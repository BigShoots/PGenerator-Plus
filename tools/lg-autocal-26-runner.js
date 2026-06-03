#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const baseUrl = process.env.PGEN_URL || 'http://192.168.1.179';
const stamp = new Date().toISOString().replace(/[-:T]/g, '').replace(/\..+/, '');
const outDir = process.env.PGEN_OUT_DIR || 'tmp';
const displayType = process.env.PGEN_DISPLAY_TYPE || 'oled_generic';
const patchSize = Number(process.env.PGEN_PATCH_SIZE || '10');
const delayMs = Number(process.env.PGEN_DELAY_MS || '2500');
const targetDeltaE = Number(process.env.PGEN_TARGET_DE || '0.5');
const maxIterations = Number(process.env.PGEN_MAX_ITERATIONS || '80');
const readAttempts = Number(process.env.PGEN_READ_ATTEMPTS || '5');
const pictureMode = process.env.PGEN_PICTURE_MODE || 'cinema';
const targetGamma = process.env.PGEN_TARGET_GAMMA || 'bt1886';
const runAutocal = process.env.PGEN_RUN_AUTOCAL !== '0';
const runSeries = process.env.PGEN_RUN_SERIES !== '0';
const patchInsert = process.env.PGEN_PATCH_INSERT === '1';
const malformedStatusJsonRetries = Number(process.env.PGEN_STATUS_JSON_RETRIES || '3');

const ddcSlots = [
  2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45,
  50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109
];

const ddcCodes = [
  84, 92, 100, 108, 124, 152, 196, 240, 284, 328, 372, 416, 460,
  504, 544, 588, 632, 676, 720, 764, 808, 852, 896, 932, 984, 1023
];

const ddcStimulus = ddcCodes.map(code => {
  return ((code - 64) * 100) / 876;
});

function fmt(value) {
  return String(Math.round(Number(value) * 100) / 100)
    .replace(/(\.\d*?)0+$/, '$1')
    .replace(/\.$/, '');
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function api(endpoint, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 60000);
  try {
    const response = await fetch(baseUrl + endpoint, {
      method: options.method || 'GET',
      headers: options.body ? { 'Content-Type': 'application/json' } : undefined,
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: controller.signal
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${endpoint} HTTP ${response.status}: ${text.slice(0, 240)}`);
    try {
      return JSON.parse(text);
    } catch {
      const error = new Error(`${endpoint} returned non-JSON: ${text.slice(0, 240)}`);
      error.nonJson = true;
      error.endpoint = endpoint;
      error.responseText = text;
      throw error;
    }
  } finally {
    clearTimeout(timeout);
  }
}

function xyToUvPrime(x, y) {
  const den = (-2 * x) + (12 * y) + 3;
  if (!Number.isFinite(den) || Math.abs(den) < 1e-9) return [0, 0];
  return [(4 * x) / den, (9 * y) / den];
}

function lstar(ratio) {
  const r = Math.max(0, Number(ratio) || 0);
  return r <= 0.008856451679 ? 903.2963 * r : (116 * Math.pow(r, 1 / 3)) - 16;
}

function targetGammaLinear(signal) {
  const s = Math.max(0, Math.min(1, Number(signal) || 0));
  if (s <= 0) return 0;
  if (targetGamma === 'srgb') return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  const gamma = targetGamma === '2.2' ? 2.2 : 2.4;
  return Math.pow(s, gamma);
}

function luminance(reading) {
  if (!reading) return undefined;
  if (reading.luminance != null) return Number(reading.luminance);
  if (reading.Y != null) return Number(reading.Y);
  return undefined;
}

function deltaELuvGamma(reading, whiteY, targetX, targetY, targetLuminance) {
  if (!reading || !Number.isFinite(whiteY) || whiteY <= 0) return undefined;
  const x = Number(reading.x);
  const y = Number(reading.y);
  const Y = luminance(reading);
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(Y) || x <= 0 || y <= 0) return undefined;
  const [u, v] = xyToUvPrime(x, y);
  const [tu, tv] = xyToUvPrime(targetX, targetY);
  const L = lstar(Y / whiteY);
  const chroma = 13 * L * Math.sqrt((u - tu) * (u - tu) + (v - tv) * (v - tv));
  if (!Number.isFinite(targetLuminance) || targetLuminance <= 0) return chroma;
  const luma = Math.abs(lstar(Y / whiteY) - lstar(targetLuminance / whiteY));
  return Math.sqrt((chroma * chroma) + (luma * luma));
}

function buildAutocalSteps() {
  const stepFor = (ire, stimulus, code, extra = {}) => {
    return {
      ire,
      stimulus,
      signal_r_pct: stimulus,
      signal_g_pct: stimulus,
      signal_b_pct: stimulus,
      r: code,
      g: code,
      b: code,
      input_max: 1023,
      name: `${fmt(ire)}%`,
      series_type: 'greyscale',
      ...extra
    };
  };
  const out = [
    stepFor(100, 100, 940, {
      name: '100%',
      autocal_white_reference: true,
      autocal_reference_only: true,
      autocal_slot_locked: true,
      ddc_slot_locked: true,
      autocal_code: 940
    }),
    stepFor(0, 0, 64, {
      autocal_read_only: true,
      autocal_slot_locked: false,
      ddc_slot_locked: false
    })
  ];
  ddcSlots.forEach((slot, idx) => {
    out.push(stepFor(slot, ddcStimulus[idx], ddcCodes[idx], {
      autocal_code: ddcCodes[idx],
      autocal_slot_locked: true,
      ddc_slot_locked: true
    }));
  });
  return out;
}

function summarize(readings, steps) {
  const targetX = 0.3127;
  const targetY = 0.3290;
  const byIre = new Map();
  (steps || []).forEach(step => {
    if (step && step.ire != null) byIre.set(fmt(step.ire), step);
  });
  const white = (readings || []).find(r => {
      const step = byIre.get(fmt(r.ire));
      return step && step.autocal_white_reference;
    })
    || (readings || []).find(r => {
      const step = byIre.get(fmt(r.ire));
      return Math.abs(Number(r.ire) - 100) < 0.001;
    })
    || (readings || []).filter(r => Number(r.ire) > 0).sort((a, b) => Number(b.ire) - Number(a.ire))[0]
    || (readings || [])[0];
  const whiteY = luminance(white);
  const rows = [];
  for (const reading of readings || []) {
    const ire = Number(reading.ire);
    const key = fmt(ire);
    const step = byIre.get(key) || reading;
    const stimulus = Number(step.stimulus != null ? step.stimulus : (reading.stimulus != null ? reading.stimulus : ire));
    const targetLuminance = ire >= 99.9 ? undefined : (whiteY * targetGammaLinear(stimulus / 100));
    const dE = deltaELuvGamma(reading, whiteY, targetX, targetY, targetLuminance);
    const Y = luminance(reading);
    const lumPct = Number.isFinite(targetLuminance) && targetLuminance > 0 && Number.isFinite(Y)
      ? ((Y - targetLuminance) / targetLuminance) * 100
      : undefined;
    rows.push({
      ire,
      stimulus,
      code: reading.r_code ?? step.r,
      Y,
      x: reading.x,
      y: reading.y,
      dE: Number.isFinite(dE) ? Number(dE.toFixed(3)) : null,
      luminance_error_pct: Number.isFinite(lumPct) ? Number(lumPct.toFixed(2)) : null
    });
  }
  const valid = rows.filter(row => {
    if (row.dE == null || row.ire <= 0) return false;
    const step = byIre.get(fmt(row.ire));
    if (Math.abs(Number(row.ire) - 100) < 0.001 && Number(row.code) === 940) return false;
    return !(step && step.autocal_reference_only);
  });
  const avg = valid.length ? valid.reduce((sum, row) => sum + row.dE, 0) / valid.length : null;
  const max = valid.reduce((best, row) => (!best || row.dE > best.dE) ? row : best, null);
  return { whiteY, avg_dE: avg == null ? null : Number(avg.toFixed(3)), max_dE: max, rows };
}

function save(name, value) {
  fs.mkdirSync(outDir, { recursive: true });
  const file = path.join(outDir, name);
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
  return file;
}

async function parkBlack() {
  await api('/api/pattern', {
    method: 'POST',
    body: {
      name: 'patch',
      r: 0,
      g: 0,
      b: 0,
      size: 100,
      input_max: 255,
      signal_mode: 'sdr',
      max_luma: 1000,
      signal_range: '1',
      transport_signal_range: '1'
    },
    timeoutMs: 10000
  }).catch(() => null);
}

async function pollStatus(endpoint, outName, label) {
  let last = null;
  const started = Date.now();
  const maxMalformedRetries = Number.isFinite(malformedStatusJsonRetries) && malformedStatusJsonRetries >= 0
    ? Math.floor(malformedStatusJsonRetries)
    : 3;
  let malformedRetries = 0;
  while (Date.now() - started < 6 * 60 * 60 * 1000) {
    let status;
    try {
      status = await api(endpoint, { timeoutMs: 30000 });
      malformedRetries = 0;
    } catch (error) {
      if (!error || !error.nonJson || malformedRetries >= maxMalformedRetries) throw error;
      malformedRetries++;
      process.stderr.write(
        `[${new Date().toLocaleTimeString()}] ${label}: malformed status JSON from ${endpoint}; retry ${malformedRetries}/${maxMalformedRetries}\n`
      );
      await sleep(1000);
      continue;
    }
    last = status;
    save(outName, status);
    const state = status.status || 'unknown';
    const current = status.current_name || status.message || '';
    process.stdout.write(`[${new Date().toLocaleTimeString()}] ${label}: ${state} ${current}\n`);
    if (state === 'complete' || state === 'error' || state === 'cancelled') return status;
    await sleep(5000);
  }
  throw new Error(`${label} timed out`);
}

async function main() {
  const steps = buildAutocalSteps();
  const payload = {
    type: 'greyscale',
    points: 26,
    display_type: displayType,
    delay_ms: delayMs,
    patch_size: patchSize,
    signal_range: '1',
    pattern_signal_range: '1',
    transport_signal_range: '1',
    signal_mode: 'sdr',
    max_luma: 1000,
    lg_autocal_26: true,
    lg_extended_sdr_16_255: true,
    use_shifted_lg_autocal_stimulus: true,
    stimulus_probe_enabled: false,
    strict_lg_autocal_slot_signal: false,
    patch_insert: patchInsert,
    post_commit_polish: process.env.PGEN_POST_COMMIT_POLISH !== '0',
    target_delta_e: targetDeltaE,
    target_luminance: 0,
    target_gamma: targetGamma,
    target_white_x: 0.3127,
    target_white_y: 0.3290,
    picture_mode: pictureMode,
    reset_ddc_baseline: true,
    force_ddc_white_balance: true,
    max_iterations: maxIterations,
    read_attempts: readAttempts,
    steps
  };
  const result = { started_at: new Date().toISOString(), autocal_payload: payload };
  save(`lg-autocal-26-run-${stamp}-payload.json`, payload);
  try {
    if (runAutocal) {
      await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
      await parkBlack();
      const start = await api('/api/meter/lg-autocal', { method: 'POST', body: payload, timeoutMs: 30000 });
      result.autocal_start = start;
      if (!start || start.status !== 'started') throw new Error((start && start.message) || 'AutoCal did not start');
      const autocal = await pollStatus('/api/meter/lg-autocal/status', `lg-autocal-26-run-${stamp}-status.json`, 'autocal');
      result.autocal_status = autocal;
      result.autocal_summary = summarize(autocal.readings || [], autocal.steps || steps);
      save(`lg-autocal-26-run-${stamp}-summary.json`, result.autocal_summary);
      if (autocal.status !== 'complete') throw new Error(`AutoCal ended as ${autocal.status}: ${autocal.message || ''}`);
    }

    if (runSeries) {
      await parkBlack();
      const seriesPayload = {
        type: 'greyscale',
        points: 26,
        display_type: displayType,
        delay_ms: delayMs,
        patch_size: patchSize,
        signal_range: '1',
        pattern_signal_range: '1',
        transport_signal_range: '1',
        signal_mode: 'sdr',
        max_luma: 1000,
        lg_autocal_26: true,
        target_gamma: targetGamma,
        target_gamut: 'bt709',
        patch_insert: false
      };
      const start = await api('/api/meter/series', { method: 'POST', body: seriesPayload, timeoutMs: 30000 });
      result.series_start = start;
      if (!start || start.status !== 'started') throw new Error((start && start.message) || '26pt series did not start');
      const series = await pollStatus('/api/meter/series/status', `lg-autocal-26-run-${stamp}-series.json`, 'series');
      result.series_status = series;
      result.series_summary = summarize(series.readings || [], series.steps || start.steps || steps);
      save(`lg-autocal-26-run-${stamp}-series-summary.json`, result.series_summary);
      if (series.status !== 'complete') throw new Error(`Series ended as ${series.status}: ${series.message || ''}`);
    }
  } finally {
    await parkBlack();
    result.finished_at = new Date().toISOString();
    save(`lg-autocal-26-run-${stamp}-result.json`, result);
  }

  process.stdout.write(`Done. Results written under ${outDir} with stamp ${stamp}.\n`);
  if (result.series_summary) {
    process.stdout.write(`Series avg dE ${result.series_summary.avg_dE}; max ${JSON.stringify(result.series_summary.max_dE)}\n`);
  }
}

main().catch(error => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});

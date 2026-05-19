#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const apiBase = process.env.PGEN_API || 'http://192.168.1.177';
const outDir = process.env.PGEN_OUT_DIR || `tmp/lg-ddc-fast-series-${new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, 'Z')}`;
const pictureMode = process.env.PGEN_PICTURE_MODE || 'cinema';
const displayType = process.env.PGEN_DISPLAY_TYPE || 'ccss_LG_C2_(WRGB_OLED)_-_JETI_1501_HiRes_2nm.ccss';
const delayMs = Number(process.env.PGEN_DELAY_MS || 2500);
const patchSize = Number(process.env.PGEN_PATCH_SIZE || 10);
const ddcSlots = [2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109];

function mkdir() {
  fs.mkdirSync(outDir, { recursive: true });
}

function save(name, value) {
  mkdir();
  fs.writeFileSync(path.join(outDir, name), typeof value === 'string' ? value : JSON.stringify(value, null, 2));
}

function append(name, value) {
  mkdir();
  fs.appendFileSync(path.join(outDir, name), `${JSON.stringify(value)}\n`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function api(endpoint, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 60000);
  try {
    const response = await fetch(apiBase + endpoint, {
      method: options.method || 'GET',
      headers: options.body ? { 'Content-Type': 'application/json' } : undefined,
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: controller.signal
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${endpoint} HTTP ${response.status}: ${text.slice(0, 400)}`);
    try {
      return JSON.parse(text);
    } catch {
      return { raw: text };
    }
  } finally {
    clearTimeout(timeout);
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeArray(value, count = 26) {
  const out = Array.isArray(value) ? value.map(v => Number(v) || 0) : [];
  while (out.length < count) out.push(0);
  return out.slice(0, count);
}

function arraysFromPicture(picture) {
  return {
    whiteBalanceRed: normalizeArray(picture.whiteBalanceRed),
    whiteBalanceGreen: normalizeArray(picture.whiteBalanceGreen),
    whiteBalanceBlue: normalizeArray(picture.whiteBalanceBlue),
    adjustingLuminance: normalizeArray(picture.adjustingLuminance)
  };
}

function parseJsonEnv(name, fallback) {
  if (!process.env[name]) return fallback;
  try {
    return JSON.parse(process.env[name]);
  } catch (error) {
    throw new Error(`Invalid ${name}: ${error.message}`);
  }
}

function indexForIre(ireText) {
  const ire = Number(ireText);
  const index = ddcSlots.findIndex(slot => Math.abs(slot - ire) < 0.001);
  if (index < 0) throw new Error(`No LG 26pt DDC slot for IRE ${ireText}`);
  return index;
}

function applyLumaDeltas(arrays, deltas) {
  const next = clone(arrays);
  for (const [ireText, deltaRaw] of Object.entries(deltas || {})) {
    const index = indexForIre(ireText);
    const delta = Number(deltaRaw);
    if (!Number.isFinite(delta)) throw new Error(`Invalid luminance delta for ${ireText}: ${deltaRaw}`);
    next.adjustingLuminance[index] = Math.max(-50, Math.min(50, (Number(next.adjustingLuminance[index]) || 0) + delta));
  }
  return next;
}

async function cleanup(prefix) {
  const result = {};
  result.lgAutocalStop = await api('/api/meter/lg-autocal/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  result.meterStop = await api('/api/meter/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  result.sessionStop = await api('/api/meter/session/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  result.patternStop = await api('/api/pattern', { method: 'POST', body: { name: 'stop' }, timeoutMs: 10000 }).catch(e => ({ error: e.message }));
  result.calibrationModeOff = await api('/api/lg/calibration-mode', {
    method: 'POST',
    body: { picture_mode: pictureMode, calibration_mode: false },
    timeoutMs: 30000
  }).catch(e => ({ error: e.message }));
  save(`${prefix}-cleanup.json`, result);
}

async function readPicture() {
  const response = await api('/api/lg/picture-settings', {
    method: 'POST',
    body: {
      keys: ['pictureMode', 'whiteBalanceMethod', 'whiteBalanceIre', 'whiteBalanceRed', 'whiteBalanceGreen', 'whiteBalanceBlue', 'adjustingLuminance'],
      picture_mode: pictureMode,
      force_ddc_white_balance: true,
      helper_timeout: 90
    },
    timeoutMs: 120000
  });
  if (!response || response.status !== 'ok') throw new Error((response && response.message) || 'picture-settings read failed');
  return response.picture_settings || {};
}

async function writeArrays(arrays, label) {
  const payload = {
    settings: {
      whiteBalanceMethod: '22',
      whiteBalanceIre: '109',
      whiteBalanceRed: arrays.whiteBalanceRed,
      whiteBalanceGreen: arrays.whiteBalanceGreen,
      whiteBalanceBlue: arrays.whiteBalanceBlue,
      adjustingLuminance: arrays.adjustingLuminance
    },
    picture_mode: pictureMode,
    keep_calibration_mode: false,
    calibration_mode_active: false,
    force_ddc_white_balance: true,
    verify_ddc_upload: true,
    helper_timeout: 170,
    readback_keys: ['pictureMode', 'whiteBalanceMethod', 'whiteBalanceIre', 'whiteBalanceRed', 'whiteBalanceGreen', 'whiteBalanceBlue', 'adjustingLuminance']
  };
  save(`${label}-write-payload.json`, payload);
  const response = await api('/api/lg/picture-settings/set', { method: 'POST', body: payload, timeoutMs: 240000 });
  save(`${label}-write-result.json`, response);
  if (!response || response.status !== 'ok') throw new Error((response && response.message) || `${label} write failed`);
  await sleep(1200);
}

async function parkBlack(ms) {
  await api('/api/pattern', { method: 'POST', body: { name: 'black' }, timeoutMs: 10000 }).catch(() => null);
  if (ms > 0) await sleep(ms);
}

function seriesPayload() {
  return {
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
    target_gamma: 'bt1886',
    target_gamut: 'bt709',
    delta_e_formula: 'deitp',
    patch_insert: false
  };
}

async function runSeries() {
  const payload = seriesPayload();
  save('series-payload.json', payload);
  const start = await api('/api/meter/series', { method: 'POST', body: payload, timeoutMs: 30000 });
  save('series-start.json', start);
  if (!start || start.status !== 'started') throw new Error(`series did not start: ${JSON.stringify(start)}`);
  const started = Date.now();
  let last = start;
  while (Date.now() - started < 90 * 60 * 1000) {
    await sleep(5000);
    last = await api('/api/meter/series/status', { timeoutMs: 30000 });
    append('series-status-stream.jsonl', { ts: new Date().toISOString(), status: last });
    save('series-status.json', last);
    console.log(`${new Date().toISOString()} series ${last.status || 'unknown'} ${last.current_name || ''}`);
    if (last.status === 'complete' || last.status === 'error' || last.status === 'cancelled') break;
  }
  if (last.status !== 'complete') throw new Error(`series ended as ${last.status || 'unknown'}`);
  save('series-readings.json', last.readings || []);
  return last;
}

function codeFor(reading) {
  const value = reading && (reading.autocal_code ?? reading.code ?? reading.r_code ?? reading.g_code ?? reading.b_code ?? reading.r ?? reading.g ?? reading.b);
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n) : null;
}

function normalizeKeyPart(value) {
  if (value == null) return '';
  const n = Number(value);
  if (Number.isFinite(n)) return String(Math.round(n * 1000) / 1000).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
  return String(value).trim().toLowerCase();
}

function stepKeys(step) {
  const keys = new Set();
  const name = normalizeKeyPart(step && step.name);
  const ire = normalizeKeyPart(step && step.ire);
  const codes = [step && step.autocal_code, step && step.code, step && step.r_code, step && step.g_code, step && step.b_code, step && step.r, step && step.g, step && step.b]
    .map(v => {
      const n = Number(v);
      return Number.isFinite(n) ? Math.round(n) : null;
    })
    .filter(v => v != null);
  if (ire && codes.length) for (const code of codes) keys.add(`ire-code:${ire}:${code}`);
  if (name && codes.length) for (const code of codes) keys.add(`name-code:${name}:${code}`);
  if (ire) keys.add(`ire:${ire}`);
  if (name) keys.add(`name:${name}`);
  for (const code of codes) keys.add(`code:${code}`);
  return keys;
}

function readingKeys(reading) {
  return stepKeys(reading);
}

function buildStepLookup(steps) {
  const lookup = new Map();
  for (const step of steps || []) {
    for (const key of stepKeys(step)) if (!lookup.has(key)) lookup.set(key, step);
  }
  return lookup;
}

function enrichSeriesReadings(readings, steps) {
  const lookup = buildStepLookup(steps);
  return (readings || []).map(reading => {
    if (!reading) return reading;
    let matched = null;
    for (const key of readingKeys(reading)) {
      matched = lookup.get(key);
      if (matched) break;
    }
    if (!matched) return reading;
    const enriched = { ...reading };
    for (const field of ['target_x', 'target_y', 'target_Yn', 'stimulus', 'signal_r_pct', 'signal_g_pct', 'signal_b_pct', 'r', 'g', 'b', 'autocal_code', 'code']) {
      if (matched[field] != null) enriched[field] = matched[field];
    }
    return enriched;
  });
}

function targetGammaLinear(signal) {
  const s = Math.max(0, Math.min(1, Number(signal) || 0));
  return s <= 0 ? 0 : Math.pow(s, 2.4);
}

function deriveReferenceFrom109(readings, fallback) {
  const row = (readings || []).find(r => Math.abs(Number(r && r.ire) - 109) < 0.01 || codeFor(r) === 1023 || String(r && r.name || '').trim() === '109%');
  const y = Number(row && (row.luminance ?? row.Y));
  const yn = Number(row && row.target_Yn);
  if (Number.isFinite(y) && y > 0 && Number.isFinite(yn) && yn > 0) return y / yn;
  return fallback;
}

function pqEncodeNormalized(nits) {
  let value = Number(nits) || 0;
  if (value <= 0) return 0;
  if (value > 10000) value = 10000;
  const l = value / 10000;
  const m1 = 2610 / 16384;
  const m2 = 2523 / 32;
  const c1 = 3424 / 4096;
  const c2 = 2413 / 128;
  const c3 = 2392 / 128;
  const p = Math.pow(l, m1);
  return Math.pow((c1 + c2 * p) / (1 + c3 * p), m2);
}

function xyzToICtCp(X, Y, Z) {
  const R = Math.max(0, 1.7166511880 * X - 0.3556707838 * Y - 0.2533662814 * Z);
  const G = Math.max(0, -0.6666843518 * X + 1.6164812366 * Y + 0.0157685458 * Z);
  const B = Math.max(0, 0.0176398574 * X - 0.0427706133 * Y + 0.9421031212 * Z);
  const L = (1688 * R + 2146 * G + 262 * B) / 4096;
  const M = (683 * R + 2951 * G + 462 * B) / 4096;
  const S = (99 * R + 309 * G + 3688 * B) / 4096;
  const Lp = pqEncodeNormalized(L);
  const Mp = pqEncodeNormalized(M);
  const Sp = pqEncodeNormalized(S);
  return {
    I: 0.5 * Lp + 0.5 * Mp,
    T: (6610 * Lp - 13613 * Mp + 7003 * Sp) / 4096,
    P: (17933 * Lp - 17390 * Mp - 543 * Sp) / 4096
  };
}

function xyzFromXyY(x, y, Y) {
  if (![x, y, Y].every(Number.isFinite) || y <= 0) return null;
  return { X: (x * Y) / y, Y, Z: ((1 - x - y) * Y) / y };
}

function deltaEItpY(reading, targetY) {
  const x = Number(reading && reading.x);
  const y = Number(reading && reading.y);
  const Y = Number(reading && (reading.luminance ?? reading.Y));
  const measured = [reading && reading.X, Y, reading && reading.Z].every(v => Number.isFinite(Number(v)))
    ? { X: Number(reading.X), Y, Z: Number(reading.Z) }
    : xyzFromXyY(x, y, Y);
  const target = xyzFromXyY(0.3127, 0.3290, Number(targetY));
  if (!measured || !target) return null;
  const a = xyzToICtCp(measured.X, measured.Y, measured.Z);
  const b = xyzToICtCp(target.X, target.Y, target.Z);
  return 720 * Math.sqrt((a.I - b.I) ** 2 + 0.25 * (a.T - b.T) ** 2 + (a.P - b.P) ** 2);
}

function summarize(readings, referenceY) {
  const ref = Number(referenceY);
  if (!Number.isFinite(ref) || ref <= 0) throw new Error(`Cannot summarize without a valid reference Y: ${referenceY}`);
  const rows = (readings || []).filter(r => r && r.ire != null && (r.luminance != null || r.Y != null)).map(r => {
    const ire = Number(r.ire);
    const stimulus = Number(r.stimulus ?? r.signal_g_pct ?? ire);
    const targetYn = Number(r.target_Yn);
    const targetY = Number.isFinite(targetYn) && targetYn > 0 ? ref * targetYn : (ire >= 99.999 ? ref : ref * targetGammaLinear(stimulus / 100));
    return {
      ire,
      name: r.name,
      Y: Number(r.luminance ?? r.Y),
      targetY,
      deltaEItpY: deltaEItpY(r, targetY)
    };
  });
  const valid = rows.filter(r => r.deltaEItpY != null && r.ire > 0);
  const avg = valid.reduce((sum, r) => sum + r.deltaEItpY, 0) / valid.length;
  const max = valid.reduce((best, r) => !best || r.deltaEItpY > best.deltaEItpY ? r : best, null);
  return { referenceY: ref, avgDeltaEItpY: avg, maxDeltaEItpY: max, over1: valid.filter(r => r.deltaEItpY > 1), rows };
}

function analyzeSeriesStatus(seriesStatus) {
  const enriched = enrichSeriesReadings(seriesStatus.readings || [], seriesStatus.steps || []);
  const post109Ref = deriveReferenceFrom109(enriched, null);
  const summary109 = summarize(enriched, post109Ref);
  return { enriched, post109Ref, summary109 };
}

async function main() {
  mkdir();
  if (process.env.PGEN_ANALYZE_ARTIFACT) {
    const artifact = process.env.PGEN_ANALYZE_ARTIFACT;
    const seriesStatus = JSON.parse(fs.readFileSync(path.join(artifact, 'series-status.json'), 'utf8'));
    const analysis = analyzeSeriesStatus(seriesStatus);
    save('series-readings.json', analysis.enriched);
    save('summary-109-reference.json', analysis.summary109);
    save('summary.json', { status: 'complete', post_series_109_reference: analysis.summary109, reanalyzed_from: artifact, completed_at: new Date().toISOString() });
    return;
  }

  const lumaDeltas = parseJsonEnv('PGEN_DDC_LUMA_DELTAS', {});
  const settleMs = Number(process.env.PGEN_BLACK_SETTLE_MS || 12000);
  save('run-info.json', { started_at: new Date().toISOString(), apiBase, pictureMode, displayType, lumaDeltas });

  await cleanup('initial');
  const seedPicture = await readPicture();
  const seedArrays = arraysFromPicture(seedPicture);
  save('seed-picture.json', seedPicture);
  save('seed-arrays.json', seedArrays);

  const candidateArrays = applyLumaDeltas(seedArrays, lumaDeltas);
  save('candidate-arrays.json', candidateArrays);

  try {
    await writeArrays(candidateArrays, 'candidate');
    await parkBlack(settleMs);
    const series = await runSeries();
    const analysis = analyzeSeriesStatus(series);
    const readings = analysis.enriched;
    const post109Ref = analysis.post109Ref;
    const summary109 = analysis.summary109;
    save('series-readings.json', readings);
    save('summary-109-reference.json', summary109);
    save('summary.json', { status: 'complete', post_series_109_reference: summary109, lumaDeltas, completed_at: new Date().toISOString() });
  } finally {
    await writeArrays(seedArrays, 'restore-seed').catch(error => save('restore-error.json', { message: error.message, stack: error.stack }));
    await cleanup('final');
  }
}

main().catch(async error => {
  save('error.json', { message: error.message, stack: error.stack, at: new Date().toISOString() });
  await cleanup('error-final').catch(() => null);
  console.error(error.stack || error.message);
  process.exit(1);
});

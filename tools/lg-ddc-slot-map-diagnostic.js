#!/usr/bin/env node
'use strict';

const fs = require('fs');

const baseUrl = process.env.PGEN_URL || 'http://192.168.1.179';
const outputPath = process.env.PGEN_DDC_MAP_OUT || 'tmp/lg-ddc-slot-map-diagnostic.json';
const diagnosticToken = process.env.PGEN_DDC_MAP_TOKEN || 'codexdiag';
const ddcLayout = String(process.env.PGEN_DDC_MAP_LAYOUT || 'sdr26').toLowerCase() === 'hdr20' ? 'hdr20' : 'sdr26';
const channel = (process.env.PGEN_DDC_MAP_CHANNEL || 'blue').toLowerCase();
const delta = Number(process.env.PGEN_DDC_MAP_DELTA || '-30');
const minReadDelayMs = Number(process.env.PGEN_DDC_MAP_DELAY_MS || '700');
const readRetries = Math.max(0, Number(process.env.PGEN_DDC_MAP_READ_RETRIES || '2') || 0);
const envDisplayType = process.env.PGEN_DISPLAY_TYPE || process.env.PGEN_DDC_MAP_DISPLAY_TYPE || '';
const envSignalMode = process.env.PGEN_SIGNAL_MODE || process.env.PGEN_DDC_MAP_SIGNAL_MODE || '';
const envMaxLuma = process.env.PGEN_MAX_LUMA || process.env.PGEN_DDC_MAP_MAX_LUMA || '';
const envPatchSize = process.env.PGEN_PATCH_SIZE || process.env.PGEN_DDC_MAP_PATCH_SIZE || '';
const defaultPatchPoints = [0, 2.5, 5, 7.5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100];
const hdr20DdcSlots = [1.4, 2, 2.7, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100];
const defaultDdcSlots = ddcLayout === 'hdr20' ? hdr20DdcSlots : defaultPatchPoints.filter(v => v !== 0);
const mapWindowBelow = Math.max(0, Number(process.env.PGEN_DDC_MAP_WINDOW_BELOW || '10') || 0);
const mapWindowAbove = Math.max(0, Number(process.env.PGEN_DDC_MAP_WINDOW_ABOVE || '12.5') || 0);
const mapCandidateStep = Math.max(0.5, Number(process.env.PGEN_DDC_MAP_CANDIDATE_STEP || '2.5') || 2.5);
const resetBeforeMap = String(process.env.PGEN_DDC_MAP_RESET || '1') !== '0';
const restoreMode = String(process.env.PGEN_DDC_MAP_RESTORE || (resetBeforeMap ? 'zero' : 'original')).toLowerCase();
const extendedVideoHeadroom = String(process.env.PGEN_DDC_MAP_EXTENDED_16_255 || '0') === '1';
function envNumberList(name, fallback) {
  const raw = String(process.env[name] || '').trim();
  if (!raw) return fallback;
  const parsed = raw.split(',').map(item => Number(item.trim())).filter(Number.isFinite);
  return parsed.length ? parsed : fallback;
}
const explicitPatchPoints = String(process.env.PGEN_DDC_MAP_POINTS || '').trim()
  ? envNumberList('PGEN_DDC_MAP_POINTS', [])
  : null;
const ddcSlots = envNumberList('PGEN_DDC_MAP_SLOTS', defaultDdcSlots.filter(v => v <= 50));
const channelKey = {
  red: 'whiteBalanceRed',
  r: 'whiteBalanceRed',
  green: 'whiteBalanceGreen',
  g: 'whiteBalanceGreen',
  blue: 'whiteBalanceBlue',
  b: 'whiteBalanceBlue',
  luminance: 'adjustingLuminance',
  luma: 'adjustingLuminance',
  lum: 'adjustingLuminance',
  y: 'adjustingLuminance'
}[channel] || 'whiteBalanceRed';
let lastReadPostAt = 0;

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function api(path, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 120000);
  try {
    const res = await fetch(baseUrl + path, {
      method: options.method || 'GET',
      headers: options.body ? { 'Content-Type': 'application/json' } : undefined,
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: controller.signal
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${path} HTTP ${res.status}: ${text.slice(0, 300)}`);
    try {
      return JSON.parse(text);
    } catch (err) {
      throw new Error(`${path} returned non-JSON: ${text.slice(0, 300)}`);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function pctLabel(value) {
  return String(Math.round(Number(value) * 10) / 10).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
}

function pctKey(value) {
  return pctLabel(value);
}

function candidatePointsForSlot(slot) {
  if (explicitPatchPoints && explicitPatchPoints.length) return explicitPatchPoints;
  const lower = Math.max(0, Number(slot) - mapWindowBelow);
  const upper = Math.min(100, Number(slot) + mapWindowAbove);
  const points = new Set();
  for (let value = Math.ceil(lower / mapCandidateStep) * mapCandidateStep; value <= upper + 1e-9; value += mapCandidateStep) {
    points.add(Number(pctLabel(value)));
  }
  points.add(Number(pctLabel(slot)));
  return [...points].filter(Number.isFinite).sort((a, b) => a - b);
}

function codeForPercent(percent, range) {
  const pct = Math.max(0, Math.min(100, Number(percent) || 0));
  if (String(range) === '1' && extendedVideoHeadroom) return Math.round(16 + pct / 100 * 239);
  if (String(range) === '1') return Math.round(16 + pct / 100 * 219);
  return Math.round(pct / 100 * 255);
}

function normalizeArray(value) {
  if (!Array.isArray(value)) return defaultDdcSlots.map(() => 0);
  return defaultDdcSlots.map((_, idx) => {
    const numeric = Number(value[idx]);
    return Number.isFinite(numeric) ? numeric : 0;
  });
}

function zeroArrays() {
  const zero = defaultDdcSlots.map(() => 0);
  return {
    whiteBalanceRed: [...zero],
    whiteBalanceGreen: [...zero],
    whiteBalanceBlue: [...zero],
    adjustingLuminance: [...zero]
  };
}

function readingMetric(before, after) {
  if (!before || !after) return { metric: 0, dY: 0, dYpct: 0, dx: 0, dy: 0, dxy1000: 0 };
  const bY = Number(before.Y ?? before.luminance ?? 0);
  const aY = Number(after.Y ?? after.luminance ?? 0);
  const bx = Number(before.x ?? 0);
  const by = Number(before.y ?? 0);
  const ax = Number(after.x ?? 0);
  const ay = Number(after.y ?? 0);
  const dY = aY - bY;
  const dYpct = Math.abs(bY) > 1e-6 ? (dY / bY * 100) : 0;
  const dx = ax - bx;
  const dy = ay - by;
  const dxy1000 = Math.sqrt(dx * dx + dy * dy) * 1000;
  return {
    metric: dxy1000 + Math.abs(dYpct) * 0.4,
    dY,
    dYpct,
    dx,
    dy,
    dxy1000
  };
}

function summarizeSlot(slotResult, baseline) {
  const points = slotResult.candidate_points || [];
  const deltas = points.map(point => {
    const before = baseline.readings[pctKey(point)];
    const after = slotResult.readings[pctKey(point)];
    return {
      point,
      before,
      after,
      ...readingMetric(before, after)
    };
  }).sort((a, b) => b.metric - a.metric);
  slotResult.top = deltas.slice(0, 5).map(item => ({
    point: item.point,
    metric: Number(item.metric.toFixed(4)),
    dxy1000: Number(item.dxy1000.toFixed(4)),
    dY: Number(item.dY.toFixed(4)),
    dYpct: Number(item.dYpct.toFixed(3)),
    beforeY: item.before ? Number(Number(item.before.Y ?? item.before.luminance ?? 0).toFixed(4)) : null,
    afterY: item.after ? Number(Number(item.after.Y ?? item.after.luminance ?? 0).toFixed(4)) : null
  }));
  slotResult.best_point = slotResult.top[0] ? slotResult.top[0].point : null;
}

async function readPatch(point, settings, config, runId) {
  let lastError = null;
  for (let attempt = 0; attempt <= readRetries; attempt++) {
    try {
      const sinceLastPost = Date.now() - lastReadPostAt;
      if (sinceLastPost < 650) await sleep(650 - sinceLastPost);
      const range = String(config.rgb_quant_range || '1');
      const code = codeForPercent(point, range);
      const requestId = `${diagnosticToken}_${runId}_try${attempt + 1}_${pctLabel(point).replace('.', 'p')}_${Date.now()}`;
      const payload = {
        display_type: envDisplayType || settings.display_type || 'lcd',
        refresh_rate: settings.refresh_rate || undefined,
        measurement_meter_port: settings.measurement_meter_port || undefined,
        patch_r: code,
        patch_g: code,
        patch_b: code,
        patch_size: Number(envPatchSize || settings.patch_size || 10) || 10,
        ire: point,
        stimulus: point,
        name: `${pctLabel(point)}%`,
        delay_ms: Math.max(Number(settings.delay || 500) || 500, minReadDelayMs),
        signal_range: range,
        transport_signal_range: range,
        signal_mode: envSignalMode || settings.signal_mode || (ddcLayout === 'hdr20' ? 'hdr10' : 'sdr'),
        max_luma: envMaxLuma || settings.max_luma || (ddcLayout === 'hdr20' ? '1000' : ''),
        target_gamut: settings.target_gamut || (ddcLayout === 'hdr20' ? 'bt2020' : 'bt709'),
        target_gamma: settings.target_gamma || (ddcLayout === 'hdr20' ? '2.2' : 'bt1886'),
        request_id: requestId
      };
      lastReadPostAt = Date.now();
      await api('/api/meter/read', { method: 'POST', body: payload, timeoutMs: 180000 });
      const started = Date.now();
      while (Date.now() - started < 180000) {
        const result = await api('/api/meter/read/result', { timeoutMs: 10000 });
        if (result && result.status === 'ok' && Array.isArray(result.readings) && result.readings[0]) {
          const reading = result.readings[0];
          if (!reading.request_id || reading.request_id === requestId) {
            return reading;
          }
        }
        if (result && result.status && result.status !== 'measuring' && result.status !== 'ok') {
          throw new Error(`Read ${point}% failed: ${result.message || result.status}`);
        }
        await sleep(250);
      }
      throw new Error(`Timed out reading ${point}%`);
    } catch (err) {
      lastError = err;
      if (attempt >= readRetries) break;
      process.stdout.write(`  meter read recovery: ${err.message || String(err)}\n`);
      await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
      lastReadPostAt = 0;
      await sleep(1800);
    }
  }
  throw lastError || new Error(`Timed out reading ${point}%`);
}

async function readAllPoints(label, settings, config) {
  const readings = {};
  for (const point of explicitPatchPoints || defaultPatchPoints) {
    process.stdout.write(`  ${label}: reading ${pctLabel(point)}%\n`);
    const reading = await readPatch(point, settings, config, `${label}_${pctLabel(point).replace('.', 'p')}`);
    readings[pctKey(point)] = reading;
  }
  return readings;
}

async function ensureBaselineReading(results, point, settings, config) {
  const key = pctKey(point);
  if (results.baseline.readings[key]) return results.baseline.readings[key];
  process.stdout.write(`  baseline: reading ${pctLabel(point)}%\n`);
  const reading = await readPatch(point, settings, config, `baseline_${pctLabel(point).replace('.', 'p')}`);
  results.baseline.readings[key] = reading;
  saveProgress(results);
  return reading;
}

async function setWhiteBalance(originalPicture, arrays, ire, calibrationModeActive, resetBaseline = false) {
  const body = {
    settings: {
      whiteBalanceMethod: '22',
      whiteBalanceIre: pctLabel(ire),
      ddc_layout: ddcLayout,
      whiteBalanceRed: arrays.whiteBalanceRed,
      whiteBalanceGreen: arrays.whiteBalanceGreen,
      whiteBalanceBlue: arrays.whiteBalanceBlue,
      adjustingLuminance: arrays.adjustingLuminance
    },
    picture_mode: originalPicture.pictureMode || '',
    force_ddc_white_balance: true,
    readback_keys: ['pictureMode', 'ddc_layout', 'whiteBalanceMethod', 'whiteBalanceIre', 'whiteBalanceRed', 'whiteBalanceGreen', 'whiteBalanceBlue', 'adjustingLuminance'],
    keep_calibration_mode: true,
    calibration_mode_active: !!calibrationModeActive,
    reset_ddc_baseline: !!resetBaseline
  };
  const response = await api('/api/lg/picture-settings/set', { method: 'POST', body, timeoutMs: 180000 });
  if (!response || response.status !== 'ok') {
    throw new Error(response && response.message ? response.message : 'LG white-balance write failed');
  }
  await sleep(1000);
  return response.picture_settings || null;
}

function saveProgress(results) {
  fs.mkdirSync(require('path').dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(results, null, 2));
}

async function main() {
  const results = {
    started_at: new Date().toISOString(),
    base_url: baseUrl,
    channel: channelKey,
    diagnostic_token: diagnosticToken,
    delta,
    explicit_patch_points: explicitPatchPoints,
    ddc_slots: ddcSlots,
    ddc_layout: ddcLayout,
    map_window_below: mapWindowBelow,
    map_window_above: mapWindowAbove,
    map_candidate_step: mapCandidateStep,
    extended_video_headroom: extendedVideoHeadroom,
    reset_before_map: resetBeforeMap,
    restore_mode: restoreMode,
    baseline: null,
    slots: []
  };
  let originalPicture = null;
  let restorePicture = null;
  let restoreArrays = null;
  let calibrationModeActive = false;
  try {
    await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
    const [settings, config, lgStatus] = await Promise.all([
      api('/api/meter/settings', { timeoutMs: 10000 }),
      api('/api/config', { timeoutMs: 10000 }),
      api('/api/lg/status', { timeoutMs: 10000 })
    ]);
    calibrationModeActive = !!(lgStatus && lgStatus.calibration_mode);
    results.meter_settings = settings;
    results.config = config;
    results.lg_status = lgStatus;
    const picResponse = await api('/api/lg/picture-settings', {
      method: 'POST',
      body: {
        keys: ['pictureMode', 'ddc_layout', 'whiteBalanceMethod', 'whiteBalanceIre', 'whiteBalanceRed', 'whiteBalanceGreen', 'whiteBalanceBlue', 'adjustingLuminance'],
        force_ddc_white_balance: true
      },
      timeoutMs: 30000
    });
    if (!picResponse || picResponse.status !== 'ok') throw new Error('Could not read LG picture settings');
    restorePicture = picResponse.picture_settings || {};
    restoreArrays = {
      whiteBalanceRed: normalizeArray(restorePicture.whiteBalanceRed),
      whiteBalanceGreen: normalizeArray(restorePicture.whiteBalanceGreen),
      whiteBalanceBlue: normalizeArray(restorePicture.whiteBalanceBlue),
      adjustingLuminance: normalizeArray(restorePicture.adjustingLuminance)
    };
    originalPicture = restorePicture;
    results.original_picture = clone(restorePicture);
    let originalArrays = {
      whiteBalanceRed: normalizeArray(originalPicture.whiteBalanceRed),
      whiteBalanceGreen: normalizeArray(originalPicture.whiteBalanceGreen),
      whiteBalanceBlue: normalizeArray(originalPicture.whiteBalanceBlue),
      adjustingLuminance: normalizeArray(originalPicture.adjustingLuminance)
    };
    if (resetBeforeMap) {
      process.stdout.write('Resetting LG DDC table to zero before mapping...\n');
      const resetPicture = await setWhiteBalance(originalPicture, zeroArrays(), '100', calibrationModeActive, true);
      if (resetPicture) originalPicture = resetPicture;
      originalArrays = zeroArrays();
      results.reset_picture = clone(originalPicture);
      calibrationModeActive = true;
    } else {
      process.stdout.write('Re-applying the current LG DDC table before baseline...\n');
      await setWhiteBalance(originalPicture, originalArrays, originalPicture.whiteBalanceIre || '100', calibrationModeActive);
    }
    process.stdout.write('Reading baseline patches on demand...\n');
    results.baseline = { readings: {} };
    saveProgress(results);

    for (const slot of ddcSlots) {
      const idx = defaultDdcSlots.findIndex(value => Math.abs(value - slot) < 0.001);
      if (idx < 0) {
        results.slots.push({ slot, index: -1, skipped: true, reason: 'slot is not an LG DDC slot' });
        continue;
      }
      const arrays = clone(originalArrays);
      const before = Number(arrays[channelKey][idx]) || 0;
      const after = Math.max(-50, Math.min(50, before + delta));
      if (Math.abs(after - before) < 0.001) {
        results.slots.push({ slot, index: idx, skipped: true, reason: 'delta would not change value' });
        continue;
      }
      const slotResult = {
        slot,
        index: idx,
        changed_channel: channelKey,
        before_value: before,
        test_value: after,
        candidate_points: candidatePointsForSlot(slot),
        readings: {}
      };
      process.stdout.write(`\nTesting LG DDC slot ${pctLabel(slot)}% (${channelKey} ${before} -> ${after})...\n`);
      for (const point of slotResult.candidate_points) {
        await ensureBaselineReading(results, point, settings, config);
      }
      arrays[channelKey][idx] = after;
      await setWhiteBalance(originalPicture, arrays, slot, calibrationModeActive);
      for (const point of slotResult.candidate_points) {
        process.stdout.write(`  slot_${pctLabel(slot).replace('.', 'p')}: reading ${pctLabel(point)}%\n`);
        slotResult.readings[pctKey(point)] = await readPatch(point, settings, config, `slot_${pctLabel(slot).replace('.', 'p')}_${pctLabel(point).replace('.', 'p')}`);
      }
      summarizeSlot(slotResult, results.baseline);
      results.slots.push(slotResult);
      saveProgress(results);
      process.stdout.write(`  strongest change: ${pctLabel(slotResult.best_point)}% (top ${slotResult.top.map(t => `${pctLabel(t.point)}%`).join(', ')})\n`);
      await setWhiteBalance(originalPicture, originalArrays, originalPicture.whiteBalanceIre || slot, calibrationModeActive);
    }
    results.finished_at = new Date().toISOString();
    saveProgress(results);
  } finally {
    if (originalPicture) {
      const arrays = restoreMode === 'original' && restoreArrays ? restoreArrays : zeroArrays();
      const picture = restoreMode === 'original' && restorePicture ? restorePicture : originalPicture;
      await setWhiteBalance(picture, arrays, picture.whiteBalanceIre || '100', calibrationModeActive, restoreMode !== 'original').catch(err => {
        process.stderr.write(`Restore failed: ${err.message}\n`);
      });
    }
    await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
  }
  const mismatches = results.slots.filter(slot => !slot.skipped && Number(slot.best_point) !== Number(slot.slot));
  process.stdout.write(`\nDone. Results written to ${outputPath}\n`);
  if (mismatches.length) {
    process.stdout.write(`Potential mismatches: ${mismatches.map(s => `${pctLabel(s.slot)}->${pctLabel(s.best_point)}`).join(', ')}\n`);
  } else {
    process.stdout.write('Every tested slot mapped strongest to its matching patch.\n');
  }
}

main().catch(err => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});

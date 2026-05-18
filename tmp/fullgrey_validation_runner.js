#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const apiBase = process.env.PGEN_API || 'http://192.168.1.177';
const outDir = process.env.PGEN_OUT_DIR || 'tmp/recovery-fullgrey-manual';
const displayType = 'ccss_LG_C2_(WRGB_OLED)_-_JETI_1501_HiRes_2nm.ccss';
const delayMs = 1800;
const patchSize = 10;
const targetGamma = 'bt1886';
const targetGamut = 'bt709';
const targetDeltaE = 0.5;
const pictureMode = 'cinema';
const postCommitPolish = process.env.PGEN_POST_COMMIT_POLISH == null
  ? undefined
  : !/^(0|false|off|no)$/i.test(process.env.PGEN_POST_COMMIT_POLISH);

const slots = [
  [2.3, 84], [3, 92], [4, 100], [5, 108], [7, 124], [10, 152],
  [15, 196], [20, 240], [25, 284], [30, 328], [35, 372], [40, 416],
  [45, 460], [50, 504], [55, 544], [60, 588], [65, 632], [70, 676],
  [75, 720], [80, 764], [85, 808], [90, 852], [95, 896], [99, 932],
  [105, 984], [109, 1023]
];

function mkdir() {
  fs.mkdirSync(outDir, { recursive: true });
}

function save(name, value) {
  mkdir();
  const file = path.join(outDir, name);
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value, null, 2));
  return file;
}

function append(name, value) {
  mkdir();
  fs.appendFileSync(path.join(outDir, name), typeof value === 'string' ? value : `${JSON.stringify(value)}\n`);
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

function fmt(v) {
  return String(Math.round(Number(v) * 1000) / 1000).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
}

function stimulusForCode(code) {
  return (Number(code) - 64) * 100 / 876;
}

function step(ire, code, extra = {}) {
  const stim = code == null ? Number(ire) : stimulusForCode(code);
  return {
    name: `${fmt(ire)}%`,
    ire,
    stimulus: stim,
    r: code == null ? Math.round(Number(ire) * 1023 / 100) : code,
    g: code == null ? Math.round(Number(ire) * 1023 / 100) : code,
    b: code == null ? Math.round(Number(ire) * 1023 / 100) : code,
    input_max: 1023,
    preview_r: Math.round((code == null ? Math.round(Number(ire) * 1023 / 100) : code) * 255 / 1023),
    preview_g: Math.round((code == null ? Math.round(Number(ire) * 1023 / 100) : code) * 255 / 1023),
    preview_b: Math.round((code == null ? Math.round(Number(ire) * 1023 / 100) : code) * 255 / 1023),
    signal_r_pct: stim,
    signal_g_pct: stim,
    signal_b_pct: stim,
    series_type: 'greyscale',
    series_mode: 'lg-autocal-26',
    autocal_code: code,
    autocal_slot_locked: true,
    ddc_slot_locked: true,
    ...extra
  };
}

function buildAutocalSteps() {
  const legal100 = step(100, 940, {
    name: '100%',
    stimulus: 100,
    signal_r_pct: 100,
    signal_g_pct: 100,
    signal_b_pct: 100,
    preview_r: 235,
    preview_g: 235,
    preview_b: 235,
    autocal_white_reference: true,
    autocal_reference_only: true,
    autocal_read_only: true,
    autocal_legal_white_anchor: true,
    ddc_target_ire: 99,
    autocal_order_ire: 98.95,
    autocal_target_label: '100% legal white',
    legal_white_pair_active: true
  });
  return [
    step(109, 1023),
    step(105, 984),
    legal100,
    step(99, 932, { legal_white_pair_active: true }),
    ...slots.filter(([ire]) => ire < 99).sort((a, b) => b[0] - a[0]).map(([ire, code]) => step(ire, code))
  ];
}

function basePayload() {
  return {
    display_type: displayType,
    delay_ms: delayMs,
    patch_size: patchSize,
    signal_mode: 'sdr',
    max_luma: 1000,
    signal_range: '1',
    pattern_signal_range: '1',
    transport_signal_range: '1',
    target_gamut: targetGamut,
    target_gamma: targetGamma,
    target_white: { x: 0.3127, y: 0.3290 },
    target_white_x: 0.3127,
    target_white_y: 0.3290,
    picture_mode: pictureMode,
    require_device_ready: false
  };
}

async function cleanup(prefix) {
  const results = {};
  results.lgAutocalStop = await api('/api/meter/lg-autocal/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  results.meterStop = await api('/api/meter/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  results.sessionStop = await api('/api/meter/session/stop', { method: 'POST', body: {}, timeoutMs: 30000 }).catch(e => ({ error: e.message }));
  results.patternStop = await api('/api/pattern', { method: 'POST', body: { name: 'stop' }, timeoutMs: 10000 }).catch(e => ({ error: e.message }));
  results.calibrationModeOff = await api('/api/lg/calibration-mode', {
    method: 'POST',
    body: { picture_mode: pictureMode, calibration_mode: false },
    timeoutMs: 30000
  }).catch(e => ({ error: e.message }));
  save(`${prefix}-cleanup.json`, results);
  return results;
}

async function readTargetWhite() {
  const requestId = `fullgrey-white-${Date.now()}`;
  const payload = {
    ...basePayload(),
    patch_insert: true,
    patch_r: 940,
    patch_g: 940,
    patch_b: 940,
    patch_input_max: 1023,
    patch_ire: 100,
    patch_name: '100% target white',
    request_id: requestId,
    read_timeout: 240
  };
  save('target-white-payload.json', payload);
  const start = await api('/api/meter/read', { method: 'POST', body: payload, timeoutMs: 30000 });
  save('target-white-start.json', start);
  const started = Date.now();
  let last = start;
  while (Date.now() - started < 300000) {
    await sleep(2000);
    last = await api('/api/meter/read/result', { timeoutMs: 30000 });
    append('target-white-status.jsonl', last);
    if (last && (last.luminance != null || last.Y != null || Array.isArray(last.readings))) break;
  }
  save('target-white-read.json', last);
  const reading = Array.isArray(last.readings) ? last.readings[0] : last;
  const y = Number(reading && (reading.luminance ?? reading.Y));
  if (!(Number.isFinite(y) && y > 0)) throw new Error('Target white read did not produce luminance');
  return { reading, y };
}

async function resetDdc() {
  const zero = Array.from({ length: 26 }, () => 0);
  const payload = {
    settings: {
      whiteBalanceMethod: '22',
      whiteBalanceIre: '109',
      whiteBalanceRed: zero,
      whiteBalanceGreen: zero,
      whiteBalanceBlue: zero,
      adjustingLuminance: zero
    },
    picture_mode: pictureMode,
    reset_ddc_baseline: true,
    force_ddc_white_balance: true,
    helper_timeout: 180,
    readback_keys: [
      'pictureMode',
      'whiteBalanceMethod',
      'whiteBalanceIre',
      'whiteBalanceRed',
      'whiteBalanceGreen',
      'whiteBalanceBlue',
      'adjustingLuminance'
    ]
  };
  save('reset-ddc-payload.json', payload);
  const result = await api('/api/lg/picture-settings/set', { method: 'POST', body: payload, timeoutMs: 240000 });
  save('reset-ddc.json', result);
  return result;
}

async function poll(endpoint, streamFile, latestFile, label, intervalMs = 5000) {
  const started = Date.now();
  let last = null;
  while (Date.now() - started < 8 * 60 * 60 * 1000) {
    last = await api(endpoint, { timeoutMs: 30000 });
    append(streamFile, { ts: new Date().toISOString(), status: last });
    save(latestFile, last);
    const state = last.status || 'unknown';
    const current = last.current_name || last.message || '';
    console.log(`${new Date().toISOString()} ${label}: ${state} ${current}`);
    if (state === 'complete' || state === 'error' || state === 'cancelled') return last;
    await sleep(intervalMs);
  }
  throw new Error(`${label} timed out`);
}

function targetGammaLinear(signal) {
  const s = Math.max(0, Math.min(1, Number(signal) || 0));
  return s <= 0 ? 0 : Math.pow(s, targetGamma === '2.2' ? 2.2 : 2.4);
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
  X = Number(X) || 0;
  Y = Number(Y) || 0;
  Z = Number(Z) || 0;
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
  x = Number(x);
  y = Number(y);
  Y = Number(Y);
  if (![x, y, Y].every(Number.isFinite) || y <= 0) return null;
  return {
    X: (x * Y) / y,
    Y,
    Z: ((1 - x - y) * Y) / y
  };
}

function deltaEItpY(reading, targetY, targetWhite = null) {
  const x = Number(reading && reading.x);
  const y = Number(reading && reading.y);
  const Y = Number(reading && (reading.luminance ?? reading.Y));
  const ty = Number(targetY);
  if (![x, y, Y, ty].every(Number.isFinite) || y <= 0 || ty <= 0) return null;
  const targetX = Number(targetWhite && targetWhite.x != null ? targetWhite.x : 0.3127);
  const targetYxy = Number(targetWhite && targetWhite.y != null ? targetWhite.y : 0.3290);
  const measured = {
    X: Number(reading && reading.X),
    Y,
    Z: Number(reading && reading.Z)
  };
  const measuredXyz = [measured.X, measured.Y, measured.Z].every(Number.isFinite)
    ? measured
    : xyzFromXyY(x, y, Y);
  const targetXyz = xyzFromXyY(targetX, targetYxy, ty);
  if (!measuredXyz || !targetXyz) return null;
  const a = xyzToICtCp(measuredXyz.X, measuredXyz.Y, measuredXyz.Z);
  const b = xyzToICtCp(targetXyz.X, targetXyz.Y, targetXyz.Z);
  const dI = a.I - b.I;
  const dT = a.T - b.T;
  const dP = a.P - b.P;
  return 720 * Math.sqrt(dI * dI + 0.25 * dT * dT + dP * dP);
}

function normalizeKeyPart(value) {
  if (value == null) return '';
  const n = Number(value);
  if (Number.isFinite(n)) return fmt(n);
  return String(value).trim().toLowerCase();
}

function codeFor(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n) : null;
}

function stepKeys(stepRow) {
  const keys = new Set();
  const name = normalizeKeyPart(stepRow.name);
  const ire = normalizeKeyPart(stepRow.ire);
  const codes = [stepRow.autocal_code, stepRow.code, stepRow.r_code, stepRow.g_code, stepRow.b_code, stepRow.r, stepRow.g, stepRow.b]
    .map(codeFor)
    .filter(code => code != null);
  if (ire && codes.length) {
    for (const code of codes) keys.add(`ire-code:${ire}:${code}`);
  }
  if (name && codes.length) {
    for (const code of codes) keys.add(`name-code:${name}:${code}`);
  }
  if (ire) keys.add(`ire:${ire}`);
  if (name) keys.add(`name:${name}`);
  for (const code of codes) keys.add(`code:${code}`);
  return keys;
}

function readingKeys(reading) {
  const keys = new Set();
  const name = normalizeKeyPart(reading.name);
  const ire = normalizeKeyPart(reading.ire);
  const codes = [reading.autocal_code, reading.code, reading.r_code, reading.g_code, reading.b_code, reading.r, reading.g, reading.b]
    .map(codeFor)
    .filter(code => code != null);
  if (ire && codes.length) {
    for (const code of codes) keys.add(`ire-code:${ire}:${code}`);
  }
  if (name && codes.length) {
    for (const code of codes) keys.add(`name-code:${name}:${code}`);
  }
  if (ire) keys.add(`ire:${ire}`);
  if (name) keys.add(`name:${name}`);
  for (const code of codes) keys.add(`code:${code}`);
  return keys;
}

function buildStepLookup(steps) {
  const lookup = new Map();
  for (const stepRow of steps || []) {
    for (const key of stepKeys(stepRow)) {
      if (!lookup.has(key)) lookup.set(key, stepRow);
    }
  }
  return lookup;
}

function findMatchingStep(reading, stepLookup) {
  for (const key of readingKeys(reading)) {
    const match = stepLookup.get(key);
    if (match) return match;
  }
  return null;
}

function enrichSeriesReadings(readings, steps) {
  const stepLookup = buildStepLookup(steps);
  return (readings || []).map(reading => {
    if (!reading) return reading;
    const matchedStep = findMatchingStep(reading, stepLookup);
    if (!matchedStep) return reading;
    const enriched = { ...reading };
    const fields = [
      'target_x',
      'target_y',
      'target_Yn',
      'stimulus',
      'signal_r_pct',
      'signal_g_pct',
      'signal_b_pct',
      'r',
      'g',
      'b',
      'r_code',
      'g_code',
      'b_code',
      'autocal_code',
      'code'
    ];
    for (const field of fields) {
      if (matchedStep[field] != null) enriched[field] = matchedStep[field];
    }
    return enriched;
  });
}

function deriveReferenceFrom109Reading(readings, fallbackReferenceY) {
  const reading109 = (readings || []).find(row => {
    const ire = Number(row && row.ire);
    const code = codeFor(row && (row.autocal_code ?? row.code ?? row.r_code ?? row.g_code ?? row.b_code ?? row.r ?? row.g ?? row.b));
    return Math.abs(ire - 109) < 0.01 || code === 1023 || String(row && row.name || '').trim() === '109%';
  });
  const measuredY = Number(reading109 && (reading109.luminance ?? reading109.Y));
  const targetYn = Number(reading109 && reading109.target_Yn);
  if (Number.isFinite(measuredY) && measuredY > 0 && Number.isFinite(targetYn) && targetYn > 0) {
    return measuredY / targetYn;
  }
  return fallbackReferenceY;
}

function summarizeReadings(readings, referenceY, options = {}) {
  const rows = (readings || []).filter(r => r && r.ire != null && (r.luminance != null || r.Y != null)).map(r => {
    const ire = Number(r.ire);
    const stimulus = Number(r.stimulus ?? r.signal_g_pct ?? ire);
    const targetYn = Number(r.target_Yn);
    const targetY = (options.useStepTargets && Number.isFinite(targetYn) && targetYn > 0 ? referenceY * targetYn : null) ||
      Number(r.target_luminance ?? r.lg_target_white_y ?? r.series_target_white_y) ||
      (ire >= 99.999 ? referenceY : referenceY * targetGammaLinear(stimulus / 100));
    const targetWhite = options.useStepTargets ? { x: r.target_x, y: r.target_y } : null;
    const dE = Number(r.delta_e_itp_y ?? r.delta_e_itp ?? r.delta_e ?? r.de_itp_y ?? r.deitp) || deltaEItpY(r, targetY, targetWhite);
    const row = {
      ire,
      name: r.name,
      stimulus,
      r_code: r.r_code ?? r.r,
      g_code: r.g_code ?? r.g,
      b_code: r.b_code ?? r.b,
      x: r.x,
      y: r.y,
      Y: Number(r.luminance ?? r.Y),
      targetY,
      deltaEItpY: Number.isFinite(dE) ? dE : null,
      settings: r.settings || r.adjustments || null
    };
    if (options.includeStepMetadata) {
      row.target_x = r.target_x;
      row.target_y = r.target_y;
      row.target_Yn = r.target_Yn;
      row.signal_r_pct = r.signal_r_pct;
      row.signal_g_pct = r.signal_g_pct;
      row.signal_b_pct = r.signal_b_pct;
      row.autocal_code = r.autocal_code;
      row.code = r.code;
    }
    return row;
  });
  const valid = rows.filter(r => r.deltaEItpY != null && r.ire > 0 && !r.name?.match(/target white/i));
  const avg = valid.length ? valid.reduce((sum, r) => sum + r.deltaEItpY, 0) / valid.length : null;
  const max = valid.reduce((best, r) => !best || r.deltaEItpY > best.deltaEItpY ? r : best, null);
  return { referenceY, avgDeltaEItpY: avg, maxDeltaEItpY: max, over1: valid.filter(r => r.deltaEItpY > 1), rows };
}

function csvForRows(rows) {
  const header = ['ire', 'name', 'stimulus', 'r_code', 'g_code', 'b_code', 'x', 'y', 'Y', 'targetY', 'deltaEItpY'];
  const lines = [header.join(',')];
  for (const row of rows) {
    lines.push(header.map(k => JSON.stringify(row[k] ?? '')).join(','));
  }
  return `${lines.join('\n')}\n`;
}

async function main() {
  mkdir();
  save('run-info.json', { apiBase, outDir, started_at: new Date().toISOString() });
  await cleanup('initial');

  const targetWhite = await readTargetWhite();
  await api('/api/pattern', { method: 'POST', body: { name: 'stop' }, timeoutMs: 10000 }).catch(() => null);
  await resetDdc();

  const setupY = targetWhite.y;
  const headroomY = setupY * Math.pow((1023 - 64) / 876, 2.4);
  save('computed-luminance.json', { setupY, headroomY, formula: 'setupY * ((1023-64)/876)^2.4' });

  const autocalPayload = {
    ...basePayload(),
    patch_insert: true,
    type: 'greyscale',
    points: 26,
    target_luminance: setupY,
    setup_luminance_reference: setupY,
    headroom_target_luminance: headroomY,
    delta_e_formula: 'deitp',
    target_delta_e: targetDeltaE,
    lg_autocal_26: true,
    lg_extended_sdr_16_255: true,
    force_ddc_white_balance: true,
    reset_ddc_baseline: false,
    restore_factory_levels: false,
    max_iterations: 36,
    headroom_max_iterations: 60,
    full_workflow: false,
    steps: buildAutocalSteps()
  };
  if (postCommitPolish !== undefined) autocalPayload.post_commit_polish = postCommitPolish;
  save('payload.json', autocalPayload);
  const autocalStartTime = Date.now();
  const start = await api('/api/meter/lg-autocal', { method: 'POST', body: autocalPayload, timeoutMs: 30000 });
  save('start.json', start);
  if (!start || start.status !== 'started') throw new Error(`AutoCal did not start: ${JSON.stringify(start)}`);
  const autocalStatus = await poll('/api/meter/lg-autocal/status', 'status-stream.jsonl', 'latest-status.json', 'autocal');
  const autocalEndTime = Date.now();
  save('final-status.json', autocalStatus);
  save('status.json', autocalStatus);
  if (autocalStatus.status !== 'complete') throw new Error(`AutoCal ended as ${autocalStatus.status}`);

  const calibratedReferenceY = Number(autocalStatus.target_luminance || autocalStatus.calibrated_white_luminance || setupY);
  const headroomReferenceY = Number(autocalStatus.headroom_target_luminance || headroomY);
  const autocalSummary = summarizeReadings(autocalStatus.readings || [], calibratedReferenceY);
  save('autocal-summary.json', autocalSummary);
  save('autocal-readings.csv', csvForRows(autocalSummary.rows));

  const seriesPayload = {
    ...basePayload(),
    type: 'greyscale',
    points: 26,
    patch_insert: false,
    lg_autocal_26: true,
    lg_extended_sdr_16_255: true,
    delta_e_formula: 'deitp',
    series_target_white_y: calibratedReferenceY,
    lg_target_white_y: calibratedReferenceY,
    headroom_target_luminance: headroomReferenceY
  };
  save('post-series-payload.json', seriesPayload);
  const seriesStart = await api('/api/meter/series', { method: 'POST', body: seriesPayload, timeoutMs: 30000 });
  save('post-series-start.json', seriesStart);
  if (!seriesStart || seriesStart.status !== 'started') throw new Error(`Series did not start: ${JSON.stringify(seriesStart)}`);
  const seriesStatus = await poll('/api/meter/series/status', 'post-series-status-stream.jsonl', 'post-series-status.json', 'series');
  save('post-series-final-status.json', seriesStatus);
  const enrichedSeriesReadings = enrichSeriesReadings(seriesStatus.readings || [], seriesStatus.steps || []);
  save('post-series-readings.json', enrichedSeriesReadings);
  const postSeries109ReferenceY = deriveReferenceFrom109Reading(enrichedSeriesReadings, calibratedReferenceY);
  const seriesSummary109Reference = summarizeReadings(enrichedSeriesReadings, postSeries109ReferenceY, {
    includeStepMetadata: true,
    useStepTargets: true
  });
  const seriesSummaryCalibratedReference = summarizeReadings(enrichedSeriesReadings, calibratedReferenceY, {
    includeStepMetadata: true,
    useStepTargets: true
  });
  save('post-series-summary.json', seriesSummary109Reference);
  save('post-series-summary-109-reference.json', seriesSummary109Reference);
  save('post-series-summary-calibrated-reference.json', seriesSummaryCalibratedReference);
  save('post-series-readings.csv', csvForRows(seriesSummary109Reference.rows));
  save('post-series-readings-calibrated-reference.csv', csvForRows(seriesSummaryCalibratedReference.rows));
  if (seriesStatus.status !== 'complete') throw new Error(`Series ended as ${seriesStatus.status}`);

  await cleanup('final');
  const summary = {
    artifact_path: outDir,
    status: 'complete',
    started_at: new Date(autocalStartTime).toISOString(),
    completed_at: new Date().toISOString(),
    autocal_duration_ms: autocalEndTime - autocalStartTime,
    target_white_Y: setupY,
    calibrated_reference_Y: calibratedReferenceY,
    headroom_reference_Y: headroomReferenceY,
    post_series_reference_Y: postSeries109ReferenceY,
    post_series_109_reference_Y: postSeries109ReferenceY,
    post_series_calibrated_reference_Y: calibratedReferenceY,
    post_read_reference: {
      passed_series_target_white_y: calibratedReferenceY,
      passed_lg_target_white_y: calibratedReferenceY,
      measured_white_first: true,
      applied_109_derived_reference: postSeries109ReferenceY !== calibratedReferenceY,
      calibrated_reference_summary: true
    },
    autocal: autocalSummary,
    post_series: seriesSummary109Reference,
    post_series_109_reference: seriesSummary109Reference,
    post_series_calibrated_reference: seriesSummaryCalibratedReference
  };
  save('summary.json', summary);
  console.log(`complete ${outDir}`);
}

main().catch(async error => {
  save('error.json', { message: error.message, stack: error.stack, at: new Date().toISOString() });
  await cleanup('error-final').catch(() => null);
  console.error(error.stack || error.message);
  process.exit(1);
});

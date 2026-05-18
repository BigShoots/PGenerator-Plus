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

function xyToUvPrime(x, y) {
  const den = (-2 * x) + (12 * y) + 3;
  if (!Number.isFinite(den) || Math.abs(den) < 1e-12) return [0, 0];
  return [(4 * x) / den, (9 * y) / den];
}

function deltaEItpY(reading, targetY) {
  const x = Number(reading && reading.x);
  const y = Number(reading && reading.y);
  const Y = Number(reading && (reading.luminance ?? reading.Y));
  const ty = Number(targetY);
  if (![x, y, Y, ty].every(Number.isFinite) || y <= 0 || ty <= 0) return null;
  const [u, v] = xyToUvPrime(x, y);
  const [tu, tv] = xyToUvPrime(0.3127, 0.3290);
  const chroma = Math.sqrt((u - tu) ** 2 + (v - tv) ** 2) * 720;
  const luma = Math.abs(Math.log(Math.max(Y, 0.0001) / ty)) * 100;
  return Math.sqrt(chroma ** 2 + luma ** 2);
}

function summarizeReadings(readings, referenceY) {
  const rows = (readings || []).filter(r => r && r.ire != null && (r.luminance != null || r.Y != null)).map(r => {
    const ire = Number(r.ire);
    const stimulus = Number(r.stimulus ?? r.signal_g_pct ?? ire);
    const targetY = Number(r.target_luminance ?? r.lg_target_white_y ?? r.series_target_white_y) ||
      (ire >= 99.999 ? referenceY : referenceY * targetGammaLinear(stimulus / 100));
    const dE = Number(r.delta_e_itp_y ?? r.delta_e_itp ?? r.delta_e ?? r.de_itp_y ?? r.deitp) || deltaEItpY(r, targetY);
    return {
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
  save('post-series-readings.json', seriesStatus.readings || []);
  const seriesSummary = summarizeReadings(seriesStatus.readings || [], calibratedReferenceY);
  save('post-series-summary.json', seriesSummary);
  save('post-series-readings.csv', csvForRows(seriesSummary.rows));
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
    post_read_reference: {
      passed_series_target_white_y: calibratedReferenceY,
      passed_lg_target_white_y: calibratedReferenceY,
      measured_white_first: true,
      applied_109_derived_reference: Number.isFinite(headroomReferenceY) && headroomReferenceY > 0
    },
    autocal: autocalSummary,
    post_series: seriesSummary
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

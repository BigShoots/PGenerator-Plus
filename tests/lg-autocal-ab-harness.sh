#!/usr/bin/env bash
# tests/lg-autocal-ab-harness.sh <label>
# Runs greyscale-only LG AutoCal against the Pi and saves comparable artifacts.

set -euo pipefail

LABEL="${1:?usage: $0 <label>}"
PI="${PI_HOST:-192.168.1.177}"
PI_PASS="${PI_PASS:-}"
if [ -z "$PI_PASS" ]; then
  PI_PASS='PGenerator!!$'
fi
PICTURE_MODE="${PICTURE_MODE:-cinema}"
OUT="tmp/ab-${LABEL}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

cleanup() {
  curl -s --max-time 10 -X POST "http://$PI/api/meter/lg-autocal/stop" >/dev/null || true
  curl -s --max-time 10 -X POST "http://$PI/api/meter/stop" >/dev/null || true
  curl -s --max-time 10 -X POST "http://$PI/api/meter/session/stop" >/dev/null || true
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d '{"name":"stop"}' "http://$PI/api/pattern" >/dev/null || true
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"enabled\":false,\"picture_mode\":\"$PICTURE_MODE\"}" \
    "http://$PI/api/lg/calibration-mode" >/dev/null || true
}
trap cleanup EXIT

cleanup
if command -v sshpass >/dev/null 2>&1; then
  sshpass -p "$PI_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@$PI" "rm -f /var/log/PGenerator/lg-autocal-109-trace.log /tmp/meter_lg_autocal.log" >/dev/null 2>&1 || true
fi

node - "$LABEL" "$PI" "$PICTURE_MODE" "$OUT" "$PI_PASS" <<'NODE'
'use strict';

const fs = require('fs');
const { execFileSync } = require('child_process');

const [label, pi, pictureMode, outDir, piPass] = process.argv.slice(2);
const base = `http://${pi}`;
const displayType = process.env.PROFILE || 'ccss_LG_C2_(WRGB_OLED)_-_JETI_1501_HiRes_2nm.ccss';
const patchSize = Number(process.env.PATCH_SIZE || 10);
const delayMs = Number(process.env.DELAY_MS || 500);
const targetDelta = Number(process.env.TARGET_DELTA_E || 0.5);
const focusIres = (process.env.FOCUS_IRES || process.env.FOCUS_IRE || '')
  .split(',')
  .map(value => Number(value.trim()))
  .filter(value => Number.isFinite(value));

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function writeJson(name, value) {
  fs.writeFileSync(`${outDir}/${name}`, JSON.stringify(value, null, 2));
}

async function request(endpoint, options = {}) {
  const timeoutMs = options.timeoutMs || 30000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const init = { ...options, signal: controller.signal };
    delete init.timeoutMs;
    if (init.body && !init.headers) init.headers = { 'Content-Type': 'application/json' };
    const res = await fetch(`${base}${endpoint}`, init);
    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch (_err) {
      data = { status: res.ok ? 'ok' : 'error', raw: text };
    }
    if (!res.ok) throw new Error(`${endpoint} HTTP ${res.status}: ${text.slice(0, 300)}`);
    return data;
  } finally {
    clearTimeout(timer);
  }
}

function post(endpoint, body, timeoutMs = 30000) {
  return request(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
    timeoutMs,
  });
}

function readRemoteJson(remotePath) {
  const args = [
    '-p',
    piPass,
    'ssh',
    '-o',
    'StrictHostKeyChecking=no',
    '-o',
    'UserKnownHostsFile=/dev/null',
    '-o',
    'LogLevel=ERROR',
    `root@${pi}`,
    `cat ${remotePath} 2>/dev/null || true`,
  ];
  const raw = execFileSync('sshpass', args, { encoding: 'utf8', timeout: 15000 });
  return raw.trim() ? JSON.parse(raw) : null;
}

async function cleanup() {
  await Promise.all([
    post('/api/meter/lg-autocal/stop', {}, 7000).catch(() => null),
    post('/api/meter/stop', {}, 7000).catch(() => null),
    post('/api/meter/session/stop', {}, 7000).catch(() => null),
    post('/api/pattern', { name: 'stop' }, 7000).catch(() => null),
    post('/api/lg/calibration-mode', { enabled: false, picture_mode: pictureMode }, 7000).catch(() => null),
  ]);
}

function measurementPayload(extra = {}) {
  return {
    display_type: displayType,
    delay_ms: delayMs,
    patch_size: patchSize,
    signal_range: '1',
    pattern_signal_range: '1',
    transport_signal_range: '1',
    target_gamut: 'bt709',
    target_gamma: 'bt1886',
    picture_mode: pictureMode,
    require_device_ready: false,
    patch_insert: true,
    ...extra,
  };
}

function luminance(reading) {
  const y = Number(reading && (reading.luminance ?? reading.Y));
  return Number.isFinite(y) ? y : NaN;
}

function buildGreyscale26Steps() {
  const steps = [{
    name: '100%',
    ire: 100,
    stimulus: 100,
    r: 940,
    g: 940,
    b: 940,
    input_max: 1023,
    preview_r: 235,
    preview_g: 235,
    preview_b: 235,
    signal_r_pct: 100,
    signal_g_pct: 100,
    signal_b_pct: 100,
    series_type: 'greyscale',
    series_mode: 'lg-autocal-26',
    autocal_code: 940,
    autocal_slot_locked: true,
    ddc_slot_locked: true,
    autocal_white_reference: true,
    autocal_reference_only: true,
    autocal_read_only: true,
    autocal_legal_white_anchor: true,
    ddc_target_ire: 99,
    autocal_order_ire: 98.95,
    autocal_target_label: '100% legal white',
  }];
  const codes = [
    [0, 64, true],
    [2.3, 84],
    [3, 92],
    [4, 100],
    [5, 108],
    [7, 124],
    [10, 152],
    [15, 196],
    [20, 240],
    [25, 284],
    [30, 328],
    [35, 372],
    [40, 416],
    [45, 460],
    [50, 504],
    [55, 544],
    [60, 588],
    [65, 632],
    [70, 676],
    [75, 720],
    [80, 764],
    [85, 808],
    [90, 852],
    [95, 896],
    [99, 932],
    [105, 984],
    [109, 1023],
  ];
  for (const [ire, code, readOnly] of codes) {
    const stimulus = ire === 0 ? 0 : ((code - 64) * 100 / 876);
    const preview = Math.max(0, Math.min(255, Math.round(code / 1023 * 255)));
    const step = {
      name: `${ire}%`,
      ire,
      stimulus,
      r: code,
      g: code,
      b: code,
      input_max: 1023,
      preview_r: preview,
      preview_g: preview,
      preview_b: preview,
      signal_r_pct: stimulus,
      signal_g_pct: stimulus,
      signal_b_pct: stimulus,
      series_type: 'greyscale',
      series_mode: 'lg-autocal-26',
      autocal_code: code,
      autocal_slot_locked: ire !== 0,
      ddc_slot_locked: ire !== 0,
    };
    if (readOnly) {
      step.autocal_read_only = true;
      step.autocal_slot_locked = false;
      step.ddc_slot_locked = false;
    }
    if (ire === 99) step.legal_white_pair_active = true;
    steps.push(step);
  }
  return steps;
}

function selectedGreyscale26Steps() {
  const steps = buildGreyscale26Steps();
  if (!focusIres.length) return steps;
  const focused = steps.filter(step => {
    if (!step || step.autocal_white_reference) return false;
    return focusIres.some(ire => Math.abs(Number(step.ire) - ire) < 0.001);
  });
  if (focused.length !== focusIres.length) {
    throw new Error(`Only matched ${focused.length}/${focusIres.length} requested LG 26-point greyscale focus steps`);
  }
  return focused;
}

function headroomRatio() {
  const stimulus109 = (1023 - 64) * 100 / 876;
  return Math.pow(stimulus109 / 100, 2.4);
}

async function readTargetWhite() {
  const requestId = `${label}-target-white-${Date.now().toString(36)}`;
  const payload = measurementPayload({
    patch_r: 940,
    patch_g: 940,
    patch_b: 940,
    patch_input_max: 1023,
    patch_ire: 100,
    patch_name: '100% target white',
    delay_ms: 1800,
    request_id: requestId,
    read_timeout: 220,
  });
  const started = await post('/api/meter/read', payload, 180000);
  writeJson('target-white-start.json', started);
  const deadline = Date.now() + 260000;
  while (Date.now() < deadline) {
    const result = await request('/api/meter/read/result', { timeoutMs: 10000 });
    if (result.awaiting_ready) {
      await post('/api/meter/read/ready', {}, 10000);
    }
    if (result.status === 'ok' || result.status === 'complete') {
      const reading = (Array.isArray(result.readings) && result.readings[0]) || result.reading || result;
      writeJson('target-white-read.json', reading);
      return reading;
    }
    if (result.status === 'error') throw new Error(result.message || 'target white read failed');
    await sleep(1000);
  }
  throw new Error('Timed out waiting for target white read');
}

async function resetDdc() {
  const zero = Array.from({ length: 26 }, () => 0);
  const result = await post('/api/lg/picture-settings/set', {
    settings: {
      whiteBalanceMethod: '22',
      whiteBalanceIre: '109',
      whiteBalanceRed: zero,
      whiteBalanceGreen: zero,
      whiteBalanceBlue: zero,
      adjustingLuminance: zero,
    },
    picture_mode: pictureMode,
    reset_ddc_baseline: true,
    force_ddc_white_balance: true,
    helper_timeout: 170,
    readback_keys: [
      'pictureMode',
      'whiteBalanceMethod',
      'whiteBalanceIre',
      'whiteBalanceRed',
      'whiteBalanceGreen',
      'whiteBalanceBlue',
      'adjustingLuminance',
    ],
  }, 190000);
  writeJson('reset-ddc.json', result);
  if (result.status !== 'ok') throw new Error(result.message || 'DDC reset failed');
}

async function runGreyscale(setupY) {
  const targetY = Math.max(10, Math.min(10000, setupY));
  const headroomY = Math.max(10, Math.min(10000, setupY * headroomRatio()));
  const payload = measurementPayload({
    type: 'greyscale',
    points: 26,
    lg_greyscale_21: false,
    lg_autocal_26: true,
    lg_extended_sdr_16_255: true,
    target_delta_e: targetDelta,
    delta_e_formula: 'deitp',
    target_luminance: targetY,
    setup_luminance_reference: setupY,
    headroom_target_luminance: headroomY,
    target_white: { x: 0.3127, y: 0.3290 },
    force_ddc_white_balance: true,
    full_workflow: false,
    full_autocal_run_id: label,
    steps: selectedGreyscale26Steps(),
  });
  writeJson('payload.json', payload);
  const started = await post('/api/meter/lg-autocal', payload, 12000);
  writeJson('start.json', started);
  if (started.status !== 'started') throw new Error(started.message || 'LG AutoCal did not start');

  await sleep(2500);
  const snapshots = [];
  while (true) {
    const status = readRemoteJson('/tmp/meter_lg_autocal.json');
    if (!status) {
      await sleep(1000);
      continue;
    }
    snapshots.push({
      at: Date.now(),
      status: status.status,
      phase: status.phase,
      current_step: status.current_step,
      total_steps: status.total_steps,
      current_name: status.current_name,
      message: status.message,
      current_delta_e: status.current_delta_e,
      best_delta_e: status.best_delta_e,
      current_luminance: status.current_luminance,
      calibration_mode: status.calibration_mode,
    });
    fs.appendFileSync(`${outDir}/status-stream.jsonl`, JSON.stringify(status) + '\n');
    if (status.status === 'complete') {
      writeJson('status.json', status);
      writeJson('status-snapshots.json', snapshots);
      return;
    }
    if (status.status === 'error' || status.status === 'cancelled') {
      writeJson('status.json', status);
      writeJson('status-snapshots.json', snapshots);
      throw new Error(`LG AutoCal ${status.status}: ${status.message || 'unknown error'}`);
    }
    await sleep(5000);
  }
}

(async () => {
  await cleanup();
  await post('/api/lg/calibration-mode', { enabled: true, picture_mode: pictureMode }, 30000)
    .then(r => writeJson('calmode.json', r));
  const targetWhite = await readTargetWhite();
  const setupY = luminance(targetWhite);
  if (!(setupY > 0)) throw new Error('Target white read did not return luminance');
  await resetDdc();
  await runGreyscale(setupY);
})().catch(async err => {
  writeJson('error.json', { status: 'error', message: err && err.message ? err.message : String(err), stack: err && err.stack });
  await cleanup();
  process.exitCode = 1;
});
NODE

if command -v sshpass >/dev/null 2>&1; then
  sshpass -p "$PI_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@$PI" "cat /var/log/PGenerator/lg-autocal-109-trace.log 2>/dev/null || true" > "$OUT/trace.jsonl" || true
fi

echo "ARTIFACTS: $OUT"

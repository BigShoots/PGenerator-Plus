#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const baseUrl = process.env.PGEN_URL || 'http://192.168.1.179';
const stamp = new Date().toISOString().replace(/[-:T]/g, '').replace(/\..+/, '');
const outDir = process.env.PGEN_OUT_DIR || 'tmp';

function envBool(name, fallback) {
  const value = process.env[name];
  if (value == null || value === '') return fallback;
  return /^(1|true|yes|on)$/i.test(String(value));
}

function envNumber(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) ? value : fallback;
}

const config = {
  display_type: process.env.PGEN_DISPLAY_TYPE || 'oled_generic',
  patch_size: envNumber('PGEN_PATCH_SIZE', 10),
  delay_ms: envNumber('PGEN_DELAY_MS', 2500),
  picture_mode: process.env.PGEN_PICTURE_MODE || 'cinema',
  target_gamma: process.env.PGEN_TARGET_GAMMA || 'bt1886',
  method: (process.env.PGEN_METHOD || 'matrix').toLowerCase(),
  upload: envBool('PGEN_UPLOAD', false),
  allow_tv_write: envBool('PGEN_ALLOW_TV_WRITE', false),
  run_baseline: envBool('PGEN_RUN_BASELINE', true),
  run_3d: envBool('PGEN_RUN_3D', true),
  run_post: envBool('PGEN_RUN_POST', true),
  run_greyscale: envBool('PGEN_RUN_GREYSCALE', true),
  reset_3d: envBool('PGEN_RESET_3D', false),
  patch_insert: envBool('PGEN_PATCH_INSERT', false),
  require_device_ready: envBool('PGEN_REQUIRE_READY', false),
  autocal_post_check: envBool('PGEN_AUTOCAL_POST_CHECK', false),
  dry_run: envBool('PGEN_DRY_RUN', false),
  poll_ms: envNumber('PGEN_POLL_MS', 5000),
  series_timeout_ms: envNumber('PGEN_SERIES_TIMEOUT_MS', 90 * 60 * 1000),
  autocal_timeout_ms: envNumber('PGEN_AUTOCAL_TIMEOUT_MS', 4 * 60 * 60 * 1000),
  mean_improvement_threshold_pct: envNumber('PGEN_MEAN_IMPROVEMENT_THRESHOLD_PCT', 20),
  max_regression_allowed_pct: envNumber('PGEN_MAX_REGRESSION_ALLOWED_PCT', 10),
  color_checker_max_de_limit: envNumber('PGEN_COLORCHECKER_MAX_DE_LIMIT', 3.0),
  saturation_max_de_limit: envNumber('PGEN_SATURATION_MAX_DE_LIMIT', 3.5),
  greyscale_max_de_limit: envNumber('PGEN_GREYSCALE_MAX_DE_LIMIT', 1.5),
  greyscale_mean_regression_limit: envNumber('PGEN_GREYSCALE_MEAN_REGRESSION_LIMIT', 0.2),
  greyscale_max_regression_limit: envNumber('PGEN_GREYSCALE_MAX_REGRESSION_LIMIT', 0.5)
};

if (!['ramp', 'matrix'].includes(config.method)) {
  throw new Error(`PGEN_METHOD must be ramp or matrix, got ${config.method}`);
}

if ((config.upload || config.reset_3d) && !config.allow_tv_write) {
  throw new Error('TV writes are guarded. Set PGEN_ALLOW_TV_WRITE=1 with PGEN_UPLOAD=1 or PGEN_RESET_3D=1.');
}

const BT709 = {
  white: { x: 0.3127, y: 0.3290 },
  rgbToXyz: [
    [0.4123907993, 0.3575843394, 0.1804807884],
    [0.2126390059, 0.7151686788, 0.0721923154],
    [0.0193308187, 0.1191947798, 0.9505321522]
  ]
};

function clamp(value, min = 0, max = 1) {
  const number = Number(value);
  if (!Number.isFinite(number)) return min;
  return Math.max(min, Math.min(max, number));
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
      throw new Error(`${endpoint} returned non-JSON: ${text.slice(0, 240)}`);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function save(name, value) {
  fs.mkdirSync(outDir, { recursive: true });
  const file = path.join(outDir, name);
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
  return file;
}

function fmtPct(value) {
  if (value == null || !Number.isFinite(Number(value))) return 'n/a';
  return `${Number(value).toFixed(1)}%`;
}

function fmtDe(value) {
  if (value == null || !Number.isFinite(Number(value))) return 'n/a';
  return Number(value).toFixed(2);
}

function targetGammaSignalToLinear(signal) {
  const s = clamp(signal);
  if (s <= 0) return 0;
  if (config.target_gamma === 'srgb') {
    return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  }
  const gamma = config.target_gamma === '2.2' ? 2.2 : 2.4;
  return Math.pow(s, gamma);
}

function xyzFromXyY(x, y, Y) {
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(Y) || y <= 0) return null;
  return [
    (x / y) * Y,
    Y,
    ((1 - x - y) / y) * Y
  ];
}

function measuredWhiteY(seriesStatus) {
  const white = seriesStatus.white_reading
    || (seriesStatus.readings || []).find(reading => String(reading.name || '').toLowerCase() === 'white')
    || (seriesStatus.readings || []).filter(reading => Number(reading.luminance ?? reading.Y) > 0)
      .sort((a, b) => Number(b.luminance ?? b.Y) - Number(a.luminance ?? a.Y))[0];
  const Y = Number(white && (white.luminance ?? white.Y));
  return Number.isFinite(Y) && Y > 0 ? Y : 100;
}

function measuredBlackXyz(seriesStatus) {
  const readings = seriesStatus.readings || [];
  const black = seriesStatus.black_reading
    || readings.find(reading => String(reading.name || '').toLowerCase() === 'black')
    || readings.find(reading => Number(reading.ire) === 0);
  if (!black) return null;
  const X = Number(black.X);
  const Y = Number(black.Y ?? black.luminance);
  const Z = Number(black.Z);
  if (Number.isFinite(X) && Number.isFinite(Y) && Number.isFinite(Z) && Y >= 0) return [X, Y, Z];
  const x = Number(black.x);
  const y = Number(black.y);
  return xyzFromXyY(x, y, Y);
}

function readingXyz(reading) {
  if (!reading || reading.error) return null;
  const X = Number(reading.X);
  const Y = Number(reading.Y ?? reading.luminance);
  const Z = Number(reading.Z);
  if (Number.isFinite(X) && Number.isFinite(Y) && Number.isFinite(Z) && Y > 0) return [X, Y, Z];
  const x = Number(reading.x);
  const y = Number(reading.y);
  return xyzFromXyY(x, y, Y);
}

function referenceWhiteXyz(whiteY) {
  return xyzFromXyY(BT709.white.x, BT709.white.y, whiteY);
}

function labPivot(value) {
  return value > 216 / 24389 ? Math.cbrt(value) : ((24389 / 27) * value + 16) / 116;
}

function xyzToLab(xyz, whiteXyz) {
  const fx = labPivot(xyz[0] / whiteXyz[0]);
  const fy = labPivot(xyz[1] / whiteXyz[1]);
  const fz = labPivot(xyz[2] / whiteXyz[2]);
  return [(116 * fy) - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

function deltaE2000(lab1, lab2) {
  const [L1, a1, b1] = lab1;
  const [L2, a2, b2] = lab2;
  const kL = 1;
  const kC = 1;
  const kH = 1;
  const c1 = Math.sqrt(a1 * a1 + b1 * b1);
  const c2 = Math.sqrt(a2 * a2 + b2 * b2);
  const cBar = (c1 + c2) / 2;
  const cBar7 = Math.pow(cBar, 7);
  const g = 0.5 * (1 - Math.sqrt(cBar7 / (cBar7 + Math.pow(25, 7))));
  const ap1 = (1 + g) * a1;
  const ap2 = (1 + g) * a2;
  const cp1 = Math.sqrt(ap1 * ap1 + b1 * b1);
  const cp2 = Math.sqrt(ap2 * ap2 + b2 * b2);
  const hp1 = hueDegrees(b1, ap1);
  const hp2 = hueDegrees(b2, ap2);
  const dLp = L2 - L1;
  const dCp = cp2 - cp1;
  let dhp = hp2 - hp1;
  if (cp1 * cp2 === 0) dhp = 0;
  else if (dhp > 180) dhp -= 360;
  else if (dhp < -180) dhp += 360;
  const dHp = 2 * Math.sqrt(cp1 * cp2) * Math.sin(degToRad(dhp / 2));
  const LpBar = (L1 + L2) / 2;
  const CpBar = (cp1 + cp2) / 2;
  let hpBar;
  if (cp1 * cp2 === 0) hpBar = hp1 + hp2;
  else if (Math.abs(hp1 - hp2) <= 180) hpBar = (hp1 + hp2) / 2;
  else if ((hp1 + hp2) < 360) hpBar = (hp1 + hp2 + 360) / 2;
  else hpBar = (hp1 + hp2 - 360) / 2;
  const T = 1
    - 0.17 * Math.cos(degToRad(hpBar - 30))
    + 0.24 * Math.cos(degToRad(2 * hpBar))
    + 0.32 * Math.cos(degToRad((3 * hpBar) + 6))
    - 0.20 * Math.cos(degToRad((4 * hpBar) - 63));
  const deltaTheta = 30 * Math.exp(-Math.pow((hpBar - 275) / 25, 2));
  const rc = 2 * Math.sqrt(Math.pow(CpBar, 7) / (Math.pow(CpBar, 7) + Math.pow(25, 7)));
  const sl = 1 + (0.015 * Math.pow(LpBar - 50, 2)) / Math.sqrt(20 + Math.pow(LpBar - 50, 2));
  const sc = 1 + 0.045 * CpBar;
  const sh = 1 + 0.015 * CpBar * T;
  const rt = -Math.sin(degToRad(2 * deltaTheta)) * rc;
  const l = dLp / (kL * sl);
  const c = dCp / (kC * sc);
  const h = dHp / (kH * sh);
  return Math.sqrt((l * l) + (c * c) + (h * h) + (rt * c * h));
}

function hueDegrees(y, x) {
  if (x === 0 && y === 0) return 0;
  const h = radToDeg(Math.atan2(y, x));
  return h >= 0 ? h : h + 360;
}

function degToRad(deg) {
  return deg * Math.PI / 180;
}

function radToDeg(rad) {
  return rad * 180 / Math.PI;
}

function stepByName(steps) {
  const out = new Map();
  for (const step of steps || []) {
    if (!step || step.name == null) continue;
    out.set(String(step.name), step);
    out.set(String(step.name).toLowerCase(), step);
  }
  return out;
}

function findStep(reading, steps, nameMap) {
  if (!reading) return null;
  const byExact = nameMap.get(String(reading.name || '')) || nameMap.get(String(reading.name || '').toLowerCase());
  if (byExact) return byExact;
  const ire = Number(reading.ire);
  if (!Number.isFinite(ire)) return null;
  return (steps || []).find(step => Math.abs(Number(step.ire) - ire) < 0.001 && String(step.name || '') === String(reading.name || ''))
    || (steps || []).find(step => Math.abs(Number(step.ire) - ire) < 0.001);
}

function codeToSignal(step, channel) {
  const code = Number(step[channel]);
  const inputMax = Number(step.input_max || 255);
  if (inputMax >= 1023) return clamp((code - 64) / 876);
  return clamp((code - 16) / 219);
}

function bt1886LuminanceY(signal, whiteY, blackY) {
  const s = clamp(signal);
  const Lw = Number.isFinite(whiteY) && whiteY > 0 ? whiteY : 100;
  let Lb = Number.isFinite(blackY) && blackY >= 0 ? blackY : 0;
  if (Lb >= Lw) Lb = 0;
  const gamma = 2.4;
  return Math.pow((Math.pow(Lw, 1 / gamma) - Math.pow(Lb, 1 / gamma)) * s + Math.pow(Lb, 1 / gamma), gamma);
}

function bt1886RelativeLuminance(signal, whiteY, blackY) {
  const range = whiteY - blackY;
  if (range <= 1e-9) return targetGammaSignalToLinear(signal);
  return clamp((bt1886LuminanceY(signal, whiteY, blackY) - blackY) / range);
}

function bt709RgbToXyz(r, g, b, whiteY) {
  return [
    (BT709.rgbToXyz[0][0] * r + BT709.rgbToXyz[0][1] * g + BT709.rgbToXyz[0][2] * b) * whiteY,
    (BT709.rgbToXyz[1][0] * r + BT709.rgbToXyz[1][1] * g + BT709.rgbToXyz[1][2] * b) * whiteY,
    (BT709.rgbToXyz[2][0] * r + BT709.rgbToXyz[2][1] * g + BT709.rgbToXyz[2][2] * b) * whiteY
  ];
}

function targetFromRgbCodes(step, whiteY, blackXyz) {
  const rs = codeToSignal(step, 'r');
  const gs = codeToSignal(step, 'g');
  const bs = codeToSignal(step, 'b');
  if (config.target_gamma === 'bt1886' && blackXyz) {
    const blackY = Number(blackXyz[1]) || 0;
    let range = whiteY - blackY;
    if (range <= 1e-9) range = whiteY;
    const target = bt709RgbToXyz(
      bt1886RelativeLuminance(rs, whiteY, blackY),
      bt1886RelativeLuminance(gs, whiteY, blackY),
      bt1886RelativeLuminance(bs, whiteY, blackY),
      range
    );
    return {
      xyz: [
        blackXyz[0] + target[0],
        blackXyz[1] + target[1],
        blackXyz[2] + target[2]
      ],
      source: 'rgb_codes_bt1886_measured_black'
    };
  }
  const r = targetGammaSignalToLinear(codeToSignal(step, 'r'));
  const g = targetGammaSignalToLinear(codeToSignal(step, 'g'));
  const b = targetGammaSignalToLinear(codeToSignal(step, 'b'));
  return { xyz: bt709RgbToXyz(r, g, b, whiteY), source: 'rgb_codes' };
}

function targetForStep(step, whiteY, blackXyz) {
  if (!step) return null;
  const targetX = Number(step.target_x);
  const targetY = Number(step.target_y);
  const targetYn = Number(step.target_Yn);
  if (Number.isFinite(targetX) && Number.isFinite(targetY) && Number.isFinite(targetYn)) {
    return { xyz: xyzFromXyY(targetX, targetY, targetYn * whiteY), source: 'target_Yn' };
  }
  if (step.r != null && step.g != null && step.b != null) return targetFromRgbCodes(step, whiteY, blackXyz);
  return null;
}

function readingLabel(reading, step) {
  return String((step && step.name) || reading.name || `${reading.ire}%`);
}

function summarizeSeries(start, status, type) {
  const steps = status.steps || start.steps || [];
  const readings = status.readings || [];
  const nameMap = stepByName(steps);
  const whiteY = measuredWhiteY(status);
  const blackXyz = measuredBlackXyz(status);
  const whiteXyz = referenceWhiteXyz(whiteY);
  const rows = [];
  const warnings = [];
  for (const reading of readings) {
    const step = findStep(reading, steps, nameMap);
    const actualXyz = readingXyz(reading);
    if (
      type === 'greyscale'
      && config.target_gamma === 'bt1886'
      && step
      && step.target_Yn == null
      && step.r != null
      && step.g != null
      && step.b != null
      && !blackXyz
    ) {
      throw new Error('BT.1886 greyscale summary cannot score RGB-code fallback without a measured black sample.');
    }
    const target = targetForStep(step, whiteY, blackXyz);
    const targetXyz = target && target.xyz;
    const name = readingLabel(reading, step);
    const lowerName = name.toLowerCase();
    if (!actualXyz || !targetXyz || lowerName === 'black' || lowerName === 'white') {
      continue;
    }
    if (target.source === 'rgb_codes' && config.target_gamma === 'bt1886') {
      warnings.push(`BT.1886 ${type} target for ${name} used RGB-code fallback without measured black.`);
    }
    const actualLab = xyzToLab(actualXyz, whiteXyz);
    const targetLab = xyzToLab(targetXyz, whiteXyz);
    const dE = deltaE2000(targetLab, actualLab);
    if (!Number.isFinite(dE)) continue;
    rows.push({
      name,
      ire: Number(reading.ire),
      series_color: step && step.series_color,
      sat_pct: step && step.sat_pct != null ? Number(step.sat_pct) : undefined,
      r_code: Number(reading.r_code ?? (step && step.r)),
      g_code: Number(reading.g_code ?? (step && step.g)),
      b_code: Number(reading.b_code ?? (step && step.b)),
      x: Number(reading.x),
      y: Number(reading.y),
      Y: Number(reading.luminance ?? reading.Y),
      target_X: targetXyz[0],
      target_Y: targetXyz[1],
      target_Z: targetXyz[2],
      target_source: target.source,
      delta_e_2000: Number(dE.toFixed(4))
    });
  }
  const mean = rows.length ? rows.reduce((sum, row) => sum + row.delta_e_2000, 0) / rows.length : null;
  const max = rows.reduce((best, row) => (!best || row.delta_e_2000 > best.delta_e_2000) ? row : best, null);
  return {
    type,
    whiteY: Number(whiteY.toFixed(4)),
    blackY: blackXyz ? Number(blackXyz[1].toFixed(4)) : null,
    warnings: [...new Set(warnings)],
    count: rows.length,
    mean_delta_e_2000: mean == null ? null : Number(mean.toFixed(4)),
    max_delta_e_2000: max ? Number(max.delta_e_2000.toFixed(4)) : null,
    max_name: max ? max.name : null,
    worst5: [...rows].sort((a, b) => b.delta_e_2000 - a.delta_e_2000).slice(0, 5),
    by_color: summarizeBy(rows, row => row.series_color || 'unlabeled'),
    by_saturation: summarizeBy(rows.filter(row => row.sat_pct != null), row => `${row.sat_pct}%`),
    rows
  };
}

function summarizeBy(rows, keyFn) {
  const groups = new Map();
  for (const row of rows) {
    const key = keyFn(row);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  const out = {};
  for (const [key, group] of groups.entries()) {
    const mean = group.reduce((sum, row) => sum + row.delta_e_2000, 0) / group.length;
    const max = group.reduce((best, row) => (!best || row.delta_e_2000 > best.delta_e_2000) ? row : best, null);
    out[key] = {
      count: group.length,
      mean_delta_e_2000: Number(mean.toFixed(4)),
      max_delta_e_2000: Number(max.delta_e_2000.toFixed(4)),
      max_name: max.name
    };
  }
  return out;
}

function compareSummaries(before, after, maxDeltaELimit = null) {
  if (!before || !after || before.mean_delta_e_2000 == null || after.mean_delta_e_2000 == null || before.mean_delta_e_2000 <= 0) {
    return { available: false };
  }
  const meanImprovementPct = ((before.mean_delta_e_2000 - after.mean_delta_e_2000) / before.mean_delta_e_2000) * 100;
  const maxImprovementPct = before.max_delta_e_2000 > 0
    ? ((before.max_delta_e_2000 - after.max_delta_e_2000) / before.max_delta_e_2000) * 100
    : null;
  return {
    available: true,
    before_mean_delta_e_2000: before.mean_delta_e_2000,
    after_mean_delta_e_2000: after.mean_delta_e_2000,
    mean_change_delta_e_2000: Number((after.mean_delta_e_2000 - before.mean_delta_e_2000).toFixed(4)),
    mean_improvement_pct: Number(meanImprovementPct.toFixed(2)),
    before_max_delta_e_2000: before.max_delta_e_2000,
    after_max_delta_e_2000: after.max_delta_e_2000,
    max_change_delta_e_2000: Number((after.max_delta_e_2000 - before.max_delta_e_2000).toFixed(4)),
    max_improvement_pct: maxImprovementPct == null ? null : Number(maxImprovementPct.toFixed(2)),
    passed_mean_improvement: meanImprovementPct >= config.mean_improvement_threshold_pct,
    passed_mean_non_regression: meanImprovementPct >= -config.max_regression_allowed_pct,
    passed_no_max_regression: maxImprovementPct == null ? null : maxImprovementPct >= -config.max_regression_allowed_pct,
    max_delta_e_limit: maxDeltaELimit,
    passed_max_delta_e_limit: maxDeltaELimit == null ? null : after.max_delta_e_2000 <= maxDeltaELimit
  };
}

function acceptanceFrom(result) {
  const uploadVerified = Boolean(result.autocal && result.autocal.status && result.autocal.status.upload_verified);
  const color = compareSummaries(
    result.baseline && result.baseline.colors,
    result.post && result.post.colors,
    config.color_checker_max_de_limit
  );
  const saturations = compareSummaries(
    result.baseline && result.baseline.saturations,
    result.post && result.post.saturations,
    config.saturation_max_de_limit
  );
  const greyscale = compareSummaries(result.baseline && result.baseline.greyscale, result.post && result.post.greyscale);
  const greyscaleMaxOk = !result.post || !result.post.greyscale || result.post.greyscale.max_delta_e_2000 == null
    ? null
    : result.post.greyscale.max_delta_e_2000 <= config.greyscale_max_de_limit;
  const greyscaleMeanStable = greyscale.available
    ? greyscale.mean_change_delta_e_2000 <= config.greyscale_mean_regression_limit
    : null;
  const greyscaleMaxStable = greyscale.available
    ? greyscale.max_change_delta_e_2000 <= config.greyscale_max_regression_limit
    : null;
  const colorPass = methodSeriesPass(color);
  const saturationPass = methodSeriesPass(saturations);
  const greyscalePass = greyscale.available
    ? Boolean(greyscaleMeanStable && greyscaleMaxStable && greyscaleMaxOk !== false)
    : null;
  return {
    method: config.method,
    upload_enabled: config.upload,
    upload_verified: uploadVerified,
    note: uploadVerified
      ? 'Post series measured after the generated LUT upload path.'
      : 'Export-only run: post series does not validate TV LUT improvement unless the LUT was applied separately.',
    colors: { ...color, passed_for_method: colorPass },
    saturations: { ...saturations, passed_for_method: saturationPass },
    greyscale: {
      ...greyscale,
      passed_post_max_delta_e_2000: greyscaleMaxOk,
      passed_mean_stability: greyscaleMeanStable,
      passed_max_stability: greyscaleMaxStable,
      passed_for_method: greyscalePass
    },
    overall_pass: uploadVerified ? Boolean(colorPass && saturationPass && greyscalePass !== false) : null
  };
}

function methodSeriesPass(summary) {
  if (!summary || !summary.available) return null;
  const maxOk = summary.passed_max_delta_e_limit || summary.passed_no_max_regression;
  return Boolean(summary.passed_mean_improvement && maxOk);
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

async function pollStatus(endpoint, outName, label, timeoutMs) {
  const started = Date.now();
  let last = null;
  while (Date.now() - started < timeoutMs) {
    const status = await api(endpoint, { timeoutMs: 30000 });
    last = status;
    save(outName, status);
    const state = status.status || 'unknown';
    const step = status.current_step != null && status.total_steps != null
      ? `${status.current_step}/${status.total_steps}`
      : '';
    const current = status.current_name || status.message || '';
    process.stdout.write(`[${new Date().toLocaleTimeString()}] ${label}: ${state} ${step} ${current}\n`);
    if (state === 'complete' || state === 'error' || state === 'cancelled') return status;
    await sleep(config.poll_ms);
  }
  if (last) save(outName, last);
  throw new Error(`${label} timed out after ${Math.round(timeoutMs / 1000)} seconds`);
}

function seriesPayload(type) {
  return {
    type,
    points: type === 'saturations' ? 24 : (type === 'colors' ? 30 : 21),
    display_type: config.display_type,
    delay_ms: config.delay_ms,
    patch_size: config.patch_size,
    signal_range: '1',
    pattern_signal_range: '1',
    transport_signal_range: '1',
    signal_mode: 'sdr',
    max_luma: 1000,
    target_gamma: config.target_gamma,
    target_gamut: 'bt709',
    lg_greyscale_21: type === 'greyscale',
    patch_insert: config.patch_insert,
    require_device_ready: config.require_device_ready
  };
}

async function runSeries(type, label) {
  const payload = seriesPayload(type);
  save(`lg-3d-lut-acceptance-${stamp}-${label}-${type}-payload.json`, payload);
  await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
  await parkBlack();
  const start = await api('/api/meter/series', { method: 'POST', body: payload, timeoutMs: 30000 });
  save(`lg-3d-lut-acceptance-${stamp}-${label}-${type}-start.json`, start);
  if (!start || start.status !== 'started') throw new Error(`${label} ${type} did not start: ${(start && start.message) || 'unknown'}`);
  const status = await pollStatus(
    '/api/meter/series/status',
    `lg-3d-lut-acceptance-${stamp}-${label}-${type}-status.json`,
    `${label} ${type}`,
    config.series_timeout_ms
  );
  const summary = summarizeSeries(start, status, type);
  save(`lg-3d-lut-acceptance-${stamp}-${label}-${type}-summary.json`, summary);
  if (status.status !== 'complete') throw new Error(`${label} ${type} ended as ${status.status}: ${status.message || ''}`);
  process.stdout.write(`${label} ${type}: mean dE2000 ${fmtDe(summary.mean_delta_e_2000)}, max ${fmtDe(summary.max_delta_e_2000)} (${summary.max_name || 'n/a'})\n`);
  return { start, status, summary };
}

async function runValidationSet(label) {
  const out = {};
  const colors = await runSeries('colors', label);
  out.colors = colors.summary;
  const saturations = await runSeries('saturations', label);
  out.saturations = saturations.summary;
  if (config.run_greyscale) {
    const greyscale = await runSeries('greyscale', label);
    out.greyscale = greyscale.summary;
  }
  return out;
}

async function run3dAutocal() {
  const payload = {
    method: config.method,
    type: 'lg-3d-lut',
    display_type: config.display_type,
    delay_ms: config.delay_ms,
    patch_size: config.patch_size,
    signal_range: '1',
    pattern_signal_range: '1',
    transport_signal_range: '1',
    signal_mode: 'sdr',
    requested_signal_mode: 'sdr',
    max_luma: 1000,
    target_gamma: config.target_gamma,
    target_gamut: 'bt709',
    picture_mode: config.picture_mode,
    upload: config.upload,
    post_check: config.autocal_post_check,
    patch_insert: config.patch_insert,
    require_device_ready: config.require_device_ready
  };
  save(`lg-3d-lut-acceptance-${stamp}-autocal-payload.json`, payload);
  await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
  await parkBlack();
  const start = await api('/api/meter/lg-3d-autocal/start', { method: 'POST', body: payload, timeoutMs: 30000 });
  save(`lg-3d-lut-acceptance-${stamp}-autocal-start.json`, start);
  if (!start || start.status !== 'started') throw new Error(`3D LUT AutoCal did not start: ${(start && start.message) || 'unknown'}`);
  const status = await pollStatus(
    '/api/meter/lg-3d-autocal/status',
    `lg-3d-lut-acceptance-${stamp}-autocal-status.json`,
    '3D LUT AutoCal',
    config.autocal_timeout_ms
  );
  save(`lg-3d-lut-acceptance-${stamp}-autocal-final.json`, status);
  if (status.status !== 'complete') throw new Error(`3D LUT AutoCal ended as ${status.status}: ${status.message || ''}`);
  return { start, status };
}

async function reset3d() {
  const payload = {
    picture_mode: config.picture_mode,
    requested_signal_mode: 'sdr',
    signal_mode: 'sdr'
  };
  const result = await api('/api/lg/3d-lut/reset', { method: 'POST', body: payload, timeoutMs: 120000 });
  save(`lg-3d-lut-acceptance-${stamp}-reset-3d.json`, result);
  return result;
}

async function preflight() {
  const meter = await api('/api/meter/status', { timeoutMs: 10000 });
  const lg = await api('/api/lg/status', { timeoutMs: 10000 }).catch(error => ({
    status: 'error',
    message: error.message
  }));
  const status = { meter, lg };
  save(`lg-3d-lut-acceptance-${stamp}-preflight.json`, status);
  if (!meter || !meter.detected) {
    throw new Error('Meter preflight failed: no meter detected.');
  }
  if (config.upload) {
    if (!lg || lg.status !== 'ok' || !lg.paired) {
      throw new Error(`LG preflight failed: ${(lg && lg.message) || 'not paired/ready'}`);
    }
    if (String(lg.tv_power || '').toLowerCase() === 'standby') {
      throw new Error('LG preflight failed: TV is in standby. Wake the TV and select the SDR calibration picture mode first.');
    }
  }
  return status;
}

async function main() {
  const result = {
    started_at: new Date().toISOString(),
    base_url: baseUrl,
    stamp,
    config
  };
  save(`lg-3d-lut-acceptance-${stamp}-plan.json`, result);

  if (config.dry_run) {
    process.stdout.write(`Dry run. Plan written to ${outDir}/lg-3d-lut-acceptance-${stamp}-plan.json\n`);
    return;
  }

  try {
    if (!config.upload) {
      process.stdout.write('Running in export-only mode. Set PGEN_UPLOAD=1 PGEN_ALLOW_TV_WRITE=1 for post-series TV LUT validation.\n');
    }
    result.preflight = await preflight();
    if (config.reset_3d) {
      result.reset_3d = await reset3d();
    }
    if (config.run_baseline) {
      result.baseline = await runValidationSet('baseline');
    }
    if (config.run_3d) {
      result.autocal = await run3dAutocal();
    }
    if (config.run_post) {
      result.post = await runValidationSet('post');
    }
    result.acceptance = acceptanceFrom(result);
    save(`lg-3d-lut-acceptance-${stamp}-acceptance.json`, result.acceptance);
  } finally {
    await parkBlack();
    result.finished_at = new Date().toISOString();
    save(`lg-3d-lut-acceptance-${stamp}-result.json`, result);
  }

  const acc = result.acceptance || {};
  process.stdout.write(`Done. Artifacts written under ${outDir} with stamp ${stamp}.\n`);
  if (acc.colors && acc.colors.available) {
    process.stdout.write(`ColorChecker mean: ${fmtDe(acc.colors.before_mean_delta_e_2000)} -> ${fmtDe(acc.colors.after_mean_delta_e_2000)} (${fmtPct(acc.colors.mean_improvement_pct)})\n`);
  }
  if (acc.saturations && acc.saturations.available) {
    process.stdout.write(`Sat sweep mean: ${fmtDe(acc.saturations.before_mean_delta_e_2000)} -> ${fmtDe(acc.saturations.after_mean_delta_e_2000)} (${fmtPct(acc.saturations.mean_improvement_pct)})\n`);
  }
  if (acc.greyscale && acc.greyscale.available) {
    process.stdout.write(`Greyscale mean: ${fmtDe(acc.greyscale.before_mean_delta_e_2000)} -> ${fmtDe(acc.greyscale.after_mean_delta_e_2000)} (${fmtPct(acc.greyscale.mean_improvement_pct)})\n`);
  }
  if (acc.overall_pass != null) {
    process.stdout.write(`Acceptance: ${acc.overall_pass ? 'PASS' : 'REVIEW'}\n`);
  }
}

main().catch(error => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});

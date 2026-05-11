#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const baseUrl = process.env.PGEN_URL || 'http://192.168.1.179';
const outPath = process.env.PGEN_MAP_OUT || `tmp/lg-map-${Date.now()}.json`;
const mode = (process.env.PGEN_MAP_MODE || 'manual').toLowerCase();
const channel = (process.env.PGEN_MAP_CHANNEL || 'lum').toLowerCase();
const delta = Number(process.env.PGEN_MAP_DELTA || '30');
const settleMs = Number(process.env.PGEN_MAP_SETTLE_MS || '1000');
const readRetries = Math.max(0, Number(process.env.PGEN_MAP_READ_RETRIES || '1'));
const candidateRadius = Math.max(0, Number(process.env.PGEN_MAP_RADIUS || '3'));
const exactCandidateCodes = String(process.env.PGEN_MAP_EXACT_CODES || '0') === '1';
const patchSize = Number(process.env.PGEN_MAP_PATCH_SIZE || '10');
const pictureMode = process.env.PGEN_MAP_PICTURE_MODE || 'cinema';
const restoreMode = (process.env.PGEN_MAP_RESTORE || 'original').toLowerCase();
const baselineMode = (process.env.PGEN_MAP_BASELINE || 'original').toLowerCase();
const disableCalibrationMode = process.env.PGEN_MAP_DISABLE_CAL !== '0';
const forceDdc = mode === 'ddc' || process.env.PGEN_MAP_FORCE_DDC === '1';
const extended16To255 = process.env.PGEN_MAP_EXTENDED !== '0';
const ddcSlots = [
  2.5, 5, 7.5, 10, 15, 20, 25, 30, 35, 40, 45,
  50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100
];

const slots = parseList(process.env.PGEN_MAP_SLOTS) || [
  ...ddcSlots
];

const ddcAnchorCodes = [
  32, 38, 43, 49, 60, 71, 82, 93, 98, 109, 120,
  131, 142, 153, 164, 169, 180, 191, 202, 213, 224, 235
];
const legacy26Codes = [
  16, 21, 25, 30, 44, 53, 63, 68, 72, 77, 82, 91,
  100, 110, 121, 136, 143, 151, 170, 188, 213, 222,
  232, 241, 250, 255
];
const legalCodes = slots.map(slot => slot <= 0 ? 16 : Math.round(16 + (slot / 100) * 219));
const candidateCodes = [...new Set([
  ...ddcAnchorCodes,
  ...legacy26Codes,
  ...legalCodes,
  ...(parseList(process.env.PGEN_MAP_CODES) || [])
])].filter(code => code >= 0 && code <= 255).sort((a, b) => a - b);

function parseList(raw) {
  if (!raw || !String(raw).trim()) return null;
  const out = String(raw).split(',').map(v => Number(v.trim())).filter(Number.isFinite);
  return out.length ? out : null;
}

function pctFromCode(code) {
  if (extended16To255) return (Number(code) - 16) / 239 * 100;
  return (Number(code) - 16) / 219 * 100;
}

function fmt(value) {
  return String(Math.round(Number(value) * 100) / 100)
    .replace(/(\.\d*?)0+$/, '$1')
    .replace(/\.$/, '');
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function api(endpoint, options = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 120000);
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

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeArray(value, count = 22) {
  const out = Array.isArray(value) ? value.map(v => Number(v) || 0) : [];
  while (out.length < count) out.push(0);
  return out.slice(0, count);
}

function settingKey() {
  if (channel === 'r' || channel === 'red') return 'whiteBalanceRed';
  if (channel === 'g' || channel === 'green') return 'whiteBalanceGreen';
  if (channel === 'b' || channel === 'blue') return 'whiteBalanceBlue';
  return 'adjustingLuminance';
}

function arraysFromPicture(picture) {
  return {
    whiteBalanceRed: normalizeArray(picture.whiteBalanceRed),
    whiteBalanceGreen: normalizeArray(picture.whiteBalanceGreen),
    whiteBalanceBlue: normalizeArray(picture.whiteBalanceBlue),
    adjustingLuminance: normalizeArray(picture.adjustingLuminance)
  };
}

function zeroArrays() {
  return {
    whiteBalanceRed: Array(22).fill(0),
    whiteBalanceGreen: Array(22).fill(0),
    whiteBalanceBlue: Array(22).fill(0),
    adjustingLuminance: Array(22).fill(0)
  };
}

async function writeWhiteBalance(picture, arrays, ire, reset = false) {
  const settings = {
    whiteBalanceMethod: '22',
    whiteBalanceIre: fmt(ire),
    whiteBalanceRed: arrays.whiteBalanceRed,
    whiteBalanceGreen: arrays.whiteBalanceGreen,
    whiteBalanceBlue: arrays.whiteBalanceBlue,
    adjustingLuminance: arrays.adjustingLuminance
  };
  const response = await api('/api/lg/picture-settings/set', {
    method: 'POST',
    body: {
      settings,
      picture_mode: picture.pictureMode || pictureMode,
      keep_calibration_mode: forceDdc,
      calibration_mode_active: forceDdc,
      force_ddc_white_balance: forceDdc,
      reset_ddc_baseline: reset,
      skip_readback: true,
      helper_timeout: 150
    },
    timeoutMs: 180000
  });
  if (!response || response.status !== 'ok') {
    throw new Error((response && response.message) || 'white balance write failed');
  }
  await sleep(900);
}

function candidateCodesForSlot(slot) {
  const explicitCodes = parseList(process.env.PGEN_MAP_CODES);
  if (exactCandidateCodes && explicitCodes && explicitCodes.length) {
    return [...new Set(explicitCodes)]
      .filter(code => code >= 0 && code <= 255)
      .sort((a, b) => a - b);
  }
  const targetAnchor = ddcAnchorCodes[ddcSlots.findIndex(v => Math.abs(v - slot) < 0.001)];
  const targetLegal = Math.round(16 + (slot / 100) * 219);
  const targets = [targetAnchor, targetLegal].filter(Number.isFinite);
  const indexes = new Set();
  for (const target of targets) {
    const nearest = candidateCodes.reduce((best, code, idx) => {
      const dist = Math.abs(code - target);
      return dist < best.dist ? { idx, dist } : best;
    }, { idx: 0, dist: Infinity }).idx;
    for (let offset = -candidateRadius; offset <= candidateRadius; offset++) {
      const idx = nearest + offset;
      if (idx >= 0 && idx < candidateCodes.length) indexes.add(idx);
    }
  }
  return [...indexes].sort((a, b) => a - b).map(idx => candidateCodes[idx]);
}

async function readCode(code, namePrefix) {
  let lastError = null;
  for (let attempt = 0; attempt <= readRetries; attempt++) {
    const requestId = `map_${process.pid}_${Date.now()}_${code}_${attempt}`;
    const percent = pctFromCode(code);
    try {
      const started = await api('/api/meter/read', {
        method: 'POST',
        body: {
          display_type: 'oled_generic',
          patch_r: code,
          patch_g: code,
          patch_b: code,
          patch_size: patchSize,
          patch_ire: percent,
          patch_name: `${namePrefix}_${code}`,
          delay_ms: settleMs,
          signal_mode: 'sdr',
          max_luma: 1000,
          signal_range: '1',
          transport_signal_range: '1',
          request_id: requestId
        },
        timeoutMs: 30000
      });
      if (!started || started.status !== 'measuring') {
        throw new Error(`read did not start: ${JSON.stringify(started)}`);
      }
      const deadline = Date.now() + 190000;
      while (Date.now() < deadline) {
        await sleep(750);
        const result = await api('/api/meter/read/result', { timeoutMs: 10000 });
        if (result && result.status === 'ok' && Array.isArray(result.readings) && result.readings[0]) {
          const reading = result.readings[0];
          if (!reading.request_id || reading.request_id === requestId) return reading;
        }
        if (result && result.status && result.status !== 'measuring' && result.status !== 'ok') {
          throw new Error(result.message || result.status);
        }
      }
      throw new Error('read timed out');
    } catch (error) {
      lastError = error;
      process.stdout.write(`  read retry ${fmt(percent)}% code ${code}: ${error.message}\n`);
      await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
      await sleep(1500);
    }
  }
  throw lastError;
}

function responseScore(before, after) {
  const bY = Number(before && (before.Y ?? before.luminance)) || 0;
  const aY = Number(after && (after.Y ?? after.luminance)) || 0;
  const dx = (Number(after && after.x) || 0) - (Number(before && before.x) || 0);
  const dy = (Number(after && after.y) || 0) - (Number(before && before.y) || 0);
  const dY = aY - bY;
  const absY = Math.abs(dY);
  const relY = Math.abs(dY) / Math.max(1, bY);
  const color = Math.sqrt(dx * dx + dy * dy) * 1000;
  const yWeight = Math.sqrt(Math.max(0.05, Math.min(25, bY)));
  const metric = channel === 'lum'
    ? (absY + relY * 8)
    : ((color * yWeight) + (absY * 0.25));
  return { metric, dY, relY, dx, dy, color };
}

function save(results) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(results, null, 2));
}

async function main() {
  const results = {
    started_at: new Date().toISOString(),
    mode,
    channel,
    delta,
    force_ddc: forceDdc,
    extended_16_255: extended16To255,
    candidate_codes: candidateCodes,
    slots: []
  };
  let originalPicture = null;
  let originalArrays = null;
  try {
    await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
    if (disableCalibrationMode && !forceDdc) {
      await api('/api/lg/calibration-mode', {
        method: 'POST',
        body: { enabled: false, picture_mode: pictureMode },
        timeoutMs: 90000
      }).catch(() => null);
    }
    const pic = await api('/api/lg/picture-settings', {
      method: 'POST',
      body: {
        keys: [
          'pictureMode', 'whiteBalanceMethod', 'whiteBalanceIre',
          'whiteBalanceRed', 'whiteBalanceGreen', 'whiteBalanceBlue',
          'adjustingLuminance', 'brightness', 'contrast', 'blackLevel'
        ],
        picture_mode: pictureMode,
        force_ddc_white_balance: forceDdc,
        helper_timeout: 90
      },
      timeoutMs: 120000
    });
    if (!pic || pic.status !== 'ok') throw new Error((pic && pic.message) || 'picture read failed');
    originalPicture = pic.picture_settings || {};
    originalArrays = arraysFromPicture(originalPicture);
    results.original_picture = originalPicture;
    results.picture_capabilities = pic.picture_capabilities || null;
    save(results);

    if (forceDdc) {
      process.stdout.write('Resetting DDC LUT baseline to neutral for DDC mapping...\n');
      const neutral = {
        whiteBalanceRed: Array(22).fill(0),
        whiteBalanceGreen: Array(22).fill(0),
        whiteBalanceBlue: Array(22).fill(0),
        adjustingLuminance: Array(22).fill(0)
      };
      await writeWhiteBalance(originalPicture, neutral, 100, true);
      originalArrays = neutral;
    } else if (baselineMode === 'zero') {
      process.stdout.write('Writing neutral 22pt table before mapping...\n');
      originalArrays = zeroArrays();
      await writeWhiteBalance(originalPicture, originalArrays, 100, false);
    }

    const baseline = new Map();
    for (const slot of slots) {
      const idx = ddcSlots.findIndex(v => Math.abs(v - slot) < 0.001);
      if (idx < 0) {
        results.slots.push({ slot, index: -1, skipped: true, reason: 'slot is not an LG DDC slot' });
        save(results);
        continue;
      }
      const codes = candidateCodesForSlot(slot);
      for (const code of codes) {
        if (!baseline.has(code)) {
          process.stdout.write(`baseline code ${code} (${fmt(pctFromCode(code))}%)\n`);
          baseline.set(code, await readCode(code, 'baseline'));
        }
      }
      const arrays = clone(originalArrays);
      const key = settingKey();
      const beforeValue = Number(arrays[key][idx]) || 0;
      const testValue = Math.max(-50, Math.min(50, beforeValue + delta));
      arrays[key][idx] = testValue;
      process.stdout.write(`\nslot ${fmt(slot)}% ${key} ${beforeValue} -> ${testValue}; candidates ${codes.join(',')}\n`);
      await writeWhiteBalance(originalPicture, arrays, slot, false);
      const afterReadings = {};
      for (const code of codes) {
        process.stdout.write(`  reading code ${code} (${fmt(pctFromCode(code))}%)\n`);
        afterReadings[code] = await readCode(code, `slot_${fmt(slot).replace('.', 'p')}`);
      }
      const ranked = codes.map(code => {
        const before = baseline.get(code);
        const after = afterReadings[code];
        return {
          code,
          stimulus: Number(fmt(pctFromCode(code))),
          beforeY: Number((Number(before.Y ?? before.luminance) || 0).toFixed(5)),
          afterY: Number((Number(after.Y ?? after.luminance) || 0).toFixed(5)),
          ...responseScore(before, after)
        };
      }).sort((a, b) => b.metric - a.metric);
      const result = {
        slot,
        index: idx,
        setting: key,
        before_value: beforeValue,
        test_value: testValue,
        candidate_codes: codes,
        ranked: ranked.slice(0, 6).map(item => ({
          code: item.code,
          stimulus: item.stimulus,
          metric: Number(item.metric.toFixed(5)),
          dY: Number(item.dY.toFixed(5)),
          relY: Number(item.relY.toFixed(5)),
          color: Number(item.color.toFixed(5)),
          beforeY: item.beforeY,
          afterY: item.afterY
        })),
        best_code: ranked[0] && ranked[0].code,
        best_stimulus: ranked[0] && Number(fmt(pctFromCode(ranked[0].code)))
      };
      results.slots.push(result);
      save(results);
      process.stdout.write(`  best ${fmt(slot)}% -> code ${result.best_code} (${fmt(result.best_stimulus)}%)\n`);
      await writeWhiteBalance(originalPicture, originalArrays, originalPicture.whiteBalanceIre || slot, false);
    }
    results.finished_at = new Date().toISOString();
    save(results);
  } finally {
    if (originalPicture && originalArrays && restoreMode === 'original') {
      await writeWhiteBalance(originalPicture, originalArrays, originalPicture.whiteBalanceIre || 100, false).catch(error => {
        process.stderr.write(`restore failed: ${error.message}\n`);
      });
    }
    await api('/api/meter/stop', { method: 'POST', timeoutMs: 30000 }).catch(() => null);
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
  process.stdout.write(`Done: ${outPath}\n`);
}

main().catch(error => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});

#!/usr/bin/env node
// tests/lg-autocal-ab-compare.js <baseline-dir> <candidate-dir>
// Emits a markdown table: IRE | baseline dE | candidate dE | delta | verdict.
'use strict';

const fs = require('fs');
const path = require('path');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function luminance(reading) {
  const y = Number(reading && (reading.luminance ?? reading.Y));
  return Number.isFinite(y) ? y : NaN;
}

function xyzFromXyY(x, y, Y) {
  x = Number(x);
  y = Number(y);
  Y = Number(Y);
  if (!(x > 0) || !(y > 0) || !(Y >= 0)) return null;
  return { X: (x * Y) / y, Y, Z: ((1 - x - y) * Y) / y };
}

function readingXyz(reading) {
  const X = Number(reading && reading.X);
  const Y = Number(reading && reading.Y);
  const Z = Number(reading && reading.Z);
  if (Number.isFinite(X) && Number.isFinite(Y) && Number.isFinite(Z)) return { X, Y, Z };
  return xyzFromXyY(Number(reading && reading.x), Number(reading && reading.y), luminance(reading));
}

function pqEncodeNormalized(nits) {
  nits = Number(nits) || 0;
  if (nits <= 0) return 0;
  if (nits > 10000) nits = 10000;
  const l = nits / 10000;
  const m1 = 2610 / 16384;
  const m2 = 2523 / 32;
  const c1 = 3424 / 4096;
  const c2 = 2413 / 128;
  const c3 = 2392 / 128;
  const p = Math.pow(l, m1);
  return Math.pow((c1 + c2 * p) / (1 + c3 * p), m2);
}

function xyzToICtCp(X, Y, Z) {
  let R = 1.7166511880 * X - 0.3556707838 * Y - 0.2533662814 * Z;
  let G = -0.6666843518 * X + 1.6164812366 * Y + 0.0157685458 * Z;
  let B = 0.0176398574 * X - 0.0427706133 * Y + 0.9421031212 * Z;
  R = Math.max(0, R);
  G = Math.max(0, G);
  B = Math.max(0, B);
  const L = (1688 * R + 2146 * G + 262 * B) / 4096;
  const M = (683 * R + 2951 * G + 462 * B) / 4096;
  const S = (99 * R + 309 * G + 3688 * B) / 4096;
  const Lp = pqEncodeNormalized(L);
  const Mp = pqEncodeNormalized(M);
  const Sp = pqEncodeNormalized(S);
  return {
    I: 0.5 * Lp + 0.5 * Mp,
    T: (6610 * Lp - 13613 * Mp + 7003 * Sp) / 4096,
    P: (17933 * Lp - 17390 * Mp - 543 * Sp) / 4096,
  };
}

function deltaEITPXYZ(a, b) {
  const ia = xyzToICtCp(a.X, a.Y, a.Z);
  const ib = xyzToICtCp(b.X, b.Y, b.Z);
  const dI = ia.I - ib.I;
  const dT = ia.T - ib.T;
  const dP = ia.P - ib.P;
  return 720 * Math.sqrt(dI * dI + 0.25 * dT * dT + dP * dP);
}

function deltaEITPNoLum(reading, targetX = 0.3127, targetY = 0.3290) {
  const actual = readingXyz(reading);
  const Y = luminance(reading);
  const target = xyzFromXyY(targetX, targetY, Y);
  if (!actual || !target) return NaN;
  return deltaEITPXYZ(actual, target);
}

function normalizeIre(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Number(n.toFixed(4)) : value;
}

function rowsFromStatus(status) {
  const directRows = status?.result?.greyscale?.rows || status?.greyscale?.rows;
  if (Array.isArray(directRows) && directRows.length) {
    return directRows.map(row => ({
      name: row.name || `${row.ire}%`,
      ire: normalizeIre(row.ire),
      de: Number(row.de_itp_no_lum ?? row.delta_e_itp ?? row.de_itp ?? row.delta_e),
    })).filter(row => row.ire != null && Number.isFinite(row.de));
  }

  const readings = Array.isArray(status?.readings) ? status.readings : [];
  return readings
    .filter(reading => reading && Number(reading.ire) > 0)
    .map(reading => ({
      name: reading.name || `${reading.ire}%`,
      ire: normalizeIre(reading.ire),
      de: deltaEITPNoLum(reading, Number(reading.target_x || 0.3127), Number(reading.target_y || 0.3290)),
    }))
    .filter(row => row.ire != null && Number.isFinite(row.de));
}

function loadResult(dir) {
  const statusPath = path.join(dir, 'status.json');
  const resultPath = path.join(dir, 'result.json');
  const status = fs.existsSync(statusPath) ? readJson(statusPath) : readJson(resultPath);
  const map = new Map();
  for (const row of rowsFromStatus(status)) {
    map.set(row.ire, row);
  }
  return map;
}

const [baselineDir, candidateDir] = process.argv.slice(2);
if (!baselineDir || !candidateDir) {
  console.error('usage: lg-autocal-ab-compare.js <baseline-dir> <candidate-dir>');
  process.exit(2);
}

const baseline = loadResult(baselineDir);
const candidate = loadResult(candidateDir);
const ires = [...new Set([...baseline.keys(), ...candidate.keys()])].sort((a, b) => Number(a) - Number(b));

let regressions = 0;
let improvements = 0;
console.log('| IRE | baseline dE_ITP | candidate dE_ITP | Delta | verdict |');
console.log('|----:|----------------:|-----------------:|------:|---------|');
for (const ire of ires) {
  const a = baseline.get(ire);
  const b = candidate.get(ire);
  if (!a || !b) continue;
  const delta = b.de - a.de;
  let verdict = '.';
  if (delta > 0.15) {
    verdict = 'worse';
    regressions++;
  } else if (delta < -0.15) {
    verdict = 'better';
    improvements++;
  }
  console.log(`| ${ire} | ${a.de.toFixed(2)} | ${b.de.toFixed(2)} | ${delta >= 0 ? '+' : ''}${delta.toFixed(2)} | ${verdict} |`);
}
console.log(`\nSummary: ${improvements} improved, ${regressions} regressed (>0.15 dE threshold).`);
process.exit(regressions > improvements ? 1 : 0);

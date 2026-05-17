#!/usr/bin/env node
'use strict';

const fs = require('fs');

const tracePath = process.argv[2];
if (!tracePath) {
  console.error('usage: lg-autocal-trace-summary.js <trace.jsonl>');
  process.exit(2);
}

const lines = fs.readFileSync(tracePath, 'utf8').split(/\r?\n/).filter(Boolean);
const finals = new Map();
const committed = new Map();

function ireKey(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value || '');
  return Number.isInteger(n) ? String(n) : n.toFixed(1).replace(/0+$/, '').replace(/\.$/, '');
}

function readingY(reading) {
  const y = Number(reading && (reading.luminance ?? reading.Y));
  return Number.isFinite(y) ? y : null;
}

function targetY(row) {
  const y = Number(row && (row.target_luminance ?? (row.best_reading && row.best_reading.target_luminance)));
  return Number.isFinite(y) ? y : null;
}

function store(map, row) {
  const key = ireKey(row.ire ?? (row.best_reading && row.best_reading.ire));
  if (!key) return;
  map.set(key, row);
}

for (const line of lines) {
  let row;
  try {
    row = JSON.parse(line);
  } catch (_err) {
    continue;
  }
  if (row.event === 'final_step_result') store(finals, row);
  if (row.event === 'committed_low_shadow_measurement' || row.event === 'committed_polish_measurement') {
    store(committed, row);
  }
}

const keys = Array.from(new Set([...finals.keys(), ...committed.keys()]))
  .sort((a, b) => Number(a) - Number(b));

console.log(['IRE', 'Final dE', 'Final Y', 'Target Y', 'Final Y err %', 'Committed dE', 'Committed Y err %'].join('\t'));
for (const key of keys) {
  const f = finals.get(key);
  const c = committed.get(key);
  const fReading = f && (f.best_reading || f.reading);
  const cReading = c && (c.best_reading || c.reading);
  const fY = readingY(fReading);
  const fTarget = targetY(f);
  const fLum = Number(f && f.best_luminance_error_pct);
  const cLum = Number(c && (c.best_luminance_error_pct ?? c.luminance_error_pct));
  const cols = [
    key,
    Number.isFinite(Number(f && f.best_delta_e)) ? Number(f.best_delta_e).toFixed(3) : '',
    fY != null ? fY.toFixed(fY < 1 ? 6 : 3) : '',
    fTarget != null ? fTarget.toFixed(fTarget < 1 ? 6 : 3) : '',
    Number.isFinite(fLum) ? fLum.toFixed(2) : '',
    Number.isFinite(Number(c && (c.best_delta_e ?? c.delta_e))) ? Number(c.best_delta_e ?? c.delta_e).toFixed(3) : '',
    Number.isFinite(cLum) ? cLum.toFixed(2) : '',
  ];
  console.log(cols.join('\t'));
}

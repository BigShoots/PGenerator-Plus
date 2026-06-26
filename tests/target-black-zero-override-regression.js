#!/usr/bin/env node
'use strict';

// Regression test for the meter Chart Black Level honoring the operator's
// Target Black = 0 manual override on OLED-class panels.
//
// Pre-fix: meterChartBlackLevel() only honored the manual override when
// `_tb.value > 0`. For OLED (and any other self-emissive display type) the
// default is `useMeasured=false, value=0`, so the `> 0` guard silently fell
// through to the measured 0% IRE reading. The chart then anchored the
// target floor at the measured lift (~0.05-0.1 nits) instead of 0, hiding
// the OLED's true-black target and making a 21pt / 101pt series read
// grade against a stale floor.
//
// Post-fix: `_tb.value >= 0` honors the OLED-default value=0 entry and
// always wins over any series/stamped measurement, exactly like a manual
// value of 0.05 nits already did.
//
// Source-only test, no live renderer or meter required.

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

function runScenario(useMeasured, value) {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext([
    `
      function meterNormalizeOledBlackReading(reading){ return reading; }
      function meterReadingIsGreyscale(reading){ return !!reading && String(reading.series_type || 'greyscale') === 'greyscale'; }
      function meterDisplayIsOled(){ return false; }
      function meterChartIsHdr(){ return false; }
      function meterTargetBlackLevel(){ return ${JSON.stringify({ useMeasured, value })}; }
    `,
    extractFunction('meterChartBlackLevel'),
    `
      const readingsWithLift = [
        { ire: 0,   name: '0%',   luminance: 0.08, series_type: 'greyscale', series_target_black_y: 0.05 },
        { ire: 10,  name: '10%',  luminance: 1.8,  series_type: 'greyscale' },
        { ire: 100, name: '100%', luminance: 276,  series_type: 'greyscale' }
      ];
      globalThis.withLift = meterChartBlackLevel(readingsWithLift);

      const readingsMissingZero = [
        { ire: 10,  name: '10%',  luminance: 1.8,  series_type: 'greyscale' },
        { ire: 100, name: '100%', luminance: 276,  series_type: 'greyscale' }
      ];
      globalThis.missingZero = meterChartBlackLevel(readingsMissingZero);
    `
  ].join('\n'), ctx);
  return { withLift: ctx.withLift, missingZero: ctx.missingZero };
}

const zero = runScenario(false, 0);
assert.strictEqual(zero.withLift, 0,
  'Manual Target Black = 0 must win over a measured 0.08 nits lift (OLED default)');
assert.strictEqual(zero.missingZero, 0,
  'Manual Target Black = 0 must win even when no 0% IRE reading is in the series');

const measured = runScenario(true, null);
assert.strictEqual(measured.withLift, 0.08,
  'With Use measured checked, the chart must use the series 0% IRE reading');

const nonZero = runScenario(false, 0.05);
assert.strictEqual(nonZero.withLift, 0.05,
  'Manual Target Black = 0.05 (the pre-fix honored case) must still win over measured 0.08');

const fnStart = source.indexOf('function meterChartBlackLevel(readings){');
assert(fnStart >= 0, 'meterChartBlackLevel must be defined');
const fnBody = source.slice(fnStart, fnStart + 800);
assert(/!_tb\.useMeasured\s*&&\s*_tb\.value\s*!=\s*null\s*&&\s*_tb\.value\s*>=\s*0/.test(fnBody),
  'override guard must use _tb.value>=0 (the OLED value=0 default)');
assert(!/_tb\.value\s*>\s*0\s*\)/.test(fnBody),
  'override guard must NOT regress to _tb.value>0 (the pre-fix bypass for OLED value=0)');

console.log('Target Black = 0 override regression checks passed.');
#!/usr/bin/env node
'use strict';

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

const context = {};
vm.createContext(context);
vm.runInContext([
  `
    let meterReadings = [];
    function meterNormalizeOledBlackReading(reading){ return reading; }
    function meterReadingIsGreyscale(reading){ return !!reading && String(reading.series_type || 'greyscale') === 'greyscale'; }
    function meterReadingHasLuminance(reading){ return !!reading && reading.luminance != null && reading.luminance >= 0; }
    function meterReadingLuminanceNits(reading){ return reading && reading.luminance; }
    function meterDisplayIsOled(){ return false; }
    function meterChartIsHdr(){ return false; }
    function meterChartIsDv(){ return false; }
    function meterChartIsHlg(){ return false; }
    function meterGreyChartUsesPqTarget(){ return false; }
    function meterGreyTargetGammaSelection(){ return 'bt1886'; }
    function meterGreyTargetSignal(ire){ return Math.max(0, Math.min(1, (Number(ire) || 0) / 100)); }
  `,
  extractFunction('meterChartBlackLevel'),
  extractFunction('meterBlackReadingY'),
  extractFunction('bt1886Eotf'),
  extractFunction('meterGreyTargetLuminance'),
  `
    meterReadings = [
      { ire: 5, name: '5%', luminance: 5.2, series_type: 'greyscale' },
      { ire: 10, name: '10%', luminance: 9.8, series_type: 'greyscale' },
      { ire: 100, name: '100%', luminance: 100, series_type: 'greyscale' }
    ];
    globalThis.missingBlackY = meterBlackReadingY();
    globalThis.missingBlackTarget5 = meterGreyTargetLuminance(5, 100, missingBlackY, null);

    meterReadings = [
      { ire: 0, name: '0%', error: 'no_reading', series_type: 'greyscale' },
      { ire: 5, name: '5%', luminance: 5.2, series_type: 'greyscale' },
      { ire: 100, name: '100%', luminance: 100, series_type: 'greyscale' }
    ];
    globalThis.invalidBlackY = meterBlackReadingY();
    globalThis.invalidBlackTarget5 = meterGreyTargetLuminance(5, 100, invalidBlackY, null);

    meterReadings = [
      { ire: 0, name: '0%', luminance: 0.04, series_type: 'greyscale' },
      { ire: 5, name: '5%', luminance: 5.2, series_type: 'greyscale' },
      { ire: 100, name: '100%', luminance: 100, series_type: 'greyscale' }
    ];
    globalThis.trueBlackY = meterBlackReadingY();
    globalThis.trueBlackTarget5 = meterGreyTargetLuminance(5, 100, trueBlackY, null);
  `
].join('\n'), context);

const zeroBlackTarget5 = Math.pow(0.05, 2.4) * 100;
assert.strictEqual(context.missingBlackY, 0, '21pt target math must not treat 5% as black when 0% is missing');
assert.strictEqual(context.invalidBlackY, 0, '21pt target math must ignore a 0% read without luminance instead of using 5% as black');
assert(Math.abs(context.missingBlackTarget5 - zeroBlackTarget5) < 1e-12, 'Missing 0% should keep the 5% target on a zero-black basis');
assert(Math.abs(context.invalidBlackTarget5 - zeroBlackTarget5) < 1e-12, 'Invalid 0% should keep the 5% target on a zero-black basis');
assert.strictEqual(context.trueBlackY, 0.04, 'A valid true 0% luminance read should still be used as black');
assert(context.trueBlackTarget5 > context.missingBlackTarget5, 'A nonzero true black read should still shape the low-end target');

console.log('Greyscale black-reference regression checks passed.');

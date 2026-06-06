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

const context = {
  console,
  Math,
  meterReadings: [],
  displayType: 'lcd',
  meterActiveSeriesType: 'greyscale',
  meterColorSeriesReferenceNits(){ return 100; },
  meterColorReferenceNits(){ return 100; },
  meterTargetWhitePoint(){ return { X: 0.95047, Y: 1, Z: 1.08883, x: 0.3127, y: 0.329 }; },
  meterGreyscaleChartWhiteReference(readings){
    return (Array.isArray(readings) ? readings : []).find(reading => Number(reading && reading.ire) === 100) || null;
  },
  meterAnalysisGamut(){
    return { xyzToRgb: [[1,0,0],[0,1,0],[0,0,1]], rgbToXyz: [[1,0,0],[0,1,0],[0,0,1]] };
  },
  xyzToLinRgb(X,Y,Z){ return [X,Y,Z]; },
  linRgbToXyz(R,G,B){ return { X:R, Y:G, Z:B }; },
  document: {
    getElementById(id) {
      if (id === 'meterDisplayType') return { value: context.displayType };
      if (id === 'meterTargetGamma') return { value: 'bt1886' };
      return { value: '' };
    }
  },
  meterChartIsHdr(){ return false; },
  meterChartIsHlg(){ return false; },
  meterChartIsDv(){ return false; },
  meterGreyChartUsesPqTarget(){ return false; },
  meterGreyTargetGammaSelection(){ return 'bt1886'; },
  meterGreyAllowsHeadroomTargets(){ return true; },
  meterGreySignalFractionFromCode(code){ return Math.max(0, (Number(code) - 64) / 876); },
  meterGreyCodeLooksHeadroom(code){ return Number(code) > 255; },
  meterNormalizeMeasuredReading(){},
  meterParseSaturationReading(){ return null; },
  meterColorCheckerFullSatTargetXYZ(){ return { X:0, Y:0, Z:0 }; },
  meterSaturationTargetXYZ(){ return { X:0, Y:0, Z:0 }; },
  targetColorXYZAbs(){ return { X:0, Y:0, Z:0 }; }
};

vm.createContext(context);
vm.runInContext([
  extractFunction('meterReadingAnalysisIre'),
  extractFunction('meterReadingIsGreyscale'),
  extractFunction('meterReadingIsZeroBlack'),
  extractFunction('meterNormalizeOledBlackReading'),
  extractFunction('meterDisplayIsOled'),
  extractFunction('meterChartBlackLevel'),
  extractFunction('meterBlackReadingY'),
  extractFunction('meterReadingLuminanceNits'),
  extractFunction('meterGreyTargetSignal'),
  extractFunction('bt1886Eotf'),
  extractFunction('gammaEotf'),
  extractFunction('srgbEotf'),
  extractFunction('meterGreyTargetLuminance'),
  extractFunction('meterGreyTargetPeak'),
  extractFunction('meterTargetXYZForReading')
].join('\n'), context);

context.meterReadings = [
  { ire: 0, name: '0%', luminance: 0.04, Y: 0.04, series_type: 'greyscale', target_Yn: 0 },
  { ire: 100, name: '100%', luminance: 100, Y: 100, series_type: 'greyscale' }
];

const lcdZero = context.meterTargetXYZForReading({
  ire: 0,
  name: '0%',
  r_code: 64,
  r: 64,
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: 0,
  series_type: 'greyscale'
});
const lcdFour = context.meterTargetXYZForReading({
  ire: 4,
  name: '4%',
  r_code: 99,
  r: 99,
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: Math.pow((99 - 64) / 876, 2.4),
  series_type: 'greyscale'
});
const expectedLiftedFour = context.meterGreyTargetLuminance(4, 100, 0.04, 99);

assert.strictEqual(lcdZero.Y, 0.04, 'LCD 26pt 0% target should follow the measured lifted black level');
assert(Math.abs(lcdFour.Y - expectedLiftedFour) < 1e-12, 'LCD 26pt dark target_Yn patches should use BT.1886 with lifted black');
assert(lcdFour.Y > Math.pow((99 - 64) / 876, 2.4) * 100, 'Lifted black should raise the dark LG26 target above raw target_Yn * white');

context.displayType = 'oled';
context.meterReadings = [
  { ire: 0, name: '0%', luminance: 0, Y: 0, normalized_black: true, series_type: 'greyscale', target_Yn: 0 },
  { ire: 100, name: '100%', luminance: 100, Y: 100, series_type: 'greyscale' }
];
const oledZero = context.meterTargetXYZForReading({
  ire: 0,
  name: '0%',
  r_code: 64,
  r: 64,
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: 0,
  series_type: 'greyscale'
});
assert.strictEqual(oledZero.Y, 0, 'OLED normalized 0% black should still target true black');

context.displayType = 'lcd';
context.meterActiveSeriesType = 'colors';
const color = context.meterTargetXYZForReading({
  name: 'Color patch',
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: 0.2
});
assert.strictEqual(color.Y, 20, 'Color target_Yn should remain normalized to the series white reference');

const colorCheckerGray = context.meterTargetXYZForReading({
  name: 'Gray 35',
  ire: 9,
  r_code: 96,
  g_code: 96,
  b_code: 96,
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: 0.09
});
assert(Math.abs(colorCheckerGray.Y - 9) < 1e-12, 'ColorChecker gray chips should use color-series target_Yn, not greyscale EOTF target Y');

console.log('LG 26 target-Y black regression checks passed.');

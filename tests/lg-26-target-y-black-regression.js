#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

assert(source.includes('my $stamp_series_target_white_y=0;'), 'Series route should not default-stamp ColorChecker/Sat Sweep with stored AutoCal target white');
assert(!source.includes('my $stamp_series_target_white_y=($type eq "colors" || $type eq "saturations") ? 1 : 0;'), 'ColorChecker/Sat Sweep target Y should come from their own White read, not stale LG target-white stamps');

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
  meterWhiteReading: null,
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
  meterUseLgAutoCal26(points){ return Number(points) === 26; },
  meterReadingDisablesAutoCalTargetReference(){ return false; },
  meterReadingIsAutoCalReferenceOnly(){ return false; },
  meterAutoCalGreyscaleTargetWhiteReferenceActive(){ return false; },
  meterStoredLgTargetWhiteReferenceNits(){ return 180; },
  meterDvMapModeValue(){ return '2'; },
  meterChartMasterPeak(){ return 1000; },
  meterFullAutoCalConfig: { targetY: 180 },
  meterFullAutoCalPhase: '',
  meterFullAutoCalRunning: false,
  meterActiveSeriesPoints: 30,
  window: {},
  targetColorXYZAbs(){ return { X:0, Y:0, Z:0 }; }
};
context.window = context;

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
  extractFunction('meterExplicitLgTargetWhiteReferenceNits'),
  extractFunction('meterSeriesUsesLgTargetWhite'),
  extractFunction('meterColorSeriesTargetWhiteForRun'),
  extractFunction('meterApplyColorSeriesTargetWhiteReference'),
  extractFunction('meterColorSeriesReferenceNits'),
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
context.meterActiveSeriesPoints = 30;
context.meterReadings = [
  {
    name: 'White',
    ire: 100,
    r_code: 255,
    g_code: 255,
    b_code: 255,
    luminance: 162,
    Y: 162,
    series_target_white_y: 180,
    lg_target_white_y: 180
  }
];
assert.strictEqual(context.meterSeriesUsesLgTargetWhite('colors', 30), false, 'ColorChecker should not opt into stored LG target-white injection');
assert.strictEqual(context.meterColorSeriesTargetWhiteForRun('colors', 30), null, 'ColorChecker series starts should not send stored AutoCal target white');
const colorSteps = context.meterApplyColorSeriesTargetWhiteReference([{ name: 'White' }], 'colors', 30);
assert.strictEqual(colorSteps[0].series_target_white_y, undefined, 'ColorChecker steps should not be stamped with stored AutoCal target white');
assert.strictEqual(context.meterColorSeriesReferenceNits(), 162, 'ColorChecker target Y should use the measured series White even if stale LG target fields are present');
const color = context.meterTargetXYZForReading({
  name: 'Color patch',
  target_x: 0.3127,
  target_y: 0.329,
  target_Yn: 0.2
});
assert.strictEqual(color.Y, 32.4, 'Color target_Yn should remain normalized to the measured series white reference');

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
assert(Math.abs(colorCheckerGray.Y - 14.58) < 1e-12, 'ColorChecker gray chips should use color-series target_Yn and measured series White, not greyscale EOTF or stale LG target Y');

console.log('LG 26 target-Y black regression checks passed.');

#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');
const vm = require('vm');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = webui.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
  let i = webui.indexOf('{', start);
  let depth = 0;
  for (; i < webui.length; i++) {
    const ch = webui[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return webui.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

function sliceBetween(startNeedle, endNeedle, label) {
  const start = webui.indexOf(startNeedle);
  assert(start >= 0, `${label} start should exist`);
  const end = webui.indexOf(endNeedle, start);
  assert(end > start, `${label} end should exist`);
  return webui.slice(start, end);
}

const context = {
  Number,
  Math,
  console
};

vm.createContext(context);
vm.runInContext([
  'function meterNormalizeMeasuredReading(reading){ return reading; }',
  'function meterTargetWhitePoint(){ return {X:0.95047,Y:1,Z:1.08883,x:0.3127,y:0.329}; }',
  'function meterTargetXYZForReading(reading){ const y=Number(reading&&reading.targetY); const Y=Number.isFinite(y)?y:12; return {X:0.95047*Y,Y,Z:1.08883*Y}; }',
  'function meterResolveGreyRefMode(mode){ if(mode===true) return "eotf"; if(mode===false) return "relative"; return mode||"relative"; }',
  'function meterDeltaEForm(){ return "deitp"; }',
  'function meterGrayWorldWeight(){ return 1; }',
  'function meterColorLabWhite(){ return {X:95.047,Y:100,Z:108.883}; }',
  'function meterGreyDeltaTargetXYZ(reading,inclLum){ return meterTargetXYZForReading(reading); }',
  'function xyzToLab(X,Y,Z){ return {L:Y,a:X,b:Z}; }',
  'function meterDeltaE(labM,labT,form,ctx){ return Math.abs((ctx.Yref||0)-(ctx.Ym||0)) + Math.abs((ctx.Xr||0)-(ctx.X||0))*0.01; }',
  'function deltaE2000(labM,labT){ return Math.abs(labT.L-labM.L); }',
  extractFunction('meterReadingPlotIre'),
  extractFunction('meterReadingAnalysisIre'),
  extractFunction('meterReadingIsGreyscale'),
  extractFunction('meterReadingIsZeroBlack'),
  extractFunction('meterReadingLuminanceNits'),
  extractFunction('meterReadingXYZ'),
  extractFunction('meterReadingIsFailedNonZeroBlack'),
  extractFunction('meterZeroXYZForFailedNonZeroBlack'),
  extractFunction('meterGreyDeltaResult'),
  extractFunction('meterSplitChartLineSegments')
].join('\n'), context);

const failed30 = {
  series_type: 'greyscale',
  name: '30%',
  ire: 30,
  stimulus: 30,
  r_code: 82,
  g_code: 82,
  b_code: 82,
  luminance: 0,
  X: 0,
  Y: 0,
  Z: 0,
  targetY: 12
};
const trueBlack = {
  series_type: 'greyscale',
  name: '0%',
  ire: 0,
  stimulus: 0,
  r_code: 16,
  g_code: 16,
  b_code: 16,
  luminance: 0,
  X: 0,
  Y: 0,
  Z: 0,
  targetY: 0
};
context.failed30 = failed30;
context.trueBlack = trueBlack;

assert.strictEqual(
  vm.runInContext('meterReadingIsFailedNonZeroBlack(failed30)', context),
  true,
  'A non-zero greyscale patch measured at Y=0 should be classified as a failed zero-luminance reading'
);
assert.strictEqual(
  vm.runInContext('meterReadingIsFailedNonZeroBlack(trueBlack)', context),
  false,
  'The real 0% black patch should remain valid black, not a failed non-zero read'
);

const rawDe = vm.runInContext("meterGreyDeltaResult(failed30,'eotf','deitp',1).value", context);
assert(Number.isFinite(rawDe) && rawDe > 10, 'Luminance-inclusive dE should become large for non-zero Y=0 readings');
assert(
  Number.isNaN(vm.runInContext("meterGreyDeltaResult(failed30,'absolute','deitp',1).value", context)),
  'Chroma-only dE should not report fake perfect zero when chroma is invalid at Y=0'
);
assert.strictEqual(
  vm.runInContext("meterGreyDeltaResult(trueBlack,'eotf','deitp',1).value", context),
  0,
  'True black should keep the existing zero-error behavior'
);

const split = vm.runInContext('meterSplitChartLineSegments([[0,0.1],[0.1,0.2],null,[0.3,0.4]])', context);
assert.strictEqual(
  JSON.stringify(split),
  JSON.stringify([[[0, 0.1], [0.1, 0.2]], [[0.3, 0.4]]]),
  'Chart line segments should break across invalid points'
);

const primaryDeltaChart = sliceBetween(
  'function drawDeltaEChart(gs,allSteps,readingMap,rawGs)',
  'function drawDeltaE2000Chart(gs,allSteps,readingMap)',
  'primary greyscale dE chart'
);
assert(
  !primaryDeltaChart.includes('deMap[rd.ire]=0;return;') &&
    primaryDeltaChart.includes('Number.isFinite(value)?value:null'),
  'Primary dE chart must not coerce non-zero Y=0 readings to 0.00'
);

const referenceDeltaChart = sliceBetween(
  'function drawDeltaE2000Chart(gs,allSteps,readingMap)',
  'function drawDeltaE2000Preset(gsSteps)',
  'reference dE2000 chart'
);
assert(
  referenceDeltaChart.includes('!meterReadingIsFailedNonZeroBlack(rd)') &&
    referenceDeltaChart.includes("meterResolveGreyRefMode(greyMode)!=='eotf'"),
  'Reference dE2000 chart should only keep zero dE for true black, not failed non-zero black'
);

const rgbChart = sliceBetween(
  'function drawRGBChart(gs,allSteps,readingMap)',
  'function drawEOTFChart(gs,allSteps,readingMap)',
  'RGB balance chart'
);
assert(
  rgbChart.includes('meterReadingIsFailedNonZeroBlack') &&
    rgbChart.includes('drawLineSegments') &&
    rgbChart.includes('invalidPts'),
  'RGB balance chart should break and mark non-zero Y=0 readings instead of drawing fake 100/100/100 balance'
);

const gammaChart = sliceBetween(
  'function drawGammaValueChart(gs,allSteps,readingMap)',
  '///////////////////////////////////////////////',
  'gamma value chart'
);
assert(
  gammaChart.includes('gammaInvalidMap') &&
    gammaChart.includes('drawLineSegments') &&
    gammaChart.includes('invalidPts'),
  'Gamma chart should break and mark non-zero Y=0 readings instead of connecting through them'
);

const reportTable = sliceBetween(
  'function meterBuildGreyscaleReportTable()',
  'function meterBuildEmptySeriesReportSection(title)',
  'greyscale report table'
);
assert(
  !reportTable.includes("de='0.00'") &&
    reportTable.includes('meterColorDeltaE2000(rd,greyMode,deForm,meterGrayWorldWeight())') &&
    reportTable.includes('meterFormatFixedOrDash(bal&&bal.R,1)'),
  'Greyscale report table should not report non-zero Y=0 readings as 0.00 dE or fake RGB balance'
);

const eotfChart = sliceBetween(
  'function drawEOTFChart(gs,allSteps,readingMap)',
  'function meterDrawDeltaSummary',
  'EOTF chart'
);
const luminanceChart = sliceBetween(
  'function drawGammaChart(gs,allSteps,readingMap)',
  'function drawDeltaEChart(gs,allSteps,readingMap,rawGs)',
  'luminance chart'
);
assert(
  eotfChart.includes('r.luminance!=null && r.luminance>=0') &&
    luminanceChart.includes('r.luminance!=null && r.luminance>=0'),
  'EOTF and luminance charts should continue to include real zero-Y readings'
);

console.log('greyscale zero-Y chart regression checks passed.');

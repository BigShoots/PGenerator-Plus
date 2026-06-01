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

const code = [
  'const METER_CHART_LOG_KNEE_DIVISOR=10000;',
  'const METER_LUMINANCE_LOG_FLOOR_DIVISOR=1000000;',
  'function meterGreyChartStimulusIre(item){ return item&&item.stimulus!=null?Number(item.stimulus):(item&&item.ire!=null?Number(item.ire):null); }',
  'function meterGreyChartPlotIre(item){ return item&&item.plot_ire!=null?Number(item.plot_ire):(item&&item.ire!=null?Number(item.ire):null); }',
  'function meterGreyChartTargetCode(){ return null; }',
  'function meterPatchRangeMin(){ return 0; }',
  'function meterGreyTargetSignal(ire){ const n=Number(ire); return Number.isFinite(n)?Math.max(0,n/100):NaN; }',
  'function meterGreyEotfLuminanceChartX(step,steps,idx,axisMax){ const plot=meterGreyEotfLuminancePlotIre(step); const max=Math.max(1,Number(axisMax)||100); return Number.isFinite(Number(plot))?Math.max(0,Math.min(max,Number(plot)))/max:0; }',
  'function meterGreyTargetEotfChartValueForSignal(signal){ return Number(signal); }',
  'function meterGreyTargetLuminanceForChartPoint(signal,targetPeak){ return Number(signal)*(Number(targetPeak)||100); }',
  'function meterGreyTargetEotfChartValue(ire){ return meterGreyTargetSignal(ire); }',
  'function meterGreyTargetChartValue(ire,targetPeak){ return meterGreyTargetSignal(ire)*(Number(targetPeak)||100); }',
  'function meterReadingLuminanceNits(reading){ return reading&&(reading.luminance!=null?Number(reading.luminance):Number(reading.Y)); }',
  'function meterUseTargetShapedMeasuredEotfLuminanceCurve(){ return true; }',
  extractFunction('meterEotfLogScaleEnabled'),
  extractFunction('meterLuminanceLogScaleEnabled'),
  extractFunction('meterEotfLuminanceLogScaleEnabledForMode'),
  extractFunction('meterLogScaleValue'),
  extractFunction('meterLuminanceLogFloor'),
  extractFunction('meterEotfScaleValue'),
  extractFunction('meterLuminanceScaleValue'),
  extractFunction('meterEotfLuminanceLogPointAllowed'),
  extractFunction('meterScaleEotfLuminancePlotValue'),
  extractFunction('meterGreyDenseTargetCurvePoints'),
  extractFunction('meterGreyNominalTargetCurvePoints'),
  extractFunction('meterGreyEotfLuminancePlotIre'),
  extractFunction('meterEotfLuminanceMeasuredStepAllowed'),
  extractFunction('meterTargetShapedCurveFraction'),
  extractFunction('meterDensifyTargetShapedMeasuredSegment'),
  extractFunction('meterUniqueMeasuredRowsByPlotX'),
  extractFunction('meterDirectMeasuredEotfLuminanceSegments'),
  extractFunction('meterTargetShapedMeasuredSegments'),
  extractFunction('meterMeasuredEotfLuminanceSegments')
].join('\n\n');

const context = {
  console,
  Math,
  Number,
  document: {
    elements: {
      meterEotfLogScale: { checked: true },
      meterLuminanceLogScale: { checked: true }
    },
    getElementById(id) {
      return this.elements[id] || null;
    }
  },
  steps: [
    { ire: 0, stimulus: 0, plot_ire: 0 },
    { ire: 5, stimulus: 5, plot_ire: 5 },
    { ire: 10, stimulus: 10, plot_ire: 10 }
  ],
  readingMap: {
    0: { ire: 0, luminance: 0 },
    5: { ire: 5, luminance: 0.2 },
    10: { ire: 10, luminance: 1.0 }
  }
};

vm.createContext(context);
vm.runInContext(code, context);

assert.strictEqual(
  vm.runInContext("meterEotfLuminanceLogPointAllowed('eotf',0.5,null,null)", context),
  true,
  'Log-scale point gating should not treat null plot/signal as explicit zero'
);
assert.strictEqual(
  vm.runInContext("meterEotfLuminanceLogPointAllowed('luminance',0.5,'','')", context),
  true,
  'Log-scale point gating should not treat empty plot/signal as explicit zero'
);
assert.strictEqual(
  vm.runInContext("meterScaleEotfLuminancePlotValue('eotf',0.5,1,null,null)!=null", context),
  true,
  'Measured EOTF scaling with null plot/signal should keep valid positive luminance'
);
assert.strictEqual(
  vm.runInContext("meterScaleEotfLuminancePlotValue('luminance',0.5,100,'','')!=null", context),
  true,
  'Measured luminance scaling with empty plot/signal should keep valid positive luminance'
);
assert.strictEqual(
  vm.runInContext("meterEotfLuminanceLogPointAllowed('eotf',0.5,0,null)", context),
  true,
  'Explicit 0% plot should remain available for the black origin in log mode'
);
assert.strictEqual(
  vm.runInContext("meterScaleEotfLuminancePlotValue('luminance',0,100,0,0)!=null", context),
  true,
  'Log luminance scaling should keep an explicit black origin point'
);
assert(
  vm.runInContext("meterScaleEotfLuminancePlotValue('luminance',0.00005,100,null,null)", context) > 0,
  'Tiny positive luminance below the old log floor should map continuously above black'
);
assert.strictEqual(
  vm.runInContext("meterEotfLuminanceLogPointAllowed('luminance',-0.01,null,null)", context),
  false,
  'Negative luminance value should still be skipped in log mode'
);

function assertSmoothLowEnd(points, label) {
  assert(Array.isArray(points) && points.length > 0, `${label} should produce points`);
  assert(points.every(point => Array.isArray(point) && point.length >= 2), `${label} points should be x/y pairs`);
  const low = points.filter(point => point[0] >= -1e-12 && point[0] <= 0.05 + 1e-12);
  assert(low.length > 4, `${label} should include dense low-end points between 0% and 5%`);
  assert(Math.abs(low[0][0]) < 1e-12, `${label} should keep the real 0% black origin`);
  assert(low.some(point => point[0] > 0 && point[0] < 0.05), `${label} should not jump directly from 0% to 5%`);
  assert(low.some(point => Math.abs(point[0] - 0.05) < 1e-9), `${label} should include the first measured/target 5% point`);
  for (let i = 1; i < low.length; i++) {
    assert(low[i][0] > low[i - 1][0], `${label} low-end x values should increase monotonically`);
    assert(low[i][1] >= low[i - 1][1] - 1e-12, `${label} low-end y values should not fall`);
  }
  const positiveLow = low.filter(point => point[0] > 0);
  assert(positiveLow[0][1] > low[0][1], `${label} first positive point should rise above true black`);
  const earlyY = positiveLow.slice(0, Math.min(5, positiveLow.length)).map(point => point[1].toFixed(12));
  assert(new Set(earlyY).size > 1, `${label} should not flatten early positives onto a log floor`);
}

const targetEotf = vm.runInContext("meterGreyNominalTargetCurvePoints(100,0,1,'eotf',100,steps)", context);
assertSmoothLowEnd(targetEotf, 'Log EOTF target curve');

const targetLuminance = vm.runInContext("meterGreyNominalTargetCurvePoints(100,0,100,'luminance',100,steps)", context);
assertSmoothLowEnd(targetLuminance, 'Log luminance target curve');

const measuredEotf = vm.runInContext(`
meterMeasuredEotfLuminanceSegments(
  steps,
  readingMap,
  100,
  signal => Number(signal),
  lum => meterScaleEotfLuminancePlotValue('eotf', Number(lum), 1, null, Number(lum)),
  'eotf'
)
`, context);
assert.strictEqual(measuredEotf.length, 1, 'Log EOTF measured curve should produce one positive segment');
assertSmoothLowEnd(measuredEotf[0], 'Log EOTF measured curve');

const measuredLuminance = vm.runInContext(`
meterMeasuredEotfLuminanceSegments(
  steps,
  readingMap,
  100,
  signal => Number(signal) * 100,
  lum => meterScaleEotfLuminancePlotValue('luminance', Number(lum), 100, null, Number(lum)),
  'luminance'
)
`, context);
assert.strictEqual(measuredLuminance.length, 1, 'Log luminance measured curve should produce one positive segment');
assertSmoothLowEnd(measuredLuminance[0], 'Log luminance measured curve');

context.document.elements.meterEotfLogScale.checked = false;
const linearEotf = vm.runInContext("meterGreyNominalTargetCurvePoints(100,0,1,'eotf',100,steps)", context);
assert(linearEotf.some(point => Math.abs(point[0]) < 1e-12), 'Linear EOTF target curve should keep the 0% point');

console.log('EOTF/luminance log roll-on regression passed');

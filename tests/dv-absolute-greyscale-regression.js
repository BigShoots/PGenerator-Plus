const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const seriesSource = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing function ${name}`);
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

const code = [
  'const METER_LG_GREY_MANUAL_22_ENABLED=false;',
  extractFunction('clampNum'),
  extractFunction('gammaEotf'),
  extractFunction('srgbEotf'),
  extractFunction('meterDvAbsoluteTargetRollOffFraction'),
  extractFunction('meterChartPqDecodeNormalized'),
  extractFunction('meterChartPqEncodeNormalized'),
  extractFunction('meterDvAbsoluteChartTargetLuminance'),
  extractFunction('meterDvAbsoluteReadingTargetY'),
  extractFunction('meterCodeFromSignalPercent'),
  extractFunction('meterLgSdrExtendedCodeFromPercent'),
  extractFunction('meterCodeFromSignalPercentWithOptions'),
  extractFunction('meterLgGreyscaleUsesExtendedSdr'),
  extractFunction('meterUseLgGreyscale21'),
  extractFunction('meterUseLgAutoCal26'),
  extractFunction('meterGreyAllowsHeadroomTargets'),
  extractFunction('meterLgGreyscaleUsesLegalSdrDdcCodes'),
  extractFunction('meterGreyStimulusFraction'),
  extractFunction('meterBuildStepsJS')
].join('\n\n');

const grey21 = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100];
const meterGreySeriesSlots = (points) => {
  if (points === 100) return Array.from({ length: 101 }, (_, index) => index);
  return points === 11 ? [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100] : grey21;
};
const state = {
  signal_mode: 'dv',
  dv_map_mode: '1',
  meterTargetGamma: 'st2084',
  rgb_quant_range: '2',
  color_format: '0'
};

const context = {
  console,
  Math,
  meterActiveSeriesType: 'greyscale',
  meterActiveSeriesSignalMode: 'dv',
  meterActiveSeriesPoints: 21,
  document: {
    getElementById(id) {
      return { value: Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '' };
    }
  },
  getVal(id) {
    return Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '';
  },
  clampNum(v, min, max) {
    return Math.max(min, Math.min(max, Number(v) || 0));
  },
  meterChartIsDv() {
    return state.signal_mode === 'dv';
  },
  meterDvMapModeValue() {
    return state.dv_map_mode;
  },
  meterDvAutoTargetGamma() {
    return state.dv_map_mode === '2' ? '2.2' : 'st2084';
  },
  meterPatchRangeMin() {
    return state.rgb_quant_range === '1' ? 16 : 0;
  },
  meterPatchRangeSpan() {
    return state.rgb_quant_range === '1' ? 219 : 255;
  },
  meterGreyCodeRange() {
    return state.signal_mode === 'dv'
      ? { min: 16, span: 219 }
      : { min: state.rgb_quant_range === '1' ? 16 : 0, span: state.rgb_quant_range === '1' ? 219 : 255 };
  },
  meterGreySignalFractionFromCode(code) {
    const min = state.signal_mode === 'dv' || state.rgb_quant_range === '1' ? 16 : 0;
    const span = state.signal_mode === 'dv' || state.rgb_quant_range === '1' ? 219 : 255;
    return Math.max(0, Math.min(1, ((Number(code) || 0) - min) / span));
  },
  meterDvRelativeSt2084UsesLegalRange() {
    return false;
  },
  meterReadingIsGreyscale(reading) {
    if (!reading) return false;
    if (String(reading.series_type || '').toLowerCase() === 'greyscale') return true;
    const r = reading.r_code != null ? reading.r_code : reading.r;
    const g = reading.g_code != null ? reading.g_code : reading.g;
    const b = reading.b_code != null ? reading.b_code : reading.b;
    return r != null && g != null && b != null && Number(r) === Number(g) && Number(g) === Number(b);
  },
  meterReadingAnalysisIre(reading) {
    const candidates = [reading.analysis_ire, reading.target_ire, reading.stimulus, reading.ire];
    for (const value of candidates) {
      const ire = Number(value);
      if (Number.isFinite(ire)) return ire;
    }
    return null;
  },
  meterPatchUsesVideoRange() {
    return state.rgb_quant_range === '1';
  },
  meterSignalFractionFromCode(code) {
    const min = state.rgb_quant_range === '1' ? 16 : 0;
    const span = state.rgb_quant_range === '1' ? 219 : 255;
    return Math.max(0, Math.min(1, ((Number(code) || 0) - min) / span));
  },
  meterGreySeriesSlots,
  meterGreyTvControlsActive() {
    return false;
  },
  meterGreySignalEntries(points) {
    return meterGreySeriesSlots(points).map(slot => ({
      slot,
      stimulus: slot,
      r: slot,
      g: slot,
      b: slot
    }));
  },
  meterFormatPercentValue(value) {
    return String(Math.round(Number(value) * 10) / 10).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
  },
  meterGreyStimulusValues(points) {
    return meterGreySeriesSlots(points);
  },
  meterBuildColorCheckerStepsJS() {
    return [];
  },
  meterBuildSaturationStepRgb() {
    return [0, 0, 0];
  },
  meterApplyColorSeriesTargetWhiteReference(steps) {
    return steps;
  }
};
context.window = context;

vm.createContext(context);
vm.runInContext(code, context);

const expectedLegal45 = Math.round(16 + 0.45 * 219);
assert.strictEqual(context.meterCodeFromSignalPercent(45), expectedLegal45, 'DV absolute 45% greyscale should emit legal RGB tunnel level');
assert(Math.abs(context.meterGreyStimulusFraction(45) - ((expectedLegal45 - 16) / 219)) < 1e-12, 'DV absolute 45% greyscale stimulus fraction mismatch');

const steps = context.meterBuildStepsJS('greyscale', 21);
assert.strictEqual(steps[0].ire, 100, 'DV absolute greyscale should measure White first');
assert.strictEqual(steps[0].r, 235, 'DV absolute White should emit legal white');
const step45 = steps.find(step => step.ire === 45);
assert(step45, 'Missing DV absolute 45% greyscale step');
assert.strictEqual(step45.r, expectedLegal45, 'DV absolute 45% greyscale series code mismatch');

assert(
  seriesSource.includes('dv_tunnel_gamma = 2.2') &&
    seriesSource.includes('return 16, 219') &&
    seriesSource.includes('(target_y / white_y) ** (1 / dv_tunnel_gamma)') &&
    seriesSource.includes('step["dv_absolute_rolloff_pct"] = pq_encode_normalized(white_y) * 100') &&
    seriesSource.includes('step["dv_absolute_tunnel_gamma"] = dv_tunnel_gamma'),
  'DV absolute helper-side greyscale rewrite should use legal RGB tunnel range with the 2.2 carrier exponent'
);

function dvAbsoluteHelperCode(percent, whiteY) {
  const targetY = Math.min(whiteY, context.meterChartPqDecodeNormalized(percent / 100));
  const encoded = targetY <= 0 ? 0 : Math.pow(targetY / whiteY, 1 / 2.2);
  return Math.max(16, Math.min(235, Math.round(16 + encoded * 219)));
}

assert.deepStrictEqual(
  [5, 10, 15, 20, 25].map(percent => dvAbsoluteHelperCode(percent, 733.89)),
  [19, 23, 27, 32, 39],
  'DV absolute helper-side patch codes should be legal-range ST.2084 targets through the measured-white 2.2 tunnel'
);

const abs50 = context.meterDvAbsoluteChartTargetLuminance(50, 10000);
const abs75 = context.meterDvAbsoluteChartTargetLuminance(75, 10000);
const abs100 = context.meterDvAbsoluteChartTargetLuminance(100, 10000);
assert(Math.abs(abs50 - context.meterChartPqDecodeNormalized(0.5)) < 1e-9, 'DV absolute 50% target should decode direct PQ signal');
assert(abs100 > abs75, 'Unclipped DV absolute target should continue rising through 100%');
const measuredRoll = context.meterDvAbsoluteTargetRollOffFraction(750);
assert(Math.abs(measuredRoll - context.meterChartPqEncodeNormalized(750)) < 1e-12, 'DV absolute roll-off should derive from measured peak');
const clippedAbs75 = context.meterDvAbsoluteChartTargetLuminance(75, 750);
const clippedAbs100 = context.meterDvAbsoluteChartTargetLuminance(100, 750);
assert.strictEqual(clippedAbs75, 750, 'DV absolute chart target should roll off at measured peak');
assert.strictEqual(clippedAbs100, 750, 'DV absolute chart target should stay clipped above measured peak');
assert.strictEqual(
  context.meterDvAbsoluteReadingTargetY({ series_type: 'greyscale', r_code: 27, g_code: 27, b_code: 27, dv_absolute_target_y: 1.001, analysis_ire: 15 }),
  1.001,
  'DV absolute greyscale delta target should prefer stamped measured-white target Y'
);
const fallbackTarget = context.meterDvAbsoluteReadingTargetY({ series_type: 'greyscale', r_code: 32, g_code: 32, b_code: 32, dv_absolute_white_y: 750, analysis_ire: 20 });
assert(Math.abs(fallbackTarget - context.meterDvAbsoluteChartTargetLuminance(20, 750, null)) < 1e-12, 'DV absolute greyscale delta target should fall back to measured white metadata');

console.log('DV absolute greyscale regression checks passed.');

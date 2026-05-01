const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

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
  extractFunction('meterCodeFromSignalPercent'),
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
  meterTargetGamma: 'bt1886',
  rgb_quant_range: '2',
  color_format: '0'
};

const context = {
  console,
  Math,
  meterActiveSeriesType: 'greyscale',
  meterActiveSeriesSignalMode: 'dv',
  document: {
    getElementById(id) {
      return { value: Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '' };
    }
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
    return '2.2';
  },
  meterPatchRangeMin() {
    return state.rgb_quant_range === '1' ? 16 : 0;
  },
  meterPatchRangeSpan() {
    return state.rgb_quant_range === '1' ? 219 : 255;
  },
  meterGreyCodeRange() {
    return { min: state.rgb_quant_range === '1' ? 16 : 0, span: state.rgb_quant_range === '1' ? 219 : 255 };
  },
  meterGreySignalFractionFromCode(code) {
    const min = state.rgb_quant_range === '1' ? 16 : 0;
    const span = state.rgb_quant_range === '1' ? 219 : 255;
    return Math.max(0, Math.min(1, ((Number(code) || 0) - min) / span));
  },
  meterDvRelativeSt2084UsesLegalRange() {
    return false;
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
  meterGreyStimulusValues(points) {
    return meterGreySeriesSlots(points);
  },
  meterBuildColorCheckerStepsJS() {
    return [];
  },
  meterBuildSaturationStepRgb() {
    return [0, 0, 0];
  }
};
context.window = context;

vm.createContext(context);
vm.runInContext(code, context);

assert.strictEqual(context.meterCodeFromSignalPercent(45), 115, 'DV absolute 45% greyscale should emit code 115');
assert(Math.abs(context.meterGreyStimulusFraction(45) - (115 / 255)) < 1e-12, 'DV absolute 45% greyscale stimulus fraction mismatch');

const steps = context.meterBuildStepsJS('greyscale', 21);
assert.strictEqual(steps[0].ire, 100, 'DV absolute greyscale should measure White first');
assert.strictEqual(steps[0].r, 255, 'DV absolute White should emit code 255');
const step45 = steps.find(step => step.ire === 45);
assert(step45, 'Missing DV absolute 45% greyscale step');
assert.strictEqual(step45.r, 115, 'DV absolute 45% greyscale series code mismatch');

console.log('DV absolute greyscale regression checks passed.');
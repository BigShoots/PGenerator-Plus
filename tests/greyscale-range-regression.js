const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const lgSource = fs.readFileSync('usr/sbin/pgenerator-lg', 'utf8');

assert(
  !source.includes('int($level*255/219+.5)'),
  'server greyscale full-range path must not re-scale from a rounded legal-range code'
);
assert(
  source.includes('int($stimulus_pct/100*255 + .5)'),
  'server greyscale full-range path should use direct 0-255 rounding'
);
assert(
  lgSource.includes('@LG_DDC_1D_INDEXES=map { &lg_ddc_legal_video_8bit_for_ire($_) << 2 }'),
  'LG DDC 1D LUT bins should stay aligned to legal limited-range patch codes'
);
assert(
  lgSource.includes('sub lg_ddc_interpolated_offset_at_index'),
  'LG DDC writes should build an interpolated 1D LUT curve rather than broad nearest-point shelves'
);
assert(
  lgSource.includes('&lg_ddc_interpolated_offset_at_index($i,$channels[$channel],$baseline,$channel)'),
  'LG DDC 1D LUT builder should apply the interpolated offset curve'
);
assert(
  source.includes('const targetStep=meterClonePatchStep(selectedStep);') &&
    source.includes('meterPauseContinuousForPriorityWrite(targetStep)'),
  'LG RGB writes should snapshot and restore the selected greyscale patch while continuous read is paused'
);
assert(
  source.includes('_timeoutMs:90000'),
  'LG RGB writes should allow enough time for slow webOS 1D LUT uploads'
);
assert(
  source.includes('function lgBeginCommand(label)') &&
    source.includes('noteLgBusyConnectionDelay()') &&
    source.includes("lgBeginCommand('LG TV '+target.label+' '+channelLabel+' adjustment')"),
  'LG TV writes should expose a visible busy state and suppress unrelated connection-error toasts'
);
assert(
  source.includes('meter-lg-rgb-busy') &&
    source.includes('function meterGreyTvBusyHtml()') &&
    source.includes('syncMeterLgRgbBusyIndicator()'),
  'LG RGB white-balance widget should show the LG command busy state during manual adjustments'
);

function extractConst(name) {
  const token = `const ${name}=`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing const ${name}`);
  let i = start;
  while (i < source.length && source[i] !== ';') i++;
  return source.slice(start, i + 1);
}

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
  extractConst('METER_GREY_SLOTS_11'),
  extractConst('METER_GREY_SLOTS_21'),
  extractConst('METER_LG_GREY_DDC_SLOTS_22'),
  extractConst('METER_LG_GREY_SERIES_SLOTS'),
  "let meterGreyPatchProfiles={format:'pgenerator-greyscale-profile-v2',apply_to_all_modes:false,profiles:{}};",
  extractFunction('clampNum'),
  extractFunction('meterDvMapModeValue'),
  extractFunction('meterDvAutoTargetGamma'),
  extractFunction('meterChartSignalMode'),
  extractFunction('meterChartIsDv'),
  extractFunction('meterFormatPercentValue'),
  extractFunction('meterIsLimitedRange'),
  extractFunction('meterOutputIsRgb'),
  extractFunction('meterGreyscaleUsesFullSourceRange'),
  extractFunction('meterPatchUsesVideoRange'),
  extractFunction('meterPatchRangeMin'),
  extractFunction('meterPatchRangeSpan'),
  extractFunction('meterDvRelativeSt2084UsesLegalRange'),
  extractFunction('meterGreyCodeRange'),
  extractFunction('meterDvTunnelGamma'),
  extractFunction('meterCodeFromSignalPercent'),
  extractFunction('meterLgSdrExtendedCodeFromPercent'),
  extractFunction('meterCodeFromSignalPercentWithOptions'),
  extractFunction('meterGreyDefaultSlots'),
  extractFunction('meterUseLgGreyscale21'),
  extractFunction('meterLgGreyscaleUsesExtendedSdr'),
  extractFunction('meterGreySeriesSlots'),
  extractFunction('meterGreyProfileSlots'),
  extractFunction('meterGreyClampPercent'),
  extractFunction('meterGreyNormalizeEntry'),
  extractFunction('meterGreyProfileStepsKey'),
  extractFunction('meterGreyProfileTemplate'),
  extractFunction('meterGreyModeSignature'),
  extractFunction('meterGreyNormalizeProfilesState'),
  extractFunction('meterGreyActiveProfileKey'),
  extractFunction('meterGreyActiveProfile'),
  extractFunction('meterGreyProfileEntry'),
  extractFunction('meterGreySignalEntries'),
  extractFunction('meterBuildStepsJS')
].join('\n\n');

const state = {
  signal_mode: 'sdr',
  rgb_quant_range: '2',
  color_format: '0',
  dv_map_mode: '2',
  meterTargetGamma: 'bt1886',
  meterTwoPointLow: '30',
  meterTwoPointHigh: '100',
  lgPaired: false
};

const context = {
  console,
  Math,
  config: { signal_mode: 'sdr', max_luma: '1000' },
  meterActiveSeriesType: 'greyscale',
  meterActiveSeriesPoints: 21,
  meterActiveSeriesSignalMode: 'sdr',
  document: {
    getElementById(id) {
      return { value: Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '' };
    }
  },
  getVal(id) {
    return Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '';
  },
  meterGreyTvControlsActive() {
    return !!state.lgPaired;
  },
  meterSyncTwoPointInputs() {
    return { low: Number(state.meterTwoPointLow), high: Number(state.meterTwoPointHigh) };
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

function roundCode(value) {
  return Math.round(value);
}

function expectedGreyscaleCode(percent, opts) {
  const pct = Math.max(0, Math.min(100, Number(percent) || 0));
  const clamped = pct / 100;
  const limited = opts.range === '1';
  if (opts.mode === 'dv') {
    if (opts.dvMapMode === '1') {
      const legal = roundCode(16 + clamped * 219);
      if (limited) return legal;
      if (clamped <= 0) return 0;
      if (clamped >= 1) return 255;
      return legal;
    }
    if (opts.targetGamma === 'st2084') {
      return roundCode(16 + clamped * 219);
    }
    const encoded = clamped > 0 ? Math.pow(clamped, 1 / 2.2) : 0;
    return limited ? roundCode(16 + encoded * 219) : roundCode(encoded * 255);
  }
  return limited ? roundCode(16 + clamped * 219) : roundCode(clamped * 255);
}

function setMode(opts) {
  state.signal_mode = opts.mode;
  state.rgb_quant_range = opts.range;
  state.dv_map_mode = opts.dvMapMode || '2';
  state.meterTargetGamma = opts.targetGamma || (opts.mode === 'dv' ? 'st2084' : 'bt1886');
  context.meterActiveSeriesType = 'greyscale';
  context.meterActiveSeriesSignalMode = opts.mode;
  context.meterActiveSeriesPoints = opts.points || 21;
}

const modes = [
  { name: 'SDR', mode: 'sdr' },
  { name: 'HDR10', mode: 'hdr10' },
  { name: 'HLG', mode: 'hlg' },
  { name: 'DV absolute', mode: 'dv', dvMapMode: '1', targetGamma: '2.2' },
  { name: 'DV relative ST2084', mode: 'dv', dvMapMode: '2', targetGamma: 'st2084' },
  { name: 'DV relative gamma', mode: 'dv', dvMapMode: '2', targetGamma: '2.2' }
];
const series = [2, 11, 21, 100];

for (const mode of modes) {
  for (const range of ['1', '2']) {
    for (const points of series) {
      state.lgPaired = false;
      setMode({ ...mode, range, points });
      const steps = context.meterBuildStepsJS('greyscale', points);
      assert(steps.length > 0, `${mode.name} ${range} ${points}pt produced no steps`);
      for (const step of steps) {
        const expectedR = expectedGreyscaleCode(step.signal_r_pct, { ...mode, range });
        const expectedG = expectedGreyscaleCode(step.signal_g_pct, { ...mode, range });
        const expectedB = expectedGreyscaleCode(step.signal_b_pct, { ...mode, range });
        assert.strictEqual(step.r, expectedR, `${mode.name} range ${range} ${points}pt ${step.name} red code`);
        assert.strictEqual(step.g, expectedG, `${mode.name} range ${range} ${points}pt ${step.name} green code`);
        assert.strictEqual(step.b, expectedB, `${mode.name} range ${range} ${points}pt ${step.name} blue code`);
      }
    }
  }
}

state.lgPaired = true;
setMode({ mode: 'sdr', range: '1', points: 21 });
const lgSeries = context.meterBuildStepsJS('greyscale', 21);
const lgSteps = lgSeries
  .slice()
  .sort((a, b) => a.ire - b.ire)
  .map(step => step.ire);
assert.strictEqual(
  JSON.stringify(lgSteps),
  JSON.stringify([0, 2.5, 5, 7.5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]),
  'LG-connected 21pt greyscale should read black plus the 22 LG DDC slots'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 40).r,
  104,
  'LG-connected SDR limited 40% patch should use legal 16-235 source code'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 100).r,
  235,
  'LG-connected SDR limited 100% patch should stay at legal video white'
);

state.lgPaired = false;
setMode({ mode: 'sdr', range: '1', points: 21 });
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 40).r,
  104,
  'legacy SDR limited 40% patch should stay on 16-235 video levels'
);

state.lgPaired = true;
setMode({ mode: 'sdr', range: '2', points: 21 });
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 40).r,
  102,
  'LG-connected SDR full-range 40% patch should keep full-range source levels'
);

function rendererNormalizeSourceValue(value, opts) {
  if (opts.sourceRange !== 'LIMITED') return value;
  if (opts.outputFormat !== '0') return value;
  if (opts.mode !== 'dv' && opts.mode !== 'std_dv' && opts.transportRange !== '1') return value;
  const bitDepth = opts.bitDepth || 8;
  const shift = bitDepth - 8;
  const limitedMin = 16 << shift;
  const limitedSpan = 219 << shift;
  const maxValue = (1 << bitDepth) - 1;
  let normalized = Math.floor(((value - limitedMin) * maxValue) / limitedSpan + 0.5);
  if (normalized < 0) normalized = 0;
  if (normalized > maxValue) normalized = maxValue;
  return normalized;
}

function rgbLimitedWireCode(framebufferCode) {
  return Math.round(16 + framebufferCode * 219 / 255);
}

const legal80 = expectedGreyscaleCode(80, { mode: 'sdr', range: '1' });
const framebuffer80 = rendererNormalizeSourceValue(legal80, {
  sourceRange: 'LIMITED',
  outputFormat: '0',
  transportRange: '1',
  mode: 'sdr',
  bitDepth: 8
});
assert.strictEqual(legal80, 191, '80% limited source code should be legal code 191');
assert.strictEqual(framebuffer80, 204, 'renderer should normalize limited source 191 to framebuffer 204 for RGB limited transport');
assert.strictEqual(rgbLimitedWireCode(framebuffer80), legal80, 'renderer normalization should preserve the requested limited wire code');
assert.strictEqual(
  rendererNormalizeSourceValue(legal80, { sourceRange: 'FULL', outputFormat: '0', transportRange: '1', mode: 'sdr', bitDepth: 8 }),
  legal80,
  'FULL source range must not be normalized by the renderer'
);
assert.strictEqual(
  rendererNormalizeSourceValue(legal80, { sourceRange: 'LIMITED', outputFormat: '1', transportRange: '1', mode: 'sdr', bitDepth: 8 }),
  legal80,
  'YCbCr renderer path should not normalize RGB source values before RGB2YCbCr conversion'
);

console.log('Greyscale range regression checks passed.');

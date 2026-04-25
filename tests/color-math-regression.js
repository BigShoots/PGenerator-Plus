const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractConst(name) {
  const token = `const ${name}=`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing const ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        while (i < source.length && source[i] !== ';') i++;
        return source.slice(start, i + 1);
      }
    }
  }
  throw new Error(`Failed to extract const ${name}`);
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
  extractConst('D65'),
  extractConst('GAMUT_PRESETS'),
  extractFunction('meterDvMapModeValue'),
  extractFunction('meterSignalColorimetryGamutKey'),
  extractFunction('meterAutoTargetGamutKey'),
  extractFunction('meterContainerGamutKey'),
  extractFunction('meterSelectedTargetGamutKey'),
  extractFunction('meterActiveGamutKey'),
  extractFunction('meterContainerGamut'),
  extractFunction('meterActiveGamut'),
  extractFunction('meterAnalysisGamutKey'),
  extractFunction('meterAnalysisGamut'),
  extractFunction('meterStimulusSolveGamut'),
  extractFunction('meterTargetSolveGamut'),
  extractFunction('xyzToLinRgb'),
  extractFunction('linRgbToXyz'),
  extractFunction('meterParseSaturationReading'),
  extractFunction('meterDecodeColorTargetChannel'),
  extractFunction('meterBuildSaturationTargetLinearRgb'),
  extractFunction('meterSaturationTargetXYZ'),
  extractFunction('meterGamutColorEndpointRgb'),
  extractFunction('meterGamutColorEndpointXY'),
  extractFunction('meterGamutColorIsSecondary'),
  extractFunction('meterDvTunnelGamma'),
  extractFunction('meterDvSaturationTunnelGamma'),
  extractFunction('meterTargetLinearToSignal'),
  extractFunction('meterTargetSignalToLinear'),
  extractFunction('meterEncodeSaturationLinear'),
  extractFunction('meterColorLevelPercent'),
  extractFunction('meterActualSignalPercent'),
  extractFunction('meterActualCodePercent'),
  extractFunction('meterColorReferenceNits'),
  extractFunction('meterColorSeriesReferenceNits'),
  extractFunction('meterIsWhiteReferenceReading'),
  extractFunction('meterSaturationStimulusLinearLevel'),
  extractFunction('meterDvRelativeSaturationFraction'),
  extractFunction('meterDvAbsoluteSaturationFraction'),
  extractFunction('meterSaturationSolveGamut'),
  extractFunction('meterSaturationAxisGamut'),
  extractFunction('meterBuildSaturationStepRgb'),
  extractFunction('meterBuildSaturationStimulusLinearRgb'),
  extractFunction('meterChartPqEncodeNormalized'),
  extractFunction('meterChartPqDecodeNormalized'),
  extractFunction('meterChartTrackingLuminance'),
  extractFunction('meterChartHdrPeak'),
  extractFunction('meterChartIsPq'),
  extractFunction('meterChartIsDv'),
  extractFunction('meterChartIsHdr'),
  extractFunction('meterChartSignalMode'),
  extractFunction('meterGreyTargetSignal'),
  extractFunction('meterChartTargetLuminance'),
  extractFunction('meterGreyTargetLuminance'),
  extractFunction('meterResolveGreyRefMode'),
  extractFunction('meterGreyRefMode'),
  extractFunction('meterGrayWorldWeight'),
  extractFunction('targetColorXYZAbs'),
  extractFunction('meterTargetXYZForReading'),
  extractFunction('meterTargetChromaticityForReading'),
  extractFunction('meterColorDeltaTargetXYZ'),
  extractFunction('meterColorIncludeLum'),
  extractFunction('meterLiveRgbData'),
  extractFunction('meterXYYDeltasForLive'),
  extractFunction('meterGreyChartX'),
  extractFunction('meterAnchorOriginPoint'),
  extractFunction('meterGammaValueAnchorPoints'),
  extractFunction('hcfrGreyRef')
].join('\n\n');

const state = {
  colorimetry: '2',
  primaries: '0',
  signal_mode: 'sdr',
  meterTargetGamut: 'auto',
  meterTargetGamma: 'bt1886',
  meterGrayWorld: '1',
  meterGreyRefMode: 'absolute',
  rgb_quant_range: '2',
  color_format: '0'
};

const context = {
  console,
  Math,
  meterActiveSeriesType: 'colors',
  meterWhiteReading: { X: 95.05, Y: 100, Z: 108.9 },
  meterReadings: [],
  meterSeriesCache: {},
  meterActiveSeriesSignalMode: '',
  config: { colorimetry: '2', primaries: '0', signal_mode: 'sdr', max_luma: '1000' },
  document: {
    getElementById(id) {
      return { value: Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '' };
    }
  },
  clampNum(v,min,max){ return Math.max(min, Math.min(max, Number(v)||0)); },
  meterTargetChromaticityForReading(reading){
    const xyz = this.meterTargetXYZForReading(reading);
    const sum = xyz.X + xyz.Y + xyz.Z;
    return sum > 0 ? { x: xyz.X/sum, y: xyz.Y/sum } : { x: this.D65.x, y: this.D65.y };
  },
  meterCodeFromSignalPercent(p){ return Math.round((Number(p)||0) * 255 / 100); },
  meterPatchRangeMin(){ return 0; },
  meterPatchRangeSpan(){ return 255; },
  meterSignalFractionFromCode(code){ return Math.max(0, Math.min(1, (Number(code)||0) / 255)); },
  meterPatchUsesVideoRange(){ return false; },
  meterIncludeLum(){ return false; },
  meterBuildColorCheckerStepsJS(){ return [{ name:'Cyan', series_color:'Cyan', sat_pct:100, r_code:0, g_code:255, b_code:255, r:0, g:255, b:255, iree:100 }]; },
  getVal(){ return 'sdr'; },
  targetEotf(v,Lw){ return Math.pow(Math.max(0, v), 2.4) * (Lw||100); }
};
context.window = context;
context.meterFindMeasuredWhiteReading = () => context.meterWhiteReading;
context.meterChartMasterPeak = () => context.meterChartHdrPeak();
context.meterChartIsHlg = () => false;
context.meterGreySignalFractionFromCode = code => Math.max(0, Math.min(1, (Number(code) || 0) / 255));
vm.createContext(context);
vm.runInContext(code, context);

function approxEqual(actual, expected, tol, message) {
  if (Math.abs(actual - expected) > tol) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

// Test 1: HCFR relative mode should use measured relative Y, not EOTF target Y.
const ref = context.hcfrGreyRef(10, 1, 100, 0, 'relative', 26, 1.0);
approxEqual(ref.refY, 0.01, 0.001, 'relative grey reference Y mismatch');

// Test 2: Color ΔY should be normalized to target Y (so 10% low = -10%).
const colorStep = { name:'Cyan', target_x:0.225, target_y:0.329, target_Yn:0.2 };
const txyz = context.meterTargetXYZForReading(colorStep);
const reading = {
  ...colorStep,
  X: txyz.X * 0.9,
  Y: txyz.Y * 0.9,
  Z: txyz.Z * 0.9,
  x: txyz.X / (txyz.X + txyz.Y + txyz.Z),
  y: txyz.Y / (txyz.X + txyz.Y + txyz.Z),
  luminance: txyz.Y * 0.9
};
const xyy = context.meterXYYDeltasForLive(reading);
if (!xyy || !Array.isArray(xyy.entries)) {
  throw new Error(`meterXYYDeltasForLive returned ${JSON.stringify(xyy)}`);
}
const dY = xyy.entries.find(e => e.key === 'Y').v;
approxEqual(dY, -10, 0.75, 'color ΔY normalization mismatch');

// Test 3: greyscale chart X positions must follow actual IRE, not array index.
const x5 = context.meterGreyChartX({ ire: 5 }, [{ ire: 0 }, { ire: 5 }, { ire: 10 }], 1);
approxEqual(x5, 0.05, 0.0001, 'greyscale chart X mapping mismatch');

// Test 4: gamma chart should start at the first real point, not add a 0% anchor.
state.signal_mode = 'dv';
const dvPts = context.meterGammaValueAnchorPoints([[0.05, 0.95], [0.10, 0.90]]);
approxEqual(dvPts[0][0], 0.05, 0.0001, 'DV gamma chart should not anchor at 0%');
state.signal_mode = 'sdr';
const sdrPts = context.meterGammaValueAnchorPoints([[0.05, 0.95], [0.10, 0.90]]);
approxEqual(sdrPts[0][0], 0.05, 0.0001, 'SDR gamma chart should not anchor at 0%');

// Test 5: in HDR/DV analysis, the selected target gamut must drive the target XYZ.
state.signal_mode = 'hdr10';
state.colorimetry = '9';
state.primaries = '1';
state.meterTargetGamut = 'p3d65';
const hdrRed = context.targetColorXYZAbs(255, 0, 0);
const hdrSum = hdrRed.X + hdrRed.Y + hdrRed.Z;
const hdrX = hdrRed.X / hdrSum;
const hdrY = hdrRed.Y / hdrSum;
approxEqual(hdrX, 0.68, 0.02, 'HDR target gamut x mismatch');
approxEqual(hdrY, 0.32, 0.02, 'HDR target gamut y mismatch');

// Test 6: saturation live deltas must use an absolute target scale so they
// do not pin RGB to +50 or explode Y into thousands of percent.
state.signal_mode = 'sdr';
state.colorimetry = '2';
state.primaries = '0';
state.meterTargetGamut = 'auto';
context.meterActiveSeriesType = 'saturations';
const satReading = {
  name: 'Magenta 50%',
  series_color: 'Magenta',
  sat_pct: 50,
  r_code: 191,
  g_code: 0,
  b_code: 191,
  X: 71.95,
  Y: 53.74,
  Z: 98.60,
  x: 0.3209,
  y: 0.2396,
  luminance: 53.74
};
const satTarget = context.meterTargetXYZForReading(satReading);
if (!(satTarget.Y > 1)) {
  throw new Error(`saturation target Y is not in an absolute scale: ${satTarget.Y}`);
}
const satXyy = context.meterXYYDeltasForLive(satReading);
const satDy = satXyy.entries.find(e => e.key === 'Y').v;
if (!(Math.abs(satDy) < 500)) {
  throw new Error(`saturation ΔY is implausibly large: ${satDy}`);
}
const satRgb = context.meterLiveRgbData(satReading);
if (satRgb.R === 50 && satRgb.G === 50 && satRgb.B === 50) {
  throw new Error(`saturation RGB deltas are pinned at +50: ${JSON.stringify(satRgb)}`);
}

// Test 6b: the actual in-series White patch should stay visible in color
// charts, while the helper-only White Ref remains filtered.
if (context.meterIsWhiteReferenceReading({ name: 'White' })) {
  throw new Error('actual series White patch should remain plottable');
}
if (!context.meterIsWhiteReferenceReading({ name: 'White Ref' })) {
  throw new Error('helper-only White Ref should stay filtered');
}

// Test 7: DV absolute sat sweeps keep the P3 hue axis and now solve RGB in
// the selected target gamut to match the fixed live renderer behavior.
state.signal_mode = 'dv';
state.dv_map_mode = '1';
state.colorimetry = '9';
state.primaries = '1';
state.meterTargetGamut = 'auto';
approxEqual(context.meterColorLevelPercent(), 75, 1e-9, 'DV absolute gamut level should be 75%');
approxEqual(
  context.meterSaturationStimulusLinearLevel('Red'),
  Math.pow(Math.round(0.75 * 255) / 255, context.meterDvSaturationTunnelGamma('Red')),
  1e-9,
  'DV absolute saturation level should use code-range percent before DV gamma'
);
const axisRed = context.meterGamutColorEndpointXY('Red', context.meterSaturationAxisGamut());
const solveRed = context.meterGamutColorEndpointXY('Red', context.meterSaturationSolveGamut());
approxEqual(axisRed.x, 0.68, 1e-9, 'DV absolute saturation axis x mismatch');
approxEqual(axisRed.y, 0.32, 1e-9, 'DV absolute saturation axis y mismatch');
approxEqual(solveRed.x, 0.68, 1e-9, 'DV absolute saturation solve x mismatch');
approxEqual(solveRed.y, 0.32, 1e-9, 'DV absolute saturation solve y mismatch');
approxEqual(context.meterDvSaturationTunnelGamma('Red'), 3.8, 1e-9, 'DV absolute primary sat tunnel gamma mismatch');
approxEqual(context.meterDvSaturationTunnelGamma('Cyan'), 3.8, 1e-9, 'DV absolute secondary sat tunnel gamma mismatch');
const red25 = context.meterBuildSaturationStepRgb('Red', 25);
const cyan25 = context.meterBuildSaturationStepRgb('Cyan', 25);
const cyan50 = context.meterBuildSaturationStepRgb('Cyan', 50);
[191, 134, 134].forEach((value, idx) => approxEqual(red25[idx], value, 1e-9, `DV absolute Red 25 code ${idx} mismatch`));
[162, 191, 191].forEach((value, idx) => approxEqual(cyan25[idx], value, 1e-9, `DV absolute Cyan 25 code ${idx} mismatch`));
[132, 191, 191].forEach((value, idx) => approxEqual(cyan50[idx], value, 1e-9, `DV absolute Cyan 50 code ${idx} mismatch`));

// Test 8: DV relative keeps the HDR-style 50% gamut level.
state.dv_map_mode = '2';
approxEqual(context.meterColorLevelPercent(), 50, 1e-9, 'DV relative gamut level should stay at 50%');

// Test 9: DV absolute target luminance stays anchored to mastering peak even
// when a measured white reference exists.
state.dv_map_mode = '1';
context.meterWhiteReading = { X: 158.5, Y: 166.7, Z: 181.5 };
approxEqual(context.meterColorReferenceNits(), 1000, 1e-9, 'DV absolute should stay anchored to mastering peak');

// Test 10: color-series target Y should use the measured White patch when one
// is available, even in DV absolute mode.
const dvColorStep = { name:'Orange', target_x:0.512087, target_y:0.410373, target_Yn:0.285811070494883 };
const dvTarget = context.meterTargetXYZForReading(dvColorStep);
approxEqual(dvTarget.Y, 166.7 * dvColorStep.target_Yn, 1e-6, 'DV absolute color-series target Y should follow measured White');

console.log('All color-math regression checks passed.');

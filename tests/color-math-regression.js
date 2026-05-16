const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const GAMUT_PRESETS_JS = `const GAMUT_PRESETS={
 bt709:{label:'BT.709 / D65',white:{x:0.3127,y:0.3290},primaries:{R:{x:0.64,y:0.33},G:{x:0.30,y:0.60},B:{x:0.15,y:0.06}},xyzToRgb:[[3.2406,-1.5372,-0.4986],[-0.9689,1.8758,0.0415],[0.0557,-0.2040,1.0570]],rgbToXyz:[[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]]},
 bt2020:{label:'BT.2020 / D65',white:{x:0.3127,y:0.3290},primaries:{R:{x:0.708,y:0.292},G:{x:0.170,y:0.797},B:{x:0.131,y:0.046}},xyzToRgb:[[1.7166511880,-0.3556707838,-0.2533662814],[-0.6666843518,1.6164812366,0.0157685458],[0.0176398574,-0.0427706133,0.9421031212]],rgbToXyz:[[0.6369580483,0.1446169036,0.1688809752],[0.2627002120,0.6779980715,0.0593017165],[0.0000000000,0.0280726930,1.0609850577]]},
 p3d65:{label:'P3 / D65',white:{x:0.3127,y:0.3290},primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},xyzToRgb:[[2.4934969119,-0.9313836179,-0.4027107845],[-0.8294889696,1.7626640603,0.0236246858],[0.0358458302,-0.0761723893,0.9568845240]],rgbToXyz:[[0.4865709486,0.2656676932,0.1982172852],[0.2289745641,0.6917385218,0.0792869141],[0.0000000000,0.0451133819,1.0439443689]]},
 p3dci:{label:'P3 / DCI',white:{x:0.3140,y:0.3510},primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},xyzToRgb:[[2.7253940305,-1.0180030062,-0.4401631952],[-0.7951680258,1.6897320548,0.0226471906],[0.0412418914,-0.0876390192,1.1009293786]],rgbToXyz:[[0.4451698156,0.2771344092,0.1722826698],[0.2094916779,0.7215952542,0.0689130679],[0.0000000000,0.0470605601,0.9073553944]]}
};
const M_XYZ_TO_RGB=GAMUT_PRESETS.bt709.xyzToRgb;
const M_RGB_TO_XYZ=GAMUT_PRESETS.bt709.rgbToXyz;`;

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
  'const METER_GREY_SLOTS_11=[0,10,20,30,40,50,60,70,80,90,100];',
  'const METER_GREY_SLOTS_21=[0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];',
  "let meterGreyPatchProfiles={format:'pgenerator-greyscale-profile-v1',apply_to_all_modes:false,profiles:{}};",
  'let meterGreyEditorPoints=21;',
  'function meterGreyAllowsHeadroomTargets(){return false;}',
  GAMUT_PRESETS_JS,
  extractFunction('meterGreyDefaultSlots'),
  extractFunction('meterGreySeriesSlots'),
  extractFunction('meterGreyClampPercent'),
  extractFunction('meterGreyNormalizeEntry'),
  extractFunction('meterGreyProfileSlots'),
  extractFunction('meterGreyProfileTemplate'),
  extractFunction('meterGreyProfileStepsKey'),
  extractFunction('meterGreyModeSignature'),
  extractFunction('meterGreyNormalizeProfilesState'),
  extractFunction('meterGreyActiveProfileKey'),
  extractFunction('meterGreyActiveProfile'),
  extractFunction('meterGreyProfileEntry'),
  extractFunction('meterGreySignalEntries'),
  extractFunction('meterGreyCustomEnabled'),
  extractFunction('meterGreyStimulusValues'),
  extractFunction('meterGreyStimulusCsv'),
  extractFunction('meterDvMapModeValue'),
  extractFunction('meterSignalColorimetryGamutKey'),
  extractFunction('meterAutoTargetGamutKey'),
  extractFunction('meterContainerGamutKey'),
  extractFunction('meterSelectedTargetGamutKey'),
  extractFunction('meterTargetWhitePointEnabled'),
  extractFunction('xyToUnitXyz'),
  extractFunction('meterTargetWhitePoint'),
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
  extractFunction('meterStoredLgTargetWhiteReferenceNits'),
  extractFunction('meterExplicitLgTargetWhiteReferenceNits'),
  extractFunction('meterColorSeriesUsesLgTargetWhite'),
  extractFunction('meterColorSeriesTargetWhiteForRun'),
  extractFunction('meterApplyColorSeriesTargetWhiteReference'),
  extractFunction('meterChartSignalMode'),
  extractFunction('meterGreyTargetSignal'),
  extractFunction('meterChartTargetLuminance'),
  extractFunction('meterGreyTargetLuminance'),
  extractFunction('meterReadingAnalysisIre'),
  extractFunction('meterGreyscaleTargetIreForStep'),
  extractFunction('meterResolveGreyRefMode'),
  extractFunction('meterGreyRefMode'),
  extractFunction('meterGrayWorldWeight'),
  extractFunction('meterBuildStepsJS'),
  extractFunction('meterNormalizeMeasuredReading'),
  extractFunction('meterReadingLuminanceNits'),
  extractFunction('meterReadingXYZ'),
  extractFunction('targetColorXYZAbs'),
  extractFunction('meterTargetXYZForReading'),
  extractFunction('meterTargetChromaticityForReading'),
  extractFunction('meterReadingIsGreyscale'),
  extractFunction('meterIreIsPeakHeadroom'),
  extractFunction('meterReadingIsPeakHeadroom'),
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
  meterFullAutoCalRunning: false,
  meterFullAutoCalPhase: '',
  meterFullAutoCalConfig: null,
  config: { colorimetry: '2', primaries: '0', signal_mode: 'sdr', max_luma: '1000' },
  lgStatusState: {},
  localStorage: {
    getItem(){ return null; }
  },
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
  meterCodeFromSignalPercentWithOptions(p){ return Math.round((Number(p)||0) * 255 / 100); },
  meterFormatPercentValue(value){ return String(Math.round(Number(value) * 10) / 10).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, ''); },
  meterPatchRangeMin(){ return 0; },
  meterPatchRangeSpan(){ return 255; },
  meterChromaPatchRangeMin(){ return 0; },
  meterChromaPatchRangeSpan(){ return 255; },
  meterGreyCodeRange(){ return { min: 0, span: 255 }; },
  meterSignalFractionFromCode(code){ return Math.max(0, Math.min(1, (Number(code)||0) / 255)); },
  meterPatchUsesVideoRange(){ return false; },
  meterIncludeLum(){ return false; },
  meterUseLgGreyscale21(){ return false; },
  meterUseLgAutoCal26(){ return false; },
  meterLgGreyscaleUsesExtendedSdr(){ return false; },
  meterLgGreyscaleUsesLegalSdrDdcCodes(){ return false; },
  meterXyzCorrectionEnabled(){ return false; },
  meterApplyXyzCorrectionMatrix(X, Y, Z){ return { X, Y, Z }; },
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

// Test 2b: post-cal LG color/sat series must carry the calibrated white
// target through step metadata, while untagged historical/pre-cal series keep
// their own measured series white instead of being reinterpreted later.
vm.runInContext(`
  meterFullAutoCalRunning = true;
  meterFullAutoCalPhase = 'postcal-report';
  meterFullAutoCalConfig = { targetY: 175 };
  meterActiveSeriesType = 'colors';
`, context);
const postColorSteps = vm.runInContext("meterBuildStepsJS('colors',30)", context);
assert(
  postColorSteps.length > 0 && postColorSteps.every(step => step.series_target_white_y === 175 && step.lg_target_white_y === 175),
  'post-cal ColorChecker steps should be tagged with calibrated LG white target Y'
);
vm.runInContext(`
  meterReadings = [{ name:'White', ire:100, r_code:255, g_code:255, b_code:255, luminance:100, Y:100 }];
`, context);
approxEqual(
  vm.runInContext('meterColorSeriesReferenceNits()', context),
  100,
  0.001,
  'untagged color series should keep measured series white reference'
);
vm.runInContext(`
  meterReadings = [{ name:'White', ire:100, r_code:255, g_code:255, b_code:255, luminance:100, Y:100, series_target_white_y:175 }];
`, context);
approxEqual(
  vm.runInContext('meterColorSeriesReferenceNits()', context),
  175,
  0.001,
  'tagged post-cal color series should use calibrated target white reference'
);

// Test 3: greyscale chart X positions must follow actual IRE, not array index.
const x5 = context.meterGreyChartX({ ire: 5 }, [{ ire: 0 }, { ire: 5 }, { ire: 10 }], 1);
approxEqual(x5, 0.05, 0.0001, 'greyscale chart X mapping mismatch');

// Test 3b: custom greyscale stimuli must feed both the emitted patch code and
// the greyscale target luminance path via reading.r_code.
vm.runInContext(`
  meterGreyPatchProfiles.apply_to_all_modes = true;
  meterGreyPatchProfiles.profiles.__all__ = meterGreyProfileTemplate();
  meterGreyPatchProfiles.profiles.__all__.enabled = true;
  meterGreyPatchProfiles.profiles.__all__.steps_11["10"] = { slot: 10, stimulus: 7.5 };
  meterGreyPatchProfiles.profiles.__all__.steps_11["20"] = { slot: 20, stimulus: 18 };
`, context);
const customCsv11 = vm.runInContext('meterGreyStimulusCsv(11)', context);
assert.strictEqual(customCsv11, '0,7.5,18,30,40,50,60,70,80,90,100', 'custom greyscale CSV mismatch');
const customSteps11 = vm.runInContext("meterBuildStepsJS('greyscale',11)", context);
const custom10 = customSteps11.find(step => step.ire === 10);
assert(custom10, 'missing custom 10% greyscale step');
approxEqual(custom10.stimulus, 7.5, 1e-9, 'custom 10% greyscale stimulus mismatch');
approxEqual(custom10.r, context.meterCodeFromSignalPercent(7.5), 1e-9, 'custom 10% greyscale code mismatch');
const customTargetIre = context.meterGreyscaleTargetIreForStep(custom10, null);
approxEqual(customTargetIre, 7.5, 1e-9, 'custom 10% greyscale target IRE should follow the explicit stimulus');
const customTargetY = context.meterGreyTargetLuminance(customTargetIre, 100, 0, custom10.r);
const nominalTargetY = context.meterGreyTargetLuminance(10, 100, 0, null);
assert(Math.abs(customTargetY - nominalTargetY) > 1e-6, 'custom greyscale target luminance should differ from nominal 10%');

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

// Test 10: color-series target Y stays anchored to the DV absolute mastering
// peak even when a measured White patch is available.
const dvColorStep = { name:'Orange', target_x:0.512087, target_y:0.410373, target_Yn:0.285811070494883 };
const dvTarget = context.meterTargetXYZForReading(dvColorStep);
approxEqual(dvTarget.Y, 1000 * dvColorStep.target_Yn, 1e-6, 'DV absolute color-series target Y should follow mastering peak');

console.log('All color-math regression checks passed.');

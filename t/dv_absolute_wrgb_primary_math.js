const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui-app.js', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `missing ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

const P3 = [
  [0.48663243, 0.26566758, 0.19817182],
  [0.22897456, 0.69173852, 0.07928691],
  [0.00000000, 0.04511331, 1.04394437]
];
const BT2020 = [
  [0.6369580483, 0.1446169036, 0.1688809752],
  [0.2627002120, 0.6779980715, 0.0593017165],
  [0.0000000000, 0.0280726930, 1.0609850577]
];

let mapMode = '1';
let technology = 'oled_generic';
let isDv = true;
let signalMode = 'dv';
const context = {
  window: {lgStatusState: {model_name: 'OLED65C2PUA'}},
  document: {getElementById: () => ({value: technology})},
  getDisplayTechnology: () => technology,
  meterActiveSeriesType: 'colors',
  meterChartIsPq: () => true,
  meterChartIsHdr: () => true,
  meterChartIsDv: () => isDv,
  meterDvMapModeValue: () => mapMode,
  meterChartHdrPeak: () => 1000,
  meterHdrDiffuseScale: () => 1,
  meterAnalysisGamut: () => ({rgbToXyz: P3}),
  meterContainerGamut: () => ({rgbToXyz: BT2020}),
  meterGamutColorEndpointRgb: name => ({
    red: [1, 0, 0], green: [0, 1, 0], blue: [0, 0, 1],
    cyan: [0, 1, 1], magenta: [1, 0, 1], yellow: [1, 1, 0]
  })[String(name).toLowerCase()] || [1, 1, 1],
  meterActiveChartSignalMode: () => signalMode,
  meterColorTargetCodeRange: () => ({min: 256, span: 3504}),
  meterColorSeriesReferenceNits: () => 715.360759,
  meterCanonicalSeriesStep: () => null,
  meterDecodeColorTargetChannel: code => context.meterDvStimulusLinearChannel(code),
  meterReadingLuminanceNits: rd => Number(rd && (rd.luminance != null ? rd.luminance : rd.Y)) || 0,
  meterReadingIsGreyscale: rd => {
    const r = rd && (rd.r_code != null ? rd.r_code : rd.r);
    const g = rd && (rd.g_code != null ? rd.g_code : rd.g);
    const b = rd && (rd.b_code != null ? rd.b_code : rd.b);
    return r != null && g != null && b != null && Number(r) === Number(g) && Number(g) === Number(b);
  },
  linRgbToXyz: (r, g, b, M) => ({
    X: M[0][0] * r + M[0][1] * g + M[0][2] * b,
    Y: M[1][0] * r + M[1][1] * g + M[1][2] * b,
    Z: M[2][0] * r + M[2][1] * g + M[2][2] * b
  })
};

const endpointCodes = {
  Red: [2008, 1153, 256], Green: [1499, 2008, 885], Blue: [1096, 810, 2008],
  Cyan: [1545, 1991, 2008], Magenta: [1937, 1147, 2008], Yellow: [1995, 2008, 861]
};
context.meterReadings = [
  {series_color: 'Red', sat_pct: 100, r_code: 2008, g_code: 1153, b_code: 256, luminance: 18.361413, signal_mode: 'dv'},
  {series_color: 'Green', sat_pct: 100, r_code: 1499, g_code: 2008, b_code: 885, luminance: 58.190180, signal_mode: 'dv'},
  {series_color: 'Blue', sat_pct: 100, r_code: 1096, g_code: 810, b_code: 2008, luminance: 7.174204, signal_mode: 'dv'}
];

vm.createContext(context);
vm.runInContext([
  extractFunction('meterWrgbTargetCompensationSelected'),
  extractFunction('meterWrgbPrimaryCeilings'),
  extractFunction('meterChartPqDecodeNormalized'),
  extractFunction('meterDvStimulusLinearChannel'),
  extractFunction('meterWrgbGamutSurfaceAnchors'),
  extractFunction('meterWrgbGamutSurfaceTargetY'),
  extractFunction('meterWrgbStimulusTargetY')
].join('\n'), context);

function close(actual, expected, tolerance, message) {
  assert(Math.abs(actual - expected) <= tolerance,
    `${message}: got ${actual}, expected ${expected} +/- ${tolerance}`);
}

assert.strictEqual(context.meterWrgbTargetCompensationSelected(), true,
  'the selected WOLED technology is detected');
const ceilings = context.meterWrgbPrimaryCeilings();
assert(ceilings[0] > 0 && ceilings[1] > 0 && ceilings[2] > 0,
  'Absolute DV exposes measured WRGB primary ceilings');

for (const [name, measured] of [
  ['Red', 18.361413], ['Green', 58.190180], ['Blue', 7.174204]
]) {
  const codes = endpointCodes[name];
  const target = context.meterWrgbStimulusTargetY({
    series_color: name, sat_pct: 100,
    r_code: codes[0], g_code: codes[1], b_code: codes[2], signal_mode: 'dv'
  });
  close(target, measured, 1e-6, `${name} target follows its measured filtered-primary ceiling`);
}

const cyan = context.meterWrgbStimulusTargetY({
  series_color: 'Cyan', sat_pct: 100,
  r_code: endpointCodes.Cyan[0], g_code: endpointCodes.Cyan[1], b_code: endpointCodes.Cyan[2], signal_mode: 'dv'
});
close(cyan, 58.190180 + 7.174204, 1e-6,
  'Absolute DV secondary target uses the additive measured primary ceilings');

context.meterActiveSeriesType = 'saturations';
context.meterReadings = [
  {series_color: 'Red', sat_pct: 100, r_code: 2008, g_code: 1153, b_code: 256, luminance: 18.431602, signal_mode: 'dv'},
  {series_color: 'Green', sat_pct: 100, r_code: 1499, g_code: 2008, b_code: 885, luminance: 58.307092, signal_mode: 'dv'},
  {series_color: 'Blue', sat_pct: 100, r_code: 1096, g_code: 810, b_code: 2008, luminance: 7.155143, signal_mode: 'dv'}
];
const sweepRed = context.meterWrgbStimulusTargetY({
  series_color: 'Red', sat_pct: 100,
  r_code: endpointCodes.Red[0], g_code: endpointCodes.Red[1], b_code: endpointCodes.Red[2], signal_mode: 'dv'
});
close(sweepRed, 18.431602, 1e-6,
  'Absolute DV saturation endpoint uses its measured WRGB primary ceiling');

const sweepRed75 = context.meterWrgbStimulusTargetY({
  series_color: 'Red', sat_pct: 75,
  r_code: 2008, g_code: 1396, b_code: 1264, signal_mode: 'dv'
});
const sweepRed75Raw = (() => {
  const channels = [2008, 1396, 1264].map(context.meterDvStimulusLinearChannel);
  return context.linRgbToXyz(channels[0], channels[1], channels[2], BT2020).Y;
})();
close(sweepRed75, sweepRed75Raw, 1e-9,
  'sub-100% saturation target remains the authored PQ stimulus');

const neutral = {r_code: 1882, g_code: 1882, b_code: 1882, signal_mode: 'dv'};
context.meterActiveSeriesType = 'colors';
context.meterReadings = [];
const neutralBefore = context.meterWrgbStimulusTargetY(neutral);
context.meterReadings = [{series_color: 'Red', sat_pct: 100, r_code: 2008, g_code: 256, b_code: 256, luminance: 1, signal_mode: 'dv'}];
close(context.meterWrgbStimulusTargetY(neutral), neutralBefore, 1e-9,
  'neutral target is independent of WRGB primary ceilings');

context.meterReadings = [
  {name: 'White', r_code: 3760, g_code: 3760, b_code: 3760,
   X: 674.593853, Y: 709.926711, Z: 772.328725, luminance: 709.926711, signal_mode: 'dv'},
  {name: '100% Red', series_color: 'Red', sat_pct: 100,
   r_code: 2008, g_code: 1153, b_code: 256,
   X: 38.896120, Y: 18.314059, Z: 0.110782, luminance: 18.314059, signal_mode: 'dv'},
  {name: '100% Green', series_color: 'Green', sat_pct: 100,
   r_code: 1499, g_code: 2008, b_code: 885,
   X: 22.909178, Y: 57.729028, Z: 4.452011, luminance: 57.729028, signal_mode: 'dv'},
  {name: '100% Blue', series_color: 'Blue', sat_pct: 100,
   r_code: 1096, g_code: 810, b_code: 2008,
   X: 17.015666, Y: 7.064088, Z: 89.257092, luminance: 7.064088, signal_mode: 'dv'},
  {name: '100% Cyan', series_color: 'Cyan', sat_pct: 100,
   r_code: 1545, g_code: 1991, b_code: 2008,
   X: 39.568580, Y: 66.525759, Z: 86.258195, luminance: 66.525759, signal_mode: 'dv'},
  {name: '100% Magenta', series_color: 'Magenta', sat_pct: 100,
   r_code: 1937, g_code: 1147, b_code: 2008,
   X: 47.907715, Y: 21.372635, Z: 82.970096, luminance: 21.372635, signal_mode: 'dv'},
  {name: '100% Yellow', series_color: 'Yellow', sat_pct: 100,
   r_code: 1995, g_code: 2008, b_code: 861,
   X: 53.082727, Y: 65.441343, Z: 3.907269, luminance: 65.441343, signal_mode: 'dv'}
];
const orange = {
  name: 'Orange', r_code: 2041, g_code: 1770, b_code: 1282,
  target_x: 0.512087, target_y: 0.410373, signal_mode: 'dv'
};
const orangeRawChannels = [2041, 1770, 1282].map(context.meterDvStimulusLinearChannel);
const orangeRaw = context.linRgbToXyz(
  orangeRawChannels[0], orangeRawChannels[1], orangeRawChannels[2], BT2020
).Y;
const orangeTarget = context.meterWrgbStimulusTargetY(orange);
close(orangeTarget, 40.482543, 1e-5,
  'seven-point gamut surface interpolates the Orange target');
assert(orangeTarget < orangeRaw,
  'surface target exposes the display-referenced result instead of raw PQ luminance');
for (const [patch, low, high] of [
  [{name: 'Orange Yellow', r_code: 2118, g_code: 1958, b_code: 1391,
    target_x: 0.473379, target_y: 0.443246, signal_mode: 'dv'}, 62, 64],
  [{name: 'Yellow', r_code: 2176, g_code: 2101, b_code: 1425,
    target_x: 0.447920, target_y: 0.475618, signal_mode: 'dv'}, 87, 89]
]) {
  const target = context.meterWrgbStimulusTargetY(patch);
  assert(target > low && target < high,
    `${patch.name} receives an interpolated seven-point surface target: ${target}`);
}
close(orange._wrgb_authored_target_y, orangeRaw, 1e-9,
  'raw PQ target remains attached for diagnostics');
close(orange._wrgb_surface_target_y, orangeTarget, 1e-9,
  'surface target remains attached for diagnostics');

isDv = false;
signalMode = 'hdr10';
context.meterReadings.forEach(reading => { reading.signal_mode = 'hdr10'; });
orange.signal_mode = 'hdr10';
close(context.meterWrgbStimulusTargetY(orange), orangeTarget, 1e-9,
  'HDR10 uses the same seven-point WRGB gamut surface');
isDv = true;
signalMode = 'dv';
context.meterReadings.forEach(reading => { reading.signal_mode = 'dv'; });
orange.signal_mode = 'dv';

mapMode = '2';
assert.deepStrictEqual(Object.keys(context.meterWrgbPrimaryCeilings()), [],
  'Relative DV remains on its authored WRGB response model');

mapMode = '1';
technology = 'qdoled';
assert.deepStrictEqual(Object.keys(context.meterWrgbPrimaryCeilings()), [],
  'QD-OLED bypasses WRGB primary ceilings');

console.log('Absolute DV WRGB primary luminance math regression OK');

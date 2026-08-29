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
const context = {
  window: {lgStatusState: {model_name: 'OLED65C2PUA'}},
  document: {getElementById: () => ({value: technology})},
  getDisplayTechnology: () => technology,
  meterActiveSeriesType: 'colors',
  meterChartIsPq: () => true,
  meterChartIsHdr: () => true,
  meterChartIsDv: () => true,
  meterDvMapModeValue: () => mapMode,
  meterChartHdrPeak: () => 1000,
  meterHdrDiffuseScale: () => 1,
  meterAnalysisGamut: () => ({rgbToXyz: P3}),
  meterContainerGamut: () => ({rgbToXyz: BT2020}),
  meterGamutColorEndpointRgb: name => ({
    red: [1, 0, 0], green: [0, 1, 0], blue: [0, 0, 1],
    cyan: [0, 1, 1], magenta: [1, 0, 1], yellow: [1, 1, 0]
  })[String(name).toLowerCase()] || [1, 1, 1],
  meterActiveChartSignalMode: () => 'dv',
  meterColorTargetCodeRange: () => ({min: 256, span: 3504}),
  meterColorSeriesReferenceNits: () => 715.360759,
  meterCanonicalSeriesStep: () => null,
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

const neutral = {r_code: 1882, g_code: 1882, b_code: 1882, signal_mode: 'dv'};
context.meterReadings = [];
const neutralBefore = context.meterWrgbStimulusTargetY(neutral);
context.meterReadings = [{series_color: 'Red', sat_pct: 100, r_code: 2008, g_code: 256, b_code: 256, luminance: 1, signal_mode: 'dv'}];
close(context.meterWrgbStimulusTargetY(neutral), neutralBefore, 1e-9,
  'neutral target is independent of WRGB primary ceilings');

mapMode = '2';
assert.deepStrictEqual(Object.keys(context.meterWrgbPrimaryCeilings()), [],
  'Relative DV remains on its authored WRGB response model');

mapMode = '1';
technology = 'qdoled';
assert.deepStrictEqual(Object.keys(context.meterWrgbPrimaryCeilings()), [],
  'QD-OLED bypasses WRGB primary ceilings');

console.log('Absolute DV WRGB primary luminance math regression OK');

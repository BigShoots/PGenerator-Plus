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

let mode = 'hdr10';
let mapMode = '1';
const targetMatrix = [
  [0.48663243, 0.26566758, 0.19817182],
  [0.22897456, 0.69173852, 0.07928691],
  [0, 0.04511331, 1.04394437]
];
const containerMatrix = [
  [0.63695805, 0.14461690, 0.16888098],
  [0.2, 0.7, 0.1],
  [0, 0.02807269, 1.06098506]
];
const context = {
  meterChartIsPq: () => true,
  meterChartIsHdr: () => true,
  meterChartIsDv: () => mode === 'dv',
  meterDvMapModeValue: () => mapMode,
  meterSaturationSolveGamut: () => ({xyzToRgb: []}),
  meterSaturationAxisGamut: () => ({}),
  meterGamutColorEndpointXY: () => ({x: 0.68, y: 0.32}),
  xyzToLinRgb: () => [1, 0.2, 0],
  meterGamutStimulusLinearLevel: () => 0.5,
  meterEncodeSaturationLinear: value => Math.round(value * 10000),
  meterBuildFullGamutTargetLinearRgb: () => [1, 0, 0],
  meterTargetSolveGamut: () => ({rgbToXyz: targetMatrix}),
  meterTargetWhitePoint: () => ({x: 0.3127, y: 0.329}),
  meterColorSeriesReferenceNits: () => 700,
  linRgbToXyz: (r, g, b, matrix) => ({
    X: matrix[0][0] * r + matrix[0][1] * g + matrix[0][2] * b,
    Y: matrix[1][0] * r + matrix[1][1] * g + matrix[1][2] * b,
    Z: matrix[2][0] * r + matrix[2][1] * g + matrix[2][2] * b
  }),
  meterContainerGamut: () => ({rgbToXyz: containerMatrix}),
  meterAnalysisGamut: () => ({rgbToXyz: targetMatrix}),
  meterDecodeColorTargetChannel: code => Number(code),
  meterDvStimulusLinearChannel: code => Number(code),
  meterCanonicalSeriesStep: () => null,
  meterWrgbTargetCompensationSelected: () => true,
  meterReadingIsGreyscale: () => false,
  meterActiveSeriesType: 'colors',
  meterReadings: []
};

vm.createContext(context);
vm.runInContext([
  extractFunction('meterBuildColorCheckerEndpointStepRgb'),
  extractFunction('meterBuildColorCheckerEndpointTargetStepMeta'),
  extractFunction('meterColorCheckerFullSatTargetXYZ'),
  extractFunction('meterWrgbStimulusTargetY')
].join('\n'), context);

for (const signalMode of ['hdr10', 'dv']) {
  mode = signalMode;
  mapMode = '1';
  assert.deepStrictEqual(
    Array.from(context.meterBuildColorCheckerEndpointStepRgb('Red')),
    [100, 20, 0],
    `${signalMode} ColorChecker endpoint uses a 100/10000 PQ-linear level`
  );

  const meta = context.meterBuildColorCheckerEndpointTargetStepMeta('Red');
  assert(Math.abs(meta.target_Yn - (0.22897456 * 100 / 700)) < 1e-12,
    `${signalMode} endpoint target is 100-nit absolute, normalized to series white`);

  const reading = {series_color: 'Red', sat_pct: 100, r_code: 100, g_code: 20, b_code: 0};
  const before = context.meterWrgbStimulusTargetY(reading);
  context.meterReadings = [
    {series_color: 'Red', sat_pct: 100, Y: 1},
    {series_color: 'Green', sat_pct: 100, Y: 500},
    {series_color: 'Blue', sat_pct: 100, Y: 2}
  ];
  const after = context.meterWrgbStimulusTargetY(reading);
  assert.strictEqual(before, 34, `${signalMode} endpoint reports its native PQ target`);
  assert.strictEqual(after, before,
    `${signalMode} endpoint target is independent of measured primary results`);
  context.meterReadings = [];

  const fallback = context.meterColorCheckerFullSatTargetXYZ('Red');
  assert(Math.abs(fallback.Y - 22.897456) < 1e-9,
    `${signalMode} endpoint fallback target is the target primary at 100 nits`);
}

mode = 'dv';
mapMode = '2';
assert.deepStrictEqual(
  Array.from(context.meterBuildColorCheckerEndpointStepRgb('Red')),
  [5000, 1000, 0],
  'Relative DV retains its established gamma-tunnel endpoint level'
);

assert(!source.includes('function meterWrgbPrimaryCeilings('),
  'PQ ColorChecker endpoint grading no longer derives targets from measured primaries');

console.log('HDR10 and Absolute-DV 100-nit ColorChecker endpoint regression OK');

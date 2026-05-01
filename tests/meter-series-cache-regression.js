const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

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
  'var meterSeriesCache = {};',
  "var meterActiveSeriesSignalMode = 'sdr';",
  'function meterLoadSeriesCache(){}',
  extractFunction('meterParseSeriesKey'),
  extractFunction('meterSeriesSnapshotSignalMode'),
  extractFunction('meterGreyscaleReadingMatchesStep'),
  extractFunction('meterNormalizeMeasuredReading'),
  extractFunction('meterReadingHasLuminance'),
  extractFunction('meterFindSeriesWhiteReading'),
  extractFunction('meterStampReadingStepMeta'),
  extractFunction('meterResolveSeriesSnapshotFromCache')
].join('\n\n');

const context = {
  console,
  JSON,
  Object,
  Array,
  Number,
  String,
  meterChartSignalMode() {
    return 'sdr';
  },
  meterBuildStepsJS() {
    throw new Error('Unexpected meterBuildStepsJS call in cache regression test');
  },
  meterXyzCorrectionEnabled() {
    return false;
  },
  meterApplyXyzCorrectionMatrix(X, Y, Z) {
    return { X, Y, Z };
  }
};
context.window = context;
vm.createContext(context);
vm.runInContext(code, context);

context.meterSeriesCache = {
  'greyscale-11': {
    type: 'greyscale',
    points: 11,
    signal_mode: 'sdr',
    updated_at: 10,
    readings: [
      { ire: 0, name: '0%', luminance: 0.05 },
      { ire: 10, name: '10%', luminance: 10.1 },
      { ire: 20, name: '20%', luminance: 20.1 },
      { ire: 100, name: '100%', luminance: 100, r_code: 255, g_code: 255, b_code: 255 }
    ],
    white_reading: { ire: 100, name: '100%', luminance: 100, r_code: 255, g_code: 255, b_code: 255 }
  },
  'greyscale-21': {
    type: 'greyscale',
    points: 21,
    signal_mode: 'sdr',
    updated_at: 20,
    readings: [
      { ire: 5, name: '5%', luminance: 5.1 },
      { ire: 10, name: '10%', luminance: 9.9 }
    ]
  },
  'colors-30': {
    type: 'colors',
    points: 30,
    signal_mode: 'sdr',
    updated_at: 30,
    readings: [{ name: 'Red', luminance: 11 }],
    white_reading: null
  }
};

const steps21 = [
  { ire: 0, name: '0%', r: 0, g: 0, b: 0 },
  { ire: 5, name: '5%', r: 13, g: 13, b: 13 },
  { ire: 10, name: '10%', r: 26, g: 26, b: 26 },
  { ire: 15, name: '15%', r: 38, g: 38, b: 38 },
  { ire: 20, name: '20%', r: 51, g: 51, b: 51 },
  { ire: 100, name: '100%', r: 255, g: 255, b: 255 }
];

const snap21 = context.meterResolveSeriesSnapshotFromCache('greyscale-21', {
  type: 'greyscale',
  points: 21,
  signalMode: 'sdr',
  steps: steps21
});

assert(snap21, 'Expected greyscale cache snapshot');
const lumByIre = new Map(snap21.readings.map(reading => [reading.ire, reading.luminance]));
assert.strictEqual(lumByIre.get(0), 0.05, '11pt 0% should backfill 21pt');
assert.strictEqual(lumByIre.get(5), 5.1, 'Exact 21pt 5% reading should be preserved');
assert.strictEqual(lumByIre.get(10), 9.9, 'Exact 21pt reading should win over 11pt fallback');
assert.strictEqual(lumByIre.get(20), 20.1, '11pt 20% should backfill 21pt');
assert.strictEqual(lumByIre.has(15), false, 'Missing greyscale points should stay missing');
assert(snap21.white_reading, 'Expected merged greyscale white reference');
assert.strictEqual(snap21.white_reading.luminance, 100, 'Merged greyscale white reference mismatch');

const colorSnap = context.meterResolveSeriesSnapshotFromCache('colors-30', {
  type: 'colors',
  points: 30,
  signalMode: 'sdr',
  steps: [{ name: 'Red' }]
});

assert(colorSnap, 'Expected exact non-greyscale cache snapshot');
assert.strictEqual(colorSnap.readings.length, 1, 'Non-greyscale cache should restore only its own readings');
assert.strictEqual(colorSnap.readings[0].name, 'Red', 'Unexpected non-greyscale reading restore');

console.log('Meter series cache regression checks passed.');
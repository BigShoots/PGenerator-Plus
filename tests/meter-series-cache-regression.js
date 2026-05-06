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
  "var meterSeriesCacheBootId = '';",
  "var meterActiveSeriesSignalMode = 'sdr';",
  'var meterSeriesSteps = [];',
  'function meterLoadSeriesCache(){}',
  extractFunction('meterSeriesCacheKey'),
  extractFunction('meterSetSeriesCacheBootId'),
  extractFunction('meterParseSeriesKey'),
  extractFunction('meterSeriesSnapshotSignalMode'),
  extractFunction('meterStepNameKey'),
  extractFunction('meterGreyscaleReadingMatchesStep'),
  extractFunction('meterReadingCodesMatchStep'),
  extractFunction('meterRecoveredStepsMatchSeries'),
  extractFunction('meterRecoveredStepsDifferInCodes'),
  extractFunction('meterCanonicalRecoveredSteps'),
  extractFunction('meterReadingIsBlackStep'),
  extractFunction('meterReadingsWouldRecoverAsBlackOnly'),
  extractFunction('meterFilterReadingsForSteps'),
  extractFunction('meterFilterReadingsForCurrentSteps'),
  extractFunction('meterReadingMatchesStepList'),
  extractFunction('meterNormalizeMeasuredReading'),
  extractFunction('meterReadingIsGreyscale'),
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
  localStorage: (() => {
    const store = {};
    return {
      getItem(key) {
        return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null;
      },
      setItem(key, value) {
        store[key] = String(value);
      },
      removeItem(key) {
        delete store[key];
      },
      clear() {
        Object.keys(store).forEach(key => delete store[key]);
      },
      _store: store
    };
  })(),
  meterChartSignalMode() {
    return 'sdr';
  },
  meterUseLgGreyscale21() {
    return false;
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

context.localStorage.clear();
context.localStorage.setItem('pgen.meter.seriesCache.bootId', 'oldboot');
context.localStorage.setItem('pgen.meter.oldboot.lastSeriesKey', 'greyscale-21');
context.localStorage.setItem('pgen.meter.oldboot.seriesCache', JSON.stringify({
  'greyscale-21': {
    type: 'greyscale',
    points: 21,
    signal_mode: 'sdr',
    updated_at: 200,
    steps: steps21,
    readings: [{ ire: 30, name: '30%', luminance: 30.5 }]
  }
}));
context.meterSeriesCache = {};
context.meterSeriesCacheBootId = '';
context.meterSetSeriesCacheBootId('newboot');
const migratedCache = JSON.parse(context.localStorage.getItem('pgen.meter.newboot.seriesCache'));
assert(migratedCache['greyscale-21'], 'Expected old boot cache to migrate to new boot scope');
assert.strictEqual(migratedCache['greyscale-21'].readings[0].luminance, 30.5, 'Migrated manual reading mismatch');
assert(context.localStorage.getItem('pgen.meter.oldboot.seriesCache'), 'Old scoped cache should not be deleted');
assert.strictEqual(context.localStorage.getItem('pgen.meter.newboot.lastSeriesKey'), 'greyscale-21', 'Last series key should migrate');

context.meterSeriesCache = {};
context.meterSeriesCacheBootId = '';
context.meterSetSeriesCacheBootId('');
assert.strictEqual(context.meterSeriesCacheBootId, 'newboot', 'Missing boot id should reuse stored marker instead of global');

context.meterUseLgGreyscale21 = () => true;
context.meterBuildStepsJS = () => [
  { ire: 40, name: '40%', r: 104, g: 104, b: 104 },
  { ire: 45, name: '45%', r: 115, g: 115, b: 115 }
];
const staleLgSteps = [
  { ire: 40, name: '40%', r: 112, g: 112, b: 112 },
  { ire: 45, name: '45%', r: 124, g: 124, b: 124 }
];
const canonicalLgSteps = context.meterCanonicalRecoveredSteps('greyscale', 21, staleLgSteps, 'complete');
assert.strictEqual(canonicalLgSteps[0].r, 104, 'LG recovered greyscale steps should rebuild stale extended patch codes');
assert.strictEqual(
  context.meterGreyscaleReadingMatchesStep({ ire: 40, name: '40%', r_code: 112, g_code: 112, b_code: 112 }, canonicalLgSteps[0]),
  false,
  'Readings measured against stale extended LG patch codes must not be restored onto legal-code steps'
);

const legalLgStepsWithBlack = [
  { ire: 0, name: '0%', r: 16, g: 16, b: 16 },
  ...canonicalLgSteps
];
const staleLgReadingsWithBlack = [
  { ire: 0, name: '0%', luminance: 0.01, r_code: 16, g_code: 16, b_code: 16 },
  { ire: 40, name: '40%', luminance: 40.2, r_code: 112, g_code: 112, b_code: 112 },
  { ire: 45, name: '45%', luminance: 45.3, r_code: 124, g_code: 124, b_code: 124 }
];
assert.strictEqual(
  context.meterReadingsWouldRecoverAsBlackOnly(staleLgReadingsWithBlack, 'greyscale', legalLgStepsWithBlack),
  true,
  'Stale extended LG readings should be recognized before restoring a black-only chart'
);
context.meterSeriesSteps = legalLgStepsWithBlack;
assert.strictEqual(
  context.meterFilterReadingsForCurrentSteps(staleLgReadingsWithBlack, 'greyscale').length,
  0,
  'Stale extended LG readings should not recover as a black-only chart'
);
context.meterSeriesCache = {
  'greyscale-21': {
    type: 'greyscale',
    points: 21,
    signal_mode: 'sdr',
    updated_at: 300,
    steps: [
      { ire: 0, name: '0%', r: 16, g: 16, b: 16 },
      ...staleLgSteps
    ],
    readings: staleLgReadingsWithBlack,
    white_reading: { ire: 100, name: '100%', luminance: 100, r_code: 255, g_code: 255, b_code: 255 }
  }
};
const staleOnlyBlackSnap = context.meterResolveSeriesSnapshotFromCache('greyscale-21', {
  type: 'greyscale',
  points: 21,
  signalMode: 'sdr',
  steps: legalLgStepsWithBlack
});
assert.strictEqual(staleOnlyBlackSnap, null, 'Cache recovery should drop stale series data instead of plotting only black');

console.log('Meter series cache regression checks passed.');

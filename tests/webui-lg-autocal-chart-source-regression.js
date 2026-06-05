const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
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

const applyStatus = source.slice(
  source.indexOf('function meterAutoCalApplyStatus(status)'),
  source.indexOf('function meterFullAutoCalCloneValue')
);
assert(
  applyStatus.includes('const statusChartReadings=meterAutoCalStatusChartReadings(status);') &&
    applyStatus.includes('if(statusChartReadings.length){') &&
    applyStatus.includes('meterReadings=statusChartReadings;') &&
    applyStatus.includes('const currentValid=currentKey?meterReadings.find') &&
    applyStatus.includes('if(!statusChartReadings.length&&meterSeriesSteps&&status.autocal)'),
  'AutoCal status should drive chart readings from merged status/best-known data, not only raw status.readings'
);

const statusSync = source.slice(
  source.indexOf('// Sync shared series state across browsers.'),
  source.indexOf('function meterRecoverSeries(s)')
);
assert(
  statusSync.includes('if(meterAutoCalStatusActive()) return;') &&
    statusSync.indexOf('if(meterAutoCalStatusActive()) return;') < statusSync.indexOf("fetchJSON('/api/meter/series/status'"),
  'shared series recovery should not fetch/recover stale completed series while AutoCal status is active or recent'
);

assert(
  extractFunction('meterExplicitLgTargetWhiteReferenceNits').includes('meterReadingDisablesAutoCalTargetReference(rd)') &&
    extractFunction('meterFindLgAutoCalLegalWhiteReference').includes('meterReadingDisablesAutoCalTargetReference(rd)') &&
    extractFunction('meterLgAutoCalChartReferenceWhite').includes('meterReadingDisablesAutoCalTargetReference(item)'),
  'legal-white validation reads disabled as AutoCal target references should not feed chart/reference target-Y selection'
);

const context = {
  console,
  JSON,
  Object,
  Array,
  Number,
  String,
  Date,
};

vm.createContext(context);
vm.runInContext([
  `
    var meterSeriesSteps = [
      { ire: 100, stimulus: 100, name: '100% legal white', autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true, ddc_target_ire: 99 },
      { ire: 95, stimulus: 94.977, name: '95%' },
      { ire: 99, stimulus: 99.087, name: '99%', series_mode: 'lg-autocal-26' }
    ];
    var meterActiveSeriesType = 'greyscale';
    var meterActiveSeriesPoints = 26;
    var meterActiveSeriesSignalMode = 'sdr';
    var meterReadings = [
      { ire: 99, name: '99%', luminance: 149, request_id: 'magic-wand-visible-99' },
      { ire: 100, name: '100% legal white', luminance: 158, Y: 158, autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true, request_id: 'magic-wand-verify-white' }
    ];
    var meterFullAutoCalPhase = '';
    var meterAutoCalPhase = 'complete';
    var meterAutoCalMagicWandActive = false;
    var meterAutoCalRunning = true;
    var meterAutoCalPolling = false;
    var meterActionPending = false;
    var meterFullAutoCalRunning = false;
    function meterChartSignalMode(){ return 'sdr'; }
    function meterReadingPlotIre(item){ return item && item.ire; }
    function meterReadingIsGreyscale(){ return true; }
    function meterUseLgAutoCal26(){ return true; }
    function meterFindSeriesWhiteReading(){ return null; }
    function meterReadingLuminanceNits(item){ return Number(item && (item.luminance != null ? item.luminance : item.Y)); }
    function meterFullAutoCalCloneValue(value){ return JSON.parse(JSON.stringify(value)); }
    function meterFormatPercentValue(value){ return String(Number(value)); }
    function meterAttachSeriesMeta(readings){ return readings || []; }
    function meterFilterReadingsForCurrentSteps(readings){ return readings || []; }
    function meterStampReadingStepMeta(reading, step){
      if (step.ire != null) reading.ire = step.ire;
      if (step.name != null) reading.name = step.name;
      if (step.stimulus != null) reading.stimulus = step.stimulus;
      if (step.series_mode != null) reading.series_mode = step.series_mode;
      if (step.autocal_white_reference != null) reading.autocal_white_reference = step.autocal_white_reference;
      if (step.autocal_reference_only != null) reading.autocal_reference_only = step.autocal_reference_only;
      if (step.autocal_legal_white_anchor != null) reading.autocal_legal_white_anchor = step.autocal_legal_white_anchor;
      return reading;
    }
    function meterNormalizeMeasuredReading(reading){
      if (reading && reading.luminance == null && reading.Y != null) reading.luminance = reading.Y;
      return reading;
    }
    function meterReadingHasLuminance(reading){
      meterNormalizeMeasuredReading(reading);
      return !!(reading && reading.luminance != null && reading.luminance >= 0);
    }
    function meterStepNameKey(value){ return value && value.ire != null ? String(Number(value.ire)) : ''; }
    function meterAutoCalGreyscaleTargetWhiteReferenceNits(){ return 200; }
    function meterSyntheticGreyWhiteReading(luminance){ return { luminance, Y: luminance, synthetic_target: true }; }
    function meterLgHeadroomDerivedWhiteReferenceNits(){ return null; }
    function meterLgTargetWhiteReferenceNits(){ return null; }
    function meterFindMeasuredWhiteReading(){ return null; }
    function meterReadingXYZ(reading){ return reading ? { X: reading.X || 0, Y: reading.Y || reading.luminance || 0, Z: reading.Z || 0 } : null; }
    function meterColorReferenceNits(){ return 100; }
    function targetEotf(){ return 1; }
  `,
  extractFunction('meterGreyscaleReferenceReadings'),
  extractFunction('meterReadingIsAutoCalReferenceOnly'),
  extractFunction('meterReadingDisablesAutoCalTargetReference'),
  extractFunction('meterExplicitLgTargetWhiteReferenceNits'),
  extractFunction('meterFindLgAutoCalLegalWhiteReference'),
  extractFunction('meterEffectiveGreyscaleWhiteReference'),
  extractFunction('meterAutoCalGreyscaleTargetWhiteReferenceActive'),
  extractFunction('meterLgAutoCalChartReferenceWhite'),
  extractFunction('meterReadingIsAutoCalChartHidden'),
  extractFunction('meterFilterLgAutoCalChartItems'),
  extractFunction('meterAutoCalStepForIre'),
  extractFunction('meterAutoCalCurrentKeyFromStatus'),
  extractFunction('meterAutoCalBestKnownReadings'),
  extractFunction('meterAutoCalStatusChartReadings'),
  `
    const status = {
      autocal: true,
      status: 'complete',
      readings: [
        { ire: 99, name: '99%', luminance: 148, x: 0.30, y: 0.31, request_id: 'stale-series-99' },
        { ire: 95, name: '95%', luminance: 140, x: 0.312, y: 0.329, request_id: 'status-95' }
      ],
      lg_autocal_26_best_known: {
        '99': {
          ire: 99,
          delta_e: 0.2478727,
          reached_target: true,
          target_luminance: 150.5,
          legal_white_validation_status: 'diagnostic_only_failed',
          paired_legal_white_delta_e: 19.26,
          reading: { ire: 99, name: '99%', luminance: 150.2, x: 0.3127, y: 0.329, request_id: 'current-autocal-99' }
        }
      }
    };
    globalThis.autocalPaired99CurrentKey = meterAutoCalCurrentKeyFromStatus({
      autocal: true,
      status: 'running',
      current_name: 'Auto Cal 99%',
      message: 'Balancing 99% and 100% after adjustment: reading 100% legal white',
      current_ire: 100,
      current_step_ire: 100,
      patch_ire: 100,
      current_ddc_target_ire: 99,
      current_ddc_array_ire: 99,
      paired_current_name: '100% legal white'
    });
    globalThis.autocalNormal95CurrentKey = meterAutoCalCurrentKeyFromStatus({
      autocal: true,
      status: 'running',
      current_name: 'Auto Cal 95%',
      message: 'Reading 95% after adjustment',
      current_ire: 95,
      current_step_ire: 95,
      current_ddc_target_ire: 95,
      current_ddc_array_ire: 95
    });
    const chartReadings = meterAutoCalStatusChartReadings(status);
    globalThis.chartReadings = chartReadings;
    globalThis.reading99 = chartReadings.find(reading => Number(reading.ire) === 99);
    globalThis.bestKnown99ForChart = meterAutoCalBestKnownReadings(status).find(reading => Number(reading.ire) === 99);
    globalThis.reading95 = chartReadings.find(reading => Number(reading.ire) === 95);
    globalThis.filteredAutoCalChartItems = meterFilterLgAutoCalChartItems([
      { ire: 99, name: '99% pre-shape', luminance: 149, autocal_diagnostic: true, autocal_chart_hidden: true, autocal_read_role: 'top_cluster_preshape' },
      { ire: 99, name: '99%', luminance: 150, request_id: 'normal-99' },
      { ire: 105, name: '105% pair counterpart', luminance: 170, autocal_read_role: 'legal_white_pair_counterpart' },
      { ire: 105, name: '105%', luminance: 171, request_id: 'normal-105' },
      { ire: 100, name: '100% legal white', luminance: 160, autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true },
      { ire: 95, name: '95% validation', luminance: 145, autocal_read_role: 'legal_white_validation' },
      { ire: 80, name: '80%', luminance: 95, request_id: 'normal-80' }
    ]);
    const disabledValidationWhite = { ire: 100, luminance: 161, autocal_white_y: 161, autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true, autocal_target_reference_disabled: true };
    const normalReferenceWhite = { ire: 100, luminance: 162, autocal_white_y: 162, autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true };
    globalThis.disabledLegalWhiteReference = meterFindLgAutoCalLegalWhiteReference([disabledValidationWhite]);
    globalThis.normalLegalWhiteReference = meterFindLgAutoCalLegalWhiteReference([normalReferenceWhite]);
    globalThis.disabledExplicitTargetWhite = meterExplicitLgTargetWhiteReferenceNits([disabledValidationWhite]);
    globalThis.normalExplicitTargetWhiteDuringAutoCal = meterExplicitLgTargetWhiteReferenceNits([normalReferenceWhite]);
    globalThis.activeAutoCalReference = meterEffectiveGreyscaleWhiteReference([
      { ire: 3, name: '3%', luminance: 0.4 },
      { ire: 99, name: '99%', luminance: 149, request_id: 'visible-only-99' }
    ]);
    meterAutoCalRunning = false;
    globalThis.normalExplicitTargetWhiteAfterAutoCal = meterExplicitLgTargetWhiteReferenceNits([normalReferenceWhite]);
    globalThis.completePhaseTargetReferenceActive = meterAutoCalGreyscaleTargetWhiteReferenceActive([
      { ire: 99, name: '99%', luminance: 149 }
    ]);
    meterFindSeriesWhiteReading = function(readings){
      return (readings || []).find(reading => Number(reading && reading.ire) === 100 && meterReadingHasLuminance(reading)) || null;
    };
    const completedSeriesWhite = meterEffectiveGreyscaleWhiteReference([
      normalReferenceWhite,
      { ire: 109, name: '109%', luminance: 230, Y: 230, series_mode: 'lg-autocal-26' }
    ]);
    globalThis.completedSeriesWhiteY = meterReadingLuminanceNits(completedSeriesWhite);
    globalThis.completedSeriesWhiteSynthetic = completedSeriesWhite && completedSeriesWhite.synthetic_target;
  `
].join('\n'), context);

assert.strictEqual(context.autocalPaired99CurrentKey, '99', 'AutoCal 99/100 paired legal-white reads should keep the visible/current key on the calibrated 99% slot');
assert.strictEqual(context.autocalNormal95CurrentKey, '95', 'normal AutoCal statuses should still resolve the active key from the current patch');
assert.strictEqual(context.reading99.request_id, 'current-autocal-99', 'AutoCal chart should prefer current best-known direct 99 over stale series/status 99');
assert.strictEqual(context.reading99.name, '99%', 'LG26 chart labels should stay on nominal slot labels instead of showing code-derived stimulus values');
assert(Math.abs(Number(context.reading99.stimulus) - 99.087) < 0.001, 'LG26 chart analysis should still retain the code-derived 99% stimulus separately from the label');
assert.strictEqual(context.bestKnown99ForChart.name, '99%', 'Best-known 99 should match the actual 99 step, not the 100% legal-white DDC alias');
assert.strictEqual(context.bestKnown99ForChart.autocal_reference_only, undefined, 'Best-known 99 should not inherit reference-only metadata from the 100% legal-white alias');
assert.strictEqual(context.reading99.best_known_delta_e, 0.2478727, 'best-known direct 99 delta should remain attached for status/report context');
assert.strictEqual(context.reading99.best_known_reached_target, true, 'direct 99 reached/good status should remain available');
assert.strictEqual(context.reading99.legal_white_validation_status, 'diagnostic_only_failed', 'legal-white diagnostic status should remain recorded separately');
assert.strictEqual(context.reading95.request_id, 'status-95', 'non-best-known status readings should still be shown for current AutoCal context');
assert.strictEqual(context.chartReadings.length, 2, 'AutoCal chart should contain merged current status/best-known readings only');
assert.strictEqual(
  JSON.stringify(context.filteredAutoCalChartItems.map(item => item.request_id || item.name)),
  JSON.stringify(['normal-99', 'normal-105', 'normal-80']),
  'AutoCal chart filtering should hide diagnostic top-cluster/legal-white reads while preserving normal calibrated points'
);
assert.strictEqual(context.disabledLegalWhiteReference, null, 'disabled legal-white validation should not become the LG AutoCal chart legal-white reference');
assert.strictEqual(context.disabledExplicitTargetWhite, null, 'disabled legal-white validation autocal_white_y should not become an explicit target white');
assert.strictEqual(context.normalLegalWhiteReference && context.normalLegalWhiteReference.luminance, 162, 'normal series/reference 100% should remain eligible as legal white');
assert.strictEqual(context.normalExplicitTargetWhiteDuringAutoCal, null, 'normal read-only legal white should not provide the active AutoCal target-white basis');
assert.strictEqual(
  context.activeAutoCalReference && context.activeAutoCalReference.synthetic_target,
  true,
  'active AutoCal charts should use the synthetic/derived target reference instead of a hidden legal-white read'
);
assert.strictEqual(context.normalExplicitTargetWhiteAfterAutoCal, 162, 'normal completed series/reference 100% should still provide explicit target white');
assert.strictEqual(
  context.completePhaseTargetReferenceActive,
  false,
  'AutoCal complete popup state should not keep target-white override active for existing chart readings'
);
assert.strictEqual(context.completedSeriesWhiteY, 162, 'completed LG26 series reads should keep the measured 100% legal-white chart reference even after 109% arrives');
assert.strictEqual(context.completedSeriesWhiteSynthetic, undefined, 'completed LG26 series reads should not synthesize chart white from the 109% read');

const headroomContext = {
  console,
  JSON,
  Object,
  Array,
  Number,
  String,
};
vm.createContext(headroomContext);
vm.runInContext([
  `
    var meterActiveSeriesType = 'greyscale';
    var meterActiveSeriesPoints = 26;
    var meterActiveSeriesSignalMode = 'sdr';
    var meterAutoCalRunning = false;
    var meterAutoCalPolling = false;
    var meterActionPending = false;
    var meterFullAutoCalRunning = false;
    var meterFullAutoCalPhase = '';
    const document = { getElementById: () => ({ value: 'bt1886' }) };
    function meterUseLgAutoCal26(){ return true; }
    function meterGreyAllowsHeadroomTargets(){ return true; }
    function meterReadingIsGreyscale(){ return true; }
    function meterReadingHasLuminance(reading){ return !!(reading && ((reading.luminance != null && reading.luminance >= 0) || (reading.Y != null && reading.Y >= 0))); }
    function meterReadingLuminanceNits(reading){ return Number(reading && (reading.luminance != null ? reading.luminance : reading.Y)); }
    function meterReadingPlotIre(reading){ return reading && (reading.plot_ire != null ? reading.plot_ire : reading.ire); }
    function meterHdrDiffuseWhiteOverride(){ return null; }
    function meterChartIsPq(){ return false; }
    function meterChartIsDv(){ return false; }
    function meterChartIsHdr(){ return false; }
    function meterChartIsHlg(){ return false; }
    function meterDvMapModeValue(){ return '0'; }
    function meterGreyChartUsesPqTarget(){ return false; }
    function meterPatchUsesVideoRange(){ return true; }
    function meterPatchRangeMin(){ return 16; }
    function meterPatchRangeSpan(){ return 219; }
    function meterGreySignalFractionFromCode(code){ return (Number(code) - 64) / 876; }
    function meterGreyCodeLooksHeadroom(code){ return Number(code) > 255; }
    function meterGreyChartTargetGammaSelection(){ return 'bt1886'; }
    function meterGreyChartTargetCode(step){ return step && (step.r_code != null ? step.r_code : step.r); }
    function meterExplicitLgTargetWhiteReferenceNits(){ return null; }
    function meterStoredLgTargetWhiteReferenceNits(){ return null; }
    function meterColorReferenceNits(){ return 200; }
    function meterChartBlackLevel(){ return 0; }
    function meterFindSeriesWhiteReading(readings){
      return (readings || []).find(reading => Number(reading && reading.ire) === 100 && meterReadingHasLuminance(reading)) || null;
    }
    function meterGreyscaleReferenceReadings(readings){
      return (readings || []).filter(reading => reading && meterReadingIsGreyscale(reading) && meterReadingHasLuminance(reading));
    }
  `,
  extractFunction('meterAutoCalGreyscaleTargetWhiteReferenceActive'),
  extractFunction('meterReadingsUseLgHeadroomReference'),
  extractFunction('meterReadingsHaveLgAutoCal26SeriesMarker'),
  extractFunction('meterLgAutoCal26SeriesReadUsesInitialWhite'),
  extractFunction('meterGreyHeadroomReferenceReading'),
  extractFunction('bt1886Eotf'),
  extractFunction('gammaEotf'),
  extractFunction('srgbEotf'),
  extractFunction('targetEotf'),
  extractFunction('meterGreyTargetSignal'),
  extractFunction('meterGreyTargetLuminance'),
  extractFunction('meterGreyStepCodeForIre'),
  extractFunction('meterGreySolvePeakFromHeadroomReading'),
  extractFunction('meterLgHeadroomDerivedWhiteReferenceNits'),
  extractFunction('meterGreyTargetPeakForReadings'),
  `
    const steps = [{ ire: 100, r: 940 }, { ire: 109, r: 1023 }];
    const readings = [
      { ire: 100, name: '100% legal white', luminance: 200, Y: 200, autocal_white_reference: true, autocal_reference_only: true, autocal_legal_white_anchor: true },
      { ire: 109, name: '109%', luminance: 230, Y: 230, r_code: 1023, series_mode: 'lg-autocal-26' }
    ];
    globalThis.seriesHeadroomReference = meterLgHeadroomDerivedWhiteReferenceNits(readings);
    globalThis.seriesPeak = meterGreyTargetPeakForReadings(readings, steps, 200, 0);
    meterAutoCalRunning = true;
    meterFullAutoCalRunning = true;
    meterFullAutoCalPhase = 'post-3d-polish';
    globalThis.autoCalHeadroomReference = meterLgHeadroomDerivedWhiteReferenceNits(readings);
    globalThis.autoCalPeak = meterGreyTargetPeakForReadings(readings, steps, 200, 0);
  `
].join('\n'), headroomContext);

assert.strictEqual(headroomContext.seriesHeadroomReference, null, '26pt series reads should not derive chart white from 109% headroom');
assert.strictEqual(headroomContext.seriesPeak, 200, '26pt series reads should keep the initial 100% white target peak after 109% is read');
assert(Number.isFinite(headroomContext.autoCalHeadroomReference) && Math.abs(headroomContext.autoCalHeadroomReference - 200) > 0.01, 'active AutoCal should still be allowed to derive target white from 109%');
assert(Number.isFinite(headroomContext.autoCalPeak) && Math.abs(headroomContext.autoCalPeak - 200) > 0.01, 'active AutoCal chart targets should still use the 109%-derived white peak');
assert(
  extractFunction('meterEnsureDeltaECache').includes('greyWhiteStamp') &&
    extractFunction('meterEnsureDeltaECache').includes('meterGreyscaleChartWhiteReference(readings)'),
  'DeltaE cache key should include the active greyscale white/reference so popup-only target changes cannot reuse stale dE'
);

console.log('WebUI LG AutoCal chart source regression checks passed.');

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
    else if (ch === '}') { depth--; if (depth === 0) return source.slice(start, i + 1); }
  }
  throw new Error(`Failed to extract function ${name}`);
}

// Each scenario builds a vm sandbox that wires the meterChart* /
// meterActiveSeries* helpers `meterColorSeriesReferenceNits` calls and
// stubs out the lookup helpers it uses. The expected reference nits for
// each scenario is asserted at the end.
function makeSandbox(seriesType, signalMode, masterPeak, measuredWhiteLum) {
  const whiteReading = { luminance: measuredWhiteLum, Y: measuredWhiteLum, name: 'White', r_code: 940, g_code: 940, b_code: 940, ire: 100 };
  const sandbox = {
    meterActiveSeriesType: seriesType,
    meterActiveSeriesSignalMode: signalMode,
    meterWhiteReading: whiteReading,
    meterReadings: [whiteReading],
    config: { max_luma: String(masterPeak) },
    meterChartSignalMode() { return signalMode; },
    meterActiveChartSignalMode() { return signalMode; },
    meterChartIsDv() { return signalMode === 'dv'; },
    meterChartIsPq() { return signalMode === 'hdr10' || signalMode === 'dv'; },
    meterChartIsHdr() { return signalMode !== 'sdr'; },
    meterChartHdrPeak() { return masterPeak; },
    meterChartMasterPeak() { return masterPeak; },
    meterDvMapModeValue() { return '0'; },
    meterFindMeasuredWhiteReading() { return whiteReading; },
    meterReadingLuminanceNits(rd) { return rd && rd.luminance > 0 ? rd.luminance : 0; },
    meterExplicitLgTargetWhiteReferenceNits() { return 0; },
    meterColorReferenceNits() { return masterPeak; },
    meterColorSeriesTargetWhiteForRun() { return 0; },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  return sandbox;
}

function runWith(sandbox) {
  const fn = extractFunction('meterColorSeriesReferenceNits');
  vm.runInContext(fn, sandbox);
  return sandbox.meterColorSeriesReferenceNits();
}

// Bug fix: in HDR10 PQ the saturations/color generator bakes target_Yn
// normalized to the 10000-nit PQ space (see webui.pm ~3052:
// target_Yn = level_linear / mx, where level_linear = PQ_decode(signal)/10000).
// The chart then does `Y = tYn * refY`, so the reference must be the PQ
// mastering peak (10000), not the display's measured white. With a measured
// white of 721.8 nits, Magenta 75% currently shows Target Y = 3.0 cd/m^2
// instead of the correct ~41 nits.
{
  const sb = makeSandbox('saturations', 'hdr10', 10000, 721.8);
  const ref = runWith(sb);
  assert.strictEqual(ref, 10000,
    'HDR10 PQ saturations: reference nits must be the PQ mastering peak (10000), not the measured white (721.8)');
}

{
  const sb = makeSandbox('colors', 'hdr10', 10000, 721.8);
  const ref = runWith(sb);
  assert.strictEqual(ref, 10000,
    'HDR10 PQ colors: reference nits must be the PQ mastering peak (10000), not the measured white (721.8)');
}

// SDR is unchanged: tYn is white-relative, so the measured white IS the right
// reference (a 50% SDR patch expects Y = 0.5 * measured_white).
{
  const sb = makeSandbox('saturations', 'sdr', 100, 100);
  const ref = runWith(sb);
  assert.strictEqual(ref, 100,
    'SDR saturations: reference nits must remain the measured white (no HDR-only change)');
}

// HLG is not PQ, so the PQ-absolute fix must not touch it either; the
// measured white is the correct reference.
{
  const sb = makeSandbox('saturations', 'hlg', 1000, 800);
  const ref = runWith(sb);
  assert.strictEqual(ref, 800,
    'HLG saturations: reference nits must remain the measured white (HLG is relative, not PQ-absolute)');
}

// DV absolute (dv_map_mode='1') was already anchored to mastering peak; the
// fix must not regress that.
{
  const sb = makeSandbox('saturations', 'dv', 10000, 750);
  // Override the dv_map_mode to '1' for this case
  sb.meterDvMapModeValue = function() { return '1'; };
  // meterColorReferenceNits for DV absolute returns master peak (10000)
  const ref = runWith(sb);
  assert.strictEqual(ref, 10000,
    'DV absolute saturations: reference nits must remain the mastering peak (10000)');
}

console.log('hdr sat target Y pq-absolute regression OK');

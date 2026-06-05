const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const workerSource = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceFunction(name) {
  const token = `async function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing ${name}`);
  const next = source.indexOf('\nasync function ', start + token.length);
  const alt = source.indexOf('\nfunction ', start + token.length);
  const candidates = [next, alt].filter(index => index > start);
  const end = candidates.length ? Math.min(...candidates) : source.length;
  return source.slice(start, end);
}

const resetFlow = sliceFunction('meterAutoCalRunPreflightReset');
assert(
  resetFlow.includes('const ddcReset=await meterAutoCalResetDdc();') &&
    resetFlow.includes('if(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)') &&
    resetFlow.includes('lutReset=await meterAutoCalReset3dLutBaseline();'),
  'Greyscale reset should always run DDC reset, while 3D LUT reset remains gated to full workflow'
);

const resetDdc = sliceFunction('meterAutoCalResetDdc');
const pictureResetIdx = resetDdc.indexOf("fetchJSON('/api/lg/picture-settings/reset'");
const ddcSetIdx = resetDdc.indexOf("fetchJSON('/api/lg/picture-settings/set'");
assert(pictureResetIdx >= 0, 'Greyscale reset should first reset the active LG picture mode');
assert(ddcSetIdx > pictureResetIdx, 'DDC clear/write should happen after the picture-mode reset');
assert(
  resetDdc.includes('require_white_balance_reset:true') &&
    resetDdc.includes('response.picture_mode_reset=pictureModeReset;') &&
    resetDdc.includes("throw new Error('LG picture mode reset did not confirm a 1D LUT baseline reset.');"),
  'Picture-mode reset should require white-balance reset and still verify the DDC baseline clear'
);

const disclaimer = sliceFunction('meterAutoCalAcceptDisclaimer');
const levelIdx = disclaimer.indexOf('meterAutoCalLevelPreflight=await meterAutoCalRunLevelPreflight();');
const setupIdx = disclaimer.indexOf('const setupReading=await meterAutoCalLuminanceSetupLoop(whiteStep);');
const skipIdx = disclaimer.indexOf('meterAutoCalLevelPreflight={skipped:true};');

assert(levelIdx < 0, 'The AutoCal wizard should not run the black/white brightness clipping preflight');
assert(setupIdx >= 0, 'The AutoCal wizard should still run the live 100% luminance setup');
assert(skipIdx >= 0 && skipIdx < setupIdx, 'Wizard preflight should be marked skipped before 100% setup starts');

assert(
  source.includes('async function meterAutoCalRunLevelPreflight()'),
  'The level-preflight helper can remain available without being part of the wizard'
);

const workerInitialBlack = workerSource.indexOf('"Reading initial 0% black reference for target curve"');
const workerOrderedLoop = workerSource.indexOf('foreach my $step (@ordered)', workerInitialBlack);
assert(workerInitialBlack >= 0, 'LG26 worker should read an initial 0% black reference');
assert(workerOrderedLoop > workerInitialBlack, 'Initial 0% black reference should run before ordered AutoCal calibration');
assert(
  /my\s+\@lg_autocal_26_order\s*=\s*\(\s*109\s*,/.test(workerSource),
  'LG26 ordered calibration should still start at 109 after the initial black reference'
);

console.log('LG AutoCal picture-reset and initial-black regression checks passed.');

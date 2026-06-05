const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

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

assert(levelIdx >= 0, 'SDR greyscale AutoCal should run the black/white level preflight after reset');
assert(setupIdx > levelIdx, 'Level preflight should finish before the live 100% luminance setup starts');
assert(skipIdx > setupIdx, 'Only the non-luminance setup path should mark level preflight skipped');

assert(
  !disclaimer.includes('Auto Cal must not change those TV picture controls implicitly'),
  'Greyscale AutoCal should not carry the old forced-skip comment'
);

console.log('LG AutoCal level-preflight regression checks passed.');

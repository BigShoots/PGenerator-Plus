const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function sliceBetween(startNeedle, endNeedle, from = 0) {
  const start = source.indexOf(startNeedle, from);
  assert(start >= 0, `${startNeedle} should be present`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `${endNeedle} should follow ${startNeedle}`);
  return source.slice(start, end);
}

const targetSource = sliceBetween(
  'function meterGreyTvTarget(step)',
  'function meterGreyTvTargetAdjustable(target)'
);
assert(
  targetSource.includes("key:'readonly:0'") &&
    targetSource.includes('read_only:true') &&
    targetSource.includes("return {unsupported:true,key:'unsupported:'+meterFormatPercentValue(ire),reason:reason};"),
  '0% should remain a read-only target and unmapped greyscale steps should still be represented as unsupported targets'
);

const renderSource = sliceBetween(
  'function meterRenderGreyTvControls(reading)',
  'async function meterLgGreySyncForCurrentStep'
);
assert(
  !renderSource.includes('if(target.unsupported){') &&
    renderSource.includes('const targetAdjustable=meterGreyTvTargetAdjustable(target);') &&
    renderSource.includes("!state.picture&&targetAdjustable") &&
    renderSource.includes('(target&&target.unsupported) ||') &&
    renderSource.includes("meterGreyTvColumnHtml('r','R','#f44'") &&
    renderSource.includes("meterGreyTvColumnHtml('g','G','#4caf50'") &&
    renderSource.includes("meterGreyTvColumnHtml('b','B','#42a5f5'") &&
    renderSource.includes("meta.textContent=unsupportedLabel?('LG '+unsupportedLabel+'% read-only'):'LG read-only';"),
  'LG RGB panel should render balance bars for unmapped/read-only greyscale patches while suppressing manual controls'
);

const syncSource = sliceBetween(
  'async function meterLgGreySyncForCurrentStep(forceRefresh)',
  'async function meterGreyAdjustCurrentStepChannel'
);
assert(
  syncSource.includes('if(!target||target.unsupported||target.read_only)') &&
    syncSource.includes('meterRenderGreyTvControls(meterFindReadingForStep(meterCurrentPatchStep));'),
  'unmapped and 0% read-only patches should render locally without fetching LG DDC controls'
);

console.log('WebUI LG RGB unmapped greyscale regression passed');

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
  'function meterGreyTvTarget(step,opts)',
  'function meterGreyTvSettingKey(channel)'
);
assert(
  targetSource.includes('const allowSeriesRunning=!!(opts&&opts.allow_series_running);') &&
    targetSource.includes('(!allowSeriesRunning&&meterSeriesRunning)') &&
    targetSource.includes("return {unsupported:true,key:'unsupported:'+meterFormatPercentValue(ire),reason:reason};"),
  'LG RGB target lookup should stay disabled during series except for explicit read-only live rendering'
);

const renderSource = sliceBetween(
  'function meterRenderGreyTvControls(reading)',
  'async function meterLgGreySyncForCurrentStep'
);
assert(
  renderSource.includes('const seriesReadOnly=!!(meterSeriesRunning&&reading&&meterReadingIsGreyscale(reading));') &&
    renderSource.includes('const renderStep=seriesReadOnly?(meterCanonicalSeriesStep(reading)||reading):meterCurrentPatchStep;') &&
    renderSource.includes('const target=meterGreyTvTarget(renderStep,{allow_series_running:seriesReadOnly});') &&
    renderSource.includes("&&!seriesReadOnly") &&
    renderSource.includes('const selected=seriesReadOnly?null:meterGreyTvSelectedValues(state);') &&
    renderSource.includes('seriesReadOnly ||') &&
    renderSource.includes("if(seriesReadOnly) meta.textContent='LG '+target.label+' read-only';"),
  'LG RGB panel should render read-only live RGB bars from the current greyscale series reading'
);

const pollSource = sliceBetween(
  'async function meterPollSeries()',
  'let meterSelectedThumbIre=null;'
);
assert(
  pollSource.includes('const currentStep=meterFindCurrentSeriesStep(currentIre);') &&
    pollSource.includes("if(currentStep&&meterActiveSeriesType==='greyscale') meterCurrentPatchStep=meterClonePatchStep(currentStep)||currentStep;") &&
    pollSource.includes('const currentReading=meterCurrentPatchStep?meterFindReadingForStep(meterCurrentPatchStep):null;') &&
    pollSource.includes('liveSeriesReading=currentReading||lastValid||null;') &&
    pollSource.includes("meterRenderGreyTvControls(meterCurrentPatchStep);"),
  'running series polls should track the status-current greyscale step and prefer its reading for the LG RGB panel'
);

const currentStepSource = sliceBetween(
  'function meterFindCurrentSeriesStep(key)',
  'function meterQueueGreyscaleTargetSync'
);
assert(
  currentStepSource.includes('if(meterStepNameKey(step)===text) return true;') &&
    currentStepSource.includes("if(String(step&&step.name||'')===text) return true;") &&
    currentStepSource.includes('return meterReadingPatchLabel(step)===text;'),
  'current series status keys should map back to canonical steps by key, name, or label'
);

console.log('WebUI LG RGB series read-only regression passed');

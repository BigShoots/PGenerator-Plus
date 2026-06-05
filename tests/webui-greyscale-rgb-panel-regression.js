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

assert(
  source.includes('id="meterGreyTvTitle"') &&
    source.includes('>RGB</div>') &&
    source.includes('id="meterGreyTvWrap"') &&
    source.includes('display:flex;flex-direction:column'),
  'Greyscale should render the shared tall RGB widget by default'
);

const widgetMode = sliceBetween(
  'function meterUpdateGreyTvWidgetMode(useTvControls)',
  'function meterRenderGreyRgbReadOnly(reading)'
);
assert(
  widgetMode.includes("wrap.classList.toggle('lg-calibration-mode',true);") &&
    widgetMode.includes("legacy.style.display='none';") &&
    widgetMode.includes("tv.style.display='flex';") &&
    widgetMode.includes("title.textContent=useTvControls?'LG RGB':'RGB';") &&
    widgetMode.includes("meta.style.display=useTvControls?'':'none';"),
  'The greyscale RGB widget should use the large LG-layout panel while only the title/footer depend on TV connection'
);

const readOnlyPanel = sliceBetween(
  'function meterGreyscaleRgbPanelReading(reading)',
  'function meterRenderGreyTvControls(reading)'
);
assert(
  readOnlyPanel.includes('const current=meterCurrentPatchStep?meterFindReadingForStep(meterCurrentPatchStep):null;') &&
    readOnlyPanel.includes('for(let i=meterReadings.length-1;i>=0;i--)') &&
    readOnlyPanel.includes('const panelReading=meterGreyscaleRgbPanelReading(reading);') &&
    readOnlyPanel.includes('const liveRgb=panelReading?meterLiveRgbData(panelReading):null;'),
  'Disconnected greyscale RGB bars should fall back to the current or latest measured greyscale reading'
);

const readOnlyWidget = sliceBetween(
  'function meterRenderGreyRgbReadOnly(reading)',
  'function meterRenderGreyTvControls(reading)'
);
assert(
  (readOnlyWidget.match(/meterGreyTvColumnHtml\('[rgb]','[RGB]'/g) || []).length === 3 &&
    (readOnlyWidget.match(/halfRange,true,true\)/g) || []).length === 3 &&
    readOnlyWidget.includes("host.innerHTML='<div class=\"meter-lg-rgb-host meter-lg-rgb-readonly-host\">'") &&
    readOnlyWidget.includes("meta.style.display='none';"),
  'Disconnected greyscale should render the same glowing RGB bars in read-only mode with no controls or picture-mode footer'
);

const renderPanel = sliceBetween(
  'function meterRenderGreyTvControls(reading)',
  'async function meterLgGreySyncForCurrentStep'
);
assert(
  renderPanel.includes('if(!connected){') &&
    renderPanel.includes('meterRenderGreyRgbReadOnly(reading);') &&
    !renderPanel.includes("host.innerHTML='<div style=\"height:100%;display:flex;align-items:center;justify-content:center;text-align:center;font-size:.68rem;color:var(--text2);padding:8px\">LG TV</div>';"),
  'Disconnected greyscale should not show the old LG TV placeholder'
);

console.log('WebUI greyscale RGB panel regression passed');

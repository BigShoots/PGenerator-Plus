'use strict';

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
assert(source.includes("meterNiceAxisTopForZoom('chartEOTF',yTop,0.2,10)"),'EOTF Y zoom must bypass coarse post-zoom axis snapping');
assert(source.includes("meterNiceAxisTopForZoom('chartGamma',yTop,50,10)"),'luminance Y zoom must bypass coarse post-zoom axis snapping');
assert(source.includes("if(!meterChartYZoomIsActive(id)) return meterNiceAxisTop(dataMax,base,maxTicks)"),'default axes must retain clean rounded divisions');
const start = source.indexOf('async function meterSelectSeries(type,points,opts)');
const end = source.indexOf('function meterMeasurementSignalContext', start);
assert(start >= 0 && end > start, 'meterSelectSeries function is missing');
const select = source.slice(start, end);

assert(
  select.includes('else if(meterContinuousActive||meterContinuousSuspendedForLgWrite||meterContinuousTimer) meterStopContinuous();'),
  'an idle series switch must not rebuild the outgoing series through meterStopContinuous'
);
assert(
  !select.includes('else meterStopContinuous();'),
  'unconditional idle continuous-stop teardown has returned'
);
assert(
  source.includes("window.requestAnimationFrame(()=>setTimeout(drawRecoveredCharts,0))"),
  'cached series chart redraw must yield so the new selection can paint first'
);

console.log('series switch performance regression OK');

'use strict';

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
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

console.log('series switch performance regression OK');

const assert=require('assert');
const fs=require('fs');
const src=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
const start=src.indexOf('function meterTargetXYZForReading(');
const end=src.indexOf('function meterTargetChromaticityForReading(');
assert(start>=0&&end>start,'meterTargetXYZForReading present');
const fn=src.slice(start,end);
// HDR10 color/sat: the neutral WHITE reference patch must reference the
// display's achieved measured white (not the PQ peak), so the panel's peak
// rolloff does not read as a spurious white luminance error. Colored patches
// keep the PQ-absolute reference.
assert(/meterActiveChartSignalMode\(\)==='hdr10'/.test(fn),'white override gated on hdr10');
assert(/meterReadingIsGreyscale\(reading\)/.test(fn),'white override detects the neutral reference patch');
assert(/meterFindMeasuredWhiteReading\(\)/.test(fn)&&/refY=_whiteRefY/.test(fn),'white reference reassigns refY to the measured achieved white');
console.log('hdr color white luminance reference regression OK');

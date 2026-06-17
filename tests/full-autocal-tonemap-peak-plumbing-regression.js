const assert=require('assert');
const fs=require('fs');
const src=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
const peakStart=src.indexOf('function meterFullAutoCalToneMapPeakLuminance(');
assert(peakStart>=0,'peak fn present');
const peakFn=src.slice(peakStart,peakStart+800);
// Peak lookup must consider the greyscale-stage tone-map peak (on the status
// and on the saved first/greyscale result).
assert(/status&&status\.hdr20_1d_tonemap_peak_luminance/.test(peakFn),'peak lookup checks status.hdr20_1d_tonemap_peak_luminance');
assert(/meterFullAutoCalResults\.first\.hdr20_1d_tonemap_peak_luminance/.test(peakFn),'peak lookup checks first.hdr20_1d_tonemap_peak_luminance');
const compStart=src.indexOf('async function meterFullAutoCalCompleteAfterHdrToneMap(');
assert(compStart>=0,'completion fn present');
const compFn=src.slice(compStart,compStart+1100);
// The completion step pulls the greyscale tone-map fields into the working
// status so the wizard-owned upload triggers (they were lost in 3D/polish).
assert(/meterFullAutoCalResults&&meterFullAutoCalResults\.first/.test(compFn),'completion reads the saved greyscale status');
assert(/hdr20_1d_tonemap_pending/.test(compFn)&&/hdr20_1d_tonemap_peak_luminance/.test(compFn),'completion merges greyscale tonemap_pending + peak');
console.log('full-autocal tonemap peak plumbing regression OK');

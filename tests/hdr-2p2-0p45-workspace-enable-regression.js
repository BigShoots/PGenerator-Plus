const assert=require('assert');
const fs=require('fs');
const src=fs.readFileSync('usr/sbin/pgenerator-lg','utf8');
// HDR-only reset workflow enables the 2.2/0.45 gamma workspace at CAL_START.
assert(/\["1D_2_2_EN",1\]/.test(src),'reset workflow enables 1D_2_2_EN');
assert(/\["1D_0_45_EN",1\]/.test(src),'reset workflow enables 1D_0_45_EN');
// The shared 1D pipeline enable gates the workspace on an HDR picture mode,
// so SDR (sdr26) keeps it disabled.
const i=src.indexOf('sub lg_ddc_enable_1d_pipeline');
assert(i>=0,'pipeline fn present');
const pipe=src.slice(i,i+1000);
assert(/\$is_hdr_mode/.test(pipe),'pipeline derives an is_hdr_mode flag');
assert(/=~\s*\/hdr\/i/.test(pipe),'is_hdr_mode is derived from an hdr picture-mode match');
assert(/"1D_2_2_EN","ddc_enable_1d_degamma",0,\$is_hdr_mode/.test(pipe),'1D_2_2_EN enable gated on is_hdr_mode');
assert(/"1D_0_45_EN","ddc_enable_1d_regamma",0,\$is_hdr_mode/.test(pipe),'1D_0_45_EN enable gated on is_hdr_mode');
console.log('hdr 2.2/0.45 workspace enable (hdr-gated) regression OK');

// Regression test for the ColorChecker HDR PQ encode-peak bug.
//
// Symptom (pre-fix): during a HDR10 ColorChecker series run, the meter
// measured Yellow and Orange Yellow with a large chromaticity error (8+ dE).
// Re-reading the same patches as a single read after the series corrected
// the dE -- because meterDisplayPatch / meterFreshSeriesStep rebuild
// meterSeriesSteps from the client-side builder, which used a different
// luminance reference than the server (so the thumbnail click re-sent a
// different stimulus than the series did).
//
// Root cause: meterEncodeColorCheckerLinear hardcoded PQ encode against
// 100 nits (SDR-style) when running HDR PQ, while the server builder
// (webui_meter_series_start) encodes against the active series peak
// (typically max_luma = 1000). Client preview codes therefore didn't match
// the actual wire codes, and the cached client-built steps got re-sent on
// thumbnail refresh / single reread.
//
// Fix: use the active series peak (meterActiveSeriesMaxLuma, stamped at
// series start from the server response), falling back to
// meterChartHdrPeak(), with a 100-nit fallback only when neither is
// available. This makes client preview codes match server actual codes,
// so series-run and single-reread produce the same panel stimulus and
// the same measured x/y.

const assert=require('assert');
const fs=require('fs');
const vm=require('vm');

const source=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');

function extractFunction(name){
 const token=`function ${name}(`;
 const start=source.indexOf(token);
 assert(start>=0,`Missing function ${name}`);
 let i=source.indexOf('{',start);
 let depth=0;
 for(;i<source.length;i++){
  const ch=source[i];
  if(ch==='{') depth++;
  else if(ch==='}'){ depth--; if(depth===0) return source.slice(start,i+1); }
 }
 throw new Error(`Failed to extract function ${name}`);
}

const context={
 // Chart context: HDR10 PQ with BT.2020 container, active peak = 1000 nits
 // (matches the default PGenerator config and the webui_meter_series_start
 // cc_ref path used by the operator's HDR10 ColorChecker series).
 meterChartIsPq: ()=>true,
 meterChartIsDv: ()=>false,
 meterChartIsHdr: ()=>true,
 meterDvClassicColorCheckerScale: ()=>1,
 meterTargetLinearToSignal: (v)=>v,
 meterChromaPatchRangeMin: ()=>16,
 meterChromaPatchRangeSpan: ()=>219,
 meterActiveSeriesMaxLuma:1000,
 meterChartHdrPeak: ()=>1000,
 // PQ encode: ITU-R BT.2100 PQ OETF on absolute nits, capped at 10000.
 meterChartPqEncodeNormalized:(nits)=>{
  if(nits<=0) return 0;
  const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
  const l=Math.max(0,Math.min(1,nits/10000));
  const p=Math.pow(l,m1);
  return Math.pow((c1+c2*p)/(1+c3*p),m2);
 },
};
vm.createContext(context);
vm.runInContext(extractFunction('meterEncodeColorCheckerLinear'), context);

// Reference: the server-side encoding for a HDR10 ColorChecker patch with
// linear R = G = 0.86, B = 0, max_luma = 1000:
//   pq_encode(0.86 * 1000) -> PQ at 860 nits -> 10-bit code -> limited-range 8-bit
// Helper recomputes the same path using the fixed client code.
function expectedHdrPqCode(linear, peak){
 const min=16, span=219;
 const clamped=Math.max(0,Math.min(1,linear||0));
 const norm=context.meterChartPqEncodeNormalized(clamped*peak);
 return Math.round(min + norm*span);
}

// === ColorChecker Yellow: linear R = G = 0.86 (after BT.2020 solve, no clip).
// The fixed encode must match the server's pq_encode(0.86 * 1000) = ~173.
// The pre-fix code used 100 nits ref and produced ~122 -- the wrong stimulus.
{
 const code=context.meterEncodeColorCheckerLinear(0.86);
 const expected=expectedHdrPqCode(0.86, 1000);
 assert(code===expected,
  `ColorChecker Yellow R/G (linear 0.86) must encode against max_luma (1000), not 100. Got ${code}, expected ${expected}.`);
 assert(code>=160 && code<=185,
  `ColorChecker Yellow code must land near the server's value (~173). Got ${code}.`);
}

// === ColorChecker Orange Yellow: linear ~0.59 R/G -- also bright.
{
 const code=context.meterEncodeColorCheckerLinear(0.59);
 const expected=expectedHdrPqCode(0.59, 1000);
 assert(code===expected,
  `ColorChecker Orange Yellow (linear 0.59) must encode against max_luma. Got ${code}, expected ${expected}.`);
}

// === ColorChecker Dark Skin: linear ~0.115 -- low brightness, must also
// scale with max_luma (the bug would have under-driven all ColorChecker
// chromatic patches in HDR PQ, not just Yellow/Orange Yellow).
{
 const code=context.meterEncodeColorCheckerLinear(0.115);
 const expected=expectedHdrPqCode(0.115, 1000);
 assert(code===expected,
  `ColorChecker Dark Skin (linear 0.115) must encode against max_luma. Got ${code}, expected ${expected}.`);
}

// === Active series peak must take precedence over the generic chart peak.
// Some configurations set the live config peak differently from the series
// peak -- the series-built snapshot is what the server actually uses, so
// the client preview must mirror that exact number, not the config value.
{
 context.meterActiveSeriesMaxLuma=4000;
 context.meterChartHdrPeak=()=>1000;
 const code=context.meterEncodeColorCheckerLinear(0.5);
 const expected=expectedHdrPqCode(0.5, 4000);
 assert(code===expected,
  `Active series peak must override the chart peak (4000 vs 1000). Got ${code}, expected ${expected}.`);
}

// === Without an active series peak, fall back to meterChartHdrPeak().
{
 context.meterActiveSeriesMaxLuma=null;
 context.meterChartHdrPeak=()=>750;
 const code=context.meterEncodeColorCheckerLinear(0.5);
 const expected=expectedHdrPqCode(0.5, 750);
 assert(code===expected,
  `Without an active series peak, encode must use meterChartHdrPeak() (750). Got ${code}, expected ${expected}.`);
}

// === Without ANY peak source (cold start before config loads), keep the
// 100-nit historical fallback so SDR-style behavior is preserved.
{
 context.meterActiveSeriesMaxLuma=null;
 context.meterChartHdrPeak=()=>0;
 const code=context.meterEncodeColorCheckerLinear(0.5);
 const expected=expectedHdrPqCode(0.5, 100);
 assert(code===expected,
  `Without any peak source, encode must fall back to 100 nits (pre-fix behavior). Got ${code}, expected ${expected}.`);
}

// === SDR path is untouched (regression guard for the SDR PQ-encode branch).
{
 // Force SDR branch by making meterChartIsPq() false.
 context.meterChartIsPq=()=>false;
 context.meterActiveSeriesMaxLuma=1000;
 context.meterChartHdrPeak=()=>1000;
 const code=context.meterEncodeColorCheckerLinear(0.5);
 // SDR path uses meterTargetLinearToSignal which we stubbed to identity.
 const expected=Math.round(16 + 0.5*219);
 assert(code===expected,
  `SDR path must still use linear->signal, not PQ encode. Got ${code}, expected ${expected}.`);
}

console.log('OK color-checker-hdr-pq-encode-peak-regression: client preview codes now match server actual codes in HDR PQ (max_luma reference, not 100).');

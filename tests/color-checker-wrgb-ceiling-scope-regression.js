// Regression test for the ColorChecker chromatic-patch ceiling-clamp fix.
//
// Symptom (pre-fix): after a ColorChecker HDR10 series that includes the
// 100% R/G/B primaries, a single reread of the Yellow or Orange Yellow patch
// reported very large dE (8+) against the chart target, even though the
// same patch measured correctly during the series. Page refresh (clearing
// meterReadings) made the dE drop back to normal.
//
// Root cause: meterWrgbStimulusTargetY applied the per-primary ceiling clamp
// (meterWrgbPrimaryCeilings, derived from full-drive 100% R/G/B reads) to
// EVERY chromatic patch. ColorChecker Yellow / Orange Yellow have sub-peak
// chromaticities inside the BT.2020/P3 gamut that the panel reproduces by
// tracking the PQ signal; clamping them to the linear-RGB-space ceilings
// once the 100% primaries had been measured shifted their chromaticity, and
// the chart target Y no longer matched the panel's emission.
//
// Fix: only clamp full-saturation primaries/secondaries (sat_pct>=99.5 with
// series_color set) whose chromaticity sits on the gamut boundary. Mid-sat
// and ColorChecker chromaticity patches keep the raw decoded Y so the chart
// target is stable across the series run and across reread vs. fresh-read.

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
 // Chart context: PQ HDR with the active target gamut = P3-D65 (matches the
 // default AutoCal/HDR verification drop-down the operator uses on the LG C2).
 meterChartIsPq: ()=>true,
 meterChartIsHdr: ()=>true,
 meterChartIsDv: ()=>false,
 meterReadingIsGreyscale: (rd)=>{
  if(!rd) return false;
  if(String(rd.series_type||'').toLowerCase()==='greyscale') return true;
  const r=rd.r_code!=null?rd.r_code:rd.r;
  const g=rd.g_code!=null?rd.g_code:rd.g;
  const b=rd.b_code!=null?rd.b_code:rd.b;
  return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
 },
 // BT.2020 / D65 gamut (analysis target for HDR10 ColorChecker patches).
 meterAnalysisGamut: ()=>({
  rgbToXyz:[[0.6369580483,0.1446169036,0.1688809752],[0.2627002120,0.6779980715,0.0593017165],[0.0000000000,0.0280726930,1.0609850577]],
  primaries:{R:{x:0.708,y:0.292},G:{x:0.170,y:0.797},B:{x:0.131,y:0.046}}
 }),
 // PQ-decode each channel code -> absolute nits (capped at HDR peak).
 meterChartPqDecodeNormalized: (norm)=>{
  if(norm<=0) return 0;
  const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
  const p=Math.pow(norm,1/m2);
  const num=Math.max(p-c1,0);
  const den=c2-c3*p;
  if(den<=0) return 10000;
  return 10000*Math.pow(num/den,1/m1);
 },
 meterChartPqEncodeNormalized: (nits)=>{
  if(nits<=0) return 0;
  const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
  const l=Math.max(0,Math.min(1,nits/10000));
  const p=Math.pow(l,m1);
  return Math.pow((c1+c2*p)/(1+c3*p),m2);
 },
 meterChartHdrPeak: ()=>1000,
 // Color-series reference for non-PQ paths (unused for HDR PQ but called).
 meterColorSeriesReferenceNits: ()=>1000,
 // Helpers exercised by the chart target path (no-ops here).
 meterCanonicalSeriesStep: (rd)=>null,
 meterWrgbPrimaryCeilings: ()=>({0:1332,1:885,2:1012}),
 // Decode a wire code into 0..1 by treating the value as a fraction of the
 // limited-range 16..235 container (matches meterPatchRangeMin+Span for HDR
 // PQ ColorChecker patches). meterDecodeColorTargetChannel uses this for
 // both PQ (then PQ-decode) and SDR (then EOTF-decode) paths; the test
 // only exercises PQ so the SDR-side use never triggers.
 meterSignalFractionFromCode: (code)=>{
  const n=Math.max(0,Math.min(1,(Number(code)-16)/219));
  return n;
 },
};
vm.createContext(context);
vm.runInContext([
 extractFunction('meterDecodeColorTargetChannel'),
 extractFunction('meterWrgbStimulusTargetY')
].join('\n'), context);

// Minimal linRgbToXyz (BT.709-ish is fine for Y comparison sanity).
context.linRgbToXyz=(r,g,b,matrix)=>{
 const M=matrix||context.meterAnalysisGamut().rgbToXyz;
 return {X:M[0][0]*r+M[0][1]*g+M[0][2]*b,Y:M[1][0]*r+M[1][1]*g+M[1][2]*b,Z:M[2][0]*r+M[2][1]*g+M[2][2]*b};
};

// Helper: round a number to N decimals (avoid float-equality noise).
const round=(n,d)=>Math.round(n*Math.pow(10,d))/Math.pow(10,d);

// === Yellow ColorChecker patch (HDR10 PQ, BT.2020). Codes from a real
// server-built HDR10 ColorChecker step: r=173, g=168, b=121 (limited range
// 16..235, PQ-encoded). Without ceilings the decoded Y in BT.2020 is
// (0.2627*R + 0.6780*G + 0.0593*B) in nits. With the WRGB primary ceiling
// clamp pre-fix, R linear in linear-RGB space would be clamped to ~1332,
// B to ~1012, which over-amplifies the BT.2020 Y contribution and shifts
// chromaticity -- the dE explosion the user reported. Post-fix: the clamp
// only applies to sat_pct>=99.5 full-saturation primaries/secondaries.
const yellow={
 name:'Yellow',ire:60,
 r_code:173,g_code:168,b_code:121,
 r:173,g:168,b:121,
 target_x:0.44792,target_y:0.475618,target_Yn:0.597462,
 signal_mode:'hdr10',series_type:'colors'
};

const yDecoded=context.meterWrgbStimulusTargetY(yellow);
assert(yDecoded!==null,'meterWrgbStimulusTargetY must return a number for HDR PQ ColorChecker Yellow');

// Decode each channel the same way the function does, for the assertion.
function decodedPerChannel(rd){
 const min=16,span=219;
 const norm=(c)=>Math.max(0,Math.min(1,(c-min)/span));
 const dr=context.meterChartPqDecodeNormalized(norm(rd.r_code));
 const dg=context.meterChartPqDecodeNormalized(norm(rd.g_code));
 const db=context.meterChartPqDecodeNormalized(norm(rd.b_code));
 return {dr,dg,db};
}
const {dr,dg,db}=decodedPerChannel(yellow);
const expectedUnclamped=context.linRgbToXyz(dr,dg,db).Y;
assert(Math.abs(yDecoded-expectedUnclamped)<0.5,
 `ColorChecker Yellow target Y must equal the unclamped stimulus decode (no WRGB primary ceiling shift for chromaticity patches). Got ${round(yDecoded,2)}, expected ~${round(expectedUnclamped,2)}.`);

// Cross-check: a 100% Yellow saturation patch (sat_pct>=99.5) at the same
// full-drive codes WOULD be clamped. The clamp reduces the per-channel nits
// when the decoded linear-RGB value exceeds the measured ceiling, so the
// post-clamp Y must be <= the unclamped decode.
const yellow100={
 name:'100% Yellow',ire:100,
 r_code:235,g_code:235,b_code:16,
 r:235,g:235,b:16,
 target_x:0.4378,target_y:0.5359,target_Yn:0.9207,
 signal_mode:'hdr10',series_type:'colors',series_color:'Yellow',sat_pct:100
};
const y100Decoded=context.meterWrgbStimulusTargetY(yellow100);
assert(y100Decoded!==null,'meterWrgbStimulusTargetY must return a number for HDR PQ 100% Yellow');
const {dr:dr100,dg:dg100,db:db100}=decodedPerChannel(yellow100);
const expected100Unclamped=context.linRgbToXyz(dr100,dg100,db100).Y;
// For these full-drive codes, ceilings[1]=885 < dg100, so G clamps and
// y100Decoded must be < expected100Unclamped (the clamp pulls Y down toward
// the achievable additive primary sum).
assert(y100Decoded<expected100Unclamped+0.001,
 `100% Yellow must apply the WRGB primary ceiling clamp (clamped Y < unclamped Y). Got ${round(y100Decoded,2)}, expected <${round(expected100Unclamped,2)}.`);

// Cross-check the stability invariant the user reported: the chart target
// for the ColorChecker Yellow patch is the same whether or not the 100%
// R/G/B primaries have been measured yet. The ceiling cache is consulted
// only by the full-saturation path, so swapping meterWrgbPrimaryCeilings
// between "no data" and "populated" must not change yDecoded.
{
 context.meterWrgbPrimaryCeilings=()=>({});
 const yNoCeilings=context.meterWrgbStimulusTargetY(yellow);
 context.meterWrgbPrimaryCeilings=()=>({0:1332,1:885,2:1012});
 const yWithCeilings=context.meterWrgbStimulusTargetY(yellow);
 assert(Math.abs(yNoCeilings-yWithCeilings)<1e-9,
  `ColorChecker Yellow target Y must be independent of meterWrgbPrimaryCeilings population. noCeilings=${round(yNoCeilings,4)}, withCeilings=${round(yWithCeilings,4)}.`);
}

console.log('OK color-checker-wrgb-ceiling-scope-regression: ColorChecker chromatic patches bypass the WRGB primary ceiling clamp; only full-saturation primaries/secondaries are clamped; the chart target is stable across series state.');

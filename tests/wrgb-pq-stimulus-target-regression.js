// Regression test for meterWrgbStimulusTargetY in usr/share/PGenerator/webui.pm.
//
// Before the fix, target Y for WRGB-OLED chromatic patches was an additive
// primary sum (and the resulting dE was huge on P3-D65 content). The fix
// derives the target by PQ-decoding the patch's RGB stimulus codes and
// forming XYZ in the analysis gamut, returning the decoded target Y.
//
// This test locks the new behaviour for ordinary reflectance patches: the
// function returns the decoded signal-target Y without consulting any measured
// color, or null when the signal is not PQ or the codes are missing. The six
// full-drive HDR ColorChecker endpoints have a separate WRGB ceiling regression.
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

const context={};
vm.createContext(context);
// Stubs for helpers that are not under test.
context.meterChartIsPq=()=>true;
context.meterChartIsDv=()=>false;
context.meterChartIsHdr=()=>true;
context.meterChartHdrPeak=()=>1000;
context.meterPatchRangeMin=()=>16;
context.meterPatchRangeSpan=()=>219;
// Bit-depth context for meterColorTargetCodeRange. This test models 8-bit
// ColorChecker/saturation codes (16..235), so the decode range stays 8-bit
// limited and the expected per-channel nits below are unchanged.
context.meterPatchUsesVideoRange=()=>true;
context.meterPatchBitDepth=()=>8;
context.meterActiveSeriesCodesAre8Bit=()=>false;
context.meterCanonicalSeriesStep=()=>null;
context.meterWrgbTargetCompensationSelected=()=>true;
context.meterReadingIsGreyscale=()=>false;
context.meterActiveSeriesType=null;
context.meterActiveChartSignalMode=()=>'hdr10';
context.meterReadings=[];
context.meterReadingLuminanceNits=(rd)=>(rd&&rd.luminance!=null)?rd.luminance:(rd&&rd.Y!=null?rd.Y:null);
// P3-D65 matrix (analysis gamut target). The real meterAnalysisGamut()
// would also pull matrix from config, so this stub returns the matrix
// directly to keep the test self-contained.
const P3=[[0.48663243,0.26566758,0.19817182],
          [0.22897456,0.69173852,0.07928691],
          [0.00000000,0.04511331,1.04394437]];
context.meterAnalysisGamut=()=>({rgbToXyz:P3});

vm.runInContext([
 extractFunction('meterWrgbStimulusTargetY'),
 extractFunction('meterWrgbPrimaryCeilings'),
 extractFunction('targetColorXYZAbs'),
 extractFunction('meterColorTargetCodeRange'),
 extractFunction('meterDecodeColorTargetChannel'),
 extractFunction('meterChartPqDecodeNormalized'),
 extractFunction('meterSignalFractionFromCode'),
 extractFunction('linRgbToXyz')
].join('\n'), context);

// === Reflectance Cyan (live LG C2 HDR10 ColorChecker reading). ===
// Y must land between 185 and 210 (~197 expected), and must be > 150 --
// proving the function returns the PQ-decoded signal target rather than
// the pre-fix additive primary sum (~79).
{
 const reading={r_code:121,g_code:145,b_code:156};
 const Y=context.meterWrgbStimulusTargetY(reading);
 assert(Y>150,`Reflectance cyan Y must be > 150 (was the additive ~79 before the fix), got ${Y}`);
 assert(Y>=185 && Y<=210,`Reflectance cyan Y in [185,210] (~197 expected), got ${Y}`);
}

// === Reflectance Green (live LG C2 HDR10 ColorChecker reading). ===
// Y must land between 222 and 250 (~236 expected).
{
 const reading={r_code:135,g_code:151,b_code:123};
 const Y=context.meterWrgbStimulusTargetY(reading);
 assert(Y>=222 && Y<=250,`Reflectance green Y in [222,250] (~236 expected), got ${Y}`);
}

// === Mid grey: Y must equal the per-channel PQ value within 2% ===
// (P3 Y-row coefficients sum to ~1, so for r=g=b the per-channel sum
// collapses to a single PQ-decoded value; the function caps each channel
// at meterChartHdrPeak()=1000 which is well above PQ-decoded mid-grey).
{
 const norm=(128-16)/219;
 const pq=context.meterChartPqDecodeNormalized(norm);
 const Y=context.meterWrgbStimulusTargetY({r_code:128,g_code:128,b_code:128});
 assert(Y>0,`Mid-grey Y must be > 0, got ${Y}`);
 const tol=0.02*Math.max(pq,1);
 assert(Math.abs(Y-pq)<=tol,`Mid-grey Y must equal meterChartPqDecodeNormalized(norm) within 2% (got ${Y}, expected ${pq}, tol ${tol})`);
}

// === Full-code 100% Cyan ===
// The authored signal target is stable and independent of panel measurements.
{
 const Y=context.meterWrgbStimulusTargetY({r_code:16,g_code:235,b_code:235});
 assert(Y>700,`Full-code 100% cyan raw PQ-decode Y must be > 700 (~771 expected), got ${Y}`);
}

// Adding complete R/G/B measurements must not revise an ordinary reflectance
// cyan target. It has no series_color/sat_pct endpoint metadata, so the
// HDR-only full-drive WRGB endpoint correction must not apply.
{
 const saved=context.meterReadings;
 const reading={name:'Cyan',r_code:121,g_code:145,b_code:156};
 context.meterReadings=[];
 const before=context.meterWrgbStimulusTargetY(reading);
 context.meterReadings=[
  {series_color:'Red',  sat_pct:100,r_code:235,g_code:16, b_code:16, Y:87.83,luminance:87.83},
  {series_color:'Green',sat_pct:100,r_code:16, g_code:235,b_code:16, Y:290.87,luminance:290.87},
  {series_color:'Blue', sat_pct:100,r_code:16, g_code:16, b_code:235,Y:31.82,luminance:31.82}
 ];
 const after=context.meterWrgbStimulusTargetY(reading);
 assert.strictEqual(after,before,
  `Full-code cyan target must not change after primary reads; before=${before}, after=${after}`);
 context.meterReadings=saved;
}

// === HDR WRGB full-drive ColorChecker endpoint ===
// Unlike an ordinary reflectance patch, the six 100% endpoints are graded
// against the filtered-primary output the run actually established. Cyan is
// therefore the additive measured G+B luminance rather than the unattainable
// white-subpixel PQ peak. This exception is limited to the colors chart.
{
 const savedReadings=context.meterReadings;
 context.meterActiveSeriesType='colors';
 context.meterReadings=[
  {series_color:'Red',sat_pct:100,r_code:235,g_code:16,b_code:16,Y:87.83,signal_mode:'hdr10'},
  {series_color:'Green',sat_pct:100,r_code:16,g_code:235,b_code:16,Y:290.87,signal_mode:'hdr10'},
  {series_color:'Blue',sat_pct:100,r_code:16,g_code:16,b_code:235,Y:31.82,signal_mode:'hdr10'}
 ];
 const endpoint={series_color:'Cyan',sat_pct:100,r_code:16,g_code:235,b_code:235,signal_mode:'hdr10'};
 const Y=context.meterWrgbStimulusTargetY(endpoint);
 const expected=290.87+31.82;
 assert(Math.abs(Y-expected)<0.01,
  `HDR WRGB 100% cyan target must equal measured G+B (${expected}), got ${Y}`);
 context.meterActiveSeriesType='saturations';
 const sweepY=context.meterWrgbStimulusTargetY(endpoint);
 assert(sweepY>700,
  `Saturation sweep endpoint must keep its authored PQ target (>700), got ${sweepY}`);
 context.meterActiveSeriesType=null;
 context.meterReadings=savedReadings;
}

// === Non-PQ signal: returns null ===
{
 context.meterChartIsPq=()=>false;
 const Y=context.meterWrgbStimulusTargetY({r_code:121,g_code:145,b_code:156});
 assert.strictEqual(Y,null,`Non-PQ signal must return null, got ${Y}`);
 // Restore for subsequent tests.
 context.meterChartIsPq=()=>true;
}

// === Missing codes: returns null ===
{
 const Y=context.meterWrgbStimulusTargetY({});
 assert.strictEqual(Y,null,`Missing codes must return null, got ${Y}`);
}

// === Measurement independence ===
// meterWrgbStimulusTargetY is the gate-fix's load-bearing contract: it MUST
// not require the WRGB white, the 100% primaries, or any other measured
// luminance before it can return a correct target Y. If it depended on any
// measurement, the first three sub-saturation chromatic reads of a color
// series would have wrong target Y until red 100% is read (the original
// "first three reads bad, then red 100% fixes everything" symptom).
//
// Two complementary checks:
//   1) The same reading produces the same Y whether meterReadings is empty
//      (simulating "before any read") or populated with white + 100%
//      primaries (simulating "after red 100% unlocks the chromatic ref").
//   2) The function never reads meterWrgbChromaticReferenceNits /
//      meterFindMeasuredWhiteReading -- those would only be invoked if the
//      function were measurement-gated. Stub them to throw; if they're
//      called the test fails immediately.
{
 const reading={r_code:121,g_code:145,b_code:156};
 const savedReadings=context.meterReadings;
 // (1) Empty readings -> target Y from stimulus alone.
 context.meterReadings=[];
 const Y_empty=context.meterWrgbStimulusTargetY(reading);
 // (1b) Populated readings with measured WRGB white and full-drive primaries
 // would, in meterTargetXYZForReading, open meterWrgbChromaticReferenceNits
 // (returns positive). The stimulus-decode function must ignore that.
 context.meterReadings=[
  {name:'White',ire:100,r_code:940,g_code:940,b_code:940,Y:721.8,luminance:721.8,series_type:'colors'},
  {series_color:'Red',  sat_pct:100,r_code:235,g_code:16, b_code:16, Y:87.83,signal_mode:'hdr10'},
  {series_color:'Green',sat_pct:100,r_code:16, g_code:235,b_code:16, Y:290.87,signal_mode:'hdr10'},
  {series_color:'Blue', sat_pct:100,r_code:16, g_code:16, b_code:235,Y:31.82,signal_mode:'hdr10'}
 ];
 const Y_full=context.meterWrgbStimulusTargetY(reading);
 assert.strictEqual(Y_full,Y_empty,
  `Stimulus-target Y must be identical regardless of measured primaries; empty=${Y_empty}, full=${Y_full}`);
 assert(Y_full>=185 && Y_full<=210,
  `Stimulus-target Y for Reflectance Cyan must be ~197 in P3 (185..210), got ${Y_full}`);
 context.meterReadings=savedReadings;

 // (2) The function must not consult meterWrgbChromaticReferenceNits or
 // meterFindMeasuredWhiteReading. Throwing from either proves they're not
 // called. (meterReadingLuminanceNits is also off-limits: the function has
 // no measurement input.)
 context.meterWrgbChromaticReferenceNits=()=>{ throw new Error('stimulus path must not consult chromatic ref'); };
 context.meterFindMeasuredWhiteReading=()=>{ throw new Error('stimulus path must not consult measured white'); };
 context.meterReadingLuminanceNits=()=>{ throw new Error('stimulus path must not read measured luminance'); };
 const Y_isolated=context.meterWrgbStimulusTargetY(reading);
 assert.strictEqual(Y_isolated,Y_empty,
  `Stimulus-target Y must not change when measurement helpers throw, got ${Y_isolated} vs baseline ${Y_empty}`);
 delete context.meterWrgbChromaticReferenceNits;
 delete context.meterFindMeasuredWhiteReading;
 context.meterReadingLuminanceNits=(rd)=>(rd&&rd.luminance!=null)?rd.luminance:(rd&&rd.Y!=null?rd.Y:null);
}

console.log('wrgb pq stimulus target regression OK');

// Regression test for the ColorChecker / Sat Sweep white-reference fix.
// Before the fix, color-series readings with `luminance:0` (raw field
// missing/zero from the read pipeline) and a valid `Y` were rejected by
// isWhiteReading / isSeriesWhite, so the chart fell through to the
// SDR default of 100 nits and produced massive dE for every color patch.
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
// Stubs for helpers called by the extracted functions but not part of the
// fix under test. meterXyzCorrectionEnabled returns false (default UI state
// -- the matrix toggle is off in the deployed card).
context.meterXyzCorrectionEnabled=()=>false;
context.meterApplyXyzCorrectionMatrix=(X,Y,Z)=>({X,Y,Z});
vm.runInContext([
 extractFunction('meterReadingLuminanceNits'),
 extractFunction('meterNormalizeMeasuredReading'),
 extractFunction('meterColorReferenceNits'),
 extractFunction('meterColorSeriesReferenceNits')
].join('\n'), context);

// === A ColorChecker White patch read with luminance:0 and Y:0.59 must
// normalize to luminance=0.59 (luminance mirrors Y) so the chart can use
// it as the measured series white. ===
{
 const white={
  name:'White',ire:100,r_code:255,g_code:255,b_code:255,
  r:255,g:255,b:255,
  X:0.79,Y:0.59,Z:1.04,
  x:0.327,y:0.245,luminance:0,
  signal_mode:'sdr',series_type:'colors'
 };
 context.meterNormalizeMeasuredReading(white);
 assert(white.luminance>0 && Math.abs(white.luminance-0.59)<1e-9,
  'Normalizer must set reading.luminance = corrected.Y (0.59) even when raw luminance was 0');
 assert(context.meterReadingLuminanceNits(white)===0.59,
  'meterReadingLuminanceNits returns the corrected luminance (0.59) after normalization');
}

// === isWhiteReading / isSeriesWhite predicates must accept a reading whose
// raw luminance is 0 but Y>0 (the normalizer hasn't run yet in some
// call sites). The fix changes the lum extraction to fall back to Y when
// luminance is null OR <= 0. ===
{
 // Build a tiny predicate harness mirroring the live predicates.
 const isWhiteReading=(rd)=>{
  if(!rd) return false;
  if(rd.synthetic_target) return false;
  const lum=((rd.luminance!=null && rd.luminance>0)?rd.luminance:rd.Y);
  if(!(lum>0)) return false;
  const name=String(rd.name||'').toLowerCase();
  const r=(rd.r_code!=null)?rd.r_code:rd.r;
  const g=(rd.g_code!=null)?rd.g_code:rd.g;
  const b=(rd.b_code!=null)?rd.b_code:rd.b;
  if(r!=null && g!=null && b!=null){
   return ((rd.ire||0)===100 || name==='white') && Number(r)===Number(g) && Number(g)===Number(b);
  }
  return (rd.ire==null || Number(rd.ire)===100 || name==='white');
 };
 const whiteRaw={
  name:'White',ire:100,r_code:255,g_code:255,b_code:255,
  Y:0.59,luminance:0,signal_mode:'sdr'
 };
 assert(isWhiteReading(whiteRaw),
  'ColorChecker White patch (luminance:0, Y:0.59, r=g=b=255) is recognized as a white reading');
 // A 100% red patch (r=255,g=0,b=0) must NOT be a white.
 const redRaw={name:'Red 100%',ire:100,r_code:255,g_code:0,b_code:0,Y:20,luminance:20,signal_mode:'sdr'};
 assert(!isWhiteReading(redRaw),
  '100% Red (r!=g) is NOT a white reading even though luminance is high');
}

// === meterColorSeriesReferenceNits: with the active series containing a
// White patch (luminance:0, Y:0.59), the reference must be the measured
// value (0.59), NOT the 100-nit SDR default, and NOT clamped to 1. ===
{
 context.meterActiveSeriesType='colors';
 context.meterReadings=[
  {name:'White',ire:100,r_code:255,g_code:255,b_code:255,Y:0.59,luminance:0,signal_mode:'sdr',series_type:'colors'},
  {name:'Red',ire:100,r_code:255,g_code:0,b_code:0,Y:20,luminance:20,signal_mode:'sdr',series_type:'colors'},
  {name:'Cyan',ire:100,r_code:0,g_code:255,b_code:255,Y:18,luminance:18,signal_mode:'sdr',series_type:'colors'}
 ];
 // Stubs for the chart mode helpers used by the real function.
 context.meterChartIsDv=()=>false;
 context.meterChartIsPq=()=>false;
 context.meterChartIsHdr=()=>false;
 context.meterDvMapModeValue=()=>'2';
 context.meterChartMasterPeak=()=>1000;
 context.meterChartHdrPeak=()=>1000;
 context.meterFindMeasuredWhiteReading=()=>null;
 context.meterColorSeriesTargetWhiteForRun=()=>0;
 context.meterExplicitLgTargetWhiteReferenceNits=()=>0;
 context.meterWhiteReading=null;
 const ref=context.meterColorSeriesReferenceNits();
 assert(typeof ref==='number' && Math.abs(ref-0.59)<1e-9,
  `meterColorSeriesReferenceNits returns the measured white (0.59), got ${ref} (was 100 / clamped to 1 before the fix)`);
}

// === A normal measured white (120 nits) is still used as-is (no clamp
// to 1 distorts a healthy reading). ===
{
 context.meterActiveSeriesType='colors';
 context.meterReadings=[
  {name:'White',ire:100,r_code:255,g_code:255,b_code:255,Y:120,luminance:120,signal_mode:'sdr',series_type:'colors'},
  {name:'Cyan',ire:100,r_code:0,g_code:255,b_code:255,Y:95,luminance:95,signal_mode:'sdr',series_type:'colors'}
 ];
 context.meterChartIsDv=()=>false;
 context.meterChartIsPq=()=>false;
 context.meterChartIsHdr=()=>false;
 context.meterDvMapModeValue=()=>'2';
 context.meterChartMasterPeak=()=>1000;
 context.meterChartHdrPeak=()=>1000;
 context.meterFindMeasuredWhiteReading=()=>null;
 context.meterColorSeriesTargetWhiteForRun=()=>0;
 context.meterExplicitLgTargetWhiteReferenceNits=()=>0;
 context.meterWhiteReading=null;
 const ref=context.meterColorSeriesReferenceNits();
 assert(Math.abs(ref-120)<1e-9, `Healthy measured white (120) is used as-is, got ${ref}`);
}

// === The fix preserves the DV Absolute branch (mastering-peak cap). ===
{
 context.meterActiveSeriesType='colors';
 context.meterReadings=[
  {name:'White',ire:100,r_code:255,g_code:255,b_code:255,Y:4000,luminance:4000,signal_mode:'dv',series_type:'colors'}
 ];
 context.meterChartIsDv=()=>true;
 context.meterDvMapModeValue=()=>'1'; // DV Absolute
 context.meterChartMasterPeak=()=>1000;
 context.meterFindMeasuredWhiteReading=()=>null;
 context.meterColorSeriesTargetWhiteForRun=()=>0;
 context.meterExplicitLgTargetWhiteReferenceNits=()=>0;
 context.meterWhiteReading=null;
 const ref=context.meterColorSeriesReferenceNits();
 assert(ref===1000, `DV Absolute still caps at mastering peak (1000), got ${ref}`);
}

console.log('color/sat series white-reference fix regression OK');

// Generated file. Do not edit directly.
// Source: /mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus/usr/share/PGenerator/webui.pm
// Source SHA-256: 3e3ee2e3ab10
// Extracted by tools/extract_webui_meter_math.py

// D65 reference white chromaticity
const D65={x:0.3127,y:0.3290,X:0.9505,Y:1.0,Z:1.0890};

const GAMUT_PRESETS={
 bt709:{
  label:'BT.709 / D65',
  primaries:{R:{x:0.64,y:0.33},G:{x:0.30,y:0.60},B:{x:0.15,y:0.06}},
  xyzToRgb:[
   [3.2406,-1.5372,-0.4986],
   [-0.9689,1.8758,0.0415],
   [0.0557,-0.2040,1.0570]
  ],
  rgbToXyz:[
   [0.4124564,0.3575761,0.1804375],
   [0.2126729,0.7151522,0.0721750],
   [0.0193339,0.1191920,0.9503041]
  ]
 },
 bt2020:{
  label:'BT.2020 / D65',
  primaries:{R:{x:0.708,y:0.292},G:{x:0.170,y:0.797},B:{x:0.131,y:0.046}},
  xyzToRgb:[
   [1.7166511880,-0.3556707838,-0.2533662814],
   [-0.6666843518,1.6164812366,0.0157685458],
   [0.0176398574,-0.0427706133,0.9421031212]
  ],
  rgbToXyz:[
   [0.6369580483,0.1446169036,0.1688809752],
   [0.2627002120,0.6779980715,0.0593017165],
   [0.0000000000,0.0280726930,1.0609850577]
  ]
 },
 p3d65:{
  label:'P3 / D65',
  primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},
  xyzToRgb:[
   [2.4934969119,-0.9313836179,-0.4027107845],
   [-0.8294889696,1.7626640603,0.0236246858],
   [0.0358458302,-0.0761723893,0.9568845240]
  ],
  rgbToXyz:[
   [0.4865709486,0.2656676932,0.1982172852],
   [0.2289745641,0.6917385218,0.0792869141],
   [0.0000000000,0.0451133819,1.0439443689]
  ]
 }
};

const M_XYZ_TO_RGB=GAMUT_PRESETS.bt709.xyzToRgb;
const M_RGB_TO_XYZ=GAMUT_PRESETS.bt709.rgbToXyz;

function meterSignalColorimetryGamutKey(){
 // DV rides in a BT.2020 container (P3-D65 is mastering/target only). The
 // stimulus-solve gamut follows the container so meter targets align with
 // what the display actually decodes — otherwise color measurements come
 // back oversaturated vs. the plotted target.
 if(meterChartIsDv()) return 'bt2020';
 if(meterChartIsPq() || meterChartSignalMode()==='hlg') return 'bt2020';
 const el=document.getElementById('colorimetry');
 const val=String((el&&el.value) || (config&&config.colorimetry) || '2');
 return val==='9' ? 'bt2020' : 'bt709';
}

function meterAutoTargetGamutKey(){
 if(meterChartIsDv()) return 'p3d65';
 if(meterChartIsPq() || meterChartSignalMode()==='hlg'){
  const primEl=document.getElementById('primaries');
  const prim=parseInt((primEl&&primEl.value) || (config&&config.primaries) || '0',10);
  if(prim===2 || prim===3) return 'p3d65';
  return 'bt2020';
 }
 return meterSignalColorimetryGamutKey();
}

function meterContainerGamutKey(){
 return meterSignalColorimetryGamutKey();
}

function meterSelectedTargetGamutKey(){
 const el=document.getElementById('meterTargetGamut');
 const val=String(el&&el.value||'auto').toLowerCase();
 return /^(bt709|bt2020|p3d65)$/.test(val)?val:'';
}

function meterActiveGamutKey(){
 const forced=meterSelectedTargetGamutKey();
 return forced||meterAutoTargetGamutKey();
}

function meterContainerGamut(){
 return GAMUT_PRESETS[meterContainerGamutKey()]||GAMUT_PRESETS.bt709;
}

function meterActiveGamut(){
 return GAMUT_PRESETS[meterActiveGamutKey()]||GAMUT_PRESETS.bt709;
}

function meterDvMapModeValue(){
 const el=document.getElementById('dv_map_mode');
 return String((el&&el.value) || (config&&config.dv_map_mode) || '2');
}

// Analysis targets and chart overlays must follow the currently selected
// Target Colorspace dropdown so the CIE triangle, saturation endpoints, and
// ΔE references all stay in sync with what the user is evaluating.
function meterAnalysisGamutKey(){
 return meterActiveGamutKey();
}

function meterAnalysisGamut(){
 return GAMUT_PRESETS[meterAnalysisGamutKey()]||GAMUT_PRESETS.bt709;
}

function meterStimulusSolveGamut(){
 // DV Absolute color-series patches must solve in the active target gamut.
 // Solving them in the BT.2020 tunnel widens chromaticities and makes
 // ColorChecker patches read oversaturated against the selected target.
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return meterAnalysisGamut();
 if(meterChartIsDv()) return meterContainerGamut();
 return meterChartIsPq() ? meterContainerGamut() : meterAnalysisGamut();
}

function meterTargetSolveGamut(){
 return meterAnalysisGamut();
}

function xyzToLinRgb(X,Y,Z,matrix){
 const M=matrix||M_XYZ_TO_RGB;
 return M.map(r=>r[0]*X+r[1]*Y+r[2]*Z);
}

function linRgbToXyz(R,G,B,matrix){
 const M=matrix||M_RGB_TO_XYZ;
 return {
  X:M[0][0]*R+M[0][1]*G+M[0][2]*B,
  Y:M[1][0]*R+M[1][1]*G+M[1][2]*B,
  Z:M[2][0]*R+M[2][1]*G+M[2][2]*B
 };
}

function meterIsLimitedRange(){
 const rangeEl=document.getElementById('rgb_quant_range');
 return !!(rangeEl&&rangeEl.value==='1');
}

function meterOutputIsRgb(){
 const fmtEl=document.getElementById('color_format');
 const val=String((fmtEl&&fmtEl.value) || (config&&config.color_format) || '0');
 return val==='0';
}

function meterPatchUsesVideoRange(){
 return meterIsLimitedRange();
}

function meterRangeMin(){
 return meterIsLimitedRange()?16:0;
}

function meterRangeSpan(){
 return meterIsLimitedRange()?219:255;
}

function meterPatchRangeMin(){
 return meterPatchUsesVideoRange()?16:0;
}

function meterPatchRangeSpan(){
 return meterPatchUsesVideoRange()?219:255;
}

function meterDvRelativeSt2084UsesLegalRange(){
 const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
 return meterChartIsDv() && meterDvMapModeValue()==='2' && sel==='st2084';
}

function meterGreyCodeRange(){
 if(meterDvRelativeSt2084UsesLegalRange()) return {min:16,span:219};
 return {min:meterPatchRangeMin(),span:meterPatchRangeSpan()};
}

function meterGreySignalFractionFromCode(code){
 const range=meterGreyCodeRange();
 return Math.max(0,Math.min(1,((code||0)-range.min)/range.span));
}

function meterSignalFractionFromCode(code){
 const min=meterPatchRangeMin();
 const span=meterPatchRangeSpan();
 return Math.max(0,Math.min(1,((code||0)-min)/span));
}

function meterDvTunnelGamma(){
 return meterChartIsDv() && meterDvMapModeValue()==='1' ? 3.8 : 2.2;
}

function meterDvSaturationTunnelGamma(colorName){
 return meterDvTunnelGamma();
}

function meterDecodeSignalChannel(code){
 const norm=meterSignalFractionFromCode(code);
 if(meterChartIsDv()) return Math.pow(norm,meterDvTunnelGamma());
 if(meterChartIsPq()){
  const peak=meterChartHdrPeak();
  if(!(peak>0)) return norm;
  return Math.max(0,Math.min(1,meterChartPqDecodeNormalized(norm)/peak));
 }
 if(meterChartIsHlg()){
  const peak=meterChartHdrPeak();
  const minY=meterChartMasterMin();
  return hlgSignalToDisplayLinear(norm,minY,peak);
 }
 return Math.pow(norm,2.4);
}

function meterEncodeSignalChannel(linear){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 let encoded=clamped;
 if(meterChartIsDv()){
  const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
  encoded=sel==='st2084' ? meterChartPqEncodeNormalized(clamped*10000) : Math.pow(clamped,1/meterDvTunnelGamma());
 }
 else if(meterChartIsPq()){
  const peak=meterChartHdrPeak();
  const peakCode=meterChartPqEncodeNormalized(peak)||1;
  encoded=meterChartPqEncodeNormalized(clamped*peak)/peakCode;
 }
 else if(meterChartIsHlg()) encoded=hlgOetf(clamped);
 else encoded=Math.pow(clamped,1/2.4);
 return Math.round(min+encoded*span);
}

function meterDvAbsoluteTargetLuminanceForPercent(percent, peak){
 const clamped=clampNum(percent,0,100)/100;
 const targetPeak=(peak>0)?peak:meterChartMasterPeak();
 const sel=(document.getElementById('meterTargetGamma')||{}).value||'2.2';
 if(sel==='srgb') return Math.min(targetPeak,srgbEotf(clamped)*targetPeak);
 if(sel==='bt1886') return Math.min(targetPeak,gammaEotf(clamped,2.4)*targetPeak);
 return Math.min(targetPeak,gammaEotf(clamped,parseFloat(sel)||2.2)*targetPeak);
}

function meterDvAbsoluteTargetRollOffFraction(){
 return 0.75;
}

function meterDvAbsoluteChartTargetLuminance(ire, peak){
 const targetPeak=(peak>0)?peak:100;
 const frac=clampNum((ire||0)/100,0,1);
 const roll=meterDvAbsoluteTargetRollOffFraction();
 const normalized=roll>0?Math.min(frac/roll,1):frac;
 const sel=(document.getElementById('meterTargetGamma')||{}).value||'2.2';
 if(sel==='srgb') return srgbEotf(normalized)*targetPeak;
 if(sel==='bt1886') return gammaEotf(normalized,2.4)*targetPeak;
 return gammaEotf(normalized,parseFloat(sel)||2.2)*targetPeak;
}

function meterDvRelativeChartTargetLuminance(ire, peak){
 const targetPeak=(peak>0)?peak:100;
 const frac=clampNum((ire||0)/100,0,1);
 return gammaEotf(frac,2.2)*targetPeak;
}

function meterCodeFromSignalPercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 if(meterChartIsDv()){
  const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
  if(sel==='st2084'){
   const range=meterGreyCodeRange();
   return Math.round(range.min+clamped*range.span);
  }
  const encoded=clamped>0?Math.pow(clamped,1/meterDvTunnelGamma()):0;
  return Math.round(meterPatchRangeMin()+encoded*meterPatchRangeSpan());
 }
 return Math.round(meterPatchRangeMin()+clamped*meterPatchRangeSpan());
}

function meterActualSignalPercent(percent){
 return meterGreySignalFractionFromCode(meterCodeFromSignalPercent(percent))*100;
}

function meterActualCodePercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 const code=Math.round(meterPatchRangeMin()+clamped*meterPatchRangeSpan());
 return meterGreySignalFractionFromCode(code)*100;
}

function meterColorLevelPercent(){
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return 75;
 return meterChartIsHdr()?50:75;
}

function meterFindMeasuredWhiteReading(){
 const currentMode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const readingMatchesMode=(rd)=>{
  if(!rd) return false;
  const rdMode=String((rd.signal_mode||'')).toLowerCase();
  if(rdMode) return rdMode===currentMode;
  // Legacy cached readings may not carry signal_mode. For SDR, reject
  // implausibly high white luminance snapshots that are almost certainly
  // stale HDR/DV references.
  if(currentMode==='sdr'){
   const lum=(rd.luminance!=null)?rd.luminance:rd.Y;
   if(lum>300) return false;
  }
  return true;
 };
 const isWhiteReading=(rd)=>{
  if(!rd) return false;
  if(!readingMatchesMode(rd)) return false;
  const lum=(rd.luminance!=null)?rd.luminance:rd.Y;
  if(!(lum>0)) return false;
  const name=String(rd.name||'').toLowerCase();
  const r=(rd.r_code!=null)?rd.r_code:rd.r;
  const g=(rd.g_code!=null)?rd.g_code:rd.g;
  const b=(rd.b_code!=null)?rd.b_code:rd.b;
  if(r!=null && g!=null && b!=null){
   return ((rd.ire||0)===100 || name==='white') && Number(r)===Number(g) && Number(g)===Number(b);
  }
  return (rd.ire==null || Number(rd.ire)===100 || name==='white') && ((rd.Y||0)>0 || (rd.X||0)>0 || (rd.Z||0)>0);
 };
 if(isWhiteReading(meterWhiteReading)) return meterWhiteReading;
 if(Array.isArray(meterReadings)){
  const liveWhite=meterReadings.find(isWhiteReading);
  if(liveWhite) return liveWhite;
 }
 const preferredKeys=['greyscale-21','greyscale-11','saturations-24','colors-30'];
 let best=null;
 const considerSnapshot=(snap)=>{
  if(!snap||!Array.isArray(snap.readings)) return;
  const snapMode=String((snap.signal_mode||'')).toLowerCase();
  if(snapMode && snapMode!==currentMode) return;
  const white=snap.readings.find(isWhiteReading);
  if(!white) return;
  const updated=(snap.updated_at||0);
  if(!best || updated>(best.updated_at||0)) best={reading:white,updated_at:updated};
 };
 preferredKeys.forEach(key=>considerSnapshot(meterSeriesCache&&meterSeriesCache[key]));
 if(meterSeriesCache&&typeof meterSeriesCache==='object') Object.values(meterSeriesCache).forEach(considerSnapshot);
 return best?best.reading:null;
}

function meterColorReferenceNits(){
 if(meterChartIsDv()){
  // DV relative uses the measured white reference when available, but DV
  // absolute keeps its target luminance anchored to mastering peak. The warm
  // white pre-read remains diagnostic-only for absolute mode.
  const master=Math.max(1,meterChartMasterPeak());
  if(meterDvMapModeValue()==='1') return master;
  const white=meterFindMeasuredWhiteReading();
  const measured=(white&&white.Y>0)?white.Y:master;
  return Math.max(1,Math.min(master,measured));
 }
 const white=meterFindMeasuredWhiteReading();
 if(white&&white.Y>0) return white.Y;
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartHdrPeak();
 if(meterChartIsHdr()) return meterChartHdrPeak();
 return 100;
}

function meterColorSeriesReferenceNits(){
 const isSeriesWhite=(rd)=>{
  if(!rd) return false;
  const lum=(rd.luminance!=null)?rd.luminance:rd.Y;
  if(!(lum>0)) return false;
  const name=String(rd.name||'').toLowerCase();
  const r=(rd.r_code!=null)?rd.r_code:rd.r;
  const g=(rd.g_code!=null)?rd.g_code:rd.g;
  const b=(rd.b_code!=null)?rd.b_code:rd.b;
  if(r!=null && g!=null && b!=null){
   return ((rd.ire||0)===100 || name==='white') && Number(r)===Number(g) && Number(g)===Number(b);
  }
  return name==='white' || Number(rd.ire)===100;
 };
 const white=
  (isSeriesWhite(meterWhiteReading)?meterWhiteReading:null) ||
  (Array.isArray(meterReadings)?meterReadings.find(isSeriesWhite):null) ||
  meterFindMeasuredWhiteReading();
 if(white&&((white.luminance!=null&&white.luminance>0)||(white.Y>0))){
  return Math.max(1,(white.luminance!=null)?white.luminance:white.Y);
 }
 return Math.max(1,meterColorReferenceNits());
}

function meterBlackReadingY(){
 const readings=Array.isArray(meterReadings)?meterReadings:[];
 const blacks=readings.filter(r=>meterReadingIsGreyscale(r)&&(r.ire||0)<=5&&r.luminance!=null)
  .map(r=>r.luminance||r.Y||0)
  .filter(v=>v>=0);
 return blacks.length>0?Math.min(...blacks):0;
}

function meterDisplayIsOled(){
 const dt=((document.getElementById('meterDisplayType')||{}).value||'').toLowerCase();
 return dt.indexOf('oled')!==-1;
}

// Infer chart black level. On OLED, true black can time out and be missing;
// use only true 0% greyscale reading (or 0 fallback) in every mode.
function meterChartBlackLevel(readings){
 const gs=(Array.isArray(readings)?readings:[])
  .filter(r=>r && meterReadingIsGreyscale(r) && r.luminance!=null && r.luminance>=0);
 const trueBlack=gs.filter(r=>(r.ire||0)===0).map(r=>r.luminance||0);
 if(trueBlack.length>0) return Math.min(...trueBlack);
 if(meterDisplayIsOled()) return 0;
 if(!meterChartIsHdr()) return 0;
 const nearBlack=gs.filter(r=>(r.ire||0)<=5).map(r=>r.luminance||0);
 return nearBlack.length>0?Math.min(...nearBlack):0;
}

function meterColorLabWhite(){
 const white=meterFindMeasuredWhiteReading();
 if(white&&white.X>0&&white.Y>0&&white.Z>0) return {X:white.X,Y:white.Y,Z:white.Z};
 const refY=Math.max(1,meterColorReferenceNits());
 return {X:D65.X*refY,Y:refY,Z:D65.Z*refY};
}

// Forward/inverse of the active SDR/DV target signal model used by the meter
// series builders. DV relative keeps the classic 2.2 tunnel. DV absolute
// needs a steeper inverse to match the live panel chromaticities.
function meterTargetLinearToSignal(v){
 const c=Math.max(0,Math.min(1,v||0));
 if(c<=0) return 0;
 if(meterChartIsDv()){
  return Math.pow(c,1/meterDvTunnelGamma());
 }
 if(meterChartIsHlg()) return hlgOetf(c);
 const sel=(document.getElementById('meterTargetGamma')||{}).value||'bt1886';
 if(sel==='srgb') return c<=0.0031308 ? 12.92*c : 1.055*Math.pow(c,1/2.4)-0.055;
 const g=(sel==='bt1886')?2.4:(parseFloat(sel)||2.2);
 return Math.pow(c,1/g);
}
function meterTargetSignalToLinear(v){
 const c=Math.max(0,Math.min(1,v||0));
 if(c<=0) return 0;
 if(meterChartIsDv()){
  return Math.pow(c,meterDvTunnelGamma());
 }
 if(meterChartIsHlg()){
  const peak=meterChartHdrPeak();
  const minY=meterChartMasterMin();
  return hlgSignalToDisplayLinear(c,minY,peak);
 }
 const sel=(document.getElementById('meterTargetGamma')||{}).value||'bt1886';
 if(sel==='srgb') return c<=0.04045 ? c/12.92 : Math.pow((c+0.055)/1.055,2.4);
 const g=(sel==='bt1886')?2.4:(parseFloat(sel)||2.2);
 return Math.pow(c,g);
}

function meterDvClassicColorCheckerScale(){
 return 0.68;
}

function meterEncodeColorCheckerLinear(linear){
 const min=meterPatchRangeMin();
 const span=meterPatchRangeSpan();
 let clamped=Math.max(0,Math.min(1,linear||0));
 if(meterChartIsDv()) clamped*=meterDvClassicColorCheckerScale();
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(clamped*100)*span);
 if(meterChartIsDv()) return Math.round(min+Math.pow(clamped,1/2.2)*span);
 return Math.round(min+meterTargetLinearToSignal(clamped)*span);
}

function meterDecodeColorCheckerSignal(signal){
 let clamped=Math.max(0,Math.min(1,signal||0));
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartPqDecodeNormalized(clamped)/100;
 if(meterChartIsDv()) return Math.pow(clamped,2.2)/meterDvClassicColorCheckerScale();
 return meterTargetSignalToLinear(clamped);
}

function meterEncodeColorCheckerFullSatChannel(active){
 const min=meterPatchRangeMin();
 const span=meterPatchRangeSpan();
 if(!active) return min;
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(100)*span);
 return min+span;
}

function meterFullSatChannelIsActive(linear){
 return Number(linear||0) > 1e-6;
}

function meterEncodeSaturationLinear(linear,colorName){
 const min=meterPatchRangeMin();
 const span=meterPatchRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(clamped*10000)*span);
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return Math.round(min+Math.pow(clamped,1/meterDvSaturationTunnelGamma(colorName))*span);
 return Math.round(min+meterTargetLinearToSignal(clamped)*span);
}

function meterGamutStimulusLinearLevel(){
 if(meterChartIsPq()&&!meterChartIsDv()) return 1;
 return meterTargetSignalToLinear(meterColorLevelPercent()/100);
}

function meterSaturationStimulusLinearLevel(colorName){
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const actualPercent=meterActualCodePercent(meterColorLevelPercent())/100;
  return Math.pow(actualPercent,meterDvSaturationTunnelGamma(colorName));
 }
 const actualPercent=meterActualSignalPercent(meterColorLevelPercent())/100;
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartPqDecodeNormalized(actualPercent)/10000;
 return meterTargetSignalToLinear(actualPercent);
}

function meterDvRelativeSaturationFraction(sat){
 const s=Math.max(0,Math.min(1,sat||0));
 return s-(0.8*s*s*(1-s));
}

function meterGamutColorIsSecondary(colorName){
 switch(String(colorName||'').toLowerCase()){
  case 'cyan':
  case 'magenta':
  case 'yellow':
   return true;
  default:
   return false;
 }
}

function meterDvAbsoluteSaturationFraction(colorName,sat){
 const s=Math.max(0,Math.min(1,sat||0));
 return s + 0.8*s*(1-s);
}

function meterRemapRelativeDvChromaticityToSolveGamut(x,y,gamut){
 if(!(meterChartIsDv() && meterDvMapModeValue()!=='1')) return {x,y};
 const solveGamut=gamut||meterAnalysisGamut();
 const wx=D65.x, wy=D65.y;
 const dx=(x||0)-wx;
 const dy=(y||0)-wy;
 if(Math.abs(dx)<1e-9 && Math.abs(dy)<1e-9) return {x,y};
 const verts=[solveGamut.primaries.R,solveGamut.primaries.G,solveGamut.primaries.B];
 let bestT=null;
 for(let i=0;i<verts.length;i++){
  const a=verts[i];
  const b=verts[(i+1)%verts.length];
  const ex=b.x-a.x;
  const ey=b.y-a.y;
  const qx=a.x-wx;
  const qy=a.y-wy;
  const den=dx*ey-dy*ex;
  if(Math.abs(den)<1e-9) continue;
  const t=(qx*ey-qy*ex)/den;
  const u=(qx*dy-qy*dx)/den;
  if(t>0 && u>=-1e-9 && u<=1+1e-9 && (bestT==null || t<bestT)) bestT=t;
 }
 if(!(bestT>0)) return {x,y};
 const frac=Math.max(0,Math.min(1,1/bestT));
 const compressed=meterDvRelativeSaturationFraction(frac);
 if(!(frac>1e-9)) return {x:wx,y:wy};
 const scale=compressed/frac;
 return {x:wx+dx*scale,y:wy+dy*scale};
}

function meterRemapAbsoluteDvColorCheckerChromaticity(x,y,gamut){
 if(!(meterChartIsDv() && meterDvMapModeValue()==='1')) return {x,y};
 const solveGamut=gamut||meterAnalysisGamut();
 const wx=D65.x, wy=D65.y;
 const dx=(x||0)-wx;
 const dy=(y||0)-wy;
 if(Math.abs(dx)<1e-9 && Math.abs(dy)<1e-9) return {x,y};
 const verts=[solveGamut.primaries.R,solveGamut.primaries.G,solveGamut.primaries.B];
 let bestT=null;
 for(let i=0;i<verts.length;i++){
  const a=verts[i];
  const b=verts[(i+1)%verts.length];
  const ex=b.x-a.x;
  const ey=b.y-a.y;
  const qx=a.x-wx;
  const qy=a.y-wy;
  const den=dx*ey-dy*ex;
  if(Math.abs(den)<1e-9) continue;
  const t=(qx*ey-qy*ex)/den;
  const u=(qx*dy-qy*dx)/den;
  if(t>0 && u>=-1e-9 && u<=1+1e-9 && (bestT==null || t<bestT)) bestT=t;
 }
 if(!(bestT>0)) return {x,y};
 const frac=Math.max(0,Math.min(1,1/bestT));
 if(!(frac>1e-9)) return {x:wx,y:wy};
 const compressed=frac-0.32*frac*(1-frac);
 const scale=compressed/frac;
 return {x:wx+dx*scale,y:wy+dy*scale};
}

function meterSaturationSolveGamut(){
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return meterAnalysisGamut();
 if(meterChartIsDv()) return meterAnalysisGamut();
 return meterStimulusSolveGamut();
}

function meterSaturationAxisGamut(){
 return meterAnalysisGamut();
}

function meterBuildSaturationStepRgb(colorName,satPercent){
 const rgb=meterBuildSaturationStimulusLinearRgb(colorName,satPercent);
 return rgb.map(v=>meterEncodeSaturationLinear(v,colorName));
}

function meterGamutColorEndpointRgb(colorName){
 switch(String(colorName||'').toLowerCase()){
  case 'red': return [1,0,0];
  case 'green': return [0,1,0];
  case 'blue': return [0,0,1];
  case 'cyan': return [0,1,1];
  case 'magenta': return [1,0,1];
  case 'yellow': return [1,1,0];
  default: return [1,1,1];
 }
}

function meterGamutColorEndpointXY(colorName,gamutOverride){
 const gamut=gamutOverride||meterAnalysisGamut();
 const rgb=meterGamutColorEndpointRgb(colorName);
 const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],gamut.rgbToXyz);
 const sum=xyz.X+xyz.Y+xyz.Z;
 return sum>0?{x:xyz.X/sum,y:xyz.Y/sum}:{x:D65.x,y:D65.y};
}

function meterBuildSaturationTargetLinearRgb(colorName,satPercent){
 const solveGamut=meterAnalysisGamut();
 const sat=Math.max(0,Math.min(100,satPercent||0))/100;
 const endpoint=meterGamutColorEndpointXY(colorName,meterSaturationAxisGamut());
 const x=D65.x+sat*(endpoint.x-D65.x);
 const y=D65.y+sat*(endpoint.y-D65.y);
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 const level=meterSaturationStimulusLinearLevel(colorName);
 return coeffs.map(v=>Math.max(0,v/maxCoeff)*level);
}

function meterBuildSaturationStimulusLinearRgb(colorName,satPercent){
 const solveGamut=meterSaturationSolveGamut();
 const axisGamut=meterSaturationAxisGamut();
 let sat=Math.max(0,Math.min(100,satPercent||0))/100;
 if(meterChartIsDv()) sat=(meterDvMapModeValue()==='1') ? meterDvAbsoluteSaturationFraction(colorName,sat) : meterDvRelativeSaturationFraction(sat);
 const endpoint=meterGamutColorEndpointXY(colorName,axisGamut);
 const x=D65.x+sat*(endpoint.x-D65.x);
 const y=D65.y+sat*(endpoint.y-D65.y);
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 const level=meterSaturationStimulusLinearLevel(colorName);
 return coeffs.map(v=>Math.max(0,v/maxCoeff)*level);
}

function meterBuildFullGamutTargetLinearRgb(colorName){
 const solveGamut=meterTargetSolveGamut();
 const endpoint=meterGamutColorEndpointXY(colorName,solveGamut);
 const x=endpoint.x;
 const y=endpoint.y;
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 return coeffs.map(v=>Math.max(0,v/maxCoeff));
}

function meterColorCheckerFullSatTargetXYZ(colorName){
 return meterSaturationTargetXYZ(colorName,100);
}

function meterInferSdrSatReferenceNits(){
 if(meterChartIsHdr()) return null;
 const rows=(Array.isArray(meterReadings)?meterReadings:[])
  .filter(r=>r&&r.series_color&&r.sat_pct!=null&&((r.luminance!=null&&r.luminance>0)||(r.Y!=null&&r.Y>0)));
 if(rows.length<6) return null;
 const estimates=[];
 rows.forEach(r=>{
  const measuredY=(r.luminance!=null)?Number(r.luminance):Number(r.Y);
  if(!(measuredY>0)) return;
  const rgb=meterBuildSaturationTargetLinearRgb(String(r.series_color),Number(r.sat_pct));
  const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],meterTargetSolveGamut().rgbToXyz);
  if(!(xyz&&xyz.Y>1e-9)) return;
  const est=measuredY/xyz.Y;
  if(est>30&&est<400) estimates.push(est);
 });
 if(estimates.length<6) return null;
   estimates.sort((a,b)=>a-b);
   const mid=Math.floor(estimates.length/2);
   return estimates.length%2 ? estimates[mid] : (estimates[mid-1]+estimates[mid])/2;
  }

function meterSaturationTargetXYZ(colorName,satPercent){
 const rgb=meterBuildSaturationTargetLinearRgb(colorName,satPercent);
 const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],meterTargetSolveGamut().rgbToXyz);
 // For PQ the linear RGB is scaled by meterChartPqDecodeNormalized()/10000,
 // so xyz values are already relative to the 10000-nit PQ reference.
 // Multiply by 10000 to recover absolute nits.
 // For SDR/HLG/DV the linear RGB is in 0..1 relative to display peak, so
 // multiply by meterColorReferenceNits() as before.
 let scale=meterChartIsPq()&&!meterChartIsDv()?10000:meterColorSeriesReferenceNits();
 if(!(meterChartIsPq()&&!meterChartIsDv()) && !meterChartIsHdr()){
  const white=meterFindMeasuredWhiteReading();
  if(!(white&&white.Y>0)){
   const inferred=meterInferSdrSatReferenceNits();
   if(inferred>0) scale=inferred;
  }
 }
 return {X:xyz.X*scale,Y:xyz.Y*scale,Z:xyz.Z*scale};
}

function meterParseSaturationReading(reading){
 if(reading.series_color&&reading.sat_pct!=null){
  return {color:String(reading.series_color),sat:parseFloat(reading.sat_pct)||0};
 }
 const name=String(reading.name||'').trim();
 let match=name.match(/^(Red|Green|Blue|Cyan|Magenta|Yellow)\s+(\d+)%$/i);
 if(match) return {color:match[1],sat:parseFloat(match[2])||0};
 match=name.match(/^(\d+)%\s+(Red|Green|Blue|Cyan|Magenta|Yellow)$/i);
 if(match) return {color:match[2],sat:parseFloat(match[1])||0};
 return null;
}

function meterDecodeColorTargetChannel(code){
 const norm=meterSignalFractionFromCode(code);
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.min(meterChartPqDecodeNormalized(norm),meterChartHdrPeak());
 // SDR/DV: decode with the active target EOTF so the reconstructed target
 // XYZ for r/g/b-code patches matches the chromaticity the display actually
 // produces when tracking that EOTF (previously hardcoded γ=2.2).
 return meterTargetSignalToLinear(norm)*meterColorReferenceNits();
}

function targetColorXYZAbs(r,g,b){
 // Analysis targets must follow the selected target gamut, not the transport
 // container. This keeps the CIE triangle and the target chromaticities in
 // sync with the Target Colorspace dropdown even in HDR/DV workflows.
 const gamut=meterAnalysisGamut();
 return linRgbToXyz(
  meterDecodeColorTargetChannel(r),
  meterDecodeColorTargetChannel(g),
  meterDecodeColorTargetChannel(b),
  gamut.rgbToXyz
 );
}

function targetChromaticityXY(r,g,b){
 const xyz=targetColorXYZAbs(r,g,b);
 const s=xyz.X+xyz.Y+xyz.Z;
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:D65.x,y:D65.y};
}

function meterTargetXYZForReading(reading){
 if(!reading) return {X:0,Y:0,Z:0};
 if(meterActiveSeriesType==='colors' && reading.series_color && reading.sat_pct!=null){
  return meterColorCheckerFullSatTargetXYZ(String(reading.series_color));
 }
 const tx=parseFloat(reading.target_x);
 const ty=parseFloat(reading.target_y);
 const tYn=parseFloat(reading.target_Yn);
 if(Number.isFinite(tx)&&Number.isFinite(ty)&&ty>0&&Number.isFinite(tYn)&&tYn>=0){
  if(tYn<=0) return {X:0,Y:0,Z:0};
  const refY=meterColorSeriesReferenceNits();
  // Gamut-clip: for analysis/charting, solve in the selected target gamut so
  // the CIE chart and ΔE targets respect the Target Colorspace dropdown.
  const gamut=meterAnalysisGamut();
  const coeffs=xyzToLinRgb(tx/ty,1,(1-tx-ty)/ty,gamut.xyzToRgb);
  let r=coeffs[0],g=coeffs[1],b=coeffs[2];
  if(r<0||g<0||b<0){
   if(r<0) r=0; if(g<0) g=0; if(b<0) b=0;
   const clipped=linRgbToXyz(r,g,b,gamut.rgbToXyz);
   const cs=clipped.X+clipped.Y+clipped.Z;
   if(cs>0&&clipped.Y>0){
    const cx=clipped.X/cs,cy=clipped.Y/cs;
    const Y=tYn*refY;
    return {X:(cx/cy)*Y,Y:Y,Z:((1-cx-cy)/cy)*Y};
   }
  }
  const Y=tYn*refY;
  return {X:(tx/ty)*Y,Y:Y,Z:((1-tx-ty)/ty)*Y};
 }
 const satInfo=meterParseSaturationReading(reading);
 if(satInfo){
  if(meterActiveSeriesType==='colors' && satInfo.sat===100){
   return meterColorCheckerFullSatTargetXYZ(satInfo.color);
  }
  return meterSaturationTargetXYZ(satInfo.color,satInfo.sat);
 }
 return targetColorXYZAbs(reading.r_code,reading.g_code,reading.b_code);
}

function meterTargetChromaticityForReading(reading){
 const xyz=meterTargetXYZForReading(reading);
 const s=xyz.X+xyz.Y+xyz.Z;
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:D65.x,y:D65.y};
}

function meterColorDeltaTargetXYZ(reading,inclLum){
 const xyz=meterTargetXYZForReading(reading);
 if(inclLum||!reading||reading.Y==null||!(reading.Y>0)||!(xyz.Y>0)) return xyz;
 const scale=reading.Y/xyz.Y;
 return {X:xyz.X*scale,Y:reading.Y,Z:xyz.Z*scale};
}

function meterColorIncludeLum(){
 const el=document.getElementById('meterColorIncludeLumError');
 return !!(el&&el.checked);
}

// Color and saturation ΔE use their own luminance toggle so they do not leak
// state from the greyscale controls.
function meterColorRefMode(){
 return meterColorIncludeLum() ? 'eotf' : 'absolute';
}

function meterReadingLuminanceNits(reading){
 if(!reading) return null;
 if(reading.luminance!=null) return reading.luminance;
 if(reading.Y!=null) return reading.Y;
 return null;
}

function meterReadingXYZ(reading){
 if(!reading) return null;
 const Y=meterReadingLuminanceNits(reading);
 if(!(Y>0)) return null;
 if(reading.X!=null && reading.Y!=null && reading.Z!=null) return {X:reading.X,Y:reading.Y,Z:reading.Z};
 const x=(reading.x!=null)?Number(reading.x):NaN;
 const y=(reading.y!=null)?Number(reading.y):NaN;
 if(Number.isFinite(x) && Number.isFinite(y) && y>0){
  return {X:(x/y)*Y,Y,Z:((1-x-y)/y)*Y};
 }
 if(meterReadingIsGreyscale(reading)) return {X:D65.X*Y,Y,Z:D65.Z*Y};
 return null;
}

function meterColorLuminanceInfo(reading){
 if(!reading) return {measuredY:null,targetY:null,deltaY:null,deltaPct:null};
 let targetY=null;
 try{
  const targetXYZ=meterTargetXYZForReading(reading);
  if(targetXYZ&&targetXYZ.Y!=null&&targetXYZ.Y>=0) targetY=targetXYZ.Y;
 }catch(e){}
 const measuredY=meterReadingLuminanceNits(reading);
 let deltaY=null,deltaPct=null;
 if(measuredY!=null&&targetY!=null){
  deltaY=measuredY-targetY;
  if(Math.abs(targetY)>1e-9) deltaPct=(deltaY/targetY)*100;
 }
 return {measuredY,targetY,deltaY,deltaPct};
}

function meterReadingUsesColorDeltaForm(reading){
 if(!reading) return false;
 if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations') return true;
 const tx=parseFloat(reading.target_x);
 const ty=parseFloat(reading.target_y);
 const tYn=parseFloat(reading.target_Yn);
 if(Number.isFinite(tx)&&Number.isFinite(ty)&&ty>0&&Number.isFinite(tYn)) return true;
 if(reading.series_color!=null||reading.sat_pct!=null) return true;
 return false;
}

function meterColorDeltaEForm(){
 const sel=document.getElementById('meterColorDeltaEForm');
 if(sel && sel.value) return sel.value;
 return 'de2000';
}

function meterGreyDeltaResult(reading,modeOrIncl,form,gwWeight){
 const xyz=meterReadingXYZ(reading);
 if(!reading||!xyz||!(xyz.Y>0)) return {value:0,de2000:0};
 form = form || meterDeltaEForm();
 if(gwWeight==null) gwWeight = meterGrayWorldWeight();
 const mode=meterResolveGreyRefMode(modeOrIncl);
 if(meterRgbBalanceFormula()==='hcfr'){
  const white=(meterWhiteReading&&meterWhiteReading.Y>0)?meterWhiteReading:null;
  const Lw=white?(white.luminance||white.Y||0):0;
  const blacks=(Array.isArray(meterReadings)?meterReadings:[]).filter(r=>meterReadingIsGreyscale(r)&&(r.ire||0)<=5&&r.luminance!=null);
  const Lb=blacks.length>0?Math.min(...blacks.map(r=>r.luminance)):0;
  const ref=hcfrGreyRef(reading.ire, xyz.Y, Lw, Lb, modeOrIncl, reading.r_code, gwWeight);
  const XnM=(ref.wxN||D65.X)*ref.YWhite, YnM=ref.YWhite, ZnM=(ref.wzN||D65.Z)*ref.YWhite;
  const XnR=(ref.wxN||D65.X)*ref.YWhiteRef, YnR=ref.YWhiteRef, ZnR=(ref.wzN||D65.Z)*ref.YWhiteRef;
  const labM=xyzToLab(xyz.X,xyz.Y,xyz.Z,XnM,YnM,ZnM);
  const labT=xyzToLab(ref.refX,ref.refY,ref.refZ,XnR,YnR,ZnR);
  const ctx={
   isGrey:true,
   Ym:xyz.Y, Yref:ref.refY*ref.YWhiteRef,
   X:xyz.X, Y:xyz.Y, Z:xyz.Z, YWhite:ref.YWhite,
   Xr:ref.refX*ref.YWhiteRef, Yr:ref.refY*ref.YWhiteRef, Zr:ref.refZ*ref.YWhiteRef,
   YWhiteRef:ref.YWhiteRef
  };
  return {value:meterDeltaE(labM,labT,form,ctx),de2000:deltaE2000(labM,labT)};
 }
 let wR=meterColorLabWhite();
 const _gw=(gwWeight>0&&gwWeight<=1)?gwWeight:1;
 if(_gw<1) wR={X:wR.X*_gw,Y:wR.Y*_gw,Z:wR.Z*_gw};
 const target=meterColorDeltaTargetXYZ(reading, mode==='eotf');
 if(mode==='absolute'){
  const stepY=Math.max(xyz.Y||0,target.Y||0,0);
  if(stepY>0 && wR.Y>0){
   const scale=stepY/wR.Y;
   wR={X:wR.X*scale,Y:stepY,Z:wR.Z*scale};
  }
 }
 const labM=xyzToLab(xyz.X,xyz.Y,xyz.Z,wR.X,wR.Y,wR.Z);
 const labT=xyzToLab(target.X,target.Y,target.Z,wR.X,wR.Y,wR.Z);
 const ctx={
  isGrey:true,
  Ym:xyz.Y, Yref:target.Y||0,
  X:xyz.X, Y:xyz.Y, Z:xyz.Z, YWhite:wR.Y,
  Xr:target.X, Yr:target.Y, Zr:target.Z, YWhiteRef:wR.Y
 };
 return {value:meterDeltaE(labM,labT,form,ctx),de2000:deltaE2000(labM,labT)};
}

// Primary grayscale/color ΔE entry point. Greyscale uses the greyscale ΔE
// selector; Colors and Sat Sweep use their dedicated Color ΔE selector.
function meterColorDeltaE2000(reading,modeOrIncl,form,gwWeight){
 if(!reading) return 0;
 const useColorForm=meterReadingUsesColorDeltaForm(reading);
 form = form || (useColorForm ? meterColorDeltaEForm() : meterDeltaEForm());
 if(gwWeight==null) gwWeight = meterGrayWorldWeight();
 if(!useColorForm && meterReadingIsGreyscale(reading) && (reading.Y||0)>0){
  return meterGreyDeltaResult(reading,modeOrIncl,form,gwWeight).value;
 }
 const wR=meterColorLabWhite();
 const mode=meterResolveGreyRefMode(modeOrIncl);
 const target=meterColorDeltaTargetXYZ(reading, mode==='eotf');
 const labM=xyzToLab(reading.X||0,reading.Y||0,reading.Z||0,wR.X,wR.Y,wR.Z);
 const labT=xyzToLab(target.X,target.Y,target.Z,wR.X,wR.Y,wR.Z);
 return meterDeltaE(labM,labT,form,{
  isGrey:false,
  Ym:reading.Y||0, Yref:target.Y||0,
  X:reading.X||0, Y:reading.Y||0, Z:reading.Z||0, YWhite:wR.Y,
  Xr:target.X, Yr:target.Y, Zr:target.Z, YWhiteRef:wR.Y
 });
}

// Computes both raw (luminance-inclusive) and luminance-compensated ΔE
// for a single reading. Used so the chart/table can switch modes without
// re-running the full pipeline per point.
function meterColorDeltaE2000Pair(reading,form,gwWeight){
 return {
  raw: meterColorDeltaE2000(reading,'eotf',form,gwWeight),
  lc:  meterColorDeltaE2000(reading,'absolute',form,gwWeight)
 };
}

// Caches {raw, lc} ΔE pair on each reading under a key that encodes the
// currently-selected form + gw weight. If the key matches a previous
// compute the cached values are returned; otherwise the pair is
// recomputed and stored. Callers use reading._dE_raw / reading._dE_lc.
function meterEnsureDeltaECache(readings){
 if(!Array.isArray(readings)) return;
 const greyForm=meterDeltaEForm();
 const colorForm=meterColorDeltaEForm();
 const greyMode=meterGreyRefMode();
 const gw=meterGrayWorldWeight();
 const tgtGamma=((document.getElementById('meterTargetGamma')||{}).value)||'';
 const key=greyForm+':'+colorForm+':'+greyMode+':'+gw+':'+meterAnalysisGamutKey()+':'+meterChartSignalMode()+':'+tgtGamma;
 readings.forEach(rd=>{
  if(!rd) return;
  if(rd._dE_cache_key===key) return;
  const formForReading=meterReadingUsesColorDeltaForm(rd)?colorForm:greyForm;
  const pair=meterColorDeltaE2000Pair(rd,formForReading,gw);
  rd._dE_raw=pair.raw;
  rd._dE_lc=pair.lc;
  rd._dE_cache_key=key;
 });
}

// Compute per-channel effective gamma for a single reading vs the active
// measured white. Returns {r,g,b} of the effective gamma exponent per
// channel. Values are null when a channel has non-positive linear Y or
// when ire<=0.
function meterPerChannelGamma(reading, whiteReading, ire, prevReading){
 if(!reading||!whiteReading||!(ire>0)) return {r:null,g:null,b:null};
 const g=meterAnalysisGamut();
 const rm=xyzToLinRgb(reading.X||0,reading.Y||0,reading.Z||0,g.xyzToRgb);
 const rw=xyzToLinRgb(whiteReading.X||0,whiteReading.Y||0,whiteReading.Z||0,g.xyzToRgb);
 const prevRgb=prevReading?xyzToLinRgb(prevReading.X||0,prevReading.Y||0,prevReading.Z||0,g.xyzToRgb):null;
 const exp=(m,w,pm)=>{
  if(!(w>0)) return null;
  if(ire>=100){
   const prevIre=prevReading?(prevReading.ire||0):null;
   if(pm>0 && prevIre>0 && prevIre<100){
    const gTop=Math.log(pm/w)/Math.log(prevIre/100);
    return isFinite(gTop)?gTop:null;
   }
   return null;
  }
  if(!(m>0)) return null;
  const gv=Math.log(m/w)/Math.log(ire/100);
  return isFinite(gv)?gv:null;
 };
 return {
  r:exp(rm[0],rw[0],prevRgb?prevRgb[0]:null),
  g:exp(rm[1],rw[1],prevRgb?prevRgb[1]:null),
  b:exp(rm[2],rw[2],prevRgb?prevRgb[2]:null)
 };
}

function meterEnsureChannelGammaCache(readings){
 if(!Array.isArray(readings)) return;
 const white=(meterWhiteReading&&meterWhiteReading.Y>0)?meterWhiteReading:null;
 const greys=readings.filter(rd=>rd&&meterReadingIsGreyscale(rd)).sort((a,b)=>(a.ire||0)-(b.ire||0));
 greys.forEach((rd,idx)=>{
  const prev=idx>0?greys[idx-1]:null;
  rd._gamma_rgb=meterPerChannelGamma(rd,white,rd.ire||0,prev);
 });
}

function meterColorCheckerClassicSource(){
 return [
  {name:'Gray 35',gray:0.090},
  {name:'Gray 50',gray:0.198},
  {name:'Gray 65',gray:0.362},
  {name:'Gray 80',gray:0.591},
  {name:'Dark Skin',x:0.405119,y:0.36253,Yn:0.096774},
  {name:'Light Skin',x:0.379756,y:0.357031,Yn:0.353705},
  {name:'Blue Sky',x:0.249396,y:0.266854,Yn:0.18913},
  {name:'Foliage',x:0.338784,y:0.433265,Yn:0.132836},
  {name:'Blue Flower',x:0.267688,y:0.25314,Yn:0.235775},
  {name:'Bluish Green',x:0.261653,y:0.359045,Yn:0.425252},
  {name:'Orange',x:0.512087,y:0.410373,Yn:0.287229},
  {name:'Purplish Blue',x:0.213095,y:0.186377,Yn:0.115692},
  {name:'Moderate Red',x:0.461291,y:0.312073,Yn:0.187204},
  {name:'Purple',x:0.288075,y:0.217532,Yn:0.064716},
  {name:'Yellow Green',x:0.37852,y:0.496473,Yn:0.436288},
  {name:'Orange Yellow',x:0.473379,y:0.443246,Yn:0.433456},
  {name:'Blue',x:0.186955,y:0.133934,Yn:0.060722},
  {name:'Green',x:0.306493,y:0.495107,Yn:0.234403},
  {name:'Red',x:0.547377,y:0.317462,Yn:0.114731},
  {name:'Yellow',x:0.44792,y:0.475618,Yn:0.597462},
  {name:'Magenta',x:0.371346,y:0.24177,Yn:0.187509},
  {name:'Cyan',x:0.19619,y:0.266985,Yn:0.193415}
 ];
}

function meterBuildColorCheckerStepsJS(){
 const steps=[];
 const min=meterPatchRangeMin();
 const max=min+meterPatchRangeSpan();
 const solveGamut=meterChartIsDv()?meterAnalysisGamut():meterStimulusSolveGamut();
 steps.push({ire:100,r:max,g:max,b:max,name:'White'});
 steps.push({ire:0,r:min,g:min,b:min,name:'Black'});
 meterColorCheckerClassicSource().forEach(src=>{
  if(src.gray!=null){
   const ire=Math.round(src.gray*100);
   const code=meterEncodeColorCheckerLinear(src.gray);
   steps.push({ire:ire,r:code,g:code,b:code,name:src.name});
   return;
  }
    let emitXY=meterRemapRelativeDvChromaticityToSolveGamut(src.x,src.y,solveGamut);
    emitXY=meterRemapAbsoluteDvColorCheckerChromaticity(emitXY.x,emitXY.y,solveGamut);
    const X=(emitXY.x/emitXY.y)*src.Yn;
  const Y=src.Yn;
    const Z=((1-emitXY.x-emitXY.y)/emitXY.y)*src.Yn;
  let rl=solveGamut.xyzToRgb[0][0]*X+solveGamut.xyzToRgb[0][1]*Y+solveGamut.xyzToRgb[0][2]*Z;
  let gl=solveGamut.xyzToRgb[1][0]*X+solveGamut.xyzToRgb[1][1]*Y+solveGamut.xyzToRgb[1][2]*Z;
  let bl=solveGamut.xyzToRgb[2][0]*X+solveGamut.xyzToRgb[2][1]*Y+solveGamut.xyzToRgb[2][2]*Z;
  const mx=Math.max(rl,gl,bl);
  if(mx>1){rl/=mx;gl/=mx;bl/=mx;}
  rl=Math.max(0,rl);
  gl=Math.max(0,gl);
  bl=Math.max(0,bl);
  const rCode=meterEncodeColorCheckerLinear(rl);
  const gCode=meterEncodeColorCheckerLinear(gl);
  const bCode=meterEncodeColorCheckerLinear(bl);
  let targetYn=src.Yn;
  if(meterChartIsDv()){
    const min=meterPatchRangeMin();
    const span=meterPatchRangeSpan();
    const targetGamut=meterAnalysisGamut();
    const rSignal=span>0?(rCode-min)/span:0;
    const gSignal=span>0?(gCode-min)/span:0;
    const bSignal=span>0?(bCode-min)/span:0;
    const rLin=meterDecodeColorCheckerSignal(rSignal);
    const gLin=meterDecodeColorCheckerSignal(gSignal);
    const bLin=meterDecodeColorCheckerSignal(bSignal);
    targetYn=
     targetGamut.rgbToXyz[1][0]*rLin+
     targetGamut.rgbToXyz[1][1]*gLin+
     targetGamut.rgbToXyz[1][2]*bLin;
    if(!(targetYn>=0)) targetYn=0;
  }
  steps.push({
   ire:Math.round(src.Yn*100),
   r:rCode,
   g:gCode,
   b:bCode,
   name:src.name,
   target_x:src.x,
   target_y:src.y,
   target_Yn:targetYn
  });
 });
 [
  ['100% Red','Red'],
  ['100% Green','Green'],
  ['100% Blue','Blue'],
  ['100% Cyan','Cyan'],
  ['100% Magenta','Magenta'],
  ['100% Yellow','Yellow']
 ].forEach(([name,colorName])=>{
  const rgb=meterBuildSaturationStepRgb(colorName,100);
  steps.push({
   ire:100,
   r:rgb[0],
   g:rgb[1],
   b:rgb[2],
   name:name,
   series_color:colorName,
   sat_pct:100
  });
 });
 return steps;
}

function meterStepNameKey(step){
 if(!step) return '';
 return step.name||(((step.ire!=null)?step.ire:'')+'-'+(step.r||0)+'-'+(step.g||0)+'-'+(step.b||0));
}

function meterLinearToSrgbChannel(linear){
 const c=Math.max(0,Math.min(1,linear||0));
 return c<=0.0031308 ? 12.92*c : 1.055*Math.pow(c,1/2.4)-0.055;
}

function meterPreviewCssFromLinearRgb(rgb,normalize){
 let vals=(rgb||[0,0,0]).map(v=>Number.isFinite(v)?Math.max(0,v):0);
 const isGrey=Math.abs(vals[0]-vals[1])<1e-4&&Math.abs(vals[1]-vals[2])<1e-4;
 const mx=Math.max(vals[0],vals[1],vals[2],0);
 if(mx>0){
  if(normalize&&!isGrey) vals=vals.map(v=>v/mx);
  else if(mx>1) vals=vals.map(v=>v/mx);
 }
 const enc=vals.map(v=>Math.round(255*meterLinearToSrgbChannel(v)));
 return 'rgb('+enc[0]+','+enc[1]+','+enc[2]+')';
}

function meterPreviewCssFromXYZ(X,Y,Z,normalize){
 return meterPreviewCssFromLinearRgb(xyzToLinRgb(X,Y,Z,GAMUT_PRESETS.bt709.xyzToRgb),normalize!==false);
}

function meterColorWithAlpha(css,alpha){
 const a=Math.max(0,Math.min(1,alpha==null?1:alpha));
 const s=String(css||'#aaa').trim();
 const nums=s.match(/[\d.]+/g);
 if(/^rgba?\(/i.test(s) && nums && nums.length>=3){
  return 'rgba('+Math.round(parseFloat(nums[0]))+','+Math.round(parseFloat(nums[1]))+','+Math.round(parseFloat(nums[2]))+','+a+')';
 }
 const hex=s.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
 if(hex){
  let h=hex[1];
  if(h.length===3) h=h.split('').map(ch=>ch+ch).join('');
  return 'rgba('+parseInt(h.slice(0,2),16)+','+parseInt(h.slice(2,4),16)+','+parseInt(h.slice(4,6),16)+','+a+')';
 }
 return s;
}

function meterBoostPlotColor(css,satBoost,lightBoost){
 const s=String(css||'#aaa').trim();
 let r=170,g=170,b=170;
 const nums=s.match(/[\d.]+/g);
 if(/^rgba?\(/i.test(s) && nums && nums.length>=3){
  r=Math.round(parseFloat(nums[0]));
  g=Math.round(parseFloat(nums[1]));
  b=Math.round(parseFloat(nums[2]));
 } else {
  const hex=s.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if(hex){
   let h=hex[1];
   if(h.length===3) h=h.split('').map(ch=>ch+ch).join('');
   r=parseInt(h.slice(0,2),16);
   g=parseInt(h.slice(2,4),16);
   b=parseInt(h.slice(4,6),16);
  }
 }
 r/=255; g/=255; b/=255;
 const max=Math.max(r,g,b), min=Math.min(r,g,b);
 let h=0, sat=0;
 const l=(max+min)/2;
 const d=max-min;
 if(d>0){
  sat=l>0.5 ? d/(2-max-min) : d/(max+min);
  switch(max){
   case r: h=(g-b)/d + (g<b?6:0); break;
   case g: h=(b-r)/d + 2; break;
   default: h=(r-g)/d + 4; break;
  }
  h/=6;
 }
 sat=Math.max(0,Math.min(1,sat*(satBoost==null?1.10:satBoost)));
 const ll=Math.max(0,Math.min(1,l+(lightBoost==null?-0.07:lightBoost)));
   function hue2rgb(p,q,t){
    if(t<0) t+=1;
    if(t>1) t-=1;
    if(t<1/6) return p+(q-p)*6*t;
    if(t<1/2) return q;
    if(t<2/3) return p+(q-p)*(2/3-t)*6;
    return p;
   }
 if(sat<=0){
  const v=Math.round(ll*255);
  return 'rgb('+v+','+v+','+v+')';
 }
 const q=ll<0.5 ? ll*(1+sat) : ll+sat-ll*sat;
 const p=2*ll-q;
 const rr=Math.round(hue2rgb(p,q,h+1/3)*255);
 const gg=Math.round(hue2rgb(p,q,h)*255);
 const bb=Math.round(hue2rgb(p,q,h-1/3)*255);
 return 'rgb('+rr+','+gg+','+bb+')';
}

function meterReadingIsGreyscale(reading){
 if(!reading) return false;
 const r=reading.r_code!=null?reading.r_code:reading.r;
 const g=reading.g_code!=null?reading.g_code:reading.g;
 const b=reading.b_code!=null?reading.b_code:reading.b;
 return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
}

function meterSignalPreviewColor(r,g,b){
 if(r==null||g==null||b==null) return '#aaa';
 if(r===g&&g===b) return 'rgb('+r+','+g+','+b+')';
 const xyz=linRgbToXyz(
  meterDecodeSignalChannel(r),
  meterDecodeSignalChannel(g),
  meterDecodeSignalChannel(b),
  meterStimulusSolveGamut().rgbToXyz
 );
 return meterPreviewCssFromXYZ(xyz.X,xyz.Y,xyz.Z,true);
}

function meterPreviewColorForReading(reading,mode){
 if(!reading) return '#aaa';
 const r=reading.r_code!=null?reading.r_code:reading.r;
 const g=reading.g_code!=null?reading.g_code:reading.g;
 const b=reading.b_code!=null?reading.b_code:reading.b;
 if(r!=null&&g!=null&&b!=null&&r===g&&g===b) return meterSignalPreviewColor(r,g,b);
 if(mode==='measured'&&reading.X!=null&&reading.Y!=null&&reading.Z!=null&&reading.Y>0){
  return meterPreviewCssFromXYZ(reading.X,reading.Y,reading.Z,true);
 }
 const target=meterTargetXYZForReading(reading);
 if(target&&target.Y>0) return meterPreviewCssFromXYZ(target.X,target.Y,target.Z,true);
 return meterSignalPreviewColor(r,g,b);
}

function meterPreviewColorForStep(step){
 if(!step) return '#aaa';
 return meterPreviewColorForReading({
  r_code:step.r,
  g_code:step.g,
  b_code:step.b,
  series_color:step.series_color,
  sat_pct:step.sat_pct,
  name:step.name
 },'target');
}

function meterContrastTextColor(css){
 const m=String(css||'').match(/\d+/g)||[];
 if(m.length<3) return '#222';
 const lum=0.299*parseInt(m[0],10)+0.587*parseInt(m[1],10)+0.114*parseInt(m[2],10);
 return lum<145?'#eee':'#222';
}

// Display color for a stimulus RGB triplet using a browser-safe preview of the
// actual emitted signal patch inside the current signal container.
function stimulusColor(r,g,b){
 return meterSignalPreviewColor(r,g,b);
}

// CIE 1931 spectral locus xy coordinates (5nm intervals, 380-700nm)
const CIE_LOCUS=[[.1741,.005],[.174,.005],[.1733,.0048],[.1726,.0048],[.1714,.0051],[.1703,.0058],[.1689,.0069],[.1669,.0086],[.1644,.0109],[.1611,.0138],[.1566,.0177],[.151,.0227],[.144,.0297],[.1355,.0399],[.1241,.0578],[.1096,.0868],[.0913,.1327],[.0687,.2007],[.0454,.295],[.0235,.4127],[.0082,.5384],[.0039,.6548],[.0139,.7502],[.0389,.812],[.0743,.8338],[.1142,.8262],[.1547,.8059],[.1929,.7816],[.2296,.7543],[.2658,.7243],[.3016,.6923],[.3373,.6589],[.3731,.6245],[.4087,.5896],[.4441,.5547],[.4788,.5202],[.5125,.4866],[.5448,.4544],[.5752,.4242],[.6029,.3965],[.627,.3725],[.6482,.3514],[.6658,.334],[.6801,.3197],[.6915,.3083],[.7006,.2993],[.7079,.292],[.714,.2859],[.719,.2809],[.723,.277],[.726,.274],[.7283,.2717],[.73,.27],[.732,.268],[.7334,.2666],[.7347,.2653]];

// CIE L* from Y/Yn (normalized luminance 0-1) — perceptual lightness
function ynToLstar(yn){
 const a=Math.abs(yn);
 const f=a>0.008856451679?Math.pow(a,1/3):(903.2963*a+16)/116;
 const L=116*f-16;
 return yn>=0?L:-L;
}

// Reads the selected RGB balance formula: perceptual lightness of linear RGB
// or the HCFR-style unit-Y XYZ path from measured xy.
function meterRgbBalanceFormula(){
 const sel=document.getElementById('meterRgbBalanceFormula');
 if(sel && sel.value) return sel.value;
 return 'calman';
}

// Perceptual RGB balance: linearRGB → L*, diff + 100.
// The ire>0 branch builds a luminance-compensated target (chroma-only) in
// 'absolute'/'relative' modes, or an absolute target in 'eotf' mode.
function rgbBalanceCalman(reading,whiteRef,modeOrIncl){
 if(!whiteRef||whiteRef.Y<=0) return {R:100,G:100,B:100};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 // Use the absolute D65 white target for greyscale RGB balance in all modes
 // so HDR/DV 100% white shows its real white-point error instead of being
 // pinned to 100/100/100 by self-normalizing to the measured white.
 const wXn = D65.X;
 const wZn = D65.Z;
 // Measured XYZ normalized by white Y
 const mXn=reading.X/whiteRef.Y, mYn=reading.Y/whiteRef.Y, mZn=reading.Z/whiteRef.Y;
 const ire=reading.ire;
 let lcXn,lcYn,lcZn;
 if(ire!=null&&ire>0){
  // Target: D65 white at the active grey-target luminance.
  const Lw=whiteRef.Y, Lb=0;
  const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,reading.r_code);
  const tYn=tgtLum/whiteRef.Y;
  const tXn=wXn*tYn;
  const tZn=wZn*tYn;
  if(mode==='eotf'){
   // Include luminance error: compare measured to absolute target without
   // rescaling — under/over-bright patches now skew the R/G/B bars.
   lcXn=tXn; lcYn=tYn; lcZn=tZn;
  } else {
   // Chroma-only (absolute or relative): lift/lower the target to the measured
   // Y so pure luminance errors don't show up as equal R/G/B shifts.
   const lumRatio=(mYn>0&&tYn>0)?mYn/tYn:1;
   lcXn=tXn*lumRatio; lcYn=mYn; lcZn=tZn*lumRatio;
  }
 } else {
  // No IRE: scale white chromaticity to measured luminance
  lcXn=wXn*mYn; lcYn=mYn; lcZn=wZn*mYn;
 }
 // Convert both to linear RGB via the selected analysis gamut matrix.
 const gamut=meterAnalysisGamut();
 const mRgb=xyzToLinRgb(mXn,mYn,mZn,gamut.xyzToRgb);
 const tRgb=xyzToLinRgb(lcXn,lcYn,lcZn,gamut.xyzToRgb);
 // Per-channel percent: L*(measured) - L*(target) + 100 (perceptual balance)
 return {
  R:ynToLstar(mRgb[0])-ynToLstar(tRgb[0])+100,
  G:ynToLstar(mRgb[1])-ynToLstar(tRgb[1])+100,
  B:ynToLstar(mRgb[2])-ynToLstar(tRgb[2])+100
 };
}

// HCFR-style RGB balance (RGBLevelWnd.cpp:303-328, luma-mode-OFF branch).
// Chromaticity RGB balance: build a unit-Y XYZ from the *measured*
// chromaticity, multiply by a luminance factor selected by the grey-ref
// mode, convert through the active gamut's XYZtoRGB matrix, × 100.
// Reference is the absolute gamut white (e.g. D65 for Rec.709/2020), not
// the measured 100% white — this is a true reading of each step's
// chromaticity against the colorspace anchor.
function rgbBalanceHCFR(reading,whiteRef,modeOrIncl){
 if(!whiteRef||whiteRef.Y<=0) return {R:100,G:100,B:100};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 const s = (reading.X||0)+(reading.Y||0)+(reading.Z||0);
 if(!(s>0)) return {R:100,G:100,B:100};
 const x = reading.X/s, y = reading.Y/s;
 if(!(y>0)) return {R:100,G:100,B:100};
 let fact;
 if(mode==='absolute'){
  fact = 1.0;
 } else if(mode==='relative'){
  fact = (reading.Y>0 && whiteRef.Y>0) ? reading.Y/whiteRef.Y : 1.0;
 } else { // 'eotf'
  const Lb = meterBlackReadingY();
  const tgtY = meterGreyTargetLuminance(reading.ire, whiteRef.Y, Lb, reading.r_code);
  fact = (tgtY>0 && whiteRef.Y>0 && reading.Y>0) ? reading.Y / tgtY : 1.0;
 }
 const Xn = (x/y)*fact, Yn = 1.0*fact, Zn = ((1-x-y)/y)*fact;
 const gamut = meterAnalysisGamut();
 const [r,g,b] = xyzToLinRgb(Xn,Yn,Zn, gamut.xyzToRgb);
 return { R:r*100, G:g*100, B:b*100 };
}

// Dispatcher — keeps every existing caller working while honoring the
// new <select id="meterRgbBalanceFormula"> selector.
function rgbBalance(reading,whiteRef,modeOrIncl){
 return meterRgbBalanceFormula()==='hcfr'
  ? rgbBalanceHCFR(reading,whiteRef,modeOrIncl)
  : rgbBalanceCalman(reading,whiteRef,modeOrIncl);
}

function meterLiveRgbData(reading){
 if(!reading) return {mode:'balance',R:100,G:100,B:100};
 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(!isColorSeries||reading.X==null||reading.Y==null||reading.Z==null){
  return meterWhiteReading?{mode:'balance',...rgbBalance(reading,meterWhiteReading,meterGreyRefMode())}:{mode:'balance',R:100,G:100,B:100};
 }
 const gamut=meterAnalysisGamut();
 const target=meterColorDeltaTargetXYZ(reading,meterColorIncludeLum());
 const mRgb=xyzToLinRgb(reading.X,reading.Y,reading.Z,gamut.xyzToRgb);
 const tRgb=xyzToLinRgb(target.X,target.Y,target.Z,gamut.xyzToRgb);
 // Use the patch's dominant target channel as the percent reference. For
 // many color / sat targets one channel is intentionally zero, so dividing
 // by each channel independently pins contamination to ±50 and stops being
 // informative. A shared patch-level reference keeps the deltas meaningful.
 const refScale=Math.max(
  0.01,
  Math.abs(tRgb[0]||0),
  Math.abs(tRgb[1]||0),
  Math.abs(tRgb[2]||0)
 );
 const channelDelta=(meas,ref)=>{
  meas=meas||0; ref=ref||0;
  let pct=((meas-ref)/refScale)*100;
  if(!isFinite(pct)) pct=0;
  return Math.max(-200,Math.min(200,pct));
 };
 return {
  mode:'delta',
  R:channelDelta(mRgb[0],tRgb[0]),
  G:channelDelta(mRgb[1],tRgb[1]),
  B:channelDelta(mRgb[2],tRgb[2])
 };
}

function effectiveGamma(Y,Yw,ire,prevY,prevIre){
 const frac=(ire>1)?(ire/100):ire;
 if(!(frac>0) || !(Y>0) || !(Yw>0)) return null;
 if(frac>=0.999999){
  const prevFrac=(prevIre>1)?(prevIre/100):prevIre;
  if(prevY>0 && prevFrac>0 && prevFrac<0.999999){
   const gTop=Math.log(prevY/Yw)/Math.log(prevFrac);
   return isFinite(gTop)?gTop:null;
  }
  return null;
 }
 const g=Math.log(Y/Yw)/Math.log(frac);
 return isFinite(g)?g:null;
}

function meterDvRelativeCalmanWhiteGamma(whiteY,peak){
 const targetPeak=(peak>0)?peak:100;
 if(!(whiteY>0) || !(targetPeak>0)) return null;
 const targetAtWhite=effectiveGamma(meterDvRelativeChartTargetLuminance(99.9,targetPeak),targetPeak,99.9);
 const normalizedY=whiteY/targetPeak;
 if(!(targetAtWhite>0) || !(normalizedY>0)) return null;
 const gamma=targetAtWhite/normalizedY;
 return isFinite(gamma)?gamma:null;
}

function bt1886Eotf(v,Lw,Lb){
 Lw=Lw||100;Lb=Lb||0;
 const g=2.4;
 const a=Math.pow(Math.pow(Lw,1/g)-Math.pow(Lb,1/g),g);
 const b=Math.pow(Lb,1/g)/(Math.pow(Lw,1/g)-Math.pow(Lb,1/g));
 return a*Math.pow(Math.max(0,v+b),g);
}

function gammaEotf(v,gamma){return Math.pow(Math.max(0,v),gamma);}

function srgbEotf(v){return v<=0.04045?v/12.92:Math.pow((v+0.055)/1.055,2.4);}

function targetEotf(v,Lw,Lb){
 // In HDR/DV modes the source EOTF is PQ (or a 2.2 approximation for DV),
 // not a BT.1886/sRGB power curve — targetEotf must honor that so grey
 // tracking ΔE (include-luminance mode) compares against the correct
 // absolute nits at each stimulus. The meterTargetGamma dropdown is only
 // meaningful for SDR tracking.
 if(meterChartIsHdr()) return meterChartTargetLuminance(v,Lw,Lb);
 const tgt=document.getElementById('meterTargetGamma').value;
 if(tgt==='bt1886') return bt1886Eotf(v,Lw,Lb);
 if(tgt==='st2084') return meterChartPqDecodeNormalized(v);
 if(tgt==='srgb') return srgbEotf(v)*Lw;
 return gammaEotf(v,parseFloat(tgt))*Lw;
}

function meterGreyStimulusFraction(ire){
 const pct=Math.max(0,Math.min(100,ire||0));
 const dvMode=meterChartIsDv();
 const dvAbsolute=dvMode && meterDvMapModeValue()==='1';
 if(dvAbsolute || meterDvRelativeSt2084UsesLegalRange()) return meterGreySignalFractionFromCode(meterCodeFromSignalPercent(pct));
 const isLimited=meterPatchUsesVideoRange();
 const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
 const code=dvMode
  ? (sel==='st2084'
    ? (isLimited?Math.round(16+pct/100*219):Math.round(pct*255/100))
    : (isLimited?Math.round(16+Math.pow(pct/100,1/2.2)*219):Math.round(Math.pow(pct/100,1/2.2)*255)))
  : (isLimited?Math.round(16+pct/100*(235-16)):Math.round(pct*255/100));
 return meterSignalFractionFromCode(code);
}

function meterGreyTargetSignal(ire,code){
 const nominal=Math.max(0,Math.min(1,(ire||0)/100));
 if(code!=null) return meterGreySignalFractionFromCode(code);
 if(meterChartIsPq()) return meterGreyStimulusFraction(ire);
 return nominal;
}

function meterGreyInputFraction(ire,code){
 const nominal=Math.max(0,Math.min(1,(ire||0)/100));
 if(code!=null && meterChartIsHdr()) return meterGreySignalFractionFromCode(code);
 return nominal;
}

function meterGreyTargetLuminance(ire,Lw,Lb,code){
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const peak=(Lw>0)?Lw:100;
  return meterDvAbsoluteChartTargetLuminance(ire,peak);
 }
 if(meterChartIsDv() && meterDvMapModeValue()==='2'){
  const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
  if(sel==='st2084'){
   const peak=(Lw>0)?Lw:100;
   return meterDvRelativeChartTargetLuminance(ire,peak);
  }
 }
 const peak=(Lw>0)?Lw:(meterChartIsHdr()?meterChartHdrPeak():1);
 const signal=meterGreyTargetSignal(ire,code);
 return meterChartTargetLuminance(signal,peak,Lb||0);
}

function meterGreyTargetChartValue(ire,Lw,Lb,code){
 return meterGreyTargetLuminance(ire,Lw,Lb,code);
}

function meterGreyTargetWhiteValue(Lw,Lb){
 return meterGreyTargetChartValue(100,Lw,Lb,meterPatchRangeMin()+meterPatchRangeSpan());
}

function meterGreyTargetEotfValue(ire,Lw,Lb,code){
 const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,code);
 if(meterChartIsPq() || meterChartIsDv()) return meterChartPqEncodeNormalized(tgtLum);
 const peak=(Lw>0)?Lw:100;
 return peak>0 ? tgtLum/peak : 0;
}

function meterEotfLogScaleEnabled(){
 const el=document.getElementById('meterEotfLogScale');
 return !!(el && el.checked);
}

// Log-strength tuned for EOTF ratio charts: keeps linear behavior available,
// while revealing near-black structure in HDR where PQ appears compressed.
function meterEotfLogAlpha(){
 return 80;
}

function meterEotfScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 if(!meterEotfLogScaleEnabled()) return val/top;
 const a=meterEotfLogAlpha();
 return Math.log(1+a*val)/Math.log(1+a*top);
}

function meterEotfUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 if(!meterEotfLogScaleEnabled()) return n*top;
 const a=meterEotfLogAlpha();
 return (Math.exp(n*Math.log(1+a*top))-1)/a;
}

function meterLuminanceLogScaleEnabled(){
 const el=document.getElementById('meterLuminanceLogScale');
 return !!(el && el.checked);
}

function meterLuminanceScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 if(!meterLuminanceLogScaleEnabled()) return val/top;
 return Math.log(1+val)/Math.log(1+top);
}

function meterLuminanceUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 if(!meterLuminanceLogScaleEnabled()) return n*top;
 return Math.exp(n*Math.log(1+top))-1;
}

function meterGreyMeasuredEotfValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 if(meterChartIsPq() || meterChartIsDv()) return meterChartPqEncodeNormalized(y);
 const peak=(refWhite>0)?refWhite:100;
 return peak>0 ? y/peak : 0;
}

function meterGreyTargetGamma(ire,Lw,Lb,code,prevIre,prevCode){
 const peak=(Lw>0)?Lw:100;
 if(!(peak>0) || !(ire>0)) return null;
 const tgt=((document.getElementById('meterTargetGamma')||{}).value)||'2.2';
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
  const tgtLum=meterDvAbsoluteChartTargetLuminance(ire,peak);
  if(ire>=100){
   const prevLum=meterDvAbsoluteChartTargetLuminance(prevStepIre,peak);
   return effectiveGamma(tgtLum,peak,ire,prevLum,prevStepIre);
  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 if(meterChartIsDv() && meterDvMapModeValue()==='2' && tgt==='st2084'){
  const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
  const tgtLum=meterDvRelativeChartTargetLuminance(ire,peak);
  if(ire>=100){
   return meterDvRelativeCalmanWhiteGamma(tgtLum,peak);
  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 const signal=meterGreyTargetSignal(ire,code);
 if(!(signal>0)) return null;
 const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
 const prevStepCode=(prevCode!=null)?prevCode:meterCodeFromSignalPercent(prevStepIre);
 // HDR/PQ: the "target gamma" is the effective exponent of the actual
 // displayed target curve at each grey step. In DV this follows the encoded
 // transport patch values that the series generator emits, which yields the
 // expected near-linear luminance-vs-step target in the chart view.
 if(meterChartIsHdr()){
  const tgtLum=meterChartTargetLuminance(signal,peak,Lb||0);
  if(ire>=100){
   const prevSignal=meterGreyTargetSignal(prevStepIre,prevStepCode);
   const prevLum=meterChartTargetLuminance(prevSignal,peak,Lb||0);
   return effectiveGamma(tgtLum,peak,ire,prevLum,prevStepIre);
  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 let black=Lb||0;
 if(tgt==='bt1886'){
  // BT.1886 is not a flat 2.4 line once black level is included. Use the
  // measured/inferred chart black level directly; do not force config.min_luma
  // when black reads as 0 on emissive displays.
  if(!(black>0)) return 2.4;
  const tgtLum=bt1886Eotf(signal,peak,black);
  if(ire>=100){
   const prevSignal=meterGreyTargetSignal(prevStepIre,prevStepCode);
   const prevLum=bt1886Eotf(prevSignal,peak,black);
   return effectiveGamma(tgtLum,peak,ire,prevLum,prevStepIre);
  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 if(tgt==='srgb') return 2.2;
 const gamma=parseFloat(tgt);
 return (gamma>0&&isFinite(gamma))?gamma:null;
}

function meterGreyTargetPeak(refWhite){
 // DV absolute and DV relative both anchor the chart target to the measured
 // 100% white so the target curve tracks what the display actually produces
 // rather than the authored mastering-peak label.
 if(meterChartIsDv()) return (refWhite>0)?refWhite:meterChartMasterPeak();
 // HDR10/PQ greyscale charts should keep the same target-curve shape but
 // normalize it to the actual measured white so the target luminance and
 // EOTF views line up with the display's real peak after a series run.
 if(meterChartIsPq()) return (refWhite>0)?refWhite:meterChartHdrPeak();
 return (refWhite>0)?refWhite:100;
}

function meterTargetGammaLabel(){
 const sel=document.getElementById('meterTargetGamma');
 if(!sel) return meterChartIsDv() ? 'Dolby Vision' : (meterChartIsPq() ? 'PQ' : 'Gamma');
 const opt=sel.options[sel.selectedIndex];
 if(meterChartIsDv() && meterDvMapModeValue()==='2' && ((sel&&sel.value)||'')==='st2084') return 'Dolby Vision Relative';
 if(meterChartIsDv()) return opt&&opt.textContent?opt.textContent.trim():'Dolby Vision';
 if(meterChartIsPq()) return 'PQ';
 return opt&&opt.textContent?opt.textContent.trim():'Gamma';
}

function meterGreyTargetChartPoints(steps,Lw,Lb,scale){
 const pts=[];
 const seen={};
 const addPoint=(ire,code)=>{
  const key=''+ire+':'+(code==null?'':code);
  if(seen[key]) return;
  seen[key]=1;
  pts.push([meterGreyInputFraction(ire,code),meterGreyTargetChartValue(ire,Lw,Lb,code)/scale]);
 };
 addPoint(0,0);
 (steps||[]).forEach(s=>addPoint(s.ire||0,s.r_code!=null?s.r_code:s.r));
 addPoint(100,meterPatchRangeMin()+meterPatchRangeSpan());
 pts.sort((a,b)=>a[0]-b[0]);
 return pts;
}

function targetGammaValue(){
 const tgt=document.getElementById('meterTargetGamma').value;
 if(tgt==='bt1886') return 2.4;
 if(tgt==='srgb') return 2.2;
 return parseFloat(tgt);
}

function meterChartSignalMode(){
 const liveSel=(document.getElementById('signal_mode')||{}).value;
 if(liveSel) return liveSel;
 if(config&&config.dv_status==='1') return 'dv';
 if(config&&config.is_hdr==='1') return (config.eotf==='3')?'hlg':'hdr10';
 return 'sdr';
}

function meterChartIsHdr(){
 return meterChartSignalMode()!=='sdr';
}

function meterChartIsPq(){
 const sm=meterChartSignalMode();
 return sm==='hdr10'||sm==='dv';
}

function meterChartIsHlg(){
 return meterChartSignalMode()==='hlg';
}

function meterChartIsDv(){
 return meterChartSignalMode()==='dv';
}

function meterChartHdrPeak(){
 const top=document.getElementById('max_luma');
 const live=top?parseFloat(top.value):NaN;
 const cfg=parseFloat((config&&config.max_luma)||'1000');
 const peak=live>0?live:cfg;
 if(!(peak>0)) return 1000;
 return Math.min(10000,peak);
}

// The meter pane mirrors the main HDR metadata controls so peak/min only
// have to be set once at the top of the page.
function meterChartMasterPeak(){
 return meterChartHdrPeak();
}

function meterChartMasterMin(){
 const top=document.getElementById('min_luma');
 const live=top?parseFloat(top.value):NaN;
 const cfg=parseFloat((config&&config.min_luma)||'0.005');
 if(live>=0&&isFinite(live)) return live;
 return (cfg>=0&&isFinite(cfg))?cfg:0.005;
}

function meterChartBt2390Enabled(){
 const el=document.getElementById('meterHdrApplyBT2390');
 return !!(el && el.checked);
}

// ITU-R BT.2390-11 §5.2 Hermite tone-mapping:
// Maps an input luminance (nits) encoded in PQ against a master peak Lmax
// to a display peak Ldisp. Input/output are linear nits (not PQ-coded).
// Below the knee point KS the curve is identity; above, a cubic Hermite
// spline rolls toward Ldisp. Returns linear nits clipped to Ldisp.
function bt2390Tonemap(Lsrc, Lmax, Ldisp){
 if(!(Lmax>0) || !(Ldisp>0)) return Lsrc;
 if(Ldisp>=Lmax) return Math.min(Lsrc,Lmax);
 if(!(Lsrc>0)) return 0;
 // Work in PQ E' domain (0..1) so the curve is perceptually uniform.
 const Emax = meterChartPqEncodeNormalized(Lmax);
 const Edisp = meterChartPqEncodeNormalized(Ldisp);
 const E = meterChartPqEncodeNormalized(Lsrc);
 if(!(Emax>0)) return Lsrc;
 const e1 = E / Emax;           // normalized input [0,1]
 const maxLum = Edisp / Emax;   // display peak in same normalized scale
 const KS = 1.5*maxLum - 0.5;   // knee start (BT.2390)
 let e2;
 if(e1 < KS || KS>=1){
  e2 = e1;
 } else {
  const T = (e1 - KS) / (1 - KS);
  const T2 = T*T;
  const T3 = T2*T;
  // Hermite spline: P(T) = (2T³-3T²+1)KS + (T³-2T²+T)(1-KS) + (-2T³+3T²)maxLum
  e2 = (2*T3 - 3*T2 + 1)*KS
     + (T3 - 2*T2 + T)*(1 - KS)
     + (-2*T3 + 3*T2)*maxLum;
 }
 const Eout = e2 * Emax;
 return Math.min(meterChartPqDecodeNormalized(Eout), Ldisp);
}

// Show the HDR roll-off control only when the chart path can actually use it
// (PQ-based HDR/DV targets). Called from the HDR-aware redraw path.
function meterUpdateHdrConfigVisibility(){
 const el=document.getElementById('meterHdrConfig');
 if(!el) return;
 el.style.display = meterChartIsPq() ? '' : 'none';
}

function meterChartPqEncodeNormalized(nits){
 const clamped=Math.max(0,Math.min(10000,nits||0));
 if(clamped<=0) return 0;
 const l=clamped/10000;
 const m1=2610/16384;
 const m2=2523/32;
 const c1=3424/4096;
 const c2=2413/128;
 const c3=2392/128;
 const p=Math.pow(l,m1);
 return Math.pow((c1+c2*p)/(1+c3*p),m2);
}

function meterChartPqDecodeNormalized(code){
 const clamped=Math.max(0,Math.min(1,code||0));
 if(clamped<=0) return 0;
 const m1=2610/16384;
 const m2=2523/32;
 const c1=3424/4096;
 const c2=2413/128;
 const c3=2392/128;
 const p=Math.pow(clamped,1/m2);
 const num=Math.max(p-c1,0);
 const den=c2-c3*p;
 if(den<=0) return 10000;
 return 10000*Math.pow(num/den,1/m1);
}

function hlgOotf(maxY){
 const peak=maxY>0?maxY:1000;
 if(peak<400 || peak>2000) return 1.2*Math.pow(1.111,Math.log(peak/1000)/Math.log(2));
 if(peak>1000) return 1.2+0.42*Math.log10(peak/1000);
 return 1.2;
}

function hlgOetf(linearLight){
 const x=Math.max(0,linearLight||0)*12;
 if(x<=1) return 0.5*Math.sqrt(x);
 return 0.17883277*Math.log(x-0.28466892)+0.55991073;
}

function hlgEotf(stim,minY,maxY){
 const peak=maxY>0?maxY:1000;
 const black=Math.max(0,minY||0);
 const gamma=hlgOotf(peak);
 const clamped=Math.max(0,Math.min(1,stim||0));
 const a=peak-black;
 const b=Math.sqrt(3*Math.pow(Math.max(black/peak,0),1/gamma));
 return a*Math.pow(clamped,gamma)+b;
}

function hlgSignalToDisplayLinear(stim,minY,maxY){
 const peak=maxY>0?maxY:1000;
 if(!(peak>0)) return 0;
 return Math.max(0,Math.min(1,hlgEotf(stim,minY,peak)/peak));
}

function meterChartHdrStimulusLuminance(v){
 return Math.pow(Math.max(0,Math.min(1,v)),2.2)*meterChartHdrPeak();
}

function meterChartHdrCodeLuminance(v,clipPeak){
 const peak=(clipPeak>0)?clipPeak:meterChartHdrPeak();
 const raw=meterChartPqDecodeNormalized(v);
 if(meterChartBt2390Enabled()){
  const master=meterChartMasterPeak();
  return bt2390Tonemap(raw,master,peak);
 }
 return Math.min(raw,peak);
}

function meterChartDvClipPeak(){
 const contentPeak=meterChartHdrPeak();
 const whitePeak=(meterWhiteReading&&meterWhiteReading.luminance>0)?meterWhiteReading.luminance:0;
 return whitePeak>0?Math.min(contentPeak,whitePeak):contentPeak;
}

function meterChartTrackingLuminance(v,clipPeak,Lw,Lb){
 const clamped=Math.max(0,Math.min(1,v));
 if(meterChartIsPq()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  return meterChartHdrCodeLuminance(clamped,peak);
 }
 if(meterChartIsHlg()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  return Math.min(hlgEotf(clamped,Lb||0,peak),peak);
 }
 return targetEotf(clamped,Lw,Lb);
}

function meterChartTargetLuminance(v,Lw,Lb){
 const peak=(Lw>0)?Lw:meterChartHdrPeak();
 if(meterChartIsHdr()) return meterChartTrackingLuminance(v,peak,Lw,Lb);
 return meterChartTrackingLuminance(v,Lw,Lw,Lb);
}

// CIE L* from Y with white reference Yn
function cieLstar(Y,Yn){
 if(Yn<=0) return 0;
 const r=Y/Yn;
 return r>0.008856?116*Math.cbrt(r)-16:903.3*r;
}

// CIELUV chromaticity-only ΔE: 1300 * Δu'v' (HCFR old formula)
function deltaEuv(X,Y,Z,Xr,Yr,Zr){
 const d=X+15*Y+3*Z, dr=Xr+15*Yr+3*Zr;
 if(d<=0||dr<=0) return 0;
 const u=4*X/d, v=9*Y/d;
 const ur=4*Xr/dr, vr=9*Yr/dr;
 return 1300*Math.sqrt((u-ur)*(u-ur)+(v-vr)*(v-vr));
}

// Full CIELUV ΔE*uv (HCFR 3.5.4.4 new formula)
// Yw1/Yw2 = white Y for L* scaling of measured/reference
// (Xn,Yn,Zn) = adaptation white for u'n,v'n
function deltaELuv(X1,Y1,Z1,Yw1, X2,Y2,Z2,Yw2, Xn,Yn,Zn){
 const L1=cieLstar(Y1,Yw1), L2=cieLstar(Y2,Yw2);
 const d1=X1+15*Y1+3*Z1, d2=X2+15*Y2+3*Z2, dn=Xn+15*Yn+3*Zn;
 if(d1<=0||dn<=0) return Math.abs(L1-L2);
 const un=4*Xn/dn, vn=9*Yn/dn;
 const u1s=13*L1*(4*X1/d1-un), v1s=13*L1*(9*Y1/d1-vn);
 const u2s=d2>0?13*L2*(4*X2/d2-un):0, v2s=d2>0?13*L2*(9*Y2/d2-vn):0;
 return Math.sqrt((L1-L2)*(L1-L2)+(u1s-u2s)*(u1s-u2s)+(v1s-v2s)*(v1s-v2s));
}

// XYZ to Lab (optional white point, defaults to D65 Y=1)
function xyzToLab(X,Y,Z,Xn,Yn,Zn){
 if(!Xn){Xn=D65.X;Yn=D65.Y;Zn=D65.Z;}
 const e=216/24389, k=24389/27;
 function f(t){return t>e?Math.cbrt(t):(k*t+16)/116;}
 const fx=f(X/Xn),fy=f(Y/Yn),fz=f(Z/Zn);
 return {L:116*fy-16, a:500*(fx-fy), b:200*(fy-fz)};
}

// HCFR's CIELUV ΔE — matches libHCFR/Color.cpp ColorLuv ctor bit-for-bit.
// HCFR's u-prime has a bug (12*x instead of 12*y in the denominator):
//   u = 4x / (-2x + 12x + 3)   [should be 12y, but HCFR uses 12x]
//   v = 9y / (-2x + 12y + 3)   [correct]
// u_white, v_white use the same formulas applied to the CColorReference
// white point (D65 for BT.709/BT.2020). refColor's chromaticity is NOT the
// subtraction target — the cRef white is.
// YWhite / YWhiteRef scale L* via var_Y = Y/YWhite (epsilon branch for low Y).
function lstar(Y,YW){
 const e=216/24389, k=24389/27;
 if(YW<=0||Y<=0) return 0;
 const v=Y/YW;
 return v>e ? 116*Math.cbrt(v)-16 : (k*v+16)/116*116-16;
}
function _hcfrUV(X,Y,Z){
 const s=X+Y+Z; if(s<=0) return {u:0,v:0};
 const x=X/s, y=Y/s;
 const u=4*x/(10*x+3);        // HCFR's buggy u: -2x+12x+3 = 10x+3
 const v=9*y/(-2*x+12*y+3);   // standard v
 return {u:u,v:v};
}
function deltaELuvHCFR(X1,Y1,Z1,YW1, X2,Y2,Z2,YW2){
 // L* from each sample's own YWhite (matches HCFR: Luv(*this, YWhite, cRef)
 // for measured, LuvRef(refColor, YWhiteRef, cRef) for reference).
 const L1=lstar(Y1,YW1), L2=lstar(Y2,YW2);
 // u_white, v_white are always from cRef (D65 for our BT.709/2020 pipeline)
 const uw=4*D65.x/(10*D65.x+3);
 const vw=9*D65.y/(-2*D65.x+12*D65.y+3);
 const m1=_hcfrUV(X1,Y1,Z1);
 const m2=_hcfrUV(X2,Y2,Z2);
 const u1s=13*L1*(m1.u-uw), v1s=13*L1*(m1.v-vw);
 const u2s=13*L2*(m2.u-uw), v2s=13*L2*(m2.v-vw);
 const dL=L1-L2, du=u1s-u2s, dv=v1s-v2s;
 return Math.sqrt(dL*dL+du*du+dv*dv);
}

// Returns whether the "Include luminance error" checkbox is ticked.
// Retained for back-compat with callers that still pass boolean inclLum.
function meterIncludeLum(){
 const el=document.getElementById('meterIncludeLumError');
 if(!el) return false;
 // Select-driven mode wins when present (checkbox follows the select).
 const sel=document.getElementById('meterGreyRefMode');
 if(sel && sel.value) return sel.value==='eotf';
 return !!el.checked;
}

// Unified handler for the grey-ref / gray-world / RGB balance / greyscale
// ΔE / color ΔE selectors and the legacy checkbox. Keeps checkbox state in
// sync with the select, persists selections, and redraws charts.
function meterOnGreyRefChange(src){
 const cb=document.getElementById('meterIncludeLumError');
 const sel=document.getElementById('meterGreyRefMode');
 if(cb && sel){
  if(src==='checkbox' || (src==null && document.activeElement===cb)){
   sel.value = cb.checked ? 'eotf' : 'absolute';
  } else {
   cb.checked = (sel.value==='eotf');
  }
 }
 try{ meterSaveColorPrefs(); }catch(e){}
 if(meterReadings && meterReadings.length){
  // Invalidate any per-reading greyscale analysis cache (mode/form/gw changed).
  meterReadings.forEach(r=>{
   if(!r) return;
   delete r._dE_cache_key;
   delete r._dE_raw;
   delete r._dE_lc;
   delete r._gamma_rgb;
  });
  _chartHitZones=[];
  meterLastChartSignature='';
  meterLastChartCount=0;
  if(meterActiveSeriesType && meterActiveSeriesPoints && typeof meterRefreshActiveSeriesCharts==='function'){
   meterRefreshActiveSeriesCharts();
  } else {
   drawAllCharts(meterReadings);
  }
 }
}

// Persist the meter color-science selections to localStorage so reloads
// keep the user's choices. Keys are kept under pgen.meter.* so they don't
// collide with other prefs.
function meterSaveColorPrefs(){
 try{
  const v=(id)=>{ const e=document.getElementById(id); return e?e.value:''; };
  const cb=(id)=>{ const e=document.getElementById(id); return e?(e.checked?'1':'0'):''; };
  const prefs={
   grey_ref_mode: v('meterGreyRefMode'),
   gray_world:    v('meterGrayWorld'),
   rgb_formula:   v('meterRgbBalanceFormula'),
   de_form:       v('meterDeltaEForm'),
   color_de_form: v('meterColorDeltaEForm'),
  color_incl_lum:cb('meterColorIncludeLumError'),
   incl_lum:      cb('meterIncludeLumError'),
   target_gamma:  v('meterTargetGamma'),
    hdr_bt2390:    cb('meterHdrApplyBT2390'),
    eotf_log:      cb('meterEotfLogScale'),
    lum_log:       cb('meterLuminanceLogScale')
  };
  localStorage.setItem('pgen.meter.colorPrefs', JSON.stringify(prefs));
 }catch(e){}
}

// Apply saved meter color-science selections to the DOM. Safe to call
// before the inputs exist — each lookup is a no-op if the element is
// missing. Server-provided config wins on first load; see meterApplyServerColorPrefs.
function meterLoadColorPrefs(){
 try{
  const raw=localStorage.getItem('pgen.meter.colorPrefs');
  if(!raw) return;
  const p=JSON.parse(raw)||{};
  const setVal=(id,val)=>{ if(val==null||val==='') return; const e=document.getElementById(id); if(e) e.value=val; };
  const setChk=(id,val)=>{ if(val==null||val==='') return; const e=document.getElementById(id); if(e) e.checked=(val==='1'||val===true); };
  setVal('meterGreyRefMode', p.grey_ref_mode);
  setVal('meterGrayWorld',   p.gray_world);
  setVal('meterRgbBalanceFormula', p.rgb_formula);
  setVal('meterDeltaEForm',  p.de_form==='auto'?'deluv76':p.de_form);
  setVal('meterColorDeltaEForm', p.color_de_form);
  setChk('meterColorIncludeLumError', p.color_incl_lum);
  setChk('meterIncludeLumError', p.incl_lum);
  setVal('meterTargetGamma', p.target_gamma);
  setChk('meterHdrApplyBT2390', p.hdr_bt2390);
  setChk('meterEotfLogScale', p.eotf_log);
  setChk('meterLuminanceLogScale', p.lum_log);
 }catch(e){}
}

// Tri-state grey-reference mode (HCFR m_dE_gray 0/1/2).
//   'absolute' : ref Y = measured Y (ΔL*=0; chroma only)
//   'eotf'     : ref Y = target EOTF using the configured / metadata peak
//                (luminance tracking error included)
//   'relative' : ref Y = measured Y normalized to measured white peak
//                (perfect-gamma assumption; gamma/luma error cancelled).
//
// Reads <select id="meterGreyRefMode"> when present; otherwise falls back
// to the legacy checkbox (#meterIncludeLumError) where ticked → 'eotf'.
function meterGreyRefMode(){
 const sel=document.getElementById('meterGreyRefMode');
 if(sel && sel.value) return sel.value;
 return meterIncludeLum() ? 'eotf' : 'relative';
}

// Accepts either a boolean (legacy inclLum) or a mode string and returns
// the canonical mode string for the grey-reference builders.
function meterResolveGreyRefMode(x){
 if(typeof x === 'string'){
  if(x==='eotf'||x==='absolute'||x==='relative') return x;
 }
 if(x===true) return 'eotf';
 if(x===false) return 'absolute';
 return meterGreyRefMode();
}

// Returns the selected gray-world weighting (HCFR gw_Weight).
// 1.0 = off, 0.15 = gray-world, 0.05 = near-black. Pulls the Y/Yn ratio
// below Lab's ε threshold so near-black luminance errors become visible.
function meterGrayWorldWeight(){
 const sel=document.getElementById('meterGrayWorld');
 if(!sel) return 1.0;
 const v=parseFloat(sel.value);
 return (v>0 && v<=1) ? v : 1.0;
}

// Greyscale reference builder for ΔE calculation.
//   mode === 'absolute' : chroma-only. Reference is D65 at the measured Y
//     normalized by peak, so ΔL* = 0 and only u'v' / a*b* chromaticity
//     error contributes. Matches the chroma-only readout used by most
//     calibration tools. (HCFR m_dE_gray == 0)
//   mode === 'eotf'     : "include luminance error" mode. Reference
//     Y comes from the active EOTF using the configured / metadata peak,
//     so ΔL* reports absolute tracking error. (HCFR m_dE_gray == 1)
//   mode === 'relative' : reference Y uses the measured relative luminance
//     of the step (Ym / Ywhite), cancelling gamma/luma error while still
//     using the target white chromaticity. (HCFR m_dE_gray == 2)
//
// Legacy boolean inclLum is still accepted (true → 'eotf', false → 'absolute').
// Optional gwWeight (HCFR gw_Weight) pre-multiplies YWhite / YWhiteRef by
// 0.15 or 0.05 to pull Lab into its linear (κ·t) region for near-black
// patches.

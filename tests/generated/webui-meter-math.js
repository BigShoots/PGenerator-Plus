// Generated file. Do not edit directly.
// Source: /mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus/usr/share/PGenerator/webui.pm
// Source SHA-256: 6f6a3c9d4539
// Extracted by tools/extract_webui_meter_math.py

// D65 reference white chromaticity
const D65={x:0.3127,y:0.3290,X:0.9505,Y:1.0,Z:1.0890};
const METER_XYZ_MATRIX_DEFAULT=[[1,0,0],[0,1,0],[0,0,1]];

function xyToUnitXyz(x,y){
 if(!(x>0) || !(y>0) || x+y>=1) return {X:D65.X,Y:1,Z:D65.Z};
 return {X:x/y,Y:1,Z:(1-x-y)/y};
}

function meterIdentityXyzCorrectionMatrix(){
 return METER_XYZ_MATRIX_DEFAULT.map(row=>row.slice());
}

function meterXyzCorrectionEnabled(){
 const el=document.getElementById('meterXyzMatrixEnabled');
 return el ? !!el.checked : true;
}

function meterStoredXyzMatrixEnabled(settings){
 if(!settings||settings.xyz_matrix_enabled==null) return false;
 return settings.xyz_matrix_enabled===true||settings.xyz_matrix_enabled==='1'||settings.xyz_matrix_enabled===1;
}

function meterUpdateXyzMatrixVisibility(){
 const wrap=document.getElementById('meterXyzMatrixFields');
 const actionRow=document.getElementById('meterXyzMatrixActionRow');
 const enabled=meterXyzCorrectionEnabled();
 if(wrap) wrap.classList.toggle('visible',enabled);
 if(actionRow) actionRow.classList.toggle('visible',enabled);
 ['meterXyzM11','meterXyzM12','meterXyzM13','meterXyzM21','meterXyzM22','meterXyzM23','meterXyzM31','meterXyzM32','meterXyzM33'].forEach(id=>{
  const el=document.getElementById(id);
  if(el) el.disabled=!enabled;
 });
}

function meterConfiguredXyzCorrectionMatrix(){
 const ids=[
  ['meterXyzM11','meterXyzM12','meterXyzM13'],
  ['meterXyzM21','meterXyzM22','meterXyzM23'],
  ['meterXyzM31','meterXyzM32','meterXyzM33']
 ];
 return ids.map((row,rowIdx)=>row.map((id,colIdx)=>{
  const el=document.getElementById(id);
  const raw=parseFloat((el&&el.value)||'');
  return Number.isFinite(raw)?raw:METER_XYZ_MATRIX_DEFAULT[rowIdx][colIdx];
 }));
}

function meterSetXyzCorrectionMatrix(matrix, enabled){
 const ids=[
  ['meterXyzM11','meterXyzM12','meterXyzM13'],
  ['meterXyzM21','meterXyzM22','meterXyzM23'],
  ['meterXyzM31','meterXyzM32','meterXyzM33']
 ];
 ids.forEach((row,rowIdx)=>row.forEach((id,colIdx)=>{
  const el=document.getElementById(id);
  if(!el) return;
  const value=matrix&&matrix[rowIdx]&&Number.isFinite(Number(matrix[rowIdx][colIdx]))?Number(matrix[rowIdx][colIdx]):METER_XYZ_MATRIX_DEFAULT[rowIdx][colIdx];
  el.value=String(Math.round(value*10000)/10000);
 }));
 if(enabled!=null){
  const toggle=document.getElementById('meterXyzMatrixEnabled');
  if(toggle) toggle.checked=(enabled===true||enabled===1||enabled==='1');
 }
}

function meterExportXyzMatrix(){
 const payload={
  format:'pgenerator-xyz-correction-matrix',
  version:1,
  enabled:meterXyzCorrectionEnabled(),
  matrix:meterConfiguredXyzCorrectionMatrix()
 };
 const filename=meterPromptExportFilename('xyz-matrix','pgenerator-xyz-correction-matrix','json','Enter a file name for the XYZ correction matrix export');
 if(!filename) return;
 const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'});
 meterDownloadBlob(blob,filename);
}

function meterOpenXyzMatrixImport(){
 const input=document.getElementById('meterXyzMatrixImportInput');
 if(!input) return;
 input.value='';
 input.click();
}

function meterParseImportedXyzMatrix(rawText){
 const parsed=JSON.parse(String(rawText||'{}'));
 let enabled=null;
 let matrix=parsed;
 if(parsed&&typeof parsed==='object'&&!Array.isArray(parsed)){
  if(parsed.enabled!=null) enabled=(parsed.enabled===true||parsed.enabled===1||parsed.enabled==='1');
  if(Array.isArray(parsed.matrix)) matrix=parsed.matrix;
 }
 if(!Array.isArray(matrix)||matrix.length!==3||matrix.some(row=>!Array.isArray(row)||row.length!==3)){
  throw new Error('Matrix must be a 3x3 array');
 }
 const normalized=matrix.map(row=>row.map(value=>{
  const numeric=Number(value);
  if(!Number.isFinite(numeric)) throw new Error('Matrix values must be numeric');
  return numeric;
 }));
 return {matrix:normalized,enabled:enabled};
}

function meterImportXyzMatrix(evt){
 const file=evt&&evt.target&&evt.target.files?evt.target.files[0]:null;
 if(!file) return;
 const reader=new FileReader();
 reader.onload=()=>{
  try{
   const imported=meterParseImportedXyzMatrix(reader.result);
   meterSetXyzCorrectionMatrix(imported.matrix, imported.enabled);
   meterRefreshAfterXyzMatrixChange();
   saveMeterSettings();
   toast('XYZ correction matrix imported');
  }catch(e){
   toast('Invalid XYZ correction matrix file',true);
  }
 };
 reader.readAsText(file);
}

function meterXyzCorrectionMatrix(){
 if(!meterXyzCorrectionEnabled()) return meterIdentityXyzCorrectionMatrix();
 return meterConfiguredXyzCorrectionMatrix();
}

function meterApplyXyzCorrectionMatrix(X,Y,Z,matrix){
 const M=matrix||meterXyzCorrectionMatrix();
 return {
  X:M[0][0]*X+M[0][1]*Y+M[0][2]*Z,
  Y:M[1][0]*X+M[1][1]*Y+M[1][2]*Z,
  Z:M[2][0]*X+M[2][1]*Y+M[2][2]*Z
 };
}

function meterNormalizeMeasuredReading(reading){
 if(!reading||typeof reading!=='object'||reading.synthetic_target) return reading;
 if(reading.raw_X==null&&reading.X!=null) reading.raw_X=Number(reading.X);
 if(reading.raw_Y==null&&reading.Y!=null) reading.raw_Y=Number(reading.Y);
 if(reading.raw_Z==null&&reading.Z!=null) reading.raw_Z=Number(reading.Z);
 if(reading.raw_x==null&&reading.x!=null) reading.raw_x=Number(reading.x);
 if(reading.raw_y==null&&reading.y!=null) reading.raw_y=Number(reading.y);
 if(reading.raw_luminance==null){
  const lum=(reading.luminance!=null)?Number(reading.luminance):Number(reading.Y);
  if(Number.isFinite(lum)) reading.raw_luminance=lum;
 }
 const rawX=Number(reading.raw_X);
 const rawY=Number(reading.raw_Y);
 const rawZ=Number(reading.raw_Z);
 const rawx=Number(reading.raw_x);
 const rawy=Number(reading.raw_y);
 const rawLum=Number(reading.raw_luminance);
 let base=null;
 if(Number.isFinite(rawX)&&Number.isFinite(rawY)&&Number.isFinite(rawZ)){
  base={X:rawX,Y:rawY,Z:rawZ};
 }
 else if(Number.isFinite(rawx)&&Number.isFinite(rawy)&&rawy>0&&rawx+rawy<1&&Number.isFinite(rawLum)&&rawLum>=0){
  base={X:(rawx/rawy)*rawLum,Y:rawLum,Z:((1-rawx-rawy)/rawy)*rawLum};
 }
 if(!base) return reading;
 const enabled=meterXyzCorrectionEnabled();
 const corrected=enabled?meterApplyXyzCorrectionMatrix(base.X,base.Y,base.Z):base;
 reading.X=corrected.X;
 reading.Y=corrected.Y;
 reading.Z=corrected.Z;
 if(enabled&&(reading.luminance!=null||reading.raw_luminance!=null)) reading.luminance=corrected.Y;
 const sum=corrected.X+corrected.Y+corrected.Z;
 if(sum>0){
  reading.x=corrected.X/sum;
  reading.y=corrected.Y/sum;
 }
 return reading;
}

function meterTargetWhitePoint(){
 if(!meterTargetWhitePointEnabled()){
  const gamut=GAMUT_PRESETS[meterActiveGamutKey()]||GAMUT_PRESETS.bt709;
  if(gamut&&gamut.white){
   const xyz=xyToUnitXyz(gamut.white.x,gamut.white.y);
   return {x:gamut.white.x,y:gamut.white.y,X:xyz.X,Y:1,Z:xyz.Z};
  }
  return {...D65};
 }
 const xEl=document.getElementById('meterTargetWhiteX');
 const yEl=document.getElementById('meterTargetWhiteY');
 const rawX=parseFloat((xEl&&xEl.value)||'');
 const rawY=parseFloat((yEl&&yEl.value)||'');
 const x=Number.isFinite(rawX)?rawX:D65.x;
 const y=Number.isFinite(rawY)?rawY:D65.y;
 if(!(x>0) || !(y>0) || x+y>=1) return {...D65};
 const xyz=xyToUnitXyz(x,y);
 return {x,y,X:xyz.X,Y:1,Z:xyz.Z};
}

const GAMUT_PRESETS=__PG_GAMUT_PRESETS__;

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
  if(prim===2) return 'p3d65';
  if(prim===3) return 'p3dci';
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
 if(val==='customd65') return 'bt709';
 return /^(bt709|bt2020|p3d65|p3dci)$/.test(val)?val:'';
}

function meterTargetWhitePointEnabled(){
 const el=document.getElementById('meterTargetGamut');
 return String(el&&el.value||'').toLowerCase()==='customd65';
}

function updateMeterTargetWhitepointVisibility(){
 const field=document.getElementById('meterTargetWhitePointField');
 if(!field) return;
 field.classList.toggle('visible',meterTargetWhitePointEnabled());
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

function meterOutputFormatValue(){
 const fmtEl=document.getElementById('color_format');
 return String((fmtEl&&fmtEl.value) || (config&&config.color_format) || '0');
}

function meterOutputIsRgb(){
 return meterOutputFormatValue()==='0';
}

function meterExtendedVideoHeadroomRequired(){
 return meterActiveSeriesType==='greyscale'&&meterLgGreyscaleUsesExtendedSdr(meterActiveSeriesPoints);
}

function meterExtendedVideoTransportCanCarryHeadroom(){
 return !meterOutputIsRgb()&&meterIsLimitedRange();
}

function meterExtendedVideoTransportOk(){
 if(!meterExtendedVideoHeadroomRequired()) return true;
 return meterExtendedVideoTransportCanCarryHeadroom();
}

function meterEnsureExtendedVideoTransport(){
 if(!meterExtendedVideoHeadroomRequired()||meterExtendedVideoTransportOk()) return true;
 const fmtSel=document.getElementById('color_format');
 const rngSel=document.getElementById('rgb_quant_range');
 const ycc444=fmtSel?Array.from(fmtSel.options||[]).find(o=>o.value==='1'&&!o.disabled):null;
 if(ycc444){
  fmtSel.value='1';
  if(rngSel) rngSel.value='1';
  if(typeof updateDropdowns==='function') updateDropdowns();
  if(rngSel) rngSel.value='1';
  if(typeof checkSettingsChanged==='function') checkSettingsChanged();
 }
 const applyBar=document.getElementById('applyBar');
 if(applyBar&&applyBar.scrollIntoView){
  try{ applyBar.scrollIntoView({behavior:'smooth',block:'center'}); }catch(e){ applyBar.scrollIntoView(); }
 }
	 toast(ycc444
		  ? 'LG extended greyscale uses 16-255 video-code patches. Apply & Restart to use YCbCr 4:4:4 limited transport so 236-255 are preserved.'
		  : 'LG extended greyscale needs YCbCr 4:4:4 limited transport to preserve 236-255 video-code patches, but this mode is not available for the current output.',
	 true);
	 return false;
	}

function meterEnsureLgAutoCalExtendedVideoTransport(){
 if(!meterLgAutoCalUsesExtendedSdr()||meterExtendedVideoTransportCanCarryHeadroom()) return true;
 const fmtSel=document.getElementById('color_format');
 const rngSel=document.getElementById('rgb_quant_range');
 const ycc444=fmtSel?Array.from(fmtSel.options||[]).find(o=>o.value==='1'&&!o.disabled):null;
 if(ycc444){
  fmtSel.value='1';
  if(rngSel) rngSel.value='1';
  if(typeof updateDropdowns==='function') updateDropdowns();
  if(rngSel) rngSel.value='1';
  if(typeof checkSettingsChanged==='function') checkSettingsChanged();
 }
 const applyBar=document.getElementById('applyBar');
 if(applyBar&&applyBar.scrollIntoView){
  try{ applyBar.scrollIntoView({behavior:'smooth',block:'center'}); }catch(e){ applyBar.scrollIntoView(); }
 }
 toast(ycc444
	  ? 'LG Auto Cal uses 16-255 video-code patches. Apply & Restart to use YCbCr 4:4:4 limited transport so 236-255 are preserved.'
	  : 'LG Auto Cal needs YCbCr 4:4:4 limited transport to preserve 236-255 video-code patches, but this mode is not available for the current output.',
  true);
 return false;
}

function meterGreyscaleUsesFullSourceRange(){
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 return meterActiveSeriesType==='greyscale' && mode==='sdr' && !meterPatchUsesVideoRange() && !meterLgGreyscaleUsesLegalSdrDdcCodes(meterActiveSeriesPoints);
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

function meterSdrRgbChromaUsesFullSourceRange(){
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 return mode==='sdr' && meterOutputIsRgb() && !meterPatchUsesVideoRange();
}

function meterChromaPatchRangeMin(){
 return meterSdrRgbChromaUsesFullSourceRange()?0:meterPatchRangeMin();
}

function meterChromaPatchRangeSpan(){
 return meterSdrRgbChromaUsesFullSourceRange()?255:meterPatchRangeSpan();
}

function meterDvRelativeSt2084UsesLegalRange(){
 const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
 return meterChartIsDv() && meterDvMapModeValue()==='2' && sel==='st2084';
}

function meterGreyCodeRange(){
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return {min:16,span:219};
 if(meterDvRelativeSt2084UsesLegalRange()) return {min:16,span:219};
 if(meterLgGreyscaleUsesExtendedSdr(meterActiveSeriesPoints)) return {min:16,span:239};
 if(meterLgGreyscaleUsesLegalSdrDdcCodes(meterActiveSeriesPoints)) return {min:16,span:219};
 if(meterGreyscaleUsesFullSourceRange()) return {min:0,span:255};
 return {min:meterPatchRangeMin(),span:meterPatchRangeSpan()};
}

function meterGreySignalFractionFromCode(code){
 const numeric=Number(code);
 if(Number.isFinite(numeric)&&meterGreyAllowsHeadroomTargets()){
  return Math.max(0,Math.min(1.1,(numeric-64)/876));
 }
 if(Number.isFinite(numeric)&&numeric>255){
  return Math.max(0,Math.min(1.1,(numeric-64)/876));
 }
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
 // With the corrected DV transport/range path, Absolute chart targets should
 // rise to the measured peak across the full 0-100% range rather than
 // flattening at 75%.
 return 1;
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
 return meterCodeFromSignalPercentWithOptions(percent,null);
}

function meterLgSdrExtendedCodeFromPercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 if(clamped<=0) return 0;
 return Math.round(16+clamped*239);
}

function meterLgSdrLegalHeadroomCodeFromPercent(percent){
	 const clamped=clampNum(percent,0,109.5)/100;
	 return Math.max(64,Math.min(1023,Math.round(64+clamped*876)));
}

function meterLgAutoCalStimulusFromCode(code){
	 const numeric=Number(code);
	 if(!Number.isFinite(numeric)) return 0;
	 return Math.max(0,(numeric-64)*100/876);
}

function meterLgAutoCalCodeForSlot(slot){
 const idx=METER_LG_GREY_AUTOCAL_26_SLOTS.findIndex(v=>Math.abs(Number(v)-Number(slot))<0.001);
 return idx>=0?METER_LG_GREY_AUTOCAL_26_CODES[idx]:meterLgSdrLegalHeadroomCodeFromPercent(slot);
}

function meterLgSdrLegalDdcCodeFromPercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 if(clamped<=0) return 0;
 return Math.round(16+clamped*219);
}

function meterLgSdrLegalStimulusFromCode(code){
 const numeric=Number(code);
 if(!Number.isFinite(numeric)) return 0;
 if(numeric<=16) return 0;
 return Math.round(Math.max(0,Math.min(100,(numeric-16)*100/219))*10000)/10000;
}

function meterCodeFromSignalPercentWithOptions(percent,opts){
 opts=opts||{};
 if(opts.lgExtendedSdr) return meterLgSdrExtendedCodeFromPercent(percent);
 if(opts.lgLegalSdrDdc) return meterLgSdrLegalDdcCodeFromPercent(percent);
 const clamped=clampNum(percent,0,100)/100;
 const range=meterGreyCodeRange();
 if(meterChartIsDv()){
  const dvAbsolute=meterDvMapModeValue()==='1';
  const sel=(document.getElementById('meterTargetGamma')||{}).value||meterDvAutoTargetGamma();
  if(dvAbsolute){
  if(meterPatchUsesVideoRange()) return Math.round(range.min+clamped*range.span);
  if(clamped<=0) return 0;
  if(clamped>=1) return 255;
  return Math.round(range.min+clamped*range.span);
  }
  if(sel==='st2084'){
   return Math.round(range.min+clamped*range.span);
  }
  const encoded=clamped>0?Math.pow(clamped,1/meterDvTunnelGamma()):0;
  return Math.round(meterPatchRangeMin()+encoded*meterPatchRangeSpan());
 }
 return Math.round(range.min+clamped*range.span);
}

function meterActualSignalPercent(percent){
 return meterGreySignalFractionFromCode(meterCodeFromSignalPercent(percent))*100;
}

function meterActualCodePercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 const range=meterGreyCodeRange();
 const code=Math.round(range.min+clamped*range.span);
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
  if(rd.synthetic_target) return false;
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
 const preferredKeys=['greyscale-100','greyscale-2','greyscale-21','greyscale-11','saturations-24','colors-30'];
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

function meterSyntheticGreyWhiteReading(luminance){
 const value=Number(luminance);
 if(!(Number.isFinite(value)&&value>0)) return null;
 const wp=meterTargetWhitePoint();
 return {X:wp.X*value,Y:value,Z:wp.Z*value,luminance:value,x:wp.x,y:wp.y,cct:null,synthetic_target:true};
}

function meterStoreLgTargetWhiteReference(value,source,runId){
 const y=Number(value);
 if(!(Number.isFinite(y)&&y>0)) return;
 try{
  localStorage.setItem('pgen.meter.lgTargetWhiteReference',JSON.stringify({
   luminance:y,
   source:source||'lg-autocal',
   run_id:runId||null,
   signal_mode:String((meterChartSignalMode&&meterChartSignalMode())||'sdr').toLowerCase(),
   updated_at:Date.now()
  }));
 }catch(e){}
}

function meterStoredLgTargetWhiteReferenceNits(){
 try{
  const raw=localStorage.getItem('pgen.meter.lgTargetWhiteReference')||'';
  if(!raw) return null;
  const parsed=JSON.parse(raw)||{};
  const mode=String(parsed.signal_mode||'sdr').toLowerCase();
  const current=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
  if(mode&&current&&mode!==current) return null;
  const y=Number(parsed.luminance);
  return (Number.isFinite(y)&&y>0)?y:null;
 }catch(e){ return null; }
}

function meterExplicitLgTargetWhiteReferenceNits(readings){
 const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
 for(const rd of list){
  const y=Number(rd&&(rd.autocal_white_y!=null?rd.autocal_white_y:(rd.lg_target_white_y!=null?rd.lg_target_white_y:rd.series_target_white_y)));
  if(Number.isFinite(y)&&y>0) return y;
 }
 return null;
}

function meterLgTargetWhiteReferenceNits(readings){
 const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
 const explicit=meterExplicitLgTargetWhiteReferenceNits(list);
 if(explicit>0) return explicit;
 const cfg=Number(meterFullAutoCalConfig&&meterFullAutoCalConfig.targetY);
 if(Number.isFinite(cfg)&&cfg>0) return cfg;
 try{
  if((typeof meterChartIsHdr==='function'&&meterChartIsHdr())||(typeof meterChartIsDv==='function'&&meterChartIsDv())) return null;
 }catch(e){}
 const state=window.lgStatusState||{};
 const connected=!!((state.paired||state.clientKeyPresent)&&!state.pinPending);
 if(!connected) return null;
 return meterStoredLgTargetWhiteReferenceNits();
}

function meterColorSeriesUsesLgTargetWhite(type){
 const t=String(type||'').toLowerCase();
 return t==='colors'||t==='saturations';
}

function meterColorSeriesTargetWhiteForRun(type){
 if(!meterColorSeriesUsesLgTargetWhite(type||meterActiveSeriesType)) return null;
 const phase=String(meterFullAutoCalPhase||'');
 if(meterFullAutoCalRunning&&phase==='precal-report') return null;
 const cfg=Number(meterFullAutoCalConfig&&meterFullAutoCalConfig.targetY);
 if(Number.isFinite(cfg)&&cfg>0) return cfg;
 try{
  if((typeof meterChartIsHdr==='function'&&meterChartIsHdr())||(typeof meterChartIsDv==='function'&&meterChartIsDv())) return null;
 }catch(e){}
 const state=window.lgStatusState||{};
 const connected=!!((state.paired||state.clientKeyPresent)&&!state.pinPending);
 if(!connected) return null;
 return meterStoredLgTargetWhiteReferenceNits();
}

function meterApplyColorSeriesTargetWhiteReference(steps,type){
 if(!Array.isArray(steps)||!meterColorSeriesUsesLgTargetWhite(type)) return steps;
 const targetY=Number(meterColorSeriesTargetWhiteForRun(type));
 if(!(Number.isFinite(targetY)&&targetY>0)) return steps;
 steps.forEach(step=>{
  if(!step) return;
  step.series_target_white_y=targetY;
  step.lg_target_white_y=targetY;
 });
 return steps;
}

function meterEffectiveGreyscaleWhiteReference(readings){
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 const targetY=meterLgTargetWhiteReferenceNits(list);
 if(targetY>0){
  const synthetic=meterSyntheticGreyWhiteReading(targetY);
  if(synthetic) return synthetic;
 }
 const white=meterFindSeriesWhiteReading(list);
 if(white) return white;
 const cached=meterWhiteReading&&!meterWhiteReading.synthetic_target?meterReadingXYZ(meterWhiteReading):null;
 if(cached&&cached.Y>0) return meterWhiteReading;
 const measured=meterFindMeasuredWhiteReading();
 const measuredXyz=measured&&!measured.synthetic_target?meterReadingXYZ(measured):null;
 if(measuredXyz&&measuredXyz.Y>0) return measured;
 const fallbackY=Number(meterColorReferenceNits());
 if(Number.isFinite(fallbackY)&&fallbackY>0){
  const synthetic=meterSyntheticGreyWhiteReading(fallbackY);
  if(synthetic) return synthetic;
 }
 if(list.length>0){
  const brightest=[...list].sort((a,b)=>(meterReadingLuminanceNits(b)||0)-(meterReadingLuminanceNits(a)||0))[0];
  const measured=meterReadingLuminanceNits(brightest);
  const ire=Math.max(1,Number((brightest&&brightest.ire)||100)||100);
  if(measured>0){
   let inferred=measured;
   if(ire<100){
    const frac=Math.max(targetEotf(ire/100,1,0),0.02);
    inferred=measured/frac;
   }
   const synthetic=meterSyntheticGreyWhiteReading(inferred);
   if(synthetic) return synthetic;
  }
 }
 return null;
}

function meterGreyscaleChartWhiteReference(readings){
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 return meterEffectiveGreyscaleWhiteReference(list);
}

function meterColorReferenceNits(){
 if(meterChartIsDv()){
  // DV relative uses the measured white reference when available, but DV
  // absolute keeps its target luminance anchored to mastering peak. The warm
  // white pre-read remains diagnostic-only for absolute mode.
  const master=Math.max(1,meterChartMasterPeak());
  if(meterDvMapModeValue()==='1') return master;
  const white=meterFindMeasuredWhiteReading();
  const measured=meterReadingLuminanceNits(white)||master;
  return Math.max(1,Math.min(master,measured));
 }
 const white=meterFindMeasuredWhiteReading();
 const measured=meterReadingLuminanceNits(white);
 if(measured>0) return measured;
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartHdrPeak();
 if(meterChartIsHdr()) return meterChartHdrPeak();
 return 100;
}

function meterColorSeriesReferenceNits(){
	 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
	  // DV Absolute target luminance stays anchored to mastering peak. The
	  // white pre-read is still useful diagnostically, but it is not the target
	  // Y reference for color or saturation patches in absolute mode.
	  return Math.max(1,meterColorReferenceNits());
	 }
 const explicitLgTarget=meterExplicitLgTargetWhiteReferenceNits(meterReadings);
 if(explicitLgTarget>0) return Math.max(1,explicitLgTarget);
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
  const measured=(white.luminance!=null)?white.luminance:white.Y;
  if(meterChartIsDv()) return Math.max(1,Math.min(Math.max(1,meterChartMasterPeak()),measured));
  return Math.max(1,measured);
 }
 const lgTarget=meterColorSeriesTargetWhiteForRun(meterActiveSeriesType);
 if(lgTarget>0) return Math.max(1,lgTarget);
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
 const wp=meterTargetWhitePoint();
 return {X:wp.X*refY,Y:refY,Z:wp.Z*refY};
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
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
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
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
 if(!active) return min;
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(100)*span);
 return min+span;
}

function meterFullSatChannelIsActive(linear){
 return Number(linear||0) > 1e-6;
}

function meterEncodeSaturationLinear(linear,colorName){
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
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
 const wp=meterTargetWhitePoint();
 const wx=wp.x, wy=wp.y;
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
 const wp=meterTargetWhitePoint();
 const wx=wp.x, wy=wp.y;
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
 const wp=meterTargetWhitePoint();
 return sum>0?{x:xyz.X/sum,y:xyz.Y/sum}:{x:wp.x,y:wp.y};
}

function meterBuildSaturationTargetLinearRgb(colorName,satPercent){
 const solveGamut=meterAnalysisGamut();
 const sat=Math.max(0,Math.min(100,satPercent||0))/100;
 const endpoint=meterGamutColorEndpointXY(colorName,meterSaturationAxisGamut());
 const wp=meterTargetWhitePoint();
 const x=wp.x+sat*(endpoint.x-wp.x);
 const y=wp.y+sat*(endpoint.y-wp.y);
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 const level=meterSaturationStimulusLinearLevel(colorName);
 return coeffs.map(v=>Math.max(0,v/maxCoeff)*level);
}

function meterBuildSaturationTargetStepMeta(colorName,satPercent){
 const rgb=meterBuildSaturationTargetLinearRgb(colorName,satPercent);
 const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],meterTargetSolveGamut().rgbToXyz);
 const sum=xyz.X+xyz.Y+xyz.Z;
 const wp=meterTargetWhitePoint();
 return {
  target_x:sum>0?xyz.X/sum:wp.x,
  target_y:sum>0?xyz.Y/sum:wp.y,
  target_Yn:Math.max(0,xyz.Y||0)
 };
}

function meterBuildSaturationStimulusLinearRgb(colorName,satPercent){
 const solveGamut=meterSaturationSolveGamut();
 const axisGamut=meterSaturationAxisGamut();
 let sat=Math.max(0,Math.min(100,satPercent||0))/100;
 if(meterChartIsDv()) sat=(meterDvMapModeValue()==='1') ? meterDvAbsoluteSaturationFraction(colorName,sat) : meterDvRelativeSaturationFraction(sat);
 const endpoint=meterGamutColorEndpointXY(colorName,axisGamut);
 const wp=meterTargetWhitePoint();
 const x=wp.x+sat*(endpoint.x-wp.x);
 const y=wp.y+sat*(endpoint.y-wp.y);
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
 // Use the same per-mode luminance reference as target_Yn-based color
 // patches so saturation sweeps and color series stay aligned.
 let scale=meterColorSeriesReferenceNits();
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
 return meterTargetSignalToLinear(norm)*meterColorSeriesReferenceNits();
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
 const wp=meterTargetWhitePoint();
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:wp.x,y:wp.y};
}

function meterTargetXYZForReading(reading){
	 if(!reading) return {X:0,Y:0,Z:0};
	 const absX=Number(reading.target_X);
	 const absY=Number(reading.target_Y);
	 const absZ=Number(reading.target_Z);
	 if(Number.isFinite(absX)&&Number.isFinite(absY)&&Number.isFinite(absZ)&&absY>=0){
	  return {X:absX,Y:absY,Z:absZ};
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
	 if(meterActiveSeriesType==='colors' && reading.series_color && reading.sat_pct!=null){
	  return meterColorCheckerFullSatTargetXYZ(String(reading.series_color));
	 }
	 const satInfo=meterParseSaturationReading(reading);
	 if(satInfo){
	  if(meterActiveSeriesType==='colors' && satInfo.sat===100){
	   return meterColorCheckerFullSatTargetXYZ(satInfo.color);
  }
  return meterSaturationTargetXYZ(satInfo.color,satInfo.sat);
 }
 if(meterReadingIsGreyscale(reading)){
  const wp=meterTargetWhitePoint();
  let refWhite=null;
  try{ refWhite=meterGreyscaleChartWhiteReference(meterReadings); }catch(e){}
  const refY=refWhite?meterReadingLuminanceNits(refWhite):null;
  const peak=meterGreyTargetPeak((refY>0)?refY:meterColorReferenceNits());
  const black=meterBlackReadingY();
  const ire=meterReadingAnalysisIre(reading);
  const code=(reading.r_code!=null)?reading.r_code:reading.r;
  const Y=meterGreyTargetLuminance(ire!=null?ire:(reading.ire||0),peak,black||0,code);
  return {X:wp.X*Y,Y:Y,Z:wp.Z*Y};
 }
 return targetColorXYZAbs(reading.r_code,reading.g_code,reading.b_code);
}

function meterTargetChromaticityForReading(reading){
 const xyz=meterTargetXYZForReading(reading);
 const s=xyz.X+xyz.Y+xyz.Z;
 const wp=meterTargetWhitePoint();
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:wp.x,y:wp.y};
}

function meterIreIsPeakHeadroom(ire){
 ire=Number(ire);
 return Number.isFinite(ire) && ire>=108.5;
}

function meterReadingIsPeakHeadroom(reading){
 if(!reading || !meterReadingIsGreyscale(reading)) return false;
 const raw=(reading.nominal_ire!=null)?reading.nominal_ire:(reading.plot_ire!=null?reading.plot_ire:(reading.ire!=null?reading.ire:reading.stimulus));
 return meterIreIsPeakHeadroom(raw);
}

function meterColorDeltaTargetXYZ(reading,inclLum){
 const xyz=meterTargetXYZForReading(reading);
 const measured=meterReadingXYZ(reading);
 if(meterReadingIsPeakHeadroom(reading) && measured && measured.Y>0){
  const wp=meterTargetWhitePoint();
  return {X:wp.X*measured.Y,Y:measured.Y,Z:wp.Z*measured.Y};
 }
 if(inclLum||!measured||!(measured.Y>0)) return xyz;
 if(!(xyz.Y>0)){
  if(meterReadingIsGreyscale(reading)){
   const wp=meterTargetWhitePoint();
   return {X:wp.X*measured.Y,Y:measured.Y,Z:wp.Z*measured.Y};
  }
  return xyz;
 }
 const scale=measured.Y/xyz.Y;
 return {X:xyz.X*scale,Y:measured.Y,Z:xyz.Z*scale};
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
 meterNormalizeMeasuredReading(reading);
 if(reading.luminance!=null) return reading.luminance;
 if(reading.Y!=null) return reading.Y;
 return null;
}

function meterReadingXYZ(reading){
 if(!reading) return null;
 meterNormalizeMeasuredReading(reading);
 const Y=meterReadingLuminanceNits(reading);
 if(!(Y>0)) return null;
 if(reading.X!=null && reading.Y!=null && reading.Z!=null) return {X:reading.X,Y:reading.Y,Z:reading.Z};
 const x=(reading.x!=null)?Number(reading.x):NaN;
 const y=(reading.y!=null)?Number(reading.y):NaN;
 if(Number.isFinite(x) && Number.isFinite(y) && y>0){
  return {X:(x/y)*Y,Y,Z:((1-x-y)/y)*Y};
 }
 if(meterReadingIsGreyscale(reading)){
  const wp=meterTargetWhitePoint();
  return {X:wp.X*Y,Y,Z:wp.Z*Y};
 }
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
 if(meterReadingIsGreyscale(reading)) return false;
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
  const wp=meterTargetWhitePoint();
  const XnM=(ref.wxN||wp.X)*ref.YWhite, YnM=ref.YWhite, ZnM=(ref.wzN||wp.Z)*ref.YWhite;
  const XnR=(ref.wxN||wp.X)*ref.YWhiteRef, YnR=ref.YWhiteRef, ZnR=(ref.wzN||wp.Z)*ref.YWhiteRef;
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
 const xyz=meterReadingXYZ(reading);
 const useColorForm=meterReadingUsesColorDeltaForm(reading);
 form = form || (useColorForm ? meterColorDeltaEForm() : meterDeltaEForm());
 if(gwWeight==null) gwWeight = meterGrayWorldWeight();
 if(!useColorForm && meterReadingIsGreyscale(reading) && xyz && xyz.Y>0){
  return meterGreyDeltaResult(reading,modeOrIncl,form,gwWeight).value;
 }
 if(!xyz||!(xyz.Y>0)) return useColorForm ? NaN : 0;
 const wR=meterColorLabWhite();
 const mode=meterResolveGreyRefMode(modeOrIncl);
 const target=meterColorDeltaTargetXYZ(reading, mode==='eotf');
 const labM=xyzToLab(xyz.X,xyz.Y,xyz.Z,wR.X,wR.Y,wR.Z);
 const labT=xyzToLab(target.X,target.Y,target.Z,wR.X,wR.Y,wR.Z);
 return meterDeltaE(labM,labT,form,{
  isGrey:false,
  Ym:xyz.Y, Yref:target.Y||0,
  X:xyz.X, Y:xyz.Y, Z:xyz.Z, YWhite:wR.Y,
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
 const readingXYZ=meterReadingXYZ(reading);
 const whiteXYZ=meterReadingXYZ(whiteReading);
 const prevXYZ=prevReading?meterReadingXYZ(prevReading):null;
 if(!readingXYZ||!whiteXYZ) return {r:null,g:null,b:null};
 const g=meterAnalysisGamut();
 const rm=xyzToLinRgb(readingXYZ.X,readingXYZ.Y,readingXYZ.Z,g.xyzToRgb);
 const rw=xyzToLinRgb(whiteXYZ.X,whiteXYZ.Y,whiteXYZ.Z,g.xyzToRgb);
 const prevRgb=prevXYZ?xyzToLinRgb(prevXYZ.X,prevXYZ.Y,prevXYZ.Z,g.xyzToRgb):null;
 const exp=(m,w,pm)=>{
 if(!(w>0)) return null;
 if(ire>=100){
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

function meterGammaValueWhiteReference(readings){
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 const seriesWhite=meterFindSeriesWhiteReading(list);
 if(seriesWhite) return seriesWhite;
 const measured=meterFindMeasuredWhiteReading();
 if(measured) return measured;
 return meterEffectiveGreyscaleWhiteReference(list);
}

function meterGammaValueReferenceY(readings){
 const white=meterGammaValueWhiteReference(readings);
 const y=white?meterReadingLuminanceNits(white):null;
 if(y>0) return y;
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 const measuredPeak=meterFilterEotfLuminanceChartItems(list).reduce((mx,r)=>Math.max(mx,meterReadingLuminanceNits(r)||0),0);
 return measuredPeak>0?measuredPeak:0;
}

function meterGreyscaleGammaValue(reading,whiteY){
 if(!reading) return null;
 const y=meterReadingLuminanceNits(reading);
 const analysisIre=meterReadingAnalysisIre(reading);
 if(!(whiteY>0) || !(y>0) || !(analysisIre>0) || analysisIre>=100) return null;
 return effectiveGamma(y,whiteY,analysisIre);
}

function meterEnsureChannelGammaCache(readings){
 if(!Array.isArray(readings)) return;
 const greys=readings.filter(rd=>rd&&meterReadingIsGreyscale(rd)).sort((a,b)=>(a.ire||0)-(b.ire||0));
 const white=meterGammaValueWhiteReference(greys);
 greys.forEach((rd,idx)=>{
  const prev=idx>0?greys[idx-1]:null;
  rd._gamma_rgb=meterPerChannelGamma(rd,white,meterReadingAnalysisIre(rd)||rd.ire||0,prev);
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
	 const min=meterChromaPatchRangeMin();
	 const max=min+meterChromaPatchRangeSpan();
	 const solveGamut=meterChartIsDv()?meterAnalysisGamut():meterStimulusSolveGamut();
	 const wp=meterTargetWhitePoint();
	 steps.push({ire:100,r:max,g:max,b:max,name:'White',target_x:wp.x,target_y:wp.y,target_Yn:1});
	 steps.push({ire:0,r:min,g:min,b:min,name:'Black',target_x:wp.x,target_y:wp.y,target_Yn:0});
	 meterColorCheckerClassicSource().forEach(src=>{
	  if(src.gray!=null){
	   const ire=Math.round(src.gray*100);
	   const code=meterEncodeColorCheckerLinear(src.gray);
	   let targetYn=src.gray;
	   if(meterChartIsDv()){
	    const span=meterChromaPatchRangeSpan();
	    const signal=span>0?(code-meterChromaPatchRangeMin())/span:0;
	    targetYn=Math.max(0,meterDecodeColorCheckerSignal(signal));
	   }
	   steps.push({ire:ire,r:code,g:code,b:code,name:src.name,target_x:wp.x,target_y:wp.y,target_Yn:targetYn});
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
    const min=meterChromaPatchRangeMin();
    const span=meterChromaPatchRangeSpan();
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
  const target=meterBuildSaturationTargetStepMeta(colorName,100);
  steps.push({
   ire:100,
   r:rgb[0],
   g:rgb[1],
   b:rgb[2],
   name:name,
   series_color:colorName,
   sat_pct:100,
   ...target
  });
 });
 return steps;
}

function meterStepNameKey(step){
 if(!step) return '';
 const plotIre=meterReadingPlotIre(step);
 return step.name||(((plotIre!=null)?plotIre:((step.ire!=null)?step.ire:''))+'-'+(step.r||0)+'-'+(step.g||0)+'-'+(step.b||0));
}

function meterSeriesStepIsGreyscale(step){
 if(!step) return false;
 if(String(step.series_type||'').toLowerCase()==='greyscale') return true;
 const r=step.r;
 const g=step.g;
 const b=step.b;
 return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
}

function meterGreyscaleStepSortValue(step){
 if(!step) return 0;
 if(meterUseLgAutoCal26(meterActiveSeriesPoints)&&String(step.series_mode||'')==='lg-autocal-26'){
  const candidates=[step.stimulus,step.signal_r_pct,step.patch_stimulus,step.ire];
  for(const value of candidates){
   const numeric=Number(value);
   if(Number.isFinite(numeric)) return numeric;
  }
 }
 const ire=Number(step.ire);
 return Number.isFinite(ire)?ire:0;
}

function meterGreyscaleSeriesSteps(steps){
 return (Array.isArray(steps)?steps:[]).filter(step=>meterSeriesStepIsGreyscale(step)).sort((a,b)=>{
  const av=meterGreyscaleStepSortValue(a);
  const bv=meterGreyscaleStepSortValue(b);
  if(Math.abs(av-bv)>0.0001) return av-bv;
  return (Number(a&&a.ire)||0)-(Number(b&&b.ire)||0);
 });
}

function meterLgAutoCalChartReferenceWhite(item){
 if(!item||meterActiveSeriesType!=='greyscale'||!meterUseLgAutoCal26(meterActiveSeriesPoints)) return false;
 const plotIre=meterReadingPlotIre(item);
 const ire=Number(plotIre!=null?plotIre:item.ire);
 return Number.isFinite(ire)&&Math.abs(ire-100)<0.001;
}

function meterFilterLgAutoCalChartItems(items){
 const list=Array.isArray(items)?items:[];
 return list.filter(item=>!meterLgAutoCalChartReferenceWhite(item));
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
 if(String(reading.series_type||'').toLowerCase()==='greyscale') return true;
 const r=reading.r_code!=null?reading.r_code:reading.r;
 const g=reading.g_code!=null?reading.g_code:reading.g;
 const b=reading.b_code!=null?reading.b_code:reading.b;
 return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
}

function meterGreyscaleReadings(readings){
 return (Array.isArray(readings)?readings:[]).filter(rd=>meterReadingHasLuminance(rd)&&meterReadingIsGreyscale(rd)).map(rd=>{
  const plotIre=meterReadingPlotIre(rd);
  if(plotIre==null) return rd;
  const current=Number(rd.ire);
  if(Number.isFinite(current)&&Math.abs(current-plotIre)<0.001) return rd;
  return Object.assign({},rd,{ire:plotIre});
 }).sort((a,b)=>(meterReadingPlotIre(a)||0)-(meterReadingPlotIre(b)||0));
}

function meterGreyscaleReadingMap(readings){
 const map={};
 meterGreyscaleReadings(readings).forEach(rd=>{
  const plotIre=meterReadingPlotIre(rd);
  if(plotIre!=null) map[plotIre]=rd;
 });
 return map;
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
 if(mode==='measured'){
  const xyz=meterReadingXYZ(reading);
  if(xyz&&xyz.Y>0) return meterPreviewCssFromXYZ(xyz.X,xyz.Y,xyz.Z,true);
  return '#111';
 }
 const target=meterTargetXYZForReading(reading);
 if(target&&target.Y>0) return meterPreviewCssFromXYZ(target.X,target.Y,target.Z,true);
 return meterSignalPreviewColor(r,g,b);
}

function meterPreviewColorForStep(step){
 if(!step) return '#aaa';
 return meterPreviewColorForReading({
  r_code:step.preview_r!=null?step.preview_r:step.r,
  g_code:step.preview_g!=null?step.preview_g:step.g,
  b_code:step.preview_b!=null?step.preview_b:step.b,
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
 return 'perceptual';
}

// Perceptual RGB balance: linearRGB → L*, diff + 100.
// The ire>0 branch builds a luminance-compensated target (chroma-only) in
// 'absolute'/'relative' modes, or an absolute target in 'eotf' mode.
function rgbBalancePerceptual(reading,whiteRef,modeOrIncl){
 const readingXYZ=meterReadingXYZ(reading);
 const whiteXYZ=meterReadingXYZ(whiteRef);
 if(!readingXYZ||!whiteXYZ||whiteXYZ.Y<=0) return {R:100,G:100,B:100};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 // Use the absolute D65 white target for greyscale RGB balance in all modes
 // so HDR/DV 100% white shows its real white-point error instead of being
 // pinned to 100/100/100 by self-normalizing to the measured white.
 const wp = meterTargetWhitePoint();
 const wXn = wp.X;
 const wZn = wp.Z;
 // Measured XYZ normalized by white Y
 const mXn=readingXYZ.X/whiteXYZ.Y, mYn=readingXYZ.Y/whiteXYZ.Y, mZn=readingXYZ.Z/whiteXYZ.Y;
 const ire=reading.ire;
 let lcXn,lcYn,lcZn;
 if(ire!=null&&ire>0){
 // Target: D65 white at the active grey-target luminance.
  const Lw=meterChartIsHdr()?meterGreyTargetPeak(whiteXYZ.Y):whiteXYZ.Y, Lb=0;
  const tgtLum=meterReadingIsPeakHeadroom(reading) ? readingXYZ.Y : meterGreyTargetLuminance(ire,Lw,Lb,reading.r_code);
  const tYn=tgtLum/whiteXYZ.Y;
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

// HCFR-style RGB balance (mirrors RGBLevelWnd.cpp luma-mode-OFF branch).
// Modes 0 and 2 both use a unit-Y XYZ built from the measured chromaticity;
// only mode 1 (Absolute Y w/gamma) rescales by measuredY / targetY.
function rgbBalanceHCFR(reading,whiteRef,modeOrIncl){
 const readingXYZ=meterReadingXYZ(reading);
 const whiteXYZ=meterReadingXYZ(whiteRef);
 if(!readingXYZ||!whiteXYZ||whiteXYZ.Y<=0) return {R:100,G:100,B:100};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 const s = readingXYZ.X+readingXYZ.Y+readingXYZ.Z;
 if(!(s>0)) return {R:100,G:100,B:100};
 const x = readingXYZ.X/s, y = readingXYZ.Y/s;
 if(!(y>0)) return {R:100,G:100,B:100};
 let fact = 1.0;
 if(mode==='eotf'){
  if(meterReadingIsPeakHeadroom(reading)){
   fact = 1.0;
  } else {
   const Lb = meterBlackReadingY();
   const targetPeak = meterChartIsHdr() ? meterGreyTargetPeak(whiteXYZ.Y) : whiteXYZ.Y;
   const tgtY = meterGreyTargetLuminance(reading.ire, targetPeak, Lb, reading.r_code);
   fact = (tgtY>0 && whiteXYZ.Y>0 && readingXYZ.Y>0) ? readingXYZ.Y / tgtY : 1.0;
  }
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
  : rgbBalancePerceptual(reading,whiteRef,modeOrIncl);
}

function meterLiveRgbData(reading){
 if(!reading) return {mode:'balance',R:100,G:100,B:100};
 const measured=meterReadingXYZ(reading);
 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(!isColorSeries||!measured||!(measured.Y>0)){
  const whiteRef=meterEffectiveGreyscaleWhiteReference(Array.isArray(meterReadings)&&meterReadings.length?meterReadings:[reading]);
  return whiteRef?{mode:'balance',...rgbBalance(reading,whiteRef,meterGreyRefMode())}:{mode:'balance',R:100,G:100,B:100};
 }
 const gamut=meterAnalysisGamut();
 const target=meterColorDeltaTargetXYZ(reading,meterColorIncludeLum());
 const mRgb=xyzToLinRgb(measured.X,measured.Y,measured.Z,gamut.xyzToRgb);
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
 if(frac>=0.999999) return null;
 const g=Math.log(Y/Yw)/Math.log(frac);
 return isFinite(g)?g:null;
}

function effectiveGammaTopSlope(Y,Yw,ire,prevY,prevIre){
 const g=effectiveGamma(Y,Yw,ire);
 if(g!=null&&isFinite(g)) return g;
 const prevFrac=(prevIre>1)?(prevIre/100):prevIre;
 if(prevY>0 && Yw>0 && prevFrac>0 && prevFrac<0.999999){
  const gTop=Math.log(prevY/Yw)/Math.log(prevFrac);
  return isFinite(gTop)?gTop:null;
 }
 return null;
}

function meterGammaPreviousSeriesReading(reading,xSteps,readingMap){
 if(!reading||!Array.isArray(xSteps)||!readingMap) return null;
 const ire=Number(reading.ire);
 if(!(ire>=100)) return null;
 const key=meterStepNameKey(reading);
 const idx=xSteps.findIndex(step=>{
  if(key&&meterStepNameKey(step)===key) return true;
  const stepIre=Number(step&&step.ire);
  return Number.isFinite(ire)&&Number.isFinite(stepIre)&&Math.abs(stepIre-ire)<0.001;
 });
 if(idx<=0) return null;
 const prevStep=xSteps[idx-1];
 return (prevStep&&readingMap[prevStep.ire])?readingMap[prevStep.ire]:null;
}

function meterDvRelativeWhiteGamma(whiteY,peak){
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
 const pct=Math.max(0,Math.min(meterGreyAllowsHeadroomTargets()?110:100,ire||0));
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
 if(code!=null&&(meterChartIsHdr()||meterGreyAllowsHeadroomTargets())) return meterGreySignalFractionFromCode(code);
 const nominal=Math.max(0,Math.min(meterGreyAllowsHeadroomTargets()?1.1:1,(ire||0)/100));
 if(meterChartIsPq()) return meterGreyStimulusFraction(ire);
 return nominal;
}

function meterGreyInputFraction(ire,code){
 const nominal=Math.max(0,Math.min(1,(ire||0)/100));
 if(code!=null && meterChartIsHdr()) return meterGreySignalFractionFromCode(code);
 return nominal;
}

const METER_HDR_DIFFUSE_WHITE_DEFAULT=94.4;

function meterDisplayTypeIsProjector(value){
 const current=String(value||((document.getElementById('meterDisplayType')||{}).value)||'').toLowerCase();
 if(current==='projector'||current==='projector_ccss') return true;
 if(current.startsWith('ccss_')||current.startsWith('custom_')){
  const source=current.startsWith('custom_')?'custom':'system';
  const name=current.replace(/^(?:ccss|custom)_/,'');
  const entry=(meterCcssLibrary||[]).find(item=>String(item&&item.source||'').toLowerCase()===source&&String(item&&item.name||'').toLowerCase()===name);
  const meta=[entry&&entry.display,entry&&entry.technology,entry&&entry.name,name].filter(Boolean).join(' ');
  return /projector/i.test(meta);
 }
 return false;
}

function meterUpdateHdrDiffuseWhiteVisibility(value){
 const wrap=document.getElementById('meterHdrDiffuseWhiteWrap');
 if(!wrap) return;
 wrap.style.display=meterDisplayTypeIsProjector(value)?'flex':'none';
}

function meterHdrDiffuseWhiteOverride(){
 if(!meterDisplayTypeIsProjector()) return null;
 const el=document.getElementById('meterHdrDiffuseWhite');
 if(!el) return null;
 const value=Number(el.value);
 if(!(Number.isFinite(value)&&value>0)) return null;
 return Math.max(1,Math.min(10000,value));
}

function meterHdrDiffuseScale(){
 const diffuse=meterHdrDiffuseWhiteOverride();
 if(!(diffuse>0)) return 1;
 if(!(meterChartIsPq&&meterChartIsPq())) return 1;
 return diffuse/METER_HDR_DIFFUSE_WHITE_DEFAULT;
}

function meterApplyHdrDiffuseOverridePeak(peak){
 const p=Number(peak);
 if(!(p>0)) return peak;
 const scale=meterHdrDiffuseScale();
 if(!(scale>0)||Math.abs(scale-1)<1e-9) return p;
 return Math.max(0.001,Math.min(10000,p*scale));
}

function meterOnHdrDiffuseWhiteChange(){
 try{ meterSaveColorPrefs(); }catch(e){}
 if(meterReadings&&meterReadings.length){
  meterOnGreyRefChange();
  return;
 }
 meterRedrawEotfChart();
 meterRedrawLuminanceChart();
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

function meterGreyHeadroomReferenceReading(readings){
 if(!meterGreyAllowsHeadroomTargets()) return null;
 const list=Array.isArray(readings)?readings:[];
 let best=null;
 list.forEach(rd=>{
  if(!rd || !meterReadingHasLuminance(rd)) return;
  const raw=(rd.plot_ire!=null)?rd.plot_ire:(rd.ire!=null?rd.ire:rd.stimulus);
  const ire=Number(raw);
  if(!Number.isFinite(ire) || ire < 108.5) return;
  const y=meterReadingLuminanceNits(rd);
  if(!(y>0)) return;
  if(!best || ire > best.ire || (Math.abs(ire-best.ire)<0.001 && y > best.y)) best={reading:rd,ire,y};
 });
 return best?best.reading:null;
}

function meterGreyStepCodeForIre(steps,ire){
 const want=Number(ire);
 if(!Number.isFinite(want)) return null;
 const list=Array.isArray(steps)?steps:[];
 const match=list.find(s=>{
  if(!s) return false;
  const raw=(s.plot_ire!=null)?s.plot_ire:(s.ire!=null?s.ire:s.stimulus);
  const got=Number(raw);
  return Number.isFinite(got)&&Math.abs(got-want)<0.01;
 });
 return match?meterGreyChartTargetCode(match):null;
}

function meterGreySolvePeakFromHeadroomReading(reading,steps,fallbackPeak,Lb){
 if(!meterGreyAllowsHeadroomTargets() || !reading) return fallbackPeak;
 const y=meterReadingLuminanceNits(reading);
 if(!(y>0)) return fallbackPeak;
 const raw=(reading.plot_ire!=null)?reading.plot_ire:(reading.ire!=null?reading.ire:reading.stimulus);
 const ire=Number(raw);
 if(!Number.isFinite(ire) || ire < 108.5) return fallbackPeak;
 const code=(reading.r_code!=null)?reading.r_code:(reading.r!=null?reading.r:meterGreyStepCodeForIre(steps,ire));
 const targetFor=peak=>meterGreyTargetLuminance(ire,peak,Lb||0,code);
 let lo=0.01;
 let hi=Math.max(Number(fallbackPeak)||0,y,100);
 while(targetFor(hi)<y && hi<10000) hi*=1.5;
 if(!(targetFor(hi)>0)) return fallbackPeak;
 for(let i=0;i<40;i++){
  const mid=(lo+hi)/2;
  if(targetFor(mid)<y) lo=mid;
  else hi=mid;
 }
 const peak=(lo+hi)/2;
 return (peak>0&&isFinite(peak))?peak:fallbackPeak;
}

function meterGreyTargetPeakForReadings(readings,steps,fallbackPeak,Lb){
 if(meterHdrDiffuseWhiteOverride()!=null && meterChartIsPq()) return fallbackPeak;
 const list=Array.isArray(readings)?readings:[];
 const hasMeasuredWhite=list.some(rd=>{
  if(!rd || rd.synthetic_target) return false;
  const y=Number((rd.luminance!=null)?rd.luminance:rd.Y);
  if(!(y>0)) return false;
  const raw=(rd.ire!=null)?rd.ire:(rd.plot_ire!=null?rd.plot_ire:rd.stimulus);
  const name=String(rd.name||'').toLowerCase();
  return Math.abs((Number(raw)||0)-100)<0.05 || name==='white' || !!rd.autocal_white_reference;
 });
 if(hasMeasuredWhite) return fallbackPeak;
 const peak=meterGreySolvePeakFromHeadroomReading(meterGreyHeadroomReferenceReading(readings),steps,fallbackPeak,Lb);
 return (peak>0&&isFinite(peak))?peak:fallbackPeak;
}

function meterGreyTargetChartValue(ire,Lw,Lb,code){
 return meterGreyTargetLuminance(ire,Lw,Lb,code);
}

function meterGreyTargetWhiteValue(Lw,Lb){
 return meterGreyTargetChartValue(100,Lw,Lb,meterPatchRangeMin()+meterPatchRangeSpan());
}

function meterGreyTargetEotfValue(ire,Lw,Lb,code){
 const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,code);
 return meterChartPqEncodeNormalized(tgtLum);
}

function meterGreyTargetNormalizedEotfValue(ire,Lw,Lb,code){
 const peakEotf=meterGreyTargetEotfValue(100,Lw,Lb,null);
 if(!(peakEotf>0)) return meterGreyTargetEotfValue(ire,Lw,Lb,code);
 return meterGreyTargetEotfValue(ire,Lw,Lb,code)/peakEotf;
}

function meterEotfNormalizedEnabled(){
 const el=document.getElementById('meterEotfNormalized');
 return !el || !!el.checked;
}

function meterEotfLogScaleEnabled(){
 const el=document.getElementById('meterEotfLogScale');
 return !!(el&&el.checked);
}

function meterLuminanceLogScaleEnabled(){
 const el=document.getElementById('meterLuminanceLogScale');
 return !!(el&&el.checked);
}

const METER_CHART_LOG_KNEE_DIVISOR=10000;

function meterLogScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 const knee=Math.max(top/METER_CHART_LOG_KNEE_DIVISOR,1e-9);
 return Math.log1p(val/knee)/Math.log1p(top/knee);
}

function meterLogUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 const knee=Math.max(top/METER_CHART_LOG_KNEE_DIVISOR,1e-9);
 return knee*(Math.exp(n*Math.log1p(top/knee))-1);
}

function meterEotfScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 if(meterEotfLogScaleEnabled()) return meterLogScaleValue(val,top);
 return val/top;
}

function meterEotfUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 if(meterEotfLogScaleEnabled()) return meterLogUnscaleValue(n,top);
 return n*top;
}

function meterEotfAxisLabel(v){
 const value=Number(v)||0;
 if(meterEotfNormalizedEnabled() || value <= 1.5) return value.toFixed(2);
 return value>=10 ? value.toFixed(0) : value.toFixed(2);
}

function meterGreyTargetEotfChartValue(ire,Lw,Lb,code){
 return meterEotfNormalizedEnabled()
  ? meterGreyTargetNormalizedEotfValue(ire,Lw,Lb,code)
  : meterGreyTargetEotfValue(ire,Lw,Lb,code);
}

function meterLuminanceScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 if(meterLuminanceLogScaleEnabled()) return meterLogScaleValue(val,top);
 return val/top;
}

function meterLuminanceUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 if(meterLuminanceLogScaleEnabled()) return meterLogUnscaleValue(n,top);
 return n*top;
}

function meterLuminanceAxisLabel(v){
 const value=Number(v)||0;
 if(value>=100) return value.toFixed(0);
 if(value>=10) return value.toFixed(1);
 if(value>=1) return value.toFixed(2);
 if(value>0) return value.toFixed(3);
 return '0';
}

function meterGreyMeasuredEotfValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 return meterChartPqEncodeNormalized(y);
}

function meterGreyMeasuredNormalizedEotfValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 const peakEotf=meterGreyMeasuredEotfValue(refWhite>0?refWhite:100,refWhite);
 return peakEotf>0 ? meterGreyMeasuredEotfValue(y,refWhite)/peakEotf : meterGreyMeasuredEotfValue(y,refWhite);
}

function meterGreyMeasuredEotfChartValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 return meterEotfNormalizedEnabled() ? meterGreyMeasuredNormalizedEotfValue(y,refWhite) : meterGreyMeasuredEotfValue(y,refWhite);
}

function meterEotfChartTop(values){
 const vals=(values||[]).filter(v=>v!=null&&isFinite(v)&&v>=0);
 const max=Math.max(...(vals.length?vals:[0.5]));
 if(meterEotfNormalizedEnabled() || max <= 1.5) return Math.max(0.55,Math.ceil(max*1.12*20)/20);
 return Math.ceil(max*1.1/10)*10 || max || 1;
}

function meterUpdateEotfChartLabel(){
 const lbl=document.getElementById('chartEotfLabel');
 if(!lbl) return;
 const scaled=(meterHdrDiffuseWhiteOverride()!=null && meterChartIsPq());
 if(meterEotfNormalizedEnabled()) lbl.textContent=scaled?'EOTF (normalized, diffuse)':'EOTF (normalized)';
 else lbl.textContent=scaled?'EOTF (diffuse)':'EOTF';
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
	   return effectiveGammaTopSlope(tgtLum,peak,ire,prevLum,prevStepIre);
	  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 if(meterChartIsDv() && meterDvMapModeValue()==='2' && tgt==='st2084'){
  const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
  const tgtLum=meterDvRelativeChartTargetLuminance(ire,peak);
  if(ire>=100){
   return meterDvRelativeWhiteGamma(tgtLum,peak);
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
	   return effectiveGammaTopSlope(tgtLum,peak,ire,prevLum,prevStepIre);
	  }
  return effectiveGamma(tgtLum,peak,ire);
 }
 let black=Lb||0;
 if(tgt==='bt1886'){
  // Keep the SDR gamma target consistent across 11/21/101-point greyscale
  // series. The BT.1886 black-offset shape still belongs in the luminance and
  // EOTF targets; the gamma target chart should reflect the nominal exponent.
  return 2.4;
 }
 if(tgt==='srgb') return 2.2;
 const gamma=parseFloat(tgt);
 return (gamma>0&&isFinite(gamma))?gamma:null;
}

function meterGreyTargetPeak(refWhite){
 // DV absolute and DV relative both anchor the chart target to the measured
 // 100% white so the target curve tracks what the display actually produces
 // rather than the authored mastering-peak label.
 if(meterChartIsDv()) return meterApplyHdrDiffuseOverridePeak((refWhite>0)?refWhite:meterChartMasterPeak());
 // HDR10/PQ greyscale charts should keep the same target-curve shape but
 // normalize it to the actual measured white so the target luminance and
 // EOTF views line up with the display's real peak after a series run.
 if(meterChartIsPq()) return meterApplyHdrDiffuseOverridePeak((refWhite>0)?refWhite:meterChartHdrPeak());
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

function meterGreyDenseTargetCurvePoints(targetPeak,Lb,yTop,mode,maxPct,steps){
 if(mode!=='luminance' || !meterLuminanceLogScaleEnabled()) return null;
 if(meterChartIsDv()) return null;
 const stepList=Array.isArray(steps)?steps:[];
 const end=Math.max(1,Number(maxPct)||100);
 const top=Math.max(1e-6,yTop||1);
 const rows=[];
 stepList.forEach(s=>{
  if(!s) return;
  const plot=Number(meterGreyChartPlotIre(s));
  if(!Number.isFinite(plot)) return;
  const stimulus=Number(meterGreyChartStimulusIre(s));
  const code=meterGreyChartTargetCode(s);
  const signal=meterGreyTargetSignal(Number.isFinite(stimulus)?stimulus:plot,code);
  if(!Number.isFinite(signal)) return;
  rows.push({plot:Math.max(0,Math.min(end,plot)),signal:Math.max(0,signal)});
 });
 if(rows.length<2) return null;
 if(!rows.some(row=>row.plot<=0.0001)){
  rows.push({plot:0,signal:meterGreyTargetSignal(0,meterPatchRangeMin())});
 }
 rows.sort((a,b)=>a.plot-b.plot);
 const unique=[];
 rows.forEach(row=>{
  const last=unique[unique.length-1];
  if(last&&Math.abs(last.plot-row.plot)<0.0001){
   last.signal=row.signal;
  } else {
   unique.push(Object.assign({},row));
  }
 });
 if(unique.length<2) return null;
 const pointFor=(plot,signal)=>[
  Math.max(0,Math.min(end,plot))/end,
  meterLuminanceScaleValue(meterChartTargetLuminance(signal,targetPeak,Lb||0),top)
 ];
 const pts=[];
 for(let i=0;i<unique.length-1;i++){
  const a=unique[i];
  const b=unique[i+1];
  const span=Math.max(0,b.plot-a.plot);
  const segments=Math.max(1,Math.ceil(span*4));
  for(let j=0;j<=segments;j++){
   if(i>0&&j===0) continue;
   const t=segments>0?j/segments:0;
   pts.push(pointFor(a.plot+(b.plot-a.plot)*t,a.signal+(b.signal-a.signal)*t));
  }
 }
 return pts.length>1?pts:null;
}

function meterGreyNominalTargetCurvePoints(targetPeak,Lb,yTop,mode,maxPct,steps){
 const pts=[];
 const top=Math.max(1e-6,yTop||1);
 const end=Math.max(1,Number(maxPct)||100);
 const stepList=Array.isArray(steps)?steps:[];
 const coded=stepList
  .filter(s=>s&&Number.isFinite(Number(meterGreyChartStimulusIre(s))))
  .map((s,idx)=>{
   const code=meterGreyChartTargetCode(s);
   const ire=Number(meterGreyChartStimulusIre(s));
   const x=meterGreyEotfLuminanceChartX(s,stepList,idx,end);
   const value=(mode==='eotf')
    ? meterEotfScaleValue(meterGreyTargetEotfChartValue(ire,targetPeak,Lb,code),top)
    : meterLuminanceScaleValue(meterGreyTargetChartValue(ire,targetPeak,Lb,code),top);
  return [x,value];
  })
  .filter(p=>p&&isFinite(p[0])&&isFinite(p[1]));
 if(coded.length>1){
  const dense=meterGreyDenseTargetCurvePoints(targetPeak,Lb,yTop,mode,maxPct,stepList);
  if(dense&&dense.length>1) return dense;
  const hasBlack=coded.some(p=>p[0]<=0.0001);
  if(!hasBlack){
   const value=(mode==='eotf')
    ? meterEotfScaleValue(meterGreyTargetEotfChartValue(0,targetPeak,Lb,meterPatchRangeMin()),top)
    : meterLuminanceScaleValue(meterGreyTargetChartValue(0,targetPeak,Lb,meterPatchRangeMin()),top);
   coded.unshift([0,value]);
  }
  coded.sort((a,b)=>a[0]-b[0]);
  return coded;
 }
 for(let pct=0;pct<=end;pct+=1){
  const value=(mode==='eotf')
   ? meterEotfScaleValue(meterGreyTargetEotfChartValue(pct,targetPeak,Lb,null),top)
   : meterLuminanceScaleValue(meterGreyTargetChartValue(pct,targetPeak,Lb,null),top);
  pts.push([pct/end,value]);
 }
 return pts;
}

function meterGammaAxisCenteredOnTarget(measuredVals,targetVals,isHdr){
 const measured=(measuredVals||[]).filter(v=>v!=null&&isFinite(v));
 const targets=(targetVals||[]).filter(v=>v!=null&&isFinite(v));
 const allVals=[...measured,...targets];
 if(isHdr){
  const lo=Math.min(...(allVals.length?allVals:[0.8]));
  const hi=Math.max(...(allVals.length?allVals:[3.2]));
  const axis=meterNiceLinearAxis(lo-0.2,hi+0.2,4,{clampMin:0,minSpan:0.8});
  return {min:axis.min,max:axis.max};
 }
 const center=targets.length
  ? targets.reduce((sum,v)=>sum+v,0)/targets.length
  : targetGammaValue();
 let half=0.3;
 allVals.forEach(v=>{ half=Math.max(half,Math.abs(v-center)+0.08); });
 half=Math.ceil(half*20)/20;
 return {min:center-half,max:center+half};
}

function meterGreyChartTargetCode(step){
 if(!step) return null;
 if(!meterChartIsHdr()&&!meterGreyAllowsHeadroomTargets()) return null;
 return step.r_code!=null?step.r_code:step.r;
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

function xyzToICtCp(X,Y,Z){
 X=Number(X)||0; Y=Number(Y)||0; Z=Number(Z)||0;
 const R= 1.7166511880*X -0.3556707838*Y -0.2533662814*Z;
 const G=-0.6666843518*X +1.6164812366*Y +0.0157685458*Z;
 const B= 0.0176398574*X -0.0427706133*Y +0.9421031212*Z;
 const L=(1688*Math.max(0,R)+2146*Math.max(0,G)+262*Math.max(0,B))/4096;
 const M=(683*Math.max(0,R)+2951*Math.max(0,G)+462*Math.max(0,B))/4096;
 const S=(99*Math.max(0,R)+309*Math.max(0,G)+3688*Math.max(0,B))/4096;
 const Lp=meterChartPqEncodeNormalized(L);
 const Mp=meterChartPqEncodeNormalized(M);
 const Sp=meterChartPqEncodeNormalized(S);
 return {
  I:0.5*Lp+0.5*Mp,
  T:(6610*Lp-13613*Mp+7003*Sp)/4096,
  P:(17933*Lp-17390*Mp-543*Sp)/4096
 };
}

function deltaEITP(X1,Y1,Z1,X2,Y2,Z2){
 const a=xyzToICtCp(X1,Y1,Z1);
 const b=xyzToICtCp(X2,Y2,Z2);
 const dI=a.I-b.I;
 const dT=a.T-b.T;
 const dP=a.P-b.P;
 return 720*Math.sqrt(dI*dI+0.25*dT*dT+dP*dP);
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
 const signal=Math.max(0,Number(v)||0);
 const clamped=Math.min(1,signal);
 if(meterChartIsPq()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  return meterChartHdrCodeLuminance(clamped,peak);
 }
 if(meterChartIsHlg()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  return Math.min(hlgEotf(clamped,Lb||0,peak),peak);
 }
 return targetEotf(signal,Lw,Lb);
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
 if(!Xn){
  const wp=meterTargetWhitePoint();
  Xn=wp.X; Yn=wp.Y; Zn=wp.Z;
 }
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
 const wp=meterTargetWhitePoint();
 const uw=4*wp.x/(10*wp.x+3);
 const vw=9*wp.y/(-2*wp.x+12*wp.y+3);
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
  sel.value = cb.checked ? 'eotf' : 'relative';
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
    eotf_normalized: cb('meterEotfNormalized'),
    eotf_log: cb('meterEotfLogScale'),
    luminance_log: cb('meterLuminanceLogScale'),
    hdr_diffuse_white: v('meterHdrDiffuseWhite')
  };
  localStorage.setItem('pgen.meter.colorPrefs', JSON.stringify(prefs));
 }catch(e){}
}

  function meterNormalizeSavedGreyRefMode(mode,inclLum){
   if(inclLum===true || inclLum==='1' || inclLum===1) return 'eotf';
   const normalized=String(mode==null?'':mode).trim();
   if(normalized==='eotf') return 'eotf';
   if(normalized==='relative') return 'relative';
   // Legacy saved "absolute" values came from the pre-HCFR relabeling.
   // Default those forward to Absolute Y w/o gamma.
   if(normalized==='absolute') return 'relative';
   return 'relative';
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
    const greyMode=meterNormalizeSavedGreyRefMode(p.grey_ref_mode,p.incl_lum);
    setVal('meterGreyRefMode', greyMode);
  setVal('meterGrayWorld',   p.gray_world);
  setVal('meterRgbBalanceFormula', p.rgb_formula);
  setVal('meterDeltaEForm',  p.de_form==='auto'?'deluv76':p.de_form);
  setVal('meterColorDeltaEForm', p.color_de_form);
  setChk('meterColorIncludeLumError', p.color_incl_lum);
    setChk('meterIncludeLumError', greyMode==='eotf');
  setVal('meterTargetGamma', p.target_gamma);
  setChk('meterHdrApplyBT2390', p.hdr_bt2390);
  setChk('meterEotfNormalized', p.eotf_normalized);
  setChk('meterEotfLogScale', p.eotf_log);
  setChk('meterLuminanceLogScale', p.luminance_log);
  setVal('meterHdrDiffuseWhite', p.hdr_diffuse_white);
 }catch(e){}
}

// Tri-state grey-reference mode. The stored string values are kept for
// backward compatibility, but their HCFR meanings are:
//   'absolute' : HCFR m_dE_gray == 0, "Relative Y"
//                ref Y = 1.0 with measured YWhite = patch Y
//                (chroma-only, L*=100 at every step)
//   'eotf'     : HCFR m_dE_gray == 1, "Absolute Y w/gamma"
//                ref Y = target gamma/EOTF luminance
//                (luminance tracking error included)
//   'relative' : HCFR m_dE_gray == 2, "Absolute Y w/o gamma"
//                ref Y = measured Y normalized to measured white peak
//                (gamma/luma error cancelled while keeping step lightness).
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
 if(x===false) return 'relative';
 return meterGreyRefMode();
}

function meterGreyRefModeLabel(mode){
 const resolved=meterResolveGreyRefMode(mode);
 return resolved==='absolute' ? 'Relative Y'
  : resolved==='eotf' ? 'Absolute Y w/gamma'
  : 'Absolute Y w/o gamma';
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

// Greyscale reference builder for the HCFR-compatible ΔE path.
//
// Legacy boolean inclLum is still accepted (true → 'eotf', false → 'relative').
// Optional gwWeight (HCFR gw_Weight) pre-multiplies YWhite / YWhiteRef by
// 0.15 or 0.05 to pull Lab into its linear (κ·t) region for near-black
// patches.

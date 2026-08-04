let meterIccRunning=false;
let meterIccStarting=false;
let meterIccStartToken=0;
let meterIccPollTimer=null;
let meterIccRunConfig=null;
let meterIccBuildPending=false;
let meterIccCompanionConnected=false;
let meterIccCompanionLastSeenAt=0;
let meterIccCompanionDetail='ICC Companion connected';
let meterIccCompanionClient='';
let meterIccCompanionTimer=null;
let meterIccCompanionSettingsPending=0;
let meterIccPollPending=false;
let meterIccReuseChoiceResolver=null;

const METER_ICC_BUILD_TIMING_KEY='pgen.iccBuildTiming.v1';
const METER_ICC_UI_SETTINGS_KEY='pgen.iccUiSettings.v1';
const METER_ICC_LAST_RUN_KEY='pgen.iccLastRun.v1';
let meterIccUiSettingsRestored=false;
let meterIccUiSettingsJson='';
let meterIccHadStoredUiSettings=false;

function meterIccStoredRunConfig(config,patchCount){
 if(!config) return null;
 return {
  profile_type:String(config.profile_type||''),profile_model:String(config.profile_model||''),
  profile_quality:String(config.profile_quality||''),quality:String(config.quality||''),
  signal_mode:String(config.signal_mode||''),pattern_provider:String(config.pattern_provider||''),
  reuse_signature:String(config.reuse_signature||''),target_transfer:config.target_transfer,
  code_min:Number(config.code_min),code_max:Number(config.code_max),meter_name:String(config.meter_name||''),
  patch_settings:config.patch_settings||null,patch_count:Math.max(0,Math.round(Number(patchCount)||0))
 };
}

function meterIccRememberLastRunConfig(config,patchCount){
 try{ localStorage.setItem(METER_ICC_LAST_RUN_KEY,JSON.stringify(meterIccStoredRunConfig(config,patchCount))); }catch(error){}
}

function meterIccLoadLastRunConfig(readings){
 try{
  const saved=JSON.parse(localStorage.getItem(METER_ICC_LAST_RUN_KEY)||'null');
  const count=Array.isArray(readings)?readings.length:null;
  if(!saved||(count!=null&&Number(saved.patch_count)!==count)||!saved.profile_type||!saved.profile_model||!saved.profile_quality) return null;
  return saved;
 }catch(error){ return null; }
}

function meterIccUiSettings(){
 const value=id=>String((document.getElementById(id)||{}).value||'');
 return {
  name:value('meterIccProfileName'),profile_type:value('meterIccProfileType'),target_transfer:value('meterIccTargetTransfer'),
  profile_model:value('meterIccProfileModel'),profile_quality:value('meterIccProfileQuality'),quality:value('meterIccQuality'),
  pattern_provider:value('meterIccPatternProvider'),window_mode:value('meterIccCompanionWindowMode'),start_delay:value('meterIccStartDelay'),
  companion_correction:value('meterIccCompanionCorrectionMode'),
  patch_settings:meterIccPatchSettings()
 };
}

function meterIccRememberUiSettings(){
 if(!meterIccUiSettingsRestored) return;
 try{
  const json=JSON.stringify(meterIccUiSettings());
  if(json!==meterIccUiSettingsJson){ localStorage.setItem(METER_ICC_UI_SETTINGS_KEY,json); meterIccUiSettingsJson=json; }
 }catch(error){}
}

function meterIccRestoreUiSettings(){
 if(meterIccUiSettingsRestored) return;
 let saved=null;
 try{ saved=JSON.parse(localStorage.getItem(METER_ICC_UI_SETTINGS_KEY)||'null'); }catch(error){}
 const set=(id,value,allowed)=>{
  const element=document.getElementById(id);
  if(!element||value==null) return;
  const text=String(value);
  if(!allowed||allowed.includes(text)) element.value=text;
 };
 if(saved){
  meterIccHadStoredUiSettings=true;
  set('meterIccProfileName',saved.name);
  set('meterIccProfileType',saved.profile_type,['sdr','windows-sdr','kde-hdr','windows-hdr']);
  set('meterIccTargetTransfer',saved.target_transfer,['srgb','gamma22','gamma24','bt1886']);
  set('meterIccProfileModel',saved.profile_model,Object.keys(METER_ICC_PROFILE_MODELS));
  set('meterIccProfileQuality',saved.profile_quality,['low','medium','high','ultra']);
  set('meterIccQuality',saved.quality,['small','medium','large','custom']);
  set('meterIccPatternProvider',saved.pattern_provider,['companion','local']);
  set('meterIccCompanionWindowMode',saved.window_mode,['window','fullscreen']);
  set('meterIccCompanionCorrectionMode',saved.companion_correction,['system','clut','matrix']);
  set('meterIccStartDelay',saved.start_delay);
  const patch=saved.patch_settings;
  if(patch&&typeof patch==='object'){
   set('meterIccPatchCount',patch.patch_count); set('meterIccPatchCountRange',patch.patch_count);
   set('meterIccWhitePatches',patch.white_patches); set('meterIccBlackPatches',patch.black_patches);
   set('meterIccGraySteps',patch.gray_steps); set('meterIccSingleSteps',patch.single_channel_steps);
   set('meterIccNeutralEmphasis',Math.round(Number(patch.neutral_emphasis||0)*100));
   set('meterIccDarkEmphasis',Math.round(Number(patch.dark_emphasis||0)*100));
   const good=document.getElementById('meterIccGoodOptimization'); if(good) good.checked=!!patch.good_optimization;
   const auto=document.getElementById('meterIccAutoPrecondition'); if(auto) auto.checked=!!patch.auto_precondition;
  }
 }
 meterIccUiSettingsRestored=true;
 meterIccUiSettingsJson=saved?JSON.stringify(saved):'';
}

function meterIccFormatDuration(seconds){
 seconds=Math.max(0,Math.round(Number(seconds)||0));
 const hours=Math.floor(seconds/3600);
 const minutes=Math.floor((seconds%3600)/60);
 const remainder=seconds%60;
 return hours?(hours+':'+String(minutes).padStart(2,'0')+':'+String(remainder).padStart(2,'0')):(minutes+':'+String(remainder).padStart(2,'0'));
}

function meterIccBuildTimingKey(config,patchCount){
 const model=String((config&&config.profile_model)||'clut');
 const family=meterIccProfileModelInfo(model).family;
 const quality=String((config&&config.profile_quality)||'medium').toLowerCase();
 return family+':'+model+':'+quality+':'+Math.max(1,Math.round(Number(patchCount)||1));
}

function meterIccRememberBuildDuration(config,patchCount,seconds){
 try{
  const key=meterIccBuildTimingKey(config,patchCount);
  const timings=JSON.parse(localStorage.getItem(METER_ICC_BUILD_TIMING_KEY)||'{}');
  const previous=Number(timings[key]);
  timings[key]=previous>0?Math.round(previous*.35+seconds*.65):Math.round(seconds);
  const keys=Object.keys(timings);
  while(keys.length>40) delete timings[keys.shift()];
  localStorage.setItem(METER_ICC_BUILD_TIMING_KEY,JSON.stringify(timings));
 }catch(error){}
}

function meterIccEstimatedBuildSeconds(config,patchCount){
 const count=Math.max(16,Math.round(Number(patchCount)||16));
 try{
  const timings=JSON.parse(localStorage.getItem(METER_ICC_BUILD_TIMING_KEY)||'{}');
  const measured=Number(timings[meterIccBuildTimingKey(config,count)]);
  if(Number.isFinite(measured)&&measured>=5) return measured;
 }catch(error){}
 const model=String((config&&config.profile_model)||'clut');
 const family=meterIccProfileModelInfo(model).family;
 const quality=String((config&&config.profile_quality)||'medium').toLowerCase();
 if(family==='matrix'){
  const base={low:12,medium:22,high:40,ultra:75,l:12,m:22,h:40,u:75}[quality]||22;
  return Math.max(10,Math.round(base*(.75+.25*Math.sqrt(count/95))));
 }
 const base={low:180,medium:360,high:600,ultra:1100,l:180,m:360,h:600,u:1100}[quality]||360;
 return Math.max(60,Math.round(base*(.7+.3*Math.sqrt(count/425))));
}

function meterIccStartBuildClock(status,config,patchCount){
 const clock={startedAt:Date.now(),estimated:meterIccEstimatedBuildSeconds(config,patchCount),timer:null,config,patchCount};
 const update=()=>{
  if(!status) return;
  const elapsed=Math.max(0,(Date.now()-clock.startedAt)/1000);
  const estimate=clock.estimated;
  const remaining=Math.max(0,estimate-elapsed);
  status.textContent='Measurements complete. Building the ICC profile. Elapsed '+meterIccFormatDuration(elapsed)+'. '
   +(remaining>0?('Estimated total '+meterIccFormatDuration(estimate)+', about '+meterIccFormatDuration(remaining)+' remaining.'):'The initial time estimate has been exceeded; the build is still working.');
 };
 update();
 clock.timer=setInterval(update,1000);
 return clock;
}

function meterIccStopBuildClock(clock,remember){
 if(!clock) return 0;
 if(clock.timer) clearInterval(clock.timer);
 clock.timer=null;
 const elapsed=Math.max(0,(Date.now()-clock.startedAt)/1000);
 if(remember&&elapsed>=1) meterIccRememberBuildDuration(clock.config,clock.patchCount,elapsed);
 return elapsed;
}

function meterIccResolveReuseChoice(choice){
 const modal=document.getElementById('meterIccReuseModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
 const resolver=meterIccReuseChoiceResolver;
 meterIccReuseChoiceResolver=null;
 if(resolver) resolver(choice==='reuse'?'reuse':choice==='fresh'?'fresh':'cancel');
}

function meterIccAskReuseChoice(reused,total,legacy,options){
 const modal=document.getElementById('meterIccReuseModal');
 const message=document.getElementById('meterIccReuseMessage');
 const confirmButton=document.getElementById('meterIccReuseConfirmBtn');
 if(!modal||!message) return Promise.resolve('fresh');
 if(meterIccReuseChoiceResolver) meterIccResolveReuseChoice('cancel');
 options=options||{};
 const remaining=Math.max(0,total-reused);
 const sourceCount=Math.max(reused,Math.round(Number(options.sourceCount)||0));
 const savedProfile=String(options.savedProfile||'');
 const source=(legacy?'A completed ICC run from before full compatibility tracking ':'A compatible completed ICC run ')
  +(savedProfile?'saved with '+savedProfile+' ':'')
  +'contains '+sourceCount+' measured '+(sourceCount===1?'patch':'patches')+'. ';
 const exact=reused
  ?reused+' also match the new '+total+'-patch set exactly, leaving '+remaining+' new '+(remaining===1?'patch':'patches')+' to measure. '
  :'None of its patch codes exactly match the new '+total+'-patch set. ';
 const prerequisite=options.prerequisite
  ?(reused+' match the required '+total+'-patch display pre-read. The remaining '+remaining+' '+(remaining===1?'patch will':'patches will')+' be measured before the optimized profile set is generated. The final profile patch set does not exist yet, so its reusable count will be calculated and shown after this pre-read finishes. ')
  :'';
 const preRead=options.skipPreRead
  ?('All '+sourceCount+' completed pre-read measurements will be used to optimize the final patch set. '+reused+' of those pre-read patches also match the final set exactly and can count as final profile measurements. ')
  :'';
 message.textContent=source+(options.prerequisite?prerequisite:(options.skipPreRead?preRead:exact))+'Reuse the compatible data, or start with an entirely new measurement run. Only reuse measurements if the display, input, meter, correction profile and measurement setup have not changed.';
 if(confirmButton) confirmButton.textContent=options.prerequisite
  ?('Reuse '+reused+' + Measure '+remaining)
  :options.skipPreRead
  ?('Use Pre-read'+(reused?' + Reuse '+reused:'') )
  :(reused?'Reuse '+reused+' Matching Reads':'Reuse as Display Pre-read');
 if(typeof meterEnsureModalOnBody==='function') meterEnsureModalOnBody(modal);
 modal.style.display='flex';
 uiSyncBodyScrollLock();
 return new Promise(resolve=>{ meterIccReuseChoiceResolver=resolve; });
}

function meterIccReuseSignature(type,patternProvider){
 const meter=meterSelectedMeasurementMeter()||{};
 const insertion=meterPatternInsertionPayload(document.getElementById('meterIccPatternInsertion'));
 const context={
  schema:'icc-reuse-v1',profile_type:String(type||''),signal_mode:meterIccProfileInfo(type).mode,
  meter_usb:String(meter.usb_id||'').toLowerCase(),meter_port:String(meter.physical_port||meter.port_num||meterSelectedMeasurementPort()||''),meter_name:String(meter.name||''),
  display_type:String((document.getElementById('meterIccDisplayType')||{}).value||''),
  correction:String((document.getElementById('meterIccMeterProfile')||{}).value||''),
  pattern_provider:String(patternProvider||''),patch_size:Number(getMeterPatchSize())||100,
  companion_mode:String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window'),
  signal_range:String(meterMeasurementPatchSignalRange()||''),refresh_rate:String(getMeterRefreshRate()||''),
  color_format:String((typeof getVal==='function'&&getVal('color_format'))||((typeof config!=='undefined'&&config&&config.color_format)||'')),
  colorimetry:String((typeof getVal==='function'&&getVal('colorimetry'))||((typeof config!=='undefined'&&config&&config.colorimetry)||'')),
  primaries:String((typeof getVal==='function'&&getVal('primaries'))||((typeof config!=='undefined'&&config&&config.primaries)||'')),
  max_luma:String((typeof getVal==='function'&&getVal('max_luma'))||((typeof config!=='undefined'&&config&&config.max_luma)||'')),
  min_luma:String((typeof getVal==='function'&&getVal('min_luma'))||((typeof config!=='undefined'&&config&&config.min_luma)||'')),
  max_cll:String((typeof getVal==='function'&&getVal('max_cll'))||((typeof config!=='undefined'&&config&&config.max_cll)||'')),
  max_fall:String((typeof getVal==='function'&&getVal('max_fall'))||((typeof config!=='undefined'&&config&&config.max_fall)||'')),
  measurement_delay_ms:Number(meterDelayMs())||0,low_light:meterLowLightReadState()||null,insertion
 };
 const text=JSON.stringify(context);
 let first=0x811c9dc5,second=0x9e3779b9;
 for(let index=0;index<text.length;index++){
  const code=text.charCodeAt(index);
  first=Math.imul(first^code,0x01000193)>>>0;
  second=Math.imul(second^(code+index),0x85ebca6b)>>>0;
 }
 return first.toString(16).padStart(8,'0')+second.toString(16).padStart(8,'0');
}

async function meterIccPreviousReusableReadings(signature,type){
 let state=null;
 let profileReadings=[];
 let liveExact=[];
 try{
  state=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:120000});
  if(state&&state.status==='complete'&&state.type==='colors'&&Number(state.points)===990001){
   profileReadings=meterIccProfileReadings(state.readings).filter(reading=>
    ['X','Y','Z'].every(key=>Number.isFinite(Number(reading[key])))
   );
  }
  liveExact=profileReadings.filter(reading=>
   String(reading.icc_reuse_signature||'').toLowerCase()===signature
  );
 }catch(error){ state=null; profileReadings=[]; }
 try{
  const saved=await fetchJSON('/api/icc/reusable?signature='+encodeURIComponent(signature),{_quiet:true,_timeoutMs:120000});
  if(saved&&saved.status==='ok'&&Array.isArray(saved.readings)&&saved.readings.length){
   const savedReadings=saved.readings.map(reading=>Object.assign({},reading,{icc_reuse_signature:signature}));
   const patchKey=reading=>[Math.round(Number(reading.input_max)||255),Math.round(Number(reading.r_code)||0),Math.round(Number(reading.g_code)||0),Math.round(Number(reading.b_code)||0)].join(':');
   const combined=[...liveExact];
   const liveCounts=new Map();
   combined.forEach(reading=>{ const key=patchKey(reading); liveCounts.set(key,(liveCounts.get(key)||0)+1); });
   const savedCounts=new Map();
   savedReadings.forEach(reading=>{
    const key=patchKey(reading);
    const count=(savedCounts.get(key)||0)+1;
    savedCounts.set(key,count);
    if(count>(liveCounts.get(key)||0)) combined.push(reading);
   });
   return {readings:combined,legacy:false,savedProfile:String(saved.profile||''),build_config:saved.build_config&&typeof saved.build_config==='object'?saved.build_config:null};
  }
 }catch(error){}
 if(liveExact.length) return {readings:liveExact,legacy:false};
 try{
  if(!state||!profileReadings.length||profileReadings.some(reading=>String(reading.icc_reuse_signature||'')!=='')) return {readings:[],legacy:false};
  const expectedMode=meterIccProfileInfo(type).mode;
  const expectedMaximum=expectedMode==='sdr'?255:1023;
  const legacyCompatible=String(state.signal_mode||'').toLowerCase()===expectedMode
   &&profileReadings.length>=16
   &&profileReadings.every(reading=>Math.round(Number(reading.input_max)||255)===expectedMaximum)
   &&profileReadings.every(reading=>!reading.observer||String(reading.observer)==='1931_2');
  return {readings:legacyCompatible?profileReadings:[],legacy:legacyCompatible};
 }catch(error){ return {readings:[],legacy:false}; }
}

function meterIccMatchReusableReadings(steps,readings,signature){
 const key=value=>{
  const maximum=Math.round(Number(value.input_max)||255);
  const r=Math.round(Number(value.r_code!=null?value.r_code:value.r)||0);
  const g=Math.round(Number(value.g_code!=null?value.g_code:value.g)||0);
  const b=Math.round(Number(value.b_code!=null?value.b_code:value.b)||0);
  return maximum+':'+r+':'+g+':'+b;
 };
 const buckets=new Map();
 (Array.isArray(readings)?readings:[]).forEach(reading=>{
  const patchKey=key(reading);
  if(!buckets.has(patchKey)) buckets.set(patchKey,[]);
  buckets.get(patchKey).push(reading);
 });
 const reused=[];
 const pending=[];
 (Array.isArray(steps)?steps:[]).forEach(step=>{
  const patchKey=key(step);
  const bucket=buckets.get(patchKey);
  if(!bucket||!bucket.length){ pending.push(step); return; }
  const reading=Object.assign({},bucket.shift(),{
   name:String(step.name||''),ire:Number(step.ire)||0,
   r_code:Math.round(Number(step.r)||0),g_code:Math.round(Number(step.g)||0),b_code:Math.round(Number(step.b)||0),
   input_max:Math.round(Number(step.input_max)||255),icc_reuse_signature:signature
  });
  reused.push(reading);
 });
 return {reused,pending};
}

function meterIccStampReuseSignature(steps,signature){
 return (Array.isArray(steps)?steps:[]).map(step=>Object.assign({},step,{icc_reuse_signature:signature}));
}

function meterIccCopySelectOptions(sourceId,targetId,excludeValues){
 const source=document.getElementById(sourceId);
 const target=document.getElementById(targetId);
 if(!source||!target) return;
 const excluded=new Set(excludeValues||[]);
 const signature=Array.from(source.options).filter(option=>!excluded.has(String(option.value))).map(option=>String(option.value)+'\t'+String(option.textContent||'')+'\t'+(option.disabled?'1':'0')).join('\n');
 if(target.dataset.sourceSignature!==signature){
  target.innerHTML='';
  Array.from(source.children).forEach(child=>{
   const clone=child.cloneNode(true);
   if(clone.tagName==='OPTION'&&excluded.has(String(clone.value))) return;
   target.appendChild(clone);
  });
  target.dataset.sourceSignature=signature;
 }
 const values=Array.from(target.options).map(option=>String(option.value));
 target.value=values.includes(String(source.value))?String(source.value):'';
 if(!values.includes(String(target.value))&&values.length) target.value=values[0];
}

function meterIccPrepareMeasurementControls(){
 meterIccCopySelectOptions('meterDisplayType','meterIccDisplayType',[]);
 meterIccCopySelectOptions('meterCcssProfile','meterIccMeterProfile',['custom_editor']);
 meterIccCopySelectOptions('meterPatchSize','meterIccCompanionPatchSize',[]);
 meterIccCopySelectOptions('meterPatchSize','meterCalibrationCompanionPatchSize',[]);
 const insertion=document.getElementById('meterIccPatternInsertion');
 if(insertion) insertion.checked=!!((document.getElementById('meterPatchInsert')||{}).checked);
}

function meterIccCompanionPatchSizeValue(){
 const value=(typeof getMeterPatchSize==='function')?Number(getMeterPatchSize()):100;
 return [2,5,10,18,25,50,75,100,105,110,118,125,150].includes(value)?value:100;
}

async function meterIccPushCompanionDisplaySettings(showError){
 const mode=String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window');
 const correctionMode=String((document.getElementById('meterIccCompanionCorrectionMode')||{}).value||'system');
 const activeSignal=String((typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr').toLowerCase()==='hdr10'?'hdr10':'sdr';
 meterIccCompanionSettingsPending++;
 try{
  const response=await fetchJSON('/api/icc/companion/settings',{
   method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({window_mode:mode,patch_size:meterIccCompanionPatchSizeValue(),correction_mode:correctionMode,correction_signal_mode:activeSignal}),
   _quiet:true,_timeoutMs:5000
  });
  if(!response||response.status!=='ok') throw new Error(response&&response.message?response.message:'Could not update the ICC Companion');
  return true;
 }catch(error){
  if(showError!==false) toast(error&&error.message?error.message:'Could not update the ICC Companion',true);
  return false;
 }finally{
  meterIccCompanionSettingsPending=Math.max(0,meterIccCompanionSettingsPending-1);
 }
}

function meterIccCompanionCorrectionChanged(source){
 const fromCalibration=source==='calibration';
 const sourceMode=document.getElementById(fromCalibration?'meterCalibrationCompanionCorrectionMode':'meterIccCompanionCorrectionMode');
 const targetMode=document.getElementById(fromCalibration?'meterIccCompanionCorrectionMode':'meterCalibrationCompanionCorrectionMode');
 if(sourceMode&&targetMode) targetMode.value=sourceMode.value;
 meterIccSyncUi();
 meterIccPushCompanionDisplaySettings(true);
}

function meterIccCompanionDisplaySettingsChanged(){
 meterIccSyncUi();
 meterIccPushCompanionDisplaySettings(true);
 meterIccRefreshRecoveryAvailability();
}

function meterCalibrationCompanionDisplaySettingsChanged(){
 const calibrationMode=document.getElementById('meterCalibrationCompanionWindowMode');
 const iccMode=document.getElementById('meterIccCompanionWindowMode');
 if(calibrationMode&&iccMode) iccMode.value=calibrationMode.value;
 const calibrationPatch=document.getElementById('meterCalibrationCompanionPatchSize');
 const mainPatch=document.getElementById('meterPatchSize');
 if(calibrationPatch&&mainPatch&&mainPatch.value!==calibrationPatch.value){
  mainPatch.value=calibrationPatch.value;
  mainPatch.dispatchEvent(new Event('change',{bubbles:true}));
 }
 meterIccSyncUi();
 meterIccPushCompanionDisplaySettings(true);
 meterIccRefreshRecoveryAvailability();
}

function meterIccLinkedPatchSizeChanged(){
 const linked=document.getElementById('meterIccCompanionPatchSize');
 const source=document.getElementById('meterPatchSize');
 if(linked&&source&&source.value!==linked.value){
  source.value=linked.value;
  source.dispatchEvent(new Event('change',{bubbles:true}));
 }
 meterIccSyncUi();
 if(meterIccPatternProvider()==='companion') meterIccPushCompanionDisplaySettings(true);
 meterIccRefreshRecoveryAvailability();
}

function meterIccLinkedDisplayTypeChanged(){
 const linked=document.getElementById('meterIccDisplayType');
 const source=document.getElementById('meterDisplayType');
 if(linked&&source&&source.value!==linked.value){
  source.value=linked.value;
  source.dispatchEvent(new Event('change',{bubbles:true}));
 }
 meterIccPrepareMeasurementControls();
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccLinkedMeterProfileChanged(){
 const linked=document.getElementById('meterIccMeterProfile');
 const source=document.getElementById('meterCcssProfile');
 if(linked&&source&&source.value!==linked.value){
  source.value=linked.value;
  source.dispatchEvent(new Event('change',{bubbles:true}));
 }
 meterIccPrepareMeasurementControls();
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccLinkedPatternInsertionChanged(){
 const linked=document.getElementById('meterIccPatternInsertion');
 const source=document.getElementById('meterPatchInsert');
 if(linked&&source){
  source.checked=!!linked.checked;
  source.dispatchEvent(new Event('change',{bubbles:true}));
 }
 try{ if(typeof saveMeterSettings==='function') saveMeterSettings(); }catch(error){}
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccProfileInfo(type){
 const info={
  sdr:{
   mode:'sdr',
   description:'Creates a measured ICC v2 display profile with ArgyllCMS. Choose a compact matrix/shaper model or an XYZ cLUT with a fallback matrix.',
   compatibility:'Portable conventional ICC profile for Linux, Windows and other ICC-aware software. It has no MHC2 system-calibration data, so unmanaged desktop output and raw Companion patches are not corrected.'
  },
  'windows-sdr':{
   mode:'sdr',
   description:'Creates a portable ICC v2 display profile with MHC2 system-calibration data. Its measured 3x3 matrix corrects primaries and white, and its per-channel 1D curves correct the measured RGB response to the selected target transfer.',
   compatibility:'Use with Windows 10 version 2004 or newer Advanced Color, or KDE Plasma 6.5.3 or newer on Wayland. Software that ignores the private MHC2 tag can still read the standard ICC matrix or cLUT fallback.'
  },
  'kde-hdr':{
   mode:'hdr10',
   description:'Creates a measured HDR ICC v2 display profile without MHC2. KDE Plasma can use the full BToA cLUT through KWin for system-wide HDR color management.',
   compatibility:'Requires KDE Plasma 6.7 or newer on Wayland with HDR enabled. This is the higher-accuracy KDE path for cLUT profiles. Windows Advanced Color requires the HDR ICC + MHC2 option instead.'
  },
  'windows-hdr':{
   mode:'hdr10',
   description:'Creates a portable ICC v2 display profile with MHC2 system-calibration data for HDR. It records measured peak, black, HDR metadata white, primaries and white, and applies a measured XYZ primary/white correction matrix.',
   compatibility:'Use with Windows Advanced Color or KDE Plasma 6.7 or newer on Wayland with HDR enabled. In Windows, install it through Settings > System > Display > Color profile while HDR is enabled. The legacy Color Management dialog associates it as an ordinary ICC profile instead of an HDR Advanced Color profile. MHC2 supports a 3x3 matrix and per-channel 1D curves, not a 3D LUT. The HDR curves remain at identity so the operating system applies PQ only once. Software that ignores MHC2 can still read the standard ICC fallback.'
  }
 };
 return info[type]||info.sdr;
}

function meterIccTargetTransferInfo(value){
 const info={
  srgb:{label:'sRGB',note:'Recommended for a normal SDR desktop and standard PC content. Validate it with sRGB selected as Target Gamma.'},
  gamma22:{label:'Gamma 2.2',note:'Calibrates the raw SDR output to a pure 2.2 power response. Validate it with Gamma 2.2.'},
  gamma24:{label:'Gamma 2.4',note:'Calibrates the raw SDR output to a pure 2.4 power response. This is mainly useful in a controlled dark-room workflow.'},
  bt1886:{label:'BT.1886',note:'Uses the measured black and white levels to build a display-relative BT.1886 response. Validate it with BT.1886 and the same black reference.'}
 };
 return info[value]||info.srgb;
}

function meterIccTargetTransferValue(){
 const select=document.getElementById('meterIccTargetTransfer');
 return ['srgb','gamma22','gamma24','bt1886'].includes(String(select&&select.value||''))?String(select.value):'srgb';
}

const METER_ICC_PATCH_PRESETS={
 matrix:{
  small:{patch_count:55,white_patches:1,black_patches:1,gray_steps:17,single_channel_steps:9,neutral_emphasis:50,dark_emphasis:0,good_optimization:true,auto_precondition:false,profile_quality:'medium'},
  medium:{patch_count:95,white_patches:2,black_patches:2,gray_steps:25,single_channel_steps:13,neutral_emphasis:50,dark_emphasis:10,good_optimization:true,auto_precondition:false,profile_quality:'high'},
  large:{patch_count:225,white_patches:4,black_patches:4,gray_steps:33,single_channel_steps:17,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:false,profile_quality:'ultra'}
 },
 clut:{
  small:{patch_count:175,white_patches:4,black_patches:4,gray_steps:33,single_channel_steps:9,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'medium'},
  medium:{patch_count:425,white_patches:4,black_patches:4,gray_steps:49,single_channel_steps:17,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'high'},
  large:{patch_count:1000,white_patches:4,black_patches:4,gray_steps:73,single_channel_steps:25,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'ultra'}
 }
};

const METER_ICC_PROFILE_MODELS={
 clut:{label:'XYZ cLUT + matrix',family:'clut',windows:true,note:'Recommended for detailed characterization. It creates an XYZ cLUT and accurate matrix/TRC fallback tags, so software without cLUT support can still use the profile.'},
 xyz_clut:{label:'XYZ cLUT only',family:'clut',windows:false,note:'Creates only an XYZ lookup-table transform. It can model nonlinear color interactions but has no matrix fallback for software that ignores display cLUT tags.'},
 lab_clut:{label:'L*a*b* cLUT only',family:'clut',windows:false,note:'Creates a Lab PCS lookup-table profile. It is mainly useful for compatibility testing and specialized color-managed workflows, and has no matrix fallback.'},
 matrix:{label:'Curves + matrix',family:'matrix',windows:true,note:'Uses independent RGB tone curves and a 3x3 colorant matrix. It is compact, broadly compatible, and a good choice for displays with mostly separable channel behavior.'},
 single_curve_matrix:{label:'Single curve + matrix',family:'matrix',windows:true,note:'Uses one shared tone curve for all three channels plus a 3x3 matrix. It preserves neutral balance but cannot model different per-channel tone responses.'},
 gamma_matrix:{label:'Gamma + matrix',family:'matrix',windows:true,note:'Fits a separate simple gamma exponent for each RGB channel plus a 3x3 matrix. It is smaller but less flexible than full tone curves.'},
 single_gamma_matrix:{label:'Single gamma + matrix',family:'matrix',windows:true,note:'Fits one shared gamma exponent plus a 3x3 matrix. This is highly compatible but only suitable for displays with a simple, common channel response.'}
};

function meterIccProfileModelInfo(value){
 return METER_ICC_PROFILE_MODELS[value]||METER_ICC_PROFILE_MODELS.clut;
}

function meterIccPatchSettings(){
 const number=(id,fallback)=>{
  const value=Number((document.getElementById(id)||{}).value);
  return Number.isFinite(value)?value:fallback;
 };
 return {
  patch_count:Math.max(34,Math.min(11106,Math.round(number('meterIccPatchCount',95)))),
  white_patches:Math.max(1,Math.min(32,Math.round(number('meterIccWhitePatches',2)))),
  black_patches:Math.max(1,Math.min(32,Math.round(number('meterIccBlackPatches',2)))),
  gray_steps:Math.max(2,Math.min(257,Math.round(number('meterIccGraySteps',25)))),
  single_channel_steps:Math.max(0,Math.min(129,Math.round(number('meterIccSingleSteps',13)))),
  neutral_emphasis:Math.max(0,Math.min(1,number('meterIccNeutralEmphasis',50)/100)),
  dark_emphasis:Math.max(0,Math.min(1,number('meterIccDarkEmphasis',10)/100)),
  good_optimization:!!((document.getElementById('meterIccGoodOptimization')||{}).checked),
  precondition_profile:String((document.getElementById('meterIccPreconditionProfile')||{}).value||''),
  auto_precondition:!!((document.getElementById('meterIccAutoPrecondition')||{}).checked)
 };
}

function meterIccApplyPatchPreset(presetName){
 const model=meterIccProfileModelInfo(String((document.getElementById('meterIccProfileModel')||{}).value||'clut'));
 const preset=(METER_ICC_PATCH_PRESETS[model.family]||METER_ICC_PATCH_PRESETS.clut)[presetName];
 if(!preset) return;
 const set=(id,value)=>{ const element=document.getElementById(id); if(element) element.value=String(value); };
 set('meterIccPatchCount',preset.patch_count);
 set('meterIccPatchCountRange',preset.patch_count);
 set('meterIccWhitePatches',preset.white_patches);
 set('meterIccBlackPatches',preset.black_patches);
 set('meterIccGraySteps',preset.gray_steps);
 set('meterIccSingleSteps',preset.single_channel_steps);
 set('meterIccNeutralEmphasis',preset.neutral_emphasis);
 set('meterIccDarkEmphasis',preset.dark_emphasis);
 const good=document.getElementById('meterIccGoodOptimization');
 if(good) good.checked=!!preset.good_optimization;
 const auto=document.getElementById('meterIccAutoPrecondition');
 if(auto) auto.checked=!!preset.auto_precondition;
 set('meterIccProfileQuality',preset.profile_quality||'high');
 meterIccSyncUi();
}

function meterIccPatchPresetChanged(){
 const preset=String((document.getElementById('meterIccQuality')||{}).value||'medium');
 if(preset!=='custom') meterIccApplyPatchPreset(preset);
 else meterIccSyncUi();
}

function meterIccProfileModelChanged(){
 const select=document.getElementById('meterIccQuality');
 let preset=String(select&&select.value||'medium');
 if(preset==='custom') preset='medium';
 if(select) select.value=preset;
 meterIccApplyPatchPreset(preset);
}

function meterIccPatchControlChanged(source){
 const range=document.getElementById('meterIccPatchCountRange');
 const number=document.getElementById('meterIccPatchCount');
 if(range&&number){
  if(source==='count-range') number.value=range.value;
  else if(source==='count-number') range.value=String(Math.max(34,Math.min(11106,Number(number.value)||34)));
 }
 const preset=document.getElementById('meterIccQuality');
 if(preset) preset.value='custom';
 meterIccSyncUi();
}

function meterIccPatchFractions(quality,profileType,profileModel){
 quality=quality==='quick'?'small':quality==='standard'?'medium':quality==='high'?'large':quality;
 const clut=profileModel==='clut';
 const rampCount=quality==='small'?(clut?17:9):(quality==='large'?33:17);
 const cubeCount=clut?(quality==='small'?3:quality==='large'?7:5):(quality==='large'?5:3);
 const patches=[];
 const seen=new Set();
 const add=(r,g,b,name)=>{
  const key=[r,g,b].map(value=>Math.round(value*100000)).join(':');
  if(seen.has(key)) return;
  seen.add(key);
  patches.push({r,g,b,name});
 };
 add(1,1,1,'ICC White');
 add(0,0,0,'ICC Black');
 add(1,0,0,'ICC Red 100');
 add(0,1,0,'ICC Green 100');
 add(0,0,1,'ICC Blue 100');
 const rampValues=[];
 for(let index=0;index<rampCount;index++) rampValues.push(index/(rampCount-1));
 // A standard 17-point encoded ramp does not take its first non-black sample
 // until about 6.25%. That is too sparse to solve the shaper curves which
 // Windows loads from an SDR MHC2 profile. Add exact low-end 8-bit codes while
 // retaining the evenly spaced ramp across the rest of the range.
 if(profileType==='windows-sdr'){
  [3,5,8,10,13,19,26].forEach(code=>rampValues.push(code/255));
 }
 rampValues.sort((a,b)=>a-b);
 for(const value of rampValues){
  add(value,value,value,'ICC Grey '+Math.round(value*100));
  add(value,0,0,'ICC Red '+Math.round(value*100));
  add(0,value,0,'ICC Green '+Math.round(value*100));
  add(0,0,value,'ICC Blue '+Math.round(value*100));
 }
 for(let ri=0;ri<cubeCount;ri++) for(let gi=0;gi<cubeCount;gi++) for(let bi=0;bi<cubeCount;bi++){
  const r=ri/(cubeCount-1),g=gi/(cubeCount-1),b=bi/(cubeCount-1);
  add(r,g,b,'ICC Cube '+Math.round(r*100)+'/'+Math.round(g*100)+'/'+Math.round(b*100));
 }
 return patches;
}

function meterIccSteps(quality,profileType,profileModel){
 const hdr=profileType==='kde-hdr'||profileType==='windows-hdr';
 const inputMax=hdr?1023:255;
 const code=value=>Math.round(Math.max(0,Math.min(1,value))*inputMax);
 const steps=meterIccPatchFractions(quality,profileType,profileModel).map((patch,index)=>({
  ire:index,
  r:code(patch.r),
  g:code(patch.g),
  b:code(patch.b),
  input_max:inputMax,
  name:patch.name
 }));
 if(profileType==='windows-hdr'){
  steps.push({
   ire:100,
   r:inputMax,
   g:inputMax,
   b:inputMax,
   input_max:inputMax,
   name:'ICC HDR Metadata White'
  });
 }
 return steps;
}

function meterIccPatchesToSteps(patches,profileType,includeMetadataWhite){
 const hdr=profileType==='kde-hdr'||profileType==='windows-hdr';
 const inputMax=hdr?1023:255;
 const code=value=>Math.round(Math.max(0,Math.min(1,Number(value)||0))*inputMax);
 const steps=patches.map((patch,index)=>({
  ire:index,r:code(patch.r),g:code(patch.g),b:code(patch.b),input_max:inputMax,name:String(patch.name||('ICC Optimized '+(index+1)))
 }));
 if(includeMetadataWhite!==false&&profileType==='windows-hdr') steps.push({ire:100,r:inputMax,g:inputMax,b:inputMax,input_max:inputMax,name:'ICC HDR Metadata White'});
 return steps;
}

async function meterIccGenerateSteps(profileType,settings,includeMetadataWhite){
 settings=settings||meterIccPatchSettings();
 const response=await fetchJSON('/api/icc/patches',{
  method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(settings),_timeoutMs:920000
 });
 if(!response||response.status!=='ok'||!Array.isArray(response.patches)) throw new Error(response&&response.message?response.message:'Could not generate the optimized patch set');
 return meterIccPatchesToSteps(response.patches,profileType,includeMetadataWhite);
}

async function meterIccGeneratePreconditionedSteps(readings,runConfig){
 const payload={
  profile_type:runConfig.profile_type,
  signal_mode:runConfig.signal_mode,
  name:runConfig.name+' precondition',
  meter_name:runConfig.meter_name,
  code_min:runConfig.code_min,
  code_max:runConfig.code_max,
  readings,
  patch_settings:runConfig.patch_settings
 };
 const response=await fetchJSON('/api/icc/precondition-patches',{
  method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),_timeoutMs:930000
 });
 if(!response||response.status!=='ok'||!Array.isArray(response.patches)) throw new Error(response&&response.message?response.message:'Could not create the display-aware patch set');
 return meterIccPatchesToSteps(response.patches,runConfig.profile_type);
}

function meterIccMissingPreconditionAnchors(error){
 return /required black, white and primary measurements are missing/i.test(String(error&&error.message||''));
}

function meterIccPreReadSettings(){
 return {patch_count:34,white_patches:2,black_patches:2,gray_steps:8,single_channel_steps:5,neutral_emphasis:.5,dark_emphasis:.2,good_optimization:true};
}

function meterIccProfileTypeChanged(){
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const mhc2=type==='windows-sdr'||type==='windows-hdr';
 const modelSelect=document.getElementById('meterIccProfileModel');
 if(modelSelect){
  Array.from(modelSelect.options).forEach(option=>{
   const supported=!mhc2||meterIccProfileModelInfo(option.value).windows;
   option.disabled=!supported;
   option.title=supported?'':'MHC2 profiles require matrix and tone-curve fallback tags.';
  });
  if(mhc2&&!meterIccProfileModelInfo(modelSelect.value).windows){
   modelSelect.value='clut';
   meterIccApplyPatchPreset(String((document.getElementById('meterIccQuality')||{}).value||'medium'));
  }
 }
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccPatternProvider(){
 const select=document.getElementById('meterIccPatternProvider');
 return select&&select.value==='local'?'local':'companion';
}

function meterIccLocalOutputModeStatus(profileType){
 const required=(profileType==='kde-hdr'||profileType==='windows-hdr')?'hdr10':'sdr';
 const active=String((typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr').toLowerCase();
 const label=active==='hdr10'?'HDR10':active==='hlg'?'HLG':active==='dv'?'Dolby Vision':'SDR';
 const dirty=typeof hasUnsavedSettings==='function'&&hasUnsavedSettings();
 return {
  required,
  active,
  matches:!dirty&&active===required,
  message:dirty
   ?'Apply & Restart before profiling so the HDMI measurements use the selected output settings.'
   :active===required
   ?('PGenerator+ HDMI output is '+label+'.')
   :('Set the PGenerator+ output to '+(required==='hdr10'?'HDR10':'SDR')+' before profiling. It is currently '+label+'.')
 };
}

async function meterIccEnsureLocalOutputMode(profileType){
 const status=meterIccLocalOutputModeStatus(profileType);
 if(status.matches) return true;
 const requiredLabel=status.required==='hdr10'?'HDR10':'SDR';
 const activeLabel=status.active==='hdr10'?'HDR10':status.active==='hlg'?'HLG':status.active==='dv'?'Dolby Vision':'SDR';
 const dirty=typeof hasUnsavedSettings==='function'&&hasUnsavedSettings();
 const accepted=await meterShowChoiceModal({
  title:dirty?'Apply output settings?':'Switch output mode?',
  body:dirty
   ?('This ICC profile requires '+requiredLabel+' output. The selected display settings must be applied before profiling can start. Apply them and restart the pattern generator now?')
   :('This ICC profile requires '+requiredLabel+' output, but PGenerator+ is currently in '+activeLabel+' mode. Switch to '+requiredLabel+' and restart the pattern generator now?'),
  acceptLabel:dirty?'Apply & Restart':('Switch to '+requiredLabel),
  cancelLabel:'Cancel'
 });
 if(!accepted) return false;
 const signalMode=document.getElementById('signal_mode');
 if(!signalMode){ toast('The output mode control is unavailable',true); return false; }
 if(signalMode.value!==status.required){
  signalMode.value=status.required;
  signalMode.dispatchEvent(new Event('change',{bubbles:true}));
 }
 if(typeof applySettings!=='function'||!await applySettings()) return false;
 const applied=meterIccLocalOutputModeStatus(profileType);
 if(!applied.matches){
  toast('The PGenerator+ output did not switch to '+requiredLabel+'. Check the display connection and try again.',true);
  return false;
 }
 return true;
}

function meterIccPatternProviderChanged(){
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccSyncUi(){
 meterIccPrepareMeasurementControls();
 const typeEl=document.getElementById('meterIccProfileType');
 const type=String(typeEl&&typeEl.value||'sdr');
 const info=meterIccProfileInfo(type);
 const provider=meterIccPatternProvider();
 const usesCompanion=provider==='companion';
 const localMode=meterIccLocalOutputModeStatus(type);
 const desc=document.getElementById('meterIccProfileDescription');
 const compatibility=document.getElementById('meterIccCompatibility');
 const windowsInstallGuide=document.getElementById('meterIccWindowsInstallGuide');
 const summary=document.getElementById('meterIccRunSummary');
 const start=document.getElementById('meterIccStartBtn');
 const startHint=document.getElementById('meterIccStartBtnHint');
 const quality=String((document.getElementById('meterIccQuality')||{}).value||'medium');
 const profileModel=String((document.getElementById('meterIccProfileModel')||{}).value||'clut');
 const profileModelInfo=meterIccProfileModelInfo(profileModel);
 const profileQuality=String((document.getElementById('meterIccProfileQuality')||{}).value||'high');
 const patchSettings=meterIccPatchSettings();
 const count=patchSettings.patch_count+(type==='windows-hdr'?1:0);
 const preRead=patchSettings.auto_precondition&&!patchSettings.precondition_profile;
 const patchMinimum=patchSettings.white_patches+patchSettings.black_patches+patchSettings.gray_steps+Math.max(0,patchSettings.single_channel_steps-2)*3;
 const invalidPatchSet=patchSettings.patch_count<patchMinimum;
 const modelNote=document.getElementById('meterIccProfileModelNote');
 const transferField=document.getElementById('meterIccTargetTransferField');
 const transferNote=document.getElementById('meterIccTargetTransferNote');
 const transfer=meterIccTargetTransferInfo(meterIccTargetTransferValue());
 if(transferField) transferField.style.display=type==='windows-sdr'?'':'none';
 if(transferNote) transferNote.textContent=transfer.note;
 const companionSetup=document.getElementById('meterIccCompanionSetup');
 const localSetup=document.getElementById('meterIccLocalSetup');
 const delayNote=document.getElementById('meterIccStartDelayNote');
 const companionWindowMode=String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window');
 const companionPatchSizeField=document.getElementById('meterIccCompanionPatchSizeField');
 const patchSizeNote=document.getElementById('meterIccPatchSizeNote');
 const companionDisplayModeNote=document.getElementById('meterIccCompanionDisplayModeNote');
 const companionCorrectionMode=String((document.getElementById('meterIccCompanionCorrectionMode')||{}).value||'system');
 const companionCorrectionNote=document.getElementById('meterIccCompanionCorrectionNote');
 const calibrationCorrectionMode=document.getElementById('meterCalibrationCompanionCorrectionMode');
 const calibrationCorrectionNote=document.getElementById('meterCalibrationCompanionCorrectionNote');
 const calibrationWindowMode=document.getElementById('meterCalibrationCompanionWindowMode');
 const calibrationPatchSize=document.getElementById('meterCalibrationCompanionPatchSize');
 const calibrationPatchSizeField=document.getElementById('meterCalibrationCompanionPatchSizeField');
 const calibrationDisplayModeNote=document.getElementById('meterCalibrationCompanionDisplayModeNote');
 if(companionSetup) companionSetup.style.display=usesCompanion?'':'none';
 if(localSetup) localSetup.style.display=usesCompanion?'none':'';
 if(delayNote) delayNote.textContent=usesCompanion
  ?'For single-monitor setups using the same computer for the WebUI and profiling, this delay gives you time to switch the display to the required input before measurements begin.'
  :'The delay gives you time to switch the display to the PGenerator+ HDMI input before measurements begin.';
 if(companionPatchSizeField) companionPatchSizeField.style.display=(!usesCompanion||companionWindowMode==='fullscreen')?'':'none';
 if(calibrationWindowMode&&calibrationWindowMode.value!==companionWindowMode) calibrationWindowMode.value=companionWindowMode;
 if(calibrationPatchSize){
  const patchSize=String(meterIccCompanionPatchSizeValue());
  if(Array.from(calibrationPatchSize.options).some(option=>option.value===patchSize)) calibrationPatchSize.value=patchSize;
 }
 if(calibrationPatchSizeField) calibrationPatchSizeField.style.display=companionWindowMode==='fullscreen'?'':'none';
 if(patchSizeNote) patchSizeNote.textContent=usesCompanion
  ?'Linked to Patch Size in the Calibration workspace. Window and APL selections are applied live to the running Companion.'
  :'Linked to Patch Size in the Calibration workspace and used by the PGenerator+ HDMI output.';
 if(companionDisplayModeNote) companionDisplayModeNote.textContent=companionWindowMode==='fullscreen'
  ?('The Companion uses a borderless fullscreen window. The selected centered window or APL pattern is rendered using the chosen patch size.'+(type==='windows-hdr'?' The HDR metadata white uses this same patch size.':'')+' Press F11 on the Companion computer to exit fullscreen.')
  :('Each patch fills the movable Companion window. Resize and position that window on the display being profiled.'+(type==='windows-hdr'?' The HDR metadata white uses this same window geometry.':''));
 if(calibrationDisplayModeNote) calibrationDisplayModeNote.textContent=companionWindowMode==='fullscreen'
  ?'The Companion uses a borderless fullscreen window and renders the selected centered window or APL patch size. Press F11 on the Companion computer to exit fullscreen.'
  :'Each patch fills the movable Companion window. Resize and position that window on the display being measured.';
 if(calibrationCorrectionMode&&calibrationCorrectionMode.value!==companionCorrectionMode) calibrationCorrectionMode.value=companionCorrectionMode;
 const correctionNote=companionCorrectionMode==='system'
  ?'The Companion sends uncorrected patches through the active Windows Advanced Color or Linux compositor profile pipeline.'
  :(companionCorrectionMode==='clut'
   ?'The Companion applies the cLUT from the profile currently active for its selected display. Disable MHC2 system correction while using this mode to avoid applying the correction twice.'
   :'The Companion applies the matrix and tone-curve fallback from the profile currently active for its selected display. Disable MHC2 system correction while using this mode to avoid applying the correction twice.');
 if(companionCorrectionNote) companionCorrectionNote.textContent=correctionNote;
 if(calibrationCorrectionNote) calibrationCorrectionNote.textContent=correctionNote;
 const qualitySelect=document.getElementById('meterIccQuality');
 if(qualitySelect) Array.from(qualitySelect.options).forEach(option=>{
  const label=String(option.value).charAt(0).toUpperCase()+String(option.value).slice(1);
  const preset=(METER_ICC_PATCH_PRESETS[profileModelInfo.family]||{})[String(option.value)];
  option.textContent=preset?(label+', '+(preset.patch_count+(type==='windows-hdr'?1:0))+' patches'):(label+', '+count+' patches');
 });
 const patchCountLabel=document.getElementById('meterIccPatchCountLabel');
 const neutralLabel=document.getElementById('meterIccNeutralEmphasisLabel');
 const darkLabel=document.getElementById('meterIccDarkEmphasisLabel');
 if(patchCountLabel) patchCountLabel.textContent=String(patchSettings.patch_count);
 if(neutralLabel) neutralLabel.textContent=Math.round(patchSettings.neutral_emphasis*100)+'%';
 if(darkLabel) darkLabel.textContent=Math.round(patchSettings.dark_emphasis*100)+'%';
 if(modelNote) modelNote.textContent=profileModelInfo.note;
 if(desc) desc.textContent=info.description;
 if(compatibility) compatibility.textContent=info.compatibility;
 if(windowsInstallGuide){
  windowsInstallGuide.style.display=(type==='windows-sdr'||type==='kde-hdr'||type==='windows-hdr')?'':'none';
  windowsInstallGuide.textContent=type==='kde-hdr'
   ?'Plasma 6.7+: enable HDR and select this file as the display HDR ICC profile in System Settings. KWin applies its cLUT through the compositor.'
   :type==='windows-hdr'
   ?'Windows: enable HDR, then add the file under Settings > System > Display > Color profile and set it as the HDR display default. Do not use the legacy Color Management dialog, because it creates a standard ICC association instead of an HDR Advanced Color association. Plasma 6.7+: enable HDR and select the same file as the display ICC profile in System Settings.'
   :'Windows: add the file under Settings > System > Display > Color profile and set it as the display default. Plasma 6.5.3+: select the same file as the display ICC profile in System Settings.';
 }
 const meterLabel=typeof meterSelectedMeasurementLabel==='function'?meterSelectedMeasurementLabel(null):'Meter';
 const displayOptions=(document.getElementById('meterIccDisplayType')||{}).selectedOptions;
 const displayLabel=displayOptions&&displayOptions[0]?String(displayOptions[0].textContent||'').trim():'Auto';
 const correction=(document.getElementById('meterIccMeterProfile')||{}).selectedOptions;
 const correctionLabel=correction&&correction[0]?String(correction[0].textContent||'').trim():'Auto';
 const insertion=!!((document.getElementById('meterIccPatternInsertion')||{}).checked);
 const companionPatchSizeSelect=document.getElementById('meterIccCompanionPatchSize');
 const companionPatchSizeOption=companionPatchSizeSelect&&companionPatchSizeSelect.selectedOptions?companionPatchSizeSelect.selectedOptions[0]:null;
 const generatorLabel=usesCompanion
  ?('ICC Companion '+(companionWindowMode==='fullscreen'?('fullscreen, '+String(companionPatchSizeOption?companionPatchSizeOption.textContent:'controlled patch')):'resizable window'))
  :'PGenerator+ HDMI';
 if(summary) summary.textContent=invalidPatchSet
  ?('Increase total patches to at least '+patchMinimum+' for the selected grayscale, single-channel, white and black coverage.')
  :(generatorLabel+' output: '+info.mode.toUpperCase()+'. Profile: '+profileModelInfo.label+' at '+profileQuality+' calculation quality. Meter: '+meterLabel+'. Display: '+displayLabel+'. Meter correction: '+correctionLabel+'. Pattern insertion: '+(insertion?'On':'Off')+'. '+count+' profile patches'+(preRead?' plus a 34-patch optimization pre-read':'')+'.'+(type==='windows-sdr'?' Target: '+transfer.label+'.':'')+(!usesCompanion?' '+localMode.message:''));
 const busy=meterIccStarting||meterIccRunning||meterIccBuildPending||meterSeriesRunning||meterActionPending||meterContinuousActive||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning;
 if(start){
  const selectedMeter=typeof meterSelectedMeasurementMeter==='function'?meterSelectedMeasurementMeter():null;
  const displayControl=document.getElementById('meterIccDisplayType');
  const profileControl=document.getElementById('meterIccMeterProfile');
  const meterReady=!!(meterDetected&&selectedMeter&&displayControl&&displayControl.options.length&&profileControl&&profileControl.options.length);
  const generatorUnavailable=usesCompanion&&!meterIccCompanionConnected;
  start.disabled=!meterReady||generatorUnavailable||busy||invalidPatchSet;
  start.textContent=meterIccBuildPending?'Building Profile...':(meterIccStarting||meterIccRunning?'Profiling...':'Start Profiling');
  start.setAttribute('aria-busy',(meterIccStarting||meterIccRunning||meterIccBuildPending)?'true':'false');
  const startReason=!meterDetected?'Connect a meter first':!meterReady?'Waiting for the meter settings to finish loading':invalidPatchSet?('Increase total patches to at least '+patchMinimum):usesCompanion&&!meterIccCompanionConnected?'Start the ICC Companion on the target computer before profiling':busy?'A meter operation is already running':!usesCompanion&&!localMode.matches?'Start profiling to review and apply the required output mode':'Start the ICC profiling measurements';
  start.title='';
  if(startHint){
   const companionTip=start.disabled&&generatorUnavailable?'Start the ICC Companion on the target computer before profiling':'';
   startHint.title='';
   startHint.dataset.tooltip=companionTip;
   startHint.setAttribute('aria-label',startReason);
  }
 }
 const retry=document.getElementById('meterIccRetryBuildBtn');
 const retryCount=Number(retry&&retry.dataset?retry.dataset.measurementCount:0);
 if(retry&&retryCount>0){
  retry.textContent='Rebuild '+retryCount+' Measurements ('+profileQuality.replace(/^./,letter=>letter.toUpperCase())+' Quality)';
 }
 meterIccRememberUiSettings();
}

async function meterOpenIccProfileBuilder(){
 const modal=document.getElementById('meterIccProfileModal');
 if(!modal) return;
 if(document.body.classList.contains('layout-desktop')&&pgDesktopWorkspace!=='icc-profile'){
  pgSelectDesktopWorkspace('icc-profile',{focus:true});
  return;
 }
 modal.style.display='flex';
 meterIccPrepareMeasurementControls();
 meterIccRestoreUiSettings();
 meterIccProfileTypeChanged();
 if(await meterIccRefreshCompanionStatus()) await meterIccPushCompanionDisplaySettings(false);
 await meterIccRefreshRecoveryAvailability();
 if(!meterIccCompanionTimer) meterIccCompanionTimer=setInterval(meterIccRefreshCompanionStatus,2000);
 await meterIccLoadProfiles();
 uiSyncBodyScrollLock();
}

function meterCloseIccProfileBuilder(){
 if(meterIccReuseChoiceResolver) meterIccResolveReuseChoice('cancel');
 if(document.body.classList.contains('layout-desktop')) return;
 const modal=document.getElementById('meterIccProfileModal');
 if(modal) modal.style.display='none';
 if(meterIccCompanionTimer){ clearInterval(meterIccCompanionTimer); meterIccCompanionTimer=null; }
 uiSyncBodyScrollLock();
}

function meterIccDownloadCompanion(platform){
 window.location.href='/api/icc/companion/download?platform='+encodeURIComponent(platform);
}

let meterCalibrationCompanionTimer=null;
function meterCalibrationPatternProvider(){
 const select=document.getElementById('meterPatternProvider');
 return select&&select.value==='companion'?'companion':'local';
}
function meterCalibrationUsesCompanion(){ return meterCalibrationPatternProvider()==='companion'; }
function meterCalibrationAutoCalUsesLocalOutput(){
 return !!(meterAutoCalRunning||meterLg3dAutoCalRunning||meterDvAutoCalProfileRunning||meterFullAutoCalRunning);
}
function meterCalibrationReadPatternProvider(){
 if(meterCalibrationAutoCalUsesLocalOutput()) return 'local';
 return meterCalibrationPatternProvider();
}
function meterCalibrationSelectLocalOutput(){
 const select=document.getElementById('meterPatternProvider');
 if(!select||select.value!=='companion') return false;
 select.value='local';
 select.dataset.previousValue='local';
 meterCalibrationSyncPatternProviderUi();
 try{ saveMeterSettings(); }catch(error){}
 return true;
}
function meterCalibrationReflectActualPatternProvider(){
 if(meterCalibrationAutoCalUsesLocalOutput()) meterCalibrationSelectLocalOutput();
}
function meterCalibrationApplyCompanionAvailability(connected){
 const select=document.getElementById('meterPatternProvider');
 const companionOption=select?Array.from(select.options).find(option=>option.value==='companion'):null;
 if(companionOption){
  companionOption.disabled=!connected;
  companionOption.title=connected
   ?'Use the connected ICC Companion for patch generation'
   :'Run the ICC Companion on the target computer to enable this option';
 }
 if(!connected) meterCalibrationSelectLocalOutput();
}
function meterCalibrationShowCompanionStatus(connected,text){
 const target=document.getElementById('meterCalibrationCompanionStatus');
 if(!target) return;
 target.textContent='';
 target.style.color=connected?'var(--green)':'var(--red)';
 if(!meterCalibrationUsesCompanion()) return;
 const dot=document.createElement('span');
 dot.style.color=connected?'var(--green)':'var(--red)';
 dot.textContent='\u25cf';
 target.append(dot,document.createTextNode(' '+text));
}
function meterCalibrationSyncPatternProviderUi(){
 const col=document.getElementById('meterPatternProviderCol');
 const gearWrap=document.getElementById('meterCompanionGearWrap');
 if(col) col.classList.toggle('companion-selected',meterCalibrationUsesCompanion());
 if(gearWrap) gearWrap.classList.toggle('is-hidden',!meterCalibrationUsesCompanion());
 if(!meterCalibrationUsesCompanion()){
  const popover=document.getElementById('meterCompanionGearPopover');
  const gear=document.getElementById('meterCompanionGear');
  if(popover) popover.classList.remove('open');
  if(gear){gear.classList.remove('active');gear.setAttribute('aria-expanded','false');}
 }
 if(meterCalibrationUsesCompanion()){
  if(!meterCalibrationCompanionTimer) meterCalibrationCompanionTimer=setInterval(meterIccRefreshCompanionStatus,2000);
 }else{
  if(meterCalibrationCompanionTimer){clearInterval(meterCalibrationCompanionTimer);meterCalibrationCompanionTimer=null;}
  meterCalibrationShowCompanionStatus(false,'');
 }
}
async function meterCalibrationPatternProviderChanged(){
 if(meterActionPending||meterSeriesRunning||meterContinuousActive){
  toast('Stop the active measurement before changing the patch generator',true);
  const select=document.getElementById('meterPatternProvider');
  if(select) select.value=select.dataset.previousValue||'local';
  return;
 }
 const select=document.getElementById('meterPatternProvider');
 if(select) select.dataset.previousValue=select.value;
 meterCalibrationSyncPatternProviderUi();
 saveMeterSettings();
 const connected=await meterIccRefreshCompanionStatus();
 if(meterCalibrationUsesCompanion()&&connected){
  try{ await fetchJSON('/api/icc/companion/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'align'}),_quiet:true,_timeoutMs:5000}); }catch(e){}
 }
}
async function meterCalibrationRequirePatternProvider(){
 if(meterCalibrationReadPatternProvider()!=='companion') return true;
 const connected=await meterIccRefreshCompanionStatus();
 if(connected) return true;
 toast('Run the paired ICC Companion on the target computer before reading',true);
 return false;
}

function meterIccShowCompanionStatus(connected,text){
 const target=document.getElementById('meterIccCompanionStatus');
 if(!target) return;
 target.textContent='';
 target.style.color=connected?'var(--green)':'var(--red)';
 const dot=document.createElement('span');
 dot.style.color=connected?'var(--green)':'var(--red)';
 dot.textContent='\u25cf';
 target.append(dot,document.createTextNode(' '+text));
}

function meterIccUpdateTopCompanionStatus(connected,detail){
 const wrap=document.getElementById('iccCompanionTopStatusWrap');
 if(!wrap) return;
 wrap.style.display=connected?'':'none';
 wrap.title=connected?String(detail||'ICC Companion connected'):'ICC Companion not connected';
 const dot=document.getElementById('iccCompanionTopDot');
 const text=document.getElementById('iccCompanionTopStatusText');
 if(dot) dot.style.background='var(--green)';
 if(text){
  text.textContent='ICC Companion'+(meterIccCompanionClient?' ['+meterIccCompanionClient+']':'');
  text.style.color='var(--text)';
 }
 if(typeof syncTopStatusStack==='function') syncTopStatusStack();
}

async function meterIccRefreshCompanionStatus(){
 try{
  const state=await fetchJSON('/api/icc/companion/status',{_quiet:true,_timeoutMs:3500});
  const windowMode=document.getElementById('meterIccCompanionWindowMode');
  if(windowMode&&state&&['window','fullscreen'].includes(String(state.window_mode||''))) windowMode.value=String(state.window_mode);
  const reportedConnected=!!(state&&state.connected);
  if(reportedConnected) meterIccCompanionLastSeenAt=Date.now();
  meterIccCompanionConnected=reportedConnected||(meterIccCompanionLastSeenAt>0&&Date.now()-meterIccCompanionLastSeenAt<12000);
  if(reportedConnected){
   const client=String(state.client||'target computer');
   meterIccCompanionClient=client;
   const renderer=String(state.renderer||'renderer');
   const version=String(state.version||'');
   const hdr=state.hdr_active?' with native HDR active':'';
   const correctionMode=String(state.correction_mode||'system');
   if(!meterIccCompanionSettingsPending&&['system','clut','matrix'].includes(correctionMode)){
    const workspaceMode=document.getElementById('meterIccCompanionCorrectionMode');
    const calibrationMode=document.getElementById('meterCalibrationCompanionCorrectionMode');
    if(workspaceMode) workspaceMode.value=correctionMode;
    if(calibrationMode) calibrationMode.value=correctionMode;
   }
   const activeProfile=String(state.active_profile||'');
   const correction=correctionMode==='clut'?(' using active-profile cLUT'+(activeProfile?' ['+activeProfile+']':'')):correctionMode==='matrix'?(' using active-profile matrix/TRC'+(activeProfile?' ['+activeProfile+']':'')):' using operating-system correction';
   const detail='Connected: '+client+' using '+renderer+hdr+correction+(version?' (v'+version+')':'');
   meterIccCompanionDetail=detail;
   meterIccShowCompanionStatus(true,detail);
   meterCalibrationShowCompanionStatus(true,detail);
  }else if(!meterIccCompanionConnected){ meterIccShowCompanionStatus(false,'Companion not connected'); meterCalibrationShowCompanionStatus(false,'Companion not connected'); }
 }catch(error){
  meterIccCompanionConnected=meterIccCompanionLastSeenAt>0&&Date.now()-meterIccCompanionLastSeenAt<12000;
  if(!meterIccCompanionConnected){ meterIccShowCompanionStatus(false,'Companion not connected'); meterCalibrationShowCompanionStatus(false,'Companion not connected'); }
 }
 meterIccUpdateTopCompanionStatus(meterIccCompanionConnected,meterIccCompanionDetail);
 meterCalibrationApplyCompanionAvailability(meterIccCompanionConnected);
 meterIccSyncUi();
 return meterIccCompanionConnected;
}

async function meterIccLoadProfiles(){
 const list=document.getElementById('meterIccProfileList');
 if(!list) return;
 try{
  const response=await fetchJSON('/api/icc/profiles',{_quiet:true,_timeoutMs:5000});
  const profiles=response&&Array.isArray(response.profiles)?response.profiles:[];
  const historyProfiles=[...profiles].sort((a,b)=>{
   const timestampDifference=Number(b&&b.mtime||0)-Number(a&&a.mtime||0);
   if(timestampDifference) return timestampDifference;
   return String(a&&a.name||'').localeCompare(String(b&&b.name||''));
  });
  const precondition=document.getElementById('meterIccPreconditionProfile');
  if(precondition){
   const previous=precondition.value;
   precondition.textContent='';
   const none=document.createElement('option');
   none.value='';
   none.textContent='None';
   precondition.appendChild(none);
   profiles.forEach(profile=>{
    const option=document.createElement('option');
    option.value=profile.name;
    option.textContent=profile.name;
    precondition.appendChild(option);
   });
   if(profiles.some(profile=>profile.name===previous)) precondition.value=previous;
  }
  if(!profiles.length){
   list.textContent='No ICC profiles have been created yet.';
   return;
  }
  list.innerHTML='';
  historyProfiles.forEach(profile=>{
   const row=document.createElement('div');
   row.className='meter-icc-profile-row';
   const name=document.createElement('span');
   name.className='meter-icc-profile-name';
   name.textContent=profile.name;
   const download=document.createElement('button');
   download.type='button';
   download.className='btn btn-sm btn-primary';
   download.textContent='Download';
   download.onclick=()=>{ window.location.href='/api/icc/download?file='+encodeURIComponent(profile.name); };
   const validate=document.createElement('button');
   validate.type='button';
   validate.className='btn btn-sm btn-secondary';
   validate.textContent='Self-check';
   validate.disabled=!profile.validation;
   validate.title=profile.validation?'View the ArgyllCMS profcheck results':'No saved self-check is available for this profile';
   validate.onclick=()=>meterIccOpenValidation(profile.name);
   const remove=document.createElement('button');
   remove.type='button';
   remove.className='btn btn-sm btn-danger';
   remove.textContent='Delete';
   remove.onclick=()=>meterIccDeleteProfile(profile.name);
   row.append(name,download,validate,remove);
   list.appendChild(row);
  });
 }catch(error){
  list.textContent='Could not load created profiles.';
 }
}

function meterIccCloseValidation(){
 const modal=document.getElementById('meterIccValidationModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

function meterIccRenderValidation(file,result){
 const set=(id,value)=>{ const element=document.getElementById(id); if(element) element.textContent=value; };
 const number=value=>Number.isFinite(Number(value))?Number(value).toFixed(3):'--';
 set('meterIccValidationFile',file||'ICC profile');
 set('meterIccValidationAverage',number(result.average_de00));
 set('meterIccValidationRms',number(result.rms_de00));
 set('meterIccValidationPeak',number(result.peak_de00));
 set('meterIccValidationMedian',number(result.median_de00));
 set('meterIccValidationP95',number(result.p95_de00));
 set('meterIccValidationMeta',String(result.profile_model_label||'ICC profile')+'; '+String(result.profile_quality||'standard')+' calculation quality; '+Number(result.patches||0)+' characterization patches; '+String(result.engine||'ArgyllCMS profcheck'));
 const info=result&&result.profile_info&&typeof result.profile_info==='object'?result.profile_info:null;
 set('meterIccValidationStructure',info
  ?('Profile structure: ICC '+String(info.icc_version||'unknown')+'; '+String(info.profile_class||'display')+'; '+String(info.color_space||'RGB')+' to '+String(info.pcs||'XYZ')+'; '+String(info.rendering_intent||'unknown intent')+'; '+Number(info.tag_count||0)+' tags; '+String(info.size_label||'unknown size')+'.')
  :'');
 const characterization=result&&result.characterization&&typeof result.characterization==='object'?result.characterization:null;
 set('meterIccValidationCharacterization',characterization
  ?('Saved characterization: white xy '+Number(characterization.white_x||0).toFixed(4)+', '+Number(characterization.white_y||0).toFixed(4)+' at '+Number(characterization.white_nits||0).toFixed(2)+' cd/m²; black '+Number(characterization.black_nits||0).toFixed(4)+' cd/m²; contrast '+(Number.isFinite(Number(characterization.contrast_ratio))?Number(characterization.contrast_ratio).toFixed(0)+':1':'infinite')+'.')
  :'');
 const distribution=result&&result.distribution&&typeof result.distribution==='object'?result.distribution:null;
 set('meterIccValidationDistribution',distribution
  ?('Fit distribution: '+Number(distribution.within_1_percent||0).toFixed(1)+'% at or below ΔE00 1; '+Number(distribution.within_2_percent||0).toFixed(1)+'% at or below 2; '+Number(distribution.within_3_percent||0).toFixed(1)+'% at or below 3.')
  :'');
 set('meterIccValidationScale','Rating scale: Excellent ≤ 1.0 average, 1.5 RMS, 4.0 peak; Good ≤ 2.0 average, 2.5 RMS, 7.0 peak; Fair ≤ 3.0 average, 4.0 RMS, 10.0 peak; Poor exceeds one or more Fair limits.');
 set('meterIccValidationNote',String(result.note||''));
 const download=document.getElementById('meterIccValidationDownloadBtn');
 if(download){
  download.disabled=!file;
  download.onclick=()=>{ if(file) window.location.href='/api/icc/download?file='+encodeURIComponent(file); };
 }
 const mhc2Panel=document.getElementById('meterIccValidationMhc2');
 const mhc2=result&&result.mhc2&&result.mhc2.status==='passed'?result.mhc2:null;
 if(mhc2Panel){
  mhc2Panel.style.display=mhc2?'':'none';
  mhc2Panel.textContent=mhc2
   ?('MHC2 check passed. Matrix round-trip maximum error: '+Number(mhc2.matrix_round_trip_max_error||0).toFixed(7)+'. Curves: '+Number(mhc2.curve_entries||0)+' points, '+String(mhc2.curves||'verified')+'. Metadata white: '+Number(mhc2.metadata_white_luminance_nits||0).toFixed(1)+' cd/m²; measured peak: '+Number(mhc2.peak_luminance_nits||0).toFixed(1)+' cd/m².')
   :'';
 }
 const rating=document.getElementById('meterIccValidationRating');
 if(rating){
  const average=Number(result.average_de00);
  const rms=Number(result.rms_de00);
  const peak=Number(result.peak_de00);
  let grade=String(result.rating||'Profile fit complete').replace(/\s+fit$/i,'');
  if(Number.isFinite(average)&&Number.isFinite(rms)&&Number.isFinite(peak)){
   grade=average<=1&&rms<=1.5&&peak<=4?'Excellent':average<=2&&rms<=2.5&&peak<=7?'Good':average<=3&&rms<=4&&peak<=10?'Fair':'Poor';
  }
  rating.textContent=grade+(grade==='Profile fit complete'?'':' profile fit');
  const key=grade.toLowerCase();
  rating.style.color=key==='excellent'||key==='good'?'var(--success)':key==='fair'?'var(--warning)':'var(--danger)';
 }
 const table=document.getElementById('meterIccValidationWorst');
 if(table){
  table.textContent='';
  const worst=Array.isArray(result.worst_patches)?result.worst_patches:[];
  worst.forEach(patch=>{
   const row=document.createElement('tr');
   const label=document.createElement('td');
   const rgb=document.createElement('td');
   const error=document.createElement('td');
   label.style.padding=rgb.style.padding=error.style.padding='6px';
   error.style.textAlign='right';
   label.textContent=String(patch.name||('Patch '+patch.index));
   rgb.textContent=Array.isArray(patch.rgb)?patch.rgb.map(value=>Number(value).toFixed(1)).join(', '):'';
   error.textContent=number(patch.de00);
   row.append(label,rgb,error);
   table.appendChild(row);
  });
  if(!worst.length){
   const row=document.createElement('tr');
   const cell=document.createElement('td');
   cell.colSpan=3;
   cell.style.padding='8px';
   cell.textContent='No per-patch error details were returned.';
   row.appendChild(cell);
   table.appendChild(row);
  }
 }
 const modal=document.getElementById('meterIccValidationModal');
 if(modal){
  if(typeof meterEnsureModalOnBody==='function') meterEnsureModalOnBody(modal);
  modal.style.display='flex';
 }
 uiSyncBodyScrollLock();
}

async function meterIccOpenValidation(file,result){
 try{
  const validation=result||await fetchJSON('/api/icc/validation?file='+encodeURIComponent(file),{_quiet:true,_timeoutMs:10000});
  if(!validation||validation.status==='error') throw new Error(validation&&validation.message?validation.message:'Validation results are unavailable');
  meterIccRenderValidation(file,validation);
 }catch(error){
  toast(error&&error.message?error.message:'Could not load the profile self-check',true);
 }
}

async function meterIccDeleteProfile(file){
 if(!confirm('Delete '+file+'?')) return;
 const response=await fetchJSON('/api/icc/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({file}),_timeoutMs:5000});
 if(response&&response.status==='ok'){
  toast('ICC profile deleted');
  meterIccLoadProfiles();
 }else toast(response&&response.message?response.message:'Could not delete ICC profile',true);
}

async function meterIccRefreshRecoveryAvailability(){
 const retry=document.getElementById('meterIccRetryBuildBtn');
 if(!retry) return false;
 try{
  const selectedType=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
  const selectedProvider=meterIccPatternProvider();
  const selectedSignature=meterIccReuseSignature(selectedType,selectedProvider);
  const reusable=await meterIccPreviousReusableReadings(selectedSignature,selectedType);
  const readings=reusable.readings;
  const available=readings.length>=16&&meterIccReadingsHaveRequiredAnchors(readings);
  retry.style.display=available?'':'none';
  if(available){
  const saved=meterIccLoadLastRunConfig(readings)||(reusable.build_config&&typeof reusable.build_config==='object'?reusable.build_config:null);
  const profileCount=Math.max(0,Number(saved&&saved.patch_count)||readings.length);
  retry.dataset.measurementCount=String(profileCount);
  if(!meterIccHadStoredUiSettings&&!saved){
   const family=meterIccProfileModelInfo(String((document.getElementById('meterIccProfileModel')||{}).value||'clut')).family;
   const inferred=profileCount<=(family==='matrix'?70:250)?'small':profileCount<=(family==='matrix'?130:650)?'medium':'large';
   const qualitySelect=document.getElementById('meterIccQuality');
   if(qualitySelect) qualitySelect.value=inferred;
   meterIccApplyPatchPreset(inferred);
  }
  const calculationQuality=String((document.getElementById('meterIccProfileQuality')||{}).value||(saved&&saved.profile_quality)||'medium');
  retry.textContent='Rebuild '+profileCount+' Measurements ('+calculationQuality.replace(/^./,letter=>letter.toUpperCase())+' Quality)';
  retry.title='Rebuild exactly these saved measurements using the selected profile model and calculation quality. No larger patch set will be generated or measured.';
  }
  return available;
 }catch(error){
  retry.style.display='none';
  return false;
 }
}

function meterIccProfileReadings(readings){
 return (Array.isArray(readings)?readings:[]).filter(reading=>{
  if(!reading||reading.error||reading.autocal_reference_only) return false;
  if(String(reading.series_type||'').toLowerCase()==='reference') return false;
  return /^ICC(?:\s|$)/i.test(String(reading.name||''));
 });
}

function meterIccReadingsHaveRequiredAnchors(readings){
 const values=meterIccProfileReadings(readings);
 const targets=[[0,0,0],[1,1,1],[1,0,0],[0,1,0],[0,0,1]];
 return targets.every(target=>values.some(reading=>{
  const maximum=Math.max(1,Math.round(Number(reading.input_max)||255));
  const rgb=[reading.r_code,reading.g_code,reading.b_code].map(value=>Math.round(Number(value)||0)/maximum);
  return rgb.reduce((sum,value,index)=>sum+Math.abs(value-target[index]),0)<=.02;
 }));
}

async function meterIccRetryBuild(){
 if(meterIccStarting||meterIccRunning||meterIccBuildPending) return;
 const name=String((document.getElementById('meterIccProfileName')||{}).value||'').trim();
 if(!name){ toast('Enter the profile name first',true); return; }
 const selectedType=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 try{
  const state=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:120000});
  const selectedProvider=meterIccPatternProvider();
  const selectedSignature=meterIccReuseSignature(selectedType,selectedProvider);
  const reusable=await meterIccPreviousReusableReadings(selectedSignature,selectedType);
  const readings=reusable.readings;
  if(!state||readings.length<16||!meterIccReadingsHaveRequiredAnchors(readings)) throw new Error('No compatible completed ICC measurements are available for the selected signal mode and settings');
  const saved=meterIccLoadLastRunConfig(readings)||(reusable.build_config&&typeof reusable.build_config==='object'?reusable.build_config:null);
  const inputMaximum=Math.max(...readings.map(reading=>Number(reading.input_max)||255));
  const inferredType=inputMaximum>255?(selectedType==='windows-hdr'?'windows-hdr':'kde-hdr'):(selectedType==='windows-sdr'?'windows-sdr':'sdr');
  const type=String((saved&&saved.profile_type)||inferredType);
  const info=meterIccProfileInfo(type);
  const patternProvider=String((saved&&saved.pattern_provider)||selectedProvider);
  const reuseSignature=String((saved&&saved.reuse_signature)||selectedSignature);
  const profileModel=String((document.getElementById('meterIccProfileModel')||{}).value||(saved&&saved.profile_model)||'clut');
  const family=meterIccProfileModelInfo(profileModel).family;
  const inferredQuality=readings.length<=(family==='matrix'?70:250)?'small':readings.length<=(family==='matrix'?130:650)?'medium':'large';
  const quality=String((saved&&saved.quality)||inferredQuality);
  const preset=(METER_ICC_PATCH_PRESETS[family]||METER_ICC_PATCH_PRESETS.clut)[quality]||{};
  const selectedProfileQuality=String((document.getElementById('meterIccProfileQuality')||{}).value||'');
  const profileQuality=['low','medium','high','ultra'].includes(selectedProfileQuality)?selectedProfileQuality:String((saved&&saved.profile_quality)||preset.profile_quality||'medium');
  meterIccRunConfig={
   profile_type:type,profile_model:profileModel,profile_quality:profileQuality,name,quality,signal_mode:info.mode,steps:[],
   pattern_provider:patternProvider,reuse_signature:reuseSignature,
   patch_settings:(saved&&saved.patch_settings)||null,
   target_transfer:type==='windows-sdr'?String((saved&&saved.target_transfer)||meterIccTargetTransferValue()):undefined,
   code_min:0,code_max:info.mode==='sdr'?255:1023,
   meter_name:meterSelectedMeasurementLabel(null)
  };
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent='Rebuilding exactly '+readings.length+' saved measurements at '+profileQuality+' calculation quality. No '+((METER_ICC_PATCH_PRESETS[family]||{}).medium||{}).patch_count+'-patch set is being generated or measured.';
  await meterIccBuild(readings);
 }catch(error){
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent=error&&error.message?error.message:'Could not recover the completed measurements.';
  toast(error&&error.message?error.message:'Could not recover the completed measurements',true);
 }
}

function meterIccSetProgress(label,current,total){
 const wrap=document.getElementById('meterIccProgress');
 const labelEl=document.getElementById('meterIccProgressLabel');
 const count=document.getElementById('meterIccProgressCount');
 const fill=document.getElementById('meterIccProgressFill');
 if(wrap) wrap.style.display='';
 if(labelEl) labelEl.textContent=label||'Measuring';
 if(count) count.textContent=Math.max(0,Number(current)||0)+' / '+Math.max(0,Number(total)||0);
 if(fill) fill.style.width=(total>0?Math.max(0,Math.min(100,100*current/total)):0)+'%';
}

function meterIccSetRunning(running){
 meterIccRunning=!!running;
 const stop=document.getElementById('meterIccStopBtn');
 if(stop) stop.style.display=running?'':'none';
 meterSyncBusyStatusDot();
 meterIccSyncUi();
 meterUpdateReadButtons();
}

async function meterIccLaunchMeasurementSeries(steps,type,patternProvider){
 const mode=meterIccProfileInfo(type).mode;
 const body=meterMeasurementSignalContext({
  type:'colors',points:990001,custom_series:true,custom_steps:steps,
  display_type:String((document.getElementById('meterIccDisplayType')||{}).value||getEffectiveDisplayType()),
  ccss_override:String((document.getElementById('meterIccMeterProfile')||{}).value||''),
  target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',
  target_gamma:meterAutoCalTargetGammaValue(),delay_ms:meterDelayMs(),
  patch_size:getMeterPatchSize(),pattern_signal_range:meterMeasurementPatchSignalRange()||undefined,
  refresh_rate:getMeterRefreshRate()||undefined,require_device_ready:meterSelectedMeasurementRequiresReady(),
  pattern_provider:patternProvider,
  ...meterPatternInsertionPayload(document.getElementById('meterIccPatternInsertion'))
 });
 // ICC profiling always characterises measurements in CIE 1931. The chart
 // observer is a viewing/analysis preference and must not change the mode
 // requested from a tristimulus meter such as SpyderX.
 body.observer='1931_2';
 // The characterization chart already contains its own black and white
 // patches. Do not prepend the calibration workspace's reference reads: they
 // are redundant and can use a different transport bit depth from HDR ICC
 // patches.
 body.target_white_use_measured=false;
 body.target_black_use_measured=false;
 body.series_has_saved_white_reference=true;
 body.series_has_saved_black_reference=true;
 if(patternProvider==='companion'){
  body.signal_mode=mode;
  body.signal_range='2';
  body.pattern_signal_range='2';
  body.transport_signal_range='2';
  body.max_luma='1000';
 }
 const lowLight=meterLowLightReadState();
 if(lowLight) body.low_light=lowLight;
 const response=await fetchJSON('/api/meter/series',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),_timeoutMs:12000});
 if(!response||response.status!=='started') throw new Error(response&&response.message?response.message:'Could not start the meter series');
 meterSharedSeriesId=String(response.series_id||'');
 meterSeriesRunning=true;
 meterIccSetRunning(true);
 meterIccStarting=false;
 meterActionPending=false;
 if(meterIccPollTimer) clearInterval(meterIccPollTimer);
 meterIccPollTimer=setInterval(meterIccPoll,1000);
}

async function meterIccStart(){
 if(meterIccStarting||meterIccRunning||meterIccBuildPending) return;
 const retryButton=document.getElementById('meterIccRetryBuildBtn');
 if(retryButton) retryButton.style.display='none';
 if(!await meterEnsureDetected()){ toast('Connect a meter first',true); return; }
 meterIccPrepareMeasurementControls();
 const selectedMeter=meterSelectedMeasurementMeter();
 const displayControl=document.getElementById('meterIccDisplayType');
 const profileControl=document.getElementById('meterIccMeterProfile');
 if(!selectedMeter||!displayControl||!displayControl.options.length||!profileControl||!profileControl.options.length){
  meterIccSyncUi();
  toast('Wait for the meter settings to finish loading',true);
  return;
 }
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const info=meterIccProfileInfo(type);
 const mode=info.mode;
 const patternProvider=meterIccPatternProvider();
 if(patternProvider==='companion'){
  if(!await meterIccRefreshCompanionStatus()){ toast('Run the ICC Companion on the target computer first',true); return; }
  const nativeCorrection=document.getElementById('meterIccCompanionCorrectionMode');
  if(nativeCorrection&&nativeCorrection.value!=='system'){
   nativeCorrection.value='system';
   const calibrationCorrection=document.getElementById('meterCalibrationCompanionCorrectionMode');
   if(calibrationCorrection) calibrationCorrection.value='system';
   meterIccSyncUi();
   toast('Companion profile correction was disabled so the new profile measures the uncorrected display path');
  }
  if(!await meterIccPushCompanionDisplaySettings(true)) return;
 }else{
  if(!await meterIccEnsureLocalOutputMode(type)) return;
 }
 const name=String((document.getElementById('meterIccProfileName')||{}).value||'').trim();
 if(!name){ toast('Enter a profile name',true); return; }
 const quality=String((document.getElementById('meterIccQuality')||{}).value||'medium');
 const profileModel=String((document.getElementById('meterIccProfileModel')||{}).value||'clut');
 const profileQuality=String((document.getElementById('meterIccProfileQuality')||{}).value||'high');
 const patchSettings=meterIccPatchSettings();
 const delayEl=document.getElementById('meterIccStartDelay');
 const startDelay=Math.max(0,Math.min(300,Math.round(Number(delayEl&&delayEl.value)||0)));
 const status=document.getElementById('meterIccStatus');
 const startToken=++meterIccStartToken;
 const reuseSignature=meterIccReuseSignature(type,patternProvider);
 meterIccStarting=true;
 meterActionPending=true;
 const stopButton=document.getElementById('meterIccStopBtn');
 if(stopButton) stopButton.style.display='';
 meterIccSyncUi();
 try{
  const usePreRead=patchSettings.auto_precondition&&!patchSettings.precondition_profile;
  const baseRunConfig={
   profile_type:type,profile_model:profileModel,profile_quality:profileQuality,name,quality,signal_mode:mode,pattern_provider:patternProvider,
   patch_settings:patchSettings,start_token:startToken,reuse_signature:reuseSignature,
   target_transfer:type==='windows-sdr'?meterIccTargetTransferValue():undefined,
   code_min:0,code_max:mode==='sdr'?255:1023,
   meter_name:meterSelectedMeasurementLabel(null)
  };
  if(status) status.textContent='Checking for compatible completed ICC measurements...';
  const previousReuse=await meterIccPreviousReusableReadings(reuseSignature,type);
  const previousReadings=previousReuse.readings;
  if(startToken!==meterIccStartToken) throw new Error('ICC profiling stopped');
  let steps=[];
  let measurementSteps=[];
  let reusedReadings=[];
  let preconditionReusedReadings=[];
  let reuseSourceReadings=[];
  let usedPreviousPreRead=false;
  let stage=usePreRead?'precondition':'profile';
  if(usePreRead&&previousReadings.length){
   if(status) status.textContent='Generating the display-aware patch set to compare with previous measurements...';
   meterIccSetProgress('Checking reusable patches',0,patchSettings.patch_count);
   try{
    const candidateSteps=meterIccStampReuseSignature(await meterIccGeneratePreconditionedSteps(previousReadings,baseRunConfig),reuseSignature);
    const matches=meterIccMatchReusableReadings(candidateSteps,previousReadings,reuseSignature);
    const choice=await meterIccAskReuseChoice(matches.reused.length,candidateSteps.length,previousReuse.legacy,{skipPreRead:true,sourceCount:previousReadings.length,savedProfile:previousReuse.savedProfile});
    if(choice==='cancel'){
     const cancelled=new Error('ICC profiling cancelled');
     cancelled.icc_cancelled=true;
     throw cancelled;
    }
    if(choice==='reuse'){
     steps=candidateSteps;
     measurementSteps=matches.pending;
     reusedReadings=matches.reused;
     usedPreviousPreRead=true;
     stage='profile';
    }
   }catch(error){
    if(error&&error.icc_cancelled) throw error;
    if(!meterIccMissingPreconditionAnchors(error)) throw error;
    if(status) status.textContent='The saved run is incomplete. Checking which required display pre-read patches can be reused...';
    meterIccSetProgress('Checking required pre-read patches',0,34);
    const preReadSteps=meterIccStampReuseSignature(await meterIccGenerateSteps(type,meterIccPreReadSettings(),false),reuseSignature);
    const preReadMatches=meterIccMatchReusableReadings(preReadSteps,previousReadings,reuseSignature);
    let choice='fresh';
    if(preReadMatches.reused.length){
     choice=await meterIccAskReuseChoice(preReadMatches.reused.length,preReadSteps.length,previousReuse.legacy,{prerequisite:true,sourceCount:previousReadings.length,savedProfile:previousReuse.savedProfile});
    }
    if(choice==='cancel'){
     const cancelled=new Error('ICC profiling cancelled');
     cancelled.icc_cancelled=true;
     throw cancelled;
    }
    steps=preReadSteps;
    stage='precondition';
    if(choice==='reuse'){
     measurementSteps=preReadMatches.pending;
     preconditionReusedReadings=preReadMatches.reused;
     reuseSourceReadings=previousReadings;
     usedPreviousPreRead=true;
    }else{
     measurementSteps=preReadSteps;
    }
   }
  }
  if(!steps.length){
   if(status) status.textContent=usePreRead?'Generating the 34-patch display pre-read...':'Generating an optimized '+meterIccProfileModelInfo(profileModel).label+' patch set...';
   meterIccSetProgress(usePreRead?'Preparing display pre-read':'Optimizing patch set',0,usePreRead?34:patchSettings.patch_count);
   steps=meterIccStampReuseSignature(usePreRead
    ?await meterIccGenerateSteps(type,meterIccPreReadSettings(),false)
    :await meterIccGenerateSteps(type,patchSettings),reuseSignature);
   measurementSteps=steps;
   if(!usePreRead&&previousReadings.length){
    const matches=meterIccMatchReusableReadings(steps,previousReadings,reuseSignature);
    if(matches.reused.length){
     const choice=await meterIccAskReuseChoice(matches.reused.length,steps.length,previousReuse.legacy,{sourceCount:previousReadings.length,savedProfile:previousReuse.savedProfile});
     if(choice==='cancel'){
      const cancelled=new Error('ICC profiling cancelled');
      cancelled.icc_cancelled=true;
      throw cancelled;
     }
     if(choice==='reuse'){
      measurementSteps=matches.pending;
      reusedReadings=matches.reused;
     }
    }
   }
  }
  if(startToken!==meterIccStartToken) throw new Error('ICC profiling stopped');
  meterIccRunConfig=Object.assign({},baseRunConfig,{steps,stage,reused_readings:reusedReadings,precondition_reused_readings:preconditionReusedReadings,reuse_source_readings:reuseSourceReadings,used_previous_pre_read:usedPreviousPreRead});
  for(let remaining=startDelay;remaining>0;remaining--){
   if(startToken!==meterIccStartToken) throw new Error('ICC profiling stopped');
   if(status) status.textContent=patternProvider==='companion'
    ?('Starting in '+remaining+' seconds. Move and resize the ICC Companion on the target display now.')
    :('Starting in '+remaining+' seconds. Switch the display to the PGenerator+ HDMI input now.');
   meterIccSetProgress('Waiting to start',startDelay-remaining,startDelay);
   await new Promise(resolve=>setTimeout(resolve,1000));
  }
  if(startToken!==meterIccStartToken) throw new Error('ICC profiling stopped');
  if(stage==='precondition'&&!measurementSteps.length&&preconditionReusedReadings.length){
   if(status) status.textContent='All required display pre-read patches were reused. Generating the optimized profile set...';
   await meterIccContinueAfterPreRead([],status);
   return;
  }
  if(!measurementSteps.length&&reusedReadings.length){
   meterIccStarting=false;
   meterActionPending=false;
   if(stopButton) stopButton.style.display='none';
   if(status) status.textContent='All '+reusedReadings.length+' requested patches were reused. Building the ICC profile...';
   await meterIccBuild(reusedReadings);
   return;
  }
  if(status) status.textContent='Connecting to the meter...';
  meterIccSetProgress(reusedReadings.length?('Reusing '+reusedReadings.length+' patches; starting meter'):(usedPreviousPreRead?'Previous display pre-read reused; starting meter':'Starting meter'),0,measurementSteps.length);
  await meterIccLaunchMeasurementSeries(measurementSteps,type,patternProvider);
  if(status) status.textContent=stage==='precondition'?'Display pre-read started. Waiting for the first patch...':(reusedReadings.length?('Reused '+reusedReadings.length+' patches. Measuring '+measurementSteps.length+' remaining patches...'):(usedPreviousPreRead?('Previous measurements supplied the display pre-read. Measuring '+measurementSteps.length+' new patches...'):'Measurement series started. Waiting for the first patch...'));
  await meterIccPoll();
 }catch(error){
  meterIccStarting=false;
  meterActionPending=false;
  meterSeriesRunning=false;
  meterIccSetRunning(false);
  if(status) status.textContent=error&&error.message?error.message:'Could not start ICC profiling.';
  if(!(error&&error.icc_cancelled)) toast(error&&error.message?error.message:'Could not start ICC profiling',true);
 }
}

async function meterIccContinueAfterPreRead(newReadings,status){
 const config=meterIccRunConfig;
 if(!config) throw new Error('ICC profiling state was lost');
 const measuredPreRead=meterIccProfileReadings(newReadings);
 const reusedPreRead=Array.isArray(config.precondition_reused_readings)?config.precondition_reused_readings:[];
 const completePreRead=[...reusedPreRead,...measuredPreRead];
 if(status) status.textContent='Pre-read complete. Building a temporary display model and optimizing the final patch set...';
 meterIccSetProgress('Optimizing for the measured display',completePreRead.length,config.patch_settings.patch_count);
 const finalSteps=meterIccStampReuseSignature(await meterIccGeneratePreconditionedSteps(completePreRead,config),config.reuse_signature);
 if(Number(config.start_token)!==meterIccStartToken) throw new Error('ICC profiling stopped');
 const reuseSource=Array.isArray(config.reuse_source_readings)?config.reuse_source_readings:[];
 const reusablePool=reuseSource.length?[...reuseSource,...measuredPreRead]:[];
 const matches=reusablePool.length
  ?meterIccMatchReusableReadings(finalSteps,reusablePool,config.reuse_signature)
  :{reused:[],pending:finalSteps};
 config.steps=finalSteps;
 config.stage='profile';
 config.reused_readings=matches.reused;
 config.precondition_reused_readings=[];
 config.reuse_source_readings=[];
 if(!matches.pending.length&&matches.reused.length){
  meterIccStarting=false;
  meterActionPending=false;
  const stopButton=document.getElementById('meterIccStopBtn');
  if(stopButton) stopButton.style.display='none';
  if(status) status.textContent='All '+matches.reused.length+' optimized profile patches were reused. Building the ICC profile...';
  await meterIccBuild(matches.reused);
  return;
 }
 if(status) status.textContent=matches.reused.length
  ?('Reused '+matches.reused.length+' optimized profile patches. Restarting the meter for '+matches.pending.length+' missing patches...')
  :'Display-aware patch set ready. Restarting the meter for the profile measurements...';
 meterIccSetProgress(matches.reused.length?('Reusing '+matches.reused.length+' profile patches; restarting meter'):'Restarting meter',0,matches.pending.length);
 await meterIccLaunchMeasurementSeries(matches.pending,config.profile_type,config.pattern_provider);
 if(status) status.textContent=matches.reused.length
  ?('Reused '+matches.reused.length+' patches. Measuring '+matches.pending.length+' remaining patches...')
  :'Profile measurement series started. Waiting for the first patch...';
 setTimeout(meterIccPoll,0);
}

async function meterIccPoll(){
 if(!meterIccRunning||meterIccPollPending) return;
 meterIccPollPending=true;
 let terminalTransition=false;
 try{
  let state=await fetchJSON('/api/meter/series/status?summary=1',{_quiet:true,_timeoutMs:10000});
  if(!state) return;
  meterSeriesAwaitingReady=!!state.awaiting_ready;
  meterSeriesSpectroSetupApplyFromStatus(state);
  const current=Number(state.current_step)||0;
  const total=Number(state.total_steps)||((meterIccRunConfig&&meterIccRunConfig.steps.length)||0);
  meterIccSetProgress(state.current_name||'Initializing meter',current,total);
  const status=document.getElementById('meterIccStatus');
  if(status){
   if(state.status==='setup') status.textContent='Complete the meter setup prompt to continue.';
   else if(current>0){
    const reused=(meterIccRunConfig&&meterIccRunConfig.stage==='profile'&&Array.isArray(meterIccRunConfig.reused_readings))?meterIccRunConfig.reused_readings.length:0;
    status.textContent=reused
     ?('Measuring new patch '+Math.min(current,total)+' of '+total+'. Reused '+reused+' of '+(reused+total)+' final profile patches.')
     :('Measuring patch '+Math.min(current,total)+' of '+total+'.');
   }
   else status.textContent=state.current_name||'Initializing the meter. The first patch will appear when it is ready.';
  }
  if(!['complete','cancelled','error','cleared'].includes(String(state.status||'').toLowerCase())) return;
  terminalTransition=true;
  if(status) status.textContent=state.status==='complete'?'Measurement stage complete. Retrieving the readings...':'ICC profiling is stopping...';
  if(state.status==='complete'){
   const completeState=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:120000});
   if(!completeState||completeState.status!=='complete') throw new Error('Could not retrieve completed ICC measurements');
   state=completeState;
  }
  clearInterval(meterIccPollTimer);
  meterIccPollTimer=null;
  meterSeriesRunning=false;
  meterSeriesAwaitingReady=false;
  meterSpectroSetupApply(null);
  meterIccSetRunning(false);
  try{ meterClearDisplayPattern(); }catch(_error){}
  if(state.status==='complete'){
   if(meterIccRunConfig&&meterIccRunConfig.stage==='precondition'){
    meterIccStarting=true;
    meterActionPending=true;
    meterIccSyncUi();
    await meterIccContinueAfterPreRead(state.readings,status);
   }else{
    await meterIccBuild([...(meterIccRunConfig&&Array.isArray(meterIccRunConfig.reused_readings)?meterIccRunConfig.reused_readings:[]),...meterIccProfileReadings(state.readings)]);
   }
  }else{
   if(status) status.textContent=state.status==='error'?('Measurement failed: '+(state.current_name||'meter error')):'ICC profiling stopped.';
  }
 }catch(error){
  const status=document.getElementById('meterIccStatus');
  if(status&&error&&error.message) status.textContent=error.message;
  if(meterIccStarting||terminalTransition){
   if(meterIccPollTimer) clearInterval(meterIccPollTimer);
   meterIccPollTimer=null;
   meterIccStarting=false;
   meterActionPending=false;
   meterSeriesRunning=false;
   meterIccSetRunning(false);
   toast(error&&error.message?error.message:'Could not create the display-aware patch set',true);
  }
 }finally{
  meterIccPollPending=false;
 }
}

function meterIccResumeVisiblePolling(){
 if(document.hidden||!meterIccRunning||meterIccPollPending) return;
 meterIccPoll();
}

document.addEventListener('visibilitychange',meterIccResumeVisiblePolling);
window.addEventListener('focus',meterIccResumeVisiblePolling);

async function meterIccBuild(readings){
 const status=document.getElementById('meterIccStatus');
 meterIccBuildPending=true;
 meterActionPending=true;
 meterIccSyncUi();
 const total=(meterIccRunConfig&&meterIccRunConfig.steps.length)||readings.length;
 meterIccSetProgress('Building ICC profile',total,total);
 const profileReadings=meterIccProfileReadings(readings);
 meterIccRememberLastRunConfig(meterIccRunConfig,profileReadings.length);
 const buildClock=meterIccStartBuildClock(status,meterIccRunConfig,profileReadings.length);
 let buildElapsed=0;
 try{
  const payload=Object.assign({},meterIccRunConfig,{readings:profileReadings});
  delete payload.steps;
  delete payload.reused_readings;
  delete payload.precondition_reused_readings;
  delete payload.reuse_source_readings;
  const response=await fetchJSON('/api/icc/build',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),_timeoutMs:2710000});
  if(!response||response.status!=='ok') throw new Error(response&&response.message?response.message:'Profile build failed');
  buildElapsed=meterIccStopBuildClock(buildClock,true);
  if(status){
   const windowsMhc=meterIccRunConfig&&(meterIccRunConfig.profile_type==='windows-sdr'||meterIccRunConfig.profile_type==='windows-hdr');
   const transferText=response.target_transfer?(' Target transfer: '+meterIccTargetTransferInfo(response.target_transfer).label+'.'):'';
   const measuredWhite=Number(response.white_nits);
   const calibratedWhite=Number(response.calibrated_white_nits);
   const whiteText=(windowsMhc&&calibratedWhite>0&&measuredWhite>calibratedWhite+0.1)
    ?(' Calibrated white was reduced from '+measuredWhite.toFixed(1)+' to '+calibratedWhite.toFixed(1)+' cd/m² to preserve the target white point without channel clipping.')
    :'';
   const installText=meterIccRunConfig&&meterIccRunConfig.profile_type==='windows-hdr'
    ?' In Windows, enable HDR and install it through Settings > System > Display > Color profile, not the legacy Color Management dialog. For Plasma 6.7+, install it as the HDR display profile before verification.'
    :(meterIccRunConfig&&meterIccRunConfig.profile_type==='kde-hdr'
     ?' Install it as the HDR display ICC profile in Plasma 6.7+ before verification.'
     :(meterIccRunConfig&&meterIccRunConfig.profile_type==='windows-sdr'?' Install it as the display profile in Windows Advanced Color or Plasma 6.5.3+ before verification.':''));
   status.textContent='Profile created in '+meterIccFormatDuration(buildElapsed)+': '+response.file+'. Download it below.'+transferText+whiteText+installText;
  }
  const retry=document.getElementById('meterIccRetryBuildBtn');
  // Profile quality only changes the fit. Preserve an explicit rebuild path
  // so the completed measurements can be reused without another meter run.
  if(retry) retry.style.display='';
  toast('ICC profile created');
  await meterIccLoadProfiles();
  // The profile and profcheck are complete before the self-check modal opens.
  // Clear every ICC-owned busy flag now so the workspace cannot remain stuck
  // on "Building" behind the modal if another browser starts a meter read.
  meterIccBuildPending=false;
  meterIccStarting=false;
  meterActionPending=false;
  meterIccSetRunning(false);
  // Successful builds always have a saved profcheck result. Fetch the saved
  // result as a fallback if an older builder response omitted the inline copy.
  await meterIccOpenValidation(response.file,response.validation||null);
 }catch(error){
  meterIccStopBuildClock(buildClock,false);
  if(status) status.textContent=error&&error.message?error.message:'ICC profile build failed.';
  const retry=document.getElementById('meterIccRetryBuildBtn');
  if(retry) retry.style.display='';
  toast(error&&error.message?error.message:'ICC profile build failed',true);
 }finally{
  meterIccStopBuildClock(buildClock,false);
  meterIccBuildPending=false;
  meterIccStarting=false;
  meterActionPending=false;
  meterIccSetRunning(false);
  const stopButton=document.getElementById('meterIccStopBtn');
  if(stopButton) stopButton.style.display='none';
  meterIccSyncUi();
  meterUpdateReadButtons();
 }
}

async function meterIccStop(){
 if(meterIccStarting){
  if(meterIccReuseChoiceResolver) meterIccResolveReuseChoice('cancel');
  meterIccStartToken++;
  meterIccStarting=false;
  meterActionPending=false;
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent='ICC profiling stopped before measurements began.';
  const stop=document.getElementById('meterIccStopBtn');
  if(stop) stop.style.display='none';
  meterIccSyncUi();
  meterUpdateReadButtons();
  return;
 }
 if(!meterIccRunning) return;
 const stop=document.getElementById('meterIccStopBtn');
 if(stop) stop.disabled=true;
 try{
  await fetchJSON('/api/meter/stop',{method:'POST',_timeoutMs:5000});
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent='Stopping after the current meter operation...';
 }finally{
  if(stop) stop.disabled=false;
 }
}

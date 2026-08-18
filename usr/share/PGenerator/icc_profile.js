let meterIccRunning=false;
let meterIccStarting=false;
let meterIccStartToken=0;
let meterIccPollTimer=null;
let meterIccRunConfig=null;
let meterIccBuildPending=false;
let meterIccCompanionConnected=false;
let meterIccCompanionReportedConnected=false;
let meterIccCompanionLastSeenAt=0;
let meterIccCompanionDetail='PGenerator+ Patch Companion connected';
let meterIccCompanionClient='';
let meterIccCompanionOutdated='';
let meterIccCompanionTimer=null;
let meterIccCompanionSettingsPending=0;
// The correction selector is an operator choice, not a live-status widget.
// A profile run temporarily writes `none` to the Companion settings, and the
// status poll used to copy that temporary value back into the selector. The
// next calibration series then faithfully sent `none` again, making every
// installed profile appear ineffective. Hydrate once on page load, then keep
// the explicit browser choice until the operator changes it.
let meterIccCompanionCorrectionInitialized=false;
let meterIccCompanionProfileRestoreMode='';
let meterIccPollPending=false;
let meterIccReuseChoiceResolver=null;
let meterIccMeasurementClock=null;

const METER_ICC_BUILD_TIMING_KEY='pgen.iccBuildTiming.v2';
const METER_ICC_LEGACY_BUILD_TIMING_KEY='pgen.iccBuildTiming.v1';
const METER_ICC_UI_SETTINGS_KEY='pgen.iccUiSettings.v1';
const METER_ICC_LAST_RUN_KEY='pgen.iccLastRun.v1';
let meterIccUiSettingsRestored=false;
let meterIccUiSettingsJson='';
let meterIccHadStoredUiSettings=false;

function meterIccCalibrationMode(config){
 const mode=String(config&&config.calibration_mode||'');
 if(['vcgt','profile','none'].includes(mode)) return mode;
 return config&&config.include_vcgt===false?'none':'vcgt';
}

function meterIccCalibrationModeValue(){
 const mode=String((document.getElementById('meterIccCalibrationMode')||{}).value||'vcgt');
 return ['vcgt','profile','none'].includes(mode)?mode:'vcgt';
}

function meterIccStoredRunConfig(config,patchCount){
 if(!config) return null;
 const calibrationMode=meterIccCalibrationMode(config);
 return {
  profile_type:String(config.profile_type||''),profile_model:String(config.profile_model||''),
  profile_quality:String(config.profile_quality||''),quality:String(config.quality||''),
  calibration_mode:calibrationMode,include_vcgt:calibrationMode==='vcgt',
  icc_version:String(config.icc_version||'auto'),cicp:config.cicp||null,
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
  avg_deviation:value('meterIccAvgDeviation'),
  calibration_mode:meterIccCalibrationModeValue(),
  icc_version:value('meterIccVersion')||'auto',cicp:meterIccCicpSettings(),
  patch_settings:meterIccPatchSettings()
 };
}

function meterIccAvgDeviationValue(){
 const input=document.getElementById('meterIccAvgDeviation');
 if(!input) return '';
 const raw=String(input.value||'').trim();
 if(!raw) return '';
 const number=Number(raw);
 if(!Number.isFinite(number)||number<0||number>5) return '';
 return String(number);
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
  set('meterIccStartDelay',saved.start_delay);
  set('meterIccVersion',saved.icc_version,['auto','2.2','4.4']);
  if(saved.cicp&&typeof saved.cicp==='object'){
   set('meterIccCicpPrimaries',saved.cicp.colour_primaries,['1','5','6','9','11','12']);
   set('meterIccCicpTransfer',saved.cicp.transfer_characteristics,['1','4','5','8','13','14','15','16','18']);
   set('meterIccCicpMatrix',saved.cicp.matrix_coefficients,['0','1','5','6','9','10']);
   set('meterIccCicpRange',saved.cicp.video_full_range_flag,['0','1']);
   const fields=document.getElementById('meterIccCicpFields');
   if(fields) fields.dataset.profileType=String(saved.profile_type||'');
  }
  if(saved.calibration_mode!==undefined||saved.include_vcgt!==undefined){
   const calibration=document.getElementById('meterIccCalibrationMode');
   if(calibration){ calibration.value=meterIccCalibrationMode(saved); calibration.dataset.profileType=String(saved.profile_type||''); }
  }
  if(saved.avg_deviation!==undefined&&saved.avg_deviation!==null&&saved.avg_deviation!==''){
   const number=Number(saved.avg_deviation);
   if(Number.isFinite(number)&&number>=0&&number<=5) set('meterIccAvgDeviation',saved.avg_deviation);
  }
  const patch=saved.patch_settings;
  if(patch&&typeof patch==='object'){
   set('meterIccPatchCount',patch.patch_count); set('meterIccPatchCountRange',patch.patch_count);
   set('meterIccWhitePatches',patch.white_patches); set('meterIccBlackPatches',patch.black_patches);
   set('meterIccGraySteps',patch.gray_steps); set('meterIccSingleSteps',patch.single_channel_steps);
   set('meterIccCubeSteps',patch.cube_steps!=null?patch.cube_steps:0);
   set('meterIccCubeSurfaceSteps',patch.cube_surface_steps!=null?patch.cube_surface_steps:0);
   set('meterIccBccSteps',patch.bcc_steps!=null?patch.bcc_steps:0);
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

function meterIccBuildTimingKey(config){
 const model=String((config&&config.profile_model)||'clut');
 const family=meterIccProfileModelInfo(model).family;
 const quality=String((config&&config.profile_quality)||'medium').toLowerCase();
 return family+':'+model+':'+quality;
}

function meterIccRememberBuildDuration(config,patchCount,seconds){
 try{
  const key=meterIccBuildTimingKey(config);
  const timings=JSON.parse(localStorage.getItem(METER_ICC_BUILD_TIMING_KEY)||'{}');
  const samples=Array.isArray(timings[key])?timings[key]:[];
  samples.push({patches:Math.max(1,Math.round(Number(patchCount)||1)),seconds:Math.max(1,Math.round(seconds)),at:Date.now()});
  timings[key]=samples.slice(-16);
  const keys=Object.keys(timings).sort((a,b)=>Number((timings[b]||[]).slice(-1)[0]?.at||0)-Number((timings[a]||[]).slice(-1)[0]?.at||0));
  keys.slice(20).forEach(oldKey=>delete timings[oldKey]);
  localStorage.setItem(METER_ICC_BUILD_TIMING_KEY,JSON.stringify(timings));
 }catch(error){}
}

function meterIccBuildWorkScale(family,patchCount){
 const count=Math.max(16,Math.round(Number(patchCount)||16));
 return family==='matrix'
  ?(.82+.18*Math.sqrt(count/175))
  :(.68+.32*Math.sqrt(count/175));
}

function meterIccMedian(values){
 const sorted=values.filter(Number.isFinite).sort((a,b)=>a-b);
 if(!sorted.length) return 0;
 const middle=Math.floor(sorted.length/2);
 return sorted.length%2?sorted[middle]:(sorted[middle-1]+sorted[middle])/2;
}

function meterIccEstimatedBuildRange(config,patchCount){
 const count=Math.max(16,Math.round(Number(patchCount)||16));
 const model=String((config&&config.profile_model)||'clut');
 const family=meterIccProfileModelInfo(model).family;
 const quality=String((config&&config.profile_quality)||'medium').toLowerCase();
 const scale=meterIccBuildWorkScale(family,count);
 let learned=[];
 try{
  const timings=JSON.parse(localStorage.getItem(METER_ICC_BUILD_TIMING_KEY)||'{}');
  const samples=Array.isArray(timings[meterIccBuildTimingKey(config)])?timings[meterIccBuildTimingKey(config)]:[];
  learned=samples.filter(sample=>Number(sample.seconds)>=5&&Number(sample.patches)>0).map(sample=>
   Number(sample.seconds)*scale/meterIccBuildWorkScale(family,Number(sample.patches))
  );
 }catch(error){}
 if(!learned.length){
  try{
   const legacy=JSON.parse(localStorage.getItem(METER_ICC_LEGACY_BUILD_TIMING_KEY)||'{}');
   const exact=Number(legacy[family+':'+model+':'+quality+':'+count]);
   if(Number.isFinite(exact)&&exact>=5) learned=[exact];
  }catch(error){}
 }
 const base=family==='matrix'
  ?({low:14,medium:26,high:48,ultra:90,l:14,m:26,h:48,u:90}[quality]||26)
  :({low:260,medium:480,high:780,ultra:1650,l:260,m:480,h:780,u:1650}[quality]||480);
 const expected=learned.length?meterIccMedian(learned):base*scale;
 const spread=learned.length>=3?.22:learned.length?.32:.38;
 return {
  expected:Math.max(10,Math.round(expected)),
  low:Math.max(5,Math.round(expected*(1-spread))),
  high:Math.max(20,Math.round(expected*(1+spread))),
  learned:learned.length
 };
}

function meterIccStartBuildClock(status,config,patchCount){
 const clock={startedAt:Date.now(),estimate:meterIccEstimatedBuildRange(config,patchCount),timer:null,config,patchCount};
 const update=()=>{
  if(!status) return;
  const elapsed=Math.max(0,(Date.now()-clock.startedAt)/1000);
  const lowTotal=Math.max(elapsed,clock.estimate.low);
  const highTotal=Math.max(elapsed+60,clock.estimate.high);
  const lowRemaining=Math.max(0,lowTotal-elapsed);
  const highRemaining=Math.max(60,highTotal-elapsed);
  const remaining=lowRemaining<30
   ?('up to '+meterIccFormatDuration(highRemaining)+' remaining')
   :(meterIccFormatDuration(lowRemaining)+' to '+meterIccFormatDuration(highRemaining)+' remaining');
  status.textContent='Measurements complete. Building the ICC profile. Elapsed '+meterIccFormatDuration(elapsed)+'. Estimated '+remaining+'.'
   +(clock.estimate.learned?' Based on previous builds on this browser.':'');
 };
 update();
 clock.timer=setInterval(update,1000);
 return clock;
}

function meterIccStartMeasurementClock(total){
 meterIccMeasurementClock={startedAt:Date.now(),lastStep:0,lastStepAt:0,samples:[],total:Math.max(0,Number(total)||0)};
}

function meterIccMeasurementRemaining(current,total){
 const clock=meterIccMeasurementClock;
 if(!clock||current<=0||total<=0) return '';
 const now=Date.now();
 if(current!==clock.lastStep){
  if(clock.lastStep>0&&clock.lastStepAt>0&&current>clock.lastStep){
   const perPatch=(now-clock.lastStepAt)/1000/Math.max(1,current-clock.lastStep);
   if(perPatch>=.25&&perPatch<=300) clock.samples.push(perPatch);
   clock.samples=clock.samples.slice(-12);
  }
  clock.lastStep=current;
  clock.lastStepAt=now;
 }
 if(clock.samples.length<2) return ' Estimating remaining time from the first few patches.';
 const perPatch=meterIccMedian(clock.samples);
 const measurementRemaining=Math.max(0,(total-current)*perPatch);
 const config=meterIccRunConfig||{};
 const finalPatchCount=config.stage==='precondition'
  ?Math.max(1,Number((config.patch_settings||{}).patch_count)||total)
  :((config.steps||[]).length||total);
 const build=meterIccEstimatedBuildRange(config,finalPatchCount);
 let extraMeasurement=0;
 let preparation=0;
 if(config.stage==='precondition'){
  extraMeasurement=Math.max(0,Number((config.patch_settings||{}).patch_count)||0)*perPatch;
  preparation=60;
 }
 const low=Math.max(0,measurementRemaining+extraMeasurement+preparation+build.low);
 const high=Math.max(low+30,measurementRemaining+extraMeasurement+preparation+build.high);
 return ' Estimated profiling time remaining: '+meterIccFormatDuration(low)+' to '+meterIccFormatDuration(high)+'.';
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

// The ICC workspace no longer carries a correction selector: profile builds
// always measure the uncorrected path, so there is nothing to choose. The
// calibration workspace keeps its selector for measurement and verification,
// which makes it the source of truth for everything except a profile build.
function meterIccCompanionCorrectionValue(){
 const calibration=document.getElementById('meterCalibrationCompanionCorrectionMode');
 const requested=String((calibration||{}).value||'system');
 return ['system','none','clut','matrix'].includes(requested)?requested:'system';
}

async function meterIccPushCompanionDisplaySettings(showError,correctionOverride,windowOverride){
 const mode=windowOverride||String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window');
 const correctionMode=correctionOverride||meterIccCompanionCorrectionValue();
 const activeSignal=String((typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr').toLowerCase()==='hdr10'?'hdr10':'sdr';
 meterIccCompanionSettingsPending++;
 try{
  const response=await fetchJSON('/api/icc/companion/settings',{
   method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({settings_protocol:2,window_mode:mode,patch_size:meterIccCompanionPatchSizeValue(),correction_mode:correctionMode,correction_signal_mode:activeSignal}),
   _quiet:true,_timeoutMs:5000
  });
  if(!response||response.status!=='ok') throw new Error(response&&response.message?response.message:'Could not update PGenerator+ Patch Companion');
  return true;
 }catch(error){
  if(showError!==false) toast(error&&error.message?error.message:'Could not update PGenerator+ Patch Companion',true);
  return false;
 }finally{
  meterIccCompanionSettingsPending=Math.max(0,meterIccCompanionSettingsPending-1);
 }
}

async function meterIccCompanionCycleFullscreen(forceFullscreen,correctionOverride){
 // Re-entering fullscreen exercises Windows' presentation-promotion path.
 // Measured on hardware: a swapchain demoted to composed by a profile
 // apply's Advanced Color cycle re-promotes to hardware-overlay after a
 // windowed round-trip, with no user input -- where renderer recreation,
 // activation calls and injected clicks are all denied. Skip when the
 // operator runs windowed: there is nothing to promote.
 const configured=forceFullscreen?'fullscreen':String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window');
 if(configured!=='fullscreen') return;
 await meterIccPushCompanionDisplaySettings(false,correctionOverride,'window');
 await new Promise(resolve=>setTimeout(resolve,2500));
 await meterIccPushCompanionDisplaySettings(false,correctionOverride,'fullscreen');
 await new Promise(resolve=>setTimeout(resolve,3500));
}

function meterIccCompanionCorrectionChanged(source){
 // Only the calibration workspace still carries a correction selector. The
 // ICC workspace has none: a profile build forces no correction for its whole
 // run, so there was nothing to choose and every choice but one was a trap.
 meterIccCompanionCorrectionInitialized=true;
 meterIccSyncUi();
 meterIccPushCompanionDisplaySettings(true);
}

async function meterIccRestoreCompanionCorrectionAfterProfile(){
 const mode=meterIccCompanionProfileRestoreMode;
 meterIccCompanionProfileRestoreMode='';
 if(!mode||meterIccPatternProvider()!=='companion') return;
 await meterIccPushCompanionDisplaySettings(false,mode);
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
   description:'Standard Dynamic Range ICC display profile built from measured patches with ArgyllCMS. Choose a compact shaper/matrix model or an XYZ cLUT with matrix fallback.',
   compatibility:'Portable conventional ICC for Linux, Windows, macOS and other ICC-aware software. No MHC2 system-calibration data, so unmanaged desktop output is not corrected.',
   install:''
  },
  'windows-sdr':{
   mode:'sdr',
   description:'SDR ICC for Windows Advanced Color. With calibration enabled, a measured MHC2 matrix corrects primaries and white while per-channel curves correct response to the selected target. No calibration keeps MHC2 identity for a display already calibrated internally.',
   compatibility:'Windows 10 version 2004+ Advanced Color, or KDE Plasma 6.5.3+ on Wayland. Apps that ignore MHC2 still get the standard matrix or cLUT fallback.',
   install:'Windows: Settings > System > Display > Color profile. Plasma 6.5.3+: select the file as the display ICC profile in System Settings.'
  },
  'kde-hdr':{
   mode:'hdr10',
   description:'HDR display ICC without MHC2. Intended for system-wide HDR color management where the compositor can apply the full BToA cLUT (for example KWin on Plasma).',
   compatibility:'KDE Plasma 6.7+ on Wayland with HDR enabled. For Windows Advanced Color, use HDR with MHC2 instead.',
   install:'Plasma 6.7+: enable HDR and select this file as the display HDR ICC profile in System Settings.'
  },
  'windows-hdr':{
   mode:'hdr10',
   description:'HDR ICC for Windows Advanced Color. With calibration enabled, MHC2 uses a measured 3x3 matrix and per-channel response curves. No calibration keeps the MHC2 transform identity while retaining measured luminance metadata for a TV or display already calibrated internally.',
   compatibility:'Windows Advanced Color or KDE Plasma 6.7+ on Wayland with HDR enabled. Do not use the legacy Color Management dialog for the Windows HDR association.',
   install:'Windows: enable HDR, then Settings > System > Display > Color profile as the HDR display default. Plasma 6.7+: enable HDR and select the file as the display ICC profile.'
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
  small:{patch_count:55,white_patches:1,black_patches:1,gray_steps:17,single_channel_steps:9,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:0,good_optimization:true,auto_precondition:false,profile_quality:'medium'},
  medium:{patch_count:95,white_patches:2,black_patches:2,gray_steps:25,single_channel_steps:13,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:10,good_optimization:true,auto_precondition:false,profile_quality:'high'},
  large:{patch_count:225,white_patches:4,black_patches:4,gray_steps:51,single_channel_steps:17,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:false,profile_quality:'ultra'}
 },
 clut:{
  small:{patch_count:175,white_patches:4,black_patches:4,gray_steps:38,single_channel_steps:9,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'medium'},
  medium:{patch_count:425,white_patches:4,black_patches:4,gray_steps:101,single_channel_steps:17,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'high'},
  large:{patch_count:1000,white_patches:4,black_patches:4,gray_steps:257,single_channel_steps:25,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:50,dark_emphasis:20,good_optimization:true,auto_precondition:true,profile_quality:'ultra'}
 }
};

const METER_ICC_PROFILE_MODELS={
 clut:{label:'XYZ cLUT + matrix',family:'clut',mhc2:true,note:'Recommended for detailed characterization. Creates an XYZ cLUT plus accurate matrix/TRC fallback tags so software without cLUT support can still use the profile.'},
 xyz_clut:{label:'XYZ cLUT only',family:'clut',mhc2:false,note:'Creates only an XYZ lookup-table transform. Can model nonlinear color interactions, but has no matrix fallback for software that ignores display cLUT tags.'},
 lab_clut:{label:'Lab cLUT only',family:'clut',mhc2:false,note:'Creates a Lab PCS lookup-table profile. Mainly useful for compatibility testing and specialized color-managed workflows. No matrix fallback.'},
 xyz_clut_debug_matrix:{label:'XYZ cLUT + debug matrix',family:'clut',mhc2:false,note:'ArgyllCMS display XYZ cLUT with a debug matrix (colprof -aY). Useful for comparing matrix versus cLUT behavior. Not a production MHC2 fallback path.'},
 matrix:{label:'Shaper + matrix',family:'matrix',mhc2:true,note:'Independent RGB shaper curves and a 3x3 colorant matrix. Compact, broadly compatible, and a good choice for displays with mostly separable channel behavior.'},
 matrix_only:{label:'Matrix only',family:'matrix',mhc2:false,note:'A 3x3 colorant matrix with identity tone curves, so the profile describes the display as linear light. Smallest model; only meaningful when the signal path is already linearised. Not available for MHC2 profiles.'},
 single_curve_matrix:{label:'Single shaper + matrix',family:'matrix',mhc2:true,note:'One shared shaper curve for all three channels plus a 3x3 matrix. Preserves neutral balance but cannot model different per-channel tone responses.'},
 gamma_matrix:{label:'Gamma + matrix',family:'matrix',mhc2:true,note:'A separate simple gamma exponent for each RGB channel plus a 3x3 matrix. Smaller but less flexible than full shaper curves.'},
 single_gamma_matrix:{label:'Single gamma + matrix',family:'matrix',mhc2:true,note:'One shared gamma exponent plus a 3x3 matrix. Highly compatible, but only suitable for displays with a simple shared channel response.'}
};

function meterIccProfileModelInfo(value){
 return METER_ICC_PROFILE_MODELS[value]||METER_ICC_PROFILE_MODELS.clut;
}

function meterIccStructuredPatchEstimate(settings){
 const white=Math.max(0,Math.round(Number(settings.white_patches)||0));
 const black=Math.max(0,Math.round(Number(settings.black_patches)||0));
 const gray=Math.max(0,Math.round(Number(settings.gray_steps)||0));
 const single=Math.max(0,Math.round(Number(settings.single_channel_steps)||0));
 const cube=Math.max(0,Math.round(Number(settings.cube_steps)||0));
 const surface=Math.max(0,Math.round(Number(settings.cube_surface_steps)||0));
 const bcc=Math.max(0,Math.round(Number(settings.bcc_steps)||0));
 let total=white+black+gray+Math.max(0,single-2)*3;
 if(cube>=2) total+=cube*cube*cube;
 if(surface>=2){
  const inner=Math.max(0,surface-2);
  total+=(surface*surface*surface)-(inner*inner*inner);
 }
 if(bcc>=2) total+=(bcc*bcc*bcc)+(Math.max(0,bcc-1)**3);
 return total;
}

function meterIccNeutralPatchCount(settings){
 const white=Math.max(0,Math.round(Number(settings.white_patches)||0));
 const black=Math.max(0,Math.round(Number(settings.black_patches)||0));
 const gray=Math.max(2,Math.round(Number(settings.gray_steps)||2));
 // Argyll's -g count includes the black and white endpoints. The separately
 // requested -B/-e repeats replace those two endpoints in the final chart.
 return Math.max(0,gray-2)+black+white;
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
  cube_steps:Math.max(0,Math.min(21,Math.round(number('meterIccCubeSteps',0)))),
  cube_surface_steps:Math.max(0,Math.min(21,Math.round(number('meterIccCubeSurfaceSteps',0)))),
  bcc_steps:Math.max(0,Math.min(21,Math.round(number('meterIccBccSteps',0)))),
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
 set('meterIccCubeSteps',preset.cube_steps!=null?preset.cube_steps:0);
 set('meterIccCubeSurfaceSteps',preset.cube_surface_steps!=null?preset.cube_surface_steps:0);
 set('meterIccBccSteps',preset.bcc_steps!=null?preset.bcc_steps:0);
 set('meterIccNeutralEmphasis',preset.neutral_emphasis);
 set('meterIccDarkEmphasis',preset.dark_emphasis);
 const good=document.getElementById('meterIccGoodOptimization');
 if(good) good.checked=!!preset.good_optimization;
 const auto=document.getElementById('meterIccAutoPrecondition');
 if(auto) auto.checked=!!preset.auto_precondition;
 // Patch count and table resolution are independent choices. Keep the
 // resolution the user selected even when changing patch presets or models.
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
 if(profileType==='windows-sdr'||profileType==='sdr'){
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
 return {patch_count:34,white_patches:2,black_patches:2,gray_steps:8,single_channel_steps:5,cube_steps:0,cube_surface_steps:0,bcc_steps:0,neutral_emphasis:.5,dark_emphasis:.2,good_optimization:true};
}

function meterIccProfileTypeChanged(){
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const mhc2=type==='windows-sdr'||type==='windows-hdr';
 const modelSelect=document.getElementById('meterIccProfileModel');
 if(modelSelect){
  Array.from(modelSelect.options).forEach(option=>{
   const supported=!mhc2||meterIccProfileModelInfo(option.value).mhc2;
   option.disabled=!supported;
   option.title=supported?'':'MHC2 profiles require matrix and shaper/tone-curve fallback tags.';
  });
  if(mhc2&&!meterIccProfileModelInfo(modelSelect.value).mhc2){
   modelSelect.value='clut';
   meterIccApplyPatchPreset(String((document.getElementById('meterIccQuality')||{}).value||'medium'));
  }
 }
 const calibration=document.getElementById('meterIccCalibrationMode');
 if(calibration&&calibration.dataset.profileType!==type){
  calibration.value=mhc2?'profile':'vcgt';
  calibration.dataset.profileType=type;
 }
 const cicpFields=document.getElementById('meterIccCicpFields');
 if(cicpFields&&cicpFields.dataset.profileType!==type){
  const defaults=meterIccDefaultCicp(type);
  const set=(id,value)=>{ const element=document.getElementById(id); if(element) element.value=String(value); };
  set('meterIccCicpPrimaries',defaults.colour_primaries);
  set('meterIccCicpTransfer',defaults.transfer_characteristics);
  set('meterIccCicpMatrix',defaults.matrix_coefficients);
  set('meterIccCicpRange',defaults.video_full_range_flag);
  cicpFields.dataset.profileType=type;
 }
 meterIccSyncUi();
 meterIccRefreshRecoveryAvailability();
}

function meterIccCalibrationModeChanged(){
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const calibration=document.getElementById('meterIccCalibrationMode');
 if(calibration) calibration.dataset.profileType=type;
 meterIccSyncUi();
}

function meterIccDefaultCicp(type){
 const hdr=type==='kde-hdr'||type==='windows-hdr';
 return hdr
  ?{colour_primaries:9,transfer_characteristics:16,matrix_coefficients:0,video_full_range_flag:1}
  :{colour_primaries:1,transfer_characteristics:13,matrix_coefficients:0,video_full_range_flag:1};
}

function meterIccCicpSettings(){
 const number=(id,fallback)=>{
  const value=Number((document.getElementById(id)||{}).value);
  return Number.isInteger(value)?value:fallback;
 };
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const defaults=meterIccDefaultCicp(type);
 return {
  colour_primaries:number('meterIccCicpPrimaries',defaults.colour_primaries),
  transfer_characteristics:number('meterIccCicpTransfer',defaults.transfer_characteristics),
  matrix_coefficients:number('meterIccCicpMatrix',defaults.matrix_coefficients),
  video_full_range_flag:number('meterIccCicpRange',defaults.video_full_range_flag)
 };
}

function meterIccEffectiveVersion(type){
 const selected=String((document.getElementById('meterIccVersion')||{}).value||'auto');
 return selected==='auto'?(type==='kde-hdr'?'4.4':'2.2'):selected;
}

function meterIccFormatChanged(){
 meterIccSyncUi();
}

function meterIccCicpChanged(){
 const type=String((document.getElementById('meterIccProfileType')||{}).value||'sdr');
 const fields=document.getElementById('meterIccCicpFields');
 if(fields) fields.dataset.profileType=type;
 meterIccSyncUi();
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
 const summary=document.getElementById('meterIccRunSummary');
 const start=document.getElementById('meterIccStartBtn');
 const startHint=document.getElementById('meterIccStartBtnHint');
 const quality=String((document.getElementById('meterIccQuality')||{}).value||'medium');
 const profileModel=String((document.getElementById('meterIccProfileModel')||{}).value||'clut');
 const profileModelInfo=meterIccProfileModelInfo(profileModel);
 const profileQuality=String((document.getElementById('meterIccProfileQuality')||{}).value||'high');
 const calibrationMode=meterIccCalibrationModeValue();
 const selectedIccVersion=String((document.getElementById('meterIccVersion')||{}).value||'auto');
 const effectiveIccVersion=meterIccEffectiveVersion(type);
 const cicp=meterIccCicpSettings();
 const patchSettings=meterIccPatchSettings();
 const count=patchSettings.patch_count+(type==='windows-hdr'?1:0);
 const preRead=patchSettings.auto_precondition&&!patchSettings.precondition_profile;
 const patchMinimum=meterIccStructuredPatchEstimate(patchSettings);
 const invalidPatchSet=patchSettings.patch_count<patchMinimum;
 const transferField=document.getElementById('meterIccTargetTransferField');
 const transfer=meterIccTargetTransferInfo(meterIccTargetTransferValue());
 const selectsSdrTarget=(type==='windows-sdr'||type==='sdr')&&calibrationMode!=='none';
 if(transferField) transferField.style.display=selectsSdrTarget?'':'none';
 const cicpFields=document.getElementById('meterIccCicpFields');
 const versionNote=document.getElementById('meterIccVersionNote');
 if(cicpFields) cicpFields.style.display=effectiveIccVersion==='4.4'?'':'none';
 if(versionNote) versionNote.textContent=selectedIccVersion==='auto'
  ?('Automatic selects ICC v'+effectiveIccVersion+(effectiveIccVersion==='4.4'?' with CICP.':'.'))
  :(effectiveIccVersion==='4.4'?'The profile will use the selected four CICP code points.':'ICC v2.2 does not contain a CICP tag.');
 const setTip=(id,text)=>{ const el=document.getElementById(id); if(el) el.setAttribute('data-tip',String(text||'')); };
 const typeTip=[info.description,info.compatibility,info.install].filter(Boolean).join(' ');
 setTip('meterIccProfileTypeHelp',typeTip);
 setTip('meterIccProfileModelHelp',profileModelInfo.note+(profileModelInfo.mhc2?'':' Not available for MHC2 profile categories.'));
 setTip('meterIccTargetTransferHelp',transfer.note);
 const companionSetup=document.getElementById('meterIccCompanionSetup');
 const localSetup=document.getElementById('meterIccLocalSetup');
 const delayNote=document.getElementById('meterIccStartDelayNote');
 const companionWindowMode=String((document.getElementById('meterIccCompanionWindowMode')||{}).value||'window');
 const companionPatchSizeField=document.getElementById('meterIccCompanionPatchSizeField');
 const patchSizeNote=document.getElementById('meterIccPatchSizeNote');
 const companionDisplayModeNote=document.getElementById('meterIccCompanionDisplayModeNote');
 const companionCorrectionMode=meterIccCompanionCorrectionValue();
 const companionCorrectionNote=document.getElementById('meterIccCompanionCorrectionNote');
 const calibrationCorrectionMode=document.getElementById('meterCalibrationCompanionCorrectionMode');
 const calibrationCorrectionNote=document.getElementById('meterCalibrationCompanionCorrectionNote');
 const calibrationWindowMode=document.getElementById('meterCalibrationCompanionWindowMode');
 const calibrationPatchSize=document.getElementById('meterCalibrationCompanionPatchSize');
 const calibrationPatchSizeField=document.getElementById('meterCalibrationCompanionPatchSizeField');
 const calibrationDisplayModeNote=document.getElementById('meterCalibrationCompanionDisplayModeNote');
 if(companionSetup) companionSetup.style.display=usesCompanion?'':'none';
 if(localSetup) localSetup.style.display=usesCompanion?'none':'';
 const delayTip=usesCompanion
  ?'For single-monitor setups using the same computer for the WebUI and profiling, this delay gives you time to switch the display to the required input before measurements begin.'
  :'The delay gives you time to switch the display to the PGenerator+ HDMI input before measurements begin.';
 if(delayNote) delayNote.textContent=delayTip;
 setTip('meterIccStartDelayHelp',delayTip);
 if(companionPatchSizeField) companionPatchSizeField.style.display=(!usesCompanion||companionWindowMode==='fullscreen')?'':'none';
 if(calibrationWindowMode&&calibrationWindowMode.value!==companionWindowMode) calibrationWindowMode.value=companionWindowMode;
 if(calibrationPatchSize){
  const patchSize=String(meterIccCompanionPatchSizeValue());
  if(Array.from(calibrationPatchSize.options).some(option=>option.value===patchSize)) calibrationPatchSize.value=patchSize;
 }
 if(calibrationPatchSizeField) calibrationPatchSizeField.style.display=companionWindowMode==='fullscreen'?'':'none';
 const patchSizeTip=usesCompanion
  ?'Linked to Patch Size in the Calibration workspace. Window and APL selections are applied live to the running Companion.'
  :'Linked to Patch Size in the Calibration workspace and used by the PGenerator+ HDMI output.';
 if(patchSizeNote) patchSizeNote.textContent=patchSizeTip;
 setTip('meterIccPatchSizeHelp',patchSizeTip);
 const companionModeTip=companionWindowMode==='fullscreen'
  ?('The Companion uses a borderless fullscreen window. The selected centered window or APL pattern is rendered using the chosen patch size.'+(type==='windows-hdr'?' The HDR metadata white uses this same patch size.':'')+' Press F11 on the Companion computer to exit fullscreen.')
  :('Each patch fills the movable Companion window. Resize and position that window on the display being profiled.'+(type==='windows-hdr'?' The HDR metadata white uses this same window geometry.':''));
 if(companionDisplayModeNote) companionDisplayModeNote.textContent=companionModeTip;
 setTip('meterIccCompanionDisplayModeHelp',companionModeTip);
 if(calibrationDisplayModeNote) calibrationDisplayModeNote.textContent=companionWindowMode==='fullscreen'
  ?'The Companion uses a borderless fullscreen window and renders the selected centered window or APL patch size. Press F11 on the Companion computer to exit fullscreen.'
  :'Each patch fills the movable Companion window. Resize and position that window on the display being measured.';
 if(calibrationCorrectionMode){
  const calibrationMode=['system','none','clut','matrix'].includes(companionCorrectionMode)?companionCorrectionMode:'system';
  if(calibrationCorrectionMode.value!==calibrationMode) calibrationCorrectionMode.value=calibrationMode;
 }
 const correctionNote=companionCorrectionMode==='none'
  ?'The Companion submits every patch exactly as sent, with no transform of any kind. Profiling selects this automatically so the characterization measures the panel itself.'
  :(companionCorrectionMode==='system'
  ?(meterIccCompanionPlatform==='linux'
   ?'The compositor applies whatever ICC profile is assigned to the display, so patches are measured through that correction. Assign the profile you want to verify, and clear it before profiling so the characterization measures the raw panel.'
   :'The Companion leaves profile handling to Windows, but on fullscreen HDR it applies the active profile MHC2 stage itself because Windows skips it there. This is not a no-correction mode.')
  :(companionCorrectionMode==='clut'
   ?('The Companion applies the cLUT from the profile currently active for its selected display.'+(meterIccCompanionPlatform==='linux'
     ?' KWin applies an assigned profile itself, so clear it from the display first or the correction lands twice.'
     :' Disable MHC2 system correction while using this mode to avoid applying the correction twice.'))
   :('The Companion applies the matrix and tone-curve fallback from the profile currently active for its selected display.'+(meterIccCompanionPlatform==='linux'
     ?' KWin applies an assigned profile itself, so clear it from the display first or the correction lands twice.'
     :' Disable MHC2 system correction while using this mode to avoid applying the correction twice.'))));
 // The ICC workspace note is a fixed statement in the markup: a profile build
 // always forces no correction, so it must not track the calibration card's
 // selector. Only the calibration note is dynamic.
 void companionCorrectionNote;
 if(calibrationCorrectionNote) calibrationCorrectionNote.textContent=companionCorrectionMode==='clut'
  ?'The Companion explicitly applies the active profile B2A cLUT, then submits the corrected patch through its native HDR swapchain.'
  :(companionCorrectionMode==='matrix'
   ?'The Companion explicitly applies the active profile matrix and tone curves, then submits the corrected patch through its native HDR swapchain.'
   :(companionCorrectionMode==='none'
    ?'The Companion submits the unmodified patch through its native HDR swapchain and applies no transform at all.'
    :'The Companion submits the patch through its native HDR swapchain and leaves profile handling to Windows, except on fullscreen HDR where it applies the active profile MHC2 stage itself.'));
 const qualitySelect=document.getElementById('meterIccQuality');
 if(qualitySelect) Array.from(qualitySelect.options).forEach(option=>{
  const label=String(option.value).charAt(0).toUpperCase()+String(option.value).slice(1);
  const preset=(METER_ICC_PATCH_PRESETS[profileModelInfo.family]||{})[String(option.value)];
  option.textContent=preset
   ?(label+', '+(preset.patch_count+(type==='windows-hdr'?1:0))+' patches, '+meterIccNeutralPatchCount(preset)+' neutral')
   :(label+', '+count+' patches');
 });
 const patchCountLabel=document.getElementById('meterIccPatchCountLabel');
 const neutralPatchCount=document.getElementById('meterIccNeutralPatchCount');
 const neutralLabel=document.getElementById('meterIccNeutralEmphasisLabel');
 const darkLabel=document.getElementById('meterIccDarkEmphasisLabel');
 if(patchCountLabel) patchCountLabel.textContent=String(patchSettings.patch_count);
 if(neutralPatchCount) neutralPatchCount.textContent='('+meterIccNeutralPatchCount(patchSettings)+' final patches)';
 if(neutralLabel) neutralLabel.textContent=Math.round(patchSettings.neutral_emphasis*100)+'%';
 if(darkLabel) darkLabel.textContent=Math.round(patchSettings.dark_emphasis*100)+'%';
 const meterLabel=typeof meterSelectedMeasurementLabel==='function'?meterSelectedMeasurementLabel(null):'Meter';
 const displayOptions=(document.getElementById('meterIccDisplayType')||{}).selectedOptions;
 const displayLabel=displayOptions&&displayOptions[0]?String(displayOptions[0].textContent||'').trim():'Auto';
 const correction=(document.getElementById('meterIccMeterProfile')||{}).selectedOptions;
 const correctionLabel=correction&&correction[0]?String(correction[0].textContent||'').trim():'Auto';
 const insertion=!!((document.getElementById('meterIccPatternInsertion')||{}).checked);
 const companionPatchSizeSelect=document.getElementById('meterIccCompanionPatchSize');
 const companionPatchSizeOption=companionPatchSizeSelect&&companionPatchSizeSelect.selectedOptions?companionPatchSizeSelect.selectedOptions[0]:null;
 const generatorLabel=usesCompanion
  ?('PGenerator+ Patch Companion '+(companionWindowMode==='fullscreen'?('fullscreen, '+String(companionPatchSizeOption?companionPatchSizeOption.textContent:'controlled patch')):'resizable window'))
  :'PGenerator+ HDMI';
 if(summary) summary.textContent=invalidPatchSet
  ?('Increase total patches to at least '+patchMinimum+' for the selected structured patch coverage.')
  :(generatorLabel+' output: '+info.mode.toUpperCase()+'. Algorithm: '+profileModelInfo.label+' at '+profileQuality+' table resolution. ICC v'+effectiveIccVersion+(effectiveIccVersion==='4.4'?' CICP '+cicp.colour_primaries+'/'+cicp.transfer_characteristics+'/'+cicp.matrix_coefficients+'/'+cicp.video_full_range_flag:'')+'. Calibration: '+({vcgt:'With VCGT',profile:'Without VCGT',none:'None'}[calibrationMode])+'. Meter: '+meterLabel+'. Display: '+displayLabel+'. Meter correction: '+correctionLabel+'. Pattern insertion: '+(insertion?'On':'Off')+'. '+count+' profile patches'+(preRead?' plus a 34-patch optimization pre-read':'')+'.'+(selectsSdrTarget?' Target: '+transfer.label+'.':'')+(!usesCompanion?' '+localMode.message:''));
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
  const startReason=!meterDetected?'Connect a meter first':!meterReady?'Waiting for the meter settings to finish loading':invalidPatchSet?('Increase total patches to at least '+patchMinimum):usesCompanion&&!meterIccCompanionConnected?'Start PGenerator+ Patch Companion on the target computer before profiling':busy?'A meter operation is already running':!usesCompanion&&!localMode.matches?'Start profiling to review and apply the required output mode':'Start the ICC profiling measurements';
  start.title='';
  if(startHint){
   const companionTip=start.disabled&&generatorUnavailable?'Start PGenerator+ Patch Companion on the target computer before profiling':'';
   startHint.title='';
   startHint.dataset.tooltip=companionTip;
   startHint.setAttribute('aria-label',startReason);
  }
 }
 const retry=document.getElementById('meterIccRetryBuildBtn');
 const retryCount=Number(retry&&retry.dataset?retry.dataset.measurementCount:0);
 if(retry&&retryCount>0){
  retry.textContent='Rebuild with '+retryCount+' Measurements';
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

// Last platform reported by the connected Companion ('windows', 'linux', '').
var meterIccCompanionPlatform='';
// Version of the connected Companion, so capability gating can follow the build
// rather than the platform. Empty means nothing is connected yet.
var meterIccCompanionVersion='';

// The cLUT and matrix modes transform the patch inside the Companion using the
// display's active OS profile, so they need a build that can read it. Offering
// a mode that cannot work is worse than not offering it: it fails at the first
// patch and takes the run down with it.
function meterIccApplyCompanionCorrectionAvailability(){
 // Two separate questions. WHICH OS is connected decides what the modes are
 // called -- naming the compositor "Windows" in front of a Linux user is just
 // wrong. WHETHER the build can read the display's active profile decides if
 // the active-profile modes are offered at all: on Linux that arrived with
 // 1.4.2, which asks KWin for the assignment including Plasma 6.7's separate
 // HDR slot. Conflating the two made the label revert the moment a capable
 // Linux Companion connected.
 const isLinux=meterIccCompanionPlatform==='linux';
 const cannotReadProfile=isLinux&&
  (!meterIccCompanionVersion||meterIccVersionBelow(meterIccCompanionVersion,'1.4.2'));
 ['meterCalibrationCompanionCorrectionMode','meterIccCompanionCorrectionMode'].forEach(function(id){
  const select=document.getElementById(id);
  if(!select) return;
  let reselect=false;
  Array.prototype.forEach.call(select.options,function(option){
   const unavailable=cannotReadProfile&&(option.value==='clut'||option.value==='matrix');
   option.hidden=unavailable;
   option.disabled=unavailable;
   if(unavailable&&select.value===option.value) reselect=true;
  });
  const system=select.querySelector('option[value="system"]');
  if(system) system.textContent=isLinux?'Compositor profile handling (KWin)':'Windows profile handling';
  // A stored selection from a Windows session must not survive onto a Linux
  // Companion as a hidden-but-selected value.
  if(reselect){
   select.value='none';
   if(typeof meterIccCompanionCorrectionChanged==='function')
    meterIccCompanionCorrectionChanged(id.indexOf('Calibration')>=0?'calibration':'icc');
  }
 });
}


// Asset filenames match what icc_companion_package.py produces, so a release
// built from that same packager output can be uploaded to GitHub unchanged.
const METER_ICC_GITHUB_RELEASE_ASSETS={
 'windows-x64':'PGeneratorPlus-ICC-Tools-Windows-x64.exe',
 'windows-portable-x64':'PGeneratorPlus-ICC-Tools-Portable-Windows-x64.zip',
 'linux-x64':'PGeneratorPlus-ICC-Tools-Linux-x64.zip'
};

// Which package this visitor most likely wants. A connected Companion is the
// only reliable answer, because the WebUI is routinely open on a phone or a
// second machine while a different computer is the one being profiled; the
// browser is only guessed from when nothing is connected to ask.
function meterIccPreferredDownloadPlatform(){
 if(meterIccCompanionPlatform==='linux') return 'linux-x64';
 if(meterIccCompanionPlatform==='windows') return 'windows-x64';
 const hint=String((navigator.userAgentData&&navigator.userAgentData.platform)||navigator.platform||navigator.userAgent||'');
 if(/win/i.test(hint)) return 'windows-x64';
 if(/linux|x11|cros/i.test(hint)&&!/android/i.test(hint)) return 'linux-x64';
 return '';
}

// Marks the matching release button as the primary action wherever a download
// row is rendered, so the visitor is not left choosing between three packages
// with nothing to tell them apart. Runs on every status poll because the
// answer changes the moment a Companion connects or goes away.
function meterIccApplyDownloadRecommendation(){
 const preferred=meterIccPreferredDownloadPlatform();
 // The release page lists every platform, so rather than choosing for the
 // visitor, name the file they want. Runs on every status poll because the
 // answer changes the moment a Companion connects or goes away.
 const labels={'windows-x64':'the Windows installer','windows-portable-x64':'the Windows portable zip','linux-x64':'the KDE/Linux zip'};
 const hint=document.getElementById('meterIccReleaseHint');
 if(hint) hint.textContent=labels[preferred]?('Look for '+labels[preferred]+'.'):'';
}

// GitHub redirects "latest/download/<asset>" to whichever release is newest,
// so this needs no version lookup and works even though the Pi itself has no
// internet route -- the browser does the fetching, not the server. Opened in
// a new tab because it leaves the WebUI (and any running measurement) in
// place. This copy is unpaired: it discovers this PGenerator+ by resolving
// pgenerator.local and waits for approval through the pairing prompt below.
// Opens the release PAGE, not an asset. Chrome and Edge judge a download by
// the origin of the page that started it, so a direct asset link from this
// plain-http WebUI is flagged insecure however the asset itself is served.
// Navigating to GitHub first makes the download originate there, over https,
// and the browser is satisfied. It also means one button instead of three
// guesses at which platform the visitor wants.
function meterIccOpenGithubRelease(){
 window.open('https://github.com/BigShoots/Pgenerator_Plus_ICC_Tools/releases/latest','_blank','noopener');
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
   ?'Use the connected PGenerator+ Patch Companion for patch generation'
   :'Run PGenerator+ Patch Companion on the target computer to enable this option';
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
 meterIccAppendCompanionVersionWarning(target,connected);
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
 await saveMeterSettings();
 const connected=await meterIccRefreshCompanionStatus();
 if(meterCalibrationUsesCompanion()&&connected){
  if(!await meterCalibrationPushCompanionCorrection()) return;
  try{ await fetchJSON('/api/icc/companion/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'align'}),_quiet:true,_timeoutMs:5000}); }catch(e){}
 }else if(typeof meterRefreshStabilizationIdlePattern==='function'){
  await meterRefreshStabilizationIdlePattern(false);
 }
}
async function meterCalibrationPushCompanionCorrection(){
 const calibrationCorrection=document.getElementById('meterCalibrationCompanionCorrectionMode');
 const requested=String((calibrationCorrection||{}).value||'system');
 const mode=['system','none','clut','matrix'].includes(requested)?requested:'system';
 if(calibrationCorrection) calibrationCorrection.value=mode;
 meterIccSyncUi();
 return meterIccPushCompanionDisplaySettings(true);
}
async function meterCalibrationRequirePatternProvider(){
 if(meterCalibrationReadPatternProvider()!=='companion') return true;
 const connected=await meterIccRefreshCompanionStatus();
 if(connected) return meterCalibrationPushCompanionCorrection();
 toast('Run the paired PGenerator+ Patch Companion on the target computer before reading',true);
 return false;
}

// Numeric version compare so 1.3.9 sorts below 1.3.36 rather than above it,
// which a string compare would get wrong exactly where it matters.
// Append the out-of-date notice under a connected status line. An outdated
// Companion silently mismatches the profile it is handed -- the correction
// stages moved between releases -- so it is reported where the connection is,
// not left to be discovered in the measurements.
function meterIccAppendCompanionVersionWarning(target,connected){
 if(!target||!connected||!meterIccCompanionOutdated) return;
 const warn=document.createElement('div');
 warn.style.color='var(--red)';
 warn.style.marginTop='2px';
 warn.textContent=meterIccCompanionOutdated;
 target.append(warn);
}

const METER_ICC_GITHUB_VERSION_KEY='pgen.iccGithubVersion.v2';
const METER_ICC_GITHUB_VERSION_TTL_MS=6*60*60*1000;
const METER_ICC_GITHUB_VERSION_REFRESH_MS=30*60*1000;
let meterIccGithubVersionCache='';
let meterIccGithubVersionCacheLoaded=false;
let meterIccGithubVersionLastAttempt=0;
let meterIccGithubVersionInFlight=false;

// Talks straight to the GitHub API rather than through the Pi: this network's
// Pi has no internet route or nameserver, so a server-side lookup would always
// fail, but the operator's browser normally does have one, and an http page
// fetching an https URL is not the mixed-content direction browsers block.
// Every failure mode -- offline, DNS, a 403 rate limit, CORS, malformed JSON
// -- is swallowed here: this is a nice-to-have version hint, never something
// allowed to toast an error or stall the status poll that calls it.
async function meterIccFetchGithubLatestVersion(){
 let timer=null;
 try{
  const controller=new AbortController();
  timer=setTimeout(()=>controller.abort(),4000);
  const response=await fetch('https://api.github.com/repos/BigShoots/Pgenerator_Plus_ICC_Tools/releases/latest',{signal:controller.signal});
  if(!response||!response.ok) return '';
  const data=await response.json();
  const tag=String((data&&data.tag_name)||'').replace(/^v/i,'');
  return /^[0-9]+(\.[0-9]+){1,3}$/.test(tag)?tag:'';
 }catch(error){ return ''; }
 finally{ if(timer) clearTimeout(timer); }
}

// Refresh the latest-release version in the background. A cached value remains
// useful as an offline fallback, but it must not suppress the network check:
// otherwise a browser opened shortly before a release can call the previous
// Companion current for the entire cache lifetime. Recheck periodically so an
// already-open WebUI notices a newly published release too.
function meterIccRefreshGithubVersionCache(force){
 const now=Date.now();
 if(!meterIccGithubVersionCacheLoaded){
  meterIccGithubVersionCacheLoaded=true;
  try{
   const cached=JSON.parse(localStorage.getItem(METER_ICC_GITHUB_VERSION_KEY)||'null');
   const cachedVersion=String((cached&&cached.version)||'');
   if(cached&&typeof cached==='object'&&(now-Number(cached.time||0))<METER_ICC_GITHUB_VERSION_TTL_MS&&/^[0-9]+(\.[0-9]+){1,3}$/.test(cachedVersion)){
    meterIccGithubVersionCache=cachedVersion;
   }
  }catch(error){}
 }
 if(meterIccGithubVersionInFlight||(!force&&(now-meterIccGithubVersionLastAttempt)<METER_ICC_GITHUB_VERSION_REFRESH_MS)) return;
 meterIccGithubVersionLastAttempt=now;
 meterIccGithubVersionInFlight=true;
 meterIccFetchGithubLatestVersion().then(version=>{
  if(!version) return;
  const changed=version!==meterIccGithubVersionCache;
  meterIccGithubVersionCache=version;
  try{ localStorage.setItem(METER_ICC_GITHUB_VERSION_KEY,JSON.stringify({version:version,time:Date.now()})); }catch(error){}
  if(changed&&meterIccCompanionConnected) meterIccRefreshCompanionStatus();
 }).finally(()=>{ meterIccGithubVersionInFlight=false; });
}

// One render function for both companion-status locations (the ICC workspace
// modal and the calibration card), fed the same pair_requests array from the
// status poll, so the two prompts can never drift the way separately
// maintained renderers have before in this codebase.
function meterIccRenderPairRequestsInto(container,requests,rowClass,metaClass,codeClass){
 container.textContent='';
 if(!Array.isArray(requests)||!requests.length) return;
 requests.forEach(function(request){
  const id=String((request&&request.id)||'');
  if(!id) return;
  const row=document.createElement('div');
  row.className=rowClass;
  const meta=document.createElement('div');
  meta.className=metaClass;
  const client=String((request&&request.client)||'a computer');
  const platform=String((request&&request.platform)||'');
  const ip=String((request&&request.ip)||'');
  meta.textContent='"'+client+'"'+(platform?' ('+platform+')':'')+(ip?' at '+ip:'')+' wants to pair. Check that this code matches the one shown on the Companion, then approve or deny:';
  const code=document.createElement('span');
  code.className=codeClass;
  code.textContent=String((request&&request.code)||'------');
  const approve=document.createElement('button');
  approve.type='button';
  approve.className='btn btn-sm btn-primary';
  approve.textContent='Approve';
  approve.onclick=()=>meterIccDecidePairRequest(id,'approve');
  const deny=document.createElement('button');
  deny.type='button';
  deny.className='btn btn-sm btn-danger';
  deny.textContent='Deny';
  deny.onclick=()=>meterIccDecidePairRequest(id,'deny');
  row.append(meta,code,approve,deny);
  container.appendChild(row);
 });
}

function meterIccRenderPairRequests(requests){
 const icc=document.getElementById('meterIccPairRequests');
 if(icc) meterIccRenderPairRequestsInto(icc,requests,'meter-icc-pair-row','meter-icc-pair-meta','meter-icc-pair-code');
 const calibration=document.getElementById('meterCalibrationPairRequests');
 if(calibration) meterIccRenderPairRequestsInto(calibration,requests,'meter-companion-pair-row','meter-companion-pair-meta','meter-companion-pair-code');
}

async function meterIccDecidePairRequest(id,action){
 try{
  await fetchJSON('/api/icc/companion/pair-decide',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({request:id,action:action}),_quiet:true,_timeoutMs:5000});
 }catch(error){}
 meterIccRefreshCompanionStatus();
}

function meterIccVersionBelow(have,want){
 if(!have||!want) return false;
 const a=String(have).split('.').map(n=>parseInt(n,10)||0);
 const b=String(want).split('.').map(n=>parseInt(n,10)||0);
 for(let i=0;i<Math.max(a.length,b.length);i++){
  const x=a[i]||0, y=b[i]||0;
  if(x!==y) return x<y;
 }
 return false;
}

function meterIccVersionAtLeast(have,want){
 return !!have&&!meterIccVersionBelow(have,want);
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
 meterIccAppendCompanionVersionWarning(target,connected);
}

function meterIccUpdateTopCompanionStatus(connected,detail){
 const wrap=document.getElementById('iccCompanionTopStatusWrap');
 if(!wrap) return;
 wrap.style.display=connected?'':'none';
 wrap.title=connected?String(detail||'PGenerator+ Patch Companion connected'):'PGenerator+ Patch Companion not connected';
 const dot=document.getElementById('iccCompanionTopDot');
 const text=document.getElementById('iccCompanionTopStatusText');
 if(dot) dot.style.background='var(--green)';
 if(text){
  text.textContent='PGenerator+ Patch Companion'+(meterIccCompanionClient?' ['+meterIccCompanionClient+']':'');
  text.style.color='var(--text)';
 }
 if(typeof syncTopStatusStack==='function') syncTopStatusStack();
}

async function meterIccRefreshCompanionStatus(){
 // Fire-and-forget: this only ever primes a cache that the outdated-version
 // check below reads synchronously, so it cannot delay this poll.
 meterIccRefreshGithubVersionCache();
 try{
  const state=await fetchJSON('/api/icc/companion/status',{_quiet:true,_timeoutMs:3500});
  // Shown in both companion-status locations regardless of connection state --
  // an unpaired Companion is by definition not connected yet, so the approval
  // prompt has to appear anyway.
  meterIccRenderPairRequests(state&&Array.isArray(state.pair_requests)?state.pair_requests:[]);
  const windowMode=document.getElementById('meterIccCompanionWindowMode');
  if(windowMode&&state&&['window','fullscreen'].includes(String(state.window_mode||''))) windowMode.value=String(state.window_mode);
  const reportedConnected=!!(state&&state.connected);
  const companionJustConnected=reportedConnected&&!meterIccCompanionReportedConnected;
  meterIccCompanionReportedConnected=reportedConnected;
  if(companionJustConnected) meterIccRefreshGithubVersionCache(true);
  if(reportedConnected) meterIccCompanionLastSeenAt=Date.now();
  meterIccCompanionConnected=reportedConnected||(meterIccCompanionLastSeenAt>0&&Date.now()-meterIccCompanionLastSeenAt<12000);
  if(reportedConnected){
   const client=String(state.client||'target computer');
   meterIccCompanionClient=client;
   const renderer=String(state.renderer||'renderer');
   const version=String(state.version||'');
   // Prefer the newest GitHub release tag; fall back to what this PGenerator
   // ships (read from the Companion source tree) when that lookup has not
   // resolved, which keeps offline behavior identical to before this existed.
   const shipped=String(state.shipped_version||'');
   const latestKnown=meterIccGithubVersionCache||shipped;
   meterIccCompanionOutdated=meterIccVersionBelow(version,latestKnown)
    ?('Patch Companion '+version+' is out of date. A newer version ('+latestKnown+') is available from the GitHub release. Download and install it before profiling or reading.')
    :'';
   const hdr=state.hdr_active?' with native HDR active':'';
   const swapchain=String(state.swapchain_color_space||'');
   const presentation=String(state.presentation_mode||'');
   const outputMax=Number(state.output_max_luminance)||0;
   const outputFull=Number(state.output_full_frame_luminance)||0;
   const outputBits=Number(state.output_bits_per_color)||0;
   const correctionMode=String(state.correction_mode||'system');
   const transformMode=String(state.transform_mode||correctionMode);
   const transformReady=state.transform_ready!==false;
   const selectedDisplay=String(state.selected_display||'');
   if(!meterIccCompanionCorrectionInitialized&&!meterIccCompanionSettingsPending&&['system','none','clut','matrix'].includes(correctionMode)){
    const calibrationMode=document.getElementById('meterCalibrationCompanionCorrectionMode');
    if(calibrationMode) calibrationMode.value=correctionMode;
    meterIccCompanionCorrectionInitialized=true;
   }
   const activeProfile=String(state.active_profile||'');
   const platform=String(state.platform||'');
   // Remembered so the correction selector can hide the modes this Companion
   // cannot perform. Only the status response carries the platform and version.
   meterIccCompanionPlatform=platform;
   meterIccCompanionVersion=String(state.version||'');
   meterIccApplyCompanionCorrectionAvailability();
   const transformNote=String(state.transform_note||'');
   // The Companion only reads the display's active OS profile on Windows, so an
   // empty name there means none was found, while elsewhere it means the build
   // never looks. Saying which keeps an unavailable feature from reading as a
   // missing profile. "system" mode does not load an ICC inside the Companion;
   // on Linux the compositor still applies the display profile KDE has set.
   const profileLabel=activeProfile?' ['+activeProfile+']':(platform==='linux'?' [OS profile not reported by Linux Companion]':' [none detected]');
   const correction=transformMode==='clut'?(' using active-profile cLUT'+profileLabel):transformMode==='matrix'?(' using active-profile matrix/TRC'+profileLabel):(platform==='linux'?' leaving color management to the compositor (KDE/colord profile still applies outside the app)':' using no application profile correction');
   const transformState=transformMode!==correctionMode?' [requested transform not yet applied]':(!transformReady?(' [transform not ready'+(transformNote?': '+transformNote:'')+']'):'');
   // "none" is the Windows swapchain reporting no HDR colorspace, not a missing
   // value; spell that out rather than leaving a bare "[none]" on screen.
   const swapchainLabel=swapchain==='none'?'no HDR swapchain':swapchain;
   const nativeDetail=swapchain&&swapchain!=='unknown'
    ?(' ['+swapchainLabel+(presentation&&presentation!=='unknown'?', '+presentation:'')+(outputBits?', '+outputBits+'-bit':'')+(outputMax?', peak '+outputMax.toFixed(1)+' cd/m²':'')+(outputFull?', full-frame '+outputFull.toFixed(1)+' cd/m²':'')+']')
    :'';
   const detail='Connected: '+client+(selectedDisplay?' on '+selectedDisplay:'')+' using '+renderer+hdr+nativeDetail+correction+transformState+(version?' (v'+version+')':'');
   meterIccCompanionDetail=detail;
   meterIccShowCompanionStatus(true,detail);
   meterCalibrationShowCompanionStatus(true,detail);
  }else if(!meterIccCompanionConnected){ meterIccShowCompanionStatus(false,'Companion not connected'); meterCalibrationShowCompanionStatus(false,'Companion not connected'); }
 }catch(error){
  meterIccCompanionConnected=meterIccCompanionLastSeenAt>0&&Date.now()-meterIccCompanionLastSeenAt<12000;
  if(!meterIccCompanionConnected){ meterIccShowCompanionStatus(false,'Companion not connected'); meterCalibrationShowCompanionStatus(false,'Companion not connected'); }
 }
 meterIccUpdateTopCompanionStatus(meterIccCompanionConnected,meterIccCompanionDetail);
 document.querySelectorAll('.meter-icc-install-profile').forEach(button=>{
  button.style.display=meterIccCompanionConnected&&meterIccVersionAtLeast(meterIccCompanionVersion,'1.4.11')?'':'none';
 });
 meterCalibrationApplyCompanionAvailability(meterIccCompanionConnected);
 // Out here rather than in the success branch so the recommendation is still
 // right when the status request itself failed and only the browser guess is
 // available to go on.
 meterIccApplyDownloadRecommendation();
 meterIccSyncUi();
 return meterIccCompanionConnected;
}

async function meterIccLoadProfiles(){
 const list=document.getElementById('meterIccProfileList');
 if(!list) return;
 try{
  // A build or fine-tune calls this right after writing a new profile; do
  // not let the browser reuse a pre-build response for the listing.
  const response=await fetchJSON('/api/icc/profiles?_='+Date.now(),{_quiet:true,_timeoutMs:5000,cache:'no-store'});
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
   // Fine-tuned profiles are results of post-correction, not characterization
   // aids: keep them selectable but clearly labeled and listed after the base
   // profiles so a pre-conditioning pick defaults to an original build.
   profiles.filter(p=>!p.finetune).concat(profiles.filter(p=>p.finetune)).forEach(profile=>{
    const option=document.createElement('option');
    option.value=profile.name;
    option.textContent=profile.name+(profile.finetune?' — fine-tuned':'');
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
   // Rows are newest first; the date makes that ordering visible and tells the
   // user which of several similarly named builds they are about to download.
   const created=document.createElement('span');
   created.className='meter-icc-profile-date';
   const stamp=Number(profile&&profile.mtime||0);
   if(stamp>0){
    const when=new Date(stamp*1000);
    created.textContent=when.toLocaleString([], {year:'numeric',month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
    created.title='Created '+when.toString();
   } else {
    created.textContent='date unknown';
   }
   const download=document.createElement('button');
   download.type='button';
   download.className='btn btn-sm btn-primary';
   download.textContent='Download';
   download.onclick=()=>{ window.location.href='/api/icc/download?file='+encodeURIComponent(profile.name); };
   const install=document.createElement('button');
   install.type='button';
   install.className='btn btn-sm btn-success meter-icc-install-profile';
   install.textContent='Install & Apply';
   install.title='Install this profile on the target computer and apply it to the display used by Patch Companion';
   install.style.display=meterIccCompanionConnected&&meterIccVersionAtLeast(meterIccCompanionVersion,'1.4.11')?'':'none';
   install.onclick=()=>meterIccInstallProfile(profile.name,install);
   if(profile.finetune){
    const badge=document.createElement('span');
    badge.className='meter-icc-profile-date';
    badge.textContent='fine-tuned';
    badge.title='Created by a post-correction fine-tune pass from measured reads of the applied parent profile';
    name.appendChild(document.createTextNode(' '));
    name.appendChild(badge);
   }
   const finetune=document.createElement('button');
   finetune.type='button';
   finetune.className='btn btn-sm btn-secondary';
   finetune.textContent='Fine tune';
   const finetuneEligible=!!profile.tunable;
   // Keep the action in a consistent place for every profile. Imported or
   // diagnostic profiles without embedded characterization data cannot be
   // adjusted safely, so explain that case instead of silently removing the
   // control from the row.
   finetune.disabled=!finetuneEligible;
   finetune.title=finetuneEligible
    ?'Apply this profile, read a grey series through it and create a corrected fine-tuned copy in the history'
    :'Fine tuning requires a profile with embedded characterization data and an adjustable MHC2 or BToA stage';
   finetune.style.display=meterIccCompanionConnected&&meterIccVersionAtLeast(meterIccCompanionVersion,'1.4.11')?'':'none';
   finetune.onclick=()=>meterIccFineTuneProfile(profile.name,finetune,profile.tune_mode||'hdr10',profile.tune_color!==false,profile.has_mhc2===true);
   const validate=document.createElement('button');
   validate.type='button';
   validate.className='btn btn-sm btn-secondary';
   validate.textContent='Self-check';
   validate.disabled=!profile.validation;
   validate.title=profile.validation?'View the ArgyllCMS profcheck results':'No saved self-check is available for this profile';
   validate.onclick=()=>meterIccOpenValidation(profile.name);
   const cube=document.createElement('button');
   cube.type='button';
   cube.className='btn btn-sm btn-secondary';
   cube.textContent='3D LUT';
   const cubeEligible=!!profile.has_clut;
   // Keep the action in a consistent place for every profile, matching the
   // Fine tune button: matrix-only or imported profiles explain why the
   // conversion is unavailable instead of losing the control.
   cube.disabled=!cubeEligible;
   cube.title=cubeEligible
    ?'Convert this profile’s correction cLUT into a 3D LUT (.cube) and add it to the 3D LUT workspace'
    :'3D LUT conversion requires a profile with a BToA cLUT stage';
   cube.onclick=()=>meterIccConvertProfileToCube(profile.name,cube);
   const remove=document.createElement('button');
   remove.type='button';
   remove.className='btn btn-sm btn-danger';
   remove.textContent='×';
   remove.title='Delete this profile';
   remove.setAttribute('aria-label','Delete '+profile.name);
   remove.onclick=()=>meterIccDeleteProfile(profile.name);
   row.append(name,created,download,install,finetune,validate,cube,remove);
   list.appendChild(row);
  });
 }catch(error){
  list.textContent='Could not load created profiles.';
 }
}

// Live progress for the fine-tune session. State lives at module level so
// every stage update can re-render the whole list; hiding the modal only
// hides it — the session keeps running and the button label still shows the
// same progress.
let meterIccFineTuneProgress=null;

function meterIccFineTuneProgressRender(){
 const s=meterIccFineTuneProgress;
 if(!s) return;
 const esc=value=>String(value==null?'':value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
 const passLabel=document.getElementById('meterIccFineTunePassLabel');
 if(passLabel) passLabel.textContent=s.pass>0?('Pass '+s.pass+' of up to '+s.maxPasses):'Preparing session...';
 const fileLabel=document.getElementById('meterIccFineTuneFile');
 if(fileLabel) fileLabel.textContent='Fine-tuning '+s.file+' — each pass applies the current profile, measures it, corrects it, and re-checks until improvement stops. The best measured pass is kept.';
 const list=document.getElementById('meterIccFineTuneSteps');
 if(list){
  const colors={pending:'var(--text2)',active:'var(--warning)',done:'var(--success)',error:'var(--danger)',skipped:'var(--text2)'};
  const markers={pending:'○',active:'●',done:'✓',error:'✕',skipped:'—'};
  list.innerHTML=s.steps.map(step=>'<div style="display:flex;gap:10px;align-items:flex-start;padding:6px 0;border-bottom:1px solid var(--border)">'
   +'<span style="color:'+(colors[step.state]||colors.pending)+';width:14px;flex:none;text-align:center">'+(markers[step.state]||markers.pending)+'</span>'
   +'<div style="min-width:0"><div style="color:'+(step.state==='pending'||step.state==='skipped'?'var(--text2)':'var(--text)')+';font-weight:'+(step.state==='active'?'700':'400')+'">'+esc(step.label)+'</div>'
   +(step.detail?'<div class="meter-icc-note" style="margin-top:2px">'+esc(step.detail)+'</div>':'')
   +'</div></div>').join('');
 }
 const history=document.getElementById('meterIccFineTuneHistory');
 if(history) history.innerHTML=s.notes.map(note=>esc(note)).join('<br>');
}

function meterIccFineTuneProgressOpen(file,tuneColor,maxPasses){
 meterIccFineTuneProgress={file:String(file||''),maxPasses:Number(maxPasses)||4,pass:0,notes:[],activeKey:null,tuneColor:tuneColor!==false,
  steps:[
   {key:'apply',label:'Apply the profile on the target computer',state:'pending',detail:''},
   {key:'grey',label:'Read the grey ladder through the applied profile',state:'pending',detail:''},
   {key:'color',label:'Read colour patches through the applied profile',state:'pending',detail:''},
   {key:'tune',label:'Compute corrections and update the profile',state:'pending',detail:''},
   {key:'evaluate',label:'Evaluate convergence',state:'pending',detail:''},
   {key:'finalize',label:'Keep the best measured pass',state:'pending',detail:''}
  ]};
 if(tuneColor===false){
  const color=meterIccFineTuneProgress.steps.find(step=>step.key==='color');
  if(color){ color.state='skipped'; color.detail='Skipped — this profile tunes from grey reads alone'; }
 }
 meterIccFineTuneProgressRender();
 const modal=document.getElementById('meterIccFineTuneModal');
 if(modal){
  if(typeof meterEnsureModalOnBody==='function') meterEnsureModalOnBody(modal);
  modal.style.display='flex';
 }
 uiSyncBodyScrollLock();
}

function meterIccFineTuneProgressPass(pass){
 const s=meterIccFineTuneProgress;
 if(!s) return;
 s.pass=Number(pass)||0;
 s.steps.forEach(step=>{
  if(step.key==='finalize') return;
  if(step.key==='color'&&!s.tuneColor) return;
  step.state='pending';
  step.detail='';
 });
 meterIccFineTuneProgressRender();
}

function meterIccFineTuneProgressStep(key,state,detail){
 const s=meterIccFineTuneProgress;
 if(!s) return;
 const step=s.steps.find(entry=>entry.key===key);
 if(!step) return;
 step.state=String(state||'pending');
 step.detail=detail==null?step.detail:String(detail);
 s.activeKey=step.state==='active'?step.key:(s.activeKey===key?null:s.activeKey);
 meterIccFineTuneProgressRender();
}

function meterIccFineTuneProgressError(message){
 const s=meterIccFineTuneProgress;
 if(!s) return;
 const step=s.steps.find(entry=>entry.key===s.activeKey)||s.steps.find(entry=>entry.state==='active');
 if(step){ step.state='error'; step.detail=String(message||'Fine-tuning failed'); }
 else s.notes.push(String(message||'Fine-tuning failed'));
 meterIccFineTuneProgressRender();
}

function meterIccFineTuneProgressNote(text){
 const s=meterIccFineTuneProgress;
 if(!s) return;
 s.notes.push(String(text||''));
 meterIccFineTuneProgressRender();
}

let meterIccFineTuneCancelRequested=false;

function meterIccFineTuneCancel(){
 meterIccFineTuneCancelRequested=true;
 meterIccFineTuneProgressNote('Cancel requested — stopping after the current step and keeping the best measured pass.');
 // Abort an in-flight meter read so the session notices promptly.
 fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
 meterIccFineTuneProgressHide();
}

function meterIccFineTuneProgressHide(){
 const modal=document.getElementById('meterIccFineTuneModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

async function meterIccFineTuneProfile(file,button,tuneMode,tuneColor,tuneMhc2){
 if(!meterIccCompanionConnected){ toast('Start Patch Companion on the target computer first',true); return; }
 if(meterIccRunning||meterSeriesRunning){ toast('Wait for the active meter work to finish first',true); return; }
 const original=button?button.textContent:'Fine tune';
 if(button){ button.disabled=true; }
 // An AutoCal-style session: apply, read the grey ladder, adjust the profile,
 // re-apply and re-read, until every level converges inside the tolerance or
 // the pass budget runs out. Every pass overwrites one public output file,
 // while the server privately checkpoints the best profile actually measured.
 const MAX_PASSES=4;
 const TARGET_DE=1.0;
 // cLUT profiles use colour reads for local cell edits. MHC2 profiles use
 // them for a bounded, D65-preserving residual matrix correction.
 const TUNE_COLOR=tuneColor!==false;
 const outStem=file.replace(/\.icc$/i,'').replace(/-FineTuned(?:-\d+)?$/,'')+'-FineTuned';
 const session=Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,14);
 const passes=[];
 let currentFile=file;
 let sessionStarted=false;
 let finalized=false;
 let sessionAnchorY=0;
 const mhc2Path=tuneMhc2===true;
 const tuneWindowOverride=mhc2Path?'fullscreen':undefined;
 const tuneCorrectionOverride=mhc2Path?'system':undefined;
 // Sessions may follow an exit-fullscreen from a previous run; re-assert the
 // measurement path before the first apply and read. Windows MHC2 must be
 // graded through Windows system handling on a fullscreen HDR swapchain.
 await meterIccPushCompanionDisplaySettings(
  false,tuneCorrectionOverride,tuneWindowOverride);
 meterIccFineTuneCancelRequested=false;
 meterIccFineTuneProgressOpen(file,TUNE_COLOR,MAX_PASSES);
 const cancelCheck=()=>{ if(meterIccFineTuneCancelRequested) throw new Error('Fine-tune cancelled'); };
 const anchorProblem=(anchorY,pass)=>{
  if(!(anchorY>0)) return 'The 66% pipeline canary did not return a usable luminance reading';
  if(pass===1){
   sessionAnchorY=anchorY;
   if(Math.abs(anchorY/429-1)>0.12) return 'The display pipeline is tone-mapping (66% grey read '+anchorY.toFixed(0)+' cd/m², expected ~429). The presentation path is not suitable for fine-tuning.';
  }else if(sessionAnchorY>0&&anchorY<sessionAnchorY*0.90){
   return 'The display pipeline degraded between passes (66% grey fell from '+sessionAnchorY.toFixed(0)+' to '+anchorY.toFixed(0)+' cd/m²). Keeping the best measured pass.';
  }
  return '';
 };
 const installOnTarget=async targetFile=>{
  const queued=await fetchJSON('/api/icc/companion/profile-install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({file:targetFile})});
  if(!queued||queued.status!=='ok'||!queued.job) throw new Error(queued&&queued.message||'Could not queue profile installation');
  for(let i=0;i<40;i++){
   await new Promise(resolve=>setTimeout(resolve,1500));
   const state=await fetchJSON('/api/icc/companion/profile-install-status?job='+encodeURIComponent(queued.job),{_quiet:true,_timeoutMs:5000});
   if(state&&state.status==='ok'&&/applied/i.test(String(state.message||''))) return;
   if(state&&state.status==='error') throw new Error(state.message||'Profile installation failed');
  }
  throw new Error('Profile installation timed out');
 };
 try{
  let lastResult=null;
  for(let pass=1;pass<=MAX_PASSES;pass++){
   cancelCheck();
   // The first pass needs enough authority to make a useful correction.  A
   // later pass is a residual/recovery edit and must be gentler so one noisy
   // toe or exact-white read cannot swing the MHC2 curve back past the target.
   const passDamping=pass===1?0.5:0.35;
   if(button) button.textContent='Pass '+pass+': applying...';
   meterIccFineTuneProgressPass(pass);
   meterIccFineTuneProgressStep('apply','active','Installing '+currentFile+' on the target computer and applying it to the display');
   await installOnTarget(currentFile);
   // Build 4 deliberately completes its post-install MHC2 foreground handoff
   // when the first HDR patch arrives. Before that command, the last idle
   // frame can legitimately still report "composed". Waiting for overlay here
   // deadlocks the recovery by refusing to send the patch that triggers it.
   // The in-series check below remains authoritative because patch delivery is
   // acknowledged only after the Companion has completed the handoff and
   // presented the calibrated frame again.
   meterIccFineTuneProgressStep('apply','done','Installed '+currentFile+'; confirming the calibrated HDR response with the first measurement patch');
   meterIccFineTuneProgressStep('grey','active','Starting the grey ladder reads...');
   // Measure the 66% pipeline canary first. DXGI can report "composed" on a
   // healthy AMD HDR path, so the measured PQ response is authoritative. A
   // genuinely tone-mapped path is rejected after one read instead of after
   // most of the ladder. The tuner keys samples by code and does not depend
   // on acquisition order.
   const percents=[66,0,5,10,15,20,25,30,40,50,55,58,60,62,64,68,70,72,74,75,76,78,80,85,90,95,100];
   const steps=percents.map(pct=>({ire:pct,r:Math.round(pct*1023/100),g:Math.round(pct*1023/100),b:Math.round(pct*1023/100),input_max:1023}));
   const body=meterMeasurementSignalContext({
    type:'colors',points:990001,custom_series:true,custom_steps:steps,
    display_type:String((document.getElementById('meterIccDisplayType')||{}).value||getEffectiveDisplayType()),
    ccss_override:String((document.getElementById('meterIccMeterProfile')||{}).value||''),
    target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',
    target_gamma:meterAutoCalTargetGammaValue(),delay_ms:meterDelayMs(),
    patch_size:getMeterPatchSize(),refresh_rate:getMeterRefreshRate()||undefined,
    require_device_ready:meterSelectedMeasurementRequiresReady(),
    pattern_provider:'companion',
    ...meterPatternInsertionPayload(document.getElementById('meterIccPatternInsertion'))
   });
   body.observer='1931_2';
   body.target_white_use_measured=false;
   body.target_black_use_measured=false;
   body.series_has_saved_white_reference=true;
   body.series_has_saved_black_reference=true;
   body.signal_mode=(tuneMode||'hdr10')==='hdr10'?'hdr10':'sdr';
   if(body.signal_mode==='hdr10'){ body.signal_range='2'; body.pattern_signal_range='2'; body.transport_signal_range='2'; body.max_luma='1000'; }
   const started=await fetchJSON('/api/meter/series',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),_timeoutMs:12000});
   if(!started||started.status!=='started') throw new Error(started&&started.message||'Could not start the fine-tune reads');
   let readings=null;
   let anchorChecked=false;
   for(let i=0;i<600;i++){
    await new Promise(resolve=>setTimeout(resolve,2000));
    cancelCheck();
    const state=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:120000});
    if(button) button.textContent='Pass '+pass+': reading '+(state&&state.current_step||0)+'/'+steps.length;
    meterIccFineTuneProgressStep('grey','active','Reading level '+(state&&state.current_step||0)+'/'+steps.length);
    if(body.signal_mode==='hdr10'&&!anchorChecked&&state&&Array.isArray(state.readings)){
     const liveAnchor=state.readings.find(r=>Number(r&&r.ire)===66&&r.r_code===r.g_code&&r.g_code===r.b_code);
     if(liveAnchor){
      const liveAnchorY=Number(liveAnchor.Y||liveAnchor.luminance||0);
      const problem=anchorProblem(liveAnchorY,pass);
      if(problem){
       await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
       throw new Error(problem);
      }
      anchorChecked=true;
      meterIccFineTuneProgressNote('Pass '+pass+': 66% pipeline canary '+liveAnchorY.toFixed(1)+' cd/m²');
     }
    }
    if(state&&state.status==='complete'){ readings=state.readings||[]; break; }
    if(state&&(state.status==='error'||state.status==='stopped')) throw new Error('Fine-tune reads did not complete');
   }
   if(!readings||!readings.length) throw new Error('Fine-tune reads did not complete');
   if(body.signal_mode==='hdr10'&&!anchorChecked){
    const anchor=readings.find(r=>Number(r&&r.ire)===66&&r.r_code===r.g_code&&r.g_code===r.b_code);
    const anchorY=anchor?Number(anchor.Y||anchor.luminance||0):0;
    const problem=anchorProblem(anchorY,pass);
    if(problem) throw new Error(problem);
   }
   meterIccFineTuneProgressStep('grey','done','Measured '+readings.length+' grey levels');
   // Colour patches through the same applied profile. The chart carries the
   // server's absolute targets per patch, so the tuner can correct the cLUT
   // cells around each measured colour as well as the grey corridor.
   let colorReadings=[];
   if(TUNE_COLOR){
    if(button) button.textContent='Pass '+pass+': colour...';
    meterIccFineTuneProgressStep('color','active','Starting the colour patch reads...');
    const ccBody=Object.assign({},body);
    delete ccBody.custom_series; delete ccBody.custom_steps;
    ccBody.points=30;
    const ccStarted=await fetchJSON('/api/meter/series',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(ccBody),_timeoutMs:12000});
    if(ccStarted&&ccStarted.status==='started'){
     for(let i=0;i<600;i++){
      await new Promise(resolve=>setTimeout(resolve,2000));
      cancelCheck();
      const state=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:120000});
      if(button) button.textContent='Pass '+pass+': colour '+(state&&state.current_step||0)+'/30';
      meterIccFineTuneProgressStep('color','active','Reading patch '+(state&&state.current_step||0)+'/30');
      if(state&&state.status==='complete'){ colorReadings=state.readings||[]; break; }
      if(state&&(state.status==='error'||state.status==='stopped')) break;
     }
    }
    meterIccFineTuneProgressStep('color','done',colorReadings.length?('Measured '+colorReadings.length+' colour patches'):'No colour readings — continuing with grey corrections only');
   }
   if(button) button.textContent='Pass '+pass+': tuning...';
   meterIccFineTuneProgressStep('tune','active','Computing corrections and writing '+outStem+'.icc (damping '+passDamping+')');
   const result=await fetchJSON('/api/icc/finetune',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({file:currentFile,readings,color_readings:colorReadings,damping:passDamping,output:outStem,target_de:TARGET_DE,target_color_de:2.0,session,pass}),_timeoutMs:1800000});
   if(!result||result.status!=='ok') throw new Error(result&&result.message||'Fine-tuning failed');
   sessionStarted=true;
   const colourLevels=Array.isArray(result.color_levels)?result.color_levels:[];
   const measuredColourMean=Number(result.color_de&&result.color_de.mean);
   passes.push({pass,de:result.before_de||{},worst:Number(result.worst_de||0),
    score:Number(result.selection_score!=null?result.selection_score:result.worst_de||0),
    color_mean:Number.isFinite(measuredColourMean)?measuredColourMean:null,
    converged:!!result.converged,file:String(result.file||''),result});
   lastResult=result;
   const passEntry=passes[passes.length-1];
   const passSummary='worst grey '+(Number.isFinite(passEntry.worst)?passEntry.worst.toFixed(2):'--')+' dE'
    +(passEntry.color_mean==null?'':(', colour mean '+passEntry.color_mean.toFixed(2)));
   meterIccFineTuneProgressStep('tune','done','Corrections computed — measured '+passSummary);
   meterIccFineTuneProgressNote('Pass '+pass+': '+passSummary+(passEntry.converged?' (converged)':''));
   meterIccFineTuneProgressStep('evaluate','active','Checking convergence...');
   if(result.converged){
    // The currently applied profile already meets the tolerance everywhere.
    meterIccFineTuneProgressStep('evaluate','done','Converged — the applied profile meets the tolerance everywhere');
    break;
   }
   // Measured convergence: the grey axis keeps creeping down for a few
   // passes while colour reaches its floor after one, so stop when a pass
   // no longer improves either by a meaningful margin rather than waiting
   // for an absolute tolerance the noisy toe level may never satisfy.
   if(passes.length>1){
    const now=passes[passes.length-1], was=passes[passes.length-2];
    const priorWorst=Math.min(...passes.slice(0,-1).map(entry=>Number(entry.score)).filter(Number.isFinite));
    const grey=Number(now.worst), greyWas=Number(was.worst);
    const score=Number(now.score);
    const col=Number(now.color_mean), colWas=Number(was.color_mean);
    // A regressed read has already produced a new, lower-damping correction.
    // Measure that recovery candidate before deciding which checkpoint wins.
    // The old immediate stop discarded it and commonly restored pass 1, which
    // made the advertised FineTuned profile byte-identical to its parent.
    if(Number.isFinite(score)&&Number.isFinite(priorWorst)&&score>priorWorst*1.03){
     if(pass<MAX_PASSES){
      meterIccFineTuneProgressStep('evaluate','done','This pass regressed — measuring the damped recovery candidate in pass '+(pass+1));
      currentFile=outStem+'.icc';
      continue;
     }
     meterIccFineTuneProgressStep('evaluate','done','Pass budget reached after a regression — keeping the best measured pass');
     break;
    }
    const greyStalled=!Number.isFinite(grey)||!Number.isFinite(greyWas)||grey>greyWas*0.97;
    const colStalled=!Number.isFinite(col)||!Number.isFinite(colWas)||col>colWas*0.97;
    if(greyStalled&&colStalled){
     meterIccFineTuneProgressStep('evaluate','done','No meaningful improvement over the last pass — stopping and keeping the best pass');
     break;
    }
   }
   meterIccFineTuneProgressStep('evaluate','done',pass<MAX_PASSES?('Still improving — continuing to pass '+(pass+1)):'Pass budget reached — keeping the best measured pass');
   currentFile=outStem+'.icc';
  }
  if(!sessionStarted) throw new Error('Fine-tune session produced no measured checkpoint');
  if(button) button.textContent='Keeping best measured pass...';
  meterIccFineTuneProgressStep('finalize','active','Restoring the best measured profile from the session checkpoints...');
  const selected=await fetchJSON('/api/icc/finetune',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({action:'finalize',file:currentFile,output:outStem,session}),_timeoutMs:180000});
  if(!selected||selected.status!=='ok') throw new Error(selected&&selected.message||'Could not restore the best measured profile');
  const selectedFile=String(selected.file||outStem+'.icc');
  meterIccFineTuneProgressStep('finalize','active','Reapplying '+selectedFile+' so Windows reloads the selected MHC2 state...');
  await installOnTarget(selectedFile);
  finalized=true;
  meterIccFineTuneProgressStep('finalize','done','Kept and reapplied pass '+Number(selected.best_pass||0)+' as '+selectedFile);
  const selectedPass=passes.find(entry=>entry.pass===Number(selected.best_pass));
  passes.forEach(entry=>{ entry.selected=entry===selectedPass; });
  if(selectedPass&&selectedPass.result) lastResult=Object.assign({},selectedPass.result,{file:selected.file,selection:selected});
  else if(lastResult) lastResult=Object.assign({},lastResult,{file:selected.file,selection:selected});
  meterIccFineTuneProgressHide();
  meterIccShowFineTuneReport(file,lastResult,passes);
 }catch(error){
  // Do not leave a meter worker finishing the rest of a rejected ladder.
  await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
  // The modal stays open with the failed step marked so the user can see
  // where the session stopped; the toast still reports the message.
  meterIccFineTuneProgressError(error&&error.message?error.message:'Fine-tuning failed');
  // A failed later read must not strand the unverified candidate written by
  // the preceding pass. Best-effort finalization restores the checkpoint.
  if(sessionStarted&&!finalized){
   meterIccFineTuneProgressStep('finalize','active','Restoring the best measured checkpoint...');
   try{
    await fetchJSON('/api/icc/finetune',{method:'POST',headers:{'Content-Type':'application/json'},
     body:JSON.stringify({action:'finalize',file:currentFile,output:outStem,session}),_timeoutMs:180000});
    meterIccFineTuneProgressStep('finalize','done','Best measured checkpoint restore requested');
   }catch(_restoreError){}
  }
  toast(error&&error.message?error.message:'Fine-tuning failed',true);
 }finally{
  if(button){ button.disabled=false; button.textContent=original; }
  // Success and checkpoint-restored failures both leave a new or updated
  // -FineTuned profile behind; refresh the history either way.
  meterIccLoadProfiles();
  meterIccPushCompanionDisplaySettings(false);
 }
}

function meterIccShowFineTuneReport(parent,result,passes){
 const previous=document.getElementById('meterIccFineTuneReport');
 if(previous) previous.remove();
 const overlay=document.createElement('div');
 overlay.id='meterIccFineTuneReport';
 overlay.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.72);z-index:10024;display:flex;align-items:center;justify-content:center;padding:18px;box-sizing:border-box;';
 const card=document.createElement('div');
 // Wide two-column card: the long measured-grey ladder gets its own column so
 // the whole report fits without scrolling on a desktop viewport.
 card.style.cssText='width:min(1080px,100%);max-height:92vh;overflow:auto;background:#111723;border:1px solid #2a3140;border-radius:10px;padding:18px;box-sizing:border-box;color:var(--text2);';
 const fixed=value=>Number.isFinite(Number(value))?Number(value).toFixed(2):'--';
 const tableStyle='width:100%;border-collapse:collapse;font-size:.78rem;color:var(--text2)';
 const cell='padding:3px 10px 3px 0';
 const cellRight='padding:3px 0 3px 10px;text-align:right';
 const heading='font-size:.82rem;font-weight:700;color:var(--text);margin:0 0 6px';
 const note='opacity:.65;font-size:.72rem;margin-top:4px;line-height:1.45';
 let left='';
 if(Array.isArray(passes)&&passes.length){
  left+='<div style="margin-bottom:14px"><div style="'+heading+'">Session passes</div><table style="'+tableStyle+'">'
   +'<tr style="opacity:.7"><td style="'+cell+'">Pass</td><td style="'+cell+'">In-range mean/max</td><td style="'+cell+'">Rolloff mean/max</td><td style="'+cell+'">Colour mean</td><td style="'+cell+'">State</td></tr>';
  passes.forEach(entry=>{
   const de=entry.de||{};
   left+='<tr><td style="'+cell+'">'+entry.pass+'</td><td style="'+cell+'">'+fixed(de.inrange_mean)+' / '+fixed(de.inrange_max)+'</td>'
    +'<td style="'+cell+'">'+fixed(de.rolloff_mean)+' / '+fixed(de.rolloff_max)+'</td>'
    +'<td style="'+cell+'">'+(entry.color_mean==null?'--':fixed(entry.color_mean))+'</td>'
    +'<td style="'+cell+(entry.selected?';color:var(--success);font-weight:700':'')+'">'+(entry.selected?'kept':(entry.converged?'converged':'measured'))+'</td></tr>';
  });
  left+='</table><div style="'+note+'">Each row is measured through the profile applied at the start of that pass; dE ITP against absolute PQ in range, against D65 balance inside the rolloff.</div></div>';
 }
 if(result&&result.selection){
  left+='<div style="margin-bottom:14px">Kept pass '+Number(result.selection.best_pass||0)+' as the best measured result (score '+fixed(result.selection.best_score)+', worst grey '+fixed(result.selection.best_worst_de)+' dE ITP).</div>';
 }else if(!result.converged){
  left+='<div style="margin-bottom:14px">Corrections applied: mean '+fixed(result.mean_correction_pct)+'%, max '+fixed(result.max_correction_pct)+'% across '+Number(result.reads_used||0)+' measured levels.</div>';
 }
 const colorLevels=Array.isArray(result.color_levels)?result.color_levels:[];
 if(colorLevels.length){
  const mean=Number(result.color_de&&result.color_de.mean);
  const worst=colorLevels.slice().sort((a,b)=>Number(b.de2000||0)-Number(a.de2000||0)).slice(0,4);
  left+='<div style="margin-bottom:14px"><div style="'+heading+'">Colour patches</div>'
   +'<div style="margin-bottom:6px">'+Number(result.color_de&&result.color_de.patches||colorLevels.length)+' chromatic patches, mean '+fixed(mean)+' dE2000 before this pass. Largest errors:</div>'
   +'<table style="'+tableStyle+'"><tr style="opacity:.7"><td style="'+cell+'">Patch</td><td style="'+cellRight+'">Target</td><td style="'+cellRight+'">Measured</td><td style="'+cellRight+'">dE2000</td></tr>';
  worst.forEach(entry=>{
   left+='<tr><td style="'+cell+'">'+String(entry.name||'')+'</td><td style="'+cellRight+'">'+fixed(entry.target_nits)+'</td><td style="'+cellRight+'">'+fixed(entry.measured_nits)+'</td><td style="'+cellRight+'">'+fixed(entry.de2000)+'</td></tr>';
  });
  const mhc2=/^mhc2/.test(String(result.mode||''));
  const clut=colorLevels.some(entry=>entry.post_matrix_de2000!=null)||!mhc2;
  const method=mhc2&&clut?'The MHC2 matrix removes the global colour residual, then the cLUT corrects the remaining local error.':mhc2?'The MHC2 matrix removes the bounded global colour residual.':'The cLUT cells around each measured colour were adjusted by their interpolation share.';
  left+='</table><div style="'+note+'">'+method+' The grey corridor is corrected separately.</div></div>';
 }
 if(result.selfcheck){
  left+='<div style="margin-bottom:14px"><div style="'+heading+'">Self-check (ArgyllCMS profcheck, ΔE00 vs characterization)</div>'
   +'<table style="'+tableStyle+'"><tr style="opacity:.7"><td style="'+cell+'"></td><td style="'+cellRight+'">Average</td><td style="'+cellRight+'">Peak</td></tr>'
   +'<tr><td style="'+cell+'">Before</td><td style="'+cellRight+'">'+fixed(result.selfcheck.before_avg)+'</td><td style="'+cellRight+'">'+fixed(result.selfcheck.before_peak)+'</td></tr>'
   +'<tr><td style="'+cell+'">After</td><td style="'+cellRight+'">'+fixed(result.selfcheck.after_avg)+'</td><td style="'+cellRight+'">'+fixed(result.selfcheck.after_peak)+'</td></tr></table>'
   +'<div style="'+note+'">'+String(result.selfcheck.note||'')+'</div></div>';
 }
 let right='';
 if(Array.isArray(result.levels)&&result.levels.length){
  right+='<div><div style="'+heading+'">Measured grey error, before → predicted after</div>'
   +'<table style="'+tableStyle+'"><tr style="opacity:.7"><td style="'+cell+'">Level</td><td style="'+cellRight+'">Target cd/m²</td><td style="'+cellRight+'">Before</td><td style="'+cellRight+'">After</td></tr>';
  result.levels.forEach(level=>{
   right+='<tr><td style="'+cell+'">'+fixed(level.pct)+'%</td><td style="'+cellRight+'">'+fixed(level.target_nits)+'</td>'
    +'<td style="'+cellRight+'">'+fixed(level.before_err_pct)+'%</td>'
    +'<td style="'+cellRight+'">'+fixed(level.predicted_err_pct)+'%</td></tr>';
  });
  right+='</table><div style="'+note+'">Predicted values assume the damped, bounded corrections land as computed; run a verification read of the new profile to confirm.</div></div>';
 }
 card.innerHTML='<div style="font-size:1rem;font-weight:700;color:var(--text);margin-bottom:4px">Fine-tune '+(result&&result.converged?'converged':'complete')+'</div>'
  +'<div class="meter-icc-note" style="margin-bottom:14px">'+String(result.file||'')+' from '+String(parent||'')+'</div>'
  +'<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(400px,1fr));gap:0 28px;align-items:start"><div>'+left+'</div><div>'+right+'</div></div>';
 const close=document.createElement('button');
 close.type='button';
 close.className='btn btn-sm btn-primary';
 close.textContent='Close';
 close.style.marginTop='14px';
 close.onclick=()=>overlay.remove();
 card.appendChild(close);
 overlay.appendChild(card);
 overlay.onclick=event=>{ if(event.target===overlay) overlay.remove(); };
 document.body.appendChild(overlay);
}

async function meterIccInstallProfile(file,button){
 if(!meterIccCompanionConnected){ showToast('Start Patch Companion on the target computer first','error'); return; }
 const original=button?button.textContent:'Install & Apply';
 if(button){ button.disabled=true; button.textContent='Installing...'; }
 try{
  const queued=await fetchJSON('/api/icc/companion/profile-install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({file})});
  if(!queued||queued.status!=='ok'||!queued.job) throw new Error(queued&&queued.message||'Could not queue profile installation');
  const deadline=Date.now()+120000;
  while(Date.now()<deadline){
   await new Promise(resolve=>setTimeout(resolve,750));
   const state=await fetchJSON('/api/icc/companion/profile-install-status?job='+encodeURIComponent(queued.job),{_quiet:true,_timeoutMs:5000});
   if(state&&state.status==='ok'){
    showToast(state.message||('Installed and applied '+file),'success');
    await meterIccCompanionCycleFullscreen();
    return;
   }
   if(state&&state.status==='error') throw new Error(state.message||'Profile installation failed');
  }
  throw new Error('Patch Companion did not finish the profile installation');
 }catch(error){ showToast(error&&error.message?error.message:'Profile installation failed','error'); }
 finally{ if(button){ button.disabled=false; button.textContent=original; } }
}

let meterIccCubeResult=null;

async function meterIccConvertProfileToCube(file,button){
 const original=button?button.textContent:'3D LUT';
 if(button){ button.disabled=true; button.textContent='Converting...'; }
 try{
  // The Pi samples the 65^3 lattice point by point through the profile's
  // BToA tables; allow minutes rather than the default fetch timeout.
  const result=await fetchJSON('/api/icc/to-cube',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({file,size:65}),_timeoutMs:900000});
  if(!result||result.status!=='ok'||!result.file) throw new Error(result&&result.message?result.message:'LUT conversion failed');
  meterIccCubeResult=result;
  // The cube lands in the solved-LUT directory, so a plain refresh registers
  // it in the 3D LUT workspace list alongside solved LUTs.
  if(typeof meterLoadSolvedLutList==='function') meterLoadSolvedLutList();
  meterIccShowCubeModal(file,result);
 }catch(error){ toast(error&&error.message?error.message:'LUT conversion failed',true); }
 finally{ if(button){ button.disabled=false; button.textContent=original; } }
}

function meterIccShowCubeModal(file,result){
 const summary=document.getElementById('meterIccCubeSummary');
 if(summary){
  const size=Number(result.lut_size||0);
  const modeLabel=String(result.signal_mode||'sdr')==='hdr10'?'HDR10':'SDR';
  const methodLabel=String(result.method||'clut')==='clut'?'BToA cLUT':'matrix/TRC';
  summary.textContent='Converted '+file+' ('+modeLabel+', '+methodLabel+') into '
   +(size?size+'×'+size+'×'+size+' ':'')+String(result.file||'')
   +'. The LUT was added to the 3D LUT workspace history on this PGenerator+.';
 }
 const modal=document.getElementById('meterIccCubeModal');
 if(modal){
  if(typeof meterEnsureModalOnBody==='function') meterEnsureModalOnBody(modal);
  modal.style.display='flex';
 }
 uiSyncBodyScrollLock();
}

function meterIccCloseCubeModal(){
 const modal=document.getElementById('meterIccCubeModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

function meterIccCubeDownload(){
 const file=meterIccCubeResult&&meterIccCubeResult.file;
 if(file) window.location.href='/api/3d-lut/cube?file='+encodeURIComponent(file);
}

async function meterIccCubeOpenWorkspace(){
 const file=meterIccCubeResult&&meterIccCubeResult.file;
 meterIccCloseCubeModal();
 if(typeof meterOpenLutTools==='function') meterOpenLutTools();
 if(file&&typeof meterSolvedLutRefreshAndSelect==='function') await meterSolvedLutRefreshAndSelect(file);
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
 set('meterIccValidationMeta',String(result.profile_model_label||'ICC profile')+'; '+String(result.profile_quality||'standard')+' table resolution; '+Number(result.patches||0)+' characterization patches; '+String(result.engine||'ArgyllCMS profcheck'));
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
 const install=document.getElementById('meterIccValidationInstallBtn');
 if(install){
  install.disabled=!file;
  install.style.display=file&&meterIccCompanionConnected&&meterIccVersionAtLeast(meterIccCompanionVersion,'1.4.11')?'':'none';
  install.onclick=()=>{ if(file) meterIccInstallProfile(file,install); };
 }
 const mhc2Panel=document.getElementById('meterIccValidationMhc2');
 const mhc2=result&&result.mhc2&&result.mhc2.status==='passed'?result.mhc2:null;
 if(mhc2Panel){
  mhc2Panel.style.display=mhc2?'':'none';
  if(mhc2){
   const matrixScale=Number(mhc2.matrix_scale);
   const scaleText=Number.isFinite(matrixScale)&&Math.abs(matrixScale-1)>0.0001
    ?(' Matrix headroom scale: '+(matrixScale*100).toFixed(1)+'%.')
    :'';
   mhc2Panel.textContent='MHC2 check passed. Matrix round-trip maximum error: '+Number(mhc2.matrix_round_trip_max_error||0).toFixed(7)+'.'+scaleText+' Curves: '+Number(mhc2.curve_entries||0)+' points, '+String(mhc2.curves||'verified')+'. Metadata white: '+Number(mhc2.metadata_white_luminance_nits||0).toFixed(1)+' cd/m²; measured peak: '+Number(mhc2.peak_luminance_nits||0).toFixed(1)+' cd/m².';
  }else mhc2Panel.textContent='';
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
  retry.textContent='Rebuild with '+profileCount+' Measurements';
  retry.title='Rebuild exactly these saved measurements using the selected algorithm type and table resolution. No larger patch set will be generated or measured.';
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
   // Calibration mode is a build-time choice, not a property of the
   // measurements: reusing a characterization must not silently override
   // the user's current selection with the previous build's mode.
   calibration_mode:meterIccCalibrationModeValue(),
   icc_version:String((document.getElementById('meterIccVersion')||{}).value||(saved&&saved.icc_version)||'auto'),
   cicp:meterIccCicpSettings(),
   pattern_provider:patternProvider,reuse_signature:reuseSignature,
   patch_settings:(saved&&saved.patch_settings)||null,
   target_transfer:(type==='windows-sdr'||type==='sdr')?String((saved&&saved.target_transfer)||meterIccTargetTransferValue()):undefined,
   code_min:0,code_max:info.mode==='sdr'?255:1023,
   meter_name:meterSelectedMeasurementLabel(null)
  };
  const avgDeviation=meterIccAvgDeviationValue();
  if(avgDeviation) meterIccRunConfig.avg_deviation=avgDeviation;
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent='Rebuilding exactly '+readings.length+' saved measurements at '+profileQuality+' table resolution. No '+((METER_ICC_PATCH_PRESETS[family]||{}).medium||{}).patch_count+'-patch set is being generated or measured.';
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
 const determinate=Number(total)>0;
 if(count) count.textContent=determinate?(Math.max(0,Number(current)||0)+' / '+Math.max(0,Number(total)||0)):'Working...';
 if(fill){
  fill.classList.toggle('indeterminate',!determinate);
  fill.style.width=determinate?(Math.max(0,Math.min(100,100*current/total))+'%'):'';
 }
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
 meterIccStartMeasurementClock(steps.length);
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
  if(!await meterIccRefreshCompanionStatus()){ toast('Run PGenerator+ Patch Companion on the target computer first',true); return; }
  // Profile builds always measure the panel itself, so the correction is
  // forced off for the run rather than offered as a choice. 'system' is NOT a
  // no-correction mode: on fullscreen HDR the Companion stands in for the
  // MHC2 stage Windows skips, which characterized the display through the
  // previously active profile's curves.
  meterIccCompanionProfileRestoreMode=meterIccCompanionCorrectionValue();
  meterIccCompanionCorrectionInitialized=true;
  if(!await meterIccPushCompanionDisplaySettings(true,'none')){
   meterIccCompanionProfileRestoreMode='';
   return;
  }
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
   calibration_mode:meterIccCalibrationModeValue(),
   icc_version:String((document.getElementById('meterIccVersion')||{}).value||'auto'),cicp:meterIccCicpSettings(),
   patch_settings:patchSettings,start_token:startToken,reuse_signature:reuseSignature,
   target_transfer:(type==='windows-sdr'||type==='sdr')?meterIccTargetTransferValue():undefined,
   code_min:0,code_max:mode==='sdr'?255:1023,
   meter_name:meterSelectedMeasurementLabel(null)
  };
  const avgDeviation=meterIccAvgDeviationValue();
  if(avgDeviation) baseRunConfig.avg_deviation=avgDeviation;
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
   if(status) status.textContent='Building a temporary display model from '+previousReadings.length+' saved measurements. This CPU-only step may take a minute on Pi 4; measurement begins when it finishes.';
   meterIccSetProgress('Building display model for patch reuse',0,0);
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
    ?('Starting in '+remaining+' seconds. Move and resize PGenerator+ Patch Companion on the target display now.')
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
  await meterIccRestoreCompanionCorrectionAfterProfile();
  // The session is over: hand the desktop back instead of leaving the patch
  // window covering the display until the next run re-applies fullscreen.
  meterIccPushCompanionDisplaySettings(false,undefined,'window');
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
    const timing=meterIccMeasurementRemaining(current,total);
    status.textContent=(reused
     ?('Measuring new patch '+Math.min(current,total)+' of '+total+'. Reused '+reused+' of '+(reused+total)+' final profile patches.')
     :('Measuring patch '+Math.min(current,total)+' of '+total+'.'))+timing;
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
  meterIccMeasurementClock=null;
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
   await meterIccRestoreCompanionCorrectionAfterProfile();
  // The session is over: hand the desktop back instead of leaving the patch
  // window covering the display until the next run re-applies fullscreen.
  meterIccPushCompanionDisplaySettings(false,undefined,'window');
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
  const payload=Object.assign({},meterIccRunConfig,{readings:profileReadings,client_time:Math.floor(Date.now()/1000)});
  delete payload.steps;
  delete payload.reused_readings;
  delete payload.precondition_reused_readings;
  delete payload.reuse_source_readings;
  // Stay beyond the server's four-hour runaway guard. Ultra cLUT fitting on
  // the Pi can legitimately exceed two hours when desktop offload is absent.
  const response=await fetchJSON('/api/icc/build',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),_timeoutMs:15010000});
  if(!response||response.status!=='ok') throw new Error(response&&response.message?response.message:'Profile build failed');
  buildElapsed=meterIccStopBuildClock(buildClock,true);
  if(status){
   const windowsMhc=meterIccRunConfig&&(meterIccRunConfig.profile_type==='windows-sdr'||meterIccRunConfig.profile_type==='windows-hdr');
   const transferText=response.target_transfer?(' Target response curve: '+meterIccTargetTransferInfo(response.target_transfer).label+'.'):'';
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
  await meterIccRestoreCompanionCorrectionAfterProfile();
  // The session is over: hand the desktop back instead of leaving the patch
  // window covering the display until the next run re-applies fullscreen.
  meterIccPushCompanionDisplaySettings(false,undefined,'window');
 }
}

async function meterIccStop(){
 if(meterIccStarting){
  if(meterIccReuseChoiceResolver) meterIccResolveReuseChoice('cancel');
  meterIccStartToken++;
  meterIccStarting=false;
  meterIccMeasurementClock=null;
  meterActionPending=false;
  const status=document.getElementById('meterIccStatus');
  if(status) status.textContent='ICC profiling stopped before measurements began.';
  const stop=document.getElementById('meterIccStopBtn');
  if(stop) stop.style.display='none';
  meterIccSyncUi();
  meterUpdateReadButtons();
  await meterIccRestoreCompanionCorrectionAfterProfile();
  // The session is over: hand the desktop back instead of leaving the patch
  // window covering the display until the next run re-applies fullscreen.
  meterIccPushCompanionDisplaySettings(false,undefined,'window');
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

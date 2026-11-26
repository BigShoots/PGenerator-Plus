var pgAutomation = {
 loaded:false,recipes:[],queues:[],queue:{name:'TV calibration queue',items:[]},selectedQueue:'',loadedQueueSnapshot:'',
 current:null,currentHistoryRunId:'',history:[],liveTimer:null,reportBusy:false,
 supportedKeys:[],supportedValues:{},pinnedKeys:[],supportedSignal:'',supportedPictureMode:'',
 editorTarget:'queue',editingQueueIndex:null,editingRecipe:null,editorEpoch:0,
 editorSettingsKey:'',editorSettingsDrafts:{},fillingEditor:false,gammaFollowsTarget:false,
 editingRunId:'',firstPending:0,editChecked:'',editChecking:'',busy:false,polling:false,tab:'queue',
 jobViews:{},followLive:true,liveSelection:null,logFollow:true,logNotices:[],logObserved:[]
};
const PG_AUTOMATION_SERIES=[['Grey','greyscale-21','Greyscale'],['Colors','colors-30','ColorChecker'],['Sats','saturations-24','Saturation']];
const PG_AUTOMATION_LABELS={deitp:'ΔE ITP',de2000:'ΔE2000',bt1886:'BT.1886 (2.4)','2.2':'Gamma 2.2','2.4':'Gamma 2.4',srgb:'sRGB',st2084:'ST 2084',hlg:'HLG',bt709:'BT.709',p3d65:'DCI-P3 / D65',bt2020:'BT.2020'};
// Fields whose value changes the calibrated result. A job keeps template_id and
// template_mode, so the pristine reference item can be rebuilt and compared
// against it -- no stored copy of the template is needed.
//
// Workflow choices (stages, the pre/post series, the name) and anything derived
// from the meter or link (ccss_override, refresh_rate, panel_light.key) are
// deliberately absent: opting a job into extra sweeps is not "modified" in the
// sense that matters, and a badge that lights up on every customised job is
// noise -- which is the failure this is meant to prevent, not repeat.
const PG_AUTOMATION_DRIFT_FIELDS=[
 // target_luminance is deliberately absent, top level and under calibration.
 // It is an input the runner overwrites with what it measured: a real finished
 // SDR job carries 31.99 against the template's 100. "Copy this run to an
 // editable queue" puts exactly that item back on the queue, so comparing it
 // would badge a job nobody touched. panel_light.fixed_value below is the
 // setting that actually drives it, and it does not move on its own.
 'picture_mode','signal_format','target_gamma','target_gamut','target_delta_e',
 'delta_e_formula','tv_gamma_follows_target','color_format','max_bpc','rgb_quant_range',
 'patch_size','delay_ms','settle_seconds','display_type','observer',
 'target_white.x','target_white.y',
 'panel_light.policy','panel_light.fixed_value',
 'panel_protection.disable',
 'calibration.target_gamma','calibration.target_gamut',
 'calibration.target_delta_e','calibration.delta_e_formula','calibration.method',
 'calibration.profile_source','calibration.lattice_size','calibration.solve_cube_size',
 'calibration.lattice_residuals','calibration.dark_detail','calibration.shadow_fix',
 'calibration.target_white.x','calibration.target_white.y',
];
function pgAutomationDriftAt(object,path){
 return path.split('.').reduce((value,key)=>(value==null?undefined:value[key]),object);
}
// Compare like with like: JSON round trips turn true into 1 and 85 into "85",
// and a job that came back from the Pi has been through that twice. Comparing
// raw values would report every boolean as drift.
function pgAutomationDriftSame(a,b){
 if(a===undefined&&b===undefined)return true;
 if(typeof a==='boolean'||typeof b==='boolean')return (a?1:0)===(b?1:0);
 if(a==null||b==null)return a==null&&b==null;
 // Some TV settings carry a structured value (a legacy blackLevel map is one),
 // not a scalar. String(obj) is "[object Object]" for every object, so a scalar
 // compare would silently call two different maps equal. Recurse over the
 // contents, keeping the loose scalar coercion at the leaves.
 if(typeof a==='object'||typeof b==='object'){
  if(typeof a!=='object'||typeof b!=='object')return false;
  for(const key of new Set([...Object.keys(a),...Object.keys(b)])){
   if(!pgAutomationDriftSame(a[key],b[key]))return false;
  }
  return true;
 }
 return String(a)===String(b);
}
// What a job is measured against, plus how to name that source, or null when
// there is nothing to compare it to. Two kinds of provenance resolve here:
//
//  - source_recipe: the job was added from a saved recipe (see
//    pgAutomationQueueAdd). This is the proximate provenance and wins over any
//    template the recipe itself descends from -- the operator is asking "does
//    this still match the recipe I chose?", not the reference behind it. The
//    recipe is compared as it stands now; one deleted after the job was queued
//    has no reference, so the job is left unbadged. The recipe is snapshotted
//    so it is normalized the same way the queued job already was (an untouched
//    job then matches its recipe exactly, even for a legacy recipe that the
//    snapshot upgrades in place).
//  - template_id: the job was built straight from a reference template, which
//    is rebuilt fresh and compared. Nothing about the template is stored.
function pgAutomationDriftReference(item){
 if(!item)return null;
 if(item.source_recipe){
  const recipe=(pgAutomation.recipes||[]).find(entry=>entry&&entry.id===item.source_recipe);
  if(!recipe)return null;
  return {reference:pgAutomationSnapshot(recipe),noun:'recipe',source:'the “'+(recipe.name||'saved')+'” recipe'};
 }
 if(item.template_mode&&/^reference-settings-v/.test(item.template_id||'')){
  let reference;
  try{
   reference=pgAutomationReferenceItems([item.template_mode],{
    panel_key:item.panel_light&&item.panel_light.key,
    ccss_override:item.ccss_override,refresh_rate:item.refresh_rate,
   })[0];
  }catch(error){return null;}
  if(!reference)return null;
  return {reference,noun:'reference',source:'the '+item.template_mode+' reference settings'};
 }
 return null;
}
// The fields in which a job differs from a resolved reference, or null when
// they are identical. Shared by the template and recipe branches; the field
// list and loose compares below are the whole design of what counts as drift.
function pgAutomationDriftAgainst(item,reference){
 const drift=[];
 for(const path of PG_AUTOMATION_DRIFT_FIELDS){
  const was=pgAutomationDriftAt(reference,path),now=pgAutomationDriftAt(item,path);
  if(!pgAutomationDriftSame(was,now))drift.push({field:path,was,now});
 }
 // The TV settings block is open-ended, so compare the union of both sides
 // rather than a fixed list: a control the job added or dropped is drift too.
 // The panel-light aliases are handled below, not here.
 const refSettings=reference.settings||{},itemSettings=item.settings||{};
 for(const key of new Set([...Object.keys(refSettings),...Object.keys(itemSettings)])){
  if(PG_AUTOMATION_PANEL_ALIASES.includes(key))continue;
  const was=refSettings[key],now=itemSettings[key];
  if(!pgAutomationDriftSame(was,now))drift.push({field:'settings.'+key,was,now});
 }
 // Which of backlight/oledLight/oledPixelBrightness a TV exposes is a
 // compatibility binding, not an edit: pgAutomationRecipeFromForm rewrites the
 // job to the current alias on every save. Comparing the aliases separately
 // would report the old one unset and the new one set for a routine rebind, so
 // compare the level once under one name -- a real brightness change still is.
 const wasLevel=pgAutomationPanelLevel(refSettings),nowLevel=pgAutomationPanelLevel(itemSettings);
 if(!pgAutomationDriftSame(wasLevel,nowLevel))drift.push({field:'settings.panel_light',was:wasLevel,now:nowLevel});
 // Under target policy the requested setup-white luminance drives the whole
 // adjustment loop, so an edit to it is a real change. target_luminance is
 // excluded everywhere else because a fixed-policy job reports its measured
 // native white there (a finished SDR job carries 31.99 against a template's
 // 100), and the runner never repurposes the field that way under target
 // policy -- so compare the requested target only when both sides still ask
 // for one, leaving the fixed-policy exclusion untouched.
 if((item.panel_light&&item.panel_light.policy)==='target'&&(reference.panel_light&&reference.panel_light.policy)==='target'){
  const was=pgAutomationDriftAt(reference,'panel_light.target_luminance'),now=pgAutomationDriftAt(item,'panel_light.target_luminance');
  if(!pgAutomationDriftSame(was,now))drift.push({field:'panel_light.target_luminance',was,now});
 }
 return drift.length?drift:null;
}
// The three panel-light control aliases. Only one is set on a job at a time
// (the editor deletes the rest), so the first present is the panel-light level.
const PG_AUTOMATION_PANEL_ALIASES=['backlight','oledLight','oledPixelBrightness'];
function pgAutomationPanelLevel(settings){
 for(const key of PG_AUTOMATION_PANEL_ALIASES){if(settings&&settings[key]!=null)return settings[key];}
 return undefined;
}
// The differences between a queued job and the reference it was built from --
// a saved recipe or a template -- or null when there are none and for a job
// with no provenance to compare against. Returns every differing field so the
// operator can judge intent -- naming them is the point; guessing which were
// deliberate is not.
function pgAutomationTemplateDrift(item){
 const resolved=pgAutomationDriftReference(item);
 return resolved?pgAutomationDriftAgainst(item,resolved.reference):null;
}
function pgAutomationDriftText(drift){
 // Format each side through pgAutomationSettingValue so a structured value
 // reads as its JSON, not "[object Object]"; undefined stays "unset".
 const show=value=>value===undefined?'unset':pgAutomationSettingValue(value);
 return drift.map(d=>d.field+': '+show(d.was)+' → '+show(d.now)).join('\n');
}
// A job named after its recipe or template but carrying different values is
// invisible otherwise: the row shows only the name. Name the count on the row
// and the fields on hover, so a job that is not what it says it is can be
// spotted before it calibrates rather than afterwards in the run record. The
// row reads "Differs from recipe/reference": one stem that is accurate whether
// the job was edited or the reference it points at moved underneath it.
function pgAutomationDriftBadge(item){
 const resolved=pgAutomationDriftReference(item);
 if(!resolved)return '';
 const drift=pgAutomationDriftAgainst(item,resolved.reference);
 if(!drift)return '';
 return '<span class="auto-pill auto-drift" title="Differs from '+pgAutomationEscape(resolved.source)
  +':\n'+pgAutomationEscape(pgAutomationDriftText(drift))+'">Differs from '+pgAutomationEscape(resolved.noun)+' · '
  +drift.length+' field'+(drift.length===1?'':'s')+'</span>';
}
const PG_AUTOMATION_REFERENCE_MODES=[
 {id:'dv-filmmaker',signal:'dv',mode:'dolbyVisionFilmMaker',name:'Dolby Vision Filmmaker'},
 {id:'dv-cinema',signal:'dv',mode:'dolbyVisionCinemaBright',name:'Dolby Vision Cinema Home'},
 {id:'hdr-filmmaker',signal:'hdr10',mode:'hdrFilmMaker',name:'HDR10 Filmmaker'},
 {id:'hdr-cinema',signal:'hdr10',mode:'hdrCinema',name:'HDR10 Cinema'},
 {id:'sdr-filmmaker',signal:'sdr',mode:'filmMaker',name:'SDR Filmmaker'},
 {id:'sdr-cinema',signal:'sdr',mode:'cinema',name:'SDR Cinema'}
];
// Adapt the reference table's P1 (TV) and P6 (PGenerator+) columns, not its G1
// columns, which describe external calibration software.
// Build fresh objects for each insertion: editing a queued copy never edits the template.
function pgAutomationReferenceItems(ids,context){
 const selected=new Set(ids),meter=context||{};
 const panelKey=['backlight','oledLight','oledPixelBrightness'].includes(meter.panel_key)?meter.panel_key:'backlight';
 return PG_AUTOMATION_REFERENCE_MODES.filter(mode=>selected.has(mode.id)).map(mode=>{
  const sdr=mode.signal==='sdr',hdr=mode.signal==='hdr10',dv=mode.signal==='dv';
  const gamma=sdr?(mode.id==='sdr-cinema'?'2.2':'bt1886'):'st2084',gamut=sdr?'bt709':'p3d65';
  const brightness=mode.id==='sdr-filmmaker'?95:100,range=dv?'2':'1';
  const settings={brightness:50,contrast:sdr?85:100,blackLevel:'auto',sharpness:0,color:50,tint:0,
   peakBrightness:sdr?'off':'high',dynamicContrast:'off',dynamicColor:'off',superResolution:'off',noiseReduction:'off',
   mpegNoiseReduction:'off',smoothGradation:'off',realCinema:'off',energySaving:'off',
   [panelKey]:brightness};
  // DV gamut/DTM belong to its decoder; do not pin generic HDR10 controls there.
  if(!dv)settings.colorGamut='auto';
  if(sdr)settings.gamma=pgAutomationTvGamma(gamma);
  if(hdr)settings.hdrDynamicToneMapping='off';
  return {
   name:mode.name,signal_format:mode.signal,picture_mode:mode.mode,tv_gamma_follows_target:sdr,
   template_id:'reference-settings-v5',template_mode:mode.id,
   manual_checks:['TruMotion: verify Off in the TV menu; this control is not available through the API.'],
   template_notes:'LG OLED starting settings. Check supported controls for this TV and mode. '+
    (sdr?'Fixed panel brightness; actual white is measured, not a promised 100-nit result. ':hdr?'Check Dynamic Tone Mapping is Off after reset. ':'DV gamut and tone mapping are decoder-managed. ')+
    'Check TruMotion, AI Brightness, Motion Eye Care, Expression Enhancer and ambient-light processing are Off where available; Near Black Detail 0. Real Cinema is Off for measurement; use On for 24p viewing afterwards. '+
    'Set generator resolution to 1080p24 and Pattern Delay to 0.75 s in Display Settings. Check HDR/DV metadata: maximum 1000, minimum 0.005, MaxCLL 1000, MaxFALL 400; DV transport Standard. These global settings are not applied by the queue.',
   // Keep calibration's own measurement/results, without three extra sweeps
   // on either side. Users may opt into those stages on a saved/custom copy.
   settings,stages:{pre_readings:false,calibration:true,post_readings:false,apply_all:true},
   // Calibration mode suspends TPC/GSR itself; switching it off is opt-in.
   panel_protection:{disable:false},
   pre_series:PG_AUTOMATION_SERIES.map(x=>x[1]),post_series:PG_AUTOMATION_SERIES.map(x=>x[1]),
   target_gamma:gamma,target_gamut:gamut,target_white:{x:.3127,y:.3290},target_luminance:100,
   target_delta_e:.5,delta_e_formula:'deitp',
   panel_light:{policy:'fixed',key:panelKey,fixed_value:brightness,target_luminance:100},
   calibration:{target_gamma:gamma,target_gamut:gamut,target_white:{x:.3127,y:.3290},target_luminance:100,
    target_delta_e:.5,delta_e_formula:'deitp',method:sdr?'hybrid':'matrix',profile_source:sdr?'hybrid3':'matrix',
    lattice_size:3,solve_cube_size:33,lattice_residuals:sdr,dark_detail:true,shadow_fix:hdr},
   // Keep acceptance disabled: the source does not specify HDR/DV maximum-patch limits.
   quality:{enabled:false,dE_formula:'deitp',limits:sdr?{'greyscale-21':{avg:2,max:3},'colors-30':{avg:2,max:3},'saturations-24':{avg:2,max:3}}:{}},
   display_type:'oled_generic',ccss_override:meter.ccss_override||'',observer:'1931_2',
   delay_ms:1000,patch_size:10,settle_seconds:8,refresh_rate:meter.refresh_rate||'',
   low_light:{enabled:true,mode:'a',trigger:1},
   // 19 Sep 2026: SDR used to skip the per-patch grey field and insert the
   // 25% field only every 45 s, so an SDR colour profile read 63 saturated
   // patches back to back with a 1.8 s settle. The owner wants SDR treated
   // like HDR and DV on the OLED; pgAutomationUpgradeInsertion lifts saved
   // jobs that still carry the old SDR values.
   patch_insert:true,patch_insert_time_enabled:true,patch_insert_time_frequency_ms:5000,
   patch_insert_time_duration_ms:5000,patch_insert_time_level:25,patch_insert_patch_enabled:true,
   patch_insert_patch_every:1,patch_insert_patch_duration_ms:1000,patch_insert_patch_level:10,
   display_use_case:'keep',color_format:dv?'0':'1',max_bpc:dv?8:10,colorimetry:sdr?'2':'9',
   ...(hdr?{primaries:'2',eotf:'2'}:{}),
   signal_range:range,pattern_signal_range:range,transport_signal_range:range,rgb_quant_range:range
  };
 });
}
function pgAutomationReferenceQueue(){
 const context={};
 // The panel-light aliases vary by TV. Prefer an already reported working control.
 if(typeof lgDisplayControlValues!=='undefined'){
  context.panel_key=['backlight','oledLight','oledPixelBrightness'].find(key=>lgDisplayControlValues[key]!=null);
 }
 if(typeof getCcssOverride==='function')context.ccss_override=getCcssOverride();
 if(typeof getMeterRefreshRate==='function')context.refresh_rate=getMeterRefreshRate();
 return {name:'Reference settings',items:pgAutomationReferenceItems(PG_AUTOMATION_REFERENCE_MODES.map(mode=>mode.id),context)};
}
function pgAutomationQueueName(name){return name==='ColoursTrue LG OLED plan'?'Reference settings':name;}
function pgAutomationLabel(value){const key=String(value==null?'':value);return PG_AUTOMATION_LABELS[key]||key;}
function pgAutomationSeriesLabel(key){const found=PG_AUTOMATION_SERIES.find(x=>x[1]===key);return found?found[2]:key;}
function pgAutomationFormatTime(iso){if(!iso)return '';const date=new Date(iso);return Number.isNaN(date.getTime())?String(iso):date.toLocaleString();}
function pgAutomationStateBadge(status){
 const badge=pgAutomationEl('State');if(!badge)return;
 badge.textContent=status.replace(/-/g,' ').replace(/^./,ch=>ch.toUpperCase());
 badge.style.color=status==='complete'?'var(--green)':['starting','checking','running','stopping','completing'].includes(status)?'var(--accent)':['paused','interrupted','complete-with-warnings'].includes(status)?'var(--orange)':['failed','blocked'].includes(status)?'var(--red)':'var(--text2)';
}
function pgAutomationEscape(value){return String(value==null?'':value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));}
function pgAutomationClone(value){return value==null?value:JSON.parse(JSON.stringify(value));}
function pgAutomationEl(id){return document.getElementById('pgAutomation'+id);}
// <dialog> is missing on older engines (Safari before 15.4). Fall back to the
// open attribute so the editor still renders as a block instead of throwing.
function pgAutomationOpenDialog(el){if(!el)return;if(typeof el.showModal==='function'){if(!el.open)el.showModal();}else{el.setAttribute('open','');el.open=true;}}
function pgAutomationCloseDialog(el){if(!el)return;if(typeof el.close==='function'&&el.open)el.close();else{el.removeAttribute('open');el.open=false;}}
// In-app confirmation. window.confirm() blocks the page and every browser
// automation driving it; this dialog does not. Tests set
// window.pgAutomationConfirmOverride to answer without a dialog.
function pgAutomationConfirm(message,confirmLabel){
 const hook=globalThis.pgAutomationConfirmOverride;
 if(typeof hook==='function')return Promise.resolve(!!hook(message));
 return new Promise(resolve=>{
  let dialog=document.getElementById('pgAutomationConfirmDialog');
  if(!dialog){
   dialog=document.createElement('dialog');dialog.id='pgAutomationConfirmDialog';dialog.setAttribute('aria-labelledby','pgAutomationConfirmText');
   dialog.innerHTML='<form method="dialog"><p id="pgAutomationConfirmText"></p><p id="pgAutomationConfirmNotice" role="status"></p><div class="auto-actions"><button class="btn btn-sm btn-secondary" type="submit" value="cancel">Cancel</button><button class="btn btn-sm btn-primary" type="submit" value="ok" id="pgAutomationConfirmOk">Continue</button></div></form>';
   (document.getElementById('pgAutomationQueueDialog')?.parentNode||document.body).appendChild(dialog);
  }
  // One question at a time: a second request while one is open is declined
  // rather than replacing the question the user is reading.
  if(typeof dialog.showModal!=='function'){resolve(false);return;}
  if(dialog.open){
   // The page behind a modal is inert; keep this feedback inside the question.
   dialog.querySelector('#pgAutomationConfirmNotice').textContent='Another action is waiting for your answer. Answer this question, then retry the action you just requested.';
   resolve(false);return;
  }
  dialog.querySelector('#pgAutomationConfirmNotice').textContent='';
  dialog.querySelector('#pgAutomationConfirmText').textContent=message;
  dialog.querySelector('#pgAutomationConfirmOk').textContent=confirmLabel||'Continue';
  // Only the original request owns the close listener and receives this answer.
  const done=()=>{dialog.removeEventListener('close',done);resolve(dialog.returnValue==='ok');};
  dialog.returnValue='';dialog.addEventListener('close',done);
  dialog.showModal();dialog.querySelector('#pgAutomationConfirmOk').focus();
 });
}
function pgAutomationValue(id,fallback){const el=pgAutomationEl(id);return el&&el.value!==''?el.value:fallback;}
function pgAutomationChecked(id){return !!(pgAutomationEl(id)&&pgAutomationEl(id).checked);}
function pgAutomationStageEnabled(stages,key){
 return stages?.[key]==null?!['pre_readings','post_readings'].includes(key):!!stages[key];
}
function pgAutomationNotice(message,error){
 const level=error==='warning'?'warning':error?'error':'info';error=level==='error';
 if(message){pgAutomation.logNotices.push({time:Date.now()/1000,level,message,source:'Browser'});pgAutomation.logNotices=pgAutomation.logNotices.slice(-100);pgAutomationRenderActivity();}
 // Info notices describe a moment ("Automation resumed"); the live render
 // clears them once the run has since parked or finished.
 pgAutomation.noticeLevel=message?level:'';pgAutomation.noticeRunStatus=null;pgAutomation.noticeAt=Date.now();
 const el=pgAutomationEl('Notice');if(!el)return;
 el.textContent=message||'';el.style.display=message?'block':'none';el.style.color=error?'var(--red)':level==='warning'?'var(--orange)':'var(--text2)';
 el.setAttribute('role',error?'alert':'status');
 if(error){pgAutomation.lastProblem=message;pgAutomationRenderProgress();}
 if(pgAutomationEl('Editor').open)pgAutomationEl('EditorError').textContent=error?(message||''):'';
}
async function pgAutomationRequest(path,body,timeout){
 const opts={_quiet:true,_timeoutMs:timeout||30000};
 if(body!==undefined){opts.method='POST';opts.headers={'Content-Type':'application/json'};opts.body=JSON.stringify(body);}
 const result=await fetchJSON('/api/automation/'+path,opts);
 if(!result)throw new Error('The generator did not respond. Refresh to check its state before retrying.');
 if(result.status==='error')throw new Error(result.message||'Automation request failed');
 return result;
}
function pgAutomationSnapshot(source){
 const item=pgAutomationClone(source)||{};
 delete item.warmup_minutes;
 delete item.settings_recovery;
 ['readiness','setting_contracts','generation_profile','capability_profile','preflight_contract','best_available_settings','best_available_write_ack','tv_input','worker_status','started_at','completed_at'].forEach(key=>delete item[key]);
 pgAutomationUpgradeReference(item);
 pgAutomationUpgradeInsertion(item);
 ['item_number','status','checkpoints','checkpoint','checkpoint_status','active_stage','stage_started_at','failure','warnings','recheck','hazards','hazard_capabilities','hazard_restore','device_identity','fault_injected','drift_recovery_attempts','drift_recovery_pending','series','apply-all','panel-light'].forEach(key=>delete item[key]);
 // Run evidence merged into history items (webui_automation_item_artifacts);
 // the server strips it again on save, but it must not sit in the draft either.
 if(item.calibration&&typeof item.calibration==='object'){['reset','grey-state','3d-state','dv-profile-state','dv-profile-measurements','dv-profile-upload'].forEach(key=>delete item.calibration[key]);}
 return item;
}
// An SDR job carrying exactly the old SDR defaults (no per-patch grey field,
// 25% field every 45 s) is lifted to the HDR/DV insertion. A job whose
// insertion was set by hand to anything else is left alone.
function pgAutomationUpgradeInsertion(item){
 if((item.signal_format||'')!=='sdr')return;
 if(item.patch_insert_patch_enabled!==false||Number(item.patch_insert_time_frequency_ms)!==45000)return;
 item.patch_insert_patch_enabled=true;
 item.patch_insert_time_frequency_ms=5000;
}
function pgAutomationUpgradeReference(item){
 if(!/^(reference-settings-v[123]|colourstrue-six-modes-v1)$/.test(item.template_id||''))return;
 item.settings=item.settings||{};
 if(item.settings.truMotionMode==='off')delete item.settings.truMotionMode;
 if(item.signal_format==='hdr10'&&!Object.prototype.hasOwnProperty.call(item.settings,'hdrDynamicToneMapping'))item.settings.hdrDynamicToneMapping='off';
 item.manual_checks=['TruMotion: verify Off in the TV menu; this control is not available through the API.'];item.template_id='reference-settings-v3';
}
function pgAutomationSaveDraft(){
 const draft=JSON.stringify({queue:pgAutomation.queue,editingRunId:pgAutomation.editingRunId,firstPending:pgAutomation.firstPending,selectedQueue:pgAutomation.selectedQueue,loadedQueueSnapshot:pgAutomation.loadedQueueSnapshot});
 try{localStorage.setItem('pgen.automation.queueDraft',draft);}
 catch(e){
  // A full storage quota is usually cached series data, which is disposable;
  // the queue draft is not. Free series space and try once more.
  let saved=false;
  if(typeof meterSeriesCacheReclaimSpace==='function'&&meterSeriesCacheReclaimSpace()){try{localStorage.setItem('pgen.automation.queueDraft',draft);saved=true;}catch(retry){}}
  if(!saved)pgAutomationNotice('Browser draft storage is unavailable. Use Save queue to keep edits on the Pi before refreshing.', 'warning');
 }
 const ready=pgAutomationEl('Readiness');if(ready)ready.innerHTML='';
}
function pgAutomationModes(signal){
 if(typeof lgPictureModesForSignal==='function')return lgPictureModesForSignal(signal).map(mode=>typeof mode==='string'?mode:Array.isArray(mode)?mode[0]:(mode.value||mode.id));
 return signal==='dv'?['dolbyVisionCinemaBright','dolbyVisionFilmMaker']:signal==='sdr'?['cinema','filmMaker','expert1','expert2']:['hdrCinema','hdrFilmMaker'];
}
function pgAutomationModeLabel(mode,signal){
 if(typeof lgPictureModesForSignal==='function'){
  const found=lgPictureModesForSignal(signal).find(x=>x[0]===mode||x.value===mode||x.id===mode);
  if(found)return found.label||found[1]||mode;
 }
 return mode||'Choose a picture mode';
}
function pgAutomationModesChanged(){
 const signal=pgAutomationValue('Signal','sdr'),select=pgAutomationEl('PictureMode'),prior=select.value;
 const modes=pgAutomationModes(signal).filter(Boolean);
 select.innerHTML=modes.map(mode=>'<option value="'+pgAutomationEscape(mode)+'">'+pgAutomationEscape(pgAutomationModeLabel(mode,signal))+'</option>').join('');
 if(modes.includes(prior))select.value=prior;
 else select.value=modes.find(mode=>/filmmaker/i.test(mode))||modes[0]||'';
 pgAutomationModeChanged();
}
function pgAutomationModeChanged(){
 if(pgAutomation.fillingEditor)return;
 const key=pgAutomationValue('Signal','sdr')+':'+pgAutomationValue('PictureMode','');
 if(key===pgAutomation.editorSettingsKey)return;
 if(pgAutomation.editorSettingsKey){
  const [oldSignal,oldMode]=pgAutomation.editorSettingsKey.split(':');
  if(pgAutomationValue('RecipeName','')===pgAutomationModeLabel(oldMode,oldSignal))pgAutomationEl('RecipeName').value=pgAutomationModeLabel(pgAutomationValue('PictureMode',''),pgAutomationValue('Signal','sdr'));
  try{Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());}catch(e){}
  pgAutomation.editorSettingsDrafts[pgAutomation.editorSettingsKey]={values:pgAutomationClone(pgAutomation.supportedValues),pins:[...pgAutomation.pinnedKeys],gamma:pgAutomationValue('Gamma','bt1886'),gammaFollowsTarget:pgAutomation.gammaFollowsTarget,
   manualSettings:pgAutomationClone(pgAutomation.manualSettings||{}),panel:{key:pgAutomationValue('PanelKey',''),policy:pgAutomationValue('PanelPolicy','fixed'),fixed_value:pgAutomationValue('PanelValue',100),target_luminance:pgAutomationValue('PanelTarget',100)}};
 }
 pgAutomation.editorEpoch++;pgAutomation.editorSettingsKey=key;
 const draft=pgAutomation.editorSettingsDrafts[key];
 pgAutomationApplyPictureDefaults(draft);
}
// Same settings factory as the reference queue; never copy a live TV's values
// implicitly or mutate saved jobs simply by opening their editor.
function pgAutomationPictureDefaults(signal,mode,panelKey){
 const canonical=value=>String(value||'').replace(/[\s_-]/g,'').toLowerCase();
 const modes=PG_AUTOMATION_REFERENCE_MODES.filter(x=>x.signal===signal);
 const match=modes.find(x=>canonical(x.mode)===canonical(mode))||modes.find(x=>/filmmaker/.test(x.id));
 if(!match)return {settings:{},panel_light:{key:panelKey||'backlight',policy:'fixed',fixed_value:100,target_luminance:100}};
 return pgAutomationReferenceItems([match.id],{panel_key:panelKey})[0];
}
function pgAutomationApplyPictureDefaults(draft,reference){
 const defaults=pgAutomationPictureDefaults(pgAutomationValue('Signal','sdr'),pgAutomationValue('PictureMode',''),pgAutomationValue('PanelKey','backlight'));
 const panel=draft?.panel||defaults.panel_light;
 pgAutomation.supportedKeys=[];pgAutomation.supportedSignal='';pgAutomation.supportedPictureMode='';
 pgAutomation.supportedValues=pgAutomationClone(draft?.values||defaults.settings);
 pgAutomation.pinnedKeys=draft?[...draft.pins]:Object.keys(defaults.settings);
 pgAutomationEl('Gamma').value=draft?.gamma||defaults.target_gamma||'hlg';
 pgAutomation.gammaFollowsTarget=draft?!!draft.gammaFollowsTarget:!!defaults.tv_gamma_follows_target;
 pgAutomation.settingsPlan=null;pgAutomation.manualSettings=pgAutomationClone(draft?.manualSettings||{});
 pgAutomationEl('PanelKey').value=panel.key;
 pgAutomationRenderSettingsEditor();
 pgAutomationEl('PanelKey').value=panel.key;
 pgAutomationEl('PanelPolicy').value=panel.policy;
 pgAutomationEl('PanelValue').value=panel.fixed_value;
 pgAutomationEl('PanelTarget').value=panel.target_luminance;
 pgAutomationUpdateEditor();
 pgAutomationResolveSettingsPlan();
}
function pgAutomationResetPictureDefaults(){
 pgAutomation.editorEpoch++;
 pgAutomationApplyPictureDefaults(null,true);
}
function pgAutomationSignalDefaults(){
 const signal=pgAutomationValue('Signal','sdr');
 if(signal!=='sdr')pgAutomationEl('Gamma').value=signal==='hlg'?'hlg':'st2084';
 pgAutomationEl('Gamut').value=signal==='sdr'?'bt709':'p3d65';
 if(signal!=='sdr')pgAutomationEl('PanelPolicy').value='fixed';
 pgAutomationEl('Method').value=signal==='hdr10'?'matrix':'hybrid3';
 if(signal==='dv'){
  pgAutomationEl('UseCase').value='keep';pgAutomationEl('ColorFormat').value='0';pgAutomationEl('Range').value='2';pgAutomationEl('BitDepth').value='8';
 }else{
  if(pgAutomationValue('UseCase','keep')==='keep'){
   pgAutomationEl('ColorFormat').value='1';pgAutomationEl('Range').value='1';pgAutomationEl('BitDepth').value='10';
  }
  pgAutomationUseCaseChanged(true);
 }
 if(signal==='hlg')pgAutomationEl('Cal').checked=false;
 pgAutomationDisplayTypeChanged();
 pgAutomationUpdateEditor();
}
function pgAutomationUseCaseChanged(outputOnly){
 const choice=pgAutomationValue('UseCase','keep'),signal=pgAutomationValue('Signal','sdr');
 const mapping=typeof METER_AUTOCAL_USECASE_OUTPUT!=='undefined'?METER_AUTOCAL_USECASE_OUTPUT:{pc:{color_format:'0',rgb_quant_range:'2',max_bpc:'10'},tv:{color_format:'1',rgb_quant_range:'1',max_bpc:'10'},console:{color_format:'0',rgb_quant_range:'2',max_bpc:'10'}};
 const config=mapping[choice];
 if(config&&signal!=='dv'){
  pgAutomationEl('ColorFormat').value=config.color_format;pgAutomationEl('Range').value=config.rgb_quant_range;pgAutomationEl('BitDepth').value=config.max_bpc;
  if(signal==='sdr'&&!outputOnly){pgAutomationEl('Gamma').value=choice==='tv'?'bt1886':'2.2';pgAutomationGammaChanged();}
 }
}
// LG's picture API uses enum tokens, not the labels shown in the TV menu.
function pgAutomationTvGamma(target){return {'1.9':'low','2.2':'medium','2.4':'high1',bt1886:'high2','BT.1886':'high2'}[target]||'';}
function pgAutomationGammaChanged(){
 if(pgAutomationValue('Signal','sdr')==='sdr'&&pgAutomation.gammaFollowsTarget){
  const value=pgAutomationTvGamma(pgAutomationValue('Gamma','bt1886'));
  const input=document.querySelector('[data-pg-automation-key="gamma"]'),pin=document.querySelector('[data-pg-automation-pin="gamma"]');
  pgAutomation.pinnedKeys=pgAutomation.pinnedKeys.filter(key=>key!=='gamma');
  const unavailable=pgAutomation.settingsPlan?.manual?.gamma||pgAutomation.settingsPlan?.blocked?.gamma;
  if(value){pgAutomation.supportedValues.gamma=value;if(!unavailable)pgAutomation.pinnedKeys.push('gamma');if(input)input.value=value;}
  if(pgAutomation.manualSettings?.gamma){if(value)pgAutomation.manualSettings.gamma.value=value;else delete pgAutomation.manualSettings.gamma;pgAutomationRenderManualSettings();}
  if(input)input.disabled=!value||!!unavailable;
  if(pin)pin.checked=!!value&&!unavailable;
  pgAutomationUpdateSettingsStatus();
 }
 pgAutomationUpdateEditor();
}
function pgAutomationSettingChanged(key){
 if(key==='gamma'){pgAutomation.gammaFollowsTarget=false;pgAutomationUpdateEditor();}
}
function pgAutomationPopulateMeterChoices(dtype,ccss){
 const copy=(id,sourceId,value,fallback)=>{
  const select=pgAutomationEl(id),source=document.getElementById(sourceId);
  select.innerHTML=source?source.innerHTML:fallback;
  select.querySelectorAll('option[value="custom_editor"]').forEach(x=>x.remove());
  if(!Array.from(select.options).some(x=>x.value===value))select.add(new Option(value||'Auto (technology default)',value));
  select.value=value;
 };
 copy('DisplayType','meterDisplayType',dtype||'lcd','<option value="lcd">LCD</option><option value="oled_generic">WOLED</option>');
 copy('Ccss','meterCcssProfile',ccss||'','<option value="">Auto (technology default)</option><option value="none">No correction</option>');
 pgAutomationDisplayHelp();
}
function pgAutomationDisplayHelp(){
 const dtype=pgAutomationEl('DisplayType'),oled=/oled|wrgb/i.test(dtype.value+' '+(dtype.selectedOptions[0]?.textContent||'')),hdr=pgAutomationValue('Signal','sdr')!=='sdr';
 pgAutomationEl('DisplayHelp').textContent=oled?'OLED: 10% window. Changing panel technology applies wizard conditioning: '+(hdr?'5 s':'45 s')+' interval, 5 s at 25%'+(hdr?', plus a 1 s / 10% insertion every patch.':'.'):'LCD / QNED: 10% window on black (10% APL), with pattern insertion off. Meter profile is captured for this item only.';
}
function pgAutomationDisplayTypeChanged(){
 const dtype=pgAutomationEl('DisplayType'),oled=/oled|wrgb/i.test(dtype.value+' '+(dtype.selectedOptions[0]?.textContent||'')),hdr=pgAutomationValue('Signal','sdr')!=='sdr';
 pgAutomationEl('PatchSize').value=10;
 Object.assign(pgAutomation.editingRecipe,{
  patch_insert:oled,patch_insert_time_enabled:oled,patch_insert_time_frequency_ms:hdr?5000:45000,
  patch_insert_time_duration_ms:5000,patch_insert_time_level:25,patch_insert_patch_enabled:oled&&hdr,
  patch_insert_patch_every:1,patch_insert_patch_duration_ms:1000,patch_insert_patch_level:10
 });
 pgAutomationDisplayHelp();
}
function pgAutomationSetPanelPolicy(policy){pgAutomationEl('PanelPolicy').value=policy;pgAutomationUpdateEditor();}
function pgAutomationModeEligibility(){
 const candidate=pgAutomation.settingsPlan?.calibration_mode;
 const contract=candidate&&candidate.signal_mode===pgAutomationValue('Signal','sdr')?candidate:null;
 const blocked=!!contract&&!contract.allowed&&pgAutomationChecked('Cal');
 const select=pgAutomationEl('PictureMode');
 const token=value=>String(value||'').replace(/[\s_-]/g,'').toLowerCase();
 const allowed=new Set((contract?.allowed_modes||[]).map(token));
 // Preserve a saved unknown token rather than silently selecting a preset.
 if(Array.isArray(contract?.catalogue)){
  const selected=select.value;
  const rows=contract.catalogue.filter(row=>row.offered||[row.value,row.settings_value,...(row.aliases||[])].some(value=>token(value)===token(selected)));
  const options=rows.map(row=>{
   const value=[row.value,row.settings_value,...(row.aliases||[])].some(value=>token(value)===token(selected))?selected:row.value;
   const option=new Option(row.label,value);option.dataset.modeLabel=row.label;return option;
  });
  if(selected&&!options.some(option=>option.value===selected))options.unshift(new Option(selected,selected));
  while(select.firstChild)select.removeChild(select.firstChild);options.forEach(option=>select.appendChild(option));select.value=selected;
 }
 Array.from(select.options).forEach(option=>{
  option.dataset.modeLabel=option.dataset.modeLabel||option.textContent;
  const readingsOnly=!!contract&&!allowed.has(token(option.value));
  option.disabled=readingsOnly&&pgAutomationChecked('Cal');
  option.textContent=option.dataset.modeLabel+(readingsOnly?' — readings only':'');
 });
 const message=blocked?pgAutomationModeLabel(select.value,pgAutomationValue('Signal','sdr'))+': '+contract.message
  :contract&&!contract.allowed?'This mode is available for readings, not AutoCal.':contract?.message||'';
 pgAutomationEl('ModeEligibility').textContent=message;
 select.setAttribute('aria-invalid',blocked?'true':'false');
 // A pending check no longer blocks Save: job readiness re-checks every
 // control against the TV, so the wait (30-50 s on a busy appliance) only
 // guided the choice. A failed check still needs attention before saving.
 pgAutomationEl('EditorSave').disabled=!!pgAutomation.editorSaving||!!pgAutomation.planError||blocked;
 pgAutomationEl('EditorSave').title=blocked?message:'';
 let footer=pgAutomationEl('ModeSaveHelp');
 if(!footer){footer=document.createElement('p');footer.id='pgAutomationModeSaveHelp';footer.className='auto-muted';footer.style.cssText='flex-basis:100%;margin:0';pgAutomationEl('EditorSave').parentElement.prepend(footer);}
 footer.textContent=pgAutomation.planPending?'Checking TV compatibility. You can keep editing or save now; unsupported controls are flagged when the queue is checked.'
  :pgAutomation.planError?'TV compatibility check failed. Review the error above and retry before saving.'
  :blocked?message:'';
 footer.hidden=!footer.textContent;
 pgAutomationEl('EditorSave').setAttribute('aria-describedby','pgAutomationModeSaveHelp');
 pgAutomationRenderCompatibilityStatus(blocked?message:'');
 return blocked?message:'';
}
function pgAutomationRenderCompatibilityStatus(modeBlockMessage){
 const panel=pgAutomationEl('Compatibility');if(!panel)return;
 const plan=pgAutomation.settingsPlan;
 let state='required',label='Check required',detail='Required before saving. Connect your TV, then check which controls this job can use.',action='Check TV compatibility';
 if(pgAutomation.planPending){
  state='checking';label='Checking…';action='Checking compatibility…';
  detail='Reading the connected TV and matching its controls to this job. Keep the TV connected; you can keep editing or save now, and Check Readiness flags any control the TV rejects.';
 }else if(pgAutomation.planError){
  state='error';label='Check failed — action needed';action='Retry compatibility check';
  detail=pgAutomation.planError+' Keep your TV connected, then retry. This check must complete before you can save.';
 }else if(plan){
  const limited=!plan.known||Object.keys(plan.manual||{}).length>0||Object.keys(plan.blocked||{}).length>0;
  state=modeBlockMessage?'error':limited?'limited':'checked';
  label=modeBlockMessage?'Action needed':limited?'Checked — review limits':'Checked';action='Refresh TV compatibility';
  const context=(plan.model_name||'Connected TV')+' · '+pgAutomationValue('Signal','sdr').toUpperCase()+' · '+pgAutomationModeLabel(pgAutomationValue('PictureMode',''),pgAutomationValue('Signal','sdr'))+'. ';
  detail=context+(modeBlockMessage?modeBlockMessage
   :!plan.known?'No reviewed TV profile matched. Only conservative controls are available; review the limitations under TV Settings.'
   :limited?'Compatibility checked. Review manual steps and unavailable controls under TV Settings.'
   :plan.live_context_matches?'Compatibility checked in the current TV mode. Settings will be verified again when the job runs.'
   :'Settings selected from the TV matrix. Live checks will run after the job selects its signal and picture mode.');
 }
 panel.dataset.state=state;
 // Do not re-announce unchanged status on every unrelated form edit.
 const setText=(id,value)=>{const el=pgAutomationEl(id);if(el.textContent!==value)el.textContent=value;};
 setText('CompatibilityState',label);setText('CompatibilityDetail',detail);setText('CompatibilityButton',action);
 pgAutomationEl('CompatibilityButton').disabled=!!pgAutomation.planPending;
}
function pgAutomationSelectSettings(all){
 document.querySelectorAll('[data-pg-automation-pin]').forEach(el=>{
  const key=el.getAttribute('data-pg-automation-pin');
  if(el.disabled||all&&pgAutomation.supportedValues[key]==null)return;
  el.checked=all;pgAutomationTogglePin(el);
 });
}
function pgAutomationSettingMetadata(key){
 if(key==='gamma')return {key,label:'TV Gamma (setup)',type:'select',options:['low','medium','high1','high2'],labels:{low:'Gamma 1.9',medium:'Gamma 2.2',high1:'Gamma 2.4',high2:'BT.1886'}};
 if(typeof LG_DISPLAY_CONTROL_ITEMS!=='undefined')return LG_DISPLAY_CONTROL_ITEMS.find(item=>item.key===key)||{key,label:key,type:'text'};
 return {key,label:key,type:'text'};
}
function pgAutomationSettingCandidates(){
 const keys=typeof LG_DISPLAY_CONTROL_KEYS!=='undefined'?LG_DISPLAY_CONTROL_KEYS.slice():['brightness','contrast','backlight','oledLight','oledPixelBrightness','energySaving'];
 const signal=pgAutomationValue('Signal','sdr');
 return keys.filter(key=>!(key==='hdrDynamicToneMapping'&&signal!=='hdr10')&&!(key==='colorGamut'&&signal==='dv')&&!(key==='gamma'&&signal!=='sdr'));
}
function pgAutomationSettingValue(value){return value==null?'':typeof value==='object'?JSON.stringify(value):String(value);}
function pgAutomationRenderSettingsEditor(){
 const editor=pgAutomationEl('SettingsEditor');
 const pinned=pgAutomation.pinnedKeys||[];
 const checked=pgAutomation.supportedKeys.length>0;
 const keys=Array.from(new Set([...(checked?pgAutomation.supportedKeys:pgAutomationSettingCandidates()),...pinned]));
  editor.innerHTML=keys.filter(key=>!['backlight','oledLight','oledPixelBrightness'].includes(key)).map(key=>{
   const unavailable=pgAutomation.settingsPlan?.manual?.[key]||pgAutomation.settingsPlan?.blocked?.[key];
   const meta=pgAutomationSettingMetadata(key),raw=pgAutomation.supportedValues[key],value=pgAutomationSettingValue(key==='gamma'?(pgAutomationTvGamma(raw)||raw):raw),pin=pinned.includes(key);
   let input;
   const attrs=' data-pg-automation-key="'+pgAutomationEscape(key)+'" onchange="pgAutomationSettingChanged(this.dataset.pgAutomationKey)"'+(pin?'':' disabled');
   if(meta.type==='select'&&Array.isArray(meta.options)){
    const options=meta.options.slice();if(value&&!options.includes(value))options.unshift(value);
    input='<select'+attrs+' aria-label="'+pgAutomationEscape(meta.label||key)+'">'+options.map(option=>'<option value="'+pgAutomationEscape(option)+'"'+(String(option)===value?' selected':'')+'>'+pgAutomationEscape(meta.labels?.[option]||option)+'</option>').join('')+'</select>';
   }else{
    input='<input'+attrs+' aria-label="'+pgAutomationEscape(meta.label||key)+'" type="'+(meta.type==='number'?'number':'text')+'"'+(meta.min!=null?' min="'+pgAutomationEscape(meta.min)+'"':'')+(meta.max!=null?' max="'+pgAutomationEscape(meta.max)+'"':'')+' value="'+pgAutomationEscape(value)+'">';
   }
   return '<div class="field"><label><input type="checkbox" data-pg-automation-pin="'+pgAutomationEscape(key)+'"'+(pin?' checked':'')+(unavailable?' disabled':'')+' onchange="pgAutomationTogglePin(this)"> '+pgAutomationEscape(meta.label||key)+'</label>'+input+(unavailable?'<span class="auto-muted">'+pgAutomationEscape(unavailable.reason)+'</span>':'')+'</div>';
  }).join('');
 pgAutomationUpdateSettingsStatus();
 pgAutomationRenderPanelKeyOptions();
 pgAutomationEl('SelectAllSettings').disabled=!keys.some(key=>pgAutomation.supportedValues[key]!=null);
 pgAutomationEl('SelectAllSettings').title='Pin every control with a configured value; blank controls are left unchanged';
}
function pgAutomationUpdateSettingsStatus(){
 const count=pgAutomation.pinnedKeys.filter(key=>!['backlight','oledLight','oledPixelBrightness'].includes(key)).length;
 pgAutomationEl('SettingsStatus').textContent=count+' picture controls pinned · '+(pgAutomation.settingsPlan?'TV-matrix selection for '+(pgAutomation.settingsPlan.model_name||'unidentified TV')+'. Writes are verified at run time.':pgAutomation.supportedKeys.length?'TV values read for '+pgAutomationModeLabel(pgAutomation.supportedPictureMode,pgAutomation.supportedSignal)+'.':'Reference values prepared; TV compatibility must be checked.');
}
function pgAutomationTogglePin(el){
 const key=el.getAttribute('data-pg-automation-pin');
 pgAutomationSettingChanged(key);
 pgAutomation.pinnedKeys=pgAutomation.pinnedKeys.filter(x=>x!==key);
 if(el.checked)pgAutomation.pinnedKeys.push(key);
 const input=Array.from(document.querySelectorAll('[data-pg-automation-key]')).find(x=>x.getAttribute('data-pg-automation-key')===key);
 if(input)input.disabled=!el.checked;
 pgAutomationUpdateSettingsStatus();
}
function pgAutomationRenderPanelKeyOptions(){
 const panel=pgAutomation.settingsPlan?.panel_light;
 pgAutomationEl('PanelBinding').textContent=panel?.wire_key?panel.label:'TV control not yet identified';
 pgAutomationEl('PanelBindingHelp').textContent=panel?.wire_key?(panel.target_available?(panel.source==='native_readback'?'Confirmed by TV readback.':'Selected from the TV matrix; live readback is required before target adjustment.'):'Automatic luminance targeting is unavailable because this control cannot be read back. Set panel brightness manually or use a supported fixed write.'):'Connect your TV, then refresh compatibility. No API alias needs to be selected.';
}
async function pgAutomationResolveSettingsPlan(){
 if(typeof fetchJSON!=='function')return;
 const epoch=pgAutomation.editorEpoch,request=(pgAutomation.planRequest||0)+1;
 pgAutomation.planRequest=request;pgAutomation.planPending=true;pgAutomation.planError='';
 pgAutomationEl('PanelBinding').textContent='Checking TV compatibility…';
 pgAutomationEl('KeysButton').disabled=true;pgAutomationUpdateEditor();
 try{
  Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());
  const result=await fetchJSON('/api/automation/settings-plan',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({signal_mode:pgAutomationValue('Signal','sdr'),picture_mode:pgAutomationValue('PictureMode',''),settings:pgAutomation.supportedValues}),_quiet:true,_timeoutMs:60000});
  if(epoch!==pgAutomation.editorEpoch||request!==pgAutomation.planRequest)return;
  if(result?.status!=='ok')throw new Error(result?.message||'Connect the TV and refresh compatibility before saving.');
  // Filter the current selection, not the selection at request time. Edits made
  // during the read remain intact; a refresh never copies live TV values.
  Object.assign(pgAutomation.supportedValues,pgAutomationReadSettingsEditor());
  pgAutomation.settingsPlan=result;
  const intended=Array.from(new Set([...pgAutomation.pinnedKeys,...Object.keys(pgAutomation.manualSettings||{})]));
  pgAutomation.manualSettings=Object.fromEntries(intended.filter(key=>result.manual?.[key]).map(key=>[key,{...result.manual[key],value:pgAutomation.supportedValues[key]}]));
  pgAutomation.pinnedKeys=intended.filter(key=>Object.prototype.hasOwnProperty.call(result.automatic||{},key));
  const panel=result.panel_light||{};
  pgAutomationEl('PanelKey').value=panel.writable?panel.wire_key||'':'';
  pgAutomationRenderManualSettings();
  pgAutomationRenderSettingsEditor();
 }catch(e){
  if(epoch!==pgAutomation.editorEpoch||request!==pgAutomation.planRequest)return;
  pgAutomation.planError=e.message;pgAutomationEl('PanelBinding').textContent='TV compatibility unavailable';
  pgAutomationEl('PanelBindingHelp').textContent=e.message+' Refresh TV compatibility to retry.';
 }finally{
  if(epoch===pgAutomation.editorEpoch&&request===pgAutomation.planRequest){pgAutomation.planPending=false;pgAutomationEl('EditorSave').disabled=!!pgAutomation.editorSaving||!!pgAutomation.planError;pgAutomationEl('KeysButton').disabled=false;pgAutomationUpdateEditor();}
 }
}
function pgAutomationRenderManualSettings(){
 const manual=Object.entries(pgAutomation.manualSettings||{}).map(([key,entry])=>'Set '+(pgAutomationSettingMetadata(key).label||key)+' to '+pgAutomationSettingValue(entry.value)+' in the TV menu ('+entry.reason+').');
 const blocked=Object.entries(pgAutomation.settingsPlan?.blocked||{}).map(([key,entry])=>(pgAutomationSettingMetadata(key).label||key)+': '+entry.reason+'.');
 const panel=pgAutomation.settingsPlan?.panel_light;
 if(panel&&!panel.writable)manual.push('Set '+panel.label+' manually to '+pgAutomationValue('PanelValue',100)+'; automatic panel adjustment is unavailable.');
 pgAutomationEl('ManualSettings').textContent=[...manual,...blocked].join(' ');
}
function pgAutomationReadSettingsEditor(){
 const values={};
 pgAutomation.pinnedKeys.forEach(key=>{if(pgAutomation.supportedValues[key]!=null)values[key]=pgAutomation.supportedValues[key];});
 document.querySelectorAll('[data-pg-automation-key]').forEach(input=>{
  const key=input.getAttribute('data-pg-automation-key');
  if(!pgAutomation.pinnedKeys.includes(key)){delete values[key];return;}
  if(input.value==='')throw new Error('Enter a value for '+key+' or unpin it.');
  const meta=pgAutomationSettingMetadata(key);
  if(meta.type==='number'&&(!Number.isFinite(Number(input.value))||Number(input.value)<meta.min||Number(input.value)>meta.max))throw new Error(meta.label+' must be between '+meta.min+' and '+meta.max+'.');
  const original=pgAutomation.supportedValues[key];
  if(original&&typeof original==='object'&&/^[\[{]/.test(input.value.trim())){
   try{values[key]=JSON.parse(input.value);}catch(e){throw new Error('Invalid structured value for '+key);}
  }else values[key]=meta.type==='number'||typeof original==='number'&&Number.isFinite(Number(input.value))?Number(input.value):input.value;
 });
 return values;
}
async function pgAutomationLoadSupportedKeys(){
 const signal=pgAutomationValue('Signal','sdr'),pictureMode=pgAutomationValue('PictureMode',''),epoch=pgAutomation.editorEpoch;
 const button=pgAutomationEl('KeysButton');button.disabled=true;button.textContent='Reading Controls…';
 try{
  const prior=pgAutomationReadSettingsEditor();
  const panelBefore=['PanelKey','PanelPolicy','PanelValue','PanelTarget'].map(id=>pgAutomationValue(id,''));
  const candidates=pgAutomationSettingCandidates();
  const result=await fetchJSON('/api/lg/picture-settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keys:[...candidates,'pictureMode'],picture_mode:pictureMode,signal_mode:signal,category:'picture',include_current_input:true}),_quiet:true,_timeoutMs:60000});
  if(epoch!==pgAutomation.editorEpoch||signal!==pgAutomationValue('Signal','sdr')||pictureMode!==pgAutomationValue('PictureMode',''))return;
  if(!result||result.status==='error')throw new Error(result?.message||'Could not read TV controls. Check the TV connection.');
  if(JSON.stringify(prior)!==JSON.stringify(pgAutomationReadSettingsEditor())||JSON.stringify(panelBefore)!==JSON.stringify(['PanelKey','PanelPolicy','PanelValue','PanelTarget'].map(id=>pgAutomationValue(id,''))))throw new Error('Settings changed while the TV was being read. Your edits were kept; use TV settings again if you want to replace them.');
  const current=result.picture_settings||result.settings||{};
  const canonical=value=>String(typeof lgPictureModeCanonicalValue==='function'?lgPictureModeCanonicalValue(value):value).replace(/[\s_-]/g,'').toLowerCase();
  if(current.pictureMode&&canonical(current.pictureMode)!==canonical(pictureMode))throw new Error('The TV reported a different picture mode. Select '+pgAutomationModeLabel(pictureMode,signal)+' on the TV before using its settings. Prepared values were kept.');
  const values=Object.fromEntries(Object.entries(current).filter(([key,value])=>candidates.includes(key)&&value!=null&&!(typeof value==='string'&&!value.trim())&&!result.unsupported_picture_keys?.[key]&&(!result.virtual_picture_settings||(result.supported_picture_keys||[]).includes(key))));
  if(!Object.keys(values).length)throw new Error('The TV returned no readable picture controls. Prepared values were kept.');
  pgAutomation.supportedKeys=Array.from(new Set([...(result.supported_picture_keys||[]),...Object.keys(values)])).filter(key=>candidates.includes(key));
  // Keep unread values available for deliberate manual selection, not as
  // automatic writes. A read limitation alone does not prove a write is unsafe.
  const removed=Object.keys(prior).filter(key=>!Object.prototype.hasOwnProperty.call(values,key));
  const writable=Object.keys(values).filter(key=>!['blocked','not_applicable'].includes(result.setting_contracts?.[key]?.write_decision));
  pgAutomation.supportedKeys=Array.from(new Set([...candidates,...Object.keys(values)]));
  pgAutomation.supportedValues=Object.assign({},pgAutomation.supportedValues,prior,values);
  pgAutomation.pinnedKeys=writable;
  pgAutomation.manualSettings={};
  pgAutomation.gammaFollowsTarget=false;
  pgAutomation.supportedSignal=signal;pgAutomation.supportedPictureMode=pictureMode;
  const panelKey=result.logical_controls?.panel_light?.wire_key||pgAutomation.settingsPlan?.panel_light?.wire_key||pgAutomationValue('PanelKey','');
  if(panelKey&&writable.includes(panelKey)){pgAutomationEl('PanelKey').value=panelKey;pgAutomationEl('PanelValue').value=values[panelKey];}
  else pgAutomationEl('PanelKey').value='';
  pgAutomationRenderSettingsEditor();
  pgAutomationEl('PanelKey').value=panelKey&&writable.includes(panelKey)?panelKey:'';
  pgAutomationUpdateEditor();
  await pgAutomationResolveSettingsPlan();
  const reasons=removed.map(key=>key+': '+(result.unsupported_picture_keys?.[key]?'TV readback unavailable':'no native value returned')).join('; ');
  pgAutomationNotice(writable.length+' readable controls copied. '+removed.length+' unread pins removed'+(reasons?' ('+reasons+')':'')+'. You can explicitly select write-only controls; the TV matrix decides whether to write them or require a manual check. No TV settings were changed.');
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{button.disabled=false;button.textContent='Use TV Settings';}
}
function pgAutomationUpdateEditor(){
 pgAutomationModeEligibility();
 const signal=pgAutomationValue('Signal','sdr'),cal=pgAutomationChecked('Cal')&&signal!=='hlg',post=pgAutomationChecked('Post');
 const sdr=signal==='sdr',dv=signal==='dv',hdr=signal==='hdr10',hlg=signal==='hlg';
 const show=(id,value)=>{pgAutomationEl(id).style.display=value?'':'none';};
 pgAutomationEl('Cal').disabled=hlg;
 if(hlg)pgAutomationEl('Cal').checked=false;
 pgAutomationEl('ApplyAll').disabled=!cal;
 pgAutomationEl('QualitySection').style.display=post?'':'none';
 pgAutomationEl('Sweeps').style.display=post||pgAutomationChecked('Pre')?'':'none';
 pgAutomationEl('PanelTarget').disabled=!sdr||!cal;
 pgAutomationEl('PanelTargetRadio').disabled=pgAutomation.planPending||!!pgAutomation.planError||!!pgAutomation.settingsPlan&&!pgAutomation.settingsPlan.panel_light?.target_available;
 pgAutomationEl('PanelPolicy').querySelector('option[value="target"]').disabled=signal!=='sdr'||!cal;
 if(!sdr||!cal)pgAutomationEl('PanelPolicy').value='fixed';
 const target=pgAutomationValue('PanelPolicy','fixed')==='target';
 pgAutomationEl('PanelFixed').checked=!target;pgAutomationEl('PanelTargetRadio').checked=target;
 pgAutomationEl('PanelSlider').value=pgAutomationEl('PanelValue').value;
 show('PanelTargetChoice',sdr&&cal);show('PanelFixedField',!target);show('PanelTargetField',target);
 show('OutputSection',!dv);show('WorkflowOptions',cal&&!hlg);show('OneDSection',cal&&!hlg);
 show('VolumeFields',sdr&&cal);show('ShadowFixField',hdr&&cal);
 show('LatticeSizeField',pgAutomationValue('Method','hybrid3')==='lattice');
 show('CubeSizeField',cal&&!dv&&!hlg);show('ResidualsField',sdr&&cal&&pgAutomationValue('Method','hybrid3')!=='matrix');
 pgAutomationEl('Method').disabled=!cal||hdr||dv||hlg;
 pgAutomationEl('ShadowFix').disabled=!cal||signal!=='hdr10';
 pgAutomationEl('Residuals').disabled=!cal||dv||hdr||hlg||pgAutomationValue('Method','hybrid3')==='matrix';
 pgAutomationEl('CubeSize').disabled=!cal||signal==='dv';
 pgAutomationEl('Gamma').disabled=hdr||dv||hlg;
 Array.from(pgAutomationEl('Gamma').options).forEach(option=>{option.hidden=sdr?['st2084','hlg'].includes(option.value):option.value!==(hlg?'hlg':'st2084');});
 if(!sdr)pgAutomationEl('Gamma').value=hlg?'hlg':'st2084';
 pgAutomationEl('ColorFormat').disabled=dv;pgAutomationEl('Range').disabled=dv;pgAutomationEl('BitDepth').disabled=dv;
 pgAutomationEl('WorkflowHelp').textContent=hlg?'HLG supports before/after measurements. The existing LG AutoCal workers support SDR, HDR10 and Dolby Vision, not HLG calibration.':!cal?'Measurements only: apply this item’s settings, then capture selected sweeps. No calibration reset or LUT upload.':dv?'Before readings → reset greyscale → HDR greyscale / 1D LUT → Dolby Vision panel profile upload → after readings. No 3D LUT.':hdr?'Before readings → reset greyscale and 3D LUT → HDR greyscale / 1D LUT → HDR10 matrix 3D LUT → after readings.':'Before readings → reset and reapply settings → set and measure 100% white → greyscale / 1D LUT → color 3D LUT → after readings.';
 pgAutomationEl('GammaHeading').textContent=sdr?'Gamma Target':'Calibration and Verification Targets';
 pgAutomationEl('GammaHelp').textContent=sdr?'The 1D LUT is calibrated to this curve; after readings use the same target. TV Gamma is a separate setup control, bypassed after a 1D LUT upload. '+(pgAutomation.gammaFollowsTarget?(pgAutomationValue('Gamma','')==='srgb'?'LG has no sRGB menu preset, so TV Gamma is not pinned.':'The prepared TV Gamma follows this target; editing or unpinning TV Gamma overrides that link.'):'Your TV Gamma override is kept separately. Restore Reference Defaults to link it to the target again.'):hlg?'HLG measurements use the HLG transfer function.':(dv?'Dolby Vision uses pinned RGB Full 8-bit transport and its dedicated map modes. ':'')+'Greyscale calibrates in Gamma 2.2; before/after readings use ST 2084 (PQ). Peak luminance is measured by the HDR worker.';
 pgAutomationEl('LuminanceHelp').textContent=!cal?'Only fixed TV controls are applied; no luminance-target loop is run.':sdr?(target?'Adjusts panel light to this setup target, then captures the actual 100% white. ':'Keeps this fixed control value, then measures its actual 100% white. ')+'Like the manual wizard, the setup white sets the 1D reference and SDR headroom. The final calibrated white can be lower (the wizard notes roughly 15%); this is not a guaranteed post-cal luminance target.':'Fixed panel light is preserved through calibration. HDR10 and Dolby Vision skip the SDR luminance loop and use the measured native peak.';
 const method=pgAutomationValue('Method','hybrid3');
 pgAutomationEl('LutHelp').textContent=dv?'Builds and uploads a measured Dolby Vision panel profile. Dark Detail applies to the greyscale pass; no color-cube or shadow-fix options.':hdr?'Matrix 3D LUT profiling and 33³ upload, followed by the HDR tone-mapping handoff.':(typeof meterLg3dProfilingExplain==='function'&&method!=='ramp'?meterLg3dProfilingExplain(method):'Color profiling followed by a 33³ TV LUT upload.');
}
function pgAutomationNumber(id,fallback,min,max){
 const value=Number(pgAutomationValue(id,fallback));
 if(!Number.isFinite(value)||value<min||value>max)throw new Error((pgAutomationEl(id)?.labels?.[0]?.textContent||id)+' must be between '+min+' and '+max+'.');
 return value;
}
function pgAutomationRecipeFromForm(){
 if(pgAutomation.planError)throw new Error(pgAutomation.planError);
 const admission=pgAutomation.settingsPlan?.calibration_mode;
 if(pgAutomationChecked('Cal')&&admission&&!admission.allowed)throw new Error(admission.message);
 const recipe=pgAutomationSnapshot(pgAutomation.editingRecipe),signal=pgAutomationValue('Signal','sdr'),settings=pgAutomationReadSettingsEditor();
 const stages={pre_readings:pgAutomationChecked('Pre'),calibration:pgAutomationChecked('Cal'),post_readings:pgAutomationChecked('Post'),apply_all:pgAutomationChecked('Cal')&&pgAutomationChecked('ApplyAll')};
 if(!stages.pre_readings&&!stages.calibration&&!stages.post_readings)throw new Error('Enable at least one stage.');
 if(signal==='hlg'&&stages.calibration)throw new Error('HLG supports measurements only; use SDR, HDR10 or Dolby Vision for LG AutoCal.');
 const pre=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('Series'+x[0])).map(x=>x[1]);
 const post=PG_AUTOMATION_SERIES.filter(x=>pgAutomationChecked('PostSeries'+x[0])).map(x=>x[1]);
 if(stages.pre_readings&&!pre.length||stages.post_readings&&!post.length)throw new Error('Select a sweep for each enabled readings stage.');
 const panelKey=pgAutomationValue('PanelKey',''),policy=pgAutomationValue('PanelPolicy','fixed');
 if(policy==='target'&&(signal!=='sdr'||!stages.calibration||!panelKey))throw new Error('Target luminance requires SDR AutoCal and a supported panel-light control.');
 if(policy==='target'&&pgAutomation.settingsPlan&&!pgAutomation.settingsPlan.panel_light?.target_available)throw new Error('Target luminance requires readable panel brightness. Use fixed brightness and the manual TV checks for this model.');
 const panelValue=pgAutomationNumber('PanelValue',signal==='sdr'?80:100,0,100);
 ['backlight','oledLight','oledPixelBrightness'].forEach(key=>delete settings[key]);
 if(panelKey&&policy==='fixed')settings[panelKey]=panelValue;
 const target=pgAutomationNumber('PanelTarget',100,1,10000),formula=pgAutomationValue('Formula','deitp');
 const limits={};
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{const prefix='Quality'+(suffix==='Grey'?'':suffix);limits[key]={avg:pgAutomationNumber(prefix+'Avg',2,0,10000),max:pgAutomationNumber(prefix+'Max',5,0,10000)};});
 const white={x:pgAutomationNumber('WhiteX',.3127,.01,.9),y:pgAutomationNumber('WhiteY',.329,.01,.9)};
 if(white.x+white.y>=1)throw new Error('White point x + y must be below 1.');
 Object.assign(recipe,{
  name:pgAutomationValue('RecipeName','Automation item'),signal_format:signal,picture_mode:pgAutomationValue('PictureMode',''),
  settings,stages,pre_series:pre,post_series:post,tv_gamma_follows_target:signal==='sdr'&&pgAutomation.gammaFollowsTarget,
  target_luminance:target,target_gamma:pgAutomationValue('Gamma','bt1886'),target_gamut:pgAutomationValue('Gamut','bt709'),
  target_delta_e:pgAutomationNumber('Delta',.5,.1,100),delta_e_formula:formula,target_white:white,
  display_use_case:signal==='dv'?'keep':pgAutomationValue('UseCase','keep'),color_format:signal==='dv'?'0':pgAutomationValue('ColorFormat','0'),
  eotf:signal==='sdr'?'0':signal==='hlg'?'3':'2',primaries:signal==='sdr'?'0':signal==='dv'?'1':'2',colorimetry:signal==='sdr'?'2':'9',
  panel_light:{policy,key:panelKey,fixed_value:panelValue,target_luminance:target},
  panel_protection:{disable:pgAutomationChecked('PanelProtection')},
  quality:{enabled:stages.post_readings&&pgAutomationChecked('Quality'),policy:pgAutomationValue('QualityPolicy','audit'),dE_formula:formula,limits},
  patch_size:pgAutomationNumber('PatchSize',10,1,100),delay_ms:pgAutomationNumber('Delay',1000,0,30000),
  settle_seconds:pgAutomationNumber('Settle',8,0,600),
  signal_range:pgAutomationValue('Range','2'),pattern_signal_range:pgAutomationValue('Range','2'),
  transport_signal_range:pgAutomationValue('Range','2'),rgb_quant_range:pgAutomationValue('Range','2'),
  max_bpc:signal==='dv'?8:pgAutomationNumber('BitDepth',10,8,10),display_type:pgAutomationValue('DisplayType','lcd'),ccss_override:pgAutomationValue('Ccss','')
 });
 if(signal==='dv')recipe.signal_range=recipe.pattern_signal_range=recipe.transport_signal_range=recipe.rgb_quant_range='2';
 if(recipe.quality.policy==='enforce'&&!recipe.quality.enabled)throw new Error('Enforce requires After Readings and Enable Quality Checks.');
 const previous=recipe.reference_manual_checks||[];
 recipe.reference_manual_checks=Object.entries(pgAutomation.manualSettings||{}).map(([key,entry])=>'Set '+(pgAutomationSettingMetadata(key).label||key)+' to '+pgAutomationSettingValue(entry.value)+' in the TV menu for '+recipe.picture_mode+' ('+signal+'). '+entry.reason+'.');
 if(pgAutomation.settingsPlan?.panel_light&&!pgAutomation.settingsPlan.panel_light.writable)recipe.reference_manual_checks.push('Set '+pgAutomation.settingsPlan.panel_light.label+' manually to '+panelValue+' for '+recipe.picture_mode+' ('+signal+'). Automatic panel adjustment is unavailable.');
 recipe.reference_manual_settings=pgAutomationClone(pgAutomation.manualSettings||{});
 recipe.manual_checks=[...(recipe.manual_checks||[]).filter(text=>!previous.includes(text)),...recipe.reference_manual_checks];
 const source=signal==='hdr10'?'matrix':pgAutomationValue('Method','hybrid3'),method=source.startsWith('hybrid')?'hybrid':source;
 const size=source==='hybrid9'?9:source==='hybrid5'?5:source==='hybrid3'?3:Number(pgAutomationValue('LatticeSize',5));
 const oldCal=recipe.calibration||{};
 recipe.calibration=Object.assign({},recipe.calibration||{},{
  target_gamma:recipe.target_gamma,target_gamut:recipe.target_gamut,target_luminance:target,target_delta_e:recipe.target_delta_e,delta_e_formula:formula,target_white:white,
  method,profile_source:source,lattice_size:size,solve_cube_size:Number(pgAutomationValue('CubeSize',17)),
  lattice_residuals:signal==='sdr'&&pgAutomationChecked('Residuals'),dark_detail:stages.calibration&&pgAutomationChecked('DarkDetail'),shadow_fix:signal==='hdr10'&&pgAutomationChecked('ShadowFix')
 });
 // A deliberately changed profile must not retain a previous expanded cube.
 const oldSource=oldCal.profile_source||(oldCal.method==='hybrid'?'hybrid'+(oldCal.lattice_size||5):oldCal.method);
 if(oldSource!==source||Number(oldCal.lattice_size||5)!==size)delete recipe.calibration.lattice_patches;
 return recipe;
}
function pgAutomationFillRecipe(recipe){
 recipe=recipe||{};pgAutomation.editorEpoch++;pgAutomation.editingRecipe=pgAutomationClone(recipe);
 pgAutomation.settingsPlan=null;pgAutomation.manualSettings=pgAutomationClone(recipe.reference_manual_settings||{});pgAutomation.planPending=false;pgAutomation.planError='';
 pgAutomationEl('ManualSettings').textContent='';pgAutomationEl('EditorSave').disabled=false;
 pgAutomation.fillingEditor=true;pgAutomation.editorSettingsDrafts={};pgAutomation.editorSettingsKey='';
 pgAutomation.gammaFollowsTarget=!!recipe.tv_gamma_follows_target;
 pgAutomation.supportedKeys=[];pgAutomation.supportedSignal='';pgAutomation.supportedPictureMode='';
 const set=(id,value)=>{pgAutomationEl(id).value=value==null?'':value;},check=(id,value)=>{pgAutomationEl(id).checked=!!value;};
 const cal=recipe.calibration||{},panel=recipe.panel_light||{},stages=recipe.stages||{};
 set('RecipeName',recipe.name||'SDR Filmmaker');set('Signal',recipe.signal_format||'sdr');pgAutomationModesChanged();
 const mode=recipe.picture_mode||pgAutomationModes(recipe.signal_format||'sdr')[0];
 if(!Array.from(pgAutomationEl('PictureMode').options).some(x=>x.value===mode))pgAutomationEl('PictureMode').add(new Option(mode,mode));
 set('PictureMode',mode);pgAutomationModeChanged();
 pgAutomation.supportedValues=pgAutomationClone(recipe.settings||{});pgAutomation.pinnedKeys=Object.keys(recipe.settings||{});
 Object.entries(pgAutomation.manualSettings).forEach(([key,entry])=>{if(!Object.prototype.hasOwnProperty.call(pgAutomation.supportedValues,key))pgAutomation.supportedValues[key]=entry.value;});
 if(Array.isArray(recipe.supported_picture_keys)&&recipe.supported_picture_keys.length){pgAutomation.supportedKeys=recipe.supported_picture_keys.filter(key=>pgAutomationSettingCandidates().includes(key));pgAutomation.supportedSignal=recipe.signal_format;pgAutomation.supportedPictureMode=mode;}
 pgAutomationRenderSettingsEditor();
 ['Pre','Cal','Post','ApplyAll'].forEach((id,index)=>{const key=['pre_readings','calibration','post_readings','apply_all'][index];check(id,pgAutomationStageEnabled(stages,key));});
 check('PanelProtection',recipe.panel_protection?.disable===true);
 PG_AUTOMATION_SERIES.forEach(([suffix,key])=>{
  check('Series'+suffix,(recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  check('PostSeries'+suffix,(recipe.post_series||recipe.pre_series||PG_AUTOMATION_SERIES.map(x=>x[1])).includes(key));
  const limit=recipe.quality?.limits?.[key]||{},prefix='Quality'+(suffix==='Grey'?'':suffix);
  set(prefix+'Avg',limit.avg??2);set(prefix+'Max',limit.max??5);
 });
 check('Quality',recipe.quality?.enabled);
 set('QualityPolicy',recipe.quality?.policy||'audit');
 set('PanelPolicy',panel.policy||'fixed');set('PanelKey',panel.key||'');pgAutomationRenderPanelKeyOptions();
 set('PanelValue',panel.fixed_value??panel.value??80);set('PanelTarget',panel.target_luminance??recipe.target_luminance??100);
 set('Gamma',recipe.target_gamma||cal.target_gamma||(recipe.signal_format==='sdr'?'bt1886':recipe.signal_format==='hlg'?'hlg':'st2084'));
 set('Gamut',recipe.target_gamut||cal.target_gamut||(recipe.signal_format==='sdr'?'bt709':'p3d65'));
 set('Delta',cal.target_delta_e??recipe.target_delta_e??.5);set('Formula',cal.delta_e_formula||recipe.delta_e_formula||'deitp');
 set('WhiteX',cal.target_white?.x??recipe.target_white?.x??.3127);set('WhiteY',cal.target_white?.y??recipe.target_white?.y??.329);
 const source=cal.profile_source||(cal.method==='hybrid'?'hybrid'+(cal.lattice_size||5):cal.method)||'hybrid3';
 set('Method',recipe.signal_format==='hdr10'?'matrix':source);set('LatticeSize',cal.lattice_size||5);set('CubeSize',cal.solve_cube_size||17);
 check('Residuals',cal.lattice_residuals??true);check('DarkDetail',cal.dark_detail);check('ShadowFix',cal.shadow_fix);
 set('PatchSize',recipe.patch_size??10);set('Delay',recipe.delay_ms??1000);set('Settle',recipe.settle_seconds??8);
 set('UseCase',recipe.display_use_case||'keep');set('ColorFormat',recipe.signal_format==='dv'?'0':recipe.color_format||'0');
 set('Range',recipe.signal_format==='dv'?'2':recipe.signal_range||'2');set('BitDepth',recipe.signal_format==='dv'?8:recipe.max_bpc||10);
 pgAutomationPopulateMeterChoices(recipe.display_type||'lcd',recipe.ccss_override||'');
 check('SaveAsRecipe',false);pgAutomationUpdateEditor();
 pgAutomation.editorSettingsKey=pgAutomationValue('Signal','sdr')+':'+mode;pgAutomation.fillingEditor=false;
}
function pgAutomationOpenEditor(target,recipe,index){
 pgAutomation.editorTarget=target||'queue';pgAutomation.editingQueueIndex=index==null?null:index;
 pgAutomationFillRecipe(recipe);
 pgAutomationEl('EditorTitle').textContent=target==='recipe'?'Configure Saved Recipe':index==null?'Add Queue Item':'Configure Item '+(index+1);
 pgAutomationEl('EditorSave').textContent=target==='recipe'?'Save Recipe':index==null?'Add to Queue':'Save Item';
 pgAutomationEl('SaveAsRecipeLabel').style.display=target==='recipe'?'none':'';
 pgAutomationEl('EditorError').textContent='';
 pgAutomationOpenDialog(pgAutomationEl('Editor'));
 pgAutomationEl('Editor').scrollTop=0;
 pgAutomationResolveSettingsPlan();
}
function pgAutomationCancelEditor(){pgAutomation.editorEpoch++;pgAutomationCloseDialog(pgAutomationEl('Editor'));pgAutomation.editingQueueIndex=null;}
function pgAutomationNewRecipe(target){
 let measurement={};
 try{
  measurement={display_type:typeof getEffectiveDisplayType==='function'?getEffectiveDisplayType():'lcd',
   ccss_override:typeof getCcssOverride==='function'?getCcssOverride():'',
   delay_ms:typeof meterDelayMs==='function'?meterDelayMs():1000,patch_size:typeof getMeterPatchSize==='function'?getMeterPatchSize():10,
   refresh_rate:typeof getMeterRefreshRate==='function'?getMeterRefreshRate():'',
   low_light:typeof meterLowLightReadState==='function'?meterLowLightReadState():{},
   ...(typeof meterPatternInsertionPayload==='function'?meterPatternInsertionPayload():{})};
 }catch(e){}
 const mode=pgAutomationModes('sdr').find(x=>/filmmaker/i.test(x))||'cinema';
 const defaults=pgAutomationPictureDefaults('sdr',mode,'backlight');
 pgAutomationOpenEditor(target||'queue',{...measurement,display_use_case:'tv',color_format:'1',signal_range:'1',max_bpc:10,name:pgAutomationModeLabel(mode,'sdr'),signal_format:'sdr',picture_mode:mode,settings:defaults.settings,target_gamma:defaults.target_gamma,tv_gamma_follows_target:!!defaults.tv_gamma_follows_target,panel_light:defaults.panel_light,manual_checks:defaults.manual_checks});
 pgAutomation.supportedValues=pgAutomationClone(defaults.settings);pgAutomationRenderSettingsEditor();
 pgAutomationDisplayTypeChanged();
}
// The object to POST as a recipe. A recipe is a source, never a derivative, so
// it must not carry source_recipe: a queue item added from recipe A and then
// saved as recipe B would otherwise claim to descend from A, and every job
// added from B would badge against A. Dropping the id lets the server assign a
// fresh one; keepId is set only when editing an existing recipe in place.
function pgAutomationRecipeForSave(item,keepId){
 const recipe=pgAutomationClone(item);
 if(!keepId)delete recipe.id;
 delete recipe.source_recipe;
 return recipe;
}
async function pgAutomationSaveRecipe(){
 const button=pgAutomationEl('EditorSave');if(button.disabled||pgAutomation.editorSaving)return;button.disabled=true;
 // A compatibility reply can land while a recipe POST is in flight; this flag
 // keeps every Save re-enable path shut until the save finishes (no double save).
 pgAutomation.editorSaving=true;
 let saved=false;
 try{
  const item=pgAutomationRecipeFromForm();
  if(pgAutomation.editorTarget==='recipe'||pgAutomationChecked('SaveAsRecipe')){
   const recipe=pgAutomationRecipeForSave(item,pgAutomation.editorTarget==='recipe');
   await pgAutomationRequest('recipes',{recipe});
  }
  if(pgAutomation.editorTarget!=='recipe'){
   if(pgAutomation.editingQueueIndex!=null)pgAutomation.queue.items[pgAutomation.editingQueueIndex]=item;
   else pgAutomation.queue.items.push(item);
   pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
  }
  pgAutomationCancelEditor();pgAutomationNotice(pgAutomation.editorTarget==='recipe'?'Recipe saved':'Queue item saved');saved=true;
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.editorSaving=false;button.disabled=false;if(pgAutomationEl('Editor').open)pgAutomationModeEligibility();}
 // The save is finished once it is stored: a slow page refresh must not keep
 // the editor's Save locked (P8).
 if(saved){try{await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}}
}
function pgAutomationItemSettingsList(item){
 const panel=item.panel_light||{};
 const settings=Object.entries(item.settings||{}).map(([key,value])=>pgAutomationSettingMetadata(key).label+' '+pgAutomationSettingValue(value));
 if(panel.key&&!Object.prototype.hasOwnProperty.call(item.settings||{},panel.key)&&panel.policy!=='target')settings.push(pgAutomationSettingMetadata(panel.key).label+' '+(panel.fixed_value??80));
 return settings;
}
// part 'targets' is what the job was asked to achieve, 'setup' is what was
// pinned on the TV to achieve it. Callers outside the job report take both.
function pgAutomationItemSummary(item,part){
 const signal=item.signal_format||'sdr',cal=item.calibration||{},stages=item.stages||{},panel=item.panel_light||{};
 const enabled=key=>pgAutomationStageEnabled(stages,key);
 const pills=[signal==='dv'?'Dolby Vision':signal.toUpperCase(),pgAutomationModeLabel(item.picture_mode,signal)];
 if(enabled('pre_readings'))pills.push('Before: '+(item.pre_series||PG_AUTOMATION_SERIES).length+' sweeps');
 if(enabled('calibration'))pills.push(signal==='dv'?'1D LUT + DV profile':'1D LUT + '+(signal==='hdr10'?'matrix':cal.profile_source||cal.method||'hybrid')+' 3D LUT');
 if(enabled('calibration')&&enabled('apply_all'))pills.push('All inputs');
 if(item.panel_protection?.disable===true)pills.push('TPC/GSR off');
 if(enabled('post_readings'))pills.push('After: '+(item.post_series||PG_AUTOMATION_SERIES).length+' sweeps');
 const settings=pgAutomationItemSettingsList(item);
 const targets=[];
 if(enabled('calibration'))targets.push('1D LUT ΔE '+(cal.target_delta_e??item.target_delta_e??.5)+' ('+pgAutomationLabel(cal.delta_e_formula||item.delta_e_formula||'deitp')+')');
 targets.push(signal==='sdr'?(panel.policy==='target'?'Setup white target '+(panel.target_luminance??item.target_luminance??100)+' nits':'Fixed panel light; setup white measured at run time'):'Measured peak luminance');
 targets.push(pgAutomationLabel(item.target_gamma||cal.target_gamma||(signal==='sdr'?'bt1886':'st2084')));targets.push(pgAutomationLabel(item.target_gamut||cal.target_gamut||(signal==='sdr'?'bt709':'p3d65')));
 const targetsHtml='<div class="auto-pills">'+pills.map(x=>'<span class="auto-pill">'+pgAutomationEscape(x)+'</span>').join('')+'</div><div class="auto-muted">'+targets.map(pgAutomationEscape).join(' · ')+'</div>';
 const setupHtml='<div class="auto-muted auto-pin-summary"><strong>TV settings</strong>'+(settings.length?'<ul>'+settings.map(value=>'<li>'+pgAutomationEscape(value)+'</li>').join('')+'</ul>':'<p>No explicit pins; default hazard controls applied</p>')+'</div>'+(item.template_notes?'<details class="auto-muted"><summary>Setup notes</summary><p>'+pgAutomationEscape(item.template_notes)+'</p></details>':'');
 if(part==='targets')return targetsHtml;
 if(part==='setup')return setupHtml;
 return targetsHtml+setupHtml;
}
function pgAutomationTargetLine(item){
 const cal=item.calibration||{},signal=item.signal_format||'sdr';
 const enabled=key=>pgAutomationStageEnabled(item.stages||{},key);
 const parts=[];
 if(enabled('calibration'))parts.push('ΔE '+(cal.target_delta_e??item.target_delta_e??.5));
 parts.push(pgAutomationLabel(item.target_gamut||cal.target_gamut||(signal==='sdr'?'bt709':'p3d65')));
 return parts.join(' · ');
}
function pgAutomationRenderRecipeList(){
 const list=pgAutomationEl('RecipeList'),select=pgAutomationEl('RecipeSelect'),prior=select.value;
 select.innerHTML='<option value="">Choose a saved recipe…</option>'+pgAutomation.recipes.map((recipe,i)=>'<option value="'+i+'">'+pgAutomationEscape(recipe.name)+'</option>').join('');
 if(prior)select.value=prior;
 list.innerHTML=pgAutomation.recipes.length?pgAutomation.recipes.map((recipe,i)=>'<div class="auto-item"><span></span><div><strong>'+pgAutomationEscape(recipe.name)+'</strong>'+pgAutomationItemSummary(recipe)+'</div><div class="auto-actions"><button class="btn btn-sm btn-secondary" onclick="pgAutomationEditRecipe('+i+')">Edit</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDuplicateRecipe('+i+')">Duplicate</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationDeleteRecipe('+i+')">Delete</button></div></div>').join(''):'<div class="auto-empty">No recipes saved yet. Create one, or save a queue item as a recipe.</div>';
}
function pgAutomationEditRecipe(index){pgAutomationOpenEditor('recipe',pgAutomation.recipes[index]);}
function pgAutomationDuplicateRecipe(index){const copy=pgAutomationSnapshot(pgAutomation.recipes[index]);delete copy.id;copy.name+=' (copy)';pgAutomationOpenEditor('recipe',copy);}
async function pgAutomationDeleteRecipe(index){
 const recipe=pgAutomation.recipes[index];if(!recipe||!await pgAutomationConfirm('Delete saved recipe “'+recipe.name+'”? Queued copies remain.','Delete recipe'))return;
 try{await pgAutomationRequest('recipes/delete',{id:recipe.id});await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
function pgAutomationQueueAdd(){
 const value=pgAutomationValue('RecipeSelect','');if(value===''){pgAutomationNotice('Choose a saved recipe or use Add item.',true);return;}
 const recipe=pgAutomation.recipes[Number(value)];if(!recipe)return;
 // Record where the job came from so the drift badge can compare it against the
 // recipe later. source_recipe survives editing (pgAutomationSnapshot keeps
 // unknown keys, and pgAutomationRecipeFromForm assigns over the snapshot), and
 // is stripped again if the job is ever saved back as its own recipe. The id is
 // what pgAutomationDeleteRecipe uses, so it is stable; a recipe without one
 // cannot be looked up, so there is nothing to stamp.
 const item=pgAutomationSnapshot(recipe);
 if(recipe.id!=null)item.source_recipe=recipe.id;
 pgAutomation.queue.items.push(item);pgAutomationSaveDraft();pgAutomationRenderQueue();
}
function pgAutomationQueueLocked(index){
 if(!pgAutomation.editingRunId)return false;
 const run=pgAutomation.current?.run;
 const first=run?.id===pgAutomation.editingRunId?Math.max(pgAutomation.firstPending,Number(run.active_item??-1)+1):pgAutomation.firstPending;
 return index<first;
}
function pgAutomationQueueDirty(){return JSON.stringify(pgAutomation.queue)!==pgAutomation.loadedQueueSnapshot;}
function pgAutomationJobSummary(item){
 const signal=item.signal_format||'sdr',cal=item.calibration||{},stages=item.stages||{},steps=[];
 const enabled=key=>pgAutomationStageEnabled(stages,key);
 if(enabled('pre_readings'))steps.push('Before readings');
 if(enabled('calibration'))steps.push(signal==='dv'?'1D LUT + DV profile':signal==='hdr10'?'1D LUT + Matrix 3D LUT':'1D LUT + '+(cal.profile_source||cal.method||'Hybrid')+' 3D LUT');
 if(enabled('post_readings'))steps.push('After readings');
 return '<div class="auto-job-summary">'+pgAutomationEscape((signal==='dv'?'Dolby Vision':signal.toUpperCase())+' · '+pgAutomationModeLabel(item.picture_mode,signal))+'<br>'+pgAutomationEscape(steps.join(' → ')||'Settings only')+'</div>';
}
function pgAutomationFinishPolicyChanged(){
 if(pgAutomation.editingRunId)return;
 pgAutomation.queue.finish_policy=pgAutomationValue('FinishPolicy','restore-original')==='keep-last'?'keep-last':'restore-original';
 pgAutomationSaveDraft();pgAutomationRenderQueue();
}
function pgAutomationRenderQueue(){
 pgAutomationDragCancel?.();
 pgAutomation.queue.items.forEach(pgAutomationUpgradeReference);
 const finish=pgAutomationEl('FinishPolicy');if(finish){finish.value=pgAutomation.queue.finish_policy==='keep-last'?'keep-last':'restore-original';finish.disabled=!!pgAutomation.editingRunId;}
 pgAutomation.queue.name=pgAutomationQueueName(pgAutomation.queue.name);
 if(!pgAutomationEl('QueueDialog').open)pgAutomationEl('QueueName').value=pgAutomation.queue.name||'TV calibration queue';
 pgAutomationEl('QueueCount').textContent=pgAutomation.queue.items.length;
 const count=pgAutomation.queue.items.length,dirty=pgAutomationQueueDirty(),reference=pgAutomation.selectedQueue==='reference-settings';
 pgAutomationEl('JobsHeading').textContent=count+' job'+(count===1?'':'s')+' in '+(pgAutomation.queue.name||'New queue');
 pgAutomationEl('QueueSaveState').textContent=pgAutomation.editingRunId?'Editing pending jobs':reference?(dirty?'Reference copy · unsaved changes':'Reference settings · copy this queue to make your own'):pgAutomation.queue.id?(dirty?'Unsaved changes':'Saved queue'):'Not saved yet';
 const save=pgAutomationEl('SaveQueueButton');save.textContent=reference?'Copy queue':pgAutomation.queue.id?'Save changes':'Save queue';save.disabled=!!pgAutomation.editingRunId||(!reference&&!!pgAutomation.queue.id&&!dirty);
 pgAutomationRenderSavedQueues();
 pgAutomationEl('QueueContext').innerHTML=pgAutomation.editingRunId?'Editing pending items for '+pgAutomationEscape(pgAutomation.editingRunId)+'. Active and completed items are locked. <button class="btn btn-sm btn-secondary" id="pgAutomationStopEditingButton" type="button" style="margin:4px 0 8px" onclick="pgAutomationStopEditing()">Stop editing</button>':'';
 pgAutomationEl('SavePendingButton').style.display=pgAutomation.editingRunId?'':'none';
 pgAutomationEl('StartButton').style.display=pgAutomation.editingRunId?'none':'';
 pgAutomationEl('QueueItems').innerHTML=pgAutomation.queue.items.length?pgAutomation.queue.items.map((item,i)=>{
  const locked=pgAutomationQueueLocked(i);
  return '<div class="auto-item" data-queue-index="'+i+'"><div><span class="auto-number">'+(i+1)+'</span>'+(locked?'':'<button type="button" class="auto-reorder" aria-label="Reorder job '+(i+1)+': '+pgAutomationEscape(item.name)+'" title="Drag to reorder; arrow keys move up or down" onpointerdown="pgAutomationDragStart(event,'+i+')" onkeydown="pgAutomationReorderKey(event,'+i+')">⠿</button>')+'</div><div><strong>'+pgAutomationEscape(item.name||'Job '+(i+1))+'</strong>'+pgAutomationDriftBadge(item)+pgAutomationJobSummary(item)+'<details class="auto-job-details"><summary>Settings and targets</summary>'+pgAutomationItemSummary(item)+'</details></div><div class="auto-actions">'+(locked?'<span class="auto-muted">'+pgAutomationEscape(item.status||'Locked')+'</span>':'<button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueEdit('+i+')">Configure</button><details class="auto-menu"><summary aria-label="Actions for job '+(i+1)+'">More</summary><div class="auto-menu-panel"><button class="btn btn-sm btn-secondary" '+(i===0||pgAutomationQueueLocked(i-1)?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',-1)">Move up</button><button class="btn btn-sm btn-secondary" '+(i===pgAutomation.queue.items.length-1||pgAutomationQueueLocked(i+1)?'disabled ':'')+'onclick="pgAutomationQueueMove('+i+',1)">Move down</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueDuplicate('+i+')">Duplicate job</button><button class="btn btn-sm btn-secondary" onclick="pgAutomationQueueRemove('+i+')">Remove job</button></div></details>')+'</div></div>';
 }).join(''):'<div class="auto-empty"><strong>No jobs in this queue</strong><p class="auto-muted">Add a job below, or select another queue above to see its jobs.</p></div>';
}
function pgAutomationQueueEdit(index){if(!pgAutomationQueueLocked(index))pgAutomationOpenEditor('queue',pgAutomation.queue.items[index],index);}
function pgAutomationQueueDuplicate(index){const copy=pgAutomationSnapshot(pgAutomation.queue.items[index]);delete copy.id;copy.name+=' (copy)';pgAutomation.queue.items.splice(index+1,0,copy);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueRemove(index){if(pgAutomationQueueLocked(index))return;pgAutomation.queue.items.splice(index,1);pgAutomationSaveDraft();pgAutomationRenderQueue();}
function pgAutomationQueueMove(index,delta){
 const target=index+delta;
 if(!Number.isInteger(index)||!Number.isInteger(target)||index<0||index>=pgAutomation.queue.items.length||target<0||target>=pgAutomation.queue.items.length||index===target||pgAutomationQueueLocked(index)||pgAutomationQueueLocked(target))return;
 const item=pgAutomation.queue.items.splice(index,1)[0];pgAutomation.queue.items.splice(target,0,item);pgAutomationSaveDraft();pgAutomationRenderQueue();
 pgAutomationEl('ReorderStatus').textContent=item.name+' moved to job '+(target+1)+'. '+(pgAutomation.editingRunId?'Save Pending Changes to apply this order.':'Order saved in this draft.');
 return true;
}
function pgAutomationReorderKey(event,index){
 if(!['ArrowUp','ArrowDown'].includes(event.key))return;
 event.preventDefault();event.stopPropagation();const delta=event.key==='ArrowUp'?-1:1;
 if(pgAutomationQueueMove(index,delta))pgAutomationEl('QueueItems').querySelector('[data-queue-index="'+(index+delta)+'"] .auto-reorder')?.focus();
}
function pgAutomationDragStart(event,index){
 if(event.button!==0||pgAutomationQueueLocked(index))return;
 event.preventDefault();event.stopPropagation();pgAutomationDragCancel();
 const handle=event.currentTarget,queue=pgAutomation.queue,items=queue.items.slice(),row=handle.closest('[data-queue-index]');
 let slot=null,dragging=false;
 const clear=()=>pgAutomationEl('QueueItems').querySelectorAll('[data-drop]').forEach(el=>delete el.dataset.drop);
 const move=e=>{
  if(e.pointerId!==event.pointerId)return;
  if(!dragging&&Math.hypot(e.clientX-event.clientX,e.clientY-event.clientY)<5)return;
  dragging=true;row.classList.add('auto-dragging');clear();slot=null;
  const hit=document.elementFromPoint(e.clientX,e.clientY)?.closest('#pgAutomationQueueItems [data-queue-index]');
  if(hit){const target=Number(hit.dataset.queueIndex);if(!pgAutomationQueueLocked(target)){const after=e.clientY>hit.getBoundingClientRect().top+hit.getBoundingClientRect().height/2;slot=target+Number(after);hit.dataset.drop=after?'after':'before';}}
  if(e.clientY<70)window.scrollBy(0,-25);else if(e.clientY>innerHeight-70)window.scrollBy(0,25);
 };
 const cleanup=()=>{clear();row.classList.remove('auto-dragging');document.removeEventListener('pointermove',move);document.removeEventListener('pointerup',up);document.removeEventListener('pointercancel',cancel);document.removeEventListener('keydown',key);window.removeEventListener('blur',cleanup);if(handle.hasPointerCapture?.(event.pointerId))handle.releasePointerCapture(event.pointerId);pgAutomation.dragCancel=null;};
 const up=e=>{if(e.pointerId!==event.pointerId)return;const target=slot==null?null:slot-(slot>index?1:0);cleanup();if(dragging&&target!=null&&queue===pgAutomation.queue&&items.length===queue.items.length&&items.every((item,i)=>item===queue.items[i]))pgAutomationQueueMove(index,target-index);};
 const cancel=e=>{if(e.pointerId===event.pointerId)cleanup();};
 const key=e=>{if(e.key==='Escape'){e.preventDefault();cleanup();}};
 pgAutomation.dragCancel=cleanup;handle.setPointerCapture?.(event.pointerId);
 document.addEventListener('pointermove',move);document.addEventListener('pointerup',up);document.addEventListener('pointercancel',cancel);document.addEventListener('keydown',key);window.addEventListener('blur',cleanup);
}
function pgAutomationDragCancel(){pgAutomation.dragCancel?.();}
function pgAutomationNewQueue(){
 // Opens at once when nothing is being edited; callers fill the dialog next.
 if(!pgAutomation.editingRunId){pgAutomationNameQueue('new');return Promise.resolve();}
 return pgAutomationStopEditing().then(ok=>{if(ok)pgAutomationNameQueue('new');});
}
// The way out of editing a batch's pending jobs. The batch keeps the jobs it
// has saved; only this browser's unsaved pending changes are dropped, and the
// page starts over from an empty queue.
async function pgAutomationStopEditing(){
 const id=pgAutomation.editingRunId;if(!id)return true;
 if(!await pgAutomationConfirm('Stop editing the pending jobs of '+id+' and start an empty queue? Unsaved pending changes are discarded. The batch itself is not changed.','Stop editing'))return false;
 if(pgAutomation.editingRunId!==id)return true;
 pgAutomation.queue={name:'TV calibration queue',items:[]};
 pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.editChecked='';pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';
 pgAutomationSaveDraft();pgAutomationRenderSavedQueues();pgAutomationRenderQueue();
 pgAutomationNotice('Stopped editing '+id+'. The batch keeps its saved jobs; this queue is empty.');
 return true;
}
function pgAutomationSaveSelectedQueue(){if(pgAutomation.queue.id&&!pgAutomation.editingRunId)pgAutomationQueueSave();else pgAutomationNameQueue('copy');}
function pgAutomationNameQueue(action){
 if(pgAutomation.editingRunId){pgAutomationNotice('Save Pending Changes, or choose Stop editing, before copying or renaming a queue.',true);return;}
 pgAutomation.queueNameAction=action;
 pgAutomationEl('QueueMenu').open=false;
 pgAutomationEl('QueueDialogTitle').textContent=action==='new'?'New queue':action==='copy'?'Copy queue':'Rename queue';
 pgAutomationEl('QueueName').value=action==='new'?'':(pgAutomation.queue.name||'TV calibration queue')+(action==='copy'?' (copy)':'');
 pgAutomationEl('QueueDialogHelp').textContent=action==='new'?'Create a saved queue, then add its jobs.':action==='copy'?'Save an independent copy of all '+pgAutomation.queue.items.length+' jobs. The original queue stays unchanged.':'Change the name of this queue. Its jobs stay together.';
 pgAutomationEl('QueueDialogError').textContent='';pgAutomationOpenDialog(pgAutomationEl('QueueDialog'));pgAutomationEl('QueueName').focus();
}
async function pgAutomationSubmitQueueName(){
 const button=pgAutomationEl('QueueDialogSave'),name=pgAutomationValue('QueueName','').trim();if(!name||button.disabled)return;
 const action=pgAutomation.queueNameAction;
 if(action==='new'&&pgAutomation.queue.items.length&&pgAutomationQueueDirty()&&!await pgAutomationConfirm('Create a new queue and leave these unsaved changes? Save or copy this queue first to keep them.','Leave changes'))return;
 button.disabled=true;
 try{
  const queue=action==='new'?{name,items:[]}:pgAutomationClone(pgAutomation.queue);queue.name=name;
  if(action==='copy'||action==='new')delete queue.id;
  queue.items=queue.items.map(pgAutomationSnapshot);
  const result=await pgAutomationRequest('queues',{queue});
  pgAutomation.queue={...queue,id:result.queue.id};pgAutomation.selectedQueue='saved:'+result.queue.id;pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);pgAutomation.editingRunId='';pgAutomation.firstPending=0;
  pgAutomation.queues=pgAutomation.queues.filter(q=>q.id!==result.queue.id).concat([pgAutomationClone(pgAutomation.queue)]);
  pgAutomationCloseDialog(pgAutomationEl('QueueDialog'));pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationNotice('Queue saved');await pgAutomationRefresh();
 }catch(e){pgAutomationEl('QueueDialogError').textContent=e.message;}
 finally{button.disabled=false;}
}
async function pgAutomationQueueSave(){
 if(pgAutomation.queueSaving)return;pgAutomation.queueSaving=true;
 const source=pgAutomation.queue,queue=pgAutomationClone({...source,items:source.items.map(pgAutomationSnapshot)});
 try{
  const result=await pgAutomationRequest('queues',{queue});
  if(pgAutomation.queue===source){pgAutomation.queue.id=result.queue.id;pgAutomation.selectedQueue='saved:'+result.queue.id;pgAutomation.loadedQueueSnapshot=JSON.stringify({...queue,id:result.queue.id});pgAutomationSaveDraft();}
  pgAutomationNotice('Queue saved');await pgAutomationRefresh();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.queueSaving=false;}
}
function pgAutomationRenderSavedQueues(){
 const select=pgAutomationEl('SavedQueueSelect');
 const option=(key,name,count)=>{
  const current=key===pgAutomation.selectedQueue,dirty=current&&pgAutomationQueueDirty();
  return '<option value="'+pgAutomationEscape(key)+'">'+pgAutomationEscape(current?pgAutomation.queue.name||name:name)+' · '+(current?pgAutomation.queue.items.length:count)+' jobs'+(dirty?' · unsaved':'')+'</option>';
 };
 select.innerHTML=(!pgAutomation.selectedQueue?option('',pgAutomation.queue.name||'New queue',pgAutomation.queue.items.length):'')+option('reference-settings','Reference settings',6)+pgAutomation.queues.map(queue=>option('saved:'+queue.id,pgAutomationQueueName(queue.name),(queue.items||[]).length)).join('');
 if(pgAutomation.selectedQueue&&pgAutomation.selectedQueue!=='reference-settings'&&!pgAutomation.queues.some(queue=>'saved:'+queue.id===pgAutomation.selectedQueue))select.innerHTML=option('',pgAutomation.queue.name||'Unsaved queue',pgAutomation.queue.items.length)+select.innerHTML;
 select.value=pgAutomation.selectedQueue==='reference-settings'||pgAutomation.queues.some(queue=>'saved:'+queue.id===pgAutomation.selectedQueue)?pgAutomation.selectedQueue:'';
 pgAutomationQueueSelectionChanged();
}
function pgAutomationQueueSelectionChanged(load){
 let pending=null;
 if(load){
  if(pgAutomationValue('SavedQueueSelect',''))pending=pgAutomationLoadQueue();
  else{pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationSaveDraft();}
 }
 const value=pgAutomationValue('SavedQueueSelect',''),button=pgAutomationEl('DeleteQueueButton');
 if(button){
  button.disabled=value===''||value==='reference-settings';
  // A greyed control with no reason reads as "the queue cannot be cleared".
  // Say which of the two reasons applies, and where the other action lives.
  button.title=value===''?'This queue is not saved yet. Save it first, or remove jobs with the job’s More menu.'
   :value==='reference-settings'?'The built-in reference queue cannot be deleted.'
   :'Delete this saved queue.';
 }
 const reload=pgAutomationEl('ReloadQueueButton');if(reload)reload.disabled=value==='';
 return pending;
}
async function pgAutomationLoadQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=value==='reference-settings'?pgAutomationReferenceQueue():pgAutomation.queues.find(queue=>'saved:'+queue.id===value);if(!queue)return;
 const changed=pgAutomation.editingRunId||JSON.stringify(pgAutomation.queue)!==pgAutomation.loadedQueueSnapshot;
 if(pgAutomation.queue.items.length&&changed&&!await pgAutomationConfirm('Replace this draft with queue “'+pgAutomationQueueName(queue.name)+'”? Save your current queue first to keep its edits.','Replace draft')){
  pgAutomationEl('SavedQueueSelect').value=pgAutomation.selectedQueue;pgAutomationQueueSelectionChanged();return;
 }
 pgAutomation.queue=pgAutomationClone(queue);pgAutomation.queue.name=pgAutomationQueueName(pgAutomation.queue.name);pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.selectedQueue=value;pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationQueueSelectionChanged();
 pgAutomationNotice('Queue loaded. Configure, reorder or remove items before starting.');
}
async function pgAutomationDeleteQueue(){
 const value=pgAutomationValue('SavedQueueSelect',''),queue=pgAutomation.queues.find(queue=>'saved:'+queue.id===value);
 if(!queue||!await pgAutomationConfirm('Delete saved queue “'+pgAutomationQueueName(queue.name)+'”? Run history remains.','Delete queue'))return;
 try{await pgAutomationRequest('queues/delete',{id:queue.id});if(pgAutomation.queue.id===queue.id){delete pgAutomation.queue.id;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationSaveDraft();}await pgAutomationRefresh();}catch(e){pgAutomationNotice(e.message,true);}
}
// The colour stage is a 3D LUT profile on every signal except Dolby Vision,
// where it is a DV profile instead. Naming both on an SDR job reads as if the
// run had wandered into Dolby Vision, so the label follows the job's signal.
function pgAutomationStageSignal(signal){
 if(signal)return String(signal).toLowerCase();
 const run=pgAutomation.current?.run;
 const index=run&&run.active_item!=null?Number(run.active_item):null;
 const item=(index!=null&&Array.isArray(run.items))?run.items[index]:null;
 return String(item?.signal_format||'').toLowerCase();
}
function pgAutomationStageLabel(stage,signal){
 const dolbyVision=pgAutomationStageSignal(signal)==='dv';
 if(stage==='greyscale-settings-verified')return 'Checking TV settings after 1D calibration';
 if(stage==='volume-settings-verified')return dolbyVision?'Checking TV settings after the Dolby Vision profile upload':'Checking TV settings after the 3D LUT upload';
 if(stage==='volume-done')return dolbyVision?'Dolby Vision profiling':'3D LUT profiling';
 return {'queue-preflight':'Initial checks','readiness':'Checking TV and meter','job-readiness':'Selecting this job’s signal and picture mode','item-started':'Checking this job before measurements','tv-setup-verified':'Applying TV settings','pre-readings-done':'Before readings','reset-and-reapply-verified':'Resetting calibration and reapplying settings','panel-light-settled':'Setting 100% white luminance','greyscale-done':'Calibrating the 1D LUT','session-closed':'Closing calibration','apply-all-done':'Applying calibration to all inputs','post-readings-done':'After readings','item-complete':'Saving job results'}[stage]||String(stage||'').replace(/-/g,' ');
}
function pgAutomationIssueText(issue){
 const raw=typeof issue==='string'?issue:issue?.message||'';
 if(/Driver error while executing the command/i.test(raw))return 'The TV rejected a calibration command. Let cleanup finish, confirm the intended signal and picture mode, then retry readiness. If it repeats, reconnect the TV and include the saved command details in the report. The TV-side cause is not yet known.';
 if(typeof issue==='string'){
  const unverified=issue.match(/^([a-z][a-z0-9-]*)-unverified$/);
  return unverified?pgAutomationStageLabel(unverified[1])+': verification incomplete. See the job’s recorded checks for details.':issue;
 }
 let message=issue.message||issue.code||issue.name;
 if(/-key-/.test(issue.name||'')&&/is not supported by the LG TV/.test(message||''))message=message.replace(/ \(matrix:.*?\)/g,'').replace(/: .+?\. Configure/,'. Configure');
 const issueSignal=issue.signal_format||(issue.item_number!=null?(pgAutomation.current?.run?.items||[])[Number(issue.item_number)]?.signal_format:'');
 return (issue.item_number!=null?'Job '+(Number(issue.item_number)+1)+': ':'')+[pgAutomationStageLabel(issue.stage,issueSignal),message].filter(Boolean).join(' · ');
}
function pgAutomationFailureChecks(item,index){
 const checks=item?.failure?.stage==='job-readiness'?(item.readiness?.checks||[]).filter(check=>!check.ok&&check.level!=='warning'):[];
 return checks.length?checks.map(check=>({...check,item_number:index??check.item_number})):item?.failure?[{...item.failure,item_number:index}]:[];
}
function pgAutomationFailureHtml(run){
 const checks=(run?.items||[]).flatMap((item,index)=>pgAutomationFailureChecks(item,index));
 const issues=checks.length?checks:run?.failure?[run.failure]:[];
 if(checks.length&&run.failure&&!(run.items||[]).some(item=>item.failure?.stage===run.failure.stage&&item.failure?.message===run.failure.message))issues.push(run.failure);
 if(!issues.length)return '';
 return '<details open style="color:var(--red)"><summary>Problems requiring attention ('+issues.length+')</summary><ul class="auto-readiness-problems">'+issues.map(issue=>'<li>'+pgAutomationEscape(pgAutomationIssueText(issue))+'</li>').join('')+'</ul></details>'
  +'<details><summary>Technical details</summary><pre style="white-space:pre-wrap;overflow-wrap:anywhere">'+pgAutomationEscape(JSON.stringify({failure:run.failure,checks},null,2))+'</pre></details>';
}
function pgAutomationResuming(run){return run?.status==='starting'||(run?.status==='running'&&run.active_stage==='readiness');}
function pgAutomationTerminal(run){return /^(complete(-with-warnings)?|stopped|failed)$/.test(run?.status||'');}
function pgAutomationLogScroll(){
 const box=pgAutomationEl('Log');if(!box)return;
 if(!box.clientHeight)return; // Hidden workspaces cannot express scroll intent.
 pgAutomation.logFollow=box.scrollHeight-box.clientHeight-box.scrollTop<24;
 pgAutomationEl('LogFollowing').textContent=pgAutomation.logFollow?'Following latest':'Scroll paused';
}
function pgAutomationLogLatest(){
 pgAutomationEl('Activity').open=true;pgAutomation.logFollow=true;
 const box=pgAutomationEl('Log');box.scrollTop=box.scrollHeight;pgAutomationEl('LogFollowing').textContent='Following latest';
}
function pgAutomationRenderActivity(){
 const box=pgAutomationEl('Log');if(!box)return;
 const historical=pgAutomation.tab==='history'&&pgAutomation.historyActivity;
 const current=pgAutomation.current||{},pre=historical?null:pgAutomation.pendingChecks||current.preflight;
 const preActive=pre&&['checking','blocked','failed','interrupted'].includes(pre.status);
 const run=historical?.run||(preActive&&pgAutomationTerminal(current.run)?null:current.run);
 const scope=historical?'history:'+run.id:run?.id||pre?.id||'idle';
 if(pgAutomation.logScope!==scope){
  pgAutomation.logScope=scope;pgAutomation.logObserved=[];pgAutomation.logSignature=null;pgAutomation.logFollow=true;
  // Opening the log is a user choice. Polling, history selection and failed
  // readiness must not repeatedly expand it above the queue.
 }
 const activity=historical?historical.activity||{}:pgAutomation.pendingChecks&&current.preflight?.id!==pgAutomation.pendingChecks.id?{}:current.activity||{};
 const entries=[...(activity.entries||[])];
 if(!historical){
  // Runner/startup events are the durable source of progress. Only record
  // browser connection failures here; repeating sampled worker status hides
  // the useful events and creates a second, misleading event timestamp.
  const message=pgAutomation.statusError||'';
  const last=pgAutomation.logObserved[pgAutomation.logObserved.length-1];
  if(message&&last?.message!==message)pgAutomation.logObserved.push({time:Date.now()/1000,level:pgAutomation.statusError?'error':'info',message,source:'Observed in browser'});
  pgAutomation.logObserved=pgAutomation.logObserved.slice(-100);
  entries.push(...pgAutomation.logObserved,...pgAutomation.logNotices);
 }
 const timestamp=entry=>typeof entry.time==='number'?entry.time*1000:Date.parse(entry.time)||0;
 entries.sort((a,b)=>timestamp(a)-timestamp(b));
 const signature=JSON.stringify([scope,entries,activity.truncated]);if(signature===pgAutomation.logSignature){
  // First render can happen while the workspace is hidden (zero layout size).
  // Follow when it becomes visible, even if no new line has arrived yet.
  if(pgAutomation.logFollow&&box.clientHeight)box.scrollTop=box.scrollHeight;
  return;
 }
 pgAutomation.logSignature=signature;
 const top=box.scrollTop,follow=pgAutomation.logFollow;
 const rows=entries.slice(-500);
 box.innerHTML=rows.length?rows.map(entry=>'<div data-level="'+(['error','warning','note','ok'].includes(entry.level)?entry.level:'info')+'"><time>'+pgAutomationEscape(entry.time?pgAutomationFormatTime(typeof entry.time==='number'?entry.time*1000:entry.time):'Time not recorded')+'</time> · '+pgAutomationEscape(entry.source||'Activity')+(entry.item_number!=null?' · Job '+(Number(entry.item_number)+1):'')+' · '+pgAutomationEscape(entry.message)+'</div>').join(''):'No activity yet.';
 box.scrollTop=follow?box.scrollHeight:top;
 pgAutomationEl('LogCount').textContent='· '+rows.length+' entries';
 pgAutomationEl('LogContext').textContent=(historical?'History · ':'')+(run?.queue_name||pre?.queue_name||'Startup checks and batch output');
 pgAutomationEl('LogFollowing').textContent=follow?'Following latest':'Scroll paused';
 pgAutomationEl('LogLimit').textContent=activity.truncated||entries.length>500?'Showing recent output (up to 500 entries and the latest 64 KiB of runner output). Full runner log remains saved with the run.':'Saved startup checks and runner output survive refresh. Browser observations are kept only while this page is open.';
}
async function pgAutomationClearLastRun(){
 const run=pgAutomationCurrentRun();if(!pgAutomationTerminal(run))return;
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/control/clear',{});
  pgAutomation.lastProblem='';pgAutomationNotice(result.message);await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationDismissReadiness(button){
 const pre=pgAutomation.current?.preflight;
 if(!pre?.id||pgAutomation.pendingChecks||pre.status==='checking')return;
 if(button)button.disabled=true;
 try{
  const result=await pgAutomationRequest('readiness/dismiss',{request_id:pre.id});
  pgAutomation.dismissedCheck={id:result.dismissed,started_at:pre.started_at};
  if(pgAutomation.current?.preflight?.id===result.dismissed){
   pgAutomation.current.preflight=null;pgAutomation.lastProblem='';pgAutomationEl('Readiness').innerHTML='';pgAutomationNotice('');
   pgAutomationRenderLiveRun(pgAutomation.current.run,pgAutomation.current.execution);
   pgAutomationEl('ReadinessButton').focus();
  }
  await pgAutomationPollLive();
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{if(button)button.disabled=false;}
}
function pgAutomationEstimateModel(run,now){
 // Everything the progress card says about time, decided once. Ranges are in
 // seconds; the card rounds them so a display left on for hours stays calm.
 const model={state:'none',preflight:false,job:null,batch:null,pass:null,jobLabel:'this job left',jobPartial:false,batchPartial:false,note:''};
 if(!run||!['running','starting','stopping','completing','paused'].includes(run.status))return model;
 model.preflight=run.active_stage==='queue-preflight';
 if(model.preflight)model.jobLabel='checks left';
 if(run.status==='paused'){model.state='paused';return model;}
 if(run.status!=='running'){model.state='estimating';return model;}
 if(pgAutomation.statusError||pgAutomationHeartbeatAge(run)>60){model.state='unavailable';return model;}
 const eta=run.time_estimate,at=now??Date.now()/1000;
 if(!eta){model.state='estimating';return model;}
 if((!model.preflight&&Number(eta.active_item)!==Number(run.active_item))||eta.stage!==run.active_stage){model.state='estimating';return model;}
 const age=at-Number(eta.calculated_at),stale=!Number.isFinite(age)||age<0||age>180;
 const range=(value,countdown,key)=>{
  value=Number(value);
  if(!Number.isFinite(value)||value<=0)return null;
  // Only time the current stage consumes can count down between server
  // recalculations; work not yet started cannot consume the estimate.
  const elapsed=countdown?Math.min(age,Math.max(0,Number(eta.stage_remaining_seconds)||value)):0;
  const bounds=eta.ranges?.[key],low=Number(bounds?.low),high=Number(bounds?.high);
  const valid=bounds&&Number.isFinite(low)&&Number.isFinite(high)&&low>=0&&high>=low&&high>0;
  return {low:Math.max(60,(valid?low:value*.75)-elapsed),high:Math.max(60,(valid?high:value*1.5)-elapsed)};
 };
 if(eta.batch_unknown_stages!=null){
  if(stale){model.state='updating';return model;}
  const countdown=Number(eta.stage_remaining_seconds)>0;
  model.job=model.preflight?range(eta.stage_remaining_seconds,true,'stage'):range(eta.job_remaining_seconds,countdown,'job');
  model.jobPartial=!model.preflight&&eta.job_unknown_stages>0;
  model.batch=range(eta.batch_known_seconds,countdown,'batch');
  model.batchPartial=eta.batch_unknown_stages>0;
  model.pass=range(eta.pass_remaining_seconds,true,'pass');
  if(model.batch&&eta.batch_unknown_stages>0)model.note='Batch estimate covers '+eta.known_stages+' of '+eta.remaining_stages+' remaining stages';
  else if(eta.adaptive)model.note='Estimates adjusted to this run’s measured progress';
  else if(eta.seeded_history)model.note='Starting estimates use recorded calibration timings';
  else if(eta.approximate_history)model.note='Estimates use timings from similar jobs';
  model.state='ready';return model;
 }
 if(!['batch','stage','pass'].includes(eta.scope)){model.state='estimating';return model;}
 const seconds=Number(eta.remaining_seconds);
 if(stale||!Number.isFinite(seconds)||seconds<=0||seconds*1.5-age<=0){model.state='updating';return model;}
 const legacy={low:Math.max(60,seconds*.75-age),high:seconds*1.5-age};
 if(eta.scope==='batch')model.batch=legacy;else{model.job=legacy;model.jobLabel='this stage left';model.note='Batch estimate still learning';}
 model.state='ready';return model;
}
function pgAutomationEstimateRange(range){
 // Round the range outwards. Rounding its lower bound up could exclude a
 // finish the server correctly predicted (61 minutes became 1.5 hours).
 // A second of tolerance avoids flipping a rounded boundary during a render.
 if(!range)return '';
 const minutes=(value,upper)=>{let m=Math.max(1,(upper?Math.ceil:Math.floor)((value+(upper?0:1))/60));const step=m>=60?30:m>=10?5:1;return Math.max(1,(upper?Math.ceil:Math.floor)(m/step)*step);};
 const unit=m=>{if(m<60)return m+' min';const h=m/60;return (Number.isInteger(h)?h:h.toFixed(1))+' h';};
 const low=minutes(range.low,false),high=Math.max(minutes(range.high,true),low);
 if(unit(low)===unit(high))return unit(low);
 if(low<60&&high<60)return low+'–'+high+' min';
 if(low>=60&&high>=60)return unit(low).replace(' h','')+'–'+unit(high);
 return unit(low)+'–'+unit(high);
}
function pgAutomationEstimateText(run,now){
 const m=pgAutomationEstimateModel(run,now);
 if(m.state==='none')return '';
 if(m.state==='paused')return 'Time estimate paused';
 if(m.state==='unavailable')return 'Time estimate unavailable — waiting for live progress';
 if(m.state==='estimating')return 'Estimating time remaining…';
 if(m.state==='updating')return 'Updating time estimate…';
 const subject=m.preflight?'Initial checks':m.jobLabel==='this stage left'?'Current stage':'Current job';
 const parts=[subject+': '+(m.job?'about '+pgAutomationEstimateRange(m.job)+' left'+(m.jobPartial?' plus untimed stages':''):'estimating'),
  'Whole batch: '+(m.batch?'about '+pgAutomationEstimateRange(m.batch)+' left'+(m.batchPartial?' plus untimed stages':''):'estimating')];
 if(m.note)parts.push(m.note);
 return parts.join('. ')+'.';
}
function pgAutomationHeartbeatAge(run){
 return Number(run?.heartbeat_age||0)+Math.max(0,Date.now()/1000-(pgAutomation.receivedAt||Date.now()/1000));
}
function pgAutomationClock(seconds){
 // Whole minutes only. Seconds are noise on a job measured in hours, and a
 // value that changes once a minute never pulls the eye.
 seconds=Math.max(0,Math.floor(Number(seconds)||0));
 const h=Math.floor(seconds/3600),m=Math.floor(seconds%3600/60);
 return h?h+'h '+String(m).padStart(2,'0')+'m':m+'m';
}
function pgAutomationReadouts(run,pre,now){
 now=now??Date.now()/1000;
 const active=run&&['running','starting','stopping','completing'].includes(run.status);
 const end=run&&!active?(run.completed_at||run.heartbeat||now):!run&&pre?.status!=='checking'?(pre?.completed_at||pre?.updated_at||now):now;
 const start=run?.created_at||pre?.started_at;
 const model=pgAutomationEstimateModel(run,now);
 const slot=(value,label)=>({value,label});
 const pending={paused:', paused',updating:', updating',unavailable:', waiting for the runner'}[model.state]||', estimating';
 const jobLabel=!run&&pre?'checks left':model.jobLabel;
 const liveState=!active?'':pgAutomation.statusError?'lost':(pgAutomation.pollDelayed||pgAutomationHeartbeatAge(run)>60)?'delayed':'live';
 return {
  elapsed:slot(start?pgAutomationClock(end-start):'—','elapsed'),
  stage:slot(active&&run.stage_started_at?pgAutomationClock(now-run.stage_started_at):'—','this stage'),
  job:model.job?slot(pgAutomationEstimateRange(model.job),jobLabel+(model.jobPartial?', timed stages only':'')):slot('—',jobLabel+pending),
  // Untimed stages are unknown, not zero: a partial batch figure is a floor.
  batch:model.batch?slot(pgAutomationEstimateRange(model.batch),'whole batch left'+(model.batchPartial?', timed stages only':'')):slot('—','whole batch left'+pending),
  note:model.note,liveState,
  live:{live:'Live',delayed:'Updates delayed',lost:'Connection lost'}[liveState]||'',
 };
}
function pgAutomationReadoutsHtml(run,pre,completed,total,showRun){
 const r=pgAutomationReadouts(run,pre);
 const cell=(key,s)=>'<div class="auto-readout"><span class="auto-readout-value" data-automation-'+key+'>'+pgAutomationEscape(s.value)+'</span><span class="auto-readout-label" data-automation-'+key+'-label>'+pgAutomationEscape(s.label)+'</span></div>';
 return '<div class="auto-readouts" aria-live="off">'+cell('clock',r.elapsed)+cell('stage-clock',r.stage)
  +'<div class="auto-readouts-left" data-automation-eta>'+cell('eta-job',r.job)+cell('eta-batch',r.batch)+'</div></div>'
  +'<div class="auto-progress-status auto-muted"><span class="auto-live" data-automation-live data-state="'+r.liveState+'">'+pgAutomationEscape(r.live)+'</span>'
  +((showRun||pre)?'<span>'+completed+' of '+total+(run?.active_stage==='queue-preflight'||!showRun?' jobs checked':' jobs complete')+'</span>':'')+'<span data-automation-eta-note>'+pgAutomationEscape(r.note)+'</span></div>';
}
function pgAutomationProgressMeters(run,pre){
 const p=run?.progress;
 const checks=run?.active_stage==='queue-preflight'||(!run&&pre);
 // Older runner manifests report only the worker's patch counter.
 const worker=!p?.stage_total&&run?.worker_status?.total_steps?{stage_completed:run.worker_status.current_step||0,stage_total:run.worker_status.total_steps,unit:'patches'}:null;
 const done=Number(p?.stage_completed??worker?.stage_completed??pre?.progress_done??0),total=Number(p?.stage_total??worker?.stage_total??pre?.progress_total??0);
 const unit=p?.unit||worker?.unit||(checks?'checks':'steps');
 const label=checks?'Initial checks':pgAutomationStageLabel(run?.active_stage||'Preparing');
 const measured=Number.isFinite(total)&&total>0;
 const value=Math.max(0,Math.min(total,done));
 const held=(run&&['paused','interrupted','stopped','failed'].includes(run.status))||pgAutomation.statusError||(!run&&pre?.status!=='checking');
 // Name the held state from its own source: the run's status, a lost status
 // poll on a live run, or the preflight state when there is no run.
 const heldLabel=pgAutomation.statusError?'Status unavailable':run
  ?(({paused:'Paused',interrupted:'Interrupted',stopped:'Stopped',failed:'Failed'})[run.status]||'Paused')
  :(({blocked:'Blocked',failed:'Failed',interrupted:'Interrupted',ready:'Ready'})[pre?.status]||(pre?.status?String(pre.status).replace(/-/g,' ').replace(/^./,ch=>ch.toUpperCase()):'Paused'));
 let html='<div class="auto-progress-label"><span>'+pgAutomationEscape(label)+'</span><span>'+pgAutomationEscape(measured?value+' of '+total+' '+unit:held?heldLabel:'In progress')+'</span></div>'
  +'<progress aria-label="'+pgAutomationEscape(label)+'" '+(measured?'value="'+value+'" max="'+total+'"':held?'value="0" max="1"':'')+'></progress>';
 if(p?.total>0&&!run.preflight_only){
  const fraction=Math.max(0,Math.min(1,Number(p.completed)/Number(p.total)));
  html+='<div class="auto-progress-label auto-muted"><span>Whole queue</span><span>'+Math.floor(Number(p.completed))+' of '+Number(p.total)+' stages</span></div>'
   +'<progress class="auto-progress-overall" aria-label="Whole queue stages" value="'+fraction+'" max="1"></progress>';
 }
 return html;
}
function pgAutomationTickProgress(){
 // Runs every second but only writes what changed, which with whole-minute
 // clocks and rounded estimates is about once a minute.
 const box=pgAutomationEl('Progress');if(!box||!box.querySelector('[data-automation-clock]'))return;
 const run=pgAutomation.current?.run,pre=pgAutomation.pendingChecks||pgAutomation.current?.preflight;
 const r=pgAutomationReadouts(run,pre);
 const set=(selector,text)=>{const el=box.querySelector(selector);if(el&&el.textContent!==text)el.textContent=text;};
 set('[data-automation-clock]',r.elapsed.value);set('[data-automation-stage-clock]',r.stage.value);
 set('[data-automation-eta-job]',r.job.value);set('[data-automation-eta-job-label]',r.job.label);
 set('[data-automation-eta-batch]',r.batch.value);set('[data-automation-eta-batch-label]',r.batch.label);
 set('[data-automation-eta-note]',r.note);set('[data-automation-live]',r.live);
 const live=box.querySelector('[data-automation-live]');if(live&&live.dataset.state!==r.liveState)live.dataset.state=r.liveState;
}
function pgAutomationRunWarnings(run){
 return [...new Set([...(run?.warnings||[]).map(pgAutomationIssueText),...(run?.items||[]).flatMap((item,index)=>(item.warnings||[]).map(w=>pgAutomationIssueText({message:pgAutomationIssueText(w),item_number:index})))].filter(Boolean))];
}
function pgAutomationRunWarningsHtml(run){
 const warnings=pgAutomationRunWarnings(run);
 return warnings.length?'<details class="auto-run-warnings"><summary>'+warnings.length+' recorded warning'+(warnings.length===1?'':'s')+'</summary><ul>'+warnings.map(w=>'<li>'+pgAutomationEscape(w)+'</li>').join('')+'</ul></details>':'';
}
function pgAutomationRenderProgress(){
 const box=pgAutomationEl('Progress');if(!box)return;
 const run=pgAutomation.current?.run;
 const server=pgAutomation.current?.preflight;
 const pre=pgAutomation.pendingChecks&&server?.id!==pgAutomation.pendingChecks.id?pgAutomation.pendingChecks:server;
 const preActive=pre&&['checking','blocked','failed','interrupted'].includes(pre.status);
 const showRun=run&&(!preActive||['running','starting','stopping','completing','paused','interrupted'].includes(run.status));
 if(showRun&&pgAutomationTerminal(run)){
  box.style.display='';box.dataset.error=String(run.status==='failed'||!!pgAutomation.statusError);box.setAttribute('role',run.status==='failed'?'alert':'status');
  // "Last batch complete" for a readiness pass reads as a finished calibration
  // of that queue, which is how three checks in a row looked like a working
  // batch that produced nothing. Name what actually ran.
  // This box sits above the tab strip, so it is on screen from History and
  // Live Run too. Keep naming the Queue tab: "select Run queue" is not
  // actionable from a tab that does not show that button.
  box.innerHTML='<strong>'+(run.preflight_only?'Last readiness check ':'Last batch ')+pgAutomationEscape(run.status.replace(/-/g,' '))+' · '+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Calibration queue')+'</strong><p class="auto-muted">'+(run.preflight_only?'This checked the queue only — no calibration was performed. Return to Queue and select Run queue to calibrate.':'No calibration is running. Jobs and results are saved in History.')+'</p>'
   +(run.status==='failed'?pgAutomationFailureHtml(run):'')
   +(pgAutomation.statusError?'<p>'+pgAutomationEscape(pgAutomation.statusError)+'</p>':'')
   +pgAutomationRunWarningsHtml(run)
   +'<button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationClearLastRun()">'+(run.preflight_only?'Clear last check':'Clear last batch')+'</button>';
  return;
 }
 let title='',message='',issues=[],completed=0,total=0,error=false;
 if(showRun){
  const items=run.items||[],index=run.active_item==null?-1:Number(run.active_item);total=items.length;
  completed=items.filter(item=>/^complete(?:-with-warnings)?$/.test(item.status)).length;
  title=(index>=0?'Job '+(index+1)+' of '+total+': '+(items[index]?.name||''):(run.queue_name||'Queue'))+' · '+run.status;
  const runnerEntries=(pgAutomation.current?.activity?.entries||[]).filter(entry=>entry.source==='Runner');const latest=runnerEntries[runnerEntries.length-1];
  message=(run.status==='running'?run.operation_progress?.message:null)||(run.active_stage==='queue-preflight'?latest?.message:null)||run.worker_status?.message||latest?.message||run.worker_status?.current_name||pgAutomationStageLabel(run.active_stage);
  message=String(message).replace(/^Job \d+ \| /,'');
  if(run.active_stage==='queue-preflight'){
   title='Checking the whole queue'+(index>=0?' · Job '+(index+1)+' of '+total:'');
   const checked=run.preflight_result;
   total=checked?.total_items??total;
   completed=(checked?.jobs||[]).filter(item=>['checked','checked-limited'].includes(item.status)).length;
  }
  if(run.failure){
   error=true;
   // The runner saves the same stage failure on both the job and the run.
   // Attach its job context before deduplication, retaining separate causes.
   const itemFailure=items[index]?.failure;
   const sameFailure=itemFailure&&pgAutomationIssueText({...run.failure,item_number:null})===pgAutomationIssueText({...itemFailure,item_number:null});
   issues.push(sameFailure?{...run.failure,item_number:index}:run.failure);
  }
  items.forEach((item,i)=>{if(item.failure){if(pgAutomationResuming(run))issues.push({message:'Previous attempt: '+pgAutomationIssueText(item.failure),item_number:i});else{error=true;issues.push({...item.failure,item_number:i});}}(item.warnings||[]).forEach(w=>issues.push({message:pgAutomationIssueText(w),item_number:i,level:'warning'}));});
  error=error||['failed','interrupted'].includes(run.status);
  if(error&&!issues.length)issues.push({message:'Run '+run.status+'. Open Live Run or History for its saved checkpoints.'});
  if(run.heartbeat_age>60&&['running','starting','stopping','completing'].includes(run.status))issues.push({message:'No runner heartbeat for '+run.heartbeat_age+' seconds. Progress is unconfirmed; do not start a second run.'});
 }else if(pre){
  total=pre.total_items||0;completed=(pre.items||[]).filter(item=>['checked','checked-limited'].includes(item.status)).length;
  title=pre.status==='checking'?'Checking '+(pre.active_item==null?'TV and meter':'job '+(Number(pre.active_item)+1)+' of '+total):pre.status==='ready'?'Last readiness check passed':pre.status==='started'?'Launching calibration runner':'Last readiness check did not pass';
  const elapsed=pgAutomationPreflightElapsed(pre);
  message=(pre.queue_name?pre.queue_name+' · ':'')+(pre.message||'')+(elapsed!=null?' · '+elapsed+' s elapsed':'');
  issues=pre.issues||[];error=['blocked','failed','interrupted'].includes(pre.status)||issues.some(issue=>issue.level==='error');
 }else if(!pgAutomation.lastProblem&&!pgAutomation.statusError){box.style.display='none';return;}
 if(pgAutomation.statusError){error=true;issues=[{message:pgAutomation.statusError},...issues];}
 if(pgAutomation.lastProblem){error=true;issues=[{message:pgAutomation.lastProblem},...issues];}
 if(showRun&&!pgAutomationResuming(run)&&(run.items||[]).some(item=>item.failure?.stage==='job-readiness'&&item.readiness?.checks?.length)){
  const checks=(run.items||[]).flatMap((item,index)=>pgAutomationFailureChecks(item,index));
  if(checks.length)issues=[...checks,...issues.filter(issue=>issue.level==='warning')];
 }
 box.style.display='';box.dataset.error=String(error);box.setAttribute('role',error?'alert':'status');
 const unique=[...new Set(issues.map(pgAutomationIssueText).filter(Boolean))];
 box.innerHTML='<strong>'+pgAutomationEscape(title||(error?'Automation needs attention':'Automation'))+'</strong><div class="auto-muted">'+pgAutomationEscape(message)+'</div>'
  +((showRun||pre)?pgAutomationProgressMeters(showRun?run:null,pre)+pgAutomationReadoutsHtml(showRun?run:null,pre,completed,total,showRun):'')
  +(unique.length?'<details '+(error?'open':'')+'><summary>'+(error?'Problems requiring attention':'Warnings and manual checks')+' ('+unique.length+')</summary><div class="auto-issues">'+unique.map(text=>{const match=issues.find(issue=>pgAutomationIssueText(issue)===text);const level=match&&match.level==='warning'?pgAutomationCheckLevel({...match,ok:false}):'';return '<p class="auto-muted"'+(level?' data-level="'+level+'"':'')+'>'+pgAutomationEscape(text)+'</p>';}).join('')+'</div></details>':'')
  +(!showRun&&pre?.id&&['ready','blocked','failed','interrupted'].includes(pre.status)?'<p class="auto-muted">This is a saved check result, not an active calibration lock. After correcting the issue, check again or dismiss this result. Dismissing does not bypass future safety checks.</p><button id="pgAutomationDismissReadiness" type="button" class="btn btn-sm btn-secondary" onclick="pgAutomationDismissReadiness(this)">Dismiss previous check</button>':'');
}
function pgAutomationBeginChecks(intent){
 const id='ui-'+Date.now()+'-'+Math.random().toString(36).slice(2,10);
 pgAutomation.lastProblem='';pgAutomation.statusError='';pgAutomation.pollMisses=0;pgAutomation.pollDelayed=false;
 pgAutomation.pendingChecks={id,status:'checking',intent,started_at:Date.now()/1000,queue_name:pgAutomation.queue.name,total_items:pgAutomation.queue.items.length,message:'Waiting for the generator to begin startup checks. No calibration has started.',items:[]};
 pgAutomationRenderProgress();pgAutomationRenderActivity();pgAutomationPollLive();return id;
}
// A saved readiness result describes the queue it checked. The open queue may
// be a different or empty one, so name the mismatch instead of showing stale
// checks under it.
function pgAutomationReadinessQueueMatches(run){
 if(!run)return true;
 if(pgAutomation.editingRunId&&pgAutomation.editingRunId===run.id)return true;
 // Compare names the way the server stores them (blank becomes
 // "Automation item", then 120 characters), so a saved run matches its own
 // draft. An empty draft matches nothing: it cannot own a readiness result.
 const perlTrue=value=>value!=null&&value!==''&&String(value)!=='0';
 const label=item=>Array.from(String(perlTrue(item?.name)?item.name:perlTrue(item?.title)?item.title:'Automation item')).slice(0,120).join('');
 const mine=(pgAutomation.queue?.items||[]).map(label),theirs=(run.items||[]).map(label);
 return mine.length>0&&mine.length===theirs.length&&mine.every((name,i)=>name===theirs[i]);
}
// Three kinds of notice. An error needs fixing before calibration; a warning
// changed the outcome (a control that could not be verified, a mismatch); a
// note asks the operator to look at a TV menu the API does not expose. Only
// the first two deserve a colour, or six jobs' menu reminders paint the whole
// page orange.
function pgAutomationCheckLevel(check){
 if(!check||check.ok)return 'ok';
 if(check.level==='warning'&&/-(?:manual|panel-protection)$|-hazard-/.test(String(check.name||'')))return 'note';
 return check.level==='warning'?'warning':'error';
}
function pgAutomationRenderReadiness(result,run){
 const box=pgAutomationEl('Readiness');if(!result){box.textContent='Readiness request failed';return;}
 if(run&&!pgAutomationReadinessQueueMatches(run)){
  box.innerHTML='<p class="auto-muted" data-readiness-other-queue>The last readiness result belongs to “'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'another queue')+'” ('+(run.items||[]).length+' job'+((run.items||[]).length===1?'':'s')+'). Check Readiness again for this queue.</p>';
  return;
 }
 // The batch pass and a job's own pass can both report that job's manual
 // checks; list each distinct (job, outcome, message) once. The outcome is
 // part of the key so a passing duplicate can never hide a failing check.
 const seen=new Set();
 const checks=[...(result.checks||[])].filter(check=>{const key=String(check.item_number??'')+'|'+(check.ok?1:0)+'|'+String(check.level||'')+'|'+String(check.message||check.name||'');if(seen.has(key))return false;seen.add(key);return true;});
 // Grouped by job in queue order, equipment first, behind one disclosure:
 // the runner checks the last job first, so the raw order reads backwards,
 // and six jobs' manual notices as one flat list buried the verdict.
 const esc=pgAutomationEscape,names=result.jobs||run?.items||pgAutomation.queue?.items||[];
 const groups=new Map();
 for(const check of checks){const key=check.item_number==null||check.item_number===''?-1:Number(check.item_number);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(check);}
 const tally=list=>{const t={error:0,warning:0,note:0,ok:0};list.forEach(check=>{t[pgAutomationCheckLevel(check)]++;});return t;};
 const describe=t=>[t.error?t.error+' failed':null,t.warning?t.warning+' to check':null,t.note?t.note+' manual':null].filter(Boolean).join(' · ');
 const problems=checks.filter(check=>!check.ok),totals=tally(checks),errors=totals.error;
 const summary=[checks.length+' checks',describe(totals)].filter(Boolean).join(' · ');
 const line=check=>'<li data-level="'+pgAutomationCheckLevel(check)+'">'+esc(pgAutomationIssueText({...check,item_number:null,signal_format:check.signal_format||(check.item_number!=null?(run?.items||[])[Number(check.item_number)]?.signal_format:'')}))+'</li>';
 const group=key=>{
  const list=groups.get(key),bad=list.filter(check=>!check.ok),t=tally(list);
  const title=key<0?'Equipment and queue':'Job '+(key+1)+(names[key]?.name?' · '+names[key].name:'');
  return '<section class="auto-readiness-job"><h5>'+esc(title)+' <span class="auto-muted">'+(bad.length?describe(t):'passed')+(t.ok&&bad.length?' · '+t.ok+' passed':'')+'</span></h5>'
   +(bad.length?'<ul class="auto-readiness-problems">'+bad.map(line).join('')+'</ul>':'')+'</section>';
 };
 box.innerHTML='<p class="auto-muted">'+esc(result.message||'Readiness')+'</p>'
  +(problems.length
   ?'<details class="auto-readiness-details"'+(errors?' open':'')+'><summary>'+esc(summary)+'</summary>'+[...groups.keys()].sort((a,b)=>a-b).map(group).join('')+'</details>'
   :'<p class="auto-muted">'+checks.length+' checks passed.</p>');
 // Readiness is a saved result. Rendering it must never replace the live
 // activity payload supplied by runs/current (including runner events).
 if(result.scope!=='queue')box.scrollIntoView({block:'nearest'});
}
async function pgAutomationReadiness(){
 if(pgAutomation.pendingChecks||pgAutomation.busy||pgAutomation.current?.preflight?.status==='checking')return;
 if(!pgAutomation.queue.items.length){pgAutomationNotice('Add a job before checking readiness. No device checks were started.');return;}
 if(!await pgAutomationConfirm('Check every queued job? This temporarily switches generator signals and TV picture modes, then restores them. It does not reset calibration, upload LUTs or take measurements. A neutral grey pattern is left afterwards.','Check all jobs'))return;
 // The question can stay open for a while: re-check that nothing else started
 // and the queue still has jobs before switching any TV modes.
 if(pgAutomation.pendingChecks||pgAutomation.busy||pgAutomation.current?.preflight?.status==='checking')return;
 if(!pgAutomation.queue.items.length){pgAutomationNotice('Add a job before checking readiness. No device checks were started.');return;}
 const button=pgAutomationEl('ReadinessButton');button.disabled=true;button.textContent='Checking all jobs…';
 const request_id=pgAutomationBeginChecks('readiness');
 try{const result=await pgAutomationRequest('readiness',{scope:'queue',confirm_mode_switches:true,items:pgAutomation.queue.items,queue_name:pgAutomation.queue.name,request_id},300000);
  if(result.run_id){pgAutomationNotice('Whole-queue preflight started. No calibration will be performed.');await pgAutomationRefresh();pgAutomationTab('live');}
  else pgAutomationRenderReadiness(result);
 }catch(e){pgAutomationNotice(e.message,true);}
 finally{pgAutomation.pendingChecks=null;button.disabled=false;button.textContent='Check Readiness';await pgAutomationPollLive();}
}
async function pgAutomationStart(){
 if(pgAutomation.busy||pgAutomation.pendingChecks||pgAutomation.current?.preflight?.status==='checking')return;if(!pgAutomation.queue.items.length){pgAutomationNotice('Add a job before running the queue. No calibration was started.');return;}
 pgAutomation.busy=true;pgAutomationEl('StartButton').disabled=true;pgAutomationEl('StartButton').textContent='Checking and Starting…';
 pgAutomationSaveDraft();
 const request_id=pgAutomationBeginChecks('start');
 try{
  const result=await pgAutomationRequest('runs/start',{queue:pgAutomation.queue,request_id},300000);
  if(!result.run_id){pgAutomationRenderReadiness(result);throw new Error(result.message||'Batch did not start');}
  pgAutomationNotice('Runner started. Every queued job will be checked before calibration begins.');await pgAutomationRefresh();pgAutomationTab('live');
 }catch(e){pgAutomationNotice(e.message+' No new run is confirmed. Check the status above before retrying.',true);}
 finally{pgAutomation.pendingChecks=null;pgAutomation.busy=false;pgAutomationEl('StartButton').disabled=false;pgAutomationEl('StartButton').textContent='Run queue';await pgAutomationPollLive();}
}
function pgAutomationCurrentRun(){return pgAutomation.current?.run||null;}
async function pgAutomationControl(action){
 const run=pgAutomationCurrentRun();if(!run)return;
 try{const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/control/'+action,{},300000);if(result.ready===0){pgAutomationRenderReadiness(result);pgAutomationTab('queue');throw new Error(result.message);}if(result.run){pgAutomation.current={...pgAutomation.current,run:result.run};pgAutomationRenderLiveRun(result.run,pgAutomation.current.execution);}pgAutomationNotice(result.message);await pgAutomationPollLive();}catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationLoadActiveQueue(){
 const run=pgAutomationCurrentRun();if(!run){pgAutomationNotice('No active batch to edit.',true);return;}
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/edit');
  pgAutomation.queue={name:run.queue_name,items:result.items};pgAutomation.editingRunId=run.id;pgAutomation.firstPending=result.first_pending;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';pgAutomationRenderSavedQueues();
  pgAutomationSaveDraft();pgAutomationRenderQueue();pgAutomationTab('queue');
 }catch(e){pgAutomationNotice(e.message,true);}
}
async function pgAutomationEditActiveQueue(){
 if(!pgAutomation.editingRunId)return;
 try{
  const result=await pgAutomationRequest('runs/'+encodeURIComponent(pgAutomation.editingRunId)+'/edit',{first_pending:pgAutomation.firstPending,items:pgAutomation.queue.items.slice(pgAutomation.firstPending)});
  pgAutomationNotice(result.warning?'Pending changes saved. '+result.warning:'Pending changes saved',result.warning?'warning':false);await pgAutomationPollLive();
 }catch(e){
  pgAutomationNotice(e.message+' Reload pending items if the batch has advanced.',true);
  pgAutomation.editChecked='';await pgAutomationCheckEditBinding(pgAutomationCurrentRun());
 }
}
// Pending edits bind the saved draft to one run. Once that run ends or is
// deleted, the binding would hide Run queue for good, even across reloads.
// Mirrors webui_automation_active_status (pinned by t/automation_active_status_sync.t).
const PG_AUTOMATION_ACTIVE_STATUSES=['starting','running','paused','stopping','completing','interrupted'];
function pgAutomationReleaseEdit(reason){
 if(!pgAutomation.editingRunId)return;
 const ran=pgAutomation.firstPending;
 pgAutomation.queue={...pgAutomation.queue,name:pgAutomationQueueName(pgAutomation.queue.name),items:pgAutomation.queue.items.map(pgAutomationSnapshot)};
 pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.editChecked='';pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';
 pgAutomationSaveDraft();pgAutomationRenderSavedQueues();pgAutomationRenderQueue();
 pgAutomationNotice('The run these jobs belonged to '+reason+'; they are now an ordinary unsaved draft.'+(ran>0?' The first '+(ran===1?'job':ran+' jobs')+' already ran in that batch; remove '+(ran===1?'it':'them')+' if you do not want to run '+(ran===1?'it':'them')+' again.':'')+' Nothing has started.','warning');
}
// Checks the run the draft is bound to. Only a definite answer releases it;
// a failed or slow request keeps the binding and retries on the next poll.
async function pgAutomationCheckEditBinding(current){
 const id=pgAutomation.editingRunId;
 if(!id||pgAutomation.editChecking===id)return;
 if(current?.id===id){
  if(!PG_AUTOMATION_ACTIVE_STATUSES.includes(current.status))pgAutomationReleaseEdit('has ended ('+String(current.status||'finished').replace(/-/g,' ')+')');
  return;
 }
 // A run that is not current cannot advance, so one confirmed answer holds.
 if(pgAutomation.editChecked===id)return;
 pgAutomation.editChecking=id;
 try{
  // fetchJSON resolves null on failure or timeout; neither branch below matches, so the binding stays.
  const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(id),{_quiet:true,_timeoutMs:30000});
  if(pgAutomation.editingRunId!==id)return;
  if(result?.run){
   if(PG_AUTOMATION_ACTIVE_STATUSES.includes(result.run.status))pgAutomation.editChecked=id;
   else pgAutomationReleaseEdit('has ended ('+String(result.run.status||'finished').replace(/-/g,' ')+')');
  }else if(result?.error_code==='not-found')pgAutomationReleaseEdit('no longer exists on the generator');
 }catch(e){}
 finally{if(pgAutomation.editChecking===id)pgAutomation.editChecking='';}
}
function pgAutomationRenderLiveRun(run,execution){
 pgAutomationSyncCalibrationView(run);
 pgAutomationRenderActivity();
 const pre=pgAutomation.current?.preflight,checking=pgAutomation.pendingChecks||pre?.status==='checking';
 const status=run?.status||(checking?'checking':'idle');pgAutomationStateBadge(status);pgAutomationRenderProgress();
 if(pgAutomation.noticeLevel==='info'){
  // An info notice describes one moment. It stays while the run is in the
  // state it was raised in (at least 5 s), clears on the next status change,
  // and expires after 2 min on a parked or idle run. It remains in the log.
  const age=Date.now()-(pgAutomation.noticeAt||0);
  if(pgAutomation.noticeRunStatus==null)pgAutomation.noticeRunStatus=status;
  else if((pgAutomation.noticeRunStatus!==status&&age>5000)||(age>120000&&['idle','paused','interrupted','stopped','failed','complete','complete-with-warnings'].includes(status)))pgAutomationNotice('');
 }
 const occupied=checking||run?.cleanup_required||['starting','running','paused','interrupted','stopping','completing'].includes(run?.status);
 pgAutomationEl('StartButton').disabled=!!(occupied||pgAutomation.busy);
 pgAutomationEl('ReadinessButton').disabled=!!(occupied||pgAutomation.pendingChecks);
 const reason=run?.cleanup_required?'Cleanup is still required. Open Live Run and use Retry cleanup.':checking?'Readiness checks are in progress.':occupied?'The previous batch is '+run.status+'. Open Live Run to resume it or Stop it before starting a new queue.':pgAutomation.busy?'A start request is in progress.':'';
 // A blocker reason wins while set; when it clears, fall back to the standing
 // explanation of what each action does rather than leaving the title empty.
 const actionTitle={StartButton:'Rechecks every job, then calibrates.',ReadinessButton:'Checks the queue only. Does not calibrate.'};
 for(const id of ['StartButton','ReadinessButton'])pgAutomationEl(id).title=reason||actionTitle[id];
 const blocker=pgAutomationEl('ActionBlocker');
 if(blocker){blocker.hidden=!reason;blocker.innerHTML=pgAutomationEscape(reason)+(occupied&&!checking?' <button type="button" class="btn btn-sm btn-secondary" onclick="pgAutomationTab(\'live\')">Open Live Run</button>':'');}
 pgAutomationEl('PauseButton').disabled=status!=='running'||run?.preflight_only||run?.active_stage==='queue-preflight';pgAutomationEl('ResumeButton').disabled=!!run?.preflight_only||!!run?.cleanup_required||!['paused','interrupted'].includes(status);
 pgAutomationEl('ResumeButton').title=run?.cleanup_required?'Retry cleanup before resuming.':'';
 pgAutomationEl('StopButton').disabled=!run?.cleanup_required&&!['starting','running','paused','interrupted','stopping','completing'].includes(status);
 pgAutomationEl('StopButton').textContent=run?.cleanup_required?'Retry cleanup':'Stop';
 const live=pgAutomationEl('Live');
 // The run carries the verdict; the check list is in the saved preflight
 // status the same poll delivers for this run.
 if(run?.preflight_result){const pre=pgAutomation.current?.preflight;pgAutomationRenderReadiness({...run.preflight_result,checks:run.preflight_result.checks||(pre&&pre.run_id===run.id?pre.checks:null)||[]},run);}
 if(!run){live.innerHTML='<div class="auto-empty">'+(checking?'Checking the whole queue against the connected TV before calibration. Signal and picture modes are temporarily switched and restored.':pre&&['blocked','failed','interrupted'].includes(pre.status)?'Calibration has not started. Resolve the startup problems shown above, then retry.':'No active batch. Completed and stopped runs are in History.')+'</div>';pgAutomationEl('LiveDetail').innerHTML='';delete pgAutomation.jobViews.live;return;}
 const terminal=pgAutomationTerminal(run),active=run.active_item!=null?Number(run.active_item):-1,items=run.items||[],worker=terminal?{}:{...(run.worker_status||{}),message:(run.status==='running'?run.operation_progress?.message:null)||run.worker_status?.message};
 if(terminal){
  live.innerHTML='<h3>'+(run.preflight_only?'Last readiness check · ':'Last batch · ')+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Batch')+'</h3><p class="auto-muted">'+pgAutomationEscape(status.replace(/-/g,' '))+' · Nothing is running. Results remain available below and in History.</p>'
   +pgAutomationRunWarningsHtml(run)
   +pgAutomationBatchSummary(run)
   +items.map((item,i)=>pgAutomationJobButton(item,i,'live',run.id,false)).join('');
  if(pgAutomation.tab==='live')pgAutomationSyncLiveDetail(run);return;
 }
  live.innerHTML='<h3>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Batch')+' · '+pgAutomationEscape(status)+'</h3>'
  +'<p class="auto-muted">'+(active>=0?'Job '+(active+1)+' of '+items.length+' · ':'')+pgAutomationEscape(pgAutomationStageLabel(run.active_stage||'Between stages'))+'</p>'
  +'<p>'+pgAutomationEscape(worker.current_name||worker.message||'')+(worker.total_steps?' · '+Number(worker.current_step||0)+' / '+Number(worker.total_steps):'')+'</p>'
  +pgAutomationFailureHtml(run)
  +(['starting','running','completing','stopping'].includes(status)&&run.heartbeat_age!=null&&run.heartbeat_age>60?'<p style="color:var(--orange)">No heartbeat for '+Number(run.heartbeat_age)+' s. If the runner has stopped, the next status check marks this run interrupted.</p>':'')
  +'<p class="auto-muted">Saved checkpoint: '+pgAutomationEscape(run.checkpoint||'none')+' · Heartbeat '+pgAutomationEscape(run.heartbeat_age==null?'pending':run.heartbeat_age+'s ago')+'</p>'
  +pgAutomationBatchSummary(run)
  +items.map((item,i)=>pgAutomationJobButton(item,i,'live',run.id,i===active)).join('');
 if(pgAutomation.tab==='live')pgAutomationSyncLiveDetail(run);
}
// One slow or failed poll is a delay, not a lost connection: the appliance
// answers slowly while a calibration worker has its CPU. "Connection lost"
// waits for three misses in a row, about a minute at the live cadence.
const PG_AUTOMATION_POLL_TIMEOUT_MS=20000,PG_AUTOMATION_POLL_LOST_AFTER=3,PG_AUTOMATION_LOG_LINES=300;
// 18 Sep 2026: every 2 s poll resent the same 78 KB of startup checks and
// 81 KB of activity. The poll now names the check revision and the activity
// cursor it already holds; the reply omits an unchanged check list and sends
// only the runner lines appended since. The merged result keeps the shapes
// the rest of the page reads (activity.entries, .truncated, .run_id, preflight).
function pgAutomationPollQuery(previous){
 const params=[];
 if(previous?.preflight?.rev)params.push('preflight_rev='+encodeURIComponent(previous.preflight.rev));
 if(previous?.activity?.cursor)params.push('activity_after='+encodeURIComponent(previous.activity.cursor));
 return params.length?'?'+params.join('&'):'';
}
// How long a startup check has run. A finished check says so itself; one
// still running is not resent for its elapsed time alone, so the daemon's
// figure from the poll the block arrived in is advanced by the time since.
// The daemon's clock is not this page's (the appliance has no real-time
// clock), so started_at is never compared with Date.now().
function pgAutomationPreflightElapsed(pre){
 if(!pre||typeof pre!=='object')return null;
 if(pre.completed_at!=null&&pre.started_at!=null)return Math.max(0,Math.floor(Number(pre.completed_at)-Number(pre.started_at)));
 if(pre.elapsed_seconds==null)return null;
 const since=pre.received_at?Math.max(0,Date.now()/1000-pre.received_at):0;
 return Math.floor(Number(pre.elapsed_seconds)+since);
}
// A partial feed carries only new runner lines; append them to the entries
// already held and cap the log lines the way a full read does: the entries
// that are not from the log (head) come first and are kept whole.
function pgAutomationMergeActivity(previous,incoming){
 if(!incoming||typeof incoming!=='object'||!incoming.partial)return incoming;
 const entries=[...(Array.isArray(previous?.entries)?previous.entries:[]),...(Array.isArray(incoming.entries)?incoming.entries:[])];
 const head=Math.max(0,Number(incoming.head)||0),excess=entries.length-head-PG_AUTOMATION_LOG_LINES;
 let truncated=!!(previous?.truncated||incoming.truncated);
 if(excess>0){entries.splice(head,excess);truncated=true;}
 const merged={...incoming,entries,truncated};
 delete merged.partial;
 return merged;
}
function pgAutomationPollMissed(message){
 pgAutomation.pollMisses=(pgAutomation.pollMisses||0)+1;
 pgAutomation.pollDelayed=true;
 if(pgAutomation.pollMisses>=PG_AUTOMATION_POLL_LOST_AFTER)pgAutomation.statusError=message;
 pgAutomationRenderProgress();
}
async function pgAutomationPollLive(){
 if(pgAutomation.polling)return;pgAutomation.polling=true;
 try{
  const previous=pgAutomation.current;
  const result=await fetchJSON('/api/automation/runs/current'+pgAutomationPollQuery(previous),{_quiet:true,_timeoutMs:PG_AUTOMATION_POLL_TIMEOUT_MS});
  if(result&&result.status!=='error'){
   if(result.preflight_unchanged&&previous?.preflight&&!('preflight' in result))result.preflight=previous.preflight;
   else if(result.preflight&&typeof result.preflight==='object')result.preflight.received_at=Date.now()/1000;
   result.activity=pgAutomationMergeActivity(previous?.activity,result.activity);
   if(pgAutomation.dismissedCheck&&result.preflight?.id===pgAutomation.dismissedCheck.id&&result.preflight?.started_at===pgAutomation.dismissedCheck.started_at&&result.preflight?.status!=='checking')result.preflight=null;
   if(pgAutomation.current?.preflight?.id&&!result.preflight&&!pgAutomation.pendingChecks)pgAutomationEl('Readiness').innerHTML='';
   pgAutomation.pollMisses=0;pgAutomation.pollDelayed=false;
   pgAutomation.statusError='';pgAutomation.receivedAt=Date.now()/1000;pgAutomation.current=result;pgAutomationRenderLiveRun(result.run,result.execution);
   pgAutomationSyncLiveMark();
   if(pgAutomation.editingRunId)pgAutomationCheckEditBinding(result.run);
  }
  else pgAutomationPollMissed('Cannot refresh run status. Showing the last known state; progress is unconfirmed. Do not start another run.');
 }catch(e){pgAutomationPollMissed('Run status connection failed: '+e.message+'. Showing the last known state.');
 }finally{
  // Release the guard before rendering: an unexpected presentation error
  // must not permanently stop polling. Always schedule the next attempt.
  pgAutomation.polling=false;
  try{pgAutomationRenderActivity();pgAutomationSyncCalibrationView(pgAutomation.current?.run);}
  catch(e){pgAutomation.statusError='Display update failed: '+e.message;}
  if(pgAutomation.liveTimer)clearTimeout(pgAutomation.liveTimer);
  // Poll fast while a runner should be alive or the Live tab is showing;
  // otherwise a slow poll keeps the header badge honest about a batch started
  // from another browser (and gives the daemon its dead-runner check).
  const status=pgAutomation.current?.run?.status||'';
  const fast=pgAutomation.pendingChecks||pgAutomation.current?.preflight?.status==='checking'||pgAutomation.tab==='live'||['starting','running','completing','stopping'].includes(status);
  pgAutomation.liveTimer=setTimeout(()=>{pgAutomation.liveTimer=null;pgAutomationPollLive();},fast?2000:30000);
 }
}
// History titles say what a run did, not just which queue it came from: most
// runs share a queue name. The row carries a brief of its jobs; the per-job
// detail is fetched from the listing cache when the row is expanded.
function pgAutomationHistorySummary(run,index){
 const title=pgAutomationHistoryTitle(run);
 return '<div class="auto-history-row" data-run-id="'+pgAutomationEscape(run.id)+'"><div><strong title="'+pgAutomationEscape(title)+'">'+pgAutomationEscape(title)+'</strong><small>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Automation queue')+' · '+pgAutomationEscape(run.id||'')+'</small>'+(run.preflight_only?'<p class="auto-muted">Readiness check · no calibration performed</p>':'')+(run.status==='complete-with-warnings'?'<p class="auto-warning-note">Completed with warnings. Open the run for details.</p>':'')+(run.failure?'<p style="color:var(--red)">'+pgAutomationEscape(pgAutomationIssueText(run.failure))+'</p>':'')
  +'<details class="auto-history-details" ontoggle="pgAutomationHistoryDetails(this,'+index+')"><summary>Job details</summary><div class="auto-history-jobs" aria-live="polite"></div></details>'
  +'</div><div class="auto-actions"><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationOpenHistory('+index+')">Open</button><button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationDeleteRun('+index+')">Delete</button></div></div>';
}
function pgAutomationHistoryWhen(run){
 const date=new Date(run.created_at_iso||(run.created_at?run.created_at*1000:NaN));
 return Number.isNaN(date.getTime())?'':date.toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
}
function pgAutomationHistoryTitle(run){
 const brief=run.digest||{},names=Array.isArray(brief.job_names)?brief.job_names:[],count=brief.job_count||names.length;
 let jobs=count>1?count+' jobs: '+names.join(', ')+(count>names.length?', …':''):names[0]||pgAutomationQueueName(run.queue_name)||'Automation queue';
 const single=count===1&&!run.preflight_only,luts=[brief.lut_1d?'1D':'',brief.lut_3d?'3D':''].filter(Boolean).join(' + ');
 if(single&&luts)jobs+=' ('+luts+')';
 // A one-job run reports how its job ended, which can be warnings under "complete".
 return [pgAutomationHistoryWhen(run),run.preflight_only?'Readiness check':'',jobs,((single&&brief.status)||run.status||'').replace(/-/g,' '),
  single&&Number.isFinite(brief.de)?(PG_AUTOMATION_LABELS[brief.formula]||'ΔE')+' '+brief.de.toFixed(2):''].filter(Boolean).join(' · ');
}
function pgAutomationHistoryJobHtml(job){
 const yes=value=>value?'yes':'no',lines=[];
 lines.push([{sdr:'SDR',hdr10:'HDR10',hlg:'HLG',dv:'Dolby Vision'}[job.signal]||job.signal||'Signal unknown',job.picture_mode,job.tv_input?job.tv_input.toUpperCase():''].filter(Boolean).join(' · '));
 lines.push('Stages: '+((job.stages||[]).map(stage=>stage.replace(/_/g,' ')).join(', ')||'none'));
 lines.push('Outcome: '+String(job.status||'').replace(/-/g,' '));
 lines.push('Greyscale: '+(Number.isFinite(job.de)?(PG_AUTOMATION_LABELS[job.formula]||'ΔE')+' '+job.de.toFixed(2)+' (final)':'no result')+' · 1D LUT uploaded: '+yes(job.lut_1d));
 lines.push('3D LUT uploaded: '+yes(job.lut_3d)+(Number.isFinite(job.peak_nits)?' · Peak '+Math.round(job.peak_nits)+' cd/m²':''));
 lines.push('Post-readings: '+(job.post_readings?job.post_readings+' saved':'none'));
 const artifacts=(job.artifacts||[]).map(a=>'<li><button class="btn btn-sm btn-secondary" type="button" data-artifact-id="'+pgAutomationEscape(a.id)+'" onclick="pgAutomationShowArtifact(this.dataset.artifactId)">'+pgAutomationEscape((a.type==='3d'?'3D LUT':'1D LUT')+(a.variant?' ('+a.variant+')':''))+'</button> <code>'+pgAutomationEscape(a.id)+'</code>'+(a.inferred?' <span class="auto-muted">matched by time and picture mode</span>':'')+'</li>').join('');
 return '<div class="auto-history-job"><strong>'+pgAutomationEscape(job.name||'Job')+'</strong><ul>'+lines.map(line=>'<li>'+pgAutomationEscape(line)+'</li>').join('')
  +'<li>Saved to LG Calibration History: '+(artifacts?'<ul>'+artifacts+'</ul>':'nothing')+'</li></ul></div>';
}
async function pgAutomationHistoryDetails(details,index){
 const run=pgAutomation.history[index],target=details.querySelector('.auto-history-jobs');
 if(!details.open||!run||!target||details.dataset.loaded===run.id)return;
 // A run in progress keeps its status while its jobs gain results, so only
 // a finished run's digest is reused.
 const cache=pgAutomation.historyDigests=pgAutomation.historyDigests||{},key=run.id+'|'+run.status;
 if(['starting','running','completing','stopping','paused'].includes(run.status))delete cache[key];
 if(!cache[key])target.textContent='Loading job details…';
 const result=cache[key]||await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/digest',{_quiet:true,_timeoutMs:30000});
 if(!result||!Array.isArray(result.jobs)){target.textContent=(result&&result.message)||'Unable to load job details.';return;}
 cache[key]=result;details.dataset.loaded=run.id;
 target.innerHTML=result.jobs.length?result.jobs.map(pgAutomationHistoryJobHtml).join(''):'No jobs were saved with this run.';
}
// Opens LG Calibration History at the entry a run produced.
async function pgAutomationShowArtifact(id){
 if(typeof lgOpenCalHistoryModal!=='function'){pgAutomationNotice('LG Calibration History is not available on this page',true);return;}
 lgOpenCalHistoryModal();
 if(typeof lgRefreshCalHistory==='function')await lgRefreshCalHistory();
 const entry=[...document.querySelectorAll('#lgCalHistoryModal [data-id]')].find(el=>el.dataset.id===id);
 if(!entry){pgAutomationNotice('That calibration is no longer in LG Calibration History',true);return;}
 entry.classList.add('lg-cal-hist-highlight');entry.tabIndex=-1;entry.scrollIntoView({block:'center'});entry.focus();
}

function pgAutomationRenderHistoryList(){
 const el=document.getElementById('pgAutomationHistoryList');
 if(!el)return;
 // A refresh rebuilds every row; reopen the job details the user had open.
 const open=new Set([...el.querySelectorAll('.auto-history-row')].filter(row=>row.querySelector('.auto-history-details')?.open).map(row=>row.dataset.runId));
 el.innerHTML=(pgAutomation.historyError?'<p role="alert">'+pgAutomationEscape(pgAutomation.historyError)+' <button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationRefresh()">Retry</button></p>':'')
  +(pgAutomation.history.length?pgAutomation.history.map(pgAutomationHistorySummary).join(''):pgAutomation.historyError?'':'No automation history.');
 el.querySelectorAll('.auto-history-row').forEach(row=>{if(open.has(row.dataset.runId))row.querySelector('.auto-history-details').open=true;});
}

async function pgAutomationOpenHistory(index){
 const summary=pgAutomation.history[index];
 if(!summary)return;
 const request=pgAutomation.historyRequest=(pgAutomation.historyRequest||0)+1;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(summary.id),{_quiet:true,_timeoutMs:30000});
 if(request!==pgAutomation.historyRequest)return;
 const run=result&&result.run;
 if(!run){pgAutomationNotice((result&&result.message)||'Unable to load automation history',true);return;}
 pgAutomation.currentHistoryRunId=run.id||summary.id||'';
 pgAutomation.historyActivity={run,activity:result.activity||{}};pgAutomationRenderActivity();
 const detail=document.getElementById('pgAutomationHistoryDetail');
 if(!detail)return;
 delete pgAutomation.jobViews.history;
 detail.innerHTML='<h3>'+pgAutomationEscape(pgAutomationQueueName(run.queue_name)||'Automation queue')+' · '+pgAutomationEscape((run.status||'').replace(/-/g,' '))+'</h3>'
  +pgAutomationRunWarningsHtml(run)
  +pgAutomationFailureHtml(run)
  +'<button class="btn btn-sm btn-secondary" type="button" onclick="pgAutomationRecoverQueue()">Copy this run to an editable queue</button><p class="auto-muted">Recovers the jobs saved on the Pi, including failed runs. Does not resume or start calibration.</p>'
  +(Array.isArray(run.hazard_restore_unverified)&&run.hazard_restore_unverified.length?'<div style="color:var(--orange);margin-bottom:8px" data-hazard-unverified>TV protections sent but not confirmed (this TV cannot read them back): '+pgAutomationEscape(run.hazard_restore_unverified.map(x=>(x&&x.key)||String(x)).join(', '))+'. Check them in the TV menu.</div>':'')
  +(Array.isArray(run.hazard_restore_failures)&&run.hazard_restore_failures.length?'<div style="color:var(--red);margin-bottom:8px">TV protections were not restored: '+pgAutomationEscape(run.hazard_restore_failures.map(x=>typeof x==='string'?x:(x.key||'')+(x.message?' ('+x.message+')':'')).join(', '))+'. Check the TV\'s energy saving, screen saver and power-off settings.</div>':'')
  +'<div class="auto-job-layout"><div id="pgAutomationHistoryJobs">'+pgAutomationBatchSummary(run)+(run.items||[]).map((item,i)=>pgAutomationJobButton(item,i,'history',run.id,false)).join('')+'</div><aside id="pgAutomationHistoryJobDetail" class="auto-job-detail" aria-label="Selected historical job details"></aside></div>';
 // The detail renders below the full history list; bring it into view so
 // the click visibly does something.
 detail.style.scrollMarginTop='calc(var(--pg-header-height, 61px) + 12px)'; // clear the sticky header at any width
 detail.scrollIntoView({block:'start'});
 if(run.items?.length)pgAutomationSelectJob('history',run.id,0);
}
async function pgAutomationRecoverQueue(){
 const run=pgAutomation.historyActivity?.run;if(!Array.isArray(run?.items)||!run.items.length)return;
 if(pgAutomation.queue.items.length&&!await pgAutomationConfirm('Replace the current draft with a copy of this run? Save your draft first if you want to keep it.','Replace draft'))return;
 const before=JSON.stringify(pgAutomation.queue);
 let result;
 try{result=await pgAutomationRequest('runs/'+encodeURIComponent(run.id)+'/queue');if(!Array.isArray(result.queue?.items))throw new Error('Saved queue is unavailable.');if(before!==JSON.stringify(pgAutomation.queue))throw new Error('Your draft changed while loading. Retry recovery to replace it.');}
 catch(e){pgAutomationNotice(e.message,true);return;}
 pgAutomation.queue={name:pgAutomationQueueName(result.queue.name)||'Recovered queue',finish_policy:result.queue.finish_policy||'restore-original',items:result.queue.items.map(pgAutomationSnapshot)};
 pgAutomation.editingRunId='';pgAutomation.firstPending=0;pgAutomation.selectedQueue='';pgAutomation.loadedQueueSnapshot='';
 pgAutomationSaveDraft();pgAutomationRenderSavedQueues();pgAutomationRenderQueue();pgAutomationTab('queue');
 pgAutomationNotice('Jobs recovered from the Pi. Review and Save queue to keep a named copy. Nothing has started.');
}

// Scanning a six-job batch for the one that went wrong should be a glance.
function pgAutomationBatchSummary(run){
 const items=(run&&run.items)||[];
 if(items.length<2)return '';
 let complete=0,incomplete=0,pending=0,warned=0;
 items.forEach(item=>{
  const status=pgAutomationJobStatus(item,run.status);
  if(/^complete/.test(status))complete++;
  else if(['failed','stopped','interrupted'].includes(status))incomplete++;
  else pending++;
  if(Array.isArray(item.warnings)&&item.warnings.length)warned++;
 });
 const parts=[items.length+' jobs'];
 if(complete)parts.push(complete+' complete');
 if(incomplete)parts.push(incomplete+' incomplete');
 if(pending)parts.push(pending+' not run');
 if(warned)parts.push(warned+' with warnings');
 return '<p class="auto-batch-summary">'+pgAutomationEscape(parts.join(' · '))+'</p>';
}
// The run record carries an average only where quality checks recorded one.
// Anything else shown here was measured when that job was last opened.
function pgAutomationJobFigure(item,runId,index){
 const quality=item&&(item.quality_result||item.quality),series=quality&&quality.series||{};
 const grey=series.greyscale||series['greyscale-21'];
 if(grey&&grey.average!=null&&isFinite(Number(grey.average)))return 'ΔE '+Number(grey.average).toFixed(2);
 return (pgAutomation.jobFigures||{})[runId+':'+index]||'';
}
function pgAutomationJobButton(item,index,view,runId,active){
 const selected=pgAutomation.jobViews[view];
 const status=pgAutomationJobStatus(item,view==='live'?pgAutomation.current?.run?.status:null);
 const figure=pgAutomationJobFigure(item,runId,index);
 return '<div class="auto-job-row"><button type="button" class="auto-job-pick '+(active?'auto-run-current':'')+'" data-job-index="'+index+'" aria-pressed="'+!!(selected?.runId===runId&&selected.index===index)+'" '+(active?'aria-current="step"':'')+' onclick="pgAutomationSelectJob(\''+view+'\',\''+pgAutomationEscape(runId)+'\','+index+')"><span class="auto-job-line"><strong>'+(index+1)+'. '+pgAutomationEscape(item.name||'Job')+'</strong>'+(figure?'<span class="auto-job-figure">'+pgAutomationEscape(figure)+'</span>':'')+'</span><small>'+pgAutomationEscape(status)+(active?' · Current job':'')+'</small>'+(item.failure?'<small>'+pgAutomationEscape(pgAutomationIssueText(item.failure))+'</small>':'')+'</button><div class="auto-job-index" data-job-index-for="'+index+'"></div></div>';
}
function pgAutomationReducedMotion(){
 try{return window.matchMedia('(prefers-reduced-motion:reduce)').matches;}catch(e){return false;}
}
// Sections a job was configured to produce but never did. Shown greyed so a
// job that was not asked to do 3D reads differently from one that tried.
function pgAutomationPlannedSections(item,state){
 const stages=item&&item.stages||{},signal=item&&item.signal_format||'sdr';
 const enabled=key=>pgAutomationStageEnabled(stages,key);
 const planned=[];
 const sweeps=(keys,phase,label)=>(keys||['greyscale-21','colors-30','saturations-24']).forEach(key=>planned.push({key:'m:'+phase+':'+key,name:label+' · '+pgAutomationSeriesLabel(key)}));
 if(enabled('pre_readings')&&state.showBefore)sweeps(item.pre_series,'pre','Before');
 if(enabled('calibration')){
  planned.push({key:'m:calibration:grey',name:'1D LUT'});
  planned.push(signal==='dv'?{key:'m:calibration:dv-profile',name:'Dolby Vision profile'}:{key:'m:calibration:3d',name:'3D LUT'});
 }
 if(enabled('post_readings')&&state.showAfter)sweeps(item.post_series,'post','After');
 return planned;
}
function pgAutomationIndexRow(view,key,name,figure,options){
 const opts=options||{};
 return '<li class="auto-index-row'+(opts.absent?' auto-index-absent':'')+(opts.chart?' auto-index-chart':'')+'" data-index-key="'+pgAutomationEscape(key)+'">'
  +(opts.absent
   ?'<span class="auto-index-name">'+pgAutomationEscape(name)+'</span><span class="auto-index-figure">Not recorded</span>'
   :'<button type="button" class="auto-index-link" onclick="pgAutomationJumpToSection(\''+view+'\',\''+pgAutomationEscape(opts.section||key)+'\''+(opts.chart?',\''+pgAutomationEscape(opts.chart)+'\'':'')+')">'
    +'<span class="auto-index-name">'+pgAutomationEscape(name)+'</span>'
    +(opts.flag?'<span class="auto-section-flag" aria-label="'+pgAutomationEscape(opts.flag)+'" title="'+pgAutomationEscape(opts.flag)+'">!</span>':'')
    +'<span class="auto-index-figure">'+pgAutomationEscape(figure||'')+'</span></button>')
  +'</li>';
}
// Built from the rendered sections, so the index can never drift from them.
function pgAutomationRenderJobIndex(view,state){
 if(view==='calibration')return;
 const list=pgAutomationEl(view==='live'?'Live':'HistoryJobs');
 const target=pgAutomationJobTarget(view);
 if(!list||!target)return;
 // Only the selected job carries an index; a previous job's entries would
 // otherwise sit under its own row pointing at results no longer on screen.
 const slots=[...list.querySelectorAll('[data-job-index-for]')];
 slots.forEach(el=>{if(Number(el.dataset.jobIndexFor)!==state.index&&el.firstChild)el.innerHTML='';});
 const slot=slots.find(el=>Number(el.dataset.jobIndexFor)===state.index);
 if(!slot)return;
 const rows=[],present=new Set();
 target.querySelectorAll('details.auto-section').forEach(section=>{
  const key=section.dataset.sectionKey||'';
  present.add(key);
  const name=String(section.querySelector('.auto-section-name')?.textContent||key);
  const badge=state.sectionBadges&&state.sectionBadges[key]?state.sectionBadges[key]:String(section.querySelector('.auto-section-figure')?.textContent||'');
  const flag=section.querySelector('.auto-section-flag')?.getAttribute('title')||'';
  rows.push(pgAutomationIndexRow(view,key,name,badge,{flag}));
  if(!section.open)return;
  section.querySelectorAll('details.auto-chart').forEach(chart=>{
   const chartKey=chart.dataset.chartKey||'';
   if(!chartKey)return;
   rows.push(pgAutomationIndexRow(view,key+'/'+chartKey,String(chart.querySelector('.report-chart-name')?.textContent||chartKey),
    String(chart.querySelector('.report-chart-figure')?.textContent||''),{section:key,chart:chartKey}));
  });
 });
 pgAutomationPlannedSections(state.data?.item||{},state).forEach(planned=>{
  if(!present.has(planned.key))rows.push(pgAutomationIndexRow(view,planned.key,planned.name,'',{absent:true}));
 });
 const html=rows.length?'<ul class="auto-index" aria-label="Sections in this job">'+rows.join('')+'</ul>':'';
 if(state.indexHtml===html&&!!slot.firstChild===!!html)return;
 state.indexHtml=html;slot.innerHTML=html;
 pgAutomationWatchSectionScroll(view,target,slot);
}
function pgAutomationJumpToSection(view,key,chartKey){
 const target=pgAutomationJobTarget(view);if(!target)return;
 const section=[...target.querySelectorAll('details.auto-section')].find(el=>el.dataset.sectionKey===key);
 if(!section)return;
 if(!section.open)section.open=true;
 let focus=section;
 if(chartKey){
  const chart=[...section.querySelectorAll('details.auto-chart')].find(el=>el.dataset.chartKey===chartKey);
  if(chart){if(!chart.open)chart.open=true;focus=chart;}
 }
 focus.style.scrollMarginTop='calc(var(--pg-header-height, 61px) + 12px)';
 focus.scrollIntoView({behavior:pgAutomationReducedMotion()?'auto':'smooth',block:'start'});
 focus.querySelector('summary')?.focus({preventScroll:true});
}
// Mark the section being read, so the index says where you are.
function pgAutomationWatchSectionScroll(view,target,slot){
 const spies=pgAutomation.sectionSpies=pgAutomation.sectionSpies||{};
 if(spies[view])spies[view].disconnect();
 if(typeof IntersectionObserver!=='function')return;
 const seen=new Map();
 const observer=new IntersectionObserver(records=>{
  records.forEach(record=>seen.set(record.target,record));
  let best=null;
  seen.forEach(record=>{
   if(!record.isIntersecting)return;
   if(!best||record.boundingClientRect.top<best.boundingClientRect.top)best=record;
  });
  const key=best?best.target.dataset.sectionKey:'';
  slot.querySelectorAll('.auto-index-row').forEach(row=>{
   const active=!!key&&row.dataset.indexKey===key;
   row.classList.toggle('auto-index-current',active);
   const link=row.querySelector('.auto-index-link');
   if(link){if(active)link.setAttribute('aria-current','true');else link.removeAttribute('aria-current');}
  });
 },{rootMargin:'-10% 0px -70% 0px',threshold:0});
 target.querySelectorAll('details.auto-section').forEach(section=>observer.observe(section));
 spies[view]=observer;
}
// Say "incomplete" only where the record shows a job that stopped short; a
// queued or running job has simply not got there yet.
function pgAutomationJobIncomplete(item,runStatus){
 const status=pgAutomationJobStatus(item,runStatus);
 if(/^complete/.test(status||''))return '';
 if(item&&item.failure)return pgAutomationIssueText(item.failure);
 if(['failed','stopped','interrupted'].includes(status))return 'Job '+status;
 return '';
}
function pgAutomationJobStatus(item,runStatus){return item.status==='running'&&['paused','interrupted','stopped','failed'].includes(runStatus)?runStatus:item.status||'queued';}
function pgAutomationJobFailureHtml(item){
 if(!item?.failure)return '';
 if(item.failure.message)return pgAutomationFailureHtml({items:[item],failure:item.failure});
 const cancelled=item.status==='stopped'&&item.failure.status==='interrupted'&&!item.failure.message&&!item.failure.error_code;
 return '<p style="color:var('+(cancelled?'--text2':'--red')+')">'+(cancelled?'Stopped during ':'')+pgAutomationEscape(pgAutomationIssueText(item.failure))+'</p>';
}
// While the whole queue is being checked no job has started: active_item is
// null as the runner saves context, restores modes or hands over to job 1.
// Coercing that null to job 0 named the first job as if it were running.
function pgAutomationQueueCheckOnly(run){return !!run&&run.active_stage==='queue-preflight'&&run.active_item==null;}
function pgAutomationShowQueueCheck(view,run){
 const target=pgAutomationJobTarget(view);if(!target)return;
 delete pgAutomation.jobViews[view];
 const html='<div class="auto-toolbar"><span class="auto-muted">Queue check</span></div><div data-job-meta><p>Checking the whole queue before any calibration begins.'+(run.worker_status?.message?' '+pgAutomationEscape(run.worker_status.message)+'.':'')+'</p></div>';
 if(target.innerHTML!==html)target.innerHTML=html;
 if(view!=='calibration')pgAutomationEl(view==='live'?'Live':'HistoryJobs')?.querySelectorAll('[data-job-index]').forEach(button=>button.setAttribute('aria-pressed','false'));
}
function pgAutomationSyncLiveDetail(run){
 if(!run?.items?.length)return;
 if(pgAutomation.liveSelection?.runId!==run.id){pgAutomation.followLive=true;pgAutomation.liveSelection=null;}
 if(pgAutomation.followLive&&pgAutomationQueueCheckOnly(run)){pgAutomationShowQueueCheck('live',run);return;}
 const index=pgAutomation.followLive?Math.max(0,Math.min(Number(run.active_item??0),run.items.length-1)):pgAutomation.liveSelection.index;
 pgAutomationShowJob('live',run.id,index);
}
function pgAutomationSelectJob(view,runId,index){
 if(view==='live'){pgAutomation.followLive=false;pgAutomation.liveSelection={runId,index};}
 pgAutomationShowJob(view,runId,index,true);
}
function pgAutomationBackToLive(){pgAutomation.followLive=true;pgAutomationSyncLiveDetail(pgAutomation.current?.run);}
function pgAutomationJobTarget(view){return pgAutomationEl(view==='calibration'?'CalibrationDetail':view==='live'?'LiveDetail':'HistoryJobDetail');}
function pgAutomationCalibrationOccupied(run){return !!run&&['starting','running','paused','interrupted','stopping','completing'].includes(run.status);}
function pgAutomationOpenRun(){
 if(typeof pgSelectDesktopWorkspace==='function')pgSelectDesktopWorkspace('automation');
 pgAutomationTab('live');
 pgAutomationBackToLive();
 document.getElementById('automationCard')?.scrollIntoView({behavior:'smooth',block:'start'});
 const live=pgAutomationEl('Live'),run=pgAutomation.current?.run,index=Math.max(0,Math.min(Number(run?.active_item||0),(run?.items?.length||1)-1));
 (live?.querySelector('[aria-current="step"]')||live?.querySelector('[data-job-index="'+index+'"]')||document.querySelector('[data-auto-tab="live"]'))?.focus({preventScroll:true});
}
function pgAutomationSyncCalibrationView(run){
 const card=pgAutomationEl('CalibrationCard'),meter=document.getElementById('meterCard');
 if(!card||!meter)return;
 const occupied=pgAutomationCalibrationOccupied(run);
 if(occupied){
  if(!pgAutomation.calibrationObserver){pgAutomation.meterWasInert=meter.inert;}
  pgAutomation.calibrationObserver=run.id;
 }
 if(!run||pgAutomation.calibrationObserver!==run.id){pgAutomationReleaseCalibrationView(true);return;}
 card.style.display='';meter.inert=true;document.body.classList.add('pg-automation-calibration-observer');
 const badge=pgAutomationEl('CalibrationBadge');
 badge.dataset.state=run.status;
 badge.textContent='Automation '+({running:'active',starting:'starting',paused:'paused',interrupted:'interrupted',stopping:'stopping',completing:'finishing',complete:'complete','complete-with-warnings':'complete with warnings',stopped:'stopped',failed:'failed'}[run.status]||run.status)+' · Read-only';
 const queueCheck=pgAutomationQueueCheckOnly(run);
 const index=Math.max(0,Math.min(Number(run.active_item??0),(run.items?.length||1)-1)),item=queueCheck?null:run.items?.[index],worker=pgAutomationTerminal(run)?{}:{...(run.worker_status||{}),message:(run.status==='running'?run.operation_progress?.message:null)||run.worker_status?.message};
 const terminal=pgAutomationTerminal(run),esc=pgAutomationEscape;
 const stage=terminal?({stopped:'Run stopped',failed:'Run failed',complete:'Run complete','complete-with-warnings':'Run complete with warnings'}[run.status]||'Saved results'):pgAutomationStageLabel(run.active_stage||'Preparing job');
 const held=['paused','interrupted'].includes(run.status);
 const detail=[held?(run.status==='paused'?'Paused':'Interrupted'):null,stage,!terminal&&worker.current_name,!terminal&&worker.total_steps?(held?'Last patch ':'Patch ')+Number(worker.current_step||0)+' / '+worker.total_steps:null].filter(Boolean).join(' · ');
 const progress='<div class="auto-observer-eyebrow">'+(queueCheck?'Queue check':'Job '+(index+1)+' of '+(run.items?.length||0)+(terminal?' · Saved results':''))+'</div><h3 class="auto-observer-title">'+esc(queueCheck?'Checking the whole queue':(item?.name||'Preparing job'))+'</h3><p class="auto-observer-stage">'+esc(detail)+'</p>'+(!terminal&&worker.message?'<p class="auto-observer-activity">'+(held?'Last activity: ':'')+esc(worker.message)+'</p>':'');
 const progressEl=pgAutomationEl('CalibrationProgress');if(progressEl.innerHTML!==progress)progressEl.innerHTML=progress;
 pgAutomationEl('CalibrationHelp').textContent=pgAutomation.statusError|| ({complete:'Saved results for this completed run.','complete-with-warnings':'Measurements saved. Review the warnings in Automation.',stopped:'Run stopped. Saved measurements may be partial.',failed:'Run failed. Any saved measurements may be partial.',paused:'Batch paused. Resume or stop the run in Automation.',interrupted:'Batch interrupted. Review the run in Automation before continuing.'}[run.status]||'Read-only view of the active batch. Manage the run in Automation.');
 pgAutomationEl('CalibrationRelease').style.display=occupied?'none':'';
 if(typeof pgSyncDesktopPanels==='function')pgSyncDesktopPanels();
 const state=pgAutomation.jobViews.calibration;
 if(state&&(state.stage!==run.active_stage||state.runStatus!==run.status)){
  state.data=null;state.graphSignature=null;state.lastFetch=0;state.stage=run.active_stage;
  pgAutomationJobTarget('calibration').querySelector('[data-job-graphs]').textContent='Waiting for measurements from '+pgAutomationStageLabel(run.active_stage||'the next stage')+'.';
 }
 if(queueCheck&&card.getClientRects().length){pgAutomationShowQueueCheck('calibration',run);}
 if(item&&card.getClientRects().length){
  pgAutomationShowJob('calibration',run.id,index);
  if(pgAutomation.jobViews.calibration){pgAutomation.jobViews.calibration.stage=run.active_stage;pgAutomation.jobViews.calibration.runStatus=run.status;}
 }
}
function pgAutomationReleaseCalibrationView(force=false){
 if(!force&&pgAutomationCalibrationOccupied(pgAutomation.current?.run))return;
 const card=pgAutomationEl('CalibrationCard'),meter=document.getElementById('meterCard');
 if(card)card.style.display='none';
 if(meter&&pgAutomation.calibrationObserver)meter.inert=!!pgAutomation.meterWasInert;
 pgAutomation.calibrationObserver=null;delete pgAutomation.jobViews.calibration;
 document.body.classList.remove('pg-automation-calibration-observer');
 if(typeof pgSyncDesktopPanels==='function')pgSyncDesktopPanels();
}
function pgAutomationShowJob(view,runId,index,force=false){
 const target=pgAutomationJobTarget(view);if(!target)return;
 let state=pgAutomation.jobViews[view];
 if(!state||state.runId!==runId||state.index!==index){
  state={runId,index,showBefore:true,showAfter:true,lastFetch:0,entries:[],sectionBadges:{},verdictStats:[],totalReadings:0};pgAutomation.jobViews[view]=state;
  target.innerHTML='<div class="auto-toolbar" data-job-nav></div><div data-job-meta>Loading job details…</div><div data-job-verdict></div><div data-job-toggles></div><div data-job-error role="status"></div><div data-job-measurement role="status"></div><div class="auto-sections" data-job-sections><div data-job-settings></div><div data-job-graphs></div></div>';
 }
 pgAutomationWatchFolds(target,view);
 const list=view==='calibration'?null:pgAutomationEl(view==='live'?'Live':'HistoryJobs');
 list?.querySelectorAll('[data-job-index]').forEach(button=>button.setAttribute('aria-pressed',String(Number(button.dataset.jobIndex)===index)));
 const saved=view!=='live'||pgAutomationTerminal(pgAutomation.current?.run);
 target.querySelector('[data-job-nav]').innerHTML=view==='live'&&!saved&&!pgAutomation.followLive?'<button class="btn btn-sm btn-primary" onclick="pgAutomationBackToLive()">Back to live job</button>':'<span class="auto-muted">'+(saved?'Saved job results':'Following live job')+'</span>';
 // 18 Sep 2026: a job-detail fetch costs 1.4-3 s on the appliance (472 KB with
 // snapshots and checks), so two open tabs at the old 2.5 s / 10 s cadence
 // kept the daemon at two thirds of a core. The chart refreshes every 5 s,
 // the saved-job card every 30 s; the 2 s status poll still drives the rest.
 if(state.data)pgAutomationRenderJobIndex(view,state);
 // A terminal job's results are frozen on the Pi. Re-fetching and re-rendering
 // them on a timer cost the appliance a chart pass every 30 s for nothing.
 // A running stage refreshes its plots at the observer's 5 s. The marker
 // itself rides the light 2 s run poll, so it never waits on the 472 KB job
 // fetch that the 18 Sep work deliberately slowed down.
 const cadence=(view==='calibration'||pgAutomationRunIsLive())?5000:30000;
 const run=pgAutomation.current?.run;
 if(run?.id===state.runId&&!pgAutomationTerminal(run)&&Number(run.active_item)===state.index)state.settled=false;
 if(!state.loading&&(force||!(state.settled&&state.data))&&(force||Date.now()-state.lastFetch>cadence))pgAutomationFetchJob(view,state);
}
async function pgAutomationFetchJob(view,state){
 state.loading=true;state.lastFetch=Date.now();
 try{
  const data=await fetchJSON('/api/automation/runs/'+encodeURIComponent(state.runId)+'/jobs/'+state.index,{_quiet:true,_timeoutMs:15000});
  // A response can arrive after the operator selects another job; never paint
  // the previous job's measurements into the newly selected view.
  if(pgAutomation.jobViews[view]!==state)return;
  if(!data||data.status!=='ok')throw new Error(data?.message||'No job details returned');
  // Status polling may already have advanced the stage while details loaded.
  if(view==='calibration'&&data.active_stage!==pgAutomation.current?.run?.active_stage)return;
  state.data=data;
  const target=pgAutomationJobTarget(view),item=data.item;
  const measurement=target.querySelector('[data-job-measurement]');
  if(measurement){
   const snap=data.live?.snapshot,retry=snap?.measurement_retry;
   const timestamps=(snap?.readings||[]).filter(r=>!r.null_read).map(r=>Number(r.timestamp)).filter(t=>Number.isFinite(t)&&t>0);
   measurement.style.color=retry?'var(--orange)':'';
   measurement.textContent=retry?'Retrying invalid measurement · '+(snap.message||retry.reason)+'. Graphs retain the last measurements.':snap?[snap.message,timestamps.length?'Last valid measurement '+new Date(Math.max(...timestamps)*1000).toLocaleTimeString():null].filter(Boolean).join(' · '):'';
  }
  target.querySelector('[data-job-error]').textContent='';
  const meta=target.querySelector('[data-job-meta]');
  // "Results saved" is when the runner last recorded a checkpoint for this
 // job; the fetch time only says when the browser asked.
 // Only completed measurement stages count, After Readings first: skipped,
 // interrupted and setup-only records carry a timestamp but measured nothing.
 const doneAt=names=>Math.max(0,...(item.checkpoints||[]).filter(c=>c&&c.status==='done'&&(!names||names.includes(c.name))).map(c=>Number(c.completed_at)||0));
 const saved=doneAt(['post-readings-done'])||doneAt(['pre-readings-done','greyscale-done','volume-done']);
 meta.innerHTML=(view==='calibration'?'':'<h3>'+pgAutomationEscape(item.name||'Job '+(state.index+1))+'</h3><p class="auto-muted">'+pgAutomationEscape(pgAutomationJobStatus(item,data.run_status))+(saved?' · Results saved '+new Date(saved*1000).toLocaleTimeString():' · Results updated '+new Date(data.fetched_at*1000).toLocaleTimeString())+'</p>')+pgAutomationJobFailureHtml(item);
  state.settled=['complete','complete-with-warnings','failed','stopped'].includes(data.run_status||'')&&!['running','queued','paused'].includes(item.status||'');
  const manualChecks=[...new Set([...(item.manual_checks||[]),...(data.readiness_issues||[]).map(issue=>issue.message).filter(Boolean)])];
  const checkTotals=pgAutomationCheckTotals(data.checks||[]);
  state.checkTotals=checkTotals;state.incomplete=pgAutomationJobIncomplete(item,data.run_status);
  const settingsCount=pgAutomationItemSettingsList(item).length;
  const settings=target.querySelector('[data-job-settings]');
  settings.innerHTML=
   pgAutomationSection('overview','Overview',pgAutomationTargetLine(item),pgAutomationItemSummary(item,'targets'),{defaultOpen:false})
   +pgAutomationSection('setup','Setup',settingsCount?settingsCount+(settingsCount===1?' setting':' settings'):'No pins',pgAutomationApplyAllNote(item)+pgAutomationItemSummary(item,'setup'),{defaultOpen:false})
   +pgAutomationSection('checks','Checks',checkTotals.total?checkTotals.total+' checks':'None recorded',pgAutomationSettingsEvidence(data.checks||[],{...item,manual_checks:manualChecks},{heading:false}),
    {defaultOpen:!!checkTotals.flagged,flag:checkTotals.flagged?checkTotals.flagged+' setting'+(checkTotals.flagged===1?'':'s')+' not verified':''});
  const before=(data.snapshots||[]).some(s=>s.phase==='pre'&&s.snapshot?.readings?.length)||(data.live?.phase==='pre'&&data.live.snapshot?.readings?.length);
  target.querySelector('[data-job-toggles]').innerHTML='<div class="auto-job-controls">'
   +(before?'<label><input type="checkbox" '+(state.showBefore?'checked':'')+' onchange="pgAutomationGraphToggle(\''+view+'\',\'showBefore\',this.checked)"> Before</label>':'')
   +'<label><input type="checkbox" '+(state.showAfter?'checked':'')+' onchange="pgAutomationGraphToggle(\''+view+'\',\'showAfter\',this.checked)"> '+(/^complete/.test(item.status||'')?'Final':'Latest / after')+'</label>'
   +'<span class="auto-controls-gap" aria-hidden="true"></span>'
   +'<button class="btn btn-sm btn-secondary" type="button" title="Open every section. Charts keep their own state." onclick="pgAutomationExpandAll(\''+view+'\',true)">Expand all</button>'
   +'<button class="btn btn-sm btn-secondary" type="button" title="Close every section and chart." onclick="pgAutomationExpandAll(\''+view+'\',false)">Collapse all</button></div>';
  await pgAutomationRenderJobGraphs(view,state);
 }catch(e){if(pgAutomation.jobViews[view]===state)pgAutomationJobTarget(view).querySelector('[data-job-error]').textContent=state.data?'Unable to refresh job details: '+e.message+'. Any displayed results are the last received, not confirmed current.':'Unable to load job details: '+e.message+'. No measurements have been loaded for this job. The next status check will retry.';}
 finally{state.loading=false;}
}
function pgAutomationApplyAllNote(item){
 const apply=item?.['apply-all'];
 if(apply?.outcome!=='sent-unconfirmed'||!apply.confirmation_unavailable)return '';
 return '<p class="auto-muted">Apply to All Inputs sent — confirmation unavailable on this TV.</p>';
}
function pgAutomationSettingReason(check){
 if(check.reason)return String(check.reason)+(check.error_code?' ('+check.error_code+')':'');
 if(check.result==='expected-calibration-state')return 'Expected LG calibration state: Auto requested for setup, Wide reported after calibration. Retained for diagnostics; no gamut rewrite is required.';
 if(check.result==='lut-managed')return 'The uploaded calibration LUT controls this setting; the requested menu value is retained as the pre-calibration setup.';
 if(check.result==='readback-warning')return 'LG reported Wide for requested Auto. Continuing with a warning; the two values are not confirmed equivalent.';
 if(check.verified)return 'TV readback matched at this check.';
 if(check.result==='apply-failed')return 'Setting write failed; this older record did not save the driver reason.';
 if(check.result==='unverifiable')return 'Readback could not be verified. This older record does not say whether the control was unsupported or unavailable in this mode. Check the TV menu.';
 if(check.observed==null)return 'No TV-reported value was saved. The reason was not recorded; this does not prove the write failed.';
 return 'TV-reported value differs from the requested value.';
}
function pgAutomationCheckStage(check){
 const key=check.point||check.checkpoint||check.stage||'';
 if(key==='dv-profile-before-upload')return 'After Dolby Vision profile measurements, before upload';
 if(/^3d-processing-transition-\d+$/.test(key))return 'After calibration transition, before further measurements';
 if(key==='resume-profile-baseline')return 'Saved 1D and unity baseline restored before profile retry';
 if(key.endsWith('-mode'))return 'Picture mode confirmation before settings · '+(key.slice(0,-5));
 const boundary=key.match(/^c([678])(?:-(confirm|repair|stable))?$/);
 if(boundary)return ({6:'After 1D calibration',7:'After profile / LUT upload, before calibration exit',8:'After calibration exit'})[boundary[1]]+({confirm:' · fresh confirmation',repair:' · targeted repair',stable:' · stability check'}[boundary[2]]||'');
 return ({c1:'TV setup',c4:'After reset and reapply',c5:'White luminance setup','c5-panel-iteration':'Adjusting panel light',c8:'After calibration closes','c8-recovery':'Reapplying settings after drift',c9:'After apply to all inputs',c10:'Before after-readings'})[key]||pgAutomationStageLabel(key)||'Stage not recorded';
}
function pgAutomationCheckTotals(checks){
 const latest=new Map();(checks||[]).forEach(c=>latest.set((c.category||'picture')+':'+c.key,c));
 const managed=c=>c.result==='lut-managed'||c.result==='expected-calibration-state';
 return {total:(checks||[]).length,flagged:[...latest.values()].filter(c=>!c.verified&&!managed(c)).length};
}
function pgAutomationSettingsEvidence(checks,item,options){
 const opts=options||{};
 const value=v=>v==null?'Not returned':typeof v==='object'?JSON.stringify(v):String(v),esc=pgAutomationEscape;
 const label=c=>c.result==='expected-calibration-state'?'Expected calibration state':c.result==='lut-managed'?'LUT-managed':c.result==='readback-warning'?'Warning — LG gamut readback':c.verified?'Verified':c.result==='apply-failed'?'Failed to apply':c.result==='unverifiable'||c.observed==null?'Could not verify':'Readback mismatch';
 const stage=c=>[pgAutomationCheckStage(c),c.timestamp?pgAutomationFormatTime(typeof c.timestamp==='number'?c.timestamp*1000:c.timestamp):c.at?pgAutomationFormatTime(c.at):''].filter(Boolean).join(' · ');
 const latest=new Map();checks.forEach(c=>latest.set((c.category||'picture')+':'+c.key,c));
 const isManaged=c=>c.result==='lut-managed'||c.result==='expected-calibration-state';
 const managed=[...latest.values()].filter(isManaged);
 const problems=[...latest.values()].filter(c=>!c.verified&&!isManaged(c));
 const manual=(item.manual_checks||[]).map(c=>'<p class="auto-muted">Manual check: '+esc(typeof c==='string'?c:c.message||c.key||'Check in the TV menu')+'</p>').join('');
 return (opts.heading===false?'':'<h4>TV settings verification</h4>')+'<p class="auto-muted">Saved readbacks at the stages shown—not a fresh read of the TV.</p>'+manual+
  managed.map(c=>'<p class="auto-muted"><strong>'+esc(c.key)+' · '+label(c)+'</strong><br>Requested: '+esc(value(c.expected))+' · TV reported: '+esc(value(c.observed))+'<br>'+esc(pgAutomationSettingReason(c))+'<br><small>'+esc(stage(c))+'</small></p>').join('')+
  (checks.length?(problems.length?problems.map(c=>'<div class="auto-setting-problem"><strong>'+esc(c.key)+' · '+label(c)+'</strong><div>Requested: '+esc(value(c.expected))+' · TV reported: '+esc(value(c.observed))+'</div><div>'+esc(pgAutomationSettingReason(c))+'</div><small>'+esc(stage(c))+'</small></div>').join(''):managed.length?'<p>Other recorded settings matched at their latest check.</p>':'<p>All recorded settings matched at their latest check.</p>'):'<p class="auto-muted">No settings verification has been recorded for this job.</p>')+
  (checks.length?'<details><summary>All setting checks ('+checks.length+')</summary><div class="auto-settings-table"><table><thead><tr><th>Setting</th><th>Requested</th><th>TV reported</th><th>Result / reason</th><th>Checked at</th></tr></thead><tbody>'+checks.map(c=>'<tr><td>'+esc(c.key)+'</td><td>'+esc(value(c.expected))+'</td><td>'+esc(value(c.observed))+'</td><td>'+label(c)+' — '+esc(pgAutomationSettingReason(c))+'</td><td>'+esc(stage(c))+'</td></tr>').join('')+'</tbody></table></div></details>':'');
}
// Section folding. A fold is a reading preference, not job data: it is keyed by
// section name so it carries across jobs and reloads, and it lives only in this
// browser. Sections default open for measurements (the numbers answer "how did
// this go") and closed for the setup record.
const PG_AUTOMATION_SECTIONS_KEY='pgen.ui.automationSections';
function pgAutomationFolds(){
 if(!pgAutomation.folds){
  let stored=null;
  try{stored=JSON.parse(localStorage.getItem(PG_AUTOMATION_SECTIONS_KEY)||'{}');}catch(e){stored=null;}
  pgAutomation.folds=stored&&typeof stored==='object'&&!Array.isArray(stored)?stored:{};
 }
 return pgAutomation.folds;
}
function pgAutomationSetFold(key,open){
 if(!key)return;
 const folds=pgAutomationFolds();folds[key]=!!open;
 try{localStorage.setItem(PG_AUTOMATION_SECTIONS_KEY,JSON.stringify(folds));}catch(e){}
}
function pgAutomationFoldOpen(key,fallback){
 const folds=pgAutomationFolds();
 return Object.prototype.hasOwnProperty.call(folds,key)?!!folds[key]:!!fallback;
}
// The run's worker status is the only live thing on this screen: the panel
// watches a job it is not driving.
function pgAutomationLiveWorker(){
 const run=pgAutomation.current&&pgAutomation.current.run;
 if(!run||pgAutomationTerminal(run))return null;
 const worker=run.worker_status;
 return worker&&worker.current_name?worker:null;
}
function pgAutomationRunIsLive(){return !!pgAutomationLiveWorker();}
// The job's live snapshot carries the patch under the meter as numbers
// (current_ire and friends); the run's worker status only carries a display
// string with the stage name glued on. Prefer the numbers.
function pgAutomationLiveState(){
 const run=pgAutomation.current?.run;
 if(!run||pgAutomationTerminal(run)||run.active_item==null)return null;
 return Object.values(pgAutomation.jobViews||{}).filter(state=>state&&state.runId===run.id
  &&state.index===Number(run.active_item)&&state.data?.live&&state.data.active_stage===run.active_stage
  &&(!run.stage_started_at||Number(state.data.stage_started_at)===Number(run.stage_started_at)))
  .sort((a,b)=>b.lastFetch-a.lastFetch)[0]||null;
}
function pgAutomationLiveSnapshot(worker){
 const snap=pgAutomationLiveState()?.data?.live?.snapshot;
 // A job snapshot can lag the status poll. Its numbers are authoritative only
 // while both replies name the same patch of this run and stage.
 return snap&&snap.current_name&&(!worker||String(snap.current_name)===String(worker.current_name))?snap:null;
}
// A running stage answers "how much longer" first. On tablet widths the quality
// figure is dropped by CSS -- the chart carrying it is a few pixels below.
function pgAutomationLiveFigureHtml(count,average){
 const worker=pgAutomationLiveWorker();
 const total=Number(worker&&worker.total_steps)||0;
 const done=Number(worker&&worker.current_step)||0;
 const progress=total?done+' / '+total:(count?count+' readings':'Measuring');
 return pgAutomationEscape(progress)
  +(average?'<span class="auto-section-figure-trail"> · ΔE '+pgAutomationEscape(average)+'</span>':'');
}
function pgAutomationPaintLiveFigures(){
 const active=pgAutomationLiveState();
 Object.entries(pgAutomation.jobViews||{}).forEach(([view,state])=>{
  pgAutomationJobTarget(view)?.querySelectorAll('details.auto-section-running').forEach(section=>{
   const current=!!active&&state.runId===active.runId&&state.index===active.index
    &&state.data?.active_stage===active.data.active_stage&&state.data?.stage_started_at===active.data.stage_started_at;
   section.toggleAttribute('data-pg-live',current);
   const el=section.querySelector('.auto-section-figure');if(!el||!current)return;
   const live=state.sectionLive?.[section.dataset.sectionKey]||{};
   el.innerHTML=pgAutomationLiveFigureHtml(Number(live.count||0),live.average||'');
  });
 });
}
// Set the live mark from the poll that delivered it, then let the shared chart
// layer place it on every chart that published geometry.
function pgAutomationSyncLiveMark(){
 if(typeof meterLiveMarkSet!=='function')return;
 const worker=pgAutomationLiveWorker();
 pgAutomationPaintLiveFigures();
 const state=pgAutomationLiveState();
 const entry=state?.entries?.find(entry=>entry.isLive);
 const series=entry&&state.sectionSeries?.[entry.key];
 if(!worker||!series){meterLiveMarkSet(null);return;}
 const run=pgAutomation.current&&pgAutomation.current.run;
 const held=['paused','interrupted','stopping'].includes((run&&run.status)||'');
 meterLiveMarkSet(meterLiveResolveStatusMark(pgAutomationLiveSnapshot(worker)||worker,series.steps,held?'held':null,series.readings));
 // A re-render replaces the chart images even when the patch has not moved,
 // so the overlays are re-attached here rather than only when the mark changes.
 if(typeof meterLiveRefreshSurfaces==='function')meterLiveRefreshSurfaces();
 pgAutomationMarkLiveTableRow();
}
// The greyscale table lists measured patches only, so its live row is the most
// recent real reading: one patch behind the charts' ghost while the meter is
// still integrating. Manual scrolling pauses following until explicitly resumed.
function pgAutomationMarkLiveTableRow(){
 document.querySelectorAll('tr.auto-live-row').forEach(tr=>tr.classList.remove('auto-live-row'));
 const mark=(typeof meterLiveMark==='function')?meterLiveMark():null;
 if(!mark)return;
 // Both the observer and Automation can show this stage at once. Each
 // view owns its highlight and scroll choice independently.
 document.querySelectorAll('[data-pg-live]').forEach(section=>{
  const rows=[...section.querySelectorAll('tr[data-ire]')];
  if(!rows.length)return;
  let row=null;
  rows.forEach(tr=>{
   const ire=Number(tr.dataset.ire);
   if(isFinite(ire)&&(mark.ire==null||ire<=Number(mark.ire)))row=tr;
  });
  row=row||rows[rows.length-1];
  row.classList.add('auto-live-row');
  pgAutomationFollowTableRow(section,row);
 });
}
function pgAutomationFollowTableRow(section,row){
 const scroller=pgAutomationScrollerFor(row);
 if(!scroller)return;
 const owner=Object.entries(pgAutomation.jobViews||{}).find(([view])=>pgAutomationJobTarget(view)?.contains(section));
 // Keep preferences with the job because width/DPR changes rebuild sections.
 const states=owner?(owner[1].tableFollow||(owner[1].tableFollow={})):section;
 const key=owner?(section.dataset.sectionKey||'readings'):'_pgTableFollow';
 const follow=states[key]||(states[key]={enabled:true,top:scroller.scrollTop});
 if(follow.scroller!==scroller){
  follow.scroller=scroller;
  scroller.scrollTop=follow.top;
  const button=document.createElement('button');
  button.type='button';button.className='btn btn-sm';
  button.textContent='Follow latest reading';button.hidden=follow.enabled;
  scroller.before(button);
  const pause=()=>{follow.enabled=false;button.hidden=false;};
  button.addEventListener('click',()=>{follow.enabled=true;button.hidden=true;pgAutomationMarkLiveTableRow();});
  scroller.addEventListener('wheel',pause,{passive:true});
  scroller.addEventListener('touchmove',pause,{passive:true});
  scroller.addEventListener('keydown',event=>{
   if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(event.key))pause();
  });
  scroller.addEventListener('scroll',()=>{
   if(Math.abs(scroller.scrollTop-follow.top)>1)pause();
   follow.top=scroller.scrollTop;
  },{passive:true});
 }
 if(!follow.enabled)return;
 const top=row.offsetTop-scroller.clientHeight/2+row.offsetHeight/2;
 scroller.scrollTop=Math.max(0,Math.min(top,scroller.scrollHeight-scroller.clientHeight));
 follow.top=scroller.scrollTop;
}
function pgAutomationScrollerFor(el){
 let node=el&&el.parentElement;
 while(node&&node!==document.body){
  const style=getComputedStyle(node);
  if(/(auto|scroll)/.test(style.overflowY)&&node.scrollHeight>node.clientHeight+4)return node;
  node=node.parentElement;
 }
 return null;
}
function pgAutomationSection(key,name,figure,body,options){
 const opts=options||{};
 const open=opts.forceOpen||pgAutomationFoldOpen(key,opts.defaultOpen);
 return '<details class="auto-section'+(opts.live?' auto-section-running':'')+'" data-section-key="'+pgAutomationEscape(key)+'"'+(opts.live?' data-pg-live':'')+(open?' open':'')+'>'
  +'<summary class="auto-section-head">'+(opts.live?'<span class="auto-section-dot" aria-hidden="true"></span>':'')
  +'<span class="auto-section-name">'+pgAutomationEscape(name)+'</span>'
  +(opts.flag?'<span class="auto-section-flag" title="'+pgAutomationEscape(opts.flag)+'" aria-label="'+pgAutomationEscape(opts.flag)+'">!</span>':'')
  +'<span class="auto-section-rule" aria-hidden="true"></span>'
  +'<span class="auto-section-figure">'+(opts.figureHtml||pgAutomationEscape(figure||''))+'</span></summary>'
  +'<div class="auto-section-body">'+body+'</div></details>';
}
// Chart cards arrive as flat divs from the shared report builder, which the
// downloadable report needs to stay flat. Fold them here, in the panel only.
function pgAutomationFoldCharts(root){
 if(!root)return;
 let untitled=0;
 root.querySelectorAll('.report-chart-card,.report-table-card').forEach(card=>{
  if(card.closest('.auto-chart'))return;
  const titleEl=card.querySelector('.report-chart-title,.report-table-title');
  const details=document.createElement('details');
  details.className='auto-chart '+card.className;
  const slug=titleEl?String(titleEl.textContent||'').trim().toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,''):'';
  const key=card.dataset.chartKey||slug||('measured-values'+(untitled++?'-'+untitled:''));
  if(key)details.dataset.chartKey=key;
  const summary=document.createElement('summary');
  summary.className='auto-chart-head';
  if(titleEl){while(titleEl.firstChild)summary.append(titleEl.firstChild);titleEl.remove();}
  else summary.textContent='Measured values';
  if(!summary.querySelector('.report-chart-name')){
   const name=document.createElement('span');name.className='report-chart-name';
   while(summary.firstChild)name.append(summary.firstChild);
   summary.append(name);
  }
  const body=document.createElement('div');
  body.className='auto-chart-body';
  while(card.firstChild)body.append(card.firstChild);
  details.append(summary,body);
  if(key&&pgAutomationFoldOpen('chart:'+key,false))details.open=true;
  card.replaceWith(details);
 });
}
function pgAutomationReportSectionParts(el){
 const title=el.querySelector('.report-section-title'),meta=el.querySelector('.report-section-meta');
 const count=meta?(String(meta.textContent||'').match(/(\d+)/)||[])[1]||'':'';
 const stats=[...el.querySelectorAll('.report-stat')].map(stat=>({
  label:String(stat.querySelector('.report-stat-label')?.textContent||'').trim(),
  value:String(stat.querySelector('.report-stat-value')?.textContent||'').trim()
 }));
 if(title)title.remove();
 if(meta)meta.remove();
 return {count,stats,html:el.innerHTML};
}
function pgAutomationStatValue(stats,match){
 const found=(stats||[]).find(stat=>match.test(stat.label));
 const value=found?found.value:'';
 return value&&value!=='--'&&value!=='NA'?value:'';
}
// Greyscale describes the display; a colour-volume pass measures its brightest
// patch, which is not the panel's peak. Keep them apart.
function pgAutomationVerdictHtml(state){
 const stats=state.verdictStats||[];
 const cells=[];
 const push=(value,label)=>{if(value)cells.push({value,label});};
 const de=(stats||[]).find(stat=>/^Average (ΔE|Delta)/i.test(stat.label));
 if(de&&de.value&&de.value!=='--')cells.push({value:de.value,label:de.label.replace(/^Average /,'Average ')});
 push(pgAutomationStatValue(stats,/^Peak Luminance$/),'Peak luminance');
 push(pgAutomationStatValue(stats,/^Black Level$/),'Black level');
 push(pgAutomationStatValue(stats,/^Contrast Ratio$/),'Contrast');
 push(pgAutomationStatValue(stats,/^Average CCT$/),'Average CCT');
 if(state.totalReadings)cells.push({value:String(state.totalReadings),label:'Readings'});
 const checks=state.checkTotals;
 if(checks&&checks.total)cells.push({value:String(checks.total),label:checks.flagged?checks.flagged+' unverified':'Checks verified',flag:!!checks.flagged});
 if(state.incomplete)cells.push({value:'Incomplete',label:state.incomplete,flag:true});
 if(!cells.length)return '';
 return '<div class="auto-verdict">'+cells.map(cell=>'<div class="auto-verdict-cell'+(cell.flag?' auto-verdict-flag':'')+'"><span class="auto-verdict-value">'+pgAutomationEscape(cell.value)+'</span><span class="auto-verdict-label">'+pgAutomationEscape(cell.label)+'</span></div>').join('')+'</div>';
}
function pgAutomationQueueIndex(view,state){
 pgAutomation.indexTimers=pgAutomation.indexTimers||{};
 clearTimeout(pgAutomation.indexTimers[view]);
 pgAutomation.indexTimers[view]=setTimeout(()=>{
  if(pgAutomation.jobViews[view]===state)pgAutomationRenderJobIndex(view,state);
 },40);
}
function pgAutomationExpandAll(view,open){
 const target=pgAutomationJobTarget(view);if(!target)return;
 target.querySelectorAll('details.auto-section').forEach(el=>{
  if(el.open!==open)el.open=open;
 });
 if(!open)target.querySelectorAll('details.auto-chart').forEach(el=>{if(el.open)el.open=false;});
}
// <details> toggle does not bubble, so listen in the capture phase.
function pgAutomationWatchFolds(target,view){
 if(!target)return;
 target.dataset.jobView=view;
 if(target.dataset.foldWatch==='1')return;
 target.dataset.foldWatch='1';
 target.addEventListener('toggle',event=>{
  const el=event.target;
  if(!el||!el.matches||!el.matches('details.auto-section,details.auto-chart'))return;
  const key=el.dataset.sectionKey?el.dataset.sectionKey:el.dataset.chartKey?'chart:'+el.dataset.chartKey:'';
  if(el.dataset.foldTransient!=='1')pgAutomationSetFold(key,el.open);
  const view=target.dataset.jobView;
  if(el.open&&el.classList.contains('auto-section'))pgAutomationRenderSectionCharts(view,el);
  const state=pgAutomation.jobViews[view];
  if(state)pgAutomationQueueIndex(view,state);
 },true);
}
function pgAutomationGraphToggle(view,key,value){const state=pgAutomation.jobViews[view];if(!state)return;state[key]=value;state.graphSignature=null;pgAutomationRenderJobGraphs(view,state);}
function pgAutomationGraphGroup(key){return /^grey/.test(key)?'greyscale':/^colors/.test(key)?'colors':/^saturations/.test(key)?'saturations':key;}
function pgAutomationGraphSnapshot(entry,item){
 const saved=entry.snapshot||{},cal=item.calibration||{};
 const signal=saved.signal_mode||item.signal_format;
 const calibration=entry.phase==='calibration';
 const snap={...saved,signal_mode:signal,
  target_gamma:saved.target_gamma||(calibration&&(signal==='dv'||entry.key==='grey'&&signal==='hdr10')?'2.2':item.target_gamma||cal.target_gamma),
  target_gamut:saved.target_gamut||item.target_gamut||cal.target_gamut,
  delta_e_formula:saved.delta_e_formula||item.delta_e_formula||cal.delta_e_formula,
  target_white:saved.target_white||item.target_white||cal.target_white};
 // Legacy worker snapshots omitted these fields. Recover from THIS job's
 // frozen recipe, never the currently running job or manual output controls.
 for(const key of ['color_format','max_bpc','signal_range','pattern_signal_range','transport_signal_range','max_luma']){
  if(snap[key]==null)snap[key]=item[key]??cal[key];
 }
 snap.signal_range=snap.signal_range??item.rgb_quant_range;
 // Sparse legacy recipes use the runner's documented defaults. Flag the
 // assumption rather than silently using today's unrelated output settings.
 snap.transport_context_inferred=!!saved.transport_context_inferred||
  signal!=='dv'&&(snap.color_format==null||snap.max_bpc==null||snap.signal_range==null);
 snap.color_format=snap.color_format??'0';
 snap.max_bpc=snap.max_bpc??(signal==='dv'?8:10);
 snap.signal_range=snap.signal_range??'2';
 snap.pattern_signal_range=snap.pattern_signal_range??snap.signal_range;
 snap.transport_signal_range=snap.transport_signal_range??snap.signal_range;
 if(signal==='dv'){
  snap.dv_map_mode=saved.dv_map_mode||(calibration?'2':'1');
  snap.color_format=snap.color_format??'0';snap.max_bpc=snap.max_bpc??8;snap.signal_range=snap.signal_range??'2';
  snap.transport_signal_range=snap.transport_signal_range??'2';
 }
 if(entry.key==='dv-profile'){
  // The actual profile worker saves measured xyY in steps, not readings.
  // This is native-panel characterisation, not a ColorChecker accuracy test.
  if(!snap.readings?.length)snap.readings=(saved.steps||[]).filter(st=>st&&st.luminance!=null&&Number.isFinite(Number(st.luminance))&&Number(st.luminance)>=0)
   .map(st=>({...st,series_type:'colors',signal_mode:'dv'}));
  snap.cache_key='lg-dv-profile';
 }
 if(entry.key==='3d'){
  snap.cache_key=(saved.method||cal.method)==='matrix'?'lg-3d-matrix-profile':'lg-3d-lattice-profile-automation';
 }
 if(entry.key==='grey'){snap.type='greyscale';snap.points=snap.points||26;}
 if(entry.key==='3d'||entry.key==='dv-profile'){snap.type='colors';snap.points=snap.points||snap.readings?.length||5;}
 return snap;
}
function pgAutomationCalibrationSnapshots(data){
 const snapshots=data.snapshots||[];
 if(['complete','complete-with-warnings','failed','stopped'].includes(data.run_status)){
  return snapshots.filter(s=>s.phase==='post'||s.phase==='calibration');
 }
 const stage=data.active_stage,phase=stage==='pre-readings-done'?'pre':stage==='post-readings-done'?'post':stage==='greyscale-done'||stage==='volume-done'?'calibration':null;
 const key=stage==='greyscale-done'?'grey':stage==='volume-done'?(data.item?.signal_format==='dv'?'dv-profile':'3d'):null;
 const live=phase&&data.live?.phase===phase&&(!key||data.live.key===key)?{...data.live,isLive:true}:null;
 // Keep earlier results on the page as saved measurements, never as live data.
 // A pre-sweep belongs here only while it is the active measurement.
 const saved=snapshots.filter(s=>s.phase==='post'||s.phase==='calibration');
 const hasLive=live&&pgAutomationGraphSnapshot(live,data.item).readings?.length;
 return [...saved.filter(s=>!(hasLive&&s.phase===live.phase&&s.key===live.key)),...(hasLive?[live]:[])];
}
async function pgAutomationRenderJobGraphs(view,state){
 if(!state.data)return;
 if(pgAutomation.reportBusy){pgAutomation.pendingJobGraphs=pgAutomation.pendingJobGraphs||{};pgAutomation.pendingJobGraphs[view]=state;return;}
 const target=pgAutomationJobTarget(view)?.querySelector('[data-job-graphs]');if(!target)return;
 const data=state.data,item=data.item,entries=[];
 const observer=view==='calibration';
 const live=data.live?{...data.live,snapshot:pgAutomationGraphSnapshot(data.live,item),isLive:true}:null;
 const sources=observer?pgAutomationCalibrationSnapshots(data):(data.snapshots||[]).filter(s=>!(live?.snapshot?.readings?.length&&s.key===live.key&&s.phase===live.phase));
 if(!observer&&live?.snapshot?.readings?.length)sources.push(live);
 const groupOrder={greyscale:0,'3d':1,'dv-profile':1,colors:2,saturations:3};
 const phaseOrder={pre:0,calibration:1,post:2};
 const snapshots=sources.map(s=>({...s,snapshot:pgAutomationGraphSnapshot(s,item)})).sort((a,b)=>
  ((groupOrder[pgAutomationGraphGroup(a.key)]??4)-(groupOrder[pgAutomationGraphGroup(b.key)]??4))||
  (String(pgAutomationGraphGroup(a.key)).localeCompare(String(pgAutomationGraphGroup(b.key))))||
  ((phaseOrder[a.phase]??3)-(phaseOrder[b.phase]??3))||String(a.key).localeCompare(String(b.key)));
 const hasAfterGrey=snapshots.some(s=>s.phase==='post'&&pgAutomationGraphGroup(s.key)==='greyscale'&&s.snapshot?.readings?.length);
 snapshots.forEach(s=>{
  if(hasAfterGrey&&s.phase==='calibration'&&s.key==='grey')return;
  if(!s.snapshot?.readings?.length||(s.phase==='pre'?!state.showBefore:!state.showAfter))return;
  const snap=s.snapshot;
  const label=s.phase==='pre'?(s.isLive?'Before (measuring)':'Before'):s.phase==='post'?(s.isLive?'After (measuring)':'After'):s.isLive?'Live calibration':'Saved calibration';
  const kind=s.key==='grey'?'1D LUT':s.key==='3d'?'3D LUT':s.key==='dv-profile'?'Dolby Vision profile':pgAutomationSeriesLabel(s.key);
  // A calibration-phase section is named for its stage alone: "Saved
  // calibration" is true of every one of them and crowds the index.
  entries.push({key:'m:'+s.phase+':'+s.key,name:s.phase==='calibration'?kind:label+' · '+kind,phase:s.phase,
   greyscale:pgAutomationGraphGroup(s.key)==='greyscale',isLive:!!s.isLive,title:label+' · '+kind,snapshot:snap});
 });
 // Render at least as wide as the destination, including the source card's
 // padding. The shared canvas renderer handles display pixel density/zoom.
 // Measure the panel, not the section body: a folded section has no width.
 const host=pgAutomationJobTarget(view);
 const renderWidth=Math.max(1100,Math.ceil(target.offsetWidth||(host?host.offsetWidth:0)||0)+80);
 state.renderWidth=renderWidth;
 const scale=[renderWidth,window.devicePixelRatio||1,typeof pgDesktopZoom==='number'?pgDesktopZoom:1];
 const signature=JSON.stringify([entries,...scale]);
 if(signature===state.graphSignature){pgAutomationPaintVerdict(view,state);return;}
 // Only the running stage's measurements can move mid-run, and rebuilding the
 // skeleton for them throws away every finished section's chart image. When
 // nothing structural changed, refresh that one stage in place instead.
 const structure=JSON.stringify([entries.map(e=>[e.key,e.name,e.phase,e.greyscale,e.isLive]),...scale]);
 const reuse=state.graphStructure===structure&&(state.entries||[]).length&&target.querySelector('details.auto-section');
 const changed=reuse?entries.filter(entry=>JSON.stringify(entry)!==JSON.stringify(state.entries.find(old=>old.key===entry.key))):entries;
 if(!entries.length){
  target.innerHTML='<p class="auto-muted">'+(observer?'No measurements for the current stage yet. '+pgAutomationEscape(pgAutomationStageLabel(data.active_stage||'Between stages'))+'. Previous-stage graphs are not shown as live.':!state.showBefore&&!state.showAfter?'Select a comparison to show graphs.':'No measured graph data is available for this selection yet.')+'</p>';
  state.entries=entries;state.graphStructure=structure;state.graphSignature=signature;
  state.sectionStats={};state.sectionBadges={};state.sectionLive={};state.verdictStats=[];state.totalReadings=0;
  pgAutomationPaintVerdict(view,state);pgAutomationRenderJobIndex(view,state);
  return;
 }
 if(typeof meterFullAutoCalBuildSnapshotReportSections!=='function'){target.textContent='The calibration chart renderer is unavailable. Reload the page to load it.';return;}
 pgAutomation.reportBusy=true;
 try{
  // Headline numbers for every stage, no canvas work. Charts are drawn later,
  // one section at a time, and only for sections somebody opened.
  const series={};
  const html=await meterFullAutoCalBuildSnapshotReportSections(changed,{summaryOnly:true,onSeries:(entry,value)=>{series[entry.key]=value;}});
  if(pgAutomation.jobViews[view]===state&&state.data===data){
   const template=document.createElement('template');template.innerHTML=html;
   const rendered=[...template.content.querySelectorAll('.report-section')];
   state.entries=entries;state.graphStructure=structure;
   if(!reuse){state.sectionStats={};state.sectionBadges={};state.sectionLive={};state.sectionSeries={};}
   Object.assign(state.sectionSeries,series);
   const built=rendered.map(section=>{
    const key=section.dataset.reportKey||'';
    const entry=entries.find(candidate=>candidate.key===key)||{};
    const parts=pgAutomationReportSectionParts(section);
    const count=Number(parts.count||0);
    state.sectionStats[key]={count,stats:parts.stats};
    const average=pgAutomationStatValue(parts.stats,/^Average (ΔE|Delta)/i);
    state.sectionBadges[key]=average?'ΔE '+average:(count?count+' readings':'');
    if(entry.isLive)state.sectionLive[key]={count,average:average||''};
    if(reuse){
     const existing=[...target.querySelectorAll('details.auto-section')].find(el=>el.dataset.sectionKey===key);
     if(existing){
      // A folded section keeps its charts, but must redraw when reopened.
      delete existing.dataset.chartsReady;
      const summary=existing.querySelector('.report-summary'),fresh=section.querySelector('.report-summary');
      if(summary&&fresh)summary.replaceWith(fresh);
      const figure=existing.querySelector('.auto-section-figure');
      if(figure)figure.innerHTML=entry.isLive?pgAutomationLiveFigureHtml(count,average):pgAutomationEscape(count?count+' readings':'No readings');
     }
    }
    return pgAutomationSection(key,entry.name||key,count?count+' readings':'No readings',parts.html,
     {defaultOpen:true,live:!!entry.isLive,figureHtml:entry.isLive?pgAutomationLiveFigureHtml(count,average):''});
   });
   // A renderer response with no sections in it is shown whole; measurements
   // are never dropped because this panel could not take them apart.
   if(!reuse)target.innerHTML=rendered.length?built.join(''):html;
   const phaseRank={post:3,calibration:2,pre:1};
   let total=0,verdict=null;
   entries.forEach(entry=>{
    const parts=state.sectionStats[entry.key];if(!parts)return;
    total+=parts.count;
    if(entry.greyscale&&parts.count&&(!verdict||(phaseRank[entry.phase]||0)>verdict.rank))verdict={rank:phaseRank[entry.phase]||0,stats:parts.stats};
   });
   state.graphSignature=signature;state.totalReadings=total;state.verdictStats=verdict?verdict.stats:[];
   const measured=pgAutomationStatValue(state.verdictStats,/^Average (ΔE|Delta)/i);
   pgAutomation.jobFigures=pgAutomation.jobFigures||{};
   if(measured)pgAutomation.jobFigures[state.runId+':'+state.index]='ΔE '+measured;
   else delete pgAutomation.jobFigures[state.runId+':'+state.index];
   pgAutomationPaintVerdict(view,state);pgAutomationRenderJobIndex(view,state);pgAutomationSyncLiveMark();
  }
 }catch(e){if(pgAutomation.jobViews[view]===state)target.textContent='Unable to summarise measurements: '+e.message;}
 finally{
  pgAutomation.reportBusy=false;
  pgAutomationDrainReports();
  if(pgAutomation.jobViews[view]===state)target.querySelectorAll('details.auto-section[open]').forEach(section=>pgAutomationRenderSectionCharts(view,section));
 }
}
function pgAutomationPaintVerdict(view,state){
 const strip=pgAutomationJobTarget(view)?.querySelector('[data-job-verdict]');
 if(strip)strip.innerHTML=pgAutomationVerdictHtml(state);
}
function pgAutomationDrainReports(){
 const graphs=pgAutomation.pendingJobGraphs||{};pgAutomation.pendingJobGraphs={};
 Object.entries(graphs).forEach(([nextView,nextState])=>{if(pgAutomation.jobViews[nextView]===nextState)pgAutomationRenderJobGraphs(nextView,nextState);});
 const sections=pgAutomation.pendingSections||[];pgAutomation.pendingSections=[];
 sections.forEach(pending=>{
  const host=pgAutomationJobTarget(pending.view);
  const section=host?[...host.querySelectorAll('details.auto-section')].find(el=>el.dataset.sectionKey===pending.key):null;
  if(section&&section.open)pgAutomationRenderSectionCharts(pending.view,section);
 });
}
// Draw one stage's charts. Each call drives the real calibration canvases
// off-screen through the shared report mutex, so it must stay one at a time.
async function pgAutomationRenderSectionCharts(view,sectionEl){
 const state=pgAutomation.jobViews[view];
 if(!state||!sectionEl||!sectionEl.isConnected)return;
 if(sectionEl.dataset.chartsReady==='1'||sectionEl.dataset.chartsBusy==='1')return;
 const key=sectionEl.dataset.sectionKey||'';
 const entry=(state.entries||[]).find(candidate=>candidate.key===key);
 if(!entry||typeof meterFullAutoCalBuildSnapshotReportSections!=='function')return;
 if(pgAutomation.reportBusy){
  pgAutomation.pendingSections=pgAutomation.pendingSections||[];
  if(!pgAutomation.pendingSections.some(pending=>pending.view===view&&pending.key===key))pgAutomation.pendingSections.push({view,key});
  return;
 }
 const body=sectionEl.querySelector('.auto-section-body');
 if(!body)return;
 const data=state.data;
 const previousWidth=document.body.style.getPropertyValue('--automation-report-width');
 try{
  sectionEl.dataset.chartsBusy='1';
  pgAutomation.reportBusy=true;
  document.body.style.setProperty('--automation-report-width',(state.renderWidth||1100)+'px');
  document.body.classList.add('pg-automation-report-render');
  let series=null;
  const html=await meterFullAutoCalBuildSnapshotReportSections([entry],{onSeries:(_entry,value)=>{series=value;}});
  if(pgAutomation.jobViews[view]===state&&state.data===data&&sectionEl.isConnected){
   const template=document.createElement('template');template.innerHTML=html;
   const rendered=template.content.querySelector('.report-section');
   const parts=rendered?pgAutomationReportSectionParts(rendered):null;
   body.innerHTML=parts?parts.html:html;
   if(rendered)pgAutomationFoldCharts(body);
   if(entry.isLive){
    // The shared renderer has already restored the manual series. Use only
    // the snapshot captured while this chart's saved context was installed.
    state.sectionLive=state.sectionLive||{};
    state.sectionLive[key]={count:Number(parts&&parts.count)||0,
     average:(parts?pgAutomationStatValue(parts.stats,/^Average (ΔE|Delta)/i):'')||''};
    if(series){state.sectionSeries=state.sectionSeries||{};state.sectionSeries[key]=series;}
   }
   sectionEl.dataset.chartsReady='1';
   if(entry.isLive)pgAutomationSyncLiveMark();
   pgAutomationQueueIndex(view,state);
  }
 }catch(e){
  if(sectionEl.isConnected)body.insertAdjacentHTML('beforeend','<p class="auto-muted" role="status">Unable to draw these measurements: '+pgAutomationEscape(e.message)+'</p>');
 }
 finally{
  delete sectionEl.dataset.chartsBusy;
  document.body.classList.remove('pg-automation-report-render');pgAutomation.reportBusy=false;
  if(previousWidth)document.body.style.setProperty('--automation-report-width',previousWidth);
  else document.body.style.removeProperty('--automation-report-width');
  pgAutomationDrainReports();
 }
}

// Rebuild snapshots after a window/screen change, even if measurements have
// not changed. Reuse saved job data; resizing must never make device requests.
if(typeof window!=='undefined')window.addEventListener('resize',event=>{
 if(event.pgHeightOnlyTabletResize)return;
 clearTimeout(pgAutomation.graphResizeTimer);
 pgAutomation.graphResizeTimer=setTimeout(()=>{
  Object.entries(pgAutomation.jobViews||{}).forEach(([view,state])=>{
   const target=pgAutomationJobTarget(view);
   if(target&&target.getBoundingClientRect().width>0)pgAutomationRenderJobGraphs(view,state);
  });
 },200);
});

function pgAutomationHistoryItemHtml(item,index){
 const apply=item&&item['apply-all'];
 const quality=item&&(item.quality_result||item.quality);
 const panel=item&&item['panel-light'];
 const warningList=Array.isArray(item&&item.warnings)?item.warnings:[];
 const details=[pgAutomationEscape(item&&item.status||''),((item&&item.checkpoints)||[]).filter(x=>x&&x.status==='done').length+' checkpoints'];
 if(warningList.length)details.push(warningList.length+' warnings: '+pgAutomationEscape(warningList.map(w=>typeof w==='string'?pgAutomationIssueText(w):[w.code,w.series,w.message].filter(Boolean).join(': ')).join(', ')));
 if(apply)details.push(apply.outcome==='sent-unconfirmed'&&apply.confirmation_unavailable?'Apply to All Inputs sent — confirmation unavailable on this TV.':'Apply to all: '+pgAutomationEscape(apply.outcome||apply.status||'unverified'));
 if(quality&&quality.warnings&&quality.warnings.length)details.push('Quality limits: '+quality.warnings.length+' miss'+(quality.warnings.length===1?'':'es'));
 const base=item&&item.item_number!=null?item.item_number:index;
 const qualityRows=quality?.enabled?Object.entries(quality.series||{}).map(([key,result])=>'<tr><td>'+pgAutomationEscape(pgAutomationSeriesLabel(key))+'</td><td>'+(result.average==null?'Unavailable':Number(result.average).toFixed(2))+'</td><td>'+(result.maximum==null?'Unavailable':Number(result.maximum).toFixed(2))+'</td><td>'+(result.passed==null?'Unverified':result.passed?'Pass':'Limit missed')+'</td></tr>').join(''):'';
 return '<div style="padding:12px 0;border-top:1px solid var(--border)"><strong>Item '+(index+1)+': '+pgAutomationEscape(item&&item.name||item&&item.picture_mode||'')+'</strong>'+pgAutomationItemSummary(item)+'<p style="color:var(--text2)">'+details.join(' · ')+'</p>'+pgAutomationJobFailureHtml(item)+(qualityRows?'<table><thead><tr><th>Sweep</th><th>Average ΔE</th><th>Maximum ΔE</th><th>Quality</th></tr></thead><tbody>'+qualityRows+'</tbody></table>':'')+'<div class="btn-row" style="margin-top:8px"><a class="btn btn-sm btn-secondary" href="/api/automation/runs/'+encodeURIComponent(pgAutomation.currentHistoryRunId||'')+'/artifact/items/'+base+'/settings-checks.ndjson" target="_blank" rel="noopener">Settings Checks</a></div></div>';
}

async function pgAutomationBuildHistoryReport(run){
 const target=document.getElementById('pgAutomationHistoryReport');
 if(!target||typeof meterFullAutoCalBuildSnapshotReportSections!=='function')return;
 if(pgAutomation.reportBusy){pgAutomation.pendingHistoryRun=run;return;}
 pgAutomation.reportBusy=true;
 const entries=[];
 const runId=String(run&&run.id||pgAutomation.currentHistoryRunId||'');
 const seriesRequests=[];
 (run.items||[]).forEach((item,index)=>{
  const calibration=item&&item.calibration||{};
  const grey=calibration['grey-state'];
  if(grey&&Array.isArray(grey.readings)&&grey.readings.length)entries.push({title:'Item '+(index+1)+' Calibration Greyscale',snapshot:grey});
  const volume=calibration['3d-state'];
  if(volume&&Array.isArray(volume.readings)&&volume.readings.length)entries.push({title:'Item '+(index+1)+' 3D LUT measurements',snapshot:{...volume,type:'colors',points:volume.readings.length,signal_mode:item.signal_format,target_gamma:item.target_gamma}});
  ['pre','post'].forEach(stage=>{
   if(item.stages&&item.stages[stage+'_readings']!=null&&!item.stages[stage+'_readings'])return;
   (item[stage+'_series']||['greyscale-21','colors-30','saturations-24']).forEach(key=>{
    seriesRequests.push({
     title:'Item '+(index+1)+' '+(stage==='pre'?'Pre-Cal ':'Post-Cal ')+key,
     path:'/api/automation/runs/'+encodeURIComponent(runId)+'/artifact/items/'+index+'/'+stage+'/'+key+'.json'
    });
   });
  });
 });
 try{
  const snapshots=await Promise.all(seriesRequests.map(request=>fetchJSON(request.path,{_quiet:true,_timeoutMs:30000})));
  seriesRequests.forEach((request,index)=>entries.push({title:request.title,snapshot:snapshots[index]||null}));
  if(pgAutomation.currentHistoryRunId!==runId)return;
  // The shared renderer snapshots real canvases. Give its hidden workspace a
  // layout off-screen without navigating away from Automation or touching TV state.
  document.body.classList.add('pg-automation-report-render');
  let html;
  try{html=await meterFullAutoCalBuildSnapshotReportSections(entries);}
  finally{document.body.classList.remove('pg-automation-report-render');}
  if(pgAutomation.currentHistoryRunId===runId)target.innerHTML=html||'<div style="color:var(--text2)">No graph data was saved for this run.</div>';
 }catch(e){target.innerHTML='<div style="color:var(--red)">Unable to render saved graphs: '+pgAutomationEscape(e.message||e)+'</div>';}
 finally{pgAutomation.reportBusy=false;if(pgAutomation.pendingHistoryRun){const pending=pgAutomation.pendingHistoryRun;pgAutomation.pendingHistoryRun=null;pgAutomationBuildHistoryReport(pending);}}
}

async function pgAutomationDeleteRun(index){
 const run=pgAutomation.history[index];
 if(!run||!await pgAutomationConfirm('Delete this run and its saved results? This cannot be undone.','Delete run'))return;
 const result=await fetchJSON('/api/automation/runs/'+encodeURIComponent(run.id)+'/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
 if(!result||result.status==='error'){pgAutomationNotice((result&&result.message)||'Unable to delete run',true);return;}
 const detail=document.getElementById('pgAutomationHistoryDetail');if(detail)detail.innerHTML='';
 await pgAutomationRefresh();
}

function pgAutomationTabKey(event){
 const tabs=[...document.querySelectorAll('#automationCard [data-auto-tab]')],current=tabs.indexOf(event.target);
 if(current<0||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
 event.preventDefault();
 const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(current+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;
 pgAutomationTab(tabs[next].dataset.autoTab);tabs[next].focus();
}
function pgAutomationTab(tab){
 pgAutomationDragCancel();
 ['recipes','queue','live','history'].forEach(name=>{const el=document.getElementById('pgAutomationTab'+name.charAt(0).toUpperCase()+name.slice(1));if(el)el.style.display=name===tab?'':'none';});
 pgAutomation.tab=tab;
 pgAutomationRenderActivity();
 document.querySelectorAll('[data-auto-tab]').forEach(el=>{const selected=el.getAttribute('data-auto-tab')===tab;el.setAttribute('aria-selected',String(selected));el.tabIndex=selected?0:-1;});
 if(tab==='history')pgAutomationRefresh();
 if(tab==='live')pgAutomationPollLive();
}

async function pgAutomationRefresh(){
 // The live poll owns run state. Do not hold it behind history loading or
 // overwrite a newer poll with the result of an older bulk refresh.
 pgAutomationPollLive();
 if(pgAutomation.refreshing)return pgAutomation.refreshing;
 const pending=(async()=>{
 const responses=await Promise.all([
  fetchJSON('/api/automation/recipes',{_quiet:true,_timeoutMs:5000}),
  fetchJSON('/api/automation/queues',{_quiet:true,_timeoutMs:5000}),
  // Saved manifests can take longer than a live-status poll on the Pi.
  fetchJSON('/api/automation/runs',{_quiet:true,_timeoutMs:30000})
 ]);
 if(responses[0]&&Array.isArray(responses[0].recipes))pgAutomation.recipes=responses[0].recipes;
 if(responses[1]&&Array.isArray(responses[1].queues))pgAutomation.queues=responses[1].queues;
 if(responses[2]&&responses[2].status!=='error'&&Array.isArray(responses[2].runs)){
  pgAutomation.history=responses[2].runs;pgAutomation.historyError='';
  // After an update the server adds job digests to old runs a few at a time;
  // keep refreshing History until every row has one.
  const pending=pgAutomation.history.some(run=>run.digest_pending);
  pgAutomation.digestRetries=pending?(pgAutomation.digestRetries||0)+1:0;
  if(pending&&pgAutomation.tab==='history'&&pgAutomation.digestRetries<=40)setTimeout(()=>{if(pgAutomation.tab==='history')pgAutomationRefresh();},1500);
 }else pgAutomation.historyError='Cannot load saved runs. Any results shown below are from the last successful refresh.';
 pgAutomationRenderRecipeList();
 pgAutomationRenderSavedQueues();
 pgAutomationRenderQueue();
 pgAutomationRenderHistoryList();
 })();
 pgAutomation.refreshing=pending;
 try{await pending;}finally{if(pgAutomation.refreshing===pending)pgAutomation.refreshing=null;}
}

function pgAutomationInit(){
 if(pgAutomation.loaded)return;pgAutomation.loaded=true;
 try{const saved=JSON.parse(localStorage.getItem('pgen.automation.queueDraft')||'null');if(saved&&Array.isArray(saved.queue?.items)){saved.queue.items=saved.queue.items.map(pgAutomationSnapshot);pgAutomation.queue=saved.queue;pgAutomation.editingRunId=saved.editingRunId||'';pgAutomation.firstPending=saved.firstPending||0;pgAutomation.selectedQueue=saved.selectedQueue||'';pgAutomation.loadedQueueSnapshot=saved.loadedQueueSnapshot||'';}}catch(e){}
 pgAutomationRenderQueue();pgAutomationRenderRecipeList();pgAutomationRenderSavedQueues();
 pgAutomationRefresh();pgAutomationTab('queue');pgAutomationPollLive();
 if(!pgAutomation.clockTimer)pgAutomation.clockTimer=setInterval(pgAutomationTickProgress,1000);
}
setTimeout(pgAutomationInit,0);

let lgStatusPending=false;
let lgLastPinPending=false;
let lgDetectedPromptShown=false;
let lgPictureModePending=false;
let lgApplyAllInputsPending=false;
let lgPictureModeValue='';
let lgPictureModeSignalMode='';
let lgPictureModeRefreshTimer=null;
let lgScanPending=false;
let lgCalibrationModePending=false;
window.lgStatusState=window.lgStatusState||{paired:false,connected:false,disconnected:false,detected:false,hasIp:false,checked:false,clientKeyPresent:false,pinPending:false};

function lgStatusHasSavedKey(state){
 state=state||{};
 return !!(state.clientKeyPresent||state.client_key_present||state.paired);
}

function lgStatusConnected(state){
 state=state||{};
 if(Object.prototype.hasOwnProperty.call(state,'connected')) return !!state.connected&&!state.pinPending;
 return !!(lgStatusHasSavedKey(state)&&!state.pinPending&&!state.disconnected);
}

function lgRenderCurrentInput(){
 const el=document.getElementById('lgCurrentInput');
 if(!el) return;
 const state=window.lgStatusState||{};
 if(!lgStatusConnected(state)){
  el.textContent='Connect display';
  el.style.color='var(--text2)';
  el.title='';
  return;
 }
 if(!state.currentInputChecked){
  el.textContent='Checking...';
  el.style.color='var(--text2)';
  el.title='';
  return;
 }
 el.textContent=state.currentInputDisplay||'Not reported by TV';
 el.style.color=state.currentInputDisplay?'var(--text)':'var(--orange)';
 el.title=state.currentAppId?('WebOS app: '+state.currentAppId):'';
}

function lgUpdateCurrentInput(r){
 if(!r||!r.current_input_checked) return;
 const state=window.lgStatusState||{};
 state.currentInputChecked=true;
 state.currentInputDisplay=String(r.current_input_display||'').trim();
 state.currentInput=String(r.current_input||'').trim();
 state.currentInputId=String(r.current_input_id||'').trim();
 state.currentInputLabel=String(r.current_input_label||'').trim();
 state.currentAppId=String(r.current_app_id||'').trim();
 state.currentInputMessage=String(r.current_input_message||'').trim();
 state.currentInputUpdatedAt=Date.now();
 window.lgStatusState=state;
 lgRenderCurrentInput();
}

function lgIsPGeneratorDisplayName(name){
 const normalized=String(name||'').trim().toLowerCase().replace(/[\s_-]+/g,'');
 return /^(?:pgenerator|pgeneratorplus|pgenerator\+)$/.test(normalized);
}

function lgDisplayNameFromStatus(r){
 const candidates=[
  r&&r.model_name,
  r&&r.modelName,
  r&&r.product_name,
  r&&r.productName,
  r&&r.displayName,
  r&&r.stored_name,
  r&&r.cec_osd_name,
  r&&r.cec_tv_name
 ];
 for(const candidate of candidates){
  const name=String(candidate||'').trim();
  if(name&&!lgIsPGeneratorDisplayName(name)) return name;
 }
 return 'LG TV';
}

function renderLgTopStatus(r){
 const wrap=document.getElementById('lgTopStatusWrap');
 const dot=document.getElementById('lgTopDot');
 const text=document.getElementById('lgTopStatusText');
 if(!wrap||!dot||!text) return;
 const paired=lgStatusConnected(r);
 const pinPending=!!(r&&(r.pin_pairing_pending||r.pinPending));
 if(!paired||pinPending){
  wrap.style.display='none';
  if(typeof syncTopStatusStack==='function') syncTopStatusStack();
  return;
 }
 const rawName=lgDisplayNameFromStatus(r);
 const ip=String((r&&(r.manual_ip||r.stored_ip||r.auto_ip||r.ip))||'').trim();
 const name=rawName;
 const label=name+(ip?' ['+ip+']':'');
 const power=String((r&&(r.tv_power||r.tvPower))||'').trim();
 const powerKey=power.toLowerCase();
 dot.style.background=/^(off|standby)$/.test(powerKey)?'var(--orange)':'var(--green)';
 text.textContent=label;
 text.style.color='var(--text)';
 wrap.title='Display: '+label+(power?(' | Power: '+power):'');
 wrap.style.display='flex';
 if(typeof syncTopStatusStack==='function') syncTopStatusStack();
}

// Values are the raw webOS pictureMode tokens. Their spellings are stable
// across the captured C8..G5 settings inventories (the SDR "Standard"
// preset is "normal", "Auto Power Save" is "eco") but the set grows per
// generation: filmMaker is CX+, personalized*/hdrEco are C2+. Labels
// abbreviate the TV's own menu names (G3 menu, 30 July 2026).
const LG_PICTURE_MODES_BY_SIGNAL={
 sdr:[
  ['expert1','SDR Expert Bright'],
  ['expert2','SDR Expert Dark'],
  ['cinema','SDR Cinema'],
  ['filmMaker','SDR Filmmaker'],
  ['game','SDR Game Optimizer'],
  ['normal','SDR Standard'],
  ['eco','SDR Auto Power Save'],
  ['sports','SDR Sports'],
  ['vivid','SDR Vivid'],
  ['personalized','SDR Personalised Picture']
 ],
 hdr10:[
  ['hdrCinema','HDR Cinema'],
  ['hdrCinemaBright','HDR Cinema Home'],
  ['hdrFilmMaker','HDR Filmmaker'],
 ['hdrGame','HDR Game Optimizer'],
  ['hdrStandard','HDR Standard'],
  ['hdrEco','HDR Auto Power Save'],
  ['hdrVivid','HDR Vivid'],
  ['hdrPersonalized','HDR Personalised Picture']
 ],
 hlg:[
  ['hdrCinema','HLG Cinema'],
  ['hdrCinemaBright','HLG Cinema Home'],
  ['hdrFilmMaker','HLG Filmmaker'],
  ['hdrGame','HLG Game Optimizer'],
  ['hdrStandard','HLG Standard'],
  ['hdrEco','HLG Auto Power Save'],
  ['hdrVivid','HLG Vivid'],
  ['hdrPersonalized','HLG Personalised Picture']
 ],
 // Operator-confirmed real preset list for this generation's Dolby Vision
 // menu (2026-07-24, LG C2/webOS4.1.0): Cinema Home, Filmmaker, Game
 // Optimizer, Vivid, Standard -- no separate "Cinema" distinct from "Cinema
 // Home" exists. The prior list (DV Cinema / DV Cinema Home / DV Game
 // Optimizer / DV Vivid) was an unconfirmed guess that included a
 // non-existent "Cinema" entry and was missing Filmmaker and Standard.
 dv:[
  ['dolbyVisionCinemaBright','DV Cinema Home'],
  ['dolbyVisionFilmMaker','DV Filmmaker'],
  ['dolbyVisionGame','DV Game Optimizer'],
  ['dolbyVisionVivid','DV Vivid'],
  ['dolbyVisionStandard','DV Standard'],
  // Personalised Picture is NOT part of the 2026-07-24 operator
  // confirmation above -- added later for current-generation menus that
  // expose it; readback-verified selection still gates it like any other.
  ['dolbyVisionPersonalized','DV Personalised Picture']
 ]
};

// C8/C9 use the older Technicolor family and do not expose Filmmaker or
// Personalised Picture. Their dark DV reference preset is called Cinema.
const LG_2018_2019_PICTURE_MODES_BY_SIGNAL={
 sdr:[
  ['expert1','SDR Expert Bright'],
  ['expert2','SDR Expert Dark'],
  ['cinema','SDR Cinema'],
  ['technicolor','SDR Technicolor Expert'],
  ['game','SDR Game'],
  ['normal','SDR Standard'],
  ['eco','SDR Auto Power Save'],
  ['sports','SDR Sports'],
  ['vivid','SDR Vivid']
 ],
 hdr10:[
  ['hdrCinema','HDR Cinema'],
  ['hdrCinemaBright','HDR Cinema Home'],
  ['hdrTechnicolor','HDR Technicolor Expert'],
  ['hdrGame','HDR Game'],
  ['hdrStandard','HDR Standard'],
  ['hdrVivid','HDR Vivid']
 ],
 hlg:[
  ['hdrCinema','HLG Cinema'],
  ['hdrCinemaBright','HLG Cinema Home'],
  ['hdrTechnicolor','HLG Technicolor Expert'],
  ['hdrGame','HLG Game'],
  ['hdrStandard','HLG Standard'],
  ['hdrVivid','HLG Vivid']
 ],
 dv:[
  ['dolbyVisionFilmMaker','DV Cinema'],
  ['dolbyVisionCinemaBright','DV Cinema Home'],
  ['dolbyVisionGame','DV Game'],
  ['dolbyVisionStandard','DV Standard'],
  ['dolbyVisionVivid','DV Vivid']
 ]
};

// CX/C1 predate the C2+ Personalised Picture and HDR Auto Power Save modes.
// They also call their dark DV reference preset Cinema. Keep the proven
// dark-reference calibration value and change only its visible UI label.
const LG_PRE2022_PICTURE_MODES_BY_SIGNAL={
 sdr:[
  ['expert1','SDR Expert Bright'],
  ['expert2','SDR Expert Dark'],
  ['cinema','SDR Cinema'],
  ['filmMaker','SDR Filmmaker'],
  ['game','SDR Game Optimizer'],
  ['normal','SDR Standard'],
  ['eco','SDR Auto Power Save'],
  ['sports','SDR Sports'],
  ['vivid','SDR Vivid']
 ],
 hdr10:[
  ['hdrCinema','HDR Cinema'],
  ['hdrCinemaBright','HDR Cinema Home'],
  ['hdrFilmMaker','HDR Filmmaker'],
  ['hdrGame','HDR Game Optimizer'],
  ['hdrStandard','HDR Standard'],
  ['hdrVivid','HDR Vivid']
 ],
 hlg:[
  ['hdrCinema','HLG Cinema'],
  ['hdrCinemaBright','HLG Cinema Home'],
  ['hdrFilmMaker','HLG Filmmaker'],
  ['hdrGame','HLG Game Optimizer'],
  ['hdrStandard','HLG Standard'],
  ['hdrVivid','HLG Vivid']
 ],
 dv:[
  ['dolbyVisionFilmMaker','DV Cinema'],
  ['dolbyVisionCinemaBright','DV Cinema Home'],
  ['dolbyVisionGame','DV Game Optimizer'],
  ['dolbyVisionStandard','DV Standard'],
  ['dolbyVisionVivid','DV Vivid']
 ]
};

const LG_DISPLAY_CONTROL_ITEMS=[
 {key:'brightness',label:'Brightness',type:'number',min:0,max:100,step:1},
 {key:'contrast',label:'Contrast',type:'number',min:0,max:100,step:1},
 {key:'blackLevel',label:'Black Level / Range',type:'select',options:['auto','low','high','limited','full']},
 {key:'blackLevelAdjust',label:'Black Level Adjust',type:'number',min:0,max:100,step:1},
 {key:'backlight',label:'Backlight',type:'number',min:0,max:100,step:1},
 {key:'oledLight',label:'OLED Light',type:'number',min:0,max:100,step:1},
 {key:'oledPixelBrightness',label:'OLED Pixel Brightness',type:'number',min:0,max:100,step:1},
 {key:'peakBrightness',label:'Peak Brightness',type:'select',options:['off','low','medium','high']},
 {key:'color',label:'Color',type:'number',min:0,max:100,step:1},
 {key:'colorDepth',label:'Color Depth',type:'number',min:0,max:100,step:1},
 {key:'tint',label:'Tint',type:'number',min:0,max:100,step:1},
 {key:'sharpness',label:'Sharpness',type:'number',min:0,max:100,step:1},
 {key:'hSharpness',label:'H Sharpness',type:'number',min:0,max:100,step:1},
 {key:'vSharpness',label:'V Sharpness',type:'number',min:0,max:100,step:1},
 {key:'gamma',label:'Gamma',type:'select',options:['1.9','2.2','2.4','bt1886','BT.1886']},
 {key:'colorTemperature',label:'Color Temperature',type:'select',options:['cool','medium','warm','warm1','warm2','warm3','expert1','expert2']},
 {key:'colorGamut',label:'Color Gamut',type:'select',options:['auto','native','extended','wide']},
 {key:'energySaving',label:'Energy Saving',type:'select',options:['off','minimum','medium','maximum','auto','screenOff']},
 {key:'dynamicContrast',label:'Dynamic Contrast',type:'select',options:['off','low','medium','high']},
 {key:'dynamicColor',label:'Dynamic Color',type:'select',options:['off','low','medium','high']},
 {key:'localDimming',label:'Local Dimming',type:'select',options:['off','low','medium','high']},
 {key:'noiseReduction',label:'Noise Reduction',type:'select',options:['off','low','medium','high','auto']},
 {key:'mpegNoiseReduction',label:'MPEG Noise Reduction',type:'select',options:['off','low','medium','high','auto']},
 {key:'smoothGradation',label:'Smooth Gradation',type:'select',options:['off','low','medium','high']},
 {key:'superResolution',label:'Super Resolution',type:'select',options:['off','low','medium','high']},
 {key:'realCinema',label:'Real Cinema',type:'select',options:['off','on']},
 {key:'eyeComfortMode',label:'Eye Comfort Mode',type:'select',options:['off','on']},
 {key:'blackFrameInsertion',label:'Black Frame Insertion',type:'select',options:['off','low','medium','high']},
 {key:'truMotionMode',label:'TruMotion Mode',type:'select',options:['off','cinematicMovement','natural','smooth','user']},
 {key:'deJudder',label:'De-Judder',type:'number',min:0,max:10,step:1},
 {key:'deBlur',label:'De-Blur',type:'number',min:0,max:10,step:1}
];
const LG_DISPLAY_CONTROL_KEYS=LG_DISPLAY_CONTROL_ITEMS.map(item=>item.key);
let lgDisplayControlPending=false;
let lgDisplayControlValues={};
let lgDisplayControlCapabilities={supportedKeys:[],unsupportedKeys:{}};
let lgDisplayControlLoaded=false;
let lgDisplayControlError='';

function lgEscapeHtml(value){
 return String(value==null?'':value).replace(/[&<>"']/g,(ch)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}

function lgSignalModeKey(){
 const sm=String((document.getElementById('signal_mode')||{}).value||'sdr').toLowerCase();
 if(sm==='dv') return 'dv';
 if(sm==='hlg') return 'hlg';
 if(sm==='hdr10') return 'hdr10';
 return 'sdr';
}

function lgUsesPre2022PictureModeMap(){
 const state=window.lgStatusState||{};
 const model=String(state.modelName||state.model_name||state.displayName||'').toUpperCase();
 return /OLED\d*(?:A|B|C|E|G|R|W|Z)(?:8|9|X|1)(?!\d)/.test(model);
}

function lgUses2018Or2019PictureModeMap(){
 const state=window.lgStatusState||{};
 const model=String(state.modelName||state.model_name||state.displayName||'').toUpperCase();
 return /OLED\d*(?:A|B|C|E|G|R|W|Z)(?:8|9)/.test(model);
}

function lgPictureModesForSignal(signalMode){
 const signal=String(signalMode||'sdr');
 if(lgUses2018Or2019PictureModeMap()&&LG_2018_2019_PICTURE_MODES_BY_SIGNAL[signal]){
  return LG_2018_2019_PICTURE_MODES_BY_SIGNAL[signal];
 }
 if(lgUsesPre2022PictureModeMap()&&LG_PRE2022_PICTURE_MODES_BY_SIGNAL[signal]){
  return LG_PRE2022_PICTURE_MODES_BY_SIGNAL[signal];
 }
 return LG_PICTURE_MODES_BY_SIGNAL[signal]||LG_PICTURE_MODES_BY_SIGNAL.sdr;
}

function lgPictureModeEntries(){
 return [
  ...LG_PICTURE_MODES_BY_SIGNAL.sdr,
  ...LG_PICTURE_MODES_BY_SIGNAL.hdr10,
  ...LG_PICTURE_MODES_BY_SIGNAL.dv,
  ...LG_2018_2019_PICTURE_MODES_BY_SIGNAL.sdr,
  ...LG_2018_2019_PICTURE_MODES_BY_SIGNAL.hdr10,
  ...LG_2018_2019_PICTURE_MODES_BY_SIGNAL.dv,
  ...LG_PRE2022_PICTURE_MODES_BY_SIGNAL.sdr,
  ...LG_PRE2022_PICTURE_MODES_BY_SIGNAL.hdr10,
  ...LG_PRE2022_PICTURE_MODES_BY_SIGNAL.dv
 ];
}

function lgPictureModeToken(value){
 return String(value||'').trim().replace(/[\s_-]+/g,'').toLowerCase();
}

function lgPictureModeCanonicalValue(value){
 const raw=String(value||'').trim();
 if(!raw) return '';
 const exact=lgPictureModeEntries().find(item=>item[0]===raw);
 if(exact) return exact[0];
 const token=lgPictureModeToken(raw);
 const aliases={
  isfexpert1:'expert1',
  isfexpertbright:'expert1',
  expertbright:'expert1',
  isfexpert2:'expert2',
  isfexpertdark:'expert2',
  expertdark:'expert2',
  isfdarkroom:'expert2',
  isfdark:'expert2',
  darkroom:'expert2',
  brightroom:'expert1',
  filmmaker:'filmMaker',
  filmmakermode:'filmMaker',
  filmlmakermode:'filmMaker',
  filmlmaker:'filmMaker',
  filmlmak:'filmMaker',
  filmlmamaker:'filmMaker',
  filmamker:'filmMaker',
  gameoptimizer:'game',
  technicolorexpert:'technicolor',
  hdrcinema:'hdrCinema',
  hdr_cinema:'hdrCinema',
  hdrfilmamker:'hdrFilmMaker',
  hdrfilmmaker:'hdrFilmMaker',
  hdr_filmmaker:'hdrFilmMaker',
  hdr_filmmakermode:'hdrFilmMaker',
  hdrfilmmakermode:'hdrFilmMaker',
  hdrgame:'hdrGame',
  hdr_game:'hdrGame',
  hdrgameoptimizer:'hdrGame',
  hdrstandard:'hdrStandard',
  hdr_standard:'hdrStandard',
  hdreco:'hdrEco',
  hdr_eco:'hdrEco',
  hdrautopowersave:'hdrEco',
  hdrvivid:'hdrVivid',
  hdr_vivid:'hdrVivid',
  hdrtechnicolorexpert:'hdrTechnicolor',
  hdr_technicolorexpert:'hdrTechnicolor',
  dolbyvisioncinema:lgUsesPre2022PictureModeMap()?'dolbyVisionFilmMaker':'dolbyVisionCinema',
  dolby_hdr_cinema:lgUsesPre2022PictureModeMap()?'dolbyVisionFilmMaker':'dolbyVisionCinema',
  // The dark-reference mode is called Cinema on C9/CX/C1 and Filmmaker on
  // C2+. Both use the proven dolbyVisionFilmMaker calibration value; the
  // generation-specific options above supply the correct visible label.
  dolbyhdrcinema:'dolbyVisionFilmMaker',
  dolbyvisioncinemahome:'dolbyVisionCinemaBright',
  dolbyvisioncinemabright:'dolbyVisionCinemaBright',
  dolby_hdr_cinema_bright:'dolbyVisionCinemaBright',
  dolbyhdrcinemabright:'dolbyVisionCinemaBright',
  dolbyhdrcinemahome:'dolbyVisionCinemaBright',
  dolbyhdrgame:'dolbyVisionGame',
  dolby_hdr_game:'dolbyVisionGame',
  dolbyvisiongame:'dolbyVisionGame',
  dolbyhdrgameoptimizer:'dolbyVisionGame',
  dolbyvisiongameoptimizer:'dolbyVisionGame',
  dolbyvisionvivid:'dolbyVisionVivid',
  dolbyhdrvivid:'dolbyVisionVivid',
  dolby_hdr_vivid:'dolbyVisionVivid',
  dolbyvisionfilmmaker:'dolbyVisionFilmMaker',
  dolbyhdrfilmmaker:'dolbyVisionFilmMaker',
  dolby_hdr_filmmaker:'dolbyVisionFilmMaker',
  dolbyvisionfilmmakermode:'dolbyVisionFilmMaker',
  dolbyhdrfilmmakermode:'dolbyVisionFilmMaker',
  // Operator-confirmed on real hardware (LG C2, webOS 4.1.0, 2026-07-24):
  // the TV's own "Filmmaker" preset lives under the webOS picture mode
  // webOS itself calls "CinemaDark" -- so the TV reports "dolbyHdrCinemaDark"
  // when it is actually sitting in Filmmaker mode, and that must canonicalize
  // to dolbyVisionFilmMaker (not an orphaned "Cinema Dark" that has no
  // corresponding dropdown entry).
  dolbyvisioncinemadark:'dolbyVisionFilmMaker',
  dolbyhdrcinemadark:'dolbyVisionFilmMaker',
  dolby_hdr_cinema_dark:'dolbyVisionFilmMaker',
  dolbycinemadark:'dolbyVisionFilmMaker',
  dolbyvisionstandard:'dolbyVisionStandard',
  dolbyhdrstandard:'dolbyVisionStandard',
  dolby_hdr_standard:'dolbyVisionStandard',
  standard:'normal',
  aps:'eco',
  autopowersave:'eco',
  personalised:'personalized',
  personalizedpicture:'personalized',
  personalisedpicture:'personalized',
  hdrpersonalised:'hdrPersonalized',
  hdr_personalized:'hdrPersonalized',
  hdr_personalised:'hdrPersonalized',
  hdrpersonalizedpicture:'hdrPersonalized',
  hdrpersonalisedpicture:'hdrPersonalized',
  dolbyvisionpersonalised:'dolbyVisionPersonalized',
  dolbyhdrpersonalized:'dolbyVisionPersonalized',
  dolbyhdrpersonalised:'dolbyVisionPersonalized',
  dolby_hdr_personalized:'dolbyVisionPersonalized',
  dolbypersonalized:'dolbyVisionPersonalized',
  dolbypersonalised:'dolbyVisionPersonalized'
 };
 if(aliases[token]) return aliases[token];
 const normalized=lgPictureModeEntries().find(item=>lgPictureModeToken(item[0])===token);
 return normalized?normalized[0]:raw;
}

function lgPictureModeEffectiveSignal(current){
 const configured=lgSignalModeKey();
 const modeSignal=lgPictureModeSignalForValue(current||lgPictureModeValue);
 if(modeSignal==='hdr10'&&configured==='hlg') return 'hlg';
 return modeSignal||configured;
}

function lgPictureModeStorageKey(signalMode){
 return 'lgPictureMode:'+String(signalMode||lgSignalModeKey());
}

function lgPictureModeSignalForValue(value){
 const mode=lgPictureModeCanonicalValue(value);
 if(!mode) return '';
 if(/^dolby(?:Vision|Hdr)/i.test(mode)) return 'dv';
 if(/^hdr/i.test(mode)) return 'hdr10';
 for(const entry of Object.entries(LG_PICTURE_MODES_BY_SIGNAL)){
  const signal=entry[0];
  const modes=entry[1]||[];
  if(modes.some(item=>item[0]===mode)) return signal;
 }
 if(/^dolby_hdr_/i.test(mode)) return 'dv';
 if(/^hdr_/i.test(mode)) return 'hdr10';
 const token=lgPictureModeToken(mode);
 if(token.indexOf('dolbyhdr')===0) return 'dv';
 if(token.indexOf('hdr')===0) return 'hdr10';
 // Every HDR10/HLG token starts with "hdr" and every Dolby Vision token
 // with "dolby" on all captured firmware, so anything else the TV reports
 // (e.g. "photo", or a token newer than this list) is an SDR preset.
 // Returning '' here blanks the dropdown and wipes the cached mode.
 return 'sdr';
}

function lgPictureModeMatchesSignal(value,signalMode){
 const signal=signalMode||lgSignalModeKey();
 const modeSignal=lgPictureModeSignalForValue(value);
 if(!modeSignal) return false;
 if(signal==='hdr10'||signal==='hlg') return modeSignal==='hdr10'||modeSignal==='hlg';
 return modeSignal===signal;
}

function lgRememberPictureMode(value,signalMode){
 if(!value) return;
 const mode=lgPictureModeCanonicalValue(value);
 const signal=signalMode||lgPictureModeEffectiveSignal(mode);
 if(!lgPictureModeMatchesSignal(mode,signal)) return;
 try{localStorage.setItem(lgPictureModeStorageKey(signal),mode);}catch(e){}
}

function lgStoredPictureMode(signalMode){
 try{return localStorage.getItem(lgPictureModeStorageKey(signalMode))||'';}catch(e){return '';}
}

function lgPictureModeLabel(value){
 const mode=lgPictureModeCanonicalValue(value);
 const signal=lgPictureModeEffectiveSignal(mode);
 const all=[...lgPictureModesForSignal(signal),...lgPictureModeEntries()];
 const found=all.find(item=>item[0]===mode);
 if(found) return found[1];
 return mode.replace(/^hdr_/,'HDR ').replace(/^dolby_hdr_/,'Dolby Vision ').replace(/_/g,' ').replace(/([a-z])([A-Z])/g,'$1 $2').replace(/\b\w/g,ch=>ch.toUpperCase());
}

function lgPictureModeOptions(signalMode,current){
 const mode=signalMode||lgPictureModeEffectiveSignal(current);
 const options=lgPictureModesForSignal(mode).map(item=>item.slice());
 const stored=lgPictureModeCanonicalValue(lgStoredPictureMode(mode));
 const extras=[];
 if(stored&&lgPictureModeMatchesSignal(stored,mode)) extras.push(stored);
 const canonicalCurrent=lgPictureModeCanonicalValue(current);
 if(canonicalCurrent&&lgPictureModeMatchesSignal(canonicalCurrent,mode)) extras.push(canonicalCurrent);
 extras.forEach(value=>{
  if(value&&!options.some(item=>item[0]===value)) options.unshift([value,lgPictureModeLabel(value)]);
 });
 return options;
}

function lgPopulatePictureModeSelect(current){
 const select=document.getElementById('lgPictureMode');
 if(!select) return;
 const state=window.lgStatusState||{};
 // Options always follow the OUTPUT signal_mode (sdr/hdr10/dv/hlg), not the
 // family of whatever picture mode string is currently cached. A stale
 // "cinema" selection while signal_mode=dv previously forced the SDR list
 // (and AutoCal reset then hit SDR Cinema and failed the DV reset path).
 const configured=lgSignalModeKey();
 let selected=lgPictureModeCanonicalValue(current!=null?current:lgPictureModeValue);
 if(selected && !lgPictureModeMatchesSignal(selected,configured)){
  selected='';
 }
 if(!selected){
  const stored=lgPictureModeCanonicalValue(lgStoredPictureMode(configured));
  if(stored && lgPictureModeMatchesSignal(stored,configured)) selected=stored;
 }
 const options=lgPictureModeOptions(configured,selected);
 let html='<option value="">Select mode</option>';
 options.forEach(item=>{html+='<option value="'+lgEscapeHtml(item[0])+'">'+lgEscapeHtml(item[1])+'</option>';});
 select.innerHTML=html;
 if(selected && options.some(item=>item[0]===selected)){
  select.value=selected;
  lgPictureModeValue=selected;
 } else {
  select.value='';
  // Drop a stale cross-signal value so meterLgPictureModeValue() cannot
  // hand AutoCal "cinema" while the output is DV.
  if(!selected || !lgPictureModeMatchesSignal(selected,configured)) lgPictureModeValue='';
 }
 lgPictureModeSignalMode=configured;
 select.disabled=lgPictureModePending||!lgStatusConnected(state);
}

function lgSelectedPairingMode(){
 const select=document.getElementById('lgPairingMode');
 const mode=select&&select.value?String(select.value).toUpperCase():'PIN';
 return /^(PIN|COMBINED|LGSWITCH-PIN)$/.test(mode)?mode:'PIN';
}

// True when a /api/lg/connect response says this TV still has to go through
// PIN pairing: the daemon refused to accept a "press OK" prompt pairing on a
// TV that advertises PIN, because prompt pairing is not how this box pairs.
// Note this is deliberately NOT inferred from what the key can reach on the
// TV afterwards -- the readable picture-key set varies by model (a 2021 C1
// exposes far fewer keys than a 2022 C2 with an equally valid PIN-paired
// key), so treating a short key list as "needs re-pairing" would put such a
// set into a pairing loop and trip the TV's pairing-request throttle.
function lgResponseNeedsPinPairing(r){
 if(!r) return false;
 return !!r.needs_pin_pairing;
}

function lgRevealPinEntry(){
 // The PIN field lives inside the LG Connect modal -- that is the only
 // PIN entry point in the new flow (see lgConnectModalShow / Submit).
 // Focus the modal input if the modal is open. If the modal isn't open
 // (e.g., the operator opened the page with a stale pinPending status
 // from a previous session), fall back to a legacy no-op: there is no
 // longer an inline lgPairPin input in the display card to scroll to.
 const overlay=document.getElementById('lgConnectOverlay');
 const modalOpen=overlay&&overlay.getAttribute('aria-hidden')!=='true';
 const modalInput=document.getElementById('lgConnectPinInput');
 if(modalOpen&&modalInput){
  try{modalInput.focus({preventScroll:true});}catch(e){modalInput.focus();}
  if(modalInput.select) modalInput.select();
  return;
 }
 // No modal -- if the legacy input is somehow still present (it isn't
 // in production), scroll/focus it as a last resort.
 const legacyInput=document.getElementById('lgPairPin');
 const card=(legacyInput&&legacyInput.closest('.card'))||document.querySelector('.card[data-widget="lg"]');
 if(card&&card.classList.contains('collapsed')){
  card.classList.remove('collapsed');
  try{
   const key=card.dataset.collapseKey||card.id||card.getAttribute('data-widget');
   if(key){
    const state=JSON.parse(localStorage.getItem('cardCollapse')||'{}')||{};
    delete state[key];
    localStorage.setItem('cardCollapse',JSON.stringify(state));
   }
  }catch(e){}
 }
 if(card&&card.scrollIntoView) card.scrollIntoView({behavior:'smooth',block:'center'});
 if(legacyInput){
  try{legacyInput.focus({preventScroll:true});}catch(e){legacyInput.focus();}
  if(legacyInput.select) legacyInput.select();
 }
}

function lgDetectedPromptKey(r){
 const boot=r.boot_id||'boot-unknown';
 const cec=[r.cec_tv_vendor||'',r.cec_tv_name||'',r.cec_osd_name||'',r.phys_addr||'',r.log_addr||''].join('@');
 return boot+'|'+cec;
}

function lgDetectedPromptSeenStorageKey(key){
 return 'lgDetectedPromptSeen:'+String(key||'');
}

function lgDetectedPromptWasHandled(key){
 if(!key) return false;
 try{
  if(localStorage.getItem(lgDetectedPromptSeenStorageKey(key))==='1') return true;
 }catch(e){}
 try{
  if(sessionStorage.getItem('lgDetectedPromptDismissed')===key) return true;
 }catch(e){}
 return false;
}

function lgMarkDetectedPromptHandled(r){
 const key=(typeof r==='string')?r:lgDetectedPromptKey(r||{});
 if(!key) return;
 try{localStorage.setItem(lgDetectedPromptSeenStorageKey(key),'1');}catch(e){}
 try{sessionStorage.setItem('lgDetectedPromptDismissed',key);}catch(e){}
}

function lgDismissDetectedPrompt(){
 const modal=document.getElementById('lgConnectPrompt');
 if(modal) modal.style.display='none';
 const key=(window.lgStatusState&&window.lgStatusState.promptKey)||'';
 lgMarkDetectedPromptHandled(key);
}

	function lgPromptSelectedIp(){
	 const manual=document.getElementById('lgPromptManualIp');
	 const typed=manual?manual.value.trim():'';
	 if(typed) return typed;
	 const select=document.getElementById('lgPromptDeviceList');
	 return select?String(select.value||'').trim():'';
	}

		function lgSelectedDeviceIp(selectId){
		 const el=document.getElementById(selectId);
		 if(!el) return '';
		 if(typeof el.value!=='undefined') return String(el.value||'').trim();
		 const selected=el.querySelector('[data-lg-tv-ip].selected')||el.querySelector('[data-lg-tv-ip]');
		 return selected?String(selected.getAttribute('data-lg-tv-ip')||'').trim():'';
		}

	function lgApplySelectedIp(ip){
	 ip=String(ip||'').trim();
	 if(!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return;
	 const input=document.getElementById('lgManualIp');
	 const promptInput=document.getElementById('lgPromptManualIp');
	 if(input) input.value=ip;
	 if(promptInput) promptInput.value=ip;
	}

	function lgUsePromptSelectedIp(){
	 lgApplySelectedIp(lgSelectedDeviceIp('lgPromptDeviceList')||lgPromptSelectedIp());
	}

		function lgUseCardSelectedIp(){
		 lgApplySelectedIp(lgSelectedDeviceIp('lgDeviceList'));
		}

		function lgCardDeviceClicked(ip){
		 const list=document.getElementById('lgDeviceList');
		 if(list){
		  Array.from(list.querySelectorAll('[data-lg-tv-ip]')).forEach(item=>{
		   const selected=String(item.getAttribute('data-lg-tv-ip')||'')===String(ip||'');
		   item.classList.toggle('selected',selected);
		   item.setAttribute('aria-selected',selected?'true':'false');
		   item.style.background=selected?'#10131d':'transparent';
		   item.style.boxShadow=selected?'inset 3px 0 0 var(--green)':'none';
		  });
		 }
		 lgApplySelectedIp(ip);
		}

	function lgPromptManualIpChanged(){
	 const ip=lgPromptSelectedIp();
	 lgApplySelectedIp(ip);
	}

	function lgRenderScanResults(r){
	 const promptSelect=document.getElementById('lgPromptDeviceList');
	 const cardSelect=document.getElementById('lgDeviceList');
	 const promptStatus=document.getElementById('lgConnectScanStatus');
	 const cardStatus=document.getElementById('lgCardScanStatus');
		 const setPromptSelectRows=(select,count)=>{
		  if(!select||typeof select.size==='undefined') return;
		  const rows=count>1?Math.min(4,count):1;
		  select.size=rows;
		  select.style.minHeight=(rows>1)?'92px':'';
		 };
			 const setCardListHeight=(list,count)=>{
			  if(!list) return;
			  list.style.height='90px';
			  list.style.maxHeight='90px';
			  list.style.overflowY=(count>3)?'auto':'hidden';
			  list.style.scrollbarColor='var(--border) #0d0d15';
			  list.style.scrollbarWidth='thin';
		 };
		 const devices=(r&&Array.isArray(r.devices))?r.devices:[];
		 if(!devices.length){
			  const emptyHtml='<option value="">No TVs found</option>';
			  const emptyBox='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:var(--text2)">No TVs found</div>';
			  if(promptSelect) promptSelect.innerHTML=emptyHtml;
			  if(cardSelect) cardSelect.innerHTML=emptyBox;
			  setPromptSelectRows(promptSelect,1);
			  setCardListHeight(cardSelect,1);
			  const message=(r&&r.message)||'No LG WebOS TVs were found. Enter the TV IP manually.';
	  if(promptStatus) promptStatus.textContent=message;
	  if(cardStatus) cardStatus.textContent=message;
	  return;
	 }
		 let html='';
		 let cardHtml='';
		 devices.forEach((d,idx)=>{
		  const ip=String(d.ip||'');
		  const label=String(d.label||((d.name||d.model_name||'LG WebOS TV')+' ('+ip+')'))+(d.saved?' — saved pairing':'');
		  html+='<option value="'+lgEscapeHtml(ip)+'" '+(idx===0?'selected':'')+'>'+lgEscapeHtml(label)+'</option>';
		  cardHtml+='<button type="button" data-lg-tv-ip="'+lgEscapeHtml(ip)+'" role="option" aria-selected="'+(idx===0?'true':'false')+'" class="lg-device-item '+(idx===0?'selected':'')+'" onclick="lgCardDeviceClicked(\''+lgEscapeHtml(ip)+'\')" style="display:flex;align-items:center;width:100%;height:30px;min-height:30px;padding:0 10px;text-align:left;background:'+(idx===0?'#10131d':'transparent')+';box-shadow:'+(idx===0?'inset 3px 0 0 var(--green)':'none')+';border:0;border-bottom:1px solid var(--border);color:var(--text);font-size:.82rem;line-height:1.15;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer">'+lgEscapeHtml(label)+'</button>';
			 });
			 if(promptSelect) promptSelect.innerHTML=html;
			 if(cardSelect) cardSelect.innerHTML=cardHtml;
			 setPromptSelectRows(promptSelect,devices.length);
			 setCardListHeight(cardSelect,devices.length);
		 if(promptStatus) promptStatus.textContent='Choose a detected TV, or enter an IP manually.';
	 if(cardStatus) cardStatus.textContent=devices.length+' LG TV'+(devices.length===1?'':'s')+' found. Click one to use its IP.';
	 const input=document.getElementById('lgManualIp');
	 const currentIp=input?String(input.value||'').trim():'';
		 if(currentIp){
		  if(promptSelect) promptSelect.value=currentIp;
		  if(cardSelect) lgCardDeviceClicked(currentIp);
		 }else{
		  lgUseCardSelectedIp();
		 }
	}

	async function lgLoadSavedTvs(){
	 try{
	  const s=await fetchJSON('/api/lg/scan/saved',{_quiet:true,_timeoutMs:4000});
	  if(s&&Array.isArray(s.devices)&&s.devices.length) lgRenderScanResults(s);
	 }catch(e){}
	}

	async function lgStartupAutoDetect(){
	 const deadline=Date.now()+25000;
	 let result=null;
	 while(Date.now()<deadline){
	  try{
	   result=await fetchJSON('/api/lg/scan/startup',{_quiet:true,_timeoutMs:3000});
	  }catch(e){ result=null; }
	  if(result&&result.status!=='running') break;
	  await new Promise(resolve=>setTimeout(resolve,600));
	 }
	 if(result&&Array.isArray(result.devices)&&result.devices.length){
	  lgRenderScanResults(result);
	  // The scan updates auto-detection metadata. Refreshing normal LG status
	  // invokes the existing new-TV pairing prompt when appropriate.
	  await loadLgStatus(true);
	 }
	}

	async function lgScanTvs(force){
	 if(lgScanPending&&!force) return;
	 lgScanPending=true;
		 const promptSelect=document.getElementById('lgPromptDeviceList');
		 const cardSelect=document.getElementById('lgDeviceList');
	 const promptStatus=document.getElementById('lgConnectScanStatus');
	 const cardStatus=document.getElementById('lgCardScanStatus');
			 if(promptSelect) promptSelect.innerHTML='<option value="">Scanning...</option>';
			 if(cardSelect) {
			  cardSelect.innerHTML='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:var(--text2)">Scanning...</div>';
			  cardSelect.style.height='90px';
			  cardSelect.style.maxHeight='90px';
			  cardSelect.style.overflowY='hidden';
			 }
			 if(promptSelect) { promptSelect.size=1; promptSelect.style.minHeight=''; }
	 if(promptStatus) promptStatus.textContent='Scanning the local network for LG WebOS TVs...';
	 if(cardStatus) cardStatus.textContent='Scanning the local network for LG WebOS TVs...';
	 // Saved pairings render instantly (no probes) so the operator can
	 // see and forget stored TVs without waiting for discovery; the full
	 // scan below then replaces the list (it includes the saved entries).
	 let savedShown=false;
	 try{
	  const s=await fetchJSON('/api/lg/scan/saved',{_quiet:true,_timeoutMs:4000});
	  if(s&&Array.isArray(s.devices)&&s.devices.length){
	   lgRenderScanResults(s);
	   savedShown=true;
	   if(promptStatus) promptStatus.textContent='Saved TVs shown. Scanning for more...';
	   if(cardStatus) cardStatus.textContent='Saved TVs shown. Scanning the network for more...';
	  }
	 }catch(e){}
	 try{
	  const r=await fetchJSON('/api/lg/scan',{_quiet:true,_timeoutMs:20000});
	  if(r&&Array.isArray(r.devices)&&(r.devices.length||!savedShown)) lgRenderScanResults(r);
	  else if(savedShown&&cardStatus) cardStatus.textContent='Showing saved TVs. Network scan found nothing new.';
	 }catch(e){
	  if(savedShown){
	   if(promptStatus) promptStatus.textContent='Network scan timed out; showing saved TVs.';
	   if(cardStatus) cardStatus.textContent='Network scan timed out; showing saved TVs.';
	  }else{
		  if(promptSelect) promptSelect.innerHTML='<option value="">Scan failed</option>';
		  if(cardSelect) cardSelect.innerHTML='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:#f7b0b0">Scan failed</div>';
	  if(promptStatus) promptStatus.textContent='Scan failed. Enter the TV IP manually.';
	  if(cardStatus) cardStatus.textContent='Scan failed. Enter the TV IP manually.';
	  }
	 }finally{
	  lgScanPending=false;
	 }
}

function lgPromptConnect(){
 const modal=document.getElementById('lgConnectPrompt');
 if(modal) modal.style.display='none';
 lgDetectedPromptShown=true;
 const ip=lgPromptSelectedIp();
 const input=document.getElementById('lgManualIp');
 if(ip&&input) input.value=ip;
 lgConnect();
}

function lgMaybeShowDetectedPrompt(r){
 if(!r||r.pin_pairing_pending) return;
 if(r.paired||r.client_key_present) return;
 const detected=!!r.detected;
 const hasIp=!!(r.manual_ip||r.stored_ip||r.auto_ip);
 if(!detected||lgDetectedPromptShown) return;
 const key=lgDetectedPromptKey(r);
 if(lgDetectedPromptWasHandled(key)) return;
 const modal=document.getElementById('lgConnectPrompt');
 const text=document.getElementById('lgConnectPromptText');
 const button=document.getElementById('lgConnectPromptBtn');
 if(!modal||!text) return;
 const name=r.model_name||r.stored_name||r.cec_tv_name||(r.auto_ip?'LG WebOS TV':r.cec_osd_name)||'LG TV';
 const loc=r.phys_addr?(' on HDMI '+r.phys_addr):'';
 const ip=r.auto_ip||r.stored_ip||r.manual_ip||'';
 text.textContent=name+' detected'+loc+(ip?(' at '+ip):'')+'. Choose a TV from the scan or enter its IP.';
 if(button) button.textContent=(r.client_key_present||r.paired)?'Connect':'Pair With PIN';
 window.lgStatusState.promptKey=key;
 modal.style.display='flex';
 lgDetectedPromptShown=true;
 lgMarkDetectedPromptHandled(key);
 lgLoadSavedTvs();
}

function lgSchedulePictureModeRefresh(force){
 if(lgPictureModeRefreshTimer) return;
 lgPictureModeRefreshTimer=setTimeout(()=>{
  lgPictureModeRefreshTimer=null;
  lgRefreshPictureMode(!!force);
 },80);
}

function lgClearPictureModeForSignalChange(){
 lgPictureModeValue='';
 lgPictureModeSignalMode=lgSignalModeKey();
 lgDisplayControlInvalidate();
 lgPopulatePictureModeSelect('');
}

function lgRefreshPictureModeAfterOutputApply(){
 if(!lgDisplayControlConnected()) return;
 lgClearPictureModeForSignalChange();
 [250,1500,3500,6500].forEach(delay=>{
  setTimeout(()=>lgRefreshPictureMode(true),delay);
 });
}

function lgBindDisplayModeControl(){
 const signal=document.getElementById('signal_mode');
 if(signal&&!signal.dataset.lgPictureModeBound){
  signal.dataset.lgPictureModeBound='1';
  signal.addEventListener('change',()=>{
   lgClearPictureModeForSignalChange();
  });
 }
 lgPopulatePictureModeSelect(lgPictureModeValue);
}

function lgDisplayControlConnected(){
 const state=window.lgStatusState||{};
 return lgStatusConnected(state);
}

function lgSelectedPictureModeValue(){
 const select=document.getElementById('lgPictureMode');
 if(select&&select.value) return select.value;
 return lgPictureModeCanonicalValue(lgPictureModeValue);
}

function lgDisplayControlPictureMode(){
 return lgSelectedPictureModeValue();
}

function lgPictureResetButtons(){
 return ['lgPictureResetBtn','lgDisplayControlResetBtn'].map(id=>document.getElementById(id)).filter(Boolean);
}

function lgSetPictureResetButtonsDisabled(disabled){
 lgPictureResetButtons().forEach(button=>{button.disabled=!!disabled;});
}

function lgDisplayControlSetStatus(text,error){
 const status=document.getElementById('lgDisplayControlStatus');
 const badge=document.getElementById('lgDisplayControlBadge');
 if(status){
  status.textContent=text||'';
  status.style.color=error?'var(--red)':'var(--text2)';
 }
 if(badge){
  badge.textContent=lgDisplayControlPending?'Busy':(lgDisplayControlConnected()?(lgDisplayControlLoaded?'Ready':'Refresh'):'Connect');
  badge.style.background=lgDisplayControlPending?'var(--orange)':(lgDisplayControlConnected()?'var(--green)':'var(--text2)');
 }
}

function lgOpenDisplayControl(){
 const modal=document.getElementById('lgDisplayControlModal');
 if(!modal) return;
 modal.style.display='flex';
 lgDisplayControlRender();
 lgDisplayControlRefresh(false);
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

function lgCloseDisplayControl(){
 const modal=document.getElementById('lgDisplayControlModal');
 if(modal) modal.style.display='none';
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

function lgDisplayControlCurrentValue(key){
 return Object.prototype.hasOwnProperty.call(lgDisplayControlValues,key)?lgDisplayControlValues[key]:null;
}

function lgDisplayControlOptionHtml(meta,value){
 const raw=String(value==null?'':value);
 const seen={};
 let html='';
 (meta.options||[]).forEach(opt=>{
  const val=String(opt);
  seen[val]=true;
  html+='<option value="'+lgEscapeHtml(val)+'"'+(raw===val?' selected':'')+'>'+lgEscapeHtml(lgPictureModeLabel(val))+'</option>';
 });
 if(raw!==''&&!seen[raw]){
  html='<option value="'+lgEscapeHtml(raw)+'" selected>'+lgEscapeHtml(raw)+'</option>'+html;
 }
 return html;
}

function lgDisplayControlInvalidate(){
 lgDisplayControlLoaded=false;
 lgDisplayControlValues={};
 lgDisplayControlCapabilities={supportedKeys:[],unsupportedKeys:{}};
 lgDisplayControlError='';
 lgDisplayControlRender();
}

function lgDisplayControlRender(){
 const grid=document.getElementById('lgDisplayControlGrid');
 const refreshBtn=document.getElementById('lgDisplayControlRefreshBtn');
 const resetBtn=document.getElementById('lgDisplayControlResetBtn');
 const applyAllBtn=document.getElementById('lgApplyAllInputsBtn');
 if(refreshBtn) refreshBtn.disabled=lgDisplayControlPending||!lgDisplayControlConnected();
 const modeActionsDisabled=lgDisplayControlPending||!lgDisplayControlConnected()||lgPictureModePending||lgCalibrationModePending||lgApplyAllInputsPending;
 if(resetBtn) resetBtn.disabled=modeActionsDisabled;
 if(applyAllBtn) applyAllBtn.disabled=modeActionsDisabled;
 if(!grid) return;
 const connected=lgDisplayControlConnected();
 if(!connected){
  grid.innerHTML='';
  lgDisplayControlSetStatus('Connect display',false);
  return;
 }
 let html='';
 LG_DISPLAY_CONTROL_ITEMS.forEach(meta=>{
  const value=lgDisplayControlCurrentValue(meta.key);
  const supported=value!==null&&value!==undefined;
  const disabled=(!supported||lgDisplayControlPending)?' disabled':'';
  const displayValue=supported?String(value):'--';
  html+='<div class="lg-display-control-item" data-lg-display-control="'+lgEscapeHtml(meta.key)+'">';
  html+='<div class="lg-display-control-top"><div class="lg-display-control-label">'+lgEscapeHtml(meta.label)+'</div><div class="lg-display-control-value" id="lgDcValue_'+lgEscapeHtml(meta.key)+'">'+lgEscapeHtml(displayValue)+'</div></div>';
  html+='<div class="lg-display-control-row">';
  if(meta.type==='number'){
   const numeric=Number(value);
   const safe=Number.isFinite(numeric)?numeric:(meta.min||0);
   html+='<input type="range" id="lgDcRange_'+lgEscapeHtml(meta.key)+'" min="'+meta.min+'" max="'+meta.max+'" step="'+meta.step+'" value="'+safe+'" oninput="lgDisplayControlSyncNumber(\''+lgEscapeHtml(meta.key)+'\',this.value)" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>';
   html+='<input type="number" id="lgDcInput_'+lgEscapeHtml(meta.key)+'" min="'+meta.min+'" max="'+meta.max+'" step="'+meta.step+'" value="'+safe+'" oninput="lgDisplayControlSyncRange(\''+lgEscapeHtml(meta.key)+'\',this.value)" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>';
  }else{
   html+='<select id="lgDcInput_'+lgEscapeHtml(meta.key)+'" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>'+lgDisplayControlOptionHtml(meta,value)+'</select>';
  }
  html+='</div></div>';
 });
 grid.innerHTML=html;
 lgDisplayControlSetStatus(lgDisplayControlError||(lgDisplayControlLoaded?'Picture controls loaded':'Refresh settings'),!!lgDisplayControlError);
}

function lgDisplayControlSyncNumber(key,value){
 const number=document.getElementById('lgDcInput_'+key);
 const label=document.getElementById('lgDcValue_'+key);
 if(number&&document.activeElement!==number) number.value=value;
 if(label) label.textContent=String(value);
}

function lgDisplayControlSyncRange(key,value){
 const range=document.getElementById('lgDcRange_'+key);
 const label=document.getElementById('lgDcValue_'+key);
 if(range&&document.activeElement!==range) range.value=value;
 if(label) label.textContent=String(value);
}

async function lgDisplayControlRefresh(force){
 if(lgDisplayControlPending) return;
 if(!lgDisplayControlConnected()){
  lgDisplayControlInvalidate();
  return;
 }
 if(!force&&lgDisplayControlLoaded) return;
 lgDisplayControlPending=true;
 lgDisplayControlError='';
 lgDisplayControlRender();
 try{
  const r=await fetchJSON('/api/lg/picture-settings',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({keys:['pictureMode',...LG_DISPLAY_CONTROL_KEYS],picture_mode:lgDisplayControlPictureMode(),signal_mode:lgSignalModeKey(),ignore_calibration_picture_mode:true}),
   _quiet:true,
   _timeoutMs:18000
  });
	  if(r&&r.status==='ok'&&r.picture_settings){
	   lgDisplayControlValues=r.picture_settings||{};
	   lgDisplayControlCapabilities={
	    supportedKeys:Array.isArray(r.supported_picture_keys)?r.supported_picture_keys:[],
	    unsupportedKeys:(r.unsupported_picture_keys&&typeof r.unsupported_picture_keys==='object')?r.unsupported_picture_keys:{}
	   };
	   lgDisplayControlLoaded=true;
   lgDisplayControlError='';
   if(r.picture_settings.pictureMode){
    const mode=r.picture_settings.pictureMode;
    const signal=lgPictureModeEffectiveSignal(mode);
    lgPictureModeValue=mode;
    lgPictureModeSignalMode=signal;
    lgRememberPictureMode(mode,signal);
    lgPopulatePictureModeSelect(mode);
   }
  }else{
   lgDisplayControlError=(r&&r.message)||'Unable to read display controls';
  }
 }catch(e){
  lgDisplayControlError='Unable to read display controls';
 }finally{
  lgDisplayControlPending=false;
  lgDisplayControlRender();
 }
}

async function lgDisplayControlCommit(key){
 const meta=LG_DISPLAY_CONTROL_ITEMS.find(item=>item.key===key);
 if(!meta||!lgDisplayControlConnected()||lgDisplayControlPending) return;
 const input=document.getElementById('lgDcInput_'+key);
 if(!input) return;
 let value=meta.type==='number'?Number(input.value):input.value;
 if(meta.type==='number'){
  if(!Number.isFinite(value)) return;
  value=Math.max(Number(meta.min),Math.min(Number(meta.max),value));
 }
 const previousValue=lgDisplayControlValues[key];
 lgDisplayControlValues[key]=value;
 lgDisplayControlPending=true;
 lgDisplayControlError='';
 lgDisplayControlRender();
 const commandHandle=lgBeginCommand('Changing '+meta.label);
 let refreshAfter=false;
 try{
  const settings={};
  settings[key]=value;
  const r=await fetchJSON('/api/lg/picture-settings/set',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({settings:settings,picture_mode:lgDisplayControlPictureMode(),signal_mode:lgSignalModeKey(),ignore_calibration_picture_mode:true,readback_keys:[key,'pictureMode']}),
   _timeoutMs:30000
  });
  if(r&&r.status==='ok'){
   const picture=r.picture_settings||{};
   lgDisplayControlValues[key]=(picture[key]!==undefined)?picture[key]:value;
   if(picture.pictureMode){
    lgPictureModeValue=picture.pictureMode;
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(lgPictureModeValue);
    lgRememberPictureMode(lgPictureModeValue,lgPictureModeSignalMode);
    lgPopulatePictureModeSelect(lgPictureModeValue);
   }
   lgDisplayControlLoaded=true;
   lgDisplayControlError='';
   toast(meta.label+' updated');
  }else{
   lgDisplayControlValues[key]=previousValue;
   toast((r&&r.message)||('Unable to update '+meta.label),'err');
   refreshAfter=true;
  }
 }catch(e){
  lgDisplayControlValues[key]=previousValue;
  toast('Unable to update '+meta.label,'err');
  refreshAfter=true;
 }finally{
  lgEndCommand(commandHandle);
  lgDisplayControlPending=false;
  if(refreshAfter) await lgDisplayControlRefresh(true);
  else lgDisplayControlRender();
 }
}

function renderLgStatus(r){
 const badge=document.getElementById('lgStatusBadge');
 const text=document.getElementById('lgStatusText');
 const meta=document.getElementById('lgStatusMeta');
 const input=document.getElementById('lgManualIp');
 const pairingModeSelect=document.getElementById('lgPairingMode');
 const connectBtn=document.getElementById('lgConnectBtn');
 const disconnectBtn=document.getElementById('lgDisconnectBtn');
 const pinStartBtn=document.getElementById('lgPinStartBtn');
 const resetButtons=lgPictureResetButtons();
 const calibrationMode=document.getElementById('lgCalibrationMode');
 const hint=document.getElementById('lgWorkflowHint');
 if(!badge||!text||!meta) return;
 const detected=!!r.detected;
 const paired=!!r.paired;
 const pinPending=!!r.pin_pairing_pending;
	 const pairingMode=r.pairing_mode||'';
	 const promptStyle=r.prompt_style||'';
	 const hasIp=!!(r.manual_ip||r.stored_ip||r.auto_ip);
	 const clientKeyPresent=!!r.client_key_present;
	 const disconnected=!!r.disconnected;
	 const connected=Object.prototype.hasOwnProperty.call(r,'connected')?!!r.connected:!!((paired||clientKeyPresent)&&!pinPending&&!disconnected);
	 const previousState=window.lgStatusState||{};
	 const previousPaired=!!previousState.paired;
	 const promptKey=lgDetectedPromptKey(r);
	 window.lgStatusState={
		  paired:paired,
		  connected:connected,
		  disconnected:disconnected,
		  detected:detected,
	  hasIp:hasIp,
	  checked:true,
	  clientKeyPresent:clientKeyPresent,
	  pinPending:pinPending,
		  calibrationMode:!!r.calibration_mode,
		  promptKey:promptKey,
		  ip:r.manual_ip||r.stored_ip||r.auto_ip||'',
		  modelName:lgDisplayNameFromStatus(r),
		  displayName:lgDisplayNameFromStatus(r),
		  tvPower:r.tv_power||'',
		  currentInputChecked:connected&&!!previousState.currentInputChecked,
		  currentInputDisplay:connected?(previousState.currentInputDisplay||''):'',
		  currentInput:connected?(previousState.currentInput||''):'',
		  currentInputId:connected?(previousState.currentInputId||''):'',
		  currentInputLabel:connected?(previousState.currentInputLabel||''):'',
		  currentAppId:connected?(previousState.currentAppId||''):'',
		  currentInputMessage:connected?(previousState.currentInputMessage||''):'',
		  currentInputUpdatedAt:connected?(previousState.currentInputUpdatedAt||0):0
		 };
	 renderLgTopStatus(r);
	 lgRenderCurrentInput();
	 if(pinPending){
    badge.textContent=promptStyle==='controller-pin'?'Enter PIN':'Pairing';
   badge.style.background='var(--orange)';
	 }else if(connected){
	    badge.textContent='Connected';
	  badge.style.background='var(--green)';
	 }else if(disconnected&&clientKeyPresent){
	    badge.textContent='Disconnected';
	  badge.style.background='var(--badge-neutral)';
	 }else if(paired||clientKeyPresent){
	    badge.textContent='Paired';
	  badge.style.background='var(--green)';
 }else if(hasIp){
    badge.textContent='Ready to Pair';
  badge.style.background='var(--orange)';
 }else if(detected){
    badge.textContent='Detected';
    badge.style.background='var(--orange)';
 }else{
    badge.textContent='Needs IP';
  badge.style.background='var(--text2)';
 }
		 if(connectBtn) connectBtn.textContent=(paired||clientKeyPresent)?'Connect':'Pair With PIN';
		 if(disconnectBtn) disconnectBtn.disabled=pinPending||!clientKeyPresent||!connected;
 const parts=[];
 if(r.cec_osd_name) parts.push('CEC OSD: '+r.cec_osd_name);
 if(r.cec_tv_vendor) parts.push('CEC TV vendor: '+r.cec_tv_vendor);
 if(r.phys_addr) parts.push('HDMI '+r.phys_addr);
 if(r.manual_ip) parts.push('Manual IP: '+r.manual_ip);
 else if(r.stored_ip) parts.push('Stored IP: '+r.stored_ip);
 else if(r.auto_ip) parts.push('Auto IP: '+r.auto_ip);
 if(r.auto_host) parts.push('Host: '+r.auto_host);
 if(r.stored_name) parts.push('TV: '+r.stored_name);
 else if(r.model_name) parts.push('Model: '+r.model_name);
 if(r.software_version) parts.push('SW: '+r.software_version);
	 if(pairingMode) parts.push('Pairing: '+pairingMode);
	 if(r.client_key_present) parts.push('Client key saved');
	 if(disconnected) parts.push('Disconnected');
    if(r.transport) parts.push('Transport: '+r.transport.toUpperCase());
 if(r.detection_source) parts.push('Detect: '+r.detection_source);
 text.textContent=r.message||'LG status unavailable';
	 meta.textContent=parts.join(' | ');
	 if(input&&document.activeElement!==input) input.value=r.manual_ip||r.stored_ip||r.auto_ip||'';
	 const activeIp=r.manual_ip||r.stored_ip||r.auto_ip||'';
		 ['lgDeviceList','lgPromptDeviceList'].forEach(id=>{
		  const el=document.getElementById(id);
		  if(!el||!activeIp) return;
		  if(typeof el.value!=='undefined') el.value=activeIp;
		  else if(id==='lgDeviceList') lgCardDeviceClicked(activeIp);
		 });
	 if(pairingModeSelect){
  if(pairingMode && pairingModeSelect.value!==pairingMode) pairingModeSelect.value=pairingMode;
  pairingModeSelect.disabled=pinPending;
 }
 // The PIN entry row/button used to live in the display card and was
 // toggled here on pinPending. Both have been removed -- the LG Connect
 // modal is now the only PIN entry point (see lgConnectModalShow /
 // lgConnectSubmitPinFromModal). renderLgStatus() no longer needs to
 // touch any inline PIN UI; lgRevealPinEntry() below focuses the modal
 // input when a status refresh confirms pinPending.
	 if(calibrationMode){
	  calibrationMode.disabled=lgCalibrationModePending||pinPending||!connected;
	  calibrationMode.checked=!!r.calibration_mode;
 }
 if(pinPending && !lgLastPinPending) lgRevealPinEntry();
	 if(pinStartBtn){
	  pinStartBtn.disabled=pinPending;
	  pinStartBtn.textContent=pinPending?'Pairing Active':'Pair With PIN';
	 }
	 resetButtons.forEach(button=>{button.disabled=pinPending||!connected||lgPictureModePending||lgCalibrationModePending;});
	 if(hint){
	  if(pinPending){
	   hint.textContent=promptStyle==='controller-pin'
	    ? 'Enter the PIN shown on the LG TV to finish pairing.'
	    : 'Finish the pairing prompt shown on the LG TV.';
		  }else if(disconnected&&clientKeyPresent){
		   hint.textContent='LG TV is disconnected. Connect reuses the saved key without another PIN.';
		  }else if(connected){
		   hint.textContent='Saved LG pairing is available. Connect uses the stored key without another PIN.';
	  }else if(r.auto_ip){
	   hint.textContent='LG TV auto-detected via '+(r.auto_host||'lgwebostv.local')+'.';
	  }else if(hasIp){
	   hint.textContent='LG TV IP is ready.';
	  }else{
	   hint.textContent='No LG TV IP is available yet.';
	  }
	 }
	 lgPopulatePictureModeSelect(lgPictureModeValue);
	 lgDisplayControlRender();
	 if(typeof meterUpdateSeriesTabUi==='function') meterUpdateSeriesTabUi();
	 else if(typeof meterUpdateSeriesLabels==='function') meterUpdateSeriesLabels();
	 if(typeof meterUpdateReadButtons==='function') meterUpdateReadButtons();
		 if(connected&&!pinPending) {
	  lgSchedulePictureModeRefresh(false);
	  setTimeout(()=>lgDisplayControlRefresh(false),650);
	 } else {
	  lgDisplayControlInvalidate();
	 }
	 lgMaybeShowDetectedPrompt(r);
	 lgLastPinPending=pinPending;
		 if(previousPaired!==paired && typeof meterRefreshActiveSeriesCharts==='function') meterRefreshActiveSeriesCharts();
	  else if(typeof meterLgGreySyncForCurrentStep==='function') meterLgGreySyncForCurrentStep(false);
	  if(typeof updateLgCommandBusyUi==='function') updateLgCommandBusyUi();
			}

async function loadLgStatus(quiet){
	 if(typeof lgIsCommandBusy==='function'&&lgIsCommandBusy()){
	  if(typeof updateLgCommandBusyUi==='function') updateLgCommandBusyUi();
	  return;
	 }
	 if(lgStatusPending) return;
 lgStatusPending=true;
 try{
  const r=await fetchJSON('/api/lg/status',{_quiet:!!quiet,_timeoutMs:8000});
  if(r&&r.status==='ok') renderLgStatus(r);
  else renderLgStatus({message:'LG status unavailable'});
 }catch(e){
  renderLgStatus({message:'LG status unavailable'});
 }finally{
  lgStatusPending=false;
 }
}

// The manual "Save IP" button was removed: the TV IP is saved
// automatically -- lg_update_connect_metadata persists manual_ip on
// every successful connect/pair, and saved pairings are always listed.

// Cancellation token for lgConnect(). lgConnectModalHide() in
// webui.pm bumps this when the operator clicks Cancel or dismisses the
// modal, so any in-flight lgConnect() await points check
// _lgConnectToken === myToken and bail out without re-entering the
// modal or stomping on a newer lgConnect() call. Without this, a
// Cancel during the 15s lgStartPinPairing() wait leaves the connect
// button disabled until the flow eventually unwinds, and a follow-up
// click races against the still-running first call.
window._lgConnectToken=window._lgConnectToken||0;

async function lgConnect(){
 const myToken=++window._lgConnectToken;
 const input=document.getElementById('lgManualIp');
 const button=document.getElementById('lgConnectBtn');
	 const ip=input?input.value.trim():'';
	 const state=window.lgStatusState||{};
	 const hasSavedKey=lgStatusHasSavedKey(state);
 if(ip&&!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid LG TV IP','err');return;}
 // Helper: bail out if a newer lgConnect() call or a Cancel has
 // invalidated this run. Restores the button label so the operator
 // isn't left staring at "Starting Pairing..." forever. Default label
 // matches renderLgStatus's rule: "Connect" if paired||clientKeyPresent,
 // otherwise "Pair With PIN".
 const aborted=()=>myToken!==window._lgConnectToken;
 const bail=()=>{
  if(button){
   button.disabled=false;
   const state=window.lgStatusState||{};
   const pairedOrKey=!!(state.paired||state.clientKeyPresent||state.client_key_present);
   button.textContent=pairedOrKey?'Connect':'Pair With PIN';
  }
 };
 // Pop the LG Connect modal IMMEDIATELY (synchronously, before any
 // blocking POST). The WebOS WSS handshake can take 5-70s; if we waited
 // for the POST to return the operator would see a dead "Connect" button
 // for that whole window. The modal carries the spinner through the
 // entire flow. The PIN field stays HIDDEN initially because the TV
 // isn't showing a PIN yet -- it is revealed (and focused) by
 // lgConnectModalRevealPinField() once /api/lg/pair-pin/start reports
 // pin_pending. This keeps the operator from typing into a blank field
 // while the TV is still booting its pairing prompt.
 //
 // Helpers live in webui.pm; if absent (older webui.pm deployed) we
 // fall back to the corner toast so the function is still usable.
 const showModal=typeof lgConnectModalShow==='function';
 if(showModal){
  // Always start with the PIN field hidden -- it is revealed only if
  // the post-pair-pin/start status reports pin_pending.
  lgConnectModalShow(false, hasSavedKey
   ? 'Contacting the LG TV with the saved key\u2026'
   : 'Starting LG PIN pairing. Watch the TV for a PIN.');
 }else{
  toast(hasSavedKey
   ? 'Connecting to the LG TV with the saved key.'
   : 'Starting LG PIN pairing. Watch the TV for a PIN.');
 }

 // POSTs the PIN to /api/lg/pair-pin/submit and reports success/failure
 // via the modal. Returns true on success so the caller can fall through
 // to the saved-key connect POST below.
 async function submitPinThenConnect(pin){
  const commandHandle=lgBeginCommand('Submitting LG TV PIN');
  try{
   const r=await fetchJSON('/api/lg/pair-pin/submit',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({pin}),
    _timeoutMs:70000
   });
   // If a Cancel or a newer lgConnect() call invalidated this run
   // while we were waiting, swallow the result silently -- the new
   // flow owns the modal now.
   if(aborted()) return false;
   if(r){
    renderLgStatus(r);
    if(r.status==='ok'){
     // Saved key is now in place. The modal flips to a "Connecting..."
     // status while the saved-key POST runs.
     if(showModal) lgConnectModalPinStatus('PIN accepted. Connecting\u2026');
     return true;
    }
    if(showModal) lgConnectModalError(r.message||'PIN was not accepted.');
    else toast(r.message||'PIN was not accepted.','err');
    return false;
   }
   if(showModal) lgConnectModalError('The daemon returned no response.');
   else toast('Unable to submit PIN','err');
   return false;
  }catch(e){
   if(aborted()) return false;
   if(showModal) lgConnectModalError((e&&e.message)||'PIN submission failed.');
   else toast('Unable to submit PIN','err');
   return false;
  }finally{
   lgEndCommand(commandHandle);
  }
 }

 // POSTs to /api/lg/connect to open the WebOS session. Modal is
 // already up (show() ran synchronously above); transitions to
 // success/error on the result.
 async function runSavedKeyConnect(allowPinFallback){
  if(button){button.disabled=true;button.textContent='Connecting...';}
  const commandHandle=lgBeginCommand('Connecting to LG TV');
  let pinFallback=false;
  try{
   const r=await fetchJSON('/api/lg/connect',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({ip}),
    _timeoutMs:70000
   });
   if(aborted()) return;
   if(r){
    renderLgStatus(r);
    if(allowPinFallback&&lgResponseNeedsPinPairing(r)){
     // This TV has never been PIN-paired on this box (or its stored key
     // came from a "press OK" prompt pairing and cannot touch the picture
     // keys). Don't report a dead error -- run PIN pairing, then retry the
     // connect with the fresh key.
     pinFallback=true;
     if(showModal) lgConnectModalPinStatus('This TV needs PIN pairing. Watch the TV for a PIN…');
     else toast('This TV needs PIN pairing. Watch the TV for a PIN.');
    }else if(r.status==='ok'){
     if(showModal) lgConnectModalSuccess(r.message);
     else toast(r.message||'LG TV connected');
    }else{
     if(showModal) lgConnectModalError(r.message);
     else toast(r.message||'Unable to connect to LG TV','err');
    }
   }else{
    if(showModal) lgConnectModalError('The daemon returned no response.');
    else toast('Unable to connect to LG TV','err');
   }
  }catch(e){
   if(aborted()) return;
   if(showModal) lgConnectModalError((e&&e.message)||'Connect request failed.');
   else toast('Unable to connect to LG TV','err');
  }finally{
   lgEndCommand(commandHandle);
   if(button&&!aborted()){button.disabled=false;button.textContent=pinFallback?'Pair With PIN':'Connect';}
   else if(button){bail();}
  }
  if(!pinFallback) return;
  if(aborted()){bail();return;}
  const paired=await runPinPairing();
  if(!paired) return;
  // Fresh PIN-paired key in place -- retry once, with the fallback closed so
  // a TV that still reports needs_pin_pairing cannot loop.
  await runSavedKeyConnect(false);
 }

 // First-time (or repeat) PIN pairing: /api/lg/pair-pin/start triggers the
 // TV to show its PIN. After it succeeds, the modal reveals the PIN field
 // and waits (via _lgPinResolver) for the operator to type and submit.
 // Returns true when a key is in place and the caller should go on to the
 // saved-key connect; false when it already reported the failure and bailed.
 async function runPinPairing(){
  if(button){button.disabled=true;button.textContent='Starting Pairing...';}
  const commandHandle=lgBeginCommand('Starting LG PIN pairing');
  try{
   await lgStartPinPairing();
   // If the operator hit Cancel during the 15s pair-pin/start wait,
   // bail out without touching the (now-owned-by-elsewhere) modal.
   if(aborted()){bail();return false;}
   const postState=window.lgStatusState||{};
   if(!lgStatusHasSavedKey(postState)||postState.pinPending){
    // PIN is required. Reveal the modal's inline PIN field and wait
    // for the operator to submit. The modal stays up the entire time;
    // it transitions to success/error after submitPinThenConnect +
    // runSavedKeyConnect.
    if(showModal){
     lgConnectModalPinStatus('Enter the PIN shown on the TV.');
     if(typeof lgConnectModalRevealPinField==='function') lgConnectModalRevealPinField();
    }else{
     toast('Enter the PIN shown on the TV.');
    }
    if(button){button.disabled=false;button.textContent='Connect';}
    const pin=await lgWaitForModalPin();
    if(aborted()||!pin){
     // Modal closed without a PIN (safety timeout, hide() call, or
     // a newer lgConnect() took over).
     bail();
     return false;
    }
    const ok=await submitPinThenConnect(pin);
    if(aborted()){bail();return false;}
    if(!ok){
     bail();
     return false;
    }
    // PIN accepted; saved key is now in place.
   }
   return true;
  }catch(e){
   if(aborted()){bail();return false;}
   if(showModal) lgConnectModalError((e&&e.message)||'LG PIN pairing failed to start.');
   else toast('LG PIN pairing failed to start.','err');
   bail();
   return false;
  }finally{
   lgEndCommand(commandHandle);
  }
 }

 if(!hasSavedKey){
  const paired=await runPinPairing();
  if(!paired) return;
 }
 // Saved-key path (or post-PIN-submit continuation): open the WebOS
 // session. The modal is still up (showing the spinner) from the
 // synchronous show() at the top; transition to success/error after.
 await runSavedKeyConnect(true);
}

// Resolves with the PIN when the operator submits the modal's PIN
// input (via Submit button or Enter key). Resolves with null if the
// modal is hidden before submission (lgConnectModalHide() resolves
// with null as a safety), so the connect flow doesn't hang.
function lgWaitForModalPin(){
 return new Promise((resolve)=>{
  let done=false;
  const finish=(val)=>{
   if(done) return;
   done=true;
   clearInterval(check);
   window._lgPinResolver=null;
   resolve(val);
  };
  window._lgPinResolver=finish;
  const check=setInterval(()=>{
   const overlay=document.getElementById('lgConnectOverlay');
   if(!overlay||overlay.getAttribute('aria-hidden')==='true') finish(null);
  },500);
 });
}

async function lgStartPinPairing(){
 const input=document.getElementById('lgManualIp');
 const button=document.getElementById('lgPinStartBtn');
 const ip=input?input.value.trim():'';
 const pairingMode=lgSelectedPairingMode();
	 if(ip&&!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid LG TV IP','err');return;}
	 if(button){button.disabled=true;button.textContent='Starting Pairing...';}
	 const commandHandle=lgBeginCommand('Starting LG PIN pairing');
	 try{
	   toast('Starting LG PIN pairing. Watch the TV for a PIN.');
  const r=await fetchJSON('/api/lg/pair-pin/start',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
    body:JSON.stringify({ip,pairing_mode:pairingMode}),
   _timeoutMs:15000
  });
  if(r){
   renderLgStatus(r);
   if(r.status==='ok') {
      toast(r.message||'LG TV pairing started');
    if(r.pin_pairing_pending) lgRevealPinEntry();
   }
    else toast(r.message||'Unable to start LG TV pairing','err');
  }else{
    toast('Unable to start LG TV pairing','err');
  }
	 }catch(e){
	   toast('Unable to start LG TV pairing','err');
	 }finally{
	   lgEndCommand(commandHandle);
	   if(button){
    button.disabled=false;
    const badge=document.getElementById('lgStatusBadge');
    const badgeText=badge?badge.textContent:'';
	    button.textContent=(badgeText==='Enter PIN'||badgeText==='Pairing')?'Pairing Active':'Pair With PIN';
   }
 }
}

async function lgRefreshPictureMode(force){
 const state=window.lgStatusState||{};
 const configured=lgSignalModeKey();
 let signal=configured;
			 if(!lgStatusConnected(state)){
		  lgPictureModeValue='';
		  lgPictureModeSignalMode=configured;
		  lgPopulatePictureModeSelect('');
		  lgDisplayControlInvalidate();
		  return;
		 }
	 if(typeof lgIsCommandBusy==='function'&&lgIsCommandBusy()) return;
	 if(lgPictureModePending) return;
	 const currentInputFresh=!!(state.currentInputChecked&&state.currentInputUpdatedAt&&(Date.now()-state.currentInputUpdatedAt)<15000);
	 if(!force&&currentInputFresh&&lgPictureModeValue&&lgPictureModeSignalMode===configured
    && lgPictureModeMatchesSignal(lgPictureModeValue,configured)){
  lgPopulatePictureModeSelect(lgPictureModeValue);
  return;
 }
 lgPictureModePending=true;
 lgPopulatePictureModeSelect(lgPictureModeValue);
 try{
  const r=await fetchJSON('/api/lg/picture-settings',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({keys:['pictureMode'],picture_mode:'',signal_mode:lgSignalModeKey(),ignore_calibration_picture_mode:true,include_current_input:true}),
   _quiet:true,
   _timeoutMs:9000
  });
  if(r&&r.status==='ok'&&r.picture_settings){
   lgUpdateCurrentInput(r);
   const mode=lgPictureModeCanonicalValue(r.picture_settings.pictureMode||'');
   // Only accept a TV readback that matches the configured output signal.
   // When HDMI is DV but the TV still reports SDR "cinema" (wrong input,
   // latch, or pre-switch read), pinning that value collapses the card to
   // the SDR list and AutoCal DV reset fails.
   if(mode && lgPictureModeMatchesSignal(mode,configured)){
    lgPictureModeValue=mode;
    lgPictureModeSignalMode=configured;
    lgRememberPictureMode(mode,configured);
    lgDisplayControlInvalidate();
    setTimeout(()=>lgDisplayControlRefresh(true),650);
   } else if(mode){
    // Keep DV/HDR options visible; fall back to per-signal stored preference.
    const stored=lgPictureModeCanonicalValue(lgStoredPictureMode(configured));
    lgPictureModeValue=(stored&&lgPictureModeMatchesSignal(stored,configured))?stored:'';
    lgPictureModeSignalMode=configured;
   }
	  }
 }catch(e){
	 }finally{
	  lgPictureModePending=false;
	  lgPopulatePictureModeSelect(lgPictureModeValue);
	  lgDisplayControlRender();
	 }
}

async function lgSetPictureMode(){
 const select=document.getElementById('lgPictureMode');
 if(!select) return;
 const value=select.value||'';
 if(!value) return;
 const state=window.lgStatusState||{};
 const signal=lgPictureModeEffectiveSignal(value);
	 if(!lgStatusConnected(state)){
  toast('Connect the LG TV first','err');
  lgPopulatePictureModeSelect(lgPictureModeValue);
  return;
	 }
	 lgPictureModePending=true;
	 select.disabled=true;
	 const commandHandle=lgBeginCommand('Changing LG picture mode');
	 try{
  const r=await fetchJSON('/api/lg/picture-settings/set',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({settings:{pictureMode:value},picture_mode:value,signal_mode:lgSignalModeKey(),readback_keys:['pictureMode']}),
   // Above the helper's own 45 s budget: the readback-verified select can
   // poll both routes for ~20 s on a slow HDMI re-sync, and giving up here
   // first leaves the helper switching the TV after the UI said it failed.
   _timeoutMs:50000
  });
  if(r&&r.status==='ok'){
   const mode=(r.picture_settings&&r.picture_settings.pictureMode)||value;
   lgPictureModeValue=mode;
   lgPictureModeSignalMode=signal;
   // Keep an unverified legacy selection as this session's DDC target, but
   // never persist it as the TV's active mode. Reset and future calibration
   // must not silently trust a mode the TV could not read back.
   if(r.picture_mode_verified===true) lgRememberPictureMode(mode,signal);
   // A pre-2022 set (webOS <= 6) does not expose picture-mode switching over
   // the settings API: the daemon only records the mode as the DDC calibration
   // target and the TV stays on whatever the operator last selected with the
   // remote. Saying "set to X" there reads as though the TV switched, which is
   // how this got mistaken for a broken picture-mode control -- say what
   // actually happened and what the operator still has to do.
   if(r.manual_confirmation_required||r.virtual_picture_settings){
    toast(r.message||('PGenerator will calibrate '+lgPictureModeLabel(mode)+', but this LG generation cannot be switched over the network -- select '+lgPictureModeLabel(mode)+' on the TV with the remote.'),true);
   }else{
    toast('LG picture mode set to '+lgPictureModeLabel(mode));
   }
	   if(typeof meterLgGreySyncForCurrentStep==='function'){
	    try{meterLgGreyState={status:'idle',picture:null,message:'',needsRepair:false};}catch(e){}
	    meterLgGreySyncForCurrentStep(true);
	   }
	   lgDisplayControlInvalidate();
	   lgDisplayControlRefresh(true);
	  }else{
   // The helper refuses unless the TV reads the requested mode back, and
   // reports what the TV is actually on -- show that rather than the
   // selection that did not take.
   if(r&&r.active_picture_mode&&r.picture_mode_verified===true){
    lgPictureModeValue=lgPictureModeCanonicalValue(r.active_picture_mode);
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(lgPictureModeValue);
    lgRememberPictureMode(lgPictureModeValue,lgPictureModeSignalMode);
   }
   let msg=r&&(r.message||r.repair_hint);
   // fetchJSON answers null when the request timed out; the helper may
   // still be switching the TV, so do not call that a failure outright.
   if(!r) msg='No reply from the LG helper within 50 s; the TV may still change. Click Refresh to see which mode it is on.';
   toast(msg||'Unable to change LG picture mode','err');
  }
	 }catch(e){
	  toast((e&&e.message)?e.message:'Unable to change LG picture mode','err');
	 }finally{
	  lgEndCommand(commandHandle);
	  lgPictureModePending=false;
	 lgPopulatePictureModeSelect(lgPictureModeValue);
	 lgDisplayControlRender();
 }
}

async function lgApplyAllInputs(){
 if(lgApplyAllInputsPending) return;
 const state=window.lgStatusState||{};
 if(!lgStatusConnected(state)){
  toast('Connect the LG TV first','err');
  return;
 }
 // The TV copies whatever mode it is actually on, not the dropdown's
 // selection (stale after a Magic Remote change). Ask the TV before naming
 // the preset in an irreversible-action warning; fall back to a generic
 // label rather than a possibly wrong one.
 const button=document.getElementById('lgApplyAllInputsBtn');
 if(button) button.disabled=true;
 let mode='';
 try{
  const r=await fetchJSON('/api/lg/picture-settings',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({keys:['pictureMode'],picture_mode:'',signal_mode:lgSignalModeKey(),ignore_calibration_picture_mode:true}),
   _quiet:true,
   _timeoutMs:9000
  });
  if(r&&r.status==='ok'&&r.picture_settings&&r.picture_settings.pictureMode){
   mode=lgPictureModeCanonicalValue(r.picture_settings.pictureMode);
   if(mode&&mode!==lgPictureModeValue){
    lgPictureModeValue=mode;
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(mode);
    lgPopulatePictureModeSelect(mode);
   }
  }
 }catch(e){
  mode='';
 }finally{
  lgDisplayControlRender();
 }
 const modeEl=document.getElementById('lgApplyAllInputsMode');
 if(modeEl) modeEl.textContent=mode?lgPictureModeLabel(mode):'the active picture mode (the TV did not report it)';
 const modal=document.getElementById('lgApplyAllInputsModal');
 if(!modal) return;
 modal.style.display='flex';
 const confirmBtn=document.getElementById('lgApplyAllInputsConfirmBtn');
 if(confirmBtn){ confirmBtn.disabled=false; confirmBtn.focus(); }
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

function lgApplyAllInputsClose(){
 const modal=document.getElementById('lgApplyAllInputsModal');
 if(modal) modal.style.display='none';
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

async function lgApplyAllInputsConfirmed(){
 if(lgApplyAllInputsPending) return;
 lgApplyAllInputsPending=true;
 const confirmBtn=document.getElementById('lgApplyAllInputsConfirmBtn');
 if(confirmBtn) confirmBtn.disabled=true;
 lgApplyAllInputsClose();
 const button=document.getElementById('lgApplyAllInputsBtn');
 if(button) button.disabled=true;
 const commandHandle=lgBeginCommand('Applying picture settings to all inputs');
 try{
  const r=await fetchJSON('/api/lg/picture-settings/apply-all-inputs',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({}),
   _timeoutMs:75000
  });
  if(r&&r.status==='ok'){
   // Green only when the TV reported the action done or accepted the
   // request outright; a bare alert-bridge dispatch is a warning, not a
   // result.
   toast(r.message||'Applied picture settings to all inputs',!(r.confirmed||r.acknowledged));
  }else{
   toast(r&&r.message?r.message:'Unable to apply picture settings to all inputs','err');
  }
 }catch(e){
  console.error('apply-all-inputs',e);
  toast((e&&e.message)?e.message:'Unable to apply picture settings to all inputs','err');
 }finally{
  lgEndCommand(commandHandle);
  lgApplyAllInputsPending=false;
  lgDisplayControlRender();
 }
}

async function lgResetPictureMode(){
 const state=window.lgStatusState||{};
	 if(!lgStatusConnected(state)){
  toast('Connect the LG TV first',true);
  return;
	 }
	 const signal=lgSignalModeKey();
	 // Prefer the Display card dropdown; fall back to last remembered mode.
	 // Pre-2022 OLEDs (C9 etc.) cannot read the live picture mode from the TV.
	 let mode=lgSelectedPictureModeValue()||lgPictureModeCanonicalValue(lgPictureModeValue)||'';
	 if(!mode){
	  toast('Select the LG picture mode on the Display card first, then try Reset Picture Mode again.',true);
	  return;
 }
 const label=mode?lgPictureModeLabel(mode):'the active mode';
 if(!confirm('Reset '+label+' picture settings?\n\nThis restores core picture defaults (brightness, contrast, backlight, etc.) for the mode. Greyscale DDC calibration is NOT wiped (use Auto Cal preflight for that).')) return;
 lgSetPictureResetButtonsDisabled(true);
 const commandHandle=lgBeginCommand('Resetting LG picture mode');
 try{
  // Display Card intent: TV-menu style picture reset, no DDC wipe
  // (require_white_balance_reset:false). C9 and other ddc_cal_identity
  // sets use the CAL UI_DATA + factory/builtin fallback path when webOS
  // rejects resetSystemSettings.
  const r=await fetchJSON('/api/lg/picture-settings/reset',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({picture_mode:mode,signal_mode:signal,require_white_balance_reset:false}),
   _timeoutMs:120000
  });
  if(r&&r.status==='ok'){
   const basicOk=!!(r.basic_picture_reset_ok||r.clean_picture_mode_reset);
   const bestEffort=String(r.picture_reset_best_effort||'')==='not_permitted';
   let msg=r.message||'LG picture mode reset complete';
   if(bestEffort){
    msg='Picture-settings reset is limited on this TV model; core defaults were applied via the calibration path.';
   }else if(!basicOk){
    msg=r.message||'LG picture mode reset only partially applied. Check picture mode selection and try again.';
   }
   toast(msg,!basicOk&&!bestEffort);
   if(r.active_picture_mode){
    lgPictureModeValue=r.active_picture_mode;
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(r.active_picture_mode);
    lgRememberPictureMode(r.active_picture_mode,lgPictureModeSignalMode);
   }
	   if(typeof meterLgGreySyncForCurrentStep==='function'){
	    try{meterLgGreyState={status:'idle',picture:null,message:'',needsRepair:false};}catch(e){}
	    meterLgGreySyncForCurrentStep(true);
	   }
	   lgRefreshPictureMode(true);
	   lgDisplayControlInvalidate();
	   lgDisplayControlRefresh(true);
	  }else{
   toast(r&&(r.repair_hint||r.message)?(r.repair_hint||r.message):'Unable to reset LG picture mode',true);
  }
 }catch(e){
  toast((e&&e.message)?e.message:'Unable to reset LG picture mode',true);
 }finally{
  lgEndCommand(commandHandle);
  lgSetPictureResetButtonsDisabled(false);
  await loadLgStatus(true);
  lgDisplayControlRender();
 }
}

async function lgSetCalibrationMode(){
 const checkbox=document.getElementById('lgCalibrationMode');
 if(!checkbox) return;
 const enabled=!!checkbox.checked;
 const state=window.lgStatusState||{};
	 if(!lgStatusConnected(state)){
  checkbox.checked=!enabled;
  toast('Connect the LG TV first','err');
  return;
	 }
	 lgCalibrationModePending=true;
	 checkbox.disabled=true;
	 const commandHandle=lgBeginCommand(enabled?'Enabling LG calibration mode':'Disabling LG calibration mode');
	 try{
  const r=await fetchJSON('/api/lg/calibration-mode',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({enabled,picture_mode:lgSelectedPictureModeValue()||'',signal_mode:lgSignalModeKey()}),
   _timeoutMs:18000
  });
  if(r&&r.status==='ok'){
   renderLgStatus(r);
   toast(enabled?'LG calibration mode enabled':'LG calibration mode disabled');
  }else{
   checkbox.checked=!enabled;
   toast(r&&r.message?r.message:'Unable to change LG calibration mode','err');
   loadLgStatus(true);
  }
	 }catch(e){
	  checkbox.checked=!enabled;
	  toast('Unable to change LG calibration mode','err');
	  loadLgStatus(true);
	 }finally{
	  lgEndCommand(commandHandle);
	  lgCalibrationModePending=false;
  const fresh=window.lgStatusState||{};
	  checkbox.disabled=!lgStatusConnected(fresh)||!!fresh.pinPending;
 }
}

async function lgForgetClient(){
 // Forget only the set selected in the device list (falls back to the active
 // TV when nothing is selected). Other paired TVs keep their saved keys.
 const selectedIp=(typeof lgSelectedDeviceIp==='function'?(lgSelectedDeviceIp('lgDeviceList')||''):'');
 const r=await fetchJSON('/api/lg/forget',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:selectedIp})});
 if(r&&r.status==='ok'){
	  lgPictureModeValue='';
	  lgPictureModeSignalMode='';
  lgDisplayControlInvalidate();
	  lgMarkDetectedPromptHandled(r);
  renderLgStatus(r);
  toast('Stored LG pairing cleared');
  // Refresh the device list so the forgotten pairing disappears
  // immediately (saved pairings are listed from the keyring).
  lgScanTvs(true);
 }else{
  toast(r&&r.message?r.message:'Unable to clear LG pairing','err');
 }
}

async function lgDisconnectClient(){
 const button=document.getElementById('lgDisconnectBtn');
 if(button) button.disabled=true;
 try{
  const r=await fetchJSON('/api/lg/disconnect',{method:'POST'});
  if(r&&r.status==='ok'){
   lgPictureModeValue='';
   lgPictureModeSignalMode='';
   lgDisplayControlInvalidate();
   renderLgStatus(r);
   toast('LG TV disconnected; pairing saved');
  }else{
   toast(r&&r.message?r.message:'Unable to disconnect LG TV','err');
  }
 }catch(e){
  toast('Unable to disconnect LG TV','err');
 }finally{
  const fresh=window.lgStatusState||{};
  if(button) button.disabled=!lgStatusConnected(fresh)||!lgStatusHasSavedKey(fresh)||!!fresh.pinPending;
 }
}

// --- Calibration history (final AutoCal uploads) ---
let lgCalHistoryCache=[];
let lgCalHistoryBusy=false;

function lgOpenCalHistoryModal(){
 const m=document.getElementById('lgCalHistoryModal');
 if(m){ m.style.display='flex'; m.setAttribute('aria-hidden','false'); }
 lgRefreshCalHistory();
}
function lgCloseCalHistoryModal(){
 const m=document.getElementById('lgCalHistoryModal');
 if(m){ m.style.display='none'; m.setAttribute('aria-hidden','true'); }
}
// Desktop: load history only when entering the LG Display workspace.
function lgMaybeRefreshCalHistoryForDesktopWorkspace(workspace,workspaceChanged){
 if(workspace!=='display-control') return;
 if(!workspaceChanged) return;
 if(!document.body.classList.contains('layout-desktop')) return;
 try{ lgRefreshCalHistory(); }catch(e){}
}

function lgCalHistoryTypeLabel(t){
 if(t==='1d') return '1D LUT';
 if(t==='3d') return '3D LUT';
 if(t==='dv') return 'DV Config';
 return t||'?';
}

function lgCalHistoryFormatTime(mtime){
 if(!mtime) return '';
 try{ return new Date(mtime*1000).toLocaleString(); }catch(e){ return ''; }
}

function lgRenderCalHistoryInto(el){
 if(!el) return;
 if(!lgCalHistoryCache.length){
  el.innerHTML='<div class="lg-cal-hist-empty">No final uploaded AutoCal artifacts found yet.</div>';
  return;
 }
 const groups={ '1d':[], '3d':[], 'dv':[] };
 lgCalHistoryCache.forEach(it=>{ if(groups[it.type]) groups[it.type].push(it); else groups['1d'].push(it); });
 let html='';
 [['1d','1D LUTs'],['3d','3D LUTs'],['dv','DV Configs']].forEach(([type,title])=>{
  const list=groups[type]||[];
  html+='<div class="lg-cal-hist-section"><div class="lg-cal-hist-title">'+title+' ('+list.length+')</div>';
  if(!list.length){ html+='<div class="lg-cal-hist-empty">None</div></div>'; return; }
  html+='<div class="lg-cal-hist-list">';
  list.forEach(it=>{
   const de=(it.de!=null&&isFinite(it.de))?' · best dE '+Number(it.de).toFixed(3):'';
   const note=it.note?('<small style="color:var(--orange)">'+String(it.note).replace(/</g,'&lt;')+'</small>'):'';
   const canUp=!(it.type==='dv'&&it.reuploadable===0);
   html+='<div class="lg-cal-hist-item" data-id="'+String(it.id||'').replace(/"/g,'&quot;')+'">'
    +'<div class="lg-cal-hist-meta"><strong>'+lgCalHistoryTypeLabel(it.type)+'</strong> '
    +String(it.label||it.id||'').replace(/</g,'&lt;')
    +'<small>'+lgCalHistoryFormatTime(it.mtime)
    +(it.signal_mode?(' · '+it.signal_mode):'')
    +(it.picture_mode?(' · '+it.picture_mode):'')
    +de+'</small>'+note+'</div>'
    +'<div class="lg-cal-hist-actions">'
    +(canUp?('<button type="button" class="btn btn-sm btn-primary" onclick="lgCalHistoryReupload(\''+String(it.id).replace(/'/g,"\\'")+'\')">Reupload</button>'):'')
    +((it.download||it.type==='1d'||(it.type==='3d'&&it.has_cube))?('<button type="button" class="btn btn-sm btn-secondary" onclick="lgCalHistoryDownload(\''+String(it.id).replace(/'/g,"\\'")+'\')">Download</button>'):'')
    +'</div></div>';
  });
  html+='</div></div>';
 });
 el.innerHTML=html;
}

async function lgRefreshCalHistory(){
 const hosts=[document.getElementById('lgCalHistoryBodyDesktop'),document.getElementById('lgCalHistoryBodyModal')];
 hosts.forEach(h=>{ if(h) h.innerHTML='Loading history...'; });
 try{
  const r=await fetchJSON('/api/lg/calibration-history?_='+Date.now(),{_quiet:true,_timeoutMs:12000,cache:'no-store'});
  lgCalHistoryCache=(r&&r.status==='ok'&&Array.isArray(r.items))?r.items:[];
 }catch(e){
  lgCalHistoryCache=[];
  hosts.forEach(h=>{ if(h) h.innerHTML='<div class="lg-cal-hist-empty">Unable to load history.</div>'; });
  return;
 }
 hosts.forEach(h=>lgRenderCalHistoryInto(h));
}

async function lgCalHistoryReupload(id){
 if(lgCalHistoryBusy) return;
 const item=lgCalHistoryCache.find(x=>x&&x.id===id);
 if(!item){ toast('History item not found','err'); return; }
 if(item.type==='dv'&&item.reuploadable===0){ toast(item.note||'Cannot reupload this DV config','err'); return; }
 if(!window.confirm('Reupload this '+lgCalHistoryTypeLabel(item.type)+' to the TV?\n\nCalibration mode will be enabled, the payload uploaded, then calibration mode disabled.')) return;
 lgCalHistoryBusy=true;
 try{
  if(typeof lgBeginCommand==='function') lgBeginCommand('Reuploading '+lgCalHistoryTypeLabel(item.type));
  const body={id:id,picture_mode:item.picture_mode||'',signal_mode:item.signal_mode||'',enable_calibration:true,disable_calibration:true};
  const r=await fetchJSON('/api/lg/calibration-history/reupload',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),_timeoutMs:180000});
  if(r&&r.status==='ok') toast(lgCalHistoryTypeLabel(item.type)+' reuploaded to TV');
  else toast((r&&r.message)||'Reupload failed','err');
 }catch(e){ toast('Reupload failed','err'); }
 finally{
  lgCalHistoryBusy=false;
  if(typeof lgEndCommand==='function') lgEndCommand();
  try{ if(typeof loadLgStatus==='function') loadLgStatus(true); }catch(e){}
 }
}

async function lgCalHistoryDownload(id){
 const item=lgCalHistoryCache.find(x=>x&&x.id===id);
 if(!item){ toast('History item not found','err'); return; }
 try{
  if(item.type==='3d'){
   const href=item.download||('/api/3d-lut/cube?file='+encodeURIComponent((item.base||'')+'.cube'));
   window.location.href=href;
   return;
  }
  if(item.type==='1d'){
   const r=await fetchJSON('/api/lg/calibration-history/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id}),_timeoutMs:60000});
   if(!(r&&r.status==='ok'&&Array.isArray(r.dpg_data))){ toast((r&&r.message)||'Download failed','err'); return; }
   const blob=new Blob([JSON.stringify(r,null,2)],{type:'application/json'});
   const a=document.createElement('a');
   a.href=URL.createObjectURL(blob);
   const model=String(item.display_model||r.display_model||'').replace(/[^A-Za-z0-9._-]+/g,'_').replace(/^[._-]+|[._-]+$/g,'');
   a.download=(model?(model+'_'):'')+(item.run_id||'1d')+'_dpg.json';
   document.body.appendChild(a); a.click(); a.remove();
   setTimeout(()=>URL.revokeObjectURL(a.href),2000);
   return;
  }
  toast('No download available for this item','err');
 }catch(e){ toast('Download failed','err'); }
}

// Calibration history loads only on demand:
// - tablet: History button -> lgOpenCalHistoryModal()
// - desktop: navigating to LG Display workspace (pgSelectDesktopWorkspace)


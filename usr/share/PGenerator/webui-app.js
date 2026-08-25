const API=window.location.origin;
let config={};
let modes=[];
let caps=null;

const IFACE_NAMES={
 eth0:'Ethernet',
 usb0:'Ethernet (USB)',
 wlan0:'WiFi',
 ap0:'WiFi AP',
 bnep:'Bluetooth PAN',
 bnep0:'Bluetooth PAN',
};

let toastHideTimer=0;
function toast(msg,err){
 const t=document.getElementById('toast');
 if(!t)return;
 if(toastHideTimer)clearTimeout(toastHideTimer);
 t.textContent=msg;t.className='toast'+(err?' error':'')+' show';
 // Success messages stay visible for 8 seconds; warnings and errors get 12.
 // Resetting the shared timer prevents an older toast from hiding a newer one.
 toastHideTimer=setTimeout(()=>{
  toastHideTimer=0;
  t.className='toast';
 },err?12000:8000);
}

// Apply Settings modal: full-screen mask + spinner/check card. The corner
// toast is too easy to miss when the operator just clicked "Apply &
// Restart" and the renderer is about to black out for 3-5s while it
// re-initializes. The modal stays up until the apply flow finishes and
// auto-dismisses on success.
function applySettingsModalShow(){
 const overlay=document.getElementById('applySettingsOverlay');
 if(!overlay) return;
 // Defensive: hide any stale LG Connect modal before popping the Apply
 // Settings modal. Without this, an errored LG Connect flow from a
 // previous click can leave #lgConnectOverlay visible, and because both
 // modals share z-index 9100 and #lgConnectOverlay is later in the DOM,
 // it stacks on top -- the operator sees "Connect to LG TV" instead of
 // "Apply Settings" while the renderer is restarting.
 if(typeof lgConnectModalHide==='function') lgConnectModalHide();
 document.body.classList.add('apply-settings-active');
 document.body.classList.remove('apply-settings-success','apply-settings-error');
 const title=document.getElementById('applySettingsTitle');
 const status=document.getElementById('applySettingsStatus');
 const hint=document.getElementById('applySettingsHint');
 if(title) title.textContent='Applying Settings';
 if(status) status.textContent='Saving and restarting the renderer\u2026';
 if(hint) hint.style.display='';
 overlay.setAttribute('aria-hidden','false');
}
function applySettingsModalSuccess(detail){
 const overlay=document.getElementById('applySettingsOverlay');
 if(!overlay) return;
 document.body.classList.add('apply-settings-success');
 const title=document.getElementById('applySettingsTitle');
 const status=document.getElementById('applySettingsStatus');
 if(title) title.textContent='Settings applied';
 if(status) status.textContent=detail||'New signal mode is live on the display.';
 setTimeout(()=>applySettingsModalHide(),1500);
}
function applySettingsModalError(detail){
 const overlay=document.getElementById('applySettingsOverlay');
 if(!overlay) return;
 document.body.classList.add('apply-settings-error');
 document.body.classList.remove('apply-settings-success');
 const title=document.getElementById('applySettingsTitle');
 const status=document.getElementById('applySettingsStatus');
 if(title) title.textContent='Apply failed';
 if(status) status.textContent=detail||'The renderer did not accept the new settings.';
 // Leave the modal up so the operator can read the error -- the corner
 // toast often scrolls off the visible area on long autocal sessions.
}
function applySettingsModalHide(){
 const overlay=document.getElementById('applySettingsOverlay');
 if(!overlay) return;
 overlay.setAttribute('aria-hidden','true');
 document.body.classList.remove('apply-settings-active','apply-settings-success','apply-settings-error');
}

async function waitForRendererRestart(restartId,timeoutMs){
 if(!restartId) throw new Error('The server did not return a renderer restart identifier.');
 const deadline=Date.now()+(Number(timeoutMs)||60000);
 while(Date.now()<deadline){
  const status=await fetchJSON('/api/restart/status?id='+encodeURIComponent(restartId),{_quiet:true,_timeoutMs:5000});
  if(status&&status.state==='ready') return status;
  if(status&&status.state==='error') throw new Error(status.message||'The renderer restart failed.');
  const statusEl=document.getElementById('applySettingsStatus');
  if(statusEl&&status&&status.message) statusEl.textContent=status.message;
  await new Promise(resolve=>setTimeout(resolve,250));
 }
 throw new Error('Timed out waiting for the renderer to become ready.');
}

// Meter Stop modal: blocks the dashboard while Stop waits on the
// backend (series kill, meter session teardown, autocal pkill). Show
// at the click frame so the operator never sees a "stopped but frozen"
// page with no feedback.
let meterStopModalKind='';
function meterStopModalShow(kind,statusText){
 const overlay=document.getElementById('meterStopOverlay');
 if(!overlay) return;
 meterStopModalKind=String(kind||'meter');
 // Only one of these full-screen masks at a time.
 if(typeof applySettingsModalHide==='function') applySettingsModalHide();
 if(typeof lgConnectModalHide==='function') lgConnectModalHide();
 document.body.classList.add('meter-stop-active');
 document.body.classList.remove('apply-settings-active','apply-settings-success','apply-settings-error','lg-connect-active');
 const title=document.getElementById('meterStopTitle');
 const status=document.getElementById('meterStopStatus');
 const labels={
  series:{title:'Stopping Series Read',status:'Waiting for the series and meter to stop\u2026'},
  continuous:{title:'Stopping Continuous Read',status:'Waiting for the meter to stop\u2026'},
  meter:{title:'Stopping Meter',status:'Waiting for the meter to stop\u2026'},
  autocal:{title:'Stopping Auto Cal',status:'Waiting for Auto Cal to stop\u2026'},
  '3d-autocal':{title:'Stopping 3D LUT AutoCal',status:'Waiting for 3D LUT AutoCal to stop\u2026'},
  'full-autocal':{title:'Stopping Full Auto Cal',status:'Waiting for Full Auto Cal to stop\u2026'},
  'resolve-connect':{title:'Connecting to Calibration Software',status:'Waiting for the calibration software to accept the Resolve connection\u2026'}
 };
 const pack=labels[meterStopModalKind]||labels.meter;
 if(title) title.textContent=pack.title;
 if(status) status.textContent=statusText||pack.status;
 // Cancel affordance: only the Resolve connect wait is user-abortable (the
 // "stopping" masks must run to completion). Show + wire it for that kind only.
 const cancelRow=document.getElementById('meterStopCancelRow');
 const cancelBtn=document.getElementById('meterStopCancelBtn');
 if(cancelRow&&cancelBtn){
  if(meterStopModalKind==='resolve-connect'){
   cancelBtn.onclick=resolveConnectCancel;
   cancelRow.style.display='';
  }else{
   cancelBtn.onclick=null;
   cancelRow.style.display='none';
  }
 }
 overlay.setAttribute('aria-hidden','false');
}
function meterStopModalHide(){
 const overlay=document.getElementById('meterStopOverlay');
 if(!overlay) return;
 overlay.setAttribute('aria-hidden','true');
 document.body.classList.remove('meter-stop-active','apply-settings-success','apply-settings-error');
 const cancelRow=document.getElementById('meterStopCancelRow');
 if(cancelRow) cancelRow.style.display='none';
 meterStopModalKind='';
}

// LG Connect modal helpers: the same modal skeleton (mask + spinner ->
// green check) as applySettings, but the success/error states stick
// around long enough for the operator to read the message because the
// WebOS WSS handshake can take 30-70s and the success/failure is the
// only feedback they'll get. The PIN field is only shown when
// lgConnect() detects a first-time pairing (no saved client key);
// lgConnectSubmitPinFromModal() reads the input and forwards to the
// existing lgSubmitPin() flow.
function lgConnectModalShow(showPinField,statusText){
 const overlay=document.getElementById('lgConnectOverlay');
 if(!overlay) return;
 // Use the LG-specific body class so the Apply Settings modal stays
 // hidden (its trigger is body.apply-settings-active). They share a
 // CSS skeleton but only one can be visible at a time. Also defensively
 // remove apply-settings-active in case the apply-settings flow left it
 // on (e.g., the user opened Connect right after Apply finished).
 document.body.classList.add('lg-connect-active');
 document.body.classList.remove('apply-settings-active','apply-settings-success','apply-settings-error');
 const title=document.getElementById('lgConnectTitle');
 const status=document.getElementById('lgConnectStatus');
 const pinField=document.getElementById('lgConnectPinField');
 const pinInput=document.getElementById('lgConnectPinInput');
 // Spinner state, so present tense. lgConnectModalSuccess flips this to
 // 'Connected to LG TV' and lgConnectModalError to 'Connect failed'.
 if(title) title.textContent='Connecting to LG TV';
 if(status) status.textContent=statusText||'Contacting the LG TV\u2026';
 if(pinField) pinField.style.display=showPinField?'flex':'none';
 if(pinInput){
  pinInput.value='';
  pinInput.disabled=!showPinField;
  if(showPinField){
   // Defer focus a tick so the modal transition completes first --
   // focus() on a display:none element is a no-op.
   setTimeout(()=>{try{pinInput.focus({preventScroll:true});}catch(e){}},50);
  }
 }
 overlay.setAttribute('aria-hidden','false');
}
// Reveal the LG Connect modal's PIN field after /api/lg/pair-pin/start
// has succeeded and the TV is actually showing a PIN. The initial
// lgConnectModalShow() call passes showPinField=false so the operator
// doesn't see an input they can't fill yet; this helper flips the field
// on and focuses it when the TV is ready. The modal stays up through
// this transition -- the spinner/check carries the wait.
function lgConnectModalRevealPinField(){
 const pinField=document.getElementById('lgConnectPinField');
 const pinInput=document.getElementById('lgConnectPinInput');
 if(pinField) pinField.style.display='flex';
 if(pinInput){
  pinInput.disabled=false;
  setTimeout(()=>{
   try{pinInput.focus({preventScroll:true});}catch(e){pinInput.focus();}
   if(pinInput.select) pinInput.select();
  },50);
 }
}
function lgConnectModalPinStatus(statusText){
 const status=document.getElementById('lgConnectStatus');
 if(status) status.textContent=statusText;
}
function lgConnectModalSuccess(detail){
 const overlay=document.getElementById('lgConnectOverlay');
 if(!overlay) return;
 document.body.classList.add('apply-settings-success');
 const title=document.getElementById('lgConnectTitle');
 const status=document.getElementById('lgConnectStatus');
 const pinField=document.getElementById('lgConnectPinField');
 if(title) title.textContent='Connected to LG TV';
 if(status) status.textContent=detail||'The LG TV is now paired and reachable.';
 if(pinField) pinField.style.display='none';
 setTimeout(()=>lgConnectModalHide(),2000);
}
function lgConnectModalError(detail){
 const overlay=document.getElementById('lgConnectOverlay');
 if(!overlay) return;
 document.body.classList.add('apply-settings-error');
 document.body.classList.remove('apply-settings-success');
 // Make sure the apply-settings flag is off so a stale Apply Settings
 // modal can't pop back over the LG error state if the user happened
 // to leave it up before clicking Connect.
 document.body.classList.remove('apply-settings-active');
 document.body.classList.add('lg-connect-active');
 const title=document.getElementById('lgConnectTitle');
 const status=document.getElementById('lgConnectStatus');
 if(title) title.textContent='Connect failed';
 // Translate a few opaque LG library errors into something the operator
 // can act on. The raw "User rejected pairing" / "403 Error: ..."
 // messages from the WebOS pairing helper make it sound like the LG
 // service is talking to a different user, when in practice the cause
 // is either: (a) the pairing prompt timed out on the TV before the
 // operator submitted, (b) the operator dismissed the prompt on the TV
 // remote, or (c) the PIN they typed didn't match what the TV showed.
 if(status){
  const raw=String(detail||'');
  if(/user\s*rejected\s*pairing/i.test(raw)||/^\s*403\b/.test(raw)){
   status.textContent='The LG TV rejected the pairing (the prompt may have timed out, been dismissed on the TV, or the PIN didn\'t match). Click Connect to try again.';
  }else{
   status.textContent=raw||'Unable to connect to the LG TV.';
  }
 }
 // Leave the modal up so the operator can read the error -- the corner
 // toast often scrolls off the visible area on long autocal sessions.
}
function lgConnectModalHide(){
 const overlay=document.getElementById('lgConnectOverlay');
 if(!overlay) return;
 overlay.setAttribute('aria-hidden','true');
 // Remove the LG-specific trigger. Leave apply-settings-* alone --
 // Apply Settings has its own show() and shouldn't be cleared by an
 // LG Cancel. Only remove apply-settings-active defensively if it
 // wasn't actually set by applySettingsModalShow() in this session
 // (we can't tell cheaply, so just leave it).
 document.body.classList.remove('lg-connect-active');
 const pinInput=document.getElementById('lgConnectPinInput');
 if(pinInput) pinInput.value='';
 // Bump the cancellation token so any in-flight lgConnect() flow
 // (especially the 15s lgStartPinPairing() wait that has no resolver
 // to wake up) aborts at its next await boundary without stomping on
 // a follow-up click.
 if(typeof window._lgConnectToken==='number') window._lgConnectToken++;
 // Wake up any pending lgConnect() flow waiting for a PIN so it can
 // bail out instead of hanging on a now-hidden modal.
 if(window._lgPinResolver){
  const r=window._lgPinResolver;
  window._lgPinResolver=null;
  r(null);
 }
 // Re-enable the connect button so the operator can click it again
 // immediately. lgConnect() disables the button at the top of the
 // flow ("Starting Pairing..." / "Connecting...") and only re-enables
 // it at the end -- which can take 15+ seconds if the user clicks
 // Cancel mid-pair-pin/start. Without this the button is dead for
 // the whole wait and the operator has to refresh the page. The
 // flow's own re-enable paths are idempotent (they set textContent
 // + disabled=false again), so it's safe to flip it here as soon
 // as the modal goes away.
 const connectBtn=document.getElementById('lgConnectBtn');
 if(connectBtn&&connectBtn.disabled){
  connectBtn.disabled=false;
  // Mirror the same label rule renderLgStatus uses so the two stay
  // in sync: "Connect" if paired||clientKeyPresent, otherwise
  // "Pair With PIN". Read the live status state from
  // window.lgStatusState (kept current by renderLgStatus).
  const state=window.lgStatusState||{};
  const pairedOrKey=!!(state.paired||state.clientKeyPresent||state.client_key_present);
  connectBtn.textContent=pairedOrKey?'Connect':'Pair With PIN';
 }
}
// Reads the modal PIN input and resolves the pending lgConnect() flow
// (window._lgPinResolver). The modal is the only PIN entry point in the
// new flow -- the old lgSubmitPin() handler in lg.pm read from the
// removed lgPairPin input in the display card, so calling it would
// always see an empty value. Instead, lgConnect() registers a one-shot
// resolver when it enters the PIN-waiting state, and this helper wakes
// it up with the typed PIN. Enter-to-submit is bridged inline by the
// onkeydown attribute on the input.
function lgConnectSubmitPinFromModal(){
 const input=document.getElementById('lgConnectPinInput');
 if(!input) return;
 const pin=String(input.value||'').replace(/\D+/g,'');
 if(!/^\d{4,8}$/.test(pin)){
  input.focus();
  return;
 }
 if(window._lgPinResolver){
  const r=window._lgPinResolver;
  window._lgPinResolver=null;
  r(pin);
  return;
 }
 // No pending connect flow. The Submit button only appears inside the
 // modal, and the modal is only opened by lgConnect() which always
 // registers a resolver when the PIN field is visible, so this branch
 // should not be reachable in normal use. Fall back to a toast so a
 // stale modal can't submit a PIN into a closed pairing session.
 if(typeof toast==='function') toast('No pending LG Connect flow. Click Connect to start.','err');
}

let _pingFailCount=0;
let _uiOffline=false;
let _lastLgBusyConnectionNoticeAt=0;
window._configApplyPending=false;
window._lgCommandBusyCount=window._lgCommandBusyCount||0;
window._lgCommandBusyLabel=window._lgCommandBusyLabel||'';
window._lgCommandBusyStartedAt=window._lgCommandBusyStartedAt||0;
window._lgCommandBusyTimer=window._lgCommandBusyTimer||null;

function lgIsCommandBusy(){
	 try{
	  return !!((Number(window._lgCommandBusyCount)||0)>0
	   ||(typeof meterLgGreyBusy!=='undefined'&&meterLgGreyBusy));
	 }catch(e){
	  return (Number(window._lgCommandBusyCount)||0)>0;
	 }
	}

function lgBusyLabel(){
	 const label=String(window._lgCommandBusyLabel||'').trim();
	 return label||'Communicating with LG TV';
	}

function lgFormatBusyElapsed(startedAt){
	 const start=Number(startedAt)||0;
	 if(!start) return '';
	 const seconds=Math.max(0,Math.floor((Date.now()-start)/1000));
	 return seconds<60 ? (seconds+'s') : (Math.floor(seconds/60)+'m '+String(seconds%60).padStart(2,'0')+'s');
	}

function updateLgCommandBusyUi(){
	 const active=lgIsCommandBusy();
	 const label=lgBusyLabel();
	 const startedAt=Number(window._lgCommandBusyStartedAt)||0;
	 const box=document.getElementById('lgCommandStatus');
	 const text=document.getElementById('lgCommandStatusText');
	 const elapsed=document.getElementById('lgCommandElapsed');
	 if(box) box.style.display=active?'flex':'none';
	 if(text) text.textContent=label+'...';
	 if(elapsed) elapsed.textContent=active?lgFormatBusyElapsed(startedAt):'';
	 if(typeof syncMeterLgRgbBusyIndicator==='function') syncMeterLgRgbBusyIndicator();
	 if(active) setConnectionBusyStatus('LG TV');
	 ['lgConnectBtn','lgPinSubmitBtn','lgPictureMode','lgCalibrationMode'].forEach(id=>{
	  const el=document.getElementById(id);
	  if(!el) return;
	  if(active){
	   if(el.dataset.lgBusyPrevDisabled==null) el.dataset.lgBusyPrevDisabled=el.disabled?'1':'0';
	   el.disabled=true;
	  }else if(el.dataset.lgBusyPrevDisabled!=null){
	   el.disabled=el.dataset.lgBusyPrevDisabled==='1';
	   delete el.dataset.lgBusyPrevDisabled;
	  }
	 });
	}

function lgBeginCommand(label){
	 window._lgCommandBusyCount=Math.max(0,Number(window._lgCommandBusyCount)||0)+1;
	 window._lgCommandBusyLabel=String(label||'Communicating with LG TV');
	 if(!window._lgCommandBusyStartedAt) window._lgCommandBusyStartedAt=Date.now();
	 if(window._lgCommandBusyTimer) clearInterval(window._lgCommandBusyTimer);
	 window._lgCommandBusyTimer=setInterval(updateLgCommandBusyUi,1000);
	 updateLgCommandBusyUi();
	 return {done:false};
	}

function lgEndCommand(handle){
	 if(handle&&handle.done) return;
	 if(handle) handle.done=true;
	 window._lgCommandBusyCount=Math.max(0,(Number(window._lgCommandBusyCount)||0)-1);
	 if(window._lgCommandBusyCount===0){
	  window._lgCommandBusyLabel='';
	  window._lgCommandBusyStartedAt=0;
	  if(window._lgCommandBusyTimer) clearInterval(window._lgCommandBusyTimer);
	  window._lgCommandBusyTimer=null;
	 }
	 updateLgCommandBusyUi();
	 if(window._lgCommandBusyCount===0) setTimeout(()=>checkPing(),150);
	}

function noteLgBusyConnectionDelay(){
	 const now=Date.now();
	 if(now-_lastLgBusyConnectionNoticeAt<3500) return;
	 _lastLgBusyConnectionNoticeAt=now;
	 toast('LG TV command still running; UI polling is paused until it finishes');
	 updateLgCommandBusyUi();
	}

function isCalibrationWorkflowActive(){
	 try{
	  return !!((typeof meterContinuousActive!=='undefined'&&meterContinuousActive)
	   ||(typeof meterContinuousSuspendedForLgWrite!=='undefined'&&meterContinuousSuspendedForLgWrite)
	   ||(typeof meterLgGreyBusy!=='undefined'&&meterLgGreyBusy)
	   ||lgIsCommandBusy()
	   ||(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning)
   ||(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
	   ||(typeof meterActionPending!=='undefined'&&meterActionPending)
	   ||(typeof meterPingBusy!=='undefined'&&meterPingBusy)
	   ||(typeof meterSeriesAwaitingReady!=='undefined'&&meterSeriesAwaitingReady)
   ||(typeof meterSeriesSpectroSetupActive!=='undefined'&&meterSeriesSpectroSetupActive)
	   ||(typeof meterManualPromptAwaiting!=='undefined'&&meterManualPromptAwaiting));
 }catch(e){
  return false;
 }
}

function setConnectionBusyStatus(label){
	 _pingFailCount=0;
	 setUiOffline(false);
 const dot=document.getElementById('statusDot');
 const text=document.getElementById('statusText');
 const wrap=document.getElementById('statusWrap');
 if(dot) dot.style.background='var(--orange)';
	 if(text) text.textContent=label||'Busy';
	 if(wrap) wrap.title='Calibration in progress';
 setPowerButtonState(true);
}

function setUiOffline(offline){
 offline=!!offline;
 if(_uiOffline===offline) return false;
 _uiOffline=offline;
 document.body.classList.toggle('ui-offline',offline);
 const overlay=document.getElementById('offlineMask');
 if(overlay) overlay.setAttribute('aria-hidden',offline?'false':'true');
 if(offline){
  try{
   const active=document.activeElement;
   if(active&&typeof active.blur==='function') active.blur();
  }catch(e){}
 }
 return true;
}

async function fetchJSON(url,opts){
 const req=Object.assign({},opts||{});
 const quiet=!!req._quiet;
 const timeoutMs=req._timeoutMs||8000;
 delete req._quiet;
 delete req._timeoutMs;
 let timer=null;
 if(!req.signal){
  const controller=new AbortController();
  req.signal=controller.signal;
  timer=setTimeout(()=>controller.abort(),timeoutMs);
 }
 try{
  const r=await fetch(API+url,req);
  return await r.json();
	 }
 catch(e){
  if(!quiet){
   if(lgIsCommandBusy()) noteLgBusyConnectionDelay();
   else if(typeof cecIsCommandBusy==='function'&&cecIsCommandBusy()){}
   else toast('Connection error','err');
  }
  return null;
	 }
 finally{
  if(timer)clearTimeout(timer);
 }
}

async function loadConfig(quiet){
 if(quiet&&shouldPauseAutoRefresh()) return;
 const loadedConfig=await fetchJSON('/api/config',{_quiet:!!quiet,_timeoutMs:10000});
 if(!loadedConfig)return;
 applyConfigState(loadedConfig);
}

function normalizeColorimetryValue(value,signalMode){
 const val=String(value==null?'':value);
 if(val==='2'||val==='9') return val;
 return webuiAutoColorimetryForSignalMode(signalMode);
}

//
// Helper: the default Target Colourspace for a given signal mode.
// BT.2020 (9) for HDR10 / HLG / Dolby Vision; BT.709 (2) for SDR.
// Used by both the user-driven signal_mode change handler and the
// polled /api/config refresh path so the dropdown follows the
// signal mode in both directions and stays user-editable after the
// auto-set (the next /api/config poll respects the server's
// persisted colorimetry, so any manual edit survives one poll
// cycle and the server remains the source of truth).
//
function webuiAutoColorimetryForSignalMode(signalMode){
 const sm=String(signalMode||'').toLowerCase();
 if(sm==='hdr10'||sm==='hlg'||sm==='dv') return '9';
 return '2';
}

function applyConfigState(nextConfig){
 config=nextConfig;
 window._remoteConfigSnapshot=JSON.stringify(nextConfig);
 const rfc=document.getElementById('resolveForceCenter');
 if(rfc) rfc.checked=String(config.resolve_force_center||'0')==='1';
 const rps=document.getElementById('resolvePatchSize');
 if(rps&&document.activeElement!==rps) rps.value=(config.resolve_patch_size&&/^\d+$/.test(String(config.resolve_patch_size)))?String(config.resolve_patch_size):'';
 // Derive signal mode from flags
 let sm='sdr';
 if(config.dv_status==='1'||config.is_ll_dovi==='1'||config.is_std_dovi==='1') sm='dv';
 else if(config.is_hdr==='1'){
  sm=(config.eotf==='3')?'hlg':'hdr10';
 }
 setVal('mode_idx',config.mode_idx||'');
 setVal('signal_mode',sm);
 setVal('max_bpc',config.max_bpc||'8');
 setVal('color_format',config.color_format||'0');
 setVal('colorimetry',normalizeColorimetryValue(config.colorimetry,sm));
 setVal('rgb_quant_range',config.rgb_quant_range||'0');
 try{ uiEnforceQuantRangeForColorFormat(); }catch(e){}
 setVal('eotf',config.eotf||'0');
 setVal('primaries',config.primaries||'0');
 // The static HTML defaults are SDR values. Before durable meter settings
 // arrive, seed the calibration targets from the restored output mode so a
 // cold HDR start cannot get stuck on BT.709 and BT.1886.
 applyMeterTargetGamutDefault(!meterSettingsLoaded);
 document.getElementById('max_luma').value=config.max_luma||'1000';
 document.getElementById('min_luma').value=config.min_luma||'0.005';
 document.getElementById('max_cll').value=config.max_cll||'1000';
 document.getElementById('max_fall').value=config.max_fall||'400';
 meterSyncHdrMetadata();
 try{ if(typeof meterSyncTargetGammaOptionsForSignal==='function') meterSyncTargetGammaOptionsForSignal(); }catch(e){}
 if(!meterSettingsLoaded) applyMeterTargetGammaDefault(true);
 // Restore the calibration-card low-light handler from localStorage so
 // the operator's last selection (e.g. 3-read averaging for 1.4% IRE)
 // persists across page loads.
 try{ meterRestoreLowLightHandler(); }catch(e){}
 try{ meterRestoreSeriesBeepPref(); }catch(e){}
 try{ meterRestoreTargetLevels(); }catch(e){}
	 // DV settings
	 setVal('dv_transport',dvTransportMode(config.dv_transport));
	 setVal('dv_interface',config.dv_interface||'0');
	 setVal('dv_map_mode',config.dv_map_mode||'2');
	 if(sm==='dv'){
	  syncDvOutputEotfState();
	  const dvTransport=dvTransportDefaults(getVal('dv_transport'));
	  setVal('dv_transport',dvTransport.dv_transport);
	  setVal('max_bpc',dvRgbMaxBpc(config.max_bpc||dvTransport.max_bpc));
	  setVal('color_format',dvTransport.color_format);
  setVal('dv_interface',dvTransport.dv_interface);
  setVal('colorimetry','9');
  setVal('primaries','1');
  setVal('rgb_quant_range','2');
  applyMeterTargetGammaDefault();
  saveMeterSettings();
 }
 updateModeVisibility();
 updateDropdowns();
 refreshSavedSettingsSnapshot();
}

async function syncRemoteConfig(){
 if(shouldPauseAutoRefresh()||window._configSyncBusy) return;
 window._configSyncBusy=true;
 try{
  const remoteConfig=await fetchJSON('/api/config',{_quiet:true,_timeoutMs:10000});
  if(!remoteConfig)return;
  const remoteSnapshot=JSON.stringify(remoteConfig);
  if(!window._remoteConfigSnapshot||remoteSnapshot!==window._remoteConfigSnapshot){
   applyConfigState(remoteConfig);
   // When the config changes (e.g. reference switches signal mode,
   // resolution, or color format), also refresh /api/info so the
   // info-grid resolution display updates within the same poll
   // cycle. Without this the resolution field would only refresh
   // on the 30s loadInfo interval and would lag the config change.
   const prev=window._remoteConfigSnapshot?JSON.parse(window._remoteConfigSnapshot):null;
   const modeChanged=prev && (
    prev.mode_idx!==remoteConfig.mode_idx ||
    prev.signal_mode!==remoteConfig.signal_mode ||
    prev.color_format!==remoteConfig.color_format ||
    prev.max_bpc!==remoteConfig.max_bpc ||
    prev.colorimetry!==remoteConfig.colorimetry
   );
   if(modeChanged && typeof loadInfo==='function'){
    loadInfo(true);
   }
  }
 }
 finally{
  window._configSyncBusy=false;
 }
}

function setVal(id,v){const el=document.getElementById(id);if(el)el.value=v;}
function getVal(id){const el=document.getElementById(id);return el?el.value:'';}
// Human-readable label of the currently-selected <option> for a <select> id.
// Falls back to the raw value if the element/option is missing so this never
// throws and degrades gracefully in headless/test contexts.
function meterSelectLabel(id){const el=document.getElementById(id);if(!el)return getVal(id)||'';const o=el.options&&el.options[el.selectedIndex];return o?(o.textContent||'').trim():(el.value||'');}

function dvMetadataForMapMode(mapMode){
 mapMode=String(mapMode||'');
 if(mapMode==='1') return '3';
 if(mapMode==='2') return '4';
 return '2';
}

function syncDvOutputEotfState(){
 if(getVal('signal_mode')==='dv') setVal('eotf','2');
}

function meterHdrMetadataFieldId(key,mode){
 const sm=mode||getVal('signal_mode')||'sdr';
 if(sm==='dv'){
  if(key==='max_luma') return 'dv_max_luma';
  if(key==='min_luma') return 'dv_min_luma';
  if(key==='max_cll') return 'dv_max_cll';
  if(key==='max_fall') return 'dv_max_fall';
 }
 return key;
}

function meterHdrMetadataFieldValue(key,mode){
 const el=document.getElementById(meterHdrMetadataFieldId(key,mode));
 return el?el.value:'';
}

function meterCopyHdrMetadataFields(fromMode,toMode){
 ['max_luma','min_luma','max_cll','max_fall'].forEach(key=>{
  const src=document.getElementById(meterHdrMetadataFieldId(key,fromMode));
  const dst=document.getElementById(meterHdrMetadataFieldId(key,toMode));
  if(src&&dst) dst.value=src.value;
 });
}

let meterLastHdrMetadataMode=null;

function meterSyncHdrMetadataFieldMirrors(){
 const sm=getVal('signal_mode')||'sdr';
 if(meterLastHdrMetadataMode==null){
  if(sm==='dv') meterCopyHdrMetadataFields('hdr10','dv');
 }else if(sm==='dv'&&meterLastHdrMetadataMode!=='dv'){
  meterCopyHdrMetadataFields('hdr10','dv');
 }else if(sm!=='dv'&&meterLastHdrMetadataMode==='dv'){
  meterCopyHdrMetadataFields('dv','hdr10');
 }
 meterLastHdrMetadataMode=sm;
}

function meterSyncHdrMetadata(){
 const meterPeak=document.getElementById('meterHdrMasterPeak');
 const meterMin=document.getElementById('meterHdrMasterMin');
 meterSyncHdrMetadataFieldMirrors();
 if(!meterPeak||!meterMin) return;
 const peakVal=meterHdrMetadataFieldValue('max_luma')||((config&&config.max_luma)||'1000');
 const minVal=meterHdrMetadataFieldValue('min_luma')||((config&&config.min_luma)||'0.005');
 meterPeak.value=peakVal;
 meterMin.value=minVal;
}

function captureSettings(){
 return JSON.stringify({
  mode_idx:getVal('mode_idx'),signal_mode:getVal('signal_mode'),
  max_bpc:getVal('max_bpc'),color_format:getVal('color_format'),
  colorimetry:getVal('colorimetry'),rgb_quant_range:getVal('rgb_quant_range'),
  eotf:getVal('eotf'),primaries:getVal('primaries'),
	  max_luma:meterHdrMetadataFieldValue('max_luma'),
	  min_luma:meterHdrMetadataFieldValue('min_luma'),
	  max_cll:meterHdrMetadataFieldValue('max_cll'),
	  max_fall:meterHdrMetadataFieldValue('max_fall'),
	  dv_transport:getVal('dv_transport'),
	  dv_interface:getVal('dv_interface'),
	  dv_map_mode:getVal('dv_map_mode')
	 });
}

function refreshSavedSettingsSnapshot(){
 window._savedConfig=captureSettings();
 checkSettingsChanged();
}

function hasUnsavedSettings(){
 if(!window._savedConfig)return false;
 return captureSettings()!==window._savedConfig;
}

function isSettingsFieldActive(){
 const el=document.activeElement;
 if(!el||!el.id)return false;
	 return ['mode_idx','signal_mode','max_bpc','color_format','colorimetry','rgb_quant_range',
	  'eotf','primaries','dv_transport','dv_interface','dv_map_mode','max_luma','min_luma','max_cll','max_fall',
	  'dv_max_luma','dv_min_luma','dv_max_cll','dv_max_fall'].includes(el.id);
}

function shouldPauseAutoRefresh(){
 return !!window._configApplyPending||isSettingsFieldActive()||hasUnsavedSettings()||isCalibrationWorkflowActive();
}

function checkSettingsChanged(){
 if(!window._savedConfig)return;
 var changed=captureSettings()!==window._savedConfig;
 document.getElementById('applyBar').style.display=changed?'':'none';
 if(typeof meterUpdateReadButtons==='function') meterUpdateReadButtons();
 // Defensive: a stale or in-flight LG Connect modal from a previous
 // click must not obstruct the display-settings card. The operator's
 // intent at this moment is to tweak display settings; clear any LG
 // modal up front so they don't see "Connect to LG TV" over the
 // dropdowns. Also wakes up any pending _lgPinResolver so an
 // orphaned lgConnect() doesn't hang in the background.
 if(typeof lgConnectModalHide==='function') lgConnectModalHide();
}

// Output changes can rebuild every patch thumbnail and chart. Running that
// work in the same change event prevents the browser from painting the dirty
// Apply bar until the rebuild finishes (signal mode also used to rebuild
// twice, once here and once in its dedicated handler). Coalesce the dependent
// calibration refresh and run it only after the browser has painted the
// immediately-updated output controls.
let meterOutputSettingsRefreshQueued=false;
let meterOutputSettingsSaveQueued=false;
function meterQueueOutputSettingsRefresh(saveMeterPrefs){
 meterOutputSettingsSaveQueued=meterOutputSettingsSaveQueued||!!saveMeterPrefs;
 if(meterOutputSettingsRefreshQueued) return;
 meterOutputSettingsRefreshQueued=true;
 const afterPaint=()=>{
  setTimeout(()=>{
   const savePrefs=meterOutputSettingsSaveQueued;
   meterOutputSettingsRefreshQueued=false;
   meterOutputSettingsSaveQueued=false;
   meterGreySyncUi();
   meterUpdateSeriesTabUi();
   updateMeterTargetWhitepointVisibility();
   meterSyncHdrDiffuseWhiteControl();
   meterSyncActiveSeriesSignalMode();
   meterSyncTwoPointInputs();
   meterRefreshActiveSeriesCharts();
   meterUpdateReadButtons();
   try{ if(typeof meterSyncTargetGammaOptionsForSignal==='function') meterSyncTargetGammaOptionsForSignal(); }catch(e){}
   if(savePrefs) saveMeterSettings();
  },0);
 };
 if(typeof requestAnimationFrame==='function') requestAnimationFrame(afterPaint);
 else afterPaint();
}

function updateModeVisibility(){
 const sm=getVal('signal_mode');
 document.getElementById('hdrCard').style.display=(sm==='hdr10'||sm==='hlg')?'':'none';
 document.getElementById('dvCard').style.display=(sm==='dv')?'':'none';
 meterSyncHcfrFixedCodesUi();
 syncDvOutputEotfState();
 meterSyncTargetGammaControl();
 updateDiagAvsHd709Visibility();
 meterSyncHdrMetadata();
}

	['mode_idx','signal_mode','max_bpc','color_format','colorimetry','rgb_quant_range',
	 'eotf','primaries','dv_transport','dv_interface','dv_map_mode'].forEach(function(id){
	 document.getElementById(id).addEventListener('change',checkSettingsChanged);
	});
['max_luma','min_luma','max_cll','max_fall'].forEach(function(id){
 const el=document.getElementById(id);
 if(!el) return;
 const sync=function(event){
  if((id==='max_luma' || id==='min_luma') && getVal('signal_mode')!=='dv'){
   meterSyncHdrMetadata();
   if(meterReadings&&meterReadings.length) meterOnGreyRefChange();
  }else if(getVal('signal_mode')!=='dv'){
   meterSyncHdrMetadataFieldMirrors();
  }
  if(id==='max_luma'&&event&&event.type==='change') meterWarnTargetWhiteAboveHdrMax();
  checkSettingsChanged();
 };
 el.addEventListener('input',sync);
 el.addEventListener('change',sync);
});
[['dv_max_luma','max_luma'],['dv_min_luma','min_luma'],['dv_max_cll','max_cll'],['dv_max_fall','max_fall']].forEach(function(pair){
 const el=document.getElementById(pair[0]);
 if(!el) return;
 const sync=function(event){
  if(getVal('signal_mode')==='dv' && (pair[1]==='max_luma' || pair[1]==='min_luma')){
   meterSyncHdrMetadata();
   if(meterReadings&&meterReadings.length) meterOnGreyRefChange();
  }else if(getVal('signal_mode')==='dv'){
   meterSyncHdrMetadataFieldMirrors();
  }
  if(pair[1]==='max_luma'&&event&&event.type==='change') meterWarnTargetWhiteAboveHdrMax();
  checkSettingsChanged();
 };
 el.addEventListener('input',sync);
 el.addEventListener('change',sync);
});
	// Re-filter dropdowns when mode, bit depth, color format, or DV transport changes
	['mode_idx','max_bpc','color_format','dv_transport','dv_interface'].forEach(function(id){
	 document.getElementById(id).addEventListener('change',updateDropdowns);
	});
document.getElementById('mode_idx').addEventListener('change',updateModeSelectLabel);

function meterDefaultTargetGamutForMode(){
 const sm=(document.getElementById('signal_mode')||{}).value||'sdr';
 // HDR10 post-cal series + chart target = P3-D65 (consumer HDR is mastered to
 // P3 inside the BT.2020 container), so reads are scored against P3, not the
 // BT.2020 container. HLG stays on the BT.2020 container.
 if(sm==='hdr10') return 'p3d65';
 if(sm==='hlg') return 'bt2020';
 return sm==='sdr' ? 'bt709' : 'p3d65';
}

// HDR10 matrix/3D-LUT target gamut = the HDR METADATA (mastering-display)
// PRIMARIES setting (#primaries), NOT the target-gamut / colorspace controls.
// Source MUST be #primaries (the "Primaries" select, values 0-3) — never
// meterTargetGamut (the chart target gamut) and never #colorimetry (the
// BT.2020 container/colorspace). The signal still rides in the BT.2020
// container (chart + BT2020_3D_LUT_DATA upload slot are unchanged), but the
// LUT is solved toward the metadata primaries the content was mastered in.
// #primaries: 0=custom/BT.709, 1=BT.2020, 2=P3/D65, 3=P3/DCI. Default P3/D65.
function meterHdrMetadataGamut(){
 const p=String((document.getElementById('primaries')||{}).value||'2');
 if(p==='1') return 'bt2020';
 if(p==='3') return 'p3dci';
 if(p==='0') return 'bt709';
 return 'p3d65';
}

function applyMeterTargetGamutDefault(force){
 const g=document.getElementById('meterTargetGamut');
 if(!g) return;
 if(force || !g.value || g.value==='auto') g.value=meterDefaultTargetGamutForMode();
}

function meterPatternInsertionDefaultsForMode(){
 const sm=String((document.getElementById('signal_mode')||{}).value||'sdr').toLowerCase();
 const hdrLike=sm==='hdr10'||sm==='hlg'||sm==='dv';
 return {
  timeEnabled:true,
  timeFrequency:hdrLike?5:45,
  timeDuration:5,
  timeLevel:25,
  patchEnabled:hdrLike,
  patchEvery:1,
  patchDuration:1,
  patchLevel:10
 };
}

function meterApplyPatternInsertionDefaults(force){
 const d=meterPatternInsertionDefaultsForMode();
 const setChkIf=(id,value)=>{ const el=document.getElementById(id); if(el&&(force||el.dataset.defaulted==='1'||el.dataset.defaulted==null)){ el.checked=!!value; el.dataset.defaulted='1'; } };
 const setValIf=(id,value)=>{ const el=document.getElementById(id); if(el&&(force||el.dataset.defaulted==='1'||el.dataset.defaulted==null)){ el.value=meterDelayFormatSeconds(value); el.dataset.defaulted='1'; } };
 setChkIf('meterPatchInsertTimeEnabled',d.timeEnabled);
 setValIf('meterPatchInsertTimeFrequency',d.timeFrequency);
 setValIf('meterPatchInsertTimeDuration',d.timeDuration);
 setValIf('meterPatchInsertTimeLevel',d.timeLevel);
 setChkIf('meterPatchInsertPatchEnabled',d.patchEnabled);
 setValIf('meterPatchInsertPatchEvery',d.patchEvery);
 setValIf('meterPatchInsertPatchDuration',d.patchDuration);
 setValIf('meterPatchInsertPatchLevel',d.patchLevel);
}

function meterPatternInsertionControlIds(){
 return [
  'meterPatchInsertTimeEnabled','meterPatchInsertTimeFrequency','meterPatchInsertTimeDuration','meterPatchInsertTimeLevel',
  'meterPatchInsertPatchEnabled','meterPatchInsertPatchEvery','meterPatchInsertPatchDuration','meterPatchInsertPatchLevel'
 ];
}

function meterMarkPatternInsertionControlsUserSet(){
 meterPatternInsertionControlIds().forEach(id=>{ const el=document.getElementById(id); if(el) el.dataset.defaulted='0'; });
}

function meterDvAutoTargetGamma(){
 return meterDvMapModeValue()==='2' ? '2.2' : 'st2084';
}

function meterSyncTargetGammaControl(){
 const g=document.getElementById('meterTargetGamma');
 if(!g) return;
 const sm=(document.getElementById('signal_mode')||{}).value||'sdr';
 // The Target Gamma dropdown is always selectable. The chart math and the
 // calibration solver pin their own curve from dv_map_mode during an active
 // calibration (meterHdrAutoCalUsesPowerGammaChartMath + solver config), so
 // disabling the control here only caused it to grey out on phantom/stale
 // running states after a service restart. Keep it enabled; just annotate.
 g.disabled=false;
 if(sm==='dv'){
  g.title=(meterDvMapModeValue()==='2')
   ? 'Dolby Vision Relative default is ST 2084 (PQ target curve); calibration pins 2.2.'
   : 'Dolby Vision Absolute default is ST 2084; 2.2 renders the standard EOTF.';
 }else{
  g.title='';
 }
}

function meterSyncTargetGammaOptionsForSignal(){
 const g=document.getElementById('meterTargetGamma');
 if(!g) return;
 const sm=String((typeof getVal==='function'?getVal('signal_mode'):'')||'sdr').toLowerCase();
 const isSdr=(sm==='sdr');
 for(const opt of g.options){
  if(opt.value==='st2084'){ opt.hidden=isSdr; opt.disabled=isSdr; }
 }
 // ST 2084 is an HDR EOTF; never leave it selected for SDR.
 if(isSdr&&g.value==='st2084'){ g.value='bt1886'; if(typeof meterSyncTargetGammaControl==='function') meterSyncTargetGammaControl(); }
}

function applyMeterTargetGammaDefault(force){
 const g=document.getElementById('meterTargetGamma');
 if(!g) return;
 // Never clobber an operator-chosen target gamma unless force=true (used by
 // the signal_mode change handler to land on the mode-appropriate default
 // when the operator switches modes). DV is freely selectable
 // (2.2 or ST 2084); the calibration solver pins the curve at run time.
 if(!force && g.value) { meterSyncTargetGammaControl(); return; }
 const sm=document.getElementById('signal_mode').value;
 const displayType=document.getElementById('meterDisplayType').value;
 if(sm==='dv') g.value='st2084';
 else if(sm==='hdr10') g.value='st2084';
 else if(displayType.startsWith('projector')) g.value='2.2';
 else g.value='bt1886';
 meterSyncTargetGammaControl();
}

document.getElementById('signal_mode').addEventListener('change',function(){
 const sm=this.value;
 // Set sensible defaults per mode. Users can still adjust the fields after
 // switching modes, but picking the mode should land on a working baseline.
 // Target Colourspace follows the signal mode (BT.2020 for HDR10/HLG/DV,
 // BT.709 for SDR) and stays user-editable after the auto-set; the
 // next /api/config poll respects whatever the server has stored.
 const autoColorimetry=webuiAutoColorimetryForSignalMode(sm);
 if(sm==='sdr'){
  setVal('eotf','0');
  setVal('colorimetry',autoColorimetry);
  // Leave HDR's transport constraints behind before filtering bit depths.
  // YCbCr 4:2:2 is intentionally 10-bit-only, so setting 8-bit while the
  // previous 4:2:2 format is still active makes updateDropdowns() restore
  // 10-bit. Select the normal SDR RGB baseline first so one mode change is
  // sufficient and the 4:2:2 bit-perfect rule remains intact.
  setVal('color_format','0');
  setVal('max_bpc','8');
 }else if(sm==='hdr10'){
  setVal('eotf','2');
  setVal('colorimetry',autoColorimetry);
  // HDR10 mastering-display primaries default to DCI-P3/D65: consumer HDR is
  // mastered to P3 inside the BT.2020 container, so the HDR static metadata
  // advertises P3 primaries while the AVI colorimetry stays BT.2020. Matches
  // the LG AutoCal transport setup (meterSetLgAutoCalTransportValues).
  setVal('primaries','2');
  setVal('max_bpc','10');
 }else if(sm==='hlg'){
  setVal('eotf','3');
  setVal('colorimetry',autoColorimetry);
  setVal('primaries','1');
  setVal('max_bpc','10');
	 }else if(sm==='dv'){
	  const dvTransport=dvTransportDefaults(getVal('dv_transport'));
	  setVal('dv_transport',dvTransport.dv_transport);
	  setVal('dv_interface',dvTransport.dv_interface);
	  setVal('eotf','2');
  setVal('color_format',dvTransport.color_format);
  setVal('colorimetry',autoColorimetry);
  setVal('primaries','1');
  setVal('max_bpc',dvTransport.max_bpc);
  setVal('rgb_quant_range','2');
	 }
	 applyMeterTargetGamutDefault(true);
	 applyMeterTargetGammaDefault(true);
	 // Output-mode changes establish a new conditioning profile. Force the
	 // mode defaults here because settings restored from disk are marked as
	 // user-set and would otherwise carry HDR's 5-second interval into SDR.
	 meterApplyPatternInsertionDefaults(true);
	 if(typeof saveMeterSettings==='function') saveMeterSettings();
	 updateModeVisibility();
 meterWarnTargetWhiteAboveHdrMax();
 updateDropdowns();
 checkSettingsChanged();
 meterUpdateCardMode();
 meterQueueOutputSettingsRefresh(true);
});

document.getElementById('dv_map_mode').addEventListener('change',function(){
 if(getVal('signal_mode')!=='dv') return;
 syncDvOutputEotfState();
 applyMeterTargetGammaDefault();
 checkSettingsChanged();
 meterQueueOutputSettingsRefresh(true);
});

async function loadModes(quiet){
 const fetched=await fetchJSON('/api/modes',{_quiet:!!quiet,_timeoutMs:10000});
 if(!Array.isArray(fetched)||!fetched.length){
  if(!quiet) toast('No display modes reported yet',true);
  return;
 }
 modes=fetched;
 const sel=document.getElementById('mode_idx');
 sel.innerHTML='';
 modes.forEach(m=>{
  const o=document.createElement('option');
  o.value=m.idx;
  o.textContent=formatModeLabel(m);
  o.title=m.resolution+' @ '+m.refresh+'Hz';
  sel.appendChild(o);
 });
 syncModeSelectValue();
}

function formatModeLabel(m){
 const refresh=parseFloat(m&&m.refresh);
 let hz=String((m&&m.refresh)||'');
 if(!Number.isNaN(refresh)){
  hz=(Math.abs(refresh-Math.round(refresh))<0.01)?String(Math.round(refresh)):String(refresh).replace(/0+$/,'').replace(/\.$/,'');
 }
 let label=String((m&&m.resolution)||'')+' '+hz+'Hz';
 // Append vsync polarity when present so same WxH/refresh modes that differ
 // only in sync polarity (e.g. the two 1080p60 timings) are distinguishable.
 const flags=String((m&&m.flags)||'');
 const vsync=(flags.match(/\bpvsync\b/))?'pvsync':((flags.match(/\bnvsync\b/))?'nvsync':'');
 if(vsync) label+=' ('+vsync+')';
 return label;
}

function parseResolutionLabel(value){
 const m=String(value||'').match(/(\d+x\d+i?)(?:\s*@\s*([\d.]+)\s*Hz?)?/i);
 return m?{resolution:m[1],refresh:m[2]?parseFloat(m[2]):null}:{resolution:'',refresh:null};
}

function modeOptionExists(sel,value){
 return !!Array.from(sel.options).find(o=>o.value===String(value));
}

function modeOptionIsSelectable(sel,value){
 const opt=Array.from(sel.options).find(o=>o.value===String(value));
 return !!(opt&&!opt.disabled&&opt.style.display!=='none');
}

function firstEnabledModeIdx(){
 const sel=document.getElementById('mode_idx');
 if(!sel||!sel.options.length)return '';
 const first=Array.from(sel.options).find(o=>!o.disabled&&o.style.display!=='none');
 return first?String(first.value):'';
}

function updateModeSelectLabel(){
 const sel=document.getElementById('mode_idx');
 const label=document.getElementById('mode_idx_text');
 if(!sel||!label)return;
 const opt=sel.options[sel.selectedIndex];
 label.textContent=opt?opt.textContent:'';
 label.title=opt?(opt.title||opt.textContent):'';
}

function setModeSelectValue(value){
 const sel=document.getElementById('mode_idx');
 if(!sel||!sel.options.length||value==null||value==='')return;
 sel.value=String(value);
 Array.from(sel.options).forEach(o=>{
  const selected=o.value===sel.value;
  o.selected=selected;
  if(selected)o.setAttribute('selected','selected');
  else o.removeAttribute('selected');
 });
 updateModeSelectLabel();
}

function chooseDefaultModeIdx(){
 if(!Array.isArray(modes)||!modes.length)return '';
 return chooseModeIdxForInfo()||choosePreferredModeIdx('1920x1080',null)||'';
}

function choosePreferredModeIdx(wanted,refresh){
 if(!Array.isArray(modes)||!modes.length||!wanted)return '';
 const candidates=modes.filter(m=>String(m.resolution)===wanted);
 if(candidates.length){
  if(refresh!=null&&!Number.isNaN(refresh)){
   let best=candidates[0];
   let bestDelta=Math.abs((parseFloat(best.refresh)||0)-refresh);
   candidates.forEach(m=>{
    const delta=Math.abs((parseFloat(m.refresh)||0)-refresh);
    if(delta<bestDelta){best=m;bestDelta=delta;}
   });
   return String(best.idx);
  }
  const sixty=candidates.find(m=>Math.abs((parseFloat(m.refresh)||0)-60)<0.05);
  return String((sixty||candidates[0]).idx);
 }
 return '';
}

function chooseModeIdxForInfo(){
 const infoRes=parseResolutionLabel((window._lastInfo&&window._lastInfo.resolution)||'');
 if(!infoRes.resolution)return '';
 return choosePreferredModeIdx(infoRes.resolution,infoRes.refresh);
}

function chooseFallbackModeIdx(){
 const defaultMode=modes.find(m=>String(m.resolution)==='1920x1080'&&Math.abs((parseFloat(m.refresh)||0)-60)<0.05)
  ||modes.find(m=>String(m.resolution)==='1920x1080')
  ||modes[0];
 return defaultMode?String(defaultMode.idx):'';
}

function syncModeSelectValue(){
 const sel=document.getElementById('mode_idx');
 if(!sel||!sel.options.length)return;
 let target=(config&&config.mode_idx!=null&&config.mode_idx!=='')?String(config.mode_idx):'';
 // Only fall back to an info-derived match when the configured mode_idx is
 // absent/invalid. When mode_idx is a real option, keep it: the reported
 // resolution's refresh is rounded to an integer (/api/info), so re-deriving
 // from it can silently flip a 119.88 selection to the 120.00 option next to
 // it (both round to "120Hz", and the nearest-match picks 120.00). Honoring
 // the explicit selection avoids that desync.
 if(!target||!modeOptionExists(sel,target)){
  const liveTarget=(!isSettingsFieldActive()&&!hasUnsavedSettings())?chooseModeIdxForInfo():'';
  if(liveTarget)target=liveTarget;
 }
 if(target&&!modeOptionExists(sel,target))target='';
 if(!target)target=chooseDefaultModeIdx()||chooseFallbackModeIdx();
 if(target)setModeSelectValue(target);
 if(!sel.value||!modeOptionIsSelectable(sel,sel.value))setModeSelectValue(firstEnabledModeIdx());
}

async function loadCapabilities(quiet){
 caps=await fetchJSON('/api/capabilities',{_quiet:!!quiet,_timeoutMs:10000});
}

// Determine which color formats are valid for a given mode + bit depth
function getValidFormats(modeIdx,bpc){
 if(!caps||caps.edid_decode_available===false||caps.edid_parsed===false)return [0,1,2]; // fallback: Pi 5 supported formats
 const mode=modes.find(m=>String(m.idx)===String(modeIdx));
 const clock=mode?mode.clock:148500; // default 1080p60 if unknown
 const maxTmds=caps.max_tmds*1000; // MHz to kHz
 const valid=[];

 // RGB (format 0)
 const rgb_ok=(bpc===8)||(bpc===10&&caps.dc_30bit)||(bpc===12&&caps.dc_36bit);
 if(rgb_ok&&(bpc===8?clock:clock*bpc/8)<=maxTmds) valid.push(0);

 // YCbCr 4:4:4 (format 1)
 const y444_ok=caps.has_ycbcr444&&((bpc===8)||(bpc===10&&caps.dc_30bit&&caps.dc_y444)||(bpc===12&&caps.dc_36bit&&caps.dc_y444));
 if(y444_ok&&(bpc===8?clock:clock*bpc/8)<=maxTmds) valid.push(1);

 // The renderer's YCbCr 4:2:2 path is supported at 10-bit only.
 if(caps.has_ycbcr422&&bpc===10&&clock<=maxTmds) valid.push(2);

 return valid;
}

// Determine which bit depths are valid for a given mode + color format
function getValidBpc(modeIdx,fmt){
 if(!caps||caps.edid_decode_available===false||caps.edid_parsed===false)return [8,10,12];
 const mode=modes.find(m=>String(m.idx)===String(modeIdx));
 const clock=mode?mode.clock:148500;
 const maxTmds=caps.max_tmds*1000;
 const valid=[];

 [8,10,12].forEach(function(bpc){
  let ok=false;
  if(fmt===0){ // RGB
   ok=(bpc===8)||(bpc===10&&caps.dc_30bit)||(bpc===12&&caps.dc_36bit);
   if(ok) ok=(bpc===8?clock:clock*bpc/8)<=maxTmds;
  }else if(fmt===1){ // YCbCr 4:4:4
   ok=caps.has_ycbcr444&&((bpc===8)||(bpc===10&&caps.dc_30bit&&caps.dc_y444)||(bpc===12&&caps.dc_36bit&&caps.dc_y444));
   if(ok) ok=(bpc===8?clock:clock*bpc/8)<=maxTmds;
  }else if(fmt===2){ // YCbCr 4:2:2 — restricted to 10-bit
   ok=caps.has_ycbcr422&&bpc===10&&clock<=maxTmds;
  }
  if(ok) valid.push(bpc);
 });
 return valid;
}

// Update the dropdowns to only show valid options
function updateDropdowns(){
 if(!caps||!modes.length)return;
 const modeIdx=getVal('mode_idx');
 const curBpc=parseInt(getVal('max_bpc'))||8;
 const curFmt=parseInt(getVal('color_format'))||0;
 const sm=getVal('signal_mode');

 // Signal mode filtering
 const smSel=document.getElementById('signal_mode');
 const capsKnown=!(caps&&caps.edid_decode_available===false);
 const dvKernelOk=!(caps&&caps.kms_dovi_output_metadata===false);
 const smOpts=capsKnown
  ? {sdr:true,hdr10:caps.has_hdr_st2084,hlg:caps.has_hdr_hlg,dv:caps.has_dv&&dvKernelOk}
  : {sdr:true,hdr10:true,hlg:true,dv:false};
 Array.from(smSel.options).forEach(function(o){o.disabled=!smOpts[o.value];o.style.display=smOpts[o.value]?'':'none';});

 // In DV mode, calibration uses the platform Dolby Vision transport.
 const fmtSel=document.getElementById('color_format');
 const bpcSel=document.getElementById('max_bpc');
 const modeSel=document.getElementById('mode_idx');
	 if(sm==='dv'){
	  const transportSel=document.getElementById('dv_transport');
	  const modes=['standard'];
	  Array.from(transportSel.options).forEach(function(o){const ok=modes.includes(String(o.value).toLowerCase());o.disabled=!ok;o.style.display=ok?'':'none';});
	  transportSel.disabled=true;
	  const dvTransport=dvTransportDefaults(getVal('dv_transport'));
	  setVal('dv_transport',dvTransport.dv_transport);
	  setVal('dv_interface',dvTransport.dv_interface);
  const allowedBpc=['8','10'];
  const targetFmt=dvTransport.color_format;
  Array.from(fmtSel.options).forEach(function(o){o.disabled=o.value!==targetFmt;o.style.display=o.value===targetFmt?'':'none';});
  fmtSel.value=targetFmt;
  Array.from(bpcSel.options).forEach(function(o){o.disabled=!allowedBpc.includes(o.value);o.style.display=allowedBpc.includes(o.value)?'':'none';});
  if(!allowedBpc.includes(bpcSel.value)) bpcSel.value=dvTransport.max_bpc;
  const rngSel=document.getElementById('rgb_quant_range');
  const targetRange='2';
  Array.from(rngSel.options).forEach(function(o){o.disabled=o.value!==targetRange;o.style.display=o.value===targetRange?'':'none';});
  rngSel.value=targetRange;
  // The platform DV transport uses its configured TMDS bandwidth.
  const maxTmds=(caps&&caps.max_tmds)?caps.max_tmds*1000:600000;
  let curModeValid=false;
  Array.from(modeSel.options).forEach(function(o){
   const m=modes.find(x=>String(x.idx)===o.value);
   const ok=m?(m.clock<=maxTmds):true;
   o.disabled=!ok;o.style.display=ok?'':'none';
   if(ok&&o.value===modeIdx)curModeValid=true;
  });
  if(!curModeValid){
   setModeSelectValue(firstEnabledModeIdx());
  }
  updateModeSelectLabel();
  checkSettingsChanged();
  return;
 }
 // Non-DV: re-enable all mode options
 Array.from(modeSel.options).forEach(function(o){o.disabled=false;o.style.display='';});
 // Re-enable all range options
 const rngSel=document.getElementById('rgb_quant_range');
 Array.from(rngSel.options).forEach(function(o){o.disabled=false;o.style.display='';});

 // Color format filtering based on current mode + bpc
 const validFmts=getValidFormats(modeIdx,curBpc);
 Array.from(fmtSel.options).forEach(function(o){
  const v=parseInt(o.value);
  o.disabled=validFmts.indexOf(v)<0;
  o.style.display=validFmts.indexOf(v)>=0?'':'none';
 });
 // If current format is no longer valid, switch to first valid
 if(validFmts.indexOf(curFmt)<0&&validFmts.length>0){
  fmtSel.value=String(validFmts[0]);
 }

 // Keep every bit depth that has at least one valid format selectable. If
 // this were filtered only against the current format, a 4K60 YCbCr 4:2:2
 // 10-bit state would hide 8-bit while 10-bit hides RGB, leaving the two
 // dropdowns circularly locked. Selecting 8-bit now lets the format pass
 // above move to RGB, which also recovers stale SDR configs safely.
 const validBpc=[8,10,12].filter(function(bpc){
  return getValidFormats(modeIdx,bpc).some(function(fmt){
   return getValidBpc(modeIdx,fmt).indexOf(bpc)>=0;
  });
 });
 Array.from(bpcSel.options).forEach(function(o){
  const v=parseInt(o.value);
  o.disabled=validBpc.indexOf(v)<0;
  o.style.display=validBpc.indexOf(v)>=0?'':'none';
 });
 // If current bpc is no longer valid, switch to first valid
 if(validBpc.indexOf(curBpc)<0&&validBpc.length>0){
  bpcSel.value=String(validBpc[0]);
 }
 checkSettingsChanged();
}

async function checkPing(){
	 if(isCalibrationWorkflowActive()){
	  setConnectionBusyStatus(lgIsCommandBusy()?'LG TV':'Busy');
	  return;
	 }
 if(shouldPauseAutoRefresh()) return;
 const t0=performance.now();
 try{
  const r=await fetch(API+'/api/ping',{signal:AbortSignal.timeout(8000)});
  if(!r.ok) throw new Error(r.status);
  await r.json();
  const wasOffline=_pingFailCount>=3||_uiOffline;
  _pingFailCount=0;
  setUiOffline(false);
  if(wasOffline){
   document.getElementById('statusDot').style.background='#4caf50';
   document.getElementById('statusText').textContent='Online';
   document.getElementById('statusWrap').title='Connection restored';
   setPowerButtonState(true);
   return;
  }
 }catch(e){
  // Suppress offline detection while a continuous meter read or series scan
  // is active. The daemon is single-threaded and meter API calls block ping
  // responses; a busy meter session can cause 3 consecutive ping timeouts
  // (30s wall-time) and falsely trigger the offline overlay even though the
  // daemon is fine. Active meter API traffic is itself proof of liveness.
	  const meterBusy=(typeof meterContinuousActive!=='undefined' && meterContinuousActive)
	                  || (typeof meterContinuousSuspendedForLgWrite!=='undefined' && meterContinuousSuspendedForLgWrite)
	                  || (typeof meterLgGreyBusy!=='undefined' && meterLgGreyBusy)
	                  || lgIsCommandBusy()
	                  || (typeof meterSeriesRunning!=='undefined' && meterSeriesRunning)
	                  || (typeof meterPingBusy!=='undefined' && meterPingBusy);
	  if(meterBusy){
	   setConnectionBusyStatus(lgIsCommandBusy()?'LG TV':'Busy');
	   return;
	  }
  _pingFailCount++;
  if(_pingFailCount<3){
   document.getElementById('statusDot').style.background='var(--orange)';
   document.getElementById('statusText').textContent='Retry';
   document.getElementById('statusWrap').title='Transient timeout';
   return;
  }
  document.getElementById('statusDot').style.background='var(--red)';
  document.getElementById('statusText').textContent='Offline';
  document.getElementById('statusWrap').title='No response';
  setUiOffline(true);
  setPowerButtonState(false);
  return;
 }
 const latency=Math.round(performance.now()-t0);
 var col='#4caf50';
 if(latency>500)col='var(--red)'; else if(latency>200)col='var(--orange)'; else if(latency>100)col='#ffeb3b';
 document.getElementById('statusDot').style.background=col;
 document.getElementById('statusText').textContent=latency+'ms';
 document.getElementById('statusWrap').title='Response time: '+latency+'ms';
 setPowerButtonState(true);
}

async function loadInfo(quiet){
 const info=await fetchJSON('/api/info',{_quiet:!!quiet,_timeoutMs:10000});
 if(!info) return;
 window._lastInfo=info;
 if(Array.isArray(modes)&&modes.length&&!isSettingsFieldActive()&&!hasUnsavedSettings()){
  const beforeMode=getVal('mode_idx');
  syncModeSelectValue();
  if(getVal('mode_idx')!==beforeMode){
   updateDropdowns();
   if(window._savedConfig) refreshSavedSettingsSnapshot();
  }
 }
 document.getElementById('tempDisplay').textContent=info.temperature?info.temperature+'\u00B0C':'';
 if(info.version){
  document.getElementById('verDisplay').textContent='v'+info.version;
  document.getElementById('updateCurrent').textContent='v'+info.version;
 }
 const g=document.getElementById('infoGrid');
 g.innerHTML='';
 addInfo(g,'Hostname',info.hostname);
 addInfo(g,'Resolution',info.resolution);
 addInfo(g,'Uptime',formatUptime(info.uptime),'deviceInfoUptime');
 addInfo(g,'Temp',info.temperature+'\u00B0C','deviceInfoTemperature');
 if(info.total_ram) addInfo(g,'RAM',info.total_ram+'MB');
 if(info.gpu_mem) addInfo(g,'GPU Mem',info.gpu_mem);
 // Update GPU Memory card readout
 if(info.gpu_mem){
  const gi=document.getElementById('gpuMemInfo');
  if(gi){gi.innerHTML='';addInfo(gi,'Current',info.gpu_mem);}
 }
 if(info.interfaces){
  Object.entries(info.interfaces).forEach(([iface,ip])=>{
   const name=IFACE_NAMES[iface]||iface;
   addInfo(g,name,ip);
  });
 }
 const wifiDisconnectBtn=document.getElementById('wifiDisconnectBtn');
 if(info.wifi && info.wifi.state==='COMPLETED' && info.wifi.ssid){
  const ws=document.getElementById('wifiStatus');
  ws.innerHTML='';
  addInfo(ws,'Network',info.wifi.ssid);
  if(info.wifi.band) addInfo(ws,'Band',info.wifi.band+' ('+info.wifi.freq+' MHz)');
  if(info.wifi.signal) addInfo(ws,'Signal',info.wifi.signal+' dBm');
  if(wifiDisconnectBtn) wifiDisconnectBtn.style.display='';
  const wifiForgetBtn=document.getElementById('wifiForgetBtn');
  if(wifiForgetBtn) wifiForgetBtn.style.display='';
 }else{
  const ws=document.getElementById('wifiStatus');
  ws.innerHTML='<div style="font-size:.8rem;color:var(--text2)">Not connected</div>';
  if(wifiDisconnectBtn) wifiDisconnectBtn.style.display='none';
  const wifiForgetBtn=document.getElementById('wifiForgetBtn');
  if(wifiForgetBtn) wifiForgetBtn.style.display='none';
 }
 // Update top-bar calibration indicator
 const calWrap=document.getElementById('calStatusWrap');
 const calDot=document.getElementById('calDot');
 const calText=document.getElementById('calStatusText');
 if(info.calibration && info.calibration.connected){
  calDot.style.background='#4caf50';
  calText.style.color='';
  calText.textContent=info.calibration.software||'Connected';
  calWrap.title=(info.calibration.software||'Calibration')+' ('+info.calibration.ip+')';
 }else{
  calDot.style.background='var(--text2)';
  calText.style.color='var(--text2)';
  calText.textContent='No SW';
  calWrap.title='No calibration software connected';
 }
 // Update Resolve card status
 const rBadge=document.getElementById('resolveStatusBadge');
 const rConn=document.getElementById('resolveConnectBtn');
 const rDisc=document.getElementById('resolveDisconnectBtn');
 if(rBadge){
  const isResolve=info.calibration&&info.calibration.connected&&info.calibration.software==='Resolve';
  if(isResolve){
   rBadge.textContent='Connected ('+info.calibration.ip+')';
   rBadge.style.background='var(--green)';
   rConn.style.display='none';
   rDisc.style.display='';
  }else{
   rBadge.textContent='Disconnected';
   rBadge.style.background='var(--badge-neutral)';
   rConn.style.display='';
   rDisc.style.display='none';
  }
 }
   __PG_LG_LOAD_INFO__
 // HDMI port check
 if(info.hdmi_port) updateHdmiPortWarning(info.hdmi_port);
}

let _hdmiIgnored=false;
const uiBlockingOverlayIds=[
 'meterGreyProfileModal','meterCustomSeriesModal','meterCustomSeriesManagerModal',
 'meterImportWizardModal','meterLutToolsModal','lutSolveProgressModal',
 'meterIccProfileModal','meterIccValidationModal','meterIccCubeModal','meterIccFineTuneModal',
 'meterBuild3dLutMeasureModal','lutSolveDoneModal','meterLg3dStartModal',
 'meterLg3dSelectSeriesModal','meterLatticeGenModal','meterCcssCreateModal',
 'customCcssEditorModal','meterSpectroSetupModal','meterReportOverlay',
 'lgDisplayControlModal','lgApplyAllInputsModal'
];
let uiLockedScrollTop=0;

function uiAnyBlockingOverlayVisible(){
 const hdmi=document.getElementById('hdmiOverlay');
 if(hdmi&&hdmi.classList.contains('active')) return true;
 return uiBlockingOverlayIds.some(id=>{
  const el=document.getElementById(id);
  if(!el) return false;
  if(id==='customCcssEditorModal'&&document.body.classList.contains('layout-desktop')) return false;
  if(id==='meterLutToolsModal'&&document.body.classList.contains('layout-desktop')) return false;
  if(id==='meterIccProfileModal'&&document.body.classList.contains('layout-desktop')) return false;
  if(el.style.display) return el.style.display!=='none';
  return getComputedStyle(el).display!=='none';
 });
}

function uiSyncBodyScrollLock(){
 const body=document.body;
 // Fixed overlays nested under dashboard cards can inherit a card/grid
 // containing block in mobile WebKit, centering against the widened card
 // rather than the phone viewport. Hoist any visible tablet modal before
 // calculating the scroll lock. Desktop keeps its intentionally embedded
 // workspace panels in place.
 if(body.classList.contains('layout-tablet')){
  uiBlockingOverlayIds.forEach(id=>{
   const el=document.getElementById(id);
   if(!el||el.parentElement===body) return;
   const visible=el.style.display?el.style.display!=='none':getComputedStyle(el).display!=='none';
   if(visible) body.appendChild(el);
  });
 }
 const shouldLock=uiAnyBlockingOverlayVisible();
 if(shouldLock){
  if(!body.classList.contains('modal-open')){
   uiLockedScrollTop=window.scrollY||window.pageYOffset||0;
   body.style.top='-'+uiLockedScrollTop+'px';
   body.classList.add('modal-open');
  }
  return;
 }
 if(body.classList.contains('modal-open')){
  const restoreTop=uiLockedScrollTop||Math.abs(parseInt(body.style.top||'0',10))||0;
  body.classList.remove('modal-open');
  body.style.top='';
  window.scrollTo(0,restoreTop);
  uiLockedScrollTop=0;
 }
}

function updateHdmiPortWarning(hp){
 const overlay=document.getElementById('hdmiOverlay');
 const badge=document.getElementById('hdmiWarnBadge');
 const prefSpan=document.getElementById('hdmiPreferred');
 if(prefSpan) prefSpan.textContent=hp.preferred;
 if(hp.wrong_port){
  badge.style.display='inline';
  if(!_hdmiIgnored) overlay.classList.add('active');
 }else{
  badge.style.display='none';
  overlay.classList.remove('active');
 }
 uiSyncBodyScrollLock();
}
function hdmiIgnore(){
 _hdmiIgnored=true;
 document.getElementById('hdmiOverlay').classList.remove('active');
 uiSyncBodyScrollLock();
}
async function hdmiRecheck(){
 const btn=document.getElementById('hdmiRecheckBtn');
 btn.disabled=true;btn.textContent='Checking\u2026';
 let ok=false;
 for(let i=0;i<20;i++){
  try{
   const info=await fetchJSON('/api/info',{_timeoutMs:5000});
   if(info&&info.hdmi_port){
    if(!info.hdmi_port.wrong_port){
     btn.textContent='Restarting display\u2026';
     // Restart pattern generator so it re-targets the correct connector
     await fetchJSON('/api/restart',{_timeoutMs:10000}).catch(function(){});
     _hdmiIgnored=false;
     document.getElementById('hdmiOverlay').classList.remove('active');
    uiSyncBodyScrollLock();
     document.getElementById('hdmiWarnBadge').style.display='none';
     toast('Correct port detected \u2014 display restarted');loadInfo();ok=true;break;
    }else{
     toast('Still on wrong port \u2014 please switch to '+info.hdmi_port.preferred,'error');
     ok=true;break;
    }
   }
  }catch(e){}
  await new Promise(r=>setTimeout(r,2000));
 }
 btn.disabled=false;btn.textContent="I've switched \u2014 Recheck";
 if(!ok) toast('Could not reconnect \u2014 try refreshing the page','error');
}
function hdmiShowOverlay(){
 _hdmiIgnored=false;
 document.getElementById('hdmiOverlay').classList.add('active');
 uiSyncBodyScrollLock();
}

function statToneClass(pct){
 pct=Number(pct)||0;
 if(pct>=90)return' bad';
 if(pct>=75)return' hot';
 if(pct>=60)return' warn';
 return'';
}
function setMeter(id,pct){
 const el=document.getElementById(id);
 if(el)el.style.width=Math.max(0,Math.min(100,Number(pct)||0))+'%';
}
async function loadStats(quiet){
 const stats=await fetchJSON('/api/stats',{_quiet:!!quiet,_timeoutMs:5000});
 if(!stats)return;
 const cpuPct=Number(stats.cpu_percent),memPct=Number(stats.memory_percent);
 const cpuVal=document.getElementById('cpuUsageValue');
 const memVal=document.getElementById('memUsageValue');
 if(cpuVal){
  cpuVal.className='stat-value'+statToneClass(cpuPct);
  cpuVal.textContent=isNaN(cpuPct)?'--%':cpuPct+'%';
 }
 if(memVal){
  memVal.className='stat-value'+statToneClass(memPct);
  memVal.textContent=isNaN(memPct)?'--%':memPct+'%';
 }
 setMeter('cpuUsageBar',cpuPct);
 setMeter('memUsageBar',memPct);
 const cpuBits=[];
 if(stats.cpu_freq_mhz)cpuBits.push(stats.cpu_freq_mhz+' MHz');
 if(stats.load_1)cpuBits.push('LA '+stats.load_1);
 document.getElementById('cpuUsageSub').textContent=cpuBits.join(' • ')||'--';
 let memText='--';
 if(stats.memory_total_mb){
  memText=stats.memory_used_mb+' / '+stats.memory_total_mb+' MB';
  if(stats.memory_available_mb)memText+=' • Avail '+stats.memory_available_mb+' MB';
 }
 document.getElementById('memUsageSub').textContent=memText;
 const temperatureRaw=stats.temperature_c;
 const temperature=Number(temperatureRaw);
 if(temperatureRaw!==null&&temperatureRaw!==''&&Number.isFinite(temperature)){
  const temperatureText=(Math.round(temperature*10)/10).toFixed(1).replace(/\.0$/,'')+'\u00B0C';
  const headerTemperature=document.getElementById('tempDisplay');
  const deviceTemperature=document.getElementById('deviceInfoTemperature');
  if(headerTemperature) headerTemperature.textContent=temperatureText;
  if(deviceTemperature){
   deviceTemperature.textContent=temperatureText;
   deviceTemperature.title=temperatureText;
  }
 }
 const uptime=Number(stats.uptime_seconds);
 const deviceUptime=document.getElementById('deviceInfoUptime');
 if(deviceUptime&&Number.isFinite(uptime)){
  const uptimeText=formatUptime(uptime);
  deviceUptime.textContent=uptimeText;
  deviceUptime.title=uptimeText;
 }
}
function setSwitch(id,on){const e=document.getElementById(id);if(e)e.checked=!!on;}
function switchBusy(id,busy){const e=document.getElementById(id);if(e)e.disabled=!!busy;}
function addInfo(g,label,value,valueId){
 const d=document.createElement('div');d.className='info-item';
 const l=document.createElement('div');l.className='label';l.textContent=label;
 const v=document.createElement('div');v.className='value';v.textContent=value==null?'':String(value);v.title=v.textContent;
 if(valueId)v.id=valueId;
 d.appendChild(l);d.appendChild(v);
 g.appendChild(d);
}
function formatUptime(s){
 s=parseFloat(s);if(isNaN(s))return'?';
 const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);
 return(d?d+'d ':'')+(h?h+'h ':'')+(m?m+'m':'<1m');
}

const DIAG_DESCRIPTIONS={
 white_clipping:'<b>White Clipping (Contrast)</b> &mdash; Labeled near-white bars from 232 to 255 on a reference-white field. Set HDMI output to RGB, then lower Contrast/White Level until the 236+ bars separate cleanly and 255 is not clipped into the background.',
 black_clipping:'<b>Black Clipping / PLUGE (Brightness)</b> &mdash; Labeled near-black bars from 2 to 25 on black. Set HDMI output to RGB, then raise Brightness until the first few bars above black become barely visible without turning the whole background gray.',
 color_bars:'<b>Color Bars</b> &mdash; 75% Rec.709 bars with a mid reference strip and a bottom PLUGE/white section for quick color and level checks. Use this pattern with HDMI output set to RGB.',
 gray_ramp:'<b>Gray Ramp</b> &mdash; Smooth black-to-white ramp across the top with 11 stepped gray bars underneath. Use HDMI RGB output and check for smooth transitions, neutral grayscale, and no banding.',
 overscan:'<b>Overscan</b> &mdash; Border lines at 0%, 2.5%, and 5% from screen edges with corner L-brackets and center crosshair. Use HDMI RGB output, and all lines should be visible &mdash; if not, disable overscan in your TV settings.',
 avs_hd_709_black_clipping:'<b>AVS HD 709 - Black Clipping</b> &mdash; SDR-only AVS HD 709 black clipping. RGB Full uses full-span frames (true black=0). RGB Limited / YCbCr Limited use studio codes (footroom 2-15); set TV black level to Limited so only 17+ flash at default Brightness.',
 avs_hd_709_apl_clipping:'<b>AVS HD 709 - APL Clipping</b> &mdash; SDR-only AVS HD 709 APL clipping video for checking level behavior with an average picture level load on screen.',
 avs_hd_709_white_clipping:'<b>AVS HD 709 - White Clipping</b> &mdash; SDR-only AVS HD 709 video version of the white clipping pattern. Use it to set Contrast so near-white detail is not crushed.',
 avs_hd_709_flashing_color_bars:'<b>AVS HD 709 - Flashing Color Bars</b> &mdash; SDR-only AVS HD 709 flashing color bars video for color and tint checks with blue-only or filter workflows.',
 avs_hd_709_sharpness_overscan:'<b>AVS HD 709 - Sharpness &amp; Overscan</b> &mdash; SDR-only AVS HD 709 sharpness and overscan video for checking edge visibility and artificial sharpening.',
};
const AVS_HD_709_PATTERNS={
 avs_hd_709_black_clipping:true,
 avs_hd_709_apl_clipping:true,
 avs_hd_709_white_clipping:true,
 avs_hd_709_flashing_color_bars:true,
 avs_hd_709_sharpness_overscan:true,
};
const DIAG_UPLOAD_SENTINEL='__upload__';
const DIAG_UPLOAD_CHUNK_BYTES=192*1024;
const DIAG_VIDEO_SEQUENCE_FPS=8;
const DIAG_VIDEO_SEQUENCE_MAX_FRAMES=24;
const DIAG_VIDEO_SEQUENCE_MAX_SECONDS=3;
let diagCustomAssets={video:[],image:[]};
let activePattern=null;
function clearActive(){document.querySelectorAll('.pat-btn').forEach(b=>b.classList.remove('active'));if(document.activeElement&&document.activeElement.classList&&document.activeElement.classList.contains('pat-btn'))document.activeElement.blur();activePattern=null;}
function isAvsHd709Pattern(name){return !!AVS_HD_709_PATTERNS[String(name||'')];}
function diagSetInfoHtml(html){
 const el=document.getElementById('diagInfo');
 if(!el) return;
 if(html){el.innerHTML=html;el.style.display='';}
 else el.style.display='none';
}
function diagAssetSelectId(kind){return kind==='video'?'diagCustomVideoSelect':'diagCustomImageSelect';}
function diagAssetInputId(kind){return kind==='video'?'diagCustomVideoInput':'diagCustomImageInput';}
function diagAssetBaseLabel(filename){return String(filename||'').replace(/\.[^.]+$/,'');}
function diagAssetDisplayLabel(filename){return diagAssetBaseLabel(filename).replace(/_/g,' ');}
function diagAssetPatternToken(kind,filename){return (kind==='video'?'uploaded_diag_video:':'uploaded_diag_image:')+String(filename||'');}
function diagBlurElement(el){if(el&&typeof el.blur==='function')el.blur();}
function diagAssetInfoHtml(kind,filename){
 const label=diagAssetDisplayLabel(filename);
 if(kind==='video') return '<b>Custom Diagnostic Video</b> &mdash; '+label+'.';
 return '<b>Custom Diagnostic Image</b> &mdash; '+label+'.';
}
function diagUpdateUploadStatus(message,isError){
 const el=document.getElementById('diagUploadStatus');
 if(!el) return;
 const text=message||'';
 el.textContent=text;
 el.style.color=isError?'var(--red)':'var(--text2)';
 el.style.display=text?'block':'none';
}
function diagRenderAssetSelect(kind,selectedValue){
 const sel=document.getElementById(diagAssetSelectId(kind));
 if(!sel) return;
 const files=Array.isArray(diagCustomAssets[kind])?diagCustomAssets[kind]:[];
 const placeholder=kind==='video'?'Custom Diagnostic Video...':'Custom Diagnostic Image...';
 let html='<option value="">'+placeholder+'</option>';
 files.forEach(filename=>{
  html+='<option value="'+filename+'">'+diagAssetDisplayLabel(filename)+'</option>';
 });
 html+='<option value="'+DIAG_UPLOAD_SENTINEL+'">Upload '+kind+'...</option>';
 sel.innerHTML=html;
 if(selectedValue&&files.includes(selectedValue)) sel.value=selectedValue;
 else if(sel.dataset.lastSelected&&files.includes(sel.dataset.lastSelected)) sel.value=sel.dataset.lastSelected;
 else sel.value='';
 if(sel.value!==DIAG_UPLOAD_SENTINEL) sel.dataset.lastSelected=sel.value;
 diagUpdateDeleteButtonState(kind);
}
function diagUpdateDeleteButtonState(kind){
 const sel=document.getElementById(diagAssetSelectId(kind));
 const btn=document.getElementById(kind==='video'?'diagCustomVideoDelete':'diagCustomImageDelete');
 if(!sel||!btn) return;
 const v=sel.value||'';
 const files=Array.isArray(diagCustomAssets[kind])?diagCustomAssets[kind]:[];
 btn.disabled=!(v && v!==DIAG_UPLOAD_SENTINEL && files.includes(v));
}
async function diagDeleteSelectedAsset(kind){
 const sel=document.getElementById(diagAssetSelectId(kind));
 if(!sel) return;
 const filename=sel.value||'';
 if(!filename || filename===DIAG_UPLOAD_SENTINEL) return;
 const files=Array.isArray(diagCustomAssets[kind])?diagCustomAssets[kind]:[];
 if(!files.includes(filename)) return;
 if(!confirm('Delete custom diagnostic '+kind+' "'+diagAssetDisplayLabel(filename)+'"?')) return;
 const btn=document.getElementById(kind==='video'?'diagCustomVideoDelete':'diagCustomImageDelete');
 if(btn) btn.disabled=true;
 try{
  if(activePattern===diagAssetPatternToken(kind,filename)) await stopPattern();
  const r=await fetchJSON('/api/diagnostic/delete',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({kind:kind,filename:filename}),
   _timeoutMs:8000
  });
  if(!r||r.status!=='ok') throw new Error(r&&r.message?r.message:'Delete failed');
  sel.dataset.lastSelected='';
  sel.value='';
  await diagLoadAssetCatalog(kind,'');
  toast('Deleted '+diagAssetDisplayLabel(filename));
 }catch(e){
  toast(e&&e.message?e.message:'Delete failed',true);
 } finally {
  diagUpdateDeleteButtonState(kind);
 }
}
async function diagPlaySelectedAsset(kind){
 const sel=document.getElementById(diagAssetSelectId(kind));
 if(!sel) return;
 const value=sel.value||sel.dataset.lastSelected||'';
 if(!value||value===DIAG_UPLOAD_SENTINEL){
  toast('Choose a custom diagnostic '+kind+' first',true);
  return;
 }
 sel.value=value;
 sel.dataset.lastSelected=value;
 diagBlurElement(sel);
 await diagShowUploadedAsset(kind,value,true);
}
async function diagLoadAssetCatalog(kind,preserveValue){
 const path=kind==='video'?'/api/diagnostic/videos':'/api/diagnostic/images';
 const r=await fetchJSON(path,{_quiet:true,_timeoutMs:10000});
 diagCustomAssets[kind]=r&&Array.isArray(r.files)?r.files:[];
 diagRenderAssetSelect(kind,preserveValue||'');
}
async function diagRefreshCustomAssets(){
 await Promise.all([diagLoadAssetCatalog('video'),diagLoadAssetCatalog('image')]);
}
function diagBlobToBase64(blob){
 return new Promise((resolve,reject)=>{
  const reader=new FileReader();
  reader.onload=()=>{
   const raw=String(reader.result||'');
   const comma=raw.indexOf(',');
   resolve(comma>=0?raw.slice(comma+1):raw);
  };
  reader.onerror=()=>reject(reader.error||new Error('Failed to read file'));
  reader.readAsDataURL(blob);
 });
}
function diagCanvasToBlob(canvas,type){
 return new Promise((resolve,reject)=>{
  canvas.toBlob(blob=>blob?resolve(blob):reject(new Error('Failed to encode video frame')),type||'image/png');
 });
}
// Author extracted frames at limited range (16..235) so they match the
// renderer's limited-authored convention and display correctly on a limited
// YCbCr/RGB link. The browser decodes video to full-range RGB (0=black), so
// without this a limited signal crushes near-black content. No-op for Full.
function diagCanvasApplyLimitedRange(ctx,w,h){
 try{
  const img=ctx.getImageData(0,0,w,h);
  const d=img.data;
  for(let i=0;i<d.length;i+=4){
   d[i]  =16+Math.round(d[i]*219/255);
   d[i+1]=16+Math.round(d[i+1]*219/255);
   d[i+2]=16+Math.round(d[i+2]*219/255);
  }
  ctx.putImageData(img,0,0);
 }catch(_e){
  // tainted canvas (cross-origin source) — leave pixels untouched
 }
}
function diagVideoRangePref(){
 try{
  const v=localStorage.getItem('diagVideoRange');
  if(v==='full'||v==='limited') return v;
 }catch(_e){}
 return 'limited';
}
function diagVideoRangePrefSet(v){
 try{ localStorage.setItem('diagVideoRange', v==='full'?'full':'limited'); }catch(_e){}
}
// Ask the user (only at upload time) which range to author the extracted
// frames at. Remembers the last choice. Renders into the upload-status area.
function diagPromptVideoRange(){
 return new Promise(resolve=>{
  const pref=diagVideoRangePref();
  const host=document.getElementById('diagUploadStatus');
  if(!host){ resolve(pref); return; }
  host.style.display='';
  host.innerHTML='';
  const wrap=document.createElement('div');
  wrap.style.cssText='display:flex;align-items:center;gap:8px;flex-wrap:wrap';
  const label=document.createElement('span');
  label.textContent='Frame range for extracted frames:';
  const sel=document.createElement('select');
  sel.className='inline-select';
  sel.style.cssText='font-size:.68rem;max-width:unset';
  sel.innerHTML='<option value="limited">Limited (16-235, recommended)</option><option value="full">Full (0-255)</option>';
  sel.value=pref;
  const btn=document.createElement('button');
  btn.className='btn btn-sm btn-primary';
  btn.textContent='Prepare frames';
  btn.onclick=()=>{
   const v=sel.value==='full'?'full':'limited';
   diagVideoRangePrefSet(v);
   host.innerHTML='';
   resolve(v);
  };
  wrap.appendChild(label); wrap.appendChild(sel); wrap.appendChild(btn);
  host.appendChild(wrap);
 });
}
function diagVideoLoadFile(file){
 return new Promise((resolve,reject)=>{
  const video=document.createElement('video');
  const url=URL.createObjectURL(file);
  let done=false;
  function finishOk(){
   if(done)return;
   done=true;
   cleanup();
   resolve({video,url});
  }
  function finishErr(){
   if(done)return;
   done=true;
   cleanup();
   URL.revokeObjectURL(url);
   reject(new Error('Browser could not decode the uploaded video'));
  }
  function cleanup(){
   video.onloadeddata=null;
   video.onerror=null;
  }
  video.preload='auto';
  video.muted=true;
  video.playsInline=true;
  video.onloadeddata=finishOk;
  video.onerror=finishErr;
  video.src=url;
  video.load();
 });
}
function diagClampVideoTimestamp(video,time){
 const duration=Number(video&&video.duration||0);
 let target=Math.max(0,Number(time)||0);
 if(duration>0){
  const epsilon=Math.min(0.05,Math.max(duration/1000,0.001));
  if(target>=duration) target=Math.max(0,duration-epsilon);
 }
 return target;
}
function diagVideoSeek(video,time){
 return new Promise((resolve,reject)=>{
  const target=diagClampVideoTimestamp(video,time);
  const onSeeked=()=>{cleanup();resolve();};
  const onError=()=>{cleanup();reject(new Error('Failed to decode video frame'));};
  function cleanup(){
   video.removeEventListener('seeked',onSeeked);
   video.removeEventListener('error',onError);
  }
  if(Math.abs((Number(video.currentTime)||0)-target) < 0.001 && video.readyState >= 2){
   resolve();
   return;
  }
  video.addEventListener('seeked',onSeeked);
  video.addEventListener('error',onError);
  try{video.currentTime=target;}catch(e){cleanup();reject(e);}
 });
}
async function diagUploadVideoSequence(videoFilename,file,range){
 const uploadedName=String(videoFilename||file&&file.name||'');
 if(!uploadedName||!file) throw new Error('Video file is unavailable for renderer preparation');
 const useLimited=range!=='full';
 const loaded=await diagVideoLoadFile(file);
 const video=loaded.video;
 const url=loaded.url;
 try{
  const duration=Math.max(0,Number(video.duration)||0);
  const sequenceSeconds=duration>0?Math.min(duration,DIAG_VIDEO_SEQUENCE_MAX_SECONDS):0;
  let frameCount=Math.max(1,Math.ceil(Math.max(sequenceSeconds,1/DIAG_VIDEO_SEQUENCE_FPS)*DIAG_VIDEO_SEQUENCE_FPS));
  frameCount=Math.min(frameCount,DIAG_VIDEO_SEQUENCE_MAX_FRAMES);
  const canvas=document.createElement('canvas');
  canvas.width=Math.max(1,video.videoWidth||1920);
  canvas.height=Math.max(1,video.videoHeight||1080);
  const ctx=canvas.getContext('2d');
  if(!ctx) throw new Error('Canvas is unavailable for video decoding');
  const uploadId='diagseq_'+Date.now().toString(36)+'_'+Math.random().toString(36).slice(2,8);
  for(let i=0;i<frameCount;i++){
   const time=(frameCount<=1||sequenceSeconds<=0)?0:(sequenceSeconds*(i/(frameCount-1)));
   if(i>0 || video.readyState<2) await diagVideoSeek(video,time);
    ctx.clearRect(0,0,canvas.width,canvas.height);
    ctx.drawImage(video,0,0,canvas.width,canvas.height);
    if(useLimited) diagCanvasApplyLimitedRange(ctx,canvas.width,canvas.height);
    const blob=await diagCanvasToBlob(canvas,'image/png');
   const b64=await diagBlobToBase64(blob);
   const percent=Math.min(100,Math.round(((i+1)/frameCount)*100));
   diagUpdateUploadStatus('Preparing video frames... '+percent+'%');
   const r=await fetchJSON('/api/diagnostic/video-sequence',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({upload_id:uploadId,video_filename:uploadedName,frame_index:i,frame_total:frameCount,content:b64}),
    _timeoutMs:20000
   });
   if(!r||r.status!=='ok') throw new Error(r&&r.message?r.message:'Failed to upload video frames');
  }
  return {frameCount};
 } finally {
  try{video.pause();}catch(_e){}
  try{video.removeAttribute('src');video.load();}catch(_e){}
  URL.revokeObjectURL(url);
 }
}
async function diagUploadAsset(kind,file){
 if(!file||!file.size) throw new Error('Choose a file to upload');
 const uploadId=kind+'_'+Date.now().toString(36)+'_'+Math.random().toString(36).slice(2,8);
 diagUpdateUploadStatus('Uploading '+file.name+'...');
 for(let offset=0; offset<file.size; offset+=DIAG_UPLOAD_CHUNK_BYTES){
  const chunk=file.slice(offset,offset+DIAG_UPLOAD_CHUNK_BYTES);
  const b64=await diagBlobToBase64(chunk);
  const isFinal=(offset+chunk.size)>=file.size;
  const percent=Math.min(100,Math.round(((offset+chunk.size)/file.size)*100));
  const r=await fetchJSON('/api/diagnostic/upload',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({kind:kind,upload_id:uploadId,filename:file.name,offset:offset,total_size:file.size,is_final:isFinal,content:b64}),
   _timeoutMs:20000
  });
  if(!r||r.status!=='ok') throw new Error(r&&r.message?r.message:'Upload failed');
  diagUpdateUploadStatus('Uploading '+file.name+'... '+percent+'%');
  if(isFinal) return r;
 }
 throw new Error('Upload failed');
}
async function diagShowUploadedAsset(kind,filename,forcePlay){
 const token=diagAssetPatternToken(kind,filename);
 if(activePattern===token && !forcePlay){await stopPattern();return;}
 meterClearInteractiveSelection(true);
 clearActive();
 activePattern=token;
 diagSetInfoHtml(diagAssetInfoHtml(kind,filename));
 const body={name:kind==='video'?'uploaded_diag_video':'uploaded_diag_image',filename:filename,signal_mode:getVal('signal_mode'),max_luma:document.getElementById('max_luma').value};
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 if(r&&r.status==='ok') toast('Pattern: '+diagAssetDisplayLabel(filename));
 else toast(r&&r.message?r.message:'Pattern error',true);
}
async function diagHandleAssetSelect(kind){
 const sel=document.getElementById(diagAssetSelectId(kind));
 if(!sel) return;
 const value=sel.value||'';
 if(value===DIAG_UPLOAD_SENTINEL){
  sel.value=sel.dataset.lastSelected||'';
  diagBlurElement(sel);
  const input=document.getElementById(diagAssetInputId(kind));
  if(input){input.value='';input.click();}
  return;
 }
 if(value===''){
  sel.dataset.lastSelected='';
  diagBlurElement(sel);
  if(activePattern&&activePattern.indexOf('uploaded_diag_'+kind+':')===0) await stopPattern();
  return;
 }
  sel.dataset.lastSelected=value;
  diagBlurElement(sel);
  diagSetInfoHtml(diagAssetInfoHtml(kind,value));
  diagUpdateDeleteButtonState(kind);
}
async function diagHandleAssetUpload(kind,evt){
 const input=evt&&evt.target?evt.target:null;
 const file=input&&input.files&&input.files[0]?input.files[0]:null;
 if(!file) return;
 try{
  const r=await diagUploadAsset(kind,file);
  let statusMessage=r&&r.message?r.message:'Upload complete';
   if(kind==='video'){
    try{
     const range=await diagPromptVideoRange();
     const seq=await diagUploadVideoSequence(r&&r.filename?r.filename:file.name,file,range);
     statusMessage='Uploaded diagnostic video and '+seq.frameCount+' renderer frames ('+(range==='full'?'full':'limited')+' range)';
   }catch(seqErr){
    const seqMessage='Uploaded diagnostic video; using Pi video player';
    await diagLoadAssetCatalog(kind,r.filename||file.name);
    const sel=document.getElementById(diagAssetSelectId(kind));
    if(sel && r && r.filename){
     sel.value=r.filename;
     sel.dataset.lastSelected=r.filename;
    }
    diagUpdateUploadStatus(seqMessage);
    toast(seqMessage);
    if(input) input.value='';
    return;
   }
  }
  await diagLoadAssetCatalog(kind,r.filename||file.name);
  const sel=document.getElementById(diagAssetSelectId(kind));
  if(sel && r && r.filename){
   sel.value=r.filename;
   sel.dataset.lastSelected=r.filename;
  }
  diagUpdateUploadStatus(statusMessage);
  toast(statusMessage);
  if(r&&r.filename) diagSetInfoHtml(diagAssetInfoHtml(kind,r.filename));
 }catch(e){
  const message=e&&e.message?e.message:'Upload failed';
  diagUpdateUploadStatus(message,true);
  toast(message,true);
 }
 if(input) input.value='';
}
function updateDiagAvsHd709Visibility(){
 const el=document.getElementById('diagAvsHd709Section');
 const isSdr=getVal('signal_mode')==='sdr';
 if(el) el.style.display=isSdr?'':'none';
 const vlabel=document.getElementById('diagVideoLabel');
 if(vlabel) vlabel.style.display=isSdr?'none':'';
 if(!isSdr&&activePattern&&isAvsHd709Pattern(activePattern)) stopPattern();
}
function updateDiagInfo(name){
 if(DIAG_DESCRIPTIONS[name]) diagSetInfoHtml(DIAG_DESCRIPTIONS[name]);
 else diagSetInfoHtml('');
}
async function showPattern(name,ev){
 const btn=ev&&ev.currentTarget?ev.currentTarget:null;
 if(btn&&typeof btn.blur==='function') btn.blur();
 if(activePattern===name){await stopPattern();return;}
 if(isAvsHd709Pattern(name)&&getVal('signal_mode')!=='sdr'){
  toast('AVS HD 709 videos are available only in SDR',true);
  return;
 }
 meterClearInteractiveSelection(true);
 clearActive();
 if(ev&&ev.currentTarget)ev.currentTarget.classList.add('active');
 activePattern=name;
 updateDiagInfo(name);
 const label=ev&&ev.currentTarget?ev.currentTarget.textContent.trim():name.replace(/_/g,' ');
 try{
  const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({name:name,signal_mode:getVal('signal_mode'),
    max_luma:document.getElementById('max_luma').value})});
  if(r&&r.status==='ok') toast('Pattern: '+label);
  else {
   clearActive();
   diagSetInfoHtml('');
   toast(r?r.message:'Pattern error',true);
  }
 }catch(e){
  clearActive();
  diagSetInfoHtml('');
  toast(e&&e.message?e.message:'Pattern error',true);
 }
}
async function showPatch(id,pr,pg,pb,ev){
 // Greyscale/color/saturation patches are now driven by the Meter & Measurements
 // series readings card. This stub remains only so any legacy handler is a no-op.
 if(ev&&ev.currentTarget)ev.currentTarget.classList.remove('active');
}
async function stopPattern(){
 meterClearInteractiveSelection(true);
 clearActive();
 diagBlurElement(document.getElementById('diagCustomVideoSelect'));
 diagBlurElement(document.getElementById('diagCustomImageSelect'));
 diagSetInfoHtml('');
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:'stop'})});
 if(r&&r.status==='ok') toast('Pattern stopped');
}
document.getElementById('diagCustomVideoInput').addEventListener('change',evt=>diagHandleAssetUpload('video',evt));
document.getElementById('diagCustomImageInput').addEventListener('change',evt=>diagHandleAssetUpload('image',evt));
function toggleSection(el){el.parentElement.classList.toggle('collapsed');}
function getPatternTargetMax(){
 const sm=getVal('signal_mode');
 if(sm==='dv')return 255;
 const bits=parseInt(getVal('max_bpc')||'8',10);
 if(bits>=12)return 4095;
 if(bits>=10)return 1023;
 return 255;
}
function isPqStimulusMode(){
 const sm=getVal('signal_mode');
 return sm==='hdr10'||sm==='dv';
}
function clampNum(v,min,max){
 v=parseFloat(v);
 if(isNaN(v))v=min;
 if(v<min)return min;
 if(v>max)return max;
 return v;
}
function pqEncodeNormalized(nits){
 const l=clampNum(nits,0,10000)/10000;
 if(l<=0)return 0;
 const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
 const p=Math.pow(l,m1);
 return Math.pow((c1+c2*p)/(1+c3*p),m2);
}
function getPatternPeakCode(){
 const maxCode=getPatternTargetMax();
 if(isPqStimulusMode()){
  const peak=clampNum(document.getElementById('max_luma').value||1000,0,10000);
  return Math.round(pqEncodeNormalized(peak)*maxCode);
 }
 return maxCode;
}
function stimulusPercentToCode(percent){
 const pct=clampNum(percent,0,100);
 return Math.round(getPatternPeakCode()*pct/100);
}
function buildCalPatterns(){
 // Greyscale, Color Checker and Saturation Sweep grids were removed from the
 // Test Patterns card — those series are now driven exclusively by the Meter
 // & Measurements card. Kept as a no-op so the init call at module load works.
}
buildCalPatterns();

function dvTransportDefault(configKey,capsKey,fallback){
 if(caps&&caps[capsKey]!=null) return String(caps[capsKey]);
 if(config&&config[configKey]!=null) return String(config[configKey]);
 return fallback;
}
function dvTransportMode(value){
 return 'standard';
}
function dvRgbMaxBpc(value){
 return String(value||'').trim()==='10' ? '10' : '8';
}
function dvTransportDefaults(mode){
 if(String(mode||'').toLowerCase()==='lldv'){
  // Low-latency (source-led) DV: PQ YCbCr 4:2:2 12-bit, LL bit in the VSIF.
  return {dv_transport:'lldv',is_ll_dovi:'1',is_std_dovi:'0',dv_interface:'1',color_format:'2',max_bpc:'12'};
 }
 return {dv_transport:'standard',is_ll_dovi:'0',is_std_dovi:'1',dv_interface:'0',color_format:'0',max_bpc:'8'};
}

function resetDefaults(){
 setVal('signal_mode','sdr');
 setVal('max_bpc','8');
 setVal('color_format','0');
 setVal('colorimetry','2');
 setVal('rgb_quant_range','2');
 setVal('eotf','0');
 setVal('primaries','0');
 document.getElementById('max_luma').value='1000';
 document.getElementById('min_luma').value='0.005';
 document.getElementById('max_cll').value='1000';
	 document.getElementById('max_fall').value='400';
	 setVal('dv_transport','standard');
	 setVal('dv_map_mode','2');
	 setVal('dv_interface','0');
 updateModeVisibility();
 updateDropdowns();
 checkSettingsChanged();
 toast('Defaults loaded. Click Apply to save and restart.');
}

async function applySettings(){
 if(window._configApplyPending) return false;
 // A running continuous/series read measures the CURRENT signal mode; applying
 // new output settings mid-read would silently restart the generator under it.
 // Mirror the series-selector behavior: ask, then stop the read before applying.
 if(meterContinuousActive||meterSeriesRunning){
  const what=meterSeriesRunning?'series read':'continuous read';
  const ok=await meterShowChoiceModal({title:'Apply new settings?',body:'A '+what+' is running. Stop it and apply the new signal settings?',acceptLabel:'Stop & apply',cancelLabel:'Cancel'});
  if(!ok) return false;
  if(meterSeriesRunning) meterStop();
  else meterStopContinuous();
 }
 window._configApplyPending=true;
 meterUpdateReadButtons();
 const sm=getVal('signal_mode');
 const changes={
  mode_idx:getVal('mode_idx'),
  max_bpc:getVal('max_bpc'),
  color_format:getVal('color_format'),
  colorimetry:getVal('colorimetry'),
  rgb_quant_range:getVal('rgb_quant_range'),
 };
 if(sm==='sdr'){
  Object.assign(changes,{is_sdr:'1',is_hdr:'0',eotf:'0',
   primaries:'0',is_ll_dovi:'0',is_std_dovi:'0',dv_status:'0',
   dv_interface:'0',dv_metadata:'0'});
 }else if(sm==='hdr10'||sm==='hlg'){
  Object.assign(changes,{is_sdr:'0',is_hdr:'1',
   is_ll_dovi:'0',is_std_dovi:'0',dv_status:'0',dv_interface:'0',dv_metadata:'0',
   eotf:getVal('eotf'),primaries:getVal('primaries'),
   max_luma:meterHdrMetadataFieldValue('max_luma','hdr10'),
   min_luma:meterHdrMetadataFieldValue('min_luma','hdr10'),
   max_cll:meterHdrMetadataFieldValue('max_cll','hdr10'),
   max_fall:meterHdrMetadataFieldValue('max_fall','hdr10')});
	 }else if(sm==='dv'){
	  const dvTransport=dvTransportDefaults(getVal('dv_transport'));
	  Object.assign(changes,{is_sdr:'0',is_hdr:'1',
	   dv_transport:dvTransport.dv_transport,
	   is_ll_dovi:dvTransport.is_ll_dovi,is_std_dovi:dvTransport.is_std_dovi,
   dv_status:'1',primaries:'1',color_format:dvTransport.color_format,colorimetry:'9',
   max_bpc:(dvTransport.dv_transport==='lldv'?dvTransport.max_bpc:dvRgbMaxBpc(getVal('max_bpc'))),
   rgb_quant_range:'2',eotf:'2',
   dv_interface:dvTransport.dv_interface,
   dv_map_mode:getVal('dv_map_mode'),
   max_luma:meterHdrMetadataFieldValue('max_luma','dv'),
   min_luma:meterHdrMetadataFieldValue('min_luma','dv'),
   max_cll:meterHdrMetadataFieldValue('max_cll','dv'),
   max_fall:meterHdrMetadataFieldValue('max_fall','dv'),
    dv_color_space:'0',
   dv_metadata:dvMetadataForMapMode(getVal('dv_map_mode'))});
 }
 clearActive();
 var di=document.getElementById('diagInfo');if(di)di.style.display='none';
 // Pop the spinner modal synchronously before submitting the config. The
 // POST returns a restart token, then the browser follows that specific
 // worker until the renderer is running and owns DRM master. This keeps the
 // click responsive without guessing how long the mode switch will take.
 applySettingsModalShow();
 document.getElementById('applyBar').style.display='none';
 const r=await fetchJSON('/api/config',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify(changes),_timeoutMs:30000});
 if(r&&r.status==='ok'){
  try{
   if(r.restart) await waitForRendererRestart(r.restart_id,60000);
   await loadConfig();
   updateDropdowns();
   await loadInfo();
   // Re-fetch the mode list: a mode change re-negotiates the HDMI link and the
   // server invalidated its modes/caps caches, so the dropdown must rebuild from
   // the live connector modes instead of the pre-apply snapshot.
   await loadModes(true);
   if(typeof lgRefreshPictureModeAfterOutputApply==='function') lgRefreshPictureModeAfterOutputApply();
   if(typeof meterRefreshStabilizationIdlePattern==='function') await meterRefreshStabilizationIdlePattern(false);
   applySettingsModalSuccess();
  }catch(e){
   applySettingsModalError((e&&e.message)||'Apply failed while reloading config.');
   // Fall through to finally so _configApplyPending clears and the modal
   // stays open for the operator to read.
  }finally{
   window._configApplyPending=false;
   meterUpdateReadButtons();
  }
  return true;
 }else{
  applySettingsModalError((r&&r.message)||'The daemon rejected the new settings.');
  window._configApplyPending=false;
  meterUpdateReadButtons();
  return false;
 }
}

function confirmReboot(){
 if(!confirm('Reboot device?')) return;
 rebootDevice();
}
async function rebootDevice(){
 toast('Rebooting device...');
 setPowerButtonState(false);
 await fetchJSON('/api/reboot',{method:'POST'});
}
let _powerOffRequested=false;
async function shutdownDevice(){
 if(!confirm('Power off the Pi?\n\nThe WebUI will become unreachable until you power-cycle the device.')) return;
 _powerOffRequested=true;
 setPowerButtonState(false);
 toast('Shutting down...');
 await flushMeterSettings(3000);
 try{ await fetchJSON('/api/power',{method:'POST'}); }catch(e){}
}
function setPowerButtonState(online){
 const b=document.getElementById('pwrBtn');
 if(!b) return;
 // Once a shutdown request is in-flight we keep the button muted even if a
 // stray ping reply races in during the kernel halt.
 const effective=_powerOffRequested?false:online;
 b.classList.toggle('online',!!effective);
 b.classList.toggle('offline',!effective);
 b.title=effective?'Power off':(_powerOffRequested?'Shutdown requested':'Offline');
}

async function loadMemory(){
 const m=await fetchJSON('/api/boot/memory',{_quiet:true});
 if(!m)return;
 setVal('gpu_mem',m.gpu_mem||'128');
 const g=document.getElementById('gpuMemInfo');
 if(g){
  g.innerHTML='';
  addInfo(g,'Current',m.gpu_mem+'MB');
 }
}

async function applyMemory(){
 const gpu=getVal('gpu_mem');
 if(!confirm('Set GPU memory to '+gpu+'MB and reboot?'))return;
 const r=await fetchJSON('/api/boot/memory',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({gpu_mem:gpu})});
 if(r&&r.status==='ok') toast(r.message);
 else toast(r&&r.message?r.message:'Failed to apply','err');
}

async function scanWifi(){
 document.getElementById('wifiList').innerHTML='<div class="spinner"></div> Scanning...';
 const nets=await fetchJSON('/api/wifi/scan');
 const list=document.getElementById('wifiList');
 if(!nets||!nets.length){list.innerHTML='<div style="color:var(--text2)">No networks found</div>';return;}
 list.innerHTML='';
 const seen={};
 nets.filter(n=>{if(seen[n.ssid])return false;seen[n.ssid]=1;return true;})
 .sort((a,b)=>b.signal-a.signal)
 .forEach(n=>{
  const d=document.createElement('div');d.className='wifi-item';
  d.innerHTML='<div><div class="name">'+n.ssid+'</div><div class="meta">'+n.security+'</div></div><div class="meta">'+n.signal+' dBm</div>';
  d.onclick=()=>{
   list.querySelectorAll('.wifi-item.is-selected').forEach(item=>item.classList.remove('is-selected'));
   d.classList.add('is-selected');
   showWifiForm(n.ssid,n.security);
  };
  list.appendChild(d);
 });
}

function showWifiForm(ssid,sec){
 document.getElementById('wifiSsid').value=ssid;
 document.getElementById('wifiPsk').value='';
 document.getElementById('wifiConnect').className='';
 document.getElementById('wifiPsk').placeholder=sec==='Open'?'No password needed':'Enter password';
}
function hideWifiForm(){document.getElementById('wifiConnect').className='hidden';}

async function connectWifi(){
 const ssid=document.getElementById('wifiSsid').value;
 const psk=document.getElementById('wifiPsk').value;
 const btn=event.target;btn.disabled=true;btn.textContent='Connecting...';
 const r=await fetchJSON('/api/wifi/connect',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,psk}),_timeoutMs:30000});
 if(r&&r.status==='ok'){
  toast((r.message||('Connecting to '+ssid))+'...');
  hideWifiForm();
  // Poll long enough for association plus DHCP lease acquisition.
  let attempts=0;
  const poll=setInterval(async()=>{
   attempts++;
   const ws=await fetchJSON('/api/wifi/status');
   if(ws&&ws.wpa_state==='COMPLETED'&&ws.ssid===ssid&&ws.ip){
    clearInterval(poll);
    const bandInfo=ws.band?' on '+ws.band:'';
    const sigInfo=ws.signal?' ('+ws.signal+' dBm)':'';
    toast('Connected to '+ssid+bandInfo+sigInfo+' - '+ws.ip);
    loadInfo();
   }else if(ws&&ws.wpa_state==='COMPLETED'&&ws.ssid===ssid&&attempts===4){
    toast('Connected to '+ssid+', waiting for IP...');
   }else if(attempts>=40){
    clearInterval(poll);
    if(ws&&ws.wpa_state==='COMPLETED'&&ws.ip) toast('Connected to '+ws.ssid+' - '+ws.ip);
    else if(ws&&ws.wpa_state==='COMPLETED') toast('Connected to '+ws.ssid+', but no IP lease yet','err');
    else toast('Connection to '+ssid+' may have failed - check status','err');
    loadInfo();
   }
  },1500);
 }else toast((r&&r.message)?r.message:'Connection failed','err');
 btn.disabled=false;btn.textContent='Connect';
}

async function disconnectWifi(){
 const btn=document.getElementById('wifiDisconnectBtn');
 if(btn) btn.disabled=true;
 if(!window.confirm('Disconnect the current WiFi client connection?')){
  if(btn) btn.disabled=false;
  return;
 }
 const r=await fetchJSON('/api/wifi/disconnect',{method:'POST'});
 if(r&&r.status==='ok'){
  toast('Disconnecting WiFi...');
  hideWifiForm();
  setTimeout(()=>{loadInfo();if(btn) btn.disabled=false;},1500);
 }else{
  toast('WiFi disconnect failed','err');
  if(btn) btn.disabled=false;
 }
}
async function forgetWifi(){
 const btn=document.getElementById('wifiForgetBtn');
 if(btn) btn.disabled=true;
 if(!window.confirm('Forget WiFi network? Stored credentials will be deleted and WiFi will not reconnect on reboot.')){
  if(btn) btn.disabled=false;
  return;
 }
 const r=await fetchJSON('/api/wifi/forget',{method:'POST'});
 if(r&&r.status==='ok'){
  toast('WiFi network forgotten');
  hideWifiForm();
  setTimeout(()=>{loadInfo();if(btn) btn.disabled=false;},1500);
 }else{
  toast('WiFi forget failed','err');
  if(btn) btn.disabled=false;
 }
}

let cecCommandBusyUntil=0;
let cecStatusFollowupTimer=null;
let cecLastPhysAddr='';

function cecIsCommandBusy(){
 return Date.now()<cecCommandBusyUntil;
}

function cecExpectedPower(cmd){
 if(cmd==='on') return 'powering-on';
 if(cmd==='off') return 'powering-off';
 return '';
}

function scheduleCecStatusFollowup(cmd){
 if(cecStatusFollowupTimer){
  clearInterval(cecStatusFollowupTimer);
  cecStatusFollowupTimer=null;
 }
 const timeoutMs=(cmd==='on')?60000:20000;
 const intervalMs=(cmd==='on')?2000:1500;
 const until=Date.now()+timeoutMs;
 const target=(cmd==='on')?'on':(cmd==='off')?'standby':'';
 const tick=async()=>{
  const r=await loadCecStatus({force:true});
  if((target&&r&&r.tv_power===target)||Date.now()>=until){
   if(cecStatusFollowupTimer){
    clearInterval(cecStatusFollowupTimer);
    cecStatusFollowupTimer=null;
   }
  }
 };
 setTimeout(tick,(cmd==='on')?1500:500);
 cecStatusFollowupTimer=setInterval(tick,intervalMs);
}

async function cecCmd(cmd){
 const expectedPower=cecExpectedPower(cmd);
 if(expectedPower) renderCecStatus(expectedPower,cecLastPhysAddr);
 cecCommandBusyUntil=Date.now()+25000;
 const r=await fetchJSON('/api/cec/'+cmd,{_quiet:true,_timeoutMs:20000});
 if(r){
  if(r.status==='ok'){
   toast('CEC: '+cmd+' OK');
   if(r.tv_power) renderCecStatus(r.tv_power,cecLastPhysAddr);
  }else{
   toast('CEC: '+(r.message||r.output||'error'),'err');
  }
 }else{
  toast('CEC: '+cmd+' sent; waiting for status');
 }
 cecCommandBusyUntil=Date.now()+5000;
 scheduleCecStatusFollowup(cmd);
 if((cmd==='active'||cmd==='input')&&typeof lgRefreshPictureMode==='function'){
  setTimeout(()=>lgRefreshPictureMode(true),1500);
  setTimeout(()=>lgRefreshPictureMode(true),3500);
 }
}

async function cecScan(){
  const el=document.getElementById('cecDeviceList');
  el.innerHTML='Scanning... (may take 15-30s)';
  const r=await fetchJSON('/api/cec/scan',{_timeoutMs:30000});
 if(r&&r.status==='ok'&&r.data&&r.data.devices){
  const devs=r.data.devices;
  if(devs.length===0){el.innerHTML='No devices found';return;}
  const typeNames={0:'TV',1:'Recording',3:'Tuner',4:'Playback',5:'Audio System'};
  const pwrNames={0:'On',1:'Standby',2:'Powering On',3:'Powering Off'};
  const cecCleanName=(name)=>String(name||'').replace(/[\x00-\x1f\x7f]+/g,'').trim();
  const cecVendorName=(vendor)=>{
   const v=String(vendor||'').toLowerCase().replace(/^0x/,'');
   return v==='00e091'?'LG':'';
  };
  let html='<table style="width:100%;border-collapse:collapse;font-size:.8rem">';
  html+='<tr style="border-bottom:1px solid var(--border)"><th style="text-align:left;padding:2px 6px">Device</th><th style="text-align:left;padding:2px 6px">Type</th><th style="text-align:left;padding:2px 6px">Address</th><th style="text-align:left;padding:2px 6px">Vendor</th><th style="text-align:left;padding:2px 6px">Power</th></tr>';
  devs.forEach(d=>{
   const vendor=cecVendorName(d.vendor)||d.vendor||'';
   const cleanName=cecCleanName(d.name);
   const name=(cleanName.length>1)?cleanName:(vendor==='LG'&&d.type===0?'LG TV':('Device '+d.addr));
   const type=typeNames[d.type]||(d.type!==undefined?'Type '+d.type:'');
   const pwr=pwrNames[d.power]||(d.power!==undefined?''+d.power:'?');
   const pwrColor=d.power===0?'#4caf50':d.power===1?'var(--orange)':'var(--text2)';
   html+='<tr style="border-bottom:1px solid var(--border)">';
   html+='<td style="padding:2px 6px">'+name+'</td>';
   html+='<td style="padding:2px 6px">'+type+'</td>';
   html+='<td style="padding:2px 6px">'+(d.phys||'')+'</td>';
   html+='<td style="padding:2px 6px">'+vendor+'</td>';
   html+='<td style="padding:2px 6px;color:'+pwrColor+'">'+pwr+'</td>';
   html+='</tr>';
  });
  html+='</table>';
  html+='<div style="margin-top:4px;color:var(--text2)">PGenerator+: '+r.data.self.phys+' (logical '+r.data.self.log+')</div>';
  el.innerHTML=html;
  loadCecStatus();
 }else{
  el.innerHTML='Scan failed: '+(r&&r.message?r.message:'unknown error');
  loadCecStatus();
 }
}

let cecStatusPending=false;

function renderCecStatus(tvPower,physAddr){
 const el=document.getElementById('cecStatus');
 if(!el) return;
 if(physAddr) cecLastPhysAddr=physAddr;
 const pwr=tvPower||'unknown';
 const pwrColors={on:'#4caf50',standby:'var(--orange)','powering-on':'var(--orange)','powering-off':'var(--orange)',unknown:'var(--text2)'};
 const pwrLabels={on:'On',standby:'Standby','powering-on':'Waking Up','powering-off':'Going to Standby',unknown:'Unknown'};
 const c=pwrColors[pwr]||'var(--text2)';
 const lbl=pwrLabels[pwr]||pwr;
  let html='TV: <span style="color:'+c+';font-weight:600">'+lbl+'</span>';
 const shownPhys=physAddr||cecLastPhysAddr;
 if(shownPhys) html+=' &bull; HDMI '+shownPhys;
 el.innerHTML=html;
 el.style.color='';
}

async function loadCecStatus(opts){
 opts=opts||{};
 if(!opts.force&&shouldPauseAutoRefresh()) return null;
 if(cecStatusPending) return;
 cecStatusPending=true;
 try{
  const r=await fetchJSON('/api/cec/status',{_quiet:true,_timeoutMs:8000});
  if(r&&r.status==='ok'){
   renderCecStatus(r.tv_power,r.phys_addr);
   return r;
  }else{
   renderCecStatus('unknown','');
   return null;
  }
 }catch(e){
  renderCecStatus('unknown','');
  return null;
 }finally{
  cecStatusPending=false;
 }
}

__PG_LG_JS__

async function loadAP(){
 const r=await fetchJSON('/api/wifi/ap',{_quiet:true,_timeoutMs:10000});
 if(r&&r.status==='ok'){
  document.getElementById('apSsid').value=r.ssid||'';
  document.getElementById('apPass').value=r.password||'';
 }
 const s=await fetchJSON('/api/wifi/ap/status',{_quiet:true,_timeoutMs:10000});
 const el=document.getElementById('apStatus');
 if(el&&s&&s.status==='ok'){
  el.innerHTML='';
  addInfo(el,'State',s.active?'Running':'Stopped');
  addInfo(el,'Interface',s.interface||'-');
  addInfo(el,'DHCP',s.dnsmasq_active?'Running':'Stopped');
  addInfo(el,'Gateway',s.gateway_ready?'Ready':'Unavailable');
  addInfo(el,'Address',s.address||((s.ap_net||'10.10.10')+'.1'));
  const t=document.getElementById('apEnableToggle');
  if(t&&!t.disabled) t.checked=!!s.active;
 }
}

async function onWifiRadioToggle(el){
 const enable=el.checked;
 if(!enable){
  const aps=await fetchJSON('/api/wifi/ap/status',{_quiet:true,_timeoutMs:8000});
  if(aps&&aps.status==='ok'&&aps.active){
   if(!window.confirm('Disabling the WiFi radio will also stop the WiFi Access Point (they share one radio). Continue?')){
    el.checked=true;
    return;
   }
  }
 }
 switchBusy('wifiRadioToggle',true);
 const r=await fetchJSON('/api/wifi/radio',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled:enable})});
 if(r&&r.status==='ok') toast(r.message||('WiFi radio '+(enable?'enabled':'disabled')));
 else toast(r&&(r.message||r.error)?(r.message||r.error):'WiFi radio change failed','err');
 setTimeout(()=>{loadWifiRadio();loadAP();switchBusy('wifiRadioToggle',false);},1500);
}
async function loadWifiRadio(){
 const r=await fetchJSON('/api/wifi/radio',{_quiet:true,_timeoutMs:8000});
 const t=document.getElementById('wifiRadioToggle');
 if(t&&!t.disabled&&r&&r.status==='ok') t.checked=!r.blocked;
}

async function applyAP(){
 const ssid=document.getElementById('apSsid').value.trim();
 const password=document.getElementById('apPass').value;
 if(!ssid){toast('SSID is required','err');return;}
 if(password.length<8){toast('Password must be at least 8 characters','err');return;}
 const r=await fetchJSON('/api/wifi/ap',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,password})});
 if(r&&r.status==='ok'){toast('AP settings saved');loadAP();}
 else toast(r&&(r.message||r.error)?(r.message||r.error):'AP apply failed','err');
}

async function controlAP(action){
 const r=await fetchJSON('/api/wifi/ap/'+action,{method:'POST'});
 if(r&&r.status==='ok'){toast(r.message||'AP '+action+'d');setTimeout(loadAP,1000);}
 else toast(r&&(r.message||r.error)?(r.message||r.error):'AP '+action+' failed','err');
}

async function onApToggle(el){
 switchBusy('apEnableToggle',true);
 await controlAP(el.checked?'enable':'disable');
 setTimeout(()=>{loadAP();switchBusy('apEnableToggle',false);},1200);
}

async function loadBluetooth(){
 const r=await fetchJSON('/api/bluetooth/status',{_quiet:true,_timeoutMs:10000});
 const el=document.getElementById('btStatus');
 if(!el||!r||r.status!=='ok') return;
 el.innerHTML='';
 addInfo(el,'Power',r.powered?'On':'Off');
 const bt=document.getElementById('btPowerToggle');
 if(bt&&!bt.disabled) bt.checked=!!r.powered;
 addInfo(el,'Visible',r.discoverable?'Yes':'No');
 addInfo(el,'Agent',r.agent?'Running':'Stopped');
 addInfo(el,'PAN',r.pan_running?'Running':'Stopped');
 addInfo(el,'Network',(r.pan_net||'10.10.11')+'.1');
 if(Array.isArray(r.devices)&&r.devices.length) addInfo(el,'Devices',r.devices.length);
}

async function btSet(kind,enabled){
 const map={power:'/api/bluetooth/power',discoverable:'/api/bluetooth/discoverable',agent:'/api/bluetooth/agent'};
 const path=map[kind];
 if(!path)return;
 const r=await fetchJSON(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled})});
 if(r&&r.status==='ok'){toast(r.message||'Bluetooth updated');setTimeout(loadBluetooth,800);}
 else toast(r&&(r.message||r.error)?(r.message||r.error):'Bluetooth command failed','err');
}

async function onBtPowerToggle(el){
 switchBusy('btPowerToggle',true);
 await btSet('power', el.checked);
 setTimeout(()=>{loadBluetooth();switchBusy('btPowerToggle',false);},1200);
}

async function btRestartPan(){
 const r=await fetchJSON('/api/bluetooth/pan/restart',{method:'POST'});
 if(r&&r.status==='ok'){toast(r.message||'Bluetooth PAN restarted');setTimeout(loadBluetooth,1000);}
 else toast(r&&(r.message||r.error)?(r.message||r.error):'Bluetooth PAN restart failed','err');
}

// Set by the modal Cancel button so the connect poll loop below bails out and
// does not fire a "timed out" toast over the "Cancelled" one.
let resolveConnectCancelled=false;
async function resolveConnect(){
 const ip=document.getElementById('resolveIp').value.trim();
 const port=parseInt(document.getElementById('resolvePort').value)||20002;
 if(!ip||!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid IP address','err');return;}
 // Blocking spinner (with a Cancel button) until the daemon's outbound connect
 // is accepted by the calibration PC (or we give up). The connect endpoint only
 // queues the request; /api/resolve/status flips connected once the socket is up.
 resolveConnectCancelled=false;
 meterStopModalShow('resolve-connect','Connecting to '+ip+':'+port+'…');
 let r=null;
 try{
  r=await fetchJSON('/api/resolve/connect',{method:'POST',
   headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,port})});
 }catch(e){ r=null; }
 if(resolveConnectCancelled) return;
 if(!(r&&r.status==='ok')){
  meterStopModalHide();
  toast(r&&r.message?r.message:'Connect failed','err');
  return;
 }
 const t0=Date.now();
 let connected=false;
 while(Date.now()-t0<20000 && !resolveConnectCancelled){
  await new Promise(res=>setTimeout(res,700));
  if(resolveConnectCancelled) break;
  let s=null;
  try{ s=await fetchJSON('/api/resolve/status',{_quiet:true,_timeoutMs:4000}); }catch(e){ s=null; }
  if(s&&s.connected){connected=true;break;}
 }
 if(resolveConnectCancelled) return;
 meterStopModalHide();
 if(connected){toast('Resolve connected to '+ip+':'+port);loadInfo();}
 else{toast('Resolve connect timed out. Check the calibration software is listening on '+ip+':'+port,'err');loadInfo();}
}
// Cancel an in-progress connect (e.g. the operator realises the IP is wrong).
// Signals the daemon to abort via the disconnect flag; the daemon's connect is
// bounded (~10s) so the single connection thread frees for a corrected retry.
function resolveConnectCancel(){
 resolveConnectCancelled=true;
 try{ fetchJSON('/api/resolve/cancel',{method:'POST',_quiet:true}); }catch(e){}
 meterStopModalHide();
 toast('Connection cancelled');
 loadInfo();
}
async function resolvePatchSizeChanged(v){
 try{
  const r=await fetchJSON('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({resolve_patch_size:String(v||'')})});
  if(r&&r.status==='ok') toast(v?('Resolve patch size forced to '+v+'%'):'Resolve patch size follows the software');
  else toast('Failed to save setting','err');
 }catch(e){ toast('Failed to save setting','err'); }
}
async function resolveForceCenterChanged(on){
 try{
  const r=await fetchJSON('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({resolve_force_center:on?'1':'0'})});
  if(r&&r.status==='ok') toast(on?'Resolve patches will be centered':'Resolve patches follow the sent position');
  else toast('Failed to save setting','err');
 }catch(e){ toast('Failed to save setting','err'); }
}
async function resolveDisconnect(){
 const r=await fetchJSON('/api/resolve/disconnect',{method:'POST'});
 if(r&&r.status==='ok'){toast('Disconnected');setTimeout(loadInfo,500);}
 else toast('Disconnect failed','err');
}

// Interface layout controller. Desktop mode is deliberately a presentation
// layer over the existing dashboard DOM: controls, pollers, canvases and
// workflow state stay alive when their workspace is not currently visible.
const PG_LAYOUT_STORAGE_KEY='pgen.ui.layoutMode';
const PG_THEME_STORAGE_KEY='pgen.ui.themeMode';
const PG_DESKTOP_ZOOM_STORAGE_KEY='pgen.ui.desktopZoom';
const PG_DESKTOP_SIDEBAR_STORAGE_KEY='pgen.ui.desktopSidebarCollapsed';
const PG_METER_CONFIG_COLLAPSE_KEY='pgen.ui.meterConfigCollapsed';
const PG_DESKTOP_MIN_WIDTH=1024;
const PG_DESKTOP_WORKSPACES={
 output:'Output',patterns:'Patterns',calibration:'Calibration','3d-lut':'3D LUT','icc-profile':'Display Profiler','meter-profile':'Meter Profiler',
 'display-control':'LG Display',connectivity:'Connectivity',session:'Session','ui-settings':'UI Settings',system:'System'
};
let pgThemeMode='dark';
let pgLayoutPreference='tablet';
let pgLayoutEffective='tablet';
let pgDesktopZoom=1;
let pgDesktopWorkspace='output';
let pgDesktopSidebarCollapsed=false;
let pgDesktopSidebarRefreshTimer=null;
let pgLayoutResizeTimer=null;
let pgLayoutPanelObserver=null;
let pgLayoutViewportWidth=0;
let pgLayoutViewportHeight=0;

function pgWideEnoughForDesktop(){
 return window.innerWidth>=PG_DESKTOP_MIN_WIDTH;
}
function pgReadLayoutPreference(){
 try{
  const saved=localStorage.getItem(PG_LAYOUT_STORAGE_KEY);
  if(saved==='desktop'||saved==='tablet') return saved;
  return pgWideEnoughForDesktop()?'desktop':'tablet';
 }catch(e){ return pgWideEnoughForDesktop()?'desktop':'tablet'; }
}
function pgReadDesktopZoom(){
 try{
  const value=Number(localStorage.getItem(PG_DESKTOP_ZOOM_STORAGE_KEY));
  return [0.75,0.8,0.9,1,1.1,1.25].includes(value)?value:1;
 }catch(e){ return 1; }
}
function pgReadDesktopSidebarCollapsed(){
 try{ return localStorage.getItem(PG_DESKTOP_SIDEBAR_STORAGE_KEY)==='1'; }
 catch(e){ return false; }
}
function pgSyncDesktopSidebar(){
 const collapsed=!!pgDesktopSidebarCollapsed;
 document.documentElement.setAttribute('data-desktop-sidebar-collapsed',collapsed?'1':'0');
 document.querySelectorAll('.desktop-nav-btn[data-workspace-target]').forEach(button=>{
  if(!button.getAttribute('aria-label')) button.setAttribute('aria-label',button.title||'Workspace');
 });
 const toggle=document.getElementById('desktopSidebarToggle');
 if(toggle){
  toggle.setAttribute('aria-expanded',collapsed?'false':'true');
  toggle.setAttribute('aria-label',collapsed?'Expand workspace menu':'Collapse workspace menu');
  toggle.title=collapsed?'Expand workspace menu':'Collapse workspace menu';
 }
}
function pgSetDesktopSidebarCollapsed(collapsed){
 pgDesktopSidebarCollapsed=!!collapsed;
 try{ localStorage.setItem(PG_DESKTOP_SIDEBAR_STORAGE_KEY,pgDesktopSidebarCollapsed?'1':'0'); }catch(e){}
 pgSyncDesktopSidebar();
 if(pgDesktopSidebarRefreshTimer) clearTimeout(pgDesktopSidebarRefreshTimer);
 if(pgLayoutEffective==='desktop'){
  pgDesktopSidebarRefreshTimer=setTimeout(()=>{
   pgDesktopSidebarRefreshTimer=null;
   pgRefreshVisibleWorkspace({layoutOnly:true});
  },220);
 }
}
function pgToggleDesktopSidebar(){
 pgSetDesktopSidebarCollapsed(!pgDesktopSidebarCollapsed);
}
function pgApplyDesktopZoom(){
 const scale=pgLayoutEffective==='desktop'?pgDesktopZoom:1;
 const root=document.documentElement;
 root.style.zoom=scale===1?'':String(scale);
 root.style.width='';
 const select=document.getElementById('pgDesktopZoom');
 if(select) select.value=String(pgDesktopZoom);
}
function pgSetDesktopZoom(value){
 const parsed=Number(value);
 pgDesktopZoom=[0.75,0.8,0.9,1,1.1,1.25].includes(parsed)?parsed:1;
 try{ localStorage.setItem(PG_DESKTOP_ZOOM_STORAGE_KEY,String(pgDesktopZoom)); }catch(e){}
 pgApplyDesktopZoom();
 pgUpdateHeaderOffset();
 pgRefreshVisibleWorkspace();
}
function pgCanvasPixelRatio(){
 const nativeRatio=window.devicePixelRatio||1;
 const zoom=(pgLayoutEffective==='desktop'&&pgDesktopZoom>0)?pgDesktopZoom:1;
 // CSS zoom scales a canvas after it has been rasterized. Allocate the
 // inverse zoom in the backing store so chart text and one-pixel grid lines
 // still land at the display's native pixel density.
 return nativeRatio/zoom;
}
function meterSyncConfigurationCollapse(){
 const card=document.getElementById('meterCard');
 const button=document.getElementById('meterConfigToggle');
 if(!card||!button) return;
 let collapsed=false;
 try{ collapsed=localStorage.getItem(PG_METER_CONFIG_COLLAPSE_KEY)==='1'; }catch(e){}
 card.classList.toggle('meter-config-collapsed',collapsed);
 button.setAttribute('aria-expanded',collapsed?'false':'true');
 button.title=collapsed?'Expand meter and target settings':'Collapse meter and target settings';
}
function meterToggleConfiguration(event){
 if(event){ event.preventDefault();event.stopPropagation(); }
 const card=document.getElementById('meterCard');
 if(!card) return;
 const collapsed=!card.classList.contains('meter-config-collapsed');
 try{ localStorage.setItem(PG_METER_CONFIG_COLLAPSE_KEY,collapsed?'1':'0'); }catch(e){}
 meterSyncConfigurationCollapse();
}
function pgUpdateLayoutControls(){
 const effective=pgLayoutEffective;
 document.querySelectorAll('.layout-switch-btn[data-layout-mode]').forEach(btn=>{
  const mode=btn.getAttribute('data-layout-mode');
  btn.setAttribute('aria-pressed',mode===effective?'true':'false');
  if(mode==='desktop'){
   const unavailable=!pgWideEnoughForDesktop();
   btn.disabled=unavailable;
   btn.title=unavailable
    ?'Desktop mode requires a browser width of at least 1024 pixels'
    :'Use the full-width desktop workspace';
  }
 });
 const note=document.getElementById('desktopLayoutUnavailable');
 if(note) note.classList.toggle('is-visible',!pgWideEnoughForDesktop());
}
function pgReadThemeMode(){
 try{
  const saved=localStorage.getItem(PG_THEME_STORAGE_KEY);
  return saved==='light'||saved==='dark'?saved:'dark';
 }catch(e){ return 'dark'; }
}
function pgThemeColor(token,fallback){
 try{
  const value=getComputedStyle(document.documentElement).getPropertyValue(token).trim();
  return value||fallback;
 }catch(e){ return fallback; }
}
function pgUpdateThemeControls(){
 document.querySelectorAll('.theme-switch-btn[data-theme-mode]').forEach(btn=>{
  btn.setAttribute('aria-pressed',btn.getAttribute('data-theme-mode')===pgThemeMode?'true':'false');
 });
}
function pgRedrawChartsForTheme(){
 requestAnimationFrame(()=>requestAnimationFrame(()=>{
  meterLastChartSignature='';
  meterLastChartCount=0;
  try{
   if(typeof meterReadings!=='undefined'&&meterReadings&&meterReadings.length&&typeof drawAllCharts==='function') drawAllCharts(meterReadings);
   else if(typeof meterSeriesSteps!=='undefined'&&meterSeriesSteps&&meterSeriesSteps.length&&typeof drawAllChartsPreset==='function') drawAllChartsPreset(meterSeriesSteps);
  }catch(e){}
  try{
   if(typeof ccssPreviewLastPayload!=='undefined'&&ccssPreviewLastPayload&&typeof ccssPreviewRender==='function'){
    ccssPreviewRender(ccssPreviewLastPayload);
   }
  }catch(e){}
  try{ window.dispatchEvent(new Event('resize')); }catch(e){}
 }));
}
function pgApplyThemeMode(mode,options){
 pgThemeMode=mode==='light'?'light':'dark';
 document.documentElement.setAttribute('data-theme',pgThemeMode);
 pgUpdateThemeControls();
 if(!(options&&options.initial)){
  document.dispatchEvent(new CustomEvent('pgen:themechange',{detail:{theme:pgThemeMode}}));
  pgRedrawChartsForTheme();
 }
}
function pgSetThemeMode(mode){
 pgApplyThemeMode(mode);
 try{ localStorage.setItem(PG_THEME_STORAGE_KEY,pgThemeMode); }catch(e){}
}
function pgPanelBelongsToActiveWorkspace(panel){
 if(!panel||!panel.getAttribute) return false;
 const workspace=panel.getAttribute('data-desktop-workspace');
 const globalPanel=panel.getAttribute('data-desktop-global');
 const available=panel.style.display!=='none';
 return available&&((workspace===pgDesktopWorkspace)||!!globalPanel);
}
function pgSyncDesktopPanels(){
 document.querySelectorAll('.dashboard > .card[data-desktop-workspace]').forEach(panel=>{
  panel.setAttribute('data-desktop-active',pgPanelBelongsToActiveWorkspace(panel)?'true':'false');
  const order=Number(panel.getAttribute('data-desktop-order')||0);
  if(Number.isFinite(order)) panel.style.order=String(order);
 });
}
function pgSyncMeterDesktopWorkspaceAvailability(){
 const desktop=document.body.classList.contains('layout-desktop');
 // The 3D LUT and Display Profiler workspaces stay visible even with no meter
 // attached: the operator should be able to see every feature, and the
 // no-meter banner offers the simulated meter for actual readings.
 const workspaces=[
  {target:'3d-lut',panel:'meter3dLutWorkspaceCard',tab:'3dlut'},
  {target:'icc-profile',panel:'meterIccWorkspaceCard',tab:'icc'}
 ];
 workspaces.forEach(function(entry){
  const nav=document.querySelector('.desktop-nav-btn[data-workspace-target="'+entry.target+'"]');
  const panel=document.getElementById(entry.panel);
  if(nav){ nav.hidden=false; nav.setAttribute('aria-hidden','false'); }
  if(panel) panel.style.display='';
 });
 if(!desktop) return;
 pgSyncDesktopPanels();
}
function pgRefreshVisibleWorkspace(options){
 const layoutOnly=!!(options&&options.layoutOnly);
 requestAnimationFrame(()=>requestAnimationFrame(()=>{
  try{ window.dispatchEvent(new Event('resize')); }catch(e){}
  if(layoutOnly) return;
  // Workspace and viewport changes are presentation-only. Repaint the current
  // in-memory snapshot without rebuilding steps or consulting measurement
  // caches, otherwise a resize can replace freshly graded results with an
  // older series context.
  if(pgDesktopWorkspace==='calibration'&&typeof meterRedrawActiveSeriesCharts==='function'){
   try{ meterRedrawActiveSeriesCharts(); }catch(e){}
  }else if(typeof pgRedrawChartsForTheme==='function') pgRedrawChartsForTheme();
 }));
}
function pgSyncCardCollapseForLayout(){
 let state={};
 try{ state=JSON.parse(localStorage.getItem('cardCollapse')||'{}')||{}; }catch(e){ state={}; }
 document.querySelectorAll('.card[data-collapse-key]').forEach(card=>{
  if(pgLayoutEffective==='desktop') card.classList.remove('collapsed');
  else card.classList.toggle('collapsed',!!state[card.dataset.collapseKey]);
 });
}
function meterPlace3dLutWorkspaceForLayout(){
 const group=document.getElementById('meterSeriesGroup3dLut');
 const groupHome=document.getElementById('meter3dLutSeriesHome');
 const groupHost=document.getElementById('meter3dLutSeriesWorkspaceHost');
 const tools=document.getElementById('meterLutToolsModal');
 const toolsHome=document.getElementById('meterLutToolsHome');
 const toolsHost=document.getElementById('meter3dLutToolsWorkspaceHost');
 const desktop=document.body.classList.contains('layout-desktop');
 if(group&&groupHome&&groupHost){
  if(desktop){ if(group.parentNode!==groupHost) groupHost.appendChild(group); }
  else if(group.previousElementSibling!==groupHome) groupHome.insertAdjacentElement('afterend',group);
 }
 if(tools&&toolsHome&&toolsHost){
  if(desktop){
   if(tools.parentNode!==toolsHost) toolsHost.appendChild(tools);
  }else{
   const returningFromDesktop=tools.parentNode===toolsHost;
   if(tools.parentNode!==toolsHome.parentNode) toolsHome.insertAdjacentElement('afterend',tools);
   // A Tablet modal open locks body scrolling, which can fire a viewport
   // resize and re-run this layout sync. Do not close an already-hosted modal;
   // hide it only when it is actually returning from the Desktop workspace.
   if(returningFromDesktop) tools.style.display='none';
  }
 }
 meterSync3dLutWorkspaceUi();
}
function meterPlaceIccWorkspaceForLayout(){
 const modal=document.getElementById('meterIccProfileModal');
 const home=document.getElementById('meterIccProfileHome');
 const host=document.getElementById('meterIccWorkspaceHost');
 const desktop=document.body.classList.contains('layout-desktop');
 if(!modal||!home||!host) return;
 if(desktop){
  if(modal.parentNode!==host) host.appendChild(modal);
 }else{
  const returningFromDesktop=modal.parentNode===host;
  if(modal.parentNode!==home.parentNode) home.insertAdjacentElement('afterend',modal);
  if(returningFromDesktop) modal.style.display='none';
 }
}
function meterActivate3dLutWorkspace(){
 if(!document.body.classList.contains('layout-desktop')) return;
 meterPlace3dLutWorkspaceForLayout();
 meterSetSeriesTab('3dlut');
 try{ meterLoadSolvedLutList(); }catch(e){}
 meterSync3dLutWorkspaceUi();
}
// Human label for the active 3D LUT profiling series. Built-in hybrid /
// skeleton / lattice / matrix never update the "Select series…" button text,
// so the workspace status must not fall back to that placeholder.
function meter3dLutSelectedSeriesLabel(){
 try{
  if(typeof meterActiveMatrixProfileSeries==='function'&&meterActiveMatrixProfileSeries()){
   return 'Matrix (5-point)';
  }
  const vol=(typeof meterActiveVolumeProfileSeries==='function')?meterActiveVolumeProfileSeries():null;
  if(vol){
   const n=String(vol.name||'').trim();
   if(n) return n;
   const kind=String(vol.kind||'').toLowerCase();
   if(kind==='hybrid') return 'Hybrid';
   if(kind==='skeleton') return 'Skeleton';
   if(kind==='lattice') return 'Lattice';
  }
  const loaded=document.getElementById('meterCustomSeriesLoaded3dLut');
  const loadedName=loaded&&loaded.style.display!=='none'?String(loaded.textContent||'').trim():'';
  if(loadedName) return loadedName;
 }catch(e){}
 return '';
}
function meterSync3dLutWorkspaceUi(){
 const button=document.getElementById('meter3dLutWorkspaceBuildBtn');
 const status=document.getElementById('meter3dLutWorkspaceStatus');
 if(!button&&!status) return;
 const selected=typeof meter3dLutTabHasSelectedSeries==='function'&&meter3dLutTabHasSelectedSeries();
 const seriesName=meter3dLutSelectedSeriesLabel();
 const picker=document.getElementById('meter3dLutSelectSeriesBtn');
 if(status) status.textContent=selected
  ?('Selected: '+(seriesName||'3D LUT profiling series'))
  :'Select a profiling series to begin.';
 if(picker){
  picker.title=selected&&seriesName
   ?('Selected: '+seriesName+' — click to choose another profiling series')
   :'Choose a 3D LUT profiling series to measure (lattice / skeleton / hybrid) — same method chooser and descriptions as the standalone 3D LUT AutoCal';
 }
 if(button){
  const busy=!!window._configApplyPending||meterActionPending||meterSeriesRunning||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning||meterContinuousActive;
  const dirty=hasUnsavedSettings();
  button.disabled=!selected||!meterDetected||dirty||busy;
  button.title=!selected?'Select a built-in or custom 3D LUT profiling series first':!meterDetected?'Connect a meter first':dirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'Build a 3D LUT from the selected profiling series';
  button.textContent=(meterSeriesRunning||meterActionPending)?'Building…':'Build 3D LUT';
 }
}
function pgSelectDesktopWorkspace(workspace,options){
 if(!Object.prototype.hasOwnProperty.call(PG_DESKTOP_WORKSPACES,workspace)) workspace='output';
 const previousWorkspace=pgDesktopWorkspace;
 const workspaceChanged=pgDesktopWorkspace!==workspace;
 pgDesktopWorkspace=workspace;
 document.querySelectorAll('.desktop-nav-btn[data-workspace-target]').forEach(btn=>{
  const active=btn.getAttribute('data-workspace-target')===workspace;
  if(active) btn.setAttribute('aria-current','page');
  else btn.removeAttribute('aria-current');
 });
 const title=document.getElementById('desktopWorkspaceTitle');
 if(title) title.textContent=PG_DESKTOP_WORKSPACES[workspace];
 pgSyncDesktopPanels();
 if(workspace==='meter-profile'&&workspaceChanged&&document.body.classList.contains('layout-desktop')){
  meterPlaceCcssEditorForLayout();
  meterActivateCcssEditorWorkspace();
 }
 if(workspace==='3d-lut'&&workspaceChanged&&document.body.classList.contains('layout-desktop')) meterActivate3dLutWorkspace();
 if(workspace==='icc-profile'&&workspaceChanged&&document.body.classList.contains('layout-desktop')){
  meterPlaceIccWorkspaceForLayout();
  meterOpenIccProfileBuilder();
 }
 if(workspace!=='icc-profile'&&workspaceChanged&&document.body.classList.contains('layout-desktop')&&meterIccCompanionTimer){
  clearInterval(meterIccCompanionTimer);
  meterIccCompanionTimer=null;
 }
 if(previousWorkspace==='3d-lut'&&workspace==='calibration'&&document.body.classList.contains('layout-desktop')) meterSetSeriesTab('greyscale');
 if(workspaceChanged&&(workspace==='calibration'||workspace==='3d-lut')&&document.body.classList.contains('layout-desktop')){
  // Pick up series created/imported in another browser whenever the operator
  // returns to a measurement workspace; no page reload should be required.
  try{ meterRefreshCustomSeriesFromServer(); }catch(e){}
 }
 // Revealing Calibration changes only layout. Keep the exact in-memory
 // measurement revision and repaint it before the browser exposes the canvas.
 if(workspaceChanged&&workspace==='calibration'&&document.body.classList.contains('layout-desktop')&&typeof meterRedrawActiveSeriesCharts==='function'){
  try{ meterRedrawActiveSeriesCharts(); }catch(e){}
 }
 // LG calibration history: only when entering LG Display, not on loadInfo poll.
 try{ if(typeof lgMaybeRefreshCalHistoryForDesktopWorkspace==='function') lgMaybeRefreshCalHistoryForDesktopWorkspace(workspace,workspaceChanged); }catch(e){}
 pgRefreshVisibleWorkspace();
 if(options&&options.focus&&title){
  try{ title.focus({preventScroll:true}); }catch(e){ title.focus(); }
 }
}
function pgApplyLayout(options){
 const previous=pgLayoutEffective;
 pgLayoutEffective=(pgLayoutPreference==='desktop'&&pgWideEnoughForDesktop())?'desktop':'tablet';
 document.body.classList.toggle('layout-desktop',pgLayoutEffective==='desktop');
 document.body.classList.toggle('layout-tablet',pgLayoutEffective==='tablet');
 pgSyncMeterDesktopWorkspaceAvailability();
 pgSyncDesktopSidebar();
 pgApplyDesktopZoom();
 meterPlaceCcssEditorForLayout();
 meterPlace3dLutWorkspaceForLayout();
 meterPlaceIccWorkspaceForLayout();
 uiSyncBodyScrollLock();
 meterSyncGreyscaleDesktopLayout();
 pgSyncCardCollapseForLayout();
 pgUpdateLayoutControls();
 if(pgLayoutEffective==='desktop'){
  if(previous!=='desktop'||(options&&options.resetWorkspace)) pgDesktopWorkspace='output';
  pgSelectDesktopWorkspace(pgDesktopWorkspace);
 }else{
  pgSetDesktopUtilityDrawer(false);
  document.querySelectorAll('.dashboard > .card[data-desktop-workspace]').forEach(panel=>{panel.style.order='';});
  // Desktop workspaces assign inline presentation order. Clear it when
  // returning to Tablet or CSS order masks DOM drag-and-drop reordering.
  document.querySelectorAll('.dashboard > .card[data-desktop-active]').forEach(panel=>panel.removeAttribute('data-desktop-active'));
  pgRefreshVisibleWorkspace();
 }
}
function meterSyncGreyscaleDesktopLayout(){
 const live=document.getElementById('meterLiveReading');
 const home=document.getElementById('meterLiveReadingHome');
 const rail=document.getElementById('meterGreyLiveRail');
 if(!live||!home||!rail) return;
 const useRail=document.body.classList.contains('layout-desktop');
 if(useRail){
  if(live.parentNode!==rail) rail.appendChild(live);
 }else if(live.previousElementSibling!==home){
  home.insertAdjacentElement('afterend',live);
 }
}
function pgSetLayoutPreference(mode){
 pgLayoutPreference=mode==='desktop'?'desktop':'tablet';
 try{ localStorage.setItem(PG_LAYOUT_STORAGE_KEY,pgLayoutPreference); }catch(e){}
 pgApplyLayout({resetWorkspace:pgLayoutPreference==='desktop'});
}
function pgUpdateHeaderOffset(){
 const header=document.querySelector('.header');
 if(!header) return;
 document.documentElement.style.setProperty('--pg-header-height',Math.ceil(header.getBoundingClientRect().height)+'px');
}
function pgLayoutInit(){
 pgApplyThemeMode(pgReadThemeMode(),{initial:true});
 pgLayoutPreference=pgReadLayoutPreference();
 pgDesktopZoom=pgReadDesktopZoom();
 pgDesktopSidebarCollapsed=pgReadDesktopSidebarCollapsed();
 pgLayoutEffective='tablet';
 pgDesktopWorkspace='output';
 pgLayoutViewportWidth=Math.round(window.innerWidth||0);
 pgLayoutViewportHeight=Math.round(window.innerHeight||0);
 pgUpdateHeaderOffset();
 pgApplyLayout({resetWorkspace:true});
 meterSyncConfigurationCollapse();
 const header=document.querySelector('.header');
 if(header&&window.ResizeObserver){
  try{ new ResizeObserver(pgUpdateHeaderOffset).observe(header); }catch(e){}
 }
 const dashboard=document.querySelector('.dashboard');
 if(dashboard&&window.MutationObserver){
  try{
   pgLayoutPanelObserver=new MutationObserver(mutations=>{
    if(document.body.classList.contains('layout-desktop')&&mutations.some(m=>m.target&&m.target.matches&&m.target.matches('.dashboard > .card[data-desktop-workspace]'))) pgSyncDesktopPanels();
   });
   pgLayoutPanelObserver.observe(dashboard,{subtree:true,attributes:true,attributeFilter:['style']});
  }catch(e){}
 }
 window.addEventListener('resize',()=>{
  const width=Math.round(window.innerWidth||0);
  const height=Math.round(window.innerHeight||0);
  // Chart code deliberately dispatches synthetic resize events after a
  // workspace/theme redraw. Re-running pgApplyLayout for those events calls
  // pgRefreshVisibleWorkspace, which dispatches resize again and creates a
  // permanent redraw loop. Only the real viewport changing needs layout work.
  if(width===pgLayoutViewportWidth&&height===pgLayoutViewportHeight) return;
  pgLayoutViewportWidth=width;
  pgLayoutViewportHeight=height;
  pgUpdateHeaderOffset();
  if(pgLayoutResizeTimer) clearTimeout(pgLayoutResizeTimer);
  pgLayoutResizeTimer=setTimeout(()=>pgApplyLayout(),80);
 });
}

function pgUtilityControlText(id){
 const el=document.getElementById(id);
 if(!el) return '-';
 if(el.tagName==='SELECT'){
  const option=el.options&&el.selectedIndex>=0?el.options[el.selectedIndex]:null;
  return option?String(option.textContent||option.value||'-').trim():'-';
 }
 return String(el.value!=null?el.value:(el.textContent||'-')).trim()||'-';
}
function pgUtilitySetRows(id,rows){
 const host=document.getElementById(id);
 if(!host) return;
 const normalized=(rows||[]).map(row=>[String(row[0]||''),(row[1]==null||String(row[1]).trim()==='')?'-':String(row[1])]);
 const signature=JSON.stringify(normalized);
 if(host.dataset.utilitySignature===signature) return;
 host.dataset.utilitySignature=signature;
 host.innerHTML='';
 normalized.forEach(row=>{
  const label=document.createElement('div');
  const value=document.createElement('div');
  label.className='desktop-utility-label';
  value.className='desktop-utility-value';
  label.textContent=row[0];
  value.textContent=row[1];
  host.appendChild(label);
  host.appendChild(value);
 });
}
function pgUtilityInfoframeText(decodedId,rawId){
 const decoded=document.getElementById(decodedId);
 const raw=document.getElementById(rawId);
 const decodedText=decoded?String(decoded.innerText||decoded.textContent||'').trim():'';
 const rawText=raw?String(raw.textContent||'').trim():'';
 return [decodedText,rawText&&rawText!=='-'?rawText:''].filter(Boolean).join('\n')||'No data';
}
function pgUtilitySetText(el,value){
 if(!el) return;
 const next=String(value==null?'':value);
 if(el.textContent!==next) el.textContent=next;
}
function pgSyncDesktopUtilityDrawer(){
 pgUtilitySetRows('desktopUtilityOutput',[
  ['Resolution',pgUtilityControlText('mode_idx_text')],['Signal Mode',pgUtilityControlText('signal_mode')],
  ['Bit Depth',pgUtilityControlText('max_bpc')],['Color Format',pgUtilityControlText('color_format')],
  ['Colorimetry',pgUtilityControlText('colorimetry')],['Range',pgUtilityControlText('rgb_quant_range')]
 ]);
 const signal=String(getVal('signal_mode')||'sdr');
 const metadataTitle=document.getElementById('desktopUtilityMetadataTitle');
 let metadata=[];
 if(signal==='dv'){
  if(metadataTitle) metadataTitle.textContent='Dolby Vision Metadata';
  metadata=[['Transport',pgUtilityControlText('dv_transport')],['Map Mode',pgUtilityControlText('dv_map_mode')],['Max Luma',pgUtilityControlText('dv_max_luma')+' nits'],['Min Luma',pgUtilityControlText('dv_min_luma')+' nits'],['MaxCLL',pgUtilityControlText('dv_max_cll')],['MaxFALL',pgUtilityControlText('dv_max_fall')]];
 }else if(signal==='hdr10'||signal==='hlg'){
  if(metadataTitle) metadataTitle.textContent='HDR Metadata';
  metadata=[['EOTF',pgUtilityControlText('eotf')],['Primaries',pgUtilityControlText('primaries')],['Max Luma',pgUtilityControlText('max_luma')+' nits'],['Min Luma',pgUtilityControlText('min_luma')+' nits'],['MaxCLL',pgUtilityControlText('max_cll')],['MaxFALL',pgUtilityControlText('max_fall')]];
 }else{
  if(metadataTitle) metadataTitle.textContent='HDMI Metadata';
  metadata=[['EOTF',pgUtilityControlText('eotf')],['Primaries',pgUtilityControlText('primaries')]];
 }
 pgUtilitySetRows('desktopUtilityMetadata',metadata);
 const avi=document.getElementById('desktopUtilityAvi');
 const drm=document.getElementById('desktopUtilityDrm');
 pgUtilitySetText(avi,pgUtilityInfoframeText('aviDecoded','aviIF'));
 pgUtilitySetText(drm,pgUtilityInfoframeText('drmDecoded','drmIF'));
 const cec=document.getElementById('cecStatus');
 const cecOut=document.getElementById('desktopUtilityCecStatus');
 pgUtilitySetText(cecOut,cec?String(cec.innerText||cec.textContent||'Checking...').trim():'Checking...');
 const cecDevices=document.getElementById('cecDeviceList');
 const cecDevicesOut=document.getElementById('desktopUtilityCecDevices');
 pgUtilitySetText(cecDevicesOut,cecDevices?String(cecDevices.innerText||cecDevices.textContent||'Not scanned yet').trim():'Not scanned yet');
 const deviceRows=[['CPU Usage',String((document.getElementById('cpuUsageValue')||{}).textContent||'--%').trim()],['Memory Usage',String((document.getElementById('memUsageValue')||{}).textContent||'--%').trim()]];
 const info=document.getElementById('infoGrid');
 if(info){
  info.querySelectorAll('.info-item').forEach(item=>{
   const label=item.querySelector('.label');
   const value=item.querySelector('.value');
   if(label&&value) deviceRows.push([String(label.textContent||'').trim(),String(value.textContent||'').trim()]);
  });
 }
 pgUtilitySetRows('desktopUtilityDevice',deviceRows);
}
function pgSetDesktopUtilityDrawer(open){
 const next=!!open&&document.body.classList.contains('layout-desktop');
 document.body.classList.toggle('desktop-utility-open',next);
 const toggle=document.getElementById('desktopUtilityToggle');
 const drawer=document.getElementById('desktopUtilityDrawer');
 const arrow=document.getElementById('desktopUtilityArrow');
 if(toggle){toggle.setAttribute('aria-expanded',next?'true':'false');toggle.setAttribute('aria-label',next?'Close live information sidebar':'Open live information sidebar');}
 if(drawer) drawer.setAttribute('aria-hidden',next?'false':'true');
 if(arrow) arrow.innerHTML=next?'&#8250;':'&#8249;';
 if(next) pgSyncDesktopUtilityDrawer();
 // The drawer reserves workspace width in Desktop mode. Redraw charts once,
 // after the CSS transition reaches its final size; redrawing both before and
 // after the transition doubled the most expensive calibration work.
 setTimeout(()=>window.dispatchEvent(new Event('resize')),240);
}
function pgToggleDesktopUtilityDrawer(){
 pgSetDesktopUtilityDrawer(!document.body.classList.contains('desktop-utility-open'));
}
function pgDesktopUtilityInit(){
 document.addEventListener('change',()=>{if(document.body.classList.contains('desktop-utility-open')) pgSyncDesktopUtilityDrawer();});
 document.addEventListener('keydown',event=>{if(event.key==='Escape'&&document.body.classList.contains('desktop-utility-open')) pgSetDesktopUtilityDrawer(false);});
 setInterval(()=>{if(!document.hidden&&document.body.classList.contains('desktop-utility-open')) pgSyncDesktopUtilityDrawer();},3000);
}

async function loadInfoframes(){
 const r=await fetchJSON('/api/infoframes',{_quiet:true,_timeoutMs:10000});
 if(!r||r.status!=='ok') return;
 const ae=document.getElementById('aviIF');
 const ad=document.getElementById('aviDecoded');
 const de=document.getElementById('drmIF');
 const dd=document.getElementById('drmDecoded');
 /* AVI InfoFrame */
 if(r.avi){
  ae.textContent=r.avi;
  const b=r.avi.split(':').map(x=>parseInt(x,16));
  if(b.length>=5){
   const y=(b[4]>>5)&3;const yName=['RGB','YCbCr 4:2:2','YCbCr 4:4:4','YCbCr 4:2:0'][y]||'?';
   const q=(b[6]>>2)&3;const qName=['Default','Limited','Full','Reserved'][q]||'?';
   const c=(b[5]>>6)&3;const cName=['None','SMPTE 170M','BT.709','Extended'][c]||'?';
   const vic=b[7]&0x7f;
   let lines=['Color: '+yName,'Quant: '+qName,'Colorimetry: '+cName,'VIC: '+vic];
   if(c===3&&b.length>=7){
    const ec=b[6]&0x70;const ecName={0:'xvYCC 601',0x10:'xvYCC 709',0x20:'sYCC',
     0x30:'opYCC',0x40:'opRGB',0x50:'BT.2020 cYCC',0x60:'BT.2020 YCC/RGB',0x70:'Reserved'}[ec]||'?';
    lines[2]='Colorimetry: '+ecName;
   }
   ad.innerHTML=lines.join('<br>');
  }
 }else{ae.textContent='-';ad.innerHTML='';}
 /* DRM InfoFrame */
 if(r.drm){
  de.textContent=r.drm;
  const b=r.drm.split(':').map(x=>parseInt(x,16));
  if(b.length>=6){
   const eotf=b[4];const eotfName=['SDR','HDR (traditional)','PQ (ST 2084)','HLG'][eotf]||'Unknown ('+eotf+')';
   let lines=['EOTF: '+eotfName];
   if(b.length>=26){
    const u16=(l,h)=>l|(h<<8);
    const maxLum=u16(b[22],b[23]);
    const minLum=u16(b[24],b[25]);
    lines.push('Max Lum: '+maxLum+' cd/m²');
    lines.push('Min Lum: '+(minLum/10000).toFixed(4)+' cd/m²');
    if(b.length>=30){
     const maxCLL=u16(b[26],b[27]);
     const maxFALL=u16(b[28],b[29]);
     lines.push('Max CLL: '+maxCLL+' cd/m²');
     lines.push('Max FALL: '+maxFALL+' cd/m²');
    }
   }
   dd.innerHTML=lines.join('<br>');
  }
 }else{de.textContent='-';dd.innerHTML='';}
}

// Widget reorder: POINTER drag on ☰ .drag-handle only (no HTML5 DnD).
// Drop target = card under the cursor; insert before/after by midpoint.
// Avoid setPointerCapture + moving the capture node (that combo was a no-op).
(function(){
 const dash=document.querySelector('.dashboard');
 if(!dash) return;
 // Direct children only (reliable without :scope).
 const widgets=()=>[...dash.children].filter(el=>el&&el.getAttribute&&el.getAttribute('data-widget'));
 let dragEl=null;
 let moved=false;
 let startX=0,startY=0;
 let active=false; // true once past drag threshold
 let lastTarget=null;
 let lastBefore=true;

 function saveOrder(){
  try{
   localStorage.setItem('pg_widget_order',JSON.stringify(widgets().map(w=>w.dataset.widget)));
  }catch(e){}
 }
 function restoreOrder(){
  try{
   const order=JSON.parse(localStorage.getItem('pg_widget_order'));
   const uiSettings=document.getElementById('uiSettingsCard');
   const session=document.getElementById('sessionCard');
   const update=document.getElementById('updateCard');
   const placeBottomPair=()=>{
    const anchor=(update&&update.parentNode===dash)?update:(dash.querySelector('.toast')||null);
    if(uiSettings&&uiSettings.parentNode===dash) dash.insertBefore(uiSettings,anchor);
    if(session&&session.parentNode===dash) dash.insertBefore(session,anchor);
   };
   if(!order||!Array.isArray(order)){
    // Session and UI Settings share the final half-width row immediately
    // above the full-width Software Update card by default. They remain
    // ordinary draggable widgets after this initial placement.
    placeBottomPair();
    return;
   }
   const map={}; widgets().forEach(w=>{ map[w.dataset.widget]=w; });
   const end=dash.querySelector('.toast')||null;
   order.forEach(id=>{ if(map[id]) dash.insertBefore(map[id],end); });
   // Existing browsers have a saved order created before UI Settings became
   // draggable. Put that newly introduced widget at the default end once;
   // the next drag save includes it and preserves the operator's placement.
   if((uiSettings&&order.indexOf('ui_settings')<0)||(session&&order.indexOf('session')<0)) placeBottomPair();
  }catch(e){}
 }
 function clearDragState(){
  if(dragEl){
   dragEl.classList.remove('dragging');
   dragEl.style.pointerEvents='';
  }
  widgets().forEach(w=>w.classList.remove('dragging','drag-over'));
  dragEl=null;
  moved=false;
  active=false;
  lastTarget=null;
  document.body.classList.remove('is-widget-dragging');
  try{ document.body.style.cursor=''; document.documentElement.style.cursor=''; }catch(e){}
 }

 // Kill native HTML5 drag on every widget card (markup still has draggable=true).
 function disableNativeDrag(){
  dash.querySelectorAll('[data-widget]').forEach(w=>w.setAttribute('draggable','false'));
 }
 disableNativeDrag();
 dash.addEventListener('dragstart',e=>{
  if(e.target.closest&&e.target.closest('[data-widget]')) e.preventDefault();
 },true);

 function cardUnderPoint(x,y){
  // Prefer elementsFromPoint so we skip the translucent dragged card.
  let list=[];
  try{ list=document.elementsFromPoint(x,y)||[]; }catch(e){
   const one=document.elementFromPoint(x,y);
   if(one) list=[one];
  }
  for(let i=0;i<list.length;i++){
   const el=list[i];
   if(!el||!el.closest) continue;
   const w=el.closest('[data-widget]');
   if(w&&w!==dragEl&&dash.contains(w)&&w.parentNode===dash) return w;
  }
  return null;
 }

 // Move dragEl next to target (before if pointer in top/left half, else after).
 function placeRelativeTo(target,clientX,clientY){
  if(!dragEl||!target||target===dragEl) return;
  const r=target.getBoundingClientRect();
  const sameRow=clientY>=r.top&&clientY<=r.bottom;
  let before;
  if(sameRow) before=clientX<(r.left+r.right)/2;
  else before=clientY<(r.top+r.bottom)/2;

  lastTarget=target;
  lastBefore=before;
  widgets().forEach(c=>c.classList.remove('drag-over'));
  target.classList.add('drag-over');

  // Always re-insert (no nextElementSibling short-circuit — that blocked swaps).
  if(before){
   if(dragEl.nextSibling!==target) target.parentNode.insertBefore(dragEl,target);
  } else {
   // insert after target
   const ref=target.nextSibling;
   if(ref!==dragEl){
    if(ref) target.parentNode.insertBefore(dragEl,ref);
    else target.parentNode.appendChild(dragEl);
   }
  }
  // Verify we actually changed something relative to target
  if(before){
   if(dragEl.nextElementSibling===target||target.previousElementSibling===dragEl) moved=true;
  } else {
   if(target.nextElementSibling===dragEl||dragEl.previousElementSibling===target) moved=true;
  }
 }

 function onPointerDown(e){
  if(document.body.classList.contains('layout-desktop')) return;
  if(e.button!=null&&e.button!==0) return;
  const handle=e.target.closest&&e.target.closest('.drag-handle');
  if(!handle) return;
  const w=handle.closest('[data-widget]');
  if(!w||w.parentNode!==dash) return;
  // Don't capture — moving the capture target breaks the gesture.
  e.preventDefault();
  dragEl=w;
  moved=false;
  active=false;
  startX=e.clientX;
  startY=e.clientY;
  lastTarget=null;
  w.classList.add('dragging');
  w.style.pointerEvents='none'; // so elementFromPoint sees cards underneath
  document.body.classList.add('is-widget-dragging');
  document.body.style.cursor='grabbing';
 }

 function onPointerMove(e){
  if(!dragEl) return;
  const dx=e.clientX-startX, dy=e.clientY-startY;
  if(!active&&(dx*dx+dy*dy)<25) return; // 5px threshold
  active=true;
  const target=cardUnderPoint(e.clientX,e.clientY);
  if(target) placeRelativeTo(target,e.clientX,e.clientY);
 }

 function onPointerUp(e){
  if(!dragEl) return;
  if(active){
   const target=cardUnderPoint(e.clientX,e.clientY)||lastTarget;
   if(target) placeRelativeTo(target,e.clientX,e.clientY);
   if(moved) saveOrder();
  }
  clearDragState();
 }

 // Capture phase on document so nothing inside cards eats the events.
 document.addEventListener('pointerdown',onPointerDown,true);
 document.addEventListener('pointermove',onPointerMove,true);
 document.addEventListener('pointerup',onPointerUp,true);
 document.addEventListener('pointercancel',onPointerUp,true);
 window.addEventListener('blur',clearDragState);
 document.addEventListener('visibilitychange',()=>{ if(document.hidden) clearDragState(); });
 document.addEventListener('keydown',e=>{ if(e.key==='Escape') clearDragState(); });
 restoreOrder();
 // Late-injected widgets (e.g. Display/LG card) — re-disable native drag.
 try{
  const mo=new MutationObserver(()=>disableNativeDrag());
  mo.observe(dash,{childList:true,subtree:true});
 }catch(e){}
})();

async function checkUpdate(){
 _updateChecked=true;
 document.getElementById('updateStatus').textContent='Checking GitHub for updates...';
 const r=await fetchJSON('/api/update/check',{_quiet:true,_timeoutMs:30000});
 if(!r||r.status==='error'){
  document.getElementById('updateStatus').textContent=r?r.message:'Check failed — no internet?';
  return;
 }
 document.getElementById('updateCurrent').textContent='v'+r.current;
 document.getElementById('updateLatest').textContent='v'+r.latest;
 document.getElementById('updatePublished').textContent=r.published?r.published.split('T')[0]:'-';
 if(r.changelog){
  document.getElementById('updateChangelog').textContent=r.changelog;
 }
 if(r.update_available){
  document.getElementById('applyUpdateBtn').style.display='';
  document.getElementById('updateBtn').style.display='';
  document.getElementById('updateBtn').classList.add('update-pulse');
  document.getElementById('updateStatus').textContent='A new version is available.';
 } else {
  document.getElementById('applyUpdateBtn').style.display='none';
  document.getElementById('updateBtn').style.display='none';
  document.getElementById('updateStatus').textContent='You are running the latest version.';
 }
}
let _updateChecked=false;
function showUpdateCard(){
 document.getElementById('updateCard').style.display='';
 if(document.body.classList.contains('layout-desktop')) pgSelectDesktopWorkspace('system');
 document.getElementById('updateCard').scrollIntoView({behavior:'smooth'});
 if(!_updateChecked) checkUpdate();
}
async function applyUpdate(){
 if(!confirm('Install update now? PGenerator+ will restart.'))return;
 document.getElementById('applyUpdateBtn').disabled=true;
 document.getElementById('updateStatus').innerHTML='<span class="spinner"></span> Downloading and installing...';
 const r=await fetchJSON('/api/update/apply',{method:'POST'});
 if(r&&r.status==='ok'){
  document.getElementById('updateStatus').textContent='Update started. The page will reload when PGenerator+ restarts...';
  setTimeout(()=>location.reload(),30000);
  let checks=0;
  const poll=setInterval(async()=>{
   checks++;
   try{const p=await fetch(API+'/api/ping',{signal:AbortSignal.timeout(3000)});if(p.ok){clearInterval(poll);location.reload();}}catch(e){}
   if(checks>60)clearInterval(poll);
  },5000);
 } else {
  document.getElementById('updateStatus').textContent=r?r.message:'Update failed';
  document.getElementById('applyUpdateBtn').disabled=false;
 }
}
async function submitLogs(){
 const btn=document.getElementById('submitLogsBtn');
 btn.disabled=true;btn.textContent='Collecting...';
 try{
  const res=await fetch('/api/submit_logs',{method:'POST'});
  if(res.ok){
   const blob=await res.blob();
   const cd=res.headers.get('Content-Disposition')||'';
   const m=cd.match(/filename="([^"]+)"/);
   const fname=m?m[1]:'PGenerator_diag.txt';
   const a=document.createElement('a');
   a.href=URL.createObjectURL(blob);
   a.download=fname;
   document.body.appendChild(a);a.click();a.remove();
   URL.revokeObjectURL(a.href);
   toast('Diagnostic report downloaded');
  }else{
   const j=await res.json().catch(()=>null);
   toast(j?j.message:'Failed to collect logs','error');
  }
 }catch(e){toast('Error: '+e.message,'error');}
 btn.disabled=false;btn.innerHTML='&#128230; Submit Logs';
}

function systemBackupSetStatus(message,isError){
 const status=document.getElementById('systemBackupStatus');
 if(!status)return;
 status.textContent=String(message||'');
 status.style.color=isError?'var(--red)':'var(--text2)';
}
async function systemBackupWaitForReboot(){
 const started=Date.now();
 let sawOffline=false;
 while(Date.now()-started<180000){
  await new Promise(resolve=>setTimeout(resolve,2000));
  let online=false;
  try{
   const response=await fetch('/api/ping?_reboot_check='+Date.now(),{
    cache:'no-store',signal:AbortSignal.timeout(2500)
   });
   online=response.ok;
  }catch(e){
   online=false;
  }
  if(!online){
   sawOffline=true;
   continue;
  }
  // Normally reload only after observing the Pi go offline and return. Some
  // browsers can miss a short outage, so reload once the normal reboot window
  // has elapsed even if every individual ping happened to land while online.
  if(sawOffline||Date.now()-started>=30000){
   systemBackupSetStatus('PGenerator+ is back online. Reloading...',false);
   location.reload();
   return;
  }
 }
 systemBackupSetStatus('Could not confirm that PGenerator+ restarted. Reload this page after the device is back online.',true);
}
async function exportSystemSettings(){
 const btn=document.getElementById('exportSystemSettingsBtn');
 if(btn){btn.disabled=true;btn.textContent='Creating Backup...';}
 systemBackupSetStatus('Collecting settings, profiles, calibration history and custom diagnostic media...',false);
 try{
  const response=await fetch('/api/system-backup/export',{method:'POST'});
  if(!response.ok){
   const error=await response.json().catch(()=>null);
   throw new Error(error&&error.message?error.message:'Could not create system backup');
  }
  const blob=await response.blob();
  const disposition=response.headers.get('Content-Disposition')||'';
  const match=disposition.match(/filename="([^"]+)"/);
  const filename=match?match[1]:'PGenerator_plus_system_backup.pgbackup';
  const link=document.createElement('a');
  link.href=URL.createObjectURL(blob);
  link.download=filename;
  document.body.appendChild(link);link.click();link.remove();
  URL.revokeObjectURL(link.href);
  systemBackupSetStatus('System backup downloaded ('+(blob.size/1048576).toFixed(1)+' MB).',false);
  toast('System backup downloaded');
 }catch(error){
  systemBackupSetStatus(error&&error.message?error.message:'System backup failed',true);
  toast(error&&error.message?error.message:'System backup failed',true);
 }
 if(btn){btn.disabled=false;btn.textContent='Export System Settings';}
}
function selectSystemSettingsImport(){
 const input=document.getElementById('systemSettingsImportFile');
 if(input)input.click();
}
async function importSystemSettingsFile(file){
 const input=document.getElementById('systemSettingsImportFile');
 if(!file)return;
 if(!/\.pgbackup$/i.test(String(file.name||''))){
  systemBackupSetStatus('Select a PGenerator+ .pgbackup file.',true);
  if(input)input.value='';
  return;
 }
 const accepted=confirm('Import this PGenerator+ system backup?\n\nMatching system settings, profiles and custom diagnostic media will be replaced. Existing history and media with different names will be preserved. A local rollback backup will be created first. Stop all measurements and calibration work before continuing.');
 if(!accepted){if(input)input.value='';return;}
 const btn=document.getElementById('importSystemSettingsBtn');
 if(btn){btn.disabled=true;btn.textContent='Importing...';}
 const chunkSize=512*1024;
 const uploadId='system_backup_'+Date.now().toString(36)+'_'+Math.random().toString(36).slice(2,10);
 let offset=0;
 try{
  while(offset<file.size){
   const end=Math.min(file.size,offset+chunkSize);
   const content=await diagBlobToBase64(file.slice(offset,end));
   const isFinal=end===file.size;
   systemBackupSetStatus('Uploading backup... '+Math.round(100*end/file.size)+'%',false);
   const response=await fetch('/api/system-backup/import',{
    method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({upload_id:uploadId,filename:file.name,offset:offset,total_size:file.size,is_final:isFinal,content:content})
   });
   const result=await response.json().catch(()=>null);
   if(!response.ok||!result||result.status!=='ok')throw new Error(result&&result.message?result.message:'System backup import failed');
   offset=end;
   if(isFinal){
    const count=Number(result.restored_files)||0;
    systemBackupSetStatus('Import complete. Restored '+count+' files. Reboot to apply all settings.',false);
    toast('System backup imported');
    if(confirm('System backup imported successfully. Reboot PGenerator+ now to apply all restored settings?')){
     const reboot=await fetchJSON('/api/reboot',{method:'POST'});
     if(!reboot||reboot.status!=='ok')throw new Error(reboot&&reboot.message?reboot.message:'Could not start reboot');
     systemBackupSetStatus('Rebooting PGenerator+...',false);
     systemBackupWaitForReboot();
    }
   }
  }
 }catch(error){
  systemBackupSetStatus(error&&error.message?error.message:'System backup import failed',true);
  toast(error&&error.message?error.message:'System backup import failed',true);
 }
 if(input)input.value='';
 if(btn){btn.disabled=false;btn.textContent='Import System Settings';}
}

///////////////////////////////////////////////
//        Meter & Measurements JS            //
///////////////////////////////////////////////
let meterDetected=false;
let meterStatusMisses=0;
let meterLastKnownName='Meter';
let meterInventory=[];
let meterMeasurementPort='';
let meterSavedMeasurementPort='';
let meterResolvedMeasurementPort='';
let meterProfilingPort='';
let meterContinuousActive=false;
let meterContinuousTimer=null;
let meterContinuousRetryDelayMs=50;
let meterContinuousStartupErrors=0;
let meterContinuousSuspendedForLgWrite=false;
let meterContinuousSuspendToken=0;
let meterContinuousReadInFlight=false;
let meterContinuousHadFirstRead=false;
let meterSeriesPolling=null;
const meterSeriesPollIntervalMs=500;
let meterSeriesPollInFlight=false;
let meterAutoCalRunning=false;
let meterAutoCalPolling=null;
let meterAutoCalPollInFlight=false;
let meterAutoCalPollErrors=0;
let meterAutoCalLatestStatus=null;
let meterLg3dAutoCalRunning=false;
let meterLg3dAutoCalPolling=null;
let meterLg3dAutoCalPollInFlight=false;
let meterLg3dAutoCalPollErrors=0;
let meterLg3dUploadRetryStatus=null;
let meterDvAutoCalProfileRunning=false;
// True while the DV panel-profile measurement is running as its own pass
// (AutoCal -> DV Config), i.e. NOT as the colour stage of a Full Auto Cal.
// The measure/upload chain is shared; only the entry, failure and completion
// handling differ.
let meterDvProfileStandaloneRunning=false;
let meterDvAutoCalProfilePolling=null;
let meterDvAutoCalProfilePollInFlight=false;
let meterDvAutoCalProfilePollErrors=0;
let meterDvMapModeTransitionPromise=null;
let meterDvMapModeTransitionTarget='';
let meterAutoCalWatchdogInFlight=false;
let meterFullAutoCalRunning=false;
let meterFullAutoCalPhase='';
let meterFullAutoCalConfig=null;
let meterFullAutoCalRunId=null;
let meterAutoCalRecordRunId=null;
let meterFullAutoCalControllerIdCache='';
let meterFullAutoCalStartedAt=null;
let meterFullAutoCalResults={first:null,lut3d:null,touchup:null};
let meterFullAutoCalReportData={pre:null,post:null,updated_at:null,run_id:null,started_at:null,pre_cal_skipped:null,stages:{},reset:null};
let meterFullAutoCalConfirmResolver=null;
let meterFullAutoCalConfirmOptions=null;
let meterAutoCalLuminanceSetupActive=false;
let meterAutoCalLuminanceContinue=false;
let meterAutoCalStopRequested=false;
let meterAutoCalPhase='';
let meterAutoCalPendingNextEntry='';
// True from LG Auto Cal wizard entry (after the availability gates verified
// a live TV connection) until the run is launched or the wizard closes.
// While set, meterGreyTvControlsActive() reports active even if the TV
// websocket bounces mid-wizard: the cached lgStatusState is not refreshed
// during calibration workflows, and a stale "disconnected" snapshot made
// the SDR26 step builder silently fall back to the 21-point LG list (and
// once to the stale YCbCr super-white set) for the worker payload/chart.
let meterAutoCalWizardContextActive=false;
let meterAutoCalPanelLight={key:'',value:null,label:'Panel light',pending:false,candidates:[]};
let meterAutoCalPanelLightReadPending=false;
let meterAutoCalPanelLightWritePending=false;
let meterAutoCalPanelLightQueuedDelta=0;
let meterAutoCalPanelLightQueuedValue=null;
let meterAutoCalPanelLightCommitTimer=null;
let meterAutoCalLuminanceReadBusy=false;
let meterAutoCalResetNotice='';
let meterAutoCalResetSkipped='';
let meterAutoCalPreflightResetDone=false;
let meterAutoCalPreflightLgGeneration=null;
let meterAutoCalResetInProgress=false;
let meterAutoCalSetupReading=null;
let meterAutoCalPendingConfig=null;
let meterAutoCalCapturedMeasurementPort='';
let meterAutoCalCapturedMeasurementLabel='';
let meterAutoCalCapturedTargetY=0;
let meterAutoCalLuminanceScaleMax=0;
let meterAutoCalLevelPreflight=null;
let meterHdrAutoCalChartContextHeld=false;
const METER_FULL_AUTOCAL_STATE_KEY='meterFullAutoCalState';
const METER_FULL_AUTOCAL_REPORT_KEY='meterFullAutoCalReportData';
const METER_FULL_AUTOCAL_COMPLETE_KEY='meterFullAutoCalCompleteToken';
const METER_FULL_AUTOCAL_TOUCHUP_DISABLED=true;
const METER_LG_HDR_CALMAN_RESET_ENDPOINT='/api/lg/hdr-calman-reset';
const METER_LG_DV_CALMAN_RESET_ENDPOINT='/api/lg/dv-calman-reset';
const METER_LG_SDR_CALMAN_RESET_ENDPOINT='/api/lg/sdr-calman-reset';
const METER_AUTOCAL_STATE_KEY='meterAutoCalState';
const METER_FULL_AUTOCAL_REPORT_SERIES=[
 {key:'greyscale-21',type:'greyscale',points:21,label:'Greyscale 21pt'},
 {key:'colors-30',type:'colors',points:30,label:'ColorChecker'},
 {key:'saturations-24',type:'saturations',points:24,label:'Sat Sweep'}
];
function meterFullAutoCalRunSignalMode(){
 const cfg=meterFullAutoCalConfig||null;
 const data=meterFullAutoCalReportData||((typeof meterFullAutoCalLoadReportData==='function')?meterFullAutoCalLoadReportData():null);
 return String((cfg&&cfg.signalMode)||(data&&data.signal_mode)||((typeof meterChartSignalMode==='function')?meterChartSignalMode():'sdr')||'sdr').toLowerCase();
}
function meterFullAutoCalReportSeries(){
 const greyscale={key:'greyscale-21',type:'greyscale',points:21,label:'Greyscale 21pt'};
 return [greyscale,{key:'colors-30',type:'colors',points:30,label:'ColorChecker'},{key:'saturations-24',type:'saturations',points:24,label:'Sat Sweep'}];
}
let meterActionPending=false;
let meterPingBusy=false;
let meterSeriesAwaitingReady=false;
let meterSeriesSpectroSetupActive=false;
let meterAutoCalSpectroSetupActive=false;
let meterLg3dAutoCalSpectroSetupActive=false;
let meterReadySignalPending=false;
let meterPendingDeviceReadyAction=null;
let meterManualPromptAwaiting=false;
let meterManualPromptReason='';
let meterManualPromptMessage='';
let meterManualPromptContinueResolver=null;
let meterCcssCreatePolling=null;
let meterCcssCreateHandledToken='';
let meterCcssCreateFreshOpen=true;
let meterCcssCreateInventoryReady=false;
let meterCcssCreateJobActive=false;
let meterCcssCreateFormat='ccss';
let meterCcssCreateMethod='measure';
let meterCcssCreateTargetPort='';
let meterCcssCreateJsonLoaded=false;
let meterReadings=[];
let meterWhiteReading=null;
let meterLastChartCount=0; // track reading count to skip redundant chart redraws
let meterLastChartSignature='';
let meterSeriesChartRevision=0;
let meterSeriesCache={};
let meterSeriesCacheBootId='';
let meterChromaticityLockedMode='';
let meterActiveHcfrSessionId=null;
let meterCcssCreateDisplayType='oled_generic';
let meterExportFilenameBases={};

// ArgyllCMS ccxxmake -t technologies. Labels intentionally omit redundant
// umbrella prefixes: the backend still writes canonical values such as
// "LED AMOLED" and "LCD White LED IPS" into CCSS/CCMX metadata.
const METER_ARGYLL_DISPLAY_TECHNOLOGY_GROUPS=[
 {label:'OLED and emissive',options:[
  ['oled','OLED'],['qdoled','QD-OLED'],['amoled','AMOLED'],['oled_generic','WOLED'],
  ['plasma','Plasma'],['crt','CRT']
 ]},
 {label:'LCD',options:[
  ['lcd','LCD'],
  ['lcd_ccfl','CCFL'],['lcd_ccfl_ips','CCFL IPS'],['lcd_ccfl_pva','CCFL PVA'],['lcd_ccfl_tft','CCFL TFT'],
  ['lcd_wgccfl','Wide Gamut CCFL'],['lcd_wgccfl_ips','Wide Gamut CCFL IPS'],['lcd_wgccfl_pva','Wide Gamut CCFL PVA'],['lcd_wgccfl_tft','Wide Gamut CCFL TFT'],
  ['lcd_wled','White LED'],['lcd_wled_ips','White LED IPS'],['lcd_wled_pva','White LED PVA'],['lcd_wled_tft','White LED TFT'],
  ['lcd_rgbled','RGB LED'],['lcd_rgbled_ips','RGB LED IPS'],['lcd_rgbled_pva','RGB LED PVA'],['lcd_rgbled_tft','RGB LED TFT'],
  ['lcd_rgphosphor','RG Phosphor'],['lcd_rgphosphor_ips','RG Phosphor IPS'],['lcd_rgphosphor_pva','RG Phosphor PVA'],['lcd_rgphosphor_tft','RG Phosphor TFT'],
  ['lcd_pfsphosphor','PFS Phosphor'],['lcd_pfsphosphor_ips','PFS Phosphor IPS'],['lcd_pfsphosphor_pva','PFS Phosphor PVA'],['lcd_pfsphosphor_tft','PFS Phosphor TFT'],
  ['lcd_gbled','GB-R Phosphor'],['lcd_gbled_ips','GB-R Phosphor IPS'],['lcd_gbled_pva','GB-R Phosphor PVA'],['lcd_gbled_tft','GB-R Phosphor TFT']
 ]},
 {label:'Projector',options:[
  ['projector_ccss','DLP Projector'],['projector_rgb','DLP Projector, RGB Filter Wheel'],
  ['projector_rgbw','DLP Projector, RGBW Filter Wheel'],['projector_rgbcmy','DLP Projector, RGBCMY Filter Wheel']
 ]},
 {label:'Other',options:[['unknown','Unknown']]}
];

function meterPopulateDisplayTechnologySelect(select,includeMeasurementModes){
 if(!select) return;
 const previous=String(select.value||'');
 select.innerHTML='';
 const addGroup=(label,options)=>{
  const group=document.createElement('optgroup');
  group.label=label;
  options.forEach(([value,text])=>{
   const option=document.createElement('option');
   option.value=value;
   option.textContent=text;
   group.appendChild(option);
  });
  select.appendChild(group);
 };
 if(includeMeasurementModes) addGroup('Measurement mode',[
  ['non_refresh','Non-refresh display'],['refresh','Refresh display']
 ]);
 METER_ARGYLL_DISPLAY_TECHNOLOGY_GROUPS.forEach(group=>addGroup(group.label,group.options));
 const fallback=select.id==='meterCcssCreateDisplayType'?meterCcssCreateDisplayType:'oled_generic';
 select.value=Array.from(select.options).some(option=>option.value===previous)?previous:fallback;
}

meterPopulateDisplayTechnologySelect(document.getElementById('meterDisplayType'),true);
meterPopulateDisplayTechnologySelect(document.getElementById('meterCcssCreateDisplayType'),false);

function meterSanitizeExportFilenameBase(value){
 let text=String(value==null?'':value).replace(/[<>:"/\\|?*\x00-\x1f]/g,' ').replace(/\s+/g,' ').trim();
 text=text.replace(/^\.+/,'').replace(/\.+$/,'');
 text=text.replace(/\.[A-Za-z0-9]{1,16}$/,'').trim();
 return text;
}

function meterPromptExportFilename(key,defaultBase,extension,promptLabel){
 const ext='.'+String(extension||'').replace(/^\./,'');
 const sessionBase=(key&&meterExportFilenameBases[key])?meterExportFilenameBases[key]:defaultBase;
 let entered=null;
 try{
  if(typeof window.prompt!=='function') return meterDefaultExportFilename(key,defaultBase,extension);
  entered=window.prompt(promptLabel||'Enter a file name',sessionBase);
 }catch(e){
  // Embedded browsers such as VS Code's webview expose prompt() but throw
  // when it is called. Export with a useful timestamped name instead.
  return meterDefaultExportFilename(key,defaultBase,extension);
 }
 if(entered==null) return null;
 const base=meterSanitizeExportFilenameBase(entered);
 if(!base){
  toast('File name required',true);
  return null;
 }
 if(key) meterExportFilenameBases[key]=base;
 return base+ext;
}

function meterDefaultExportFilename(key,defaultBase,extension){
 const ext='.'+String(extension||'').replace(/^\./,'');
 const sessionBase=meterSanitizeExportFilenameBase((key&&meterExportFilenameBases[key])?meterExportFilenameBases[key]:defaultBase)||defaultBase;
 const stamp=new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d+Z$/,'Z');
 if(key&&!meterExportFilenameBases[key]) meterExportFilenameBases[key]=sessionBase;
 return sessionBase+'_'+stamp+ext;
}

function meterDownloadBlob(blob,filename){
 const a=document.createElement('a');
 a.href=URL.createObjectURL(blob);
 a.download=filename;
 document.body.appendChild(a);
 a.click();
 a.remove();
 setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

function meterFilenameBase(filename){
 return String(filename||'').replace(/\.[^.]+$/,'');
}

function meterSeriesCacheKey(name){
 const scope=(meterSeriesCacheBootId&&String(meterSeriesCacheBootId).trim())?String(meterSeriesCacheBootId).trim():'global';
 return 'pgen.meter.'+scope+'.'+name;
}

function meterSeriesSnapshotIsCleared(snap){
 return !!(snap&&String(snap.status||'').toLowerCase()==='cleared');
}

function meterSeriesSnapshotHasReadings(snap){
 return !!(snap&&Array.isArray(snap.readings)&&snap.readings.some(rd=>meterReadingHasLuminance(rd)));
}

function meterSeriesSnapshotCanRestore(snap){
 if(!snap||typeof snap!=='object') return false;
 if(!meterSeriesSnapshotIsCleared(snap)&&meterSeriesSnapshotHasReadings(snap)) return true;
 const variants=(snap.mode_snapshots&&typeof snap.mode_snapshots==='object')?snap.mode_snapshots:{};
 return Object.values(variants).some(variant=>variant&&!meterSeriesSnapshotIsCleared(variant)&&meterSeriesSnapshotHasReadings(variant));
}

function meterSeriesSnapshotContainsIccWorkflow(snapshot){
 if(meterSeriesStatusIsIccWorkflow(snapshot)) return true;
 const variants=(snapshot&&snapshot.mode_snapshots&&typeof snapshot.mode_snapshots==='object')?snapshot.mode_snapshots:{};
 return Object.values(variants).some(variant=>meterSeriesStatusIsIccWorkflow(variant));
}

function meterSetSeriesCacheBootId(bootId){
 bootId=(bootId==null?'':String(bootId)).replace(/[^A-Za-z0-9_-]/g,'');
 if(!bootId){
  try{ bootId=localStorage.getItem('pgen.meter.seriesCache.bootId')||meterSeriesCacheBootId||'global'; }catch(e){ bootId=meterSeriesCacheBootId||'global'; }
 }
 if(meterSeriesCacheBootId===bootId) return;
 const priorBootId=meterSeriesCacheBootId;
 const memoryCache=(meterSeriesCache&&typeof meterSeriesCache==='object')?JSON.parse(JSON.stringify(meterSeriesCache)):{};
 meterSeriesCacheBootId=bootId;
 meterSeriesCache={};
 try{
  const markerKey='pgen.meter.seriesCache.bootId';
  const prev=localStorage.getItem(markerKey)||'';
  const scopedKey=(scope,name)=>'pgen.meter.'+(scope||'global')+'.'+name;
  const readCache=(key)=>{
   try{
    const raw=localStorage.getItem(key);
    if(!raw) return null;
    const parsed=JSON.parse(raw)||{};
    return (parsed&&typeof parsed==='object')?parsed:null;
   }catch(e){ return null; }
  };
  const mergeCache=(cache)=>{
   if(!cache||typeof cache!=='object') return;
   Object.entries(cache).forEach(([key,snap])=>{
    if(!snap||typeof snap!=='object') return;
    if(meterSeriesKeyIsIccWorkflow(key)||meterSeriesSnapshotContainsIccWorkflow(snap)) return;
    const incoming=[];
    const bare=meterSeriesSnapshotWithoutModeVariants(snap);
    if(bare) incoming.push(bare);
    if(snap.mode_snapshots&&typeof snap.mode_snapshots==='object') Object.values(snap.mode_snapshots).forEach(variant=>{if(variant&&typeof variant==='object') incoming.push(variant);});
    incoming.forEach(variant=>{
     const mode=meterSeriesSnapshotSignalMode(variant,'sdr');
     const existing=meterSeriesSnapshotForMode(meterSeriesCache[key],mode);
     if(!existing||Number(variant.updated_at||0)>=Number(existing.updated_at||0)) meterStoreSeriesSnapshot(key,variant);
    });
   });
  };
  mergeCache(readCache(scopedKey(bootId,'seriesCache')));
  if(prev&&prev!==bootId) mergeCache(readCache(scopedKey(prev,'seriesCache')));
  if(priorBootId&&priorBootId!==bootId&&priorBootId!==prev) mergeCache(readCache(scopedKey(priorBootId,'seriesCache')));
  mergeCache(readCache('pgen.meter.seriesCache'));
  mergeCache(memoryCache);
  localStorage.setItem(markerKey,bootId);
  if(Object.keys(meterSeriesCache).length>0){
   localStorage.setItem(meterSeriesCacheKey('seriesCache'),JSON.stringify(meterSeriesCache));
   const lastCandidates=[
    localStorage.getItem(scopedKey(bootId,'lastSeriesKey'))||'',
    prev?localStorage.getItem(scopedKey(prev,'lastSeriesKey'))||'':'',
    priorBootId?localStorage.getItem(scopedKey(priorBootId,'lastSeriesKey'))||'':'',
    localStorage.getItem('pgen.meter.lastSeriesKey')||''
   ].filter(key=>key&&!meterSeriesKeyIsIccWorkflow(key));
   let keepKey=lastCandidates.find(key=>meterSeriesSnapshotCanRestore(meterSeriesCache[key]));
   if(!keepKey){
    keepKey=Object.entries(meterSeriesCache)
     .filter(entry=>!meterSeriesKeyIsIccWorkflow(entry[0])&&meterSeriesSnapshotCanRestore(entry[1]))
     .sort((a,b)=>Number((b[1]&&b[1].updated_at)||0)-Number((a[1]&&a[1].updated_at)||0))
     .map(entry=>entry[0])[0]||'';
   }
   if(keepKey) localStorage.setItem(meterSeriesCacheKey('lastSeriesKey'),keepKey);
   else localStorage.removeItem(meterSeriesCacheKey('lastSeriesKey'));
  }
 }catch(e){}
}

function meterPersistSeriesCache(){
 if(!meterSeriesCacheBootId) return;
 try{
  localStorage.setItem(meterSeriesCacheKey('seriesCache'),JSON.stringify(meterSeriesCache||{}));
  const keepKey=(meterActiveSeriesKey&&meterSeriesSnapshotCanRestore(meterSeriesCache[meterActiveSeriesKey]))?meterActiveSeriesKey:'';
  if(keepKey) localStorage.setItem(meterSeriesCacheKey('lastSeriesKey'),keepKey);
  else {
   const prev=localStorage.getItem(meterSeriesCacheKey('lastSeriesKey'))||'';
   if(!prev || !meterSeriesSnapshotCanRestore(meterSeriesCache[prev])) localStorage.removeItem(meterSeriesCacheKey('lastSeriesKey'));
  }
 }catch(e){}
}

let meterSeriesCachePersistTimer=null;
function meterScheduleSeriesCachePersist(){
 if(meterSeriesCachePersistTimer) clearTimeout(meterSeriesCachePersistTimer);
 meterSeriesCachePersistTimer=setTimeout(()=>{
  meterSeriesCachePersistTimer=null;
  meterPersistSeriesCache();
 },0);
}

function meterLoadSeriesCache(){
 if(!meterSeriesCacheBootId) return;
 try{
  const raw=localStorage.getItem(meterSeriesCacheKey('seriesCache'));
  if(!raw) return;
  const parsed=JSON.parse(raw)||{};
  if(parsed&&typeof parsed==='object'){
   Object.keys(parsed).forEach(key=>{
    if(meterSeriesKeyIsIccWorkflow(key)||meterSeriesSnapshotContainsIccWorkflow(parsed[key])) delete parsed[key];
   });
   meterSeriesCache=parsed;
  }
 }catch(e){}
}

function meterParseSeriesKey(key){
 const match=String(key||'').match(/^([a-z]+)-(\d+)$/);
 if(!match) return null;
 return {type:match[1],points:Number(match[2])||0};
}

function meterSeriesKeyIsIccWorkflow(key){
 const parsed=meterParseSeriesKey(key);
 return !!(parsed&&Number(parsed.points)===990001);
}

function meterSeriesReadingIsImported(reading){
 return !!(reading&&(reading.source_format==='hcfr-chc'||reading.measurement_only===true));
}

function meterSeriesSnapshotIsImported(snapshot){
 if(!snapshot||typeof snapshot!=='object') return false;
 if(snapshot.source_format==='hcfr-chc'||snapshot.measurement_only===true) return true;
 const readings=Array.isArray(snapshot.readings)?snapshot.readings:[];
 return readings.length>0&&readings.every(meterSeriesReadingIsImported);
}

function meterSeriesKeyIsNativePreset(key){
 return /^(?:greyscale-(?:2|11|21|26|30|100|101|256)|colors-(?:29|30)|saturations-(?:24|25))$/.test(String(key||''));
}

function meterSeriesSnapshotSignalMode(snapshot,fallbackMode){
 const mode=String((snapshot&&snapshot.signal_mode)||fallbackMode||'sdr').toLowerCase();
 return mode||'sdr';
}

function meterSeriesSnapshotWithoutModeVariants(snapshot){
 if(!snapshot||typeof snapshot!=='object') return null;
 const bare={...snapshot};
 delete bare.mode_snapshots;
 return bare;
}

function meterSeriesSnapshotForMode(snapshot,signalMode){
 if(!snapshot||typeof snapshot!=='object') return null;
 const mode=String(signalMode||'sdr').toLowerCase()||'sdr';
 const variants=(snapshot.mode_snapshots&&typeof snapshot.mode_snapshots==='object')?snapshot.mode_snapshots:null;
 if(variants&&variants[mode]&&typeof variants[mode]==='object') return variants[mode];
 return meterSeriesSnapshotSignalMode(snapshot,mode)===mode?meterSeriesSnapshotWithoutModeVariants(snapshot):null;
}

function meterStoreSeriesSnapshot(key,snapshot){
 if(!key||!snapshot||typeof snapshot!=='object') return;
 const bare=meterSeriesSnapshotWithoutModeVariants(snapshot);
 const mode=meterSeriesSnapshotSignalMode(bare,'sdr');
 const current=meterSeriesCache&&meterSeriesCache[key];
 const variants=(current&&current.mode_snapshots&&typeof current.mode_snapshots==='object')
  ? JSON.parse(JSON.stringify(current.mode_snapshots))
  : {};
 if(current){
  const prior=meterSeriesSnapshotWithoutModeVariants(current);
  const priorMode=meterSeriesSnapshotSignalMode(prior,'sdr');
  if(!variants[priorMode]||Number(prior.updated_at||0)>=Number(variants[priorMode].updated_at||0)) variants[priorMode]=prior;
 }
 variants[mode]=bare;
 meterSeriesCache[key]={...bare,mode_snapshots:variants};
}

function meterGreyscaleReadingMatchesStep(reading,step){
 if(!reading||!step) return false;
 const samePoint=(step.ire!=null&&reading.ire!=null&&Number(step.ire)===Number(reading.ire));
 const stepName=String(step.name||'');
 const readingName=String(reading.name||'');
 const sameName=stepName!==''&&stepName===readingName;
 if(!samePoint&&!sameName) return false;
 return meterReadingMatchesStepForPlot(reading,step);
}

// Normalised full-scale tolerance for "is this reading the same patch as this
// step". Sized from what it must separate:
//   - ACCEPT: the same nominal level expressed on two slightly different
//     ladders. The worst legitimate disagreement is ~3/1023 = 0.29% of full
//     scale (integer rounding between code maps at the same bit depth).
//   - REJECT: the same nominal level driven at a genuinely different SIGNAL,
//     which is what this check exists to catch. Limited vs Full at the same
//     IRE are furthest apart in the upper mid-range and are still ~1.0% apart
//     (50%: 502/1023=0.4907 vs 512/1023=0.5005), widening to 8% at 100% and
//     6% at 0%. 0.4% keeps a >2x margin on the tightest case.
const METER_CODE_MATCH_TOLERANCE=0.004;
function meterCodeInputMaxFor(obj,fallback){
 const im=Number(obj&&obj.input_max);
 if(Number.isFinite(im)&&im>0) return im;
 return fallback;
}
function meterReadingCodesMatchStep(reading,step){
 if(!reading||!step) return false;
 // Compare NORMALISED level, not raw integers. A reading carries the codes the
 // server actually drove (stamped with their own input_max); the step carries
 // the codes the client rebuilt. Those can legitimately be on different scales
 // -- 8-bit vs 10-bit, or two code maps at the same depth -- and a raw integer
 // compare turns any such difference into a total mismatch. Normalising means
 // a scale difference no longer masquerades as a different patch.
 const defaultMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
 const readingMax=meterCodeInputMaxFor(reading,defaultMax);
 const stepMax=meterCodeInputMaxFor(step,defaultMax);
 const pairs=[['r_code','r'],['g_code','g'],['b_code','b']];
 for(const pair of pairs){
  const rv=reading[pair[0]];
  const sv=step[pair[1]];
  if(rv==null||sv==null) continue;
  const rn=Number(rv);
  const sn=Number(sv);
  if(!Number.isFinite(rn)||!Number.isFinite(sn)) continue;
  if(Math.abs(rn-sn)<=0.5) continue;              // identical on a shared scale
  if(!(readingMax>0)||!(stepMax>0)) return false;
  if(Math.abs((rn/readingMax)-(sn/stepMax))>METER_CODE_MATCH_TOLERANCE) return false;
 }
 return true;
}

function meterReadingNominalSlotMatchesStep(reading,step){
 if(!reading||!step) return false;
 const stepName=String(step.name||'');
 const readingName=String(reading.name||'');
 if(stepName!==''&&readingName!==''&&stepName===readingName) return true;
 const si=Number(step.ire);
 if(!Number.isFinite(si)) return false;
 const candidates=[reading.plot_ire,reading.nominal_ire,reading.slot_ire,reading.ire];
 return candidates.some(value=>{
  const ri=Number(value);
  return Number.isFinite(ri)&&Math.abs(ri-si)<0.001;
 });
}

function meterReadingUsesAlternateStimulus(reading,step){
 if(!meterReadingNominalSlotMatchesStep(reading,step)) return false;
 const stepStim=Number(step.stimulus!=null?step.stimulus:step.ire);
 const readingStim=Number(reading.stimulus);
 if(Number.isFinite(stepStim)&&Number.isFinite(readingStim)&&Math.abs(readingStim-stepStim)>0.05) return true;
 const pairs=[
  ['signal_r_pct','signal_r_pct'],
  ['signal_g_pct','signal_g_pct'],
  ['signal_b_pct','signal_b_pct']
 ];
 for(const pair of pairs){
  const rv=Number(reading[pair[0]]);
  const sv=Number(step[pair[1]]!=null?step[pair[1]]:step.stimulus!=null?step.stimulus:step.ire);
  if(Number.isFinite(rv)&&Number.isFinite(sv)&&Math.abs(rv-sv)>0.05) return true;
 }
 return !!reading.autocal_probe_stimulus;
}

function meterDvAbsoluteWhiteRefreshMatchesStep(reading,step){
 if(!reading||!step) return false;
 if(!meterReadingNominalSlotMatchesStep(reading,step)) return false;
 if(!meterReadingIsGreyscale(reading)) return false;
 const stepSeries=String(step.series_type||'').toLowerCase();
 const readingSeries=String(reading.series_type||'').toLowerCase();
 if((stepSeries&&stepSeries!=='greyscale')||(readingSeries&&readingSeries!=='greyscale')) return false;
 const ire=Number(step.ire!=null?step.ire:reading.ire);
 if(!Number.isFinite(ire)||Math.abs(ire-100)>0.001) return false;
 if(!(reading.final_white_refresh||step.final_white_refresh)) return false;
 const activeSignal=(typeof meterActiveSeriesSignalMode!=='undefined')?meterActiveSeriesSignalMode:'';
 const activeDvMap=(typeof meterActiveSeriesDvMapMode!=='undefined')?meterActiveSeriesDvMapMode:'';
 const signal=String(reading.signal_mode||step.signal_mode||activeSignal||'').toLowerCase();
 const dvMap=String(reading.dv_map_mode||step.dv_map_mode||activeDvMap||'');
 return signal==='dv'&&(dvMap==='1'||reading.dv_absolute_st2084_precomp||step.dv_absolute_st2084_precomp);
}

function meterReadingMatchesStepForPlot(reading,step){
 if(!reading||!step) return false;
 if(meterReadingCodesMatchStep(reading,step)) return true;
 if(meterDvAbsoluteWhiteRefreshMatchesStep(reading,step)) return true;
 return meterReadingUsesAlternateStimulus(reading,step);
}

function meterReadingPlotIre(reading){
 if(!reading) return null;
 const candidates=[reading.plot_ire,reading.nominal_ire,reading.slot_ire,reading.ire];
 for(const value of candidates){
  const ire=Number(value);
  if(Number.isFinite(ire)) return ire;
 }
 return null;
}

function meterReadingAnalysisIre(reading){
 if(!reading) return null;
 const candidates=[reading.analysis_ire,reading.target_ire,reading.patch_stimulus,reading.stimulus,reading.patch_ire,reading.signal_r_pct,reading.plot_ire,reading.nominal_ire,reading.ire];
 for(const value of candidates){
  const ire=Number(value);
  if(Number.isFinite(ire)) return ire;
 }
 return null;
}

function meterReadingGammaAnalysisIre(reading){
 if(!reading) return null;
 if(meterReadingIsGreyscale(reading)&&(meterChartIsDv()||meterChartIsHdr()||meterChartIsHlg())){
  const analysis=meterReadingAnalysisIre(reading);
  // Honor an explicit analysis_ire / target_ire stamp on the reading so
  // the chart's measured gamma uses the same signal basis the worker
  // stamped into target_Yn. Without this gate the helper falls through
  // to meterGreySignalFractionFromCode(r_code), which produces a
  // code-derived signal that can differ noticeably from the slot value
  // (e.g. 0.01826 vs 0.020 for code 80 in 10-bit Limited at slot 2.0%)
  // and makes a near-converged reading plot visibly below the gamma
  // target line. DV is treated explicitly above; for HDR/HLG, the HDR20
  // makeHdrStep path stamps analysis_ire / target_ire from the slot
  // value, mirroring the LG 22pt manual greyscale pattern.
  if(analysis!=null && (meterChartIsDv() || reading.analysis_ire!=null || reading.target_ire!=null)) return analysis;
  const code=reading.r_code!=null?reading.r_code:reading.r;
  if(code!=null){
   const signal=meterGreySignalFractionFromCode(code);
   if(Number.isFinite(signal)) return signal*100;
  }
  if(analysis!=null) return analysis;
 }
 return meterReadingAnalysisIre(reading);
}

function meterGreyChartStimulusIre(item){
 if(!item) return null;
 const candidates=[item.analysis_ire,item.target_ire,item.patch_stimulus,item.stimulus,item.patch_ire,item.signal_g_pct,item.signal_r_pct,item.plot_ire,item.nominal_ire,item.ire];
 for(const value of candidates){
  const ire=Number(value);
  if(Number.isFinite(ire)) return ire;
 }
 return null;
}

function meterGreyChartPlotIre(item){
 if(!item) return null;
 const candidates=[item.plot_ire,item.nominal_ire,item.slot_ire,item.ire,item.stimulus];
 for(const value of candidates){
  const ire=Number(value);
  if(Number.isFinite(ire)) return ire;
 }
 return null;
}

// Target-slot IRE resolver for the greyscale TARGET math (target Y, chart
// target lines, RGB-balance target). Custom greyscale must only change which
// patch code is sent (stimulus / signal_*_pct / the r/g/b codes), NOT the
// target. So for the user-facing custom-greyscale series the target follows the
// NOMINAL slot IRE (plot_ire/nominal_ire/slot_ire/ire), not the custom stimulus.
// Two intentionally-stimulus-derived paths keep their old behaviour:
//   - LG 22pt manual greyscale stamps analysis_ire/target_ire from the decoded
//     legal stimulus (its target must track what the TV's menu slot decodes to).
//   - LG AutoCal 26pt headroom (105/109%) derives the target from the code.
// Both are detected by an explicit analysis_ire/target_ire stamp, so when either
// is present we delegate to meterGreyChartStimulusIre (unchanged). For plain
// and custom greyscale neither is stamped, so we fall through to the slot IRE.
function meterGreyscaleTargetSlotIre(item){
 if(!item) return null;
 if(item.analysis_ire!=null||item.target_ire!=null) return meterGreyChartStimulusIre(item);
 const candidates=[item.plot_ire,item.nominal_ire,item.slot_ire,item.ire];
 for(const value of candidates){
  const ire=Number(value);
  if(Number.isFinite(ire)) return ire;
 }
 return meterGreyChartStimulusIre(item);
}

// Runtime gate for the user-facing custom greyscale feature (the per-point
// stimulus table edited via "Edit Values"). When active, the target must NOT
// move with the custom stimulus/code -- it stays anchored to the nominal slot
// IRE. Excludes LG 22pt manual greyscale (METER_LG_GREY_MANUAL_22_ENABLED is
// false) and LG AutoCal 26pt headroom, whose targets are intentionally
// stimulus/code-derived.
function meterGreyscaleCustomTargetActive(){
 if(typeof meterActiveSeriesType==='undefined'||meterActiveSeriesType!=='greyscale') return false;
 const useLg21=(typeof meterUseLgGreyscale21==='function')&&meterUseLgGreyscale21(meterActiveSeriesPoints);
 const useLg26=(typeof meterUseLgAutoCal26==='function')&&meterUseLgAutoCal26(meterActiveSeriesPoints);
 if(useLg21||useLg26) return false;
 return (typeof meterGreyCustomEnabled==='function')&&meterGreyCustomEnabled();
}

function meterGreyscaleTargetIreForStep(step,readingMap){
 if(!step) return 0;
 const rd=(readingMap&&step.ire!=null)?readingMap[step.ire]:null;
 const ire=(typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(rd||step):null;
 return ire!=null?ire:(step.ire||0);
}

function meterGreyscaleTargetCodeForStep(step,readingMap){
 const rd=(readingMap&&step&&step.ire!=null)?readingMap[step.ire]:null;
 if(rd&&rd.r_code!=null) return rd.r_code;
 if(step&&step.r_code!=null) return step.r_code;
 return step?step.r:null;
}

function meterRecoveredStepsMatchSeries(a,b){
 if(!Array.isArray(a)||!Array.isArray(b)||a.length!==b.length) return false;
 for(let i=0;i<a.length;i++){
  const ak=meterStepNameKey(a[i])||String((a[i]&&a[i].name)||'');
  const bk=meterStepNameKey(b[i])||String((b[i]&&b[i].name)||'');
  if(ak!==bk) return false;
 }
 return true;
}

function meterRecoveredStepsDifferInCodes(a,b){
 if(!Array.isArray(a)||!Array.isArray(b)||a.length!==b.length) return true;
 for(let i=0;i<a.length;i++){
  if(!meterReadingCodesMatchStep({r_code:a[i].r,g_code:a[i].g,b_code:a[i].b},b[i])) return true;
 }
 return false;
}

function meterCanonicalRecoveredSteps(type,points,steps,status){
	 const existing=Array.isArray(steps)?steps:[];
	 // Lattice series: server-shaped steps carry no chart targets (the server
	 // expansion computes none). The client expansion is name-identical
	 // (parity-locked) and stamps target_x/y/Yn — always prefer it so target
	 // resolution never falls back to the raw absolute stimulus decode.
	 try{
	  const latSeries=(typeof meterCustomSeriesById==='function')?meterCustomSeriesById(points):null;
	  if(latSeries&&latSeries.kind==='lattice'){
	   const freshLat=meterBuildStepsJS(type,points);
	   if(Array.isArray(freshLat)&&freshLat.length&&(existing.length===0||freshLat.length===existing.length)) return freshLat;
	  }
	 }catch(e){}
	 // Custom series: a snapshot can hold a PARTIAL patch list. Reading a
	 // sub-range of a custom series replaces meterSeriesSteps with just that
	 // range, and meterCacheSeriesState then persists the short list -- its
	 // anti-downgrade guard only fires when the step COUNT matches, so the full
	 // ladder is lost. After a restart or OTA the series NAME is right but only
	 // the sub-range renders, and it becomes the active series
	 // (operator-reported). Rebuild from the series definition whenever the
	 // snapshot is a strict SUBSET of it. A definition that legitimately shrank
	 // produces a shorter fresh list, which fails the length test, so an edited
	 // series still wins. This runs on every restore path, including boot
	 // recovery, which is the one that has no freshly built steps to compare.
	 try{
	  const customSeries=(typeof meterCustomSeriesById==='function')?meterCustomSeriesById(points):null;
	  if(customSeries&&existing.length){
	   const freshCustom=meterBuildStepsJS(type,points);
	   if(Array.isArray(freshCustom)&&freshCustom.length===existing.length&&meterRecoveredStepsMatchSeries(existing,freshCustom)){
	    const targetChanged=existing.some((step,idx)=>{
	     const fresh=freshCustom[idx]||{};
	     return ['target_x','target_y','target_Yn'].some(field=>{
	      const a=Number(step&&step[field]),b=Number(fresh[field]);
	      if(!Number.isFinite(a)&&!Number.isFinite(b)) return false;
	      if(!Number.isFinite(a)||!Number.isFinite(b)) return true;
	      return Math.abs(a-b)>0.000001;
	     });
	    });
	    // Target math is derived, not measured state. Refresh it after an
	    // importer/container fix while the cached readings remain attached to
	    // their name-identical patch steps.
	    if(targetChanged) return freshCustom;
	   }
	   if(Array.isArray(freshCustom)&&freshCustom.length>existing.length){
	    const freshKeys=new Set(freshCustom.map(s=>meterStepNameKey(s)||String((s&&s.name)||'')));
	    const isSubset=existing.every(s=>freshKeys.has(meterStepNameKey(s)||String((s&&s.name)||'')));
	    if(isSubset){
	     try{ console.info('Series cache: rebuilt full ladder over a partial snapshot',{points:points,cached:existing.length,full:freshCustom.length}); }catch(e){}
	     return freshCustom;
	    }
	   }
	  }
	 }catch(e){}
	 if(type!=='greyscale'||String(status||'')==='running') return existing;
	 if(!(meterUseLgGreyscale21(points)||meterUseLgAutoCal26(points))) return existing;
	 const fresh=meterBuildStepsJS(type,points);
 if(!Array.isArray(fresh)||fresh.length===0) return existing;
 if(existing.length===0) return fresh;
 if(!meterRecoveredStepsMatchSeries(existing,fresh)) return existing;
 return meterRecoveredStepsDifferInCodes(existing,fresh)?fresh:existing;
}

function meterFilterReadingsForCurrentSteps(readings,type){
 const list=Array.isArray(readings)?readings:[];
 if(!Array.isArray(meterSeriesSteps)||!meterSeriesSteps.length) return list;
 // Greyscale and colour/sat: drop leftovers from a previous series (e.g.
 // ColorChecker dots still plotting after loading a custom grid).
 if(type==='greyscale') return meterFilterReadingsForSteps(list,type,meterSeriesSteps,{dropStaleBlackOnly:true});
 if(type==='colors'||type==='saturations') return meterFilterReadingsForSteps(list,type,meterSeriesSteps);
 return list;
}

function meterColorReadingMatchesStep(reading,step){
 if(!reading||!step) return false;
 const rk=meterStepNameKey(reading), sk=meterStepNameKey(step);
 if(rk&&sk&&rk===sk) return true;
 const rn=String(reading.name||''), sn=String(step.name||'');
 return !!(rn&&sn&&rn===sn);
}

function meterReadingMatchesStepList(reading,type,steps){
 if(!Array.isArray(steps)||!steps.length) return true;
 if(type==='greyscale') return steps.some(step=>meterGreyscaleReadingMatchesStep(reading,step));
 if(type==='colors'||type==='saturations') return steps.some(step=>meterColorReadingMatchesStep(reading,step));
 return true;
}

function meterReadingIsBlackStep(reading){
 if(!reading) return false;
 const ire=Number(reading.ire);
 if(Number.isFinite(ire)) return Math.abs(ire)<=0.05;
 const name=String(reading.name||'').trim().toLowerCase();
 return name==='0%'||name==='black';
}

function meterReadingsWouldRecoverAsBlackOnly(readings,type,steps){
 if(type!=='greyscale'||!Array.isArray(steps)||!steps.length) return false;
 const list=(Array.isArray(readings)?readings:[]).filter(rd=>meterReadingHasLuminance(rd));
 if(!list.length) return false;
 const matched=list.filter(rd=>meterReadingMatchesStepList(rd,type,steps));
 const mismatched=list.filter(rd=>!meterReadingMatchesStepList(rd,type,steps));
 if(!matched.length||!mismatched.length) return false;
 const hadNonBlack=list.some(rd=>!meterReadingIsBlackStep(rd));
 const matchedNonBlack=matched.some(rd=>!meterReadingIsBlackStep(rd));
 return hadNonBlack&&!matchedNonBlack;
}

// A measurement must never be discarded silently.
//
// What this filter is FOR: dropping leftovers from a PREVIOUS series so they
// are not attributed to the current one (e.g. ColorChecker dots still plotting
// after loading a custom grid, or a status poll that caught the state file
// before the new run overwrote it). Those leftovers belong to different
// patches -- different names, different nominal slots -- and are still dropped.
//
// What it must NOT do: delete a reading that IS one of the current patches
// merely because the two sides computed its drive code slightly differently.
// That is a presentation-layer disagreement, not evidence the meter measured
// the wrong thing, and deleting the measurement is the worst available
// response -- the operator sees "no reading" mid-calibration with no clue that
// real data was thrown away. A code disagreement now KEEPS the reading, tags
// it, and is reported.
let _meterCodeMismatchNotified='';
function meterNoteCodeMismatch(mismatched,type){
 if(!mismatched.length) return;
 const key=String(type||'')+'|'+(typeof meterActiveSeriesKey!=='undefined'?meterActiveSeriesKey:'')+'|'+mismatched.length;
 if(_meterCodeMismatchNotified===key) return;
 _meterCodeMismatchNotified=key;
 const detail=mismatched.slice(0,12).map(rd=>{
  const label=(rd&&rd.name!=null&&String(rd.name)!=='')?String(rd.name):(rd&&rd.ire!=null?rd.ire+'%':'?');
  return label+' (r_code='+(rd&&rd.r_code!=null?rd.r_code:'?')+')';
 }).join(', ');
 try{
  console.warn('Series reading/step drive codes disagree for '+mismatched.length+' patch(es); '
   +'the measurements were KEPT and plotted against their nominal slot. '
   +'This means the client and server code ladders are out of step: '+detail);
 }catch(e){}
 try{ toast(mismatched.length+' patch(es) measured at a different drive code than expected - kept, but check the bit depth/range settings',true); }catch(e){}
}
function meterFilterReadingsForSteps(readings,type,steps,options){
 const list=Array.isArray(readings)?readings:[];
 if(!Array.isArray(steps)||!steps.length) return list;
 if(type==='greyscale'){
  if(options&&options.dropStaleBlackOnly&&meterReadingsWouldRecoverAsBlackOnly(list,type,steps)) return [];
  const kept=[]; const mismatched=[];
  list.forEach(rd=>{
   if(meterReadingMatchesStepList(rd,type,steps)){ kept.push(rd); return; }
   // Same patch by nominal slot (name or IRE), rejected only on drive code:
   // keep it rather than lose a real measurement.
   if(steps.some(step=>meterReadingNominalSlotMatchesStep(rd,step))){
    if(rd&&typeof rd==='object') rd.code_mismatch=true;
    kept.push(rd);
    if(meterReadingHasLuminance(rd)) mismatched.push(rd);
    return;
   }
   // Belongs to no current patch at all -> genuine leftover, drop it.
  });
  meterNoteCodeMismatch(mismatched,type);
  return kept;
 }
 if(type==='colors'||type==='saturations'){
  // Colour/sat matching is already name-based (meterColorReadingMatchesStep),
  // so a code disagreement cannot delete a measurement here.
  return list.filter(rd=>meterReadingMatchesStepList(rd,type,steps));
 }
 return list;
}

// True only for a real meter sample. Series steps, target-only placeholders, and
// synthetic whites must never count — otherwise unread nodes show fabricated
// "Measured" values (from codes, stale series, or target_Y mistaken for Y).
function meterReadingIsRealMeasurement(rd){
 if(!rd||typeof rd!=='object') return false;
 if(rd._unreadStep||rd._presetStep||rd.synthetic_target) return false;
 // Instrument path always leaves raw_* (or CIE xy + luminance) from a read.
 if(rd.raw_Y!=null||rd.raw_luminance!=null||rd.raw_X!=null||rd.raw_Z!=null) return true;
 if(rd.raw_x!=null&&rd.raw_y!=null) return true;
 const hasXY=rd.x!=null&&rd.y!=null&&Number(rd.x)>0&&Number(rd.y)>0;
 const hasLum=(rd.luminance!=null&&Number(rd.luminance)>=0)||(rd.Y!=null&&Number(rd.Y)>=0);
 // Require both chroma + luminance so a step shell with only codes never passes.
 if(hasXY&&hasLum) return true;
 // Absolute XYZ from the meter (not target_X/Y/Z alone).
 if(rd.X!=null&&rd.Y!=null&&rd.Z!=null&&hasLum&&(rd.x!=null||rd.raw_Y!=null)) return true;
 return false;
}

// Detail/live context for an unread colour patch: targets only, no measured fields.
// Intentionally omits x/y/X/Y/Z/luminance so nothing can treat it as a sample.
function meterColorUnreadDetailFromStep(step){
 if(!step) return null;
 return {
  name:step.name,ire:step.ire,
  r:step.r,g:step.g,b:step.b,
  r_code:(step.r_code!=null?step.r_code:step.r),
  g_code:(step.g_code!=null?step.g_code:step.g),
  b_code:(step.b_code!=null?step.b_code:step.b),
  target_x:step.target_x,target_y:step.target_y,target_Yn:step.target_Yn,
  custom_target_nits:step.custom_target_nits,
  signal_r_pct:step.signal_r_pct,signal_g_pct:step.signal_g_pct,signal_b_pct:step.signal_b_pct,
  series_color:step.series_color,sat_pct:step.sat_pct,
  _unreadStep:true
 };
}

function meterResolveSeriesSnapshotFromCache(key,options){
 if((!meterSeriesCache||Object.keys(meterSeriesCache).length===0) && key) meterLoadSeriesCache();
 // Deep-clone while stripping volatile per-reading analysis caches. The
 // cached readings carry _dE_raw/_dE_lc/_dE_cache_key/_gamma_rgb computed
 // against the chart context (white reference / target black / target
 // gamma / max_luma) that was live at cache time. If those are left on the
 // restored readings, meterEnsureDeltaECache can reuse stale ΔE values
 // (or a matching key can short-circuit a recompute) whenever the live
 // context differs after restore — e.g. switching back to the greyscale
 // series after an HDR AutoCal. Stripping forces a fresh compute against
 // the restored context, matching meterRefreshActiveSeriesCharts.
 const clone=(value)=>{
  const out=JSON.parse(JSON.stringify(value));
  if(Array.isArray(out)) out.forEach(rd=>{ if(rd&&typeof rd==='object'){ delete rd._dE_raw; delete rd._dE_lc; delete rd._dE_cache_key; delete rd._gamma_rgb; } });
  return out;
 };
 const opts=options||{};
 let rawExact=(meterSeriesCache&&meterSeriesCache[key])?meterSeriesCache[key]:null;
 if(rawExact&&meterSeriesSnapshotContainsIccWorkflow(rawExact)){
  delete meterSeriesCache[key];
  rawExact=null;
  meterScheduleSeriesCachePersist();
 }
 const requestedMode=String((opts.signalMode!=null)?opts.signalMode:(meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase()||'sdr';
 let exact=meterSeriesSnapshotForMode(rawExact,requestedMode);
 // CHC imports are measurement-only workspaces. Older builds allowed their
 // readings to be merged into a native preset with the same IRE labels, then
 // persisted that mixture under e.g. greyscale-21 during boot recovery. Strip
 // those imported readings when resolving a native preset so its patch steps,
 // thumbnails, and measurements cannot become cross-wired after a restart.
 if(exact&&meterSeriesKeyIsNativePreset(key)&&Array.isArray(exact.readings)&&exact.readings.some(meterSeriesReadingIsImported)){
  const nativeReadings=exact.readings.filter(rd=>!meterSeriesReadingIsImported(rd));
  exact={...exact,readings:nativeReadings};
  if(exact.white_reading&&meterSeriesReadingIsImported(exact.white_reading)) exact.white_reading=null;
 }
 const parsed=meterParseSeriesKey(key)||null;
 const type=opts.type||((parsed&&parsed.type)?parsed.type:'')||(exact&&exact.type)||(rawExact&&rawExact.type)||'greyscale';
 const points=opts.points||((parsed&&parsed.points)?parsed.points:0)||(exact&&exact.points)||(rawExact&&rawExact.points)||21;
 // The eligibility gate must compare the snapshot's mode against the LIVE
 // (requested) chart mode — resolving signalMode from the snapshot first and
 // then comparing the snapshot against it was a tautology (always true), so
 // e.g. an SDR-cached cube snapshot restored into an HDR10 session and
 // stamped signal_mode 'sdr' onto the active series, silently collapsing the
 // whole PQ pipeline (BT.2390 control, PQ target decode, chart law).
 const signalMode=meterSeriesSnapshotSignalMode(exact,requestedMode);
 if(exact&&meterSeriesSnapshotIsCleared(exact)&&meterSeriesSnapshotSignalMode(exact,requestedMode)===requestedMode) return null;
 let steps=clone((Array.isArray(opts.steps)&&opts.steps.length)?opts.steps:((exact&&Array.isArray(exact.steps)&&exact.steps.length)?exact.steps:meterBuildStepsJS(type,points)));
 steps=meterCanonicalRecoveredSteps(type,points,steps,(exact&&exact.status)||'complete');
 const requestedLg26=type==='greyscale'&&(Number(points)===26||meterSeriesStepsHaveLgAutoCal26Markers(steps));
 const exactEligible=exact&&Array.isArray(exact.readings)&&exact.readings.length>0&&meterSeriesSnapshotSignalMode(exact,requestedMode)===requestedMode&&(requestedLg26===(meterSeriesSnapshotHasLgAutoCal26Markers(exact)||Number((exact&&exact.points)||0)===26))?exact:null;
 if(type!=='greyscale'){
  if(!exactEligible) return null;
	  return {
	   type:type,
	   points:points,
	   source_format:exactEligible.source_format||null,
	   signal_mode:signalMode,
	   target_gamma:exactEligible.target_gamma||null,
	   max_luma:exactEligible.max_luma||null,
	   dv_map_mode:exactEligible.dv_map_mode||null,
	   observer_readings:clone(exactEligible.observer_readings||{}),
	   steps:steps,
	   readings:clone((exactEligible.readings||[]).filter(rd=>meterReadingHasLuminance(rd))),
	   white_reading:exactEligible.white_reading?clone(exactEligible.white_reading):null,
	   black_reading:exactEligible.black_reading?clone(exactEligible.black_reading):null,
	   status:exactEligible.status||'complete'
	  };
 }
 const candidates=[];
 if(exactEligible) candidates.push({snap:exactEligible,exact:true});
 if(meterSeriesCache&&typeof meterSeriesCache==='object'){
  Object.entries(meterSeriesCache).forEach(([cacheKey,rootSnap])=>{
   if(cacheKey===key) return;
   if(meterSeriesSnapshotContainsIccWorkflow(rootSnap)) return;
   const meta=meterParseSeriesKey(cacheKey);
   if(!meta||meta.type!=='greyscale') return;
   const snap=meterSeriesSnapshotForMode(rootSnap,signalMode);
   if(!snap||!Array.isArray(snap.readings)||snap.readings.length===0) return;
   // Imported CHC workspaces must remain selectable as their own snapshot, but
   // must never act as fallback measurements for native point-count presets.
   if(meterSeriesSnapshotIsImported(snap)) return;
   if(meterSeriesSnapshotSignalMode(snap,signalMode)!==signalMode) return;
   const snapshotLg26=meta.points===26||meterSeriesSnapshotHasLgAutoCal26Markers(snap);
   if(snapshotLg26!==requestedLg26) return;
   candidates.push({snap:snap,exact:false});
  });
 }
 if(candidates.length===0) return null;
 candidates.sort((a,b)=>{
  if(a.exact!==b.exact) return a.exact?-1:1;
  return Number(b.snap.updated_at||0)-Number(a.snap.updated_at||0);
 });
 const mergedReadings=[];
 steps.forEach(step=>{
  for(const candidate of candidates){
	  const source=(candidate.snap.readings||[]).find(rd=>meterReadingHasLuminance(rd)&&meterGreyscaleReadingMatchesStep(rd,step));
	   if(!source) continue;
	   const reading=clone(source);
	   meterStampReadingStepMeta(reading,step);
   meterNormalizeMeasuredReading(reading);
   mergedReadings.push(reading);
   break;
  }
 });
 if(mergedReadings.length===0) return null;
	 if(!mergedReadings.some(rd=>!meterReadingIsBlackStep(rd))&&candidates.some(candidate=>meterReadingsWouldRecoverAsBlackOnly(candidate.snap.readings,type,steps))) return null;
	 const contextSnap=exactEligible||((candidates[0]&&candidates[0].snap)?candidates[0].snap:{});
		 let white=null;
		 const mergedWhite=meterFindSeriesWhiteReading(mergedReadings);
	 if(mergedWhite) white=clone(mergedWhite);
	 if(!white&&exactEligible&&exactEligible.white_reading&&meterReadingHasLuminance(exactEligible.white_reading)&&meterReadingMatchesStepList(exactEligible.white_reading,type,steps)) white=clone(exactEligible.white_reading);
	 if(!white){
	  for(const candidate of candidates){
	   if(candidate.snap.white_reading&&meterReadingHasLuminance(candidate.snap.white_reading)&&meterReadingMatchesStepList(candidate.snap.white_reading,type,steps)){
	    white=clone(candidate.snap.white_reading);
	    break;
	   }
  }
 }
	 return {
	  type:type,
	  points:points,
	  source_format:contextSnap.source_format||null,
	  signal_mode:signalMode,
	  target_gamma:contextSnap.target_gamma||null,
	  max_luma:contextSnap.max_luma||null,
	  dv_map_mode:contextSnap.dv_map_mode||null,
	  steps:steps,
	  readings:mergedReadings,
	  white_reading:white,
	  black_reading:contextSnap.black_reading?clone(contextSnap.black_reading):null,
	  status:(exactEligible&&exactEligible.status)||'complete'
 };
}

function meterRestoreLatestPersistedSeries(){
 if(!meterSeriesCacheBootId || meterActiveSeriesKey) return false;
 meterLoadSeriesCache();
 const lastKey=(function(){ try{return localStorage.getItem(meterSeriesCacheKey('lastSeriesKey'))||'';}catch(e){return '';} })();
 // USER custom series (id >= 1001) are never auto-loaded at boot — they load
 // only through the Custom Series manager's Load button.
 const parsed=meterParseSeriesKey(lastKey)||{};
 if(Number(parsed.points)===990001) return false;
 const restoredSeries=Number(parsed.points)>=1001&&(typeof meterCustomSeriesById==='function')?meterCustomSeriesById(parsed.points):null;
 const userCustom=!!(restoredSeries&&!restoredSeries.builtin_verification);
 if(userCustom) return false;
 if(lastKey && meterSeriesSnapshotCanRestore(meterSeriesCache[lastKey])) return meterRestoreSeriesFromCache(lastKey);
 return false;
}

function meterSeriesLatestReadingTimestamp(readings){
 let latest=0;
 (Array.isArray(readings)?readings:[]).forEach(rd=>{
  const ts=Number(rd&&rd.timestamp);
  if(Number.isFinite(ts)&&ts>latest) latest=ts;
 });
 return latest;
}

function meterSeriesIdTimestamp(seriesId){
 const match=String(seriesId||'').match(/_(\d{9,})$/);
 return match?Number(match[1]):0;
}

function meterSeriesStatusLatestTimestamp(status){
 return Math.max(
  meterSeriesLatestReadingTimestamp(status&&status.readings),
  meterSeriesLatestReadingTimestamp(status&&status.white_reading?[status.white_reading]:[]),
  meterSeriesIdTimestamp(status&&status.series_id)
 );
}

function meterCurrentSeriesLatestTimestamp(){
 return Math.max(
  meterSeriesLatestReadingTimestamp(meterReadings),
  meterSeriesLatestReadingTimestamp(meterWhiteReading?[meterWhiteReading]:[])
 );
}

function meterSeriesLuminanceReadingCount(readings){
 return (Array.isArray(readings)?readings:[]).filter(rd=>meterReadingHasLuminance(rd)).length;
}

function meterSeriesStepHasLgAutoCal26Marker(step){
 if(!step) return false;
 if(String(step.series_mode||'')==='lg-autocal-26') return true;
 if(step.autocal_legal_white_anchor) return true;
 if(step.autocal_white_reference&&(step.ddc_target_ire!=null||step.autocal_order_ire!=null||step.autocal_target_label!=null)) return true;
 if(step.autocal_slot_locked&&(step.autocal_code!=null||step.ddc_target_ire!=null||step.autocal_order_ire!=null||step.ire>100)) return true;
 return false;
}

function meterSeriesStepsHaveLgAutoCal26Markers(steps){
 return Array.isArray(steps)&&steps.some(step=>meterSeriesStepHasLgAutoCal26Marker(step));
}

function meterSeriesSnapshotHasLgAutoCal26Markers(status){
 if(!status) return false;
 if(meterSeriesStepsHaveLgAutoCal26Markers(status.steps)) return true;
 return meterSeriesStepsHaveLgAutoCal26Markers(status.readings);
}

function meterSeriesStepsHaveHcfrSaturationMarkers(steps){
 return Array.isArray(steps)&&steps.some(step=>String(step&&step.series_mode||'')==='hcfr-constant-luminance');
}

// ICC characterization uses the meter-series worker, but its patch list is a
// private workflow payload rather than a calibration-workspace series. The
// shared-status poll must never recover it into the normal Series UI: doing so
// replaces (for example) Greyscale 21pt with ICC White/Black/Grey patches while
// the preset selector still displays its built-in fallback value.
function meterSeriesStatusIsIccWorkflow(status){
 if(Number(status&&status.points||0)===990001) return true;
 if(!status) return false;
 const steps=Array.isArray(status.steps)?status.steps:[];
 const readings=Array.isArray(status.readings)?status.readings:[];
 const items=steps.length?steps:readings;
 // Older/in-flight state payloads did not always retain the reserved points
 // value, and contaminated browser caches can carry the preset's type instead
 // of the worker's. ICC characterization patch names are private and
 // deliberately use the ICC prefix, so identify that payload by shape too.
 return items.length>=2&&items.every(item=>/^ICC(?:\s|$)/i.test(String(item&&item.name||'')));
}

function meterActiveSeriesIsIccWorkflow(){
 return meterSeriesStatusIsIccWorkflow({
  type:meterActiveSeriesType,
  points:meterActiveSeriesPoints,
  steps:Array.isArray(meterSeriesSteps)?meterSeriesSteps:[],
  readings:Array.isArray(meterReadings)?meterReadings:[]
 });
}

function meterSharedSeriesStatusCanRecover(status){
 const s=String((status&&status.status)||'').toLowerCase();
 return !!(status&&!meterSeriesStatusIsIccWorkflow(status)&&status.series_id
  &&(s==='running'||s==='setup'||s==='complete'||s==='cancelled'||s==='error'));
}

function meterSharedSeriesStatusKey(status){
 if(!status) return '';
 let type=String(status.type||'').toLowerCase();
 let points=Number(status.points||0)||0;
 const steps=Array.isArray(status.steps)?status.steps:null;
 if(!type) type='greyscale';
 if(status.series_id){
  const m=String(status.series_id||'').match(/^(greyscale|colors|saturations)_/);
  if(m) type=m[1];
 }
 // Custom/lattice color series ride on type 'colors' with points>=900 (900-999
 // built-in cubes, >=1001 user series); only the stock ColorChecker is 30.
 const total=Number(status.total_steps||0)||0;
 const stepCount=steps?steps.length:0;
 if(type==='colors') points=(points>=900)?points:((points===29||total===29||stepCount===29)?29:30);
 else if(type==='saturations') points=(points===25||total===25||stepCount===25||total===30||stepCount===30||total===31||stepCount===31||meterSeriesStepsHaveHcfrSaturationMarkers(steps))?25:24;
 else if(type==='greyscale'){
  // User-defined greyscale series use their id as points, just like custom
  // colour series. Do not collapse a cached 40-patch custom series to 21pt.
  if(points>=1001) return type+'-'+points;
  if(meterSeriesSnapshotHasLgAutoCal26Markers(status)) points=26;
  else {
   const basis=points||total||stepCount;
   if(basis>0&&basis<=2) points=2;
   else if(basis===26) points=26;
   else if(basis>=101) points=100;
   else points=(basis>0&&basis<=11)?11:21;
  }
 }
 return type&&points ? type+'-'+points : '';
}

function meterSharedSeriesShouldRecover(status,opts){
 opts=opts||{};
 if(!meterSharedSeriesStatusCanRecover(status)) return false;
 const serverId=String(status.series_id||'');
 const localId=String(meterSharedSeriesId||'');
 const serverKey=meterSharedSeriesStatusKey(status);
 const serverMeta=serverKey&&typeof meterParseSeriesKey==='function'?meterParseSeriesKey(serverKey):null;
 if(serverMeta&&(serverMeta.type==='colors'||serverMeta.type==='saturations')){
  const serverObserver=meterObserverForReadings(status.readings)
   ||(/^(?:1931_2|1964_10|2015_2|2015_10)$/.test(String(status.observer||''))?String(status.observer):null);
  if(serverObserver&&serverObserver!==meterChromaticityObserver()) return false;
 }
 if(!meterActiveSeriesKey) return true;
 // Series selection is browser-local. Do not let the periodic shared-status
 // poll replace an idle 3D LUT workspace with another browser's ordinary
 // greyscale/color session (and repeatedly redraw its stale chart data).
 // A series actually running in this browser still follows the normal sync.
 if(meterSeriesTab==='3dlut'&&!meterSeriesRunning&&!meterActionPending&&serverMeta
   &&meterSeriesTabForSeries(serverMeta.type,serverMeta.points)!=='3dlut') return false;
 const serverCount=meterSeriesLuminanceReadingCount(status.readings);
 const localCount=meterSeriesLuminanceReadingCount(meterReadings);
 const serverTs=meterSeriesStatusLatestTimestamp(status);
 const localTs=meterCurrentSeriesLatestTimestamp();
 const state=String(status.status||'').toLowerCase();
 const isActive=(state==='running'||state==='setup');
 if(serverId&&localId){
  if(serverId!==localId) return true;
  if(serverCount>localCount) return true;
  return serverTs>0&&serverTs>localTs;
 }
 if(serverId&&!localId){
  if(serverKey&&meterActiveSeriesKey&&serverKey!==meterActiveSeriesKey&&!opts.restoredLocal) return false;
  if(serverKey&&meterActiveSeriesKey&&serverKey!==meterActiveSeriesKey&&opts.restoredLocal) return serverTs>0&&(!localTs||serverTs>=localTs);
  if(isActive) return true;
  // A completed Read Selection remains the server's latest status and contains
  // only that subset. The browser cache already holds the full series with the
  // selected patches merged into it. After switching away, localId is empty;
  // do not let the periodic shared-status poll replace that larger snapshot
  // with the terminal subset merely because its last timestamp is equal/newer.
  if(serverKey&&serverKey===meterActiveSeriesKey&&localCount>serverCount&&localCount>0) return false;
  if(serverCount>0&&localCount===0) return true;
  if(serverTs>0&&(!localTs||serverTs>=localTs)) return true;
  if(serverCount>localCount&&(!localTs||serverTs+300>=localTs)) return true;
 }
 return false;
}

// D65 reference white chromaticity
const D65={x:0.3127,y:0.3290,X:0.9505,Y:1.0,Z:1.0890};

function xyToUnitXyz(x,y){
 if(!(x>0) || !(y>0) || x+y>=1) return {X:D65.X,Y:1,Z:D65.Z};
 return {X:x/y,Y:1,Z:(1-x-y)/y};
}

const METER_BRADFORD_M=[[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]];
const METER_BRADFORD_MI=[[0.9869929,-0.1470543,0.1599627],[0.4323053,0.5183603,0.0492912],[-0.0085287,0.0400428,0.9684867]];
function meterBradfordAdaptXyz(X,Y,Z,fromWhite,toWhite){
 const fx=Number(fromWhite&&fromWhite.x),fy=Number(fromWhite&&fromWhite.y);
 const tx=Number(toWhite&&toWhite.x),ty=Number(toWhite&&toWhite.y);
 if(!(fx>0&&fy>0&&tx>0&&ty>0)) return {X:X,Y:Y,Z:Z};
 if(Math.abs(fx-tx)<1e-7&&Math.abs(fy-ty)<1e-7) return {X:X,Y:Y,Z:Z};
 const mul=(M,v)=>[M[0][0]*v[0]+M[0][1]*v[1]+M[0][2]*v[2],M[1][0]*v[0]+M[1][1]*v[1]+M[1][2]*v[2],M[2][0]*v[0]+M[2][1]*v[1]+M[2][2]*v[2]];
 const ws=xyToUnitXyz(fx,fy),wd=xyToUnitXyz(tx,ty);
 const cs=mul(METER_BRADFORD_M,[ws.X,ws.Y,ws.Z]);
 const cd=mul(METER_BRADFORD_M,[wd.X,wd.Y,wd.Z]);
 const c=mul(METER_BRADFORD_M,[X,Y,Z]);
 const scaled=[c[0]*(cs[0]!==0?cd[0]/cs[0]:1),c[1]*(cs[1]!==0?cd[1]/cs[1]:1),c[2]*(cs[2]!==0?cd[2]/cs[2]:1)];
 const out=mul(METER_BRADFORD_MI,scaled);
 return {X:out[0],Y:out[1],Z:out[2]};
}
function meterAdaptReferenceXyzToTargetWhite(X,Y,Z){
 const wp=(typeof meterTargetWhitePoint==='function')?meterTargetWhitePoint():D65;
 return meterBradfordAdaptXyz(X,Y,Z,D65,wp);
}

// Black-floor epsilon (cd/m²): a black (0%) read at or below this luminance is
// treated as true zero (normalized to {0,0,0}) instead of reporting the small
// ambient-leakage value a spectro picks up on a true-black OLED. Set just above
// the observed i1 Pro 2 ambient (~0.004) and well under the lowest real
// greyscale step, so only the 0% patch is affected (gate is meterReadingTargetsBlack).
const METER_BLACK_FLOOR_NITS=0.02;

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
 const corrected=base;
  reading.X=corrected.X;
  reading.Y=corrected.Y;
  reading.Z=corrected.Z;
  // Black-floor normalize: a true-black (0%) patch reads exactly 0 with a
  // colorimeter but a small POSITIVE ambient-leakage value with a spectro
  // (observed ~0.004 cd/m² on the i1 Pro 2). Route that through the same
  // zero path used for the exact-0 case: when this is a black-targeted read
  // (meterReadingTargetsBlack) and the measured luminance is at/below the
  // black-floor epsilon (just above the observed ambient, well under the
  // lowest real greyscale step), snap X/Y/Z to 0. raw_* above are preserved
  // for diagnostics, and a genuinely elevated black (>epsilon) is left
  // untouched. Applies to single/continuous/series reads (all flow here).
  if(meterReadingTargetsBlack(reading)
     && Number.isFinite(corrected.Y) && corrected.Y>=0 && corrected.Y<=METER_BLACK_FLOOR_NITS){
   reading.X=0; reading.Y=0; reading.Z=0;
   corrected.X=0; corrected.Y=0; corrected.Z=0;
  }
 // Luminance is the same physical quantity as CIE Y (cd/m^2). Always mirror
 // the corrected Y into reading.luminance so downstream predicates
 // (isWhiteReading / isSeriesWhite) and chart references see the same value
 // whether or not the XYZ correction matrix is enabled and regardless of
 // whether the raw read populated a `luminance` field. Previously gated on
 // `enabled && (luminance!=null || raw_luminance!=null)`, which left
 // reading.luminance at 0 for color/sat series reads when the matrix was off
 // and the raw field was missing -- causing the ColorChecker / Sat Sweep
 // white-reference lookup to reject the measured White patch and fall through
 // to the 100-nit SDR default (massive dE for every color patch).
 reading.luminance=corrected.Y;
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

function meterMeasuredWhiteChromaticity(reading){
 const valid=(x,y)=>Number.isFinite(x)&&Number.isFinite(y)&&x>0&&y>0&&x+y<1;
 if(!reading||typeof reading!=='object') return null;
 const directX=Number(reading.x);
 const directY=Number(reading.y);
 if(valid(directX,directY)) return {x:directX,y:directY};
 const X=Number(reading.X);
 const Y=Number(reading.Y);
 const Z=Number(reading.Z);
 const sum=X+Y+Z;
 if(Number.isFinite(X)&&Number.isFinite(Y)&&Number.isFinite(Z)&&sum>0){
  const x=X/sum;
  const y=Y/sum;
  if(valid(x,y)) return {x,y};
 }
 return null;
}

function meterUseMeasuredWhiteTarget(){
 const xy=meterMeasuredWhiteChromaticity(meterFindMeasuredWhiteReading());
 if(!xy){
  toast('Read a white patch first.',true);
  return false;
 }
 const xEl=document.getElementById('meterTargetWhiteX');
 const yEl=document.getElementById('meterTargetWhiteY');
 if(!xEl||!yEl) return false;
 xEl.value=xy.x.toFixed(4);
 yEl.value=xy.y.toFixed(4);
 const customEl=document.getElementById('meterCustomD65Enabled');
 if(customEl) customEl.checked=true;
 updateMeterTargetWhitepointVisibility();
 saveMeterSettings();
 meterOnGreyRefChange();
 meterRefreshActiveSeriesCharts();
 return true;
}

const GAMUT_PRESETS=__PG_GAMUT_PRESETS__;


// Measured gamut outline: ONLY 100% primaries (R/G/B) and 100% secondaries (C/M/Y).
// Used on CIE 2D charts as a thin solid triangle (primaries) / hexagon (with secondaries).
//
// Earlier matching treated bare ColorChecker names ("Red","Green",…) and first-wins
// sat-sweep midpoints as primaries, so the outline sat on the wrong interior patches.
function meterReadingGamutCornerKey(rd){
 if(!rd) return null;
 if(typeof meterReadingIsGreyscale==='function' && meterReadingIsGreyscale(rd)) return null;
 const name=String(rd.name||'').toLowerCase().trim();
 const kind=String(rd.kind||'').toLowerCase().trim();
 const sc=String(rd.series_color||'').toLowerCase().trim();
 const sat=Number(rd.sat_pct);
 const fullSat=isFinite(sat) && sat>=99.5;
 // Explicit 100% labels: "100% Red" / "Red 100%" / "Red 100"
 const labelMap=[
  ['R',/^100%\s*red$/],['R',/^red\s*100%?$/],
  ['G',/^100%\s*green$/],['G',/^green\s*100%?$/],
  ['B',/^100%\s*blue$/],['B',/^blue\s*100%?$/],
  ['C',/^100%\s*cyan$/],['C',/^cyan\s*100%?$/],
  ['M',/^100%\s*magenta$/],['M',/^magenta\s*100%?$/],
  ['Y',/^100%\s*yellow$/],['Y',/^yellow\s*100%?$/]
 ];
 for(let i=0;i<labelMap.length;i++){
  if(labelMap[i][1].test(name)) return {key:labelMap[i][0],score:100};
 }
 // series_color + full saturation (sat sweep / color-series endpoints)
 const scMap={red:'R',green:'G',blue:'B',cyan:'C',magenta:'M',yellow:'Y'};
 if(fullSat && scMap[sc]) return {key:scMap[sc],score:90+(sat/100)};
 // DV/matrix profile kinds (full-drive primaries only; no secondaries)
 if(kind==='red') return {key:'R',score:85};
 if(kind==='green') return {key:'G',score:85};
 if(kind==='blue') return {key:'B',score:85};
 // Pure channel-code fallback. Sat sweeps run at a SUB-PEAK level (≈75% SDR /
 // ≈50% HDR), so 100% endpoints are pure in chroma but not full-scale codes.
 // Detect purity by "dominant channel(s) high, others at range floor" rather
 // than requiring near-100% code. ColorChecker "Red" etc. keep residual G/B
 // and are rejected. Mid-sat mixes also fail the floor test.
 const r=Number(rd.r_code!=null?rd.r_code:(rd.r!=null?rd.r:NaN));
 const g=Number(rd.g_code!=null?rd.g_code:(rd.g!=null?rd.g:NaN));
 const b=Number(rd.b_code!=null?rd.b_code:(rd.b!=null?rd.b:NaN));
 if([r,g,b].every(isFinite)){
  let minC=0, span=Math.max(r,g,b,1);
  try{
   if(typeof meterChromaPatchRangeMin==='function' && typeof meterChromaPatchRangeSpan==='function'){
    minC=meterChromaPatchRangeMin();
    span=meterChromaPatchRangeSpan();
   }
  }catch(e){}
  if(span>0){
   const rn=Math.max(0,Math.min(1,(r-minC)/span));
   const gn=Math.max(0,Math.min(1,(g-minC)/span));
   const bn=Math.max(0,Math.min(1,(b-minC)/span));
   const lo=0.08;
   const peak=Math.max(rn,gn,bn);
   // Dim greys / near-black: not a gamut corner
   if(peak>=0.25){
    const satBoost=fullSat?30:0;
    const score=40+peak*20+satBoost;
    // Primaries: one channel at peak, other two at floor
    if(rn>=peak*0.95 && gn<=lo && bn<=lo) return {key:'R',score:score};
    if(gn>=peak*0.95 && rn<=lo && bn<=lo) return {key:'G',score:score};
    if(bn>=peak*0.95 && rn<=lo && gn<=lo) return {key:'B',score:score};
    // Secondaries: two channels at peak, one at floor
    if(rn<=lo && gn>=peak*0.95 && bn>=peak*0.95) return {key:'C',score:score};
    if(gn<=lo && rn>=peak*0.95 && bn>=peak*0.95) return {key:'M',score:score};
    if(bn<=lo && rn>=peak*0.95 && gn>=peak*0.95) return {key:'Y',score:score};
   }
  }
 }
 return null;
}
function meterMeasuredGamutOutlinePoints(readings){
 const list=Array.isArray(readings)?readings:[];
 const best={};
 list.forEach(rd=>{
  if(!rd) return;
  const hit=meterReadingGamutCornerKey(rd);
  if(!hit) return;
  // Use observer-stamped tristimulus data and the same native projection as
  // the measured markers. This also rejects readings made with a different
  // observer instead of leaking their legacy x/y outline into another chart.
  let xyz=null,coord=null;
  try{
   xyz=meterReadingXYZ(rd);
   coord=xyz&&meterCieChartCoordFromXYZ(xyz);
  }catch(e){}
  if(!coord||!isFinite(coord.x)||!isFinite(coord.y)) return;
  const prev=best[hit.key];
  if(!prev || hit.score>prev.score){
   best[hit.key]={x:coord.x,y:coord.y,xyz:xyz,reading:rd,name:rd.name||hit.key,score:hit.score};
  }
 });
 // Prefer primaries triangle; if secondaries exist, walk R-Y-G-C-B-M (hue order)
 const orderPrim=['R','G','B'];
 const orderFull=['R','Y','G','C','B','M'];
 const hasSec=orderFull.some(k=>k!=='R'&&k!=='G'&&k!=='B'&&best[k]);
 const order=hasSec?orderFull:orderPrim;
 const pts=order.map(k=>best[k]).filter(Boolean);
 if(pts.length<3) return null;
 if(!best.R||!best.G||!best.B) return null;
 return pts;
}
function meterStrokeMeasuredGamut(ctx,toX,toY,readings){
 const pts=meterMeasuredGamutOutlinePoints(readings);
 if(!pts||pts.length<3) return;
 ctx.save();
 ctx.strokeStyle=pgThemeColor('--chart-measured-gamut','rgba(120,220,170,0.92)');
 ctx.lineWidth=1.0;
 ctx.setLineDash([]);
 ctx.beginPath();
 pts.forEach((p,i)=>{ const X=toX(p.x), Y=toY(p.y); if(i===0) ctx.moveTo(X,Y); else ctx.lineTo(X,Y); });
 ctx.closePath();
 ctx.stroke();
 ctx.restore();
}

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

function meterTargetGamutUsesD65(key){
 return key==='bt709'||key==='bt2020'||key==='p3d65';
}

function meterTargetWhitePointEnabled(){
 const customEl=document.getElementById('meterCustomD65Enabled');
 return !!(customEl&&customEl.checked&&meterTargetGamutUsesD65(meterActiveGamutKey()));
}

function updateMeterTargetWhitepointVisibility(){
 const field=document.getElementById('meterTargetWhitePointField');
 const toggle=document.getElementById('meterCustomD65ToggleWrap');
 const usesD65=meterTargetGamutUsesD65(meterActiveGamutKey());
 if(toggle) toggle.style.display=usesD65?'flex':'none';
 if(!field) return;
 const enabled=meterTargetWhitePointEnabled();
 field.classList.toggle('visible',enabled);
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
 const active=(typeof meterActiveSeriesDvMapMode!=='undefined')?String(meterActiveSeriesDvMapMode||''):'';
 if(active) return active;
 const el=document.getElementById('dv_map_mode');
 return String((el&&el.value) || (config&&config.dv_map_mode) || '2');
}

function meterDvInterfaceValue(){
 return '0';
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
 // DV Absolute is PQ RGB in a BT.2020 container. Target xy (normally P3-D65)
 // must be reverse-solved into that container. Emitting target-gamut RGB
 // coefficients directly makes a P3 endpoint become a BT.2020 endpoint on
 // the wire. Relative DV retains its established target-gamut tunnel path.
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return meterContainerGamut();
 if(meterChartIsDv()) return meterAnalysisGamut();
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
 const v=String((rangeEl&&rangeEl.value)||'0');
 if(v==='1') return true;
 if(v==='2') return false;
 // Default: YCbCr transports are Limited on the wire (Full range is an
 // RGB-only concept), so Default resolves to Limited whenever a YCbCr
 // colour format is selected. RGB Default keeps the historical
 // full-range interpretation.
 return !meterOutputIsRgb();
}

// Quant-range rules for the selected colour format: YCbCr is always
// Limited on the wire, so the Full option is REMOVED from the dropdown for
// YCbCr (not merely greyed out) and a Full selection is coerced back to
// Limited when switching to YCbCr. The Default option label reflects what it
// resolves to.
function uiEnforceQuantRangeForColorFormat(){
 const fmtEl=document.getElementById('color_format');
 const sel=document.getElementById('rgb_quant_range');
 if(!fmtEl||!sel) return;
 const isYcc=fmtEl.value==='1'||fmtEl.value==='2';
 const fullOpt=sel.querySelector('option[value="2"]');
 if(fullOpt){
  fullOpt.hidden=isYcc;
  fullOpt.disabled=isYcc;
  fullOpt.style.display=isYcc?'none':'';
 }
 const defOpt=sel.querySelector('option[value="0"]');
 if(defOpt) defOpt.textContent=isYcc?'Default (Limited)':'Default';
 if(isYcc&&sel.value==='2'){
  sel.value='1';
  try{ sel.dispatchEvent(new Event('change',{bubbles:true})); }catch(e){}
 }
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
 // Popup block removed by user request on 2026-06-13: the operator runs
 // autocal tests in different signal modes (RGB 10-bit full, RGB 10-bit
 // limited, YCbCr 4:4:4 limited, etc.) and the YCbCr-only toast was
 // blocking the test run. The autocal's per-anchor 16-235 patches still
 // go through correctly in any signal mode (the meter measures whatever
 // the panel puts out); we just no longer FORCE a switch to YCbCr 4:4:4
 // limited before the autocal starts. If the headroom is required and
 // the transport can't carry it, the dE at 95-100% will be visibly off
 // and the operator can switch manually.
 if(!meterExtendedVideoHeadroomRequired()||meterExtendedVideoTransportOk()) return true;
 return true;
}

function meterEnsureLgAutoCalExtendedVideoTransport(){
 // Popup block removed by user request on 2026-06-13: see the comment
 // on meterEnsureExtendedVideoTransport above. Same rationale.
 if(!meterLgAutoCalUsesExtendedSdr()||meterExtendedVideoTransportCanCarryHeadroom()) return true;
 return true;
}

function meterGreyscaleUsesFullSourceRange(){
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 return meterActiveSeriesType==='greyscale' && mode==='sdr' && !meterPatchUsesVideoRange() && !meterLgGreyscaleUsesLegalSdrDdcCodes(meterActiveSeriesPoints);
}

function meterPatchUsesVideoRange(){
 if(typeof meterChartIsDv==='function'&&meterChartIsDv()) return true;
 return meterIsLimitedRange();
}

function meterRangeMin(){
 return meterIsLimitedRange()?16:0;
}

function meterRangeSpan(){
 return meterIsLimitedRange()?219:255;
}

// SDR26 super-white ladder (99/105/109 anchors) exists only on YCbCr
// Limited transports. RGB Limited clamps above legal white, so it uses
// the Full-shape 24-anchor model with Limited codes; its peak is 100%.
// Full range never has super-white at all. Returns true IFF the active
// transport is YCbCr Limited (color_format 1 or 2 with limited range).
function meterSdr26UsesSuperWhiteLadder(){
 if(typeof meterPatchUsesVideoRange==='function' && !meterPatchUsesVideoRange()) return false;
 const fmt=(typeof meterOutputFormatValue==='function')?String(meterOutputFormatValue()):'0';
 return fmt==='1'||fmt==='2';
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
 const base=meterSdrRgbChromaUsesFullSourceRange()?0:meterPatchRangeMin();
 const bits=meterPatchBitDepth();
 return bits===12?Math.round(base*16):(bits===10?Math.round(base*4):base);
}

function meterChromaPatchRangeSpan(){
 const base=meterSdrRgbChromaUsesFullSourceRange()?255:meterPatchRangeSpan();
 const bits=meterPatchBitDepth();
 return bits===12?Math.round(base*16):(bits===10?Math.round(base*4):base);
}

function meterDvRelativeSt2084UsesLegalRange(){
 return false;
}

function meterGreyTargetGammaSelection(){
 // Active-series snapshot wins during an LG HDR autocal (the solver pins a
 // 2.2 power target and the chart has to grade against the same curve).
 // Outside autocal, the operator's TARGET GAMMA dropdown is the source of
 // truth: changing it must immediately retarget the chart math even if an
 // older series snapshot is still cached. For SDR, always honor the dropdown
 // (2.7.2 behaviour) so a non-bt1886 snapshot cannot bypass the BT.1886
 // black-level lift on a calibrated SDR panel.
 if((typeof meterChartIsHdr==='function') && meterChartIsHdr() &&
    (typeof meterHdrAutoCalUsesPowerGammaChartMath==='function') &&
    meterHdrAutoCalUsesPowerGammaChartMath()){
  return '2.2';
 }
 const el=document.getElementById('meterTargetGamma');
 const selected=String((el&&el.value) || '');
 if(meterChartIsDv()){
  // During an active calibration the solver pins the DV curve to the
  // map-mode-appropriate gamma; otherwise honor the operator's dropdown
  // selection so a DV ST 2084 target renders the PQ charts.
  const calActive=(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
   ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
   ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
   ||(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning);
  return calActive ? meterDvAutoTargetGamma() : (selected||meterDvAutoTargetGamma());
 }
 return selected;
}

function meterDvRelativeUsesGammaChartMath(){
 return false;
}

function meterHdrAutoCalUsesPowerGammaChartMath(){
 const phase=String((typeof meterAutoCalPhase!=='undefined'&&meterAutoCalPhase)||'');
 const status=(typeof meterAutoCalLatestStatus!=='undefined')?meterAutoCalLatestStatus:null;
 const statusRunning=!!(status&&String(status.status||'').toLowerCase()==='running');
 // During an active HDR10 calibration the series is stamped target_gamma=2.2
 // and the chart math must grade against 2.2. But once calibration completes
 // and the operator switches Target Gamma back to ST 2084 (the HDR10 default),
 // the chart must follow the dropdown -- the stale 2.2 series stamp cannot
 // pin the curve forever. Only honor the series stamp while the dropdown is
 // also 2.2, or while a calibration/series is actively running.
 const calActive=(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning&&phase!=='complete'&&phase!=='error')
  ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
  ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
  ||(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning)
  ||statusRunning;
 const dropdownGamma=String(((document.getElementById('meterTargetGamma')||{}).value)||'').toLowerCase();
 {
  const seriesTarget=String((typeof meterActiveSeriesTargetGamma!=='undefined'&&meterActiveSeriesTargetGamma)||'').toLowerCase();
  const seriesMode=String((typeof meterActiveSeriesSignalMode!=='undefined'&&meterActiveSeriesSignalMode)||'').toLowerCase();
  if(seriesTarget==='2.2' && (seriesMode==='hdr10'||seriesMode==='dv') && meterActiveSeriesType==='greyscale' && (calActive||dropdownGamma==='2.2')) return true;
 }
 if(statusRunning){
  const target=String(status.target_gamma||'').toLowerCase();
  const layout=String(status.ddc_layout||'').toLowerCase();
  const signal=String(status.signal_mode||'').toLowerCase();
  return (target===''||target==='2.2')&&(layout==='hdr20'||signal==='hdr10');
 }
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 // DV runs through the same HDR20 greyscale mechanism as HDR10 with a pinned
 // 2.2 target -- meterLgAutoCalRequestedSignalMode() collapses dv->'sdr',
 // so do not gate this branch on hdr10 alone (operator-reported 2026-07-24).
 if(mode!=='hdr10'&&mode!=='dv') return false;
 if(meterActiveSeriesType!=='greyscale') return false;
 if(typeof meterUseLgAutoCal26==='function'&&!meterUseLgAutoCal26(meterActiveSeriesPoints)) return false;
 if(typeof meterHdrAutoCalChartContextHeld!=='undefined'&&meterHdrAutoCalChartContextHeld) return true;
 const lgCalibrationMode=!!(
  (typeof window!=='undefined'&&window.lgStatusState&&window.lgStatusState.calibrationMode)||
  (status&&(status.calibration_mode||status.calibrationMode))
 );
 const active=!!((typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning&&phase!=='complete'&&phase!=='error')||
  (typeof meterAutoCalPolling!=='undefined'&&meterAutoCalPolling)||
  (typeof meterAutoCalPendingConfig!=='undefined'&&meterAutoCalPendingConfig)||
  statusRunning);
 if(!active) return false;
 if(!lgCalibrationMode&&!(typeof meterAutoCalPendingConfig!=='undefined'&&meterAutoCalPendingConfig)) return false;
 const requested=String((typeof getVal==='function'?getVal('signal_mode'):'')||mode).toLowerCase();
 return requested==='hdr10'||requested==='dv';
}

function meterGreyChartTargetGammaSelection(){
 if(meterHdrAutoCalUsesPowerGammaChartMath()) return '2.2';
 return meterGreyTargetGammaSelection();
}

function meterGreyChartUsesPqTarget(){
 if(meterHdrAutoCalUsesPowerGammaChartMath()) return false;
 if(meterChartIsDv()){
  // Honor the operator's Target Gamma dropdown: ST 2084 -> PQ charts,
  // anything else -> standard EOTF. During an active calibration the
  // solver pins the curve, so fall back to the map-mode-appropriate path.
  const calActive=(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
   ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
   ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
   ||(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning);
  if(calActive) return meterDvMapModeValue()!=='2';
  return ((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():'')==='st2084';
 }
 const sel=String(((typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():''))||'').toLowerCase();
 if(sel && sel!=='st2084') return false;
 return (typeof meterChartIsPq==='function') && meterChartIsPq();
}

function meterGreyTargetUsesPq(){
 if(typeof meterGreyChartUsesPqTarget==='function') return meterGreyChartUsesPqTarget();
 if(meterChartIsDv()) return meterDvMapModeValue()!=='2';
 return (typeof meterChartIsPq==='function') && meterChartIsPq();
}

function meterGreyEotfUsesPqCurve(){
 if(typeof meterGreyChartUsesPqTarget==='function') return meterGreyChartUsesPqTarget();
 return meterChartIsDv() ? meterDvMapModeValue()!=='2' : meterChartIsPq();
}

function meterGreyCodeRange(){
 // Bit-depth scaling added on 2026-06-13: when max_bpc is 10, the codes
 // generated by meterCodeFromSignalPercent are 10-bit (0-1023 full,
 // 64-940 limited) so the autocal's per-anchor patches match the panel's
 // 10-bit transport. 8-bit modes still use 16-235 (limited) or 0-255 (full).
 // DV is 12-bit LEGAL range, 256..3760 (235*16), and meterPatchUsesVideoRange()
 // is deliberately unconditional for DV. That is not an oversight: Dolby Vision
 // is a FULL-RANGE TUNNEL CARRYING LIMITED-RANGE CODES, so the transport is
 // full range while the codes inside it stay legal. There is no DV full-range
 // code ladder to add here -- do not "fix" this into one.
 if(meterChartIsDv()) return {min:256,span:3504};
 // Extended SDR is LG's "16..255" ladder: legal black, FULL white. Its top is
 // 100% at full scale, so 10-bit is 64..1023 (span 959), NOT the 8-bit span
 // 239 upshifted by 4 (which gave 956 -> a 1020 top and 8-bit quantisation at
 // every point). Distinct from the SDR-26 super-white ladder, where 1023 is
 // 109% and 100% is 940 -- see meterGreySdr26HeadroomCodeRange().
 if(meterLgGreyscaleUsesExtendedSdr(meterActiveSeriesPoints)) return meterPatchBitDepth()===10?{min:64,span:959}:{min:16,span:239};
 if(meterLgGreyscaleUsesLegalSdrDdcCodes(meterActiveSeriesPoints)) return meterPatchBitDepth()===10?{min:64,span:876}:{min:16,span:219};
 const eightBitRange=(meterGreyscaleUsesFullSourceRange()||!meterPatchUsesVideoRange())?{min:0,span:255}:{min:meterPatchRangeMin(),span:meterPatchRangeSpan()};
 if(meterPatchBitDepth()===10){
  // Scale the ENDPOINTS, not the span.
  //
  // This used to be span*4, which the comment above it already contradicted
  // ("full range scales by 1023/255"). Full range came out 0..1020, so 100%
  // white went on the wire as 1020 instead of 1023 -- a real signal error at
  // peak, not just a chart-matching one, and PQ is least forgiving exactly
  // there. Limited was unaffected because its endpoints happen to be exact
  // <<2 mappings.
  //
  // Full scale is full scale at either depth: 8-bit 255 IS 10-bit 1023.
  // Sub-full-scale endpoints (legal 16..235) are exact <<2 mappings
  // (64..940), so they must keep using *4 rather than being stretched to
  // full scale.
  const min8=eightBitRange.min;
  const max8=eightBitRange.min+eightBitRange.span;
  const min10=Math.round(min8*4);
  const max10=(max8>=255)?1023:Math.round(max8*4);
  return {min:min10,span:max10-min10};
 }
 return eightBitRange;
}

function meterPatchBitDepth(){
 if(typeof meterChartIsDv==='function'&&meterChartIsDv()) return 12;
 const bpc=parseInt(getVal('max_bpc')||'8',10);
 return bpc===12?10:bpc;
}

function meterPatchInputMax(){
 const bits=meterPatchBitDepth();
 return bits===12?4095:(bits===10?1023:255);
}

// HDR10 (10-bit PQ) 100% white code depends on the panel's quant range.
// Limited 10-bit -> 940 (94% of 1023, BT.709-style 100% white).
// Full 10-bit    -> 1023 (100% of full range).
function meterLgHdrHundredPercentCodeForRange(){
 return meterIsLimitedRange() ? 940 : 1023;
}

function meterActiveSeriesCodesAre8Bit(){
 // True when the current greyscale series' patch codes are 8-bit (white
 // r_code ~235/255) even though the transport (max_bpc) is 10-bit. The
 // white/100% patch is read first, so its r_code reliably indicates the
 // series code bit-depth (235 -> 8-bit, 940/1023 -> 10-bit). Returns false
 // when unknown so codes that already match the range are left alone.
 let w=(typeof meterWhiteReading!=='undefined' && meterWhiteReading) ? meterWhiteReading : null;
 if((!w || w.r_code==null) && Array.isArray(meterReadings)){
  w=meterReadings.find(function(r){ return r && (Number(r.ire)===100 || r.final_white_refresh) && (r.r_code!=null || r.r!=null); }) || w;
 }
 if(!w) return false;
 const wc=Number(w.r_code!=null?w.r_code:w.r);
 return Number.isFinite(wc) && wc>0 && wc<=255;
}

// The SDR-26 super-white ladder is NOT the extended-SDR ladder, even though
// both run from legal black to full scale. On this one the TOP is 109%, not
// 100%: 0%->64, 100%->940, 105%->984, 109%->1023, the piecewise ladder built by
// meterLgAutoCalCodeForSlot (64 + S/100*876 up to 100%, then 940 + (S-100)/9*83).
// Only YCbCr-Limited SDR-26 has it (meterGreyAllowsHeadroomTargets).
//
// It has its own range so that correcting the extended-SDR ladder can never
// silently move SDR-26 chart targets again, and vice versa -- they were sharing
// one constant while meaning two different things.
function meterGreySdr26HeadroomCodeRange(){
 return (typeof meterPatchBitDepth==='function' && meterPatchBitDepth()===10)
  ? {min:64,span:959}    // 64..1023, top = 109%
  : {min:16,span:239};   // 16..255,  top = 109%
}
function meterGreySignalFractionFromCode(code){
 let numeric=Number(code);
 const range=meterGreyCodeRange();
 // Bit-depth reconciliation: the manual greyscale series read can emit 8-bit
 // codes (white=235) while max_bpc=10 makes meterGreyCodeRange 10-bit; scale
 // the 8-bit code to 10-bit so (code-min)/span is correct. No-op for genuinely
 // 10-bit series (white>255) and for 8-bit transports (max_bpc=8).
 if(typeof meterPatchBitDepth==='function' && meterPatchBitDepth()===10 && Number.isFinite(numeric) && numeric<=255 && meterActiveSeriesCodesAre8Bit()){
  numeric=numeric*4;
 }
 if(meterChartIsDv()){
  return Math.max(0,Math.min(1,((numeric||0)-range.min)/range.span));
 }
if(Number.isFinite(numeric) && (meterGreyAllowsHeadroomTargets() || numeric>255)){
   // SDR-26 headroom decode uses its OWN range, not meterGreyCodeRange(): the
   // two ladders share endpoints but not meaning, and they were sharing one
   // constant. See meterGreySdr26HeadroomCodeRange().
   //
   // The chart normalises against the TOP of the ladder, so the 109% anchor
   // must come back as exactly 1.0: grey target Y for 109 = peak * signal^γ
   // and the peak anchor needs signal 1.0. With the old span (956) code 1023
   // returned 1.003 and only the clamp below hid it -- the bisection in
   // meterGreySolvePeakFromHeadroomReading would otherwise solve peak =
   // measured_Y / 1.003^γ, ~0.75% low, and every body anchor (50-105) would
   // show a proportionally low target Y, inflating ΔE ITP across the upper
   // greyscale. With span 959 (64..1023) it is exactly 1.0 arithmetically;
   // the clamp stays as a guard rather than as the mechanism.
   const hr=meterGreyAllowsHeadroomTargets()?meterGreySdr26HeadroomCodeRange():range;
   const headroomPeak=(numeric-hr.min>=hr.span*0.95) && numeric>=hr.min+hr.span;
   return Math.max(0,Math.min(headroomPeak?1.0:1.1,(numeric-hr.min)/hr.span));
  }
 return Math.max(0,Math.min(1,(numeric-range.min)/range.span));
}

function meterSignalFractionFromCode(code){
 const min=meterPatchRangeMin();
 const span=meterPatchRangeSpan();
 return Math.max(0,Math.min(1,((code||0)-min)/span));
}

function meterDvTargetGamma(){
 return meterChartIsDv() && meterDvMapModeValue()==='1' ? 3.8 : 2.2;
}

function meterDvTunnelGamma(){
 return meterDvTargetGamma();
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
  const sel=(typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||'')||((typeof meterDvAutoTargetGamma==='function')?meterDvAutoTargetGamma():''));
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
 const sel=(typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||'')||((typeof meterDvAutoTargetGamma==='function')?meterDvAutoTargetGamma():''));
 if(sel==='st2084') return Math.min(targetPeak,meterChartPqDecodeNormalized(clamped));
 if(sel==='srgb') return Math.min(targetPeak,srgbEotf(clamped)*targetPeak);
 if(sel==='bt1886') return Math.min(targetPeak,gammaEotf(clamped,2.4)*targetPeak);
 return Math.min(targetPeak,gammaEotf(clamped,parseFloat(sel)||2.2)*targetPeak);
}

function meterDvAbsoluteTargetRollOffFraction(peak){
 const targetPeak=(peak>0)?peak:meterChartMasterPeak();
 return meterChartPqEncodeNormalized(targetPeak);
}

function meterDvTargetSignalFraction(ire,code){
 const pct=Number(ire);
 if(Number.isFinite(pct)) return clampNum(pct/100,0,1);
 if(code!=null&&code!==''&&typeof meterGreySignalFractionFromCode==='function'){
  return meterGreySignalFractionFromCode(Number(code));
 }
 return 0;
}

function meterDvAbsoluteChartTargetLuminance(ire, peak, code){
 const targetPeak=(peak>0)?peak:100;
 const frac=clampNum((ire||0)/100,0,1);
 const signal=(typeof meterDvTargetSignalFraction==='function')
  ? meterDvTargetSignalFraction(ire,code)
  : ((code!=null&&code!==''&&typeof meterGreySignalFractionFromCode==='function')
   ? meterGreySignalFractionFromCode(Number(code))
   : frac);
 const roll=(typeof meterDvAbsoluteTargetRollOffFraction==='function')
  ? meterDvAbsoluteTargetRollOffFraction(targetPeak)
  : meterChartPqEncodeNormalized(targetPeak);
 return signal>=roll ? targetPeak : Math.min(targetPeak,meterChartPqDecodeNormalized(signal));
}

function meterDvRelativeChartTargetLuminance(ire, peak, code){
 const targetPeak=(peak>0)?peak:100;
 const frac=clampNum((ire||0)/100,0,1);
 return Math.min(targetPeak,gammaEotf(frac,2.2)*targetPeak);
}

function meterCodeFromSignalPercent(percent){
 return meterCodeFromSignalPercentWithOptions(percent,null);
}

function meterLgSdrExtendedCodeFromPercent(percent){
 const clamped=clampNum(percent,0,100)/100;
 if(clamped<=0) return 0;   // 0% is true black, below legal black, at both depths
 // Derive the code natively at the transport depth. This was 8-bit-only
 // (16+pct*239) regardless of max_bpc, so on a 10-bit link it either shipped an
 // 8-bit code or, once upshifted, carried 8-bit quantisation the whole way up.
 // Extended SDR runs legal black to FULL white, so 10-bit is 64..1023.
 if(typeof meterPatchBitDepth==='function' && meterPatchBitDepth()===10) return Math.round(64+clamped*959);
 return Math.round(16+clamped*239);
}

function meterLgSdrLegalHeadroomCodeFromPercent(percent){
	 const s=clampNum(percent,0,109.5);
	 const bits=meterPatchBitDepth();
	 const limited=meterIsLimitedRange();
	 if(!limited){
		// Full range: no headroom above 100%. 10-bit uses 8bit<<2 so the
		// patch samples the same LUT entry the SDR26 DPG solver adjusts.
		const clamped=Math.max(0,Math.min(100,s));
		if(bits===10){
			if(clamped>=99.95) return 1023;
			return (Math.round(clamped/100*255)<<2);
		}
		return Math.round(clamped/100*255);
	 }
	 // Limited: dispatch on RGB vs YCbCr (RGB clamps at legal peak,
	 // YCbCr ramps into super-white).
	 const fmt=meterOutputFormatValue();
	 const isYcbcr=(fmt==='1'||fmt==='2');
	 if(bits===10){
		if(isYcbcr){
			// YCbCr Limited 10-bit: 64..1023 with super-white ramp.
			const c=s<=100 ? 64+s/100*876 : 940+(s-100)/9*83;
			return Math.max(64,Math.min(1023,Math.round(c)));
		}
		// RGB Limited 10-bit: 64..940 only.
		return Math.max(64,Math.min(940,Math.round(64+s/100*876)));
	 }
	 if(isYcbcr){
		// YCbCr Limited 8-bit: 16..255 with super-white ramp.
		const c=s<=100 ? 16+s/100*219 : 235+(s-100)/9*20;
		return Math.max(16,Math.min(255,Math.round(c)));
	 }
	 // RGB Limited 8-bit: 16..235 only.
	 return Math.max(16,Math.min(235,Math.round(16+s/100*219)));
}

function meterLgAutoCalStimulusFromCode(code){
	 const numeric=Number(code);
	 if(!Number.isFinite(numeric)) return 0;
	 const bits=meterPatchBitDepth();
	 const limited=meterIsLimitedRange();
	 const peak=bits===10?1023:255;
	 if(!limited){
		// Full 10-bit uses 8bit<<2 codes (not linear *1023). Invert via >>2.
		if(bits===10){
			if(numeric>=1020) return 100; // peak 1020..1023 → 100%
			const b8=Math.max(0,Math.min(255,numeric>>2));
			return Math.max(0,Math.min(100,(b8/255)*100));
		}
		return Math.max(0,Math.min(100,(numeric/peak)*100));
	 }
	 const fmt=meterOutputFormatValue();         // '0'=RGB, '1'=YCbCr 4:2:2, '2'=YCbCr 4:4:4
	 const isYcbcr=(fmt==='1'||fmt==='2');
	 if(bits===10){
		if(isYcbcr){
			// YCbCr Limited 10-bit: 64..940 -> 0..100%, 941..1023 ->
			// 100..109% via super-white ramp 940+(S-100)/9*83.
			if(numeric<=64) return 0;
			if(numeric<=940) return Math.max(0,Math.min(100,(numeric-64)*100/876));
			return Math.max(100,Math.min(109,100+(numeric-940)*(109-100)/(1023-940)));
		}
		// RGB Limited 10-bit: 64..940 -> 0..100%. >940 -> 100% (clamped).
		if(numeric<=64) return 0;
		return Math.max(0,Math.min(100,(numeric-64)*100/876));
	 }
	 // 8-bit Limited
	 if(isYcbcr){
		// YCbCr Limited 8-bit: 16..235 -> 0..100%, 236..255 -> 100..109%.
		if(numeric<=16) return 0;
		if(numeric<=235) return Math.max(0,Math.min(100,(numeric-16)*100/219));
		return Math.max(100,Math.min(109,100+(numeric-235)*(109-100)/(255-235)));
	 }
	 // RGB Limited 8-bit: 16..235 -> 0..100%. >235 -> 100% (clamped).
	 if(numeric<=16) return 0;
	 return Math.max(0,Math.min(100,(numeric-16)*100/219));
}

function meterLgAutoCalTargetYnForStimulus(stimulus){
 const signal=Math.max(0,Math.min(1.1,(Number(stimulus)||0)/100));
 if(signal<=0) return 0;
 const sel=((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||''))||'bt1886';
 if(sel==='srgb') return signal<=0.04045 ? signal/12.92 : Math.pow((signal+0.055)/1.055,2.4);
 // PQ (ST2084): match the server's $target_signal_to_linear hdr10+st2084
 // branch and the chart's PQ path. Decode the normalized signal as a PQ
 // code value to absolute nits, then normalize to the 10000-nit peak so
 // the chart's target_Yn * peak math gives the same PQ EOTF target the
 // server bakes. Without this branch, 'st2084' falls through to the
 // 2.4 power-law and stamps a BT.1886-shaped target_Yn on HDR PQ steps
 // -- which on a PQ-calibrated panel makes the dE chart blow up by
 // ~100x (see 2026-06-29 memory note on the Include-luminance toggle).
 if(sel==='st2084' && typeof meterChartPqDecodeNormalized==='function'){
  const y=meterChartPqDecodeNormalized(signal);
  return y>0 ? y/10000 : 0;
 }
 const gamma=sel==='2.2'?2.2:2.4;
 return Math.pow(signal,gamma);
}

function meterLgAutoCalTargetMetaForCode(code){
 const wp=meterTargetWhitePoint();
 const stimulus=meterLgAutoCalStimulusFromCode(code);
 return {
  target_x:wp.x,
  target_y:wp.y,
  target_Yn:meterLgAutoCalTargetYnForStimulus(stimulus)
 };
}

// Re-grade a single greyscale reading's luminance target against the
// CURRENTLY selected target gamma (via meterLgAutoCalTargetYnForStimulus).
// The reading's original target_Yn is baked at series-load time and the
// per-step stamp in meterStampReadingStepMeta re-applies that baked value
// on every meterAttachSeriesMeta pass, so changing the TARGET GAMMA dropdown
// alone has no visible effect. This helper overwrites the baked value with
// the live computation, and clears any cached absolute target_X/Y/Z so
// meterTargetXYZForReading re-derives them from the new target_Yn.
//
// Guards:
//   - non-greyscale readings (colors / saturations have a different
//     target_Yn meaning - relative color value, not a luminance-gamma
//     target) are left alone.
//   - Dolby Vision series use meterDvAutoTargetGamma + absolute-Y target
//     math; their baked target_Yn is correct, leave it alone.
function meterRegradeReadingTargetYn(reading){
 if(!reading) return;
 if(typeof meterReadingIsGreyscale==='function' && !meterReadingIsGreyscale(reading)) return;
 if(typeof meterChartIsDv==='function' && meterChartIsDv()) return;
 const stimulus=(typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(reading):((typeof meterReadingAnalysisIre==='function')?meterReadingAnalysisIre(reading):null);
 if(!Number.isFinite(stimulus)) return;
 if(typeof meterLgAutoCalTargetYnForStimulus!=='function') return;
 const liveTargetYn=meterLgAutoCalTargetYnForStimulus(stimulus);
 if(!Number.isFinite(liveTargetYn)) return;
 reading.target_Yn=liveTargetYn;
 // Drop any cached absolute target_X/Y/Z so the chart path falls through
 // to the recompute branch in meterTargetXYZForReading, which uses the
 // new normalized target_Yn + the (unchanged) chroma target_x/target_y.
 if('target_X' in reading) reading.target_X=undefined;
 if('target_Y' in reading) reading.target_Y=undefined;
 if('target_Z' in reading) reading.target_Z=undefined;
}

// Re-grade every greyscale reading in meterReadings against the currently
// selected target gamma. Safe to call on a non-greyscale series (no-op).
function meterRegradeActiveSeriesTargets(){
 if(!Array.isArray(meterReadings)) return;
 for(const rd of meterReadings) meterRegradeReadingTargetYn(rd);
}

function meterLgAutoCalBodyLumaBiasPayload(dtype){
 const display=String(dtype||getEffectiveDisplayType()||'').toLowerCase();
 if(!/lg[_ -]?c2/.test(display)) return {};
 return {
  body_luma_bias_mode:'observe',
  body_luma_bias_matrix_pct:{
   10:-0.006,
   15:0.008,
   20:0.014,
   25:0.008,
   30:0.0145,
   35:0.014,
   40:0.0156,
   45:0.0191,
   50:0.0218,
   55:0.012,
   60:0.0152,
   65:0.0126,
   70:0.0219,
   75:0.0146,
   80:0.0073,
   85:0.0101,
   90:0.0107
  }
 };
}

// SDR26 body slots for the active range. Only YCbCr Limited keeps the
// super-white ladder (99/105/109); RGB Limited AND Full use the 24-anchor
// shape with no super-white (RGB Limited clamps 101..109% to legal white,
// Full has no super-white at all). Used by thumbs, series slots, TV stops.
// Dark Detail filler patch values. These MUST stay identical to
// ddc_dark_detail_fillers_for_layout() in meter_lg_autocal.pl: the browser
// posts the measurement steps and the worker maps each one onto a DDC slot via
// ddc_target_for_step, so a value present in one list and not the other is
// simply dropped on the floor. Changing one without the other is a bug.
const METER_DARK_DETAIL_FILLERS_SDR=[2,2.7,3.7,6,8,9];
const METER_DARK_DETAIL_FILLERS_HDR=[1,2.3,3,3.7,6,8,55,65,75,85,95];

function meterDarkDetailFillersForMode(mode){
 const m=String(mode||'').toLowerCase();
 return (m==='hdr10'||m==='dv')?METER_DARK_DETAIL_FILLERS_HDR.slice():METER_DARK_DETAIL_FILLERS_SDR.slice();
}

// Merge the fillers into a ladder body, de-duped, returned ascending. Callers
// impose their own final ordering (SDR keeps the body ascending, HDR reverses
// it to descending), so this deliberately does not care about direction.
// Returns the input untouched when the option is off, so the default path is
// byte-identical.
function meterDarkDetailMergeBody(body,mode){
 const base=(body||[]).slice();
 if(!(typeof meterFullAutoCalDarkDetailEnabled==='function'&&meterFullAutoCalDarkDetailEnabled())) return base;
 const seen=new Set(base.map(v=>Number(v).toFixed(4)));
 meterDarkDetailFillersForMode(mode).forEach(v=>{
  const k=Number(v).toFixed(4);
  if(!seen.has(k)){ seen.add(k); base.push(Number(v)); }
 });
 return base.sort((a,b)=>a-b);
}

function meterLgAutoCalSdr26BodySlots(){
 const body=(typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder())
  ? METER_LG_GREY_AUTOCAL_26_SLOTS_FULL
  : METER_LG_GREY_AUTOCAL_26_SLOTS;
 return meterDarkDetailMergeBody(body,'sdr');
}
function meterLgAutoCalSdr26SeriesSlots(){
 // RGB Limited AND Full: include peak 100% (it is a real charted/thumbed
 // anchor, not a legal-white reference-only step). YCbCr Limited: body
 // already has 99/105/109; 100% legal-white is injected separately as a
 // reference-only step.
 const body=meterLgAutoCalSdr26BodySlots();
 if(typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder()){
  return [0,100,...body];
 }
 return [0,...body];
}
// Chart/target peak IRE for SDR26 gamma curves. RGB Limited AND Full ->
// 100; YCbCr Limited legal-expanded super-white ladder -> 109. Matches
// worker peak (100 or 109 depending on transport).
function meterSdr26ChartPeakIre(){
 if(typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder()) return 100;
 return 109;
}

// SDR26 forward code: IRE% → wire code. Dispatches on (transport ×
// bit-depth × colorspace). Limited transport has TWO sub-modes that must
// NOT be conflated:
//   - RGB Limited has codes 16..235 ONLY (109% clamps to 235).
//   - YCbCr Limited (4:2:2 or 4:4:4) has codes 16..255 with 235 at 100%
//     and 255 at 109% via the legal super-white ramp.
function meterLgAutoCalCodeForSlot(slot){
 const idx=METER_LG_GREY_AUTOCAL_26_SLOTS.findIndex(v=>Math.abs(Number(v)-Number(slot))<0.001);
 const bits=meterPatchBitDepth();
 const max=bits===10?1023:255;
 const numSlot=Number(slot);
 // Full range (RGB Full or YCbCr Full): SDR 10-bit uses 8bit<<2 so
 // thumbs/chart step codes match the worker DPG index + pattern code.
 // Super-white clamps to peak -- Full transport has no headroom above 100%.
 if(!meterPatchUsesVideoRange()){
  const s=Math.max(0,Math.min(100,numSlot));
  if(bits===10){
   if(s>=99.95) return 1023;
   return (Math.round(s/100*255)<<2);
  }
  return Math.round(s/100*max);
 }
 // Limited transport: dispatch on colorspace + bit-depth.
 const fmt=meterOutputFormatValue();          // '0' = RGB, '1' = YCbCr 4:2:2, '2' = YCbCr 4:4:4
 const isYcbcr=(fmt==='1'||fmt==='2');
 if(bits===10){
  if(isYcbcr){
   // YCbCr Limited 10-bit: codes 64..1023 (100=940, 109=1023, super-white
   // ramp 940+(S-100)/9*83). Use the empirical 26-entry table for the
   // exact ladder slots; formula for in-between.
   if(idx>=0) return METER_LG_GREY_AUTOCAL_26_CODES[idx];
   const s=numSlot;
   if(s<=100) return Math.max(64,Math.min(940,Math.round(64+s/100*876)));
   return Math.max(64,Math.min(1023,Math.round(940+(s-100)/9*83)));
  }
  // RGB Limited 10-bit: codes 64..940 ONLY (109% clamps to 940). Use
  // the table for the ladder, with super-white slots capped at 940.
  if(idx>=0) return Math.min(940, METER_LG_GREY_AUTOCAL_26_CODES[idx]);
  return Math.max(64,Math.min(940,Math.round(64+numSlot/100*876)));
 }
 // 8-bit Limited
 if(isYcbcr){
  // YCbCr Limited 8-bit: legal ramp ≤100% (16..235 via 16+S/100*219),
  // super-white ramp >100% (235+(S-100)/9*20 → 109%=255).
  const s=numSlot;
  if(s<=100) return Math.max(16,Math.min(235,Math.round(16+s/100*219)));
  return Math.max(16,Math.min(255,Math.round(235+(s-100)/9*20)));
 }
 // RGB Limited 8-bit: codes 16..235 only (109% clamps to 235).
 return Math.max(16,Math.min(235,Math.round(16+numSlot/100*219)));
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
 const ire=clampNum(percent,0,100);
 // SDR Full 10-bit: derive the code from the stimulus AT the transport bit
 // depth -- round(pct*1023/100).
 //
 // This used to be 8bit<<2. That map belongs to the SDR-26 AutoCal ladder and
 // still lives there in meterLgAutoCalCodeForSlot(), because those client-side
 // codes have to equal the ones the AutoCal WORKER builds for itself
 // (@sdr26_codes in meter_lg_autocal.pl, from the same 8bit<<2 helper) or the
 // chart and step strip stop matching the run. Note the DPG write index itself
 // is NOT code-derived -- the solver picks it by IRE lookup ($idx_for_sdr over
 // @sdr26_labels/@sdr26_indexes) -- so AutoCal's ladder is about agreeing with
 // the worker, not about steering node selection. Either way it was
 // ALSO applied here, which is every OTHER SDR consumer -- above all the plain
 // 11/21/30/100-point greyscale series read built by meterBuildStepsJS(). A
 // series read is a measurement, not a LUT-node write: it wants the finest
 // stimulus resolution the link can carry. 8bit<<2 yields only 256 distinct
 // values inside a 10-bit container (every code a multiple of 4, ~0.392% per
 // step) instead of the ~0.098% true 10-bit gives, i.e. it bakes 8-bit
 // quantisation into a 10-bit signal.
 //
 // It also silently destroyed data. The SERVER builds the steps a series read
 // actually measures (webui_grey_code_for_stimulus, which uses round(pct*1023
 // /100) here) and stamps those codes onto every reading as r_code/g_code/
 // b_code; the browser then matches readings to its own rebuilt steps BY CODE.
 // The two ladders agree only at 0/50/70/100, so an 11-point greyscale lost 7
 // of its 11 measured patches -- reproducibly, mid-calibration, with no
 // indication anything was missing.
 //
 // AutoCal is unaffected by this change: the SDR-26 body codes come from
 // meterLgAutoCalCodeForSlot(), its SDR 0%/100% anchors are literals, and the
 // remaining meterCodeFromSignalPercentWithOptions() call sites inside
 // meterBuildLgAutoCalSteps() are all HDR10/DV-guarded -- and this branch
 // cannot fire for HDR or DV.
 if(typeof meterPatchBitDepth==='function' && meterPatchBitDepth()===10
    && typeof meterIsLimitedRange==='function' && !meterIsLimitedRange()
    && typeof meterChartIsHdr==='function' && !meterChartIsHdr()
    && typeof meterChartIsDv==='function' && !meterChartIsDv()){
  return Math.round(ire/100*1023);
 }
 const clamped=ire/100;
 const range=meterGreyCodeRange();
 if(meterChartIsDv()){
  return Math.round(range.min+clamped*range.span);
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
 const lgAutoCalChartRef=(meterActiveSeriesType==='greyscale'&&meterUseLgAutoCal26(meterActiveSeriesPoints));
 const activeLgAutoCal=lgAutoCalChartRef&&meterAutoCalGreyscaleTargetWhiteReferenceActive();
 // SDR26 robustness fix: prefer the headroom-encoded 109% legal peak
 // (r_code == 1023, ire == 109) over the 100% reading whenever both are
 // present. The autocal worker uses 109's measured Y as the target-curve
 // peak for every body anchor; the chart must match that reference,
 // otherwise the 1-2 nit gap between 109 and 100 is PQ-amplified into
 // ~0.5 dE ITP -- ~7x over the worker's actual per-anchor dE, producing
 // the "70-99 patches fail to hit target" false alarm). The headroom
 // encoding (r_code == 1023) is the unambiguous signal that a 109
 // reading is the legal peak even before the autocal worker has stamped
 // autocal_white_reference.
 if(lgAutoCalChartRef && Array.isArray(meterReadings)){
  const sdr109=meterReadings.find(rd=>{
   // Some read/import paths carry valid tristimulus Y before the shared
   // normalizer has mirrored it into luminance. Use the same validity helper
   // as charts and export so the result does not depend on entry path.
   if(!rd || !meterReadingHasLuminance(rd)) return false;
   if(!meterReadingIsGreyscale(rd)) return false;
   const _ire=Number(rd.ire!=null?rd.ire:(rd.plot_ire!=null?rd.plot_ire:null));
   const _code=Number(rd.r_code!=null?rd.r_code:(rd.r!=null?rd.r:0));
   return Number.isFinite(_ire) && Math.abs(_ire-109)<0.05 && Number.isFinite(_code) && _code>255;
  });
  if(sdr109) return sdr109;
 }
 const readingMatchesMode=(rd)=>{
  if(!rd) return false;
  const rdMode=String((rd.signal_mode||'')).toLowerCase();
  if(rdMode) return rdMode===currentMode;
  // Legacy cached readings may not carry signal_mode. For SDR, reject
  // implausibly high white luminance snapshots that are almost certainly
  // stale HDR/DV references.
  if(currentMode==='sdr'){
   const lum=((rd.luminance!=null && rd.luminance>0)?rd.luminance:rd.Y);
   if(lum>300) return false;
  }
  return true;
 };
 const isWhiteReading=(rd)=>{
  if(!rd) return false;
  if(rd.synthetic_target) return false;
  if(lgAutoCalChartRef&&meterReadingDisablesAutoCalTargetReference(rd)) return false;
  if(activeLgAutoCal&&meterReadingIsAutoCalReferenceOnly(rd)) return false;
  if(!readingMatchesMode(rd)) return false;
  const lum=((rd.luminance!=null && rd.luminance>0)?rd.luminance:rd.Y);
  if(!(lum>0)) return false;
  if(meterReadingIsSeriesWhite(rd)) return true;
  const name=String(rd.name||'').toLowerCase();
  const r=(rd.r_code!=null)?rd.r_code:rd.r;
  const g=(rd.g_code!=null)?rd.g_code:rd.g;
  const b=(rd.b_code!=null)?rd.b_code:rd.b;
  if(r!=null && g!=null && b!=null){
   // Treat the 109% legal peak as white for SDR26 charts. The autocal
   // worker tags 109 with autocal_legal_white_anchor + autocal_white_
   // reference; honour those flags AND match by ire/name. SDR autocal
   // stores rd.ire as a STRING ('109') in some builds, so coerce.
   const _rdIre=Number(rd.ire);
   const _isLegalPeak=(rd.autocal_legal_white_anchor||rd.autocal_white_reference) ? 1 : 0;
   const _isIre100=(Number.isFinite(_rdIre) && Math.abs(_rdIre-100)<0.05);
   const _isIre109Legal=(_isLegalPeak||(Number.isFinite(_rdIre) && Math.abs(_rdIre-109)<0.05));
   if(!(_isIre100 || name==='white' || _isIre109Legal)) return false;
   return Number(r)===Number(g) && Number(g)===Number(b);
  }
  const _rdIre2=Number(rd.ire);
  const _isLegalPeak2=(rd.autocal_legal_white_anchor||rd.autocal_white_reference) ? 1 : 0;
  const _isIre100_2=(Number.isFinite(_rdIre2) && Math.abs(_rdIre2-100)<0.05);
  const _isIre109Legal2=(_isLegalPeak2||(Number.isFinite(_rdIre2) && Math.abs(_rdIre2-109)<0.05));
  if(_isIre100_2 || name==='white' || _isIre109Legal2) return ((rd.Y||0)>0 || (rd.X||0)>0 || (rd.Z||0)>0);
  return false;
 };
 if(isWhiteReading(meterWhiteReading)) return meterWhiteReading;
 if(Array.isArray(meterReadings)){
  const liveWhite=meterReadings.find(isWhiteReading);
  if(liveWhite) return liveWhite;
 }
 const preferredKeys=['greyscale-100','greyscale-2','greyscale-21','greyscale-11','saturations-25','saturations-24','colors-30'];
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

// Live SDR26 peak white (Limited 109 / Full 100). Prefers the latest
// measured peak reading so the target curve tracks each 100%/109% re-read
// during reduce-to-lowest peak calibration (Y falls as chroma balances).
function meterFindSdr26PeakWhiteReading(readings){
 const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
 let best109=null,best100=null;
 list.forEach(rd=>{
  if(!rd||typeof meterReadingIsGreyscale==='function'&&!meterReadingIsGreyscale(rd)) return;
  const y=(typeof meterReadingLuminanceNits==='function')?meterReadingLuminanceNits(rd):(Number(rd.luminance!=null?rd.luminance:rd.Y)||0);
  if(!(y>0)) return;
  const ire=Number(rd.ire!=null?rd.ire:(rd.plot_ire!=null?rd.plot_ire:rd.stimulus));
  if(!Number.isFinite(ire)) return;
  const ts=Number(rd.timestamp)||0;
  if(Math.abs(ire-109)<0.05){
   if(!best109||ts>=(best109.ts||0)) best109={rd,y,ts};
   return;
  }
  if(Math.abs(ire-100)<0.05){
   // Skip Limited legal-white reference at 100 (ddc_target_ire 99) — peak is 109.
   if(rd.autocal_legal_white_anchor||(rd.ddc_target_ire!=null&&Number(rd.ddc_target_ire)<100.5&&Number(rd.ddc_target_ire)>90)){
    if(typeof meterPatchUsesVideoRange==='function'&&meterPatchUsesVideoRange()) return;
   }
   const isFullPeak=(typeof meterReadingIsSdr26LegalPeak==='function'&&meterReadingIsSdr26LegalPeak(rd))
    ||String(rd.name||'').toLowerCase().indexOf('sdr26_')===0
    ||String(rd.autocal_target_label||'').toLowerCase().indexOf('full peak')>=0
    ||(rd.autocal_white_reference&&!rd.autocal_legal_white_anchor&&rd.ddc_target_ire==null);
   const isFullRange=(typeof meterPatchUsesVideoRange==='function'&&!meterPatchUsesVideoRange());
   if(!isFullPeak&&!isFullRange) return;
   if(!best100||ts>=(best100.ts||0)) best100={rd,y,ts};
  }
 });
 if(best109) return best109.rd;
 if(best100) return best100.rd;
 return null;
}

function meterExplicitLgTargetWhiteReferenceNits(readings){
 const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
 const lgAutoCalChartRef=(meterActiveSeriesType==='greyscale'&&meterUseLgAutoCal26(meterActiveSeriesPoints));
 const activeLgAutoCal=lgAutoCalChartRef&&meterAutoCalGreyscaleTargetWhiteReferenceActive(list);
 // Prefer live peak measured Y (updates every 100%/109% peak iter). Do NOT
 // take the first autocal_white_y stamp — 0%/body rows keep the INITIAL
 // peak Y and freeze the target curve while measured peak drops.
 if(lgAutoCalChartRef){
  const peakRd=(typeof meterFindSdr26PeakWhiteReading==='function')?meterFindSdr26PeakWhiteReading(list):null;
  const peakY=peakRd?(typeof meterReadingLuminanceNits==='function'?meterReadingLuminanceNits(peakRd):Number(peakRd.luminance!=null?peakRd.luminance:peakRd.Y)):null;
  if(peakY>0) return peakY;
  const white=(typeof meterFindLgAutoCalLegalWhiteReference==='function')?meterFindLgAutoCalLegalWhiteReference(list):((typeof meterFindSeriesWhiteReading==='function')?meterFindSeriesWhiteReading(list):null);
  const whiteY=white?meterReadingLuminanceNits(white):null;
  if(activeLgAutoCal&&white&&!white.synthetic_target&&whiteY>0) return whiteY;
 }
 let bestStamp=null;
 for(const rd of list){
  if(meterReadingDisablesAutoCalTargetReference(rd)) continue;
  if(activeLgAutoCal&&meterReadingIsAutoCalReferenceOnly(rd)) continue;
  const y=Number(rd&&(rd.autocal_white_y!=null?rd.autocal_white_y:(rd.lg_target_white_y!=null?rd.lg_target_white_y:rd.series_target_white_y)));
  if(!(Number.isFinite(y)&&y>0)) continue;
  const ts=Number(rd.timestamp)||0;
  // Prefer stamps on the peak reading itself; otherwise newest stamp.
  const onPeak=(typeof meterReadingIsSdr26LegalPeak==='function'&&meterReadingIsSdr26LegalPeak(rd))
   ||Math.abs(Number(rd.ire)-109)<0.05
   ||(Math.abs(Number(rd.ire)-100)<0.05&&String(rd.name||'').toLowerCase().indexOf('sdr26_')===0);
  if(!bestStamp||(onPeak&&!bestStamp.onPeak)||(onPeak===bestStamp.onPeak&&ts>=bestStamp.ts)){
   bestStamp={y,ts,onPeak:!!onPeak};
  }
 }
 return bestStamp?bestStamp.y:null;
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
	 const connected=(typeof lgStatusConnected==='function')?lgStatusConnected(state):!!((state.paired||state.clientKeyPresent)&&!state.pinPending&&!state.disconnected);
	 if(!connected) return null;
 return meterStoredLgTargetWhiteReferenceNits();
}

function meterSeriesUsesLgTargetWhite(type,points){
 const t=String(type||'').toLowerCase();
 // ColorChecker and Sat Sweep use the White patch from that same series for
 // target Y; stored AutoCal target white can make normal series reads look bad.
 return t==='greyscale'&&meterUseLgAutoCal26(points!=null?points:meterActiveSeriesPoints);
}

function meterColorSeriesUsesLgTargetWhite(type){
 return meterSeriesUsesLgTargetWhite(type,meterActiveSeriesPoints);
}

function meterColorSeriesTargetWhiteForRun(type,points){
 const resolvedType=type||meterActiveSeriesType;
 const resolvedPoints=points!=null?points:meterActiveSeriesPoints;
 if(!meterSeriesUsesLgTargetWhite(resolvedType,resolvedPoints)) return null;
 // LG 26pt greyscale carries its measured 100% legal-white reference in the
 // run itself; the server may audit-stamp an AutoCal target, but the chart
 // should prefer the fresh white read.
 if(String(resolvedType||'').toLowerCase()==='greyscale'&&meterUseLgAutoCal26(resolvedPoints)) return null;
 const phase=String(meterFullAutoCalPhase||'');
 if(meterFullAutoCalRunning&&phase==='precal-report') return null;
 const cfg=Number(meterFullAutoCalConfig&&meterFullAutoCalConfig.targetY);
 if(Number.isFinite(cfg)&&cfg>0) return cfg;
 try{
  if((typeof meterChartIsHdr==='function'&&meterChartIsHdr())||(typeof meterChartIsDv==='function'&&meterChartIsDv())) return null;
	 }catch(e){}
	 const state=window.lgStatusState||{};
	 const connected=(typeof lgStatusConnected==='function')?lgStatusConnected(state):!!((state.paired||state.clientKeyPresent)&&!state.pinPending&&!state.disconnected);
	 if(!connected) return null;
 return meterStoredLgTargetWhiteReferenceNits();
}

function meterApplyColorSeriesTargetWhiteReference(steps,type,points){
 if(!Array.isArray(steps)||!meterSeriesUsesLgTargetWhite(type,points)) return steps;
 const targetY=Number(meterColorSeriesTargetWhiteForRun(type,points));
 if(!(Number.isFinite(targetY)&&targetY>0)) return steps;
 steps.forEach(step=>{
  if(!step) return;
  step.series_target_white_y=targetY;
  step.lg_target_white_y=targetY;
 });
 return steps;
}

function meterGreyscaleReferenceReadings(readings){
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 const lgAutoCalChartRef=(meterActiveSeriesType==='greyscale'&&meterUseLgAutoCal26(meterActiveSeriesPoints));
 if(!lgAutoCalChartRef||meterFindSeriesWhiteReading(list)||!Array.isArray(meterReadings)) return list;
 if(typeof meterGreyscaleReadings!=='function') return list;
 const raw=meterGreyscaleReadings(meterReadings);
 const white=meterFindSeriesWhiteReading(raw);
 if(!white) return list;
 const whiteKey=meterStepNameKey(white)||'';
 const exists=list.some(rd=>rd===white||(whiteKey&&meterStepNameKey(rd)===whiteKey));
 return exists?list:[...list,white];
}

function meterEffectiveGreyscaleWhiteReference(readings){
 const list=meterGreyscaleReferenceReadings(readings);
  const lgAutoCalChartRef=(meterActiveSeriesType==='greyscale'&&meterUseLgAutoCal26(meterActiveSeriesPoints));
   const activeAutoCalReference=lgAutoCalChartRef&&meterAutoCalGreyscaleTargetWhiteReferenceActive(list);
  // SDR26 peak (Limited 109 / Full 100): always prefer the LIVE measured peak
  // reading so EOTF/gamma/luma target curves re-scale as peak Y updates each
  // reduce-to-lowest iter (e.g. Full 100: 198 → 183 nits). Stale first-read
  // stamps must not freeze the curve.
  if(lgAutoCalChartRef){
   const peakRd=(typeof meterFindSdr26PeakWhiteReading==='function')?meterFindSdr26PeakWhiteReading(list):null;
   if(peakRd&&!peakRd.synthetic_target){
    const peakY=(typeof meterReadingLuminanceNits==='function')?meterReadingLuminanceNits(peakRd):0;
    if(peakY>0) return peakRd;
   }
  }
  // SDR26 1D-DPG Limited: headroom-derived peak from 109 when no live peak row.
  const earlyHeadroomTargetY=lgAutoCalChartRef?meterLgHeadroomDerivedWhiteReferenceNits(list):null;
  if(lgAutoCalChartRef && !activeAutoCalReference && earlyHeadroomTargetY>0){
   const synthetic=meterSyntheticGreyWhiteReading(earlyHeadroomTargetY);
   if(synthetic) return synthetic;
  }
  const referenceList=(lgAutoCalChartRef&&activeAutoCalReference)?list.filter(rd=>!meterReadingIsAutoCalReferenceOnly(rd)):list;
 const activeAutoCalTargetY=activeAutoCalReference?meterAutoCalGreyscaleTargetWhiteReferenceNits(list):null;
 if(activeAutoCalTargetY>0){
  const synthetic=meterSyntheticGreyWhiteReading(activeAutoCalTargetY);
  if(synthetic) return synthetic;
 }
 const white=meterFindSeriesWhiteReading(lgAutoCalChartRef?referenceList:list);
 if(white) return white;
 const explicitTargetY=meterExplicitLgTargetWhiteReferenceNits(list);
 if(explicitTargetY>0){
  const synthetic=meterSyntheticGreyWhiteReading(explicitTargetY);
  if(synthetic) return synthetic;
 }
 const headroomTargetY=meterLgHeadroomDerivedWhiteReferenceNits(list);
 if(headroomTargetY>0){
  const synthetic=meterSyntheticGreyWhiteReading(headroomTargetY);
  if(synthetic) return synthetic;
 }
 const targetY=meterLgTargetWhiteReferenceNits(list);
 if(targetY>0){
  const synthetic=meterSyntheticGreyWhiteReading(targetY);
  if(synthetic) return synthetic;
 }
 const visibleWhite=meterFindSeriesWhiteReading(referenceList);
 if(visibleWhite) return visibleWhite;
 const cached=meterWhiteReading&&!meterWhiteReading.synthetic_target&&(!lgAutoCalChartRef||!meterReadingIsAutoCalReferenceOnly(meterWhiteReading))?meterReadingXYZ(meterWhiteReading):null;
 if(cached&&cached.Y>0) return meterWhiteReading;
 const measured=meterFindMeasuredWhiteReading();
 const measuredXyz=measured&&!measured.synthetic_target&&(!lgAutoCalChartRef||!meterReadingIsAutoCalReferenceOnly(measured))?meterReadingXYZ(measured):null;
 if(measuredXyz&&measuredXyz.Y>0) return measured;
 const fallbackY=Number(meterColorReferenceNits());
 if(Number.isFinite(fallbackY)&&fallbackY>0){
  const synthetic=meterSyntheticGreyWhiteReading(fallbackY);
  if(synthetic) return synthetic;
 }
 if(referenceList.length>0){
  const brightest=[...referenceList].sort((a,b)=>(meterReadingLuminanceNits(b)||0)-(meterReadingLuminanceNits(a)||0))[0];
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

function meterAutoCalGreyscaleTargetWhiteReferenceActive(readings){
 if(meterActiveSeriesType!=='greyscale'||!meterUseLgAutoCal26(meterActiveSeriesPoints)) return false;
 const phase=String(meterFullAutoCalPhase||'');
 const fullGreyscalePhase=phase==='first-greyscale'||phase==='touchup-greyscale'||phase==='post-3d-polish';
 const directAutoCal=!!((typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)||(typeof meterAutoCalPolling!=='undefined'&&meterAutoCalPolling));
 const fullGreyscaleAutoCal=!!((typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)&&fullGreyscalePhase);
 const autoCalPhase=String((typeof meterAutoCalPhase!=='undefined'?meterAutoCalPhase:'')||'');
 const actionPending=!!(typeof meterActionPending!=='undefined'&&meterActionPending);
 const seriesRunning=!!(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning);
 const pendingAutoCal=!!(actionPending&&!seriesRunning&&(directAutoCal||fullGreyscaleAutoCal||autoCalPhase==='running'||autoCalPhase==='luminance'));
 return !!(directAutoCal||fullGreyscaleAutoCal||pendingAutoCal);
}

function meterAutoCalGreyscaleTargetWhiteReferenceNits(readings){
 // Prefer LIVE measured peak (Full 100 / Limited 109) so the target curve
 // tracks each peak re-read. Headroom-derived 109 is Limited-only fallback.
 if(meterActiveSeriesType==='greyscale' && (typeof meterUseLgAutoCal26==='function') && meterUseLgAutoCal26(meterActiveSeriesPoints)){
  const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
  const peakRd=(typeof meterFindSdr26PeakWhiteReading==='function')?meterFindSdr26PeakWhiteReading(list):null;
  const peakY=peakRd?(typeof meterReadingLuminanceNits==='function'?meterReadingLuminanceNits(peakRd):0):0;
  if(peakY>0) return peakY;
  const headroomTargetY=meterLgHeadroomDerivedWhiteReferenceNits(list);
  if(headroomTargetY>0) return headroomTargetY;
 }
 if(!meterAutoCalGreyscaleTargetWhiteReferenceActive(readings)) return null;
 const list=Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[]);
 const targetY=meterLgTargetWhiteReferenceNits(list);
 return targetY>0?targetY:null;
}

function meterGreyscaleChartWhiteReference(readings){
 const list=meterGreyscaleReferenceReadings(readings);
 return meterEffectiveGreyscaleWhiteReference(list);
}

function meterColorReferenceNits(){
 // Operator Target White override (manual nits) is the chart peak when not
 // Use measured — same rule as meterGreyTargetPeak / color series targets.
 try{
  const tw=(typeof meterTargetWhiteLevel==='function')?meterTargetWhiteLevel():null;
  if(tw&&!tw.useMeasured&&tw.value!=null&&Number(tw.value)>0){
   return Math.max(1,Number(tw.value));
  }
 }catch(e){}
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
 // Manual Target White (cd/m²) from the calibration card is the absolute peak
 // for color/sat target luminance (target_Yn * peak). Honor it before any
 // measured-white cascade so Read Series / Read Selection match the operator
 // value even when White was not re-measured in this run.
 try{
  const tw=(typeof meterTargetWhiteLevel==='function')?meterTargetWhiteLevel():null;
  if(tw&&!tw.useMeasured&&tw.value!=null&&Number(tw.value)>0){
   return Math.max(1,Number(tw.value));
  }
 }catch(e){}
 // DV Absolute used to short-circuit to the mastering peak here, ignoring the
 // measured white entirely. With Target White = "Use measured" that produced
 // absurd targets on a ~713 cd/m2 panel (observed: Moderate Red targeting
 // 48359 cd/m2, dY -99.8%), because the DV target_Yn recompute can exceed 1
 // and was then multiplied by the 10000 cd/m2 PQ reference. When the operator
 // has asked for the measured white, honour it: fall through to the
 // measured-white cascade below, which already clamps DV to the mastering
 // peak so an absolute target can never exceed what the panel can show.
 {
  const _umw=document.getElementById('meterTargetWhiteUseMeasured');
  const _useMeasuredWhite=_umw?(_umw.checked!==false):true;
  if(meterChartIsDv() && meterDvMapModeValue()==='1' && !_useMeasuredWhite){
   return Math.max(1,meterColorReferenceNits());
  }
 }
 const activeColorSeries=(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations');
 const explicitLgTarget=activeColorSeries?null:meterExplicitLgTargetWhiteReferenceNits(meterReadings);
 if(explicitLgTarget>0) return Math.max(1,explicitLgTarget);
 const isSeriesWhite=(rd)=>{
  if(!rd) return false;
  const lum=((rd.luminance!=null && rd.luminance>0)?rd.luminance:rd.Y);
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
  const measured=(white.luminance!=null && white.luminance>0)?white.luminance:white.Y;
  if(meterChartIsDv()) return Math.max(1,Math.min(Math.max(1,meterChartMasterPeak()),measured));
  // Both the ColorChecker ("colors") and the saturation SWEEP now bake RELATIVE
  // target_Yn referenced to measured white: ColorChecker = reflectance/Yn; the
  // sat sweep bakes target_Yn = (level_linear/mx)*(10000/measured_white) so
  // target_Yn*measured = the patch's reachable (sub-peak, 50%-level) absolute
  // luminance, and the sweep's white patch (target_Yn=1) lands on the measured
  // peak instead of 10000. So both reference measured white. SDR/HLG always were.
  // Return the measured value directly (no Math.max(1, ...) clamp) so a dim
  // measured white (e.g. 0.59 nits from a real read) anchors the target
  // curve honestly. The previous clamp forced 0.59 -> 1, which silently
  // mis-targeted every color patch. Operators who want a mastering-100
  // reference for a dim read can set Target White = 100 (calibration card).
  return measured;
 }
 const lgTarget=meterColorSeriesTargetWhiteForRun(meterActiveSeriesType);
 if(lgTarget>0) return Math.max(1,lgTarget);
 return Math.max(1,meterColorReferenceNits());
}

function meterWrgbChromaticReferenceNits(){
 // Deprecated compatibility hook. A chart target must not be constructed
 // from current-series primary measurements: doing so changes prior targets
 // as R/G/B arrive and grades the display against its own output. All modes
 // and all built-in/custom color series now use their authored signal target
 // plus the run's white reference instead.
 return null;
}

function meterWrgbTargetCompensationSelected(){
 // Display Type owns this choice. Do not infer WRGB merely because a measured
 // primary sum is below white: the colour-series endpoints intentionally run
 // below peak, so that comparison falsely classifies every additive display
 // as WRGB. The independently selected meter profile is irrelevant here.
 let tech='';
 try{
  tech=(typeof getDisplayTechnology==='function')
   ?String(getDisplayTechnology()||'').toLowerCase()
   :String(((document.getElementById('meterDisplayType')||{}).value)||'').toLowerCase();
 }catch(e){ tech=''; }
 if(tech==='oled_generic'||/\b(?:wrgb|woled)\b/.test(tech)) return true;
 // The paired LG model is a stronger panel-architecture signal than the
 // generic Argyll "OLED" measurement mode. LG OLED televisions use the
 // white-subpixel color-volume response this endpoint model describes, while
 // QD-OLED / RGB OLED selections must retain the unbounded additive target.
 // This also keeps a C-series AutoCal correctly graded when the operator chose
 // OLED for meter refresh behavior and supplied a separate display CCSS.
 if(tech==='oled'){
  const state=window.lgStatusState||{};
  const model=String(state.modelName||state.model_name||state.productName||state.product_name||'').toLowerCase();
  if(model.indexOf('oled')!==-1&&!/qd[-_\s]*oled/.test(model)) return true;
 }
 return false;
}

// Per-primary HDR luminance ceilings derived from the current ColorChecker
// run's R/G/B endpoint reads. This is deliberately not a general
// chart reference: ordinary ColorChecker patches and saturation sweeps retain
// their authored, measurement-independent target. The ceilings are consumed
// only by the HDR ColorChecker 100% primary/secondary endpoint path below.
function meterWrgbPrimaryCeilings(){
 const out={};
 if(typeof meterActiveSeriesType==='undefined'||meterActiveSeriesType!=='colors') return out;
 if(!meterChartIsHdr()||meterChartIsDv()||!meterWrgbTargetCompensationSelected()) return out;
 const gamut=meterAnalysisGamut();
 const Yrow=(gamut&&gamut.rgbToXyz)?gamut.rgbToXyz[1]:[0.2627,0.6780,0.0593];
 const idx={red:0,green:1,blue:2};
 const curMode=(typeof meterActiveChartSignalMode==='function')
  ?String(meterActiveChartSignalMode()||'').toLowerCase():'';
 (Array.isArray(meterReadings)?meterReadings:[]).forEach(rd=>{
  if(!rd||!rd.series_color||Number(rd.sat_pct)<99.5) return;
  const color=String(rd.series_color).toLowerCase();
  if(!(color in idx)) return;
  const rdMode=String(rd.signal_mode||'').toLowerCase();
  if(curMode&&rdMode&&rdMode!==curMode) return;
  const codes=[
   (rd.r_code!=null)?rd.r_code:rd.r,
   (rd.g_code!=null)?rd.g_code:rd.g,
   (rd.b_code!=null)?rd.b_code:rd.b
  ];
  // series_color + sat_pct identifies the dedicated ColorChecker endpoint.
  // Do not require a near-full code: HDR10 endpoints are now encoded at the
  // measured-white PQ level (typically about 75% signal), not at 10,000 nits.
  if(codes.some(v=>v==null)) return;
  const i=idx[color];
  const measuredY=meterReadingLuminanceNits(rd);
  if(measuredY>0&&Yrow[i]>0&&!(out[i]>0)) out[i]=measuredY/Yrow[i];
 });
 return out;
}

// Target luminance normally comes directly from the authored patch stimulus:
// decode each channel and form target Y in the selected analysis gamut.
// Ordinary ColorChecker patches and saturation sweeps must not learn their
// target from the measurements they grade. The one display-reference exception
// is the six full-drive HDR ColorChecker endpoints on a selected WRGB OLED:
// those are bounded by the run's measured filtered-primary ceilings because
// the white-subpixel peak is physically unavailable to saturated colors.
// Greys remain referenced to measured white.
// Returns the decoded target Y (cd/m^2), or null when not applicable (non-PQ
// signal, or the stimulus codes cannot be resolved).

// Absolute DV color patches use PQ codes and therefore decode to absolute
// luminance. Relative DV alone uses the classic gamma-2.2 tunnel referenced
// to the measured series white.
function meterDvStimulusLinearChannel(code){
 const rng=meterColorTargetCodeRange();
 const norm=Math.max(0,Math.min(1,((Number(code)||0)-rng.min)/rng.span));
 if(norm<=0) return 0;
 if(meterDvMapModeValue()==='1'){
  const diffuseScale=(typeof meterHdrDiffuseScale==='function')?meterHdrDiffuseScale():1;
  return Math.min(
   meterChartPqDecodeNormalized(norm)*((diffuseScale>0)?diffuseScale:1),
   meterChartHdrPeak()
  );
 }
 return Math.pow(norm,2.2)*Math.max(1,meterColorSeriesReferenceNits());
}

function meterWrgbStimulusTargetY(reading){
 if(!reading||!meterChartIsPq()) return null;
 let r=(reading.r_code!=null)?reading.r_code:reading.r;
 let g=(reading.g_code!=null)?reading.g_code:reading.g;
 let b=(reading.b_code!=null)?reading.b_code:reading.b;
 if((r==null||g==null||b==null) && typeof meterCanonicalSeriesStep==='function'){
  const st=meterCanonicalSeriesStep(reading);
  if(st){
   if(r==null) r=(st.r_code!=null)?st.r_code:st.r;
   if(g==null) g=(st.g_code!=null)?st.g_code:st.g;
   if(b==null) b=(st.b_code!=null)?st.b_code:st.b;
  }
 }
 if(r==null||g==null||b==null) return null;
 const _dvLum=meterChartIsDv();
 let dr=_dvLum?meterDvStimulusLinearChannel(r):meterDecodeColorTargetChannel(r);
 let dg=_dvLum?meterDvStimulusLinearChannel(g):meterDecodeColorTargetChannel(g);
 let db=_dvLum?meterDvStimulusLinearChannel(b):meterDecodeColorTargetChannel(b);
 const gamut=(_dvLum&&meterDvMapModeValue()==='1')||(!_dvLum&&meterChartIsHdr())
  ?meterContainerGamut():meterAnalysisGamut();
 // An HDR ColorChecker endpoint on a WRGB OLED cannot reach the
 // decoded PQ peak through its filtered color subpixels. Grade those six
 // endpoint patches against the additive output established by the measured
 // R/G/B endpoints. Keep this narrowly scoped: DV has its stable authored
 // response model below, saturation sweeps use their own sub-peak stimulus,
 // and ordinary ColorChecker patches remain independent of measured results.
 const _hdrColorEndpoint=!_dvLum
  && typeof meterActiveSeriesType!=='undefined'&&meterActiveSeriesType==='colors'
  && meterChartIsHdr()&&meterWrgbTargetCompensationSelected()
  && !meterReadingIsGreyscale(reading)
  && reading.series_color!=null&&Number(reading.sat_pct)>=99.5;
 if(_hdrColorEndpoint){
  const ceil=meterWrgbPrimaryCeilings();
  // dr/dg/db are BT.2020 container channels. Apply WRGB primary ceilings in
  // the selected target-gamut basis instead, otherwise mixed P3-in-BT.2020
  // codes are mistaken for desaturated P3 channels during target grading.
  const endpointRgb=meterGamutColorEndpointRgb(String(reading.series_color));
  const endpointNits=Math.max(dr,dg,db);
  dr=Math.max(0,Number(endpointRgb[0])||0)*endpointNits;
  dg=Math.max(0,Number(endpointRgb[1])||0)*endpointNits;
  db=Math.max(0,Number(endpointRgb[2])||0)*endpointNits;
  if(ceil[0]>0) dr=Math.min(dr,ceil[0]);
  if(ceil[1]>0) dg=Math.min(dg,ceil[1]);
  if(ceil[2]>0) db=Math.min(db,ceil[2]);
  const targetGamut=meterAnalysisGamut();
  const targetXyz=linRgbToXyz(dr,dg,db,targetGamut.rgbToXyz);
  return (targetXyz&&Number.isFinite(targetXyz.Y)&&targetXyz.Y>=0)?targetXyz.Y:null;
 }
 const xyz=linRgbToXyz(dr,dg,db,gamut.rgbToXyz);
 if(!(xyz&&Number.isFinite(xyz.Y)&&xyz.Y>=0)) return null;
 if(_dvLum && meterDvMapModeValue()!=='1' && meterWrgbTargetCompensationSelected()){
  // Match the HDR WRGB target behavior: sub-peak/low-saturation content tracks
  // the authored signal, while saturated high-drive content rolls toward the
  // filtered-primary response. The previous DV-only model applied the 0.65
  // primary efficiency to every chromatic residual, which under-targeted
  // ColorChecker mixtures. This blend is the same saturation×drive² shape the
  // established HDR path used, but its endpoint factor comes from Display Type
  // so targets are stable from the first patch and never learn from the run.
  const common=Math.min(dr,dg,db);
  const Yrow=(gamut&&gamut.rgbToXyz)?gamut.rgbToXyz[1]:[0.2627,0.6780,0.0593];
  const commonY=common*(Number(Yrow[0])+Number(Yrow[1])+Number(Yrow[2]));
  const chromaticY=
   Number(Yrow[0])*Math.max(0,dr-common)+
   Number(Yrow[1])*Math.max(0,dg-common)+
   Number(Yrow[2])*Math.max(0,db-common);
  // The dedicated saturation sweep is authored at one fixed 50% drive and
  // has a directly validated endpoint response. Keep that sweep model
  // separate from ColorChecker/HDR reflectance blending.
  const isSaturationSweep=(typeof meterActiveSeriesType!=='undefined'&&meterActiveSeriesType==='saturations');
  if(isSaturationSweep){
   const maxChannel=Math.max(dr,dg,db);
   const cyanAxis=maxChannel>0&&dg>dr&&db>dr&&Math.abs(dg-db)<=maxChannel*0.002;
   const commonFraction=maxChannel>0?common/maxChannel:0;
   const efficiency=0.65+(cyanAxis?0.20*commonFraction:0);
   return commonY+efficiency*chromaticY;
  }
  const endpointY=commonY+0.65*chromaticY;
  const rng=meterColorTargetCodeRange();
  const signal=[r,g,b].map(code=>Math.max(0,Math.min(1,(Number(code)-rng.min)/rng.span)));
  const hi=Math.max(signal[0],signal[1],signal[2]);
  const lo=Math.min(signal[0],signal[1],signal[2]);
  if(!(hi>0)) return xyz.Y;
  const saturation=(hi-lo)/hi;
  const standardDvEndpointSignal=(2813-256)/(3760-256);
  const drive=hi/standardDvEndpointSignal;
  const weight=Math.max(0,Math.min(1,saturation*drive*drive));
  return xyz.Y+(endpointY-xyz.Y)*weight;
 }
 return xyz.Y;
}

// Reference mode for lattice/cube chart targets. 'display' (default) judges
// the panel against what it CAN do -- BT.2390 roll-off toward the measured
// white peak plus per-channel additive ceilings from the cube's own 100%
// corners. 'mastering' keeps the raw absolute stimulus decode for
// mastering-monitor QC. Lattice series only; ColorChecker/sat targets are
// governed by their own locked rules and never take this path.
function meterLatticeDisplayReference(){
 const el=document.getElementById('meterCubeReference');
 const v=el?String(el.value||'').toLowerCase():'';
 return v==='mastering'?'mastering':'display';
}

// Lattice corner readings from the current run. A cube lattice always
// includes the 100% W/R/G/B corners, so the run carries its own reference
// data: measured white peak + per-channel linear-RGB luminance ceilings
// (Y / Yrow, the same per-primary construction as the colour-series response).
// Only entries
// whose corner has actually been measured are present.
function meterLatticeCornerRefs(){
 const out={white:0,ceil:{}};
 const series=(typeof meterActiveLatticeSeries==='function')?meterActiveLatticeSeries():null;
 if(!series) return out;
 // Derive the wire range from the READINGS themselves: a lattice run always
 // spans its wire min..max, and the recorded codes are authoritative for THAT
 // run. Deriving from the current UI range settings broke corner detection
 // whenever the operator's range/bit-depth selection no longer matched the
 // run being charted (recorded full-range 0..1023 vs UI limited 64..940).
 let wireMin=Infinity,wireMax=-Infinity;
 (Array.isArray(meterReadings)?meterReadings:[]).forEach(rd=>{
  if(!rd) return;
  [ (rd.r_code!=null)?rd.r_code:rd.r, (rd.g_code!=null)?rd.g_code:rd.g, (rd.b_code!=null)?rd.b_code:rd.b ].forEach(v=>{
   const n=Number(v);
   if(!Number.isFinite(n)) return;
   if(n<wireMin) wireMin=n;
   if(n>wireMax) wireMax=n;
  });
 });
 if(!(wireMax>wireMin)) return out;
 const tol=Math.max(2,(wireMax-wireMin)*0.002);
 const lo=v=>Math.abs(Number(v)-wireMin)<=tol;
 const hi=v=>Math.abs(Number(v)-wireMax)<=tol;
 const gamut=meterAnalysisGamut();
 const Yrow=(gamut&&gamut.rgbToXyz)?gamut.rgbToXyz[1]:[0.2627,0.6780,0.0593];
 (Array.isArray(meterReadings)?meterReadings:[]).forEach(rd=>{
  if(!rd) return;
  const r=(rd.r_code!=null)?rd.r_code:rd.r;
  const g=(rd.g_code!=null)?rd.g_code:rd.g;
  const b=(rd.b_code!=null)?rd.b_code:rd.b;
  if(r==null||g==null||b==null) return;
  const y=meterReadingLuminanceNits(rd);
  if(!(y>0)) return;
  if(hi(r)&&hi(g)&&hi(b)){ if(!(out.white>0)) out.white=y; return; }
  if(hi(r)&&lo(g)&&lo(b)&&Yrow[0]>0){ if(!(out.ceil[0]>0)) out.ceil[0]=y/Yrow[0]; return; }
  if(lo(r)&&hi(g)&&lo(b)&&Yrow[1]>0){ if(!(out.ceil[1]>0)) out.ceil[1]=y/Yrow[1]; return; }
  if(lo(r)&&lo(g)&&hi(b)&&Yrow[2]>0){ if(!(out.ceil[2]>0)) out.ceil[2]=y/Yrow[2]; }
 });
 return out;
}

// Display-referenced target Y for a lattice node in HDR PQ. The raw stimulus
// decode assumes the panel tracks PQ all the way to the encoded value; a real
// panel BT.2390-rolls toward its peak, and chromatic output is capped by the
// additive per-channel ceilings (the WRGB W subpixel does not light for
// colour). 'mastering' mode and non-lattice series return the raw value; a
// run with no corner data yet also falls back to raw (never guess).
function meterLatticeDisplayTargetY(rawY,reading){
 if(!(rawY>0)) return rawY;
 if(!(typeof meterActiveLatticeSeries==='function'&&meterActiveLatticeSeries())) return rawY;
 if(meterLatticeDisplayReference()!=='display') return rawY;
 const refs=meterLatticeCornerRefs();
 let y=rawY;
 // Do not cap chromatic nodes from R/G/B corners measured in this run.
 // Custom/lattice targets must be stable before and after those corners.
 let peak=refs.white;
 // Mid-run fallback chain: the run's own white reading (worker measures white
 // for target Y before the lattice), then any measured white in the readings.
 if(!(peak>0)&&typeof meterWhiteReading!=='undefined'&&meterWhiteReading&&!meterWhiteReading.synthetic_target&&!meterWhiteReading.autocal_reference_only){
  const wy=meterReadingLuminanceNits(meterWhiteReading);
  if(wy>0) peak=wy;
 }
 if(!(peak>0)&&typeof meterFindMeasuredWhiteReading==='function'){
  const w=meterFindMeasuredWhiteReading();
  const wy=w?meterReadingLuminanceNits(w):0;
  if(wy>0) peak=wy;
 }
 if(peak>0){
  if(meterReadingIsGreyscale(reading)){
   // Neutral nodes: the panel tracks the signal then clips at ITS peak, and
   // the measured white IS the reference — a plain cap keeps the white corner
   // targeting itself (BT.2390 here would re-roll an already-white-clamped
   // value below the measured peak and charge white a phantom dY).
   y=Math.min(y,peak);
  } else {
   const master=(typeof meterChartMasterPeak==='function')?meterChartMasterPeak():0;
   if(master>0&&typeof bt2390Tonemap==='function') y=bt2390Tonemap(y,master,peak);
  }
 }
 return y;
}

function meterBlackReadingY(){
 return meterChartBlackLevel(Array.isArray(meterReadings)?meterReadings:[]);
}

function meterDisplayIsOled(){
 const dt=((document.getElementById('meterDisplayType')||{}).value||'').toLowerCase();
 return dt.indexOf('oled')!==-1;
}

// Infer chart black level. On OLED, true black can time out and be missing;
// use only true 0% greyscale reading (or 0 fallback) in every mode.
function meterChartBlackLevel(readings){
 // Operator Target Black override forces the black-floor reference.
 const _tb=(typeof meterTargetBlackLevel==='function')?meterTargetBlackLevel():null;
 // If the operator has explicitly entered a manual Target Black value
 // (including 0, which is the OLED-class default), respect it and ignore
 // any series/stamped measurement — the operator's number always wins over
 // the cached reading. `_tb.value>=0` covers the OLED default of 0 that the
 // earlier `_tb.value>0` check silently bypassed in favour of "measured".
 if(_tb && !_tb.useMeasured && _tb.value!=null && _tb.value>=0) return _tb.value;
 const gs=(Array.isArray(readings)?readings:[]).map(r=>meterNormalizeOledBlackReading(r))
  .filter(r=>r && meterReadingIsGreyscale(r) && r.luminance!=null && r.luminance>=0);
 // Prefer the CURRENT series's 0% IRE measurement, INCLUDING a measured
 // 0.000. That is a real result, not a failed read: the worker medians
 // several samples and only collapses the black to 0 when it is at or below
 // the ambient floor. The old `v>0` filter discarded it, so "Use measured"
 // stayed pinned to the PREVIOUS series' cached black and the chart showed a
 // lifted target against a measured 0.000 (Y error -100%, dE ITP ~18 at 0%).
 // The server stamp below now only covers the window before the 0% reading
 // lands, which is early -- the ladder measures 0% second, after 100%.
 const measuredBlack=gs.filter(r=>(r.ire||0)===0&&Number.isFinite(Number(r.luminance))&&Number(r.luminance)>=0)
  .map(r=>Number(r.luminance));
 if(measuredBlack.length>0) return Math.min(...measuredBlack);
 // A new colour series normally does not contain a black patch. Retain the
 // last measured black from the same live calibration context until its
 // reference pre-read replaces it.
 if(meterSeriesBaselineBlack){
  const baseline=Number(meterSeriesBaselineBlack.luminance!=null
   ?meterSeriesBaselineBlack.luminance:meterSeriesBaselineBlack.Y);
  if(Number.isFinite(baseline)&&baseline>=0) return baseline;
 }
 // Fall back to the server-stamped cached 0% black. The webui stamps this
 // on every step at series start so the chart has a sensible target even
 // before any 0% reading lands in the current series (or when that reading
 // is timed-out to 0 on OLED).
 const stamped=gs.map(r=>r.series_target_black_y).filter(v=>v!=null&&Number.isFinite(v)&&v>=0);
 if(stamped.length>0) return Math.min(...stamped);
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
// series builders. DV greyscale patches use the same direct 16-235 ramp for
// Absolute and Relative; chart targets still analyze Relative against gamma 2.2.
// Does the Dolby Vision greyscale target curve use ST 2084/PQ right now?
// Honors the operator's Target Gamma dropdown outside an active calibration;
// during a calibration the solver pins the curve from dv_map_mode (relative=2.2,
// absolute=st2084).
function meterDvUsesPqTargetCurve(){
 if(typeof meterChartIsDv!=='function' || !meterChartIsDv()) return false;
 const calActive=(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
  ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
  ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
  ||(typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning);
 if(calActive) return meterDvMapModeValue()!=='2';
 const sel=(typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||''));
 return String(sel||'').toLowerCase()==='st2084';
}

function meterTargetLinearToSignal(v){
 const c=Math.max(0,Math.min(1,v||0));
 if(c<=0) return 0;
 if(meterChartIsDv()){
  // Relative DV treats the signal fraction as the linear target directly
  // (the DV engine applies its own tonemap on top of a 2.2-encoded signal).
  // ST 2084 / absolute DV should follow the PQ OETF, so honor the operator's
  // Target Gamma dropdown selection outside an active calibration.
  if(meterDvUsesPqTargetCurve()) return meterChartPqEncodeNormalized(c*10000);
  return c;
 }
 if(meterChartIsHlg()) return hlgOetf(c);
 const sel=(typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||'bt1886'));
 if(sel==='srgb') return c<=0.0031308 ? 12.92*c : 1.055*Math.pow(c,1/2.4)-0.055;
 const g=(sel==='bt1886')?2.4:(parseFloat(sel)||2.2);
 return Math.pow(c,1/g);
}
function meterTargetSignalToLinear(v){
 const c=Math.max(0,Math.min(1,v||0));
 if(c<=0) return 0;
 if(meterChartIsDv()){
  // See meterTargetLinearToSignal: relative DV is identity; ST 2084/absolute
  // follows the PQ EOTF when the operator selects it (outside calibration).
  if(meterDvUsesPqTargetCurve()) return meterChartPqDecodeNormalized(c);
  return c;
 }
 if(meterChartIsHlg()){
  const peak=meterChartHdrPeak();
  const minY=meterChartMasterMin();
  return hlgSignalToDisplayLinear(c,minY,peak);
 }
 const sel=(typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||'bt1886'));
 if(sel==='srgb') return c<=0.04045 ? c/12.92 : Math.pow((c+0.055)/1.055,2.4);
 // An st2084 target selection means PQ decode regardless of how the chart
 // classified the wire — parseFloat('st2084') is NaN and silently fell back
 // to gamma 2.2, which quietly mis-decoded every target when a stale series
 // context dropped the chart out of PQ mode.
 if(sel==='st2084') return meterChartPqDecodeNormalized(c);
 const g=(sel==='bt1886')?2.4:(parseFloat(sel)||2.2);
 return Math.pow(c,g);
}

function meterGreyscaleTargetYnForCode(code){
 const signal=(typeof meterGreySignalFractionFromCode==='function')?meterGreySignalFractionFromCode(code):null;
 if(!Number.isFinite(Number(signal))) return null;
 return Math.max(0,meterTargetSignalToLinear(signal));
}

function meterDvClassicColorCheckerScale(){
 return 0.68;
}

function meterEncodeColorCheckerLinear(linear,referenceNits){
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
 let clamped=Math.max(0,Math.min(1,linear||0));
 const dvAbsolute=meterChartIsDv()&&meterDvMapModeValue()==='1';
 if(meterChartIsDv()&&!dvAbsolute) clamped*=meterDvClassicColorCheckerScale();
 // HDR PQ encode must use the same peak-luminance reference the server uses
 // (cc_ref = max_luma in webui_meter_series_start, typically 1000). Previously
 // hardcoded to *100 nits, which produced dimmer preview codes than the actual
 // patch the panel displayed during the series run -- so the client-side
 // meterSeriesSteps cache (used for thumbnail refresh, meterDisplayPatch, and
 // meterFreshSeriesStep on single-reread of a thumbnail) ended up re-sending a
 // different stimulus than the series, drifting the measured x/y and the
 // chart dE. The active series peak comes from the server snapshot first
 // (meterActiveSeriesMaxLuma, stamped when the series started) and falls
 // back to meterChartHdrPeak() (config/live peak). Without an active series
 // peak the fallback still uses 100 (the SDR-style assumption), matching the
 // historical behavior for non-HDR builds.
 if(meterChartIsPq()&&(!meterChartIsDv()||dvAbsolute)){
  const active=(typeof meterActiveSeriesMaxLuma!=='undefined'&&Number(meterActiveSeriesMaxLuma)>0)?Number(meterActiveSeriesMaxLuma):0;
  const peak=(active>0)?active:((typeof meterChartHdrPeak==='function')?meterChartHdrPeak():0);
  const requestedRef=Number(referenceNits);
  const ref=(Number.isFinite(requestedRef)&&requestedRef>0)?requestedRef:((peak>0)?peak:100);
  return Math.round(min+meterChartPqEncodeNormalized(clamped*ref)*span);
 }
 if(meterChartIsDv()) return Math.round(min+Math.pow(clamped,1/2.2)*span);
 return Math.round(min+meterTargetLinearToSignal(clamped)*span);
}

function meterDecodeColorCheckerSignal(signal){
 let clamped=Math.max(0,Math.min(1,signal||0));
 if(meterChartIsPq()&&(!meterChartIsDv()||meterDvMapModeValue()==='1')) return meterChartPqDecodeNormalized(clamped)/100;
 if(meterChartIsDv()) return Math.pow(clamped,2.2)/meterDvClassicColorCheckerScale();
 return meterTargetSignalToLinear(clamped);
}

function meterEncodeColorCheckerFullSatChannel(active){
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
 if(!active) return min;
 if(meterChartIsPq()&&(!meterChartIsDv()||meterDvMapModeValue()==='1')) return Math.round(min+meterChartPqEncodeNormalized(100)*span);
 return min+span;
}

function meterFullSatChannelIsActive(linear){
 return Number(linear||0) > 1e-6;
}

function meterEncodeSaturationLinear(linear,colorName){
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 if(meterChartIsPq()&&(!meterChartIsDv()||meterDvMapModeValue()==='1')) return Math.round(min+meterChartPqEncodeNormalized(clamped*10000)*span);
 if(meterChartIsDv()) return Math.round(min+Math.pow(clamped,1/2.2)*span);
 return Math.round(min+meterTargetLinearToSignal(clamped)*span);
}

const METER_HCFR_HDR_DIFFUSE_WHITE_NITS=94.37844;
function meterHcfrQuantizedSignal(signal){
 // HCFR authors HDR color patches on the 8-bit legal-video lattice even
 // when the generator transport is 10-bit. Preserve those 219 intervals.
 return Math.round(Math.max(0,Math.min(1,Number(signal)||0))*219)/219;
}

function meterHcfrCodeFromSignal(signal){
 const min=meterChromaPatchRangeMin();
 const span=meterChromaPatchRangeSpan();
 return Math.round(min+meterHcfrQuantizedSignal(signal)*span);
}

function meterHcfrSaturationLinearLevel(){
 if(meterChartIsPq()&&!meterChartIsDv()) return METER_HCFR_HDR_DIFFUSE_WHITE_NITS/10000;
 // HCFR has no Dolby Vision generator mode. Keep the existing PGenerator DV
 // adaptation at a safe half-linear stimulus.
 if(meterChartIsDv()) return 0.5;
 // HCFR SDR and HLG saturation patterns are built at unit-linear reference.
 return 1;
}

function meterEncodeHcfrSaturationLinear(linear){
 const clamped=Math.max(0,Math.min(1,Number(linear)||0));
 let signal=0;
 if(meterChartIsPq()&&!meterChartIsDv()) signal=meterChartPqEncodeNormalized(clamped*10000);
 else if(meterChartIsHlg()) signal=hlgOetf(clamped);
 else if(meterChartIsDv()) signal=Math.pow(clamped,1/2.2);
 else signal=Math.pow(clamped,1/2.22);
 return meterHcfrCodeFromSignal(signal);
}

function meterGamutStimulusLinearLevel(){
 if(meterChartIsPq()&&!meterChartIsDv()) return 1;
 // Standard DV gamut endpoints use a fixed 50% tunnel code. In Absolute mode
 // that code is PQ and must be decoded before the per-channel PQ encoder is
 // applied; Relative mode retains the gamma-tunnel linear level.
 if(meterChartIsDv()) return meterDvMapModeValue()==='1'
  ? meterChartPqDecodeNormalized(0.5)/10000
  : 0.5;
 return meterTargetSignalToLinear(meterColorLevelPercent()/100);
}

function meterSaturationStimulusLinearLevel(colorName){
 const actualPercent=meterActualSignalPercent(meterColorLevelPercent())/100;
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartPqDecodeNormalized(actualPercent)/10000;
 if(meterChartIsDv()) return meterDvMapModeValue()==='1'
  ? meterChartPqDecodeNormalized(actualPercent)/10000
  : 0.5;
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

function meterSaturationSolveGamut(){
 if(meterChartIsDv() && meterDvMapModeValue()==='1') return meterContainerGamut();
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

// ColorChecker's appended 100% primaries/secondaries are gamut endpoints at
// the ColorChecker endpoint drive (HDR10 measured white, DV 50%, SDR/HLG 75%).
// They deliberately do not use the native saturation sweep's fixed 50% HDR
// drive.
// Keep this client builder aligned with webui_meter_series_start so Read
// Selection and a full series send the same patch for the same thumbnail.
function meterBuildColorCheckerEndpointStepRgb(colorName){
 const solveGamut=meterSaturationSolveGamut();
 // Endpoint chromaticity follows the selected analysis gamut. HDR10 normally
 // expresses a P3-D65 endpoint as mixed RGB inside its BT.2020 wire container.
 // Keep this aligned with the server builder so a thumbnail reread cannot
 // silently substitute a different gamut axis.
 const hdr10=meterChartIsPq()&&!meterChartIsDv();
 const endpoint=meterGamutColorEndpointXY(colorName,meterSaturationAxisGamut());
 const x=endpoint.x,y=endpoint.y;
 if(!(y>0)) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 // The full-series server anchors HDR10 endpoint codes to the measured series
 // white so they stay inside the characterized range. Apply the same level to
 // browser-built Read Selection steps; meterGamutStimulusLinearLevel() is 1.0
 // for HDR10 and would otherwise restore the old 10,000-nit code path.
 const endpointReferenceNits=hdr10?Number(meterColorSeriesReferenceNits()):0;
 const level=hdr10
  ? Math.max(0,Math.min(1,(endpointReferenceNits>0?endpointReferenceNits:1000)/10000))
  : meterGamutStimulusLinearLevel();
 return coeffs.map(v=>meterEncodeSaturationLinear(Math.max(0,v/maxCoeff)*level,colorName));
}

function meterBuildColorCheckerEndpointTargetStepMeta(colorName){
 const level=meterGamutStimulusLinearLevel();
 const rgb=meterBuildFullGamutTargetLinearRgb(colorName).map(v=>v*level);
 const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],meterTargetSolveGamut().rgbToXyz);
 const sum=xyz.X+xyz.Y+xyz.Z;
 const wp=meterTargetWhitePoint();
 return {
  target_x:sum>0?xyz.X/sum:wp.x,
  target_y:sum>0?xyz.Y/sum:wp.y,
  target_Yn:Math.max(0,xyz.Y||0)
 };
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

function meterBuildHcfrSaturationStep(colorName,satPercent){
 const solveGamut=meterSaturationSolveGamut();
 const targetGamut=meterAnalysisGamut();
 const sat=Math.max(0,Math.min(100,Number(satPercent)||0))/100;
 const endpoint=meterGamutColorEndpointXY(colorName,meterSaturationAxisGamut());
 const wp=meterTargetWhitePoint();
 const x=wp.x+sat*(endpoint.x-wp.x),y=wp.y+sat*(endpoint.y-wp.y);
 const endpointRgb=meterGamutColorEndpointRgb(colorName);
 const endpointXyz=linRgbToXyz(endpointRgb[0],endpointRgb[1],endpointRgb[2],targetGamut.rgbToXyz);
 const K=Math.max(0,Number(endpointXyz.Y)||0);
 const coeffs=y>0?xyzToLinRgb(x/y,1,(1-x-y)/y,solveGamut.xyzToRgb):[0,0,0];
 const level=meterHcfrSaturationLinearLevel();
 const linear=coeffs.map(v=>Math.max(0,Math.min(1,v*K))*level);
 const rgb=linear.map(v=>meterEncodeHcfrSaturationLinear(v));
 let targetYn=level*K;
 if(meterChartIsPq()&&!meterChartIsDv()){
  const whiteRef=Number(meterColorSeriesReferenceNits());
  if(whiteRef>0) targetYn=(METER_HCFR_HDR_DIFFUSE_WHITE_NITS/whiteRef)*K;
 }
 return {ire:satPercent,r:rgb[0],g:rgb[1],b:rgb[2],name:colorName+' '+satPercent+'%',series_color:colorName,sat_pct:satPercent,target_x:x,target_y:y,target_Yn:targetYn,series_mode:'hcfr-constant-luminance'};
}

function meterBuildSaturationStimulusLinearRgb(colorName,satPercent){
 const solveGamut=meterSaturationSolveGamut();
 const axisGamut=meterSaturationAxisGamut();
 let sat=Math.max(0,Math.min(100,satPercent||0))/100;
 if(meterChartIsDv()&&meterDvMapModeValue()!=='1') sat=meterDvRelativeSaturationFraction(sat);
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
  let scale=meterWrgbChromaticReferenceNits();
  if(!(scale>0)) scale=meterColorSeriesReferenceNits();
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

// Bit-depth-aware code range for COLOR / SATURATION target decode, mirroring
// meterGreyCodeRange. Since the 2026-06-29 max_bpc fix (commit 45c0ea3d) the
// color/saturation series builders emit 10-bit patch codes (Limited 64..940,
// Full 0..1023, with input_max=1023 stamped on every step) on a max_bpc=10
// link. Those codes MUST be normalized against the 10-bit range: decoding them
// with the 8-bit range (16..235 / 0..255) clamps every chromatic channel to
// signal 1.0, which on a PQ chart decodes to the panel peak -- so every HDR
// ColorChecker / saturation patch target collapsed to ~1000 cd/m^2 instead of
// its 203-nit-referenced per-patch value. 12-bit links coerce to 10-bit
// (meterPatchBitDepth). The meterActiveSeriesCodesAre8Bit() guard keeps a
// genuinely 8-bit series (white code <=255) on the 8-bit range even when the
// conf reports max_bpc=10, matching the greyscale path.
function meterColorTargetCodeRange(){
 // Standard Dolby Vision carries legal 12-bit source codes inside its
 // 8-bit RGB tunnel. The wire max_bpc is therefore not the source-code
 // precision: every DV color/saturation series uses 256..3760.
 if(meterChartIsDv()) return {min:256,span:3504};
 const limited=meterPatchUsesVideoRange();
 const tenBit=(meterPatchBitDepth()===10) &&
  !(typeof meterActiveSeriesCodesAre8Bit==='function' && meterActiveSeriesCodesAre8Bit());
 if(tenBit) return limited?{min:64,span:876}:{min:0,span:1023};
 return limited?{min:16,span:219}:{min:0,span:255};
}

// Resolve the display peak used to grade HDR color-series luminance. PQ patch
// codes remain absolute below the roll-off knee, but high-luminance colors
// must roll toward the same measured/manual Target White as greyscale. The
// mastering peak remains the native-PQ fallback only while Target White is
// set to Use measured.
function meterHdrColorTargetPeak(){
 let reference=(typeof meterChartHdrPeak==='function')?meterChartHdrPeak():1000;
 try{
  const selected=(typeof meterColorSeriesReferenceNits==='function')?Number(meterColorSeriesReferenceNits()):NaN;
  if(Number.isFinite(selected)&&selected>0) reference=selected;
 }catch(e){}
 if(typeof meterGreyTargetPeak==='function'){
  const resolved=Number(meterGreyTargetPeak(reference));
  if(Number.isFinite(resolved)&&resolved>0) return resolved;
 }
 return Math.max(1,reference);
}

function meterDecodeColorTargetChannel(code,opts){
 const rng=meterColorTargetCodeRange();
 const norm=Math.max(0,Math.min(1,((Number(code)||0)-rng.min)/rng.span));
 if(meterChartIsPq()&&(!meterChartIsDv()||meterDvMapModeValue()==='1')){
  const diffuseScale=(typeof meterHdrDiffuseScale==='function')?meterHdrDiffuseScale():1;
  const nits=meterChartPqDecodeNormalized(norm)*((diffuseScale>0)?diffuseScale:1);
  // The per-channel clamp to the HDR peak keeps LUMINANCE targets bounded,
  // but it DISTORTS THE HUE of any mix with a channel above the mastering
  // peak: 100/75/25 truly encodes ~10:1 R:G linear light (orange), yet with
  // R clamped 10000->1000 and G (981) untouched the "target" said ~1:1
  // (yellow) — nowhere near what the signal means or what a panel shows.
  // Chromaticity consumers pass unclamped:true to keep the encoded ratios.
  if(opts&&opts.unclamped) return nits;
  const peak=meterHdrColorTargetPeak();
  if(typeof meterChartBt2390Enabled==='function'&&meterChartBt2390Enabled()
   &&typeof bt2390Tonemap==='function'){
   const master=(typeof meterChartMasterPeak==='function')?Number(meterChartMasterPeak()):Number(meterChartHdrPeak());
   if(master>0) return bt2390Tonemap(Math.min(nits,master),master,peak);
  }
  return Math.min(nits,peak);
 }
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
 // Hue from the UNCLAMPED per-channel decode — the signal's true encoded
 // ratios (see meterDecodeColorTargetChannel). Luminance targets stay on the
 // clamped path via targetColorXYZAbs.
 const gamut=meterAnalysisGamut();
 const xyz=linRgbToXyz(
  meterDecodeColorTargetChannel(r,{unclamped:true}),
  meterDecodeColorTargetChannel(g,{unclamped:true}),
  meterDecodeColorTargetChannel(b,{unclamped:true}),
  gamut.rgbToXyz
 );
 const s=xyz.X+xyz.Y+xyz.Z;
 const wp=meterTargetWhitePoint();
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:wp.x,y:wp.y};
}

function meterDvAbsoluteReadingTargetY(reading){
 if(!(meterChartIsDv()&&meterDvMapModeValue()==='1')||!reading||!meterReadingIsGreyscale(reading)) return null;
 const stamped=Number(reading.dv_absolute_target_y);
 if(Number.isFinite(stamped)&&stamped>=0) return stamped;
 const white=Number(reading.dv_absolute_white_y);
 const stim=meterReadingAnalysisIre(reading);
 if(Number.isFinite(white)&&white>0&&Number.isFinite(Number(stim))){
  return meterDvAbsoluteChartTargetLuminance(Number(stim),white,null);
 }
 return null;
}

function meterGreyscaleTargetYFromYn(targetYn,refY,blackLevel){
 const tYn=Number(targetYn);
 const peak=(refY>0)?refY:meterColorReferenceNits();
 if(!Number.isFinite(tYn)||tYn<0||!(peak>0)) return null;
 const Lb=Math.max(0,Number(blackLevel)||0);
 if(tYn<=0) return Lb>0?Lb:0;
 // SDR headroom clamp: signals > 1.0 encode headroom that the panel
 // cannot lift above peak white. The SDR26 step table bakes the
 // OLD gamma-2.2 target_Yn for the 105 anchor as (105/100)^2.2 =
 // 1.1133, which a chart that reads target_Yn through this fn then
	// scales by the calibrated 109 peak -- producing a target line
	// that SPIKES ABOVE the 109 peak at 105 IRE (e.g. 1.1133 * 188
	// = 209 nits on a panel that maxes at 188 nits at 109). The chart
	// renders that spike as a "PQ curve" -- sharp rise at low IRE,
	// plateau near top -- even though the actual target_gamma is
	// bt1886. Clamp tYn to 1.0 for SDR signals above 1.0 so the
	// chart's target line stays at or below the calibrated peak.
 // (HDR/DV signals above 1.0 are meaningful -- 109% headroom codes
	// higher than peak-white for HDR tone mapping -- and are NOT
	// clamped here.)
 const isSdrMode=!(typeof meterChartIsHdr==='function'&&meterChartIsHdr())&&!(typeof meterChartIsDv==='function'&&meterChartIsDv());
 const tYnClamped=(isSdrMode && tYn>1.0) ? 1.0 : tYn;
 const targetGamma=(typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||''));
 // Gamma-aware decode. The worker stores target_Yn as the LINEAR luminance
 // ratio from a pure power/EOTF without the live black floor:
 //   SDR26 / 2.2: signal^2.2
 //   2.4 / bt1886: signal^2.4  ($target_signal_to_linear; NOT bt1886Eotf/peak)
 //   srgb: srgbEotf(signal)
 //   HDR/PQ: handled upstream by meterChartTargetLuminance
 // For power gammas, chart y = tYn * peak (optionally floored at Lb). For
 // BT.1886 with a real measured black, recover signal from the power-law
 // stamp and re-apply bt1886Eotf(signal, peak, Lb) so Absolute-Y targets
 // lift with the black floor instead of treating linear tYn as a signal.
  if(!meterChartIsHdr()&&!meterChartIsDv()){
   if(targetGamma==='2.2'){
    // tYn already encodes gamma 2.2 (= signal^2.2 = target_luminance /
    // white_y). Multiplying by peak recovers target_luminance directly.
    // The previous `pow(tYn, 1/2.2) * peak` round-tripped BACK to signal
    // first (giving peak * signal, e.g. 108 on a 237-peak panel at 50%
    // IRE -- signal = 0.459, target = 42.7, but the chart showed 108).
    // SDR26 (signal = stimulus/109) and the legacy SDR (signal =
    // stimulus/100) both use the same tYn encoding -- the worker
    // normalises the input signal against its own peak divisor before
    // applying the EOTF, so tYn is gamma-encoded in either case and
    // multiplying by peak gives the correct target.
    const y=Math.max(0,tYnClamped)*peak;
    if(Number.isFinite(y)&&y>=0) return Math.max(y,Lb);
   } else if(targetGamma==='2.4'){
    const y=Math.max(0,tYnClamped)*peak;
    if(Number.isFinite(y)&&y>=0) return Math.max(y,Lb);
   } else if(targetGamma==='srgb'){
    // sRGB inverse: tYn is the linear ratio (worker stores
    // srgbEotf(signal) = target_luminance / white_y). To recover the
    // signal, apply the sRGB inverse EOTF, then re-apply sRGB EOTF
    // scaled to peak. The previous `srgbEotf(signal) * peak` was right
    // structurally but the `signal = srgbEotfInv(tYn)` round-trip was
    // correctly applied -- the sRGB branch had the right round-trip
    // shape. Leave as is.
    const lin=Math.max(0,Math.min(1,tYnClamped));
    const signal=lin<=0.0031308?lin*12.92:1.055*Math.pow(lin,1/2.4)-0.055;
    const y=srgbEotf(Math.max(0,Math.min(1,signal)))*peak;
    if(Number.isFinite(y)&&y>=0) return Math.max(y,Lb);
   } else if(targetGamma==='bt1886'&&Lb>0){
    // Worker stamps power-law tYn = signal^2.4 (no black). Recover signal
    // and apply BT.1886 with the live black floor so mid greys stay near
    // power*peak while darks lift. The old a*(tYn+b)^g treated linear tYn
    // as a signal and crushed 40/50% targets to ~1 nit (ΔE ITP 100+).
    const g=2.4;
    const t=Math.max(0,Math.min(1,tYnClamped));
    const signal=Math.pow(t,1/g);
    if(typeof bt1886Eotf==='function'){
     const y=bt1886Eotf(signal,peak,Lb);
     if(Number.isFinite(y)&&y>=0) return y;
    }
    const lwRoot=Math.pow(peak,1/g);
    const lbRoot=Math.pow(Lb,1/g);
    const denom=lwRoot-lbRoot;
    if(denom>0){
     const a=Math.pow(denom,g);
     const b=lbRoot/denom;
     const y=a*Math.pow(Math.max(0,signal)+b,g);
     if(Number.isFinite(y)&&y>=0) return y;
    }
   }
  }
 // Floor the target at the operator's black level so the curve and dE honor
 // the Target Black override across all IREs, not just 0%. When Lb=0 this is
 // a no-op (Math.max(tYn*peak,0)==tYn*peak). For Lb>0, low-signal IREs whose
 // PQ target would fall below the black floor are clamped to Lb, matching the
 // physical constraint that the display cannot produce less than its black
 // floor. This is analogous to how the BT.1886 path above maps to [Lb,peak].
 return Math.max(tYnClamped*peak,Lb);
}

function meterGreyChartTargetXYZForReading(reading){
 const wp=meterTargetWhitePoint();
 // SDR26 peak (Limited 109 / Full 100): chroma-only — target at measured Y.
 if(typeof meterReadingIsSdr26LegalPeak==='function' && meterReadingIsSdr26LegalPeak(reading)){
  const mY=(typeof meterReadingLuminanceNits==='function')?meterReadingLuminanceNits(reading):(reading&&reading.Y)||0;
  if(Number.isFinite(mY) && mY>0) return {X:wp.X*mY,Y:mY,Z:wp.Z*mY};
  return {X:0,Y:0,Z:0};
 }
 let refWhite=null;
 try{ refWhite=meterGreyscaleChartWhiteReference(meterReadings); }catch(e){}
 const refY=refWhite?meterReadingLuminanceNits(refWhite):null;
 const peak=meterGreyTargetPeak((refY>0)?refY:meterColorReferenceNits());
 const black=meterBlackReadingY();
 const step=(typeof meterCanonicalSeriesStep==='function')?meterCanonicalSeriesStep(reading):null;
 let ire=meterGreyscaleTargetSlotIre(reading);
 // Zero is a real target slot, not a missing value. In particular, a black
 // neutral inside a color series has a category/index IRE on its canonical
 // color step; falling through on numeric zero would target that index instead
 // of black.
 if(ire==null&&step) ire=meterGreyscaleTargetSlotIre(step);
 const code=(reading&&reading.r_code!=null)?reading.r_code:(reading&&reading.r!=null?reading.r:(step?(step.r_code!=null?step.r_code:step.r):null));
 const measuredDvTargetY=meterDvAbsoluteReadingTargetY(reading);
 const Y=measuredDvTargetY!=null?measuredDvTargetY:meterGreyTargetLuminance(ire!=null?ire:(reading&&reading.ire||0),peak,black||0,code);
 return {X:wp.X*Y,Y:Y,Z:wp.Z*Y};
}

function meterTargetXYZForReading(reading){
	 if(!reading) return {X:0,Y:0,Z:0};
	 // SDR26 peak (Limited 109 legal / Full 100): NO luminance target --
	 // peak calibrates RGB balance, chroma only. Same rule HDR applies to
	 // its 100% peak. Return D65 chromaticity at the MEASURED luminance
	 // (not {0,0,0}) so ITP dE is the chromaticity gap to D65; meterDeltaE
	 // drops the dI term via meterReadingIsSdr26LegalPeak. Matches worker
	 // delta_e_itp_chroma_only. Limited 100% legal-white (ddc_target_ire 99)
	 // is NOT a peak and must not take this path.
	 try{
	  if(typeof meterReadingIsSdr26LegalPeak==='function' && meterReadingIsSdr26LegalPeak(reading)){
	   const _mY=(typeof meterReadingLuminanceNits==='function')?meterReadingLuminanceNits(reading):(reading.Y||0);
	   const _wp=(typeof meterTargetWhitePoint==='function')?meterTargetWhitePoint():{x:0.3127,y:0.329};
	   if(Number.isFinite(_mY) && _mY>0){
	    return {X:_wp.X*_mY, Y:_mY, Z:_wp.Z*_mY};
	   }
	   return {X:0, Y:0, Z:0};
	  }
	 }catch(e){}
	 const absX=Number(reading.target_X);
	 const absY=Number(reading.target_Y);
	 const absZ=Number(reading.target_Z);
	 if(Number.isFinite(absX)&&Number.isFinite(absY)&&Number.isFinite(absZ)&&absY>=0){
	  return {X:absX,Y:absY,Z:absZ};
	 }
	 let targetMeta=null;
	 let targetStep=null;
	 if((reading.target_x==null||reading.target_y==null||reading.target_Yn==null) && typeof meterCanonicalSeriesStep==='function'){
	  targetStep=meterCanonicalSeriesStep(reading);
	  if(targetStep&&(targetStep.target_x!=null||targetStep.target_y!=null||targetStep.target_Yn!=null)) targetMeta=targetStep;
	 }
 // SDR26 109% legal-peak fallback: when the target XYZ lookup returned
 // {0,0,0} (the no-target-Y sentinel from the early-return above) but
 // the operator has the "Include luminance error" toggle on, we still
 // need a usable target so the dE chart doesn't blow up to 400+. The
 // chroma-only dE path (deltaEITPChromaOnly) uses this target's X/Y/Z
 // purely for the Ct/Cp rotation -- the dI term is dropped, so the
 // absolute target Y doesn't matter for the dE. Returning the target
 // chromaticity at the calibrated peak Y keeps the chart target line
 // visible at the legal peak without re-introducing a luminance error.
 let tx=parseFloat(reading.target_x!=null?reading.target_x:(targetMeta?targetMeta.target_x:null));
 let ty=parseFloat(reading.target_y!=null?reading.target_y:(targetMeta?targetMeta.target_y:null));
 const tYn=parseFloat(reading.target_Yn!=null?reading.target_Yn:(targetMeta?targetMeta.target_Yn:null));
 if((!Number.isFinite(tx)||!Number.isFinite(ty)||ty<=0)&&meterReadingIsGreyscale(reading)&&Number.isFinite(tYn)&&tYn>=0){
  const wp=meterTargetWhitePoint();
  tx=wp.x;
  ty=wp.y;
 }
 // Custom user series: a per-patch user-entered target luminance (cd/m²) is
 // authoritative — return the target chromaticity at that absolute Y so charts
 // and dE use exactly what the operator typed, independent of reference-white
 // drift between step build time and chart time.
 let customTargetNits=Number(reading.custom_target_nits);
 if(!(Number.isFinite(customTargetNits)&&customTargetNits>0)&&typeof meterCanonicalSeriesStep==='function'){
  const customStep=meterCanonicalSeriesStep(reading);
  if(customStep) customTargetNits=Number(customStep.custom_target_nits);
 }
 if(Number.isFinite(customTargetNits)&&customTargetNits>0&&Number.isFinite(tx)&&Number.isFinite(ty)&&ty>0){
  return {X:customTargetNits*tx/ty,Y:customTargetNits,Z:customTargetNits*(1-tx-ty)/ty};
 }
 if(Number.isFinite(tx)&&Number.isFinite(ty)&&ty>0&&Number.isFinite(tYn)&&tYn>=0){
  let refY=meterColorSeriesReferenceNits();
  let _wrgbStimY=null;
  const _activeColorSeries=(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations');
  const _greyReading=meterReadingIsGreyscale(reading);
  // WRGB OLED luminance. A white-subpixel panel tracks the PQ signal, so
  // ColorChecker reflectance patches and saturation sweeps target the absolute
  // value their stimulus encodes. Only the six full-drive HDR ColorChecker
  // endpoints are bounded by the measured filtered-primary ceilings, keeping a
  // full-code secondary from exceeding the achievable additive primary sum.
  // Chromaticity always stays on target_x/target_y.
  // Greys are clamped to measured white (white uses the W subpixel and exceeds
  // the primary sum). The additive reference (meterWrgbChromaticReferenceNits)
  // remains only as the non-PQ / no-codes fallback for chromatic patches.
  // WRGB OLED chromatic refY (additive primary sum) is ONLY used by the
  // chromatic-target fallback path (no stimulus codes / non-PQ). The
  // PQ stimulus-decode path below is measurement-independent for ordinary
  // patches; the explicit full-drive endpoint exception is handled inside it.
  if(_activeColorSeries && meterChartIsHdr() && !_greyReading && meterWrgbChromaticReferenceNits()>0){
   const _wrgbRef=meterWrgbChromaticReferenceNits();
   if(_wrgbRef>0) refY=_wrgbRef;
  }
  if(_activeColorSeries && meterChartIsHdr() && meterChartIsPq()){
   let _sy=meterWrgbStimulusTargetY(reading);
   if(_sy!=null){
    if(_greyReading){
     const _gw=meterColorSeriesReferenceNits();
     if(_gw>0) _sy=Math.min(_sy,_gw);
    }
    _sy=meterLatticeDisplayTargetY(_sy,reading);
    _wrgbStimY=_sy;
   }
  }
  // HDR10 color/sat series carry PQ-absolute target_Yn (normalized to the
  // 10000-nit peak), so colored patches reference the PQ peak. The neutral
  // WHITE reference patch (target_Yn=1) must instead reference the display's
  // achieved white; otherwise the panel's normal peak rolloff reads as a
  // spurious white luminance error.
  if(_activeColorSeries&&meterActiveChartSignalMode()==='hdr10'&&_greyReading){
   const _whiteRef=meterFindMeasuredWhiteReading();
   const _whiteRefY=meterReadingLuminanceNits(_whiteRef);
   if(_whiteRefY>0) refY=_whiteRefY;
  }
  let greyTargetY=null;
  const activeColorSeries=(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations');
	  if(!activeColorSeries&&meterReadingIsGreyscale(reading)){
	   let greyWhite=null;
	   try{ greyWhite=meterGreyscaleChartWhiteReference(meterReadings); }catch(e){}
   const greyY=meterReadingLuminanceNits(greyWhite);
   if(greyY>0) refY=greyY;
   const step=targetStep||((typeof meterCanonicalSeriesStep==='function')?meterCanonicalSeriesStep(reading):null);
   const stepIre=(step&&typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(step):null;
   const ire=(typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(reading):null;
   const targetIre=ire!=null?ire:(stepIre!=null?stepIre:(reading&&reading.ire||0));
   const code=(reading&&reading.r_code!=null)?reading.r_code:(reading&&reading.r!=null?reading.r:(step?(step.r_code!=null?step.r_code:step.r):null));
   const peak=(typeof meterGreyTargetPeak==='function')?meterGreyTargetPeak((refY>0)?refY:meterColorReferenceNits()):((refY>0)?refY:meterColorReferenceNits());
   let black=0;
   try{
    if(typeof meterBlackReadingY==='function') black=meterBlackReadingY();
    else if(typeof meterChartBlackLevel==='function') black=meterChartBlackLevel(Array.isArray(meterReadings)?meterReadings:[]);
	   }catch(e){}
	   const measuredDvTargetY=(typeof meterDvAbsoluteReadingTargetY==='function')?meterDvAbsoluteReadingTargetY(reading):null;
	   const targetY=measuredDvTargetY!=null?measuredDvTargetY:
	    (Number.isFinite(tYn)?meterGreyscaleTargetYFromYn(tYn,peak,black||0):null);
	   const fallbackTargetY=(targetY!=null&&Number.isFinite(targetY))?targetY:
	    ((typeof meterGreyTargetLuminance==='function')?meterGreyTargetLuminance(targetIre,peak,black||0,code):null);
	   if(Number.isFinite(fallbackTargetY)&&fallbackTargetY>=0) greyTargetY=fallbackTargetY;
	  }
  if(tYn<=0&&greyTargetY==null) return {X:0,Y:0,Z:0};
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
    const Y=greyTargetY!=null?greyTargetY:(_wrgbStimY!=null?_wrgbStimY:tYn*refY);
    return {X:(cx/cy)*Y,Y:Y,Z:((1-cx-cy)/cy)*Y};
   }
  }
	  const Y=greyTargetY!=null?greyTargetY:(_wrgbStimY!=null?_wrgbStimY:tYn*refY);
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
 if(meterReadingIsGreyscale(reading)) return meterGreyChartTargetXYZForReading(reading);
	 return targetColorXYZAbs(reading.r_code,reading.g_code,reading.b_code);
}

function meterTargetChromaticityForReading(reading){
 const xyz=meterTargetXYZForReading(reading);
 const s=xyz.X+xyz.Y+xyz.Z;
 const wp=meterTargetWhitePoint();
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:wp.x,y:wp.y};
}

// Approximate correlated colour temperature from CIE xy (McCamy 1992).
// Good to a few K near the blackbody locus, which is all the live-reading
// target readout needs. Returns null outside a sane display range.
function meterCctFromXy(x,y){
 if(!(Number.isFinite(x)&&Number.isFinite(y))) return null;
 const d=0.1858-y;
 if(Math.abs(d)<1e-9) return null;
 const n=(x-0.3320)/d;
 const cct=449*n*n*n+3525*n*n+6823.3*n+5520.33;
 return (cct>1000&&cct<25000)?cct:null;
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
 if(!inclLum && meterReadingIsPeakHeadroom(reading) && measured && measured.Y>0){
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

function meterGreyDeltaTargetXYZ(reading,inclLum){
 // Neutral patches in a color/saturation series are deliberately analysed as
 // greyscale.  Force them through the greyscale target as well as the
 // greyscale Delta-E formula; otherwise their authored color target_Yn leaks
 // back in here and the result still differs from the identical patch in a
 // greyscale series.
 if(!(reading&&reading._neutral_color_greyscale_analysis)
    &&!(meterChartIsDv()&&meterReadingIsGreyscale(reading))) return meterColorDeltaTargetXYZ(reading,inclLum);
 let target=null;
 const customNits=Number(reading&&reading.custom_target_nits);
 if(reading&&reading._neutral_color_greyscale_analysis&&Number.isFinite(customNits)&&customNits>0){
  const wp=meterTargetWhitePoint();
  target={X:wp.X*customNits,Y:customNits,Z:wp.Z*customNits};
 }else{
  target=meterGreyChartTargetXYZForReading(reading);
 }
 const measured=meterReadingXYZ(reading);
 if(inclLum||!measured||!(measured.Y>0)) return target;
 if(!(target.Y>0)){
  const wp=meterTargetWhitePoint();
  return {X:wp.X*measured.Y,Y:measured.Y,Z:wp.Z*measured.Y};
 }
 const scale=measured.Y/target.Y;
 return {X:target.X*scale,Y:measured.Y,Z:target.Z*scale};
}

function meterColorIncludeLum(){
 const el=document.getElementById('meterColorIncludeLumError');
 return !!(el&&el.checked);
}

function meterColorSeparateLumEnabled(){
 const el=document.getElementById('meterColorSeparateLumError');
 return !!(el&&el.checked&&meterColorIncludeLum());
}

function meterUpdateColorSeparateLumVisibility(){
 const cb=document.getElementById('meterColorSeparateLumError');
 const wrap=document.getElementById('meterColorSeparateLumErrorWrap');
 if(!cb||!wrap) return;
 const show=meterColorIncludeLum();
 wrap.style.display=show?'':'none';
 if(!show&&cb.checked) cb.checked=false;
}

// Color-series "Include luminance error" toggle: updates ΔE mode, CIE ΔY%
// halo rings, tables, and prefs. Dedicated handler so the CIE canvas always
// fully redraws when the rings should appear/disappear.
function meterOnColorIncludeLumChange(){
 meterUpdateColorSeparateLumVisibility();
 try{ meterSaveColorPrefs(); }catch(e){}
 if(meterReadings && meterReadings.length){
  meterReadings.forEach(r=>{
   if(!r) return;
   delete r._dE_cache_key;
   delete r._dE_raw;
   delete r._dE_lc;
  });
 }
 // Hard-clear CIE so stale halo strokes cannot survive a partial redraw.
 try{
  const c=document.getElementById('chartCIE');
  if(c){ const w=c.width,h=c.height; c.width=w; c.height=h; }
 }catch(e){}
 meterOnGreyRefChange();
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

function meterReadingTargetsBlack(reading){
 if(!reading) return false;
 const name=String(reading.name||'').trim().toLowerCase();
 if(name==='black'||name==='0%') return true;
 const tYn=Number(reading.target_Yn);
 return Number.isFinite(tYn)&&Math.abs(tYn)<1e-12;
}

function meterXyzIsBlack(xyz){
 if(!xyz) return false;
 const X=Number(xyz.X), Y=Number(xyz.Y), Z=Number(xyz.Z);
 return Number.isFinite(X)&&Number.isFinite(Y)&&Number.isFinite(Z)&&
  Math.abs(X)<1e-9&&Math.abs(Y)<1e-9&&Math.abs(Z)<1e-9;
}

function meterReadingXYZ(reading){
 if(!reading) return null;
 meterNormalizeMeasuredReading(reading);
 const Y=meterReadingLuminanceNits(reading);
 if(!(Y>0)){
  // A measured zero is a REAL result for any patch, not just the black step.
  // A crushed panel genuinely emits no light at 5%/10% stimulus, and the meter
  // reports an exact 0 XYZ for it. Restricting this to meterReadingTargetsBlack
  // returned null for every other patch that measured 0, which dropped the node
  // out of meterReadingXYZ and therefore out of RGB balance, the per-channel
  // overlays and the report tables -- hiding the very defect being measured.
  // Only a genuinely absent reading (luminance/Y not present) stays null.
  if(Number(Y)===0){
   const X=(reading.X!=null)?Number(reading.X):0;
   const Z=(reading.Z!=null)?Number(reading.Z):0;
   return {X:Number.isFinite(X)?X:0,Y:0,Z:Number.isFinite(Z)?Z:0,observer:reading.observer||'1931_2'};
  }
  return null;
 }
 if(reading.X!=null && reading.Y!=null && reading.Z!=null) return {X:reading.X,Y:reading.Y,Z:reading.Z,observer:reading.observer||'1931_2'};
 const x=(reading.x!=null)?Number(reading.x):NaN;
 const y=(reading.y!=null)?Number(reading.y):NaN;
 if(Number.isFinite(x) && Number.isFinite(y) && y>0){
  return {X:(x/y)*Y,Y,Z:((1-x-y)/y)*Y,observer:reading.observer||'1931_2'};
 }
 if(meterReadingIsGreyscale(reading)){
  const wp=meterTargetWhitePoint();
  return {X:wp.X*Y,Y,Z:wp.Z*Y};
 }
 return null;
}

// meterReadingXYZ returns null for a reading of zero luminance unless the patch
// was TARGETING black, because a zero read carries no chromaticity. Every dE
// path then treated "no measurement to compare" the same as "nothing to report"
// and returned 0 -- so a patch that measured pure black against a lit target
// (display off, meter capped or unplugged, fully crushed shadow) scored a
// perfect zero. Reconstruct {X,0,Z} for a real measurement so the luminance gap
// is scored against whatever the target is.
//
// Unread step shells return null and keep the old behaviour: they have no
// measurement, which is genuinely different from having measured nothing.
function meterMeasuredXYZOrBlack(reading){
 const xyz=meterReadingXYZ(reading);
 if(xyz) return xyz;
 if(!reading) return null;
 if(typeof meterReadingIsRealMeasurement==='function' && !meterReadingIsRealMeasurement(reading)) return null;
 const Y=Number(meterReadingLuminanceNits(reading));
 if(!(Y===0)) return null;
 const X=(reading.X!=null)?Number(reading.X):0;
 const Z=(reading.Z!=null)?Number(reading.Z):0;
 if(!Number.isFinite(X)||!Number.isFinite(Z)) return null;
 return {X:X,Y:0,Z:Z};
}

function meterColorLuminanceInfo(reading){
 if(!reading) return {measuredY:null,targetY:null,deltaY:null,deltaPct:null};
 const measuredY=meterReadingLuminanceNits(reading);
 // SDR26 peak (Limited 109 / Full 100): chroma-only -- no luminance target
 // and no Y-error. Target Y must not be a gamma curve value (that inflated
 // Full 100% error against a stale pre-peak white).
 if(typeof meterReadingIsSdr26LegalPeak==='function' && meterReadingIsSdr26LegalPeak(reading)){
  return {measuredY,targetY:null,deltaY:null,deltaPct:null,chromaOnlyPeak:true};
 }
 let targetY=null;
 try{
  const targetXYZ=meterTargetXYZForReading(reading);
  // Peak path may still return measured-Y D65 XYZ; treat equal-to-measured
  // as no target for display. All-zero is the no-target sentinel.
  if(targetXYZ && targetXYZ.Y!=null && targetXYZ.Y>0
     && (targetXYZ.X>0 || targetXYZ.Y>0 || targetXYZ.Z>0)){
   targetY=targetXYZ.Y;
   if(measuredY!=null && Math.abs(targetY-measuredY)<1e-6) targetY=null;
  }
 }catch(e){}
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
 // Reconstructs {X,0,Z} for a patch that genuinely measured black, so the
 // black-on-black guard below decides: still 0 when the target is also ~0 (the
 // 0% / target-black case), but a full luminance-gap dE for any lit target.
 // This used to be inline here and required X and Z within 1e-9 of zero, but
 // it was unreachable anyway -- meterColorDeltaE2000 bailed on the null XYZ
 // before ever calling this.
 let xyz=meterMeasuredXYZOrBlack(reading);
 if(!reading||!xyz) return {value:0,de2000:0};
 form = form || meterDeltaEForm();
 if(gwWeight==null) gwWeight = meterGrayWorldWeight();
 const mode=meterResolveGreyRefMode(modeOrIncl);
 let wR=meterColorLabWhite();
 const _gw=(gwWeight>0&&gwWeight<=1)?gwWeight:1;
 if(_gw<1) wR={X:wR.X*_gw,Y:wR.Y*_gw,Z:wR.Z*_gw};
 const target=meterGreyDeltaTargetXYZ(reading, mode==='eotf');
 // Black-on-black: measured Y=0 with target Y=0 (or no target) = no error.
 // But when the operator set a Target Black override (target Y>0), compute the
 // dE against {0,0,0} measured so the luminance gap is reported even when the
 // meter read 0 on OLED true black.
 if(!(xyz.Y>0) && !(target&&target.Y>0)) return {value:0,de2000:0};
 // "Use measured" Target Black supplies only the luminance floor. Do not
 // replace a raised-black measurement's chromaticity with the target white:
 // an LCD black that still has measurable light can have a real colour cast,
 // and greyscale dE must compare that measured XYZ against the selected target
 // white at the measured/manual black Y. A true zero-luminance black remains
 // covered by the black-on-black guard above because it has no chromaticity.
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
  Xr:target.X, Yr:target.Y, Zr:target.Z, YWhiteRef:wR.Y,
  reading:reading
 };
 return {value:meterDeltaE(labM,labT,form,ctx),de2000:deltaE2000(labM,labT)};
}

// Primary grayscale/color ΔE entry point. Greyscale uses the greyscale ΔE
// selector; Colors and Sat Sweep use their dedicated Color ΔE selector.
function meterColorDeltaE2000(reading,modeOrIncl,form,gwWeight){
 if(!reading) return 0;
 const xyz=meterMeasuredXYZOrBlack(reading);
 const useColorForm=meterReadingUsesColorDeltaForm(reading);
 form = form || (useColorForm ? meterColorDeltaEForm() : meterDeltaEForm());
 if(gwWeight==null) gwWeight = meterGrayWorldWeight();
 if(!useColorForm && meterReadingIsGreyscale(reading) && xyz && xyz.Y>=0){
  return meterGreyDeltaResult(reading,modeOrIncl,form,gwWeight).value;
 }
 const mode=meterResolveGreyRefMode(modeOrIncl);
 const target=meterColorDeltaTargetXYZ(reading, mode==='eotf');
 if(!xyz||!(xyz.Y>0)){
  // Measured black is a zero error ONLY against a black target. Against a lit
  // target it is a total miss and has to be scored, not swallowed.
  if(!xyz||!target||!(target.Y>0)){
   if(useColorForm&&meterXyzIsBlack(xyz)&&meterXyzIsBlack(target)) return 0;
   return useColorForm ? NaN : 0;
  }
 }
 const wR=meterColorLabWhite();
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

// Color-series patches are classified by their emitted code triplet, not by
// their name or series category. Exact R=G=B is a neutral patch and must use
// the same target, Delta-E formula and RGB-balance math as the identical patch
// in a greyscale series. Reports and CSV use this same dispatch so exported
// errors agree with the charts.

function meterColorSeriesNeutralUsesGreyscaleAnalysis(reading){
 if(!reading) return false;
 if(meterActiveSeriesType!=='colors'&&meterActiveSeriesType!=='saturations') return false;
 const r=Number(reading.r_code!=null?reading.r_code:reading.r);
 const g=Number(reading.g_code!=null?reading.g_code:reading.g);
 const b=Number(reading.b_code!=null?reading.b_code:reading.b);
 return Number.isFinite(r)&&Number.isFinite(g)&&Number.isFinite(b)&&r===g&&g===b;
}

function meterNeutralColorGreyscaleReading(reading){
 if(!reading) return reading;
 const clone={...reading};
 const step=(typeof meterCanonicalSeriesStep==='function')?meterCanonicalSeriesStep(reading):null;
 const source=step||reading;
 const code=Number(reading.r_code!=null?reading.r_code:(source.r_code!=null?source.r_code:source.r));
 let ire=null;
 const pctFields=['signal_r_pct','signal_g_pct','signal_b_pct'];
 const pcts=pctFields.map(key=>Number(source[key]));
 if(pcts.every(Number.isFinite)&&pcts[0]===pcts[1]&&pcts[1]===pcts[2]) ire=pcts[0];
 if(!Number.isFinite(ire)){
  const range=meterColorTargetCodeRange();
  if(Number.isFinite(code)&&range&&range.span>0) ire=Math.max(0,Math.min(1,(code-range.min)/range.span))*100;
 }
 if(!Number.isFinite(ire)) ire=Number(meterReadingAnalysisIre(reading));
 if(!Number.isFinite(ire)) ire=0;
 clone.ire=ire;
 clone.analysis_ire=ire;
 clone.target_ire=ire;
 clone.stimulus=ire;
 clone.signal_r_pct=ire;
 clone.signal_g_pct=ire;
 clone.signal_b_pct=ire;
 clone.series_type='greyscale';
 clone._neutral_color_greyscale_analysis=true;
 // Color-series targets are not greyscale targets. The marker above makes the
 // target resolver rebuild D65 + EOTF Y from this patch's actual neutral code.
 delete clone.target_X; delete clone.target_Y; delete clone.target_Z;
 delete clone.target_x; delete clone.target_y; delete clone.target_Yn;
 return clone;
}

function meterSeriesDeltaEForDisplay(reading,modeOrIncl,form,gwWeight){
 if(!meterColorSeriesNeutralUsesGreyscaleAnalysis(reading)) return meterColorDeltaE2000(reading,modeOrIncl,form,gwWeight);
 const grey=meterNeutralColorGreyscaleReading(reading);
 // Neutral rows use greyscale target/formula math, but the color chart's own
 // luminance toggle still controls whether EOTF/gamma error is included.
 // Ignoring modeOrIncl made both raw and compensated cache entries identical,
 // so neutral ColorChecker rows could never report their luminance error.
 const mode=(modeOrIncl==null)?meterColorRefMode():modeOrIncl;
 const weight=(gwWeight==null)?meterGrayWorldWeight():gwWeight;
 return meterGreyDeltaResult(grey,mode,meterDeltaEForm(),weight).value;
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
	const tgtGamma=((typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||'')))||'';
		const targetContext=[
		 meterChartSignalMode(),
		 tgtGamma,
	 (typeof meterDvMapModeValue==='function')?meterDvMapModeValue():'',
	 (typeof meterChartHdrPeak==='function')?meterChartHdrPeak():'',
	 (typeof meterChartMasterMin==='function')?meterChartMasterMin():'',
	 (typeof meterChartBt2390Enabled==='function'&&meterChartBt2390Enabled())?'bt2390':'',
		 (typeof meterHdrDiffuseWhiteOverride==='function')?meterHdrDiffuseWhiteOverride():''
		].join(':');
		const greyWhite=meterGreyscaleChartWhiteReference(readings);
		const greyWhiteStamp=greyWhite?[
		 meterReadingLuminanceNits(greyWhite)||0,
		 greyWhite.synthetic_target?'synthetic':'measured',
		 greyWhite.autocal_target_reference_disabled?'disabled':'active'
		].join('@'):'none';
		// Include color_incl_lum so toggling CIE ΔY% / color ΔE mode never reuses a stale pair.
		const colorInclLum=meterColorIncludeLum()?'1':'0';
		// Target Black / Target White feed the greyscale target luminance
		// (meterGreyscaleTargetYFromYn / meterGreyTargetLuminance), so a pair
		// computed under one black is invalid under another. meterRefreshTargetCurves
		// deletes these caches on a target-levels edit, but that only fires when
		// meterReadings is already populated and it is one explicit call among
		// several paths that can recompute -- miss it once and the key still claims
		// the stale pair is good, which is why a dE could sit wrong until the gamma
		// dropdown was toggled (gamma IS in the key) and then "fix itself".
		// Keying on the values removes the dependency on remembering to invalidate.
		const levelStamp=fn=>{
		 try{ const t=(typeof fn==='function')?fn():null;
		  return t?((t.useMeasured?'m':'f')+(t.value!=null?t.value:'')):''; }catch(e){ return ''; }
		};
		let resolvedBlack='';
		try{ resolvedBlack=String(Number((typeof meterBlackReadingY==='function')?meterBlackReadingY():0)||0); }catch(e){}
		const targetLevels=[
		 resolvedBlack,
		 levelStamp(typeof meterTargetBlackLevel!=='undefined'?meterTargetBlackLevel:null),
		 levelStamp(typeof meterTargetWhiteLevel!=='undefined'?meterTargetWhiteLevel:null)
		].join('/');
		const key=greyForm+':'+colorForm+':'+greyMode+':'+gw+':'+colorInclLum+':live-neutral-grey:'+meterAnalysisGamutKey()+':'+targetContext+':'+greyWhiteStamp+':'+targetLevels;
	readings.forEach(rd=>{
	 if(!rd) return;
	 if(rd._dE_cache_key===key) return;
	 const neutral=meterColorSeriesNeutralUsesGreyscaleAnalysis(rd);
	 const formForReading=neutral?greyForm:(meterReadingUsesColorDeltaForm(rd)?colorForm:greyForm);
	 const pair=neutral
	  ? {raw:meterSeriesDeltaEForDisplay(rd,greyMode,formForReading,gw),lc:meterSeriesDeltaEForDisplay(rd,greyMode,formForReading,gw)}
	  : meterColorDeltaE2000Pair(rd,formForReading,gw);
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
 const analysisIre=((meterChartIsDv()||meterChartIsHdr()||meterChartIsHlg())&&meterReadingIsGreyscale(reading))?(meterReadingGammaAnalysisIre(reading)||ire):ire;
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
 if(analysisIre>=100){
   return null;
  }
  if(!(m>0)) return null;
  const gv=Math.log(m/w)/Math.log(analysisIre/100);
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
 const effective=meterEffectiveGreyscaleWhiteReference(list);
 if(effective) return effective;
 const seriesWhite=meterFindSeriesWhiteReading(list);
 if(seriesWhite) return seriesWhite;
 const measured=meterFindMeasuredWhiteReading();
 if(measured) return measured;
 return null;
}

function meterGammaValueReferenceY(readings){
 const white=meterGammaValueWhiteReference(readings);
 const y=white?meterReadingLuminanceNits(white):null;
 if(y>0) return y;
 const list=(Array.isArray(readings)?readings:(Array.isArray(meterReadings)?meterReadings:[])).filter(rd=>rd&&meterReadingIsGreyscale(rd)&&meterReadingHasLuminance(rd));
 const measuredPeak=meterFilterEotfLuminanceChartItems(list).reduce((mx,r)=>Math.max(mx,meterReadingLuminanceNits(r)||0),0);
 return measuredPeak>0?measuredPeak:0;
}

// The measured gamma is the plain log-ratio exponent ln(Y/Yw)/ln(V) -- the
// display's actual behaviour, with nothing about the TARGET folded into it. The
// target line carries the raised Target Black instead (meterGreyTargetGamma),
// so the two lines share one metric and the gap between them is the error.
//
// A previous revision solved this for the exponent that would put each reading
// on the BT.1886 curve built from the operator's Lw/Lb, which made an on-target
// display read a flat 2.4. That reads well but is not what the display is doing,
// it cannot be compared against a nominal line, and readings at or below the
// target black had no solution at all so they dropped out of the plot.
// blackLevel is accepted and ignored; kept so existing call sites still work.
function meterGreyscaleGammaValue(reading,whiteY,blackLevel){
 if(!reading) return null;
 const y=meterReadingLuminanceNits(reading);
 const analysisIre=meterReadingGammaAnalysisIre(reading);
 if(!(whiteY>0) || !(y>0) || !(analysisIre>0) || analysisIre>=100) return null;
 return effectiveGamma(y,whiteY,analysisIre);
}

function meterBt1886BlackAwareMetricsActive(){
 try{
  if(typeof meterChartIsDv==='function' && meterChartIsDv()) return false;
  if(typeof meterChartIsHlg==='function' && meterChartIsHlg()) return false;
  if(typeof meterGreyChartUsesPqTarget==='function' ? meterGreyChartUsesPqTarget()
     : (typeof meterChartIsHdr==='function' && meterChartIsHdr())) return false;
  const tgt=(typeof meterGreyChartTargetGammaSelection==='function')
   ?meterGreyChartTargetGammaSelection()
   :((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():'');
  return String(tgt||'').toLowerCase()==='bt1886';
 }catch(e){ return false; }
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

function meterHcfrGcdColorCheckerSource(){
 return [
  ['Gray 35',62.10,62.10,62.10],['Gray 50',73.06,73.06,73.06],
  ['Gray 65',82.19,82.19,82.19],['Gray 80',89.95,89.95,89.95],
  ['Dark Skin',45.20,31.96,26.03],['Light Skin',75.80,58.90,51.14],
  ['Blue Sky',36.99,47.95,61.19],['Foliage',35.16,42.01,26.03],
  ['Blue Flower',51.14,50.23,68.95],['Bluish Green',38.81,73.97,66.21],
  ['Orange',84.93,47.03,15.98],['Purplish Blue',29.22,36.07,63.93],
  ['Moderate Red',75.80,32.88,37.90],['Purple',36.07,24.20,42.01],
  ['Yellow Green',62.10,73.06,25.11],['Orange Yellow',89.95,63.01,17.81],
  ['Blue',20.09,24.20,58.90],['Green',27.85,57.99,27.85],
  ['Red',68.95,19.18,22.83],['Yellow',93.15,78.08,12.79],
  ['Magenta',73.06,32.88,57.08],['Cyan',0,52.05,63.93]
 ];
}

function meterSolveD65ReferenceLinear(X,Y,Z,solveGamut){
 const adapted=meterAdaptReferenceXyzToTargetWhite(X,Y,Z);
 const sum=adapted.X+adapted.Y+adapted.Z;
 const wp=meterTargetWhitePoint();
 const targetX=sum>0?adapted.X/sum:wp.x;
 const targetY=sum>0?adapted.Y/sum:wp.y;
 let rgb=xyzToLinRgb(adapted.X,adapted.Y,adapted.Z,solveGamut.xyzToRgb);
 const mx=Math.max(rgb[0],rgb[1],rgb[2]);
 let scale=1;
 if(mx>1+1e-6){rgb=rgb.map(v=>v/mx);scale=1/mx;}
 rgb=rgb.map(v=>Math.max(0,v));
 return {rgb:rgb,target_x:targetX,target_y:targetY,target_Yn:Math.max(0,adapted.Y)*scale,reference_Yn:Math.max(0,adapted.Y)};
}

function meterBuildFixedVideoCodeColorSteps(rows,seriesMode){
 const steps=[];
 const min=meterChromaPatchRangeMin(),span=meterChromaPatchRangeSpan();
 const wp=meterTargetWhitePoint();
 const inputMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
 const signalModeFn=(typeof meterActiveChartSignalMode==='function')?meterActiveChartSignalMode:((typeof meterChartSignalMode==='function')?meterChartSignalMode:null);
 const signalMode=String((signalModeFn?signalModeFn():'sdr')||'sdr').toLowerCase();
 const hcfrSeries=/^hcfr(?:-|$)/.test(String(seriesMode||'').toLowerCase());
 const solveGamut=(signalMode==='hlg')
  ?GAMUT_PRESETS.bt2020
  :((typeof meterStimulusSolveGamut==='function')?meterStimulusSolveGamut():GAMUT_PRESETS.bt709);
 const canSolveReference=!!(solveGamut&&Array.isArray(solveGamut.xyzToRgb)&&typeof meterSolveD65ReferenceLinear==='function');
 const add=(name,rPct,gPct,bPct,ire)=>{
  const sourceSignal=[rPct,gPct,bPct].map(v=>Math.max(0,Math.min(100,Number(v)||0))/100);
  if(hcfrSeries&&(signalMode==='hdr10'||signalMode==='hlg')){
   // Keep HCFR's HDR conversion byte-for-byte compatible: gamma 2.22 source,
   // Rec.709 XYZ, BT.2020 container, 94.37844-nit PQ reference and legal-8
   // requantisation. Its decoded target stays on the same D65 stimulus.
   const sourceLinear=sourceSignal.map(v=>Math.pow(v,2.22));
   const sourceXyz=linRgbToXyz(sourceLinear[0],sourceLinear[1],sourceLinear[2],GAMUT_PRESETS.bt709.rgbToXyz);
   const scale=(signalMode==='hdr10')?METER_HCFR_HDR_DIFFUSE_WHITE_NITS/10000:1;
   const containerLinear=xyzToLinRgb(sourceXyz.X*scale,sourceXyz.Y*scale,sourceXyz.Z*scale,GAMUT_PRESETS.bt2020.xyzToRgb)
    .map(v=>Math.max(0,Math.min(1,v)));
   const encoded=containerLinear.map(v=>(signalMode==='hdr10')?meterChartPqEncodeNormalized(v*10000):hlgOetf(v));
   const quantized=encoded.map(v=>meterHcfrQuantizedSignal(v));
   const codes=quantized.map(v=>Math.round(min+v*span));
   const decoded=quantized.map(v=>{
    if(signalMode==='hdr10') return meterChartPqDecodeNormalized(v)/10000;
    if(v<=0.5) return (4*v*v)/12;
    return (Math.exp((v-0.55991073)/0.17883277)+0.28466892)/12;
   });
   const xyz=linRgbToXyz(decoded[0],decoded[1],decoded[2],GAMUT_PRESETS.bt2020.rgbToXyz);
   const sum=xyz.X+xyz.Y+xyz.Z;
   let targetYn=Math.max(0,xyz.Y);
   if(signalMode==='hdr10'){
    const whiteRef=Number(meterColorSeriesReferenceNits());
    if(whiteRef>0) targetYn=xyz.Y*10000/whiteRef;
   }
   steps.push({ire:ire!=null?ire:Math.round(Math.max(0,sourceXyz.Y)*100),r:codes[0],g:codes[1],b:codes[2],name:name,
    target_x:sum>0?xyz.X/sum:wp.x,target_y:sum>0?xyz.Y/sum:wp.y,target_Yn:targetYn,
    input_max:inputMax,series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
   return;
  }

  const linear=(signalMode==='sdr')
   ?sourceSignal.map(v=>meterDecodeColorCheckerSignal(v))
   :sourceSignal.map(v=>Math.pow(v,2.4));
  const sourceXyz=linRgbToXyz(linear[0],linear[1],linear[2],GAMUT_PRESETS.bt709.rgbToXyz);
  const nominalY=Math.max(0,sourceXyz.Y);
  const neutral=Math.abs(sourceSignal[0]-sourceSignal[1])<1e-9&&Math.abs(sourceSignal[1]-sourceSignal[2])<1e-9;
  const endpoint=neutral&&(sourceSignal[0]<=1e-9||sourceSignal[0]>=1-1e-9);
  if(endpoint){
   const code=sourceSignal[0]>=1-1e-9?Math.round(min+span):Math.round(min);
   const level=sourceSignal[0]>=1-1e-9?1:0;
   const sum=sourceXyz.X+sourceXyz.Y+sourceXyz.Z;
   const tx=(!canSolveReference&&sum>0)?sourceXyz.X/sum:wp.x;
   const ty=(!canSolveReference&&sum>0)?sourceXyz.Y/sum:wp.y;
   steps.push({ire:level?100:0,r:code,g:code,b:code,name:name,target_x:tx,target_y:ty,target_Yn:canSolveReference?level:nominalY,
    input_max:inputMax,series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
   return;
  }
  // Relative DV keeps its existing tunnel behavior; it has no HCFR equivalent
  // and remains outside this cross-colorspace SDR/HLG correction.
  if(signalMode==='dv'){
   const codes=linear.map(v=>meterEncodeColorCheckerLinear(v));
   const sum=sourceXyz.X+sourceXyz.Y+sourceXyz.Z;
   steps.push({ire:ire!=null?ire:Math.round(nominalY*100),r:codes[0],g:codes[1],b:codes[2],name:name,
    target_x:sum>0?sourceXyz.X/sum:wp.x,target_y:sum>0?sourceXyz.Y/sum:wp.y,target_Yn:nominalY,
    input_max:inputMax,series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
   return;
  }
  if(neutral&&signalMode==='sdr'&&canSolveReference){
   // Equal SDR codes already produce the selected RGB space's white. Keep the
   // authored code exactly while targeting that white at the decoded level.
   const code=Math.round(min+sourceSignal[0]*span);
   steps.push({ire:ire!=null?ire:Math.round(nominalY*100),r:code,g:code,b:code,name:name,
    target_x:wp.x,target_y:wp.y,target_Yn:nominalY,input_max:inputMax,
    series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
   return;
  }
  // Older cached pages and isolated harnesses may not include the reference
  // solver dependencies. Preserve their established BT.709 interpretation.
  if(!canSolveReference){
   const codes=(signalMode==='sdr')?sourceSignal.map(v=>Math.round(min+v*span)):linear.map(v=>meterEncodeColorCheckerLinear(v));
   const sum=sourceXyz.X+sourceXyz.Y+sourceXyz.Z;
   steps.push({ire:ire!=null?ire:Math.round(nominalY*100),r:codes[0],g:codes[1],b:codes[2],name:name,
    target_x:sum>0?sourceXyz.X/sum:wp.x,target_y:sum>0?sourceXyz.Y/sum:wp.y,target_Yn:nominalY,
    input_max:inputMax,series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
   return;
  }
  const solved=meterSolveD65ReferenceLinear(sourceXyz.X,sourceXyz.Y,sourceXyz.Z,solveGamut);
  const codes=solved.rgb.map(v=>meterEncodeColorCheckerLinear(v));
  steps.push({ire:ire!=null?ire:Math.round(nominalY*100),r:codes[0],g:codes[1],b:codes[2],name:name,
   target_x:solved.target_x,target_y:solved.target_y,target_Yn:solved.target_Yn,
   input_max:inputMax,series_mode:(seriesMode||'fixed-video')+'-'+signalMode});
 };
 (Array.isArray(rows)?rows:[]).forEach((row,idx)=>add(row[0]||('Patch '+(idx+1)),row[1],row[2],row[3]));
 return steps;
}

function meterBuildHcfrColorCheckerStepsJS(includePrimaries){
 const rows=[['White',100,100,100],['Black',0,0,0],...meterHcfrGcdColorCheckerSource()];
 const steps=meterBuildFixedVideoCodeColorSteps(rows,'hcfr-gcd');
 if(includePrimaries===false) return steps;
 [['100% Red','Red'],['100% Green','Green'],['100% Blue','Blue'],['100% Cyan','Cyan'],['100% Magenta','Magenta'],['100% Yellow','Yellow']].forEach(([name,colorName])=>{
  const step=meterBuildHcfrSaturationStep(colorName,100);
  steps.push({...step,name:name});
 });
 return steps;
}

function meterBuildColorCheckerStepsJS(includePrimaries){
	 const steps=[];
	 const min=meterChromaPatchRangeMin();
	 const max=min+meterChromaPatchRangeSpan();
	 const inputMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
	 const wp=meterTargetWhitePoint();
	 const dvAbsolute=meterChartIsDv()&&meterDvMapModeValue()==='1';
	 const absoluteHdrColorChecker=(meterChartIsPq()&&!meterChartIsDv())||dvAbsolute;
	 // HDR10 and Absolute DV carry PQ RGB in the BT.2020 container, while
	 // Relative DV retains its target-gamut tunnel. Keep this routed through
	 // the shared stimulus solver so fixing the Absolute-DV path cannot make
	 // HDR10 fall back to target-gamut coefficients on a BT.2020 wire.
	 const solveGamut=meterStimulusSolveGamut();
	 // HLG is carried in a BT.2020 container. Keep this local to ColorChecker
	 // so unrelated custom and MacLeod-Boynton series retain their behavior.
	 const wireSolveGamut=meterChartIsHlg()?GAMUT_PRESETS.bt2020:solveGamut;
	 const seriesWhite=Math.max(1,Number(meterColorSeriesReferenceNits())||1);
	 const hdrColorCheckerRefNits=203;
	 steps.push({ire:100,r:max,g:max,b:max,name:'White',target_x:wp.x,target_y:wp.y,target_Yn:1,input_max:inputMax});
	 steps.push({ire:0,r:min,g:min,b:min,name:'Black',target_x:wp.x,target_y:wp.y,target_Yn:0,input_max:inputMax});
	 meterColorCheckerClassicSource().forEach(src=>{
	  if(src.gray!=null){
	   const ire=Math.round(src.gray*100);
	   const code=meterEncodeColorCheckerLinear(src.gray,absoluteHdrColorChecker?hdrColorCheckerRefNits:undefined);
	   let targetYn=absoluteHdrColorChecker?(src.gray*hdrColorCheckerRefNits/seriesWhite):src.gray;
	   if(meterChartIsDv()&&!dvAbsolute){
	    const span=meterChromaPatchRangeSpan();
	    const signal=span>0?(code-meterChromaPatchRangeMin())/span:0;
	    targetYn=Math.max(0,meterDecodeColorCheckerSignal(signal));
	   }
	   steps.push({ire:ire,r:code,g:code,b:code,name:src.name,target_x:wp.x,target_y:wp.y,target_Yn:targetYn,input_max:inputMax});
	   return;
	  }
    const ref=xyToUnitXyz(src.x,src.y);
    const adapted=meterAdaptReferenceXyzToTargetWhite(ref.X*src.Yn,src.Yn,ref.Z*src.Yn);
    const adaptedSum=adapted.X+adapted.Y+adapted.Z;
    const targetX=adaptedSum>0?adapted.X/adaptedSum:wp.x;
    const targetY=adaptedSum>0?adapted.Y/adaptedSum:wp.y;
    const adaptedYn=Math.max(0,adapted.Y);
    let emitXY=meterRemapRelativeDvChromaticityToSolveGamut(targetX,targetY,wireSolveGamut);
    // Do not pre-compress Absolute-DV ColorChecker chromaticity. Targets and
    // emitted RGB must describe the same xy point; otherwise the display is
    // scored against a saturation it was never asked to produce.
    const X=(emitXY.x/emitXY.y)*adaptedYn;
    const Y=adaptedYn;
    const Z=((1-emitXY.x-emitXY.y)/emitXY.y)*adaptedYn;
  let rl=wireSolveGamut.xyzToRgb[0][0]*X+wireSolveGamut.xyzToRgb[0][1]*Y+wireSolveGamut.xyzToRgb[0][2]*Z;
  let gl=wireSolveGamut.xyzToRgb[1][0]*X+wireSolveGamut.xyzToRgb[1][1]*Y+wireSolveGamut.xyzToRgb[1][2]*Z;
  let bl=wireSolveGamut.xyzToRgb[2][0]*X+wireSolveGamut.xyzToRgb[2][1]*Y+wireSolveGamut.xyzToRgb[2][2]*Z;
  const mx=Math.max(rl,gl,bl);
  let stimulusScale=1;
  if(mx>1+1e-6){rl/=mx;gl/=mx;bl/=mx;stimulusScale=1/mx;}
  rl=Math.max(0,rl);
  gl=Math.max(0,gl);
  bl=Math.max(0,bl);
	  const colorRef=absoluteHdrColorChecker?hdrColorCheckerRefNits:undefined;
	  const rCode=meterEncodeColorCheckerLinear(rl,colorRef);
	  const gCode=meterEncodeColorCheckerLinear(gl,colorRef);
	  const bCode=meterEncodeColorCheckerLinear(bl,colorRef);
	  const scaledYn=adaptedYn*stimulusScale;
	  let targetYn=absoluteHdrColorChecker?(scaledYn*hdrColorCheckerRefNits/seriesWhite):scaledYn;
	  if(meterChartIsDv()&&!dvAbsolute){
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
   ire:Math.round(adaptedYn*100),
   r:rCode,
   g:gCode,
   b:bCode,
   name:src.name,
   target_x:targetX,
   target_y:targetY,
   target_Yn:targetYn,
   input_max:inputMax
  });
 });
 if(includePrimaries!==false) [
  ['100% Red','Red'],
  ['100% Green','Green'],
  ['100% Blue','Blue'],
  ['100% Cyan','Cyan'],
  ['100% Magenta','Magenta'],
  ['100% Yellow','Yellow']
 ].forEach(([name,colorName])=>{
  const rgb=meterBuildColorCheckerEndpointStepRgb(colorName);
  const target=meterBuildColorCheckerEndpointTargetStepMeta(colorName);
  steps.push({
   ire:100,
   r:rgb[0],
   g:rgb[1],
   b:rgb[2],
   name:name,
   series_color:colorName,
   sat_pct:100,
   input_max:inputMax,
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

function meterReadingIsAutoCalReferenceOnly(item){
 return !!(item&&(item.autocal_white_reference||item.autocal_reference_only));
}

function meterReadingDisablesAutoCalTargetReference(item){
 return !!(item&&(item.autocal_target_reference_disabled||item.autocal_diagnostic||item.autocal_chart_hidden));
}

function meterReadingIsAutoCalChartHidden(item){
 if(!item) return false;
 if(item.autocal_chart_hidden||item.autocal_diagnostic) return true;
 const role=String(item.autocal_read_role||'').toLowerCase();
 return role==='legal_white_validation'||role==='legal_white_pair_counterpart'||role==='top_cluster_preshape';
}

function meterFindLgAutoCalLegalWhiteReference(readings){
 const list=Array.isArray(readings)?readings:[];
 return list.find(rd=>!meterReadingDisablesAutoCalTargetReference(rd)&&meterLgAutoCalChartReferenceWhite(rd))||null;
}

function meterLgAutoCalChartReferenceWhite(item){
	 if(!item||meterActiveSeriesType!=='greyscale') return false;
	 if(meterReadingDisablesAutoCalTargetReference(item)) return false;
	 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
	 if(mode==='hdr10') return false;
	 // RGB-Limited AND Full SDR: 100% is the true peak. It must stay on
	 // thumbs and plot lines. YCbCr-Limited alone treats 100% as a
	 // legal-white reference step (ddc 99) that is hidden from the body
	 // curve / thumb strip -- RGB Limited has the same Limited-domain
	 // wire codes as YCbCr Limited, but the renderer clamps 101..109% to
	 // legal white, so 100% IS the genuine peak there.
	 if(mode==='sdr' && typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder()){
	  return false;
	 }
	 const plotIre=meterReadingPlotIre(item);
	 const ire=Number(plotIre!=null?plotIre:item.ire);
	 if(item.autocal_white_reference||item.autocal_reference_only||item.autocal_legal_white_anchor){
	  return Number.isFinite(ire)&&Math.abs(ire-100)<0.001;
	 }
	 // SDR26 1D-DPG Limited: the 109% legal peak carries the same
	 // chroma-only / no-target-Y fingerprint as the HDR 100% legal peak,
	 // but at IRE 109, not 100. The worker tags the SDR26 109 reading with
	 // autocal_legal_white_anchor + autocal_white_reference + autocal_white_y.
	 // Treat it as a chart reference white so it does NOT contribute to the
	 // body curve / deltaE bar (its chroma-only dE is reported separately).
	 if(mode==='sdr' && (typeof meterUseLgAutoCal26==='function') && meterUseLgAutoCal26(meterActiveSeriesPoints)){
	  if(Number.isFinite(ire)&&Math.abs(ire-109)<0.05){
	   if(item.autocal_legal_white_anchor||item.autocal_white_y){
	    return true;
	   }
	  }
	 }
	 return false;
}

function meterFilterLgAutoCalChartItems(items){
 const list=Array.isArray(items)?items:[];
 return list.filter(item=>!meterReadingIsAutoCalChartHidden(item)&&!meterLgAutoCalChartReferenceWhite(item));
}

function meterGreyscaleReportReadings(readings){
 const raw=meterGreyscaleReadings(readings||[]);
 const visible=meterFilterLgAutoCalChartItems(raw);
 const white=meterGreyscaleChartWhiteReference(raw)||meterWhiteReading||raw.find(r=>(r.ire||0)===100)||raw[raw.length-1]||null;
 return {raw,visible,white};
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

function meterCieLightMode(){
 return (typeof pgThemeMode!=='undefined'&&pgThemeMode==='light')||document.documentElement.getAttribute('data-theme')==='light';
}

// The CIE wash is intentionally pale in light mode, so raw preview colors
// (especially yellow, cyan and pastel ColorChecker patches) need substantially
// darker ink than they do on the dark chart background.
function meterCiePlotColor(css){
 return meterCieLightMode()?meterBoostPlotColor(css,1.30,-0.23):meterBoostPlotColor(css);
}

function meterReadingIsGreyscale(reading){
 if(!reading) return false;
 if(String(reading.series_type||'').toLowerCase()==='greyscale') return true;
 const r=reading.r_code!=null?reading.r_code:reading.r;
 const g=reading.g_code!=null?reading.g_code:reading.g;
 const b=reading.b_code!=null?reading.b_code:reading.b;
 return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
}

function meterReadingIsZeroBlack(reading){
 if(!reading) return false;
 const name=String(reading.name||'').trim().toLowerCase();
 if(name==='0%'||name==='black') return true;
 const plot=(typeof meterReadingPlotIre==='function')?meterReadingPlotIre(reading):null;
 const candidates=[plot,reading.plot_ire,reading.nominal_ire,reading.target_ire,reading.ire,reading.stimulus];
 return candidates.some(value=>{
  const ire=Number(value);
  return Number.isFinite(ire)&&Math.abs(ire)<0.05;
 });
}

function meterNormalizeOledBlackReading(reading){
 // Pass-through normalizer for the 0% IRE greyscale reading. The previous
 // behavior force-zeroed the reading whenever the measured luminance was
 // not finite or was < 0; that hid real black lift on OLED panels and
 // made the chart plot 0.0 cd/m^2 at 0% IRE even when the panel was
 // visibly lifted. The 0% reading must flow through to the chart with
 // its actual measured value, exactly like any other patch reading, so
 // the EOTF/Gamma charts (and the lifted-black callout added in 4668e285)
 // can show the real state of the panel.
 // Always return the reading object: meterNormalizeMeasuredReading mutates
 // in place. Depending on its return value would drop the sample if a stub
 // or older path returned undefined, which zeroed meterChartBlackLevel.
 if(!reading||typeof reading!=='object') return reading;
 try{ meterNormalizeMeasuredReading(reading); }catch(e){}
 return reading;
}

function meterGreyscaleReadings(readings){
 return (Array.isArray(readings)?readings:[]).map(rd=>meterNormalizeOledBlackReading(rd)).filter(rd=>meterReadingHasLuminance(rd)&&meterReadingIsGreyscale(rd)).map(rd=>{
  const plotIre=meterReadingPlotIre(rd);
  if(plotIre==null) return rd;
  const current=Number(rd.ire);
  if(Number.isFinite(current)&&Math.abs(current-plotIre)<0.001) return rd;
  return Object.assign({},rd,{ire:plotIre});
 }).sort((a,b)=>(meterReadingPlotIre(a)||0)-(meterReadingPlotIre(b)||0));
}

function meterGreyscaleReadingMap(readings){
 const map={};
 const list=meterGreyscaleReadings(readings);
 list.forEach(rd=>{
  const plotIre=meterReadingPlotIre(rd);
  if(plotIre!=null) map[plotIre]=rd;
 });
 // Defensive audit for SDR26 chart drops. If the active series is SDR26 and
 // any expected anchor IRE is missing from the map, log which one and why
 // (no reading, no luminance, filtered, or hidden). One-shot per series change
 // via a flag stored on meterAutoCalLatestStatus so we don't spam the console.
 try{
  if((typeof meterActiveSeriesPoints==='number'&&meterActiveSeriesPoints===26)
   && (typeof meterUseLgAutoCal26==='function')&&meterUseLgAutoCal26(meterActiveSeriesPoints)
   && (typeof meterActiveSeriesSignalMode!=='undefined')&&String(meterActiveSeriesSignalMode).toLowerCase()==='sdr'){
   const status=(typeof meterAutoCalLatestStatus!=='undefined')?meterAutoCalLatestStatus:(meterAutoCalLatestStatus={});
   if(!status.__sdr26_audit_done){
    // Full expects peak 100% on the chart; Limited body has 99/105/109 (100 is ref-only).
    const expectedIres=(typeof meterLgAutoCalSdr26SeriesSlots==='function')
     ? meterLgAutoCalSdr26SeriesSlots().filter(v=>Number(v)>0)
     :(typeof meterLgAutoCalSdr26BodySlots==='function')?meterLgAutoCalSdr26BodySlots():[2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109];
    const missing=[];
    expectedIres.forEach(ire=>{
     const key=String(ire);
     if(!map[ire] && !map[key] && !map[Number(ire)]){
      // Find the source reading by name and dump its fingerprint.
      const raw=(readings||[]).find(r=>{
       const n=Number(r.ire!=null?r.ire:(r.plot_ire!=null?r.plot_ire:r.stimulus));
       return Number.isFinite(n)&&Math.abs(n-ire)<0.05;
      });
      const filtered=(readings||[]).filter(r=>{
       const n=Number(r.ire!=null?r.ire:(r.plot_ire!=null?r.plot_ire:r.stimulus));
       return Number.isFinite(n)&&Math.abs(n-ire)<0.05;
      });
      missing.push({
       ire:ire,
       raw_count:raw?1:0,
       raw_keys:raw?Object.keys(raw).filter(k=>['Y','luminance','ire','plot_ire','stimulus','name','r_code','g_code','b_code','r','g','b','autocal_legal_white_anchor','autocal_chart_hidden','autocal_read_role','autocal_white_reference','autocal_white_y'].includes(k)).reduce((o,k)=>(o[k]=raw[k],o),{}):null,
       filtered_count:filtered.length,
       filtered_out_by:meterLgAutoCalChartReferenceWhite(filtered[0])?'chart_reference_white':(meterReadingIsAutoCalChartHidden(filtered[0])?'autocal_chart_hidden':(meterReadingHasLuminance(filtered[0])?null:'no_luminance'))
      });
     }
    });
    if(missing.length>0){
     console.warn('[SDR26 chart audit] missing anchor(s) on chart:',missing);
    }
    status.__sdr26_audit_done=true;
   }
  }
 }catch(e){}
 return map;
}

function meterSignalPreviewColor(r,g,b){
 if(r==null||g==null||b==null) return '#aaa';
 if(r===g&&g===b){
  // Normalize grey codes through the bit-depth/range-aware grey code
  // range instead of painting the raw code as an 8-bit sRGB value. A
  // 10-bit Limited black (code 64) painted as rgb(64,64,64) showed
  // every HDR Limited grey thumbnail lifted; normalizing maps code 64
  // -> 0 and 940 -> 255, and is a no-op for 8-bit full-range codes.
  const f=Math.max(0,Math.min(1,(typeof meterGreySignalFractionFromCode==='function')
   ? meterGreySignalFractionFromCode(r)
   : Math.max(0,Math.min(1,(r||0)/255))));
  // SDR/gamma signals: paint the fraction linearly -- the signal's own
  // gamma and the browser's display gamma cancel, matching the accepted
  // SDR thumbnail look. PQ/HLG signals are already perceptually encoded,
  // and the browser's ~2.2 display gamma on top double-darkens them
  // (10% drew as rgb(26) = near black); counter it with 1/2.2 so the
  // painted lightness tracks the HDR signal's perceptual spacing.
  const isHdrCurve=(typeof meterChartIsPq==='function'&&meterChartIsPq())
   ||(typeof meterChartIsHlg==='function'&&meterChartIsHlg());
  const v=Math.round((isHdrCurve?Math.pow(f,1/2.2):f)*255);
  return 'rgb('+v+','+v+','+v+')';
 }
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
 // Grey steps use their NATIVE codes: meterSignalPreviewColor normalizes
 // them through the bit-depth/range-aware grey code range. The preview_*
 // fields are 8-bit-SCALED codes (code*255/input_max, pedestal included:
 // 10-bit white 940 -> 234) meant for direct painting in the old raw-code
 // path -- running them through the 10-bit range math drew 100% white as
 // a ~50% grey.
 if(step.r!=null&&step.g!=null&&step.b!=null&&step.r===step.g&&step.g===step.b){
  return meterSignalPreviewColor(step.r,step.g,step.b);
 }
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
// Official CIE open-data spectral loci, sampled at 10 nm for the alternate
// observers. Blank long-wave Z/S table cells are zero.
const CIE_LOCUS_1964=[[.181333,.019685],[.180313,.0193476],[.178387,.0187109],[.175488,.0181337],[.170634,.0178493],[.165027,.0202828],[.159022,.0257251],[.151001,.0364389],[.138922,.0589201],[.11518,.10904],[.0727766,.229239],[.0209874,.440113],[.00558634,.674543],[.0495405,.802302],[.125236,.810194],[.207057,.766282],[.278588,.7113],[.347296,.65009],[.414213,.585787],[.479038,.520962],[.53856,.46144],[.58996,.41004],[.630629,.369371],[.661224,.338776],[.68266,.31734],[.695483,.304517],[.705873,.294127],[.713713,.286287],[.71679,.28321],[.718732,.281268],[.719763,.280237],[.72016,.27984],[.720358,.279642]];
const CIE_LOCUS_2015_2=[[.16638,.0182998],[.164995,.0182721],[.162958,.0165252],[.159581,.0158926],[.155404,.0176748],[.150365,.0217336],[.144232,.0289496],[.133916,.0458814],[.115738,.0832027],[.0805505,.176011],[.0311653,.355796],[.00418288,.591944],[.0238164,.796176],[.0932183,.840635],[.170905,.806175],[.243156,.749116],[.311614,.685758],[.380606,.618505],[.450008,.549684],[.518078,.481808],[.577571,.422385],[.624569,.375412],[.659999,.339992],[.683693,.316307],[.699072,.300928],[.708867,.291133],[.715279,.284721],[.719116,.280884],[.721541,.278459],[.722647,.277353],[.723143,.276857],[.723291,.276709]];
const CIE_LOCUS_2015_10=[[.17842,.0246367],[.176521,.024325],[.173723,.0218546],[.169345,.0209976],[.164082,.0234899],[.157689,.0292501],[.149774,.0395764],[.136265,.0639734],[.112468,.117502],[.0692931,.244778],[.0182574,.463233],[.00817345,.691305],[.0502997,.831847],[.128254,.831344],[.20946,.776992],[.283155,.712361],[.35114,.647341],[.417162,.582324],[.480878,.518942],[.540968,.458964],[.593121,.406852],[.633963,.366025],[.664977,.335017],[.685958,.314042],[.699774,.300226],[.708708,.291292],[.714655,.285345],[.718244,.281756],[.720535,.279465],[.721581,.278419],[.722049,.277951],[.722187,.277813]];
// CIE 170-2 spectral MacLeod-Boynton coordinates at 5 nm in the source table's
// spectral-maximum S normalization. meterCieChartLocus converts these to the
// relative cone-troland display convention. The previous 10 nm subset made the
// short-wave peak visibly angular in both 2D and 3D.
const CIE_LOCUS_MB_2=[[.690547,.855670],[.684874,.835495],[.677571,.858452],[.670708,.915226],[.662656,.953597],[.645977,.991436],[.627777,.996399],[.605668,.959504],[.585916,.898535],[.565891,.807527],[.551744,.731596],[.539800,.641510],[.531511,.548520],[.527476,.441625],[.524357,.343327],[.525096,.258774],[.528335,.184906],[.533931,.125009],[.540738,.081120],[.547797,.052248],[.555470,.033091],[.563711,.020925],[.572275,.013104],[.580161,.007722],[.588088,.004342],[.596380,.002563],[.603889,.001511],[.611831,.000907],[.619954,.000546],[.627978,.000332],[.636807,.000198],[.646077,.000120],[.655844,.000074],[.666621,.000045],[.679293,.000028],[.692851,.000017],[.708852,.000011],[.726397,.000007],[.746141,.000005],[.767738,.000003],[.788583,.000002],[.810139,.000001],[.831629,.000001],[.852855,.000001],[.871948,.000001],[.888841,0],[.903949,0],[.917401,0],[.927421,0],[.935885,0],[.943662,0],[.950920,0],[.954901,0],[.958448,0],[.961871,0],[.964655,0],[.966375,0],[.967596,0],[.968455,0],[.969042,0],[.969394,0],[.969636,0],[.969674,0]];
const CIE_LOCUS_MB_10=[[.6927375,.8357751],[.6870832,.8206594],[.6797181,.8488253],[.6727481,.9095265],[.6645833,.9510032],[.6476727,.9906852],[.6292175,.996258],[.6067605,.9579689],[.5866436,.893601],[.5661608,.7979728],[.551633,.7181829],[.539265,.6246675],[.5305491,.5292222],[.5260994,.420745],[.5224176,.3229995],[.5226151,.2402932],[.5253855,.1693177],[.5306679,.1129544],[.5371162,.07240147],[.5437788,.04611277],[.5512122,.02891989],[.5591616,.01809867],[.5677017,.01123174],[.5756501,.00656182],[.5838496,.003660485],[.5926899,.002146038],[.6007595,.00125562],[.609689,.0007499602],[.6190357,.0004504866],[.6283244,.0002728945],[.6386031,.0001626139],[.6493716,.00009850216],[.6605153,.00006059423],[.6726908,.00003686778],[.6867121,.00002280989],[.7013987,.00001418905],[.7183437,.000008957794],[.7364157,.000005776205],[.7562422,.000003822312],[.7778403,.000002526004],[.7982168,.000001709524],[.8189538,.000001189292],[.8394434,.0000008480996],[.8595312,.0000006193677],[.8774655,.0000004661395],[.8932797,.0000003608705],[.907444,0],[.9201038,0],[.9294768,0],[.9374403,0],[.9448365,0],[.9518048,0],[.9555935,0],[.9589933,0],[.9623054,0],[.9650123,0],[.9666802,0],[.9678665,0],[.9687004,0],[.96927,0],[.9696107,0],[.969845,0],[.9698788,0]];

function meterChromaticityChartMode(){
 const el=document.getElementById('meterChromaticityChart');
 const mode=String(el&&el.value||'cie1931_2');
 return /^(cie1931_2|cie1964_10|cie1976_2|cie1976_10|cie2015_2|cie2015_10|ciemb_2|ciemb_10|cieopp_2)$/.test(mode)?mode:'cie1931_2';
}
function meterCieIsOpponentMode(mode){
 return /^cieopp_/.test(String(mode||meterChromaticityChartMode()));
}
function meterCieIsConeChartMode(mode){
 return /^(?:ciemb|cieopp)_/.test(String(mode||meterChromaticityChartMode()));
}
function meterChromaticityObserver(){
 const mode=meterChromaticityChartMode();
 if(/(?:1964|_10)$/.test(mode)) return mode.indexOf('2015')>=0||meterCieIsConeChartMode(mode)?'2015_10':'1964_10';
 if(mode.indexOf('2015')>=0||meterCieIsConeChartMode(mode)) return '2015_2';
 return '1931_2';
}
function meterObserverForReadings(readings){
 const observers=new Set();
 (Array.isArray(readings)?readings:[]).forEach(rd=>{
  if(!rd||!meterReadingHasLuminance(rd)) return;
  const observer=String(rd.observer||'1931_2');
  if(/^(?:1931_2|1964_10|2015_2|2015_10)$/.test(observer)) observers.add(observer);
 });
 return observers.size===1?[...observers][0]:null;
}
function meterChromaticityReadActive(){
 return !!(
  (typeof meterSeriesRunning!=='undefined'&&meterSeriesRunning)
  ||(typeof meterSeriesAwaitingReady!=='undefined'&&meterSeriesAwaitingReady)
  ||(typeof meterActionPending!=='undefined'&&meterActionPending)
  ||(typeof meterContinuousActive!=='undefined'&&meterContinuousActive)
  ||(typeof meterContinuousSuspendedForLgWrite!=='undefined'&&meterContinuousSuspendedForLgWrite)
  ||(typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
  ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
  ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
 );
}
function meterUpdateChromaticityChartLock(){
 const el=document.getElementById('meterChromaticityChart');
 if(!el) return;
 const locked=meterChromaticityReadActive();
 if(locked&&!meterChromaticityLockedMode) meterChromaticityLockedMode=String(el.value||'cie1931_2');
 if(!locked) meterChromaticityLockedMode='';
 el.disabled=locked;
 el.setAttribute('aria-disabled',locked?'true':'false');
 el.title=locked?'Chromaticity chart is locked while a measurement is running':'';
}
function meterCacheActiveChromaticityReadings(){
 if(!(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')) return;
 if(!meterActiveSeriesKey||!Array.isArray(meterReadings)||!meterReadings.length) return;
 const observer=meterObserverForReadings(meterReadings);
 if(!observer) return;
 meterCacheSeriesState('complete',{deferPersist:true});
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const snap=meterSeriesSnapshotForMode(meterSeriesCache&&meterSeriesCache[meterActiveSeriesKey],mode);
 if(!snap) return;
 const map=(snap.observer_readings&&typeof snap.observer_readings==='object')?snap.observer_readings:{};
 map[observer]={
  readings:JSON.parse(JSON.stringify(meterReadings)),
  white_reading:meterWhiteReading?JSON.parse(JSON.stringify(meterWhiteReading)):null,
  black_reading:meterSeriesBaselineBlack?JSON.parse(JSON.stringify(meterSeriesBaselineBlack)):null,
  updated_at:Date.now()
 };
 snap.observer_readings=map;
 snap.updated_at=Date.now();
 meterStoreSeriesSnapshot(meterActiveSeriesKey,snap);
 meterScheduleSeriesCachePersist();
}
function meterRestoreActiveChromaticityReadings(observer){
 if(!(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')) return false;
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const snap=meterSeriesSnapshotForMode(meterSeriesCache&&meterSeriesCache[meterActiveSeriesKey],mode);
 const entry=snap&&snap.observer_readings&&snap.observer_readings[observer];
 let readings=null,white=null,black=null;
 if(entry&&Array.isArray(entry.readings)){
  readings=entry.readings;
  white=entry.white_reading||null;
  black=entry.black_reading||null;
 }else if(snap&&Array.isArray(snap.readings)&&meterObserverForReadings(snap.readings)===observer){
  readings=snap.readings;
  white=snap.white_reading||null;
  black=snap.black_reading||null;
 }
 meterReadings=readings?JSON.parse(JSON.stringify(readings)):[];
 meterWhiteReading=white?JSON.parse(JSON.stringify(white)):null;
 meterSeriesBaselineBlack=black?JSON.parse(JSON.stringify(black)):null;
 meterLastChartCount=0;
 meterLastChartSignature='';
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 try{ showColorReadingDetail(null,{pin:false}); }catch(e){}
 if(Array.isArray(meterSeriesSteps)&&meterSeriesSteps.length){
  const completed=new Set(meterReadings.filter(rd=>rd&&rd.luminance!=null).map(rd=>meterStepNameKey(rd)));
  meterBuildPatchThumbs([...meterSeriesSteps],completed,null);
 }
 return !!meterReadings.length;
}

// CIE 1964 and CIE 170-2 are different observers. Their tristimulus values
// cannot be recovered from CIE 1931 XYZ without the source spectrum: two
// metamers with the same 1931 XYZ can differ under another observer. Only
// measurements stamped with the selected native observer are plotted.
// CIE 1976 u'v' is an exact projective transform once native XYZ is known.
const CIE2015_TO_LMS_2=[
 [0.210575136,0.855102038,-0.039698405],
 [-0.417074188,1.177257920,0.078628107],
 [-0.000000183,0.000000172,0.516833478]
];
const CIE2015_TO_LMS_10=[
 [0.217010354,0.835733794,-0.043510601],
 [-0.429979672,1.203889660,0.086210852],
 [-0.000000018,0.000000018,0.465792324]
];
const CIE_LMS_TO_CIE2015_2=[
 [1.947354386,-1.414462149,.364766123],
 [.689900827,.348321629,.000000178],
 [.000000460,-.000000617,1.934859310]
];
const CIE_LMS_TO_CIE2015_10=[
 [1.939864394,-1.346643543,.430449242],
 [.692839451,.349675448,.000000091],
 [.000000048,-.000000066,2.146879535]
];
// Native CIE 170-2 MacLeod-Boynton factors use the spectral-maximum S
// normalization. Keep them explicit because threshold-scaled opponent spaces
// such as 2754/4099 are defined in these native coordinates.
const CIE_MB_NATIVE_FACTORS_2=[0.68990078,0.34832169,0.03715959];
const CIE_MB_NATIVE_FACTORS_10=[0.69283938,0.34967553,0.05546866];
// Display factors use relative cone trolands: equal-energy S/(L+M)=1, matching
// MacLeod-Boynton practice and Cao, Pokorny & Smith (2005), Fig. 1.
const CIE_MB_FACTORS_2=[0.68990078,0.34832169,1.934859310];
const CIE_MB_FACTORS_10=[0.69283938,0.34967553,2.146879535];
const CIE_MB_LOCUS_S_SCALE_2=CIE_MB_FACTORS_2[2]/CIE_MB_NATIVE_FACTORS_2[2];
const CIE_MB_LOCUS_S_SCALE_10=CIE_MB_FACTORS_10[2]/CIE_MB_NATIVE_FACTORS_10[2];
const CIE_MB_EES_RAW_L_2=0.7078236164536152;
const CIE_MB_EES_RAW_L_10=0.6992367760459623;
function meterCieMbRelativeL(rawL,ten){
 const x=Math.max(0,Math.min(1,Number(rawL)||0));
 const e=ten?CIE_MB_EES_RAW_L_10:CIE_MB_EES_RAW_L_2;
 const r=e*.34/(.66*(1-e));
 return x/(x+r*(1-x));
}
function meterCieMbRawL(relativeL,ten){
 const x=Math.max(0,Math.min(1,Number(relativeL)||0));
 const e=ten?CIE_MB_EES_RAW_L_10:CIE_MB_EES_RAW_L_2;
 const r=e*.34/(.66*(1-e));
 const den=1-x+r*x;
 return Math.abs(den)>1e-12?(r*x/den):x;
}
function meterCieApplyMatrix(xyz,M){
 const X=Number(xyz.X),Y=Number(xyz.Y),Z=Number(xyz.Z);
 return {X:M[0][0]*X+M[0][1]*Y+M[0][2]*Z,Y:M[1][0]*X+M[1][1]*Y+M[1][2]*Z,Z:M[2][0]*X+M[2][1]*Y+M[2][2]*Z};
}
// Threshold-scaled, white-centred cone-opponent coordinates. The 2754 and
// 4099 factors are the same sensitivity scaling used by the built-in
// MacLeod-Boynton hue-circle series, so an equal-threshold series is circular.
function meterCieOpponentWhiteMb(ten){
 const p=ten?CIE_D65_COORDS.ciemb_10:CIE_D65_COORDS.ciemb_2;
 return {x:p[0],y:p[1]};
}
function meterCieOpponentFromMb(coord,ten){
 if(!coord) return null;
 const white=meterCieOpponentWhiteMb(!!ten);
 const sNativeScale=(ten?CIE_MB_NATIVE_FACTORS_10[2]/CIE_MB_FACTORS_10[2]:CIE_MB_NATIVE_FACTORS_2[2]/CIE_MB_FACTORS_2[2]);
 const raw=meterCieMbRawL(Number(coord.x),!!ten);
 const rawWhite=meterCieMbRawL(white.x,!!ten);
 return {
  x:(raw-rawWhite)*2754,
  y:(Number(coord.y)-white.y)*sNativeScale*4099,
  Y:Number(coord.Y),L:Number(coord.L),M:Number(coord.M),S:Number(coord.S),
  reference:!!coord.reference
 };
}
function meterCieMbFromOpponent(x,y,ten){
 const white=meterCieOpponentWhiteMb(!!ten);
 const sNativeScale=(ten?CIE_MB_NATIVE_FACTORS_10[2]/CIE_MB_FACTORS_10[2]:CIE_MB_NATIVE_FACTORS_2[2]/CIE_MB_FACTORS_2[2]);
 return {
  x:meterCieMbRelativeL(meterCieMbRawL(white.x,!!ten)+Number(x)/2754,!!ten),
  y:white.y+Number(y)/(4099*sNativeScale)
 };
}
// Gamut standards and generated patch targets are specified in CIE 1931
// coordinates and normally have no source spectrum. Give them a stable
// reference projection in every chart so the requested gamut and targets
// remain usable. Native meter readings still require the selected observer.
function meterCieReferenceCoordFromXYZ(xyz){
 if(!xyz) return null;
 const mode=meterChromaticityChartMode();
 const X=Number(xyz.X),Y=Number(xyz.Y),Z=Number(xyz.Z);
 if(![X,Y,Z].every(Number.isFinite)) return null;
 if(meterCieIsConeChartMode(mode)){
  const ten=/_10$/.test(mode);
  const lms=meterCieApplyMatrix({X:X,Y:Y,Z:Z},ten?CIE2015_TO_LMS_10:CIE2015_TO_LMS_2);
  const f=ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
  const L=f[0]*lms.X,M=f[1]*lms.Y,S=f[2]*lms.Z,lm=L+M;
  if(!(lm>0)) return null;
  const l=meterCieMbRelativeL(L/lm,ten);
  const coord={x:l,y:S/lm,Y:lm,L:l*lm,M:(1-l)*lm,S:S,reference:true};
  return meterCieIsOpponentMode(mode)?meterCieOpponentFromMb(coord,ten):coord;
 }
 if(mode.indexOf('cie1976_')===0){
  const d=X+15*Y+3*Z;
  return d>0?{x:4*X/d,y:9*Y/d,Y:Y,reference:true}:null;
 }
 const s=X+Y+Z;
 return s>0?{x:X/s,y:Y/s,Y:Y,reference:true}:null;
}
function meterCie2015XYZ(xyz){
 if(!xyz) return null;
 if(Number.isFinite(Number(xyz.XF))&&Number.isFinite(Number(xyz.YF))&&Number.isFinite(Number(xyz.ZF))){
  return {X:Number(xyz.XF),Y:Number(xyz.YF),Z:Number(xyz.ZF),native:true};
 }
 const X=Number(xyz.X),Y=Number(xyz.Y),Z=Number(xyz.Z);
 if(![X,Y,Z].every(Number.isFinite)) return null;
 const observer=String(xyz.observer||'');
 if(observer==='2015_2'||observer==='2015_10') return {X:X,Y:Y,Z:Z,native:true};
 return null;
}
function meterCieChartCoordFromXYZ(xyz){
 if(!xyz) return null;
 const mode=meterChromaticityChartMode();
 let X=Number(xyz.X),Y=Number(xyz.Y),Z=Number(xyz.Z);
 const observer=String(xyz.observer||'');
 const desiredObserver=meterChromaticityObserver();
 // Unstamped target XYZ is defined in the application's CIE 1931 reference
 // space. It is valid only in 1931 and its exact 1976 2 degree projection.
 if(!observer&&desiredObserver!=='1931_2') return meterCieReferenceCoordFromXYZ(xyz);
 if(observer&&observer!==desiredObserver) return null;
 const wantsTen=/_10$/.test(mode);
 if(mode.indexOf('cie2015_')===0||meterCieIsConeChartMode(mode)){
  const f=meterCie2015XYZ(xyz);
  if(!f) return null;
  X=f.X;Y=f.Y;Z=f.Z;
 }
 if(![X,Y,Z].every(Number.isFinite)) return null;
 if(meterCieIsConeChartMode(mode)){
  const lms=meterCieApplyMatrix({X:X,Y:Y,Z:Z},wantsTen?CIE2015_TO_LMS_10:CIE2015_TO_LMS_2);
  const f=wantsTen?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
  const L=f[0]*lms.X,M=f[1]*lms.Y,S=f[2]*lms.Z;
  const lm=L+M;
  if(!(lm>0)) return {x:0,y:0,Y:0,L:0,M:0,S:0};
  const l=meterCieMbRelativeL(L/lm,wantsTen);
  const coord={x:l,y:S/lm,Y:lm,L:l*lm,M:(1-l)*lm,S:S};
  return meterCieIsOpponentMode(mode)?meterCieOpponentFromMb(coord,wantsTen):coord;
 }
 if(mode.indexOf('cie1976_')===0){
  const d=X+15*Y+3*Z;
  return d>0?{x:4*X/d,y:9*Y/d,Y:Y}:{x:0,y:0,Y:Y};
 }
 const s=X+Y+Z;
 return s>0?{x:X/s,y:Y/s,Y:Y}:{x:0,y:0,Y:Y};
}
function meterCieChartCoordFromXy(x,y,Y){
 x=Number(x);y=Number(y);Y=Number.isFinite(Number(Y))?Number(Y):1;
 if(!(x>=0&&y>0)) return null;
 return meterCieReferenceCoordFromXYZ({X:x*Y/y,Y:Y,Z:(1-x-y)*Y/y});
}
function meterCieDeclaredMbTargetCoord(reading){
 const mode=meterChromaticityChartMode();
 if(!meterCieIsConeChartMode(mode)||!reading) return null;
 let source=reading;
 if((!Number.isFinite(Number(source.mb_target_l))||!Number.isFinite(Number(source.mb_target_s)))
    &&typeof meterCanonicalSeriesStep==='function'){
  const step=meterCanonicalSeriesStep(reading);
  if(step) source=step;
 }
 const l=Number(source.mb_target_l),s=Number(source.mb_target_s);
 const lm=Number(source.mb_target_lm);
 if(!Number.isFinite(l)||!Number.isFinite(s)) return null;
 const coord={x:l,y:s,Y:Number.isFinite(lm)?lm:null};
 return meterCieIsOpponentMode(mode)?meterCieOpponentFromMb(coord,/_10$/.test(mode)):coord;
}
function meterCieChartTargetCoord(reading,targetXYZ){
 // A zero-luminance target has no defined chromaticity. Keep the black target
 // on the reference-white chromaticity instead of allowing {0,0,0} to become
 // the chart origin. This also keeps the target in the same place before and
 // after the black patch is measured.
 if(targetXYZ&&meterXyzIsBlack(targetXYZ)&&meterReadingTargetsBlack(reading)){
  const white=meterCieD65Coord();
  return {x:white.x,y:white.y,Y:0,reference:true,blackTarget:true};
 }
 const declared=meterCieDeclaredMbTargetCoord(reading);
 if(declared){
  if(declared.Y==null||!Number.isFinite(Number(declared.Y))){
   declared.Y=targetXYZ&&Number.isFinite(Number(targetXYZ.Y))?Number(targetXYZ.Y):0;
  }
  return declared;
 }
 return targetXYZ?meterCieChartCoordFromXYZ(targetXYZ):null;
}
function meterCieReferenceXyForChartCoord(x,y){
 const mode=meterChromaticityChartMode();
 x=Number(x);y=Number(y);
 if(![x,y].every(Number.isFinite)) return null;
 if(mode.indexOf('cie1976_')===0){
  const d=6*x-16*y+12;
  return Math.abs(d)>1e-9?{x:9*x/d,y:4*y/d}:null;
 }
 if(meterCieIsConeChartMode(mode)){
  const ten=/_10$/.test(mode),f=ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
  const mb=meterCieIsOpponentMode(mode)?meterCieMbFromOpponent(x,y,ten):{x:x,y:y};
  const rawL=meterCieMbRawL(mb.x,ten);
  const raw={X:rawL/f[0],Y:(1-rawL)/f[1],Z:mb.y/f[2]};
  const xyz=meterCieApplyMatrix(raw,ten?CIE_LMS_TO_CIE2015_10:CIE_LMS_TO_CIE2015_2);
  const s=xyz.X+xyz.Y+xyz.Z;
  return s>0?{x:xyz.X/s,y:xyz.Y/s}:null;
 }
 return {x:x,y:y};
}
// Observer-specific coordinates obtained by integrating the official CIE D65
// spectrum with the corresponding CMFs/cone fundamentals. D65 is spectral,
// so unlike a generic xy target it can be represented under every observer.
const CIE_D65_COORDS={
 cie1931_2:[.3127,.3290],
 cie1964_10:[.3138236469,.3309989855],
 cie2015_2:[.3134524493,.3308018280],
 cie2015_10:[.3137862795,.3312747630],
 ciemb_2:[.6495102165,1.0757493978],
 ciemb_10:[.6492472717,1.0717425460],
 cieopp_2:[0,0]
};
function meterCieD65Coord(){
 const mode=meterChromaticityChartMode();
 if(mode==='cie1976_2'){
  const p=CIE_D65_COORDS.cie1931_2,d=-2*p[0]+12*p[1]+3;
  return {x:4*p[0]/d,y:9*p[1]/d,Y:1,reference:true};
 }
 if(mode==='cie1976_10'){
  const p=CIE_D65_COORDS.cie1964_10,d=-2*p[0]+12*p[1]+3;
  return {x:4*p[0]/d,y:9*p[1]/d,Y:1,reference:true};
 }
 const p=CIE_D65_COORDS[mode]||CIE_D65_COORDS.cie1931_2;
 return {x:p[0],y:p[1],Y:1,reference:true};
}
function meterCieTargetsAvailable(){
 return true;
}
function meterCieMacLeodDisplayLocus(source,sScale,ten){
 const scale=(Number(sScale)>0)?Number(sScale):1;
 const locus=source.map(p=>[meterCieMbRelativeL(p[0],!!ten),p[1]*scale]);
 if(locus.length<5) return locus;
 // In this projection the 390 nm endpoint and its tiny 395 nm reversal sit
 // high on the diagram, where the straight purple boundary meets the spectral
 // arc as a conspicuous hook. Preserve the official table above and round only
 // that display seam with a short quadratic transition into the 405 nm point.
 const violet=locus[0],spectralJoin=locus[3],red=locus[locus.length-1];
 const purpleJoin=[
  violet[0]+(red[0]-violet[0])*.06,
  violet[1]+(red[1]-violet[1])*.06
 ];
 const rounded=[];
 for(let i=1;i<=5;i++){
  const t=i/5,u=1-t;
  rounded.push([
   u*u*purpleJoin[0]+2*u*t*violet[0]+t*t*spectralJoin[0],
   u*u*purpleJoin[1]+2*u*t*violet[1]+t*t*spectralJoin[1]
  ]);
 }
 return locus.slice(3).concat([purpleJoin],rounded);
}
function meterCieChartLocus(){
 const mode=meterChromaticityChartMode();
 if(mode==='cie2015_2') return CIE_LOCUS_2015_2;
 if(mode==='cie2015_10') return CIE_LOCUS_2015_10;
 if(mode==='ciemb_2') return meterCieMacLeodDisplayLocus(CIE_LOCUS_MB_2,CIE_MB_LOCUS_S_SCALE_2,false);
 if(mode==='ciemb_10') return meterCieMacLeodDisplayLocus(CIE_LOCUS_MB_10,CIE_MB_LOCUS_S_SCALE_10,true);
 if(mode==='cieopp_2') return meterCieMacLeodDisplayLocus(CIE_LOCUS_MB_2,CIE_MB_LOCUS_S_SCALE_2,false).map(p=>{
  const c=meterCieOpponentFromMb({x:p[0],y:p[1]},false);return [c.x,c.y];
 });
 const locus=(mode==='cie1964_10'||mode==='cie1976_10')?CIE_LOCUS_1964:CIE_LOCUS;
 if(mode.indexOf('cie1976_')===0){
  return locus.map(p=>{
   const d=-2*p[0]+12*p[1]+3;
   return [4*p[0]/d,9*p[1]/d];
  });
 }
 return locus;
}
function meterCiePointInsideLocus(point,locus){
 if(!point||!Array.isArray(locus)||locus.length<3) return false;
 const px=Number(point.x),py=Number(point.y);
 if(!Number.isFinite(px)||!Number.isFinite(py)) return false;
 let inside=false;
 for(let i=0,j=locus.length-1;i<locus.length;j=i++){
  const xi=locus[i][0],yi=locus[i][1],xj=locus[j][0],yj=locus[j][1];
  if((yi>py)!==(yj>py)&&px<(xj-xi)*(py-yi)/(yj-yi)+xi) inside=!inside;
 }
 return inside;
}
// Reference gamut primaries specified without spectra can project just beyond
// an alternate observer's spectral boundary. A display gamut cannot extend
// outside the visible-colour locus, so constrain only that reference outline
// to its nearest boundary segment. Measured points remain completely raw.
function meterCieGamutCoordWithinLocus(coord){
 if(!coord) return null;
 const locus=meterCieChartLocus();
 if(!Array.isArray(locus)||locus.length<3||meterCiePointInsideLocus(coord,locus)) return coord;
 const xs=locus.map(p=>p[0]),ys=locus.map(p=>p[1]);
 const xScale=Math.max(1e-9,Math.max(...xs)-Math.min(...xs));
 const yScale=Math.max(1e-9,Math.max(...ys)-Math.min(...ys));
 let best=null,bestD=Infinity;
 for(let i=0;i<locus.length;i++){
  const a=locus[i],b=locus[(i+1)%locus.length];
  const ax=a[0]/xScale,ay=a[1]/yScale,bx=b[0]/xScale,by=b[1]/yScale;
  const px=coord.x/xScale,py=coord.y/yScale,dx=bx-ax,dy=by-ay;
  const den=dx*dx+dy*dy;
  const t=den>0?Math.max(0,Math.min(1,((px-ax)*dx+(py-ay)*dy)/den)):0;
  const qx=ax+t*dx,qy=ay+t*dy,d=(px-qx)*(px-qx)+(py-qy)*(py-qy);
  if(d<bestD){bestD=d;best={x:(qx*xScale),y:(qy*yScale)};}
 }
 return best?Object.assign({},coord,best,{locusConstrained:true}):coord;
}
function meterCieGamutCoords(primaries){
 if(!primaries) return {R:null,G:null,B:null};
 const convert=p=>meterCieGamutCoordWithinLocus(meterCieChartCoordFromXy(p.x,p.y,1));
 return {R:convert(primaries.R),G:convert(primaries.G),B:convert(primaries.B)};
}
function meterStrokeCieLocus2d(ctx,points,toX,toY){
 if(!points||points.length<2) return;
 ctx.beginPath();ctx.moveTo(toX(points[0][0]),toY(points[0][1]));
 for(let i=1;i<points.length-1;i++){
  const p=points[i],n=points[i+1];
  ctx.quadraticCurveTo(toX(p[0]),toY(p[1]),toX((p[0]+n[0])/2),toY((p[1]+n[1])/2));
 }
 const last=points[points.length-1];
 ctx.lineTo(toX(last[0]),toY(last[1]));
 ctx.lineTo(toX(points[0][0]),toY(points[0][1]));
 ctx.closePath();ctx.stroke();
}
function cie3dStrokeSmoothLocus(ctx,points){
 if(!points||points.length<2) return;
 ctx.beginPath();ctx.moveTo(points[0].sx,points[0].sy);
 for(let i=1;i<points.length-1;i++){
  const p=points[i],n=points[i+1];
  ctx.quadraticCurveTo(p.sx,p.sy,(p.sx+n.sx)/2,(p.sy+n.sy)/2);
 }
 const last=points[points.length-1];
 ctx.lineTo(last.sx,last.sy);ctx.lineTo(points[0].sx,points[0].sy);
 ctx.closePath();ctx.stroke();
}
function meterCieChartAxis(){
 const mode=meterChromaticityChartMode();
 const ten=/_10$/.test(mode),degree=ten?'10\u00B0':'2\u00B0';
 if(mode.indexOf('cie1976_')===0) return {x:'u\u2032',y:'v\u2032',title:'CIE 1976 UCS Chromaticity ('+degree+')',threeD:'CIE 1976 L*u*v* ('+degree+', 3D)'};
 if(mode.indexOf('cie2015_')===0) return {x:'xF',y:'yF',title:'CIE 170-2:2015 Chromaticity ('+degree+')',threeD:'CIE 170-2 XF YF ZF ('+degree+', 3D)'};
 if(mode.indexOf('ciemb_')===0) return {x:'L/(L+M)',y:'S/(L+M)',title:'MacLeod-Boynton Relative Cone-Troland Chromaticity ('+degree+')',threeD:'MacLeod-Boynton Relative Cone Trolands ('+degree+', 3D)'};
 if(meterCieIsOpponentMode(mode)) return {x:'L-M opponent response',y:'S-(L+M) opponent response',title:'Cone-Opponent Polar Chromaticity ('+degree+')',threeD:'Cone-Opponent Space with Achromatic Axis ('+degree+', 3D)'};
 if(mode==='cie1964_10') return {x:'x',y:'y',title:'CIE 1964 Chromaticity (10\u00B0)',threeD:'CIE 1964 X10 Y10 Z10 (3D)'};
 return {x:'x',y:'y',title:'CIE 1931 Chromaticity (2\u00B0)',threeD:'CIE 1931 XYZ (2\u00B0, 3D)'};
}
function meterOnChromaticityChartChange(){
 const el=document.getElementById('meterChromaticityChart');
 if(meterChromaticityReadActive()){
  if(el&&meterChromaticityLockedMode) el.value=meterChromaticityLockedMode;
  meterUpdateChromaticityChartLock();
  toast('Chromaticity chart is locked until the measurement finishes.',true);
  return;
 }
 meterCacheActiveChromaticityReadings();
 cie2dResetView();
 try{ meterSaveColorPrefs(); }catch(e){}
 meterUpdateCie3dLabel();
 const observer=meterChromaticityObserver();
 const chromaticitySeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 const hadOtherReadings=chromaticitySeries&&Array.isArray(meterReadings)&&meterReadings.length>0;
 const restored=chromaticitySeries&&meterRestoreActiveChromaticityReadings(observer);
 if(hadOtherReadings&&!restored){
  const observerLabel={1931_2:'CIE 1931 2\u00B0',1964_10:'CIE 1964 10\u00B0',2015_2:'CIE 2015 2\u00B0',2015_10:'CIE 2015 10\u00B0'}[observer]||observer;
  toast('No cached samples for '+observerLabel+'. Read the series for this observer.',true);
 }
 if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations'){
  if(meterReadings&&meterReadings.length) drawAllCharts(meterReadings);
  else if(meterSeriesSteps&&meterSeriesSteps.length) drawAllChartsPreset(meterSeriesSteps);
 }
 // The MacLeod series are only selectable on an MB chart, so the option list has
 // to follow the chart the moment it changes.
 if(typeof meterSyncColorCheckerSeriesUi==='function'){
  try{ meterSyncColorCheckerSeriesUi(['colors','saturations'].includes(meterActiveSeriesType)?meterActiveSeriesPoints:null); }catch(e){}
 }
 meterUpdateReadButtons();
}

// CIE L* from Y/Yn (normalized luminance 0-1) — perceptual lightness
function ynToLstar(yn){
 const a=Math.abs(yn);
 const f=a>0.008856451679?Math.pow(a,1/3):(903.2963*a+16)/116;
 const L=116*f-16;
 return yn>=0?L:-L;
}

// Reads the selected RGB balance formula: shadow-weighted perceptual L*, the
// original unweighted absolute L*, or HCFR-style unit-Y XYZ from measured xy.
function meterRgbBalanceFormula(){
 const sel=document.getElementById('meterRgbBalanceFormula');
 if(sel && sel.value) return sel.value;
 return 'absolute';
}

// Perceptual RGB balance shadow emphasis. A fourth-power falloff concentrates
// the added separation below 30% IRE, where small channel errors are easiest
// to lose in a normal base-100 chart. The gain is bounded at 20x near black
// and is exactly 1x at 100% IRE and above.
function meterPerceptualRgbBalanceGain(reading){
 const slot=(typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(reading):null;
 const measuredIre=Number(slot!=null?slot:(reading&&reading.ire));
 if(!Number.isFinite(measuredIre)) return 1;
 const normalized=Math.max(0,Math.min(100,measuredIre))/100;
 return 1+19*Math.pow(1-normalized,4);
}

// Row object for the per-reading balance target lookup. The eotf-mode bars
// must grade against the SAME absolute luminance target the per-point tooltip
// uses (meterTargetXYZForReading -> meterGreyscaleTargetYFromYn on the
// worker-stamped target_Yn). Passing the stamp through lets
// meterGreyTargetLuminanceForChartPoint take its metadata path instead of
// re-deriving the signal from the rounded slot IRE. On a full-range 10-bit
// series the wire code and the displayed IRE differ (code 106 -> 10.358%
// shown as "10.4"), so ire/100 vs code/input_max shifts the target by up to
// ~1% luminance at low IRE -- enough for the tooltip to report "Y too high"
// while every R/G/B bar reads "too low" on the same patch. SDR26 rows are
// unaffected (their branch runs first inside the lookup); custom greyscale
// keeps its nominal-slot target; HDR/DV keep their existing signal paths.
function meterBalanceTargetRow(reading,ire){
 const row={stimulus:ire,code:(reading&&reading.r_code!=null)?reading.r_code:null};
 try{
  if(!meterChartIsDv()&&!meterChartIsHdr()
   &&!(typeof meterGreyscaleCustomTargetActive==='function'&&meterGreyscaleCustomTargetActive())
   &&reading&&reading.target_Yn!=null){
   row.target_Yn=Number(reading.target_Yn);
  }
 }catch(e){}
 return row;
}

// L* RGB balance shared by the weighted Perceptual mode and the unweighted
// Absolute mode. The ire>0 branch builds a luminance-compensated target
// (chroma-only) in 'absolute'/'relative' grey-reference modes, or an absolute
// target in 'eotf' grey-reference mode.
function rgbBalancePerceptual(reading,whiteRef,modeOrIncl,blackLevel,shadowWeighted){
 const readingXYZ=meterReadingXYZ(reading);
 const whiteXYZ=meterReadingXYZ(whiteRef);
 if(!readingXYZ||!whiteXYZ||whiteXYZ.Y<=0) return {R:100,G:100,B:100,noChroma:true};
 // A patch that emitted no light has no chromaticity, so it has no RGB balance.
 // In the chroma-only modes the target is rescaled to the measured luminance,
 // so a zero measurement would otherwise collapse target and measurement onto
 // each other and plot as a flawless 100/100/100.
 if(!(readingXYZ.Y>0)) return {R:100,G:100,B:100,noChroma:true};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 // Use the absolute D65 white target for greyscale RGB balance in all modes
 // so HDR/DV 100% white shows its real white-point error instead of being
 // pinned to 100/100/100 by self-normalizing to the measured white.
 const wp = meterTargetWhitePoint();
 const wXn = wp.X;
 const wZn = wp.Z;
 // Measured response is normalized by its measured 100% white. In Absolute Y
 // mode the target must use that SAME scale so a measured white above/below
 // Target White moves all three channels above/below 100. Chroma-only modes
 // normalize the target independently because luminance error is excluded.
 const mXn=readingXYZ.X/whiteXYZ.Y, mYn=readingXYZ.Y/whiteXYZ.Y, mZn=readingXYZ.Z/whiteXYZ.Y;
 const ire=((typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(reading):null)||reading.ire;
 let lcXn,lcYn,lcZn;
 if(ire!=null&&ire>=0){
 // Target: D65 white at the active grey-target luminance.
  const Lw=meterGreyTargetPeak(whiteXYZ.Y);
  const explicitBlack=Number(blackLevel);
  const Lb=Number.isFinite(explicitBlack)&&explicitBlack>=0?explicitBlack:meterBlackReadingY();
  // Route the gamma target through meterGreyTargetLuminanceForChartPoint so the
  // RGB-balance luminance-error bars share the SAME stimulus-based target the
  // gamma/EOTF chart and the per-point tooltip use. For SDR26 that path derives
  // the target from stimulus/109 (transport-independent) instead of re-decoding
  // the wire code through meterGreyCodeRange, whose range is limited-only and
  // skews the gamma error on full-range output (min=0 codes decoded through a
  // min=16 range -> wildly wrong signal at low/mid IRE, the "unbalanced lines").
  // Non-SDR26 modes fall straight back to meterGreyTargetLuminance(ire,...,code).
  const tgtLum=(meterReadingIsPeakHeadroom(reading)&&mode!=='eotf') ? readingXYZ.Y :
   ((typeof meterGreyTargetLuminanceForChartPoint==='function')
    ? meterGreyTargetLuminanceForChartPoint(ire/100,Lw,Lb,meterBalanceTargetRow(reading,ire))
    : meterGreyTargetLuminance(ire,Lw,Lb,reading.r_code));
  const targetNormY=(mode==='eotf')?whiteXYZ.Y:Lw;
  const tYn=(targetNormY>0)?tgtLum/targetNormY:0;
  const tXn=wXn*tYn;
  const tZn=wZn*tYn;
  if(mode==='eotf'){
   // Include luminance error: compare measured to absolute target without
   // rescaling — under/over-bright patches now skew the R/G/B bars.
   lcXn=tXn; lcYn=tYn; lcZn=tZn;
  } else {
   // Chroma-only (absolute or relative): lift/lower the target to the measured
   // Y so pure luminance errors don't show up as equal R/G/B shifts.
   const lumRatio=(tYn>0)?Math.max(0,mYn)/tYn:1;
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
 // The inline fallback keeps this long-standing function independently
 // testable when extracted from the generated WebUI source.
 const weighted=shadowWeighted!==false;
 const fallbackIreValue=ire==null?NaN:Number(ire);
 const fallbackIre=Number.isFinite(fallbackIreValue)?Math.max(0,Math.min(100,fallbackIreValue))/100:1;
 const shadowGain=weighted
  ? ((typeof meterPerceptualRgbBalanceGain==='function')
    ? meterPerceptualRgbBalanceGain(reading)
    : 1+19*Math.pow(1-fallbackIre,4))
  : 1;
 // Per-channel percent: magnify the signed L* error around the neutral 100
 // baseline. A perfectly balanced channel remains exactly 100 at every IRE.
 return {
  R:(ynToLstar(mRgb[0])-ynToLstar(tRgb[0]))*shadowGain+100,
  G:(ynToLstar(mRgb[1])-ynToLstar(tRgb[1]))*shadowGain+100,
  B:(ynToLstar(mRgb[2])-ynToLstar(tRgb[2]))*shadowGain+100
 };
}

// Original unweighted L* balance retained as an explicit comparison view.
function rgbBalanceAbsolute(reading,whiteRef,modeOrIncl,blackLevel){
 return rgbBalancePerceptual(reading,whiteRef,modeOrIncl,blackLevel,false);
}

// HCFR-style RGB balance for the luma-mode-OFF branch.
// Modes 0 and 2 both use a unit-Y XYZ built from the measured chromaticity;
// only mode 1 (Absolute Y w/gamma) rescales by measuredY / targetY.
function rgbBalanceHCFR(reading,whiteRef,modeOrIncl,blackLevel){
 const readingXYZ=meterReadingXYZ(reading);
 const whiteXYZ=meterReadingXYZ(whiteRef);
 if(!readingXYZ||!whiteXYZ||whiteXYZ.Y<=0) return {R:100,G:100,B:100,noChroma:true};
 // A patch that emitted no light has no chromaticity, so it has no RGB balance.
 // Report that explicitly instead of returning a neutral 100/100/100, which
 // reads as "perfectly balanced" on the chart and in the report tables.
 if(!(readingXYZ.Y>0)) return {R:100,G:100,B:100,noChroma:true};
 const mode = meterResolveGreyRefMode(modeOrIncl);
 const s = readingXYZ.X+readingXYZ.Y+readingXYZ.Z;
 if(!(s>0)) return {R:100,G:100,B:100,noChroma:true};
 const x = readingXYZ.X/s, y = readingXYZ.Y/s;
 if(!(y>0)) return {R:100,G:100,B:100,noChroma:true};
 let fact = 1.0;
 if(mode==='eotf'){
  const explicitBlack=Number(blackLevel);
  const Lb=Number.isFinite(explicitBlack)&&explicitBlack>=0?explicitBlack:meterBlackReadingY();
  const targetPeak = meterGreyTargetPeak(whiteXYZ.Y);
  const targetIre=((typeof meterGreyscaleTargetSlotIre==='function')?meterGreyscaleTargetSlotIre(reading):null)||reading.ire;
  // Same stimulus-based target as the gamma chart (see rgbBalancePerceptual):
  // avoids the limited-only meterGreyCodeRange skewing full-range gamma error.
  const tgtY = (typeof meterGreyTargetLuminanceForChartPoint==='function')
   ? meterGreyTargetLuminanceForChartPoint(targetIre/100, targetPeak, Lb, meterBalanceTargetRow(reading,targetIre))
   : meterGreyTargetLuminance(targetIre, targetPeak, Lb, reading.r_code);
  fact = (tgtY>0 && readingXYZ.Y>=0) ? readingXYZ.Y / tgtY : 1.0;
 }
 const Xn = (x/y)*fact, Yn = 1.0*fact, Zn = ((1-x-y)/y)*fact;
 const gamut = meterAnalysisGamut();
 const [r,g,b] = xyzToLinRgb(Xn,Yn,Zn, gamut.xyzToRgb);
 return { R:r*100, G:g*100, B:b*100 };
}

// Dispatcher — keeps every existing caller working while honoring the
// new <select id="meterRgbBalanceFormula"> selector.
function rgbBalance(reading,whiteRef,modeOrIncl,blackLevel){
 const formula=meterRgbBalanceFormula();
 if(formula==='hcfr') return rgbBalanceHCFR(reading,whiteRef,modeOrIncl,blackLevel);
 if(formula==='absolute') return rgbBalanceAbsolute(reading,whiteRef,modeOrIncl,blackLevel);
 return rgbBalancePerceptual(reading,whiteRef,modeOrIncl,blackLevel);
}

// RGB agreement for a colour-series patch. Greyscale RGB balance compares a
// neutral reading with D65, but applying that formula to a red/green/blue
// target reports the intentional colour channels as enormous balance errors.
// Compare measured and target RGB component-by-component after removing the
// measured black floor and normalizing the usable span to measured white.
function meterColorPatchRgbBalance(reading,whiteRef,blackRef,includeLuminance){
 const measured=meterReadingXYZ(reading);
 const target=meterColorDeltaTargetXYZ(reading,!!includeLuminance);
 const white=meterReadingXYZ(whiteRef);
 if(!measured||!target||!white||!(white.Y>0)||!(measured.Y>0)) return {R:null,G:null,B:null,noChroma:true};
 const black=meterReadingXYZ(blackRef)||{X:0,Y:0,Z:0};
 const spanY=white.Y-black.Y;
 if(!(spanY>0)) return {R:null,G:null,B:null,noChroma:true};
 const gamut=meterAnalysisGamut();
 const subtractBlack=xyz=>({X:xyz.X-black.X,Y:xyz.Y-black.Y,Z:xyz.Z-black.Z});
 const measuredSpan=subtractBlack(measured);
 const targetSpan=subtractBlack(target);
 const whiteSpan=subtractBlack(white);
 const m=xyzToLinRgb(measuredSpan.X/spanY,measuredSpan.Y/spanY,measuredSpan.Z/spanY,gamut.xyzToRgb);
 const w=xyzToLinRgb(whiteSpan.X/spanY,whiteSpan.Y/spanY,whiteSpan.Z/spanY,gamut.xyzToRgb);
 const t=xyzToLinRgb(targetSpan.X/spanY,targetSpan.Y/spanY,targetSpan.Z/spanY,gamut.xyzToRgb);
 const dominant=t.reduce((best,value,index)=>Math.abs(value)>Math.abs(t[best])?index:best,0);
 const targetDominant=t[dominant];
 const measuredDominant=m[dominant];
 if(!(Math.abs(targetDominant)>1e-9)||!(Math.abs(measuredDominant)>1e-9)) return {R:null,G:null,B:null,noChroma:true};
 let scaledTarget,baseline,componentScale;
 if(includeLuminance){
  // Luminance-inclusive RGB must use the same absolute XYZ target as xyY and
  // Delta E. A perfect measured target therefore lands at 100/100/100, while
  // an equal-channel luminance miss moves the driven components away from 100.
  // The old dominant-channel rescale erased that luminance miss and could show
  // perfect RGB while luminance-inclusive Delta E correctly grew worse.
  scaledTarget=t;
  baseline=[100,100,100];
  componentScale=Math.max(Math.abs(targetDominant),1e-9);
 }else{
  // Chroma-only balance retains the target-ray normalization: intentional
  // luminance differences are removed before component agreement is shown.
  const targetScale=measuredDominant/targetDominant;
  scaledTarget=t.map(value=>value*targetScale);
  const whiteScale=Math.max(Math.abs(w[0]),Math.abs(w[1]),Math.abs(w[2]),1e-9);
  baseline=w.map(value=>value*100/whiteScale);
  componentScale=Math.max(Math.abs(measuredDominant),1e-9);
 }
 const out=m.map((value,index)=>{
  if(includeLuminance) return baseline[index]+(value-scaledTarget[index])*100/componentScale;
  const active=Math.abs(scaledTarget[index])>Math.abs(measuredDominant)*1e-6;
  const center=active?baseline[index]:100;
  return center+(value-scaledTarget[index])*100/componentScale;
 });
 return {R:out[0],G:out[1],B:out[2]};
}

function meterLiveRgbData(reading){
 if(!reading) return {mode:'balance',R:100,G:100,B:100};
 const measured=meterReadingXYZ(reading);
 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(!isColorSeries){
  const whiteRef=meterEffectiveGreyscaleWhiteReference(Array.isArray(meterReadings)&&meterReadings.length?meterReadings:[reading]);
  const blackReadings=Array.isArray(meterReadings)&&meterReadings.length?meterReadings:[reading];
  const blackLevel=meterChartBlackLevel(blackReadings);
  return whiteRef?{mode:'balance',...rgbBalance(reading,whiteRef,meterGreyRefMode(),blackLevel)}:{mode:'balance',R:100,G:100,B:100};
 }
 // A neutral color-series patch uses the exact greyscale RGB-balance path.
 // This keeps the result centered on 100 (a +1% channel error is 101%) and
 // avoids the exaggerated dominant-channel color-patch normalization.
 if(meterColorSeriesNeutralUsesGreyscaleAnalysis(reading)){
  const neutralReadings=(Array.isArray(meterReadings)&&meterReadings.length?meterReadings:[reading])
   .filter(rd=>rd&&meterReadingIsGreyscale(rd))
   .map(meterNeutralColorGreyscaleReading);
  const grey=meterNeutralColorGreyscaleReading(reading);
  const whiteRef=meterGreyscaleRgbBalanceReference(neutralReadings);
  const blackLevel=meterChartBlackLevel(neutralReadings);
  return whiteRef?{mode:'balance',...rgbBalance(grey,whiteRef,meterGreyRefMode(),blackLevel)}:{mode:'balance',R:100,G:100,B:100};
 }
 if(!measured||!(measured.Y>0)) return {mode:'balance',R:null,G:null,B:null,noChroma:true};
 const readings=Array.isArray(meterReadings)&&meterReadings.length?meterReadings:[reading];
 let whiteRef=meterFindSeriesWhiteReading(readings)
  ||(meterWhiteReading&&!meterWhiteReading.synthetic_target?meterWhiteReading:null);
 // Continuous/single reads on a colour patch usually have no measured white in
 // the current series (saturation sweeps carry no White step), which left the
 // live RGB bars stuck at "--" during continuous measurement. Fall back to the
 // latest mode-matched measured white from any cached series, then to a
 // synthetic target-white reference (target white point at the colour
 // reference luminance) so the bars stay usable for live calibration.
 if(!whiteRef&&typeof meterFindMeasuredWhiteReading==='function'){
  try{ whiteRef=meterFindMeasuredWhiteReading(); }catch(e){}
 }
 if(!whiteRef&&typeof meterSyntheticGreyWhiteReading==='function'){
  try{ whiteRef=meterSyntheticGreyWhiteReading(meterColorReferenceNits()); }catch(e){}
 }
 const blackRef=(typeof meterSeriesBaselineBlack!=='undefined')?meterSeriesBaselineBlack:null;
 const includeLuminance=(typeof meterColorIncludeLum==='function')?meterColorIncludeLum():false;
 const balance=whiteRef?meterColorPatchRgbBalance(reading,whiteRef,blackRef,includeLuminance):null;
 return balance?{mode:'balance',...balance}:{mode:'balance',R:null,G:null,B:null,noChroma:true};
}

// Shared IRE->signal-fraction convention for every per-point gamma metric, so
// the measured and target lines can never disagree about the divisor.
function meterGammaSignalFraction(ire){
 let _gammaHasHeadroomAnchor=false;
 try{
  const _gl=Array.isArray(meterReadings)?meterReadings:[];
  _gammaHasHeadroomAnchor=_gl.some(function(rd){return rd&&(typeof meterReadingIsGreyscale!=='function'||meterReadingIsGreyscale(rd))&&Number(rd.ire)>100.5;});
 }catch(e){}
 const fracBase=((typeof meterChartSignalMode==='function'&&meterChartSignalMode()==='sdr')&&_gammaHasHeadroomAnchor)?109:100;
 return (ire>1)?(ire/fracBase):ire;
}

function effectiveGamma(Y,Yw,ire,prevY,prevIre){
 // SDR26 normalises the gamma reference against the 109% legal peak, not
 // 100 IRE. The worker stores target_Yn = (ire/109)^2.2 (gamma 2.2 encoded
 // against 109) so the measured-vs-target gamma reading must use the same
 // divisor to recover the gamma exponent. SDR26 / BT.1886 / sRGB all share
 // this 109-divisor convention; HDR (PQ) keeps 100 because the PQ EOTF
 // saturates at 100% by spec. The HDR path is gated by meterChartIsHdr /
 // meterChartIsPq callers of meterGreyscaleGammaValue -- effectiveGamma is
 // shared so the divisor is selected here.
 // The 109 headroom divisor is correct ONLY for a series that actually has a
 // >100% headroom anchor (the SDR26 26-point autocal). The standard 21-point
 // post-cal/verification greyscale is anchored at 100, so dividing its IRE by
 // 109 (while Yw is the measured 100% reading) makes the per-point gamma
 // collapse toward 0 as IRE rises. Use 109 only when a >100 IRE greyscale
 // reading is actually present in the data being charted.
 const frac=meterGammaSignalFraction(ire);
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

// Pure power / sRGB targets with a raised black: scale from 0..peak then hard-
// floor at Lb. That produces the classic clip kink on EOTF/luminance charts
// (shadow codes whose power-law target sits below Lb map to the black shelf).
// BT.1886 does NOT use this — it bends smoothly into Lb via a*(v+b)^g.
function meterPowerTargetLuminance(signal,peak,gamma,Lb){
 const p=(peak>0)?peak:0;
 const y=gammaEotf(Math.max(0,Math.min(1,Number(signal)||0)),gamma)*p;
 const floor=Math.max(0,Number(Lb)||0);
 return floor>0?Math.max(y,floor):y;
}
function meterSrgbTargetLuminance(signal,peak,Lb){
 const p=(peak>0)?peak:0;
 const y=srgbEotf(Math.max(0,Math.min(1,Number(signal)||0)))*p;
 const floor=Math.max(0,Number(Lb)||0);
 return floor>0?Math.max(y,floor):y;
}

// Black level for bending the MEASURED trace along the target's shape between
// samples. Power 2.2/2.4 and sRGB hard-floor the target at Lb, and that shelf
// is a target-side clamp, not a transfer curve any display follows. Shaping
// across it pins the interpolation weight at 0 until the clip point and then
// races it to 1 -- with Lw=172/Lb=0.5 the clip lands at 7.04% IRE, so the
// 5%->10% span drew a flat run then a step between two perfectly smooth reads.
// Shape on the unclipped power law instead. BT.1886 bends smoothly into Lb and
// keeps the real black; the drawn target curve is built elsewhere and still
// shows the clip.
function meterTargetShapeBlackLevel(Lb){
 const black=Math.max(0,Number(Lb)||0);
 if(!(black>0)) return 0;
 try{
  const tgt=String(((typeof meterGreyChartTargetGammaSelection==='function')
   ?meterGreyChartTargetGammaSelection()
   :((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():''))||'').toLowerCase();
  if(tgt==='srgb') return 0;
  const g=parseFloat(tgt);
  if(g>0&&isFinite(g)) return 0;
 }catch(e){}
 return black;
}

function targetEotf(v,Lw,Lb){
 // DV Absolute uses PQ/ST2084. DV Relative uses the normal power-gamma path
 // below so chart targets follow the standard 2.2 tunnel curve.
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const peak=(Lw>0)?Lw:meterChartHdrPeak();
  const ire=Math.max(0,Math.min(1,Number(v)||0))*100;
  return meterDvAbsoluteChartTargetLuminance(ire,peak);
 }
 // Normal HDR10 analysis is PQ. During LG HDR calibration mode, reference-style
 // 1D LUT greyscale adjustment uses a power-gamma workspace; keep that local
 // to the live AutoCal charts so post-cal series reads remain PQ.
 const usesPqTarget=(typeof meterGreyChartUsesPqTarget==='function')?meterGreyChartUsesPqTarget():meterChartIsHdr();
 if(usesPqTarget||meterChartIsHlg()) return meterChartTargetLuminance(v,Lw,Lb);
 const tgt=(typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||''));
 if(tgt==='bt1886') return bt1886Eotf(v,Lw,Lb);
 if(tgt==='st2084') return meterChartPqDecodeNormalized(v);
 if(tgt==='srgb') return meterSrgbTargetLuminance(v,Lw,Lb);
 const gamma=parseFloat(tgt);
 return meterPowerTargetLuminance(v,Lw,(gamma>0&&isFinite(gamma))?gamma:2.2,Lb);
}

function meterGreyStimulusFraction(ire){
 const allowsHeadroom=(typeof meterGreyAllowsHeadroomTargets==='function') && meterGreyAllowsHeadroomTargets();
 const pct=Math.max(0,Math.min(allowsHeadroom?110:100,ire||0));
 const dvMode=meterChartIsDv();
 if(dvMode || meterDvRelativeSt2084UsesLegalRange()) return meterGreySignalFractionFromCode(meterCodeFromSignalPercent(pct));
 const isLimited=meterPatchUsesVideoRange();
 const code=isLimited?Math.round(16+pct/100*(235-16)):Math.round(pct*255/100);
 return meterSignalFractionFromCode(code);
}

function meterGreyCodeLooksHeadroom(code){
 const c=Number(code);
 return Number.isFinite(c)&&c>255;
}

function meterGreyTargetSignal(ire,code){
 const headroomIre=Number(ire)>100;
 const nominal=Math.max(0,Math.min((meterGreyAllowsHeadroomTargets()||headroomIre)?1.1:1,(ire||0)/100));
 if(meterChartIsDv()) return nominal;
 // Custom greyscale: the target must follow the nominal IRE only. Ignore the
 // passed code so a custom 10-bit code (which can look headroom >255, or trip
 // the HDR/PQ code-decode branch) does not re-bend the target signal.
 if((typeof meterGreyscaleCustomTargetActive==='function')&&meterGreyscaleCustomTargetActive()){
  if(meterChartIsPq()) return meterGreyStimulusFraction(ire);
  return nominal;
 }
 const headroomCode=meterGreyCodeLooksHeadroom(code);
 if(code!=null&&(meterChartIsHdr()||meterGreyAllowsHeadroomTargets()||headroomCode)) return meterGreySignalFractionFromCode(code);
 if(meterChartIsPq()) return meterGreyStimulusFraction(ire);
 return nominal;
}

function meterGreyInputFraction(ire,code){
 const nominal=Math.max(0,Math.min(1,(ire||0)/100));
 if(meterChartIsDv()&&meterDvMapModeValue()==='2') return nominal;
 if(code!=null && meterChartIsHdr()) return meterGreySignalFractionFromCode(code);
 return nominal;
}

const METER_HDR_DIFFUSE_WHITE_DEFAULT=92.2457;

function meterDisplayTypeIsProjector(value){
 const current=String(value||((document.getElementById('meterDisplayType')||{}).value)||'').toLowerCase();
 if(current==='projector'||current.startsWith('projector_')) return true;
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
 const wrap=document.getElementById('meterHdrDiffuseConfig');
 if(!wrap) return;
 const sel=String(((document.getElementById('meterTargetGamma')||{}).value)||'').toLowerCase();
 wrap.style.display=(meterChartIsPq()||sel==='st2084')?'':'none';
 meterSyncHdrDiffuseWhiteControl();
}

function meterSyncHdrDiffuseWhiteControl(){
 const input=document.getElementById('meterHdrDiffuseWhite');
 const automatic=document.getElementById('meterHdrDiffuseWhiteAuto');
 if(!input||!automatic) return;
 if(automatic.checked) input.value=meterHdrNativeDiffuseWhite().toFixed(4);
 else if(!(Number(input.value)>0)) input.value=meterHdrNativeDiffuseWhite().toFixed(4);
 input.disabled=!!automatic.checked;
 input.classList.toggle('meter-input-disabled',!!automatic.checked);
}

function meterHdrDiffuseWhiteSignalFraction(){
 // Diffuse-white Auto describes the patch that will actually be emitted, so
 // derive its midpoint at the active transport precision. Do not route this
 // through the active greyscale-series range: that range can represent a
 // cached SDR headroom or AutoCal ladder and previously produced stale or
 // nonsensical HDR diffuse-white values.
 const bits=(typeof meterPatchBitDepth==='function')?meterPatchBitDepth():10;
 const limited=(typeof meterPatchUsesVideoRange==='function')?meterPatchUsesVideoRange():true;
 let minCode=0;
 let maxCode=bits===8?255:1023;
 if(bits===12){
  minCode=256;
  maxCode=3760;
 }else if(limited){
  minCode=bits===8?16:64;
  maxCode=bits===8?235:940;
 }
 const span=maxCode-minCode;
 if(!(span>0)) return 0.5;
 const midpointCode=Math.round(minCode+(span*0.5));
 const signal=(midpointCode-minCode)/span;
 return (Number.isFinite(signal)&&signal>0&&signal<1)?signal:0.5;
}

function meterHdrNativeDiffuseWhite(){
 if(!(typeof meterChartPqDecodeNormalized==='function')) return METER_HDR_DIFFUSE_WHITE_DEFAULT;
 let signal=0.5;
 try{ signal=meterHdrDiffuseWhiteSignalFraction(); }catch(e){}
 const nits=meterChartPqDecodeNormalized(signal);
 // A 50% PQ code at supported transport depths is around 92 to 94 cd/m².
 // Reject any value outside a deliberately wider safety envelope so a stale
 // or malformed output state can never populate the Auto field with garbage.
 return (Number.isFinite(nits)&&nits>=70&&nits<=130)?nits:METER_HDR_DIFFUSE_WHITE_DEFAULT;
}

function meterHdrDiffuseWhiteResolved(){
 const automatic=document.getElementById('meterHdrDiffuseWhiteAuto');
 if(!automatic||automatic.checked) return meterHdrNativeDiffuseWhite();
 const el=document.getElementById('meterHdrDiffuseWhite');
 const value=Number(el&&el.value);
 if(!(Number.isFinite(value)&&value>0)) return meterHdrNativeDiffuseWhite();
 return Math.max(1,Math.min(200,value));
}

function meterHdrDiffuseWhiteOverride(){
 const automatic=document.getElementById('meterHdrDiffuseWhiteAuto');
 if(!automatic||automatic.checked) return null;
 return meterHdrDiffuseWhiteResolved();
}

function meterHdrDiffuseScale(){
 const diffuse=meterHdrDiffuseWhiteOverride();
 if(!(diffuse>0)) return 1;
 if(!(meterChartIsPq&&meterChartIsPq())) return 1;
 const native=meterHdrNativeDiffuseWhite();
 return native>0?diffuse/native:1;
}

function meterApplyHdrDiffuseOverridePeak(peak){
 const p=Number(peak);
 if(!(p>0)) return peak;
 // Diffuse white scales the authored PQ target curve, not the display or
 // mastering peak. Keep this legacy call site neutral; target decoding is
 // scaled in meterChartHdrCodeLuminance/meterDecodeColorTargetChannel.
 return p;
}

function meterOnHdrDiffuseWhiteChange(){
 try{ meterSaveColorPrefs(); }catch(e){}
 // Diffuse white changes the authored PQ targets themselves. Use the full
 // target refresh so EOTF, luminance, gamma and colour-series targets all
 // rebuild instead of the lightweight grey-reference refresh, which only
 // redraws RGB balance and Delta E.
 meterScheduleTargetCurveRefresh();
}

function meterOnHdrDiffuseWhiteAutoChange(){
 meterSyncHdrDiffuseWhiteControl();
 meterOnHdrDiffuseWhiteChange();
}

function meterGreyTargetLuminance(ire,Lw,Lb,code){
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const peak=(Lw>0)?Lw:100;
  return meterDvAbsoluteChartTargetLuminance(ire,peak,code);
 }
 if(meterChartIsDv() && meterDvMapModeValue()==='2'){
  const peak=(Lw>0)?Lw:100;
  return meterDvRelativeChartTargetLuminance(ire,peak,code);
 }
 const peak=(Lw>0)?Lw:(meterChartIsHdr()?meterChartHdrPeak():1);
 const signal=meterGreyTargetSignal(ire,code);
 const usesPqTarget=(typeof meterGreyChartUsesPqTarget==='function')?meterGreyChartUsesPqTarget():meterChartIsHdr();
 if(usesPqTarget||meterChartIsHlg()) return meterChartTargetLuminance(signal,peak,Lb||0);
 const tgt=(typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||''));
 // BT.1886: black-aware smooth bend into Lb (a*(v+b)^g).
 // Power 2.2/2.4 and sRGB: black-oblivious curve hard-floored at Lb so a
 // raised black (manual or measured) draws the clip kink on EOTF/luminance.
 if(tgt==='bt1886') return bt1886Eotf(signal,peak,Lb||0);
 if(tgt==='srgb') return meterSrgbTargetLuminance(signal,peak,Lb||0);
 const gamma=parseFloat(tgt);
 return meterPowerTargetLuminance(signal,peak,(gamma>0&&isFinite(gamma))?gamma:2.2,Lb||0);
}

function meterReadingsUseLgHeadroomReference(readings){
 if(meterGreyAllowsHeadroomTargets()) return true;
 const list=Array.isArray(readings)?readings:[];
 return list.some(rd=>{
  if(!rd || !meterReadingIsGreyscale(rd) || !meterReadingHasLuminance(rd)) return false;
  const ire=Number(meterReadingPlotIre(rd));
  const code=Number(rd.r_code!=null?rd.r_code:rd.r);
  return Number.isFinite(ire)&&ire>=108.5&&Number.isFinite(code)&&code>255;
 });
}

function meterReadingsHaveLgAutoCal26SeriesMarker(readings){
 const list=Array.isArray(readings)?readings:[];
 return list.some(rd=>{
  if(!rd) return false;
  if(String(rd.series_mode||'')==='lg-autocal-26') return true;
  if(rd.autocal_legal_white_anchor||rd.autocal_white_reference||rd.autocal_slot_locked||rd.ddc_slot_locked) return true;
  const ire=Number(meterReadingPlotIre(rd));
  const code=Number(rd.r_code!=null?rd.r_code:rd.r);
  return Number.isFinite(ire)&&ire>=105&&Number.isFinite(code)&&code>255;
 });
}

function meterLgAutoCal26SeriesReadUsesInitialWhite(readings){
 if(meterActiveSeriesType!=='greyscale'||!meterUseLgAutoCal26(meterActiveSeriesPoints)) return false;
 if(meterAutoCalGreyscaleTargetWhiteReferenceActive(readings)) return false;
 return meterReadingsHaveLgAutoCal26SeriesMarker(readings);
}

function meterGreyHeadroomReferenceReading(readings){
 if(!meterReadingsUseLgHeadroomReference(readings)) return null;
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

function meterLgHeadroomDerivedWhiteReferenceNits(readings){
 const list=Array.isArray(readings)?readings:[];
 if(meterLgAutoCal26SeriesReadUsesInitialWhite(list)) return null;
 if(!meterReadingsUseLgHeadroomReference(list)) return null;
 const headroom=meterGreyHeadroomReferenceReading(list);
 if(!headroom) return null;
 const fallback=meterExplicitLgTargetWhiteReferenceNits(list)||meterStoredLgTargetWhiteReferenceNits()||meterColorReferenceNits();
 const peak=meterGreySolvePeakFromHeadroomReading(headroom,list,fallback,meterChartBlackLevel(list));
 return (peak>0&&isFinite(peak))?peak:null;
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
 if(!reading) return fallbackPeak;
 const y=meterReadingLuminanceNits(reading);
 if(!(y>0)) return fallbackPeak;
 const raw=(reading.plot_ire!=null)?reading.plot_ire:(reading.ire!=null?reading.ire:reading.stimulus);
 const ire=Number(raw);
 if(!Number.isFinite(ire) || ire < 108.5) return fallbackPeak;
 const code=(reading.r_code!=null)?reading.r_code:(reading.r!=null?reading.r:meterGreyStepCodeForIre(steps,ire));
 const headroomContext=meterGreyAllowsHeadroomTargets()||meterReadingsUseLgHeadroomReference(steps)||(meterGreyCodeLooksHeadroom(code)&&ire>=108.5);
 if(!headroomContext) return fallbackPeak;
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
 const _tw=(typeof meterTargetWhiteLevel==='function')?meterTargetWhiteLevel():null;
 if(_tw&&!_tw.useMeasured&&_tw.value!=null&&Number(_tw.value)>0) return fallbackPeak;
 const list=Array.isArray(readings)?readings:[];
 const referenceList=meterGreyscaleReferenceReadings(list);
 const activeAutoCalReference=meterAutoCalGreyscaleTargetWhiteReferenceActive(list);
 const allowHeadroomPeak=meterReadingsUseLgHeadroomReference(list)&&!meterLgAutoCal26SeriesReadUsesInitialWhite(list);
 const hasMeasuredWhite=referenceList.some(rd=>{
  if(!rd || rd.synthetic_target) return false;
  const y=Number(((rd.luminance!=null && rd.luminance>0)?rd.luminance:rd.Y));
  if(!(y>0)) return false;
  const raw=(rd.ire!=null)?rd.ire:(rd.plot_ire!=null?rd.plot_ire:rd.stimulus);
  const name=String(rd.name||'').toLowerCase();
  return Math.abs((Number(raw)||0)-100)<0.05 || name==='white' || !!rd.autocal_white_reference;
 });
 if(hasMeasuredWhite&&!activeAutoCalReference) return fallbackPeak;
 if(allowHeadroomPeak){
  const peak=meterGreySolvePeakFromHeadroomReading(meterGreyHeadroomReferenceReading(list),steps,fallbackPeak,Lb);
  if(peak>0&&isFinite(peak)) return peak;
 }
 if(!allowHeadroomPeak) return fallbackPeak;
 const peak=meterGreySolvePeakFromHeadroomReading(meterGreyHeadroomReferenceReading(readings),steps,fallbackPeak,Lb);
 return (peak>0&&isFinite(peak))?peak:fallbackPeak;
}

function meterGreyTargetChartValue(ire,Lw,Lb,code){
 return meterGreyTargetLuminance(ire,Lw,Lb,code);
}

function meterGreyTargetWhiteValue(Lw,Lb){
 return meterGreyTargetChartValue(100,Lw,Lb,meterPatchRangeMin()+meterPatchRangeSpan());
}

const METER_SDR_EOTF_REFERENCE_NITS=200;
function meterEotfSdrChartActive(){
 return !(typeof meterChartIsHdr==='function'&&meterChartIsHdr());
}
function meterEotfChartNormRef(peak){
 // For the SDR EOTF chart, normalize against a fixed reference white so the Y
 // axis reads in absolute terms (1.0 == 200 cd/m2). The target curve keeps the
 // real target peak for its luminance, so it still tracks the measured white.
 return meterEotfSdrChartActive() ? METER_SDR_EOTF_REFERENCE_NITS : peak;
}

function meterGreyTargetEotfValue(ire,Lw,Lb,code){
 const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,code);
 return meterGreyEotfValueFromLuminance(tgtLum,meterEotfChartNormRef(Lw),Lb);
}

function meterGreyTargetNormalizedEotfValue(ire,Lw,Lb,code){
 const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,code);
 return meterGreyNormalizedEotfValueFromLuminance(tgtLum,meterEotfChartNormRef(Lw),Lb);
}

function meterGreyTargetLuminanceForChartPoint(signal,Lw,Lb,point){
		const row=point||{};
		// SDR26 1D-DPG autocal series rows (both the discrete step rows AND the
		// dense-curve interpolated mid points): derive the chart target from
		// the step's stimulus through targetEotf using the active Target Gamma
		// dropdown, instead of going through meterGreyTargetSignal which would
		// re-derive signal from the step's 10-bit code against the chart's
		// current bit-depth range (an 8-bit transport reading a 10-bit
		// extended SDR26 code table produces signal values that saturate to
		// 1.1 around IRE 27, drawing a flat-to-peak plateau from 25% to 109%
		// that looks like a PQ rolloff). The active dropdown drives the gamma
		// via targetEotf; chart signal normalizes to the calibrated peak IRE
		// (=109) for headroom anchors so 105 lands BELOW peak.
		const activeSeriesIsSdr26=(typeof meterActiveSeriesType!=='undefined')&&meterActiveSeriesType==='greyscale'
		 &&Number(meterActiveSeriesPoints)===26
		 &&String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase()==='sdr'
		 &&(typeof meterUseLgAutoCal26==='function')&&meterUseLgAutoCal26(meterActiveSeriesPoints);
		if(activeSeriesIsSdr26 && row && row.stimulus!=null){
		 const stimulus=Number(row.stimulus);
		 if(Number.isFinite(stimulus)){
		  // SDR26 headroom is a single continuous curve from 0 to 109 (the
		  // calibrated peak). 100 IRE sits at 100/109 of the peak and 105 at
		  // 105/109; normalize the WHOLE chart signal to the calibrated peak
		  // IRE so the curve is monotonic across the 100->105 boundary
		  // (otherwise the split at stimulus=100 makes chartSig jump from
		  // 1.0 down to 100/109=0.917, producing a visible kink).
		  // Full -> peak 100; Limited super-white ladder -> peak 109.
		  const peakIre=(typeof meterSdr26ChartPeakIre==='function')?meterSdr26ChartPeakIre():109;
		  let chartSig=stimulus/peakIre;
		  // RGB-Limited AND Full range (peak 100): reference the target to the
		  // EMITTED code fraction — the wire codes quantize the nominal IRE
		  // by up to ~2% relative at 10%, and the panel is calibrated onto
		  // the curve at the emitted signal. RGB Limited uses Limited LEGAL
		  // codes (10-bit 64..940, 8-bit 16..235) with input_max=1023/255,
		  // so rc/im would misreference targets by ~9% on 10-bit and ~9%
		  // on 8-bit -- the Limited formula (rc-lo)/span is required. Full
		  // range uses the rc/im formula (codes are 0..1023 / 0..255 with
		  // no headroom offset). YCbCr Limited keeps the nominal /109
		  // ladder reference. Neutral rows only (r==g==b) with a usable
		  // input_max; synthesized mid-curve rows without codes fall back
		  // to the nominal stimulus.
		  if(peakIre<=100.01){
		   const rc=Number(row.r_code), gc=Number(row.g_code), bc=Number(row.b_code);
		   const im=Number(row.input_max);
		   if(Number.isFinite(rc)&&rc===gc&&gc===bc&&Number.isFinite(im)&&im>0){
		    if(typeof meterPatchUsesVideoRange==='function'&&meterPatchUsesVideoRange()){
		     const lo=(im>255)?64:16, span=(im>255)?876:219;
		     chartSig=Math.max(0,Math.min(1,(rc-lo)/span));
		    } else {
		     chartSig=rc/im;
		    }
		   }
		  }
		  return targetEotf(Math.max(0,Math.min(1,chartSig)),Lw,Lb||0);
		 }
		}
		const metadataY=(row&&row.target_Yn!=null&&typeof meterGreyscaleTargetYFromYn==='function')?meterGreyscaleTargetYFromYn(row.target_Yn,Lw,Lb||0):null;
		if(Number.isFinite(metadataY)&&metadataY>=0) return metadataY;
		// Custom greyscale: row.stimulus / row.code are the CUSTOM patch values,
		// which must NOT move the target. The caller (curve builder / per-reading
		// target) already reduced the position to the nominal slot and passed it
		// as `signal`; use that and ignore the row so the target line is smooth.
		if((typeof meterGreyscaleCustomTargetActive==='function')&&meterGreyscaleCustomTargetActive()){
		 const frac=Number(signal);
		 return meterGreyTargetLuminance(Number.isFinite(frac)?frac*100:0,Lw,Lb||0,null);
		}
		if(row&&('stimulus' in row || 'code' in row)){
		 const stimulus=Number(row.stimulus);
		 const ire=Number.isFinite(stimulus) ? stimulus : (Number.isFinite(Number(signal)) ? Number(signal)*100 : 0);
		 const code=(row.code!=null)?row.code:null;
	 return meterGreyTargetLuminance(ire,Lw,Lb||0,code);
	}
	const frac=Number(signal);
	return meterGreyTargetLuminance(Number.isFinite(frac)?frac*100:0,Lw,Lb||0,null);
}

function meterGreyTargetEotfChartValueForSignal(signal,Lw,Lb,point){
 const lum=meterGreyTargetLuminanceForChartPoint(signal,Lw,Lb||0,point);
 return meterEotfNormalizedEnabled()
  ? meterGreyNormalizedEotfValueFromLuminance(lum,meterEotfChartNormRef(Lw),Lb)
  : meterGreyEotfValueFromLuminance(lum,meterEotfChartNormRef(Lw),Lb);
}

function meterEotfNormalizedEnabled(){
 // Absolute/inverse-EOTF is the default view. The bowed normalized EOTF view
 // is active whenever Absolute is NOT checked.
 const el=document.getElementById('meterEotfAbsolute');
 return !el || !el.checked;
}

function meterEotfLogScaleEnabled(){
 const el=document.getElementById('meterEotfLogScale');
 return !!(el&&el.checked);
}

function meterLuminanceLogScaleEnabled(){
 const el=document.getElementById('meterLuminanceLogScale');
 return !!(el&&el.checked);
}

const METER_CHART_LOG_KNEE_DIVISOR=50000;
const METER_LUMINANCE_LOG_FLOOR_DIVISOR=1000000;
// EOTF log scale uses a much larger knee (smaller divisor) so the curve starts
// gradually and the first gridline above 0 isn't crushed against the axis.
const METER_EOTF_LOG_KNEE_DIVISOR=16;

function meterEotfLuminanceLogScaleEnabledForMode(mode){
 if(mode==='eotf') return meterEotfLogScaleEnabled();
 if(mode==='luminance') return meterLuminanceLogScaleEnabled();
 return false;
}

function meterLogScaleValue(v,yTop,floorValue,kneeDivisor){
 const top=Math.max(1e-6,yTop||1);
 const floor=Math.max(0,Math.min(top*0.999,Number(floorValue)||0));
 const val=Math.max(floor,Math.min(top,v||0));
 const knee=Math.max(top/(kneeDivisor||METER_CHART_LOG_KNEE_DIVISOR),1e-9);
 const lo=floor>0?Math.log1p(floor/knee):0;
 const hi=Math.log1p(top/knee);
 return (Math.log1p(val/knee)-lo)/Math.max(1e-9,hi-lo);
}

function meterLogUnscaleValue(norm,yTop,floorValue,kneeDivisor){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 const floor=Math.max(0,Math.min(top*0.999,Number(floorValue)||0));
 const knee=Math.max(top/(kneeDivisor||METER_CHART_LOG_KNEE_DIVISOR),1e-9);
 const lo=floor>0?Math.log1p(floor/knee):0;
 const hi=Math.log1p(top/knee);
 return knee*(Math.exp(lo+n*Math.max(1e-9,hi-lo))-1);
}

function meterEotfScaleValue(v,yTop){
 const top=Math.max(1e-6,yTop||1);
 const val=Math.max(0,Math.min(top,v||0));
 if(meterEotfLogScaleEnabled()) return meterLogScaleValue(val,top,0,METER_EOTF_LOG_KNEE_DIVISOR);
 return val/top;
}

function meterEotfUnscaleValue(norm,yTop){
 const top=Math.max(1e-6,yTop||1);
 const n=Math.max(0,Math.min(1,norm||0));
 if(meterEotfLogScaleEnabled()) return meterLogUnscaleValue(n,top,0,METER_EOTF_LOG_KNEE_DIVISOR);
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

function meterLuminanceLogFloor(yTop){
 const top=Math.max(1e-6,yTop||1);
 return Math.max(1e-6,top/METER_LUMINANCE_LOG_FLOOR_DIVISOR);
}

function meterEotfLuminanceLogPointAllowed(mode,value,plot,signal){
 if(!meterEotfLuminanceLogScaleEnabledForMode(mode)) return true;
 const val=Number(value);
 if(!(Number.isFinite(val)&&val>=0)) return false;
 const explicitNumber=value=>{
  if(value==null) return null;
  if(typeof value==='string'&&value.trim()==='') return null;
  const n=Number(value);
  return Number.isFinite(n)?n:null;
 };
 const plotValue=explicitNumber(plot);
 if(plotValue!=null&&plotValue<0) return false;
 const signalValue=explicitNumber(signal);
 if(signalValue!=null&&signalValue<0) return false;
 return true;
}

function meterScaleEotfLuminancePlotValue(mode,value,yTop,plot,signal){
 const val=Number(value);
 if(!Number.isFinite(val)) return null;
 if(!meterEotfLuminanceLogPointAllowed(mode,val,plot,signal)) return null;
 return mode==='eotf' ? meterEotfScaleValue(val,yTop) : meterLuminanceScaleValue(val,yTop);
}

function meterLuminanceAxisLabel(v){
 const value=Number(v)||0;
 if(value>=100) return value.toFixed(0);
 if(value>=10) return value.toFixed(1);
 if(value>=1) return value.toFixed(2);
 if(value>0) return value.toFixed(3);
 return '0';
}

// blackLevel must be the SAME Lb the target curve was built with. In the
// Absolute (inverse-EOTF) view the target inverts to the diagonal by
// construction, so the measured curve is the only thing carrying the error --
// inverting it against a different Lb silently cancels that error out.
function meterGreyMeasuredEotfValue(luminance,refWhite,blackLevel){
 const y=Math.max(0,luminance||0);
 return meterGreyEotfValueFromLuminance(y,refWhite,blackLevel);
}

function meterGreyNormalizedLuminanceValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 const peak=(refWhite>0)?refWhite:100;
 return peak>0 ? y/peak : 0;
}

function meterGreyInverseEotfSignalFromLuminance(luminance,refWhite,blackLevel){
 const y=Math.max(0,luminance||0);
 const peak=(refWhite>0)?refWhite:100;
 if(!(peak>0)) return 0;
 const ratio=Math.max(0,y/peak);
 const tgt=((typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||'')))||'2.2';
 if(tgt==='bt1886'){
  const Lw=peak;
  const Lb=Math.max(0,Number(blackLevel)||0);
  const g=2.4;
  const lwRoot=Math.pow(Lw,1/g);
  const lbRoot=Math.pow(Lb,1/g);
  const denom=lwRoot-lbRoot;
  if(denom>0){
   const a=Math.pow(denom,g);
   const b=lbRoot/denom;
   return Math.max(0,Math.min(1.1,Math.pow(y/Math.max(a,1e-12),1/g)-b));
  }
  return Math.pow(ratio,1/g);
 }
 if(tgt==='srgb'){
  return ratio<=0.0031308 ? ratio*12.92 : 1.055*Math.pow(ratio,1/2.4)-0.055;
 }
 if(tgt==='st2084') return meterChartPqEncodeNormalized(y);
 const gamma=parseFloat(tgt);
 return Math.pow(ratio,1/(gamma>0?gamma:2.2));
}

function meterGreyEotfValueFromLuminance(luminance,refWhite,blackLevel){
	 const y=Math.max(0,luminance||0);
	 if(meterGreyEotfUsesPqCurve()) return meterChartPqEncodeNormalized(y);
	 if(meterChartIsHlg()) return hlgInverseEotfSignal(y,blackLevel,refWhite);
	 return meterGreyInverseEotfSignalFromLuminance(y,refWhite,blackLevel);
}

function meterGreyNormalizedEotfValueFromLuminance(luminance,refWhite,blackLevel){
	 const y=Math.max(0,luminance||0);
	 return meterGreyNormalizedLuminanceValue(y,refWhite);
}

function meterGreyMeasuredNormalizedEotfValue(luminance,refWhite){
 const y=Math.max(0,luminance||0);
 return meterGreyNormalizedEotfValueFromLuminance(y,refWhite);
}

// blackLevel defaults to 0 so callers that have no series black (the preset
// pre-read charts) keep drawing exactly as before. The normalized view is a
// plain y/ref ratio and needs no Lb.
function meterGreyMeasuredEotfChartValue(luminance,refWhite,blackLevel){
 const y=Math.max(0,luminance||0);
 const ref=meterEotfChartNormRef(refWhite);
 if(meterEotfNormalizedEnabled()) return meterGreyMeasuredNormalizedEotfValue(y,ref);
 // Absolute (inverse-EOTF) view. The BT.1886 inverse genuinely has no solution
 // below the target black: L(0)=Lb for every signal, so a reading under Lb is
 // off the curve family and there is no signal value that maps to it.
 // meterGreyInverseEotfSignalFromLuminance clamps those to 0, which painted a
 // false flat run along the X axis reading as "tracking zero" rather than
 // "unmeasurable against this target". Return null so the line and its dots
 // simply stop.
 //
 // This applies to THIS chart only, because inverting the target curve is what
 // it plots. The gamma chart does not share the limitation: its measured value
 // is the plain log-ratio exponent ln(Y/Yw)/ln(V), which is defined for any
 // Y>0, so a panel with blacker-than-target black still plots there.
 const Lb=Math.max(0,Number(blackLevel)||0);
 if(Lb>0.001 && y<Lb && meterBt1886BlackAwareMetricsActive()) return null;
 return meterGreyMeasuredEotfValue(y,ref,blackLevel);
}

function meterNiceAxisTop(dataMax,base,maxTicks){
 // Round an axis top up to a clean multiple of `base` (e.g. 0.2 or 50) while
 // keeping the tick count <= maxTicks, bumping the step to the next multiple
 // of base when needed. Returns the rounded top and number of even divisions.
 const m=Math.max(base,Number(dataMax)||0);
 let step=base;
 const mt=Math.max(1,maxTicks||10);
 while(Math.ceil(m/step-1e-9)>mt) step+=base;
 const top=Math.ceil(m/step-1e-9)*step;
 return {top:top,steps:Math.max(1,Math.round(top/step))};
}

// Keep the initial EOTF/luminance axis on clean engineering divisions, but
// do not snap every user-zoomed ceiling back to the same large increment.
// That snapping made several wheel ticks visually do nothing (especially the
// luminance chart's 50 cd/m2 base), so these charts felt much slower than the
// other Y-axis zoom controls.
function meterNiceAxisTopForZoom(id,dataMax,base,maxTicks){
 if(!meterChartYZoomIsActive(id)) return meterNiceAxisTop(dataMax,base,maxTicks);
 const top=Math.max(Number(base)||1,Number(dataMax)||0);
 return {top:top,steps:Math.max(1,Number(maxTicks)||10)};
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
 if(meterEotfNormalizedEnabled()) lbl.textContent=scaled?'EOTF (diffuse)':'EOTF';
 else lbl.textContent=scaled?'EOTF Absolute Error (diffuse)':'EOTF Absolute Error';
}

function meterGreyTargetGamma(ire,Lw,Lb,code,prevIre,prevCode){
 const peak=(Lw>0)?Lw:100;
 if(!(peak>0) || !(ire>0)) return null;
 const tgt=((typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():(((document.getElementById('meterTargetGamma')||{}).value||'')||((typeof meterDvAutoTargetGamma==='function'&&meterChartIsDv())?meterDvAutoTargetGamma():''))))||'2.2';
 if(meterChartIsDv() && meterDvMapModeValue()==='1'){
  const analysisIre=meterDvTargetSignalFraction(ire,code)*100;
  const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
  const prevSignalIre=meterDvTargetSignalFraction(prevStepIre,prevCode)*100;
  const tgtLum=meterDvAbsoluteChartTargetLuminance(ire,peak,code);
  if(analysisIre>=99.999){
   const prevLum=meterDvAbsoluteChartTargetLuminance(prevStepIre,peak,prevCode);
   return effectiveGammaTopSlope(tgtLum,peak,analysisIre,prevLum,prevSignalIre);
  }
  return effectiveGamma(tgtLum,peak,analysisIre);
 }
 if(meterChartIsDv() && meterDvMapModeValue()==='2'){
  return 2.2;
 }
 const signal=meterGreyTargetSignal(ire,code);
 if(!(signal>0)) return null;
 const prevStepIre=(prevIre>0&&prevIre<100)?prevIre:95;
 const prevStepCode=(prevCode!=null)?prevCode:meterCodeFromSignalPercent(prevStepIre);
 // HDR/PQ: the "target gamma" is the effective exponent of the actual
 // displayed target curve at each grey step. In DV this follows the encoded
 // transport patch values that the series generator emits, which yields the
 // expected near-linear luminance-vs-step target in the chart view.
 const usesPqTarget=(typeof meterGreyChartUsesPqTarget==='function')?meterGreyChartUsesPqTarget():meterChartIsHdr();
 if(usesPqTarget||meterChartIsHlg()){
  const tgtLum=meterChartTargetLuminance(signal,peak,Lb||0);
  const analysisIre=signal*100;
  if(analysisIre>=99.999){
   const prevSignal=meterGreyTargetSignal(prevStepIre,prevStepCode);
   const prevLum=meterChartTargetLuminance(prevSignal,peak,Lb||0);
   return effectiveGammaTopSlope(tgtLum,peak,analysisIre,prevLum,prevSignal*100);
  }
  return effectiveGamma(tgtLum,peak,analysisIre);
 }
 let black=Lb||0;
 // With a raised Target Black the SDR target is NOT a pure power law. BT.1886
 // is L = a*(V+b)^g with b derived from Lb, so L(0)=Lb; power/sRGB clip onto
 // it. Plot the effective exponent of the luminance the EOTF/luminance charts
 // actually target, exactly as the PQ/HLG branch above does, so all three
 // charts and the Absolute-Y error agree rather than drawing a flat nominal
 // line the target does not follow. At Lw=100, Lb=0.1 the BT.1886 target is
 // 1.97 at 10% and 2.26 at 90%, not 2.4 -- that droop is the definition of the
 // curve, not an error, and its depth is set by the Lw/Lb contrast ratio.
 //
 // Both lines are therefore the same metric, the log-ratio exponent
 // ln(Y/Yw)/ln(V), which is what makes the vertical gap between them a
 // like-for-like gamma error and matches how established calibration software
 // draws BT.1886 against a raised black. A previous revision flattened this to
 // a constant 2.4 and instead solved the MEASURED line for the exponent that
 // put each reading back on the BT.1886 curve; that made an on-target display
 // read 2.4, but it put target and measured on two different metrics and hid
 // the shape of the target the operator had actually asked for.
 //
 // Lb=0 collapses BT.1886 to Lw*V^g and is mathematically identical to the
 // nominal exponent, so keep returning the constant there.
 if(black>0.001){
  const tgtLum=meterGreyTargetLuminance(ire,peak,black,code);
  if(!(tgtLum>0)) return null;
  const analysisIre=signal*100;
  if(analysisIre>=99.999){
   const prevSignal=meterGreyTargetSignal(prevStepIre,prevStepCode);
   const prevLum=meterGreyTargetLuminance(prevStepIre,peak,black,prevStepCode);
   return effectiveGammaTopSlope(tgtLum,peak,analysisIre,prevLum,prevSignal*100);
  }
  return effectiveGamma(tgtLum,peak,analysisIre);
 }
 if(tgt==='bt1886') return 2.4;
 if(tgt==='srgb') return 2.2;
 const gamma=parseFloat(tgt);
 return (gamma>0&&isFinite(gamma))?gamma:null;
}

function meterGreyTargetPeak(refWhite){
 // Operator Target White replaces the measured white reference and is the
 // authoritative top of the displayed target EOTF curve.
 const _tw=(typeof meterTargetWhiteLevel==='function')?meterTargetWhiteLevel():null;
 const manualTargetWhite=(_tw&&!_tw.useMeasured&&_tw.value!=null&&Number(_tw.value)>0)?Number(_tw.value):null;
 if(manualTargetWhite!=null) refWhite=manualTargetWhite;
 // DV absolute and DV relative both anchor the chart target to the measured
 // 100% white so the target curve tracks what the display actually produces
 // rather than the authored mastering-peak label.
 if(meterChartIsDv()) return meterApplyHdrDiffuseOverridePeak((refWhite>0)?refWhite:meterChartMasterPeak());
 // HDR10/PQ greyscale charts should keep the same target-curve shape but
 // use two distinct peaks: native PQ (BT.2390 off) targets the mastering
 // peak, while BT.2390 maps that authored curve toward the measured/manual
 // display peak. Previously both modes returned measured white here, so the
 // unchecked target still hard-clipped at the panel peak and looked rolled
 // off even though tone mapping was disabled.
 const usesPqTarget=(typeof meterGreyChartUsesPqTarget==='function')?meterGreyChartUsesPqTarget():meterChartIsPq();
 if(usesPqTarget){
  const displayPeak=meterApplyHdrDiffuseOverridePeak((refWhite>0)?refWhite:meterChartHdrPeak());
  // An explicit Target White must win over mastering Max Luma in native PQ
  // mode too. Max Luma remains the fallback when Target White follows the
  // measurement, and remains the BT.2390 source/mastering peak.
  if(manualTargetWhite!=null) return displayPeak;
  if(typeof meterChartBt2390Enabled==='function'&&!meterChartBt2390Enabled()){
   const master=(typeof meterChartMasterPeak==='function')?meterChartMasterPeak():meterChartHdrPeak();
   return (master>0)?master:displayPeak;
  }
  return displayPeak;
 }
 return (refWhite>0)?refWhite:100;
}

function meterTargetGammaLabel(){
 const sel=document.getElementById('meterTargetGamma');
 const autoPower=(typeof meterHdrAutoCalUsesPowerGammaChartMath==='function')&&meterHdrAutoCalUsesPowerGammaChartMath();
	 const usesPqTarget=(typeof meterGreyChartUsesPqTarget==='function')?meterGreyChartUsesPqTarget():meterChartIsPq();
	 if(autoPower) return 'Gamma 2.2';
	 if(meterChartIsHlg()) return 'HLG';
	 if(meterChartIsDv()){
	  const tgt=((typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():''))||'';
	  if(tgt==='2.2') return 'Gamma 2.2';
	  if(tgt==='2.4') return 'Gamma 2.4';
	  if(tgt==='bt1886') return 'BT.1886';
	  if(tgt==='srgb') return 'sRGB';
	  return 'ST 2084';
	 }
	 if(!sel) return usesPqTarget ? (meterChartBt2390Enabled()?'PQ + BT.2390':'PQ') : 'Gamma';
 const opt=sel.options[sel.selectedIndex];
 if(usesPqTarget) return meterChartBt2390Enabled()?'PQ + BT.2390':'PQ';
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
 (steps||[]).forEach(s=>{
  const slotIre=Number(meterGreyscaleTargetSlotIre(s));
  addPoint(Number.isFinite(slotIre)?slotIre:(s.ire||0),s.r_code!=null?s.r_code:s.r);
 });
 addPoint(100,meterPatchRangeMin()+meterPatchRangeSpan());
 pts.sort((a,b)=>a[0]-b[0]);
 return pts;
}

function meterGreyDenseTargetCurvePoints(targetPeak,Lb,yTop,mode,maxPct,steps){
 if(mode!=='luminance' && mode!=='eotf') return null;
 const stepList=Array.isArray(steps)?steps:[];
 const end=Math.max(1,Number(maxPct)||100);
 const top=Math.max(1e-6,yTop||1);
 const rows=[];
 stepList.forEach(s=>{
  if(!s) return;
  const stimulus=Number(meterGreyscaleTargetSlotIre(s));
  const plot=Number(meterGreyEotfLuminancePlotIre(s));
  if(!Number.isFinite(plot)) return;
  const code=meterGreyChartTargetCode(s);
  const signal=meterGreyTargetSignal(Number.isFinite(stimulus)?stimulus:plot,code);
  if(!Number.isFinite(signal)) return;
  rows.push({plot:Math.max(0,Math.min(end,plot)),stimulus:Number.isFinite(stimulus)?stimulus:plot,code,signal:Math.max(0,signal)});
 });
 if(rows.length<2) return null;
 if(!rows.some(row=>row.plot<=0.0001)){
  rows.push({plot:0,stimulus:0,code:meterPatchRangeMin(),signal:meterGreyTargetSignal(0,meterPatchRangeMin())});
 }
 rows.sort((a,b)=>a.plot-b.plot);
 const unique=[];
 rows.forEach(row=>{
  const last=unique[unique.length-1];
  if(last&&Math.abs(last.plot-row.plot)<0.0001){
   last.signal=row.signal;
   last.stimulus=row.stimulus;
   last.code=row.code;
  } else {
   unique.push(Object.assign({},row));
  }
 });
 if(unique.length<2) return null;
 const pointFor=(plot,signal,point)=>{
  const rawValue=mode==='eotf'
   ? meterGreyTargetEotfChartValueForSignal(signal,targetPeak,Lb||0,point)
   : meterGreyTargetLuminanceForChartPoint(signal,targetPeak,Lb||0,point);
  const scaled=meterScaleEotfLuminancePlotValue(mode,rawValue,top,plot,signal);
  return scaled==null?null:[Math.max(0,Math.min(end,plot))/end,scaled];
 };
 const pts=[];
 for(let i=0;i<unique.length-1;i++){
  const a=unique[i];
  const b=unique[i+1];
  const span=Math.max(0,b.plot-a.plot);
  // Roughly 100 points over a 0-100 chart is visually smooth while avoiding
  // hundreds of redundant target-mode evaluations on every redraw.
  const segments=Math.max(1,Math.ceil(span));
  for(let j=0;j<=segments;j++){
   if(i>0&&j===0) continue;
   const t=segments>0?j/segments:0;
   const mid={stimulus:a.stimulus+(b.stimulus-a.stimulus)*t};
   if(Number.isFinite(Number(a.code))&&Number.isFinite(Number(b.code))) mid.code=Number(a.code)+(Number(b.code)-Number(a.code))*t;
   const pt=pointFor(a.plot+(b.plot-a.plot)*t,a.signal+(b.signal-a.signal)*t,mid);
   if(pt) pts.push(pt);
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
  .filter(s=>s&&Number.isFinite(Number(meterGreyscaleTargetSlotIre(s))))
  .map((s,idx)=>{
   const code=meterGreyChartTargetCode(s);
   const ire=Number(meterGreyscaleTargetSlotIre(s));
   const x=meterGreyEotfLuminanceChartX(s,stepList,idx,end);
   const signal=meterGreyTargetSignal(ire,code);
	   const rawValue=(mode==='eotf')
	    ? meterGreyTargetEotfChartValueForSignal(signal,targetPeak,Lb,s)
	    : meterGreyTargetLuminanceForChartPoint(signal,targetPeak,Lb,s);
   const value=meterScaleEotfLuminancePlotValue(mode,rawValue,top,x*end,signal);
   return value==null?null:[x,value];
  })
  .filter(p=>p&&isFinite(p[0])&&isFinite(p[1]));
 if(coded.length>1){
  const dense=meterGreyDenseTargetCurvePoints(targetPeak,Lb,yTop,mode,maxPct,stepList);
  if(dense&&dense.length>1) return dense;
  const hasBlack=coded.some(p=>p[0]<=0.0001);
  if(!hasBlack){
   const code=meterPatchRangeMin();
   const signal=meterGreyTargetSignal(0,code);
   const rawValue=(mode==='eotf')
    ? meterGreyTargetEotfChartValue(0,targetPeak,Lb,code)
    : meterGreyTargetChartValue(0,targetPeak,Lb,code);
   const value=meterScaleEotfLuminancePlotValue(mode,rawValue,top,0,signal);
   if(value!=null) coded.unshift([0,value]);
  }
  coded.sort((a,b)=>a[0]-b[0]);
  return coded;
 }
 for(let pct=0;pct<=end;pct+=1){
  const signal=meterGreyTargetSignal(pct,null);
  const rawValue=(mode==='eotf')
   ? meterGreyTargetEotfChartValue(pct,targetPeak,Lb,null)
   : meterGreyTargetChartValue(pct,targetPeak,Lb,null);
  const value=meterScaleEotfLuminancePlotValue(mode,rawValue,top,pct,signal);
  if(value!=null) pts.push([pct/end,value]);
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
  if(Number.isFinite(axis.min)&&Number.isFinite(axis.max)&&axis.max>axis.min) return {min:axis.min,max:axis.max};
  return {min:0,max:4};
 }
 let center=targets.length
  ? targets.reduce((sum,v)=>sum+v,0)/targets.length
  : targetGammaValue();
 if(!Number.isFinite(center)) center=2.2;
 let half=0.3;
 allVals.forEach(v=>{ half=Math.max(half,Math.abs(v-center)+0.08); });
 half=Math.ceil(half*20)/20;
 // Gamma is an exponent: a negative axis floor is meaningless. One large
 // outlier used to drag the symmetric lower bound well below zero (a 69 with
 // a 2.4 centre gave an axis of -64..71). Match the HDR branch and clamp at 0.
 return {min:Math.max(0,center-half),max:center+half};
}

function meterGreyChartTargetCode(step){
 if(!step) return null;
 if(!meterChartIsHdr()&&!meterGreyAllowsHeadroomTargets()) return null;
 return step.r_code!=null?step.r_code:step.r;
}

function targetGammaValue(){
 const tgt=(typeof meterGreyChartTargetGammaSelection==='function')?meterGreyChartTargetGammaSelection():((typeof meterGreyTargetGammaSelection==='function')?meterGreyTargetGammaSelection():((document.getElementById('meterTargetGamma')||{}).value||''));
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

function meterActiveChartSignalMode(){
 const active=(typeof meterActiveSeriesSignalMode!=='undefined')?String(meterActiveSeriesSignalMode||'').toLowerCase():'';
 return active||meterChartSignalMode();
}

function meterChartIsHdr(){
 return meterActiveChartSignalMode()!=='sdr';
}

function meterChartIsPq(){
 const sm=meterActiveChartSignalMode();
 return sm==='hdr10'||sm==='dv';
}

function meterChartIsHlg(){
 return meterActiveChartSignalMode()==='hlg';
}

function meterChartIsDv(){
 return meterActiveChartSignalMode()==='dv';
}

function meterChartHdrPeak(){
 const active=(typeof meterActiveSeriesMaxLuma!=='undefined')?Number(meterActiveSeriesMaxLuma):NaN;
 if(active>0&&isFinite(active)) return Math.min(10000,active);
 const top=document.getElementById('max_luma');
 const live=top?parseFloat(top.value):NaN;
 const cfg=parseFloat((config&&config.max_luma)||'1000');
 const peak=live>0?live:cfg;
 if(!(peak>0)) return 1000;
 return Math.min(10000,peak);
}

function meterSetActiveSeriesChartContext(source){
 const src=source||{};
 const metaStep=(Array.isArray(src.steps)?src.steps.find(st=>st&&(st.signal_mode||st.target_gamma||st.max_luma||st.dv_map_mode||st.dv_interface)):null)||{};
 const metaReading=(Array.isArray(src.readings)?src.readings.find(rd=>rd&&(rd.signal_mode||rd.target_gamma||rd.max_luma||rd.dv_map_mode||rd.dv_interface)):null)||{};
 const signal=String((src.signal_mode||src.requested_signal_mode||metaStep.signal_mode||metaReading.signal_mode||meterChartSignalMode()||'sdr')).toLowerCase();
 meterActiveSeriesSignalMode=signal;
 const target=String(src.target_gamma||metaStep.target_gamma||metaReading.target_gamma||'').toLowerCase();
 if(target) meterActiveSeriesTargetGamma=target;
 else if(signal==='dv'&&typeof meterDvAutoTargetGamma==='function') meterActiveSeriesTargetGamma=String(meterDvAutoTargetGamma()||'').toLowerCase()||null;
 else {
  const targetGammaEl=document.getElementById('meterTargetGamma');
  meterActiveSeriesTargetGamma=String((targetGammaEl&&targetGammaEl.value)||'').toLowerCase()||null;
 }
 const maxLumaEl=document.getElementById('max_luma');
 const maxLuma=Number((src.max_luma!=null)?src.max_luma:((metaStep.max_luma!=null)?metaStep.max_luma:((metaReading.max_luma!=null)?metaReading.max_luma:(maxLumaEl&&maxLumaEl.value))));
 meterActiveSeriesMaxLuma=(maxLuma>0&&isFinite(maxLuma))?maxLuma:null;
 const dvMapEl=document.getElementById('dv_map_mode');
 meterActiveSeriesDvMapMode=String((src.dv_map_mode!=null)?src.dv_map_mode:((metaStep.dv_map_mode!=null)?metaStep.dv_map_mode:((metaReading.dv_map_mode!=null)?metaReading.dv_map_mode:((dvMapEl&&dvMapEl.value)||'')))).toLowerCase()||null;
 const dvInterfaceEl=document.getElementById('dv_interface');
 meterActiveSeriesDvInterface=String((src.dv_interface!=null)?src.dv_interface:((metaStep.dv_interface!=null)?metaStep.dv_interface:((metaReading.dv_interface!=null)?metaReading.dv_interface:((dvInterfaceEl&&dvInterfaceEl.value)||'')))).toLowerCase()||null;
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

// Show the HDR roll-off control whenever the chart path can use it: a
// PQ-classified chart (HDR10/DV series) OR an st2084 Target Gamma selection —
// an operator who targets PQ must always be able to reach the BT.2390 toggle,
// even before the series context is classified. Refreshed on every chart
// context change and draw (including empty preset draws).
function meterUpdateHdrConfigVisibility(){
 const el=document.getElementById('meterHdrConfig');
 const sel=String(((document.getElementById('meterTargetGamma')||{}).value)||'').toLowerCase();
 if(el) el.style.display = (meterChartIsPq()||sel==='st2084') ? '' : 'none';
 meterUpdateHdrDiffuseWhiteVisibility();
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

// Chroma-only dE ITP -- same scale (720) and ITP transform, but with the
// luminance / intensity term (dI) dropped. Used for the SDR26 109% legal
// peak in the chart so its dE mirrors what the autocal worker computes
// (chrominance-only, since the peak calibrates its own RGB balance to
// pull the higher channels down to the lowest). Without this the chart
// dE includes the dI term against a (correctly suppressed) {0,0,0}
// target reference and reads as a huge number; with this it reads as
// the actual chromaticity gap to D65 the calibration is closing.
function deltaEITPChromaOnly(X1,Y1,Z1,X2,Y2,Z2){
 const a=xyzToICtCp(X1,Y1,Z1);
 const b=xyzToICtCp(X2,Y2,Z2);
 const dT=a.T-b.T;
 const dP=a.P-b.P;
 return 720*Math.sqrt(0.25*dT*dT+dP*dP);
}

// SDR26 peak detector for the chart path (chroma-only / no luminance target).
// Limited legal peak = 109; Full peak = 100. Must NOT match Limited's
// legal-white reference at 100% (ddc_target_ire 99 / legal_white_anchor).
// Mirrors worker lg_autocal_sdr26_dpg_is_peak_ire + Full labels.
function meterReadingIsSdr26LegalPeak(rd){
 if(!rd) return false;
 const _ire=Number(rd.ire!=null?rd.ire:(rd.plot_ire!=null?rd.plot_ire:(rd.nominal_ire!=null?rd.nominal_ire:(rd.stimulus!=null?rd.stimulus:null))));
 if(!Number.isFinite(_ire)) return false;
 const _layout=String(rd.series_mode||rd.ddc_layout||'').toLowerCase();
 const _name=String(rd.name||'').toLowerCase();
 const _label=String(rd.autocal_target_label||'').toLowerCase();
 const _sdrish=(_layout.indexOf('sdr')>=0) || _name.startsWith('sdr26_') || (rd.autocal_white_y!=null && Number(rd.autocal_white_y)>0);
 // Limited 109 legal peak
 if(Math.abs(_ire-109.0)<0.05){
  if(_sdrish) return true;
  if(rd.autocal_legal_white_anchor) return true;
  return false;
 }
 // Full 100 peak (not Limited 100 legal-white reference)
 if(Math.abs(_ire-100.0)<0.05){
  // Worker Full peak label
  if(_label.indexOf('full peak')>=0) return true;
  // DPG greyscale step name sdr26_100%
  if(_name.startsWith('sdr26_')) return true;
  // RGB-Limited AND Full white_reference without YCbCr-Limited legal-white
  // markers. RGB Limited uses the Full-shape ladder with Limited codes, so
  // its 100% reading is the genuine peak (no separate legal-white reference).
  if(rd.autocal_white_reference && !rd.autocal_legal_white_anchor && rd.ddc_target_ire==null){
   if(typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder()) return true;
  }
  return false;
 }
 return false;
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

function hlgInverseEotfSignal(luminance,minY,maxY){
	 const peak=maxY>0?maxY:1000;
	 const black=Math.max(0,minY||0);
	 const gamma=hlgOotf(peak);
	 const a=peak-black;
	 if(!(a>0)) return 0;
	 const b=Math.sqrt(3*Math.pow(Math.max(black/peak,0),1/gamma));
	 const normalized=(Math.max(0,luminance||0)-b)/a;
	 return Math.max(0,Math.min(1,Math.pow(Math.max(0,normalized),1/gamma)));
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
 const diffuseScale=(typeof meterHdrDiffuseScale==='function')?meterHdrDiffuseScale():1;
 const raw=meterChartPqDecodeNormalized(v)*((diffuseScale>0)?diffuseScale:1);
 if(meterChartBt2390Enabled()){
  const master=meterChartMasterPeak();
  // A Target White at or above the metadata mastering peak does not need
  // roll-off. Let the explicit target remain the chart endpoint instead of
  // pre-clipping it to Max Luma and silently turning 4000 back into 1000.
  if(peak>=master) return Math.min(raw,peak);
  return bt2390Tonemap(Math.min(raw,master),master,peak);
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
 const Lblack=Math.max(0,Number(Lb)||0);
 if(meterChartIsDv()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  return meterGreyTargetLuminance(clamped*100,peak,Lb||0,null);
 }
 // PQ path: the canonical PQ EOTF maps 0 -> 0 regardless of black floor, but
 // the operator's Target Black override wants the chart to anchor the black
 // floor at Lb. Honor Lb at signal<=0, and floor all PQ targets at Lb so the
 // curve does not dip below the operator's black target for low-signal IREs.
 // When Lb=0 this is a no-op (Math.max(pqLum,0)==pqLum).
 if(meterChartIsPq()){
  const peak=(clipPeak>0)?clipPeak:(Lw>0?Lw:meterChartHdrPeak());
  if(clamped<=0) return Lblack;
  return Math.max(meterChartHdrCodeLuminance(clamped,peak),Lblack);
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

// HCFR-style CIELUV ΔE using the same L*u*v* reference math.
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

// Returns whether the greyscale reference includes luminance error
// (Grey ref select = Absolute Y w/gamma). Retained for back-compat with
// callers that still pass boolean inclLum.
function meterIncludeLum(){
 const sel=document.getElementById('meterGreyRefMode');
 if(sel && sel.value) return sel.value==='eotf';
 const el=document.getElementById('meterIncludeLumError');
 return !!(el && el.checked);
}

// Separate-luminance-error split for the greyscale ΔE chart: when ticked
// the bars show the Absolute-Y-w/gamma total ΔE with a shimmering cap
// above the luminance-cancelled (chroma-only) portion. The split is only
// meaningful when Grey ref = Absolute Y w/gamma, so the checkbox is shown
// (and its state honored) only in that mode.
function meterSeparateLumEnabled(){
 const el=document.getElementById('meterSeparateLumError');
 return !!(el && el.checked);
}

// Shows the Separate Luminance Error checkbox only while Grey ref =
// Absolute Y w/gamma; hiding it also unticks it so a stale checked state
// can't survive a mode change.
function meterUpdateSeparateLumVisibility(){
 const sel=document.getElementById('meterGreyRefMode');
 const cb=document.getElementById('meterSeparateLumError');
 const wrap=document.getElementById('meterSeparateLumErrorWrap');
 if(!cb||!wrap) return;
 const show=!!(sel&&sel.value==='eotf');
 wrap.style.display=show?'':'none';
 if(!show&&cb.checked) cb.checked=false;
}

// Unified handler for the grey-ref / gray-world / RGB balance / greyscale
// ΔE / color ΔE selectors and the Separate Luminance Error checkbox.
// Persists selections and redraws charts.
let meterGreyAnalysisRefreshFrame=0;
let meterGreyAnalysisRefreshPaintFrame=0;

function meterCancelQueuedGreyAnalysisRefresh(){
 if(meterGreyAnalysisRefreshFrame){
  window.cancelAnimationFrame(meterGreyAnalysisRefreshFrame);
  meterGreyAnalysisRefreshFrame=0;
 }
 if(meterGreyAnalysisRefreshPaintFrame){
  window.cancelAnimationFrame(meterGreyAnalysisRefreshPaintFrame);
  meterGreyAnalysisRefreshPaintFrame=0;
 }
}

function meterDrawGreyAnalysisCharts(){
 meterGreyAnalysisRefreshPaintFrame=0;
 if(!Array.isArray(meterReadings)||!meterReadings.length) return;
 const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(isColor||meterIsTwoPointGreyscale()){
  drawAllCharts(meterReadings);
  return;
 }
 const allStepsRaw=meterSeriesSteps?meterGreyscaleSeriesSteps(meterSeriesSteps):null;
 const allSteps=allStepsRaw?meterFilterLgAutoCalChartItems(allStepsRaw):null;
 const rawGs=meterGreyscaleReadings(meterReadings);
 const gs=meterFilterLgAutoCalChartItems(rawGs);
 if(!gs.length) return;
 const readingMap=meterGreyscaleReadingMap(gs);
 // Grey-reference controls affect RGB balance and greyscale Delta E only.
 // Gamma-value, EOTF and luminance canvases retain both their pixels and
 // per-channel gamma cache.
 drawRGBChart(gs,allSteps,readingMap);
 drawDeltaEChart(gs,allSteps,readingMap,rawGs);
 chartRegisterInteraction();
 const live=meterCurrentPatchStep?meterFindReadingForStep(meterCurrentPatchStep):null;
 if(live&&meterReadingIsRealMeasurement(live)) updateLiveReading(live);
}

function meterQueueGreyAnalysisRefresh(){
 if(typeof meterCancelRunningGreyscaleChartRefresh==='function') meterCancelRunningGreyscaleChartRefresh();
 meterCancelQueuedGreyAnalysisRefresh();
 // Yield one complete paint so the native select closes and displays its new
 // value before any long-series canvas work begins.
 meterGreyAnalysisRefreshFrame=window.requestAnimationFrame(()=>{
  meterGreyAnalysisRefreshFrame=0;
  meterGreyAnalysisRefreshPaintFrame=window.requestAnimationFrame(meterDrawGreyAnalysisCharts);
 });
}

// RGB balance formula changes are presentation-only. Redraw the RGB canvas,
// its hit zones, and the live RGB companion immediately from one formula state
// so the plotted lines cannot lag behind the hover values while the general
// two-frame analysis refresh queue is yielding to browser input.
function meterOnRgbBalanceFormulaChange(){
 try{ meterSaveColorPrefs(); }catch(e){}
 if(!Array.isArray(meterReadings)||!meterReadings.length) return;
 const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(isColor||meterIsTwoPointGreyscale()){
  drawAllCharts(meterReadings);
  return;
 }
 if(typeof meterCancelRunningGreyscaleChartRefresh==='function') meterCancelRunningGreyscaleChartRefresh();
 meterCancelQueuedGreyAnalysisRefresh();
 const allStepsRaw=meterSeriesSteps?meterGreyscaleSeriesSteps(meterSeriesSteps):null;
 const allSteps=allStepsRaw?meterFilterLgAutoCalChartItems(allStepsRaw):null;
 const gs=meterFilterLgAutoCalChartItems(meterGreyscaleReadings(meterReadings));
 if(!gs.length) return;
 const readingMap=meterGreyscaleReadingMap(gs);
 drawRGBChart(gs,allSteps,readingMap);
 chartRegisterInteraction();
 const live=meterCurrentPatchStep?meterFindReadingForStep(meterCurrentPatchStep):null;
 if(live&&meterReadingIsRealMeasurement(live)) updateLiveReading(live);
}

function meterOnGreyRefChange(src){
 meterUpdateSeparateLumVisibility();
 try{ meterSaveColorPrefs(); }catch(e){}
 // Target Gamma has a dedicated change listener that regrades series targets
 // and performs the required full target-curve refresh.
 if(src==='target-gamma') return;
 if(meterReadings && meterReadings.length){
  // Invalidate any per-reading greyscale analysis cache (mode/form/gw changed).
  meterReadings.forEach(r=>{
   if(!r) return;
   delete r._dE_cache_key;
   delete r._dE_raw;
   delete r._dE_lc;
   delete r._gamma_rgb;
  });
  if(meterAutoCalRunning||meterAutoCalPolling||meterLg3dAutoCalRunning||meterLg3dAutoCalPolling){
   const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
   if(isColor) drawAllCharts([...meterReadings]);
   else meterQueueGreyAnalysisRefresh();
  } else if(meterActiveSeriesType && meterActiveSeriesPoints && typeof meterRefreshActiveSeriesCharts==='function'){
   // Post-autocal greyscale/color toggle: route through the lighter
   // drawAllCharts path instead of meterRefreshActiveSeriesCharts. The
   // refresh path re-stamps target_Yn via meterRegradeActiveSeriesTargets
   // using meterLgAutoCalTargetYnForStimulus (which has no ST2084 PQ
   // branch -- see the 2026-06-29 memory note), so a sequence of
   // check/uncheck/check toggles between the autocal-pinned '2.2' stamp
   // and a post-autocal 'st2084' stamp and the dE ITP chart jumps from
   // near 1 to 95+. The toggle is a chart-display change, not a gamma
   // change -- leaving target_Yn alone keeps the chart consistent across
   // toggles. (operator-initiated Target Gamma dropdown changes still go
   // through meterRefreshActiveSeriesCharts from meterOnTargetGammaChange.)
   if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations') drawAllCharts(meterReadings);
   else meterQueueGreyAnalysisRefresh();
  } else {
   if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations') drawAllCharts(meterReadings);
   else meterQueueGreyAnalysisRefresh();
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
  color_sep_lum: cb('meterColorSeparateLumError'),
   sep_lum:       cb('meterSeparateLumError'),
   target_gamma:  v('meterTargetGamma'),
    hdr_bt2390:    cb('meterHdrApplyBT2390'),
    gamma_per_channel: cb('meterPerChannelGamma'),
    eotf_absolute: cb('meterEotfAbsolute'),
    eotf_per_channel: cb('meterEotfPerChannel'),
    eotf_log: cb('meterEotfLogScale'),
    luminance_log: cb('meterLuminanceLogScale'),
    cie_3d: cb('meterCie3dView'),
    chromaticity_chart: v('meterChromaticityChart'),
    hdr_diffuse_white: v('meterHdrDiffuseWhite'),
    hdr_diffuse_white_auto: cb('meterHdrDiffuseWhiteAuto')
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

function meterNormalizeSavedGreyDeltaEForm(form){
 const normalized=String(form==null?'':form).trim().toLowerCase();
 if(!normalized || normalized==='auto' || normalized==='deluv76') return 'deitp';
 return normalized;
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
  setVal('meterDeltaEForm',  meterNormalizeSavedGreyDeltaEForm(p.de_form));
  setVal('meterColorDeltaEForm', p.color_de_form);
  setChk('meterColorIncludeLumError', p.color_incl_lum);
  setChk('meterColorSeparateLumError', p.color_sep_lum);
  meterUpdateColorSeparateLumVisibility();
    setChk('meterSeparateLumError', greyMode==='eotf' ? p.sep_lum : '0');
    meterUpdateSeparateLumVisibility();
  setVal('meterTargetGamma', p.target_gamma);
  setChk('meterHdrApplyBT2390', p.hdr_bt2390);
  setChk('meterPerChannelGamma', p.gamma_per_channel);
  setChk('meterEotfAbsolute', p.eotf_absolute);
  setChk('meterEotfPerChannel', p.eotf_per_channel);
  setChk('meterEotfLogScale', p.eotf_log);
  setChk('meterLuminanceLogScale', p.luminance_log);
  setChk('meterCie3dView', p.cie_3d);
  setVal('meterChromaticityChart', p.chromaticity_chart);
  setVal('meterHdrDiffuseWhite', p.hdr_diffuse_white);
  setChk('meterHdrDiffuseWhiteAuto', p.hdr_diffuse_white_auto==null?'1':p.hdr_diffuse_white_auto);
  meterSyncHdrDiffuseWhiteControl();
  try{ meterUpdateCie3dLabel(); meterApplyCie3dLayout(); }catch(e2){}
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
function hcfrGreyRef(ire, Ym, Lw, Lb, modeOrIncl, code, gwWeight, targetYOverride){
 const mode = meterResolveGreyRefMode(modeOrIncl);
 const gw = (gwWeight>0 && gwWeight<=1) ? gwWeight : 1.0;
 const measuredPeak = (Lw>0) ? Lw : (Ym>0 ? Ym : 1);
 // Always reference greyscale chromaticity to the target white (D65). This
 // keeps the greyscale 100% white point aligned with the color-series white
 // readout instead of forcing ΔE at 100% to zero in HDR/DV.
 const wp = meterTargetWhitePoint();
 const wxN = wp.X;
 const wzN = wp.Z;
 let YWhite = measuredPeak;
 let refVy = measuredPeak>0 ? Ym/measuredPeak : 0;
 if(mode==='absolute'){
  YWhite = (Ym>0) ? Ym : measuredPeak;
  refVy = 1.0;
 } else if(mode==='eotf'){
  const targetPeak = meterChartIsHdr() ? meterGreyTargetPeak(measuredPeak) : measuredPeak;
  const stampedY=Number(targetYOverride);
  const tgtY = (Number.isFinite(stampedY)&&stampedY>=0) ? stampedY : meterGreyTargetLuminance(ire, targetPeak, Lb||0, code);
  refVy = measuredPeak>0 ? tgtY/measuredPeak : 0;
 }
 return {
  YWhite: YWhite*gw,
  refX: wxN*refVy, refY: refVy, refZ: wzN*refVy,
  YWhiteRef: 1.0*gw, wxN, wzN,
  mode: mode, gwWeight: gw
 };
}

// Simplified deltaE2000
function deltaE2000(lab1,lab2){ const dL=lab2.L-lab1.L;
 const C1=Math.sqrt(lab1.a*lab1.a+lab1.b*lab1.b);
 const C2=Math.sqrt(lab2.a*lab2.a+lab2.b*lab2.b);
 const Cb=(C1+C2)/2;
 const G=0.5*(1-Math.sqrt(Math.pow(Cb,7)/(Math.pow(Cb,7)+Math.pow(25,7))));
 const a1p=lab1.a*(1+G),a2p=lab2.a*(1+G);
 const C1p=Math.sqrt(a1p*a1p+lab1.b*lab1.b);
 const C2p=Math.sqrt(a2p*a2p+lab2.b*lab2.b);
 const dCp=C2p-C1p;
 let h1p=(a1p===0&&lab1.b===0)?0:Math.atan2(lab1.b,a1p)*180/Math.PI; if(h1p<0) h1p+=360;
 let h2p=(a2p===0&&lab2.b===0)?0:Math.atan2(lab2.b,a2p)*180/Math.PI; if(h2p<0) h2p+=360;
 const Cprod=C1p*C2p;
 let dhp;
 if(Cprod===0){ dhp=0; }
 else {
  dhp=h2p-h1p;
  if(dhp>180) dhp-=360;
  else if(dhp<-180) dhp+=360;
 }
 const dHp=2*Math.sqrt(Cprod)*Math.sin(dhp*Math.PI/360);
 const Lbp=(lab1.L+lab2.L)/2;
 const Cbp=(C1p+C2p)/2;
 let Hbp;
 if(Cprod===0){ Hbp=h1p+h2p; }
 else {
  const dh=Math.abs(h1p-h2p);
  if(dh<=180) Hbp=(h1p+h2p)/2;
  else if(h1p+h2p<360) Hbp=(h1p+h2p+360)/2;
  else Hbp=(h1p+h2p-360)/2;
 }
 const T=1-0.17*Math.cos((Hbp-30)*Math.PI/180)+0.24*Math.cos(2*Hbp*Math.PI/180)+0.32*Math.cos((3*Hbp+6)*Math.PI/180)-0.20*Math.cos((4*Hbp-63)*Math.PI/180);
 const SL=1+0.015*Math.pow(Lbp-50,2)/Math.sqrt(20+Math.pow(Lbp-50,2));
 const SC=1+0.045*Cbp;
 const SH=1+0.015*Cbp*T;
 const RT=-2*Math.sqrt(Math.pow(Cbp,7)/(Math.pow(Cbp,7)+Math.pow(25,7)))*Math.sin(60*Math.exp(-Math.pow((Hbp-275)/25,2))*Math.PI/180);
 return Math.sqrt(Math.pow(dL/SL,2)+Math.pow(dCp/SC,2)+Math.pow(dHp/SH,2)+RT*(dCp/SC)*(dHp/SH));
}

// CIE 1976 Lab ΔE (Euclidean distance in L*a*b*).
function deltaE76Lab(l1,l2){
 const dL=l1.L-l2.L, da=l1.a-l2.a, db=l1.b-l2.b;
 return Math.sqrt(dL*dL+da*da+db*db);
}

// CIE94 (graphics / kL=kC=kH=1 by default). Reference = lab2.
function deltaE94(l1,l2,kL,kC,kH){
 kL=kL||1; kC=kC||1; kH=kH||1;
 const dL=l1.L-l2.L;
 const C1=Math.hypot(l1.a,l1.b), C2=Math.hypot(l2.a,l2.b);
 const dC=C1-C2;
 const da=l1.a-l2.a, db=l1.b-l2.b;
 const dHsq=Math.max(0, da*da+db*db-dC*dC);
 const SL=1, SC=1+0.045*C1, SH=1+0.015*C1;
 return Math.sqrt(Math.pow(dL/(kL*SL),2)+Math.pow(dC/(kC*SC),2)+dHsq/Math.pow(kH*SH,2));
}

// CMC(l:c) ΔE. l=c=1 is CMC(1:1) perceptibility; l=2,c=1 is CMC(2:1) acceptability.
function deltaECMC(l1,l2,lParam,cParam){
 const l=lParam||1, c=cParam||1;
 const C1=Math.hypot(l1.a,l1.b), C2=Math.hypot(l2.a,l2.b);
 const dC=C1-C2, dL=l1.L-l2.L;
 const da=l1.a-l2.a, db=l1.b-l2.b;
 const dHsq=Math.max(0, da*da+db*db-dC*dC);
 let H1=Math.atan2(l1.b,l1.a)*180/Math.PI; if(H1<0) H1+=360;
 const F=Math.sqrt(Math.pow(C1,4)/(Math.pow(C1,4)+1900));
 const T=(H1>=164&&H1<=345)
  ? (0.56+Math.abs(0.2*Math.cos((H1+168)*Math.PI/180)))
  : (0.36+Math.abs(0.4*Math.cos((H1+35)*Math.PI/180)));
 const SL=(l1.L<16)?0.511:(0.040975*l1.L/(1+0.01765*l1.L));
 const SC=0.0638*C1/(1+0.0131*C1)+0.638;
 const SH=SC*(F*T+1-F);
 return Math.sqrt(Math.pow(dL/(l*SL),2)+Math.pow(dC/(c*SC),2)+dHsq/(SH*SH));
}

// Barten (1999) CSF-derived JND at average field luminance L (cd/m²).
// Returns the L* increment per 1 JND at that luminance (approx; from
// ITU-R BT.2246-7 §7). Clamps to a safe floor so SL never vanishes.
function bartenJND(L){
 const Lc=Math.max(0.005, L);
 // Simplified Barten JND normalized to 1 unit at ~100 nit: ΔL/L scales with
 // Lc^(-0.5) in the low-nit region and approaches Weber (≈0.0106) at 100+ nit.
 const weber=0.0106;
 const dL_over_L = weber * Math.sqrt(100/Lc) ;
 // Convert relative threshold to an L* delta: dL* ≈ 116/3 * f'(Y/Yn) * ΔY/Yn.
 // For perceptual weighting we only need a monotonic scale — return dL*/unit.
 const Yn=100;
 const r=Lc/Yn;
 const fprime = (r>0.008856) ? (1/3)*Math.pow(r,-2/3) : 903.2963/116;
 const dLstar = 116 * fprime * (Lc * dL_over_L) / Yn;
 return Math.max(dLstar, 0.05);
}

// dE2000 with SL replaced by a Barten-JND-scaled lightness term so
// "1 ΔE ≈ 1 JND" across the HDR luminance range. Hybrid JND formulation
// derived from Barten CSF so near-black is not overweighted.
function deltaE2000JND(lab1,lab2,Ym,Yref){
 const dL=lab2.L-lab1.L;
 const C1=Math.sqrt(lab1.a*lab1.a+lab1.b*lab1.b);
 const C2=Math.sqrt(lab2.a*lab2.a+lab2.b*lab2.b);
 const Cb=(C1+C2)/2;
 const G=0.5*(1-Math.sqrt(Math.pow(Cb,7)/(Math.pow(Cb,7)+Math.pow(25,7))));
 const a1p=lab1.a*(1+G),a2p=lab2.a*(1+G);
 const C1p=Math.sqrt(a1p*a1p+lab1.b*lab1.b);
 const C2p=Math.sqrt(a2p*a2p+lab2.b*lab2.b);
 const dCp=C2p-C1p;
 let h1p=(a1p===0&&lab1.b===0)?0:Math.atan2(lab1.b,a1p)*180/Math.PI; if(h1p<0) h1p+=360;
 let h2p=(a2p===0&&lab2.b===0)?0:Math.atan2(lab2.b,a2p)*180/Math.PI; if(h2p<0) h2p+=360;
 const Cprod=C1p*C2p;
 let dhp;
 if(Cprod===0){ dhp=0; }
 else {
  dhp=h2p-h1p;
  if(dhp>180) dhp-=360;
  else if(dhp<-180) dhp+=360;
 }
 const dHp=2*Math.sqrt(Cprod)*Math.sin(dhp*Math.PI/360);
 const Cbp=(C1p+C2p)/2;
 let Hbp;
 if(Cprod===0){ Hbp=h1p+h2p; }
 else {
  const dh=Math.abs(h1p-h2p);
  if(dh<=180) Hbp=(h1p+h2p)/2;
  else if(h1p+h2p<360) Hbp=(h1p+h2p+360)/2;
  else Hbp=(h1p+h2p-360)/2;
 }
 const T=1-0.17*Math.cos((Hbp-30)*Math.PI/180)+0.24*Math.cos(2*Hbp*Math.PI/180)+0.32*Math.cos((3*Hbp+6)*Math.PI/180)-0.20*Math.cos((4*Hbp-63)*Math.PI/180);
 // SL replaced with Barten JND at the field-average luminance. Falls back
 // to the standard CIEDE2000 SL when Ym/Yref are not supplied.
 let SL;
 if(Ym>0 || Yref>0){
  const Lfield=Math.max(Ym||0, Yref||0, 0.005);
  SL=bartenJND(Lfield);
 } else {
  const Lbp=(lab1.L+lab2.L)/2;
  SL=1+0.015*Math.pow(Lbp-50,2)/Math.sqrt(20+Math.pow(Lbp-50,2));
 }
 const SC=1+0.045*Cbp;
 const SH=1+0.015*Cbp*T;
 const RT=-2*Math.sqrt(Math.pow(Cbp,7)/(Math.pow(Cbp,7)+Math.pow(25,7)))*Math.sin(60*Math.exp(-Math.pow((Hbp-275)/25,2))*Math.PI/180);
 return Math.sqrt(Math.pow(dL/SL,2)+Math.pow(dCp/SC,2)+Math.pow(dHp/SH,2)+RT*(dCp/SC)*(dHp/SH));
}

// Reads the greyscale ΔE form selector. AutoCal and new installs default to ITP.
function meterDeltaEForm(){
 const sel=document.getElementById('meterDeltaEForm');
 if(sel && sel.value) return sel.value;
 return 'deitp';
}

function meterDeltaEFormLabel(form){
 const f=form||meterDeltaEForm();
 return {
  de2000:'ΔE 2000',
  de94:'ΔE 94',
  de76lab:'ΔE 76 (Lab)',
  deluv76:'ΔE 76 (Luv)',
  decmc:'ΔE CMC(1:1)',
  de2000_jnd:'ΔE 2000 JND',
  deitp:'ΔE ITP',
  auto:'ΔE Auto'
 }[f]||'ΔE';
}

function meterNormalizePortValue(value){
 const normalized=String(value==null?'':value).trim();
 return /^\d+$/.test(normalized)?normalized:'';
}

function meterOptionLabel(meter){
 if(!meter) return 'Meter';
 const name=String(meter.name||'Meter').trim()||'Meter';
 const physical=String(meter.physical_port||'').trim();
 // Square brackets: the TV and Patch Companion status lines write their
 // address/host suffix as [ ... ], so the meter's port suffix matches.
 if(physical) return `${name} [USB ${physical}]`;
 const port=meterNormalizePortValue(meter.port_num);
 return port ? `${name} [Meter ${port}]` : name;
}

function meterFindByPort(port){
 const normalized=meterNormalizePortValue(port);
 if(!normalized) return null;
 return (meterInventory||[]).find(m=>meterNormalizePortValue(m&&m.port_num)===normalized)||null;
}

function meterKindFromName(name){
 const normalized=String(name||'').toLowerCase();
 if(/(?:^|[^a-z0-9])(jeti|specbos|spectro|spectroradi|i1\s*pro|i1pro|cs-1000|cs-150|cs-2000|cr-2\d\d|cr-3\d\d|fd-5|fd-7|myiro)(?:[^a-z0-9]|$)/.test(normalized)) return 'spectro';
 if(/spyder|display\s*pro|i1display|i1\s*display|colormunki\s*display|klein|sequel\s*chroma/.test(normalized)) return 'colorimeter';
 return '';
}

function meterSimulateSpectroEnabled(){
 const el=document.getElementById('meterSimulateSpectro');
 return !!(el&&el.checked);
}

function meterKind(meter){
 if(meter && meterSimulateSpectroEnabled()) return 'spectro';
 const kind=String((meter&&meter.meter_type)||'').trim().toLowerCase();
 if(kind==='spectro'||kind==='colorimeter') return kind;
 return meterKindFromName(meter&&meter.name);
}

function meterIsSpectrophotometer(meter){
 return meterKind(meter)==='spectro';
}

function meterIsColorimeter(meter){
 return meterKind(meter)==='colorimeter';
}

function meterIsSpyderX(meter){
 return String((meter&&meter.usb_id)||'').toLowerCase()==='085c:0a00';
}

function meterRequiresManualCalibration(meter){
 if(!meter) return false;
 if(meterIsSpectrophotometer(meter)) return true;
 // Argyll's Spyder drivers expose an operator-triggered dark calibration.
 // i1d3-family colorimeters calibrate internally and should not show a
 // misleading covered-sensor button.
 return /(?:^|[^a-z0-9])spyder\s*(?:x2|x|[2-5])(?:[^a-z0-9]|$)/i.test(String(meter.name||''));
}

function meterSelectedMeasurementIsSpyderX(){
 return meterIsSpyderX(meterSelectedMeasurementMeter());
}

function meterSpyderXNativeModeLabel(){
 const tech=getDisplayTechnology();
 if(tech.startsWith('lcd_wled')) return 'Standard LED';
 if(tech.startsWith('lcd_rgbled')) return 'Wide Gamut LED';
 if(tech.startsWith('lcd_gbled')) return 'GB-R LED';
 return 'General';
}

function meterSpyderXNativeModeHelp(){
 const mode=meterSpyderXNativeModeLabel();
 let purpose='';
 if(mode==='Standard LED') purpose='This is ArgyllCMS display type -y e for white LED backlit LCDs.';
 else if(mode==='Wide Gamut LED') purpose='This is ArgyllCMS display type -y b for RGB LED backlit LCDs.';
 else if(mode==='GB-R LED') purpose='This is ArgyllCMS display type -y i for GB-R phosphor LED backlit LCDs.';
 else purpose='This is ArgyllCMS display type -y l, its default General LCD/CCFL calibration. PGenerator+ uses General as the fallback when the selected display has no matching SpyderX built-in mode, including OLED, QD-OLED, plasma, projector, and CRT.';
 return 'The Display Type selection chooses the SpyderX built-in calibration. '+purpose+' SpyderX does not support CCSS spectral profiles in ArgyllCMS. For a display without a matching built-in mode, use a CCMX created for this SpyderX and display.';
}

function meterUpdateMeterCapabilityControls(){
 const spyderX=meterSelectedMeasurementIsSpyderX();
 const selectedMeter=meterSelectedMeasurementMeter();
 const spectro=!!(selectedMeter&&meterIsSpectrophotometer(selectedMeter));
 const ccss=document.getElementById('meterCcssProfile');
 const wizardCcss=document.getElementById('meterAutoCalCcssProfile');
 const refresh=document.getElementById('meterRefreshRate');
 const observerSelect=document.getElementById('meterChromaticityChart');
 const ccssNote=document.getElementById('meterCcssCapabilityNote');
 const profileHelp=document.getElementById('meterCorrectionProfileHelp');
 const refreshNote=document.getElementById('meterRefreshCapabilityNote');
 const nativeLabel=meterSpyderXNativeModeLabel();
 const setCapabilityOptionText=(sel,text)=>{
  if(!sel) return;
  // Change only the visible label. Keep the operator's real selection intact
  // so switching back to a CCSS-capable meter restores its saved profile and
  // refresh preference without a hidden settings mutation.
  for(const opt of Array.from(sel.options||[])){
   if(opt.dataset&&opt.dataset.capabilityOriginalText!=null){
    opt.textContent=opt.dataset.capabilityOriginalText;
    delete opt.dataset.capabilityOriginalText;
   }
  }
  if(spyderX&&sel.selectedIndex>=0){
   const selected=sel.options[sel.selectedIndex];
   selected.dataset.capabilityOriginalText=selected.textContent;
   selected.textContent=text;
  }
 };
 for(const sel of [ccss,wizardCcss]){
  if(!sel) continue;
  sel.disabled=spectro;
  sel.title=spectro
   ? 'Spectrophotometers measure spectral data directly and do not use CCSS or CCMX correction profiles.'
   : spyderX
   ? 'SpyderX supports matching CCMX matrices but not CCSS spectral profiles.'
   : '';
  meterSyncCcssProfileHoverTitle(sel);
 }
 if(refresh){
  setCapabilityOptionText(refresh,'Automatic (SpyderX native)');
  refresh.disabled=spyderX;
  refresh.title=spyderX
   ? 'SpyderX handles timing internally and does not support a manual refresh-rate override.'
   : '';
 }
 if(ccssNote){
  ccssNote.style.display=spyderX?'':'none';
  if(spyderX) ccssNote.textContent='SpyderX native mode: '+nativeLabel+'. CCMX supported; CCSS unavailable.';
 }
 if(profileHelp){
  profileHelp.title=spectro
   ? 'Spectrophotometers measure spectral data directly and do not use CCSS or CCMX correction profiles.'
   : spyderX
   ? meterSpyderXNativeModeHelp()
   : 'CCSS profiles are reusable spectral display corrections for compatible colorimeters. CCMX profiles are meter-specific correction matrices. Choose No Correction for the meter\'s native response.';
 }
 if(refreshNote) refreshNote.style.display=spyderX?'':'none';
 if(observerSelect){
  const spectralObserverAvailable=meterIsSpectrophotometer(meterSelectedMeasurementMeter());
  const tristimulusViews=new Set(['cie1931_2','cie1976_2']);
  for(const option of Array.from(observerSelect.options||[])){
   if(!spectralObserverAvailable&&!tristimulusViews.has(option.value)){
    option.disabled=true;
    option.dataset.spectralObserverDisabled='1';
    option.title='Select a spectrophotometer to use this observer.';
   }else if(option.dataset&&option.dataset.spectralObserverDisabled==='1'){
    option.disabled=false;
    delete option.dataset.spectralObserverDisabled;
    option.title='';
   }
  }
  if(!spectralObserverAvailable&&!tristimulusViews.has(observerSelect.value)){
   observerSelect.value='cie1931_2';
   if(typeof meterOnChromaticityChartChange==='function'&&!meterChromaticityReadActive()){
    meterOnChromaticityChartChange();
   }
   toast('The selected observer requires a spectrophotometer. Observer reset to CIE 1931.',true);
  }
  if(typeof meterSyncOpponentChartAvailability==='function'){
   meterSyncOpponentChartAvailability(
    typeof meterActiveSeriesType==='undefined'?null:meterActiveSeriesType,
    typeof meterActiveSeriesPoints==='undefined'?null:meterActiveSeriesPoints
   );
  }
 }
 if(Array.isArray(meterCcssLibrary)&&typeof populateMeterCcssProfileSelect==='function'){
  populateMeterCcssProfileSelect('meterAutoCalCcssProfile');
 }
 // The SpyderX built-in display calibration is represented by the Auto
 // option. Do not replace the visible name of a selected CCMX file.
 if(spyderX){
  for(const sel of [ccss,wizardCcss]){
   const autoOpt=sel&&sel.querySelector('option[value=""]');
   if(autoOpt) autoOpt.textContent='SpyderX native: '+nativeLabel;
  }
 }
}

function meterSelectedMeasurementMeter(){
 return meterFindByPort(meterSelectedMeasurementPort())||(Array.isArray(meterInventory)?meterInventory[0]:null);
}

function meterStoredMeasurementPort(){
 const select=document.getElementById('meterMeasurementPort');
 return meterNormalizePortValue(select?select.value:meterMeasurementPort);
}

function meterSelectedMeasurementRequiresReady(){
 return meterIsSpectrophotometer(meterSelectedMeasurementMeter());
}

function meterAutoMeasurementOptionLabel(preferredMeter){
 const meter=preferredMeter||meterFindByPort(meterResolvedMeasurementPort)||meterFindByPort(meterMeasurementPort)||(Array.isArray(meterInventory)?meterInventory[0]:null);
 const label=meter?meterOptionLabel(meter):(meterLastKnownName||'Meter');
 return label&&label!=='Meter'?('Auto: '+label):'Auto';
}

function meterPopulateRoleSelects(meters,detectedPort){
 const savedMeasurementPort=meterStoredMeasurementPort();
 meterInventory=Array.isArray(meters)
  ? meters.filter(m=>meterNormalizePortValue(m&&m.port_num))
  : [];
 meterCcssCreateInventoryReady=true;
 const select=document.getElementById('meterMeasurementPort');
 const autoMeter=meterFindByPort(detectedPort)||meterFindByPort(savedMeasurementPort)||(meterInventory[0]||null);
 const current=meterNormalizePortValue(select&&select.value)||savedMeasurementPort;
 const currentMeter=meterFindByPort(current);
 const autoPort=meterNormalizePortValue(autoMeter&&autoMeter.port_num);
 const resolvedPort=currentMeter?current:autoPort;
 const useAutoSelection=!!(autoPort && (!currentMeter || (current===autoPort && meterInventory.length===1)));
  if(select){
   select.innerHTML='';
   // No "Auto" option: list only connected meters, each directly selectable.
   // The previously-deduplicated "Auto: <meter>" entry caused duplicate
   // listings and resolution mismatches; a plain list of connected meters is
   // unambiguous and always has one selected.
   meterInventory.forEach(meter=>{
    const port=meterNormalizePortValue(meter.port_num);
    const option=document.createElement('option');
    option.value=port;
    option.textContent=meterOptionLabel(meter);
    select.appendChild(option);
   });
   select.disabled=meterInventory.length===0;
   // Keep the operator's current meter selected if it is still connected;
   // otherwise fall back to the detected meter, then the first listed.
   const desired=currentMeter?current:autoPort;
   if(desired && meterInventory.some(m=>meterNormalizePortValue(m.port_num)===desired)){
    select.value=desired;
   } else if(select.options.length>0){
    select.value=select.options[0].value;
   }
  }
 meterMeasurementPort=meterStoredMeasurementPort();
 meterResolvedMeasurementPort=resolvedPort;
 meterProfilingPort=meterNormalizePortValue(meterProfilingPort);
 meterRenderCcssCreateChoices();
 meterUpdateProfileFieldVisibility();
 meterUpdateMeterCapabilityControls();
}

function meterSelectedMeasurementPort(){
 // The dropdown lists only connected meters (no "Auto" option) and always has
 // one selected, so the live SELECT value is authoritative. The saved-preference
 // and autodetect fallbacks only matter before the first populate or if the
 // SELECT is transiently empty.
 return meterStoredMeasurementPort()||meterNormalizePortValue(meterSavedMeasurementPort)||meterNormalizePortValue(meterResolvedMeasurementPort);
}

function meterSelectedMeasurementLabel(fallbackMeter){
 const select=document.getElementById('meterMeasurementPort');
 const selectedPort=meterSelectedMeasurementPort();
 if(selectedPort && select){
  const selectedOption=select.options[select.selectedIndex];
  if(selectedOption && meterNormalizePortValue(selectedOption.value)===selectedPort){
   const text=String(selectedOption.textContent||'').trim();
   if(text) return text;
  }
 }
 const meter=fallbackMeter||meterFindByPort(selectedPort);
 if(meter) return meterOptionLabel(meter);
 if(selectedPort) return `Meter (Port ${selectedPort})`;
 if(fallbackMeter) return meterOptionLabel(fallbackMeter);
 return meterLastKnownName||'Meter';
}

function meterSelectedProfilingPort(){
 return meterNormalizePortValue(meterProfilingPort);
}

function meterSupportsHighResolutionSpectrum(meter){
 if(!meter||!meterIsSpectrophotometer(meter)) return false;
 const usb=String(meter.usb_id||'').trim().toLowerCase();
 if(/^(?:0971:2000|0971:2007|0765:6008|0765:6009)$/.test(usb)) return true;
 const name=String(meter.name||'').trim().toLowerCase();
 if(/(?:colormunki|colorchecker|i1)\s*display|display\s*(?:pro|plus|studio)/.test(name)) return false;
 return /(?:eye[- ]?one|i1)\s*pro(?:\s*(?:2|3|3\s*plus))?|efi\s*es[- ]?(?:1000|2000|3000)|colormunki(?:\s*(?:photo|design))?|i1\s*studio|colorchecker\s*studio/.test(name);
}

function meterCcssCreateSpectros(){
 return (meterInventory||[]).filter(meter=>meterIsSpectrophotometer(meter));
}

function meterCcssCreateColorimeters(){
 return (meterInventory||[]).filter(meter=>meterIsColorimeter(meter));
}

function meterCcssCreateReferenceMeters(){
 if(meterCcssCreateFormatValue()==='ccmx'&&meterCcssCreateMethodValue()==='measure'){
  const meters=(meterInventory||[]).filter(meter=>meterIsSpectrophotometer(meter)||meterIsColorimeter(meter));
  return meters.slice().sort((a,b)=>Number(meterIsColorimeter(a))-Number(meterIsColorimeter(b)));
 }
 return meterCcssCreateSpectros();
}

function meterCcssCreateFormatValue(){
 const select=document.getElementById('meterCcssCreateFormat');
 const value=String((select&&select.value)||meterCcssCreateFormat||'ccss').toLowerCase();
 meterCcssCreateFormat=value==='ccmx'?'ccmx':'ccss';
 return meterCcssCreateFormat;
}

function meterCcssCreateMethodValue(){
 const select=document.getElementById('meterCcssCreateMethod');
 const value=String((select&&select.value)||meterCcssCreateMethod||'measure').toLowerCase();
 meterCcssCreateMethod=/^(?:json|manual)$/.test(value)?value:'measure';
 return meterCcssCreateMethod;
}

function meterCcssCreateMethodChanged(){
 meterCcssCreateMethodValue();
 meterCcssCreateUpdateCopy();
 meterRenderCcssCreateChoices();
 meterCcssCreateUpdateStartState();
}

const METER_CCMX_MATRIX_IDS=[
 ['meterCcmxM11','meterCcmxM12','meterCcmxM13'],
 ['meterCcmxM21','meterCcmxM22','meterCcmxM23'],
 ['meterCcmxM31','meterCcmxM32','meterCcmxM33']
];

function meterCcssCreateReadMatrix(){
 return METER_CCMX_MATRIX_IDS.map(row=>row.map(id=>{
  const el=document.getElementById(id);
  const value=Number(el&&el.value);
  if(!Number.isFinite(value)) throw new Error('Every matrix cell must contain a number.');
  return value;
 }));
}

function meterCcssCreateSetMatrix(matrix){
 METER_CCMX_MATRIX_IDS.forEach((row,r)=>row.forEach((id,c)=>{
  const el=document.getElementById(id);
  if(el) el.value=String(Number(matrix[r][c]));
 }));
}

function meterParseCcmxMatrixJson(rawText){
 const parsed=JSON.parse(String(rawText||'{}'));
 const matrix=parsed&&typeof parsed==='object'&&!Array.isArray(parsed)&&Array.isArray(parsed.matrix)
  ? parsed.matrix
  : parsed;
 if(!Array.isArray(matrix)||matrix.length!==3||matrix.some(row=>!Array.isArray(row)||row.length!==3)){
  throw new Error('Matrix must be a 3x3 array.');
 }
 return matrix.map(row=>row.map(value=>{
  const numeric=Number(value);
  if(!Number.isFinite(numeric)) throw new Error('Matrix values must be numeric.');
  return numeric;
 }));
}

function meterCcssCreateImportJson(evt){
 const file=evt&&evt.target&&evt.target.files?evt.target.files[0]:null;
 const status=document.getElementById('meterCcssCreateJsonStatus');
 meterCcssCreateJsonLoaded=false;
 if(!file){
  if(status) status.textContent='Choose a JSON file exported by the former PGenerator+ XYZ Correction Matrix tool.';
  meterCcssCreateUpdateStartState();
  return;
 }
 const reader=new FileReader();
 reader.onload=()=>{
  try{
   const matrix=meterParseCcmxMatrixJson(reader.result);
   meterCcssCreateSetMatrix(matrix);
   meterCcssCreateJsonLoaded=true;
   if(status){
    status.textContent='Loaded '+file.name+'. Review the matrix below, then create the CCMX.';
    status.style.color='var(--green)';
   }
  }catch(e){
   if(status){
    status.textContent=e&&e.message?e.message:'Invalid XYZ correction matrix JSON.';
    status.style.color='var(--red)';
   }
   toast('Invalid XYZ correction matrix JSON',true);
  }
  meterCcssCreateUpdateStartState();
 };
 reader.onerror=()=>{
  if(status){status.textContent='Could not read the selected JSON file.';status.style.color='var(--red)';}
  meterCcssCreateUpdateStartState();
 };
 reader.readAsText(file);
}

function meterCcssCreateSelectedMeter(){
 const selected=meterFindByPort(meterSelectedProfilingPort());
 const references=meterCcssCreateReferenceMeters();
 if(selected&&references.includes(selected)) return selected;
 return references[0]||null;
}

function meterCcssCreateSyncHighResolution(){
 const checkbox=document.getElementById('meterCcssCreateHighResolution');
 const help=document.getElementById('meterCcssCreateHighResolutionHelp');
 if(!checkbox) return false;
 const needsReference=meterCcssCreateFormatValue()==='ccss'||meterCcssCreateMethodValue()==='measure';
 const meter=needsReference&&meterCcssCreateInventoryReady?meterCcssCreateSelectedMeter():null;
 const supported=!!(meter&&meterSupportsHighResolutionSpectrum(meter));
 checkbox.disabled=!supported||meterCcssCreateJobActive;
 if(!supported) checkbox.checked=false;
 if(help){
  if(!needsReference) help.textContent='High-resolution sampling is not used when creating a CCMX from a supplied matrix.';
  else if(!meterCcssCreateInventoryReady) help.textContent='Checking whether the selected reference meter supports high-resolution spectral sampling.';
  else if(!meter) help.textContent='Select a compatible reference spectrophotometer to enable approximately 3.3 nm reconstructed spectral sampling.';
  else if(supported) help.textContent='Supported by '+meterOptionLabel(meter)+'. Uses approximately 3.3 nm reconstructed sampling and may not improve absolute colorimetric accuracy.';
  else help.textContent=meterOptionLabel(meter)+' does not support ArgyllCMS high-resolution spectral mode.';
 }
 return supported;
}

function meterCcssCreateSelectedTarget(){
 const referencePort=meterNormalizePortValue(meterCcssCreateSelectedMeter()&&meterCcssCreateSelectedMeter().port_num);
 const selected=meterFindByPort(meterCcssCreateTargetPort);
 if(selected&&meterIsColorimeter(selected)&&meterNormalizePortValue(selected.port_num)!==referencePort) return selected;
 const current=meterFindByPort(meterSelectedMeasurementPort());
 if(current&&meterIsColorimeter(current)&&meterNormalizePortValue(current.port_num)!==referencePort) return current;
 return meterCcssCreateColorimeters().find(meter=>meterNormalizePortValue(meter.port_num)!==referencePort)||null;
}

function meterCcssCreateFormatChanged(){
 meterCcssCreateFormatValue();
 meterRenderCcssCreateChoices();
 meterCcssCreateUpdateCopy();
 meterCcssCreateUpdateStartState();
}

function meterCcssCreateUpdateCopy(){
 const mode=meterCcssCreateFormatValue();
 const method=meterCcssCreateMethodValue();
 const intro=document.getElementById('meterCcssCreateIntro');
 const help=document.getElementById('meterCcssCreateFormatHelp');
 const displayHelp=document.getElementById('meterCcssCreateDisplayHelp');
 const targetSection=document.getElementById('meterCcssCreateTargetSection');
 const methodSection=document.getElementById('meterCcssCreateMethodSection');
 const methodHelp=document.getElementById('meterCcssCreateMethodHelp');
 const referenceSection=document.getElementById('meterCcssCreateReferenceSection');
 const matrixSection=document.getElementById('meterCcssCreateMatrixSection');
 const jsonSection=document.getElementById('meterCcssCreateJsonSection');
 const suppliedMatrix=mode==='ccmx'&&method!=='measure';
 if(intro) intro.textContent=mode==='ccmx'
  ? (method==='measure'
    ? 'Creates a correction matrix by measuring the same display patches with a reference meter and the colorimeter being corrected. The reference may be a spectrophotometer or another colorimeter. Follow each setup prompt and keep both meters connected.'
    : 'Creates a standard ArgyllCMS CCMX profile from a supplied 3x3 XYZ correction matrix and associates it with the selected target colorimeter.')
  : 'Creates spectral display correction data from a reference spectrophotometer. Follow the setup prompts to calibrate the spectro, aim it at the display, and measure the patch set.';
 if(help) help.textContent=mode==='ccmx'
  ? (method==='measure'
    ? 'A CCMX is a small matrix made for one colorimeter model or unit on this specific display. It corrects that colorimeter to agree with the selected reference meter and is not a general display spectral profile.'
    : 'A CCMX is an ArgyllCMS meter profile containing a 3x3 XYZ correction matrix. The selected colorimeter and display technology are stored with the supplied matrix.')
  : 'A CCSS stores the display spectrum. Compatible colorimeters use that spectral data with their own sensor characteristics, so a CCSS can be shared across supported meter units measuring the same display technology.';
 if(displayHelp) displayHelp.textContent=mode==='ccmx'
  ? (method==='measure'
    ? 'This identifies the display technology in the CCMX. The target colorimeter is measured in its uncorrected base mode so the new matrix is not stacked on another profile.'
    : 'This identifies the display technology in the CCMX metadata. It does not alter the supplied matrix values.')
  : 'This sets the ccxxmake display technology used to build the new CCSS.';
 if(methodHelp) methodHelp.textContent=method==='measure'
  ? 'Measures both meters and calculates the correction matrix from their XYZ results.'
  : (method==='json'
    ? 'Imports the JSON format exported by the former software XYZ Correction Matrix tool and converts it into a meter profile.'
    : 'Enter the matrix values directly. PGenerator+ will package them as a CCMX that ArgyllCMS applies to the selected meter.');
 if(methodSection) methodSection.style.display=mode==='ccmx'?'':'none';
 if(referenceSection) referenceSection.style.display=suppliedMatrix?'none':'';
 if(targetSection) targetSection.style.display=mode==='ccmx'?'':'none';
 if(matrixSection) matrixSection.style.display=suppliedMatrix?'':'none';
 if(jsonSection) jsonSection.style.display=suppliedMatrix&&method==='json'?'':'none';
}

function meterCcssCreateDisplayTypeValue(){
 const createSel=document.getElementById('meterCcssCreateDisplayType');
 const createValue=String((createSel&&createSel.value)||'').trim();
 if(createValue){
  meterCcssCreateDisplayType=createValue;
  return createValue;
 }
 if(meterCcssCreateDisplayType) return meterCcssCreateDisplayType;
 const sel=document.getElementById('meterDisplayType');
 let value=String((sel&&sel.value)||'');
 if(value==='custom_editor') value=String((sel&&sel.dataset.lastStableValue)||'lcd');
 return value;
}

function meterCcssCreateCanStart(){
 return meterCcssCreateStartBlockReason()==='';
}

function meterCcssCreateStartBlockReason(){
 const mode=meterCcssCreateFormatValue();
 const method=meterCcssCreateMethodValue();
 const needsReference=mode==='ccss'||method==='measure';
 if(!meterCcssCreateInventoryReady) return needsReference?'Checking for a ready reference meter.':'Checking for a ready colorimeter.';
 if(needsReference&&!meterCcssCreateSelectedMeter()) return mode==='ccss'?'Connect and select a reference spectrophotometer.':'Connect and select a reference meter.';
 if(mode==='ccmx'&&!meterCcssCreateSelectedTarget()) return 'Connect and select the target colorimeter.';
 if(mode==='ccmx'&&method==='json'&&!meterCcssCreateJsonLoaded) return 'Choose a valid XYZ correction matrix JSON file.';
 if(mode==='ccmx'&&method!=='measure'){
  try{ meterCcssCreateReadMatrix(); }catch(e){ return e.message||'Enter a valid 3x3 correction matrix.'; }
 }
 const nameInput=document.getElementById('meterCcssCreateName');
 if(!String((nameInput&&nameInput.value)||'').trim()) return 'Enter a profile name.';
 if(!meterCcssCreateDisplayTypeValue()) return 'Choose a display technology.';
 if(needsReference&&typeof hasUnsavedSettings==='function'&&hasUnsavedSettings()) return 'Apply & Restart before creating the profile.';
 if(meterActionPending||meterSeriesRunning||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning) return 'Wait for the current meter operation to finish.';
 return '';
}

function meterCcssCreateUpdateStartState(clearStaleMessage){
 const startBtn=document.getElementById('meterCcssCreateStartBtn');
 if(!startBtn) return;
 const startHint=document.getElementById('meterCcssCreateStartBtnHint');
 const progress=document.getElementById('meterCcssCreateProgress');
 const reason=meterCcssCreateStartBlockReason();
 const supplied=meterCcssCreateFormatValue()==='ccmx'&&meterCcssCreateMethodValue()!=='measure';
 if(!startBtn.dataset.starting) startBtn.textContent=supplied?'Create CCMX':'Start Creation';
 startBtn.disabled=reason!=='';
 startBtn.title=reason?'':(supplied?'Create the CCMX profile':'Start meter profile creation');
 if(startHint){
  const explanation=reason||(supplied?'Create the CCMX profile':'Start meter profile creation');
  startHint.title=explanation;
  startHint.dataset.tooltip=startBtn.disabled?explanation:'';
  startHint.setAttribute('aria-label',explanation);
 }
 if(clearStaleMessage&&progress&&!meterCcssCreateJobActive&&!startBtn.dataset.starting){
  progress.textContent=reason||'Ready to start meter profile creation.';
  delete progress.dataset.starting;
 }
}

function meterCcssCreateSetStartingFeedback(starting,format){
 const startBtn=document.getElementById('meterCcssCreateStartBtn');
 const startHint=document.getElementById('meterCcssCreateStartBtnHint');
 const progress=document.getElementById('meterCcssCreateProgress');
 const highResolutionInput=document.getElementById('meterCcssCreateHighResolution');
 if(highResolutionInput){
  if(starting) highResolutionInput.disabled=true;
  else meterCcssCreateSyncHighResolution();
 }
 if(startBtn){
  const supplied=meterCcssCreateFormatValue()==='ccmx'&&meterCcssCreateMethodValue()!=='measure';
  startBtn.textContent=starting?'Starting...':(supplied?'Create CCMX':'Start Creation');
  if(starting){
   startBtn.dataset.starting='1';
   startBtn.disabled=true;
   startBtn.title='';
   if(startHint){
    startHint.title='Starting meter profile creation';
    startHint.dataset.tooltip='Starting meter profile creation';
    startHint.setAttribute('aria-label','Starting meter profile creation');
   }
  }else{
   delete startBtn.dataset.starting;
   meterCcssCreateUpdateStartState();
  }
 }
 if(progress&&starting){
  const profileType=String(format||meterCcssCreateFormatValue()||'ccss').toUpperCase();
  progress.textContent='Starting '+profileType+' creation...';
  progress.dataset.starting='1';
 }else if(progress&&progress.dataset.starting==='1'){
  progress.textContent='Select a profile type and the required meter or meters, then start.';
  delete progress.dataset.starting;
 }
}

function meterCcssCreateSetUi(status){
 const progress=document.getElementById('meterCcssCreateProgress');
 const startBtn=document.getElementById('meterCcssCreateStartBtn');
 const stopBtn=document.getElementById('meterCcssCreateStopBtn');
 const nameInput=document.getElementById('meterCcssCreateName');
 const displayTypeSel=document.getElementById('meterCcssCreateDisplayType');
 const formatSel=document.getElementById('meterCcssCreateFormat');
 const methodSel=document.getElementById('meterCcssCreateMethod');
 const jsonInput=document.getElementById('meterCcssCreateJsonInput');
 const highResolutionInput=document.getElementById('meterCcssCreateHighResolution');
 const running=!!(status&&(status.status==='starting'||status.status==='running'));
 if(progress&&status&&status.message){
  // Show only our curated message. status.detail carries the raw ccxxmake
  // output for the log/diagnostics and must NOT be surfaced to the operator.
  progress.textContent=status.message;
  delete progress.dataset.starting;
 }
 if(startBtn){ delete startBtn.dataset.starting; startBtn.style.display=running?'none':''; meterCcssCreateUpdateStartState(); }
 if(stopBtn) stopBtn.style.display=running?'':'none';
 // The action button is driven by meterCcssCreateRefreshStatus for setup steps;
 // for any non-setup status (handled here) keep it hidden.
 const continueBtn=document.getElementById('meterCcssCreateContinueBtn');
 if(continueBtn) continueBtn.style.display='none';
 if(nameInput) nameInput.disabled=running;
 if(displayTypeSel) displayTypeSel.disabled=running;
 if(formatSel) formatSel.disabled=running;
 if(methodSel) methodSel.disabled=running;
 if(jsonInput) jsonInput.disabled=running;
 if(highResolutionInput) highResolutionInput.disabled=running||!meterCcssCreateSyncHighResolution();
 METER_CCMX_MATRIX_IDS.forEach(row=>row.forEach(id=>{const el=document.getElementById(id);if(el) el.disabled=running;}));
}

let meterCcssSetupStepId=0;
async function meterCcssCreateSetupAck(){
 // Acks the current calibrate/aim step for the in-modal CCSS wizard.
 const btn=document.getElementById('meterCcssCreateContinueBtn');
 const id=meterCcssSetupStepId;
 if(!id) return;
 if(btn) btn.disabled=true;
 const r=await fetchJSON('/api/ccss/create/setup/ack',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({step_id:id}),_timeoutMs:5000});
 if(!r||r.status==='error'){ if(btn) btn.disabled=false; toast(r&&r.message?r.message:'Could not continue',true); }
 // The next status poll re-labels or hides the button as the step advances.
}

function meterRenderCcssCreateChoices(){
 const wrap=document.getElementById('meterCcssCreateChoices');
 const status=document.getElementById('meterCcssCreateStatus');
 const targetWrap=document.getElementById('meterCcssCreateTargetChoices');
 const targetStatus=document.getElementById('meterCcssCreateTargetStatus');
 if(!wrap||!status) return;
 const mode=meterCcssCreateFormatValue();
 const method=meterCcssCreateMethodValue();
 const needsReference=mode==='ccss'||method==='measure';
 meterCcssCreateSyncHighResolution();
 const referenceLabel=document.getElementById('meterCcssCreateReferenceLabel');
 if(referenceLabel) referenceLabel.textContent=mode==='ccss'?'Reference Spectrophotometer':'Reference Meter';
 if(!meterCcssCreateInventoryReady){
  wrap.innerHTML='';
  status.textContent=needsReference?'Checking connected reference meters...':'No reference meter is required for a supplied matrix.';
  if(targetWrap) targetWrap.innerHTML='';
  if(targetStatus) targetStatus.textContent=mode==='ccmx'?'Checking connected colorimeters...':'';
  meterCcssCreateUpdateStartState();
  return;
 }
 const references=meterCcssCreateReferenceMeters();
 const colorimeters=meterCcssCreateColorimeters();
 const selected=meterSelectedProfilingPort();
 if(!meterInventory||meterInventory.length===0){
  wrap.innerHTML='';
  status.textContent=needsReference
   ? 'No supported meter detected. Connect the required meter or meters, then reopen this creator.'
   : 'No supported colorimeter detected. Connect the meter that this matrix will correct.';
  if(targetWrap) targetWrap.innerHTML='';
  if(targetStatus) targetStatus.textContent=mode==='ccmx'?'A CCMX also requires a target colorimeter.':'';
  meterCcssCreateUpdateStartState();
  return;
 }
 if(needsReference&&!references.length){
  wrap.innerHTML='';
  status.textContent=mode==='ccss'
   ? 'No spectrophotometer detected. Connect the reference spectro you want to use.'
   : 'No reference meter detected. Connect the meter you want to use as the reference.';
  if(targetWrap) targetWrap.innerHTML='';
  if(targetStatus&&mode==='ccmx') targetStatus.textContent=colorimeters.length?'Select a reference meter before starting.':'No target colorimeter detected.';
  meterCcssCreateUpdateStartState();
  return;
 }
 if(!needsReference){
  wrap.innerHTML='';
  status.textContent='No reference meter is required for a supplied matrix.';
 }
 const selectedMeter=selected&&meterFindByPort(selected);
 const chosen=(selectedMeter&&references.includes(selectedMeter))?selectedMeter:(references[0]||null);
 if(needsReference&&chosen) meterProfilingPort=meterNormalizePortValue(chosen.port_num);
 if(needsReference&&references.length>1){
  status.textContent=chosen?('Reference: '+meterOptionLabel(chosen)+'. Tap another to switch.'):'Select the reference meter.';
 }else if(needsReference&&chosen){
  status.textContent='Selected reference: '+meterOptionLabel(chosen)+'.';
 }else if(needsReference) {
  status.textContent='Choose the reference meter.';
 }
 if(needsReference) wrap.innerHTML=references.map(meter=>{
  const port=meterNormalizePortValue(meter.port_num);
  const active=meterProfilingPort===port;
  return '<button class="btn btn-sm '+(active?'btn-success':'btn-secondary')+'" style="text-align:left;justify-content:flex-start;padding:8px 10px" onclick="meterChooseCcssCreationMeter(\''+port+'\')">'+(active?'\u2713 ':'')+meterOptionLabel(meter)+'</button>';
 }).join('');
 if(mode==='ccmx'&&targetWrap&&targetStatus){
  const chosenTarget=meterCcssCreateSelectedTarget();
  if(chosenTarget) meterCcssCreateTargetPort=meterNormalizePortValue(chosenTarget.port_num);
  const referencePort=meterNormalizePortValue(chosen&&chosen.port_num);
  const targetMeters=colorimeters.filter(meter=>meterNormalizePortValue(meter.port_num)!==referencePort);
  targetWrap.innerHTML=targetMeters.map(meter=>{
   const port=meterNormalizePortValue(meter.port_num);
   const active=meterCcssCreateTargetPort===port;
   return '<button class="btn btn-sm '+(active?'btn-success':'btn-secondary')+'" style="text-align:left;justify-content:flex-start;padding:8px 10px" onclick="meterChooseCcssCreationTarget(\''+port+'\')">'+(active?'\u2713 ':'')+meterOptionLabel(meter)+'</button>';
  }).join('');
  targetStatus.textContent=chosenTarget
   ? 'Selected target: '+meterOptionLabel(chosenTarget)+'. The finished CCMX will be selected for this meter.'
   : 'No colorimeter detected. Connect the colorimeter that this matrix will correct.';
 }
 meterCcssCreateSyncHighResolution();
 meterCcssCreateUpdateStartState();
}

// Fixed modals that live under .dashboard get trapped under the AutoCal mask
// because body.meter-autocal-active dims/filters the whole dashboard (stacking
// context). Reparent to document.body before show so z-index can win.
function meterEnsureModalOnBody(modal){
 if(!modal||!document.body) return modal;
 if(modal.parentElement!==document.body) document.body.appendChild(modal);
 return modal;
}

function meterOpenCcssCreateModal(){
 meterCloseCustomCcssEditor();
 const modal=meterEnsureModalOnBody(document.getElementById('meterCcssCreateModal'));
 if(!modal) return;
 meterCcssCreateFreshOpen=true;
 meterCcssCreateInventoryReady=false;
 meterCcssCreateJobActive=false;
 meterCcssCreateJsonLoaded=false;
 meterCcssSetupStepId=0;
 meterCcssCreateHandledToken='';
 const progress=document.getElementById('meterCcssCreateProgress');
 if(progress) progress.textContent='Select a profile type and the required meter or meters, then start.';
 const continueBtn=document.getElementById('meterCcssCreateContinueBtn');
 if(continueBtn) continueBtn.style.display='none';
 const stopBtn=document.getElementById('meterCcssCreateStopBtn');
 if(stopBtn) stopBtn.style.display='none';
 const createSel=document.getElementById('meterCcssCreateDisplayType');
 if(createSel){
  const preferred=String(meterCcssCreateDisplayType||'').trim();
  const mainSel=document.getElementById('meterDisplayType');
  const stable=String((mainSel&&(mainSel.dataset.lastStableValue||mainSel.value))||'').trim();
  const fallback=preferred||stable||'oled_generic';
  const hasChoice=fallback&&Array.from(createSel.options).some(opt=>opt.value===fallback);
  createSel.value=hasChoice?fallback:'oled_generic';
  meterCcssCreateDisplayType=createSel.value;
 }
 const formatSel=document.getElementById('meterCcssCreateFormat');
 if(formatSel) formatSel.value=meterCcssCreateFormat==='ccmx'?'ccmx':'ccss';
 const methodSel=document.getElementById('meterCcssCreateMethod');
 if(methodSel) methodSel.value=/^(?:json|manual)$/.test(meterCcssCreateMethod)?meterCcssCreateMethod:'measure';
 const jsonInput=document.getElementById('meterCcssCreateJsonInput');
 if(jsonInput) jsonInput.value='';
 const jsonStatus=document.getElementById('meterCcssCreateJsonStatus');
 if(jsonStatus){
  jsonStatus.textContent='Choose a JSON file exported by the former PGenerator+ XYZ Correction Matrix tool.';
  jsonStatus.style.color='var(--text2)';
 }
 meterCcssCreateSetMatrix([[1,0,0],[0,1,0],[0,0,1]]);
 meterCcssCreateUpdateCopy();
 meterRenderCcssCreateChoices();
 modal.style.display='flex';
 uiSyncBodyScrollLock();
 Promise.resolve(meterCheckStatus()).finally(()=>{
  if(modal.style.display==='flex'&&!meterCcssCreateInventoryReady){
   const status=document.getElementById('meterCcssCreateStatus');
   const needsReference=meterCcssCreateFormatValue()==='ccss'||meterCcssCreateMethodValue()==='measure';
   if(status) status.textContent=needsReference
    ? 'Could not confirm that the reference meter is ready. Check the connection and reopen this window.'
    : 'Could not confirm that the target colorimeter is ready. Check the connection and reopen this window.';
   meterCcssCreateUpdateStartState();
  }
 });
 meterCcssCreateRefreshStatus(true);
 if(meterCcssCreatePolling) clearInterval(meterCcssCreatePolling);
 meterCcssCreatePolling=setInterval(()=>meterCcssCreateRefreshStatus(true),2000);
}

function meterCloseCcssCreateModal(restoreSelection){
 const modal=document.getElementById('meterCcssCreateModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
 const _wasRunning=meterCcssCreateJobActive;
 if(meterCcssCreatePolling){clearInterval(meterCcssCreatePolling);meterCcssCreatePolling=null;}
 // If a CCSS job was in progress, closing the window must stop it -- otherwise it
 // keeps running (e.g. parked at a wizard step), holds the meter, and blocks every
 // subsequent read via the "busy creating a CCSS" guard.
 if(_wasRunning){ try{ fetchJSON('/api/ccss/create/stop',{method:'POST',_quiet:true,_timeoutMs:5000}); }catch(e){} }
 meterCcssCreateJobActive=false;
 if(restoreSelection){
  const sel=document.getElementById('meterDisplayType');
  if(sel){
   const stable=sel.dataset.lastStableValue||'lcd';
   sel.value=stable;
  }
 }
}

function meterChooseCcssCreationMeter(port){
 const normalized=meterNormalizePortValue(port);
 if(!normalized) return;
 meterProfilingPort=normalized;
 meterRenderCcssCreateChoices();
 saveMeterSettings();
 const chosen=meterFindByPort(normalized);
 if(chosen) toast('Reference meter: '+meterOptionLabel(chosen));
 else toast('Reference meter selected');
}

function meterChooseCcssCreationTarget(port){
 const normalized=meterNormalizePortValue(port);
 const chosen=meterFindByPort(normalized);
 if(!chosen||!meterIsColorimeter(chosen)) return;
 meterCcssCreateTargetPort=normalized;
 meterRenderCcssCreateChoices();
 toast('Target colorimeter: '+meterOptionLabel(chosen));
}

async function meterCcssCreateRefreshStatus(quiet){
 const progress=document.getElementById('meterCcssCreateProgress');
 const r=await fetchJSON('/api/ccss/create/status',{_quiet:true,_timeoutMs:5000});
 if(!r){
  if(progress&&!quiet) progress.textContent='Unable to load meter profile creation status.';
  return null;
 }
 // Meter profile creation runs entirely inside THIS modal, never the separate shared wizard
 // popup (that one is only for meter reads). One popup, one theme: the
 // calibrate/aim steps and the working messages all render here.
 meterSpectroSetupApply(null);
 const contBtn=document.getElementById('meterCcssCreateContinueBtn');
 const activeStatus=r.status==='starting'||r.status==='running'||r.status==='setup';
 meterCcssCreateJobActive=activeStatus;
 if(meterCcssCreateFreshOpen&&!activeStatus){
  meterCcssCreateSetUi({status:'idle'});
  return r;
 }
 if(activeStatus) meterCcssCreateFreshOpen=false;
 if(r.status==='setup'){
  meterCcssSetupStepId=Number(r.step_id)||0;
  if(progress){ progress.textContent=r.message||''; delete progress.dataset.starting; }
  if(contBtn){ contBtn.textContent=meterSpectroSetupLabel(r.step||''); contBtn.style.display=''; contBtn.disabled=false; }
  const sBtn=document.getElementById('meterCcssCreateStartBtn'); if(sBtn) sBtn.style.display='none';
  const stBtn=document.getElementById('meterCcssCreateStopBtn'); if(stBtn) stBtn.style.display='';
  return r;
 }
 if(contBtn) contBtn.style.display='none';
 meterCcssCreateSetUi(r);
 const token=[r.status||'',r.filename||'',r.message||''].join('|');
 if(r.status==='complete'&&token!==meterCcssCreateHandledToken){
  meterCcssCreateHandledToken=token;
  if(r.filename){
   if(String(r.format||'').toLowerCase()==='ccmx'&&meterNormalizePortValue(r.target_port)){
    const targetPort=meterNormalizePortValue(r.target_port);
    const meterSelect=document.getElementById('meterMeasurementPort');
    if(meterSelect&&Array.from(meterSelect.options).some(opt=>meterNormalizePortValue(opt.value)===targetPort)){
     meterSelect.value=targetPort;
     meterMeasurementPort=targetPort;
     meterSavedMeasurementPort=targetPort;
     meterResolvedMeasurementPort=targetPort;
     meterSelect.dispatchEvent(new Event('change',{bubbles:true}));
    }
   }
   await refreshMeterCcssCatalog();
   meterSetCcssProfileSelection('custom_'+r.filename);
   await loadCustomCcssList();
   await ccssPreviewLoadByValue('custom\t'+r.filename,false);
   saveMeterSettings();
  }
  if(!quiet) toast(r.message||'Meter profile created');
 }
 if(!quiet&&r.status==='error') toast(r.message||'Meter profile creation failed',true);
 if(!quiet&&r.status==='cancelled') toast(r.message||'Meter profile creation cancelled');
 return r;
}

function meterCcmxHeaderValue(value){
 return String(value==null?'':value).replace(/[\x00-\x1f\x7f"]/g,' ').replace(/\s+/g,' ').trim();
}

function meterCcmxInstrumentName(meter){
 const name=String((meter&&meter.name)||'').toLowerCase();
 const usb=String((meter&&meter.usb_id)||'').toLowerCase();
 if(usb==='085c:0a00'||/\bspyder\s*x\b/.test(name)) return 'Datacolor SpyderX';
 if(/\bspyder\s*5\b/.test(name)) return 'Datacolor Spyder5';
 if(/i1\s*display|i1display|display\s*pro|colormunki\s*display|colorchecker\s*display|c6/.test(name)) return 'X-Rite i1 DisplayPro, ColorMunki Display';
 return meterCcmxHeaderValue((meter&&meter.name)||'Colorimeter');
}

function meterCcmxTechnologyName(key){
 return {
  oled_generic:'LED WOLED',
  oled:'LED OLED',
  qdoled:'LED OLED',
  amoled:'LED AMOLED',
  lcd:'LCD',
  lcd_ccfl:'LCD CCFL',
  lcd_ccfl_ips:'LCD CCFL IPS',
  lcd_ccfl_pva:'LCD CCFL PVA',
  lcd_ccfl_tft:'LCD CCFL TFT',
  lcd_wgccfl:'LCD CCFL Wide Gamut',
  lcd_wgccfl_ips:'LCD CCFL Wide Gamut IPS',
  lcd_wgccfl_pva:'LCD CCFL Wide Gamut PVA',
  lcd_wgccfl_tft:'LCD CCFL Wide Gamut TFT',
  lcd_wled:'LCD White LED',
  lcd_wled_ips:'LCD White LED IPS',
  lcd_wled_pva:'LCD White LED PVA',
  lcd_wled_tft:'LCD White LED TFT',
  lcd_rgbled:'LCD RGB LED',
  lcd_rgbled_ips:'LCD RGB LED IPS',
  lcd_rgbled_pva:'LCD RGB LED PVA',
  lcd_rgbled_tft:'LCD RGB LED TFT',
  lcd_rgphosphor:'LCD RG Phosphor',
  lcd_rgphosphor_ips:'LCD RG Phosphor IPS',
  lcd_rgphosphor_pva:'LCD RG Phosphor PVA',
  lcd_rgphosphor_tft:'LCD RG Phosphor TFT',
  lcd_pfsphosphor:'LCD PFS Phosphor',
  lcd_pfsphosphor_ips:'LCD PFS Phosphor IPS',
  lcd_pfsphosphor_pva:'LCD PFS Phosphor PVA',
  lcd_pfsphosphor_tft:'LCD PFS Phosphor TFT',
  lcd_gbled:'LCD GB-R Phosphor',
  lcd_gbled_ips:'LCD GB-R Phosphor IPS',
  lcd_gbled_pva:'LCD GB-R Phosphor PVA',
  lcd_gbled_tft:'LCD GB-R Phosphor TFT',
  plasma:'Plasma',
  projector_ccss:'DLP Projector',
  projector_rgb:'DLP Projector RGB Filter Wheel',
  projector_rgbw:'DLP Projector RGBW Filter Wheel',
  projector_rgbcmy:'DLP Projector RGBCMY Filter Wheel',
  crt:'CRT',
  unknown:'Unknown'
 }[String(key||'')]||meterCcmxHeaderValue(key)||'Unknown';
}

function meterBuildCcmxContent(name,target,matrix,displayType,method){
 const rows=matrix.map(row=>row.map(value=>Number(value).toPrecision(12).replace(/(?:\.0+|(\.\d+?)0+)$/,'$1')).join(' '));
 const reference=method==='json'?'Imported PGenerator+ XYZ correction matrix':'User entered 3x3 XYZ correction matrix';
 const refresh=/^(?:plasma|crt)$/.test(String(displayType||''))?'YES':'NO';
 return [
  'CCMX',
  '',
  'DESCRIPTOR "'+meterCcmxHeaderValue(name)+'"',
  'INSTRUMENT "'+meterCcmxInstrumentName(target)+'"',
  'DISPLAY "'+meterCcmxHeaderValue(name)+'"',
  'TECHNOLOGY "'+meterCcmxTechnologyName(displayType)+'"',
  'DISPLAY_TYPE_BASE_ID "1"',
  'DISPLAY_TYPE_REFRESH "'+refresh+'"',
  'REFERENCE "'+reference+'"',
  'ORIGINATOR "PGenerator+"',
  'CREATED "'+new Date().toUTCString()+'"',
  'COLOR_REP "XYZ"',
  '',
  'NUMBER_OF_FIELDS 3',
  'BEGIN_DATA_FORMAT',
  'XYZ_X XYZ_Y XYZ_Z',
  'END_DATA_FORMAT',
  '',
  'NUMBER_OF_SETS 3',
  'BEGIN_DATA',
  ...rows,
  'END_DATA',
  ''
 ].join('\n');
}

function meterBase64Utf8(text){
 const bytes=new TextEncoder().encode(String(text||''));
 let binary='';
 for(let i=0;i<bytes.length;i+=8192) binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
 return btoa(binary);
}

async function meterSelectCreatedCcmxForTarget(filename,target){
 const targetPort=meterNormalizePortValue(target&&target.port_num);
 const meterSelect=document.getElementById('meterMeasurementPort');
 if(targetPort&&meterSelect&&Array.from(meterSelect.options).some(opt=>meterNormalizePortValue(opt.value)===targetPort)){
  meterSelect.value=targetPort;
  meterMeasurementPort=targetPort;
  meterSavedMeasurementPort=targetPort;
  meterResolvedMeasurementPort=targetPort;
  meterSelect.dispatchEvent(new Event('change',{bubbles:true}));
 }
 await refreshMeterCcssCatalog();
 const selected=meterSetCcssProfileSelection('custom_'+filename);
 await loadCustomCcssList();
 await ccssPreviewLoadByValue('custom\t'+filename,false);
 saveMeterSettings();
 return selected;
}

async function meterCreateCcmxFromSuppliedMatrix(name,target,matrix,displayType,method){
 const content=meterBuildCcmxContent(name,target,matrix,displayType,method);
 const r=await fetchJSON('/api/ccss/upload',{
  method:'POST',
  headers:{'Content-Type':'application/json'},
  body:JSON.stringify({
   name:name,
   content:meterBase64Utf8(content),
   filename:name+'.ccmx',
   display_type:displayType
  }),
  _timeoutMs:15000
 });
 if(!r||r.status!=='ok') throw new Error(r&&r.message?r.message:'Failed to create CCMX profile');
 const selected=await meterSelectCreatedCcmxForTarget(r.filename,target);
 return {response:r,selected:selected};
}

async function meterStartCcssCreate(){
 if(meterActionPending){toast('Meter operation already in progress',true);return;}
 const initialFormat=meterCcssCreateFormatValue();
 meterCcssCreateSetStartingFeedback(true,initialFormat);
 // Stop any continuous read loop first. Otherwise it keeps re-POSTing reads,
 // which restarts the spotread session and re-claims the instrument -- ccxxmake
 // then fails with "Instrument Access Failed" because the meter is still held.
 // (The backend webui_ccss_create_start also frees the session before launch.)
 meterStopContinuous();
 meterCcssCreateInventoryReady=false;
 await meterCheckStatus();
 meterRenderCcssCreateChoices();
 const blocked=meterCcssCreateStartBlockReason();
 if(blocked){meterCcssCreateSetStartingFeedback(false);toast(blocked,true);return;}
 const format=meterCcssCreateFormatValue();
 const method=meterCcssCreateMethodValue();
 const target=format==='ccmx'?meterCcssCreateSelectedTarget():null;
 if(format==='ccmx'&&!target){meterCcssCreateSetStartingFeedback(false);toast('No target colorimeter selected',true);return;}
 const nameInput=document.getElementById('meterCcssCreateName');
 const name=String((nameInput&&nameInput.value)||'').trim();
 if(!name){meterCcssCreateSetStartingFeedback(false);toast('Enter a profile name',true);return;}
 const displayType=meterCcssCreateDisplayTypeValue();
 if(!displayType){meterCcssCreateSetStartingFeedback(false);toast('Choose a display technology',true);return;}
 if(format==='ccmx'&&method!=='measure'){
  meterActionPending=true;
  try{
   const matrix=meterCcssCreateReadMatrix();
   const result=await meterCreateCcmxFromSuppliedMatrix(name,target,matrix,displayType,method);
   const progress=document.getElementById('meterCcssCreateProgress');
   if(progress){
    progress.textContent=result.selected
     ? 'CCMX profile created and selected for '+meterOptionLabel(target)+'.'
     : 'CCMX profile created, but it could not be selected for '+meterOptionLabel(target)+'.';
    delete progress.dataset.starting;
   }
   toast(result.selected?'CCMX profile created and selected':'CCMX profile created');
  }catch(e){
   const message=e&&e.message?e.message:'Failed to create CCMX profile';
   const progress=document.getElementById('meterCcssCreateProgress');
   if(progress){progress.textContent=message;delete progress.dataset.starting;}
   toast(message,true);
  }finally{
   meterActionPending=false;
   meterCcssCreateSetStartingFeedback(false);
  }
  return;
 }
 const references=meterCcssCreateReferenceMeters();
 if(!references.length){meterCcssCreateSetStartingFeedback(false);toast(format==='ccss'?'Connect a spectrophotometer first':'Connect a reference meter first',true);return;}
 const meter=meterCcssCreateSelectedMeter();
 if(!meter){meterCcssCreateSetStartingFeedback(false);toast('No reference meter selected',true);return;}
 if(!meterEnsureAppliedGeneratorSettings()){meterCcssCreateSetStartingFeedback(false);return;}
 meterCcssCreateFreshOpen=false;
 meterCcssCreateJobActive=true;
 meterActionPending=true;
 meterCcssCreateSetStartingFeedback(true,format);
 try{
  const highResolutionInput=document.getElementById('meterCcssCreateHighResolution');
  const highResolution=!!(highResolutionInput&&highResolutionInput.checked&&meterSupportsHighResolutionSpectrum(meter));
  const r=await fetchJSON('/api/ccss/create/start',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify(meterMeasurementSignalContext({name:name,format:format,display_type:displayType,profiling_meter_port:meterNormalizePortValue(meter.port_num),target_meter_port:target?meterNormalizePortValue(target.port_num):'',high_resolution:highResolution,patch_size:getMeterPatchSize(),refresh_rate:getMeterRefreshRate()||undefined})),_timeoutMs:10000});
  if(!r||r.status==='error'){
   meterCcssCreateJobActive=false;
   meterCcssCreateSetUi(r||{status:'error',message:'Failed to start meter profile creation'});
   toast(r&&r.message?r.message:'Failed to start meter profile creation',true);
   return;
  }
  if(meterCcssCreatePolling) clearInterval(meterCcssCreatePolling);
  meterCcssCreatePolling=setInterval(()=>meterCcssCreateRefreshStatus(true),2000);
  await meterCcssCreateRefreshStatus(false);
 }finally{
  meterActionPending=false;
  meterCcssCreateSetStartingFeedback(false);
 }
}

async function meterStopCcssCreate(){
 const r=await fetchJSON('/api/ccss/create/stop',{method:'POST',_timeoutMs:5000});
 if(!r||r.status!=='ok'){
  toast(r&&r.message?r.message:'Failed to stop meter profile creation',true);
  return;
 }
 meterCcssCreateJobActive=false;
 await meterCcssCreateRefreshStatus(false);
}

// Router that runs the selected ΔE form on a Lab pair plus optional
// luminance context (used by de2000_jnd, deitp, and the auto mode).
//   form: 'de2000' | 'de94' | 'de76lab' | 'deluv76' | 'decmc' | 'de2000_jnd' | 'deitp' | 'auto'
//   ctx:  { isGrey?: bool, Ym?: nits, Yref?: nits,
//           X,Y,Z, YWhite, Xr,Yr,Zr, YWhiteRef }   (Luv76 only uses XYZ+YWhite)
function meterDeltaE(labM,labT,form,ctx){
 form = form || 'de2000';
 ctx = ctx || {};
 if(form==='auto'){
  form = ctx.isGrey ? 'deitp' : 'de2000';
 }
 if(form==='deluv76'){
  if(ctx.X!=null && ctx.Xr!=null){
   return deltaELuvHCFR(ctx.X,ctx.Y,ctx.Z,ctx.YWhite, ctx.Xr,ctx.Yr,ctx.Zr,ctx.YWhiteRef);
  }
  // Fallback: Lab-approximated Luv76 distance when XYZ context missing.
  return deltaE76Lab(labM,labT);
 }
 if(form==='de76lab') return deltaE76Lab(labM,labT);
 if(form==='de94')    return deltaE94(labM,labT,1,1,1);
 if(form==='decmc')   return deltaECMC(labM,labT,1,1);
 if(form==='de2000_jnd') return deltaE2000JND(labM,labT,ctx.Ym||0,ctx.Yref||0);
 if(form==='deitp' && ctx.X!=null && ctx.Xr!=null){
  const X=(ctx.itpX!=null)?ctx.itpX:ctx.X;
  const Y=(ctx.itpY!=null)?ctx.itpY:ctx.Y;
  const Z=(ctx.itpZ!=null)?ctx.itpZ:ctx.Z;
  const Xr=(ctx.itpXr!=null)?ctx.itpXr:ctx.Xr;
  const Yr=(ctx.itpYr!=null)?ctx.itpYr:ctx.Yr;
  const Zr=(ctx.itpZr!=null)?ctx.itpZr:ctx.Zr;
  // SDR26 peak (Limited 109 / Full 100): chroma-only dE ITP. Peak
  // calibrates RGB balance only -- matching worker delta_e_itp_chroma_only.
  if(ctx.reading && meterReadingIsSdr26LegalPeak(ctx.reading)){
   return deltaEITPChromaOnly(X,Y,Z,Xr,Yr,Zr);
  }
  return deltaEITP(X,Y,Z,Xr,Yr,Zr);
 }
 return deltaE2000(labM,labT);
}

async function meterEnsureDetected(){
 if(meterDetected) return true;
 await meterCheckStatus();
 return !!meterDetected;
}

function syncTopStatusStack(){
 const stack=document.getElementById('meterDisplayStatusStack');
 if(!stack) return;
 const meter=document.getElementById('meterStatusWrap');
 const display=document.getElementById('lgTopStatusWrap');
 const companion=document.getElementById('iccCompanionTopStatusWrap');
 const visible=!!((meter&&meter.style.display!=='none')||(display&&display.style.display!=='none')||(companion&&companion.style.display!=='none'));
 stack.classList.toggle('active',visible);
}

function meterSyncBusyStatusDot(){
 const dot=document.getElementById('meterDot');
 if(!dot) return;
 const busy=!!(
  meterActionPending||meterSeriesRunning||meterContinuousActive||meterContinuousSuspendedForLgWrite
  ||meterContinuousReadInFlight||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning
  ||meterDvAutoCalProfileRunning||meterDvProfileStandaloneRunning||meterLgGreyBusy
  ||meterSeriesAwaitingReady||meterManualPromptAwaiting||meterReadySignalPending
  ||window._meterToneMapBusy
 );
 dot.style.background=meterDetected?(busy?'var(--orange)':'var(--green)'):'var(--text2)';
}

let _meterUsbPowerWarned=false;
// Show/hide the persistent "Meter USB Unstable" badge (and a one-shot toast on
// transition) from the /api/meter/status usb_power_warning field. The badge
// stays up while the kernel log shows meter USB link/enumeration errors so the
// operator attributes failed/garbage reads to the USB link, not the calibration.
// The server always emits usb_power_kind='link' now: the log lines driving this
// (over-current change / power cycle / -71 / -32 / "unable to enumerate") are
// signal-integrity / runtime-PM faults on the Pi's shared internal hub, not
// genuine current overloads, so we never label it "Overloaded".
function meterUpdateUsbPowerWarning(r){
 const badge=document.getElementById('meterUsbWarnBadge');
 if(!badge) return;
 const warn=!!(r&&r.usb_power_warning);
 if(warn){
  const fallback='USB link unstable - a device is not enumerating reliably. Try a different cable/port or a powered USB hub.';
  const detail=(r&&r.usb_power_detail)||fallback;
  badge.style.display='inline';
  badge.textContent='\u26a0 USB Unstable';
  badge.title=detail;
  if(!_meterUsbPowerWarned){ _meterUsbPowerWarned=true; toast(detail,true); }
 }else{
  badge.style.display='none';
  _meterUsbPowerWarned=false;
 }
}

async function meterCheckStatus(){
 // Busy guard. On a cold start (meter not yet detected in this
 // session) we still probe the meter status so the user can see the
 // connected meter without waiting for a busy flag to clear. Once the
 // meter is known, a stale busy flag from a previous tab or in-flight
 // read won't blank the status card.
 if(meterDetected && (meterContinuousActive||meterContinuousSuspendedForLgWrite||meterLgGreyBusy||meterAutoCalRunning||meterActionPending)){
  setConnectionBusyStatus('Busy');
  return;
 }

 const meterWasDetected=meterDetected;
 const r=await fetchJSON('/api/meter/status',{_quiet:true,_timeoutMs:5000});
 // A timed-out request is not a USB disconnect. Keep a previously detected
 // meter and its charts visible until the daemon explicitly reports
 // detected:false; slow auxiliary status work must not blank calibration UI.
 if(!r){
  if(meterDetected){
   document.getElementById('meterStatusWrap').style.display='';
   document.getElementById('meterDot').style.background='var(--orange)';
   document.getElementById('meterStatusText').textContent=meterLastKnownName+' (busy)';
   document.getElementById('meterStatusText').style.color='var(--text)';
   syncTopStatusStack();
  }
  return;
 }
 meterUpdateUsbPowerWarning(r);
 const busy=meterSeriesRunning||meterContinuousActive||meterAutoCalRunning||meterActionPending||meterLgGreyBusy||(typeof lgIsCommandBusy==='function'&&lgIsCommandBusy())||document.getElementById('meterDot').style.background==='var(--orange)';
 if(r&&r.detected){
  meterStatusMisses=0;
  meterDetected=true;
  meterSimulatedActive=!!r.simulated;
  pgSyncMeterDesktopWorkspaceAvailability();
  meterPopulateRoleSelects(r.meters||[],r.port_num);
  const selectedMeter=meterFindByPort(meterSelectedMeasurementPort());
    const detectedMeter=meterFindByPort(meterNormalizePortValue(r.port_num));
    meterLastKnownName=meterSelectedMeasurementLabel(selectedMeter||detectedMeter);
  document.getElementById('meterCard').style.display='';
  document.getElementById('meterStatusWrap').style.display='';
  document.getElementById('meterDot').style.background='var(--green)';
  document.getElementById('meterStatusText').textContent=meterLastKnownName;
  document.getElementById('meterStatusText').style.color='var(--text)';
  document.getElementById('meterResetRow').style.display='none';
  meterUpdateCardMode();
  meterUpdateSeriesTabUi();
  meterUpdateReadButtons();
 } else {
  meterStatusMisses++;
  // During mode switches and meter startup, a single status probe can
  // transiently fail even though the meter is still there and in use.
  if(meterDetected && (busy || meterStatusMisses < 2)){
   document.getElementById('meterCard').style.display='';
   document.getElementById('meterStatusWrap').style.display='';
   document.getElementById('meterDot').style.background=busy?'var(--orange)':'var(--green)';
   document.getElementById('meterStatusText').textContent=busy?(meterLastKnownName+' (initializing)'):meterLastKnownName;
   document.getElementById('meterStatusText').style.color='var(--text)';
   meterUpdateCardMode();
   meterUpdateSeriesTabUi();
   meterUpdateReadButtons();
  } else {
   meterDetected=false;
   meterSimulatedActive=false;
    pgSyncMeterDesktopWorkspaceAvailability();
    meterPopulateRoleSelects([]);
   // Card stays visible in Patterns mode — always show series buttons + thumbs.
   document.getElementById('meterCard').style.display='';
   document.getElementById('meterStatusWrap').style.display='';
   document.getElementById('meterDot').style.background='var(--text2)';
   document.getElementById('meterStatusText').textContent='No Meter';
   document.getElementById('meterStatusText').style.color='var(--text2)';
   meterUpdateCardMode();
   meterUpdateSeriesTabUi();
   meterUpdateReadButtons();
  }
 }
  if(typeof meterSyncStabilizationAvailability==='function') meterSyncStabilizationAvailability();
  if(meterWasDetected!==meterDetected && typeof meterRefreshStabilizationIdlePattern==='function'){
   meterRefreshStabilizationIdlePattern(false);
  }
  syncTopStatusStack();
  // Sync shared series state across browsers. First restore any browser-local
  // snapshot from the current session so a manual reread survives refresh and
  // stale backend series JSON cannot immediately overwrite it.
  // The series-status sync ALWAYS runs (not gated by !meterSeriesRunning)
  // so that when the renderer is restarted (e.g. after a mode change +
  // apply) and the server-side series was cancelled, the client's stale
  // meterSeriesRunning flag is cleared and the stop button is hidden.
  if(meterAutoCalStatusActive()) return;
  if(!meterSeriesCacheBootId) return;
  let restoredLocal=false;
  if(!meterActiveSeriesKey){
   try{ restoredLocal=!!meterRestoreLatestPersistedSeries(); }catch(e){}
  }
  const s=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:5000});
  if(s){
   // Trust the server as the source of truth: if it says the series is
   // not running, clear the local flag and hide the stop button. This
    // handles the case where the renderer was restarted and the in-flight
    // series was implicitly cancelled by the stop+start.
    const serverRunning=(s.status==='running' || s.status==='setup' || s.status==='started');
    // Between the local click and the POST response, the status endpoint can
    // still contain the previous completed series. Do not let that stale
    // terminal snapshot finish the new run before it has acquired an id.
    const localStartPending=!!(meterSeriesRunning&&meterActionPending&&!meterSharedSeriesId);
    if(!serverRunning && !localStartPending && (meterSeriesRunning || meterSeriesPolling)){
     if(meterSeriesPolling) clearInterval(meterSeriesPolling);
     meterSeriesRunning=false;
     meterSeriesBeepArmed=false;
     meterSeriesPolling=null;
     if(typeof meterApplyClearedState==='function'){
      meterApplyClearedState(false);
     }
    }
   if(s.status==='cleared'){
    if(meterSharedSeriesId || !meterActiveSeriesKey){
     meterSharedSeriesId=null;
     meterApplyClearedState(false);
    }
   } else if(!localStartPending&&meterSharedSeriesShouldRecover(s,{restoredLocal:restoredLocal})){
    meterRecoverSeries(s);
   }
  }
 }

function meterRecoverSeries(s){
 // ICC profiling owns and consumes its worker result through icc_profile.js.
 // It is not a chart-series selection and must not replace the calibration
 // workspace's active preset if another recovery caller sees the same status.
 if(meterSeriesStatusIsIccWorkflow(s)) return false;
 const recoveredChartRevision=++meterSeriesChartRevision;
 const previousSeriesKey=String(meterActiveSeriesKey||'');
 const previousScrollRatio=Number(meterGreyscaleScrollRatio)||0;
 const recoveredState=String((s&&s.status)||'').toLowerCase();
 const preserveSelection=!!(recoveredState==='complete'
  &&s&&s.series_id&&meterSharedSeriesId
  &&String(s.series_id)===String(meterSharedSeriesId)
  &&meterCurrentPatchStep);
 const previousSelectedKey=preserveSelection?meterStepNameKey(meterCurrentPatchStep):'';
 const previousSelectedName=preserveSelection?String((meterCurrentPatchStep&&meterCurrentPatchStep.name)||_selectedColorReadingName||''):'';
 const previousColorPinned=preserveSelection&&!!_colorDetailPinned;
 // Determine series type and points from series_id or the recovered steps.
 let type=String((s&&s.type)||'').toLowerCase();
 let points=Number((s&&s.points)||0)||0;
 if(!type) type='greyscale';
 if(!points) points=21;
 if(s.series_id){
  const m=s.series_id.match(/^(greyscale|colors|saturations)_/);
  if(m) type=m[1];
 }
	 const normalizePoints=(seriesType,total,steps)=>{
	  const count=Number(total||0)||0;
	  const stepCount=Array.isArray(steps)?steps.length:0;
	  // Imported workspaces use a timestamp in their cache key, but chart mode
	  // selection still needs a recognized built-in-sized point count. Keeping
	  // the timestamp as `points` makes color charts look like a custom/3D LUT
	  // series (IDs >= 900) and suppresses the ColorChecker/Sat Sweep plots.
	  if(s&&s.source_format==='hcfr-chc'){
	   if(seriesType==='colors') return 30;
	   if(seriesType==='saturations') return 24;
	   const importedBasis=count||stepCount;
	   if(importedBasis>0&&importedBasis<=2) return 2;
	   if(importedBasis>=101) return 100;
	   return importedBasis>0&&importedBasis<=11?11:21;
	  }
	  // The backend keeps the original series preset/id in `points` even when
	  // Read Selection sends only a small custom_steps subset to the worker.
	  // Preserve that identity. Inferring from total_steps turns, for example,
	  // six selected patches from a 21-point or 1024-patch series into a new
	  // 11-point series after refresh.
	  if(seriesType==='greyscale'&&(points===2||points===11||points===21||points===26||points===30||points===100||points>=1001)) return points;
	  if(seriesType==='colors'&&(points===29||points===30||points>=900)) return points;
	  if(seriesType==='saturations'&&(points===24||points===25)) return points;
	  // Preserve custom/lattice color-series ids (>=900) and custom greyscale
	  // ids (>=1001); their patch count is not a built-in point preset.
	  if(seriesType==='colors') return (points>=900)?points:((points===29||count===29||stepCount===29)?29:30);
	  if(seriesType==='saturations') return (points===25||count===25||stepCount===25||count===30||stepCount===30||count===31||stepCount===31||meterSeriesStepsHaveHcfrSaturationMarkers(steps))?25:24;
	  if(seriesType==='greyscale'&&points>=1001) return points;
	  if(seriesType==='greyscale'&&meterSeriesStepsHaveLgAutoCal26Markers(steps)) return 26;
	  const basis=count||stepCount;
	  if(basis>0&&basis<=2) return 2;
	  if(seriesType==='greyscale'&&basis===26) return 26;
	  if(basis>=101) return 100;
	  return basis>0&&basis<=11?11:21;
	 };
 // Recover steps: prefer server-provided steps, else rebuild client-side
 let steps=null;
 if(s.steps&&Array.isArray(s.steps)&&s.steps.length>0){
  steps=s.steps;
  if(type!=='greyscale'&&type!=='colors'&&type!=='saturations'){
   const allGrey=steps.every(st=>Number(st.r)===Number(st.g)&&Number(st.g)===Number(st.b));
   if(allGrey){type='greyscale';}
   else if(steps.length===6||steps.length===7||steps.length===30||steps.length===31){type='colors';}
   else if(steps.length===24||steps.length===25){type='saturations';}
  }
	 } else {
  if(s.total_steps){
   points=normalizePoints(type,s.total_steps,steps);
  }
	  steps=meterBuildStepsJS(type,points);
	 }
 if(s.total_steps){
  points=normalizePoints(type,s.total_steps,steps);
 }
	 else if(steps&&steps.length>0){
	  points=normalizePoints(type,steps.length,steps);
	 }
	 steps=meterCanonicalRecoveredSteps(type,points,steps,s.status||'complete');
	 steps=meterRecoveryDisplaySteps(type,points,steps);
	 if(s.series_id) steps=meterApplyColorSeriesTargetWhiteReference(steps,type);
 meterSeriesSteps=steps;
 meterActiveSeriesType=type;
 meterActiveSeriesPoints=points;
 const metaStep=(Array.isArray(steps)?steps.find(st=>st&&(st.signal_mode||st.target_gamma||st.max_luma||st.dv_map_mode||st.dv_interface)):null)||{};
 const metaReading=(s.readings&&Array.isArray(s.readings)?s.readings.find(rd=>rd&&(rd.signal_mode||rd.target_gamma||rd.max_luma||rd.dv_map_mode||rd.dv_interface)):null)||{};
 meterActiveSeriesSignalMode=String((s.signal_mode||metaStep.signal_mode||metaReading.signal_mode||meterChartSignalMode()||'sdr')).toLowerCase();
 meterActiveSeriesTargetGamma=String((s.target_gamma||metaStep.target_gamma||metaReading.target_gamma||'')).toLowerCase()||null;
 const activeMaxLuma=Number((s.max_luma!=null?s.max_luma:(metaStep.max_luma!=null?metaStep.max_luma:metaReading.max_luma)));
 meterActiveSeriesMaxLuma=(activeMaxLuma>0&&isFinite(activeMaxLuma))?activeMaxLuma:null;
 meterActiveSeriesDvMapMode=String((s.dv_map_mode||metaStep.dv_map_mode||metaReading.dv_map_mode||'')).toLowerCase()||null;
 meterActiveSeriesDvInterface=String((s.dv_interface||metaStep.dv_interface||metaReading.dv_interface||'')).toLowerCase()||null;
 meterActiveSeriesKey=(s&&s.cache_key)?String(s.cache_key):(type+'-'+points);
 meterSharedSeriesId=s.series_id||null;
 if(typeof meterLatticeDefault3dView==='function') meterLatticeDefault3dView(points);
   const recoveredSelectedStep=preserveSelection&&Array.isArray(steps)
    ?(steps.find(step=>previousSelectedKey&&meterStepNameKey(step)===previousSelectedKey)
      ||steps.find(step=>previousSelectedName&&String(step&&step.name||'')===previousSelectedName)
      ||null)
    :null;
   meterCurrentPatchStep=recoveredSelectedStep;
   meterSelectedThumbIre=recoveredSelectedStep?meterStepNameKey(recoveredSelectedStep):null;
   _selectedColorReadingName=recoveredSelectedStep&&previousSelectedName?previousSelectedName:null;
   _colorDetailPinned=!!(recoveredSelectedStep&&previousColorPinned);
 // The 10-second shared-status poll may refresh the series currently on
 // screen. Preserve the operator's scroll position when its key is unchanged;
 // only a genuinely different recovered series starts at patch zero.
 meterGreyscaleScrollRatio=(previousSeriesKey===meterActiveSeriesKey)?previousScrollRatio:0;
 meterLastChartCount=0;
 // Restore readings — always clear the previous series first so a cached
 // empty Sat Sweep can never leave the old Colors CIE plot on screen.
 meterReadings=[];
 meterWhiteReading=null;
 meterSeriesBaselineBlack=s.black_reading?JSON.parse(JSON.stringify(s.black_reading)):null;
	 if(!meterSeriesBaselineBlack&&Array.isArray(s.readings)){
	  const recoveredBlack=[...s.readings].reverse().find(rd=>{
	   if(!rd||rd.error) return false;
	   const name=String(rd.name||'').trim().toLowerCase();
	   if(name==='black ref') return meterReadingHasLuminance(rd);
	   const r=Number(rd.r_code!=null?rd.r_code:rd.r);
	   const g=Number(rd.g_code!=null?rd.g_code:rd.g);
	   const b=Number(rd.b_code!=null?rd.b_code:rd.b);
	   return Math.abs(Number(rd.ire||0))<0.05&&r===g&&g===b&&meterReadingHasLuminance(rd);
	  });
	  if(recoveredBlack) meterSeriesBaselineBlack=JSON.parse(JSON.stringify(recoveredBlack));
	 }
	 if(meterSeriesBaselineBlack){
	  try{ meterNormalizeMeasuredReading(meterSeriesBaselineBlack); }catch(e){}
	 }
	 if(s.readings&&s.readings.length>0){
	  meterReadings=meterAttachSeriesMeta(meterFilterReadingsForCurrentSteps(s.readings,type));
  // Invalidate any carried-over per-reading analysis caches (ΔE/gamma)
  // so charts recompute against the restored chart context rather than a
  // value cached under a prior white reference / target black / gamma.
  if(Array.isArray(meterReadings)) meterReadings.forEach(rd=>{ if(rd){ delete rd._dE_raw; delete rd._dE_lc; delete rd._dE_cache_key; delete rd._gamma_rgb; } });
  const white=meterReadings.find(rd=>meterReadingIsSeriesWhite(rd));
  if(white) meterWhiteReading=white;
 }
	 if(s.white_reading&&s.white_reading.luminance!=null&&meterReadingMatchesStepList(s.white_reading,type,meterSeriesSteps)){
	  meterWhiteReading=s.white_reading;
	  if(meterWhiteReading.synthetic_target) meterWhiteReading=meterSyntheticGreyWhiteReading(meterColorReferenceNits());
	  else meterNormalizeMeasuredReading(meterWhiteReading);
	 }
 // Show UI elements — ensure card is visible even if meter is disconnected
 document.getElementById('meterCard').style.display='';
 if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true); else document.getElementById('meterCharts').style.display='';
 meterShowSeriesTabForSeries(type,points);
 // Toggle greyscale vs color chart sections
 if(type==='greyscale'){
  document.getElementById('chartsGreyscaleWrap').style.display='';
  document.getElementById('chartsColorWrap').style.display='none';
 } else {
  document.getElementById('chartsGreyscaleWrap').style.display='none';
  document.getElementById('chartsColorWrap').style.display='';
 }
 meterUpdateGreyscaleChartMode();
 document.getElementById('meterExportRow').style.display='';
 document.getElementById('meterReadSeriesBtn').style.display='';
 meterSetThumbsVisible(true);
 meterResetLiveReadingDisplay();
 document.getElementById('meterLiveReading').style.display='none';
 // Highlight correct series button
 meterResetSeriesButtons();
 const importedSnap=meterSeriesSnapshotForMode(meterSeriesCache&&meterSeriesCache[meterActiveSeriesKey],meterActiveSeriesSignalMode);
 let activeBtn=document.querySelector('#meterSeriesBtnRow button[data-series="'+meterActiveSeriesKey+'"]');
 if(!activeBtn&&meterSeriesSnapshotIsImported(importedSnap)){
  if(type==='greyscale') activeBtn=document.querySelector('#meterSeriesBtnRow button[data-series="greyscale-'+points+'"]');
  else if(type==='colors') activeBtn=null;
 }
 if(activeBtn){activeBtn.classList.remove('btn-secondary');activeBtn.classList.add('btn-primary');}
 meterRenderCustomSeriesButtons();
 // Build thumbs and charts
 const sortedSteps=(type==='colors'||type==='saturations')?[...steps]:meterGreyscaleSeriesSteps(steps);
 const completedIres=new Set();
 if(meterReadings) meterReadings.forEach(rd=>{if(rd.luminance!=null) completedIres.add(meterStepNameKey(rd));});
 let currentIre=s.current_name||null;
 meterBuildPatchThumbs(sortedSteps,completedIres,currentIre);
 // Canvas resizing and six greyscale chart paints are the most expensive part
 // of a cached switch (especially the 3726px-wide 101-point canvases). Let the
 // selected button and thumbnails paint first, then redraw against a captured
 // snapshot. The key guard drops a stale callback after a rapid second click.
 const recoveredChartKey=meterActiveSeriesKey;
 const recoveredReadings=Array.isArray(meterReadings)?[...meterReadings]:[];
 const drawRecoveredCharts=()=>{
  if(meterActiveSeriesKey!==recoveredChartKey||meterSeriesChartRevision!==recoveredChartRevision) return;
  if(recoveredReadings.length>0){
   const sorted=(type==='colors'||type==='saturations')?[...recoveredReadings]:[...recoveredReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
   drawAllCharts(sorted);
   // On the first greyscale -> colour transition the newly unhidden colour
   // canvases can still report their old/zero layout during this paint. A
   // guarded second-frame paint uses the settled dimensions. Without it the
   // imported readings are loaded but the ColorChecker charts/table remain
   // visually blank until another colour series supplies a second paint.
   if((type==='colors'||type==='saturations')&&typeof window.requestAnimationFrame==='function'){
    window.requestAnimationFrame(()=>window.requestAnimationFrame(()=>{
     if(meterActiveSeriesKey===recoveredChartKey&&meterSeriesChartRevision===recoveredChartRevision&&meterReadings&&meterReadings.length) drawAllCharts([...meterReadings]);
    }));
    // The Color tab's automatic default selection also completes a broader
    // tab/layout pass after the animation frames above. That pass can resize
    // (and therefore clear) chartCIE while leaving the readings table intact.
    // Repaint once after it settles; the key guard prevents stale work when
    // the operator has already moved to Sat Sweep or another series.
    [150,500,1000,1500].forEach(delay=>setTimeout(()=>{
     if(meterActiveSeriesKey===recoveredChartKey&&meterSeriesChartRevision===recoveredChartRevision&&meterReadings&&meterReadings.length) drawAllCharts([...meterReadings]);
    },delay));
   }
   const selectedNow=meterCurrentPatchStep?meterFindReadingForStep(meterCurrentPatchStep):null;
   const lastValid=[...recoveredReadings].reverse().find(rd=>rd.luminance!=null);
   if(selectedNow&&meterReadingHasLuminance(selectedNow)) updateLiveReading(selectedNow);
   else if(!meterCurrentPatchStep&&lastValid) updateLiveReading(lastValid);
  } else drawAllChartsPreset(sortedSteps);
 };
 if(s&&s._defer_cache_persist&&typeof window.requestAnimationFrame==='function'){
  window.requestAnimationFrame(()=>setTimeout(drawRecoveredCharts,0));
 } else drawRecoveredCharts();
  meterCacheSeriesState(s.status||'complete',s&&s._defer_cache_persist?{deferPersist:true}:null);
  if(s.status==='running'||s.status==='setup'||s.status==='started'){
  // Series is still running — start polling and show stop button
  meterSeriesRunning=true;
  meterSeriesAwaitingReady=!!s.awaiting_ready;
  meterSeriesSpectroSetupApplyFromStatus(s);
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterStopBtn').style.display='';
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.add('btn-success');
  document.getElementById('meterProgressLabel').textContent=s.current_name||'Running...';
  document.getElementById('meterDot').style.background='var(--orange)';
  if(meterSeriesPolling) clearInterval(meterSeriesPolling);
  meterSeriesPolling=setInterval(meterPollSeries,meterSeriesPollIntervalMs);
 } else {
  // Complete/cancelled/error — just show results, no polling
  meterSeriesRunning=false;
  document.getElementById('meterStopBtn').style.display='none';
  document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
  if(s.status==='error'){
   document.getElementById('meterProgress').style.display='';
   document.getElementById('meterProgressLabel').textContent=s.current_name||'Error';
  }
 }
 meterUpdateReadButtons();
 meterUpdateDeltaEFormControl();
}

function meterStampReadingStepMeta(reading,step){
 if(!reading||!step) return reading;
 const alternateStimulus=meterReadingUsesAlternateStimulus(reading,step);
 if(step.ire!=null) {
  reading.ire=step.ire;
  reading.nominal_ire=step.ire;
  reading.plot_ire=step.ire;
 }
 if(step.name!=null) reading.name=step.name;
 if(alternateStimulus){
  if(step.name!=null) reading.nominal_name=step.name;
  if(step.r!=null) reading.nominal_r_code=step.r;
  if(step.g!=null) reading.nominal_g_code=step.g;
  if(step.b!=null) reading.nominal_b_code=step.b;
  if(reading.stimulus!=null) reading.patch_stimulus=reading.stimulus;
 } else {
  if(step.r!=null) reading.r_code=step.r;
  if(step.g!=null) reading.g_code=step.g;
  if(step.b!=null) reading.b_code=step.b;
 }
 if(step.series_type!=null) reading.series_type=step.series_type;
 if(step.series_white_reference!=null) reading.series_white_reference=step.series_white_reference;
 if(!alternateStimulus&&step.stimulus!=null) reading.stimulus=step.stimulus;
 if(!alternateStimulus&&step.input_max!=null) reading.input_max=step.input_max;
	 if(!alternateStimulus&&step.signal_r_pct!=null) reading.signal_r_pct=step.signal_r_pct;
	 if(!alternateStimulus&&step.signal_g_pct!=null) reading.signal_g_pct=step.signal_g_pct;
	 if(!alternateStimulus&&step.signal_b_pct!=null) reading.signal_b_pct=step.signal_b_pct;
	 if(step.signal_mode!=null) reading.signal_mode=step.signal_mode;
	 if(step.target_gamma!=null) reading.target_gamma=step.target_gamma;
	 if(step.max_luma!=null) reading.max_luma=step.max_luma;
	 if(step.dv_map_mode!=null) reading.dv_map_mode=step.dv_map_mode;
	 if(step.dv_interface!=null) reading.dv_interface=step.dv_interface;
	 if(step.analysis_ire!=null) reading.analysis_ire=step.analysis_ire;
 if(step.target_ire!=null) reading.target_ire=step.target_ire;
 if(step.transport_stimulus!=null) reading.transport_stimulus=step.transport_stimulus;
 if(step.point_role!=null) reading.point_role=step.point_role;
 if(step.series_color!=null) reading.series_color=step.series_color;
 if(step.sat_pct!=null) reading.sat_pct=step.sat_pct;
 if(step.target_x!=null) reading.target_x=step.target_x;
 if(step.target_y!=null) reading.target_y=step.target_y;
 if(step.target_Yn!=null) reading.target_Yn=step.target_Yn;
 if(step.target_X!=null) reading.target_X=step.target_X;
 if(step.target_Y!=null) reading.target_Y=step.target_Y;
 if(step.target_Z!=null) reading.target_Z=step.target_Z;
 if(step.dv_absolute_white_y!=null) reading.dv_absolute_white_y=step.dv_absolute_white_y;
 if(step.dv_absolute_target_y!=null) reading.dv_absolute_target_y=step.dv_absolute_target_y;
 if(step.dv_absolute_rolloff_pct!=null) reading.dv_absolute_rolloff_pct=step.dv_absolute_rolloff_pct;
 if(step.dv_absolute_tunnel_gamma!=null) reading.dv_absolute_tunnel_gamma=step.dv_absolute_tunnel_gamma;
 if(step.dv_absolute_st2084_precomp!=null) reading.dv_absolute_st2084_precomp=step.dv_absolute_st2084_precomp;
 if(step.series_target_white_y!=null) reading.series_target_white_y=step.series_target_white_y;
 if(step.lg_target_white_y!=null) reading.lg_target_white_y=step.lg_target_white_y;
 if(step.series_target_black_y!=null) reading.series_target_black_y=step.series_target_black_y;
 if(step.autocal_code!=null) reading.autocal_code=step.autocal_code;
 if(step.series_mode!=null) reading.series_mode=step.series_mode;
 if(step.autocal_white_reference!=null) reading.autocal_white_reference=step.autocal_white_reference;
 if(step.autocal_reference_only!=null) reading.autocal_reference_only=step.autocal_reference_only;
 if(step.autocal_read_only!=null) reading.autocal_read_only=step.autocal_read_only;
 if(step.autocal_slot_locked!=null) reading.autocal_slot_locked=step.autocal_slot_locked;
 if(step.ddc_slot_locked!=null) reading.ddc_slot_locked=step.ddc_slot_locked;
 if(step.autocal_legal_white_anchor!=null) reading.autocal_legal_white_anchor=step.autocal_legal_white_anchor;
 if(step.ddc_target_ire!=null) reading.ddc_target_ire=step.ddc_target_ire;
 if(step.autocal_order_ire!=null) reading.autocal_order_ire=step.autocal_order_ire;
 if(step.autocal_target_label!=null) reading.autocal_target_label=step.autocal_target_label;
 return reading;
}

function meterAttachSeriesMeta(readings){
 if(!Array.isArray(readings)||!meterSeriesSteps) return readings||[];
 return readings.map(rd=>{
  const matches=meterSeriesSteps.filter(s=>(meterStepNameKey(s)===meterStepNameKey(rd)||((s.name||'')===(rd.name||'')))&&meterReadingMatchesStepForPlot(rd,s));
  const wantsReference=!!(rd&&(rd.autocal_white_reference||rd.autocal_reference_only||rd.autocal_read_only)&&rd.ddc_target_ire==null);
  const step=wantsReference
   ? (matches.find(s=>meterReadingIsAutoCalReferenceOnly(s)||s.autocal_read_only)||matches[0])
   : (matches.find(s=>!meterReadingIsAutoCalReferenceOnly(s)&&!s.autocal_read_only)||matches[0]);
  const reading=step?meterStampReadingStepMeta(rd,step):rd;
  return meterNormalizeOledBlackReading(meterNormalizeMeasuredReading(reading));
 });
}

// Custom colour/profile series commonly label neutral endpoints by source
// code (for example "255") rather than IRE. Recognize those endpoints without
// requiring a special display label.
function meterReadingIsSeriesWhite(rd){
 if(!rd||rd.synthetic_target||rd.error) return false;
 if(!meterReadingHasLuminance(rd)) return false;
 if(rd.series_white_reference) return true;
 const name=String(rd.name||'').trim().toLowerCase();
 const ire=Number(rd.ire);
 const r=Number(rd.r_code!=null?rd.r_code:rd.r);
 const g=Number(rd.g_code!=null?rd.g_code:rd.g);
 const b=Number(rd.b_code!=null?rd.b_code:rd.b);
 const neutral=Number.isFinite(r)&&r===g&&g===b;
 if(!neutral) return false;
 if(name==='white'||name==='white ref'||name==='100% white') return true;
 if(Number.isFinite(ire)&&Math.abs(ire-100)<0.05) return true;
 const targetYn=Number(rd.target_Yn);
 // target_Yn is not bounded to 1 for absolute PQ patches. For example, the
 // DV ColorChecker neutral ramp stores absolute luminance in 100-nit units,
 // so Gray 50/65/80 legitimately carry values above 1. Treating every one of
 // those as white replaced the series reference as each reading arrived and
 // retroactively changed Delta E for every earlier patch. Only an actual
 // unit-relative target is a white candidate here; name, IRE, and full-scale
 // code checks above/below remain the authoritative endpoint detection.
 if(Number.isFinite(targetYn)&&Math.abs(targetYn-1)<0.0005) return true;
 const inputMax=Number(rd.input_max);
 return Number.isFinite(inputMax)&&inputMax>0&&r===inputMax;
}

function meterFindSeriesWhiteReading(readings){
 const list=Array.isArray(readings)?readings:[];
 // Prefer live SDR26 peak (Limited 109 / Full 100 latest measured Y).
 if(typeof meterFindSdr26PeakWhiteReading==='function'){
  const peak=meterFindSdr26PeakWhiteReading(list);
  if(peak) return peak;
 }
 // SDR26 robustness fix: scan twice, prefer the headroom-encoded 109
 // legal peak (r_code == 1023) over the 100% reading whenever BOTH are
 // present. The autocal worker uses 109's measured Y as the target-curve
 // peak for every body anchor; the chart must match that reference.
 const _sdr109=list.find(rd=>{
  if(!rd || !meterReadingHasLuminance(rd)) return false;
  if(!meterReadingIsGreyscale(rd)) return false;
  const _rdIre=Number(rd.ire);
  const _rdCode=Number(rd.r_code!=null?rd.r_code:rd.r);
  return Number.isFinite(_rdIre) && Math.abs(_rdIre-109)<0.05 && Number.isFinite(_rdCode) && _rdCode>255;
 });
 if(_sdr109) return _sdr109;
 // Prefer latest 100% (by timestamp) over first-in-list so Full peak
 // re-reads replace the initial white on the chart.
 let best100=null;
 list.forEach(rd=>{
  // meterReadingHasLuminance normalizes valid Y-only readings. Previously
  // those readings were rejected here before meterReadingIsSeriesWhite could
  // identify them, causing intermittent "No 100% white reading" CSV errors.
  if(!rd || !meterReadingHasLuminance(rd)) return;
  if(!meterReadingIsGreyscale(rd)) return;
  const name=String(rd.name||'').toLowerCase();
  const _rdIre=Number(rd.ire);
  const is100=meterReadingIsSeriesWhite(rd)||(_rdIre===100)||Math.abs(_rdIre-100)<0.05||name==='white'
   ||rd.autocal_legal_white_anchor||rd.autocal_white_reference
   ||(Number.isFinite(_rdIre)&&Math.abs(_rdIre-109)<0.05);
  if(!is100) return;
  const ts=Number(rd.timestamp)||0;
  if(!best100||ts>=(best100.ts||0)) best100={rd,ts};
 });
 return best100?best100.rd:null;
}

function meterCanonicalSeriesStep(step){
 if(!step||!Array.isArray(meterSeriesSteps)||!meterSeriesSteps.length) return step||null;
 if(meterCanonicalStepCacheSource!==meterSeriesSteps||!meterCanonicalStepCache){
  const byObject=new Map();
  const byKey=new Map();
  meterSeriesSteps.forEach(candidate=>{
   byObject.set(candidate,candidate);
   const key=meterStepNameKey(candidate);
   if(key&&!byKey.has(key)) byKey.set(key,candidate);
   const name=String((candidate&&candidate.name)||'');
   if(name&&!byKey.has('name:'+name)) byKey.set('name:'+name,candidate);
  });
  meterCanonicalStepCacheSource=meterSeriesSteps;
  meterCanonicalStepCache={byObject:byObject,byKey:byKey};
 }
 const direct=meterCanonicalStepCache.byObject.get(step);
 if(direct) return direct;
 const key=meterStepNameKey(step);
 if(key&&meterCanonicalStepCache.byKey.has(key)) return meterCanonicalStepCache.byKey.get(key);
 const name=String(step.name||'');
 return (name&&meterCanonicalStepCache.byKey.get('name:'+name))||step;
}

function meterFreshSeriesStep(step){
 const canon=meterCanonicalSeriesStep(step)||step;
 if(!canon||!meterActiveSeriesType||!meterActiveSeriesPoints||meterSeriesRunning) return canon||null;
 const freshSteps=meterBuildStepsJS(meterActiveSeriesType,meterActiveSeriesPoints);
 if(!Array.isArray(freshSteps)||freshSteps.length===0) return canon;
 const key=meterStepNameKey(canon);
 const name=String(canon.name||'');
 const ire=Number(canon.ire);
 const fresh=freshSteps.find(s=>{
  if(key&&meterStepNameKey(s)===key) return true;
  if(name&&String(s.name||'')===name) return true;
  const sIre=Number(s.ire);
  return Number.isFinite(ire)&&Number.isFinite(sIre)&&Math.abs(sIre-ire)<0.001&&String(s.series_color||'')===String(canon.series_color||'');
 })||canon;
 meterSeriesSteps=freshSteps;
 if(meterCurrentPatchStep&&key&&meterStepNameKey(meterCurrentPatchStep)===key) meterCurrentPatchStep=fresh;
 return fresh;
}

function meterUpsertSeriesReading(reading,step){
 if(!reading) return;
 meterNormalizeMeasuredReading(reading);
 const canon=meterCanonicalSeriesStep(step||reading);
 if(canon) meterStampReadingStepMeta(reading,canon);
 if(!Array.isArray(meterReadings)) meterReadings=[];
 const key=meterStepNameKey(reading);
 const idx=meterReadings.findIndex(r=>meterStepNameKey(r)===key||((r&&r.name||'')===(reading.name||'')));
 if(idx>=0) meterReadings[idx]=reading;
 else meterReadings.push(reading);
}

function meterReadingHasLuminance(rd){
 meterNormalizeMeasuredReading(rd);
 return !!rd&&((rd.luminance!=null&&rd.luminance>=0)||(rd.Y!=null&&rd.Y>=0));
}

function meterReadingHasChromaticity(rd){
 meterNormalizeMeasuredReading(rd);
 return !!rd&&rd.x!=null&&rd.y!=null&&rd.x>0&&rd.y>0;
}

function meterIsWhiteReferenceReading(rd){
 if(!rd) return false;
 const name=String(rd.name||'').trim().toLowerCase();
 return name==='white ref'||name==='black ref';
}

function meterCacheSeriesState(status,options){
 // Never persist an ICC characterization run as a selectable chart snapshot.
 // This also prevents a completed profile run from becoming the last Series
 // restored after a browser refresh.
 if(meterActiveSeriesIsIccWorkflow()) return;
 if(!meterActiveSeriesKey||!meterSeriesSteps||meterSeriesSteps.length===0) return;
 const activeSignalMode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const prev=meterSeriesSnapshotForMode(meterSeriesCache[meterActiveSeriesKey],activeSignalMode);
 const readings=JSON.parse(JSON.stringify(meterReadings||[]));
 const observerReadings=JSON.parse(JSON.stringify((prev&&prev.observer_readings)||{}));
 const readingObserver=(typeof meterObserverForReadings==='function')?meterObserverForReadings(readings):null;
 if((meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')&&readingObserver&&readings.length){
  observerReadings[readingObserver]={
   readings:readings,
   white_reading:meterWhiteReading?JSON.parse(JSON.stringify(meterWhiteReading)):null,
   black_reading:meterSeriesBaselineBlack?JSON.parse(JSON.stringify(meterSeriesBaselineBlack)):null,
   updated_at:Date.now()
  };
 }
 // Never downgrade a COMPLETE snapshot to a partial in-progress one. The chart
 // is driven by live meterReadings while a series runs, so the cache only
 // matters on restore -- and letting a mid-run write land meant selecting that
 // series later showed a handful of points instead of the finished set.
 // Reported after a Full Auto Cal: the post-cal report measures Greyscale 21pt
 // first, and afterwards re-selecting the 21pt series showed only a few of its
 // readings. An explicit clear is unaffected: meterClearResults marks the
 // snapshot cleared, which is handled by the branch below.
 if(prev && String(prev.status||'').toLowerCase()==='complete'
  && !meterSeriesSnapshotIsCleared(prev)
  && String(status||'').toLowerCase()==='running'
  && Array.isArray(prev.readings)
  && readings.length < prev.readings.length
  && Array.isArray(prev.steps) && prev.steps.length===meterSeriesSteps.length){
  return;
 }
 if(readings.length===0&&prev&&meterSeriesSnapshotIsCleared(prev)&&String(status||'').toLowerCase()!=='running'){
  meterStoreSeriesSnapshot(meterActiveSeriesKey,{...prev,updated_at:Date.now()});
  if(options&&options.deferPersist) meterScheduleSeriesCachePersist();
  else meterPersistSeriesCache();
  return;
 }
	 const snapshot={
	  type:meterActiveSeriesType,
	  points:meterActiveSeriesPoints,
	  source_format:(prev&&prev.source_format)||((readings.length&&readings.every(meterSeriesReadingIsImported))?'hcfr-chc':null),
	  source_label:(prev&&prev.source_label)||null,
	  source_rgb_range:(prev&&prev.source_rgb_range)||null,
	  source_session_id:(prev&&prev.source_session_id)||null,
	  source_group:(prev&&prev.source_group)||null,
	  hcfr_preferences:(prev&&prev.hcfr_preferences)?JSON.parse(JSON.stringify(prev.hcfr_preferences)):null,
	  signal_mode:activeSignalMode,
	  target_gamma:meterActiveSeriesTargetGamma||null,
	  max_luma:meterActiveSeriesMaxLuma||null,
	  dv_map_mode:meterActiveSeriesDvMapMode||null,
	  dv_interface:meterActiveSeriesDvInterface||null,
	  observer_readings:observerReadings,
	  white_reading:meterWhiteReading?JSON.parse(JSON.stringify(meterWhiteReading)):null,
	  black_reading:meterSeriesBaselineBlack?JSON.parse(JSON.stringify(meterSeriesBaselineBlack)):null,
  steps:JSON.parse(JSON.stringify(meterSeriesSteps||[])),
  readings:readings,
  status:status||(meterSeriesRunning?'running':'complete'),
  series_id:meterSharedSeriesId||((prev&&prev.series_id)?prev.series_id:null),
  updated_at:Date.now()
 };
 meterStoreSeriesSnapshot(meterActiveSeriesKey,snapshot);
 if(options&&options.deferPersist) meterScheduleSeriesCachePersist();
 else meterPersistSeriesCache();
}

function meterRestoreSeriesFromCache(key){
 const cached=meterResolveSeriesSnapshotFromCache(key,arguments[1]||{});
 if(!cached||!cached.steps||cached.steps.length===0) return false;
 const sourceSnap=meterSeriesCache&&meterSeriesCache[key];
 if(sourceSnap&&sourceSnap.source_format==='hcfr-chc'&&sourceSnap.source_session_id) meterActiveHcfrSessionId=sourceSnap.source_session_id;
 let restoredReadings=JSON.parse(JSON.stringify(cached.readings||[]));
 let restoredWhite=cached.white_reading?JSON.parse(JSON.stringify(cached.white_reading)):null;
 let restoredBlack=cached.black_reading?JSON.parse(JSON.stringify(cached.black_reading)):null;
 if(cached.type==='colors'||cached.type==='saturations'){
  const observer=meterChromaticityObserver();
  const observerEntry=cached.observer_readings&&cached.observer_readings[observer];
  if(observerEntry&&Array.isArray(observerEntry.readings)){
   restoredReadings=JSON.parse(JSON.stringify(observerEntry.readings));
   restoredWhite=observerEntry.white_reading?JSON.parse(JSON.stringify(observerEntry.white_reading)):null;
   restoredBlack=observerEntry.black_reading?JSON.parse(JSON.stringify(observerEntry.black_reading)):restoredBlack;
  }else if(meterObserverForReadings(restoredReadings)!==observer){
   restoredReadings=[];
   restoredWhite=null;
  }
 }
 meterRecoverSeries({
  series_id:null,
  cache_key:key,
  type:cached.type,
  points:cached.points,
  source_format:cached.source_format||null,
  status:cached.status||'complete',
	  total_steps:cached.steps.length,
	  signal_mode:cached.signal_mode,
	  target_gamma:cached.target_gamma,
	  max_luma:cached.max_luma,
	  dv_map_mode:cached.dv_map_mode,
	  steps:JSON.parse(JSON.stringify(cached.steps)),
  readings:restoredReadings,
  white_reading:restoredWhite,
  black_reading:restoredBlack,
  _defer_cache_persist:true
 });
 meterSharedSeriesId=null;
 return true;
}

function meterClearLiveReading(step){
 const liveLabel=document.getElementById('meterLiveReadingLabel');
 const targetStep=step||(meterCurrentPatchStep?(meterCanonicalSeriesStep(meterCurrentPatchStep)||meterCurrentPatchStep):null);
 document.getElementById('meterLiveReading').style.display='';
 if(liveLabel) liveLabel.textContent=meterReadingPatchLabel(targetStep);
 document.getElementById('meterLum').textContent='--';
 document.getElementById('meterCCT').textContent='--';
 document.getElementById('meterCIEx').textContent='--';
 document.getElementById('meterCIEy').textContent='--';
 // Selected-but-unread patch: still show its targets so the operator knows
 // what the read should land on.
 meterUpdateLiveReadingTargets(targetStep);
 meterUpdateLiveReadingDetails(targetStep,false);
 drawRGBBars(null);
 meterRenderGreyTvControls(null);
 drawDeltaBarsVertical('meterRGBCanvasGrey',null);
 drawDeltaBarsVertical('meterRGBCanvasColor',null);
 drawDeltaBarsVertical('meterXYYCanvasColor',null);
}

function meterFindReadingForStep(step){
 if(!step||!Array.isArray(meterReadings)||!meterReadings.length) return null;
 const canon=meterCanonicalSeriesStep(step)||step;
 const key=meterStepNameKey(canon);
 const name=String(canon.name||'');
 for(let i=meterReadings.length-1;i>=0;i--){
  const rd=meterReadings[i];
  if(!rd||!meterReadingHasLuminance(rd)) continue;
  if(key&&meterStepNameKey(rd)===key&&meterReadingMatchesStepForPlot(rd,canon)) return rd;
  if(name&&(rd.name||'')===name&&meterReadingMatchesStepForPlot(rd,canon)) return rd;
  if(!name&&canon.ire!=null&&rd.ire===canon.ire&&meterReadingMatchesStepForPlot(rd,canon)) return rd;
 }
 return null;
}

// Populates explicit target labels in the live Patch Reading box.
// Accepts a measured reading OR an unread canonical series step (targets
// show as soon as a patch is selected, before it is read). Pass null to
// clear. CCT target only renders for near-neutral (greyscale) patches,
// mirroring the measured-CCT suppression rule; CIE x/y come from the same
// target math the charts use, so the pair always agrees with the ΔE view.
function meterUpdateLiveReadingTargets(src){
 const set=(id,txt)=>{ const e=document.getElementById(id); if(e) e.textContent=txt; };
 let tY=null,tXY=null,tCct=null,isGrey=false;
 if(src){
  try{ isGrey=meterReadingIsGreyscale(src); }catch(e){}
  try{
   const info=meterColorLuminanceInfo(src);
   if(info&&info.targetY!=null&&Number.isFinite(Number(info.targetY))) tY=Number(info.targetY);
  }catch(e){}
  try{
   const t=meterTargetXYZForReading(src);
   const s=t?(t.X+t.Y+t.Z):0;
   if(s>0) tXY={x:t.X/s,y:t.Y/s};
   // Chroma-only targets (e.g. the SDR26 109% legal peak) return {0,0,0}:
   // no target Y, but the chromaticity target is still the white point.
   else if(isGrey){ const wp=meterTargetWhitePoint(); tXY={x:wp.x,y:wp.y}; }
  }catch(e){}
  if(tXY&&isGrey) tCct=meterCctFromXy(tXY.x,tXY.y);
 }
 set('meterLumTgt', tY!=null?('Target: '+tY.toFixed(2)):'');
 set('meterCCTTgt', tCct!=null?('Target: '+Math.round(tCct)+'K'):'');
 set('meterCIExTgt', tXY?('Target: '+tXY.x.toFixed(4)):'');
 set('meterCIEyTgt', tXY?('Target: '+tXY.y.toFixed(4)):'');
}

// Display scale for the calculated RGB row (the "RGB"/"RGB PQe" readout).
//
// That row is a SIMULATED value -- the measured XYZ re-encoded back to a signal
// -- shown beside the signal the patch asked for. Both columns therefore belong
// on the OPERATOR'S selected range, not on whatever range the patch ladder
// happens to be coded in. They used to be pinned to the ladder's range, so on
// an RGB FULL transport a 100% white patch displayed as 235 / target 235 and 0%
// as 16 / target 16, because the HDR and DV greyscale ladders are limited-coded.
//
// This is a PRESENTATION scale only. The emitted patch codes are deliberately
// left exactly as they were -- the ladders are a separate, hardware-driven
// concern and changing them is not what this row is reporting.
// The SDR26 YCbCr-Limited ladder is legal-EXPANDED: 0% is code 64 and the top
// slot is 109% at code 1023, so in 8-bit terms its signal axis spans 16..255,
// NOT 16..235. Gate strictly on the SDR autocal-26 ladder:
// meterSdr26UsesSuperWhiteLadder() alone is true for any YCbCr Limited link,
// including HDR and DV, whose ladders top out at 100% and must keep 16..235.
// meterGreyAllowsHeadroomTargets() is exactly this question already -- greyscale
// + 26pt + SDR + the super-white ladder, i.e. "this series has slots above
// 100%". Reuse it rather than re-deriving: meterUseLgAutoCal26() additionally
// requires live LG TV-control state, which has nothing to do with how a code is
// displayed and made the row fall back to 16..235 whenever the TV link was not
// up yet.
function meterLiveSuperWhiteLadderActive(){
 if(typeof meterGreyAllowsHeadroomTargets==='function') return !!meterGreyAllowsHeadroomTargets();
 const mode=String((meterActiveSeriesSignalMode
  ||(typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr')).toLowerCase();
 if(mode!=='sdr') return false;
 return (typeof meterSdr26UsesSuperWhiteLadder==='function')?!!meterSdr26UsesSuperWhiteLadder():false;
}

// peakIre is the IRE that sits at the TOP of the code range, so the target
// fraction normalizes against it. On the super-white ladder that is 109 (code
// 1023): normalizing by 100 instead clamped both 100% and 109% to legal white,
// so the calculated RGB row showed 235 for both (operator-reported).
// Cross-check against the emitted ladder codes: 0%->64/4=16, 50%->504/4=126,
// 100%->940/4=235, 105%->984/4=246, 109%->1023/4=255.
function meterLiveDisplayCodeRange(){
 if(meterLiveSuperWhiteLadderActive()) return {min:16,span:239,peakIre:109};
 return (typeof meterPatchUsesVideoRange==='function'&&meterPatchUsesVideoRange())
  ? {min:16,span:219,peakIre:100} : {min:0,span:255,peakIre:100};
}

function meterLiveTargetRgbCodes(src){
 if(!src) return null;
 const step=meterCanonicalSeriesStep(src)||src;
 const disp=meterLiveDisplayCodeRange();
 const toDisplay=(frac)=>Math.round(disp.min+disp.span*Math.max(0,Math.min(1,frac)));
 // The patch's own per-channel signal percentage is the honest source for this
 // row: it is what the patch ASKED for, independent of how the ladder encoded
 // it. Greyscale steps stamp signal_r/g/b_pct on both the server
 // (webui_meter_series_start) and the client (makeHdrStep), so 0% -> range min
 // and 100% -> range max regardless of the ladder's coding.
 const pct=['r','g','b'].map(channel=>Number(step['signal_'+channel+'_pct']));
 if(pct.every(value=>Number.isFinite(value)&&value>=0)){
  return pct.map(value=>toDisplay(value/(disp.peakIre||100)));
 }
 const raw=['r','g','b'].map(channel=>{
  const code=step[channel+'_code']!=null?step[channel+'_code']:step[channel];
  return Number(code);
 });
 if(!raw.every(Number.isFinite)) return null;
 // Decide code depth once for the whole patch/series. Testing each channel's
 // value independently made Limited 10-bit greyscale jump from 64/108/239
 // to 71 at the first code above 255. input_max is stamped on every normal
 // series step; the remaining checks cover recovered legacy snapshots.
 const inputMax=Number(step.input_max!=null?step.input_max:src.input_max);
 const tenBit=inputMax===1023 || raw.some(code=>code>255) ||
  ((typeof meterPatchBitDepth==='function'&&meterPatchBitDepth()===10) &&
   !(typeof meterActiveSeriesCodesAre8Bit==='function'&&meterActiveSeriesCodesAre8Bit()));
 // No per-channel signal pct (colour / saturation patches, legacy snapshots):
 // reduce the 10-bit code to its 8-bit equivalent using the exact 4x mapping
 // (Limited 64..940 -> 16..235; Full 0..1023 -> 0..255), then convert it off
 // the ladder it was built on and onto the display range.
 const code8=raw.map(code=>Math.max(0,Math.min(1023,tenBit?code/4:code)));
 const ladder=meterLiveCodeRangeForStep(step);
 return code8.map(code=>toDisplay(ladder.span>0?((code-ladder.min)/ladder.span):0));
}

// Pick the code scale the measured value must be expressed on so that it is
// actually comparable to the patch target code beside it. Inferred from the
// patch itself rather than from the transport flag: Dolby Vision runs an RGB
// FULL transport but its patch ladder is limited-coded, and the panel decodes
// it as limited. Hardware, DV 15%: the patch code is 49, whose limited decode
// predicts 11.30 cd/m2 and whose full decode would predict 19.30 -- the panel
// measured 11.13. Trusting meterPatchUsesVideoRange() (i.e. the transport)
// put the measured number on a full 0..255 scale against a limited-coded
// target, so the two were never on the same scale.
function meterLiveCodeRangeForStep(step){
 const fallback=(typeof meterPatchUsesVideoRange==='function'&&meterPatchUsesVideoRange())
  ? {min:16,span:219} : {min:0,span:255};
 if(!step) return fallback;
 const pct=[step.signal_r_pct,step.stimulus,step.ire]
  .map(Number).find(v=>Number.isFinite(v)&&v>0);
 const codeRaw=Number(step.r_code!=null?step.r_code:step.r);
 if(!Number.isFinite(pct)||!Number.isFinite(codeRaw)) return fallback;
 const inputMax=Number(step.input_max);
 const code=(inputMax===1023||codeRaw>255)?codeRaw/4:codeRaw;
 const f=Math.max(0,Math.min(1,pct/100));
 // Whichever standard range better predicts this patch's own code is the
 // ladder the patch was built on.
 return (Math.abs(code-(16+219*f)) <= Math.abs(code-(255*f)))
  ? {min:16,span:219} : {min:0,span:255};
}

// Convert an absolute measured channel luminance back to the signal that
// produces it on the ACTIVE PQ target curve. This is an inverse-EOTF readout,
// not a normalization against panel peak. Scaling every channel by
// 10000/measured_white makes only the endpoints look right and badly inflates
// every intermediate value (2.4 cd/m2 became PQ code 103 instead of 51 on a
// ~700-nit display).
//
// Inverting meterGreyTargetLuminance also preserves the selected BT.2390
// roll-off. DV Absolute hard-clips at its measured peak, so retain the explicit
// 100% reference-white endpoint rather than choosing the first code on that
// flat clipped section.
function meterLivePqEquivalentSignal(nits,step){
 const y=Math.max(0,Number(nits)||0);
 if(!(y>0)) return 0;
 if(typeof meterIsReferenceWhiteStep==='function'&&meterIsReferenceWhiteStep(step)) return 1;
 const reference=Math.max(0.0001,meterColorSeriesReferenceNits());
 const peak=(typeof meterGreyTargetPeak==='function')
  ? Math.max(0.0001,meterGreyTargetPeak(reference))
  : reference;
 const black=(typeof meterBlackReadingY==='function')?Math.max(0,Number(meterBlackReadingY())||0):0;
 const targetAt=signal=>meterGreyTargetLuminance(signal*100,peak,black,null);
 const top=Number(targetAt(1));
 if(Number.isFinite(top)&&y>=top) return 1;
 let lo=0,hi=1;
 for(let i=0;i<36;i++){
  const mid=(lo+hi)/2;
  const target=Number(targetAt(mid));
  if(Number.isFinite(target)&&target<y) lo=mid;
  else hi=mid;
 }
 return Math.max(0,Math.min(1,(lo+hi)/2));
}

function meterLiveXyzRgbCodes(xyz,step){
 if(!xyz) return null;
 const linear=xyzToLinRgb(xyz.X,xyz.Y,xyz.Z,meterAnalysisGamut().xyzToRgb);
 let signal;
 if(meterChartIsPq() && (!meterChartIsDv() || meterDvUsesPqTargetCurve())){
  signal=linear.map(channel=>meterLivePqEquivalentSignal(channel,step));
 }else if(meterChartIsHlg()){
  const peak=Math.max(1,meterColorSeriesReferenceNits());
  signal=linear.map(channel=>hlgInverseEotfSignal(Math.max(0,channel),meterChartMasterMin(),peak));
 }else{
  const reference=Math.max(0.0001,meterColorSeriesReferenceNits());
  // DV outside the PQ target curve encodes linear -> signal with 2.2, the
  // same convention meterEncodeColorCheckerLinear() uses for DV. It must NOT
  // go through meterTargetLinearToSignal(), which returns the fraction
  // UNENCODED for DV because its other callers hand it an already-encoded
  // signal fraction. Skipping the encode compared linear light against a
  // gamma-encoded target code: at DV 15% the measured value rendered as 4
  // beside a target of 49 (255 * 11.13/726.8 = 3.9) while luminance and x,y
  // were both on target.
  const dvGamma22=(typeof meterChartIsDv==='function'&&meterChartIsDv())
   && !(typeof meterDvUsesPqTargetCurve==='function'&&meterDvUsesPqTargetCurve());
  // A raised Target Black reshapes the BT.1886 encode, but
  // meterTargetLinearToSignal is a bare pow(c,1/2.4) with no Lb term -- and it
  // must stay that way, because meterEncodeColorCheckerLinear /
  // meterEncodeSaturationLinear use it to author the codes actually SENT to
  // the display. So do the black-aware encode here, in the readout only.
  // Without it the round trip cancelled the error: 0.66 cd/m2 measured against
  // a 10.02 cd/m2 target came back as code 38 beside a target of 38.
  // Target White needs nothing extra -- meterColorSeriesReferenceNits() already
  // prefers a manual override over the measured peak.
  const Lb=(typeof meterChartBlackLevel==='function')
   ?Math.max(0,Number(meterChartBlackLevel(Array.isArray(meterReadings)?meterReadings:[]))||0):0;
  const blackAware=!dvGamma22 && Lb>0.001
   && (typeof meterBt1886BlackAwareMetricsActive==='function') && meterBt1886BlackAwareMetricsActive();
  signal=linear.map(channel=>{
   if(blackAware) return meterGreyInverseEotfSignalFromLuminance(Math.max(0,channel),reference,Lb);
   const frac=Math.max(0,channel)/reference;
   return dvGamma22
    ? Math.pow(Math.max(0,Math.min(1,frac)),1/2.2)
    : meterTargetLinearToSignal(frac);
  });
 }
 // Put the calculated measured RGB on the SAME scale meterLiveTargetRgbCodes
 // uses for the target beside it -- the operator's selected range -- or the two
 // columns are not comparable. Previously both sides used the ladder-inferred
 // range, which is why an RGB FULL run reported 235/235 at 100% and 16/16 at 0%.
 const range=meterLiveDisplayCodeRange();
 return signal.map(value=>Math.round(range.min+range.span*Math.max(0,Math.min(1,value))));
}

function meterLiveMeasuredRgbCodes(reading){
 return meterLiveXyzRgbCodes(meterReadingXYZ(reading),
  (typeof meterCanonicalSeriesStep==='function'?(meterCanonicalSeriesStep(reading)||reading):reading));
}

function meterLiveRgbMarkup(values){
 if(!values||values.length!==3) return '--';
 return '<span class="r">'+values[0]+'</span>, <span class="g">'+values[1]+'</span>, <span class="b">'+values[2]+'</span>';
}

function meterUpdateLiveReadingDetails(src,isMeasured){
 const set=(id,value)=>{ const el=document.getElementById(id); if(el) el.textContent=value; };
 const setRgb=(id,value)=>{ const el=document.getElementById(id); if(el) el.innerHTML=meterLiveRgbMarkup(value); };
 const target=src?meterTargetXYZForReading(src):null;
 const measured=isMeasured?meterReadingXYZ(src):null;
 const rgbLabel=document.getElementById('meterLiveRgbLabel');
 if(rgbLabel){
  const gamma=(typeof meterGreyTargetGammaSelection==='function')?String(meterGreyTargetGammaSelection()||'').toLowerCase():'';
  rgbLabel.textContent=(gamma==='st2084')?'RGB PQe':'RGB';
 }
 setRgb('meterLiveRgbMeasured',measured?meterLiveMeasuredRgbCodes(src):null);
 setRgb('meterLiveRgbTarget',src?meterLiveTargetRgbCodes(src):null);
 const xyzText=xyz=>xyz?[xyz.X,xyz.Y,xyz.Z].map(value=>Number(value).toFixed(3)).join(', '):'--';
 set('meterLiveXyzMeasured',xyzText(measured));
 set('meterLiveXyzTarget',xyzText(target));
 let measuredXy=null,targetXy=null;
 if(measured){ const sum=measured.X+measured.Y+measured.Z; if(sum>0) measuredXy={x:measured.X/sum,y:measured.Y/sum}; }
 if(target){ const sum=target.X+target.Y+target.Z; if(sum>0) targetXy={x:target.X/sum,y:target.Y/sum}; }
 set('meterLiveDeltaXy',(measuredXy&&targetXy)?((measuredXy.x-targetXy.x>=0?'+':'')+(measuredXy.x-targetXy.x).toFixed(4)+' / '+(measuredXy.y-targetXy.y>=0?'+':'')+(measuredXy.y-targetXy.y).toFixed(4)):'--');
 set('meterLiveDeltaY',(measured&&target)?((measured.Y-target.Y>=0?'+':'')+(measured.Y-target.Y).toFixed(2)+' cd/m²'):'--');
 if(measured){
  const denominator=measured.X+15*measured.Y+3*measured.Z;
  set('meterLiveUvMeasured',denominator>0?((4*measured.X/denominator).toFixed(4)+' / '+(9*measured.Y/denominator).toFixed(4)):'--');
 }else set('meterLiveUvMeasured','--');
 let deltaE=null;
 if(measured){ try{ deltaE=meterSeriesDeltaEForDisplay(src,meterGreyRefMode()); }catch(e){} }
 set('meterLiveDeltaE',Number.isFinite(deltaE)?deltaE.toFixed(2):'--');
}

function updateLiveReading(reading){
 // Unread step shells: never invent live measured values from patch codes.
 if(!reading||reading._unreadStep||reading._presetStep||!meterReadingIsRealMeasurement(reading)){
  meterClearLiveReading(reading||meterCurrentPatchStep);
  return;
 }
 meterNormalizeMeasuredReading(reading);
 if((meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')&&_colorDetailPinned&&_selectedColorReadingName&&Array.isArray(meterReadings)){
  // Only pin-override to a REAL sample for the selected name — not a stale
  // leftover or a different series.
  const selected=meterReadings.find(r=>r&&r.name===_selectedColorReadingName&&meterReadingIsRealMeasurement(r));
  if(selected) reading=selected;
 }
 const measured=meterReadingXYZ(reading);
 document.getElementById('meterLiveReading').style.display='';
 const liveLabel=document.getElementById('meterLiveReadingLabel');
 if(liveLabel) liveLabel.textContent=meterLiveReadingLabel(reading);
 document.getElementById('meterLum').textContent=measured&&measured.Y!=null?measured.Y.toFixed(2):'--';
 // CCT (correlated colour temperature) is only meaningful for near-neutral
 // (greyscale/white) patches. For a saturated colour patch the "temperature"
 // is a nonsense number, so suppress it rather than mislead the operator.
 const cctEl=document.getElementById('meterCCT');
 if(cctEl) cctEl.textContent=(reading.cct&&meterReadingIsGreyscale(reading))?reading.cct:'--';
 document.getElementById('meterCIEx').textContent=(measured&&reading.x!=null)?reading.x.toFixed(4):'--';
 document.getElementById('meterCIEy').textContent=(measured&&reading.y!=null)?reading.y.toFixed(4):'--';
 meterUpdateLiveReadingTargets(reading);
 meterUpdateLiveReadingDetails(reading,true);

 const liveRgb=meterLiveRgbData(reading);
 drawRGBBars(liveRgb);
 const rgbDeltas=meterRgbDeltasForLive(reading,liveRgb);
 meterRenderGreyTvControls(reading);
 drawDeltaBarsVertical('meterRGBCanvasGrey',rgbDeltas);
 drawDeltaBarsVertical('meterRGBCanvasColor',rgbDeltas);
 const xyyDeltas=meterXYYDeltasForLive(reading);
 drawDeltaBarsVertical('meterXYYCanvasColor',xyyDeltas);
}

function meterReadingPatchLabel(reading){
 if(!reading) return 'Patch Reading';
 const name=String(reading.name||'').trim();
 if(name) return name;
 const ire=Number(reading.ire);
 if(Number.isFinite(ire)) return meterFormatPercentValue(ire)+'%';
 return 'Patch Reading';
}

function meterLiveReadingLabel(reading){
 const current=meterCurrentPatchStep?(meterCanonicalSeriesStep(meterCurrentPatchStep)||meterCurrentPatchStep):null;
 const live=reading?(meterCanonicalSeriesStep(reading)||reading):null;
 if(current&&live){
  const currentKey=meterStepNameKey(current);
  const liveKey=meterStepNameKey(live);
  if((currentKey&&liveKey&&currentKey===liveKey)||((current.name||'')&&((current.name||'')===(live.name||'')))){
   return meterReadingPatchLabel(current);
  }
 }
 return meterReadingPatchLabel(live||current||reading);
}

function meterMeasuredContrastRatio(readings){
 const gs=(Array.isArray(readings)?readings:[]).map(r=>meterNormalizeOledBlackReading(r))
  .filter(r=>r&&meterReadingIsGreyscale(r)&&meterReadingHasLuminance(r));
 if(gs.length===0) return null;
 const hasIre=(r,target)=>{
  const plot=(typeof meterReadingPlotIre==='function')?meterReadingPlotIre(r):null;
  const candidates=[plot,r&&r.plot_ire,r&&r.nominal_ire,r&&r.target_ire,r&&r.ire,r&&r.stimulus];
  return candidates.some(value=>{
   const ire=Number(value);
   return Number.isFinite(ire)&&Math.abs(ire-target)<0.05;
  });
 };
 const white=gs.find(r=>hasIre(r,100) || String(r&&r.name||'').toLowerCase()==='white') || null;
 const black=gs.find(r=>hasIre(r,0)) || null;
 const whiteY=white?meterReadingLuminanceNits(white):null;
 const blackY=black?meterReadingLuminanceNits(black):null;
 if(!(whiteY>0) || blackY==null || blackY<0) return null;
 if(blackY===0) return Infinity;
 return whiteY/blackY;
}

function meterFormatContrastRatio(value){
 if(value==null) return 'NA';
 if(!Number.isFinite(value)) return 'Infinite';
 return Math.max(1,Math.round(value)).toLocaleString()+':1';
}

function meterLuminanceContrastText(readings){
 const contrast=(meterActiveSeriesType==='greyscale'||!meterActiveSeriesType)
  ? meterMeasuredContrastRatio(readings)
  : null;
 return meterFormatContrastRatio(contrast);
}

function drawGammaContrastLabel(ctx,chart,readings){
 if(!ctx||!chart) return;
 ctx.fillStyle=pgThemeColor('--chart-annotation','#aaa');
 ctx.font='11px sans-serif';
 ctx.textAlign='right';
 ctx.fillText('Contrast Ratio: '+meterLuminanceContrastText(readings||[]),ctx.w-chart.pad.r,chart.pad.t+14);
}

// Convert the meterLiveRgbData() output into a uniform "delta from target"
// shape for the vertical live bar chart. Target is always the center line
// (0) regardless of whether the source was balance (100-based) or color
// delta (already 0-based).
function meterRgbDeltasForLive(reading,bal,includeDeltaE){
 if(!bal) return null;
 const isDelta=(bal.mode==='delta');
 const center=isDelta?0:100;
 const entries=[
  {key:'R',label:'R',color:'#f44',v:(bal.R!=null)?bal.R-center:null,labelV:(bal.R!=null)?(isDelta?(bal.R-center):bal.R):null,showPlus:isDelta},
  {key:'G',label:'G',color:'#4caf50',v:(bal.G!=null)?bal.G-center:null,labelV:(bal.G!=null)?(isDelta?(bal.G-center):bal.G):null,showPlus:isDelta},
  {key:'B',label:'B',color:'#42a5f5',v:(bal.B!=null)?bal.B-center:null,labelV:(bal.B!=null)?(isDelta?(bal.B-center):bal.B):null,showPlus:isDelta}
 ];
 if(includeDeltaE&&reading){
  let de=null;
  try{ de=meterGreyDeltaResult(reading,meterGreyRefMode(),meterDeltaEForm(),meterGrayWorldWeight()).value; }catch(e){}
  if(Number.isFinite(de)) entries.push({key:'DE',label:'ΔE',color:de<1?'#4caf50':de<3?'#ff9800':'#ff4444',v:de,labelV:de,showPlus:false,unit:'',decimals:2});
  else entries.push({key:'DE',label:'ΔE',color:'#888',v:null,labelV:null,showPlus:false,unit:'',decimals:2});
 }
 return {title:'RGB Δ',unit:'%',entries,decimals:2,minHalfRange:5,scaleHeadroom:1.6};
}

// Build xy/Y deltas vs. the active target for the live bar chart. Uses the
// same measured-minus-target form as the RGB delta bars so the two charts
// read the same way: bar above target = over, below = under. Δx and Δy are
// scaled ×1000 for visibility; ΔY is normalized to target Y for color/sat
// patches and to white Y for greyscale, matching HCFR-style interpretation.
// The bar geometry remains centered on zero error, while footer labels use the
// same base-100 presentation as RGB balance (for example -6.33 -> 93.67%).
// Falls back to null when no target is known (manual read with no series loaded).
function meterXYYDeltasForLive(reading){
 if(!reading) return null;
 const measured=meterReadingXYZ(reading);
 const sum=measured?(measured.X+measured.Y+measured.Z):0;
 const mx=(measured&&sum>0)?(measured.X/sum):null;
 const my=(measured&&sum>0)?(measured.Y/sum):null;
 const mY=(measured&&measured.Y!=null)?measured.Y:null;
 let tx=null,ty=null,tY=null;
 const isColor=(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations');
 let ref=null;
 if(isColor){
  try{
   const txyz=(typeof meterTargetXYZForReading==='function')?meterTargetXYZForReading(reading):null;
   if(txyz){
    tY=txyz.Y;
    const sum=txyz.X+txyz.Y+txyz.Z;
    if(sum>0){
     tx=txyz.X/sum;
     ty=txyz.Y/sum;
    }
   }
   if(typeof meterColorReferenceNits==='function') ref=meterColorReferenceNits();
  }catch(e){}
 } else {
  // Greyscale: target = configured target white chromaticity, target Y from EOTF at this IRE.
  const wp=(typeof meterTargetWhitePoint==='function')?meterTargetWhitePoint():D65;
  tx=wp.x;
  ty=wp.y;
  if(meterWhiteReading&&meterWhiteReading.Y>0&&reading.ire!=null){
   const peak=meterGreyTargetPeak(meterWhiteReading.Y);
   const black=meterBlackReadingY();
   try{ tY=meterGreyTargetLuminance(reading.ire,peak,black,reading.r_code); }catch(e){}
   ref=peak;
  }
 }
 // Δx, Δy scaled ×1000 so they sit in a similar magnitude band as ΔY%.
 const dx=(mx!=null&&tx!=null)?(mx-tx)*1000:null;
 const dy=(my!=null&&ty!=null)?(my-ty)*1000:null;
 // ΔY as % of target Y for color patches, or % of measured white for grey.
 let dY=null;
 if(mY!=null&&tY!=null){
  if(isColor){
   dY=(Math.abs(tY)>1e-9)?((mY-tY)/tY*100):null;
  } else if(ref>0){
   dY=((mY-tY)/ref*100);
  }
 }
 if(dx==null&&dy==null&&dY==null) return null;
 const entries=[
  {key:'x',label:'x',color:'#f4b',v:dx,labelV:dx==null?null:100+dx,unit:'%',showPlus:false},
  {key:'y',label:'y',color:'#fd4',v:dy,labelV:dy==null?null:100+dy,unit:'%',showPlus:false},
  {key:'Y',label:'Y',color:'#8df',v:dY,labelV:dY==null?null:100+dY,unit:'%',showPlus:false}
 ];
 return {title:'xyY',unit:'',entries,decimals:2,minHalfRange:5,scaleHeadroom:1.6};
}

// Generic vertical delta-bar chart. Every bar extends up/down from a
// center line that represents the target (delta = 0). Positive bars
// above, negative bars below. Each entry has its own autoscale based on
// the data magnitude so bars stay readable.
function drawDeltaBarsVertical(canvasId,spec){
 const c=document.getElementById(canvasId);
 if(!c) return;
 const rect=c.getBoundingClientRect();
 if(rect.width<2||rect.height<2) return;
 const dpr=pgCanvasPixelRatio();
 c.width=rect.width*dpr;
 c.height=rect.height*dpr;
 const ctx=c.getContext('2d');
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.imageSmoothingEnabled=false;
 const W=rect.width,H=rect.height;
 ctx.fillStyle=pgThemeColor('--chart-bg','#0d0d15');ctx.fillRect(0,0,W,H);
 if(!spec||!spec.entries||!spec.entries.length){
  ctx.fillStyle='#555';ctx.font='10px sans-serif';ctx.textAlign='center';
  ctx.fillText('--',W/2,H/2);
  return;
 }
 // Only the compact greyscale companion switches to horizontal on phones.
 // The color-series RGB companion remains the same vertical three-bar chart
 // in every layout; its phone wrapper receives enough height in responsive CSS.
 const useHorizontal=canvasId==='meterRGBCanvasGrey'&&window.matchMedia&&window.matchMedia('(max-width:700px)').matches;
 const rgbPercentageBars=canvasId==='meterRGBCanvasGrey'||canvasId==='meterRGBCanvasColor'||canvasId==='meterXYYCanvasColor'
  ||canvasId==='meterTwoPointLowCanvas'||canvasId==='meterTwoPointHighCanvas';
 const themedColorBars=canvasId==='meterRGBCanvasColor'||canvasId==='meterXYYCanvasColor'
  ||canvasId==='meterTwoPointLowCanvas'||canvasId==='meterTwoPointHighCanvas';
 const padTop=themedColorBars?28:18,padBot=themedColorBars?30:24,padL=6,padR=6;
 const plotH=H-padTop-padBot;
 const plotW=W-padL-padR;
 const labelColor=pgThemeColor('--chart-label','#d7e1f3');
 // Shared autoscale across all entries so the center-line is visually consistent.
 const niceDeltaHalfRange=(value)=>{
  if(!(value>0)) return 1;
  const magnitude=Math.pow(10,Math.floor(Math.log10(value)));
  const normalized=value/magnitude;
  const step=normalized<=1?1:(normalized<=2?2:(normalized<=5?5:10));
  return step*magnitude;
 };
 const minHalfRange=Math.max(1e-6,spec.minHalfRange||1);
 let maxAbs=0;
 spec.entries.forEach(e=>{ if(e.v!=null) maxAbs=Math.max(maxAbs,Math.abs(e.v)); });
 const headroom=(spec.scaleHeadroom!=null)?spec.scaleHeadroom:1.6;
 const halfRange=Math.max(minHalfRange,niceDeltaHalfRange(maxAbs*headroom));
 const lo=-halfRange,hi=halfRange;
 if(useHorizontal){
  const rowH=plotH/spec.entries.length;
  const padLabel=16;
  const x0=padL+padLabel;
  const x1=W-padR-30;
  const cx=x0+(0-lo)/(hi-lo)*(x1-x0);
  const cxPx=Math.round(cx)+0.5;
  ctx.strokeStyle=labelColor;ctx.lineWidth=1.2;
  ctx.beginPath();ctx.moveTo(cxPx,padTop);ctx.lineTo(cxPx,H-padBot);ctx.stroke();
  spec.entries.forEach((e,i)=>{
   const cy=padTop+rowH*i+rowH/2;
   ctx.fillStyle=labelColor;ctx.font='bold 11px sans-serif';ctx.textAlign='left';ctx.textBaseline='middle';
   ctx.fillText(e.label,padL,cy);
   if(e.v==null){
    ctx.textAlign='right';
    ctx.fillText('--',W-padR,cy);
    return;
   }
   const xV=x0+(e.v-lo)/(hi-lo)*(x1-x0);
   const left=Math.round(Math.min(cx,xV));
   const width=Math.max(Math.round(Math.abs(xV-cx)),1);
   const barH=Math.max(6,Math.min(14,rowH*0.42));
   ctx.fillStyle=e.color;ctx.globalAlpha=0.88;
   ctx.fillRect(left,Math.round(cy-barH/2),width,Math.round(barH));
   ctx.globalAlpha=1;
   ctx.beginPath();ctx.arc(Math.round(xV),Math.round(cy),3,0,Math.PI*2);ctx.fillStyle=e.color;ctx.fill();
   const dec=(e.decimals!=null)?e.decimals:((spec.decimals!=null)?spec.decimals:1);
   const labelVal=(e.labelV!=null)?e.labelV:e.v;
   const prefix=(e.showPlus===false)?'':(labelVal>0?'+':(labelVal<0?'':''));
   ctx.fillStyle=rgbPercentageBars?'#fff':labelColor;ctx.font=(rgbPercentageBars?'bold 11px':'10px')+' sans-serif';ctx.textAlign='right';
   ctx.fillText(prefix+labelVal.toFixed(dec),W-padR,cy);
  });
  return;
 }
 function valToY(v){return padTop+(hi-v)/(hi-lo)*plotH;}
 const cy=valToY(0);
 const cyPx=Math.round(cy)+0.5;
 // Bars
 const slot=plotW/spec.entries.length;
 const trackW=themedColorBars?42:Math.max(20,Math.min(38,slot*0.72));
 const barW=themedColorBars?20:Math.min(28,slot*0.74);
 const roundedRect=(x,y,w,h,r)=>{
  const rr=Math.max(0,Math.min(r,w/2,h/2));
  ctx.beginPath();ctx.moveTo(x+rr,y);ctx.lineTo(x+w-rr,y);ctx.quadraticCurveTo(x+w,y,x+w,y+rr);
  ctx.lineTo(x+w,y+h-rr);ctx.quadraticCurveTo(x+w,y+h,x+w-rr,y+h);ctx.lineTo(x+rr,y+h);
  ctx.quadraticCurveTo(x,y+h,x,y+h-rr);ctx.lineTo(x,y+rr);ctx.quadraticCurveTo(x,y,x+rr,y);ctx.closePath();
 };
 if(!themedColorBars){
  ctx.strokeStyle=labelColor;ctx.lineWidth=1.4;
  ctx.beginPath();ctx.moveTo(padL,cyPx);ctx.lineTo(W-padR,cyPx);ctx.stroke();
 }
 spec.entries.forEach((e,i)=>{
  const cx=padL+slot*i+slot/2;
  if(themedColorBars){
   const trackLeft=Math.round(cx-trackW/2);
   ctx.fillStyle=pgThemeColor('--meter-bar-track','#10131d');
   roundedRect(trackLeft,padTop,trackW,plotH,6);ctx.fill();
   ctx.fillStyle=pgThemeColor('--meter-bar-zero','rgba(255,255,255,.28)');
   ctx.fillRect(trackLeft+6,Math.round(cy),trackW-12,1);
   ctx.fillStyle=e.color;ctx.font='bold 11px sans-serif';ctx.textAlign='center';ctx.textBaseline='alphabetic';
   ctx.fillText(e.label,Math.round(cx),14);
  }
  if(e.v==null){
   ctx.fillStyle='#555';ctx.font='10px sans-serif';ctx.textAlign='center';
   ctx.fillText('--',Math.round(cx),themedColorBars?H-6:cyPx+4);
   if(!themedColorBars){ctx.fillStyle=labelColor;ctx.font='bold 11px sans-serif';ctx.fillText(e.label,Math.round(cx),H-padBot+15);}
   return;
  }
  const yV=valToY(e.v);
  const yVPx=Math.round(yV);
  const left=Math.round(cx-barW/2);
  const top=Math.round(Math.min(cy,yV));
  const width=Math.max(Math.round(barW),1);
  const height=Math.max(Math.round(Math.abs(yV-cy)),1);
  ctx.save();
  ctx.fillStyle=e.color;ctx.globalAlpha=0.9;
  if(themedColorBars){ctx.shadowColor=e.color;ctx.shadowBlur=8;roundedRect(left,top,width,height,3);ctx.fill();}
  else {ctx.fillRect(left,top,width,height);ctx.beginPath();ctx.arc(Math.round(cx),yVPx,3,0,Math.PI*2);ctx.fill();}
  ctx.restore();
  // Themed color-series and 2-point RGB values use the same fixed footer row
  // as greyscale RGB balance instead of following the moving bar endpoint.
  if(!themedColorBars){ctx.fillStyle=labelColor;ctx.font='bold 11px sans-serif';ctx.textAlign='center';ctx.fillText(e.label,Math.round(cx),H-padBot+15);}
  ctx.fillStyle=rgbPercentageBars?'#fff':labelColor;ctx.font=(rgbPercentageBars?'bold 11px':'10px')+' sans-serif';ctx.textAlign='center';
  const dec=(e.decimals!=null)?e.decimals:((spec.decimals!=null)?spec.decimals:1);
  const labelVal=(e.labelV!=null)?e.labelV:e.v;
  const prefix=(e.showPlus===false)?'':(labelVal>0?'+':(labelVal<0?'':''));
  let labelY=themedColorBars?H-6:(e.v<0 ? (yVPx+16) : (yVPx-8));
  if(!themedColorBars&&e.v<0){
   if(labelY>H-padBot-4) labelY=H-padBot-4;
  } else if(!themedColorBars&&labelY<padTop) {
   labelY=padTop;
  }
  const unit=themedColorBars?((e.unit!=null)?e.unit:(spec.unit||'')):'';
  ctx.fillText(prefix+labelVal.toFixed(dec)+unit,Math.round(cx),labelY);
 });
}

function drawRGBBars(bal){
 const c=document.getElementById('meterRGBCanvas');
 if(!c) return;
 const rect=c.getBoundingClientRect();
 // The horizontal live-RGB canvas is retained as a hidden placeholder
 // for backward compatibility — the live data now renders into the
 // vertical companions inside the chart areas.
 if(rect.width<2||rect.height<2) return;
 const dpr=pgCanvasPixelRatio();
 c.width=rect.width*dpr;
 c.height=rect.height*dpr;
 const ctx=c.getContext('2d');
 ctx.scale(dpr,dpr);
 const W=rect.width,H=rect.height;
 ctx.fillStyle='#1d1d29';ctx.fillRect(0,0,W,H);
 if(!bal||bal.R==null||bal.G==null||bal.B==null){
  ctx.fillStyle='#555';ctx.font='10px sans-serif';ctx.textAlign='center';
  ctx.fillText('--',W/2,H/2);
  return;
 }
 const isDelta=bal&&bal.mode==='delta';
 const center=isDelta?0:100;
 const maxDev=Math.max(Math.abs((bal.R||0)-center),Math.abs((bal.G||0)-center),Math.abs((bal.B||0)-center),1);
 const halfRange=Math.max(isDelta?2:5,Math.ceil(maxDev/5)*5+(isDelta?1:2));
 const lo=center-halfRange,hi=center+halfRange;
 const labelW=20,barL=labelW+4,barR=W-40;
 const barW=barR-barL;
 function valToX(v){return barL+(v-lo)/(hi-lo)*barW;}
 // Gridlines at 5-unit intervals
 ctx.font='8px sans-serif';ctx.textAlign='center';ctx.fillStyle='#666';
 for(let g=Math.ceil(lo/5)*5;g<=hi;g+=5){
  const x=valToX(g);
  ctx.strokeStyle=g===center?'#888':'#2a2a3a';
  ctx.lineWidth=g===center?1.5:0.5;
  ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,H);ctx.stroke();
  ctx.fillStyle=g===center?'#aaa':'#555';
  ctx.fillText(g,x,H-1);
 }
 // Bars
 const channels=[{ch:'R',color:'#f44',v:bal.R},{ch:'G',color:'#4caf50',v:bal.G},{ch:'B',color:'#42a5f5',v:bal.B}];
 const barH=Math.min(12,(H-16)/3-2);
 const topPad=2;
 channels.forEach((c,i)=>{
  const cy=topPad+i*(barH+3)+barH/2;
  const x100=valToX(center);
  const xVal=valToX(c.v);
  // Bar from center to value
  const bx=Math.min(x100,xVal),bw=Math.abs(xVal-x100);
  ctx.fillStyle=c.color;
  ctx.globalAlpha=0.85;
  ctx.fillRect(bx,cy-barH/2,Math.max(bw,1),barH);
  ctx.globalAlpha=1;
  // Dot at value
  ctx.beginPath();ctx.arc(xVal,cy,3,0,Math.PI*2);ctx.fillStyle=c.color;ctx.fill();
  // Channel label
  ctx.fillStyle=c.color;ctx.font='bold 9px sans-serif';ctx.textAlign='right';
  ctx.fillText(c.ch,labelW,cy+3);
  // Value label at right
  ctx.fillStyle=pgThemeColor('--chart-annotation','#ccc');ctx.font='9px sans-serif';ctx.textAlign='left';
  const prefix=isDelta&&c.v>0?'+':'';
  ctx.fillText(prefix+c.v.toFixed(2)+'%',barR+4,cy+3);
 });
}

async function meterStartSingleReadWithTimeout(readPayload,timeoutMs,shouldCancel){
		 meterPingBusy=true;
	 // Raise the shared spectro setup modal in 'Working…' mode immediately so
	 // the operator sees feedback that the click registered while the backend
	 // boots the meter session (1-5+ s for a spectro cold start). The poll
	 // below replaces this with the actual setup step (calibrate_tile /
	 // position_screen) when the backend reports it, or hides the modal when
	 // the read completes without needing a setup step. Gated on the
	 // selected meter being a spectro so colorimeter users don't see the
	 // "Spectrophotometer Setup" modal flash on every read.
	 if(meterSelectedMeasurementRequiresReady()){
	  meterSpectroSetupApply({keepBusy:true,message:'Preparing the meter\u2026'},'/api/meter/setup/ack');
	 }
	 try{
	  const initR=await fetchJSON('/api/meter/read',{method:'POST',headers:{'Content-Type':'application/json'},
	   body:JSON.stringify(readPayload),_quiet:true,_timeoutMs:90000});
	  if(!initR) throw new Error('Meter read connection error');
	  if(initR&&initR.status==='error') throw new Error(initR.message||'Read failed');
	  const readResult=await meterPollRead(timeoutMs||180000,shouldCancel);
	  return readResult;
	 } finally {
	  meterPingBusy=false;
	  await meterRestoreStabilizationAfterMeasurement();
		 }
}

async function meterStartSingleRead(readPayload,shouldCancel){
 return meterStartSingleReadWithTimeout(readPayload,180000,shouldCancel);
}

function meterApplyReadStepPayload(readPayload,step){
 if(!readPayload||!step) return readPayload;
 const ire=Number(step.ire);
 if(Number.isFinite(ire)){
  readPayload.ire=ire;
  readPayload.stimulus=(step.stimulus!=null)?Number(step.stimulus):ire;
 }
 if(step.name!=null) readPayload.name=String(step.name);
 if(step.signal_r_pct!=null) readPayload.signal_r_pct=Number(step.signal_r_pct);
 if(step.signal_g_pct!=null) readPayload.signal_g_pct=Number(step.signal_g_pct);
 if(step.signal_b_pct!=null) readPayload.signal_b_pct=Number(step.signal_b_pct);
	 if(step.r!=null) readPayload.patch_r=step.r;
	 if(step.g!=null) readPayload.patch_g=step.g;
	 if(step.b!=null) readPayload.patch_b=step.b;
	 readPayload.input_max=meterStepInputMax(step);
	 return readPayload;
}

function meterStepInputMax(step){
 const explicit=Number(step&&step.input_max);
 if(Number.isFinite(explicit)&&explicit>0) return explicit;
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const isGreyStep=!!(step&&meterActiveSeriesType==='greyscale'&&meterSeriesStepIsGreyscale(step));
 if(isGreyStep&&meterUseLgAutoCal26(meterActiveSeriesPoints)&&mode==='sdr') return 1023;
 // 10-bit transport (HDR10/HLG/SDR 10-bit) emits 10-bit codes from
 // meterGreyCodeRange (0-1023 full, 64-940 limited). Without an explicit
 // step.input_max the server would interpret e.g. 0%->code 64 as 8-bit and
 // shift it to 256 (10-bit), which lifts black to ~22% signal. Mirror the
 // 26pt SDR branch for any greyscale step on a 10-bit transport.
 if(isGreyStep&&meterPatchBitDepth()===10) return 1023;
 return meterPatchInputMax();
}

function meterApplySingleReadResult(result,requestedStep){
 // meterReadResultOk also rejects a reading the meter session flagged as an
 // unusable all-zero (null_read). The else branch below already surfaces the
 // server's message, which for that case explains what to check.
 if(meterReadResultOk(result)){
  const rd=result.readings[0];
  meterNormalizeMeasuredReading(rd);
  // Only commit the result if the user is still on the patch this read was
  // fired against. If they switched mid-read, the meter integrated photons
  // from a different patch; storing/displaying the result would be wrong
  // either way.
  const stillOnRequested=!requestedStep||!meterCurrentPatchStep||meterStepNameKey(meterCurrentPatchStep)===meterStepNameKey(requestedStep);
  if(stillOnRequested){
   // If a series is loaded and a patch is selected, store reading in series results
   if(meterSeriesSteps&&requestedStep){
    meterUpsertSeriesReading(rd,requestedStep);
    // Auto-detect white reference from the canonical stamped series reading.
    const white=meterFindSeriesWhiteReading(meterReadings);
    if(white) meterWhiteReading=white;
    // Update charts and thumbnails
    const completedIres=new Set();
    meterReadings.forEach(r=>{if(r.luminance!=null) completedIres.add(meterStepNameKey(r));});
    const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
    const sorted=isColor?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
    drawAllCharts(sorted);
    meterCacheSeriesState('complete');
    const sortedSteps=isColor?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
    meterBuildPatchThumbs(sortedSteps,completedIres,null);
   }
    updateLiveReading(rd);
   toast('Reading: '+rd.luminance.toFixed(2)+' cd/m\\u00B2');
  }
 } else {
  toast(result&&result.message?result.message:'Measurement failed',true);
 }
}

function meterIsReferenceWhiteStep(step){
 if(!step||!meterSeriesStepIsGreyscale(step)) return false;
 const name=String(step.name||'').trim().toLowerCase();
 const ire=Number(step.ire);
 return (Number.isFinite(ire)&&Math.abs(ire-100)<0.001)||name==='white'||name==='100%';
}

function meterHasMeasuredReferenceWhite(){
 const white=meterFindMeasuredWhiteReading();
 const xyz=white&&!white.synthetic_target?meterReadingXYZ(white):null;
 return !!(xyz&&xyz.Y>0);
}

function meterFindReferenceWhiteStepForRead(step){
 if(!step||!meterSeriesStepIsGreyscale(step)) return null;
 const steps=Array.isArray(meterSeriesSteps)?meterGreyscaleSeriesSteps(meterSeriesSteps):[];
 const white=steps.find(meterIsReferenceWhiteStep);
 if(white) return meterClonePatchStep(meterFreshSeriesStep(white)||white);
 const code=meterCodeFromSignalPercent(100);
 return {ire:100,stimulus:100,signal_r_pct:100,signal_g_pct:100,signal_b_pct:100,r:code,g:code,b:code,name:'100%',series_type:'greyscale'};
}

function meterReferenceWhitePromptStep(requestedStep){
 if(!requestedStep||!meterSeriesStepIsGreyscale(requestedStep)) return null;
 if(meterIsReferenceWhiteStep(requestedStep)) return null;
 if(meterHasMeasuredReferenceWhite()) return null;
 return meterFindReferenceWhiteStepForRead(requestedStep);
}

function meterConfirmReferenceWhiteRead(requestedStep,whiteStep){
 if(!requestedStep||!whiteStep) return false;
 const targetLabel=meterReadingPatchLabel(requestedStep);
 const whiteLabel=meterReadingPatchLabel(whiteStep);
 return window.confirm('No measured 100% white reference is available for this greyscale chart.\n\nRead '+whiteLabel+' first, then return to '+targetLabel+'?\n\nCancel will read '+targetLabel+' without a reference white.');
}

// Resolve the current step's expected target luminance through the same target
// helpers used by the charts. A neutral step needs a real stimulus/IRE (or
// explicit target metadata); otherwise a missing target could look like black.
function meterExpectedTargetYForReadStep(step){
 if(!step||typeof step!=='object') return null;
 try{
  if(step.target_Y!=null){
   const direct=Number(step.target_Y);
   if(Number.isFinite(direct)&&direct>=0) return direct;
   return null;
  }
  if(step.dv_absolute_target_y!=null){
   const direct=Number(step.dv_absolute_target_y);
   if(Number.isFinite(direct)&&direct>=0) return direct;
   return null;
  }
  if(step.custom_target_nits!=null){
   const custom=Number(step.custom_target_nits);
   if(Number.isFinite(custom)&&custom>0) return custom;
   return null;
  }
  if(typeof meterSeriesStepIsGreyscale==='function'&&meterSeriesStepIsGreyscale(step)){
   const targetPosition=[step.target_ire,step.analysis_ire,step.stimulus,step.ire]
    .map(Number).find(Number.isFinite);
   const targetYn=(step.target_Yn!=null)?Number(step.target_Yn):NaN;
   if(!Number.isFinite(targetPosition)&&!(Number.isFinite(targetYn)&&targetYn>=0)) return null;
   if(typeof meterGreyChartTargetXYZForReading!=='function') return null;
   const target=meterGreyChartTargetXYZForReading(step);
   const y=Number(target&&target.Y);
   if(y===0&&((Number.isFinite(targetYn)&&targetYn>0)||(Number.isFinite(targetPosition)&&targetPosition>0))) return null;
   return (Number.isFinite(y)&&y>=0)?y:null;
  }
  const hasTargetMeta=(step.target_Yn!=null&&Number.isFinite(Number(step.target_x))&&Number.isFinite(Number(step.target_y))
   &&Number(step.target_y)>0&&Number.isFinite(Number(step.target_Yn))&&Number(step.target_Yn)>=0)
   ||(step.dv_absolute_target_y!=null&&Number.isFinite(Number(step.dv_absolute_target_y)));
  if(!hasTargetMeta||typeof meterTargetXYZForReading!=='function') return null;
  const target=meterTargetXYZForReading(step);
  const y=Number(target&&target.Y);
  if(y===0&&((step.target_Yn!=null&&Number(step.target_Yn)>0)||(step.dv_absolute_target_y!=null&&Number(step.dv_absolute_target_y)>0))) return null;
  return (Number.isFinite(y)&&y>=0)?y:null;
 }catch(e){ return null; }
}

// Return an explicit per-read mode. The selected a/aa/aaa mode is used only
// when expected target Y is valid and strictly below the configured trigger.
function meterEffectiveLowLightReadState(step){
 const selected=meterLowLightReadState();
 const trigger=Number(selected&&selected.trigger);
 const mode=String((selected&&selected.mode)||'off');
 const off={enabled:false,mode:'off',trigger:Number.isFinite(trigger)?trigger:0};
 if(!selected||!selected.enabled||!['a','aa','aaa'].includes(mode)||!(Number.isFinite(trigger)&&trigger>0)) return off;
 const expectedY=meterExpectedTargetYForReadStep(step);
 if(!(Number.isFinite(expectedY)&&expectedY>=0)) return off;
 return expectedY<trigger?{enabled:true,mode:mode,trigger:trigger}:off;
}

function meterBuildManualReadPayload(step,ctx){
 const opts=ctx||{};
 const readPayload=meterMeasurementSignalContext({
  display_type:opts.dtype,
  refresh_rate:opts.rr||undefined,
  delay_ms:opts.delay,
  // Mirror the wizard/CCSS override split into the manual-read payload so
  // step-level manual reads (used by autocal inner loops, chart reads, and
  // single-step tools) carry the operator's chosen CCSS, not just the tech.
  ccss_override:(opts&&typeof opts.ccss_override==='string')?opts.ccss_override:(typeof getCcssOverride==='function')?getCcssOverride():undefined,
  target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',
  target_gamma:meterAutoCalTargetGammaValue(),
  pattern_provider:meterCalibrationReadPatternProvider()
 });
 if(step){
  meterApplyReadStepPayload(readPayload,step);
  readPayload.patch_size=getMeterPatchSize();
  if(opts.patternSignalRange!=null) readPayload.signal_range=opts.patternSignalRange;
 }
 readPayload.require_device_ready=!!opts.requireDeviceReady;
 // Manual, single, and continuous reads always carry an explicit effective
 // mode selected from the current step's chart target. AutoCal and series
 // persist the raw card configuration separately and resolve their own steps.
 readPayload.low_light=meterEffectiveLowLightReadState(step);
 return readPayload;
}

// Relocate meter-settings popover contents at runtime (delay + refresh).
// Display Type and Meter Profile stay together in the card header.
// Idempotent: safe to call more than once.
function meterRelocateProfileControls(){
 const profileCol=document.getElementById('meterProfileHeaderCol');
 const slot=document.getElementById('meterProfileRelocSlot');
 if(!profileCol||!slot) return;
 const ccssRow=document.querySelector('.meter-ccss-profile-row');
 if(ccssRow&&ccssRow.parentElement!==profileCol) profileCol.appendChild(ccssRow);
 const delay=document.getElementById('meterDelay');
 const delayField=delay?delay.closest('.field'):null;
 if(delayField&&delayField.parentElement!==slot) slot.appendChild(delayField);
 const refresh=document.getElementById('meterRefreshRate');
 const refreshField=refresh?refresh.closest('.field'):null;
 if(refreshField&&refreshField.parentElement!==slot) slot.appendChild(refreshField);
 meterUpdateProfileFieldVisibility();
}

// Keep the profile column in the header grid for every meter so the controls
// remain aligned. Spectrophotometers measure spectra directly, so disable the
// correction selector and explain why on the hoverable wrapper.
function meterUpdateProfileFieldVisibility(){
 const field=document.getElementById('meterProfileHeaderCol');
 if(!field) return;
 let isSpectro=false;
 try{
  const meter=meterFindByPort(meterSelectedMeasurementPort());
  isSpectro=!!(meter&&meterIsSpectrophotometer(meter));
 }catch(e){ isSpectro=false; }
 const explanation='Spectrophotometers measure spectral data directly and do not use CCSS or CCMX correction profiles.';
 field.style.display='';
 field.classList.toggle('is-spectro-disabled',isSpectro);
 field.title=isSpectro?explanation:'';
 const select=document.getElementById('meterCcssProfile');
 if(select){
  select.disabled=isSpectro;
  select.title=isSpectro?explanation:'';
 }
 try{ meterRefreshCcssAutoLabel(); }catch(e){}
}

// Read the current state of the calibration-card Low Light Handler
// gear. Returns null if the controls are not on the page (e.g. the
// card has not been rendered yet), or {enabled,mode,trigger} for the
// current gear state. Used by every meter read path (single read,
// autocal, series read) so the server gets a consistent payload.
// The mode is the Mode dropdown value (off/a/aa/aaa), consumed by
// meterLowLightFlags() and the server-side parser.
function meterLowLightReadState(){
 try{
  const enabled=document.getElementById('meterLowLightEnabled');
  const mode=document.getElementById('meterLowLightMode');
  const trigger=document.getElementById('meterLowLightTrigger');
  if(!enabled||!mode||!trigger) return null;
  if(!enabled.checked) return {enabled:false,mode:'off',trigger:0};
  const base=String(mode.value||'off');
  return {enabled:true,mode:base,trigger:Number(trigger.value)||5.0};
 }catch(e){ return null; }
}

// Completion beep for manually started series reads. Armed only by the
// operator's Read Series / Read Selection actions in meterRunSeries; single
// reads, continuous reads, Full AutoCal report series (which share the same
// series worker/poll) and the Build 3D LUT flow never arm it, and the
// Display Profiler drives its own worker via icc_profile.js so it never
// reaches the calibration-card poll at all.
const METER_SERIES_BEEP_KEY='pgen.meter.seriesBeep';
let meterSeriesBeepArmed=false;
let meterSeriesBeepAudioCtx=null;
function meterSeriesBeepEnabled(){
 const el=document.getElementById('meterSeriesBeepEnabled');
 return !!(el&&el.checked);
}
function meterSeriesBeepAudioContext(){
 try{
  const Ctx=window.AudioContext||window.webkitAudioContext;
  if(!Ctx) return null;
  if(!meterSeriesBeepAudioCtx) meterSeriesBeepAudioCtx=new Ctx();
  return meterSeriesBeepAudioCtx;
 }catch(e){ return null; }
}
// Browsers gate audio behind a user gesture. Priming from the start click
// (and from checking the box) resumes the context so the later completion
// beep is allowed to sound.
function meterSeriesBeepPrime(){
 const ctx=meterSeriesBeepAudioContext();
 if(ctx&&ctx.state==='suspended'){ try{ ctx.resume().catch(()=>{}); }catch(e){} }
}
function meterSeriesBeepPlay(){
 const ctx=meterSeriesBeepAudioContext();
 if(!ctx) return;
 const play=()=>{
  try{
   const t=ctx.currentTime+0.01;
   const tone=(freq,start,dur)=>{
    const osc=ctx.createOscillator();
    const gain=ctx.createGain();
    osc.type='sine';
    osc.frequency.value=freq;
    gain.gain.setValueAtTime(0.0001,start);
    gain.gain.exponentialRampToValueAtTime(0.25,start+0.015);
    gain.gain.setValueAtTime(0.25,start+dur-0.06);
    gain.gain.exponentialRampToValueAtTime(0.0001,start+dur);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(start);
    osc.stop(start+dur+0.02);
   };
   tone(880,t,0.18);
   tone(1318.5,t+0.2,0.22);
  }catch(e){}
 };
 if(ctx.state==='suspended'){ try{ ctx.resume().then(play).catch(()=>{}); }catch(e){} }
 else play();
}
function meterSeriesBeepToggleChanged(){
 const el=document.getElementById('meterSeriesBeepEnabled');
 try{ localStorage.setItem(METER_SERIES_BEEP_KEY,(el&&el.checked)?'1':'0'); }catch(e){}
 // Preview the beep on enable; the gesture also unlocks the audio context.
 if(el&&el.checked) meterSeriesBeepPlay();
}
function meterRestoreSeriesBeepPref(){
 const el=document.getElementById('meterSeriesBeepEnabled');
 if(!el) return;
 try{ el.checked=localStorage.getItem(METER_SERIES_BEEP_KEY)==='1'; }catch(e){}
}

// Calibration-card low-light handler: applies the selected spotread mode
// to reads whose expected target luminance is below the trigger. The mode
// is a spotread flag-set built by meterLowLightFlags(). Server-side
// default is off (no mode), so the single-read path is preserved when the
// handler is disabled or the body is missing.
const METER_LOW_LIGHT_KEY='pgen.meter.lowLight';
function meterSetLowLightHandler(){
 const enabled=document.getElementById('meterLowLightEnabled');
 const mode=document.getElementById('meterLowLightMode');
 const trigger=document.getElementById('meterLowLightTrigger');
 if(!enabled||!mode||!trigger) return;
 try{
  localStorage.setItem(METER_LOW_LIGHT_KEY,JSON.stringify({
   enabled:!!enabled.checked,
   mode:String(mode.value||'off'),
   trigger:Number(trigger.value)||5.0
  }));
 }catch(e){}
 try{ if(typeof saveMeterSettings==='function') saveMeterSettings(); }catch(e){}
}
function meterRestoreLowLightHandler(){
 const sel=document.getElementById('meterLowLightEnabled');
 const mode=document.getElementById('meterLowLightMode');
 const trigger=document.getElementById('meterLowLightTrigger');
 if(!sel||!mode||!trigger) return;
 let saved=null;
 try{ saved=JSON.parse(localStorage.getItem(METER_LOW_LIGHT_KEY)||'null'); }catch(e){ saved=null; }
 if(!saved||typeof saved!=='object') return;
 if(typeof saved.enabled==='boolean') sel.checked=saved.enabled;
 // Backward compat: older saves stored high-precision variants
 // (x, x_a, x_aa, x_aaa) in mode; the high-precision option has been
 // removed (it mapped to spotread -x = Yxy output, already always on,
 // a no-op for precision), so collapse those back to the base mode.
 let base=(typeof saved.mode==='string')?saved.mode:'off';
 if(base==='x'){ base='off'; }
 else if(base.indexOf('x_')===0){ base=base.slice(2); }
 if(Array.from(mode.options).some(o=>o.value===base)) mode.value=base;
 if(typeof saved.trigger==='number'&&saved.trigger>0) trigger.value=saved.trigger;
}

// Map the low-light mode value to the spotread flag set. Returns an
// empty string for 'off' (no flag). Spotread flags:
//   -Y a   = 2-read avg
//   -Y aa  = 3-read avg
//   -Y aaa = 5-read avg
function meterLowLightFlags(mode){
 const m=String(mode||'off');
 switch(m){
  case 'a':     return '-Y a';
  case 'aa':    return '-Y aa';
  case 'aaa':   return '-Y aaa';
  case 'off':   return '';
  default:      return '';
 }
}

// Target White / Target Black override state (white-peak and black-floor
// luminance used to compute target Y for reads and charts). Mirrors the
// Low Light Handler persistence pattern. When a "Use measured" checkbox is
// checked the matching number input is disabled (greyed) and the measured
// reference is used internally; uncheck + enter a value to force that
// reference for all read targets (charts, series, autocal). Free under every
// target gamma (BT.1886, power 2.2/2.4, sRGB, ST 2084) — raised black under
// pure power is not the same curve as BT.1886 with the same Lb.
const METER_TARGET_LEVELS_KEY='pgen.meter.targetLevels';
function getEl(id){ return document.getElementById(id); }
function meterReadTargetLevelsState(){
 let saved=null;
 try{ saved=JSON.parse(localStorage.getItem(METER_TARGET_LEVELS_KEY)||'null'); }catch(e){ saved=null; }
 if(!saved||typeof saved!=='object') return null;
 const w=(saved.white&&typeof saved.white==='object')?saved.white:{};
 const b=(saved.black&&typeof saved.black==='object')?saved.black:{};
 return {
  white:{
   useMeasured:(typeof w.useMeasured==='boolean')?w.useMeasured:true,
   value:(typeof w.value==='number'&&Number.isFinite(w.value))?w.value:null,
   overridden:(typeof w.overridden==='boolean')?w.overridden:false
  },
  black:{
   useMeasured:(typeof b.useMeasured==='boolean')?b.useMeasured:true,
   value:(typeof b.value==='number'&&Number.isFinite(b.value))?b.value:null,
   overridden:(typeof b.overridden==='boolean')?b.overridden:false
  }
 };
}
function meterSetTargetLevels(){
 const wUm=getEl('meterTargetWhiteUseMeasured'), white=getEl('meterTargetWhite');
 const bUm=getEl('meterTargetBlackUseMeasured'), black=getEl('meterTargetBlack');
 if(!wUm||!white||!bUm||!black) return;
 // When Use measured is turned on, clear the manual box so it cannot look
 // like a fixed override while the measured reference is active.
 if(wUm.checked) white.value='';
 if(bUm.checked) black.value='';
 // OLED default is manual 0. If the operator unchecks Use measured with an
 // empty black box, restore that default so the field is not blank.
 if(!bUm.checked&&black.value===''&&meterDisplayTypeIsOledClass()) black.value='0';
 white.disabled=!!wUm.checked; black.disabled=!!bUm.checked;
 white.classList.toggle('meter-input-disabled',!!wUm.checked);
 black.classList.toggle('meter-input-disabled',!!bUm.checked);
 if(wUm.checked){ white.placeholder=''; white.removeAttribute('placeholder'); }
 else if(!white.hasAttribute('placeholder')){ white.setAttribute('placeholder','auto'); }
 if(bUm.checked){ black.placeholder=''; black.removeAttribute('placeholder'); }
 else if(!black.hasAttribute('placeholder')){ black.setAttribute('placeholder','auto'); }
 const wVal=Number(white.value); let bVal=Number(black.value);
 const oled=meterDisplayTypeIsOledClass();
 const wDef={useMeasured:true,value:null};
 const bDef=oled?{useMeasured:false,value:0}:{useMeasured:true,value:null};
 const wUseMeasured=!!wUm.checked;
 const wValue=(!wUseMeasured&&Number.isFinite(wVal))?wVal:null;
 const bUseMeasured=!!bUm.checked;
 const bValue=(!bUseMeasured&&Number.isFinite(bVal))?bVal:null;
 const wOver=(wUseMeasured!==wDef.useMeasured||wValue!==wDef.value);
 const bOver=(bUseMeasured!==bDef.useMeasured||bValue!==bDef.value);
 const state={
  white:{useMeasured:wUseMeasured,value:wValue,overridden:wOver},
  black:{useMeasured:bUseMeasured,value:bValue,overridden:bOver}
 };
 try{ localStorage.setItem(METER_TARGET_LEVELS_KEY,JSON.stringify(state)); }catch(e){}
 try{ meterWarnTargetWhiteAboveHdrMax(); }catch(e){}
 // Let the checkbox/input state paint before recalculating charts. Rapid
 // toggles coalesce into one refresh instead of stacking expensive canvases.
 try{ meterScheduleTargetCurveRefresh(); }catch(e){}
}
function meterRestoreTargetLevels(){
 const wUm=getEl('meterTargetWhiteUseMeasured'), white=getEl('meterTargetWhite');
 const bUm=getEl('meterTargetBlackUseMeasured'), black=getEl('meterTargetBlack');
 if(!wUm||!white||!bUm||!black) return;
 const s=meterReadTargetLevelsState();
 if(!s){
  // No saved state: apply the display-type defaults.
  meterApplyTargetLevelsDisplayDefaults(true);
  meterSetTargetLevelsStateOnly();
  return;
 }
 wUm.checked=!!s.white.useMeasured;
 if(!s.white.useMeasured&&s.white.value!=null) white.value=s.white.value; else white.value='';
 bUm.checked=!!s.black.useMeasured;
 if(!s.black.useMeasured&&s.black.value!=null) black.value=s.black.value; else black.value='';
 // Re-apply display-type defaults only for whichever side the operator has
 // not yet overridden.
 if(!s.white.overridden||!s.black.overridden) meterApplyTargetLevelsDisplayDefaults(false,s);
 meterSetTargetLevelsStateOnly();
}
// Apply the DOM checkbox/input state to the disabled/grey styling without
// re-persisting (used during restore before the user edits anything).
function meterSetTargetLevelsStateOnly(){
 const wUm=getEl('meterTargetWhiteUseMeasured'), white=getEl('meterTargetWhite');
 const bUm=getEl('meterTargetBlackUseMeasured'), black=getEl('meterTargetBlack');
 if(!wUm||!white||!bUm||!black) return;
 white.disabled=!!wUm.checked; black.disabled=!!bUm.checked;
 white.classList.toggle('meter-input-disabled',!!wUm.checked);
 black.classList.toggle('meter-input-disabled',!!bUm.checked);
 if(wUm.checked){ white.removeAttribute('placeholder'); }
 else { white.setAttribute('placeholder','auto'); }
 if(bUm.checked){ black.removeAttribute('placeholder'); }
 else { black.setAttribute('placeholder','auto'); }
}
// Determine whether the selected display type is self-emissive (defaults
// Target Black = 0 instead of measured). Covers OLED, QD-OLED, Plasma and
// CRT, plus any display-specific CCSS whose technology resolves to OLED.
function meterDisplayTypeIsOledClass(value){
 const v=String(value||((document.getElementById('meterDisplayType')||{}).value)||'').toLowerCase();
 if(v.indexOf('oled')!==-1||v==='qdoled'||v==='plasma'||v==='crt') return true;
 if(v.startsWith('ccss_')||v.startsWith('custom_')){
  try{
   const meta=(typeof meterDisplayTypeMetaText==='function')?meterDisplayTypeMetaText(v):'';
   if(/\b(?:qd[-\s]*oled|wrgb[-\s]*oled|rgb[-\s]*oled|woled|amoled|oled)\b/i.test(meta)) return true;
  }catch(e){}
 }
 return false;
}
// Apply display-type-based defaults. when forceAll is true both white and
// black are reset to defaults (first selection / no saved state); otherwise
// only sides not marked overridden are touched.
function meterApplyTargetLevelsDisplayDefaults(forceAll,saved){
 const wUm=getEl('meterTargetWhiteUseMeasured'), white=getEl('meterTargetWhite');
 const bUm=getEl('meterTargetBlackUseMeasured'), black=getEl('meterTargetBlack');
 if(!wUm||!bUm) return;
 const oled=meterDisplayTypeIsOledClass();
 const s=saved||meterReadTargetLevelsState();
 const wOver=s&&s.white&&s.white.overridden;
 const bOver=s&&s.black&&s.black.overridden;
 // Target White defaults to measured for every display type.
 if(forceAll||!wOver){
  wUm.checked=true; if(white) white.value='';
 }
 // Target Black defaults: self-emissive -> manual 0, else Use measured.
 // Respect an explicit operator override (including checking Use measured on
 // OLED); never force the checkbox back off after the user toggled it.
 if(forceAll||!bOver){
  if(oled){
   bUm.checked=false; if(black) black.value='0';
  }else{
   bUm.checked=true; if(black) black.value='';
  }
 }
 // A display-type change can flip Target Black between the manual OLED
 // default and Use Measured. Keep the input's disabled/placeholder state in
 // lockstep with the checkbox instead of leaving the previous mode editable.
 meterSetTargetLevelsStateOnly();
}
// Resolve the effective Target White level. Returns {useMeasured,value}.
function meterTargetWhiteLevel(){
 const useMeasured=document.getElementById('meterTargetWhiteUseMeasured');
 const input=document.getElementById('meterTargetWhite');
 if(useMeasured&&input){
  const raw=String(input.value==null?'':input.value).trim();
  const value=raw===''?null:Number(raw);
  return {useMeasured:!!useMeasured.checked,value:Number.isFinite(value)?value:null};
 }
 const s=meterReadTargetLevelsState();
 if(s) return {useMeasured:!!s.white.useMeasured,value:s.white.value};
 return {useMeasured:true,value:null};
}

function meterWarnTargetWhiteAboveHdrMax(){
 const mode=String((typeof getVal==='function'?getVal('signal_mode'):'')||'sdr').toLowerCase();
 if(mode==='sdr') return false;
 const target=meterTargetWhiteLevel();
 if(!target||target.useMeasured||!(Number(target.value)>0)) return false;
 const rawMax=(typeof meterHdrMetadataFieldValue==='function')
  ?meterHdrMetadataFieldValue('max_luma',mode)
  :((document.getElementById(mode==='dv'?'dv_max_luma':'max_luma')||{}).value);
 const maxLuma=Number(rawMax);
 if(!(maxLuma>0)||Number(target.value)<=maxLuma) return false;
 const fmt=value=>Number(value).toLocaleString(undefined,{maximumFractionDigits:2});
 toast('Warning: Target White ('+fmt(target.value)+' cd/m\u00B2) is above HDR Max Luma ('+fmt(maxLuma)+' cd/m\u00B2). The target curve will use Target White; output metadata remains '+fmt(maxLuma)+' cd/m\u00B2.',true);
 return true;
}
// Resolve the effective Target Black level. Returns {useMeasured,value}.
function meterTargetBlackLevel(){
 const useMeasured=document.getElementById('meterTargetBlackUseMeasured');
 const input=document.getElementById('meterTargetBlack');
 if(useMeasured&&input){
  const raw=String(input.value==null?'':input.value).trim();
  const value=raw===''?null:Number(raw);
  return {useMeasured:!!useMeasured.checked,value:Number.isFinite(value)?value:null};
 }
 const s=meterReadTargetLevelsState();
 if(s){
  return {useMeasured:!!s.black.useMeasured,value:s.black.value};
 }
 return meterDisplayTypeIsOledClass()?{useMeasured:false,value:0}:{useMeasured:true,value:null};
}
// Build the override payload spread into meter request bodies. Only emits
// keys when the operator has entered a manual value.
function meterTargetLevelsPayload(){
 const w=meterTargetWhiteLevel(), b=meterTargetBlackLevel();
 const p={};
 if(!w.useMeasured&&w.value!=null&&w.value>0){ p.target_white_luminance=Number(w.value); }
 else { p.target_white_use_measured=true; }
 if(!b.useMeasured&&b.value!=null&&b.value>=0){ p.target_black_luminance=Number(b.value); }
 else { p.target_black_use_measured=true; }
 return p;
}

let meterTargetLevelMeasuring='';
function meterTargetLevelFormat(kind,value){
 const numeric=Math.max(0,Number(value)||0);
 if(kind==='black'){
  if(numeric===0) return '0';
  if(numeric<0.001) return numeric.toFixed(6).replace(/0+$/,'').replace(/\.$/,'');
  return numeric.toFixed(4).replace(/0+$/,'').replace(/\.$/,'');
 }
 return numeric.toFixed(2).replace(/0+$/,'').replace(/\.$/,'');
}

function meterUpdateTargetMeasureButtons(){
 const busy=!!window._configApplyPending||meterActionPending||meterSeriesRunning
  ||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning
  ||meterContinuousActive||meterContinuousSuspendedForLgWrite;
 ['white','black'].forEach(kind=>{
  const button=document.getElementById(kind==='white'?'meterTargetWhiteMeasure':'meterTargetBlackMeasure');
  if(!button) return;
  const active=meterTargetLevelMeasuring===kind;
  button.textContent=active?'Reading\u2026':'Measure';
  button.disabled=!meterDetected||hasUnsavedSettings()||busy;
  button.classList.toggle('btn-success',active);
  button.classList.toggle('btn-secondary',!active);
  button.title=hasUnsavedSettings()
   ?'Apply & Restart first so the measurement matches the live signal mode'
   :(busy&&!active?'Meter operation already in progress'
    :(kind==='white'
     ?'Display white, take one meter reading, and use its luminance as the fixed Target White'
     :'Display black, take one meter reading, and use its luminance as the fixed Target Black'));
 });
}

async function meterMeasureTargetLevel(kind){
 const targetKind=kind==='black'?'black':'white';
 if(meterActionPending||meterSeriesRunning||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning||meterContinuousActive){
  toast('Meter operation already in progress',true);
  return;
 }
 if(!(await meterEnsureDetected())){ toast('No meter detected',true); return; }
 if(!meterEnsureAppliedGeneratorSettings()) return;
 const ire=targetKind==='white'?100:0;
 const code=meterCodeFromSignalPercent(ire);
 const step={
  ire:ire,stimulus:ire,
  signal_r_pct:ire,signal_g_pct:ire,signal_b_pct:ire,
  r:code,g:code,b:code,input_max:meterPatchInputMax(),
  name:targetKind==='white'?'Target White':'Target Black',
  series_type:'greyscale'
 };
 meterActionPending=true;
 meterTargetLevelMeasuring=targetKind;
 meterUpdateReadButtons();
 meterUpdateTargetMeasureButtons();
 document.getElementById('meterDot').style.background='var(--orange)';
 const progress=document.getElementById('meterProgress');
 const progressLabel=document.getElementById('meterProgressLabel');
 if(progress) progress.style.display='';
 if(progressLabel) progressLabel.textContent='Measuring '+(targetKind==='white'?'Target White\u2026':'Target Black\u2026');
 try{
  await meterDisplayPatch(step,{fresh:false,allowAfterStop:true});
  const payload=meterBuildManualReadPayload(step,{
   dtype:getEffectiveDisplayType(),
   rr:getMeterRefreshRate(),
   delay:meterDelayMs(),
   patternSignalRange:meterMeasurementPatchSignalRange(),
   requireDeviceReady:meterSelectedMeasurementRequiresReady()
  });
  const result=await meterStartSingleRead(payload);
  if(!meterReadResultOk(result)){
   toast(result&&result.message?result.message:'Measurement failed',true);
   return;
  }
  const reading=result.readings[0];
  meterNormalizeMeasuredReading(reading);
  const luminance=Number(reading.luminance!=null?reading.luminance:reading.Y);
  if(!Number.isFinite(luminance)||luminance<0) throw new Error('Meter returned no valid luminance');
  const input=document.getElementById(targetKind==='white'?'meterTargetWhite':'meterTargetBlack');
  const useMeasured=document.getElementById(targetKind==='white'?'meterTargetWhiteUseMeasured':'meterTargetBlackUseMeasured');
  if(input) input.value=meterTargetLevelFormat(targetKind,luminance);
  if(useMeasured) useMeasured.checked=false;
  meterSetTargetLevels();
  toast((targetKind==='white'?'Target White: ':'Target Black: ')+meterTargetLevelFormat(targetKind,luminance)+' cd/m\u00B2');
 }catch(e){
  toast('Target '+targetKind+' measurement failed: '+(e&&e.message?e.message:'unknown error'),true);
 }finally{
  meterTargetLevelMeasuring='';
  meterActionPending=false;
  meterPingBusy=false;
  meterSeriesAwaitingReady=false;
  meterReadySignalPending=false;
  meterPendingDeviceReadyAction=null;
  meterClearManualPromptAwaiting(false);
  meterSpectroSetupApply(null);
  meterUpdateReadButtons();
  meterUpdateTargetMeasureButtons();
  document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
  meterHideProgressIfIdle();
  await meterCheckStatus();
 }
}
let meterTargetCurveRefreshFrame=0;
let meterTargetCurveRefreshTimer=0;
function meterScheduleTargetCurveRefresh(){
 if(meterTargetCurveRefreshFrame) cancelAnimationFrame(meterTargetCurveRefreshFrame);
 if(meterTargetCurveRefreshTimer) clearTimeout(meterTargetCurveRefreshTimer);
 meterTargetCurveRefreshFrame=requestAnimationFrame(()=>{
  meterTargetCurveRefreshFrame=0;
  // A timer from the animation frame lets the browser commit the checkbox
  // paint before any chart computation begins.
  meterTargetCurveRefreshTimer=setTimeout(()=>{
   meterTargetCurveRefreshTimer=0;
   meterRefreshTargetCurves();
  },0);
 });
}

// Redraw the greyscale target curves so a Target White/Black change is
// reflected immediately without re-reading. Mirrors the cache bookkeeping
// in meterOnGreyRefChange (this is bookkeeping, not curve math) so the
// Gamma / Delta E / RGB charts pick up the new target endpoints too.
function meterRefreshTargetCurves(){
 // Invalidate per-reading greyscale analysis caches so the Delta E and
 // per-channel gamma recomputes against the new target White/Black.
 try{
  if(meterReadings&&meterReadings.length){
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
  }
 }catch(e){}
 if(!(meterReadings&&meterReadings.length)) return;
 // The old path drew EOTF + luminance individually and then drew ALL charts,
 // which drew those same two canvases again. Use the existing frame-sliced
 // greyscale renderer so each chart is computed once and input can be handled
 // between canvases.
 try{
  if(meterActiveSeriesType==='greyscale'&&typeof meterQueueRunningGreyscaleChartRefresh==='function'){
   meterQueueRunningGreyscaleChartRefresh(meterReadings);
  }else if(typeof drawAllCharts==='function'){
   requestAnimationFrame(()=>drawAllCharts(meterReadings));
  }
 }catch(e){}
}

async function meterRunManualReadStep(step,ctx){
 const opts=ctx||{};
 if(step&&opts.displayFirst) await meterDisplayPatch(step,{fresh:false,allowAfterStop:true});
 const label=document.getElementById('meterProgressLabel');
 if(label&&step) label.textContent=(step.name||step.ire+'%')+' (reading)';
 const result=await meterStartSingleRead(meterBuildManualReadPayload(step,opts));
 meterApplySingleReadResult(result,step);
 return result;
}

function meterReadResultOk(result){
 // null_read is stamped by meter_session.sh when an all-zero measurement
 // survived every re-read of a patch that DRIVES LIGHT (a 0% black reads zero
 // legitimately and is never flagged). Treat it as a failed read here rather
 // than letting a lit patch enter a chart, a white reference or a peak probe
 // as 0 cd/m2; the payload carries a message explaining what to check.
 if(result&&result.null_read) return false;
 return !!(result&&result.status==='ok'&&Array.isArray(result.readings)&&result.readings.length>0);
}

function meterManualPromptActionLabel(){
 switch(meterManualPromptReason){
  case 'calibration_setup': return 'Continue Meter Setup';
  case 'incorrect_position': return 'Continue After Reposition';
  default: return 'Continue Reading';
 }
}

function meterClearManualPromptAwaiting(resolvePending){
 const resolver=meterManualPromptContinueResolver;
 meterManualPromptAwaiting=false;
 meterManualPromptReason='';
 meterManualPromptMessage='';
 meterManualPromptContinueResolver=null;
 if(resolvePending&&resolver) resolver();
}

async function meterWaitForManualPromptClear(state){
 meterPingBusy=false;
 meterManualPromptAwaiting=true;
 meterManualPromptReason=String((state&&state.awaiting_ready_reason)||'');
 meterManualPromptMessage=String((state&&state.message)||'Meter is waiting for operator input');
 const progress=document.getElementById('meterProgress');
 const label=document.getElementById('meterProgressLabel');
 if(progress) progress.style.display='';
 if(label) label.textContent=meterManualPromptMessage;
 meterUpdateReadButtons();
 await new Promise(resolve=>{ meterManualPromptContinueResolver=resolve; });
 meterPingBusy=true;
}

function meterWorkflowClamp01(value){
 const numeric=Number(value);
 if(!Number.isFinite(numeric)) return 0;
 return Math.max(0,Math.min(1,numeric));
}

function meterWorkflowPhaseFraction(status){
 if(!status) return 0;
 const phase=String(status.phase||'').toLowerCase();
 // The HDR20 shadow correction runs AFTER the 3D LUT + tone-map commit
 // (worker reorder 2026-07-03). The state still carries the profile's
 // 5/5 step counts at that point, so without this the bar would show
 // 100% for the whole trim. Pin the late phases just under complete.
 if(phase.indexOf('postcal_shadow')===0) return 0.975;
 if(phase==='tone_map_upload') return 0.97;
 let total=Number(status.total_steps)||0;
 let current=Number(status.current_step)||0;
 if(status.autocal3d&&phase==='post_check'){
  total=Number(status.post_check_total)||total;
  current=Number(status.post_check_current)||current;
 }
 if(total>0){
  let fraction=meterWorkflowClamp01(current/total);
  const running=String(status.status||'').toLowerCase()==='running';
  const label=String((status.current_name||'')+' '+(status.message||'')).toLowerCase();
  if(running&&fraction>=1&&/committed|polish|settling|verify/.test(label)) fraction=0.985;
  return fraction;
 }
 if(status.status==='complete') return 1;
 if(phase==='building') return 0.86;
 if(phase==='upload_probe') return 0.92;
 if(phase==='upload') return 0.96;
 return 0;
}

function meterWorkflowStepText(status){
 if(!status) return '';
 const phase=String(status.phase||'').toLowerCase();
 let total=Number(status.total_steps)||0;
 let current=Number(status.current_step)||0;
 if(status.autocal3d&&phase==='post_check'){
  total=Number(status.post_check_total)||total;
  current=Number(status.post_check_current)||current;
 }
 if(total>0) return Math.max(0,current)+'/'+total;
 return '';
}

function meterFullAutoCalStageIndex(){
 const phase=String(meterFullAutoCalPhase||'');
 const stages=meterFullAutoCalStageOrder();
 const idx=stages.indexOf(phase);
 if(idx>=0) return idx;
 if(phase==='complete') return stages.length-1;
 return 0;
}

function meterFullAutoCalStageOrder(){
 const skipPre=!!(meterFullAutoCalConfig&&meterFullAutoCalConfig.preCalSkipped);
 const dvSignal=String((meterFullAutoCalConfig&&meterFullAutoCalConfig.signalMode)||'').toLowerCase()==='dv';
 const stages=[];
 if(!skipPre) stages.push('precal-report');
 stages.push('first-greyscale');
 if(dvSignal){
  // Dolby Vision has no 3D LUT / committed-polish / touch-up concept --
  // the panel-profile upload (Task 6/7) is the whole "color" stage.
  stages.push('dv-profile');
 }else{
  stages.push('3d-lut');
  if(meterFullAutoCalPostCommitPolishEnabled()) stages.push('post-3d-polish');
 }
  stages.push('postcal-report','complete');
  return stages;
 }

function meterFullAutoCalStageLabel(){
 switch(String(meterFullAutoCalPhase||'')){
	  case 'precal-report': return 'Pre-Cal measurements';
		  case 'first-greyscale': return 'Greyscale';
		  case '3d-lut': return '3D LUT';
		  case 'dv-profile': return 'Dolby Vision profile';
		  case 'touchup-greyscale': return 'Greyscale touch-up';
		  case 'post-3d-polish': return 'Committed polish';
	  case 'postcal-report': return 'Post-Cal measurements';
  case 'complete': return 'Complete';
  default: return 'Greyscale';
 }
}

function meterFullAutoCalReportPhaseActive(){
 const phase=String(meterFullAutoCalPhase||'');
 return !!(meterFullAutoCalRunning&&(phase==='precal-report'||phase==='postcal-report'));
}

function meterClearAutoCalStatusPollingForReport(){
 if(!meterFullAutoCalReportPhaseActive()) return;
 if(meterAutoCalPolling){clearInterval(meterAutoCalPolling);meterAutoCalPolling=null;}
 if(meterLg3dAutoCalPolling){clearInterval(meterLg3dAutoCalPolling);meterLg3dAutoCalPolling=null;}
 meterAutoCalRunning=false;
 meterLg3dAutoCalRunning=false;
 if(meterAutoCalPhase==='running'||meterAutoCalPhase==='complete'||meterAutoCalPhase==='error') meterAutoCalPhase='';
}

function meterFullAutoCalStageWeights(){
 // Expected meter-read count per phase, so the Full Auto Cal bar advances
 // roughly in proportion to reads done rather than treating every phase as an
 // equal slice (which made the ~80-read greyscale count the same as the
 // 0-read tone-map/complete steps, so the bar looked stuck on the short tail).
 // Report phases measure meterFullAutoCalReportSeries() (e.g. 21+30+24=75);
 // greyscale runs ~26 anchors with several iterations each (~80 reads); the
 // HDR 3D LUT is matrix-only (~5 profile + ~10 post-check); tone-map/complete
 // do no reads. These are estimates -- exact greyscale reads vary with
 // convergence -- but they make the overall bar far more honest than equal
 // slices. Within-phase pacing still comes from meterWorkflowPhaseFraction.
 let reportReads=0;
 try{ reportReads=meterFullAutoCalReportSeries().reduce(function(n,s){return n+(Number(s.points)||0);},0); }catch(e){ reportReads=0; }
 if(!(reportReads>0)) reportReads=75;
 // The HDR20 shadow fix now runs inside the 3D-LUT phase, after the
 // cube + tone-map commit: zone probe (~25 reads) plus up to 6 trim
 // passes over 6 anchors with confirm re-reads (~60-90 reads). Weight
 // the 3D phase accordingly when it is enabled so the full bar does not
 // stall near the end for half an hour.
 let shadowReads=0;
 try{
  if(meterFullAutoCalShadowFixEnabled()&&String((meterFullAutoCalConfig&&meterFullAutoCalConfig.signalMode)||'')==='hdr10') shadowReads=95;
 }catch(e){ shadowReads=0; }
 // Lattice profiling replaces the 5-point matrix profile with the chosen
 // series' full patch count — weight the 3D phase by the extra reads so the
 // bar does not crawl through a long lattice at matrix pacing.
 let latticeReads=0;
 try{
  {
  const fm=String((meterFullAutoCalConfig&&meterFullAutoCalConfig.method)||'');
  if(fm==='lattice'||fm==='skeleton'||fm==='hybrid'){
   let series=meterCustomSeriesById(meterFullAutoCalConfig.latticeSeriesId);
   if(!series&&fm==='skeleton') series=meterCustomSeriesById(920);
   if(!series&&fm==='hybrid') series=meterCustomSeriesById(923);
   if(series) latticeReads=Math.max(0,meterLg3dLatticePatchesForStart(series).length-5);
  }
 }
 }catch(e){ latticeReads=0; }
 return {
  'precal-report':reportReads,
  'first-greyscale':80,
  'touchup-greyscale':20,
  '3d-lut':15+latticeReads+shadowReads,
  'dv-profile':5,
  'post-3d-polish':20,
  'postcal-report':reportReads,
  'complete':0
 };
}

function meterWorkflowPercent(status,workflow){
 const fraction=meterWorkflowPhaseFraction(status);
 if(workflow==='full'){
  const stage=meterFullAutoCalStageIndex();
  const stages=meterFullAutoCalStageOrder();
  const weights=meterFullAutoCalStageWeights();
  let total=0; for(let i=0;i<stages.length;i++) total+=(Number(weights[stages[i]])||0);
  // Fall back to equal-slice weighting if weights are unavailable.
  if(!(total>0)){
   const denom=Math.max(1,stages.length-1);
   return meterWorkflowClamp01((stage+fraction)/denom)*100;
  }
  let done=0; for(let i=0;i<stage&&i<stages.length;i++) done+=(Number(weights[stages[i]])||0);
  const cur=(stage>=0&&stage<stages.length)?(Number(weights[stages[stage]])||0):0;
  return meterWorkflowClamp01((done+fraction*cur)/total)*100;
 }
 return fraction*100;
}

function meterSetWorkflowProgress(status,options){
 const progress=document.getElementById('meterProgress');
 const label=document.getElementById('meterProgressLabel');
 const pctText=document.getElementById('meterProgressPercent');
 const bar=document.getElementById('meterWorkflowProgressBar');
 const fill=document.getElementById('meterWorkflowProgressFill');
 const opts=options||{};
 const workflow=opts.workflow||'';
 const pct=meterWorkflowPercent(status,workflow);
 const stepText=meterWorkflowStepText(status);
 let text=opts.label||(status&&(status.current_name||status.message))||'Running...';
 if(workflow==='full') text='Full Auto Cal: '+meterFullAutoCalStageLabel()+(text?(' - '+text):'');
 if(stepText) text+=' '+stepText;
 if(progress) progress.style.display='grid';
 if(label) label.textContent=text;
 if(pctText) pctText.textContent=Number.isFinite(pct)?Math.round(pct)+'%':'';
 if(bar) bar.style.display='';
 if(bar){
  const pctValue=Number.isFinite(pct)?Math.max(0,Math.min(100,pct)):0;
  bar.setAttribute('role','progressbar');
  bar.setAttribute('aria-valuemin','0');
  bar.setAttribute('aria-valuemax','100');
  bar.setAttribute('aria-valuenow',String(Math.round(pctValue)));
  if(fill){
   fill.style.width=pctValue+'%';
   fill.classList.toggle('active',pctValue>0&&pctValue<100);
  }
 }
}

function meterClearWorkflowProgress(){
 const pctText=document.getElementById('meterProgressPercent');
 const bar=document.getElementById('meterWorkflowProgressBar');
 const fill=document.getElementById('meterWorkflowProgressFill');
 if(pctText) pctText.textContent='';
 if(fill){
  fill.style.width='0%';
  fill.classList.remove('active');
 }
 if(bar) bar.style.display='none';
}

function meterHideWorkflowProgress(){
 const progress=document.getElementById('meterProgress');
 if(progress) progress.style.display='none';
 meterClearWorkflowProgress();
}

function meterHideProgressIfIdle(){
 const progress=document.getElementById('meterProgress');
 if(!progress) return;
 if(meterSeriesRunning||meterActionPending||meterContinuousActive||meterSeriesAwaitingReady||meterManualPromptAwaiting) return;
 meterHideWorkflowProgress();
}

async function meterSignalManualPromptReady(){
 if(meterReadySignalPending||!meterManualPromptAwaiting) return;
 const progressEl=document.getElementById('meterProgressLabel');
 meterReadySignalPending=true;
 if(progressEl) progressEl.textContent='Resuming measurement...';
 meterUpdateReadButtons();
 try{
  const r=await fetchJSON('/api/meter/read/ready',{method:'POST',_timeoutMs:5000});
  if(!r||r.status!=='ok'){
   if(r&&/not waiting for device readiness/i.test(r.message||'')){
    meterClearManualPromptAwaiting(true);
    return;
   }
   toast(r&&r.message?r.message:'Failed to resume measurement',true);
   return;
  }
  meterClearManualPromptAwaiting(true);
 }catch(e){
  toast('Failed to resume measurement',true);
 }finally{
  meterReadySignalPending=false;
  meterUpdateReadButtons();
 }
}

async function meterFinishSingleRead(){
 meterActionPending=false;
 meterPingBusy=false;
 meterSeriesAwaitingReady=false;
 meterReadySignalPending=false;
 meterPendingDeviceReadyAction=null;
 meterClearManualPromptAwaiting(false);
 // Hide the shared spectro setup modal if we raised it preemptively at the
 // start of the read. Normal single reads hide it via the poll result, but
 // the POST-throws-before-poll path (e.g. /api/meter/read connection error)
 // skips the poll entirely and would otherwise leave the modal visible.
 meterSpectroSetupApply(null);
 document.getElementById('meterReadOnce').innerHTML='&#9679; Read Once';
 meterUpdateReadButtons();
 document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
 meterHideProgressIfIdle();
 // Always clear the "reading" pulse once Read Once returns (success or error).
 if(meterSeriesSteps){
  const isColorE=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedStepsE=isColorE?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
  const doneE=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneE.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedStepsE,doneE,null);
 }
 await meterCheckStatus();
}

let meterSpectroSetupStepId=0;
let meterSpectroSetupStep='';
let meterSpectroSetupAckEndpoint='/api/meter/setup/ack';
let meterSpectroSetupCancelEndpoint='/api/meter/stop';
function meterSpectroSetupLabel(step){
 return ({calibrate_tile:'Calibrate',calibrate_dark:'Calibrate',position_screen:'Ready',calibrate_retry:'Retry'})[step]||'Continue';
}
// calibrate_dark is the colorimeter (SpyderX) dark reference, not a spectro
// step, so the modal title has to follow the step instead of being hardcoded.
function meterSpectroSetupTitleText(step){
 return step==='calibrate_dark' ? 'Meter Setup'
  : !meterIsSpectrophotometer(meterSelectedMeasurementMeter()) ? 'Meter Setup'
  : 'Spectrophotometer Setup';
}
function meterSpectroSetupStepText(step){
 return ({calibrate_tile:'Step 1 of 2: Calibrate on the white tile',calibrate_dark:'Step 1 of 2: Dark calibration',position_screen:'Step 2 of 2: Aim at the screen',calibrate_retry:'Calibration retry'})[step]||'Setup';
}
function meterSpectroSetupWorkingText(step){
 return ({calibrate_tile:'Calibrating the meter on its tile. Please wait...',calibrate_dark:'Calibrating the meter black reference. Please wait...',position_screen:'Preparing the measurement...',calibrate_retry:'Retrying meter calibration. Please wait...'})[step]||'Preparing the meter. Please wait...';
}
// Driven by the read-result poll. Shows the modal during status:"setup",
// updates per step, hides it otherwise.
function meterSpectroSetupApply(r,ackEndpoint){
 const modal=document.getElementById('meterSpectroSetupModal');
 if(!modal) return;
 const lbl=document.getElementById('meterSpectroSetupStepLabel');
 const ttl=document.getElementById('meterSpectroSetupTitle');
 const msg=document.getElementById('meterSpectroSetupMessage');
 const btn=document.getElementById('meterSpectroSetupBtn');
 if(ackEndpoint){
  meterSpectroSetupAckEndpoint=ackEndpoint;
  meterSpectroSetupCancelEndpoint=(ackEndpoint.indexOf('/ccss/')>=0)?'/api/ccss/create/stop':'/api/meter/stop';
 }
 if(r && r.status==='setup' && r.step_id){
  meterSpectroSetupStepId=Number(r.step_id)||0;
  meterSpectroSetupStep=String(r.step||'');
  if(ttl) ttl.textContent=meterSpectroSetupTitleText(r.step||'');
  if(lbl) lbl.textContent=meterSpectroSetupStepText(r.step||'');
  if(msg) msg.textContent=String(r.message||'');
  if(btn){ btn.textContent=meterSpectroSetupLabel(r.step||''); btn.disabled=false; btn.style.display=''; }
  modal.style.display='flex';
  uiSyncBodyScrollLock();
 } else if(r && r.keepBusy){
  // Keep the popup visible BETWEEN steps. Calibration and the patch sweep each
  // take several seconds; hiding the modal here left the operator staring at a
  // blank screen. Show a 'working' message and no action button instead.
  meterSpectroSetupStepId=0;
  if(r.step) meterSpectroSetupStep=String(r.step);
  if(ttl) ttl.textContent=meterSpectroSetupTitleText(meterSpectroSetupStep);
  if(lbl) lbl.textContent='Working…';
  if(msg) msg.textContent=String(r.message||'Please wait…');
  if(btn){ btn.style.display='none'; }
  modal.style.display='flex';
  uiSyncBodyScrollLock();
 } else {
  meterSpectroSetupStep='';
  if(modal.style.display!=='none'){ modal.style.display='none'; uiSyncBodyScrollLock(); }
 }
}
async function meterSpectroSetupAck(){
 const btn=document.getElementById('meterSpectroSetupBtn');
 const id=meterSpectroSetupStepId;
 const step=meterSpectroSetupStep;
 if(!id) return;
 if(btn) btn.disabled=true;
 try{
  const r=await fetchJSON(meterSpectroSetupAckEndpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({step_id:id}),_timeoutMs:5000});
  if(!r||r.status!=='ok'){
   if(btn) btn.disabled=false;
   toast(r&&r.message?r.message:'Could not continue setup',true);
   return;
  }
  meterSpectroSetupApply({keepBusy:true,step:step,message:meterSpectroSetupWorkingText(step)},meterSpectroSetupAckEndpoint);
 }catch(e){
  if(btn) btn.disabled=false;
  toast('Could not continue meter setup',true);
 }
}
async function meterSpectroSetupCancel(){
 const modal=document.getElementById('meterSpectroSetupModal');
 if(modal){ modal.style.display='none'; uiSyncBodyScrollLock(); }
 if(meterSpectroSetupAckEndpoint==='/api/meter/series/ready'||meterSeriesSpectroSetupActive){
  await meterStop();
  return;
 }
 // Cancel the right job: the CCSS helper during CCSS creation, otherwise the
 // meter session.
 await fetchJSON(meterSpectroSetupCancelEndpoint||'/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000}).catch(()=>null);
}

async function meterCalibrateSelectedMeter(){
 if(meterActionPending){toast('Meter operation already in progress',true);return;}
 if(!(await meterEnsureDetected())){toast('No meter detected',true);return;}
 const selected=meterSelectedMeasurementMeter();
 if(!meterRequiresManualCalibration(selected)){toast('The selected meter does not require manual calibration',true);return;}
 if(meterSeriesRunning||meterContinuousActive){toast('Stop the active meter run before calibrating',true);return;}
 if(!meterEnsureAppliedGeneratorSettings()) return;
 meterActionPending=true;
 meterUpdateReadButtons();
 const button=document.getElementById('meterCalibrateBtn');
 if(button) button.textContent='Calibrating...';
 document.getElementById('meterDot').style.background='var(--orange)';
 meterSpectroSetupApply({keepBusy:true,message:'Preparing meter calibration...'},'/api/meter/setup/ack');
 try{
  const payload=meterMeasurementSignalContext({
   display_type:getEffectiveDisplayType(),
   refresh_rate:getMeterRefreshRate()||undefined,
   delay_ms:0,
   ccss_override:(typeof getCcssOverride==='function')?getCcssOverride():undefined,
   require_device_ready:meterSelectedMeasurementRequiresReady(),
   calibrate_only:true
  });
  const start=await fetchJSON('/api/meter/read',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify(payload),
   _quiet:true,
   _timeoutMs:90000
  });
  if(!start||start.status==='error') throw new Error((start&&start.message)||'Could not start meter calibration');
  const result=await meterPollRead(240000);
  if(result&&result.status==='ok') toast(result.message||'Meter calibration complete');
  else throw new Error((result&&result.message)||'Meter calibration did not complete');
 }catch(e){
  toast('Meter calibration error: '+e.message,true);
 }finally{
  meterSpectroSetupApply(null);
  meterActionPending=false;
  if(button) button.textContent='Calibrate Meter';
  document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
  meterUpdateReadButtons();
 }
}

function meterSeriesSpectroSetupApplyFromStatus(r){
 if(!r){
  if(meterSeriesSpectroSetupActive){
   meterSeriesSpectroSetupActive=false;
   meterSpectroSetupApply(null);
  }
  return false;
 }
 if(r.setup_busy){
  meterSeriesSpectroSetupActive=true;
  meterSpectroSetupApply({keepBusy:true,message:r.message},'/api/meter/series/ready');
  return true;
 }
 if(String(r.status||'').toLowerCase()==='setup'){
  meterSeriesSpectroSetupActive=true;
  meterSpectroSetupApply(r,'/api/meter/series/ready');
  return true;
 }
 if(!r.awaiting_ready){
  if(meterSeriesSpectroSetupActive){
   meterSeriesSpectroSetupActive=false;
   meterSpectroSetupApply(null);
  }
  return false;
 }
 const reason=String(r.awaiting_ready_reason||'').toLowerCase();
 let setup=null;
 if(reason==='calibration_setup'){
  setup={
   status:'setup',
   step_id:1,
   step:'calibrate_tile',
   message:'Place the spectrophotometer flat on its white calibration tile, then click Calibrate.'
  };
 } else if(reason==='initial_measurement'){
  setup={
   status:'setup',
   step_id:2,
   step:'position_screen',
   message:'Aim the meter at where the test patches appear on the screen, then click Ready.'
  };
 } else if(reason==='incorrect_position'){
  setup={
   status:'setup',
   step_id:3,
   step:'position_screen',
   message:'Reposition the meter at the test patch area, then click Ready.'
  };
 }
 if(!setup) return false;
 meterSeriesSpectroSetupActive=true;
 meterSpectroSetupApply(setup,'/api/meter/series/ready');
 return true;
}

async function meterReadOnce(){
 if(meterActionPending){toast('Meter operation already in progress',true);return;}
 if(!(await meterEnsureDetected())){toast('No meter detected',true);return;}
 if(!(await meterCalibrationRequirePatternProvider())) return;
 if(meterSeriesRunning){toast('Series scan is running \u2014 stop it first',true);return;}
 if(!meterEnsureAppliedGeneratorSettings()) return;
 const requestedStep=meterClonePatchStep(meterCurrentPatchStep);
 const referenceWhiteStep=meterReferenceWhitePromptStep(requestedStep);
 const readReferenceWhiteFirst=referenceWhiteStep?meterConfirmReferenceWhiteRead(requestedStep,referenceWhiteStep):false;
 // Enter manual mode: clear any leftover series poller/state so stale series
 // snapshots cannot repaint the charts after this manual read.
 const _priorRunActive=meterContinuousActive||meterSeriesRunning;
 meterSharedSeriesId=null;
 meterSeriesRunning=false;
 if(meterSeriesPolling){
  clearInterval(meterSeriesPolling);
  meterSeriesPolling=null;
 }
 // Only tear the meter session down if a series/continuous run was active.
 // For back-to-back single reads, reuse the long-lived session so a spectro
 // calibrates ONCE at session start instead of re-calibrating on every read.
 if(_priorRunActive) fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
 meterActionPending=true;
 meterUpdateReadButtons();
 document.getElementById('meterStopBtn').style.display='none';
 document.getElementById('meterReadOnce').disabled=true;
 document.getElementById('meterReadOnce').textContent='\u23F3 Reading\u2026';
 document.getElementById('meterDot').style.background='var(--orange)';
 // Pulse ONLY the thumb we're reading (selected patch), clear any stale state
 // from a previous series on all other thumbs.
 const readIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
 if(meterSeriesSteps){
  const isColor0=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps0=isColor0?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
  const doneIres=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneIres.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedSteps0,doneIres,readIre);
 }
 if(meterCurrentPatchStep){
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterProgressLabel').textContent=(meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%')+' (reading)';
 }
 try{
  const dtype=getEffectiveDisplayType();
  const rr=getMeterRefreshRate();
  const delay=meterDelayMs();
  const patternSignalRange=meterMeasurementPatchSignalRange();
  const requireDeviceReady=meterSelectedMeasurementRequiresReady();
  const readContext={dtype,rr,delay,patternSignalRange,requireDeviceReady};
  // No separate "Device Ready" pre-gate for spectro single reads: the session
  // surfaces its own interactive setup prompts (place on white tile -> Continue,
  // aim at screen -> Continue), which is the real readiness gate. requireDeviceReady
  // just flows through readContext to the read below.
  if(readReferenceWhiteFirst&&referenceWhiteStep){
   const whiteResult=await meterRunManualReadStep(referenceWhiteStep,{...readContext,displayFirst:true});
   if(!meterReadResultOk(whiteResult)) return;
   if(requestedStep) await meterRunManualReadStep(requestedStep,{...readContext,displayFirst:true});
  } else {
   await meterRunManualReadStep(requestedStep,{...readContext,displayFirst:false});
  }
 }catch(e){toast('Meter read error: '+e.message,true);}
 finally{
  if(!meterPendingDeviceReadyAction) await meterFinishSingleRead();
 }
}

async function meterPollRead(timeoutMs,shouldCancel){
 let start=Date.now();
 // Tiny initial delay so the backend has time to write the 'measuring' marker
 // before we poll. Then poll quickly — finer than the wrapper's own poll
 // granularity gives diminishing returns, but 200ms keeps UI responsiveness.
 await new Promise(r=>setTimeout(r,100));
 while(Date.now()-start<timeoutMs){
  if(typeof shouldCancel==='function'&&shouldCancel()) {
   meterClearManualPromptAwaiting(false);
   // Don't tear down the session on cancel -- it idles and is reused, so the
   // spectro keeps its calibration. Explicit Stop / series / AutoCal free it.
   return {status:'cancelled'};
  }
  try{
   const r=await fetchJSON('/api/meter/read/result',{_quiet:true,_timeoutMs:5000});
   if(r && r.setup_busy){
    // Keep the wizard popup visible with a 'working' message between setup
    // steps (e.g. while the meter calibrates after the tile step) instead of
    // hiding it and leaving the operator staring at a blank screen.
    meterSpectroSetupApply({keepBusy:true,message:r.message},'/api/meter/setup/ack');
   } else {
    meterSpectroSetupApply(r,'/api/meter/setup/ack');
   }
   if(r&&r.status==='setup'){ await new Promise(res=>setTimeout(res,300)); continue; }
   if(r&&r.awaiting_ready){
    await meterWaitForManualPromptClear(r);
    start=Date.now();
    continue;
   }
   if(r&&r.status!=='measuring'){
    meterClearManualPromptAwaiting(false);
    return r;
   }
  }catch(e){}
	  await new Promise(r=>setTimeout(r,200));
 }
 meterClearManualPromptAwaiting(false);
 try{
  const final=await fetchJSON('/api/meter/read/result',{_quiet:true,_timeoutMs:5000});
  if(final&&final.status&&final.status!=='measuring') return final;
 }catch(e){}
 return {status:'error',message:'Timeout waiting for reading'};
}

async function meterToggleContinuous(){
 if(meterContinuousActive){
  meterStopContinuous();
 } else {
  if(!(await meterEnsureDetected())){toast('No meter detected',true);return;}
  if(!(await meterCalibrationRequirePatternProvider())) return;
  if(!meterEnsureAppliedGeneratorSettings()) return;
  // Enter manual continuous mode and cut off any leftover series state.
  const _priorSeriesRunning=meterSeriesRunning;
  meterSharedSeriesId=null;
  meterSeriesRunning=false;
  if(meterSeriesPolling){
   clearInterval(meterSeriesPolling);
   meterSeriesPolling=null;
  }
  // Only tear down the backend session if a series scan owned it. A calibrated
  // single-read / idle session is reused by the first continuous read (config-
  // matched), so a spectrophotometer does NOT re-run the calibrate/aim wizard
  // every time continuous starts (which would block the loop on the setup step).
	  if(_priorSeriesRunning){
	   try{
	    await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
	   }catch(e){}
	  }
	  meterContinuousActive=true;
	  meterContinuousRetryDelayMs=50;
	  meterContinuousStartupErrors=0;
	  meterContinuousHadFirstRead=false;
	  meterSeriesAwaitingReady=false;
	  meterReadySignalPending=false;
  document.getElementById('meterContinuous').classList.remove('btn-secondary');
  document.getElementById('meterContinuous').classList.add('btn-success');
  meterUpdateReadButtons();
  meterContinuousLoop();
 }
}

async function meterContinuousLoop(){
	 meterContinuousTimer=null;
	 if(!meterContinuousActive) return;
	 if(meterSeriesRunning){toast('Series scan is running',true);meterStopContinuous();return;}
	 if(meterContinuousSuspendedForLgWrite||meterLgGreyBusy){
	  meterContinuousTimer=setTimeout(meterContinuousLoop,300);
	  return;
	 }
 let nextDelay=meterContinuousRetryDelayMs||50;
 document.getElementById('meterDot').style.background='var(--orange)';
 // Pulse ONLY the selected thumb during continuous reads.
 const contIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
 if(meterSeriesSteps){
  const isColorC=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedStepsC=isColorC?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
  const doneC=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneC.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedStepsC,doneC,contIre);
 }
 if(meterCurrentPatchStep){
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterProgressLabel').textContent=(meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%')+' (reading)';
 }
 // Raise the shared spectro setup modal in 'Working…' mode at the start of
 // each iteration. The first iteration may take 1-5+ s while the spectro
 // boots; the operator would otherwise be staring at a blank screen waiting
 // for the white-tile prompt. Subsequent iterations also flash the modal
 // briefly (until polling sees no setup state and hides it), which doubles
 // as per-read click feedback. Gated on the selected meter being a spectro
 // so colorimeter users don't see the "Spectrophotometer Setup" flash.
 // Only while the meter is still coming up (before the FIRST reading): once a
 // reading has landed the session is up, and re-raising the modal every
 // iteration produced a perpetual "Preparing the meter" flash on a spectro.
 if(meterSelectedMeasurementRequiresReady()&&!meterContinuousReadInFlight&&!meterContinuousHadFirstRead){
  meterSpectroSetupApply({keepBusy:true,message:'Preparing the meter\u2026'},'/api/meter/setup/ack');
 }
 try{
  const dtype=getEffectiveDisplayType();
  const rr=getMeterRefreshRate();
  const delay=meterDelayMs();
	  const requestedStep=meterClonePatchStep(meterCurrentPatchStep);
  const patternSignalRange=meterMeasurementPatchSignalRange();
	  const readPayload=meterMeasurementSignalContext({display_type:dtype,refresh_rate:rr||undefined,delay_ms:delay,ccss_override:(typeof getCcssOverride==='function')?getCcssOverride():undefined,target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',target_gamma:meterAutoCalTargetGammaValue(),pattern_provider:meterCalibrationReadPatternProvider()});
	  if(requestedStep){
	   meterApplyReadStepPayload(readPayload,requestedStep);
	   readPayload.patch_size=getMeterPatchSize();
	   if(patternSignalRange!=null) readPayload.signal_range=patternSignalRange;
		  }
	  readPayload.continuous=true;
	  readPayload.require_device_ready=meterSelectedMeasurementRequiresReady();
	  const readSuspendToken=meterContinuousSuspendToken;
		  if(!meterContinuousActive||meterContinuousSuspendedForLgWrite||meterLgGreyBusy){
		   document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
		   return;
		  }
		  meterContinuousReadInFlight=true;
		  const initR=await fetchJSON('/api/meter/read',{method:'POST',headers:{'Content-Type':'application/json'},
		   body:JSON.stringify(readPayload),_quiet:true,_timeoutMs:90000});
	  if(!initR||(initR&&initR.status==='error')){
	   meterContinuousReadInFlight=false;
	   await meterRestoreStabilizationAfterMeasurement();
	   const msg=String((initR&&initR.message)||'Meter read connection error');
	   const transient=/communication|connection|init|start|fifo|timeout|unavailable/i.test(msg);
	   meterContinuousStartupErrors++;
	   if(transient&&meterContinuousStartupErrors<=5){
	    meterContinuousRetryDelayMs=Math.min(2000,Math.max(500,(meterContinuousRetryDelayMs||50)*2));
	    nextDelay=meterContinuousRetryDelayMs;
	    const label=document.getElementById('meterProgressLabel');
	    if(label) label.textContent='Starting meter session...';
	    if(meterContinuousActive) meterContinuousTimer=setTimeout(meterContinuousLoop,nextDelay);
	    return;
	   }
	   meterStopContinuous();
	   toast(msg,true);
	   return;
	  }
	  const r=await meterPollRead(180000,()=>!meterContinuousActive);
	  meterContinuousReadInFlight=false;
  await meterRestoreStabilizationAfterMeasurement();
  if(r&&r.status==='cancelled'){
   document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
   if(meterContinuousActive) meterContinuousTimer=setTimeout(meterContinuousLoop,nextDelay);
   return;
  }
	  if(r&&r.status==='ok'&&r.readings&&r.readings.length>0){
	    meterContinuousRetryDelayMs=50;
	    meterContinuousStartupErrors=0;
	    meterContinuousHadFirstRead=true;
	    nextDelay=50;
   const rd=r.readings[0];
    meterNormalizeMeasuredReading(rd);
   // Drop the entire result if the user switched thumbnails mid-read. In the
   // normal preview mode that can change the displayed light; in measurement-
   // only mode it changes which step the next iteration will read. Either way,
   // the completed sample belongs only to requestedStep.
   const stillOnRequested=!requestedStep||!meterCurrentPatchStep||meterStepNameKey(meterCurrentPatchStep)===meterStepNameKey(requestedStep);
   const invalidatedByLgWrite=readSuspendToken!==meterContinuousSuspendToken;
   if(!stillOnRequested||invalidatedByLgWrite){
    // Skip storage, live readout, and chart redraw; the next iteration will
    // fire fresh against the now-current patch.
   } else {
   const stampStep=requestedStep;
   if(meterSeriesSteps&&stampStep){
    meterUpsertSeriesReading(rd,stampStep);
    const white=meterFindSeriesWhiteReading(meterReadings);
    if(white) meterWhiteReading=white;
    const completedIresC=new Set();
    meterReadings.forEach(x=>{if(x.luminance!=null) completedIresC.add(meterStepNameKey(x));});
    const isColorL=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
    const sortedL=isColorL?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
    drawAllCharts(sortedL);
    updateLiveReading(rd);
    meterCacheSeriesState(meterContinuousActive?'running':'complete');
    const sortedStepsL=isColorL?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
    // Keep pulsing on whatever patch is CURRENTLY selected (user may have
    // clicked a different thumb while the read was in flight).
    const nowIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
    meterBuildPatchThumbs(sortedStepsL,completedIresC,nowIre);
   }
   }
  } else {
   meterContinuousRetryDelayMs=Math.min(1000,Math.max(250,(meterContinuousRetryDelayMs||50)*2));
   nextDelay=meterContinuousRetryDelayMs;
  }
	 }catch(e){
	  meterContinuousReadInFlight=false;
	  await meterRestoreStabilizationAfterMeasurement();
	  meterContinuousStartupErrors++;
	  meterContinuousRetryDelayMs=Math.min(1000,Math.max(250,(meterContinuousRetryDelayMs||50)*2));
	  nextDelay=meterContinuousRetryDelayMs;
	 }
 document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
 if(meterContinuousActive) meterContinuousTimer=setTimeout(meterContinuousLoop,nextDelay);
}

function meterStopContinuous(options){
 const silent=!!(options&&options.silent);
 const wasActive=meterContinuousActive;
 if(!silent){
  meterContinuousSuspendedForLgWrite=false;
  meterContinuousSuspendToken++;
 }
 meterContinuousActive=false;
 meterContinuousRetryDelayMs=50;
 meterContinuousStartupErrors=0;
 meterClearManualPromptAwaiting(true);
 if(meterContinuousTimer) clearTimeout(meterContinuousTimer);
 meterContinuousTimer=null;
 // Hide the shared spectro setup modal when continuous stops. Normal per-
 // iteration polls hide it on success, but the terminal "too many startup
 // errors" branch in meterContinuousLoop calls meterStopContinuous() without
 // ever returning a polled result, leaving the preemptively-raised modal up.
 meterSpectroSetupApply(null);
 if(!silent){
  document.getElementById('meterContinuous').classList.remove('btn-success');
  document.getElementById('meterContinuous').classList.add('btn-secondary');
 }
 // Stopping continuous no longer tears down the meter session. The spotread
 // session idles between reads and is reused by the next read, so a
 // spectrophotometer keeps its calibration across stop/switch-series/clear.
 // The meter is freed only by explicit Stop, by series/AutoCal startup, by a
 // config change (display/CCSS/port), or by the session's idle timeout.
 let stopPromise=null;
 if(!silent){
  document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
  meterHideProgressIfIdle();
  // Clear continuous-read pulse.
  if(meterSeriesSteps){
   const isColorCS=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
   const sortedStepsCS=isColorCS?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
   const doneCS=new Set();
   meterReadings.forEach(r=>{if(r.luminance!=null) doneCS.add(meterStepNameKey(r));});
   meterBuildPatchThumbs(sortedStepsCS,doneCS,null);
  }
  meterUpdateReadButtons();
 }
 return stopPromise;
}

function meterClonePatchStep(step){
	 if(!step) return null;
	 try{
	  return JSON.parse(JSON.stringify(step));
	 }catch(e){
	  return Object.assign({},step);
	 }
	}

async function meterPauseContinuousForPriorityWrite(step){
	 const restoreStep=meterClonePatchStep(step);
	 const shouldResume=!!(meterContinuousActive||meterContinuousSuspendedForLgWrite);
	 if(!shouldResume) return {resume:false,token:meterContinuousSuspendToken,step:restoreStep};
	 meterContinuousSuspendedForLgWrite=true;
	 const token=++meterContinuousSuspendToken;
	 if(meterContinuousTimer) clearTimeout(meterContinuousTimer);
	 meterContinuousTimer=null;
	 meterUpdateReadButtons();
	 return {resume:true,token:token,step:restoreStep};
	}

function meterResumeContinuousAfterPriorityWrite(pauseState){
	 const shouldResume=!!(pauseState&&pauseState.resume);
	 const token=pauseState?pauseState.token:null;
	 if(!shouldResume){
	  meterContinuousSuspendedForLgWrite=false;
	  meterUpdateReadButtons();
	  return;
	 }
	 setTimeout(()=>{
	  if(token!==meterContinuousSuspendToken) return;
	  if(meterActionPending||meterSeriesRunning||meterSeriesAwaitingReady||meterManualPromptAwaiting){
	   meterContinuousSuspendedForLgWrite=false;
	   meterUpdateReadButtons();
	   return;
	  }
	  meterContinuousSuspendedForLgWrite=false;
	  meterContinuousRetryDelayMs=50;
  meterContinuousStartupErrors=0;
  document.getElementById('meterContinuous').classList.remove('btn-secondary');
  document.getElementById('meterContinuous').classList.add('btn-success');
  meterUpdateReadButtons();
  if(!meterContinuousActive) meterContinuousActive=true;
  if(!meterContinuousReadInFlight&&!meterContinuousTimer) meterContinuousLoop();
 },75);
}

async function meterStop(){
 const fullReportSeriesActive=!!(meterFullAutoCalRunning&&meterSeriesRunning&&!meterLg3dAutoCalRunning&&!meterAutoCalRunning);
 if(meterDvAutoCalProfileRunning){
  return meterStopDvAutoCalProfile();
 }
 if(meterLg3dAutoCalRunning){
  return meterStopLg3dAutoCal();
 }
 if(meterAutoCalRunning){
  return meterStopAutoCal();
 }
 if(meterFullAutoCalRunning&&!fullReportSeriesActive){
  return meterFullAutoCalAbort('Full Auto Cal stopped',false);
 }
 const hadContinuousStop=meterContinuousActive||meterContinuousSuspendedForLgWrite;
 const hadManualStop=meterManualPromptAwaiting;
 meterStopContinuous();
 meterClearInteractiveSelection(true);
 if(meterSeriesPolling){clearInterval(meterSeriesPolling);meterSeriesPolling=null;}
 const hadSeriesStop=meterSeriesRunning||meterSeriesAwaitingReady||meterSeriesSpectroSetupActive;
 meterSeriesRunning=false;
 meterSeriesAwaitingReady=false;
 meterSeriesSpectroSetupActive=false;
 meterReadySignalPending=false;
 meterPendingDeviceReadyAction=null;
 const continuousOnlyStop=hadContinuousStop&&!hadSeriesStop&&!hadManualStop;
 // Continuous mode uses the reusable meter_session. Stopping its browser loop
 // must not tear down spotread: let any in-flight read finish, then leave the
 // session idle for the next Read Once/Continuous request. Series and explicit
 // manual/setup stops still call the backend because they own work that must
 // be cooperatively cancelled.
 const needsBackendStop=!continuousOnlyStop;
 if(hadSeriesStop&&meterBuild3dLutPending) meterBuild3dLutMeasureHide();
 if(hadSeriesStop) meterBuild3dLutPending=null;
 meterClearManualPromptAwaiting(true);
 meterSpectroSetupApply(null);
 meterActionPending=hadSeriesStop||hadContinuousStop||hadManualStop;
 // Blocking modal while the stop RTT runs. Without it the series buttons
 // look idle but meterActionPending freezes every click until the helper
 // is actually dead (often several seconds on a mid-read series).
 if(hadSeriesStop||hadContinuousStop||hadManualStop){
  meterStopModalShow(hadSeriesStop?'series':(hadContinuousStop?'continuous':'meter'));
 }
 document.getElementById('meterReadOnce').innerHTML='&#9679; Read Once';
 document.getElementById('meterReadSeriesBtn').innerHTML=meterReadSeriesButtonLabel();
 document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
 document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
 // Clear the "currently reading" pulse animation on whichever thumb was last
 // being measured — without this, the last-polled thumb keeps pulsing as if
 // the series is still running.
 if(meterSeriesSteps){
  const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps=isColor?[...meterSeriesSteps]:meterGreyscaleSeriesSteps(meterSeriesSteps);
  const completedIres=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) completedIres.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedSteps,completedIres,null);
 }
 meterHideWorkflowProgress();
 meterUpdateReadButtons();
 let stopRequestConfirmed=false;
 const waitForSeriesTeardown=async()=>{
  const started=Date.now();
  let lastRetry=started;
  while(true){
   const status=await fetchJSON('/api/meter/stop/status',{_quiet:true,_timeoutMs:5000});
   if(status&&status.series_alive===false&&status.spotread_alive===false) return;
   const elapsed=Date.now()-started;
   const statusEl=document.getElementById('meterStopStatus');
   if(statusEl){
    statusEl.textContent=elapsed>=30000
     ? 'Finishing the current meter transaction and closing the series\u2026'
     : 'Waiting for the series and meter to stop\u2026';
   }
   // Cancellation is idempotent. If the original request was lost during a
   // network hiccup, re-send it occasionally rather than leaving the modal
   // polling a series that was never signalled.
   if(!stopRequestConfirmed&&Date.now()-lastRetry>=5000){
    lastRetry=Date.now();
    const retry=await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
    stopRequestConfirmed=!!(retry&&retry.status==='ok');
   }
   await new Promise(resolve=>setTimeout(resolve,500));
  }
 };
 let patternStopped=false;
 try{
  if(needsBackendStop){
   const stopResult=await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:15000});
   stopRequestConfirmed=!!(stopResult&&stopResult.status==='ok');
  }
  // Blank the Pi output or restore the companion alignment pattern immediately,
  // but leave the modal and interaction lock in place until spotread exits.
  try{
   await meterStopCalibrationPattern();
   patternStopped=true;
  }catch(e){}
  if(hadSeriesStop) await waitForSeriesTeardown();
 }catch(e){
  // A transient request failure is handled by the polling loop's idempotent
  // stop retry. For non-series stops, preserve the previous best-effort flow.
  if(hadSeriesStop) await waitForSeriesTeardown();
 }finally{
  if(!patternStopped){
   try{
    await meterStopCalibrationPattern();
   }catch(e){}
  }
  meterActionPending=false;
  meterStopModalHide();
  meterUpdateReadButtons();
 }
 if(fullReportSeriesActive) meterFullAutoCalAbort('Full Auto Cal stopped',false);
}

async function meterSignalDeviceReady(){
 if(meterReadySignalPending||!meterSeriesAwaitingReady) return;
 const progressEl=document.getElementById('meterProgressLabel');
 const previousLabel=progressEl?(progressEl.textContent||''):'';
 meterReadySignalPending=true;
 meterUpdateReadButtons();
 try{
  if(meterPendingDeviceReadyAction){
   const action=meterPendingDeviceReadyAction;
   meterPendingDeviceReadyAction=null;
   await action();
   return;
  }
  const r=await fetchJSON('/api/meter/series/ready',{method:'POST',_timeoutMs:5000});
  if(!r||r.status!=='ok'){
  if(r&&/not waiting for device readiness/i.test(r.message||'')){
   meterSeriesAwaitingReady=false;
   await meterSyncSeriesAfterReady(previousLabel,4000);
   return;
  }
   toast(r&&r.message?r.message:'Failed to resume measurement',true);
   return;
  }
  meterSeriesAwaitingReady=false;
  await meterSyncSeriesAfterReady(previousLabel,4000);
 }catch(e){
  toast('Failed to resume measurement',true);
 }finally{
  meterReadySignalPending=false;
  meterUpdateReadButtons();
 }
}

async function meterSyncSeriesAfterReady(previousLabel,timeoutMs){
 const start=Date.now();
 const prior=(previousLabel||'');
 let idleSince=0;
 while(Date.now()-start<Math.max(250,Number(timeoutMs)||0)){
  try{
  await meterPollSeries();
  }catch(e){}
  const progressEl=document.getElementById('meterProgressLabel');
  const currentLabel=progressEl?(progressEl.textContent||''):'';
  if(currentLabel!==prior) return;
  if(!meterSeriesRunning) return;
  if(!meterSeriesAwaitingReady){
   if(!idleSince) idleSince=Date.now();
   if(Date.now()-idleSince>=750) return;
  } else {
   idleSince=0;
  }
  await new Promise(r=>setTimeout(r,150));
 }
}

async function meterResetUSB(){
 toast('Resetting USB...');
 const r=await fetchJSON('/api/meter/reset',{method:'POST',_timeoutMs:15000});
 if(r&&r.status==='ok'){
  toast('USB reset done, checking meter...');
  await new Promise(r=>setTimeout(r,2000));
  await meterCheckStatus();
  if(meterDetected) toast('Meter reconnected!');
  else toast('Meter still not detected after USB reset',true);
 } else {
  toast(r&&r.message?r.message:'USB reset failed',true);
 }
}

let meterSeriesSteps=null; // steps for loaded series
let meterActiveSeriesKey=null; // track which series button is active
let meterActiveSeriesType=null; // series type (greyscale/colors/saturations)
let meterActiveSeriesPoints=null; // series point count
// Last series the operator chose per tab. Switching to the 3D LUT workspace
// sets the 3dlut tab, and coming back sets the greyscale tab again -- a tab
// CHANGE, so the guard in meterSetSeriesTab falls through to the tab's default
// button (the first visible one, Greyscale 2pt) and silently discarded a 21pt
// or 26pt selection. Remember the choice and return to it instead.
const meterLastSeriesByTab={};
let meterActiveSeriesSignalMode=null; // signal mode tied to active series snapshot
let meterActiveSeriesTargetGamma=null; // target transfer function tied to active series snapshot
let meterActiveSeriesMaxLuma=null; // HDR/DV peak tied to active series snapshot
let meterActiveSeriesDvMapMode=null; // DV absolute/relative mode tied to active series snapshot
let meterActiveSeriesDvInterface=null; // DV standard/low-latency interface tied to active series snapshot
let meterCurrentPatchStep=null; // currently displayed patch step object
let meterPatternDisplayToken=0; // invalidates queued patch-display requests
let meterPatternDisplayQueue=Promise.resolve(); // serialize latest-wins display writes
let meterSeriesRunning=false; // true when Read Series is actively running
let meterSelectedThumbIndices=new Set(); // visible thumbnail indices selected for a partial series
let meterThumbSelectionAnchor=null; // shift-range anchor in visible thumbnail order
let meterThumbSuppressClickUntil=0; // prevents the click following a drag-box selection
let meterThumbDragState=null;
let meterSeriesSelectionRunActive=false;
// Step identities selected by Read Selection. The run temporarily clears the
// interactive state while the meter owns the patch, then restores these exact
// patches at completion so the same subset can be read again.
let meterSelectionRunStepKeys=[];
// Snapshot of chart readings when Read Selection starts so partial re-reads
// merge into the existing series instead of wiping the charts first.
let meterSelectionBaselineReadings=null;
// Pre-run measured white for Read Selection. Mid-grey selections omit 100%;
// without this, post-run error math falls back to the brightest selected patch.
let meterSelectionBaselineWhite=null;
let meterSelectionWillMeasureWhite=false;
// Full-series references retained from the current mode until a new reference
// pre-read replaces them. They are not plotted as series patches.
let meterSeriesBaselineBlack=null;
let meterSeriesWaitingForWhiteReference=false;
let meterAutoCalRecoveryInFlight=false; // true while a refreshed page is checking for a backend AutoCal run
let meterVisibleStepsCacheSource=null;
let meterVisibleStepsCacheType=null;
let meterVisibleStepsCacheResult=null;
let meterVisibleStepsIndexCacheSource=null;
let meterVisibleStepsIndexCache=null;
let meterCanonicalStepCacheSource=null;
let meterCanonicalStepCache=null;

// A Read Selection worker intentionally reports only the patches it was asked
// to measure (plus optional white/black reference steps). Those worker steps
// are correct for progress/current-patch tracking, but they are not the series
// definition shown by the thumbnail strip. After refresh, retain/rebuild the
// larger matching series so unselected thumbnails do not disappear.
function meterRecoveryDisplaySteps(type,points,workerSteps){
 const run=Array.isArray(workerSteps)?workerSteps:[];
 if(!run.length) return run;
 const candidates=[];
 if(meterActiveSeriesType===type&&Number(meterActiveSeriesPoints)===Number(points)
    &&Array.isArray(meterSeriesSteps)&&meterSeriesSteps.length+2>=run.length){
  candidates.push(meterSeriesSteps);
 }
 try{
  const rebuilt=meterBuildStepsJS(type,points);
  if(Array.isArray(rebuilt)&&rebuilt.length+2>=run.length) candidates.push(rebuilt);
 }catch(e){}
 const runKeys=run.map(step=>meterStepNameKey(step)).filter(Boolean);
 for(const candidate of candidates){
  const candidateKeys=new Set(candidate.map(step=>meterStepNameKey(step)).filter(Boolean));
  const matched=runKeys.reduce((count,key)=>count+(candidateKeys.has(key)?1:0),0);
  // Selection may prepend measured-reference White/Black steps that are not
  // part of a custom series. Allow those two extras, but require every other
  // worker patch to belong to the candidate before treating it as the parent.
  if(matched>=Math.max(1,runKeys.length-2)) return candidate;
 }
 return run;
}

function meterVisibleSeriesSteps(){
 const source=Array.isArray(meterSeriesSteps)?meterSeriesSteps:[];
 if(meterVisibleStepsCacheSource===source&&meterVisibleStepsCacheType===meterActiveSeriesType&&Array.isArray(meterVisibleStepsCacheResult)){
  return meterVisibleStepsCacheResult;
 }
 const ordered=(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')
  ? [...source]
  : meterGreyscaleSeriesSteps(source);
 meterVisibleStepsCacheSource=source;
 meterVisibleStepsCacheType=meterActiveSeriesType;
 meterVisibleStepsCacheResult=meterFilterLgAutoCalChartItems(ordered)
  .filter(step=>!meterIsWhiteReferenceReading(step));
 meterVisibleStepsIndexCacheSource=null;
 meterVisibleStepsIndexCache=null;
 return meterVisibleStepsCacheResult;
}

function meterVisibleSeriesStepIndex(step){
 if(!step) return -1;
 const steps=meterVisibleSeriesSteps();
 if(meterVisibleStepsIndexCacheSource!==steps||!meterVisibleStepsIndexCache){
  const byObject=new Map();
  const byKey=new Map();
  steps.forEach((candidate,index)=>{
   byObject.set(candidate,index);
   const key=meterStepNameKey(candidate);
   if(key&&!byKey.has(key)) byKey.set(key,index);
   const name=String((candidate&&candidate.name)||'');
   if(name&&!byKey.has('name:'+name)) byKey.set('name:'+name,index);
  });
  meterVisibleStepsIndexCacheSource=steps;
  meterVisibleStepsIndexCache={byObject:byObject,byKey:byKey};
 }
 const direct=meterVisibleStepsIndexCache.byObject.get(step);
 if(direct!=null) return direct;
 const canonical=meterCanonicalSeriesStep(step)||step;
 const canonicalDirect=meterVisibleStepsIndexCache.byObject.get(canonical);
 if(canonicalDirect!=null) return canonicalDirect;
 const key=meterStepNameKey(canonical);
 if(key&&meterVisibleStepsIndexCache.byKey.has(key)) return meterVisibleStepsIndexCache.byKey.get(key);
 const name=String((canonical&&canonical.name)||'');
 return name&&meterVisibleStepsIndexCache.byKey.has('name:'+name)
  ?meterVisibleStepsIndexCache.byKey.get('name:'+name)
  :-1;
}

function meterSelectedPatchCount(){
 return meterSelectedThumbIndices instanceof Set ? meterSelectedThumbIndices.size : 0;
}

function meterClearMultiPatchSelection(){
 meterSelectedThumbIndices=new Set();
 meterThumbSelectionAnchor=null;
}

function meterRestoreSelectionRunPatches(){
 const wanted=new Set(Array.isArray(meterSelectionRunStepKeys)?meterSelectionRunStepKeys:[]);
 meterSelectionRunStepKeys=[];
 if(!wanted.size) return;
 const next=new Set();
 meterVisibleSeriesSteps().forEach((step,index)=>{
  if(wanted.has(meterStepNameKey(step))) next.add(index);
 });
 meterSelectedThumbIndices=next;
 meterThumbSelectionAnchor=next.size?Math.min(...Array.from(next)):null;
}

function meterThumbStepAt(index){
 const steps=meterVisibleSeriesSteps();
 return (index>=0&&index<steps.length)?steps[index]:null;
}

function meterThumbIndexForStep(step){
 return meterVisibleSeriesStepIndex(step);
}

function meterRefreshThumbSelectionStyles(suppressButtonUpdate){
 const container=document.getElementById('meterPatchThumbs');
 if(!container) return;
 const completed=new Set((meterReadings||[]).filter(r=>r&&r.luminance!=null).map(r=>meterStepNameKey(r)));
 meterUpdateThumbStyles(container,completed,null);
 if(!suppressButtonUpdate) meterUpdateReadButtons();
}

function meterDisplayFirstSelectedPatch(){
 if(!meterSelectedThumbIndices.size){
  meterDeselectCurrentPatch();
  return;
 }
 const index=Math.min(...Array.from(meterSelectedThumbIndices));
 const step=meterThumbStepAt(index);
 if(step) meterSelectPatchFromInteraction(step,meterFindReadingForStep(step),{pin:true,preserveMulti:true});
}

function meterApplyThumbSelection(indices,opts){
 opts=opts||{};
 const steps=meterVisibleSeriesSteps();
 const next=opts.additive?new Set(meterSelectedThumbIndices):new Set();
 Array.from(indices||[]).forEach(raw=>{
  const index=Number(raw);
  if(Number.isInteger(index)&&index>=0&&index<steps.length) next.add(index);
 });
 meterSelectedThumbIndices=next;
 if(Number.isInteger(opts.anchor)) meterThumbSelectionAnchor=opts.anchor;
 const currentIndex=meterThumbIndexForStep(meterCurrentPatchStep);
 if(!meterSelectedThumbIndices.size){
  meterDeselectCurrentPatch();
  return;
 }
 if(opts.displayFirst||currentIndex<0||!meterSelectedThumbIndices.has(currentIndex)){
  meterDisplayFirstSelectedPatch();
 }else{
  meterRefreshThumbSelectionStyles();
 }
}
function meterUpdateDeltaEFormControl(){
 const greySel=document.getElementById('meterDeltaEForm');
 const twoPointSel=document.getElementById('meterTwoPointDeltaEForm');
 const colorSel=document.getElementById('meterColorDeltaEForm');
 const colorWrap=document.getElementById('meterColorDeltaEFormWrap');
 const colorMode=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(greySel){
  greySel.disabled=false;
  greySel.title=colorMode?'Changes the greyscale ΔE calculation used when greyscale charts are shown':'Changes the greyscale ΔE calculation';
 }
 if(twoPointSel&&greySel&&twoPointSel.value!==greySel.value) twoPointSel.value=greySel.value;
 if(colorWrap) colorWrap.style.display=colorMode?'flex':'none';
 if(colorSel){
  colorSel.disabled=false;
  colorSel.title='Changes the color and saturation-sweep ΔE calculation';
 }
}

function meterOnTwoPointDeltaEFormChange(){
 const twoPointSel=document.getElementById('meterTwoPointDeltaEForm');
 const greySel=document.getElementById('meterDeltaEForm');
 if(twoPointSel&&greySel) greySel.value=twoPointSel.value;
 meterOnGreyRefChange();
 try{ saveMeterSettings(); }catch(e){}
}

function meterClearInteractiveSelection(keepLiveReading){
 meterPatternDisplayToken++;
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 meterClearMultiPatchSelection();
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 const container=document.getElementById('meterPatchThumbs');
 if(container&&container.children.length>0){
  const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  if(isColorSeries){
   colorHighlightThumb(null);
   colorHighlightTableRow(null);
   showColorReadingDetail(null);
  } else {
   const completed=new Set((meterReadings||[]).filter(r=>r&&r.luminance!=null).map(r=>meterStepNameKey(r)));
   meterUpdateThumbStyles(container,completed,null);
  }
 }
 if(!keepLiveReading){
  document.getElementById('meterLiveReading').style.display='none';
  document.getElementById('meterProgress').style.display='none';
 }
 meterUpdateReadButtons();
}

function meterIsPatchStepSelected(step){
 if(!meterCurrentPatchStep||!step) return false;
 const cur=meterCanonicalSeriesStep(meterCurrentPatchStep)||meterCurrentPatchStep;
 const sel=meterCanonicalSeriesStep(step)||step;
 return meterStepNameKey(cur)===meterStepNameKey(sel);
}

function meterPatchDisplayLockedForRead(){
 return !!(
  meterSeriesRunning
  ||meterContinuousActive
  ||meterContinuousSuspendedForLgWrite
  ||meterContinuousReadInFlight
  ||meterActionPending
  ||meterSeriesAwaitingReady
  ||meterManualPromptAwaiting
  ||meterAutoCalStatusActive()
 );
}

function meterDeselectCurrentPatch(options){
 // Click-away deselection normally stops the displayed pattern. During any
 // read that would change the light being integrated by the meter, so keep
 // the current patch selected unless a workflow explicitly forces teardown.
 if(meterPatchDisplayLockedForRead()&&!(options&&options.force)){
  const currentIndex=meterThumbIndexForStep(meterCurrentPatchStep);
  if(currentIndex>=0){
   meterSelectedThumbIndices=new Set([currentIndex]);
   meterThumbSelectionAnchor=currentIndex;
   meterSelectedThumbIre=meterStepNameKey(meterCurrentPatchStep);
   meterRefreshThumbSelectionStyles();
  }
  return false;
 }
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 meterClearMultiPatchSelection();
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 const container=document.getElementById('meterPatchThumbs');
 if(container&&container.children.length>0){
  const completed=new Set((meterReadings||[]).filter(r=>r&&r.luminance!=null).map(r=>meterStepNameKey(r)));
  meterUpdateThumbStyles(container,completed,null);
 }
 if(typeof colorHighlightThumb==='function') colorHighlightThumb('');
 if(typeof colorHighlightTableRow==='function') colorHighlightTableRow('');
 meterResetLiveReadingDisplay();
 const liveEl=document.getElementById('meterLiveReading');
 if(liveEl) liveEl.style.display='none';
 meterUpdateReadButtons();
 try{ fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'}),_quiet:true,_timeoutMs:5000}); }catch(_e){}
 return true;
}
function meterSelectPatchFromInteraction(step,reading,opts){
	 if(!step) return;
	 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
	 const resolvedStep=meterCanonicalSeriesStep(step)||step;
	 if(!(opts&&opts.preserveMulti)){
	  const index=meterThumbIndexForStep(resolvedStep);
	  meterSelectedThumbIndices=(index>=0)?new Set([index]):new Set();
	  meterThumbSelectionAnchor=(index>=0)?index:null;
	 }
	 // Only a real meter sample for THIS step counts as measured. Never treat
	 // the series step (or a leftover ColorChecker reading) as the measurement.
	 let resolvedReading=meterFindReadingForStep(resolvedStep);
	 if(!resolvedReading&&reading&&meterReadingIsRealMeasurement(reading)
	    &&meterColorReadingMatchesStep(reading,resolvedStep)){
	  resolvedReading=reading;
	 }
	 if(resolvedReading&&!meterReadingIsRealMeasurement(resolvedReading)) resolvedReading=null;
	 meterCurrentPatchStep=resolvedStep;
 meterLgGreySyncForCurrentStep(false);
 if(isColorSeries){
  const pin=!(opts&&opts.pin===false);
  // Keep thumb selection key so rebuild/restyle (desktop refresh, caps) still
  // marks the chosen colour patch, not only greyscale.
  meterSelectedThumbIre=meterStepNameKey(resolvedStep)||String(resolvedStep.name||'')||null;
  if(resolvedReading) meterFocusColorReading(resolvedReading,{pin:pin});
  else {
   // Unread node: targets only, measured = --
   const unread=meterColorUnreadDetailFromStep(resolvedStep);
   if(unread) showColorReadingDetail(unread,{pin:pin});
   else if(resolvedStep.name){
    _selectedColorReadingName=resolvedStep.name||null;
    _colorDetailPinned=pin&&!!_selectedColorReadingName;
    colorHighlightTableRow(resolvedStep.name);
   }
  }
  // Always restyle thumbs after focus: multi-select must keep every selected
  // ring (colorHighlightThumb alone only paints one name).
  if(meterSelectedThumbIndices&&meterSelectedThumbIndices.size>1){
   try{ meterRefreshThumbSelectionStyles(true); }catch(e){}
  }else if(resolvedStep.name){
   try{ colorHighlightThumb(resolvedStep.name); }catch(e){}
  }
 } else {
  meterSelectedThumbIre=meterStepNameKey(resolvedStep);
  const container=document.getElementById('meterPatchThumbs');
  if(container&&container.children.length>0){
   const completed=new Set((meterReadings||[]).filter(r=>r&&r.luminance!=null).map(r=>meterStepNameKey(r)));
   meterUpdateThumbStyles(container,completed,null);
  }
 }
 if(resolvedReading) updateLiveReading(resolvedReading);
 else meterClearLiveReading(resolvedStep);
	 if(meterStabilizationMeasurementOnlyEnabled()){
	  // Selecting a thumbnail changes the requested/UI step only. Preserve the
	  // current measurement patch while a read is active; otherwise make sure
	  // the configured stabilization pattern owns the idle display.
	  if(typeof activePattern!=='undefined'&&activePattern!=null) clearActive();
	  if(!meterPatchDisplayLockedForRead()) meterRestoreStabilizationAfterMeasurement();
	 }else{
	  meterDisplayPatch(resolvedStep,{fresh:false,allowAfterStop:true});
	 }
 document.getElementById('meterLiveReading').style.display='';
 meterHideProgressIfIdle();
 meterUpdateReadButtons();
}

function meterHideSeriesControlsForAutoCal(){
 const phase=String(meterAutoCalPhase||'');
 const greyscaleAutoCalActive=!!(meterAutoCalPolling||meterAutoCalPendingConfig||(meterAutoCalRunning&&phase!=='complete'&&phase!=='error'));
 return !!(greyscaleAutoCalActive||meterLg3dAutoCalRunning||meterLg3dAutoCalPolling||meterFullAutoCalRunning);
}

function meterAutoCalControlsAllowedForSignal(){
 // HLG has no supported AutoCal pipeline (no greyscale/3D-LUT calibration
 // workspace) and stays hidden. Dolby Vision now has one (see the
 // dv-profile-upload endpoints) -- reusing the same HDR20 greyscale ladder
 // plus a one-shot panel-profile upload in place of a 3D LUT -- so it is no
 // longer excluded here.
 const sm=(getVal('signal_mode')||'sdr');
 return sm!=='hlg';
}

function meterAutoCalSeriesAvailable(){
 // A run in flight OWNS the AutoCal tab. Both inputs below flap transiently
 // while a worker holds the meter -- the DV profile worker in particular, and
 // any LG status refresh that briefly reports not-connected. Because
 // meterUpdateSeriesTabUi() switches the tab away from 'autocal' the moment
 // this returns false, a flap re-derived the series context from the default
 // greyscale ladder and the operator watched the live 26-point AutoCal
 // results change and disappear mid-run (reported during the Dolby Vision
 // config stage: the step row flipped from the 26-point ladder to the
 // 21-point one and the Auto Cal tab vanished, then came back). Stay
 // available for as long as something is actually running.
 if((typeof meterAutoCalRunning!=='undefined'&&meterAutoCalRunning)
  ||(typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
  ||(typeof meterLg3dAutoCalRunning!=='undefined'&&meterLg3dAutoCalRunning)
  ||(typeof meterDvAutoCalProfileRunning!=='undefined'&&meterDvAutoCalProfileRunning)
  ||(typeof meterDvProfileStandaloneRunning!=='undefined'&&meterDvProfileStandaloneRunning)) return true;
 // LG AutoCal requires a paired LG TV AND a connected meter -- without a
 // meter there is nothing to read, so the option must not even be
 // selectable (previously this only checked TV pairing + signal mode,
 // letting AutoCal show as a pickable series with no meter attached in any
 // picture mode). HLG has no calibration workspace (mirrors
 // meterAutoCalControlsAllowedForSignal); dv is allowed through.
 const lgPaired=(typeof meterGreyTvControlsActive==='function')&&meterGreyTvControlsActive();
 const sm=(getVal('signal_mode')||'sdr');
 const signalAllowed=(sm!=='hlg');
 // Meter presence no longer hides the tab: AutoCal stays discoverable and the
 // start paths refuse to launch without a real meter (the simulated meter is
 // also blocked because AutoCal writes calibration data into the TV).
 return !!(lgPaired&&signalAllowed);
}

// Standalone Tone Map series is HDR10-only (PQ peak + LG HDR tone-map
// upload). Hide the series picker in SDR/HLG/DV so it is not a dead control.
function meterToneMapSeriesAllowedForSignal(){
 const sm=String((typeof getVal==='function'?getVal('signal_mode'):'')||'').toLowerCase();
 if(sm==='hdr10') return true;
 // Live chart mode can lag the select briefly after Apply; honor either.
 try{
  if(typeof meterActiveChartSignalMode==='function'&&meterActiveChartSignalMode()==='hdr10') return true;
 }catch(e){}
 return false;
}

function meterUpdateReadButtons(){
 meterCalibrationReflectActualPatternProvider();
 meterAutoCalRepairOverlayPointerState();
 try{ meterUpdateChromaticityChartLock(); }catch(e){}
 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 const hasSelection=isColorSeries ? !!meterCurrentPatchStep : meterSelectedThumbIre!=null;
 const hasSeries=meterSeriesSteps&&meterSeriesSteps.length>0;
 // Read controls stay VISIBLE without a meter (disabled, with a tooltip) so
 // every feature is discoverable; the no-meter banner offers the simulated
 // meter for real interaction.
 const show=hasSeries&&hasSelection;
 const showSeries=hasSeries;
 const noMeterTitle='No meter connected. Connect a USB meter or enable the simulated meter.';
 const settingsDirty=hasUnsavedSettings();
 const continuousUiActive=meterContinuousActive||meterContinuousSuspendedForLgWrite;
 const busy=!!window._configApplyPending||meterActionPending||meterSeriesRunning||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning||continuousUiActive;
 const colorCheckerSelect=document.getElementById('meterColorCheckerSeriesSelect');
 if(colorCheckerSelect) colorCheckerSelect.disabled=busy;
 const greyscaleSelect=document.getElementById('meterGreyscaleSeriesSelect');
 if(greyscaleSelect) greyscaleSelect.disabled=busy;
 const hasData=Array.isArray(meterReadings)&&meterReadings.some(r=>r&&r.luminance!=null);
 const hideSeriesControlsForAutoCal=meterHideSeriesControlsForAutoCal();
 const autoCalSignalAllowed=meterAutoCalControlsAllowedForSignal();
 const autoCalSeriesAvailable=meterAutoCalSeriesAvailable();
 const on3dLutTab=meterSeriesTab==='3dlut';
 const has3dLutSeries=typeof meter3dLutTabHasSelectedSeries==='function'&&meter3dLutTabHasSelectedSeries();
 const empty3dLutTab=on3dLutTab&&!has3dLutSeries;
 // Clear Chart is meaningless on an empty 3D LUT tab (and would expose leftover ColorChecker data).
 const showClear=hasData&&!empty3dLutTab;
 const clearBtn=document.getElementById('meterClearChartBtn');
 const calibrateBtn=document.getElementById('meterCalibrateBtn');
 const readSeriesBtn=document.getElementById('meterReadSeriesBtn');
 const readSelectionBtn=document.getElementById('meterReadSelectionBtn');
 const readOnceBtn=document.getElementById('meterReadOnce');
 const continuousBtn=document.getElementById('meterContinuous');
 const autoCalBtn=document.getElementById('meterAutoCalBtn');
 const fullAutoCalBtn=document.getElementById('meterFullAutoCalBtn');
 const autoCalTarget=document.getElementById('meterAutoCalTarget');
 const lg3dColorControls=document.getElementById('meterLg3dColorControls');
 const lg3dBtn=document.getElementById('meterLg3dAutoCalBtn');
 const stopBtn=document.getElementById('meterStopBtn');
 const readyBtn=document.getElementById('meterDeviceReadyBtn');
 const manualPromptBtn=document.getElementById('meterManualPromptBtn');
 meterUpdateTargetMeasureButtons();
 if(clearBtn){
  clearBtn.style.display=(showClear&&!hideSeriesControlsForAutoCal)?'':'none';
  clearBtn.disabled=!hasData||busy||hideSeriesControlsForAutoCal||empty3dLutTab;
 }
 if(calibrateBtn){
  const showCalibration=meterDetected&&meterRequiresManualCalibration(meterSelectedMeasurementMeter())&&!on3dLutTab;
  calibrateBtn.style.display=(showCalibration&&!hideSeriesControlsForAutoCal)?'':'none';
  calibrateBtn.disabled=!showCalibration||settingsDirty||busy;
  calibrateBtn.title=settingsDirty
   ? 'Apply & Restart first so calibration uses the active meter settings'
   : busy
    ? 'Meter operation already in progress'
    : 'Run the selected meter calibration';
 }
 // On the 3D LUT tab, only expose Build 3D LUT once a profiling series is selected.
 const seriesControlsOk=on3dLutTab?has3dLutSeries:showSeries;
 if(readSeriesBtn){
  if(!meterSeriesRunning&&!meterActionPending) readSeriesBtn.innerHTML=meterReadSeriesButtonLabel();
  readSeriesBtn.disabled=!seriesControlsOk||!meterDetected||settingsDirty||busy;
  readSeriesBtn.title=!meterDetected?noMeterTitle:window._configApplyPending?'Applying settings...':settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':(on3dLutTab&&!has3dLutSeries?'Select a 3D LUT series first':'');
 }
 if(readOnceBtn) readOnceBtn.style.display=(show&&!continuousUiActive&&!on3dLutTab)?'':'none';
 if(continuousBtn) continuousBtn.style.display=(show&&!on3dLutTab)?'':'none';
 const toneMapSeriesActive=meterSeriesTab==='autocal'&&meterNormalizeAutoCalSeriesChoice(meterAutoCalSeriesChoice)==='tone-map';
 if(readSeriesBtn) readSeriesBtn.style.display=(seriesControlsOk&&!continuousUiActive&&!hideSeriesControlsForAutoCal&&!toneMapSeriesActive)?'':'none';
 if(readSelectionBtn){
  const selectionCount=meterSelectedPatchCount();
  const showSelection=selectionCount>1&&showSeries&&!continuousUiActive&&!hideSeriesControlsForAutoCal&&!toneMapSeriesActive;
  readSelectionBtn.style.display=showSelection?'':'none';
  readSelectionBtn.innerHTML='&#9654; Read Selection ('+selectionCount+')';
  readSelectionBtn.disabled=!showSelection||!meterDetected||settingsDirty||busy;
  readSelectionBtn.title=!meterDetected?noMeterTitle
   :window._configApplyPending?'Applying settings...'
   :settingsDirty?'Apply & Restart first so measurements match the live signal mode'
   :busy?'Meter operation already in progress'
   :'Read only the selected patches in thumbnail order';
 }
 const autoCalTabActive=meterSeriesTab==='autocal';
 const showAutoCal=autoCalSignalAllowed&&autoCalSeriesAvailable&&autoCalTabActive&&meterAutoCalSeriesChoice==='greyscale'&&!continuousUiActive;
 if(autoCalBtn){
  autoCalBtn.style.display=showAutoCal?'':'none';
  autoCalBtn.disabled=!showAutoCal||settingsDirty||busy;
  autoCalBtn.title=settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'';
 }
 const showFullAutoCal=autoCalSignalAllowed&&autoCalSeriesAvailable&&meterFullAutoCalAvailable()&&!continuousUiActive;
 if(fullAutoCalBtn){
  fullAutoCalBtn.style.display=showFullAutoCal?'':'none';
  fullAutoCalBtn.disabled=!showFullAutoCal||settingsDirty||busy;
  fullAutoCalBtn.title=settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'';
 }
 const showLg3d=autoCalSignalAllowed&&autoCalSeriesAvailable&&autoCalTabActive&&meterAutoCalSeriesChoice==='3d-lut'&&meterLg3dAutoCalAvailable()&&!continuousUiActive;
 if(lg3dColorControls) lg3dColorControls.style.display=showLg3d?'flex':'none';
 if(lg3dBtn){
  lg3dBtn.style.display=showLg3d?'':'none';
  lg3dBtn.disabled=!showLg3d||settingsDirty||busy;
  lg3dBtn.title=settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'';
 }
 const toneMapBtn=document.getElementById('meterToneMapMeasureUploadBtn');
 const toneMapHdrOk=typeof meterToneMapSeriesAllowedForSignal==='function'?meterToneMapSeriesAllowedForSignal():(String((typeof getVal==='function'?getVal('signal_mode'):'')||'').toLowerCase()==='hdr10');
 // Re-assert series picker visibility whenever read buttons refresh (signal
 // mode can change without re-entering the AutoCal tab). Do not call
 // meterSelectAutoCalGreyscale here — it re-enters this function.
 try{
  document.querySelectorAll('#meterSeriesGroupAutoCal button[data-autocal-series="tone-map"]').forEach(btn=>{
   btn.style.display=toneMapHdrOk?'':'none';
   btn.hidden=!toneMapHdrOk;
   btn.disabled=!toneMapHdrOk;
  });
  if(!toneMapHdrOk&&meterNormalizeAutoCalSeriesChoice(meterAutoCalSeriesChoice)==='tone-map'){
   meterSetAutoCalSeriesChoice('greyscale');
  }
 }catch(e){}
 // Dolby Vision has no 3D LUT stage -- its colour stage is the panel-profile
 // (DOLBY_CFG_DATA) upload. Swap the two buttons by signal mode so DV shows
 // "DV Config" where the other modes show "3D LUT", letting the operator run
 // greyscale and the DV config as separate passes.
 const dvSeriesOk=(String((typeof getVal==='function'?getVal('signal_mode'):'')||'').toLowerCase()==='dv');
 try{
  document.querySelectorAll('#meterSeriesGroupAutoCal button[data-autocal-series="dv-profile"]').forEach(btn=>{
   btn.style.display=dvSeriesOk?'':'none';
   btn.hidden=!dvSeriesOk;
   btn.disabled=!dvSeriesOk;
  });
  document.querySelectorAll('#meterSeriesGroupAutoCal button[data-autocal-series="3d-lut"]').forEach(btn=>{
   btn.style.display=dvSeriesOk?'none':'';
   btn.hidden=dvSeriesOk;
   btn.disabled=dvSeriesOk;
  });
  const choiceNow=meterNormalizeAutoCalSeriesChoice(meterAutoCalSeriesChoice);
  if(dvSeriesOk&&choiceNow==='3d-lut') meterSetAutoCalSeriesChoice('greyscale');
  if(!dvSeriesOk&&choiceNow==='dv-profile') meterSetAutoCalSeriesChoice('greyscale');
 }catch(e){}
 {
  const dvProfileBtn=document.getElementById('meterDvProfileMeasureUploadBtn');
  const showDvProfile=autoCalSignalAllowed&&autoCalSeriesAvailable&&autoCalTabActive
   &&meterNormalizeAutoCalSeriesChoice(meterAutoCalSeriesChoice)==='dv-profile'&&dvSeriesOk&&!continuousUiActive;
  if(dvProfileBtn){
   dvProfileBtn.style.display=showDvProfile?'':'none';
   dvProfileBtn.disabled=!showDvProfile||!meterDetected||settingsDirty||busy||!!meterDvProfileStandaloneRunning;
   dvProfileBtn.title=!dvSeriesOk?'DV Config requires Dolby Vision signal mode'
    :settingsDirty?'Apply & Restart first so measurements match the live signal mode'
    :(busy||meterDvProfileStandaloneRunning)?'Meter operation already in progress'
    :'Measure the panel profile (black, white, red, green, blue) and upload the Dolby Vision configuration';
  }
 }
 const showToneMap=autoCalSignalAllowed&&autoCalSeriesAvailable&&autoCalTabActive&&meterAutoCalSeriesChoice==='tone-map'&&toneMapHdrOk&&!continuousUiActive;
 if(toneMapBtn){
  toneMapBtn.style.display=showToneMap?'':'none';
  toneMapBtn.disabled=!showToneMap||!meterDetected||settingsDirty||busy||!!window._meterToneMapBusy;
  toneMapBtn.title=!toneMapHdrOk?'HDR tone map requires HDR10 signal mode':settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy||window._meterToneMapBusy?'Meter operation already in progress':'Measure 100% white peak and upload the HDR tone map';
 }
 try{ meterUpdateToneMapPanelVisibility(); }catch(e){}
 // Re-assert empty 3D LUT hide after tone-map restore (which used to re-open ColorChecker).
 try{ if(typeof meterSync3dLutTabChartVisibility==='function') meterSync3dLutTabChartVisibility(); }catch(e){}
 if(autoCalTarget) autoCalTarget.disabled=busy&&meterAutoCalPhase!=='confirm';
 if(readOnceBtn){
  readOnceBtn.disabled=!hasSelection||!meterDetected||settingsDirty||busy;
  readOnceBtn.title=!meterDetected?noMeterTitle:window._configApplyPending?'Applying settings...':settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'';
 }
 if(continuousBtn){
    continuousBtn.disabled=!hasSelection||!meterDetected||settingsDirty||busy;
    continuousBtn.title=!meterDetected?noMeterTitle:window._configApplyPending?'Applying settings...':settingsDirty?'Apply & Restart first so measurements match the live signal mode':busy?'Meter operation already in progress':'';
 }
 if(stopBtn){
    const showStop=meterSeriesRunning||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning||!!window._meterToneMapBusy||continuousUiActive||meterSeriesAwaitingReady||meterManualPromptAwaiting;
  stopBtn.style.display=showStop?'':'none';
  stopBtn.disabled=!showStop;
 }
 if(readyBtn){
  const readyVisible=meterSeriesAwaitingReady&&meterSelectedMeasurementRequiresReady()&&!meterSeriesSpectroSetupActive;
  readyBtn.style.display=readyVisible?'':'none';
  readyBtn.disabled=!readyVisible||meterReadySignalPending;
  readyBtn.textContent=meterReadySignalPending?'Sending...':'Device Ready';
 }
 if(manualPromptBtn){
    const promptVisible=meterManualPromptAwaiting;
    manualPromptBtn.style.display=promptVisible?'':'none';
    manualPromptBtn.disabled=!promptVisible||meterReadySignalPending;
    manualPromptBtn.textContent=meterReadySignalPending?'Sending...':meterManualPromptActionLabel();
	   }
 meterSyncBusyStatusDot();
 try{ meterSync3dLutWorkspaceUi(); }catch(e){}
}
function meterCalibrationModeTitle(){
 const mode=String((typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr').toLowerCase();
 if(mode==='hdr10') return 'HDR Calibration';
 if(mode==='hlg') return 'HLG Calibration';
 if(mode==='dv') return 'DV Calibration';
 return 'SDR Calibration';
}

function meterUpdateCardMode(){
 const card=document.getElementById('meterCard');
 const title=document.getElementById('meterCardTitleText');
 if(!card||!title) return;
 // The calibration card always shows its full content. Without a meter the
 // read actions are disabled and the banner below the header explains the
 // options (connect a meter or enable the simulated one).
 card.classList.remove('meter-patterns-only');
 title.textContent=meterCalibrationModeTitle();
 meterUpdateNoMeterBanner();
}

// AutoCal writes calibration data into a real TV, so every AutoCal entry
// point refuses to start on the simulated meter (the server enforces the
// same rule on its launch endpoints).
function meterBlockAutoCalForSimulation(){
 if(!meterSimulatedActive) return false;
 toast('AutoCal is not available with the Simulated Meter. Connect a real meter to calibrate a display.',true);
 return true;
}

// "No meter" banner + simulated-meter toggle. meterSimulatedActive mirrors
// the "simulated":true field of /api/meter/status.
let meterSimulatedActive=false;
let meterSimulateTogglePending=false;
function meterUpdateNoMeterBanner(){
 const banner=document.getElementById('meterNoMeterBanner');
 if(!banner) return;
 const text=document.getElementById('meterNoMeterBannerText');
 const btn=document.getElementById('meterSimToggleBtn');
 if(meterDetected&&!meterSimulatedActive){
  banner.style.display='none';
  return;
 }
 banner.style.display='flex';
 if(meterSimulatedActive){
  banner.classList.add('meter-banner-sim-active');
  if(text) text.innerHTML='<strong>Simulated meter active.</strong> Readings are synthetic (an intentionally imperfect virtual display) and are for exploring and testing only.';
  if(btn){ btn.textContent='Disable Simulated Meter'; btn.disabled=meterSimulateTogglePending; }
 } else {
  banner.classList.remove('meter-banner-sim-active');
  if(text) text.innerHTML='<strong>No meter connected.</strong> Connect a USB meter to measure, or use the simulated meter to explore measurements, series reads and charts with synthetic readings.';
  if(btn){ btn.textContent='Use Simulated Meter'; btn.disabled=meterSimulateTogglePending; }
 }
}

async function meterToggleSimulatedMeter(){
 if(meterSimulateTogglePending) return;
 const enable=!meterSimulatedActive;
 meterSimulateTogglePending=true;
 meterUpdateNoMeterBanner();
 try{
  const r=await fetchJSON('/api/meter/simulate',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({enabled:enable}),_timeoutMs:8000});
  if(!r||r.status!=='ok'){
   toast((r&&r.message)?r.message:'Could not change the simulated meter state',true);
   return;
  }
  meterSimulatedActive=!!enable;
  if(!enable) meterDetected=false;
  await meterCheckStatus();
  if(enable){
   // Preselect the virtual instrument so Read Once / series work immediately.
   const sel=document.getElementById('meterMeasurementPort');
   if(sel&&Array.from(sel.options).some(o=>o.value==='99')&&sel.value!=='99'){
    sel.value='99';
    try{ sel.dispatchEvent(new Event('change',{bubbles:true})); }catch(e){}
   }
   toast('Simulated meter enabled. Readings are synthetic.');
  } else {
   toast('Simulated meter disabled');
  }
 }catch(e){
  toast('Could not change the simulated meter state: '+String((e&&e.message)||e||'unknown error'),true);
 }finally{
  meterSimulateTogglePending=false;
  meterUpdateNoMeterBanner();
  meterUpdateReadButtons();
 }
}
function meterResetSeriesButtons(){
 // Only clear data-series measurement buttons (Greyscale 21pt, ColorChecker,
 // Cube 5³, …). AutoCal sub-choice buttons use data-autocal-series; wiping
 // them every poll made Greyscale / 3D LUT / Tone Map look unselected during
 // 3D LUT AutoCal reads (and after prepareChartContext).
 document.querySelectorAll('#meterSeriesBtnRow button[data-series]').forEach(b=>{
  b.classList.remove('btn-primary');
  b.classList.add('btn-secondary');
 });
 // Re-assert the AutoCal sub-choice highlight when that group is active.
 if(meterSeriesTab==='autocal'){
  try{ meterSetAutoCalSeriesChoice(meterAutoCalSeriesChoice); }catch(e){}
 }
}

let meterAutoCalSeriesChoice='greyscale';
function meterNormalizeAutoCalSeriesChoice(choice){
 const c=String(choice||'').toLowerCase();
 if(c==='3d-lut'||c==='3dlut'||c==='lut') return '3d-lut';
 if(c==='tone-map'||c==='tonemap'||c==='tone_map'||c==='hdr-tone-map') return 'tone-map';
 if(c==='dv-profile'||c==='dvprofile'||c==='dv-config'||c==='dvconfig'||c==='dv') return 'dv-profile';
 return 'greyscale';
}

function meterDvProfileSeriesAllowedForSignal(){
 return String((typeof getVal==='function'?getVal('signal_mode'):'')||'').toLowerCase()==='dv';
}

function meterSetAutoCalSeriesChoice(choice){
 let next=meterNormalizeAutoCalSeriesChoice(choice);
 // Tone Map series is HDR10-only — never leave it selected in SDR/etc.
 if(next==='tone-map'&&typeof meterToneMapSeriesAllowedForSignal==='function'&&!meterToneMapSeriesAllowedForSignal()){
  next='greyscale';
 }
 // DV Config series is Dolby-Vision-only, and DV has no 3D LUT stage.
 if(next==='dv-profile'&&!meterDvProfileSeriesAllowedForSignal()) next='greyscale';
 if(next==='3d-lut'&&meterDvProfileSeriesAllowedForSignal()) next='greyscale';
 meterAutoCalSeriesChoice=next;
 // Signal-mode gating here MUST match the DV / 3D LUT swap in
 // meterUpdateReadButtons. This loop used to gate only the tone-map button and
 // force every other one visible, so each call re-showed "3D LUT" in DV mode
 // (and "DV Config" outside DV) until the next meterUpdateReadButtons hid it
 // again -- a visible flap, once per poll for the whole of a DV Config run.
 const dvSeriesMode=meterDvProfileSeriesAllowedForSignal();
 document.querySelectorAll('#meterSeriesGroupAutoCal button[data-autocal-series]').forEach(btn=>{
  const series=btn.dataset.autocalSeries||'';
  let allowed=true;
  if(series==='tone-map') allowed=(typeof meterToneMapSeriesAllowedForSignal==='function')?meterToneMapSeriesAllowedForSignal():false;
  else if(series==='dv-profile') allowed=dvSeriesMode;
  else if(series==='3d-lut') allowed=!dvSeriesMode;
  btn.style.display=allowed?'':'none';
  btn.hidden=!allowed;
  btn.disabled=!allowed;
  const active=allowed&&series===meterAutoCalSeriesChoice;
  btn.classList.toggle('btn-primary',active);
  btn.classList.toggle('btn-secondary',!active);
 });
 try{ meterUpdateToneMapPanelVisibility(); }catch(e){}
}

let meterSeriesTab='greyscale';
const METER_TWO_POINT_DEFAULTS={low:30,high:100};

		const METER_GREY_SLOTS_11=[0,10,20,30,40,50,60,70,80,90,100];
		const METER_GREY_SLOTS_21=[0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];
		const METER_GREY_SLOTS_HDR30=[0,1,1.4,2,2.3,2.7,3,3.7,4,6,8,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];
const METER_LG_GREY_MANUAL_22_ENABLED=false;
		const METER_LG_GREY_DDC_SLOTS_22=[2.5,5,7.5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];
			const METER_LG_GREY_AUTOCAL_26_SLOTS=[2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109];
			// Full-range SDR Autocal-26 body: no super-white 105/109 (peak is 100%).
			const METER_LG_GREY_AUTOCAL_26_SLOTS_FULL=[2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95];
				const METER_LG_GREY_HDR_AUTOCAL_SLOTS=[100,90,80,70,60,50,45,40,35,30,25,20,15,10,7,5,4,2.7,2,1.4];
				// HDR greyscale patch codes are 10-bit in the renderer's
				// 10-bit pipeline. Three tables, picked at runtime by
				// bit-depth + quant range:
				//   8-bit limited  -> legacy 8-bit values (used in SDR
				//                     extended / older code paths)
				//   10-bit limited -> int(64 + IRE%*8.76 + 0.5)
				//   10-bit full    -> int(IRE%/100*1023 + 0.5)
				// On RGB Full 10-bit panels the 8-bit table is wrong: it
				// sends e.g. 27 for 5% IRE (8-bit-limited 16+5*2.19)
				// where the renderer expects 51 (10-bit-full 5% of 1023),
				// over-driving the low anchor.
				const METER_LG_GREY_HDR_AUTOCAL_CODES_8BIT_LIMITED=[235,213,191,169,147,126,115,104,93,82,71,60,49,38,31,27,25,22,20,19];
				// HDR10 8-bit full table (0..255). Used when max_bpc=8 and the
				// panel is RGB Full (the WebUI Bit Depth dropdown drives this).
				// Values are int(IRE%/100*255+0.5) for slots 100, 90, ..., 1.4
				// in the same order as the other HDR20 tables.
				const METER_LG_GREY_HDR_AUTOCAL_CODES_8BIT_FULL=[255,230,204,179,153,128,115,102,89,77,64,51,38,26,18,13,10,7,5,4];
				const METER_LG_GREY_HDR_AUTOCAL_CODES_10BIT_LIMITED=[940,852,764,676,588,504,460,416,372,328,284,240,196,152,124,108,100,88,80,76];
				const METER_LG_GREY_HDR_AUTOCAL_CODES_10BIT_FULL=[1023,921,818,716,614,512,460,409,358,307,256,205,153,102,72,51,41,28,20,14];
				const METER_LG_GREY_HDR_AUTOCAL_DDC_ARRAY_IRES=[100,90,80,70,60,50,45,40,35,30,25,20,15,10,7,5,4,2.7,2,1.4];
							function meterLgHdrAutoCalStimulusFromCode(code){
							 const value=(Number(code)-16)*100/219;
							 if(!Number.isFinite(value)) return 0;
							 return Math.max(0,Math.min(100,value));
							}
				const METER_LG_GREY_AUTOCAL_26_CODES=[84,92,100,108,124,152,196,240,284,328,372,416,460,504,544,588,632,676,720,764,808,852,896,932,984,1023];
				const METER_LG_GREY_EXTENDED_26_CODES=[64,...METER_LG_GREY_AUTOCAL_26_CODES];
			const METER_LG_GREY_EXTENDED_26_SLOTS=[0,...METER_LG_GREY_AUTOCAL_26_SLOTS];
			const METER_LG_GREY_DDC_PATCH_SLOTS_22=[6.7,9.2,11.3,13.8,18.4,23,27.6,32.2,34.3,38.9,43.5,48.1,52.7,57.3,61.9,64,68.6,73.2,77.8,82.4,87,91.6];
			const METER_LG_GREY_SERIES_SLOTS=[0,...METER_LG_GREY_DDC_SLOTS_22];
			const METER_LG_GREY_AUTOCAL_SERIES_SLOTS=[0,...METER_LG_GREY_AUTOCAL_26_SLOTS];
			const METER_LG_GREY_STIMULUS_22={
			 '0':0,'2.5':6.7,'5':9.2,'7.5':11.3,'10':13.8,'15':18.4,'20':23,'25':27.6,'30':32.2,'35':34.3,'40':38.9,'45':43.5,'50':48.1,'55':52.7,'60':57.3,'65':61.9,
		 '70':64,'75':68.6,'80':73.2,'85':77.8,'90':82.4,'95':87,'100':91.6
		};
const METER_LG_GREY_TV_MENU_STEP=1;
let meterGreyPatchProfiles={format:'pgenerator-greyscale-profile-v2',apply_to_all_modes:false,profiles:{}};
let meterGreyEditorPoints=21;

function meterFormatPercentValue(value){
 const numeric=Number(value);
 if(!Number.isFinite(numeric)) return '0';
 const rounded=Math.round(numeric*10)/10;
 return String(rounded).replace(/(\.\d*?)0+$/,'$1').replace(/\.$/,'');
}

function meterIsTwoPointGreyscale(){
 return meterActiveSeriesType==='greyscale' && Number(meterActiveSeriesPoints)===2;
}

function meterTwoPointSignalMode(){
 return String((document.getElementById('signal_mode')||{}).value||'sdr').toLowerCase();
}

function meterTwoPointCodeLimits(){
 // The patch source stays 10-bit when the HDMI container is set to 12-bit;
 // Dolby Vision is the exception and uses its 12-bit legal source domain.
 if(meterTwoPointSignalMode()==='dv'){
  return {bits:12,inputMax:4095,min:256,legalMax:3760,max:3760,headroom:false,label:'Dolby Vision legal'};
 }
 const selectedBits=parseInt((document.getElementById('max_bpc')||{}).value||'8',10);
 const bits=selectedBits>=10?10:8;
 const inputMax=bits===10?1023:255;
 const limited=meterIsLimitedRange();
 const ycbcr=!meterOutputIsRgb();
 if(!limited) return {bits,inputMax,min:0,legalMax:inputMax,max:inputMax,headroom:false,label:'RGB Full'};
 const min=bits===10?64:16;
 const legalMax=bits===10?940:235;
 return {bits,inputMax,min,legalMax,max:ycbcr?inputMax:legalMax,headroom:ycbcr,label:ycbcr?'YCbCr Limited':'RGB Limited'};
}

function meterTwoPointStimulusMax(){
 return meterTwoPointCodeLimits().headroom?109:100;
}

function meterTwoPointCodeFromStimulus(stimulus){
 const limits=meterTwoPointCodeLimits();
 const maxStimulus=limits.headroom?109:100;
 const value=Math.max(0,Math.min(maxStimulus,Number(stimulus)||0));
 if(limits.headroom&&value>100){
  return Math.max(limits.min,Math.min(limits.max,Math.round(limits.legalMax+(value-100)/9*(limits.max-limits.legalMax))));
 }
 return Math.max(limits.min,Math.min(limits.legalMax,Math.round(limits.min+value/100*(limits.legalMax-limits.min))));
}

function meterTwoPointStimulusFromCode(code){
 const limits=meterTwoPointCodeLimits();
 const value=Math.max(limits.min,Math.min(limits.max,Math.round(Number(code)||0)));
 let stimulus;
 if(limits.headroom&&value>limits.legalMax){
  stimulus=100+(value-limits.legalMax)*9/(limits.max-limits.legalMax);
 }else{
  stimulus=(value-limits.min)*100/(limits.legalMax-limits.min);
 }
 return Math.round(Math.max(0,Math.min(limits.headroom?109:100,stimulus))*10000)/10000;
}

function meterFormatTwoPointStimulusValue(value){
 const numeric=Number(value);
 if(!Number.isFinite(numeric)) return '0';
 return String(Math.round(numeric*10000)/10000).replace(/(\.\d*?)0+$/,'$1').replace(/\.$/,'');
}

function meterUpdateTwoPointCodeUi(values){
 const limits=meterTwoPointCodeLimits();
 const maxStimulus=limits.headroom?109:100;
 const lowEl=document.getElementById('meterTwoPointLow');
 const highEl=document.getElementById('meterTwoPointHigh');
 const lowCodeEl=document.getElementById('meterTwoPointLowCode');
 const highCodeEl=document.getElementById('meterTwoPointHighCode');
 if(lowEl) lowEl.max=String(maxStimulus);
 if(highEl) highEl.max=String(maxStimulus);
 [lowCodeEl,highCodeEl].forEach(el=>{
  if(!el) return;
  el.min=String(limits.min);
  el.max=String(limits.max);
 });
 if(lowCodeEl) lowCodeEl.value=String(values.lowCode);
 if(highCodeEl) highCodeEl.value=String(values.highCode);
 const hint=document.getElementById('meterTwoPointCodeHint');
 if(hint){
  hint.textContent=limits.headroom
   ? limits.bits+'-bit '+limits.label+': '+limits.min+'-'+limits.legalMax+' is 0-100%; 100-109% uses headroom through '+limits.max+'. '
   : limits.bits+'-bit '+limits.label+' code range: '+limits.min+'-'+limits.max+'. ';
 }
}

function meterIsToneMapSeries(){
 return meterSeriesTab==='autocal' && meterNormalizeAutoCalSeriesChoice(meterAutoCalSeriesChoice)==='tone-map';
}

function meterSeriesTabForType(type){
 return (type==='colors'||type==='saturations')?'color':'greyscale';
}

function meterSeriesTabForSeries(type,points){
 // Lattice (3D LUT profiling) series live under the 3D LUT tab; manual custom
 // colour series stay under Color, custom greyscale under Greyscale.
 const series=(typeof meterCustomSeriesById==='function')?meterCustomSeriesById(points):null;
 if(series&&(series.kind==='lattice'||series.kind==='hybrid'||series.kind==='skeleton')) return '3dlut';
 return meterSeriesTabForType(type);
}

function meterNormalizeSeriesTab(tab){
 // 'cube' is a legacy stored value from the retired 3D Cube tab.
 if(tab==='autocal') return 'autocal';
 if(tab==='3dlut'||tab==='cube') return '3dlut';
 return (tab==='color')?'color':'greyscale';
}

function meterTwoPointValues(){
 const lowEl=document.getElementById('meterTwoPointLow');
 const highEl=document.getElementById('meterTwoPointHigh');
 let low=parseFloat((lowEl&&lowEl.value)||METER_TWO_POINT_DEFAULTS.low);
 let high=parseFloat((highEl&&highEl.value)||METER_TWO_POINT_DEFAULTS.high);
 if(!Number.isFinite(low)) low=METER_TWO_POINT_DEFAULTS.low;
 if(!Number.isFinite(high)) high=METER_TWO_POINT_DEFAULTS.high;
 const maxStimulus=meterTwoPointStimulusMax();
 low=Math.max(0,Math.min(maxStimulus,Math.round(low*10000)/10000));
 high=Math.max(0,Math.min(maxStimulus,Math.round(high*10000)/10000));
 if(high<=low){
  if(low>=maxStimulus){ high=maxStimulus; low=Math.max(0,maxStimulus-1); }
  else high=Math.min(maxStimulus,low+1);
 }
 return {
  low,
  high,
  lowCode:meterTwoPointCodeFromStimulus(low),
  highCode:meterTwoPointCodeFromStimulus(high),
  inputMax:meterTwoPointCodeLimits().inputMax
 };
}

function meterSetTwoPointInputs(values){
 const lowEl=document.getElementById('meterTwoPointLow');
 const highEl=document.getElementById('meterTwoPointHigh');
 if(lowEl) lowEl.value=meterFormatTwoPointStimulusValue(values.low);
 if(highEl) highEl.value=meterFormatTwoPointStimulusValue(values.high);
 meterUpdateTwoPointCodeUi(values);
}

function meterSyncTwoPointInputs(){
 const values=meterTwoPointValues();
 meterSetTwoPointInputs(values);
 return values;
}

function meterGreyscale21SeriesLabel(){
 return meterUseLgGreyscale21(21)?'Greyscale LG 22pt Manual':'Greyscale 21pt';
}

function meterGreyscale26SeriesLabel(){
 return meterUseLgAutoCal26(26)?'Greyscale LG 26pt AutoCal':'Greyscale 26pt';
}

function meterHdrGreyscaleSeriesAvailable(){
 return false;
}

function meterUseHdrGreyscale30(points){
 if(!meterHdrGreyscaleSeriesAvailable()) return false;
 const normalized=(points===256)?100:Number(points);
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 return normalized===30&&mode==='hdr10';
}

function meterUpdateSeriesLabels(){
 const select=document.getElementById('meterGreyscaleSeriesSelect');
 const grey21=select&&select.querySelector('option[value="21"]');
 if(grey21) grey21.textContent=meterGreyscale21SeriesLabel();
 const grey26=select&&select.querySelector('option[value="26"]');
 if(grey26) grey26.textContent=meterGreyscale26SeriesLabel();
 const grey30=select&&select.querySelector('option[value="30"]');
 const hdrAvailable=meterHdrGreyscaleSeriesAvailable();
 if(grey30){
  grey30.hidden=!hdrAvailable;
  grey30.disabled=!hdrAvailable;
 }
 if(meterActiveSeriesKey==='greyscale-30'&&!meterHdrGreyscaleSeriesAvailable()){
  meterActiveSeriesKey='';
 }
 meterSyncGreyscaleSeriesUi(meterActiveSeriesType==='greyscale'?meterActiveSeriesPoints:null);
 const edit21=document.getElementById('meterGreyEdit21Btn');
 if(edit21) edit21.textContent=meterUseLgGreyscale21(21)?'LG 22pt':'21pt';
}

function meterHandleTwoPointLevelChange(){
 meterSyncTwoPointInputs();
 saveMeterSettings();
 if(meterIsTwoPointGreyscale()) meterRefreshActiveSeriesCharts();
}

function meterHandleTwoPointCodeChange(event){
 const codeEl=event&&event.currentTarget;
 const isHigh=!!(codeEl&&codeEl.id==='meterTwoPointHighCode');
 const stimulusEl=document.getElementById(isHigh?'meterTwoPointHigh':'meterTwoPointLow');
 const limits=meterTwoPointCodeLimits();
 let code=parseInt((codeEl&&codeEl.value)||'',10);
 if(!Number.isFinite(code)){
  const current=meterTwoPointValues();
  code=isHigh?current.highCode:current.lowCode;
 }
 code=Math.max(limits.min,Math.min(limits.max,code));
 if(stimulusEl) stimulusEl.value=meterFormatTwoPointStimulusValue(meterTwoPointStimulusFromCode(code));
 meterSyncTwoPointInputs();
 saveMeterSettings();
 if(meterIsTwoPointGreyscale()) meterRefreshActiveSeriesCharts();
}

function meterUpdateSeriesTabUi(){
 let tab=meterNormalizeSeriesTab(meterSeriesTab);
 const autoCalSignalAllowed=meterAutoCalControlsAllowedForSignal();
 const autoCalSeriesAvailable=meterAutoCalSeriesAvailable();
 if(tab==='autocal'&&!(autoCalSignalAllowed&&autoCalSeriesAvailable)){
  tab=meterSeriesTabForSeries(meterActiveSeriesType,meterActiveSeriesPoints);
  meterSeriesTab=tab;
 }
 // The 3D LUT series tab is measurement-only (profile a lattice/skeleton/hybrid
 // with the meter), so it is hidden with no meter attached. Fall back to a
 // usable tab if it was active when the meter went away.
 if(tab==='3dlut'&&!meterDetected){
  tab=(meterSeriesTabForType(meterActiveSeriesType)==='color')?'color':'greyscale';
  meterSeriesTab=tab;
 }
 const greyGroup=document.getElementById('meterSeriesGroupGreyscale');
 const colorGroup=document.getElementById('meterSeriesGroupColor');
 const lutGroup=document.getElementById('meterSeriesGroup3dLut');
 const autoCalGroup=document.getElementById('meterSeriesGroupAutoCal');
	 const greyBar=document.getElementById('meterGreyProfileBar');
	 const twoPointControls=document.getElementById('meterTwoPointControls');
	 const twoPointActive=meterIsTwoPointGreyscale();
 const autoCal26Active=meterActiveSeriesType==='greyscale'&&Number(meterActiveSeriesPoints)===26&&meterGreyTvControlsActive();
 document.querySelectorAll('#meterSeriesTabRow button[data-series-tab]').forEach(btn=>{
  const tabKey=btn.dataset.seriesTab||'';
  let visible=true;
  if(tabKey==='autocal') visible=autoCalSignalAllowed&&autoCalSeriesAvailable;
  // 3D LUT and Display Profiler stay visible without a meter so operators can
  // see what the tools offer; the no-meter banner explains how to get
  // readings (connect a meter or enable the simulated meter).
  btn.style.display=visible?'':'none';
  btn.hidden=!visible;
  btn.disabled=!visible;
  const active=visible&&tabKey===tab;
  btn.classList.toggle('btn-primary',active);
  btn.classList.toggle('btn-secondary',!active);
 });
 meterUpdateSeriesLabels();
 meterRenderCustomSeriesButtons();
 if(greyGroup) greyGroup.style.display=tab==='greyscale'?'flex':'none';
 if(colorGroup) colorGroup.style.display=tab==='color'?'flex':'none';
 if(lutGroup) lutGroup.style.display=tab==='3dlut'?'flex':'none';
 if(autoCalGroup) autoCalGroup.style.display=(tab==='autocal'&&autoCalSignalAllowed&&autoCalSeriesAvailable)?'flex':'none';
 if(tab==='autocal'&&autoCalSignalAllowed&&autoCalSeriesAvailable) meterSetAutoCalSeriesChoice(meterAutoCalSeriesChoice);
 meterGreySyncUi();
	 if(greyBar) greyBar.style.display=(tab==='greyscale'&&!twoPointActive&&!autoCal26Active&&!meterActiveSeriesIsCustom())?'flex':'none';
 if(twoPointControls) twoPointControls.style.display=(tab==='greyscale'&&twoPointActive)?'flex':'none';
 // Hide leftover greyscale/color charts on the 3D LUT tab until a profiling series is chosen.
 try{ if(tab==='3dlut'&&typeof meterSync3dLutTabChartVisibility==='function') meterSync3dLutTabChartVisibility(); }catch(e){}
 try{ meterSync3dLutWorkspaceUi(); }catch(e){}
}

function meterAutoCalChoiceForSeries(type,points){
 if(type==='greyscale'&&Number(points)===26) return 'greyscale';
 // Volume cube series ids (900-999) belong to 3D LUT AutoCal — never ColorChecker (30).
 if(type==='colors'&&Number(points)>=900&&Number(points)<1000) return '3d-lut';
 const key=String(meterActiveSeriesKey||'');
 if(key.indexOf('lg-3d-')===0) return '3d-lut';
 return '';
}

function meterPreserveAutoCalTabForSeries(type,points){
 const choice=meterAutoCalChoiceForSeries(type,points);
 if(meterSeriesTab!=='autocal'||!choice) return false;
 meterUpdateSeriesTabUi();
 meterSetAutoCalSeriesChoice(choice);
 return true;
}

function meterShowSeriesTabForSeries(type,points){
 if(meterPreserveAutoCalTabForSeries(type,points)) return;
 meterSetSeriesTab(meterSeriesTabForSeries(type,points),true);
}

function meterShowGreyscaleAutoCalContext(){
 if(meterPreserveAutoCalTabForSeries('greyscale',26)) return;
 meterSetSeriesTab('greyscale',true);
}

// True while charts are owned by a 3D LUT AutoCal profile (volume or matrix).
// Post-check uses lg-3d-post-check and is verification — keep Delta-E there.
function meterIs3dLutProfileChartContext(){
 const key=String(meterActiveSeriesKey||'');
 if(key.indexOf('lg-3d-lattice-profile-')===0) return true;
 if(key==='lg-3d-matrix-profile') return true;
 // The DV Config pass is the Dolby Vision equivalent of the matrix profile
 // (five native primary/white/black reads) and wants the same CIE-only view.
 if(key==='lg-dv-profile') return true;
 if(typeof meterActiveVolumeProfileSeries==='function'&&meterActiveVolumeProfileSeries()) return true;
 return false;
}

// Install a clean 3D LUT chart context: no ColorChecker readings, no Delta-E
// bars, hybrid/lattice/skeleton thumbs (or empty matrix shell). Call when the
// operator opens the 3D LUT AutoCal sub-tab or starts a run.
function meterLg3dPrepareChartContext(opts){
 const o=opts||{};
 const method=String(o.method||'').toLowerCase();
 let series=o.series||null;
 if(!series&&meterLg3dIsVolumeMethod(method)){
  if(method==='skeleton') series=meterCustomSeriesById(920);
  else if(method==='hybrid') series=meterCustomSeriesById(923);
  else series=meterLg3dSelectedLatticeSeries();
 }
 if(!series&&!method){
  // Tab open / default preview: last modal source or Hybrid 3³.
  const src=(typeof meterLg3dProfileSourceValue==='function')?meterLg3dProfileSourceValue():'hybrid3';
  const resolved=(typeof meterLg3dResolveProfilingChoice==='function')?meterLg3dResolveProfilingChoice(src,null):null;
  series=(resolved&&resolved.series)||meterCustomSeriesById(923);
 }
 meterSeriesTab='autocal';
 try{ meterSetAutoCalSeriesChoice('3d-lut'); }catch(e){}
 try{ meterUpdateSeriesTabUi(); }catch(e){}
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 meterClearMultiPatchSelection();
 meterSharedSeriesId=null;
 if(o.clearReadings!==false){
  meterReadings=[];
  meterWhiteReading=null;
 }
 meterActiveSeriesType='colors';
 let steps=[];
 if(series&&series.id!=null){
  meterActiveSeriesPoints=series.id;
  meterActiveSeriesKey='lg-3d-lattice-profile-'+series.id;
  meterLg3dActiveLatticeSeriesId=series.id;
  try{ steps=meterBuildCustomSeriesSteps(series)||[]; }catch(e){ steps=[]; }
  steps=steps.filter(s=>/^[0-9.]+\/[0-9.]+\/[0-9.]+$/.test(String((s&&s.name)||'')));
 } else {
  meterActiveSeriesPoints=5;
  meterActiveSeriesKey='lg-3d-matrix-profile';
  steps=[];
 }
 meterSeriesSteps=steps;
 try{ meterSetActiveSeriesChartContext(); }catch(e){}
 try{ meterResetSeriesButtons(); }catch(e){}
 // resetSeriesButtons re-applies choice on autocal tab; force 3D LUT so a
 // previous greyscale AutoCal choice cannot stick after prepare.
 try{ meterSetAutoCalSeriesChoice('3d-lut'); }catch(e){}
 try{ if(typeof meterUpdateColorChartMode==='function') meterUpdateColorChartMode(true); }catch(e){}
 try{
  document.getElementById('chartsGreyscaleWrap').style.display='none';
  document.getElementById('chartsColorWrap').style.display='';
  if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true); else document.getElementById('meterCharts').style.display='';
 }catch(e){}
 // Force-hide ColorChecker-style Delta-E + averages for every 3D LUT profile.
 try{
  const deSec=document.getElementById('meterColorDeltaESection');
  if(deSec) deSec.style.display='none';
  const avgWrap=document.getElementById('colorSeriesAveragesWrap');
  if(avgWrap) avgWrap.style.display='none';
  const tableWrap=document.getElementById('colorReadingsTableWrap');
  if(tableWrap) tableWrap.style.display='none';
 }catch(e){}
 if(steps.length){
  try{ meterBuildPatchThumbs(steps,new Set(),null); }catch(e){}
  try{ meterSetThumbsVisible(true); }catch(e){}
  try{ drawAllChartsPreset(steps); }catch(e){}
 } else {
  try{ meterSetThumbsVisible(false); }catch(e){}
  try{ drawAllChartsPreset([]); }catch(e){}
 }
 try{ showColorReadingDetail(null,{pin:false}); }catch(e){}
 try{ meterClearLiveReading(); }catch(e){}
 try{ meterResetLiveReadingDisplay(); }catch(e){}
 try{ meterUpdateDeltaEFormControl(); }catch(e){}
 // Profiling CIE defaults: Targets off (no meaningful verification targets).
 try{
  if(typeof meterLatticeDefault3dView==='function'){
   meterLatticeDefault3dView((series&&series.id!=null)?series.id:(meterActiveSeriesKey==='lg-3d-matrix-profile'?'matrix':null));
  }
 }catch(e){}
 return true;
}

function meterShow3dLutAutoCalContext(){
 // Keep AutoCal tab on 3D LUT — never fall through to ColorChecker (colors-30).
 meterSeriesTab='autocal';
 try{ meterSetAutoCalSeriesChoice('3d-lut'); }catch(e){}
 try{ meterUpdateSeriesTabUi(); }catch(e){}
 // Always re-assert 3D LUT after tab UI refresh (series button resets above
 // must not leave Greyscale/3D LUT/Tone Map all secondary).
 try{ meterSetAutoCalSeriesChoice('3d-lut'); }catch(e){}
 if(String(meterActiveSeriesKey||'').indexOf('lg-3d-')===0) return;
 // First entry with no profile context yet: install a clean volume shell.
 try{ meterLg3dPrepareChartContext({clearReadings:true}); }catch(e){}
 try{ meterSetAutoCalSeriesChoice('3d-lut'); }catch(e){}
}

function meterDefaultSeriesButtonForTab(tab){
 if(tab==='greyscale') return {dataset:{series:'greyscale-21'},hidden:false,disabled:false,style:{display:''}};
 const group=document.getElementById(tab==='color'?'meterSeriesGroupColor':(tab==='3dlut'?'meterSeriesGroup3dLut':'meterSeriesGroupGreyscale'));
 if(!group) return null;
 return Array.from(group.querySelectorAll('button[data-series]')).find(btn=>!btn.hidden&&btn.style.display!=='none'&&!btn.disabled)||null;
}

// 3D LUT measurement tab: only show charts/thumbs after a matrix/volume series
// is selected. Otherwise leftover greyscale/ColorChecker charts from the
// previous tab stay on screen.
function meterActiveMatrixProfileSeries(){
 return String(meterActiveSeriesKey||'')==='lg-3d-matrix-profile';
}
// True when the ACTIVE series is matrix (5-point) or volume (lattice/hybrid/skeleton).
function meter3dLutTabHasSelectedSeries(){
 try{
  if(meterActiveMatrixProfileSeries()) return true;
  if(typeof meterActiveVolumeProfileSeries==='function'){
   const s=meterActiveVolumeProfileSeries();
   if(s&&(s.kind==='lattice'||s.kind==='hybrid'||s.kind==='skeleton')) return true;
  }
 }catch(e){}
 return false;
}
// Five WRGBK patches for offline matrix profile / Build 3D LUT.
function meterMatrixProfileSteps(){
 const wire=(typeof meterLatticeWireRange==='function')?meterLatticeWireRange():{min:0,span:255,max:255};
 const inputMax=(wire.max!=null)?wire.max:((wire.min||0)+(wire.span||255));
 const pct=function(f){ const n=Math.round(Number(f)*1000)/10; return (Math.abs(n-Math.round(n))<0.05)?String(Math.round(n)):String(n); };
 const code=function(f){ return Math.round((wire.min||0)+Math.max(0,Math.min(1,Number(f)||0))*(wire.span||255)); };
 const prev=function(c){
  const max=inputMax>0?inputMax:255;
  return max>255?Math.max(0,Math.min(255,Math.round(Number(c)*255/max))):Math.max(0,Math.min(255,Math.round(Number(c)||0)));
 };
 const make=function(fr,fg,fb){
  const r=code(fr),g=code(fg),b=code(fb);
  return {
   name:pct(fr)+'/'+pct(fg)+'/'+pct(fb),
   ire:pct(Math.max(fr,fg,fb)),
   stimulus:Number(pct(Math.max(fr,fg,fb))),
   signal_r_pct:Number(pct(fr)),signal_g_pct:Number(pct(fg)),signal_b_pct:Number(pct(fb)),
   r:r,g:g,b:b,
   preview_r:prev(r),preview_g:prev(g),preview_b:prev(b),
   input_max:inputMax,
   series_type:'colors',
   custom_series_id:'matrix'
  };
 };
 // W, R, G, B, K — corners the offline matrix solve requires.
 return [make(1,1,1),make(1,0,0),make(0,1,0),make(0,0,1),make(0,0,0)];
}
// Load matrix as a measurable series on the 3D LUT *series* tab (not Autocal).
function meterInstallMatrixProfileSeries(opts){
 const o=opts||{};
 meterSeriesTab='3dlut';
 try{ if(typeof meterUpdateSeriesTabUi==='function') meterUpdateSeriesTabUi(); }catch(e){}
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 meterSharedSeriesId=null;
 if(o.clearReadings!==false){
  meterReadings=[];
  meterWhiteReading=null;
 }
 meterActiveSeriesType='colors';
 meterActiveSeriesPoints='matrix';
 meterActiveSeriesKey='lg-3d-matrix-profile';
 meterLg3dActiveLatticeSeriesId=0;
 try{ meterActiveSeriesSignalMode=String((typeof meterChartSignalMode==='function'?meterChartSignalMode():'sdr')||'sdr').toLowerCase(); }catch(e){ meterActiveSeriesSignalMode='sdr'; }
 const steps=meterMatrixProfileSteps();
 meterSeriesSteps=steps;
 try{ meterSetActiveSeriesChartContext(); }catch(e){}
 try{ meterResetSeriesButtons(); }catch(e){}
 try{ if(typeof meterUpdateColorChartMode==='function') meterUpdateColorChartMode(true); }catch(e){}
 try{
  document.getElementById('chartsGreyscaleWrap').style.display='none';
  document.getElementById('chartsColorWrap').style.display='';
  if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true);
  else document.getElementById('meterCharts').style.display='';
 }catch(e){}
 try{
  const deSec=document.getElementById('meterColorDeltaESection');
  if(deSec) deSec.style.display='none';
  const avgWrap=document.getElementById('colorSeriesAveragesWrap');
  if(avgWrap) avgWrap.style.display='none';
  const tableWrap=document.getElementById('colorReadingsTableWrap');
  if(tableWrap) tableWrap.style.display='none';
 }catch(e){}
 try{ meterBuildPatchThumbs(steps,new Set(),null); }catch(e){}
 try{ meterSetThumbsVisible(true); }catch(e){}
 try{ drawAllChartsPreset(steps); }catch(e){}
 try{ showColorReadingDetail(null,{pin:false}); }catch(e){}
 try{ meterClearLiveReading(); }catch(e){}
 try{ meterResetLiveReadingDisplay(); }catch(e){}
 try{ meterUpdateDeltaEFormControl(); }catch(e){}
 try{ meterUpdateReadButtons(); }catch(e){}
 try{ if(typeof meterLatticeDefault3dView==='function') meterLatticeDefault3dView('matrix'); }catch(e){}
 return true;
}
// When false on the 3D LUT tab, drawAllCharts* must not re-open the chart shell.
let meter3dLutChartsAllowed=true;
// Live gate (does not rely on the cached flag alone): empty 3D LUT always wins.
function meterShouldSuppressMeterCharts(){
 try{
  if(meterNormalizeSeriesTab(meterSeriesTab)!=='3dlut') return false;
  return !meter3dLutTabHasSelectedSeries();
 }catch(e){ return false; }
}
// Sole show/hide path for #meterCharts so tone-map restore / status polls cannot
// re-open ColorChecker leftovers on an empty 3D LUT tab.
function meterSetMeterChartsVisible(wantShow){
 const charts=document.getElementById('meterCharts');
 if(!charts) return false;
 if(wantShow&&meterShouldSuppressMeterCharts()){
  meter3dLutChartsAllowed=false;
  charts.style.display='none';
  charts.setAttribute('data-3dlut-empty','1');
  return false;
 }
 if(wantShow){
  charts.style.display='';
  charts.removeAttribute('data-3dlut-empty');
  return true;
 }
 charts.style.display='none';
 return false;
}
function meterSync3dLutTabChartVisibility(){
 const on3d=meterNormalizeSeriesTab(meterSeriesTab)==='3dlut';
 if(!on3d){
  meter3dLutChartsAllowed=true;
  const charts=document.getElementById('meterCharts');
  if(charts) charts.removeAttribute('data-3dlut-empty');
  return;
 }
 const has=meter3dLutTabHasSelectedSeries();
 meter3dLutChartsAllowed=!!has;
 const charts=document.getElementById('meterCharts');
 const exportRow=document.getElementById('meterExportRow');
 const grey=document.getElementById('chartsGreyscaleWrap');
 const color=document.getElementById('chartsColorWrap');
 const thumbs=document.getElementById('meterPatchThumbs');
 const thumbsWrap=document.getElementById('meterPatchThumbsWrap')||(thumbs&&thumbs.parentElement);
 const clearBtn=document.getElementById('meterClearChartBtn');
 if(!has){
  meterSetMeterChartsVisible(false);
  if(charts) charts.setAttribute('data-3dlut-empty','1');
  if(exportRow) exportRow.style.display='none';
  if(grey) grey.style.display='none';
  if(color) color.style.display='none';
  if(thumbs) thumbs.style.display='none';
  if(thumbsWrap&&thumbsWrap!==charts) try{ thumbsWrap.style.display='none'; }catch(e){}
  if(clearBtn) clearBtn.style.display='none';
  try{ if(typeof meterSetThumbsVisible==='function') meterSetThumbsVisible(false); }catch(e){}
  try{ if(typeof showColorReadingDetail==='function') showColorReadingDetail(null,{pin:false}); }catch(e){}
  try{ if(typeof meterResetLiveReadingDisplay==='function') meterResetLiveReadingDisplay(); }catch(e){}
  const liveEl=document.getElementById('meterLiveReading');
  if(liveEl) liveEl.style.display='none';
  // Hide progress/export leftovers from greyscale/color runs.
  const progress=document.getElementById('meterProgress');
  if(progress&&!meterSeriesRunning) progress.style.display='none';
 } else {
  meterSetMeterChartsVisible(true);
  if(grey) grey.style.display='none';
  if(color) color.style.display='';
 }
}
// drawAllCharts / preset must not fight the empty 3D LUT tab.
// LIVE check only: do NOT OR in the cached meter3dLutChartsAllowed flag.
// That flag stays false from the empty-tab hide until after sync; OR-ing it
// blocked the first Hybrid/lattice draw after Select series, so the old
// ColorChecker canvas was un-hidden without a redraw (second load "fixed" it).
function meter3dLutChartsBlocked(){
 return meterShouldSuppressMeterCharts();
}

function meterSetSeriesTab(tab,skipAutoSelect){
 const previousTab=meterNormalizeSeriesTab(meterSeriesTab);
 meterSeriesTab=meterNormalizeSeriesTab(tab);
 meterUpdateSeriesTabUi();
 // 3D LUT tab never auto-loads a leftover greyscale/color series into the charts.
 if(meterSeriesTab==='3dlut'){
  meterSync3dLutTabChartVisibility();
  try{ meterUpdateReadButtons(); }catch(e){}
  // Beat any post-tab async redraw (status poll / refresh charts).
  try{
   requestAnimationFrame(function(){
    try{ meterSync3dLutTabChartVisibility(); }catch(e2){}
    try{ meterUpdateReadButtons(); }catch(e2){}
   });
  }catch(e){}
  if(skipAutoSelect) return;
  return;
 }
 if(skipAutoSelect) return;
 if(meterSeriesTab==='autocal'){
  meterSelectAutoCalGreyscale();
  return;
 }
 // An imported CHC session owns a linked grayscale/ColorChecker/Sat Sweep
 // workspace. Entering Color must open that session's ColorChecker snapshot
 // through the same handler as an explicit ColorChecker click. Falling through
 // to the generic data-series parser selects native colors-29/30 instead,
 // which makes the tab appear selected with blank charts until the operator
 // visits Sat Sweep and explicitly clicks ColorChecker again.
 if(meterSeriesTab==='color'&&meterActiveHcfrSessionId){
  const importedSession=meterActiveHcfrSessionId;
  const selectImportedDefault=()=>{
   if(meterSeriesTab==='color'&&meterActiveHcfrSessionId===importedSession) meterSelectImportedHcfrGroup('colorChecker');
  };
  if(typeof window.requestAnimationFrame==='function') window.requestAnimationFrame(()=>setTimeout(selectImportedDefault,0));
  else setTimeout(selectImportedDefault,0);
  return;
 }
 if(previousTab===meterSeriesTab&&meterActiveSeriesType
  &&meterSeriesTabForType(meterActiveSeriesType)===meterSeriesTab
  &&!meterActiveSeriesIsIccWorkflow()) return;
 if(meterSeriesTab==='color'){
  meterSelectBuiltinColorChecker();
  return;
 }
 // preserveTab: this IS meterSetSeriesTab, and the tab UI is already in sync.
 const remembered=meterLastSeriesByTab[meterSeriesTab];
 if(remembered){
  meterSelectSeries(remembered.type,remembered.points,{preserveTab:true});
 } else {
  const defaultBtn=meterDefaultSeriesButtonForTab(meterSeriesTab);
  const match=defaultBtn?String(defaultBtn.dataset.series||'').match(/^([^-]+)-(\d+)$/):null;
  if(match) meterSelectSeries(match[1],parseInt(match[2],10));
 }
 // Leaving Tone Map / 3D LUT empty shell: restore charts if another series is live.
 try{
  if(meterSeriesTab!=='3dlut'&&meterActiveSeriesType&&meterDetected){
   if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true);
   else{
    const charts=document.getElementById('meterCharts');
    if(charts) charts.style.display='';
   }
   const grey=document.getElementById('chartsGreyscaleWrap');
   const color=document.getElementById('chartsColorWrap');
   if(meterActiveSeriesType==='greyscale'){
    if(grey) grey.style.display='';
    if(color) color.style.display='none';
   } else if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations'){
    if(grey) grey.style.display='none';
    if(color) color.style.display='';
   }
  }
 }catch(e){}
}

function meterSelectAutoCalGreyscale(){
 meterSeriesTab='autocal';
 meterSetAutoCalSeriesChoice('greyscale');
 meterUpdateSeriesTabUi();
 meterSelectSeries('greyscale',26,{preserveTab:true});
}

function meterSelectAutoCal3dLut(){
 meterSeriesTab='autocal';
 meterSetAutoCalSeriesChoice('3d-lut');
 meterUpdateSeriesTabUi();
 // 3D LUT charts are independent of ColorChecker — install the default
 // hybrid/volume shell (or last modal source) with empty readings.
 try{ meterLg3dPrepareChartContext({clearReadings:true}); }catch(e){}
}

// The DV Config pass reads five patches -- black/white/red/green/blue at peak
// code -- which is the SAME W/R/G/B/K primary shape as the 3D LUT matrix
// profile, so it reuses that target/step machinery and gets the same CIE-only
// presentation (meterIs3dLutProfileChartContext covers both keys, so the
// Delta-E bars stay hidden). The greyscale charts this used to show were simply
// the wrong charts: there is no greyscale ladder anywhere in this pass.
function meterDvProfileChartSteps(){
 const bitDepth=(typeof meterPatchBitDepth==='function')?meterPatchBitDepth():8;
 const min=256;
 const max=3760;
 return [
  {kind:'black',name:'black',r:min,g:min,b:min},
  {kind:'white',name:'white',r:max,g:max,b:max},
  {kind:'red',name:'red',r:max,g:min,b:min},
  {kind:'green',name:'green',r:min,g:max,b:min},
  {kind:'blue',name:'blue',r:min,g:min,b:max}
 ].map(p=>Object.assign({ire:(p.kind==='black')?0:100,input_max:4095},p,
   meterLg3dMatrixProfileTarget({kind:p.kind,level:100})));
}

// Worker status.steps -> chart readings. The worker reports {name,kind,x,y,
// luminance} per measured patch, so the plots appear one at a time as it works.
function meterDvProfileChartReadings(status){
 const list=(status&&Array.isArray(status.steps))?status.steps:[];
 return list.filter(st=>st&&(st.x!=null||st.luminance!=null)).map(st=>{
  const kind=String(st.kind||'').toLowerCase();
  return Object.assign({
   name:st.name||kind||'patch',
   kind:kind,
   x:st.x,
   y:st.y,
   luminance:st.luminance,
   ire:(kind==='black')?0:100,
   signal_mode:'dv'
  },meterLg3dMatrixProfileTarget({kind:kind,level:100}));
 });
}

function meterDvProfileApplyChartStatus(status){
 const readings=meterDvProfileChartReadings(status);
 // Live poll updates only need the readings and a redraw; re-running the whole
 // button/choice install every 1.5s is pure churn.
 const alreadyInstalled=(String(meterActiveSeriesKey||'')==='lg-dv-profile');
 meterActiveSeriesType='colors';
 meterActiveSeriesPoints=5;
 meterActiveSeriesKey='lg-dv-profile';
 try{ meterSetActiveSeriesChartContext(status||{signal_mode:'dv'}); }catch(e){}
 meterSeriesSteps=meterDvProfileChartSteps();
 meterReadings=readings;
 const whiteRd=readings.find(rd=>String(rd.kind||'')==='white'&&meterReadingHasLuminance(rd));
 if(whiteRd) meterWhiteReading=whiteRd;
 if(!alreadyInstalled){
  try{ meterResetSeriesButtons(); }catch(e){}
  // resetSeriesButtons re-applies the stored choice on the autocal tab; force
  // DV Config back so a previous greyscale/3D LUT choice cannot stick.
  try{ meterSetAutoCalSeriesChoice('dv-profile'); }catch(e){}
 }
 try{ if(typeof meterUpdateColorChartMode==='function') meterUpdateColorChartMode(true); }catch(e){}
 try{
  const gw=document.getElementById('chartsGreyscaleWrap'); if(gw) gw.style.display='none';
  const cw=document.getElementById('chartsColorWrap'); if(cw) cw.style.display='';
  if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true);
  else{ const mc=document.getElementById('meterCharts'); if(mc) mc.style.display=''; }
 }catch(e){}
 try{ if(typeof meterSetThumbsVisible==='function') meterSetThumbsVisible(true); }catch(e){}
 try{
  const completed=new Set(readings.map(rd=>meterStepNameKey(rd)));
  meterBuildPatchThumbs(meterSeriesSteps,completed,readings.length?meterStepNameKey(readings[readings.length-1]):null);
 }catch(e){}
 try{ drawAllCharts(readings); }catch(e){}
}

// AutoCal -> DV Config. Dolby Vision's colour stage is a panel-profile
// measurement (black/white/R/G/B) followed by a DOLBY_CFG_DATA upload, not a
// 3D LUT -- this is the same stage Full Auto Cal runs after greyscale, exposed
// on its own so greyscale and the DV config can be run as separate passes.
function meterSelectAutoCalDvProfile(){
 if(!meterDvProfileSeriesAllowedForSignal()){
  try{ toast('DV Config series requires Dolby Vision signal mode',true); }catch(e){}
  meterSelectAutoCalGreyscale();
  return;
 }
 meterSeriesTab='autocal';
 meterSetAutoCalSeriesChoice('dv-profile');
 meterUpdateSeriesTabUi();
 // Empty CIE shell for the five profile patches. Nothing is parked on the
 // panel here -- the worker drives its own patches, and leaving full-field
 // white up while the operator reads the screen would both stress an OLED and
 // skew the peak read.
 meterDvProfileApplyChartStatus(null);
 try{
  fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'}),_quiet:true,_timeoutMs:5000}).catch(()=>{});
 }catch(e){}
 meterUpdateReadButtons();
}

// Standalone entry for the DV panel profile. Reuses the shared measure/poll/
// upload chain (meterDvAutoCalPollProfile / meterDvAutoCalUploadProfile); the
// only differences are that no Full Auto Cal wizard is running, so failure
// must not tear down a wizard that does not exist, and completion reports
// directly instead of opening the post-cal report overlay.
async function meterStartDvProfileStandalone(){
 if(meterBlockAutoCalForSimulation()) return;
 if(meterActionPending||meterAutoCalRunning||meterLg3dAutoCalRunning||meterFullAutoCalRunning||meterDvProfileStandaloneRunning||meterDvAutoCalProfileRunning){
  toast('Meter operation already in progress',true); return;
 }
 if(!meterDvProfileSeriesAllowedForSignal()){ toast('DV Config requires Dolby Vision signal mode',true); return; }
 if(!(await meterEnsureDetected())){ toast('No meter detected',true); return; }
 if(typeof meterFullAutoCalAvailable==='function'&&!meterFullAutoCalAvailable()){
  toast('Connect an LG TV before running the DV Config pass',true); return;
 }
 if(!(await meterEnsureLgAutoCalTransport('DV Config'))) return;
 if(!meterEnsureAppliedGeneratorSettings()) return;
 // The profile is measured with the panel's DV engine in Relative (the same
 // state Full Auto Cal holds it in for this stage). meterDvProfileFinishStandalone
 // restores Absolute when the pass ends, however it ends.
 applySettingsModalShow();
 const mapOk=await meterDvAutoCalSetMapMode('2');
 if(mapOk) applySettingsModalSuccess('Dolby Vision map mode updated.');
 else{ applySettingsModalError('Failed to switch the Dolby Vision map mode.'); setTimeout(()=>applySettingsModalHide(),3000); return; }
 meterDvAutoCalForceTargetGamma('2.2');
 // A minimal config so the shared chain has the same fields it reads out of a
 // Full Auto Cal run (dtype / ccss / range / signalMode).
 meterFullAutoCalConfig={
  signalMode:'dv',
  dtype:getEffectiveDisplayType(),
  ccss_override:(typeof getCcssOverride==='function')?getCcssOverride():'',
  patternSignalRange:String(getVal('rgb_quant_range')||'2')
 };
 meterDvProfileStandaloneRunning=true;
 meterActionPending=false;
 // Clean CIE shell for this run: the five patches plot as the worker reads
 // them (meterDvAutoCalPollProfile feeds status.steps back in).
 meterDvProfileApplyChartStatus(null);
 meterSetWorkflowProgress({status:'running',current_step:0,total_steps:5,current_name:'Starting Dolby Vision profile measurement'},{workflow:'dv-profile',label:'Starting Dolby Vision profile measurement'});
 meterUpdateReadButtons();
 const bitDepth=(typeof meterPatchBitDepth==='function')?meterPatchBitDepth():8;
 const range=meterFullAutoCalConfig.patternSignalRange;
 const payload={
  input_max:4095,
  display_type:meterFullAutoCalConfig.dtype,
  ccss_override:meterFullAutoCalConfig.ccss_override,
  delay_ms:meterDelayMs(),
  pattern_signal_range:range,
  signal_range:range,
  transport_signal_range:range,
  picture_mode:meterLgPictureModeValue(),
  // Measure the profile with the SAME patch geometry the greyscale pass used
  // (10% window + pattern insertion on OLED). Without these the worker read
  // white full-field, ABL pulled it down, and that low value became the
  // uploaded DV config's Tmax -- hardware: 531.47 here vs 729-730 from the
  // greyscale on the same panel.
  patch_size:(typeof getMeterPatchSize==='function')?getMeterPatchSize():undefined,
  refresh_rate:(typeof getMeterRefreshRate==='function')?(getMeterRefreshRate()||undefined):undefined,
  ...((typeof meterPatternInsertionPayload==='function')?meterPatternInsertionPayload():{}),
  upload:false,
  keep_calibration_mode:true,
  calibration_mode_active:!!(window.lgStatusState&&window.lgStatusState.calibrationMode)
 };
 let started=null;
 try{
  started=await fetchJSON('/api/lg/dv-profile/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),_timeoutMs:15000});
 }catch(e){ started=null; }
 if(!started||started.status!=='started'){
  // Anything other than a confirmed 'started' is a failure here -- including
  // the hand-off guard's {status:'retry'} (greyscale AutoCal still finishing
  // cleanup), which previously slipped past an ==='error' check and left this
  // path polling a worker that was never launched.
  meterDvProfileFail((started&&started.message)||'Could not start the Dolby Vision profile measurement');
  return;
 }
 meterDvAutoCalProfileRunning=true;
 meterDvAutoCalProfilePollErrors=0;
 if(meterDvAutoCalProfilePolling){clearInterval(meterDvAutoCalProfilePolling);meterDvAutoCalProfilePolling=null;}
 meterDvAutoCalProfilePolling=setInterval(meterDvAutoCalPollProfile,1500);
 await meterDvAutoCalPollProfile({initial:true});
}

// Route a DV-profile failure to whichever flow owns the run.
function meterDvProfileFail(message){
 if(meterDvProfileStandaloneRunning){
  meterDvProfileFinishStandalone(false,message||'Dolby Vision profile pass failed');
  return;
 }
 meterFullAutoCalAbort(message||'Dolby Vision profile stage failed',true);
}

// End a standalone DV Config pass. Always restores the DV engine to Absolute
// (the normal viewing curve) and the PQ report curve, mirroring what
// meterFullAutoCalComplete does at the end of a full run.
// Completion notice for a standalone DV Config pass. Persists until the
// operator dismisses it -- a timed auto-hide would let a failure message vanish
// unread, which is exactly the problem the corner toast had.
function meterDvProfileDoneModalShow(ok,message){
 // STANDALONE ONLY. A Full Auto Cal run ends on its own completion modal
 // (meterFullAutoCalComplete -> meterAutoCalSetOverlay, phase 'complete'),
 // which already reports the DV profile upload in its message. Popping this
 // one as well would mean two completion modals for one run, and mid-run for
 // the DV stage rather than at the end. The call sites are already gated on
 // meterDvProfileStandaloneRunning; this is the belt-and-braces guard so a
 // stale flag can never surface it inside a wizard run.
 if((typeof meterFullAutoCalRunning!=='undefined'&&meterFullAutoCalRunning)
  ||(typeof meterFullAutoCalReportPhaseActive==='function'&&meterFullAutoCalReportPhaseActive())){
  return;
 }
 const overlay=document.getElementById('dvProfileDoneOverlay');
 if(!overlay){
  // No modal in the DOM (older cached page): fall back to the toast so the
  // operator is still told the outcome.
  try{ toast(message||(ok?'Dolby Vision configuration uploaded':'Dolby Vision profile pass failed'),!ok); }catch(e){}
  return;
 }
 // Only one full-screen mask at a time.
 try{ if(typeof applySettingsModalHide==='function') applySettingsModalHide(); }catch(e){}
 try{ if(typeof lgConnectModalHide==='function') lgConnectModalHide(); }catch(e){}
 const title=document.getElementById('dvProfileDoneTitle');
 const status=document.getElementById('dvProfileDoneStatus');
 if(title) title.textContent=ok?'Dolby Vision configuration uploaded':'DV Config pass failed';
 if(status) status.textContent=message||(ok
  ?'The panel profile was measured and DOLBY_CFG_DATA was written to the TV.'
  :'The Dolby Vision profile pass did not complete.');
 document.body.classList.add('dv-profile-done-active');
 document.body.classList.toggle('dv-profile-done-error',!ok);
 overlay.setAttribute('aria-hidden','false');
}

function meterDvProfileDoneModalHide(){
 const overlay=document.getElementById('dvProfileDoneOverlay');
 if(overlay) overlay.setAttribute('aria-hidden','true');
 document.body.classList.remove('dv-profile-done-active','dv-profile-done-error');
}

async function meterDvProfileFinishStandalone(ok,message){
 if(meterDvAutoCalProfilePolling){clearInterval(meterDvAutoCalProfilePolling);meterDvAutoCalProfilePolling=null;}
 meterDvAutoCalProfileRunning=false;
 meterDvProfileStandaloneRunning=false;
 meterHideWorkflowProgress();
 try{ await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'}),_quiet:true,_timeoutMs:5000}); }catch(e){}
 try{ meterDvAutoCalSetMapMode('1').catch(function(){}); }catch(e){}
 try{ meterDvAutoCalForceTargetGamma('st2084'); }catch(e){}
 meterActionPending=false;
 meterUpdateReadButtons();
 meterDvProfileDoneModalShow(ok,message);
}

function meterSelectAutoCalToneMap(){
 if(typeof meterToneMapSeriesAllowedForSignal==='function'&&!meterToneMapSeriesAllowedForSignal()){
  try{ toast('Tone Map series requires HDR10 signal mode',true); }catch(e){}
  meterSelectAutoCalGreyscale();
  return;
 }
 meterSeriesTab='autocal';
 meterSetAutoCalSeriesChoice('tone-map');
 meterUpdateSeriesTabUi();
 // Minimal series context: single 100% white step for the measure path.
 // Do NOT park full-field white on the panel here — that over-heats OLEDs
 // before Measure & Upload and inflates peak nits. White only flashes during measure.
 meterActiveSeriesType='greyscale';
 meterActiveSeriesPoints=1;
 try{
  const hdr100=(typeof meterLgHdrHundredPercentCodeForRange==='function')?meterLgHdrHundredPercentCodeForRange():1023;
  const isHdr=(typeof meterChartIsHdr==='function'&&meterChartIsHdr())||String((typeof getVal==='function'?getVal('signal_mode'):'')||'').toLowerCase()==='hdr10';
  const white=isHdr
   ?{ire:100,stimulus:100,signal_r_pct:100,signal_g_pct:100,signal_b_pct:100,r:hdr100,g:hdr100,b:hdr100,input_max:1023,name:'100% White',series_mode:'tone-map'}
   :{ire:100,stimulus:100,signal_r_pct:100,signal_g_pct:100,signal_b_pct:100,r:235,g:235,b:235,input_max:255,name:'100% White',series_mode:'tone-map'};
  meterSeriesSteps=[white];
  meterCurrentPatchStep=white;
  // No thumbs / greyscale chart suite for tone-map (peak bar only).
  try{ if(typeof meterSetThumbsVisible==='function') meterSetThumbsVisible(false); }catch(e2){}
  // Idle/stop so the panel is not sitting on 100% white while the operator waits.
  fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'}),_quiet:true,_timeoutMs:5000}).catch(()=>{});
 }catch(e){}
 meterToneMapSetLiveY(null);
 meterToneMapSetStatus('Idle — press Measure & Upload for a short white flash + peak read, then tone-map upload.');
 meterUpdateToneMapPanelVisibility();
 meterUpdateReadButtons();
 if(typeof meterUpdateSeriesTabUi==='function') meterUpdateSeriesTabUi();
}

function meterUpdateToneMapPanelVisibility(){
 const panel=document.getElementById('meterToneMapPanel');
 const charts=document.getElementById('meterCharts');
 const exportRow=document.getElementById('meterExportRow');
 const seriesOn=typeof meterIsToneMapSeries==='function'?meterIsToneMapSeries():false;
 const hdrOk=typeof meterToneMapSeriesAllowedForSignal==='function'?meterToneMapSeriesAllowedForSignal():false;
 const show=!!(seriesOn&&hdrOk);
 if(panel) panel.style.display=show?'':'none';
 if(show){
  // Peak-only UI: luminance bar + Measure & Upload — no greyscale/color charts.
  if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(false);
  else if(charts) charts.style.display='none';
  if(exportRow) exportRow.style.display='none';
  try{ if(typeof meterSetThumbsVisible==='function') meterSetThumbsVisible(false); }catch(e){}
  try{ meterUpdateGreyscaleChartMode(); }catch(e){}
 } else {
  // Leaving Tone Map: restore chart shell when a series is active — but never
  // on an empty 3D LUT tab (ColorChecker leftovers must stay hidden).
  try{ meterUpdateGreyscaleChartMode(); }catch(e){}
  if(typeof meterShouldSuppressMeterCharts==='function'&&meterShouldSuppressMeterCharts()){
   if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(false);
   else if(charts){ charts.style.display='none'; charts.setAttribute('data-3dlut-empty','1'); }
   if(exportRow) exportRow.style.display='none';
   return;
  }
  if(charts&&meterActiveSeriesType&&meterDetected){
   if(typeof meterSetMeterChartsVisible==='function') meterSetMeterChartsVisible(true);
   else charts.style.display='';
   const grey=document.getElementById('chartsGreyscaleWrap');
   const color=document.getElementById('chartsColorWrap');
   if(meterActiveSeriesType==='greyscale'){
    if(grey) grey.style.display='';
    if(color) color.style.display='none';
   } else if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations'){
    if(grey) grey.style.display='none';
    if(color) color.style.display='';
   }
  }
 }
}

function meterToneMapSetLiveY(nits){
 const yEl=document.getElementById('meterToneMapLiveY');
 const fill=document.getElementById('meterToneMapLuminanceFill');
 const y=Number(nits);
 if(yEl) yEl.textContent=(Number.isFinite(y)&&y>0)?y.toFixed(2):'--';
 if(fill){
  // Bar scales 0–2000 nits for HDR peaks (clamped display only).
  const pct=Number.isFinite(y)&&y>0?Math.max(0,Math.min(100,(y/2000)*100)):0;
  fill.style.width=pct+'%';
 }
}

function meterToneMapSetStatus(text,isError){
 const el=document.getElementById('meterToneMapStatusText');
 if(!el) return;
 el.textContent=String(text||'');
 el.style.color=isError?'var(--red,#f66)':'var(--text2)';
}

// Fast peak-only white measure for standalone Tone Map series.
// Keeps full-field white on for a short settle + one read, then stops immediately
// so OLED ABL/warm-up does not inflate the peak uploaded to the tone map.
async function meterToneMapMeasurePeakFast(){
 const hdr100=(typeof meterLgHdrHundredPercentCodeForRange==='function')?meterLgHdrHundredPercentCodeForRange():1023;
 const step={ire:100,stimulus:100,signal_r_pct:100,signal_g_pct:100,signal_b_pct:100,r:hdr100,g:hdr100,b:hdr100,input_max:1023,name:'100% White',series_mode:'tone-map'};
 let peak=null;
 try{
  if(typeof meterDisplayPatch==='function') await meterDisplayPatch(step,{fresh:false,allowAfterStop:true});
  // Short settle only — long white dwell (multi-second meter delay + low-light
  // averaging) heats WRGB OLEDs and raises the peak used for tone-map upload.
  await new Promise(r=>setTimeout(r,250));
  const dtype=(typeof getEffectiveDisplayType==='function')?getEffectiveDisplayType():'';
  const rr=(typeof getMeterRefreshRate==='function')?getMeterRefreshRate():'';
  // Cap integration delay; white peak does not need multi-second meter delay.
  const userDelay=(typeof meterDelayMs==='function')?Number(meterDelayMs())||0:0;
  const delay=Math.min(Math.max(userDelay,0),350);
  const patternSignalRange=(typeof meterMeasurementPatchSignalRange==='function')?meterMeasurementPatchSignalRange():null;
  const readContext={dtype,rr,delay,patternSignalRange,requireDeviceReady:false};
  if(typeof meterStartSingleRead==='function'&&typeof meterBuildManualReadPayload==='function'){
   const payload=meterBuildManualReadPayload(step,readContext);
   // Force single-shot high-luma read (no low-light multi-average).
   if(payload&&payload.low_light) delete payload.low_light;
   payload.delay_ms=delay;
   const result=await meterStartSingleRead(payload);
   if(typeof meterReadResultOk==='function'&&meterReadResultOk(result)&&result.readings&&result.readings[0]){
    peak=(typeof meterReadingLuminanceNits==='function')?meterReadingLuminanceNits(result.readings[0]):(result.readings[0].luminance||result.readings[0].Y);
   }
  }
 }catch(e){
  peak=null;
 }finally{
  // Always kill white ASAP — never leave peak white up during the LG upload.
  try{
   await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'}),_quiet:true,_timeoutMs:5000});
  }catch(e2){}
 }
 return peak;
}

// Standalone HDR tone-map: quick peak measure, then upload via the same
// /api/lg/hdr-tone-map/upload path used by Full AutoCal / greyscale wizard.
async function meterStartToneMapMeasureUpload(){
 if(meterBlockAutoCalForSimulation()) return;
 if(window._meterToneMapBusy) return;
 const sig=String((typeof getVal==='function'?getVal('signal_mode'):'')||(typeof meterLgAutoCalRequestedSignalMode==='function'?meterLgAutoCalRequestedSignalMode():'')||'').toLowerCase();
 if(sig!=='hdr10'&&!(typeof meterChartIsHdr==='function'&&meterChartIsHdr())){
  toast('HDR tone map requires HDR10 signal mode',true);
  meterToneMapSetStatus('HDR tone map requires HDR10 signal mode.',true);
  return;
 }
 if(typeof meterEnsureDetected==='function'){
  try{ await meterEnsureDetected(); }catch(e){}
 }
 if(!meterDetected){
  toast('Connect a meter before measuring peak luminance',true);
  meterToneMapSetStatus('No meter detected.',true);
  return;
 }
 window._meterToneMapBusy=true;
 try{ meterUpdateReadButtons(); }catch(e){}
 const btn=document.getElementById('meterToneMapMeasureUploadBtn');
 if(btn){ btn.disabled=true; btn.textContent='Measuring...'; }
 meterToneMapSetStatus('Short white flash — measuring peak (then off immediately)...');
 meterToneMapSetLiveY(null);
 let peak=null;
 try{
  peak=await meterToneMapMeasurePeakFast();
 }catch(e){
  peak=null;
 }
 if(!(Number.isFinite(peak)&&peak>0)){
  toast('Could not measure 100% white peak',true);
  meterToneMapSetStatus('Measurement failed — check meter placement and try again.',true);
  window._meterToneMapBusy=false;
  if(btn){ btn.disabled=false; btn.textContent='\u25B6 Measure & Upload'; }
  try{ meterUpdateReadButtons(); }catch(e){}
  return;
 }
 meterToneMapSetLiveY(peak);
 meterToneMapSetStatus('Measured '+peak.toFixed(1)+' cd/m\u00B2 (white off) — uploading HDR tone map...');
 if(btn) btn.textContent='Uploading...';
 const pictureMode=(typeof meterLgPictureModeValue==='function')?meterLgPictureModeValue():'';
 // Optional DPG from last greyscale/full-autocal state (same session binding as Full AutoCal).
 let dpg=null;
 try{
  const grey=meterFullAutoCalResults&&meterFullAutoCalResults.first;
  if(grey&&Array.isArray(grey.hdr20_1d_dpg)&&grey.hdr20_1d_dpg.length===3072) dpg=grey.hdr20_1d_dpg;
  else if(grey&&Array.isArray(grey.dpg_data)&&grey.dpg_data.length===3072) dpg=grey.dpg_data;
 }catch(e){}
 try{
  const body={picture_mode:pictureMode,peak_luminance:peak,helper_timeout:90};
  if(dpg) body.dpg_data=dpg;
  const response=await fetchJSON('/api/lg/hdr-tone-map/upload',{
   method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify(body),
   _timeoutMs:100000
  });
  if(response&&response.status==='ok'){
   toast('HDR tone map uploaded (peak='+peak.toFixed(1)+' nits)');
   meterToneMapSetStatus('Uploaded tone map at peak '+peak.toFixed(1)+' cd/m\u00B2'+(dpg?' (with greyscale DPG)':'')+'.',false);
   try{
    meterAutoCalPersistHdrToneMapChoice('standalone-manual',{user_choice:'uploaded',peak_luminance:peak,source:'tone-map-series',response});
    meterAutoCalRecordHdrToneMapReport({user_choice:'uploaded',peak_luminance:peak,source:'tone-map-series'});
   }catch(e){}
  }else{
   const msg=(response&&response.message)||'HDR tone map upload failed';
   toast(msg,true);
   meterToneMapSetStatus(msg,true);
  }
 }catch(e){
  const msg='HDR tone map upload failed: '+(e&&e.message?e.message:e);
  toast(msg,true);
  meterToneMapSetStatus(msg,true);
 }
 window._meterToneMapBusy=false;
 if(btn){ btn.disabled=false; btn.textContent='\u25B6 Measure & Upload'; }
 try{ meterUpdateReadButtons(); }catch(e){}
}

function meterUpdateGreyscaleChartMode(){
 const full=document.getElementById('chartsGreyscaleFullWrap');
 const twoPoint=document.getElementById('chartsGreyscaleTwoPointWrap');
 const card=document.getElementById('meterCard');
 // Tone Map series is peak-only — hide the full greyscale chart suite
 // (same idea as 2pt, which swaps to a minimal layout).
 if(typeof meterIsToneMapSeries==='function'&&meterIsToneMapSeries()){
  if(card) card.classList.remove('meter-two-point-active');
  if(full) full.style.display='none';
  if(twoPoint) twoPoint.style.display='none';
  return;
 }
 const showTwoPoint=meterIsTwoPointGreyscale();
 if(card) card.classList.toggle('meter-two-point-active',showTwoPoint);
 if(full) full.style.display=showTwoPoint?'none':'';
 if(twoPoint) twoPoint.style.display=showTwoPoint?'':'none';
}

function meterGreyDefaultSlots(points){
 if(points===100) return Array.from({length:101},(_,idx)=>idx);
 if(points===30) return [...METER_GREY_SLOTS_HDR30];
 return points===11?[...METER_GREY_SLOTS_11]:[...METER_GREY_SLOTS_21];
}

function meterUseLgGreyscale21(points){
 const normalized=(points===256)?100:Number(points);
 const manual22Enabled=(typeof METER_LG_GREY_MANUAL_22_ENABLED!=='undefined') && METER_LG_GREY_MANUAL_22_ENABLED;
 return manual22Enabled&&normalized===21&&meterGreyTvControlsActive();
}

function meterUseLgAutoCal26(points){
 const normalized=(points===256)?100:Number(points);
 return normalized===26&&meterGreyTvControlsActive();
}

function meterGreyAllowsHeadroomTargets(){
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const normalized=(Number(meterActiveSeriesPoints)===256)?100:Number(meterActiveSeriesPoints);
 // Only YCbCr-Limited SDR has the super-white ladder (99/105/109). Full and
 // RGB Limited never carry headroom above 100%, so the headroom chart math
 // (above-100% target line / above-100% measured stamps) is YCbCr-Limited-only.
 if(typeof meterSdr26UsesSuperWhiteLadder==='function' && !meterSdr26UsesSuperWhiteLadder()) return false;
 return meterActiveSeriesType==='greyscale'&&normalized===26&&mode==='sdr';
}

function meterLgGreyscaleUsesExtendedSdr(points){
 const normalized=(points===256)?100:Number(points);
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 const useLg21=(typeof meterUseLgGreyscale21==='function')&&meterUseLgGreyscale21(normalized);
 const useLg26=(typeof meterUseLgAutoCal26==='function')&&meterUseLgAutoCal26(normalized);
 return (useLg21||useLg26)&&mode==='sdr'&&meterGreyTvControlsActive();
}

function meterLgGreyscaleUsesLegalSdrDdcCodes(points){
 return false;
}

function meterLgAutoCalUsesExtendedSdr(){
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 return meterActiveSeriesType==='greyscale'&&(meterUseLgGreyscale21(meterActiveSeriesPoints)||meterUseLgAutoCal26(meterActiveSeriesPoints))&&mode==='sdr'&&meterGreyTvControlsActive();
}

function meterGreySeriesSlots(points){
 if(points===256) points=100;
 if(meterUseHdrGreyscale30(points)) return [...METER_GREY_SLOTS_HDR30];
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 // HDR/DV: this list is ASCENDING after 0%. METER_LG_GREY_HDR_AUTOCAL_SLOTS is
 // stored descending, so the original `.slice().reverse()` produced ascending --
 // an earlier version of this merge re-sorted then reversed again and inverted
 // the whole ladder, which wrecked the EOTF/luminance curves and the bar-chart
 // axis. The WORKER does its own descending pass (@top_down); this client list
 // only drives the step order, charts and thumbs, and must stay ascending.
 if(Number(points)===26&&meterUseLgAutoCal26(points)&&(mode==='hdr10'||mode==='dv')){
  return [0,...meterDarkDetailMergeBody(METER_LG_GREY_HDR_AUTOCAL_SLOTS.slice().reverse(),mode)];
 }
 if(meterUseLgAutoCal26(points)){
  if(mode==='sdr'&&typeof meterLgAutoCalSdr26SeriesSlots==='function') return meterLgAutoCalSdr26SeriesSlots();
  return [...METER_LG_GREY_AUTOCAL_SERIES_SLOTS];
 }
 if(meterUseLgGreyscale21(points)) return [...METER_LG_GREY_SERIES_SLOTS];
 return meterGreyDefaultSlots(points);
}

function meterGreyProfileSlots(points){
 const normalized=(points===256)?100:Number(points);
 if(normalized===30) return [...METER_GREY_SLOTS_HDR30];
 const mode=String((meterActiveSeriesSignalMode||meterChartSignalMode()||'sdr')).toLowerCase();
 if(normalized===26&&meterUseLgAutoCal26(normalized)&&(mode==='hdr10'||mode==='dv')) return [0,...METER_LG_GREY_HDR_AUTOCAL_SLOTS.slice().reverse()];
 if(meterUseLgAutoCal26(normalized)){
  if(mode==='sdr'&&typeof meterLgAutoCalSdr26SeriesSlots==='function') return meterLgAutoCalSdr26SeriesSlots();
  return [...METER_LG_GREY_AUTOCAL_SERIES_SLOTS];
 }
 if(meterUseLgGreyscale21(normalized)) return [...METER_LG_GREY_SERIES_SLOTS];
 return meterGreyDefaultSlots(normalized);
}

function meterGreyAnalysisIreFromCode(code){
 const value=Number(code);
 if(!Number.isFinite(value)) return 0;
 if(value<=0) return 0;
 if(value>=255) return 100;
 return value*100/255;
}

function meterGreyscaleStepLabel(step){
 if(!step) return '';
 if(step.name!=null && String(step.name)!=='') return String(step.name);
 if(step.ire!=null){
  const ire=Number(step.ire);
  if(Number.isFinite(ire)) return (Math.round(ire*100)/100)+'%';
 }
 return '';
}

function meterGreyscaleChartLabel(step,steps,idx){
 const label=meterGreyscaleStepLabel(step);
 return label||'';
 }

function meterGreyClampPercent(value,fallback){
 let numeric=Number(value);
 if(!Number.isFinite(numeric)) numeric=Number(fallback);
 if(!Number.isFinite(numeric)) numeric=0;
 numeric=Math.max(0,Math.min(100,numeric));
 return Math.round(numeric*10)/10;
}

function meterGreyPercentEquals(a,b){
 return Math.abs((Number(a)||0)-(Number(b)||0))<0.05;
}

function meterGreyNormalizeEntry(slot,raw){
 const hasObject=!!(raw&&typeof raw==='object');
 const hasRgb=hasObject&&(raw.r!=null||raw.g!=null||raw.b!=null);
 const stimulusSource=(hasObject&&raw.stimulus!=null)?raw.stimulus:(raw!=null&&!hasObject?raw:slot);
 const stimulus=meterGreyClampPercent(stimulusSource,slot);
 const entry={slot:slot,stimulus:stimulus,r:stimulus,g:stimulus,b:stimulus};
 if(hasRgb){
  entry.r=meterGreyClampPercent(raw.r,stimulus);
  entry.g=meterGreyClampPercent(raw.g,stimulus);
  entry.b=meterGreyClampPercent(raw.b,stimulus);
 }
 return entry;
}

function meterLgGreyDefaultEntry(slot){
 const key=meterFormatPercentValue(slot);
 const stimulus=(Object.prototype.hasOwnProperty.call(METER_LG_GREY_STIMULUS_22,key))?METER_LG_GREY_STIMULUS_22[key]:slot;
 return meterGreyNormalizeEntry(slot,stimulus);
}

function meterLgAutoCalDefaultEntry(slot){
 const code=meterLgAutoCalCodeForSlot(slot);
 const stimulus=meterLgAutoCalStimulusFromCode(code);
 return meterGreyNormalizeEntry(slot,stimulus);
}

function meterLgDdcStepHasCustomStimulus(step,slot){
 if(!step) return false;
 const target=Number(slot);
 const keys=['stimulus','signal_r_pct','signal_g_pct','signal_b_pct'];
 return keys.some(key=>step[key]!=null&&!meterGreyPercentEquals(step[key],target));
}

function meterGreyProfileStepsKey(points){
 const normalized=(points===256)?100:points;
 return 'steps_'+normalized;
}

function meterGreyProfileTemplate(){
 const makeSteps=(points)=>{
  const out={};
  meterGreyProfileSlots(points).forEach(slot=>{out[String(slot)]=meterGreyNormalizeEntry(slot,null);});
  return out;
 };
 return {enabled:false,steps_11:makeSteps(11),steps_21:makeSteps(21),steps_30:makeSteps(30),steps_100:makeSteps(100)};
}

function meterGreyModeSignature(){
 return [
  getVal('signal_mode')||'sdr',
  'fmt:'+(getVal('color_format')||'0'),
  'bpc:'+(getVal('max_bpc')||'8'),
  'range:'+(getVal('rgb_quant_range')||'0'),
  'color:'+(getVal('colorimetry')||'0'),
  'prim:'+(getVal('primaries')||'0'),
  'eotf:'+(getVal('eotf')||'0')
 ].join('|');
}
// Human-readable version of the active mode signature, derived from the live
// <select> option text so it can never drift from the dropdowns. Used by the
// custom-greyscale status labels (which previously dumped the raw numeric
// signature, e.g. "sdr|fmt:1|range:1|..."). Omits EOTF/primaries when they are
// the plain SDR defaults to keep the label short; always includes signal mode,
// color format, bit depth, range and colorimetry since those actually scope a
// custom greyscale profile.
function meterGreyModeSignatureLabel(){
 const parts=[
  meterSelectLabel('signal_mode')||'SDR',
  meterSelectLabel('color_format'),
  meterSelectLabel('max_bpc'),
  meterSelectLabel('rgb_quant_range'),
  meterSelectLabel('colorimetry')
 ].filter(p=>p&&String(p).length);
 const eotf=getVal('eotf')||'0';
 const primaries=getVal('primaries')||'0';
 if(eotf!=='0') parts.push(meterSelectLabel('eotf'));
 if(primaries!=='0') parts.push(meterSelectLabel('primaries'));
 return parts.join(' \u00b7 ');
}

function meterGreyNormalizeProfilesState(){
 if(!meterGreyPatchProfiles||typeof meterGreyPatchProfiles!=='object') meterGreyPatchProfiles={};
 meterGreyPatchProfiles.format='pgenerator-greyscale-profile-v2';
 meterGreyPatchProfiles.apply_to_all_modes=!!meterGreyPatchProfiles.apply_to_all_modes;
 if(!meterGreyPatchProfiles.profiles||typeof meterGreyPatchProfiles.profiles!=='object') meterGreyPatchProfiles.profiles={};
 // One-time migration: older builds keyed profiles WITHOUT a bpc: segment, so
 // 8-bit and 10-bit shared one table. The key now includes bpc:<max_bpc>; re-
 // key any legacy entry under the current bit depth (inserting the bpc: segment
 // in the SAME position meterGreyModeSignature builds it -- after fmt:) so the
 // migrated key resolves correctly. Existing custom values keep working where
 // they were last seen; the other bit depth starts fresh. Runs once per bundle.
 if(!meterGreyPatchProfiles.migrated_bpc_keys){
  const curBpc=getVal('max_bpc')||'8';
  const legacy={};
  Object.keys(meterGreyPatchProfiles.profiles).forEach(key=>{
   if(key==='__all__') return;
   if(!/\bbpc:/.test(key)) legacy[key]=meterGreyPatchProfiles.profiles[key];
  });
  Object.keys(legacy).forEach(key=>{
   delete meterGreyPatchProfiles.profiles[key];
   // Reconstruct with bpc: after fmt:, matching meterGreyModeSignature order.
   const segs=key.split('|');
   const out=[];
   let inserted=false;
   for(let si=0;si<segs.length;si++){
    out.push(segs[si]);
    if(!inserted && /^fmt:/.test(segs[si])){ out.push('bpc:'+curBpc); inserted=true; }
   }
   if(!inserted) out.push('bpc:'+curBpc);
   const nk=out.join('|');
   if(!meterGreyPatchProfiles.profiles[nk]) meterGreyPatchProfiles.profiles[nk]=legacy[key];
  });
  meterGreyPatchProfiles.migrated_bpc_keys=true;
 }
 const normalize=(profile)=>{
  const base=meterGreyProfileTemplate();
  const src=(profile&&typeof profile==='object')?profile:{};
  base.enabled=!!src.enabled;
  [11,21,30,100].forEach(points=>{
   const key=meterGreyProfileStepsKey(points);
   const slots=meterGreyProfileSlots(points);
   const out={};
   slots.forEach((slot,idx)=>{
    const raw=src[key]&&src[key][String(slot)];
  const entry=meterGreyNormalizeEntry(slot,raw);
  const hadCustom=!!(raw&&typeof raw==='object'&&(raw.r!=null||raw.g!=null||raw.b!=null));
    if(idx>0){
     const prev=out[String(slots[idx-1])].stimulus;
   if(entry.stimulus<prev){
    entry.stimulus=prev;
    if(!hadCustom){
     entry.r=entry.stimulus;
     entry.g=entry.stimulus;
     entry.b=entry.stimulus;
    }
   }
    }
  out[String(slot)]=entry;
   });
   base[key]=out;
  });
  return base;
 };
 Object.keys(meterGreyPatchProfiles.profiles).forEach(key=>{
  meterGreyPatchProfiles.profiles[key]=normalize(meterGreyPatchProfiles.profiles[key]);
 });
 if(!meterGreyPatchProfiles.profiles['__all__']) meterGreyPatchProfiles.profiles['__all__']=meterGreyProfileTemplate();
 return meterGreyPatchProfiles;
}

function meterGreyActiveProfileKey(){
 const state=meterGreyNormalizeProfilesState();
 return state.apply_to_all_modes?'__all__':meterGreyModeSignature();
}

function meterGreyActiveProfile(create){
 const state=meterGreyNormalizeProfilesState();
 const key=meterGreyActiveProfileKey();
 if(!state.profiles[key]&&create) state.profiles[key]=meterGreyProfileTemplate();
 return state.profiles[key]||null;
}

function meterGreyProfileEntry(points,slot,create){
 const normalized=(points===256)?100:points;
 const stepsKey=meterGreyProfileStepsKey(normalized);
 const profile=meterGreyActiveProfile(!!create);
 if(!profile) return meterGreyNormalizeEntry(slot,null);
 if(!profile[stepsKey]&&create) profile[stepsKey]=meterGreyProfileTemplate()[stepsKey]||{};
 let entry=profile[stepsKey]&&profile[stepsKey][String(slot)];
 if(!entry&&create){
  entry=meterGreyNormalizeEntry(slot,null);
  profile[stepsKey][String(slot)]=entry;
  return entry;
 }
 if(entry&&create){
  entry=meterGreyNormalizeEntry(slot,entry);
  profile[stepsKey][String(slot)]=entry;
 }
 return entry||meterGreyNormalizeEntry(slot,null);
}

function meterGreySignalEntries(points){
 const normalized=(points===256)?100:points;
 const slots=meterGreySeriesSlots(normalized);
 const profile=meterGreyActiveProfile(true);
 const useCustom=!!(profile&&profile.enabled);
 if(!useCustom&&meterUseLgGreyscale21(normalized)) return slots.map(slot=>meterLgGreyDefaultEntry(slot));
 return slots.map(slot=>useCustom?meterGreyProfileEntry(normalized,slot,true):meterGreyNormalizeEntry(slot,null));
}

function meterGreyCustomEnabled(){
 const profile=meterGreyActiveProfile(true);
 return !!(profile&&profile.enabled);
}

function meterGreyStimulusValues(points){
 return meterGreySignalEntries(points).map(entry=>entry.stimulus);
}

function meterGreyStimulusCsv(points){
 return meterGreyStimulusValues(points).map(v=>String(Math.round(v*100)/100)).join(',');
}

function meterGreyChannelValues(points,channel){
 const key=String(channel||'').toLowerCase();
 return meterGreySignalEntries(points).map(entry=>{
  const value=(key==='r'||key==='g'||key==='b')?entry[key]:entry.stimulus;
  return meterGreyClampPercent(value,entry.stimulus);
 });
}

function meterGreyChannelCsv(points,channel){
 return meterGreyChannelValues(points,channel).map(v=>String(Math.round(v*100)/100)).join(',');
}

function meterGreySyncUi(){
 meterGreyNormalizeProfilesState();
 const enabled=meterGreyCustomEnabled();
 const chk=document.getElementById('meterUseCustomGreyscale');
 if(chk) chk.checked=enabled;
 const label=document.getElementById('meterGreyProfileModeLabel');
 if(label) label.textContent=meterGreyPatchProfiles.apply_to_all_modes?'All modes':meterGreyModeSignatureLabel();
 const actions=document.getElementById('meterGreyProfileActions');
 if(actions) actions.style.display=enabled?'flex':'none';
}

function meterToggleCustomGreyscale(){
 const chk=document.getElementById('meterUseCustomGreyscale');
 const profile=meterGreyActiveProfile(true);
 if(profile) profile.enabled=!!(chk&&chk.checked);
 meterGreySyncUi();
 saveMeterSettings();
 meterRefreshActiveSeriesCharts();
}

function meterOpenGreyProfileImport(){
 const input=document.getElementById('meterGreyProfileImportInput');
 if(!input) return;
 input.value='';
 input.click();
}

function meterExportGreyProfile(){
 meterGreyNormalizeProfilesState();
 const filename=meterPromptExportFilename('greyscale-profile','pgenerator-greyscale-profile','json','Enter a file name for the custom greyscale export');
 if(!filename) return;
 const blob=new Blob([JSON.stringify(meterGreyPatchProfiles,null,2)],{type:'application/json'});
 meterDownloadBlob(blob,filename);
}

function meterImportGreyProfile(evt){
 const file=evt&&evt.target&&evt.target.files?evt.target.files[0]:null;
 if(!file) return;
 const reader=new FileReader();
 reader.onload=()=>{
  try{
   meterGreyPatchProfiles=JSON.parse(String(reader.result||'{}'));
   meterGreyNormalizeProfilesState();
   meterGreySyncUi();
   saveMeterSettings();
   meterRefreshActiveSeriesCharts();
   toast('Greyscale profile imported');
  }catch(e){
   toast('Invalid greyscale profile file',true);
  }
 };
 reader.readAsText(file);
}

function meterOpenGreyProfileEditor(points){
 meterGreyNormalizeProfilesState();
 meterGreyEditorPoints=(points===11)?11:21;
 const modal=document.getElementById('meterGreyProfileModal');
 if(!modal) return;
 const applyAll=document.getElementById('meterGreyApplyAll');
 if(applyAll) applyAll.checked=!!meterGreyPatchProfiles.apply_to_all_modes;
 const label=document.getElementById('meterGreyModalModeLabel');
 if(label) label.textContent=meterGreyModeSignatureLabel();
 meterRenderGreyProfileEditor();
 modal.style.display='flex';
 uiSyncBodyScrollLock();
}

function meterCloseGreyProfileEditor(){
 const modal=document.getElementById('meterGreyProfileModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

function meterSetGreyEditorPoints(points){
 meterGreyEditorPoints=(points===11)?11:21;
 meterRenderGreyProfileEditor();
}

function meterRenderGreyProfileEditor(){
 meterGreyNormalizeProfilesState();
 const btn11=document.getElementById('meterGreyEdit11Btn');
 const btn21=document.getElementById('meterGreyEdit21Btn');
 if(btn11){btn11.classList.toggle('btn-primary',meterGreyEditorPoints===11);btn11.classList.toggle('btn-secondary',meterGreyEditorPoints!==11);}
 if(btn21){btn21.classList.toggle('btn-primary',meterGreyEditorPoints===21);btn21.classList.toggle('btn-secondary',meterGreyEditorPoints!==21);}
 const applyAll=document.getElementById('meterGreyApplyAll')&&document.getElementById('meterGreyApplyAll').checked;
 const key=applyAll?'__all__':meterGreyModeSignature();
 if(!meterGreyPatchProfiles.profiles[key]) meterGreyPatchProfiles.profiles[key]=meterGreyProfileTemplate();
 const profile=meterGreyPatchProfiles.profiles[key];
 const slots=meterGreyProfileSlots(meterGreyEditorPoints);
 const stepsKey=meterGreyProfileStepsKey(meterGreyEditorPoints);
 const body=document.getElementById('meterGreyProfileEditorBody');
 if(!body) return;
 body.innerHTML=slots.map(slot=>{
  const entry=profile[stepsKey][String(slot)]||{slot:slot,stimulus:slot};
  const val=(entry&&entry.stimulus!=null)?entry.stimulus:slot;
  return '<tr style="border-bottom:1px solid #1a1a28">'
   +'<td style="padding:6px">'+slot+'%</td>'
   +'<td style="padding:6px;color:#999">'+slot+'%</td>'
   +'<td style="padding:6px"><input type="number" min="0" max="100" step="0.1" data-grey-slot="'+slot+'" value="'+val+'" style="width:100%;background:#0d0d15;border:1px solid #2a3140;border-radius:4px;color:#eee;padding:6px;box-sizing:border-box"></td>'
   +'</tr>';
 }).join('');
}

function meterResetGreyProfileEditor(){
 const applyAll=document.getElementById('meterGreyApplyAll')&&document.getElementById('meterGreyApplyAll').checked;
 const key=applyAll?'__all__':meterGreyModeSignature();
 meterGreyPatchProfiles.profiles[key]=meterGreyProfileTemplate();
 meterRenderGreyProfileEditor();
}

function meterSaveGreyProfileEditor(){
 meterGreyNormalizeProfilesState();
 const applyAll=!!(document.getElementById('meterGreyApplyAll')&&document.getElementById('meterGreyApplyAll').checked);
 const slots=meterGreyProfileSlots(meterGreyEditorPoints);
 const vals=[];
 let prev=-1;
 for(const slot of slots){
  const input=document.querySelector('#meterGreyProfileEditorBody input[data-grey-slot="'+slot+'"]');
  let v=input?parseFloat(input.value):slot;
  if(!Number.isFinite(v)) v=slot;
  v=Math.max(0,Math.min(100,v));
  if(prev>v){ toast('Custom greyscale values must be monotonic ascending',true); return; }
  vals.push(v);
  prev=v;
 }
 meterGreyPatchProfiles.apply_to_all_modes=applyAll;
 const key=applyAll?'__all__':meterGreyModeSignature();
 if(!meterGreyPatchProfiles.profiles[key]) meterGreyPatchProfiles.profiles[key]=meterGreyProfileTemplate();
 const profile=meterGreyPatchProfiles.profiles[key];
 profile.enabled=true;
 const stepsKey=meterGreyProfileStepsKey(meterGreyEditorPoints);
 slots.forEach((slot,idx)=>{
  const prevEntry=meterGreyNormalizeEntry(slot,profile[stepsKey]&&profile[stepsKey][String(slot)]);
  const preserveCustom=!meterGreyPercentEquals(prevEntry.r,prevEntry.stimulus)||!meterGreyPercentEquals(prevEntry.g,prevEntry.stimulus)||!meterGreyPercentEquals(prevEntry.b,prevEntry.stimulus);
  const nextEntry={slot:slot,stimulus:vals[idx],r:vals[idx],g:vals[idx],b:vals[idx]};
  if(preserveCustom){
   nextEntry.r=meterGreyClampPercent(prevEntry.r,vals[idx]);
   nextEntry.g=meterGreyClampPercent(prevEntry.g,vals[idx]);
   nextEntry.b=meterGreyClampPercent(prevEntry.b,vals[idx]);
  }
  profile[stepsKey][String(slot)]=nextEntry;
 });
 const chk=document.getElementById('meterUseCustomGreyscale');
 if(chk) chk.checked=true;
 meterGreySyncUi();
 meterCloseGreyProfileEditor();
 saveMeterSettings();
 meterRefreshActiveSeriesCharts();
 toast('Custom greyscale values saved');
}
// ---- Custom user-defined patch series ----
// One state blob, persisted as custom_series_json via /api/meter/settings
// (same mechanism as grey_patch_profiles_json). Series ids start at 1001 so
// the series key "greyscale-<id>" / "colors-<id>" can never collide with the
// built-in points values (2,11,21,24,26,30,100,256).
// Manual / CSV / CCFX patch lists were historically capped at 200; raise high
// enough for large CalMAN / ColourSpace imports (400–2k+ nodes). Lattice
// series expand from params and are not subject to this store limit.
const METER_CUSTOM_SERIES_MAX_PATCHES=3000;
let meterCustomSeriesState={format:'pgenerator-custom-series-v1',next_id:1001,series:[]};
let meterCustomSeriesNormalizedState=null;
let meterCustomSeriesIndexedSeries=null;
let meterCustomSeriesIndex=new Map();
let meterCustomSeriesRawJson='';
let meterCustomSeriesRevision='';

// Durability backup: every custom-series mutation is mirrored to localStorage
// (marked unsynced) and the mark clears once the settings save that carried
// the blob lands on the Pi. At boot, unsynced backup series missing from the
// server blob are merged back and re-saved — so a failed save (daemon
// restart, network blip) followed by a page refresh can no longer lose work.
const METER_CUSTOM_SERIES_BACKUP_KEY='pgen.meter.customSeries.backup';
function meterCustomSeriesBackupWrite(unsynced){
 try{ localStorage.setItem(METER_CUSTOM_SERIES_BACKUP_KEY,JSON.stringify({unsynced:!!unsynced,state:meterCustomSeriesState})); }catch(e){}
}
function meterCustomSeriesBackupRead(){
 try{
  const raw=localStorage.getItem(METER_CUSTOM_SERIES_BACKUP_KEY);
  if(raw){ const p=JSON.parse(raw); if(p&&typeof p==='object') return p; }
 }catch(e){}
 return null;
}
function meterCustomSeriesRecoverFromBackup(){
 const backup=meterCustomSeriesBackupRead();
 if(!backup||!backup.unsynced||!backup.state||!Array.isArray(backup.state.series)) return false;
 const have={};
 (meterCustomSeriesState.series||[]).forEach(sr=>{ if(sr) have[String(sr.name||'')+'|'+String(sr.mode||'')]=1; });
 let recovered=0;
 backup.state.series.forEach(sr=>{
  if(!sr||have[String(sr.name||'')+'|'+String(sr.mode||'')]) return;
  meterCustomSeriesState.series.push(sr);
  recovered++;
 });
 if(!recovered) return false;
 meterCustomSeriesNormalizeState();
 meterCustomSeriesDirty=true;
 return true;
}

function meterCustomSeriesModeKey(mode){
 const m=String(mode!=null?mode:((typeof meterChartSignalMode==='function')?meterChartSignalMode():'sdr')).toLowerCase();
 if(m==='hdr10'||m==='hlg'||m==='hdr') return 'hdr';
 if(m==='dv') return 'dv';
 return 'sdr';
}

// A manual series stores range-specific codes (Limited/legal vs Full), so it is
// tagged with the range its codes were authored for. '' = untagged/legacy (or a
// lattice, whose codes are re-derived from params at read time) and matches any
// output range. Only 'full' and 'limited' are meaningful tags.
function meterCustomSeriesRangeKey(range){
 const r=String(range==null?'':range).toLowerCase();
 if(r==='full'||r==='pc'||r==='extended') return 'full';
 if(r==='limited'||r==='legal'||r==='video'||r==='tv') return 'limited';
 return '';
}

// The range the WebUI is currently driving to the TV (from rgb_quant_range),
// used to show the operator only the series that will render correctly.
function meterCurrentOutputRangeKey(){
 return (typeof meterIsLimitedRange==='function' && meterIsLimitedRange()) ? 'limited' : 'full';
}

// A series is shown for the current output when it is untagged (legacy/lattice)
// or its tag matches the range being output right now.
function meterSeriesMatchesCurrentRange(series){
 if(!series) return false;
 const r=meterCustomSeriesRangeKey(series.range);
 return r==='' || r===meterCurrentOutputRangeKey();
}

function meterCustomSeriesClampCode(value,max){
 const numeric=Math.round(Number(value));
 if(!Number.isFinite(numeric)) return 0;
 return Math.max(0,Math.min(max,numeric));
}

function meterCustomSeriesCode8To10(code8){
 const code=meterCustomSeriesClampCode(code8,255);
 // Preserve the exact full-scale endpoint. A plain left shift maps 255 to
 // 1020, leaving the top three 10-bit codes unreachable from the editor.
 return code===255?1023:code*4;
}

function meterCustomSeriesCode10To8(code10){
 return Math.min(255,Math.round(meterCustomSeriesClampCode(code10,1023)/4));
}

function meterCustomSeriesSanitizePatch(raw,index){
 const src=(raw&&typeof raw==='object')?raw:{};
 const patch={name:'',r8:0,g8:0,b8:0,r10:0,g10:0,b10:0,target_nits:null};
 patch.name=String(src.name==null?'':src.name).replace(/[\[\]{}"\\,]/g,'').slice(0,40).trim();
 if(!patch.name) patch.name='Patch '+Number(index||0);
 ['r','g','b'].forEach(ch=>{
  const c10=Number(src[ch+'10']);
  const c8=Number(src[ch+'8']);
  if(src[ch+'10']!=null&&Number.isFinite(c10)){
   patch[ch+'10']=meterCustomSeriesClampCode(c10,1023);
   patch[ch+'8']=meterCustomSeriesCode10To8(patch[ch+'10']);
  } else {
   patch[ch+'8']=meterCustomSeriesClampCode(c8,255);
   patch[ch+'10']=meterCustomSeriesCode8To10(patch[ch+'8']);
  }
 });
 const nits=Number(src.target_nits);
 patch.target_nits=(Number.isFinite(nits)&&nits>0)?Math.min(10000,nits):null;
 // Optional EXPLICIT target chromaticity. Without it the chart derives the
 // target from the patch codes — which is faithful to the signal but, in PQ,
 // pins nearly every code-defined mix to the gamut edge (small code
 // differences are huge linear-light ratios). Operators who want a specific
 // verification target enter it here and it is used verbatim.
 const tx=Number(src.target_x), ty=Number(src.target_y);
 if(Number.isFinite(tx)&&Number.isFinite(ty)&&tx>0&&tx<1&&ty>0&&ty<1){
  patch.target_x=Math.round(tx*10000)/10000;
  patch.target_y=Math.round(ty*10000)/10000;
 } else {
  patch.target_x=null;
  patch.target_y=null;
 }
 return patch;
}

function meterCustomSeriesNormalizeState(){
 if(!meterCustomSeriesState||typeof meterCustomSeriesState!=='object') meterCustomSeriesState={};
 meterCustomSeriesState.format='pgenerator-custom-series-v1';
 if(!Array.isArray(meterCustomSeriesState.series)) meterCustomSeriesState.series=[];
 const seen={};
 let maxId=1000;
 meterCustomSeriesState.series=meterCustomSeriesState.series.filter(s=>s&&typeof s==='object').map((s,si)=>{
  const id=Math.round(Number(s.id));
  const valid=Number.isFinite(id)&&id>=1001&&!seen[id];
  if(valid){seen[id]=true;if(id>maxId) maxId=id;}
  const kind=(s.kind==='lattice')?'lattice':'manual';
  return {
   id:valid?id:0,
   name:String(s.name==null?'':s.name).replace(/[\[\]{}"\\]/g,'').slice(0,96).trim()||('Custom '+(si+1)),
   category:(kind==='lattice')?'color':((s.category==='color')?'color':'greyscale'),
   mode:meterCustomSeriesModeKey(s.mode),
   range:(kind==='lattice')?'':meterCustomSeriesRangeKey(s.range),
   kind:kind,
   params:(kind==='lattice')?meterLatticeSanitizeParams(s.params):undefined,
   patches:(kind==='lattice')?[]:((Array.isArray(s.patches)?s.patches:[]).slice(0,METER_CUSTOM_SERIES_MAX_PATCHES).map((p,pi)=>meterCustomSeriesSanitizePatch(p,pi)))
  };
 });
 meterCustomSeriesState.series.forEach(s=>{
  if(!s.id){maxId+=1;s.id=maxId;seen[s.id]=true;}
  const used={};
  s.patches.forEach((p,pi)=>{
   if(used[p.name]) p.name=p.name+' #'+(pi+1);
   used[p.name]=true;
  });
 });
 const nextId=Math.round(Number(meterCustomSeriesState.next_id));
 meterCustomSeriesState.next_id=Math.max(maxId+1,Number.isFinite(nextId)?nextId:0,1001);
 meterCustomSeriesNormalizedState=meterCustomSeriesState;
 meterCustomSeriesReindex();
 return meterCustomSeriesState;
}

function meterCustomSeriesReindex(){
 const series=(meterCustomSeriesState&&Array.isArray(meterCustomSeriesState.series))
  ?meterCustomSeriesState.series:[];
 meterCustomSeriesIndex=new Map();
 series.forEach(item=>{
  const id=Math.round(Number(item&&item.id));
  if(Number.isFinite(id)&&id>=1001) meterCustomSeriesIndex.set(id,item);
 });
 meterCustomSeriesIndexedSeries=series;
}

// Normalization sanitizes every stored patch. That is appropriate after a load
// or mutation, but it is far too expensive for a lookup: large imported
// libraries can contain tens of thousands of patches and the chart path asks
// for the active series many times per frame.
function meterCustomSeriesCurrentState(){
 if(meterCustomSeriesNormalizedState!==meterCustomSeriesState) return meterCustomSeriesNormalizeState();
 if(meterCustomSeriesIndexedSeries!==meterCustomSeriesState.series) meterCustomSeriesReindex();
 return meterCustomSeriesState;
}

// Built-in lattice presets live on reserved ids 900-999 (below the 1001+ user
// range) so the 3D Cube tab always has series to select. They behave exactly
// like user lattice series (params-only, range-aware measurement) but are not
// persisted, listed in the manager, or deletable.
const METER_BUILTIN_CUBE_SERIES=[
 {id:903,name:'Cube 3³',category:'color',mode:'any',kind:'lattice',params:{size:3,grey_points:0,threshold_pct:0,order:'spread',reverse:false},patches:[]},
 {id:905,name:'Cube 5³',category:'color',mode:'any',kind:'lattice',params:{size:5,grey_points:0,threshold_pct:0,order:'spread',reverse:false},patches:[]},
 {id:909,name:'Cube 9³',category:'color',mode:'any',kind:'lattice',params:{size:9,grey_points:0,threshold_pct:0,order:'spread',reverse:false},patches:[]},
 {id:917,name:'Cube 17³',category:'color',mode:'any',kind:'lattice',params:{size:17,grey_points:0,threshold_pct:0,order:'spread',reverse:false},patches:[]}
];

// Built-in 3D LUT AutoCal profiling series (reserved ids 920-939). Skeleton =
// multi-level WRGB ramps only; hybrid = skeleton + lattice volume (deduped).
// Not listed on the 3D Cube chart tab as pure lattices; used by profiling selects.
const METER_BUILTIN_3D_PROFILE_SERIES=[
 {id:920,name:'Skeleton WRGB',category:'color',mode:'any',kind:'skeleton',params:{levels:[0,5,10,20,30,40,50,60,70,80,90,100]},patches:[]},
 {id:923,name:'Hybrid 3³',category:'color',mode:'any',kind:'hybrid',params:{size:3,grey_points:0,threshold_pct:0,order:'spread',reverse:false,levels:[0,5,10,20,30,40,50,60,70,80,90,100]},patches:[]},
 {id:925,name:'Hybrid 5³',category:'color',mode:'any',kind:'hybrid',params:{size:5,grey_points:0,threshold_pct:0,order:'spread',reverse:false,levels:[0,5,10,20,30,40,50,60,70,80,90,100]},patches:[]},
 {id:929,name:'Hybrid 9³',category:'color',mode:'any',kind:'hybrid',params:{size:9,grey_points:0,threshold_pct:0,order:'spread',reverse:false,levels:[0,5,10,20,30,40,50,60,70,80,90,100]},patches:[]}
];

// Built-in display-verification libraries use reserved high ids so every
// sequence has its own cache key without entering the editable custom-series
// manager. Fixed-code libraries retain their standard wire codes in SDR and are
// converted through relative linear light in HDR/DV. Classic xyY sets are
// solved into the active signal mode and target gamut by the existing builder.
const METER_BUILTIN_COLORCHECKER_SERIES=[
 {id:800024,name:'Classic (24)',category:'color',mode:'any',kind:'verification',preset:'classic-24',builtin_verification:true,patches:[]},
 {id:800124,name:'HCFR GCD Classic (24)',category:'color',mode:'any',kind:'verification',preset:'hcfr-gcd-24',builtin_verification:true,patches:[]},
 {id:800096,name:'ColorChecker SG (96)',category:'color',mode:'any',kind:'verification',preset:'sg-96',builtin_verification:true,patches:[]},
 {id:800019,name:'SG Skin Tones (19)',category:'color',mode:'any',kind:'verification',preset:'sg-skin-19',builtin_verification:true,patches:[]},
 {id:800137,name:'MacLeod-Boynton Hue Circle (37)',category:'color',mode:'any',kind:'verification',preset:'mb-hue-circle-37',builtin_verification:true,patches:[]},
 {id:800008,name:'MacLeod-Boynton Focal Colours (8)',category:'color',mode:'any',kind:'verification',preset:'mb-focal-8',builtin_verification:true,patches:[]},
 {id:800064,name:'MacLeod-Boynton OSA-UCS Map (64)',category:'color',mode:'any',kind:'verification',preset:'mb-osa-ucs-64',builtin_verification:true,patches:[]}
];

const METER_COLORCHECKER_SG_NAMES=[
 'White','6J','5F','6I','6K','5G','6H','5H','7K','6G','5I','6F','8K','5J','Black',
 '2B','2C','2D','2E','2F','2G','2H','2I','2J','2K','2L','2M',
 '3B','3C','3D','3E','3F','3G','3H','3I','3J','3K','3L','3M',
 '4B','4C','4D','4E','4F','4G','4H','4I','4J','4K','4L','4M',
 '5B','5C','5D','5K','5L','5M','6B','6C','6D','6L','6M',
 '7B','7C','7D','7E','7F','7G','7H','7I','7J','7L','7M',
 '8B','8C','8D','8E','8F','8G','8H','8I','8J','8L','8M',
 '9B','9C','9D','9E','9F','9G','9H','9I','9J','9K','9L','9M'
];
const METER_COLORCHECKER_SG_LEGAL8=[
 [235,235,235],[207,207,207],[185,185,185],[174,174,174],[163,163,163],[150,150,150],[139,139,139],[117,117,117],
 [108,108,108],[97,97,97],[88,88,88],[80,80,80],[62,62,62],[53,53,53],[16,16,16],[141,40,88],[80,55,77],
 [202,196,182],[112,71,49],[191,134,104],[93,112,128],[88,99,42],[126,117,141],[108,171,139],[235,187,147],
 [101,40,51],[180,42,80],[178,126,150],[110,93,134],[233,187,171],[215,112,16],[69,84,139],[187,71,75],
 [86,49,86],[161,171,16],[217,145,16],[200,215,171],[191,16,34],[90,44,62],[117,42,112],[16,62,93],
 [178,204,174],[27,53,117],[73,136,51],[169,16,38],[228,180,16],[182,73,121],[16,126,136],[215,191,180],
 [200,117,119],[180,16,49],[16,123,165],[88,147,165],[235,187,163],[180,200,182],[207,117,104],[222,60,49],
 [58,154,158],[16,66,75],[204,198,130],[235,104,16],[235,154,16],[16,66,60],[117,143,167],[204,121,77],
 [228,163,123],[187,136,95],[139,95,60],[193,145,115],[154,90,44],[200,130,95],[187,169,16],[235,180,16],
 [16,154,139],[16,136,117],[196,134,106],[231,147,115],[187,139,108],[189,136,108],[191,139,106],
 [121,80,49],[202,136,97],[174,139,36],[176,169,16],[71,62,47],[93,154,93],[16,134,84],[42,71,51],
 [66,154,110],[121,150,64],[60,134,38],[80,161,51],[189,130,53],[152,145,38],[158,176,16],[82,53,38]
];
const METER_COLORCHECKER_SG_SKIN_NAMES=[
 'White','Black','2E','2F','2K','5D','7E','7F','7G','7H','7I','7J','8D','8E','8F','8G','8H','8I','8J'
];
const METER_COLORCHECKER_SG_SKIN_LEGAL8=[
 [235,235,235],[16,16,16],[112,71,49],[191,134,104],[235,187,147],[235,187,163],[228,163,123],
 [187,136,95],[139,95,60],[193,145,115],[154,90,44],[200,130,95],[196,134,106],[231,147,115],
 [187,139,108],[189,136,108],[191,139,106],[121,80,49],[202,136,97]
];

function meterBuiltinFixedLegal8Rows(names,codes){
 const pct=code=>(Math.max(16,Math.min(235,Number(code)||16))-16)*100/219;
 return (Array.isArray(codes)?codes:[]).map((rgb,idx)=>[
  (Array.isArray(names)&&names[idx])||('Patch '+(idx+1)),pct(rgb[0]),pct(rgb[1]),pct(rgb[2])
 ]);
}

// A common MacLeod-Boynton experiment samples an equal-luminance hue circle
// at 10-degree intervals. Build 36 chromatic directions around the active
// gamut's neutral plus the neutral reference itself. The two axis radii use
// the established 2754 / 4099 threshold-scaled MB units; a single global
// scale keeps the complete circle inside the selected RGB gamut.
// Colour-appearance data from Cao, Pokorny & Smith (2005), Vision Research 45,
// 1929-1934, figures 1a/1b. Coordinates are the paper's own MacLeod-Boynton cone
// chromaticities: L/(L+M) and S/(L+M), with S normalised so the equal-energy
// spectrum sits at s=1.0 (relative cone troland space).
// Table 3 - focal colours, the black squares in Fig 1b.
const METER_MB_PAPER_FOCAL=[
 {name:'Red',l:0.777,s:0.54},{name:'Green',l:0.630,s:0.44},
 {name:'Blue',l:0.595,s:2.72},{name:'Yellow',l:0.687,s:0.13},
 {name:'Purple',l:0.659,s:2.15},{name:'Orange',l:0.730,s:0.33},
 {name:'Pink',l:0.687,s:1.15},{name:'White',l:0.660,s:0.87}
];
// Table 4 - the OSA-UCS sample gamut in the same coordinates. Straight edges are
// y = a + b x; the lower-left edge is the cubic y = a + b x + c x^2 + d x^3.
const METER_MB_PAPER_GAMUT={
 upper:{a:2.91,b:0.00},lower:{a:0.13,b:0.00},right:{a:14.98,b:-18.50},
 upperLeft:{a:79.44,b:-131.18},
 lowerLeft:{a:1417.43,b:-6522.35,c:10007.04,d:-5118.66}
};
// Table 2 - the White region. Table 4 has NO boundary rows for White: the paper
// puts White "around the cone chromaticity of EES ... surrounded by other basic
// colors" and represents it with an ellipse instead, so a boundary-only
// classifier can never award a point to White. These are the published CENTROID
// ellipse parameters (a and b are semi-axes along the axis rotated theta degrees
// from l, centred on x0/y0). Note this is the spread of the eight observers'
// centroids and is therefore narrow; Fig 1c's larger white region ellipse was
// fitted to the Fig 1a naming data and its parameters are not published, and the
// paper states that for red and white in Fig 1b "a circle of arbitrary size was
// plotted" because only one data point existed. This is the published stand-in.
const METER_MB_PAPER_WHITE_ELLIPSE={a:0.127,b:0.004,theta:92.68,x0:0.661,y0:0.905};
// Table 4 - equal-probability boundaries between adjacent colour names.
// The Red-Pink intercept is +38.40. The published table's minus sign does not
// survive text extraction as a usable line: with a=-38.40 the Red and Pink focal
// colours fall on the SAME side of it (+78.45 and +74.48), so it cannot be the
// boundary between them; with a=+38.40 they separate (+1.65 and -2.32). Every
// other row separates its own pair exactly as published, and all eight focal
// colours land inside the gamut edges above.
const METER_MB_PAPER_REGION_EDGES=[
 {pair:['Blue','Purple'],a:31.95,b:-47.44},{pair:['Purple','Pink'],a:0.89,b:0.47},
 {pair:['Blue','Green'],a:1.74,b:-1.05},{pair:['Green','Yellow'],a:37.17,b:-54.08},
 {pair:['Yellow','Orange'],a:8.08,b:-10.98},{pair:['Orange','Pink'],a:1.58,b:-1.32},
 {pair:['Orange','Red'],a:5.02,b:-5.97},{pair:['Red','Pink'],a:38.40,b:-50.85}
];

// The paper uses Smith-Pokorny fundamentals and equal-energy = (0.66, 1.0).
// The chart's CIE 170-2 fundamentals are globally normalized to that same
// relative cone-troland origin. Derive the anchors from the selected observer
// so the paper reconstruction remains numerically aligned in both MB modes.
function meterMbPaperAnchors(){
 const ten=/_10$/.test(String(meterChromaticityChartMode()||'ciemb_2'));
 const factors=ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
 const lms=meterCieApplyMatrix({X:1,Y:1,Z:1},ten?CIE2015_TO_LMS_10:CIE2015_TO_LMS_2);
 const L=factors[0]*lms.X,M=factors[1]*lms.Y,S=factors[2]*lms.Z,lm=L+M;
 const lE=meterCieMbRelativeL(L/lm,ten),sE=S/lm;
 return {ten:ten,lE:lE,sE:sE,k:sE,r:(0.66/0.34)*((1-lE)/lE)};
}
function meterMbPaperToChart(l,s){
 const a=meterMbPaperAnchors(),lp=Number(l)||0;
 return {l:lp/(lp+a.r*(1-lp)),s:a.k*(Number(s)||0)};
}
// MacLeod-Boynton chromaticity in THIS chart's convention back to XYZ, with L+M
// normalised to 1 so Y is a relative luminance the caller then scales.
function meterMbChartToXyz(l,s){
 const a=meterMbPaperAnchors();
 const factors=a.ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
 const inv=a.ten?CIE_LMS_TO_CIE2015_10:CIE_LMS_TO_CIE2015_2;
 const lv=meterCieMbRawL(Number(l)||0,a.ten);
 return meterCieApplyMatrix({X:lv/factors[0],Y:(1-lv)/factors[1],Z:(Number(s)||0)/factors[2]},inv);
}
function meterMbLuminanceFromXyz(xyz,ten){
 const lms=meterCieApplyMatrix(xyz,ten?CIE2015_TO_LMS_10:CIE2015_TO_LMS_2);
 const factors=ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
 return factors[0]*lms.X+factors[1]*lms.Y;
}

// Scale a chromaticity to the brightest luminance the active gamut can show.
// A chromaticity outside the gamut cannot be reproduced at ANY luminance, so it
// is clamped -- something has to be sent -- and reported, letting the caller
// declare it instead of measuring a silently altered colour and calling it a pass.
function meterMbMaxInGamutRgb(xyz,matrix){
 const det=(M)=>M[0][0]*(M[1][1]*M[2][2]-M[1][2]*M[2][1])
  -M[0][1]*(M[1][0]*M[2][2]-M[1][2]*M[2][0])
  +M[0][2]*(M[1][0]*M[2][1]-M[1][1]*M[2][0]);
 const solve=(M,v)=>{
  const d=det(M);
  if(!isFinite(d)||Math.abs(d)<1e-12) return [0,0,0];
  const col=(i)=>{const C=M.map(row=>row.slice());for(let r=0;r<3;r++) C[r][i]=v[r];return det(C);};
  return [col(0)/d,col(1)/d,col(2)/d];
 };
 let rgb=solve(matrix,[xyz.X,xyz.Y,xyz.Z]);
 if(!rgb.every(v=>isFinite(v))) return {rgb:[0,0,0],scale:0,outOfGamut:true};
 const outOfGamut=(Math.min.apply(null,rgb)<-1e-6);
 const max=Math.max.apply(null,rgb);
 if(!(max>0)) return {rgb:[0,0,0],scale:0,outOfGamut:true};
 const scale=1/max;
 rgb=rgb.map(v=>Math.max(0,Math.min(1,v*scale)));
 return {rgb:rgb,scale:scale,outOfGamut:outOfGamut};
}

// Fig 1b focal colours (Table 3). Chromaticity is exact; luminance is whatever
// the active gamut allows, so it differs from patch to patch.
function meterBuildMbFocalColourSteps(){
 const matrix=meterAnalysisGamut().rgbToXyz;
 const ten=/_10$/.test(String(meterChromaticityChartMode()||'ciemb_2'));
 const inputMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
 return METER_MB_PAPER_FOCAL.map(entry=>{
  const mb=meterMbPaperToChart(entry.l,entry.s);
  const fit=meterMbMaxInGamutRgb(meterMbChartToXyz(mb.l,mb.s),matrix);
  const xyz=linRgbToXyz(fit.rgb[0],fit.rgb[1],fit.rgb[2],matrix);
  const sum=xyz.X+xyz.Y+xyz.Z;
  return {ire:Math.round(xyz.Y*100),
   r:meterEncodeColorCheckerLinear(fit.rgb[0]),g:meterEncodeColorCheckerLinear(fit.rgb[1]),b:meterEncodeColorCheckerLinear(fit.rgb[2]),
   name:'MB Focal '+entry.name+(fit.outOfGamut?' (out of gamut)':''),
   target_x:sum>0?xyz.X/sum:.3127,target_y:sum>0?xyz.Y/sum:.329,target_Yn:xyz.Y,
   input_max:inputMax,series_mode:'mb-focal-'+String(((typeof meterChartSignalMode==='function')?meterChartSignalMode():'sdr')||'sdr').toLowerCase(),
   mb_target_l:mb.l,mb_target_s:mb.s,mb_target_lm:meterMbLuminanceFromXyz(xyz,ten),
   mb_paper_l:entry.l,mb_paper_s:entry.s,
   out_of_gamut:fit.outOfGamut};
 });
}

// Table 4 gamut test, evaluated in the paper's own coordinates.
function meterMbPaperGamutContains(l,s){
 const G=METER_MB_PAPER_GAMUT,x=Number(l)||0,y=Number(s)||0;
 const line=(e)=>e.a+e.b*x;
 const cubic=G.lowerLeft.a+G.lowerLeft.b*x+G.lowerLeft.c*x*x+G.lowerLeft.d*x*x*x;
 return y<=G.upper.a+1e-9&&y>=G.lower.a-1e-9&&y<=line(G.right)+1e-9
  &&y>=line(G.upperLeft)-1e-9&&y>=cubic-1e-6;
}
// Colour name for a point, from Table 4's equal-probability boundaries. Each row
// only decides between its own two names, so score how many pairwise contests
// each name wins and take the leader; the focal colours say which side of a line
// belongs to which name. Ties break toward the nearer focal colour, which is what
// keeps White reachable -- it has no boundary rows of its own. The l distance is
// weighted by ~39 so both axes count comparably, since s spans a ~39x wider range.
function meterMbPaperRegionFor(l,s){
 const x=Number(l)||0,y=Number(s)||0,wins={};
 // White first: it owns an ellipse rather than any boundary row.
 const W=METER_MB_PAPER_WHITE_ELLIPSE,th=W.theta*Math.PI/180;
 const dx=x-W.x0,dy=y-W.y0;
 const u=dx*Math.cos(th)+dy*Math.sin(th),v=-dx*Math.sin(th)+dy*Math.cos(th);
 if((u*u)/(W.a*W.a)+(v*v)/(W.b*W.b)<=1) return 'White';
 METER_MB_PAPER_FOCAL.forEach(f=>{wins[f.name]=0;});
 METER_MB_PAPER_REGION_EDGES.forEach(edge=>{
  const ref=METER_MB_PAPER_FOCAL.find(f=>f.name===edge.pair[0]);
  if(!ref) return;
  const above=y>(edge.a+edge.b*x);
  const refAbove=ref.s>(edge.a+edge.b*ref.l);
  const winner=(above===refAbove)?edge.pair[0]:edge.pair[1];
  wins[winner]=(wins[winner]||0)+1;
 });
 let best='',bestScore=-1,bestDist=Infinity;
 METER_MB_PAPER_FOCAL.forEach(f=>{
  const d=Math.sqrt(Math.pow((f.l-x)*39,2)+Math.pow(f.s-y,2));
  const score=wins[f.name]||0;
  if(score>bestScore||(score===bestScore&&d<bestDist)){best=f.name;bestScore=score;bestDist=d;}
 });
 return best;
}
// Fig 1a reconstruction: a deterministic grid inside the Table 4 gamut, labelled
// by colour region and thinned so each region's share follows its area. The
// paper's own 424 sample coordinates are not published, so this reconstructs the
// figure's structure and is never a copy of its samples. Deterministic on purpose
// -- a fixed stride over sorted points, no RNG -- so the same 64 patches come out
// every run and measurements stay comparable across runs and machines.
function meterBuildMbOsaUcsMapSteps(){
 const TARGET=64,STEPS_L=61,STEPS_S=61;
 const G=METER_MB_PAPER_GAMUT;
 const grid=[];
 // Seed with the eight published focal colours. Each certainly belongs to its
 // own region, and it guarantees every region is represented even where the grid
 // misses a narrow one -- White's published ellipse is only +/-0.004 wide in l.
 METER_MB_PAPER_FOCAL.forEach(f=>{
  if(meterMbPaperGamutContains(f.l,f.s)) grid.push({l:f.l,s:f.s,region:f.name});
 });
 for(let i=0;i<STEPS_L;i++){
  const l=0.45+(0.95-0.45)*(i/(STEPS_L-1));
  for(let j=0;j<STEPS_S;j++){
   const s=G.lower.a+(G.upper.a-G.lower.a)*(j/(STEPS_S-1));
   if(!meterMbPaperGamutContains(l,s)) continue;
   grid.push({l:l,s:s,region:meterMbPaperRegionFor(l,s)});
  }
 }
 if(!grid.length) return [];
 const byRegion={};
 grid.forEach(p=>{(byRegion[p.region]=byRegion[p.region]||[]).push(p);});
 const regions=Object.keys(byRegion).sort();
 const quota={};let assigned=0;
 regions.forEach(name=>{
  const q=Math.max(1,Math.round(TARGET*byRegion[name].length/grid.length));
  quota[name]=q;assigned+=q;
 });
 // Settle the rounding on the largest regions first so the total is exactly
 // TARGET without ever emptying a small region.
 const order=regions.slice().sort((a,b)=>(byRegion[b].length-byRegion[a].length)||(a<b?-1:1));
 let guard=0;
 while(assigned!==TARGET&&guard++<1000){
  for(const name of order){
   if(assigned===TARGET) break;
   if(assigned<TARGET){quota[name]++;assigned++;}
   else if(quota[name]>1){quota[name]--;assigned--;}
  }
 }
 const matrix=meterAnalysisGamut().rgbToXyz;
 const ten=/_10$/.test(String(meterChromaticityChartMode()||'ciemb_2'));
 const inputMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
 const steps=[];
 regions.forEach(name=>{
  const pts=byRegion[name].slice().sort((p,q)=>(p.l-q.l)||(p.s-q.s));
  const want=Math.min(quota[name],pts.length),stride=pts.length/want;
  for(let n=0;n<want;n++){
   const pt=pts[Math.min(pts.length-1,Math.floor(n*stride))];
   const mb=meterMbPaperToChart(pt.l,pt.s);
   const fit=meterMbMaxInGamutRgb(meterMbChartToXyz(mb.l,mb.s),matrix);
   const xyz=linRgbToXyz(fit.rgb[0],fit.rgb[1],fit.rgb[2],matrix);
   const sum=xyz.X+xyz.Y+xyz.Z;
   steps.push({ire:Math.round(xyz.Y*100),
    r:meterEncodeColorCheckerLinear(fit.rgb[0]),g:meterEncodeColorCheckerLinear(fit.rgb[1]),b:meterEncodeColorCheckerLinear(fit.rgb[2]),
    name:'1a '+name+' '+(n+1)+(fit.outOfGamut?' (out of gamut)':''),
    target_x:sum>0?xyz.X/sum:.3127,target_y:sum>0?xyz.Y/sum:.329,target_Yn:xyz.Y,
    input_max:inputMax,series_mode:'mb-osa-ucs-'+String(((typeof meterChartSignalMode==='function')?meterChartSignalMode():'sdr')||'sdr').toLowerCase(),mb_region:name,
    mb_target_l:mb.l,mb_target_s:mb.s,mb_target_lm:meterMbLuminanceFromXyz(xyz,ten),
    mb_paper_l:pt.l,mb_paper_s:pt.s,
    out_of_gamut:fit.outOfGamut});
  }
 });
 return steps;
}

function meterBuildMbHueCircleSteps(){
 const gamut=meterAnalysisGamut(),matrix=gamut.rgbToXyz;
 const ten=/_10$/.test(String(meterChromaticityChartMode()||'ciemb_2'));
 const nativeFactors=ten?CIE_MB_NATIVE_FACTORS_10:CIE_MB_NATIVE_FACTORS_2;
 const displayFactors=ten?CIE_MB_FACTORS_10:CIE_MB_FACTORS_2;
 const lmsMatrix=ten?CIE2015_TO_LMS_10:CIE2015_TO_LMS_2;
 const inputMax=(typeof meterPatchInputMax==='function')?meterPatchInputMax():255;
 const center=[.5,.5,.5],yr=matrix[1][0],yg=matrix[1][1],yb=matrix[1][2];
 const basisA=[1,-yr/Math.max(1e-9,yg),0];
 const rg=Math.max(1e-9,yr+yg),basisB=[-yb/rg,-yb/rg,1];
 const xyzFor=rgb=>linRgbToXyz(rgb[0],rgb[1],rgb[2],matrix);
 const mbFor=(rgb,factors,relativeL)=>{
  const lms=meterCieApplyMatrix(xyzFor(rgb),lmsMatrix);
  const L=factors[0]*lms.X,M=factors[1]*lms.Y,S=factors[2]*lms.Z,lm=L+M;
  const l=L/lm;
  return {x:relativeL?meterCieMbRelativeL(l,ten):l,y:S/lm,lm:lm};
 };
 // The 2754/4099 sensitivity scaling is defined in native MB coordinates,
 // before the displayed S axis is expanded to equal-energy = 1.
 const nativeFor=rgb=>mbFor(rgb,nativeFactors,false);
 const displayFor=rgb=>mbFor(rgb,displayFactors,true);
 const c=nativeFor(center);
 const addVec=(base,vec)=>base.map((value,i)=>value+vec[i]);
 const a=nativeFor(addVec(center,basisA)),b=nativeFor(addVec(center,basisB));
 const d00=a.x-c.x,d01=b.x-c.x,d10=a.y-c.y,d11=b.y-c.y;
 const det=d00*d11-d01*d10;
 if(Math.abs(det)<1e-12) return [];
 const vectors=[];
 for(let angle=0;angle<360;angle+=10){
  const rad=angle*Math.PI/180,dx=50*Math.cos(rad)/2754,dy=50*Math.sin(rad)/4099;
  const alpha=(dx*d11-d01*dy)/det,beta=(d00*dy-dx*d10)/det;
  vectors.push({angle:angle,delta:basisA.map((value,i)=>value*alpha+basisB[i]*beta)});
 }
 let scale=1;
 vectors.forEach(item=>item.delta.forEach(delta=>{
  if(Math.abs(delta)>1e-9) scale=Math.min(scale,.48/Math.abs(delta));
 }));
 const makeStep=(name,rgb,angle)=>{
  const xyz=xyzFor(rgb),sum=xyz.X+xyz.Y+xyz.Z,mb=displayFor(rgb);
  return {ire:Math.round(xyz.Y*100),r:meterEncodeColorCheckerLinear(rgb[0]),g:meterEncodeColorCheckerLinear(rgb[1]),b:meterEncodeColorCheckerLinear(rgb[2]),
   name:name,target_x:sum>0?xyz.X/sum:.3127,target_y:sum>0?xyz.Y/sum:.329,target_Yn:xyz.Y,input_max:inputMax,
   series_mode:'mb-hue-circle-'+String(((typeof meterChartSignalMode==='function')?meterChartSignalMode():'sdr')||'sdr').toLowerCase(),
   mb_hue_angle:angle,mb_target_l:mb.x,mb_target_s:mb.y,mb_target_lm:mb.lm};
 };
 const steps=[makeStep('MB Neutral',center,null)];
 vectors.forEach(item=>steps.push(makeStep('MB Hue '+item.angle+'\u00b0',center.map((value,i)=>Math.max(0,Math.min(1,value+scale*item.delta[i]))),item.angle)));
 return steps;
}

function meterBuildBuiltinColorCheckerSteps(series){
 const preset=String((series&&series.preset)||'');
 if(preset==='classic-24') return meterBuildColorCheckerStepsJS(false);
 if(preset==='hcfr-gcd-24') return meterBuildHcfrColorCheckerStepsJS(false);
 if(preset==='sg-96') return meterBuildFixedVideoCodeColorSteps(
  meterBuiltinFixedLegal8Rows(METER_COLORCHECKER_SG_NAMES,METER_COLORCHECKER_SG_LEGAL8),'colorchecker-sg');
 if(preset==='sg-skin-19') return meterBuildFixedVideoCodeColorSteps(
  meterBuiltinFixedLegal8Rows(METER_COLORCHECKER_SG_SKIN_NAMES,METER_COLORCHECKER_SG_SKIN_LEGAL8),'colorchecker-sg-skin');
 if(preset==='mb-hue-circle-37') return meterBuildMbHueCircleSteps();
 if(preset==='mb-focal-8') return meterBuildMbFocalColourSteps();
 if(preset==='mb-osa-ucs-64') return meterBuildMbOsaUcsMapSteps();
 return [];
}

// Built-in cube lattices pick node spacing from the CURRENT signal mode:
// SDR stays signal-uniform (the display gamma already spreads decoded light),
// HDR switches to light-uniform PQ spacing up to the mastering peak so the
// same patch count fills the chroma interior instead of crowding the gamut
// edge (see the spacing note in meterLatticeSanitizeParams). Returns a copy —
// the METER_BUILTIN_CUBE_SERIES constants stay untouched.
function meterBuiltinCubeSeriesForMode(builtin){
 if(!builtin||(builtin.kind!=='lattice'&&builtin.kind!=='hybrid')) return builtin;
 if(builtin.kind==='hybrid'){
  // Hybrid volume half follows lattice spacing rules; skeleton levels stay as-is.
  const modeKey=(typeof meterCustomSeriesModeKey==='function')?meterCustomSeriesModeKey():'sdr';
  const hdr=(modeKey==='hdr');
  const peak=Number((typeof getVal==='function'?getVal('max_luma'):0)||0)||1000;
  const params=Object.assign({},builtin.params,
   hdr?{spacing:'light',pq:true,peak_nits:peak}:{spacing:'signal',pq:false});
  return Object.assign({},builtin,{params:params});
 }
 const modeKey=(typeof meterCustomSeriesModeKey==='function')?meterCustomSeriesModeKey():'sdr';
 const hdr=(modeKey==='hdr');
 const peak=Number((typeof getVal==='function'?getVal('max_luma'):0)||0)||1000;
 const params=Object.assign({},builtin.params,
  hdr?{spacing:'light',pq:true,peak_nits:peak}:{spacing:'signal',pq:false});
 return Object.assign({},builtin,{params:params});
}

function meterCustomSeriesById(id){
 const numeric=Math.round(Number(id));
 if(Number.isFinite(numeric)&&typeof METER_BUILTIN_COLORCHECKER_SERIES!=='undefined'){
  const verification=METER_BUILTIN_COLORCHECKER_SERIES.find(s=>s.id===numeric)||null;
  if(verification) return verification;
 }
 if(Number.isFinite(numeric)&&numeric>=900&&numeric<1000){
  let builtin=METER_BUILTIN_CUBE_SERIES.find(s=>s.id===numeric)||null;
  if(!builtin&&typeof METER_BUILTIN_3D_PROFILE_SERIES!=='undefined')
   builtin=METER_BUILTIN_3D_PROFILE_SERIES.find(s=>s.id===numeric)||null;
  if(builtin&&typeof meterBuiltinCubeSeriesForMode==='function') return meterBuiltinCubeSeriesForMode(builtin);
  return builtin;
 }
 if(!Number.isFinite(numeric)||numeric<1001) return null;
 meterCustomSeriesCurrentState();
 return meterCustomSeriesIndex.get(numeric)||null;
}

function meterCustomSeriesForMode(category,mode){
 const state=meterCustomSeriesCurrentState();
 const modeKey=meterCustomSeriesModeKey(mode);
 const cat=(category==='color')?'color':'greyscale';
 // Only series that render correctly for the current output range are offered
 // (untagged/lattice series match any range). Keeps the read-side dropdowns
 // from listing a Limited grid while the display is outputting Full, etc.
 return state.series.filter(s=>s.mode===modeKey&&s.category===cat&&meterSeriesMatchesCurrentRange(s));
}

function meterActiveSeriesIsCustom(){
 return !!meterCustomSeriesById(meterActiveSeriesPoints);
}

// ---- Parameter-defined lattice series ----
// A kind:'lattice' series stores only generator params; patches are expanded
// deterministically here AND in the server's webui_lattice_series_steps_from_body.
// Any change to this algorithm must be mirrored there (locked by shared fixtures
// in tests/lattice-expansion-regression.js + tests/lattice-server-steps-regression.pl).
function meterLatticeGcd(a,b){ while(b){ const t=a%b; a=b; b=t; } return a; }

function meterLatticeSpreadOrder(count){
 const total=Math.max(0,Math.round(Number(count)||0));
 if(total===0) return [];
 if(total===1) return [0];
 let stride=Math.floor(total*0.618034);
 if(stride<1) stride=1;
 while(meterLatticeGcd(stride,total)!==1) stride++;
 const out=[];
 let idx=0;
 for(let k=0;k<total;k++){ out.push(idx); idx=(idx+stride)%total; }
 return out;
}

function meterLatticeSanitizeParams(raw){
 const src=(raw&&typeof raw==='object')?raw:{};
 const num=(v,def,min,max)=>{ const n=Math.round(Number(v)); return Number.isFinite(n)?Math.max(min,Math.min(max,n)):def; };
 let grey=num(src.grey_points,0,0,101);
 if(grey<2) grey=0;
 let threshold=Number(src.threshold_pct);
 if(!Number.isFinite(threshold)) threshold=0;
 threshold=Math.max(0,Math.min(50,threshold));
 return {
  size:num(src.size,9,3,50),
  grey_points:grey,
  threshold_pct:threshold,
  order:(src.order==='grid')?'grid':'spread',
  reverse:!!src.reverse,
  // Node spacing: 'signal' = uniform code steps (classic). 'light' = uniform
  // DECODED-light steps up to peak_nits, normalized so the corners still hit
  // 100% signal. In PQ, signal-uniform mixes decode to near-primary light
  // ratios (75/50/25 ≈ 380:35:1) and crowd the gamut edge — light-uniform
  // spacing fills the chroma interior with the same patch count.
  spacing:(src.spacing==='light')?'light':'signal',
  peak_nits:num(src.peak_nits,1000,100,10000),
  // Baked at generation time from the series' signal mode: light spacing uses
  // the PQ encode for HDR lattices, a 2.4 power law for SDR ones.
  pq:!!src.pq
 };
}

// Per-axis node fractions for a lattice. Self-contained math (no chart-state
// dependencies) — MUST stay algorithm-identical to the server expansion in
// webui_lattice_series_steps_from_body (parity-locked).
function meterLatticeAxisFracs(N,params){
 const div=N-1;
 const out=[];
 const light=!!(params&&params.spacing==='light');
 const pqe=(L)=>{ const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128; const y=Math.max(0,L)/10000; const p=Math.pow(y,m1); return Math.pow((c1+c2*p)/(1+c3*p),m2); };
 const peak=(params&&params.peak_nits)||1000;
 const top=pqe(peak);
 for(let i=0;i<N;i++){
  const t=i/div;
  if(!light){ out.push(t); continue; }
  // Endpoints pinned EXACTLY: pqe(0) is ~7e-7, not 0, and a black frac of
  // 9.7e-7 breaks the frac-exact corner detection (corners-first ordering,
  // display-referenced ceilings) even though the percent name rounds to 0.
  if(i===0){ out.push(0); continue; }
  if(i===div){ out.push(1); continue; }
  if(params.pq){ out.push(top>0?(pqe(t*peak)/top):t); }
  else { out.push(Math.pow(t,1/2.4)); }
 }
 return out;
}

function meterLatticePct(f){
 const v=Math.round(f*1000)/10;
 return String(v);
}

function meterLatticeKeepNode(fr,fg,fb,thresholdPct){
 if(!(thresholdPct>0)) return true;
 return (0.2126*fr+0.7152*fg+0.0722*fb)*100>=thresholdPct;
}

function meterLatticeExpandPatches(rawParams){
 const params=meterLatticeSanitizeParams(rawParams);
 const N=params.size;
 const div=N-1;
 const makePatch=(name,fr,fg,fb)=>({
  name:name,frac_r:fr,frac_g:fg,frac_b:fb,
  r8:Math.round(fr*255),g8:Math.round(fg*255),b8:Math.round(fb*255),
  r10:Math.round(fr*1023),g10:Math.round(fg*1023),b10:Math.round(fb*1023),
  target_nits:null
 });
 const patches=[];
 if(params.grey_points>=2){
  const G=params.grey_points;
  patches.push(makePatch('G 100%',1,1,1));
  for(let i=0;i<G;i++){
   const f=i/(G-1);
   if(f>=1) continue;
   patches.push(makePatch('G '+meterLatticePct(f)+'%',f,f,f));
  }
 }
 const nodes=[];
 const axisFracs=meterLatticeAxisFracs(N,params);
 for(let ri=0;ri<N;ri++) for(let gi=0;gi<N;gi++) for(let bi=0;bi<N;bi++){
  const fr=axisFracs[ri],fg=axisFracs[gi],fb=axisFracs[bi];
  if(!meterLatticeKeepNode(fr,fg,fb,params.threshold_pct)) continue;
  nodes.push(makePatch(meterLatticePct(fr)+'/'+meterLatticePct(fg)+'/'+meterLatticePct(fb),fr,fg,fb));
 }
 let ordered=nodes;
 if(params.order==='spread') ordered=meterLatticeSpreadOrder(nodes.length).map(i=>nodes[i]);
 if(params.reverse) ordered=ordered.slice().reverse();
 // Reference corners first: W, R, G, B (then K when present) lead the run so
 // the display-referenced chart targets (measured white peak + additive
 // per-channel ceilings from the cube's own corners) are live from the first
 // handful of patches instead of engaging only when the spread order happens
 // to reach them. MUST stay algorithm-identical to the server expansion in
 // webui_lattice_series_steps_from_body (parity-locked by the lattice tests).
 const latticeCornerRank=(p)=>{
  const one=v=>v>=1, zero=v=>v<=0;
  if(one(p.frac_r)&&one(p.frac_g)&&one(p.frac_b)) return 0;
  if(one(p.frac_r)&&zero(p.frac_g)&&zero(p.frac_b)) return 1;
  if(zero(p.frac_r)&&one(p.frac_g)&&zero(p.frac_b)) return 2;
  if(zero(p.frac_r)&&zero(p.frac_g)&&one(p.frac_b)) return 3;
  if(zero(p.frac_r)&&zero(p.frac_g)&&zero(p.frac_b)) return 4;
  return -1;
 };
 const cornerLead=ordered.filter(p=>latticeCornerRank(p)>=0).sort((a,b)=>latticeCornerRank(a)-latticeCornerRank(b));
 if(cornerLead.length) ordered=[...cornerLead,...ordered.filter(p=>latticeCornerRank(p)<0)];
 patches.push(...ordered);
 return patches;
}

function meterLatticeCountForParams(rawParams){
 const params=meterLatticeSanitizeParams(rawParams);
 const N=params.size;
 let count=(params.grey_points>=2)?params.grey_points:0;
 const axisFracs=meterLatticeAxisFracs(N,params);
 for(let ri=0;ri<N;ri++) for(let gi=0;gi<N;gi++) for(let bi=0;bi<N;bi++){
  if(meterLatticeKeepNode(axisFracs[ri],axisFracs[gi],axisFracs[bi],params.threshold_pct)) count++;
 }
 return count;
}

// Default multi-level WRGB skeleton levels (percent). Matches worker skeleton_levels.
function meterSkeletonDefaultLevels(){
 return [0,5,10,20,30,40,50,60,70,80,90,100];
}

function meterSkeletonSanitizeParams(raw){
 const src=(raw&&typeof raw==='object')?raw:{};
 let levels=Array.isArray(src.levels)?src.levels.map(v=>Math.round(Number(v))).filter(n=>Number.isFinite(n)&&n>=0&&n<=100):meterSkeletonDefaultLevels();
 if(!levels.length) levels=meterSkeletonDefaultLevels();
 // unique sorted
 levels=Array.from(new Set(levels)).sort((a,b)=>a-b);
 return {levels:levels};
}

function meterSkeletonExpandPatches(rawParams){
 const params=meterSkeletonSanitizeParams(rawParams);
 const makePatch=(name,fr,fg,fb)=>({
  name:name,frac_r:fr,frac_g:fg,frac_b:fb,
  r8:Math.round(fr*255),g8:Math.round(fg*255),b8:Math.round(fb*255),
  r10:Math.round(fr*1023),g10:Math.round(fg*1023),b10:Math.round(fb*1023),
  target_nits:null
 });
 const pct=f=>meterLatticePct(f);
 const patches=[];
 const seen=new Set();
 const push=(fr,fg,fb)=>{
  const name=pct(fr)+'/'+pct(fg)+'/'+pct(fb);
  if(seen.has(name)) return;
  seen.add(name);
  patches.push(makePatch(name,fr,fg,fb));
 };
 push(0,0,0);
 for(const L of params.levels){
  if(!(L>0)) continue;
  const f=L/100;
  push(f,f,f); // white at level
  push(f,0,0); // red
  push(0,f,0); // green
  push(0,0,f); // blue
 }
 return patches;
}

function meterSkeletonCountForParams(rawParams){
 return meterSkeletonExpandPatches(rawParams).length;
}

// Hybrid = skeleton edges + lattice volume (dedupe by name). Skeleton leads so
// multi-level WRGB is measured first; volume interiors follow.
function meterHybridExpandPatches(rawParams){
 const src=(rawParams&&typeof rawParams==='object')?rawParams:{};
 const sk=meterSkeletonExpandPatches(src);
 const lat=meterLatticeExpandPatches(src);
 const seen=new Set(sk.map(p=>p.name));
 const out=sk.slice();
 for(const p of lat){
  if(!p||!p.name||seen.has(p.name)) continue;
  seen.add(p.name);
  out.push(p);
 }
 return out;
}

function meterHybridCountForParams(rawParams){
 return meterHybridExpandPatches(rawParams).length;
}

function meterCustomSeriesPatches(series){
 if(!series) return [];
 if(series.kind==='lattice') return meterLatticeExpandPatches(series.params);
 if(series.kind==='skeleton') return meterSkeletonExpandPatches(series.params);
 if(series.kind==='hybrid') return meterHybridExpandPatches(series.params);
 return Array.isArray(series.patches)?series.patches:[];
}

function meterProfilingSeriesPatchCount(series){
 if(!series) return 0;
 try{
  if(series.kind==='lattice') return meterLatticeCountForParams(series.params);
  if(series.kind==='skeleton') return meterSkeletonCountForParams(series.params);
  if(series.kind==='hybrid') return meterHybridCountForParams(series.params);
  return Array.isArray(series.patches)?series.patches.length:0;
 }catch(e){ return 0; }
}

function meterLatticeWireRange(){
 const tenBit=meterPatchBitDepth()===10;
 const limited=(typeof meterPatchUsesVideoRange==='function')&&meterPatchUsesVideoRange();
 if(tenBit) return limited?{min:64,span:876,max:1023}:{min:0,span:1023,max:1023};
 return limited?{min:16,span:219,max:255}:{min:0,span:255,max:255};
}

let meterCustomSeriesReturnToManager=false;
// True once THIS session has created/edited/deleted a custom series. Guards
// the settings save: a tab that loaded while the blob was empty must not post
// its stale empty state over data a newer tab saved (the server preserves the
// stored blob when the key is omitted). Deletions set this flag, so wiping
// the last series still persists.
let meterCustomSeriesDirty=false;

// Refresh the custom-series blob from the Pi so series created in ANOTHER
// browser/computer appear without a reload. Local unsaved edits win (dirty
// state skips the refresh; it posts on the next save instead).
async function meterFetchCustomSeriesSnapshot(){
 const payload=await fetchJSON('/api/meter/custom-series?_='+Date.now(),{_quiet:true,_timeoutMs:30000,cache:'no-store'});
 if(!payload||payload.status!=='ok'||typeof payload.state_json!=='string') return null;
 try{
  const state=JSON.parse(payload.state_json);
  if(!state||!Array.isArray(state.series)) return null;
  return {status:'ok',revision:String(payload.revision||''),state:state,rawJson:payload.state_json};
 }catch(e){ return null; }
}

async function meterRefreshCustomSeriesFromServer(){
 if(meterCustomSeriesDirty) return false;
 let meta=null;
 try{ meta=await fetchJSON('/api/meter/custom-series?meta=1&_='+Date.now(),{_quiet:true,_timeoutMs:5000,cache:'no-store'}); }catch(e){ return false; }
 if(!meta||meta.status!=='ok') return false;
 if(meterCustomSeriesRevision&&String(meta.revision||'')===meterCustomSeriesRevision) return false;
 try{
  const payload=await meterFetchCustomSeriesSnapshot();
  if(!payload) return false;
  meterCustomSeriesState=payload.state;
  meterCustomSeriesRawJson=payload.rawJson;
  meterCustomSeriesRevision=String(payload.revision||'');
  meterCustomSeriesNormalizeState();
  meterRenderCustomSeriesButtons();
  return true;
 }catch(e){}
 return false;
}

let meterCustomSeriesManagerCategory='greyscale';
function meterCustomSeriesManagerCategoryLabel(category){
 return category==='3dlut'?'3D LUT':(category==='color'?'Color':'Greyscale');
}
function meterCustomSeriesMatchesManagerCategory(series){
 if(!series) return false;
 if(meterCustomSeriesManagerCategory==='3dlut') return series.kind==='lattice';
 if(meterCustomSeriesManagerCategory==='color') return series.category==='color'&&series.kind!=='lattice';
 return series.category!=='color'&&series.kind!=='lattice';
}
async function meterOpenCustomSeriesManager(category){
 if(category==='greyscale'||category==='color'||category==='3dlut') meterCustomSeriesManagerCategory=category;
 const modal=meterEnsureModalOnBody(document.getElementById('meterCustomSeriesManagerModal'));
 if(!modal) return;
 const status=document.getElementById('meterCustomSeriesManagerStatus');
 if(status){ status.textContent=''; status.style.display='none'; }
 meterCustomSeriesReturnToManager=false;
 const showAllEl=document.getElementById('meterCustomSeriesManagerShowAll');
 if(showAllEl) showAllEl.checked=meterCustomSeriesManagerShowAll;
 const categoryLabel=meterCustomSeriesManagerCategoryLabel(meterCustomSeriesManagerCategory);
 const title=document.getElementById('meterCustomSeriesManagerTitle');
 if(title) title.textContent=categoryLabel+' Custom Series';
 const setVisible=(id,on)=>{const el=document.getElementById(id);if(el)el.style.display=on?'':'none';};
 setVisible('meterCustomSeriesNewGrey',meterCustomSeriesManagerCategory==='greyscale');
 setVisible('meterCustomSeriesNewColor',meterCustomSeriesManagerCategory==='color');
 setVisible('meterCustomSeriesNew3dLut',meterCustomSeriesManagerCategory==='3dlut');
 setVisible('meterCustomSeriesImport',meterCustomSeriesManagerCategory!=='3dlut');
 meterRenderCustomSeriesManager();
 modal.style.display='flex';
 uiSyncBodyScrollLock();
 // Refresh from the Pi in the background and re-render if anything changed.
 try{ if(await meterRefreshCustomSeriesFromServer()) meterRenderCustomSeriesManager(); }catch(e){}
}

function meterCloseCustomSeriesManager(){
 const modal=document.getElementById('meterCustomSeriesManagerModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

function meterOpenLutTools(){
 const modal=document.getElementById('meterLutToolsModal');
 if(!modal) return;
 if(document.body.classList.contains('layout-desktop')){
  // LUT Tools is embedded in the dedicated desktop workspace.  Merely
  // changing the old modal display property leaves it hidden when invoked
  // from the solve-complete dialog on another workspace.
  pgSelectDesktopWorkspace('3d-lut',{focus:true});
 }
 if(typeof meterLoadSolvedLutList==='function') meterLoadSolvedLutList();
 modal.style.display='flex';
 uiSyncBodyScrollLock();
}

function meterCloseLutTools(){
 const modal=document.getElementById('meterLutToolsModal');
 if(modal) modal.style.display='none';
 uiSyncBodyScrollLock();
}

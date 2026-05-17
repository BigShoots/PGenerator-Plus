const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const lgSource = fs.readFileSync('usr/sbin/pgenerator-lg', 'utf8');
const lgWebSource = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');
const autocalWorkerSource = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');
const lg3dWorkerSource = fs.readFileSync('usr/bin/meter_lg_3d_autocal.pl', 'utf8');
const meterSessionSource = fs.readFileSync('usr/bin/meter_session.sh', 'utf8');
const meterSeriesSource = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');
const autoCalDdcResetStart = source.indexOf('async function meterAutoCalResetDdc()');
const autoCalDdcResetEnd = source.indexOf('async function meterAutoCalRunPreflightReset()', autoCalDdcResetStart);
const autoCalDdcResetSource = autoCalDdcResetStart >= 0 && autoCalDdcResetEnd > autoCalDdcResetStart
  ? source.slice(autoCalDdcResetStart, autoCalDdcResetEnd)
  : '';
const fullAutoCalTouchupStart = source.indexOf('async function meterFullAutoCalStartTouchup');
const fullAutoCalTouchupEnd = source.indexOf('async function meterStartAutoCal', fullAutoCalTouchupStart);
const fullAutoCalTouchupSource = fullAutoCalTouchupStart >= 0 && fullAutoCalTouchupEnd > fullAutoCalTouchupStart
  ? source.slice(fullAutoCalTouchupStart, fullAutoCalTouchupEnd)
  : '';
const fullAutoCalStartStart = source.indexOf('async function meterStartFullAutoCal');
const fullAutoCalStartEnd = source.indexOf('async function meterFullAutoCalStart3d', fullAutoCalStartStart);
const fullAutoCalStartSource = fullAutoCalStartStart >= 0 && fullAutoCalStartEnd > fullAutoCalStartStart
  ? source.slice(fullAutoCalStartStart, fullAutoCalStartEnd)
  : '';
const autoCalLuminanceStart = source.indexOf('async function meterAutoCalLuminanceSetupLoop');
const autoCalLuminanceEnd = source.indexOf('function meterAutoCalCurrentKeyFromStatus', autoCalLuminanceStart);
const autoCalLuminanceSource = autoCalLuminanceStart >= 0 && autoCalLuminanceEnd > autoCalLuminanceStart
  ? source.slice(autoCalLuminanceStart, autoCalLuminanceEnd)
  : '';

assert(
  !source.includes('int($level*255/219+.5)'),
  'server greyscale full-range path must not re-scale from a rounded legal-range code'
);
assert(
  source.includes('int($stimulus_pct/100*255 + .5)'),
  'server greyscale full-range path should use direct 0-255 rounding'
);
assert(
  source.includes('$patch_input_max <= 255 && ($patch_r > 255 || $patch_g > 255 || $patch_b > 255)') &&
    source.includes('$patch_input_max=$patch_target_max;') &&
    source.includes('$input_max=$target_max if($input_max <= 255 && ($pr > 255 || $pg > 255 || $pb > 255));'),
  '10-bit greyscale patches must not be clamped and re-expanded as 8-bit patches when input_max is missing or wrong'
);
assert(
  meterSeriesSource.includes('find_greyscale_white_step_index') &&
    meterSeriesSource.includes('build_series_read_order') &&
    meterSeriesSource.includes('READ_ORDER+=("$white_index")') &&
    meterSeriesSource.includes('for i in "${READ_ORDER[@]}"; do') &&
    meterSeriesSource.includes('STEP_NUM=$((READING_COUNT + 1))') &&
    meterSeriesSource.includes('if [[ "$PATCH_INSERT" == "1" ]] && (( READING_COUNT > 0 )); then') &&
    meterSeriesSource.includes('WHITE_STEP_INDEX=$(find_greyscale_white_step_index || true)'),
  'Greyscale series worker should enforce target-white first and refresh the actual white step'
);
assert(
  meterSeriesSource.includes('build_step_reading_json()') &&
    meterSeriesSource.includes('STEP_TARGET_X="$target_x" STEP_TARGET_Y="$target_y" STEP_TARGET_YN="$target_Yn"') &&
    meterSeriesSource.includes("('target_x','STEP_TARGET_X'),('target_y','STEP_TARGET_Y'),('target_Yn','STEP_TARGET_YN')") &&
    meterSeriesSource.includes("('series_color','STEP_SERIES_COLOR'),('series_type','STEP_SERIES_TYPE'),('series_mode','STEP_SERIES_MODE')") &&
    meterSeriesSource.includes('FIRST_READING=$(build_step_reading_json "$WHITE_READING" 0 || echo "")') &&
    meterSeriesSource.includes('READING=$(build_step_reading_json "$PARSED" "$i")') &&
    meterSeriesSource.includes('REFRESH_READING=$(build_step_reading_json "$PARSED" "$WHITE_STEP_INDEX")'),
  'Series worker should stamp target metadata into backend readings so color/sat luminance-error targets survive polling, reports, and refreshes'
);
assert(
  source.includes('function meterBuildSaturationTargetStepMeta') &&
    source.includes('const target=meterBuildSaturationTargetStepMeta(colorName,100);') &&
    source.includes("name:name+' '+sat+'%',series_color:name,sat_pct:sat,...meterBuildSaturationTargetStepMeta(name,sat)") &&
    source.includes('\\"name\\":\\"White\\",\\"target_x\\":$target_wx,\\"target_y\\":$target_wy,\\"target_Yn\\":1') &&
    source.includes('\\"series_color\\":\\"$series_color\\",\\"sat_pct\\":100,\\"target_x\\":$target_x,\\"target_y\\":$target_y,\\"target_Yn\\":$target_Yn_for_step') &&
    source.includes('\\"series_color\\":\\"$name\\",\\"sat_pct\\":$sat,\\"target_x\\":$tx,\\"target_y\\":$ty,\\"target_Yn\\":$target_Yn_for_step'),
  'Saturation and ColorChecker series steps should carry explicit target xy/Y metadata for luminance-error Delta E'
);
assert(
  meterSeriesSource.includes("local num_re='^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$'") &&
    (meterSeriesSource.match(/PARSED=\$\(parse_latest_result\)/g) || []).length >= 3 &&
    meterSeriesSource.includes('parsed_len=${#PARSED}') &&
    meterSeriesSource.includes('reading_is_invalid_low_light()') &&
    meterSeriesSource.includes('(v + 0) <= 20.0001') &&
    meterSeriesSource.includes('MAX_READ_ATTEMPTS=3') &&
    meterSeriesSource.includes('low-light invalid read retry') &&
    meterSeriesSource.includes('WHITE_READING_JSON="$WHITE_READING"') &&
    meterSeriesSource.includes('READ_ATTEMPT="$attempt" MAX_READ_ATTEMPTS="$max_attempts"') &&
    meterSeriesSource.includes("attempt=int(os.environ.get('READ_ATTEMPT','1') or 1)") &&
    meterSeriesSource.includes('expected=white_y*(stim**2.4)') &&
    meterSeriesSource.includes('max_reasonable=max(expected*1.8, expected+0.10)') &&
    meterSeriesSource.includes('max_reasonable=max(expected*1.25, expected+0.35)') &&
    meterSeriesSource.includes('if y > max_reasonable and attempt < max_attempts:') &&
    meterSeriesSource.includes('WHITE_READING="$READING"') &&
    meterSeriesSource.includes('wait_for_read_prompt()') &&
    meterSeriesSource.includes('trigger_spotread_read()') &&
    meterSeriesSource.includes('prompt wait timeout') &&
    meterSeriesSource.includes('NEXT_PROMPT_MIN=$((cur + 1))') &&
    meterSeriesSource.includes('EMISSIVE_BLACK_NO_READ=1') &&
    meterSeriesSource.includes('if [[ "$EMISSIVE_BLACK_NO_READ" == "1" && "$R" == "$G" && "$G" == "$B" ]] && float_le "$IRE" 0; then'),
  'Meter series worker should wait for a complete parsed XYZ/Yxy result, wait for spotread readiness before triggering reads, skip emissive black timeouts, and retry bogus low-light samples before accepting a spotread count increase'
);
assert(
  source.includes("title.textContent='Calibration';") &&
    source.includes('id="meterHdrDiffuseWhiteWrap"') &&
    source.includes('function meterDisplayTypeIsProjector') &&
    source.includes('if(!meterDisplayTypeIsProjector()) return null;') &&
    source.includes('meterUpdateHdrDiffuseWhiteVisibility(v);'),
  'Calibration card title and HDR diffuse-white override should be projector-only'
);
assert(
  source.includes('function meterDisplayTypePatchSizeDefault') &&
    source.includes("if(current.startsWith('oled')||current.startsWith('qdoled')) return '10';") &&
    source.includes("if(current==='lcd'||current.startsWith('lcd_')||current==='projector'||current==='projector_ccss') return '100';") &&
    source.includes('if(opts.patchSizeDefault) meterApplyDisplayTypePatchSizeDefault(v);') &&
    source.includes('meterApplyDisplayTypeSelection(v,{patchSizeDefault:true});') &&
    !source.includes('else meterApplyDisplayTypePatchSizeDefault(getEffectiveDisplayType());') &&
    source.includes('<option value="10" selected>10% Window</option>'),
  'Display type selection should default OLED patch size to 10% and LCD/projector patch size to 100% only when changing profiles'
);
assert(
    source.includes('function meterAutoCalWaitForPanelLightIdle') &&
    source.includes('let meterAutoCalPanelLightReadPending=false;') &&
    source.includes('let meterAutoCalPanelLightWritePending=false;') &&
    source.includes('function meterAutoCalPanelLightQueuedValuePending()') &&
    source.includes("String(meterAutoCalPanelLightQueuedValue).trim()!==''") &&
    source.includes('const hasQueuedValue=meterAutoCalPanelLightQueuedValuePending();') &&
    source.includes('function meterAutoCalSeedPanelLightFromDisplayControl()') &&
    source.includes("if(typeof lgDisplayControlCurrentValue!=='function') return false;") &&
    source.includes('function meterAutoCalSchedulePanelLightCommit(value,immediate)') &&
    source.includes('meterAutoCalPanelLightCommitTimer=setTimeout') &&
    source.includes('meterAutoCalProcessQueuedPanelLight();') &&
    source.includes('function meterAutoCalPanelLightBlocksMeterRead()') &&
    source.includes('function meterAutoCalDdcResetReadbackKeys()') &&
    source.includes('LG controls paused during luminance setup.') &&
    source.includes('if(meterAutoCalLuminanceSetupActive){\n  meterLgGreyLoadToken++;') &&
    source.includes("toast('Wait for the first 100% luminance read.',true);") &&
    autoCalLuminanceSource.includes('meterAutoCalUpdatePanelLightUi();') &&
    autoCalLuminanceSource.includes('meterAutoCalSeedPanelLightFromDisplayControl();') &&
    autoCalLuminanceSource.includes('await meterAutoCalLoadPanelLightValue(true);') &&
    autoCalLuminanceSource.indexOf('await meterAutoCalLoadPanelLightValue(true);') < autoCalLuminanceSource.indexOf('await meterDisplayPatch(whiteStep,{fresh:false});') &&
    !autoCalLuminanceSource.includes('meterAutoCalLoadPanelLightValue(true).catch(()=>{});') &&
    autoCalLuminanceSource.includes('const startedPanelLightWrite=meterAutoCalProcessQueuedPanelLight();') &&
    autoCalLuminanceSource.includes('if(startedPanelLightWrite||meterAutoCalPanelLightBlocksMeterRead())') &&
    autoCalLuminanceSource.includes('Waiting for panel light change to finish before the next meter read') &&
    autoCalLuminanceSource.includes('meterAutoCalSetupReading=rd;') &&
    autoCalLuminanceSource.includes('if(live) live.textContent=') &&
    autoCalLuminanceSource.includes('updateLiveReading(rd);') &&
    !autoCalLuminanceSource.includes('drawAllCharts(sorted)'),
  'AutoCal luminance setup should keep the page responsive and show the live luminance before any chart redraw work'
);
assert(
  source.includes('id="meterFullAutoCalConfirmBox"') &&
    source.includes('id="meterFullAutoCalSkipBtn"') &&
    source.includes('function meterFullAutoCalConfirmDialog(options)') &&
    source.includes('function meterFullAutoCalConfirmDialog(options){\n meterAutoCalClearCompleteAutoClose();') &&
    source.includes('function meterFullAutoCalResolveConfirm(accepted)') &&
    source.includes("meterFullAutoCalResolveConfirm('skip')") &&
    source.includes("'meterFullAutoCalPostReportBtn','meterFullAutoCalSkipReportBtn'") &&
    source.includes('const accepted=await meterFullAutoCalConfirmDialog();') &&
    !source.includes("window.confirm('Full Auto Cal will reset") &&
    !source.includes('then calibrate white, 75%, 50%, 25%') &&
    source.includes('derive the 109% headroom reference, then calibrate the LG 26-point greyscale sequence top/body first and shadows low-to-high') &&
    source.includes('run the current LG 26-point greyscale AutoCal top/body first and shadows low-to-high') &&
    source.includes('This will first switch PGenerator to the AutoCal video transport and measure the current state for the before report') &&
    source.includes('reset the active LG greyscale DDC state and LG 3D LUT baseline'),
  'Full Auto Cal confirmation should use the in-app AutoCal overlay instead of a browser confirm dialog'
);
assert(
    source.includes("meterFullAutoCalPhase='first-greyscale';") &&
    source.includes('const started=await meterStartAutoCal({fullWorkflow:true});') &&
    source.includes("if(!(await meterEnsureLgAutoCalTransport(fullWorkflow?'Full Auto Cal':'LG Greyscale Auto Cal'))) return fail('');") &&
    fullAutoCalStartSource.includes("if(!(await meterEnsureLgAutoCalTransport('Full Auto Cal'))) return;") &&
    fullAutoCalStartSource.includes('if(!meterEnsureLgAutoCalExtendedVideoTransport()) return;') &&
    source.includes('const patternSignalRange=meterLgAutoCalUsesExtendedSdr()?\'1\':meterMeasurementPatchSignalRange();') &&
    source.includes('meterAutoCalPendingConfig={dtype,patternSignalRange,wp,adjustable,whiteStep,fullWorkflow:fullWorkflow};') &&
    source.includes('if(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow){') &&
    source.includes("full_workflow:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?true:undefined") &&
    source.includes("full_autocal_phase:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?'first-greyscale':undefined") &&
    source.includes('full_workflow:fullWorkflow?true:undefined') &&
    source.includes("full_autocal_phase:fullWorkflow?'3d-lut':undefined") &&
    autocalWorkerSource.includes('full_workflow=>$full_workflow ? JSON::PP::true : JSON::PP::false') &&
    autocalWorkerSource.includes('full_autocal_phase=>$full_autocal_phase||undef') &&
    lg3dWorkerSource.includes('full_workflow => $full_workflow ? json_true() : json_false()') &&
    lg3dWorkerSource.includes('full_autocal_phase => $full_autocal_phase||undef') &&
    source.includes('await meterAutoCalResetDdc();') &&
    source.includes('await meterAutoCalReset3dLutBaseline();'),
  'Full Auto Cal should start its first greyscale pass through the normal greyscale AutoCal workflow and full preflight reset'
);
assert(
  source.includes("const METER_FULL_AUTOCAL_COMPLETE_KEY='meterFullAutoCalCompleteToken';") &&
    source.includes('const METER_FULL_AUTOCAL_TOUCHUP_DISABLED=true;') &&
    source.includes('my $_meter_lg_autocal_log_file="/tmp/meter_lg_autocal.log";') &&
    source.includes('my $_meter_lg_3d_autocal_log_file="/tmp/meter_lg_3d_autocal.log";') &&
    source.includes('sub webui_prepare_tmp_worker_log') &&
    source.includes('my $fallback="/tmp/".$prefix."_".time()."_".$$.".log";') &&
    source.includes('webui_prepare_tmp_worker_log($_meter_lg_autocal_log_file,"meter_lg_autocal")') &&
    source.includes('webui_prepare_tmp_worker_log($_meter_lg_3d_autocal_log_file,"meter_lg_3d_autocal")') &&
    source.includes('meterFullAutoCalRunId=meterFullAutoCalNewRunId();') &&
    source.includes('const firstRunId=firstStatus&&(firstStatus.full_autocal_run_id||firstStatus.run_id);') &&
    source.includes('const lutRunId=lutStatus&&(lutStatus.full_autocal_run_id||lutStatus.run_id);') &&
    source.includes('const runId=(touchupStatus&&(touchupStatus.full_autocal_run_id||touchupStatus.run_id))||meterFullAutoCalRunId||meterFullAutoCalNewRunId();') &&
    source.includes('full_autocal_run_id:runId') &&
    source.includes('completed_at:completedAt') &&
    source.includes('touchup_skipped:skipTouchup') &&
    source.includes("Greyscale and 3D LUT complete. Post-3D greyscale touch-up skipped to preserve color alignment.") &&
    source.includes('meterFullAutoCalComplete({') &&
    source.includes('},{skipTouchup:true});') &&
    source.includes('runId:meterFullAutoCalRunId||null') &&
    source.includes("}else if(meterFullAutoCalPhase==='precal-report'||meterFullAutoCalPhase==='postcal-report')") &&
    source.includes('meterSeriesRunning=true;') &&
    !source.includes("meterFullAutoCalResetState(false);\n  return false;\n }else{") &&
    source.includes("if(runId) return ['run',statusPhase,status.status||'',String(runId),status.completed_at||''].join(':');") &&
    autocalWorkerSource.includes('my $run_id=(ref($config) eq "HASH" && defined($config->{"full_autocal_run_id"})') &&
    autocalWorkerSource.includes('run_id=>$run_id') &&
    autocalWorkerSource.includes('full_autocal_run_id=>$full_workflow ? $run_id : undef') &&
    autocalWorkerSource.includes('$state->{"completed_at"}=int(time()*1000);') &&
    lg3dWorkerSource.includes('my $run_id=(ref($config) eq "HASH" && defined($config->{"full_autocal_run_id"})') &&
    lg3dWorkerSource.includes('run_id => $run_id') &&
    lg3dWorkerSource.includes('full_autocal_run_id => $full_workflow ? $run_id : undef') &&
    lg3dWorkerSource.includes('$state->{"completed_at"}=int(time()*1000);'),
  'Full Auto Cal phase workers should share a run id and expose completed_at so handled completions do not reopen stale popups'
);
assert(
  lg3dWorkerSource.includes('sub upload_generated_lut_verified') &&
    lg3dWorkerSource.includes('sub lg_3d_upload_failure_is_transient') &&
    lg3dWorkerSource.includes('my $attempts=3;') &&
    lg3dWorkerSource.includes('$state->{"upload_verified"}=(ref($upload) eq "HASH" && $upload->{"upload_verified"}) ? json_true() : json_false();') &&
    lg3dWorkerSource.includes('Generated LG 3D LUT was not uploaded and verified') &&
    lg3dWorkerSource.includes('LG 3D LUT upload is required but the upload path did not verify'),
  'Full Auto Cal color phase should retry transient 3D LUT upload failures and stop instead of continuing after an unverified LUT'
);
assert(
  source.includes('const METER_FULL_AUTOCAL_REPORT_SERIES=[') &&
    source.includes("{key:'greyscale-26',type:'greyscale',points:26,label:'Greyscale LG 26pt AutoCal'}") &&
    source.includes("{key:'colors-30',type:'colors',points:30,label:'ColorChecker'}") &&
    source.includes("{key:'saturations-24',type:'saturations',points:24,label:'Sat Sweep'}") &&
    source.includes("title:'Pre-Cal Report Measurements'") &&
    source.includes("continueText:'\\u25B6 Measure Pre-Cal'") &&
    source.includes("skipText:'Skip Pre-Cal'") &&
    source.includes("const skipPreCal=preChoice==='skip';") &&
    source.includes("meterFullAutoCalPhase=skipPreCal?'first-greyscale':'precal-report';") &&
    source.includes('if(!skipPreCal){') &&
    source.includes("const measured=await meterFullAutoCalCaptureReportSet('pre');") &&
    source.includes("meterFullAutoCalPhase='first-greyscale';"),
  'Full Auto Cal should offer an optional full pre-cal greyscale/color/saturation report set before starting calibration'
);
assert(
  source.includes('id="meterFullAutoCalPostReportBtn"') &&
    source.includes('id="meterFullAutoCalSkipReportBtn"') &&
    source.includes('function meterFullAutoCalGeneratePostReport()') &&
    source.includes('function meterFullAutoCalSkipPostReport()') &&
    source.includes('function meterFullAutoCalEnsureCalibrationModeOff(reason)') &&
    source.includes("current_name:'Ending LG calibration mode'") &&
    source.includes("const calibrationOff=await meterFullAutoCalEnsureCalibrationModeOff('post-cal report');") &&
    source.includes('LG calibration mode must be off before post-cal report measurements') &&
    source.includes("meterFullAutoCalCaptureReportSet('post')") &&
    source.includes('meterFullAutoCalDownloadReport(filename)') &&
    source.includes("meterBuildReportDocument(sectionHtml,'PGenerator Full AutoCal Report')") &&
    source.includes("const hasPre=meterFullAutoCalReportSetHasData('pre');") &&
    source.includes("const hasPost=meterFullAutoCalReportSetHasData('post');") &&
    source.includes("if(hasPre) entries.push({title:'Pre-Cal '+item.label,snapshot:data&&data.pre?data.pre[item.key]:null});") &&
    source.includes("if(hasPost||!hasPre) entries.push({title:'Post-Cal '+item.label,snapshot:data&&data.post?data.post[item.key]:null});") &&
    source.includes("Click Generate Post-Cal Report to read Greyscale LG 26pt AutoCal, ColorChecker, and Sat Sweep again and build a before/after report.") &&
    source.includes("Click Generate Post-Cal Report to read Greyscale LG 26pt AutoCal, ColorChecker, and Sat Sweep and build a post-cal report."),
  'Full Auto Cal completion should offer a post-cal read and generate a before/after report through the report builder'
);
assert(
  source.includes('const fullReportSeriesActive=!!(meterFullAutoCalRunning&&meterSeriesRunning&&!meterLg3dAutoCalRunning&&!meterAutoCalRunning);') &&
    source.includes("if(fullReportSeriesActive) meterFullAutoCalAbort('Full Auto Cal stopped',false);"),
  'Full Auto Cal report reads should stop the active series backend before aborting the wizard'
);
assert(
  source.includes("greySel.disabled=false;") &&
    !source.includes("greySel.disabled=!!colorMode") &&
    source.includes("Changes the greyscale ΔE calculation used when greyscale charts are shown"),
  'Greyscale Delta E selector should remain usable even while a color series is selected'
);
assert(
  source.includes("const METER_AUTOCAL_STATE_KEY='meterAutoCalState';") &&
    source.includes('function meterAutoCalSaveState()') &&
    source.includes('function meterAutoCalRestoreSavedState()') &&
    source.includes('function meterRestoreAutoCalWorkflows()') &&
    source.includes('meterRestoreAutoCalWorkflows();') &&
    source.includes('function meterFullAutoCalConfirmOverlayActive()') &&
    source.includes('if(meterFullAutoCalConfirmOverlayActive()) return true;') &&
    source.includes('function meterAutoCalInitialRecoveryPoll()') &&
    source.includes('setTimeout(meterAutoCalInitialRecoveryPoll,1200);') &&
    source.includes('const setupOverlayActiveBeforeFetch=meterAutoCalSetupOverlayActive();') &&
    source.includes('if(setupOverlayActiveBeforeFetch&&!fullGreyscaleBackendActive) return;') &&
    source.includes('if(setupOverlayActive&&!fullGreyscaleBackendActive) return;') &&
    source.includes("if(meterAutoCalSetupOverlayActive()&&!full3dPhase) return;") &&
    source.includes("const full3dActive=full3dPhase||meterFullAutoCalEnsureStatusPhase(r,'3d-lut');") &&
    source.includes("if(meterFullAutoCalEnsureStatusPhase(r,'3d-lut'))") &&
    source.includes('function meterFullAutoCalStatusMatchesRun(status)') &&
    source.includes("if(meterFullAutoCalRunId&&statusRunId&&statusRunId!==meterFullAutoCalRunId) return false;") &&
    source.includes('if(r.full_workflow&&!meterFullAutoCalStatusMatchesRun(r)) return;') &&
    source.includes('function meterFullAutoCalEnsureStatusPhase(status,phase)') &&
    source.includes("if(r.status==='complete'&&meterFullAutoCalEnsureStatusPhase(r,'first-greyscale'))") &&
    source.includes("await meterFullAutoCalStart3d(r);") &&
    source.includes("const final=await fetchJSON('/api/meter/read/result',{_quiet:true,_timeoutMs:5000});") &&
    source.includes("const postReportAvailable=!!(showComplete&&status&&status.full_autocal);") &&
    source.includes("function meterFullAutoCalCompletionToken(status)") &&
    source.includes("function meterFullAutoCalMarkCompletionHandled(status)") &&
    source.includes("if(r.status==='complete'&&r.full_workflow&&meterFullAutoCalCompletionHandled(r))") &&
    source.includes("full_autocal_run_id") &&
    source.includes("completed_at"),
  'AutoCal should recover from a sleeping or refreshed browser, ignore stale full-run statuses, and still offer the post-cal report'
);
assert(
  source.includes("pgrep -f '[m]eter_lg_autocal\\\\.pl'") &&
    source.includes("pkill -TERM -f '[m]eter_lg_autocal\\\\.pl'") &&
    source.includes("pkill -9 -f '[m]eter_lg_autocal\\\\.pl'") &&
    source.includes("pgrep -f '[m]eter_lg_3d_autocal\\\\.pl'") &&
    source.includes("pkill -TERM -f '[m]eter_lg_3d_autocal\\\\.pl'") &&
    source.includes("pkill -9 -f '[m]eter_lg_3d_autocal\\\\.pl'") &&
    source.includes('sub webui_meter_lg_autocal_same_run_running') &&
    source.includes('sub webui_meter_lg_3d_autocal_same_run_running') &&
    source.includes('LG Auto Cal already running') &&
    source.includes('LG 3D LUT AutoCal already running'),
  'LG AutoCal process checks should not self-match pgrep/pkill commands and duplicate same-run starts should be idempotent'
);
assert(
  fullAutoCalTouchupSource.includes("meterFullAutoCalPhase='touchup-greyscale';") &&
    fullAutoCalTouchupSource.includes("if(!(await meterEnsureLgAutoCalTransport('Full Auto Cal greyscale touch-up'))) throw new Error('LG Auto Cal transport is not ready');") &&
    fullAutoCalTouchupSource.includes("const patternSignalRange=(meterFullAutoCalConfig&&meterFullAutoCalConfig.patternSignalRange)||(meterLgAutoCalUsesExtendedSdr()?'1':meterMeasurementPatchSignalRange());") &&
    fullAutoCalTouchupSource.includes('meterAutoCalPendingConfig={dtype,patternSignalRange,wp,adjustable,whiteStep,fullWorkflowTouchup:true};') &&
    fullAutoCalTouchupSource.includes('delta_e_formula:deltaEFormula') &&
    fullAutoCalTouchupSource.includes('target_luminance:targetY') &&
    fullAutoCalTouchupSource.includes('setup_luminance_reference:(Number.isFinite(setupY)&&setupY>0)?setupY:undefined') &&
    fullAutoCalTouchupSource.includes('headroom_target_luminance:(Number.isFinite(headroomY)&&headroomY>0)?headroomY:undefined') &&
    fullAutoCalTouchupSource.includes('lg_autocal_26:true') &&
    fullAutoCalTouchupSource.includes('lg_extended_sdr_16_255:meterLgAutoCalUsesExtendedSdr()') &&
    fullAutoCalTouchupSource.includes('force_ddc_white_balance:true') &&
    fullAutoCalTouchupSource.includes('restore_factory_levels:false') &&
    fullAutoCalTouchupSource.includes('reset_ddc_baseline:false') &&
    fullAutoCalTouchupSource.includes('max_iterations:8') &&
    fullAutoCalTouchupSource.includes('headroom_max_iterations:8') &&
    fullAutoCalTouchupSource.includes('max_polish_iterations:4') &&
    fullAutoCalTouchupSource.includes('precision_polish_iterations:6') &&
    fullAutoCalTouchupSource.includes('post_commit_body_polish:true') &&
    fullAutoCalTouchupSource.includes('post_commit_polish:true') &&
    fullAutoCalTouchupSource.includes('post_commit_polish_iterations:3') &&
    fullAutoCalTouchupSource.includes('post_commit_low_shadow_iterations:2') &&
    fullAutoCalTouchupSource.includes('post_commit_true_low_shadow:true') &&
    fullAutoCalTouchupSource.includes('post_commit_low_shadow_committed_iterations:3') &&
    fullAutoCalTouchupSource.includes('post_commit_settle_ms:12000') &&
    fullAutoCalTouchupSource.includes('post_commit_white_resettle_ms:8000') &&
    fullAutoCalTouchupSource.includes('post_commit_low_shadow_settle_ms:2500') &&
    fullAutoCalTouchupSource.includes('post_commit_low_shadow_read_settle_ms:1200') &&
    fullAutoCalTouchupSource.includes('full_autocal_touchup:true') &&
    fullAutoCalTouchupSource.includes('full_workflow:true') &&
    fullAutoCalTouchupSource.includes("full_autocal_phase:'touchup-greyscale'") &&
    fullAutoCalTouchupSource.includes('steps:autocalSteps') &&
    autocalWorkerSource.includes('sub autocal_config_is_touchup') &&
    autocalWorkerSource.includes('return undef if(autocal_config_is_touchup($config));') &&
    autocalWorkerSource.includes('sub config_positive_int') &&
    autocalWorkerSource.includes('sub touchup_delta_skip_reached') &&
    autocalWorkerSource.includes('return 1 if($de <= ($target_delta/6.0));') &&
    autocalWorkerSource.includes('return ($de <= $target_delta) ? 1 : 0;') &&
    autocalWorkerSource.includes('if(touchup_delta_skip_reached($config,$de,$target_delta,$read_step,$lum_pct) && (!$paired_white_step || $pair_target_reached_now->()))') &&
    (autocalWorkerSource.match(/\$state->\{"readings"\}=merge_reading\(\$state->\{"readings"\},\$best_reading\)/g) || []).length >= 2 &&
	    autocalWorkerSource.includes('return 3 if($ire <= 3.1);') &&
	    autocalWorkerSource.includes('return 5 if($ire <= 5.1);') &&
	    autocalWorkerSource.includes('return 1 if($ire <= 3.1);') &&
	    autocalWorkerSource.includes('return 1 if($ire <= 10.0001);'),
  'Full Auto Cal greyscale touch-up should reuse the greyscale AutoCal scoring payload while keeping low-shadow touch-up bounded'
);
assert(
  source.includes("id=\"meterIncludeLumError\" onchange=\"meterOnGreyRefChange('checkbox')\"") &&
    source.includes('if(meterReadingIsGreyscale(reading)) return false;'),
  'Greyscale AutoCal readings should honor the Include luminance error checkbox and stay on the greyscale Delta E path'
);
assert(
  (source.match(/<option value="deitp">ΔE ITP<\/option>/g) || []).length >= 2 &&
    source.includes("deitp:'ΔE ITP'") &&
    source.includes('function deltaEITP') &&
    source.includes("if(form==='deitp' && ctx.X!=null && ctx.Xr!=null) return deltaEITP"),
  'Greyscale and color Delta E selectors should expose and route Delta E ITP'
);
assert(
  autocalWorkerSource.includes('sub delta_e_itp_gamma') &&
    autocalWorkerSource.includes('sub autocal_delta_e') &&
    autocalWorkerSource.includes('sub autocal_delta_e_for_step') &&
    autocalWorkerSource.includes('autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y)') &&
    autocalWorkerSource.includes('our $LG_AUTOCAL_DELTA_E_FORMULA = "deitp";') &&
    autocalWorkerSource.includes('sub normalize_autocal_delta_e_formula {\n return "deitp";\n}') &&
    autocalWorkerSource.includes('delta_e_formula=>$LG_AUTOCAL_DELTA_E_FORMULA') &&
    source.includes("const deltaEFormula='deitp';") &&
    source.includes('delta_e_formula:deltaEFormula'),
  'LG AutoCal should hard-code Delta E ITP for candidate scoring instead of following the chart selector'
);
assert(
  autocalWorkerSource.includes('sub seed_target_from_prior_slot') &&
    !autocalWorkerSource.includes('return 0 if(autocal_step_is_fast_headroom($target));') &&
    autocalWorkerSource.includes('if(target_is_low_shadow_slot($target))') &&
    autocalWorkerSource.includes('@probe_indices=reverse(0..($idx-1)) if($idx > 0);') &&
    autocalWorkerSource.includes('@probe_indices=($idx+1)..(ddc_slot_count()-1) if($idx+1 < ddc_slot_count());') &&
    autocalWorkerSource.includes('return 0 if(target_is_low_shadow_slot($target) && abs(($slots[$source_idx]+0)-($slots[$idx]+0)) > 3.1001);') &&
    autocalWorkerSource.includes('abs(($slots[$source_idx]+0)-($slots[$idx]+0)) > 12'),
  'LG AutoCal should seed body slots from nearby higher slots but seed low-shadow slots only from calibrated lower neighbors'
);
assert(
  source.includes("const savedTargetGamma=(s.target_gamma!=null)?String(s.target_gamma):'';") &&
    source.includes("if(savedTargetGamma!==''){") &&
    source.includes("setVal('meterTargetGamma', savedTargetGamma);") &&
    source.includes('}else{\n  applyMeterTargetGammaDefault();\n }'),
  'Meter settings load should preserve a saved target gamma instead of overwriting it with the default on boot'
);
assert(
  /function meterGreyscaleRotateXLabels\(stepCount\)\s*\{\s*return Number\(stepCount\)>=21;\s*\}/.test(source),
  'Dense greyscale RGB and Delta E chart x-axis labels should use the angled color-series label style'
);
assert(
    lgSource.includes('$LG_DDC_1D_BLACK_SAMPLE=0') &&
    lgSource.includes('@LG_DDC_1D_PATCH_CODES_8BIT=(84,92,100,108,124,152,196,240,284,328,372,416,460,504,544,588,632,676,720,764,808,852,896,932,984,1023)') &&
    lgSource.includes('@LG_DDC_1D_INDEXES=(21,30,38,47,64,94,141,188,235,282,329,375,422,469,512,559,606,653,700,747,794,841,888,926,981,1023)') &&
    lgSource.includes('@LG_DDC_1D_PATCH_INDEXES_8BIT=@LG_DDC_1D_PATCH_CODES_8BIT') &&
    lgSource.includes('&lg_ddc_normalize_rgb_array($settings->{"whiteBalanceRed"}),') &&
    !lgSource.includes('&lg_ddc_coalesce_duplicate_patch_offsets(&lg_ddc_normalize_rgb_array($settings->{"whiteBalanceRed"}))') &&
    !lgSource.includes('$channels[2][6]=$compensated;') &&
    !lgSource.includes('sub lg_ddc_lut_video_10bit_for_ire'),
  'LG DDC 1D LUT bins should use captured raw 26-point patches with normalized TV LUT anchors'
);
assert(
  lgSource.includes('sub lg_ddc_interpolated_offset_at_index'),
  'LG DDC writes should build an interpolated 1D LUT curve rather than broad nearest-point shelves'
);
assert(
  lgSource.includes('&lg_ddc_interpolated_offset_at_index($i,$channels[$channel],$baseline,$channel)'),
  'LG DDC 1D LUT builder should apply the interpolated offset curve'
);
assert(
  lgSource.includes('my ($enable_ok,$enable_message,$enable_responses)=&lg_ddc_enable_1d_pipeline($session,$timeout,$cal_mode);') &&
    !lgSource.includes('command => "1D pipeline", skipped => &json_true(), calibration_mode_active => &json_true()'),
  'LG DDC manual writes should always enable the 1D LUT pipeline before uploading values'
);
assert(
  lgSource.includes('$picture_settings=&lg_ddc_merge_picture_settings($ip,$picture_settings,$generation,$force_ddc_white_balance);') &&
    lgSource.includes('return $picture_settings if(ref($generation) eq "HASH" && !$generation->{"ddc_only_white_balance"} && !$force_ddc_white_balance);') &&
    lgSource.includes('my $native_white_balance=($has_white_balance_write && !$generation->{"ddc_only_white_balance"} && !$force_ddc_white_balance) ? 1 : 0;') &&
    lgSource.includes('my $ddc_white_balance_only=($can_ddc_white_balance && ($generation->{"ddc_only_white_balance"} || $force_ddc_white_balance)) ? 1 : 0;') &&
    lgSource.includes('if($ddc_white_balance_only)') &&
    lgSource.includes('($ddc_attempted,$ddc_result)=&lg_ddc_1d_white_balance_set') &&
    lgSource.includes('if(!$native_white_balance && !$picture_mode_only && $tv_input ne "" && $active_picture_mode ne "")') &&
    source.includes('window.lgStatusState.calibrationMode=!!response.calibration_mode;') &&
    source.includes('function meterAutoCalSyncLgCalibrationMode(status)') &&
    source.includes('meterAutoCalSyncLgCalibrationMode(r);'),
  'C2/newer LG white-balance controls should read/write native TV menu values unless AutoCal explicitly forces DDC'
);
assert(
  lgWebSource.includes('my $calibration_mode_active=($payload->{"calibration_mode_active"}||($ddc_white_balance&&$keep_calibration_mode&&$clients->{"calibration_mode"})) ? 1 : 0;') &&
    source.includes('keep_calibration_mode:true') &&
    source.includes('calibration_mode_active:activeCalibration') &&
    lgSource.includes('if(!$enable_ok && $calibration_mode_active)') &&
    lgSource.includes('ddc_cal_start_late'),
  'LG DDC manual writes should reuse an active calibration-mode hint and recover with CAL_START if the hint is stale'
);
assert(
  !lgSource.includes('BACKLIGHT_UI_DATA'),
  'LG panel-light writes should not use the calibration/DDC backlight endpoint'
);
assert(
  lgSource.includes('$LG_REMOTE_APP_SIGNATURE') &&
    lgSource.includes('hrVRgjCwXVvE2OOSpDZ58hR') &&
    lgSource.includes('appId => "com.lge.test"') &&
    lgSource.includes('"" => "LG Remote App"') &&
    lgSource.includes('created => "20140509"') &&
    lgSource.includes('serial => "2f930e2d2cfe083771f68e4fe7bb07"') &&
    !lgSource.includes('CHgjyv0gsB4sHNSJ2VVHFdk4') &&
    !lgSource.includes('Test Remote App') &&
    !lgSource.includes('use_calibration_identity'),
  'LG registration should use the public LG Remote App signed manifest, not the previous private-looking signature or an opt-in path'
);
assert(
  lgSource.includes('picture_set:panel-light-luna-dim-ok') &&
    lgSource.includes('dimension => { input => $tv_input, pictureMode => $active_picture_mode, "_3dStatus" => "2d" }') &&
    lgSource.includes('get_picture_panel_light_after_${safe_key}_${read_attempt}') &&
    lgSource.includes('for(my $read_attempt=0;$read_attempt<14;$read_attempt++)') &&
    lgSource.includes('LG TV acknowledged the panel-light write but did not return a verified readback.'),
  'LG panel-light writes should use the WebOS Luna picture+dimension path and poll single-key verified readback'
);
assert(
  lgSource.includes('!$picture_mode_only && !$panel_light_only && $active_picture_mode ne "" && !$mode_writable'),
  'LG panel-light writes should not be blocked by white-balance-only picture-mode preflight'
);
assert(
  lgSource.includes('picture_set:scoped-dim-ok') &&
    lgSource.includes('picture_set:scoped-category-ok') &&
    lgSource.includes('picture_set:luna-scoped-dim-ok') &&
    lgSource.includes('picture_set:luna-scoped-category-ok') &&
    lgSource.includes(`$failure_message =~ /(?:doesn'?t support the key|not support|undefined|-1000|Application error)/i`),
  'LG brightness/contrast writes should retry through scoped picture-setting paths when the plain picture category rejects them'
);
assert(
  lgSource.includes('"brightness","contrast","blackLevel","blackLevelAdjust"') &&
    lgSource.includes('reset_keys_succeeded') &&
    lgSource.includes('reset_keys_failed') &&
    lgSource.includes('sub lg_picture_delete_settings_reset') &&
    lgSource.includes('deleteSystemSettings') &&
    lgSource.includes('LG picture mode defaults restored.') &&
    lgSource.includes('sub lg_picture_factory_default_values') &&
    lgSource.includes('getSystemSettingFactoryValue') &&
    lgSource.includes('sub lg_picture_apply_factory_defaults') &&
    lgSource.includes('LG picture mode factory defaults applied.') &&
    lgSource.includes('sub lg_picture_builtin_default_values') &&
    lgSource.includes('LG picture mode core defaults applied.') &&
    lgSource.includes('foreach my $key (@{$keys})') &&
    lgSource.includes('panel_light_reset_ok') &&
    lgSource.includes('get_picture_panel_light_after_reset') &&
    lgSource.includes('sub lg_picture_scoped_categories') &&
    lgSource.includes('picture\\$".$tv_input.".".$active_picture_mode.".2d.".$suffix') &&
    lgSource.includes('needs_picture_mode') &&
    lgSource.includes('push(@panel_payloads,{ path => "com.webos.settingsservice/resetSystemSettings", payload => $payload, luna => 1 })') &&
    !lgSource.includes('$panel_factory_apply_ok,$panel_factory_apply_attempts)=&lg_picture_set_panel_light_values'),
  'LG picture-mode reset should require an explicit mode, try scoped reset categories, and avoid manual factory-value fallback'
);
assert(
  source.includes('function meterAutoCalPanelLightFromPicture(picture)') &&
    source.includes('function meterAutoCalDdcResetReadbackKeys()') &&
    !source.includes('LG kept ') &&
    !source.includes('Adjust TV settings now if needed') &&
    !source.includes('message:meterAutoCalResetNotice+') &&
    autoCalDdcResetSource.includes('/api/lg/picture-settings/set') &&
    autoCalDdcResetSource.includes('reset_ddc_baseline:true') &&
    autoCalDdcResetSource.includes('readback_keys:meterAutoCalDdcResetReadbackKeys()') &&
    !autoCalDdcResetSource.includes('const loadedPanel=await meterAutoCalLoadPanelLightValue(true);') &&
    source.includes('async function meterAutoCalReset3dLutBaseline()') &&
    source.includes("/api/lg/3d-lut/reset") &&
    source.includes('Writing unity 3D LUT baseline before greyscale') &&
    source.includes('if(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)') &&
    source.indexOf('await meterAutoCalResetDdc();') < source.indexOf('await meterAutoCalReset3dLutBaseline();') &&
    !autoCalDdcResetSource.includes('/api/lg/picture-settings/reset'),
  'LG Auto Cal should clear the DDC table, Full Auto Cal should also reset the LG 3D LUT baseline before greyscale, refresh retained panel light silently, and continue to the luminance setup step'
);
assert(
  lgSource.includes('my ($session,$ip,$picture_mode,$timeout,$reset_to_unity)=@_;') &&
    lgSource.includes('&lg_write_1d_lut_file($path,$unity);') &&
    lgSource.includes('$reset_ddc_baseline=$reset_ddc_baseline ? 1 : 0;') &&
    lgSource.includes('$calibration_mode_active=0 if($reset_ddc_baseline);') &&
    lgSource.includes('sub lg_lut_matches') &&
    lgSource.includes('&lg_ddc_baseline_lut($session,$ip,$picture_mode,$timeout,$reset_ddc_baseline)') &&
    lgSource.includes('my $verify_lut=&lg_get_current_1d_lut($session,$timeout);') &&
    lgSource.includes('LG DDC reset upload did not verify against the TV 1D LUT readback.') &&
	    lgSource.includes('ddc_reset_verified => &json_bool($reset_ddc_baseline && $upload_verified)') &&
	    lgSource.includes('ddc_upload_verified => &json_bool($upload_verified)') &&
    lgSource.includes('ddc_reset_verified => &json_bool($ddc_result->{"ddc_reset_verified"})') &&
    lgWebSource.includes('$calibration_mode_active=0 if($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"});') &&
    lgWebSource.includes('reset_ddc_baseline => ($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"})') &&
    source.includes('response.ddc_reset_verified!==true'),
  'LG DDC reset should discard stale cached baselines, upload zero offsets against a unity 1D LUT, and verify the TV readback'
);
assert(
  source.includes('my $grey_custom_allowed=$grey_custom_enabled ? 1 : 0;') &&
    !source.includes('!($points==21 && $lg_greyscale_21)'),
  'LG 21/22-point greyscale should keep using the saved custom stimulus table from the 2.6.1 flow'
);
assert(
  source.includes('\\"analysis_ire\\":$analysis_ire,\\"target_ire\\":$analysis_ire,\\"transport_stimulus\\":$stim') &&
    source.includes('function meterLgSdrLegalStimulusFromCode(code)') &&
    source.includes('const analysisIre=meterLgSdrLegalStimulusFromCode(step.g);') &&
    source.includes('function meterGreyChartStimulusIre(item)') &&
    source.includes('function meterGreyChartPlotIre(item)') &&
    source.includes('step.transport_stimulus=entry.stimulus;') &&
    source.includes('const candidates=[reading.analysis_ire,reading.target_ire') &&
    source.includes('if(code!=null&&(meterChartIsHdr()||meterGreyAllowsHeadroomTargets())) return meterGreySignalFractionFromCode(code);'),
  'LG 22pt manual charts should analyze the decoded legal stimulus while still labeling and controlling the LG menu slot'
);
assert(
  source.includes('id="meterAutoCalResetBtn" onclick="meterAutoCalRunPreflightReset()"') &&
    source.includes('resetBtn.style.display=(showDisclaimer&&!meterAutoCalPreflightResetDone)') &&
    source.includes('disclaimerBtn.style.display=(showDisclaimer&&meterAutoCalPreflightResetDone)') &&
    source.includes('async function meterAutoCalRunPreflightReset()') &&
    source.includes("message:'Click Continue when ready.'") &&
    source.includes('async function meterAutoCalRunLevelPreflight()') &&
    source.includes('async function meterStartSingleReadWithTimeout') &&
    source.includes('function meterAutoCalBlackClipOk') &&
    source.includes('function meterAutoCalBlackClipState') &&
    source.includes('function meterAutoCalWhiteClipOk') &&
    source.includes('function meterAutoCalWhiteClipState') &&
    source.includes('function meterAutoCalReadTransient') &&
    source.includes("current_name:'Retrying meter read'") &&
    source.includes('referenceBlack?45000:180000') &&
    source.includes('if(referenceBlack&&/timeout|timed out/i.test(lastMessage)) break;') &&
    source.includes('synthetic_black:true') &&
    source.includes("white:[233,234,235]") &&
    source.includes("white:[253,254,255]") &&
    source.includes('const delta=blackState.floorRaised?-1:1') &&
    source.includes('const firstVisible=blackTo18Separated||nearBlackSeparated') &&
    source.includes("current_name:kind==='black'?'Tuning Black Brightness':'Tuning White Contrast'") &&
    source.includes("message:'Preserving black floor at brightness '+brightness") &&
    source.includes('const optimizeBlackSeparation=finalBlackState.ok') &&
    source.includes("throw new Error('Black floor is still raised after brightness adjustment.')") &&
    source.includes("meterAutoCalWriteClipControl('brightness',Number(brightness)-1") &&
    source.includes("keys:['pictureMode','brightness','contrast']") &&
    source.includes('readback_keys:[key]') &&
    source.includes("if(key!=='brightness'&&key!=='contrast')") &&
    source.includes("meterAutoCalWriteClipControl('brightness',Number(brightness)+delta") &&
    source.includes('const targetReached=lowerSeparated&&topSeparated') &&
    source.includes('tooHigh:!targetReached') &&
    source.includes('for(let attempt=0;attempt<36;attempt++)') &&
    source.includes("meterAutoCalWriteClipControl('contrast',Number(contrast)-1") &&
    source.includes("meterAutoCalWriteClipControl('contrast',Number(contrast)+1") &&
    source.includes("message:'Backed off contrast to '+contrast") &&
    source.includes("current_name:'Tuning White Contrast'") &&
    !source.includes('stimulus_probe_enabled:true') &&
    !source.includes('Checking white clipping') &&
    !source.includes('Checking black clipping') &&
    !source.includes('meterAutoCalLevelPreflight=await meterAutoCalRunLevelPreflight();') &&
	    source.includes('meterAutoCalLevelPreflight={skipped:true};') &&
	    source.includes('meterActionPending=false;') &&
	    source.includes('function meterAutoCalSetupOverlayActive()') &&
	    source.includes("current_name:'Reset failed'") &&
	    source.includes("const message=meterAutoCalPreflightResetDone?'Click Continue when ready.'") &&
	    source.includes("'Run the LG DDC reset first.'") &&
	    source.includes("'Run the LG DDC and 3D LUT reset first.'"),
  'LG Auto Cal preflight should expose Reset first, skip automatic clipping changes, then park on a simple Continue path'
);
assert(
  !lgWebSource.includes('data-widget="display-control"') &&
    lgWebSource.includes('id="lgDisplayControlOpenBtn"') &&
    lgWebSource.includes('id="lgDisplayControlModal"') &&
    lgWebSource.includes('function lgOpenDisplayControl()') &&
    lgWebSource.includes('function lgCloseDisplayControl()') &&
    lgWebSource.includes('Display Control') &&
    lgWebSource.includes("key:'brightness'") &&
    lgWebSource.includes("key:'contrast'") &&
    lgWebSource.includes("key:'blackLevel'") &&
    lgWebSource.includes("key:'backlight'") &&
    lgWebSource.includes("key:'oledPixelBrightness'") &&
    lgWebSource.includes('id="lgDisplayControlResetBtn"') &&
    lgWebSource.includes('Reset Picture Mode') &&
    lgWebSource.includes('#lgDisplayControlPanel .lg-display-control-row select,#lgDisplayControlPanel .lg-display-control-row input[type="number"],#lgDisplayControlPanel .lg-display-control-row input[type="text"]') &&
    lgWebSource.includes('color-scheme:dark') &&
    lgWebSource.includes('#lgDisplayControlPanel .lg-display-control-row select option{background:#0d0d15;color:var(--text)}') &&
    lgWebSource.includes('function lgSelectedPictureModeValue()') &&
    lgWebSource.includes('const mode=lgSelectedPictureModeValue();') &&
    lgWebSource.includes('function lgPictureResetButtons()') &&
    lgWebSource.includes('async function lgDisplayControlRefresh(force)') &&
    lgWebSource.includes('async function lgDisplayControlCommit(key)') &&
    source.includes("'lgDisplayControlModal'"),
  'LG web UI should expose manual Display Control picture settings in a popup'
);
assert(
  source.includes('id="meterDisplayStatusStack"') &&
    source.includes('id="lgTopStatusWrap"') &&
    source.includes('function syncTopStatusStack()') &&
    lgWebSource.includes('function renderLgTopStatus(r)') &&
    lgWebSource.includes('renderLgTopStatus(r);'),
  'Top status bar should stack connected meter and connected LG display status'
);
assert(
  source.includes('$final_config_ready=&webui_meter_session_config_matches($config) ? 1 : 0') &&
    source.includes('$final_fifo_ready=&webui_meter_session_fifo_ready() ? 1 : 0') &&
    source.includes('$final_start_ready=&webui_meter_session_start_ready() ? 1 : 0') &&
    source.includes('$final_config_ready && $final_start_ready && !$final_fifo_ready') &&
    source.includes('config_ready=$final_config_ready fifo_ready=$final_fifo_ready start_ready=$final_start_ready'),
  'Meter session startup should retry and clean up when spotread reaches ready but the command FIFO is unusable'
);
assert(
  meterSessionSource.includes('Always re-display the requested patch before measuring') &&
    meterSessionSource.includes('post_patch "$R" "$G" "$B" "$PSIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"') &&
    !meterSessionSource.includes('if [[ "$R" != "$LAST_R"'),
  'Persistent spotread sessions should redisplay each requested patch so external pattern changes cannot poison read-once or continuous results'
);
assert(
  source.includes("current_name:'Meter setup failed'") &&
    source.includes("click Continue to retry"),
  'LG Auto Cal should keep the reset popup open and allow Continue retry when luminance meter setup fails'
);
assert(
  source.includes('setsid /usr/bin/perl /usr/bin/meter_lg_autocal.pl') &&
    !source.includes('setsid sudo /usr/bin/perl /usr/bin/meter_lg_autocal.pl') &&
    source.includes('const overlayActive=!!active;') &&
    source.includes("function meterAutoCalRepairOverlayPointerState()") &&
    source.includes("document.body.classList.toggle('meter-autocal-active',meterAutoCalOverlayVisible())") &&
    source.includes("if(status.status==='running')") &&
    source.includes('meterAutoCalSetOverlay(false,status)') &&
    source.includes("meterAutoCalSetOverlay(false,{phase:'running',current_name:'LG Auto Cal started'") &&
    source.includes("if(r.status==='error')") &&
    source.includes("current_name:r.current_name||'LG Auto Cal error'") &&
    source.includes("message:r.message||'Auto Cal failed'") &&
    source.includes("current_name:'LG Auto Cal error'"),
  'LG Auto Cal worker should launch without sudo, hide the setup overlay while running, and keep errors visible'
);
assert(
  autocalWorkerSource.includes('use IO::Select ();') &&
    autocalWorkerSource.includes('use MIME::Base64 ();') &&
    autocalWorkerSource.includes('my $deadline=time()+$timeout;') &&
    autocalWorkerSource.includes('$selector->can_read') &&
    autocalWorkerSource.includes('Web UI API timed out during $path') &&
    autocalWorkerSource.includes('sub lg_helper_picture_set') &&
    autocalWorkerSource.includes('PGEN_LG_REQUEST_B64') &&
    autocalWorkerSource.includes('},170);') &&
    autocalWorkerSource.includes('connect_timeout => 8') &&
    autocalWorkerSource.includes('sub lg_write_error_is_transient') &&
    autocalWorkerSource.includes('Unable to connect to LG WebOS TV') &&
    autocalWorkerSource.includes('LG TV connection missed; retrying write') &&
    autocalWorkerSource.includes('my $attempts=4;') &&
    autocalWorkerSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state') &&
    lgWebSource.includes('sub lg_helper_timeout (@)') &&
    lgWebSource.includes('timeout ${timeout}s env PGEN_LG_REQUEST_B64=') &&
    lgWebSource.includes('LG TV did not finish the white-balance write'),
  'LG Auto Cal and LG helper calls should have hard deadlines and retry transient LG WebOS connection misses instead of hanging or aborting mid-calibration'
);
assert(
  source.includes('const currentKey=meterAutoCalCurrentKeyFromStatus(status);') &&
    source.includes('drawAllChartsPreset(sortedSteps);') &&
    source.includes('meterBuildPatchThumbs(sortedSteps,new Set(),currentKey)'),
  'LG Auto Cal should keep the live chart scaffold and current-point status visible before the first reading arrives'
);
assert(
    autocalWorkerSource.includes('$keep_calibration_mode=1 if(!defined($keep_calibration_mode));') &&
    autocalWorkerSource.includes('sub set_state_calibration_mode') &&
    autocalWorkerSource.includes('$state->{"calibration_mode"}=$active ? JSON::PP::true : JSON::PP::false;') &&
    autocalWorkerSource.includes('set_state_calibration_mode($state,$response->{"calibration_mode"} ? 1 : 0') &&
    autocalWorkerSource.includes('keep_calibration_mode => $keep_calibration_mode ? JSON::PP::true : JSON::PP::false') &&
    autocalWorkerSource.includes('calibration_mode_active => $calibration_mode_active ? JSON::PP::true : JSON::PP::false') &&
    autocalWorkerSource.includes('sub end_calibration_mode') &&
    lgSource.includes('calibration_mode_active=$calibration_mode_active ? 1 : 0') &&
    lgSource.includes('ddc_cal_start_late') &&
    lgSource.includes('$calibration_mode_active || $first_message =~') &&
    lgSource.includes('calibration_mode_active => &json_true()'),
  'LG Auto Cal DDC writes should keep calibration mode open and skip repeated CAL_START calls after the first write'
);
{
  const orderStart = autocalWorkerSource.indexOf('sub order_autocal_steps');
  const lgDescending = autocalWorkerSource.indexOf('defined($a->{"autocal_order_ire"})', orderStart);
  const topSort = autocalWorkerSource.indexOf('my @top=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) >= 98.9 } @valid;', orderStart);
  const shadowSort = autocalWorkerSource.indexOf('my @shadow=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep { ($_->{"ire"}+0) > 0 && ($_->{"ire"}+0) <= 10.0001 } @valid;', topSort);
  const reservedSlots = autocalWorkerSource.indexOf('my %reserved=map { format_percent($_->{"ire"}) => 1 } (@top,@shadow);', shadowSort);
  const bodySort = autocalWorkerSource.indexOf('my @body=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { !$reserved{format_percent($_->{"ire"})} } @valid;', reservedSlots);
  const returnOrder = autocalWorkerSource.indexOf('return (@top,@body,@shadow);', bodySort);
  const skipDuplicate = autocalWorkerSource.indexOf('sub autocal_skip_duplicate_ddc_slot');
  assert(
    orderStart >= 0 &&
      lgDescending > orderStart &&
      topSort > orderStart &&
      shadowSort > topSort &&
      reservedSlots > shadowSort &&
      bodySort > reservedSlots &&
	      returnOrder > bodySort &&
	      skipDuplicate >= 0 &&
	      skipDuplicate < orderStart &&
      autocalWorkerSource.includes('!autocal_skip_duplicate_ddc_slot($_)') &&
	      autocalWorkerSource.includes('defined($step->{"ddc_target_ire"}) ? $step->{"ddc_target_ire"} : $step->{"ire"}') &&
	      !autocalWorkerSource.includes('return 1 if($key eq "7.5" || $key eq "35" || $key eq "70");') &&
	      autocalWorkerSource.includes('my @ordered=order_autocal_steps($steps,$config);') &&
	      autocalWorkerSource.includes('sub fixed_lg_autocal_stimulus') &&
	      autocalWorkerSource.includes('"2.3" => 2.28310502283105') &&
	      autocalWorkerSource.includes('"75" => 74.8858447488585') &&
	      autocalWorkerSource.includes('"109" => 109.474885844749') &&
      autocalWorkerSource.includes('my $slot_read_step=fixed_lg_autocal_step($config,$step);') &&
      autocalWorkerSource.includes('my $read_step=clone_picture($slot_read_step);') &&
      autocalWorkerSource.includes('next if($target_slot_ire <= 100.0001 && ($slots[$probe]+0) >= 105);') &&
      autocalWorkerSource.includes('return $step if(!$config->{"use_shifted_lg_autocal_stimulus"});') &&
      autocalWorkerSource.includes('$reading->{"autocal_fixed_stimulus"}=JSON::PP::true') &&
      autocalWorkerSource.includes('sub stimulus_probe_enabled') &&
      autocalWorkerSource.includes('return (ref($config) eq "HASH" && $config->{"stimulus_probe_enabled"}) ? 1 : 0;') &&
	      autocalWorkerSource.includes('if(!$adjustments && stimulus_probe_enabled($config) && !autocal_step_is_peak_headroom($read_step) && !$pair_target_reached_now->())') &&
      autocalWorkerSource.includes('if(stimulus_probe_enabled($config) && $needs_stimulus_probe)') &&
      autocalWorkerSource.includes('return (undef,$reading,$arrays,$picture,undef) if(!stimulus_probe_enabled($config));'),
    'LG Auto Cal should calibrate captured 26pt patches top/body first, then shadows low-to-high so 5% is not followed by lower-slot writes'
		  );
		  assert(
			    autocalWorkerSource.includes('sub legal_white_pair_close_enough') &&
			      autocalWorkerSource.includes('sub legal_white_pair_close_enough_stalled') &&
			      autocalWorkerSource.includes('sub legal_white_pair_precision_stall_limit') &&
			      autocalWorkerSource.includes('$state->{"message"}="$label and 100% legal white close pair kept"') &&
			      autocalWorkerSource.includes('legal_white_pair_close_enough_stalled($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading,$target_delta,$white_guard_y,$stalls,$iter)') &&
			      autocalWorkerSource.includes('config_positive_int($config,"paired_white_polish_iterations",8,1,28)') &&
			      autocalWorkerSource.includes('$micro_step=(defined($best_de) && $best_de > ($target_delta+0.75)) ? 0.25 : 0.10;') &&
			      autocalWorkerSource.includes('legal_white_pair_precision_stall_limit($best_de,$best_pair_de,$target_delta)'),
			    'LG Auto Cal should balance 99% and hidden 100% with small paired-slot moves and stop stalled polish once both are close'
			  );
			  assert(
			    autocalWorkerSource.includes('sub legal_white_pair_luminance_priority_adjustments') &&
			      autocalWorkerSource.includes('my $pair_chroma_mag=chroma_error_magnitude($err);') &&
			      autocalWorkerSource.includes('$pair_chroma_mag < 0.035 || (defined($de) && $de <= ($target_delta+1.0))') &&
			      autocalWorkerSource.includes('$pair_chroma_mag < 0.025 || (defined($best_de) && $best_de <= ($target_delta+0.75))') &&
			      autocalWorkerSource.includes('sub headroom_105_wrgb_seed_adjustment') &&
			      autocalWorkerSource.includes('sub legal_white_pair_wrgb_seed_adjustment') &&
			      autocalWorkerSource.includes('whiteBalanceRed => 4.25') &&
			      autocalWorkerSource.includes('whiteBalanceBlue => -7') &&
			      autocalWorkerSource.includes('my $candidate_delta_keep=sub') &&
			      autocalWorkerSource.includes('return 0 if(!autocal_step_is_low_shadow($read_step));') &&
			      autocalWorkerSource.includes('$adj->{"paired_luminance"}=1 if(ref($adj) eq "HASH");'),
			    'LG Auto Cal should prioritize paired 99/100 luminance only after chroma is close enough for Y trimming'
			  );
			}
	assert(
  lgWebSource.includes('sub lg_settings_are_ddc_white_balance (@)') &&
    lgWebSource.includes('exists($payload->{"keep_calibration_mode"})') &&
    lgWebSource.includes('(($clients->{"calibration_mode"}||$ddc_white_balance) ? 1 : 0)') &&
    lgWebSource.includes('my $calibration_mode_active=($payload->{"calibration_mode_active"}||($ddc_white_balance&&$keep_calibration_mode&&$clients->{"calibration_mode"})) ? 1 : 0;') &&
    lgWebSource.includes('$updated_clients->{"calibration_mode"}=$keep_calibration_mode ? &lg_json_true() : &lg_json_false();') &&
    lgSource.includes('calibration_picture_mode => $ddc_result->{"calibration_picture_mode"}||""'),
  'Manual LG RGB writes should keep calibration mode open and skip repeat CAL_START when a DDC session is already active'
);
assert(
  autocalWorkerSource.includes('sub choose_adjustments') &&
    autocalWorkerSource.includes('sub adjustment_step') &&
    autocalWorkerSource.includes('sub stalled_step_floor') &&
    autocalWorkerSource.includes('stalled_step_floor($stalls,$de,$abs_err)') &&
    autocalWorkerSource.includes('$floor=5;') &&
    autocalWorkerSource.includes('if($de <= 1.0 || $abs_err < 0.01)') &&
	    autocalWorkerSource.includes('return $cap if($floor > $cap);') &&
	    !autocalWorkerSource.includes('$step*=0.5 if($stalls >= 3);') &&
		    autocalWorkerSource.includes('sub mark_tried_values') &&
		    autocalWorkerSource.includes('sub next_untried_value') &&
		    autocalWorkerSource.includes('repeated_value($tried,$setting,$next)') &&
		    autocalWorkerSource.includes('sub strict_tried_for_step') &&
		    autocalWorkerSource.includes('$read_step->{"legal_white_pair_active"}=JSON::PP::true') &&
		    autocalWorkerSource.includes('my $seen=$strict ? tried_value_exists($tried,$setting,$next) : repeated_value($tried,$setting,$next);') &&
		    autocalWorkerSource.includes('mark_tried_values(\\%tried_values,$arrays,$target,$de);') &&
		    autocalWorkerSource.includes('sub choose_rgb_response_adjustments') &&
		    autocalWorkerSource.includes('sub update_rgb_response_model') &&
		    autocalWorkerSource.includes('my $paired_white=strict_tried_for_step($step);') &&
		    autocalWorkerSource.includes('$max_jump=(defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 1.0 : 0.5;') &&
		    autocalWorkerSource.includes('my $probe_step=$paired_white ? ((defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 0.5 : 0.25) : 1;') &&
		    autocalWorkerSource.includes('paired_white=>$paired_white ? 1 : 0') &&
		    autocalWorkerSource.includes('$adjustments=choose_rgb_response_adjustments($err,$arrays,$target,\\%rgb_response_model,\\%tried_values,$de,$read_step,$target_delta,$stalls) if(!$adjustments);') &&
		    autocalWorkerSource.includes('choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\\%tried_values,$read_step)') &&
		    autocalWorkerSource.includes('my $pair_switched=$switch_to_worst_pair_step->("Paired result after adjustment");') &&
		    autocalWorkerSource.includes('%rgb_response_model=();') &&
			    autocalWorkerSource.includes('sub neutral_luminance_adjustments') &&
		    autocalWorkerSource.includes('sub neutral_luminance_step') &&
		    autocalWorkerSource.includes('sub low_shadow_luminance_max_step') &&
		    autocalWorkerSource.includes('$low_cap=4 if($abs >= 0.40);') &&
		    autocalWorkerSource.includes('$low_cap=2 if($abs >= 0.50);') &&
		    autocalWorkerSource.includes('foreach my $candidate ($max_step,1,0.5,0.25)') &&
		    autocalWorkerSource.includes('next if($candidate > $max_step+0.0001);') &&
		    autocalWorkerSource.includes('$threshold=$tol*1.5 if($ire > 0 && $ire <= 3.1001);') &&
			    autocalWorkerSource.includes('sub target_is_low_shadow_slot') &&
			    autocalWorkerSource.includes('sub low_ire_luminance_needs_lift') &&
			    autocalWorkerSource.includes('return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));') &&
			    autocalWorkerSource.includes('sub low_ire_luminance_needs_tuning') &&
			    autocalWorkerSource.includes('return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));') &&
			    !autocalWorkerSource.includes('return 1 if($ire > 0 && $ire <= 3.1 && $de <= 0.25);') &&
			    !autocalWorkerSource.includes('return 1 if($ire <= 5 && $de <= 4.0);') &&
				    autocalWorkerSource.includes('return 4 if($ire <= 3.1);') &&
				    autocalWorkerSource.includes('return 3.5 if($ire <= 5);') &&
				    autocalWorkerSource.includes('return 3 if($ire <= 7.5);') &&
				    autocalWorkerSource.includes('return 2.5 if($ire <= 10);') &&
			    autocalWorkerSource.includes('$value=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $value < 0);') &&
			    !autocalWorkerSource.includes('$next=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $luminance_err < 0 && $current < 0 && $next < 0);') &&
		    autocalWorkerSource.includes('sub implausible_autocal_read') &&
		    autocalWorkerSource.includes('sub read_step_guarded') &&
		    autocalWorkerSource.includes('Rejecting implausible Auto Cal read') &&
		    autocalWorkerSource.includes('$ratio >= 0.35 && $ratio <= 2.20') &&
		    autocalWorkerSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
	    autocalWorkerSource.includes('sub chroma_error_magnitude') &&
	    autocalWorkerSource.includes('neutral_luminance=>1') &&
	    autocalWorkerSource.includes('$luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));') &&
	    autocalWorkerSource.includes('$near_fine=0 if($ire >= 99.9 && defined($de) && $de > 0.75);') &&
	    autocalWorkerSource.includes('return 1 if($ire >= 99.9 && !defined($lum_pct));') &&
	    autocalWorkerSource.includes('return 0.45;') &&
		    autocalWorkerSource.includes('$_->{"damped"}?" damped":""') &&
			    autocalWorkerSource.includes('sub stimulus_probe_steps') &&
			    autocalWorkerSource.includes('($base <= 20) ? (-2,-4,-6,-8,2,4,6,8)') &&
			    autocalWorkerSource.includes('($base <= 20) ? (0,-2,-4,-6,-8,2,4,6,8)') &&
			    autocalWorkerSource.includes('sub shifted_stimulus_step') &&
			    autocalWorkerSource.includes('sub probe_responsive_stimulus') &&
			    autocalWorkerSource.includes('sub reading_change_score') &&
		    autocalWorkerSource.includes('sub ddc_target_max_delta') &&
		    autocalWorkerSource.includes('sub restore_target_slot_arrays') &&
		    autocalWorkerSource.includes('sub far_from_target') &&
		    autocalWorkerSource.includes('my $slot_default_arrays=clone_arrays($arrays);') &&
		    autocalWorkerSource.includes('my $base_arrays=restore_target_slot_arrays($arrays,$slot_default_arrays,$target);') &&
		    autocalWorkerSource.includes('return ($best_probe_step,$best_before,$best_restore_arrays,$best_picture,undef);') &&
		    autocalWorkerSource.includes('sub ddc_target_near_limit') &&
		    autocalWorkerSource.includes('my %stimulus_probe_tried;') &&
		    autocalWorkerSource.includes('mark_stimulus_probe_tried(\\%stimulus_probe_tried,$read_step);') &&
			    autocalWorkerSource.includes('sub near_target_for_probe_skip') &&
			    autocalWorkerSource.includes('my $near_probe_skip=near_target_for_probe_skip($de,$lum_pct,$target_delta,$read_step);') &&
			    autocalWorkerSource.includes('my $keep_tuning_luma=0;') &&
			    autocalWorkerSource.includes('my $luma_gate=headroom_luminance_control_gate_percent($read_step,0.65);') &&
			    autocalWorkerSource.includes('$keep_tuning_luma=1 if(abs($lum_pct) > $luma_gate && !ddc_target_near_limit($arrays,$target,42));') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && ddc_target_near_limit($arrays,$target,45));') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $no_response_stalls >= 2);') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 4 && ddc_target_max_delta($arrays,$slot_default_arrays,$target) >= 12);') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 6 && far_from_target($de,$lum_pct,$target_delta,$read_step));') &&
			    autocalWorkerSource.includes('!autocal_step_is_peak_headroom($read_step) && !$pair_target_reached_now->()') &&
				    autocalWorkerSource.includes('my $restore_best_branch=sub') &&
				    autocalWorkerSource.includes('Backtracking to best $label result') &&
				    autocalWorkerSource.includes('"Backtracking to best $label result after rejected adjustment"') &&
			    autocalWorkerSource.includes('$state->{"active_stimulus"}=$read_step->{"stimulus"}+0') &&
    autocalWorkerSource.includes('read_step($config,$read_step,$state)') &&
	    autocalWorkerSource.includes('my $stimulus=defined($step->{"stimulus"})') &&
	    autocalWorkerSource.includes('$reading->{"stimulus"}=$step->{"stimulus"}') &&
	    autocalWorkerSource.includes('refresh_rate => $config->{"refresh_rate"}||""') &&
			    autocalWorkerSource.includes('sub close_enough_stalled') &&
			    autocalWorkerSource.includes('sub iteration_limit_for_step') &&
			    autocalWorkerSource.includes('sub autocal_step_is_fast_headroom') &&
			    autocalWorkerSource.includes('sub autocal_step_is_peak_headroom') &&
			    autocalWorkerSource.includes('return autocal_step_is_peak_headroom($step);') &&
			    autocalWorkerSource.includes('sub headroom_iteration_limit_for_step') &&
			    autocalWorkerSource.includes('my $limit=($ire >= 108.5) ? 60 : 36;') &&
			    autocalWorkerSource.includes('$limit=($ire >= 108.5) ? 10 : 8 if(autocal_config_is_touchup($config));') &&
			    autocalWorkerSource.includes('sub headroom_polish_limit_for_step') &&
			    autocalWorkerSource.includes('my $limit=($ire >= 108.5) ? 16 : 10;') &&
			    autocalWorkerSource.includes('sub autocal_step_allows_final_fine_tune') &&
				    autocalWorkerSource.includes('sub headroom_adjustment_step') &&
				    autocalWorkerSource.includes('my $step=headroom_adjustment_step(abs($err),$stalls,$min_step,$max_step,$micro);') &&
				    autocalWorkerSource.includes('sub headroom_autocal_result_score') &&
				    autocalWorkerSource.includes('my $de_score=defined($de) ? ($de+0) : 9999;') &&
				    autocalWorkerSource.includes('return $de_score+($max*12)+($sum*3);') &&
				    !autocalWorkerSource.includes('return ($max*100)+($sum*10)+$de_tiebreak;') &&
				    autocalWorkerSource.includes('sub headroom_fine_target_delta') &&
				    autocalWorkerSource.includes('sub headroom_needs_fine_tune') &&
				    autocalWorkerSource.includes('if(!autocal_step_is_peak_headroom($step) && ref($reading) eq "HASH" && defined($reading->{"target_luminance"}))') &&
				    autocalWorkerSource.includes('return 0 if(headroom_needs_fine_tune($de,$target_delta,$reading,$step));') &&
				    autocalWorkerSource.includes('my $headroom_score=headroom_autocal_result_score($de,$reading,$step);') &&
			    autocalWorkerSource.includes('if(!autocal_step_is_peak_headroom($step) && defined($lum_pct))') &&
				    autocalWorkerSource.includes('sub choose_headroom_single_adjustment') &&
			    autocalWorkerSource.includes('sub headroom_peak_match_low_adjustment') &&
			    autocalWorkerSource.includes('sub adjustments_have_flag') &&
			    autocalWorkerSource.includes('peak_match_low=>1') &&
			    autocalWorkerSource.includes('frozen_channel=>$low') &&
			    autocalWorkerSource.includes('headroom_peak_match_low_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0,$step)') &&
			    !autocalWorkerSource.includes('adjustments_have_flag($adjustments,"peak_match_low")') &&
				    autocalWorkerSource.includes('"Backtracking to best $label result after rejected adjustment"') &&
				    autocalWorkerSource.includes('"Backtracking $label fine tune after rejected adjustment"') &&
				    !autocalWorkerSource.includes('trace_109($read_step,"peak_match_low_continue"') &&
				    !autocalWorkerSource.includes('trace_109($read_step,"peak_match_low_continue_fine_tune"') &&
			    autocalWorkerSource.includes('sub headroom_chroma_adjustment') &&
			    autocalWorkerSource.includes('headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0)') &&
			    autocalWorkerSource.includes('sub headroom_pair_adjustment') &&
			    autocalWorkerSource.includes('headroom_pair=>1') &&
			    autocalWorkerSource.includes('headroom_pair_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,1,0)') &&
			    autocalWorkerSource.includes('sub headroom_peak_clip_relief_adjustment') &&
			    autocalWorkerSource.includes('peak_clip_relief=>1') &&
			    autocalWorkerSource.includes('headroom_peak_clip_relief_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,2,0,$step)') &&
			    autocalWorkerSource.includes('sub headroom_rgb_luminance_adjustments') &&
			    autocalWorkerSource.includes('headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step)') &&
			    autocalWorkerSource.includes('sub headroom_proportional_adjustment') &&
			    autocalWorkerSource.includes('my $before_err=autocal_adjustment_error($before,$step);') &&
			    autocalWorkerSource.includes('my $after_err=autocal_adjustment_error($after,$step);') &&
			    autocalWorkerSource.includes('my $ideal=$start - ($e0*($end-$start)/($e1-$e0));') &&
			    autocalWorkerSource.includes('proportional=>1') &&
			    autocalWorkerSource.includes('sub headroom_queued_adjustment_still_best') &&
			    autocalWorkerSource.includes('headroom_queued_adjustment_still_best($headroom_next_adjustments,$err,$de,$target_delta,$read_step)') &&
			    autocalWorkerSource.includes('$headroom_next_adjustments=undef if(autocal_step_is_fast_headroom($read_step));') &&
			    !autocalWorkerSource.includes('return 0 if(autocal_step_is_fast_headroom($step) && !headroom_rgb_balanced($reading,$target_delta,$step));') &&
			    !autocalWorkerSource.includes('Backtracking to best $label result after rejected headroom step') &&
			    autocalWorkerSource.includes('autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta)') &&
			    autocalWorkerSource.includes('$polish_limit=headroom_polish_limit_for_step($read_step,$config);') &&
			    autocalWorkerSource.includes('sub trace_109') &&
			    autocalWorkerSource.includes('/var/log/PGenerator/lg-autocal-109-trace.log') &&
			    autocalWorkerSource.includes('return 1;\n return 1 if(abs($ire-109) < 0.001);') &&
			    autocalWorkerSource.includes('trace_109($read_step,"initial_measurement"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"adjustment_plan"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"measurement_after_adjustment"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"candidate_rejected"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"restore_best_branch"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"fine_tune_plan"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"fine_tune_measurement"') &&
			    autocalWorkerSource.includes('trace_109($read_step,"final_step_result"') &&
		    !autocalWorkerSource.includes('return 18 if($ire >= 90 && $default > 18);') &&
		    autocalWorkerSource.includes('$default=50 if(!defined($default) || $default < 1);') &&
	    autocalWorkerSource.includes('$step=8') &&
	    autocalWorkerSource.includes('describe_adjustments($adjustments)') &&
	    autocalWorkerSource.includes('Reading $label after adjustment ($iter/$iteration_limit)') &&
	    autocalWorkerSource.includes('int($config->{"max_iterations"}) : 80') &&
	    autocalWorkerSource.includes('my $min_iterations=autocal_config_is_touchup($config) ? 4 : 12;') &&
	    autocalWorkerSource.includes('$stalls >= 8') &&
	    !autocalWorkerSource.includes('last if($stalls >= 8 && defined($de) && $de > $last_de'),
  'LG Auto Cal RGB adjustment should use larger multi-channel steps, show iteration progress, and avoid endless 100% fine-tuning'
);
assert(
    autocalWorkerSource.includes('sub target_luminance_for_step') &&
    autocalWorkerSource.includes('sub target_luminance_for_autocal_step') &&
    autocalWorkerSource.includes('sub update_white_reference_for_step') &&
    autocalWorkerSource.includes('sub set_state_white_reference') &&
    autocalWorkerSource.includes('sub delta_e_luv_gamma') &&
    autocalWorkerSource.includes('sub luminance_error_ratio') &&
	    autocalWorkerSource.includes('sub luminance_tolerance_percent') &&
	    autocalWorkerSource.includes('return 4 if($ire <= 3.1);') &&
	    autocalWorkerSource.includes('return 3.5 if($ire <= 5);') &&
	    autocalWorkerSource.includes('return 3 if($ire <= 7.5);') &&
	    autocalWorkerSource.includes('return 2.5 if($ire <= 10);') &&
	    autocalWorkerSource.includes('sub target_reached') &&
		    autocalWorkerSource.includes('sub autocal_result_score') &&
		    autocalWorkerSource.includes('sub white_luminance_guard_failed') &&
		    autocalWorkerSource.includes('sub guarded_autocal_result_score') &&
		    autocalWorkerSource.includes('sub guarded_target_reached') &&
		    autocalWorkerSource.includes('$penalty=$excess*0.35') &&
		    autocalWorkerSource.includes('$penalty=4 if($penalty > 4);') &&
		    !autocalWorkerSource.includes('return 100 + ($excess*4) + $score;') &&
		    autocalWorkerSource.includes('sub legal_white_pair_target_reached') &&
		    autocalWorkerSource.includes('sub legal_white_pair_needs_work') &&
		    autocalWorkerSource.includes('$force_other_focus=1 if(autocal_step_is_white($read_step) && !autocal_step_is_white($pair_step) && $other_de > $target_delta+0.10);') &&
		    autocalWorkerSource.includes('$iteration_limit=48 if($paired_white_step && !autocal_config_is_touchup($config) && $iteration_limit < 48);') &&
		    autocalWorkerSource.includes('my $no_response_stall_limit=$paired_white_step ? 6 : 2;') &&
		    autocalWorkerSource.includes('my $no_response_iter_floor=$paired_white_step ? 12 : 4;') &&
			    autocalWorkerSource.includes('config_positive_int($config,"paired_white_polish_iterations",8,1,28)') &&
		    autocalWorkerSource.includes('if($pair_target_reached_now->())') &&
		    autocalWorkerSource.includes('last if($pair_target_reached_now->());') &&
			    autocalWorkerSource.includes('sub choose_micro_adjustments') &&
			    autocalWorkerSource.includes('sub autocal_itp_precision_polish_needed') &&
			    autocalWorkerSource.includes('return 0 if(autocal_step_is_low_shadow($step));') &&
				    autocalWorkerSource.includes('Starting final fine tune for $label') &&
				    autocalWorkerSource.includes('Fine tuning $label') &&
				    autocalWorkerSource.includes('$polish_limit=48 if(!defined($polish_limit));') &&
			    autocalWorkerSource.includes('my $precision_needed=autocal_itp_precision_polish_needed($best_de,$target_delta,$read_step);') &&
			    autocalWorkerSource.includes('my $precision_polish_limit=config_positive_int($config,"precision_polish_iterations",72,0,72);') &&
			    autocalWorkerSource.includes('if($precision_needed) {') &&
			    autocalWorkerSource.includes('if(ref($config) eq "HASH" && defined($config->{"precision_polish_iterations"}))') &&
			    autocalWorkerSource.includes('$polish_limit=$precision_polish_limit;') &&
			    autocalWorkerSource.includes('$best_de <= ($target_delta+0.15)') &&
			    autocalWorkerSource.includes('foreach my $mag ($max_step,1.0,0.5,0.20)') &&
				    autocalWorkerSource.includes('next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step,$strict_tried)') &&
					    autocalWorkerSource.includes('my $precision_stall_limit=$paired_white_step ? legal_white_pair_precision_stall_limit($best_de,$best_pair_de,$target_delta) : autocal_itp_precision_stall_limit($best_de,$target_delta,$read_step);') &&
					    autocalWorkerSource.includes('last if($polish_stalls >= $precision_stall_limit);') &&
		    autocalWorkerSource.includes('my $probe_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);') &&
		    autocalWorkerSource.includes('if(defined($de) && $probe_score + 0.0001 < $best_score)') &&
		    autocalWorkerSource.includes('Keeping best $label result') &&
	    autocalWorkerSource.includes('target_gamma=>$target_gamma') &&
		    autocalWorkerSource.includes('setup_luminance_reference=>$setup_luminance_reference||$target_luminance||undef') &&
		    autocalWorkerSource.includes('target_luminance=>$target_luminance||undef') &&
		    autocalWorkerSource.includes('headroom_target_luminance=>$headroom_target_luminance||undef') &&
		    autocalWorkerSource.includes('my $white_y=($target_luminance > 0) ? $target_luminance : undef;') &&
		    autocalWorkerSource.includes('return $white_y if(defined($white_y) && $white_y > 0);') &&
		    autocalWorkerSource.includes('set_state_white_reference($state,$white_y) if(autocal_step_is_white($read_step));') &&
		    autocalWorkerSource.includes('return $white_y if(autocal_step_is_white($step));') &&
		    autocalWorkerSource.includes('target_step_luminance') &&
		    autocalWorkerSource.includes('return $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE if(autocal_step_is_peak_headroom($step) && $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE > 0);') &&
		    autocalWorkerSource.includes('configured_delay_ms') &&
    autocalWorkerSource.includes('$reading->{"read_delay_ms"}=$delay_ms') &&
    autocalWorkerSource.includes('sub read_request_id') &&
    autocalWorkerSource.includes('sub read_timeout_for_step') &&
    autocalWorkerSource.includes('sub transient_read_error') &&
    autocalWorkerSource.includes('sub read_step_once') &&
	    autocalWorkerSource.includes('/api/meter/session/stop') &&
	    autocalWorkerSource.includes('sub patch_payload_for_step') &&
	    autocalWorkerSource.includes('sub apply_pattern_insert_before_read') &&
	    autocalWorkerSource.includes('api_json("POST","/api/pattern",$payload,10);') &&
	    autocalWorkerSource.includes('api_json("POST","/api/pattern",patch_payload_for_step($config,$step),10);') &&
		    autocalWorkerSource.includes('$read_sequence++;') &&
	    autocalWorkerSource.includes('$state_ref->{"meter_read_retry"}=$attempt') &&
			    autocalWorkerSource.includes('my $session_read_timeout=read_timeout_for_step($step,undef)-20;') &&
			    autocalWorkerSource.includes('$payload->{"read_timeout"}=int($session_read_timeout);') &&
			    autocalWorkerSource.includes('my $deadline=time()+read_timeout_for_step($step,$payload->{"read_timeout"});') &&
			    autocalWorkerSource.includes('return 210 if($ire <= 5);') &&
			    autocalWorkerSource.includes('$delay_ms=1800 if($delay_ms < 1800);') &&
			    autocalWorkerSource.includes('$delay_ms=5000 if($ire <= 5 && $delay_ms < 5000);') &&
			    autocalWorkerSource.includes('$delay_ms=4200 if($ire > 5 && $ire <= 10 && $delay_ms < 4200);') &&
			    autocalWorkerSource.includes('$delay_ms=3200 if($ire > 10 && $ire <= 25 && $delay_ms < 3200);') &&
			    autocalWorkerSource.includes('int($config->{"read_attempts"}) : 5') &&
	    autocalWorkerSource.includes('delete $state_ref->{"meter_read_retry"}') &&
    autocalWorkerSource.includes('request_id => $request_id') &&
    autocalWorkerSource.includes('Ignoring mismatched meter result') &&
    autocalWorkerSource.includes('my $read_started=time();') &&
    autocalWorkerSource.includes('Ignoring stale meter result') &&
    source.includes('"request_id":"\'.$request_id.\'"') &&
    source.includes('my $cmd_request_id=($request_id ne "") ? $request_id : "-";') &&
    source.includes('my $cmd_read_timeout=($read_timeout > 0) ? $read_timeout : "-";') &&
    source.includes('$read_command.=" $cmd_signal_range $cmd_transport_signal_range $cmd_request_id $patch_input_max $cmd_read_timeout"') &&
    meterSessionSource.includes('REQUEST_ID') &&
    meterSessionSource.includes('[[ "$REQUEST_ID" == "-" ]] && REQUEST_ID=""') &&
    meterSessionSource.includes('READ_TIMEOUT_OVERRIDE') &&
    meterSessionSource.includes('READ_TIMEOUT="$READ_TIMEOUT_OVERRIDE"') &&
    meterSessionSource.includes('\\"request_id\\":\\"$REQUEST_ID\\"') &&
    meterSessionSource.includes('READ_TIMEOUT=90') &&
    meterSessionSource.includes('ire_le "$IRE" 25 && READ_TIMEOUT=120') &&
    meterSessionSource.includes('ire_le "$IRE" 5 && READ_TIMEOUT=140') &&
    source.includes('return meterPollRead(timeoutMs||180000,shouldCancel);') &&
    source.includes('async function meterStartSingleReadWithTimeout') &&
    source.includes('await meterPollRead(180000,()=>!meterContinuousActive)') &&
    source.includes('const invalidatedByLgWrite=readSuspendToken!==meterContinuousSuspendToken') &&
    source.includes('meter read state stale for ${age}s') &&
    source.includes(',"timeout_sec":') &&
    meterSessionSource.includes('PARSED_JSON="$PARSED"') &&
    meterSessionSource.includes("json.loads(os.environ.get('PARSED_JSON','{}'))") &&
    meterSessionSource.includes('ire_le "$IRE" 25') &&
    source.includes('my $patch_ire_explicit=""') &&
    source.includes('(($patch_r-16)/219)*100') &&
    source.includes('function meterApplyReadStepPayload(readPayload,step)') &&
    source.includes('meterApplyReadStepPayload(readPayload,requestedStep);') &&
    autocalWorkerSource.includes('ire => $step->{"ire"}+0') &&
    source.includes('$cmd!~/meter_session\\.sh/') &&
    source.includes("sudo pkill -9 -f 'script.*spotread'") &&
	    autocalWorkerSource.includes('my $err=autocal_adjustment_error($reading,$read_step);') &&
	    autocalWorkerSource.includes('choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\\%tried_values,$read_step)') &&
	    autocalWorkerSource.includes('choose_micro_adjustments($err,$arrays,$target,$lum_err,\\%polish_tried,$micro_step,$best_de,$polish_stalls,$read_step,$target_delta)') &&
    autocalWorkerSource.includes('$state->{"message"}=$paired_white_step') &&
    source.includes("target_gamma:(document.getElementById('meterTargetGamma')||{}).value||'bt1886'") &&
    source.includes('return Math.max(10,Math.min(10000,setup));') &&
    source.includes('return Math.max(10,Math.min(10000,setup*peakRatio));') &&
    source.includes("message:'Using 100% target '+targetY.toFixed(2)+' cd/m\\u00B2 and 109% target '+headroomY.toFixed(2)+' cd/m\\u00B2'"),
  'LG Auto Cal/manual reads should include gamma/luminance error, reject stale results, and keep meter sessions healthy'
);
assert(
    autocalWorkerSource.includes('sub autocal_step_is_low_shadow') &&
	    autocalWorkerSource.includes('return ($ire > 0 && $ire <= 10.0001) ? 1 : 0;') &&
    autocalWorkerSource.includes('sub low_shadow_luminance_priority_adjustments') &&
    autocalWorkerSource.includes('my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);') &&
	    autocalWorkerSource.includes('my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,1);') &&
		    autocalWorkerSource.includes('sub autocal_config_is_touchup') &&
		    autocalWorkerSource.includes('return 1 if($de <= ($target_delta+0.5));') &&
			    autocalWorkerSource.includes('return 3 if($ire <= 3.1);') &&
			    autocalWorkerSource.includes('return 5 if($ire <= 5.1);') &&
			    autocalWorkerSource.includes('return 8 if($ire <= 3.1);') &&
			    autocalWorkerSource.includes('return 16 if($ire <= 5.1);') &&
    autocalWorkerSource.includes('sub low_shadow_delta_acceptance') &&
    autocalWorkerSource.includes('sub low_shadow_luminance_acceptance_percent') &&
	    autocalWorkerSource.includes('sub low_shadow_luminance_close_enough') &&
	    autocalWorkerSource.includes('return $score if(autocal_uses_itp());') &&
	    autocalWorkerSource.includes('return ($de <= ($target_delta+0.25)) ? 1 : 0;') &&
	    autocalWorkerSource.includes('(($ire <= 5.1001) ? ($target_delta+0.35)') &&
	    autocalWorkerSource.includes('(($ire <= 7.5001) ? ($target_delta+0.25) : ($target_delta+0.20))') &&
    autocalWorkerSource.includes('sub low_shadow_itp_near_target_reached') &&
    autocalWorkerSource.includes('sub low_shadow_good_enough') &&
    autocalWorkerSource.includes('sub committed_low_shadow_good_enough') &&
    autocalWorkerSource.includes('(($ire <= 7.5001) ? ($target_delta+0.30) : ($target_delta+0.25))') &&
    autocalWorkerSource.includes('if(low_shadow_good_enough($step,$best_de,$best_lum_pct,$target_delta))') &&
	    autocalWorkerSource.includes('return 1 if($ire <= 3.1001 && ($iter||0) >= 2 && ($stalls||0) >= 1);') &&
    autocalWorkerSource.includes('!low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta)') &&
    autocalWorkerSource.includes('next if(committed_low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));') &&
    autocalWorkerSource.includes('my $best_de=$de;') &&
    autocalWorkerSource.includes('$de=$best_de;') &&
    autocalWorkerSource.includes('last if(committed_low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta));') &&
    autocalWorkerSource.includes('sub body_itp_near_target_reached') &&
    autocalWorkerSource.includes('return 1 if(body_itp_near_target_reached($step,$de,$lum_pct,$target_delta));') &&
    autocalWorkerSource.includes('return 0 if(body_itp_near_target_reached($step,$de,undef,$target_delta));') &&
    autocalWorkerSource.includes('return 1 if(($iter||0) >= 8 && ($stalls||0) >= 3);') &&
    autocalWorkerSource.includes('return 1 if(low_shadow_itp_near_target_reached($step,$de,$lum_pct,$target_delta));') &&
    autocalWorkerSource.includes('$adjustments=low_shadow_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,$read_step,0);') &&
    autocalWorkerSource.includes('choose_rgb_response_adjustments($err,$arrays,$target,\\%rgb_response_model,\\%tried_values,$de,$read_step,$target_delta,$stalls) if(!$adjustments);') &&
    autocalWorkerSource.includes('if(autocal_uses_itp()) {\n  return $target_delta;\n }') &&
    autocalWorkerSource.includes('my $low_delta_allow=autocal_uses_itp() ? 0 : (($ire <= 10) ? 0.75 : 0.30);') &&
    autocalWorkerSource.includes('return 1 if(autocal_step_is_low_shadow($step) && $de <= low_shadow_delta_acceptance($step,$target_delta));') &&
    autocalWorkerSource.includes('my $shadow_limit=low_shadow_iteration_limit_for_step($step,$config);') &&
    autocalWorkerSource.includes('my $shadow_polish_limit=low_shadow_polish_limit_for_step($read_step,$config);') &&
    autocalWorkerSource.includes('$adj->{"low_shadow_luminance"}=1') &&
    autocalWorkerSource.includes('sub median_autocal_readings') &&
	    autocalWorkerSource.includes('sub low_shadow_sample_count_for_step') &&
		    autocalWorkerSource.includes('return 1 if($ire <= 5.1001);') &&
		    autocalWorkerSource.includes('return 2 if($ire <= 5.1001);') &&
		    autocalWorkerSource.includes('return 1 if($ire <= 10.0001);') &&
		    autocalWorkerSource.includes('sub low_shadow_sample_read_timeout') &&
		    autocalWorkerSource.includes('return 30 if(autocal_config_is_touchup($config) && $ire <= 3.1001);') &&
		    autocalWorkerSource.includes('return 55 if($ire <= 5.0001);') &&
    autocalWorkerSource.includes('$payload->{"read_timeout"}=int($opts->{"read_timeout"});') &&
	    autocalWorkerSource.includes('read_step_once($config,$step,$sample,{ read_timeout=>$sample_timeout, low_shadow_sample=>1 })') &&
	    autocalWorkerSource.includes('sub invalid_low_shadow_reading') &&
	    autocalWorkerSource.includes('abs($x-0.333333) < 0.0002') &&
	    autocalWorkerSource.includes('my $max_sample_attempts=$sample_count+2;') &&
	    autocalWorkerSource.includes('Discarding invalid low-shadow sample') &&
		    autocalWorkerSource.includes('sub force_low_shadow_luminance_adjustment') &&
	    autocalWorkerSource.includes('forced_luminance=>1') &&
	    autocalWorkerSource.includes('disable_low_shadow_median') &&
	    autocalWorkerSource.includes('my $threshold=$tol*($micro ? 0.70 : 1.00);') &&
	    autocalWorkerSource.includes('sub high_low_stride_steps') &&
	    autocalWorkerSource.includes('my @body=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { !$reserved{format_percent($_->{"ire"})} } @valid;') &&
	    autocalWorkerSource.includes('return (@top,@body,@shadow);') &&
	    autocalWorkerSource.includes('Settling panel before low-shadow greyscale calibration'),
	  'LG Auto Cal shadow points should stabilize low-level reads and stop luminance steering once Y is close enough for RGB polish'
	);
assert(
  !autocalWorkerSource.includes('return $white_y if($stimulus >= 100);') &&
    !autocalWorkerSource.includes('return undef if((defined($stimulus) && $stimulus >= 100) || (defined($ire) && $ire >= 100));') &&
    autocalWorkerSource.includes('$signal=1.1 if($signal > 1.1);') &&
    autocalWorkerSource.includes('return 1 if($ire >= 99.9 && !defined($lum_pct));') &&
    autocalWorkerSource.includes('return 1 if($ire >= 99.9 && !defined($best_lum_pct));') &&
    !autocalWorkerSource.includes('$luminance_err=0 if($ire >= 99.9);') &&
    autocalWorkerSource.includes('$luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));') &&
    autocalWorkerSource.includes('return 8 if($ire >= 105);') &&
    autocalWorkerSource.includes('105%+ are headroom/chroma points. Let luminance steer them only when') &&
    autocalWorkerSource.includes('sub headroom_luminance_control_gate_percent') &&
    autocalWorkerSource.includes('return $tol if(autocal_step_is_peak_headroom($step));') &&
	    autocalWorkerSource.includes('my $headroom_score=headroom_autocal_result_score($de,$reading,$step);') &&
	    autocalWorkerSource.includes('$headroom_score+=$penalty;') &&
		    autocalWorkerSource.includes('my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried);') &&
	    autocalWorkerSource.includes('sub headroom_chroma_adjustment') &&
	    autocalWorkerSource.includes('headroom_chroma=>1') &&
	    autocalWorkerSource.includes('sub headroom_rgb_luminance_adjustments') &&
	    autocalWorkerSource.includes('headroom_rgb_luminance=>1') &&
	    autocalWorkerSource.includes('sub headroom_green_luminance_adjustment') &&
	    autocalWorkerSource.includes('brightness_luminance=>1') &&
	    autocalWorkerSource.includes('green_luminance=>1') &&
	    autocalWorkerSource.includes('The LG 1D LUT upload treats RGB white-balance arrays as chroma-only') &&
	    autocalWorkerSource.includes('$adj->{"headroom_luminance"}=1') &&
	    autocalWorkerSource.includes('sub headroom_match_green_adjustment') &&
	    autocalWorkerSource.includes('match_green=>1') &&
	    autocalWorkerSource.includes('return undef if($adj->{"green_luminance"} || $adj->{"brightness_luminance"} || $adj->{"match_green"});') &&
	    autocalWorkerSource.includes('sub derived_white_reference_from_peak_headroom') &&
	    autocalWorkerSource.includes('sub apply_peak_headroom_reference') &&
	    autocalWorkerSource.includes('$$white_y_ref=$derived if(defined($derived) && $derived > 0);') &&
	    autocalWorkerSource.includes('$state->{"headroom_target_luminance"}=$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE;') &&
	    autocalWorkerSource.includes('$state->{"peak_headroom_reference"}=$effective_white if(defined($effective_white));') &&
	    autocalWorkerSource.includes('if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_tol && $chroma_mag < 0.035)') &&
	    autocalWorkerSource.includes('my $luma_gate=headroom_luminance_control_gate_percent($step,0.45);') &&
	    autocalWorkerSource.includes('if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_gate && $chroma_mag < 0.030)') &&
	    autocalWorkerSource.includes('if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > headroom_luminance_control_gate_percent($step,0.20))') &&
	    autocalWorkerSource.includes('headroom_luminance_control_gate_percent($read_step,0.65)') &&
		    autocalWorkerSource.includes('apply_peak_headroom_reference($state,$read_step,$best_reading,\\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);'),
		  'LG Auto Cal should target 105% and 109% extended Y from the setup headroom model'
		);
		assert(
		  autocalWorkerSource.includes('sub autocal_delta_target_luminance_for_step') &&
		    autocalWorkerSource.includes('if(autocal_step_is_fast_headroom($step))') &&
		    autocalWorkerSource.includes('return $Y if(defined($Y) && $Y > 0);') &&
		    autocalWorkerSource.includes('autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y)'),
		  'LG Auto Cal headroom Delta E scoring should ignore luminance error by targeting the measured 105%+ Y'
		);
		assert(
		  autocalWorkerSource.includes('my $allow=$target_delta+0.20;') &&
		    autocalWorkerSource.includes('legal_white_pair_spread_limit($target_delta)+0.12') &&
		    autocalWorkerSource.includes('$restore_best_branch->("Backtracking to best $label result after rejected adjustment");') &&
		    autocalWorkerSource.includes('return 0 if(($iter||0) < 6 || ($stalls||0) < 2);') &&
		    autocalWorkerSource.includes('return 1 if(($iter||0) >= 4 && ($stalls||0) >= 1 && $best_de <= ($target_delta+0.25));') &&
		    autocalWorkerSource.includes('return 1 if(($iter||0) >= 5 && ($stalls||0) >= 2);') &&
		    autocalWorkerSource.includes('sub neutral_luminance_step_cap_for_target') &&
		    autocalWorkerSource.includes('return 0.5 if($ire > 10.0001 && $ire <= 25.0001);') &&
		    autocalWorkerSource.includes('if($ire > 10.0001 && $ire <= 35.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.75))') &&
		    autocalWorkerSource.includes('if($ire > 35.0001 && $ire <= 50.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.80))'),
		  'LG Auto Cal should stop stalled near-target slots quickly and damp low-mid luminance moves instead of chasing worse reads'
		);
		assert(
		  source.includes('const statusTargetY=Number(status.target_luminance||status.calibrated_white_luminance);') &&
		    source.includes("synthetic.name='Auto Cal 100% target';") &&
		    source.indexOf("meterWhiteReading=synthetic;") <
		      source.indexOf('else if(white) meterWhiteReading=white;'),
		  'LG Auto Cal charts should keep the AutoCal target white as the RGB/DeltaE reference during a run'
		);
		assert(
		  source.includes('patch_insert:document.getElementById(\'meterPatchInsert\').checked') &&
	    autocalWorkerSource.includes('$config->{"patch_insert"}') &&
	    autocalWorkerSource.includes('my $insert_error=apply_pattern_insert_before_read($config,$step);'),
	  'LG Auto Cal should honor the Pattern Insertion checkbox during worker reads'
	);
	assert(
	  autocalWorkerSource.includes('$state->{"current_name"}="Auto Cal complete";') &&
	    autocalWorkerSource.indexOf('$state->{"message"}="Auto Cal complete";') <
	      autocalWorkerSource.indexOf('if($calibration_mode_active) {') &&
	    autocalWorkerSource.indexOf('write_state($state);', autocalWorkerSource.indexOf('$state->{"message"}="Auto Cal complete";')) <
	      autocalWorkerSource.indexOf('if($calibration_mode_active) {') &&
	    autocalWorkerSource.includes('Reading final 0% black') &&
	    autocalWorkerSource.includes('Final 0% black read complete'),
		  'LG Auto Cal should write complete/cancelled state before CAL_END cleanup so the UI does not report a completed run as process-died'
		);
	{
	  const finalBlackIdx = autocalWorkerSource.indexOf('Final 0% black read complete');
	  const finalCommitCallIdx = autocalWorkerSource.indexOf('commit_final_1d_lut($state,$picture,$arrays,$picture_mode,\\@ordered,$calibration_mode_active)', finalBlackIdx);
	  const commitMarksEndedIdx = autocalWorkerSource.indexOf('$calibration_mode_active=0 if($commit_ended_calibration);', finalCommitCallIdx);
	  const postCommitPolishCallIdx = autocalWorkerSource.indexOf('committed_state_polish(', commitMarksEndedIdx);
	  const postCommitPolishArgsEnd = autocalWorkerSource.indexOf(');', postCommitPolishCallIdx);
	  const postCommitPolishArgs = postCommitPolishCallIdx >= 0 && postCommitPolishArgsEnd > postCommitPolishCallIdx
	    ? autocalWorkerSource.slice(postCommitPolishCallIdx, postCommitPolishArgsEnd)
	    : '';
	  const finalCompleteIdx = autocalWorkerSource.indexOf('$state->{"status"}="complete";', commitMarksEndedIdx);
	  assert(
		      autocalWorkerSource.includes('sub commit_final_1d_lut') &&
		      autocalWorkerSource.includes('Uploading final 1024-point LG 1D LUT') &&
	      autocalWorkerSource.includes('Final 1D LUT uploaded, verified, and calibration mode ended') &&
	      autocalWorkerSource.includes('Final LG 1D LUT was not uploaded because calibration mode was not active') &&
	      autocalWorkerSource.includes('$state->{"final_1d_lut_uploaded"}=JSON::PP::true;') &&
	      autocalWorkerSource.includes('$state->{"final_1d_lut_upload_verified"}=JSON::PP::true;') &&
	      autocalWorkerSource.includes('LG DDC 1D LUT upload did not verify against the TV readback') &&
      autocalWorkerSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,0)') &&
      autocalWorkerSource.includes('end_calibration_mode($picture_mode);') &&
      autocalWorkerSource.includes('$calibration_mode_active=0 if($commit_ended_calibration);') &&
	      autocalWorkerSource.includes('verify_ddc_upload => $verify_ddc_upload ? JSON::PP::true : JSON::PP::false') &&
		      lgSource.includes('ddc_upload_verified') &&
	      finalBlackIdx > -1 &&
	      finalCommitCallIdx > finalBlackIdx &&
	      commitMarksEndedIdx > finalCommitCallIdx,
	    'LG Auto Cal should upload the final 1024-point 1D LUT and end calibration mode in the final verified write'
	  );
	  assert(
		    autocalWorkerSource.includes('sub post_commit_polish_enabled') &&
		      autocalWorkerSource.includes('sub start_calibration_mode') &&
		      autocalWorkerSource.includes('sub committed_state_polish') &&
		      autocalWorkerSource.includes(',$target_delta,$polish_steps)=@_;') &&
		      autocalWorkerSource.includes('Committed polish skipped: no 100% white reference step was available') &&
		      autocalWorkerSource.includes('my $candidate_steps=(ref($polish_steps) eq "ARRAY") ? $polish_steps : $steps;') &&
		      autocalWorkerSource.includes('return ($picture,undef) if(!post_commit_polish_enabled($config));') &&
		      autocalWorkerSource.includes('sub committed_polish_reference_white_y') &&
		      autocalWorkerSource.includes('$state->{"committed_white_luminance"}=$committed_white_y') &&
		      autocalWorkerSource.includes('Starting fresh LG calibration mode for committed polish writes') &&
		      autocalWorkerSource.includes('start_calibration_mode($picture_mode,$state,"Committed polish calibration mode enabled")') &&
		      autocalWorkerSource.includes('exists($config->{"post_commit_body_polish"})') &&
		      autocalWorkerSource.includes(': (autocal_config_is_touchup($config) ? 0 : 1);') &&
	    autocalWorkerSource.includes('grep { ($_->{"ire"}+0) >= 95 } @polish_candidates') &&
	    autocalWorkerSource.includes('my @polish=$include_body ? (@headroom,@shadow,@body) : (@headroom,@shadow);') &&
			      autocalWorkerSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1)') &&
			      autocalWorkerSource.includes('trace_109($read_step,"committed_polish_read"') &&
			      autocalWorkerSource.includes('trace_109($read_step,"committed_polish_adjustment"') &&
			      autocalWorkerSource.includes('trace_109($read_step,"committed_polish_measurement"') &&
			      autocalWorkerSource.includes('choose_micro_adjustments($err,$arrays,$target,$lum_err,\\%tried_values,0.25,$best_de,$stalls,$read_step,$target_delta)') &&
	      autocalWorkerSource.includes('sub post_commit_low_shadow_adjustments') &&
		      autocalWorkerSource.includes('my $rgb_cap=($ire <= 4.1001) ? 0.20 : (($ire <= 5.1001) ? 0.25 : 0.5);') &&
	      autocalWorkerSource.includes('$adjustments=post_commit_low_shadow_adjustments($adjustments,$read_step,$lum_pct) if(autocal_step_is_low_shadow($read_step));') &&
			      autocalWorkerSource.includes('Settling panel before committed low-shadow polish') &&
		      autocalWorkerSource.includes('post_commit_low_shadow_iterations') &&
		      autocalWorkerSource.includes('post_commit_true_low_shadow') &&
		      autocalWorkerSource.includes('Reading committed $label with calibration mode off') &&
		      autocalWorkerSource.includes('Committed verify $label ".describe_adjustments($adjustments)') &&
		      autocalWorkerSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,0,1)') &&
		      autocalWorkerSource.includes('trace_109($read_step,"committed_low_shadow_measurement"') &&
		      !autocalWorkerSource.includes('return 0 if($config->{"full_workflow"} && ($config->{"full_autocal_phase"}||"") eq "first-greyscale");') &&
	      source.includes("post_commit_polish:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?true:undefined") &&
	      source.includes("post_commit_body_polish:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?false:undefined") &&
			      source.includes("post_commit_low_shadow_iterations:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?6:undefined") &&
			      source.includes("post_commit_low_shadow_committed_iterations:(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)?6:undefined") &&
	      autocalWorkerSource.includes('end_calibration_mode($picture_mode);') &&
		      autocalWorkerSource.includes('Settling post-polish committed state before completion') &&
		      autocalWorkerSource.includes('park_black_for_settle($config,$state,"Settling post-CAL_END committed state before completion");') &&
		      autocalWorkerSource.includes('Final 1D LUT commit result: ended_calibration=') &&
		      autocalWorkerSource.includes('($commit_ended_calibration || $state->{"final_1d_lut_uploaded"})') &&
		      postCommitPolishArgs.includes('$steps,') &&
		      postCommitPolishArgs.includes('\\@ordered') &&
		      !autocalWorkerSource.includes('sub committed_state_polish {\n my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta)=@_;\n return ($picture,undef);\n') &&
		      postCommitPolishCallIdx > commitMarksEndedIdx &&
	      finalCompleteIdx > postCommitPolishCallIdx,
	    'LG Auto Cal should run committed-state polish after CAL_END, bracket DDC polish writes in CAL mode, and settle before reporting completion'
	  );
	}
assert(
	  source.includes('id="meterAutoCalResultsBox"') &&
    !source.includes('id="meterAutoCalDoneBtn"') &&
    !source.includes('>Done</button>') &&
	    source.includes('function meterAutoCalSummaryRows(status)') &&
	    source.includes('rd.autocal_white_reference||rd.autocal_reference_only') &&
	    source.includes('function meterAutoCalRenderResults(status)') &&
    source.includes('function meterAutoCalScheduleCompleteAutoClose(postReportAvailable)') &&
    !source.includes('meterAutoCalCompleteAutoCloseTimer=setTimeout') &&
    source.includes('function meterAutoCalCloseComplete()') &&
    source.includes("meterAutoCalSetOverlay(true,{...r,phase:'complete'}") &&
    source.includes("Highest ΔE points: "),
  'LG Auto Cal should show a completion popup with result summary'
);
assert(
		  source.includes('function meterBuildLgAutoCalSteps(steps,includeWhiteReference)') &&
		    source.includes("meterSeriesSteps=meterBuildStepsJS('greyscale',26);") &&
		    source.includes('autocal_slot_locked:true') &&
		    source.includes("String(step.series_mode||'')==='lg-autocal-26'||step.autocal_white_reference||step.autocal_slot_locked") &&
		    source.includes('const METER_LG_GREY_STIMULUS_22=') &&
		    source.includes('const METER_LG_GREY_AUTOCAL_26_SLOTS=') &&
		    source.includes('const METER_LG_GREY_AUTOCAL_26_CODES=') &&
    source.includes('@ire_vals=(0,2.5,5,7.5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100)') &&
    source.includes('@ire_vals=(100,0,2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109)') &&
	    source.includes('const lgSlotLocked=meterUseLgGreyscale21(points);') &&
	    source.includes('meterLgDdcStepHasCustomStimulus(step,slot)') &&
	    source.includes('const entry=entryBySlot[v]||meterGreyNormalizeEntry(v,null);') &&
	    source.includes('my $grey_custom_allowed=$grey_custom_enabled ? 1 : 0;') &&
    autocalWorkerSource.includes('sub ddc_step_signal_mismatch') &&
    autocalWorkerSource.includes('$config->{"strict_lg_autocal_slot_signal"}') &&
    autocalWorkerSource.includes('LG Auto Cal slot is using'),
	  'LG Auto Cal/manual LG DDC mode should preserve 2.6.1 custom greyscale stimulus values while marking DDC slots and recover cached AutoCal runs as 26pt'
);
assert(
  source.includes('meterAutoCalRunning||meterActionPending') &&
    source.includes('meterAutoCalRunning||meterActionPending||meterLgGreyBusy') &&
    source.includes('setInterval(meterPollAutoCal,1500)') &&
    source.includes("r.status==='running'||meterAutoCalPolling||meterAutoCalPhase==='running'") &&
    source.includes('function meterAutoCalBackendRecoveryWatchdog()') &&
    source.includes('meterPollAutoCal({initial:true,recover:true,timeoutMs:15000})') &&
    source.includes('setInterval(meterAutoCalBackendRecoveryWatchdog,15000)'),
  'LG Auto Cal should keep/recover the running UI from backend worker status without over-polling while calibration writes are blocking'
);
assert(
  source.includes('$result=&webui_cec($cec_cmd);') &&
    source.includes('cec-status-direct') &&
    source.includes('cec-scan-cache') &&
    source.includes('cec-cache') &&
    source.includes('cec-status-background') &&
    source.includes('/tmp/pgenerator-cec-power.json') &&
    source.includes('timeout $timeout $cec_bin status') &&
    source.includes('timeout 8 "$cec" scan-json') &&
    !source.includes('($now - $_cec_cache_time) >= $_CEC_CACHE_TTL'),
  'CEC status should use bounded direct power reads before falling back to cached/unknown state'
);
assert(
  source.includes('&webui_meter_read_state_write(\'{"status":"idle","message":"Measurement stopped"}\');') &&
    source.includes('/tmp/spotread_session_*') &&
    source.includes('/api/meter/session/stop') &&
    source.includes('sub webui_meter_session_stop_only') &&
    source.includes('{"status":"ok","message":"Meter session reset"}'),
  'Meter stop should clear stale starting state and persistent session temp files'
);
assert(
  lgSource.includes('sub lg_picture_get_workflow (@)') &&
    lgSource.includes('$tv_input=lc($tv_input);') &&
    lgSource.includes('picture_get:panel-light-scoped') &&
    lgWebSource.includes('tv_input => &lg_input_from_cec()'),
  'LG panel-light reads should prefer the active HDMI/picture-mode scoped value'
);
assert(
  source.includes('const targetStep=meterClonePatchStep(selectedStep);') &&
    source.includes('const selectedStep=meterClonePatchStep(meterCurrentPatchStep);') &&
    source.includes('meterPauseContinuousForPriorityWrite(targetStep)') &&
    source.includes('meterCurrentPatchStep=meterClonePatchStep(targetStep)||targetStep') &&
    source.includes('meterContinuousReadInFlight') &&
    !source.includes('meterStopContinuous({silent:true})') &&
    !source.includes('meterDisplayPatch(targetStep,{fresh:false})') &&
    !source.includes('meterCurrentPatchStep=meterFreshSeriesStep(targetStep)||targetStep'),
  'LG RGB writes should snapshot the selected greyscale patch and suspend continuous reads without restarting the meter session'
);
assert(
  source.includes('const requestedStep=meterClonePatchStep(meterCurrentPatchStep);') &&
    source.includes('meterDisplayPatch(resolvedStep,{fresh:false})') &&
    !source.includes('meterCurrentPatchStep=meterFreshSeriesStep(meterCurrentPatchStep)||meterCurrentPatchStep;'),
  'Manual Read Once/Continuous should measure the selected patch snapshot without freshening the selection first'
);
assert(
  source.includes("throw new Error('LG TV reported '+readback+' after the panel-light write.')") &&
    source.includes('readback_keys:[key]'),
  'LG panel-light UI should reject mismatched readback so Auto Cal can try the next OLED/backlight key'
);
assert(
  source.includes('id="meterAutoCalLuminanceFill" style="height:100%;width:0%;background:#fff;'),
  'LG Auto Cal luminance setup bar should render as plain white'
);
assert(
  source.includes('.meter-series-control-layout{display:flex;flex-direction:column;align-items:stretch') &&
    source.includes('#meterReadBtnRow{width:100%;justify-content:flex-end') &&
    source.includes('<div class="meter-series-control-layout">') &&
    source.includes('<div class="meter-series-selector-panel">'),
  'Meter series selector rows should keep full width when Read Once / Continuous buttons appear'
);
assert(
  source.includes('id="meterAutoCalPanelLightRange"') &&
    source.includes('id="meterAutoCalPanelLightInput"') &&
    source.includes('oninput="meterAutoCalSchedulePanelLightCommit(this.value,false)"') &&
    source.includes('onchange="meterAutoCalSchedulePanelLightCommit(this.value,true)"') &&
    source.includes('oninput="meterAutoCalSyncPanelLightRange(this.value)"') &&
    !source.includes('data-meter-autocal-brightness="1"') &&
    source.includes('let meterAutoCalLuminanceReadBusy=false;') &&
    source.includes('let meterAutoCalPanelLightQueuedDelta=0;') &&
    source.includes('let meterAutoCalPanelLightQueuedValue=null;') &&
    source.includes('let meterAutoCalPanelLightCommitTimer=null;') &&
    source.includes('function meterAutoCalPanelLightQueuePending()') &&
    source.includes('const disablePanelLight=meterAutoCalLuminanceSetupActive?false:busy;') &&
    source.includes("document.querySelectorAll('[data-meter-autocal-panel-light]').forEach") &&
    source.includes('function meterAutoCalApplyPanelLightValue(value,skipMeterStop)') &&
    source.includes('function meterAutoCalCommitPanelLight(value)') &&
    source.includes('meterAutoCalPanelLightQueuedValue=next;') &&
    source.includes('function meterAutoCalProcessQueuedPanelLight()') &&
    source.includes('function meterAutoCalSeedPanelLightFromDisplayControl()') &&
    source.includes('function meterAutoCalSetPanelLight(panel)') &&
    source.includes('meterAutoCalProcessQueuedPanelLight();') &&
    source.includes("lgBeginCommand('LG TV panel-light adjustment')") &&
    source.includes("await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000})") &&
    !source.includes('let cancelledForPanelLight=false;') &&
    !source.includes('if(await meterAutoCalProcessQueuedPanelLight())') &&
    source.includes('meterAutoCalLuminanceReadBusy=true;') &&
    source.includes('input.disabled=disablePanelLight||unavailable') &&
    source.includes("panelBusy?' (updating...)':(queued?' (queued...)':'')"),
  'LG Auto Cal panel-light slider and number input should queue absolute values without interrupting live luminance reads'
);
assert(
  source.includes('.diag-custom-picker button[onclick^="diagPlaySelectedAsset"]::before') &&
    source.includes('border-left:10px solid currentColor') &&
    source.includes('.diag-custom-picker button[onclick="stopPattern()"]::before') &&
    source.includes('width:10px;height:10px'),
  'Diagnostic custom asset play/stop buttons should use explicit CSS icon geometry instead of font glyph sizes'
);
assert(
  source.includes('let meterAutoCalLuminanceScaleMax=0;') &&
    source.includes('function meterAutoCalLuminanceScaleFor(y)') &&
    source.includes('value>meterAutoCalLuminanceScaleMax'),
  'LG Auto Cal luminance scale should stay fixed after startup and only expand when readings exceed the bar'
);
assert(
  source.includes('_timeoutMs:90000'),
  'LG RGB writes should allow enough time for slow webOS 1D LUT uploads'
);
assert(
  source.includes('function lgBeginCommand(label)') &&
    source.includes('noteLgBusyConnectionDelay()') &&
    source.includes("lgBeginCommand('LG TV '+target.label+' '+channelLabel+' adjustment')") &&
    source.includes("lgBeginCommand('LG TV panel-light adjustment')"),
  'LG TV writes should expose a visible busy state and suppress unrelated connection-error toasts'
);
assert(
  source.includes('meter-lg-rgb-busy') &&
    source.includes('function meterGreyTvBusyHtml()') &&
    source.includes('syncMeterLgRgbBusyIndicator()'),
  'LG RGB white-balance widget should show the LG command busy state during manual adjustments'
);
assert(
  source.includes('function meterLgPictureModeValue(fallback)') &&
    source.includes("typeof lgSelectedPictureModeValue==='function'") &&
    source.includes('picture_mode:meterLgPictureModeValue(nextPicture.pictureMode||') &&
    source.includes('picture_mode:meterLgPictureModeValue(),') &&
    !source.includes("picture_mode:(typeof lgPictureModeValue!=='undefined'&&lgPictureModeValue)"),
  'LG meter writes should use the selected picture-mode dropdown instead of a stale cached mode'
);
assert(
  source.includes('function meterGreyTvApplyInput(channel,button)') &&
    source.includes('class="btn btn-sm btn-secondary meter-lg-rgb-apply"') &&
    source.includes('const ok=await meterGreySetCurrentStepChannel(channel,input.value);') &&
    !source.includes('onchange="meterGreySetCurrentStepChannel') &&
    !source.includes('class="meter-lg-rgb-tv">TV <input'),
  'LG RGB value inputs should apply only on Enter or the adjacent check button, with no TV prefix label'
);
assert(
  source.includes('function meterGreyTvLuminanceHtml(tvValue,disabled,readOnly)') &&
    source.includes('meter-lg-rgb-luma') &&
    source.includes('meter-lg-rgb-luma-tv') &&
    source.includes('meter-lg-rgb-luma-arrow-left') &&
    source.includes('meter-lg-rgb-luma-arrow-right') &&
    source.includes('data-channel="lum"') &&
    source.includes("onclick=\"meterGreyTvApplyInput('lum',this)\"") &&
    source.includes("case 'lum':") &&
    source.includes("case 'brightness': return 'adjustingLuminance';") &&
    source.includes('const METER_LG_GREY_TV_MENU_STEP=1;') &&
    source.includes('return METER_LG_GREY_TV_MENU_STEP;') &&
    source.includes('function meterGreyTvWholeMenuValue(value)') &&
    source.includes('return meterGreyTvWholeMenuValue(entry);') &&
    source.includes('const current=meterGreyTvWholeMenuValue(sourceArray[target.index]);') &&
    source.includes('const next=meterGreyTvWholeMenuValue(nextRaw);') &&
    source.includes("onclick=\"meterGreyAdjustCurrentStepChannel('lum',-1)\"") &&
    source.includes("onclick=\"meterGreyAdjustCurrentStepChannel('lum',1)\"") &&
    source.includes('if(arrays.adjustingLuminance) settingsPayload.adjustingLuminance=arrays.adjustingLuminance;') &&
    source.includes('meterGreyTvLuminanceHtml(selected?selected.lum:null,disabled,ddcReadOnly)'),
  'LG 22pt manual controls should expose the per-point brightness/adjustingLuminance array as a horizontal control'
);
assert(
  source.includes('function meterGreyTvColumnHtml(channelKey,label,color,tvValue,liveEntry,halfRange,disabled,readOnly)') &&
    source.includes('const ddcReadOnly=!!(target&&target.force_ddc);') &&
    source.includes("if(target.force_ddc){toast('LG 26pt AutoCal DDC offsets are read-only. Start AutoCal to adjust them.',true);return false;}") &&
    source.includes('meter-lg-rgb-column is-readonly') &&
    source.includes("if(readOnly) return '';") &&
    source.includes('<div class="meter-lg-rgb-live">${meterGreyTvFormatLiveValue(liveEntry)}</div>') &&
    !source.includes('meter-lg-rgb-offset') &&
    !source.includes('DDC luminance offset') &&
    source.includes("meterGreyTvColumnHtml('r','R','#f44',selected?selected.r:null,meterGreyTvLiveEntry(spec,'R'),halfRange,disabled,ddcReadOnly)") &&
    source.includes('meterGreyTvLuminanceHtml(selected?selected.lum:null,disabled,ddcReadOnly)'),
  'LG 26pt AutoCal should show read-only RGB bars and percentages without DDC value or luminance controls'
);
assert(
  source.includes('function meterSeriesSnapshotIsCleared(snap)') &&
    source.includes("status:'cleared'") &&
    source.includes('if(exact&&meterSeriesSnapshotIsCleared(exact)') &&
    source.includes('readings.length===0&&prev&&meterSeriesSnapshotIsCleared(prev)') &&
    source.includes('meterSeriesSnapshotCanRestore(meterSeriesCache[lastKey])'),
  'Cleared meter series should stay cleared instead of being reconstructed from another greyscale series cache'
);
assert(
  lgWebSource.includes('id="lgCardTitle"') &&
    lgWebSource.includes('id="lgDisplayControlOpenBtn"') &&
    lgWebSource.includes('#lgCardTitle::after{margin-left:0}') &&
    !lgWebSource.includes('id="lgPictureResetBtn"'),
  'Display card should put Display Control in the card header and avoid exposing a separate Reset Mode button'
);
assert(
  source.includes('force_ddc_white_balance:true') &&
    autoCalDdcResetSource.includes('adjustingLuminance:zero') &&
    autoCalDdcResetSource.includes('force_ddc_white_balance:true') &&
    lgWebSource.includes('force_ddc_white_balance => $payload->{"force_ddc_white_balance"} ? &lg_json_true() : &lg_json_false()') &&
    lgSource.includes('my $force_ddc_white_balance=$request->{"force_ddc_white_balance"}||$request->{"ddc_white_balance"} ? 1 : 0;') &&
    autocalWorkerSource.includes('force_ddc_white_balance => JSON::PP::true') &&
    autocalWorkerSource.includes('"adjustingLuminance"') &&
    autocalWorkerSource.includes('sub has_luminance_channel') &&
    autocalWorkerSource.includes('my $luminance_drive=has_luminance_channel($arrays,$target) ? 0 : luminance_adjustment_drive($luminance_err);') &&
    lgSource.includes('+ &lg_ddc_interpolated_offset_at_index($i,$luminance,$baseline,$channel)') &&
    lgSource.includes('adjustingLuminance => &lg_ddc_normalize_rgb_array($settings->{"adjustingLuminance"}),'),
  'LG AutoCal should force DDC writes and use adjustingLuminance as a per-point luma channel in the 1D LUT'
);
assert(
  source.includes('function meterAutoCalSyncLgGreyState(status,currentKey)') &&
    source.includes("meterLgGreyState={status:'ok',picture:picture,message:'',needsRepair:false};") &&
    source.includes('meterAutoCalSyncLgGreyState(status,currentKey);') &&
    autocalWorkerSource.includes('sub sync_state_picture') &&
    autocalWorkerSource.includes('sync_state_picture($state,$picture,$picture_mode);') &&
    autocalWorkerSource.includes('$state->{"picture_settings"}=clone_picture($picture);'),
  'LG Auto Cal status should publish DDC picture settings and refresh the manual RGB value boxes'
);
assert(
  source.includes('function meterReadingUsesAlternateStimulus(reading,step)') &&
    source.includes('function meterReadingMatchesStepForPlot(reading,step)') &&
    source.includes('function meterReadingPlotIre(reading)') &&
    source.includes('return meterReadingMatchesStepForPlot(reading,step);') &&
    source.includes('nominal_r_code') &&
    source.includes('patch_stimulus') &&
    source.includes('reading.plot_ire=step.ire') &&
    source.includes('map[plotIre]=rd') &&
	    source.includes('meterReadingMatchesStepForPlot(rd,s)') &&
	    source.includes('meterReadingMatchesStepForPlot(rd,canon)') &&
	    source.includes('function meterGreyChartTargetCode(step)') &&
	    source.includes('if(!meterChartIsHdr()&&!meterGreyAllowsHeadroomTargets()) return null;') &&
	    source.includes('function meterGreyNominalTargetCurvePoints') &&
	    source.includes("meterGreyNominalTargetCurvePoints(targetPeak,Lb,yTop,'eotf',axisMax,plotSteps)") &&
	    source.includes("meterGreyNominalTargetCurvePoints(targetPeak,Lb,yTop,'luminance',axisMax,plotSteps)") &&
	    source.includes('function meterGreyTargetEotfChartValue(ire,Lw,Lb,code)') &&
	    source.includes('meterEotfNormalizedEnabled()') &&
	    source.includes('id="meterEotfLogScale"') &&
	    source.includes('id="meterLuminanceLogScale"') &&
	    source.includes('id="meterHdrDiffuseWhite"') &&
	    source.includes('function meterEotfLogScaleEnabled()') &&
	    source.includes('function meterLuminanceLogScaleEnabled()') &&
	    source.includes('const METER_HDR_DIFFUSE_WHITE_DEFAULT=94.4;') &&
	    source.includes('function meterHdrDiffuseWhiteOverride()') &&
	    source.includes('function meterApplyHdrDiffuseOverridePeak(peak)') &&
	    source.includes('function meterOnHdrDiffuseWhiteChange()') &&
	    source.includes("hdr_diffuse_white: v('meterHdrDiffuseWhite')") &&
	    source.includes("setVal('meterHdrDiffuseWhite', p.hdr_diffuse_white)") &&
	    source.includes('function meterGreyTargetPeakForReadings(readings,steps,fallbackPeak,Lb)') &&
	    source.includes('meterGreySolvePeakFromHeadroomReading(meterGreyHeadroomReferenceReading(readings),steps,fallbackPeak,Lb)') &&
	    source.includes('targetPeak=meterGreyTargetPeakForReadings(sorted,plotSteps.length?plotSteps:targetSteps,targetPeak,Lb);') &&
	    source.includes('const code=meterGreyChartTargetCode(s);') &&
	    source.includes('const targetIre=meterGreyChartStimulusIre(s);') &&
	    source.includes('meterGreyTargetEotfChartValue(targetIre,targetPeak,Lb,code)') &&
	    source.includes('meterGreyTargetChartValue(targetIre,targetPeak,Lb,code)') &&
	    source.includes('function effectiveGammaTopSlope') &&
	    source.includes('if(frac>=0.999999) return null;') &&
	    source.includes('if(topGamma) return;') &&
	    source.includes('function meterGammaValueWhiteReference(readings)') &&
	    source.includes('function meterGammaValueReferenceY(readings)') &&
	    source.includes('function meterGreyscaleGammaValue(reading,whiteY)') &&
	    source.includes('const gammaYw=meterGammaValueReferenceY(sortedAll);') &&
	    source.includes('const chartYw=meterChartIsHdr()?meterGreyTargetPeakForReadings(sortedAll,rawXSteps,gammaYw||Yw||measuredPeak,Lb):(gammaYw||Yw||measuredPeak);') &&
	    source.includes('meterGreyscaleGammaValue(rd,chartYw)') &&
	    source.includes('const gamma=meterGreyscaleGammaValue(rd,meterGammaValueReferenceY(meterGreyscaleReadings(meterReadings)));') &&
	    source.includes('meterGreyTargetGamma(analysisIre,chartYw,Lb') &&
	    source.includes('if((Number(step.ire)||0)>=100 || (targetIre||0)>=100) return;') &&
	    source.includes('topGamma && (meterChartIsHdr()||meterChartIsDv())') &&
	    autocalWorkerSource.includes('$reading->{"plot_ire"}=$step->{"ire"}') &&
	    autocalWorkerSource.includes('$reading->{"patch_ire"}=$step->{"stimulus"}'),
	  'Shifted Auto Cal patch readings should remain attached to the nominal chart slot without warping SDR target curves'
	);
assert(
    source.includes('function meterGammaAxisCenteredOnTarget') &&
    source.includes('function meterLgAutoCalChartReferenceWhite(item)') &&
    source.includes('function meterFilterLgAutoCalChartItems(items)') &&
    source.includes('const visibleSteps=meterFilterLgAutoCalChartItems(sortedSteps);') &&
    source.includes('meterSeriesThumbsUseScroll(visibleSteps.length)') &&
    source.includes('function meterFilterEotfLuminanceChartItems(items)') &&
    source.includes('function meterEotfLuminanceAxisMax(items)') &&
    source.includes('function meterGreyEotfLuminanceChartX(step,steps,idx,axisMax)') &&
    source.includes('const ire=meterGreyChartPlotIre(step);') &&
    source.includes('const plotSteps=meterFilterEotfLuminanceChartItems(targetSteps);') &&
    source.includes('const validG=meterFilterEotfLuminanceChartItems(sorted).filter') &&
    source.includes('xSteps:axisMax/10,ySteps:5') &&
    source.includes('const allStepsRaw=meterSeriesSteps?meterGreyscaleSeriesSteps(meterSeriesSteps):null;') &&
    source.includes('const allSteps=allStepsRaw?meterFilterLgAutoCalChartItems(allStepsRaw):null;') &&
    source.includes('const gs=meterFilterLgAutoCalChartItems(rawGs);') &&
    source.includes('const white=meterGreyscaleChartWhiteReference(sorted);') &&
    source.includes('const center=targets.length') &&
    source.includes('return {min:center-half,max:center+half};') &&
	    source.includes('let yMin=95,yMax=105;') &&
    source.includes("meterApplyLinearYZoom('chartRGB',yMin,yMax,100)") &&
		    source.includes('const halfRange=Math.max(5') &&
	    source.includes('function meterEnsureChartYZoomInput(canvas)') &&
	    source.includes('function meterChartPointerIsOnYAxis(canvas,e)') &&
	    source.includes('function meterChartYZoomIsActive(id)') &&
	    source.includes('if(!meterChartYZoomIsActive(id)) return {min:lo,max:hi};') &&
	    source.includes("localStorage.removeItem('pgen.meter.chartYZoom')") &&
	    source.includes("id!=='chartCIE'") &&
	    source.includes("canvas.addEventListener('wheel'") &&
	    source.includes('if(!meterChartPointerIsOnYAxis(canvas,e)) return;') &&
	    source.includes('if(!meterChartPointerIsOnYAxis(canvas,e.touches[0])) return;') &&
	    source.includes("canvas.addEventListener('touchmove'") &&
	    source.includes("meterApplyTopYZoom('chartEOTF'") &&
	    source.includes("meterApplyTopYZoom('chartGamma'") &&
	    source.includes("meterApplyTopYZoom('chartDeltaE'") &&
	    source.includes("meterApplyTopYZoom('chartColorDE'") &&
	    source.includes("meterApplyLinearYZoom('chartGammaValue'") &&
	    source.includes('meterLoadChartYZoom();') &&
	    source.includes('function meterUseLgAutoCal26GammaAxis') &&
    source.includes('function meterFilterGammaChartItems') &&
    source.includes('if(!meterUseLgAutoCal26GammaAxis()) return list;') &&
    source.includes('return Number.isFinite(ire) && ire>0 && ire<99;') &&
    source.includes('function meterGreyscaleInteractionStepsForChart') &&
    source.includes("if(canvasId==='chartEOTF'||canvasId==='chartGamma') return meterFilterEotfLuminanceChartItems(list);") &&
    source.includes("if(canvasId==='chartGammaValue') return meterFilterGammaChartItems(list);") &&
    source.includes('const chartSteps=meterGreyscaleInteractionStepsForChart(cid,xStepsBase);') &&
    source.includes('const xNorm=meterGreyscaleInteractionXForChart(cid,step,chartSteps,idx);') &&
    source.includes('const gammaFixedAxis=meterUseLgAutoCal26GammaAxis();') &&
    source.includes('const steps=meterFilterGammaChartItems(sourceSteps).filter(s=>{') &&
	    source.includes('const targetIre=meterGreyChartStimulusIre(s);') &&
	    source.includes('const sorted=gammaFixedAxis?meterFilterGammaChartItems(sortedAll):sortedAll;') &&
	    source.includes('const gammaYw=meterGammaValueReferenceY(sortedAll);') &&
	    source.includes('const chartYw=meterChartIsHdr()?meterGreyTargetPeakForReadings(sortedAll,rawXSteps,gammaYw||Yw||measuredPeak,Lb):(gammaYw||Yw||measuredPeak);') &&
	    source.includes('xSteps:gammaFixedAxis?10:(xSteps.length-1||1)') &&
	    source.includes("xLabel:(i)=>gammaFixedAxis?String(i*10):(i<xSteps.length?meterGreyscaleChartLabel(xSteps[i],xSteps,i):'')") &&
	    source.includes('rd._gamma_rgb=meterPerChannelGamma(rd,white,meterReadingAnalysisIre(rd)||rd.ire||0,prev);') &&
    source.includes('if(ire>=100){') &&
    !source.includes('const gTop=Math.log(pm/w)/Math.log(prevIre/100);'),
  'Greyscale charts should center gamma on target, omit LG 26pt gamma headroom tracking, and keep RGB balance no tighter than 95-105'
);

assert(
    !source.includes('const whiteR=gs.find(r=>r.ire===100);\n if(!whiteR) return;'),
  'Greyscale chart hover hit zones must not require a literal 100% reading, because the LG 26pt AutoCal series can omit 100%'
);

function extractConst(name) {
  const token = `const ${name}=`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing const ${name}`);
  let i = start;
  while (i < source.length && source[i] !== ';') i++;
  return source.slice(start, i + 1);
}

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing function ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

{
  const eotfContext = {};
  vm.createContext(eotfContext);
  vm.runInContext([
    `
      let normalizedChecked = true;
      let logChecked = false;
      let luminanceLogChecked = false;
      const document = {
        getElementById: (id) => {
          if (id === 'meterEotfNormalized') return { checked: normalizedChecked };
          if (id === 'meterEotfLogScale') return { checked: logChecked };
          if (id === 'meterLuminanceLogScale') return { checked: luminanceLogChecked };
          return null;
        }
      };
      function meterGreyTargetEotfValue(){ return 0.42; }
      function meterGreyTargetNormalizedEotfValue(){ return 0.84; }
      function meterGreyMeasuredEotfValue(){ return 0.5; }
      function meterGreyMeasuredNormalizedEotfValue(){ return 0.8; }
    `,
    extractFunction('meterEotfNormalizedEnabled'),
    extractFunction('meterEotfLogScaleEnabled'),
    extractFunction('meterLuminanceLogScaleEnabled'),
    extractConst('METER_CHART_LOG_KNEE_DIVISOR'),
    extractFunction('meterLogScaleValue'),
    extractFunction('meterLogUnscaleValue'),
    extractFunction('meterEotfScaleValue'),
    extractFunction('meterEotfUnscaleValue'),
    extractFunction('meterLuminanceScaleValue'),
    extractFunction('meterLuminanceUnscaleValue'),
    extractFunction('meterLuminanceAxisLabel'),
    extractFunction('meterEotfAxisLabel'),
    extractFunction('meterGreyTargetEotfChartValue'),
    extractFunction('meterGreyMeasuredEotfChartValue'),
    extractFunction('meterEotfChartTop'),
    `
      globalThis.normalizedTarget = meterGreyTargetEotfChartValue(50,100,0,null);
      globalThis.normalizedMeasured = meterGreyMeasuredEotfChartValue(80,100);
      globalThis.normalizedTop = meterEotfChartTop([0.5,1]);
      normalizedChecked = false;
      globalThis.absoluteTarget = meterGreyTargetEotfChartValue(50,100,0,null);
      globalThis.absoluteMeasured = meterGreyMeasuredEotfChartValue(80,100);
      globalThis.absoluteTop = meterEotfChartTop([0.5,0.7]);
      globalThis.absoluteLabel = meterEotfAxisLabel(0.8);
      logChecked = true;
      const scaled = meterEotfScaleValue(0.5,0.8);
      globalThis.absoluteLogScaled = scaled;
      globalThis.absoluteLogRoundTrip = meterEotfUnscaleValue(scaled,0.8);
      luminanceLogChecked = true;
      const lumaScaled = meterLuminanceScaleValue(50,200);
      globalThis.lumaLogScaled = lumaScaled;
      globalThis.lumaLogRoundTrip = meterLuminanceUnscaleValue(lumaScaled,200);
      globalThis.lumaLowScaled = meterLuminanceScaleValue(0.15,260);
      globalThis.lumaLowLabel = meterLuminanceAxisLabel(meterLuminanceUnscaleValue(1/5,260));
    `
  ].join('\n'), eotfContext);
  assert.strictEqual(eotfContext.normalizedTarget, 0.84, 'Normalized EOTF chart should use peak-normalized target values');
  assert.strictEqual(eotfContext.normalizedMeasured, 0.8, 'Normalized EOTF chart should use peak-normalized measured values');
  assert(eotfContext.normalizedTop <= 1.15, 'Normalized EOTF chart should keep normalized axis scaling');
  assert.strictEqual(eotfContext.absoluteTarget, 0.42, 'Non-normalized EOTF chart should use absolute perceptual EOTF target values');
  assert.strictEqual(eotfContext.absoluteMeasured, 0.5, 'Non-normalized EOTF chart should plot absolute perceptual EOTF measured values');
  assert(eotfContext.absoluteTop <= 1.15, 'Non-normalized EOTF chart should stay on the perceptual EOTF axis instead of duplicating cd/m2 luminance');
  assert.strictEqual(eotfContext.absoluteLabel, '0.80', 'Non-normalized EOTF chart should label the perceptual EOTF axis');
  assert(eotfContext.absoluteLogScaled > (0.5 / 0.8), 'EOTF log scale should expand lower chart values while preserving targets/dots together');
  assert(Math.abs(eotfContext.absoluteLogRoundTrip - 0.5) < 1e-9, 'EOTF log scale should round-trip through the axis label transform');
  assert(eotfContext.lumaLogScaled > (50 / 200), 'Luminance log scale should expand lower cd/m2 chart values');
  assert(Math.abs(eotfContext.lumaLogRoundTrip - 50) < 1e-9, 'Luminance log scale should round-trip through the axis label transform');
  assert(eotfContext.lumaLowScaled > 0.19, 'Luminance log scale should keep sub-5% SDR targets visible instead of flattening them at the floor');
  assert(/0\.[0-9]+/.test(eotfContext.lumaLowLabel), 'Luminance log axis should label sub-1 cd/m2 ticks instead of rounding them to zero');
}

{
  const diffuseContext = {};
  vm.createContext(diffuseContext);
  vm.runInContext([
    `
      let signalMode = 'hdr10';
      let diffuseValue = '';
      let displayTypeValue = 'ccss_ProjectorFamily_07Feb11.ccss';
      let meterCcssLibrary = [{ source: 'system', name: 'ProjectorFamily_07Feb11.ccss', technology: 'Projector' }];
      const document = {
        getElementById: (id) => {
          if (id === 'meterHdrDiffuseWhite') return { value: diffuseValue };
          if (id === 'meterDisplayType') return { value: displayTypeValue };
          return null;
        }
      };
      function meterChartIsPq(){ return signalMode === 'hdr10' || signalMode === 'dv'; }
      function meterChartIsDv(){ return signalMode === 'dv'; }
      function meterChartHdrPeak(){ return 1000; }
      function meterChartMasterPeak(){ return 1000; }
      function meterGreyHeadroomReferenceReading(){ return {}; }
      function meterGreySolvePeakFromHeadroomReading(){ return 50; }
    `,
    extractConst('METER_HDR_DIFFUSE_WHITE_DEFAULT'),
    extractFunction('meterDisplayTypeIsProjector'),
    extractFunction('meterHdrDiffuseWhiteOverride'),
    extractFunction('meterHdrDiffuseScale'),
    extractFunction('meterApplyHdrDiffuseOverridePeak'),
    extractFunction('meterGreyTargetPeak'),
    extractFunction('meterGreyTargetPeakForReadings'),
    `
      globalThis.defaultPeak = meterGreyTargetPeak(200);
      diffuseValue = '47.2';
      globalThis.scaledPeak = meterGreyTargetPeak(200);
      globalThis.scaledFallback = meterGreyTargetPeakForReadings([{ ire: 109, luminance: 100 }], [{ ire: 109 }], 200, 0);
      displayTypeValue = 'oled_generic';
      globalThis.nonProjectorPeak = meterGreyTargetPeak(200);
      displayTypeValue = 'ccss_ProjectorFamily_07Feb11.ccss';
      signalMode = 'sdr';
      globalThis.sdrPeak = meterGreyTargetPeak(200);
      signalMode = 'hdr10';
      diffuseValue = '';
      globalThis.unsolvedFallback = meterGreyTargetPeakForReadings([{ ire: 109, luminance: 100 }], [{ ire: 109 }], 200, 0);
    `
  ].join('\n'), diffuseContext);
  assert.strictEqual(diffuseContext.defaultPeak, 200, 'Blank diffuse white override should keep the current HDR target peak');
  assert(Math.abs(diffuseContext.scaledPeak - 100) < 1e-9, 'Diffuse white override should scale PQ targets relative to 94.4 cd/m2');
  assert.strictEqual(diffuseContext.scaledFallback, 200, 'Diffuse override should keep the explicit scaled target instead of re-solving from headroom reads');
  assert.strictEqual(diffuseContext.nonProjectorPeak, 200, 'Diffuse white override should not affect non-projector display profiles');
  assert.strictEqual(diffuseContext.sdrPeak, 200, 'Diffuse white override should not alter SDR targets');
  assert.strictEqual(diffuseContext.unsolvedFallback, 50, 'Without diffuse override, headroom reads may still derive the chart target peak');
}

{
  const headroomContext = {};
  vm.createContext(headroomContext);
  vm.runInContext([
    `
      let meterActiveSeriesType = 'greyscale';
      let meterActiveSeriesPoints = 26;
      let meterActiveSeriesSignalMode = 'sdr';
      let luminanceLogChecked = true;
      const document = { getElementById: (id) => id === 'meterLuminanceLogScale' ? { checked: luminanceLogChecked } : ({ value: 'bt1886' }) };
      function meterGreyTvControlsActive(){ return true; }
      function meterChartSignalMode(){ return 'sdr'; }
      function meterChartIsHdr(){ return false; }
      function meterChartIsPq(){ return false; }
      function meterChartIsHlg(){ return false; }
      function meterChartIsDv(){ return false; }
      function meterHdrDiffuseWhiteOverride(){ return null; }
      function meterDvMapModeValue(){ return '0'; }
      function meterDvRelativeSt2084UsesLegalRange(){ return false; }
      function meterPatchUsesVideoRange(){ return true; }
      function meterPatchRangeMin(){ return 16; }
      function meterPatchRangeSpan(){ return 219; }
      function meterChartHdrPeak(){ return 1000; }
      function meterNormalizeMeasuredReading(){}
    `,
    extractFunction('meterReadingLuminanceNits'),
    extractFunction('meterReadingHasLuminance'),
    extractFunction('meterUseLgAutoCal26'),
    extractFunction('meterGreyAllowsHeadroomTargets'),
    extractFunction('meterGreyCodeRange'),
    extractFunction('meterGreySignalFractionFromCode'),
    extractFunction('meterGreyStimulusFraction'),
    extractFunction('meterGreyTargetSignal'),
    extractFunction('bt1886Eotf'),
    extractFunction('gammaEotf'),
    extractFunction('srgbEotf'),
    extractFunction('targetEotf'),
    extractFunction('meterChartTrackingLuminance'),
    extractFunction('meterChartTargetLuminance'),
    extractFunction('meterGreyTargetLuminance'),
    extractFunction('meterGreyTargetChartValue'),
    extractFunction('meterGreyChartTargetCode'),
    extractFunction('meterGreyHeadroomReferenceReading'),
    extractFunction('meterGreyStepCodeForIre'),
    extractFunction('meterGreySolvePeakFromHeadroomReading'),
    extractFunction('meterGreyTargetPeakForReadings'),
    extractFunction('meterGreyChartStimulusIre'),
    extractFunction('meterGreyChartPlotIre'),
    extractFunction('meterLuminanceLogScaleEnabled'),
    extractConst('METER_CHART_LOG_KNEE_DIVISOR'),
    extractFunction('meterLogScaleValue'),
    extractFunction('meterLuminanceScaleValue'),
    extractFunction('meterEotfLuminanceAxisMax'),
    extractFunction('meterGreyEotfLuminanceChartX'),
    extractFunction('meterFilterEotfLuminanceChartItems'),
    extractFunction('meterGreyDenseTargetCurvePoints'),
    extractFunction('meterGreyNominalTargetCurvePoints'),
    `
      const steps = [{ ire: 99 }, { ire: 105 }, { ire: 109 }];
      const lowSteps = [{ ire: 0, r: 64 }, { ire: 2.3, r: 84 }, { ire: 3, r: 92 }, { ire: 4, r: 100 }, { ire: 5, r: 108 }, { ire: 7, r: 124 }, { ire: 10, r: 152 }];
      globalThis.frac23 = meterGreySignalFractionFromCode(84);
      globalThis.frac3 = meterGreySignalFractionFromCode(92);
      globalThis.frac109 = meterGreySignalFractionFromCode(1023);
      globalThis.y23 = meterGreyTargetLuminance(2.3, 200, 0, 84);
      globalThis.y3 = meterGreyTargetLuminance(3, 200, 0, 92);
      globalThis.y100 = meterGreyTargetLuminance(100, 200, 0, null);
      globalThis.y105 = meterGreyTargetLuminance(105, 200, 0, 984);
      globalThis.y109 = meterGreyTargetLuminance(109, 200, 0, 1023);
      globalThis.derivedPeak = meterGreyTargetPeakForReadings([{ ire: 109, luminance: 205.74, r_code: 1023 }], steps, 184, 0);
      globalThis.derivedY109 = meterGreyTargetLuminance(109, globalThis.derivedPeak, 0, 1023);
      globalThis.whiteAnchoredPeak = meterGreyTargetPeakForReadings([{ ire: 100, luminance: 184 }, { ire: 109, luminance: 205.74, r_code: 1023 }], steps, 184, 0);
      globalThis.axisMax = meterEotfLuminanceAxisMax(steps);
      globalThis.filteredCount = meterFilterEotfLuminanceChartItems(steps).length;
      globalThis.x109 = meterGreyEotfLuminanceChartX({ ire: 109 }, steps, 2, globalThis.axisMax);
      meterActiveSeriesPoints = 21;
      globalThis.axisMax22 = meterEotfLuminanceAxisMax(steps);
      globalThis.filteredCount22 = meterFilterEotfLuminanceChartItems(steps).length;
      const manual22 = { ire: 2.5, plot_ire: 2.5, analysis_ire: 7.3059, target_ire: 7.3059 };
      globalThis.manual22Stimulus = meterGreyChartStimulusIre(manual22);
      globalThis.manual22X = meterGreyEotfLuminanceChartX(manual22, [manual22], 0, 100);
      meterActiveSeriesPoints = 26;
      const logCurve = meterGreyNominalTargetCurvePoints(200, 0, 260, 'luminance', 110, lowSteps);
      globalThis.lowLogCurveLength = logCurve.length;
      const fiveX = 5 / 110;
      const fivePoint = logCurve.find(p => Math.abs(p[0] - fiveX) < 1e-9);
      globalThis.lowLogCurveFive = fivePoint ? fivePoint[1] : null;
      globalThis.lowLogCurveFiveTarget = meterLuminanceScaleValue(meterGreyTargetLuminance(5, 200, 0, 108), 260);
      const end23 = logCurve.find(p => Math.abs(p[0] - (2.3 / 110)) < 1e-9);
      const halfLow = logCurve.find(p => Math.abs(p[0] - (1.15 / 110)) < 0.00001);
      globalThis.lowLogCurveHalf = halfLow ? halfLow[1] : null;
      globalThis.lowLogCurveStraightHalf = end23 ? end23[1] / 2 : null;
    `
  ].join('\n'), headroomContext);
  assert(Math.abs(headroomContext.frac23 - ((84 - 64) / 876)) < 1e-9, 'LG 26pt low 10-bit codes should not be decoded as 8-bit video values');
  assert(Math.abs(headroomContext.frac3 - ((92 - 64) / 876)) < 1e-9, 'LG 26pt 3% target should use its 10-bit AutoCal code');
  assert(headroomContext.frac109 > 1.09, 'LG 26pt 109% code should decode as headroom above 100%');
  assert(headroomContext.y23 < headroomContext.y3 && headroomContext.y3 < 1, 'LG 26pt low target dots should stay near black instead of jumping up the EOTF curve');
  assert.strictEqual(Math.round(headroomContext.y100), 200, '100% target luminance should stay anchored to measured peak');
  assert(headroomContext.y105 > headroomContext.y100, '105% should target luminance above 100%');
  assert(headroomContext.y109 > headroomContext.y105, '109% should target luminance above 105%');
  assert(headroomContext.derivedPeak < 184, 'Measured 109% should back-solve a lower 100% reference when headroom is below the old target curve');
  assert(Math.abs(headroomContext.derivedY109 - 205.74) < 0.02, 'Derived LG 26pt target curve should pass through the measured 109% anchor');
  assert.strictEqual(headroomContext.whiteAnchoredPeak, 184, 'Measured 100% white should keep LG 26pt SDR charts anchored instead of letting 109% redefine the whole luminance curve');
  assert.strictEqual(headroomContext.axisMax, 110, 'LG 26pt EOTF/Luminance charts should extend the x-axis to 110');
  assert.strictEqual(headroomContext.filteredCount, 3, 'LG 26pt EOTF/Luminance charts should include 99/105/109');
  assert(Math.abs(headroomContext.x109 - (109 / 110)) < 1e-9, '109% should plot at its proportional x position on the 110 axis');
  assert.strictEqual(headroomContext.axisMax22, 100, 'Non-AutoCal greyscale charts should keep the 100% EOTF/Luminance axis');
  assert.strictEqual(headroomContext.filteredCount22, 1, 'Non-AutoCal EOTF/Luminance charts should not plot headroom points');
  assert(Math.abs(headroomContext.manual22Stimulus - 7.3059) < 1e-9, 'LG 22pt EOTF/Luminance targets should still use the decoded stimulus value');
  assert(Math.abs(headroomContext.manual22X - 0.025) < 1e-9, 'LG 22pt EOTF/Luminance points should plot at the TV menu slot position');
  assert(headroomContext.lowLogCurveLength > 20, 'LG 26pt luminance log target should be densely sampled instead of drawing sparse straight low-end chords');
  assert(Math.abs(headroomContext.lowLogCurveFive - headroomContext.lowLogCurveFiveTarget) < 1e-9, 'Dense LG 26pt luminance log target should still pass through exact 5% code target');
  assert(headroomContext.lowLogCurveHalf < headroomContext.lowLogCurveStraightHalf * 0.75, 'Dense LG 26pt luminance log target should bend through the low-end EOTF instead of linearly connecting 0 to 2.3%');
}

{
  const headroomDeltaContext = {};
  vm.createContext(headroomDeltaContext);
  vm.runInContext([
    `
      function meterReadingIsGreyscale(){ return true; }
      function meterTargetWhitePoint(){ return { X: 0.95, Y: 1, Z: 1.09, x: 0.3127, y: 0.329 }; }
      function meterTargetXYZForReading(){ return { X: 218.5, Y: 230, Z: 250.7 }; }
      function meterReadingXYZ(){ return { X: 190, Y: 200, Z: 218 }; }
      function meterResolveGreyRefMode(mode){ return mode === true ? 'eotf' : String(mode || 'absolute'); }
      function meterChartIsHdr(){ return false; }
      function meterChartHdrPeak(){ return 1000; }
      function meterGreyTargetPeak(refWhite){ return refWhite > 0 ? refWhite : 1000; }
      function meterGreyTargetLuminance(){ return 999; }
      function meterBlackReadingY(){ return 0; }
      function meterAnalysisGamut(){ return { xyzToRgb: [[1,0,0],[0,1,0],[0,0,1]] }; }
    `,
    extractFunction('meterIreIsPeakHeadroom'),
    extractFunction('meterReadingIsPeakHeadroom'),
    extractFunction('meterColorDeltaTargetXYZ'),
    extractFunction('ynToLstar'),
    extractFunction('xyzToLinRgb'),
    extractFunction('rgbBalancePerceptual'),
    extractFunction('rgbBalanceHCFR'),
    extractFunction('hcfrGreyRef'),
    `
      const target109WithLum = meterColorDeltaTargetXYZ({ ire: 109, luminance: 200 }, true);
      const target109WithoutLum = meterColorDeltaTargetXYZ({ ire: 109, luminance: 200 }, false);
      const target105WithLum = meterColorDeltaTargetXYZ({ ire: 105, luminance: 200 }, true);
      const hcfr109 = hcfrGreyRef(109, 200, 180, 0, 'eotf', 1023, 1);
      const hcfr105 = hcfrGreyRef(105, 200, 180, 0, 'eotf', 984, 1);
      const perceptual109WithLum = rgbBalancePerceptual({ ire: 109, luminance: 200 }, {}, true);
      const perceptual109WithoutLum = rgbBalancePerceptual({ ire: 109, luminance: 200 }, {}, false);
      const perceptual105WithLum = rgbBalancePerceptual({ ire: 105, luminance: 200 }, {}, true);
      const perceptual105WithoutLum = rgbBalancePerceptual({ ire: 105, luminance: 200 }, {}, false);
      const hcfrRgb109WithLum = rgbBalanceHCFR({ ire: 109, luminance: 200 }, {}, true);
      const hcfrRgb109WithoutLum = rgbBalanceHCFR({ ire: 109, luminance: 200 }, {}, false);
      const hcfrRgb105WithLum = rgbBalanceHCFR({ ire: 105, luminance: 200 }, {}, true);
      const hcfrRgb105WithoutLum = rgbBalanceHCFR({ ire: 105, luminance: 200 }, {}, false);
      globalThis.y109WithLum = target109WithLum.Y;
      globalThis.y109WithoutLum = target109WithoutLum.Y;
      globalThis.y105WithLum = target105WithLum.Y;
      globalThis.hcfr109RefY = hcfr109.refY;
      globalThis.hcfr105RefY = hcfr105.refY;
      globalThis.perceptual109Stable = JSON.stringify(perceptual109WithLum) === JSON.stringify(perceptual109WithoutLum);
      globalThis.perceptual105ChangesWithLum = Math.abs(perceptual105WithLum.R - perceptual105WithoutLum.R) > 0.001;
      globalThis.hcfr109Stable = JSON.stringify(hcfrRgb109WithLum) === JSON.stringify(hcfrRgb109WithoutLum);
      globalThis.hcfr105ChangesWithLum = Math.abs(hcfrRgb105WithLum.R - hcfrRgb105WithoutLum.R) > 0.001;
    `
  ].join('\n'), headroomDeltaContext);
  assert.strictEqual(headroomDeltaContext.y109WithLum, 200, '109% ΔE with luminance enabled should use measured 109% Y as its luminance target');
  assert.strictEqual(headroomDeltaContext.y109WithoutLum, 200, '109% ΔE without luminance enabled should also use measured 109% Y');
  assert.strictEqual(headroomDeltaContext.y105WithLum, 230, '105% ΔE should still use the modeled luminance target when luminance is enabled');
  assert(Math.abs(headroomDeltaContext.hcfr109RefY - (200 / 180)) < 1e-9, 'HCFR-style 109% ΔE should also use measured 109% Y as the target luminance');
  assert(headroomDeltaContext.hcfr105RefY > 5, 'HCFR-style 105% ΔE should still use the modeled luminance target');
  assert(headroomDeltaContext.perceptual109Stable, 'Perceptual RGB balance for 109% should not change when Include luminance error is toggled');
  assert(headroomDeltaContext.perceptual105ChangesWithLum, 'Perceptual RGB balance for 105% should still include modeled luminance when requested');
  assert(headroomDeltaContext.hcfr109Stable, 'HCFR-style RGB balance for 109% should not change when Include luminance error is toggled');
  assert(headroomDeltaContext.hcfr105ChangesWithLum, 'HCFR-style RGB balance for 105% should still include modeled luminance when requested');
}

{
  const shiftedContext = {};
  vm.createContext(shiftedContext);
  vm.runInContext([
    extractFunction('meterReadingCodesMatchStep'),
    extractFunction('meterReadingNominalSlotMatchesStep'),
    extractFunction('meterReadingUsesAlternateStimulus'),
    extractFunction('meterReadingMatchesStepForPlot'),
    extractFunction('meterReadingPlotIre'),
    extractFunction('meterStampReadingStepMeta'),
    `
      const step={ire:80,stimulus:80,r:191,g:191,b:191,signal_r_pct:80,signal_g_pct:80,signal_b_pct:80,name:'80%',series_type:'greyscale'};
      const reading={ire:80,stimulus:78,r_code:187,g_code:187,b_code:187,signal_r_pct:78,signal_g_pct:78,signal_b_pct:78,name:'80%',luminance:42};
      const shiftedIreReading={ire:78,nominal_ire:80,plot_ire:80,stimulus:78,r_code:187,g_code:187,b_code:187,signal_r_pct:78,signal_g_pct:78,signal_b_pct:78,name:'78%',luminance:42};
      globalThis.shiftedMatches=meterReadingMatchesStepForPlot(reading,step);
      globalThis.shiftedIreMatches=meterReadingMatchesStepForPlot(shiftedIreReading,step);
      meterStampReadingStepMeta(reading,step);
      meterStampReadingStepMeta(shiftedIreReading,step);
      globalThis.shiftedReading=reading;
      globalThis.shiftedIreReading=shiftedIreReading;
    `
  ].join('\n'), shiftedContext);
  assert.strictEqual(
    shiftedContext.shiftedMatches,
    true,
    'Shifted patch reading should match its nominal chart slot'
  );
  assert.strictEqual(
    shiftedContext.shiftedReading.r_code,
    187,
    'Shifted patch reading should keep the actual emitted patch code'
  );
  assert.strictEqual(
    shiftedContext.shiftedReading.nominal_r_code,
    191,
    'Shifted patch reading should keep nominal slot code separately'
  );
  assert.strictEqual(
    shiftedContext.shiftedReading.patch_stimulus,
    78,
    'Shifted patch reading should keep the actual emitted patch stimulus'
  );
  assert.strictEqual(
    shiftedContext.shiftedIreMatches,
    true,
    'Shifted patch reading should match even when the read path reports the actual patch IRE'
  );
  assert.strictEqual(
    shiftedContext.shiftedIreReading.ire,
    80,
    'Shifted patch reading should be stamped back to the nominal chart IRE'
  );
}

{
  const scaleContext = {};
  vm.createContext(scaleContext);
  vm.runInContext([
    'let meterAutoCalLuminanceScaleMax=0;',
    extractFunction('meterAutoCalRoundLuminanceScale'),
    extractFunction('meterAutoCalLuminanceScaleFor'),
    'globalThis.scaleFirst=meterAutoCalLuminanceScaleFor(220);',
    'globalThis.scaleAfterDrop=meterAutoCalLuminanceScaleFor(190);',
    'globalThis.scaleAfterRise=meterAutoCalLuminanceScaleFor(305);'
  ].join('\n'), scaleContext);
  assert.strictEqual(
    scaleContext.scaleAfterDrop,
    scaleContext.scaleFirst,
    'Auto Cal luminance bar scale should not shrink when brightness drops'
  );
  assert(
    scaleContext.scaleAfterRise > scaleContext.scaleFirst,
    'Auto Cal luminance bar scale should expand when brightness exceeds the current range'
  );
}

const code = [
	  extractConst('METER_GREY_SLOTS_11'),
	  extractConst('METER_GREY_SLOTS_21'),
	  extractConst('METER_LG_GREY_DDC_SLOTS_22'),
	  extractConst('METER_LG_GREY_AUTOCAL_26_SLOTS'),
	  extractConst('METER_LG_GREY_AUTOCAL_26_CODES'),
	  extractConst('METER_LG_GREY_EXTENDED_26_CODES'),
	  extractConst('METER_LG_GREY_EXTENDED_26_SLOTS'),
	  extractConst('METER_LG_GREY_SERIES_SLOTS'),
	  extractConst('METER_LG_GREY_AUTOCAL_SERIES_SLOTS'),
	  extractConst('METER_LG_GREY_STIMULUS_22'),
  "let meterGreyPatchProfiles={format:'pgenerator-greyscale-profile-v2',apply_to_all_modes:false,profiles:{}};",
  extractFunction('clampNum'),
  extractFunction('meterDvMapModeValue'),
  extractFunction('meterDvAutoTargetGamma'),
  extractFunction('meterChartSignalMode'),
  extractFunction('meterChartIsDv'),
  extractFunction('meterFormatPercentValue'),
  extractFunction('meterIsLimitedRange'),
  extractFunction('meterOutputFormatValue'),
  extractFunction('meterOutputIsRgb'),
  extractFunction('meterExtendedVideoHeadroomRequired'),
  extractFunction('meterExtendedVideoTransportCanCarryHeadroom'),
  extractFunction('meterExtendedVideoTransportOk'),
  extractFunction('meterGreyscaleUsesFullSourceRange'),
  extractFunction('meterPatchUsesVideoRange'),
  extractFunction('meterPatchRangeMin'),
  extractFunction('meterPatchRangeSpan'),
  extractFunction('meterDvRelativeSt2084UsesLegalRange'),
  extractFunction('meterGreyCodeRange'),
  extractFunction('meterDvTunnelGamma'),
  extractFunction('meterCodeFromSignalPercent'),
  extractFunction('meterLgSdrExtendedCodeFromPercent'),
  extractFunction('meterLgSdrLegalHeadroomCodeFromPercent'),
  extractFunction('meterLgAutoCalStimulusFromCode'),
  extractFunction('meterLgAutoCalCodeForSlot'),
  extractFunction('meterLgSdrLegalDdcCodeFromPercent'),
  extractFunction('meterLgSdrLegalStimulusFromCode'),
  extractFunction('meterCodeFromSignalPercentWithOptions'),
	  extractFunction('meterGreyDefaultSlots'),
	  extractFunction('meterUseLgGreyscale21'),
	  extractFunction('meterUseLgAutoCal26'),
	  extractFunction('meterLgGreyscaleUsesExtendedSdr'),
  extractFunction('meterLgGreyscaleUsesLegalSdrDdcCodes'),
  extractFunction('meterLgAutoCalUsesExtendedSdr'),
  extractFunction('meterGreySeriesSlots'),
  extractFunction('meterGreyProfileSlots'),
  extractFunction('meterGreyClampPercent'),
  extractFunction('meterGreyPercentEquals'),
  extractFunction('meterGreyNormalizeEntry'),
  extractFunction('meterLgGreyDefaultEntry'),
  extractFunction('meterLgAutoCalDefaultEntry'),
  extractFunction('meterLgDdcStepHasCustomStimulus'),
  extractFunction('meterGreyProfileStepsKey'),
  extractFunction('meterGreyProfileTemplate'),
  extractFunction('meterGreyModeSignature'),
  extractFunction('meterGreyNormalizeProfilesState'),
  extractFunction('meterGreyActiveProfileKey'),
  extractFunction('meterGreyActiveProfile'),
  extractFunction('meterGreyProfileEntry'),
  extractFunction('meterGreySignalEntries'),
  extractFunction('meterSeriesStepIsGreyscale'),
  extractFunction('meterBuildStepsJS'),
  extractFunction('meterBuildLgAutoCalSteps'),
  extractFunction('meterMeasurementPatchSignalRange'),
  extractFunction('meterStepInputMax'),
  extractFunction('meterApplyReadStepPayload')
].join('\n\n');

const state = {
  signal_mode: 'sdr',
  rgb_quant_range: '2',
  color_format: '0',
  dv_map_mode: '2',
  meterTargetGamma: 'bt1886',
  meterTwoPointLow: '30',
  meterTwoPointHigh: '100',
  lgPaired: false
};

const context = {
  console,
  Math,
  config: { signal_mode: 'sdr', max_luma: '1000' },
  meterActiveSeriesType: 'greyscale',
  meterActiveSeriesPoints: 21,
  meterActiveSeriesSignalMode: 'sdr',
  document: {
    getElementById(id) {
      return { value: Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '' };
    }
  },
  getVal(id) {
    return Object.prototype.hasOwnProperty.call(state, id) ? state[id] : '';
  },
  meterGreyTvControlsActive() {
    return !!state.lgPaired;
  },
  meterSyncTwoPointInputs() {
    return { low: Number(state.meterTwoPointLow), high: Number(state.meterTwoPointHigh) };
  },
  meterBuildColorCheckerStepsJS() {
    return [];
  },
  meterBuildSaturationStepRgb() {
    return [0, 0, 0];
  }
};
context.window = context;
vm.createContext(context);
vm.runInContext(code, context);

function roundCode(value) {
  return Math.round(value);
}

function expectedGreyscaleCode(percent, opts) {
  const pct = Math.max(0, Math.min(100, Number(percent) || 0));
  const clamped = pct / 100;
  const limited = opts.range === '1';
  if (opts.mode === 'dv') {
    if (opts.dvMapMode === '1') {
      const legal = roundCode(16 + clamped * 219);
      if (limited) return legal;
      if (clamped <= 0) return 0;
      if (clamped >= 1) return 255;
      return legal;
    }
    if (opts.targetGamma === 'st2084') {
      return roundCode(16 + clamped * 219);
    }
    const encoded = clamped > 0 ? Math.pow(clamped, 1 / 2.2) : 0;
    return limited ? roundCode(16 + encoded * 219) : roundCode(encoded * 255);
  }
  return limited ? roundCode(16 + clamped * 219) : roundCode(clamped * 255);
}

function expectedLgExtendedSdrCode(percent) {
  const pct = Math.max(0, Math.min(100, Number(percent) || 0));
  return roundCode(16 + (pct / 100) * 239);
}

function expectedLgLegalDdcCode(percent) {
  const pct = Math.max(0, Math.min(100, Number(percent) || 0));
  if (pct <= 0) return 0;
  return roundCode(16 + (pct / 100) * 219);
}

function setMode(opts) {
  state.signal_mode = opts.mode;
  state.rgb_quant_range = opts.range;
  state.dv_map_mode = opts.dvMapMode || '2';
  state.meterTargetGamma = opts.targetGamma || (opts.mode === 'dv' ? 'st2084' : 'bt1886');
  context.meterActiveSeriesType = 'greyscale';
  context.meterActiveSeriesSignalMode = opts.mode;
  context.meterActiveSeriesPoints = opts.points || 21;
}

const modes = [
  { name: 'SDR', mode: 'sdr' },
  { name: 'HDR10', mode: 'hdr10' },
  { name: 'HLG', mode: 'hlg' },
  { name: 'DV absolute', mode: 'dv', dvMapMode: '1', targetGamma: '2.2' },
  { name: 'DV relative ST2084', mode: 'dv', dvMapMode: '2', targetGamma: 'st2084' },
  { name: 'DV relative gamma', mode: 'dv', dvMapMode: '2', targetGamma: '2.2' }
];
const series = [2, 11, 21, 100];

for (const mode of modes) {
  for (const range of ['1', '2']) {
    for (const points of series) {
      state.lgPaired = false;
      setMode({ ...mode, range, points });
      const steps = context.meterBuildStepsJS('greyscale', points);
      assert(steps.length > 0, `${mode.name} ${range} ${points}pt produced no steps`);
      for (const step of steps) {
        const expectedR = expectedGreyscaleCode(step.signal_r_pct, { ...mode, range });
        const expectedG = expectedGreyscaleCode(step.signal_g_pct, { ...mode, range });
        const expectedB = expectedGreyscaleCode(step.signal_b_pct, { ...mode, range });
        assert.strictEqual(step.r, expectedR, `${mode.name} range ${range} ${points}pt ${step.name} red code`);
        assert.strictEqual(step.g, expectedG, `${mode.name} range ${range} ${points}pt ${step.name} green code`);
        assert.strictEqual(step.b, expectedB, `${mode.name} range ${range} ${points}pt ${step.name} blue code`);
      }
    }
  }
}

state.lgPaired = true;
setMode({ mode: 'sdr', range: '1', points: 21 });
const lgSeries = context.meterBuildStepsJS('greyscale', 21);
const lgSteps = lgSeries
  .slice()
  .sort((a, b) => a.ire - b.ire)
  .map(step => step.ire);
assert.strictEqual(
  JSON.stringify(lgSteps),
  JSON.stringify([0, 2.5, 5, 7.5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]),
  'LG-connected manual greyscale should include black plus the TV 22-point white-balance slots'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 0).r,
  0,
  'LG manual 0% black reference should request true black'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 2.5).r,
  expectedLgExtendedSdrCode(6.7),
  'LG manual 2.5% slot should use the mapped LG control-anchor stimulus code'
);
assert(
  Math.abs(lgSeries.find(step => step.ire === 2.5).analysis_ire - ((expectedLgExtendedSdrCode(6.7) - 16) * 100 / 219)) < 0.0001,
  'LG manual 2.5% slot should analyze against the legal-video stimulus represented by the emitted code'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 100).analysis_ire,
  100,
  'LG manual 100% slot should still analyze as legal 100% even though it uses the mapped control-anchor stimulus'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 7.5).stimulus,
  11.3,
  'LG manual 7.5% slot should display the mapped LG control-anchor patch'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 10).stimulus,
  13.8,
  'LG manual 10% slot should display the mapped LG control-anchor patch'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 100).r,
  235,
  'LG manual 100% slot should use code 235 reference white rather than code 255 headroom'
);
const lgAutoCalDefault = context.meterBuildLgAutoCalSteps(lgSeries);
const lgAutoCal25 = lgAutoCalDefault.find(step => step.ire === 25);
assert(Math.abs(lgAutoCal25.stimulus - 25.1141552511416) < 0.0001, 'LG Auto Cal 25% patch should use the captured 10-bit 284 level');
assert.strictEqual(lgAutoCal25.r, 284, 'LG Auto Cal 25% patch should use exact captured raw 10-bit code 284');
assert.strictEqual(lgAutoCal25.input_max, 1023, 'LG Auto Cal 25% patch should declare 10-bit input max');
assert.strictEqual(lgAutoCal25.preview_r, 71, 'LG Auto Cal 25% thumbnail should use the 8-bit preview code 71');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 2.3).r, 84, 'LG Auto Cal 2.3% patch should use exact captured raw 10-bit code 84');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 50).r, 504, 'LG Auto Cal 50% patch should use exact captured raw 10-bit code 504');
assert(Math.abs(lgAutoCalDefault.find(step => step.ire === 50).stimulus - 50.2283105022831) < 0.0001, 'LG Auto Cal 50% patch should use the captured 10-bit 504 level');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 75).r, 720, 'LG Auto Cal 75% patch should use exact captured raw 10-bit code 720');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 95).r, 896, 'LG Auto Cal 95% patch should use exact captured raw 10-bit code 896');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 99).r, 932, 'LG Auto Cal 99% near-white patch should use exact captured raw 10-bit code 932');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 100), undefined, 'LG Auto Cal 26pt patch set should not add an extra writable 100% legal-white anchor');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 105).r, 984, 'LG Auto Cal 105% headroom patch should use exact captured raw 10-bit code 984');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 109).r, 1023, 'LG Auto Cal 109% top patch should use exact captured raw 10-bit code 1023');

state.lgPaired = false;
setMode({ mode: 'sdr', range: '1', points: 21 });
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 40).r,
  104,
  'legacy SDR limited 40% patch should stay on 16-235 video levels'
);

state.lgPaired = true;
setMode({ mode: 'sdr', range: '2', points: 21 });
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 35).r,
  expectedLgExtendedSdrCode(34.3),
  'LG manual full-range output should still request mapped LG control-anchor patches'
);
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 75).stimulus,
  68.6,
  'LG manual 75% slot should use the mapped LG patch stimulus'
);
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).some(step => Math.abs(step.ire - 97.9) < 0.001),
  false,
  'LG manual 22-point series should not expose AutoCal-only 26-point headroom patches'
);
assert.strictEqual(
  context.meterMeasurementPatchSignalRange(),
  '1',
  'LG manual 22-point greyscale reads should request video-range patch metadata'
);
state.color_format = '0';
state.rgb_quant_range = '1';
assert.strictEqual(
  context.meterExtendedVideoHeadroomRequired(),
  true,
	  'LG manual 22-point SDR should require video-code transport for mapped LG patches'
);
setMode({ mode: 'sdr', range: '2', points: 26 });
state.rgb_quant_range = '1';
assert.strictEqual(
  context.meterLgAutoCalUsesExtendedSdr(),
  true,
	  'LG Auto Cal should use the mapped LG SDR patch set'
);
assert.strictEqual(
  context.meterExtendedVideoTransportCanCarryHeadroom(),
  false,
  'RGB limited transport still cannot carry super-white headroom patches when a headroom series is active'
);
state.color_format = '1';
assert.strictEqual(
  context.meterExtendedVideoTransportCanCarryHeadroom(),
  true,
	  'YCbCr 4:4:4 limited transport can carry headroom patches when a headroom series is active'
);
state.rgb_quant_range = '2';
assert.strictEqual(
  context.meterExtendedVideoTransportCanCarryHeadroom(),
  false,
	  'Headroom patches should still require video/limited transport metadata'
);
state.rgb_quant_range = '2';
state.color_format = '0';
{
  const autoCalSteps = context.meterBuildLgAutoCalSteps(context.meterBuildStepsJS('greyscale', 21));
  const autoCalIres = autoCalSteps.map(step => step.ire).sort((a, b) => a - b);
		  assert.strictEqual(autoCalSteps.length, 27, 'LG Auto Cal should include black plus the captured nonzero patches');
	  assert(autoCalIres.includes(2.3) && autoCalIres.includes(109), 'LG Auto Cal should include the captured low and headroom endpoints');
	  assert(!autoCalIres.includes(2.5) && !autoCalIres.includes(100), 'LG Auto Cal should not use manual 22pt labels or add a writable legal-white slot');
	  assert.strictEqual(autoCalSteps.find(step => step.ire === 109).ddc_slot_locked, true, 'LG Auto Cal 109% should be a writable DDC LUT anchor');
	  assert.strictEqual(autoCalSteps.find(step => step.ire === 0).autocal_read_only, true, 'LG Auto Cal 0% should remain read-only black verification');
  const autoCalWorkerSteps = context.meterBuildLgAutoCalSteps([], true);
  const legalWhite = autoCalWorkerSteps.find(step => step.autocal_legal_white_anchor);
  assert(legalWhite, 'LG Auto Cal should carry a hidden legal-white worker anchor');
  assert.strictEqual(legalWhite.ire, 100, 'The hidden legal-white anchor should read the 100% legal-white patch');
  assert.strictEqual(legalWhite.ddc_target_ire, 99, 'The hidden legal-white anchor should write through the nearest LG 99% DDC slot');
  assert(legalWhite.autocal_order_ire < 99, 'The hidden legal-white anchor should run after the visible 99% headroom point');
}

state.lgPaired = false;
setMode({ mode: 'sdr', range: '2', points: 21 });
assert.strictEqual(
  context.meterMeasurementPatchSignalRange(),
  '2',
  'Non-LG SDR full-range greyscale reads should continue to request full source patch coding'
);

vm.runInContext(`
meterGreyPatchProfiles={
  format:'pgenerator-greyscale-profile-v2',
  apply_to_all_modes:true,
  profiles:{
    __all__:{
      enabled:true,
      steps_11:{},
      steps_21:{
        "20":{slot:20,stimulus:23,r:23,g:23,b:23},
        "25":{slot:25,stimulus:31,r:31,g:31,b:31}
      },
      steps_100:{}
    }
  }
};
`, context);
state.lgPaired = false;
setMode({ mode: 'sdr', range: '1', points: 21 });
const custom20 = context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 20);
assert.strictEqual(custom20.signal_r_pct, 23, 'Non-LG custom 21pt manual patches should still honor custom 20% stimulus');
assert.strictEqual(custom20.r, expectedGreyscaleCode(23, { mode: 'sdr', range: '1' }), 'Non-LG custom 20% source code should follow its custom stimulus');

state.lgPaired = true;
setMode({ mode: 'sdr', range: '1', points: 21 });
const customDdcSteps = context.meterBuildLgAutoCalSteps([{
  ire: 20,
  stimulus: 23,
  signal_r_pct: 23,
  signal_g_pct: 23,
  signal_b_pct: 23,
  r: expectedGreyscaleCode(23, { mode: 'sdr', range: '1' }),
  g: expectedGreyscaleCode(23, { mode: 'sdr', range: '1' }),
  b: expectedGreyscaleCode(23, { mode: 'sdr', range: '1' }),
  name: '20%',
  series_type: 'greyscale',
  autocal_slot_locked: true
}, {
  ire: 25,
  stimulus: 31,
  signal_r_pct: 31,
  signal_g_pct: 31,
  signal_b_pct: 31,
  r: expectedGreyscaleCode(31, { mode: 'sdr', range: '1' }),
  g: expectedGreyscaleCode(31, { mode: 'sdr', range: '1' }),
  b: expectedGreyscaleCode(31, { mode: 'sdr', range: '1' }),
  name: '25%',
  series_type: 'greyscale',
  autocal_slot_locked: true
}]);
const locked20 = customDdcSteps.find(step => step.ire === 20);
const locked25 = customDdcSteps.find(step => step.ire === 25);
assert(Math.abs(locked20.stimulus - 20.0913242009132) < 0.0001, 'LG Auto Cal 20% DDC write should use the captured raw 240 stimulus');
assert(Math.abs(locked20.signal_r_pct - 20.0913242009132) < 0.0001, 'LG Auto Cal 20% red source should use the captured raw 240 stimulus');
assert.strictEqual(locked20.r, 240, 'LG Auto Cal 20% source code should use the captured raw 10-bit code');
assert.strictEqual(locked20.input_max, 1023, 'LG Auto Cal 20% source should declare 10-bit input max');
assert.strictEqual(locked20.ddc_slot_locked, true, 'LG Auto Cal 20% step should be marked slot-locked');
assert(Math.abs(locked25.stimulus - 25.1141552511416) < 0.0001, 'LG Auto Cal 25% DDC write should use the captured raw 284 stimulus');

vm.runInContext("meterGreyPatchProfiles={format:'pgenerator-greyscale-profile-v2',apply_to_all_modes:false,profiles:{}};", context);

state.lgPaired = true;
setMode({ mode: 'sdr', range: '1', points: 21 });
const mismatchedAutoCalStep = context.meterBuildLgAutoCalSteps([{
  ire: 25,
  stimulus: 30,
  signal_r_pct: 30,
  signal_g_pct: 28,
  signal_b_pct: 26,
  r: expectedGreyscaleCode(30, { mode: 'sdr', range: '1' }),
  g: expectedGreyscaleCode(28, { mode: 'sdr', range: '1' }),
  b: expectedGreyscaleCode(26, { mode: 'sdr', range: '1' }),
  name: '25%',
  series_type: 'greyscale',
  autocal_slot_locked: true
}]).find(step => step.ire === 25);
assert(Math.abs(mismatchedAutoCalStep.stimulus - 25.1141552511416) < 0.0001, 'LG Auto Cal should replace custom 25% slot stimulus with the captured raw 284 stimulus');
assert(Math.abs(mismatchedAutoCalStep.signal_r_pct - 25.1141552511416) < 0.0001, 'LG Auto Cal should replace custom 25% red stimulus with the captured raw 284 stimulus');
assert(Math.abs(mismatchedAutoCalStep.signal_g_pct - 25.1141552511416) < 0.0001, 'LG Auto Cal should replace custom 25% green stimulus with the captured raw 284 stimulus');
assert(Math.abs(mismatchedAutoCalStep.signal_b_pct - 25.1141552511416) < 0.0001, 'LG Auto Cal should replace custom 25% blue stimulus with the captured raw 284 stimulus');
assert.strictEqual(mismatchedAutoCalStep.r, 284, 'LG Auto Cal should use the captured raw 10-bit 25% code');
assert.strictEqual(mismatchedAutoCalStep.autocal_slot_locked, true, 'LG Auto Cal should mark preserved slot-locked steps');

const readPayload = {};
context.meterApplyReadStepPayload(readPayload, {
  ire: 55,
  stimulus: 55,
  signal_r_pct: 55,
  signal_g_pct: 55,
  signal_b_pct: 55,
  r: expectedGreyscaleCode(55, { mode: 'sdr', range: '1' }),
  g: expectedGreyscaleCode(55, { mode: 'sdr', range: '1' }),
  b: expectedGreyscaleCode(55, { mode: 'sdr', range: '1' }),
  name: '55%',
  series_type: 'greyscale'
});
assert.strictEqual(readPayload.ire, 55, 'Manual reads should send selected IRE instead of deriving it from legal RGB code');
assert.strictEqual(readPayload.stimulus, 55, 'Manual reads should send selected stimulus');
assert.strictEqual(readPayload.patch_r, expectedGreyscaleCode(55, { mode: 'sdr', range: '1' }), 'Manual reads should still send the selected source code');

const prevLgPairedForInputMax = state.lgPaired;
const prevActivePointsForInputMax = context.meterActiveSeriesPoints;
const prevActiveTypeForInputMax = context.meterActiveSeriesType;
const prevActiveModeForInputMax = context.meterActiveSeriesSignalMode;
try {
  state.lgPaired = true;
  context.meterActiveSeriesType = 'greyscale';
  context.meterActiveSeriesPoints = 26;
  context.meterActiveSeriesSignalMode = 'sdr';
  const staleLg26Payload = {};
  context.meterApplyReadStepPayload(staleLg26Payload, {
    ire: 5,
    stimulus: 5.02283105022831,
    signal_r_pct: 5.02283105022831,
    signal_g_pct: 5.02283105022831,
    signal_b_pct: 5.02283105022831,
    r: 108,
    g: 108,
    b: 108,
    name: '5%',
    series_type: 'greyscale',
    series_mode: 'lg-autocal-26'
  });
  assert.strictEqual(staleLg26Payload.patch_r, 108, 'Stale LG 26pt manual read should keep the raw 10-bit code');
  assert.strictEqual(staleLg26Payload.input_max, 1023, 'Stale LG 26pt manual read should infer 10-bit input max');
} finally {
  state.lgPaired = prevLgPairedForInputMax;
  context.meterActiveSeriesPoints = prevActivePointsForInputMax;
  context.meterActiveSeriesType = prevActiveTypeForInputMax;
  context.meterActiveSeriesSignalMode = prevActiveModeForInputMax;
}

function rendererNormalizeSourceValue(value, opts) {
  if (opts.sourceRange !== 'LIMITED') return value;
  if (opts.outputFormat !== '0') return value;
  if (opts.mode !== 'dv' && opts.mode !== 'std_dv' && opts.transportRange !== '1') return value;
  const bitDepth = opts.bitDepth || 8;
  const shift = bitDepth - 8;
  const limitedMin = 16 << shift;
  const limitedSpan = 219 << shift;
  const maxValue = (1 << bitDepth) - 1;
  let normalized = Math.floor(((value - limitedMin) * maxValue) / limitedSpan + 0.5);
  if (normalized < 0) normalized = 0;
  if (normalized > maxValue) normalized = maxValue;
  return normalized;
}

function rgbLimitedWireCode(framebufferCode) {
  return Math.round(16 + framebufferCode * 219 / 255);
}

const legal80 = expectedGreyscaleCode(80, { mode: 'sdr', range: '1' });
const framebuffer80 = rendererNormalizeSourceValue(legal80, {
  sourceRange: 'LIMITED',
  outputFormat: '0',
  transportRange: '1',
  mode: 'sdr',
  bitDepth: 8
});
assert.strictEqual(legal80, 191, '80% limited source code should be legal code 191');
assert.strictEqual(framebuffer80, 204, 'renderer should normalize limited source 191 to framebuffer 204 for RGB limited transport');
assert.strictEqual(rgbLimitedWireCode(framebuffer80), legal80, 'renderer normalization should preserve the requested limited wire code');
assert.strictEqual(
  rendererNormalizeSourceValue(legal80, { sourceRange: 'FULL', outputFormat: '0', transportRange: '1', mode: 'sdr', bitDepth: 8 }),
  legal80,
  'FULL source range must not be normalized by the renderer'
);
assert.strictEqual(
  rendererNormalizeSourceValue(legal80, { sourceRange: 'LIMITED', outputFormat: '1', transportRange: '1', mode: 'sdr', bitDepth: 8 }),
  legal80,
  'YCbCr renderer path should not normalize RGB source values before RGB2YCbCr conversion'
);
const headroom96 = 246;
assert.strictEqual(
  rgbLimitedWireCode(rendererNormalizeSourceValue(headroom96, { sourceRange: 'LIMITED', outputFormat: '0', transportRange: '1', mode: 'sdr', bitDepth: 8 })),
  235,
	  'RGB limited transport clips above-white source code 246 to reference white'
);
assert.strictEqual(
  rendererNormalizeSourceValue(headroom96, { sourceRange: 'LIMITED', outputFormat: '1', transportRange: '1', mode: 'sdr', bitDepth: 8 }),
  headroom96,
	  'YCbCr transport keeps above-white source code 246 available to the Y channel'
);
assert(
  autocalWorkerSource.includes('sub autocal_step_allows_body_final_micro') &&
    autocalWorkerSource.includes('return ($ire >= 9.999 && $ire <= 95.0001) ? 1 : 0;') &&
    autocalWorkerSource.includes('sub body_final_micro_adjustments') &&
    autocalWorkerSource.includes('body_final_micro=>1') &&
    autocalWorkerSource.includes('my $run_body_final_micro_once=sub') &&
    autocalWorkerSource.includes('$run_body_final_micro_once->("Final micro-balancing $label before moving on");'),
  'LG AutoCal should give 10-95% greyscale patches one bounded worst-channel micro-balance pass before accepting a near-target result'
);
assert(
  autocalWorkerSource.includes('my @shadow=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep { ($_->{"ire"}+0) > 0 && ($_->{"ire"}+0) <= 10.0001 } @valid;'),
  'LG AutoCal should calibrate low-shadow slots low-to-high so darker-slot writes cannot be the final change before 5%'
);

console.log('Greyscale range regression checks passed.');

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const lgSource = fs.readFileSync('usr/sbin/pgenerator-lg', 'utf8');
const lgWebSource = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');
const autocalWorkerSource = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');
const meterSessionSource = fs.readFileSync('usr/bin/meter_session.sh', 'utf8');
const autoCalDdcResetStart = source.indexOf('async function meterAutoCalResetDdc()');
const autoCalDdcResetEnd = source.indexOf('async function meterAutoCalRunPreflightReset()', autoCalDdcResetStart);
const autoCalDdcResetSource = autoCalDdcResetStart >= 0 && autoCalDdcResetEnd > autoCalDdcResetStart
  ? source.slice(autoCalDdcResetStart, autoCalDdcResetEnd)
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
    source.includes('window.lgStatusState.calibrationMode=!!response.calibration_mode;'),
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
    source.includes('const loadedPanel=await meterAutoCalLoadPanelLightValue(true);') &&
    !source.includes('LG kept ') &&
    !source.includes('Adjust TV settings now if needed') &&
    !source.includes('message:meterAutoCalResetNotice+') &&
    autoCalDdcResetSource.includes('/api/lg/picture-settings/set') &&
    autoCalDdcResetSource.includes('reset_ddc_baseline:true') &&
    !autoCalDdcResetSource.includes('/api/lg/picture-settings/reset'),
  'LG Auto Cal should clear only the DDC table, refresh retained panel light silently, and continue to the luminance setup step'
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
  source.includes('id="meterAutoCalResetBtn" onclick="meterAutoCalRunPreflightReset()"') &&
    source.includes('resetBtn.style.display=(showDisclaimer&&!meterAutoCalPreflightResetDone)') &&
    source.includes('disclaimerBtn.style.display=(showDisclaimer&&meterAutoCalPreflightResetDone)') &&
    source.includes('async function meterAutoCalRunPreflightReset()') &&
    source.includes("message:'Click Continue when ready.'") &&
    source.includes("message:meterAutoCalPreflightResetDone?'Click Continue when ready.'") &&
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
    source.includes("toast('Run the LG DDC reset first.',true)"),
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
  source.includes("current_name:'Meter setup failed'") &&
    source.includes("click Continue to retry"),
  'LG Auto Cal should keep the reset popup open and allow Continue retry when luminance meter setup fails'
);
assert(
  source.includes('setsid /usr/bin/perl /usr/bin/meter_lg_autocal.pl') &&
    !source.includes('setsid sudo /usr/bin/perl /usr/bin/meter_lg_autocal.pl') &&
    source.includes('const overlayActive=!!active;') &&
    source.includes("document.body.classList.toggle('meter-autocal-active',overlayActive)") &&
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
  const lgDescending = autocalWorkerSource.indexOf('return sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } @valid', orderStart);
  const topSort = autocalWorkerSource.indexOf('my ($top)=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { !$seen{format_percent($_->{"ire"})} } @valid;', orderStart);
  const p50 = autocalWorkerSource.indexOf('$add_nearest->(50);', orderStart);
  const p25 = autocalWorkerSource.indexOf('$add_nearest->(25);', orderStart);
  const p75 = autocalWorkerSource.indexOf('$add_nearest->(75);', orderStart);
  const descendingSort = autocalWorkerSource.indexOf('sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } @valid', p75);
  const skipDuplicate = autocalWorkerSource.indexOf('sub autocal_skip_duplicate_ddc_slot');
  assert(
    orderStart >= 0 &&
      lgDescending > orderStart &&
      topSort > orderStart &&
      p50 > topSort &&
      p25 > p50 &&
      p75 > p25 &&
	      descendingSort > p75 &&
	      skipDuplicate >= 0 &&
	      skipDuplicate < orderStart &&
	      autocalWorkerSource.includes('!autocal_skip_duplicate_ddc_slot($_)') &&
	      !autocalWorkerSource.includes('return 1 if($key eq "7.5" || $key eq "35" || $key eq "70");') &&
	      autocalWorkerSource.includes('my @ordered=order_autocal_steps($steps,$config);') &&
	      autocalWorkerSource.includes('sub fixed_lg_autocal_stimulus') &&
	      autocalWorkerSource.includes('"2.3" => 2.28310502283105') &&
	      autocalWorkerSource.includes('"75" => 74.8858447488585') &&
	      autocalWorkerSource.includes('"109" => 109.474885844749') &&
      autocalWorkerSource.includes('my $read_step=fixed_lg_autocal_step($config,$step);') &&
      autocalWorkerSource.includes('return $step if(!$config->{"use_shifted_lg_autocal_stimulus"});') &&
      autocalWorkerSource.includes('$reading->{"autocal_fixed_stimulus"}=JSON::PP::true') &&
      autocalWorkerSource.includes('sub stimulus_probe_enabled') &&
      autocalWorkerSource.includes('return (ref($config) eq "HASH" && $config->{"stimulus_probe_enabled"}) ? 1 : 0;') &&
      autocalWorkerSource.includes('if(!$adjustments && stimulus_probe_enabled($config) && !guarded_target_reached') &&
      autocalWorkerSource.includes('if(stimulus_probe_enabled($config) && $needs_stimulus_probe)') &&
      autocalWorkerSource.includes('return (undef,$reading,$arrays,$picture,undef) if(!stimulus_probe_enabled($config));'),
    'LG Auto Cal should calibrate captured 26pt patches high-to-low so later interpolation does not move completed points'
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
	    autocalWorkerSource.includes('mark_tried_values(\\%tried_values,$arrays,$target,$de);') &&
	    autocalWorkerSource.includes('choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\\%tried_values,$read_step)') &&
		    autocalWorkerSource.includes('sub neutral_luminance_adjustments') &&
		    autocalWorkerSource.includes('sub neutral_luminance_step') &&
			    autocalWorkerSource.includes('sub target_is_low_shadow_slot') &&
			    autocalWorkerSource.includes('sub low_ire_luminance_needs_lift') &&
			    autocalWorkerSource.includes('return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));') &&
			    autocalWorkerSource.includes('sub low_ire_luminance_needs_tuning') &&
			    autocalWorkerSource.includes('return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));') &&
				    autocalWorkerSource.includes('return 18 if($ire <= 5);') &&
				    autocalWorkerSource.includes('return 14 if($ire <= 7.5);') &&
				    autocalWorkerSource.includes('return 10 if($ire <= 10);') &&
			    autocalWorkerSource.includes('$value=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $value < 0);') &&
			    autocalWorkerSource.includes('$next=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $luminance_err < 0 && $current < 0 && $next < 0);') &&
		    autocalWorkerSource.includes('sub implausible_autocal_read') &&
		    autocalWorkerSource.includes('sub read_step_guarded') &&
		    autocalWorkerSource.includes('Rejecting implausible Auto Cal read') &&
		    autocalWorkerSource.includes('$ratio >= 0.35 && $ratio <= 2.20') &&
		    autocalWorkerSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
		    autocalWorkerSource.includes('sub chroma_error_magnitude') &&
	    autocalWorkerSource.includes('neutral_luminance=>1') &&
	    autocalWorkerSource.includes('$luminance_err=0 if($ire >= 99.9);') &&
	    autocalWorkerSource.includes('$near_fine=0 if($ire >= 99.9 && defined($de) && $de > 0.75);') &&
	    autocalWorkerSource.includes('return 1 if($ire >= 99.9);') &&
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
			    autocalWorkerSource.includes('$keep_tuning_luma=1 if(abs($lum_pct) > ($luma_tol*0.65) && !ddc_target_near_limit($arrays,$target,42));') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && ddc_target_near_limit($arrays,$target,45));') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $no_response_stalls >= 2);') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 4 && ddc_target_max_delta($arrays,$slot_default_arrays,$target) >= 12);') &&
			    autocalWorkerSource.includes('$needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 6 && far_from_target($de,$lum_pct,$target_delta,$read_step));') &&
			    autocalWorkerSource.includes('my $restore_best_branch=sub') &&
			    autocalWorkerSource.includes('Backtracking to best $label result') &&
			    autocalWorkerSource.includes('$state->{"active_stimulus"}=$read_step->{"stimulus"}+0') &&
    autocalWorkerSource.includes('read_step($config,$read_step,$state)') &&
	    autocalWorkerSource.includes('my $stimulus=defined($step->{"stimulus"})') &&
	    autocalWorkerSource.includes('$reading->{"stimulus"}=$step->{"stimulus"}') &&
	    autocalWorkerSource.includes('refresh_rate => $config->{"refresh_rate"}||""') &&
			    autocalWorkerSource.includes('sub close_enough_stalled') &&
			    autocalWorkerSource.includes('sub iteration_limit_for_step') &&
			    autocalWorkerSource.includes('sub autocal_step_is_fast_headroom') &&
			    autocalWorkerSource.includes('sub headroom_iteration_limit_for_step') &&
			    autocalWorkerSource.includes('return 60 if($ire >= 108.5);') &&
			    autocalWorkerSource.includes('return 36;') &&
			    autocalWorkerSource.includes('sub headroom_polish_limit_for_step') &&
			    autocalWorkerSource.includes('return 16 if($ire >= 108.5);') &&
			    autocalWorkerSource.includes('sub autocal_step_allows_final_fine_tune') &&
				    autocalWorkerSource.includes('sub headroom_autocal_result_score') &&
				    autocalWorkerSource.includes('sub headroom_fine_target_delta') &&
				    autocalWorkerSource.includes('sub headroom_needs_fine_tune') &&
				    autocalWorkerSource.includes('return 0 if(headroom_needs_fine_tune($de,$target_delta,$reading,$step));') &&
				    autocalWorkerSource.includes('return headroom_autocal_result_score($de,$reading,$step) if(autocal_step_is_fast_headroom($step));') &&
				    autocalWorkerSource.includes('sub choose_headroom_single_adjustment') &&
			    autocalWorkerSource.includes('return choose_headroom_single_adjustment($error,$arrays,$target,$de,$min_step,$stalls,$tried,$step);') &&
			    autocalWorkerSource.includes('sub headroom_proportional_adjustment') &&
			    autocalWorkerSource.includes('my $ideal=$start - ($e0*($end-$start)/($e1-$e0));') &&
			    autocalWorkerSource.includes('proportional=>1') &&
			    autocalWorkerSource.includes('if(autocal_step_is_fast_headroom($read_step) && ref($headroom_next_adjustments) eq "ARRAY")') &&
			    !autocalWorkerSource.includes('return 0 if(autocal_step_is_fast_headroom($step) && !headroom_rgb_balanced($reading,$target_delta,$step));') &&
			    !autocalWorkerSource.includes('Backtracking to best $label result after rejected headroom step') &&
			    autocalWorkerSource.includes('autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta)') &&
			    autocalWorkerSource.includes('$polish_limit=headroom_polish_limit_for_step($read_step);') &&
			    autocalWorkerSource.includes('sub trace_109') &&
			    autocalWorkerSource.includes('/var/log/PGenerator/lg-autocal-109-trace.log') &&
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
	    autocalWorkerSource.includes('sub target_reached') &&
		    autocalWorkerSource.includes('sub autocal_result_score') &&
		    autocalWorkerSource.includes('sub white_luminance_guard_failed') &&
		    autocalWorkerSource.includes('sub guarded_autocal_result_score') &&
		    autocalWorkerSource.includes('sub guarded_target_reached') &&
		    autocalWorkerSource.includes('$penalty=$excess*0.35') &&
		    autocalWorkerSource.includes('$penalty=4 if($penalty > 4);') &&
		    !autocalWorkerSource.includes('return 100 + ($excess*4) + $score;') &&
		    autocalWorkerSource.includes('if(guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y))') &&
		    autocalWorkerSource.includes('last if(guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y));') &&
			    autocalWorkerSource.includes('sub choose_micro_adjustments') &&
			    autocalWorkerSource.includes('Starting final fine tune for $label') &&
			    autocalWorkerSource.includes('Fine tuning $label') &&
			    autocalWorkerSource.includes('$polish_limit=48 if(!defined($polish_limit));') &&
		    autocalWorkerSource.includes('$best_de <= ($target_delta+0.15)') &&
		    autocalWorkerSource.includes('next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step)') &&
			    autocalWorkerSource.includes('last if($polish_stalls >= 14);') &&
		    autocalWorkerSource.includes('my $probe_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);') &&
		    autocalWorkerSource.includes('if(defined($de) && $probe_score + 0.0001 < $best_score)') &&
		    autocalWorkerSource.includes('Keeping best $label result') &&
	    autocalWorkerSource.includes('target_gamma=>$target_gamma') &&
	    autocalWorkerSource.includes('setup_luminance_reference=>$target_luminance') &&
	    autocalWorkerSource.includes('target_luminance=>undef') &&
	    autocalWorkerSource.includes('my $white_y=undef;') &&
	    autocalWorkerSource.includes('set_state_white_reference($state,$white_y) if(autocal_step_is_white($read_step));') &&
	    autocalWorkerSource.includes('return undef if(autocal_step_is_white($step));') &&
    autocalWorkerSource.includes('target_step_luminance') &&
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
		    autocalWorkerSource.includes('my $deadline=time()+read_timeout_for_step($step);') &&
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
    source.includes('$read_command.=" $cmd_signal_range $cmd_transport_signal_range $request_id $patch_input_max"') &&
    meterSessionSource.includes('REQUEST_ID') &&
    meterSessionSource.includes('\\"request_id\\":\\"$REQUEST_ID\\"') &&
    meterSessionSource.includes('READ_TIMEOUT=90') &&
    meterSessionSource.includes('ire_le "$IRE" 25 && READ_TIMEOUT=120') &&
    meterSessionSource.includes('ire_le "$IRE" 5 && READ_TIMEOUT=140') &&
    source.includes('return meterPollRead(timeoutMs||180000,shouldCancel);') &&
    source.includes('async function meterStartSingleReadWithTimeout') &&
    source.includes('await meterPollRead(180000,()=>!meterContinuousActive)') &&
    source.includes('const invalidatedByLgWrite=readSuspendToken!==meterContinuousSuspendToken') &&
    source.includes('meter read state stale for ${age}s') &&
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
	    autocalWorkerSource.includes('choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\\%tried_values,$read_step)') &&
	    autocalWorkerSource.includes('choose_micro_adjustments($err,$arrays,$target,$lum_err,\\%polish_tried,$micro_step,$best_de,$polish_stalls,$read_step)') &&
    autocalWorkerSource.includes('$state->{"message"}=guarded_target_reached($best_de,$best_lum_pct,$target_delta,$read_step,$best_reading,$white_guard_y)') &&
    source.includes("target_gamma:(document.getElementById('meterTargetGamma')||{}).value||'bt1886'") &&
    source.includes("message:'Setup white reference '+targetY.toFixed(2)+' cd/m\\u00B2'"),
  'LG Auto Cal/manual reads should include gamma/luminance error, reject stale results, and keep meter sessions healthy'
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
		assert(
		  !autocalWorkerSource.includes('committed_state_polish($config,$state'),
		  'LG Auto Cal should not run a post-commit polish pass after uploading the final 1D LUT'
		);
	{
	  const finalBlackIdx = autocalWorkerSource.indexOf('Final 0% black read complete');
	  const finalCommitCallIdx = autocalWorkerSource.indexOf('commit_final_1d_lut($state,$picture,$arrays,$picture_mode,\\@ordered,$calibration_mode_active)', finalBlackIdx);
	  const commitMarksEndedIdx = autocalWorkerSource.indexOf('$calibration_mode_active=0 if($commit_ended_calibration);', finalCommitCallIdx);
	  assert(
		      autocalWorkerSource.includes('sub commit_final_1d_lut') &&
		      autocalWorkerSource.includes('Uploading final 1024-point LG 1D LUT') &&
		      autocalWorkerSource.includes('Final 1D LUT uploaded, verified, and calibration mode ended') &&
	      autocalWorkerSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,0)') &&
	      autocalWorkerSource.includes('$calibration_mode_active=0 if($commit_ended_calibration);') &&
	      autocalWorkerSource.includes('verify_ddc_upload => $verify_ddc_upload ? JSON::PP::true : JSON::PP::false') &&
		      lgSource.includes('ddc_upload_verified') &&
	      finalBlackIdx > -1 &&
	      finalCommitCallIdx > finalBlackIdx &&
	      commitMarksEndedIdx > finalCommitCallIdx,
	    'LG Auto Cal should upload the final 1024-point 1D LUT and end calibration mode in the final verified write'
	  );
	}
assert(
	  source.includes('id="meterAutoCalResultsBox"') &&
	    source.includes('function meterAutoCalSummaryRows(status)') &&
	    source.includes('rd.autocal_white_reference||rd.autocal_reference_only') &&
	    source.includes('function meterAutoCalRenderResults(status)') &&
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
    source.includes('setInterval(meterPollAutoCal,1500)'),
  'LG Auto Cal should not mark the meter disconnected or over-poll the web service while calibration writes are blocking'
);
assert(
  source.includes('$result=&webui_cec($cec_cmd);') &&
    source.includes('timeout 2 $cec_bin status') &&
    source.includes('return "{\\"status\\":\\"ok\\",\\"tv_power\\":\\"$power\\"') &&
    source.includes('"driver":"cec-status-timeout"') &&
    !source.includes('($now - $_cec_cache_time) >= $_CEC_CACHE_TTL'),
  'CEC status should use a short direct power query instead of serving stale scan-cache power'
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
  source.includes('data-meter-autocal-brightness="1"') &&
    source.includes("document.querySelectorAll('[data-meter-autocal-brightness]').forEach") &&
    source.includes('let meterAutoCalLuminanceReadBusy=false;') &&
    source.includes('let meterAutoCalPanelLightQueuedDelta=0;') &&
    source.includes('function meterAutoCalPanelLightQueuePending()') &&
    source.includes('const disableBrightness=busy&&!inLiveLuminance') &&
    source.includes('meterAutoCalPanelLightQueuedDelta+=numericDelta;') &&
    source.includes('function meterAutoCalProcessQueuedPanelLight()') &&
    source.includes('meterAutoCalProcessQueuedPanelLight();') &&
    source.includes("lgBeginCommand('LG TV panel-light adjustment')") &&
    source.includes("await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000})") &&
    !source.includes('let cancelledForPanelLight=false;') &&
    !source.includes('if(await meterAutoCalProcessQueuedPanelLight())') &&
    source.includes('meterAutoCalLuminanceReadBusy=true;') &&
    source.includes('btn.disabled=disableBrightness') &&
    source.includes("panelBusy?' (updating...)':(queued?' (queued...)':'')"),
  'LG Auto Cal panel-light +/- buttons should queue in the background without interrupting live luminance reads'
);
assert(
  source.includes('.diag-custom-picker button[onclick^="diagPlaySelectedAsset"]::before') &&
    source.includes('border-left:14px solid currentColor') &&
    source.includes('.diag-custom-picker button[onclick="stopPattern()"]::before') &&
    source.includes('width:13px;height:13px'),
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
  source.includes('function meterGreyTvLuminanceHtml(tvValue,disabled)') &&
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
    source.includes('meterGreyTvLuminanceHtml(selected?selected.lum:null,disabled)'),
  'LG 22pt manual controls should expose the per-point brightness/adjustingLuminance array as a horizontal control'
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
	    source.includes('if(!meterChartIsHdr()) return null;') &&
	    source.includes('function meterGreyNominalTargetCurvePoints') &&
	    source.includes("meterGreyNominalTargetCurvePoints(targetPeak,Lb,yTop,'eotf')") &&
	    source.includes("meterGreyNominalTargetCurvePoints(targetPeak,Lb,yTop,'luminance')") &&
	    source.includes('meterGreyTargetEotfValue(s.ire,targetPeak,Lb,null)') &&
	    source.includes('meterGreyTargetChartValue(s.ire,targetPeak,Lb,null)') &&
	    source.includes('function effectiveGammaTopSlope') &&
	    source.includes('if(frac>=0.999999) return null;') &&
	    source.includes('if(topGamma) return;') &&
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
    source.includes('return (Array.isArray(items)?items:[]).filter(item=>Number(item&&item.ire)<=100);') &&
    source.includes('const plotSteps=meterFilterEotfLuminanceChartItems(targetSteps);') &&
    source.includes('const validG=meterFilterEotfLuminanceChartItems(sorted).filter') &&
    source.includes('xSteps:10,ySteps:5') &&
    source.includes('const allStepsRaw=meterSeriesSteps?meterGreyscaleSeriesSteps(meterSeriesSteps):null;') &&
    source.includes('const allSteps=allStepsRaw?meterFilterLgAutoCalChartItems(allStepsRaw):null;') &&
    source.includes('const gs=meterFilterLgAutoCalChartItems(rawGs);') &&
    source.includes('const white=meterGreyscaleChartWhiteReference(sorted);') &&
    source.includes('const center=targets.length') &&
    source.includes('return {min:center-half,max:center+half};') &&
    source.includes('const yMin=97,yMax=103;') &&
    source.includes('const halfRange=Math.max(3') &&
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
    source.includes('const steps=meterFilterGammaChartItems(sourceSteps).filter(s=>(s.ire||0)>0&&(s.ire||0)<100);') &&
    source.includes('const sorted=gammaFixedAxis?meterFilterGammaChartItems(sortedAll):sortedAll;') &&
    source.includes('xSteps:gammaFixedAxis?10:(xSteps.length-1||1)') &&
    source.includes("xLabel:(i)=>gammaFixedAxis?String(i*10):(i<xSteps.length?meterGreyscaleChartLabel(xSteps[i],xSteps,i):'')") &&
    source.includes('rd._gamma_rgb=meterPerChannelGamma(rd,white,rd.ire||0,prev);') &&
    source.includes('if(ire>=100){') &&
    !source.includes('const gTop=Math.log(pm/w)/Math.log(prevIre/100);'),
  'Greyscale charts should center gamma on target, omit LG 26pt gamma headroom tracking, and keep RGB balance no tighter than 97-103'
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

console.log('Greyscale range regression checks passed.');

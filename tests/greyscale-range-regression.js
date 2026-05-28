const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const lgSource = fs.readFileSync('usr/sbin/pgenerator-lg', 'utf8');
const lgWebSource = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');
const autocalWorkerSource = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');
const hybridAutocalWorkerSource = fs.readFileSync('tmp/hybrid-topend/meter_lg_autocal.pl', 'utf8');
const meterSessionSource = fs.readFileSync('usr/bin/meter_session.sh', 'utf8');
const meterSeriesSource = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');
const lgAutocalAbHarnessSource = fs.readFileSync('tests/lg-autocal-ab-harness.sh', 'utf8');
const autoCalDdcResetStart = source.indexOf('async function meterAutoCalResetDdc()');
const autoCalDdcResetEnd = source.indexOf('async function meterAutoCalRunPreflightReset()', autoCalDdcResetStart);
const autoCalDdcResetSource = autoCalDdcResetStart >= 0 && autoCalDdcResetEnd > autoCalDdcResetStart
  ? source.slice(autoCalDdcResetStart, autoCalDdcResetEnd)
  : '';
const fullAutoCalStartStart = source.indexOf('async function meterStartFullAutoCal()');
const fullAutoCalStartEnd = source.indexOf('async function meterFullAutoCalStart3d', fullAutoCalStartStart);
const fullAutoCalStartSource = fullAutoCalStartStart >= 0 && fullAutoCalStartEnd > fullAutoCalStartStart
  ? source.slice(fullAutoCalStartStart, fullAutoCalStartEnd)
  : '';
const legalWhitePairReferenceStart = autocalWorkerSource.indexOf('sub legal_white_pair_reference_step');
const legalWhitePairReferenceEnd = autocalWorkerSource.indexOf('sub legal_white_pair_spread_limit', legalWhitePairReferenceStart);
const legalWhitePairReferenceSource = legalWhitePairReferenceStart >= 0 && legalWhitePairReferenceEnd > legalWhitePairReferenceStart
  ? autocalWorkerSource.slice(legalWhitePairReferenceStart, legalWhitePairReferenceEnd)
  : '';
const shiftedStimulusStepStart = autocalWorkerSource.indexOf('sub shifted_stimulus_step');
const shiftedStimulusStepEnd = autocalWorkerSource.indexOf('sub fixed_lg_autocal_stimulus', shiftedStimulusStepStart);
const shiftedStimulusStepSource = shiftedStimulusStepStart >= 0 && shiftedStimulusStepEnd > shiftedStimulusStepStart
  ? autocalWorkerSource.slice(shiftedStimulusStepStart, shiftedStimulusStepEnd)
  : '';
const fixedLgAutoCalStepStart = autocalWorkerSource.indexOf('sub fixed_lg_autocal_step');
const fixedLgAutoCalStepEnd = autocalWorkerSource.indexOf('sub stimulus_probe_key', fixedLgAutoCalStepStart);
const fixedLgAutoCalStepSource = fixedLgAutoCalStepStart >= 0 && fixedLgAutoCalStepEnd > fixedLgAutoCalStepStart
  ? autocalWorkerSource.slice(fixedLgAutoCalStepStart, fixedLgAutoCalStepEnd)
  : '';
const autoCalTargetGammaStart = source.indexOf('function meterAutoCalTargetGammaValue()');
const autoCalTargetGammaEnd = source.indexOf('function meterAutoCalTargetGamutValue()', autoCalTargetGammaStart);
const autoCalTargetGammaSource = autoCalTargetGammaStart >= 0 && autoCalTargetGammaEnd > autoCalTargetGammaStart
  ? source.slice(autoCalTargetGammaStart, autoCalTargetGammaEnd)
  : '';
const lgAutoCalGreyscalePayloadGammaCount = (source.match(/target_gamma:meterLgAutoCalGreyscaleTargetGammaValue\(\)/g) || []).length;
const autoCalTargetLuminanceStart = autocalWorkerSource.indexOf('sub target_luminance_for_autocal_step');
const autoCalTargetLuminanceEnd = autocalWorkerSource.indexOf('sub body_luma_bias_display_allowed', autoCalTargetLuminanceStart);
const autoCalTargetLuminanceSource = autoCalTargetLuminanceStart >= 0 && autoCalTargetLuminanceEnd > autoCalTargetLuminanceStart
  ? autocalWorkerSource.slice(autoCalTargetLuminanceStart, autoCalTargetLuminanceEnd)
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
  source.includes('$step_read_delay_ms=3000 if(abs($v-100)<0.001);') &&
    source.includes('$step_read_delay_ms=6000 if($v > 0 && $v <= 10);') &&
    source.includes('$step_read_delay_ms=3200 if($v > 10 && $v <= 25);') &&
    source.includes('$extra.=",\\"read_delay_ms\\":$step_read_delay_ms" if($step_read_delay_ms > $delay_ms);') &&
    meterSeriesSource.includes('READ_DELAY_MS=$(get_step_field $i read_delay_ms)') &&
    meterSeriesSource.includes('STEP_DELAY_EXPLICIT=0') &&
    meterSeriesSource.includes('if (( i == 0 && STEP_DELAY_EXPLICIT == 0 )); then') &&
    meterSeriesSource.includes('first_white_reference=$(get_step_field 0 autocal_white_reference)') &&
    meterSeriesSource.includes('return 1') &&
    meterSeriesSource.includes('STEP_DELAY=$(python -c "print(float(\'$READ_DELAY_MS\')/1000.0)"'),
  'LG 26pt series reads should keep exact per-step settle overrides for the white reference/dark patches instead of inflating them with global first-step delay or final white refresh'
);
assert(
  (source.match(/my \$delay_ms=1000;/g) || []).length >= 2 &&
    source.includes('my $delay_default_ms=1000;') &&
    source.includes('id="meterDelay" type="text" value="1.0"') &&
    source.includes('meterDelayParseSeconds(this.value,1.0)') &&
    source.includes("return Math.round(meterDelayParseSeconds(el?el.value:'',1.0)*1000);") &&
    source.includes('el.value=meterDelayFormatSeconds(1.0);') &&
    source.includes('let meterDelayExplicit=false;') &&
    source.includes('delay_user_set:!!meterDelayExplicit') &&
    source.includes('meterDelayLoadValue(s.delay,s.delay_user_set===true||s.delay_explicit===true);') &&
    autocalWorkerSource.includes('int($config->{"delay_ms"}||1000)') &&
    autocalWorkerSource.includes('configured_delay_ms=>int($config->{"delay_ms"}||1000)') &&
    fs.readFileSync('usr/bin/meter_lg_3d_autocal.pl', 'utf8').includes('int($config->{"delay_ms"}||1000)'),
  'Meter delay should default to 1.0 second across UI, series reads, single reads, and LG AutoCal when no explicit value is supplied, while preserving user-set values'
);
assert(
  source.includes('id="meterFullAutoCalConfirmBox"') &&
    /function meterFullAutoCalConfirmDialog\([^)]*\)/.test(source) &&
    source.includes('function meterFullAutoCalResolveConfirm(accepted)') &&
    fullAutoCalStartSource.includes('const accepted=await meterFullAutoCalConfirmDialog({showPostCalTouchupChoice:true});') &&
    !fullAutoCalStartSource.includes('window.confirm(') &&
    !source.includes("window.confirm('Full Auto Cal will reset") &&
    !source.includes('then calibrate white, 75%, 50%, 25%') &&
    source.includes('derive the 109% headroom reference, then calibrate the LG 26-point greyscale sequence top/body first and shadows low-to-high') &&
    source.includes('run the current LG 26-point greyscale AutoCal top/body first and shadows low-to-high') &&
    source.includes('reset the active LG greyscale DDC state and LG 3D LUT baseline'),
  'Full Auto Cal confirmation should use the in-app AutoCal overlay instead of a browser confirm dialog'
);
assert(
  source.includes("id=\"meterIncludeLumError\" onchange=\"meterOnGreyRefChange('checkbox')\"") &&
    source.includes('if(meterReadingIsGreyscale(reading)) return false;'),
  'Greyscale AutoCal readings should honor the Include luminance error checkbox and stay on the greyscale Delta E path'
);
{
  const targetGamutStart = source.indexOf("document.getElementById('meterTargetGamut').addEventListener('change',()=>{");
  const targetGamutEnd = source.indexOf("document.getElementById('meterTargetGamma').addEventListener", targetGamutStart);
  const targetGamutSource = targetGamutStart >= 0 && targetGamutEnd > targetGamutStart
    ? source.slice(targetGamutStart, targetGamutEnd)
    : '';
  assert(
    targetGamutSource.includes('meterOnGreyRefChange();') &&
      targetGamutSource.includes('meterRefreshActiveSeriesCharts();') &&
      source.includes('delete r._dE_cache_key;'),
    'Target Colorspace changes should invalidate cached delta analysis and refresh active charts'
  );
}
{
  const measuredWhiteStart = source.indexOf('function meterUseMeasuredWhiteTarget()');
  const measuredWhiteEnd = source.indexOf('const GAMUT_PRESETS=', measuredWhiteStart);
  const measuredWhiteSource = measuredWhiteStart >= 0 && measuredWhiteEnd > measuredWhiteStart
    ? source.slice(measuredWhiteStart, measuredWhiteEnd)
    : '';
  assert(
    source.includes('onclick="meterUseMeasuredWhiteTarget()">Use measured values</button>') &&
      measuredWhiteSource.includes('meterFindMeasuredWhiteReading()') &&
      measuredWhiteSource.includes("gamutEl.value='customd65'") &&
      measuredWhiteSource.includes('saveMeterSettings();') &&
      measuredWhiteSource.includes('meterOnGreyRefChange();') &&
      measuredWhiteSource.includes('meterRefreshActiveSeriesCharts();'),
    'Use measured values should snapshot measured white into Custom / D65 and refresh grey/chart analysis'
  );
  assert(
    source.includes('#meterSettingsGrid .field-gamut{width:148px;max-width:100%}') &&
      source.includes('#meterSettingsGrid .field-gamut.has-whitepoint{width:360px}') &&
      source.includes("gamutField.classList.toggle('has-whitepoint',enabled);") &&
      source.includes('.meter-matrix-field{display:none;margin-top:32px;max-width:240px}') &&
      source.includes('.meter-matrix-field.visible{display:block}') &&
      source.includes("field.classList.toggle('visible',enabled);"),
    'Custom / D65 white-point controls should not reserve blank layout space when hidden'
  );
}
assert(
  autocalWorkerSource.includes('return 0 if($target_slot_ire >= 105 && $target_slot_ire < 108.5 && ($slots[$source_idx]+0) >= 108.5);'),
  'LG AutoCal headroom points should not seed from the previously calibrated higher headroom slot'
);
assert(
  autocalWorkerSource.includes('$bias_source eq "matrix" ? abs($bias_pct) > 0.0000001 : $bias_pct > 0') &&
    autocalWorkerSource.includes('body_luma_bias_matrix_pct') &&
    autocalWorkerSource.includes('$pct=-0.12 if($pct < -0.12);'),
  'LG AutoCal explicit body luminance bias matrix entries should support both positive and negative per-IRE target offsets'
);
const propagate26Start = autocalWorkerSource.indexOf('sub propagate_uncalibrated_26pt_slots');
const propagate26End = autocalWorkerSource.indexOf('sub seed_target_from_prior_slot', propagate26Start);
const propagate26Source = propagate26Start >= 0 && propagate26End > propagate26Start
  ? autocalWorkerSource.slice(propagate26Start, propagate26End)
  : '';
const blackAnchor26Start = autocalWorkerSource.indexOf('sub lg_autocal_26_black_lut_anchor');
const blackAnchor26End = autocalWorkerSource.indexOf('sub clone_calibrated_26pt_slot_mask', blackAnchor26Start);
const blackAnchor26Source = blackAnchor26Start >= 0 && blackAnchor26End > blackAnchor26Start
  ? autocalWorkerSource.slice(blackAnchor26Start, blackAnchor26End)
  : '';
const refresh26Start = autocalWorkerSource.indexOf('sub refresh_propagated_uncalibrated_26pt_slots');
const refresh26End = autocalWorkerSource.indexOf('sub seed_target_from_prior_slot', refresh26Start);
const refresh26Source = refresh26Start >= 0 && refresh26End > refresh26Start
  ? autocalWorkerSource.slice(refresh26Start, refresh26End)
  : '';
const dynamicFinalizeStart = autocalWorkerSource.indexOf('my $finalize_calibrated_26pt_slot=sub {');
const dynamicFinalizeEnd = autocalWorkerSource.indexOf('my @ordered=order_autocal_steps', dynamicFinalizeStart);
const dynamicFinalizeSource = dynamicFinalizeStart >= 0 && dynamicFinalizeEnd > dynamicFinalizeStart
  ? autocalWorkerSource.slice(dynamicFinalizeStart, dynamicFinalizeEnd)
  : '';
const topWindowPolishStart = autocalWorkerSource.indexOf('sub committed_top_window_polish');
const topWindowPolishEnd = autocalWorkerSource.indexOf('sub start_calibration_mode', topWindowPolishStart);
const topWindowPolishSource = topWindowPolishStart >= 0 && topWindowPolishEnd > topWindowPolishStart
  ? autocalWorkerSource.slice(topWindowPolishStart, topWindowPolishEnd)
  : '';
const postCommitVerifyGateStart = autocalWorkerSource.indexOf('sub apply_post_commit_verify_gate');
const postCommitVerifyGateEnd = autocalWorkerSource.indexOf('sub high_low_stride_steps', postCommitVerifyGateStart);
const postCommitVerifyGateSource = postCommitVerifyGateStart >= 0 && postCommitVerifyGateEnd > postCommitVerifyGateStart
  ? autocalWorkerSource.slice(postCommitVerifyGateStart, postCommitVerifyGateEnd)
  : '';
const committedPolishStart = autocalWorkerSource.indexOf('sub committed_state_polish');
const committedPolishEnd = autocalWorkerSource.indexOf('sub end_calibration_mode', committedPolishStart);
const committedPolishSource = committedPolishStart >= 0 && committedPolishEnd > committedPolishStart
  ? autocalWorkerSource.slice(committedPolishStart, committedPolishEnd)
  : '';
const committedPolishReferenceStart = autocalWorkerSource.indexOf('sub committed_polish_reference_white_y');
const committedPolishReferenceEnd = autocalWorkerSource.indexOf('sub lg_extended_sdr_16_255_enabled', committedPolishReferenceStart);
const committedPolishReferenceSource = committedPolishReferenceStart >= 0 && committedPolishReferenceEnd > committedPolishReferenceStart
  ? autocalWorkerSource.slice(committedPolishReferenceStart, committedPolishReferenceEnd)
  : '';
const oledShadowCompStart = autocalWorkerSource.indexOf('sub lg_autocal_26_oled_shadow_detail_compensation_enabled');
const oledShadowCompEnd = autocalWorkerSource.indexOf('sub config_positive_int', oledShadowCompStart);
const oledShadowCompSource = oledShadowCompStart >= 0 && oledShadowCompEnd > oledShadowCompStart
  ? autocalWorkerSource.slice(oledShadowCompStart, oledShadowCompEnd)
  : '';
const bodyVerifyStart = autocalWorkerSource.indexOf('sub committed_body_verify_step');
const bodyVerifyEnd = autocalWorkerSource.indexOf('sub committed_state_polish', bodyVerifyStart);
const bodyVerifySource = bodyVerifyStart >= 0 && bodyVerifyEnd > bodyVerifyStart
  ? autocalWorkerSource.slice(bodyVerifyStart, bodyVerifyEnd)
  : '';
const propagate26Call = autocalWorkerSource.indexOf('refresh_propagated_uncalibrated_26pt_slots($config,$arrays,\\@calibrated_ddc_slots)');
const oledShadowCompCall = autocalWorkerSource.indexOf('apply_lg_autocal_26_oled_shadow_detail_compensation(');
const finalPropagate26Call = autocalWorkerSource.indexOf('refresh_propagated_uncalibrated_26pt_slots($config,$arrays,\\@calibrated_ddc_slots)', oledShadowCompCall);
const final1dCommitCall = autocalWorkerSource.indexOf('commit_final_1d_lut($state,$picture,$arrays');
const dynamicFinalizeCallCount = (autocalWorkerSource.match(/\$finalize_calibrated_26pt_slot->\(\$target,\$read_step,\$label\);/g) || []).length;
assert(
  autocalWorkerSource.includes('return (109,105,99,75,50,25,5);') &&
    autocalWorkerSource.includes('@lg_autocal_26_order=(109,105,99,75,50,25,5,95,90,85,80,70,65,60,55,45,40,35,30,20,15,10,7,4,3,2.3)') &&
    autocalWorkerSource.includes('return 0 if(!grep { abs($target_slot_ire-$_) < 0.001 } (75,50,25,5));'),
  'LG 26-point anchor pre-drive should stop the immediate low-shadow anchor phase at 5%, then avoid luma-only 5%-copy refinement for 4% and 3% before their descending-sweep calibration'
);
assert(
  postCommitVerifyGateSource.includes('post_commit_body_verify post_commit_final_all_level_verify post_commit_final_top_window') &&
    !postCommitVerifyGateSource.includes('post_commit_top_window') &&
    !postCommitVerifyGateSource.includes('post_commit_true_low_shadow') &&
    autocalWorkerSource.includes('apply_post_commit_verify_gate($config);') &&
    source.includes('post_commit_verify:postCommitVerifyEnabled') &&
    source.includes('post_commit_verify:touchupPostCommitVerifyEnabled'),
  'Post-commit verify false should gate read-only verify stages without disabling committed polish adjustment stages'
);
assert(
  oledShadowCompSource.includes('sub lg_autocal_26_oled_shadow_detail_compensation_enabled') &&
    oledShadowCompSource.includes('return 0; # Disabled: this pre-commit OLED shadow bias made low-shadow points read too bright after calibration.') &&
    !oledShadowCompSource.includes('return 1 if($display =~ /oled/);') &&
    oledShadowCompSource.includes('"oled_shadow_detail_compensation"') &&
    oledShadowCompCall >= 0 &&
    finalPropagate26Call >= 0 &&
    final1dCommitCall >= 0 &&
    oledShadowCompCall < finalPropagate26Call &&
    finalPropagate26Call < final1dCommitCall,
  'OLED shadow detail pre-commit compensation should remain disabled so low-shadow DDC offsets are not applied before final commit'
);
assert(
  autocalWorkerSource.includes('sub low_shadow_3_4_luma_far_from_target') &&
    autocalWorkerSource.includes('$low_cap=1 if(low_shadow_3_4_luma_far_from_target($step,$luminance_err*100) && $low_cap < 1);') &&
    autocalWorkerSource.includes('$luma_cap=0.5 if($far_3_4_luma && $luma_cap < 0.5);') &&
    autocalWorkerSource.includes('return undef if($ire > 0 && $ire <= 2.5001);'),
  'Low-shadow 3%/4% luma movement should loosen only when far from target while keeping the 2.3% point protected'
);
assert(
  committedPolishSource.includes('my @shadow=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) }') &&
    !committedPolishSource.includes('my @shadow=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) }') &&
    committedPolishSource.includes('my @polish=$include_body ? (@headroom,@legal_white,@body) : (@headroom,@legal_white);') &&
    committedPolishSource.includes('push @polish,@shadow if($include_shadow);') &&
    committedPolishSource.includes('my $polish_total=scalar(@polish);') &&
    committedPolishSource.indexOf('push @polish,@shadow if($include_shadow);') < committedPolishSource.indexOf('my $polish_total=scalar(@polish);') &&
    source.includes('post_commit_true_low_shadow:postCommitPolishEnabled?undefined:false'),
  'Committed polish should include the low-shadow tail in descending order before computing total when polish remains enabled'
);
{
  const polishRestoreIdx = committedPolishSource.indexOf('"Restoring committed $label polish"');
  const polishRestoreReadIdx = committedPolishSource.indexOf('"committed_polish_restore_read"', polishRestoreIdx);
  const polishRestoreCloneIdx = committedPolishSource.indexOf('$reading=clone_picture($best_reading);', polishRestoreIdx);
  assert(
      autocalWorkerSource.includes('sub lg_autocal_26_standalone_committed_cleanup_enabled') &&
      autocalWorkerSource.includes('return 1 if(autocal_config_is_post_3d_polish($config));') &&
      autocalWorkerSource.includes('return 0 if($config->{"full_workflow"} || autocal_config_is_touchup($config));') &&
      autocalWorkerSource.includes('sub clear_committed_measurement_state') &&
      autocalWorkerSource.includes('sub prepare_standalone_committed_off_cal_read') &&
      autocalWorkerSource.includes('"committed_read_calibration_off"') &&
      autocalWorkerSource.includes('end_calibration_mode($picture_mode);') &&
      committedPolishSource.includes('clear_committed_measurement_state($state,1) if(lg_autocal_26_standalone_committed_cleanup_enabled($config));') &&
      committedPolishSource.includes('post_commit_polish_read_settle_ms') &&
      committedPolishSource.includes('prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_read","post_commit_polish_read_settle_ms",6000)') &&
      committedPolishSource.includes('prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$committed_pair_step,"committed_polish_pair_read","post_commit_polish_read_settle_ms",6000)') &&
      committedPolishSource.includes('prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_measurement","post_commit_polish_read_settle_ms",6000)') &&
      committedPolishSource.includes('prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_restore_read","post_commit_restore_read_settle_ms",6000)') &&
      polishRestoreReadIdx > polishRestoreIdx &&
      polishRestoreReadIdx < polishRestoreCloneIdx &&
      !committedPolishSource.includes('"Restoring committed $label verify best"') &&
      !committedPolishSource.includes('"committed_low_shadow_restore_read"') &&
      !committedPolishSource.includes('"committed_low_shadow_final_restore_read"'),
    'Standalone committed polish should clear stale chart values and read restored off-CAL state instead of replotting old best samples'
  );
}
assert(
  propagate26Source.includes('my ($arrays,$calibrated_slot_mask,$source_slot_mask)=@_;') &&
    propagate26Source.includes('$source_slot_mask=$calibrated_slot_mask if(ref($source_slot_mask) ne "ARRAY");') &&
    propagate26Source.includes('next if($calibrated_slot_mask->[$idx]);') &&
    propagate26Source.includes('lg_autocal_26_lut_indexes()') &&
    propagate26Source.includes('my $black_anchor=lg_autocal_26_black_lut_anchor();') &&
    autocalWorkerSource.includes('sub linear_interpolated_26pt_curve_value') &&
    autocalWorkerSource.includes('sub bounded_hermite_26pt_curve_value') &&
    autocalWorkerSource.includes('sub interpolated_26pt_curve_value') &&
    propagate26Source.includes('my @knots=({ x=>$black_anchor+0, y=>0 });') &&
    propagate26Source.includes('next if(!$source_slot_mask->[$idx]);') &&
    propagate26Source.includes('push @knots,{ x=>$lut_indexes[$idx]+0, y=>$arr->[$idx]+0 };') &&
    propagate26Source.includes('my $value=interpolated_26pt_curve_value($lut_indexes[$idx]+0,$setting_knots{$setting});') &&
    propagate26Source.includes('$arr->[$idx]=clamp_ddc_value($value);') &&
    propagate26Source.indexOf('next if($calibrated_slot_mask->[$idx]);') < propagate26Source.indexOf('$arr->[$idx]=clamp_ddc_value') &&
    !propagate26Source.includes('next if(!defined($right));') &&
    autocalWorkerSource.includes('my @calibrated_ddc_slots=map { 0 } (1..ddc_slot_count());') &&
    dynamicFinalizeSource.includes('mark_calibrated_26pt_slot(\\@calibrated_ddc_slots,$final_target);') &&
    dynamicFinalizeCallCount >= 3 &&
    propagate26Call >= 0 &&
    final1dCommitCall >= 0 &&
    propagate26Call < final1dCommitCall,
  'LG 26-point AutoCal should finalize accepted anchors through a dynamic helper and propagate only uncalibrated slots from an explicit calibrated-slot mask before final 1D LUT commit'
);
assert(
  autocalWorkerSource.includes('sub autocal_config_is_post_series_adjust') &&
    autocalWorkerSource.includes('sub post_cal_series_adjustment') &&
    autocalWorkerSource.includes('post_cal_series_readings') &&
    autocalWorkerSource.includes('post_cal_adjustment_reference') &&
    autocalWorkerSource.includes('lg_autocal_26_learned_luminance_adjustment(') &&
    autocalWorkerSource.includes('set_picture_values($picture,$arrays,$write_target,$picture_mode,1,$state,1,1)') &&
    autocalWorkerSource.includes('if(autocal_config_is_post_series_adjust($config))'),
  'Full AutoCal post-3D series adjustment should estimate one committed DDC correction pass from the committed 26pt read'
);
assert(
  blackAnchor26Source.includes('sub lg_autocal_26_black_lut_anchor') &&
    blackAnchor26Source.includes('return 0;') &&
    !propagate26Source.includes('my $left_point=defined($left) ? ($lut_indexes[$left]+0) : 0;') &&
    !propagate26Source.includes('my $left_value=(defined($left) && defined($arr->[$left])) ? ($arr->[$left]+0) : 0;') &&
    autocalWorkerSource.includes('return linear_interpolated_26pt_curve_value($x,$knots->[$left_idx],$knots->[$left_idx+1]) if(@{$knots} < 5);') &&
    autocalWorkerSource.includes('return bounded_hermite_26pt_curve_value($x,$knots,$left_idx);') &&
    autocalWorkerSource.includes('$y=$min_y if($y < $min_y);') &&
    autocalWorkerSource.includes('$y=$max_y if($y > $max_y);'),
  'LG 26-point propagation should use a named black LUT anchor helper instead of raw black-anchor literals'
);
assert(
  refresh26Source.includes('my ($config,$arrays,$calibrated_slot_mask)=@_;') &&
    refresh26Source.includes('return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});') &&
    refresh26Source.includes('my $source_slot_mask=$calibrated_slot_mask;') &&
    refresh26Source.includes('my $filled=propagate_uncalibrated_26pt_slots($arrays,$calibrated_slot_mask,$source_slot_mask);') &&
    refresh26Source.includes('my $overrides=apply_full_ddc_spine_headroom_seed_overrides($config,$arrays,$calibrated_slot_mask);') &&
    refresh26Source.includes('return $filled+$overrides;'),
  'LG 26-point propagation refresh should be wrapped in a named helper with mask plumbing'
);
assert(
    dynamicFinalizeSource.includes('my $before_arrays=clone_arrays($arrays);') &&
    dynamicFinalizeSource.includes('refresh_propagated_uncalibrated_26pt_slots($config,$arrays,\\@calibrated_ddc_slots);') &&
    dynamicFinalizeSource.includes('my $after_arrays=clone_arrays($arrays);') &&
    dynamicFinalizeSource.includes('my @changed_slot_details;') &&
    dynamicFinalizeSource.includes('$changed_settings{$setting}={ before=>$before+0, after=>$after+0 };') &&
    dynamicFinalizeSource.includes('ire=>defined($dynamic_seed_slots[$idx]) ? ($dynamic_seed_slots[$idx]+0) : undef') &&
    dynamicFinalizeSource.includes('$state->{"dynamic_propagated_26pt_slot_details"}=\\@changed_slot_details;') &&
    dynamicFinalizeSource.includes('changed_slot_details=>\\@changed_slot_details') &&
    dynamicFinalizeSource.includes('next if($calibrated_ddc_slots[$idx]);') &&
    dynamicFinalizeSource.includes('set_picture_values($picture,$arrays,$final_target,$picture_mode,$calibration_mode_active,$state)') &&
    dynamicFinalizeSource.includes('"Dynamic 26pt seed propagation updated $changed_slots pending slots"') &&
    refresh26Source.includes('return 0 if(calibrated_non_black_26pt_anchor_count($source_slot_mask) < $minimum_anchors);') &&
    !dynamicFinalizeSource.includes('next if(defined($left_anchor) && defined($right_anchor));') &&
    !dynamicFinalizeSource.includes('$arrays->{$setting}[$idx]=$before_arrays->{$setting}[$idx];'),
  'LG 26-point AutoCal should dynamically propagate accepted anchors, write changed whole-curve seeds before the next point, protect calibrated slots, and wait for three non-black anchors before broad propagation'
);
const topCandidateMask = topWindowPolishSource.indexOf('my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);');
const topCandidateMark = topWindowPolishSource.indexOf('mark_calibrated_26pt_candidate_slots($candidate_calibrated_slot_mask,$candidate);', topCandidateMask);
const topCandidateRefresh = topWindowPolishSource.indexOf('refresh_propagated_uncalibrated_26pt_slots($config,$candidate_arrays,$candidate_calibrated_slot_mask);', topCandidateMark);
const topCandidateWrite = topWindowPolishSource.indexOf('set_picture_values($picture,$candidate_arrays,$anchor,$picture_mode,1,$state,1,1)', topCandidateRefresh);
const stateCandidateMask = committedPolishSource.indexOf('my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);');
const stateCandidateMark = committedPolishSource.indexOf('mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);', stateCandidateMask);
const stateCandidateRefresh = committedPolishSource.indexOf('refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$candidate_calibrated_slot_mask);', stateCandidateMark);
const stateCandidateWrite = committedPolishSource.indexOf('set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1)', stateCandidateRefresh);
assert(
  topWindowPolishSource.includes('$signal_mode,$calibrated_slot_mask)=@_;') &&
    topWindowPolishSource.includes('my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);') &&
    topCandidateMask >= 0 &&
    topCandidateMark > topCandidateMask &&
    topCandidateRefresh > topCandidateMark &&
    topCandidateWrite > topCandidateRefresh &&
    topWindowPolishSource.includes('promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);') &&
    committedPolishSource.includes('$polish_steps,$calibrated_slot_mask)=@_;') &&
    committedPolishSource.includes('my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);') &&
    stateCandidateMask >= 0 &&
	    stateCandidateMark > stateCandidateMask &&
	    stateCandidateRefresh > stateCandidateMark &&
	    stateCandidateWrite > stateCandidateRefresh &&
	    !committedPolishSource.includes('committed_top_window_polish(') &&
	    /committed_state_polish\([\s\S]*?\\@ordered,\s*\\@calibrated_ddc_slots\s*\)/.test(autocalWorkerSource),
	  'Post-commit polish should pass candidate calibrated-slot masks through refresh before full-array writes without launching a separate top-window pass'
	);
{
  const finishPolishIdx = committedPolishSource.indexOf('$finish_polish->(undef);');
  const bodyVerifyCallIdx = committedPolishSource.indexOf('committed_body_verify_off_cal(', finishPolishIdx);
  const topWindowAfterPolishIdx = committedPolishSource.indexOf('committed_top_window_polish(', finishPolishIdx);
  const finalVerifyCallIdx = committedPolishSource.indexOf('committed_final_all_level_verify(', finishPolishIdx);
  const completionIdx = committedPolishSource.indexOf('$state->{"committed_polish"}={ status=>"complete"', finishPolishIdx);
  assert(
    finishPolishIdx >= 0 &&
      completionIdx > finishPolishIdx &&
      bodyVerifyCallIdx === -1 &&
      topWindowAfterPolishIdx === -1 &&
      finalVerifyCallIdx === -1 &&
      !committedPolishSource.includes('"Committed verify $label"') &&
      !committedPolishSource.includes('"committed_low_shadow_read"'),
    'LG committed polish should finish after the single top-to-bottom pass without separate committed verify, top-window, or final all-level adjustment sessions'
  );
}
assert(
    source.includes('function meterLgAutoCalBodyLumaBiasPayload(dtype)') &&
    source.includes('body_luma_bias_mode:\'observe\'') &&
    source.includes('10:-0.006') &&
    (source.match(/\.\.\.meterLgAutoCalBodyLumaBiasPayload\(dtype\)/g) || []).length >= 2,
  'LG C2 greyscale AutoCal and touch-up should send the validated body luminance bias matrix for observation'
);
assert(
  source.includes("const savedTargetGamma=(s.target_gamma!=null)?String(s.target_gamma):'';") &&
    source.includes("if(savedTargetGamma!==''){") &&
    source.includes("setVal('meterTargetGamma', savedTargetGamma);") &&
    source.includes('}else{\n  applyMeterTargetGammaDefault();\n }'),
  'Meter settings load should preserve a saved target gamma instead of overwriting it with the default on boot'
);
assert(
  source.includes('function syncDvOutputEotfState()') &&
    source.includes("if(getVal('signal_mode')==='dv') setVal('eotf','2');") &&
    source.includes("return meterDvMapModeValue()==='2' ? '2.2' : 'st2084';") &&
    source.includes('$meter_target_gamma_auto=($dv_map_mode eq "2") ? "2.2" : "st2084";') &&
    source.includes('<option value="2">Relative (Calibration)</option>') &&
    source.includes('<option value="1">Absolute (Mastering)</option>') &&
    !source.includes('id="dv_eotf"'),
  'DV should keep HDMI EOTF forced to PQ while defaulting Relative target gamma to 2.2 and Absolute to ST2084 without adding a duplicate DV-card target control'
);
assert(
  autocalWorkerSource.includes('hdr20_body_luminance_opposite_probe') &&
    autocalWorkerSource.includes('opposite_luminance_suppressed') &&
    autocalWorkerSource.includes('foreach my $try_direction ($direction,-$direction)'),
  'HDR body AutoCal should probe the opposite luminance DDC direction when the expected sign is blocked or has proven to move Y the wrong way'
);
assert(
  legalWhitePairReferenceSource.includes('lg_autocal_26_sdr_headroom_enabled($config)') &&
    legalWhitePairReferenceSource.includes('lg_autocal_26_hdr20_seed_enabled($config)') &&
    legalWhitePairReferenceSource.includes('hdr20_shared_top_white_pair_target($target)') &&
    !legalWhitePairReferenceSource.includes('!$config->{"lg_autocal_26"}'),
  'LG Auto Cal paired white balancing should be gated to SDR 99/100 or HDR 95/100 shared-slot modes, not just lg_autocal_26'
);
assert(
  shiftedStimulusStepSource.includes('return undef if(!lg_autocal_26_sdr_headroom_enabled($config));') &&
    fixedLgAutoCalStepSource.includes('return $step if(!lg_autocal_26_sdr_headroom_enabled($config));'),
  'LG Auto Cal fixed/shifted stimulus remapping should stay disabled for HDR/non-SDR workflows'
);
assert(
  autoCalTargetGammaSource.includes("function meterLgAutoCalGreyscaleTargetGammaValue()") &&
    autoCalTargetGammaSource.includes("return meterLgAutoCalRequestedSignalMode()==='hdr10'?'2.2':meterAutoCalTargetGammaValue();") &&
    lgAutoCalGreyscalePayloadGammaCount >= 5 &&
    source.includes("return mode==='hdr10'?'hdr10':'sdr';") &&
    source.includes("if(requested==='hdr10'){\n  setVal('eotf','2');") &&
    source.includes('requested_signal_mode:signalMode'),
  'WebUI HDR LG Auto Cal should use Power 2.2 targets while keeping requested output transport HDR10/PQ'
);
assert(
    source.includes('const METER_LG_GREY_HDR_AUTOCAL_SLOTS=[100,94.98,89.95,84.93,79.91,69.86,59.82,50.23,40.18,30.14,25.11,20.09,15.07,10.05,6.85,5.02,4.11,2.74,1.83,1.37];') &&
    source.includes('const METER_LG_GREY_HDR_AUTOCAL_CODES=[235,224,213,202,191,169,147,126,104,82,71,60,49,38,31,27,25,22,20,19];') &&
    source.includes('function meterLgHdrAutoCalDdcArrayIre(slot)') &&
    source.includes('return slot;') &&
    !source.includes('if(Math.abs(value-94.98)<0.001) return 100;') &&
    !source.includes('if(Math.abs(value-89.95)<0.001) return 94.98;') &&
    !source.includes('if(Math.abs(value-84.93)<0.001) return 89.95;') &&
    !source.includes('if(Math.abs(value-79.91)<0.001) return 84.93;') &&
    autocalWorkerSource.includes('return (1.37,1.83,2.74,4.11,5.02,6.85,10.05,15.07,20.09,25.11,30.14,40.18,50.23,59.82,69.86,79.91,84.93,89.95,94.98,100) if($layout eq "hdr20");') &&
    autocalWorkerSource.includes('sub hdr20_effective_ddc_array_ire') &&
    autocalWorkerSource.includes('return $value;') &&
    !autocalWorkerSource.includes('return 100 if(abs($value-94.98) < 0.001);') &&
    !autocalWorkerSource.includes('return 94.98 if(abs($value-89.95) < 0.001);') &&
    !autocalWorkerSource.includes('return 89.95 if(abs($value-84.93) < 0.001);') &&
    !autocalWorkerSource.includes('return 84.93 if(abs($value-79.91) < 0.001);') &&
	    autocalWorkerSource.includes('sub hdr20_top_white_chroma_priority_needed') &&
	    autocalWorkerSource.includes('hdr20_body_luminance=>1') &&
	    autocalWorkerSource.includes('if(autocal_step_is_hdr20_body($step)) {') &&
	    autocalWorkerSource.includes('return 0 if(abs($lum_pct) > luminance_tolerance_percent($step));') &&
	    autocalWorkerSource.includes('my $floor=($ire >= 80) ? 0.6 : 3;') &&
	    autocalWorkerSource.includes('!hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta) && hdr20_top_white_luminance_priority_needed') &&
	    !autoCalTargetLuminanceSource.includes('target_gamma_linear($signal,"2.2","sdr")'),
	  'HDR20 AutoCal should use exact code-derived HDR weighted slots with identity DDC mapping, calibrate 100% instead of SDR-style paired 99/100, use the supplied AutoCal target curve, and avoid luma-only HDR100 moves while chroma is still high'
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
    !lgSource.includes('appId => $app_id') &&
    !lgSource.includes('"" => $app_name') &&
    !lgSource.includes('CHgjyv0gsB4sHNSJ2VVHFdk4') &&
    !lgSource.includes('Test Remote App') &&
    !lgSource.includes('use_calibration_identity'),
  'LG registration should use the public LG Remote App signed manifest, not a custom or opt-in identity path'
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
    source.includes('await meterAutoCalLoadPanelLightValue(true);') &&
    !source.includes('LG kept ') &&
    !source.includes('Adjust TV settings now if needed') &&
    !source.includes('message:meterAutoCalResetNotice+') &&
    autoCalDdcResetSource.includes('/api/lg/picture-settings/set') &&
    autoCalDdcResetSource.includes('reset_ddc_baseline:true') &&
    source.includes('async function meterAutoCalReset3dLutBaseline()') &&
    source.includes("/api/lg/3d-lut/reset") &&
    source.includes('Writing unity 3D LUT baseline before greyscale') &&
    source.includes('if(meterAutoCalPendingConfig&&meterAutoCalPendingConfig.fullWorkflow)') &&
    source.indexOf('await meterAutoCalResetDdc();') < source.indexOf('await meterAutoCalReset3dLutBaseline();') &&
    !autoCalDdcResetSource.includes('/api/lg/picture-settings/reset'),
  'LG Auto Cal should clear the DDC table, Full Auto Cal should also reset the LG 3D LUT baseline before greyscale, refresh retained panel light silently, and continue to the luminance setup step'
);
assert(
  /my \(\$session,\$ip,\$picture_mode,\$timeout,\$reset_to_unity(?:,\$layout)?\)=@_;/.test(lgSource) &&
    lgSource.includes('&lg_write_1d_lut_file($path,$unity);') &&
    lgSource.includes('$reset_ddc_baseline=$reset_ddc_baseline ? 1 : 0;') &&
    lgSource.includes('$calibration_mode_active=0 if($reset_ddc_baseline);') &&
    lgSource.includes('sub lg_lut_matches') &&
    /&lg_ddc_baseline_lut\(\$session,\$ip,\$picture_mode,\$timeout,\$reset_ddc_baseline(?:,\$ddc_layout)?\)/.test(lgSource) &&
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
    source.includes('$lg_greyscale_21=0;') &&
    source.includes('const METER_LG_GREY_MANUAL_22_ENABLED=false;'),
  'LG 22pt manual mapping should be gated off while regular 21pt custom stimulus tables remain available'
);
assert(
  source.includes('\\"analysis_ire\\":$analysis_ire,\\"target_ire\\":$analysis_ire,\\"transport_stimulus\\":$stim') &&
    source.includes('function meterLgSdrLegalStimulusFromCode(code)') &&
    source.includes('const analysisIre=meterLgSdrLegalStimulusFromCode(step.g);') &&
    source.includes('function meterGreyChartStimulusIre(item)') &&
    source.includes('function meterGreyChartPlotIre(item)') &&
    source.includes('step.transport_stimulus=entry.stimulus;') &&
    source.includes('const candidates=[reading.analysis_ire,reading.target_ire') &&
    source.includes('if(code!=null&&(meterChartIsHdr()||meterGreyAllowsHeadroomTargets()||headroomCode)) return meterGreySignalFractionFromCode(code);'),
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
  source.includes('meter init failed|meter enumeration failed|failed to enumerate') &&
    source.includes('"/tmp/spotread_port_cache"'),
  'Meter session startup should clear the stale Argyll port cache and retry when enumeration fails'
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
	  const preserveReturn = autocalWorkerSource.indexOf('return @valid if($config->{"lg_autocal_preserve_step_order"} || $config->{"preserve_step_order"});', orderStart);
	  const productionOrder = autocalWorkerSource.indexOf('my @lg_autocal_26_order=(109,105,99,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3);', orderStart);
	  const targetKey = autocalWorkerSource.indexOf('my $target_key=sub', productionOrder);
	  const leftoverSort = autocalWorkerSource.indexOf('my @leftovers=sort', targetKey);
	  const returnOrdered = autocalWorkerSource.indexOf('return (@ordered,@leftovers);', leftoverSort);
	  const skipDuplicate = autocalWorkerSource.indexOf('sub autocal_skip_duplicate_ddc_slot');
  assert(
    orderStart >= 0 &&
	      preserveReturn > orderStart &&
	      productionOrder > preserveReturn &&
	      targetKey > productionOrder &&
	      leftoverSort > targetKey &&
	      returnOrdered > leftoverSort &&
	      skipDuplicate >= 0 &&
	      skipDuplicate < orderStart &&
      autocalWorkerSource.includes('!autocal_skip_duplicate_ddc_slot($_)') &&
	      autocalWorkerSource.includes('defined($step->{"ddc_target_ire"}) ? $step->{"ddc_target_ire"} : $step->{"ire"}') &&
		      autocalWorkerSource.includes('my $target=ddc_target_for_step($step);') &&
			      autocalWorkerSource.includes('return @valid if($config->{"lg_autocal_preserve_step_order"} || $config->{"preserve_step_order"});') &&
	      lgAutocalAbHarnessSource.includes('process.env.PRESERVE_STEP_ORDER') &&
	      lgAutocalAbHarnessSource.includes('payload.lg_autocal_preserve_step_order = true;') &&
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
	      autocalWorkerSource.includes('if(!$adjustments && stimulus_probe_enabled($config) && !autocal_step_is_peak_headroom($read_step) && !$pair_target_reached_now->())') &&
	      autocalWorkerSource.includes('if(stimulus_probe_enabled($config) && $needs_stimulus_probe)') &&
      autocalWorkerSource.includes('return (undef,$reading,$arrays,$picture,undef) if(!stimulus_probe_enabled($config));'),
	    'LG Auto Cal should calibrate the 26pt anchor spine first while preserving requested test order'
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
			    !autocalWorkerSource.includes('return 1 if($ire > 0 && $ire <= 3.1 && $de <= 0.25);') &&
			    !autocalWorkerSource.includes('return 1 if($ire <= 5 && $de <= 4.0);') &&
				    autocalWorkerSource.includes('return 4 if($ire <= 3.1);') &&
				    autocalWorkerSource.includes('return 3.5 if($ire <= 5);') &&
				    autocalWorkerSource.includes('return 3 if($ire <= 7.5);') &&
					    autocalWorkerSource.includes('return 2.5 if($ire <= 10);') &&
				    autocalWorkerSource.includes('$value=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $value < 0);') &&
			    autocalWorkerSource.includes('sub implausible_autocal_read') &&
		    autocalWorkerSource.includes('sub read_step_guarded') &&
		    autocalWorkerSource.includes('Rejecting implausible Auto Cal read') &&
		    autocalWorkerSource.includes('$ratio >= 0.35 && $ratio <= 2.20') &&
		    autocalWorkerSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
	    autocalWorkerSource.includes('sub chroma_error_magnitude') &&
	    autocalWorkerSource.includes('neutral_luminance=>1') &&
		    autocalWorkerSource.includes('$luminance_err=0 if(autocal_step_suppresses_luminance_adjustment($step));') &&
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
				    autocalWorkerSource.includes('$keep_tuning_luma=1 if(abs($lum_pct) > $luma_gate && !ddc_target_near_limit($arrays,$target,42));') &&
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
				    autocalWorkerSource.includes('sub autocal_step_is_peak_headroom') &&
				    autocalWorkerSource.includes('return autocal_step_is_peak_headroom($step);') &&
				    autocalWorkerSource.includes('sub headroom_iteration_limit_for_step') &&
				    autocalWorkerSource.includes('my $limit=($ire >= 108.5) ? 60 : 36;') &&
				    autocalWorkerSource.includes('sub headroom_polish_limit_for_step') &&
				    autocalWorkerSource.includes('my $limit=($ire >= 108.5) ? 16 : 10;') &&
			    autocalWorkerSource.includes('sub autocal_step_allows_final_fine_tune') &&
				    autocalWorkerSource.includes('sub headroom_autocal_result_score') &&
				    autocalWorkerSource.includes('sub headroom_fine_target_delta') &&
				    autocalWorkerSource.includes('sub headroom_needs_fine_tune') &&
				    autocalWorkerSource.includes('return 0 if(headroom_needs_fine_tune($de,$target_delta,$reading,$step));') &&
				    autocalWorkerSource.includes('my $headroom_score=headroom_autocal_result_score($de,$reading,$step);') &&
				    autocalWorkerSource.includes('sub choose_headroom_single_adjustment') &&
			    autocalWorkerSource.includes('sub headroom_chroma_adjustment') &&
			    autocalWorkerSource.includes('headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0)') &&
			    autocalWorkerSource.includes('sub headroom_rgb_luminance_adjustments') &&
				    autocalWorkerSource.includes('headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$step,"main_headroom_luminance")') &&
				    autocalWorkerSource.includes('sub headroom_proportional_adjustment') &&
				    autocalWorkerSource.includes('my $ideal=$start - ($e0*($end-$start)/($e1-$e0));') &&
				    autocalWorkerSource.includes('proportional=>1') &&
				    autocalWorkerSource.includes('headroom_queued_adjustment_still_best($headroom_next_adjustments,$err,$de,$target_delta,$read_step)') &&
				    !autocalWorkerSource.includes('return 0 if(autocal_step_is_fast_headroom($step) && !headroom_rgb_balanced($reading,$target_delta,$step));') &&
				    !autocalWorkerSource.includes('Backtracking to best $label result after rejected headroom step') &&
				    autocalWorkerSource.includes('autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta)') &&
				    autocalWorkerSource.includes('$polish_limit=headroom_polish_limit_for_step($read_step,$config);') &&
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
	    autocalWorkerSource.includes('if($mode eq "hdr10" && lc($target_gamma||"") eq "st2084")') &&
	    autocalWorkerSource.includes('my $pq_y=pq_decode_nits($signal);') &&
	    autocalWorkerSource.includes('return ($pq_y > $white_y) ? $white_y : $pq_y;') &&
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
			    autocalWorkerSource.includes('my $pair_target_reached_now=sub') &&
			    autocalWorkerSource.includes('last if($pair_target_reached_now->());') &&
			    autocalWorkerSource.includes('sub choose_micro_adjustments') &&
			    autocalWorkerSource.includes('Starting final fine tune for $label') &&
			    autocalWorkerSource.includes('Fine tuning $label') &&
			    autocalWorkerSource.includes('$polish_limit=48 if(!defined($polish_limit));') &&
		    autocalWorkerSource.includes('$best_de <= ($target_delta+0.15)') &&
				    autocalWorkerSource.includes('next_untried_value($current,$dir*$effective_mag,$tried,$setting,$min_micro_step,$strict_tried)') &&
				    autocalWorkerSource.includes('last if($polish_stalls >= $precision_stall_limit);') &&
		    autocalWorkerSource.includes('my $probe_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);') &&
			    autocalWorkerSource.includes('if(defined($de) && autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct) && $probe_score + 0.0001 < $best_score)') &&
		    autocalWorkerSource.includes('Keeping best $label result') &&
	    autocalWorkerSource.includes('target_gamma=>$target_gamma') &&
	    autocalWorkerSource.includes('setup_luminance_reference=>$setup_luminance_reference||$target_luminance||undef') &&
	    autocalWorkerSource.includes('target_luminance=>$target_luminance||undef') &&
	    autocalWorkerSource.includes('headroom_target_luminance=>$headroom_target_luminance||undef') &&
	    autocalWorkerSource.includes('my $white_y=($target_luminance > 0) ? $target_luminance : undef;') &&
	    autocalWorkerSource.includes('set_state_white_reference($state,$white_y) if(autocal_step_is_white($read_step));') &&
		    autocalWorkerSource.includes('return $white_y if(autocal_step_is_white($step));') &&
			    autocalWorkerSource.includes('target_step_luminance') &&
			    autocalWorkerSource.includes('return $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE if($LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE > 0);') &&
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
    source.includes('$read_command.=" $cmd_signal_range $cmd_transport_signal_range $cmd_request_id $patch_input_max $cmd_read_timeout"') &&
    meterSessionSource.includes('REQUEST_ID INPUT_MAX CMD_READ_TIMEOUT') &&
    meterSessionSource.includes('[[ "$CMD_READ_TIMEOUT" == "-" ]] && CMD_READ_TIMEOUT=""') &&
    meterSessionSource.includes('\\"request_id\\":\\"$REQUEST_ID\\"') &&
    meterSessionSource.includes('READ_TIMEOUT=90') &&
    meterSessionSource.includes('ire_le "$IRE" 25 && READ_TIMEOUT=120') &&
    meterSessionSource.includes('ire_le "$IRE" 5 && READ_TIMEOUT=140') &&
    meterSessionSource.includes('CMD_READ_TIMEOUT >= 10') &&
    meterSessionSource.includes('READ_TIMEOUT="$CMD_READ_TIMEOUT"') &&
    meterSessionSource.includes('READ_TIMEOUT > 300') &&
    source.includes('return meterPollRead(timeoutMs||180000,shouldCancel);') &&
    source.includes('async function meterStartSingleReadWithTimeout') &&
    source.includes('await meterPollRead(180000,()=>!meterContinuousActive)') &&
    source.includes('const invalidatedByLgWrite=readSuspendToken!==meterContinuousSuspendToken') &&
    source.includes('meter read state stale for ${age}s') &&
    source.includes('$timeout_sec=40 if($timeout_sec < 40);') &&
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
    autocalWorkerSource.includes('my $final_reached=$pair_target_reached_now->();') &&
	    source.includes('target_gamma:meterAutoCalTargetGammaValue()') &&
	    source.includes('return Math.max(10,Math.min(10000,setup*peakRatio));') &&
	    source.includes("message:hdrWorkflow") &&
	    source.includes("'Using 100% target '+targetY.toFixed(2)+' cd/m\\u00B2 and 109% target '+headroomY.toFixed(2)+' cd/m\\u00B2'"),
  'LG Auto Cal/manual reads should include gamma/luminance error, reject stale results, and keep meter sessions healthy'
);
	assert(
	    autocalWorkerSource.includes('sub autocal_step_is_low_shadow') &&
	    autocalWorkerSource.includes('return ($ire > 0 && $ire <= 10.0001) ? 1 : 0;') &&
    autocalWorkerSource.includes('sub low_shadow_luminance_priority_adjustments') &&
    autocalWorkerSource.includes('my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);') &&
    autocalWorkerSource.includes('my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,1);') &&
	    autocalWorkerSource.includes('sub autocal_config_is_touchup') &&
	    autocalWorkerSource.includes('return 8 if($ire <= 3.1);') &&
	    autocalWorkerSource.includes('return 10 if($ire <= 4.1);') &&
    autocalWorkerSource.includes('return 1 if($ire <= 3.1);') &&
    autocalWorkerSource.includes('return 2;') &&
    autocalWorkerSource.includes('sub low_shadow_delta_acceptance') &&
    autocalWorkerSource.includes('return 1 if(autocal_step_is_low_shadow($step) && $de <= low_shadow_delta_acceptance($step,$target_delta));') &&
    autocalWorkerSource.includes('my $shadow_limit=low_shadow_iteration_limit_for_step($step,$config);') &&
    autocalWorkerSource.includes('my $shadow_polish_limit=low_shadow_polish_limit_for_step($read_step,$config);') &&
	    autocalWorkerSource.includes('$adj->{"low_shadow_luminance"}=1'),
  'LG Auto Cal shadow points should prioritize per-point luminance before spending slow low-level reads on RGB polish, with shorter Full AutoCal touch-up limits'
);
assert(
  autocalWorkerSource.includes('sub low_shadow_luminance_response_escalation') &&
    autocalWorkerSource.includes('return ($base_cap,1,"protected_noise_floor",0) if($ire > 0 && $ire <= 2.5001);') &&
    autocalWorkerSource.includes('my ($scaled_cap,$response_multiplier,$cap_reason,$insufficient)=low_shadow_luminance_response_escalation($step,$before_lum_pct,$after_lum_pct,$cap);') &&
    autocalWorkerSource.includes('return undef if($previous_improvement < -0.05);') &&
    autocalWorkerSource.includes('low_shadow_luminance_response_scaled') &&
    autocalWorkerSource.includes('insufficient_response_x2') &&
    autocalWorkerSource.includes('insufficient_response_x1_5'),
  'LG Auto Cal shadow luminance response should escalate bounded follow-up moves when learned Y movement is too weak, while protecting 2.3% and suppressing wrong-direction pushes'
);
{
  const helperIdx = autocalWorkerSource.indexOf('sub low_shadow_chroma_luminance_coupled_adjustments');
  const chooseIdx = autocalWorkerSource.indexOf('sub choose_adjustments');
  const lumaCallIdx = autocalWorkerSource.indexOf('my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);', chooseIdx);
  const coupledCallIdx = autocalWorkerSource.indexOf('my $shadow_chroma_luma=low_shadow_chroma_luminance_coupled_adjustments($error,$arrays,$target,$luminance_err,$de,0.5,$tried,$step,0);', lumaCallIdx);
  const genericLumaIdx = autocalWorkerSource.indexOf('my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_luma_step,$strict_tried,$step,"main_luminance");', coupledCallIdx);
  const genericRgbIdx = autocalWorkerSource.indexOf('my $rgb_step=adjustment_step(abs($err),$de,$stalls,$min_step);', coupledCallIdx);
  const outerLumaIdx = autocalWorkerSource.indexOf('$adjustments=low_shadow_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,$read_step,0);');
  const outerCoupledIdx = autocalWorkerSource.indexOf('$adjustments=low_shadow_chroma_luminance_coupled_adjustments($err,$arrays,$target,$lum_err,$de,$target_delta,\\%tried_values,$read_step,0) if(!$adjustments);', outerLumaIdx);
  const outerResponseIdx = autocalWorkerSource.indexOf('$adjustments=choose_rgb_response_adjustments($err,$arrays,$target,\\%rgb_response_model,\\%tried_values,$de,$read_step,$target_delta,$stalls,$lum_err)', outerCoupledIdx);
  assert(
    helperIdx >= 0 &&
      lumaCallIdx > chooseIdx &&
      coupledCallIdx > lumaCallIdx &&
      genericLumaIdx > coupledCallIdx &&
      genericRgbIdx > coupledCallIdx &&
      outerLumaIdx > helperIdx &&
      outerCoupledIdx > outerLumaIdx &&
      outerResponseIdx > outerCoupledIdx &&
      autocalWorkerSource.includes('return undef if($ire > 0 && $ire <= 2.5001);') &&
      autocalWorkerSource.includes('$rgb_cap=1.0 if($ire <= 5.1001);') &&
      autocalWorkerSource.includes('$rgb_cap=0.5 if($ire <= 4.1001);') &&
      autocalWorkerSource.includes('source=>"low_shadow_chroma_luma"') &&
      autocalWorkerSource.includes('low_shadow_chroma_luma=>1') &&
      autocalWorkerSource.includes('low_shadow_chroma_luma response_multiplier'),
    'LG Auto Cal low-shadow cleanup should use coupled RGB plus small Y guard after luminance priority, before generic RGB, with bounded 5% and <=4% moves'
  );
}
{
  const bodyPriorityIdx = autocalWorkerSource.indexOf('sub body_luminance_priority_adjustments');
  const bodyPriorityCallIdx = autocalWorkerSource.indexOf('body_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,$read_step)', bodyPriorityIdx);
  const rgbResponseIdx = autocalWorkerSource.indexOf('choose_rgb_response_adjustments($err,$arrays,$target,\\%rgb_response_model,\\%tried_values,$de,$read_step,$target_delta,$stalls,$lum_err)', bodyPriorityCallIdx);
  assert(
      bodyPriorityIdx >= 0 &&
      bodyPriorityCallIdx > bodyPriorityIdx &&
      rgbResponseIdx > bodyPriorityCallIdx &&
      autocalWorkerSource.includes('my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);') &&
      autocalWorkerSource.includes('if(!$adjustments && !$headroom_105_luma_blocking && !$headroom_105_near_y_cleanup_active)') &&
      autocalWorkerSource.includes('return undef if(autocal_step_is_low_shadow($step) || (autocal_step_is_fast_headroom($step) && !$headroom_105_body) || autocal_step_is_white($step) || strict_tried_for_step($step));') &&
      autocalWorkerSource.includes('$threshold=8 if($threshold < 8);') &&
      autocalWorkerSource.includes('$adj->{"body_luminance_priority"}=1;'),
    'LG Auto Cal body points with large luminance error should try adjustingLuminance before RGB response chasing, while excluding legal-white, low-shadow, and unseeded headroom paths'
  );
}
assert(
  !autocalWorkerSource.includes('return $white_y if($stimulus >= 100);') &&
    !autocalWorkerSource.includes('return undef if((defined($stimulus) && $stimulus >= 100) || (defined($ire) && $ire >= 100));') &&
    autocalWorkerSource.includes('$signal=1.1 if($signal > 1.1);') &&
    autocalWorkerSource.includes('return 1 if($ire >= 99.9 && !defined($lum_pct));') &&
    autocalWorkerSource.includes('return 1 if($ire >= 99.9 && !defined($best_lum_pct));') &&
    !autocalWorkerSource.includes('$luminance_err=0 if($ire >= 99.9);') &&
	    autocalWorkerSource.includes('$luminance_err=0 if(autocal_step_suppresses_luminance_adjustment($step));') &&
	    autocalWorkerSource.includes('my $fine=($ire >= 108.5) ? $target_delta : 0.28;') &&
	    autocalWorkerSource.includes('my $headroom_score=headroom_autocal_result_score($de,$reading,$step);') &&
	    autocalWorkerSource.includes('$headroom_score+=$penalty;') &&
			    autocalWorkerSource.includes('my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried,$step,"main_luminance");') &&
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
		    autocalWorkerSource.includes('if(abs($lum_pct) > ($luma_tol*0.45) && chroma_error_magnitude($error) < 0.016)') &&
		    autocalWorkerSource.includes('apply_peak_headroom_reference($state,$read_step,$best_reading,\\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);'),
		  'LG Auto Cal should target 105% and 109% extended Y from the setup headroom model'
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
  const headroomIdx = committedPolishSource.indexOf('my @headroom=sort');
  const legalWhiteIdx = committedPolishSource.indexOf('my @legal_white=sort', headroomIdx);
  const bodyIdx = committedPolishSource.indexOf('my @body=sort', legalWhiteIdx);
  const shadowPushIdx = committedPolishSource.indexOf('push @polish,@shadow if($include_shadow);', bodyIdx);
  const peakRefReturnIdx = committedPolishReferenceSource.indexOf('return $peak_ref if($prefer_headroom && defined($peak_ref));');
  const committedRefReturnIdx = committedPolishReferenceSource.indexOf('return $committed_ref if(defined($committed_ref));');
  assert(
    autocalWorkerSource.includes('sub post_commit_polish_enabled') &&
      autocalWorkerSource.includes('return 1 if(!exists($config->{"post_commit_polish"}));') &&
      autocalWorkerSource.includes('return $config->{"post_commit_polish"} ? 1 : 0;') &&
      autocalWorkerSource.includes('if(post_commit_polish_enabled($config))') &&
      autocalWorkerSource.includes('committed_state_polish(') &&
      committedPolishReferenceSource.includes('$state->{"peak_headroom_reference"}+0') &&
      autocalWorkerSource.includes('derived_white_reference_from_peak_headroom($step,$reading,$target_gamma,$signal_mode);') &&
      committedPolishReferenceSource.includes('my $prefer_headroom=lg_autocal_26_sdr_headroom_enabled($config) ? 1 : 0;') &&
      peakRefReturnIdx > -1 &&
      committedRefReturnIdx > peakRefReturnIdx &&
      committedPolishSource.includes('my $white_y=committed_polish_reference_white_y($config,$state,$steps,$target_gamma,$signal_mode,undef);') &&
      committedPolishSource.includes('$state->{"message"}="Committed polish using committed headroom white reference";') &&
      committedPolishSource.includes('my $lock_committed_polish_white_reference=sub') &&
      committedPolishSource.includes('apply_peak_headroom_reference($state,$read_step,$reading,\\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);') &&
      committedPolishSource.includes('$state->{"committed_polish_white_y"}=$updated+0;') &&
      committedPolishSource.includes('$state->{"committed_polish_reference_locked"}=JSON::PP::true;') &&
      !committedPolishSource.includes('Reading committed 100% white reference') &&
      !committedPolishSource.includes('Refreshing committed 100% white after top-end polish') &&
      !committedPolishSource.includes('Committed white reference refreshed') &&
      headroomIdx > -1 &&
      legalWhiteIdx > headroomIdx &&
      bodyIdx > legalWhiteIdx &&
      shadowPushIdx > bodyIdx,
    'LG committed post-polish should be enabled by default, freeze the 109-derived white reference, and run high-to-low before configured shadows'
  );
			  assert(
			    hybridAutocalWorkerSource.includes('foreach my $ire (109,105,100,99,95)'),
			    'LG committed top-window candidate protection should reject fixes that improve 99/100 by sacrificing 105/109%'
			  );
			  assert(
			    hybridAutocalWorkerSource.includes('if(($best_score->{"over"}||0) == 0 && ($best_score->{"worst"}||9999) <= 0.95)') &&
			      hybridAutocalWorkerSource.includes('$state->{"committed_top_window_passed"}=1;') &&
			      hybridAutocalWorkerSource.includes('return ($picture,$arrays,undef);'),
			    'LG committed top-window should skip extra candidate writes once every protected point is at or below 0.95 dE'
			  );
}
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
		    source.includes('@ordered=(100,0,sort { $a <=> $b } grep { $_>0 && abs($_-100)>0.001 } @ire_vals);') &&
		    source.includes('read_delay_ms:3000') &&
		    source.includes('return [...(includeWhiteReference?[white]:[]),zero,...body,...passthrough];') &&
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
  source.includes('data-meter-autocal-panel-light') &&
    source.includes("document.querySelectorAll('[data-meter-autocal-panel-light]').forEach") &&
    source.includes('let meterAutoCalLuminanceReadBusy=false;') &&
    source.includes('let meterAutoCalPanelLightQueuedDelta=0;') &&
    source.includes('function meterAutoCalPanelLightQueuePending()') &&
    source.includes('const disablePanelLight=meterAutoCalLuminanceSetupActive?false:busy;') &&
    source.includes('meterAutoCalPanelLightQueuedDelta+=numericDelta;') &&
    source.includes('function meterAutoCalProcessQueuedPanelLight()') &&
    source.includes('meterAutoCalProcessQueuedPanelLight();') &&
    source.includes("lgBeginCommand('LG TV panel-light adjustment')") &&
    source.includes("await fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000})") &&
    !source.includes('let cancelledForPanelLight=false;') &&
    !source.includes('if(await meterAutoCalProcessQueuedPanelLight())') &&
    source.includes('meterAutoCalLuminanceReadBusy=true;') &&
    source.includes('input.disabled=disablePanelLight||unavailable;') &&
    source.includes("panelBusy?' (updating...)':(queued?' (queued...)':'')"),
  'LG Auto Cal panel-light controls should queue in the background without interrupting live luminance reads'
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
    source.includes('const lumaHtml=meterGreyTvSupportsLuminance(state)?meterGreyTvLuminanceHtml(selected?selected.lum:null,disabled,ddcReadOnly)'),
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
		    source.includes('function meterTargetShapedMeasuredSegments(steps,readingMap,axisMax,targetValueForSignal,scaleLuminance)') &&
		    source.includes('function meterGreyTargetLuminanceForChartPoint(signal,Lw,Lb,point)') &&
		    source.includes('function meterGreyTargetEotfChartValueForSignal(signal,Lw,Lb,point)') &&
		    source.includes("if(mode!=='luminance' && mode!=='eotf') return null;") &&
		    source.includes('const targetLum=meterGreyTargetLuminanceForChartPoint(signal,targetPeak,Lb||0,point);') &&
		    source.includes('(signal,point)=>meterLuminanceScaleValue(meterGreyTargetLuminanceForChartPoint(signal,targetPeak,Lb||0,point),yTop)') &&
	    source.includes('function effectiveGammaTopSlope') &&
	    source.includes('if(frac>=0.999999) return null;') &&
	    source.includes('if(topGamma) return;') &&
		    source.includes('const gammaYw=meterGammaValueReferenceY(sortedAll);') &&
		    source.includes('const chartYw=gammaYw||Yw||measuredPeak;') &&
		    source.includes('meterGreyscaleGammaValue(rd,chartYw)') &&
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
	    source.includes('function meterGreyEotfLuminancePlotIre(item)') &&
	    source.includes('const plot=meterGreyChartPlotIre(item);') &&
	    source.includes('function meterGreyEotfLuminanceChartX(step,steps,idx,axisMax)') &&
	    source.includes('const ire=meterGreyEotfLuminancePlotIre(step);') &&
	    source.includes('const plotSteps=meterFilterEotfLuminanceChartItems(targetSteps);') &&
	    source.includes('const validG=meterFilterEotfLuminanceChartItems(sorted).filter') &&
	    source.includes('xSteps:axisMax/10,ySteps:5') &&
	    source.includes('const allStepsRaw=meterSeriesSteps?meterGreyscaleSeriesSteps(meterSeriesSteps):null;') &&
	    source.includes('const allSteps=allStepsRaw?meterFilterLgAutoCalChartItems(allStepsRaw):null;') &&
	    source.includes('const gs=meterFilterLgAutoCalChartItems(rawGs);') &&
	    source.includes('const white=meterGreyscaleChartWhiteReference(sorted);') &&
		    source.includes('function meterGreyChartTargetXYZForReading(reading)') &&
		    source.includes('const ire=meterReadingAnalysisIre(reading)||(step?meterGreyChartStimulusIre(step):null);') &&
		    source.includes('const measuredDvTargetY=meterDvAbsoluteReadingTargetY(reading);') &&
		    source.includes('hcfrGreyRef(meterReadingAnalysisIre(rd)||rd.ire') &&
			    source.includes('const greyMode=meterGreyRefMode();') &&
			    source.includes('rgbBalance(rd,effectiveWhiteRGB,greyMode)') &&
			    source.includes('rgbBalance(rd,meterWhiteReading,meterGreyRefMode())') &&
			    source.includes('let center=targets.length') &&
    source.includes('return {min:center-half,max:center+half};') &&
	    source.includes('let yMin=95,yMax=105;') &&
	    source.includes("meterApplyLinearYZoom('chartRGB',yMin,yMax,100)") &&
	    source.includes("basePad||{t:34,r:15,b:30,l:55}") &&
		    source.includes('const halfRange=Math.max(isDelta?2:5') &&
	    source.includes('function meterEnsureChartYZoomInput(canvas)') &&
	    source.includes('function meterChartPointerIsOnYAxis(canvas,e)') &&
	    source.includes('const METER_CHART_Y_ZOOM_HELP_TEXT=') &&
	    source.includes('function meterDrawChartYZoomHelp(ctx,pad)') &&
	    source.includes('function meterChartYZoomHelpHit(e,canvasId)') &&
	    source.includes('return {cx:inset,cy:inset,radius:radius};') &&
	    source.includes("ctx.fillText('?',rect.cx,rect.cy+0.5);") &&
	    source.includes("canvas.removeAttribute('title');") &&
	    !source.includes("canvas.title=canvas.title||'Scroll or drag on the Y axis to zoom. Double-click the Y axis to reset.'") &&
	    source.includes('e.stopImmediatePropagation();') &&
	    source.includes('meterShowChartYZoomHelpTooltip(e);') &&
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
	    source.includes('const chartYw=gammaYw||Yw||measuredPeak;') &&
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

assert(
  source.includes("const readY=(rd.luminance!=null&&Number.isFinite(Number(rd.luminance)))?Number(rd.luminance).toFixed(3):'--';") &&
    source.includes("const targetY=(lumInfo.targetY!=null&&Number.isFinite(Number(lumInfo.targetY)))?Number(lumInfo.targetY).toFixed(3):'--';") &&
    source.includes("html+='<span>Read Y: '+readY+' cd/m\\u00B2</span> &nbsp; <span>Target Y: '+targetY+' cd/m\\u00B2</span>';") &&
    !source.includes("html+='Lum: '+(rd.luminance!=null?rd.luminance.toFixed(2):'--')+' cd/m\\u00B2';") &&
    !source.includes("html+='<br>Read Y: '+readY+' cd/m\\u00B2';") &&
    !source.includes("html+='<br>Target Y: '+targetY+' cd/m\\u00B2';"),
  'Greyscale chart hover should show Read Y and Target Y together, without redundant luminance rows'
);

function extractConst(name) {
  const token = `const ${name}=`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing const ${name}`);
  let i = start;
  while (i < source.length && source[i] !== ';') i++;
  return source.slice(start, i + 1).replace(/^const /, 'var ');
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
    extractConst('METER_CHART_LOG_KNEE_DIVISOR'),
    extractConst('METER_LUMINANCE_LOG_FLOOR_DIVISOR'),
	    extractFunction('meterEotfNormalizedEnabled'),
    extractFunction('meterEotfLogScaleEnabled'),
    extractFunction('meterLuminanceLogScaleEnabled'),
    extractFunction('meterLogScaleValue'),
    extractFunction('meterLogUnscaleValue'),
	    extractFunction('meterEotfScaleValue'),
	    extractFunction('meterEotfUnscaleValue'),
    extractFunction('meterLuminanceLogFloor'),
	    extractFunction('meterLuminanceScaleValue'),
    extractFunction('meterLuminanceUnscaleValue'),
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
}

{
  const eotfNormalizeContext = {};
  vm.createContext(eotfNormalizeContext);
  vm.runInContext([
    `
      let normalizedChecked = true;
      const document = {
        getElementById: (id) => {
          if (id === 'meterEotfNormalized') return { checked: normalizedChecked };
          if (id === 'meterEotfLogScale') return { checked: false };
          return null;
        }
      };
      function meterGreyEotfUsesPqCurve(){ return true; }
      function meterChartPqEncodeNormalized(v){ return v / 10000; }
    `,
    extractFunction('meterEotfNormalizedEnabled'),
    extractFunction('meterGreyEotfValueFromLuminance'),
    extractFunction('meterGreyNormalizedLuminanceValue'),
    extractFunction('meterGreyInverseEotfSignalFromLuminance'),
    extractFunction('meterGreyNormalizedEotfValueFromLuminance'),
    extractFunction('meterGreyMeasuredEotfValue'),
    extractFunction('meterGreyMeasuredNormalizedEotfValue'),
    extractFunction('meterGreyMeasuredEotfChartValue'),
    `
      globalThis.normalizedMeasured = meterGreyMeasuredEotfChartValue(50, 200);
      normalizedChecked = false;
      globalThis.absoluteMeasured = meterGreyMeasuredEotfChartValue(50, 200);
    `
  ].join('\n'), eotfNormalizeContext);
  assert(Math.abs(eotfNormalizeContext.normalizedMeasured - 0.25) < 1e-9, 'Normalized EOTF should scale PQ-style luminance to the measured peak');
  assert.strictEqual(eotfNormalizeContext.absoluteMeasured, 0.005, 'Non-normalized EOTF should keep absolute PQ EOTF-domain values so the checkbox changes the chart');
}

{
  const gammaNormalizeContext = {};
  vm.createContext(gammaNormalizeContext);
  vm.runInContext([
    `
      let normalizedChecked = true;
      const document = {
        getElementById: (id) => {
          if (id === 'meterEotfNormalized') return { checked: normalizedChecked };
          if (id === 'meterEotfLogScale') return { checked: false };
          if (id === 'meterTargetGamma') return { value: '2.0' };
          return null;
        }
      };
      function meterGreyEotfUsesPqCurve(){ return false; }
      function meterChartPqEncodeNormalized(v){ return v / 10000; }
      function meterGreyTargetGammaSelection(){ return '2.0'; }
    `,
    extractFunction('meterEotfNormalizedEnabled'),
    extractFunction('meterGreyNormalizedLuminanceValue'),
    extractFunction('meterGreyInverseEotfSignalFromLuminance'),
    extractFunction('meterGreyEotfValueFromLuminance'),
    extractFunction('meterGreyNormalizedEotfValueFromLuminance'),
    extractFunction('meterGreyMeasuredEotfValue'),
    extractFunction('meterGreyMeasuredNormalizedEotfValue'),
    extractFunction('meterGreyMeasuredEotfChartValue'),
    `
      globalThis.normalizedMeasured = meterGreyMeasuredEotfChartValue(25, 100);
      normalizedChecked = false;
      globalThis.absoluteMeasured = meterGreyMeasuredEotfChartValue(25, 100);
    `
  ].join('\n'), gammaNormalizeContext);
  assert(Math.abs(gammaNormalizeContext.normalizedMeasured - 0.25) < 1e-9, 'Normalized non-PQ EOTF should plot luminance ratio');
  assert(Math.abs(gammaNormalizeContext.absoluteMeasured - 0.5) < 1e-9, 'Non-normalized non-PQ EOTF should plot inverse-gamma signal level');
}

{
  const diffuseContext = {};
  vm.createContext(diffuseContext);
  vm.runInContext([
    `
      let signalMode = 'hdr10';
      let diffuseValue = '';
      const document = {
        getElementById: (id) => {
          if (id === 'meterHdrDiffuseWhite') return { value: diffuseValue };
          return null;
        }
      };
      function meterChartIsPq(){ return signalMode === 'hdr10' || signalMode === 'dv'; }
	      function meterChartIsDv(){ return signalMode === 'dv'; }
	      function meterChartHdrPeak(){ return 1000; }
	      function meterChartMasterPeak(){ return 1000; }
	      function meterDisplayTypeIsProjector(){ return true; }
	      function meterReadingsUseLgHeadroomReference(){ return true; }
	      function meterGreyHeadroomReferenceReading(){ return {}; }
      function meterGreyscaleReferenceReadings(readings){ return readings || []; }
      function meterGreySolvePeakFromHeadroomReading(){ return 50; }
    `,
    extractConst('METER_HDR_DIFFUSE_WHITE_DEFAULT'),
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
      let meterWhiteReading = null;
      let meterReadings = [];
      let meterAutoCalRunning = false;
      let meterAutoCalPolling = null;
      let meterActionPending = false;
      let meterFullAutoCalRunning = false;
      let meterFullAutoCalPhase = '';
      const document = { getElementById: () => ({ value: 'bt1886' }) };
      const window = { lgStatusState: {} };
      function meterReadingIsGreyscale(){ return true; }
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
      function meterTargetWhitePoint(){ return { X: 0.95047, Y: 1, Z: 1.08883, x: 0.3127, y: 0.329 }; }
      function meterLgTargetWhiteReferenceNits(){ return null; }
      function meterStoredLgTargetWhiteReferenceNits(){ return null; }
      function meterColorReferenceNits(){ return 200; }
      function meterColorSeriesReferenceNits(){ return 200; }
      function meterFindMeasuredWhiteReading(){ return null; }
      function meterChartBlackLevel(){ return 0; }
      function meterAnalysisGamut(){ return { xyzToRgb: [[1,0,0],[0,1,0],[0,0,1]], rgbToXyz: [[1,0,0],[0,1,0],[0,0,1]] }; }
      function xyzToLinRgb(X,Y,Z){ return [X,Y,Z]; }
      function linRgbToXyz(R,G,B){ return { X:R, Y:G, Z:B }; }
    `,
    extractFunction('meterReadingPlotIre'),
    extractFunction('meterStepNameKey'),
    extractFunction('meterCanonicalSeriesStep'),
    extractFunction('meterReadingLuminanceNits'),
    extractFunction('meterReadingHasLuminance'),
    extractConst('METER_LG_GREY_MANUAL_22_ENABLED'),
    extractFunction('meterUseLgGreyscale21'),
    extractFunction('meterUseLgAutoCal26'),
    extractFunction('meterGreyAllowsHeadroomTargets'),
    extractFunction('meterGreyCodeRange'),
    extractFunction('meterGreySignalFractionFromCode'),
    extractFunction('meterGreyCodeLooksHeadroom'),
    extractFunction('meterGreyStimulusFraction'),
    extractFunction('meterGreyTargetSignal'),
    extractFunction('bt1886Eotf'),
    extractFunction('gammaEotf'),
    extractFunction('srgbEotf'),
    extractFunction('targetEotf'),
    extractFunction('meterChartTrackingLuminance'),
    extractFunction('meterChartTargetLuminance'),
    extractFunction('meterGreyTargetLuminance'),
    extractFunction('meterGreyChartTargetCode'),
    extractFunction('meterGreyHeadroomReferenceReading'),
    extractFunction('meterGreyStepCodeForIre'),
    extractFunction('meterGreySolvePeakFromHeadroomReading'),
    extractFunction('meterGreyTargetPeakForReadings'),
    extractFunction('meterGreyChartStimulusIre'),
    extractFunction('meterGreyChartPlotIre'),
    extractFunction('meterGreyEotfLuminancePlotIre'),
    extractFunction('meterEotfLuminanceAxisMax'),
    extractFunction('meterGreyEotfLuminanceChartX'),
    extractFunction('meterFilterEotfLuminanceChartItems'),
    extractFunction('meterExplicitLgTargetWhiteReferenceNits'),
    extractFunction('meterSyntheticGreyWhiteReading'),
    extractFunction('meterReadingXYZ'),
    extractFunction('meterFindSeriesWhiteReading'),
    extractFunction('meterReadingIsAutoCalReferenceOnly'),
    extractFunction('meterGreyscaleReferenceReadings'),
    extractFunction('meterReadingsUseLgHeadroomReference'),
    extractFunction('meterLgHeadroomDerivedWhiteReferenceNits'),
    extractFunction('meterAutoCalGreyscaleTargetWhiteReferenceActive'),
    extractFunction('meterAutoCalGreyscaleTargetWhiteReferenceNits'),
    extractFunction('meterEffectiveGreyscaleWhiteReference'),
    extractFunction('meterGreyscaleChartWhiteReference'),
    extractFunction('meterLgAutoCalTargetYnForStimulus'),
    extractFunction('meterTargetXYZForReading'),
    `
      const steps = [{ ire: 99 }, { ire: 105 }, { ire: 109 }];
      const hiddenLegalWhite = { ire: 100, luminance: 200, Y: 200, X: 190, Z: 218, r_code: 940, g_code: 940, b_code: 940, autocal_white_reference: true, autocal_reference_only: true };
      const measured109 = { ire: 109, plot_ire: 109, luminance: 205.74, Y: 205.74, r_code: 1023, g_code: 1023, b_code: 1023 };
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
      const chartWhite = meterGreyscaleChartWhiteReference([hiddenLegalWhite, measured109]);
      const hiddenOnlyWhite = meterGreyscaleChartWhiteReference([hiddenLegalWhite]);
      globalThis.chartWhiteY = chartWhite && chartWhite.Y;
      globalThis.chartWhiteSynthetic = chartWhite && chartWhite.synthetic_target;
      globalThis.hiddenOnlyWhiteSynthetic = hiddenOnlyWhite && hiddenOnlyWhite.synthetic_target;
      globalThis.hiddenOnlyWhiteY = hiddenOnlyWhite && hiddenOnlyWhite.Y;
      globalThis.axisMax = meterEotfLuminanceAxisMax(steps);
      globalThis.filteredCount = meterFilterEotfLuminanceChartItems(steps).length;
      globalThis.x109 = meterGreyEotfLuminanceChartX({ ire: 109 }, steps, 2, globalThis.axisMax);
      meterActiveSeriesPoints = 21;
      globalThis.axisMax22 = meterEotfLuminanceAxisMax(steps);
      globalThis.filteredCount22 = meterFilterEotfLuminanceChartItems(steps).length;
      const manual22 = { ire: 2.5, plot_ire: 2.5, analysis_ire: 7.3059, target_ire: 7.3059, transport_stimulus: 6.7 };
      globalThis.manual22Stimulus = meterGreyChartStimulusIre(manual22);
      globalThis.manual22X = meterGreyEotfLuminanceChartX(manual22, [manual22], 0, 100);
      meterActiveSeriesPoints = 26;
      meterSeriesSteps = [
        { ire: 105, name: '105%', r: 984, g: 984, b: 984, target_x: 0.3127, target_y: 0.329, target_Yn: meterLgAutoCalTargetYnForStimulus((984 - 64) * 100 / 876) },
        { ire: 109, name: '109%', r: 1023, g: 1023, b: 1023, target_x: 0.3127, target_y: 0.329, target_Yn: meterLgAutoCalTargetYnForStimulus((1023 - 64) * 100 / 876) },
        { ire: 100, name: '100%', r: 940, g: 940, b: 940, target_x: 0.3127, target_y: 0.329, target_Yn: 1, autocal_white_reference: true, autocal_reference_only: true }
      ];
      const raw100 = { ire: 100, name: '100%', luminance: 200, Y: 200, X: 190, Z: 218, r_code: 940, g_code: 940, b_code: 940 };
      const raw105 = { ire: 105, name: '105%', luminance: 196.46, Y: 196.46, r_code: 984, g_code: 984, b_code: 984 };
      const raw109 = { ire: 109, name: '109%', luminance: 218.86, Y: 218.86, r_code: 1023, g_code: 1023, b_code: 1023 };
      meterReadings = [hiddenLegalWhite, raw105, raw109];
      const raw100Target = meterTargetXYZForReading(raw100);
      const raw105Target = meterTargetXYZForReading(raw105);
      const raw109Target = meterTargetXYZForReading(raw109);
      globalThis.raw100TargetY = raw100Target.Y;
      globalThis.raw100DeltaY = raw100.Y - raw100Target.Y;
      globalThis.raw105TargetY = raw105Target.Y;
      globalThis.raw109TargetY = raw109Target.Y;
      globalThis.rawTargetReferenceY = meterGreyscaleChartWhiteReference(meterReadings).Y;
      const committed100 = { ire: 100, name: '100%', luminance: 230, Y: 230, X: 218.5, Z: 250.7, r_code: 940, g_code: 940, b_code: 940 };
      meterReadings = [committed100, raw105, raw109];
      meterAutoCalRunning = true;
      meterFullAutoCalRunning = true;
      meterFullAutoCalPhase = 'post-3d-polish';
      const activeCommittedWhite = meterGreyscaleChartWhiteReference(meterReadings);
      const activeCommitted100Target = meterTargetXYZForReading(committed100);
      const activeCommitted109Target = meterTargetXYZForReading(raw109);
      globalThis.activeCommittedWhiteY = activeCommittedWhite && activeCommittedWhite.Y;
      globalThis.activeCommittedWhiteSynthetic = activeCommittedWhite && activeCommittedWhite.synthetic_target;
      globalThis.activeCommitted100TargetY = activeCommitted100Target.Y;
      globalThis.activeCommitted109TargetY = activeCommitted109Target.Y;
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
  assert(!headroomContext.chartWhiteSynthetic, 'LG 26pt chart white reference should use the measured legal-white read when present');
  assert.strictEqual(headroomContext.chartWhiteY, 200, 'LG 26pt chart white reference should stay anchored to measured 100% legal white');
  assert(!headroomContext.hiddenOnlyWhiteSynthetic, 'Hidden LG AutoCal legal-white reads should remain measured chart references');
  assert.strictEqual(headroomContext.hiddenOnlyWhiteY, 200, 'Hidden LG AutoCal legal-white reads should provide the greyscale chart white reference');
  assert.strictEqual(headroomContext.axisMax, 110, 'LG 26pt EOTF/Luminance charts should extend the x-axis to 110');
  assert.strictEqual(headroomContext.filteredCount, 3, 'LG 26pt EOTF/Luminance charts should include 99/105/109');
  assert(Math.abs(headroomContext.x109 - (109 / 110)) < 1e-9, '109% should plot at its proportional x position on the 110 axis');
  assert.strictEqual(headroomContext.axisMax22, 100, 'Non-AutoCal greyscale charts should keep the 100% EOTF/Luminance axis');
  assert.strictEqual(headroomContext.filteredCount22, 1, 'Non-AutoCal EOTF/Luminance charts should not plot headroom points');
  assert(Math.abs(headroomContext.manual22Stimulus - 7.3059) < 1e-9, 'LG 22pt EOTF/Luminance targets should still use the decoded stimulus value');
  assert(Math.abs(headroomContext.manual22X - 0.025) < 1e-9, 'LG 22pt EOTF/Luminance points should plot at the control-slot position');
  assert.strictEqual(headroomContext.raw100TargetY, 200, 'LG 26pt 100% target should use the measured 100% legal-white reference');
  assert(Math.abs(headroomContext.raw100DeltaY) < 1e-9, 'LG 26pt 100% should have zero luminance error against itself');
  assert(headroomContext.raw109TargetY > headroomContext.raw105TargetY, 'Raw post-series 109% readings should use the canonical LG 26 target_Yn above the 105% target');
  assert(headroomContext.raw105TargetY > headroomContext.rawTargetReferenceY && headroomContext.raw105TargetY < headroomContext.raw109TargetY, 'Raw post-series 105% readings should use the canonical super-white target_Yn instead of legal white');
  assert.strictEqual(headroomContext.rawTargetReferenceY, 200, 'Raw post-series legal-white reads should anchor the LG 26 report reference');
  assert(headroomContext.activeCommittedWhiteSynthetic, 'Active committed polish charts should synthesize white from the 109% headroom target');
  assert(headroomContext.activeCommittedWhiteY < 230, 'Active committed polish charts should not let a high 100% read become target white');
  assert(Math.abs(headroomContext.activeCommitted100TargetY - headroomContext.activeCommittedWhiteY) < 1e-6, 'Active committed polish 100% target should use the 109-derived white reference');
  assert(Math.abs(headroomContext.activeCommitted109TargetY - 218.86) < 0.05, 'Active committed polish 109% target should remain anchored to the 109% read, not the 100% read');
	}

{
  const headroomDeltaContext = {};
  vm.createContext(headroomDeltaContext);
  vm.runInContext([
    `
      function meterReadingIsGreyscale(){ return true; }
      function meterReadingAnalysisIre(reading){ return (reading && reading.analysis_ire != null) ? reading.analysis_ire : (reading && reading.ire); }
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
  assert.strictEqual(headroomDeltaContext.y109WithLum, 230, '109% ΔE with luminance enabled should use the modeled 109% target from 100% white');
  assert.strictEqual(headroomDeltaContext.y109WithoutLum, 200, '109% ΔE without luminance enabled should still use measured 109% Y');
  assert.strictEqual(headroomDeltaContext.y105WithLum, 230, '105% ΔE should still use the modeled luminance target when luminance is enabled');
  assert(headroomDeltaContext.hcfr109RefY > 5, 'HCFR-style 109% ΔE should use the modeled 109% target when luminance is enabled');
  assert(headroomDeltaContext.hcfr105RefY > 5, 'HCFR-style 105% ΔE should still use the modeled luminance target');
  assert(!headroomDeltaContext.perceptual109Stable, 'Perceptual RGB balance for 109% should change when Include luminance error is toggled');
  assert(headroomDeltaContext.perceptual105ChangesWithLum, 'Perceptual RGB balance for 105% should still include modeled luminance when requested');
  assert(!headroomDeltaContext.hcfr109Stable, 'HCFR-style RGB balance for 109% should change when Include luminance error is toggled');
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
  "function meterTargetWhitePoint(){ return { X: 0.95047, Y: 1, Z: 1.08883, x: 0.3127, y: 0.329 }; }",
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
  extractFunction('meterChartPqEncodeNormalized'),
  extractFunction('meterCodeFromSignalPercent'),
  extractFunction('meterLgSdrExtendedCodeFromPercent'),
  extractFunction('meterLgSdrLegalHeadroomCodeFromPercent'),
  extractFunction('meterLgAutoCalStimulusFromCode'),
  extractFunction('meterLgAutoCalCodeForSlot'),
  extractFunction('meterLgSdrLegalDdcCodeFromPercent'),
  extractFunction('meterLgSdrLegalStimulusFromCode'),
	  extractFunction('meterCodeFromSignalPercentWithOptions'),
	  extractConst('METER_LG_GREY_MANUAL_22_ENABLED'),
		  extractFunction('meterGreyDefaultSlots'),
		  extractFunction('meterUseLgGreyscale21'),
		  extractFunction('meterUseLgAutoCal26'),
		  extractConst('METER_GREY_SLOTS_HDR30'),
		  extractFunction('meterUseHdrGreyscale30'),
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
  extractFunction('meterLgAutoCalTargetYnForStimulus'),
  extractFunction('meterLgAutoCalTargetMetaForCode'),
  extractFunction('meterGreyProfileStepsKey'),
  extractFunction('meterGreyProfileTemplate'),
  extractFunction('meterGreyModeSignature'),
  extractFunction('meterGreyNormalizeProfilesState'),
  extractFunction('meterGreyActiveProfileKey'),
  extractFunction('meterGreyActiveProfile'),
  extractFunction('meterGreyProfileEntry'),
  extractFunction('meterGreySignalEntries'),
  extractFunction('meterSeriesStepIsGreyscale'),
  'function meterApplyColorSeriesTargetWhiteReference(steps){ return steps; }',
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
    return roundCode(16 + clamped * 219);
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
  state.meterTargetGamma = opts.targetGamma || (opts.mode === 'dv' ? context.meterDvAutoTargetGamma() : 'bt1886');
  context.meterActiveSeriesType = 'greyscale';
  context.meterActiveSeriesSignalMode = opts.mode;
  context.meterActiveSeriesPoints = opts.points || 21;
}

const modes = [
  { name: 'SDR', mode: 'sdr' },
  { name: 'HDR10', mode: 'hdr10' },
  { name: 'HLG', mode: 'hlg' },
  { name: 'DV absolute', mode: 'dv', dvMapMode: '1' },
  { name: 'DV relative', mode: 'dv', dvMapMode: '2' },
  { name: 'DV relative stale ST2084 dropdown', mode: 'dv', dvMapMode: '2', targetGamma: 'st2084' },
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
  JSON.stringify([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]),
  'LG-connected regular greyscale should use the generic 21pt stimulus slots while LG 22pt manual mapping is gated off'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 2.5),
  undefined,
  'LG 22pt manual-only 2.5% DDC slot should not appear while the mapped series is gated off'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 5).r,
  expectedGreyscaleCode(5, { mode: 'sdr', range: '1' }),
  'Regular 21pt 5% slot should use the standard limited-range 5% code'
);
assert(
  lgSeries.every(step => step.analysis_ire == null && step.target_ire == null && step.transport_stimulus == null),
  'Regular 21pt greyscale should not attach LG manual decoded-stimulus metadata'
);
assert.strictEqual(
  lgSeries.find(step => step.ire === 100).r,
  235,
  'Regular 21pt 100% slot should use code 235 reference white in limited range'
);
const lgAutoCalDefault = context.meterBuildLgAutoCalSteps(lgSeries);
const lgAutoCal25 = lgAutoCalDefault.find(step => step.ire === 25);
assert(Math.abs(lgAutoCal25.stimulus - 25.1141552511416) < 0.0001, 'LG Auto Cal 25% patch should use the captured 10-bit 284 level');
assert.strictEqual(lgAutoCal25.r, 284, 'LG Auto Cal 25% patch should use exact captured raw 10-bit code 284');
assert.strictEqual(lgAutoCal25.input_max, 1023, 'LG Auto Cal 25% patch should declare 10-bit input max');
assert.strictEqual(lgAutoCal25.preview_r, 71, 'LG Auto Cal 25% thumbnail should use the 8-bit preview code 71');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 2.3).r, 84, 'LG Auto Cal 2.3% patch should use exact captured raw 10-bit code 84');
assert(Math.abs(lgAutoCalDefault.find(step => step.ire === 2.3).target_Yn - Math.pow((84 - 64) / 876, 2.4)) < 1e-12, 'LG Auto Cal 2.3% series metadata should carry the same target_Yn used by AutoCal');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 50).r, 504, 'LG Auto Cal 50% patch should use exact captured raw 10-bit code 504');
assert(Math.abs(lgAutoCalDefault.find(step => step.ire === 50).stimulus - 50.2283105022831) < 0.0001, 'LG Auto Cal 50% patch should use the captured 10-bit 504 level');
assert(Math.abs(lgAutoCalDefault.find(step => step.ire === 50).target_Yn - Math.pow((504 - 64) / 876, 2.4)) < 1e-12, 'LG Auto Cal 50% series metadata should carry AutoCal target_Yn');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 75).r, 720, 'LG Auto Cal 75% patch should use exact captured raw 10-bit code 720');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 95).r, 896, 'LG Auto Cal 95% patch should use exact captured raw 10-bit code 896');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 99).r, 932, 'LG Auto Cal 99% near-white patch should use exact captured raw 10-bit code 932');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 100), undefined, 'LG Auto Cal 26pt patch set should not add an extra writable 100% legal-white anchor');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 105).r, 984, 'LG Auto Cal 105% headroom patch should use exact captured raw 10-bit code 984');
assert.strictEqual(lgAutoCalDefault.find(step => step.ire === 109).r, 1023, 'LG Auto Cal 109% top patch should use exact captured raw 10-bit code 1023');
assert(Math.abs(lgAutoCalDefault.find(step => step.ire === 109).target_Yn - Math.pow((1023 - 64) / 876, 2.4)) < 1e-12, 'LG Auto Cal 109% series metadata should preserve super-white target_Yn');

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
  expectedGreyscaleCode(35, { mode: 'sdr', range: '2' }),
  'Regular 21pt full-range output should use the standard 35% patch'
);
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).find(step => step.ire === 75).stimulus,
  75,
  'Regular 21pt 75% slot should use its visible stimulus'
);
assert.strictEqual(
  context.meterBuildStepsJS('greyscale', 21).some(step => Math.abs(step.ire - 97.9) < 0.001),
  false,
  'Regular 21pt series should not expose AutoCal-only 26-point headroom patches'
);
assert.strictEqual(
  context.meterMeasurementPatchSignalRange(),
  '2',
  'Regular 21pt full-range greyscale reads should request full-range patch metadata'
);
state.color_format = '0';
state.rgb_quant_range = '1';
assert.strictEqual(
  context.meterExtendedVideoHeadroomRequired(),
  false,
	  'Regular 21pt SDR should not require video-code transport for gated LG manual patches'
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

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startNeedle, endNeedle, label) {
  const start = source.indexOf(startNeedle);
  assert(start >= 0, `Missing start marker for ${label}`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `Missing end marker for ${label}`);
  return source.slice(start, end);
}

const helperSource = sliceBetween(
  'sub post_cal_series_adjustment_luma_cap {',
  'sub post_cal_series_adjustment_reference {',
  'post-series one-shot helpers'
);

assert(
  !helperSource.includes('sub post_cal_series_one_shot_skip_reason') &&
    !helperSource.includes('modest_error_one_shot_guard'),
  'post-cal one-shot DDC adjustment should attempt real outliers instead of hiding them behind broad skip rules'
);

assert(
  !helperSource.includes('return final_all_level_verify_adjustment_cap($step,"adjustingLuminance") if($ire <= 10.0001);') &&
    helperSource.includes('return 1.50 if($abs >= 25);') &&
    helperSource.includes('return 1.25 if($abs >= 15);') &&
    helperSource.includes('return 2.50 if($abs >= 12);') &&
    helperSource.includes('return 2.00 if($abs >= 15);') &&
    helperSource.includes('return 1.00 if($abs >= 8);') &&
    helperSource.includes('return 0.50 if($ire <= 10.1001);') &&
    helperSource.includes('return 0.75 if($ire >= 85 && $ire < 99 && $abs >= 2.5);'),
  'post-cal low-shadow one-shot moves should use bounded near-black caps instead of committed-verify caps'
);

assert(
  helperSource.includes('sub post_cal_series_direct_luminance_adjustment') &&
    helperSource.includes('sub post_cal_series_direct_luminance_fallback_enabled') &&
    helperSource.includes('return 1 if($ire <= 20.1001 && $abs >= 1.50);') &&
    helperSource.includes('my $direction=($lum_pct > 0) ? -1 : 1;') &&
    helperSource.includes('post_cal_series_capped_luma_next($current,$direction*$mag,$cap)') &&
    helperSource.includes('post_cal_one_shot=>1'),
  'post-cal direct luminance moves should cover low-shadow/body misses with the committed/CAL-off sign convention'
);

assert(
  helperSource.includes('sub post_cal_series_neighbor_protected_luma_cap') &&
    helperSource.includes('foreach my $neighbor_ire (4,3,2.3)') &&
    helperSource.includes('return $cap < 2.0 ? $cap : 2.0;'),
  'post-cal low-shadow luma caps should back off when lower dark-detail neighbors are already dim'
);

assert(
  helperSource.includes('sub post_cal_series_low_shadow_neighbor_risk') &&
    helperSource.includes('return undef if(!($ire > 4.1001 && $ire <= 5.1001));') &&
    helperSource.includes('if(abs($neighbor_lum+0) <= 2.5)') &&
    helperSource.includes('reason=>"stable_lower_shadow_neighbor"'),
  'post-cal 5% one-shot RGB should recognize stable lower shadow neighbors before stacking color moves with luma moves'
);

assert(
  helperSource.includes('sub post_cal_series_low_shadow_5_luma_suppression') &&
    helperSource.includes('return undef if(!($ire > 4.1001 && $ire <= 5.1001));') &&
    helperSource.includes('return undef if(defined($de) && ($de+0) <= ($base_delta+0.75));') &&
    helperSource.includes('return undef if(abs($lum_pct+0) >= 8.0);') &&
    helperSource.includes('reason=>"modest_5pct_luma_response_risk"'),
  'post-cal 5% should suppress modest direct luma-only moves that repeatedly turn into Magic Wand reverts'
);

assert(
  helperSource.includes('sub post_cal_series_deltae_luminance_assist_enabled') &&
    helperSource.includes('return 0 if($de <= 1.0);') &&
    helperSource.includes('return 0 if($ire > 50.1001);') &&
    helperSource.includes('return abs($lum_pct+0) >= 1.25 ? 1 : 0;') &&
    helperSource.includes('sub post_cal_series_generic_rgb_adjustment') &&
    helperSource.includes('post_cal_generic_rgb_fallback') &&
    helperSource.includes('source"}="post_cal_series_generic_rgb"'),
  'post-cal one-shot should still attempt generic luma/RGB corrections for dE>1 body misses when learned slopes are thin'
);

assert(
  helperSource.includes('sub post_cal_series_learned_luminance_adjustment') &&
    helperSource.includes('post_cal_series_response_table_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,$cap)') &&
    helperSource.includes('post_cal_series_smoothed_response_axis($state,$step,"luminance","adjustingLuminance",1)') &&
    helperSource.includes('foreach my $scale (post_cal_series_luma_scales($step,$lum_pct))') &&
    helperSource.includes('return undef if($slope <= 0);'),
  'post-cal one-shot should use a smoothed positive-response luminance table instead of unsafe CAL-on single-sample slopes'
);

assert(
  source.includes('ddc_per_error=>defined($ddc_per_error)') &&
    source.includes('error_delta=>defined($error_delta)') &&
    source.includes('sub lg_autocal_26_reading_response_for_delta') &&
    source.includes('qw(x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc)') &&
    source.includes('sub post_cal_series_mark_response_table_adjustments') &&
    source.includes('post_cal_response_table'),
  'calibration response model should expose per-patch DDC-per-error plus x/y/Y response data for post-cal compensation'
);

const adjustmentSource = sliceBetween(
  'sub post_cal_series_adjustment {',
  'sub committed_state_polish {',
  'post-series adjustment'
);

const legalGuardIndex = adjustmentSource.indexOf('post_cal_series_shared_legal_white_target($target)');
const learnedIndex = adjustmentSource.indexOf('post_cal_series_learned_luminance_adjustment(');
const directIndex = adjustmentSource.indexOf('post_cal_series_direct_luminance_adjustment(');

assert(legalGuardIndex >= 0, 'post-series adjustment should preserve the 99/100 legal-white guard');
assert(learnedIndex > legalGuardIndex, 'learned luma should only run after the legal-white guard');
assert(directIndex > learnedIndex, 'direct low-shadow luma fallback should run after learned luma is rejected');

assert(
  !adjustmentSource.includes('post_cal_series_one_shot_skip_reason(') &&
    !adjustmentSource.includes('post_cal_series_one_shot_guard'),
  'post-series one-shot adjustment should not add broad skip trace paths for high-error points'
);

assert(
  adjustmentSource.includes('my $luma_adjustments=ref($low_shadow_5_luma_suppressed) eq "HASH" ? undef : post_cal_series_learned_luminance_adjustment(') &&
    adjustmentSource.includes('post_cal_series_low_shadow_5_luma_suppression($control_step,$adjust_lum_pct,$adjust_de,$target_delta)') &&
    adjustmentSource.includes('post_cal_series_low_shadow_5_luma_suppressed') &&
    adjustmentSource.includes('ref($low_shadow_5_luma_suppressed) eq "HASH" ? undef : post_cal_series_learned_luminance_adjustment') &&
    adjustmentSource.includes('post_cal_series_neighbor_protected_luma_cap($luma_cap,$control_step,$adjust_lum_pct,$readings,$steps') &&
    adjustmentSource.includes('ref($low_shadow_5_luma_suppressed) ne "HASH" && post_cal_series_direct_luminance_fallback_enabled($control_step,$adjust_lum_pct)') &&
    adjustmentSource.includes('ref($low_shadow_5_luma_suppressed) ne "HASH" && post_cal_series_deltae_luminance_assist_enabled($control_step,$adjust_de,$adjust_lum_pct)') &&
    adjustmentSource.includes('post_cal_series_low_shadow_neighbor_risk($control_step,$readings,$steps,$white_y,$target_gamma,$signal_mode,$config,$state)') &&
    adjustmentSource.includes('my $suppress_rgb_for_low_shadow_neighbor=ref($low_shadow_neighbor_risk) eq "HASH" ? 1 : 0;') &&
    adjustmentSource.includes('post_cal_series_low_shadow_rgb_suppressed') &&
    adjustmentSource.includes('post_cal_series_allow_rgb_adjustment($control_step,$adjust_lum_pct,$luma_adjustments)') &&
    adjustmentSource.includes('post_cal_series_response_table_rgb_adjustment($state,$arrays,$target,$adjust_read_step,$adjust_reading,$adjust_de,$target_delta') &&
    adjustmentSource.includes('$rgb_adjustments=post_cal_series_generic_rgb_adjustment($state,$arrays,$target,$adjust_read_step,$adjust_reading,$adjust_de,$adjust_lum_pct,$target_delta') &&
    adjustmentSource.includes('if(!$suppress_rgb_for_low_shadow_neighbor && !$rgb_adjustments)') &&
    adjustmentSource.includes('my $adjustments=post_cal_series_merge_adjustments($luma_adjustments,$rgb_adjustments);'),
  'post-series compensation should prefer learned luma, suppress stacked 5% RGB when lower shadow is stable, and use generic RGB fallback for dE>1 misses'
);

function lowShadow5LumaSuppression(ire, lumPct, de, targetDelta = 0.5) {
  if (!(ire > 4.1001 && ire <= 5.1001)) return false;
  if (de <= targetDelta + 0.75) return false;
  if (Math.abs(lumPct) >= 8.0) return false;
  return true;
}

assert.strictEqual(
  lowShadow5LumaSuppression(5, 6.87839228455236, 1.79698275222276),
  true,
  'run-3 5% modest high-luma miss should avoid the direct luma move that reverted'
);
assert.strictEqual(
  lowShadow5LumaSuppression(5, 11.0, 1.8),
  false,
  '5% should remain luma-eligible when luminance error is large enough to need real luminance correction'
);
assert.strictEqual(
  lowShadow5LumaSuppression(4, 6.8, 1.8),
  false,
  '4% useful low-shadow correction should not inherit the 5% luma suppression'
);

function lowShadowNeighborRisk(ire, neighborLums) {
  if (!(ire > 4.1001 && ire <= 5.1001)) return false;
  return [4, 3, 2.3].some((neighborIre) => {
    const lum = neighborLums[neighborIre];
    return Number.isFinite(lum) && Math.abs(lum) <= 2.5;
  });
}

assert.strictEqual(
  lowShadowNeighborRisk(5, { 4: -15.96, 3: -1.43, 2.3: -17.13 }),
  true,
  'run-1 5% low-shadow case should suppress RGB stacking because 3% was already near target'
);
assert.strictEqual(
  lowShadowNeighborRisk(4, { 3: -1.43, 2.3: -17.13 }),
  false,
  '4% outlier should remain eligible for its useful low-shadow correction'
);
assert.strictEqual(
  lowShadowNeighborRisk(20, { 4: 0.2, 3: 0.1 }),
  false,
  'body patches should not inherit low-shadow RGB suppression'
);
assert.strictEqual(
  lowShadowNeighborRisk(5, { 4: -15.96, 3: -8.2, 2.3: -17.13 }),
  false,
  '5% should remain eligible for RGB when the lower shadow neighbors are not stable'
);

assert(
  adjustmentSource.includes('my $control_step=$read_step;') &&
    adjustmentSource.includes('$control_step=$read_step;') &&
    adjustmentSource.includes('$control_step->{"legal_white_pair_active"}=JSON::PP::true') &&
    adjustmentSource.includes('$adjust_read_step->{"legal_white_pair_active"}=JSON::PP::true'),
  'post-series 99/100 compensation should let the 100% read drive error while the writable 99% step drives DDC eligibility and caps'
);

assert(
  adjustmentSource.includes('my $pre_adjust_arrays=clone_arrays($arrays);') &&
    adjustmentSource.includes('before_delta_e=>defined($de) ? $de+0 : undef') &&
    adjustmentSource.includes('values_before=>trace_target_values($pre_adjust_arrays,$target)') &&
    adjustmentSource.includes('values_after=>trace_target_values($arrays,$target)') &&
    adjustmentSource.includes('pre_adjust_arrays=>$pre_adjust_arrays'),
  'post-series compensation should persist per-slot before/after DDC metadata for no-read failsafe restores'
);

assert(
  source.includes('sub post_cal_series_smoothed_response_axis') &&
    source.includes('foreach my $direction (-1,1)') &&
    source.includes('smoothed_neighbors'),
  'post-series response table should smooth thin patch samples using nearby above/below DDC slots'
);

assert(
  adjustmentSource.includes('post_cal_luma_only_deadband') &&
    helperSource.includes('sub post_cal_series_luma_only_deadband') &&
    helperSource.includes('sub post_cal_series_low_shadow_unstable_skip') &&
    helperSource.includes('my $base_delta=(defined($target_delta)') &&
    helperSource.includes('my $de_limit=($ire <= 2.3001) ? ($base_delta+0.75) : ($base_delta+0.25);') &&
    helperSource.includes('return 0 if(defined($de) && $de > $de_limit);') &&
    helperSource.includes('return 1 if($ire <= 2.3001 && abs($lum_pct+0) < 8.0);') &&
    adjustmentSource.includes('post_cal_series_low_shadow_unstable_skip($read_step,$lum_pct,$de,$target_delta)'),
  'post-series compensation should ignore tiny luma-only near-white noise and unstable moderate 4% one-shots without skipping real high-error outliers'
);

assert(
  source.includes('sub post_cal_series_revert_worse_adjustments') &&
    source.includes('sub post_cal_series_evaluated_entry_for_ire') &&
    source.includes('sub post_cal_series_low_shadow_neighbor_ires') &&
    source.includes('return (3) if(abs($ire-4) < 0.001);') &&
    source.includes('return (4,7) if(abs($ire-5) < 0.001);') &&
    source.includes('return (5) if(abs($ire-7) < 0.001);') &&
    source.includes('post_cal_series_after_readings') &&
    source.includes('post_cal_series_adjustment_status') &&
    source.includes('Magic Wand failsafe requires the verification series read') &&
    source.includes('my $evaluated=(ref($adjustment->{"evaluated"}) eq "ARRAY") ? $adjustment->{"evaluated"} : [];') &&
    source.includes('my $compare_before=defined($pair_before_de) ? $pair_before_de : $before_de;') &&
    source.includes('my $compare_after=defined($pair_after_de) ? $pair_after_de : $after_de;') &&
    source.includes('my $worse=(defined($compare_before) && defined($compare_after) && $compare_after > ($compare_before+$margin)) ? 1 : 0;') &&
    source.includes('foreach my $neighbor_ire (post_cal_series_low_shadow_neighbor_ires($read_step))') &&
    source.includes('next if(ref(post_cal_series_adjustment_change_for_step($changes,{ ire=>$neighbor_ire })) eq "HASH");') &&
    source.includes('post_cal_series_evaluated_entry_for_ire($evaluated,$neighbor_ire)') &&
    source.includes('my $crossed_target=defined($neighbor_after_de) && $neighbor_before_de <= ($base_delta+0.25) && ($neighbor_after_de+0) > ($base_delta+0.75);') &&
    source.includes('my $bad_worse=defined($neighbor_delta) && $neighbor_delta > $neighbor_margin && defined($neighbor_after_de) && ($neighbor_after_de+0) > ($base_delta+0.50);') &&
    source.includes('post_cal_series_neighbor_protective_revert') &&
    source.includes('post_cal_series_restore_values_before($arrays,$target,$change->{"values_before"})') &&
    source.includes('set_picture_values($picture,$arrays,$write_target,$picture_mode,1,$state,1,1)'),
  'post-series failsafe should reuse the existing post-adjust read and revert DDC slots whose own score or protected low-shadow neighbor reads worse'
);

function neighborProtectiveRevert({ changedIre, neighborIre, neighborChanged = false, before, after, target = 0.5 }) {
  const lowMap = { 4: [3], 5: [4, 7], 7: [5] };
  if (!lowMap[changedIre] || !lowMap[changedIre].includes(neighborIre)) return false;
  if (neighborChanged) return false;
  const crossed = before <= target + 0.25 && after > target + 0.75;
  const badWorse = after - before > 0.20 && after > target + 0.50;
  return crossed || badWorse;
}

assert.strictEqual(
  neighborProtectiveRevert({ changedIre: 4, neighborIre: 3, before: 0.398, after: 1.711 }),
  true,
  'run-2 4% change should be eligible for neighbor-protective revert because unchanged 3% crossed badly'
);
assert.strictEqual(
  neighborProtectiveRevert({ changedIre: 5, neighborIre: 4, before: 2.86, after: 1.58 }),
  false,
  '5% should not be neighbor-reverted when adjacent 4% improved'
);
assert.strictEqual(
  neighborProtectiveRevert({ changedIre: 7, neighborIre: 5, neighborChanged: true, before: 1.75, after: 3.73 }),
  false,
  '7% should not be blamed for 5% when 5% has its own changed slot and own failsafe decision'
);

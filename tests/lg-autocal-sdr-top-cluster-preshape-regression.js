const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startNeedle, endNeedle, from = 0) {
  const start = source.indexOf(startNeedle, from);
  assert(start >= 0, `${startNeedle} should be present`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `${endNeedle} should follow ${startNeedle}`);
  return source.slice(start, end);
}

const gateSource = sliceBetween(
  'sub sdr_top_cluster_preshape_enabled',
  'sub sdr_top_cluster_preshape_ires'
);
assert(
  gateSource.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    gateSource.includes('!lg_autocal_26_full_ddc_spine_enabled($config)') &&
    gateSource.includes('lg_autocal_26_hdr20_seed_enabled($config)') &&
    gateSource.includes('autocal_config_is_touchup($config)') &&
    gateSource.includes('autocal_config_is_post_3d_polish($config)') &&
    gateSource.includes('autocal_config_is_post_series_adjust($config)') &&
    gateSource.includes('autocal_config_is_post_series_revert($config)') &&
    gateSource.includes('lg_autocal_26_full_ddc_spine_anchors_complete($calibrated_slot_mask,$config)'),
  'top-cluster pre-shape must be SDR initial LG26 full-spine only, after anchors complete, and exclude HDR/touchup/polish/post-series'
);

const ireSource = sliceBetween(
  'sub sdr_top_cluster_preshape_ires',
  'sub sdr_top_cluster_preshape_99_far_low_luminance'
);
assert(
  ireSource.includes('return (105,99,95);'),
  'top-cluster pre-shape should read only 105/99/95 before their normal descent'
);

const protectionSource = sliceBetween(
  'sub sdr_top_cluster_preshape_protection_enabled',
  'sub sdr_top_cluster_preshape_99_far_low_luminance'
);
assert(
  protectionSource.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    protectionSource.includes('!lg_autocal_26_full_ddc_spine_enabled($config)') &&
    protectionSource.includes('lg_autocal_26_hdr20_seed_enabled($config)') &&
    protectionSource.includes('autocal_config_is_touchup($config)') &&
    protectionSource.includes('autocal_config_is_post_3d_polish($config)') &&
    protectionSource.includes('($LG_AUTOCAL_STATE->{"sdr_top_cluster_preshape"}{"status"}||"") eq "complete"') &&
    protectionSource.includes('foreach my $protected_ire (sdr_top_cluster_preshape_ires())') &&
    protectionSource.includes('calibrated_26pt_slot_for_ire($calibrated_slot_mask,$ire)'),
  'completed SDR top-cluster pre-shape should protect pending 105/99/95 slots from later seed refresh without marking them calibrated'
);

const lumaGuardSource = sliceBetween(
  'sub sdr_top_cluster_preshape_99_far_low_luminance',
  'sub sdr_top_cluster_preshape_rgb_adjustments'
);
assert(
  lumaGuardSource.includes('abs(($ire+0)-99) >= 0.001') &&
    lumaGuardSource.includes('<= -6.0') &&
    lumaGuardSource.includes('($candidate_lum_pct+0) < ($best_lum_pct+0)-0.10') &&
    lumaGuardSource.includes('($candidate_lum_pct+0) > ($best_lum_pct+0)+0.25') &&
    lumaGuardSource.includes('setting=>"adjustingLuminance"') &&
    lumaGuardSource.includes('my $max_delta=abs($lum_pct+0) >= 10.0 ? 2.0 : 1.25;') &&
    lumaGuardSource.includes('sdr_top_cluster_preshape_luma_repair=>1') &&
    lumaGuardSource.includes('source=>"sdr_top_cluster_preshape_99_luma"'),
  '99 top pre-shape should detect far-low luminance, reject worse-Y candidates, and plan a bounded local luminance repair'
);

const adjustmentSource = sliceBetween(
  'sub sdr_top_cluster_preshape_rgb_adjustments',
  'sub body_final_micro_threshold'
);
assert(
  adjustmentSource.includes('sdr_top_legal_white_rgb_recovery_adjustments($arrays,$target,$metrics,$tried)') &&
    adjustmentSource.includes('return undef if(($adj->{"setting"}||"") eq "adjustingLuminance");') &&
    adjustmentSource.includes('my $max_delta=0.50;') &&
    adjustmentSource.includes('$copy{"sdr_top_cluster_preshape"}=1;') &&
    adjustmentSource.includes('$copy{"source"}="sdr_top_cluster_preshape_rgb";') &&
    adjustmentSource.includes('$copy{"luminance_ignored"}=JSON::PP::true;'),
  'top-cluster pre-shape RGB helper should reuse small RGB/chroma moves capped to 0.5 DDC and leave luminance moves to the 99 far-low repair helper'
);

const runSource = sliceBetween(
  'my $run_sdr_top_cluster_preshape=sub',
  'my $white_refreshed_after_headroom=0;'
);
for (const event of [
  'sdr_top_cluster_preshape_start',
  'sdr_top_cluster_preshape_read',
  'sdr_top_cluster_preshape_move',
  'sdr_top_cluster_preshape_accept',
  'sdr_top_cluster_preshape_reject',
  'sdr_top_cluster_preshape_skip',
  'sdr_top_cluster_preshape_complete'
]) {
  assert(runSource.includes(event), `trace should include ${event}`);
}
assert(
  runSource.includes('foreach my $preshape_ire (sdr_top_cluster_preshape_ires())') &&
    runSource.includes('my $limit=config_positive_int($config,"sdr_top_cluster_preshape_iterations",2,0,2);') &&
    runSource.includes('my $drive_lum_pct=luminance_error_percent($reading,$target_step_y);') &&
    runSource.includes('!sdr_top_cluster_preshape_99_far_low_luminance($preshape_ire,$drive_lum_pct)') &&
    runSource.includes('sdr_top_cluster_preshape_99_luma_adjustments($arrays,$target,$drive_lum_pct,\\%tried,$preshape_ire)') &&
    runSource.includes('sdr_top_cluster_preshape_rgb_adjustments($arrays,$target,$drive_metrics,\\%tried)') &&
    runSource.includes('whiteBalanceRed|whiteBalanceGreen|whiteBalanceBlue|adjustingLuminance') &&
    runSource.includes('sdr_top_cluster_preshape_99_luma_worse($preshape_ire,$best_lum_pct,$candidate_lum_pct)') &&
    runSource.includes('reject_reason=>$luma_worse ? "far_low_luminance_worsened" : "rgb_score_not_improved"') &&
    runSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
    runSource.includes('$read_sdr_top_legal_white_validation->(') &&
    runSource.includes('sdr_top_cluster_preshape_legal_white_read') &&
    runSource.includes('diagnostic_only=>JSON::PP::true') &&
    runSource.includes('recovery_disabled=>JSON::PP::true') &&
    runSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state)') &&
    !runSource.includes('$drive_metrics=$legal_metrics;') &&
    !runSource.includes('$drive_kind="legal100";') &&
    !runSource.includes('remember_lg_autocal_26_best_known') &&
    !runSource.includes('mark_calibrated_26pt_slot'),
  'pre-shape pass should read/try bounded slot moves, repair far-low 99 luminance before RGB fallback, log legal 100 for 99 as diagnostic-only, write arrays, but not mark final bests or calibrated slots'
);

const fixtureBestLum = -14.1;
const fixtureRgbBetterButDarker = -14.6;
const fixtureLumaRepair = -13.7;
assert(
  fixtureRgbBetterButDarker < fixtureBestLum - 0.10,
  'fixture should represent the stopped-run failure: RGB/chroma can improve while already-far-low 99 luminance gets worse'
);
assert(
  fixtureLumaRepair > fixtureBestLum + 0.25,
  'fixture should represent the bounded 99 pre-shape luma repair acceptance band'
);

const mainPreludeSource = sliceBetween(
  'my $sdr_top_local_seed=apply_sdr_top_local_seed_105_from_80',
  'my $low_shadow_endpoint_seed=apply_sdr_low_shadow_endpoint_seed_2_3'
);
const localSeedIndex = source.indexOf('my $sdr_top_local_seed=apply_sdr_top_local_seed_105_from_80');
const preshapeCallIndex = source.indexOf('$run_sdr_top_cluster_preshape->($read_step);', localSeedIndex);
const lowShadowSeedIndex = source.indexOf('my $low_shadow_endpoint_seed=apply_sdr_low_shadow_endpoint_seed_2_3', localSeedIndex);
assert(
  mainPreludeSource.includes('$run_sdr_top_cluster_preshape->($read_step);') &&
    preshapeCallIndex > localSeedIndex &&
    preshapeCallIndex < lowShadowSeedIndex,
  'top-cluster pre-shape should run after the 105-from-80 local seed write and before normal 105/99/95 descent continues'
);

assert(
  source.includes('sub sdr_full_spine_below_5_seed_skip_ires') &&
    source.includes('return (2.3,3,4);'),
  'successful below-5 SDR seed exclusion must remain intact'
);

const skipMaskSource = sliceBetween(
  'sub lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask',
  'sub calibrated_26pt_slot_for_ire'
);
assert(
  skipMaskSource.includes('if(sdr_top_cluster_preshape_protection_enabled($config))') &&
    skipMaskSource.includes('foreach my $ire (sdr_top_cluster_preshape_ires())') &&
    skipMaskSource.includes('next if(calibrated_26pt_slot_for_ire($calibrated_slot_mask,$ire));') &&
    skipMaskSource.includes('$mask[$idx]=1 if(defined($idx) && $idx < @mask);'),
  'generic full-spine propagation should skip pre-shaped top slots until their normal calibration step owns them'
);

const topBlendSource = sliceBetween(
  'sub apply_sdr_top_body_blend_seed_overrides',
  'sub apply_full_ddc_spine_seed_corrections'
);
assert(
  topBlendSource.includes('!sdr_top_cluster_preshape_slot_protected($config,$calibrated_slot_mask,99)') &&
    topBlendSource.includes('next if(sdr_top_cluster_preshape_slot_protected($config,$calibrated_slot_mask,$target_ire));'),
  'local top blend overrides should not rewrite pre-shaped 99/95 before normal calibration'
);

const seedCorrectionSource = sliceBetween(
  'sub apply_full_ddc_spine_seed_corrections',
  'sub apply_full_ddc_spine_headroom_seed_overrides'
);
assert(
  seedCorrectionSource.includes('next if(sdr_top_cluster_preshape_slot_protected($config,$calibrated_slot_mask,$ire));'),
  'headroom/top seed correction loop should not overwrite pre-shaped pending 105/99/95 slots'
);

console.log('LG AutoCal SDR top-cluster pre-shape regression checks passed.');

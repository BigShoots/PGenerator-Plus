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
  'sub sdr_top_cluster_preshape_rgb_adjustments'
);
assert(
  ireSource.includes('return (105,99,95);'),
  'top-cluster pre-shape should read only 105/99/95 before their normal descent'
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
  'top-cluster pre-shape should reuse small RGB/chroma moves capped to 0.5 DDC and must not write adjustingLuminance'
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
    runSource.includes('sdr_top_cluster_preshape_rgb_adjustments($arrays,$target,$drive_metrics,\\%tried)') &&
    runSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
    runSource.includes('$read_sdr_top_legal_white_validation->(') &&
    runSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state)') &&
    !runSource.includes('remember_lg_autocal_26_best_known') &&
    !runSource.includes('mark_calibrated_26pt_slot'),
  'pre-shape pass should read/try bounded RGB moves, optionally read legal 100 for 99, write arrays, but not mark final bests or calibrated slots'
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

console.log('LG AutoCal SDR top-cluster pre-shape regression checks passed.');

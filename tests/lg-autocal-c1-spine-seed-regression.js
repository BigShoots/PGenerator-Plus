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

const skipMaskSource = sliceBetween(
  'sub lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask',
  'sub calibrated_26pt_slot_for_ire'
);
assert(
  skipMaskSource.includes('foreach my $ire (lg_autocal_26_full_ddc_spine_anchor_ddc_ires($config))') &&
    skipMaskSource.includes('$mask[$idx]=1;'),
  'full-DDC spine propagation must keep calibrated spine anchors protected'
);

const shadowSource = sliceBetween(
  'sub full_ddc_spine_shadow_seed_links',
  'sub apply_sdr_low_shadow_endpoint_seed_2_3'
);
assert(
  shadowSource.includes('sub full_ddc_spine_shadow_seed_links') &&
    shadowSource.includes('return ();') &&
    shadowSource.includes('sub apply_full_ddc_spine_shadow_seeds') &&
    shadowSource.includes('return 0;') &&
    !/source=>7,\s*target=>5/.test(source) &&
    !/source=>3,\s*target=>2\.3/.test(source),
  'retired fixed low-shadow offset chain, including the old 5% path, must stay retired'
);

const top105Source = sliceBetween(
  'sub apply_sdr_top_local_seed_105_from_80',
  'sub full_ddc_spine_seed_correction_deltas'
);
assert(
  top105Source.includes('whiteBalanceRed=>0.25') &&
    top105Source.includes('whiteBalanceGreen=>0.35') &&
    top105Source.includes('whiteBalanceBlue=>0.75') &&
    top105Source.includes('adjustingLuminance=>-0.50') &&
    top105Source.includes('my $trend_weight=0.05;') &&
    top105Source.includes('my $trend_cap=0.50;') &&
    top105Source.includes('prepare_105_from_calibrated_80_with_body_weighted_top_trend'),
  '105% seed should lean on calibrated 80% with only a small bounded 109% trend'
);

const seedCorrectionSource = sliceBetween(
  'sub full_ddc_spine_seed_correction_deltas',
  'sub apply_sdr_top_body_blend_seed_overrides'
);
assert(
  seedCorrectionSource.includes('"99"  => { adjustingLuminance => -0.75 }') &&
    seedCorrectionSource.includes('"95"  => { adjustingLuminance => -0.50 }') &&
    seedCorrectionSource.includes('"90"  => { adjustingLuminance => -0.25 }') &&
    !seedCorrectionSource.includes('whiteBalanceRed => -2.00') &&
    !seedCorrectionSource.includes('whiteBalanceGreen => 5.50') &&
    !seedCorrectionSource.includes('whiteBalanceBlue => 5.50') &&
    seedCorrectionSource.includes('my %post_105_deltas=();') &&
    !seedCorrectionSource.includes('return undef if($key eq "99" || $key eq "95");'),
  'post-105 99%/95%/90% seeds should use display-safe luma-only local offsets, not fixed RGB pushes'
);

const topBlendSource = sliceBetween(
  'sub apply_sdr_top_body_blend_seed_overrides',
  'sub apply_full_ddc_spine_seed_corrections'
);
assert(
  topBlendSource.includes('my $body_ire=80;') &&
    topBlendSource.includes('my $top_ire=105;') &&
    topBlendSource.includes('mode=>"sdr-top-local-seed-99-from-80"') &&
    topBlendSource.includes('reason=>"sdr_99_seed_from_80_without_105_shape"') &&
    topBlendSource.includes('source_ire=>$body_ire+0') &&
    topBlendSource.includes('offsets=>$deltas') &&
    topBlendSource.includes('if(!calibrated_26pt_slot_for_ire($calibrated_slot_mask,99))') &&
    !topBlendSource.includes('"99" => { top_weight=>0.22') &&
    topBlendSource.includes('"95" => { top_weight=>0.08, rgb_top_weight=>0.00') &&
    topBlendSource.includes('mode=>"sdr-top-local-seed-90-from-80-safe"') &&
    topBlendSource.includes('source_quality_gate=>$quality_99_for_90') &&
    topBlendSource.includes('body_weight=>$body_weight+0') &&
    topBlendSource.includes('top_weight=>$top_weight+0') &&
    topBlendSource.includes('rgb_top_weight=>defined($entry->{"rgb_top_weight"})') &&
    topBlendSource.includes('max_from_body=>$entry->{"max_from_body"}') &&
    topBlendSource.includes('record_full_ddc_spine_seed_detail') &&
    topBlendSource.includes('sdr_top_body_weighted_seed_from_80_and_measured_105'),
  '99% seed should be traceable local-from-80 while 95% keeps only a luma-weighted 105 blend and 90 gates bad 99'
);

function blendFromBody(body, top, weight, maxFromBody) {
  const raw = body + ((top - body) * weight);
  const offset = Math.max(-maxFromBody, Math.min(maxFromBody, raw - body));
  return body + offset;
}

const body = -8.75;
const top = -2.5;
const oldInterpolationWeight99 = 0.76;
const old99 = body + ((top - body) * oldInterpolationWeight99);
const new99 = blendFromBody(body, top, 0.22, 1.5);
assert(
  Math.abs(new99 - body) < Math.abs(old99 - body) * 0.4 &&
    !topBlendSource.includes('top_weight=>0.22'),
  'retired 99% body blend should stay retired; 99% now uses local 80% offsets instead of 105% shape'
);

const high99Source = sliceBetween(
  'sub sdr_top_99_high_error_rgb_adjustment',
  'sub body_final_micro_threshold'
);
assert(
  high99Source.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    high99Source.includes('abs(($step->{"ire"}+0)-99) >= 0.001') &&
    high99Source.includes('my $lum_pct=defined($luminance_err) ? (($luminance_err+0)*100) : undef;') &&
    high99Source.includes('if(defined($lum_pct) && $lum_pct < -10.0 && has_luminance_channel($arrays,$target))') &&
    high99Source.includes('my $luma_step=abs($lum_pct) >= 18.0 ? 6.0 : (abs($lum_pct) >= 14.0 ? 4.0 : 3.0);') &&
    high99Source.includes('my $luma_next=clamp_ddc_value($luma_current+$luma_step);') &&
    high99Source.includes('source=>"sdr_top_99_high_error_luma"') &&
    high99Source.includes('luma_coupled=>$luma_added ? JSON::PP::true : JSON::PP::false') &&
    source.includes('sdr_top_99_high_error_rgb_adjustment($LG_AUTOCAL_CONFIG,$error,$arrays,$target,$tried,$de,$step,$target_delta,$stalls,0.25,8.0,"sdr_top_99_high_error_response",$luminance_err)') &&
    source.includes('sdr_top_99_high_error_rgb_adjustment($config,$err,$arrays,$target,\\%polish_tried,$best_de,$read_step,$target_delta,$polish_stalls,0.25,4.0,"sdr_top_99_high_error_fine_tune",$lum_err)'),
  'high-error SDR 99% with low luminance should choose a coupled RGB + positive adjustingLuminance move, not RGB-only'
);

const top99LumaCleanupSource = sliceBetween(
  'sub sdr_top_99_luma_cleanup_adjustments',
  'sub body_final_micro_threshold'
);
assert(
  top99LumaCleanupSource.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    top99LumaCleanupSource.includes('abs(($step->{"ire"}+0)-99) >= 0.001') &&
    top99LumaCleanupSource.includes('return undef if($lum_pct >= -2.25);') &&
    top99LumaCleanupSource.includes('return undef if($chroma > 0.090 && defined($de) && $de > 5.0);') &&
    top99LumaCleanupSource.includes('my $max_step=($abs_lum >= 6.0) ? 1.0 : (($abs_lum >= 3.0) ? 0.75 : 0.50);') &&
    top99LumaCleanupSource.includes('neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,0,$step,$source||"sdr_top_99_luma_cleanup",$LG_AUTOCAL_STATE)') &&
    top99LumaCleanupSource.includes('$adj->{"sdr_top_99_luma_cleanup"}=1;') &&
    top99LumaCleanupSource.includes('trace_109($step,"sdr_top_99_luma_cleanup_plan"'),
  'SDR 99% luma cleanup should prioritize positive adjustingLuminance when Y is still low after the high-error seed'
);

const rgbResponseSource = sliceBetween(
  'sub choose_rgb_response_adjustments',
  'sub choose_micro_adjustments'
);
assert(
  rgbResponseSource.indexOf('sdr_top_99_high_error_rgb_adjustment($LG_AUTOCAL_CONFIG') >= 0 &&
    rgbResponseSource.indexOf('sdr_top_99_luma_cleanup_adjustments($LG_AUTOCAL_CONFIG') > rgbResponseSource.indexOf('sdr_top_99_high_error_rgb_adjustment($LG_AUTOCAL_CONFIG') &&
    rgbResponseSource.indexOf('sdr_top_99_luma_cleanup_adjustments($LG_AUTOCAL_CONFIG') < rgbResponseSource.indexOf('my $response_lum_pct='),
  'main SDR 99% response planning should try luma cleanup immediately after the high-error coupled path and before generic RGB response'
);

const microSource = sliceBetween(
  'sub choose_micro_adjustments',
  'sub describe_adjustments'
);
assert(
  microSource.indexOf('sdr_top_99_luma_cleanup_adjustments($LG_AUTOCAL_CONFIG') >= 0 &&
    microSource.indexOf('sdr_top_99_luma_cleanup_adjustments($LG_AUTOCAL_CONFIG') < microSource.indexOf('my %combined=map'),
  'fine SDR 99% polish should try luma cleanup before RGB micro sweeps so low-Y stalls do not burn polish budget'
);

const fineTuneSource = sliceBetween(
  'my $polish_stalls=0;',
  '$state->{"best_delta_e"}=$best_de;'
);
assert(
  fineTuneSource.indexOf('sdr_top_99_luma_cleanup_adjustments($config') >= 0 &&
    fineTuneSource.indexOf('sdr_top_99_luma_cleanup_adjustments($config') < fineTuneSource.indexOf('sdr_top_99_high_error_rgb_adjustment($config'),
  'fine-tune loop should continue SDR 99% low-Y recovery from the best state before spending attempts on high-error RGB'
);

const lowShadowEndpointSource = sliceBetween(
  'sub apply_sdr_low_shadow_endpoint_seed_2_3',
  'sub apply_sdr_low_shadow_local_spine_preseed'
);
assert(
  lowShadowEndpointSource.includes('my $target_ire=2.3;') &&
    lowShadowEndpointSource.includes('return 0 if(abs($ire-$target_ire) >= 0.001);') &&
    lowShadowEndpointSource.includes('return 0 if(calibrated_26pt_slot_for_ire($calibrated_slot_mask,$target_ire));') &&
    lowShadowEndpointSource.includes('my @source_ires=grep { calibrated_26pt_slot_for_ire($calibrated_slot_mask,$_) } (5,10,15);') &&
    lowShadowEndpointSource.includes('my $scale=0.55;') &&
    lowShadowEndpointSource.includes('my $max_lift=7.00;') &&
    lowShadowEndpointSource.includes('$changed_settings{"adjustingLuminance"}') &&
    lowShadowEndpointSource.includes('pre_first_read_2_3_from_calibrated_low_anchors') &&
    !lowShadowEndpointSource.includes('whiteBalanceRed') &&
    !lowShadowEndpointSource.includes('whiteBalanceGreen') &&
    !lowShadowEndpointSource.includes('whiteBalanceBlue'),
  '2.3% should get a pre-first-read luma endpoint seed from calibrated 5/10/15 anchors, not a fixed RGB/offset chain'
);

const mainLoopSource = sliceBetween(
  'my $sdr_top_local_seed=apply_sdr_top_local_seed_105_from_80',
  'my $seeded_move_damping=lg_autocal_26_seeded_move_damping_for_step'
);
assert(
  mainLoopSource.includes('my $low_shadow_endpoint_seed=apply_sdr_low_shadow_endpoint_seed_2_3') &&
    mainLoopSource.includes('trace_109($read_step,"sdr_low_shadow_endpoint_seed_2_3"') &&
    mainLoopSource.indexOf('apply_sdr_low_shadow_endpoint_seed_2_3') < mainLoopSource.indexOf('apply_sdr_low_shadow_local_spine_preseed'),
  '2.3% endpoint seed should run before the existing 3%-neighbor preseed and before the first measurement'
);

assert(
  source.includes('seed_overrides=>$LG_AUTOCAL_LAST_FULL_DDC_SPINE_SEED_DETAILS') &&
    source.includes('our $LG_AUTOCAL_LAST_FULL_DDC_SPINE_SEED_DETAILS = [];'),
  'spine propagation trace should include seed override breadcrumbs'
);

const retiredLowShadowBiasSource = sliceBetween(
  'sub low_shadow_committed_target_bias_pct_for_step',
  'sub low_shadow_committed_target_bias_allowed'
);
assert(
  retiredLowShadowBiasSource.includes('return (0,"low_shadow_bias_retired");') &&
    !source.includes('"5" => -0.16') &&
    !source.includes('"5"=>-0.16'),
  'no fixed default 5% post-upload/target-Y offset should be present'
);

console.log('LG AutoCal C1 spine seed regression checks passed.');

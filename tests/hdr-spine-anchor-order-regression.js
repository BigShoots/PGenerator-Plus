const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function block(start, end) {
  const blockStart = source.indexOf(start);
  const blockEnd = source.indexOf(end, blockStart);
  assert(blockStart >= 0 && blockEnd > blockStart, `${start} block should exist`);
  return source.slice(blockStart, blockEnd);
}

const anchorStart = source.indexOf('sub lg_autocal_26_full_ddc_spine_anchor_ires_for_layout {');
const anchorEnd = source.indexOf('sub lg_autocal_26_full_ddc_spine_anchor_ddc_ires_for_layout {', anchorStart);
assert(anchorStart >= 0 && anchorEnd > anchorStart, 'full-DDC spine anchor helper should exist');
const anchorSource = source.slice(anchorStart, anchorEnd);

assert(
  anchorSource.includes('return (100,5,20,40,60,80) if($layout eq "hdr20");'),
  'HDR20 full-DDC spine anchor order should include 5% before 20%'
);
assert(
  anchorSource.includes('return (109,20,40,60,80);') &&
    !anchorSource.includes('return (109,5,20,40,60,80);'),
  'SDR full-DDC spine anchor order should remain unchanged and exclude 5%'
);

const orderStart = source.indexOf('my @hdr_autocal_26_order=(lg_autocal_26_full_ddc_spine_anchor_ires_for_layout("hdr20"),@top_down);');
assert(orderStart >= 0, 'HDR20 AutoCal order should be built from the HDR full-DDC spine anchor helper');

const effectiveHdrSource = block(
  'sub hdr20_effective_ddc_array_ire {',
  'sub ddc_slots {'
);
assert(
  effectiveHdrSource.includes('return 1.4 if(abs(($ire+0)-2.0) < 0.001);') &&
    effectiveHdrSource.includes('return $ire+0;'),
  'HDR20 displayed 2% should resolve to the effective 1.4 DDC slot while other HDR points stay direct'
);

const ddcTargetSource = block(
  'sub ddc_target_for_step {',
  'sub lg_autocal_hdr20_sdr_adjustment_method_configured {'
);
assert(
  ddcTargetSource.includes('my $ire=defined($step->{"ddc_target_ire"}) ? $step->{"ddc_target_ire"} : $step->{"ire"};') &&
    ddcTargetSource.includes('my $array_ire=defined($step->{"ddc_array_ire"}) ? $step->{"ddc_array_ire"} : $ire;') &&
    ddcTargetSource.includes('my $effective=hdr20_effective_ddc_array_ire($ire);') &&
    ddcTargetSource.includes('return { index=>$i, ire=>format_percent($ire), array_ire=>format_percent($slots[$i]), write_ire=>format_percent($write_ire), label=>$label }'),
  'ddc_target_for_step should keep displayed ire separate from resolved HDR20 array/write slot'
);

const propagateStart = source.indexOf('sub propagate_uncalibrated_26pt_slots {');
const propagateEnd = source.indexOf('sub lg_autocal_26_hdr20_propagation_skip_slot_mask', propagateStart);
assert(propagateStart >= 0 && propagateEnd > propagateStart, '26pt propagation helper should exist');
const propagateSource = source.slice(propagateStart, propagateEnd);
assert(
  propagateSource.includes('next if($calibrated_slot_mask->[$idx]);'),
  'full-DDC spine propagation should not overwrite calibrated/best slots'
);
assert(
  propagateSource.includes('my $source_slot_masks_by_setting=(ref($source_slot_mask) eq "HASH") ? $source_slot_mask : undef;') &&
    propagateSource.includes('my $setting_source_slot_mask=$source_slot_masks_by_setting ? ($source_slot_mask->{$setting} || $default_source_slot_mask) : $default_source_slot_mask;') &&
    propagateSource.includes('$source_slot_masks_by_setting->{"__hold_last_source_to_end"}{$setting}') &&
    propagateSource.includes('push @knots,{ x=>$lut_indexes[-1]+0, y=>$arr->[$last_source_idx]+0 };'),
  'HDR full-DDC spine propagation should support per-channel source masks and hold the last RGB body knot to the DPG end'
);

const fullDdcSourceMaskSource = block(
  'sub lg_autocal_26_full_ddc_spine_source_slot_mask {',
  'sub lg_autocal_26_full_ddc_spine_anchor_count {'
);
assert(
  fullDdcSourceMaskSource.includes('sub lg_autocal_26_full_ddc_spine_setting_source_slot_masks') &&
    fullDdcSourceMaskSource.includes('return $base if(lc($layout||"") ne "hdr20");') &&
    fullDdcSourceMaskSource.includes('my $body_source_slot_mask=clone_slot_mask_without_ires($base,100);') &&
    fullDdcSourceMaskSource.includes('adjustingLuminance=>$body_source_slot_mask') &&
    fullDdcSourceMaskSource.includes('whiteBalanceRed=>$body_source_slot_mask') &&
    fullDdcSourceMaskSource.includes('whiteBalanceGreen=>$body_source_slot_mask') &&
    fullDdcSourceMaskSource.includes('whiteBalanceBlue=>$body_source_slot_mask') &&
    fullDdcSourceMaskSource.includes('adjustingLuminance=>1'),
  'HDR20 full-DDC spine should exclude 100% from body-point RGB/luma propagation while preserving SDR'
);

const fullDdcSkipSource = block(
  'sub lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask {',
  'sub calibrated_26pt_slot_for_ire {'
);
assert(
  fullDdcSkipSource.includes('foreach my $ire (lg_autocal_26_full_ddc_spine_anchor_ddc_ires($config))') &&
    fullDdcSkipSource.includes('$mask[$idx]=1;'),
  'full-DDC spine propagation should explicitly skip configured anchor slots'
);

const refreshSource = block(
  'sub refresh_propagated_uncalibrated_26pt_slots {',
  'sub lg_autocal_26_seeded_move_damping_ready {'
);
assert(
  refreshSource.includes('lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask($config,$calibrated_slot_mask)') &&
    refreshSource.includes('lg_autocal_26_full_ddc_spine_setting_source_slot_masks($calibrated_slot_mask,$config)') &&
    refreshSource.includes('propagate_uncalibrated_26pt_slots($arrays,$calibrated_slot_mask,$propagation_source_slot_mask,$skip_slot_mask)'),
  'full-DDC spine refresh should pass the anchor skip mask and HDR channel-specific source masks into interpolation'
);

const seedSource = block(
  'sub seed_target_from_prior_slot {',
  'sub repeated_value {'
);
assert(
  seedSource.includes('return 0 if(lg_autocal_26_full_ddc_spine_enabled($config) && lg_autocal_26_full_ddc_spine_anchor($target));'),
  'full-DDC spine anchors and anchor revisits should not receive adjacent/synthesized seed writes'
);

const anchorRevisitSource = block(
  'sub full_ddc_spine_anchor_revisit_luminance_adjustments {',
  'sub full_ddc_spine_anchor_luminance_adjustment {'
);
assert(
  anchorRevisitSource.includes('lg_autocal_26_full_ddc_spine_anchor_revisit_step($step)') &&
    anchorRevisitSource.includes('autocal_step_is_hdr20_body($step)') &&
    anchorRevisitSource.includes('luma_probe_family_suppressed($tried,$target,$current,$next,$step,"full_ddc_spine_anchor_revisit_luminance",$state)') &&
    !anchorRevisitSource.includes('hdr20_body_family_suppressed'),
  'HDR full-DDC anchor revisits should retry smaller luma moves after an overshoot instead of falling into RGB-only thrash'
);

const anchorRevisitKeepGuardSource = block(
  'sub full_ddc_spine_anchor_revisit_rgb_keep_blocked {',
  'sub full_ddc_spine_anchor_luminance_adjustment {'
);
assert(
  anchorRevisitKeepGuardSource.includes('lg_autocal_26_full_ddc_spine_anchor_revisit_step($step)') &&
    anchorRevisitKeepGuardSource.includes('return 0 if(adjustments_have_setting($adjustments,"adjustingLuminance"));') &&
    anchorRevisitKeepGuardSource.includes('return 0 if($after_abs + 0.35 < $before_abs);'),
  'HDR full-DDC anchor revisits should not accept RGB-only moves that fail to materially improve a large luminance error'
);

const mainRevisitPlannerIndex = source.indexOf('full_ddc_spine_anchor_revisit_luminance_adjustments');
const mainHdrBodyVectorIndex = source.indexOf('hdr20_body_rgb_luminance_vector_adjustments($err,$arrays,$target,$read_step,$de,$target_delta,$lum_err,$stalls,\\%tried_values,0.25,0,"main_hdr20_body")');
assert(
  mainRevisitPlannerIndex >= 0 &&
    mainHdrBodyVectorIndex > mainRevisitPlannerIndex,
  'anchor revisit luma recovery should run before generic HDR20 body vectors'
);

const keepCandidateSource = block(
  'my $full_ddc_spine_anchor_revisit_rgb_keep_blocked=full_ddc_spine_anchor_revisit_rgb_keep_blocked',
  'if($keep_candidate) {'
);
assert(
  keepCandidateSource.includes('$full_ddc_spine_anchor_revisit_rgb_keep_blocked') &&
    keepCandidateSource.includes('!$full_ddc_spine_anchor_revisit_rgb_keep_blocked &&'),
  'candidate keep logic should apply the HDR anchor revisit RGB-only luminance guard'
);

for (const hdrAnchor of [100, 5, 20, 40, 60, 80]) {
  assert(anchorSource.includes(`${hdrAnchor}`), `HDR anchor ${hdrAnchor}% should be represented in the anchor helper`);
}
for (const sdrAnchor of [109, 20, 40, 60, 80]) {
  assert(anchorSource.includes(`${sdrAnchor}`), `SDR anchor ${sdrAnchor}% should be represented in the anchor helper`);
}
for (const intermediate of [7, 10, 15, 25, 30, 35, 45, 50, 70, 90]) {
  assert(!fullDdcSkipSource.includes(`(${intermediate})`), `intermediate ${intermediate}% should not be hard-skipped from spine synthesis`);
}

console.log('HDR/SDR full-DDC spine anchor regression OK');

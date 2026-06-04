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

const pairDisableSource = sliceBetween(
  'sub legal_white_pair_reference_step',
  'sub legal_white_pair_spread_limit'
);
assert(
  pairDisableSource.includes('return undef if(legal_white_pair_disabled_for_sdr_initial_99($config,$target,$step));') &&
    pairDisableSource.includes('return abs(($target->{"ire"}+0)-99) <= 0.001 ? 1 : 0;'),
  'initial SDR full-spine 99% must stay unpaired from hidden 100% luminance scoring'
);

const validationGateSource = sliceBetween(
  'sub sdr_top_legal_white_validation_enabled',
  'sub sdr_top_cluster_99_105_channel_divergence'
);
assert(
  validationGateSource.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    validationGateSource.includes('!lg_autocal_26_full_ddc_spine_enabled($config)') &&
    validationGateSource.includes('lg_autocal_26_hdr20_seed_enabled($config)') &&
    validationGateSource.includes('autocal_config_is_touchup($config)') &&
    validationGateSource.includes('abs(($target->{"ire"}+0)-99) >= 0.001') &&
    validationGateSource.includes('$white_step->{"autocal_white_reference"}') &&
    validationGateSource.includes('abs(($white_step->{"ire"}+0)-100) >= 0.001'),
  'legal-white validation should be gated to SDR initial full-spine 99% with the 100% read-only legal-white step'
);

const slopeSource = sliceBetween(
  'sub sdr_top_cluster_99_105_channel_divergence',
  'sub sdr_top_legal_white_rgb_metrics'
);
assert(
  slopeSource.includes('ddc_slot_index_for_ire(99)') &&
    slopeSource.includes('ddc_slot_index_for_ire(105)') &&
    slopeSource.includes('opposing_sign') &&
    slopeSource.includes('divergent'),
  'validation diagnostics should expose divergent 99/105 top-cluster channel slopes'
);

const metricsSource = sliceBetween(
  'sub sdr_top_legal_white_rgb_metrics',
  'sub sdr_top_legal_white_needs_rgb_recovery'
);
assert(
  metricsSource.includes('autocal_adjustment_error($reading,$step)') &&
    metricsSource.includes('furthest_rgb_error_channel($error)') &&
    metricsSource.includes('spread=>$spread+0') &&
    metricsSource.includes('score=>((defined($max_abs)?$max_abs:0)*2.0)+($spread*0.75)'),
  'legal-white validation should score RGB/chroma spread, not luminance'
);

const recoveryNeedSource = sliceBetween(
  'sub sdr_top_legal_white_needs_recovery',
  'sub sdr_top_99_legal_white_final_acceptance'
);
assert(
  recoveryNeedSource.includes('sdr_top_legal_white_needs_rgb_recovery($metrics)') &&
    recoveryNeedSource.includes('($legal_de+0) > ($target_delta+0.0001)') &&
    recoveryNeedSource.includes('($r+0) <= -0.010') &&
    recoveryNeedSource.includes('($metrics->{"spread"}||0) >= 0.018'),
  'legal 100% validation should request bounded 99% recovery when dE is above target or the visible red-low case is present'
);

const diagnosticMarkSource = sliceBetween(
  'sub mark_autocal_diagnostic_reading',
  'sub write_state'
);
assert(
  diagnosticMarkSource.includes('$reading->{"autocal_diagnostic"}=JSON::PP::true;') &&
    diagnosticMarkSource.includes('$reading->{"autocal_chart_hidden"}=JSON::PP::true;') &&
    diagnosticMarkSource.includes('$reading->{"autocal_read_role"}=$role') &&
    diagnosticMarkSource.includes('$reading->{"autocal_read_phase"}=$phase'),
  'internal AutoCal diagnostic reads should carry explicit hidden/chart role metadata'
);

const recoverySource = sliceBetween(
  'sub sdr_top_legal_white_rgb_recovery_adjustments',
  'sub body_final_micro_threshold'
);
assert(
  recoverySource.includes('return undef if($setting eq "adjustingLuminance");') &&
    recoverySource.includes('sdr_top_legal_white_rgb_recovery=>1') &&
    recoverySource.includes('luminance_ignored=>JSON::PP::true') &&
    !recoverySource.includes('neutral_luminance_adjustments'),
  'legal-white recovery should make small RGB-only moves on 99%, never luma moves'
);

const validationReadSource = sliceBetween(
  'my $read_sdr_top_legal_white_validation=sub',
  'my $run_sdr_top_legal_white_validation=sub'
);
assert(
  validationReadSource.includes('my $legal_white_y=luminance($legal_reading);') &&
    validationReadSource.includes('annotate_reading_target($legal_reading,$legal_reference_y,$legal_target_y,$target_x,$target_y)') &&
    validationReadSource.includes('legal_white_self_reference=>JSON::PP::true') &&
    validationReadSource.includes('luminance_ignored=>JSON::PP::true') &&
    validationReadSource.includes('mark_autocal_diagnostic_reading($legal_reading,"legal_white_validation","sdr_top_legal_white_validation")') &&
    !validationReadSource.includes('update_white_reference_for_autocal_step'),
  'legal 100% validation should self-reference measured 100% Y, stay chart-hidden, and must not rebase the AutoCal white reference'
);

const referenceReadSource = sliceBetween(
  'my $read_reference_step=sub',
  'my $read_sdr_top_legal_white_validation=sub'
);
assert(
  referenceReadSource.includes('my ($ref_step,$label,$message,$diagnostic_role)=@_;') &&
    referenceReadSource.includes('mark_autocal_diagnostic_reading($ref_reading,$diagnostic_role,"white_reference_refresh") if(defined($diagnostic_role) && $diagnostic_role ne "");'),
  'reference reads should only become chart-hidden when a diagnostic role is explicitly passed'
);

const validationRunSource = sliceBetween(
  'my $run_sdr_top_legal_white_validation=sub',
  'my $sdr_top_cluster_preshape_done=0;'
);
assert(
  validationRunSource.includes('sdr_top_legal_white_validation_enabled($config,$final_target,$final_read_step,$white_reference_step)') &&
    validationRunSource.includes('sdr_top_cluster_99_105_channel_divergence($arrays)') &&
    validationRunSource.includes('my $needs_recovery=sdr_top_legal_white_needs_recovery($metrics,$legal_de,$target_delta) ? 1 : 0;') &&
    validationRunSource.includes('status=>$validation_status') &&
    validationRunSource.includes('recovery_available=>$needs_recovery ? JSON::PP::true : JSON::PP::false') &&
    validationRunSource.includes('diagnostic_only=>$needs_recovery ? JSON::PP::false : JSON::PP::true') &&
    validationRunSource.includes('would_have_recovered=>$needs_recovery ? JSON::PP::true : JSON::PP::false') &&
    validationRunSource.includes('sdr_top_legal_white_needs_recovery($metrics,$legal_de,$target_delta)') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_adjustments($arrays,$final_target,$metrics,\\%tried)') &&
    !validationRunSource.includes('set_picture_values($picture,$arrays,$final_target,$picture_mode,$calibration_mode_active,$state)') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_adjustment') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_accept') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_reject'),
  'post-99 validation should request recovery when legal 100% is above target without writing inside the validation read itself'
);

const finalStepSource = sliceBetween(
  '$finalize_calibrated_26pt_slot->($target,$read_step,$label);',
  'if(!cancelled() && @verification)'
);
assert(
  finalStepSource.includes('abs(($step->{"ire"}+0)-99) < 0.001') &&
    finalStepSource.includes('$sdr_99_final_needs_recovery=1 if(ref($sdr_99_final_validation) eq "HASH" && $sdr_99_final_validation->{"needs_recovery"});') &&
    finalStepSource.includes('if($sdr_99_final_rejected || $sdr_99_final_needs_recovery)') &&
    finalStepSource.includes('$sdr_99_combined_recovery->($recovery_validation') &&
    finalStepSource.includes('($candidate_de+0) > ($baseline_de99+0.05)') &&
    finalStepSource.includes('"99_delta_e_worse_than_best_observed"') &&
    finalStepSource.includes('"sdr_top_legal_white_recovery_no_safe_change"') &&
    finalStepSource.includes('$read_reference_step->($white_reference_step,"Auto Cal 100% calibrated reference","Refreshing 100% white after top-end calibration","white_reference_refresh");'),
  'initial greyscale AutoCal should validate legal white, run bounded 99% recovery when needed, and preserve chart-hidden white refresh after finalizing 99%'
);

console.log('LG AutoCal SDR top legal-white validation regression passed');

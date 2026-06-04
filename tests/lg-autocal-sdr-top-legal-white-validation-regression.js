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
    validationRunSource.includes('my $needs_recovery=sdr_top_legal_white_needs_rgb_recovery($metrics) ? 1 : 0;') &&
    validationRunSource.includes('diagnostic_only=>JSON::PP::true') &&
    validationRunSource.includes('recovery_disabled=>JSON::PP::true') &&
    validationRunSource.includes('would_have_recovered=>$needs_recovery ? JSON::PP::true : JSON::PP::false') &&
    validationRunSource.includes('sdr_top_legal_white_needs_rgb_recovery($metrics)') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_adjustments($arrays,$final_target,$metrics,\\%tried)') &&
    !validationRunSource.includes('set_picture_values($picture,$arrays,$final_target,$picture_mode,$calibration_mode_active,$state)') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_adjustment') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_accept') &&
    !validationRunSource.includes('sdr_top_legal_white_rgb_recovery_reject'),
  'post-99 validation should read legal 100% as diagnostic-only and must not drive 99% recovery writes'
);

const finalStepSource = sliceBetween(
  '$finalize_calibrated_26pt_slot->($target,$read_step,$label);',
  'if(!cancelled() && @verification)'
);
assert(
  finalStepSource.includes('abs(($step->{"ire"}+0)-99) < 0.001') &&
    finalStepSource.includes('$run_sdr_top_legal_white_validation->($target,$read_step,$label);') &&
    finalStepSource.includes('$read_reference_step->($white_reference_step,"Auto Cal 100% calibrated reference","Refreshing 100% white after top-end calibration","white_reference_refresh");'),
  'initial greyscale AutoCal should schedule legal-white validation and chart-hidden white refresh immediately after finalizing 99%'
);

console.log('LG AutoCal SDR top legal-white validation regression passed');

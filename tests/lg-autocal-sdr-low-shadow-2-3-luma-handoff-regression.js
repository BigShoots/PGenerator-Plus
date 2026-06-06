const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startNeedle, endNeedle, from = 0) {
  const start = source.indexOf(startNeedle, from);
  assert(start >= 0, `Missing start marker: ${startNeedle}`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `Missing end marker after: ${startNeedle}`);
  return source.slice(start, end);
}

const helperSource = sliceBetween(
  'sub sdr_low_shadow_2_3_luma_best_ready_for_fresh_verify',
  'sub committed_low_shadow_good_enough'
);
const endpointSeedSource = sliceBetween(
  'sub apply_sdr_low_shadow_endpoint_seed_2_3',
  'sub sdr_low_shadow_lower_neighbor_ire'
);
const chromaLumaSource = sliceBetween(
  'sub low_shadow_chroma_luminance_coupled_adjustments',
  'sub cap_post_commit_low_shadow_adjustment'
);
assert(
  endpointSeedSource.includes('return 0 if(!lg_autocal_26_legacy_low_shadow_2_3_seed_enabled($config));') &&
    endpointSeedSource.includes('my @source_ires=grep { calibrated_26pt_slot_for_ire($calibrated_slot_mask,$_) } (5,10,15);') &&
    endpointSeedSource.includes('pre_first_read_2_3_from_calibrated_low_anchors'),
  '2.3 endpoint luminance seed should remain available only behind the legacy-generation gate'
);
assert(
  chromaLumaSource.includes('abs($err) < ($max_abs*0.45)') &&
    !chromaLumaSource.includes('last if($sdr_deep_shadow_near_y_chroma && @out);'),
  '2.3 near-Y chroma cleanup should move dominant channels together instead of spending one meter read per channel'
);
assert(
  helperSource.includes('!$best_from_luma_only') &&
    helperSource.includes('sdr_low_shadow_final_acceptance_verify_required($config,$step)') &&
	    helperSource.includes('abs(($step->{"ire"}+0)-2.3) >= 0.001') &&
	    !helperSource.includes('<= 3.1001') &&
	    !helperSource.includes('<= 5.1001') &&
	    helperSource.includes('($best_de+0) > ($target_delta+0.15)') &&
	    helperSource.includes('low_shadow_luminance_close_enough($step,$best_lum_pct)') &&
	    helperSource.includes('sdr_low_shadow_near_y_chroma_state($config,$step,$best_lum_pct,$best_de,$target_delta,autocal_adjustment_error($best_reading,$step))'),
	  '2.3 luma handoff should require SDR fresh verification, exactly 2.3%, a luma-only best, near-target Y/de, and no pending near-Y chroma cleanup'
	);

const runSource = sliceBetween(
  'my $best_from_luma_only=0;',
  'if(sdr_low_shadow_final_acceptance_verify_required($config,$read_step)'
);
assert(
	    runSource.includes('my $best_from_luma_only=0;') &&
	    runSource.includes('sdr_low_shadow_2_3_luma_best_ready_for_fresh_verify($config,$read_step,$best_de,$best_lum_pct,$target_delta,$best_from_luma_only,$best_reading)') &&
	    runSource.includes('low_shadow_luminance_progress_keep(') &&
	    runSource.includes('$best_update_reason="low_shadow_luminance_progress_keep"') &&
	    runSource.includes('$best_from_luma_only=ref(luma_only_adjustment($adjustments)) eq "HASH" ? 1 : 0;') &&
	    runSource.includes('sdr_low_shadow_near_y_chroma_state($config,$read_step,$lum_pct,$de,$target_delta,$err)') &&
	    source.includes('low_shadow_near_y_chroma_luma') &&
	    runSource.includes('sdr_low_shadow_2_3_luma_best_fresh_verify_handoff') &&
	    runSource.includes('sdr_low_shadow_2_3_final_micro_suppressed') &&
	    runSource.includes('!$sdr_low_shadow_2_3_luma_ready_for_fresh_verify->() && (autocal_step_allows_final_fine_tune') &&
	    runSource.includes('$best_from_luma_only=0;'),
	  '2.3 luma-only low-shadow best should stop further probing only after the near-Y chroma cleanup lane has had a chance to run'
	);

const freshVerifySource = sliceBetween(
  'if(sdr_low_shadow_final_acceptance_verify_required($config,$read_step)',
  'my $final_reached=$pair_target_reached_now->();'
);
assert(
  freshVerifySource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
    freshVerifySource.includes('die "Fresh final low-shadow verification failed for $label" if(ref($fresh_reading) ne "HASH");') &&
    freshVerifySource.includes('low_shadow_final_fresh_verification') &&
    freshVerifySource.includes('if(!$fresh_pass)') &&
    freshVerifySource.includes('low_shadow_final_fresh_verification_warning_only') &&
    freshVerifySource.includes('$fresh_verify_record->{"warning_only"}=JSON::PP::true;') &&
    freshVerifySource.includes('$fresh_verify_record->{"final_source"}="cached_best_warning";') &&
    !freshVerifySource.includes('die "$label fresh final verification rejected cached best:'),
  '2.3 handoff should still trace fresh final verification but must keep cached best as warning-only instead of aborting'
);

console.log('LG AutoCal SDR 2.3 low-shadow luma handoff regression checks passed.');

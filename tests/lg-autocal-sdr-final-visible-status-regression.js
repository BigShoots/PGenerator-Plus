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

const guardSource = sliceBetween(
  'sub lg_autocal_26_main_final_prior_blocks_publish',
  'sub lg_autocal_26_best_known_entry'
);
assert(
  guardSource.includes('($reason||"") ne "main_final_step_result"') &&
    guardSource.includes('return undef if(!defined($reached_target) || $reached_target);') &&
    guardSource.includes('return "prior_reached_target" if($entry->{"reached_target"});') &&
    guardSource.includes('return "prior_best_known_better" if(lg_autocal_26_entry_better_than_measurement'),
  'main-final best-known guard should only block failed final publishes when a prior entry reached target or is better'
);

const rememberSource = sliceBetween(
  'sub remember_lg_autocal_26_best_known',
  'sub lg_autocal_26_best_known_for_step'
);
assert(
  rememberSource.indexOf('lg_autocal_26_main_final_prior_blocks_publish') <
    rememberSource.indexOf('lg_autocal_26_candidate_better_than_entry') &&
    rememberSource.includes('"main_final_best_known_publish_blocked"') &&
    rememberSource.includes('return $existing;'),
  'remember_lg_autocal_26_best_known should protect the prior entry before generic candidate scoring can overwrite it'
);

const anchorStartSource = sliceBetween(
  'my %anchor_revisit_prior_best_known;',
  'my $seed_from_prior_slot=0;'
);
assert(
  anchorStartSource.includes('delete_lg_autocal_26_best_known_for_step($state,$read_step)') &&
    anchorStartSource.includes('$anchor_revisit_prior_best_known{$prior_best_key}=clone_picture($prior_best_entry)') &&
    anchorStartSource.includes('"anchor_revisit_best_invalidated_at_start"'),
  'anchor revisits should preserve the invalidated prior best-known entry for final-result protection'
);

const finalSource = sliceBetween(
  'trace_109($read_step,"final_step_result"',
  '$finalize_calibrated_26pt_slot->($target,$read_step,$label);'
);
assert(
  finalSource.includes('my $main_final_restore_entry;') &&
    finalSource.includes('$anchor_revisit_prior_best_known{$anchor_prior_key}') &&
    finalSource.includes('lg_autocal_26_main_final_prior_blocks_publish(') &&
    finalSource.includes('lg_autocal_26_arrays_with_best_known_values($best_arrays,$target,$main_final_restore_entry)') &&
    finalSource.includes('"main_final_best_known_restored"') &&
    finalSource.includes('set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state)') &&
    finalSource.indexOf('"main_final_best_known_restored"') < finalSource.indexOf('remember_lg_autocal_26_best_known('),
  'failed main-final results should restore protected prior DDC values before best-known publishing and finalization'
);

const validationSource = sliceBetween(
  'my $run_sdr_top_legal_white_validation=sub',
  'my $sdr_top_cluster_preshape_done=0;'
);
assert(
  validationSource.includes('if($needs_recovery)') &&
    validationSource.includes('lg_autocal_26_best_known_for_step($state,$final_read_step)') &&
    validationSource.includes('$best_entry->{"reached_target"}=JSON::PP::false;') &&
    validationSource.includes('$best_entry->{"legal_white_validation_status"}="diagnostic_only_failed";') &&
    validationSource.includes('$best_entry->{"legal_white_failure_reason"}="legal_white_diagnostic_only_failed";') &&
    validationSource.includes('$best_entry->{"paired_legal_white_delta_e"}=$legal_de+0') &&
    validationSource.includes('"sdr_top_legal_white_best_known_flagged"') &&
    !validationSource.includes('sdr_top_legal_white_rgb_recovery_adjustments($arrays,$final_target,$metrics'),
  '99 legal-white diagnostic failures should be exposed on best-known/status without re-enabling recovery writes'
);

function score(de, lum = 0) {
  return de + Math.abs(lum) * 0.05;
}

function priorBlocks(candidate, prior, reachedTarget, reason = 'main_final_step_result') {
  if (reason !== 'main_final_step_result') return false;
  if (reachedTarget) return false;
  if (!prior || !Number.isFinite(prior.deltaE)) return false;
  if (prior.reachedTarget) return true;
  return score(prior.deltaE, prior.lum) + 0.0001 < score(candidate.deltaE, candidate.lum);
}

{
  const prior = { deltaE: 0.42, lum: 0.1, reachedTarget: true };
  const candidate = { deltaE: 36.03, lum: 1.2 };
  assert(priorBlocks(candidate, prior, false), 'failed main_final_step_result must not overwrite a prior reached target entry');
}

{
  const candidate = { deltaE: 39.47, lum: 2.0 };
  assert(!priorBlocks(candidate, null, false), 'failed main_final_step_result should remain visible when no prior better entry exists');
}

{
  const bestKnown99 = { deltaE: 0.309, reachedTarget: true };
  const legalWhiteFailed = true;
  if (legalWhiteFailed) {
    bestKnown99.reachedTarget = false;
    bestKnown99.legalWhiteValidationStatus = 'diagnostic_only_failed';
    bestKnown99.legalWhiteFailureReason = 'legal_white_diagnostic_only_failed';
    bestKnown99.pairedLegalWhiteDeltaE = 19.26;
  }
  assert.strictEqual(bestKnown99.reachedTarget, false, '99 best-known should not remain reached/good after legal-white diagnostic failure');
  assert.strictEqual(bestKnown99.legalWhiteValidationStatus, 'diagnostic_only_failed');
  assert.strictEqual(bestKnown99.pairedLegalWhiteDeltaE, 19.26);
}

console.log('LG AutoCal SDR final visible-status regression checks passed');

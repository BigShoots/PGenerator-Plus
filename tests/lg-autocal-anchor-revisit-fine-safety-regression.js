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

const severeHelper = sliceBetween(
  'sub full_ddc_spine_anchor_revisit_severe_fine_reject',
  'sub full_ddc_spine_anchor_luminance_adjustment'
);
assert(
  severeHelper.includes('lg_autocal_26_full_ddc_spine_enabled($config)') &&
    severeHelper.includes('lg_autocal_26_full_ddc_spine_body_anchor($target)') &&
    severeHelper.includes('lg_autocal_26_full_ddc_spine_anchor_revisit_step($step)') &&
    severeHelper.includes('($candidate_score+0) > ($best_score+0)+1.00') &&
    severeHelper.includes('abs($candidate_lum_pct+0) > abs($best_lum_pct+0)+5.00'),
  'severe fine reject helper should be limited to full-DDC body-anchor revisits and use score/Y worsening thresholds'
);

const mainSource = sliceBetween(
  'my $anchor_revisit_force_fresh_restore_verify=0;',
  '$restore_best_branch->($paired_white_step ? "Keeping best 99/100 paired result"'
);
assert(
  mainSource.includes('my $verify_anchor_revisit_restored_best=sub') &&
    mainSource.includes('lg_autocal_26_full_ddc_spine_body_anchor($target)') &&
    mainSource.includes('lg_autocal_26_full_ddc_spine_anchor_revisit_step($read_step)') &&
    mainSource.includes('$restore_best_branch->($reason||"Restoring best $label before anchor revisit fresh verification");') &&
    mainSource.includes('read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)') &&
    mainSource.includes('die "Fresh restored anchor revisit verification failed for $label" if(ref($fresh_reading) ne "HASH");') &&
    mainSource.includes('full_ddc_spine_anchor_revisit_fresh_restored_best') &&
    mainSource.includes('full_ddc_spine_anchor_revisit_severe_fine_reject(') &&
    mainSource.includes('$anchor_revisit_force_fresh_restore_verify=1;') &&
    mainSource.includes('Anchor revisit severe fine-tune reject; restoring best $label for fresh verification') &&
    mainSource.includes('$verify_anchor_revisit_restored_best->("Verifying restored anchor revisit best after severe fine-tune rejection")'),
  'severe anchor-revisit fine rejects should restore best, force a fresh guarded reread, then hand live readings into finalization'
);

const finalFineStart = mainSource.indexOf('trace_109($read_step,"start_final_fine_tune"');
const severeCall = mainSource.indexOf('full_ddc_spine_anchor_revisit_severe_fine_reject(', finalFineStart);
const fineRejectTrace = mainSource.indexOf('trace_109($read_step,"fine_tune_candidate_rejected"', finalFineStart);
const handoffTrace = mainSource.indexOf('trace_109($read_step,"full_ddc_spine_anchor_revisit_severe_fine_reject"', finalFineStart);
const verifyCall = mainSource.indexOf('$verify_anchor_revisit_restored_best->("Verifying restored anchor revisit best after severe fine-tune rejection")', finalFineStart);
assert(
  finalFineStart >= 0 &&
    severeCall > finalFineStart &&
    fineRejectTrace > severeCall &&
    handoffTrace > fineRejectTrace &&
    verifyCall > handoffTrace,
  'anchor-revisit severe rejection should be detected inside final fine-tune rejection flow before the restored-best verify runs'
);

console.log('LG AutoCal anchor revisit fine-tune safety regression checks passed.');

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(start, end) {
  const startIndex = source.indexOf(start);
  assert(startIndex >= 0, `missing start marker: ${start}`);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert(endIndex > startIndex, `missing end marker after: ${start}`);
  return source.slice(startIndex, endIndex);
}

const enableBody = sliceBetween(
  'sub sdr_body_rgb_suppression_enabled {',
  'sub sdr_body_rgb_best_signature {'
);
assert(
  enableBody.includes('$config->{"lg_autocal_26"}') &&
    enableBody.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    enableBody.includes('lg_autocal_26_full_ddc_spine_enabled($config)') &&
    enableBody.includes('lg_autocal_26_full_ddc_spine_body_anchor($target)') &&
    enableBody.includes('$ire >= 19.999 && $ire <= 80.0001'),
  'SDR body RGB suppression should be limited to SDR LG26 full-spine body anchors'
);

const signature = sliceBetween(
  'sub sdr_body_rgb_best_signature {',
  'sub sdr_body_rgb_active_signature {'
);
assert(
  signature.includes('whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance') &&
    signature.includes('ddc_value_key($value)'),
  'suppression signature should include the current best RGB and luma DDC slot values'
);

const familyKey = sliceBetween(
  'sub sdr_body_rgb_family_key {',
  'sub sdr_body_rgb_entry_suppressed {'
);
assert(
  familyKey.includes('whiteBalanceRed|whiteBalanceGreen|whiteBalanceBlue') &&
    !familyKey.includes('whiteBalanceRed)$/'),
  'SDR body RGB family suppression should be channel-generic for R/G/B, not red-specific'
);

const entrySuppressed = sliceBetween(
  'sub sdr_body_rgb_entry_suppressed {',
  'sub sdr_body_rgb_family_suppressed {'
);
assert(
  entrySuppressed.includes('($entry->{"count"}||0) >= 2'),
  'SDR body RGB family should suppress only after repeated rejects'
);

const recorder = sliceBetween(
  'sub record_sdr_body_bad_rgb_adjustment_family {',
  'sub sdr_low_shadow_suppressed_rgb_adjustment {'
);
assert(
  recorder.includes('my $adj=rgb_only_adjustment($adjustments);') &&
    recorder.includes('my $near_small_rgb=($before_rgb <= 0.020 || $after_rgb <= 0.020) ? 1 : 0;') &&
    recorder.includes('my $near_low_de=(defined($before_de) && ($before_de+0) <= 2.0) ? 1 : 0;') &&
    recorder.includes('trace_109($step,"sdr_body_rgb_bad_move_family"'),
  'recorder should only track rejected RGB-only probes from low-dE or small-spread SDR body states'
);

const suppressor = sliceBetween(
  'sub sdr_body_rgb_family_suppressed {',
  'sub record_sdr_body_bad_rgb_adjustment_family {'
);
assert(
  suppressor.includes('trace_109($step,"sdr_body_family_suppressed"') &&
    suppressor.includes('repeated_same_family_rejects_at_small_rgb_spread'),
  'suppression should be traceable with a clear reason'
);

assert(
  source.includes('update_sdr_body_rgb_best_signature($config,\\%tried_values,$read_step,$target,$best_arrays);'),
  'main loop should bind suppression to the current best DDC state'
);

assert(
  source.includes('record_sdr_body_bad_rgb_adjustment_family(') &&
    source.includes('bad_sdr_body_rgb_family=>$bad_sdr_body_rgb_family'),
  'main rejection path should record rejected SDR body RGB families'
);

for (const marker of [
  'sdr_body_rgb_family_suppressed($LG_AUTOCAL_CONFIG,$tried,$step,$target,$arrays,$setting,$source||"learned_rgb")',
  'sdr_body_rgb_family_suppressed($LG_AUTOCAL_CONFIG,$tried,$step,$target,$arrays,$candidate_setting,"rgb_response_model")',
  'sdr_body_rgb_family_suppressed($config,$tried,$step,$target,$arrays,$setting,"full_ddc_spine_anchor_rgb")',
  'sdr_body_rgb_family_suppressed($LG_AUTOCAL_CONFIG,$tried,$step,$target,$arrays,$setting,"main_rgb")',
]) {
  assert(source.includes(marker), `missing planner suppression hook: ${marker}`);
}

assert(
  source.includes('__sdr_body_bad_rgb_family'),
  'suppression state should be copied/restored with other adjustment-family memory'
);

console.log('SDR body RGB suppression regression checks passed');

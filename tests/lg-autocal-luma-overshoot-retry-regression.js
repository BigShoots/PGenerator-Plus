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

const lumaGuard = sliceBetween(
  'sub luma_probe_guarded_target {',
  'sub luma_probe_family_key {'
);
assert(
  lumaGuard.includes('sdr_body_rgb_suppression_enabled($LG_AUTOCAL_CONFIG,$step,$target)') &&
    lumaGuard.includes('abs($ire-99) < 0.001'),
  'luma overshoot guard should cover SDR body anchors plus standalone 99'
);

const lumaBearing = sliceBetween(
  'sub luma_bearing_adjustment {',
  'sub luma_probe_family_suppressed {'
);
assert(
  lumaBearing.includes('adjustingLuminance') &&
    lumaBearing.includes('return undef if(defined($found));'),
  'bad-luma recorder should handle luma-bearing moves without accepting ambiguous multi-luma adjustments'
);

const recorder = sliceBetween(
  'sub record_bad_luma_probe_family {',
  'sub sdr_low_shadow_rgb_suppression_enabled {'
);
assert(
  recorder.includes('my $adj=luma_bearing_adjustment($adjustments);') &&
    recorder.includes('my $sign_crossed=') &&
    recorder.includes('my $overshoot=($sign_crossed && ($de_worse || $score_worse))') &&
    recorder.includes('$entry->{"luma_overshoot"}') &&
    recorder.includes('$entry->{"best_signature"}') &&
    recorder.includes('trace_109($trace_step,$overshoot ? "luma_overshoot_family" : "bad_luma_probe"'),
  'rejected sign-crossing luma overshoots should be recorded with retry metadata and trace breadcrumbs'
);

const retry = sliceBetween(
  'sub luma_overshoot_retry_adjustments {',
  'sub record_bad_luma_probe_family {'
);
assert(
  retry.includes('my @magnitudes=($attempted/2,$attempted/4,$min_step);') &&
    retry.includes('$entry->{"best_signature"} ne $signature') &&
    retry.includes('trace_109($trace_step,"luma_overshoot_retry"') &&
    retry.includes('luma_overshoot_retry=>1'),
  'luma overshoot retry should prefer smaller same-direction moves from the same best DDC signature'
);

const neutral = sliceBetween(
  'sub neutral_luminance_adjustments {',
  'sub near_white_95_luma_step {'
);
assert(
  neutral.includes('luma_overshoot_retry_adjustments($arrays,$target,$luminance_err,$tried,$min_step,$strict_tried,$step,$source||"neutral_luminance",$state)') &&
    neutral.indexOf('luma_overshoot_retry_adjustments') < neutral.indexOf('my $setting="adjustingLuminance";'),
  'neutral luminance planner should try overshoot retry before normal luma magnitudes'
);

for (const marker of [
  '$read_step,"main",$state,$best_arrays',
  '$read_step,"fine_tune",$state,$best_arrays',
]) {
  assert(source.includes(marker), `missing best-signature context at rejection call: ${marker}`);
}

console.log('Luma overshoot retry regression checks passed');

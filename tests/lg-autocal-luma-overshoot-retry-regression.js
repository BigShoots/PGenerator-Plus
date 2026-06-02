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
  lumaGuard.includes('sdr_luma_bracket_retry_enabled($LG_AUTOCAL_CONFIG,$step,$target)') &&
    lumaGuard.includes('sdr_body_rgb_suppression_enabled($LG_AUTOCAL_CONFIG,$step,$target)') &&
    lumaGuard.includes('abs($ire-99) < 0.001'),
  'luma overshoot guard should cover SDR low-shadow/body/top retry context plus standalone 99'
);

const lumaRetryScope = sliceBetween(
  'sub sdr_luma_bracket_retry_enabled {',
  'sub update_luma_probe_best_signature {'
);
assert(
  lumaRetryScope.includes('$config->{"lg_autocal_26"}') &&
    lumaRetryScope.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    lumaRetryScope.includes('$ire > 0 && $ire <= 10.0001') &&
    lumaRetryScope.includes('$ire > 10.0001 && $ire < 99.0001') &&
    lumaRetryScope.includes('autocal_config_is_post_3d_polish($config)'),
  'luma bracketing should be SDR LG26 initial-greyscale scoped and cover both 2.3 low-shadow and 90/body/top points'
);

const lumaSignature = sliceBetween(
  'sub update_luma_probe_best_signature {',
  'sub luma_tried_value_reopen_allowed {'
);
assert(
  lumaSignature.includes('__luma_probe_best_signature') &&
    lumaSignature.includes('autocal_target_ddc_signature($arrays,$target)'),
  'luma retry memory should be keyed to the current best DDC signature'
);

const lumaReopen = sliceBetween(
  'sub luma_tried_value_reopen_allowed {',
  'sub luma_probe_guarded_target {'
);
assert(
  lumaReopen.includes('trace_109($step,"luma_reopened_after_rgb"') &&
    lumaReopen.includes('reason=>"best_ddc_context_changed"'),
  'stale tried luma values should reopen after RGB/chroma changes the best DDC context'
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
    recorder.includes('my $worse_gate=$sign_crossed ? 0.10 : 0.35;') &&
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
    neutral.indexOf('luma_overshoot_retry_adjustments') < neutral.indexOf('my $setting="adjustingLuminance";') &&
    neutral.includes('luma_tried_value_reopen_allowed($tried,$setting,$next,$step,$source||"neutral_luminance")'),
  'neutral luminance planner should try overshoot retry before normal luma magnitudes'
);

const learnedCap = sliceBetween(
  'sub lg_autocal_26_learned_luma_safe_cap {',
  'sub lg_autocal_26_learned_luminance_adjustment {'
);
assert(
  learnedCap.includes('$ire <= 3.1001') &&
    learnedCap.includes('$safe=0.25') &&
    learnedCap.includes('$ire > 10.0001 && $ire < 99.0001') &&
    learnedCap.includes('$samples < 3 && $safe > 1.00'),
  'learned luma jumps should be capped for low-shadow and sparse SDR body/top response models'
);

const learnedLuma = sliceBetween(
  'sub lg_autocal_26_learned_luminance_adjustment {',
  'sub lg_autocal_26_adaptive_headroom_luminance_adjustment {'
);
assert(
  learnedLuma.includes('lg_autocal_26_learned_luma_safe_cap') &&
    learnedLuma.includes('trace_109($step,"learned_luma_cap"'),
  'learned luma planner should trace when it damps a risky learned jump'
);

for (const marker of [
  '$read_step,"main",$state,$best_arrays',
  '$read_step,"fine_tune",$state,$best_arrays',
  '$read_step,"main_keep",$state,$best_arrays',
  '$read_step,"fine_tune_keep",$state,$best_arrays',
]) {
  assert(source.includes(marker), `missing best-signature context at rejection call: ${marker}`);
}

for (const marker of [
  'update_luma_probe_best_signature($config,\\%tried_values,$read_step,$target,$best_arrays);',
  'update_luma_probe_best_signature($config,\\%polish_tried,$read_step,$target,$best_arrays);',
  'kept_luma_overshoot_probe=>$kept_luma_overshoot_probe',
]) {
  assert(source.includes(marker), `missing luma retry state marker: ${marker}`);
}

console.log('Luma overshoot retry regression checks passed');

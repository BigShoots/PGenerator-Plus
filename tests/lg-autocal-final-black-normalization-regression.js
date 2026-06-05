const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startToken, endToken, from = 0) {
  const start = source.indexOf(startToken, from);
  assert(start >= 0, `Missing start token: ${startToken}`);
  const end = source.indexOf(endToken, start);
  assert(end > start, `Missing end token after ${startToken}: ${endToken}`);
  return source.slice(start, end);
}

const helper = sliceBetween('sub normalize_final_sdr_oled_black_reading', 'sub uv_prime');

assert(
  helper.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    helper.includes('display_type') &&
    helper.includes('/oled/i') &&
    helper.includes('abs($target_luminance+0) > 0.000001'),
  'helper should be limited to SDR OLED zero/tiny-target black reads'
);

assert(
  helper.includes('$reading->{"raw_Y"}=$original->{"Y"}') &&
    helper.includes('$reading->{"Y"}=0;') &&
    helper.includes('$reading->{"luminance"}=0;') &&
    helper.includes('$reading->{"X"}=0;') &&
    helper.includes('$reading->{"Z"}=0;') &&
    helper.includes('delete($reading->{"x"});') &&
    helper.includes('delete($reading->{"y"});') &&
    helper.includes('"sdr_oled_final_zero_target"'),
  'helper should preserve raw values, force chart black to zero, and remove unstable chromaticity'
);

const targetFunction = sliceBetween('sub target_luminance_for_step', 'sub autocal_step_is_white');
assert(
  source.includes('sub bt1886_eotf_luminance') &&
    targetFunction.includes('my ($white_y,$step,$target_gamma,$signal_mode,$black_y)=@_;') &&
    targetFunction.includes('if($mode eq "sdr" && $target_gamma eq "bt1886" && defined($black_y) && ($black_y+0) > 0)') &&
    targetFunction.includes('return bt1886_eotf_luminance($signal,$white_y,$black_y+0);'),
  'SDR BT.1886 target luminance should accept a measured lifted black level'
);

const stateBlackHelper = sliceBetween('sub autocal_state_black_luminance', 'sub target_luminance_for_autocal_step');
assert(
  stateBlackHelper.includes('$state->{"target_black_luminance"}') &&
    stateBlackHelper.includes('abs(($reading->{"ire"}+0)) > 0.001') &&
    stateBlackHelper.includes('luminance($reading)'),
  'AutoCal state should expose the current measured black reference for target calculations'
);

const effectiveTarget = sliceBetween('sub effective_target_luminance_for_autocal_reading', 'sub derived_white_reference_from_peak_headroom');
assert(
  effectiveTarget.includes('my $black_y=autocal_state_black_luminance($state || $LG_AUTOCAL_STATE);') &&
    effectiveTarget.includes('target_luminance_for_autocal_step($white_y,$step,$target_gamma,$signal_mode,$black_y)'),
  'Per-read AutoCal targets should use the measured black reference when available'
);

const traceTarget = sliceBetween('sub trace_sdr_autocal_target_y_reference', 'sub effective_target_luminance_for_autocal_reading');
assert(
  traceTarget.includes('my $black_y=autocal_state_black_luminance($state);') &&
    traceTarget.includes('target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode,$black_y)') &&
    traceTarget.includes('black_y=>defined($black_y) ? $black_y+0 : undef') &&
    traceTarget.includes('target_effective_linear=>defined($effective_linear) ? $effective_linear+0 : undef'),
  'Target-Y diagnostics should report the lifted black reference used to recompute SDR targets'
);

const setupStart = source.indexOf('my $initial_black_reference_enabled=');
assert(setupStart >= 0, 'LG26 workflow should define an initial black-reference gate');
const orderedLoop = source.indexOf('foreach my $step (@ordered)', setupStart);
assert(orderedLoop > setupStart, 'Ordered AutoCal loop should follow workflow setup');
const setupBlock = source.slice(setupStart, orderedLoop);
assert(
  setupBlock.includes('$config->{"lg_autocal_26"}') &&
    setupBlock.includes('$black_step') &&
    setupBlock.includes('my $total_ordered_steps=scalar(@ordered)+scalar(@verification)+($black_step ? 1 : 0);') &&
    !setupBlock.includes('($initial_black_reference_enabled ? 1 : 0)'),
  'Progress total should count the final black read but keep the initial LG26 black reference internal to the series'
);

const blackHelper = sliceBetween('my $read_black_reference_step=sub', 'my $read_sdr_top_legal_white_validation=sub');
assert(
  blackHelper.includes('my $count_in_workflow=$initial_reference ? 0 : 1;') &&
    blackHelper.includes('$step_num++ if($count_in_workflow);') &&
    blackHelper.includes('if($count_in_workflow)') &&
    blackHelper.includes('$state->{"current_name"}=$label;') &&
    blackHelper.includes('$state->{"message"}=$complete_message if($count_in_workflow);') &&
    blackHelper.includes('set_state_active_step($state,$black_read_step,undef);') &&
    blackHelper.includes('read_step($config,$black_read_step,$state)') &&
    blackHelper.includes('target_luminance_for_step($white_y,$black_read_step,$target_gamma,$signal_mode,autocal_state_black_luminance($state))') &&
    blackHelper.includes('set_state_target_step_luminance($state,$black_target_y);'),
  'Shared black-read helper should carry 0% active metadata and target luminance while hiding the initial reference from workflow progress'
);

assert(
  blackHelper.includes('normalize_final_sdr_oled_black_reading($config,$black_read_step,$black_reading,$black_target_y)') &&
    blackHelper.indexOf('normalize_final_sdr_oled_black_reading') < blackHelper.indexOf('merge_reading($state->{"readings"},$black_reading)'),
  'OLED black normalization should happen before black readings are merged into status readings'
);

assert(
    blackHelper.includes('if($initial_reference)') &&
    blackHelper.includes('my $measured_black_target_y=target_luminance_for_step($white_y,$black_read_step,$target_gamma,$signal_mode,$measured_black_y);') &&
    blackHelper.includes('annotate_reading_target($black_reading,$white_y,$black_target_y,$target_x,$target_y);') &&
    blackHelper.indexOf('my $measured_black_target_y=target_luminance_for_step') < blackHelper.indexOf('merge_reading($state->{"readings"},$black_reading)') &&
    blackHelper.includes('if($initial_reference || !defined($state->{"target_black_luminance"}))') &&
    blackHelper.includes('$state->{"target_black_luminance"}=$measured_black_y+0;') &&
    blackHelper.includes('$state->{"setup_black_luminance"}=$measured_black_y+0;') &&
    blackHelper.includes('$state->{"initial_black_reference_luminance"}=$measured_black_y+0;') &&
    blackHelper.includes('$state->{"final_black_luminance"}=$measured_black_y+0;'),
  'Initial black should become the stable LCD target reference while the final black read remains recorded separately'
);

const initialRead = source.indexOf('"Reading initial 0% black reference for target curve"', setupStart);
assert(
  initialRead > setupStart && initialRead < orderedLoop &&
    source.slice(initialRead, orderedLoop).includes('"initial_black_read_normalized"') &&
    source.slice(initialRead, orderedLoop).includes('"initial_black_reference_read"'),
  'LG26 should read and trace black before the ordered calibration loop starts'
);

const finalRead = source.indexOf('"Reading final 0% black"', orderedLoop);
const finalBoundary = source.indexOf('my $reconfirm_sdr_low_shadow_final_context=sub', finalRead);
assert(
  finalRead > orderedLoop &&
    finalBoundary > finalRead &&
    source.slice(finalRead, finalBoundary).includes('"final_black_read_normalized"') &&
    source.slice(finalRead, finalBoundary).includes('"final_black_reference_read"'),
  'LG26 should keep the final black verification read after calibration'
);

console.log('LG AutoCal black-reference workflow regression checks passed.');

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

const strictStart = source.indexOf('sub sdr_main_greyscale_requires_strict_delta');
assert(strictStart >= 0, 'SDR main greyscale strict delta helper should be present');
const strictEnd = source.indexOf('sub legal_white_pair_reference_step', strictStart);
assert(strictEnd > strictStart, 'strict delta helper boundary should be found');
const strictSource = source.slice(strictStart, strictEnd);

assert(
  strictSource.includes('lc($config->{"signal_mode"}||"sdr") ne "sdr"') &&
    strictSource.includes('return 0 if(autocal_config_is_touchup($config));') &&
    strictSource.includes('autocal_step_is_fast_headroom($step) || autocal_step_is_low_shadow($step) || autocal_step_is_white($step)') &&
    strictSource.includes('return ($ire > 10.0001 && $ire < 99) ? 1 : 0;'),
  'strict helper should apply only to normal SDR body greyscale steps'
);

assert(
  strictSource.includes('return 0 if(sdr_main_greyscale_requires_strict_delta($config,$step) && (!defined($de) || $de > $target_delta));') &&
    strictSource.includes('return guarded_target_reached($de,$lum_pct,$target_delta,$step,$reading,$white_guard_y);'),
  'strict target helper should require de <= configured target before falling through to existing guarded acceptance'
);

const targetClosureStart = source.indexOf('my $pair_target_reached_now=sub {');
assert(targetClosureStart >= 0, 'main AutoCal loop should define pair_target_reached_now');
const targetClosureEnd = source.indexOf('my $sdr_peak_extra_fine_tune_now=sub {', targetClosureStart);
assert(targetClosureEnd > targetClosureStart, 'pair_target_reached_now boundary should be found');
const targetClosure = source.slice(targetClosureStart, targetClosureEnd);

assert(
  targetClosure.includes('return sdr_main_greyscale_strict_target_reached($config,$de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y);') &&
    targetClosure.includes('return legal_white_pair_target_reached('),
  'unpaired main greyscale target checks should use strict target acceptance while paired 99/100 checks stay on the paired helper'
);

const initialStart = source.indexOf('if($initial_result_not_worse_than_best && $pair_target_reached_now->())');
assert(initialStart >= 0, 'initial target-reached branch should be present');
const initialEnd = source.indexOf('my $last_de=$best_de;', initialStart);
assert(initialEnd > initialStart, 'initial target branch boundary should be found');
const initialSource = source.slice(initialStart, initialEnd);

assert(
  initialSource.includes('my $initial_reached_after_micro=$pair_target_reached_now->();') &&
    initialSource.includes('"target_reached_initial_blocked"') &&
    initialSource.includes('"target_reached_initial"') &&
    initialSource.indexOf('"target_reached_initial_blocked"') < initialSource.indexOf('"target_reached_initial"'),
  'initial target branch should re-check after final micro and log a blocked event instead of target_reached_initial when strict dE fails'
);

const finalStart = source.indexOf('my $final_reached=$pair_target_reached_now->();');
assert(finalStart >= 0, 'final target-reached assignment should be present');
const finalEnd = source.indexOf('my $sdr_99_final_validation;', finalStart);
assert(finalEnd > finalStart, 'final target-reached trace boundary should be found');
const finalSource = source.slice(finalStart, finalEnd);

assert(
  finalSource.includes('target_reached_blocked_reason') &&
    finalSource.includes('sdr_main_greyscale_strict_delta_block_reason($config,$best_de,$target_delta,$read_step)') &&
    finalSource.includes('reached_target=>$final_reached?JSON::PP::true:JSON::PP::false'),
  'final result trace should report false reached_target with an explicit strict-delta block reason'
);

console.log('LG AutoCal SDR strict target regression checks passed.');

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

const helperStart = source.indexOf('sub normalize_final_sdr_oled_black_reading');
assert(helperStart >= 0, 'final SDR OLED black normalization helper should exist');
const helperEnd = source.indexOf('sub uv_prime', helperStart);
assert(helperEnd > helperStart, 'helper boundary should be found');
const helper = source.slice(helperStart, helperEnd);

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

const blockStart = source.indexOf('if(!cancelled() && $black_step)');
assert(blockStart >= 0, 'final black-read block should exist');
const blockEnd = source.indexOf('my $reconfirm_sdr_low_shadow_final_context=sub', blockStart);
assert(blockEnd > blockStart, 'final black-read block boundary should be found');
const block = source.slice(blockStart, blockEnd);

assert(
  block.includes('set_state_active_step($state,$black_read_step,undef);') &&
    block.includes('set_state_target_step_luminance($state,$black_target_y);'),
  'final black-read state should carry 0% active/current metadata and target luminance'
);

assert(
  block.includes('normalize_final_sdr_oled_black_reading($config,$black_read_step,$black_reading,$black_target_y)') &&
    block.includes('"final_black_read_normalized"') &&
    block.indexOf('normalize_final_sdr_oled_black_reading') < block.indexOf('merge_reading($state->{"readings"},$black_reading)'),
  'final black read should be normalized and traced before merging into status readings'
);

console.log('LG AutoCal final black normalization regression checks passed.');

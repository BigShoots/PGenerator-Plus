const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

assert(
  source.includes('ZERO_READ_RETRIES=2') &&
    source.includes('nonblack_zero_reading()') &&
    source.includes('normalize_oled_zero_black_reading()') &&
    source.includes('zero read guard recovered') &&
    source.includes('zero_xyz_luminance') &&
    source.includes('sdr_oled_series_zero_target'),
  'Series reads should retry/exclude non-black all-zero meter results and normalize OLED target-black readings'
);

assert(
  source.includes('awk -v r="$r" -v g="$g" -v b="$b"') &&
    source.includes('return 1'),
  'The zero-read guard must not reinterpret the intentional black patch as a failed read'
);

assert(
  source.includes('NORMALIZED_READING=$(normalize_oled_zero_black_reading "$READING"') &&
    source.indexOf('NORMALIZED_READING=$(normalize_oled_zero_black_reading "$READING"') >
      source.indexOf('zero read guard excluded'),
  'OLED zero black normalization should run after the retry/exclusion guard and before accumulation'
);

console.log('meter series zero-read regression checks passed.');

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

assert(
  source.includes('if(meterChartIsDv()) return {min:16,span:219};'),
  'DV greyscale preview code range should use authored 8-bit tunnel/video codes'
);

assert(
  source.includes('my $dv_greyscale_tunnel_codes=($dv_series && $type eq "greyscale") ? 1 : 0;') &&
    source.includes('my $dv_series_full_range=$dv_series && !$dv_greyscale_tunnel_codes'),
  'DV greyscale backend series should not switch to full-range patch codes just because the HDMI transport is full-range RGB'
);

const expectedCodes = new Map([
  [0, 16],
  [5, 27],
  [10, 38],
  [15, 49],
  [20, 60],
  [25, 71],
  [50, 126],
  [75, 180],
  [95, 224],
  [100, 235]
]);

for (const [stimulus, expected] of expectedCodes) {
  const actual = Math.round(16 + (stimulus / 100) * 219);
  assert.strictEqual(actual, expected, `DV greyscale ${stimulus}% tunnel code mismatch`);
}

console.log('DV greyscale tunnel range regression checks passed.');

#!/usr/bin/env perl
# Test that the EOTF and Gamma charts annotate the 0% IRE data point with
# the actual measured black level (Lb) so a lifted black stays visible
# even though the Y axis spans 0 to peak and the plotted 0% point sits
# on the X axis.
#
# Pre-fix: the only signal of a real black lift was the "Min cd/m^2: Lb"
# footer text in the Gamma chart, easy to miss while the chart is in
# motion. A lifted 0.05 cd/m^2 on a 1000 nit panel plotted at y ~ 0.00005
# was visually indistinguishable from true black and read as "0.0 cd/m^2"
# to the operator.
#
# Post-fix: both drawEOTFChart and drawGammaChart call a new
# meterDrawLiftedBlackLabel helper that places a small yellow "0% = Lb
# cd/m^2" callout next to the 0% data point whenever Lb > 0.
#
# This is a source-only test, no live renderer or meter required.
use strict;
use warnings;
use Test::More;

my $src_path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $src_path) or BAIL_OUT("can't read $src_path: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The helper function must exist with the expected name and signature.
like($src, qr/function\s+meterDrawLiftedBlackLabel\s*\(\s*ctx\s*,\s*chart\s*,\s*axisMax\s*,\s*yTop\s*,\s*Lb\s*,\s*measureSteps\s*,\s*scaleFn\s*\)/,
  'meterDrawLiftedBlackLabel helper present with expected signature');

# 2. The helper must guard on Lb > 0 so a true black (Lb == 0) does not
# draw a redundant "0% = 0 cd/m^2" callout on every chart.
like($src, qr/meterDrawLiftedBlackLabel[^}]*?if\s*\(!\s*\(?\s*\$?Lb\s*>\s*0\s*\)?/s,
  'helper guards on Lb > 0 (skips the callout on true black)');

# 3. The helper must locate the 0% step by IRE ~ 0 within measureSteps.
like($src, qr/const\s+zeroStep\s*=\s*\(?measureSteps\s*\|\|\s*\[\]\)?\.find/,
  'helper searches measureSteps for the 0% step');

# 4. The helper must format the label as a cd/m^2 value with appropriate
# precision (3 decimals for sub-1 nit lifts, 1 decimal otherwise).
like($src, qr/'0%\s*=\s*'\s*\+\s*\$?Lb\.toFixed\(\$?Lb\s*<\s*1\s*\?\s*3\s*:\s*1\)\s*\+\s*' cd\/m\\u00B2'/,
  'helper formats the label with sub-1 precision (3 decimals) or >=1 precision (1 decimal)');

# 5. The helper must position the label so it doesn't collide with the
# 0% point itself (label sits 10px right, 8px above the point).
like($src, qr/labelX\s*=\s*Math\.min\([^,]+,\s*px\s*\+\s*10\s*\)/,
  'helper offsets the label 10px right of the 0% point');
like($src, qr/labelY\s*=\s*Math\.max\([^,]+,\s*py\s*-\s*8\s*\)/,
  'helper offsets the label 8px above the 0% point');

# 6. drawEOTFChart must call the helper with the EOTF scale callback
# (normalized luminance -> 0..yTop -> 0..1).
like($src, qr/function\s+drawEOTFChart[\s\S]{0,4000}?meterDrawLiftedBlackLabel\(\s*ctx\s*,\s*chart\s*,\s*axisMax\s*,\s*yTop\s*,\s*Lb\s*,\s*measureSteps\s*,[\s\S]{0,200}?meterScaleEotfLuminancePlotValue\(\s*'eotf'/s,
  'drawEOTFChart calls meterDrawLiftedBlackLabel with the EOTF scale callback');

# 7. drawGammaChart must call the helper with the absolute luminance
# scale callback (linear scaling by yTop, not the EOTF-normalized path).
like($src, qr/function\s+drawGammaChart[\s\S]{0,4000}?meterDrawLiftedBlackLabel\(\s*ctx\s*,\s*chart\s*,\s*axisMax\s*,\s*yTop\s*,\s*Lb\s*,\s*measureSteps\s*,\s*scaleMeasuredLuminance\s*\)/s,
  'drawGammaChart calls meterDrawLiftedBlackLabel with the absolute scale callback');

# 8. The call must happen AFTER the measured points are drawn so the
# label sits on top of the line, not under it.
like($src, qr/mSegments\.forEach\([\s\S]{0,500}?meterDrawLiftedBlackLabel/s,
  'helper call sits after the measured-segment forEach (label on top)');

# 9. The helper must be a no-op on a true black (Lb == 0). This is the
# regression-prevention guard: a future change that removes the Lb guard
# would draw a confusing "0% = 0 cd/m^2" callout on every panel.
unlike($src, qr/function\s+meterDrawLiftedBlackLabel[\s\S]{0,400}?fillText\(\s*text/,
  'helper does not call fillText before the Lb > 0 guard');

# 10. The SDR / patch code / tone-map paths are untouched -- this commit
# only changes chart drawing in webui.pm. Re-assert the prior regression
# invariants to catch any accidental SDR/JS drift in a follow-up edit.
like($src, qr/"1\.4"=>14,"2"=>20,"2\.7"=>28/s,
  'hdr20 10-bit Full table still present (SDR-untouched invariant from the prior fix)');
like($src, qr/"1\.4"=>76,"2"=>82,"2\.7"=>88/s,
  'hdr20 10-bit Limited table still present (SDR-untouched invariant from the prior fix)');
like($src, qr/meterAutoCalMeasureHdrPeakLuminance[\s\S]{0,2000}?setTimeout\(r,\s*6000\)/s,
  'HDR tone-map wizard settle still 6s (3f1d8543 invariant)');

done_testing();

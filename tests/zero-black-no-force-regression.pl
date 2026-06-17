#!/usr/bin/env perl
# Test that meterNormalizeOledBlackReading no longer force-zeroes the
# 0% IRE greyscale reading when the measured luminance is invalid.
#
# Pre-fix behavior: the function had a branch that set
# reading.luminance = 0, reading.Y = 0, reading.X = 0, reading.Z = 0,
# and synthesized raw_luminance/raw_Y/etc. = 0 whenever the measured
# luminance was not finite or < 0. On OLED panels with a real black
# lift, the 0% IRE reading's luminance could become NaN/negative at
# some point in the normalization chain, and this branch would zero it
# out, hiding the lift. The chart then plotted 0.0 cd/m^2 at 0% IRE
# even when the panel was visibly lifted.
#
# Post-fix behavior: the function is a pass-through that delegates to
# meterNormalizeMeasuredReading and returns the reading unchanged. The
# 0% IRE reading flows through to the chart with its actual measured
# value, exactly like any other patch reading.
#
# This is a source-only test, no live renderer or meter required.
use strict;
use warnings;
use Test::More;

my $src_path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $src_path) or BAIL_OUT("can't read $src_path: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The function must exist with the expected name and pass-through
# signature.
like($src, qr/function\s+meterNormalizeOledBlackReading\s*\(\s*reading\s*\)/,
  'meterNormalizeOledBlackReading helper present with expected signature');

# 2. The function must delegate to meterNormalizeMeasuredReading and
# return the result. This is the pass-through behavior.
like($src, qr/return\s+meterNormalizeMeasuredReading\s*\(\s*reading\s*\)\s*;/s,
  'meterNormalizeOledBlackReading delegates to meterNormalizeMeasuredReading and returns the result');

# 3. The function must NOT contain the force-zero branches. These are
# the exact lines from the pre-fix code that set the reading to 0.
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?reading\.luminance\s*=\s*0\s*;/s,
  'function no longer force-zeroes reading.luminance');
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?reading\.Y\s*=\s*0\s*;/s,
  'function no longer force-zeroes reading.Y');
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?reading\.X\s*=\s*0\s*;/s,
  'function no longer force-zeroes reading.X');
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?reading\.Z\s*=\s*0\s*;/s,
  'function no longer force-zeroes reading.Z');

# 4. The function must NOT contain the guard that branched on OLED /
# greyscale / 0%-black. That guard existed only to gate the force-zero
# branch; with the branch removed, the guard is also dead code.
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?meterDisplayIsOled\(\)[\s\S]{0,200}?meterReadingIsZeroBlack\(reading\)/s,
  'function no longer branches on OLED / greyscale / 0%-black (guard was only for the force-zero path)');

# 5. The function must NOT check luminance for finiteness. The pre-fix
# code had `if(Number.isFinite(lum)&&lum>=0) return reading;` as a guard
# before the force-zero. With the force-zero removed, that guard is
# also dead code and would silently preserve a NaN reading rather than
# letting meterNormalizeMeasuredReading fix it.
unlike($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1500}?Number\.isFinite\s*\(\s*lum\s*\)/s,
  'function no longer gates on luminance finiteness (let meterNormalizeMeasuredReading handle it)');

# 6. The pass-through behavior is what callers expect. The function is
# called from 4 chart-display sites (meterGreyscaleReadings,
# meterChartBlackLevel, meterMeasuredContrastRatio, meterAttachSeriesMeta);
# none of them depend on the force-zero side effect (they all read
# reading.luminance or compute the min of valid readings, both of which
# work correctly with a NaN or 0 luminance).
like($src, qr/meterGreyscaleReadings[\s\S]{0,200}?meterNormalizeOledBlackReading/s,
  'meterGreyscaleReadings still calls the normalizer (pass-through is safe)');
like($src, qr/meterChartBlackLevel[\s\S]{0,200}?meterNormalizeOledBlackReading/s,
  'meterChartBlackLevel still calls the normalizer (pass-through is safe)');
like($src, qr/meterMeasuredContrastRatio[\s\S]{0,200}?meterNormalizeOledBlackReading/s,
  'meterMeasuredContrastRatio still calls the normalizer (pass-through is safe)');
like($src, qr/function\s+meterAttachSeriesMeta[\s\S]{0,2000}?meterNormalizeOledBlackReading/s,
  'meterAttachSeriesMeta still calls the normalizer (pass-through is safe)');

# 7. Prior-fix invariants must still hold. The HDR10 autocal series
# step builder (fc8ff80d), the spotread default (56c7019a), the
# tone-map settle (3f1d8543), and the lifted-black chart label
# (4668e285) are all unchanged by this fix.
like($src, qr/"1\.4"=>14,"2"=>20,"2\.7"=>28/s,
  'hdr20 10-bit Full table still present (fc8ff80d invariant)');
like($src, qr/"1\.4"=>76,"2"=>82,"2\.7"=>88/s,
  'hdr20 10-bit Limited table still present (fc8ff80d invariant)');
like($src, qr/meterAutoCalMeasureHdrPeakLuminance[\s\S]{0,2000}?setTimeout\(r,\s*6000\)/s,
  'HDR tone-map wizard settle still 6s (3f1d8543 invariant)');
like($src, qr/function\s+meterDrawLiftedBlackLabel/s,
  'lifted-black chart label helper still present (4668e285 invariant)');

done_testing();

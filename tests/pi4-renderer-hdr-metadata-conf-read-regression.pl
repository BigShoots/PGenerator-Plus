#!/usr/bin/env perl
# Test that ofxRPI4Window.cpp's updateHDR_Infoframe() reads the conf
# instead of zero-initializing min_display_mastering_luminance. The
# pre-fix behavior was that the renderer's wire HDR_OUTPUT_METADATA
# blob always had min_dml=0 regardless of conf, which the LG C2
# interprets as "signal can go down to true black" and applies a
# near-black lift at 5% stimulus.
#
# Source-only test, no live renderer required. The HDR metadata blob
# on the wire can be verified live with:
#   modetest -M vc4 -c 33 -p | grep -A 12 "7 HDR_OUTPUT_METADATA"
use strict;
use warnings;
use Test::More;

my $cpp = 'tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp';
open(my $fh, '<', $cpp) or BAIL_OUT("can't read $cpp: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The renderer source has a helper that reads the conf.
like($src, qr/static\s+double\s+pg_read_conf_double/,
  'ofxRPI4Window.cpp has pg_read_conf_double helper');
like($src, qr/static\s+int\s+pg_read_conf_int/,
  'ofxRPI4Window.cpp has pg_read_conf_int helper');
like($src, qr/static\s+uint16_t\s+pg_min_luma_to_u16/,
  'ofxRPI4Window.cpp has pg_min_luma_to_u16 helper (units 0.0001 cd/m^2)');
like($src, qr|define\s+PG_HDR_CONF_PATH\s+"/etc/PGenerator/PGenerator.conf"|,
  'ofxRPI4Window.cpp defines PG_HDR_CONF_PATH');

# 2. updateHDR_Infoframe reads min_luma/max_luma/max_cll/max_fall from conf.
like($src,
  qr/updateHDR_Infoframe\([^)]*\)\s*\{[\s\S]{0,2000}?pg_min_luma\s*=\s*pg_read_conf_double\([^)]*?min_luma/s,
  'updateHDR_Infoframe reads min_luma from conf');
like($src,
  qr/updateHDR_Infoframe\([^)]*\)\s*\{[\s\S]{0,2000}?pg_max_luma\s*=\s*pg_read_conf_double\([^)]*?max_luma/s,
  'updateHDR_Infoframe reads max_luma from conf');
like($src,
  qr/updateHDR_Infoframe\([^)]*\)\s*\{[\s\S]{0,2000}?pg_max_cll\s*=\s*pg_read_conf_int\([^)]*?max_cll/s,
  'updateHDR_Infoframe reads max_cll from conf');
like($src,
  qr/updateHDR_Infoframe\([^)]*\)\s*\{[\s\S]{0,2000}?pg_max_fall\s*=\s*pg_read_conf_int\([^)]*?max_fall/s,
  'updateHDR_Infoframe reads max_fall from conf');

# 3. The conversion factor is 0.0001 cd/m^2 per unit (matches pgsethdr.c).
like($src,
  qr/pg_min_luma_to_u16[\s\S]{0,200}?0\.0001/,
  'pg_min_luma_to_u16 uses the 0.0001 cd/m^2 per unit conversion factor (matches pgsethdr.c)');

# 4. The wire-blob `meta` struct gets min/max_dml from the conf values.
like($src,
  qr/min_display_mastering_luminance\s*=\s*pg_min_dml/,
  'wire blob min_display_mastering_luminance is populated from pg_min_dml');
like($src,
  qr/max_display_mastering_luminance\s*=\s*pg_max_dml/,
  'wire blob max_display_mastering_luminance is populated from pg_max_dml');

# 5. The HDR/HLG branch (eotf == 3) also reads from conf.
like($src,
  qr/if\s*\(static_cast<int>\(eotf\)\s*==\s*3\)[\s\S]{0,2000}?min_display_mastering_luminance\s*=\s*pg_min_dml/s,
  'HLG branch also uses pg_min_dml');
like($src,
  qr/if\s*\(static_cast<int>\(eotf\)\s*==\s*3\)[\s\S]{0,2000}?max_display_mastering_luminance\s*=\s*pg_max_dml/s,
  'HLG branch also uses pg_max_dml');

# 6. The zero-init pattern from the bug is gone in both branches.
unlike($src,
  qr/if\s*\(static_cast<int>\(eotf\)\s*==\s*3\)[\s\S]{0,1500}?min_display_mastering_luminance\s*=\s*0\s*;/s,
  'HLG branch no longer zero-inits min_display_mastering_luminance');

done_testing();

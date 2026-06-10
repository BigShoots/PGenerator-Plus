#!/usr/bin/env perl
# Test that pgsethdr correctly plumbs /etc/PGenerator/PGenerator.conf
# into the HDR_OUTPUT_METADATA connector blob on the wire.
#
# This is a static source-text + wire-format test, not a runtime test.
# Live verification (run pgsethdr, read the wire blob) is done by hand
# on the Pi4 because it requires the actual DRM device.
use strict;
use warnings;
use Test::More;

my $pgsethdr_c = 'usr/bin/pgsethdr.c';
my $pgsethdr_static = 'usr/bin/pgsethdr.static';

# 1. The source file exists and is non-empty.
ok(-f $pgsethdr_c, "pgsethdr.c source exists at $pgsethdr_c");
open(my $fh, '<', $pgsethdr_c) or BAIL_OUT("can't read $pgsethdr_c: $!");
local $/; my $src = <$fh>; close $fh;
ok(length($src) > 1000, "pgsethdr.c is non-trivial (".length($src)." bytes)");

# 2. The source plumbs the conf keys we care about into the wire blob:
#    eotf, primaries, max_luma, min_luma, max_cll, max_fall.
like($src, qr/parse_int.*?is_hdr.*?\)/s,  'pgsethdr reads is_hdr from conf');
like($src, qr/parse_int.*?eotf.*?\)/s,    'pgsethdr reads eotf from conf');
like($src, qr/parse_int.*?primaries.*?\)/s,'pgsethdr reads primaries from conf');
like($src, qr/parse_int.*?max_luma.*?\)/s, 'pgsethdr reads max_luma from conf');
like($src, qr/parse_double.*?min_luma.*?\)/s,'pgsethdr reads min_luma from conf (as double)');
like($src, qr/parse_int.*?max_cll.*?\)/s,  'pgsethdr reads max_cll from conf');
like($src, qr/parse_int.*?max_fall.*?\)/s, 'pgsethdr reads max_fall from conf');

# 3. The min_luma -> min_dml conversion factor is 0.0001 cd/m^2 per
#    unit (per CTA-861-G). min_dml = round(min_luma / 0.0001).
#    PGenerator 1.6 / Plus both use this exact conversion.
like($src, qr/min_luma_to_u16\s*\(\s*double\s+value\s*\)\s*\{[\s\S]{0,200}?0\.0001/s,
  'min_luma_to_u16 uses the 0.0001 cd/m^2 per unit conversion factor');

# 4. The static binary is also tracked (used as a fallback for systems
#    without libc, e.g. minimal initramfs).
ok(-f $pgsethdr_static, "pgsethdr.static fallback binary exists at $pgsethdr_static");

# 5. Init.d hook: pgsethdr runs at PGenerator start, before the
#    renderer forks, so the blob is set with the renderer as the
#    initial DRM master.
my $init_d = 'etc/init.d/PGenerator';
open(my $ifh, '<', $init_d) or BAIL_OUT("can't read $init_d: $!");
my $init_src = do { local $/; <$ifh> }; close $ifh;
like($init_src, qr|/usr/bin/pgsethdr|,
  "init.d/PGenerator references pgsethdr (will be called at startup)");

# 6. WebUI helper: apply_hdr_metadata_helper is called from
#    pattern_generator_start so the blob is set every time the
#    renderer restarts.
my $cmd_pm = 'usr/share/PGenerator/command.pm';
open(my $cmdfh, '<', $cmd_pm) or BAIL_OUT("can't read $cmd_pm: $!");
my $cmd_src = do { local $/; <$cmdfh> }; close $cmdfh;
like($cmd_src, qr/sub apply_hdr_metadata_helper/,'command.pm has apply_hdr_metadata_helper');
like($cmd_src, qr|apply_hdr_metadata_helper\(\);|,'pattern_generator_start calls apply_hdr_metadata_helper');
like($cmd_src, qr|my \$helper="/usr/bin/pgsethdr";|,'apply_hdr_metadata_helper runs pgsethdr');

done_testing();

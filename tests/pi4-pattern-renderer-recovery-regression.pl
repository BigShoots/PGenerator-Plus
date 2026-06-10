#!/usr/bin/env perl
# Regression test: pattern.pm load_new_pattern_file renderer recovery.
use strict;
use warnings;
use Test::More;

my $pm = 'usr/share/PGenerator/pattern.pm';
open(my $fh, '<', $pm) or BAIL_OUT("can't read $pm: $!");
local $/; my $src = <$fh>; close $fh;

like($src,
  qr/load_new_pattern_file:[\s\S]{0,3000}?renderer not running after first start, retrying \(DRM master race\)/,
  'load_new_pattern_file logs a retry on the DRM-master race');
like($src,
  qr/load_new_pattern_file:[\s\S]{0,3000}?renderer still not running after second start, final retry/,
  'load_new_pattern_file has a second retry after the first fails');
like($src,
  qr/load_new_pattern_file:[\s\S]{0,3000}?waiting 3s for DRM master to settle/,
  'load_new_pattern_file has a long-delay settle retry for persistent races');
like($src,
  qr/load_new_pattern_file:[\s\S]{0,3000}?renderer failed to start after all retries/,
  'load_new_pattern_file logs when all retries fail');

# Count stop+start pairs in the recovery block — should be at least 3
# (first start + two retries, each followed by stop+start).
my $recovery_start = index($src, "if(!&pattern_generator_is_running()) {");
my $recovery_block = $recovery_start >= 0 ? substr($src, $recovery_start, 3000) : "";
my $stops = () = $recovery_block =~ /pattern_generator_stop\(\)/g;
my $starts = () = $recovery_block =~ /pattern_generator_start\(1\)/g;
cmp_ok($stops, '>=', 3, "recovery block has at least 3 stop calls (got $stops)");
cmp_ok($starts, '>=', 4, "recovery block has at least 4 start calls (got $starts)");

like($src,
  qr/pattern_generator_start\(1\)\s*;\s*select\(undef,undef,undef,0\.6\)/,
  'retry waits 0.6s after start before checking is_running');

done_testing();

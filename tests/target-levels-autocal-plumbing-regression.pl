#!/usr/bin/env perl
# Regression test for the calibration-card Target White / Target Black
# override plumbing in usr/bin/meter_lg_autocal.pl.
#
# Verifies that target_luminance_for_step anchors its target Y curve to the
# operator's entered white-peak / black-floor when the overrides are active,
# and falls back to the measured references when they are cleared. Source-only
# test; the production file's main body is guarded by `unless(caller())` so
# `require` is safe.
use strict;
use warnings;
use Test::More;

my $autocal_path = 'usr/bin/meter_lg_autocal.pl';
my $require_ok = eval { require "./$autocal_path"; 1 } ? 1 : 0;
if(!$require_ok) {
 diag("require failed: $@");
}
ok($require_ok, 'required meter_lg_autocal.pl without running its main body')
 or BAIL_OUT('require failed');

my $step = { ire => 50, stimulus => 50 };

# --- Baseline: no override -> measured white (120) and measured black (0.1).
main::autocal_set_target_overrides(undef, undef);
my ($w_ov, $b_ov) = main::autocal_target_overrides();
ok(!defined($w_ov) && !defined($b_ov), 'overrides cleared (use measured)');

my $t_measured = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0.1);
ok(defined($t_measured) && $t_measured > 0, 'baseline target is defined');

# --- Manual Target White override (100) replaces the measured peak (120).
main::autocal_set_target_overrides(100, undef);
my $t_white_ov = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0.1);
ok(defined($t_white_ov), 'white-overridden target is defined');
# With a lower white peak (100 < 120) and the same stimulus, the target Y at
# 50% must be lower than the measured-peak baseline.
cmp_ok($t_white_ov, '<', $t_measured,
 'manual Target White=100 lowers the 50% target vs measured peak=120');

# --- Manual Target Black override (0) removes the BT.1886 lift. With black=0
# the curve is a pure 2.4 power law; at 50% that is white*0.5^2.4. With a
# positive measured black the BT.1886 curve sits above the pure-power curve at
# mid stimulus, so the override must produce a LOWER target at 50%.
main::autocal_set_target_overrides(undef, undef);
my $t_black_meas = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0.5);
main::autocal_set_target_overrides(undef, 0);
my $t_black_zero = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0);
ok(defined($t_black_zero) && defined($t_black_meas),
 'black-overridden targets are defined');
cmp_ok($t_black_zero, '<', $t_black_meas,
 'manual Target Black=0 (no BT.1886 lift) is below the lifted measured-black=0.5 curve at 50%');

# --- Combined override: white=100, black=0. Must use BOTH overrides
# simultaneously (not just one).
main::autocal_set_target_overrides(100, 0);
my $t_both = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0.5);
my $t_white100_black0 = main::target_luminance_for_step(100, $step, 'bt1886', 'sdr', 0);
ok(defined($t_both) && defined($t_white100_black0),
 'combined-overridden target is defined');
is(sprintf('%.6f', $t_both), sprintf('%.6f', $t_white100_black0),
 'combined override (white=100,black=0) equals a direct call with those endpoints, ignoring the measured args');

# --- 100% IRE always tracks the (overridden) white peak exactly.
my $step100 = { ire => 100, stimulus => 100 };
main::autocal_set_target_overrides(100, 0);
my $t100 = main::target_luminance_for_step(120, $step100, 'bt1886', 'sdr', 0.5);
is(sprintf('%.6f', $t100), '100.000000',
 '100% IRE target equals the overridden Target White (100), not the measured peak (120)');

# --- Clearing overrides restores the measured-peak baseline.
main::autocal_set_target_overrides(undef, undef);
my $t_restored = main::target_luminance_for_step(120, $step, 'bt1886', 'sdr', 0.1);
is(sprintf('%.6f', $t_restored), sprintf('%.6f', $t_measured),
 'clearing overrides restores the measured-reference target');

done_testing();

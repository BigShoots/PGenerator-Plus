#!/usr/bin/env perl
# Smoke regression test for the SDR26 direct-DPG upload path.
#
# Verifies the pure-math surface the new SDR helper symbols depend on,
# without requiring a live renderer, a live meter, or a live LG TV. All
# of the wiring (pgenerator-lg helper, WebUI knob, smart dispatcher) is
# exercised via static analysis: define the function in main::, call it
# on synthetic input, check the return shape and clamp envelope.
#
# The production file's main body is guarded by `unless(caller())` so
# `require` is safe in the test harness.
#
# Coverage:
#
#   1. lg_autocal_26_sdr26_dpg_gain (BT.709/D65 variant of the HDR20
#      gain fn) returns a 3-tuple in the [0.5, 2.0] clamp envelope for
#      a synthetic reading. Mirrors tests/autocal-hdr20-dpg-gain-
#      regression.pl but exercises the BT.709 matrix instead of P3.
#
#   2. lg_autocal_26_build_sdr_1d_dpg is defined and delegates to the
#      HDR20 builder: empty anchors + undef current returns the 3072-
#      entry linear identity baseline (same numeric signature).
#
#   3. pgenerator-lg syntax is clean (perl -c -- the SDR branch +
#      BT709 3BY3 send + 1D_2_2_EN/1D_0_45_EN disable are pure text
#      changes against an unverified runtime, but they MUST at least
#      compile).
#
#   4. webui.pm has lg_autocal_sdr_1d_dpg_upload_enabled:true on at
#      least one SDR autocal config builder (the gate for the path).
#
# This is NOT a live-TVR test. The actual wire upload is exercised on
# hardware by the operator.
use strict;
use warnings;
use Test::More;

# --- Test setup: require the production file ---

my $autocal_path = 'usr/bin/meter_lg_autocal.pl';
my $require_ok = eval { require "./$autocal_path"; 1 } ? 1 : 0;
if(!$require_ok) {
 diag("require failed: $@");
}
ok($require_ok, 'production file is require-safe via unless(caller()) guard')
 or BAIL_OUT('require failed');

# --- Test 1: BT.709/D65 gain function returns 3-tuple in [0.5, 2.0] ---

ok(defined(&main::lg_autocal_26_sdr26_dpg_gain),
   'lg_autocal_26_sdr26_dpg_gain is defined in main:: after require')
 or BAIL_OUT('sdr26 dpg_gain sub not defined');

# Build the target XYZ for a D65 neutral at the given luminance. Mirrors
# the math inside the sub: tY = Y, tX = (x/y)*Y, tZ = ((1-x-y)/y)*Y.
sub _sdr_target_xyz {
 my ($target_luminance,$target_x,$target_y)=@_;
 return (
  ($target_x/$target_y) * $target_luminance,
  $target_luminance + 0,
  ((1 - $target_x - $target_y)/$target_y) * $target_luminance,
 );
}

{
 # Test 1a: on-target D65 reading at BT.709/D65 neutral -> gains ~ 1.0
 my ($tx,$ty,$tY)=(0.3127, 0.329, 100);
 my ($tX,$tYv,$tZ)=_sdr_target_xyz($tY,$tx,$ty);
 my $reading={ X=>$tX, Y=>$tYv, Z=>$tZ };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is(scalar(@g), 3, 'Test 1a: returns list of 3 gains');
 ok(abs($g[0] - 1.0) < 0.001, "Test 1a: r_gain ~ 1.0 for on-target reading (got $g[0])");
 ok(abs($g[1] - 1.0) < 0.001, "Test 1a: g_gain ~ 1.0 for on-target reading (got $g[1])");
 ok(abs($g[2] - 1.0) < 0.001, "Test 1a: b_gain ~ 1.0 for on-target reading (got $g[2])");
}

{
 # Test 1b: too-blue reading (Z x 1.3) -> b_gain < 1.0 (panel needs
 # to pull blue down toward D65) and clamped to [0.5, 1.0].
 my ($tx,$ty,$tY)=(0.3127, 0.329, 100);
 my ($tX,$tYv,$tZ)=_sdr_target_xyz($tY,$tx,$ty);
 my $reading={ X=>$tX, Y=>$tYv, Z=>$tZ * 1.3 };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is(scalar(@g), 3, 'Test 1b: returns list of 3 gains');
 ok($g[2] < 1.0, "Test 1b: b_gain < 1.0 for too-blue reading (got $g[2])");
 ok($g[2] >= 0.5, "Test 1b: b_gain >= 0.5 (per-iteration clamp; got $g[2])");
 ok($g[2] <= 1.0, "Test 1b: b_gain <= 1.0 (got $g[2])");
}

{
 # Test 1c: half-luminance reading -> all three gains clamp to 2.0
 # (panel cannot meaningfully boost a channel above 2x without clipping
 # or rolling into the panel's native white at low IRE on SDR).
 my ($tx,$ty,$tY)=(0.3127, 0.329, 100);
 my ($tX,$tYv,$tZ)=_sdr_target_xyz($tY,$tx,$ty);
 my $reading={ X=>$tX*0.5, Y=>$tYv*0.5, Z=>$tZ*0.5 };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is(scalar(@g), 3, 'Test 1c: returns list of 3 gains');
 is($g[0], 2.0, "Test 1c: r_gain clamped to 2.0 (got $g[0])");
 is($g[1], 2.0, "Test 1c: g_gain clamped to 2.0 (got $g[1])");
 is($g[2], 2.0, "Test 1c: b_gain clamped to 2.0 (got $g[2])");
}

{
 # Test 1d: missing / zero measured input -> returns (1.0, 1.0, 1.0)
 # (the safety net for any non-positive / missing measurement).
 my @g_empty=main::lg_autocal_26_sdr26_dpg_gain({},100,0.3127,0.329);
 is_deeply(\@g_empty, [1.0, 1.0, 1.0], 'Test 1d: empty reading -> (1, 1, 1)');
 my @g_y0=main::lg_autocal_26_sdr26_dpg_gain({ Y=>0 },100,0.3127,0.329);
 is_deeply(\@g_y0, [1.0, 1.0, 1.0], 'Test 1d: Y=0 reading -> (1, 1, 1)');
 my @g_badtarget=main::lg_autocal_26_sdr26_dpg_gain({ X=>95.0, Y=>100, Z=>108.9 },0,0.3127,0.329);
 is_deeply(\@g_badtarget, [1.0, 1.0, 1.0], 'Test 1d: zero target luminance -> (1, 1, 1)');
}

# --- Test 2: SDR build wrapper is defined and delegates to HDR20 ---

ok(defined(&main::lg_autocal_26_build_sdr_1d_dpg),
   'lg_autocal_26_build_sdr_1d_dpg is defined in main:: after require')
 or BAIL_OUT('sdr build wrapper sub not defined');

{
 # Empty anchors + undef current -> 3072-entry linear identity baseline
 # (same numeric signature as the HDR20 builder it delegates to).
 # The SDR26 build wrapper uses the same int(k*32+0.5) identity formula
 # as the HDR20 builder; int(1023*32+0.5) = 32736, NOT 32767 (which
 # would imply int(k*32.005..)). The smoke test's older 32767 expected
 # value was a stale formula.
 my $dpg = main::lg_autocal_26_build_sdr_1d_dpg(undef, []);
 is(ref($dpg), 'ARRAY', 'Test 2a: returns an arrayref');
 is(scalar(@$dpg), 3072, 'Test 2a: result has 3072 elements');
 is($dpg->[51], 1632, 'Test 2a: R[51] == 1632 (linear identity int(51*32+0.5))');
 is($dpg->[1023], 32736, 'Test 2a: R[1023] == 32736 (linear identity endpoint int(1023*32+0.5))');
 is($dpg->[1024 + 1023], 32736, 'Test 2a: G[1023] == 32736 (channels equal under identity)');
 is($dpg->[2048 + 1023], 32736, 'Test 2a: B[1023] == 32736 (channels equal under identity)');
}

{
 # Single white anchor with per-channel gains on undef current -> gains
 # apply to the white endpoint (R[1023] = 1.0 -> 32736; G/B scaled).
 my $anchors = [{ idx => 1023, r_gain => 1.0, g_gain => 0.95, b_gain => 0.82 }];
 my $dpg = main::lg_autocal_26_build_sdr_1d_dpg(undef, $anchors);
 is($dpg->[1023], 32736, 'Test 2b: R[1023] == 32736 (gain 1.0 on identity 32736)');
 is($dpg->[1024 + 1023], 31099, 'Test 2b: G[1023] == 31099 (int(32736*0.95+0.5))');
 is($dpg->[2048 + 1023], 26844, 'Test 2b: B[1023] == 26844 (int(32736*0.82+0.5))');
}

# --- Test 3: pgenerator-lg syntax is clean ---

{
 my $lg_path = 'usr/sbin/pgenerator-lg';
 my $check = `perl -c $lg_path 2>&1`;
 my $ok = ($? == 0) ? 1 : 0;
 if(!$ok) {
  diag("perl -c $lg_path failed:\n$check");
 }
 ok($ok, 'pgenerator-lg compiles cleanly (SDR branch + BT709 send + gamma-disable must at least parse)');
}

# --- Test 4: webui.pm has the SDR direct-DPG opt-in on a config builder ---

{
 my $webui_path = 'usr/share/PGenerator/webui.pm';
 open(my $fh, '<', $webui_path) or BAIL_OUT("cannot open $webui_path: $!");
 my $contents = do { local $/; <$fh> };
 close($fh);
 like($contents, qr/lg_autocal_sdr_1d_dpg_upload_enabled\s*:\s*true/,
   'Test 4: webui.pm enables lg_autocal_sdr_1d_dpg_upload_enabled on at least one SDR config builder');
}

done_testing();
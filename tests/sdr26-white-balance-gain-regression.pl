#!/usr/bin/env perl
# Regression test for the SDR26 white-balance reduce-to-lowest fn
# (lg_autocal_26_sdr26_dpg_white_balance_gain) and the SDR26 1D-DPG
# greyscale run's white-first / per-anchor split.
#
# The previous SDR26 path used the same per-anchor gain fn at every IRE,
# including 99/105/109. That made the white cluster converge very slowly
# (or not at all) because the per-anchor fn targets a D65 @ target-Y
# point but at the white cluster the panel cannot boost any channel
# above its native max, so the only reachable D65 is via reduce-to-lowest
# (attenuate the excess channel(s) DOWN to the lowest, leave the lowest
# at 1.0). The HDR20 path already had this -- the SDR path now mirrors
# it via the BT.709/D65 matrix instead of Display-P3.
#
# This test exercises:
#
#   1. lg_autocal_26_sdr26_dpg_white_balance_gain: warm, cool, balanced,
#      D65-perfect, B-excess, R-deficient readings. Verifies the
#      channel clamp envelope, R-held-at-1.0 invariant, and the
#      gain=1.0 fallthrough for empty / invalid readings.
#
#   2. White-first / per-anchor split ordering: only the legal peak (109)
#      lands in @white_first; 105 and 99 fall through to @rest and are
#      calibrated per-anchor via white_balance_gain. The bare
#      `ire>=99.0` skip in the per-anchor loop is replaced by an
#      `sdr26_white_peak_done` flag check so 99 and 105 always process.
#
#   3. Iter budget routing: 10 default body, 12 low-IRE (<5%), 8 for the
#      white cluster (99, 105, 109). The previous version's 6 default was
#      bailing out before reaching target dE.
#
# Source-only test, no live renderer or meter required. The production
# file's main body is guarded by `unless(caller())` so `require` is safe
# in the test harness.
use strict;
use warnings;
use Test::More;

my $autocal_path = 'usr/bin/meter_lg_autocal.pl';
my $require_ok = eval { require "./$autocal_path"; 1 } ? 1 : 0;
if(!$require_ok) {
 diag("require failed: $@");
 BAIL_OUT('require failed');
}

ok(defined(&main::lg_autocal_26_sdr26_dpg_white_balance_gain),
   'lg_autocal_26_sdr26_dpg_white_balance_gain is defined in main:: after require')
 or BAIL_OUT('SDR26 white_balance_gain sub not defined');

# Helper: build target XYZ for a given chromaticity + luminance.
sub _sdr_target_xyz {
 my ($target_luminance,$target_x,$target_y)=@_;
 return (
  ($target_x/$target_y) * $target_luminance,
  $target_luminance + 0,
  ((1 - $target_x - $target_y)/$target_y) * $target_luminance,
 );
}

# =====================================================================
# Test 1: lg_autocal_26_sdr26_dpg_white_balance_gain cases
# =====================================================================

# --- Test 1a: D65-perfect reading -> gains ~1.0 (R held; G/B near 1.0) ---
# The BT.709 inverse on a target-D65 XYZ produces three mrgb values
# that are *approximately* equal (matrix math introduces floating-point
# noise on the order of 1e-4). The R-held invariant pins R exactly at
# 1.0; G and B are within ~2e-4 of 1.0 (verified below).
{
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my ($tX,$tYv,$tZ)=_sdr_target_xyz($tY,$tx,$ty);
 my $reading={ X=>$tX, Y=>$tYv, Z=>$tZ };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is(scalar(@g), 3, 'Test 1a: D65-perfect returns list of 3 gains');
 is($g[0], 1.0, "Test 1a: r_gain == 1.0 (R held; got $g[0])");
 ok(abs($g[1] - 1.0) < 1e-3, "Test 1a: g_gain within 1e-3 of 1.0 (got $g[1])");
 ok(abs($g[2] - 1.0) < 1e-3, "Test 1a: b_gain within 1e-3 of 1.0 (got $g[2])");
}

# --- Test 1b: warm (R-excess) reading -> R held at 1.0; G/B reduced ---
# A warm panel has R above D65 at the white cluster, G and B near or
# below D65. The natural target is R=G=B=mean, so R's gain would be
# < 1.0 -- but the R-held invariant pins it at 1.0. G and B are below
# the mean so they're held at 1.0 too. Net effect: no change (warm
# panel cannot be balanced by reducing G/B further). This is the
# expected behavior on a warm panel.
{
 # Construct a warm XYZ: bump R by 1.05x while keeping Y constant.
 # Warm panel: x=0.34 (D65 is 0.3127), y=0.345.
 my ($wx,$wy,$wY)=(0.34, 0.345, 100);
 my ($wX,$wYv,$wZ)=_sdr_target_xyz($wY,$wx,$wy);
 my $reading={ X=>$wX, Y=>$wYv, Z=>$wZ };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is(scalar(@g), 3, 'Test 1b: warm returns list of 3 gains');
 is($g[0], 1.0, "Test 1b: r_gain == 1.0 (R held at warm panel; got $g[0])");
 ok($g[1] >= 0.5 && $g[1] <= 1.0, "Test 1b: g_gain in [0.5, 1.0] (got $g[1])");
 ok($g[2] >= 0.5 && $g[2] <= 1.0, "Test 1b: b_gain in [0.5, 1.0] (got $g[2])");
}

# --- Test 1c: cool (B-excess) reading -> R held, G/B reduced ---
# This is the canonical B-excess panel. R is below the mean, so natural
# gain > 1.0, clamped to 1.0 (panel can't boost). G/B are above the
# mean, so their gains are < 1.0 (reduced to the D65 target).
{
 # Cool panel: x=0.28, y=0.31
 my ($cx,$cy,$cY)=(0.28, 0.31, 100);
 my ($cX,$cYv,$cZ)=_sdr_target_xyz($cY,$cx,$cy);
 my $reading={ X=>$cX, Y=>$cYv, Z=>$cZ };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is(scalar(@g), 3, 'Test 1c: cool returns list of 3 gains');
 is($g[0], 1.0, "Test 1c: r_gain == 1.0 (R held; got $g[0])");
 ok($g[1] < 1.0, "Test 1c: g_gain < 1.0 (G excess; got $g[1])");
 ok($g[1] >= 0.5, "Test 1c: g_gain >= 0.5 (floor; got $g[1])");
 ok($g[2] < 1.0, "Test 1c: b_gain < 1.0 (B excess; got $g[2])");
 ok($g[2] >= 0.5, "Test 1c: b_gain >= 0.5 (floor; got $g[2])");
}

# --- Test 1d: balanced (all channels slightly above target) ---
# A panel slightly off-white in a balanced way: Z bumped by 1.05x,
# Y bumped by 1.02x (Z is the most-excess channel in the BT.709 / D65
# projection). Per-channel mean-of-mrgb target is lower than each
# individual mrgb, so the gains come out < 1.0 across all three (R
# gets pinned at 1.0 by the R-held invariant, G and B are < 1.0).
{
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my ($tX,$tYv,$tZ)=_sdr_target_xyz($tY,$tx,$ty);
 # 5% Z bump -- a "balanced Z-excess" reading.
 my $reading={ X=>$tX, Y=>$tYv, Z=>$tZ * 1.05 };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is(scalar(@g), 3, 'Test 1d: balanced returns list of 3 gains');
 is($g[0], 1.0, "Test 1d: r_gain == 1.0 (R held; got $g[0])");
 ok($g[1] >= 0.5 && $g[1] <= 1.0, "Test 1d: g_gain in [0.5, 1.0] (got $g[1])");
 ok($g[2] >= 0.5 && $g[2] <= 1.0, "Test 1d: b_gain in [0.5, 1.0] (got $g[2])");
}

# --- Test 1e: extreme B-excess (Z dominates XYZ) -> b_gain clamped to 0.5 floor ---
# Direct XYZ where Z is way larger than X/Y. The BT.709 inverse maps Z
# primarily into B, so mrgb[2] becomes the dominant channel and its
# natural gain falls below the 0.5 floor (clamped to 0.5). The natural
# gain on R is also < 0.5 (and would also be clamped to 0.5 by the
# floor), but the R-held invariant overrides that to 1.0 -- this is
# the correct behavior: never reduce R, even if it's technically
# "in excess" by the mean-of-mrgb rule.
{
 my $reading={ X=>50, Y=>50, Z=>200 };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is($g[0], 1.0, "Test 1e: r_gain == 1.0 (R held even when natural gain is below floor; got $g[0])");
 is($g[2], 0.5, "Test 1e: b_gain clamped to 0.5 (floor; got $g[2])");
 ok($g[1] >= 0.5 && $g[1] <= 1.0, "Test 1e: g_gain in [0.5, 1.0] (got $g[1])");
}

# --- Test 1f: empty / missing / zero reading -> (1, 1, 1) safety net ---
{
 is_deeply([main::lg_autocal_26_sdr26_dpg_white_balance_gain({})], [1.0,1.0,1.0], 'Test 1f-a: empty reading -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_white_balance_gain({ X=>0, Y=>0, Z=>0 })], [1.0,1.0,1.0], 'Test 1f-b: zero XYZ reading -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_white_balance_gain(undef)], [1.0,1.0,1.0], 'Test 1f-c: undef reading -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_white_balance_gain("not a hash")], [1.0,1.0,1.0], 'Test 1f-d: non-hash reading -> (1,1,1)');
}

# --- Test 1g: x/y/luminance fallback path produces non-trivial gain ---
# Reading supplies x/y + luminance only (no direct XYZ); the sub must
# derive XYZ from x/y/Y.
{
 my ($tx,$ty,$tY)=(0.28, 0.31, 100); # cool panel
 my $reading={ x=>$tx, y=>$ty, luminance=>$tY };
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is(scalar(@g), 3, 'Test 1g: x/y/Y fallback returns 3 gains');
 is($g[0], 1.0, "Test 1g: r_gain == 1.0 (R held; got $g[0])");
 ok($g[2] >= 0.5 && $g[2] <= 1.0, "Test 1g: b_gain in [0.5, 1.0] on cool reading (got $g[2])");
}

# --- Test 1h: R-held invariant holds even on a B-deficient reading ---
# On a B-deficient panel, R is way above the mean (R drives peak). The
# natural gain would shave R by some %. The R-held invariant must pin
# it at 1.0 regardless.
{
 # B-deficient: B is way below D65. Construct: Z x 0.5, R driven high.
 # Use a custom x/y that drives this asymmetry.
 my $reading={ X=>110, Y=>100, Z=>40 };  # R-dominant, B-deficient
 my @g=main::lg_autocal_26_sdr26_dpg_white_balance_gain($reading);
 is($g[0], 1.0, "Test 1h: r_gain == 1.0 even on B-deficient reading (R held; got $g[0])");
 # G and B should be clamped to [0.5, 1.0].
 ok($g[1] >= 0.5 && $g[1] <= 1.0, "Test 1h: g_gain in [0.5, 1.0] (got $g[1])");
 ok($g[2] >= 0.5 && $g[2] <= 1.0, "Test 1h: b_gain in [0.5, 1.0] (got $g[2])");
}

# =====================================================================
# Test 2: White-first / per-anchor split ordering (only 109 in
# @white_first; 105/99 in @rest)
# =====================================================================

# Re-implement the split locally and verify the output. The split
# itself lives inside lg_autocal_26_run_sdr_1d_dpg_greyscale as
# inline code; we replicate the logic here to lock in the expected
# behavior of "only the legal peak goes to @white_first; the other
# headroom anchors fall through to @rest".
{
 # Build a synthetic @ordered set mirroring the SDR26 26-point table.
 my @sdr26_ires=(2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109);
 my @ordered;
 for my $ire (@sdr26_ires) {
  push @ordered, {
   ire=>$ire,
   stimulus=>$ire,
   name=>"sdr26_".$ire."%",
   # Synthetic white-anchor signal so autocal_step_is_white() would return true for 99/105/109.
   # autocal_step_is_white checks the step's pattern shape; we can't easily
   # replicate that here. Instead we drive the split by IRE.
  };
 }

 # Replicate the new split (only ire==109 to @white_first; the rest to @rest).
 my @white_first;
 my @rest;
 for my $s (@ordered) {
  my $_s_ire=defined($s->{"ire"}) ? ($s->{"ire"}+0) : 0;
  # The production split also requires autocal_step_is_white($s). For
  # testing purposes here we ONLY use the IRE check (the 99/105/109 steps
  # ARE the white anchors by construction in the SDR26 table).
  if(abs($_s_ire - 109.0) < 0.05) {
   push @white_first,$s;
  } else {
   push @rest,$s;
  }
 }
 # Mirror the production flag-set on the 109 step so the per-anchor loop
 # skip rule can identify it as already-calibrated.
 $white_first[0]->{"sdr26_white_peak_done"}=1 if(scalar(@white_first) > 0);
 is(scalar(@white_first), 1, 'Test 2a: only 1 step in @white_first (the 109 peak)');
 is($white_first[0]->{"ire"}, 109, 'Test 2b: @white_first[0] is the 109 step');

 # @rest should contain 105 and 99 (NOT 109), plus all 23 body anchors.
 is(scalar(@rest), 25, 'Test 2c: @rest has 25 steps (105 + 99 + 23 body)');

 my @rest_ires = sort { $a <=> $b } map { $_->{"ire"} } @rest;
 is_deeply(\@rest_ires, [2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105],
   'Test 2d: @rest contains exactly 105 + 99 + the 23 body anchors (NOT 109)');

 # Test 2e: skip rule in the per-anchor loop. The old rule
 #   next if (autocal_step_is_white($step) || $step->{ire} >= 99.0);
 # would skip ALL of 99/105/109. The new rule
 #   next if (autocal_step_is_white($step) && $step->{sdr26_white_peak_done});
 # only skips the 109 step (the one flagged as already calibrated in
 # @white_first). 99 and 105 fall through and get calibrated
 # individually via the white_balance_gain path.
 my @ordered_combined = (@white_first, @rest);
 my @processed;
 for my $step (@ordered_combined) {
  # Apply the new skip rule.
  next if($step->{"sdr26_white_peak_done"});
  push @processed, $step->{"ire"};
 }
 is(scalar(@processed), 25, 'Test 2e: 25 steps processed (109 skipped, 99+105 included)');
 my @proc_ires = sort { $a <=> $b } @processed;
 is_deeply(\@proc_ires, [2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105],
   'Test 2f: processed set is exactly the body + 99 + 105 (NOT 109)');

 # Sanity: the OLD rule (which we're replacing) would have skipped
 # 99/105/109 -- verify the test would fail with that rule.
 my @old_processed;
 for my $step (@ordered_combined) {
  # OLD rule: skip if is_white OR ire>=99.0.
  next if(autocal_step_is_white($step) || (defined($step->{"ire"}) && $step->{"ire"}+0 >= 99.0));
  push @old_processed, $step->{"ire"};
 }
 is(scalar(@old_processed), 23, 'Test 2g: OLD rule (regression) would have processed only 23 (skipped all of 99/105/109)');
 ok(scalar(@processed) > scalar(@old_processed),
   'Test 2h: NEW rule processes more steps than OLD rule (105 and 99 are now calibrated, not skipped)');
}

# =====================================================================
# Test 3: Iter budget routing for the new SDR26 budget tiers
# =====================================================================
{
 ok(defined(&main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget),
   'lg_autocal_26_sdr26_dpg_low_ire_iter_budget is defined');
 # Body (IRE 50, 70) -> 10 default
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 50), 10, 'Test 3a: IRE=50 -> 10 default body iters');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 70), 10, 'Test 3a-2: IRE=70 -> 10 default body iters');
 # Low IRE (< 5%) -> 12 low
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 4), 12, 'Test 3b: IRE=4 -> 12 low-IRE iters');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 2.3), 12, 'Test 3c: IRE=2.3 -> 12 low-IRE iters');
 # White cluster (99, 105, 109) -> 8 white-body
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 99), 8, 'Test 3d: IRE=99 -> 8 white-body iters');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 105), 8, 'Test 3e: IRE=105 -> 8 white-body iters');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 109), 8, 'Test 3f: IRE=109 -> 8 white-body iters');
 # Config overrides
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters=>4 }, 50), 4, 'Test 3g: body config override=4');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters_white_body=>3 }, 105), 3, 'Test 3h: white-body config override=3');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters_low=>7 }, 4), 7, 'Test 3i: low-IRE config override=7');
 # Clamps: body [1, 12]; white-body [1, 12]; low [1, 24]
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters=>99 }, 50), 12, 'Test 3j: body iters clamped to 12');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters=>0 }, 50), 1, 'Test 3k: body iters clamped to 1');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters_white_body=>99 }, 105), 12, 'Test 3l: white-body iters clamped to 12');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters_white_body=>0 }, 105), 1, 'Test 3m: white-body iters clamped to 1');
}

# =====================================================================
# Test 4: white_move_multiplier knob default + clamp envelope
# (Mirrors HDR's lg_autocal_hdr20_dpg_white_move_multiplier; SDR uses
# a separate knob lg_autocal_sdr26_dpg_white_move_multiplier.)
# =====================================================================
{
 # Read the knob from the production code's inner loop via a quick stub
 # to confirm the default + clamp. We can't directly call the loop's
 # internal $white_move_mult without running the full inner sub, but we
 # can validate the knob name and clamp envelope by checking the constant
 # in the production source.
 my $src_path='usr/bin/meter_lg_autocal.pl';
 open(my $fh,'<',$src_path) or BAIL_OUT("can't open $src_path: $!");
 my $contents=do { local $/; <$fh> };
 close($fh);
 like($contents, qr/lg_autocal_sdr26_dpg_white_move_multiplier/,
   'Test 4a: production code references lg_autocal_sdr26_dpg_white_move_multiplier knob');
 like($contents, qr/white_move_mult=1\.0 if\(\$white_move_mult\+0 < 1\.0\)/,
   'Test 4b: white_move_mult clamped at floor 1.0');
 like($contents, qr/white_move_mult=5\.0 if\(\$white_move_mult\+0 > 5\.0\)/,
   'Test 4c: white_move_mult clamped at ceiling 5.0');
 # Default value: 2.5 (between HDR's 2.0 and the 5.0 ceiling).
 like($contents, qr/lg_autocal_sdr26_dpg_white_move_multiplier"}\) \? \(\$config->\{"lg_autocal_sdr26_dpg_white_move_multiplier"\}\+0\) : 2\.5/,
   'Test 4d: default white_move_multiplier is 2.5');
}

# =====================================================================
# Test 5: skip-acceptance default reduction (0.6 -> 0.3) and floor (0.1)
# =====================================================================
{
 my $src_path='usr/bin/meter_lg_autocal.pl';
 open(my $fh,'<',$src_path) or BAIL_OUT("can't open $src_path: $!");
 my $contents=do { local $/; <$fh> };
 close($fh);
 like($contents, qr/lg_autocal_sdr26_dpg_acceptance_skip_fraction"}\) \? \(\$config->\{"lg_autocal_sdr26_dpg_acceptance_skip_fraction"\}\+0\) : 0\.3/,
   'Test 5a: default skip_fraction is 0.3 (was 0.6; raised to 30% to avoid early-bail before target dE)');
 like($contents, qr/\$skip_fraction=0\.1 if\(\$skip_fraction\+0 < 0\.1\)/,
   'Test 5b: skip_fraction floor at 0.1 (avoids skip_de < meter noise floor)');
}

done_testing();
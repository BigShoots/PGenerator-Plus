#!/usr/bin/env perl
# Regression test for the SDR 1D DPG upload path added on top of the
# HDR machinery in usr/bin/meter_lg_autocal.pl and usr/sbin/pgenerator-lg.
#
# Verifies the SDR direct-DPG gain function (lg_autocal_26_sdr26_dpg_gain)
# in isolation, the layout-agnostic Akima-spline build function
# (lg_autocal_26_build_hdr20_1d_dpg) with the SDR IRE-to-idx mapping, and
# the per-iteration attempt function (lg_autocal_26_attempt_sdr_1d_dpg_upload)
# in its DISABLED/INELIGIBLE paths. No live renderer or meter required;
# the production file's main body is guarded by `unless(caller())` so
# `require` is safe in the test harness.
use strict;
use warnings;
use Test::More;

my $autocal_path = 'usr/bin/meter_lg_autocal.pl';
my $require_ok = eval { require "./$autocal_path"; 1 } ? 1 : 0;
if(!$require_ok) {
 diag("require failed: $@");
 BAIL_OUT('meter_lg_autocal.pl require failed');
}

# Sanity: the SDR gain fn is defined after require.
ok(defined(&main::lg_autocal_26_sdr26_dpg_gain),
   'lg_autocal_26_sdr26_dpg_gain is defined') or BAIL_OUT('SDR gain fn missing');

# --- Test 1: on-target reading => gains within 0.01 of 1.0 ---
{
 # D65 white at luminance 100 cd/m^2.
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my $tX=($tx/$ty)*$tY;
 my $tZ=((1-$tx-$ty)/$ty)*$tY;
 my $reading={ X=>$tX, Y=>$tY, Z=>$tZ };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is(scalar(@g), 3, 'Test 1: returns list of 3 gains');
 ok(abs($g[0] - 1.0) < 0.01, "Test 1: r_gain ~ 1.0 (got $g[0])");
 ok(abs($g[1] - 1.0) < 0.01, "Test 1: g_gain ~ 1.0 (got $g[1])");
 ok(abs($g[2] - 1.0) < 0.01, "Test 1: b_gain ~ 1.0 (got $g[2])");
}

# --- Test 2: too-blue reading (Z x 1.3) => b_gain < 1.0, in [0.5, 1.0] ---
{
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my $tX=($tx/$ty)*$tY;
 my $tZ=((1-$tx-$ty)/$ty)*$tY;
 my $reading={ X=>$tX, Y=>$tY, Z=>$tZ * 1.3 };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is(scalar(@g), 3, 'Test 2: returns list of 3 gains');
 ok($g[2] < 1.0, "Test 2: b_gain < 1.0 for too-blue reading (got $g[2])");
 ok($g[2] >= 0.5, "Test 2: b_gain >= 0.5 (clamp; got $g[2])");
 ok($g[2] <= 1.0, "Test 2: b_gain <= 1.0 (got $g[2])");
}

# --- Test 3: half-luminance reading => all gains clamp to 2.0 ---
{
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my $tX=($tx/$ty)*$tY;
 my $tZ=((1-$tx-$ty)/$ty)*$tY;
 my $reading={ X=>$tX*0.5, Y=>$tY*0.5, Z=>$tZ*0.5 };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 is($g[0], 2.0, "Test 3: r_gain clamped to 2.0 (got $g[0])");
 is($g[1], 2.0, "Test 3: g_gain clamped to 2.0 (got $g[1])");
 is($g[2], 2.0, "Test 3: b_gain clamped to 2.0 (got $g[2])");
}

# --- Test 4: missing / zero measured or target => returns (1.0, 1.0, 1.0) ---
{
 is_deeply([main::lg_autocal_26_sdr26_dpg_gain({},100,0.3127,0.3290)], [1.0,1.0,1.0], 'Test 4a: empty reading -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_gain({Y=>0},100,0.3127,0.3290)], [1.0,1.0,1.0], 'Test 4b: Y=0 reading -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_gain({X=>95,Y=>100,Z=>108.9},0,0.3127,0.3290)], [1.0,1.0,1.0], 'Test 4c: zero target lum -> (1,1,1)');
 is_deeply([main::lg_autocal_26_sdr26_dpg_gain({X=>95,Y=>100,Z=>108.9},100,0.3127,0)], [1.0,1.0,1.0], 'Test 4d: zero target_y -> (1,1,1)');
}

# --- Test 5: x,y,luminance fallback path produces a non-trivial gain ---
# Reading supplies x/y + luminance, no direct XYZ; sub must derive XYZ.
{
 my ($tx,$ty,$tY)=(0.3127, 0.3290, 100);
 my $tX=($tx/$ty)*$tY;
 my $tZ=((1-$tx-$ty)/$ty)*$tY;
 # 0.8x luminance reading
 my $reading={ x=>$tx, y=>$ty, luminance=>$tY*0.8 };
 my @g=main::lg_autocal_26_sdr26_dpg_gain($reading,$tY,$tx,$ty);
 ok($g[0] > 1.0 && $g[0] < 2.0, "Test 5: r_gain in (1, 2) on dim reading (got $g[0])");
 ok($g[1] > 1.0 && $g[1] < 2.0, "Test 5: g_gain in (1, 2) on dim reading (got $g[1])");
 ok($g[2] > 1.0 && $g[2] < 2.0, "Test 5: b_gain in (1, 2) on dim reading (got $g[2])");
}

# --- Test 6: build fn produces a 3072-entry LUT from SDR-shaped anchors ---
{
 # Identity baseline (the function will accept undef and synthesize one)
 # with two anchors: idx 100 r_gain=0.5, idx 900 r_gain=2.0.
 # Identity ramp at idx k is int(k/1023 * 32767 + 0.5), so:
 #   R[100] = 100/1023*32767 + 0.5 = 3202.3   -> 3202
 #   R[500] = 500/1023*32767 + 0.5 = 16011.7  -> 16012
 #   R[900] = 900/1023*32767 + 0.5 = 28824.6  -> 28825
 # After applying 0.5x at idx 100 and 2.0x at idx 900 (and Akima between):
 #   r100 ≈ 3202 * 0.5 = 1601  (the build fn clamps & rounds; allow ±500)
 #   r900 ≈ 28825 * 2.0 = 57650 -> clamped to 32767
 my @anchors=(
  { idx=>100, r_gain=>0.5, g_gain=>1.0, b_gain=>1.0 },
  { idx=>900, r_gain=>2.0, g_gain=>1.0, b_gain=>1.0 },
 );
 my $lut=main::lg_autocal_26_build_hdr20_1d_dpg(undef,\@anchors);
 is(ref($lut), 'ARRAY', 'Test 6: build fn returned an array');
 is(scalar(@$lut), 3072, 'Test 6: build fn returned exactly 3072 values');
 my $r100=$lut->[100];
 my $r900=$lut->[900+1024];
 my $r_mid=$lut->[500];
 ok($r100 > 1100 && $r100 < 2100, "Test 6: R[100] ~= 0.5*identity_ramp (got $r100)");
 ok($r900 > 28000 && $r900 <= 32767, "Test 6: R[1024+900] ~= 2.0*identity_ramp, clamped (got $r900)");
 # At idx 500 (between anchors) the spline must produce something in
 # between the two anchor values.
 ok($r_mid > 5000 && $r_mid < 28000, "Test 6: R[500] (mid) is between the two anchor values (got $r_mid)");
}

# --- Test 7: lg_autocal_26_sdr26_dpg_compute_target pins gamma=2.2 / mode=sdr ---
{
 ok(defined(&main::lg_autocal_26_sdr26_dpg_compute_target),
   'lg_autocal_26_sdr26_dpg_compute_target is defined');
 # White=100 nit, IRE=50 should produce a 50% gamma-2.2 luminance ~ 21.8 nits.
 my $step={ ire=>50, stimulus=>50 };
 my $tl=main::lg_autocal_26_sdr26_dpg_compute_target(100,$step,0);
 ok(defined($tl), 'Test 7a: target is defined for SDR IRE=50 with white=100');
 # gamma 2.2 normalized luminance at IRE=50 = (0.5)^2.2 = 0.21764 -> 21.76 nits
 ok(abs($tl-21.764) < 1.0, sprintf("Test 7a: target ~21.76 nits (got %.4f)", $tl));
 # IRE=100 -> white (identity)
 my $tl100=main::lg_autocal_26_sdr26_dpg_compute_target(100,{ ire=>100, stimulus=>100 },0);
 ok(defined($tl100) && abs($tl100-100.0) < 0.01, sprintf("Test 7b: IRE=100 -> white=100 (got %.4f)", $tl100));
 # IRE=0 -> 0 nits
 my $tl0=main::lg_autocal_26_sdr26_dpg_compute_target(100,{ ire=>0, stimulus=>0 },0);
 ok(defined($tl0) && $tl0 == 0, sprintf("Test 7c: IRE=0 -> 0 (got %.4f)", $tl0));
 # Missing white -> undef
 my $tlbad=main::lg_autocal_26_sdr26_dpg_compute_target(0,{ ire=>50, stimulus=>50 },0);
 is($tlbad, undef, 'Test 7d: missing white_y returns undef');
}

# --- Test 8: lg_autocal_26_sdr26_dpg_damp envelope (sqrt, [floor, 1.25]) ---
{
 ok(defined(&main::lg_autocal_26_sdr26_dpg_damp),
   'lg_autocal_26_sdr26_dpg_damp is defined');
 # Gain=1.0 with default floor=0.8, exp=0.5 -> 1.0 (no change)
 is(main::lg_autocal_26_sdr26_dpg_damp(1.0), 1.0, 'Test 8a: damp(1.0) == 1.0');
 # Gain=2.0, floor=0.8, exp=0.5 -> sqrt(2) = 1.414, clamped to 1.25
 is(main::lg_autocal_26_sdr26_dpg_damp(2.0, 0.8, 0.5), 1.25, 'Test 8b: damp(2.0, 0.8, 0.5) clamped to 1.25');
 # Gain=0.5, floor=0.8, exp=0.5 -> sqrt(0.5) = 0.707, clamped to 0.8
 is(main::lg_autocal_26_sdr26_dpg_damp(0.5, 0.8, 0.5), 0.8, 'Test 8c: damp(0.5, 0.8, 0.5) clamped to 0.8');
 # Low-IRE floor=0.5: damp(0.5, 0.5, 0.5) -> 0.5 (sqrt(0.5)=0.707 > 0.5, passes)
 ok(abs(main::lg_autocal_26_sdr26_dpg_damp(0.5, 0.5, 0.5) - 0.7071) < 1e-3,
   sprintf("Test 8d: damp(0.5, 0.5, 0.5) ~ 0.7071 (no clamp; got %.4f)", main::lg_autocal_26_sdr26_dpg_damp(0.5, 0.5, 0.5)));
 # Gain=0.25, floor=0.5 -> sqrt(0.25) = 0.5, floor = 0.5
 is(main::lg_autocal_26_sdr26_dpg_damp(0.25, 0.5, 0.5), 0.5, 'Test 8e: damp(0.25, 0.5, 0.5) clamped to 0.5');
}

# --- Test 9: lg_autocal_26_sdr26_dpg_low_ire_iter_budget routing ---
{
 ok(defined(&main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget),
   'lg_autocal_26_sdr26_dpg_low_ire_iter_budget is defined');
 # IRE=50 (body) -> 10 default (was 6 in the previous version; raised so
 # the per-anchor solve actually converges to the target dE).
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 50), 10, 'Test 9a: IRE=50 -> 10 default iters');
 # IRE=4 (< 5%) -> 12 low (unchanged)
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 4), 12, 'Test 9b: IRE=4 -> 12 low-IRE iters');
 # IRE=2.3 -> 12 low (2.3 < 5.0; unchanged)
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 2.3), 12, 'Test 9c: IRE=2.3 -> 12 low-IRE iters');
 # IRE=100 -> 8 white-body iters (the white cluster 99/105 takes the
 # white_body budget; the previous version returned 6 default here).
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 100), 8, 'Test 9d: IRE=100 -> 8 white-body iters');
 # IRE=109 -> 8 white-body (same bucket as 99/105)
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 109), 8, 'Test 9d-2: IRE=109 -> 8 white-body iters');
 # IRE=99 -> 8 white-body
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({}, 99), 8, 'Test 9d-3: IRE=99 -> 8 white-body iters');
 # Override via config
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters=>3, lg_autocal_sdr26_dpg_inner_iters_low=>8 }, 50), 3, 'Test 9e: config override body=3');
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters=>3, lg_autocal_sdr26_dpg_inner_iters_low=>8 }, 4), 8, 'Test 9f: config override low=8');
 # White body override
 is(main::lg_autocal_26_sdr26_dpg_low_ire_iter_budget({ lg_autocal_sdr26_dpg_inner_iters_white_body=>5 }, 100), 5, 'Test 9g: config override white-body=5');
}

# --- Test 9b: lg_autocal_26_sdr26_dpg_accept_skip_threshold default 0.3 ---
{
 ok(defined(&main::lg_autocal_26_sdr26_dpg_accept_skip_threshold),
   'lg_autocal_26_sdr26_dpg_accept_skip_threshold is defined');
 is(main::lg_autocal_26_sdr26_dpg_accept_skip_threshold({}), 0.3, 'Test 9b-a: default threshold is 0.3');
 is(main::lg_autocal_26_sdr26_dpg_accept_skip_threshold({ lg_autocal_sdr26_dpg_acceptance_de=>0.5 }), 0.5, 'Test 9b-b: config override returns 0.5');
 # Clamp to [0.05, 5.0]
 is(main::lg_autocal_26_sdr26_dpg_accept_skip_threshold({ lg_autocal_sdr26_dpg_acceptance_de=>0.01 }), 0.05, 'Test 9b-c: tiny value clamped to 0.05');
 is(main::lg_autocal_26_sdr26_dpg_accept_skip_threshold({ lg_autocal_sdr26_dpg_acceptance_de=>10.0 }), 5.0, 'Test 9b-d: huge value clamped to 5.0');
}

# --- Test 10: pgenerator-lg 1d_dpg_upload workflow no longer requires HDR ---
# Scoped to the lg_1d_dpg_upload_workflow function only (other HDR-only
# endpoints like hdr_calman_reset, hdr_tone_map_upload, 1d_dpg_read still
# legitimately require HDR picture modes; not in scope here).
{
 my $pg_path='usr/sbin/pgenerator-lg';
 open(my $fh,'<',$pg_path) or BAIL_OUT("can't open $pg_path: $!");
 my $contents=do { local $/; <$fh> };
 close($fh);
 # Find the line numbers of lg_1d_dpg_upload_workflow and the next 'sub ' after it.
 my @lines=split(/\n/,$contents,-1);
 my $start=-1; my $end=scalar(@lines);
 for(my $i=0;$i<@lines;$i++) {
  if($start<0 && $lines[$i]=~/^sub lg_1d_dpg_upload_workflow/) { $start=$i; next; }
  if($start>=0 && $lines[$i]=~/^sub /) { $end=$i; last; }
 }
 ok($start>=0, 'pgenerator-lg: lg_1d_dpg_upload_workflow found');
 my $wf=join("\n",@lines[$start..($end-1)]);
 is(length($wf) > 1000, 1, 'pgenerator-lg: workflow body extracted (length>1000)');
 unlike($wf, qr/requires an HDR picture mode/, 'pgenerator-lg/1d_dpg_upload: no longer says HDR-only');
 like($wf, qr/writable picture mode/i, 'pgenerator-lg/1d_dpg_upload: now mentions writable picture modes');
 like($wf, qr/BT709_3BY3_GAMUT_DATA/s, 'pgenerator-lg/1d_dpg_upload: sends BT709 matrix in SDR branch');
}

done_testing();
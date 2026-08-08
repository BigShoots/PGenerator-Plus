use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use lib "$Bin/lib";
use PGenSource qw(repo_root slurp_source);
use PGAutoCalSafety qw(
 profile_reading_plausibility_error
 profile_primary_monotonicity_error
 critical_shadow_needs_revisit
 autocal_solver_target_delta_e
 autocal_white_residual_stop_allowed
 autocal_restored_acceptance_needs_retry
);

my $blue90_step={kind=>'node',level=>90,signal_r_pct=>0,signal_g_pct=>0,signal_b_pct=>90};
my $blue100_step={kind=>'blue',level=>100,signal_r_pct=>0,signal_g_pct=>0,signal_b_pct=>100};
my $blue90={X=>98.516228,Y=>29.080523,Z=>538.163308};
my $blue100_good={X=>126.439449,Y=>37.272399,Z=>691.188413};
my $blue100_bad={X=>0,Y=>0,Z=>0};

like(
 profile_reading_plausibility_error($blue100_step,$blue100_bad),
 qr/non-black patch returned black XYZ/,
 'exact-zero blue endpoint is rejected'
);
is(
 profile_reading_plausibility_error($blue100_step,$blue100_good),
 undef,
 'valid blue endpoint passes the absolute plausibility gate'
);
is(
 profile_reading_plausibility_error({kind=>'black',level=>0,signal_r_pct=>0,signal_g_pct=>0,signal_b_pct=>0},$blue100_bad),
 undef,
 'a genuine black patch may read XYZ zero'
);
is(
 profile_primary_monotonicity_error($blue100_step,$blue100_good,[{step=>$blue90_step,reading=>$blue90}]),
 undef,
 'a monotonic 90-to-100 blue ramp passes'
);
like(
 profile_primary_monotonicity_error($blue100_step,{X=>20,Y=>5,Z=>100},[{step=>$blue90_step,reading=>$blue90}]),
 qr/blue ramp collapsed/,
 'a non-zero but collapsed blue endpoint is rejected'
);

ok(
 critical_shadow_needs_revisit({ire=>2.3},0),
 'an unconverged 2.3% shadow anchor is queued for revisit'
);
ok(
 !critical_shadow_needs_revisit({ire=>2.3},1),
 'a converged 2.3% shadow anchor is not revisited'
);
ok(
 !critical_shadow_needs_revisit({ire=>2.0},0),
 'other dark-detail samples do not trigger the critical 2.3% revisit'
);

is(
 autocal_solver_target_delta_e({target_delta_e=>0.2},'lg_autocal_sdr26_dpg_target_de',0.5),
 0.2,
 'the SDR DPG solver inherits the operator-selected dE target'
);
is(
 autocal_solver_target_delta_e({target_delta_e=>0.2,lg_autocal_sdr26_dpg_target_de=>0.35},'lg_autocal_sdr26_dpg_target_de',0.5),
 0.35,
 'an explicit solver-specific target overrides the operator target'
);
is(
 autocal_solver_target_delta_e({target_delta_e=>10},'lg_autocal_hdr20_dpg_target_de',0.5),
 10,
 'the full WebUI target range reaches the specialised solver unchanged'
);
is(
 autocal_solver_target_delta_e({target_delta_e=>'invalid'},'lg_autocal_hdr20_dpg_target_de',0.5),
 0.5,
 'an invalid target falls back safely'
);

ok(
 !autocal_white_residual_stop_allowed(1,0,0.0038,0.218,0.2),
 'a small white residual cannot stop an above-target solve on its first attempt'
);
ok(
 !autocal_white_residual_stop_allowed(3,1,0.0038,0.218,0.2),
 'one revert is not enough to abandon an above-target white solve early'
);
ok(
 autocal_white_residual_stop_allowed(4,0,0.0038,0.218,0.2),
 'the residual shortcut is available after four genuine attempts'
);
ok(
 autocal_white_residual_stop_allowed(3,2,0.0038,0.218,0.2),
 'two reverts permit the bounded residual give-up path'
);
ok(
 !autocal_white_residual_stop_allowed(4,2,0.0038,0.19,0.2),
 'the residual shortcut is irrelevant once white has reached the target'
);

ok(
 autocal_restored_acceptance_needs_retry(1,0.2504,0.2),
 'a successful restoration reread above target must continue solving'
);
ok(
 !autocal_restored_acceptance_needs_retry(1,0.1789,0.2),
 'a successful restoration reread below target may finish the anchor'
);
ok(
 !autocal_restored_acceptance_needs_retry(0,0.2504,0.2),
 'a failed restoration reread does not drive a move from an unverified reading'
);

my $root=repo_root($Bin);
my $grey_source=slurp_source($root,'usr/bin/meter_lg_autocal.pl');
like(
 $grey_source,
 qr/Auto Cal complete with warning/,
 'an unresolved critical-shadow revisit is visible in the terminal state'
);
my $sdr_target_uses=()=$grey_source=~/autocal_solver_target_delta_e\(\$config,"lg_autocal_sdr26_dpg_target_de",0\.5\)/g;
is($sdr_target_uses,2,'both SDR DPG layers use the operator-aware target resolver');
my $hdr_target_uses=()=$grey_source=~/autocal_solver_target_delta_e\(\$config,"lg_autocal_hdr20_dpg_target_de",0\.5\)/g;
is($hdr_target_uses,1,'the HDR and Dolby Vision DPG worker uses the operator-aware target resolver');
like(
 $grey_source,
 qr/HDR20 1D DPG greyscale: active target dE=/,
 'the HDR and Dolby Vision worker logs its resolved target for live verification'
);
unlike(
 $grey_source,
 qr/lg_autocal_(?:hdr20|sdr26)_dpg_target_de_(?:low|very_low)_multiplier"\}\) \? \([^\n]+\) : (?:1\.5|2\.0)/,
 'low-IRE DPG thresholds do not relax the requested target by default'
);
unlike(
 $grey_source,
 qr/lg_autocal_(?:hdr20|sdr26)_dpg_low_ire_close_factor"\}\) \? \([^\n]+\) : 1\.5/,
 'the low-IRE near-target shortcut cannot stop above target by default'
);
unlike(
 $grey_source,
 qr/(?:hdr20|sdr)_1d_dpg_white_converged"\}=\(\$conv \|\| \$white_usable\)/,
 'a usable white is not falsely labelled as converged'
);
like(
 $grey_source,
 qr/remained above the requested dE target/,
 'an exhausted exact-target solve is surfaced as a warning'
);
my $restored_retry_uses=()=$grey_source=~/autocal_restored_acceptance_needs_retry\(/g;
is($restored_retry_uses,2,'both HDR and SDR refinement restores recheck the active target');
like(
 $grey_source,
 qr/restoration verify dE=.*still above target.*continuing solve/,
 'an above-target restoration is explicit in the live log'
);
my $colour_source=slurp_source($root,'usr/bin/meter_lg_3d_autocal.pl');
like(
 $colour_source,
 qr/read_validated_profile_step\(\$config,\$step,\$state,\\\@profile_readings\)/,
 'the 3D profile loop uses the validated measurement path'
);
like(
 $colour_source,
 qr/postcal_shadow_final_recommit_verified/,
 'a successful final shadow re-commit clears the stale re-establish failure state'
);

my $webui_source=slurp_source($root,'usr/share/PGenerator/webui.pm');
my $hdr_target_posts=()=$webui_source=~/lg_autocal_hdr20_dpg_target_de:target/g;
my $sdr_target_posts=()=$webui_source=~/lg_autocal_sdr26_dpg_target_de:target/g;
is($hdr_target_posts,3,'every WebUI greyscale start path posts the HDR/DV worker target explicitly');
is($sdr_target_posts,3,'every WebUI greyscale start path posts the SDR worker target explicitly');

done_testing();

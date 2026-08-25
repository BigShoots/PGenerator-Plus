use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $worker="$Bin/../usr/bin/meter_lg_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&autocal_dpg_terminal_error));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

is(autocal_committed_max(0,0.42),0.42,'the first final anchor seeds the committed maximum');
is(autocal_committed_max(0.42,0.18),0.42,'a better later anchor does not lower the committed maximum');
is(autocal_committed_max(0.42,0.67),0.67,'a worse final anchor raises the committed maximum');
is(autocal_committed_max(0.42,undef),0.42,'a missing final measurement is never invented');

autocal_set_target_overrides(undef,undef);
my $low_light_config={
 low_light=>{enabled=>1,mode=>'aa',trigger=>5},
 target_gamma=>'2.2',signal_mode=>'sdr',target_luminance=>100,
};
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>4.999}),'aa',
 '1D uses the selected mode strictly below the target-Y trigger');
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>5}),'off',
 '1D uses off exactly at the target-Y trigger');
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>'invalid'}),'off',
 '1D fails safe to off for invalid target Y');
is(autocal_low_light_mode_for_step({%{$low_light_config},low_light=>{enabled=>1,mode=>'aaa',trigger=>5}},{target_Y=>1}),'aaa',
 '1D never replaces the selected averaging mode');
{
 local $main::LG_AUTOCAL_STATE={calibrated_white_luminance=>100};
 my $step={ire=>10,stimulus=>10};
 my $expected=target_luminance_for_autocal_step(100,$step,'2.2','sdr',0);
 my $resolved=autocal_expected_target_y_for_low_light($low_light_config,$step);
 cmp_ok(abs($resolved-$expected),'<',0.0000001,
  '1D low-light selection reuses the AutoCal target-luminance helper');
}

is(autocal_dpg_terminal_error('HDR20 1D DPG',1,1,'restore_upload_failed'),
 'HDR20 1D DPG upload failed: restore_upload_failed',
 'a failed final-state restore fails the greyscale stage');
like(autocal_dpg_terminal_error('SDR26 1D DPG',0,0,''),qr/white reference did not converge/,
 'non-converged white fails instead of reporting a committed curve');
ok(!defined(autocal_dpg_terminal_error('HDR20 1D DPG',0,1,'')),
 'a verified upload with converged white remains successful');

{
 no warnings qw(redefine once);
 local *main::api_json=sub (@) { return {tv_power=>'standby'}; };
 like(verify_lg_tv_power_for_autocal(undef),qr/powered off/i,
  'a definite CEC standby state still blocks AutoCal');
}
{
 no warnings qw(redefine once);
 local *main::api_json=sub (@) { return {tv_power=>'powering-on'}; };
 ok(!defined(verify_lg_tv_power_for_autocal(undef)),
  'a stale CEC powering-on state does not block an otherwise reachable TV');
}
{
 no warnings qw(redefine once);
 local *main::api_json=sub (@) { return {tv_power=>'unknown'}; };
 ok(!defined(verify_lg_tv_power_for_autocal(undef)),
  'an unavailable CEC power reading fails open to the authenticated LG preflight');
}

{
 my $api_calls=0;
 no warnings qw(redefine once);
 local $main::LG_AUTOCAL_STATE={
  calibration_end_retry_forbidden=>JSON::PP::true(),
  calibration_recovery_message=>'accepted write close is unconfirmed',
 };
 local *main::api_json=sub (@) { $api_calls++; return {status=>'ok'}; };
 my $result=end_calibration_mode('hdrFilmMaker');
 is($api_calls,0,'the 1D worker never sends foreign-socket CAL_END after an accepted write has an unconfirmed close');
 is($result->{error_code},'lg-calibration-end-unconfirmed','the central close guard returns the stable error code');
 ok($result->{calibration_mode},'the central close guard retains held state');
 set_state_calibration_mode($main::LG_AUTOCAL_STATE,0,'');
 ok($main::LG_AUTOCAL_STATE->{calibration_mode},'later cleanup code cannot clear the held flag after the guarded close');
}

my ($source,$session_source);
{
 local $/;
 open(my $fh,'<',$worker) or die "Unable to read $worker: $!";
 $source=<$fh>;
 close($fh);
 my $session="$Bin/../usr/bin/meter_session.sh";
 open(my $sfh,'<',$session) or die "Unable to read $session: $!";
 $session_source=<$sfh>;
 close($sfh);
}

my $terminal_uses=()=$source=~/autocal_dpg_terminal_error\(/g;
is($terminal_uses,2,'both DPG paths apply the shared terminal gate');
like($source,qr/return "HDR20 1D DPG identity baseline upload failed:/,
 'HDR identity baseline failure is terminal');
like($source,qr/return "SDR26 1D DPG identity baseline upload failed:/,
 'SDR identity baseline failure is terminal');
like($source,qr/low_light_session"\}=\{ mode => "off", enabled => JSON::PP::false \}/,
 'the 1D worker keeps session-level averaging at off');
like($source,qr/my \$active_low_light=autocal_low_light_mode_for_step\(\$config,\$step\)[\s\S]{0,180}?\$payload->\{"low_light"\}/,
 'the 1D worker sends an explicit effective mode for every read');
like($source,qr/my \@layout_slots=ddc_slots_for_layout\([^\n]+\);/,
 'the Dark Detail log counts the slot list rather than its final value');
like($session_source,qr/CMD_LOW_LIGHT_MODE="\$CURRENT_LOW_LIGHT_MODE"/,
 'the meter wrapper preserves its child mode only for legacy omitted overrides');
like($session_source,qr/release the USB interface[\s\S]{0,300}?sleep 1/,
 'meter respawn allows the USB interface to settle before reopening');
like($source,qr/sub lg_calibration_end_retry_forbidden[\s\S]+?calibration_end_retry_forbidden/,
 'the 1D worker records a foreign-close prohibition');
like($source,qr/if\(lg_calibration_end_retry_forbidden\(\$state\)\)[\s\S]{0,300}?\$cal_end_unconfirmed=1[\s\S]{0,500}?if\(!\$cal_end_unconfirmed[\s\S]{0,300}?end_calibration_mode/s,
 'the 1D finaliser does not send fallback CAL_END after an accepted write has an unconfirmed close');

my $autocal_webui="$Bin/../usr/share/PGenerator/webui.pm";
open(my $wfh,'<',$autocal_webui) or die "Unable to read $autocal_webui: $!";
local $/;
my $autocal_webui_source=<$wfh>;
close($wfh);
unlike($autocal_webui_source,qr/if\(\$power eq "powering-on"\)\s*\{\s*return '\{"status":"error","message":"LG TV is still starting/s,
 'the server does not fail closed on a stale CEC powering-on state');
unlike($autocal_webui_source,qr/if\(power==='powering-on'\)\s*\{[\s\S]{0,220}?return false/,
 'the browser does not fail closed on a stale CEC powering-on state');

my $worker3d="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
my $loaded3d;
{
 package LowLight3DWorker;
 local @ARGV=();
 $loaded3d=do $worker3d;
}
die $@ if($@);
die "Failed to load $worker3d" if(!defined($loaded3d));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my $low_light_3d_config={
 low_light=>{enabled=>1,mode=>'a',trigger=>2},
 target_gamma=>'2.2',target_gamut=>'bt709',
 target_white_use_measured=>0,target_white_luminance=>100,
 target_black_use_measured=>0,target_black_luminance=>0,
};
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>1.999}),'a',
 '3D uses the selected mode strictly below the target-Y trigger');
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>2}),'off',
 '3D uses off exactly at the target-Y trigger');
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>undef}),'off',
 '3D fails safe to off for invalid target Y');
my $profile_step={kind=>'node',level=>10,signal_r_pct=>10,signal_g_pct=>10,signal_b_pct=>10};
my $profile_target=LowLight3DWorker::profile_target_xyz_for_step($profile_step,$low_light_3d_config,100,0);
my $profile_expected=LowLight3DWorker::autocal3d_expected_target_y_for_low_light($low_light_3d_config,$profile_step);
cmp_ok(abs($profile_expected-$profile_target->[1]),'<',0.0000001,
 '3D low-light selection reuses the profile target helper');

open(my $w3,'<',$worker3d) or die "Unable to read $worker3d: $!";
local $/;
my $source3d=<$w3>;
close($w3);
like($source3d,qr/low_light_session"\}=\{ mode => "off", enabled => json_false\(\) \}/,
 'the 3D worker keeps session-level averaging at off');
like($source3d,qr/autocal3d_low_light_mode_for_step\(\$config,\$step\)[\s\S]{0,180}?\$payload->\{"low_light"\}/,
 'the 3D worker sends an explicit effective mode for every read');
unlike($source3d,qr/very_low_ire_threshold|sub low_light_mode_for_reading/,
 'the 3D worker has no IRE-band or forced-aaa override');
like($source3d,qr/calibration_end_retry_forbidden/,'the 3D worker records a foreign-close prohibition');
like($source3d,qr/if\(\$upload_requested[^\n]+!lg_calibration_end_retry_forbidden\(\$state\)\)[\s\S]{0,200}?\/api\/lg\/calibration-mode/s,
 'the 3D terminal cleanup endpoint is gated off after an accepted write with unconfirmed CAL_END');
like($source3d,qr/tone_map_upload_status"\}="error"[\s\S]{0,300}?lg-tone-map-peak-missing/s,
 'the 3D worker marks a missing tone-map peak as an error instead of skipped');

my ($webui_source,$series_source);
{
 local $/;
 my $webui="$Bin/../usr/share/PGenerator/webui.pm";
 open(my $wfh,'<',$webui) or die "Unable to read $webui: $!";
 $webui_source=<$wfh>;
 close($wfh);
 for my $fragment (qw(webui-app.js webui-workspace.js)) {
  my $path="$Bin/../usr/share/PGenerator/$fragment";
  open(my $ffh,'<',$path) or die "Unable to read $path: $!";
  local $/;
  $webui_source.="\n".<$ffh>;
  close($ffh);
 }
 my $series="$Bin/../usr/bin/meter_series.sh";
 open(my $ssh,'<',$series) or die "Unable to read $series: $!";
 $series_source=<$ssh>;
 close($ssh);
}
like($webui_source,qr/function meterExpectedTargetYForReadStep[\s\S]{0,1600}?meterGreyChartTargetXYZForReading\(step\)[\s\S]{0,800}?meterTargetXYZForReading\(step\)/,
 'manual reads derive expected Y through the existing chart target helpers');
like($webui_source,qr/readPayload\.low_light=meterEffectiveLowLightReadState\(step\)/,
 'manual reads always carry an explicit effective low-light state');
like($webui_source,qr/my \$session_avg_mode="off"/,
 'the WebUI keeps session averaging at off');
like($webui_source,qr/my \$avg_enabled=.*?"enabled".*?true[\s\S]{0,300}?\$avg_mode="off" unless\(\$avg_enabled/s,
 'the WebUI fails a disabled or malformed per-read state to off');
like($webui_source,qr/my \$cmd_low_light_mode=\$avg_mode/,
 'the WebUI sends an explicit effective mode in every READ command');
like($series_source,qr/LOW_LIGHT_TRIGGER="\$\{38:-\}"/,
 'the series worker receives the trigger as its new positional argument');
like($series_source,qr/effective_low_light_mode_for_step\(\)/,
 'the series worker has a per-step expected-target selector');
like($series_source,qr/absolute_present = True[\s\S]{0,220}?print\("off"\)[\s\S]{0,120}?raise SystemExit\(0\)/,
 'the series worker fails invalid authoritative target metadata to off');
like($series_source,qr/SR_CMD_BASE="\$SR_CMD"[\s\S]{0,500}?CURRENT_LOW_LIGHT_MODE="off"/,
 'the series spotread child starts at explicit off with a stable base command');
like($series_source,qr/restart_spotread_session[\s\S]{0,1800}?sleep 1\.5/,
 'series mode changes retain the USB release wait in the child restart path');
unlike($series_source,qr/LOW_LIGHT_FLAGS|x_aaa/,
 'the series worker does not force a legacy or composite averaging mode');

done_testing();

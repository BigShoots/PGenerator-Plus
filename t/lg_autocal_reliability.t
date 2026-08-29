use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP;

sub embedded_python_worker {
 my ($source,$function)=@_;
 my ($worker)=$source=~/\Q$function\E\(\)\s*\{.*?<<'PY'[^\n]*\n(.*?)\nPY\n\}/s;
 return $worker;
}

sub run_python_worker {
 my ($worker,$environment)=@_;
 my ($fh,$path)=tempfile('pgen-meter-worker-XXXXXX',SUFFIX=>'.py',UNLINK=>1);
 print {$fh} $worker;
 close($fh);
 local %ENV=(%ENV,%{$environment || {}});
 open(my $out,'-|','python3',$path) or die "Unable to run $path: $!";
 local $/;
 my $output=<$out>;
 close($out);
 return (($? >> 8),defined($output)?$output:'');
}

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
 low_light_requested_sample_count=>3,
 target_gamma=>'2.2',signal_mode=>'sdr',target_luminance=>100,
};
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>4.999}),'aa',
 '1D repeats strictly below the target-Y trigger');
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>5}),'off',
 '1D keeps one sample exactly at the target-Y trigger');
is(autocal_low_light_mode_for_step($low_light_config,{target_Y=>'invalid'}),'off',
 '1D fails safe to one sample for invalid target Y');
is(autocal_requested_sample_count($low_light_config,'aa'),3,
 '1D executes the numeric application sample count');
{
 no warnings qw(redefine once);
 local $main::LG_AUTOCAL_CONFIG={signal_range=>1,pattern_signal_range=>1};
 my ($captured,$request_id,$result_gets)=(undef,undef,0);
 local *main::api_json=sub (@) {
  my ($method,$path,$payload)=@_;
  if($method eq 'POST' && $path eq '/api/meter/read') {
   $captured=$payload;
   $request_id=$payload->{request_id};
   return {status=>'measuring'};
  }
  if($method eq 'GET' && $path eq '/api/meter/read/result') {
   $result_gets++;
   return {status=>'error',message=>'Web UI API timed out during /api/meter/read/result'} if($result_gets==1);
   return {status=>'ok',request_id=>$request_id,readings=>[{
    request_id=>$request_id,timestamp=>time(),X=>0,Y=>0,Z=>0,x=>0,y=>0,luminance=>0,
   }]};
  }
  return {status=>'ok'};
 };
 my ($reading,$error)=read_step_once({
  low_light=>{enabled=>1,mode=>'a',trigger=>1},signal_mode=>'sdr',
  low_light_requested_sample_count=>2,
  display_type=>'oled_generic',target_gamma=>'2.2',target_gamut=>'bt709',target_luminance=>100,signal_range=>1,
 },{r=>16,g=>16,b=>16,ire=>0,stimulus=>0,name=>'0%'},1);
 ok(!defined($error) && ref($reading) eq 'HASH','the captured 1D black read completes');
 is($result_gets,2,'the 1D worker re-polls the same request after one result-poll transport timeout');
 is($captured->{low_light_session}{mode},'off','the 1D read never changes the Argyll process mode');
 is($captured->{low_light}{mode},'a','the 1D black read requests two physical application samples');
 is($captured->{low_light}{requested_sample_count},2,
  'the 1D request carries the numeric execution contract');
}

# The transport-retry budget is exactly one: a second consecutive poll failure
# must return the error (so the caller can retire the ambiguous session), and
# an interleaved successful-but-empty poll must reset the budget.
{
 no warnings qw(redefine once);
 local $main::LG_AUTOCAL_CONFIG={signal_range=>1,pattern_signal_range=>1};
 my $result_gets=0;
 local *main::api_json=sub (@) {
  my ($method,$path,$payload)=@_;
  return {status=>'measuring'} if($method eq 'POST' && $path eq '/api/meter/read');
  if($method eq 'GET' && $path eq '/api/meter/read/result') {
   $result_gets++;
   return {status=>'error',message=>'Web UI API timed out during /api/meter/read/result'};
  }
  return {status=>'ok'};
 };
 my ($reading,$error)=read_step_once({
  low_light=>{enabled=>0,mode=>'off',trigger=>1},signal_mode=>'sdr',
  display_type=>'oled_generic',target_gamma=>'2.2',target_gamut=>'bt709',target_luminance=>100,signal_range=>1,
 },{r=>128,g=>128,b=>128,ire=>50,stimulus=>50,name=>'50%'},1);
 ok(!defined($reading),'two consecutive poll transport failures do not produce a reading');
 like($error,qr/Web UI API timed out/,'the second consecutive transport failure is returned to the caller');
 is($result_gets,2,'the transport budget allows exactly one re-poll');
}
{
 no warnings qw(redefine once);
 local $main::LG_AUTOCAL_CONFIG={signal_range=>1,pattern_signal_range=>1};
 my ($request_id,$result_gets)=(undef,0);
 local *main::api_json=sub (@) {
  my ($method,$path,$payload)=@_;
  if($method eq 'POST' && $path eq '/api/meter/read') {
   $request_id=$payload->{request_id};
   return {status=>'measuring'};
  }
  if($method eq 'GET' && $path eq '/api/meter/read/result') {
   $result_gets++;
   return {status=>'error',message=>'Web UI API timed out during /api/meter/read/result'} if($result_gets==1 || $result_gets==3);
   return {status=>'measuring'} if($result_gets==2);
   return {status=>'ok',request_id=>$request_id,readings=>[{
    request_id=>$request_id,timestamp=>time(),X=>1,Y=>1,Z=>1,x=>0.33,y=>0.33,luminance=>1,
   }]};
  }
  return {status=>'ok'};
 };
 my ($reading,$error)=read_step_once({
  low_light=>{enabled=>0,mode=>'off',trigger=>1},signal_mode=>'sdr',
  display_type=>'oled_generic',target_gamma=>'2.2',target_gamut=>'bt709',target_luminance=>100,signal_range=>1,
 },{r=>128,g=>128,b=>128,ire=>50,stimulus=>50,name=>'50%'},1);
 ok(!defined($error) && ref($reading) eq 'HASH',
  'an interleaved good poll resets the transport budget so a later single failure survives');
 is($result_gets,4,'the read polls through failure, progress, failure, result');
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
like($source,qr/low_light_session"\}=\{ mode => "off", enabled => JSON::PP::false \}[\s\S]{0,180}?autocal_low_light_mode_for_step\(\$config,\$step\)[\s\S]{0,180}?\$payload->\{"low_light"\}/,
 'the 1D worker keeps Argyll normal and requests thresholded application samples');
like($source,qr/my \@layout_slots=ddc_slots_for_layout\([^\n]+\);/,
 'the Dark Detail log counts the slot list rather than its final value');
like($session_source,qr/CMD_REQUESTED_SAMPLE_COUNT[\s\S]{0,1200}?REQUESTED_SAMPLE_COUNT="\$CMD_REQUESTED_SAMPLE_COUNT"/,
 'the persistent session executes the numeric sample-count contract');
like($session_source,qr/capture_additional_average_sample[\s\S]{0,5000}?ADDITIONAL_PARSED/,
 'additional samples are captured from the existing spotread process');
unlike($session_source,qr/if \[\[ "\$CMD_LOW_LIGHT_MODE" != "\$CURRENT_LOW_LIGHT_MODE"/,
 'per-read sample-count changes never respawn spotread');
unlike($session_source,qr/new_ll_flags="-Y (?:a|aa|aaa)"/,
 'the session never passes unsupported Argyll averaging flags');
like($session_source,qr/READ_FAILURE_MESSAGE="Meter averaging sample[^\"]+meter session closed for clean retry"[\s\S]+?write_state[^\n]+READ_FAILURE_MESSAGE[^\n]*\n\s+if \(\( READ_SESSION_FATAL == 1 \)\)[\s\S]{0,200}?exit 1/s,
 'an incomplete averaging set publishes its error and retires the child before retry');
like($session_source,qr/spotread communication problem during read[\s\S]{0,300}?SCAN_OFFSET=\$\(output_size\)\s+printf " " >&3/s,
 'the main communication retry records its scan offset before sending the trigger');
like($session_source,qr/spotread communication problem during averaging sample[\s\S]{0,300}?scan_offset=\$\(output_size\)\s+printf " " >&3/s,
 'the averaging communication retry records its scan offset before sending the trigger');
like($session_source,qr/if \[\[ "\$READ_OUTPUT" == \*"Result is XYZ:"\*[\s\S]{0,3500}?RETRIED_COMM == 1[\s\S]{0,300}?to take a reading:[\s\S]{0,500}?READ_SESSION_FATAL=1/s,
 'a communication retry parses a result first, then retires a ready child that returned no XYZ');
like($session_source,qr/if \[\[ "\$CMD_CONTINUOUS" == "1" \]\][\s\S]{0,250}?READ_FAILURE_MESSAGE="Read timed out"[\s\S]{0,250}?READ_SESSION_FATAL=1/s,
 'a non-continuous timeout retires the child before another logical patch');
like($session_source,qr/release the USB interface[\s\S]{0,300}?sleep 1/,
 'meter respawn allows the USB interface to settle before reopening');
like($source,qr/my \$read_sample_count=autocal_requested_sample_count\(\$config,\$active_low_light\);[\s\S]{0,2000}?read_timeout_for_step\(\$step,\$payload->\{"read_timeout"\}\)\*\$read_sample_count\+\(\$read_sample_count > 1 \? 45 : 0\)/,
 'the 1D read deadline scales with the sample count plus the comm-retry grace');
{
 no warnings qw(redefine once);
 my $stops=0;
 local *main::api_json=sub (@) {
  my ($method,$path)=@_;
  $stops++ if($method eq 'POST' && $path eq '/api/meter/session/stop');
  return {status=>'ok'};
 };
 reset_meter_session_success();
 reset_meter_session_after_read_error('Meter communication retry returned no result; meter session closed for clean retry');
 is($stops,1,'the 1D worker uses session stop as a cleanup barrier on the first clean-retry error');
 $stops=0;
 reset_meter_session_success();
 reset_meter_session_after_read_error('spotread communication problem');
 is($stops,0,'the 1D worker still preserves the session for one ordinary transient error');
 reset_meter_session_success();
}
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
 low_light_requested_sample_count=>2,
 target_gamma=>'2.2',target_gamut=>'bt709',
 target_white_use_measured=>0,target_white_luminance=>100,
 target_black_use_measured=>0,target_black_luminance=>0,
};
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>1.999}),'a',
 '3D repeats strictly below the target-Y trigger');
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>2}),'off',
 '3D keeps one sample exactly at the target-Y trigger');
is(LowLight3DWorker::autocal3d_low_light_mode_for_step($low_light_3d_config,{target_Y=>undef}),'off',
 '3D fails safe to one sample for invalid target Y');
my $profile_step={kind=>'node',level=>10,signal_r_pct=>10,signal_g_pct=>10,signal_b_pct=>10};
my $profile_target=LowLight3DWorker::profile_target_xyz_for_step($profile_step,$low_light_3d_config,100,0);
my $profile_expected=LowLight3DWorker::autocal3d_expected_target_y_for_low_light($low_light_3d_config,$profile_step);
cmp_ok(abs($profile_expected-$profile_target->[1]),'<',0.0000001,
 '3D low-light selection reuses the profile target helper');
{
 no warnings qw(redefine once);
 my ($captured,$request_id,$result_gets)=(undef,undef,0);
 local *LowLight3DWorker::api_json=sub {
  my ($method,$path,$payload)=@_;
  if($method eq 'POST' && $path eq '/api/meter/read') {
   $captured=$payload;
   $request_id=$payload->{request_id};
   return {status=>'measuring'};
  }
  if($method eq 'GET' && $path eq '/api/meter/read/result') {
   $result_gets++;
   return {status=>'error',message=>'Web UI API timed out during /api/meter/read/result'} if($result_gets==1);
   return {status=>'ok',request_id=>$request_id,readings=>[{
    request_id=>$request_id,timestamp=>time(),X=>0,Y=>0,Z=>0,x=>0,y=>0,luminance=>0,
   }]};
  }
  return {status=>'ok'};
 };
 my ($reading,$error)=LowLight3DWorker::read_step_once($low_light_3d_config,{
  phase=>'profile',kind=>'black',level=>0,r=>16,g=>16,b=>16,
  ire=>0,stimulus=>0,signal_r_pct=>0,signal_g_pct=>0,signal_b_pct=>0,name=>'Black',input_max=>255,
 },1);
 ok(!defined($error) && ref($reading) eq 'HASH','the captured 3D black read completes');
 is($result_gets,2,'the 3D worker re-polls the same request after one result-poll transport timeout');
 is($captured->{low_light_session}{mode},'off','the 3D read never changes the Argyll process mode');
 is($captured->{low_light}{mode},'a','the 3D black read requests two physical application samples');
 is($captured->{low_light}{requested_sample_count},2,
  'the 3D request carries the numeric execution contract');
}

open(my $w3,'<',$worker3d) or die "Unable to read $worker3d: $!";
local $/;
my $source3d=<$w3>;
close($w3);
like($source3d,qr/low_light_session"\}=\{ mode => "off", enabled => json_false\(\) \}[\s\S]{0,180}?autocal3d_low_light_mode_for_step\(\$config,\$step\)[\s\S]{0,180}?\$payload->\{"low_light"\}/,
 'the 3D worker keeps Argyll normal and requests thresholded application samples');
like($source3d,qr/my \$read_sample_count=autocal3d_requested_sample_count\(\$config,\$active_low_light\);[\s\S]{0,1200}?read_timeout_for_step\(\$step,\$payload->\{"read_timeout"\}\)\*\$read_sample_count\+\(\$read_sample_count > 1 \? 45 : 0\)/,
 'the 3D read deadline scales with the sample count plus the comm-retry grace');

unlike($source3d,qr/very_low_ire_threshold|sub low_light_mode_for_reading/,
 'the 3D worker has no IRE-band or forced-aaa override');
like($source3d,qr/calibration_end_retry_forbidden/,'the 3D worker records a foreign-close prohibition');
like($source3d,qr/if\(\$upload_requested[^\n]+!lg_calibration_end_retry_forbidden\(\$state\)\)[\s\S]{0,200}?\/api\/lg\/calibration-mode/s,
 'the 3D terminal cleanup endpoint is gated off after an accepted write with unconfirmed CAL_END');
like($source3d,qr/tone_map_upload_status"\}="error"[\s\S]{0,300}?lg-tone-map-peak-missing/s,
 'the 3D worker marks a missing tone-map peak as an error instead of skipped');
{
 no warnings qw(redefine once);
 my $stops=0;
 local *LowLight3DWorker::api_json=sub {
  my ($method,$path)=@_;
  $stops++ if($method eq 'POST' && $path eq '/api/meter/session/stop');
  return {status=>'ok'};
 };
 LowLight3DWorker::reset_meter_session_success();
 LowLight3DWorker::maybe_reset_meter_session_after_read_error('Meter read timed out; meter session closed for clean retry');
 is($stops,1,'the 3D worker uses session stop as a cleanup barrier on the first clean-retry error');
 $stops=0;
 LowLight3DWorker::reset_meter_session_success();
 LowLight3DWorker::maybe_reset_meter_session_after_read_error('spotread unavailable');
 is($stops,0,'the 3D worker still preserves the session for one ordinary transient error');
 LowLight3DWorker::reset_meter_session_success();
}

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
 'the WebUI keeps the physical meter process in normal adaptive mode');
like($webui_source,qr/sub webui_low_light_request_contract[\s\S]{0,900}?\$mode="off" if\(!\$enabled \|\| \$force_off\)/s,
 'the WebUI fails a disabled or malformed per-read state to off');
like($webui_source,qr/webui_low_light_request_contract\(\$body,\$require_device_ready\)/,
 'the WebUI preserves the established single-read spectrophotometer workflow');
like($webui_source,qr/my \$cmd_low_light_mode=\$avg_mode/,
 'the WebUI sends the effective application sample mode in every READ command');
like($webui_source,qr/operation_timeout=.*?average_sample_count[\s\S]{0,300}?timeout_sec/s,
 'the WebUI stale timer covers all requested physical samples');
like($webui_source,qr/return 1 if\(\$method eq "GET" && \$path eq "\/api\/meter\/read\/result"\)/,
 'meter result polling uses the concurrent read-only lane instead of queueing behind device commands');
like($webui_source,qr/my \$timeout_sec=170;[\s\S]{0,300}?\$timeout_sec=\$requested\+30 if\(\$requested >= 10\);\s*\$timeout_sec=40 if\(\$timeout_sec < 40\);\s*\$timeout_sec=1830 if\(\$timeout_sec > 1830\)/s,
 'the stale reaper honours the published multi-sample timeout with its fixed clamps and 170s fallback');
like($webui_source,qr/\$_meter_read_command_started < 150[\s\S]{0,700}?lock\(\$_meter_stale_reap_last\)[\s\S]{0,700}?webui_meter_session_stop/s,
 'the concurrent-lane reaper defers to a live serialized read command and debounces its teardown');
like($webui_source,qr/my \$autocal_busy=0[\s\S]{0,1800}?full_autocal_phase[\s\S]{0,900}?my \$busy=.*?\$autocal_busy/s,
 'meter inventory probing stays suppressed across active AutoCal workers and the 1D-to-3D handoff');
like($webui_source,qr/if\(meterDetected && \([\s\S]{0,500}?meterLg3dAutoCalRunning[\s\S]{0,300}?meterFullAutoCalRunning[\s\S]{0,500}?window\._meterToneMapBusy/s,
 'the browser status refresh treats every AutoCal phase as meter-busy');
like($webui_source,qr/const METER_AUTOCAL_WORKER_START_TIMEOUT_MS=30000/,
 'AutoCal worker starts allow the server to finish its safe meter-session handoff');
like($webui_source,qr/function meterFullAutoCalAdoptGreyscaleStart[\s\S]{0,700}?probe\.status==='running'[\s\S]{0,300}?meterFullAutoCalStatusRunId\(probe\)===wanted/s,
 'a lost greyscale start response only adopts the matching live Full AutoCal worker');
like($webui_source,qr/full_autocal_phase:[\s\S]{0,80}?'first-greyscale'[\s\S]{0,4500}?_timeoutMs:METER_AUTOCAL_WORKER_START_TIMEOUT_MS[\s\S]{0,180}?meterFullAutoCalAdoptGreyscaleStart\(r,meterFullAutoCalRunId,'first-greyscale'\)/s,
 'the first greyscale start keeps its busy guard through the safe handoff and adoption probe');
like($webui_source,qr/meterFullAutoCalStatusRunId\(probe\)===wanted[\s\S]{0,120}?probe\.full_autocal_phase[\s\S]{0,60}?expectedPhase/s,
 'a lost start response adopts only the worker running the phase that was just requested');
like($series_source,qr/prepare_series_steps\(\)[\s\S]{0,1800}?PGEN_SERIES_STEPS_HELPER/,
 'the series normalizes target and display metadata once per generation');
unlike($series_source,qr/get_step_field|get_step_count/,
 'the steady-state series loop has no per-field step parser');
like($series_source,qr/capture_series_average_sample[\s\S]{0,10000}?PGEN_METER_RESULT_HELPER[\s\S]{0,100}?average/s,
 'the series captures repeated samples on one child and uses the shared reducer');
like($series_source,qr/REQUIRE_DEVICE_READY.*?LOW_LIGHT_MODE="off"/,
 'the series disables colorimeter averaging for spectrophotometers');
unlike($series_source,qr/SR_CMD="\$SR_CMD -Y (?:a|aa|aaa)"|ensure_spotread_low_light_for_step|restart_spotread_session/,
 'the series has no Argyll averaging flag or per-step process transition');
like($series_source,qr/error":"averaging_incomplete"[\s\S]{0,500}?series_quit_spotread "averaging_incomplete"[\s\S]{0,300}?exit 1/,
 'a series stops and retires spotread rather than accepting a late averaging sample');
like($series_source,qr/series_meter_read_failure_exit\(\)[\s\S]{0,900}?error_code[\s\S]{0,500}?series_quit_spotread/s,
 'ordinary incomplete series reads share a terminal child-retirement path');
like($series_source,qr/READ_INCOMPLETE=1[\s\S]{0,1800}?series_meter_read_failure_exit "Meter read did not complete/s,
 'a primary series timeout cannot become a no-reading row and continue to the next patch');
like($series_source,qr/communication retry produced no result during zero confirmation[\s\S]{0,1800}?series_meter_read_failure_exit "Meter zero-confirmation read did not complete/s,
 'an incomplete zero confirmation cannot leak a late result into averaging or the next patch');
like($series_source,qr/Initial white-reference read did not complete[\s\S]{0,300}?series stopped before a late result/s,
 'the required DV white pre-read fails terminally if it has no exact result');
like($series_source,qr/Final white-reference read did not complete[\s\S]{0,300}?without publishing stale white data/s,
 'the required final white refresh cannot silently publish the old white reading');
like($series_source,qr/STEP_FINAL_WHITE_REFRESH=.*?PREPARED_STEP_FINAL_WHITE_REFRESH/,
 'the series loop reads the structural final-white marker');
like($series_source,qr/\|\| "\$STEP_FINAL_WHITE_REFRESH" == "True"[\s\S]{0,700}?apply_series_white_reference_to_steps/s,
 'a greyscale final-white marker promotes the initial measured white into later step metadata');
unlike($series_source,qr/LOW_LIGHT_FLAGS|x_aaa/,
 'the series worker does not force a legacy or composite averaging mode');

# Preserve the measured-white propagation fix independently of the meter mode:
# later target metadata must still use the live 406.513964 cd/m2 reference.
my $worker_dir=tempdir('pgen-meter-low-light-XXXXXX',TMPDIR=>1,CLEANUP=>1);
my $steps_path=File::Spec->catfile($worker_dir,'steps.json');
my $steps=[
 {r=>255,g=>255,b=>255,input_max=>255,ire=>100,name=>'100%',target_Yn=>1,final_white_refresh=>JSON::PP::true,series_target_black_y=>0},
 {r=>0,g=>0,b=>0,input_max=>255,ire=>0,name=>'0%',target_Yn=>0,series_target_black_y=>0},
 {r=>13,g=>13,b=>13,input_max=>255,ire=>5,name=>'5%',target_Yn=>0.000762564474113076,series_target_black_y=>0},
 {r=>26,g=>26,b=>26,input_max=>255,ire=>10,name=>'10%',target_Yn=>0.0040248394242663,series_target_black_y=>0},
];
open(my $steps_fh,'>',$steps_path) or die "Unable to write $steps_path: $!";
print {$steps_fh} JSON::PP->new->canonical->encode($steps);
close($steps_fh);
my $white_worker=embedded_python_worker($series_source,'apply_series_white_reference_to_steps');
ok(defined($white_worker),
 'the production measured-white worker can be exercised directly');
if(defined($white_worker)) {
 my ($white_status)=run_python_worker($white_worker,{
  STEPS_FILE=>$steps_path,WHITE_Y=>'406.513964',
 });
 is($white_status,0,'the recorded SDR white is attached to the remaining series steps');
 open(my $updated_fh,'<',$steps_path) or die "Unable to read $steps_path: $!";
 local $/;
 my $updated=decode_json(<$updated_fh>);
 close($updated_fh);
 cmp_ok(abs($updated->[2]{series_target_white_y}-406.513964),'<',1e-9,
  'the 5% step receives the measured white reference');
 my $normalizer="$Bin/../usr/bin/pgen_series_steps.py";
 open(my $normalized,'-|','python3',$normalizer,'normalize',$steps_path,1,'a',2,1,'1931_2')
  or die "Unable to run $normalizer: $!";
 local $/;
 my $stream=<$normalized>||'';
 close($normalized);
 is($? >> 8,0,'low-light selector runs while preparing the measured-white generation');
 my @normalized_fields=split(/\0/,$stream,-1);
 splice(@normalized_fields,0,4);
 my @modes=map { $normalized_fields[$_*17+12] } (0..3);
 is_deeply(\@modes,[qw(off a a off)],
  'recorded SDR steps repeat below one nit and stay single at/above it');
}

done_testing();

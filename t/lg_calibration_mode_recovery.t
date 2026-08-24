use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

my $helper="$Bin/../usr/sbin/pgenerator-lg";
{
 no warnings 'once';
 do $helper;
}
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_1d_dpg_upload_workflow_inner));

my $webui="$Bin/../usr/share/PGenerator/lg.pm";
do $webui;
die $@ if($@);
die "Failed to load $webui" if(!defined(&lg_clear_stale_calibration_mode_for_reset));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

our $worker_running=0;
sub webui_meter_lg_autocal_running { return $worker_running; }
sub webui_meter_lg_3d_autocal_running { return 0; }

my $OK={ type => "response", payload => { returnValue => JSON::PP::true() } };
my $DRIVER_ERROR={
 type => "error",
 error => "500 Application error",
 payload => {
  returnValue => JSON::PP::false(),
  errorCode => 20,
  errorText => "Driver error while executing the command",
 },
};
my $UNRELATED_ERROR={
 type => "error",
 error => "500 Application error",
 payload => {
  returnValue => JSON::PP::false(),
  errorCode => 20,
  errorText => "Calibration session belongs to another client",
 },
};

# A reset with no persisted session must not emit a redundant CAL_END.
{
 my @calls;
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { push(@calls,$_[0]); return { status => "ok" }; };
 my $clients={ calibration_mode => JSON::PP::false() };
 my $result=lg_clear_stale_calibration_mode_for_reset($clients,"10.0.0.2","key","hdrFilmMaker","hdr10");
 ok(!defined($result),'no stale-session cleanup is needed when calibration mode is off');
 is(scalar(@calls),0,'no helper command is sent');
}

# Never tear down a valid held session underneath a live worker.
{
 local $worker_running=1;
 my @calls;
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { push(@calls,$_[0]); return { status => "ok" }; };
 my $clients={ calibration_mode => JSON::PP::true(), calibration_picture_mode => "hdr_filmMaker" };
 my $result=lg_clear_stale_calibration_mode_for_reset($clients,"10.0.0.2","key","hdrFilmMaker","hdr10");
 is($result->{status},'error','a reset is blocked while AutoCal is genuinely running');
 is($result->{error_code},'lg-calibration-session-active','the active-session reason is explicit');
 is(scalar(@calls),0,'CAL_END is not sent underneath the live worker');
}

# A failed cleanup must not lock the operator out of every reset (a
# power-cycled TV rejects a no-session CAL_END); the reset proceeds and the
# durable flag is preserved until the reset itself succeeds.
{
 local $worker_running=0;
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { return { status => "error", message => "CAL_END rejected" }; };
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={ calibration_mode => JSON::PP::true(), calibration_picture_mode => "hdr_filmMaker" };
 my $result=lg_clear_stale_calibration_mode_for_reset($clients,"10.0.0.2","key","hdrFilmMaker","hdr10");
 is($result->{status},'ok','an unacknowledged cleanup does not block the reset');
 is($result->{error_code},'lg-calibration-session-stuck','the stuck-session reason is still explicit');
 ok(!$result->{stale_calibration_mode_cleared},'the response does not claim the session was cleared');
 ok($clients->{calibration_mode},'the stored mode remains active after cleanup failure');
 is(scalar(@saved),0,'failed cleanup is never persisted as cleared');
}

# Re-recording an unchanged state must not rewrite the client store (the
# greyscale solver uploads a DPG on every inner iteration).
{
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={ calibration_mode => JSON::PP::true(), calibration_picture_mode => "hdr_filmMaker" };
 lg_store_calibration_mode_state($clients,1,"hdr_filmMaker");
 lg_store_calibration_mode_state($clients,1,"");
 is(scalar(@saved),0,'an unchanged held-session state is not persisted again');
 lg_store_calibration_mode_state($clients,0,"");
 is(scalar(@saved),1,'clearing the held session is persisted');
 lg_store_calibration_mode_state($clients,0,"");
 is(scalar(@saved),1,'a repeated clear is not persisted again');
}

# A cross-stage write records its held-session intent before CAL_START. This
# keeps cleanup possible even when the helper fails after opening the session.
{
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={};
 my $error=lg_prepare_held_calibration_mode($clients,1,0,'hdr_filmMaker');
 ok(!defined($error),'a persistable held-session intent permits the write');
 ok($clients->{calibration_mode},'the intent is marked active before the helper runs');
 is($clients->{calibration_picture_mode},'hdr_filmMaker','the intended calibration mode is retained');
 is(scalar(@saved),1,'the held-session intent is persisted exactly once');
 $error=lg_prepare_held_calibration_mode($clients,1,1,'hdr_filmMaker');
 ok(!defined($error),'an already-active session needs no new preparation');
 is(scalar(@saved),1,'an already-active session is not rewritten');
}

{
 no warnings qw(redefine once);
 local *main::lg_save_clients=sub (@) { return 0; };
 my $clients={};
 my $error=lg_prepare_held_calibration_mode($clients,1,0,'hdr_filmMaker');
 is($error->{status},'error','a write is refused when its held state cannot be persisted');
 is($error->{error_code},'lg-calibration-state-not-persisted','the persistence failure is machine-readable');
}

# Successful cleanup sends exactly one disable action and clears persistence.
{
 local $worker_running=0;
 my (@calls,@saved);
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { push(@calls,$_[0]); return { status => "ok", message => "LG calibration mode disabled." }; };
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={ calibration_mode => JSON::PP::true(), calibration_picture_mode => "hdr_filmMaker" };
 my $result=lg_clear_stale_calibration_mode_for_reset($clients,"10.0.0.2","key","hdrFilmMaker","hdr10");
 is($result->{status},'ok','stale CAL_END acknowledgement permits the reset to continue');
 ok($result->{stale_calibration_mode_cleared},'the response identifies stale-session recovery');
 is(scalar(@calls),1,'one cleanup helper command is sent');
 is($calls[0]{action},'calibration_mode','cleanup uses the calibration-mode workflow');
 is($calls[0]{enable},0,'cleanup explicitly disables calibration mode');
 is($calls[0]{picture_mode},'hdrFilmMaker','cleanup targets the requested picture mode');
 ok(!$clients->{calibration_mode},'the durable calibration flag is cleared');
 ok(!exists($clients->{calibration_picture_mode}),'the held picture mode is removed');
 is(scalar(@saved),1,'the cleared state is persisted once');
}

# Run-end cleanup is the terminal safety net for a worker that exited while
# CAL_START was still persisted.
{
 local $worker_running=0;
 my (@calls,@saved);
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { push(@calls,$_[0]); return { status => "ok" }; };
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={
  ip => "10.0.0.2",
  client_key => "key",
  calibration_mode => JSON::PP::true(),
  calibration_picture_mode => "hdr_filmMaker",
 };
 my $result=lg_close_calibration_mode_at_run_end($clients,{});
 is($result->{status},'ok','run-end cleanup succeeds after an acknowledged CAL_END');
 is(scalar(@calls),1,'run-end sends one helper command');
 is($calls[0]{action},'calibration_mode','run-end uses the calibration-mode endpoint');
 is($calls[0]{enable},0,'run-end explicitly disables calibration mode');
 ok(!$clients->{calibration_mode},'run-end clears the durable calibration flag');
 is(scalar(@saved),1,'the cleared run-end state is persisted once');
}

{
 local $worker_running=0;
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { return { status => "error", message => "CAL_END rejected" }; };
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={ ip => "10.0.0.2", client_key => "key", calibration_mode => JSON::PP::true() };
 my $result=lg_close_calibration_mode_at_run_end($clients,{});
 is($result->{status},'error','run-end surfaces an unclosed calibration session');
 is($result->{error_code},'lg-calibration-session-stuck','the stuck run-end state is machine-readable');
 ok($clients->{calibration_mode},'failed run-end cleanup preserves the durable flag');
 is(scalar(@saved),0,'failed run-end cleanup is never persisted as cleared');
}

{
 local $worker_running=1;
 my @calls;
 no warnings qw(redefine once);
 local *main::lg_helper_run=sub (@) { push(@calls,$_[0]); return { status => "ok" }; };
 my $clients={ ip => "10.0.0.2", client_key => "key", calibration_mode => JSON::PP::true() };
 my $result=lg_close_calibration_mode_at_run_end($clients,{});
 is($result->{error_code},'lg-calibration-session-active','run-end never closes CAL_START under a live worker');
 is(scalar(@calls),0,'no helper command is sent under a live worker');
}

# Successful upload wrappers keep the durable flag in lockstep with the
# helper's verified session outcome.
{
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={};
 my $result={ status => "ok", calibration_picture_mode => "hdr_filmMaker" };
 lg_record_calibration_mode_result($clients,$result,1,"hdrFilmMaker");
 ok($clients->{calibration_mode},'a verified held-session result is persisted active');
 is($clients->{calibration_picture_mode},'hdr_filmMaker','the canonical helper mode is persisted');
 ok($result->{calibration_mode},'the API result reports the held session');
 lg_record_calibration_mode_result($clients,{ status => "ok" },0,"hdrFilmMaker");
 ok(!$clients->{calibration_mode},'a verified CAL_END result is persisted inactive');
 ok(!exists($clients->{calibration_picture_mode}),'the canonical mode is removed after CAL_END');
}

# An explicit CAL_START rejection proves this invocation did not acquire the
# session. Never answer it with CAL_END because that could close another
# caller's held calibration session.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  my $command=$_[2];
  push(@commands,$command);
  return $DRIVER_ERROR if($command eq "CAL_START");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my @dpg=(0) x 3072;
 my $result=lg_1d_dpg_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker",\@dpg,0,0,"hdr10");
 is($result->{status},'error','the rejected start remains an error');
 is($result->{error_code},'lg-calibration-start-rejected','an explicit rejection has a distinct error code');
 is_deeply(\@commands,[qw(CAL_START)],'an explicit CAL_START rejection is never followed by speculative CAL_END');
 ok($result->{cal_start_explicit_rejection},'the rejection is distinguished from a missing reply');
 ok(!exists($result->{cal_end_cleanup_response}),'no cleanup response is invented when no cleanup was sent');
}

# A missing CAL_START reply is ambiguous: this socket may have opened the
# session before losing the acknowledgement. Same-socket cleanup is allowed
# only when the caller did not report an already-held session.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  my $command=$_[2];
  push(@commands,$command);
  return undef if($command eq "CAL_START");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my @dpg=(0) x 3072;
 my $result=lg_1d_dpg_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker",\@dpg,0,0,"hdr10");
 is($result->{status},'error','a missing start acknowledgement fails the upload');
 is($result->{error_code},'lg-calibration-start-unconfirmed','a missing reply is distinguished from rejection');
 is_deeply(\@commands,[qw(CAL_START CAL_END)],'an ambiguous missing start may receive same-socket cleanup');
 ok(ref($result->{cal_end_cleanup_response}) eq 'HASH','the same-socket cleanup response is retained');

 @commands=();
 my $cleanup=lg_calibration_start_cleanup_if_safe({},'held_cleanup',undef,1,undef,1,'hdr_filmMaker',5);
 ok(!defined($cleanup),'missing-start cleanup is forbidden when the caller reports a held session');
 is_deeply(\@commands,[],'no CAL_END is sent against caller-held state');
}

# A write failure inside caller-held state is not an excuse to close that
# state from this helper socket.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return $DRIVER_ERROR if($_[2] eq "1D_DPG_DATA");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my @dpg=(0) x 3072;
 my $result=lg_1d_dpg_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker",\@dpg,0,1,"hdr10");
 is($result->{status},'error','a write failure inside caller-held state remains an error');
 is_deeply(\@commands,[qw(1D_DPG_DATA)],'caller-held write failure sends no cleanup CAL_END');
 is($result->{cal_end_response}{reason},'caller-session-held-after-write-failure','the skipped foreign close is diagnostic');
}

# The same explicit-rejection contract applies to the 3D LUT upload path.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_read_3d_lut_file=sub (@) { return [ (0) x (33**3*3) ]; };
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) { push(@commands,$_[2]); return $DRIVER_ERROR; };
 local *main::websocket_close=sub (@) { return 1; };
 local *main::diag_log_append=sub (@) { return 1; };
 my $result=lg_3d_lut_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker","/tmp/lut.bin","BT2020_3D_LUT_DATA","GET_3D_LUT_DATA",0,0,"hdr10");
 is($result->{status},'error','3D upload fails on explicit CAL_START rejection');
 is($result->{error_code},'lg-calibration-start-rejected','3D upload classifies the explicit rejection');
 is_deeply(\@commands,[qw(CAL_START)],'3D upload sends no speculative CAL_END after rejection');
}

# A successful DPG write cannot be reported as committed when CAL_END fails.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  my $command=$_[2];
  push(@commands,$command);
  return $DRIVER_ERROR if($command eq "CAL_END");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my @dpg=(0) x 3072;
 my $result=lg_1d_dpg_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker",\@dpg,0,0,"hdr10");
 is($result->{status},'error','an unconfirmed CAL_END fails the 1D DPG commit');
 is($result->{error_code},'lg-calibration-end-unconfirmed','the close failure has a stable error code');
 like($result->{message},qr/Driver error|did not confirm calibration mode end/i,'the CAL_END failure is visible');
 ok($result->{dpg_write_accepted},'the response distinguishes write acceptance from commit failure');
 ok(!$result->{dpg_uploaded},'the DPG is not reported as uploaded/committed');
 ok($result->{calibration_mode},'the session remains reported as held');
 ok($result->{calibration_session_unconfirmed},'the held state is explicitly unconfirmed');
}

# A verified 3D LUT write cannot be reported as committed when CAL_END fails:
# the retry wrapper and the worker's commit gate both key on this shape.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_read_3d_lut_file=sub (@) { return [ (0) x (33**3*3) ]; };
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  my $command=$_[2];
  push(@commands,$command);
  return $DRIVER_ERROR if($command eq "CAL_END");
  return $OK;
 };
 local *main::lg_3d_lut_put=sub (@) { return (1,"",$OK); };
 local *main::lg_3d_lut_get=sub (@) { return (1,$_[3] ? [ (0) x (33**3*3) ] : undef,"",$OK); };
 local *main::lg_3d_lut_matches=sub (@) { return 1; };
 local *main::websocket_close=sub (@) { return 1; };
 local *main::diag_log_append=sub (@) { return 1; };
 my $result=lg_3d_lut_upload_workflow_inner("10.0.0.2","key",5,"hdrFilmMaker","/tmp/lut.bin","BT2020_3D_LUT_DATA","GET_3D_LUT_DATA",0,0,"hdr10");
 is($result->{status},'error','an unconfirmed CAL_END fails the 3D LUT commit');
 is($result->{error_code},'lg-calibration-end-unconfirmed','the 3D close failure uses the stable error code');
 ok($result->{upload_write_verified},'the response records that the write itself verified');
 ok(!$result->{upload_verified},'the LUT is not reported as committed');
 ok(ref($result->{cal_end_response}) eq 'HASH','the CAL_END failure is retained for diagnosis');
 is($commands[-1],'CAL_END','the failure is at the CAL_END step');
}

# HDR reset surfaces the exact cold-restart condition without sending
# CAL_END against an explicitly rejected start.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) {
  my $command=$_[2];
  push(@commands,$command);
  return $DRIVER_ERROR if($command eq "CAL_START");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_hdr_calman_reset_workflow("10.0.0.2","key",5,"hdrFilmMaker","");
 is($result->{status},'error','the HDR reset still fails closed on driver error 20');
 is($result->{error_code},'lg-calibration-driver-stuck','the driver-stuck condition is machine-readable');
 ok($result->{tv_restart_may_be_required},'the UI can tell the operator a cold restart may be required');
 like($result->{message},qr/cold-restart/i,'the operator receives a precise recovery instruction');
 is_deeply(\@commands,[qw(CAL_START)],'HDR reset does not send CAL_END after explicit start rejection');
}

# The exact known DV error 20 may still mean this socket owns the calibration
# exchange. Continue through the data writes and send the matching CAL_END on
# that same socket; the same exact fingerprint may confirm closure.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_hdr_picture_reset_apply_dynamic_contrast_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return $DRIVER_ERROR if($_[2] eq "CAL_START" || $_[2] eq "CAL_END");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_dv_calman_reset_workflow("10.0.0.2","key",5,"dolbyHdrCinema","hdmi1");
 is($result->{status},'ok','DV reset accepts the exact tolerated start and end fingerprints');
 ok($result->{dv_calman_reset},'the tolerated DV exchange completes the reset');
 ok(scalar(grep { $_ eq 'BT2020_3D_LUT_DATA' } @commands),'DV reset sends calibration data after the tolerated start');
 is($commands[0],'CAL_START','DV reset starts on the owned socket');
 is($commands[-1],'CAL_END','DV reset closes on that same socket');
}

# An explicit DV start rejection that does not match the exact known
# fingerprint is fatal and must not receive speculative same-socket cleanup.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_hdr_picture_reset_apply_dynamic_contrast_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return $UNRELATED_ERROR;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_dv_calman_reset_workflow("10.0.0.2","key",5,"dolbyHdrCinema","hdmi1");
 is($result->{status},'error','an unrelated DV start rejection fails closed');
 is($result->{error_code},'lg-calibration-start-rejected','the unrelated rejection is classified as a rejected start');
 is_deeply(\@commands,[qw(CAL_START)],'an unrelated explicit DV rejection sends no data or cleanup CAL_END');
}

# A strict run-end CAL_END needs a positive WebOS acknowledgement. Missing,
# rejected, and synthetic replies retain the held state and stable code.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) { push(@commands,$_[2]); return undef; };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_calibration_mode_workflow("10.0.0.2","key",5,0,"hdrFilmMaker","hdr10");
 is($result->{status},'error','run-end CAL_END cannot succeed without confirmation');
 is($result->{error_code},'lg-calibration-end-unconfirmed','run-end uses the stable close error code');
 ok($result->{calibration_mode},'run-end keeps the calibration session held');
 is_deeply(\@commands,[qw(CAL_END)],'run-end sends one strict CAL_END attempt');
}

# DV reset must not report success when its final CAL_END acknowledgement is
# missing, even when every reset write was accepted.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_hdr_picture_reset_apply_dynamic_contrast_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return undef if($_[2] eq "CAL_END");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_dv_calman_reset_workflow("10.0.0.2","key",5,"dolbyHdrCinema","hdmi1");
 is($result->{status},'error','DV reset fails when CAL_END is missing');
 is($result->{error_code},'lg-calibration-end-unconfirmed','DV reset uses the stable close error code');
 ok($result->{calibration_mode},'DV reset retains held calibration state');
 ok(!$result->{dv_calman_reset},'DV reset is not falsely reported complete');
 is($commands[-1],'CAL_END','DV reset reaches its final CAL_END on the original socket');
}

# An actual DV driver-error 20 reply is a real WebOS response and may be
# tolerated. A missing reply must not reuse that exception.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_hdr_picture_reset_apply_dynamic_contrast_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return $DRIVER_ERROR if($_[2] eq "CAL_END");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_dv_calman_reset_workflow("10.0.0.2","key",5,"dolbyHdrCinema","hdmi1");
 is($result->{status},'ok','DV reset succeeds when CAL_END is the known driver rejection');
 ok($result->{dv_calman_reset},'DV reset is reported complete after a real driver-error CAL_END');
 is($commands[-1],'CAL_END','DV reset still sent CAL_END on the original socket');
}

# A disable/CAL_END reply that exists but is not a confirmation must not
# clear the held-session flag.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 local *main::lg_calibration_request=sub (@) { push(@commands,$_[2]); return { type => "response" }; };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_calibration_mode_workflow("10.0.0.2","key",5,0,"hdrFilmMaker","hdr10");
 is($result->{status},'error','run-end CAL_END without returnValue is unconfirmed');
 is($result->{error_code},'lg-calibration-end-unconfirmed','the unconfirmed disable keeps the stable close code');
 ok($result->{calibration_mode},'the disable path keeps the calibration session held');
 is_deeply(\@commands,[qw(CAL_END)],'the disable path sends one CAL_END');
}

# Calibration-mode disable uses the DV exception only after resolving a DV
# calibration mode. The identical driver reply remains fatal for HDR.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_calibration_request=sub (@) { push(@commands,$_[2]); return $DRIVER_ERROR; };
 local *main::websocket_close=sub (@) { return 1; };
 my $result=lg_calibration_mode_workflow("10.0.0.2","key",5,0,"dolbyHdrCinema","dv");
 is($result->{status},'ok','DV calibration-mode disable accepts the exact known CAL_END fingerprint');
 ok($result->{cal_end_tolerated},'the accepted DV exception is explicit in the response');
 ok(!$result->{calibration_mode},'the tolerated DV CAL_END reports calibration mode disabled');
 is_deeply(\@commands,[qw(CAL_END)],'DV disable sends exactly one CAL_END');

 @commands=();
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("hdrFilmMaker","hdr_filmMaker"); };
 $result=lg_calibration_mode_workflow("10.0.0.2","key",5,0,"hdrFilmMaker","hdr10");
 is($result->{status},'error','the same error remains unconfirmed outside resolved DV mode');
 is($result->{error_code},'lg-calibration-end-unconfirmed','non-DV disable retains the strict close error');
 is_deeply(\@commands,[qw(CAL_END)],'non-DV disable also makes only one close attempt');
}

# DV profile data accepted on the upload socket is not finalised until that
# same socket confirms CAL_END.
{
 my (@commands,@saved);
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_dv_profile_preflight_settings_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return undef if($_[2] eq "CAL_END");
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $measurements={
  white_luminance=>750, black_luminance=>0.0005,
  red_x=>0.68, red_y=>0.32, green_x=>0.265, green_y=>0.69,
  blue_x=>0.15, blue_y=>0.06,
 };
 my $result=lg_dv_profile_upload_workflow("10.0.0.2","key",5,"dolbyHdrCinema",$measurements,0,0);
 is($result->{status},'error','DV profile fails when CAL_END is missing');
 is($result->{error_code},'lg-calibration-end-unconfirmed','DV profile uses the stable close error code');
 ok($result->{dv_profile_write_accepted},'the accepted DV profile write is recorded');
 ok(!$result->{dv_profile_uploaded},'DV profile is not falsely reported finalised');
 ok($result->{calibration_mode},'DV profile retains held calibration state');
 is_deeply(\@commands,[qw(CAL_START DOLBY_CFG_DATA CAL_END)],'DV profile uses one socket and one final close attempt');
 my $clients={ calibration_mode => JSON::PP::false() };
 lg_record_calibration_mode_result($clients,$result,0,'dolbyHdrCinema');
 ok($clients->{calibration_mode},'the missing DV CAL_END is persisted as held');
 is($clients->{calibration_picture_mode},'dolby_hdr_cinema','the persisted held state keeps the resolved DV mode');
 is(scalar(@saved),1,'the missing DV close persists held state exactly once');
}

# A DV profile exchange owned by this helper may tolerate the exact start and
# end fingerprints, while keeping start, data, and end on one socket.
{
 my @commands;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) { return { status => "ok", session => {}, client_key => "key", system_info => {}, software_info => {}, hello_info => {} }; };
 local *main::lg_generation_info=sub (@) { return {}; };
 local *main::lg_3d_lut_resolve_mode=sub (@) { return ("dolbyHdrCinema","dolby_hdr_cinema"); };
 local *main::lg_dv_profile_preflight_settings_off=sub (@) { return (1,[]); };
 local *main::lg_calibration_request=sub (@) {
  push(@commands,$_[2]);
  return $DRIVER_ERROR if($_[2] eq 'CAL_START' || $_[2] eq 'CAL_END');
  return $OK;
 };
 local *main::websocket_close=sub (@) { return 1; };
 my $measurements={
  white_luminance=>750, black_luminance=>0.0005,
  red_x=>0.68, red_y=>0.32, green_x=>0.265, green_y=>0.69,
  blue_x=>0.15, blue_y=>0.06,
 };
 my $result=lg_dv_profile_upload_workflow("10.0.0.2","key",5,"dolbyHdrCinema",$measurements,0,0);
 is($result->{status},'ok','DV profile accepts exact tolerated start and end fingerprints');
 ok($result->{dv_profile_uploaded},'the accepted same-socket exchange finalises the DV profile');
 ok($result->{cal_start_tolerated} && $result->{cal_end_tolerated},'both tolerated DV session replies are reported');
 is_deeply(\@commands,[qw(CAL_START DOLBY_CFG_DATA CAL_END)],'tolerated DV profile start, data, and end stay on one socket');
}

# Persist the held state carried by the distinct close error. This prevents a
# later WebUI helper invocation from assuming the accepted write was closed.
{
 my @saved;
 no warnings qw(redefine once);
 local *main::lg_save_clients=sub (@) { push(@saved,{%{$_[0]}}); return 1; };
 my $clients={ calibration_mode => JSON::PP::false() };
 my $result={ status=>'error', error_code=>'lg-calibration-end-unconfirmed', calibration_picture_mode=>'hdr_filmMaker' };
 lg_record_calibration_mode_result($clients,$result,0,'hdrFilmMaker');
 ok($clients->{calibration_mode},'unconfirmed close persists the held flag despite error status');
 is($clients->{calibration_picture_mode},'hdr_filmMaker','the held calibration mode is persisted');
 is(scalar(@saved),1,'the held state is saved once');
}

done_testing();

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

# A rejected CAL_START is paired with a best-effort CAL_END before the helper
# returns, giving its retry wrapper a chance to recover a wedged driver.
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
 is_deeply(\@commands,[qw(CAL_START CAL_END)],'CAL_START failure is immediately paired with CAL_END cleanup');
 ok(ref($result->{cal_end_cleanup_response}) eq 'HASH','the cleanup acknowledgement is retained for diagnosis');
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
 like($result->{message},qr/Driver error|did not confirm calibration mode end/i,'the CAL_END failure is visible');
 ok($result->{dpg_write_accepted},'the response distinguishes write acceptance from commit failure');
 ok(!$result->{dpg_uploaded},'the DPG is not reported as uploaded/committed');
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
 ok($result->{upload_write_verified},'the response records that the write itself verified');
 ok(!$result->{upload_verified},'the LUT is not reported as committed');
 ok(ref($result->{cal_end_response}) eq 'HASH','the CAL_END failure is retained for diagnosis');
 is($commands[-1],'CAL_END','the failure is at the CAL_END step');
}

# HDR reset surfaces the exact cold-restart condition while still attempting
# CAL_END cleanup, instead of returning an opaque error 20.
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
 is_deeply(\@commands,[qw(CAL_START CAL_END)],'HDR reset pairs the rejected start with cleanup');
}

done_testing();

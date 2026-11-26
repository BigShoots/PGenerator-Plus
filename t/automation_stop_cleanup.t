use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

is(main::webui_route_device_lane('POST','/api/automation/runs/test/control/stop'),'','batch stop bypasses a blocked TV lane');
is(main::webui_route_device_lane('POST','/api/automation/runs/stop'),'','legacy batch stop also bypasses TV lane');
is(main::webui_route_device_lane('POST','/api/automation/readiness'),'tv','ordinary readiness remains serialized');
is(main::webui_route_device_lane('POST','/api/lg/dv-profile/stop'),'meter','DV worker cancellation does not wait behind TV requests');
{
 my $id='cleanup-launch-failed';
 my $run={id=>$id,token=>'owner-token',status=>'paused',items=>[]};
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',$run);
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',
  {owner=>'automation',run_id=>$id,token=>'owner-token',status=>'paused',pid=>0});
 no warnings 'redefine';
 local *main::webui_automation_reap_dead_runner=sub {0};
 local *main::webui_automation_launch_runner=sub {0};
 my $result=PGAutomation::decode_json(main::webui_automation_control($id,'stop'));
 is($result->{status},'error','Stop reports cleanup-runner launch failure');
 is($result->{error_code},'stop-cleanup-unverified','Stop names the unverified cleanup state');
 my $saved=PGAutomation::read_json_file(PGAutomation::run_dir($id).'/run.json');
 is($saved->{status},'interrupted','failed cleanup stays recoverable');
 ok(!$saved->{stop_cleanup}{verified},'TV exit is explicitly unverified');
 is(PGAutomation::read_json_file(PGAutomation::base_dir().'/execution.json')->{run_id},$id,
  'execution ownership remains until cleanup can run');
}
{
 my $id='cancel-guard';
 local *main::webui_automation_reap_dead_runner=sub {0}; # This fixture represents a still-live final-cleanup runner.
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{run_id=>$id,status=>'running',token=>'owner'});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'stop'});
 my $result=PGAutomation::decode_json(main::lg_automation_guard_json('{"automation_token":"owner"}'));
 is($result->{error_code},'automation-stopping','queued TV writes are rejected after Stop even with the old valid token');
 is(main::lg_automation_guard_json('{"automation_token":"owner","automation_cleanup":true}'),'','the cleanup runner can still close calibration mode');
 like(main::lg_automation_guard_json('{"automation_token":"wrong","automation_cleanup":true}'),qr/automation-active/,'cleanup flag does not bypass ownership');
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',{id=>$id,token=>'owner',status=>'completing',items=>[{status=>'complete'}],active_item=>0});
 my $reply=PGAutomation::decode_json(main::webui_automation_control($id,'stop'));
 is($reply->{run}{status},'stopping','Stop remains available during final cleanup');
 is($reply->{run}{items}[0]{status},'complete','Stop does not reopen a completed job');
}
{
 my @calls;
 local *main::lg_autocal_worker_running=sub {0};
 local *main::lg_target_ip=sub {'192.0.2.1'};
 local *main::lg_primary_client=sub {{client_key=>'fake-key'}};
 local *main::lg_helper_run=sub {push @calls,$_[0];{status=>'ok'}};
 local *main::lg_store_calibration_mode_state=sub {push @calls,'saved-off'};
 my $result=main::lg_close_calibration_mode_at_run_end({calibration_mode=>0},{force_stop=>1});
 is($result->{status},'ok','explicit Stop sends CAL_END even if cached flag says off');
 is($calls[0]{enable},0,'cleanup never opens a calibration session');
 is($calls[-1],'saved-off','off state is saved only after acknowledgement');
 @calls=();
 local *main::lg_helper_run=sub {{status=>'error',message=>'TV unreachable'}};
 $result=main::lg_close_calibration_mode_at_run_end({calibration_mode=>1},{force_stop=>1});
 is($result->{status},'error','unreachable TV is not reported closed');
 like($result->{message},qr/TV unreachable/,'cleanup preserves TV failure reason');
 is(scalar @calls,0,'failed exit cannot clear saved state');
 local *main::lg_autocal_worker_running=sub {1};
 is(main::lg_close_calibration_mode_at_run_end({calibration_mode=>1},{force_stop=>1})->{error_code},'lg-calibration-session-active','surviving workers prevent a false cleanup acknowledgement');
}
{
 local *main::webui_meter_lg_autocal_running=sub {0};
 local *main::webui_meter_lg_3d_autocal_running=sub {0};
 local *main::webui_meter_lg_dv_profile_running=sub {1};
 ok(main::lg_autocal_worker_running(1),'DV worker is included in cleanup liveness checks');
}
{
 my @calls;
 local *main::webui_automation_read_execution=sub {{status=>'running',run_id=>'batch'}};
 local *main::webui_automation_control=sub {push @calls,[@_];'batch-stop'};
 local *main::webui_meter_stop=sub {die 'must not stop only a batch child'};
 is(main::webui_meter_stop_complete('{}'),'batch-stop','standalone Stop delegates to complete batch cancellation when owned');
 is_deeply($calls[0],['batch','stop'],'correct batch receives stop');
}
{
 my @calls;
 local *main::webui_automation_read_execution=sub {undef};
 local *main::webui_meter_stop=sub {push @calls,'workers'};
 local *main::webui_meter_lg_autocal_clear_full_workflow_state=sub {push @calls,'workflow'};
 local *main::lg_load_clients=sub {{calibration_mode=>0}};
 local *main::lg_primary_client=sub {{client_key=>'fake'}};
 local *main::lg_autocal_worker_running=sub {push @calls,'probe';1};
 local *main::lg_close_calibration_mode_at_run_end=sub {push @calls,'exit';ok($_[1]{force_stop},'explicit stop forces fresh exit');{status=>'error',message=>'CAL_END rejected',client_key=>'secret-pairing'}};
 local *main::log=sub {};
 local *PGAutomation::write_json_atomic=sub {1};
 my $result=PGAutomation::decode_json(main::webui_meter_stop_complete('{}'));
 is_deeply(\@calls,['probe','workers','workflow','exit'],'LG workers are sampled, then shut down before TV exit');
 is($result->{status},'error','explicit stop propagates cleanup failure');
 is($result->{message},'CAL_END rejected','explicit stop exposes actual cause');
 unlike(PGAutomation::encode_json($result),qr/secret-pairing|client_key/,'stop response never exposes helper pairing credentials');
}
{
 # A manual or Continuous read never opens calibration mode. A C2 answers a
 # CAL_END with no open session with 401, so Stop must not send one.
 my @calls;
 my $flag=0;
 local *main::webui_automation_read_execution=sub {undef};
 local *main::webui_meter_stop=sub {push @calls,'workers'};
 local *main::webui_meter_lg_autocal_clear_full_workflow_state=sub {};
 local *main::lg_load_clients=sub {{calibration_mode=>$flag}};
 local *main::lg_primary_client=sub {{client_key=>'fake'}};
 local *main::lg_autocal_worker_running=sub {0};
 local *main::lg_close_calibration_mode_at_run_end=sub {push @calls,'exit';{status=>'error',message=>'401 insufficient permissions'}};
 local *main::log=sub {};
 local *PGAutomation::write_json_atomic=sub {1};
 my $result=PGAutomation::decode_json(main::webui_meter_stop_complete('{}'));
 is_deeply(\@calls,['workers'],'Stop after a manual read sends no CAL_END');
 is($result->{status},'ok','Stop after a manual read succeeds');
 like($result->{message},qr/no TV calibration session was open/,'Stop says no calibration session was open');
 @calls=();
 $flag=1;
 $result=PGAutomation::decode_json(main::webui_meter_stop_complete('{}'));
 is_deeply(\@calls,['workers','exit'],'a recorded calibration session is still closed without a worker');
 is($result->{status},'error','a recorded session that will not close is still reported');
}
{
 local @ARGV=('stop-test','test-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
{
 my @calls;my $clock=0;my $alive=1;
 my $run={id=>'stop-test',status=>'running',items=>[],lg_run_id=>'actual-lg-run'};
 local *main::time=sub {$clock+=10};
 local *main::_log=sub {};
 local *main::_run=sub {$run};
 local *main::_update_run=sub {$_[0]->($run);$run};
 local *main::_ensure_lg_connection=sub {1};
 local *main::_worker_process_alive=sub {$_[0] eq 'dv' && $alive};
 local *main::_release_execution=sub {};
 local *main::_api=sub {
  my ($method,$path,$payload)=@_;push @calls,[$path,$payload];
  $alive=0 if $path eq '/api/lg/dv-profile/kill';
  return {status=>'error',message=>'TV did not acknowledge CAL_END'} if $path eq '/api/lg/calibration-mode';
  return {status=>'ok',calibration_mode=>1} if $path eq '/api/lg/status';
  return {status=>'ok'};
 };
 main::_stop_active();
 is($run->{status},'stopping','runner displays cleanup even without active item');
 is(scalar(grep {$_->[0]=~m{/stop$} && $_->[0]!~/session/} @calls),4,'all four worker types receive cancellation without a current stage');
 ok(grep({$_->[0] eq '/api/lg/dv-profile/kill'} @calls),'orphan DV worker is force-stopped');
 ok(grep({$_->[0] eq '/api/lg/calibration-mode' && !$_->[1]{enabled}} @calls),'TV exit runs without an active item');
 is((grep {$_->[0] eq '/api/lg/autocal/run/end'} @calls)[0][1]{run_id},'actual-lg-run','cleanup ends the actual LG run, not the queue ID');
 ok(!$run->{stop_cleanup}{verified},'unacknowledged exit is saved as unverified');
 like($run->{worker_status}{message},qr/Cleanup failed:.*TV did not acknowledge CAL_END/,'finished cleanup replaces the in-progress worker message with its actual failure');
 main::_finish('stopped');
 is($run->{status},'interrupted','failed cleanup stays retryable instead of becoming terminal');
 ok($run->{cleanup_required},'cleanup-required flag persists');
 like($run->{failure}{message},qr/TV did not acknowledge CAL_END/,'top-level status includes cleanup cause');
}
{
 my $run={id=>'parked',status=>'interrupted',items=>[],worker_status=>{message=>'Stopping all workers and closing TV calibration mode'},
  stop_cleanup=>{verified=>JSON::PP::true,completed_at=>100,message=>'All workers stopped; meter released; TV acknowledged calibration exit',tv_status=>{client_key=>'private'}}};
 my $public=main::webui_automation_public_run($run);
 like($public->{worker_status}{message},qr/Cleanup complete: All workers stopped/,'historical interrupted runs show acknowledged cleanup instead of stale Stopping');
 unlike(PGAutomation::encode_json($public),qr/private|client_key|tv_status/,'cleanup display does not expose raw TV helper state');
 $run->{stop_cleanup}{verified}=JSON::PP::false;
 $run->{stop_cleanup}{message}='TV calibration exit unconfirmed';
 like(main::webui_automation_public_run($run)->{worker_status}{message},qr/Cleanup failed: TV calibration exit unconfirmed/,'unconfirmed cleanup is not reported complete');
 $run->{status}='running';
 is(main::webui_automation_public_run($run)->{worker_status}{message},'Stopping all workers and closing TV calibration mode','old cleanup evidence never replaces a resumed live worker');
 $run->{status}='interrupted';$run->{resumed_at}=101;
 is(main::webui_automation_public_run($run)->{worker_status}{message},'Stopping all workers and closing TV calibration mode','cleanup from before a resumed attempt cannot describe its later interruption');
 delete $run->{stop_cleanup};$run->{status}='interrupted';
 unlike(main::webui_automation_public_run($run)->{worker_status}{message},qr/Cleanup complete/,'missing cleanup evidence cannot claim a clean stop');
}
done_testing();

use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
# A reboot under a running batch must not leave the TV as the runner had it
# and the run parked behind a manual "Retry cleanup". Boot recovery finishes
# the cleanup itself through the Stop path, ending the batch so a fresh one
# can start. Runs that never had the TV stay resumable.
my @spawned;
local *main::webui_automation_spawn_restart_cleanup=sub {push @spawned,$_[0];1};
local *main::log=sub {};
sub write_run {
 my ($id,%fields)=@_;
 make_path(PGAutomation::run_dir($id).'/items');
 my $run={id=>$id,token=>"token-$id",status=>'running',runner_pid=>0,
  items=>[{name=>'HDR10 Filmmaker',status=>'queued'},{name=>'SDR Filmmaker',status=>'queued'}],%fields};
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',$run);
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',
  {owner=>'automation',run_id=>$id,token=>"token-$id",pid=>0,status=>$run->{status}});
 return $run;
}
my $read=sub { PGAutomation::read_json_file(PGAutomation::run_dir($_[0]).'/run.json') };

# 1. Restart while job 1 was applying TV settings: the runner records no
#    cleanup debt for this (only preflight and Stop do), so the restart
#    itself plus the active job is the evidence.
write_run('mid-job',active_item=>0,active_stage=>'tv-setup-verified');
ok(main::webui_automation_boot_recover(),'boot recovery runs');
my $run=$read->('mid-job');
is($run->{status},'interrupted','the run is marked interrupted by the restart');
is($run->{failure}{error_code},'daemon-restarted','with the restart as its cause');
ok(!$run->{cleanup_required} && !$run->{preflight_restore_required},'the runner had recorded no cleanup debt (the case the old code missed)');
is_deeply(\@spawned,['mid-job'],'cleanup is scheduled from the restart and the active job alone');
is($run->{restart_cleanup_attempts},1,'the attempt is counted');
like($run->{worker_status}{message},qr/restoring the TV automatically/,'the live card explains what is happening');

# 2. A second boot while the run still needs cleanup: one more attempt, then no more.
@spawned=();
main::webui_automation_boot_recover();
is_deeply(\@spawned,['mid-job'],'a second boot tries once more');
@spawned=();
main::webui_automation_boot_recover();
is_deeply(\@spawned,[],'a third boot leaves it for a manual Retry cleanup');
is($read->('mid-job')->{restart_cleanup_attempts},2,'attempts are capped at two');

# 3. Restart during the whole-queue check: the check's own restoration debt is the evidence.
@spawned=();
write_run('mid-preflight',active_item=>undef,active_stage=>'queue-preflight',preflight_restore_required=>1);
main::webui_automation_boot_recover();
is_deeply(\@spawned,['mid-preflight'],'a restart during the queue check restores the original modes');

# 4. Restart between jobs: nothing on the TV to undo, stays resumable.
@spawned=();
write_run('between-jobs',active_item=>undef,active_stage=>'');
main::webui_automation_boot_recover();
is_deeply(\@spawned,[],'a restart between jobs leaves the run resumable');
ok(!exists($read->('between-jobs')->{restart_cleanup_scheduled_at}),'and its manifest untouched');

# 4b. Restart while a finished batch was tidying up: its last job is complete, the TV is in its end state.
@spawned=();
write_run('finishing',active_item=>1,active_stage=>'apply-all-done',items=>[{name=>'A',status=>'complete'},{name=>'B',status=>'complete'}]);
main::webui_automation_boot_recover();
is_deeply(\@spawned,[],'a batch whose last job had completed is not ended as stopped');

# 5. A run the runner parked itself after its own cleanup (readiness refused): resumable, untouched.
@spawned=();
write_run('parked',status=>'interrupted',active_item=>0,active_stage=>'job-readiness',
 failure=>{stage=>'job-readiness',error_code=>'readiness-failed',message=>'TV refused'});
main::webui_automation_boot_recover();
is_deeply(\@spawned,[],'a run parked by the runner is left for the operator');

# 6. A run already owed cleanup from an earlier failed Stop: still picked up.
@spawned=();
write_run('owed',status=>'interrupted',active_item=>undef,active_stage=>'',cleanup_required=>1,
 failure=>{stage=>'stop-cleanup',error_code=>'stop-cleanup-unverified',message=>'unverified'});
main::webui_automation_boot_recover();
is_deeply(\@spawned,['owed'],'an unverified earlier cleanup is retried at boot');

# 7. Safely paused and finished runs are never touched.
@spawned=();
write_run('paused',status=>'paused',active_item=>0,active_stage=>'greyscale-done');
main::webui_automation_boot_recover();
write_run('done',status=>'stopped',active_item=>0);
main::webui_automation_boot_recover();
is_deeply(\@spawned,[],'paused and finished runs are not cleaned up');

# 8. The recovery script: waits for the daemon, probes the TV, then presses Stop through the API.
my $cmd=main::webui_automation_restart_cleanup_command('mid-job');
like($cmd,qr{/api/ping},'the script waits for the HTTP server first');
like($cmd,qr{daemon did not answer},'and gives up quietly if it never comes');
like($cmd,qr{/api/lg/status.*stored_ip},'it asks the daemon for the paired TV address');
like($cmd,qr{http://\$ip:3000/},'and probes the TV before dialling it');
like($cmd,qr{not reachable},'a TV that is off is left for a manual Retry cleanup');
like($cmd,qr{-X POST .*'/api/automation/runs/mid-job/control/stop'|-X POST .*'http://127\.0\.0\.1/api/automation/runs/mid-job/control/stop'},'then asks for the run to be stopped');
like($cmd,qr{restart-cleanup\.log},'and logs under the run directory, not /tmp');
is(main::webui_automation_shell_quote("it's"),q{'it'"'"'s'},'shell quoting survives an apostrophe');

# A crash or power cut while an opted-in job had TPC/GSR switched off: the
# manifest still says running, and boot recovery must hand it to the
# restart cleanup so the Stop path re-enables panel protection.
@spawned=();
write_run('crashed-tpc-off',status=>'running',active_item=>0,active_stage=>'greyscale',panel_protection=>{restore_pending=>1});
main::webui_automation_boot_recover();
is_deeply(\@spawned,['crashed-tpc-off'],'a crashed run with TPC/GSR off is cleaned at boot');
ok(main::webui_automation_cleanup_required($read->('crashed-tpc-off')),'the pending TPC/GSR restore is cleanup debt after recovery');
PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{});

@spawned=();
write_run('legacy-unsafe-pause',status=>'paused',active_item=>0,active_stage=>'greyscale-done',panel_protection=>{restore_pending=>1});
main::webui_automation_boot_recover();
is_deeply(\@spawned,['legacy-unsafe-pause'],'a legacy paused run with temporary protection changes is safely cleaned at boot');
ok($read->('legacy-unsafe-pause')->{pause_park_pending},'cleanup preserves its intended paused outcome');
is($read->('legacy-unsafe-pause')->{pending_terminal_status},'paused','safe pause remains resumable after recovery');
done_testing();

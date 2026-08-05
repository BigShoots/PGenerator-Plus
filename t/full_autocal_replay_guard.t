#
# Contract: one completed Full AutoCal run cannot launch its 3D stage twice.
#
# A replay is destructive even when the second upload fails: the start route
# first stops the shared meter/series owner, which cancels a post-cal report.
# The browser must therefore validate backend workflow metadata, and the
# server must reject a same-run completion before it calls webui_meter_stop().
#
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$FindBin::Bin/lib";
use PGenSource qw(repo_root slurp_source code_only slice_between);

my $root=repo_root($Bin);
my $webui=slurp_source($root,"usr/share/PGenerator/webui.pm");

my ($state_match)=($webui=~/(sub webui_meter_lg_3d_autocal_completed_state_matches \(\@\) \{.*?^\})/ms);
my ($report_match)=($webui=~/(sub webui_meter_lg_3d_autocal_completed_report_matches \(\@\) \{.*?^\})/ms);
ok(defined($state_match),"completed worker-state predicate is extractable");
ok(defined($report_match),"completed report predicate is extractable");

SKIP: {
 skip "completion predicates not extractable",7 if(!defined($state_match) || !defined($report_match));
 my $ok=eval "package PGenReplaySandbox; $state_match\n$report_match\n1";
 ok($ok,"completion predicates evaluate in isolation") or diag($@);
 skip "completion predicates did not compile",6 if(!$ok);

 ok(PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_state_matches({
   status=>'complete',upload_verified=>1,full_autocal_run_id=>'full-run-1'
  },'full-run-1'),
  "a verified terminal 3D state is a completion receipt");
 ok(!PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_state_matches({
   status=>'error',upload_verified=>0,full_autocal_run_id=>'full-run-1'
  },'full-run-1'),
  "a failed upload remains retryable");
 ok(!PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_state_matches({
   status=>'complete',upload_verified=>1,full_autocal_run_id=>'another-run'
  },'full-run-1'),
  "a different run's terminal state does not block this run");

 my $complete_archive={run_id=>'full-run-1',report=>{run_id=>'full-run-1',completion_status=>{
  status=>'complete',full_workflow=>1
 }}};
 ok(PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_report_matches($complete_archive,'full-run-1'),
  "the durable completed report is a completion receipt");
 ok(!PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_report_matches({
   run_id=>'full-run-1',report=>{completion_status=>{status=>'running',full_workflow=>1}}
  },'full-run-1'),
  "an incomplete report does not block a legitimate stage start");
 ok(!PGenReplaySandbox::webui_meter_lg_3d_autocal_completed_report_matches($complete_archive,'another-run'),
  "a different run's report does not block this run");
}

my $start=slice_between(
 $webui,
 qr/sub webui_meter_lg_3d_autocal_start \(\@\) \{/,
 qr/sub webui_meter_lg_3d_autocal_compact_status_json/
);
ok(defined($start),"3D start handler is locatable");
SKIP: {
 skip "3D start handler not locatable",2 if(!defined($start));
 my $code=code_only($start,"perl");
 my $guard=index($code,'webui_meter_lg_3d_autocal_full_run_already_complete($body)');
 my $stop=index($code,'&webui_meter_stop();');
 ok($guard>=0,"3D start handler invokes the completed-run guard");
 ok($stop>=0 && $guard<$stop,"completed-run guard executes before destructive meter teardown");
}

like($webui,qr/"already_complete":true.*webui_meter_lg_3d_autocal_full_run_already_complete/s,
 "server labels the idempotent rejection for stale-client cleanup");
like($webui,qr/if\(r&&r\.already_complete\).*?return 'already-complete';/s,
 "browser retires a rejected stale workflow without entering retry/abort");

my $ensure=slice_between(
 $webui,
 qr/function meterFullAutoCalEnsureStatusPhase\(status,phase\)\{/,
 qr/function meterFullAutoCalRestoreSavedState\(\)/
);
ok(defined($ensure),"browser phase-adoption helper is locatable");
SKIP: {
 skip "phase-adoption helper not locatable",3 if(!defined($ensure));
 my $code=code_only($ensure,"js");
 my $metadata=index($code,"if(!(status&&status.full_workflow&&meterFullAutoCalStatusPhase(status)===phase)) return false;");
 my $trusted=index($code,"if(meterFullAutoCalRunning&&currentPhase===phase) return true;");
 ok($metadata>=0,"browser requires backend workflow metadata");
 ok($trusted>=0 && $metadata<$trusted,"backend metadata is checked before saved browser phase is trusted");
 like($code,qr/currentPhase==='precal-report'\|\|currentPhase==='postcal-report'/,
  "report phases cannot adopt a calibration-stage result");
}

done_testing();

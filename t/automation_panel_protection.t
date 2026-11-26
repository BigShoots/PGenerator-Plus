use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('panel-protection-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my (@requests,$response,$saved,%run,@logs,@actions);
local *main::_api=sub {my ($method,$path,$payload)=@_;push @requests,[$path,$payload];return $response};
local *main::_write_artifact=sub {$saved=$_[1];1};
local *main::_log=sub {push @logs,$_[0]};
local *main::_log_action=sub {push @actions,$_[0]};
local *main::_refresh_control=sub {};
local *main::_update_run=sub {$_[0]->(\%run);\%run};
local *main::_run=sub {\%run};
local *main::_restore_hazards=sub {[]};

sub reset_state {@requests=();@logs=();@actions=();%run=();$saved=undef;}
my $item={signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{},warnings=>[],tv_input=>'hdmi2',panel_protection=>{disable=>1},panel_protection_supported=>1};

# Disable during TV setup
reset_state();
$response={status=>'ok',transport=>'luna',acknowledged=>0,verification_state=>'acknowledged_unverified',controls=>{tpc=>{dispatched=>1},gsr=>{dispatched=>1}}};
my $result=main::_panel_protection_disable(0,$item);
is($requests[0][0],'/api/lg/panel-protection','disable goes through the LG panel-protection route');
ok(!$requests[0][1]{enable},'disable sends enable:false');
is($saved->{outcome},'sent-unverified','artifact records a dispatch, not a verified change');
ok($run{panel_protection}{restore_pending},'run remembers that protection must be re-enabled');
is($run{panel_protection}{verification_state},'acknowledged_unverified','run state keeps the unverified label');
is_deeply($item->{warnings},[],'an expected unverifiable dispatch is not a job warning');
like(join("\n",@actions),qr/disable sent.*no readback/,'activity log explains the limitation');

# Opt-out and unsupported TVs send nothing
# Opt-in: a job that never asked (no key, empty hash) is left alone too.
for my $case ({%$item,panel_protection=>undef},{%$item,panel_protection=>{}},{%$item,panel_protection=>{disable=>0}},{%$item,panel_protection_supported=>0},{%$item,panel_protection_supported=>-1},{%$item,panel_protection_supported=>undef}) {
 reset_state();
 my $skipped=main::_panel_protection_disable(0,$case);
 ok($skipped->{skipped},'skipped without a request');
 is(scalar(@requests),0,'no TV request when the job opts out or the matrix does not review the platform');
 ok(!$run{panel_protection},'no restore is scheduled when nothing was sent');
}

# A refused disable warns but does not stop the job
reset_state();
$response={status=>'error',message=>'LG TV rejected the panel-protection disable request for gsr.',error_code=>'panel-protection-rejected'};
$item->{warnings}=[];
$result=main::_panel_protection_disable(0,$item);
ok(ref($result),'refusal still returns evidence');
is($saved->{outcome},'failed','artifact records the failure');
is_deeply($item->{warnings},['panel-protection-failed'],'job carries a visible warning');
ok($run{panel_protection}{restore_pending},'a refused compound disable may have partial effects and still requires restoration');

# Restore when the run ends
reset_state();
%run=(panel_protection=>{restore_pending=>1});
$response={status=>'ok',transport=>'luna',verification_state=>'acknowledged_unverified'};
my $failed=main::_restore_run_hazards(\%run,[$item]);
is($requests[0][0],'/api/lg/panel-protection','restore uses the same route');
ok($requests[0][1]{enable},'restore sends enable:true');
is_deeply($failed,[],'successful dispatch is not a restore failure');
ok(!$run{panel_protection}{restore_pending},'restore is no longer pending');
is($run{panel_protection}{restore_outcome},'sent-unverified','restore outcome is recorded as unverified');
is_deeply($run{hazard_restore_failures},[],'successful restoration clears any earlier failure list');

# Restore failure is visible in history
reset_state();
%run=(panel_protection=>{restore_pending=>1});
$response={status=>'error',message=>'Unable to connect to LG WebOS TV'};
$failed=main::_restore_run_hazards(\%run,[$item]);
is($failed->[0]{key},'panel_protection','failed restore is listed with other unrestored protections');
is($failed->[0]{value},'enabled','the intended restored state is recorded');
ok($run{panel_protection}{restore_pending},'restore stays pending for a later attempt');
is_deeply($run{hazard_restore_failures},$failed,'failure list reaches the run history');

# Nothing pending: no request
reset_state();
%run=();
$failed=main::_restore_run_hazards(\%run,[$item]);
is(scalar(@requests),0,'no restore request when nothing was disabled');
done_testing();

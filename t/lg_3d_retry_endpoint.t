use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();

# Executed coverage for webui_meter_lg_3d_autocal_retry_upload -- BOTH the
# dismiss branch and the config-write retry branch. These two branches
# previously carried fatal filehandle-scoping bugs (`open(my $fh,...)` used in
# the same statement / after the declaring if-condition) that perl -c cannot
# catch and that source-regex tests sailed past: the endpoint died on every
# request. This test calls the sub for real.

# The successful retry path launches the worker with system(). Intercept that
# launch before webui.pm is compiled: otherwise Ubuntu's setsid can leave the
# short-lived child visible to the next test's pgrep and make this test race.
# Recording the command still lets us verify that the endpoint requests the
# production worker without starting one on a developer machine.
our @system_calls;
BEGIN {
 no warnings 'redefine';
 *CORE::GLOBAL::system=sub { push(@main::system_calls,[@_]); return 0; };
}

my $webui="$Bin/../usr/share/PGenerator/webui.pm";
do $webui;
die $@ if($@);
die "Failed to load $webui" if(!defined(&webui_meter_lg_3d_autocal_retry_upload));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

# Stub process discovery so only state controlled by this test affects the
# endpoint. The busy-worker guard is exercised explicitly below.
my $worker_running=0;
{
 no warnings qw(redefine once);
 *main::webui_meter_lg_3d_autocal_running=sub (@) { return $worker_running; };
}

my $state_file="/tmp/meter_lg_3d_autocal.json";
my $config_file="/tmp/meter_lg_3d_autocal_config.json";

# Preserve any real files at the fixed /tmp paths (a dev box may hold state).
my %saved;
foreach my $f ($state_file,$config_file) {
 if(-f $f) {
  local $/;
  open(my $fh,"<",$f) or die "cannot save $f: $!";
  $saved{$f}=<$fh>;
  close($fh);
 }
}
END {
 foreach my $f ("/tmp/meter_lg_3d_autocal.json","/tmp/meter_lg_3d_autocal_config.json") {
  unlink($f);
  if(exists $saved{$f}) {
   open(my $fh,">",$f) or next;
   print $fh $saved{$f};
   close($fh);
  }
 }
}

my $luts=tempdir(CLEANUP=>1);
{
 no warnings 'once';
 $main::_meter_lg_3d_autocal_luts_dir=$luts;
}
my $payload_path="$luts/run.bin";
my $cube_path="$luts/run.cube";
open(my $pf,">",$payload_path) or die $!;
print $pf ("\0" x (33**3*3*2));
close($pf);
open(my $cf,">",$cube_path) or die $!;
print $cf "# cube\n";
close($cf);

my $encoder=JSON::PP->new->canonical(1);
sub write_fixture {
 my ($state,$config)=@_;
 open(my $sf,">",$state_file) or die $!;
 print $sf $encoder->encode($state);
 close($sf);
 open(my $cfh,">",$config_file) or die $!;
 print $cfh $encoder->encode($config);
 close($cfh);
}
sub base_state {
 return {
  status=>"error",
  upload_retry_available=>JSON::PP::true,
  full_autocal_run_id=>"run-abc",
  export=>{ cube_path=>$cube_path, payload_path=>$payload_path },
  upload_request=>{ upload_command=>"BT2020_3D_LUT_DATA", get_command=>"GET_3D_LUT_DATA" },
 };
}
sub base_config {
 return { method=>"matrix", upload=>JSON::PP::true, output=>"upload", full_autocal_run_id=>"run-abc" };
}

# --- guard: worker already running ---
write_fixture(base_state(),base_config());
$worker_running=1;
my $resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{}'));
is($resp->{status},'error','a running worker blocks a second retry');
like($resp->{message},qr/already running/i,'the busy-worker guard names the reason');
$worker_running=0;

# --- guard: not waiting for a retry ---
write_fixture({ status=>"complete" },base_config());
$resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{}'));
is($resp->{status},'error','a completed run is not retryable');
like($resp->{message},qr/not waiting/i,'guard names the reason');

# --- dismiss branch (previously died before writing anything) ---
write_fixture(base_state(),base_config());
$resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{"dismiss":true}'));
is($resp->{status},'ok','dismiss succeeds')
 or diag("dismiss response: ".$encoder->encode($resp));
{
 local $/;
 open(my $fh,"<",$state_file) or die $!;
 my $on_disk=JSON::PP::decode_json(<$fh>);
 close($fh);
 ok(!$on_disk->{upload_retry_available},'dismiss retires the offer on disk');
 ok($on_disk->{upload_retry_dismissed},'dismissal is recorded so refresh does not re-raise it');
}

# --- run-id mismatch ---
write_fixture(base_state(),base_config());
$resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{"run_id":"someone-else"}'));
is($resp->{status},'error','a different run cannot claim the retry');
like($resp->{message},qr/different AutoCal run/i,'mismatch is named');

# --- retry branch (previously died in the config write) ---
write_fixture(base_state(),base_config());
$resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{"run_id":"run-abc"}'));
is($resp->{status},'started','the retry transaction completes and reports started')
 or diag("retry response: ".$encoder->encode($resp));
is(scalar(@system_calls),1,'the retry requests exactly one worker launch');
like($system_calls[0]->[0],qr{/usr/bin/meter_lg_3d_autocal\.pl},'the retry launches the 3D AutoCal worker');
{
 local $/;
 open(my $fh,"<",$config_file) or die $!;
 my $cfg=JSON::PP::decode_json(<$fh>);
 close($fh);
 ok($cfg->{retry_upload_only},'config marks a retry-only run');
 is($cfg->{method},'imported','retry reuses the exact generated payload');
 is($cfg->{imported_payload_path},$payload_path,'the exact .bin path is carried');
 is($cfg->{retry_parent_method},'matrix','the parent method is preserved');
 open(my $sfh,"<",$state_file) or die $!;
 my $st=JSON::PP::decode_json(<$sfh>);
 close($sfh);
 is($st->{status},'running','state flips to running');
 is($st->{phase},'upload_retry','phase names the retry');
 ok(!$st->{upload_retry_available},'the offer is consumed');
}

# --- missing payload file fails closed ---
unlink($payload_path);
write_fixture(base_state(),base_config());
$resp=JSON::PP::decode_json(webui_meter_lg_3d_autocal_retry_upload('{}'));
is($resp->{status},'error','a missing exact payload refuses the retry');
like($resp->{message},qr/no longer available/i,'missing files are named');

done_testing();

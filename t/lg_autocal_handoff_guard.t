use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

# Executed coverage for webui_meter_lg_autocal_handoff_guard. The guard used
# to regex-match "status":"(complete|cancelled|error)" ANYWHERE in the state
# document, and the worker state embeds nested helper responses (upload_probe
# and friends) that legitimately carry their own "status":"error" -- so a
# genuinely running AutoCal could be classified as "finishing" and a follow-on
# stage told retryable:true. These fixtures pin the top-level-only contract.

my $webui="$Bin/../usr/share/PGenerator/webui.pm";
do $webui;
die $@ if($@);
die "Failed to load $webui" if(!defined(&webui_meter_lg_autocal_handoff_guard));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my $state_file="/tmp/meter_lg_autocal.json";
my %saved;
if(-f $state_file) {
 local $/;
 open(my $fh,"<",$state_file) or die "cannot save $state_file: $!";
 $saved{$state_file}=<$fh>;
 close($fh);
}
END {
 my $f="/tmp/meter_lg_autocal.json";
 unlink($f);
 if(exists $saved{$f}) {
  open(my $fh,">",$f) or last;
  print $fh $saved{$f};
  close($fh);
 }
}

my $worker_alive=1;
{
 no warnings qw(redefine once);
 *main::webui_meter_lg_autocal_running=sub (@) { return $worker_alive; };
}

sub write_state_fixture {
 my ($raw)=@_;
 open(my $fh,">",$state_file) or die $!;
 print $fh $raw;
 close($fh);
}
sub guard_response {
 my $json=webui_meter_lg_autocal_handoff_guard();
 return undef if(!defined($json));
 return JSON::PP::decode_json($json);
}

# No worker alive: no guard at all.
$worker_alive=0;
is(webui_meter_lg_autocal_handoff_guard(),undef,'no guard when no worker is alive');
$worker_alive=1;

# A RUNNING worker whose state embeds a nested error must be ACTIVE, not
# finishing -- this is the fixture the old regex misclassified.
write_state_fixture(JSON::PP::encode_json({
 status=>"running",
 phase=>"measuring",
 current_name=>"Grey ramp",
 upload_probe=>{ status=>"error", message=>"probe write rejected" },
 last_helper=>{ status=>"error" },
}));
my $r=guard_response();
is($r->{status},'error','a running worker with a nested error is still active');
is($r->{error_code},'lg-autocal-active','active error code');
ok(!$r->{retryable},'active is not retryable');

# Top-level finalising phase => retry.
write_state_fixture(JSON::PP::encode_json({ status=>"running", phase=>"finalising" }));
$r=guard_response();
is($r->{status},'retry','finalising phase is the retryable cleanup window');
is($r->{error_code},'lg-autocal-finishing','finishing error code');
ok($r->{retryable},'finishing is retryable');
cmp_ok($r->{retry_after_ms},'>=',250,'a retry delay is provided');

# Top-level terminal status with the process still briefly alive => retry.
foreach my $status (qw(complete cancelled error)) {
 write_state_fixture(JSON::PP::encode_json({ status=>$status, phase=>"complete" }));
 $r=guard_response();
 is($r->{status},'retry',"top-level '$status' with a live process is the finishing window");
}

# Corrupt state: the worker writes atomically, so undecodable means corrupt,
# not torn -- treat as active (fail closed), never as finishing.
write_state_fixture('{"status":"running","phase":"finalis');
$r=guard_response();
is($r->{status},'error','a corrupt state file reads as active, not finishing');
ok(!$r->{retryable},'corrupt state is not retryable');

done_testing();

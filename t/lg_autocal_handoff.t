use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

sub read_source {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 return $source;
}

my $worker=read_source("$Bin/../usr/bin/meter_lg_autocal.pl");
my $webui=read_source("$Bin/../usr/share/PGenerator/webui.pm");
my $lg=read_source("$Bin/../usr/share/PGenerator/lg.pm");

my $finalising_at=rindex($worker,'$state->{"phase"}="finalising"');
my $cleanup_at=$finalising_at>=0 ? index($worker,'autocal_completion_pattern_cleanup($config,$state)',$finalising_at) : -1;
my $complete_at=$cleanup_at>=0 ? index($worker,'$state->{"status"}="complete"',$cleanup_at) : -1;
ok($finalising_at>=0,'greyscale worker exposes a finalising phase');
ok($cleanup_at>$finalising_at,'TV and pattern cleanup follows the finalising state');
ok($complete_at>$cleanup_at,'complete is not published until cleanup finishes');

# Behavioural coverage lives in t/lg_autocal_handoff_guard.t (executed with
# fixtures); this only pins that the guard still inspects the decoded
# top-level phase and emits both retryable outcomes.
like($webui,qr/sub webui_meter_lg_autocal_handoff_guard \(@\).*?\$top_phase eq "finalising".*?"retryable":true.*?"retryable":false/s,
 'the server distinguishes a retryable cleanup hand-off from a genuinely active AutoCal');
like($webui,qr/sub webui_meter_lg_3d_autocal_start \(@\).*?webui_meter_lg_autocal_handoff_guard\(\)/s,
 'the greyscale-to-3D LUT boundary uses the hand-off guard');
like($lg,qr/sub webui_meter_lg_dv_profile_start \(@\).*?webui_meter_lg_autocal_handoff_guard\(\)/s,
 'the greyscale-to-Dolby Vision profile boundary uses the hand-off guard');

like($webui,qr/function meterFullAutoCalTransitionBusy\(response\).*?hasOwnProperty\.call\(response,'retryable'\).*?response\.retryable===true/s,
 'the browser honours explicit retryable true and false responses instead of relying only on message text');
like($webui,qr/async function meterDvAutoCalStartProfile\(firstStatus\).*?for\(let attempt=0;attempt<6;attempt\+\+\).*?Waiting for greyscale AutoCal cleanup/s,
 'Dolby Vision profile start retries through bounded greyscale cleanup');
like($webui,qr/async function meterDvAutoCalStartProfile\(firstStatus\).*?\/api\/lg\/dv-profile\/status.*?probe&&probe\.status==='running'/s,
 'a timed-out Dolby Vision profile start adopts an already-running worker');
like($webui,qr/async function meterStartLg3dAutoCal\(options\).*?meterFullAutoCalTransitionBusy\(r\)/s,
 'the 3D LUT hand-off consumes the structured retry response');

done_testing();

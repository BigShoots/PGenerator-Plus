use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

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

is(autocal_dpg_terminal_error('HDR20 1D DPG',1,1,'restore_upload_failed'),
 'HDR20 1D DPG upload failed: restore_upload_failed',
 'a failed final-state restore fails the greyscale stage');
like(autocal_dpg_terminal_error('SDR26 1D DPG',0,0,''),qr/white reference did not converge/,
 'non-converged white fails instead of reporting a committed curve');
ok(!defined(autocal_dpg_terminal_error('HDR20 1D DPG',0,1,'')),
 'a verified upload with converged white remains successful');

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
unlike($source,qr/lg_low_light_active_mode|lg_low_light_mode_for_reading/,
 'AutoCal no longer changes spotread averaging mode between patches');
like($source,qr/my \@layout_slots=ddc_slots_for_layout\([^\n]+\);/,
 'the Dark Detail log counts the slot list rather than its final value');
like($session_source,qr/CMD_LOW_LIGHT_MODE="\$CURRENT_LOW_LIGHT_MODE"/,
 'an omitted per-read override preserves the session averaging mode');
like($session_source,qr/release the USB interface[\s\S]{0,300}?sleep 1/,
 'meter respawn allows the USB interface to settle before reopening');

done_testing();

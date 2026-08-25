use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use JSON::PP ();
use PGAutoCalRun ();

my $runs_dir=tempdir(CLEANUP=>1);
local $PGAutoCalRun::BASE_DIR=$runs_dir;

sub read_summary {
 my ($run_id)=@_;
 my $path=PGAutoCalRun::run_dir($run_id)."/summary.json";
 open(my $fh,'<',$path) or die "Unable to read $path: $!";
 local $/;
 my $raw=<$fh>;
 close($fh);
 return JSON::PP::decode_json($raw);
}

my $complete_then_abort=PGAutoCalRun::run_begin({workflow=>'full'});
ok($complete_then_abort,'created a run for complete-then-abort ordering');
PGAutoCalRun::run_end($complete_then_abort,{status=>'complete',note=>'worker finished'});
PGAutoCalRun::run_end($complete_then_abort,{status=>'aborted',note=>'stale browser timeout'});
my $summary=read_summary($complete_then_abort);
is($summary->{status},'complete','a stale abort cannot downgrade a completed run');
is($summary->{note},'worker finished','a stale abort cannot replace the successful summary note');

my $abort_then_complete=PGAutoCalRun::run_begin({workflow=>'full'});
ok($abort_then_complete,'created a run for abort-then-complete ordering');
PGAutoCalRun::run_end($abort_then_complete,{status=>'aborted',note=>'transient browser error'});
PGAutoCalRun::run_end($abort_then_complete,{status=>'complete',note=>'worker ultimately finished'});
$summary=read_summary($abort_then_complete);
is($summary->{status},'complete','a later authoritative completion upgrades an aborted summary');
is($summary->{note},'worker ultimately finished','the completion replaces the stale abort note');

done_testing();

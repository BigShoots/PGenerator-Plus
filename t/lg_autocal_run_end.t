use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/../usr/share/PGenerator";
use JSON::PP ();
use PGAutoCalRun ();

# Executed coverage for webui_lg_autocal_run_end's attribution rules — the
# headline claim of the controller-ownership layer. The source-regex tests in
# t/lg_autocal_handoff.t prove the checks exist; this proves they work.

BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

my $runs_dir=tempdir("pgen-autocal-runs-XXXXXX",TMPDIR=>1,CLEANUP=>1);
$ENV{'PGEN_AUTOCAL_RUNS_DIR'}=$runs_dir;

my $helper="$Bin/../usr/sbin/pgenerator-lg";
{
 no warnings 'once';
 do $helper;
}
die $@ if($@);

my $lg="$Bin/../usr/share/PGenerator/lg.pm";
do $lg;
die $@ if($@);
die "Failed to load $lg" if(!defined(&webui_lg_autocal_run_end));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

# lg.pm requires PGAutoCalRun from its absolute installed path, which only
# exists on the device; this harness loaded the repo copy above, so flip the
# flag on and point the record store at the sandbox.
{
 no warnings 'once';
 $main::PGAC_LOADED=1;
 $PGAutoCalRun::BASE_DIR=$runs_dir;
}

my $decoder=JSON::PP->new;

sub summary_for {
 my ($id)=@_;
 my $path="$runs_dir/$id/summary.json";
 return undef if(!-f $path);
 open(my $fh,'<',$path) or return undef;
 local $/;
 my $text=<$fh>;
 close($fh);
 my $data;
 eval { $data=$decoder->decode($text); 1 } or return undef;
 return $data;
}

my $run_a=PGAutoCalRun::run_begin({ source => 'run-end attribution test' });
ok($run_a ne '','run A begins');
is(PGAutoCalRun::current(),$run_a,'run A is the current run');

# A delayed callback carrying a DIFFERENT run id must not touch run A.
my $stale=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted","run_id":"20200101-000000-fff000","note":"late"}'));
ok($stale->{"stale_run_ignored"},'a mismatched run id is reported as stale');
is(summary_for($run_a),undef,'run A summary is untouched by the stale callback');
is(PGAutoCalRun::current(),$run_a,'run A is still current after the stale callback');

# A callback with NO run id while a run is live is unattributed: the owning
# tab always carries the id run/begin returned, so this is a non-owner stop
# path and must neither write run A's summary nor tear its session down.
my $anon=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted"}'));
ok($anon->{"stale_run_ignored"},'an unattributed run-end is not treated as the current run');
is(summary_for($run_a),undef,'run A summary is untouched by the unattributed callback');
is(PGAutoCalRun::current(),$run_a,'run A is still current after the unattributed callback');

# The owning callback (correct run id) finalises the run.
my $done=$decoder->decode(webui_lg_autocal_run_end('{"status":"complete","run_id":"'.$run_a.'"}'));
ok(!$done->{"stale_run_ignored"},'the owning callback is honoured');
is((summary_for($run_a)||{})->{"status"},'complete','run A summary records completion');

# A late duplicate abort cannot downgrade the completed summary.
webui_lg_autocal_run_end('{"status":"aborted","run_id":"'.$run_a.'","note":"dup"}');
is((summary_for($run_a)||{})->{"status"},'complete','a late abort cannot downgrade a completed run');

done_testing();

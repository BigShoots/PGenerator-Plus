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

my $run_a=PGAutoCalRun::run_begin({
 source => 'run-end attribution test', controller_id => 'tab-owner', client_run_token => 'client-run-a'
});
ok($run_a ne '','run A begins');
is(PGAutoCalRun::current(),$run_a,'run A is the current run');

# A delayed callback carrying a DIFFERENT run id must not touch run A.
my $stale=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted","run_id":"20200101-000000-fff000","note":"late"}'));
ok($stale->{"stale_run_ignored"},'a mismatched run id is reported as stale');
is(summary_for($run_a),undef,'run A summary is untouched by the stale callback');
is(PGAutoCalRun::current(),$run_a,'run A is still current after the stale callback');

# A callback with no run id/token remains unattributed and cannot tear down
# the live run. A different per-run token is equally unable to claim it.
my $anon=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted"}'));
ok($anon->{"stale_run_ignored"},'an unattributed run-end is not treated as the current run');
is(summary_for($run_a),undef,'run A summary is untouched by the unattributed callback');
my $foreign=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted","controller_id":"tab-other","client_run_token":"client-run-other"}'));
ok($foreign->{"stale_run_ignored"},'a foreign run token cannot claim the current run');
is(summary_for($run_a),undef,'run A summary is untouched by the foreign token');
my $old_same_tab=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted","controller_id":"tab-owner","client_run_token":"client-run-old"}'));
ok($old_same_tab->{"stale_run_ignored"},'an old callback from the same tab cannot claim a newer run');
is(summary_for($run_a),undef,'run A summary is untouched by the old same-tab callback');
is(PGAutoCalRun::current(),$run_a,'run A is still current after foreign callbacks');

# If run/begin timed out after creating the record, the owner has no run id
# but its unique begin token still proves attribution.
my $done=$decoder->decode(webui_lg_autocal_run_end('{"status":"complete","controller_id":"tab-owner","client_run_token":"client-run-a"}'));
ok(!$done->{"stale_run_ignored"},'the owning begin token is honoured without a run id');
is((summary_for($run_a)||{})->{"status"},'complete','run A summary records completion');

# A late duplicate abort cannot downgrade the completed summary.
webui_lg_autocal_run_end('{"status":"aborted","run_id":"'.$run_a.'","note":"dup"}');
is((summary_for($run_a)||{})->{"status"},'complete','a late abort cannot downgrade a completed run');

# Lease adoption changes the browser controller id but preserves the unique
# begin token. The adopter must still be able to finalize a timed-out begin.
my $run_b=PGAutoCalRun::run_begin({
 source => 'run-end adoption test', controller_id => 'tab-original', client_run_token => 'client-run-b'
});
ok($run_b ne '','run B begins for adoption coverage');
my $adopted=$decoder->decode(webui_lg_autocal_run_end('{"status":"aborted","controller_id":"tab-adopter","client_run_token":"client-run-b"}'));
ok(!$adopted->{"stale_run_ignored"},'an adopter is honoured with the preserved begin token');
is((summary_for($run_b)||{})->{"status"},'aborted','the adopter finalizes the timed-out run');

done_testing();

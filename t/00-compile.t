#
# Syntax check for the files most exposed to hand surgery.
#
# Deleting a sub from an 85,000-line Perl tree is the kind of change that
# looks clean in a diff and fails at runtime on the Pi, mid-calibration. A
# compile check is cheap, needs no hardware, and catches the single most
# likely real breakage.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec ();
use lib "$FindBin::Bin/lib";
use PGenSource qw(repo_root source_path);

my $root=repo_root($Bin);

my @sources=qw(
 usr/share/PGenerator/PGAutoCalSafety.pm
 usr/share/PGenerator/lg.pm
 usr/share/PGenerator/webui.pm
 usr/bin/meter_lg_autocal.pl
 usr/bin/meter_lg_3d_autocal.pl
 usr/sbin/pgenerator-lg
 tools/check_lg_picture_mode_regression.pl
);

foreach my $relative (@sources) {
 my $path=source_path($root,$relative);
 if(!-f $path) {
  fail("$relative exists");
  next;
 }
 my $log=File::Spec->catfile(File::Spec->tmpdir(),"pgen-compile-$$-".($relative=~s{/}{_}gr).".log");
 my $rc=system(qq{"$^X" -c "$path" >"$log" 2>&1});
 my $output="";
 if(open(my $fh,"<",$log)) { local $/; $output=<$fh>; close($fh); }
 unlink($log);
 ok($rc==0 && $output=~/syntax OK/,"$relative compiles")
  or diag($output);
}

done_testing();

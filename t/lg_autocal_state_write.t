use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

# The 1D worker's status file is read concurrently by the WebUI (hand-off
# guard, status route, same-run check). write_file must therefore be atomic
# (tmp + rename) -- a truncate-in-place write let those readers see torn
# documents, which is why the hand-off guard could never trust a decode.

my $worker="$Bin/../usr/bin/meter_lg_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&write_file));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my $dir=tempdir(CLEANUP=>1);
my $path="$dir/state.json";

ok(write_file($path,'{"status":"running"}'),'a normal write succeeds');
{
 local $/;
 open(my $fh,"<",$path) or die $!;
 is(<$fh>,'{"status":"running"}','content lands intact');
 close($fh);
}
ok(!-e "$path.tmp",'no temp file is left behind');

# Overwrite is atomic: the target either holds the old or the new document,
# and the tmp staging file never survives.
ok(write_file($path,'{"status":"complete"}'),'overwrite succeeds');
{
 local $/;
 open(my $fh,"<",$path) or die $!;
 is(<$fh>,'{"status":"complete"}','overwrite replaces the whole document');
 close($fh);
}

ok(!write_file("$dir/missing-subdir/state.json",'x'),'an unwritable destination reports failure instead of pretending');
ok(!write_file("",'x'),'an empty path reports failure');

done_testing();

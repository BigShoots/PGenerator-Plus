use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

$ENV{"PYTHONDONTWRITEBYTECODE"}=1;
my $python=$ENV{"PGEN_PYTHON"} || "python3";
my $test="$Bin/icc_companion_streaming.py";
my $output=`$python "$test" 2>&1`;
my $status=$?;

is($status,0,"Companion streaming harness exits successfully") or diag($output);
like($output,qr/Companion streaming parity and safety passed; peak_rss_bytes=\d+/,
 "65/129 cube bytes, PGLT bytes, bounded RSS and atomic failure safety hold");

done_testing();

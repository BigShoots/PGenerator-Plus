use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# Keeps the harness from writing usr/bin/__pycache__ into the source tree.
$ENV{"PYTHONDONTWRITEBYTECODE"}=1;

my $python=$ENV{"PGEN_PYTHON"} || "python3";
my $test="$Bin/icc_numpy_parity.py";
my $output=`$python "$test" 2>&1`;
my $status=$?;

is($status,0,'NumPy ICC parity harness exits successfully') or diag($output);
like($output,qr/^\d+ exact vector\/scalar parity checks passed\s*$/,
     'NumPy ICC primitives retain the pre-rewrite operation and serialisation results');

done_testing();

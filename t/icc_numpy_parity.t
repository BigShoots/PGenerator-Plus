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
like($output,qr/^\d+ vector\/scalar parity checks passed \(\d+ exact, \d+ within one ulp\)\s*$/,
     'NumPy ICC primitives retain the pre-rewrite operation and serialisation results');
# The one-ulp allowance exists only for the two array-versus-scalar pow
# comparisons (see the note in icc_numpy_parity.py). Pin the count so widening
# it has to be a deliberate edit here as well.
like($output,qr/\(\d+ exact, 2 within one ulp\)/,
     'only the two pow comparisons are allowed a one-ulp difference');

done_testing();

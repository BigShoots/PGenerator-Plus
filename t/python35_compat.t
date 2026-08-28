use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

$ENV{"PYTHONDONTWRITEBYTECODE"}=1;

my $python=$ENV{"PGEN_PYTHON"} || "python3";
my $guard="$Bin/python35_compat.py";
my $output=`$python "$guard" 2>&1`;
my $status=$?;

is($status,0,'on-device Python stays within the appliance interpreters')
 or diag($output);
like($output||"",qr/^\d+ on-device Python files parse within the appliance's syntax\s*$/,
 'the syntax guard checked every usr/bin Python file');

done_testing();

use strict;
use warnings;

use FindBin qw($Bin);
use JSON::PP ();
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
use PGMath qw(delta_e_2000_lab xyz_to_lab);

open my $fh, "<", "$Bin/fixtures/ciede2000_sharma.json"
    or die "cannot read CIEDE2000 fixture: $!";
local $/;
my $fixture = JSON::PP::decode_json(<$fh>);
close $fh;

for my $index (0..$#{$fixture->{pairs}}) {
    my $row = $fixture->{pairs}[$index];
    my $actual = delta_e_2000_lab($row->{first}, $row->{second});
    cmp_ok(abs($actual - $row->{delta_e}), "<=", 0.00005,
           "Perl CIEDE2000 matches published pair $index");
}

my $signed = xyz_to_lab([-1, 0, 2], [95.047, 100, 108.883],
                        "signed_linear");
for my $index (0..2) {
    my @expected = (0, -40.964138989326536, -25.183737285448217);
    cmp_ok(abs($signed->[$index] - $expected[$index]), "<=", 2e-12,
           "Perl signed-linear XYZ-to-Lab component $index is pinned");
}

my $root = "$Bin/..";
my $python = $ENV{PGEN_PYTHON} || "python3";
my $status = system($python, "$Bin/ciede2000_conformance.py");
is($status, 0, "Python CIEDE2000 and ratio-floor policies pass");

for my $relative (qw(usr/bin/meter_lg_3d_autocal.pl usr/bin/icc_finetune.py)) {
    open my $source_fh, "<", "$root/$relative" or die "cannot read $relative: $!";
    local $/;
    my $source = <$source_fh> // "";
    close $source_fh;
    unlike($source, qr/^\s*(?:sub|def)\s+(?:xyz_to_lab|_lab|delta_e_2000|de2000)\b/m,
           "$relative has no private Lab or CIEDE2000 implementation");
}

done_testing();

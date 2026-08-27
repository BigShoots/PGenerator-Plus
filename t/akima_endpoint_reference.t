use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $worker="$Bin/../usr/bin/meter_lg_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&lg_autocal_26_akima_interpolate));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

# Reference values from scipy.interpolate.Akima1DInterpolator(method="akima").
# The sparse, strongly curved fixture magnifies the endpoint convention error:
# the old transposed left padding missed these values by as much as 793 units.
my @xs=(0,300,700,1023);
my @ys=(0,2000,18000,32767);
my $actual=lg_autocal_26_akima_interpolate(\@xs,\@ys,0,1023);
my %reference=(
 0=>0,
 1=>-9.9835992168009025,
 50=>-442.95637105354081,
 100=>-706.34927626021931,
 200=>-301.58744140932754,
 299=>1965.0149452876415,
 300=>2000,
 350=>3786.4584709706405,
 500=>9511.9050765043212,
 699=>17955.13125313813,
 700=>18000,
 900=>26984.536525603162,
 1023=>32767,
);

is(scalar(@$actual),1024,'Akima reference covers the requested index range');
for my $index (sort {$a <=> $b} keys %reference) {
 cmp_ok(abs($actual->[$index]-$reference{$index}),'<',1e-9,
        "Akima matches the SciPy reference at index $index");
}

done_testing();

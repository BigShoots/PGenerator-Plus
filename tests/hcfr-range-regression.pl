use strict;
use warnings;

my $path = 'usr/share/PGenerator/daemon.pm';
open(my $fh, '<', $path) or die "Failed to open $path: $!\n";
local $/;
my $source = <$fh>;
close($fh);

sub extract_between {
 my ($start, $end) = @_;
 my $start_idx = index($source, $start);
 die "Missing block start: $start\n" if $start_idx < 0;
 my $end_idx = index($source, $end, $start_idx);
 die "Missing block end: $end\n" if $end_idx < 0;
 return substr($source, $start_idx, $end_idx - $start_idx);
}

my $triplet_sub = extract_between('sub legacy_external_hcfr_triplet_quant_range', 'sub legacy_external_hcfr_quant_range');
my $quant_sub = extract_between('sub legacy_external_hcfr_quant_range', 'sub legacy_external_hcfr_source_range');
my $source_sub = extract_between('sub legacy_external_hcfr_source_range', 'sub legacy_external_hcfr_template_payload');

my $loaded = eval "$triplet_sub\n$quant_sub\n$source_sub\n1;";
die "Failed to load HCFR range helpers: $@\n" if !$loaded;

sub assert_eq {
 my ($actual, $expected, $message) = @_;
 die "$message\nExpected: [$expected]\nActual:   [$actual]\n" if $actual ne $expected;
}

assert_eq(legacy_external_hcfr_quant_range('128,128,128;16,16,16'), '1', 'HCFR limited background should force limited-range detection for midtone patches');
assert_eq(legacy_external_hcfr_source_range('128,128,128;16,16,16'), 'LIMITED', 'HCFR limited background should emit SOURCE_RANGE=LIMITED');
assert_eq(legacy_external_hcfr_quant_range('128,128,128;0,0,0'), '', 'HCFR black backgrounds must not force full-range detection when the patch itself is midtone');
assert_eq(legacy_external_hcfr_quant_range('128,128,128;-1,-1,-1'), '', 'HCFR sentinel backgrounds must not be mistaken for full range');
assert_eq(legacy_external_hcfr_quant_range('0,0,0;255,255,255'), '2', 'HCFR full-range foreground should still be detected as full range');

print "HCFR range regression checks passed.\n";
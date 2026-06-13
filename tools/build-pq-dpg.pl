#!/usr/bin/perl
use strict;
use warnings;

# Build a PQ-encoded 1D DPG that should match the panel's baseline if
# the panel's 1D DPG is a PQ-input lookup.
#
# Formula:
#   dpg[ch, i] = pq_encode( (i/1023)^2.2 * white_y / peak ) * per_channel_top[ch]
#
# where:
#   pq_encode   = ST 2084 transfer function (nits -> normalized 0..1)
#   white_y     = calibrated white luminance (e.g. 729 cd/m^2)
#   peak        = panel peak luminance (e.g. 1000 for LG C2 HDR)
#   per_channel_top[ch] = (32767, 31243, 26818) for (R, G, B) from baseline readback
#
# Note: this assumes a 15-bit 1D_DPG_DATA scale (max 32767), not 16-bit.
# The existing code caps at 32767 anyway. The "unity" reference (32767) maps
# to 50% of PQ range (since 32767/65535 = 0.5 -> PQ(0.5) ~= 0.5 of peak).
# So the baseline DPG at unity means the panel is at 50% of its peak
# at i=1023, which matches white_y = peak/2.

# PQ parameters from ST 2084 (inlined into the function)
sub pq_encode_normalized {
    my ($nits, $peak) = @_;
    return 0 if !defined $nits || $nits <= 0;
    $nits = $peak if $nits > $peak;
    my $l = $nits / $peak;
    my $p = $l ** (2610/16384);
    my $num = (3424/4096) + (2413/128) * $p;
    my $den = 1 + (2392/128) * $p;
    return ($num / $den) ** (2523/32);
}

my $gamma = $ARGV[0] // 2.2;
my $white_y = $ARGV[1] // 729;     # cd/m^2 -- matches the 3rd autocal's calibrated_white_luminance
my $peak = $ARGV[2] // 1000;      # cd/m^2 -- typical LG C2 HDR peak
my $out = $ARGV[3] // "/tmp/dpg-pq-g22-w729-p1000.bin";

my @tops = (32767, 31243, 26818);

my @new;
for my $idx (0..3071) {
    my $i = $idx % 1024;
    my $ch = int($idx / 1024);
    my $g = ($i / 1023) ** $gamma;
    my $target_nits = $g * $white_y;
    my $pq = pq_encode_normalized($target_nits, $peak);
    my $v = int($pq * $tops[$ch] + 0.5);
    $v = 0 if $v < 0;
    $v = 32767 if $v > 32767;
    push @new, $v;
}

open my $outf, ">", $out or die $!;
binmode $outf;
print $outf pack("v*", @new);
close $outf;

printf "wrote %d values to %s (gamma=%g, white_y=%g, peak=%g)\n", scalar(@new), $out, $gamma, $white_y, $peak;
printf "min=%d max=%d\n", (sort { $a <=> $b } @new)[0], (sort { $b <=> $a } @new)[0];
for my $i (0, 14, 51, 257, 514, 715, 1023) {
    printf "idx=%-4d  R:%5d  G:%5d  B:%5d\n",
        $i, $new[$i], $new[1024+$i], $new[2048+$i];
}

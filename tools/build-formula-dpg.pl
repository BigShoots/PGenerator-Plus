#!/usr/bin/perl
use strict;
use warnings;

# Build a "corrected formula" 1D DPG: for each LUT index i, value = (i/1023)^gamma * per_channel_top
# Per-channel top from the baseline readback (R=32767, G=31243, B=26818 at idx=1023).
# Each channel uses its own top to preserve the panel's natural white point.
# Note: this is GAMMA-2.2 in linear-light domain, which may or may not match
# the panel's actual transfer function (likely PQ for HDR10). Experiment 2
# is to upload this and see what the panel does vs the baseline.

my $gamma = $ARGV[0] // 2.2;
my $out = $ARGV[1] // "/tmp/dpg-formula-g22.bin";

my @tops = (32767, 31243, 26818);  # R, G, B top values from baseline

open my $in, "<", "/tmp/dpg-baseline.bin" or die $!;
binmode $in;
read $in, my $raw, 6144;
close $in;
my @base = unpack("v*", $raw);

my @new;
for my $idx (0..3071) {
    my $i = $idx % 1024;
    my $ch = int($idx / 1024);
    my $g = ($i / 1023) ** $gamma;
    my $v = int($g * $tops[$ch] + 0.5);
    $v = 0 if $v < 0;
    $v = 32767 if $v > 32767;
    push @new, $v;
}

open my $outf, ">", $out or die $!;
binmode $outf;
print $outf pack("v*", @new);
close $outf;

print "wrote ", scalar(@new), " values to $out (gamma=$gamma)\n";
print "min=", (sort { $a <=> $b } @new)[0], " max=", (sort { $b <=> $a } @new)[0], "\n";
for my $i (0, 14, 51, 257, 514, 715, 1023) {
    printf "idx=%-4d  R:%5d  G:%5d  B:%5d\n",
        $i, $new[$i], $new[1024+$i], $new[2048+$i];
}

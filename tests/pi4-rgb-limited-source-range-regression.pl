#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

for my $source (
    'src/pattern_generator/src/ofApp.cpp',
    'tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.cpp',
) {
    open my $fh, '<', $source or die "open $source: $!";
    local $/;
    my $cpp = <$fh>;
    close $fh;

    like(
        $cpp,
        qr/\(long long\)\(value - limited_min\) \* max_value \+\s*limited_span \/ 2\) \/ limited_span/s,
        "$source uses integer nearest rounding",
    );
    like(
        $cpp,
        qr/if\(ofxRPI4Window::isDoVi \|\| ofxRPI4Window::is_std_DoVi\)\s+return value;/s,
        "$source keeps Dolby Vision source codes unchanged",
    );
}

for my $bits (8, 10) {
    my $shift = $bits - 8;
    my $minimum = 16 << $shift;
    my $span = 219 << $shift;
    my $maximum = (1 << $bits) - 1;

    is(expand_limited($minimum, $minimum, $span, $maximum), 0,
       "$bits-bit legal black expands to framebuffer zero");
    is(expand_limited($minimum + $span, $minimum, $span, $maximum), $maximum,
       "$bits-bit legal white expands to framebuffer maximum");

    my @mismatches;
    for my $wire ($minimum .. $minimum + $span) {
        my $framebuffer = expand_limited($wire, $minimum, $span, $maximum);
        my $round_trip = int($minimum + $framebuffer * $span / $maximum + 0.5);
        push @mismatches, "$wire->$framebuffer->$round_trip"
            if $round_trip != $wire;
    }
    is_deeply(\@mismatches, [], "$bits-bit legal codes survive limited CSC round trip");
}

is(
    int(16 + 16 * 219 / 255 + 0.5),
    30,
    'old passthrough would double-compress 8-bit code 16 to lifted code 30',
);

done_testing();

sub expand_limited {
    my ($value, $minimum, $span, $maximum) = @_;
    my $expanded = int((($value - $minimum) * $maximum + int($span / 2)) / $span);
    $expanded = 0 if $expanded < 0;
    $expanded = $maximum if $expanded > $maximum;
    return $expanded;
}

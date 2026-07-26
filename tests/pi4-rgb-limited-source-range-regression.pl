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
    like(
        $cpp,
        qr/normalizeImageSourcePixels\(arr_source_range\[i\]\[to_draw\]\)/,
        "$source normalizes IMAGE texels using their SOURCE_RANGE",
    );
    like(
        $cpp,
        qr/\(\(value - 16\) \* 255 \+ 219 \/ 2\) \/ 219/,
        "$source expands 8-bit studio IMAGE texels with nearest rounding",
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

is(expand_image_limited(0), 0, 'IMAGE footroom clamps to framebuffer black');
is(expand_image_limited(16), 0, 'IMAGE legal black expands to framebuffer zero');
is(expand_image_limited(235), 255, 'IMAGE legal white expands to framebuffer maximum');
is(expand_image_limited(255), 255, 'IMAGE headroom clamps to framebuffer white');

my @image_mismatches;
for my $wire (16 .. 235) {
    my $framebuffer = expand_image_limited($wire);
    my $round_trip = int(16 + $framebuffer * 219 / 255 + 0.5);
    push @image_mismatches, "$wire->$framebuffer->$round_trip"
        if $round_trip != $wire;
}
is_deeply(\@image_mismatches, [], '8-bit studio IMAGE texels survive limited CSC round trip');

done_testing();

sub expand_limited {
    my ($value, $minimum, $span, $maximum) = @_;
    my $expanded = int((($value - $minimum) * $maximum + int($span / 2)) / $span);
    $expanded = 0 if $expanded < 0;
    $expanded = $maximum if $expanded > $maximum;
    return $expanded;
}

sub expand_image_limited {
    my ($value) = @_;
    my $expanded = int((($value - 16) * 255 + int(219 / 2)) / 219);
    $expanded = 0 if $expanded < 0;
    $expanded = 255 if $expanded > 255;
    return $expanded;
}

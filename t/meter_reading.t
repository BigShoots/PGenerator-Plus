use strict;
use warnings;

use FindBin qw($Bin);
use JSON::PP ();
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
my $loaded = eval {
    require PGMeterReading;
    PGMeterReading->import(qw(reading_xyz));
    1;
};
ok($loaded, "shared meter-reading module loads") or diag($@);

SKIP: {
    skip "PGMeterReading is not available", 21 unless $loaded;

    is_deeply(reading_xyz({ X => "1.25", Y => 2, Z => 3.5 }),
              [1.25, 2, 3.5],
              "complete direct XYZ returns a finite array reference");
    is_deeply(reading_xyz({
                  X => 1, Y => 2, Z => 3,
                  x => "not-used", y => JSON::PP::true,
                  luminance => "1e9999",
              }), [1, 2, 3],
              "complete direct XYZ wins without validating unused xyY fields");
    is_deeply(reading_xyz({ x => 0.25, y => 0.5, luminance => 4, Y => 99 }),
              [2, 4, 2],
              "xy plus luminance is the preferred fallback representation");
    is_deeply(reading_xyz({ x => 0.25, y => 0.5, Y => 4 }),
              [2, 4, 2],
              "xy plus direct Y remains the compatibility fallback");
    is_deeply(reading_xyz({ X => "unused", x => 0.25, y => 0.5, Y => 4 }),
              [2, 4, 2],
              "an incomplete direct representation does not poison valid xyY");

    ok(!defined(reading_xyz([])), "a non-record is rejected");
    ok(!defined(reading_xyz({ X => 1, Y => 2 })),
       "an incomplete record without xyY is rejected");
    ok(!defined(reading_xyz({ x => 0.25, y => 0, luminance => 4 })),
       "xyY rejects a zero y denominator");
    ok(!defined(reading_xyz({ x => -0.1, y => 0.5, luminance => 4 })),
       "xyY rejects chromaticity below its domain");
    ok(!defined(reading_xyz({ x => 1.1, y => 0.5, luminance => 4 })),
       "xyY rejects chromaticity above its domain");
    ok(!defined(reading_xyz({ x => 0.25, y => 0.5, luminance => -0.1 })),
       "xyY rejects negative luminance");
    ok(!defined(reading_xyz({ x => 0.25, y => 0.5, luminance => 10_000_001 })),
       "xyY rejects luminance outside the meter domain");

    for my $case (
        ["NaN", "NaN"],
        ["positive infinity", "Inf"],
        ["negative infinity", "-Inf"],
        ["huge exponent", "1e9999"],
        ["empty value", ""],
        ["boolean", JSON::PP::true],
    ) {
        my ($name, $bad) = @{$case};
        ok(!defined(reading_xyz({ X => $bad, Y => 2, Z => 3 })),
           "direct XYZ rejects $name");
    }
    ok(!defined(reading_xyz({ X => 10_000_001, Y => 2, Z => 3 })),
       "direct XYZ rejects a component outside the meter domain");
    ok(!defined(reading_xyz({ x => 0.25, y => JSON::PP::false, luminance => 4 })),
       "xyY rejects boolean numeric fields");
    ok(!defined(reading_xyz({ x => 0.25, y => 0.5, luminance => "1e9999" })),
       "xyY rejects non-finite luminance before multiplication");
}

for my $worker (qw(meter_lg_autocal.pl meter_lg_3d_autocal.pl)) {
    my $path = "$Bin/../usr/bin/$worker";
    open my $fh, "<", $path or die "cannot read $path: $!";
    local $/;
    my $source = <$fh> // "";
    close $fh;
    like($source, qr/use PGMeterReading qw\(reading_xyz\)/,
         "$worker imports the required meter-reading normalizer");
    unlike($source, qr/sub\s+reading_xyz\s*\{/,
           "$worker has no private reading_xyz body");
}

{
    package MeterReadingOwner1D;
    local @ARGV = ();
    do "$main::Bin/../usr/bin/meter_lg_autocal.pl" or die($@ || $!);
}
{
    package MeterReadingOwner3D;
    local @ARGV = ();
    do "$main::Bin/../usr/bin/meter_lg_3d_autocal.pl" or die($@ || $!);
}
is(\&MeterReadingOwner1D::reading_xyz, \&PGMeterReading::reading_xyz,
   "1D AutoCal calls the shared meter-reading owner directly");
is(\&MeterReadingOwner3D::reading_xyz, \&PGMeterReading::reading_xyz,
   "3D AutoCal calls the shared meter-reading owner directly");

done_testing();

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
my $loaded = eval {
    require PGCalibrationMath;
    PGCalibrationMath->import(qw(smooth_dpg_low_end));
    1;
};
ok($loaded, "shared calibration-math module loads") or diag($@);

SKIP: {
    skip "PGCalibrationMath is not available", 8 unless $loaded;
    my @input;
    for my $channel (0..2) {
        for my $index (0..1023) {
            push @input, int($index * 64 + $channel * 3
                             + (($index % 17) == 0 ? 50 : 0));
        }
    }
    my ($output, $changed) = smooth_dpg_low_end(\@input);
    is($changed, 439, "DPG snapshot changes the established number of entries");
    is(sha256_hex(pack("n*", @{$output})),
       "34e93571f799750b16b79afcc504dfe86ab31db0f7d43e8a1ddb50fb93e9b03b",
       "DPG output remains byte-identical to both pre-move worker owners");
    is_deeply([map { $output->[$_ * 1024] } 0..2],
              [map { $input[$_ * 1024] } 0..2],
              "each channel keeps its black entry pinned");
    my $tail_unchanged = 1;
    for my $channel (0..2) {
        for my $index (281..1023) {
            $tail_unchanged = 0
                if $output->[$channel * 1024 + $index]
                   != $input[$channel * 1024 + $index];
        }
    }
    ok($tail_unchanged, "entries above the blend boundary are byte-identical");
    my $bounded_monotonic = 1;
    for my $channel (0..2) {
        for my $index (1..1023) {
            my $value = $output->[$channel * 1024 + $index];
            my $prior = $output->[$channel * 1024 + $index - 1];
            $bounded_monotonic = 0 if $value < $prior || $value < 0 || $value > 65535;
        }
    }
    ok($bounded_monotonic, "every smoothed channel is bounded and monotonic");
    my $invalid = [1, 2, 3];
    my ($invalid_out, $invalid_changed) = smooth_dpg_low_end($invalid);
    is($invalid_out, $invalid, "invalid DPG length returns the caller's record unchanged");
    is($invalid_changed, 0, "invalid DPG length reports no changes");
    my ($not_array, $not_array_changed) = smooth_dpg_low_end("invalid");
    is($not_array, "invalid", "non-array input follows the established fail-safe contract");
    is($not_array_changed, 0, "non-array input reports no changes");
}

for my $worker (qw(meter_lg_autocal.pl meter_lg_3d_autocal.pl)) {
    my $path = "$Bin/../usr/bin/$worker";
    open my $fh, "<", $path or die "cannot read $path: $!";
    local $/;
    my $source = <$fh> // "";
    close $fh;
    like($source, qr/use PGCalibrationMath qw\([\s\S]*?smooth_dpg_low_end/,
         "$worker imports the shared DPG owner");
    unlike($source, qr/sub\s+lg_autocal_26_smooth_dpg_low_end\s*\{/,
           "$worker has no private DPG smoother body");
}

done_testing();

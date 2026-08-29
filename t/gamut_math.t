use strict;
use warnings;

use FindBin qw($Bin);
use Scalar::Util qw(refaddr);
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
use PGCalibrationMath qw(
 calibration_rgb_to_xyz_matrix
 named_gamut_matrix
 standard_gamut_record
 standard_gamut_records
);

sub matrix_close {
    my ($actual, $expected, $label) = @_;
    my $ok = ref($actual) eq "ARRAY" && @{$actual} == 3;
    for my $row (0..2) {
        $ok &&= ref($actual->[$row]) eq "ARRAY" && @{$actual->[$row]} == 3;
        for my $column (0..2) {
            next unless $ok;
            my $scale = abs($expected->[$row][$column]) > 1
                ? abs($expected->[$row][$column]) : 1;
            $ok = 0 if abs($actual->[$row][$column] - $expected->[$row][$column])
                       > 2e-15 * $scale;
        }
    }
    ok($ok, $label);
}

my $records = standard_gamut_records();
is_deeply([sort keys %{$records}], [qw(bt2020 bt709 p3d65 p3dci)],
          "the four standard gamut records have one owner");
is_deeply($records->{bt709}{WHITE}, ["0.3127", "0.3290"],
          "BT.709 keeps the browser literal precision");
is_deeply($records->{bt709}{RGB_TO_XYZ}[0],
          ["0.4124564", "0.3575761", "0.1804375"],
          "BT.709 keeps its fixed precomputed matrix provenance");

$records->{bt709}{WHITE}[0] = "mutated";
is(standard_gamut_record("bt709")->{WHITE}[0], "0.3127",
   "callers cannot mutate the fixed gamut owner through returned records");

my %expected = (
    bt709 => [
        [0.41239079926595928, 0.35758433938387801, 0.18048078840183429],
        [0.21263900587151024, 0.71516867876775603, 0.072192315360733714],
        [0.019330818715591822, 0.11919477979462598, 0.9505321522496607],
    ],
    p3d65 => [
        [0.48657094864821604, 0.26566769316909306, 0.19821728523436249],
        [0.22897456406974873, 0.6917385218365063, 0.079286914093744998],
        [-3.9720755169334861e-17, 0.045113381858902631, 1.043944368900976],
    ],
    p3dci => [
        [0.44516981556455243, 0.27713440920677768, 0.17228266981556453],
        [0.20949167791273055, 0.72159525416104364, 0.068913067926225813],
        [-3.6341013169698565e-17, 0.047060560053981154, 0.90735539436197332],
    ],
    bt2020 => [
        [0.6369580483012911, 0.14461690358620835, 0.16888097516417208],
        [0.26270021201126698, 0.67799807151887093, 0.059301716469861952],
        [4.9941065744660742e-17, 0.028072693049087435, 1.0609850577107909],
    ],
);
for my $name (qw(bt709 p3d65 p3dci bt2020)) {
    matrix_close(named_gamut_matrix($name, matrix_source => "derived",
                                    caller_contract => "autocal3d"),
                 $expected{$name},
                 "$name derived matrix preserves the pre-move 3D result");
}

my $fixed = named_gamut_matrix("bt709", matrix_source => "precomputed",
                               coefficient_version => "webui-v1");
is($fixed->[0][0], 0.4124564,
   "fixed lookup returns the precomputed BT.709 coefficient");
isnt($fixed->[0][0], $expected{bt709}[0][0],
     "precomputed and derived matrix provenance cannot collide");
ok(!defined(named_gamut_matrix("custom", matrix_source => "precomputed")),
   "arbitrary gamut names never enter the bounded fixed lookup");

my $sim_definition = {
    red => [0.646, 0.332], green => [0.292, 0.612],
    blue => [0.155, 0.061], white => [0.3160, 0.3295],
};
my $sim_expected = [
    [0.4361533863651621, 0.33487399732203565, 0.18800144787577636],
    [0.22415313354989755, 0.70185919986673229, 0.073987666583370054],
    [0.014853520897884753, 0.11009556076340897, 0.95092345248134624],
];
my %request_cache;
my $sim_first = calibration_rgb_to_xyz_matrix(
    $sim_definition, caller_contract => "spotread_sim",
    context_cache => \%request_cache,
);
my $sim_second = calibration_rgb_to_xyz_matrix(
    $sim_definition, caller_contract => "spotread_sim",
    context_cache => \%request_cache,
);
matrix_close($sim_first, $sim_expected,
             "spotread simulator keeps reciprocal reduction and cutoff");
is(refaddr($sim_first), refaddr($sim_second),
   "custom matrices are reused within their request context");
is(scalar(keys %request_cache), 1,
   "a custom request cache keys the complete numerical policy once");

my $singular = {
    red => [0.64, 0.33], green => [0.64, 0.33],
    blue => [0.15, 0.06], white => [0.3127, 0.3290],
};
ok(!defined(calibration_rgb_to_xyz_matrix(
       $singular, caller_contract => "spotread_sim")),
   "spotread simulator returns undef for singular primaries");
my $autocal_singular = calibration_rgb_to_xyz_matrix(
    $singular, caller_contract => "autocal3d");
ok(ref($autocal_singular) eq "ARRAY",
   "3D AutoCal retains its singular scaling fallback");
ok(!defined(calibration_rgb_to_xyz_matrix(
       { %{$sim_definition}, white => [0.3, 0] },
       caller_contract => "spotread_sim")),
   "custom construction rejects an out-of-domain white denominator");

my %sources;
for my $relative (qw(
    usr/bin/meter_lg_3d_autocal.pl
    usr/bin/spotread_sim
    usr/share/PGenerator/webui.pm
    usr/sbin/pgenerator-lg
)) {
    my $path = "$Bin/../$relative";
    open my $fh, "<", $path or die "cannot read $path: $!";
    local $/;
    $sources{$relative} = <$fh> // "";
    close $fh;
}
like($sources{"usr/share/PGenerator/webui.pm"},
     qr/standard_gamut_records\(\)/,
     "the Web UI assembles its browser literal from the standard owner");
unlike($sources{"usr/share/PGenerator/webui.pm"},
       qr/RGB_TO_XYZ\s*=>\s*\[\['0\.4124564'/,
       "the Web UI has no private standard matrix records");
like($sources{"usr/bin/meter_lg_3d_autocal.pl"},
     qr/named_gamut_matrix\([^\n]+matrix_source=>"derived"/,
     "3D AutoCal requests the named derived-matrix provenance");
unlike($sources{"usr/bin/meter_lg_3d_autocal.pl"},
       qr/sub\s+(?:gamut_xy_definition|xy_to_xyz_unit)\s*\{/,
       "3D AutoCal has no private gamut construction primitives");
unlike($sources{"usr/bin/spotread_sim"},
       qr/sub\s+(?:rgb_to_xyz_matrix|_mat3_inverse)\s*\{/,
       "the simulator has no private primaries-plus-white builder");
like($sources{"usr/sbin/pgenerator-lg"},
     qr/caller_contract=>"dolby_vision_profile"/,
     "the Dolby Vision path selects direct cofactor division explicitly");

done_testing();

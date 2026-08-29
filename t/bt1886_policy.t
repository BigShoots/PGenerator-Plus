use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;
use lib "$Bin/../usr/share/PGenerator";
use PGMath qw(
 bt1886_luminance_1d_ab
 bt1886_relative_luminance_3d_root_blend
);

sub fixture {
 my $path="$Bin/fixtures/bt1886_policy_conformance.json";
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 return decode_json(<$fh>);
}

sub formatted {
 my ($value)=@_;
 return "NaN" if($value != $value);
 return sprintf("%.17g",$value);
}

my $fixture=fixture();
for my $row (@{$fixture->{"one_d_ab"}}) {
 is(formatted(bt1886_luminance_1d_ab(
  $row->{"signal"},$row->{"white_y"},$row->{"black_y"})),
  $row->{"expected"},"1D a/b order preserves $row->{name}");
}
for my $row (@{$fixture->{"three_d_root_blend_relative"}}) {
 is(formatted(bt1886_relative_luminance_3d_root_blend(
  $row->{"signal"},$row->{"white_y"},$row->{"black_y"})),
  $row->{"expected"},"3D root-blend order preserves $row->{name}");
}

ok(!defined(bt1886_luminance_1d_ab(0.5,undef,0)),
 "1D policy rejects a missing white");
ok(!defined(bt1886_luminance_1d_ab(0.5,0,0)),
 "1D policy rejects a non-positive white");
is(formatted(bt1886_relative_luminance_3d_root_blend(0.5,undef,0)),
 "0.18946457081379975","3D policy retains its 100-nit missing-white fallback");
is(formatted(bt1886_relative_luminance_3d_root_blend(0.5,0,0)),
 "0.18946457081379975","3D policy retains its 100-nit non-positive-white fallback");

my $worker1d="$Bin/../usr/bin/meter_lg_autocal.pl";
my $worker3d="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
local $/;
open(my $one_fh,"<",$worker1d) or die "Unable to read $worker1d: $!";
my $one_source=<$one_fh>;
close($one_fh);
open(my $three_fh,"<",$worker3d) or die "Unable to read $worker3d: $!";
my $three_source=<$three_fh>;
close($three_fh);
unlike($one_source,qr/^sub\s+bt1886_eotf_luminance\b/m,
 "1D worker has no private BT.1886 a/b implementation");
unlike($three_source,qr/^sub\s+bt1886_(?:luminance_y|relative_luminance)\b/m,
 "3D worker has no private BT.1886 root-blend implementation");

done_testing();

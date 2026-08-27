use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();

use lib "$Bin/../usr/share/PGenerator";
use PGMath qw(
 akima_interpolate bradford_adapt_xyz delta_e_itp_xyz matrix3_inverse
 matrix3_vector_multiply pq_decode_nits pq_encode_normalized xyz_to_ictcp
);

my $root="$Bin/..";
my $fixture_path="$Bin/fixtures/math_conformance.json";
open(my $fixture_fh,"<",$fixture_path) or die "Unable to read $fixture_path: $!";
local $/;
my $fixture=JSON::PP::decode_json(<$fixture_fh>);
close($fixture_fh);

sub close_enough {
 my ($actual,$expected,$label)=@_;
 my $scale=abs($expected)>1 ? abs($expected) : 1;
 cmp_ok(abs($actual-$expected),"<=",2e-12*$scale,$label);
}
is_deeply(akima_interpolate(undef,undef),[],
 "shared Akima rejects missing arrays without dereferencing them");
is_deeply(akima_interpolate([0,1,2],[0,1]),[],
 "shared Akima rejects mismatched arrays");
is_deeply(akima_interpolate([0,1,2],[0,1,2]),[],
 "shared Akima leaves underspecified interpolation to the linear fallback");
is_deeply(akima_interpolate([0,1,2,3],[0,10,20,30],0,3),[0,10,20,30],
 "shared Akima preserves a linear series exactly");

foreach my $row (@{$fixture->{"pq_encode"}}) {
 close_enough(pq_encode_normalized($row->{"nits"}),$row->{"signal"},
  "Perl PQ encodes $row->{nits} cd/m2");
}
foreach my $row (@{$fixture->{"pq_decode"}}) {
 close_enough(pq_decode_nits($row->{"signal"}),$row->{"nits"},
  "Perl PQ decodes signal $row->{signal}");
}

my $inverse=matrix3_inverse($fixture->{"matrix"});
for my $row (0..2) {
 for my $column (0..2) {
  close_enough($inverse->[$row][$column],$fixture->{"inverse"}[$row][$column],
   "Perl shared 3x3 inverse [$row][$column]");
 }
}
my $product=matrix3_vector_multiply($fixture->{"matrix"},$fixture->{"vector"});
for my $row (0..2) {
 close_enough($product->[$row],$fixture->{"product"}[$row],
  "Perl shared matrix-vector product [$row]");
}

my $direct_matrix=[
 [1.137,0.021,-0.043],[-0.038,0.947,0.059],[0.016,-0.071,1.083],
];
my ($a,$b,$c)=@{$direct_matrix->[0]};
my ($d,$e,$f)=@{$direct_matrix->[1]};
my ($g,$h,$i)=@{$direct_matrix->[2]};
my $direct_det=$a*($e*$i-$f*$h)-$b*($d*$i-$f*$g)+$c*($d*$h-$e*$g);
my $direct_expected=[
 [($e*$i-$f*$h)/$direct_det,($c*$h-$b*$i)/$direct_det,($b*$f-$c*$e)/$direct_det],
 [($f*$g-$d*$i)/$direct_det,($a*$i-$c*$g)/$direct_det,($c*$d-$a*$f)/$direct_det],
 [($d*$h-$e*$g)/$direct_det,($b*$g-$a*$h)/$direct_det,($a*$e-$b*$d)/$direct_det],
];
is_deeply(matrix3_inverse($direct_matrix,0,1),$direct_expected,
 "shared inverse retains direct-division binary64 order when requested");

my @adapted=bradford_adapt_xyz(0.31,0.42,0.18,
 0.3127,0.3290,0.3457,0.3585);
my @adapted_expected=(
 0.32546129634603371,0.42209381787880462,0.13879518502169955,
);
for my $index (0..2) {
 close_enough($adapted[$index],$adapted_expected[$index],
  "Perl shared Bradford reference component $index");
}

# Independent Colour 0.4.7 reference values. Main's established coefficient
# precision is retained for serial parity, so this reference gate is explicit
# and slightly wider than the same-expression conformance checks above.
for my $case (0..$#{$fixture->{"colour_0_4_7_ictcp_reference"}}) {
 my $row=$fixture->{"colour_0_4_7_ictcp_reference"}[$case];
 my $actual=xyz_to_ictcp(@{$row->{"xyz"}});
 for my $component (qw(I T P)) {
  my $position={I=>0,T=>1,P=>2}->{$component};
  cmp_ok(abs($actual->{$component}-$row->{"ictcp"}[$position]),"<=",2e-7,
   "Perl shared ICtCp agrees with Colour 0.4.7 case $case component $component");
 }
}
for my $case (0..$#{$fixture->{"colour_0_4_7_delta_e_itp_reference"}}) {
 my $row=$fixture->{"colour_0_4_7_delta_e_itp_reference"}[$case];
 my $actual=delta_e_itp_xyz(@{$row->{"first"}},@{$row->{"second"}});
 my $tolerance=2e-7*(abs($row->{"delta_e"})>1
  ? abs($row->{"delta_e"}) : 1);
 cmp_ok(abs($actual-$row->{"delta_e"}),"<=",$tolerance,
  "Perl shared Delta E ITP agrees with Colour 0.4.7 case $case");
}

sub command_output {
 my (@command)=@_;
 my $pid=open(my $fh,"-|",@command);
 return (undef,255) if(!defined($pid));
 local $/;
 my $output=<$fh>;
 close($fh);
 return ($output,$?);
}

my $python=$ENV{"PGEN_PYTHON"} || "python3";
my ($python_output,$python_status)=command_output($python,"$Bin/math_conformance.py");
is($python_status,0,"shared Python colour maths passes conformance")
 or diag($python_output||"");
like($python_output||"",qr/^\d+ Python colour-math conformance checks passed\s*$/,
 "Python workers delegate to the shared implementation");

my ($node_path,$node_lookup)=command_output("sh","-c","command -v node 2>/dev/null");
$node_path=~s/\s+\z// if(defined($node_path));
SKIP: {
 skip "Node.js is unavailable",2 if($node_lookup!=0 || !$node_path);
 my ($node_output,$node_status)=command_output($node_path,"$Bin/math_conformance.js");
 is($node_status,0,"browser JavaScript PQ maths passes conformance")
  or diag($node_output||"");
 like($node_output||"",qr/^\d+ JavaScript colour-math conformance checks passed\s*$/,
  "browser chart and pattern paths share one PQ implementation");
}

my $compiler=$ENV{"CC"} || "cc";
my ($compiler_path,$compiler_lookup)=command_output("sh","-c","command -v '$compiler' 2>/dev/null");
$compiler_path=~s/\s+\z// if(defined($compiler_path));
SKIP: {
 my $c_checks=scalar(@{$fixture->{"pq_encode"}})
  +scalar(@{$fixture->{"pq_decode"}})+9;
 skip "C compiler is unavailable",$c_checks if($compiler_lookup!=0 || !$compiler_path);
 my $temporary=tempdir(CLEANUP=>1);
 my $binary="$temporary/math-conformance";
 my @build=($compiler_path,"-O2","-std=c99","-ffp-contract=off",
  "-fno-fast-math","-fno-unsafe-math-optimizations","-Wall","-Wextra",
  "-Werror","-I$root","-o",$binary,"$Bin/math_conformance.c","-lm");
 system(@build);
 if($?!=0 || !-x $binary) {
  skip "C colour-math conformance helper did not build",$c_checks;
 } else {
  foreach my $row (@{$fixture->{"pq_encode"}}) {
   my ($output,$status)=command_output($binary,"encode",$row->{"nits"});
   die "C PQ encode helper failed" if($status!=0);
   close_enough($output+0,$row->{"signal"},
    "C PQ encodes $row->{nits} cd/m2");
  }
  foreach my $row (@{$fixture->{"pq_decode"}}) {
   my ($output,$status)=command_output($binary,"decode",$row->{"signal"});
   die "C PQ decode helper failed" if($status!=0);
   close_enough($output+0,$row->{"nits"},
    "C PQ decodes signal $row->{signal}");
  }
  my @matrix=map { @$_ } @{$fixture->{"matrix"}};
  my ($output,$status)=command_output($binary,"inverse",@matrix);
  die "C matrix inverse helper failed" if($status!=0);
  my @actual=split(/\s+/,$output||"");
  my @expected=map { @$_ } @{$fixture->{"inverse"}};
  for my $index (0..8) {
   close_enough($actual[$index],$expected[$index],
    "C shared 3x3 inverse element $index");
  }
 }
}

sub source_text {
 my ($path)=@_;
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 return $source;
}

my $python_callers=join("\n",map { source_text("$root/usr/bin/$_") }
 qw(icc_profile_builder.py icc_companion_lut.py icc_finetune.py icc_b2a_repair.py));
unlike($python_callers,qr/2610(?:\.0)?\s*\/\s*16384/,
 "Python callers do not carry private ST 2084 constants");
unlike($python_callers,qr/^def\s+(?:smoothstep|sample_uniform_table|matrix3_multiply|matrix3_vector_multiply)\b/m,
 "Python callers do not redefine shared scalar helpers");

my $perl_callers=join("\n",map { source_text("$root/$_") }
 qw(usr/bin/meter_lg_autocal.pl usr/bin/meter_lg_3d_autocal.pl
    usr/bin/spotread_sim usr/share/PGenerator/webui.pm usr/sbin/pgenerator-lg));
unlike($perl_callers,qr/^sub\s+(?:pq_encode_normalized|pq_decode_normalized|pq_decode_nits|xyz_to_ictcp|delta_e_itp_xyz)\b/m,
 "Perl callers do not redefine shared transfer or ICtCp maths");
unlike($perl_callers,qr/my \@M=\(\[0\.8951,0\.2664,-0\.1614\]/,
 "Perl callers do not carry a private Bradford implementation");

my $lg_server=source_text("$root/usr/sbin/pgenerator-lg");
like($lg_server,qr/use PGMath qw\(matrix3_inverse matrix3_multiply\)/,
 "LG server imports the shared Perl matrix primitives");
unlike($lg_server,qr/my \$det\s*=\s*\$m->\[0\]\[0\]/,
 "LG server has no private 3x3 inverse body");

my $shell=source_text("$root/usr/bin/meter_series.sh");
like($shell,qr/from pgen_colour_math import pq_decode_nits, pq_encode_nits/,
 "shell-embedded Python imports the shared PQ implementation");
my ($white_reference_worker)=$shell=~/(apply_series_white_reference_to_steps\(\) \{.*?\nPY\n\})/s;
my ($dv_target_worker)=$shell=~/(apply_dv_absolute_greyscale_targets\(\) \{.*?\nPY\n\})/s;
ok(defined($white_reference_worker) && defined($dv_target_worker),
 "shell-embedded Python workers remain independently identifiable");
like($dv_target_worker || "",qr/from pgen_colour_math import pq_decode_nits, pq_encode_nits.*?def pq_decode_normalized/s,
 "DV target worker imports shared PQ maths in the Python block that uses it");
unlike($white_reference_worker || "",qr/from pgen_colour_math/,
 "white-reference worker does not contain the unrelated PQ import");
unlike($shell,qr/2610(?:\.0)?\s*\/\s*16384/,
 "shell-embedded Python has no private ST 2084 constants");

my $solver=source_text("$root/src/lut_solver/pgen_lut_solve.c");
my $companion=source_text("$root/usr/share/PGenerator/icc-companion-src/pgen-icc-companion.c");
like($solver,qr{#include "\.\./common/pgen_colour_math\.h"},
 "native LUT solver uses the shared C header");
like($companion,qr{#include "\.\./\.\./\.\./\.\./src/common/pgen_colour_math\.h"},
 "native companion uses the shared C header");
unlike($solver.$companion,qr/2610(?:\.0)?\s*\/\s*16384/,
 "native C callers do not carry private ST 2084 constants");

done_testing();

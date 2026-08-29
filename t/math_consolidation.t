use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();

use lib "$Bin/../usr/share/PGenerator";
use PGMath qw(
 akima_interpolate bradford_adapt_xyz delta_e_itp_xyz matrix3_inverse
 matrix3_multiply matrix3_vector_multiply pq_constants pq_decode_nits
 pq_encode_normalized xyz_to_ictcp
);

# The Python legs import modules from usr/bin; without this they leave a
# usr/bin/__pycache__ behind in the source tree on every run.
$ENV{"PYTHONDONTWRITEBYTECODE"}=1;

my $root="$Bin/..";
my $fixture_path="$Bin/fixtures/math_conformance.json";
open(my $fixture_fh,"<",$fixture_path) or die "Unable to read $fixture_path: $!";
local $/;
my $fixture=JSON::PP::decode_json(<$fixture_fh>);
close($fixture_fh);

sub close_enough {
 my ($actual,$expected,$label)=@_;
 my $maximum=1.7976931348623157e308;
 if(!defined($actual) || !defined($expected)
  || $actual!=$actual || $expected!=$expected
  || $actual>$maximum || $actual<-$maximum
  || $expected>$maximum || $expected<-$maximum) {
  fail("$label (comparison values must be finite)");
  return;
 }
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
# Zero is an explicit policy difference. Perl and the browser short-circuit
# to exactly 0; Python and C evaluate the transfer function at zero.
my ($hard_zero_policy)=grep { $_->{"policy"} eq "hard_zero" }
 @{$fixture->{"policy_rows"}{"pq_encode_zero"}};
my ($transfer_floor_policy)=grep { $_->{"policy"} eq "transfer_floor" }
 @{$fixture->{"policy_rows"}{"pq_encode_zero"}};
is(pq_encode_normalized(0),$hard_zero_policy->{"signal"},
 "Perl PQ encode short-circuits zero to exactly 0");
is(pq_encode_normalized(-5),0,
 "Perl PQ encode short-circuits negative input to exactly 0");
foreach my $row (@{$fixture->{"pq_decode"}}) {
 close_enough(pq_decode_nits($row->{"signal"}),$row->{"nits"},
  "Perl PQ decodes signal $row->{signal}");
}

# pq_constants and matrix3_multiply feed the 1D and 3D workers but had no
# value coverage of their own: the fixture rows above cannot see a c2/c3 swap
# or a transposed product, because both sides of every other check consume the
# same Perl-computed result.
#
# The literals are the ST 2084 constants written out exactly. c2 and c3 are
# over 128; the 2413/32 and 2392/32 forms that circulate are typos, and a swap
# of c2 with c3 leaves every ratio plausible-looking but wrong.
my ($pq_m1,$pq_m2,$pq_c1,$pq_c2,$pq_c3)=pq_constants();
is($pq_m1,0.1593017578125,"shared ST 2084 m1 is 2610/16384");
is($pq_m2,78.84375,"shared ST 2084 m2 is 2523/32");
is($pq_c1,0.8359375,"shared ST 2084 c1 is 3424/4096");
is($pq_c2,18.8515625,"shared ST 2084 c2 is 2413/128, not 2413/32");
is($pq_c3,18.6875,"shared ST 2084 c3 is 2392/128, not 2392/32");
isnt($pq_c2,$pq_c3,"shared ST 2084 c2 and c3 are not interchangeable");

# Every entry is an exact binary fraction, so the hand-computed product below
# is exact in binary64 and can be compared with is_deeply. The product is
# asymmetric in both senses: left/right swapped and transposed both differ.
my $left_matrix=[
 [0.5,0.25,-0.125],[-0.75,1.5,0.0625],[0.375,-0.5,1.25],
];
my $right_matrix=[
 [2,0.5,-1],[0.25,-2,0.75],[-0.5,1,4],
];
my $hand_computed=[
 [1.125,-0.375,-0.8125],
 [-1.15625,-3.3125,2.125],
 [0,2.4375,4.25],
];
is_deeply(matrix3_multiply($left_matrix,$right_matrix),$hand_computed,
 "shared 3x3 product matches an independently hand-computed result");
isnt_deeply_product(matrix3_multiply($right_matrix,$left_matrix),$hand_computed,
 "shared 3x3 product is not commutative, so operand order is pinned");
isnt_deeply_product(
 [map { my $row=$_; [map { $hand_computed->[$_][$row] } (0..2)] } (0..2)],
 $hand_computed,
 "the hand-computed product is not its own transpose");

sub isnt_deeply_product {
 my ($actual,$unwanted,$label)=@_;
 my $same=1;
 for my $row (0..2) {
  for my $column (0..2) {
   $same=0 if($actual->[$row][$column] != $unwanted->[$row][$column]);
  }
 }
 ok(!$same,$label);
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

# Degenerate inputs must refuse, not divide by ~0: row3 = row1 + row2.
ok(!defined(matrix3_inverse([[1,2,3],[4,5,6],[5,7,9]])),
 "Perl shared inverse returns undef for a singular matrix");
is_deeply([bradford_adapt_xyz(0.31,0.42,0.18,0,0.3290,0.3127,0.3290)],
 [0.31,0.42,0.18],
 "Perl Bradford leaves XYZ unadapted for a degenerate source white");

my @adapted=bradford_adapt_xyz(0.31,0.42,0.18,
 0.3127,0.3290,0.3457,0.3585);
my @adapted_expected=(
 0.32546129634603371,0.42209381787880462,0.13879518502169955,
);
for my $index (0..2) {
 close_enough($adapted[$index],$adapted_expected[$index],
  "Perl shared Bradford reference component $index");
}

# Independent Colour 0.4.7 reference values. The coefficient precision the
# upstream main branch established is retained for serial parity with shipped
# output, so this reference gate is explicit and slightly wider than the
# same-expression conformance checks above.
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

sub command_status_quiet {
 my (@command)=@_;
 my $pid=fork();
 return 255 if(!defined($pid));
 if($pid==0) {
  open(STDOUT,">","/dev/null");
  open(STDERR,">","/dev/null");
  exec {$command[0]} @command;
  exit 127;
 }
 waitpid($pid,0);
 return $?;
}

my $python=$ENV{"PGEN_PYTHON"} || "python3";
my ($python_output,$python_status)=command_output($python,"$Bin/math_conformance.py");
is($python_status,0,"shared Python colour maths passes conformance")
 or diag($python_output||"");
like($python_output||"",qr/^\d+ Python colour-math conformance checks passed\s*$/,
 "Python workers delegate to the shared implementation");

# Skipping a conformance leg is a dev-box convenience only: CI carries both
# interpreters and a C toolchain, so an absent one there is a broken runner
# rather than a reason to lose the coverage silently.
my $ci=($ENV{"GITHUB_ACTIONS"} || $ENV{"CI"}) ? 1 : 0;

my ($node_path,$node_lookup)=command_output("sh","-c","command -v node 2>/dev/null");
$node_path=~s/\s+\z// if(defined($node_path));
SKIP: {
 my $no_node=($node_lookup!=0 || !$node_path);
 fail("Node.js must be installed in CI; the JavaScript conformance leg cannot be skipped")
  if($no_node && $ci);
 skip "Node.js is unavailable",2 if($no_node);
 my ($node_output,$node_status)=command_output($node_path,"$Bin/math_conformance.js");
 is($node_status,0,"browser JavaScript PQ maths passes conformance")
  or diag($node_output||"");
 like($node_output||"",qr/^\d+ JavaScript colour-math conformance checks passed\s*$/,
  "browser chart and pattern paths share one PQ implementation");
}

my $compiler=$ENV{"CC"} || "cc";
my ($compiler_path,$compiler_lookup)=command_output("sh","-c","command -v '$compiler' 2>/dev/null");
$compiler_path=~s/\s+\z// if(defined($compiler_path));

# The legacy appliance has /usr/bin/cc but deliberately ships no assembler, so
# command -v alone does not identify a usable C toolchain. Probe a trivial
# translation unit first. A broken probe may skip the optional C leg on a dev
# box or appliance, but it still fails CI; once the probe succeeds, a failure
# to build math_conformance.c remains a source defect and never becomes a skip.
my $compiler_usable=($compiler_lookup==0 && $compiler_path) ? 1 : 0;
my $compiler_probe_dir;
if($compiler_usable) {
 $compiler_probe_dir=tempdir(CLEANUP=>1);
 my $probe_source="$compiler_probe_dir/probe.c";
 my $probe_binary="$compiler_probe_dir/probe";
 if(open(my $probe_fh,">",$probe_source)) {
  print $probe_fh "int main(void) { return 0; }\n";
  close($probe_fh);
  my $probe_status=command_status_quiet(
   $compiler_path,"-std=c99","-o",$probe_binary,$probe_source);
  $compiler_usable=0 if($probe_status!=0 || !-x $probe_binary);
 } else {
  $compiler_usable=0;
 }
}
SKIP: {
 my $c_checks=scalar(@{$fixture->{"pq_encode"}})
  +2*scalar(@{$fixture->{"pq_decode"}})+28;
 fail("a usable C toolchain must be installed in CI; the C conformance leg cannot be skipped")
  if(!$compiler_usable && $ci);
 skip "a usable C toolchain is unavailable",$c_checks if(!$compiler_usable);
 my $temporary=tempdir(CLEANUP=>1);
 my $binary="$temporary/math-conformance";
 my @build=($compiler_path,"-O2","-std=c99","-ffp-contract=off",
  "-fno-fast-math","-fno-unsafe-math-optimizations","-Wall","-Wextra",
  "-Werror","-I$root","-o",$binary,"$Bin/math_conformance.c","-lm");
 system(@build);
 if($?!=0 || !-x $binary) {
  # The compiler is present, so a failed build is a defect in the header or
  # the helper, never a reason to drop the checks it would have run.
  fail("$compiler_path is available but failed to build $Bin/math_conformance.c");
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
   my ($normalized_output,$normalized_status)=
    command_output($binary,"decode-normalized",$row->{"signal"});
   die "C normalized PQ decode helper failed" if($normalized_status!=0);
   close_enough($normalized_output+0,$row->{"nits"}/10000,
    "C normalized PQ decoder handles signal $row->{signal}");
  }
  # The C side of the zero divergence: no short-circuit, so the transfer
  # function's value at zero is what an ICC table gets.
  my ($zero_output,$zero_status)=command_output($binary,"encode",0);
  die "C PQ encode helper failed" if($zero_status!=0);
  close_enough($zero_output+0,$transfer_floor_policy->{"signal"},
   "C PQ encode returns the transfer function value at zero, not 0");
  my @matrix=map { @$_ } @{$fixture->{"matrix"}};
  my ($output,$status)=command_output($binary,"inverse",@matrix);
  die "C matrix inverse helper failed" if($status!=0);
  my @actual=split(/\s+/,$output||"");
  my @expected=map { @$_ } @{$fixture->{"inverse"}};
  for my $index (0..8) {
   close_enough($actual[$index],$expected[$index],
    "C shared 3x3 inverse element $index");
  }
  # pgen_matrix3_inverse is the reciprocal variant the native LUT solver
  # calls, and it also cross-checks pgen_matrix3_determinant against the
  # determinant it computes internally (exit 3 if they disagree).
  my ($reciprocal_output,$reciprocal_status)=
   command_output($binary,"inverse-reciprocal",@matrix);
  die "C reciprocal inverse helper failed" if($reciprocal_status!=0);
  my @reciprocal_actual=split(/\s+/,$reciprocal_output||"");
  my @reciprocal_expected=map { @$_ } @{$fixture->{"inverse_reciprocal"}};
  for my $index (0..8) {
   close_enough($reciprocal_actual[$index],$reciprocal_expected[$index],
    "C shared 3x3 reciprocal inverse element $index");
  }
  # PGEN_BRADFORD_MATRIX_INITIALIZER has exactly one shipped consumer, the
  # native Patch Companion, which no test can build. Pin its coefficients
  # here so a header edit cannot change them unnoticed.
  my ($bradford_output,$bradford_status)=command_output($binary,"bradford");
  die "C Bradford helper failed" if($bradford_status!=0);
  my @bradford_actual=split(/\s+/,$bradford_output||"");
  my @bradford_expected=map { @$_ } @{$fixture->{"bradford_cone_response"}};
  for my $index (0..8) {
   close_enough($bradford_actual[$index],$bradford_expected[$index],
    "C shared Bradford cone-response element $index");
  }
 }
}

# PGICCProfile.pm runs the profile builder with stderr discarded on three of
# its routes, so an ImportError from a partial deploy used to reach the
# operator as a bare "ICC profile creation failed". Both NumPy consumers now
# answer in their own error protocol instead, and still exit non-zero.
{
 my $stub=tempdir("pgen-import-stub-XXXXXX",TMPDIR=>1,CLEANUP=>1);
 open(my $stub_fh,">","$stub/numpy.py")
  or die "Unable to write the NumPy stub: $!";
 print $stub_fh "raise ImportError(\"No module named 'numpy'\")\n";
 close($stub_fh);
 local $ENV{"PYTHONPATH"}=$stub;

 my ($builder_stdout,$builder_status)=command_output("sh","-c",
  "\"\$1\" \"\$2\" /nonexistent-input.json /nonexistent-output 2>/dev/null",
  "sh",$python,"$root/usr/bin/icc_profile_builder.py");
 isnt($builder_status,0,
  "the ICC profile builder exits non-zero when NumPy is unavailable");
 my $builder_error=eval { JSON::PP::decode_json($builder_stdout||"") };
 ok(ref($builder_error) eq "HASH"
   && ($builder_error->{"status"}||"") eq "error"
   && ($builder_error->{"message"}||"")
      =~ /\AICC profile builder cannot start: .*numpy/,
  "the ICC profile builder answers on stdout in the caller's error protocol")
  or diag($builder_stdout||"");

 my ($companion_stderr,$companion_status)=command_output("sh","-c",
  "\"\$1\" \"\$2\" a clut sdr b 2>&1 >/dev/null",
  "sh",$python,"$root/usr/bin/icc_companion_lut.py");
 isnt($companion_status,0,
  "the Companion LUT builder exits non-zero when NumPy is unavailable");
 like($companion_stderr||"",
  qr/\ACompanion LUT builder cannot start: .*numpy/,
  "the Companion LUT builder names the missing module on one line");
}

# The native Patch Companion is the only shipped consumer of
# PGEN_BRADFORD_MATRIX_INITIALIZER and pgen_matrix3_inverse_divide, and no
# test can build it: it is a desktop SDL3 application, so neither the
# appliance nor a default CI runner has its headers, and installing an SDL3
# toolchain in CI costs more than this gate is worth. Two mitigations instead.
# The coefficients and both inverse variants are pinned against the fixture
# above, so an absent SDL3 loses the compile and not the values; and where the
# headers ARE present the source is syntax-checked, with a failure treated as
# a failure rather than a skip.
SKIP: {
 skip "a usable C toolchain is unavailable",1 if(!$compiler_usable);
 my ($sdl_flags,$sdl_status)=command_output("sh","-c",
  "pkg-config --cflags sdl3 2>/dev/null");
 $sdl_flags="" if(!defined($sdl_flags));
 $sdl_flags=~s/\s+\z//;
 skip "SDL3 development headers are unavailable",1 if($sdl_status!=0);
 my @check=($compiler_path,"-fsyntax-only","-std=c99",
  grep { length } split(/\s+/,$sdl_flags),
  "$root/usr/share/PGenerator/icc-companion-src/pgen-icc-companion.c");
 system(@check);
 is($?,0,
  "native Patch Companion source still compiles against the shared C header");
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
unlike($python_callers,
 qr/^\s*(?:D50|PCS_WHITE|SOURCE_WHITE_D65)\s*=\s*\(0\.9642|^\s*(?:SOURCE_WHITE_D65)\s*=\s*\(0\.9504559/m,
 "Python callers reuse identical D50 and D65 constants from the shared owner");

my $builder_source=source_text("$root/usr/bin/icc_profile_builder.py");
unlike($builder_source,qr/^def\s+(?:calibration_curves|windows_hdr_commuting_adjustment_luts)\b/m,
 "confirmed unreferenced ICC builder maths is deleted instead of moved");
my ($xy_matrix_body)=$builder_source=~/(def xy_matrix\b.*?)(?=\ndef |\z)/s;
my ($measured_matrix_body)=$builder_source=~/(def measured_primary_matrix\b.*?)(?=\ndef |\z)/s;
is(()=($xy_matrix_body||"")=~/mat_inv\(base\)/g,1,
 "xy_matrix computes its base inverse once");
is(()=($measured_matrix_body||"")=~/mat_inv\(matrix\)/g,1,
 "measured_primary_matrix computes its base inverse once");

my $repair_source=source_text("$root/usr/bin/icc_b2a_repair.py");
unlike($repair_source,qr/^def\s+_pq_code\b/m,
 "the confirmed unreferenced B2A helper is deleted");

my $perl_callers=join("\n",map { source_text("$root/$_") }
 qw(usr/bin/meter_lg_autocal.pl usr/bin/meter_lg_3d_autocal.pl
    usr/bin/spotread_sim usr/share/PGenerator/webui.pm usr/sbin/pgenerator-lg));
unlike($perl_callers,qr/^sub\s+(?:pq_encode_normalized|pq_decode_normalized|pq_decode_nits|xyz_to_ictcp|delta_e_itp_xyz)\b/m,
 "Perl callers do not redefine shared transfer or ICtCp maths");
unlike($perl_callers,qr/my \@M=\(\[0\.8951,0\.2664,-0\.1614\]/,
 "Perl callers do not carry a private Bradford implementation");
unlike(source_text("$root/usr/bin/meter_lg_3d_autocal.pl"),
 qr/^sub\s+(?:bt709_rgb_to_xyz|srgb_to_linear|_fm_vol_axis|hdr20_postcal_converge_step)\b/m,
 "confirmed unreferenced 3D maths is deleted instead of moved");

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
unlike($solver.$companion,qr/0\.8951\s*,\s*0\.2664/,
 "native C callers take Bradford from the shared header initializer");
like($companion,qr/PGEN_BRADFORD_MATRIX_INITIALIZER/,
 "native companion still consumes the shared Bradford initializer");
like($companion,qr/pgen_matrix3_inverse_divide/,
 "native companion still consumes the shared per-cofactor 3x3 inverse");

done_testing();

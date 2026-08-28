use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Time::HiRes qw(time);

# The native cube solver (src/lut_solver/pgen_lut_solve.c) has to emit codes
# that are BYTE-IDENTICAL to the Perl path, not merely close: fm_invert is a
# discrete-branch search, so a divergence surfaces as percent, not as an ulp.
# Every cube below is compared code for code against _generate_lut_cube_serial.
#
# The committed usr/bin/pgen_lut_solve is an armhf binary for the appliance, so
# on a dev Mac we look for a host build first and otherwise compile the same C
# source into a temporary directory. The checked-in ARM binary remains the
# executable under test when this suite runs on the appliance.
#
# The whole sweep re-solves every cube in Perl as the reference, which is what
# makes it slow (a couple of minutes); PGEN_LUT_PARITY_QUICK=1 drops the single
# 33^3 leg for a faster edit loop, but the landing gate is the full run.

my $worker="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
my $host="$Bin/../src/lut_solver/build/pgen_lut_solve.host";
my $vendored="$Bin/../usr/bin/pgen_lut_solve";

sub helper_runs {
 my ($bin)=@_;
 return 0 if(!-x $bin);
 my $pid=open(my $rd,"-|");
 return 0 if(!defined($pid));
 if($pid == 0) {
  open(STDIN,'<','/dev/null');
  open(STDERR,'>','/dev/null');
  exec($bin);
  exit 127;
 }
 local $/;
 my $out=<$rd>;
 close($rd);
 return (defined($out) && $out =~ /\APGLUT3D 1 error /) ? 1 : 0;
}

# Skipping is only ever allowed to mean "this dev box has no C toolchain".
# A compiler that IS present and then fails to build pgen_lut_solve.c is a
# defect in the code under test, and must fail rather than quietly delete the
# byte-parity gate; CI refuses to skip for either reason.
sub compiler_path {
 my ($cc)=@_;
 my $pid=open(my $rd,"-|","sh","-c",'command -v "$1" 2>/dev/null',"sh",$cc);
 return undef if(!defined($pid));
 local $/;
 my $found=<$rd>;
 close($rd);
 return undef if($? != 0 || !defined($found));
 $found=~s/\s+\z//;
 return length($found) ? $found : undef;
}

sub refuse {
 my ($reason)=@_;
 plan tests => 1;
 fail($reason);
 exit 1;
}

my $ci=($ENV{"GITHUB_ACTIONS"} || $ENV{"CI"}) ? 1 : 0;
my $bin=helper_runs($host) ? $host : (helper_runs($vendored) ? $vendored : undef);
my $build_dir;
if(!$bin) {
 my $cc=$ENV{"CC"} || "cc";
 my $cc_path=compiler_path($cc);
 if(!$cc_path) {
  refuse("no C compiler and no runnable pgen_lut_solve") if($ci);
  plan skip_all => "no C compiler and no runnable pgen_lut_solve";
 }
 $build_dir=tempdir(CLEANUP=>1);
 my $built="$build_dir/pgen_lut_solve";
 my $source="$Bin/../src/lut_solver/pgen_lut_solve.c";
 my @command=($cc_path,"-O2","-std=c99","-ffp-contract=off","-fno-fast-math",
  "-fno-unsafe-math-optimizations","-o",$built,$source,"-lm");
 system(@command);
 if($? != 0) {
  my $why=($? & 127) ? "killed by signal ".($? & 127) : "exit ".($? >> 8);
  refuse("$cc_path is available but failed to build $source ($why)");
 }
 refuse("the freshly built $source does not answer the helper protocol")
  if(!helper_runs($built));
 $bin=$built;
}
$ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=$bin;

do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&generate_lut_cube));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

# The fallback paths all log through log_line, which writes to STDERR; the
# tests that deliberately trigger a fallback silence it so the harness output
# stays readable. Context has to propagate: generate_lut_cube returns a list.
sub quietly {
 my ($code)=@_;
 my $want=wantarray;
 open(my $saved,'>&',\*STDERR) or return $want ? $code->() : scalar($code->());
 open(STDERR,'>','/dev/null');
 my @out=$want ? $code->() : (scalar $code->());
 open(STDERR,'>&',$saved);
 close($saved);
 return $want ? @out : $out[0];
}

# The synthetic display model both native-helper suites share.
do "$Bin/lut_model_fixture.pl";
die $@ if($@);
die "Failed to load $Bin/lut_model_fixture.pl" if(!defined(&build_model));

sub compare_cube {
 my ($model,$label,$size,$order)=@_;
 my $native=quietly(sub {
  # The production self-check re-solves 64 nodes in Perl and would turn a
  # divergence into a silent fallback; here every code has to stand alone.
  no warnings qw(redefine once);
  local *main::_lut_native_verify=sub { return 1; };
  return _lut_native_u16($model,$size,$order);
 });
 if(!$native) {
  fail("$label ${size}^3 $order: the helper refused the cube");
  return 0;
 }
 my $ref;
 if($order eq "r_slowest") { ($ref)=_generate_lut_cube_serial($model,$size); }
 else { $ref=_generate_lut_lg_payload_serial($model,$size); }
 my $want=3*$size*$size*$size;
 if(scalar(@{$native}) != $want || scalar(@{$ref}) != $want) {
  fail("$label ${size}^3 $order: expected $want codes");
  return 0;
 }
 my ($diff,$first)=(0,"");
 for(my $i=0;$i<$want;$i++) {
  next if($native->[$i] == $ref->[$i]);
  $diff++;
  $first=sprintf(", first at index %d: native %d, Perl %d",$i,$native->[$i],$ref->[$i]) if($first eq "");
 }
 is($diff,0,"$label ${size}^3 $order: all $want codes identical$first");
 return $want;
}

sub label_for {
 my ($model,$tag)=@_;
 return sprintf("%s %s/%s/%s/nonadd=%d/%s",$tag,
  $model->{"target_gamma"},$model->{"target_gamut"},
  ($model->{"gamut_drive_matrix"} ? "matrix-seed" : "solve-seed"),
  $model->{"forward_model"}{"nonadd_count"},
  ($model->{"neutral_axis_identity"} ? "grey-identity" : "grey-solved"));
}

my $t0=time();
my $checked=0;

# Breadth at 9^3: every target gamma against every target gamut, alternating
# the greyscale mode and the node order so both arms of neutral_identity_output
# and both cube fill orders are covered across the sweep. srgb and st2084 carry
# no gamut_drive_matrix, so they exercise the solve_output_rgb seed and, with
# greys solved, the white_axis branch of target_xyz_for_node.
my $n=0;
foreach my $gamma (qw(bt1886 2.2 2.4 srgb st2084)) {
 foreach my $gamut (qw(bt709 p3d65 p3dci bt2020)) {
  my $mode=($gamma eq "st2084") ? "hdr10" : "sdr";
  my $greys=($n % 2);
  my $order=($n % 2) ? "r_fastest" : "r_slowest";
  $n++;
  my $model=build_model($gamma,$gamut,$mode,3,$greys,1);
  if(!$model) { fail("forward model for $gamma/$gamut/$mode"); next; }
  $checked+=compare_cube($model,label_for($model,"sweep"),9,$order);
 }
}

# The dense volume lattice (hybrid 5^3, 121 non-additivity samples) is where
# the inverse-distance field is least smooth and the LM works hardest.
foreach my $greys (0,1) {
 my $model=build_model("bt1886","bt709","sdr",5,$greys,1);
 if(!$model) { fail("dense forward model"); next; }
 $checked+=compare_cube($model,label_for($model,"dense"),9,"r_slowest");
}

# The live LG shapes at the sizes that actually ship: a 17^3 export cube and a
# 33^3 payload. These run without solve_only, so the model carries the rewrites
# the real workflow applies.
foreach my $case (["sdr","bt1886","bt709"],["hdr10","2.2","bt2020"]) {
 my ($mode,$gamma,$gamut)=@{$case};
 foreach my $greys (0,1) {
  my $model=build_model($gamma,$gamut,$mode,3,$greys,0);
  if(!$model) { fail("live-shape model for $mode"); next; }
  foreach my $order ("r_slowest","r_fastest") {
   $checked+=compare_cube($model,label_for($model,"live"),17,$order);
  }
 }
}

# One full-size payload. 33^3 is the size the LG upload actually carries and
# the size the offline solve defaults to, and it is the only place a rare
# node shape gets 35,937 chances to appear.
if(($ENV{"PGEN_LUT_PARITY_QUICK"}||"") eq "") {
 my $model=build_model("bt1886","bt709","sdr",3,1,1);
 if($model) { $checked+=compare_cube($model,label_for($model,"full"),33,"r_fastest"); }
 else { fail("full-size model"); }
}

# neutral_neighborhood_identity_enabled forces the 1-step neighbourhood of the
# neutral diagonal to identity as well, and the helper carries it as its own
# protocol field. Nothing else in this sweep turns it on, so that branch of
# neutral_identity_output had no byte-parity coverage on either side.
{
 my $guarded=build_model("bt1886","bt709","sdr",3,0,1);
 my $plain=build_model("bt1886","bt709","sdr",3,0,1);
 if(!$guarded || !$plain) {
  fail("neutral-neighbourhood model");
 } else {
  $guarded->{"neutral_neighborhood_identity_enabled"}=1;
  ok($guarded->{"neutral_axis_identity"},
   "the neutral-neighbourhood fixture keeps identity greys, which the branch needs");
  # Guard against a vacuous case: if the flag changed nothing, the parity
  # checks below would pass without ever entering the branch.
  my ($with)=_generate_lut_cube_serial($guarded,9);
  my ($without)=_generate_lut_cube_serial($plain,9);
  my $moved=0;
  for(my $i=0;$i<scalar(@{$with});$i++) { $moved++ if($with->[$i] != $without->[$i]); }
  cmp_ok($moved,">",0,
   "the neutral-neighbourhood guard actually moves codes ($moved of "
   .scalar(@{$with}).")");
  foreach my $order ("r_slowest","r_fastest") {
   $checked+=compare_cube($guarded,
    label_for($guarded,"neutral-neighbourhood"),9,$order);
  }
 }
}

# The wire-in itself, with the production self-check live: both entry points
# have to take the native path, agree with Perl code for code, and still hand
# back the five preview corners the export block reads.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 my ($u16,$nodes)=quietly(sub { return generate_lut_cube($model,9); });
 is(scalar(@{$u16}),3*9*9*9,'generate_lut_cube returns a full cube through the native path');
 is(scalar(@{$nodes}),5,'the native cube path still returns the five preview corners');
 my ($ref)=_generate_lut_cube_serial($model,9);
 is_deeply($u16,$ref,'generate_lut_cube via the helper matches the Perl serial cube');
 my $payload=quietly(sub { return generate_lut_lg_payload($model,9) });
 is_deeply($payload,_generate_lut_lg_payload_serial($model,9),
  'generate_lut_lg_payload via the helper matches the Perl serial payload');
}

# The runtime self-check is the production safety net. It has to accept a
# genuine helper cube and reject one whose sampled nodes have moved.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 my $native=quietly(sub {
  no warnings qw(redefine once);
  local *main::_lut_native_verify=sub { return 1; };
  return _lut_native_u16($model,17,"r_slowest");
 });
 ok($native,'the helper produced a cube for the self-check fixtures');
 ok(_lut_native_verify($model,17,"r_slowest",$native),'the runtime self-check accepts a genuine helper cube');
 my @wrecked=@{$native};
 foreach my $pt (@{_lut_native_check_nodes(17)}) {
  my ($r,$g,$b)=@{$pt};
  my $off=($r*17*17+$g*17+$b)*3;
  $wrecked[$off]=($wrecked[$off]+1) % 4096;
 }
 is(quietly(sub { return _lut_native_verify($model,17,"r_slowest",\@wrecked) }),0,
  'the runtime self-check rejects a cube whose sampled nodes disagree');
}

# The helper implements only node_output_pct's forward-model branch, so a
# model carrying a residual grid has to fall straight through to Perl rather
# than get a silently different cube.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 $model->{"residual_grid"}={ dummy=>1 };
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'a model carrying a residual grid is refused by the native path');
}

# A model with no forward model at all is the matrix / residual path and must
# never reach the helper either.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 delete $model->{"forward_model"};
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'a model with no forward model is refused by the native path');
}

# The env override has to force the Perl path outright, for A/B measurement.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE"}="0";
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'PGEN_AUTOCAL_LUT_NATIVE=0 forces the Perl path');
}

# A missing binary must fall back rather than die.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}="/nonexistent/pgen_lut_solve";
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'a missing helper binary falls back to the Perl path');
}

# A binary that never returns must be killed and fall back, not wedge the run.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 my $dir=tempdir(CLEANUP=>1);
 open(my $sh,'>',"$dir/wedged") or die "Unable to write the wedged helper: $!";
 print $sh "#!/bin/sh\nsleep 30\n";
 close($sh);
 chmod(0755,"$dir/wedged");
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}="$dir/wedged";
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_TIMEOUT"}="1";
 my $t=time();
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'a helper that never returns is killed and falls back to the Perl path');
 cmp_ok(time()-$t,'<',10,'the wedged helper does not hold the run open');
}

# A binary that answers with garbage must fall back, not emit a partial cube.
{
 my $model=build_model("bt1886","bt709","sdr",3,0,1);
 my $dir=tempdir(CLEANUP=>1);
 open(my $sh,'>',"$dir/garbage") or die "Unable to write the garbage helper: $!";
 print $sh "#!/bin/sh\necho 'PGLUT3D 1 ok'\necho 'codes 2187'\necho '1 2 3'\necho end\n";
 close($sh);
 chmod(0755,"$dir/garbage");
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}="$dir/garbage";
 is(quietly(sub { return _lut_native_u16($model,9,"r_slowest") }),undef,
  'a short but well-formed response is refused rather than padded');
}

diag(sprintf("compared %d u16 codes against the Perl path in %.1f s",$checked,time()-$t0));
done_testing();

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

# The native solver is an optimisation, never a source of truth: when it is
# missing, unusable or refuses the model, generate_lut_cube and
# generate_lut_lg_payload must still return a COMPLETE and correct Perl cube.
# t/lg_3d_lut_native_parity.t proves the helper agrees with Perl; nothing
# proved the fallthrough itself, so a broken fallback would surface as a
# corrupt LUT on a device whose helper failed to deploy.
#
# Everything here goes through the PUBLIC entry points, and the reference is
# the serial solver, so the forked multi-worker path is compared as well.

my $worker="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&generate_lut_cube));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

do "$Bin/lut_model_fixture.pl";
die $@ if($@);
die "Failed to load $Bin/lut_model_fixture.pl" if(!defined(&build_model));

# log_line writes to STDERR. The fallback paths are supposed to be noisy, so
# the messages are captured and asserted rather than silenced. A real file
# rather than an in-memory handle, because the forked cube workers inherit it.
my $log_dir=tempdir("pgen-lut-fallback-XXXXXX",TMPDIR=>1,CLEANUP=>1);

sub with_captured_log {
 my ($code)=@_;
 my $path="$log_dir/captured.$$";
 open(my $saved,'>&',\*STDERR) or die "Unable to duplicate STDERR: $!";
 open(STDERR,'>',$path) or do {
  open(STDERR,'>&',$saved);
  die "Unable to redirect STDERR to $path: $!";
 };
 my $result=eval { scalar $code->() };
 my $error=$@;
 open(STDERR,'>&',$saved);
 close($saved);
 my $captured="";
 if(open(my $fh,'<',$path)) {
  local $/;
  $captured=<$fh>;
  close($fh);
 }
 unlink($path);
 die $error if($error);
 return ($captured,$result);
}

my $size=9;
my $model=build_model("bt1886","bt709","sdr",3,0,1);
die "Failed to build the synthetic forward model" if(!$model);

my ($reference_cube)=_generate_lut_cube_serial($model,$size);
my $reference_payload=_generate_lut_lg_payload_serial($model,$size);
my $want=3*$size*$size*$size;
is(scalar(@{$reference_cube}),$want,"serial reference cube has $want codes");
is(scalar(@{$reference_payload}),$want,"serial reference payload has $want codes");

sub codes_match {
 my ($actual,$expected,$label)=@_;
 if(ref($actual) ne "ARRAY" || scalar(@{$actual}) != scalar(@{$expected})) {
  fail("$label: expected ".scalar(@{$expected})." codes, got "
   .((ref($actual) eq "ARRAY") ? scalar(@{$actual}) : "no array"));
  return;
 }
 my ($diff,$first)=(0,"");
 for(my $i=0;$i<scalar(@{$expected});$i++) {
  next if($actual->[$i] == $expected->[$i]);
  $diff++;
  $first=sprintf(", first at index %d: got %d, want %d",
   $i,$actual->[$i],$expected->[$i]) if($first eq "");
 }
 is($diff,0,"$label: all ".scalar(@{$expected})." codes match the serial cube$first");
}

# Stand-in helpers, written here rather than borrowed from /bin: the paths of
# true(1) and false(1) are not the same on every platform this suite runs on.
my $fakes=tempdir(CLEANUP=>1);
sub fake_helper {
 my ($name,$body)=@_;
 my $path="$fakes/$name";
 open(my $fh,'>',$path) or die "Unable to write $path: $!";
 print $fh "#!/bin/sh\n$body\n";
 close($fh);
 chmod(0755,$path) or die "Unable to make $path executable: $!";
 return $path;
}

# Each case is a different way for the helper to be unusable on a device.
my @cases=(
 ["a helper that was never deployed","$fakes/pgen_lut_solve_definitely_absent",
  qr/lut native: helper \S+ is not installed, Perl cube/],
 ["a helper that always fails",fake_helper("failing","exit 1"),
  qr/lut native: helper exit 1/],
 ["a helper that answers nothing",fake_helper("silent","exit 0"),
  qr/lut native: bad response header/],
 ["a helper killed by a signal",fake_helper("crashing","kill -TERM \$\$"),
  qr/lut native: helper killed by signal 15/],
);

foreach my $case (@cases) {
 my ($label,$bin,$expected_log)=@{$case};
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=$bin;
 foreach my $workers (1,3) {
  my $arm="$label, ".(($workers > 1) ? "$workers workers" : "serial");
  my ($log,$out)=with_captured_log(sub {
   no warnings qw(redefine once);
   local *main::_lut_gen_workers=sub { return $workers; };
   my ($cube,$nodes)=generate_lut_cube($model,$size);
   my $payload=generate_lut_lg_payload($model,$size);
   return [$cube,$nodes,$payload];
  });
  codes_match($out->[0],$reference_cube,"cube with $arm");
  codes_match($out->[2],$reference_payload,"payload with $arm");
  is(ref($out->[1]),"ARRAY","cube with $arm still returns its node summary");
  like($log,$expected_log,"cube with $arm logs why the helper was not used");
 }
}

# A model the helper protocol cannot express must fall back just as cleanly,
# and must say which part of the model it could not carry.
{
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=fake_helper("quiet","exit 0");
 my %residual=%{$model};
 $residual{"residual_grid"}={ dummy => 1 };
 my ($log,$out)=with_captured_log(sub {
  my ($cube)=generate_lut_cube(\%residual,$size);
  return $cube;
 });
 codes_match($out,$reference_cube,"cube with a residual-grid model");
 like($log,qr/lut native: residual-grid model, Perl cube/,
  "a residual-grid model is refused out loud");
}
{
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=fake_helper("quiet","exit 0");
 my %broken=%{$model};
 $broken{"target_gamma"}="a gamma token with spaces";
 my ($log,$out)=with_captured_log(sub {
  my ($cube)=generate_lut_cube(\%broken,$size);
  return $cube;
 });
 is(ref($out),"ARRAY","an unexpressible model still produces a Perl cube");
 like($log,qr/lut native: model not expressible in the helper protocol \(the target gamma is not a helper-safe token\)/,
  "the request builder names the field it could not carry");
}
{
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE"}="0";
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=fake_helper("quiet","exit 0");
 my ($log,$out)=with_captured_log(sub {
  my ($cube)=generate_lut_cube($model,$size);
  return $cube;
 });
 codes_match($out,$reference_cube,"cube with the helper switched off");
 like($log,qr/lut native: disabled by PGEN_AUTOCAL_LUT_NATIVE, Perl cube/,
  "an operator switching the helper off is recorded");
}

done_testing();

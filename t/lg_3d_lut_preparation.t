use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

our $_lut_native_reason;

my $worker="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&generate_lut_cube));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

do "$Bin/lut_model_fixture.pl";
die $@ if($@);
die "Failed to load $Bin/lut_model_fixture.pl" if(!defined(&build_model));

sub compiler_path {
 my ($cc)=@_;
 my $found=`command -v "$cc" 2>/dev/null`;
 chomp($found);
 return ($? == 0 && $found ne "") ? $found : undef;
}

my $cc=compiler_path($ENV{"CC"} || "cc");
if(!$cc) {
 plan skip_all => "no C compiler for the instrumented solver build";
}

my $dir=tempdir(CLEANUP=>1);
my $probe_source="$dir/compiler_probe.c";
my $probe_bin="$dir/compiler_probe";
open(my $probe_fh,'>',$probe_source) or die "Unable to write $probe_source: $!";
print {$probe_fh} "int main(void) { return 0; }\n";
close($probe_fh) or die "Unable to close $probe_source: $!";
system($cc,"-o",$probe_bin,$probe_source);
if($? != 0 || !-x $probe_bin) {
 plan skip_all => "no complete C compile/link toolchain for the instrumented solver build";
}

my $source="$Bin/../src/lut_solver/pgen_lut_solve.c";
my $bin="$dir/pgen_lut_solve_counted";
my @flags=("-O2","-std=c99","-ffp-contract=off","-fno-fast-math",
 "-fno-unsafe-math-optimizations","-DPGEN_LUT_INSTRUMENT");
system($cc,@flags,"-o",$bin,$source,"-lm");
if($? != 0 || !-x $bin) {
 plan tests => 1;
 fail("instrumented LUT solver compiles");
 exit 1;
}

sub native_solve {
 my ($model,$size,$order)=@_;
 my $request=_lut_native_request($model,$size,$order);
 die "fixture was not expressible: $_lut_native_reason" if(!defined($request));
 my $err=gensym();
 my $pid=open3(my $in,my $out,$err,$bin,"--no-gate");
 print $in $request;
 close($in);
 local $/;
 my $stdout=<$out>;
 my $stderr=<$err>;
 close($out);
 close($err);
 waitpid($pid,0);
 die "instrumented helper failed with status $?\n$stderr" if($? != 0);
 my %count=($stderr =~ /\b(transfer_evals|channel_curves|curve_points|level_matrices|prepared_level_inversions|jacobian_inversions|idw_anchor_iterations|solved_nodes)=(\d+)/g);
 my @codes=($stdout =~ /\APGLUT3D 1 ok\ncodes \d+\n([\s\d]+)end\n\z/s)
  ? map { $_+0 } split(' ',$1) : ();
 return (\%count,\@codes,$stderr);
}

sub unprepared_perl_codes {
 my ($model,$size,$order)=@_;
 $order||="r_slowest";
 my @codes;
 my @outer=($order eq "r_slowest") ? (0..$size-1) : (0..$size-1);
 for my $a (@outer) {
  for my $g (0..$size-1) {
   for my $c (0..$size-1) {
    my ($r,$b)=($order eq "r_slowest") ? ($a,$c) : ($c,$a);
    my $out=node_output_pct($model,$r,$g,$b,$size);
    push @codes,map { int(clamp($_,0,100)*4095/100+0.5) } @{$out};
   }
  }
 }
 return \@codes;
}

my $size=9;
my $solve=build_model("srgb","bt709","sdr",3,0,1);
ok($solve && !$solve->{"gamut_drive_matrix"},
 "solve-seed fixture selects the contribution-curve path");
my ($solve_count,$solve_codes,$solve_log)=native_solve($solve,$size,"r_slowest");
is($solve_count->{"channel_curves"},3,
 "solve seed prepares exactly three channel curves");
is($solve_count->{"curve_points"},51,
 "solve seed reconstructs exactly 51 channel-curve points");
is($solve_count->{"level_matrices"},$size,
 "solve seed prepares one matrix per possible maximum lattice index");
is($solve_count->{"prepared_level_inversions"},$size,
 "solve seed inverts one prepared matrix per possible maximum lattice index");
is($solve_count->{"solved_nodes"},$size**3-$size,
 "the structural counter excludes identity-neutral nodes");
cmp_ok($solve_count->{"transfer_evals"},">",0,
 "the counted build records prepared transfer evaluations");
cmp_ok($solve_count->{"idw_anchor_iterations"},">",0,
 "the counted build records IDW anchor visits");
cmp_ok($solve_count->{"jacobian_inversions"},">",0,
 "the counted build records iterative Jacobian inversions");
my ($solve_reference)=_generate_lut_cube_serial($solve,$size);
is_deeply($solve_codes,$solve_reference,
 "prepared native solve-seed output is code-identical to Perl");
is_deeply($solve_reference,unprepared_perl_codes($solve,$size),
 "prepared Perl solve-seed output is code-identical to the unprepared path");

my $matrix=build_model("bt1886","bt709","sdr",3,0,1);
ok($matrix && $matrix->{"gamut_drive_matrix"},
 "matrix-seed fixture selects the direct gamut-matrix path");
my ($matrix_count,$matrix_codes,$matrix_log)=native_solve($matrix,$size,"r_slowest");
is($matrix_count->{"channel_curves"},0,
 "matrix seed does not prepare contribution curves");
is($matrix_count->{"curve_points"},0,
 "matrix seed does not reconstruct contribution-curve points");
is($matrix_count->{"level_matrices"},0,
 "matrix seed does not prepare level matrices");
is($matrix_count->{"prepared_level_inversions"},0,
 "matrix seed does not invert level matrices");
my ($matrix_reference)=_generate_lut_cube_serial($matrix,$size);
is_deeply($matrix_codes,$matrix_reference,
 "prepared native matrix-seed output is code-identical to Perl");
is_deeply($matrix_reference,unprepared_perl_codes($matrix,$size),
 "prepared Perl matrix-seed output is code-identical to the unprepared path");

my $perl_solve=_prepare_lut_solver_state($solve,$size);
is($perl_solve->{"counts"}{"channel_curves"},3,
 "Perl fallback prepares exactly three channel curves");
is($perl_solve->{"counts"}{"curve_points"},51,
 "Perl fallback reconstructs exactly 51 curve points");
is($perl_solve->{"counts"}{"level_matrices"},$size,
 "Perl fallback prepares one matrix per maximum lattice index");
my $perl_matrix=_prepare_lut_solver_state($matrix,$size);
is($perl_matrix->{"counts"}{"channel_curves"},0,
 "Perl matrix seed does not prepare contribution curves");
is($perl_matrix->{"counts"}{"level_matrices"},0,
 "Perl matrix seed does not prepare level matrices");

# A production run may request the same cube in export order and LG payload
# order. The second product must be an exact transpose of one bounded packed
# cache entry, without starting the helper again.
{
 my $calls="$dir/helper.calls";
 my $wrapper="$dir/counting-helper";
 open(my $fh,">",$wrapper) or die "Unable to write $wrapper: $!";
 print $fh "#!/bin/sh\necho x >> '$calls'\nexec '$bin' 2>/dev/null\n";
 close($fh);
 chmod(0755,$wrapper) or die "Unable to make $wrapper executable: $!";
 local $ENV{"PGEN_AUTOCAL_LUT_NATIVE_BIN"}=$wrapper;
 _lut_native_reset_run_cache();
 no warnings qw(redefine once);
 local *main::_lut_native_verify=sub { return 1; };
 my $slow=_lut_native_u16($solve,$size,"r_slowest");
 my $fast=_lut_native_u16($solve,$size,"r_fastest");
 is_deeply($slow,unprepared_perl_codes($solve,$size,"r_slowest"),
  "cached canonical solve preserves export ordering exactly");
 is_deeply($fast,unprepared_perl_codes($solve,$size,"r_fastest"),
  "cached canonical solve transforms to LG payload ordering exactly");
 open(my $count_fh,"<",$calls) or die "Unable to read $calls: $!";
 my $call_count=()=<$count_fh>;
 close($count_fh);
 is($call_count,1,"equivalent output orders invoke the native helper once");
}

done_testing();

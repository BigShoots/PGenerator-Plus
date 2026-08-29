use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP qw(encode_json decode_json);
use IPC::Open3;
use Symbol qw(gensym);

my $helper="$Bin/../usr/bin/pgen_meter_average.py";
my $math="$Bin/../usr/bin/pgen_colour_math.py";
ok(-x $helper,'meter averaging helper is packaged as an executable');

sub run_average {
 my ($input,$mode,$requested)=@_;
 local %ENV=(%ENV,
  PGEN_AVERAGE_MODE=>defined($mode)?$mode:'off',
  PGEN_REQUESTED_SAMPLE_COUNT=>defined($requested)?$requested:scalar(@{$input||[]}));
 my $err=gensym;
 my $pid=open3(my $stdin,my $stdout,$err,'python3',$helper);
 print {$stdin} encode_json($input);
 close($stdin);
 local $/;
 my $output=<$stdout> // '';
 my $errors=<$err> // '';
 waitpid($pid,0);
 return (($? >> 8),$output,$errors);
}

my $samples=[
 {X=>0.1,Y=>0.2,Z=>0.3,name=>'dim'},
 {X=>0.3,Y=>0.4,Z=>0.5,name=>'dim'},
 {X=>0.2,Y=>0.3,Z=>0.4,name=>'dim'},
];
my ($status,$output,$errors)=run_average($samples,'aa',3);
is($status,0,'three valid readings average successfully');
is($errors,'','valid averaging has no stderr');
my $average=decode_json($output);
cmp_ok(abs($average->{X}-0.2),'<',1e-15,'X is the linear arithmetic mean');
cmp_ok(abs($average->{Y}-0.3),'<',1e-15,'Y is the linear arithmetic mean');
cmp_ok(abs($average->{Z}-0.4),'<',1e-15,'Z is the linear arithmetic mean');
cmp_ok(abs($average->{x}-$average->{X}/($average->{X}+$average->{Y}+$average->{Z})),'<',1e-15,
 'x is derived from averaged XYZ');
cmp_ok(abs($average->{y}-$average->{Y}/($average->{X}+$average->{Y}+$average->{Z})),'<',1e-15,
 'y is derived from averaged XYZ');
is($average->{luminance},$average->{Y},'luminance is the averaged Y component');
is($average->{sample_count},3,'the physical sample count is reported');
is($average->{average_mode},'aa','the selected application mode is reported');
is($average->{requested_sample_count},3,'the requested sample count is reported');

my ($cancel_status,$cancel_output)=run_average([
 {X=>1e16,Y=>1,Z=>1},{X=>1,Y=>1,Z=>1},{X=>-1e16,Y=>1,Z=>1},
],'aa',3);
is($cancel_status,0,'wide-magnitude fixture averages successfully');
my $cancel=decode_json($cancel_output);
cmp_ok(abs($cancel->{X}-(1/3)),'<',1e-15,
 'compensated summation retains the small term across cancellation');

my ($black_status,$black_output)=run_average([
 {X=>0,Y=>0,Z=>0},{X=>0,Y=>0,Z=>0},
],'a',2);
is($black_status,0,'all-black samples average successfully');
my $black=decode_json($black_output);
is_deeply([@{$black}{qw(x y cct)}],[0,0,0],'degenerate black has zero chromaticity and CCT');

my ($empty_status,undef,$empty_error)=run_average([],'a',2);
isnt($empty_status,0,'an empty sample set is rejected');
like($empty_error,qr/at least one reading/i,'empty input reports the validation failure');
my ($nan_status)=run_average([{X=>'NaN',Y=>1,Z=>1}],'off',1);
isnt($nan_status,0,'non-finite measurements are rejected');
my ($short_status)=run_average([{X=>1,Y=>1,Z=>1},{X=>1,Y=>1,Z=>1}],'aaa',5);
isnt($short_status,0,'an incomplete requested sample set is rejected');

# The McCamy CCT cubic itself: every coefficient, both epicentre constants and
# the sign of n are pinned through known illuminants. D65 and illuminant A sit
# on opposite sides of 0.332 in x (flipping n's sign); the blue primary flips
# the denominator's sign (y below 0.1858).
{
 my ($d65_status,$d65_output)=run_average([
  {X=>0.9404559,Y=>0.99,Z=>1.0790578},
  {X=>0.9504559,Y=>1.0,Z=>1.0890578},
  {X=>0.9604559,Y=>1.01,Z=>1.0990578},
 ],'aa',3);
 is($d65_status,0,'a D65 sample set averages successfully');
 is(decode_json($d65_output)->{cct},6505,'D65 mean XYZ reports 6505 K through the McCamy cubic');
 my ($a_status,$a_output)=run_average([{X=>1.09850,Y=>1.00000,Z=>0.35585}],'off',1);
 is($a_status,0,'an illuminant A sample averages successfully');
 is(decode_json($a_output)->{cct},2857,'illuminant A reports 2857 K (opposite sign of n from D65)');
 my ($blue_status,$blue_output)=run_average([{X=>0.15,Y=>0.06,Z=>0.79}],'off',1);
 is($blue_status,0,'a blue-primary sample averages successfully');
 is(decode_json($blue_output)->{cct},1667,'y below the 0.1858 epicentre keeps the cubic finite and pinned');
 my ($zero_y_status,$zero_y_output)=run_average([{X=>1,Y=>0,Z=>1}],'off',1);
 is($zero_y_status,0,'a zero-Y sample with light in other channels averages successfully');
 is(decode_json($zero_y_output)->{cct},0,'the y > 0 guard suppresses CCT for zero-luminance chromaticity');
}

# Merge order and metadata passthrough: the series feeds a MIXED array whose
# first element is a wrapped step reading (step metadata plus defaulted
# sample_count/average_mode stamps) and whose later elements are raw spotread
# parses. Step metadata must survive; the stale per-single-read stamps must be
# overridden by the averaged values.
{
 my ($mixed_status,$mixed_output)=run_average([
  {X=>0.1,Y=>0.2,Z=>0.3,ire=>10,name=>'10% grey',r_code=>58,g_code=>58,b_code=>58,
   sample_count=>1,requested_sample_count=>1,average_mode=>'off'},
  {X=>0.3,Y=>0.4,Z=>0.5},
  {X=>0.2,Y=>0.3,Z=>0.4},
 ],'aa',3);
 is($mixed_status,0,'a mixed wrapped/raw sample set averages successfully');
 my $mixed=decode_json($mixed_output);
 is($mixed->{name},'10% grey','step metadata from the first reading survives the merge');
 is($mixed->{ire},10,'step ire survives the merge');
 is($mixed->{r_code},58,'step drive codes survive the merge');
 is($mixed->{sample_count},3,'the averaged sample count overrides the first reading\'s stamp');
 cmp_ok(abs($mixed->{Y}-0.3),'<',1e-15,'the averaged XYZ overrides the first reading');
}

# Shared-module validation edges.
{
 my $excess=[({X=>1,Y=>1,Z=>1}) x 101];
 my ($excess_status,undef,$excess_error)=run_average($excess,'off',101);
 isnt($excess_status,0,'more than 100 readings are rejected');
 like($excess_error,qr/too many readings/i,'the reading cap names its failure');
 my ($bool_status)=run_average([{X=>JSON::PP::true,Y=>1,Z=>1}],'off',1);
 isnt($bool_status,0,'boolean channel values are rejected');
 my ($non_dict_status)=run_average(['reading'],'off',1);
 isnt($non_dict_status,0,'non-object readings are rejected');
 my ($missing_status)=run_average([{X=>1,Y=>1}],'off',1);
 isnt($missing_status,0,'a reading missing a channel is rejected');
}

# Command-helper validation arms, each isolated: the earlier aaa/2-sample case
# fails both arms at once so neither is proven alone.
{
 my ($legacy_status,undef,$legacy_error)=run_average([{X=>1,Y=>1,Z=>1}],'x_aa',1);
 isnt($legacy_status,0,'legacy spotread flag-set modes are rejected');
 like($legacy_error,qr/unsupported average mode/i,'legacy modes report the unsupported-mode failure');
 my $three=[({X=>1,Y=>1,Z=>1}) x 3];
 my ($mismatch_status,undef,$mismatch_error)=run_average($three,'aa',4);
 isnt($mismatch_status,0,'a requested count that disagrees with the delivered samples is rejected');
 like($mismatch_error,qr/sample count does not match/i,'the count mismatch names its failure');
 my $four=[({X=>1,Y=>1,Z=>1}) x 4];
 my ($mode_status,$mode_output)=run_average($four,'aa',4);
 is($mode_status,0,'the reducer executes a matching numeric count without owning the UI table');
 is(decode_json($mode_output)->{requested_sample_count},4,
  'numeric request metadata survives reduction');
 my ($bad_requested_status)=run_average([{X=>1,Y=>1,Z=>1}],'off','abc');
 isnt($bad_requested_status,0,'a non-integer requested sample count is rejected');
 my $err=gensym;
 my $pid=open3(my $stdin,my $stdout,$err,'python3',$helper);
 print {$stdin} 'not json';
 close($stdin);
 local $/;
 my $ignored_out=<$stdout>;
 my $ignored_err=<$err>;
 waitpid($pid,0);
 isnt(($? >> 8),0,'non-JSON stdin is rejected');
}

open(my $mfh,'<',$math) or die "Unable to read $math: $!";
local $/;
my $math_source=<$mfh>;
close($mfh);
like($math_source,qr/def average_xyz_measurements[\s\S]{0,1800}?math\.fsum/,
 'the shared colour-math module owns the compensated XYZ reduction');
open(my $hfh,'<',$helper) or die "Unable to read $helper: $!";
my $helper_source=<$hfh>;
close($hfh);
like($helper_source,qr/from pgen_meter_result import average_main/,
 'the compatibility command delegates in-process to the shared result helper');

done_testing();

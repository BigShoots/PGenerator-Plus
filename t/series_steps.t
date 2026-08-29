use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json decode_json);
use IPC::Open3;
use Symbol qw(gensym);

my $root="$Bin/..";
my $python=$ENV{"PGEN_PYTHON"}||"python3";
my $helper="$root/usr/bin/pgen_series_steps.py";
$ENV{"PYTHONDONTWRITEBYTECODE"}=1;

sub run_normalizer {
 my ($steps,$generation,$mode,$trigger)=@_;
 my ($fh,$path)=tempfile("pgen-series-steps-XXXXXX",TMPDIR=>1,UNLINK=>1);
 print {$fh} encode_json($steps);
 close($fh);
 my $error=gensym;
 my $pid=open3(undef,my $stdout,$error,$python,$helper,"normalize",$path,
  $generation,$mode,$trigger,"1931_2");
 local $/;
 my $output=<$stdout>||"";
 my $errors=<$error>||"";
 waitpid($pid,0);
 return (($? >> 8),$output,$errors);
}

ok(-x $helper,"series-step normalizer is packaged as an executable");

my $steps=[
 {r=>255,g=>255,b=>255,input_max=>255,patch_size=>10,read_delay_ms=>0,
  ire=>100,name=>"White",target_Yn=>1,series_target_white_y=>100,
  series_target_black_y=>0.01,autocal_white_reference=>JSON::PP::true},
 {r=>26,g=>26,b=>26,input_max=>255,patch_size=>10,read_delay_ms=>250,
  ire=>10,name=>"Dark patch",target_Yn=>0.005,
  series_target_white_y=>100,series_target_black_y=>0.01,
  final_white_refresh=>JSON::PP::false},
];
my ($status,$output,$errors)=run_normalizer($steps,7,"aa",1);
is($status,0,"valid steps normalize");
is($errors,"","valid normalization has no stderr");
my @fields=split(/\0/,$output,-1);
is(pop(@fields),"","stream has one trailing NUL and no trailing text");
is_deeply([splice(@fields,0,4)],["pgen-series-steps","1","7","2"],
 "stream header pins schema, generation, and count");
is(scalar(@fields),32,"each step has sixteen fixed-order fields");
my @first=splice(@fields,0,16);
is_deeply([@first[0..9]],[0,255,255,255,255,10,0,100,"White",""],
 "first step preserves fixed display and identity fields");
is($first[10],"","missing final-white marker is empty");
is($first[11],1,"target Yn retains its scalar text");
is($first[12],"off","100-nit step stays outside low-light averaging");
is($first[13],"true","autocal white-reference marker is normalized");
is_deeply(decode_json($first[14]),$steps->[0],
 "full normalized step preserves original metadata");
my $first_metadata=decode_json('{'.$first[15].'}');
is($first_metadata->{r_code},255,"reading metadata maps red drive code");
is($first_metadata->{observer},"1931_2","reading metadata stamps observer");
my @second=@fields;
is($second[12],"aa","sub-one-nit target uses the selected mode");
is($second[10],"false","false structural marker stays explicit");

my ($nul_status,undef,$nul_errors)=run_normalizer([
 {r=>0,g=>0,b=>0,input_max=>255,ire=>0,name=>"bad\0name"}
],1,"off",1);
isnt($nul_status,0,"embedded NUL is rejected before framing");
like($nul_errors,qr/NUL/i,"embedded NUL failure names the framing rule");

my ($invalid_status,undef,$invalid_errors)=run_normalizer([
 {r=>300,g=>0,b=>0,input_max=>255,ire=>10,name=>"invalid code"}
],1,"off",1);
isnt($invalid_status,0,"drive code outside input_max is rejected");
like($invalid_errors,qr/code|input_max/i,"invalid code failure names its domain");

my @large=map {
 {r=>$_%256,g=>$_%256,b=>$_%256,input_max=>255,ire=>$_/10,
  name=>"Step $_",target_Y=>$_/100}
} (0..999);
my ($large_status,$large_output,$large_errors)=run_normalizer(\@large,19,"aaa",1);
is($large_status,0,"1,000 steps normalize in one invocation");
is($large_errors,"","large normalization has no stderr");
my @large_fields=split(/\0/,$large_output,-1);
is(scalar(@large_fields),4+16*1000+1,
 "1,000-step stream is linear and complete");

my $series_path="$root/usr/bin/meter_series.sh";
open(my $series_fh,"<",$series_path) or die "Unable to read $series_path: $!";
local $/;
my $series_source=<$series_fh>;
close($series_fh);
unlike($series_source,qr/get_step_field|get_step_count/,
 "series worker has no per-field or per-count JSON parser");
like($series_source,qr/prepare_series_steps\(\)[\s\S]{0,2200}?read_step_stream_field/s,
 "series worker consumes the fixed-order NUL stream into run-scoped arrays");
like($series_source,qr/apply_series_white_reference_to_steps[\s\S]{0,500}?prepare_series_steps/s,
 "white-reference mutation explicitly regenerates prepared steps");
like($series_source,qr/apply_dv_absolute_greyscale_targets[\s\S]{0,500}?prepare_series_steps/s,
 "Dolby Vision target mutation explicitly regenerates prepared steps");
my ($build_source)=$series_source=~/^(build_step_reading_json\(\)\s*\{.*?^\})/ms;
ok(defined($build_source),"prepared reading wrapper is present");
unlike($build_source||"",qr/\bpython\b/,
 "reading wrapping reuses prepared metadata without another interpreter");

done_testing();

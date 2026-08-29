use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use IPC::Open3;
use Symbol qw(gensym);

my $root="$Bin/..";
my $python=$ENV{"PGEN_PYTHON"}||"python3";
my $helper="$root/usr/bin/pgen_meter_result.py";
my $core="$root/usr/bin/pgen_colour_math.py";
my $spotread="$root/usr/bin/spotread_measure.py";
my $fixture_path="$Bin/fixtures/measurement_conformance.json";
$ENV{"PYTHONDONTWRITEBYTECODE"}=1;

open(my $fixture_fh,"<",$fixture_path)
 or die "Unable to read $fixture_path: $!";
local $/;
my $fixture=decode_json(<$fixture_fh>);
close($fixture_fh);

sub run_helper {
 my ($command,$input)=@_;
 my $error=gensym;
 my $pid=open3(my $stdin,my $stdout,$error,$python,$helper,$command);
 print {$stdin} $input;
 close($stdin);
 local $/;
 my $output=<$stdout>||"";
 my $errors=<$error>||"";
 waitpid($pid,0);
 return (($? >> 8),$output,$errors);
}

ok(-x $helper,"meter result helper is packaged as an executable");

my ($parse_status,$parse_output,$parse_error)=run_helper(
 "parse",$fixture->{"paired_raw_spotread"}{"line"});
is($parse_status,0,"raw spotread record parses");
is($parse_error,"","valid raw parse has no stderr");
my $parsed=decode_json($parse_output||"{}");
foreach my $field (qw(X Y Z luminance x y cct)) {
 is($parsed->{$field},$fixture->{"paired_raw_spotread"}{"expected"}{$field},
 "raw parse preserves expected $field");
}

foreach my $row (@{$fixture->{"cct_from_xy"}}) {
 my $input=sprintf(
  "Result is XYZ: 1 1 1, Yxy: 1 %.17g %.17g",
  $row->{"x"},$row->{"y"});
 my ($status,$output,$error)=run_helper("parse",$input);
 is($status,0,"$row->{name} CCT row parses");
 is($error,"","$row->{name} CCT row has no stderr");
 is(decode_json($output||"{}")->{"cct"},$row->{"cct"},
  "$row->{name} has the fixture CCT policy");
}

foreach my $row (@{$fixture->{"xyz_derived_fields"}}) {
 my $input="Result is XYZ: ".join(" ",@{$row->{"xyz"}});
 my ($status,$output,$error)=run_helper("parse",$input);
 is($status,0,"$row->{name} XYZ row parses");
 is($error,"","$row->{name} XYZ row has no stderr");
 my $record=decode_json($output||"{}");
 foreach my $field (qw(x y luminance)) {
  cmp_ok(abs($record->{$field}-$row->{$field}),"<",1e-15,
   "$row->{name} derives expected $field");
 }
 is($record->{"cct"},$row->{"cct"},
  "$row->{name} derives expected cct");
}

my ($derived_status,$derived_output)=run_helper(
 "parse","Result is XYZ: 0.9504559 1.0 1.0890578");
is($derived_status,0,"XYZ-only spotread record parses");
my $derived=decode_json($derived_output||"{}");
cmp_ok(abs($derived->{"x"}-0.31269998881729005),"<",1e-15,
 "missing x is derived once from XYZ");
cmp_ok(abs($derived->{"y"}-0.3289999975983),"<",1e-15,
 "missing y is derived once from XYZ");
is($derived->{"cct"},6505,"missing Yxy uses the corrected McCamy sign");

my ($invalid_status,undef,$invalid_error)=run_helper(
 "parse","Result is XYZ: NaN 1.0 1.0, Yxy: 1.0 0.3 0.3");
isnt($invalid_status,0,"non-finite raw XYZ is rejected");
like($invalid_error,qr/not finite/i,"non-finite rejection names the cause");

my ($invalid_yxy_status,undef,$invalid_yxy_error)=run_helper(
 "parse","Result is XYZ: 1 1 1, Yxy: 1 Infinity 0.3");
isnt($invalid_yxy_status,0,"non-finite raw Yxy is rejected");
like($invalid_yxy_error,qr/not finite/i,
 "non-finite raw Yxy rejection names the cause");

my ($last_status,$last_output)=run_helper(
 "parse","Result is XYZ: 1 1 1\n\e[32mResult is XYZ: 2 3 4, Yxy: 5 0.3 0.4\e[0m\r\n");
is($last_status,0,"ANSI-decorated multi-result output parses");
is(decode_json($last_output||"{}")->{"X"},2,
 "the last complete spotread result is selected");

my $core_source;
open(my $core_fh,"<",$core) or die "Unable to read $core: $!";
$core_source=<$core_fh>;
close($core_fh);
like($core_source,qr/^def cct_from_xy\(/m,
 "dependency-free Python core owns McCamy CCT");
like($core_source,qr/^def xyz_derived_fields\(/m,
 "dependency-free Python core owns XYZ-derived fields");

open(my $spotread_fh,"<",$spotread) or die "Unable to read $spotread: $!";
my $spotread_source=<$spotread_fh>;
close($spotread_fh);
like($spotread_source,qr/from pgen_colour_math import cct_from_xy/,
 "legacy spotread command imports the corrected CCT owner");
unlike($spotread_source,qr/y_chrom\s*-\s*0\.1858/,
 "the reversed McCamy denominator cannot return to spotread_measure.py");

foreach my $script (qw(meter_session.sh meter_series.sh spotread_wrapper.sh)) {
 my $path="$root/usr/bin/$script";
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 my $source=<$fh>;
 close($fh);
 like($source,qr/PGEN_METER_RESULT_HELPER[^\n]*pgen_meter_result\.py/,
  "$script routes raw records through the shared result helper");
 unlike($source,qr/449\s*\*[^\n]*3525/,
  "$script has no independent McCamy implementation");
}

done_testing();

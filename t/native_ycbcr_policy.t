use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

my $root=File::Spec->rel2abs("$Bin/..");
my $compiler=$ENV{CXX}||'c++';
my $temp=tempdir("pgen-ycbcr-policy-XXXXXX",TMPDIR=>1,CLEANUP=>1);
my $source="$temp/native_ycbcr_policy.cpp";
my $binary="$temp/native_ycbcr_policy";
open(my $fh,">",$source) or die "Unable to write $source: $!";
print {$fh} <<'CPP';
#include <iostream>
#include "rgb2ycbcr.h"

static void print_case(int bits,int colorimetry,int range,int r,int g,int b) {
 const YCbCrPolicy policy=YCbCrPolicy::Create(bits,colorimetry,range);
 const YCbCr encoded=RGB2YCbCr(RGB(r,g,b),policy);
 const RGB decoded=YCbCrToRGB(encoded,policy);
 (void)decoded;
 std::cout << policy.bits << " " << policy.luma_scale << " "
           << policy.chroma_scale << " " << policy.offset << " "
           << encoded.Y << " " << encoded.Cb << " " << encoded.Cr << "\n";
}

int main() {
 print_case(8,2,1,16,128,235);
 print_case(10,9,2,64,512,940);
 print_case(8,9,2,0,128,255);
 return 0;
}
CPP
close($fh);

my $compile=system($compiler,'-std=c++11','-Wall','-Wextra','-Werror',
 "-I$root/src/pattern_generator/src",$source,'-o',$binary);
is($compile,0,"native YCbCr policy harness compiles warning-free");
SKIP: {
 skip "native YCbCr policy harness did not compile",4 if($compile!=0);
 my $output=`$binary`;
 is($?,0,"native YCbCr policy harness runs");
 my @rows=grep { $_ ne '' } split(/\n/,$output);
 is($rows[0],"8 219 224 128 112 196 66",
  "8-bit BT.709 Limited policy preserves the captured conversion");
 is($rows[1],"10 1020 1024 512 420 790 270",
  "10-bit BT.2020 Full policy preserves the captured conversion");
 is($rows[2],"8 255 256 128 102 210 59",
  "8-bit BT.2020 Full policy preserves the captured conversion");
}

open(my $app_fh,"<","$root/src/pattern_generator/src/ofApp.cpp")
 or die "Unable to read ofApp.cpp: $!";
local $/;
my $app=<$app_fh>;
close($app_fh);
like($app,qr/YCbCrPolicy::Create/,
 "renderer setup consumes the initialized native range/coefficient policy");

done_testing();

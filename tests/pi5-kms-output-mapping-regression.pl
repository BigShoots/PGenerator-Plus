#!/usr/bin/perl
# Locks the Pi5/Bookworm KMS output mappings:
#  - conf rgb_quant_range (1=Limited,2=Full) -> Broadcast RGB (0=Automatic,1=Full,2=Limited)
#  - conf colorimetry + color_format -> KMS Colorspace enum (9=BT2020_RGB,10=BT2020_YCC)
#  - the Pi5 renderer carries the same Broadcast RGB mapping
use strict; use warnings;
my $pass=0; my $fail=0;
sub ok($$) { my($c,$m)=@_; if($c){$pass++; print "ok - $m\n";} else {$fail++; print "NOT OK - $m\n";} }

use FindBin;
my $root="$FindBin::Bin/..";
open(my $fh,'<',"$root/usr/share/PGenerator/command.pm") or die "command.pm: $!";
my $pm=do{local $/;<$fh>}; close($fh);

my ($mbr)=$pm=~/(sub map_broadcast_rgb\(\@\) \{.*?\n\})/s;
ok(defined $mbr, "map_broadcast_rgb exists in command.pm");
my ($mkc)=$pm=~/(sub map_kms_colorspace\(\@\) \{.*?\n\})/s;
ok(defined $mkc, "map_kms_colorspace exists in command.pm");
eval "$mbr; $mkc; 1" or die "eval: $@";

ok(map_broadcast_rgb(1)==2, "conf Limited(1) -> Broadcast RGB Limited(2)");
ok(map_broadcast_rgb(2)==1, "conf Full(2) -> Broadcast RGB Full(1)");
ok(map_broadcast_rgb(0)==0, "conf Default(0) -> Broadcast RGB Automatic(0)");
ok(map_broadcast_rgb("")==0, "conf empty -> Broadcast RGB Automatic(0)");

ok(map_kms_colorspace(9,1)==10, "BT2020(9) + YCbCr -> BT2020_YCC(10)");
ok(map_kms_colorspace(9,0)==9,  "BT2020(9) + RGB -> BT2020_RGB(9)");
ok(map_kms_colorspace(2,1)==2,  "BT709(2) + YCbCr -> BT709_YCC(2)");
ok(map_kms_colorspace(2,0)==0,  "BT709(2) + RGB -> Default(0)");
ok(map_kms_colorspace(0,1)==0,  "Default(0) passes through as 0");

open($fh,'<',"$root/tools/image-targets/pi5-bookworm-armhf/src/ofxRPI4Window/src/ofxRPI4Window.cpp") or die "pi5 renderer: $!";
my $cpp=do{local $/;<$fh>}; close($fh);
ok($cpp=~/pi5_broadcast_rgb_from_rgb_quant_range/, "Pi5 renderer has Broadcast RGB mapping helper");
ok($cpp=~/case 1:\s*\n\s*return 2; \/\/ Limited/, "renderer maps conf 1 -> Broadcast RGB 2 (Limited)");
ok($cpp=~/case 2:\s*\n\s*return 1; \/\/ Full/, "renderer maps conf 2 -> Broadcast RGB 1 (Full)");
ok($cpp=~/"Colorspace"/, "renderer falls back to Colorspace property name");
ok($cpp=~/"Broadcast RGB"/, "renderer falls back to Broadcast RGB property name");

print "\n$pass passed, $fail failed\n";
exit($fail?1:0);

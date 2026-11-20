use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# webui.pm is a bare-sub include, not a loadable package, so the pattern
# subs are pinned by extracting them and evaluating them with the globals
# they read. webui_pattern_scale_triplet once carried a copy of the
# hdr10/hlg bit-depth guard from webui_pattern_effective_bits (issue 82):
# with $signal_mode/$link_bits visible in that scope the triplet call
# returned the scalar 10. Production keeps $link_bits an undeclared
# package global (guard dormant); the harness declares them so the guard
# is LIVE here — exactly the state any future scoping change would create.

my $path="$Bin/../usr/share/PGenerator/webui.pm";
open(my $fh,'<',$path) or BAIL_OUT("cannot open $path: $!");
my $src=do { local $/; <$fh> };
close($fh);
my $code='';
for my $sub (qw(webui_pattern_target_max webui_pattern_scale_value webui_pattern_effective_bits webui_pattern_scale_triplet)) {
 # Anchor on the name and take everything up to the opening brace so a
 # signature or whitespace change does not silently drop the sub.
 my $extracted=($src =~ m{^(sub \Q$sub\E\b.*?\{.*?^\})}ms);
 BAIL_OUT("missing sub $sub in webui.pm") unless $extracted;
 $code.="$1\n";
}
our %pgenerator_conf=();
our $bits_default=8;
our $signal_mode="";
our $link_bits=0;
eval $code;
BAIL_OUT("extract failed: $@") if $@;

# Regression pin for issue 82: with the guard live (globals set, the
# hdr10/hlg promotion in effect), scale_triplet must still return a
# comma-separated triplet, never a scalar bit depth.
for my $mode ("hdr10","hlg") {
 $signal_mode=$mode; $link_bits=10;
 is(webui_pattern_scale_triplet(255,255,255,255,10),"1023,1023,1023",
  "$mode on a 10-bit link: white scales to a triplet, not a scalar");
 is(webui_pattern_scale_triplet(255,0,0,255,10),"1023,0,0",
  "$mode: red triplet");
 is(webui_pattern_scale_triplet(128,128,128,255,10),"512,512,512",
  "$mode: 50% grey keeps the upscale shift");
 is(webui_pattern_scale_triplet(0,0,0,255,10),"0,0,0",
  "$mode: black triplet");
}
$signal_mode=""; $link_bits=0;

# sdr paths unaffected: 8-bit target is a pass-through, 8->10 upscales.
is(webui_pattern_scale_triplet(128,64,32,255,8),"128,64,32",'sdr 8-bit triplet pass-through');
is(webui_pattern_scale_triplet(128,64,32,255,10),"512,256,128",'sdr 8->10 upscale triplet');

# The legitimate home of the guard: webui_pattern_effective_bits keeps
# its hdr10/hlg promotion, its IMAGE 8-bit pin, and its sdr fallback.
%pgenerator_conf=(max_bpc=>10); $bits_default=8;
is(webui_pattern_effective_bits("","hdr10"),10,'effective_bits still promotes hdr10 to 10-bit');
is(webui_pattern_effective_bits("","hlg"),10,'effective_bits still promotes hlg to 10-bit');
is(webui_pattern_effective_bits("IMAGE","hdr10"),8,'IMAGE draws stay 8-bit in effective_bits');
$bits_default=12;
is(webui_pattern_effective_bits("","sdr"),10,'effective_bits maps 12-bit default to the 10-bit path');
$bits_default=8; %pgenerator_conf=();
is(webui_pattern_effective_bits("","sdr"),8,'effective_bits on 8-bit sdr stays 8');

done_testing();

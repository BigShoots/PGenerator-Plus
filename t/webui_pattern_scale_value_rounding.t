use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# webui.pm is a bare-sub include, not a loadable package, so the scaling
# sub is pinned by extracting it (plus the target-max helper it calls)
# and evaluating them. webui_pattern_scale_value takes the target bit
# depth directly; webui_pattern_target_max only reads $bits_default when
# the bits argument is <= 0, but it must still compile under strict.

my $path="$Bin/../usr/share/PGenerator/webui.pm";
open(my $fh,'<',$path) or BAIL_OUT("cannot open $path: $!");
my $src=do { local $/; <$fh> };
close($fh);
my $code='';
for my $sub (qw(webui_pattern_target_max webui_pattern_scale_value)) {
 # Anchor on the name and take everything up to the opening brace so a
 # signature or whitespace change does not silently drop the sub.
 my $extracted=($src =~ m{^(sub \Q$sub\E\b.*?\{.*?^\})}ms);
 BAIL_OUT("missing sub $sub in webui.pm") unless $extracted;
 $code.="$1\n";
}
our $bits_default=8;
eval $code;
BAIL_OUT("extract failed: $@") if $@;

sub endpoint { my($v,$in,$out)=@_; return int($v/$in*$out+0.5); }
sub sweep_mismatch { my($in,$out,$hi,$bits)=@_; my @bad;
 for my $v (0..$hi) { push @bad,[$v,webui_pattern_scale_value($v,$in,$bits)] if webui_pattern_scale_value($v,$in,$bits)!=endpoint($v,$in,$out); }
 return \@bad; }

# The reported Calman defect mirrored on the WebUI generic-patch path:
# input_max=1023 with an 8-bit link used to truncate via >> 2.
is(webui_pattern_scale_value(283,1023,8),71,'283 at 10 bit lands on 71, not the truncated 70');

# Full sweeps: downscale is exactly round(v*target_max/input_max), the
# same convention the daemon-side calman_scale_value now uses.
is_deeply(sweep_mismatch(1023,255,1022,8),[],'every 10->8 code matches the endpoint rule');
is_deeply(sweep_mismatch(4095,255,4094,8),[],'every 12->8 code matches the endpoint rule');
is_deeply(sweep_mismatch(4095,1023,4094,10),[],'every 12->10 code matches the endpoint rule');

# White/black pinning and clamping keep their semantics.
is(webui_pattern_scale_value(1023,1023,8),255,'white pins to target_max');
is(webui_pattern_scale_value(2000,1023,8),255,'a code above input_max clamps then pins');
is(webui_pattern_scale_value(-5,1023,8),0,'a negative code clamps to black');
is(webui_pattern_scale_value(0,1023,8),0,'black stays black');

# Equal depth is a pass-through and upscale keeps the bit-shift behavior
# (the color-bar callers at webui.pm use input_max=255, upscale only).
is(webui_pattern_scale_value(150,1023,10),150,'equal depth passes through untouched');
is(webui_pattern_scale_value(150,255,10),150 << 2,'8->10 upscale stays a shift');
is(webui_pattern_scale_value(255,255,10),1023,'8-bit white still pins to 10-bit white');

# No result may exceed the target max (a rounded-shift fix overflowed to
# 256 for 12->8 codes 4088..4094).
my $over=0;
for my $v (4080..4095) { $over++ if webui_pattern_scale_value($v,4095,8) > 255; }
is($over,0,'codes near 12-bit white never overflow the 8-bit target');

# Divergence band vs the removed truncating shift, pinned explicitly
# (same analysis as the daemon-side test: 255/1023 < 1/4, so codes above
# 683 land a step BELOW the truncated shift).
sub classify { my($hi,$in,$bits,$sh)=@_; my($up,$down)=(0,0);
 for my $v (0..$hi) { my $d=webui_pattern_scale_value($v,$in,$bits)-($v>>$sh); $up++ if $d>0; $down++ if $d<0; }
 return ($up,$down); }
is_deeply([classify(1022,1023,8,2)],[85,85],'10->8: 85 codes a step up, 85 a step down vs the old shift');
is(webui_pattern_scale_value(684,1023,8),(684>>2)-1,'upper band starts at 684: one step below the old shift');
is_deeply([classify(4094,4095,8,4)],[476,476],'12->8: 476 up, 476 down');

done_testing();

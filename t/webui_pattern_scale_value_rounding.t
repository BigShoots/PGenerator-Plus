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

# Same reference as the daemon-side test: the power-of-two shift rounded
# half-up, clamped at white.
sub rounded_shift { my($v,$sh,$max)=@_; my $r=($v+(1<<($sh-1)))>>$sh; return $r>$max ? $max : $r; }
sub sweep_mismatch { my($in,$out,$hi,$bits,$sh)=@_; my @bad;
 for my $v (0..$hi) { push @bad,[$v,webui_pattern_scale_value($v,$in,$bits)] if webui_pattern_scale_value($v,$in,$bits)!=rounded_shift($v,$sh,$out); }
 return \@bad; }
sub aligned_mismatch { my($in,$bits,$sh)=@_; my @bad;
 for my $k (0..(($in+1)>>$sh)-1) { my $v=$k<<$sh; push @bad,[$v,webui_pattern_scale_value($v,$in,$bits)] if webui_pattern_scale_value($v,$in,$bits)!=$k; }
 return \@bad; }

# The reported Calman defect mirrored on the WebUI generic-patch path.
is(webui_pattern_scale_value(283,1023,8),71,'283 at 10 bit lands on 71, not the truncated 70');

# Video reference levels survive the depth change exactly (measured on a
# Pi 4: the endpoint map sent 12-bit 3760 as 939 on a 10-bit link).
is(webui_pattern_scale_value(940,1023,8),235,'10-bit video white 940 is 8-bit 235');
is(webui_pattern_scale_value(3760,4095,10),940,'12-bit video white 3760 is 10-bit 940');
is(webui_pattern_scale_value(3504,4095,10),876,'12-bit 3504 is 10-bit 876');

# Every code on the coarser grid maps back to itself.
is_deeply(aligned_mismatch(1023,8,2),[],'every 4N 10-bit code lands on N at 8 bit');
is_deeply(aligned_mismatch(4095,8,4),[],'every 16N 12-bit code lands on N at 8 bit');
is_deeply(aligned_mismatch(4095,10,2),[],'every 4N 12-bit code lands on N at 10 bit');

# Full sweeps against the rounded-shift reference.
is_deeply(sweep_mismatch(1023,255,1022,8,2),[],'every 10->8 code matches the rounded shift');
is_deeply(sweep_mismatch(4095,255,4094,8,4),[],'every 12->8 code matches the rounded shift');
is_deeply(sweep_mismatch(4095,1023,4094,10,2),[],'every 12->10 code matches the rounded shift');

# White/black pinning and clamping keep their semantics.
is(webui_pattern_scale_value(1023,1023,8),255,'white pins to target_max');
is(webui_pattern_scale_value(1022,1023,8),255,'the near-white carry clamps instead of overflowing to 256');
is(webui_pattern_scale_value(2000,1023,8),255,'a code above input_max clamps then pins');
is(webui_pattern_scale_value(-5,1023,8),0,'a negative code clamps to black');
is(webui_pattern_scale_value(0,1023,8),0,'black stays black');

# Equal depth is a pass-through and upscale keeps the bit-shift behavior
# (the color-bar callers at webui.pm use input_max=255, upscale only).
is(webui_pattern_scale_value(150,1023,10),150,'equal depth passes through untouched');
is(webui_pattern_scale_value(150,255,10),150 << 2,'8->10 upscale stays a shift');
is(webui_pattern_scale_value(255,255,10),1023,'8-bit white still pins to 10-bit white');

# No result may exceed the target max near 12-bit white.
my $over=0;
for my $v (4080..4095) { $over++ if webui_pattern_scale_value($v,4095,8) > 255; }
is($over,0,'codes near 12-bit white never overflow the 8-bit target');

# Relative to the old truncating shift a code only ever moves up a step.
sub classify { my($hi,$in,$bits,$sh)=@_; my($up,$down)=(0,0);
 for my $v (0..$hi) { my $d=webui_pattern_scale_value($v,$in,$bits)-($v>>$sh); $up++ if $d>0; $down++ if $d<0; }
 return ($up,$down); }
is((classify(1022,1023,8,2))[1],0,'10->8: no code lands below the truncated shift');
is((classify(4094,4095,10,2))[1],0,'12->10: no code lands below the truncated shift');

done_testing();

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# daemon.pm is a bare-sub include, not a loadable package, so the scaling
# subs are pinned by extracting them (plus the two helpers they call) and
# evaluating them with the globals they read: %pgenerator_conf and
# $bits_default.

my $path="$Bin/../usr/share/PGenerator/daemon.pm";
open(my $fh,'<',$path) or BAIL_OUT("cannot open $path: $!");
my $src=do { local $/; <$fh> };
close($fh);
my $code='';
for my $sub (qw(calman_dv_source_max calman_target_max calman_scale_value)) {
 # Anchor on the name and take everything up to the opening brace so a
 # signature or whitespace change does not silently drop the sub.
 my $extracted=($src =~ m{^(sub \Q$sub\E\b.*?\{.*?^\})}ms);
 BAIL_OUT("missing sub $sub in daemon.pm") unless $extracted;
 $code.="$1\n";
}
our %pgenerator_conf=();
our $bits_default=8;
eval $code;
BAIL_OUT("extract failed: $@") if $@;

sub endpoint { my($v,$in,$out)=@_; return int($v/$in*$out+0.5); }
sub sweep_mismatch { my($in,$out,$hi)=@_; my @bad;
 for my $v (0..$hi) { push @bad,[$v,calman_scale_value($v,$in)] if calman_scale_value($v,$in)!=endpoint($v,$in,$out); }
 return \@bad; }

# The reported defect: Calman sends 283 (10 bit), which is 70.75 at 8 bit.
%pgenerator_conf=(); $bits_default=8;
is(calman_scale_value(283,1023),71,'283 at 10 bit lands on 71, not the truncated 70');

# Full sweeps: downscale is exactly round(v*target_max/input_max), the
# same half-up convention as the generic fallback branch.
is_deeply(sweep_mismatch(1023,255,1022),[],'every 10->8 code matches the endpoint rule');
is_deeply(sweep_mismatch(4095,255,4094),[],'every 12->8 code matches the endpoint rule');
$bits_default=10;
is_deeply(sweep_mismatch(4095,1023,4094),[],'every 12->10 code matches the endpoint rule');
$bits_default=8;

# White/black pinning and clamping keep their semantics.
is(calman_scale_value(1023,1023),255,'white pins to target_max');
is(calman_scale_value(2000,1023),255,'a code above input_max clamps then pins');
is(calman_scale_value(-5,1023),0,'a negative code clamps to black');
is(calman_scale_value(0,1023),0,'black stays black');

# Equal depth is a pass-through and upscale keeps the bit-shift behavior
# (the rounded-shift downscale variant had no right answer near white;
# these two branches are unchanged by the fix).
%pgenerator_conf=(); $bits_default=10;
is(calman_scale_value(150,1023),150,'equal depth passes through untouched');
is(calman_scale_value(150,255),150 << 2,'8->10 upscale stays a shift');
is(calman_scale_value(255,255),1023,'8-bit white still pins to 10-bit white');

# Dolby Vision source range: the target comes from dv_status/is_std_dovi.
%pgenerator_conf=(dv_status=>1,is_std_dovi=>1); $bits_default=8;
is(calman_scale_value(283,1023),283 << 2,'DV source max overrides the output depth (10->12 shift)');

# No result may exceed the target max (a rounded-shift fix overflowed to
# 256 for 12->8 codes 4088..4094).
%pgenerator_conf=(); $bits_default=8;
my $over=0;
for my $v (4080..4095) { $over++ if calman_scale_value($v,4095) > 255; }
is($over,0,'codes near 12-bit white never overflow the 8-bit target');

done_testing();

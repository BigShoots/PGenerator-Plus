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

# Video code depths scale by powers of two (BT.709 / BT.2100), so the
# reference downscale is the shift rounded half-up, clamped at white.
sub rounded_shift { my($v,$sh,$max)=@_; my $r=($v+(1<<($sh-1)))>>$sh; return $r>$max ? $max : $r; }
sub sweep_mismatch { my($in,$out,$hi,$sh)=@_; my @bad;
 for my $v (0..$hi) { push @bad,[$v,calman_scale_value($v,$in)] if calman_scale_value($v,$in)!=rounded_shift($v,$sh,$out); }
 return \@bad; }
sub aligned_mismatch { my($in,$sh)=@_; my @bad;
 for my $k (0..(($in+1)>>$sh)-1) { my $v=$k<<$sh; push @bad,[$v,calman_scale_value($v,$in)] if calman_scale_value($v,$in)!=$k; }
 return \@bad; }

# The reported defect: Calman sends 283 (10 bit), which is 70.75 at 8 bit.
%pgenerator_conf=(); $bits_default=8;
is(calman_scale_value(283,1023),71,'283 at 10 bit lands on 71, not the truncated 70');

# Video reference levels survive the depth change exactly.
is(calman_scale_value(940,1023),235,'10-bit video white 940 is 8-bit 235');
is(calman_scale_value(64,1023),16,'10-bit video black 64 is 8-bit 16');
is(calman_scale_value(3760,4095),235,'12-bit video white 3760 is 8-bit 235');
$bits_default=10;
is(calman_scale_value(3760,4095),940,'12-bit video white 3760 is 10-bit 940');
is(calman_scale_value(3504,4095),876,'12-bit 3504 is 10-bit 876');
$bits_default=8;

# Every code on the coarser grid maps back to itself (the endpoint map
# broke 85 of these at 10->8 and 341 at 12->10).
is_deeply(aligned_mismatch(1023,2),[],'every 4N 10-bit code lands on N at 8 bit');
is_deeply(aligned_mismatch(4095,4),[],'every 16N 12-bit code lands on N at 8 bit');
$bits_default=10;
is_deeply(aligned_mismatch(4095,2),[],'every 4N 12-bit code lands on N at 10 bit');
$bits_default=8;

# Full sweeps against the rounded-shift reference.
is_deeply(sweep_mismatch(1023,255,1022,2),[],'every 10->8 code matches the rounded shift');
is_deeply(sweep_mismatch(4095,255,4094,4),[],'every 12->8 code matches the rounded shift');
$bits_default=10;
is_deeply(sweep_mismatch(4095,1023,4094,2),[],'every 12->10 code matches the rounded shift');
$bits_default=8;

# White/black pinning and clamping keep their semantics.
is(calman_scale_value(1023,1023),255,'white pins to target_max');
is(calman_scale_value(1022,1023),255,'the near-white carry clamps instead of overflowing to 256');
is(calman_scale_value(2000,1023),255,'a code above input_max clamps then pins');
is(calman_scale_value(-5,1023),0,'a negative code clamps to black');
is(calman_scale_value(0,1023),0,'black stays black');

# Equal depth is a pass-through and upscale keeps the bit-shift behavior.
%pgenerator_conf=(); $bits_default=10;
is(calman_scale_value(150,1023),150,'equal depth passes through untouched');
is(calman_scale_value(150,255),150 << 2,'8->10 upscale stays a shift');
is(calman_scale_value(255,255),1023,'8-bit white still pins to 10-bit white');

# Dolby Vision source range: the target comes from dv_status/is_std_dovi.
%pgenerator_conf=(dv_status=>1,is_std_dovi=>1); $bits_default=8;
is(calman_scale_value(283,1023),283 << 2,'DV source max overrides the output depth (10->12 shift)');

# No result may exceed the target max near 12-bit white.
%pgenerator_conf=(); $bits_default=8;
my $over=0;
for my $v (4080..4095) { $over++ if calman_scale_value($v,4095) > 255; }
is($over,0,'codes near 12-bit white never overflow the 8-bit target');

# Relative to the old truncating shift a code only ever moves up by one
# step (the half-up carry), never down.
sub classify { my($hi,$in,$sh)=@_; my($up,$down)=(0,0);
 for my $v (0..$hi) { my $d=calman_scale_value($v,$in)-($v>>$sh); $up++ if $d>0; $down++ if $d<0; }
 return ($up,$down); }
is((classify(1022,1023,2))[1],0,'10->8: no code lands below the truncated shift');
is((classify(4094,4095,4))[1],0,'12->8: no code lands below the truncated shift');

done_testing();

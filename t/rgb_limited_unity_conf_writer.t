#!/usr/bin/perl
# Issue 74 review finding: the RQ3V1 unity-CSC kernel makes the renderer's
# WIRE "rgb quant range" (3) differ from the conf value (1) for the first
# time. apply_drm_properties() runs while the renderer is alive on two paths
# (same-value ownership hand-off in command.pm, CalMAN non-mode refresh in
# daemon.pm) and its modetest write does not need DRM master — so a raw conf
# write of 1 lands on the live renderer, re-arms the compress CSC, and the
# renderer's direct wire-code drawing starts outputting compressed blacks
# until its next updateAVI_Infoframe(). The fix mirrors the renderer's
# mapping in Perl: unity_wire_rgb_quant_range() maps 1 -> 3 only behind the
# same RQ3V1 srcversion marker, RGB output, DV off. These pins hold the
# mapping, the marker probe, the call-site adoption, and cross-language
# parity with the renderer gate.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

my $dir="$Bin/../usr/share/PGenerator";
do "$dir/command.pm";
plan skip_all => "command.pm subs not loadable" unless defined &main::unity_wire_rgb_quant_range;

# The two probe globals command.pm exposes (command.pm declares them our).
our $vc4_srcversion_path;
our $vc4_unity_marker;

my $tmp=tempdir(CLEANUP=>1);
my $marker="$tmp/srcversion";

sub probe {
 my($sv)=@_;                       # undef => path absent
 if(defined $sv){ open(my $fh,'>',$marker) or die $!; print $fh $sv; close $fh; }
 unlink $marker if -e $marker && !defined $sv;
 $main::vc4_srcversion_path=$marker;
 $main::vc4_unity_marker=-1;       # force one fresh probe
}

# --- stock kernel: the conf value is the wire value, always ---
probe(undef);
is(main::unity_wire_rgb_quant_range(1,0,0),1,'stock kernel (no srcversion): Limited stays 1');
probe("8f3a2b1c9d0e4f5a6b7c8d9e\n");         # stock hex digest shape
is(main::unity_wire_rgb_quant_range(1,0,0),1,'stock hex srcversion: Limited stays 1');
is(main::unity_wire_rgb_quant_range(0,0,0),0,'stock: Default unchanged');
is(main::unity_wire_rgb_quant_range(2,0,0),2,'stock: Full unchanged');

# --- patched RQ3V1 kernel: only conf-Limited + RGB + no-DV maps to 3 ---
probe("RQ3V1-B36D0A2566D75A59BB\n");
is(main::unity_wire_rgb_quant_range(1,0,0),3,'patched kernel: conf Limited (1) writes wire 3');
is(main::unity_wire_rgb_quant_range(1,"",0),3,'empty color_format counts as RGB');
is(main::unity_wire_rgb_quant_range(1,1,0),1,'YCbCr444 must not get unity signalling');
is(main::unity_wire_rgb_quant_range(1,2,0),1,'YCbCr422 must not get unity signalling');
is(main::unity_wire_rgb_quant_range(1,0,1),1,'DV must keep the kernel CSC (wire 1)');
is(main::unity_wire_rgb_quant_range(0,0,0),0,'patched: Default unchanged');
is(main::unity_wire_rgb_quant_range(2,0,0),2,'patched: Full unchanged');

# --- probe is read once, like the renderer's static gate ---
unlink $marker;
is(main::unity_wire_rgb_quant_range(1,0,0),3,'marker cached: deleted sysfs file does not downgrade');

# --- empty srcversion file (present but zero bytes) must not warn ---
# <$fh> on an empty file yields undef, not ""; without the //"" coercion the
# marker regex trips 'Use of uninitialized value' (observed when the file is
# compiled with warnings on, as a plain perl -c/-w harness does). command.pm
# itself carries no 'use warnings', so pin the pattern via eval in a
# warnings-on context rather than through the do-loaded copy.
{
 my $src = do { local $/; open(my $f,'<',"$dir/command.pm") or die $!; <$f> };
 my ($probe_sub) = $src =~ /(sub vc4_rgb_limited_unity_kernel\(\@\) \{.*?\n\})/s;
 ok(defined $probe_sub, 'marker probe sub extracted from command.pm');
 my $tmp2 = tempdir(CLEANUP=>1);
 my $empty = "$tmp2/srcversion"; open(my $e,'>',$empty) or die $!; close $e;
 my @warnings;
 {
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  my $pkg = "PR86WarnProbe::".abs($$);
  eval "package $pkg; use warnings; our \$vc4_srcversion_path='$empty'; our \$vc4_unity_marker=-1; $probe_sub; vc4_rgb_limited_unity_kernel(); 1"
   or die "probe eval failed: $@";
 }
 is(scalar(@warnings),0,'empty srcversion: marker regex is warning-clean (undef coerced via //"")');
}

# --- call site: apply_drm_properties writes the mapped value ---
{
 local $/; open(my $fh,'<',"$dir/command.pm") or die $!; my $src=<$fh>; close $fh;
 like($src, qr/&modetest_connector_write\(\$connector_id,"rgb quant range",\$wire_range\)/,
      'apply_drm_properties writes $wire_range, not the raw conf value');
 like($src, qr/my \$wire_range=&unity_wire_rgb_quant_range\(\$quant_range,\$color_fmt,\$is_dv\)/,
      'wire value derived from conf+format+DV exactly like the renderer gate');
 unlike($src, qr/&modetest_connector_write\(\$connector_id,"rgb quant range",\$quant_range\)/,
      'no remaining raw conf-value write of "rgb quant range"');
}

# --- cross-language parity: both gates key on the identical marker token ---
{
 local $/;
 open(my $fh,'<',"$Bin/../src/ofxRPI4Window/src/ofxRPI4Window.cpp") or die $!;
 my $cpp=<$fh>; close $fh;
 like($cpp, qr/strstr\(version, "RQ3V1"\)/,'renderer gates on the RQ3V1 srcversion marker');
 my ($renderer_gate)= $cpp=~/uint64_t ofxRPI4Window::wireRgbQuantRange\(int rgb_quant_range, int output_format\)\s*\n\{\s*\n\s*if \(([^)]*)\)/s;
 ok(defined $renderer_gate && $renderer_gate=~/rgb_quant_range == 1/
    && $renderer_gate=~/output_format == 0/ && $renderer_gate=~/!isDoVi && !is_std_DoVi/
    && $renderer_gate=~/rgbLimitedPassthroughSupported/,
    'renderer wire mapping is gated on (conf 1, RGB, no DV, marker) — the same four terms the Perl mirror implements');
}

done_testing();

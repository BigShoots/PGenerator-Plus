use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin qw($Bin);
use Digest::SHA qw(sha256_hex);

# Issue 74: the RQ3V1 kernel add-on (src/ofxRPI4Window/vc4_rgb_limited_unity.patch)
# must apply with fuzz 0 to the TRUE preimage of the BiasiLinux shipping kernel
# (linux-5.10.89+-7l) and must produce exactly the intended result.
#
# The fixtures under t/fixtures/vc4-7l/ were lifted verbatim from
# /usr/src/linux-5.10.89+-7l.tar.gz on the bench Pi (uname -r: 5.10.89+-7l).
# Earlier revisions of this test pinned a drm_vc4.patch-era post-image that does
# NOT exist in any shipped -7/-7l tree (it used broadcast_rgb plumbing); that
# false base is exactly what this test now guards against.

my $patch    = "$Bin/../src/ofxRPI4Window/vc4_rgb_limited_unity.patch";
my $fx_hdmi  = "$Bin/fixtures/vc4-7l/vc4_hdmi.c";
my $fx_modp  = "$Bin/fixtures/vc4-7l/modpost.c";
my $renderer = "$Bin/../src/ofxRPI4Window/src/ofxRPI4Window.cpp";
plan skip_all => "missing $patch" unless -f $patch && -f $fx_hdmi && -f $fx_modp;

sub slurp { open my $fh, '<', $_[0] or die "$! $_[0]"; local $/; return <$fh>; }

# --- fixtures must still be byte-exact members of the shipping tree ---
is(sha256_hex(slurp($fx_hdmi)),
   '88eba04aebe81bf017522ea0a5289892d2dbd0701eb89b9e7865999e7578ef8e',
   'vc4_hdmi.c fixture unmodified vs linux-5.10.89+-7l.tar.gz');
is(sha256_hex(slurp($fx_modp)),
   'c2650376ba78d6d1d37f8ec64fdc4e5bf3b54101bc375b012e08eb8fd76dfd4f',
   'modpost.c fixture unmodified vs linux-5.10.89+-7l.tar.gz');

# --- preimage sanity: the -7l property plumbing really is what we target ---
my $pre = slurp($fx_hdmi);
like($pre, qr/rgb_quant_range == HDMI_QUANTIZATION_RANGE_FULL/,
     'preimage gates on rgb_quant_range (the -7l field), not broadcast_rgb');
unlike($pre, qr/broadcast_rgb/, 'preimage has no broadcast_rgb (would be the wrong base)');

# --- patch applies fuzz 0 ---
my $hunks = () = slurp($patch) =~ /^@@/mg;
is($hunks, 3, 'patch carries exactly 3 hunks (2 x vc4_hdmi.c, 1 x modpost.c)');

my $tmp = tempdir(CLEANUP => 1);
system("mkdir -p '$tmp/drivers/gpu/drm/vc4' '$tmp/scripts/mod'") == 0 or die;
copy($fx_hdmi, "$tmp/drivers/gpu/drm/vc4/vc4_hdmi.c") or die;
copy($fx_modp, "$tmp/scripts/mod/modpost.c") or die;
my $out = `cd '$tmp' && patch -p1 -s --fuzz=0 < '$patch' 2>&1`;
is($?, 0, 'add-on applies with fuzz 0') or diag $out;
my @rej = glob("$tmp/**/*.rej");
is(scalar(@rej), 0, 'no .rej files');

# --- post-image invariants ---
my $post = slurp("$tmp/drivers/gpu/drm/vc4/vc4_hdmi.c");

# 1) value 3 (Reserved) reports not-full => AVI signals Limited
like($post,
     qr/if \(conn_state->rgb_quant_range == HDMI_QUANTIZATION_RANGE_RESERVED\)\s*\n\s*return false;/,
     'is_full_range_rgb: Reserved(3) returns false (Limited AVI signalling)');
# the Reserved branch must precede the stock FULL check
ok(index($post, 'HDMI_QUANTIZATION_RANGE_RESERVED)') <
   index($post, 'rgb_quant_range == HDMI_QUANTIZATION_RANGE_FULL'),
   'Reserved branch placed before the stock FULL check');
# stock 0/1/2 logic untouched
like($post,
     qr/return !vc4_encoder->hdmi_monitor \|\|\s*\n\s*drm_default_rgb_quant_range\(mode\) == HDMI_QUANTIZATION_RANGE_FULL;/,
     'stock default branch (values 0/1/2) unchanged');

# 2) Reserved skips the compress matrix; the unconditional trailing
#    HDMI_CSC_CTL write then leaves CSC disabled (unity passthrough).
like($post,
     qr/if \(!vc4_hdmi_is_full_range_rgb\(vc4_hdmi, mode, state\) &&\s*\n\s*state->rgb_quant_range != HDMI_QUANTIZATION_RANGE_RESERVED\) \{/,
     'csc_setup: compress branch guarded off for Reserved(3)');
like($post, qr{/\* The RGB order applies even when CSC is disabled\. \*/\s*\n\s*HDMI_WRITE\(HDMI_CSC_CTL, csc_ctl\);},
     'trailing CSC_CTL write (without ENABLE for value 3) still present');

# 3) modpost stamps only vc4 (modname is the linked .o path in modpost)
my $postm = slurp("$tmp/scripts/mod/modpost.c");
like($postm, qr/!strcmp\(modname \+ strlen\(modname\) - 17,\s*\n\s*"gpu\/drm\/vc4\/vc4\.o"\)/,
     'modpost marker gated to the vc4 linked-object path');
like($postm, qr/"RQ3V1-%\.\*s"/, 'modpost writes the RQ3V1 prefix');
is(() = $postm =~ /RQ3V1/g, 2, 'RQ3V1 literal appears exactly twice (comment + format)');

# --- patch touches only the two expected files ---
my @files = slurp($patch) =~ /^\+\+\+ b\/(\S+)/mg;
is_deeply([sort @files],
          ['drivers/gpu/drm/vc4/vc4_hdmi.c', 'scripts/mod/modpost.c'],
          'patch touches only vc4_hdmi.c and modpost.c (no DRM core changes needed: value 3 is already a valid enum member)');

# --- renderer-side contract (committed separately) stays consistent ---
SKIP: {
    skip 'renderer source not present', 3 unless -f $renderer;
    my $r = slurp($renderer);
    like($r, qr/strstr\(version, "RQ3V1"\)/,
         'renderer gates on the RQ3V1 srcversion marker');
    like($r, qr/rgb_quant_range == 1 && output_format == 0[^\n]*\n[^\n]*\n?\s*return 3;/s,
         'renderer maps conf Limited (1) onto wire value 3 behind the marker');
    like($r, qr/return \(uint64_t\)rgb_quant_range;/,
         'renderer passes stock values through unchanged when not gated in');
}

done_testing();

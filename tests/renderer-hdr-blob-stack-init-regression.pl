#!/usr/bin/env perl
# Regression test: the renderer's HDR_OUTPUT_METADATA blob is created
# from a stack-allocated drm_hdr_output_metadata struct via
# drmModeCreatePropertyBlob(device, &meta, sizeof(meta), &blob_id).
# On 32-bit ARM (both the Pi4 BiasiLinux build and the Pi5 Bookworm
# build) sizeof(drm_hdr_output_metadata) is 32 bytes but only 30 are
# the meaningful payload: 4 bytes of the outer metadata_type and 26
# bytes of the inner hdr_metadata_infoframe union. The struct has 2
# bytes of trailing alignment padding that the renderer used to leave
# uninitialised. drmModeCreatePropertyBlob writes sizeof(meta) bytes
# including the padding, so the kernel blob ended up with stack
# garbage in bytes 30-31. modetest showed the wire as e.g. `00...21
# 02` even in the SDR path where every infoframe field is set to 0.
# The TV parses only the first 26 bytes of the blob per CTA-861-G and
# ignores the padding, but a strict LLDV sink could reject the blob
# because of the non-zero tail, and a future kernel tightening the
# blob length check would outright reject the createblob ioctl.
# pgsethdr.c has done `memset(meta, 0, sizeof(*meta))` here since
# 2018; the renderer source was the odd one out. This test locks in
# the zero-init at the declaration site of `meta` in both renderer
# sources.
use strict;
use Test::More;

for my $plat (qw(pi4-biasi pi5-bookworm-armhf)) {
 my $src = "tools/image-targets/$plat/src/ofxRPI4Window/src/ofxRPI4Window.cpp";
 open(my $fh, '<', $src) or BAIL_OUT("can't read $src: $!");
 local $/; my $code = <$fh>; close $fh;

 # The DOVI sibling struct in the same renderer source already zero-
 # inits at the declaration (`struct dovi_output_metadata dovi = {};`).
 # The HDR struct must do the same.
 like($code,
  qr/struct\s+drm_hdr_output_metadata\s+meta\s*=\s*\{\s*\}\s*;/,
  "$plat: HDR blob struct is zero-initialised at declaration (was leaving "
  ."the 2-byte struct tail uninitialised, leaking stack garbage into "
  ."the kernel blob)");

 # Negative: the old broken form must not be present any more.
 unlike($code,
  qr/struct\s+drm_hdr_output_metadata\s+meta\s*;\s*\n\s*if\s*\(\s*static_cast<int>\s*\(\s*eotf\s*\)/,
  "$plat: old uninitialised declaration form is gone");
}

done_testing();

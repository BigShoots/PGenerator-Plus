#!/usr/bin/env perl
# Regression test: when drmSetMaster hits the auto-grant EACCES race
# and the renderer reopens the DRM device, the cap set on the original
# fd (UNIVERSAL_PLANES, ATOMIC, STEREO_3D=0, ASPECT_RATIO=0) is lost
# when the fd is closed. The reopen path must re-apply the caps on the
# new fd BEFORE drmSetMaster. Without this, the renderer's later
# drmModeObjectGetProperties() on the plane/connector IDs it cached
# during the original query returns an empty property list (CRTC_ID,
# FB_ID, mode enums, etc. all missing), the renderer logs
# "Unable to find CRTC_ID" on every plane in DisablePlane, the first
# atomic commit fails, and the renderer dies in setup. Symptom: a fresh
# DV renderer started by the init script dies in the first FlipPage
# while a renderer started manually (when the auto-grant race does not
# fire) survives.
use strict;
use Test::More;

for my $plat (qw(pi4-biasi pi5-bookworm-armhf)) {
 my $src = "tools/image-targets/$plat/src/ofxRPI4Window/src/ofxRPI4Window.cpp";
 open(my $fh, '<', $src) or BAIL_OUT("can't read $src: $!");
 local $/; my $code = <$fh>; close $fh;

 # The reopen path must re-apply the four caps the kernel needs on the
 # new fd. UNIVERSAL_PLANES + ATOMIC are mandatory; STEREO_3D=0 and
 # ASPECT_RATIO=0 are set on the original fd to suppress extra modes
 # and need to be carried over so the reopen path is functionally
 # equivalent to the original InitDRM setup.
 like($code,
  qr/drmSetClientCap\s*\(\s*device\s*,\s*DRM_CLIENT_CAP_UNIVERSAL_PLANES\s*,\s*1\s*\)/,
  "$plat: re-apply DRM_CLIENT_CAP_UNIVERSAL_PLANES on reopened fd");
 like($code,
  qr/drmSetClientCap\s*\(\s*device\s*,\s*DRM_CLIENT_CAP_ATOMIC\s*,\s*1\s*\)/,
  "$plat: re-apply DRM_CLIENT_CAP_ATOMIC on reopened fd");
 like($code,
  qr/drmSetClientCap\s*\(\s*device\s*,\s*DRM_CLIENT_CAP_STEREO_3D\s*,\s*0\s*\)/,
  "$plat: re-apply DRM_CLIENT_CAP_STEREO_3D=0 on reopened fd");

 # Locate the reopen block and assert the cap re-apply lives inside it
 # (i.e. inside the for(pg_reopen ...) loop body, between the
 # new_fd = open() call and the drmSetMaster(device) call on the new
 # fd). An unanchored check above could pass if a developer
 # re-introduced the cap set elsewhere; the cap has to be on the
 # reopened fd specifically.
  my ($reopen_block) = $code =~ m{
     (                                       # CAPTURE the block
     for\s*\(\s*int\s+pg_reopen\s*=\s*0\s*;\s*pg_reopen\s*<\s*20\s*;\s*pg_reopen\s*\+\+\s*\)
     [\s\S]*?
     open\s*\(\s*dev_name\s*,\s*O_RDWR\s*\|\s*O_CLOEXEC\s*\) # new fd
     [\s\S]*?
     drmSetMaster\s*\(\s*device\s*\)            # authorize on new fd
     [\s\S]*?
     )
  }mx;
 ok(defined $reopen_block, "$plat: found reopen for-loop (open -> drmSetMaster)");

 if (defined $reopen_block) {
  like($reopen_block,
   qr/DRM_CLIENT_CAP_UNIVERSAL_PLANES/,
   "$plat: cap re-apply lives inside the reopen for-loop, not somewhere unrelated");
 }
}

done_testing();

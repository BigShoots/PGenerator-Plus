#!/usr/bin/env perl
# Regression test: both renderer sources contain the reopen-on-EACCES
# fallback for drmSetMaster. When the kernel auto-grant of DRM master
# at open() misses (a root helper holds master at the renderer's open
# instant), drmSetMaster returns EACCES permanently for that fd and
# plain ioctl retries cannot recover it. The fix closes the fd, reopens
# the device so the kernel re-evaluates the auto-grant, and retries.
use strict;
use Test::More;

for my $plat (qw(pi4-biasi pi5-bookworm-armhf)) {
 my $src = "tools/image-targets/$plat/src/ofxRPI4Window/src/ofxRPI4Window.cpp";
 open(my $fh, '<', $src) or BAIL_OUT("can't read $src: $!");
 local $/; my $code = <$fh>; close $fh;

 like($code,
  qr/drmSetMaster\s*\(\s*device\s*\)\s*;[\s\S]{0,400}?pg_try\s*<\s*50/,
  "$plat: existing drmSetMaster 50x100ms retry loop is preserved");

 like($code,
  qr/if\s*\(\s*ret\s*<\s*0\s*&&\s*\(\s*errno\s*==\s*EACCES\s*\|\|\s*errno\s*==\s*EPERM\s*\)\s*\)/,
  "$plat: EACCES/EPERM guard exists for reopen path");

 like($code,
  qr/drmGetDeviceNameFromFd2\s*\(\s*device\s*\)/,
  "$plat: reopens the device via drmGetDeviceNameFromFd2(device)");

 like($code,
  qr/::close\s*\(\s*device\s*\)/,
  "$plat: closes the old fd before reopen");

 like($code,
  qr/open\s*\(\s*dev_name\s*,\s*O_RDWR\s*\|\s*O_CLOEXEC\s*\)/,
  "$plat: reopens with O_RDWR | O_CLOEXEC");

 like($code,
  qr/pg_reopen\s*<\s*20/,
  "$plat: bounded reopen retry (20 tries)");

 like($code,
  qr/usleep\s*\(\s*250000\s*\)/,
  "$plat: 250ms backoff between reopen attempts");
}

done_testing();

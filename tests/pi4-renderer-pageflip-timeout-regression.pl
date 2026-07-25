#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

for my $renderer (
 "src/ofxRPI4Window/src/ofxRPI4Window.cpp",
 "tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp",
) {
 open(my $fh, "<", $renderer) or die "cannot read $renderer: $!";
 local $/;
 my $source = <$fh>;
 close($fh);

 like($source, qr/#include <poll\.h>/, "$renderer includes poll support");
 like($source, qr/poll\(&page_flip_fd,\s*1,\s*1000\)/, "$renderer has a one-second bound");
 like($source, qr/timed out waiting for page flip completion/, "$renderer timeout is diagnosable");
 like($source, qr/ofExit\(1\)/, "$renderer exits on an unknown scanout");
 my $poll_pos = index($source, "ready = poll(&page_flip_fd, 1, 1000)");
 my $event_pos = index($source, "int ret = drmHandleEvent(device, &evctx)");
 ok($poll_pos >= 0 && $event_pos > $poll_pos,
  "$renderer gates drmHandleEvent on readiness");
}

done_testing();

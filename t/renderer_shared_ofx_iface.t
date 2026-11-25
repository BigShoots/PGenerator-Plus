#!/usr/bin/perl
# Cross-addon drift pin (PR 86 review finding): src/pattern_generator is
# compiled for BOTH targets — against src/ofxRPI4Window on Pi 4 and against
# src/ofxRPI4Window-pi5 (tools/scripts/build_and_deploy_pi5_renderer.sh).
# CI only runs prove t/ and no job compiles the Pi 5 renderer, so a shared
# app calling an interface only ONE addon declares builds green here and
# breaks the Pi 5 build (exactly how rgbLimitedPassthrough shipped in PR 86).
# Every ofxRPI4Window::<member> reference in the shared sources must exist
# in BOTH addon headers.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

sub slurp { open my $fh,'<',$_[0] or die "$! $_[0]"; local $/; <$fh> }
sub strip_comments {
    my ($s)=@_;
    $s =~ s{/\*.*?\*/}{}gs;
    $s =~ s{//[^\n]*}{}g;
    return $s;
}

my $root="$Bin/..";
my %refs;
for my $f (qw(src/pattern_generator/src/ofApp.cpp src/pattern_generator/src/main.cpp)) {
    my $src = strip_comments(slurp("$root/$f"));
    while ($src =~ /\bofxRPI4Window::([A-Za-z_]\w*)/g) { $refs{$1}=$f; }
}
ok(scalar(keys %refs) >= 10, 'shared app references a meaningful surface of the window class');

for my $header (['Pi 4',"src/ofxRPI4Window/src/ofxRPI4Window.h"],
                ['Pi 5',"src/ofxRPI4Window-pi5/src/ofxRPI4Window.h"]) {
    my ($label,$rel)=@$header;
    ok(-f "$root/$rel","$label addon header present");
    my $hdr = slurp("$root/$rel");
    my @missing = grep { $hdr !~ /\b\Q$_\E\b/ } sort keys %refs;
    is_deeply(\@missing, [], "every ofxRPI4Window:: symbol used by the shared app is declared in the $label addon header");
}

# Header side of the drift class (round-6 nit 3): the app->header pin above
# only covers symbols the shared app CALLS. A member DEFINED in an addon .cpp
# whose declaration is dropped from that addon's header compiles green under
# every pin above (nothing in the shared app references it) yet breaks that
# addon's own build — exactly the gap around rgbLimitedPassthroughSupported,
# which the app never calls. Every ofxRPI4Window::<member> definition in an
# addon .cpp must have a matching name in that addon's header.
# Definition shapes covered: functions (whitespace-normalized so a
# return-type/signature split across lines still matches) AND out-of-line
# static data-member definitions (`int ofxRPI4Window::isHDR = 0;`) — both
# forms break the addon build if the header declaration is dropped. The
# (?<![=!<>]) guard before '=' keeps comparisons (!=, ==, <=, >=) out of the
# definition set; comparisons to a member name still pin nothing here.
for my $addon (['Pi 4', "src/ofxRPI4Window"], ['Pi 5', "src/ofxRPI4Window-pi5"]) {
    my ($label,$dir)=@$addon;
    my $cpp = strip_comments(slurp("$root/$dir/src/ofxRPI4Window.cpp"));
    my $hdr = strip_comments(slurp("$root/$dir/src/ofxRPI4Window.h"));
    my $flat = $cpp;
    $flat =~ s/\s+/ /g;
    my %defs;
    while ($flat =~ /\bofxRPI4Window::(~?[A-Za-z_]\w*)\s*(?:\(|(?<![=!<>])=|\[)/g) {
        $defs{$1} = 1;
    }
    ok(scalar(keys %defs) >= 20, "$label addon .cpp defines a substantial member surface (".scalar(keys %defs).")");
    my @undef = grep { my $p = $_ =~ /^~/ ? qr/\Q$_\E/ : qr/\b\Q$_\E\b/; $hdr !~ $p } sort keys %defs;
    is_deeply(\@undef, [], "every $label addon .cpp member definition is declared in its header");
}

# The issue-74 RQ3V1 symbols specifically: declared on both addons, and the
# Pi 5 definitions must be inert (false passthrough, identity wire mapping),
# never a second copy of the Pi 4 gate — there is no unity kernel on Pi 5.
{
    my $h5 = slurp("$root/src/ofxRPI4Window-pi5/src/ofxRPI4Window.h");
    my $c5 = slurp("$root/src/ofxRPI4Window-pi5/src/ofxRPI4Window.cpp");
    like($h5, qr/static bool rgbLimitedPassthrough\(\);/, 'Pi 5 header declares rgbLimitedPassthrough');
    like($h5, qr/static uint64_t wireRgbQuantRange\(int rgb_quant_range, int output_format\);/,
         'Pi 5 header declares wireRgbQuantRange with the shared signature');
    like($c5, qr/bool ofxRPI4Window::rgbLimitedPassthrough\(\)\s*\{\s*return false;/s,
         'Pi 5 passthrough predicate is inert (returns false)');
    like($c5, qr/uint64_t ofxRPI4Window::wireRgbQuantRange\(int rgb_quant_range, int output_format\)\s*\{.*?return \(uint64_t\)rgb_quant_range;/s,
         'Pi 5 wire mapping is the identity (conf value is always the wire value)');
    unlike($c5, qr/RQ3V1.*?strstr|srcversion/, 'Pi 5 addon never probes the RQ3V1 marker or srcversion');
}

done_testing();

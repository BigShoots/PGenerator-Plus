use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

# Keep this list identical to the daemon's do-load order in PGeneratord.pl.
# The daemon also imports these modules before loading its project modules;
# doing the same here makes this a render test rather than a reduced mock.
use Cwd;
use Config;
use Time::HiRes qw(usleep);
use IO::Socket::INET;
use IO::Select;
use Getopt::Long;
use File::Copy;
use threads;
use threads::shared;
use URI::Escape;
use MIME::Base64;
use XML::Simple;
use List::Util qw(sum);

my $repo = dirname(dirname(abs_path(__FILE__)));
my $shared = File::Spec->catdir($repo, "usr", "share", "PGenerator");
my @modules = qw(version command variables conf info file log pattern daemon
                 client resolve discovery lg webui bash serial);
my @fragments = qw(webui.html webui-theme.css webui-layout.css webui-body.html
                   webui-logo-dark.html webui-app.js webui-workspace.js
                   webui-lg-card.html webui-lg.js);

chdir $shared or die "cannot chdir to $shared: $!";
for my $module (@modules) {
    my $path = "./$module.pm";
    my $ok = do $path;
    if (!$ok) {
        my $detail = $@ || $! || "module returned false";
        die "$path failed: $detail\n";
    }
}

my $golden_path = File::Spec->catfile($repo, "t", "webui_html_golden.sha256");
open my $golden_fh, "<:raw", $golden_path or die "cannot read $golden_path: $!";
local $/;
my $expected = <$golden_fh> // "";
close $golden_fh;
$expected =~ s/\s+\z//;
like($expected, qr/\A[0-9a-f]{64}\z/, "checked-in golden is a SHA-256 digest");

for my $fragment (@fragments) {
    my $path = File::Spec->catfile($shared, $fragment);
    ok(-f $path && -s $path, "$fragment exists and is non-empty");
}

my $first = main::webui_html();
is(sha256_hex($first), $expected, "render matches the checked-in golden SHA-256");
unlike($first, qr/__PG_[A-Z0-9_]+__/, "render contains no unresolved PG placeholders");

# A second webui_html() call only returns the per-boot cache, so reload the
# module for a genuinely fresh render before asserting determinism.
do "./webui.pm" or die "webui.pm reload failed: $@ $!\n";
my $second = main::webui_html();
is($second, $first, "render is deterministic across two fresh renders");

done_testing();

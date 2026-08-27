use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

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
my $golden_path = File::Spec->catfile($repo, "t", "webui_html_golden.sha256");
open my $golden_fh, "<:raw", $golden_path or die "cannot read $golden_path: $!";
local $/;
my $golden = <$golden_fh> // "";
close $golden_fh;
$golden =~ s/\s+\z//;

my $temp = tempdir("pgenerator-webui-recovery-XXXXXX", TMPDIR => 1, CLEANUP => 1);
copy(File::Spec->catfile($shared, "webui.pm"), File::Spec->catfile($temp, "webui.pm"))
    or die "cannot stage webui.pm: $!";
copy(File::Spec->catfile($shared, "PGMath.pm"), File::Spec->catfile($temp, "PGMath.pm"))
    or die "cannot stage PGMath.pm: $!";
copy(File::Spec->catfile($shared, "PGICCProfile.pm"), File::Spec->catfile($temp, "PGICCProfile.pm"))
    or die "cannot stage PGICCProfile.pm: $!";
copy(File::Spec->catfile($shared, "icc_profile.html"), File::Spec->catfile($temp, "icc_profile.html"))
    or die "cannot stage icc_profile.html: $!";
my @fragments = qw(webui.html webui-theme.css webui-layout.css webui-body.html
                   webui-logo-dark.html webui-app.js webui-workspace.js
                   webui-lg-card.html webui-lg.js);
my $missing = "webui-app.js";
for my $fragment (@fragments) {
    next if $fragment eq $missing;
    copy(File::Spec->catfile($shared, $fragment), File::Spec->catfile($temp, $fragment))
        or die "cannot stage $fragment: $!";
}

# The boot check intentionally logs the missing file. Capture the daemon's
# stdout while loading and serving the first recovery response so its
# diagnostic does not become noisy TAP output.
my $log_capture = File::Spec->catfile($temp, "boot.log");
open my $saved_stdout, ">&", \*STDOUT or die "cannot save stdout: $!";
open STDOUT, ">:raw", $log_capture or die "cannot capture stdout: $!";
chdir $temp or die "cannot chdir to $temp: $!";
for my $module (qw(version command variables conf info file log pattern daemon client
                   resolve discovery lg)) {
    my $path = File::Spec->catfile($shared, "$module.pm");
    my $ok = do $path;
    die "$path failed: $@ $!\n" unless $ok;
}
my $webui_ok = do File::Spec->catfile($temp, "webui.pm");
die "staged webui.pm failed: $@ $!\n" unless $webui_ok;

my $rejected_path = main::webui_asset("../webui.pm");
open my $empty_fragment_fh, ">:raw", File::Spec->catfile($temp, $missing)
    or die "cannot stage an empty $missing: $!";
close $empty_fragment_fh or die "cannot close empty $missing: $!";
my $empty_fragment = main::webui_asset($missing);
unlink File::Spec->catfile($temp, $missing) or die "cannot remove empty $missing: $!";
my $recovery = main::webui_html();
open STDOUT, ">&", $saved_stdout or die "cannot restore stdout: $!";
open my $log_fh, "<:raw", $log_capture or die "cannot read boot log: $!";
local $/;
my $boot_log = <$log_fh> // "";
close $log_fh;
like($boot_log, qr/WebUI ERROR: required UI fragment .*webui-app\.js/,
     "boot-time check logs a missing fragment without refusing startup");
is($rejected_path, "", "loader rejects a non-whitelisted path");
is($empty_fragment, "", "loader rejects an empty fragment");
like($recovery, qr/<!--PG_RECOVERY_PAGE-->/, "missing fragment serves the recovery sentinel");
like($recovery, qr/webui-app\.js/, "recovery page identifies the missing fragment");
like($recovery, qr/<form[^>]+action="\/api\/update\/apply"[^>]+method="post"/i,
     "recovery page offers the existing OTA POST endpoint");
unlike($recovery, qr/<script\b/i, "recovery page has no JavaScript dependency");
like($recovery, qr/Hostname.*Version|Version.*Hostname/s, "recovery page shows device identity");

# Restore the fragment in the same loaded process. Failure responses are not
# cached, so the normal page must recover without restarting the daemon.
copy(File::Spec->catfile($shared, $missing), File::Spec->catfile($temp, $missing))
    or die "cannot restore $missing: $!";
my $normal = main::webui_html();
is(sha256_hex($normal), $golden, "restoring the fragment recovers the golden page without a restart");
unlink File::Spec->catfile($temp, $missing) or die "cannot remove temporary test fragment: $!";
is(main::webui_html(), $normal, "a successful page is cached for the boot");
copy(File::Spec->catfile($shared, $missing), File::Spec->catfile($temp, $missing))
    or die "cannot restore $missing: $!";

# The remaining scenarios need a fresh module load each time: the per-boot
# page cache is already warm, and a reload is exactly a daemon restart.
sub reload_webui {
    open my $saved, ">&", \*STDOUT or die "cannot save stdout: $!";
    open STDOUT, ">>:raw", $log_capture or die "cannot capture stdout: $!";
    # webui.pm requires PGICCProfile.pm; evict it from %INC so a reload is a
    # genuine cold boot with the ICC asset cache empty, like a real restart.
    delete $INC{File::Spec->catfile($temp, "PGICCProfile.pm")};
    my $ok = do File::Spec->catfile($temp, "webui.pm");
    my $render = $ok ? main::webui_html() : undef;
    open STDOUT, ">&", $saved or die "cannot restore stdout: $!";
    die "staged webui.pm reload failed: $@ $!\n" unless $ok;
    return $render;
}

# An empty fragment that is present on disk must serve the recovery page too.
open my $truncate_fh, ">:raw", File::Spec->catfile($temp, $missing)
    or die "cannot truncate $missing: $!";
close $truncate_fh or die "cannot close truncated $missing: $!";
my $empty_page = reload_webui();
like($empty_page, qr/<!--PG_RECOVERY_PAGE-->/,
     "an empty on-disk fragment serves the recovery page");
copy(File::Spec->catfile($shared, $missing), File::Spec->catfile($temp, $missing))
    or die "cannot restore $missing: $!";

# The LG fragments reach the assembler through lg.pm's splices and the
# missing-asset flag, not the skeleton marker loop — drill that path too.
unlink File::Spec->catfile($temp, "webui-lg.js") or die "cannot remove webui-lg.js: $!";
my $lg_recovery = reload_webui();
like($lg_recovery, qr/<!--PG_RECOVERY_PAGE-->/,
     "a missing LG fragment serves the recovery page");
like($lg_recovery, qr/webui-lg\.js/, "recovery page identifies the missing LG fragment");
copy(File::Spec->catfile($shared, "webui-lg.js"), File::Spec->catfile($temp, "webui-lg.js"))
    or die "cannot restore webui-lg.js: $!";
is(sha256_hex(main::webui_html()), $golden,
   "restoring the LG fragment recovers the golden page without a restart");

# icc_profile.html is spliced by a marker-consuming substitution; a missing
# file must not slip past the residual placeholder check or be cached.
unlink File::Spec->catfile($temp, "icc_profile.html") or die "cannot remove icc_profile.html: $!";
my $icc_recovery = reload_webui();
like($icc_recovery, qr/<!--PG_RECOVERY_PAGE-->/,
     "a missing ICC workspace fragment serves the recovery page");
like($icc_recovery, qr/icc_profile\.html/, "recovery page identifies the ICC fragment");
copy(File::Spec->catfile($shared, "icc_profile.html"), File::Spec->catfile($temp, "icc_profile.html"))
    or die "cannot restore icc_profile.html: $!";
is(sha256_hex(main::webui_html()), $golden,
   "restoring the ICC fragment recovers the golden page without a restart");

# A skeleton whose marker line was lost must not serve a page with a hole.
my $skeleton_path = File::Spec->catfile($temp, "webui.html");
open my $skeleton_fh, "<:raw", $skeleton_path or die "cannot read staged skeleton: $!";
my $skeleton = do { local $/; <$skeleton_fh> // "" };
close $skeleton_fh;
(my $broken_skeleton = $skeleton) =~ s/^__PG_JS_APP__\n/__PG_JS_APP_LOST__\n/m
    or die "staged skeleton is missing the __PG_JS_APP__ marker\n";
open $skeleton_fh, ">:raw", $skeleton_path or die "cannot rewrite staged skeleton: $!";
print {$skeleton_fh} $broken_skeleton or die "cannot write staged skeleton: $!";
close $skeleton_fh or die "cannot close staged skeleton: $!";
my $marker_recovery = reload_webui();
like($marker_recovery, qr/<!--PG_RECOVERY_PAGE-->/,
     "a skeleton without its marker serves the recovery page");
like($marker_recovery, qr/__PG_JS_APP__/,
     "recovery page names the marker that was not replaced");
open $skeleton_fh, ">:raw", $skeleton_path or die "cannot restore staged skeleton: $!";
print {$skeleton_fh} $skeleton or die "cannot restore staged skeleton: $!";
close $skeleton_fh or die "cannot close staged skeleton: $!";
# Unlike a missing fragment, the broken skeleton was a successful (non-empty)
# read and is therefore cached for the boot; recovery here takes a restart.
is(sha256_hex(reload_webui()), $golden,
   "restoring the skeleton recovers the golden page after a reload");

done_testing();

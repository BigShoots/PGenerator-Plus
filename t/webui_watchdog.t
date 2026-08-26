use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $repo = dirname(dirname(abs_path(__FILE__)));
my $script = File::Spec->catfile($repo, "usr", "sbin", "pgenerator-webui-watchdog.sh");
my $temp = tempdir("pgenerator-watchdog-XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $bin = File::Spec->catdir($temp, "bin");
mkdir $bin or die "cannot create $bin: $!";
my $log = File::Spec->catfile($temp, "watchdog.log");
my $restart_log = File::Spec->catfile($temp, "watchdog-restart.log");

sub write_executable {
    my ($name, $body) = @_;
    my $path = File::Spec->catfile($bin, $name);
    open my $fh, ">", $path or die "cannot write $path: $!";
    print {$fh} $body or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
    chmod 0755, $path or die "cannot chmod $path: $!";
}

# The ping stub: healthy unless PG_WATCHDOG_WGET_MODE=down.
write_executable("wget", <<'WGET');
#!/bin/sh
[ "${PG_WATCHDOG_WGET_MODE:-up}" = "down" ] && exit 1
exit 0
WGET

# The root-probe stub. The watchdog fetches `/` twice at most: first with
# `-o /dev/null -w '%{http_code} %{size_download}'` for status and size, then
# — only for a small 200 response — once more with `-o <file>` for the body.
write_executable("curl", <<'CURL');
#!/bin/sh
body=
fmt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) body=$2; shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    -D) shift 2 ;;
    --max-time) shift 2 ;;
    *) shift ;;
  esac
done
case "${PG_WATCHDOG_CURL_MODE:-recovery}" in
  connectfail)
    echo 'curl: (7) Failed to connect to 127.0.0.1 port 80' >&2
    exit 7
    ;;
  non200)  code=503; content='unavailable' ;;
  short)   code=200; content='short' ;;
  healthy) code=200; content='page'; fake_size=2646610 ;;
  *)       code=200; content='<!--PG_RECOVERY_PAGE-->' ;;
esac
[ -n "$body" ] && [ "$body" != "/dev/null" ] && printf '%s' "$content" >"$body"
[ -n "$fmt" ] && printf '%s %s' "$code" "${fake_size:-${#content}}"
exit 0
CURL

# A harmless stand-in for /etc/init.d/PGenerator so the restart path can run.
my $init_stub = File::Spec->catfile($bin, "init-stub");
write_executable("init-stub", <<'INIT');
#!/bin/sh
echo "init stub: $*"
exit 0
INIT

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{PG_WATCHDOG_LOG} = $log;
local $ENV{PG_WATCHDOG_TMPDIR} = $temp;
local $ENV{PG_WATCHDOG_INIT} = $init_stub;

# Ping healthy, root degraded in three different ways: log-only, no restart.
for my $mode (qw(recovery short non200 connectfail)) {
    local $ENV{PG_WATCHDOG_CURL_MODE} = $mode;
    is(system("sh", $script), 0, "watchdog exits cleanly for $mode root response");
}

open my $log_fh, "<:raw", $log or die "cannot read $log: $!";
my $log_text = do { local $/; <$log_fh> // "" };
close $log_fh;
like($log_text, qr/ERROR: WebUI root probe found the fragment recovery page/,
     "healthy ping still logs a degraded root response");
like($log_text, qr/ERROR: WebUI root probe returned only\s+5 bytes/,
     "a short root response is logged");
like($log_text, qr/ERROR: WebUI root probe returned HTTP 503/,
     "a non-200 root response is logged");
like($log_text, qr/ERROR: WebUI root probe failed to connect: .*Failed to connect/,
     "a connect failure is logged with the curl error detail");
unlike($log_text, qr/WebUI down .*restarting/i,
       "a root-only failure never triggers a restart");

# A full-size healthy response stamps the daemon PID. The stamp suppresses an
# immediate repeat, expires after 15 minutes so another ithread is sampled,
# and is also invalidated immediately by a new daemon PID.
{
    my $stamp_log = File::Spec->catfile($temp, "watchdog-stamp.log");
    my $pid_file = File::Spec->catfile($temp, "PGeneratord.pl.pid");
    open my $pid_fh, ">", $pid_file or die "cannot write $pid_file: $!";
    print {$pid_fh} "4242\n";
    close $pid_fh;
    local $ENV{PG_WATCHDOG_LOG} = $stamp_log;
    local $ENV{PG_WATCHDOG_PID_FILE} = $pid_file;
    {
        local $ENV{PG_WATCHDOG_CURL_MODE} = "healthy";
        is(system("sh", $script), 0, "watchdog exits cleanly for a healthy full-size root");
    }
    my $stamp = File::Spec->catfile($temp, "pgenerator-watchdog-root-ok");
    ok(-f $stamp, "a healthy full-size probe writes the root-ok stamp");
    {
        local $ENV{PG_WATCHDOG_CURL_MODE} = "connectfail";
        is(system("sh", $script), 0, "watchdog exits cleanly when a fresh stamp skips the probe");
    }
    my $stamp_text = "";
    if (open my $fh, "<:raw", $stamp_log) {
        local $/;
        $stamp_text = <$fh> // "";
        close $fh;
    }
    is($stamp_text, "", "a freshly stamped daemon instance is not re-probed");

    my $old=time()-16*60;
    utime($old,$old,$stamp) or die "cannot age $stamp: $!";
    {
        local $ENV{PG_WATCHDOG_CURL_MODE} = "connectfail";
        is(system("sh", $script), 0, "watchdog exits cleanly after the stamp expires");
    }
    $stamp_text = do {
        open my $fh, "<:raw", $stamp_log or die "cannot read $stamp_log: $!";
        local $/; <$fh> // "";
    };
    like($stamp_text, qr/ERROR: WebUI root probe failed to connect/,
         "an expired stamp re-probes another worker for the same PID");
    open my $clear_fh, ">", $stamp_log or die "cannot clear $stamp_log: $!";
    close $clear_fh;

    open $pid_fh, ">", $pid_file or die "cannot write $pid_file: $!";
    print {$pid_fh} "4343\n";
    close $pid_fh;
    {
        local $ENV{PG_WATCHDOG_CURL_MODE} = "connectfail";
        is(system("sh", $script), 0, "watchdog exits cleanly after a daemon restart");
    }
    $stamp_text = do {
        open my $fh, "<:raw", $stamp_log or die "cannot read $stamp_log: $!";
        local $/; <$fh> // "";
    };
    like($stamp_text, qr/ERROR: WebUI root probe failed to connect/,
         "a new daemon PID invalidates the stamp and the probe runs again");
    unlink $stamp;
}

# Ping down: the pre-existing restart contract must still hold.
{
    local $ENV{PG_WATCHDOG_LOG} = $restart_log;
    local $ENV{PG_WATCHDOG_WGET_MODE} = "down";
    local $ENV{PG_WATCHDOG_CURL_MODE} = "connectfail";
    is(system("sh", $script), 0, "watchdog exits cleanly on the restart path");
}
open my $restart_fh, "<:raw", $restart_log or die "cannot read $restart_log: $!";
my $restart_text = do { local $/; <$restart_fh> // "" };
close $restart_fh;
like($restart_text, qr/WebUI down .*restarting PGenerator/i,
     "a failed ping still triggers a restart");
like($restart_text, qr/init stub: restart/,
     "the restart path invokes the init script");
like($restart_text, qr/WebUI still down after restart/,
     "a restart that does not recover is logged");
unlike($restart_text, qr/ERROR: WebUI root probe failed to connect/,
       "the restart path does not add redundant probe noise");
ok(!-f File::Spec->catfile($temp, "pgenerator-watchdog.lock"),
   "the restart path removes its lock file");

done_testing();

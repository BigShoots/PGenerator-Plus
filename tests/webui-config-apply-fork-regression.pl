#!/usr/bin/env perl
# Regression test: /api/config POST applies must not block the HTTP server.
#
# The bug: webui.pm ran pattern_generator_stop()+start() synchronously in
# the HTTP request context. An HDR apply loses the documented DRM-master
# race (pgsethdr steals DRM master from the newly-spawned renderer) on
# every attempt of the retry ladder, so the POST hung for 10-19s, the
# browser's polls timed out, and the user saw "connection errors" while
# the renderer stayed dead on the previous mode.
#
# The fix: the restart is double-forked. The worker (reparented to init,
# so no zombies and no reaping needed in the daemon) runs
# load_new_pattern_file's retry ladder and re-pushes the last pattern;
# the intermediate child exits at once and is reaped synchronously by
# the parent, which returns to the accept loop immediately.
#
# A global $SIG{CHLD} reaper is deliberately NOT used: this process runs
# system()/backticks/piped opens everywhere and checks $? afterwards
# (e.g. modetest_connector_write in command.pm); a waitpid(-1,...)
# handler steals those exit statuses. An earlier revision used one and
# it both failed to reap reliably and risked breaking every $? check.
use strict;
use warnings;
use Test::More;

my $webui = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $webui) or BAIL_OUT("can't read $webui: $!");
local $/; my $src = <$fh>; close $fh;

# Isolate the /api/config POST handler region for the fork assertions.
my ($post) = $src =~ m{(elsif\(\$method eq "POST"\) \{.{0,8000}?\n\s+\}\n\s+\}\n\s+\}\n)}s;
ok(defined $post, 'found the /api/config POST handler block')
  or BAIL_OUT('cannot isolate POST handler; later assertions would be meaningless');

# 1. The apply restart is forked, not run in the request context.
like($post, qr/my \$pid=fork\(\);/, 'POST handler forks the renderer restart');

# 2. Double-fork: the worker is detached via a second fork so it is
#    reparented to init (no zombie, no reaper needed).
like($post, qr/my \$worker=fork\(\);/, 'restart worker is double-forked');

# 3. The intermediate child exits immediately after spawning the worker.
like($post, qr/my \$worker=fork\(\);.{0,3000}?\n\s+exit\(0\);/s,
  'intermediate child exits immediately');

# 4. The parent reaps the intermediate child synchronously.
like($post, qr/waitpid\(\$pid,0\);/, 'parent reaps the intermediate child');

# 5. The worker uses the retry-ladder path and re-pushes the last pattern.
like($post, qr/load_new_pattern_file\("webui apply"\)/,
  'worker restarts via load_new_pattern_file (retry ladder + pattern re-push)');

# 5a. Apply workers are serialized with an exclusive flock: overlapping
#     workers interleave their stop/start ladders and kill each other's
#     renderer (a failed ladder runs 30-40s, plenty of time for a second
#     apply to arrive). The handle must outlive the if-block.
like($post, qr/my \$pg_apply_lock;\s*\n(?:\s+#[^\n]*\n)*\s+if\(open\(\$pg_apply_lock,'>',"\$var_dir/,
  'apply worker takes a serialization lock in the daemon-writable state dir');
like($post, qr/flock\(\$pg_apply_lock,2\);/, 'lock is exclusive (LOCK_EX)');

# 5b. The worker STOPS the renderer before load_new_pattern_file: a
#     signal-mode change requires a full restart, and
#     load_new_pattern_file only starts the renderer when it is not
#     already running. Without the stop the apply is a silent no-op
#     whenever the renderer survived the mode change.
like($post, qr/pattern_generator_stop\(\);\n\s+&load_new_pattern_file\("webui apply"\)/,
  'worker stops the renderer before the retry-ladder start');

# 6. The worker restores default child handling for its own system() calls.
like($post, qr/\$SIG\{CHLD\}='DEFAULT';/, 'worker resets SIGCHLD to DEFAULT');

# 7. Fork failure still honours the apply in-process.
like($post, qr/if\(!defined \$pid\) \{.{0,400}?pattern_generator_stop\(\);.{0,100}?pattern_generator_start\(\);/s,
  'fork-failure fallback restarts in-process');

# 8. No global SIGCHLD reaper anywhere in webui.pm: it would steal exit
#    statuses from system()/backticks ($? checks) across the daemon.
unlike($src, qr/\$SIG\{CHLD\}\s*=\s*sub/,
  'no global $SIG{CHLD} reaper is installed');

# 9. The actual renderer killer: pgsethdr must never run while a renderer
#    is alive. apply_hdr_metadata_helper() used to run right after the
#    renderer spawn and its drmSetMaster killed the initializing renderer
#    on every HDR apply (SDR applies never call the helper). The helper
#    must be guarded on pattern_generator_is_running().
my $command = 'usr/share/PGenerator/command.pm';
open($fh, '<', $command) or BAIL_OUT("can't read $command: $!");
local $/; my $cmd_src = <$fh>; close $fh;
like($cmd_src,
  qr/sub apply_hdr_metadata_helper \(\@\) \{.{0,2000}?if\(&pattern_generator_is_running\(\)\) \{\s*\n\s*&log\("DRM: skipping pgsethdr/s,
  'apply_hdr_metadata_helper skips pgsethdr while the renderer is running');

done_testing();

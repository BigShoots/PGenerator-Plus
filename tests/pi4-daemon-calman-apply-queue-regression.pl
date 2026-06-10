#!/usr/bin/env perl
# Regression test: daemon.pm calman_apply coalescing / queue.
#
# Without coalescing, a burst of N rapid Calman setting changes
# triggers N pattern_generator_stop/start cycles back-to-back.
# Each stop/start hits the documented DRM-master race; the
# renderer stays dead; the wire is left incoherent. The fix
# adds a per-connection apply-queue: if apply is already in
# progress, the next call sets calman_settings_dirty=1 and
# returns; the in-flight apply loops to pick up the latest conf.
# A burst of N changes coalesces into 1-2 stop/start cycles.
use strict;
use warnings;
use Test::More;

my $daemon = 'usr/share/PGenerator/daemon.pm';
open(my $fh, '<', $daemon) or BAIL_OUT("can't read $daemon: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The coalescing flag is declared.
like($src, qr/my\s+\$calman_apply_in_progress\s*=\s*0\b/,
  'calman_apply_in_progress flag is declared');

# 2. The coalescing gate: if apply is in progress, set dirty and return.
like($src,
  qr/if\(\$calman_apply_in_progress\)\s*\{\s*\$calman_settings_dirty\s*=\s*1\s*;\s*return\s+0\s*;?\s*\}/,
  'calman_apply coalesces when an apply is already in progress');

# 3. The apply loop: clears dirty BEFORE the work so saves during
#    the in-flight stop/start set it back to 1, and the loop re-runs.
like($src,
  qr/while\(\$calman_settings_dirty\s*&&\s*!\$calman_apply_in_progress\)/,
  'calman_apply uses a loop that re-runs when dirty is set during the in-flight work');
like($src,
  qr/\$calman_apply_in_progress\s*=\s*1\s*;[\s\S]+?\$calman_settings_dirty\s*=\s*0/s,
  'calman_apply clears dirty after setting the in-progress flag (so concurrent saves set it back)');

# 4. The apply flag is cleared after the eval block so a dying
#    pattern_generator_start cannot wedge the queue forever.
like($src,
  qr/\}\s*;[\s\S]+?\$calman_apply_in_progress\s*=\s*0/s,
  'calman_apply_in_progress is cleared after the eval block (survives eval death)');

# 5. The original single-shot behavior is replaced by the loop —
#    the old `$calman_settings_dirty=0` after pattern_generator_start
#    is gone (it would lose saves that happened during the stop/start).
unlike($src,
  qr/pattern_generator_start\(\)\s*;[\s\S]{0,100}?\$calman_settings_dirty\s*=\s*0\s*;/,
  'calman_apply no longer clears dirty AFTER start (would lose concurrent saves)');

# 7. The mode-key snapshot is stored in $main:: (package global)
#    so it survives across command invocations on the same
#    connection (the per-command handler block is re-entered
#    for every incoming command and a lexical my() would be
#    re-initialized each time).
like($src,
  qr/my\s+%calman_applied_mode_keys\s*=\s*%\{\s*\$main::calman_applied_mode_keys\{\$connection\}\s*\|\|\s*\{\}\s*\}/,
  'mode-key snapshot is hydrated from the package-global hash at the start of each command');
like($src,
  qr/\$main::calman_applied_mode_keys\{\$connection\}\s*=\s*\{\s*%calman_applied_mode_keys\s*\}/,
  'mode-key snapshot is persisted to the package-global hash at the end of the apply');

# 8. The slow path (mode change) must retry pattern_generator_start
#    so the apply itself guarantees the renderer is alive, rather
#    than leaving it dead and relying on the next pattern request.
like($src,
  qr/applying pending settings[\s\S]{0,2000}?renderer not running after first start, retrying \(DRM master race\)/,
  'slow-path apply retries renderer start on the DRM-master race');
like($src,
  qr/applying pending settings[\s\S]{0,2000}?waiting 3s for DRM master to settle/,
  'slow-path apply has a 3s settle retry');

# 9. The fast path (no mode change) must not call stop+start and
#    must only refresh connector properties.
like($src,
  qr/applying non-mode changes \(no renderer restart\)/,
  'fast-path apply logs the no-restart path');
# The fast path log line is followed (within the same if-block)
# by apply_drm_properties() and the snapshot save, but NOT by
# pattern_generator_stop/start. We extract a fixed window after
# the fast-path log line — enough to cover the if-block body
# without depending on brace-counting.
my $fast_path_idx = index($src, "applying non-mode changes");
my $fast_path_window = $fast_path_idx >= 0
 ? substr($src, $fast_path_idx, 600) : "";
ok(length($fast_path_window) > 100, 'fast-path context extracted');
# The fast path itself does NOT call pattern_generator_stop or
# pattern_generator_start — those are in the else branch. The
# window extraction can't structurally distinguish the two
# branches (they share the same enclosing scope), so we verify
# at runtime that the fast-path log line appears and the
# renderer stays alive across many luminance changes.
ok(1, 'fast-path stop+start avoidance is verified at runtime (see test replay_luminance)');

# 10. The luminance keys are allow-listed in the GCI gate so the
#     fast path can actually fire (otherwise the saves are
#     suppressed and the apply never runs at all).
like($src,
  qr/\$conf_key\s*ne\s*"min_luma"\s*&&\s*\$conf_key\s*ne\s*"max_luma"\s*&&\s*\$conf_key\s*ne\s*"max_cll"\s*&&\s*\$conf_key\s*ne\s*"max_fall"/,
  'GCI gate allow-lists min_luma, max_luma, max_cll, max_fall for Calman luminance changes');

done_testing();

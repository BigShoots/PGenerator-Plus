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
  qr/\$calman_apply_in_progress\s*=\s*1\s*;[\s\S]{0,600}?\$calman_settings_dirty\s*=\s*0\s*;[\s\S]{0,200}?pattern_generator_stop\(\)/,
  'calman_apply clears dirty BEFORE the stop/start (so concurrent saves set it back)');

# 4. The apply flag is cleared in a scope that survives eval death,
#    so a dying pattern_generator_start cannot wedge the queue.
like($src,
  qr/eval\s*\{[\s\S]{0,400}?pattern_generator_stop\(\)[\s\S]{0,400}?\}\s*;[\s\S]{0,100}?\$calman_apply_in_progress\s*=\s*0/,
  'calman_apply_in_progress is cleared after the eval block (survives eval death)');

# 5. The original single-shot behavior is replaced by the loop —
#    the old `$calman_settings_dirty=0` after pattern_generator_start
#    is gone (it would lose saves that happened during the stop/start).
unlike($src,
  qr/pattern_generator_start\(\)\s*;[\s\S]{0,100}?\$calman_settings_dirty\s*=\s*0\s*;/,
  'calman_apply no longer clears dirty AFTER start (would lose concurrent saves)');

done_testing();

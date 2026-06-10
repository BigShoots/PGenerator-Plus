#!/usr/bin/env perl
# Regression test: webui.pm init retry wrapper for header-card loads.
#
# The bug: on initial page refresh, the resolution, CEC adapter
# status and meter name would not appear in the UI for up to a
# minute. Root cause: loadInfo/loadCecStatus/meterCheckStatus were
# called once with the 8-10s fetchJSON timeout, and if that first
# call returned null (daemon still spinning up modetest parsing,
# USB enumeration or CEC adapter init) the UI stayed blank until
# the next setInterval tick (30s for loadInfo, 5-10s for the
# others). With no visible error (the init calls use _quiet:true),
# the user saw a frozen-looking header.
#
# The fix: a pgInitialRetry(name, fn, delays) wrapper fires the
# load at 0s, 2s and 5s (configurable) and cancels the pending
# retries as soon as the first call's promise resolves, so a slow
# first response doesn't leave the header cards empty.
use strict;
use warnings;
use Test::More;

my $webui = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $webui) or BAIL_OUT("can't read $webui: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The retry wrapper is defined.
like($src, qr/function\s+pgInitialRetry\s*\(\s*name\s*,\s*fn\s*,\s*delays\s*\)/,
  'pgInitialRetry wrapper is defined');

# 2. The wrapper schedules retries via setTimeout.
like($src, qr/pgInitialRetry[\s\S]{0,200}?setTimeout/,
  'pgInitialRetry uses setTimeout to schedule retries');

# 3. The wrapper cancels pending retries on successful resolution.
like($src, qr/p\.then\(\(\)\s*=>\s*\{\s*cancelled\s*=\s*true;?\s*\}\)/,
  'pgInitialRetry cancels pending retries once the first promise resolves');

# 4. loadInfo is invoked via the wrapper on init.
like($src, qr/pgInitialRetry\(\s*['"]loadInfo['"]\s*,\s*loadInfo\s*,\s*\[/,
  'init calls pgInitialRetry for loadInfo');
like($src, qr/pgInitialRetry\(\s*['"]loadCecStatus['"]\s*,\s*loadCecStatus\s*,\s*\[/,
  'init calls pgInitialRetry for loadCecStatus');

# 5. The loadInfo retry uses a tight 2s/5s schedule so the resolution
#    card populates within ~5s even when /api/info is slow.
like($src, qr/pgInitialRetry\(\s*['"]loadInfo['"]\s*,\s*loadInfo\s*,\s*\[\s*2000\s*,\s*5000\s*\]\s*\)/,
  'loadInfo retry schedule is [2000, 5000] ms');

# 6. The CEC retry uses a tight schedule for the CEC adapter init.
like($src, qr/pgInitialRetry\(\s*['"]loadCecStatus['"]\s*,\s*loadCecStatus\s*,\s*\[\s*1500\s*,\s*4000\s*\]\s*\)/,
  'loadCecStatus retry schedule is [1500, 4000] ms');

# 7. The meter gets an extra 5s and 10s retry on init (in addition to
#    the original 0s and 2s) to cover slow USB enumeration.
like($src, qr/setTimeout\(\(\)\s*=>\s*meterCheckStatus\(\)\s*,\s*5000\s*\)/,
  'init schedules an extra meterCheckStatus at 5000ms');
like($src, qr/setTimeout\(\(\)\s*=>\s*meterCheckStatus\(\)\s*,\s*10000\s*\)/,
  'init schedules a meterCheckStatus at 10000ms for slow cold starts');

# 7b. The busy guard in meterCheckStatus must NOT skip the first probe
#     on a cold start. If meterDetected is false (fresh page load), the
#     function should still hit /api/meter/status regardless of busy
#     flags — otherwise a stale meterActionPending from a previous tab
#     would leave the meter card showing "No Meter" until the flag
#     cleared.
like($src,
  qr/if\(\s*meterDetected\s*&&\s*\(\s*meterContinuousActive\s*\|\|/,
  'meterCheckStatus busy guard is gated on meterDetected (cold-start still probes)');

# 8. The 30s setInterval for loadInfo is preserved (background refresh).
like($src, qr/setInterval\(\(\)\s*=>\s*loadInfo\(true\)\s*,\s*30000\s*\)/,
  'background loadInfo interval (30s) is preserved');

# 9. The 5s setInterval for loadCecStatus is preserved.
like($src, qr/setInterval\(\(\)\s*=>\s*loadCecStatus\(\)\s*,\s*5000\s*\)/,
  'background loadCecStatus interval (5s) is preserved');

# 10. The original init sequence did not block on loadInfo with await —
#     the wrapper is non-blocking so subsequent steps (loadModes, etc.)
#     don't wait for /api/info to return. This is the key behavioral
#     change: init latency is no longer gated on the slowest of the
#     four initial awaits.
unlike($src,
  qr/await\s+loadInfo\(true\)\s*;/,
  'init no longer awaits loadInfo (replaced by non-blocking pgInitialRetry)');

# 12. When syncRemoteConfig detects a config change that affects the
#     wire (mode_idx, signal_mode, color_format, max_bpc,
#     colorimetry), it must also trigger loadInfo so the info-grid
#     resolution display updates within the same poll cycle. Without
#     this, a Calman-driven mode/format change would leave the
#     resolution field stale until the 30s loadInfo interval.
like($src,
  qr/syncRemoteConfig\s*\(\s*\)\s*\{[\s\S]{0,1500}?modeChanged[\s\S]{0,500}?loadInfo\(true\)/,
  'syncRemoteConfig triggers loadInfo(true) when mode-affecting config changes');
# 13. The mode-change detection covers at least mode_idx and
#     signal_mode (the two that change when Calman switches
#     display mode or resolution).
like($src,
  qr/prev\.mode_idx\s*!==\s*remoteConfig\.mode_idx\s*\|\|\s*prev\.signal_mode\s*!==\s*remoteConfig\.signal_mode/,
  'syncRemoteConfig detects mode_idx / signal_mode changes');

# 16. meterCheckStatus must trust the server's /api/meter/series/status
#     and clear the local meterSeriesRunning flag when the server
#     reports the series is not running. This handles the case where
#     a renderer restart (e.g. after a mode change + apply) leaves
#     the client's local flag stale, showing the stop button even
#     though no series is actually running.
like($src,
  qr/serverRunning\s*=\s*\(?s\.status\s*===?\s*['"]running['"]\)?/,
  'meterCheckStatus checks the server series status string');

# 17. The series sync must NOT be gated by !meterSeriesRunning —
#     it has to run every poll so a renderer restart can clear
#     the stale client flag.
unlike($src,
  qr/if\(\!meterSeriesRunning\s*&&\s*!meterSeriesPolling[^)]*meterSeriesCacheBootId/,
  'meterCheckStatus series sync is no longer gated by !meterSeriesRunning');

done_testing();

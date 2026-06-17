#!/usr/bin/env perl
# Regression test: meter_series.sh's EXIT trap must rewrite the state
# JSON to "error" so the poller doesn't fall through to the generic
# "Process died unexpectedly" string when the script crashes unexpectedly
# (e.g. spotread USB fault, bash error, command-not-found).
#
# Before this fix the EXIT trap only removed READY_FILE/STOP_FILE, so the
# state file stayed at "running" and the poller's liveness check rewrote
# it with the generic "Process died unexpectedly" message, hiding the
# real failure mode. With the fix, any unexpected exit (bash error,
# SIGTERM through a non-trapped path, missing command, etc.) produces
# a state JSON with status="error" carrying the last known current_step
# and current_name, so the user sees which step the helper died on.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $helper = 'usr/bin/meter_series.sh';
open(my $fh, '<', $helper) or BAIL_OUT("can't read $helper: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The EXIT trap must call a writer that updates the state JSON, not
#    just `rm -f`. Without this, the state file stays at "running" and
#    the poller rewrites it with the generic "Process died unexpectedly"
#    message.
like($src, qr/^trap\s+['"]write_state_on_exit['"]\s+EXIT\s*$/m,
  'EXIT trap must invoke write_state_on_exit (not just rm files)');

# 2. The writer must gate on the current state being "running" or "setup"
#    so completed / cancelled / error states are not clobbered.
ok(
  index($src, "write_state_on_exit()") != -1
    && index($src, '"status":"running"') != -1
    && index($src, '"status":"setup"') != -1
    && index($src, '"$cur" == *') != -1
    && index($src, ' || ') != -1,
  'write_state_on_exit must only rewrite when status is running or setup'
);

# 3. The writer must produce a JSON with status="error" carrying the
#    last known current_step so the user can see which step the helper
#    died on.
like($src, qr/write_state_on_exit[\s\S]{0,2500}?printf[\s\S]{0,500}?"status":"error"/s,
  'write_state_on_exit must emit status="error" with current_step preserved');
like($src, qr/exited unexpectedly/,
  'current_name in the error state must include "exited unexpectedly"');

# 4. The writer must tolerate the state file being absent (don't crash
#    the trap itself if the state file is gone, e.g. after explicit
#    cleanup) and must still clean up the READY/STOP files.
like($src, qr/write_state_on_exit[\s\S]{0,500}?!\s*-f\s+"\$STATE_FILE"/,
  'write_state_on_exit must guard on STATE_FILE presence');
like($src, qr/write_state_on_exit[\s\S]{0,2500}?rm\s+-f\s+"\$READY_FILE"\s+"\$STOP_FILE"/s,
  'write_state_on_exit must still remove READY_FILE/STOP_FILE on exit');

# 5. Live behavior check: a minimal run that exits before writing a
#    "complete" or "cancelled" state must leave the state file at
#    status="error" with a recognisable current_name. We extract the
#    helper's write_state_on_exit function and run it in a throwaway
#    harness, so we don't need a live meter.
my $tmp = tempdir(CLEANUP => 1);
my $state_running = "$tmp/state_running.json";
my $state_complete = "$tmp/state_complete.json";

# Pre-populate the running state file, as the helper would have left it
# just before crashing on an internal error.
open(my $wf, '>', $state_running) or BAIL_OUT("can't write $state_running: $!");
print $wf '{"status":"running","series_id":"greyscale_test_123_456","current_step":7,"total_steps":21,"current_name":"70pct (reading)","readings":[]}';
close $wf;

# Pre-populate a completed state file. The trap must NOT touch this
# (otherwise the user would lose the readings and see a spurious error
# on a successful run).
open($wf, '>', $state_complete) or BAIL_OUT("can't write $state_complete: $!");
print $wf '{"status":"complete","series_id":"greyscale_done_999","current_step":21,"total_steps":21,"current_name":"Done","readings":[{"X":0.9,"Y":1.0,"Z":1.1,"luminance":100.0}]}';
close $wf;

# Extract write_state_on_exit and the trap from the helper.
my ($fn) = $src =~ m/(write_state_on_exit\s*\(\s*\)\s*\{[\s\S]*?\n\})/m;
ok(defined $fn, 'extracted write_state_on_exit function from helper');
my ($trap_setup) = $src =~ m/^(trap\s+['"]write_state_on_exit['"]\s+EXIT\s*)$/m;
ok(defined $trap_setup, 'extracted EXIT trap invocation from helper');

# Build a crash stub that sources the function and the trap, then exits 1
# (simulating a script-internal crash before any final state JSON).
my $crash_stub = "#!/bin/bash\nset -o pipefail\n"
  . "export STATE_FILE='$state_running'\n"
  . "export SERIES_ID='greyscale_test_123_456'\n"
  . "export TOTAL='21'\n"
  . "$fn\n"
  . "$trap_setup\n"
  . "exit 1\n";
my $stub_path = "$tmp/crash_stub.sh";
open(my $sf, '>', $stub_path) or BAIL_OUT("can't write $stub_path: $!");
print $sf $crash_stub;
close $sf;
chmod 0755, $stub_path;

# Run the crash stub. We expect exit code 1 (the simulated crash) and
# the state file to be rewritten to status="error".
my $out = `$stub_path 2>&1`;
is($?, 256, 'crash stub exits 1 (the simulated crash)');
open(my $rf, '<', $state_running) or BAIL_OUT("can't read $state_running: $!");
my $running_after = do { local $/; <$rf> };
close $rf;
like($running_after, qr/"status":"error"/, 'after crash, status is rewritten to error');
like($running_after, qr/"current_step":7/, 'after crash, current_step is preserved (was 7)');
like($running_after, qr/"current_name":"70pct \(reading\) \(exited unexpectedly\)"/, 'after crash, current_name includes the last name and "exited unexpectedly"');
like($running_after, qr/"series_id":"greyscale_test_123_456"/, 'after crash, series_id is preserved');
like($running_after, qr/"error":"series_helper_exited_unexpectedly"/, 'after crash, an error tag is set for log correlation');

# 6. The writer must NOT clobber a "complete" state. Build a second
#    stub pointed at the complete state file and run it. The trap
#    should leave the "complete" state (and the readings) alone.
my $crash_stub_complete = "#!/bin/bash\nset -o pipefail\n"
  . "export STATE_FILE='$state_complete'\n"
  . "export SERIES_ID='greyscale_done_999'\n"
  . "export TOTAL='21'\n"
  . "$fn\n"
  . "$trap_setup\n"
  . "exit 1\n";
my $stub_complete_path = "$tmp/crash_stub_complete.sh";
open($sf, '>', $stub_complete_path) or BAIL_OUT("can't write $stub_complete_path: $!");
print $sf $crash_stub_complete;
close $sf;
chmod 0755, $stub_complete_path;
`$stub_complete_path 2>&1`;
is($?, 256, 'complete-state crash stub exits 1');
open($rf, '<', $state_complete) or BAIL_OUT("can't read $state_complete: $!");
my $complete_after = do { local $/; <$rf> };
close $rf;
like($complete_after, qr/"status":"complete"/, 'trap must not clobber a "complete" state');
like($complete_after, qr/"current_name":"Done"/, 'trap must preserve "Done" current_name on a completed series');
like($complete_after, qr/"luminance":100\.0/, 'trap must preserve the readings array on a completed series');

done_testing();

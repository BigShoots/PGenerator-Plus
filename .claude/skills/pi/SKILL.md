---
name: pi
description: Every access to the PGenerator+ Pi 4 (192.168.1.235) - ssh/scp, the Calman busy check, deploying files, restarting the daemon, rebooting, saving and giving back the user's signal settings, waiting for long runs. Use before any command that touches the Pi, also inside /verify.
---

# The Pi, through pgen-pi

`P=.claude/skills/pi/scripts/pgen-pi` (needs `dangerouslyDisableSandbox: true`, LAN).
It reads the root password from README.md itself; never write it into a command.
The guard hook (`.claude/hooks/pi_guard.py`) refuses raw `pi.exp`/`ssh`/`scp` to the Pi,
so this is the only way in. It reads the command like a shell (quotes, `$(…)`,
backticks, comments, `\`-newlines, heredocs) and judges each simple command,
also what it runs: `$P ssh '…'`, `sh -c`, `eval`, `xargs`, sudo/env/timeout, a
heredoc fed to a shell or interpreter, `python -c`/`perl -e` code. A heredoc
into `cat > file` is data. Anything that changes the picture, signal, daemon
or device (init script, `service`, pkill, probes, POSTs, port 85/2100/2101,
writes to `running/`, `/sys`, `/proc`, pgsethdr, pgenerator-update,
`vcgencmd display_power`) needs a fresh FREE from `$P busy` for that host;
system writes without a backup of that file into `/root/pgen-backups`, edits
under `/etc/PGenerator` and `{}`/empty bodies are refused. It is a net for
slips, not a sandbox.
`pi.exp` types the password once; a refused one ends with exit 5, a killed
ssh with exit 1, no output for `PI_TIMEOUT` s with exit 124.

| Step | Command |
|---|---|
| Is a Calman/ColourSpace session on? | `$P busy` (its own step; FREE counts 10 min) |
| Overview | `$P status` |
| Run something | `$P ssh 'CMD'`, `$P scp SRC... /tmp/` |
| Copy from the Pi | `$P fetch /root/x.json $TMPDIR/` (md5-checked; `scp` only uploads) |
| Before a test | `$P snapshot [LABEL]` |
| After the test | `$P restore` (or `$P diff` first) |
| Ship files | `$P deploy [--check] PATH[:REMOTE]...` |
| Restart the daemon | `$P restart` |
| Reboot (maintainer's OK) | `$P reboot` (re-copies the probes) |
| Probes into /tmp | `$P probes` |
| Long run in the background | `$P wait --log /root/x.log --until 'RESULT'` |

## Busy

`$P busy` runs `pi_calman_busy.sh` on the Pi (uploads it when the copy there differs)
and records FREE/BUSY with the time. The Pi leaves our own probes out (127.0.0.1,
the Mac), so `busy` also reads the shared `state.json`/`log.jsonl`: another
checkout (another local Claude session) holding a snapshot open, or using the Pi
in the last 10 minutes (reading, a restore that brought the settings back and a
closed snapshot do not count), makes it BUSY with that session named. Ask the
user before going on. Another checkout's snapshot is not closed, restored or
diffed from here; `--force` (`snapshot --close --force REASON`, `restore --force`)
only when the user says that session is gone. The guard takes only the FREE of
its own checkout and refuses changing commands while another checkout's
snapshot is open. BUSY: read the reason lines (each names the
log line behind it) before telling the user the Pi is in use; a real session ->
do not touch the device, ask. `restart`, `reboot`, `restore` and `deploy` run it
themselves and stop unless FREE. For `$P ssh` commands that change the picture,
signal, daemon or device (probes, POSTs, kill, reboot, init script, pattern
files) the hook wants a FREE younger than 10 minutes.

## Snapshot and restore

`snapshot` saves `/etc/PGenerator/PGenerator.conf` and the pattern to
`/root/pgen-backups/state-LABEL/` and marks it open. `restore` gives the signal
back under the signal-test lock, in partial `/api/config` bodies: the signal
(up to three tries, the DV keys with it when the snapshot is in DV), then the
mode and HDR metadata (mode_idx, mode_label, primaries, max/min_luma,
max_cll, max_fall: the signal mode overwrites primaries, so they need their own
POST), then pre_dv_*/sdr_colorimetry, then the DV keys outside DV. It puts the
pattern back and compares every key:

- exit 0: conf = snapshot, except DV keys the user never had (written on
  entering DV, read only in DV; printed as `note: … left`); closed.
- other keys differ (not signal keys): printed, not written, stays open. Decide,
  then `$P snapshot --close REASON`.
- not back: stays open; the reasons are printed.

The Stop hook blocks the end of a turn once while a snapshot of this checkout is
open. Handing over mid-test (the user looks at the TV): say so and stop again.

## Deploy

`$P deploy usr/share/PGenerator/webui.pm usr/sbin/PGeneratord ...`

- Repo paths under usr/ etc/ lib/ boot/ var/ go to the same path on the Pi;
  `usr/bin/pgsethdr.static` goes to `/usr/bin/pgsethdr`; anything else needs
  `LOCAL:/pi/path` (e.g. `build/x/vc4.ko:/lib/modules/5.10.89+-7l/kernel/drivers/gpu/drm/vc4/vc4.ko`).
- First it reads each Pi file (symlinks resolved: `PGeneratord.dv` is a link)
  and names its version: `= fork/main`, a commit of this branch, or STOP for a
  commit of another branch, a worktree's uncommitted copy, or an unknown file
  (`--base REF` to compare with something else, `--force` to replace anyway).
- Then `pi_deploy.sh` on the Pi: lock, watchdog pause, busy check, backup to
  `/root/pgen-backups/pre-LABEL-<time>/` with a `restore.sh`, install with md5
  checks, daemon restart, rollback if an install fails. A second run only
  reports. Kernel modules load on the next reboot.
- Renderer sources and the rebuilt binaries go together (CLAUDE.md); a WebUI
  file needs the daemon restart the deploy does anyway.

Deploying is not verification: check the result at the HDMI output (/verify).

## Where things are

- State for the hooks: `~/.local/state/pgen-pi/state.json`; every action is
  logged in `log.jsonl` next to it.
- On the Pi: `/root/pi_calman_busy.sh`, `/root/pgen-tools/pi_state.py`,
  bundles in `/root/pgen-deploy/`, backups in `/root/pgen-backups/`.
- Tests: `t/pgen_pi.t`, `t/pi_deploy.t`, `t/pi_state.t`, `t/pi_guard.t`,
  `t/pi_exp.t`, `t/pi_calman_busy.t`, `t/skill_facts.t`.

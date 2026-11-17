#!/bin/sh
#
# Program: pgenerator_usb_restore.sh
#
# First-boot settings rescue. A re-flashed image carries
# /etc/BiasiLinux/BiasiLinux.FirstBoot until rcPGenerator consumes it,
# so this is the one moment we know the device is factory-fresh. If a
# USB stick written by the WebUI's "Backup to USB" button (which puts a
# .pgbackup AND a PGEN_USB_RESCUE sentinel on a blank stick) is plugged
# in, restore it before the daemon's first start: the user flashes the
# card, plugs the stick, powers on, and the box comes back with their
# settings, profiles and calibration history. Rescue is opt-in: a
# browser-downloaded .pgbackup copied onto a stick by hand carries no
# sentinel and is deliberately IGNORED here — an arbitrary stick must
# never push settings onto an unattended first boot.
#
# Safe by construction:
#  - no first-boot marker  -> exit (normal boot, never touch settings)
#  - no USB stick          -> exit
#  - no/invalid .pgbackup  -> exit; the helper validates the archive
#    (format, manifest, per-file sha256) BEFORE writing anything, and
#    a wrong-board or foreign archive can only fail validation.
#  - restore writes exactly the backup's file list, and the helper
#    takes a rollback snapshot under /var/lib/PGenerator/system-backups
#    before applying.
# A marker file records the attempt either way so exactly one rescue
# runs per flashed image; re-flashing restores the trigger.
#
# Called by rcPGenerator AFTER the disk resize and BEFORE the PGenerator
# daemon starts. Root. Logs to /tmp so the (ephemeral) log never
# outlives into a restored state; the durable trail is the rollback
# snapshot plus a one-line marker.

FIRST_BOOT_FILE="/etc/BiasiLinux/BiasiLinux.FirstBoot"
ATTEMPT_MARKER="/etc/BiasiLinux/usb-restore.attempted"
BACKUP_HELPER="/usr/bin/pgenerator_system_backup.py"
PYTHON_BIN="$(command -v python3 || command -v python)"
LOG=/tmp/pgenerator-usb-restore.log

log() {
 echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null
}

if [ ! -f "$FIRST_BOOT_FILE" ]; then
 exit 0
fi
if [ -f "$ATTEMPT_MARKER" ]; then
 exit 0
fi
if [ ! -f "$BACKUP_HELPER" ] || [ -z "$PYTHON_BIN" ]; then
 exit 0
fi

# Give the stick a moment after power-on; USB storage can enumerate
# well after rcS reaches this point, especially behind a hub. Wait for
# a DISK node (/dev/sd[a-z]) or a PARTITION node (/dev/sd[a-z][0-9]),
# whichever lands first: a partition node can appear a beat after its
# disk (sdX, then sdX1), and an unpartitioned-superfloppy stick never
# produces a numbered node at all — breaking on either means a bare-disk
# stick does not pay the full partition wait before its grace period.
# A no-stick boot still spends the whole 10 s window: a stick that has
# not enumerated yet is indistinguishable from no stick, and trimming
# the window would silently miss slow-enumerating rescue sticks. The
# wait is once per flashed image, before the daemon starts.
i=0
while [ "$i" -lt 10 ]; do
 if ls /dev/sd[a-z][0-9] >/dev/null 2>&1; then
  break
 fi
 if ls /dev/sd[a-z] >/dev/null 2>&1; then
  break
 fi
 sleep 1
 i=$((i + 1))
done
if ! ls /dev/sd[a-z] >/dev/null 2>&1; then
 log "no USB storage after 10s; skipping rescue"
 exit 0
fi
if ! ls /dev/sd[a-z][0-9] >/dev/null 2>&1; then
 # Disk present but no partition node yet: give the partition scan a
 # short grace period before accepting the bare-disk case.
 j=0
 while [ "$j" -lt 5 ]; do
  if ls /dev/sd[a-z][0-9] >/dev/null 2>&1; then
   break
  fi
  sleep 1
  j=$((j + 1))
 done
fi

log "first boot with USB storage present; attempting restore"
# Bound the whole helper: it runs before the daemon starts, and a flaky
# stick that wedges mount must not wedge the boot. timeout kills the
# helper; run_cmd inside has its own per-command bounds as a second
# layer. If timeout is absent from the image, run unbounded (the old
# behavior) rather than skipping the rescue entirely.
HELPER_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && HELPER_TIMEOUT="timeout 300"
# Current software version straight from version.pm (same parse as
# pgenerator-update); "unknown" keeps the rollback snapshot label honest.
VERSION="$(grep '^\$version=' /usr/share/PGenerator/version.pm 2>/dev/null | sed 's/.*="\([^"]*\)".*/\1/')"
[ -n "$VERSION" ] || VERSION="unknown"
$HELPER_TIMEOUT "$PYTHON_BIN" "$BACKUP_HELPER" usb-restore --version "$VERSION" >> "$LOG" 2>&1
rc=$?
# Mark the attempt on both success and failure: a corrupt stick must not
# make every future boot stall here. NOTE: rcPGenerator deletes
# BiasiLinux.FirstBoot right after this script returns, so removing the
# attempt marker and rebooting does NOT re-run the rescue (the script
# exits at its FirstBoot check), and recreating FirstBoot would also
# re-run the disk resize — never do that. To retry a rescue after this
# boot, run the helper directly as root:
#   /usr/bin/python3 /usr/bin/pgenerator_system_backup.py usb-restore
# or restore the archive from the WebUI (Import System Settings).
echo "rc=$rc" > "$ATTEMPT_MARKER" 2>/dev/null
if [ "$rc" -eq 0 ]; then
 log "restore completed; the box boots with the backup's settings"
 sync
else
 # A failure AFTER the rollback snapshot may leave some components
 # restored and others not (e.g. ENOSPC mid-apply): do not claim a
 # clean factory boot. The pre-import snapshot under
 # /var/lib/PGenerator/system-backups is the recovery point.
 log "restore did not complete (rc=$rc); settings may be a partial mix; booting anyway"
fi
exit 0

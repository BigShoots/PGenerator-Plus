#!/bin/sh
# Keep PGenerator WebUI (port 80) alive if the daemon exits unexpectedly.
# Installed as a cron every-minute helper on the device.

PID_FILE=${PG_WATCHDOG_PID_FILE:-/var/run/PGenerator/PGeneratord.pl.pid}
LOG=${PG_WATCHDOG_LOG:-/tmp/pgenerator-watchdog.log}
# PG_WATCHDOG_TMPDIR, PG_WATCHDOG_INIT and PG_WATCHDOG_PID_FILE exist so the
# test harness can run the script in isolation; the device always uses the
# defaults.
WORK_DIR=${PG_WATCHDOG_TMPDIR:-/tmp}
INIT_SCRIPT=${PG_WATCHDOG_INIT:-/etc/init.d/PGenerator}
LOCK_FILE="$WORK_DIR/pgenerator-watchdog.lock"
PROBE_STAMP="$WORK_DIR/pgenerator-watchdog-root-ok"
MAX_LOG=50
WEBUI_MIN_BYTES=65536

log() {
  ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "?")
  if ! echo "$ts $*" >>"$LOG" 2>/dev/null; then
    # Unwritable log (full or read-only filesystem): keep the message.
    logger -t pgenerator-watchdog "$*" 2>/dev/null || true
  fi
  # keep log short
  if [ -f "$LOG" ]; then
    lines=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG" ] 2>/dev/null; then
      tail -n 30 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
  fi
}

# /api/ping can remain healthy while a missing UI fragment breaks only `/`.
# This probe is deliberately observational: its result never enters the
# restart decision below. The recovery page is a valid HTTP response, but the
# sentinel makes that degraded state visible in the watchdog log.
# The body is discarded — pulling the multi-megabyte page to disk every
# minute would wear the SD card; status and size come from curl itself, and
# the body is fetched for the sentinel only when the page is already small.
# The daemon caches the assembled page for its lifetime, so once one
# full-size response has been seen from the running daemon the probe is
# skipped until its PID changes: `/` cannot degrade without a restart, and
# re-fetching 2.6 MB through the single serialized worker every minute
# starves it — and, during long calibration runs, fills this short log with
# connect-timeout noise. Degraded results are never stamped, so an unhealthy
# root is re-probed every tick.
probe_webui_root() {
  daemon_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$daemon_pid" ] && [ "$(cat "$PROBE_STAMP" 2>/dev/null)" = "$daemon_pid" ]; then
    return 0
  fi
  status_file=$(mktemp "$WORK_DIR/pgenerator-watchdog-probe.XXXXXX" 2>/dev/null) || status_file="$WORK_DIR/pgenerator-watchdog-probe.$$"
  if ! err=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code} %{size_download}' http://127.0.0.1/ 2>&1 >"$status_file"); then
    log "ERROR: WebUI root probe failed to connect: ${err:-no detail}"
    rm -f "$status_file"
    return 0
  fi
  read -r status bytes <"$status_file" 2>/dev/null
  rm -f "$status_file"
  if [ "${status:-}" != "200" ]; then
    log "ERROR: WebUI root probe returned HTTP ${status:-unknown}"
  elif [ "${bytes:-0}" -ge "$WEBUI_MIN_BYTES" ] 2>/dev/null; then
    # Full page served: nothing can change until the daemon restarts.
    [ -n "$daemon_pid" ] && echo "$daemon_pid" >"$PROBE_STAMP" 2>/dev/null
  else
    # A small — or unparseable — 200 could be the recovery page; fetch it
    # once to classify.
    body_file=$(mktemp "$WORK_DIR/pgenerator-watchdog-page.XXXXXX" 2>/dev/null) || body_file="$WORK_DIR/pgenerator-watchdog-page.$$"
    if ! curl -s --max-time 5 -o "$body_file" http://127.0.0.1/ 2>/dev/null; then
      log "ERROR: WebUI root probe classification fetch failed after a ${bytes:-0}-byte response"
    elif grep -Fq '<!--PG_RECOVERY_PAGE-->' "$body_file" 2>/dev/null; then
      log "ERROR: WebUI root probe found the fragment recovery page"
    else
      log "ERROR: WebUI root probe returned only ${bytes:-0} bytes"
    fi
    rm -f "$body_file"
  fi
  return 0
}

# Already listening?
if wget -q -O /dev/null -T 2 http://127.0.0.1/api/ping 2>/dev/null; then
  probe_webui_root
  exit 0
fi

# Ping is down: the restart path below is the diagnostic that matters, so do
# not add a redundant root-probe connect error on every tick of a restart.

# Avoid thrash if init is mid-restart
if [ -f "$LOCK_FILE" ]; then
  # stale lock older than 120s?
  if [ -n "$(find "$LOCK_FILE" -mmin +2 2>/dev/null)" ]; then
    rm -f "$LOCK_FILE"
  else
    exit 0
  fi
fi
touch "$LOCK_FILE"

log "WebUI down — restarting PGenerator"
"$INIT_SCRIPT" restart >>"$LOG" 2>&1
sleep 4
if wget -q -O /dev/null -T 3 http://127.0.0.1/api/ping 2>/dev/null; then
  log "WebUI recovered"
  probe_webui_root
else
  log "WebUI still down after restart"
fi
rm -f "$LOCK_FILE"
exit 0

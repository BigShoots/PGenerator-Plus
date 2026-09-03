#!/bin/sh
# Keep PGenerator WebUI (port 80) alive if the daemon exits unexpectedly.
# Installed as a cron every-minute helper on the device.

# cron runs jobs with a minimal PATH that omits /sbin and /usr/sbin. Both this
# script's tools and the init script it calls need them (setcap lives in
# /sbin; without it the restarted daemon cannot bind port 80 and the watchdog
# would restart it every minute forever).
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

PID_FILE=${PG_WATCHDOG_PID_FILE:-/var/run/PGenerator/PGeneratord.pl.pid}
LOG=${PG_WATCHDOG_LOG:-/tmp/pgenerator-watchdog.log}
# PG_WATCHDOG_TMPDIR, PG_WATCHDOG_INIT and PG_WATCHDOG_PID_FILE exist so the
# test harness can run the script in isolation; the device always uses the
# defaults.
WORK_DIR=${PG_WATCHDOG_TMPDIR:-/tmp}
INIT_SCRIPT=${PG_WATCHDOG_INIT:-/etc/init.d/PGenerator}
LOCK_FILE="$WORK_DIR/pgenerator-watchdog.lock"
PROBE_STAMP="$WORK_DIR/pgenerator-watchdog-root-ok"
FAIL_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-failures"
TICK_COUNT_FILE="$WORK_DIR/pgenerator-watchdog-backoff"
INSTANCE_PID_FILE="$WORK_DIR/pgenerator-watchdog.pid"
TIMEOUT_CMD=$(command -v timeout 2>/dev/null)
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
# Each ithread owns its own fragment/page cache, so one successful response
# cannot permanently vouch for every worker. A healthy PID stamp suppresses
# the expensive 2.6 MB probe for 15 minutes, then allows a low-frequency
# sample of another worker. Degraded results are never stamped, so an
# unhealthy root is re-probed every tick.
probe_webui_root() {
  daemon_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$daemon_pid" ] && [ "$(cat "$PROBE_STAMP" 2>/dev/null)" = "$daemon_pid" ] \
     && [ -n "$(find "$PROBE_STAMP" -mmin -15 2>/dev/null)" ]; then
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

# Bounded liveness probe.
#
# This replaces `wget -q -O /dev/null -T 2`, which could not detect the very
# failure this watchdog exists to recover. GNU wget's -T is a PER-OPERATION
# timeout and wget RETRIES (--tries defaults to 20 with backoff waits), so
# against a daemon that accepts the connection and then never answers -- a
# wedged or SIGSTOPped daemon -- it keeps retrying for many minutes. Cron then
# stacked up another stuck instance every minute and the restart code below
# was never reached: proven on 2026-09-03 by freezing the daemon, after which
# the WebUI stayed down indefinitely with three wget processes piled up.
#
# curl's --max-time is a hard ceiling on the entire request and curl does not
# retry by default; `timeout` is a second ceiling in case the probe itself
# misbehaves. A connection-refused (daemon exited) still fails instantly.
webui_ping() {
  _url="http://127.0.0.1/api/ping"
  [ "${1:-80}" = "80" ] || _url="http://127.0.0.1:$1/api/ping"
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" 8 curl -s --connect-timeout 2 --max-time 4 -o /dev/null "$_url" 2>/dev/null
  else
    curl -s --connect-timeout 2 --max-time 4 -o /dev/null "$_url" 2>/dev/null
  fi
}

# One instance at a time. Cron fires every minute regardless of whether the
# previous tick finished, so a slow or stuck run must not accumulate. A
# predecessor still alive after 5 minutes is itself the fault: kill it (and
# its probe child) rather than let it block recovery forever.
if [ -f "$INSTANCE_PID_FILE" ]; then
  prev_pid=$(cat "$INSTANCE_PID_FILE" 2>/dev/null)
  case "$prev_pid" in (''|*[!0-9]*) prev_pid="";; esac
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && [ -d "/proc/$prev_pid" ]; then
    if [ -n "$(find "$INSTANCE_PID_FILE" -mmin +5 2>/dev/null)" ]; then
      log "previous watchdog instance $prev_pid stuck over 5 minutes — killing it"
      pkill -9 -P "$prev_pid" 2>/dev/null
      kill -9 "$prev_pid" 2>/dev/null
    else
      exit 0
    fi
  fi
fi
echo $$ >"$INSTANCE_PID_FILE" 2>/dev/null

# Already listening?
if webui_ping 80; then
  # Clear any failure history: the WebUI is healthy now, so a stale count
  # from an earlier incident must not push a future recovery into backoff.
  rm -f "$FAIL_COUNT_FILE" "$TICK_COUNT_FILE"
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

# When a restart does not bring the WebUI back, the cause is usually
# environmental (port 80 held by something else, a missing capability, a full
# filesystem) and retrying every single minute just kills the daemon forever
# without ever recovering -- observed for real when cron's PATH hid setcap.
# After BACKOFF_AFTER consecutive failed recoveries, restart only once every
# BACKOFF_EVERY ticks. Any success resets the counter.
BACKOFF_AFTER=5
BACKOFF_EVERY=10
fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null)
case "$fail_count" in (''|*[!0-9]*) fail_count=0;; esac
if [ "$fail_count" -ge "$BACKOFF_AFTER" ]; then
  tick_count=$(cat "$TICK_COUNT_FILE" 2>/dev/null)
  case "$tick_count" in (''|*[!0-9]*) tick_count=0;; esac
  tick_count=$((tick_count + 1))
  if [ "$tick_count" -lt "$BACKOFF_EVERY" ]; then
    echo "$tick_count" >"$TICK_COUNT_FILE" 2>/dev/null
    exit 0
  fi
  echo 0 >"$TICK_COUNT_FILE" 2>/dev/null
  log "WebUI still down after $fail_count restarts — retrying (backed off to every $BACKOFF_EVERY minutes)"
fi

touch "$LOCK_FILE"

log "WebUI down — restarting PGenerator"
"$INIT_SCRIPT" restart >>"$LOG" 2>&1
# Poll rather than check once: a fresh daemon needs a few seconds to compile
# and bind, and a single probe 4s in reported "still down" for a restart that
# actually succeeded one second later -- a false failure that counted toward
# the backoff above and put a misleading line in the log.
recovered=""
i=0
while [ "$i" -lt 10 ]; do
  sleep 2
  if webui_ping 80; then recovered=1; break; fi
  i=$((i + 1))
done
if [ -n "$recovered" ]; then
  log "WebUI recovered"
  rm -f "$FAIL_COUNT_FILE" "$TICK_COUNT_FILE"
  probe_webui_root
else
  fail_count=$((fail_count + 1))
  echo "$fail_count" >"$FAIL_COUNT_FILE" 2>/dev/null
  # A daemon that came up on the fallback port is a specific, fixable fault:
  # name it instead of logging a generic failure every minute.
  if webui_ping 8080; then
    log "ERROR: WebUI answered on port 8080 — it could not bind port 80 (perl is missing cap_net_bind_service; check setcap in $INIT_SCRIPT)"
  else
    log "WebUI still down after restart (consecutive failures: $fail_count)"
  fi
fi
rm -f "$LOCK_FILE"
exit 0

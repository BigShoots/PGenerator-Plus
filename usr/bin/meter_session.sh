#!/bin/bash
# meter_session.sh - Long-lived spotread session for Read Once / Continuous reads.
#
# Spotread cold-start is a 3-8 s USB handshake (plus a refresh-rate calibration
# cycle on OLED/CRT). This script pays that cost once, then every read is just
# "send space, parse result". meter_series.sh uses the same pattern across a
# patch series; this is the per-patch equivalent for ad-hoc reads.
#
# Usage:
#   meter_session.sh <display_type> <ccss_file> <refresh_rate> <disable_aio> [idle_timeout]
#
# Commands (one per line, written to /tmp/meter_session.cmd):
#   READ <r> <g> <b> <patch_size> <ire> <name> [settle_ms]
#   STOP
#
# settle_ms (optional, default 0) is the post-display settle wait — only
# applied when the patch RGB actually changed since the last READ, so
# back-to-back reads on the same patch (Continuous mode) pay it once.
#
# Writes results to /tmp/meter_read.json after each READ so the existing
# /api/meter/read/result polling endpoint keeps working unchanged.

set -o pipefail

DISPLAY_TYPE="${1:-l}"
CCSS_FILE="${2:-}"
REFRESH_RATE="${3:-}"
DISABLE_AIO="${4:-0}"
IDLE_TIMEOUT="${5:-300}"

SPOTREAD_BIN="/usr/bin/spotread"
TMPDIR="/tmp"
API_BASE="http://127.0.0.1/api"
CMD_FIFO="/tmp/meter_session.cmd"
STATE_FILE="/tmp/meter_read.json"
PID_FILE="/tmp/meter_session.pid"
CONFIG_FILE="/tmp/meter_session.config"
LOCK_FILE="/tmp/meter_session.lock"
LOG_FILE="/tmp/meter_session.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }

# Atomic-ish state file writer that keeps the file world-writable so the
# webui daemon (running as the unprivileged pgenerator user) can overwrite
# our "measuring" marker between READ commands.
write_state() {
 echo "$1" > "$STATE_FILE"
 chmod 666 "$STATE_FILE" 2>/dev/null
}

# Single-instance lock — refuse to start if another session is alive.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
 log "another session already holds the lock, exiting"
 exit 0
fi
echo $$ > "$PID_FILE"
printf '%s|%s|%s|%s\n' "$DISPLAY_TYPE" "$CCSS_FILE" "$REFRESH_RATE" "$DISABLE_AIO" > "$CONFIG_FILE"
log "session $$ starting (display=$DISPLAY_TYPE ccss=$CCSS_FILE refresh=$REFRESH_RATE aio_off=$DISABLE_AIO idle=${IDLE_TIMEOUT}s)"

# --- spotread bring-up (mirrors meter_series.sh) ---

find_port() {
 local cache="/tmp/spotread_port_cache"
 if [[ -f "$cache" ]]; then
  local cached age
  cached=$(cat "$cache" 2>/dev/null)
  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if (( age < 1800 )) && [[ -n "$cached" ]]; then
   echo "$cached"
   return
  fi
 fi
 local help_out
 help_out=$(timeout 5 "$SPOTREAD_BIN" -? 2>&1 || true)
 local port_num="1"
 while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]+([0-9]+)[[:space:]]*=[[:space:]]*\'/dev/bus/usb/ ]]; then
   port_num="${BASH_REMATCH[1]}"
   break
  fi
 done <<< "$help_out"
 echo "$port_num" > "$cache"
 sleep 2
 echo "$port_num"
}

count_results() {
 local n
 n=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -c "Result is XYZ:" 2>/dev/null) || true
 echo "${n:-0}" | tr -d '[:space:]'
}

parse_latest_result() {
 local clean_out result_line
 clean_out=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 result_line=$(echo "$clean_out" | grep "Result is XYZ:" | tail -1)
 [[ -z "$result_line" ]] && return 1
 local xyz_part yxy_part X Y Z lum x_chr y_chr cct ts
 xyz_part=$(echo "$result_line" | sed 's/.*XYZ:\s*//' | sed 's/,.*//')
 yxy_part=$(echo "$result_line" | sed 's/.*Yxy:\s*//')
 X=$(echo "$xyz_part" | awk '{print $1}')
 Y=$(echo "$xyz_part" | awk '{print $2}')
 Z=$(echo "$xyz_part" | awk '{print $3}')
 lum=$(echo "$yxy_part" | awk '{print $1}')
 x_chr=$(echo "$yxy_part" | awk '{print $2}')
 y_chr=$(echo "$yxy_part" | awk '{print $3}')
 cct=0
 if [[ -n "$x_chr" && -n "$y_chr" && "$y_chr" != "0.000000" ]]; then
  cct=$(python -c "
x=$x_chr; y=$y_chr
if y > 0:
 n = (x - 0.3320) / (0.1858 - y)
 print(int(round(449*n**3 + 3525*n**2 + 6823.3*n + 5520.33)))
else:
 print(0)
" 2>/dev/null || echo 0)
 fi
 ts=$(date +%s)
 echo "{\"X\":$X,\"Y\":$Y,\"Z\":$Z,\"x\":$x_chr,\"y\":$y_chr,\"luminance\":$lum,\"cct\":$cct,\"timestamp\":$ts}"
 return 0
}

cleanup() {
 log "cleanup: tearing down spotread"
 printf "Q" >&3 2>/dev/null
 exec 3>&- 2>/dev/null
 exec 4>&- 2>/dev/null
 [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null
 [[ -n "$BG_PID" ]] && pkill -9 -P "$BG_PID" 2>/dev/null
 [[ -n "$BG_PID" ]] && kill -9 "$BG_PID" 2>/dev/null
 pkill -9 -x spotread 2>/dev/null
 rm -f "$OUTFILE" "$CMDPIPE" "$CMD_FIFO" "$PID_FILE" "$CONFIG_FILE"
}
trap cleanup EXIT INT TERM

PORT_NUM=$(find_port)
OUTFILE="$TMPDIR/spotread_session_$$"
CMDPIPE="$TMPDIR/spotread_cmd_$$"
rm -f "$OUTFILE" "$CMDPIPE"
touch "$OUTFILE"
mkfifo "$CMDPIPE"

SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x"
if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" ]]; then
 # Honor CCSS file's DISPLAY_TYPE_REFRESH override (matches meter_series.sh)
 CCSS_REFRESH=$(grep -i 'DISPLAY_TYPE_REFRESH' "$CCSS_FILE" 2>/dev/null | head -1)
 if [[ "$CCSS_REFRESH" == *'"NO"'* ]]; then
  DISPLAY_TYPE="l"
 elif [[ "$CCSS_REFRESH" == *'"YES"'* ]]; then
  DISPLAY_TYPE="c"
 fi
 SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -x"
fi
[[ -n "$REFRESH_RATE" ]] && SR_CMD="$SR_CMD -Y R:$REFRESH_RATE"
[[ "$DISABLE_AIO" == "1" ]] && export I1D3_DISABLE_AIO=1

cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
BG_PID=$!
exec 3>"$CMDPIPE"

# Wait for spotread prompt
WAITED=0
while (( WAITED < 300 )); do
 grep -q "to take a reading:" "$OUTFILE" 2>/dev/null && break
 sleep 0.1
 WAITED=$((WAITED + 1))
done
if ! grep -q "to take a reading:" "$OUTFILE" 2>/dev/null; then
 log "spotread init failed"
 write_state '{"status":"error","message":"Meter init failed"}'
 exit 1
fi
log "spotread ready in $((WAITED / 10))s"

# Refresh-rate calibration prompt (CRT/OLED). Display white, send space, wait.
CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
if echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
 log "performing refresh-rate calibration"
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d '{"name":"patch","r":255,"g":255,"b":255,"size":100,"input_max":255}' >/dev/null 2>&1
 sleep 1.5
 INITIAL_PROMPTS=$(echo "$CLEAN_OUT" | grep -c "to take a reading:")
 printf " " >&3
 CAL_WAIT=0
 while (( CAL_WAIT < 300 )); do
  CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
  CUR_PROMPTS=$(echo "$CLEAN_OUT" | grep -c "to take a reading:")
  (( CUR_PROMPTS > INITIAL_PROMPTS )) && break
  sleep 0.1
  CAL_WAIT=$((CAL_WAIT + 1))
 done
fi

# Setup command FIFO. Open both ends so 'read' won't return EOF when external
# writers close their write end.
rm -f "$CMD_FIFO"
mkfifo "$CMD_FIFO"
chmod 666 "$CMD_FIFO"
exec 4<>"$CMD_FIFO"

log "command loop ready"

LAST_R="" LAST_G="" LAST_B="" LAST_PSIZE=""

# --- Main command loop ---
while read -t "$IDLE_TIMEOUT" -u 4 line; do
 case "$line" in
  READ\ *)
   # Parse: READ R G B PSIZE IRE NAME [SETTLE_MS]
   read -r _ R G B PSIZE IRE NAME SETTLE_MS <<< "$line"
   [[ -z "$PSIZE" ]] && PSIZE=10
   [[ -z "$IRE" ]] && IRE=0
   [[ -z "$NAME" ]] && NAME="manual"
   [[ -z "$SETTLE_MS" ]] && SETTLE_MS=0

   # Mark measuring so the polling endpoint knows a read is in flight.
   write_state '{"status":"measuring"}'

   # Re-display only if the patch actually changed. This makes Continuous
   # reads on a fixed patch fast (no /api/pattern roundtrip, no settle wait)
   # while still settling correctly when the user picks a different patch.
   if [[ "$R" != "$LAST_R" || "$G" != "$LAST_G" || "$B" != "$LAST_B" || "$PSIZE" != "$LAST_PSIZE" ]]; then
    curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
     -d "{\"name\":\"patch\",\"r\":$R,\"g\":$G,\"b\":$B,\"size\":$PSIZE,\"input_max\":255}" >/dev/null 2>&1
    if (( SETTLE_MS > 0 )); then
     SETTLE_SEC=$(awk "BEGIN{printf \"%.3f\", $SETTLE_MS/1000.0}")
     sleep "$SETTLE_SEC"
    fi
    LAST_R="$R"; LAST_G="$G"; LAST_B="$B"; LAST_PSIZE="$PSIZE"
   fi

   # Absolute black on emissive displays (OLED/QD-OLED/CRT/plasma) often
   # returns no measurable response. Report a valid 0.0 reading immediately.
   if [[ "$DISPLAY_TYPE" == "c" && "$R" == "$G" && "$G" == "$B" && "$IRE" -le 0 ]]; then
    TS=$(date +%s)
    write_state "{\"status\":\"complete\",\"readings\":[{\"X\":0,\"Y\":0,\"Z\":0,\"x\":0,\"y\":0,\"luminance\":0.0,\"cct\":0,\"timestamp\":$TS,\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B}],\"count\":1}"
    continue
   fi

   # Trigger reading and wait for it
   PREV_COUNT=$(count_results)
   printf " " >&3
   READ_TIMEOUT=15
   (( IRE <= 5 )) && READ_TIMEOUT=25
   READ_START=$SECONDS
   GOT_RESULT=false
   while (( SECONDS - READ_START < READ_TIMEOUT )); do
    CUR_COUNT=$(count_results)
    if (( CUR_COUNT > PREV_COUNT )); then
     GOT_RESULT=true
     break
    fi
    sleep 0.1
   done

   if $GOT_RESULT; then
    PARSED=$(parse_latest_result)
    if [[ -n "$PARSED" ]]; then
     # Wrap as a complete reading record (matches spotread_wrapper.sh shape)
     OUT=$(python -c "
import json
r=json.loads('''$PARSED''')
r['ire']=$IRE
r['name']='$NAME'
r['r_code']=$R
r['g_code']=$G
r['b_code']=$B
print(json.dumps({'status':'complete','readings':[r],'count':1}))
" 2>/dev/null)
     if [[ -n "$OUT" ]]; then
      write_state "$OUT"
     else
      write_state '{"status":"error","message":"Parse failed"}'
     fi
    else
     write_state '{"status":"error","message":"No result line"}'
    fi
   else
    log "read timed out after ${READ_TIMEOUT}s"
    write_state '{"status":"error","message":"Read timed out"}'
   fi
   ;;
  STOP)
   log "STOP received"
   break
   ;;
  "")
   ;;
  *)
   log "unknown command: $line"
   ;;
 esac
done

if (( $? > 128 )); then
 log "idle timeout reached, exiting"
fi
# cleanup runs via EXIT trap

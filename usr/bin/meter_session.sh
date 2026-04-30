#!/bin/bash
# meter_session.sh - Long-lived spotread session for Read Once / Continuous reads.
#
# Spotread cold-start is a 3-8 s USB handshake (plus a refresh-rate calibration
# cycle on OLED/CRT). This script pays that cost once, then every read is just
# "send space, parse result". meter_series.sh uses the same pattern across a
# patch series; this is the per-patch equivalent for ad-hoc reads.
#
# Usage:
#   meter_session.sh <display_type> <ccss_file> <refresh_rate> <disable_aio> [signal_mode] [max_luma] [meter_port] [idle_timeout] [require_device_ready]
#
# Commands (one per line, written to /tmp/meter_session.cmd):
#   READ <r> <g> <b> <patch_size> <ire> <name> [settle_ms] [signal_mode] [max_luma] [signal_range]
#   STOP
#
# settle_ms (optional, default 0) is the post-display settle wait applied
# before every read so manual Read Once and Continuous honor the UI value even
# when the patch itself has not changed.
#
# Writes results to /tmp/meter_read.json after each READ so the existing
# /api/meter/read/result polling endpoint keeps working unchanged.

set -o pipefail

DISPLAY_TYPE="${1:-l}"
CCSS_FILE="${2:-}"
REFRESH_RATE="${3:-}"
DISABLE_AIO="${4:-0}"
SIGNAL_MODE_DEFAULT="${5:-sdr}"
MAX_LUMA_DEFAULT="${6:-1000}"
METER_PORT="${7:-}"
IDLE_TIMEOUT="${8:-300}"
REQUIRE_DEVICE_READY="${9:-0}"

SPOTREAD_BIN="/usr/bin/spotread"
TMPDIR="/tmp"
API_BASE="http://127.0.0.1/api"
CMD_FIFO="/tmp/meter_session.cmd"
STATE_FILE="/tmp/meter_read.json"
PID_FILE="/tmp/meter_session.pid"
CONFIG_FILE="/tmp/meter_session.config"
LOCK_FILE="/tmp/meter_session.lock"
LOG_FILE="/tmp/meter_session.log"
READY_FILE="/tmp/meter_session_ready.signal"
STARTUP_READY_FILE="/tmp/meter_session_start_ready.signal"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
startup_marker() { log "startup marker: $*"; }

signal_startup_ready() {
 : > "$STARTUP_READY_FILE"
 chmod 666 "$STARTUP_READY_FILE" 2>/dev/null
}

# Atomic-ish state file writer that keeps the file world-writable so the
# webui daemon (running as the unprivileged pgenerator user) can overwrite
# our "measuring" marker between READ commands.
write_state() {
 echo "$1" > "$STATE_FILE"
 chmod 666 "$STATE_FILE" 2>/dev/null
}

startup_output_excerpt() {
 [[ -f "$OUTFILE" ]] || return 0
 sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | tail -n 8 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

output_size() {
 if [[ -f "$OUTFILE" ]]; then
  wc -c < "$OUTFILE" 2>/dev/null | tr -d '[:space:]'
 else
  echo 0
 fi
}

clean_output_since() {
 local offset="${1:-0}"
 local start=$((offset + 1))
 [[ -f "$OUTFILE" ]] || return 0
 tail -c +"$start" "$OUTFILE" 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'
}

manual_calibration_setup_prompt() {
 local normalized
 normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
 printf '%s' "$normalized" | grep -qiE 'white[[:space:]-]+reference|calibration[[:space:]-]+tile|calibration position|place cap|dark surface|white test patch|80% or greater white test patch|needs calibration|calibration retry with correct setup'
}

manual_initial_measurement_prompt() {
 local normalized
 normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
 printf '%s' "$normalized" | grep -qiE 'place .*instrument|place .*meter|position .*instrument|position .*meter'
}

manual_ready_prompt_reason() {
 local clean_out="$1"
 local normalized
 normalized=$(printf '%s' "$clean_out" | tr '[:upper:]' '[:lower:]')
 if printf '%s' "$normalized" | grep -qiE 'incorrect position|meter is in incorrect position'; then
  echo "incorrect_position"
  return 0
 fi
 if manual_calibration_setup_prompt "$clean_out"; then
  echo "calibration_setup"
  return 0
 fi
 if manual_initial_measurement_prompt "$clean_out"; then
  echo "initial_measurement"
  return 0
 fi
 return 1
}

manual_ready_prompt_message() {
 case "$1" in
  calibration_setup)
   printf '%s' 'Place the meter on its white calibration tile'
   ;;
  incorrect_position)
   printf '%s' 'Reposition the meter and continue the reading'
   ;;
  *)
   printf '%s' 'Position the meter and continue when ready'
   ;;
 esac
}

wait_for_device_ready() {
 local reason="${1:-initial_measurement}"
 local message
 message=$(manual_ready_prompt_message "$reason")
 rm -f "$READY_FILE"
 write_state "{\"status\":\"running\",\"awaiting_ready\":true,\"awaiting_ready_reason\":\"$reason\",\"message\":\"$message\"}"
 while [[ ! -f "$READY_FILE" ]]; do
  sleep 0.2
 done
 rm -f "$READY_FILE"
}

patch_request_body() {
 local r="$1" g="$2" b="$3" size="$4" signal_mode="$5" max_luma="$6" signal_range="$7"
 local payload="{\"name\":\"patch\",\"r\":$r,\"g\":$g,\"b\":$b,\"size\":$size,\"input_max\":255,\"signal_mode\":\"$signal_mode\",\"max_luma\":$max_luma"
 if [[ -n "$signal_range" ]]; then
  payload="$payload,\"signal_range\":\"$signal_range\""
 fi
 payload="$payload}"
 printf '%s' "$payload"
}

post_patch() {
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7")" >/dev/null 2>&1
}

post_patch_timeout() {
 timeout 5 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7")" >/dev/null 2>&1 || true
}

# Single-instance lock — refuse to start if another session is alive.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
 log "another session already holds the lock, exiting"
 exit 0
fi
echo $$ > "$PID_FILE"
printf '%s|%s|%s|%s|%s|%s\n' "$DISPLAY_TYPE" "$CCSS_FILE" "$REFRESH_RATE" "$DISABLE_AIO" "$METER_PORT" "$REQUIRE_DEVICE_READY" > "$CONFIG_FILE"
log "session $$ starting (display=$DISPLAY_TYPE ccss=$CCSS_FILE refresh=$REFRESH_RATE aio_off=$DISABLE_AIO port=$METER_PORT ready_gate=$REQUIRE_DEVICE_READY idle=${IDLE_TIMEOUT}s)"
startup_marker "pid/config written"

# --- spotread bring-up (mirrors meter_series.sh) ---

find_port() {
 local requested_port="$1"
 local cache="/tmp/spotread_port_cache"
 local help_out
 help_out=$(timeout 5 "$SPOTREAD_BIN" -? 2>&1 || true)
 if [[ -n "$requested_port" ]]; then
  if printf '%s\n' "$help_out" | grep -qE "^[[:space:]]*${requested_port}[[:space:]]*=[[:space:]]*'/dev/bus/usb/"; then
   echo "$requested_port" > "$cache"
   sleep 2
   echo "$requested_port"
   return
  fi
 fi
 if [[ -f "$cache" ]]; then
  local cached age
  cached=$(cat "$cache" 2>/dev/null)
  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if (( age < 1800 )) && [[ "$cached" =~ ^[0-9]+$ ]] && printf '%s\n' "$help_out" | grep -qE "^[[:space:]]*${cached}[[:space:]]*=[[:space:]]*'/dev/bus/usb/"; then
   echo "$cached"
   return
  fi
 fi
 local port_num=""
 while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]+([0-9]+)[[:space:]]*=[[:space:]]*\'/dev/bus/usb/ ]]; then
   port_num="${BASH_REMATCH[1]}"
   break
  fi
 done <<< "$help_out"
 if [[ -n "$port_num" ]]; then
  echo "$port_num" > "$cache"
  sleep 2
 fi
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
 rm -f "$OUTFILE" "$CMDPIPE" "$CMD_FIFO" "$PID_FILE" "$CONFIG_FILE" "$READY_FILE" "$STARTUP_READY_FILE"
}
trap cleanup EXIT INT TERM

PORT_NUM=""
for _try in 1 2 3; do
 PORT_NUM=$(find_port "$METER_PORT")
 [[ -n "$PORT_NUM" ]] && break
 sleep 2
done
if [[ -z "$PORT_NUM" ]]; then
 log "meter failed to enumerate during session startup"
 write_state '{"status":"error","message":"Meter enumeration failed"}'
 exit 1
fi
startup_marker "meter port resolved ($PORT_NUM)"
OUTFILE="$TMPDIR/spotread_session_$$"
CMDPIPE="$TMPDIR/spotread_cmd_$$"
rm -f "$OUTFILE" "$CMDPIPE"
touch "$OUTFILE"
mkfifo "$CMDPIPE"

SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x"
if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" ]]; then
 # Match the actual DISPLAY_TYPE_REFRESH value, not the KEYWORD line.
 # Fall back to CCSS metadata when the explicit refresh hint is absent.
 CCSS_REFRESH=$(grep -iE '^[[:space:]]*DISPLAY_TYPE_REFRESH[[:space:]]' "$CCSS_FILE" 2>/dev/null | head -1)
 if [[ "$CCSS_REFRESH" == *'"NO"'* ]]; then
  DISPLAY_TYPE="l"
 elif [[ "$CCSS_REFRESH" == *'"YES"'* ]]; then
  DISPLAY_TYPE="c"
 else
  CCSS_META=$(grep -iE '^[[:space:]]*(DISPLAY|TECHNOLOGY)[[:space:]]' "$CCSS_FILE" 2>/dev/null | tr '\n' ' ')
  if [[ "$CCSS_META" =~ [Pp]rojector ]]; then
   DISPLAY_TYPE="p"
  elif [[ "$CCSS_META" =~ (OLED|Plasma|CRT) ]]; then
   DISPLAY_TYPE="c"
  else
   DISPLAY_TYPE="l"
  fi
 fi
 SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -x"
fi
[[ -n "$REFRESH_RATE" ]] && SR_CMD="$SR_CMD -Y R:$REFRESH_RATE"
[[ "$DISABLE_AIO" == "1" ]] && export I1D3_DISABLE_AIO=1

cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
BG_PID=$!
exec 3>"$CMDPIPE"
startup_marker "spotread spawned (bg_pid=$BG_PID)"

# Publish the command FIFO immediately so the web UI can queue a manual READ
# even while startup is paused on an internal meter prompt.
rm -f "$CMD_FIFO" "$READY_FILE" "$STARTUP_READY_FILE"
mkfifo "$CMD_FIFO"
chmod 666 "$CMD_FIFO"
exec 4<>"$CMD_FIFO"
startup_marker "command FIFO created"

# Wait for spotread prompt. Allow up to 60 s on a cold boot so the first
# manual read after a Pi restart doesn't fail during slow USB bring-up.
WAITED=0
REFRESH_CAL_DONE=0
WHITE_REF_DONE=0
STARTUP_HINT=""
while (( WAITED < 600 )); do
 CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 echo "$CLEAN_OUT" | grep -q "to take a reading:" && break
 if (( REFRESH_CAL_DONE == 0 )) && echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
  log "performing refresh-rate calibration during startup"
  post_patch_timeout 204 204 204 100 "$SIGNAL_MODE_DEFAULT" "$MAX_LUMA_DEFAULT" ""
  sleep 2
  printf " " >&3
  REFRESH_CAL_DONE=1
  sleep 2
  WAITED=$((WAITED + 20))
  continue
 fi
 if (( WHITE_REF_DONE == 0 )) && manual_calibration_setup_prompt "$CLEAN_OUT"; then
  log "detected white-reference calibration prompt during startup"
  startup_marker "white-reference prompt seen"
  STARTUP_HINT="white_reference_prompt"
  if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
   wait_for_device_ready "calibration_setup"
  else
   write_state '{"status":"starting","message":"Place the meter on its white calibration tile"}'
   sleep 4
  fi
  printf " " >&3
  WHITE_REF_DONE=1
  WAITED=$((WAITED + 40))
  continue
 fi
 if echo "$CLEAN_OUT" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected"; then
  STARTUP_HINT="communications_failure"
  break
 fi
 sleep 0.1
 WAITED=$((WAITED + 1))
done
if ! sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -q "to take a reading:"; then
 FAIL_CONTEXT=$(startup_output_excerpt)
 if [[ "$STARTUP_HINT" == "white_reference_prompt" ]]; then
  log "spotread init failed after white-reference prompt${FAIL_CONTEXT:+: $FAIL_CONTEXT}"
  write_state '{"status":"error","message":"Meter init failed after white-reference prompt"}'
 elif [[ "$STARTUP_HINT" == "communications_failure" ]]; then
  log "spotread init failed after communications failure${FAIL_CONTEXT:+: $FAIL_CONTEXT}"
  write_state '{"status":"error","message":"Meter communication failed during init"}'
 else
  log "spotread init failed${FAIL_CONTEXT:+: $FAIL_CONTEXT}"
  write_state '{"status":"error","message":"Meter init failed"}'
 fi
 exit 1
fi
log "spotread ready in $((WAITED / 10))s"
startup_marker "ready prompt reached"

# Refresh-rate calibration prompt (CRT/OLED). Display white, send a key once,
# then continue — some spotread builds redraw the same prompt instead of adding
# a second prompt line, so waiting for the prompt count to increase can deadlock.
CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
if (( REFRESH_CAL_DONE == 0 )) && echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
 log "performing refresh-rate calibration"
 post_patch_timeout 204 204 204 100 "$SIGNAL_MODE_DEFAULT" "$MAX_LUMA_DEFAULT" ""
 sleep 2
 printf " " >&3
 sleep 2
fi

signal_startup_ready
startup_marker "startup ready signaled"
log "command loop ready"

LAST_R="" LAST_G="" LAST_B="" LAST_PSIZE="" LAST_SIGNAL_MODE="" LAST_MAX_LUMA="" LAST_SIGNAL_RANGE=""

# --- Main command loop ---
while read -t "$IDLE_TIMEOUT" -u 4 line; do
 case "$line" in
  READ\ *)
     # Parse: READ R G B PSIZE IRE NAME [SETTLE_MS] [SIGNAL_MODE] [MAX_LUMA] [SIGNAL_RANGE]
     read -r _ R G B PSIZE IRE NAME SETTLE_MS SIGNAL_MODE MAX_LUMA SIGNAL_RANGE <<< "$line"
   [[ -z "$PSIZE" ]] && PSIZE=10
   [[ -z "$IRE" ]] && IRE=0
   [[ -z "$NAME" ]] && NAME="manual"
   [[ -z "$SETTLE_MS" ]] && SETTLE_MS=0
   [[ -z "$SIGNAL_MODE" ]] && SIGNAL_MODE="$SIGNAL_MODE_DEFAULT"
   [[ -z "$MAX_LUMA" ]] && MAX_LUMA="$MAX_LUMA_DEFAULT"
     [[ -z "$SIGNAL_RANGE" ]] && SIGNAL_RANGE=""

   # Mark measuring so the polling endpoint knows a read is in flight.
   write_state '{"status":"measuring"}'

  # Re-display when the rendered patch changes, including transport fields
  # like signal mode and mastering peak that affect how the same RGB codes map.
  if [[ "$R" != "$LAST_R" || "$G" != "$LAST_G" || "$B" != "$LAST_B" || "$PSIZE" != "$LAST_PSIZE" || "$SIGNAL_MODE" != "$LAST_SIGNAL_MODE" || "$MAX_LUMA" != "$LAST_MAX_LUMA" || "$SIGNAL_RANGE" != "$LAST_SIGNAL_RANGE" ]]; then
   post_patch "$R" "$G" "$B" "$PSIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$SIGNAL_RANGE"
   LAST_R="$R"; LAST_G="$G"; LAST_B="$B"; LAST_PSIZE="$PSIZE"; LAST_SIGNAL_MODE="$SIGNAL_MODE"; LAST_MAX_LUMA="$MAX_LUMA"; LAST_SIGNAL_RANGE="$SIGNAL_RANGE"
   fi

  if (( SETTLE_MS > 0 )); then
   SETTLE_SEC=$(awk "BEGIN{printf \"%.3f\", $SETTLE_MS/1000.0}")
   sleep "$SETTLE_SEC"
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
     SCAN_OFFSET=$(output_size)
   printf " " >&3
  READ_TIMEOUT=60
  (( IRE <= 5 )) && READ_TIMEOUT=70
   READ_START=$SECONDS
   GOT_RESULT=false
   RETRIED_COMM=0
   while (( SECONDS - READ_START < READ_TIMEOUT )); do
    CUR_COUNT=$(count_results)
    if (( CUR_COUNT > PREV_COUNT )); then
     GOT_RESULT=true
     break
    fi
      NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
      if [[ -n "$NEW_OUTPUT" ]]; then
       CUR_SIZE=$(output_size)
       if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
        log "spotread communication problem during read - retrying once"
        printf " " >&3
        RETRIED_COMM=1
        READ_TIMEOUT=$((READ_TIMEOUT + 15))
        SCAN_OFFSET=$(output_size)
        continue
       fi
       if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
        if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
         log "manual prompt during read: reason=$PROMPT_REASON name=$NAME"
         wait_for_device_ready "$PROMPT_REASON"
         printf " " >&3
         READ_START=$SECONDS
         READ_TIMEOUT=$((READ_TIMEOUT + 30))
         SCAN_OFFSET=$(output_size)
         continue
        fi
       fi
       SCAN_OFFSET="$CUR_SIZE"
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

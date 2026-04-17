#!/bin/bash
# meter_series.sh - Background measurement series helper
# Called by PGenerator webui.pm to run a series of pattern+measurement steps
# Uses a SINGLE persistent spotread session across all patches for speed
# Usage: meter_series.sh <series_id> <display_type> <delay_ms> <patch_size> <steps_file> <state_file> [ccss_file]

set -o pipefail

SERIES_ID="$1"
DISPLAY_TYPE="$2"
DELAY_MS="$3"
PATCH_SIZE="$4"
STEPS_FILE="$5"
STATE_FILE="$6"
CCSS_FILE="$7"
PATCH_INSERT="${8:-0}"
REFRESH_RATE="${9:-}"
DISABLE_AIO="${10:-0}"
SPOTREAD_BIN="/usr/bin/spotread"
API_BASE="http://127.0.0.1/api"
TMPDIR="/tmp"

get_step_count() {
 python -c "
import json,sys
steps=json.load(open('$STEPS_FILE'))
print(len(steps))
" 2>/dev/null
}

get_step_field() {
 local idx="$1" field="$2"
 python -c "
import json
steps=json.load(open('$STEPS_FILE'))
print(steps[$idx].get('$field',''))
" 2>/dev/null
}

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
 # Allow USB device to fully release after spotread -? probe
 sleep 2
 echo "$port_num"
}

TOTAL=$(get_step_count)
DELAY_SEC=$(python -c "print($DELAY_MS/1000.0)" 2>/dev/null)

# Full cleanup of any previous meter state. Called before starting a session
# and again before any init retry. Kills every known meter process and
# removes all stale temp files that could interfere with spotread startup
# (held USB handles, stale FIFOs, cached port numbers that no longer exist).
meter_full_cleanup() {
 # Kill all meter-related processes (wrappers, pipelines, spotread itself)
 pkill -9 -f 'meter_session.sh'          2>/dev/null
 pkill -9 -f 'spotread_wrapper'          2>/dev/null
 pkill -9 -f 'script.*spotread'          2>/dev/null
 pkill -9 -f 'cat.*spotread_cmd'         2>/dev/null
 pkill -9 -f 'sudo.*spotread'            2>/dev/null
 pkill -9 -x spotread                    2>/dev/null
 rm -f /tmp/meter_session.pid /tmp/meter_session.cmd /tmp/meter_session.config 2>/dev/null
 # Remove all stale spotread / meter_read temp artifacts
 rm -f /tmp/spotread_cmd_*    2>/dev/null
 rm -f /tmp/spotread_out_*    2>/dev/null
 rm -f /tmp/spotread_series_* 2>/dev/null
 rm -f /tmp/meter_read.json.tmp 2>/dev/null
 # Only drop the port cache if it's older than 1h (safe to re-probe)
 if [[ -f /tmp/spotread_port_cache ]]; then
  local cage
  cage=$(( $(date +%s) - $(stat -c %Y /tmp/spotread_port_cache 2>/dev/null || echo 0) ))
  (( cage > 3600 )) && rm -f /tmp/spotread_port_cache
 fi
 sleep 1
}

# Initial cleanup
meter_full_cleanup

# Find meter port
PORT_NUM=$(find_port)

# Start persistent spotread session. If the first attempt fails to reach
# the "to take a reading:" prompt within 30s we assume a stuck USB handle
# or stale process is holding the meter; force a full cleanup and retry
# once before reporting "Meter init failed".
INIT_ATTEMPT=0
MAX_INIT_ATTEMPTS=2
while : ; do
 INIT_ATTEMPT=$((INIT_ATTEMPT + 1))

 OUTFILE="$TMPDIR/spotread_series_$$"
 CMDPIPE="$TMPDIR/spotread_cmd_$$"
 rm -f "$OUTFILE" "$CMDPIPE"
 touch "$OUTFILE"
 mkfifo "$CMDPIPE"

 SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x"
 if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" ]]; then
  # Honor CCSS file's DISPLAY_TYPE_REFRESH field to match HCFR behavior
  CCSS_REFRESH=$(grep -i 'DISPLAY_TYPE_REFRESH' "$CCSS_FILE" 2>/dev/null | head -1)
  if [[ "$CCSS_REFRESH" == *'"NO"'* ]]; then
   DISPLAY_TYPE="l"
  elif [[ "$CCSS_REFRESH" == *'"YES"'* ]]; then
   DISPLAY_TYPE="c"
  fi
  SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -x"
 fi
 # Override refresh rate if specified
 if [[ -n "$REFRESH_RATE" ]]; then
  SR_CMD="$SR_CMD -Y R:$REFRESH_RATE"
 fi
 # Disable AIO mode for i1D3 meters if requested
 if [[ "$DISABLE_AIO" == "1" ]]; then
  export I1D3_DISABLE_AIO=1
 fi
 cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
 BG_PID=$!
 exec 3>"$CMDPIPE"

 # Wait for spotread to be ready
 WAITED=0
 while (( WAITED < 30 )); do
  if grep -q "to take a reading:" "$OUTFILE" 2>/dev/null; then
   break
  fi
  sleep 0.5
  WAITED=$((WAITED + 1))
 done

 if grep -q "to take a reading:" "$OUTFILE" 2>/dev/null; then
  # Success
  break
 fi

 # Failure path — tear down this attempt
 DBGOUT=$(head -c 200 "$OUTFILE" 2>/dev/null | tr '"' "'" | tr '\n' ' ' | tr '\r' ' ')
 printf "Q" >&3 2>/dev/null; exec 3>&- 2>/dev/null
 kill -9 "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null
 rm -f "$OUTFILE" "$CMDPIPE"

 if (( INIT_ATTEMPT < MAX_INIT_ATTEMPTS )); then
  # Force full cleanup and invalidate port cache before retrying
  meter_full_cleanup
  rm -f /tmp/spotread_port_cache 2>/dev/null
  pkill -9 -x spotread 2>/dev/null
  sleep 2
  PORT_NUM=$(find_port)
  continue
 fi

 # All attempts exhausted — report error
 cat > "$STATE_FILE" << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter init failed","debug":"$DBGOUT","readings":[]}
EOJSON
 pkill -9 -x spotread 2>/dev/null
 exit 1
done

# Refresh rate calibration: in CRT/OLED mode (-y c/r), spotread asks to read
# an 80% white patch first. Display a bright white patch, send a space to satisfy
# the calibration, then wait for the second "to take a reading:" prompt.
CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
if echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
 # Display a white patch for calibration
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d '{"name":"patch","r":255,"g":255,"b":255,"size":100,"input_max":255}' >/dev/null 2>&1
 sleep 2
 INITIAL_PROMPTS=$(echo "$CLEAN_OUT" | grep -c "to take a reading:")
 printf " " >&3
 CAL_WAIT=0
 while (( CAL_WAIT < 30 )); do
  CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
  CUR_PROMPTS=$(echo "$CLEAN_OUT" | grep -c "to take a reading:")
  if (( CUR_PROMPTS > INITIAL_PROMPTS )); then
   break
  fi
  sleep 0.5
  CAL_WAIT=$((CAL_WAIT + 1))
 done
fi

# Helper: count result lines
count_results() {
 local n
 n=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -c "Result is XYZ:" 2>/dev/null) || true
 echo "${n:-0}" | tr -d '[:space:]'
}

# Helper: parse latest result
parse_latest_result() {
 local clean_out result_line
 clean_out=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 result_line=$(echo "$clean_out" | grep "Result is XYZ:" | tail -1)
 if [[ -n "$result_line" ]]; then
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
 fi
 return 1
}

READINGS=""
READING_COUNT=0

for (( i=0; i<TOTAL; i++ )); do
 R=$(get_step_field $i r)
 G=$(get_step_field $i g)
 B=$(get_step_field $i b)
 IRE=$(get_step_field $i ire)
 NAME=$(get_step_field $i name)
 STEP_NUM=$((i + 1))

 # Update state: displaying
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (displaying)","readings":[$READINGS]}
EOJSON

 # ABL stabilization: flash mid-gray between patches
 if [[ "$PATCH_INSERT" == "1" ]] && (( i > 0 )); then
  curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
   -d "{\"name\":\"patch\",\"r\":64,\"g\":64,\"b\":64,\"size\":100,\"input_max\":255}" >/dev/null 2>&1
  sleep 1.5
 fi

 # Display pattern
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"patch\",\"r\":$R,\"g\":$G,\"b\":$B,\"size\":$PATCH_SIZE,\"input_max\":255}" >/dev/null 2>&1

 # Settle delay — shorter for near-black
 if (( IRE <= 5 )); then
  sleep 1
 else
  sleep "$DELAY_SEC"
 fi

 # Update state: reading
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (reading)","readings":[$READINGS]}
EOJSON

 # Per-patch timeout
 if (( IRE <= 5 )); then
  READ_TIMEOUT=25
 elif (( IRE <= 20 )); then
  READ_TIMEOUT=20
 else
  READ_TIMEOUT=10
 fi

 # Trigger reading: send space
 PREV_COUNT=$(count_results)
 printf " " >&3

 # Wait for result
 READ_START=$SECONDS
 GOT_RESULT=false
 while (( SECONDS - READ_START < READ_TIMEOUT )); do
  CUR_COUNT=$(count_results)
  if (( CUR_COUNT > PREV_COUNT )); then
   GOT_RESULT=true
   break
  fi
  sleep 0.3
 done

 READING=""
 if $GOT_RESULT; then
  PARSED=$(parse_latest_result)
  if [[ -n "$PARSED" ]]; then
   READING=$(python -c "
import json
r=json.loads('''$PARSED''')
r['ire']=$IRE
r['name']='$NAME'
r['r_code']=$R
r['g_code']=$G
r['b_code']=$B
print(json.dumps(r))
" 2>/dev/null)
  fi
 fi

 if [[ -z "$READING" ]]; then
  READING="{\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B,\"error\":\"no_reading\"}"
 fi

 # Accumulate
 if [[ $READING_COUNT -gt 0 ]]; then
  READINGS="$READINGS,$READING"
 else
  READINGS="$READING"
 fi
 READING_COUNT=$((READING_COUNT + 1))

 # Update state
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME","readings":[$READINGS]}
EOJSON
done

# Quit spotread
printf "Q" >&3 2>/dev/null
exec 3>&- 2>/dev/null
sleep 0.5
kill "$BG_PID" 2>/dev/null
SR_KIDS=$(pgrep -P "$BG_PID" 2>/dev/null)
for p in $SR_KIDS; do
 SR_GRANDKIDS=$(pgrep -P "$p" 2>/dev/null)
 kill -9 $SR_GRANDKIDS 2>/dev/null
 kill -9 "$p" 2>/dev/null
done
kill -9 "$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null
pkill -9 -x spotread 2>/dev/null
rm -f "$OUTFILE" "$CMDPIPE"

# Display black screen to prevent burn-in
curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
 -d '{"name":"stop"}' >/dev/null 2>&1

# Mark complete
cat > "$STATE_FILE" << EOJSON
{"status":"complete","series_id":"$SERIES_ID","current_step":$TOTAL,"total_steps":$TOTAL,"current_name":"Done","readings":[$READINGS]}
EOJSON

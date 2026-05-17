#!/bin/bash
# meter_series.sh - Background measurement series helper
# Called by PGenerator webui.pm to run a series of pattern+measurement steps
# Uses a SINGLE persistent spotread session across all patches for speed
# Usage: meter_series.sh <series_id> <display_type> <delay_ms> <patch_size> <steps_file> <state_file> [ccss_file] [patch_insert] [refresh_rate] [disable_aio] [signal_mode] [max_luma] [dv_map_mode] [meter_port] [ready_file] [require_device_ready] [pattern_signal_range] [transport_signal_range]

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
SIGNAL_MODE="${11:-sdr}"
MAX_LUMA="${12:-1000}"
DV_MAP_MODE="${13:-}"
METER_PORT="${14:-}"
READY_FILE="${15:-/tmp/meter_series_ready_${SERIES_ID}.signal}"
REQUIRE_DEVICE_READY="${16:-0}"
PATTERN_SIGNAL_RANGE="${17:-}"
TRANSPORT_SIGNAL_RANGE="${18:-}"
SPOTREAD_BIN="/usr/bin/spotread"
API_BASE="http://127.0.0.1/api"
TMPDIR="/tmp"
INITIAL_READY_PENDING=0
EMISSIVE_BLACK_NO_READ=0
NEXT_PROMPT_MIN=1
[[ "$REQUIRE_DEVICE_READY" == "1" ]] && INITIAL_READY_PENDING=1
[[ "$DISPLAY_TYPE" == "c" ]] && EMISSIVE_BLACK_NO_READ=1

json_escape() {
 printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

patch_request_body() {
 local r="$1" g="$2" b="$3" size="$4" signal_mode="$5" max_luma="$6" signal_range="$7" transport_signal_range="$8" input_max="${9:-255}"
 [[ -z "$input_max" || "$input_max" == "-" ]] && input_max=255
 local payload="{\"name\":\"patch\",\"r\":$r,\"g\":$g,\"b\":$b,\"size\":$size,\"input_max\":$input_max,\"signal_mode\":\"$signal_mode\",\"max_luma\":$max_luma"
 if [[ -n "$signal_range" ]]; then
  payload="$payload,\"signal_range\":\"$signal_range\""
 fi
 if [[ -n "$transport_signal_range" ]]; then
  payload="$payload,\"transport_signal_range\":\"$transport_signal_range\""
 fi
 payload="$payload}"
 printf '%s' "$payload"
}

post_patch() {
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-$TRANSPORT_SIGNAL_RANGE}" "$9")" >/dev/null 2>&1
}

post_patch_timeout() {
 timeout 5 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-$TRANSPORT_SIGNAL_RANGE}" "$9")" >/dev/null 2>&1 || true
}

wait_for_device_ready() {
 local step_num="$1"
 local step_name="$2"
 local wait_reason="${3:-}"
 local escaped_name
  local extra=""
 escaped_name=$(json_escape "$step_name")
  if [[ -n "$wait_reason" ]]; then
   extra=",\"awaiting_ready_reason\":\"$(json_escape "$wait_reason")\""
  fi
 rm -f "$READY_FILE"
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$step_num,"total_steps":$TOTAL,"current_name":"$escaped_name","awaiting_ready":true${extra},"readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 while [[ ! -f "$READY_FILE" ]]; do
  sleep 0.2
 done
 rm -f "$READY_FILE"
}

maybe_wait_for_initial_ready() {
 local step_num="$1"
 local step_name="$2"
 [[ "$INITIAL_READY_PENDING" == "1" ]] || return 1
 wait_for_device_ready "$step_num" "$(manual_ready_prompt_label "$step_name" "initial_measurement")" "initial_measurement"
 INITIAL_READY_PENDING=0
 return 0
}

output_size() {
 if [[ -f "$OUTFILE" ]]; then
  wc -c < "$OUTFILE" 2>/dev/null | tr -d '[:space:]'
 else
  echo 0
 fi
}

count_prompts() {
 local n
 n=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -c "to take a reading:" 2>/dev/null) || true
 echo "${n:-0}" | tr -d '[:space:]'
}

wait_for_read_prompt() {
 local min_count="${1:-1}"
 local timeout_sec="${2:-8}"
 local start=$SECONDS
 local cur
 while (( SECONDS - start < timeout_sec )); do
  cur=$(count_prompts)
  if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= min_count )); then
   return 0
  fi
  sleep 0.1
 done
 return 1
}

trigger_spotread_read() {
 local label="$1"
 local prompt_timeout="${2:-8}"
 local cur
 if ! wait_for_read_prompt "$NEXT_PROMPT_MIN" "$prompt_timeout"; then
  echo "[$(date '+%H:%M:%S.%3N')] prompt wait timeout: need=$NEXT_PROMPT_MIN have=$(count_prompts) label=$label" >> /tmp/meter_series_debug.log
 fi
 cur=$(count_prompts)
 [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
 printf " " >&3
 NEXT_PROMPT_MIN=$((cur + 1))
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

manual_ready_prompt_label() {
 local step_name="$1"
 local reason="$2"
 case "$reason" in
  initial_measurement)
   printf '%s' "$step_name (click Device Ready when positioned)"
   ;;
  incorrect_position)
   printf '%s' "$step_name (reposition meter and click Device Ready)"
   ;;
  calibration_setup)
   printf '%s' "$step_name (complete meter setup/calibration and click Device Ready)"
   ;;
  *)
   printf '%s' "$step_name (click Device Ready when positioned)"
   ;;
 esac
}

rm -f "$READY_FILE"
trap 'rm -f "$READY_FILE"' EXIT

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

float_le() {
 local left="${1:-0}" right="${2:-0}"
 awk -v left="$left" -v right="$right" 'BEGIN { exit !((left + 0) <= (right + 0)) }'
}

read_timeout_seconds() {
	 local ire="${1:-0}"
	 if float_le "$ire" 1; then
	  echo 90
 elif float_le "$ire" 5; then
  echo 70
 elif float_le "$ire" 20; then
  echo 20
 else
  echo 10
	 fi
}

greyscale_low_read_retry_enabled() {
 [[ "$SERIES_ID" == greyscale_* ]] || return 1
 awk -v v="${1:-0}" 'BEGIN { exit !((v + 0) > 0 && (v + 0) <= 20.0001) }'
}

reading_is_invalid_low_light() {
 local reading_json="$1"
 local ire="${2:-0}"
 local attempt="${3:-1}"
 local max_attempts="${4:-1}"
 greyscale_low_read_retry_enabled "$ire" || return 1
 READING_JSON="$reading_json" WHITE_READING_JSON="$WHITE_READING" READ_ATTEMPT="$attempt" MAX_READ_ATTEMPTS="$max_attempts" python -c "import json, os, sys, math
try:
 r=json.loads(os.environ.get('READING_JSON','') or '{}')
 y=float(r.get('Y', r.get('luminance', 0)) or 0)
 x=float(r.get('x', 0) or 0)
 yy=float(r.get('y', 0) or 0)
 ire=float('$ire' or 0)
 attempt=int(os.environ.get('READ_ATTEMPT','1') or 1)
 max_attempts=max(1, int(os.environ.get('MAX_READ_ATTEMPTS','1') or 1))
 white_y=0.0
 try:
  w=json.loads(os.environ.get('WHITE_READING_JSON','') or '{}')
  white_y=float(w.get('Y', w.get('luminance', 0)) or 0)
 except Exception:
  white_y=0.0
 invalid=(y <= 0.0) or (y < 0.5 and abs(x - 0.333333) < 0.0002 and abs(yy - 0.333333) < 0.0002)
 if not invalid and white_y > 1 and ire > 0:
  stim=max(ire/100.0, 0.0)
  expected=white_y*(stim**2.4)
  if ire <= 10.0001:
   max_reasonable=max(expected*1.8, expected+0.10)
  elif ire <= 15.0001:
   max_reasonable=max(expected*1.25, expected+0.35)
  elif ire <= 20.0001:
   max_reasonable=max(expected*1.20, expected+0.50)
  else:
   max_reasonable=max(1.0, expected*8.0)
  if y > max_reasonable and attempt < max_attempts:
   invalid=True
 sys.exit(0 if invalid else 1)
except Exception:
 sys.exit(1)" >/dev/null 2>&1
}

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
  # Allow USB device to fully release after spotread -? probe
  sleep 2
 fi
 echo "$port_num"
}

TOTAL=$(get_step_count)
DELAY_SEC=$(python -c "print($DELAY_MS/1000.0)" 2>/dev/null)
FIRST_STEP_EXTRA_SEC=2
FRESH_DAEMON_WINDOW_SEC=180
FRESH_DV_FIRST_WHITE_EXTRA_SEC=8

daemon_elapsed_sec() {
 local pid
 pid=$(pgrep -o -f '/usr/sbin/PGeneratord\.pl' 2>/dev/null | head -1)
 if [[ -z "$pid" ]]; then
  echo 999999
  return
 fi
 ps -o etimes= -p "$pid" 2>/dev/null | awk '{print ($1 ~ /^[0-9]+$/) ? $1 : 999999}'
}

should_apply_fresh_dv_first_white_warmup() {
 [[ "$SIGNAL_MODE" == "dv" ]] || return 1
 local elapsed
 elapsed=$(daemon_elapsed_sec)
 [[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
 (( elapsed <= FRESH_DAEMON_WINDOW_SEC ))
}

series_uses_initial_white_reference() {
 [[ "$SIGNAL_MODE" == "dv" ]] || return 1
 [[ "$DV_MAP_MODE" != "1" ]] || return 1
 [[ "$SERIES_ID" == saturations_* || "$SERIES_ID" == colors_* ]]
}

series_requires_final_white_refresh() {
 [[ "$SERIES_ID" == greyscale_* ]] || return 1
 (( TOTAL > 2 ))
}

find_greyscale_white_step_index() {
 [[ "$SERIES_ID" == greyscale_* ]] || return 1
 local idx ire name
 for (( idx=0; idx<TOTAL; idx++ )); do
  ire=$(get_step_field "$idx" ire)
  name=$(get_step_field "$idx" name)
  if awk -v v="$ire" 'BEGIN { exit !(v != "" && (v + 0) >= 99.9 && (v + 0) <= 100.1) }'; then
   echo "$idx"
   return 0
  fi
  case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
   *"100%"*|*"target white"*|*"white ref"*|"white")
    echo "$idx"
    return 0
    ;;
  esac
 done
 return 1
}

build_series_read_order() {
 READ_ORDER=()
 local white_index=""
 if [[ "$SERIES_ID" == greyscale_* ]] && (( TOTAL > 2 )); then
  white_index=$(find_greyscale_white_step_index || true)
  if [[ "$white_index" =~ ^[0-9]+$ ]] && (( white_index >= START_INDEX && white_index < TOTAL )); then
   READ_ORDER+=("$white_index")
  fi
 fi
 local idx
 for (( idx=START_INDEX; idx<TOTAL; idx++ )); do
  if [[ "$white_index" =~ ^[0-9]+$ ]] && (( idx == white_index )); then
   continue
  fi
  READ_ORDER+=("$idx")
 done
}

# Publish an immediate startup state so the UI shows progress instead of
# looking hung while spotread is performing its cold-start handshake.
cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON

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

# Start persistent spotread session. A cold boot can take noticeably longer
# to enumerate the USB meter and reach the "to take a reading:" prompt,
# especially after a Pi restart, so allow a longer init window before we
# declare failure and retry cleanup.
INIT_ATTEMPT=0
MAX_INIT_ATTEMPTS=3
while : ; do
 INIT_ATTEMPT=$((INIT_ATTEMPT + 1))

 PORT_NUM=$(find_port "$METER_PORT")
 if [[ -z "$PORT_NUM" ]]; then
  DBGOUT="Meter did not enumerate during initialization"
  if (( INIT_ATTEMPT < MAX_INIT_ATTEMPTS )); then
   cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON
   meter_full_cleanup
   sleep 2
   continue
  fi
  cat > "$STATE_FILE" << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter init failed","debug":"$DBGOUT","readings":[]}
EOJSON
  exit 1
 fi

 OUTFILE="$TMPDIR/spotread_series_$$"
 CMDPIPE="$TMPDIR/spotread_cmd_$$"
 rm -f "$OUTFILE" "$CMDPIPE"
 touch "$OUTFILE"
 mkfifo "$CMDPIPE"

 SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x"
 if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" ]]; then
  CCSS_META_ALL=$(grep -iE '^[[:space:]]*(DISPLAY|TECHNOLOGY)[[:space:]]' "$CCSS_FILE" 2>/dev/null | tr '\n' ' ')
  if [[ "$CCSS_META_ALL $CCSS_FILE" =~ (OLED|Plasma|CRT) ]]; then
   EMISSIVE_BLACK_NO_READ=1
  fi
  # Read the actual DISPLAY_TYPE_REFRESH value line, not the KEYWORD declaration.
  # If the field is missing, fall back to the CCSS metadata so OLED/Plasma/CRT
  # profiles don't get treated like generic LCDs (or vice versa).
  CCSS_REFRESH=$(grep -iE '^[[:space:]]*DISPLAY_TYPE_REFRESH[[:space:]]' "$CCSS_FILE" 2>/dev/null | head -1)
  if [[ "$CCSS_REFRESH" == *'"NO"'* ]]; then
   DISPLAY_TYPE="l"
  elif [[ "$CCSS_REFRESH" == *'"YES"'* ]]; then
   DISPLAY_TYPE="c"
  else
   CCSS_META="$CCSS_META_ALL"
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

 # Wait for spotread to be ready. 120 x 0.5 s = 60 s, which avoids false
 # "Meter init failed" errors right after a reboot when USB bring-up is slow.
 # If the meter immediately reports a communications failure, stop waiting and
 # fall into the retry path so the UI doesn't sit on Initializing meter.
 WAITED=0
REFRESH_CAL_DONE=0
WHITE_REF_DONE=0
 while (( WAITED < 120 )); do
 CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 if echo "$CLEAN_OUT" | grep -q "to take a reading:"; then
   break
  fi
 if (( REFRESH_CAL_DONE == 0 )) && echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
  post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
  sleep 2
  printf " " >&3
  REFRESH_CAL_DONE=1
  sleep 2
  WAITED=$((WAITED + 4))
  continue
 fi
 if (( WHITE_REF_DONE == 0 )) && manual_calibration_setup_prompt "$CLEAN_OUT"; then
    if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
     wait_for_device_ready 0 "$(manual_ready_prompt_label "Initializing meter" "calibration_setup")" "calibration_setup"
    else
     sleep 4
    fi
  printf " " >&3
  WHITE_REF_DONE=1
  WAITED=$((WAITED + 1))
  continue
 fi
 if echo "$CLEAN_OUT" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected"; then
   break
  fi
  sleep 0.5
  WAITED=$((WAITED + 1))
 done

 if sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -q "to take a reading:"; then
  # Success
  NEXT_PROMPT_MIN=$(count_prompts)
  [[ "$NEXT_PROMPT_MIN" =~ ^[0-9]+$ && "$NEXT_PROMPT_MIN" -gt 0 ]] || NEXT_PROMPT_MIN=1
  break
 fi

 # Failure path — tear down this attempt
 DBGOUT=$(head -c 400 "$OUTFILE" 2>/dev/null | tr '"' "'" | tr '\n' ' ' | tr '\r' ' ')
 printf "Q" >&3 2>/dev/null; exec 3>&- 2>/dev/null
 kill -9 "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null
 rm -f "$OUTFILE" "$CMDPIPE"

 if (( INIT_ATTEMPT < MAX_INIT_ATTEMPTS )); then
  cat > "$STATE_FILE" << EOJSON
  {"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON
  # Force full cleanup and invalidate port cache before retrying.
  meter_full_cleanup
  rm -f /tmp/spotread_port_cache 2>/dev/null
  pkill -9 -x spotread 2>/dev/null
  sleep 2
  PORT_NUM=$(find_port "$METER_PORT")
  continue
 fi

 # All attempts exhausted — report error
 cat > "$STATE_FILE" << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter init failed","debug":"$DBGOUT","readings":[]}
EOJSON
 pkill -9 -x spotread 2>/dev/null
 exit 1
done

# Refresh rate calibration: some spotread builds keep rewriting the same
# prompt line instead of emitting a second prompt, so don't wait for the prompt
# count to increase here or startup can deadlock.
CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
if (( REFRESH_CAL_DONE == 0 )) && echo "$CLEAN_OUT" | grep -qi "calibrate refresh"; then
 post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
 sleep 2
 trigger_spotread_read "white pre-read" 8
 sleep 2
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
	  local num_re='^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$'
	  if ! [[ "$X" =~ $num_re && "$Y" =~ $num_re && "$Z" =~ $num_re && "$lum" =~ $num_re && "$x_chr" =~ $num_re && "$y_chr" =~ $num_re ]]; then
	   return 1
	  fi

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

build_step_reading_json() {
 local parsed_json="$1" idx="$2"
 local step_ire step_name step_r step_g step_b step_input_max
 local target_x target_y target_Yn series_color sat_pct stimulus plot_ire nominal_ire analysis_ire target_ire patch_stimulus
 local signal_r_pct signal_g_pct signal_b_pct series_type series_mode
 step_ire=$(get_step_field "$idx" ire)
 step_name=$(get_step_field "$idx" name)
 step_r=$(get_step_field "$idx" r)
 step_g=$(get_step_field "$idx" g)
 step_b=$(get_step_field "$idx" b)
 step_input_max=$(get_step_field "$idx" input_max)
 target_x=$(get_step_field "$idx" target_x)
 target_y=$(get_step_field "$idx" target_y)
 target_Yn=$(get_step_field "$idx" target_Yn)
 series_color=$(get_step_field "$idx" series_color)
 sat_pct=$(get_step_field "$idx" sat_pct)
 stimulus=$(get_step_field "$idx" stimulus)
 plot_ire=$(get_step_field "$idx" plot_ire)
 nominal_ire=$(get_step_field "$idx" nominal_ire)
 analysis_ire=$(get_step_field "$idx" analysis_ire)
 target_ire=$(get_step_field "$idx" target_ire)
 patch_stimulus=$(get_step_field "$idx" patch_stimulus)
 signal_r_pct=$(get_step_field "$idx" signal_r_pct)
 signal_g_pct=$(get_step_field "$idx" signal_g_pct)
 signal_b_pct=$(get_step_field "$idx" signal_b_pct)
 series_type=$(get_step_field "$idx" series_type)
 series_mode=$(get_step_field "$idx" series_mode)
 PARSED_JSON="$parsed_json" STEP_IRE="$step_ire" STEP_NAME="$step_name" STEP_R="$step_r" STEP_G="$step_g" STEP_B="$step_b" STEP_INPUT_MAX="$step_input_max" \
 STEP_TARGET_X="$target_x" STEP_TARGET_Y="$target_y" STEP_TARGET_YN="$target_Yn" STEP_SERIES_COLOR="$series_color" STEP_SAT_PCT="$sat_pct" \
 STEP_STIMULUS="$stimulus" STEP_PLOT_IRE="$plot_ire" STEP_NOMINAL_IRE="$nominal_ire" STEP_ANALYSIS_IRE="$analysis_ire" STEP_TARGET_IRE="$target_ire" STEP_PATCH_STIMULUS="$patch_stimulus" \
 STEP_SIGNAL_R_PCT="$signal_r_pct" STEP_SIGNAL_G_PCT="$signal_g_pct" STEP_SIGNAL_B_PCT="$signal_b_pct" STEP_SERIES_TYPE="$series_type" STEP_SERIES_MODE="$series_mode" python -c "import json, os
r=json.loads(os.environ['PARSED_JSON'])
def env(name):
 return os.environ.get(name,'')
def set_num(key,name):
 v=env(name)
 if v == '':
  return
 try:
  f=float(v)
 except Exception:
  return
 r[key]=int(f) if abs(f-round(f)) < 1e-9 and key in ('ire','r_code','g_code','b_code','input_max') else f
def set_str(key,name):
 v=env(name)
 if v != '':
  r[key]=v
set_num('ire','STEP_IRE')
set_str('name','STEP_NAME')
set_num('r_code','STEP_R')
set_num('g_code','STEP_G')
set_num('b_code','STEP_B')
set_num('input_max','STEP_INPUT_MAX')
for key,name in (
 ('target_x','STEP_TARGET_X'),('target_y','STEP_TARGET_Y'),('target_Yn','STEP_TARGET_YN'),
 ('sat_pct','STEP_SAT_PCT'),('stimulus','STEP_STIMULUS'),('plot_ire','STEP_PLOT_IRE'),
 ('nominal_ire','STEP_NOMINAL_IRE'),('analysis_ire','STEP_ANALYSIS_IRE'),
 ('target_ire','STEP_TARGET_IRE'),('patch_stimulus','STEP_PATCH_STIMULUS'),
 ('signal_r_pct','STEP_SIGNAL_R_PCT'),('signal_g_pct','STEP_SIGNAL_G_PCT'),('signal_b_pct','STEP_SIGNAL_B_PCT')):
 set_num(key,name)
for key,name in (('series_color','STEP_SERIES_COLOR'),('series_type','STEP_SERIES_TYPE'),('series_mode','STEP_SERIES_MODE')):
 set_str(key,name)
print(json.dumps(r))" 2>>/tmp/meter_series_python_error.log
}

replace_series_reading() {
 local target_ire="$1"
 local target_name="$2"
 local replacement="$3"
 local updated
 updated=$(READINGS_JSON="[$READINGS]" TARGET_IRE="$target_ire" TARGET_NAME="$target_name" REPLACEMENT_JSON="$replacement" python -c "import json, os
try:
 readings=json.loads(os.environ.get('READINGS_JSON','[]') or '[]')
except Exception:
 readings=[]
replacement=json.loads(os.environ['REPLACEMENT_JSON'])
target_ire=str(os.environ.get('TARGET_IRE',''))
target_name=os.environ.get('TARGET_NAME','')
for idx, reading in enumerate(readings):
 if str(reading.get('ire','')) == target_ire or (target_name and reading.get('name','') == target_name):
  readings[idx]=replacement
  break
else:
 readings.append(replacement)
print(','.join(json.dumps(item, separators=(',',':')) for item in readings))" 2>/dev/null)
 [[ -n "$updated" ]] || return 1
 READINGS="$updated"
 READING_COUNT=$(READINGS_JSON="[$READINGS]" python -c "import json, os
try:
 print(len(json.loads(os.environ.get('READINGS_JSON','[]') or '[]')))
except Exception:
 print(0)" 2>/dev/null)
 [[ "$READING_COUNT" =~ ^[0-9]+$ ]] || READING_COUNT=0
 return 0
}

WHITE_READING="null"

# DEBUG: Log this execution for troubleshooting
echo "[$(date '+%H:%M:%S.%3N')] meter_series.sh started: SERIES_ID=$SERIES_ID" >> /tmp/meter_series_debug.log

# DV Relative color and saturation series still use a helper-side white
# pre-read for target Y. DV Absolute should use the in-series 100% White step
# instead so the white patch is measured once and remains part of the charts.
if series_uses_initial_white_reference; then
 echo "[$(date '+%H:%M:%S')] WHITE PRE-READ GATE ENTERED for SERIES_ID=$SERIES_ID" >> /tmp/meter_series_debug.log
 if [[ -f "$STEPS_FILE" ]]; then
  FIRST_R=$(get_step_field 0 r)
  if [[ "$FIRST_R" =~ ^[0-9]+$ ]]; then
   WHITE_CODE="$FIRST_R"
  fi
 fi

 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y (displaying)","readings":[]}
EOJSON

 post_patch "$WHITE_CODE" "$WHITE_CODE" "$WHITE_CODE" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
 if should_apply_fresh_dv_first_white_warmup; then
  sleep "$FRESH_DV_FIRST_WHITE_EXTRA_SEC"
  post_patch "$WHITE_CODE" "$WHITE_CODE" "$WHITE_CODE" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
 fi
 PREREAD_DELAY="$DELAY_SEC"
 PREREAD_DELAY=$(python -c "print(float('$PREREAD_DELAY') + $FIRST_STEP_EXTRA_SEC)" 2>/dev/null)
 if ! maybe_wait_for_initial_ready 0 "Reading 100% white for target Y"; then
  sleep "$PREREAD_DELAY"
 fi

 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y (reading)","readings":[]}
EOJSON

 PREV_COUNT=$(count_results)
 DEBUG_LOG="/tmp/white_read_debug_$$.log"
 echo "[$(date '+%H:%M:%S')] Starting white pre-read: PREV_COUNT=$PREV_COUNT, OUTFILE=$OUTFILE" > "$DEBUG_LOG"
 
 SCAN_OFFSET=$(output_size)
 trigger_spotread_read "white reference pre-read" 8
 READ_START=$SECONDS
 GOT_RESULT=false
 ITERATIONS=0
 
	 while (( SECONDS - READ_START < 20 )); do
	  CUR_COUNT=$(count_results)
	  ITERATIONS=$((ITERATIONS + 1))
	  echo "[$(date '+%H:%M:%S.%3N')] Iteration $ITERATIONS (elapsed $((SECONDS - READ_START))s): PREV_COUNT=$PREV_COUNT CUR_COUNT=$CUR_COUNT" >> "$DEBUG_LOG"
	  if (( CUR_COUNT > PREV_COUNT )); then
	   PARSED=$(parse_latest_result)
	   if [[ -n "$PARSED" ]]; then
	    GOT_RESULT=true
	    echo "[$(date '+%H:%M:%S')] GOT_RESULT=true at iteration $ITERATIONS after $((SECONDS - READ_START))s" >> "$DEBUG_LOG"
	    break
	   fi
	   sleep 0.2
	   continue
	  fi
  NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
  if [[ -n "$NEW_OUTPUT" ]]; then
   CUR_SIZE=$(output_size)
   if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
    echo "[$(date '+%H:%M:%S')] Manual prompt detected during white pre-read: $PROMPT_REASON" >> "$DEBUG_LOG"
    if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
     wait_for_device_ready 0 "$(manual_ready_prompt_label "Reading 100% white for target Y" "$PROMPT_REASON")" "$PROMPT_REASON"
    else
     sleep 1
    fi
    printf " " >&3
    SCAN_OFFSET=$(output_size)
    READ_START=$SECONDS
    continue
   fi
   SCAN_OFFSET="$CUR_SIZE"
  fi
  sleep 0.3
 done

 ELAPSED=$((SECONDS - READ_START))
 echo "[$(date '+%H:%M:%S')] Loop complete: GOT_RESULT=$GOT_RESULT ITERATIONS=$ITERATIONS ELAPSED=${ELAPSED}s" >> "$DEBUG_LOG"
 
	 if $GOT_RESULT; then
	  echo "[$(date '+%H:%M:%S')] PARSED=(${#PARSED} chars) = $PARSED" >> "$DEBUG_LOG"
	  if [[ -n "$PARSED" ]]; then
   WHITE_READING=$(PARSED_JSON="$PARSED" WHITE_CODE="$WHITE_CODE" python -c "import json, os
r=json.loads(os.environ['PARSED_JSON'])
code=int(os.environ.get('WHITE_CODE','0') or 0)
r['ire']=100
r['name']='White Ref'
r['r_code']=code
r['g_code']=code
r['b_code']=code
print(json.dumps(r))" 2>>/tmp/meter_series_python_error.log || echo "null")
   echo "[$(date '+%H:%M:%S')] WHITE_READING set successfully (${#WHITE_READING} chars)" >> "$DEBUG_LOG"
  else
   echo "[$(date '+%H:%M:%S')] PARSED was empty, WHITE_READING stays null" >> "$DEBUG_LOG"
  fi
 else
  echo "[$(date '+%H:%M:%S')] GOT_RESULT was false, WHITE_READING stays null" >> "$DEBUG_LOG"
 fi
 
 echo "[$(date '+%H:%M:%S')] Final WHITE_READING=$WHITE_READING" >> "$DEBUG_LOG"
 cat "$DEBUG_LOG" >> /tmp/white_read_series.log 2>/dev/null

 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y","readings":[],"white_reading":$WHITE_READING,"debug":{"iterations":$ITERATIONS,"elapsed":$ELAPSED,"got_result":$GOT_RESULT}}
EOJSON
fi

READINGS=""
READING_COUNT=0
START_INDEX=0

# The DV pre-read above is the actual White chart reference. Reuse it as the
# first series reading so DV Colors/Sat Sweep do not immediately measure the
# same white step a second time.
if series_uses_initial_white_reference && [[ "$WHITE_READING" != "null" ]] && (( TOTAL > 0 )); then
 FIRST_NAME=$(get_step_field 0 name)
 FIRST_READING=$(build_step_reading_json "$WHITE_READING" 0 || echo "")
 if [[ -n "$FIRST_READING" ]]; then
  READINGS="$FIRST_READING"
  READING_COUNT=1
  START_INDEX=1
  cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
 fi
fi

build_series_read_order

for i in "${READ_ORDER[@]}"; do
	 R=$(get_step_field $i r)
	 G=$(get_step_field $i g)
	 B=$(get_step_field $i b)
	 INPUT_MAX=$(get_step_field $i input_max)
	 [[ -z "$INPUT_MAX" ]] && INPUT_MAX=255
	 IRE=$(get_step_field $i ire)
 NAME=$(get_step_field $i name)
 STEP_NUM=$((READING_COUNT + 1))

 # Update state: displaying
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (displaying)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

 # ABL stabilization: flash mid-gray between patches
 if [[ "$PATCH_INSERT" == "1" ]] && (( READING_COUNT > 0 )); then
  post_patch 64 64 64 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
  sleep 1.5
 fi

 # Display pattern
	 post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"

 # Right after a PGenerator restart, the first DV white often reads far too
 # low on the first pass even though an immediate rerun is correct. Give that
 # very first 100% step one extra warm-up settle while the daemon is still
 # freshly started, without slowing steady-state runs.
 if (( READING_COUNT == 0 )) && [[ "$IRE" == "100" ]] && should_apply_fresh_dv_first_white_warmup; then
  sleep "$FRESH_DV_FIRST_WHITE_EXTRA_SEC"
	  post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
 fi

 # Settle delay — use the user-configured value for every step, while still
 # keeping the existing first-step warm-up on cold starts.
 STEP_DELAY="$DELAY_SEC"
 if (( READING_COUNT == 0 )); then
  STEP_DELAY=$(python -c "print(float('$STEP_DELAY') + $FIRST_STEP_EXTRA_SEC)" 2>/dev/null)
 fi
 if ! maybe_wait_for_initial_ready "$STEP_NUM" "$NAME"; then
  sleep "$STEP_DELAY"
 fi

 # Update state: reading
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (reading)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

 # Absolute black on emissive displays (OLED/QD-OLED/CRT/plasma) often
 # has no usable meter response. Treat it as a valid 0.0 read immediately so
 # the series continues instead of sitting through a timeout.
 if [[ "$EMISSIVE_BLACK_NO_READ" == "1" && "$R" == "$G" && "$G" == "$B" ]] && float_le "$IRE" 0; then
  TS=$(date +%s)
  READING=$(build_step_reading_json "{\"X\":0,\"Y\":0,\"Z\":0,\"x\":0,\"y\":0,\"luminance\":0.0,\"cct\":0,\"timestamp\":$TS}" "$i")
  if [[ $READING_COUNT -gt 0 ]]; then
   READINGS="$READINGS,$READING"
  else
   READINGS="$READING"
  fi
  READING_COUNT=$((READING_COUNT + 1))
  cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
  continue
 fi

	 # Near-black reads can take much longer than mid/high greys. Match the
	 # manual-read tolerance here so the low end does not time out prematurely.
	 READ_TIMEOUT=$(read_timeout_seconds "$IRE")

		 READING=""
		 MAX_READ_ATTEMPTS=1
		 if greyscale_low_read_retry_enabled "$IRE"; then
		  MAX_READ_ATTEMPTS=3
		 fi
		 READ_ATTEMPT=1
		 while (( READ_ATTEMPT <= MAX_READ_ATTEMPTS )); do
		  # Trigger reading: send space only once spotread has returned to its
		  # read prompt. Without this guard, rapid low-patch sweeps can drop the
		  # keypress and leave the series waiting for a result that never starts.
		  PREV_COUNT=$(count_results)
		  SCAN_OFFSET=$(output_size)
		  trigger_spotread_read "$NAME attempt $READ_ATTEMPT" 8
		
		  # Wait for result, retrying once if spotread reports a transient
		  # communication problem with the meter.
		  READ_START=$SECONDS
		  GOT_RESULT=false
		  PARSED=""
		  RETRIED_COMM=0
		  while (( SECONDS - READ_START < READ_TIMEOUT )); do
		   CUR_COUNT=$(count_results)
		   if (( CUR_COUNT > PREV_COUNT )); then
		    PARSED=$(parse_latest_result)
		    if [[ -n "$PARSED" ]]; then
		     GOT_RESULT=true
		     break
		    fi
		    sleep 0.2
		    continue
		   fi
		   NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
		   if [[ -n "$NEW_OUTPUT" ]]; then
		    CUR_SIZE=$(output_size)
		    if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
		     printf " " >&3
		     RETRIED_COMM=1
		     READ_TIMEOUT=$((READ_TIMEOUT + 15))
		     SCAN_OFFSET=$(output_size)
		     continue
		    fi
		    if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
		     echo "[$(date '+%H:%M:%S.%3N')] manual prompt: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
		     if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
		      wait_for_device_ready "$STEP_NUM" "$(manual_ready_prompt_label "$NAME" "$PROMPT_REASON")" "$PROMPT_REASON"
		     else
		      sleep 1
		     fi
		     printf " " >&3
		     READ_START=$SECONDS
		     READ_TIMEOUT=$((READ_TIMEOUT + 30))
		     SCAN_OFFSET=$(output_size)
		     continue
		    fi
		    SCAN_OFFSET="$CUR_SIZE"
		   fi
		   sleep 0.3
		  done
		
		  READING=""
		  if $GOT_RESULT; then
		   if [[ -n "$PARSED" ]]; then
		    READING=$(build_step_reading_json "$PARSED" "$i")
		   fi
		  fi

		  if [[ -n "$READING" ]] && reading_is_invalid_low_light "$READING" "$IRE" "$READ_ATTEMPT" "$MAX_READ_ATTEMPTS"; then
		   echo "[$(date '+%H:%M:%S.%3N')] low-light invalid read retry: step=$STEP_NUM ire=$IRE attempt=$READ_ATTEMPT name=$NAME" >> /tmp/meter_series_debug.log
		   READING=""
		   READ_ATTEMPT=$((READ_ATTEMPT + 1))
		   sleep 0.6
		   continue
		 fi

		  break
		 done
		
		 if [[ -z "$READING" ]]; then
		  echo "[$(date '+%H:%M:%S.%3N')] read timeout: step=$STEP_NUM ire=$IRE timeout=${READ_TIMEOUT}s got_result=$GOT_RESULT parsed_len=${#PARSED} attempts=$READ_ATTEMPT name=$NAME" >> /tmp/meter_series_debug.log
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
 if [[ "$SERIES_ID" == greyscale_* && -n "$READING" ]] && awk -v v="$IRE" 'BEGIN { exit !(v != "" && (v + 0) >= 99.9 && (v + 0) <= 100.1) }'; then
  WHITE_READING="$READING"
 fi
 cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
done

# Non-2pt greyscale uses the first 100% read as the live white reference while
# the sweep is running, then refreshes white once more at the end so the saved
# 100% result reflects the warmed-up display.
if series_requires_final_white_refresh && (( TOTAL > 0 )); then
 WHITE_STEP_INDEX=$(find_greyscale_white_step_index || true)
 [[ "$WHITE_STEP_INDEX" =~ ^[0-9]+$ ]] || WHITE_STEP_INDEX=""
 if [[ -n "$WHITE_STEP_INDEX" ]]; then
  FIRST_R=$(get_step_field "$WHITE_STEP_INDEX" r)
  FIRST_G=$(get_step_field "$WHITE_STEP_INDEX" g)
  FIRST_B=$(get_step_field "$WHITE_STEP_INDEX" b)
  FIRST_INPUT_MAX=$(get_step_field "$WHITE_STEP_INDEX" input_max)
  [[ -z "$FIRST_INPUT_MAX" ]] && FIRST_INPUT_MAX=255
  FIRST_IRE=$(get_step_field "$WHITE_STEP_INDEX" ire)
  FIRST_NAME=$(get_step_field "$WHITE_STEP_INDEX" name)

  if [[ "$FIRST_R" =~ ^[0-9]+$ && "$FIRST_G" =~ ^[0-9]+$ && "$FIRST_B" =~ ^[0-9]+$ && "$FIRST_IRE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
   cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refresh displaying)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

   if [[ "$PATCH_INSERT" == "1" ]] && (( READING_COUNT > 0 )); then
    post_patch 64 64 64 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
    sleep 1.5
   fi

   post_patch "$FIRST_R" "$FIRST_G" "$FIRST_B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$FIRST_INPUT_MAX"
   sleep "$DELAY_SEC"

   cat > "$STATE_FILE" << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refresh reading)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

   PREV_COUNT=$(count_results)
   SCAN_OFFSET=$(output_size)
   trigger_spotread_read "$FIRST_NAME refresh" 8

	   READ_TIMEOUT=$(read_timeout_seconds "$FIRST_IRE")
	   READ_START=$SECONDS
	   GOT_RESULT=false
	   PARSED=""
	   RETRIED_COMM=0
	   while (( SECONDS - READ_START < READ_TIMEOUT )); do
	    CUR_COUNT=$(count_results)
	    if (( CUR_COUNT > PREV_COUNT )); then
	     PARSED=$(parse_latest_result)
	     if [[ -n "$PARSED" ]]; then
	      GOT_RESULT=true
	      break
	     fi
	     sleep 0.2
	     continue
	    fi
    NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
    if [[ -n "$NEW_OUTPUT" ]]; then
     CUR_SIZE=$(output_size)
     if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
      printf " " >&3
      RETRIED_COMM=1
      READ_TIMEOUT=$((READ_TIMEOUT + 15))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
      echo "[$(date '+%H:%M:%S.%3N')] manual prompt: step=1 ire=$FIRST_IRE reason=$PROMPT_REASON name=$FIRST_NAME (refresh)" >> /tmp/meter_series_debug.log
      if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
       wait_for_device_ready "1" "$(manual_ready_prompt_label "$FIRST_NAME (refresh)" "$PROMPT_REASON")" "$PROMPT_REASON"
      else
       sleep 1
      fi
      printf " " >&3
      READ_START=$SECONDS
      READ_TIMEOUT=$((READ_TIMEOUT + 30))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     SCAN_OFFSET="$CUR_SIZE"
    fi
    sleep 0.3
   done

	   REFRESH_READING=""
	   if $GOT_RESULT; then
	    if [[ -n "$PARSED" ]]; then
     REFRESH_READING=$(build_step_reading_json "$PARSED" "$WHITE_STEP_INDEX")
    fi
   fi

   if [[ -n "$REFRESH_READING" ]]; then
    if replace_series_reading "$FIRST_IRE" "$FIRST_NAME" "$REFRESH_READING"; then
     WHITE_READING="$REFRESH_READING"
     cat > "$STATE_FILE" << EOJSON
  {"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refreshed)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
    fi
   fi
  fi
 fi
fi

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
{"status":"complete","series_id":"$SERIES_ID","current_step":$TOTAL,"total_steps":$TOTAL,"current_name":"Done","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

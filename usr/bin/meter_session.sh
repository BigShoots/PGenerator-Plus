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
#   READ <r> <g> <b> <patch_size> <ire> <name> [settle_ms] [signal_mode] [max_luma] [pattern_signal_range] [transport_signal_range] [request_id] [input_max] [read_timeout] [low_light_mode]
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
METER_AVERAGING="${10:-${METER_AVERAGING:-off}}"

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
ACK_FILE="/tmp/meter_session.ack"
SETUP_STEP_ID=0

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
startup_marker() { log "startup marker: $*"; }

signal_startup_ready() {
 : > "$STARTUP_READY_FILE"
 chmod 666 "$STARTUP_READY_FILE" 2>/dev/null
}

# The helper runs as root while the WebUI runs as pgenerator. On Bookworm,
# fs.protected_regular blocks root from truncating a pgenerator-owned file in
# /tmp, even when it is 0666, so publish by replacing with a fresh file.
write_state() {
 local tmp="${STATE_FILE}.$$.$RANDOM.tmp"
 printf '%s\n' "$1" > "$tmp" || return 1
 chmod 666 "$tmp" 2>/dev/null || true
 chown pgenerator:pgenerator "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$STATE_FILE"
}

startup_output_excerpt() {
 [[ -f "$OUTFILE" ]] || return 0
 sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | tail -n 8 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

output_size() {
 if [[ -f "$OUTFILE" ]]; then
  stat -c %s "$OUTFILE" 2>/dev/null | tr -d '[:space:]'
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
   printf '%s' 'Place the spectrophotometer on its white calibration tile, then click Continue'
   ;;
  initial_measurement)
   printf '%s' 'Aim the meter at the patch on the screen, then click Continue'
   ;;
  incorrect_position)
   printf '%s' 'Reposition the meter on the patch, then click Continue'
   ;;
  *)
   printf '%s' 'Position the meter, then click Continue when ready'
   ;;
	 esac
}

ire_le() {
 awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !((a+0) <= (b+0))}'
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
 # Clear awaiting_ready immediately so the UI hides the Continue button while the
 # (slow) calibration/measurement runs -- otherwise the operator keeps seeing the
 # prompt and clicks it several times. "measuring" keeps the result poll waiting.
 write_state "{\"status\":\"measuring\"}"
}

# Race-free interactive setup step. Emits a numbered setup state and waits for an
# ack whose id matches; stale/duplicate acks are read and discarded so a click
# can't be lost and double-clicks are no-ops. $1=step key, $2=operator message.
await_setup_step() {
 local step="$1" message="$2" working="${3:-}"
 SETUP_STEP_ID=$((SETUP_STEP_ID + 1))
 local sid=$SETUP_STEP_ID
 rm -f "$ACK_FILE"
 write_state "{\"status\":\"setup\",\"step_id\":$sid,\"step\":\"$step\",\"message\":\"$message\"}"
 while true; do
  if [ -f "$ACK_FILE" ]; then
   local acked
   acked=$(tr -dc '0-9' < "$ACK_FILE" 2>/dev/null)
   rm -f "$ACK_FILE"
   [ "$acked" = "$sid" ] && break
  fi
  sleep 0.2
 done
 # After the ack, keep the wizard popup visible (no button) with a 'working'
 # message while the slow step runs (wavelength calibration takes several
 # seconds) instead of vanishing. Steps with no working text fall back to a
 # bare measuring state so the popup closes (e.g. after positioning, the read
 # proceeds and the result is shown).
 if [ -n "$working" ]; then
  write_state "{\"status\":\"measuring\",\"setup_busy\":true,\"message\":\"$working\"}"
 else
  write_state "{\"status\":\"measuring\"}"
 fi
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
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9")" >/dev/null 2>&1
}

post_patch_timeout() {
 timeout 5 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9")" >/dev/null 2>&1 || true
}

# Single-instance lock — refuse to start if another session is alive.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
 log "another session already holds the lock, exiting"
 exit 0
fi
echo $$ > "$PID_FILE"
printf '%s|%s|%s|%s|%s|%s|%s\n' "$DISPLAY_TYPE" "$CCSS_FILE" "$REFRESH_RATE" "$DISABLE_AIO" "$METER_PORT" "$REQUIRE_DEVICE_READY" "${METER_AVERAGING:-off}" > "$CONFIG_FILE"
log "session $$ starting (display=$DISPLAY_TYPE ccss=$CCSS_FILE refresh=$REFRESH_RATE aio_off=$DISABLE_AIO port=$METER_PORT ready_gate=$REQUIRE_DEVICE_READY averaging=${METER_AVERAGING:-off} idle=${IDLE_TIMEOUT}s)"
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

parse_latest_result_text() {
 local clean_out="$1" result_line
 result_line=$(printf '%s\n' "$clean_out" | grep "Result is XYZ:" | tail -1)
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
 # Ask spotread to quit cleanly, then close its stdin (EOF via the cat pipe).
 # spotread may be mid-reading (an active USB transaction); SIGKILLing it now
 # wedges the Pi's dwc2 USB controller, which then fails the NEXT session with
 # "communication failed during init". So give it time to finish the in-flight
 # read, process the quit, and release the device before escalating to a kill.
 printf "Q" >&3 2>/dev/null
 exec 3>&- 2>/dev/null
 exec 4>&- 2>/dev/null
 # Wait up to ~6s for the spotread pipeline to exit on its own.
 local _w=0
 while (( _w < 60 )) && [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; do
  sleep 0.1
  _w=$(( _w + 1 ))
 done
 # Still alive: ask politely (TERM) and let the USB transaction unwind.
 if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
  kill "$BG_PID" 2>/dev/null
  pkill -TERM -x spotread 2>/dev/null
  local _t=0
  while (( _t < 20 )) && { kill -0 "$BG_PID" 2>/dev/null || pgrep -x spotread >/dev/null 2>&1; }; do
   sleep 0.1
   _t=$(( _t + 1 ))
  done
 fi
 # Last resort only if it ignored both the quit and TERM (genuinely stuck).
 if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
  pkill -9 -P "$BG_PID" 2>/dev/null
  kill -9 "$BG_PID" 2>/dev/null
 fi
 pgrep -x spotread >/dev/null 2>&1 && pkill -9 -x spotread 2>/dev/null
 rm -f "$OUTFILE" "$CMDPIPE" "$CMD_FIFO" "$PID_FILE" "$CONFIG_FILE" "$READY_FILE" "$STARTUP_READY_FILE"
}

# Track the spotread averaging/low_light mode of the currently-running
# pipeline so per-read READ commands that change it can trigger a
# spotread-only respawn instead of a full session respawn. Initialized
# from METER_AVERAGING (the session-level averaging) because at startup
# LOW_LIGHT_FLAGS is empty -- the per-read channel was empty too until
# the first READ with a low_light field arrived.
CURRENT_LOW_LIGHT_MODE="${METER_AVERAGING:-off}"

# Rebuild SR_CMD using the current DISPLAY_TYPE, CCSS, AVG_FLAG and
# REFRESH_RATE/AIO settings, applying $1 as the new low_light mode
# (-Y a / -Y aa / -Y aaa / -x / -x -Y a / -x -Y aa / -x -Y aaa / "").
build_sr_cmd () {
 local new_mode="${1:-off}"
 local new_ll_flags=""
 case "$new_mode" in
  a)     new_ll_flags="-Y a" ;;
  aa)    new_ll_flags="-Y aa" ;;
  aaa)   new_ll_flags="-Y aaa" ;;
  x)     new_ll_flags="-x" ;;
  x_a)   new_ll_flags="-x -Y a" ;;
  x_aa)  new_ll_flags="-x -Y aa" ;;
  x_aaa) new_ll_flags="-x -Y aaa" ;;
  off|*) new_ll_flags="" ;;
  esac
  # new_ll_flags is the authoritative -Y source. Do NOT also inject $AVG_FLAG:
  # stacking e.g. "-Y a -Y A" passes conflicting integration modes to spotread.
  if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" && "$REQUIRE_DEVICE_READY" != "1" ]]; then
   local cmd="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -x $new_ll_flags"
  else
   local cmd="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x $new_ll_flags"
  fi
  # -Y R:rate overrides spotread's measured refresh rate. Passing it makes
  # spotread SKIP its mandatory "read an 80% white patch to calibrate refresh
  # frequency" step -- on a sample-and-hold OLED that auto-cal read is
  # unreliable (it fails without averaging, leaving the meter uncalibrated so
  # every subsequent read fails). So always honour an explicit rate.
  [[ -n "$REFRESH_RATE" ]] && cmd="$cmd -Y R:$REFRESH_RATE"
  printf '%s' "$cmd"
}

# Respawn ONLY the spotread pipeline (NOT the wrapper) with a new
# low_light mode. The wrapper keeps its command FIFO, PID file, config
# file, and state file intact so the WebUI does not see a session
# restart and does not pay the 35-90s OLED bring-up. The new mode
# applies to this and every subsequent read until it changes again.
respawn_spotread () {
 local new_mode="${1:-off}"
 log "respawn: switching spotread to low_light mode=$new_mode (was $CURRENT_LOW_LIGHT_MODE)"
 # Close the current spotread cleanly. SIGKILLing it mid-read wedges the
 # Pi's dwc2 USB controller, so ask politely first and escalate only if
 # it ignores the quit.
 printf "Q" >&3 2>/dev/null
 exec 3>&- 2>/dev/null
 local _w=0
 while (( _w < 60 )) && [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; do
  sleep 0.1
  _w=$(( _w + 1 ))
 done
 if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
  kill "$BG_PID" 2>/dev/null
  pkill -TERM -x spotread 2>/dev/null
  local _t=0
  while (( _t < 20 )) && { kill -0 "$BG_PID" 2>/dev/null || pgrep -x spotread >/dev/null 2>&1; }; do
   sleep 0.1
   _t=$(( _t + 1 ))
  done
 fi
 if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
  pkill -9 -P "$BG_PID" 2>/dev/null
  kill -9 "$BG_PID" 2>/dev/null
 fi
 pgrep -x spotread >/dev/null 2>&1 && pkill -9 -x spotread 2>/dev/null
 # The wait-for-ready loop below is run twice (150 iterations x 0.1s =
 # 15s per attempt, 30s total). The i1d3 AIO can take >5s to re-init
 # after a per-read low_light mode change (the previous step's averaging
 # flags must settle and the new command pipeline must be reopened), and
 # a single one-shot USB init hiccup is recovered by the second attempt.
 # The first attempt is the initial respawn; the second is a clean
 # re-exec (printf Q + kill cycle + new script invocation) so we do not
 # pay a full session restart.
 for _retry in 1 2; do
  # Truncate (NOT unlink) OUTFILE so the readiness wait does not match
  # the previous session's stale "to take a reading:" line. `script`
  # would create a new inode if we unlinked, desyncing the read-side cat.
  : > "$OUTFILE"
  # Rebuild SR_CMD with the new low_light flags. AVG_FLAG, DISPLAY_TYPE,
  # CCSS_FILE, REFRESH_RATE, and AIO are unchanged -- the only delta
  # between this respawn and the initial startup is the averaging flags.
  SR_CMD=$(build_sr_cmd "$new_mode")
  cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
  BG_PID=$!
  exec 3>"$CMDPIPE"
  log "respawn: spotread respawned (bg_pid=$BG_PID mode=$new_mode attempt=$_retry)"
  # Wait for "to take a reading:" — colorimeters re-ready in <2s; allow
  # up to 15s for the i1d3 AIO to re-init after a mode change. The
  # second iteration of the outer retry loop gives a second 15s window
  # after a clean re-exec.
  local _rt=0
  while (( _rt < 150 )); do
   local _co
   _co=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
   echo "$_co" | grep -q "to take a reading:" && break
   sleep 0.1
   _rt=$(( _rt + 1 ))
  done
  if sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -q "to take a reading:"; then
   CURRENT_LOW_LIGHT_MODE="$new_mode"
   return 0
  fi
  log "respawn: spotread failed to ready within 15s on attempt $_retry, will retry with clean re-exec"
  # Clean quit + kill cycle for the retry. Same logic as the initial
  # shutdown above but applied to the just-failed spotread.
  printf "Q" >&3 2>/dev/null
  exec 3>&- 2>/dev/null
  local _w2=0
  while (( _w2 < 60 )) && [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; do
   sleep 0.1
   _w2=$(( _w2 + 1 ))
  done
  if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
   kill "$BG_PID" 2>/dev/null
   pkill -TERM -x spotread 2>/dev/null
   local _t2=0
   while (( _t2 < 20 )) && { kill -0 "$BG_PID" 2>/dev/null || pgrep -x spotread >/dev/null 2>&1; }; do
    sleep 0.1
    _t2=$(( _t2 + 1 ))
   done
  fi
  if [[ -n "$BG_PID" ]] && kill -0 "$BG_PID" 2>/dev/null; then
   pkill -9 -P "$BG_PID" 2>/dev/null
   kill -9 "$BG_PID" 2>/dev/null
  fi
  pgrep -x spotread >/dev/null 2>&1 && pkill -9 -x spotread 2>/dev/null
 done
 log "respawn: spotread failed to ready within 15s on both attempts, surfacing error"
 write_state '{"status":"error","message":"Meter respawn failed (low-light mode change)"}'
 return 1
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

# ArgyllCMS persists the spectro wavelength calibration under the XDG dirs.
# If they are missing ("xdg_bds failed to locate file"), the i1 Pro 2 cannot
# save its cal and re-calibrates on every read. Ensure they exist so the cal is
# done once and reused. (A stable system clock is also required -- Argyll ages
# the cal by wall-clock time, so an unsynced/jumping clock re-invalidates it.)
export HOME="${HOME:-/root}"
mkdir -p "$HOME/.cache" "$HOME/.local/share" "$HOME/.config" 2>/dev/null

# i1Display3 averaging mode (low light handling): the i1D3 supports
# 2/3/5-read averaging (`-Y a` / `-Y aa` / `-Y aaa`) that reduces read
# noise at dim patches. Default OFF (single long read, no -Y flag);
# override with METER_AVERAGING=a (2 reads) / =aa (3 reads) / =aaa
# (5 reads) to enable averaging. The HDR autocal still benefits from
# 2-read averaging at 1.4-4% IRE (0.07-0.59 nits) but the default is
# the single-read path for the panel/post-cal greyscale series read.
case "${METER_AVERAGING:-off}" in
 off|OFF|none|NONE) AVG_FLAG="" ;;
 a)                 AVG_FLAG="-Y a" ;;
 aa)                AVG_FLAG="-Y aa" ;;
 aaa)               AVG_FLAG="-Y aaa" ;;
 *)                 AVG_FLAG="" ;;
esac
# Reference-style low-light handler from the calibration card. Maps the
# client-picked mode to the matching spotread flag set:
#   off   = no flag (single long read, the project convention)
#   a/aa/aaa = 2/3/5-read averaging (-Y a/-Y aa/-Y aaa)
#   x     = high precision, longer integration (-x)
#   x_a/x_aa/x_aaa = combined (-x -Y a / -x -Y aa / -x -Y aaa)
# Spotread has no direct integration-time control and maxes at 5-read
# averaging, so the client dropdown covers what spotread actually
# supports. The mode is selected at the calibration level (autocal,
# series read, single read) by comparing the expected target luminance
# to the trigger threshold on the client; meter_session.sh just
# applies whatever flag set the client asked for.
case "${LOW_LIGHT_MODE:-off}" in
 a)     LOW_LIGHT_FLAGS="-Y a" ;;
 aa)    LOW_LIGHT_FLAGS="-Y aa" ;;
 aaa)   LOW_LIGHT_FLAGS="-Y aaa" ;;
 x)     LOW_LIGHT_FLAGS="-x" ;;
 x_a)   LOW_LIGHT_FLAGS="-x -Y a" ;;
 x_aa)  LOW_LIGHT_FLAGS="-x -Y aa" ;;
 x_aaa) LOW_LIGHT_FLAGS="-x -Y aaa" ;;
 off|*) LOW_LIGHT_FLAGS="" ;;
esac
# A CCSS (Colorimeter Calibration Spectral Sample) only corrects COLORIMETERS.
# A spectrophotometer (i1 Pro 2, etc.) measures spectrally and rejects -X with
# "Instrument doesn't have Colorimeter Calibration Spectral Sample capability",
# which aborts init. require_device_ready==1 is set only for spectros, so use it
# to keep the CCSS off them. (Colorimeters keep their CCSS unchanged.)
if [[ "$REQUIRE_DEVICE_READY" == "1" && -n "$CCSS_FILE" ]]; then
 log "spectrophotometer selected: skipping CCSS ($CCSS_FILE) -- spectros measure spectrally"
fi
if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" && "$REQUIRE_DEVICE_READY" != "1" ]]; then
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
fi
# Use build_sr_cmd to construct the initial SR_CMD so the respawn path and the
# startup path share a single source of truth for the flag combination. The
# initial mode is the operator's session-level METER_AVERAGING so it matches
# CURRENT_LOW_LIGHT_MODE (also METER_AVERAGING) -- a mismatch would mean the
# first per-read mode equals CURRENT and skips the respawn, leaving spotread
# running with the wrong -Y flag.
SR_CMD=$(build_sr_cmd "${METER_AVERAGING:-off}")
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
HANDLED_OFFSET=0
STARTUP_HINT=""
# Spectros such as the i1 Pro 2 need a multi-step interactive bring-up (place on
# the white calibration tile, keypress; then aim at the screen, keypress) before
# they reach the "to take a reading:" prompt. Colorimeters (i1d3) report ready
# immediately. Surface every interactive prompt through the device-ready UI and
# only inject the keypress once the operator resumes, so nobody is left guessing
# and we never blindly drive the meter mid-air. WAITED gates spotread
# responsiveness only (it is reset after each handled step); operator think-time
# is unbounded because wait_for_device_ready blocks without advancing it.
while (( WAITED < 900 )); do
 CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 echo "$CLEAN_OUT" | grep -q "to take a reading:" && break
 NEW_OUT=$(clean_output_since "$HANDLED_OFFSET")
 if (( REFRESH_CAL_DONE == 0 )) && echo "$NEW_OUT" | grep -qi "calibrate refresh"; then
  log "performing refresh-rate calibration during startup"
  post_patch_timeout 204 204 204 100 "$SIGNAL_MODE_DEFAULT" "$MAX_LUMA_DEFAULT" ""
  sleep 2
  printf " " >&3
  REFRESH_CAL_DONE=1
  HANDLED_OFFSET=$(output_size)
  sleep 2
  WAITED=0
  continue
 fi
 if echo "$NEW_OUT" | grep -qiE 'reading is too low|calibration failed'; then
  log "calibration failed during startup, surfacing retry"
  STARTUP_HINT="interactive_setup"
  await_setup_step "calibrate_retry" "Calibration failed. Re-seat the spectro flat on its white tile, then click Retry." "Re-calibrating the meter - please wait..."
  printf " " >&3
  HANDLED_OFFSET=$(output_size)
  WAITED=0
  continue
 fi
 if manual_calibration_setup_prompt "$NEW_OUT"; then
  log "calibrate_tile prompt during startup"
  startup_marker "calibrate_tile prompt seen"
  STARTUP_HINT="interactive_setup"
  await_setup_step "calibrate_tile" "Place the spectrophotometer flat on its white calibration tile, then click Calibrate." "Calibrating the meter on its tile - please wait a few seconds..."
  printf " " >&3
  HANDLED_OFFSET=$(output_size)
  WAITED=0
  continue
 fi
 if echo "$NEW_OUT" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected"; then
  STARTUP_HINT="communications_failure"
  break
 fi
 sleep 0.1
 WAITED=$((WAITED + 1))
done
if ! sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -q "to take a reading:"; then
 FAIL_CONTEXT=$(startup_output_excerpt)
 if [[ "$STARTUP_HINT" == "interactive_setup" ]]; then
  log "spotread init failed after interactive setup${FAIL_CONTEXT:+: $FAIL_CONTEXT}"
  write_state '{"status":"error","message":"Meter setup did not complete. Re-seat the spectro on its tile, then aim at the screen, and try the read again."}'
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

# Spectros are on the calibration tile after init; have the operator aim at the
# screen ONCE before reads begin. Colorimeters (REQUIRE_DEVICE_READY=0) skip this.
if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
 await_setup_step "position_screen" "Aim the meter at where the test patches appear on the screen, then click Ready."
fi

signal_startup_ready
startup_marker "startup ready signaled"
log "command loop ready"

LAST_R="" LAST_G="" LAST_B="" LAST_PSIZE="" LAST_SIGNAL_MODE="" LAST_MAX_LUMA="" LAST_SIGNAL_RANGE="" LAST_TRANSPORT_SIGNAL_RANGE="" LAST_INPUT_MAX=""

# --- Main command loop ---
while read -t "$IDLE_TIMEOUT" -u 4 line; do
 case "$line" in
  READ\ *)
	    # Parse: READ R G B PSIZE IRE NAME [SETTLE_MS] [SIGNAL_MODE] [MAX_LUMA] [PATTERN_SIGNAL_RANGE] [TRANSPORT_SIGNAL_RANGE] [REQUEST_ID] [INPUT_MAX] [READ_TIMEOUT] [LOW_LIGHT_MODE]
	    # LOW_LIGHT_MODE (15th, optional) is the PER-READ handler mode. When
	    # it differs from the currently-running spotread's mode the session
	    # respawns spotread (NOT the wrapper) so the session-level
	    # METER_AVERAGING (and the want_config 7th field) stay stable.
	    read -r _ R G B PSIZE IRE NAME SETTLE_MS SIGNAL_MODE MAX_LUMA SIGNAL_RANGE TRANSPORT_SIGNAL_RANGE REQUEST_ID INPUT_MAX CMD_READ_TIMEOUT CMD_LOW_LIGHT_MODE <<< "$line"
   [[ -z "$PSIZE" ]] && PSIZE=10
   [[ -z "$IRE" ]] && IRE=0
   [[ -z "$NAME" ]] && NAME="manual"
   [[ -z "$SETTLE_MS" ]] && SETTLE_MS=0
   [[ -z "$SIGNAL_MODE" ]] && SIGNAL_MODE="$SIGNAL_MODE_DEFAULT"
   [[ -z "$MAX_LUMA" ]] && MAX_LUMA="$MAX_LUMA_DEFAULT"
	     [[ -z "$SIGNAL_RANGE" ]] && SIGNAL_RANGE=""
		     [[ -z "$TRANSPORT_SIGNAL_RANGE" ]] && TRANSPORT_SIGNAL_RANGE=""
		     [[ -z "$REQUEST_ID" ]] && REQUEST_ID=""
		     [[ -z "$INPUT_MAX" ]] && INPUT_MAX=255
		     [[ -z "$CMD_READ_TIMEOUT" ]] && CMD_READ_TIMEOUT=""
		     [[ -z "$CMD_LOW_LIGHT_MODE" ]] && CMD_LOW_LIGHT_MODE="off"
		     [[ "$SIGNAL_RANGE" == "-" ]] && SIGNAL_RANGE=""
		     [[ "$TRANSPORT_SIGNAL_RANGE" == "-" ]] && TRANSPORT_SIGNAL_RANGE=""
		     [[ "$INPUT_MAX" == "-" ]] && INPUT_MAX=255
		     [[ "$CMD_READ_TIMEOUT" == "-" ]] && CMD_READ_TIMEOUT=""
		     [[ "$CMD_LOW_LIGHT_MODE" == "-" ]] && CMD_LOW_LIGHT_MODE="off"

	   # If the per-read low_light mode differs from the currently-running
	   # spotread's, respawn ONLY spotread (1-3s) instead of the wrapper
	   # (35-90s on OLED). The wrapper's command FIFO, PID, config, and
	   # state files are untouched, so the WebUI does not see a session
	   # restart and the session config stays stable across reads.
	   if [[ "$CMD_LOW_LIGHT_MODE" != "$CURRENT_LOW_LIGHT_MODE" ]]; then
	    if ! respawn_spotread "$CMD_LOW_LIGHT_MODE"; then
	     # Respawn surfaced an error to the state file; skip this read.
	     continue
	    fi
	   fi

	   # Mark measuring so the polling endpoint knows a read is in flight.
	   write_state "{\"status\":\"measuring\",\"request_id\":\"$REQUEST_ID\"}"

  # Re-display when the rendered patch changes, including transport fields
  # like signal mode and mastering peak that affect how the same RGB codes map.
	  if [[ "$R" != "$LAST_R" || "$G" != "$LAST_G" || "$B" != "$LAST_B" || "$PSIZE" != "$LAST_PSIZE" || "$SIGNAL_MODE" != "$LAST_SIGNAL_MODE" || "$MAX_LUMA" != "$LAST_MAX_LUMA" || "$SIGNAL_RANGE" != "$LAST_SIGNAL_RANGE" || "$TRANSPORT_SIGNAL_RANGE" != "$LAST_TRANSPORT_SIGNAL_RANGE" || "$INPUT_MAX" != "$LAST_INPUT_MAX" ]]; then
	   post_patch "$R" "$G" "$B" "$PSIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	   LAST_R="$R"; LAST_G="$G"; LAST_B="$B"; LAST_PSIZE="$PSIZE"; LAST_SIGNAL_MODE="$SIGNAL_MODE"; LAST_MAX_LUMA="$MAX_LUMA"; LAST_SIGNAL_RANGE="$SIGNAL_RANGE"; LAST_TRANSPORT_SIGNAL_RANGE="$TRANSPORT_SIGNAL_RANGE"; LAST_INPUT_MAX="$INPUT_MAX"
	   fi

  if (( SETTLE_MS > 0 )); then
   SETTLE_SEC=$(awk "BEGIN{printf \"%.3f\", $SETTLE_MS/1000.0}")
   sleep "$SETTLE_SEC"
  fi

   # Absolute black on emissive displays (OLED/QD-OLED/CRT/plasma) often
   # returns no measurable response. Report a valid 0.0 reading immediately.
	   if [[ "$DISPLAY_TYPE" == "c" && "$R" == "$G" && "$G" == "$B" ]] && ire_le "$IRE" 0; then
    TS=$(date +%s)
	    write_state "{\"status\":\"complete\",\"request_id\":\"$REQUEST_ID\",\"readings\":[{\"X\":0,\"Y\":0,\"Z\":0,\"x\":0,\"y\":0,\"luminance\":0.0,\"cct\":0,\"timestamp\":$TS,\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B,\"request_id\":\"$REQUEST_ID\"}],\"count\":1}"
    continue
   fi

   # Trigger reading and wait for it
   PARSED_RESULT=""
   READ_OUTPUT=""
   # Positioning is now a one-time post-init setup step (position_screen), so the
   # spectro is already aimed at the screen; reads auto-fire without a per-read
   # prompt.
   SCAN_OFFSET=$(output_size)
   printf " " >&3
	  READ_TIMEOUT=90
	  ire_le "$IRE" 25 && READ_TIMEOUT=120
	  ire_le "$IRE" 5 && READ_TIMEOUT=140
	  if [[ "$CMD_READ_TIMEOUT" =~ ^[0-9]+$ ]] && (( CMD_READ_TIMEOUT >= 10 )); then
	   READ_TIMEOUT="$CMD_READ_TIMEOUT"
	   (( READ_TIMEOUT > 300 )) && READ_TIMEOUT=300
	  fi
   READ_START=$SECONDS
   GOT_RESULT=false
   RETRIED_COMM=0
   while (( SECONDS - READ_START < READ_TIMEOUT )); do
      NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
      if [[ -n "$NEW_OUTPUT" ]]; then
       CUR_SIZE=$(output_size)
       READ_OUTPUT+="$NEW_OUTPUT"
       if [[ $RETRIED_COMM -eq 0 && "$READ_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
        log "spotread communication problem during read - retrying once"
        printf " " >&3
        RETRIED_COMM=1
        READ_TIMEOUT=$((READ_TIMEOUT + 30))
        READ_OUTPUT=""
        SCAN_OFFSET=$(output_size)
        continue
       fi
       # Result first: once spotread returns a reading we're done. spotread
       # reprints its normal "Place instrument on spot ... to take a reading"
       # prompt after every read; that is NOT an operator step and must not be
       # mistaken for one (doing so caused an endless re-prompt loop).
       if [[ "$READ_OUTPUT" == *"Result is XYZ:"* ]]; then
        PARSED_RESULT=$(parse_latest_result_text "$READ_OUTPUT")
        if [[ -n "$PARSED_RESULT" ]]; then
         GOT_RESULT=true
         break
        fi
       fi
       if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
        # Only surface a genuine re-calibration (white tile) or reposition
        # prompt -- never the normal ready-to-read prompt.
        PROMPT_REASON=""
        if manual_calibration_setup_prompt "$READ_OUTPUT"; then
         PROMPT_REASON="calibration_setup"
        elif printf '%s' "$READ_OUTPUT" | grep -qiE 'incorrect position|meter is in incorrect position'; then
         PROMPT_REASON="incorrect_position"
        fi
        if [[ -n "$PROMPT_REASON" ]]; then
         log "manual prompt during read: reason=$PROMPT_REASON name=$NAME"
         wait_for_device_ready "$PROMPT_REASON"
         printf " " >&3
         READ_START=$SECONDS
         READ_TIMEOUT=$((READ_TIMEOUT + 30))
         READ_OUTPUT=""
         SCAN_OFFSET=$(output_size)
         continue
        fi
       fi
       SCAN_OFFSET="$CUR_SIZE"
    fi
    sleep 0.1
   done

   if $GOT_RESULT; then
	    PARSED="$PARSED_RESULT"
	    if [[ -n "$PARSED" ]]; then
	     # Wrap as a complete reading record (matches spotread_wrapper.sh shape).
	     # Pass parsed JSON via environment variables so Python 2 shells on older
	     # Pi images do not choke on inline quoting.
	     OUT=$(PARSED_JSON="$PARSED" READ_IRE="$IRE" READ_NAME="$NAME" READ_R="$R" READ_G="$G" READ_B="$B" READ_REQUEST_ID="$REQUEST_ID" python -c "
import json, os
r=json.loads(os.environ.get('PARSED_JSON','{}'))
try:
 ire=float(os.environ.get('READ_IRE','0'))
 if abs(ire-int(ire)) < 0.000001:
  ire=int(ire)
except Exception:
 ire=0
r['ire']=ire
r['name']=os.environ.get('READ_NAME','manual')
r['r_code']=int(os.environ.get('READ_R','0') or 0)
r['g_code']=int(os.environ.get('READ_G','0') or 0)
r['b_code']=int(os.environ.get('READ_B','0') or 0)
r['request_id']=os.environ.get('READ_REQUEST_ID','')
print(json.dumps({'status':'complete','request_id':os.environ.get('READ_REQUEST_ID',''),'readings':[r],'count':1}))
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

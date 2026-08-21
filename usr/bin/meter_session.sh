#!/bin/bash
# meter_session.sh - Long-lived spotread session for Read Once / Continuous reads.
#
# Spotread cold-start is a 3-8 s USB handshake (plus a refresh-rate calibration
# cycle on OLED/CRT). This script pays that cost once, then every read is just
# "send space, parse result". meter_series.sh uses the same pattern across a
# patch series; this is the per-patch equivalent for ad-hoc reads.
#
# Usage:
#   meter_session.sh <display_type> <ccss_file> <refresh_rate> <disable_aio> [signal_mode] [max_luma] [meter_port] [idle_timeout] [require_device_ready] [averaging] [meter_usb_id] [observer] [pattern_provider]
#
# Commands (one per line, written to /tmp/meter_session.cmd):
#   READ <r> <g> <b> <patch_size> <ire> <name> [settle_ms] [signal_mode] [max_luma] [pattern_signal_range] [transport_signal_range] [request_id] [input_max] [read_timeout] [low_light_mode] [continuous]
#   STOP
#
# settle_ms (optional, default 0) is the post-display settle wait applied
# before every read so manual Read Once and Continuous honor the UI value even
# when the patch itself has not changed.
#
# Writes results to /tmp/meter_read.json after each READ so the existing
# /api/meter/read/result polling endpoint keeps working unchanged.

set -o pipefail

# Add the legacy SpectraCal C6 unlock key as an ArgyllCMS i1Display3 fallback.
# Built-in i1D3 keys remain first in Argyll's key list; other meter drivers
# never consume this variable.
I1D3_ESCAPE="${I1D3_ESCAPE:-c9bfafe002871166}"
export I1D3_ESCAPE

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
# USB vid:pid of the operator-selected meter. When set, find_port resolves the
# spotread -c index from THIS device instead of trusting the requested index,
# which goes stale whenever meters are plugged/unplugged (enumeration order).
METER_USB_ID="${11:-}"
OBSERVER="${12:-1931_2}"
case "$OBSERVER" in
 1931_2|1964_10|2015_2|2015_10) ;;
 *) OBSERVER="1931_2" ;;
esac
export OBSERVER
PATTERN_PROVIDER="${13:-local}"
[[ "$PATTERN_PROVIDER" == "companion" ]] || PATTERN_PROVIDER="local"

# SpyderX supports its built-in display calibrations and device-specific CCMX
# matrices. It does not expose CCSS spectral-sample or manual refresh-override
# capability. Preserve a selected CCMX but reject CCSS in direct/helper calls.
if [[ "${METER_USB_ID,,}" == "085c:0a00" ]]; then
 [[ "${CCSS_FILE,,}" =~ \.ccmx$ ]] || CCSS_FILE=""
 REFRESH_RATE=""
fi

SPECTRO_MARKER_ID=$(printf '%s' "${METER_USB_ID:-unknown}" | tr -cd 'A-Za-z0-9')
[[ -n "$SPECTRO_MARKER_ID" ]] || SPECTRO_MARKER_ID="unknown"
SPECTRO_STARTUP_MARKER="/tmp/pg_spectro_startup_checked_${SPECTRO_MARKER_ID}"
# SpyderX/Spyder5 perform a manual dark calibration with the sensor covered.
# Their first process after boot must run without -N so Argyll can request it.
# Once that startup succeeds, later spotread processes use -N to reuse the
# checked calibration instead of prompting before every read operation.
NOINITCAL_FLAG=""
case "${METER_USB_ID,,}" in
 085c:0a00|085c:0500)
  [[ -f "$SPECTRO_STARTUP_MARKER" ]] && NOINITCAL_FLAG="-N"
  ;;
esac

SPOTREAD_BIN="/usr/bin/spotread"
# Simulated meter (WebUI port 99): swap in the spotread-protocol simulator.
# It enumerates itself as port 99 via -?, so find_port resolves it without
# any USB device present. No CCSS/refresh/USB identity applies to it.
METER_SIMULATED=0
if [[ "$METER_PORT" == "99" ]]; then
 METER_SIMULATED=1
 SPOTREAD_BIN="/usr/bin/spotread_sim"
 METER_USB_ID=""
 CCSS_FILE=""
 REFRESH_RATE=""
fi
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
COMPANION_COMMAND_FILE="/var/lib/PGenerator/icc-companion/command.json"
COMPANION_ACK_FILE="/tmp/pgen_icc_companion.ack.json"
COMPANION_SEQUENCE=0
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

# spotread's refresh-rate calibration step. Two DIFFERENT strings are involved
# and only one of them is a prompt:
#   diagnostic: "Please read an 80% white patch first to calibrate refresh frequency"
#   prompt:     "Place the instrument on a 80% white test patch,"
#               "and hit [Return] to start calibration:"
# Matching only "calibrate refresh" catches the diagnostic and misses the
# prompt, which then goes unanswered until the startup loop times out.
# An explicit -Y R:rate makes spotread skip this step on meters that support
# refresh-rate calibration. A meter left on automatic refresh can otherwise
# wait at this prompt until the startup loop times out.
refresh_cal_prompt() {
 printf '%s' "$1" | grep -qiE 'calibrate[[:space:]]+refresh|refresh[[:space:]]+frequency|80%[[:space:]]*(or[[:space:]]+greater[[:space:]]+)?white[[:space:]]+test[[:space:]]+patch'
}

# A genuine "cover the sensor" dark calibration. Unlike the generic
# "needs calibration" text this one names a real operator action, so it is
# safe to surface for a colorimeter too -- answering it blind with the meter
# aimed at a lit screen captures screen light as the black reference, which
# is what zeroes every low-grey reading afterwards.
colorimeter_dark_cal_prompt() {
 [[ "${REQUIRE_DEVICE_READY:-0}" == "1" ]] && return 1
 printf '%s' "$1" | grep -qiE 'place cap on the instrument|place on a dark surface'
}

manual_calibration_setup_prompt() {
 local normalized
 normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
 # Spectrophotometer white-tile wavelength cal only. Colorimeters (SpyderX,
 # i1Display, Spyder5, ...) never use a white tile -- matching their refresh
 # "80% white test patch" or generic "needs calibration" text used to pop the
 # spectro wizard and force an operator click-through that does nothing useful.
 [[ "${REQUIRE_DEVICE_READY:-0}" == "1" ]] || return 1
 # SpyderX is always a colorimeter; belt-and-braces if ready_gate was mis-set.
 [[ "${METER_USB_ID,,}" == "085c:0a00" || "${METER_USB_ID,,}" == "085c:0500" ]] && return 1
 # Refresh-rate white-patch prompts are handled by the refresh-cal path, not
 # the spectro white-tile wizard.
 if printf '%s' "$normalized" | grep -qiE 'calibrate[[:space:]]+refresh|refresh[[:space:]]+(rate|frequency)|80%[[:space:]]+or[[:space:]]+greater'; then
  return 1
 fi
 printf '%s' "$normalized" | grep -qiE 'white[[:space:]-]+reference|calibration[[:space:]-]+tile|place cap|dark surface|needs[[:space:]]+a[[:space:]]+calibration|spot read needs a calibration|calibration retry with correct setup'
}

manual_initial_measurement_prompt() {
 local normalized
 normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
 printf '%s' "$normalized" | grep -qiE 'place .*instrument|place .*meter|position .*instrument|position .*meter'
}

manual_ready_prompt_reason() {
 local clean_out="$1"
 # The Device Ready wizard must ONLY surface a genuine spotread calibration
 # request (white-tile / "needs calibration"). Other spotread lines -- the
 # normal "Place instrument on spot to be measured" per-reading prompt,
 # "incorrect position", refresh-rate prompts, etc. -- are NOT operator-action
 # calibration prompts and must not pop the wizard mid-read (a "place
 # .*instrument" race on the normal prompt previously fired a spurious wizard
 # that skipped the white-tile step). Applies to all read types (continuous).
 if manual_calibration_setup_prompt "$clean_out"; then
  echo "calibration_setup"
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

# Complete a colorimeter dark calibration requested after startup. The caller
# has already observed spotread's dark-calibration prompt. This function
# performs the covered-sensor step, waits for the normal read prompt, and asks
# the operator to aim the meter back at the display. The caller owns the final
# key that resumes the interrupted read.
perform_colorimeter_dark_calibration() {
 local context="${1:-read}"
 local cal_offset waited clean
 log "colorimeter dark-calibration prompt during $context"
 await_setup_step "calibrate_dark" "Cover the meter's sensor (or lay it face-down on a dark surface), then click Calibrate." "Calibrating the meter's black reference - please wait..."
 cal_offset=$(output_size)
 printf " " >&3
 waited=0
 while (( waited < 300 )); do
  clean=$(clean_output_since "$cal_offset")
  if printf '%s' "$clean" | grep -q "to take a reading:"; then
   await_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
   return 0
  fi
  if printf '%s' "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected|calibration failed"; then
   log "dark calibration failed during $context: $(printf '%s' "$clean" | tr '\n' ' ' | cut -c1-300)"
   return 1
  fi
  sleep 0.1
  waited=$((waited + 1))
 done
 log "dark calibration did not return to the read prompt during $context"
 return 1
}

perform_spectro_white_calibration() {
 local context="${1:-read}"
 local cal_offset waited clean
 log "spectrophotometer white-tile calibration prompt during $context"
 await_setup_step "calibrate_tile" "Place the spectrophotometer flat on its white calibration tile, then click Calibrate." "Calibrating the meter on its tile - please wait a few seconds..."
 cal_offset=$(output_size)
 printf " " >&3
 waited=0
 while (( waited < 900 )); do
  clean=$(clean_output_since "$cal_offset")
  if printf '%s' "$clean" | grep -q "to take a reading:"; then
   await_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
   return 0
  fi
  if printf '%s' "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected|calibration failed|reading is too low"; then
   log "spectrophotometer calibration failed during $context: $(printf '%s' "$clean" | tr '\n' ' ' | cut -c1-300)"
   return 1
  fi
  sleep 0.1
  waited=$((waited + 1))
 done
 log "spectrophotometer calibration did not return to the read prompt during $context"
 return 1
}

# Run an operator-requested ArgyllCMS instrument calibration inside the
# existing spotread process. The interactive 'k' command asks the selected
# instrument what calibration it needs, so spectros get their white-tile
# workflow while Spyder colorimeters get their covered-sensor dark reference.
# Keeping this in the persistent session preserves the new calibration for
# subsequent Read Once, Continuous, and Read Series operations.
perform_requested_calibration() {
 local scan_offset waited clean prompted
 log "manual meter calibration requested"
 scan_offset=$(output_size)
 write_state '{"status":"measuring","setup_busy":true,"message":"Checking the meter calibration requirements..."}'
 printf "k" >&3
 waited=0
 prompted=0
 while (( waited < 900 )); do
  clean=$(clean_output_since "$scan_offset")
  if colorimeter_dark_cal_prompt "$clean"; then
   if perform_colorimeter_dark_calibration "manual request"; then
    write_state '{"status":"ok","message":"Meter calibration complete"}'
    return 0
   fi
   write_state '{"status":"error","message":"Meter dark calibration did not complete"}'
   return 1
  fi
  if manual_calibration_setup_prompt "$clean"; then
   prompted=1
   await_setup_step "calibrate_tile" "Place the spectrophotometer flat on its white calibration tile, then click Calibrate." "Calibrating the meter on its tile - please wait a few seconds..."
   scan_offset=$(output_size)
   printf " " >&3
   waited=0
   continue
  fi
  if printf '%s' "$clean" | grep -q "to take a reading:"; then
   if (( prompted == 1 )); then
    await_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
   fi
   write_state '{"status":"ok","message":"Meter calibration complete"}'
   return 0
  fi
  if printf '%s' "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected|calibration failed|fatal error"; then
   log "manual calibration failed: $(printf '%s' "$clean" | tr '\n' ' ' | cut -c1-300)"
   write_state '{"status":"error","message":"Meter calibration failed"}'
   return 1
  fi
  sleep 0.1
  waited=$((waited + 1))
 done
 log "manual calibration timed out"
 write_state '{"status":"error","message":"Meter calibration timed out"}'
 return 1
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
 if [[ "$PATTERN_PROVIDER" == "companion" ]]; then
  post_companion_patch "$@"
  return $?
 fi
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9")" >/dev/null 2>&1
}

post_patch_timeout() {
 if [[ "$PATTERN_PROVIDER" == "companion" ]]; then
  post_companion_patch "$@"
  return $?
 fi
 timeout 5 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9")" >/dev/null 2>&1 || true
}

post_companion_patch() {
 local r="$1" g="$2" b="$3" size="$4" signal_mode="$5" max_luma="$6" signal_range="$7" input_max="${9:-255}"
 local code_min=0 code_max scale sequence payload tmp deadline ack ack_sequence ack_status ack_message
 [[ -z "$input_max" || "$input_max" == "-" ]] && input_max=255
 code_max="$input_max"
 if [[ "$signal_range" == "1" ]]; then
  case "$input_max" in 1023) scale=4 ;; 4095) scale=16 ;; *) scale=1 ;; esac
  code_min=$((16 * scale)); code_max=$((235 * scale))
 fi
 sequence=$(date +%s%3N)
 (( sequence <= COMPANION_SEQUENCE )) && sequence=$((COMPANION_SEQUENCE + 1))
 COMPANION_SEQUENCE=$sequence
 payload="{\"status\":\"patch\",\"sequence\":$sequence,\"r\":$r,\"g\":$g,\"b\":$b,\"size\":$size,\"input_max\":$input_max,\"code_min\":$code_min,\"code_max\":$code_max,\"signal_mode\":\"$signal_mode\",\"max_luma\":$max_luma}"
 tmp="${COMPANION_COMMAND_FILE}.$$.$sequence.tmp"
 printf '%s' "$payload" > "$tmp" || { write_state '{"status":"error","message":"Could not send a patch to PGenerator+ Patch Companion"}'; return 1; }
 chmod 644 "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$COMPANION_COMMAND_FILE" || { write_state '{"status":"error","message":"Could not send a patch to PGenerator+ Patch Companion"}'; return 1; }
 # Windows can briefly pause the Companion while changing HDR or fullscreen
 # swapchains. Keep the patch pending long enough for polling to resume rather
 # than aborting an otherwise valid measurement run after ten seconds.
 deadline=$((SECONDS + 30))
 while (( SECONDS < deadline )); do
  if [[ -f "$COMPANION_ACK_FILE" ]]; then
   ack=$(cat "$COMPANION_ACK_FILE" 2>/dev/null || true)
   ack_sequence=$(printf '%s' "$ack" | sed -n 's/.*"sequence"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
   if [[ "$ack_sequence" == "$sequence" ]]; then
    ack_status=$(printf '%s' "$ack" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ "$ack_status" == "ok" ]] && return 0
    ack_message=$(printf '%s' "$ack" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    write_state "{\"status\":\"error\",\"message\":\"${ack_message:-PGenerator+ Patch Companion could not render the requested patch}\"}"
    return 1
   fi
  fi
  sleep 0.05
 done
 write_state '{"status":"error","message":"PGenerator+ Patch Companion did not acknowledge the patch"}'
 return 1
}

companion_show_alignment() {
 [[ "$PATTERN_PROVIDER" == "companion" ]] || return 0
 local sequence tmp
 sequence=$(date +%s%3N)
 (( sequence <= COMPANION_SEQUENCE )) && sequence=$((COMPANION_SEQUENCE + 1))
 COMPANION_SEQUENCE=$sequence
 tmp="${COMPANION_COMMAND_FILE}.$$.$sequence.tmp"
 printf '{"status":"align","sequence":%s}' "$sequence" > "$tmp" 2>/dev/null || return 0
 chmod 644 "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$COMPANION_COMMAND_FILE" 2>/dev/null || true
}

# Single-instance lock — refuse to start if another session is alive.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
 log "another session already holds the lock, exiting"
 exit 0
fi
echo $$ > "$PID_FILE"
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$DISPLAY_TYPE" "$CCSS_FILE" "$REFRESH_RATE" "$DISABLE_AIO" "$METER_PORT" "$REQUIRE_DEVICE_READY" "${METER_AVERAGING:-off}" "$METER_USB_ID" "$OBSERVER" "$PATTERN_PROVIDER" > "$CONFIG_FILE"
log "session $$ starting (display=$DISPLAY_TYPE ccss=$CCSS_FILE refresh=$REFRESH_RATE aio_off=$DISABLE_AIO port=$METER_PORT usb_id=$METER_USB_ID observer=$OBSERVER provider=$PATTERN_PROVIDER ready_gate=$REQUIRE_DEVICE_READY averaging=${METER_AVERAGING:-off} idle=${IDLE_TIMEOUT}s)"
startup_marker "pid/config written"

# --- spotread bring-up (mirrors meter_series.sh) ---

find_port() {
 local requested_port="$1"
 local requested_usb_id="$2"
 local cache="/tmp/spotread_port_cache"
 # Simulated meter: fixed virtual port; never touch the USB port cache.
 if (( METER_SIMULATED )); then
  echo "99"
  return
 fi
 local help_out
 help_out=$(timeout 5 "$SPOTREAD_BIN" -? 2>&1 || true)
 # Resolve by USB vid:pid first: the spotread -c index is enumeration order
 # and shifts when meters come and go, so a remembered index can silently
 # land on the WRONG meter. The vid:pid identifies the physical device.
 if [[ -n "$requested_usb_id" ]]; then
  local lsusb_out
  lsusb_out=$(lsusb 2>/dev/null)
  local _line _pnum _bus _dev
  while IFS= read -r _line; do
   if [[ "$_line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*=[[:space:]]*\'/dev/bus/usb/([0-9]+)/([0-9]+) ]]; then
    _pnum="${BASH_REMATCH[1]}"; _bus="${BASH_REMATCH[2]}"; _dev="${BASH_REMATCH[3]}"
    if printf '%s\n' "$lsusb_out" | grep -qiE "^Bus[[:space:]]+${_bus}[[:space:]]+Device[[:space:]]+${_dev}:[[:space:]]+ID[[:space:]]+${requested_usb_id}\b"; then
     echo "$_pnum" > "$cache"
     sleep 2
     echo "$_pnum"
     return
    fi
   fi
  done <<< "$help_out"
 fi
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

# --- Null-read guard -------------------------------------------------------
# A meter that has drifted off the patch, gone to sleep, or lost its USB
# interface can still answer a read "successfully" with an all-zero
# measurement: X=Y=Z=0. Chromaticity is derived from XYZ, so x and y then come
# back pinned at 1/3 (printed as 0.333333 here, rounded to 0.3333 once the API
# has serialised it). Nothing downstream of this script rejected that, so a
# plainly lit patch entered a calibration, a profile or a chart as if it were
# black.
#
# This is the lowest common point for the whole /api/meter/read family: the
# browser's Read Once / Continuous, meter_lg_autocal.pl, meter_lg_3d_autocal.pl
# and meter_lg_dv_profile.pl all POST /api/meter/read, which lands on the READ
# command below. It is also the only layer that both knows the REQUESTED patch
# and can issue a genuinely new measurement (another " " down spotread's stdin)
# rather than re-reading the same completed result. (meter_series.sh runs its
# own spotread pipeline and carries the sibling guard nonblack_zero_reading.)
#
# The numeric signature is deliberately identical to the two proven Perl
# implementations (invalid_low_shadow_reading / invalid_null_reading),
# INCLUDING the 0.0002 chromaticity window: the API hands back rounded JSON, so
# a real null read arrives as 0.3333 -- 3.3e-5 from 1/3 -- and any tighter
# window would never fire.
NULL_READ_RETRIES=2

# Does the REQUESTED patch actually drive light?
#
# This is the half that must not be got wrong. A 0% black patch on an emissive
# panel legitimately measures X=Y=Z=0 and its chromaticity legitimately
# degenerates to 1/3,1/3, so rejecting the reading alone would make every black
# read retry until it failed. The gate therefore keys off the patch that was
# asked for, never off the reading.
#
# Two things make it awkward:
#   * Colour patches (ColorChecker, saturation sweeps) arrive with ire=0 while
#     driving real colour, so an IRE-only gate would exempt all of them.
#   * A limited-range black is NOT code 0: it is 16 at 8-bit and 64 at 10-bit,
#     so an r=g=b=0 gate would treat a limited black as lit.
# So: light is driven when the IRE says so, or when any channel sits above the
# black floor for the patch's code scale. The floor is derived from input_max
# (16/255 of full scale) and is applied whether or not the caller told us the
# signal range -- for full range that only exempts codes 1..16, which are
# deep-shadow greys that carry a non-zero IRE anyway. Erring toward "this is
# black" is the safe direction: it can only ever mean a null read slips through
# on a near-black patch, never that a legitimate black is thrown away.
patch_drives_light() {
 local r="${1:-0}" g="${2:-0}" b="${3:-0}" ire="${4:-0}" input_max="${5:-255}"
 awk -v ire="$ire" 'BEGIN{ exit !((ire+0) > 0) }' && return 0
 awk -v r="$r" -v g="$g" -v b="$b" -v m="$input_max" '
  BEGIN {
   m = m + 0
   if (m <= 0) m = 255
   # Digital video code scales are based on the number of representable
   # values, not the largest code. This produces exact limited black at every
   # supported depth: 16/255, 64/1023 and 256/4095.
   black_floor = int(16.0 * (m + 1.0) / 256.0 + 0.5)
   hi = r + 0
   if (g + 0 > hi) hi = g + 0
   if (b + 0 > hi) hi = b + 0
   exit !(hi > black_floor)
  }'
}

# Returns 0 (shell true) when a reading the meter reported as successful is in
# fact an unusable null read.
null_meter_reading() {
 local reading="$1"
 local Y lum x_chr y_chr
 Y=$(printf '%s' "$reading" | sed -n 's/.*"Y":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 lum=$(printf '%s' "$reading" | sed -n 's/.*"luminance":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 x_chr=$(printf '%s' "$reading" | sed -n 's/.*"x":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 y_chr=$(printf '%s' "$reading" | sed -n 's/.*"y":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 awk -v Y="$Y" -v lum="$lum" -v x="$x_chr" -v y="$y_chr" '
  function abs(v) { return v < 0 ? -v : v }
  BEGIN {
   v = (lum != "" ? lum : Y)
   if (v == "") exit 1
   if (v + 0 <= 0) exit 0
   if (x == "" || y == "") exit 1
   if (v + 0 < 0.5 && abs(x + 0 - 0.333333) < 0.0002 && abs(y + 0 - 0.333333) < 0.0002) exit 0
   exit 1
  }'
}

cleanup() {
 log "cleanup: tearing down spotread"
 companion_show_alignment
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
  pkill -TERM -x spotread_sim 2>/dev/null
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
 pgrep -x spotread_sim >/dev/null 2>&1 && pkill -9 -x spotread_sim 2>/dev/null
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
  # Spectrophotometers (REQUIRE_DEVICE_READY=1) get neither -X (CCSS is a
  # colorimeter correction) nor -y (display type selection is a colorimeter
  # concept; spotread emits "Display/calibration type ignored" for a spectro).
   local cmd
   if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
    # The first spectro process after boot runs without -N so Argyll performs
    # its calibration check before any measurement. Later session respawns and
    # series launches reuse that checked calibration with -N.
    local spectro_noinit=""
    [[ -f "$SPECTRO_STARTUP_MARKER" ]] && spectro_noinit="-N"
    cmd="$SPOTREAD_BIN $spectro_noinit -e -c $PORT_NUM -Q $OBSERVER -x $new_ll_flags"
   elif [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" ]]; then
   cmd="$SPOTREAD_BIN $NOINITCAL_FLAG -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -Q $OBSERVER -x $new_ll_flags"
  else
   cmd="$SPOTREAD_BIN $NOINITCAL_FLAG -e -y $DISPLAY_TYPE -c $PORT_NUM -Q $OBSERVER -x $new_ll_flags"
  fi
  # -Y R:rate overrides spotread's measured refresh rate. Passing it makes
  # spotread SKIP its mandatory "read an 80% white patch to calibrate refresh
  # frequency" step -- on a sample-and-hold OLED that auto-cal read is
  # unreliable (it fails without averaging, leaving the meter uncalibrated so
  # every subsequent read fails). So always honour an explicit rate on meters
  # that support the override.
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
 local respawn_reason="${2:-low-light mode change}"
 log "respawn: restarting spotread for $respawn_reason with low_light mode=$new_mode (was $CURRENT_LOW_LIGHT_MODE)"
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
  pkill -TERM -x spotread_sim 2>/dev/null
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
 pgrep -x spotread_sim >/dev/null 2>&1 && pkill -9 -x spotread_sim 2>/dev/null
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
  local _rt=0 _refresh_done=0
  while (( _rt < 150 )); do
   local _co
   _co=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
   echo "$_co" | grep -q "to take a reading:" && break
   if (( _refresh_done == 0 )) && refresh_cal_prompt "$_co"; then
    log "performing refresh-rate calibration during low-light respawn"
    post_patch_timeout 204 204 204 100 "$SIGNAL_MODE_DEFAULT" "$MAX_LUMA_DEFAULT" ""
    sleep 2
    printf " " >&3
    _refresh_done=1
    sleep 2
    _rt=$((_rt + 40))
    continue
   fi
   if colorimeter_dark_cal_prompt "$_co"; then
    if ! perform_colorimeter_dark_calibration "low-light respawn"; then
     write_state '{"status":"error","message":"Meter dark calibration did not complete"}'
     return 1
    fi
    CURRENT_LOW_LIGHT_MODE="$new_mode"
    return 0
   fi
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
  pkill -TERM -x spotread_sim 2>/dev/null
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
 pgrep -x spotread_sim >/dev/null 2>&1 && pkill -9 -x spotread_sim 2>/dev/null
 done
 log "respawn: spotread failed to ready within 15s on both attempts after $respawn_reason, surfacing error"
 write_state '{"status":"error","message":"Meter respawn failed"}'
 return 1
}
trap cleanup EXIT INT TERM

PORT_NUM=""
for _try in 1 2 3; do
 PORT_NUM=$(find_port "$METER_PORT" "$METER_USB_ID")
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
if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" && "${CCSS_FILE,,}" =~ \.ccss$ && "$REQUIRE_DEVICE_READY" != "1" ]]; then
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
WHITE_REF_DONE=0
DARK_CAL_DONE=0
HANDLED_OFFSET=0
STARTUP_LOG_OFFSET=0
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
 # Echo new spotread output into the session log every ~5s. Without this an
 # unrecognised prompt is completely silent: the log shows "spotread spawned"
 # and then nothing until the teardown, with no record of what it asked for.
 if (( WAITED % 50 == 0 )); then
  _startup_new=$(clean_output_since "$STARTUP_LOG_OFFSET" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  if [[ -n "$_startup_new" ]]; then
   log "startup output: $_startup_new"
   STARTUP_LOG_OFFSET=$(output_size)
  fi
 fi
 if (( REFRESH_CAL_DONE == 0 )) && refresh_cal_prompt "$NEW_OUT"; then
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
 if colorimeter_dark_cal_prompt "$NEW_OUT"; then
  log "colorimeter dark-calibration prompt during startup"
  startup_marker "dark_cal prompt seen"
  DARK_CAL_DONE=1
  await_setup_step "calibrate_dark" "Cover the meter's sensor (or lay it face-down on a dark surface), then click Calibrate." "Calibrating the meter's black reference - please wait..."
  printf " " >&3
  HANDLED_OFFSET=$(output_size)
  WAITED=0
  continue
 fi
 if [[ "$REQUIRE_DEVICE_READY" == "1" ]] && echo "$NEW_OUT" | grep -qiE 'reading is too low|calibration failed'; then
  log "calibration failed during startup, surfacing retry"
  STARTUP_HINT="interactive_setup"
  WHITE_REF_DONE=1
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
  WHITE_REF_DONE=1
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
 if echo "$CLEAN_OUT" | grep -qiE "doesn't have|does not support|instrument doesn't support|Display/calibration type ignored|no suitable|not supported|Colorimeter Calibration Spectral Sample|usage:"; then
  STARTUP_HINT="unsupported_mode"
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
 elif [[ "$STARTUP_HINT" == "unsupported_mode" ]]; then
  log "spotread rejected the requested mode${FAIL_CONTEXT:+: $FAIL_CONTEXT}"
  write_state '{"status":"error","message":"Meter does not support requested mode"}'
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
if (( REFRESH_CAL_DONE == 0 )) && refresh_cal_prompt "$CLEAN_OUT"; then
 log "performing refresh-rate calibration"
 post_patch_timeout 204 204 204 100 "$SIGNAL_MODE_DEFAULT" "$MAX_LUMA_DEFAULT" ""
 sleep 2
 printf " " >&3
 sleep 2
fi

# Spectros only need to re-aim at the screen when a white-tile calibration
# actually happened this startup (the meter was on the tile). When no
# calibration was needed (cal reused via -N, meter never left the screen) skip
# this so no wizard appears -- the startup wait loop above already showed the
# "preparing" status and surfaced calibrate_tile only when spotread requested it.
if [[ ( "$REQUIRE_DEVICE_READY" == "1" && "$WHITE_REF_DONE" == "1" ) || "$DARK_CAL_DONE" == "1" ]]; then
 await_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
fi
if [[ "$REQUIRE_DEVICE_READY" == "1" || "${METER_USB_ID,,}" == "085c:0a00" || "${METER_USB_ID,,}" == "085c:0500" ]]; then
 touch "$SPECTRO_STARTUP_MARKER" 2>/dev/null || true
fi

signal_startup_ready
startup_marker "startup ready signaled"
log "command loop ready"

STARTUP_CALIBRATION_COMPLETED=0
if (( WHITE_REF_DONE == 1 || DARK_CAL_DONE == 1 )); then
 STARTUP_CALIBRATION_COMPLETED=1
fi

# --- Main command loop ---
while read -t "$IDLE_TIMEOUT" -u 4 line; do
 case "$line" in
  CALIBRATE)
   # A cold session can be forced through calibration before its command loop
   # starts. In that case the queued button request is already satisfied and
   # must not immediately ask the operator to calibrate a second time.
   if (( STARTUP_CALIBRATION_COMPLETED == 1 )); then
    STARTUP_CALIBRATION_COMPLETED=0
    write_state '{"status":"ok","message":"Meter calibration complete"}'
   else
    perform_requested_calibration || true
   fi
   ;;
  READ\ *)
	    STARTUP_CALIBRATION_COMPLETED=0
	    # Parse: READ R G B PSIZE IRE NAME [SETTLE_MS] [SIGNAL_MODE] [MAX_LUMA] [PATTERN_SIGNAL_RANGE] [TRANSPORT_SIGNAL_RANGE] [REQUEST_ID] [INPUT_MAX] [READ_TIMEOUT] [LOW_LIGHT_MODE] [CONTINUOUS]
	    # LOW_LIGHT_MODE (15th, optional) is the PER-READ handler mode. When
	    # it differs from the currently-running spotread's mode the session
	    # respawns spotread (NOT the wrapper) so the session-level
	    # METER_AVERAGING (and the want_config 7th field) stay stable.
	    read -r _ R G B PSIZE IRE NAME SETTLE_MS SIGNAL_MODE MAX_LUMA SIGNAL_RANGE TRANSPORT_SIGNAL_RANGE REQUEST_ID INPUT_MAX CMD_READ_TIMEOUT CMD_LOW_LIGHT_MODE CMD_CONTINUOUS <<< "$line"
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
		     [[ -z "$CMD_CONTINUOUS" ]] && CMD_CONTINUOUS="0"
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

  # Always re-display the requested measurement patch before a read. The
  # WebUI can replace it with the stabilization pattern after the previous
  # read, so this long-lived worker cannot safely infer the current display
  # from its last READ command. This also makes repeated reads of one patch
  # behave the same for the local renderer and Patch Companion.
	  if ! post_patch "$R" "$G" "$B" "$PSIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"; then
	   log "pattern provider failed for $NAME"
	   continue
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
	  # A healthy i1Display Pro Plus returns a single, non-averaged read well
	  # inside this window even at black. If it produces no result for 45s,
	  # spotread has wedged rather than merely selected a long integration.
	  # Do not wait the generic spectro-oriented 120/140s watchdog and then
	  # keep feeding commands to the same dead interactive process.
	  if [[ "$CMD_CONTINUOUS" == "1" && "${METER_USB_ID,,}" == "0765:5020" && "$CURRENT_LOW_LIGHT_MODE" == "off" ]]; then
	   READ_TIMEOUT=45
	  fi
	  if [[ "$CMD_READ_TIMEOUT" =~ ^[0-9]+$ ]] && (( CMD_READ_TIMEOUT >= 10 )); then
	   READ_TIMEOUT="$CMD_READ_TIMEOUT"
	   (( READ_TIMEOUT > 300 )) && READ_TIMEOUT=300
	  fi
   READ_START=$SECONDS
   GOT_RESULT=false
   RETRIED_COMM=0
   NULL_READ_DISCARDS=0
   NULL_READ_FLAGGED=0
   while (( SECONDS - READ_START < READ_TIMEOUT )); do
      NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
      if [[ -n "$NEW_OUTPUT" ]]; then
       CUR_SIZE=$(output_size)
       READ_OUTPUT+="$NEW_OUTPUT"
       # Retry once on spotread's "communication problem": a transient
       # integration miss or USB hiccup is far more common than a permanent
       # comm failure during a series or autocal read, and aborting the
       # whole run on the first comm problem would discard every good read
       # before it. Retry once with +30s on the timeout, then surface the
       # error via write_state below if the retry also fails. (The earlier
       # fail-fast path that aborted immediately was reverted on 2026-06-29
       # because a Yellow 25% comm problem in a 25-step sat sweep killed 21
       # already-good reads -- see series-comm-error-must-retry-not-failfast
       # memory note.)
       if [[ $RETRIED_COMM -eq 0 && "$READ_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
        log "spotread communication problem during read - retrying once (+30s)"
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
         # Null-read guard. Only ever fires for a patch that actually drives
         # light (see patch_drives_light) -- a 0% black reads zero and is
         # accepted as-is. Each discard sends spotread another " ", which is a
         # genuinely NEW measurement; re-polling the parsed result would just
         # hand back the same zero until the deadline expired.
         if (( NULL_READ_DISCARDS < NULL_READ_RETRIES )) \
            && patch_drives_light "$R" "$G" "$B" "$IRE" "$INPUT_MAX" \
            && null_meter_reading "$PARSED_RESULT"; then
          NULL_READ_DISCARDS=$(( NULL_READ_DISCARDS + 1 ))
          log "null meter reading (all-zero XYZ) for $NAME at a light-driving patch (rgb=$R/$G/$B ire=$IRE input_max=$INPUT_MAX); re-reading ${NULL_READ_DISCARDS}/${NULL_READ_RETRIES}"
          write_state "{\"status\":\"measuring\",\"request_id\":\"$REQUEST_ID\"}"
          PARSED_RESULT=""
          READ_OUTPUT=""
          SCAN_OFFSET=$(output_size)
          READ_START=$SECONDS
          printf " " >&3
          continue
         fi
         GOT_RESULT=true
         break
        fi
       fi
       if colorimeter_dark_cal_prompt "$READ_OUTPUT"; then
        if ! perform_colorimeter_dark_calibration "read"; then
         write_state '{"status":"error","message":"Meter dark calibration did not complete"}'
         break
        fi
        printf " " >&3
        READ_START=$SECONDS
        READ_TIMEOUT=$((READ_TIMEOUT + 30))
        READ_OUTPUT=""
        SCAN_OFFSET=$(output_size)
        continue
       fi
       if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
        # Only surface a genuine re-calibration (white tile) prompt -- never
        # the normal ready-to-read prompt and never a generic "incorrect
        # position" line (those are not operator calibration steps).
        PROMPT_REASON=""
        if manual_calibration_setup_prompt "$READ_OUTPUT"; then
         PROMPT_REASON="calibration_setup"
        fi
        if [[ -n "$PROMPT_REASON" ]]; then
         log "manual prompt during read: reason=$PROMPT_REASON name=$NAME"
         if ! perform_spectro_white_calibration "read"; then
          write_state '{"status":"error","message":"Meter white-tile calibration did not complete"}'
          break
         fi
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

   # Re-reads exhausted and the patch still measures zero. Do NOT discard it and
   # do NOT fail the read: once the patch has been re-measured this many times,
   # a persistent exact zero at a low drive is a real measurement of a crushed
   # output (the same reasoning meter_series.sh records a measured zero on), and
   # aborting here would break the very calibration that is trying to fix it.
   # Instead stamp the reading so it can never be mistaken for clean data, and
   # let the consumer decide -- meter_lg_autocal.pl fails the read outright above
   # its shadow ladder, where a zero cannot be legitimate.
   if $GOT_RESULT && (( NULL_READ_DISCARDS >= NULL_READ_RETRIES )) \
      && patch_drives_light "$R" "$G" "$B" "$IRE" "$INPUT_MAX" \
      && null_meter_reading "$PARSED_RESULT"; then
    NULL_READ_FLAGGED=1
    log "null meter reading persisted for $NAME after $NULL_READ_RETRIES re-reads; recording it flagged (check the meter is on the patch, awake, and its USB link)"
   fi

   if $GOT_RESULT; then
	    PARSED="$PARSED_RESULT"
	    if [[ -n "$PARSED" ]]; then
	     # Wrap as a complete reading record (matches spotread_wrapper.sh shape).
	     # Pass parsed JSON via environment variables so Python 2 shells on older
	     # Pi images do not choke on inline quoting.
	     OUT=$(PARSED_JSON="$PARSED" READ_IRE="$IRE" READ_NAME="$NAME" READ_R="$R" READ_G="$G" READ_B="$B" READ_REQUEST_ID="$REQUEST_ID" READ_NULL_FLAG="$NULL_READ_FLAGGED" READ_NULL_RETRIES="$NULL_READ_DISCARDS" python -c "
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
r['observer']=os.environ.get('OBSERVER','1931_2')
out={'status':'complete','request_id':os.environ.get('READ_REQUEST_ID',''),'readings':[r],'count':1}
try:
 retries=int(os.environ.get('READ_NULL_RETRIES','0') or 0)
except Exception:
 retries=0
if os.environ.get('READ_NULL_FLAG','0') == '1':
 # An all-zero measurement that survived every re-read of a patch that
 # drives light. Recorded, never discarded, but stamped so no consumer can
 # mistake it for clean data.
 r['null_read']=1
 r['measured_zero']=1
 r['null_read_retries']=retries
 out['null_read']=True
 out['null_read_warning']=('The meter returned an all-zero reading for '+str(r['name'])+' after '+str(retries)+' re-reads. Check the meter is aimed at the patch, awake, and still on its USB link.')
 # Mirrored into 'message' so the existing error toasts and the workers'
 # generic failure reporting have something actionable to show.
 out['message']=out['null_read_warning']
elif retries > 0:
 r['null_read_retries']=retries
print(json.dumps(out))
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
    # A timeout leaves spotread's interactive process in an unknown state.
	    # Recover only Continuous reads. Read Once deliberately leaves timeout
	    # handling to the operator, and series reads use their own worker and
	    # retry policy. Respawning every non-continuous miss adds a long delay
	    # and previously made unreported reads stall an entire workflow.
	    if [[ "$CMD_CONTINUOUS" == "1" ]]; then
	     if ! respawn_spotread "$CURRENT_LOW_LIGHT_MODE" "continuous read timeout"; then
	      log "continuous read-timeout recovery failed"
	     fi
	    fi
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

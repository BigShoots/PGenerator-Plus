#!/bin/bash
# meter_series.sh - Background measurement series helper
# Called by PGenerator webui.pm to run a series of pattern+measurement steps
# Uses a SINGLE persistent spotread session across all patches for speed
# Usage: meter_series.sh <series_id> <display_type> <delay_ms> <patch_size> <steps_file> <state_file> [ccss_file] [patch_insert] [refresh_rate] [disable_aio] [signal_mode] [max_luma] [dv_map_mode] [meter_port] [ready_file] [require_device_ready] [pattern_signal_range] [transport_signal_range] [pattern_delay_ms] [patch_insert_patch_enabled] [patch_insert_patch_every] [patch_insert_patch_duration_ms] [patch_insert_patch_level] [patch_insert_time_enabled] [patch_insert_time_frequency_ms] [patch_insert_time_duration_ms] [patch_insert_time_level] [low_light_mode] [insert_patch_code] [insert_time_code] [color_format] [meter_usb_id] [observer] [pattern_provider] [min_luma] [max_cll] [max_fall] [low_light_trigger]

set -o pipefail

# Add the legacy SpectraCal C6 unlock key as an ArgyllCMS i1Display3 fallback.
# Built-in i1D3 keys remain first in Argyll's key list; other meter drivers
# never consume this variable.
I1D3_ESCAPE="${I1D3_ESCAPE:-c9bfafe002871166}"
export I1D3_ESCAPE

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
PATTERN_DELAY_MS="${19:-0}"
PATCH_INSERT_PATCH_ENABLED="${20:-}"
PATCH_INSERT_PATCH_EVERY="${21:-1}"
PATCH_INSERT_PATCH_DURATION_PROVIDED=0
[[ ${22+x} ]] && PATCH_INSERT_PATCH_DURATION_PROVIDED=1
PATCH_INSERT_PATCH_DURATION_MS="${22:-0}"
PATCH_INSERT_PATCH_LEVEL="${23:-25}"
PATCH_INSERT_TIME_ENABLED="${24:-0}"
PATCH_INSERT_TIME_FREQUENCY_MS="${25:-5000}"
PATCH_INSERT_TIME_DURATION_MS="${26:-5000}"
PATCH_INSERT_TIME_LEVEL="${27:-25}"
# Operator-selected low-light averaging mode. It is not the initial spotread
# mode: the child always starts at off and changes only for a step below the
# trigger.
LOW_LIGHT_MODE="${28:-${LOW_LIGHT_MODE:-off}}"
case "$LOW_LIGHT_MODE" in
 a|aa|aaa) ;;
 *) LOW_LIGHT_MODE="off" ;;
esac
# Precomputed pattern-insertion codes (mode-correct). The webui derives them
# from the same closure the greyscale ladder uses, so an insertion patch at
# the user-configured level lands on the same code a step at that stimulus
# would. Positional args 29/30; empty value triggers a legacy linear
# fallback below (older webui binaries). "<code>:<input_max>" colon-joined
# so the daemon's "/usr/bin/meter_series.sh *" arg-count stays minimal.
PATCH_INSERT_PATCH_PRECOMPUTED="${29:-}"
PATCH_INSERT_TIME_PRECOMPUTED="${30:-}"
# Color format (0=RGB, 1=YCbCr). Used as part of the last_black_<sig> cache
# key because the panel-side 0% IRE black depends on colorimetry.
COLOR_FORMAT="${31:-}"
# USB vid:pid of the operator-selected meter (arg 32). When set, find_port
# resolves the spotread -c index from THIS device instead of trusting the
# requested index, which goes stale when meters are plugged/unplugged.
METER_USB_ID="${32:-}"
# Argyll tristimulus observer (arg 33).
OBSERVER="${33:-1931_2}"
case "$OBSERVER" in
 1931_2|1964_10|2015_2|2015_10) ;;
 *) OBSERVER="1931_2" ;;
esac
export OBSERVER
# ICC profiling can display patches through a paired target-computer
# companion. All other series continue to use the local PGenerator renderer.
PATTERN_PROVIDER="${34:-local}"
[[ "$PATTERN_PROVIDER" == "companion" ]] || PATTERN_PROVIDER="local"
MIN_LUMA="${35:-0.005}"
MAX_CLL="${36:-$MAX_LUMA}"
MAX_FALL="${37:-400}"
LOW_LIGHT_TRIGGER="${38:-}"
if ! [[ "$LOW_LIGHT_TRIGGER" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
 LOW_LIGHT_TRIGGER=""
fi
COMPANION_COMMAND_FILE="/var/lib/PGenerator/icc-companion/command.json"
COMPANION_ACK_FILE="/tmp/pgen_icc_companion.ack.json"
COMPANION_SEQUENCE=0

# SpyderX uses native -y display calibrations and device-specific CCMX
# matrices. It does not accept CCSS or a manual refresh-frequency override.
if [[ "${METER_USB_ID,,}" == "085c:0a00" ]]; then
 [[ "${CCSS_FILE,,}" =~ \.ccmx$ ]] || CCSS_FILE=""
 REFRESH_RATE=""
fi
STOP_FILE="/tmp/meter_series_stop_${SERIES_ID}.signal"
USB_CANCEL_SUPPRESS_FILE="/tmp/meter_series_cancel_usb_suppress.uptime"
SPOTREAD_BIN="/usr/bin/spotread"
# Simulated meter (WebUI port 99): swap in the spotread-protocol simulator.
# It enumerates itself as port 99 via -?, needs no USB device, and takes no
# CCSS/refresh/USB identity.
METER_SIMULATED=0
if [[ "$METER_PORT" == "99" ]]; then
 METER_SIMULATED=1
 SPOTREAD_BIN="/usr/bin/spotread_sim"
 METER_USB_ID=""
 CCSS_FILE=""
 REFRESH_RATE=""
fi
API_BASE="http://127.0.0.1/api"
TMPDIR="/tmp"
SPECTRO_MARKER_ID=$(printf '%s' "${METER_USB_ID:-unknown}" | tr -cd 'A-Za-z0-9')
[[ -n "$SPECTRO_MARKER_ID" ]] || SPECTRO_MARKER_ID="unknown"
SPECTRO_STARTUP_MARKER="/tmp/pg_spectro_startup_checked_${SPECTRO_MARKER_ID}"
INITIAL_READY_PENDING=0
[[ "$REQUIRE_DEVICE_READY" == "1" ]] && INITIAL_READY_PENDING=1
SETUP_STEP_ID=0
METER_SERIES_FD_OPEN=0
SERIES_STATE_CLAIM_LOST=0

json_escape() {
 printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

series_state_claim_lost() {
 [[ "${SERIES_STATE_CLAIM_LOST:-0}" == "1" ]] && return 0
 [[ -f "$STATE_FILE" ]] || return 1
 local owner
 owner=$(python - "$STATE_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        state = json.load(fh)
except Exception:
    raise SystemExit(0)
if isinstance(state, dict):
    print(state.get("series_id", "") or "")
PY
)
 [[ -z "$owner" || "$owner" == "$SERIES_ID" ]] && return 1
 SERIES_STATE_CLAIM_LOST=1
 echo "[$(date '+%H:%M:%S.%3N')] series state ownership moved: own=$SERIES_ID current=$owner" >> /tmp/meter_series_debug.log
 return 0
}

# webui.pm seeds the initial state file with the series identity ("type" +
# "points"). Custom/lattice colour series (points>=900) ride on type "colors"
# and are told apart from the stock ColorChecker ONLY by that id. The worker's
# own state writes below omit type/points, so without carrying them forward
# every poll/recovery of a running cube read loses the lattice id and the WebUI
# routes the reads onto the ColorChecker CIE chart. Cache the identity once from
# the seed (before our first overwrite) and re-splice it into every state write.
SERIES_META_JSON=""
SERIES_META_LOADED=""
load_series_identity_meta() {
 [[ -n "$SERIES_META_LOADED" ]] && return
 SERIES_META_LOADED=1
 [[ -f "$STATE_FILE" ]] || return
 SERIES_META_JSON=$(python - "$STATE_FILE" <<'PY' 2>/dev/null || true
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
if not isinstance(state, dict) or "points" not in state:
    raise SystemExit(0)
try:
    points = int(state.get("points"))
except Exception:
    raise SystemExit(0)
stype = str(state.get("type", "") or "")
meta = {"type": stype, "points": points}
# Keep the chart context seeded by webui.pm on every worker rewrite. Losing
# these top-level fields made a live series depend on whichever reading or
# reconstructed step happened to be available during that poll, then caused a
# second target/Delta-E calculation when the completed snapshot was restored.
for key in ("signal_mode", "target_gamma", "max_luma", "dv_map_mode", "dv_interface"):
    if key in state and state[key] is not None:
        meta[key] = state[key]
sys.stdout.write(",".join(json.dumps(key) + ":" + json.dumps(value, separators=(",", ":"))
                          for key, value in meta.items()))
PY
)
}

write_state_json() {
 local payload
 payload=$(cat) || return 1
 series_state_claim_lost && return 1
 load_series_identity_meta
 if [[ -n "$SERIES_META_JSON" && "$payload" != *'"points"'* && "$payload" == *"}" ]]; then
  payload="${payload%\}},$SERIES_META_JSON}"
 fi
 local tmp="${STATE_FILE}.$$.$RANDOM.tmp"
 printf '%s\n' "$payload" > "$tmp" || return 1
 chmod 666 "$tmp" 2>/dev/null || true
 chown pgenerator:pgenerator "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$STATE_FILE"
}

series_stop_requested() {
 [[ -f "$STOP_FILE" ]] && return 0
 series_state_claim_lost && return 0
 return 1
}

series_process_tree() {
 local root="$1"
 [[ -n "$root" ]] || return 0
 local all="$root"
 local parents="$root"
 local next kids
 while [[ -n "$parents" ]]; do
  next=""
  for p in $parents; do
   kids=$(pgrep -P "$p" 2>/dev/null || true)
   [[ -n "$kids" ]] || continue
   next="$next $kids"
   all="$all $kids"
  done
  parents="$next"
 done
 printf '%s\n' "$all" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

record_series_cancel_usb_suppression() {
 local uptime_now="" tmp=""
 read -r uptime_now _ < /proc/uptime 2>/dev/null || return 0
 [[ "$uptime_now" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
 tmp="${USB_CANCEL_SUPPRESS_FILE}.$$"
 {
  tail -n 19 "$USB_CANCEL_SUPPRESS_FILE" 2>/dev/null || true
  printf '%s\n' "$uptime_now"
 } > "$tmp" || return 0
 chmod 666 "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$USB_CANCEL_SUPPRESS_FILE" 2>/dev/null || rm -f "$tmp"
}

series_quit_spotread() {
 local quit_reason="${1:-normal}"
 if [[ "${METER_SERIES_FD_OPEN:-0}" == "1" ]]; then
  printf "Q" >&3 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  METER_SERIES_FD_OPEN=0
 fi
 # A Stop request is explicit cancellation, not a request to finish the active
 # read. Give spotread a short opportunity to consume Q and close its USB
 # handle cleanly, then use TERM to interrupt a read that is still integrating.
 # Waiting the full READ_TIMEOUT here made normal Stop operations take 30-180s
 # (90s in the observed 2026-07-27 color-series stop). SIGKILL remains only the
 # final fallback, so responsive cancellation does not return to force-resetting
 # a healthy meter process immediately.
 local spotread_grace=3
 local waited=0
 while (( waited < spotread_grace * 10 )) && pgrep -x spotread >/dev/null 2>&1; do
  sleep 0.1
  waited=$((waited + 1))
 done
 if pgrep -x spotread >/dev/null 2>&1; then
  echo "[$(date '+%H:%M:%S.%3N')] series stop: spotread exceeded ${spotread_grace}s graceful timeout; sending TERM" >> /tmp/meter_series_debug.log
  # Dark reads can leave spotread blocked inside libusb so an explicit Stop
  # must interrupt it. The kernel may emit a short -32/-71 enumeration burst
  # while that cancelled transaction is torn down. Record the monotonic time
  # before TERM so the WebUI can ignore only this expected cancellation burst;
  # spontaneous errors before it or errors that continue afterward still warn.
  [[ "$quit_reason" == "cancel" ]] && record_series_cancel_usb_suppression
  pkill -TERM -x spotread 2>/dev/null || true
 pkill -TERM -x spotread_sim 2>/dev/null || true
  local term_waited=0
  while (( term_waited < 50 )) && pgrep -x spotread >/dev/null 2>&1; do
   sleep 0.1
   term_waited=$((term_waited + 1))
  done
 fi
 if pgrep -x spotread >/dev/null 2>&1; then
  echo "[$(date '+%H:%M:%S.%3N')] series stop: spotread ignored TERM for 5s; forcing SIGKILL" >> /tmp/meter_series_debug.log
  pkill -9 -x spotread 2>/dev/null || true
 pkill -9 -x spotread_sim 2>/dev/null || true
 fi
 # spotread is gone; now the surrounding cat/script pipeline can be reaped
 # without interrupting a USB transaction.
 if [[ -n "${BG_PID:-}" ]]; then
  if kill -0 "$BG_PID" 2>/dev/null; then
   local tree
   tree=$(series_process_tree "$BG_PID")
   kill $tree 2>/dev/null || true
   sleep 0.2
   kill -9 $tree 2>/dev/null || true
  fi
  wait "$BG_PID" 2>/dev/null || true
 fi
 rm -f "${OUTFILE:-}" "${CMDPIPE:-}" 2>/dev/null || true
}

series_cancel_exit() {
 write_state_json << EOJSON
{"status":"cancelled","series_id":"$SERIES_ID","current_step":0,"total_steps":${TOTAL:-0},"current_name":"Cancelled","readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 series_quit_spotread "cancel"
 companion_show_alignment
 rm -f "$READY_FILE" "$STOP_FILE" 2>/dev/null || true
 exit 0
}

cleanup_stale_series_step_files() {
 local keep
 keep="$(basename "$STEPS_FILE")"
 find "$TMPDIR" -maxdepth 1 -type f -name 'meter_series_steps_*.json' ! -name "$keep" -delete >/dev/null 2>&1 || true
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
 curl -s --max-time 8 "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-$TRANSPORT_SIGNAL_RANGE}" "$9")" >/dev/null 2>&1
}

post_patch_timeout() {
 if [[ "$PATTERN_PROVIDER" == "companion" ]]; then
  post_companion_patch "$@"
  return $?
 fi
 timeout 5 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d "$(patch_request_body "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-$TRANSPORT_SIGNAL_RANGE}" "$9")" >/dev/null 2>&1 || true
}

companion_pattern_failure() {
 local message="$1" escaped
 escaped=$(json_escape "$message")
 write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":${STEP_NUM:-0},"total_steps":${TOTAL:-0},"current_name":"$escaped","readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 series_quit_spotread "companion_error" 2>/dev/null || true
 companion_show_alignment
 exit 1
}

post_companion_patch() {
 local r="$1" g="$2" b="$3" size="$4" signal_mode="$5" max_luma="$6" signal_range="$7" input_max="${9:-255}"
 local preserve_hdr_calibration="${10:-0}"
 local code_min=0 code_max shift sequence payload tmp deadline ack ack_sequence ack_status ack_message
 [[ -z "$input_max" || "$input_max" == "-" ]] && input_max=255
 code_max="$input_max"
 if [[ "$signal_range" == "1" ]]; then
  case "$input_max" in
   1023) shift=4 ;;
   4095) shift=16 ;;
   *) shift=1 ;;
  esac
  code_min=$((16 * shift))
  code_max=$((235 * shift))
 fi
 sequence=$(date +%s%3N)
 if (( sequence <= COMPANION_SEQUENCE )); then sequence=$((COMPANION_SEQUENCE + 1)); fi
 COMPANION_SEQUENCE=$sequence
 payload="{\"status\":\"patch\",\"sequence\":$sequence,\"r\":$r,\"g\":$g,\"b\":$b,\"size\":$size,\"input_max\":$input_max,\"code_min\":$code_min,\"code_max\":$code_max,\"signal_mode\":\"$signal_mode\",\"max_luma\":$max_luma,\"min_luma\":$MIN_LUMA,\"max_cll\":$MAX_CLL,\"max_fall\":$MAX_FALL}"
 if [[ "$preserve_hdr_calibration" == "1" ]]; then
  payload="${payload%\}},\"preserve_hdr_calibration\":1}"
 fi
 tmp="${COMPANION_COMMAND_FILE}.$$.$sequence.tmp"
 printf '%s' "$payload" > "$tmp" || companion_pattern_failure "Could not send a patch to PGenerator+ Patch Companion"
 # The root-run worker writes RGB patch commands, while the WebUI poll
 # endpoint runs as pgenerator. The command contains no pairing token or
 # measurement data, so make it readable after the atomic rename.
 chmod 644 "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$COMPANION_COMMAND_FILE" || companion_pattern_failure "Could not send a patch to PGenerator+ Patch Companion"
 # Windows can briefly pause the Companion while changing HDR or fullscreen
 # swapchains. Keep the patch pending long enough for polling to resume rather
 # than aborting an otherwise valid measurement run after ten seconds.
 deadline=$((SECONDS + 30))
 while (( SECONDS < deadline )); do
  series_stop_requested && series_cancel_exit
  if [[ -f "$COMPANION_ACK_FILE" ]]; then
   ack=$(cat "$COMPANION_ACK_FILE" 2>/dev/null || true)
   ack_sequence=$(printf '%s' "$ack" | sed -n 's/.*"sequence"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
   if [[ "$ack_sequence" == "$sequence" ]]; then
    ack_status=$(printf '%s' "$ack" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ "$ack_status" == "ok" ]] && return 0
    ack_message=$(printf '%s' "$ack" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    companion_pattern_failure "${ack_message:-PGenerator+ Patch Companion could not render the requested patch}"
   fi
  fi
  sleep 0.05
 done
 companion_pattern_failure "PGenerator+ Patch Companion did not acknowledge the patch"
}

companion_show_alignment() {
 [[ "$PATTERN_PROVIDER" == "companion" ]] || return 0
 # Route the idle command through the WebUI first so the meter-gated
 # stabilization policy can replace alignment with its full-screen stimulus.
 # Retain the direct file write as a fallback if the local API is unavailable.
 local response
 response=$(curl -s --max-time 5 "$API_BASE/icc/companion/pattern" -X POST \
  -H 'Content-Type: application/json' -d '{"name":"align"}' 2>/dev/null || true)
 [[ "$response" == *'"status":"ok"'* ]] && return 0
 local sequence tmp payload
 sequence=$(date +%s%3N)
 if (( sequence <= COMPANION_SEQUENCE )); then sequence=$((COMPANION_SEQUENCE + 1)); fi
 COMPANION_SEQUENCE=$sequence
 payload="{\"status\":\"align\",\"sequence\":$sequence}"
 tmp="${COMPANION_COMMAND_FILE}.$$.$sequence.tmp"
 printf '%s' "$payload" > "$tmp" 2>/dev/null || return 0
 chmod 644 "$tmp" 2>/dev/null || true
 mv -f "$tmp" "$COMPANION_COMMAND_FILE" 2>/dev/null || true
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
 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$step_num,"total_steps":$TOTAL,"current_name":"$escaped_name","awaiting_ready":true${extra},"readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 while [[ ! -f "$READY_FILE" ]]; do
  series_stop_requested && series_cancel_exit
  sleep 0.2
 done
 rm -f "$READY_FILE"
}

series_setup_step() {
 local step="$1" message="$2" working="${3:-}"
 SETUP_STEP_ID=$((SETUP_STEP_ID + 1))
 local sid=$SETUP_STEP_ID
 local escaped_step escaped_message escaped_working ready_reason
 ready_reason="initial_measurement"
 case "$step" in
  calibrate_tile|calibrate_retry|calibrate_dark) ready_reason="calibration_setup" ;;
  position_screen) ready_reason="initial_measurement" ;;
 esac
 escaped_step=$(json_escape "$step")
 escaped_message=$(json_escape "$message")
 rm -f "$READY_FILE"
 write_state_json << EOJSON
{"status":"setup","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"$escaped_message","step_id":$sid,"step":"$escaped_step","message":"$escaped_message","awaiting_ready":true,"awaiting_ready_reason":"$ready_reason","readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 while [[ ! -f "$READY_FILE" ]]; do
  series_stop_requested && series_cancel_exit
  sleep 0.2
 done
 rm -f "$READY_FILE"
 if [[ -n "$working" ]]; then
  escaped_working=$(json_escape "$working")
  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"$escaped_working","setup_busy":true,"message":"$escaped_working","readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 else
  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[${READINGS:-}],"white_reading":${WHITE_READING:-null}}
EOJSON
 fi
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

clean_output_since() {
 local offset="${1:-0}"
 local start=$((offset + 1))
 [[ -f "$OUTFILE" ]] || return 0
 tail -c +"$start" "$OUTFILE" 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'
}

# See meter_session.sh: spotread's refresh-cal PROMPT is
# "Place the instrument on a 80% white test patch," while "calibrate refresh"
# only ever appears in a separate diagnostic line. Matching the diagnostic
# alone leaves a refresh-capable meter unanswered until the startup loop
# times out.
refresh_cal_prompt() {
 printf '%s' "$1" | grep -qiE 'calibrate[[:space:]]+refresh|refresh[[:space:]]+frequency|80%[[:space:]]*(or[[:space:]]+greater[[:space:]]+)?white[[:space:]]+test[[:space:]]+patch'
}

# A genuine "cover the sensor" dark calibration, which a colorimeter can ask
# for as well. Answering it blind with the meter facing a lit screen takes
# screen light as the black reference and zeroes every low-grey reading.
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
 # that skipped the white-tile step). Applies to all read types (series).
 if colorimeter_dark_cal_prompt "$clean_out"; then
  echo "dark_calibration"
  return 0
 fi
 if manual_calibration_setup_prompt "$clean_out"; then
  echo "calibration_setup"
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

# Handle an interactive prompt raised after a series has already started.
# Argyll can invalidate a SpyderX black reference after 30 minutes, so the
# covered-sensor step must work during long series as well as during startup.
# The caller sends the final key that retries the interrupted patch read.
handle_series_manual_prompt() {
 local step_num="$1" step_name="$2" reason="$3"
 local cal_offset waited clean
 if [[ "$reason" == "dark_calibration" ]]; then
  series_setup_step "calibrate_dark" "Cover the meter's sensor (or lay it face-down on a dark surface), then click Calibrate." "Calibrating the meter's black reference - please wait..."
  cal_offset=$(output_size)
  printf " " >&3
  waited=0
  while (( waited < 300 )); do
   series_stop_requested && series_cancel_exit
   clean=$(clean_output_since "$cal_offset")
   if printf '%s' "$clean" | grep -q "to take a reading:"; then
    series_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
    return 0
   fi
   if printf '%s' "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected|calibration failed"; then
    echo "[$(date '+%H:%M:%S.%3N')] dark calibration failed: step=$step_num name=$step_name output=$(printf '%s' "$clean" | tr '\n' ' ' | cut -c1-300)" >> /tmp/meter_series_debug.log
    return 1
   fi
   sleep 0.1
   waited=$((waited + 1))
  done
  echo "[$(date '+%H:%M:%S.%3N')] dark calibration timed out: step=$step_num name=$step_name" >> /tmp/meter_series_debug.log
  return 1
 fi
 if [[ "$reason" == "calibration_setup" ]]; then
  series_setup_step "calibrate_tile" "Place the spectrophotometer flat on its white calibration tile, then click Calibrate." "Calibrating the meter on its tile - please wait a few seconds..."
  cal_offset=$(output_size)
  printf " " >&3
  waited=0
  while (( waited < 900 )); do
   series_stop_requested && series_cancel_exit
   clean=$(clean_output_since "$cal_offset")
   if printf '%s' "$clean" | grep -q "to take a reading:"; then
    series_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
    return 0
   fi
   if printf '%s' "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected|calibration failed|reading is too low"; then
    echo "[$(date '+%H:%M:%S.%3N')] spectrophotometer calibration failed: step=$step_num name=$step_name output=$(printf '%s' "$clean" | tr '\n' ' ' | cut -c1-300)" >> /tmp/meter_series_debug.log
    return 1
   fi
   sleep 0.1
   waited=$((waited + 1))
  done
  echo "[$(date '+%H:%M:%S.%3N')] spectrophotometer calibration timed out: step=$step_num name=$step_name" >> /tmp/meter_series_debug.log
  return 1
 fi
 if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
  wait_for_device_ready "$step_num" "$(manual_ready_prompt_label "$step_name" "$reason")" "$reason"
 else
  sleep 1
 fi
 return 0
}

rm -f "$READY_FILE" "$STOP_FILE"

# On unexpected exit, rewrite the state JSON so the poller doesn't report
# the generic "Process died unexpectedly" string when the script crashes
# before its normal error path runs (spotread USB fault, bash error, etc.).
# The TERM/INT trap and the normal completion path already write their own
# status, so this is a no-op for the well-behaved exits; it only kicks in
# for crashes where the state is still "running" or "setup".
write_state_on_exit() {
 if [[ -z "${STATE_FILE:-}" || ! -f "$STATE_FILE" ]]; then
  rm -f "${READY_FILE:-}" "${STOP_FILE:-}" 2>/dev/null || true
  return 0
 fi
 local cur=""
 if command -v cat >/dev/null 2>&1; then
  cur=$(cat "$STATE_FILE" 2>/dev/null) || cur=""
 fi
 if [[ "$cur" == *'"status":"running"'* || "$cur" == *'"status":"setup"'* ]]; then
  local last_step=0 last_name="Series helper exited unexpectedly"
  if [[ "$cur" =~ \"current_step\":[[:space:]]*([0-9]+) ]]; then
   last_step="${BASH_REMATCH[1]}"
  fi
  if [[ "$cur" =~ \"current_name\":[[:space:]]*\"([^\"]*)\" ]]; then
   last_name="${BASH_REMATCH[1]} (exited unexpectedly)"
  fi
  local safe_name
  safe_name=$(printf '%s' "$last_name" | tr -d '\n\r' | head -c 200)
  local safe_sid="${SERIES_ID:-}"
  safe_sid=$(printf '%s' "$safe_sid" | tr -cd 'A-Za-z0-9_.-')
  local total="${TOTAL:-0}"
  printf '{"status":"error","series_id":"%s","current_step":%s,"total_steps":%s,"current_name":"%s","readings":[],"white_reading":null,"error":"series_helper_exited_unexpectedly"}\n' \
   "$safe_sid" "$last_step" "$total" "$safe_name" > "$STATE_FILE" 2>/dev/null || true
  chmod 666 "$STATE_FILE" 2>/dev/null || true
 fi
 rm -f "$READY_FILE" "$STOP_FILE" 2>/dev/null || true
}

trap 'write_state_on_exit' EXIT
trap 'series_cancel_exit' TERM INT

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

# Persist a measured white reference into step metadata once it is available.
# The per-step selector below consumes only serialized target metadata; it does
# not use the previous patch's measured luminance as the next patch's decision.
apply_series_white_reference_to_steps() {
 local white_y="$1"
 [[ -f "$STEPS_FILE" ]] || return 1
 [[ "$white_y" =~ ^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$ ]] || return 1
 STEPS_FILE="$STEPS_FILE" WHITE_Y="$white_y" python - <<'PY' 2>/dev/null
import json, os, tempfile

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

path = os.environ.get("STEPS_FILE", "")
try:
    white_y = float(os.environ.get("WHITE_Y", ""))
except Exception:
    raise SystemExit(1)
if not finite(white_y) or white_y <= 0:
    raise SystemExit(1)
try:
    with open(path) as fh:
        steps = json.load(fh)
except Exception:
    raise SystemExit(1)
if not isinstance(steps, list):
    raise SystemExit(1)
changed = False

for step in steps:
    if not isinstance(step, dict):
        continue
    if "series_target_white_y" not in step and "lg_target_white_y" not in step:
        step["series_target_white_y"] = white_y
        changed = True
if not changed:
    raise SystemExit(0)
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(steps, fh, separators=(",", ":"))
        fh.write("\n")
    os.rename(tmp, path)
    os.chmod(path, int("644", 8))
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

# Return off or the operator-selected a/aa/aaa mode for one serialized step.
# Direct absolute targets win; otherwise target_Yn is resolved against the
# serialized white reference and floored at the serialized black reference.
effective_low_light_mode_for_step() {
 local idx="$1"
 STEPS_FILE="$STEPS_FILE" STEP_INDEX="$idx" SELECTED_MODE="$LOW_LIGHT_MODE" LOW_LIGHT_TRIGGER_VALUE="$LOW_LIGHT_TRIGGER" python - <<'PY' 2>/dev/null
import json, os

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
    except Exception:
        return None
    return value if finite(value) else None

mode = os.environ.get("SELECTED_MODE", "off")
if mode not in ("a", "aa", "aaa"):
    print("off")
    raise SystemExit(0)
trigger = number(os.environ.get("LOW_LIGHT_TRIGGER_VALUE"))
if trigger is None or trigger <= 0:
    print("off")
    raise SystemExit(0)
try:
    with open(os.environ.get("STEPS_FILE", "")) as fh:
        steps = json.load(fh)
    step = steps[int(os.environ.get("STEP_INDEX", "-1"))]
except Exception:
    print("off")
    raise SystemExit(0)
if not isinstance(step, dict):
    print("off")
    raise SystemExit(0)

expected = None
absolute_present = False
for key in ("target_Y", "dv_absolute_target_y"):
    if key in step:
        absolute_present = True
        expected = number(step.get(key))
        if expected is None or expected < 0:
            print("off")
            raise SystemExit(0)
        break
if not absolute_present and "custom_target_nits" in step:
    absolute_present = True
    expected = number(step.get("custom_target_nits"))
    if expected is None or expected <= 0:
        print("off")
        raise SystemExit(0)
if not absolute_present:
    target_yn = number(step.get("target_Yn"))
    black_y = number(step.get("series_target_black_y"))
    if black_y is None or black_y < 0:
        black_y = 0.0
    if target_yn is not None and target_yn >= 0:
        if target_yn == 0:
            expected = black_y
        else:
            white_y = None
            for key in ("dv_absolute_white_y", "series_target_white_y", "lg_target_white_y"):
                candidate = number(step.get(key))
                if candidate is not None and candidate > 0:
                    white_y = candidate
                    break
            if white_y is not None:
                expected = max(black_y, target_yn * white_y)
if expected is None or expected < 0 or not finite(expected):
    print("off")
else:
    print(mode if expected < trigger else "off")
PY
}

ensure_spotread_low_light_for_step() {
 local idx="$1" desired
 # Spectrophotometers can require a physical white-tile prompt after a child
 # restart. Do not abort an otherwise valid series to change averaging mode
 # when the operator must remain in control of that setup sequence.
 [[ "$REQUIRE_DEVICE_READY" == "1" ]] && return 0
 desired=$(effective_low_light_mode_for_step "$idx")
 case "$desired" in a|aa|aaa) ;; *) desired="off" ;; esac
 [[ "$desired" == "${CURRENT_LOW_LIGHT_MODE:-off}" ]] && return 0
 restart_spotread_session "$desired"
}

build_step_reading_json() {
 local idx="$1" parsed_json="${2:-}"
 [[ -n "$parsed_json" ]] || parsed_json="{}"
 python - "$idx" "$STEPS_FILE" "$parsed_json" <<'PY'
import json, math, os, sys

try:
    index = int(sys.argv[1])
except Exception:
    index = 0

try:
    steps_file = sys.argv[2]
except Exception:
    steps_file = ""

try:
    reading = json.loads(sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "{}")
except Exception:
    sys.exit(1)

if not isinstance(reading, dict):
    sys.exit(1)
reading["observer"] = os.environ.get("OBSERVER", "1931_2")

def finite_number(value):
    try:
        value = float(value)
    except Exception:
        return False
    return math.isfinite(value) if hasattr(math, "isfinite") else value == value and value not in (float("inf"), float("-inf"))

has_measurement = (
    finite_number(reading.get("X")) and
    finite_number(reading.get("Y")) and
    finite_number(reading.get("Z")) and
    finite_number(reading.get("luminance"))
)

if not has_measurement and "error" not in reading:
    sys.exit(1)

try:
    with open(steps_file) as fh:
        steps = json.load(fh)
    step = steps[index] if 0 <= index < len(steps) else {}
except Exception:
    step = {}

def copy_field(name):
    if name in step:
        reading[name] = step[name]

if "ire" in step:
    reading["ire"] = step["ire"]
if "name" in step:
    reading["name"] = step["name"]
for dst, src in (("r_code", "r"), ("g_code", "g"), ("b_code", "b")):
    if src in step:
        reading[dst] = step[src]

for field in (
	"input_max", "patch_size", "stimulus", "signal_r_pct", "signal_g_pct", "signal_b_pct",
	"signal_mode", "target_gamma", "max_luma", "dv_map_mode",
	"analysis_ire", "target_ire", "transport_stimulus",
	"final_white_refresh",
	"target_x", "target_y", "target_Yn", "target_X", "target_Y", "target_Z",
	"dv_absolute_white_y", "dv_absolute_target_y", "dv_absolute_rolloff_pct",
	"dv_absolute_tunnel_gamma", "dv_absolute_st2084_precomp",
    "series_target_white_y", "lg_target_white_y", "series_target_black_y",
	"series_type", "series_color", "sat_pct", "point_role", "series_mode",
	"series_white_reference",
	"icc_reuse_signature",
    "autocal_code", "autocal_white_reference", "autocal_reference_only",
    "autocal_read_only", "autocal_slot_locked", "ddc_slot_locked",
    "autocal_legal_white_anchor", "ddc_target_ire", "autocal_order_ire",
    "autocal_target_label", "preview_r", "preview_g", "preview_b"
):
    copy_field(field)

print(json.dumps(reading, separators=(",", ":")))
PY
}

dv_absolute_greyscale_series_active() {
 [[ "$SIGNAL_MODE" == "dv" ]] || return 1
 [[ "$DV_MAP_MODE" == "1" ]] || return 1
 [[ "$SERIES_ID" == greyscale_* ]] || return 1
}

reading_luminance_json() {
READING_JSON="$1" python - <<'PY' 2>/dev/null
import json, math, os

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

try:
    reading = json.loads(os.environ.get("READING_JSON", "") or "{}")
except Exception:
    raise SystemExit(1)

for key in ("luminance", "Y"):
    try:
        value = float(reading.get(key))
    except Exception:
        continue
    if finite(value) and value > 0:
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

apply_dv_absolute_greyscale_targets() {
 local white_y="$1"
 [[ -f "$STEPS_FILE" ]] || return 1
 is_number "$white_y" || return 1
 STEPS_FILE="$STEPS_FILE" WHITE_Y="$white_y" python - <<'PY' 2>/dev/null
import json, math, os, sys, tempfile

sys.path.insert(0, "/usr/bin")
from pgen_colour_math import pq_decode_nits, pq_encode_nits

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

steps_file = os.environ.get("STEPS_FILE", "")
try:
    white_y = float(os.environ.get("WHITE_Y", "0"))
except Exception:
    raise SystemExit(1)
if not (finite(white_y) and white_y > 0):
    raise SystemExit(1)

try:
    with open(steps_file) as fh:
        steps = json.load(fh)
except Exception:
    raise SystemExit(1)
if not isinstance(steps, list):
    raise SystemExit(1)

def pq_decode_normalized(code):
    return pq_decode_nits(float(code))

def pq_encode_normalized(nits):
    nits = max(0.0, min(10000.0, float(nits)))
    if nits <= 0:
        return 0.0
    return pq_encode_nits(nits, clamp_peak=True)

def percent_from_step(step, channel):
    for key in ("signal_%s_pct" % channel, "stimulus", "analysis_ire", "target_ire", "ire"):
        try:
            value = float(step.get(key))
        except Exception:
            continue
        if finite(value):
            return value
    return 0.0

def target_for_absolute_percent(percent):
    stim = max(0.0, min(1.0, float(percent) / 100.0))
    if stim <= 0:
        return 0.0
    return min(white_y, pq_decode_normalized(stim))

for step in steps:
    if not isinstance(step, dict):
        continue
    if str(step.get("series_type", "")).lower() != "greyscale":
        continue
    # Absolute Dolby Vision uses a PQ base layer. Keep the direct 12-bit
    # legal-range codes built by the client (256..3760); converting the PQ
    # target through a measured-white 2.2 carrier makes the TV decode PQ
    # twice and produces a severely crushed verification ramp.
    step["input_max"] = 4095
    target_y = target_for_absolute_percent(percent_from_step(step, "g"))
    step["dv_absolute_white_y"] = white_y
    step["dv_absolute_target_y"] = target_y
    step["dv_absolute_rolloff_pct"] = pq_encode_normalized(white_y) * 100
    step.pop("dv_absolute_st2084_precomp", None)
    step.pop("dv_absolute_tunnel_gamma", None)

directory = os.path.dirname(steps_file) or "."
fd, tmp_path = tempfile.mkstemp(prefix=os.path.basename(steps_file) + ".", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(steps, fh, separators=(",", ":"))
        fh.write("\n")
    os.rename(tmp_path, steps_file)
    try:
        os.chmod(steps_file, int("644", 8))
    except Exception:
        pass
finally:
    try:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    except Exception:
        pass
PY
}

is_number() {
 [[ "$1" =~ ^[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$ ]]
}

number_token() {
 printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[^0-9.eE+-].*$//'
}

float_le() {
 local left="${1:-0}" right="${2:-0}"
 awk -v left="$left" -v right="$right" 'BEGIN { exit !((left + 0) <= (right + 0)) }'
}

clamp_int() {
 local value="${1:-0}" min="${2:-0}" max="${3:-255}"
 awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN {
  value = int(value + 0.5)
  if (value < min) value = min
  if (value > max) value = max
  print value
 }'
}

milliseconds_to_seconds() {
 local ms="${1:-0}"
 awk -v ms="$ms" 'BEGIN {
  if (ms < 0) ms = 0
  printf "%.3f", ms / 1000.0
 }'
}

patch_insert_settle_seconds() {
 local ire="${1:-0}"
 if float_le "$ire" 25; then
  echo 3.0
 else
  echo 1.5
 fi
}

sanitize_ms() {
 local raw="${1:-0}" fallback="${2:-0}" max="${3:-120000}"
 if [[ ! "$raw" =~ ^[0-9]+$ ]]; then raw="$fallback"; fi
 if (( raw < 0 )); then raw=0; fi
 if (( raw > max )); then raw="$max"; fi
 echo "$raw"
}

sanitize_count() {
 local raw="${1:-1}" fallback="${2:-1}" max="${3:-999}"
 if [[ ! "$raw" =~ ^[0-9]+$ ]]; then raw="$fallback"; fi
 if (( raw < 1 )); then raw=1; fi
 if (( raw > max )); then raw="$max"; fi
 echo "$raw"
}

sanitize_level() {
 local raw="${1:-25}" fallback="${2:-25}"
 if ! is_number "$raw"; then raw="$fallback"; fi
 awk -v raw="$raw" 'BEGIN {
  value = raw + 0
  if (value < 0) value = 0
  if (value > 100) value = 100
  printf "%.3f", value
 }'
}

patch_insert_code_for_level() {
 local level="${1:-25}" precomputed="${2:-}"
 # Prefer the webui-precomputed "<code>:<input_max>" payload so the insertion
 # patch matches the greyscale-series code for the same stimulus in the
 # active output mode (SDR/HDR10/DV/HLG). Older WebUI callers do not supply
 # the pair, so retain their fallback while keeping DV in its native legal
 # 12-bit source domain instead of rounding through 8-bit first.
 if [[ -n "$precomputed" && "$precomputed" == *:* ]]; then
  local pre_code="${precomputed%%:*}"
  if is_number "$pre_code"; then
   echo "$pre_code"
   return 0
  fi
 fi
 if [[ "${SIGNAL_MODE,,}" == "dv" ]]; then
  awk -v level="$level" 'BEGIN {
   value = int(256.0 + (level / 100.0) * 3504.0 + 0.5)
   if (value < 256) value = 256
   if (value > 3760) value = 3760
   print value
  }'
  return 0
 fi
 awk -v level="$level" 'BEGIN {
  value = int((level / 100.0) * 255.0 + 0.5)
  if (value < 0) value = 0
  if (value > 255) value = 255
  print value
 }'
}

patch_insert_input_max_for_level() {
 local precomputed="${1:-}"
 if [[ -n "$precomputed" && "$precomputed" == *:* ]]; then
  local im="${precomputed##*:}"
  if is_number "$im" && (( im > 0 )); then
   echo "$im"
   return 0
  fi
 fi
 if [[ "${SIGNAL_MODE,,}" == "dv" ]]; then
  echo 4095
  return 0
 fi
 echo 255
}

post_insert_patch() {
 local level="${1:-25}" duration_ms="${2:-0}" reason="${3:-patch}" precomputed="${4:-}"
 local code input_max duration_sec
 code=$(patch_insert_code_for_level "$level" "$precomputed")
 input_max=$(patch_insert_input_max_for_level "$precomputed")
 duration_sec=$(milliseconds_to_seconds "$duration_ms")
 echo "[$(date '+%H:%M:%S.%3N')] pattern insertion: reason=$reason level=${level}% code=$code input_max=$input_max duration=${duration_sec}s" >> /tmp/meter_series_debug.log
 post_patch "$code" "$code" "$code" 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$input_max" 1
 sleep "$duration_sec"
 # Clear the insertion flash before restoring the measurement patch. Without
 # this transition, a near-black read starts while the panel and meter still
 # carry the bright insertion state, producing repeatable but false XYZ.
 local black_code=0
 if [[ "${SIGNAL_MODE,,}" == "dv" ]]; then black_code=256; fi
 post_patch "$black_code" "$black_code" "$black_code" 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$input_max" 1
 sleep 0.5
 PATCH_INSERT_FIRED=1
}

current_millis() {
 python - <<'PY' 2>/dev/null || date +%s000
import time
print(int(time.time() * 1000))
PY
}

maybe_pattern_insert_before_step() {
 local step_index="${1:-0}" ire="${2:-0}"
 (( step_index > 0 )) || return 0
 local now elapsed
if [[ "$PATCH_INSERT_TIME_ENABLED" == "1" ]]; then
   now=$(current_millis)
   elapsed=$(( now - PATCH_INSERT_LAST_TIME_TS ))
   if (( elapsed >= PATCH_INSERT_TIME_FREQUENCY_MS )); then
    post_insert_patch "$PATCH_INSERT_TIME_LEVEL" "$PATCH_INSERT_TIME_DURATION_MS" "time" "$PATCH_INSERT_TIME_PRECOMPUTED"
    PATCH_INSERT_LAST_TIME_TS=$(current_millis)
   fi
  fi
  if [[ "$PATCH_INSERT_PATCH_ENABLED" == "1" ]]; then
   PATCH_INSERT_PATCH_COUNTER=$((PATCH_INSERT_PATCH_COUNTER + 1))
   if (( PATCH_INSERT_PATCH_COUNTER % PATCH_INSERT_PATCH_EVERY == 0 )); then
    local duration_ms="$PATCH_INSERT_PATCH_DURATION_MS"
    if (( PATCH_INSERT_DYNAMIC_SETTLE == 1 )); then
     duration_ms=$(awk -v seconds="$(patch_insert_settle_seconds "$ire")" 'BEGIN { printf "%d", seconds * 1000 }')
    fi
    post_insert_patch "$PATCH_INSERT_PATCH_LEVEL" "$duration_ms" "patch" "$PATCH_INSERT_PATCH_PRECOMPUTED"
   fi
  fi
}

read_timeout_seconds() {
 local ire="${1:-0}"
 # Large ICC sets can enter a slower adaptive integration after hundreds of
 # readings even when their synthetic IRE field is high.  Ten seconds then
 # expires just before a valid result and needlessly starts a second trigger.
 # Keep the longer bound scoped to profile-sized colour series.
 if [[ "$SERIES_ID" == colors_* ]] && (( ${TOTAL:-0} >= 100 )); then
  echo 20
 elif float_le "$ire" 1; then
  echo 90
 elif float_le "$ire" 5; then
  echo 70
 elif float_le "$ire" 20; then
  echo 20
 else
  echo 10
 fi
}

find_port() {
 local requested_port="$1"
 local requested_usb_id="${2:-$METER_USB_ID}"
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
  # Allow USB device to fully release after spotread -? probe
  sleep 2
 fi
 echo "$port_num"
}

cleanup_stale_series_step_files

TOTAL=$(get_step_count)
DELAY_SEC=$(python -c "print($DELAY_MS/1000.0)" 2>/dev/null)
PATTERN_DELAY_MS=$(sanitize_ms "$PATTERN_DELAY_MS" 0 120000)
PATTERN_DELAY_SEC=$(milliseconds_to_seconds "$PATTERN_DELAY_MS")
if [[ -z "$PATCH_INSERT_PATCH_ENABLED" ]]; then
 PATCH_INSERT_PATCH_ENABLED="$PATCH_INSERT"
fi
[[ "$PATCH_INSERT_PATCH_ENABLED" == "true" ]] && PATCH_INSERT_PATCH_ENABLED=1
[[ "$PATCH_INSERT_TIME_ENABLED" == "true" ]] && PATCH_INSERT_TIME_ENABLED=1
[[ "$PATCH_INSERT_PATCH_ENABLED" == "1" ]] || PATCH_INSERT_PATCH_ENABLED=0
[[ "$PATCH_INSERT_TIME_ENABLED" == "1" ]] || PATCH_INSERT_TIME_ENABLED=0
PATCH_INSERT_PATCH_EVERY=$(sanitize_count "$PATCH_INSERT_PATCH_EVERY" 1 999)
PATCH_INSERT_PATCH_LEVEL=$(sanitize_level "$PATCH_INSERT_PATCH_LEVEL" 25)
PATCH_INSERT_TIME_LEVEL=$(sanitize_level "$PATCH_INSERT_TIME_LEVEL" 25)
PATCH_INSERT_TIME_FREQUENCY_MS=$(sanitize_ms "$PATCH_INSERT_TIME_FREQUENCY_MS" 5000 120000)
PATCH_INSERT_TIME_DURATION_MS=$(sanitize_ms "$PATCH_INSERT_TIME_DURATION_MS" 5000 120000)
PATCH_INSERT_DYNAMIC_SETTLE=0
(( PATCH_INSERT_PATCH_DURATION_PROVIDED == 0 )) && PATCH_INSERT_DYNAMIC_SETTLE=1
PATCH_INSERT_PATCH_DURATION_MS=$(sanitize_ms "$PATCH_INSERT_PATCH_DURATION_MS" 1000 120000)
PATCH_INSERT_LAST_TIME_TS=$(date +%s%3N 2>/dev/null || date +%s000)
PATCH_INSERT_PATCH_COUNTER=0
FIRST_STEP_EXTRA_SEC=2
FRESH_DAEMON_WINDOW_SEC=180
FRESH_DV_FIRST_WHITE_EXTRA_SEC=8
DV_GREYSCALE_FIRST_WHITE_WARMUP_SEC=5
# A failed patch must not silently poison a validation or profiling series.
# Give an absent result one bounded redisplay/read retry. An exact all-zero
# result on a non-black patch is quick to detect and has proved transient on
# real i1Display hardware, so confirm it twice before recording it as a real
# crushed-output measurement. This retries only failed patches and does not
# respawn spotread, avoiding the long per-patch stalls of the old policy.
NO_READING_RETRIES=1
ZERO_READ_RETRIES=2

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
 (( TOTAL > 2 )) || return 1
 local first_white_reference final_white_refresh
 first_white_reference=$(get_step_field 0 autocal_white_reference)
 [[ "$first_white_reference" == "True" || "$first_white_reference" == "true" || "$first_white_reference" == "1" ]] && return 1
 final_white_refresh=$(get_step_field 0 final_white_refresh)
 [[ "$final_white_refresh" == "True" || "$final_white_refresh" == "true" || "$final_white_refresh" == "1" ]]
}

series_uses_first_white_warmup() {
 [[ "$SIGNAL_MODE" == "dv" ]] || return 1
 [[ "$SERIES_ID" == greyscale_* ]] || return 1
 (( TOTAL > 2 ))
}

# Publish an immediate startup state so the UI shows progress instead of
# looking hung while spotread is performing its cold-start handshake.
write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON

# Full cleanup of any previous meter state. Called before starting a session
# and again before any init retry. Kills every known meter process and
# removes all stale temp files that could interfere with spotread startup
# (held USB handles, stale FIFOs, cached port numbers that no longer exist).
# After a read timeout the persistent spotread session is often WEDGED, not
# just slow: i1D3-class meters intermittently reset on the USB bus (dmesg
# shows "reset full-speed USB device"; 261 timeouts logged on one rig) and the
# in-flight read never returns. Retrying on the dead session burns the retry
# timeout, and every LATER step then fails the same way to the end of the run.
# Bounce the session instead: kill the wedged reader, respawn the spotread
# child from its stable base command, wait for the reading prompt. Colorimeters
# only: a spectro restart would re-prompt for its white
# tile, which cannot be answered mid-run headlessly.
restart_spotread_session() {
 [[ "$REQUIRE_DEVICE_READY" == "1" ]] && return 1
 [[ -z "$SR_CMD_BASE" ]] && return 1
 local requested_mode="${1:-${CURRENT_LOW_LIGHT_MODE:-off}}"
 case "$requested_mode" in a|aa|aaa) ;; *) requested_mode="off" ;; esac
 SR_CMD="$SR_CMD_BASE"
 case "$requested_mode" in
  a) SR_CMD="$SR_CMD -Y a" ;;
  aa) SR_CMD="$SR_CMD -Y aa" ;;
  aaa) SR_CMD="$SR_CMD -Y aaa" ;;
 esac
 echo "[$(date '+%H:%M:%S.%3N')] restarting spotread child: step=${STEP_NUM:-?} name=${NAME:-?} low_light=${CURRENT_LOW_LIGHT_MODE:-off}->$requested_mode" >> /tmp/meter_series_debug.log
 if [[ "$METER_SERIES_FD_OPEN" == "1" ]]; then
  exec 3>&-
  METER_SERIES_FD_OPEN=0
 fi
 [[ -n "$BG_PID" ]] && kill -9 "$BG_PID" 2>/dev/null
 pkill -9 -x spotread 2>/dev/null
 pkill -9 -x spotread_sim 2>/dev/null
 sleep 1.5
 rm -f "$OUTFILE" "$CMDPIPE"
 touch "$OUTFILE"
 mkfifo "$CMDPIPE"
 cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
 BG_PID=$!
 exec 3>"$CMDPIPE"
 METER_SERIES_FD_OPEN=1
 local waited=0 refresh_done=0 clean=""
 while (( waited < 80 )); do
  series_stop_requested && series_cancel_exit
  clean=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
  if echo "$clean" | grep -q "to take a reading:"; then
   CURRENT_LOW_LIGHT_MODE="$requested_mode"
   echo "[$(date '+%H:%M:%S.%3N')] spotread session restarted OK (${waited}x0.5s)" >> /tmp/meter_series_debug.log
   return 0
  fi
  if (( refresh_done == 0 )) && refresh_cal_prompt "$clean"; then
   post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
   sleep 2
   printf " " >&3
   refresh_done=1
   sleep 2
   waited=$((waited + 8))
   continue
  fi
  if echo "$clean" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected"; then
   echo "[$(date '+%H:%M:%S.%3N')] spotread session restart: instrument error" >> /tmp/meter_series_debug.log
   return 1
  fi
  sleep 0.5
  waited=$((waited + 1))
 done
 echo "[$(date '+%H:%M:%S.%3N')] spotread session restart TIMED OUT" >> /tmp/meter_series_debug.log
 return 1
}

meter_full_cleanup() {
 # Kill all meter-related processes (wrappers, pipelines, spotread itself)
 pkill -9 -f 'meter_session.sh'          2>/dev/null
 pkill -9 -f 'spotread_wrapper'          2>/dev/null
 pkill -9 -f 'script.*spotread'          2>/dev/null
 pkill -9 -f 'cat.*spotread_cmd'         2>/dev/null
 pkill -9 -f 'sudo.*spotread'            2>/dev/null
 pkill -9 -x spotread                    2>/dev/null
pkill -9 -x spotread_sim                2>/dev/null
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
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON
   meter_full_cleanup
   sleep 2
   continue
  fi
  write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter init failed","debug":"$DBGOUT","readings":[]}
EOJSON
  exit 1
 fi

 OUTFILE="$TMPDIR/spotread_series_$$"
 CMDPIPE="$TMPDIR/spotread_cmd_$$"
 rm -f "$OUTFILE" "$CMDPIPE"
 touch "$OUTFILE"
 mkfifo "$CMDPIPE"

 # The first SpyderX/Spyder5 process after boot runs without -N so Argyll can
 # request its manual dark calibration. Later processes reuse that checked
 # calibration instead of prompting on every series. See meter_session.sh.
 NOINITCAL_FLAG=""
 case "${METER_USB_ID,,}" in
  085c:0a00|085c:0500)
   [[ -f "$SPECTRO_STARTUP_MARKER" ]] && NOINITCAL_FLAG="-N"
   ;;
 esac
 SR_CMD="$SPOTREAD_BIN $NOINITCAL_FLAG -e -y $DISPLAY_TYPE -c $PORT_NUM -Q $OBSERVER -x"
  if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
   # Spectrophotometer: no -X (CCSS is a colorimeter correction) and no -y
   # (display type selection is a colorimeter concept). Passing -y makes
   # spotread print "Display/calibration type ignored", which the init-error
   # classifier below used to treat as fatal ("Meter does not support
   # requested mode") even though the read would have worked.
   # The first spectro process after boot runs without -N so Argyll performs
   # its calibration check before any measurement. Later series launches reuse
   # the checked calibration with -N.
   SPECTRO_NOINITCAL_FLAG=""
   [[ -f "$SPECTRO_STARTUP_MARKER" ]] && SPECTRO_NOINITCAL_FLAG="-N"
   SR_CMD="$SPOTREAD_BIN $SPECTRO_NOINITCAL_FLAG -e -c $PORT_NUM -Q $OBSERVER -x"
   [[ -n "$CCSS_FILE" ]] && echo "[$(date '+%H:%M:%S.%3N')] spectrophotometer selected: skipping CCSS ($CCSS_FILE)" >> /tmp/meter_series_debug.log
  fi
 if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" && "$REQUIRE_DEVICE_READY" != "1" ]]; then
  if [[ "${CCSS_FILE,,}" =~ \.ccss$ ]]; then
   # Read the actual DISPLAY_TYPE_REFRESH value line, not the KEYWORD declaration.
   # If the field is missing, fall back to the CCSS metadata so OLED/Plasma/CRT
   # profiles don't get treated like generic LCDs (or vice versa). A CCMX uses
   # the selected instrument base type and has no spectral refresh metadata.
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
  SR_CMD="$SPOTREAD_BIN $NOINITCAL_FLAG -e -y $DISPLAY_TYPE -X '$CCSS_FILE' -c $PORT_NUM -Q $OBSERVER -x"
 fi
 # Override refresh rate if specified. Passing -Y R:rate makes spotread skip
 # its mandatory 80% white refresh-calibration read (unreliable on a
 # sample-and-hold OLED), so always honour an explicit rate.
 if [[ -n "$REFRESH_RATE" ]]; then
  SR_CMD="$SR_CMD -Y R:$REFRESH_RATE"
 fi
 # The wrapper and initial child start at explicit off. Per-step selection
 # below rebuilds only this spotread command from the stable base.
 SR_CMD_BASE="$SR_CMD"
 SR_CMD="$SR_CMD_BASE"
 CURRENT_LOW_LIGHT_MODE="off"
 # Disable AIO mode for i1D3 meters if requested
 if [[ "$DISABLE_AIO" == "1" ]]; then
  export I1D3_DISABLE_AIO=1
 fi
 cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
 BG_PID=$!
 exec 3>"$CMDPIPE"
 METER_SERIES_FD_OPEN=1

 # Wait for spotread to be ready. 120 x 0.5 s = 60 s, which avoids false
 # "Meter init failed" errors right after a reboot when USB bring-up is slow.
 # If the meter immediately reports a communications failure, stop waiting and
 # fall into the retry path so the UI doesn't sit on Initializing meter.
 WAITED=0
REFRESH_CAL_DONE=0
WHITE_REF_DONE=0
DARK_CAL_DONE=0
HANDLED_OFFSET=0
 while (( WAITED < 120 )); do
  series_stop_requested && series_cancel_exit
  CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 NEW_OUT=$(clean_output_since "$HANDLED_OFFSET")
 if echo "$CLEAN_OUT" | grep -q "to take a reading:"; then
   break
  fi
 if (( REFRESH_CAL_DONE == 0 )) && refresh_cal_prompt "$NEW_OUT"; then
  post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
  sleep 2
  printf " " >&3
  REFRESH_CAL_DONE=1
  HANDLED_OFFSET=$(output_size)
  sleep 2
  WAITED=$((WAITED + 4))
  continue
 fi
 if [[ "$REQUIRE_DEVICE_READY" == "1" ]] && echo "$NEW_OUT" | grep -qiE 'reading is too low|calibration failed'; then
    series_setup_step "calibrate_retry" "Calibration failed. Re-seat the spectrophotometer flat on its white tile, then click Retry." "Re-calibrating the meter - please wait..."
  printf " " >&3
  HANDLED_OFFSET=$(output_size)
  WAITED=$((WAITED + 1))
  continue
 fi
 if colorimeter_dark_cal_prompt "$NEW_OUT"; then
    series_setup_step "calibrate_dark" "Cover the meter's sensor (or lay it face-down on a dark surface), then click Calibrate." "Calibrating the meter's black reference - please wait..."
  printf " " >&3
  DARK_CAL_DONE=1
  HANDLED_OFFSET=$(output_size)
  WAITED=$((WAITED + 1))
  continue
 fi
 if (( WHITE_REF_DONE == 0 )) && manual_calibration_setup_prompt "$NEW_OUT"; then
    series_setup_step "calibrate_tile" "Place the spectrophotometer flat on its white calibration tile, then click Calibrate." "Calibrating the meter on its tile - please wait..."
  printf " " >&3
  WHITE_REF_DONE=1
  HANDLED_OFFSET=$(output_size)
  WAITED=$((WAITED + 1))
  continue
 fi
 if echo "$CLEAN_OUT" | grep -qiE "Communications failure|Instrument initialisation failed|No device found|instrument is not connected"; then
   break
  fi
  # Catch meter-model mismatches: spotread exits cleanly when the meter
  # doesn't support the requested flags (e.g. -X WRGB_OLED_LG.ccss on a
  # colorimeter that has no Colorimeter Calibration Spectral Sample
  # capability) or when spotread simply ignores an unsupported option.
  # Without this, the loop runs the full 120s before timing out, and 3
  # attempts => ~6 minutes of "Initializing meter..." before the series
  # errors out. See meter-selection-empty-port-bug-2026-06-29.md.
  if echo "$CLEAN_OUT" | grep -qiE "doesn't have|does not support|instrument doesn't support|Display/calibration type ignored|no suitable|not supported|Colorimeter Calibration Spectral Sample"; then
   break
  fi
  sleep 0.5
  WAITED=$((WAITED + 1))
 done

 if sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep -q "to take a reading:"; then
  # Success
  break
 fi

 # Failure path — tear down this attempt
 DBGOUT=$(head -c 400 "$OUTFILE" 2>/dev/null | tr '"' "'" | tr '\n' ' ' | tr '\r' ' ')
 printf "Q" >&3 2>/dev/null; exec 3>&- 2>/dev/null
 METER_SERIES_FD_OPEN=0
 kill -9 "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null
 rm -f "$OUTFILE" "$CMDPIPE"

 # Meter-model mismatch is not recoverable by retrying: the requested flags
 # (e.g. -X CCSS) are simply incompatible with the meter at this port. Skip
 # straight to the error path so the operator doesn't wait 6 minutes for 3
 # identical retries. Mirrors the 2026-06-29 series hang (CCSS on a
 # colorimeter); see meter-selection-empty-port-bug-2026-06-29.md.
 if echo "$DBGOUT" | grep -qiE "doesn't have|does not support|instrument doesn't support|Display/calibration type ignored|no suitable|not supported|Colorimeter Calibration Spectral Sample"; then
  write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter does not support requested mode","debug":"$DBGOUT","readings":[]}
EOJSON
  pkill -9 -x spotread 2>/dev/null
 pkill -9 -x spotread_sim 2>/dev/null
  exit 1
 fi

 if (( INIT_ATTEMPT < MAX_INIT_ATTEMPTS )); then
  write_state_json << EOJSON
  {"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Connecting to meter...","readings":[]}
EOJSON
  # Force full cleanup and invalidate port cache before retrying.
  meter_full_cleanup
  rm -f /tmp/spotread_port_cache 2>/dev/null
  pkill -9 -x spotread 2>/dev/null
 pkill -9 -x spotread_sim 2>/dev/null
  sleep 2
  PORT_NUM=$(find_port "$METER_PORT")
  continue
 fi

 # All attempts exhausted — report error
 write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Meter init failed","debug":"$DBGOUT","readings":[]}
EOJSON
 pkill -9 -x spotread 2>/dev/null
 pkill -9 -x spotread_sim 2>/dev/null
 exit 1
done

# Refresh rate calibration: some spotread builds keep rewriting the same
# prompt line instead of emitting a second prompt, so don't wait for the prompt
# count to increase here or startup can deadlock.
CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
if (( REFRESH_CAL_DONE == 0 )) && refresh_cal_prompt "$CLEAN_OUT"; then
 post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
 sleep 2
 printf " " >&3
 sleep 2
fi

series_stop_requested && series_cancel_exit
if [[ ( "$REQUIRE_DEVICE_READY" == "1" && "$WHITE_REF_DONE" == "1" ) || "$DARK_CAL_DONE" == "1" ]]; then
 # Only re-prompt "aim at the screen" when a white-tile calibration actually
 # happened this startup -- the meter was on the tile and must be moved back to
 # the screen. When no calibration was needed (cal reused via -N, meter never
 # left the screen) skip this step entirely so no wizard appears. The startup
 # wait loop above already shows "Connecting to meter..." (the preparing popup)
 # and surfaces the calibrate_tile wizard only when spotread requests it.
 series_setup_step "position_screen" "Calibration complete. Aim the meter at where the test patches appear on the screen, then click Ready."
fi
if [[ "$REQUIRE_DEVICE_READY" == "1" || "${METER_USB_ID,,}" == "085c:0a00" || "${METER_USB_ID,,}" == "085c:0500" ]]; then
 touch "$SPECTRO_STARTUP_MARKER" 2>/dev/null || true
fi
INITIAL_READY_PENDING=0

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
  xyz_part=$(echo "$result_line" | sed 's/.*XYZ:[[:space:]]*//' | sed 's/,.*//')
  X=$(echo "$xyz_part" | awk '{print $1}')
  Y=$(echo "$xyz_part" | awk '{print $2}')
  Z=$(echo "$xyz_part" | awk '{print $3}')
  X=$(number_token "$X")
  Y=$(number_token "$Y")
  Z=$(number_token "$Z")
  if [[ "$result_line" == *"Yxy:"* ]]; then
   yxy_part=$(echo "$result_line" | sed 's/.*Yxy:[[:space:]]*//')
   lum=$(echo "$yxy_part" | awk '{print $1}')
   x_chr=$(echo "$yxy_part" | awk '{print $2}')
   y_chr=$(echo "$yxy_part" | awk '{print $3}')
   lum=$(number_token "$lum")
   x_chr=$(number_token "$x_chr")
   y_chr=$(number_token "$y_chr")
  fi
  if ! is_number "$X" || ! is_number "$Y" || ! is_number "$Z"; then
   echo "[$(date '+%H:%M:%S.%3N')] parse failed: missing XYZ result=$(printf '%s' "$result_line" | cut -c1-240)" >> /tmp/meter_series_debug.log
   return 1
  fi
  if ! is_number "$lum" || ! is_number "$x_chr" || ! is_number "$y_chr"; then
   # Some spotread builds omit Yxy in continuous mode. Derive it from XYZ so
   # valid meter reads still plot instead of becoming metadata-only entries.
   local derived
   derived=$(awk -v X="$X" -v Y="$Y" -v Z="$Z" 'BEGIN {
    sum = X + Y + Z
    if (sum > 0) printf "%.10g %.10g %.10g", Y, X / sum, Y / sum
    else printf "%.10g 0 0", Y
   }')
   lum=$(echo "$derived" | awk '{print $1}')
   x_chr=$(echo "$derived" | awk '{print $2}')
   y_chr=$(echo "$derived" | awk '{print $3}')
  fi
  if ! is_number "$lum" || ! is_number "$x_chr" || ! is_number "$y_chr"; then
   echo "[$(date '+%H:%M:%S.%3N')] parse failed: missing Yxy result=$(printf '%s' "$result_line" | cut -c1-240)" >> /tmp/meter_series_debug.log
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

nonblack_zero_reading() {
 local reading="$1" ire="$2" r="$3" g="$4" b="$5"
 # A black target is expected to read ~0; do not treat its zero reading as a
 # meter failure. Check IRE (the 0% greyscale step sends the limited-range
 # black code, e.g. 64, not r=g=b=0, so the r=g=b=0 test below alone misses it).
 # An EMPTY or non-numeric IRE means "unspecified", NOT 0: feeding it straight
 # to awk made ire+0 collapse to 0, which exempted the patch and silently
 # disabled this guard for it. The series loop validates IRE before it gets
 # here, so this is belt-and-braces, but the helper must not be the weak link.
 if [[ "$ire" =~ ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
  awk -v ire="$ire" 'BEGIN { exit !(ire+0 <= 0) }' && return 1
 fi
 awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN { exit !((r+0)==0 && (g+0)==0 && (b+0)==0) }' && return 1
 local X Y Z lum
 X=$(printf '%s' "$reading" | sed -n 's/.*"X":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 Y=$(printf '%s' "$reading" | sed -n 's/.*"Y":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 Z=$(printf '%s' "$reading" | sed -n 's/.*"Z":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 lum=$(printf '%s' "$reading" | sed -n 's/.*"luminance":[[:space:]]*\([-+0-9.eE]*\).*/\1/p')
 awk -v X="$X" -v Y="$Y" -v Z="$Z" -v lum="$lum" '
  function abs(v) { return v < 0 ? -v : v }
  BEGIN {
   if (X == "" || Y == "" || Z == "" || lum == "") exit 1
   exit !((abs(X+0) < 1e-12) && (abs(Y+0) < 1e-12) && (abs(Z+0) < 1e-12) && (abs(lum+0) < 1e-12))
  }'
}

# Catch a successful-looking measurement that cannot plausibly belong to the
# displayed HDR profiling patch.  A renderer/update transient can return finite
# XYZ from a much darker frame, so the all-zero guard cannot identify it.  For
# patches whose three channels are all at least 65% drive, compare against the
# repeated white measurements at the start of the same series.  Falling below
# 20% of that white is intentionally a very wide gate: normal tone mapping,
# gamut differences and OLED power limiting remain valid, while a stale/dark
# frame such as 86 cd/m2 between 1000 cd/m2 neighbours is re-displayed once.
implausibly_dim_hdr_profile_reading() {
 local reading="$1" r="$2" g="$3" b="$4" input_max="$5" name="$6"
 [[ "$SIGNAL_MODE" == "hdr10" ]] || return 1
 [[ "$SERIES_ID" == colors_* && "$name" == ICC\ * ]] || return 1
 READING_JSON="$reading" R_CODE="$r" G_CODE="$g" B_CODE="$b" INPUT_MAX_VALUE="$input_max" \
 STATE_FILE_VALUE="$STATE_FILE" "${PYTHON_BIN:-python}" - <<'PY' 2>/dev/null
import json, os, sys

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

def number(value):
    try:
        value = float(value)
    except Exception:
        return None
    return value if finite(value) else None

try:
    maximum = float(os.environ.get("INPUT_MAX_VALUE", "0"))
    channels = [float(os.environ.get(key, "0")) for key in ("R_CODE", "G_CODE", "B_CODE")]
    reading = json.loads(os.environ.get("READING_JSON", "") or "{}")
except Exception:
    raise SystemExit(1)
if maximum <= 0 or min(channels) / maximum < 0.65:
    raise SystemExit(1)
measured_y = number(reading.get("luminance", reading.get("Y")))
if measured_y is None or measured_y < 0:
    raise SystemExit(1)

try:
    with open(os.environ.get("STATE_FILE_VALUE", "")) as fh:
        state = json.load(fh)
except Exception:
    raise SystemExit(1)

white_values = []
for row in state.get("readings", []) if isinstance(state, dict) else []:
    try:
        row_max = float(row.get("input_max", maximum) or maximum)
        rc, gc, bc = (float(row.get(key)) for key in ("r_code", "g_code", "b_code"))
    except Exception:
        continue
    if row_max <= 0 or min(rc, gc, bc) / row_max < 0.95:
        continue
    y = number(row.get("luminance", row.get("Y")))
    if y is not None and y > 0:
        white_values.append(y)
if not white_values:
    raise SystemExit(1)
white_values.sort()
white_y = white_values[len(white_values) // 2]
raise SystemExit(0 if measured_y < white_y * 0.20 else 1)
PY
}

# Convert a persistent all-zero parsed reading into an explicit measured-zero
# result. nonblack_zero_reading only fires on a SUCCESSFULLY PARSED all-zero
# XYZ: an instrument that failed to read produces no parsed result at all and
# is handled by the separate no_reading path. Once the retries have
# re-displayed the patch and re-read it, a persistent exact zero is a real
# measurement of a crushed output, so it is recorded rather than discarded.
mark_measured_zero_reading() {
 local reading="$1" retries="${2:-0}"
 READING_JSON="$reading" ZERO_RETRIES="$retries" "${PYTHON_BIN:-python}" - <<'PY'
import json, os, sys

try:
    rd = json.loads(os.environ.get("READING_JSON", "") or "{}")
except Exception:
    sys.exit(1)
if not isinstance(rd, dict):
    sys.exit(1)

for key in ("X", "Y", "Z", "luminance"):
    rd[key] = 0.0
# A zero reading carries no chromaticity; leave x/y absent rather than 0,0.
rd.pop("x", None)
rd.pop("y", None)
rd["measured_zero"] = 1
try:
    rd["zero_read_retries"] = int(os.environ.get("ZERO_RETRIES", "0") or 0)
except Exception:
    pass
# It is a measurement, not an error.
rd.pop("error", None)
rd.pop("reason", None)
sys.stdout.write(json.dumps(rd))
PY
}

normalize_oled_zero_black_reading() {
 local reading="$1"
 READING_JSON="$reading" DISPLAY_TYPE_VALUE="$DISPLAY_TYPE" CCSS_FILE_VALUE="${CCSS_FILE:-}" "${PYTHON_BIN:-python}" - <<'PY'
import json, os, sys

def finite(value):
    return value == value and value not in (float("inf"), float("-inf"))

try:
    rd = json.loads(os.environ.get("READING_JSON", "") or "{}")
except Exception:
    sys.exit(1)

display_type = str(os.environ.get("DISPLAY_TYPE_VALUE", "") or rd.get("display_type", "")).lower()
ccss_file = str(os.environ.get("CCSS_FILE_VALUE", "") or rd.get("ccss_file", "")).lower()
is_oled = "oled" in display_type or "oled" in ccss_file
if not is_oled:
    sys.exit(1)
if str(rd.get("series_type", "")).lower() not in ("", "greyscale"):
    sys.exit(1)

def num(value):
    try:
        n = float(value)
        return n if finite(n) else None
    except Exception:
        return None

name = str(rd.get("name", "")).strip().lower()
ire_values = [num(rd.get(key)) for key in ("ire", "nominal_ire", "plot_ire", "stimulus")]
is_zero = name in ("0%", "black") or any(value is not None and abs(value) < 0.05 for value in ire_values)
target_yn = num(rd.get("target_Yn"))
if not is_zero or (target_yn is not None and abs(target_yn) > 1e-9):
    sys.exit(1)

for src, dst in (
    ("X", "raw_X"), ("Y", "raw_Y"), ("Z", "raw_Z"),
    ("x", "raw_x"), ("y", "raw_y"), ("luminance", "raw_luminance"),
):
    if src in rd and dst not in rd:
        rd[dst] = rd[src]

rd["X"] = 0
rd["Y"] = 0
rd["Z"] = 0
rd["luminance"] = 0
rd.pop("x", None)
rd.pop("y", None)
rd["synthetic_black"] = True
rd["normalized_black"] = True
rd["black_normalization_reason"] = "sdr_oled_series_zero_target"
print(json.dumps(rd, separators=(",", ":")))
PY
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

 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y (displaying)","readings":[]}
EOJSON

	 series_stop_requested && series_cancel_exit
	 post_patch "$WHITE_CODE" "$WHITE_CODE" "$WHITE_CODE" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
	 if should_apply_fresh_dv_first_white_warmup; then
	  sleep "$FRESH_DV_FIRST_WHITE_EXTRA_SEC"
	  post_patch "$WHITE_CODE" "$WHITE_CODE" "$WHITE_CODE" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
	 fi
	 sleep "$PATTERN_DELAY_SEC"
	 PREREAD_DELAY="$DELAY_SEC"
	 PREREAD_DELAY=$(python -c "print(float('$PREREAD_DELAY') + $FIRST_STEP_EXTRA_SEC)" 2>/dev/null)
 if ! maybe_wait_for_initial_ready 0 "Reading 100% white for target Y"; then
  sleep "$PREREAD_DELAY"
 fi

 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y (reading)","readings":[]}
EOJSON

 PREV_COUNT=$(count_results)
 DEBUG_LOG="/tmp/white_read_debug_$$.log"
 echo "[$(date '+%H:%M:%S')] Starting white pre-read: PREV_COUNT=$PREV_COUNT, OUTFILE=$OUTFILE" > "$DEBUG_LOG"
 
 SCAN_OFFSET=$(output_size)
 printf " " >&3
 READ_START=$SECONDS
 GOT_RESULT=false
 ITERATIONS=0
 
 while (( SECONDS - READ_START < 20 )); do
  series_stop_requested && series_cancel_exit
  CUR_COUNT=$(count_results)
  ITERATIONS=$((ITERATIONS + 1))
  echo "[$(date '+%H:%M:%S.%3N')] Iteration $ITERATIONS (elapsed $((SECONDS - READ_START))s): PREV_COUNT=$PREV_COUNT CUR_COUNT=$CUR_COUNT" >> "$DEBUG_LOG"
  if (( CUR_COUNT > PREV_COUNT )); then
   GOT_RESULT=true
   echo "[$(date '+%H:%M:%S')] GOT_RESULT=true at iteration $ITERATIONS after $((SECONDS - READ_START))s" >> "$DEBUG_LOG"
   break
  fi
  NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
  if [[ -n "$NEW_OUTPUT" ]]; then
   CUR_SIZE=$(output_size)
   if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
    echo "[$(date '+%H:%M:%S')] Manual prompt detected during white pre-read: $PROMPT_REASON" >> "$DEBUG_LOG"
    if ! handle_series_manual_prompt "0" "Reading 100% white for target Y" "$PROMPT_REASON"; then
     break
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
  PARSED=$(parse_latest_result)
  echo "[$(date '+%H:%M:%S')] PARSED=(${#PARSED} chars) = $PARSED" >> "$DEBUG_LOG"
  if [[ -n "$PARSED" ]]; then
   WHITE_READING=$(python -c "
import json
r=json.loads('''$PARSED''')
r['ire']=100
r['name']='White Ref'
r['r_code']=$WHITE_CODE
r['g_code']=$WHITE_CODE
r['b_code']=$WHITE_CODE
print(json.dumps(r))
" 2>/dev/null || echo "null")
   echo "[$(date '+%H:%M:%S')] WHITE_READING set successfully (${#WHITE_READING} chars)" >> "$DEBUG_LOG"
  else
   echo "[$(date '+%H:%M:%S')] PARSED was empty, WHITE_READING stays null" >> "$DEBUG_LOG"
  fi
 else
  echo "[$(date '+%H:%M:%S')] GOT_RESULT was false, WHITE_READING stays null" >> "$DEBUG_LOG"
 fi
 
 echo "[$(date '+%H:%M:%S')] Final WHITE_READING=$WHITE_READING" >> "$DEBUG_LOG"
 cat "$DEBUG_LOG" >> /tmp/white_read_series.log 2>/dev/null

 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":0,"total_steps":$TOTAL,"current_name":"Reading 100% white for target Y","readings":[],"white_reading":$WHITE_READING,"debug":{"iterations":$ITERATIONS,"elapsed":$ELAPSED,"got_result":$GOT_RESULT}}
EOJSON
fi

if [[ "$WHITE_READING" != "null" ]]; then
 WHITE_REFERENCE_Y=$(reading_luminance_json "$WHITE_READING" 2>/dev/null || true)
 if [[ -n "$WHITE_REFERENCE_Y" ]]; then
  apply_series_white_reference_to_steps "$WHITE_REFERENCE_Y" || true
 fi
fi

READINGS=""
READING_COUNT=0
START_INDEX=0
DV_ABSOLUTE_TARGETS_APPLIED=0

# The DV pre-read above is the actual White chart reference. Reuse it as the
# first series reading so DV Colors/Sat Sweep do not immediately measure the
# same white step a second time.
if series_uses_initial_white_reference && [[ "$WHITE_READING" != "null" ]] && (( TOTAL > 0 )); then
 FIRST_IRE=$(get_step_field 0 ire)
 FIRST_NAME=$(get_step_field 0 name)
 FIRST_READING=$(build_step_reading_json 0 "$WHITE_READING" 2>/dev/null || echo "")
 if [[ -n "$FIRST_READING" ]]; then
  READINGS="$FIRST_READING"
  READING_COUNT=1
  START_INDEX=1
  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
 fi
fi

for (( i=START_INDEX; i<TOTAL; i++ )); do
	 series_stop_requested && series_cancel_exit
	 R=$(get_step_field $i r)
	 G=$(get_step_field $i g)
	 B=$(get_step_field $i b)
	 INPUT_MAX=$(get_step_field $i input_max)
	 [[ -z "$INPUT_MAX" ]] && INPUT_MAX=255
	 STEP_PATCH_SIZE=$(get_step_field $i patch_size)
	 if ! is_number "$STEP_PATCH_SIZE" || ! awk "BEGIN { exit !($STEP_PATCH_SIZE >= 1 && $STEP_PATCH_SIZE <= 100) }" 2>/dev/null; then
	  STEP_PATCH_SIZE="$PATCH_SIZE"
	 fi
	 READ_DELAY_MS=$(get_step_field $i read_delay_ms)
	 IRE=$(get_step_field $i ire)
	 NAME=$(get_step_field $i name)
	 SERIES_WHITE_REFERENCE=$(get_step_field $i series_white_reference)
	 STEP_NUM=$((i + 1))
 if ! [[ "$R" =~ ^[0-9]+$ && "$G" =~ ^[0-9]+$ && "$B" =~ ^[0-9]+$ && "$INPUT_MAX" =~ ^[0-9]+$ ]] || ! is_number "$IRE" || [[ -z "$NAME" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] invalid series step: index=$i r=$R g=$G b=$B ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
  BAD_STEP_MESSAGE=$(json_escape "Invalid series step $i")
  write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$BAD_STEP_MESSAGE","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
 series_quit_spotread
 rm -f "$READY_FILE" "$STOP_FILE" 2>/dev/null || true
 exit 1
 fi

 if ! ensure_spotread_low_light_for_step "$i"; then
  LOW_LIGHT_ERROR=$(json_escape "Meter averaging mode change failed at step $STEP_NUM")
  write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$LOW_LIGHT_ERROR","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
  series_quit_spotread
  rm -f "$READY_FILE" "$STOP_FILE" 2>/dev/null || true
  exit 1
 fi

 # Update state: displaying
 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (displaying)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

	 PATCH_INSERT_FIRED=0
	 maybe_pattern_insert_before_step "$i" "$IRE"

	 # Display pattern
		 post_patch "$R" "$G" "$B" "$STEP_PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	 if (( PATCH_INSERT_FIRED == 1 )); then
	  # The pattern endpoint acknowledges notification, not presentation. Give
	  # the renderer and panel a few frames to leave black before meter timing
	  # begins, matching the guarded AutoCal insertion path.
	  sleep 0.4
	  PATCH_INSERT_FIRED=0
	 fi

 # DV greyscale derives chart/patch targets from the first 100% read. Warm
 # that first white in place and do not replace it with a different final
 # read after the sweep.
 if (( i == 0 )) && [[ "$IRE" == "100" ]]; then
  if series_uses_first_white_warmup; then
   sleep "$DV_GREYSCALE_FIRST_WHITE_WARMUP_SEC"
	  post_patch "$R" "$G" "$B" "$STEP_PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	  elif should_apply_fresh_dv_first_white_warmup; then
	   sleep "$FRESH_DV_FIRST_WHITE_EXTRA_SEC"
		  post_patch "$R" "$G" "$B" "$STEP_PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	  fi
	 fi
	 sleep "$PATTERN_DELAY_SEC"

	 # Settle delay — use the user-configured value by default, but allow
	 # per-step overrides for very dark or otherwise slow-settling patches.
	 STEP_DELAY="$DELAY_SEC"
	 STEP_DELAY_EXPLICIT=0
	 if [[ "$READ_DELAY_MS" =~ ^[0-9]+$ ]] && (( READ_DELAY_MS > 0 )); then
	  STEP_DELAY=$(python -c "print(float('$READ_DELAY_MS')/1000.0)" 2>/dev/null)
	  STEP_DELAY_EXPLICIT=1
	 fi
	 if (( i == 0 && STEP_DELAY_EXPLICIT == 0 )); then
	  STEP_DELAY=$(python -c "print(float('$STEP_DELAY') + $FIRST_STEP_EXTRA_SEC)" 2>/dev/null)
	 fi
 if ! maybe_wait_for_initial_ready "$STEP_NUM" "$NAME"; then
  sleep "$STEP_DELAY"
 fi

 # Update state: reading
 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (reading)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

 # Near-black reads can take much longer than mid/high greys. Match the
 # manual-read tolerance here so the low end does not time out prematurely.
 READ_TIMEOUT=$(read_timeout_seconds "$IRE")

 # Trigger reading: send space
 PREV_COUNT=$(count_results)
 SCAN_OFFSET=$(output_size)
 printf " " >&3

 # Wait for result. Retry once on spotread's "communication problem": a
 # transient integration miss or USB hiccup is far more common than a
 # permanent comm failure during a series read, and aborting the whole
 # run on the first comm problem would discard every good read before
 # it. Retry once with +15s on the timeout, then surface the error if
 # the retry also fails. (The earlier fail-fast path that aborted
 # immediately was reverted on 2026-06-29 because a Yellow 25% comm
 # problem in a 25-step sat sweep killed 21 already-good reads -- see
 # series-comm-error-must-retry-not-failfast memory note.)
 READ_START=$SECONDS
 GOT_RESULT=false
 RETRIED_COMM=0
 COMM_RETRY_SEEN=0
 while (( SECONDS - READ_START < READ_TIMEOUT )); do
  series_stop_requested && series_cancel_exit
  CUR_COUNT=$(count_results)
  if (( CUR_COUNT > PREV_COUNT )); then
   GOT_RESULT=true
   break
  fi
  NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
  if [[ -n "$NEW_OUTPUT" ]]; then
   CUR_SIZE=$(output_size)
   if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
    echo "[$(date '+%H:%M:%S.%3N')] spotread communication problem during read - retrying once (+15s) step=$STEP_NUM ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
    printf " " >&3
    RETRIED_COMM=1
    COMM_RETRY_SEEN=1
    READ_TIMEOUT=$((READ_TIMEOUT + 15))
    SCAN_OFFSET=$(output_size)
    continue
   fi
   if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
    echo "[$(date '+%H:%M:%S.%3N')] manual prompt: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
    if ! handle_series_manual_prompt "$STEP_NUM" "$NAME" "$PROMPT_REASON"; then
     break
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
  PARSED=$(parse_latest_result)
  if [[ -n "$PARSED" ]]; then
   READING=$(build_step_reading_json "$i" "$PARSED" 2>/dev/null)
  fi
 fi

 if [[ -n "$READING" ]] && implausibly_dim_hdr_profile_reading "$READING" "$R" "$G" "$B" "$INPUT_MAX" "$NAME"; then
  echo "[$(date '+%H:%M:%S.%3N')] implausibly dim HDR profile read: step=$STEP_NUM rgb=$R/$G/$B name=$NAME; redisplaying once" >> /tmp/meter_series_debug.log
  # Reuse the established no-reading recovery path below.  Marking this as a
  # communication-style transient guarantees one redisplay/read attempt even
  # when ordinary no-reading retries are disabled.
  READING=""
  COMM_RETRY_SEEN=1
 fi

 if [[ -z "$READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] read timeout: step=$STEP_NUM ire=$IRE timeout=${READ_TIMEOUT}s name=$NAME" >> /tmp/meter_series_debug.log
  PATCH_NO_READING_RETRIES=$NO_READING_RETRIES
  # A communication error means spotread rejected the trigger rather than
  # measuring the patch. Give that patch one clean redisplay/read cycle. Keep
  # ordinary timeouts at zero retries so an unresponsive meter cannot add a
  # minute to every patch in a finite series.
  if (( COMM_RETRY_SEEN == 1 && PATCH_NO_READING_RETRIES < 1 )); then
   PATCH_NO_READING_RETRIES=1
  fi
  for (( no_reading_retry=1; no_reading_retry<=PATCH_NO_READING_RETRIES; no_reading_retry++ )); do
   echo "[$(date '+%H:%M:%S.%3N')] no reading retry: step=$STEP_NUM ire=$IRE retry=$no_reading_retry/$PATCH_NO_READING_RETRIES name=$NAME" >> /tmp/meter_series_debug.log
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (retry reading $no_reading_retry/$PATCH_NO_READING_RETRIES)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
	   post_patch "$R" "$G" "$B" "$STEP_PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	   sleep "$PATTERN_DELAY_SEC"
	   sleep "$STEP_DELAY"
   PREV_COUNT=$(count_results)
   SCAN_OFFSET=$(output_size)
   printf " " >&3
   READ_START=$SECONDS
   RETRY_TIMEOUT=$(read_timeout_seconds "$IRE")
   GOT_RETRY=false
   RETRIED_COMM=0
   while (( SECONDS - READ_START < RETRY_TIMEOUT )); do
    series_stop_requested && series_cancel_exit
    CUR_COUNT=$(count_results)
    if (( CUR_COUNT > PREV_COUNT )); then
     GOT_RETRY=true
     break
    fi
    NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
    if [[ -n "$NEW_OUTPUT" ]]; then
     CUR_SIZE=$(output_size)
     if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
      echo "[$(date '+%H:%M:%S.%3N')] spotread communication problem during no-reading retry - retrying once (+15s) step=$STEP_NUM ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
      printf " " >&3
      RETRIED_COMM=1
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 15))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
      echo "[$(date '+%H:%M:%S.%3N')] manual prompt during no reading retry: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
      if ! handle_series_manual_prompt "$STEP_NUM" "$NAME" "$PROMPT_REASON"; then
       break
      fi
      printf " " >&3
      READ_START=$SECONDS
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 30))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     SCAN_OFFSET="$CUR_SIZE"
    fi
    sleep 0.3
   done
   if $GOT_RETRY; then
    PARSED=$(parse_latest_result)
    if [[ -n "$PARSED" ]]; then
     READING=$(build_step_reading_json "$i" "$PARSED" 2>/dev/null)
    fi
   fi
   if [[ -n "$READING" ]]; then
    echo "[$(date '+%H:%M:%S.%3N')] no reading retry recovered: step=$STEP_NUM ire=$IRE retry=$no_reading_retry name=$NAME" >> /tmp/meter_series_debug.log
    break
   fi
   echo "[$(date '+%H:%M:%S.%3N')] no reading retry failed: step=$STEP_NUM ire=$IRE retry=$no_reading_retry timeout=${RETRY_TIMEOUT}s name=$NAME" >> /tmp/meter_series_debug.log
  done
 fi

 if [[ -n "$READING" ]] && nonblack_zero_reading "$READING" "$IRE" "$R" "$G" "$B"; then
  ZERO_RESULT_LINE=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r' | grep "Result is XYZ:" | tail -1 | cut -c1-200)
  echo "[$(date '+%H:%M:%S.%3N')] zero read guard: step=$STEP_NUM ire=$IRE name=$NAME parsed all-zero XYZ/luminance result=$(printf '%s' "$ZERO_RESULT_LINE" | tr '"' "'")" >> /tmp/meter_series_debug.log
  ZERO_RETRY_READING=""
  for (( zero_retry=1; zero_retry<=ZERO_READ_RETRIES; zero_retry++ )); do
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (redisplaying after zero read $zero_retry/$ZERO_READ_RETRIES)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
	   post_patch "$R" "$G" "$B" "$STEP_PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	   sleep "$PATTERN_DELAY_SEC"
	   sleep "$STEP_DELAY"
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (retry reading $zero_retry/$ZERO_READ_RETRIES)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
   PREV_COUNT=$(count_results)
   SCAN_OFFSET=$(output_size)
   printf " " >&3
   READ_START=$SECONDS
   RETRY_TIMEOUT=$(read_timeout_seconds "$IRE")
   GOT_RETRY=false
   RETRIED_COMM=0
   while (( SECONDS - READ_START < RETRY_TIMEOUT )); do
    series_stop_requested && series_cancel_exit
    CUR_COUNT=$(count_results)
    if (( CUR_COUNT > PREV_COUNT )); then
     GOT_RETRY=true
     break
    fi
    NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
    if [[ -n "$NEW_OUTPUT" ]]; then
     CUR_SIZE=$(output_size)
     if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
      echo "[$(date '+%H:%M:%S.%3N')] spotread communication problem during zero retry - retrying once (+15s) step=$STEP_NUM ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
      printf " " >&3
      RETRIED_COMM=1
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 15))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
      echo "[$(date '+%H:%M:%S.%3N')] manual prompt during zero retry: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
      if ! handle_series_manual_prompt "$STEP_NUM" "$NAME" "$PROMPT_REASON"; then
       break
      fi
      printf " " >&3
      READ_START=$SECONDS
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 30))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     SCAN_OFFSET="$CUR_SIZE"
    fi
    sleep 0.3
   done
   if $GOT_RETRY; then
    PARSED=$(parse_latest_result)
    if [[ -n "$PARSED" ]]; then
     ZERO_RETRY_READING=$(build_step_reading_json "$i" "$PARSED" 2>/dev/null)
    fi
   fi
   if [[ -n "$ZERO_RETRY_READING" ]] && ! nonblack_zero_reading "$ZERO_RETRY_READING" "$IRE" "$R" "$G" "$B"; then
    echo "[$(date '+%H:%M:%S.%3N')] zero read guard recovered: step=$STEP_NUM ire=$IRE retry=$zero_retry name=$NAME" >> /tmp/meter_series_debug.log
    READING="$ZERO_RETRY_READING"
    break
   fi
   ZERO_RETRY_READING=""
  done
  if nonblack_zero_reading "$READING" "$IRE" "$R" "$G" "$B"; then
   # Keep the measurement. Discarding it removed the node from every chart and
   # report, which hid exactly the defect being measured: a panel whose low end
   # is crushed to black genuinely emits no light at these stimuli, and that
   # zero is the result the operator needs to see.
   echo "[$(date '+%H:%M:%S.%3N')] zero read guard: recording measured zero step=$STEP_NUM ire=$IRE retries=$ZERO_READ_RETRIES name=$NAME" >> /tmp/meter_series_debug.log
   MEASURED_ZERO_READING=$(mark_measured_zero_reading "$READING" "$ZERO_READ_RETRIES" 2>/dev/null || true)
   if [[ -n "$MEASURED_ZERO_READING" ]]; then
    READING="$MEASURED_ZERO_READING"
   fi
  fi
 fi

 NORMALIZED_READING=$(normalize_oled_zero_black_reading "$READING" 2>/dev/null || true)
 if [[ -n "$NORMALIZED_READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] oled zero black normalized: step=$STEP_NUM ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
  READING="$NORMALIZED_READING"
 fi

 if [[ -z "$READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] read timeout final: step=$STEP_NUM ire=$IRE retries=$PATCH_NO_READING_RETRIES timeout=${READ_TIMEOUT}s name=$NAME" >> /tmp/meter_series_debug.log
  READING=$(build_step_reading_json "$i" "{\"error\":\"no_reading\"}" 2>/dev/null || echo "{\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B,\"error\":\"no_reading\"}")
 fi

 # Generic colour/profile series can carry a leading reference-only white
 # patch. Publish it through white_reading immediately so target luminance is
 # fixed before the first scored series patch is drawn.
 if [[ "$SERIES_WHITE_REFERENCE" == "True" || "$SERIES_WHITE_REFERENCE" == "true" || "$SERIES_WHITE_REFERENCE" == "1"
       || "${NAME,,}" == "white ref" || "${NAME,,}" == "white" || "${NAME,,}" == "100% white" ]]; then
  WHITE_READING="$READING"
  WHITE_REFERENCE_Y=$(reading_luminance_json "$WHITE_READING" 2>/dev/null || true)
  if [[ -n "$WHITE_REFERENCE_Y" ]]; then
   apply_series_white_reference_to_steps "$WHITE_REFERENCE_Y" || true
  fi
 fi

 # Accumulate
 if [[ $READING_COUNT -gt 0 ]]; then
  READINGS="$READINGS,$READING"
 else
  READINGS="$READING"
 fi
 READING_COUNT=$((READING_COUNT + 1))

 if [[ "$DV_ABSOLUTE_TARGETS_APPLIED" == "0" ]] && dv_absolute_greyscale_series_active && is_number "$IRE" && float_le 99.999 "$IRE"; then
  WHITE_Y=$(reading_luminance_json "$READING" 2>/dev/null || true)
  if [[ -n "$WHITE_Y" ]] && apply_dv_absolute_greyscale_targets "$WHITE_Y"; then
   DV_ABSOLUTE_TARGETS_APPLIED=1
   WHITE_READING="$READING"
   echo "[$(date '+%H:%M:%S.%3N')] DV absolute greyscale targets applied from white_y=$WHITE_Y" >> /tmp/meter_series_debug.log
  fi
 fi

 # Update state
 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
done

# Greyscale uses the first 100% read as the live white reference while the
# sweep is running, then refreshes white once more at the end when marked so
# the saved 100% result reflects the warmed-up display.
if series_requires_final_white_refresh && (( TOTAL > 0 )); then
	FIRST_R=$(get_step_field 0 r)
	FIRST_G=$(get_step_field 0 g)
	FIRST_B=$(get_step_field 0 b)
	FIRST_INPUT_MAX=$(get_step_field 0 input_max)
	[[ -z "$FIRST_INPUT_MAX" ]] && FIRST_INPUT_MAX=255
 FIRST_IRE=$(get_step_field 0 ire)
 FIRST_NAME=$(get_step_field 0 name)

 if [[ "$FIRST_R" =~ ^[0-9]+$ && "$FIRST_G" =~ ^[0-9]+$ && "$FIRST_B" =~ ^[0-9]+$ && "$FIRST_IRE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  if ! ensure_spotread_low_light_for_step 0; then
   LOW_LIGHT_ERROR=$(json_escape "Meter averaging mode change failed for final white refresh")
   write_state_json << EOJSON
{"status":"error","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$LOW_LIGHT_ERROR","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
   series_quit_spotread
   rm -f "$READY_FILE" "$STOP_FILE" 2>/dev/null || true
   exit 1
  fi
  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refresh displaying)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

	  maybe_pattern_insert_before_step "$READING_COUNT" "$FIRST_IRE"

		  post_patch "$FIRST_R" "$FIRST_G" "$FIRST_B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$FIRST_INPUT_MAX"
	  sleep "$PATTERN_DELAY_SEC"
	  sleep "$DELAY_SEC"

  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refresh reading)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

  PREV_COUNT=$(count_results)
  SCAN_OFFSET=$(output_size)
  printf " " >&3

  READ_TIMEOUT=$(read_timeout_seconds "$FIRST_IRE")
  READ_START=$SECONDS
  GOT_RESULT=false
  RETRIED_COMM=0
  while (( SECONDS - READ_START < READ_TIMEOUT )); do
   series_stop_requested && series_cancel_exit
   CUR_COUNT=$(count_results)
   if (( CUR_COUNT > PREV_COUNT )); then
    GOT_RESULT=true
    break
   fi
   NEW_OUTPUT=$(clean_output_since "$SCAN_OFFSET")
   if [[ -n "$NEW_OUTPUT" ]]; then
    CUR_SIZE=$(output_size)
    if [[ $RETRIED_COMM -eq 0 && "$NEW_OUTPUT" == *"Spot read failed due to communication problem"* ]]; then
     echo "[$(date '+%H:%M:%S.%3N')] spotread communication problem during refresh reading - retrying once (+15s) step=1 ire=$FIRST_IRE name=$FIRST_NAME (refresh)" >> /tmp/meter_series_debug.log
     printf " " >&3
     RETRIED_COMM=1
     READ_TIMEOUT=$((READ_TIMEOUT + 15))
     SCAN_OFFSET=$(output_size)
     continue
    fi
    if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
    echo "[$(date '+%H:%M:%S.%3N')] manual prompt: step=1 ire=$FIRST_IRE reason=$PROMPT_REASON name=$FIRST_NAME (refresh)" >> /tmp/meter_series_debug.log
	     if ! handle_series_manual_prompt "1" "$FIRST_NAME (refresh)" "$PROMPT_REASON"; then
	      break
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
   PARSED=$(parse_latest_result)
   if [[ -n "$PARSED" ]]; then
    REFRESH_READING=$(build_step_reading_json 0 "$PARSED" 2>/dev/null)
   fi
  fi

  if [[ -n "$REFRESH_READING" ]]; then
   if replace_series_reading "$FIRST_IRE" "$FIRST_NAME" "$REFRESH_READING"; then
    WHITE_READING="$REFRESH_READING"
    write_state_json << EOJSON
  {"status":"running","series_id":"$SERIES_ID","current_step":1,"total_steps":$TOTAL,"current_name":"$FIRST_NAME (refreshed)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
   fi
  fi
 fi
fi

# Quit spotread through the same graceful, read-timeout-aware path used by
# cancellation. Normal completion reaches an idle prompt and exits quickly;
# this also avoids the former unconditional SIGKILL after only 0.5 seconds.
series_quit_spotread

# Restore the companion's meter-alignment target after the series.
if [[ "$PATTERN_PROVIDER" == "companion" ]]; then
 companion_show_alignment
else
 curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
  -d '{"name":"stop"}' >/dev/null 2>&1
fi

# Mark complete
write_state_json << EOJSON
{"status":"complete","series_id":"$SERIES_ID","current_step":$TOTAL,"total_steps":$TOTAL,"current_name":"Done","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

# Cache the 0% IRE measured black from the just-finished series so the
# next series (with target_black_use_measured=true) can stamp the cached
# value onto every step before the 0% reading actually completes in
# the new series. The chart math uses reading.series_target_black_y
# directly, so without the cache the chart sits at 0 nits from series
# start until the 0% reading arrives several seconds later.
# Color format and rgb_quant_range are part of the key because the
# panel-side pipeline maps the same wire code to a different 0% IRE
# black for different (colorimetry, quant-range) combos (the
# 8b-vs-10b-YCbCr-Ltd panel-side divergence).
BLACK_CACHE_DIR="/var/lib/PGenerator/cache"
BLACK_CACHE="$BLACK_CACHE_DIR/last_black_${SIGNAL_MODE}_${INPUT_MAX}_${COLOR_FORMAT}_${TRANSPORT_SIGNAL_RANGE}.json"
if [[ "$SERIES_ID" == greyscale_* ]] \
 && [[ "$SIGNAL_MODE" == "hdr10" || "$SIGNAL_MODE" == "sdr" || "$SIGNAL_MODE" == "hlg" ]] \
 && command -v python >/dev/null 2>&1; then
 mkdir -p "$BLACK_CACHE_DIR" 2>/dev/null || true
 python -c "
import json, os, sys, time
state_file = '$STATE_FILE'
cache_file = '$BLACK_CACHE'
signal_mode = '$SIGNAL_MODE'
input_max = '$INPUT_MAX'
color_format = '$COLOR_FORMAT'
rgb_quant_range = '$TRANSPORT_SIGNAL_RANGE'
try:
    with open(state_file) as f:
        state = json.load(f)
except Exception:
    sys.exit(0)
readings = state.get('readings') or []
# Only a real 0% greyscale result may seed this cache. Profiling steps often
# omit IRE and historically defaulted to zero, which allowed an ICC white read
# to overwrite the black cache. Accept zero luminance too; that is the normal
# result for an OLED and must replace a stale nonzero cache.
black_candidates = []
for r in readings:
    luminance = r.get('luminance')
    if luminance is None or luminance < 0:
        continue
    name = (r.get('name') or '').strip()
    if name == '0%' or r.get('ire') == 0:
        black_candidates.append(luminance)
if black_candidates:
    payload = {
        'source': 'greyscale-0-percent',
        'signal_mode': signal_mode,
        'input_max': input_max,
        'color_format': color_format,
        'rgb_quant_range': rgb_quant_range,
        'luminance': min(black_candidates),
        'ts': int(time.time()),
    }
    tmp = cache_file + '.tmp'
    try:
        with open(tmp, 'w') as f:
            json.dump(payload, f)
        if hasattr(os, 'replace'):
            os.replace(tmp, cache_file)
        else:
            os.rename(tmp, cache_file)
    except Exception:
        pass
" 2>/dev/null || true
fi

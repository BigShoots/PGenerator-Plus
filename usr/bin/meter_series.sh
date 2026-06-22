#!/bin/bash
# meter_series.sh - Background measurement series helper
# Called by PGenerator webui.pm to run a series of pattern+measurement steps
# Uses a SINGLE persistent spotread session across all patches for speed
# Usage: meter_series.sh <series_id> <display_type> <delay_ms> <patch_size> <steps_file> <state_file> [ccss_file] [patch_insert] [refresh_rate] [disable_aio] [signal_mode] [max_luma] [dv_map_mode] [meter_port] [ready_file] [require_device_ready] [pattern_signal_range] [transport_signal_range] [pattern_delay_ms] [patch_insert_patch_enabled] [patch_insert_patch_every] [patch_insert_patch_duration_ms] [patch_insert_patch_level] [patch_insert_time_enabled] [patch_insert_time_frequency_ms] [patch_insert_time_duration_ms] [patch_insert_time_level]

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
# Low-light handler mode (positional arg 28). Passed as an argument rather
# than an env-var prefix so the daemon's sudo NOPASSWD command match for
# "/bin/bash /usr/bin/meter_series.sh *" stays intact. Falls back to the
# LOW_LIGHT_MODE env (legacy) then off. The case statement below consumes it.
LOW_LIGHT_MODE="${28:-${LOW_LIGHT_MODE:-off}}"
# Precomputed pattern-insertion codes (mode-correct). The webui derives them
# from the same closure the greyscale ladder uses, so an insertion patch at
# the user-configured level lands on the same code a step at that stimulus
# would. Positional args 29/30; empty value triggers a legacy linear
# fallback below (older webui binaries). "<code>:<input_max>" colon-joined
# so the daemon's "/usr/bin/meter_series.sh *" arg-count stays minimal.
PATCH_INSERT_PATCH_PRECOMPUTED="${29:-}"
PATCH_INSERT_TIME_PRECOMPUTED="${30:-}"
STOP_FILE="/tmp/meter_series_stop_${SERIES_ID}.signal"
SPOTREAD_BIN="/usr/bin/spotread"
API_BASE="http://127.0.0.1/api"
TMPDIR="/tmp"
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

write_state_json() {
 local payload
 payload=$(cat) || return 1
 series_state_claim_lost && return 1
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

series_quit_spotread() {
 if [[ "${METER_SERIES_FD_OPEN:-0}" == "1" ]]; then
  printf "Q" >&3 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  METER_SERIES_FD_OPEN=0
 fi
 if [[ -n "${BG_PID:-}" ]]; then
  local waited=0
  while (( waited < 20 )) && kill -0 "$BG_PID" 2>/dev/null; do
   sleep 0.1
   waited=$((waited + 1))
  done
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
 series_quit_spotread
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
 curl -s --max-time 8 "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
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
  calibrate_tile|calibrate_retry) ready_reason="calibration_setup" ;;
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

build_step_reading_json() {
 local idx="$1" parsed_json="${2:-}"
 [[ -n "$parsed_json" ]] || parsed_json="{}"
 python - "$idx" "$STEPS_FILE" "$parsed_json" <<'PY'
import json, math, sys

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
	"input_max", "stimulus", "signal_r_pct", "signal_g_pct", "signal_b_pct",
	"signal_mode", "target_gamma", "max_luma", "dv_map_mode",
	"analysis_ire", "target_ire", "transport_stimulus",
	"final_white_refresh",
	"target_x", "target_y", "target_Yn", "target_X", "target_Y", "target_Z",
	"dv_absolute_white_y", "dv_absolute_target_y", "dv_absolute_rolloff_pct",
	"dv_absolute_tunnel_gamma", "dv_absolute_st2084_precomp",
    "series_target_white_y", "lg_target_white_y",
    "series_type", "series_color", "sat_pct", "point_role", "series_mode",
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

apply_dv_absolute_greyscale_codes() {
 local white_y="$1"
 [[ -f "$STEPS_FILE" ]] || return 1
 is_number "$white_y" || return 1
 STEPS_FILE="$STEPS_FILE" WHITE_Y="$white_y" python - <<'PY' 2>/dev/null
import json, math, os, tempfile

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

m1 = 2610.0 / 16384.0
m2 = 2523.0 / 32.0
c1 = 3424.0 / 4096.0
c2 = 2413.0 / 128.0
c3 = 2392.0 / 128.0
dv_tunnel_gamma = 2.2

def pq_decode_normalized(code):
    code = max(0.0, min(1.0, float(code)))
    if code <= 0:
        return 0.0
    p = code ** (1 / m2)
    num = max(p - c1, 0.0)
    den = c2 - c3 * p
    if den <= 0:
        return 10000.0
    return 10000.0 * ((num / den) ** (1 / m1))

def pq_encode_normalized(nits):
    nits = max(0.0, min(10000.0, float(nits)))
    if nits <= 0:
        return 0.0
    linear = nits / 10000.0
    p = linear ** m1
    return ((c1 + c2 * p) / (1 + c3 * p)) ** m2

def percent_from_step(step, channel):
    for key in ("signal_%s_pct" % channel, "stimulus", "analysis_ire", "target_ire", "ire"):
        try:
            value = float(step.get(key))
        except Exception:
            continue
        if finite(value):
            return value
    return 0.0

def code_range_for_step(step):
    return 16, 219

def code_for_absolute_percent(step, percent):
    stim = max(0.0, min(1.0, float(percent) / 100.0))
    min_code, span_code = code_range_for_step(step)
    if stim <= 0:
        return min_code, 0.0
    target_y = min(white_y, pq_decode_normalized(stim))
    encoded = 0.0 if target_y <= 0 else (target_y / white_y) ** (1 / dv_tunnel_gamma)
    code = int(round(min_code + max(0.0, min(1.0, encoded)) * span_code))
    return max(min_code, min(min_code + span_code, code)), target_y

changed = False
for step in steps:
    if not isinstance(step, dict):
        continue
    if str(step.get("series_type", "")).lower() != "greyscale":
        continue
    for channel in ("r", "g", "b"):
        code, target_y = code_for_absolute_percent(step, percent_from_step(step, channel))
        if step.get(channel) != code:
            changed = True
        step[channel] = code
    _, target_y = code_for_absolute_percent(step, percent_from_step(step, "g"))
    step["dv_absolute_white_y"] = white_y
    step["dv_absolute_st2084_precomp"] = True
    step["dv_absolute_target_y"] = target_y
    step["dv_absolute_rolloff_pct"] = pq_encode_normalized(white_y) * 100
    step["dv_absolute_tunnel_gamma"] = dv_tunnel_gamma

if not changed:
    raise SystemExit(0)

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
 # active output mode (SDR/HDR10/DV/HLG). Fall back to the legacy linear
 # 0..255 formula only when the precomputed payload is empty (older webui).
 if [[ -n "$precomputed" && "$precomputed" == *:* ]]; then
  local pre_code="${precomputed%%:*}"
  if is_number "$pre_code"; then
   echo "$pre_code"
   return 0
  fi
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
 echo 255
}

post_insert_patch() {
 local level="${1:-25}" duration_ms="${2:-0}" reason="${3:-patch}" precomputed="${4:-}"
 local code input_max duration_sec
 code=$(patch_insert_code_for_level "$level" "$precomputed")
 input_max=$(patch_insert_input_max_for_level "$precomputed")
 duration_sec=$(milliseconds_to_seconds "$duration_ms")
 echo "[$(date '+%H:%M:%S.%3N')] pattern insertion: reason=$reason level=${level}% code=$code input_max=$input_max duration=${duration_sec}s" >> /tmp/meter_series_debug.log
 post_patch "$code" "$code" "$code" 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$input_max"
 sleep "$duration_sec"
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
ZERO_READ_RETRIES=2
NO_READING_RETRIES=1

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
 [[ "$SIGNAL_MODE" != "dv" ]] && return 0
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

 SR_CMD="$SPOTREAD_BIN -e -y $DISPLAY_TYPE -c $PORT_NUM -x"
 if [[ "$REQUIRE_DEVICE_READY" == "1" && -n "$CCSS_FILE" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] spectrophotometer selected: skipping CCSS ($CCSS_FILE)" >> /tmp/meter_series_debug.log
 fi
 if [[ -n "$CCSS_FILE" && -f "$CCSS_FILE" && "$REQUIRE_DEVICE_READY" != "1" ]]; then
  # Read the actual DISPLAY_TYPE_REFRESH value line, not the KEYWORD declaration.
  # If the field is missing, fall back to the CCSS metadata so OLED/Plasma/CRT
  # profiles don't get treated like generic LCDs (or vice versa).
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
 # Override refresh rate if specified. Passing -Y R:rate makes spotread skip
 # its mandatory 80% white refresh-calibration read (unreliable on a
 # sample-and-hold OLED), so always honour an explicit rate.
 if [[ -n "$REFRESH_RATE" ]]; then
  SR_CMD="$SR_CMD -Y R:$REFRESH_RATE"
 fi
 # Low-light handler (reference-style) flag set. OFF maps to no -Y flag: spotread
 # uses its default adaptive integration. When the handler is ON, the
 # operator-selected a/aa/aaa averaging is used (multiple internal reads).
 # (Refresh-rate calibration is skipped separately via -Y R:rate above.)
 LOW_LIGHT_FLAGS=""
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
 if [[ -n "$LOW_LIGHT_FLAGS" ]]; then
  SR_CMD="$SR_CMD $LOW_LIGHT_FLAGS"
 fi
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
HANDLED_OFFSET=0
 while (( WAITED < 120 )); do
  series_stop_requested && series_cancel_exit
  CLEAN_OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUTFILE" 2>/dev/null | tr -d '\r')
 NEW_OUT=$(clean_output_since "$HANDLED_OFFSET")
 if echo "$CLEAN_OUT" | grep -q "to take a reading:"; then
   break
  fi
 if (( REFRESH_CAL_DONE == 0 )) && echo "$NEW_OUT" | grep -qi "calibrate refresh"; then
  post_patch_timeout 204 204 204 100 "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE"
  sleep 2
  printf " " >&3
  REFRESH_CAL_DONE=1
  HANDLED_OFFSET=$(output_size)
  sleep 2
  WAITED=$((WAITED + 4))
  continue
 fi
 if echo "$NEW_OUT" | grep -qiE 'reading is too low|calibration failed'; then
    series_setup_step "calibrate_retry" "Calibration failed. Re-seat the spectrophotometer flat on its white tile, then click Retry." "Re-calibrating the meter - please wait..."
  printf " " >&3
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

 if (( INIT_ATTEMPT < MAX_INIT_ATTEMPTS )); then
  write_state_json << EOJSON
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
 write_state_json << EOJSON
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
 printf " " >&3
 sleep 2
fi

series_stop_requested && series_cancel_exit
if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
 series_setup_step "position_screen" "Aim the meter at where the test patches appear on the screen, then click Ready."
 INITIAL_READY_PENDING=0
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

normalize_oled_zero_black_reading() {
 local reading="$1"
 READING_JSON="$reading" DISPLAY_TYPE_VALUE="$DISPLAY_TYPE" CCSS_FILE_VALUE="${CCSS_FILE:-}" "${PYTHON_BIN:-python}" - <<'PY'
import json, os, math, sys

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
        return n if math.isfinite(n) else None
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

READINGS=""
READING_COUNT=0
START_INDEX=0
DV_ABSOLUTE_CODES_APPLIED=0

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
	 READ_DELAY_MS=$(get_step_field $i read_delay_ms)
	 IRE=$(get_step_field $i ire)
	 NAME=$(get_step_field $i name)
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

 # Update state: displaying
 write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (displaying)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

	 maybe_pattern_insert_before_step "$i" "$IRE"

	 # Display pattern
		 post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"

 # DV greyscale derives chart/patch targets from the first 100% read. Warm
 # that first white in place and do not replace it with a different final
 # read after the sweep.
 if (( i == 0 )) && [[ "$IRE" == "100" ]]; then
  if series_uses_first_white_warmup; then
   sleep "$DV_GREYSCALE_FIRST_WHITE_WARMUP_SEC"
	  post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
	  elif should_apply_fresh_dv_first_white_warmup; then
	   sleep "$FRESH_DV_FIRST_WHITE_EXTRA_SEC"
		  post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
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

 # Absolute black on emissive displays (OLED/QD-OLED/CRT/plasma) often
 # has no usable meter response. Treat it as a valid 0.0 read immediately so
 # the series continues instead of sitting through a timeout.
 if [[ "$DISPLAY_TYPE" == "c" && "$R" == "$G" && "$G" == "$B" ]] && float_le "$IRE" 0; then
  TS=$(date +%s)
  READING=$(build_step_reading_json "$i" "{\"X\":0,\"Y\":0,\"Z\":0,\"x\":0,\"y\":0,\"luminance\":0.0,\"cct\":0,\"timestamp\":$TS}" 2>/dev/null || echo "")
  if [[ $READING_COUNT -gt 0 ]]; then
   READINGS="$READINGS,$READING"
  else
   READINGS="$READING"
  fi
  READING_COUNT=$((READING_COUNT + 1))
  write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
  continue
 fi

 # Near-black reads can take much longer than mid/high greys. Match the
 # manual-read tolerance here so the low end does not time out prematurely.
 READ_TIMEOUT=$(read_timeout_seconds "$IRE")

 # Trigger reading: send space
 PREV_COUNT=$(count_results)
 SCAN_OFFSET=$(output_size)
 printf " " >&3

 # Wait for result, retrying once if spotread reports a transient
 # communication problem with the meter.
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
  PARSED=$(parse_latest_result)
  if [[ -n "$PARSED" ]]; then
   READING=$(build_step_reading_json "$i" "$PARSED" 2>/dev/null)
  fi
 fi

 if [[ -z "$READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] read timeout: step=$STEP_NUM ire=$IRE timeout=${READ_TIMEOUT}s name=$NAME" >> /tmp/meter_series_debug.log
  for (( no_reading_retry=1; no_reading_retry<=NO_READING_RETRIES; no_reading_retry++ )); do
   echo "[$(date '+%H:%M:%S.%3N')] no reading retry: step=$STEP_NUM ire=$IRE retry=$no_reading_retry/$NO_READING_RETRIES name=$NAME" >> /tmp/meter_series_debug.log
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (retry reading $no_reading_retry/$NO_READING_RETRIES)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
	   post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
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
      printf " " >&3
      RETRIED_COMM=1
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 15))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
      echo "[$(date '+%H:%M:%S.%3N')] manual prompt during no reading retry: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
      if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
       wait_for_device_ready "$STEP_NUM" "$(manual_ready_prompt_label "$NAME" "$PROMPT_REASON")" "$PROMPT_REASON"
      else
       sleep 1
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
  echo "[$(date '+%H:%M:%S.%3N')] zero read guard: step=$STEP_NUM ire=$IRE name=$NAME parsed all-zero XYZ/luminance" >> /tmp/meter_series_debug.log
  ZERO_RETRY_READING=""
  for (( zero_retry=1; zero_retry<=ZERO_READ_RETRIES; zero_retry++ )); do
   write_state_json << EOJSON
{"status":"running","series_id":"$SERIES_ID","current_step":$STEP_NUM,"total_steps":$TOTAL,"current_name":"$NAME (redisplaying after zero read $zero_retry/$ZERO_READ_RETRIES)","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON
	   post_patch "$R" "$G" "$B" "$PATCH_SIZE" "$SIGNAL_MODE" "$MAX_LUMA" "$PATTERN_SIGNAL_RANGE" "$TRANSPORT_SIGNAL_RANGE" "$INPUT_MAX"
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
      printf " " >&3
      RETRIED_COMM=1
      RETRY_TIMEOUT=$((RETRY_TIMEOUT + 15))
      SCAN_OFFSET=$(output_size)
      continue
     fi
     if PROMPT_REASON=$(manual_ready_prompt_reason "$NEW_OUTPUT"); then
      echo "[$(date '+%H:%M:%S.%3N')] manual prompt during zero retry: step=$STEP_NUM ire=$IRE reason=$PROMPT_REASON name=$NAME" >> /tmp/meter_series_debug.log
      if [[ "$REQUIRE_DEVICE_READY" == "1" ]]; then
       wait_for_device_ready "$STEP_NUM" "$(manual_ready_prompt_label "$NAME" "$PROMPT_REASON")" "$PROMPT_REASON"
      else
       sleep 1
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
   echo "[$(date '+%H:%M:%S.%3N')] zero read guard excluded: step=$STEP_NUM ire=$IRE retries=$ZERO_READ_RETRIES name=$NAME" >> /tmp/meter_series_debug.log
   READING=$(build_step_reading_json "$i" "{\"error\":\"no_reading\",\"reason\":\"zero_xyz_luminance\"}" 2>/dev/null || echo "{\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B,\"error\":\"no_reading\",\"reason\":\"zero_xyz_luminance\"}")
  fi
 fi

 NORMALIZED_READING=$(normalize_oled_zero_black_reading "$READING" 2>/dev/null || true)
 if [[ -n "$NORMALIZED_READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] oled zero black normalized: step=$STEP_NUM ire=$IRE name=$NAME" >> /tmp/meter_series_debug.log
  READING="$NORMALIZED_READING"
 fi

 if [[ -z "$READING" ]]; then
  echo "[$(date '+%H:%M:%S.%3N')] read timeout final: step=$STEP_NUM ire=$IRE retries=$NO_READING_RETRIES timeout=${READ_TIMEOUT}s name=$NAME" >> /tmp/meter_series_debug.log
  READING=$(build_step_reading_json "$i" "{\"error\":\"no_reading\"}" 2>/dev/null || echo "{\"ire\":$IRE,\"name\":\"$NAME\",\"r_code\":$R,\"g_code\":$G,\"b_code\":$B,\"error\":\"no_reading\"}")
 fi

 # Accumulate
 if [[ $READING_COUNT -gt 0 ]]; then
  READINGS="$READINGS,$READING"
 else
  READINGS="$READING"
 fi
 READING_COUNT=$((READING_COUNT + 1))

 if [[ "$DV_ABSOLUTE_CODES_APPLIED" == "0" ]] && dv_absolute_greyscale_series_active && is_number "$IRE" && float_le 99.999 "$IRE"; then
  WHITE_Y=$(reading_luminance_json "$READING" 2>/dev/null || true)
  if [[ -n "$WHITE_Y" ]] && apply_dv_absolute_greyscale_codes "$WHITE_Y"; then
   DV_ABSOLUTE_CODES_APPLIED=1
   WHITE_READING="$READING"
   echo "[$(date '+%H:%M:%S.%3N')] DV absolute greyscale codes applied from white_y=$WHITE_Y" >> /tmp/meter_series_debug.log
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

# Quit spotread
printf "Q" >&3 2>/dev/null
exec 3>&- 2>/dev/null
METER_SERIES_FD_OPEN=0
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
write_state_json << EOJSON
{"status":"complete","series_id":"$SERIES_ID","current_step":$TOTAL,"total_steps":$TOTAL,"current_name":"Done","readings":[$READINGS],"white_reading":$WHITE_READING}
EOJSON

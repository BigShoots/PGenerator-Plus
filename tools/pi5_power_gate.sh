#!/usr/bin/env bash

set -euo pipefail

API_BASE="http://192.168.1.249"
LABEL="pi5-power"
OUT_DIR=""
REBOOT_TIMEOUT=180
OFFLINE_TIMEOUT=45
ONLINE_TIMEOUT=180
RUN_REBOOT=1
RUN_POWEROFF=0

usage() {
 cat <<'EOF'
Usage:
  ./tools/pi5_power_gate.sh [options]

Options:
  --api-base URL           WebUI base URL. Default: http://192.168.1.249
  --label NAME             Artifact label. Default: pi5-power
  --out-dir PATH           Artifact directory. Default: tmp/power-<label>-<timestamp>
  --no-reboot              Skip the reboot test.
  --poweroff               Also test /api/power. Leaves the Pi off until power-cycled.
  --reboot-timeout SEC     Total seconds to wait for reboot cycle. Default: 180
  -h, --help               Show this help text.

Notes:
  The reboot test posts /api/reboot, waits for the WebUI to go offline, then
  waits for it to return and verifies uptime dropped. The poweroff test is
  intentionally opt-in because a passing test makes the device unreachable.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

log() {
 printf '[power:%s] %s\n' "$LABEL" "$*"
}

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --api-base)
    [[ $# -ge 2 ]] || die "Missing value for --api-base"
    API_BASE="${2%/}"
    shift 2
    ;;
   --label)
    [[ $# -ge 2 ]] || die "Missing value for --label"
    LABEL="$2"
    shift 2
    ;;
   --out-dir)
    [[ $# -ge 2 ]] || die "Missing value for --out-dir"
    OUT_DIR="$2"
    shift 2
    ;;
   --no-reboot)
    RUN_REBOOT=0
    shift
    ;;
   --poweroff)
    RUN_POWEROFF=1
    shift
    ;;
   --reboot-timeout)
    [[ $# -ge 2 ]] || die "Missing value for --reboot-timeout"
    REBOOT_TIMEOUT="$2"
    ONLINE_TIMEOUT="$2"
    shift 2
    ;;
   -h|--help)
    usage
    exit 0
    ;;
   *)
    die "Unknown argument: $1"
    ;;
  esac
 done
}

require_commands() {
 local missing=()
 local cmd
 for cmd in awk curl date grep mkdir sed; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
 done
 [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}

api_get() {
 local path="$1"
 curl -fsS --max-time 8 "$API_BASE$path"
}

api_post() {
 local path="$1"
 curl -fsS --max-time 10 -X POST "$API_BASE$path"
}

uptime_from_json() {
 sed -n 's/.*"uptime":"\([^"]*\)".*/\1/p' "$1" | awk '{printf "%.0f\n",$1+0}'
}

wait_until_offline() {
 local timeout="$1"
 local start
 start="$(date +%s)"
 while (( $(date +%s) - start < timeout )); do
  if ! api_get "/api/info" >/dev/null 2>&1; then
   return 0
  fi
  sleep 2
 done
 return 1
}

wait_until_online() {
 local timeout="$1"
 local outfile="$2"
 local start
 start="$(date +%s)"
 while (( $(date +%s) - start < timeout )); do
  if api_get "/api/info" > "$outfile" 2> "$outfile.stderr"; then
   rm -f "$outfile.stderr"
   return 0
  fi
  sleep 3
 done
 return 1
}

write_status() {
 local status="$1"
 local reason="$2"
 {
  echo "status=$status"
  echo "reason=$reason"
  echo "api_base=$API_BASE"
  echo "artifacts=$OUT_DIR"
  echo "timestamp=$(date -Is)"
 } > "$OUT_DIR/POWER_GATE_STATUS.txt"
}

test_reboot() {
 local before_uptime
 local after_uptime

 log "checking WebUI before reboot"
 api_get "/api/info" > "$OUT_DIR/reboot_before_info.json" || die "WebUI API unavailable at $API_BASE"
 before_uptime="$(uptime_from_json "$OUT_DIR/reboot_before_info.json")"
 [[ -n "$before_uptime" ]] || die "Could not parse pre-reboot uptime"

 log "posting /api/reboot"
 api_post "/api/reboot" > "$OUT_DIR/reboot_response.json" 2> "$OUT_DIR/reboot_response.stderr" || die "POST /api/reboot failed"
 rm -f "$OUT_DIR/reboot_response.stderr"

 if ! grep -q '"status":"ok"' "$OUT_DIR/reboot_response.json"; then
  write_status "fail" "/api/reboot did not return ok"
  die "/api/reboot did not return ok"
 fi

 log "waiting for WebUI to go offline"
 if ! wait_until_offline "$OFFLINE_TIMEOUT"; then
  api_get "/api/info" > "$OUT_DIR/reboot_still_online_info.json" 2>/dev/null || true
  write_status "fail" "WebUI never went offline after /api/reboot"
  die "WebUI never went offline after /api/reboot"
 fi

 log "waiting for WebUI to return"
 if ! wait_until_online "$ONLINE_TIMEOUT" "$OUT_DIR/reboot_after_info.json"; then
  write_status "fail" "WebUI did not return after reboot"
  die "WebUI did not return after reboot"
 fi

 after_uptime="$(uptime_from_json "$OUT_DIR/reboot_after_info.json")"
 [[ -n "$after_uptime" ]] || die "Could not parse post-reboot uptime"
 if (( after_uptime >= before_uptime )); then
  write_status "fail" "uptime did not reset after reboot"
  die "Uptime did not reset after reboot: before=$before_uptime after=$after_uptime"
 fi

 printf 'before_uptime=%s\nafter_uptime=%s\n' "$before_uptime" "$after_uptime" > "$OUT_DIR/reboot_result.txt"
 log "reboot passed: uptime $before_uptime -> $after_uptime"
}

test_poweroff() {
 log "posting /api/power; device should stay offline until physically power-cycled"
 api_get "/api/info" > "$OUT_DIR/power_before_info.json" || die "WebUI API unavailable before poweroff"
 api_post "/api/power" > "$OUT_DIR/power_response.json" 2> "$OUT_DIR/power_response.stderr" || die "POST /api/power failed"
 rm -f "$OUT_DIR/power_response.stderr"

 if ! grep -q '"status":"ok"' "$OUT_DIR/power_response.json"; then
  write_status "fail" "/api/power did not return ok"
  die "/api/power did not return ok"
 fi

 if ! wait_until_offline "$OFFLINE_TIMEOUT"; then
  api_get "/api/info" > "$OUT_DIR/power_still_online_info.json" 2>/dev/null || true
  write_status "fail" "WebUI never went offline after /api/power"
  die "WebUI never went offline after /api/power"
 fi

 write_status "pass" "poweroff endpoint made WebUI unreachable; physical power cycle required"
 log "poweroff passed; the Pi now needs a physical power cycle"
}

main() {
 parse_args "$@"
 require_commands
 if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="tmp/power-${LABEL}-$(date +%Y%m%d_%H%M%S)"
 fi
 mkdir -p "$OUT_DIR"
 log "artifacts: $OUT_DIR"

 if [[ "$RUN_REBOOT" -eq 1 ]]; then
  test_reboot
 fi
 if [[ "$RUN_POWEROFF" -eq 1 ]]; then
  test_poweroff
 fi
 if [[ "$RUN_POWEROFF" -ne 1 ]]; then
  write_status "pass" "selected power checks passed; poweroff was not requested"
 fi
}

main "$@"

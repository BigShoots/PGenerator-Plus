#!/usr/bin/env bash

set -euo pipefail

TARGET="root@192.168.1.249"
LABEL="pi5-display"
OUT_DIR=""
API_BASE=""
RESTORE_CONFIG=1
PASS="${PGEN_PASS-}"
if [[ -z "$PASS" ]]; then
 PASS='PGenerator!!$'
fi

FAILED=0
APPLIED_ANY=0

usage() {
 cat <<'EOF'
Usage:
  ./tools/pi5_display_output_gate.sh [options]

Options:
  --target USER@HOST       SSH target. Default: root@192.168.1.249
  --api-base URL           WebUI base URL. Default: http://<HOST>
  --label NAME             Artifact label. Default: pi5-display
  --out-dir PATH           Artifact directory. Default: tmp/display-output-<label>-<timestamp>
  --leave-last-mode        Do not restore the starting /api/config at exit.
  -h, --help               Show this help text.

Environment:
  PGEN_PASS                SSH password. Defaults to the lab PGenerator password.

Notes:
  This gate verifies the Pi-side transport request, KMS connector state,
  HDR/Dolby metadata blobs, and renderer pattern operations. It cannot prove
  bit-perfect HDMI samples by itself; final bit-perfect acceptance still needs
  an external HDMI analyzer/capture artifact for the same cases.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

log() {
 printf '[display:%s] %s\n' "$LABEL" "$*"
}

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --target)
    [[ $# -ge 2 ]] || die "Missing value for --target"
    TARGET="$2"
    shift 2
    ;;
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
   --leave-last-mode)
    RESTORE_CONFIG=0
    shift
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
 for cmd in awk curl date grep mkdir sed sha256sum ssh sort; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
 done
 if [[ -n "$PASS" ]] && ! command -v sshpass >/dev/null 2>&1; then
  missing+=("sshpass")
 fi
 [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}

target_host() {
 local host="${TARGET#*@}"
 printf '%s' "${host%%:*}"
}

default_api_base() {
 if [[ -z "$API_BASE" ]]; then
  API_BASE="http://$(target_host)"
 fi
}

ssh_base() {
 if [[ -n "$PASS" ]]; then
  SSHPASS="$PASS" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$TARGET" "$@"
 else
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$TARGET" "$@"
 fi
}

remote() {
 ssh_base "$1"
}

api_get_direct() {
 local path="$1"
 curl -fsS --max-time 10 "$API_BASE$path"
}

api_post_direct() {
 local path="$1"
 local body="$2"
 curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' --data "$body" "$API_BASE$path"
}

api_get() {
 local path="$1"
 remote "curl -fsS --max-time 10 http://127.0.0.1${path}"
}

api_post() {
 local path="$1"
 local body="$2"
 remote "curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' --data '$body' http://127.0.0.1${path}"
}

save_remote() {
 local name="$1"
 local command="$2"
 if remote "$command" > "$OUT_DIR/$name" 2> "$OUT_DIR/$name.stderr"; then
  rm -f "$OUT_DIR/$name.stderr"
 else
  printf 'Command failed: %s\n' "$command" >> "$OUT_DIR/$name.stderr"
 fi
}

save_api_direct() {
 local name="$1"
 local path="$2"
 if api_get_direct "$path" > "$OUT_DIR/$name" 2> "$OUT_DIR/$name.stderr"; then
  rm -f "$OUT_DIR/$name.stderr"
 else
  printf 'GET failed: %s%s\n' "$API_BASE" "$path" >> "$OUT_DIR/$name.stderr"
 fi
}

save_api_remote() {
 local name="$1"
 local path="$2"
 if api_get "$path" > "$OUT_DIR/$name" 2> "$OUT_DIR/$name.stderr"; then
  rm -f "$OUT_DIR/$name.stderr"
 else
  printf 'Remote GET failed: %s\n' "$path" >> "$OUT_DIR/$name.stderr"
 fi
}

json_value_ok() {
 local file="$1"
 local key="$2"
 local expected="$3"
 grep -Eq "\"$key\"[[:space:]]*:[[:space:]]*\"?$expected\"?" "$file"
}

modetest_prop_value() {
 local file="$1"
 local prop="$2"
 awk -v prop="$prop" '
  $0 ~ "^[[:space:]]*[0-9]+[[:space:]]+" && index($0, prop ":") {
   capture=1
   waiting_blob_value=0
   is_blob=0
   next
  }
  capture && $1 == "flags:" && index($0, "blob") {
   is_blob=1
  }
  capture && $1 == "value:" {
   if (NF > 1) {
    print $2
    exit
   }
   if (is_blob) {
    waiting_blob_value=1
    next
   }
   print ""
   exit
  }
  capture && waiting_blob_value && $0 ~ /^[[:space:]]*$/ {
   next
  }
  capture && waiting_blob_value && $0 ~ "^[[:space:]]*[0-9]+[[:space:]][^:]+:" {
   print ""
   exit
  }
  capture && waiting_blob_value && $0 ~ "^[0-9]+[[:space:]][0-9]+[[:space:]]" {
   print ""
   exit
  }
  capture && waiting_blob_value {
   value=$1
   gsub(/[^0-9A-Fa-f]/, "", value)
   print value
   exit
  }
  capture && $0 ~ "^[[:space:]]*[0-9]+[[:space:]][^:]+:" {
   capture=0
  }
 ' "$file"
}

blob_is_set() {
 local file="$1"
 local prop="$2"
 local value
 value="$(modetest_prop_value "$file" "$prop" || true)"
 if [[ "$value" =~ ^[0-9A-Fa-f]{8,}$ ]]; then
  [[ "$value" =~ [1-9A-Fa-f] ]]
 elif [[ "$value" =~ ^[0-9]+$ ]]; then
  [[ "$value" -gt 0 ]]
 else
  false
 fi
}

write_local_integrity() {
 {
  echo "label=$LABEL"
  echo "target=$TARGET"
  echo "api_base=$API_BASE"
  echo "timestamp=$(date -Is)"
  echo "git_head=$(git rev-parse HEAD)"
  echo "--- git status --short ---"
  git status --short
  echo "--- relevant source hashes ---"
  sha256sum \
   tools/pi5_display_output_gate.sh \
   usr/share/PGenerator/webui.pm \
   tools/image-targets/pi5-bookworm-armhf/rootfs/usr/share/PGenerator/command.pm \
   tools/image-targets/pi5-bookworm-armhf/src/ofxRPI4Window/src/ofxRPI4Window.cpp
 } > "$OUT_DIR/local_integrity.txt"
}

write_summary_header() {
 printf 'case\tstatus\tsignal\tcolor_format\tmax_bpc\toutput_format\thdr_blob\tdovi_blob\tnotes\n' > "$OUT_DIR/summary.tsv"
}

summary_row() {
 local name="$1"
 local status="$2"
 local signal="$3"
 local color_format="$4"
 local max_bpc="$5"
 local output_format="$6"
 local hdr_blob="$7"
 local dovi_blob="$8"
 local notes="$9"
 printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$name" "$status" "$signal" "$color_format" "$max_bpc" "$output_format" "$hdr_blob" "$dovi_blob" "$notes" >> "$OUT_DIR/summary.tsv"
}

fail_case() {
 local -n case_failed_ref="$1"
 local -n notes_ref="$2"
 local message="$3"
 case_failed_ref=1
 FAILED=1
 if [[ -n "$notes_ref" ]]; then
  notes_ref="${notes_ref}; $message"
 else
  notes_ref="$message"
 fi
}

config_body_for_case() {
 local signal="$1"
 local color_format="$2"
 local quant_range="$3"
 local max_bpc="$4"
 local colorimetry="$5"
 local eotf="$6"
 local primaries="$7"
 local dv_map_mode="$8"
 local dv_metadata="$9"

 case "$signal" in
  sdr)
   printf '{"signal_mode":"sdr","is_sdr":"1","is_hdr":"0","eotf":"0","primaries":"0","color_format":"%s","rgb_quant_range":"%s","max_bpc":"%s","colorimetry":"%s","is_ll_dovi":"0","is_std_dovi":"0","dv_status":"0","dv_interface":"0","dv_metadata":"0"}' \
    "$color_format" "$quant_range" "$max_bpc" "$colorimetry"
   ;;
  hdr10|hlg)
   printf '{"signal_mode":"%s","is_sdr":"0","is_hdr":"1","is_ll_dovi":"0","is_std_dovi":"0","dv_status":"0","dv_interface":"0","dv_metadata":"0","color_format":"%s","rgb_quant_range":"%s","max_bpc":"%s","colorimetry":"%s","eotf":"%s","primaries":"%s","max_luma":"1000","min_luma":"0.005","max_cll":"1000","max_fall":"400"}' \
    "$signal" "$color_format" "$quant_range" "$max_bpc" "$colorimetry" "$eotf" "$primaries"
   ;;
  dv)
   local dv_interface="0"
   local is_ll_dovi="0"
   local is_std_dovi="1"
   if [[ "$color_format" == "2" ]]; then
    dv_interface="1"
    is_ll_dovi="1"
    is_std_dovi="0"
   fi
   printf '{"signal_mode":"dv","is_sdr":"0","is_hdr":"1","is_ll_dovi":"%s","is_std_dovi":"%s","dv_status":"1","dv_interface":"%s","dv_profile":"1","dv_color_space":"0","dv_map_mode":"%s","dv_metadata":"%s","color_format":"%s","rgb_quant_range":"%s","max_bpc":"%s","colorimetry":"%s","eotf":"2","primaries":"1","max_luma":"1000","min_luma":"0.005","max_cll":"1000","max_fall":"400"}' \
    "$is_ll_dovi" "$is_std_dovi" "$dv_interface" "$dv_map_mode" "$dv_metadata" "$color_format" "$quant_range" "$max_bpc" "$colorimetry"
   ;;
  *)
   die "Unknown signal for config: $signal"
   ;;
 esac
}

pattern_body_for_case() {
 local signal="$1"
 local code="$2"
 local input_max="$3"
 local quant_range="$4"
 printf '{"name":"patch","r":%s,"g":%s,"b":%s,"size":100,"input_max":%s,"signal_mode":"%s","signal_range":"%s","transport_signal_range":"%s"}' \
  "$code" "$code" "$code" "$input_max" "$signal" "$quant_range" "$quant_range"
}

collect_case_artifacts() {
 local name="$1"
 save_api_remote "config_${name}_readback.json" "/api/config"
 save_api_remote "info_${name}.json" "/api/info"
 save_api_remote "infoframes_${name}.json" "/api/infoframes"
 save_remote "modetest_${name}.txt" "modetest -M vc4 -a -c 2>/dev/null"
 save_remote "drm_state_${name}.txt" "for f in /sys/kernel/debug/dri/*/state; do echo '---' \$f; cat \$f; done 2>/dev/null"
 save_remote "operations_${name}.txt" "cat /var/lib/PGenerator/operations.txt 2>/dev/null"
 save_remote "renderer_log_${name}.txt" "journalctl -u pgenerator -u PGenerator -u lighttpd --no-pager -n 220 2>/dev/null || true; cat /var/log/PGenerator.log 2>/dev/null | tail -n 220 || true"
}

run_case() {
 local name="$1"
 local signal="$2"
 local color_format="$3"
 local quant_range="$4"
 local max_bpc="$5"
 local colorimetry="$6"
 local eotf="$7"
 local primaries="$8"
 local dv_map_mode="$9"
 local dv_metadata="${10}"
 local expected_output_format="${11}"
 local expected_hdr_blob="${12}"
 local expected_dovi_blob="${13}"
 local code="${14}"
 local input_max="${15}"

 local notes=""
 local case_failed=0
 local config_body
 local pattern_body
 local prop_output=""
 local prop_bpc=""
 local hdr_blob="0"
 local dovi_blob="0"

 config_body="$(config_body_for_case "$signal" "$color_format" "$quant_range" "$max_bpc" "$colorimetry" "$eotf" "$primaries" "$dv_map_mode" "$dv_metadata")"
 printf '%s\n' "$config_body" > "$OUT_DIR/config_${name}_request.json"

 log "applying $name"
 if api_post "/api/config" "$config_body" > "$OUT_DIR/config_${name}_apply.json" 2> "$OUT_DIR/config_${name}_apply.stderr"; then
  rm -f "$OUT_DIR/config_${name}_apply.stderr"
  APPLIED_ANY=1
 else
  fail_case case_failed notes "config apply failed"
  summary_row "$name" "FAIL" "$signal" "$color_format" "$max_bpc" "" "" "" "$notes"
  return
 fi

 sleep 5

 pattern_body="$(pattern_body_for_case "$signal" "$code" "$input_max" "$quant_range")"
 printf '%s\n' "$pattern_body" > "$OUT_DIR/pattern_${name}_request.json"
 if api_post "/api/pattern" "$pattern_body" > "$OUT_DIR/pattern_${name}.json" 2> "$OUT_DIR/pattern_${name}.stderr"; then
  rm -f "$OUT_DIR/pattern_${name}.stderr"
 else
  fail_case case_failed notes "pattern draw failed"
 fi

 sleep 2
 collect_case_artifacts "$name"

 if [[ -f "$OUT_DIR/config_${name}_readback.json" ]]; then
  json_value_ok "$OUT_DIR/config_${name}_readback.json" "signal_mode" "$signal" || fail_case case_failed notes "signal_mode readback mismatch"
  json_value_ok "$OUT_DIR/config_${name}_readback.json" "color_format" "$color_format" || fail_case case_failed notes "color_format readback mismatch"
  json_value_ok "$OUT_DIR/config_${name}_readback.json" "max_bpc" "$max_bpc" || fail_case case_failed notes "max_bpc readback mismatch"
  json_value_ok "$OUT_DIR/config_${name}_readback.json" "rgb_quant_range" "$quant_range" || fail_case case_failed notes "rgb_quant_range readback mismatch"
  if [[ "$signal" == "hdr10" || "$signal" == "hlg" ]]; then
   json_value_ok "$OUT_DIR/config_${name}_readback.json" "is_hdr" "1" || fail_case case_failed notes "HDR flag not set"
   json_value_ok "$OUT_DIR/config_${name}_readback.json" "eotf" "$eotf" || fail_case case_failed notes "EOTF readback mismatch"
  fi
  if [[ "$signal" == "dv" ]]; then
   json_value_ok "$OUT_DIR/config_${name}_readback.json" "dv_status" "1" || fail_case case_failed notes "DV status not set"
   json_value_ok "$OUT_DIR/config_${name}_readback.json" "dv_map_mode" "$dv_map_mode" || fail_case case_failed notes "DV map mode mismatch"
   json_value_ok "$OUT_DIR/config_${name}_readback.json" "dv_metadata" "$dv_metadata" || fail_case case_failed notes "DV metadata mode mismatch"
  fi
 else
  fail_case case_failed notes "missing config readback"
 fi

 if [[ -f "$OUT_DIR/modetest_${name}.txt" ]]; then
  prop_output="$(modetest_prop_value "$OUT_DIR/modetest_${name}.txt" "output format" || true)"
  prop_bpc="$(modetest_prop_value "$OUT_DIR/modetest_${name}.txt" "max bpc" || true)"
  [[ "$prop_output" == "$expected_output_format" ]] || fail_case case_failed notes "output format property expected $expected_output_format got ${prop_output:-missing}"
  [[ "$prop_bpc" == "$max_bpc" ]] || fail_case case_failed notes "max bpc property expected $max_bpc got ${prop_bpc:-missing}"
  if blob_is_set "$OUT_DIR/modetest_${name}.txt" "HDR_OUTPUT_METADATA"; then
   hdr_blob="1"
  fi
  if blob_is_set "$OUT_DIR/modetest_${name}.txt" "DOVI_OUTPUT_METADATA"; then
   dovi_blob="1"
  fi
  if [[ "$expected_hdr_blob" == "1" && "$hdr_blob" != "1" ]]; then
   fail_case case_failed notes "HDR metadata blob not set"
  fi
  if [[ "$expected_dovi_blob" == "1" && "$dovi_blob" != "1" ]]; then
   fail_case case_failed notes "DOVI metadata blob not set"
  fi
 else
  fail_case case_failed notes "missing modetest artifact"
 fi

 if [[ -f "$OUT_DIR/operations_${name}.txt" ]]; then
  grep -Eq 'DRAW=RECTANGLE|PATTERN_NAME=patch|RGB=' "$OUT_DIR/operations_${name}.txt" || fail_case case_failed notes "renderer operations do not show patch"
 else
  fail_case case_failed notes "missing renderer operations"
 fi

 if [[ "$case_failed" -eq 0 ]]; then
  summary_row "$name" "PASS" "$signal" "$color_format" "$max_bpc" "${prop_output:-}" "$hdr_blob" "$dovi_blob" "ok"
 else
  summary_row "$name" "FAIL" "$signal" "$color_format" "$max_bpc" "${prop_output:-}" "$hdr_blob" "$dovi_blob" "$notes"
 fi
}

restore_config() {
 if [[ "$RESTORE_CONFIG" -ne 1 || "$APPLIED_ANY" -ne 1 ]]; then
  return
 fi
 if [[ ! -s "$OUT_DIR/api_config_initial.json" ]]; then
  return
 fi
 log "restoring initial display config"
 local body
 body="$(tr -d '\n' < "$OUT_DIR/api_config_initial.json")"
 api_post "/api/config" "$body" > "$OUT_DIR/config_restore.json" 2> "$OUT_DIR/config_restore.stderr" || true
 sleep 3
 save_api_remote "config_restore_readback.json" "/api/config"
}

preflight() {
 local direct_ok=1
 local ssh_ok=1
 local preflight_fail=0

 log "collecting initial API state"
 if ! api_get_direct "/api/info" > "$OUT_DIR/api_info_initial.json" 2> "$OUT_DIR/api_info_initial.stderr"; then
  direct_ok=0
 fi
 if ! api_get_direct "/api/capabilities" > "$OUT_DIR/api_capabilities_initial.json" 2> "$OUT_DIR/api_capabilities_initial.stderr"; then
  direct_ok=0
 fi
 if ! api_get_direct "/api/config" > "$OUT_DIR/api_config_initial.json" 2> "$OUT_DIR/api_config_initial.stderr"; then
  direct_ok=0
 fi
 if [[ "$direct_ok" -ne 1 ]]; then
  printf 'status=fail\nreason=webui API unavailable at %s\n' "$API_BASE" > "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  die "WebUI API unavailable at $API_BASE"
 fi
 rm -f "$OUT_DIR"/api_*_initial.stderr

 log "checking SSH access"
 if ! ssh_base "true" > "$OUT_DIR/ssh_preflight.txt" 2> "$OUT_DIR/ssh_preflight.stderr"; then
  ssh_ok=0
 fi
 if [[ "$ssh_ok" -ne 1 ]]; then
  printf 'status=fail\nreason=ssh unavailable for %s\napi_info=%s\n' "$TARGET" "$OUT_DIR/api_info_initial.json" > "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  die "SSH unavailable for $TARGET"
 fi
 rm -f "$OUT_DIR/ssh_preflight.stderr"

 save_remote "remote_identity.txt" "printf 'model='; tr -d '\\0' < /proc/device-tree/model 2>/dev/null; printf '\\n'; uname -a; cat /etc/os-release 2>/dev/null || true"
 save_remote "remote_drm_status.txt" "for d in /sys/class/drm/card*-HDMI-A-*; do echo '---' \$d; cat \$d/status 2>/dev/null; wc -c \$d/edid 2>/dev/null; done"
 save_remote "modetest_initial.txt" "modetest -M vc4 -a -c 2>/dev/null"
 save_remote "drm_state_initial.txt" "for f in /sys/kernel/debug/dri/*/state; do echo '---' \$f; cat \$f; done 2>/dev/null"
 save_remote "renderer_initial.txt" "pgrep -af 'PGeneratord|PGenerator' 2>/dev/null || true; cat /etc/PGenerator/PGenerator.conf 2>/dev/null"

 if ! grep -q '"connected"' "$OUT_DIR/api_info_initial.json" && ! grep -q " connected .*HDMI" "$OUT_DIR/modetest_initial.txt"; then
  printf 'status=fail\nreason=no connected HDMI sink reported\napi_info=%s\n' "$OUT_DIR/api_info_initial.json" > "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  preflight_fail=1
 fi
 if ! grep -q "output format" "$OUT_DIR/modetest_initial.txt"; then
  printf 'status=fail\nreason=KMS connector has no output format property\nmodetest=%s\n' "$OUT_DIR/modetest_initial.txt" >> "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  preflight_fail=1
 fi
 if ! grep -q "HDR_OUTPUT_METADATA" "$OUT_DIR/modetest_initial.txt"; then
  printf 'status=fail\nreason=KMS connector has no HDR_OUTPUT_METADATA property\nmodetest=%s\n' "$OUT_DIR/modetest_initial.txt" >> "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  preflight_fail=1
 fi
 if ! grep -q "DOVI_OUTPUT_METADATA" "$OUT_DIR/modetest_initial.txt"; then
  printf 'status=fail\nreason=KMS connector has no DOVI_OUTPUT_METADATA property\nmodetest=%s\n' "$OUT_DIR/modetest_initial.txt" >> "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  preflight_fail=1
 fi
 if [[ "$preflight_fail" -ne 0 ]]; then
  die "Preflight failed; see $OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
 fi
}

run_matrix() {
 # name signal color_format quant_range max_bpc colorimetry eotf primaries dv_map dv_metadata expected_output expected_hdr_blob expected_dovi_blob code input_max
 run_case "sdr_rgb8_full"           "sdr"   "0" "2" "8"  "2" "0" "0" "0" "0" "0" "0" "0" "128" "255"
 run_case "sdr_rgb10_full"          "sdr"   "0" "2" "10" "2" "0" "0" "0" "0" "0" "0" "0" "512" "1023"
 run_case "sdr_y444_8_limited"      "sdr"   "1" "1" "8"  "2" "0" "0" "0" "0" "1" "0" "0" "128" "255"
 run_case "sdr_y444_10_limited"     "sdr"   "1" "1" "10" "2" "0" "0" "0" "0" "1" "0" "0" "512" "1023"
 run_case "sdr_y422_10_limited"     "sdr"   "2" "1" "10" "2" "0" "0" "0" "0" "2" "0" "0" "512" "1023"
 run_case "hdr10_rgb_10_limited"    "hdr10" "0" "1" "10" "9" "2" "1" "0" "0" "0" "1" "0" "512" "1023"
 run_case "hdr10_y444_10_limited"   "hdr10" "1" "1" "10" "9" "2" "1" "0" "0" "1" "1" "0" "512" "1023"
 run_case "hdr10_y422_10_limited"   "hdr10" "2" "1" "10" "9" "2" "1" "0" "0" "2" "1" "0" "512" "1023"
 run_case "hlg_rgb_10_limited"      "hlg"   "0" "1" "10" "9" "3" "1" "0" "0" "0" "1" "0" "512" "1023"
 run_case "hlg_y444_10_limited"     "hlg"   "1" "1" "10" "9" "3" "1" "0" "0" "1" "1" "0" "512" "1023"
 run_case "hlg_y422_10_limited"     "hlg"   "2" "1" "10" "9" "3" "1" "0" "0" "2" "1" "0" "512" "1023"
 run_case "dv_standard_relative_rgb8_full"  "dv" "0" "2" "8"  "9" "2" "1" "2" "4" "0" "0" "1" "128" "255"
 run_case "dv_standard_absolute_rgb8_full"  "dv" "0" "2" "8"  "9" "2" "1" "1" "3" "0" "0" "1" "128" "255"
 run_case "dv_lldv_relative_y422_10_full"  "dv" "2" "2" "10" "9" "2" "1" "2" "4" "2" "0" "1" "512" "1023"
 run_case "dv_lldv_absolute_y422_10_full"  "dv" "2" "2" "10" "9" "2" "1" "1" "3" "2" "0" "1" "512" "1023"
 run_case "dv_lldv_relative_y422_12_full"  "dv" "2" "2" "12" "9" "2" "1" "2" "4" "2" "0" "1" "512" "1023"
 run_case "dv_lldv_absolute_y422_12_full"  "dv" "2" "2" "12" "9" "2" "1" "1" "3" "2" "0" "1" "512" "1023"
}

main() {
 parse_args "$@"
 require_commands
 default_api_base
 if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="tmp/display-output-${LABEL}-$(date +%Y%m%d_%H%M%S)"
 fi
 mkdir -p "$OUT_DIR"
 trap restore_config EXIT

 log "artifacts: $OUT_DIR"
 write_local_integrity
 write_summary_header
 preflight
 run_matrix
 api_post "/api/pattern" '{"name":"stop"}' > "$OUT_DIR/pattern_stop.json" 2> "$OUT_DIR/pattern_stop.stderr" || true

 if [[ "$FAILED" -eq 0 ]]; then
  printf 'status=pass\nartifacts=%s\n' "$OUT_DIR" > "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  log "PASS"
 else
  printf 'status=fail\nartifacts=%s\nsummary=%s\n' "$OUT_DIR" "$OUT_DIR/summary.tsv" > "$OUT_DIR/DISPLAY_OUTPUT_GATE_STATUS.txt"
  log "FAIL; see $OUT_DIR/summary.tsv"
  exit 1
 fi
}

main "$@"

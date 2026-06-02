#!/usr/bin/env bash

set -euo pipefail

TARGET="root@192.168.1.179"
LABEL="pi5"
OUT_DIR=""
CAPTURE_DIR=""
REQUIRE_CAPTURE=0
PASS="${PGEN_PASS-}"
if [[ -z "$PASS" ]]; then
 PASS='PGenerator!!$'
fi

usage() {
 cat <<'EOF'
Usage:
  ./tools/pi5_bitperfect_gate.sh [options]

Options:
  --target USER@HOST       SSH target. Default: root@192.168.1.179
  --label NAME             Artifact label. Default: pi5
  --out-dir PATH           Artifact directory. Default: tmp/bitperfect-<label>-<timestamp>
  --capture-dir PATH       Existing HDMI analyzer/capture artifact directory to copy in.
  --require-capture        Fail if --capture-dir is missing or empty.
  -h, --help               Show this help text.

Environment:
  PGEN_PASS                SSH password. Defaults to the lab PGenerator password.

Notes:
  This gate collects software, API, DRM, InfoFrame, and generated-operation
  artifacts. It does not prove bit-perfect HDMI output by itself. A passing
  bit-perfect acceptance run must include external HDMI sample capture or
  analyzer artifacts via --capture-dir.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

log() {
 printf '[bitperfect:%s] %s\n' "$LABEL" "$*"
}

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --target)
    [[ $# -ge 2 ]] || die "Missing value for --target"
    TARGET="$2"
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
   --capture-dir)
    [[ $# -ge 2 ]] || die "Missing value for --capture-dir"
    CAPTURE_DIR="$2"
    shift 2
    ;;
   --require-capture)
    REQUIRE_CAPTURE=1
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
 for cmd in cp curl date find git grep mkdir sed sha256sum ssh sort; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
 done
 if [[ -n "$PASS" ]] && ! command -v sshpass >/dev/null 2>&1; then
  missing+=("sshpass")
 fi
 [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
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

api_get() {
 local path="$1"
 remote "curl -fsS --max-time 8 http://127.0.0.1${path}"
}

api_post() {
 local path="$1"
 local body="$2"
 remote "curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' --data '$body' http://127.0.0.1${path}"
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

save_local_integrity() {
 {
  echo "label=$LABEL"
  echo "target=$TARGET"
  echo "timestamp=$(date -Is)"
  echo "git_head=$(git rev-parse HEAD)"
  echo "--- git status --short ---"
  git status --short
  echo "--- renderer source hashes ---"
  sha256sum \
   src/pattern_generator/src/ofApp.cpp \
   src/pattern_generator/src/main.cpp \
   src/pattern_generator/src/rgb2ycbcr.h \
   src/ofxRPI4Window/src/ofxRPI4Window.cpp
 } > "$OUT_DIR/local_integrity.txt"
}

save_remote_baseline() {
 save_remote "remote_identity.txt" "printf 'model='; tr -d '\\0' < /proc/device-tree/model; printf '\\n'; uname -a; cat /etc/os-release 2>/dev/null || true"
 save_remote "renderer_integrity.txt" "sha256sum /usr/sbin/PGeneratord /usr/sbin/PGeneratord.dv 2>/dev/null; file /usr/sbin/PGeneratord /usr/sbin/PGeneratord.dv 2>/dev/null"
 save_remote "pgenerator_conf.txt" "cat /etc/PGenerator/PGenerator.conf 2>/dev/null"
 save_remote "api_config_initial.json" "curl -fsS --max-time 8 http://127.0.0.1/api/config"
 save_remote "api_infoframes_initial.json" "curl -fsS --max-time 8 http://127.0.0.1/api/infoframes"
 save_remote "modetest_connectors.txt" "modetest -M vc4 -c 2>/dev/null"
 save_remote "modetest_planes.txt" "modetest -M vc4 -p 2>/dev/null"
 save_remote "drm_debugfs_state.txt" "for f in /sys/kernel/debug/dri/*/state; do echo '---' \$f; cat \$f; done 2>/dev/null"
 save_remote "operations_initial.txt" "cat /var/lib/PGenerator/operations.txt 2>/dev/null"
}

configure_signal() {
 local name="$1"
 local color_format="$2"
 local quant_range="$3"
 local max_bpc="$4"
 local colorimetry="$5"
 local body

 body='{"signal_mode":"sdr","color_format":"'"$color_format"'","rgb_quant_range":"'"$quant_range"'","max_bpc":"'"$max_bpc"'","colorimetry":"'"$colorimetry"'"}'
 log "configuring $name"
 api_post "/api/config" "$body" > "$OUT_DIR/config_${name}.json"
 sleep 2
 api_get "/api/config" > "$OUT_DIR/config_${name}_readback.json"
 api_get "/api/infoframes" > "$OUT_DIR/infoframes_${name}.json"
 save_remote "modetest_${name}.txt" "modetest -M vc4 -c 2>/dev/null"
}

draw_patch() {
 local group="$1"
 local code="$2"
 local input_max="$3"
 local body
 local safe_group

 safe_group="$(printf '%s' "$group" | sed 's/[^A-Za-z0-9_.-]/_/g')"
 body='{"name":"patch","r":'"$code"',"g":'"$code"',"b":'"$code"',"size":100,"input_max":'"$input_max"',"signal_mode":"sdr","signal_range":"2","transport_signal_range":"2"}'
 log "drawing $group code=$code input_max=$input_max"
 api_post "/api/pattern" "$body" > "$OUT_DIR/pattern_${safe_group}_${code}.json"
 sleep 1
 save_remote "operations_${safe_group}_${code}.txt" "cat /var/lib/PGenerator/operations.txt 2>/dev/null"
 save_remote "infoframes_${safe_group}_${code}.json" "curl -fsS --max-time 8 http://127.0.0.1/api/infoframes"
}

collect_sentinel_patterns() {
 local code

 configure_signal "rgb_full_8bit" 0 2 8 2
 for code in 0 1 15 16 17 234 235 236 254 255; do
  draw_patch "rgb8_full" "$code" 255
 done

 configure_signal "rgb_full_10bit" 0 2 10 2
 for code in 0 1 63 64 65 939 940 941 1022 1023; do
  draw_patch "rgb10_full" "$code" 1023
 done

 configure_signal "ycbcr444_full_8bit" 1 2 8 2
 for code in 0 16 128 235 255; do
  draw_patch "y444_8_full" "$code" 255
 done

 configure_signal "ycbcr422_full_8bit" 2 2 8 2
 for code in 0 16 128 235 255; do
  draw_patch "y422_8_full" "$code" 255
 done

 api_post "/api/pattern" '{"name":"stop","signal_mode":"sdr"}' > "$OUT_DIR/pattern_stop.json" || true
}

copy_capture_artifacts() {
 local dst="$OUT_DIR/hdmi_capture"

 if [[ -z "$CAPTURE_DIR" ]]; then
  printf 'status=missing\nreason=no --capture-dir supplied\n' > "$OUT_DIR/BITPERFECT_STATUS.txt"
  if [[ "$REQUIRE_CAPTURE" -eq 1 ]]; then
   die "External HDMI capture artifacts are required for bit-perfect acceptance"
  fi
  return
 fi

 [[ -d "$CAPTURE_DIR" ]] || die "Capture directory does not exist: $CAPTURE_DIR"
 if ! find "$CAPTURE_DIR" -mindepth 1 -print -quit | grep -q .; then
  printf 'status=missing\nreason=capture directory empty\n' > "$OUT_DIR/BITPERFECT_STATUS.txt"
  if [[ "$REQUIRE_CAPTURE" -eq 1 ]]; then
   die "External HDMI capture directory is empty"
  fi
  return
 fi

 mkdir -p "$dst"
 cp -a "$CAPTURE_DIR"/. "$dst"/
 printf 'status=ready-for-review\ncapture_dir=%s\n' "$CAPTURE_DIR" > "$OUT_DIR/BITPERFECT_STATUS.txt"
}

main() {
 parse_args "$@"
 require_commands
 if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="tmp/bitperfect-${LABEL}-$(date +%Y%m%d_%H%M%S)"
 fi
 mkdir -p "$OUT_DIR"

 log "collecting artifacts into $OUT_DIR"
 save_local_integrity
 save_remote_baseline
 collect_sentinel_patterns
 save_remote "operations_final.txt" "cat /var/lib/PGenerator/operations.txt 2>/dev/null"
 copy_capture_artifacts
 log "complete: $OUT_DIR"
}

main "$@"

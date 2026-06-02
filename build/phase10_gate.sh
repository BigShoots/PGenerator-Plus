#!/usr/bin/env bash
# Phase 10 acceptance gate — eight-point gate, parity vs 2.2.2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PI="${PI:-root@192.168.1.179}"
PASS="${PASS:-PGenerator!!\$}"
LOG="${LOG:-/tmp/phase10_gate_$(date +%Y%m%d_%H%M%S).log}"

remote(){ SSHPASS="$PASS" sshpass -e ssh -o StrictHostKeyChecking=no "$PI" "$1"; }

meter_probe(){
  local label="$1" r="$2" g="$3" b="$4"
  echo "[probe:$label] r=$r g=$g b=$b" | tee -a "$LOG"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"patch_r\":$r,\"patch_g\":$g,\"patch_b\":$b,\"patch_size\":100,\"signal_mode\":\"sdr\"}' http://127.0.0.1/api/meter/read" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  for i in $(seq 1 40); do
    sleep 2
    out=$(remote "curl -s http://127.0.0.1/api/meter/read/result")
    echo "$out" | tee -a "$LOG"
    echo "$out" | grep -q '"readings"' && break
  done
  echo "" | tee -a "$LOG"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
  sleep 1
}

capture_drm_state(){
  local label="$1"
  echo "=== DRM state: $label ===" | tee -a "$LOG"
  remote "$(cat <<'REMOTE'
    echo 63 > /sys/module/drm/parameters/debug 2>/dev/null || true
    sleep 2
    echo '--device-model--'
    tr -d '\0' < /proc/device-tree/model 2>/dev/null || true
    echo
    echo '--connected-connectors--'
    if command -v modetest >/dev/null 2>&1; then
      timeout 3 modetest -M vc4 -c 2>/dev/null | awk '/^[0-9]+[[:space:]]+[0-9]+[[:space:]]+connected[[:space:]]+HDMI/{print; found=1; next} found && /^[[:space:]]+[0-9]+[[:space:]]+/{print; next} found && /^[0-9]+[[:space:]]+[0-9]+/{found=0}'
    fi
    state_file=""
    for f in /sys/kernel/debug/dri/*/state; do
      if [ -r "$f" ]; then
        state_file="$f"
        break
      fi
    done
    echo "--debugfs-state-file=$state_file--"
    if [ -n "$state_file" ]; then
      connector_id=""
      if command -v modetest >/dev/null 2>&1; then
        connector_id=$(timeout 3 modetest -M vc4 -c 2>/dev/null | awk '/^[0-9]+[[:space:]]+[0-9]+[[:space:]]+connected[[:space:]]+HDMI/{print $1; exit}')
      fi
      if [ -n "$connector_id" ]; then
        echo "--connector[$connector_id]--"
        awk -v id="$connector_id" '/connector\[/ { if(f) exit; f=($0 ~ "connector\\[" id "\\]") } f { print }' "$state_file"
      fi
      echo '--active-non-cursor-planes--'
      awk '
        /^plane\[[0-9]+\]/ {
          if(block != "" && block !~ /type=Cursor/ && block ~ /fb=[1-9][0-9]*/) {
            print block
          }
          block=$0 "\n"
          next
        }
        block != "" { block=block $0 "\n" }
        END {
          if(block != "" && block !~ /type=Cursor/ && block ~ /fb=[1-9][0-9]*/) {
            print block
          }
        }
      ' "$state_file"
    fi
    echo 0 > /sys/module/drm/parameters/debug 2>/dev/null || true
REMOTE
  )" | tee -a "$LOG"
}

{
  echo "=== PHASE 10 GATE START $(date '+%F %T.%N') ===" | tee -a "$LOG"
  echo "TARGET=$PI" | tee -a "$LOG"

  echo "=== [1] SOURCE + BINARY INTEGRITY ===" | tee -a "$LOG"
  sha256sum \
    "$REPO_ROOT/src/ofxRPI4Window/src/ofxRPI4Window.cpp" \
    "$REPO_ROOT/src/pattern_generator/src/main.cpp" \
    "$REPO_ROOT/usr/share/PGenerator/conf.pm" \
    "$REPO_ROOT/usr/share/PGenerator/variables.pm" \
    "$REPO_ROOT/usr/share/PGenerator/command.pm" \
    "$REPO_ROOT/build/phase10_gate.sh" | tee -a "$LOG"
  remote "tr -d '\0' < /proc/device-tree/model 2>/dev/null; echo" | tee -a "$LOG"
  remote "sha256sum /opt/openFrameworks/apps/myApps/PGeneratorBuild/pattern_generator/bin/pattern_generator /usr/sbin/PGeneratord /usr/sbin/PGeneratord.dv" | tee -a "$LOG"

  echo "=== [2] SERVICE RESTART + YCbCr SWITCH ===" | tee -a "$LOG"
  remote "/etc/init.d/PGenerator restart" | tee -a "$LOG"
  sleep 10
  echo "--- T+10 RGB settled ---" | tee -a "$LOG"
  remote "curl -s http://127.0.0.1/api/config; echo; curl -s http://127.0.0.1/api/infoframes" | tee -a "$LOG"

  ycbcr_sw=$(remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"1\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config")
  echo "YCbCr switch: $ycbcr_sw" | tee -a "$LOG"
  sleep 15

  echo "--- T+15 YCbCr settled ---" | tee -a "$LOG"
  remote "curl -s http://127.0.0.1/api/config; echo; curl -s http://127.0.0.1/api/infoframes" | tee -a "$LOG"

  echo "=== [3] DRM PLANE STATE (Gate 4 — Phase 9 delta) ===" | tee -a "$LOG"
  capture_drm_state "ycbcr444-settled"

  echo "=== [4] YCBCR METER PROBES (Gate 5) ===" | tee -a "$LOG"
  meter_probe red 255 0 0
  meter_probe green 0 255 0
  meter_probe blue 0 0 255
  meter_probe white 255 255 255
  meter_probe black 0 0 0
  meter_probe gray50 128 128 128

  echo "=== [5] PATTERN TRANSITION red->green->blue->red (Gate 7) ===" | tee -a "$LOG"
  for p in red green blue red; do
    remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"$p\"}' http://127.0.0.1/api/pattern" | tee -a "$LOG"
    sleep 1
  done
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"

  echo "=== [6] RGB REGRESSION SWITCH ===" | tee -a "$LOG"
  rgb_sw=$(remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config")
  echo "RGB switch: $rgb_sw" | tee -a "$LOG"
  sleep 10

  echo "--- T+10 RGB regression settled ---" | tee -a "$LOG"
  remote "curl -s http://127.0.0.1/api/config; echo; curl -s http://127.0.0.1/api/infoframes" | tee -a "$LOG"

  echo "=== [7] RGB PLANE STATE ===" | tee -a "$LOG"
  capture_drm_state "rgb-regression"

  echo "=== [8] RGB REGRESSION METER PROBES (Gate 8) ===" | tee -a "$LOG"
  meter_probe rgb_red 255 0 0
  meter_probe rgb_green 0 255 0
  meter_probe rgb_blue 0 0 255
  meter_probe rgb_white 255 255 255

  echo "=== CLEANUP ===" | tee -a "$LOG"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\"}' http://127.0.0.1/api/config >/dev/null 2>&1 || true"
  remote "echo 0 > /sys/module/drm/parameters/debug"
  echo "=== GATE COMPLETE $(date '+%F %T.%N') ===" | tee -a "$LOG"
  echo "LOG_FILE=$LOG" | tee -a "$LOG"
} 2>&1 | tee "$LOG"

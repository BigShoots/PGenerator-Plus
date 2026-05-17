#!/usr/bin/env bash
# Phase 10 acceptance gate — eight-point gate, parity vs 2.2.2
set -euo pipefail

PI='root@192.168.1.177'
PASS='PGenerator!!$'
LOG="/tmp/phase10_gate_$(date +%Y%m%d_%H%M%S).log"

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
  remote "
    echo 63 > /sys/module/drm/parameters/debug
    sleep 2
    echo '--connector33--'
    awk '/connector\[33\]/{f=1;print;next}/connector\[[0-9]+\]/{if(f)exit}f{print}' /sys/kernel/debug/dri/1/state
    echo '--plane102--'
    awk '/plane\[102\]/{f=1;print;next}/plane\[[0-9]+\]/{if(f)exit}f{print}' /sys/kernel/debug/dri/1/state
    echo 0 > /sys/module/drm/parameters/debug
  " | tee -a "$LOG"
}

{
  echo "=== PHASE 10 GATE START $(date '+%F %T.%N') ===" | tee -a "$LOG"

  echo "=== [1] FOUR-HASH INTEGRITY ===" | tee -a "$LOG"
  sha256sum /mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus/src/ofxRPI4Window/src/ofxRPI4Window.cpp | tee -a "$LOG"
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

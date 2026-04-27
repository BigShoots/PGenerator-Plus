#!/usr/bin/env bash
set -euo pipefail

PI='root@192.168.1.177'
PASS='PGenerator!!$'
LOCAL_ARTIFACT='/tmp/PGeneratord.phase8.artifact'
SOURCE_FILE='/mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus/src/ofxRPI4Window/src/ofxRPI4Window.cpp'
LOG="/tmp/phase8_shader_pack_gate_$(date +%Y%m%d_%H%M%S).log"

remote(){ SSHPASS="$PASS" sshpass -e ssh -o StrictHostKeyChecking=no "$PI" "$1"; }

meter_probe(){
  local label="$1" r="$2" g="$3" b="$4"
  echo "[probe:$label] request r=$r g=$g b=$b" | tee -a "$LOG"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"patch_r\":$r,\"patch_g\":$g,\"patch_b\":$b,\"patch_size\":100,\"signal_mode\":\"sdr\"}' http://127.0.0.1/api/meter/read" | tee -a "$LOG"
  for i in $(seq 1 35); do
    out=$(remote "curl -s http://127.0.0.1/api/meter/read/result")
    echo "$out" | tee -a "$LOG"
    echo "$out" | grep -q '"readings"' && break
  done
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
}

capture_state(){
  local label="$1"
  echo "[$label]" | tee -a "$LOG"
  remote "echo ts=\$(date '+%F %T.%N'); echo '--api/config--'; curl -s http://127.0.0.1/api/config; echo; echo '--api/infoframes--'; curl -s http://127.0.0.1/api/infoframes; echo; echo '--connector-state--'; awk '/connector\[33\]/{f=1;print;next}/connector\[[0-9]+\]/{if(f)exit}f{print}' /sys/kernel/debug/dri/1/state; echo '--plane102--'; awk '/plane\[102\]/{f=1;print;next}/plane\[[0-9]+\]/{if(f)exit}f{print}' /sys/kernel/debug/dri/1/state" | tee -a "$LOG"
}

{
  echo "PHASE8 shader pack ordering revert start $(date '+%F %T.%N')"
  echo "[phase8-diff]"
  git -C /mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus diff -- src/ofxRPI4Window/src/ofxRPI4Window.cpp | sed -n '1,80p'
  echo "[build-wrapper-command]"
  remote "cat /tmp/phase8_build.cmd"
  echo "[build-wrapper-exit-status]"
  remote "if [[ -f /tmp/phase8_build.exit ]]; then cat /tmp/phase8_build.exit; else echo 'missing'; fi"
  echo "[four-hash-integrity]"
  sha256sum "$SOURCE_FILE"
  sha256sum "$LOCAL_ARTIFACT"
  remote "sha256sum /opt/openFrameworks/apps/myApps/PGeneratorBuild/pattern_generator/bin/pattern_generator /usr/sbin/PGeneratord /usr/sbin/PGeneratord.dv"

  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"

  rgbsw=$(remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config")
  echo "[rgb-switch] $rgbsw"
  if echo "$rgbsw" | grep -q '"restart":true'; then
    for _ in $(seq 1 120); do
      remote "ps -eo pid,comm,args | grep -q '/usr/sbin/PGeneratord 1920 1080'" && break
    done
  fi
  sleep 10
  capture_state "rgb-settled-T+10"

  ysw=$(remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"1\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config")
  echo "[ycbcr-switch] $ysw"
  if echo "$ysw" | grep -q '"restart":true'; then
    for _ in $(seq 1 120); do
      remote "ps -eo pid,comm,args | grep -q '/usr/sbin/PGeneratord 1920 1080'" && break
    done
  fi
  sleep 15
  capture_state "ycbcr444-settled-T+15"

  meter_probe red 255 0 0
  meter_probe green 0 255 0
  meter_probe blue 0 0 255
  meter_probe white 255 255 255
  meter_probe black 0 0 0
  meter_probe gray50 128 128 128

  echo "[transition-sequence red->green->blue->red]" | tee -a "$LOG"
  for p in red green blue red; do
    remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"$p\"}' http://127.0.0.1/api/pattern" | tee -a "$LOG"
  done
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"

  rgbsw2=$(remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config")
  echo "[rgb-regression-switch] $rgbsw2"
  if echo "$rgbsw2" | grep -q '"restart":true'; then
    for _ in $(seq 1 120); do
      remote "ps -eo pid,comm,args | grep -q '/usr/sbin/PGeneratord 1920 1080'" && break
    done
  fi
  sleep 10
  capture_state "rgb-regression-settled-T+10"
  meter_probe rgb_red 255 0 0
  meter_probe rgb_green 0 255 0
  meter_probe rgb_blue 0 0 255
  meter_probe rgb_white 255 255 255

  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config >/dev/null 2>&1 || true"
  echo "LOG_FILE=$LOG"
} | tee "$LOG"

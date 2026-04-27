#!/usr/bin/env bash
set -euo pipefail
PI='root@192.168.1.177'
PASS='PGenerator!!$'
remote(){ SSHPASS="$PASS" sshpass -e ssh -o StrictHostKeyChecking=no "$PI" "$1"; }

probe(){
  local label="$1" r="$2" g="$3" b="$4" max_polls="${5:-35}"
  echo "[$label]"
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"patch_r\":$r,\"patch_g\":$g,\"patch_b\":$b,\"patch_size\":100,\"signal_mode\":\"sdr\"}' http://127.0.0.1/api/meter/read" >/dev/null
  for _ in $(seq 1 "$max_polls"); do
    out=$(remote "curl -s http://127.0.0.1/api/meter/read/result")
    echo "$out"
    echo "$out" | grep -q '"readings"' && break
  done
  remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
}

echo "[ycbcr-black-retry-setup]"
remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"1\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config; echo"
for _ in $(seq 1 120); do
  remote "ps -eo pid,comm,args | grep -q '/usr/sbin/PGeneratord 1920 1080'" && break
  sleep 0.25
done
sleep 15
remote "curl -s http://127.0.0.1/api/config; echo; curl -s http://127.0.0.1/api/infoframes; echo"
probe ycbcr_black_retry 0 0 0 45

echo "[rgb-regression-setup]"
remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config; echo"
for _ in $(seq 1 120); do
  remote "ps -eo pid,comm,args | grep -q '/usr/sbin/PGeneratord 1920 1080'" && break
  sleep 0.25
done
sleep 10
remote "curl -s http://127.0.0.1/api/config; echo; curl -s http://127.0.0.1/api/infoframes; echo"
probe rgb_red 255 0 0
probe rgb_green 0 255 0
probe rgb_blue 0 0 255
probe rgb_white 255 255 255

remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"name\":\"stop\"}' http://127.0.0.1/api/pattern >/dev/null 2>&1 || true"
remote "curl -s -X POST -H 'Content-Type: application/json' --data '{\"color_format\":\"0\",\"signal_mode\":\"sdr\",\"colorimetry\":\"2\",\"rgb_quant_range\":\"2\",\"max_bpc\":\"8\"}' http://127.0.0.1/api/config; echo"

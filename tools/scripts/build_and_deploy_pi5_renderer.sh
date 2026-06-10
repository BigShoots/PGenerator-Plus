#!/usr/bin/env bash
# Build (and optionally deploy) the Pi5 renderer.
#
# The Pi5 renderer is built NATIVELY on the Pi5 (like the Pi4 flow), in
# /root/pgplus-build/pattern_generator against the openFrameworks tree at
# /root/pgplus-build/openFrameworks. The cross env at /home/jordan/pgplus-cross/
# is NOT the production build path. gstreamer is the Pi5's real system
# gstreamer-1.0 dev stack (libgstreamer1.0-dev etc.) - never use fake
# pkg-config stubs.
#
# Usage:
#   tools/scripts/build_and_deploy_pi5_renderer.sh           # sync + build only
#   tools/scripts/build_and_deploy_pi5_renderer.sh --deploy  # + install/restart
set -euo pipefail

PI=192.168.1.249
PI_USER=root
PI_PASS='PGenerator!!$'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_APP="$REPO_ROOT/tools/image-targets/pi5-bookworm-armhf/src/pattern_generator/src"
SRC_ADDON="$REPO_ROOT/tools/image-targets/pi5-bookworm-armhf/src/ofxRPI4Window/src"
BUILD_DIR=/root/pgplus-build/pattern_generator
OF_ROOT=/root/pgplus-build/openFrameworks
DEPLOY=0
[ "${1:-}" = "--deploy" ] && DEPLOY=1

run() { sshpass -p "$PI_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PI_USER@$PI" "$@"; }
copy() { sshpass -p "$PI_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

# Refuse to deploy while a calibration / meter session is active.
if [ "$DEPLOY" = 1 ]; then
 STATUS=$(curl -s --max-time 5 "http://$PI/api/meter/lg-autocal/status" || true)
 case "$STATUS" in *'"idle"'*) ;; *) echo "Refusing to deploy: autocal status is not idle: $STATUS" >&2; exit 1;; esac
fi

# Real gstreamer-1.0 dev stack must be present on the Pi (no stub fallback).
run "pkg-config gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-base-1.0 --exists" || {
 echo "Pi5 is missing the real gstreamer-1.0 dev packages (libgstreamer1.0-dev," >&2
 echo "libgstreamer-plugins-base1.0-dev). Install them; do NOT use fake .pc stubs." >&2
 exit 1
}

TS=$(date +%Y%m%d-%H%M%S)
echo "== backup current build tree sources =="
run "mkdir -p /root/pgen-build-backups/$TS && cp $OF_ROOT/addons/ofxRPI4Window/src/ofxRPI4Window.cpp /root/pgen-build-backups/$TS/ 2>/dev/null; cp $BUILD_DIR/bin/pattern_generator /root/pgen-build-backups/$TS/ 2>/dev/null || true"

echo "== sync sources from repo =="
copy "$SRC_APP"/main.cpp "$SRC_APP"/ofApp.cpp "$SRC_APP"/ofApp.h "$SRC_APP"/rgb2ycbcr.h "$PI_USER@$PI:$BUILD_DIR/src/"
copy "$SRC_ADDON"/ofxRPI4Window.cpp "$SRC_ADDON"/ofxRPI4Window.h "$SRC_ADDON"/igt_edid.h "$PI_USER@$PI:$OF_ROOT/addons/ofxRPI4Window/src/"

echo "== build (native, incremental) =="
run "cd $BUILD_DIR && make -j4 OF_ROOT=$OF_ROOT" | tail -5
[ "$(run "ldd $BUILD_DIR/bin/pattern_generator | grep -c 'not found'" | tail -1 | tr -d '[:space:]')" = "0" ] || { echo "ldd reports unresolved libraries" >&2; exit 1; }
run "strings $BUILD_DIR/bin/pattern_generator | grep -q '/etc/PGenerator/PGenerator.conf'" || { echo "conf path missing from binary" >&2; exit 1; }
echo "== built: =="
run "md5sum $BUILD_DIR/bin/pattern_generator; ls -la $BUILD_DIR/bin/pattern_generator"

if [ "$DEPLOY" = 1 ]; then
 echo "== deploy =="
 # Install via rename: the renderer may be running and a plain cp over a
 # busy text file fails (ETXTBSY); rename replaces the path atomically.
 run "mkdir -p /root/pgen-backups/$TS && cp -a /usr/sbin/PGeneratord /usr/sbin/PGeneratord.dv /root/pgen-backups/$TS/ && cp $BUILD_DIR/bin/pattern_generator /usr/sbin/PGeneratord.new && chmod 755 /usr/sbin/PGeneratord.new && cp $BUILD_DIR/bin/pattern_generator /usr/sbin/PGeneratord.dv.new && chmod 755 /usr/sbin/PGeneratord.dv.new && mv -f /usr/sbin/PGeneratord.new /usr/sbin/PGeneratord && mv -f /usr/sbin/PGeneratord.dv.new /usr/sbin/PGeneratord.dv"
 run "/etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null & exit" || true
 sleep 8
 PING=$(curl -s --max-time 8 "http://$PI/api/ping" || true)
 echo "ping: $PING"
 case "$PING" in *'"ok":1'*) echo "deploy ok (backups in /root/pgen-backups/$TS/)";; *) echo "DAEMON NOT RESPONDING - restore from /root/pgen-backups/$TS/ if needed" >&2; exit 1;; esac
fi

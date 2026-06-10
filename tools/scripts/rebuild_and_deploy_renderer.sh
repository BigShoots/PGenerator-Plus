#!/usr/bin/env bash
# Build the renderer on the Pi4 using the existing /root/pgen-build dir.
# Reuses the openFrameworks build artifacts already on the Pi.
set -euo pipefail

PI_HOST="192.168.1.179"
PI_USER="root"
PI_PASSWORD='PGenerator!!$'
SOURCE_ROOT="/mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus"
REMOTE_BUILD_DIR="/root/pgen-build/pattern_generator"
REMOTE_OF_ROOT="/opt/openFrameworks"
REMOTE_ADDON_DIR="/opt/openFrameworks/addons/ofxRPI4Window/src"
REMOTE_BINARY="/usr/sbin/PGeneratord"
REMOTE_DV_BINARY="/usr/sbin/PGeneratord.dv"
JOBS=2
DO_DEPLOY=0

usage() {
  cat <<'EOF'
Usage: rebuild_and_deploy_renderer.sh [options]

Rebuild the PGeneratord renderer on the Pi4 from the current repo source
and (optionally) deploy it to /usr/sbin.

Options:
  --deploy                 Stop the service, install the rebuilt binary, restart.
  --build-only             Build only. Do not deploy.
  --source-root PATH       Local source root. Default: the repo root.
  --host HOST              Pi host. Default: 192.168.1.179
  --jobs N                 Parallel make jobs. Default: 2
  --help                   Show this help.

The remote build dir is hardcoded to /root/pgen-build/pattern_generator
which already has the openFrameworks compile artifacts. We sync the
new sources into that dir, run make, and (optionally) copy the binary
out to /usr/sbin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE_ROOT="$2"; shift 2 ;;
    --host) PI_HOST="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --deploy) DO_DEPLOY=1; shift ;;
    --build-only) DO_DEPLOY=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd sshpass
require_cmd ssh
require_cmd scp

SSH_BASE=(sshpass -p "$PI_PASSWORD" ssh -o StrictHostKeyChecking=no "$PI_USER@$PI_HOST")
SCP_BASE=(sshpass -p "$PI_PASSWORD" scp -o StrictHostKeyChecking=no)

remote_run() {
  "${SSH_BASE[@]}" "$@"
}

echo "Pi: $PI_USER@$PI_HOST"
echo "Local source root: $SOURCE_ROOT"
echo "Remote build dir: $REMOTE_BUILD_DIR"
echo "Build scope: ofxRPI4Window.cpp + pattern_generator sources"

echo "Checking SSH connectivity..."
remote_run "echo ok"

echo "Syncing ofxRPI4Window addon sources..."
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp" "$PI_USER@$PI_HOST:$REMOTE_ADDON_DIR/ofxRPI4Window.cpp"
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.h" "$PI_USER@$PI_HOST:$REMOTE_ADDON_DIR/ofxRPI4Window.h"

echo "Syncing pattern_generator sources..."
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.cpp" "$PI_USER@$PI_HOST:$REMOTE_BUILD_DIR/src/ofApp.cpp"
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.h" "$PI_USER@$PI_HOST:$REMOTE_BUILD_DIR/src/ofApp.h"
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/pattern_generator/src/rgb2ycbcr.h" "$PI_USER@$PI_HOST:$REMOTE_BUILD_DIR/src/rgb2ycbcr.h"
"${SCP_BASE[@]}" "$SOURCE_ROOT/tools/image-targets/pi4-biasi/src/pattern_generator/src/main.cpp" "$PI_USER@$PI_HOST:$REMOTE_BUILD_DIR/src/main.cpp"

echo "Checking gstreamer development support on Pi..."
# The openFrameworks build needs real gstreamer dev files (headers + .pc).
# BiasiLinux ships gstreamer-1.0 dev support in the OS image (no package
# manager exists on the Pi). Fake/stub .pc files are forbidden — if this
# check fails the OS image is broken and must be fixed, not worked around.
remote_run "set -e; \
  for pkg in gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-base-1.0; do \
    if ! pkg-config \$pkg --cflags --libs >/dev/null 2>&1; then \
      echo \"ERROR: \$pkg dev support missing (pkg-config cannot resolve it).\" >&2; \
      echo \"The BiasiLinux image must provide /usr/lib/pkgconfig/\$pkg.pc and\" >&2; \
      echo \"/usr/include/gstreamer-1.0 headers. Do NOT create fake .pc files.\" >&2; \
      exit 1; \
    fi; \
  done; \
  test -f /usr/include/gstreamer-1.0/gst/gst.h || { echo 'ERROR: gstreamer-1.0 headers missing' >&2; exit 1; }; \
  echo \"gstreamer-1.0 dev support OK (\$(pkg-config --modversion gstreamer-1.0))\""

echo "Building renderer on Pi..."
# Flag notes:
# - GST_VERSION=1.0 pins the OF makefile gstreamer selection explicitly
#   (auto-detect picks 1.0 too on this image, but be deterministic).
# - PROJECT_CFLAGS adds -D_GLIBCXX_USE_CXX11_ABI=0 so addon/project objects
#   match the old-ABI prebuilt libopenFrameworks.a. It is appended into the
#   composed CFLAGS, which is used for C++ compiles as well, so the platform
#   defines (-DTARGET_RASPBERRY_PI, -march, addon -I/usr/include/libdrm, ...)
#   are all preserved. Do NOT pass CXXFLAGS=/CFLAGS= on the make command line:
#   a command-line override silently drops all of those platform flags.
# - PLATFORM_CXXFLAGS bumps the C++ standard to c++17 (the default is c++14
#   on this gcc); the rest of the value mirrors the makefile's own setting.
# - Stale .d files from manual compiles use relative paths and break the
#   build, so remove them along with the cached addon object.
remote_run "set -e; \
  export PATH=/usr/local/bin:\$PATH; \
  export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/lib; \
  cd '$REMOTE_BUILD_DIR'; \
  rm -f /opt/openFrameworks/addons/obj/linuxarmv6l/Release/ofxRPI4Window/src/ofxRPI4Window.o \
        /opt/openFrameworks/addons/obj/linuxarmv6l/Release/ofxRPI4Window/src/ofxRPI4Window.d 2>/dev/null; \
  /usr/local/bin/make PLATFORM_OS=Linux PLATFORM_ARCH=armv6l PLATFORM_LIB_SUBPATH=linuxarmv6l PLATFORM_VARIANT=default \
    GST_VERSION=1.0 \
    PROJECT_CFLAGS='-D_GLIBCXX_USE_CXX11_ABI=0' \
    PLATFORM_CXXFLAGS='-Wall -Werror=return-type -std=c++17 -DGCC_HAS_REGEX' \
    -j'$JOBS' 2>&1 | tail -40"

echo "Verifying old-ABI objects (must show no [abi:cxx11] tags)..."
remote_run "nm /opt/openFrameworks/addons/obj/linuxarmv6l/Release/ofxRPI4Window/src/ofxRPI4Window.o | grep getPadding | grep -q 'abi:cxx11' && { echo 'ERROR: ofxRPI4Window.o built with new ABI' >&2; exit 1; } || echo 'ABI check OK'"

echo "Build complete. Remote binary: $REMOTE_BUILD_DIR/bin/pattern_generator"
remote_run "ls -la '$REMOTE_BUILD_DIR/bin/pattern_generator' && sha256sum '$REMOTE_BUILD_DIR/bin/pattern_generator'"

if [[ "$DO_DEPLOY" -eq 1 ]]; then
  echo "Deploying rebuilt binary..."
  remote_run "set -e; \
    cp '$REMOTE_BUILD_DIR/bin/pattern_generator' /tmp/PGeneratord.new; \
    chmod 755 /tmp/PGeneratord.new; \
    /etc/init.d/PGenerator stop >/dev/null 2>&1 || true; \
    install -m 755 /tmp/PGeneratord.new '$REMOTE_BINARY'; \
    install -m 755 /tmp/PGeneratord.new '$REMOTE_DV_BINARY'; \
    rm -f /tmp/PGeneratord.new; \
    sha256sum '$REMOTE_BINARY' '$REMOTE_DV_BINARY'; \
    /etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &"
  sleep 6
  remote_run "ps -ef | grep -E '[P]Generatord' | head"
  remote_run "set -e; \
    for i in 1 2 3 4 5 6 7 8 9 10; do \
      curl -s http://127.0.0.1/api/ping >/dev/null 2>&1 && break; \
      sleep 1; \
    done; \
    curl -s http://127.0.0.1/api/ping; echo; \
    curl -s http://127.0.0.1/api/config | head -c 800; echo"
fi

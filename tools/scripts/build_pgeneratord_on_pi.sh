#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

SOURCE_ROOT_DEFAULT="$WORKSPACE_ROOT/PGenerator_plus"
if [[ ! -d "$SOURCE_ROOT_DEFAULT/src/pattern_generator/src" ]]; then
  SOURCE_ROOT_DEFAULT="$SCRIPT_DIR"
fi

SOURCE_ROOT="$SOURCE_ROOT_DEFAULT"
PI_HOST="192.168.1.179"
PI_USER="root"
PI_PASSWORD="PGenerator!!$"
REMOTE_OF_ROOT="/opt/openFrameworks"
REMOTE_APP_ROOT="$REMOTE_OF_ROOT/apps/myApps/PGeneratorBuild/pattern_generator"
REMOTE_ADDON_ROOT="$REMOTE_OF_ROOT/addons/ofxRPI4Window"
REMOTE_BINARY="/usr/sbin/PGeneratord"
REMOTE_DV_BINARY="/usr/sbin/PGeneratord.dv"
JOBS=2
DO_SYNC=1
DO_DEPLOY=0

usage() {
  cat <<'EOF'
Usage: build_pgeneratord_on_pi.sh [options]

Build the PGeneratord renderer on the Raspberry Pi using the legacy
openFrameworks flags that this project actually requires.

Note:
  This script rebuilds and deploys the userspace renderer binary only.
  It does not rebuild or install vc4 kernel/driver patches (for example
  drm_vc4.patch changes require a separate kernel build/deploy path).

Options:
  --source-root PATH       Local source tree to sync from.
                           Default: ../PGenerator_plus when present, else PGenerator_Source.
  --host HOST              Pi host. Default: 192.168.1.177
  --user USER              SSH user. Default: root
  --password PASS          SSH password. Default: PGenerator!!$
  --remote-of-root PATH    Remote openFrameworks root. Default: /opt/openFrameworks
  --jobs N                 Parallel make jobs. Default: 2
  --deploy                 Stop the service, install the rebuilt binary to both runtime paths,
                           restart the service.
  --build-only             Build only. Do not deploy.
  --no-sync                Skip source sync and only build whatever is already on the Pi.
  --help                   Show this help.

Examples:
  ./build_pgeneratord_on_pi.sh
  ./build_pgeneratord_on_pi.sh --deploy
  ./build_pgeneratord_on_pi.sh --source-root ../PGenerator_plus --deploy --jobs 4
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --host)
      PI_HOST="$2"
      shift 2
      ;;
    --user)
      PI_USER="$2"
      shift 2
      ;;
    --password)
      PI_PASSWORD="$2"
      shift 2
      ;;
    --remote-of-root)
      REMOTE_OF_ROOT="$2"
      REMOTE_APP_ROOT="$REMOTE_OF_ROOT/apps/myApps/PGeneratorBuild/pattern_generator"
      REMOTE_ADDON_ROOT="$REMOTE_OF_ROOT/addons/ofxRPI4Window"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --deploy)
      DO_DEPLOY=1
      shift
      ;;
    --build-only)
      DO_DEPLOY=0
      shift
      ;;
    --no-sync)
      DO_SYNC=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
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

if [[ ! -d "$SOURCE_ROOT/src/pattern_generator/src" ]]; then
  echo "Source root does not look like a PGenerator renderer tree: $SOURCE_ROOT" >&2
  exit 1
fi

SSH_BASE=(sshpass -p "$PI_PASSWORD" ssh -o StrictHostKeyChecking=no "$PI_USER@$PI_HOST")
SCP_BASE=(sshpass -p "$PI_PASSWORD" scp -o StrictHostKeyChecking=no)

remote_run() {
  "${SSH_BASE[@]}" "$@"
}

echo "Pi: $PI_USER@$PI_HOST"
echo "Local source root: $SOURCE_ROOT"
echo "Remote OF root: $REMOTE_OF_ROOT"
echo "Build scope: userspace renderer only (no kernel/driver patch rebuild)"

echo "Checking SSH connectivity..."
remote_run "echo ok"

if [[ "$DO_SYNC" -eq 1 ]]; then
  echo "Syncing pattern_generator sources..."
  "${SCP_BASE[@]}" "$SOURCE_ROOT/src/pattern_generator/src/ofApp.cpp" "$PI_USER@$PI_HOST:$REMOTE_APP_ROOT/src/ofApp.cpp"
  if [[ -f "$SOURCE_ROOT/src/pattern_generator/src/ofApp.h" ]]; then
    "${SCP_BASE[@]}" "$SOURCE_ROOT/src/pattern_generator/src/ofApp.h" "$PI_USER@$PI_HOST:$REMOTE_APP_ROOT/src/ofApp.h"
  fi
  if [[ -f "$SOURCE_ROOT/src/pattern_generator/src/rgb2ycbcr.h" ]]; then
    "${SCP_BASE[@]}" "$SOURCE_ROOT/src/pattern_generator/src/rgb2ycbcr.h" "$PI_USER@$PI_HOST:$REMOTE_APP_ROOT/src/rgb2ycbcr.h"
  fi
  if [[ -f "$SOURCE_ROOT/src/pattern_generator/src/main.cpp" ]]; then
    "${SCP_BASE[@]}" "$SOURCE_ROOT/src/pattern_generator/src/main.cpp" "$PI_USER@$PI_HOST:$REMOTE_APP_ROOT/src/main.cpp"
  fi

  echo "Syncing ofxRPI4Window addon sources..."
  "${SCP_BASE[@]}" "$SOURCE_ROOT/src/ofxRPI4Window/src/ofxRPI4Window.cpp" "$PI_USER@$PI_HOST:$REMOTE_ADDON_ROOT/src/ofxRPI4Window.cpp"
  if [[ -f "$SOURCE_ROOT/src/ofxRPI4Window/src/ofxRPI4Window.h" ]]; then
    "${SCP_BASE[@]}" "$SOURCE_ROOT/src/ofxRPI4Window/src/ofxRPI4Window.h" "$PI_USER@$PI_HOST:$REMOTE_ADDON_ROOT/src/ofxRPI4Window.h"
  fi
  if [[ -f "$SOURCE_ROOT/src/ofxRPI4Window/addon_config.mk" ]]; then
    "${SCP_BASE[@]}" "$SOURCE_ROOT/src/ofxRPI4Window/addon_config.mk" "$PI_USER@$PI_HOST:$REMOTE_ADDON_ROOT/addon_config.mk"
  fi
fi

echo "Checking gstreamer development support on Pi..."
# Real gstreamer-1.0 dev files (headers + .pc) ship with the BiasiLinux image.
# Fake/stub .pc files are forbidden.
remote_run "set -e; \
  for pkg in gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-base-1.0; do \
    pkg-config \$pkg --cflags --libs >/dev/null 2>&1 || { echo \"ERROR: \$pkg dev support missing; the OS image must provide it. Do NOT create fake .pc files.\" >&2; exit 1; }; \
  done; \
  echo \"gstreamer-1.0 dev support OK (\$(pkg-config --modversion gstreamer-1.0))\""

echo "Building renderer on Pi..."
# GST_VERSION=1.0 pins the OF gstreamer selection; PROJECT_CFLAGS adds the
# old-ABI define without clobbering platform flags (never pass CXXFLAGS= or
# CFLAGS= on the make command line); PLATFORM_CXXFLAGS bumps to c++17.
remote_run "set -e; \
  export PATH=/usr/local/bin:\$PATH; \
  export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/lib; \
  cd '$REMOTE_APP_ROOT'; \
  /usr/local/bin/make PLATFORM_OS=Linux PLATFORM_ARCH=armv6l PLATFORM_LIB_SUBPATH=linuxarmv6l PLATFORM_VARIANT=default \
    GST_VERSION=1.0 \
    PROJECT_CFLAGS='-D_GLIBCXX_USE_CXX11_ABI=0' \
    PLATFORM_CXXFLAGS='-Wall -Werror=return-type -std=c++17 -DGCC_HAS_REGEX' \
    -j'$JOBS'"

echo "Build complete. Remote binary: $REMOTE_APP_ROOT/bin/pattern_generator"
remote_run "sha256sum '$REMOTE_APP_ROOT/bin/pattern_generator'"

if [[ "$DO_DEPLOY" -eq 1 ]]; then
  echo "Deploying rebuilt binary..."
  remote_run "cp '$REMOTE_APP_ROOT/bin/pattern_generator' /tmp/PGeneratord.new"
  remote_run "set +e; \
    systemctl stop pgenerator >/dev/null 2>&1 || \
    systemctl stop PGenerator >/dev/null 2>&1 || \
    /etc/init.d/PGenerator stop >/dev/null 2>&1 || \
    /etc/init.d/rcPGenerator stop >/dev/null 2>&1 || \
    true"
  remote_run "set -e; \
    install -m 755 /tmp/PGeneratord.new '$REMOTE_BINARY'; \
    install -m 755 /tmp/PGeneratord.new '$REMOTE_DV_BINARY'; \
    rm -f /tmp/PGeneratord.new; \
    sha256sum '$REMOTE_BINARY' '$REMOTE_DV_BINARY'"
  remote_run "set +e; \
    systemctl start pgenerator >/dev/null 2>&1 || \
    systemctl start PGenerator >/dev/null 2>&1 || \
    /etc/init.d/PGenerator start >/dev/null 2>&1 || \
    /etc/init.d/rcPGenerator start >/dev/null 2>&1 || \
    true"
  remote_run "set -e; \
    for i in 1 2 3 4 5 6 7 8 9 10; do \
      curl -s http://127.0.0.1/api/ping >/dev/null 2>&1 && break; \
      sleep 1; \
    done; \
    curl -s http://127.0.0.1/api/ping; echo; \
    curl -s http://127.0.0.1/api/config; echo"
fi
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$REPO_ROOT/usr/bin"
SOURCE_DIR=""
SOURCE_TARBALL=""
EXTRACT_DIR=""
STRIP_BIN="${STRIP_BIN:-arm-linux-gnueabihf-strip}"
ARGYLL_RUNTIME_REQUIRED_BINS=(ccxxmake)
ARGYLL_RUNTIME_OPTIONAL_BINS=(spotread chartread colprof i1d3ccss oeminst dispread dispcal)

usage() {
 cat <<EOF
Usage:
  ./tools/import_argyll_runtime.sh --source-dir /path/to/argyll-runtime/bin [--target-dir /path/to/usr/bin] [--no-strip]
  ./tools/import_argyll_runtime.sh --source-tarball /path/to/argyllcms-linux-armhf-v3.5.0.tar.gz [--target-dir /path/to/usr/bin] [--no-strip]

Copies the headless armhf ArgyllCMS runtime slice into the repo's usr/bin
payload so PGenerator+ can ship on-device TI3 -> CCSS conversion via
ccxxmake. Optional helpers present in the source are imported too.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

cleanup() {
 set +e
 if [[ -n "$EXTRACT_DIR" ]] && [[ -d "$EXTRACT_DIR" ]]; then
  rm -rf "$EXTRACT_DIR"
 fi
}

trap cleanup EXIT

resolve_source_dir() {
 if [[ -n "$SOURCE_DIR" ]] && [[ -n "$SOURCE_TARBALL" ]]; then
  die "Specify only one of --source-dir or --source-tarball"
 fi

 if [[ -n "$SOURCE_TARBALL" ]]; then
  [[ -f "$SOURCE_TARBALL" ]] || die "Source tarball does not exist: $SOURCE_TARBALL"
  EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-argyll-runtime.XXXXXX")"
  tar xzf "$SOURCE_TARBALL" -C "$EXTRACT_DIR"
  SOURCE_DIR="$(find "$EXTRACT_DIR" -maxdepth 2 -type d -name bin | head -n 1)"
  [[ -n "$SOURCE_DIR" ]] || die "Could not locate a bin/ directory inside $SOURCE_TARBALL"
 fi

 [[ -n "$SOURCE_DIR" ]] || die "Either --source-dir or --source-tarball is required"
 [[ -d "$SOURCE_DIR" ]] || die "Source directory does not exist: $SOURCE_DIR"
}

NO_STRIP=0

while [[ $# -gt 0 ]]; do
 case "$1" in
  --source-dir)
   [[ $# -ge 2 ]] || die "Missing value for --source-dir"
   SOURCE_DIR="$2"
   shift 2
   ;;
  --source-tarball)
   [[ $# -ge 2 ]] || die "Missing value for --source-tarball"
   SOURCE_TARBALL="$2"
   shift 2
   ;;
  --target-dir)
   [[ $# -ge 2 ]] || die "Missing value for --target-dir"
   TARGET_DIR="$2"
   shift 2
   ;;
  --no-strip)
   NO_STRIP=1
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

resolve_source_dir
mkdir -p "$TARGET_DIR"

missing=()
imported=()
for bin in "${ARGYLL_RUNTIME_REQUIRED_BINS[@]}"; do
 src="$SOURCE_DIR/$bin"
 [[ -f "$src" ]] || {
  missing+=("$bin")
  continue
 }
 install -m 0755 "$src" "$TARGET_DIR/$bin"
 if [[ "$NO_STRIP" -ne 1 ]] && command -v "$STRIP_BIN" >/dev/null 2>&1; then
  "$STRIP_BIN" "$TARGET_DIR/$bin" 2>/dev/null || true
 fi
  imported+=("$bin")
done

if [[ ${#missing[@]} -gt 0 ]]; then
 printf 'Missing Argyll runtime binaries in %s:\n' "$SOURCE_DIR" >&2
 printf '  %s\n' "${missing[@]}" >&2
 exit 1
fi

for bin in "${ARGYLL_RUNTIME_OPTIONAL_BINS[@]}"; do
 src="$SOURCE_DIR/$bin"
 [[ -f "$src" ]] || continue
 install -m 0755 "$src" "$TARGET_DIR/$bin"
 if [[ "$NO_STRIP" -ne 1 ]] && command -v "$STRIP_BIN" >/dev/null 2>&1; then
  "$STRIP_BIN" "$TARGET_DIR/$bin" 2>/dev/null || true
 fi
 imported+=("$bin")
done

printf 'Imported Argyll runtime into %s:\n' "$TARGET_DIR"
printf '  %s\n' "${imported[@]}"
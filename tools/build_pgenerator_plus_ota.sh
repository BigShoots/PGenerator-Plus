#!/usr/bin/env bash

# build_pgenerator_plus_ota.sh — Build the cumulative OTA tarball used by
# pgenerator-update.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"
MANIFEST_CHECKER="$REPO_ROOT/tools/check_release_manifest.sh"

FORCE_OUTPUT=0
KEEP_STAGING=0
TARGET="pi4-biasi"
TARGET_OVERLAY_REL=""
TARGET_DESCRIPTION=""
OUTPUT_TARBALL=""
STAGING_DIR=""
TARGET_OWNED_RUNTIME_PATHS=(
 "usr/share/PGenerator/command.pm"
 "usr/share/PGenerator/conf.pm"
 "usr/share/PGenerator/variables.pm"
 "usr/bin/PGeneratorDisplayMirror"
 "usr/bin/pgcec"
 "usr/lib/drm_override.c"
 "usr/lib/drm_override.so"
 "usr/lib/scdc_tool"
 "usr/lib/scdc_tool.c"
 "usr/sbin/PGeneratord"
 "usr/sbin/PGeneratord.dv"
 "usr/sbin/disable_csc"
 "usr/sbin/disable_csc.c"
 "usr/sbin/drm_player"
 "usr/sbin/drm_player.c"
 "usr/sbin/fb_player"
 "usr/sbin/fb_player.c"
 "usr/sbin/pg_diag_video_player"
 "usr/sbin/pgenerator-cec"
 "usr/sbin/write_csc.c"
)

log() {
 echo "[build-ota] $*"
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

usage() {
 cat <<EOF
Usage:
  ./tools/build_pgenerator_plus_ota.sh [options]

Options:
  --output PATH     Output tarball path.
                    Default: build/pgenerator-plus-<version>.tar.gz
  --target NAME     OTA target to package. Default: pi4-biasi.
                    Supported: pi4-biasi, pi5-bookworm-armhf.
  --force           Overwrite the output tarball if it already exists.
  --keep-staging    Keep the temporary staging directory for inspection.
  -h, --help        Show this help text.

Notes:
  - OTA updates always download the latest release tarball only.
  - This tarball must therefore be a cumulative overlay, not a diff.
  - Versioned migration scripts in usr/share/PGenerator/update-migrations.d
    are shipped inside the tarball and run after extraction when needed.
  - Shared UI/calibration files are staged first; renderer, display backend,
    and hardware files are then supplied by tools/image-targets/<target>/rootfs.
EOF
}

cleanup() {
 set +e
 if [[ -n "$STAGING_DIR" ]] && [[ -d "$STAGING_DIR" ]] && [[ "$KEEP_STAGING" -eq 0 ]]; then
  rm -rf "$STAGING_DIR"
 fi
}

trap cleanup EXIT

require_commands() {
 local missing=()
 local cmd
 for cmd in mktemp rsync sed tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
   missing+=("$cmd")
  fi
 done
 if [[ ${#missing[@]} -gt 0 ]]; then
  die "Missing required tools: ${missing[*]}"
 fi
}

repo_version() {
 local version
 version="$(sed -n 's/^\$version="\([^"]*\)";$/\1/p' "$VERSION_FILE" | head -n 1)"
 [[ -n "$version" ]] || die "Could not determine version from $VERSION_FILE"
 echo "$version"
}

abs_target_path() {
 local path="$1"
 mkdir -p "$(dirname "$path")"
 echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --output)
    [[ $# -ge 2 ]] || die "Missing value for --output"
    OUTPUT_TARBALL="$2"
    shift 2
    ;;
   --force)
    FORCE_OUTPUT=1
    shift
    ;;
   --keep-staging)
    KEEP_STAGING=1
    shift
    ;;
   --target)
    [[ $# -ge 2 ]] || die "Missing value for --target"
    TARGET="$2"
    shift 2
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

 case "$TARGET" in
  pi4-biasi|pi5-bookworm-armhf)
   ;;
  *)
   die "Unknown --target: $TARGET"
   ;;
 esac
}

load_target_manifest() {
 local manifest="$REPO_ROOT/tools/image-targets/${TARGET}.env"

 [[ -f "$manifest" ]] || die "Missing target manifest: $manifest"
 # shellcheck disable=SC1090
 . "$manifest"
 log "Loaded target manifest: $manifest (${TARGET_DESCRIPTION:-$TARGET})"
 [[ -n "$TARGET_OVERLAY_REL" ]] || die "Target manifest is missing TARGET_OVERLAY_REL"
}

prepare_paths() {
 local version
 version="$(repo_version)"
 if [[ -z "$OUTPUT_TARBALL" ]]; then
  if [[ "$TARGET" == "pi4-biasi" ]]; then
   OUTPUT_TARBALL="$REPO_ROOT/build/pgenerator-plus-${version}.tar.gz"
  else
   OUTPUT_TARBALL="$REPO_ROOT/build/pgenerator-plus-${version}-${TARGET}.tar.gz"
  fi
 fi
 OUTPUT_TARBALL="$(abs_target_path "$OUTPUT_TARBALL")"
 if [[ -e "$OUTPUT_TARBALL" ]] && [[ "$FORCE_OUTPUT" -ne 1 ]]; then
  die "Output tarball already exists: $OUTPUT_TARBALL (use --force to overwrite)"
 fi
}

shared_rsync_excludes_for_rel() {
 local rel="$1"
 local owned
 for owned in "${TARGET_OWNED_RUNTIME_PATHS[@]}"; do
  case "$owned" in
   "$rel"/*)
    printf '%s\n' "--exclude=/${owned#$rel/}"
    ;;
  esac
 done
}

stage_overlay() {
 local rel src dst target_overlay
 local rsync_args=()
 STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-ota-build.XXXXXX")"
 for rel in etc usr var lib; do
  src="$REPO_ROOT/$rel"
  [[ -d "$src" ]] || continue
  dst="$STAGING_DIR/$rel"
  mkdir -p "$dst"
  mapfile -t rsync_args < <(shared_rsync_excludes_for_rel "$rel")
  log "Staging shared /$rel"
  rsync -a --delete "${rsync_args[@]}" -- "$src/" "$dst/"
 done

 target_overlay="$REPO_ROOT/$TARGET_OVERLAY_REL"
 [[ -d "$target_overlay" ]] || die "Target overlay directory not found: $target_overlay"
 for rel in etc usr var lib; do
  src="$target_overlay/$rel"
  [[ -d "$src" ]] || continue
  dst="$STAGING_DIR/$rel"
  mkdir -p "$dst"
  log "Staging target /$rel from $TARGET_OVERLAY_REL"
  rsync -a -- "$src/" "$dst/"
 done

 # OTA bundles should not ship transient runtime state.
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/tmp"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/running/tmp"
 : > "$STAGING_DIR/var/lib/PGenerator/operations.txt"
 rm -f "$STAGING_DIR/usr/share/PGenerator/meter_settings.json"
 rm -f "$STAGING_DIR/usr/sbin/PGeneratord.hdr"
}

build_tarball() {
 local roots=()
 local rel
 rm -f "$OUTPUT_TARBALL"
 for rel in etc usr var lib; do
  [[ -d "$STAGING_DIR/$rel" ]] && roots+=("$rel")
 done
 [[ ${#roots[@]} -gt 0 ]] || die "Nothing to package"
 log "Creating $OUTPUT_TARBALL"
 (
  cd "$STAGING_DIR"
  tar --owner=0 --group=0 --numeric-owner -czf "$OUTPUT_TARBALL" "${roots[@]}"
 )
}

validate_tarball() {
 log "Validating release manifest"
 "$MANIFEST_CHECKER" --tarball "$OUTPUT_TARBALL"
}

main() {
 parse_args "$@"
 load_target_manifest
 require_commands
 prepare_paths
 stage_overlay
 build_tarball
 validate_tarball
 log "Build complete: $OUTPUT_TARBALL"
 if [[ "$KEEP_STAGING" -eq 1 ]]; then
  log "Temporary staging directory kept at $STAGING_DIR"
 fi
}

main "$@"

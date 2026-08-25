#!/usr/bin/env bash

# build_pgenerator_plus_ota.sh — Build the cumulative OTA tarball used by
# pgenerator-update.

set -euo pipefail

# Prevent macOS tar from adding AppleDouble ._* metadata entries to release
# archives. The manifest and Web UI checks below also reject any that remain.
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"
MANIFEST_CHECKER="$REPO_ROOT/tools/check_release_manifest.sh"
FRAGMENT_CHECKER="$REPO_ROOT/t/check_webui_package.pl"

FORCE_OUTPUT=0
KEEP_STAGING=0
ALLOW_REMOVALS=0
SKIP_PREV_CHECK=0
PREVIOUS_TARBALL=""
TARGET="pi4-biasi"
TARGET_OVERLAY_REL=""
TARGET_DESCRIPTION=""
OUTPUT_TARBALL=""
STAGING_DIR=""
ARCHIVE_CREATED=0
GITHUB_REPO="${GITHUB_REPO:-BigShoots/PGenerator-Plus}"

# Device-owned state: files the DEVICE writes (operator settings,
# per-display calibration artifacts, boot flags). An OTA tarball is
# extracted verbatim over / by every past updater, so the ONLY way to
# protect these on already-shipped devices is to never package them.
# PGenerator.conf ships as PGenerator.conf.dist instead; pgenerator-update
# (>= 2.8.5) and the 2.8.5-merge-conf-defaults.sh migration merge new
# default keys into the live conf without touching operator values.
DEVICE_STATE_DROPS=(
 "etc/PGenerator/hdr20_postcal_shadow_matrix.json"
 "etc/PGenerator/lut.txt"
 "etc/BiasiLinux/BiasiLinux.FirstBoot"
)
TARGET_OWNED_RUNTIME_PATHS=(
 "usr/share/PGenerator/command.pm"
 "usr/share/PGenerator/conf.pm"
 "usr/bin/PGeneratorDisplayMirror"
 "usr/bin/pgcec"
 "usr/bin/cec-ctl"
 "usr/bin/cec-compliance"
 "usr/bin/cec-follower"
 "usr/bin/python3"
 "usr/bin/python3.5"
 "usr/bin/python3.5m"
 "usr/lib/python3.5"
 "usr/bin/pgsethdr"
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
EXTERNAL_ICC_TOOL_PATHS=(
 "usr/bin/icc_companion_package.py"
 "usr/share/PGenerator/icc-companion"
 "usr/share/PGenerator/icc-companion-src"
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
  --previous PATH   Previous release OTA tarball to diff against for the
                    removed-file guard. Default: auto-download the latest
                    published release asset via gh.
  --allow-removals  Permit files that existed in the previous release to be
                    absent from this tarball without a covering migration.
  --skip-prev-check Skip the previous-release comparison entirely.
  --force           Overwrite the output tarball if it already exists.
  --keep-staging    Keep the temporary staging directory for inspection.
  -h, --help        Show this help text.

Notes:
  - OTA updates always download the LATEST release tarball only — a device
    on any older version of the same MAJOR.MINOR family jumps straight to
    it. Every tarball must therefore be a cumulative overlay of the full
    runtime tree, never a diff against the previous release.
  - A tar overlay can never DELETE a file from a device. If a runtime file
    is removed or renamed between releases, ship a versioned migration in
    usr/share/PGenerator/update-migrations.d that removes the stale copy
    (see 2.3.1-prune-stale-renderers.sh). The removed-file guard below
    fails the build when files vanish with no new migration.
  - Device-owned state (PGenerator.conf, per-display calibration artifacts,
    first-boot flags) is never packaged; factory defaults ship as
    PGenerator.conf.dist and are key-merged on the device.
  - Versioned migration scripts in usr/share/PGenerator/update-migrations.d
    are shipped inside the tarball and run after extraction when needed.
  - Shared UI/calibration files are staged first; renderer, display backend,
    and hardware files are then supplied by tools/image-targets/<target>/rootfs.
EOF
}

cleanup() {
 local rc=$?
 set +e
 if [[ -n "$STAGING_DIR" ]] && [[ -d "$STAGING_DIR" ]] && [[ "$KEEP_STAGING" -eq 0 ]]; then
  rm -rf "$STAGING_DIR"
 fi
 # Do not leave a tarball that failed either release-manifest validation or
 # the split-Web-UI completeness checks ready to publish accidentally.
 if [[ "$rc" -ne 0 ]] && [[ "$ARCHIVE_CREATED" -eq 1 ]] && [[ -e "$OUTPUT_TARBALL" ]]; then
  rm -f "$OUTPUT_TARBALL"
  echo "ERROR: removed invalid archive: $OUTPUT_TARBALL" >&2
 fi
 return "$rc"
}

trap cleanup EXIT

require_commands() {
 local missing=()
 local cmd
 for cmd in file install mktemp perl rsync sed strings tar; do
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
   --previous)
    [[ $# -ge 2 ]] || die "Missing value for --previous"
    PREVIOUS_TARBALL="$2"
    shift 2
    ;;
   --allow-removals)
    ALLOW_REMOVALS=1
    shift
    ;;
   --skip-prev-check)
    SKIP_PREV_CHECK=1
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
 for owned in "${TARGET_OWNED_RUNTIME_PATHS[@]}" "${EXTERNAL_ICC_TOOL_PATHS[@]}"; do
  case "$owned" in
   "$rel"/*)
    printf '%s\n' "--exclude=/${owned#$rel/}"
    ;;
  esac
 done
}

remove_external_icc_tools() {
 local rel

 log "Excluding standalone ICC Tools supplied through GitHub releases"
 for rel in "${EXTERNAL_ICC_TOOL_PATHS[@]}"; do
  rm -rf -- "$STAGING_DIR/$rel"
 done
}

stage_destination_for_rel() {
 local rel="$1"

 if [[ "$TARGET" == "pi5-bookworm-armhf" ]] && [[ "$rel" == "lib" ]]; then
  # Raspberry Pi OS Bookworm is usrmerged. Shipping a top-level lib/
  # directory in a tar overlay can replace /lib -> usr/lib on extraction and
  # leave /sbin/init unable to resolve /lib/systemd/systemd.
  printf '%s\n' "$STAGING_DIR/usr/lib"
  return
 fi

 printf '%s\n' "$STAGING_DIR/$rel"
}

rsync_delete_args_for_rel() {
 local rel="$1"

 if [[ "$TARGET" == "pi5-bookworm-armhf" ]] && [[ "$rel" == "lib" ]]; then
  return
 fi

 printf '%s\n' "--delete"
}

stage_overlay() {
 local rel src dst target_overlay
 local rsync_args=()
 local delete_args=()
 STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-ota-build.XXXXXX")"
 for rel in etc usr var lib; do
  src="$REPO_ROOT/$rel"
  [[ -d "$src" ]] || continue
  dst="$(stage_destination_for_rel "$rel")"
  mkdir -p "$dst"
  mapfile -t rsync_args < <(shared_rsync_excludes_for_rel "$rel")
  mapfile -t delete_args < <(rsync_delete_args_for_rel "$rel")
  if [[ "$TARGET" == "pi5-bookworm-armhf" ]] && [[ "$rel" == "lib" ]]; then
   log "Staging shared /lib into /usr/lib for Pi 5 usrmerge"
  else
    log "Staging shared /$rel"
   fi
   rsync -aI "${delete_args[@]}" "${rsync_args[@]}" --exclude='.__smb*' --exclude='.DS_Store' -- "$src/" "$dst/"
  done

 target_overlay="$REPO_ROOT/$TARGET_OVERLAY_REL"
 [[ -d "$target_overlay" ]] || die "Target overlay directory not found: $target_overlay"
 for rel in etc usr var lib; do
  src="$target_overlay/$rel"
  [[ -d "$src" ]] || continue
  dst="$(stage_destination_for_rel "$rel")"
  mkdir -p "$dst"
  if [[ "$TARGET" == "pi5-bookworm-armhf" ]] && [[ "$rel" == "lib" ]]; then
   log "Staging target /lib into /usr/lib from $TARGET_OVERLAY_REL"
  else
   log "Staging target /$rel from $TARGET_OVERLAY_REL"
  fi
   rsync -aI --exclude='.__smb*' --exclude='.DS_Store' -- "$src/" "$dst/"
  done

 if [[ "$TARGET" == "pi4-biasi" ]]; then
  # command.pm is canonical in the shared runtime tree for Pi 4. The local
  # target rootfs may contain an older deployment snapshot, so restore the
  # tagged shared copy after applying the hardware overlay.
  log "Restoring canonical Pi 4 command.pm from the shared runtime tree"
  install -m 0644 "$REPO_ROOT/usr/share/PGenerator/command.pm" \
   "$STAGING_DIR/usr/share/PGenerator/command.pm"
 fi

 remove_external_icc_tools

 if [[ -d "$STAGING_DIR/usr/share/PGenerator/update-migrations.d" ]]; then
  find "$STAGING_DIR/usr/share/PGenerator/update-migrations.d" -type f -name '*.sh' \
   -exec chmod 0755 {} +
 fi
for rel in etc/init.d/fake-hwclock etc/init.d/ntp etc/cron.hourly/fake-hwclock; do
 [[ -f "$STAGING_DIR/$rel" ]] && chmod 0755 "$STAGING_DIR/$rel"
done
if [[ -f "$STAGING_DIR/etc/sudo/sudoers.d/PGenerator" ]]; then
 chmod 0440 "$STAGING_DIR/etc/sudo/sudoers.d/PGenerator"
fi

 # Device-owned state must never be packaged: extraction over / would
 # overwrite operator settings / per-display calibration on every update.
 local drop
 for drop in "${DEVICE_STATE_DROPS[@]}"; do
  if [[ -e "$STAGING_DIR/$drop" ]]; then
   log "Dropping device-owned state file from OTA payload: /$drop"
   rm -f "$STAGING_DIR/$drop"
  fi
 done

 if [[ "$TARGET" == "pi4-biasi" ]]; then
  # The Pi 4 image uses glibc 2.21. Keep these binaries independent of the
  # build host and of any newer binary that may exist in a target overlay.
  install -m 0755 "$REPO_ROOT/usr/bin/pgsethdr.static" "$STAGING_DIR/usr/bin/pgsethdr"
  install -m 0755 "$REPO_ROOT/usr/bin/colprof" "$STAGING_DIR/usr/bin/colprof"
  install -m 0755 "$REPO_ROOT/usr/bin/chartread" "$STAGING_DIR/usr/bin/chartread"
 fi
 if [[ -f "$STAGING_DIR/etc/PGenerator/PGenerator.conf" ]]; then
  log "Shipping PGenerator.conf as PGenerator.conf.dist (factory defaults)"
  mv "$STAGING_DIR/etc/PGenerator/PGenerator.conf" \
     "$STAGING_DIR/etc/PGenerator/PGenerator.conf.dist"
 fi

# OTA bundles should not ship transient runtime state.
find "$STAGING_DIR/usr/bin" "$STAGING_DIR/usr/share/PGenerator" \
 -type d -name '__pycache__' -prune -exec rm -rf -- {} + 2>/dev/null || true
mkdir -p "$STAGING_DIR/var/lib/PGenerator/tmp"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/images"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/video/.diagseq"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/frames"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/ccss/custom"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/lg/ddc"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/lg/luts"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/lg/pin-sessions"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/updates"
 mkdir -p "$STAGING_DIR/var/lib/PGenerator/running/tmp"
 : > "$STAGING_DIR/var/lib/PGenerator/operations.txt"
 rm -f "$STAGING_DIR/usr/share/PGenerator/meter_settings.json"
 rm -f "$STAGING_DIR/usr/sbin/PGeneratord.hdr"
}

validate_pi4_legacy_runtime() {
 local max_glibc

 [[ "$TARGET" == "pi4-biasi" ]] || return 0
 [[ -x "$STAGING_DIR/usr/bin/pgsethdr" ]] || die "Pi 4 OTA is missing /usr/bin/pgsethdr"
 [[ -x "$STAGING_DIR/usr/bin/colprof" ]] || die "Pi 4 OTA is missing /usr/bin/colprof"
 [[ -x "$STAGING_DIR/usr/bin/chartread" ]] || die "Pi 4 OTA is missing /usr/bin/chartread"
 file "$STAGING_DIR/usr/bin/pgsethdr" | grep -q 'statically linked' || \
  die "Pi 4 pgsethdr must be the static legacy-compatible build"
 max_glibc="$(strings "$STAGING_DIR/usr/bin/colprof" | grep -E '^GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1)"
 [[ -n "$max_glibc" ]] || die "Could not determine the Pi 4 colprof glibc requirement"
 [[ "$(printf '%s\n%s\n' "$max_glibc" '2.21' | sort -V | tail -1)" == '2.21' ]] || \
  die "Pi 4 colprof requires glibc $max_glibc, newer than the image's glibc 2.21"
 log "Validated Pi 4 runtime compatibility: static pgsethdr, colprof glibc <= $max_glibc"
 max_glibc="$(strings "$STAGING_DIR/usr/bin/chartread" | grep -E '^GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1)"
 [[ -n "$max_glibc" ]] || die "Could not determine the Pi 4 chartread glibc requirement"
 [[ "$(printf '%s\n%s\n' "$max_glibc" '2.21' | sort -V | tail -1)" == '2.21' ]] || \
  die "Pi 4 chartread requires glibc $max_glibc, newer than the image's glibc 2.21"
 log "Validated Pi 4 chartread compatibility: glibc <= $max_glibc"
}

validate_pi5_staging_tree() {
 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 if [[ -e "$STAGING_DIR/lib" || -L "$STAGING_DIR/lib" ]]; then
  die "Pi 5 OTA staging must not contain a root /lib entry; use /usr/lib to preserve usrmerge"
 fi
}

# ── Removed-file guard ──
# A tar overlay can never delete files from a device, so any path that was
# in the previous release but is missing from this build will silently
# linger on OTA-updated devices forever. Deletions/renames must ship a
# versioned migration script that prunes the stale copy. This guard fails
# the build when files vanish and no new migration accompanies them.

_ver_gt() {
 [ "$1" != "$2" ] && [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

_ver_le() {
 [ "$1" = "$2" ] || [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

previous_release_tarball() {
 if [[ -n "$PREVIOUS_TARBALL" ]]; then
  [[ -f "$PREVIOUS_TARBALL" ]] || die "--previous tarball not found: $PREVIOUS_TARBALL"
  printf '%s\n' "$PREVIOUS_TARBALL"
  return 0
 fi
 command -v gh >/dev/null 2>&1 || return 0
 local dl="$STAGING_DIR/.prev-release"
 mkdir -p "$dl"
 if ! gh release download --repo "$GITHUB_REPO" --dir "$dl" \
      --pattern 'pgenerator-plus-*.tar.gz' >/dev/null 2>&1; then
  return 0
 fi
 local candidate
 if [[ "$TARGET" == "pi4-biasi" ]]; then
  candidate="$(find "$dl" -maxdepth 1 -type f -name 'pgenerator-plus-*.tar.gz' \
   ! -name "*-pi5-*" | sort -V | tail -1)"
 else
  candidate="$(find "$dl" -maxdepth 1 -type f -name "pgenerator-plus-*-${TARGET}.tar.gz" \
   | sort -V | tail -1)"
 fi
 [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
 return 0
}

tarball_version() {
 tar xzf "$1" -O usr/share/PGenerator/version.pm 2>/dev/null \
  | sed -n 's/^\$version="\([^"]*\)";$/\1/p' | head -n 1
}

migrations_in_range() {
 local low="$1" high="$2" path base script_version
 while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  base="$(basename "$path")"
  script_version="$(printf '%s' "$base" | sed -E 's/^v?([0-9]+(\.[0-9]+)*).*/\1/')"
  [[ -n "$script_version" && "$script_version" != "$base" ]] || continue
  if _ver_gt "$script_version" "$low" && _ver_le "$script_version" "$high"; then
   printf '%s\n' "$base"
  fi
 done < <(find "$REPO_ROOT/usr/share/PGenerator/update-migrations.d" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -V)
}

check_removed_files() {
 if [[ "$SKIP_PREV_CHECK" -eq 1 ]]; then
  log "Removed-file guard skipped (--skip-prev-check)"
  return 0
 fi
 local prev
 prev="$(previous_release_tarball)"
 if [[ -z "$prev" ]]; then
  log "WARNING: no previous release tarball available (pass --previous PATH or install gh); removed-file guard skipped"
  return 0
 fi
 log "Removed-file guard: comparing against $(basename "$prev")"
 local removed
 local prev_list="$STAGING_DIR/.prev-files.txt"
 local new_list="$STAGING_DIR/.new-files.txt"
 tar tzf "$prev" | grep -v '/$' | LC_ALL=C sort > "$prev_list"
 tar tzf "$OUTPUT_TARBALL" | grep -v '/$' | LC_ALL=C sort > "$new_list"
 removed="$(LC_ALL=C comm -23 "$prev_list" "$new_list" \
  | grep -v -E '^(etc/PGenerator/(PGenerator\.conf|hdr20_postcal_shadow_matrix\.json|lut\.txt)|etc/BiasiLinux/BiasiLinux\.FirstBoot|usr/share/PGenerator/meter_settings\.json)$' \
  || true)"
 if [[ -z "$removed" ]]; then
  log "Removed-file guard OK: no files vanished vs previous release"
  return 0
 fi
 local prev_version cur_version covering
 prev_version="$(tarball_version "$prev")"
 cur_version="$(repo_version)"
 covering="$(migrations_in_range "${prev_version:-0}" "$cur_version")"
 echo "Files present in the previous release ($prev_version) but missing from this build:" >&2
 printf '  %s\n' $removed >&2
 if [[ "$ALLOW_REMOVALS" -eq 1 ]]; then
  log "Removals allowed by --allow-removals (${prev_version:-?} -> $cur_version)"
  return 0
 fi
 if [[ -n "$covering" ]]; then
  log "Removals accompanied by new migration(s): $(printf '%s ' $covering)"
  log "Verify the migration(s) actually prune the paths listed above."
  return 0
 fi
 die "Runtime files were removed/renamed but no migration in (${prev_version:-?}, $cur_version] prunes them. Add a versioned migration to usr/share/PGenerator/update-migrations.d (see 2.3.1-prune-stale-renderers.sh) or pass --allow-removals."
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
 ARCHIVE_CREATED=1
 (
  cd "$STAGING_DIR"
  tar --owner=0 --group=0 --numeric-owner -czf "$OUTPUT_TARBALL" "${roots[@]}"
 )
}

validate_tarball() {
 log "Validating release manifest"
 "$MANIFEST_CHECKER" --tarball "$OUTPUT_TARBALL"
 log "Validating split Web UI package"
 perl "$FRAGMENT_CHECKER" "$OUTPUT_TARBALL"
 if [[ "$TARGET" == "pi5-bookworm-armhf" ]] && tar -tzf "$OUTPUT_TARBALL" | grep -Eq '^lib(/|$)'; then
  die "Pi 5 OTA tarball contains root /lib entries and would break Bookworm usrmerge"
 fi
}

main() {
 parse_args "$@"
 load_target_manifest
 require_commands
 prepare_paths
 stage_overlay
 validate_pi4_legacy_runtime
 validate_pi5_staging_tree
 build_tarball
 check_removed_files
 validate_tarball
 log "Build complete: $OUTPUT_TARBALL"
 if [[ "$KEEP_STAGING" -eq 1 ]]; then
  log "Temporary staging directory kept at $STAGING_DIR"
 fi
}

main "$@"

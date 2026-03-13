#!/usr/bin/env bash

# build_pgenerator_plus_image.sh — Overlay PGenerator+ onto a compatible
# user-supplied BiasiLinux/PGenerator base image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"

KEEP_WORKDIR=0
FORCE_OUTPUT=0
SKIP_BASE_CHECK=0
BASE_IMAGE=""
OUTPUT_IMAGE=""
WORKDIR=""
ROOT_MOUNT=""
LOOP_DEVICE=""
ROOT_PARTITION=""

log() {
 echo "[build-image] $*"
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

usage() {
 cat <<EOF
Usage:
  sudo ./tools/build_pgenerator_plus_image.sh --base-image /path/to/BiasiLinux.img [options]

Required:
  --base-image PATH      Compatible BiasiLinux/PGenerator base image to copy.

Optional:
  --output PATH          Output image path.
                         Default: build/PGenerator_Plus_v<version>_from_biasi.img
  --force                Overwrite the output image if it already exists.
  --skip-base-check      Skip compatibility checks on the mounted rootfs.
  --keep-workdir         Keep the temporary mount/work directory for inspection.
  -h, --help             Show this help text.

Notes:
  - This script does not build a full OS from scratch.
  - It copies a user-supplied base image, mounts its Linux root partition,
    and overlays this repository's runtime filesystem onto it.
  - The base image should already be a compatible BiasiLinux/PGenerator image
    with the expected distro dependencies and account setup.
EOF
}

require_root() {
 if [[ "${EUID}" -ne 0 ]]; then
  die "This script must be run as root (use sudo)."
 fi
}

require_commands() {
 local missing=()
 local cmd
 for cmd in awk cp grep losetup lsblk mktemp mount mountpoint rsync sed sync umount; do
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

abs_existing_path() {
 local path="$1"
 [[ -e "$path" ]] || die "Path does not exist: $path"
 echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

abs_target_path() {
 local path="$1"
 mkdir -p "$(dirname "$path")"
 echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

cleanup() {
 set +e
 if [[ -n "$ROOT_MOUNT" ]] && mountpoint -q "$ROOT_MOUNT" 2>/dev/null; then
  umount "$ROOT_MOUNT"
 fi
 if [[ -n "$LOOP_DEVICE" ]]; then
  losetup -d "$LOOP_DEVICE" 2>/dev/null
 fi
 if [[ -n "$WORKDIR" ]] && [[ -d "$WORKDIR" ]] && [[ "$KEEP_WORKDIR" -eq 0 ]]; then
  rm -rf "$WORKDIR"
 fi
}

trap cleanup EXIT

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --base-image)
    [[ $# -ge 2 ]] || die "Missing value for --base-image"
    BASE_IMAGE="$2"
    shift 2
    ;;
   --output)
    [[ $# -ge 2 ]] || die "Missing value for --output"
    OUTPUT_IMAGE="$2"
    shift 2
    ;;
   --force)
    FORCE_OUTPUT=1
    shift
    ;;
   --skip-base-check)
    SKIP_BASE_CHECK=1
    shift
    ;;
   --keep-workdir)
    KEEP_WORKDIR=1
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

 [[ -n "$BASE_IMAGE" ]] || die "--base-image is required"
}

prepare_paths() {
 local version
 version="$(repo_version)"

 BASE_IMAGE="$(abs_existing_path "$BASE_IMAGE")"

 if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$REPO_ROOT/build/PGenerator_Plus_v${version}_from_biasi.img"
 fi
 OUTPUT_IMAGE="$(abs_target_path "$OUTPUT_IMAGE")"

 [[ "$BASE_IMAGE" != "$OUTPUT_IMAGE" ]] || die "Output image must be different from the base image"

 if [[ -e "$OUTPUT_IMAGE" ]] && [[ "$FORCE_OUTPUT" -ne 1 ]]; then
  die "Output image already exists: $OUTPUT_IMAGE (use --force to overwrite)"
 fi
}

copy_base_image() {
 if [[ -e "$OUTPUT_IMAGE" ]]; then
  rm -f "$OUTPUT_IMAGE"
 fi
 log "Copying base image to $OUTPUT_IMAGE"
 cp --reflink=auto --sparse=always -- "$BASE_IMAGE" "$OUTPUT_IMAGE"
}

attach_loop_device() {
 log "Attaching loop device"
 LOOP_DEVICE="$(losetup --find --show --partscan "$OUTPUT_IMAGE")"
 [[ -n "$LOOP_DEVICE" ]] || die "Failed to attach loop device"
 if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
 fi
}

discover_root_partition() {
 while read -r name type fstype; do
  [[ "$type" == "part" ]] || continue
  case "$fstype" in
   ext4|ext3|ext2)
    ROOT_PARTITION="$name"
    break
    ;;
  esac
 done < <(lsblk -nrpo NAME,TYPE,FSTYPE "$LOOP_DEVICE")

 [[ -n "$ROOT_PARTITION" ]] || die "Could not find a Linux root partition in $OUTPUT_IMAGE"
 log "Using root partition $ROOT_PARTITION"
}

mount_root_partition() {
 WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-image-build.XXXXXX")"
 ROOT_MOUNT="$WORKDIR/root"
 mkdir -p "$ROOT_MOUNT"
 log "Mounting $ROOT_PARTITION"
 mount "$ROOT_PARTITION" "$ROOT_MOUNT"
}

check_base_image() {
 [[ -d "$ROOT_MOUNT/etc" ]] || die "Mounted rootfs is missing /etc"
 [[ -d "$ROOT_MOUNT/usr" ]] || die "Mounted rootfs is missing /usr"

 if [[ "$SKIP_BASE_CHECK" -eq 1 ]]; then
  log "Skipping base compatibility checks"
  return
 fi

 local problems=()

 [[ -x "$ROOT_MOUNT/usr/bin/perl" ]] || problems+=("missing /usr/bin/perl")
 [[ -x "$ROOT_MOUNT/usr/bin/sudo" ]] || problems+=("missing /usr/bin/sudo")
 [[ -d "$ROOT_MOUNT/etc/init.d" ]] || problems+=("missing /etc/init.d")
 [[ -f "$ROOT_MOUNT/etc/passwd" ]] || problems+=("missing /etc/passwd")
 [[ -f "$ROOT_MOUNT/etc/group" ]] || problems+=("missing /etc/group")
 [[ -f "$ROOT_MOUNT/etc/sudo/sudoers.d/PGenerator" ]] || problems+=("missing /etc/sudo/sudoers.d/PGenerator")

 if [[ -f "$ROOT_MOUNT/etc/passwd" ]] && ! grep -q '^pgenerator:' "$ROOT_MOUNT/etc/passwd"; then
  problems+=("missing pgenerator user in /etc/passwd")
 fi

 if [[ ${#problems[@]} -gt 0 ]]; then
  printf 'Base image compatibility check failed:\n' >&2
  printf '  - %s\n' "${problems[@]}" >&2
  die "Use a compatible BiasiLinux/PGenerator image or rerun with --skip-base-check"
 fi
}

overlay_tree() {
 local rel
 local src
 local dst

 for rel in etc usr var lib; do
  src="$REPO_ROOT/$rel"
  [[ -d "$src" ]] || continue
  dst="$ROOT_MOUNT/$rel"
  mkdir -p "$dst"
  log "Overlaying /$rel"
  rsync -aHAX --no-owner --no-group -- "$src/" "$dst/"
 done
}

finalize_image() {
 sync
 log "Build complete: $OUTPUT_IMAGE"
 if [[ "$KEEP_WORKDIR" -eq 1 ]]; then
  log "Temporary workdir kept at $WORKDIR"
 fi
 log "If you want a smaller distributable image, shrink/compress it afterward."
}

main() {
 parse_args "$@"
 require_root
 require_commands
 prepare_paths
 copy_base_image
 attach_loop_device
 discover_root_partition
 mount_root_partition
 check_base_image
 overlay_tree
 finalize_image
}

main "$@"

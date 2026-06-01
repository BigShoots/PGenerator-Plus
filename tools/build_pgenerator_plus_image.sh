#!/usr/bin/env bash

# build_pgenerator_plus_image.sh — Overlay PGenerator+ onto a compatible
# user-supplied BiasiLinux/PGenerator base image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"
MANIFEST_CHECKER="$REPO_ROOT/tools/check_release_manifest.sh"
ARGYLL_RUNTIME_REQUIRED_BINS=(ccxxmake)
ARGYLL_RUNTIME_OPTIONAL_BINS=(spotread chartread colprof i1d3ccss oeminst dispread dispcal)
ARGYLL_RUNTIME_DIR=""

KEEP_WORKDIR=0
FORCE_OUTPUT=0
SKIP_BASE_CHECK=0
BASE_IMAGE=""
OUTPUT_IMAGE=""
WORKDIR=""
ROOT_MOUNT=""
BOOT_MOUNT=""
LOOP_DEVICE=""
ROOT_PARTITION=""
BOOT_PARTITION=""

log() {
 echo "[build-image] $*"
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

usage() {
 cat <<'EOF'
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
  --argyll-runtime-dir   Directory containing cross-compiled or prebuilt armhf
                         ArgyllCMS binaries to stage into /usr/bin.
  -h, --help             Show this help text.

Notes:
  - This script does not build a full OS from scratch.
  - It copies a user-supplied base image, mounts its Linux root partition,
    and overlays this repository's runtime filesystem onto it.
  - The base image should already be a compatible BiasiLinux/PGenerator image
    with the expected distro dependencies and account setup.
  - In the current source tree only `spotread` is bundled. Use
    --argyll-runtime-dir to add the headless Argyll runtime slice used for
    on-device TI3 -> CCSS conversion. `ccxxmake` is required; matching helper
    binaries present in the directory are staged too.
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
 for cmd in awk cpio cp dd gzip grep losetup lsblk mktemp mount mountpoint rsync sed sync umount; do
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
 if [[ -n "$BOOT_MOUNT" ]] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
  umount "$BOOT_MOUNT"
 fi
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
  --argyll-runtime-dir)
   [[ $# -ge 2 ]] || die "Missing value for --argyll-runtime-dir"
   ARGYLL_RUNTIME_DIR="$2"
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

 [[ -n "$BASE_IMAGE" ]] || die "--base-image is required"
}

prepare_paths() {
 local version
 version="$(repo_version)"

 BASE_IMAGE="$(abs_existing_path "$BASE_IMAGE")"
 if [[ -n "$ARGYLL_RUNTIME_DIR" ]]; then
  ARGYLL_RUNTIME_DIR="$(abs_existing_path "$ARGYLL_RUNTIME_DIR")"
  [[ -d "$ARGYLL_RUNTIME_DIR" ]] || die "Argyll runtime path is not a directory: $ARGYLL_RUNTIME_DIR"
 fi

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
 if cp --reflink=auto --sparse=always -- "$BASE_IMAGE" "$OUTPUT_IMAGE"; then
  return
 fi
 log "cp failed; retrying with sequential dd copy"
 rm -f "$OUTPUT_IMAGE"
 dd if="$BASE_IMAGE" of="$OUTPUT_IMAGE" bs=16M iflag=fullblock status=progress conv=fsync
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
 local name fstype

 while read -r name; do
  [[ "$name" != "$LOOP_DEVICE" ]] || continue
  fstype="$(lsblk -nrpo FSTYPE "$name" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  if [[ -z "$fstype" ]] && command -v blkid >/dev/null 2>&1; then
   fstype="$(blkid -o value -s TYPE "$name" 2>/dev/null || true)"
  fi
  case "$fstype" in
   ext4|ext3|ext2)
    ROOT_PARTITION="$name"
    break
    ;;
  esac
 done < <(lsblk -nrpo NAME "$LOOP_DEVICE")

 [[ -n "$ROOT_PARTITION" ]] || die "Could not find a Linux root partition in $OUTPUT_IMAGE"
 log "Using root partition $ROOT_PARTITION"
}

discover_boot_partition() {
 local name fstype

 while read -r name; do
  [[ "$name" != "$LOOP_DEVICE" ]] || continue
  [[ "$name" != "$ROOT_PARTITION" ]] || continue
  fstype="$(lsblk -nrpo FSTYPE "$name" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  if [[ -z "$fstype" ]] && command -v blkid >/dev/null 2>&1; then
   fstype="$(blkid -o value -s TYPE "$name" 2>/dev/null || true)"
  fi
  case "$fstype" in
   vfat|fat|fat16|fat32)
    BOOT_PARTITION="$name"
    break
    ;;
  esac
 done < <(lsblk -nrpo NAME "$LOOP_DEVICE")

 [[ -n "$BOOT_PARTITION" ]] || die "Could not find a FAT boot partition in $OUTPUT_IMAGE"
 log "Using boot partition $BOOT_PARTITION"
}

mount_root_partition() {
 WORKDIR="$(mktemp -d "$(dirname "$OUTPUT_IMAGE")/pgenerator-image-build.XXXXXX")"
 ROOT_MOUNT="$WORKDIR/root"
 BOOT_MOUNT="$WORKDIR/boot"
 mkdir -p "$ROOT_MOUNT"
 mkdir -p "$BOOT_MOUNT"
 log "Mounting $ROOT_PARTITION"
 mount "$ROOT_PARTITION" "$ROOT_MOUNT"
}

mount_boot_partition() {
 log "Mounting $BOOT_PARTITION"
 mount "$BOOT_PARTITION" "$BOOT_MOUNT"
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

stage_argyll_runtime() {
 local bin src
 local missing=()
 local staged=()

 if [[ -z "$ARGYLL_RUNTIME_DIR" ]]; then
  log "No external Argyll runtime directory supplied; only bundled meter tools will be staged"
  return
 fi

 mkdir -p "$ROOT_MOUNT/usr/bin"
 for bin in "${ARGYLL_RUNTIME_REQUIRED_BINS[@]}"; do
  src="$ARGYLL_RUNTIME_DIR/$bin"
  if [[ ! -f "$src" ]]; then
   missing+=("$bin")
   continue
  fi
  install -m 0755 "$src" "$ROOT_MOUNT/usr/bin/$bin"
  staged+=("$bin")
 done

 if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'Missing Argyll runtime binaries in %s:\n' "$ARGYLL_RUNTIME_DIR" >&2
  printf '  %s\n' "${missing[@]}" >&2
  die "Argyll runtime import is incomplete"
 fi

 for bin in "${ARGYLL_RUNTIME_OPTIONAL_BINS[@]}"; do
  src="$ARGYLL_RUNTIME_DIR/$bin"
  [[ -f "$src" ]] || continue
  install -m 0755 "$src" "$ROOT_MOUNT/usr/bin/$bin"
  staged+=("$bin")
 done

 log "Staged external Argyll runtime from $ARGYLL_RUNTIME_DIR: ${staged[*]}"
}

reset_runtime_state() {
 log "Resetting transient runtime state for a fresh image"
 rm -f "$ROOT_MOUNT/usr/share/PGenerator/meter_settings.json"
 rm -f "$ROOT_MOUNT/usr/sbin/PGeneratord.hdr"
 mkdir -p "$ROOT_MOUNT/var/lib/PGenerator/running/tmp"
 find "$ROOT_MOUNT/var/lib/PGenerator/running" -mindepth 1 -maxdepth 1 ! -name 'tmp' -exec rm -rf {} + 2>/dev/null || true
 : > "$ROOT_MOUNT/var/lib/PGenerator/operations.txt"
}

ensure_boot_ramdisk_size() {
 local cmdline_file="$BOOT_MOUNT/cmdline.txt"
 local initramfs_file="$BOOT_MOUNT/initramfs.gz"
 local required_kb=65536
 local current_size current_cmdline

 [[ -f "$cmdline_file" ]] || die "Boot partition is missing cmdline.txt"
 [[ -f "$initramfs_file" ]] || return 0

 current_size="$(sed -n 's/.*\<ramdisk_size=\([0-9][0-9]*\).*/\1/p' "$cmdline_file" | head -n 1)"
 if [[ -n "$current_size" ]] && (( current_size >= required_kb )); then
  log "Boot cmdline already provides ramdisk_size=$current_size"
  return 0
 fi

 current_cmdline="$(tr -d '\n' < "$cmdline_file")"
 if [[ -n "$current_size" ]]; then
  current_cmdline="$(sed -E "s/(^| )ramdisk_size=[0-9]+/ ramdisk_size=$required_kb/" <<<"$current_cmdline")"
 else
  current_cmdline="$current_cmdline ramdisk_size=$required_kb"
 fi

 printf '%s\n' "$current_cmdline" > "$cmdline_file"
 log "Ensured ramdisk_size=$required_kb in cmdline.txt for initramfs.gz"
}

patch_boot_initramfs_rootwait() {
 local initramfs_file="$BOOT_MOUNT/initramfs.gz"
 local initramfs_dir="$WORKDIR/initramfs"
 local repacked_initramfs="$WORKDIR/initramfs.gz"
 local init_file

 [[ -f "$initramfs_file" ]] || return 0

 rm -rf "$initramfs_dir"
 mkdir -p "$initramfs_dir"

 (
  # The shipped base image carries an initramfs.gz with a bad gzip trailer.
  # gunzip still emits a usable cpio stream, so tolerate that non-zero status
  # and repack a clean archive after patching /init.
  cd "$initramfs_dir"
  set +o pipefail
  gzip -dc "$initramfs_file" 2>/dev/null | cpio -id --quiet --no-absolute-filenames || true
 )

 init_file="$initramfs_dir/init"
 [[ -f "$init_file" ]] || die "Extracted initramfs is missing /init"

 cat > "$init_file" <<'EOF'
#!/bin/sh
echo 'Booting initramfs image...'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export RUNLEVEL=S
export FROM_INITRAMFS=1
/etc/init.d/udev start
/sbin/mdadm -As
unset RUNLEVEL
INIT_PROGRAM="/sbin/init"
OTHER=`cat /proc/cmdline|grep init=|awk -F init=\" '{print $2}'|sed -e "s/\".*//"`
if [ -z "$OTHER" ]; then
OTHER=`cat /proc/cmdline|grep init=|awk -F init= '{print $2}'|sed -e "s/ .*//"`
fi
SINGLE=`cat /proc/cmdline|egrep " single | single$"`
ROOTFS=`cat /proc/cmdline|awk -F root= '{print $2}'|sed -e "s/ .*//"`
if [ -n "$SINGLE" ]; then
INIT_PROGRAM="/sbin/init s"
fi
if [ -n "$OTHER" ]; then
INIT_PROGRAM="$OTHER"
fi
if [ -z "$ROOTFS" ]; then
ROOTFS="LABEL=/_PG"
fi
echo "Waiting for root filesystem $ROOTFS..."
ROOT_MOUNTED=0
RETRY=0
while [ "$RETRY" -lt 30 ]; do
 if mount -n -o ro "$ROOTFS" /mnt 2>/dev/null; then
  ROOT_MOUNTED=1
  break
 fi
 RETRY=$((RETRY+1))
 sleep 1
done
if [ "$ROOT_MOUNTED" -ne 1 ]; then
 echo "Unable to mount $ROOTFS after ${RETRY} seconds"
 exec /bin/bash </dev/console >/dev/console 2>&1
fi
/etc/init.d/udev stop
mount --move /dev /mnt/dev
mount --move /proc /mnt/proc
mount --move /sys /mnt/sys
export INITRAMFS_EXECUTED=1
export FROM_INITRAMFS=0
exec switch_root /mnt $INIT_PROGRAM </dev/console >/dev/console 2>&1
EOF
 chmod 0755 "$init_file"

 (
  cd "$initramfs_dir"
  find . -print | LC_ALL=C sort | cpio -o -H newc --quiet | gzip -9n > "$repacked_initramfs"
 )

 install -m 0644 "$repacked_initramfs" "$initramfs_file"
 log "Patched initramfs /init to wait for the USB root filesystem and rebuilt initramfs.gz"
}

fix_permissions() {
 local bin rel

 log "Fixing ownership and permissions for release image"

 set_root_mode() {
  local rel_path="$1"
  local mode="$2"
  local path="$ROOT_MOUNT/$rel_path"
  [[ -e "$path" ]] || return 0
  chown root:root "$path" 2>/dev/null || true
  chmod "$mode" "$path" 2>/dev/null || true
 }

 set_root_symlink_owner() {
  local rel_path="$1"
  local path="$ROOT_MOUNT/$rel_path"
  [[ -L "$path" ]] || return 0
  chown -h root:root "$path" 2>/dev/null || true
 }

 ensure_pgenerator_dir() {
  local rel_path="$1"
  local mode="$2"
  local path="$ROOT_MOUNT/$rel_path"
  install -d -o pgenerator -g pgenerator -m "$mode" "$path" 2>/dev/null || mkdir -p "$path"
  chown pgenerator:pgenerator "$path" 2>/dev/null || true
  chmod "$mode" "$path" 2>/dev/null || true
 }

 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers" 2>/dev/null || true
 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers.d" 2>/dev/null || true
 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers.d/PGenerator" 2>/dev/null || true
 chmod 755 "$ROOT_MOUNT/etc/sudo" "$ROOT_MOUNT/etc/sudo/sudoers.d" 2>/dev/null || true
 chmod 440 "$ROOT_MOUNT/etc/sudo/sudoers" "$ROOT_MOUNT/etc/sudo/sudoers.d/PGenerator" 2>/dev/null || true

 local root_execs=(
  "etc/init.d/PGenerator"
  "etc/init.d/rcPGenerator"
  "etc/init.d/fake-hwclock"
  "etc/cron.hourly/fake-hwclock"
  "usr/bin/PGeneratorDisplayMirror"
  "usr/bin/PGenerator_bash.pl"
  "usr/bin/PGenerator_bluez.sh"
  "usr/bin/PGenerator_cmd.pl"
  "usr/bin/PGenerator_serial.pl"
  "usr/bin/ccss_create.py"
  "usr/bin/ccss_create_patch.sh"
  "usr/bin/ccxxmake"
  "usr/bin/ccxxmake_interactive"
  "usr/bin/chartread"
  "usr/bin/colprof"
  "usr/bin/fix_ccss_keywords.pl"
  "usr/bin/i1d3ccss"
  "usr/bin/meter_lg_3d_autocal.pl"
  "usr/bin/meter_lg_autocal.pl"
  "usr/bin/meter_series.sh"
  "usr/bin/meter_session.sh"
  "usr/bin/meter_usb_reset.sh"
  "usr/bin/oeminst"
  "usr/bin/pgenerator-bnep-hook.sh"
  "usr/bin/pgenerator-bt-agent"
  "usr/bin/resize_PGenerator_disk"
  "usr/bin/spotread"
  "usr/bin/spotread_measure.py"
  "usr/bin/spotread_wrapper.sh"
  "usr/sbin/PGeneratord"
  "usr/sbin/PGeneratord.dv"
  "usr/sbin/PGeneratord.pl"
  "usr/sbin/disable_csc"
  "usr/sbin/drm_player"
  "usr/sbin/fake-hwclock"
  "usr/sbin/fb_player"
  "usr/sbin/pg_diag_video_player"
  "usr/sbin/pgenerator-cec"
  "usr/sbin/pgenerator-lg"
  "usr/sbin/pgenerator-slim.sh"
  "usr/sbin/pgenerator-update"
 )
 for rel in "${root_execs[@]}"; do
  set_root_mode "$rel" 0755
 done

 for rel in \
  "etc/ntp.conf" \
  "etc/default/ntp" \
  "etc/default/ntpdate"; do
  set_root_mode "$rel" 0644
 done

 for rel in \
  "etc/rc0.d/K01fake-hwclock" \
  "etc/rc0.d/K02ntp" \
  "etc/rc2.d/S98ntp" \
  "etc/rc3.d/S98ntp" \
  "etc/rc4.d/S98ntp" \
  "etc/rc5.d/S98ntp" \
  "etc/rc6.d/K01fake-hwclock" \
  "etc/rc6.d/K02ntp" \
  "etc/rcS.d/S08fake-hwclock"; do
  set_root_symlink_owner "$rel"
 done

 ensure_pgenerator_dir "var/lib/PGenerator/running" 0770
 ensure_pgenerator_dir "var/lib/PGenerator/running/tmp" 0770
 ensure_pgenerator_dir "var/lib/PGenerator/ccss" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/ccss/custom" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/ddc" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/luts" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/pin-sessions" 0775
 ensure_pgenerator_dir "var/log/PGenerator" 0775

 for bin in "${ARGYLL_RUNTIME_REQUIRED_BINS[@]}" "${ARGYLL_RUNTIME_OPTIONAL_BINS[@]}"; do
  [[ -f "$ROOT_MOUNT/usr/bin/$bin" ]] || continue
  chown root:root "$ROOT_MOUNT/usr/bin/$bin" 2>/dev/null || true
  chmod 0755 "$ROOT_MOUNT/usr/bin/$bin" 2>/dev/null || true
 done
}

validate_release_root() {
 log "Validating release manifest"
 "$MANIFEST_CHECKER" --root "$ROOT_MOUNT"
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
 discover_boot_partition
 mount_root_partition
 mount_boot_partition
 check_base_image
 overlay_tree
 stage_argyll_runtime
 reset_runtime_state
 ensure_boot_ramdisk_size
 patch_boot_initramfs_rootwait
 fix_permissions
 validate_release_root
 finalize_image
}

main "$@"

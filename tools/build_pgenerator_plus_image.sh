#!/usr/bin/env bash

# build_pgenerator_plus_image.sh — Overlay PGenerator+ onto a compatible
# user-supplied base image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"
MANIFEST_CHECKER="$REPO_ROOT/tools/check_release_manifest.sh"
ARGYLL_RUNTIME_REQUIRED_BINS=(ccxxmake)
ARGYLL_RUNTIME_OPTIONAL_BINS=(spotread chartread colprof i1d3ccss oeminst dispread dispcal)
ARGYLL_RUNTIME_DIR=""
TARGET="pi4-biasi"
PI5_TARGET_MANIFEST="$REPO_ROOT/tools/image-targets/pi5-bookworm-armhf.env"
PI5_TARGET_DESCRIPTION="Raspberry Pi 5 Bookworm armhf"
PI5_OUTPUT_SUFFIX="pi5_bookworm_armhf"
PI5_BOOT_LABEL="BOOT_PG"
PI5_ROOT_LABEL="/_PG"
PI5_REQUIRED_BOOT_KERNELS="kernel_2712.img kernel8.img"
PI5_ROOT_PASSWORD_HASH='$6$pgenerator$tEOE1qfYZlUf/.8wT.zgYKKMlRZCb/qEPvczRS/GqoNMXXqSO9a8Vhi1G6eN7prcHdONB96F2RtRNm6ZvlWTB/'
PI5_ADMIN_USER="pi"
PI5_ADMIN_PASSWORD_HASH="$PI5_ROOT_PASSWORD_HASH"
PI5_ADMIN_GROUPS="adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi"
PI5_KEYBOARD_LAYOUT="us"
PI5_LOCALE="en_US.UTF-8"
TARGET_OVERLAY_REL=""

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
  sudo ./tools/build_pgenerator_plus_image.sh --base-image /path/to/base.img [options]

Required:
  --base-image PATH      Compatible base image to copy.

Optional:
  --output PATH          Output image path.
                         Default depends on --target.
  --target NAME          Image target to prepare.
                         pi4-biasi             Existing behavior; requires a
                                               compatible Biasi/PGenerator base.
                         pi5-bookworm-armhf    Prepare a Raspberry Pi OS
                                               Bookworm Lite armhf base for
                                               Raspberry Pi 5.
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
  - The default target expects a compatible BiasiLinux/PGenerator image with
    the expected distro dependencies and account setup.
  - The pi5-bookworm-armhf target expects a Raspberry Pi OS Bookworm Lite
    armhf base image and seeds the PGenerator account/compatibility state.
    Its target manifest is tools/image-targets/pi5-bookworm-armhf.env.
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
 if [[ "$TARGET" == "pi5-bookworm-armhf" ]]; then
  if ! command -v e2label >/dev/null 2>&1; then
   missing+=("e2label")
  fi
  if ! command -v fatlabel >/dev/null 2>&1 && ! command -v dosfslabel >/dev/null 2>&1; then
   if ! command -v perl >/dev/null 2>&1; then
    missing+=("fatlabel, dosfslabel, or perl")
   fi
  fi
 fi
 if [[ ${#missing[@]} -gt 0 ]]; then
  die "Missing required tools: ${missing[*]}"
 fi
}

load_target_manifest() {
 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 [[ -f "$PI5_TARGET_MANIFEST" ]] || die "Missing target manifest: $PI5_TARGET_MANIFEST"
 # shellcheck disable=SC1090
 . "$PI5_TARGET_MANIFEST"

 [[ -n "$PI5_TARGET_DESCRIPTION" ]] || die "Pi 5 target manifest is missing PI5_TARGET_DESCRIPTION"
 [[ -n "$PI5_OUTPUT_SUFFIX" ]] || die "Pi 5 target manifest is missing PI5_OUTPUT_SUFFIX"
 [[ -n "$PI5_BOOT_LABEL" ]] || die "Pi 5 target manifest is missing PI5_BOOT_LABEL"
 [[ -n "$PI5_ROOT_LABEL" ]] || die "Pi 5 target manifest is missing PI5_ROOT_LABEL"
 [[ -n "$PI5_REQUIRED_BOOT_KERNELS" ]] || die "Pi 5 target manifest is missing PI5_REQUIRED_BOOT_KERNELS"
 log "Loaded target manifest: $PI5_TARGET_MANIFEST ($PI5_TARGET_DESCRIPTION)"
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
   --target)
    [[ $# -ge 2 ]] || die "Missing value for --target"
    TARGET="$2"
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
 case "$TARGET" in
  pi4-biasi|pi5-bookworm-armhf)
   ;;
  *)
   die "Unknown --target: $TARGET"
   ;;
 esac
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
  case "$TARGET" in
   pi5-bookworm-armhf)
    OUTPUT_IMAGE="$REPO_ROOT/build/PGenerator_Plus_v${version}_${PI5_OUTPUT_SUFFIX}.img"
    ;;
   *)
    OUTPUT_IMAGE="$REPO_ROOT/build/PGenerator_Plus_v${version}_from_biasi.img"
    ;;
  esac
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

 if [[ "$TARGET" == "pi5-bookworm-armhf" ]]; then
  check_pi5_bookworm_base_image
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

check_pi5_bookworm_base_image() {
 local problems=()
 local os_release="$ROOT_MOUNT/etc/os-release"

 [[ -x "$ROOT_MOUNT/usr/bin/perl" ]] || problems+=("missing /usr/bin/perl")
 [[ -x "$ROOT_MOUNT/usr/bin/sudo" ]] || problems+=("missing /usr/bin/sudo")
 [[ -d "$ROOT_MOUNT/etc/init.d" ]] || problems+=("missing /etc/init.d")
 [[ -f "$ROOT_MOUNT/etc/passwd" ]] || problems+=("missing /etc/passwd")
 [[ -f "$ROOT_MOUNT/etc/group" ]] || problems+=("missing /etc/group")
 [[ -f "$BOOT_MOUNT/config.txt" ]] || problems+=("missing boot config.txt")
 [[ -f "$BOOT_MOUNT/cmdline.txt" ]] || problems+=("missing boot cmdline.txt")
 if ! pi5_required_boot_kernel_present; then
  problems+=("missing one of boot kernels: $PI5_REQUIRED_BOOT_KERNELS")
 fi

 if [[ -f "$os_release" ]]; then
  if ! grep -Eq '^VERSION_CODENAME=bookworm$|^VERSION=.*bookworm' "$os_release"; then
   problems+=("base is not Debian/Raspberry Pi OS Bookworm")
  fi
  if ! grep -Eq '^ID=(raspbian|debian)$|^ID_LIKE=.*debian' "$os_release"; then
   problems+=("base is not Raspberry Pi OS/Debian-like")
  fi
 else
  problems+=("missing /etc/os-release")
 fi

 if [[ ! -e "$ROOT_MOUNT/lib/ld-linux-armhf.so.3" ]] && [[ ! -e "$ROOT_MOUNT/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3" ]]; then
  problems+=("missing armhf dynamic loader")
 fi

 if [[ ${#problems[@]} -gt 0 ]]; then
  printf 'Pi 5 Bookworm base compatibility check failed:\n' >&2
  printf '  - %s\n' "${problems[@]}" >&2
  die "Use a Raspberry Pi OS Bookworm Lite armhf base image or rerun with --skip-base-check"
 fi
}

pi5_required_boot_kernel_present() {
 local kernel

 for kernel in $PI5_REQUIRED_BOOT_KERNELS; do
  if [[ -f "$BOOT_MOUNT/$kernel" ]]; then
   return 0
  fi
 done
 return 1
}

overlay_tree() {
 local rel
 local src
 local dst
 local target_overlay

 for rel in etc usr var lib; do
  src="$REPO_ROOT/$rel"
  [[ -d "$src" ]] || continue
  dst="$ROOT_MOUNT/$rel"
  mkdir -p "$dst"
  log "Overlaying /$rel"
  rsync -aHAX --no-owner --no-group -- "$src/" "$dst/"
 done

 if [[ -n "$TARGET_OVERLAY_REL" ]]; then
  target_overlay="$REPO_ROOT/$TARGET_OVERLAY_REL"
  [[ -d "$target_overlay" ]] || die "Target overlay directory not found: $target_overlay"
  for rel in etc usr var lib; do
   src="$target_overlay/$rel"
   [[ -d "$src" ]] || continue
   dst="$ROOT_MOUNT/$rel"
   mkdir -p "$dst"
   log "Overlaying target /$rel from $TARGET_OVERLAY_REL"
   rsync -aHAX --no-owner --no-group -- "$src/" "$dst/"
  done
 fi
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

ensure_config_line() {
 local file="$1"
 local key="$2"
 local value="$3"

 touch "$file"
 if grep -Eq "^[[:space:]]*${key}=" "$file"; then
  sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
 else
  printf '%s=%s\n' "$key" "$value" >> "$file"
 fi
}

next_free_id() {
 local file="$1"
 local field="$2"
 local id

 for id in $(seq 995 -1 900); do
  if ! awk -F: -v field="$field" -v id="$id" '$field == id { found=1 } END { exit found ? 0 : 1 }' "$file"; then
   echo "$id"
   return
  fi
 done
 die "Could not find an unused system id in $file"
}

next_free_regular_id() {
 local file="$1"
 local field="$2"
 local id

 for id in $(seq 1000 60000); do
  if ! awk -F: -v field="$field" -v id="$id" '$field == id { found=1 } END { exit found ? 0 : 1 }' "$file"; then
   echo "$id"
   return
  fi
 done
 die "Could not find an unused regular id in $file"
}

ensure_user_group_membership() {
 local file="$1"
 local group="$2"
 local user="$3"
 local tmp mode owner group_id

 [[ -f "$file" ]] || return 0
 tmp="${file}.tmp.$$"
 perl - "$group" "$user" "$file" > "$tmp" <<'PERL'
  use strict;
  use warnings;
  my ($group, $user, $file) = @ARGV;
  open(my $fh, "<", $file) or die "Cannot open $file: $!\n";
  local $/;
  $_ = <$fh>;
  close($fh);
  s{^(\Q$group\E:[^:\n]*:[^:\n]*:)([^\n]*)$}{
   my %seen = map { $_ => 1 } grep { $_ ne "" } split /,/, $2;
   $seen{$user} = 1;
   $1 . join(",", sort keys %seen);
  }gme;
  print;
PERL
 mode="$(stat -c '%a' "$file" 2>/dev/null || echo 0644)"
 owner="$(stat -c '%u' "$file" 2>/dev/null || echo 0)"
 group_id="$(stat -c '%g' "$file" 2>/dev/null || echo 0)"
 install -m "$mode" -o "$owner" -g "$group_id" "$tmp" "$file" 2>/dev/null || install -m "$mode" "$tmp" "$file"
 rm -f "$tmp"
}

ensure_pi5_admin_identity() {
 local passwd_file="$ROOT_MOUNT/etc/passwd"
 local group_file="$ROOT_MOUNT/etc/group"
 local shadow_file="$ROOT_MOUNT/etc/shadow"
 local gshadow_file="$ROOT_MOUNT/etc/gshadow"
 local user="${PI5_ADMIN_USER:-pi}"
 local hash="${PI5_ADMIN_PASSWORD_HASH:-$PI5_ROOT_PASSWORD_HASH}"
 local groups="${PI5_ADMIN_GROUPS:-sudo,adm,dialout,audio,video,plugdev,users,input,render,netdev,gpio,i2c,spi}"
 local uid gid group
 local -a group_array

 [[ -f "$passwd_file" ]] || die "Pi 5 rootfs is missing /etc/passwd"
 [[ -f "$group_file" ]] || die "Pi 5 rootfs is missing /etc/group"
 [[ -f "$shadow_file" ]] || die "Pi 5 rootfs is missing /etc/shadow"
 [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid Pi 5 admin username: $user"

 if grep -q "^$user:" "$group_file"; then
  gid="$(awk -F: -v user="$user" '$1==user {print $3; exit}' "$group_file")"
 else
  gid="$(next_free_regular_id "$group_file" 3)"
  printf '%s:x:%s:\n' "$user" "$gid" >> "$group_file"
  if [[ -f "$gshadow_file" ]]; then
   printf '%s:!::\n' "$user" >> "$gshadow_file"
  fi
 fi

 if grep -q "^$user:" "$passwd_file"; then
  uid="$(awk -F: -v user="$user" '$1==user {print $3; exit}' "$passwd_file")"
  perl - "$user" "$passwd_file" > "$passwd_file.tmp" <<'PERL'
use strict;
use warnings;
my ($user, $file) = @ARGV;
open(my $fh, "<", $file) or die "Cannot open $file: $!\n";
while (my $line = <$fh>) {
 chomp $line;
 my @fields = split /:/, $line, -1;
 if (($fields[0] // "") eq $user) {
  $fields[5] = "/home/$user";
  $fields[6] = "/bin/bash";
 }
 print join(":", @fields), "\n";
}
close($fh);
PERL
  install -m 0644 -o 0 -g 0 "$passwd_file.tmp" "$passwd_file" 2>/dev/null || install -m 0644 "$passwd_file.tmp" "$passwd_file"
  rm -f "$passwd_file.tmp"
 else
  uid="$(next_free_regular_id "$passwd_file" 3)"
  printf '%s:x:%s:%s:PGenerator administrator:/home/%s:/bin/bash\n' "$user" "$uid" "$gid" "$user" >> "$passwd_file"
 fi

 if grep -q "^$user:" "$shadow_file"; then
  perl - "$user" "$hash" "$shadow_file" > "$shadow_file.tmp" <<'PERL'
use strict;
use warnings;
my ($user, $hash, $file) = @ARGV;
open(my $fh, "<", $file) or die "Cannot open $file: $!\n";
while (my $line = <$fh>) {
 chomp $line;
 my @fields = split /:/, $line, -1;
 if (($fields[0] // "") eq $user) {
  $fields[1] = $hash;
  push @fields, "" while @fields < 9;
 }
 print join(":", @fields), "\n";
}
close($fh);
PERL
  install -m 0640 -o 0 -g 42 "$shadow_file.tmp" "$shadow_file" 2>/dev/null || install -m 0640 "$shadow_file.tmp" "$shadow_file"
  rm -f "$shadow_file.tmp"
 else
  printf '%s:%s:20221:0:99999:7:::\n' "$user" "$hash" >> "$shadow_file"
 fi

 mkdir -p "$ROOT_MOUNT/home/$user"
 chown "$uid:$gid" "$ROOT_MOUNT/home/$user" 2>/dev/null || true
 chmod 0755 "$ROOT_MOUNT/home/$user"

 IFS=',' read -r -a group_array <<<"$groups"
 for group in "${group_array[@]}"; do
  [[ -n "$group" ]] || continue
  if grep -q "^$group:" "$group_file"; then
   ensure_user_group_membership "$group_file" "$group" "$user"
  fi
  if grep -q "^$group:" "$gshadow_file" 2>/dev/null; then
   ensure_user_group_membership "$gshadow_file" "$group" "$user"
  fi
 done
}

ensure_pi5_pgenerator_identity() {
 local passwd_file="$ROOT_MOUNT/etc/passwd"
 local group_file="$ROOT_MOUNT/etc/group"
 local shadow_file="$ROOT_MOUNT/etc/shadow"
 local gshadow_file="$ROOT_MOUNT/etc/gshadow"
 local groups="${PI5_PGENERATOR_GROUPS:-audio,video,input,render,gpio,i2c,spi}"
 local gid uid group
 local -a group_array

 if grep -q '^pgenerator:' "$group_file"; then
  gid="$(awk -F: '$1=="pgenerator" {print $3; exit}' "$group_file")"
 else
  gid="$(next_free_id "$group_file" 3)"
  printf 'pgenerator:x:%s:\n' "$gid" >> "$group_file"
 fi

 if grep -q '^pgenerator:' "$passwd_file"; then
  uid="$(awk -F: '$1=="pgenerator" {print $3; exit}' "$passwd_file")"
 else
  uid="$(next_free_id "$passwd_file" 3)"
  printf 'pgenerator:x:%s:%s:PGenerator service:/var/lib/PGenerator:/usr/sbin/nologin\n' "$uid" "$gid" >> "$passwd_file"
 fi

 if [[ -f "$shadow_file" ]] && ! grep -q '^pgenerator:' "$shadow_file"; then
  printf 'pgenerator:*:19700:0:99999:7:::\n' >> "$shadow_file"
 fi

 IFS=',' read -r -a group_array <<<"$groups"
 for group in "${group_array[@]}"; do
  [[ -n "$group" ]] || continue
  if grep -q "^$group:" "$group_file"; then
   ensure_user_group_membership "$group_file" "$group" "pgenerator"
  fi
  if grep -q "^$group:" "$gshadow_file" 2>/dev/null; then
   ensure_user_group_membership "$gshadow_file" "$group" "pgenerator"
  fi
 done
}

install_pi5_compat_script() {
 local rel="$1"
 local body="$2"
 local dst="$ROOT_MOUNT/$rel"

 mkdir -p "$(dirname "$dst")"
 printf '%s\n' "$body" > "$dst"
 chown root:root "$dst" 2>/dev/null || true
 chmod 0755 "$dst"
}

configure_pi5_bookworm_root() {
 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 log "Preparing Raspberry Pi 5 Bookworm armhf rootfs compatibility"
 ensure_pi5_admin_identity
 ensure_pi5_pgenerator_identity

 mkdir -p "$ROOT_MOUNT/etc/BiasiLinux" "$ROOT_MOUNT/var/lib/BiasiLinux" "$ROOT_MOUNT/boot/loader"
 touch "$ROOT_MOUNT/etc/BiasiLinux/packages.conf"
 touch "$ROOT_MOUNT/etc/BiasiLinux/boot_device.conf"
 touch "$ROOT_MOUNT/var/lib/BiasiLinux/PGenerator"
 touch "$ROOT_MOUNT/var/lib/BiasiLinux/linux"
 printf 'DISTRO="Raspberry Pi OS Bookworm"\nIMAGE_TARGET="pi5-bookworm-armhf"\n' > "$ROOT_MOUNT/etc/BiasiLinux/system_info"

 mkdir -p "$ROOT_MOUNT/boot/firmware"
 ln -sfn /boot/firmware "$ROOT_MOUNT/boot/loader/boot_dir"

 install_pi5_compat_script "usr/bin/pkg" '#!/bin/sh
exit 0'
 install_pi5_compat_script "usr/bin/rcset" '#!/bin/sh
exit 0'
 install_pi5_compat_script "usr/bin/bootloader" '#!/bin/sh
# Bookworm mounts the firmware partition at /boot/firmware. PGenerator writes
# config.txt through /boot/loader/boot_dir, which is a symlink to that mount.
sync
exit 0'
}

configure_pi5_display_defaults() {
 local conf="$ROOT_MOUNT/etc/PGenerator/PGenerator.conf"

 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0
 [[ -f "$conf" ]] || die "Pi 5 rootfs is missing /etc/PGenerator/PGenerator.conf"

 log "Applying Raspberry Pi 5 safe display defaults"
 ensure_config_line "$conf" "mode_idx" "-1"
 ensure_config_line "$conf" "signal_mode" "sdr"
 ensure_config_line "$conf" "is_sdr" "1"
 ensure_config_line "$conf" "is_hdr" "0"
 ensure_config_line "$conf" "is_ll_dovi" "0"
 ensure_config_line "$conf" "is_std_dovi" "0"
 ensure_config_line "$conf" "dv_status" "0"
 ensure_config_line "$conf" "dv_metadata" "0"
 ensure_config_line "$conf" "eotf" "0"
 ensure_config_line "$conf" "primaries" "0"
 ensure_config_line "$conf" "color_format" "0"
 ensure_config_line "$conf" "colorimetry" "2"
 ensure_config_line "$conf" "rgb_quant_range" "2"
 ensure_config_line "$conf" "max_bpc" "8"
}

configure_pi5_headless_first_boot() {
 local keyboard_file="$ROOT_MOUNT/etc/default/keyboard"
 local locale_file="$ROOT_MOUNT/etc/default/locale"
 local userconfig_wants="$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants/userconfig.service"
 local userconfig_mask="$ROOT_MOUNT/etc/systemd/system/userconfig.service"

 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 log "Disabling Raspberry Pi OS first-login setup prompts"

 mkdir -p "$ROOT_MOUNT/etc/default" "$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"
 touch "$keyboard_file"
 ensure_config_line "$keyboard_file" "XKBLAYOUT" "\"${PI5_KEYBOARD_LAYOUT:-us}\""
 touch "$locale_file"
 ensure_config_line "$locale_file" "LANG" "${PI5_LOCALE:-en_US.UTF-8}"

 rm -f "$userconfig_wants"
 ln -sfn /dev/null "$userconfig_mask"
 rm -f "$BOOT_MOUNT/userconf" "$BOOT_MOUNT/userconf.txt" "$BOOT_MOUNT/firstrun.sh"
}

enable_pi5_systemd_unit() {
 local unit="$1"
 local wants_dir="$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"

 [[ -f "$ROOT_MOUNT/etc/systemd/system/$unit" ]] || die "Missing Pi 5 systemd unit: $unit"
 mkdir -p "$wants_dir"
 ln -sfn "/etc/systemd/system/$unit" "$wants_dir/$unit"
}

configure_pi5_pgenerator_services() {
 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 log "Enabling Raspberry Pi 5 PGenerator services"
 enable_pi5_systemd_unit "rcPGenerator.service"
 enable_pi5_systemd_unit "pgenerator-dhcp.service"
 enable_pi5_systemd_unit "PGenerator.service"
}

configure_pi5_bookworm_boot() {
 local config_file="$BOOT_MOUNT/config.txt"
 local cmdline_file="$BOOT_MOUNT/cmdline.txt"
 local cmdline token

 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0
 [[ -f "$config_file" ]] || die "Boot partition is missing config.txt"
 [[ -f "$cmdline_file" ]] || die "Boot partition is missing cmdline.txt"

 log "Applying Raspberry Pi 5 Bookworm boot defaults"

 if grep -Ev '^[[:space:]]*(#|$)' "$config_file" | grep -Eq '^[[:space:]]*dtoverlay=vc4-fkms-v3d([,[:space:]]|$)'; then
  die "Pi 5 target requires full KMS; boot config still enables vc4-fkms-v3d"
 fi

 if grep -Ev '^[[:space:]]*(#|$)' "$config_file" | grep -Eq '^[[:space:]]*dtoverlay=vc4-kms-v3d([,[:space:]]|$)'; then
  log "Boot config already enables vc4-kms-v3d"
 else
  {
   printf '\n# PGenerator+ Pi 5 Bookworm target\n'
   printf '[pi5]\n'
   printf 'dtoverlay=vc4-kms-v3d\n'
   printf '[all]\n'
  } >> "$config_file"
  log "Added Pi 5 vc4-kms-v3d boot config block"
 fi

 ensure_config_line "$config_file" "auto_initramfs" "0"

 cmdline="$(tr -d '\n' < "$cmdline_file")"
 cmdline="$(perl -e '
  my $cmd = join(" ", @ARGV);
  $cmd =~ s/(^| )quiet(?= |$)/ /g;
  $cmd =~ s/[[:space:]]+/ /g;
  $cmd =~ s/^ //;
  $cmd =~ s/ $//;
  print $cmd;
 ' "$cmdline")"
 for token in rootwait rootdelay=5 systemd.show_status=1 loglevel=7 consoleblank=0; do
  if [[ " $cmdline " != *" $token "* ]]; then
   cmdline="$cmdline $token"
  fi
 done
 printf '%s\n' "$cmdline" > "$cmdline_file"
 log "Configured Pi 5 direct-root boot cmdline diagnostics"
}

configure_pi5_headless_ssh() {
 local shadow_file="$ROOT_MOUNT/etc/shadow"
 local ssh_dropin_dir="$ROOT_MOUNT/etc/ssh/sshd_config.d"
 local ssh_wants_dir="$ROOT_MOUNT/etc/systemd/system/multi-user.target.wants"

 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0
 [[ -f "$shadow_file" ]] || die "Pi 5 rootfs is missing /etc/shadow"

 log "Enabling Raspberry Pi 5 headless SSH access"

 perl - "$PI5_ROOT_PASSWORD_HASH" "$shadow_file" > "$shadow_file.tmp" <<'PERL'
use strict;
use warnings;

my ($hash, $file) = @ARGV;
my $found = 0;

open(my $fh, "<", $file) or die "Cannot open $file: $!\n";
while (my $line = <$fh>) {
 chomp $line;
 my @fields = split /:/, $line, -1;
 if (($fields[0] // "") eq "root") {
  $fields[1] = $hash;
  push @fields, "" while @fields < 9;
  $found = 1;
 }
 print join(":", @fields), "\n";
}
close($fh);

if (!$found) {
 print join(":", "root", $hash, "20221", "0", "99999", "7", "", "", ""), "\n";
}
PERL
 install -m 0640 -o 0 -g 42 "$shadow_file.tmp" "$shadow_file" 2>/dev/null || install -m 0640 "$shadow_file.tmp" "$shadow_file"
 rm -f "$shadow_file.tmp"

 mkdir -p "$ssh_dropin_dir"
 cat > "$ssh_dropin_dir/99-pgenerator-headless.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
 chown root:root "$ssh_dropin_dir/99-pgenerator-headless.conf" 2>/dev/null || true
 chmod 0644 "$ssh_dropin_dir/99-pgenerator-headless.conf"

 mkdir -p "$ssh_wants_dir"
 if [[ -f "$ROOT_MOUNT/lib/systemd/system/ssh.service" ]]; then
  ln -sfn /lib/systemd/system/ssh.service "$ssh_wants_dir/ssh.service"
 fi
 if [[ -f "$ROOT_MOUNT/lib/systemd/system/regenerate_ssh_host_keys.service" ]]; then
  ln -sfn /lib/systemd/system/regenerate_ssh_host_keys.service "$ssh_wants_dir/regenerate_ssh_host_keys.service"
 fi

 : > "$BOOT_MOUNT/ssh"
 chmod 0644 "$BOOT_MOUNT/ssh" 2>/dev/null || true
}

label_pi5_partitions() {
 [[ "$TARGET" == "pi5-bookworm-armhf" ]] || return 0

 if command -v fatlabel >/dev/null 2>&1; then
  fatlabel "$BOOT_PARTITION" "$PI5_BOOT_LABEL" || die "Could not set boot partition label to $PI5_BOOT_LABEL"
 elif command -v dosfslabel >/dev/null 2>&1; then
  dosfslabel "$BOOT_PARTITION" "$PI5_BOOT_LABEL" || die "Could not set boot partition label to $PI5_BOOT_LABEL"
 else
  set_fat_volume_label_with_perl "$BOOT_PARTITION" "$PI5_BOOT_LABEL"
 fi

 if command -v e2label >/dev/null 2>&1; then
  e2label "$ROOT_PARTITION" "$PI5_ROOT_LABEL" || die "Could not set root partition label to $PI5_ROOT_LABEL"
 else
  die "e2label not installed; root partition label was not changed to $PI5_ROOT_LABEL"
 fi
}

set_fat_volume_label_with_perl() {
 local device="$1"
 local label="$2"

 perl - "$device" "$label" <<'PERL'
use strict;
use warnings;

my ($device, $label) = @ARGV;
die "missing FAT device\n" if !defined $device || $device eq "";
die "missing FAT label\n" if !defined $label || $label eq "";

$label = uc($label);
$label =~ s/[^A-Z0-9_ -]/_/g;
$label = substr($label, 0, 11);
$label = sprintf("%-11s", $label);

open(my $fh, "+<", $device) or die "open $device: $!\n";
binmode($fh);
read_exact($fh, my $boot, 512, 0);

my $bps = le16(substr($boot, 11, 2));
my $spc = ord(substr($boot, 13, 1));
my $reserved = le16(substr($boot, 14, 2));
my $fats = ord(substr($boot, 16, 1));
my $root_entries = le16(substr($boot, 17, 2));
my $fat16_sectors = le16(substr($boot, 22, 2));
my $fat32_sectors = le32(substr($boot, 36, 4));
my $fat_sectors = $fat16_sectors || $fat32_sectors;

die "unsupported FAT BPB in $device\n" if $bps <= 0 || $spc <= 0 || $reserved <= 0 || $fats <= 0 || $fat_sectors <= 0;

my $boot_label_offset = $root_entries ? 43 : 71;
write_at($fh, $boot_label_offset, $label);

if (!$root_entries) {
  my $backup_sector = le16(substr($boot, 50, 2));
  write_at($fh, ($backup_sector * $bps) + $boot_label_offset, $label) if $backup_sector > 0;
}

my ($root_offset, $root_len);
if ($root_entries) {
  $root_offset = ($reserved + ($fats * $fat_sectors)) * $bps;
  $root_len = $root_entries * 32;
} else {
  my $root_cluster = le32(substr($boot, 44, 4));
  my $data_offset = ($reserved + ($fats * $fat_sectors)) * $bps;
  my $cluster_size = $spc * $bps;
  die "invalid FAT32 root cluster in $device\n" if $root_cluster < 2;
  $root_offset = $data_offset + (($root_cluster - 2) * $cluster_size);
  $root_len = $cluster_size;
}

read_exact($fh, my $root, $root_len, $root_offset);
my $slot = -1;
for (my $off = 0; $off + 32 <= length($root); $off += 32) {
  my $first = ord(substr($root, $off, 1));
  my $attr = ord(substr($root, $off + 11, 1));
  if ($first != 0x00 && $first != 0xe5 && $attr == 0x08) {
    $slot = $off;
    last;
  }
}
if ($slot < 0) {
  for (my $off = 0; $off + 32 <= length($root); $off += 32) {
    my $first = ord(substr($root, $off, 1));
    if ($first == 0x00 || $first == 0xe5) {
      $slot = $off;
      last;
    }
  }
}
die "no root directory slot available for FAT volume label\n" if $slot < 0;

my $entry = $label . chr(0x08) . ("\0" x 20);
write_at($fh, $root_offset + $slot, $entry);
close($fh) or die "close $device: $!\n";

sub le16 {
  return unpack("v", $_[0]);
}

sub le32 {
  return unpack("V", $_[0]);
}

sub read_exact {
  my ($fh, undef, $len, $offset) = @_;
  seek($fh, $offset, 0) or die "seek $offset: $!\n";
  my $buf = "";
  my $got = read($fh, $buf, $len);
  die "short read at $offset\n" if !defined $got || $got != $len;
  $_[1] = $buf;
}

sub write_at {
  my ($fh, $offset, $data) = @_;
  seek($fh, $offset, 0) or die "seek $offset: $!\n";
  my $written = print {$fh} $data;
  die "write at $offset failed: $!\n" if !$written;
}
PERL
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
 local bin rel path pgenerator_uid pgenerator_gid

 log "Fixing ownership and permissions for release image"

 pgenerator_uid="$(awk -F: '$1=="pgenerator" {print $3; exit}' "$ROOT_MOUNT/etc/passwd" 2>/dev/null || true)"
 pgenerator_gid="$(awk -F: '$1=="pgenerator" {print $3; exit}' "$ROOT_MOUNT/etc/group" 2>/dev/null || true)"
 if [[ -z "$pgenerator_uid" ]] || [[ -z "$pgenerator_gid" ]]; then
  log "WARNING: pgenerator user/group missing from mounted image; falling back to numeric 1000:1000 for writable runtime paths"
  pgenerator_uid=1000
  pgenerator_gid=1000
 fi

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
  mkdir -p "$path"
  chown "$pgenerator_uid:$pgenerator_gid" "$path" || die "Could not set $rel_path owner to $pgenerator_uid:$pgenerator_gid"
  chmod "$mode" "$path" || die "Could not set $rel_path mode to $mode"
 }

 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers" 2>/dev/null || true
 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers.d" 2>/dev/null || true
 chown root:root "$ROOT_MOUNT/etc/sudo/sudoers.d/PGenerator" 2>/dev/null || true
 chmod 755 "$ROOT_MOUNT/etc/sudo" "$ROOT_MOUNT/etc/sudo/sudoers.d" 2>/dev/null || true
 chmod 440 "$ROOT_MOUNT/etc/sudo/sudoers" "$ROOT_MOUNT/etc/sudo/sudoers.d/PGenerator" 2>/dev/null || true
 chown root:root "$ROOT_MOUNT/etc/sudoers.d" "$ROOT_MOUNT/etc/sudoers.d/PGenerator" 2>/dev/null || true
 chmod 755 "$ROOT_MOUNT/etc/sudoers.d" 2>/dev/null || true
 chmod 440 "$ROOT_MOUNT/etc/sudoers.d/PGenerator" 2>/dev/null || true

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

 for path in "$ROOT_MOUNT"/usr/share/PGenerator/*.pm; do
  [[ -e "$path" ]] || continue
  chown root:root "$path" 2>/dev/null || true
  chmod 0644 "$path" 2>/dev/null || true
 done
 set_root_mode "usr/share/PGenerator/bash.pm" 0755
 set_root_mode "usr/share/PGenerator/daemon.pm" 0755

 for rel in \
  "etc/ntp.conf" \
  "etc/default/ntp"; do
  set_root_mode "$rel" 0644
 done
 set_root_mode "etc/default/ntpdate" 0755

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
 ensure_pgenerator_dir "var/lib/PGenerator/running/tmp" 0755
 ensure_pgenerator_dir "var/lib/PGenerator/ccss" 0755
 ensure_pgenerator_dir "var/lib/PGenerator/ccss/custom" 0755
 ensure_pgenerator_dir "var/lib/PGenerator/lg" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/ddc" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/luts" 0775
 ensure_pgenerator_dir "var/lib/PGenerator/lg/pin-sessions" 0775
 ensure_pgenerator_dir "var/log/PGenerator" 0755

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
 load_target_manifest
 require_root
 require_commands
 prepare_paths
 copy_base_image
 attach_loop_device
 discover_root_partition
 discover_boot_partition
 label_pi5_partitions
 mount_root_partition
 mount_boot_partition
 check_base_image
  overlay_tree
 stage_argyll_runtime
 reset_runtime_state
 configure_pi5_bookworm_root
 configure_pi5_display_defaults
 configure_pi5_bookworm_boot
 configure_pi5_headless_first_boot
 configure_pi5_headless_ssh
 configure_pi5_pgenerator_services
 if [[ "$TARGET" != "pi5-bookworm-armhf" ]]; then
  ensure_boot_ramdisk_size
  patch_boot_initramfs_rootwait
 fi
 fix_permissions
 validate_release_root
 finalize_image
}

main "$@"

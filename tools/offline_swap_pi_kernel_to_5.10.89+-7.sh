#!/usr/bin/env bash
set -euo pipefail

TARGET_RELEASE="5.10.89+-7"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_SOURCE_BASE=$(cd -- "$SCRIPT_DIR/../../PGenerator_original/RPI_img_extracted" && pwd)
APPLY=0
REPLACE_BOOT_TEXT=0
SOURCE_BASE="$DEFAULT_SOURCE_BASE"
BACKUP_ROOT=""

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [--apply] [--replace-boot-text] [--source-base DIR] BOOT_MOUNT ROOT_MOUNT [BACKUP_ROOT]

What it does:
  - Copies the extracted image boot payload onto the Pi boot partition.
  - Preserves config.txt and cmdline.txt by default.
  - Replaces only /lib/modules/$TARGET_RELEASE on the Pi root partition.
  - Creates host-side backups before changing anything.

Arguments:
  BOOT_MOUNT   Mounted FAT boot partition from the Pi drive.
  ROOT_MOUNT   Mounted root filesystem from the Pi drive.
  BACKUP_ROOT  Optional host directory for backups.

Options:
  --apply              Perform the swap. Without this flag, the script does a dry run.
  --replace-boot-text  Also replace config.txt and cmdline.txt from the extracted image.
  --source-base DIR    Override extracted image base directory.
EOF
}

log() {
    printf '[offline-kernel-swap] %s\n' "$*"
}

die() {
    printf '[offline-kernel-swap] ERROR: %s\n' "$*" >&2
    exit 1
}

require_dir() {
    local path=$1
    [[ -d "$path" ]] || die "Directory not found: $path"
}

copy_tree() {
    local src=$1
    local dst=$2
    mkdir -p "$dst"
    rsync -a "$src/" "$dst/"
}

copy_file_if_present() {
    local src=$1
    local dst_dir=$2
    if [[ -e "$src" ]]; then
        mkdir -p "$dst_dir"
        cp -a "$src" "$dst_dir/"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            APPLY=1
            shift
            ;;
        --replace-boot-text)
            REPLACE_BOOT_TEXT=1
            shift
            ;;
        --source-base)
            [[ $# -ge 2 ]] || die "--source-base requires a directory"
            SOURCE_BASE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

[[ $# -ge 2 && $# -le 3 ]] || {
    usage
    exit 1
}

BOOT_MOUNT=$1
ROOT_MOUNT=$2
if [[ $# -eq 3 ]]; then
    BACKUP_ROOT=$3
fi

require_dir "$BOOT_MOUNT"
require_dir "$ROOT_MOUNT"
require_dir "$SOURCE_BASE"

SOURCE_BOOT="$SOURCE_BASE/boot"
SOURCE_ROOT="$SOURCE_BASE/root"
SOURCE_MODULES="$SOURCE_ROOT/lib/modules/$TARGET_RELEASE"
TARGET_MODULES="$ROOT_MOUNT/lib/modules/$TARGET_RELEASE"

require_dir "$SOURCE_BOOT"
require_dir "$SOURCE_ROOT"
require_dir "$SOURCE_MODULES"
require_dir "$ROOT_MOUNT/lib/modules"

[[ -f "$BOOT_MOUNT/config.txt" ]] || die "BOOT_MOUNT does not look like a Pi boot partition: missing config.txt"
[[ -f "$BOOT_MOUNT/cmdline.txt" ]] || die "BOOT_MOUNT does not look like a Pi boot partition: missing cmdline.txt"
[[ -d "$BOOT_MOUNT/overlays" ]] || die "BOOT_MOUNT does not look like a Pi boot partition: missing overlays directory"

TS=$(date +%Y%m%d-%H%M%S)
if [[ -z "$BACKUP_ROOT" ]]; then
    BACKUP_ROOT="$PWD/offline-kernel-swap-backups/$TARGET_RELEASE-$TS"
fi

BOOT_BACKUP="$BACKUP_ROOT/boot_partition"
ROOT_BACKUP="$BACKUP_ROOT/root_modules"
mkdir -p "$BOOT_BACKUP" "$ROOT_BACKUP"

log "Source image base: $SOURCE_BASE"
log "Target boot mount: $BOOT_MOUNT"
log "Target root mount: $ROOT_MOUNT"
log "Target kernel release: $TARGET_RELEASE"
log "Backup root: $BACKUP_ROOT"

if cmp -s "$SOURCE_BOOT/config.txt" "$BOOT_MOUNT/config.txt"; then
    log "boot config.txt matches extracted image"
else
    log "boot config.txt differs from extracted image"
fi

if cmp -s "$SOURCE_BOOT/cmdline.txt" "$BOOT_MOUNT/cmdline.txt"; then
    log "boot cmdline.txt matches extracted image"
else
    log "boot cmdline.txt differs from extracted image"
fi

log "Backups that will be created:"
log "  $BOOT_BACKUP"
log "  $ROOT_BACKUP/$TARGET_RELEASE"

log "Boot files that will be copied from the extracted image:"
log "  bootcode.bin, start*.elf, fixup*.dat, kernel*.img, *.dtb, overlays/, extra/, initramfs.gz"
if [[ $REPLACE_BOOT_TEXT -eq 1 ]]; then
    log "  config.txt and cmdline.txt will also be replaced"
else
    log "  config.txt and cmdline.txt will be preserved"
fi
log "Modules tree that will be replaced:"
log "  $TARGET_MODULES"

if [[ $APPLY -ne 1 ]]; then
    log "Dry run only. Re-run with --apply once the Pi drive is mounted on this PC."
    exit 0
fi

command -v rsync >/dev/null 2>&1 || die "rsync is required on the PC host"

log "Creating host-side backups"
copy_tree "$BOOT_MOUNT" "$BOOT_BACKUP"
if [[ -d "$TARGET_MODULES" ]]; then
    copy_tree "$TARGET_MODULES" "$ROOT_BACKUP/$TARGET_RELEASE"
fi

log "Copying boot payload"
copy_file_if_present "$SOURCE_BOOT/bootcode.bin" "$BOOT_MOUNT"
copy_file_if_present "$SOURCE_BOOT/initramfs.gz" "$BOOT_MOUNT"

shopt -s nullglob
for pattern in \
    "$SOURCE_BOOT"/fixup*.dat \
    "$SOURCE_BOOT"/start*.elf \
    "$SOURCE_BOOT"/kernel*.img \
    "$SOURCE_BOOT"/*.dtb
    do
    for file in $pattern; do
        cp -a "$file" "$BOOT_MOUNT/"
    done
done
shopt -u nullglob

copy_tree "$SOURCE_BOOT/overlays" "$BOOT_MOUNT/overlays"
if [[ -d "$SOURCE_BOOT/extra" ]]; then
    copy_tree "$SOURCE_BOOT/extra" "$BOOT_MOUNT/extra"
fi

if [[ $REPLACE_BOOT_TEXT -eq 1 ]]; then
    cp -a "$SOURCE_BOOT/config.txt" "$BOOT_MOUNT/config.txt"
    cp -a "$SOURCE_BOOT/cmdline.txt" "$BOOT_MOUNT/cmdline.txt"
fi

log "Replacing $TARGET_MODULES"
mkdir -p "$ROOT_MOUNT/lib/modules"
rm -rf "$TARGET_MODULES"
copy_tree "$SOURCE_MODULES" "$TARGET_MODULES"

sync

log "Offline kernel payload swap complete"
log "Next steps:"
log "  1. Safely unmount both partitions"
log "  2. Reconnect the Pi drive"
log "  3. Boot the Pi and verify uname -r and API health"
log "Rollback: restore $BOOT_BACKUP back to the boot partition and $ROOT_BACKUP/$TARGET_RELEASE back to /lib/modules/$TARGET_RELEASE"

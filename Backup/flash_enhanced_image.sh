#!/bin/bash
set -euo pipefail
#
# Flash PGenerator_Enhanced.img to a USB drive / SD card.
#
# Usage:  sudo ./flash_enhanced_image.sh /dev/sdX
#
# WARNING: This will DESTROY all data on the target device!
#

IMG="$(dirname "$0")/PGenerator_Enhanced.img"

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo $0 /dev/sdX"
  echo "  List devices:  lsblk"
  exit 1
fi

DEVICE="$1"

if [[ ! -b "$DEVICE" ]]; then
  echo "Error: $DEVICE is not a block device"
  exit 1
fi

if [[ ! -f "$IMG" ]]; then
  echo "Error: $IMG not found"
  exit 1
fi

echo "=============================================="
echo " Flashing PGenerator Enhanced Image"
echo "=============================================="
echo " Source:  $IMG"
echo " Target:  $DEVICE"
echo " Size:    $(du -h "$IMG" | cut -f1)"
echo "=============================================="
echo ""
echo " WARNING: ALL DATA ON $DEVICE WILL BE LOST!"
echo ""
read -p " Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Unmounting partitions on $DEVICE..."
for part in "${DEVICE}"*; do
  umount "$part" 2>/dev/null || true
done

echo "Writing image (this may take several minutes)..."
dd if="$IMG" of="$DEVICE" bs=4M status=progress conv=fsync

echo ""
echo "Syncing..."
sync

echo ""
echo "Done! You can now safely remove $DEVICE."
echo "Insert the SD card into the PGenerator and boot."

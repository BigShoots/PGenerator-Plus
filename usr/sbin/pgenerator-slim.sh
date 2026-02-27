#!/bin/bash
###############################################################################
# pgenerator-slim.sh — PGenerator OS Image Size Reduction Script
#
# This script strips unnecessary files from a mounted PGenerator SD card
# image to significantly reduce its size. The stock PGenerator 1.6 image
# is ~6.5 GB; this can be reduced to under ~1.5 GB.
#
# Usage:
#   Mount the PGenerator SD card or loopback-mount the .img, then:
#     sudo ./pgenerator-slim.sh /mnt/pgenerator_root
#
# CAUTION: This is destructive. Back up the image first.
#          Test on a copy before applying to your only image.
#
# Copyright 2026 — Released under GPLv3 to match PGenerator licensing
###############################################################################

set -euo pipefail

ROOTFS="${1:?Usage: $0 <path-to-mounted-rootfs>}"

if [ ! -d "$ROOTFS" ]; then
    echo "ERROR: $ROOTFS is not a directory"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)"
    exit 1
fi

# Safety check — make sure this looks like a PGenerator rootfs
if [ ! -f "$ROOTFS/etc/PGenerator/PGenerator.conf" ]; then
    echo "ERROR: Does not look like a PGenerator rootfs (missing /etc/PGenerator/PGenerator.conf)"
    exit 1
fi

echo "============================================="
echo " PGenerator OS Image Size Reduction"
echo " Target: $ROOTFS"
echo "============================================="

log_removal() {
    local desc="$1"
    local path="$2"
    if [ -e "$path" ] || ls "$path" &>/dev/null 2>&1; then
        local size
        size=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
        echo "  [REMOVE] $desc ($size): $path"
    fi
}

bytes_before=$(df --output=used "$ROOTFS" 2>/dev/null | tail -1 || echo 0)

###############################################################################
echo ""
echo "--- Phase 1: Remove development/build files ---"
###############################################################################

# 1a. Remove VideoCore GPU example source code (~32 MB)
#     These are demo programs (hello_teapot, hello_triangle, etc.) not used at runtime
TARGET="$ROOTFS/opt/vc/src"
log_removal "VideoCore GPU example source" "$TARGET"
rm -rf "$TARGET"

# 1b. Remove C/C++ header files (~2 MB)
#     Only needed for compiling, not running PGenerator
TARGET="$ROOTFS/opt/vc/include"
log_removal "VideoCore header files" "$TARGET"
rm -rf "$TARGET"

# 1c. Remove static libraries (.a files) (~1.4 MB)
#     Only needed for static linking at build time
for f in "$ROOTFS"/opt/vc/lib/*.a; do
    if [ -f "$f" ]; then
        log_removal "Static library" "$f"
        rm -f "$f"
    fi
done

# 1d. Remove pkg-config files
TARGET="$ROOTFS/opt/vc/lib/pkgconfig"
log_removal "pkg-config files" "$TARGET"
rm -rf "$TARGET"

# 1e. Remove man pages from /opt/vc
TARGET="$ROOTFS/opt/vc/man"
log_removal "VideoCore man pages" "$TARGET"
rm -rf "$TARGET"

###############################################################################
echo ""
echo "--- Phase 2: Remove unused VideoCore binaries ---"
###############################################################################

# PGenerator only needs: vcgencmd, tvservice, edidparser, dtoverlay, dtparam
# plus the dynamic libs. Camera tools and test utilities are not needed.
KEEP_VC_BINS="vcgencmd tvservice edidparser dtoverlay dtoverlay-pre dtoverlay-post dtparam dtmerge"

for f in "$ROOTFS"/opt/vc/bin/*; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    keep=0
    for k in $KEEP_VC_BINS; do
        if [ "$fname" = "$k" ]; then
            keep=1
            break
        fi
    done
    if [ $keep -eq 0 ]; then
        log_removal "Unused VC binary" "$f"
        rm -f "$f"
    fi
done

# Remove unused container plugins (PGenerator doesn't use multimedia containers)
# Keep only the basic ones that might be needed for video playback
KEEP_PLUGINS="reader_rawvideo reader_binary"
for f in "$ROOTFS"/opt/vc/lib/plugins/*; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    keep=0
    for k in $KEEP_PLUGINS; do
        if echo "$fname" | grep -q "$k"; then
            keep=1
            break
        fi
    done
    if [ $keep -eq 0 ]; then
        log_removal "Unused container plugin" "$f"
        rm -f "$f"
    fi
done

###############################################################################
echo ""
echo "--- Phase 3: Remove system bloat ---"
###############################################################################

# 3a. System man pages
TARGET="$ROOTFS/usr/share/man"
log_removal "System man pages" "$TARGET"
rm -rf "$TARGET"

# 3b. System documentation (excluding PGenerator docs)
for d in "$ROOTFS"/usr/share/doc/*; do
    [ -d "$d" ] || continue
    dname=$(basename "$d")
    case "$dname" in
        PGenerator|configuration-PGenerator) continue ;;
        *) log_removal "Package docs" "$d"; rm -rf "$d" ;;
    esac
done

# 3c. Locale files (keep only en_US and C)
if [ -d "$ROOTFS/usr/share/locale" ]; then
    for d in "$ROOTFS"/usr/share/locale/*/; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        case "$dname" in
            en|en_US|en_GB|C|POSIX) continue ;;
            *) rm -rf "$d" ;;
        esac
    done
    echo "  [REMOVE] Unused locale data"
fi

# 3d. Info pages
TARGET="$ROOTFS/usr/share/info"
log_removal "GNU info pages" "$TARGET"
rm -rf "$TARGET"

# 3e. Remove Python bytecode caches if present
find "$ROOTFS" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$ROOTFS" -name "*.pyc" -delete 2>/dev/null || true
echo "  [REMOVE] Python bytecode caches"

# 3f. Remove log files
find "$ROOTFS/var/log" -type f -name "*.log" -delete 2>/dev/null || true
find "$ROOTFS/var/log" -type f -name "*.gz" -delete 2>/dev/null || true
echo "  [REMOVE] Old log files"

# 3g. Clean apt/package manager caches
TARGET="$ROOTFS/var/cache/apt"
if [ -d "$TARGET" ]; then
    log_removal "APT cache" "$TARGET/archives"
    rm -rf "$TARGET/archives"/*.deb 2>/dev/null || true
fi

# If BiasiLinux uses its own package manager:
TARGET="$ROOTFS/var/cache/packages"
if [ -d "$TARGET" ]; then
    log_removal "Package cache" "$TARGET"
    rm -rf "$TARGET"/*
fi

# 3h. Remove firmware files not needed for Pi (if present)
if [ -d "$ROOTFS/lib/firmware" ]; then
    # Keep only: brcm (WiFi/BT), regulatory.db
    for d in "$ROOTFS"/lib/firmware/*/; do
        [ -d "$d" ] || continue
        dname=$(basename "$d")
        case "$dname" in
            brcm|cypress) continue ;;  # WiFi + Bluetooth firmware
            *) log_removal "Unused firmware" "$d"; rm -rf "$d" ;;
        esac
    done
fi

# 3i. Remove X11/Xorg if present (PGenerator uses framebuffer/DRM directly)
for target in \
    "$ROOTFS/usr/share/X11" \
    "$ROOTFS/etc/X11" \
    "$ROOTFS/usr/lib/xorg" \
    "$ROOTFS/usr/bin/X" \
    "$ROOTFS/usr/bin/Xorg" \
    "$ROOTFS/usr/bin/startx" \
    "$ROOTFS/usr/share/xsessions"
do
    if [ -e "$target" ]; then
        log_removal "X11/Xorg component" "$target"
        rm -rf "$target"
    fi
done

# 3j. Remove desktop environment files if present
for target in \
    "$ROOTFS/usr/share/applications" \
    "$ROOTFS/usr/share/desktop-directories" \
    "$ROOTFS/usr/share/icons" \
    "$ROOTFS/usr/share/pixmaps" \
    "$ROOTFS/usr/share/themes" \
    "$ROOTFS/usr/share/fonts" \
    "$ROOTFS/usr/share/backgrounds" \
    "$ROOTFS/usr/share/wallpapers"
do
    if [ -e "$target" ]; then
        log_removal "Desktop component" "$target"
        rm -rf "$target"
    fi
done

# 3k. Remove Perl documentation and POD files (PGenerator doesn't need them)
for target in \
    "$ROOTFS/usr/share/perl" \
    "$ROOTFS/usr/share/perl5" \
    "$ROOTFS/usr/lib/perl/5.*/pod" \
    "$ROOTFS/usr/lib/perl5/5.*/pod"
do
    for d in $target; do
        if [ -d "$d" ] && echo "$d" | grep -q "pod$"; then
            log_removal "Perl POD docs" "$d"
            rm -rf "$d"
        fi
    done
done
find "$ROOTFS" -name "*.pod" -delete 2>/dev/null || true
echo "  [REMOVE] Perl POD documentation files"

# 3l. Remove GLib/GStreamer documentation and introspection data if present
for target in \
    "$ROOTFS/usr/share/gtk-doc" \
    "$ROOTFS/usr/share/gir-1.0" \
    "$ROOTFS/usr/lib/girepository-1.0" \
    "$ROOTFS/usr/share/glib-2.0/schemas"
do
    if [ -e "$target" ]; then
        log_removal "GLib/introspection data" "$target"
        rm -rf "$target"
    fi
done

# 3m. Remove unused large binaries (if present, not needed for PGenerator)
for target in \
    "$ROOTFS/usr/bin/gcc" \
    "$ROOTFS/usr/bin/g++" \
    "$ROOTFS/usr/bin/cc" \
    "$ROOTFS/usr/bin/c++" \
    "$ROOTFS/usr/bin/make" \
    "$ROOTFS/usr/bin/gdb" \
    "$ROOTFS/usr/bin/strace" \
    "$ROOTFS/usr/bin/python3" \
    "$ROOTFS/usr/bin/pip3"
do
    if [ -e "$target" ]; then
        log_removal "Unused dev tool" "$target"
        rm -f "$target"
    fi
done

# 3n. Remove C/C++ development headers system-wide
TARGET="$ROOTFS/usr/include"
if [ -d "$TARGET" ]; then
    log_removal "System header files" "$TARGET"
    rm -rf "$TARGET"
fi

# 3o. Remove static libraries system-wide
find "$ROOTFS/usr/lib" -name "*.a" -delete 2>/dev/null || true
echo "  [REMOVE] Static libraries (*.a)"

###############################################################################
echo ""
echo "--- Phase 4: Strip shared libraries ---"
###############################################################################

# Strip debug symbols from shared libraries (can save 20-40% per .so)
if command -v "${CROSS_COMPILE:-}strip" &>/dev/null || command -v strip &>/dev/null; then
    STRIP_CMD="${CROSS_COMPILE:-}strip"
    command -v "$STRIP_CMD" &>/dev/null || STRIP_CMD="strip"
    
    echo "  Stripping debug symbols from shared libraries..."
    find "$ROOTFS" -name "*.so*" -type f -exec "$STRIP_CMD" --strip-unneeded {} \; 2>/dev/null || true
    find "$ROOTFS" -name "PGeneratord" -type f -exec "$STRIP_CMD" --strip-unneeded {} \; 2>/dev/null || true
    echo "  [DONE] Stripped debug symbols"
else
    echo "  [SKIP] 'strip' command not available"
fi

###############################################################################
echo ""
echo "--- Phase 5: Clean temporary files ---"
###############################################################################

# 5a. Clear tmp directories
rm -rf "$ROOTFS"/tmp/* 2>/dev/null || true
rm -rf "$ROOTFS"/var/tmp/* 2>/dev/null || true
echo "  [REMOVE] Temporary files"

# 5b. Clear DHCP leases
rm -f "$ROOTFS"/var/lib/dhcp/*.leases 2>/dev/null || true
echo "  [REMOVE] DHCP leases"

# 5c. Clear bash history
rm -f "$ROOTFS"/root/.bash_history 2>/dev/null || true
rm -f "$ROOTFS"/home/*/.bash_history 2>/dev/null || true
echo "  [REMOVE] Shell history"

# 5d. Clear SSH host keys (will be regenerated on first boot)
rm -f "$ROOTFS"/etc/ssh/ssh_host_*_key* 2>/dev/null || true
echo "  [REMOVE] SSH host keys (will regenerate on boot)"

###############################################################################
echo ""
echo "--- Phase 6: Zero free space (for better compression) ---"
###############################################################################

echo "  Zeroing free space for better image compression..."
dd if=/dev/zero of="$ROOTFS/.zerofill" bs=1M 2>/dev/null || true
rm -f "$ROOTFS/.zerofill"
sync
echo "  [DONE] Free space zeroed"

###############################################################################
echo ""
echo "============================================="
echo " Size Reduction Complete!"
echo "============================================="

bytes_after=$(df --output=used "$ROOTFS" 2>/dev/null | tail -1 || echo 0)
if [ "$bytes_before" != "0" ] && [ "$bytes_after" != "0" ]; then
    saved=$(( (bytes_before - bytes_after) ))
    echo " Space saved: ~$(( saved / 1024 )) MB"
fi

echo ""
echo " Next steps:"
echo "   1. Unmount the image:  sudo umount /mnt/pgenerator_root"
echo "   2. Shrink the partition automatically with pishrink:"
echo "        sudo pishrink.sh -z PGenerator.img"
echo "      Or manually with resize2fs:"
echo "        sudo e2fsck -f /dev/loopXpY"
echo "        sudo resize2fs -M /dev/loopXpY"
echo "        # Then truncate the image to the new partition end"
echo "   3. Compress the final image:"
echo "        xz -9 -T0 PGenerator_slim.img"
echo "        (or: zstd -19 -T0 PGenerator_slim.img)"
echo ""
echo " Note: 'dialog' package must be present in the image for the"
echo " boot wizard. Verify with: chroot \$ROOTFS dpkg -l dialog"
echo ""

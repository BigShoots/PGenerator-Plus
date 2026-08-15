#!/bin/sh
# Wrap PGenerator-GitHub-Deployer-macOS.zip in a native macOS disk image.
# Run build-macos-package.sh first.
#
# On a Mac this uses hdiutil. On Linux it needs mkfs.hfsplus (hfsprogs /
# hfsplus-tools) plus the dmg and hfsplus tools from libdmg-hfsplus
# (github.com/planetbeing/libdmg-hfsplus; configure with
# -DCMAKE_POLICY_VERSION_MINIMUM=3.5 on current CMake). Population prefers a
# loop mount when permitted and falls back to userland injection with
# explicit executable bits.
set -eu

app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
zip_path="$app_dir/PGenerator-GitHub-Deployer-macOS.zip"
output="$app_dir/PGenerator-GitHub-Deployer-macOS.dmg"
volume="PGenerator GitHub Deployer"
[ -f "$zip_path" ] || { echo "Build the macOS zip first." >&2; exit 1; }

build_dir=$(mktemp -d /tmp/pgen-macos-dmg.XXXXXX)
cleanup() { rm -rf -- "$build_dir"; }
trap cleanup EXIT HUP INT TERM

unzip -q "$zip_path" -d "$build_dir/root"

if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -volname "$volume" -srcfolder "$build_dir/root/PGenerator-GitHub-Deployer" \
    -format UDZO -ov "$output"
  exit 0
fi

command -v mkfs.hfsplus >/dev/null 2>&1 || { echo "mkfs.hfsplus is required." >&2; exit 1; }
dmg_tool=${DMG_TOOL:-$(command -v dmg || echo "$HOME/libdmg-hfsplus/build/dmg/dmg")}
hfs_tool=${HFSPLUS_TOOL:-$(command -v hfsplus || echo "$HOME/libdmg-hfsplus/build/hfs/hfsplus")}
[ -x "$dmg_tool" ] || { echo "libdmg-hfsplus dmg tool is required (DMG_TOOL=...)." >&2; exit 1; }

size_kb=$(du -sk "$build_dir/root" | cut -f1)
img_kb=$(( size_kb + size_kb / 5 + 8192 ))
dd if=/dev/zero of="$build_dir/dmg.hfs" bs=1024 count="$img_kb" status=none
mkfs.hfsplus -v "$volume" "$build_dir/dmg.hfs" >/dev/null

mount_dir="$build_dir/mnt"
mkdir -p "$mount_dir"
if sudo -n mount -t hfsplus -o loop,rw "$build_dir/dmg.hfs" "$mount_dir" 2>/dev/null; then
  sudo cp -a "$build_dir/root/PGenerator-GitHub-Deployer" "$mount_dir/"
  sudo umount "$mount_dir"
else
  [ -x "$hfs_tool" ] || { echo "libdmg-hfsplus hfsplus tool is required (HFSPLUS_TOOL=...)." >&2; exit 1; }
  "$hfs_tool" "$build_dir/dmg.hfs" addall "$build_dir/root" >/dev/null
  "$hfs_tool" "$build_dir/dmg.hfs" chmod 755 "/PGenerator-GitHub-Deployer/run-macos.command"
  "$hfs_tool" "$build_dir/dmg.hfs" chmod 755 "/PGenerator-GitHub-Deployer/kill-server-macos.command"
  "$hfs_tool" "$build_dir/dmg.hfs" chmod 755 "/PGenerator-GitHub-Deployer/runtime/python/bin/python3.13"
  "$hfs_tool" "$build_dir/dmg.hfs" chmod 755 "/PGenerator-GitHub-Deployer/runtime/python/bin/python3"
fi

rm -f -- "$output"
"$dmg_tool" build "$build_dir/dmg.hfs" "$output" >/dev/null
echo "Created $output"
sha256sum "$output"

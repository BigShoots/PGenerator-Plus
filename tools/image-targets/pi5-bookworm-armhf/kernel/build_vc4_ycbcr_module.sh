#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/0001-vc4-add-pgenerator-hdmi-output-format-property.patch"

KERNEL_VERSION="${KERNEL_VERSION:-6.12.25+rpt-rpi-v8}"
KERNEL_TAG="${KERNEL_TAG:-stable_20250428}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
BUILD_DIR="${BUILD_DIR:-$TARGET_DIR/build/vc4-ycbcr-$KERNEL_VERSION}"
SOURCE_DIR="${SOURCE_DIR:-}"
KERNEL_HEADERS="${KERNEL_HEADERS:-}"
SOURCE_DIR_SET=0
DOWNLOAD_HEADERS=0
INSTALL_LIVE=0
INSTALL_DESTDIR=""

if [[ -n "$SOURCE_DIR" ]]; then
	SOURCE_DIR_SET=1
fi

usage() {
	cat <<USAGE
Usage: $0 [options]

Build the Pi 5 Bookworm vc4 module with PGenerator HDMI YCbCr output-format
support. Defaults target Raspberry Pi kernel $KERNEL_VERSION from tag
$KERNEL_TAG.

Options:
  --download-headers       Download/extract exact Raspberry Pi header debs into
                           the build directory. Does not extract anything to /.
  --headers PATH           Use an existing Kbuild header directory.
  --source PATH            Use an existing Raspberry Pi linux source directory.
  --build-dir PATH         Override the build/cache directory.
  --install-live           Replace the running system's vc4.ko.xz after build.
                           Backs up the stock module first. Reboot required.
  --install-destdir PATH   Install into an image/rootfs directory instead.
  -j, --jobs N             Parallel build jobs.
  -h, --help               Show this help.

Environment overrides: KERNEL_VERSION, KERNEL_TAG, ARCH, CROSS_COMPILE,
BUILD_DIR, SOURCE_DIR, KERNEL_HEADERS, JOBS.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--download-headers)
			DOWNLOAD_HEADERS=1
			shift
			;;
		--headers)
			KERNEL_HEADERS="$2"
			shift 2
			;;
		--source)
			SOURCE_DIR="$2"
			SOURCE_DIR_SET=1
			shift 2
			;;
		--build-dir)
			BUILD_DIR="$2"
			shift 2
			;;
		--install-live)
			INSTALL_LIVE=1
			shift
			;;
		--install-destdir)
			INSTALL_DESTDIR="$2"
			shift 2
			;;
		-j|--jobs)
			JOBS="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ "$SOURCE_DIR_SET" -eq 0 ]]; then
	SOURCE_DIR="$BUILD_DIR/linux-$KERNEL_TAG"
fi

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

need git
need make
need curl
need tar

if [[ ! -f "$PATCH_FILE" ]]; then
	echo "Missing patch: $PATCH_FILE" >&2
	exit 1
fi

mkdir -p "$BUILD_DIR"

if [[ "$DOWNLOAD_HEADERS" -eq 1 ]]; then
	need apt-get
	need dpkg-deb
	HEADER_ROOT="$BUILD_DIR/headers-root"
	mkdir -p "$HEADER_ROOT" "$BUILD_DIR/debs"
	pushd "$BUILD_DIR/debs" >/dev/null
	common_version="${KERNEL_VERSION%-rpi-*}"
	common_pkg="linux-headers-${common_version}-common-rpi"
	arch_pkg="linux-headers-${KERNEL_VERSION}:arm64"
	apt-get download "$common_pkg" "$arch_pkg"
	for deb in ./*.deb; do
		dpkg-deb -x "$deb" "$HEADER_ROOT"
	done
	popd >/dev/null
	KERNEL_HEADERS="$HEADER_ROOT/usr/src/linux-headers-$KERNEL_VERSION"
fi

if [[ -z "$KERNEL_HEADERS" ]]; then
	if [[ -d "/lib/modules/$KERNEL_VERSION/build" ]]; then
		KERNEL_HEADERS="/lib/modules/$KERNEL_VERSION/build"
	else
		echo "No kernel headers found for $KERNEL_VERSION." >&2
		echo "Pass --headers PATH or use --download-headers on a Raspberry Pi OS system." >&2
		exit 1
	fi
fi

if [[ ! -d "$KERNEL_HEADERS" ]]; then
	echo "Kernel headers directory does not exist: $KERNEL_HEADERS" >&2
	exit 1
fi

if [[ ! -d "$SOURCE_DIR/drivers/gpu/drm/vc4" ]]; then
	archive="$BUILD_DIR/raspberrypi-linux-$KERNEL_TAG.tar.gz"
	if [[ ! -f "$archive" ]]; then
		curl -L --fail \
			"https://github.com/raspberrypi/linux/archive/refs/tags/$KERNEL_TAG.tar.gz" \
			-o "$archive"
	fi
	rm -rf "$SOURCE_DIR"
	mkdir -p "$SOURCE_DIR"
	tar -xzf "$archive" --strip-components=1 -C "$SOURCE_DIR"
fi

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
	echo "Patch already applied in $SOURCE_DIR"
else
	git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
	git -C "$SOURCE_DIR" apply "$PATCH_FILE"
fi

make -C "$KERNEL_HEADERS" \
	M="$SOURCE_DIR/drivers/gpu/drm/vc4" \
	ARCH="$ARCH" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	-j"$JOBS" \
	modules

MODULE="$SOURCE_DIR/drivers/gpu/drm/vc4/vc4.ko"
if [[ ! -f "$MODULE" ]]; then
	echo "Build completed but vc4.ko was not produced at $MODULE" >&2
	exit 1
fi

echo "Built: $MODULE"

install_module_to_root() {
	local root="$1"
	local module="$2"
	local dest="$root/lib/modules/$KERNEL_VERSION/kernel/drivers/gpu/drm/vc4/vc4.ko.xz"
	local backup=""

	mkdir -p "$(dirname "$dest")"
	if [[ -f "$dest" ]]; then
		backup="$dest.pgenerator-backup-$(date +%Y%m%d%H%M%S)"
		cp -a "$dest" "$backup"
		echo "Backed up stock module: $backup"
	fi
	install -m 0644 "$module" "${dest%.xz}"
	xz -f "${dest%.xz}"
	if command -v depmod >/dev/null 2>&1; then
		if [[ -n "$root" ]]; then
			depmod -b "$root" "$KERNEL_VERSION" || true
		else
			depmod "$KERNEL_VERSION" || true
		fi
	fi
	echo "Installed patched module: $dest"
}

if [[ "$INSTALL_LIVE" -eq 1 ]]; then
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "--install-live must run as root" >&2
		exit 1
	fi
	install_module_to_root "" "$MODULE"
	echo "Reboot the Pi to load the patched vc4 module."
fi

if [[ -n "$INSTALL_DESTDIR" ]]; then
	install_module_to_root "$INSTALL_DESTDIR" "$MODULE"
fi

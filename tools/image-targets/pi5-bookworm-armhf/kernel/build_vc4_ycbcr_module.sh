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
INSTALL_BOOT_DIR=""
SKIP_INITRAMFS=0
PREBUILT_MODULE=""

if [[ -n "$SOURCE_DIR" ]]; then
	SOURCE_DIR_SET=1
fi

usage() {
	cat <<USAGE
Usage: $0 [options]

Build the Pi 5 Bookworm vc4 module with PGenerator HDMI YCbCr output-format
support. The helper builds from full Raspberry Pi kernel source, using the
target kernel headers for .config, Module.symvers, and exact release metadata.
Defaults target Raspberry Pi kernel $KERNEL_VERSION from tag $KERNEL_TAG.

Options:
  --download-headers       Download/extract exact Raspberry Pi header debs into
                           the build directory. Does not extract anything to /.
  --headers PATH           Use an existing Kbuild header directory.
  --source PATH            Use an existing Raspberry Pi linux source directory.
  --build-dir PATH         Override the build/cache directory.
  --install-live           Replace the running system's vc4.ko.xz after build.
                           Backs up the stock module first and updates the live
                           boot initramfs when one is found. Reboot required.
  --install-destdir PATH   Install into an image/rootfs directory instead.
  --install-boot-dir PATH  Repack a boot initramfs with the patched vc4 module.
                           PATH may be a boot mount directory or initramfs file.
  --module PATH            Use an existing patched vc4.ko or vc4.ko.xz instead
                           of building one from source.
  --no-initramfs           Skip initramfs updates during install steps.
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
		--install-boot-dir)
			INSTALL_BOOT_DIR="$2"
			shift 2
			;;
		--module)
			PREBUILT_MODULE="$2"
			shift 2
			;;
		--no-initramfs)
			SKIP_INITRAMFS=1
			shift
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

if [[ -z "$PREBUILT_MODULE" ]]; then
	need git
	need make
	need curl
	need tar

	if [[ ! -f "$PATCH_FILE" ]]; then
		echo "Missing patch: $PATCH_FILE" >&2
		exit 1
	fi
fi

mkdir -p "$BUILD_DIR"

MODULE=""

if [[ -n "$PREBUILT_MODULE" ]]; then
	if [[ ! -f "$PREBUILT_MODULE" ]]; then
		echo "Prebuilt module does not exist: $PREBUILT_MODULE" >&2
		exit 1
	fi
	case "$PREBUILT_MODULE" in
		*.xz)
			need xz
			MODULE="$BUILD_DIR/prebuilt-vc4.ko"
			xz -dc "$PREBUILT_MODULE" > "$MODULE"
			;;
		*)
			MODULE="$PREBUILT_MODULE"
			;;
	esac
	if command -v modinfo >/dev/null 2>&1; then
		vermagic="$(modinfo -F vermagic "$MODULE" 2>/dev/null || true)"
		if [[ "$vermagic" != "$KERNEL_VERSION "* ]]; then
			echo "Prebuilt module vermagic does not match $KERNEL_VERSION: $vermagic" >&2
			exit 1
		fi
	fi
	echo "Using prebuilt module: $MODULE"
else

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

patch_marker_present() {
	grep -q "vc4_hdmi_pgenerator_output_format" "$SOURCE_DIR/drivers/gpu/drm/vc4/vc4_hdmi.c" &&
	grep -q "PGenerator" "$SOURCE_DIR/drivers/gpu/drm/vc4/vc4_hdmi.c" &&
	grep -q "output_format_property" "$SOURCE_DIR/drivers/gpu/drm/vc4/vc4_hdmi.h"
}

if git -C "$SOURCE_DIR" apply --recount --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
	echo "Patch already applied in $SOURCE_DIR"
elif patch_marker_present; then
	echo "Patch markers already present in $SOURCE_DIR"
else
	git -C "$SOURCE_DIR" apply --recount --check "$PATCH_FILE"
	git -C "$SOURCE_DIR" apply --recount "$PATCH_FILE"
fi

if [[ ! -f "$KERNEL_HEADERS/.config" ]]; then
	echo "Kernel headers are missing .config: $KERNEL_HEADERS" >&2
	exit 1
fi
if [[ ! -f "$KERNEL_HEADERS/Module.symvers" ]]; then
	echo "Kernel headers are missing Module.symvers: $KERNEL_HEADERS" >&2
	exit 1
fi

cp "$KERNEL_HEADERS/.config" "$SOURCE_DIR/.config"
cp "$KERNEL_HEADERS/Module.symvers" "$SOURCE_DIR/Module.symvers"

make -C "$SOURCE_DIR" \
	ARCH="$ARCH" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	olddefconfig
make -C "$SOURCE_DIR" \
	ARCH="$ARCH" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	modules_prepare

if [[ -f "$KERNEL_HEADERS/include/generated/utsrelease.h" ]]; then
	cp "$KERNEL_HEADERS/include/generated/utsrelease.h" \
		"$SOURCE_DIR/include/generated/utsrelease.h"
fi
if [[ -f "$KERNEL_HEADERS/include/config/kernel.release" ]]; then
	cp "$KERNEL_HEADERS/include/config/kernel.release" \
		"$SOURCE_DIR/include/config/kernel.release"
fi

make -C "$SOURCE_DIR" \
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
fi

install_module_to_root() {
	local root="$1"
	local module="$2"
	local dest="$root/lib/modules/$KERNEL_VERSION/kernel/drivers/gpu/drm/vc4/vc4.ko.xz"
	local backup=""

	if [[ -n "$root" ]]; then
		if [[ ! -L "$root/lib" ]] || [[ "$(readlink "$root/lib")" != "usr/lib" ]]; then
			echo "Refusing to install vc4 module: $root/lib is not the Pi 5 Bookworm usrmerge symlink" >&2
			exit 1
		fi
	fi

	mkdir -p "$(dirname "$dest")"
	if [[ -f "$dest" ]]; then
		backup="$dest.pgenerator-backup-$(date +%Y%m%d%H%M%S)"
		cp -a "$dest" "$backup"
		echo "Backed up stock module: $backup"
	fi
	need xz
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

kernel_flavour_suffix() {
	case "$KERNEL_VERSION" in
		*-rpi-v8) printf '8\n' ;;
		*-rpi-v7l) printf '7l\n' ;;
		*-rpi-v7) printf '7\n' ;;
		*-rpi-v6) printf '\n' ;;
		*) printf '\n' ;;
	esac
}

resolve_initramfs_target() {
	local target="$1"
	local suffix
	local candidate

	if [[ -f "$target" ]]; then
		printf '%s\n' "$target"
		return 0
	fi
	if [[ ! -d "$target" ]]; then
		return 1
	fi

	suffix="$(kernel_flavour_suffix)"
	for candidate in \
		"$target/initramfs$suffix" \
		"$target/initramfs.gz" \
		"$target/initrd.img-$KERNEL_VERSION"; do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

find_live_initramfs() {
	local suffix
	local candidate

	suffix="$(kernel_flavour_suffix)"
	for candidate in \
		"/boot/firmware/initramfs$suffix" \
		"/boot/firmware/initramfs.gz" \
		"/boot/initramfs.gz" \
		"/boot/initrd.img-$KERNEL_VERSION"; do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

detect_initramfs_codec() {
	local initramfs_file="$1"

	if command -v zstd >/dev/null 2>&1 &&
	   zstd -q -t "$initramfs_file" >/dev/null 2>&1; then
		printf 'zstd\n'
		return 0
	fi
	if gzip -t "$initramfs_file" >/dev/null 2>&1; then
		printf 'gzip\n'
		return 0
	fi

	return 1
}

install_module_to_initramfs() {
	local initramfs_file="$1"
	local module="$2"
	local work=""
	local root=""
	local repacked="$initramfs_file.repacked"
	local backup=""
	local module_rel="modules/$KERNEL_VERSION/kernel/drivers/gpu/drm/vc4/vc4.ko"
	local module_paths=()
	local codec=""
	local rel

	[[ -n "$initramfs_file" ]] || return 0
	if [[ ! -f "$initramfs_file" ]]; then
		echo "Boot initramfs not found: $initramfs_file" >&2
		exit 1
	fi

	need cpio
	need xz
	need gzip
	codec="$(detect_initramfs_codec "$initramfs_file")" || {
		echo "Unsupported initramfs compression: $initramfs_file" >&2
		exit 1
	}
	if [[ "$codec" == "zstd" ]]; then
		need zstd
	fi

	work="$(mktemp -d)"
	root="$work/root"
	repacked="$work/initramfs"
	mkdir -p "$root"

	(
		cd "$root"
		case "$codec" in
			zstd) zstd -q -dc "$initramfs_file" ;;
			gzip) gzip -dc "$initramfs_file" ;;
		esac | cpio -id --quiet --no-absolute-filenames || true
	)

	if [[ ! -e "$root/init" && ! -d "$root/lib" && ! -d "$root/usr/lib" ]]; then
		rm -rf "$work"
		echo "Could not unpack a recognizable initramfs from $initramfs_file" >&2
		exit 1
	fi

	for rel in "lib/$module_rel" "lib/$module_rel.xz" \
		   "usr/lib/$module_rel" "usr/lib/$module_rel.xz"; do
		if [[ -e "$root/$rel" ]]; then
			module_paths+=("$rel")
		fi
	done
	if [[ "${#module_paths[@]}" -eq 0 ]]; then
		if [[ -d "$root/usr/lib" || ( -L "$root/lib" && "$(readlink "$root/lib")" == "usr/lib" ) ]]; then
			module_paths+=("usr/lib/$module_rel")
		else
			module_paths+=("lib/$module_rel")
		fi
	fi

	for rel in "${module_paths[@]}"; do
		mkdir -p "$(dirname "$root/$rel")"
		if [[ "$rel" == *.xz ]]; then
			xz -c "$module" > "$root/$rel"
			chmod 0644 "$root/$rel"
		else
			install -m 0644 "$module" "$root/$rel"
		fi
	done

	(
		cd "$root"
		case "$codec" in
			zstd) find . -print | LC_ALL=C sort | cpio -o -H newc --quiet | zstd -q -19 -T0 -o "$repacked" ;;
			gzip) find . -print | LC_ALL=C sort | cpio -o -H newc --quiet | gzip -9n > "$repacked" ;;
		esac
	)

	backup="$initramfs_file.pgenerator-backup-$(date +%Y%m%d%H%M%S)"
	cp -a "$initramfs_file" "$backup"
	install -m 0644 "$repacked" "$initramfs_file"
	rm -rf "$work"

	echo "Backed up initramfs: $backup"
	echo "Installed patched module into initramfs: $initramfs_file (${module_paths[*]})"
}

INITRAMFS_INSTALLED=0

install_requested_initramfs() {
	local initramfs_file=""

	if [[ "$SKIP_INITRAMFS" -eq 1 ]]; then
		return 0
	fi
	if [[ -n "$INSTALL_BOOT_DIR" ]]; then
		if ! initramfs_file="$(resolve_initramfs_target "$INSTALL_BOOT_DIR")"; then
			echo "No initramfs found at --install-boot-dir target: $INSTALL_BOOT_DIR" >&2
			exit 1
		fi
	else
		if ! initramfs_file="$(find_live_initramfs)"; then
			echo "No live initramfs found under /boot/firmware or /boot; pass --install-boot-dir PATH if needed."
			return 0
		fi
	fi

	install_module_to_initramfs "$initramfs_file" "$MODULE"
	INITRAMFS_INSTALLED=1
}

if [[ "$INSTALL_LIVE" -eq 1 ]]; then
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "--install-live must run as root" >&2
		exit 1
	fi
	install_module_to_root "" "$MODULE"
	install_requested_initramfs
	echo "Reboot the Pi to load the patched vc4 module."
fi

if [[ -n "$INSTALL_DESTDIR" ]]; then
	install_module_to_root "$INSTALL_DESTDIR" "$MODULE"
fi

if [[ -n "$INSTALL_BOOT_DIR" && "$SKIP_INITRAMFS" -eq 0 && "$INITRAMFS_INSTALLED" -eq 0 ]]; then
	initramfs_file="$(resolve_initramfs_target "$INSTALL_BOOT_DIR")" || {
		echo "No initramfs found at --install-boot-dir target: $INSTALL_BOOT_DIR" >&2
		exit 1
	}
	install_module_to_initramfs "$initramfs_file" "$MODULE"
fi

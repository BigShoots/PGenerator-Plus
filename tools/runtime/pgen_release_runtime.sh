#!/usr/bin/env bash

# Shared image/OTA ownership and validation for calibration-maths runtime
# files. Builders supply their staging root and release kind explicitly; base
# image and ABI checks remain in the image builder.

PGEN_RELEASE_DEVICE_STATE_DROPS=(
 "etc/PGenerator/hdr20_postcal_shadow_matrix.json"
 "etc/PGenerator/lut.txt"
 "etc/BiasiLinux/BiasiLinux.FirstBoot"
)

# command.pm and conf.pm are NOT target-owned: the shared runtime tree carries
# the unified Pi 4 / Pi 5 platform support (Colorspace vs Colorimetry, Broadcast
# RGB mapping, atomic output format), so the shared copies flow to every target.
PGEN_RELEASE_TARGET_OWNED_RUNTIME_PATHS=(
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

# BiasiLinux (Pi 4) system files that must never reach a Raspberry Pi OS
# Bookworm root: sysv clock scripts and rc links (Bookworm runs
# systemd-timesyncd and its own fake-hwclock package), the /etc/sudo layout
# (Bookworm uses /etc/sudoers.d), and the Pi 4 kernel's wireless regulatory
# database (Bookworm ships wireless-regdb; a foreign regulatory.db fails the
# signature check and drops WiFi to the world regdom).
PGEN_RELEASE_PI4_ONLY_SYSTEM_PATHS=(
 "etc/init.d/ntp"
 "etc/init.d/fake-hwclock"
 "etc/cron.hourly/fake-hwclock"
 "etc/ntp.conf"
 "etc/default/ntp"
 "etc/default/ntpdate"
 "etc/rc0.d"
 "etc/rc2.d"
 "etc/rc3.d"
 "etc/rc4.d"
 "etc/rc5.d"
 "etc/rc6.d"
 "etc/rcS.d"
 "etc/sudo"
 "lib/firmware"
)
PGEN_RELEASE_EXTERNAL_ICC_TOOL_PATHS=(
 "usr/bin/icc_companion_package.py"
 "usr/share/PGenerator/icc-companion"
 "usr/share/PGenerator/icc-companion-src"
)

PGEN_RELEASE_REQUIRED_MATH_FILES=(
 "usr/bin/pgen_colour_math.py"
 "usr/bin/pgen_meter_average.py"
 "usr/bin/pgen_meter_result.py"
 "usr/bin/pgen_series_steps.py"
 "usr/share/PGenerator/PGCalibrationMath.pm"
 "usr/share/PGenerator/PGMath.pm"
 "usr/share/PGenerator/PGMeterReading.pm"
 "usr/share/PGenerator/PGSignalCode.pm"
 "usr/share/PGenerator/webui-colour-math.js"
)

PGEN_RELEASE_REQUIRED_MATH_EXECUTABLES=(
 "usr/bin/pgen_lut_solve"
)

pgen_release_rsync_excludes_for_rel() {
 local rel="$1"
 local owned
 local target_owned=(
  "${PGEN_RELEASE_TARGET_OWNED_RUNTIME_PATHS[@]}"
  "${PGEN_RELEASE_EXTERNAL_ICC_TOOL_PATHS[@]}"
 )
 if [[ "$TARGET" == "pi5-bookworm-armhf" ]]; then
  target_owned+=("${PI4_NUMPY_RUNTIME_PATHS[@]}" "${PGEN_RELEASE_PI4_ONLY_SYSTEM_PATHS[@]}")
 fi
 for owned in "${target_owned[@]}"; do
  case "$owned" in
   "$rel"/*) printf '%s\n' "--exclude=/${owned#$rel/}" ;;
  esac
 done
}

pgen_release_remove_external_icc_tools() {
 local root="$1"
 local rel

 log "Removing standalone ICC Tools supplied through GitHub releases"
 for rel in "${PGEN_RELEASE_EXTERNAL_ICC_TOOL_PATHS[@]}"; do
  rm -rf -- "$root/$rel"
 done
}

pgen_release_validate_colour_math_runtime() {
 local root="$1"
 local release_kind="$2"
 local rel

 for rel in "${PGEN_RELEASE_REQUIRED_MATH_FILES[@]}"; do
  [[ -f "$root/$rel" ]] || die "Math runtime is missing /$rel"
 done
 for rel in "${PGEN_RELEASE_REQUIRED_MATH_EXECUTABLES[@]}"; do
  [[ -x "$root/$rel" ]] || die "Math runtime is missing executable /$rel"
 done
 file "$root/usr/bin/pgen_lut_solve" | grep -q 'ELF 32-bit.*ARM.*statically linked' || \
  die "pgen_lut_solve must be a static 32-bit ARM executable"

 if [[ "$TARGET" == "pi4-biasi" ]]; then
  for rel in "${PI4_NUMPY_RUNTIME_PATHS[@]}"; do
   [[ -e "$root/$rel" ]] || die "Pi 4 math runtime is missing /$rel"
  done
  rel="usr/lib/python3/dist-packages/numpy/core/_multiarray_umath.cpython-35m-arm-linux-gnueabihf.so"
  [[ -f "$root/$rel" ]] || die "Pi 4 NumPy runtime is missing /$rel"
  file "$root/$rel" | grep -q 'ELF 32-bit.*ARM' || \
   die "Pi 4 NumPy core must use the 32-bit ARM CPython 3.5 ABI"
  for rel in usr/lib/libatlas.so.3 usr/lib/libblas.so.3 usr/lib/libcblas.so.3 \
             usr/lib/libf77blas.so.3 usr/lib/liblapack.so.3; do
   file "$root/$rel" | grep -q 'ELF 32-bit.*ARM' || \
    die "Pi 4 numerical library /$rel is not a 32-bit ARM binary"
  done
 else
  [[ ! -e "$root/usr/lib/python3/dist-packages/numpy-1.18.5.dist-info" ]] || \
   die "Pi 5 $release_kind must not contain the Pi 4 NumPy 1.18.5 runtime"
  if find "$root/usr/lib/python3/dist-packages" -type f \
      -name '*.cpython-35m-arm-linux-gnueabihf.so' -print -quit 2>/dev/null | grep -q .; then
   die "Pi 5 $release_kind contains a Pi 4 CPython 3.5 extension"
  fi
 fi
 log "Validated shared colour-math modules and native LUT helper"
}

# Bookworm reads /etc/sudoers.d; the shared tree carries the BiasiLinux
# /etc/sudo/sudoers.d layout. Install the shared rule set at the Bookworm
# path so there is exactly one copy to maintain.
pgen_release_install_pi5_sudoers() {
 local root="$1"
 local src="$REPO_ROOT/etc/sudo/sudoers.d/PGenerator"
 [[ -f "$src" ]] || die "Shared sudoers rule set is missing: $src"
 install -d -m 0755 "$root/etc/sudoers.d"
 install -m 0440 "$src" "$root/etc/sudoers.d/PGenerator"
 rm -rf "$root/etc/sudo"
 log "Installed the shared PGenerator sudoers rules at /etc/sudoers.d/PGenerator"
}

# The Pi 5 renderer is a native Bookworm build. Fail closed if the target
# overlay carries the Pi 4 legacy binary (glibc 2.21) or a stale/foreign file.
pgen_release_validate_pi5_renderer() {
 local root="$1"
 local bin max_glibc
 for bin in usr/sbin/PGeneratord usr/sbin/PGeneratord.dv; do
  [[ -f "$root/$bin" ]] || die "Pi 5 payload is missing /$bin"
  # The builders run with pipefail: "grep -q" exits at the first match and
  # the producer dies of SIGPIPE, which turns a successful check into a
  # failure. Let grep consume the whole stream instead.
  file "$root/$bin" | grep 'ELF 32-bit LSB.*ARM' >/dev/null || die "/$bin is not a 32-bit ARM executable"
  strings "$root/$bin" | grep -F '/etc/PGenerator/PGenerator.conf' >/dev/null || die "/$bin does not read PGenerator.conf (not a PGenerator renderer build)"
  max_glibc="$(strings "$root/$bin" | grep -E '^GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1)"
  [[ -n "$max_glibc" ]] || die "Could not determine the glibc requirement of /$bin"
  [[ "$(printf '%s\n%s\n' "$max_glibc" '2.28' | sort -V | head -1)" == '2.28' ]] || \
   die "/$bin needs only glibc $max_glibc: this is the Pi 4 legacy renderer, not the Bookworm build"
 done
 cmp -s "$root/usr/sbin/PGeneratord" "$root/usr/sbin/PGeneratord.dv" || \
  die "Pi 5 PGeneratord and PGeneratord.dv differ; the Pi 5 deploy flow installs the same native build under both names"
 log "Validated the Pi 5 renderer: native Bookworm build (glibc $max_glibc)"
}

# Symlinks the runtime trees must carry as SYMLINKS. A checkout made with
# core.symlinks=false (or a copy through a tool that drops links) turns them
# into tiny text files holding the target path. Staging such a file is
# destructive: a copy of "liblzma.so.0" that is really the text
# "liblzma.so.5" landed on the bench Pi 5 through the existing
# liblzma.so.0 -> liblzma.so.5 -> liblzma.so.5.4.1 chain and overwrote the
# system xz library (2026-09-05: sshd and NetworkManager died, cold boot hung).
PGEN_RELEASE_REQUIRED_SYMLINKS=(
 "usr/lib/arm-linux-gnueabihf/liblzma.so.0"
 "usr/lib/arm-linux-gnueabihf/libXss.so.1"
)

# Repair flattened symlinks in a staged root: a regular file of <= 200 bytes
# whose whole content is a relative path becomes a symlink to that path.
# Anything else at a required-symlink path is fatal.
pgen_release_repair_flattened_symlinks() {
 local root="$1"
 local rel path content
 for rel in "${PGEN_RELEASE_REQUIRED_SYMLINKS[@]}"; do
  path="$root/$rel"
  [[ -e "$path" || -L "$path" ]] || continue
  if [[ -L "$path" ]]; then
   continue
  fi
  if [[ -f "$path" ]] && [[ "$(stat -c %s "$path")" -le 200 ]]; then
   content="$(tr -d '\n' < "$path")"
   if [[ "$content" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]]; then
    rm -f "$path"
    ln -s "$content" "$path"
    log "Repaired flattened symlink /$rel -> $content"
    continue
   fi
  fi
  die "/$rel must be a symlink; found a regular file that is not a flattened link"
 done
}

# Fail closed if a required symlink is still not a symlink after staging.
pgen_release_validate_required_symlinks() {
 local root="$1"
 local rel
 for rel in "${PGEN_RELEASE_REQUIRED_SYMLINKS[@]}"; do
  [[ ! -e "$root/$rel" && ! -L "$root/$rel" ]] && continue
  [[ -L "$root/$rel" ]] || die "/$rel is a regular file; it must be a symlink (never copy it onto a device: it would overwrite the link target)"
 done
 log "Validated required symlinks in the staged root"
}

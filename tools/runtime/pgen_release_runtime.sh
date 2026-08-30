#!/usr/bin/env bash

# Shared image/OTA ownership and validation for calibration-maths runtime
# files. Builders supply their staging root and release kind explicitly; base
# image and ABI checks remain in the image builder.

PGEN_RELEASE_DEVICE_STATE_DROPS=(
 "etc/PGenerator/hdr20_postcal_shadow_matrix.json"
 "etc/PGenerator/lut.txt"
 "etc/BiasiLinux/BiasiLinux.FirstBoot"
)

PGEN_RELEASE_TARGET_OWNED_RUNTIME_PATHS=(
 "usr/share/PGenerator/command.pm"
 "usr/share/PGenerator/conf.pm"
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
  target_owned+=("${PI4_NUMPY_RUNTIME_PATHS[@]}")
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

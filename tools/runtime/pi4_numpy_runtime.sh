#!/usr/bin/env bash

# Reconstruct the legacy Pi 4 / CPython 3.5 numerical runtime from pinned
# upstream binary packages. Both release builders source this file so fetch,
# integrity checking, pruning, and staging cannot drift apart.

PI4_NUMPY_RUNTIME_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI4_NUMPY_RUNTIME_FILE_LIST="$PI4_NUMPY_RUNTIME_HELPER_DIR/pi4_numpy_runtime_files.txt"

PI4_NUMPY_WHEEL_NAME="numpy-1.18.5-cp35-cp35m-linux_armv7l.whl"
PI4_NUMPY_WHEEL_URL="https://www.piwheels.org/simple/numpy/$PI4_NUMPY_WHEEL_NAME"
PI4_NUMPY_WHEEL_SHA256="d0a8cddf6be1f3b6aca25784076c0bc54ff2f4fd27e2048f76722aca13487794"

PI4_ATLAS_DEB_NAME="libatlas3-base_3.10.2-7_armhf.deb"
PI4_ATLAS_DEB_URL="https://archive.debian.org/debian-archive/debian/pool/main/a/atlas/$PI4_ATLAS_DEB_NAME"
PI4_ATLAS_DEB_SHA256="9ece788c7ccb2e13378c6179daf2f29d062b9c7e91e0b8cf8516eaf7bea7af2b"

PI4_NUMPY_RUNTIME_PATHS=(
 "usr/lib/python3/dist-packages/numpy"
 "usr/lib/python3/dist-packages/numpy-1.18.5.dist-info"
 "usr/lib/libatlas.so.3"
 "usr/lib/libblas.so.3"
 "usr/lib/libcblas.so.3"
 "usr/lib/libf77blas.so.3"
 "usr/lib/liblapack.so.3"
 "usr/lib/ATLAS-LICENSE.txt"
)

_pi4_numpy_runtime_die() {
 if declare -F die >/dev/null 2>&1; then
  die "$*"
 else
  echo "ERROR: $*" >&2
  return 1
 fi
}

_pi4_numpy_sha256() {
 local artifact="$1"
 if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$artifact" | awk '{print $1}'
 elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$artifact" | awk '{print $1}'
 else
  _pi4_numpy_runtime_die "A SHA-256 tool is required (sha256sum or shasum)"
 fi
}

_pi4_numpy_resolve_artifact() {
 local override="$1" url="$2" expected_sha="$3" artifact_name="$4"
 local helper_dir repo_root cache_dir artifact part actual_sha

 if [[ -n "$override" ]]; then
  [[ -f "$override" ]] || {
   _pi4_numpy_runtime_die "Pi 4 numerical artifact not found: $override"
   return 1
  }
  printf '%s\n' "$override"
  return 0
 fi

 helper_dir="$PI4_NUMPY_RUNTIME_HELPER_DIR"
 repo_root="$(cd "$helper_dir/../.." && pwd)"
 cache_dir="${PGEN_RUNTIME_CACHE_DIR:-$repo_root/build/runtime-cache}"
 artifact="$cache_dir/$artifact_name"
 if [[ -f "$artifact" ]]; then
  actual_sha="$(_pi4_numpy_sha256 "$artifact")" || return 1
  if [[ "$actual_sha" == "$expected_sha" ]]; then
   printf '%s\n' "$artifact"
   return 0
  fi
 fi

 command -v curl >/dev/null 2>&1 || {
  _pi4_numpy_runtime_die "curl is required to download the Pi 4 numerical runtime"
  return 1
 }
 mkdir -p "$cache_dir"
 part="$artifact.part"
 echo "[pi4-numpy] Downloading $artifact_name" >&2
 if ! curl --fail --location --retry 3 --output "$part" "$url"; then
  _pi4_numpy_runtime_die "Unable to download $url"
  return 1
 fi
 actual_sha="$(_pi4_numpy_sha256 "$part")" || return 1
 if [[ "$actual_sha" != "$expected_sha" ]]; then
  _pi4_numpy_runtime_die "Downloaded $artifact_name checksum mismatch: expected $expected_sha, got $actual_sha"
  return 1
 fi
 mv -f -- "$part" "$artifact"
 printf '%s\n' "$artifact"
}

_pi4_numpy_copy_selected_wheel_files() {
 local wheel_root="$1" destination_site="$2"
 local rel source destination

 [[ -f "$PI4_NUMPY_RUNTIME_FILE_LIST" ]] || {
  _pi4_numpy_runtime_die "Missing NumPy runtime file list: $PI4_NUMPY_RUNTIME_FILE_LIST"
  return 1
 }
 while IFS= read -r rel || [[ -n "$rel" ]]; do
  [[ -n "$rel" && "${rel#\#}" == "$rel" ]] || continue
  case "$rel" in
   /*|..|../*|*/../*|*/..)
    _pi4_numpy_runtime_die "Unsafe path in NumPy runtime file list: $rel"
    return 1
    ;;
  esac
  source="$wheel_root/$rel"
  [[ -f "$source" && ! -L "$source" ]] || {
   _pi4_numpy_runtime_die "Pinned NumPy wheel is missing runtime file: $rel"
   return 1
  }
  destination="$destination_site/$rel"
  mkdir -p "$(dirname "$destination")"
  install -m 0644 "$source" "$destination"
 done < "$PI4_NUMPY_RUNTIME_FILE_LIST"
}

hydrate_pi4_numpy_runtime() {
 local destination_root="$1"
 local wheel atlas_deb wheel_sha atlas_sha temp_root deb_root site_root rel pair source destination
 local atlas_files=(
  "usr/lib/atlas-base/libatlas.so.3.0:usr/lib/libatlas.so.3"
  "usr/lib/atlas-base/atlas/libblas.so.3.0:usr/lib/libblas.so.3"
  "usr/lib/atlas-base/libcblas.so.3.0:usr/lib/libcblas.so.3"
  "usr/lib/atlas-base/libf77blas.so.3.0:usr/lib/libf77blas.so.3"
  "usr/lib/atlas-base/atlas/liblapack.so.3.0:usr/lib/liblapack.so.3"
 )

 [[ -d "$destination_root" ]] || {
  _pi4_numpy_runtime_die "Pi 4 NumPy destination root does not exist: $destination_root"
  return 1
 }
 wheel="$(_pi4_numpy_resolve_artifact \
  "${PGEN_PI4_NUMPY_WHEEL:-}" "$PI4_NUMPY_WHEEL_URL" \
  "$PI4_NUMPY_WHEEL_SHA256" "$PI4_NUMPY_WHEEL_NAME")" || return 1
 atlas_deb="$(_pi4_numpy_resolve_artifact \
  "${PGEN_PI4_ATLAS_DEB:-}" "$PI4_ATLAS_DEB_URL" \
  "$PI4_ATLAS_DEB_SHA256" "$PI4_ATLAS_DEB_NAME")" || return 1
 wheel_sha="$(_pi4_numpy_sha256 "$wheel")" || return 1
 atlas_sha="$(_pi4_numpy_sha256 "$atlas_deb")" || return 1
 [[ "$wheel_sha" == "$PI4_NUMPY_WHEEL_SHA256" ]] || {
  _pi4_numpy_runtime_die "NumPy wheel checksum mismatch: expected $PI4_NUMPY_WHEEL_SHA256, got $wheel_sha"
  return 1
 }
 [[ "$atlas_sha" == "$PI4_ATLAS_DEB_SHA256" ]] || {
  _pi4_numpy_runtime_die "ATLAS package checksum mismatch: expected $PI4_ATLAS_DEB_SHA256, got $atlas_sha"
  return 1
 }

 temp_root="$(mktemp -d "${TMPDIR:-/tmp}/pgen-pi4-numpy.XXXXXX")"
 mkdir -p "$temp_root/wheel" "$temp_root/deb"
 if ! unzip -q "$wheel" -d "$temp_root/wheel"; then
  rm -rf -- "$temp_root"
  _pi4_numpy_runtime_die "Unable to extract the pinned NumPy wheel"
  return 1
 fi
 if ! (cd "$temp_root/deb" && ar x "$atlas_deb"); then
  rm -rf -- "$temp_root"
  _pi4_numpy_runtime_die "Unable to extract the pinned ATLAS Debian package"
  return 1
 fi
 [[ -f "$temp_root/deb/data.tar.xz" ]] || {
  rm -rf -- "$temp_root"
  _pi4_numpy_runtime_die "Pinned ATLAS package has no data.tar.xz payload"
  return 1
 }
 deb_root="$temp_root/deb/root"
 mkdir -p "$deb_root"
 if ! tar -xJf "$temp_root/deb/data.tar.xz" -C "$deb_root"; then
  rm -rf -- "$temp_root"
  _pi4_numpy_runtime_die "Unable to unpack the pinned ATLAS package payload"
  return 1
 fi

 for rel in "${PI4_NUMPY_RUNTIME_PATHS[@]}"; do
  rm -rf -- "$destination_root/$rel"
 done
 site_root="$destination_root/usr/lib/python3/dist-packages"
 mkdir -p "$site_root" "$destination_root/usr/lib"
 _pi4_numpy_copy_selected_wheel_files "$temp_root/wheel" "$site_root" || {
  rm -rf -- "$temp_root"
  return 1
 }
 for pair in "${atlas_files[@]}"; do
  source="$deb_root/${pair%%:*}"
  destination="$destination_root/${pair#*:}"
  [[ -f "$source" && ! -L "$source" ]] || {
   rm -rf -- "$temp_root"
   _pi4_numpy_runtime_die "Pinned ATLAS package is missing ${pair%%:*}"
   return 1
  }
  install -m 0644 "$source" "$destination"
 done
 install -m 0644 "$PI4_NUMPY_RUNTIME_HELPER_DIR/../../third_party/pi4-numpy-runtime/ATLAS-LICENSE.txt" \
  "$destination_root/usr/lib/ATLAS-LICENSE.txt"
 rm -rf -- "$temp_root"
 echo "[pi4-numpy] Staged verified NumPy 1.18.5 and ATLAS 3.10.2-7 runtime" >&2
}

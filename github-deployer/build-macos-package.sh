#!/bin/sh
set -eu

app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
build_dir=$(mktemp -d /tmp/pgen-macos-package.XXXXXX)
package_dir="$build_dir/PGenerator-GitHub-Deployer"
runtime_dir="$package_dir/runtime"
wheel_dir="$build_dir/wheels"
python_archive="$build_dir/python-macos.tar.gz"
output="$app_dir/PGenerator-GitHub-Deployer-macOS.zip"

cleanup() {
  rm -rf -- "$build_dir"
}
trap cleanup EXIT HUP INT TERM

verify_hash() {
  expected=$1
  path=$2
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "Checksum failed for $(basename "$path")" >&2
    exit 1
  fi
}

mkdir -p "$runtime_dir" "$wheel_dir" "$package_dir/static"

# Relocatable CPython for Apple Silicon from python-build-standalone. The
# tarball unpacks to python/ with bin/python3 inside; everything resolves
# relative to the binary, so the runtime runs from wherever the package is
# unzipped.
curl -fL --retry 3 \
  -o "$python_archive" \
  "https://github.com/astral-sh/python-build-standalone/releases/download/20260814/cpython-3.13.15%2B20260814-aarch64-apple-darwin-install_only_stripped.tar.gz"
verify_hash "6d472fc49a4d95e58214a992c4c92aa73fe2a935837a01a9a36bab0bec6d72f3" "$python_archive"
tar -xzf "$python_archive" -C "$runtime_dir"
site_packages="$runtime_dir/python/lib/python3.13/site-packages"
[ -d "$site_packages" ] || { echo "Unexpected runtime layout" >&2; exit 1; }

python3 -m pip download \
  --disable-pip-version-check \
  --dest "$wheel_dir" \
  --only-binary=:all: \
  --no-deps \
  --platform macosx_11_0_arm64 \
  --python-version 313 \
  --implementation cp \
  -r "$app_dir/requirements-macos.txt"

verify_hash "0c418ca99fd47e9c59a301744d63328f17798b5947b0f791e9af3c1c499c2d0a" "$wheel_dir/bcrypt-5.0.0-cp39-abi3-macosx_10_12_universal2.whl"
verify_hash "716ff8ec22f20b4d988b12884086bcef0fc99737043e503f7a3935a6be99b1ea" "$wheel_dir/cffi-2.1.0-cp313-cp313-macosx_11_0_arm64.whl"
verify_hash "966fe0e9c67490071f14c0d2b1cb2dfb3023c5ce39457343931415f08382f2db" "$wheel_dir/cryptography-49.0.0-cp311-abi3-macosx_11_0_arm64.whl"
verify_hash "f11327165e5cbb89b2ad1d88d3292b5113332c43b8553b494da435d6ec6f5053" "$wheel_dir/invoke-3.0.3-py3-none-any.whl"
verify_hash "b7044611c30140d9a75261653210e2002977b71a0497ff3ba0d98d7edbf62f7c" "$wheel_dir/paramiko-5.0.0-py3-none-any.whl"
verify_hash "b727414169a36b7d524c1c3e31839a521725078d7b2ff038656844266160a992" "$wheel_dir/pycparser-3.0-py3-none-any.whl"
verify_hash "c949ea47e4206af7c8f604b8278093b674f7c79ed0d4719cc836902bf4517465" "$wheel_dir/pynacl-1.6.2-cp38-abi3-macosx_10_10_universal2.whl"

for wheel in "$wheel_dir"/*.whl; do
  unzip -q "$wheel" -d "$site_packages"
done

# The dashboard needs a Python interpreter, the standard library, and the SSH
# wheels - not a development distribution. python3.13 is statically linked
# (no load command references libpython) and none of the wheels link it
# either, so the dylib, the headers, the GUI stack, and the bundled pip only
# add download weight. bin/python and bin/python3 are symlinks in the
# original tarball; keep them as symlinks and zip with --symlinks so they do
# not expand into three copies of a 17 MB binary.
runtime_python="$runtime_dir/python"
rm -rf "$runtime_python/include" "$runtime_python/share" \
  "$runtime_python/lib/pkgconfig" "$runtime_python/lib/libpython3.13.dylib" \
  "$runtime_python/lib/libtcl9.0.dylib" "$runtime_python/lib/libtcl9tk9.0.dylib" \
  "$runtime_python/lib/itcl4.3.8" "$runtime_python/lib/tcl9" \
  "$runtime_python/lib/tcl9.0" "$runtime_python/lib/tk9.0" \
  "$runtime_python/lib/thread3.0.6" \
  "$runtime_python/lib/python3.13/idlelib" \
  "$runtime_python/lib/python3.13/tkinter" \
  "$runtime_python/lib/python3.13/turtledemo" \
  "$runtime_python/lib/python3.13/turtle.py" \
  "$runtime_python/lib/python3.13/ensurepip" \
  "$runtime_python/lib/python3.13/pydoc_data" \
  "$runtime_python/lib/python3.13/venv" \
  "$runtime_python/lib/python3.13/test" \
  "$runtime_python/lib/python3.13/lib-dynload/_tkinter.cpython-313-darwin.so" \
  "$site_packages"/pip "$site_packages"/pip-*.dist-info \
  "$runtime_python/bin"/pip* "$runtime_python/bin"/idle* \
  "$runtime_python/bin"/pydoc* "$runtime_python/bin"/2to3* \
  "$runtime_python/bin/python3.13-config" "$runtime_python/bin/python3-config"
for link in python python3; do
  rm -f "$runtime_python/bin/$link"
  ln -s python3.13 "$runtime_python/bin/$link"
done

cp \
  "$app_dir/server.py" \
  "$app_dir/run-macos.command" \
  "$app_dir/kill-server-macos.command" \
  "$app_dir/README-MACOS.md" \
  "$app_dir/BUNDLED-RUNTIME.txt" \
  "$package_dir/"
cp \
  "$app_dir/static/index.html" \
  "$app_dir/static/app.js" \
  "$app_dir/static/style.css" \
  "$package_dir/static/"
chmod 755 "$package_dir/run-macos.command" "$package_dir/kill-server-macos.command"

rm -f -- "$output"
(
  cd "$build_dir"
  zip -q -r --symlinks "$output" PGenerator-GitHub-Deployer
)

echo "Created $output"
sha256sum "$output"

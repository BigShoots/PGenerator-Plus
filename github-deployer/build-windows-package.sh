#!/bin/sh
set -eu

app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
build_dir=$(mktemp -d /tmp/pgen-windows-package.XXXXXX)
package_dir="$build_dir/PGenerator-GitHub-Deployer"
runtime_dir="$package_dir/runtime"
site_packages="$runtime_dir/Lib/site-packages"
wheel_dir="$build_dir/wheels"
python_archive="$build_dir/python-embed.zip"
output="$app_dir/PGenerator-GitHub-Deployer-Windows.zip"

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

mkdir -p "$runtime_dir" "$site_packages" "$wheel_dir" "$package_dir/static"

curl -fL --retry 3 \
  -o "$python_archive" \
  "https://www.python.org/ftp/python/3.13.13/python-3.13.13-embed-amd64.zip"
verify_hash "8766a8775746235e23cf5aee5027ab1060bb981d93110577adcf3508aa0cbd55" "$python_archive"
unzip -q "$python_archive" -d "$runtime_dir"
cp "$app_dir/windows-runtime/python313._pth" "$runtime_dir/python313._pth"

python3 -m pip download \
  --disable-pip-version-check \
  --dest "$wheel_dir" \
  --only-binary=:all: \
  --no-deps \
  --platform win_amd64 \
  --python-version 313 \
  --implementation cp \
  --abi cp313 \
  -r "$app_dir/requirements-windows.txt"

verify_hash "64ee8434b0da054d830fa8e89e1c8bf30061d539044a39524ff7dec90481e5c2" "$wheel_dir/bcrypt-5.0.0-cp39-abi3-win_amd64.whl"
verify_hash "8e74a6135550c4748af665b1b1118b6aab33b1fc6a16f9aff630af107c3b4512" "$wheel_dir/cffi-2.1.0-cp313-cp313-win_amd64.whl"
verify_hash "e5dfc1e64de5677cec922ffa8da89c546d0415bf6efdf081842e5d44c84e1f0e" "$wheel_dir/cryptography-49.0.0-cp311-abi3-win_amd64.whl"
verify_hash "f11327165e5cbb89b2ad1d88d3292b5113332c43b8553b494da435d6ec6f5053" "$wheel_dir/invoke-3.0.3-py3-none-any.whl"
verify_hash "b7044611c30140d9a75261653210e2002977b71a0497ff3ba0d98d7edbf62f7c" "$wheel_dir/paramiko-5.0.0-py3-none-any.whl"
verify_hash "b727414169a36b7d524c1c3e31839a521725078d7b2ff038656844266160a992" "$wheel_dir/pycparser-3.0-py3-none-any.whl"
verify_hash "62985f233210dee6548c223301b6c25440852e13d59a8b81490203c3227c5ba0" "$wheel_dir/pynacl-1.6.2-cp38-abi3-win_amd64.whl"

for wheel in "$wheel_dir"/*.whl; do
  unzip -q "$wheel" -d "$site_packages"
done

cp \
  "$app_dir/server.py" \
  "$app_dir/run-windows.bat" \
  "$app_dir/kill-server-windows.bat" \
  "$app_dir/kill-server-windows.ps1" \
  "$app_dir/README-WINDOWS.md" \
  "$app_dir/BUNDLED-RUNTIME.txt" \
  "$package_dir/"
cp \
  "$app_dir/static/index.html" \
  "$app_dir/static/app.js" \
  "$app_dir/static/style.css" \
  "$package_dir/static/"

rm -f -- "$output"
(
  cd "$build_dir"
  zip -q -r "$output" PGenerator-GitHub-Deployer
)

echo "Created $output"
sha256sum "$output"

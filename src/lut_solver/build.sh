#!/bin/sh
# Cross-build the batched 3D LUT node solver for the appliance.
#
# The appliance has gcc but no assembler and no make, so it can never build
# this itself; zig is the only working route from this workstation. The result
# is static musl, so it carries no runtime dependency on the device's glibc.
#
#   ./build.sh          armhf -> usr/bin/pgen_lut_solve (the committed binary)
#   ./build.sh host     native -> build/pgen_lut_solve.host (parity tests on a Mac)
#
# The floating-point flags are load-bearing, not hygiene. fm_invert is a
# discrete-branch search and fm_nonadd_corr accumulates inverse-distance
# weights in a fixed order: a fused multiply-add in the Jacobian or a
# reassociated IDW sum changes which branch is taken and moves the answer by
# percent, not by an ulp. Never build this with -Ofast or -ffast-math.
set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
zig=${ZIG:-/opt/homebrew/bin/zig}
src="$here/pgen_lut_solve.c"

fpflags="-std=c99 -ffp-contract=off -fno-fast-math -fno-unsafe-math-optimizations"

sha256_of() {
 if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$1" | awk '{print $1}'
 elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$1" | awk '{print $1}'
 else
  echo "No shasum or sha256sum available to write the build manifest" >&2
  exit 1
 fi
}

if [ "$1" = "host" ]; then
 mkdir -p "$here/build"
 out="$here/build/pgen_lut_solve.host"
 tmp="$out.new.$$"
 # Never write over the artefact in place: a failed link would leave a
 # truncated file that still looks like a build product.
 "$zig" cc -O2 $fpflags -o "$tmp" "$src" -lm
 mv "$tmp" "$out"
 echo "$out"
 exit 0
fi

out="$root/usr/bin/pgen_lut_solve"
tmp="$out.new.$$"
# The armhf binary is COMMITTED, so a failed link writing straight over it
# would corrupt the working tree with something git happily records.
"$zig" cc -target arm-linux-musleabihf -mcpu=cortex_a72 -O2 -static -s \
 $fpflags -o "$tmp" "$src"
chmod 755 "$tmp"
mv "$tmp" "$out"

# Bind the committed binary to the source it was built from. Nothing else can:
# CI proves the SOURCE (it compiles a host build of pgen_lut_solve.c) while the
# appliance runs this binary, so editing the C and forgetting to rebuild leaves
# a green suite and a stale device. t/math_runtime_packaging.t re-hashes both
# files and fails when they drift apart. The build is reproducible, so a
# rebuild from unchanged source rewrites the same manifest.
manifest="$here/pgen_lut_solve.manifest"
{
 echo "# Written by src/lut_solver/build.sh. Do not edit by hand: rebuild."
 echo "$(sha256_of "$src")  src/lut_solver/pgen_lut_solve.c"
 echo "$(sha256_of "$out")  usr/bin/pgen_lut_solve"
} > "$manifest.new.$$"
mv "$manifest.new.$$" "$manifest"

file "$out" 2>/dev/null || true
echo "$out"
echo "$manifest"

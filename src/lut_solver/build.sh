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

if [ "$1" = "host" ]; then
 mkdir -p "$here/build"
 out="$here/build/pgen_lut_solve.host"
 "$zig" cc -O2 $fpflags -o "$out" "$src" -lm
 echo "$out"
 exit 0
fi

out="$root/usr/bin/pgen_lut_solve"
"$zig" cc -target arm-linux-musleabihf -mcpu=cortex_a72 -O2 -static -s \
 $fpflags -o "$out" "$src"
chmod 755 "$out"
file "$out" 2>/dev/null || true
echo "$out"

# NumPy runtime for the Raspberry Pi 4 image

PGenerator Plus still supports the Raspberry Pi 4 appliance image built on
Debian Jessie and CPython 3.5. The image cannot install a current NumPy wheel
at build or update time, so the compatible ARMv7 runtime needed by the ICC
workers is checked in here.

- Upstream package: NumPy 1.18.5
- Wheel: `numpy-1.18.5-cp35-cp35m-linux_armv7l.whl`
- Wheel source: `https://www.piwheels.org/simple/numpy/numpy-1.18.5-cp35-cp35m-linux_armv7l.whl`
- Wheel SHA-256: `d0a8cddf6be1f3b6aca25784076c0bc54ff2f4fd27e2048f76722aca13487794`
- Python ABI: CPython 3.5 (`cp35m`)
- Platform ABI: Linux ARMv7 hard-float
- Licence: BSD-3-Clause; see `numpy-1.18.5.dist-info/LICENSE.txt`

The vendored tree is a runtime subset. Upstream test suites, documentation, F2PY,
`distutils`, development headers, static libraries, and bytecode caches have
been removed. The companion ATLAS/BLAS/LAPACK shared libraries in `usr/lib`
come from the matching Debian Jessie ARMv7 packages. Their BSD licence notice
is in `usr/lib/ATLAS-LICENSE.txt`. The base appliance supplies
`libgfortran.so.3` and the normal C/C++ runtime.

Runtime library SHA-256 values:

- `libatlas.so.3`: `ed8198f78e0c037b02f4c4a6c95dec77eb6f3967fc88c2614f71079bf36e7d13`
- `libblas.so.3`: `aa5d5d925514ab1f8eb7925cbaead3c825a464960e08e536a1afb38b81e74355`
- `libcblas.so.3`: `3a561af16911be0245209781251088e08fd3839294baf4ed934c65068f5ff968`
- `libf77blas.so.3`: `815b8fe14f9eb7355a9184644ae9826f7fb7679fa92344b5c7e683a9b0a80f78`
- `liblapack.so.3`: `a3a0fee09f8b2ded31bfda6f53697400c97353f2f9da7fae53cd14d0b0b58ae4`

The Raspberry Pi 5 Bookworm image does not receive this old CPython 3.5 tree
or the Jessie numerical libraries. Its image build installs the distribution's
`python3-numpy` package instead; the image and OTA builders explicitly exclude
the Pi 4-only paths when assembling a Pi 5 target.

Rebuild or replace this runtime only with a wheel whose provenance, ABI,
licence, import test, and byte-for-byte ICC parity have all been recorded in
`MATH_SPEED.md`.

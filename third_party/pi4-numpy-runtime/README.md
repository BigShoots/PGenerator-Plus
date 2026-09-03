# NumPy runtime for the Raspberry Pi 4 image

PGenerator Plus still supports the Raspberry Pi 4 appliance image built on
Debian Jessie and CPython 3.5. The compatible ARMv7 runtime needed by the ICC
workers is reconstructed from two immutable upstream binary packages instead
of storing thousands of expanded binary files in Git. Both release builders
download them, verify their SHA-256 values, select only the known runtime
files, and stage those files into the finished image or OTA payload. Devices
never download them themselves.

- Build logic: `tools/runtime/pi4_numpy_runtime.sh`
- Runtime-only NumPy file list: `tools/runtime/pi4_numpy_runtime_files.txt`

- Upstream package: NumPy 1.18.5
- Wheel: `numpy-1.18.5-cp35-cp35m-linux_armv7l.whl`
- Wheel source: `https://www.piwheels.org/simple/numpy/numpy-1.18.5-cp35-cp35m-linux_armv7l.whl`
- Wheel SHA-256: `d0a8cddf6be1f3b6aca25784076c0bc54ff2f4fd27e2048f76722aca13487794`
- Python ABI: CPython 3.5 (`cp35m`)
- Platform ABI: Linux ARMv7 hard-float
- Licence: BSD-3-Clause; see `NUMPY-LICENSE.txt` here and
  `numpy-1.18.5.dist-info/LICENSE.txt` in the selected wheel files.

The numerical libraries come from Debian's archived
`libatlas3-base_3.10.2-7_armhf.deb` package:

- Package source: `https://archive.debian.org/debian-archive/debian/pool/main/a/atlas/libatlas3-base_3.10.2-7_armhf.deb`
- Package SHA-256: `9ece788c7ccb2e13378c6179daf2f29d062b9c7e91e0b8cf8516eaf7bea7af2b`

`ATLAS-LICENSE.txt` contains the copyright text from that exact Debian package.
The five staged libraries are byte-for-byte matches for files inside the same
package, rather than locally rebuilt or copied from an unknown appliance.

The staged wheel is a runtime subset. Upstream test suites, documentation, F2PY,
`distutils`, development headers, static libraries, and bytecode caches have
been removed. The companion ATLAS/BLAS/LAPACK shared libraries in `usr/lib`
come from the matching Debian Jessie ARMv7 packages. Their BSD licence notice
is retained here and copied to `usr/lib/ATLAS-LICENSE.txt` in the release. The base appliance supplies
`libgfortran.so.3` and the normal C/C++ runtime.

Runtime library SHA-256 values:

- `libatlas.so.3`: `ed8198f78e0c037b02f4c4a6c95dec77eb6f3967fc88c2614f71079bf36e7d13`
- `libblas.so.3`: `aa5d5d925514ab1f8eb7925cbaead3c825a464960e08e536a1afb38b81e74355`
- `libcblas.so.3`: `3a561af16911be0245209781251088e08fd3839294baf4ed934c65068f5ff968`
- `libf77blas.so.3`: `815b8fe14f9eb7355a9184644ae9826f7fb7679fa92344b5c7e683a9b0a80f78`
- `liblapack.so.3`: `a3a0fee09f8b2ded31bfda6f53697400c97353f2f9da7fae53cd14d0b0b58ae4`

The Raspberry Pi 5 Bookworm image does not receive this old CPython 3.5 tree
or the Jessie numerical libraries. Its image build installs the distribution's
`python3-numpy` package instead. The builders only fetch these legacy packages
for the Pi 4 target.

Change either pin or the runtime file list only after recording its provenance,
ABI, licence, import test, and byte-for-byte ICC parity in the same change.

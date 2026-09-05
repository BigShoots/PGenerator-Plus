# ofxRPI4Window for Raspberry Pi 5 (Raspberry Pi OS Bookworm, vc4 6.12)

The Pi 5 flavour of the KMS/DRM window addon used by `src/pattern_generator`.
`src/ofxRPI4Window` is the Pi 4 (BiasiLinux, kernel 5.10) flavour; the two
share the pattern-generator sources but differ in how they talk to the kernel:

- connector properties are `Colorspace` and `Broadcast RGB` (enum numbering
  differs from the conf: conf 1=Limited/2=Full, Broadcast RGB 1=Full/2=Limited),
  and the PGenerator `output format` property is DRM_MODE_PROP_ATOMIC, so it
  is written through the atomic API;
- HDR mastering metadata is read from `/etc/PGenerator/PGenerator.conf` on
  every wire-blob rebuild (same rule as the Pi 4: `updateHDR_Infoframe()` must
  keep the conf read and the populated DML/CLL/FALL fields);
- there is no `drm_override.so` on the Pi 5, so the renderer is the only
  thing that keeps connector properties correct across atomic commits;
- Dolby Vision uses the DOVI_OUTPUT_METADATA blob of the patched vc4 module
  (`vc4-*-dv-vsif.ko`); the optional `dv_vsif_h14b=1` conf key forces the
  H14b VSIF form.

Build natively on the Pi 5 against `/root/pgplus-build/openFrameworks` with
`tools/scripts/build_and_deploy_pi5_renderer.sh [--deploy]`, which syncs this
directory and `src/pattern_generator/src` to the board. Verified 2026-09-05
against the Pi 4 renderer on the same LG C2 in nine SDR/HDR10/Dolby Vision
output modes (see `calibration-captures/output-mode-parity/`).

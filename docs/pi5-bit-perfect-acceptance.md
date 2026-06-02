# Pi 5 Bit-Perfect Acceptance

Gate a Pi 5/BCM2712 image against the Pi 4 2.7.2 behavior before release.

## Runtime Gate

Run Phase 10 against the Pi 5 target:

```bash
PI=root@192.168.1.179 build/phase10_gate.sh
```

Keep the generated `/tmp/phase10_gate_*.log` as the acceptance artifact. The log must include:

- local hashes for `ofxRPI4Window.cpp`, `main.cpp`, `conf.pm`, `variables.pm`, `command.pm`, and `phase10_gate.sh`
- remote hashes for `/usr/sbin/PGeneratord`, `/usr/sbin/PGeneratord.dv`, and the build-tree `pattern_generator`
- `/proc/device-tree/model` showing the Pi 5/BCM2712 target
- RGB and YCbCr API config snapshots plus `/api/infoframes`
- dynamic DRM connector and active non-cursor plane state from `/sys/kernel/debug/dri/*/state`
- meter reads for RGB red/green/blue/white and YCbCr red/green/blue/white/black/gray50

## Pass Criteria

- The renderer uses the `ofxRPI4Window` KMS path on Pi 5/BCM2712, not the generic `ofSetupOpenGL` fullscreen path.
- `/api/infoframes` and DRM connector state agree with the selected RGB/YCbCr format, quantization range, colorimetry/colorspace, and max bpc.
- RGB regression probes match the Pi 4 baseline for red, green, blue, and white within the existing meter tolerance.
- YCbCr444 probes match the Pi 4 baseline for red, green, blue, white, black, and gray50 within the existing meter tolerance.
- No gray50 or greyscale-range regression appears after switching YCbCr back to RGB.

## Follow-Up Artifacts

For any failure, capture the same phase17-style artifacts already present under `docs/phase17_pink_diag_*`: config JSON, infoframes JSON, operations.txt, active plane state, HVS display lists, and meter JSON for RGB, YCbCr444, and YCbCr422.

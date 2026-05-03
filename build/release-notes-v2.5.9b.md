## PGenerator+ 2.5.9b Beta

### Overview

- Beta refresh focused on meter workflow stability, correct SDR source/transport range handling, consistent greyscale target behavior, improved RGB monitor startup, and avoiding false Web UI offline states during long manual reads.
- This refreshed `v2.5.9b` image replaces the previously uploaded `v2.5.9b` assets without changing the version number.
- Rebuilt from the validated `2.5.8b` full image with the current `2.5.9b` PGenerator+ overlay. The shipped image continues to include the patched `5.10.89+-7l` `vc4.ko` carried forward from that validated base image.

### Added

- Added separate meter patch-range and transport-range plumbing across the Web UI, manual session helper, and series helper so SDR greyscale full-source overrides no longer steal HDMI range ownership.
- Added a delayed RGB DRM property reapply during renderer startup to improve monitor-class RGB sink startup without requiring a manual YCbCr toggle.
- Added explicit busy tracking for manual read-once flows so the Web UI can distinguish a blocked single-threaded daemon from a truly offline device.

### Fixed

- Fixed meter workflow regressions so Read Once, Continuous, and Series all honor the same per-reading meter delay with a persistent 0.5 s default.
- Fixed spectro/manual startup handling so white-reference and awaiting-ready prompts surface cleanly, series clears reset more reliably, and manual reads recover with clearer state transitions.
- Fixed SDR greyscale source/transport range handling so limited transport and full-source patch generation stay correctly separated instead of flipping HDMI range unexpectedly.
- Fixed SDR BT.1886 greyscale target consistency so 11-point, 21-point, and 0-100 greyscale charts share the same nominal gamma target line.
- Fixed meter settings UI regressions in the Web UI, including tighter display-type layout and more reliable persistence of meter delay/settings across restarts.
- Fixed false `Device Offline` overlays during long manual reads when the single-threaded daemon was busy but still healthy.
- Fixed cached non-greyscale series restores so Sat Sweep and Colors reopen with the correct chart set instead of falling back to Greyscale 21pt on browsers with persisted local series cache.
- Fixed continuous meter reads so they no longer get swallowed by the manual read debounce path, and added retry backoff after failed iterations instead of hammering the backend.
- Fixed meter-status polling during active reads so the Web UI reuses the last known detection while the meter session is already busy instead of spawning extra `spotread_wrapper.sh --detect` probes.
- Fixed long-run continuous-read overhead in `meter_session.sh` by parsing only newly appended `spotread` output instead of rescanning the full session transcript on every read.
- Bumped the shipped image/runtime version from `2.5.8b` to `2.5.9b`.

### Downloads

- `PGenerator_Plus_v2.5.9b.img.7z.001` + `.002` - full SD card image built from the validated `v2.5.8b` base image with the current `2.5.9b` overlay; the resulting image retains the patched `5.10.89+-7l` `vc4.ko` from that validated base.
- `PGenerator_Plus_v2.5.9b.img.sha256` - SHA-256 checksum for the extracted full image.
- `PGenerator_Plus_v2.5.9b.img.7z.sha256` - SHA-256 checksums for the split archive parts.
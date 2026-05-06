## PGenerator+ 2.6.1b

### Overview

- Beta update focused on LG display calibration workflows, diagnostic pattern playback, meter/chart stability, and smoother Web UI operation during active reads and TV control.
- Rebuilt from the released `2.5.10b` full image with the current `2.6.1b` PGenerator+ overlay. The shipped image continues to include the patched `5.10.89+-7l` `vc4.ko` carried forward from that base image.

### Added

- Added LG WebOS display controls with first-time PIN pairing, saved-key reconnects, TV discovery, picture mode selection, and calibration-mode control.
- Added LG-aware greyscale calibration controls, including an LG-specific greyscale series, vertical RGB adjustment bars, direct numeric RGB entry, and finer manual adjustment steps.
- Added generation-aware LG control behavior so supported LG models can use the appropriate picture and calibration commands automatically.
- Added bundled AVS HD 709 SDR diagnostic frame sequences for black clipping, APL clipping, white clipping, flashing color bars, and sharpness/overscan checks.
- Added bundled ARM static FFmpeg support plus framebuffer and DRM video player helpers for diagnostic playback on compatible images.

### Fixed

- Fixed LG greyscale patch mapping so the displayed patch and LG white-balance adjustment target stay aligned, including limited-range SDR workflows.
- Fixed repeated LG pairing prompts and improved saved pairing recovery so reconnecting does not require another PIN when the stored key is valid.
- Fixed Web UI connection handling during long-running meter reads and LG writes so busy operations do not look like random page disconnects.
- Fixed continuous-read startup retry behavior so the first continuous read after restart is more reliable.
- Fixed chart/cache behavior so manual reads, series reads, 0%/100% contrast handling, gamma tracking, and stale series restores stay consistent after refreshes.
- Fixed diagnostic pattern layout and custom media controls so AVS HD 709 video patterns, image patterns, uploaded video playback, and uploaded image playback are easier to control.
- Fixed the full-image build helper's optional Argyll permission pass so `set -u` does not abort builds without an external Argyll runtime directory.
- Bumped the shipped image/runtime version from `2.5.10b` to `2.6.1b`.

### Downloads

- `PGenerator_Plus_v2.6.1b.img.7z.001` + `.002` - full SD card image built from the released `v2.5.10b` base image with the current `2.6.1b` overlay; the resulting image retains the patched `5.10.89+-7l` `vc4.ko` from that base.
- `PGenerator_Plus_v2.6.1b.img.sha256` - SHA-256 checksum for the extracted full image.
- `PGenerator_Plus_v2.6.1b.img.7z.sha256` - SHA-256 checksums for the split archive parts.

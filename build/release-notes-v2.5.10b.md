## PGenerator+ 2.5.10b Beta

### Overview

- Beta refresh focused on meter workflow ergonomics, including a configurable Greyscale 2pt series, cleaner series grouping, a dedicated two-point results view, and improved thumbnail navigation on smaller screens.
- Rebuilt from the released `2.5.9b` full image with the current `2.5.10b` PGenerator+ overlay. The shipped image continues to include the patched `5.10.89+-7l` `vc4.ko` carried forward from that base image.

### Added

- Added a dedicated Greyscale 2pt series with configurable low and high patch values plus saved defaults in Meter & Measurements.
- Added top-level Greyscale and Color tabs so Greyscale 2pt, 11pt, 21pt, 101pt, ColorChecker, and Sat Sweep are grouped more cleanly.
- Added a dedicated two-point results view with separate low/high RGB balance cards and a high-luminance readout.
- Added thumbnail paging controls and improved overflow behavior for long series on mobile and narrower browser layouts.

### Fixed

- Fixed two-point greyscale settings persistence so custom low/high patch values survive shared meter-settings saves and page reloads.
- Fixed two-point greyscale white-reference handling so RGB balance stays meaningful even when the high patch is below a literal 100% white read.
- Fixed cached series recovery so saved two-point greyscale runs reopen with the correct chart mode instead of falling back to the full greyscale chart stack.
- Fixed meter-series startup copy so the UI reports `Connecting to meter...` during initialization and retry phases.
- Fixed the full-image build helper so it falls back to a sequential `dd` copy when `cp` fails reading a sparse-hostile base image with `cannot lseek`.
- Bumped the shipped image/runtime version from `2.5.9b` to `2.5.10b`.

### Downloads

- `PGenerator_Plus_v2.5.10b.img.7z.001` + `.002` - full SD card image built from the released `v2.5.9b` base image with the current `2.5.10b` overlay; the resulting image retains the patched `5.10.89+-7l` `vc4.ko` from that base.
- `PGenerator_Plus_v2.5.10b.img.sha256` - SHA-256 checksum for the extracted full image.
- `PGenerator_Plus_v2.5.10b.img.7z.sha256` - SHA-256 checksums for the split archive parts.
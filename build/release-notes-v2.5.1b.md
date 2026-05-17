## PGenerator+ 2.5.1b Beta

### Overview

- Beta release for the new spectro-driven CCSS workflow and related Web UI/runtime fixes.
- Targets feature request #6: Add ability to create CCSS profile using spectrophotometer.

### Added

- Added on-device custom CCSS creation from a connected spectrophotometer.
- Added CCSS export/download options for CCSS, CSV, and EDR.
- Added CSV import/export round-trip support for raw spectral CSV files and CCSS conversion.
- Added a visible `Delete Profile` action for selected custom CCSS entries.
- Added a `Device Ready` button for spectro-driven meter series reads so users can position the device before each measurement step.

### Fixed

- Fixed the reported monitor startup case where the screen could remain on the logo in RGB mode even though the Web UI reported that a pattern was sent; the renderer now reapplies HDMI DRM properties after startup so RGB output does not depend on toggling through YCbCr first.
- Fixed CSV export so files created from imported raw spectral CSV data export back in the expected row-based spectral layout.
- Fixed CSV import so the same raw 3-row and 4-row spectral CSV formats can be converted back into CCSS.
- Fixed modal behavior so blocking popups no longer allow the page behind them to keep scrolling.

### Notes

- This is a beta prerelease intended for manual testing, especially of the new spectro and custom-profile workflow.
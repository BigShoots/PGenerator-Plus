## PGenerator+ 2.4.1

### Web UI & Workflow Changes

- Restored missing meter controls and workflows around XYZ matrix handling, P3 DCI targeting, custom target white handling, and related meter-session stability work.
- Added persistent meter settings so display type, settle delay, patch size, insertion, refresh rate, AIO mode, and CCSS selection survive reboot.
- Improved CCSS handling and meter-session startup/readiness behavior to reduce stuck meter initialization cases and keep custom-profile measurements aligned.
- Fixed multiple meter UI regressions across continuous reads, series attribution, patch switching, background APL behavior, live status latching, and export-row recovery after chart resets.
- Fixed external-client pattern handling so source-range metadata stays with the feeder path instead of being double-scaled by the Web UI range setting.
- Added a confirmation dialog before leaving a running series read so switching series no longer cancels an active read without warning.
- Tightened output-mode guards in the UI and backend so YCbCr 4:2:2 paths stay aligned with the supported 10-bit workflow.

### Signal Handling & Runtime

- Fixed the YCbCr rendering path by mapping plane `COLOR_ENCODING` from the selected colorimetry and shipping the current Pi-tested renderer binary as both `PGeneratord` and `PGeneratord.dv`.
- Kept the shipped renderer pair synchronized again, matching the release manifest expectations and avoiding mixed-binary runtime states.
- Improved patch-switch safety and reduced false offline state during active meter reads.

### OTA & Release Reliability

- Built and validated a fresh cumulative OTA overlay as `pgenerator-plus-2.4.1.tar.gz`.
- Simulated a `2.3.1` to `2.4.1` OTA update offline and verified the updated renderer payload, executable bits, and sudoers permissions after extraction.

### Issue Fixes

- Fixes #2 by preserving external client range ownership so limited-range feeder patterns are no longer double-scaled by the Web UI setting.
- Fixes #3 by restoring export controls after chart clears and clearing stale pattern-selection highlights during screen updates.
- Fixes #4 by persisting meter settings across reboot.
- Fixes #5 and #9 through the improved meter-session startup and CCSS handling shipped in this release.
- Fixes #7 and #11 through the YCbCr and custom-target workflow fixes shipped in this release.
- Fixes the running-series cancellation regression by requiring confirmation before abandoning an active series read.

### Downloads

- `pgenerator-plus-2.4.1.tar.gz` - cumulative OTA overlay for direct update to `2.4.1`
- `PGenerator_Plus_v2.4.1.img.7z.001` + `.002` - full SD card image built from the `v2.3.1` base image with the current `2.4.1` overlay

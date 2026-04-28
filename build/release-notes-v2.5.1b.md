## PGenerator+ 2.5.1b Beta

### Beta Scope

- Beta release for the new spectro profiling, CCSS import/export, CSV round-trip, EDR export, and related Web UI workflow changes.
- Built from the `2.4.1` full image as the base image with the current repository overlay applied.
- Includes the runtime files updated on 2026-04-27, including the refreshed Argyll helper binaries and the Web UI changes.

### Publishing Rules

- Publish this version on GitHub as a prerelease.
- Do not publish this version as the latest release.
- Do not attach an OTA tarball for this beta release.
- Attach only the full image assets and checksum files for manual installation/testing.

### Why This Stays Out Of OTA

- Device OTA uses GitHub's `releases/latest` endpoint.
- GitHub excludes prereleases from `releases/latest`, so marking `v2.5.1b` as a prerelease keeps OTA pinned to the latest stable release.
- Keeping the beta image-only avoids accidental OTA targeting even if release assets are browsed manually.
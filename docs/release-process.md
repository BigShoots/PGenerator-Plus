# PGenerator+ Release Process

This document captures the repeatable release flow used for the current 2.2.x builds.

## 1. Prepare the source tree

1. Update the version in `usr/share/PGenerator/version.pm`.
2. Refresh the top release summary in `README.md`.
3. Make sure the runtime defaults are correct before shipping:
   - default boot profile should be SDR / 1080p / RGB / 8-bit
   - GPU memory default should be the intended release value
   - no stale meter or chart session data should be left in the image
4. Review `git status` so only intended changes are included.

## 2. Verify before building

Run the core checks from the repo root:

```bash
perl -c usr/share/PGenerator/webui.pm
perl -c usr/share/PGenerator/command.pm
node tests/color-math-regression.js
```

If any of these fail, fix them before creating release assets.

## 3. Build the OTA update archive

The OTA updater expects a `.tar.gz` asset containing the runtime filesystem overlay.

Example:

```bash
mkdir -p build
VERSION=2.2.2

tar czf "build/pgenerator-plus-${VERSION}.tar.gz" \
  etc \
  usr \
  var \
  lib
```

Sanity-check the archive:

```bash
tar tzf "build/pgenerator-plus-${VERSION}.tar.gz" | head
```

## 4. Build the full image

Use the previous known-good image as the base and overlay the current repo onto it.

Example using the 2.2.1 image as the base for 2.2.2:

```bash
sudo ./tools/build_pgenerator_plus_image.sh \
  --base-image ./build/PGenerator_Plus_v2.2.1.img \
  --output ./build/PGenerator_Plus_v2.2.2.img \
  --force
```

The build script already resets transient runtime state so the output image is clean.

## 5. Split the image into a two-part 7z package

Use a 2000 MB split so GitHub handles the upload cleanly:

```bash
7z a -v2000m -mx=1 \
  "build/PGenerator_Plus_v2.2.2.img.7z" \
  "build/PGenerator_Plus_v2.2.2.img"
```

This produces:

- `build/PGenerator_Plus_v2.2.2.img.7z.001`
- `build/PGenerator_Plus_v2.2.2.img.7z.002`

## 6. Verify the assets

Check that the files exist and look reasonable:

```bash
ls -lh build/PGenerator_Plus_v2.2.2.img \
      build/PGenerator_Plus_v2.2.2.img.7z.001 \
      build/PGenerator_Plus_v2.2.2.img.7z.002 \
      build/pgenerator-plus-2.2.2.tar.gz
```

## 7. Commit and tag the release

```bash
git add usr/share/PGenerator/version.pm README.md docs/release-process.md usr/share/PGenerator/webui.pm usr/share/PGenerator/command.pm tests
git commit -m "Release 2.2.2"
git tag -a v2.2.2 -m "PGenerator+ v2.2.2"
```

## 8. Publish the GitHub release

Use the same notes layout as the recent releases:

- heading: `What's New in vX.Y.Z`
- grouped sections such as:
  - Meter & Measurement Suite
  - Network & Device Integration
  - Fixes & Compatibility
  - Downloads

Example flow:

```bash
gh release create v2.2.2 \
  build/PGenerator_Plus_v2.2.2.img.7z.001 \
  build/PGenerator_Plus_v2.2.2.img.7z.002 \
  build/pgenerator-plus-2.2.2.tar.gz \
  --title "PGenerator+ v2.2.2" \
  --notes-file /path/to/release-notes.md
```

## 9. Push commit and tag

```bash
git push origin main
git push origin v2.2.2
```

## 10. Final release checklist

Before marking the release complete, verify:

- the version shown in the WebUI matches the tag
- the OTA `.tar.gz` is attached to the GitHub release
- both split image parts are attached
- the image was built from a clean base and contains no stale read/session data
- the release notes match the current changes

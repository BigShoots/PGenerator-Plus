# Plan: Confirm YCbCr444 HDMI CSC double-conversion before any kernel patch

## Decision (from user)
1. Run **Option D** first: change `rgb_quant_range=2` (Full) in `/etc/PGenerator/PGenerator.conf`, restart PGenerator, and re-read the 5%/10% HDR greyscale patches. This is a single-knob, no-source-edit test.
2. If the lift changes, the kernel HDMI CSC is confirmed as the dominant cause and Option A (kernel patch, YCRCB444 only) becomes the next step.
3. If the lift does not change, the residual cause is elsewhere and we should not touch the kernel patch.
4. Scope of any future Option A: YCRCB444 branch only. YCRCB422 left untouched.

## Option D — test procedure

### Prereqs
- Pi4 idle (no active calibration / meter read / pattern run), per AGENTS.md.
- The user just lowered `min_luma` from 0.005 to 0 and did a read that still lifted. So we are starting from that state.

### Steps
1. SSH to the Pi4 as root.
2. Verify there is no active render / calibration / meter session:
   `pgrep -af "PGeneratord|meter_|spotread" || true`
   - If anything is running, stop here and wait.
3. Back up the current conf:
   `ts=$(date +%Y%m%d-%H%M%S); cp -a /etc/PGenerator/PGenerator.conf /root/pgen-backups/$ts/`
4. Edit `/etc/PGenerator/PGenerator.conf` and change exactly one line:
   `rgb_quant_range=2`
   (was `rgb_quant_range=1`)
5. Restart PGenerator:
   `/etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &`
6. Wait ~4s, verify it is up:
   `ps -ef | grep -E "[P]Generatord.pl|[P]Generator_serial"`
7. Capture the live HDMI state for the record:
   - `modetest -c -p 2>/dev/null | grep -E "Colorimetry|Colorspace|output format|max bpc|rgb quant range|HDR_OUTPUT" -A 1 | head -40`
   - Parse the `HDR_OUTPUT_METADATA` blob to confirm min_luma is still 0, max_luma still 1000, MaxCLL still 1000, MaxFALL still 400.
8. User runs a new HDR greyscale read in the WebUI (or PGenerator-native series) at the 5%, 10%, 15%, 20% stimulus points.

### What to look for in the read

| Outcome at 5% Y and 10% Y | Interpretation |
|---|---|
| Lift grows / measurements saturate (e.g. 5% Y jumps to >0.2 cd/m²) | Confirmed: the kernel's "full RGB -> full YUV" matrix is the dominant cause. Go to Option A. |
| Lift disappears or drops substantially toward 0.0606 / 0.3285 cd/m² | Same as above — CSC range interaction is the main bug. Go to Option A. |
| Lift is unchanged from the current read | The CSC is not the dominant cause. Do not patch the kernel. The residual cause is elsewhere (BT.709 vs BT.2020 chromaticity in grayscale is near-zero, so this would suggest something like the metadata `max_cll=1000, max_fall=400` still steers the LG to a different sub-mode, or a renderer-side encode issue). |

### Revert step
If we need to undo Option D (whether the result is "worse" or "no change and we want to test something else"), restore the conf from the backup:
`cp -a /root/pgen-backups/<ts>/PGenerator.conf /etc/PGenerator/PGenerator.conf && /etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &`

## Option D — result (2026-06-09)

Meter reads with i1Display Pro Plus on the live Pi4 (`rgb_quant_range` flipped 1 → 2, single-knob test):

| Stimulus | cd/m² (Full, `rgb_quant_range=2`) | cd/m² (Limited, `rgb_quant_range=1`) |
|---|---|---|
| 5%  | **0.0000** | 0.1282 |
| 10% | 0.1125 | 0.4406 |
| 15% | 0.4531 | 1.1066 |
| 20% | 1.2991 | 2.6582 |

Lift changes by 0.13–1.36 cd/m² across 5–20% when range is flipped. **5% Full sits at the panel black floor.** The hypothesis that the kernel CSC is range-scaling Limited-range input through a full-range matrix is consistent with the observation at the Y/luma level, BUT it turns out the kernel CSC is **not the source** — see Option A status below.

## Option A — reclassified: not needed at the kernel level

While preparing to implement Option A, the agent cross-checked the deployed `vc4.ko` against the tracked `drm_vc4.patch` and discovered:

1. **The running Pi4 `vc4.ko` is not the upstream Bookworm `vc4.ko`.** It is a heavily customized module that has already been built from a different source tree (`build/vc4-kernel-build-env/linux-5.10.89+-7l/drivers/gpu/drm/vc4/`). The MD5 of that workspace's compiled `vc4.ko` (`6383a9b7c5982081771277244a58a362`) matches the running Pi4's `/lib/modules/5.10.89+-7l/kernel/drivers/gpu/drm/vc4/vc4.ko` exactly. The Pi4 also has a `vc4.ko.orig` (MD5 `aad806b5…`) kept as a fallback.

2. **The running `vc5_hdmi_csc_setup` (line 1381 of the live source tree) already uses `vc5_hdmi_csc_full_rgb_unity` for the YUV444 case.** The complex BT.709 / BT.2020 / 8-bit / 10-bit / range-aware matrix switcher is present in the source at lines 1400-1428 but is **commented out** (`/* ... */`). The only YUV matrices compiled into the deployed `.ko` are `vc5_hdmi_csc_full_rgb_unity`, `vc5_hdmi_csc_full_rgb_to_limited_rgb_8bit`, and `vc5_hdmi_csc_full_rgb_to_limited_rgb_10bit`. Strings of the running `.ko` confirm: no `vc5_hdmi_csc_full_rgb_to_full_yuv444_*` symbols are present.

3. **The BT.709 matrix in `tools/image-targets/pi4-biasi/src/ofxRPI4Window/drm_vc4.patch` is a stale/orphaned patch.** It represents an earlier version of `vc5_hdmi_csc_setup` that was never deployed. The patch was never applied to the running kernel — the deployed kernel was built from a different, more recent source tree. The `drm_vc4.patch` file should be marked as historical, not authoritative.

4. **The original PGenerator 1.6 image (`PGenerator_original/RPI_img_extracted/`) shipped a stock `vc4.ko` for kernels `5.10.89+` and `5.10.89+-7`** (no `-l` variant). Those stock modules had only RGB-related matrices in their strings and no BT.709 or BT.2020 RGB→YUV matrix. The 1.6 binary strings show the same `rgb2ycbcr_shader` GLSL and the same `RGBtoYCbCr` packing logic that PGenerator+ has today. The YCbCr pre-packing path is **not something we introduced in PGenerator+**; it was always there.

### Conclusion on Option A
The kernel-side fix described in the plan is **already deployed**. The active YUV444 case on the live Pi4 is a true 3×4 identity matrix. No kernel patch, no kernel rebuild, no module redeploy is needed for the YUV444 case.

The lift the user is still seeing at Limited range is therefore **not** the kernel CSC. The kernel is already passing pixels through unchanged for YUV444. The remaining lift must come from one of:

- The `rgb_quant_range` interaction with the panel's HDMI receiver (LG might apply different tone-mapping / black-floor handling when the AVI infoframe says Limited).
- The renderer's own packing math (the `c_enc`/`c_range` fields in the AVI infoframe that the renderer writes) interacting with the LG's colorimetry expectations.
- The MaxFALL/MaxCLL HDR metadata: note that the deployed blob had MaxFALL=243 even though `max_fall=0` was in the conf — the renderer's metadata writer is overriding conf when it thinks "unset" means "default" (243 is not 0).

These are renderer / conf / metadata issues, not kernel CSC issues. Patching the in-repo `drm_vc4.patch` would not affect the running Pi4 and would not fix the residual lift at Limited range.

## Recommended next step

1. **Do not implement Option A** as described in the plan. The kernel CSC is already an identity for YUV444 on the running Pi4. Patching `drm_vc4.patch` would have no runtime effect.
2. **Update `drm_vc4.patch` to match the deployed reality** (purely as documentation: replace the stale BT.709 matrix block with the deployed identity-matrix code) and mark it as "historical / not authoritative" in a comment. This is a repo-only change, no deploy.
3. **Investigate the renderer / metadata path** for the residual Limited-range lift. Three plausible candidates to test in this order, all single-knob / single-conf changes:
   - a. Set `max_fall=0; max_cll=0` in the conf and force the renderer to actually emit MaxFALL=0/MaxCLL=0 on the wire (the deployed conf already says 0,0 but the wire blob had MaxFALL=243 — fix the renderer or work around with `pgsethdr`).
   - b. Set `rgb_quant_range=2` (Full) as the new default and accept the lift-free behaviour. This is what the user already has running.
   - c. Investigate why the LG is treating Limited-range YCbCr differently from Full-range YCbCr at the panel side (could be an LG BFI/frame-dimming interaction with the LG's "Dynamic Contrast" or "Energy Saving" picture mode toggled on).

### Files to change (Option A, scope = YCRCB444 only)
- `tools/image-targets/pi4-biasi/src/ofxRPI4Window/drm_vc4.patch`
  - In `vc5_hdmi_csc_setup()`, change the `case DRM_COLOR_FORMAT_YCRCB444:` branch to load the identity matrix instead of `vc5_hdmi_csc_full_rgb_to_full_yuv444_bt709`.
  - Reuse the existing `vc5_hdmi_csc_full_rgb_unity` (3×4 in s2.13 fixed point) defined a few lines above the YCRCB444 case, with `0x2000` on the diagonal and `0` elsewhere.
  - Do not set `VC5_MT_CP_CSC_CTL_FILTER_MODE_444_TO_422` or `VC5_MT_CP_CSC_CTL_USE_444_TO_422` in this branch (those belong to 422 subsampling).
  - Leave the `csc_ctl` ENABLE and MODE_CUSTOM bits set (so the hardware is still actively passing pixels through a matrix, just an identity one). If Option A's "set ENABLE=0" alternative is chosen, this changes.
  - Leave the `YCRCB422` and `RGB444` cases untouched.
- New regression test: `tests/vc4-hdmi-csc-identity-regression.pl`
  - Assert the YCRCB444 branch in the patch references the unity matrix.
  - Assert the YCRCB444 branch does not set 444->422 filter bits.
  - Assert the YCRCB422 branch still references `vc5_hdmi_csc_full_rgb_to_full_yuv422_bt709` (regression guard).

### Files to NOT change (Option A)
- `usr/share/PGenerator/command.pm` (already correct after the previous turn).
- `usr/lib/drm_override.c` (already correct after the previous turn).
- Renderer source `src/ofxRPI4Window/src/ofxRPI4Window.cpp` and the Pi4 image copy — no change needed; the app's YCbCr-packing path is correct for grayscale.
- `pgsethdr` / `pgsethdr` defaults — the user already set min_luma=0; MaxCLL/MaxFALL is a separate axis of investigation and not the focus here.

### Deployment caveat (Option A, known risk)
The deployed Pi4 is running the Bookworm `linux-image-rpi-v8` Debian package. The patch in this repo is not applied to that running kernel. To actually exercise the change, the user will need to either:
- Build a custom kernel package with the modified patch, or
- Stage the patch in the repo for a future kernel build, and document the apply step.

The plan does not include a kernel rebuild recipe in this turn. That would be a follow-up task if Option D confirms the hypothesis and the user wants the fix live.

## Open question

After Option D, if the lift is unchanged, the next hypothesis to test is the `max_cll=1000, max_fall=400` vs `0/0` metadata difference, which the user can also test with a single-conf change (`max_cll=0; max_fall=0`) before doing any source edits. That step is deliberately NOT in this plan; it will be planned separately if Option D comes back negative.

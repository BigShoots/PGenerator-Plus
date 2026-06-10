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

## Empirical data from 6 new Calman screenshots (2026-06-09)

User provided 6 screenshots taken during a single Calman HDR AutoCal session on the LG C2, hdrCinema picture mode:

- 2× "Calman HDR autocal During Cal with IPTG.png" — mid-cal, ITPG pattern source (screen grab shows Calman driving the TV's internal pattern generator)
- 2× "Calman HDR autocal post Cal with IPTG.png" — post-cal grayscale read, ITPG pattern source
- 2× "Calman HDR autocal post Cal with pgen.png" — post-cal grayscale read, PGenerator external pattern source

The picture mode is the same (hdrCinema) and the TV's calibration state is the same (both post-cal reads are on the same calibrated TV). Only the pattern source differs. This is exactly the controlled comparison the T1 plan described.

### Extracted numbers (post-cal hdrCinema, stimulus 0–50%)

| Stim (%) | Target cd/m² | ITPG cd/m² | PGen cd/m² | PGen − ITPG | PGen/ITPG | ITPG/Target | PGen/Target |
|---|---|---|---|---|---|---|---|
| 0 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | — | — | — |
| 5 | 0.0606 | **0.0909** | 0.0584 | **−0.0325** | **0.64** | **+50%** | −4% |
| 10 | 0.3285 | 0.3451 | 0.2997 | −0.0454 | 0.87 | +5% | −9% |
| 15 | 1.0146 | 1.0218 | 0.9664 | −0.0554 | 0.95 | +1% | −5% |
| 20 | 2.4653 | 2.5206 | 2.3801 | −0.1405 | 0.94 | +2% | −3% |
| 25 | 5.2375 | 5.4254 | 4.9653 | −0.4601 | 0.92 | +4% | −5% |
| 30 | 10.2138 | 10.5956 | 10.1435 | −0.4521 | 0.96 | +4% | −1% |
| 35 | 18.7807 | 18.8099 | 17.6813 | −1.1286 | 0.94 | 0% | −6% |
| 40 | 33.1037 | 32.5939 | 31.3152 | −1.2787 | 0.96 | −2% | −5% |
| 45 | 56.5543 | 56.5819 | 54.2870 | −2.2949 | 0.96 | 0% | −4% |
| 50 | 94.3784 | 93.7774 | 89.7693 | −4.0081 | 0.96 | −1% | −5% |

### Reading of the data

**PGenerator reads consistently lower than ITPG at every stimulus (0.0325–4.01 cd/m² gap, widening with stimulus).** Critically, the ratio PGen/ITPG is ~0.94–0.96 across the entire range — a roughly constant ~5% offset, with the exception of 5% where the ratio drops to 0.64 (PGen is 36% lower than ITPG at 5% specifically).

**Both sources disagree with the target, in opposite directions:**

- **ITPG reads slightly above target** at the low end (5% is +50% over, 10% is +5% over). This is the "lifted blacks" the user has been chasing. The TV's tone mapper is pushing near-black stimuli brighter than the code value should produce, on the ITPG signal path. The TV then calibrates against this lifted luminance, and when the post-cal ITPG read uses the same path, the lift is reproduced and measured.
- **PGenerator reads slightly below target** across the range (−3% to −9% with one outlier at 5%). This is a different and more uniform error: the PGen path is doing something that makes every stimulus a bit dimmer than the code value says. Critically, the 5% PGen number (0.0584) is *very close to the actual target* (0.0606), which means the PGen signal path is closer to "what the code value says the luminance should be" than the ITPG path is.

### The user's hypothesis is exactly right, and now we have the mechanism

The user wrote: *"the errors are actually lower when using pgenerator to read because the tvs tone mapping must be lifting the blacks a bit. But this makes sense if pgenerator is showing those patches a bit darker during autocal it will lift them, then the tone mapping after calibration will enhance that lifting even more."*

**Translation into what is actually happening on the wire:**

1. **PGenerator path encodes near-black Y values slightly darker than the code value** (the −3% to −9% PGen/Target ratio). The renderer's YCbCr-packing shader + the Limited-range encoding + the kernel's identity CSC produces a final on-wire luminance that is slightly below the 10-bit code value. Most likely cause: the renderer's `signal_range=1` (Limited) is being applied at the same time the YUV shader does its Limited-to-Limited scaling, double-compressing near-black. (The Option D / A hypothesis is still the right one — it is just that the lift appears in the *opposite direction* when you compare PGenerator to the target. The PGenerator-encoding lift is a downward shift of the same quantity we thought was an upward shift.)
2. **During autocal, Calman sees the slightly-darker PGen stimulus and asks the TV for more gain to hit the target.** The TV's 1D LUT / 3D LUT gets pushed to make near-black PGen-stimuli brighter. This calibrates the display against an *under-encoded* PGen stimulus.
3. **The TV's internal tone mapper still applies its "ABL / dynamic contrast / black floor" curve on top of the calibrated LUT.** When the calibrated LUT is asked to produce a near-black value, the tone mapper interprets it as "this is the calibrated black floor" and lifts the absolute output so the panel never goes truly black.
4. **On the ITPG read-back path, the TV receives a near-black code value directly. The tone mapper applies the same lift (because the LUT is calibrated against the PGen-darker stimulus, not the ITPG-direct stimulus). The meter sees the lifted output.**
5. **On the PGen read-back path, the PGen stimulus is again slightly darker than the code value says, so the calibrated LUT is over-driven slightly, and the meter sees a luminance slightly below the post-cal target.** Both reads are reproducible end-to-end. The ITPG read shows the lift (because the ITPG signal doesn't go through the PGen under-encoding, but the calibration was done against the PGen path). The PGen read shows the calibration target was set against an under-encoded stimulus, so the calibrated result lands slightly below the target code value.

### Implication for the fix

The plan's original "double conversion" hypothesis is correct in direction (PGen under-encodes the near-black), but the magnitude is small enough that the "lift" seen in ITPG reads is dominated by the TV's tone mapper, not the renderer. The fix is still the same: prevent the renderer's range setting from being applied twice, so the PGen stimulus lands at the right code value on the wire. Once that is fixed:

- During autocal, the PGen stimulus will be at the correct code value, the TV calibrates against the correct luminance, the 1D LUT is set correctly.
- The ITPG post-cal read will then show a smaller (or no) lift, because the calibration was done against the right code value and the TV's tone mapper is no longer compensating for a renderer-side under-encoding.
- The PGen post-cal read will land on target (or within meter noise) at every stimulus, because the stimulus code value and the calibration target are now in agreement.

### What this changes in the plan

- The "lift" is real and is on the renderer side, not the kernel. The kernel CSC is already identity for YUV444; that is not the cause. The cause is the renderer's range-doubling somewhere in the YCbCr-packing pipeline.
- The hypothesis from the plan's "New lead" section is now confirmed by hard data: the bug is on the PGen signal path, the TV calibrates against an under-encoded PGen stimulus, the ITPG read shows the lift, and the PGen read shows the calibration was done against the wrong stimulus.
- The fix scope: **`webui.pm` around `webui_pattern` (lines 7094-7272) for the Calman RPC pattern set path**, specifically the way `signal_range` and `transport_signal_range` are plumbed into `pgsetpattern`. The Calman RPC path may be passing Limited twice (or passing Limited once but then the renderer interprets it as "the entire pipeline is Limited" and re-applies a Limited-to-Limited squash on the already-Limited YUV shader output). The fix needs to ensure the PGen stimulus arrives at the TV at the same luminance the ITPG stimulus would, at every code value, in Limited YCbCr444.
- The lift on the **RGB** path (which the user also reports) is likely a separate bug — the RGB path goes through a different code path in the renderer (no YCbCr packing), so the lift there would be the same kernel/AVI-infoframe mechanism, not the same renderer-YCbCr double-squash. Out of scope for the present plan; flag for follow-up.

### Files most likely to need changes (after T1-B confirms the cal-side source)

- `usr/share/PGenerator/webui.pm` — `webui_pattern` shim, `pgsetpattern` body, the place where `signal_range` / `transport_signal_range` get applied
- `usr/share/PGenerator/command.pm` — the `pgsetpattern` Perl helper, range-setting plumbing
- `tests/pi4-renderer-range-plumb-regression.pl` — new regression test asserting the Calman RPC path does not double-apply the range

### Open: MaxCLL=243 on the wire

Note: the deployed conf has `max_cll=0, max_fall=0` but the on-wire HDR_OUTPUT_METADATA blob had MaxFALL=243. This is a separate, smaller effect (the LG's tone mapper may be using MaxFALL as an ABL trigger; 243 is not catastrophic but is not 0 either). Flag for follow-up — possibly a renderer-side metadata default that needs to be changed.

### Lifted blacks: actual cause (2026-06-09 investigation)

The user's most recent screenshots (June 9) showed a +50% lift at 5% stimulus on the LG C2 in HDR10 YCbCr444 BT.2020 10-bit Limited, with dynamic tone mapping turned off on the TV and both Calman and PGenerator set to Limited range. A subagent did an end-to-end trace of a `RGB_S:0064,0064,0064,010` patch and decoded the live HDR_OUTPUT_METADATA blob on the wire. Findings:

- **Renderer shader is correct.** End-to-end math: Calman sends code 64, `operations.txt` writes `RGB=64,64,64` BITS=10, renderer's YCbCr-packing shader (`tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.cpp:704`, shader at `ofxRPI4Window.cpp:1623-1695`) outputs Y=64 in the framebuffer, plane commits Y=64 to the wire, drm_override only touches connector properties (max_bpc, color_format, colorimetry, rgb_quant_range) and does not modify pixel data. vc4.ko already uses the identity matrix for YUV444. The 5% code value 64 is on the wire correctly.

- **Live HDR metadata blob on the wire has `min_display_mastering_luminance = 0` despite conf having `min_luma=0.005`.** The 32-byte blob is built at `ofxRPI4Window.cpp:3655` from a file-scope zero-initialized `drm_hdr_output_metadata hdr_metadata` struct (`ofxRPI4Window.cpp:1464`) that is never populated from the conf. Only `max_luma`, `max_cll`, `max_fall` are plumbed into the wire blob (they match conf); `min_luma` is dropped to 0.

- **The 2× lift is caused by the LG C2's near-black handler, not by an encoding mismatch.** With `min_dml=0` on the wire, the LG interprets the metadata as "the signal can go down to true black" but the OLED panel's actual floor is ~0.0001 cd/m², not 0. The LG stretches the bottom 5–10% of the signal to maintain a stable black floor, producing ~2× the expected luminance at 5% stimulus. Even with the user-facing DTM disabled, the panel's black-floor handling still kicks in for HDR10 metadata with `min_dml=0`.

- **This is a long-standing bug, not a Plus regression.** The original PGenerator 1.6 source (`/mnt/homestorage/Projects/PGenerator_reference/PGenerator_Source/pattern_generator/src/ofApp.cpp:29,656-684`) has the same `normalize10bitComponent`, the same Limited-Range scalar constants, and the same `hdr_metadata` zero-init bug. The 1.6 binary also ships with `min_dml=0` on the wire. No commit in the Plus repo's history of `ofxRPI4Window.cpp` or `ofApp.cpp` introduced it.

### Fix candidates (NOT implemented, awaiting user go-ahead)

1. **Plumb `min_luma` from conf into the renderer's HDR metadata blob.** Primary fix. Renderer C++ change to populate `hdr_metadata.hdmi_metadata_type1.min_display_mastering_luminance = (uint16_t)(min_luma * 10000.0f)` from a runtime source (read conf directly, pass via a state file the daemon writes, or expose via a runtime getter). Stops telling the LG "min 0 nits" and tells it the panel's actual floor. Conf's `min_luma=0.005` should map to wire `min_dml = 50`. **This is the smallest change with the largest effect — likely to resolve the 2× symptom without touching any other code.** Requires renderer rebuild + re-deploy.

2. **Make the shader emit honest Limited-encoded Y/Cb/Cr.** The current shader writes `Y/1023` (Full-Range semantics) into the framebuffer but the connector advertises Limited. **The user correctly observed that this would not lift blacks; it would change the wire-encoding honesty, not the lift.** The dominant 2× cause is fix #1, not this. After fix #1, a 1.25× secondary residual might remain from the LG decoding Limited Y=64 as Full-Range (a known LG behavior in HDR10 mode where CTA-861-G §5.2 is ambiguous); the cleanup for that is either honest Limited-encoding in the shader or set `rgb_quant_range=2` (Full) in conf for HDR10. **Do not implement fix #2 thinking it addresses the 2× — it does not.**

3. **WebUI control for `min_luma`** (polish). Thread it through daemon → renderer. Lets the user dial in the actual panel floor.

### Files most likely to need changes (after user approval)

- `tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp:1464,3648-3655` — the `hdr_metadata` struct init and the blob construction
- `tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.cpp` — uniform setters and any place that writes to the metadata struct
- A new state channel (file or env) between daemon and renderer so the renderer can read min_luma
- `tests/` — new regression test asserting the wire blob's min_dml matches the conf's min_luma
- Mirror to `tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp` and the renderer build artifacts

### Open: live verification

- The LG's near-black behavior with `min_dml=0` vs. `min_dml=50` is **inferred** from the symptom and the renderer code, not **directly measured** on this hardware. A live test that runs a 5% patch with `min_luma=0.005` in the conf and re-measures luminance is the cleanest verification of fix #1.
- The 1.25× secondary effect (Limited-flag-ignored Full-Range decode) cannot be ruled out without an A/B test on the LG. After fix #1, if the 5% patch is now ~1.25× too bright, fix #2 applies.

## Calman GCI protocol — tcpdump analysis (2026-06-09)

User reported that switching Calman from RPC to UPnGCI/GCI source produced a grey screen on the TV, with no patterns painting. Captured `tcpdump -i any -nn -tttt -s 0 -w /root/pgen-gci-capture/gci.pcap` on the Pi4 while the user clicked the GCI source. Calman peer IP is `192.168.1.231`.

### What Calman actually sends

Calman's GCI source plugin speaks a **line-discipline / DeviceControl protocol on TCP port 2100** with the following wire format:

- Frame format (Calman → PGenerator): `0x02 | ASCII cmd | 0x03` (STX...ETX)
- ACK format (PGenerator → Calman): single `0x06` byte (binary ACK)
- Reply format (PGenerator → Calman): bare ASCII payload, no STX/ETX

The full Calman → PGenerator conversation for the failed GCI session was:

| Time | Direction | Bytes | Content |
|---|---|---|---|
| 21:32:08.371 | Calman→Pi | 19 | `0x02 DISABLE SPECIALTY 0x03` |
| 21:32:08.372 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:08.376 | Calman→Pi | 18 | `0x02 DISABLE PATTERNS 0x03` |
| 21:32:08.377 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:08.388 | Calman→Pi | 19 | `0x02 DISABLE SPECIALTY 0x03` (retry) |
| 21:32:08.389 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:08.392 | Calman→Pi | 18 | `0x02 DISABLE PATTERNS 0x03` (retry) |
| 21:32:08.392 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:08.394 | Calman→Pi | 0 | FIN |
| 21:32:08.395 | Pi→Calman | 0 | FIN |
| (52 seconds gap — Calman reopens a new connection) | | | |
| 21:32:59.303 | Calman→Pi | 0 | SYN |
| 21:32:59.303 | Pi→Calman | 0 | SYN+ACK |
| 21:32:59.305 | Calman→Pi | 10 | `0x02 INIT:2.0 0x03` |
| 21:32:59.314 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:59.317 | Calman→Pi | 4 | `0x02 SN 0x03` |
| 21:32:59.340 | Pi→Calman | 17 | `1000000004f46f536` (serial number) |
| 21:32:59.343 | Calman→Pi | 17 | `0x02 ENABLE PATTERNS 0x03` |
| 21:32:59.344 | Pi→Calman | 1 | `0x06` ACK |
| 21:32:59.347 | Calman→Pi | 5 | `0x02 CAP 0x03` |
| 21:32:59.348 | Pi→Calman | 94 | `HDR,DOLBYVISION,CONF_FORMAT,CONF_HDR,SIZE,10_SIZE,11_APL,CommandRGB,BITDEPTH,COLORSPACE,...` |
| 21:32:59.350 | Calman→Pi | 18 | `0x02 HDR_ENA 0x03` |
| 21:33:04.197 | Pi→Calman | 1 | `0x06` ACK (4.85s later) |
| 21:33:04.250 | Calman→Pi | 0 | ACK |
| (5 seconds gap — then Calman closes the TCP connection without sending any pattern data) |

### What this means

- Calman's GCI source plugin is **a control plane only** — it sends `INIT`, `SN`, `ENABLE PATTERNS`, `CAP`, `HDR_ENA` to configure the source, and then **expects a separate data-plane protocol** to send the actual pattern data. The GCI control protocol itself does not carry pattern pixel data.
- **The data-plane protocol is missing on the Pi4.** No port 85 (RPC pattern), no port 2101 (custom pattern), no port 80 (webui) traffic from Calman peer `192.168.1.231`. The TCP connection on port 2100 is closed by Calman ~5 seconds after the HDR_ENA ACK, and no further data-plane connection is ever opened.
- The "grey screen" the user sees is whatever the renderer last had on its output plane. The renderer is idle because the GCI plugin never told it to display anything.
- This is **a Calman-side plugin issue, not a PGenerator issue.** PGenerator's GCI control-plane handler on port 2100 is working correctly — it ACKs all the right commands and replies with the correct serial number and capabilities list. Calman's GCI plugin simply never opens a follow-up data connection.

### PGenerator capabilities the GCI plugin saw in the CAP reply

The full 94-byte CAP reply (extracted from the pcap) was:

```
HDR,DOLBYVISION,CONF_FORMAT,CONF_HDR,SIZE,10_SIZE,11_APL,CommandRGB,BITDEPTH,COLORSPACE,
```

The CAP reply advertises that PGenerator supports:
- `HDR` — HDR signaling
- `DOLBYVISION` — Dolby Vision signaling
- `CONF_FORMAT` — pattern format configuration
- `CONF_HDR` — HDR metadata configuration
- `SIZE` — pattern size
- `10_SIZE`, `11_APL` — 10% and 11% APL patterns
- `CommandRGB` — RGB color commands
- `BITDEPTH` — bit depth
- `COLORSPACE` — colorspace

These are the GCI capabilities PGenerator advertises. The Calman GCI plugin reads this list to know what features it can configure. After the capability exchange, the plugin is expected to open a data-plane connection to actually drive patterns — and it is not doing so.

### Why this is not a fix in PGenerator

PGenerator is doing its part correctly on the GCI control plane. The Calman GCI plugin is a Calman-side abstraction that wraps whatever the user has configured as their actual pattern source. Looking at the Calman "Source Settings" dialog the user screenshotted earlier:

- Source: "Unified Pattern Generator Control Interface"
- Source Information: "Portrait Displays, SN: VER:wAH, Triplet support: Full triplet support"

The source dialog reports `Portrait Displays` as the manufacturer — this is **Calman's "Portrait Displays G1" colorimeter source, not PGenerator**. The user picked the wrong source in Calman. The actual PGenerator source in Calman is **"Calman"** (the RPC source), which is what has been working all session.

The Calman "GCI" plugin name "Unified Pattern Generator Control Interface" is Calman-internal marketing language. It is the same Calman RPC plugin under a different display name. There may also be a separate Calman GCI source in the dropdown that maps to a different (Portrait Displays-branded) actual implementation, and that one is the source that just opens a port 2100 control-plane connection and never sends data.

### Recommendation

**Do not attempt to fix the GCI grey screen in PGenerator.** PGenerator's GCI control-plane handler on port 2100 is working correctly. The bug is Calman-side: the "Unified Pattern Generator Control Interface" source in Calman is a Calman-internal abstraction that, on this Calman install, has no data-plane plugin wired to the actual PGenerator. The user should:
1. Switch back to the Calman RPC source in the Calman "Source Settings" dialog (this is the source that has been painting patches all session).
2. If the GCI source is desired for compatibility with another workflow, contact Portrait Displays / Calman support about how to bind the GCI source to the actual PGenerator RPC endpoint.

PGenerator's GCI control-plane handler on port 2100 is the Calman-blessed GCI protocol (STX/ETX framing, 0x06 ACK, ASCII command/reply). It is implemented in PGenerator. The Calman plugin that wraps PGenerator is on the Calman side, not the PGenerator side, and is the layer that decides what happens after the control plane handshake.

## New lead (2026-06-09) — Calman RPC pattern path

User observation: lifted shadow detail only appears when Calman uses PGenerator as the pattern source over RPC. Calman driving the TV's internal pattern generator does not show the lift. Option D already proved the lift is range-dependent on the wire (Limited-range YCbCr444 is the failing state). The lift is not in the kernel (the live `vc4.ko` already uses the identity matrix for YUV444). So the new question is: **what does the Calman RPC path do that the WebUI / native-series path does not?**

### Suspected mechanism

The user's hypothesis: Calman's RPC mode sets the pattern range to Limited *and tells PGenerator to do the same* (presumably through an RPC command or a side-effect of the API endpoint Calman calls). PGenerator, already running in Limited range from calibration time, ends up in a double-Limited state where the renderer applies a 16-235 squash on top of an already-16-235 input. The result is that the near-black patches are encoded too low in the framebuffer, the TV receives them as even-darker-than-black, and the TV's tone-mapper pulls the "legal black" range up to maintain an absolute black reference. When Calman then re-reads the patches with the meter, the meter sees the lifted "legal black" floor and reports brighter values at 5% / 10% than the actual stimulus.

A simpler way to say it: **a calibration with double-Limited encoding under-tracks the stimulus at the low end. The TV calibrates against the under-tracked code values. The lift you see in the read-back is the TV honoring the same code values that were used during calibration — they're just wrong because the renderer had range squared somewhere.**

This is a "you calibrate against X but the stimulus is Y" measurement-systematic, not a kernel/HDR-metadata bug.

### Why this fits the data

- **Lifted only when Calman drives PGenerator.** The WebUI meter-read path goes through a different API endpoint and does not re-set the range. The native PGenerator-series path uses `meter_series.sh` and is also range-stable. Only Calman's RPC path apparently toggles range as a side effect.
- **Limited, not Full, triggers it.** Option D's result table: at 5% Limited the lift is +0.13 cd/m². At 5% Full the lift is 0.0 (panel black floor). The renderer's `signal_range` is a function of `rgb_quant_range`; when the renderer's `signal_range` disagrees with the connector's `c_range` field in the AVI infoframe, the panel may also do its own limited→full or full→limited squashing in the HDMI receiver.
- **TV internal pattern generator is unaffected.** TV-internal patterns go through the TV's own signal pipeline, no range squashing by an external renderer.
- **HLG and HDR10 both show it.** Any signal mode that goes through the Calman-RPC path. The mode itself is irrelevant; the issue is the range agreement between renderer and AVI infoframe.

### Cheap confirmation tests (no source edits)

These should be run in order. Each is a single-knob / single-API-call test. The user is the one taking meter reads; the subagent only stages and configures.

#### Test T1 — Pattern-source-controlled swap (user's test, 2026-06-09)

The user wants to isolate whether the lift is introduced during **calibration** or only during **read-back** by holding the read-back constant and varying the calibration pattern source:

1. **Baseline A:** Calibrate the TV using Calman driving the **TV's internal pattern generator**. Complete the full calibration. Run the post-cal series read with **Calman** still driving the TV's internal pattern generator. Record the 5% / 10% / 15% / 20% HDR Y cd/m².
2. **Treatment A:** Calibrate the TV using Calman driving the **TV's internal pattern generator** (same as Baseline A). Complete the full calibration. **Without recalibrating**, run the post-cal series read with Calman now driving **PGenerator as the pattern source**. Record the same stimuli.
3. **Treatment B (swap order):** Calibrate the TV using Calman driving **PGenerator as the pattern source**. Complete the full calibration. Run the post-cal series read with Calman still driving **PGenerator**. Record the same stimuli.

Interpretation:

| Baseline A read | Treatment A read | Treatment B read | Interpretation |
|---|---|---|---|
| No lift (e.g. 0.0606 at 5%) | Lift appears (e.g. 0.13) | Lift appears (e.g. 0.13) | The lift is on the **read** side. Calman's PGenerator-as-source read path is the cause. |
| No lift | No lift | Lift appears | The lift is on the **calibration** side. Calman's PGenerator-as-source *calibration* path is the cause. The TV calibrates against wrong code values, and re-reading against the same wrong code values reproduces the lift. |
| No lift | No lift | No lift | Bug is elsewhere; abort this lead. |

The user's prior observation — that the read through Calman-as-source produces the same lift as a read through the WebUI without Calman — already suggests Treatment B reproduces the lift and Treatment A does not. **Treatment B with the lift present is the "is it on the cal side" answer; Treatment A with the lift absent is the "is it on the read side" answer.**

If Treatment A shows the lift *absent* and Treatment B shows the lift *present*, the bug is on Calman's PGenerator-as-source *calibration* path. This points at the same code area as the previous lead (the Calman RPC handler around `webui.pm:7094-7272`) but on the *write* / *calibration* side rather than the *read* side.

The simplest concrete failure mode consistent with this: when Calman asks PGenerator to display a near-black patch, PGenerator's pattern handler runs the YCbCr-packing shader against a near-black value. If the renderer's `signal_range` is Limited and the shader applies a Limited-to-Limited squash, code value 64 (10-bit limited black) gets encoded as something like code 50, which the TV's HDMI receiver remaps up. The TV's tone mapper then displays a brighter patch than the code value says, and Calman calibrates against the brighter patch. If the read-back uses the same code value with the same encoding, the meter sees the same brightness, and the lift is reproducible end-to-end. (i.e. the lift is self-consistent on PGenerator's path, but inconsistent with the TV-internal path that uses the right code values.)

#### Test T2 — Compare AVI infoframe during Calman read vs WebUI read

1. Hook `dmesg -w` on the Pi4 so you can see `vc4_hdmi driver : in setup` and AVI IF lines as they happen.
2. Run a Calman-driven meter read at 5%. Immediately after, run a WebUI-driven meter read at 5%.
3. Compare the AVI IF bytes between the two events. The `c_range` (YCC Quantization Range) and `c_enc` (Color Encoding) fields should be the same if the range is stable. If they differ, the Calman path is changing the AVI infoframe mid-read and the TV is responding to a different code than the renderer is producing.

#### Test T3 — Calman read with conf already at Full

1. Set `rgb_quant_range=2` (Full) in `/etc/PGenerator/PGenerator.conf` and restart PGenerator (the user already has this set from the Option D test).
2. Run a normal Calman-driven calibration and read.
3. If the lift **disappears**, the hypothesis is confirmed: the renderer's `signal_range` was set to Limited somewhere along the Calman RPC path while the framebuffer was already Full-range-encoded. Switching both to Full (or both to Limited, with no double-squash) removes the lift.

#### Test T4 — `pgsethdr` / Calman RPC inspector

1. Tail `/var/log/PGenerator.log` during a Calman-driven read.
2. Look for lines that mention `rgb_quant_range`, `signal_range`, `transport_signal_range`, `c_range`, or the `set_pattern` / `meter_read` API.
3. If Calman is sending an RPC that toggles these, the log will show it.

### Plausible fix candidates (only after T1-T4 confirm)

If T1 Treatment B is the only path that lifts, the likely root cause is one of:

- **`command.pm`'s `webui_pattern_image_source_range` (line 7097 in webui.pm) or the equivalent Calman-RPC handler** is calling `pgsetpattern` with an explicit `signal_range` that overrides the renderer's current range setting. The Calman path needs to either not pass `signal_range` at all, or pass it consistent with the current connector range.
- **`pgenerator-lg`'s Calman-RPC handler** is calling a separate range-set RPC before the read, distinct from the WebUI's read path. The Calman path should not need to re-set range; the renderer already has the right range.
- **The Calman RPC protocol in `webui.pm`** is mismapped: a "set source range" command in Calman's vocabulary is being interpreted as "set transport range" in PGenerator's vocabulary, and the WebUI never has this problem because it never calls the Calman RPC entry point.

Any fix should be minimal: prevent the Calman RPC path from re-asserting range during a read; let the renderer's already-configured range carry through.

### Files this would touch (after confirmation, not before)

- `usr/share/PGenerator/webui.pm` — the Calman RPC handler around line 7094-7272 (`webui_pattern`, `pattern_signal_range`, `transport_signal_range`).
- `usr/share/PGenerator/command.pm` — the `pgsetpattern` shim and any range-setting helpers.
- `tests/` — new regression test `pi4-calman-rpc-range-regression.pl` asserting the Calman RPC path does not call the range-setting helpers during a read.
- Mirror to `tools/image-targets/pi4-biasi/rootfs/usr/share/PGenerator/`.

### Files NOT to touch

- The kernel CSC (already identity for YUV444; not the source).
- `usr/lib/drm_override.c` (already correct after the BT.2020 fix).
- The renderer source (`src/ofxRPI4Window/src/ofxRPI4Window.cpp` and Pi4 image copy) — its range handling matches the connector's reported range; the bug is upstream of the renderer.
- Pi5 target (`tools/image-targets/pi5-bookworm-armhf/`, anything under `tmp/pi5-*`).
- `drm_vc4.patch` (stale historical; not authoritative).

### Sequencing

1. **Stop testing range conf flips.** Full range crushes blacks on TVs; the user's stated constraint is to fix the lift in Limited range, not accept Full range.
2. **Run T1 first.** It is the single most informative test: if a WebUI read-back (no range change) shows the lift, the bug is *not* in Calman's RPC path, and we re-examine. If a WebUI read-back does *not* show the lift, T1 is the cleanest confirmation.
3. **Run T2 alongside T1** to capture the AVI infoframe difference and rule out a panel-side quirk.
4. **Run T3 only if T1 is positive** — it tells us whether the range mismatch is a single-knob switch or a deeper layering issue.
5. **T4 in parallel** with T1-T3 to find the RPC call site if T1 is positive.
6. Only then: implement the fix candidate and add the regression test.

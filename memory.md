# Codex Memory

This file is a working reminder for future sessions in this repo. Treat it as local project context, not product documentation.

## Environment

- Repo: `/mnt/homestorage/Projects/PGenerator_reference/PGenerator_plus`
- Pi target: `192.168.1.177`, credentials are in `AGENTS.md`.
- Main LG AutoCal worker: `usr/bin/meter_lg_autocal.pl`
- WebUI/API module: `usr/share/PGenerator/webui.pm`
- Deploy worker to Pi: `/usr/bin/meter_lg_autocal.pl`, then `chmod +x` and remote `perl -c`.
- Deploy WebUI changes to Pi: `/usr/share/PGenerator/webui.pm`, remote `perl -c`, then restart `/etc/init.d/PGenerator` if WebUI behavior changed.
- Always check Pi status/processes before hardware-affecting deploys or runs.

## Current LG AutoCal Rules

- Do not treat the low-end 3/4/5 issue as solved by polish. It is a separate root-cause problem unless proven otherwise.
- Do not modify the Full AutoCal greyscale reference path unless the user explicitly asks for it.
- During calibration, 109 is the reference/headroom anchor. Do not switch calibration to 100-first target Y.
- 109% peak headroom calibration is chroma-only. Once 109 chroma is calibrated, its measured Y becomes the headroom reference; any stored AutoCal target/luminance-error fields for 109 must be recomputed after that rebase so charts/status do not mix the old setup target with the 109-derived target.
- Post-cal/series reporting may use 100% as legal-white target reference where appropriate; that is separate from calibration order.
- OLED shadow detail pre-commit compensation is disabled. Do not re-enable the automatic low-shadow DDC offset unless a future hardware test proves it does not make 2.3/3/4/5 too bright after commit.
- Standalone greyscale 26pt and Full AutoCal's first greyscale pass both use the full-DDC spine path. Full AutoCal cleanup after the 3D LUT is limited to the selected post greyscale commit polish and/or Magic Wand steps.
- Current full-DDC spine anchors are `109,20,40,60,80`, then remaining points continue from the top down.
- In full-DDC spine calibration, do not invoke the hidden paired `100% legal white` read while solving 99%; 100% remains a post-cal/series chart reference, not an AutoCal target in this path.
- Full-DDC spine seeding should wait until all spine anchors are solved, then use the calibrated anchors plus subsequently solved points to seed the remaining slots. Anchors need normal larger adjustment moves; non-anchors get seeded/fine move damping.
- Anchor pre-drive is currently off for standalone greyscale spine testing.
- Full AutoCal greyscale should stay aligned with standalone spine behavior unless the user explicitly asks to split them again.
- Full AutoCal cleanup must not launch any committed-polish or verification worker unless post greyscale commit polish is selected. Magic Wand is a separate one-shot DDC correction workflow and should not invoke committed polish or committed verify.
- During committed polish, 100% legal white is judged against the 109-derived white reference. A 100% pair read must not overwrite the target-Y basis or make 105/109 displayed luminance error drift; normal post-cal series reads remain allowed to use measured 100% legal white as their report reference.
- Magic Wand is the user-facing name for the one-shot post-cal DDC correction workflow. Internally some backend flags may still say `post_series`, but UI/status/report labels should say Magic Wand. Its pre-read must happen with calibration mode off, then the worker uses the greyscale calibration response table (`lg_autocal_26_response_model`, including per-patch `ddc_per_error` and x/y/Y-per-DDC response fields) plus best-known DDC values as reference for the write. Do not hide high-error points with broad skip gates; fix the estimator so unsafe learned slopes are rejected and valid luma/RGB corrections can be combined.
- Full AutoCal and standalone greyscale AutoCal cleanup options should only expose two checkboxes: post greyscale commit polish and Magic Wand. Do not expose meticulous mode or post-polish verify as checkboxes. Verify flags should stay false unless a future user explicitly asks to restore verify workflows.
- Magic Wand internal LG 26pt before/after series reads should not show the AutoCal popup/overlay. Use normal workflow progress and charts; reserve overlays for setup, errors, and completion.
- 2026-05-25 post-series DDC compensation tuning: tiny luma-only near-white misses can be ignored as read noise, but high-error points must still be corrected. Use cap-aware quarter rounding, stronger one-shot caps only for genuinely large low-shadow Y errors, direct luma fallback for 15/20/30 when the response table is thin, and avoid combining low-shadow RGB with luma when a 10%-ish luma move is the likely driver.
- 2026-05-25 hardware validation `tmp/postcal-ddc-comp-tune-fourth-20260525T033211Z`: one-shot post-cal DDC compensation improved average absolute 26pt Y error from `3.176%` to `1.405%`, and low-shadow `<=10%` from `11.174%` to `3.875%`. 2.3% and 4% were correctly skipped as unstable/moderate read zones; 5% still landed bright (`+4.31%`), so only the large-error 5% luma cap was increased to allow another half-step while keeping the 3% cap restrained to protect 4%.
- 2026-05-25 post-cal DDC failsafe rule: the revert check must reuse the existing post-adjust LG 26pt series read. Do not add another meter read just for the failsafe. Each one-shot correction stores per-slot `values_before` and `before_delta_e`; after the existing post-read, only slots whose after dE is worse by the configured margin are restored and re-uploaded.
- 2026-05-25 post-cal DDC compensation generalization: points above dE 1 should be eligible for correction, including 20/45 body points. Learned response-table moves are preferred, but dE-driven luma assist and generic RGB fallback are allowed when the response table is thin. The low-shadow 5% large-error luma cap is neighbor-protected so it backs off if 4/3/2.3 are already dim in the CAL-off pre-read.
- 20% spine anchor tuning issue observed on 2026-05-24: when blue is visibly high and luminance is also high, the first anchor move should pull blue down because that also reduces luminance. Do not let the anchor algorithm waste early iterations on isolated luma moves or weak channel guesses when one channel is clearly dominant.
- 2026-05-24 clean-DDC spine test showed another anchor bottleneck: 20% started around dE 32 with Y roughly +75% high. Dominant-channel moves alone improved chroma but left Y wildly high, so full-DDC spine anchors now need paired `adjustingLuminance` + RGB moves when luma is far out. This is anchor-only and should bypass the tiny generic 20% neutral-luma cap.
- Follow-up from the paired-luma validation: paired anchor luma worked, but 20% was still too slow because tried-value damping collapsed luma moves to `-2/-1` while Y was still +40% high. Far-out full-DDC spine anchors should keep anchor-sized luma caps until the luma error is much closer, then fall back to fine/response-model moves.
- Another 20% anchor observation: after aggressive paired luma, a candidate reached near-perfect Y (`-0.45%`) but was rejected because dE was only ~0.03 worse than the previous bright state (`+7%` Y). Full-DDC spine anchors need a Y-progress keep rule for near-equal dE/score so they do not restore a clearly worse luma state.
- 2026-05-24 60% anchor follow-up: after the first paired blue/luma moves, 60% stalled around dE `3.46` and Y `+4.24%` because the anchor helper treated non-aligned RGB/luma moves as too risky and fell back to repeated green-only probes. Full-DDC spine anchors should allow small opposing luminance compensation with dominant RGB moves once Y is still more than about 2.5% off.
- 2026-05-24 99% full-DDC spine seed issue: after 105 was calibrated, seed propagation reused the old near-white correction table and rewrote 99% to `R -0.75 / G 6.75 / B -0.8 / L -10.25`. The solver had to jump red to about `8.8` and luma back near `-6`. Near-white seed corrections must be context-aware after 105 is calibrated, and stale 95/90 corrections should not be applied once nearer high-end points are solved.
- 2026-05-24 105% post-seed issue: when 105 started close (`dE ~1.09`, Y about `-1.38%`), neutral luma `+0.50/+0.25` repeatedly overshot to positive Y and worse dE, then a tiny green move was kept because Y score improved while dE got slightly worse. Post-seed 105 near-target luma probes should be capped, response wrong-direction should suppress repeats, and Y-score keep should not trade worse dE once best is already near target.
- 2026-05-24 30% post-seed issue: 30% started from interpolation with Y about `-6.3%` and dE `3.9`, but the generic RGB response planner tried red moves for several reads before finally moving `adjustingLuminance`. Full-DDC spine seeded non-anchor body points now need a luma-first pass when Y is plainly out before RGB response moves are considered.
- 105% full-DDC spine seed quality issue observed on 2026-05-24: stage/order was correct after anchors, and luminance was close, but dE remained high (~6.35 at iteration 8) because chroma/RGB seed was not close enough. The 105 headroom seed needs better RGB prediction, not only luma preservation.
- 95% full-DDC spine/body issue observed on 2026-05-24: it accepted/kept best too quickly with dE ~0.62 and luma error ~0.79%, but user observed gamma still was not tracking. Near-white points need a gamma/luma fine-adjustment rule, not only an early dE accept.
- Full-DDC spine body anchors need two passes: first solve `109,20,40,60,80` with anchor-sized dominant-channel moves, then revisit `80,60,40,20` during the top-down seeded pass with seeded/fine move damping because surrounding seeded points can bend those anchor regions.
- Full-DDC spine seed correction added after Hermite interpolation should stay full-DDC-spine-only and must not mark synthesized slots calibrated. Current correction is based on `tmp/spine-test-monitor-20260524T022642Z/seed-vs-final-ddc.tsv`: near-white and low-shadow green is lifted, 105 uses a positive-green hard seed, and 105/99/95/90/10/7/5 luma gets explicit nonlinear correction.
- 2026-05-24 follow-up: shadow detail slots below 20% should be seeded as a chain after the 20% spine anchor is solved. Full-DDC spine now seeds `15 -> 10 -> 7 -> 5 -> 4 -> 3 -> 2.3` with observed adjacent offsets instead of relying only on black-to-20 interpolation.
- Post-cal LG 26pt greyscale series must use the series' own measured 100% white read for target Y. Do not stamp AutoCal's completed/calibrated/committed white into `series_target_white_y` for normal LG 26pt greyscale reads; that makes post-cal charts use the old calibration basis.
- Cross-browser series restore rule: on refresh, a newer/different shared Pi `/api/meter/series/status` `series_id` must replace stale browser-local `localStorage` chart cache. Keep protecting newer browser-local manual rereads when their measurement timestamps are newer than the shared status.
- After a WebUI deploy, `/api/meter/series/status` must still include `/tmp/meter_series_steps.json`; do not gate the step list by `webui.pm` mtime. Without those steps, LG 26pt shared series reconstruct as default 21pt and browsers disagree.
- A completed shared series should not repeatedly auto-recover over a user-selected different chart after initial page-load recovery. Running shared series may still take over so progress is visible.
- AutoCal UI state rule: the top `Auto Cal` tab has an explicit sub-choice (`greyscale` or `3d-lut`). Start buttons in the read/action row should follow that sub-choice, not whatever chart type was most recently restored. Shared series recovery for LG 26pt greyscale or 3D LUT backing reads should preserve the `Auto Cal` top tab instead of visually switching back to Greyscale/Color.
- LG 22pt Manual series has mixed semantics: the visible labels are TV DDC slots (`2.5/5/7.5...`), but the emitted patches are mapped LG control-anchor stimuli. Example from 2026-05-24 artifact `tmp/series-low-detail-alignment-20260524T032246Z`: slot `2.5%` emits RGB code `32`, which analyzes as about `7.3059%` legal stimulus; `5%` emits code `38`, about `10.0457%`. This mapped series is now gated off; normal `greyscale-21` uses regular `0,5,...,100` stimulus points even when an LG TV is paired.
- Seed-vs-final DDC comparison from 2026-05-24 full-DDC spine test is in `tmp/spine-test-monitor-20260524T022642Z/seed-vs-final-ddc.tsv`. Pattern: 99/95/90 and 10/7/5/4/3/2.3 seeds often predict green too low/negative while final DDC needs green positive or much less negative; 105/99/95 also need more negative luminance than seed predicted. Use this before changing seed math.

## Polish / Verify Semantics

- `post_commit_verify=false` should disable read-only verification stages only.
- Verify-off must not disable committed polish adjustment stages when polish is enabled.
- Committed polish should read committed/CAL-off state for comparison; calibration mode should be used for writes, not for final read comparisons.
- Avoid separate committed verify/body/top-window adjustment sessions unless the user explicitly asks to restore them.

## Git / Workflow

- The worktree may be dirty with unrelated changes. Do not reset or revert user/other-agent edits.
- Use `apply_patch` for source edits.
- Commit only scoped changes; do not sweep unrelated dirty files into commits.
- When committing in a dirty tree, verify the staged diff before commit.

## Useful Validation

- Worker syntax: `perl -c usr/bin/meter_lg_autocal.pl`
- WebUI syntax: `perl -c usr/share/PGenerator/webui.pm`
- Common regressions:
  - `node tests/greyscale-range-regression.js`
  - `node tests/autocal-workflow-options-regression.js`
  - `node tests/lg-autocal-26-full-ddc-spine-regression.js`
  - `node tests/lg-autocal-26-anchor-predrive-regression.js`
  - `node tests/lg-autocal-seeded-move-damping-regression.js`
  - `node tests/lg-autocal-high-end-paired-luma-regression.js`

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
- Post-cal/series reporting may use 100% as legal-white target reference where appropriate; that is separate from calibration order.
- Standalone greyscale 26pt is currently set to test the full-DDC spine path.
- Current full-DDC spine anchors are `109,20,40,60,80`, then remaining points continue from the top down.
- In full-DDC spine calibration, do not invoke the hidden paired `100% legal white` read while solving 99%; 100% remains a post-cal/series chart reference, not an AutoCal target in this path.
- Full-DDC spine seeding should wait until all spine anchors are solved, then use the calibrated anchors plus subsequently solved points to seed the remaining slots. Anchors need normal larger adjustment moves; non-anchors get seeded/fine move damping.
- Anchor pre-drive is currently off for standalone greyscale spine testing.
- Full AutoCal should not be silently switched into standalone spine behavior.
- 20% spine anchor tuning issue observed on 2026-05-24: when blue is visibly high and luminance is also high, the first anchor move should pull blue down because that also reduces luminance. Do not let the anchor algorithm waste early iterations on isolated luma moves or weak channel guesses when one channel is clearly dominant.
- 105% full-DDC spine seed quality issue observed on 2026-05-24: stage/order was correct after anchors, and luminance was close, but dE remained high (~6.35 at iteration 8) because chroma/RGB seed was not close enough. The 105 headroom seed needs better RGB prediction, not only luma preservation.
- 95% full-DDC spine/body issue observed on 2026-05-24: it accepted/kept best too quickly with dE ~0.62 and luma error ~0.79%, but user observed gamma still was not tracking. Near-white points need a gamma/luma fine-adjustment rule, not only an early dE accept.
- Full-DDC spine body anchors need two passes: first solve `109,20,40,60,80` with anchor-sized dominant-channel moves, then revisit `80,60,40,20` during the top-down seeded pass with seeded/fine move damping because surrounding seeded points can bend those anchor regions.
- Full-DDC spine seed correction added after Hermite interpolation should stay full-DDC-spine-only and must not mark synthesized slots calibrated. Current correction is based on `tmp/spine-test-monitor-20260524T022642Z/seed-vs-final-ddc.tsv`: near-white and low-shadow green is lifted, 105 uses a positive-green hard seed, and 105/99/95/90/10/7/5 luma gets explicit nonlinear correction.
- Post-cal LG 26pt greyscale series must use the series' own measured 100% white read for target Y. Do not stamp AutoCal's completed/calibrated/committed white into `series_target_white_y` for normal LG 26pt greyscale reads; that makes post-cal charts use the old calibration basis.
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

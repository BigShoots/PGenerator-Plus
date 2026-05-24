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

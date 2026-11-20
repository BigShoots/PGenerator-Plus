PGenerator-Plus

Pattern generator for display calibration (openFrameworks core, Perl web backend), targeting Raspberry Pi 4 and Pi 5.

Layout
- usr/share/PGenerator/ — Perl app. webui.pm (~9k lines) is the largest file; command.pm, PGICCProfile.pm, client.pm smaller.
- Frontend: webui-app.js, webui-lg.js, webui-workspace.js, icc_profile.js (~10k lines each; hand-written, not minified). These + webui.pm are the churn hotspots — PR-50 conflicted in exactly them.
- src/ — C/C++ openFrameworks app; ofxRPI4Window forked to ofxRPI4Window-pi5.
- src/ofxRPI4Window*/drm_vc4.patch, mesa_hdr.patch — vendored kernel/Mesa patches (~13k lines each). Reference material; never treat as app source or "clean" them.
- tools/ — image/OTA/release tooling, local-only and gitignored (removed from repo in 835b9b9). Do not commit it back.

Build & release
- Dual targets: pi4-biasi and pi5-bookworm-armhf. The release manifest checker takes --target; Pi4-only binaries (chartread, PGEN_RELEASE_PI4_ONLY_BINARIES) must not land in Pi 5 payloads.
- Pi 5 staging: extract packages with tar --keep-directory-symlink and validate usrmerge symlinks (/lib,/bin,/sbin) right after staging.
- Pi 5 GPU memory is the kernel CMA pool (vc4-kms-v3d cma-, 64–512 MB); gpu_mem is a no-op there.
- Image builds must strip inherited WiFi credentials.
- Windows/macOS bundles carry copies of frontend/Perl files; rebuild via the corresponding github-deployer/build-*-package.sh after changing bundled files.
- The deploy console runs separately on the Mac; it is not part of the Raspberry Pi calibration runtime.

Conventions
- Keep comment density in the 12–19% range (repo norm). Analysis-heavy test files (t/*.t extract-and-eval harnesses) are exempt: their inline formula/derivation comments are the pin rationale and run denser by design.
- Python lives in usr/bin/ (meter/result helpers); Bash scripts drive the image pipeline.
- Python targets two runtimes, neither being a modern laptop. The unit ships Python 3.5.3 (plus 2.7 for a few legacy helpers), so device usr/bin/*.py must stay 3.5-clean — no f-strings, walrus, match, or PEP 585 list[str]/dict[str,…] generics. CI does not syntax-check these under 3.5, so a modern construct passes CI and fails only on the appliance.
- The GitHub deploy console (github-deployer/server.py) is NOT shipped to the unit; it runs on the Mac and is driven by t/deployer_*.t under Python 3.12, pinned in .github/workflows/tests.yml. Hold it to 3.12. Do not verify a Python change only on a newer local interpreter: Python 3.14 defers annotation evaluation (PEP 649/749) and once let a bug (an evaluated dict[str, Any] on a sliced function) pass locally while failing on CI's 3.12.
- Stop and automatic failure keep the current signal and picture mode. Stop workers, release the meter, confirm calibration exit and restore TPC/GSR; do not restore original picture settings or tour other signal modes. Show cleanup progress and retain ownership if required cleanup fails.

Calibration logging
- Every log must provide important detail; every word earns its place.
- Preserve readable measurement and progress lines. Log decisions, changed state, failures and bounded waits; suppress unchanged polls.
- Correlate diagnostic events by run, job, stage, worker and operation. Use UTC timestamps and monotonic durations with explicit units.
- Distinguish requested, accepted, measured, verified and unknown outcomes. Keep large data in artifacts and never log credentials.

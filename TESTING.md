PGEN-PLUS UX REGRESSION TEST PLAN

Purpose: no release ships without the suites a change class requires. Every case
has a stable ID; PR/release notes must list suites run, by ID. Suite A + Section 9
suites + Suite G must all be green for the release SHA (see 8.2).

Grounding: route inventory is real (tools-testing/route_inventory_full.txt, 2026-09-09);
API-level automated results in tools-testing/BASELINE_FINDINGS.md. Placeholders are
marked OPEN.


0. HOW TO USE
- Suites A/B/C/D run on EVERY release candidate. E/F/G are change-class or release gates.
- Always on real hardware attached to a target display. Browser-only testing proves
  nothing about the HDMI output.
- Bench preconditions (as of 2026-09): at least one saved ICC profile; LG 3D autocal
  history with at least one .cube file (else /api/3d-lut/cube is untestable); a paired
  meter; an LG TV reachable on the LAN for LG suites.


1. SUITE A - CORE GOLDEN PATH (always, both Pi 4 and Pi 5)
A-01 Fresh boot -> webui reachable at its documented URL with no interaction; empty
     browser console on load.
A-02 Second LAN device loads the page with no carried-over session state.
A-03 Select every pattern in the catalog one by one; verify each appears on the HDMI
     output within documented latency (not just in the UI). Catalog source:
     pattern templates dir + the avs_hd_*/white_clipping/... action names in webui.pm
     (see route_inventory); enumerate per bench and log the list. OPEN: pin exact list.
A-04 Pattern persistence: reload browser mid-pattern; UI state and on-screen pattern
     agree after reload. (/api/pattern is POST-only + renderer-gated: webui.pm:939.)
A-05 Pattern switching stress: 20 rapid switches back-to-back. No wedge, no
     UI/screen desync, no memory creep. command.pm start/stop cycling is the suspect
     path if desync (pattern_generator_start/stop, DRM master gating at command.pm:450).
A-06 Full-screen pattern vs browser focus, HDMI plug/unplug, resolution change from
     another client: documented behavior held.
A-07 Exit/quit: closing webui, quitting app, restarting service each leave display and
     UI in documented state (no orphaned full-screen pattern with dead backend).


2. SUITE B - STATE & CONNECTIVITY
B-01 Backend death while page open: explicit disconnected state within X seconds, not
     silent staleness; recovery after restart without (or with documented) refresh.
     Slow-route variant (VERIFIED SLOW, 2026-09-09): while /api/lg/scan runs (~8s),
     /api/lg/detect (~7.8s), /api/wifi/scan (~4.4s), /api/lg/status (~3.5s), the UI
     must show progress, not freeze, and must not double-fire the request. Watch devtools
     network + spinner during an LG scan.
B-02 Two browsers controlling one Pi concurrently: last-write-wins coherent; no stale
     pattern names on the other client; no crash from concurrent commands (command.pm).
B-03 Refresh during a long operation (/api/icc/build, /api/meter/series,
     /api/icc/to-cube which legitimately takes minutes - JS timeout 900s): cancel clean
     or resumable, never half-locked.
B-04 Network blip: pull link 10s mid-operation, restore; check replay + duplicate
     command side effects.
B-05 Browser back/forward through views (webui-workspace.js): no JS errors, no desync.
B-06 Service restart while meter session open: next interaction errors explicitly, no
     phantom results (/api/meter/session/stop, daemon.pm state).
B-07 Open UI before app ready (cold boot race): graceful not-ready + self-recovery.
B-08 Long soak 8h+ with periodic interaction: memory growth, log spam filling SD,
     stale timestamps rendered as live.


3. SUITE C - INPUT VALIDATION & HOSTILE DATA (scripted where possible)
C-01 Numeric fields: 0, negative, huge, non-numeric, empty, decimals-for-int, boundary
     values. Explicit error, never silent clamp or 500. Bits-style params: 8/10/12
     valid, 11/7/16 rejected (PGCalibrationMath.pm:218 - reachable only via POST bodies,
     not GET; see mutating pass note in Sec 10).
C-02 Text inputs: unicode (accented/CJK), spaces, quotes, ../, shell metachars. Perl
     command-injection surface (command.pm) specifically. Automated GET-side status:
     CLEAN 2026-09-09 (BASELINE_FINDINGS.md) - no leak, structured JSON errors.
C-03 ICC profile names: collision/overwrite confirm, spaces-only, max length,
     case-only difference. Download/measure routes refuse traversal with distinguishable
     JSON errors (verified). Delete/rename paths: OPEN.
C-04 Uploads (/api/ccss/upload, /api/diagnostic/upload, /api/3d-lut/import,
     /api/lg/3d-lut/upload, /api/system-backup/import): malformed, wrong extension,
     huge, zero-byte -> clear error, no crash. OPEN: needs crafted multipart POSTs,
     bench only.
C-05 Double-click every submit/save button: no duplicate profiles, no double meter
     sessions, no double-fired commands.


4. SUITE D - PLATFORM / TARGET MATRICES
D-01 Pi 4 (pi4-biasi): Suite A; chartread and PGEN_RELEASE_PI4_ONLY_BINARIES present.
D-02 Pi 5 (pi5-bookworm-armhf): Suite A; release manifest checker --target output
     attached proving no Pi4-only binaries in payload.
D-03 Pi 5 CMA extremes (64 MB and 512 MB via vc4-kms-v3d cma-): heaviest pattern at
     largest resolution renders, or legible refusal. Never black-screen.
D-04 gpu_mem on Pi 5: no effect, and UI (CMA card, commit 5e0f130d) shows the CMA pool,
     not a gpu_mem-derived number.
D-05 HDMI hotplug while running: UI reflects no-display; recovery on replug incl. EDID
     change (different resolution/color capabilities).
D-06 HDR paths (mesa_hdr.patch, dovi_pattern_shader in both ofxRPI4Window flavors):
     HDR pattern modes on Pi 5; SDR unaffected by HDR toggle flip and vice versa.
     Dovi binary selection is a config branch (command.pm:562: ${pattern_generator}.dv
     when dv_status=1 + metadata) - both branches exercised per target.
D-07 Windows/macOS bundles carry COPIES of frontend/Perl files: any such change ->
     rebuild via build-*-package.sh and smoke Suite A + touched screen in the bundle.
D-08 Image/OTA gates: WiFi credentials stripped (fresh image verified), usrmerge
     symlinks intact after staging (tar --keep-directory-symlink).
D-09 Renderer in the payload is the committed one: sha256 of usr/sbin/PGeneratord and
     PGeneratord.dv inside the Pi 4 OTA tarball and image equals binary_sha256 in
     usr/sbin/PGeneratord.provenance (t/renderer_binary_provenance.t pins the repo
     side). Local image tooling that overlays a prebuilt rootfs renderer (e.g.
     tools/image-targets/pi4-biasi/rootfs/usr/sbin) must be refreshed first; 2.13.0-
     2.14.3 shipped the 2.12.1 renderer this way. Pi 5: same check against the Pi 5
     renderer the payload carries.


5. SUITE E - ICC PROFILE FLOW (icc_profile.js / PGICCProfile.pm / measurement changes;
quarterly otherwise)
E-01 Full create flow with real meter: measure -> build -> save -> apply -> re-measure;
     visible delta matches expectation.
E-02 Abandon at each step (close tab, quit, kill app): no half-written profile files,
     no stuck building state blocking the next attempt.
E-03 List/preview/delete profiles: empty list, delete applied profile, delete last,
     delete + re-create same name.
E-04 Applied profile survives reboot and re-applies (or documented manual step works).
E-05 Hand-drop corrupt profile into profile dir: listed invalid or visibly skipped;
     no boot crash.
E-06 Meter absent / wrong model selected: explicit actionable error, no eternal spinner.
E-07 Display mode switch mid-measurement: behavior defined and safe.


6. SUITE F - WEBUI LEGENDS (webui.pm or any webui-*.js change)
F-01 Stale-cache after upgrade: old cached webui-app.js + new backend is worst-case;
     verify cache-busting/version banner. (JS calls /api/health; Perl liveness route is
     /api/ping - confirm what each serves so health checks dont drift again.)
F-02 Multiple tabs same browser: no competing pollers fighting (UI polls
     /api/meter/series/status etc.).
F-03 Browser variety: on-Pi browser, desktop Chrome/Firefox, iOS Safari, Android Chrome.
F-04 Phone-width viewport full UI; anything clipped or <44px touch target is a finding.
F-05 Non-UTC locale + DST boundary: status/log timestamps sane.
F-06 Special chars in hostname/profile names propagate through status pages, downloads,
     generated filenames.
F-07 Encoding: no mojibake from Perl responses (watch Wide-character class bugs).
F-08 Console-zero rule: after EVERY screen, browser console empty of errors. Release gate.
F-09 Degrade each polled subsystem (meter, renderer): status cards show explicit error,
     never stale-green/blank. Slow-route half of this verified as needed: see B-01.
F-10 Noise-floor control cycle (VERIFIED against extracted real handlers in a headless
    DOM 2026-09-16; re-run on the live page per release): with RGB bal on Perceptual and
    a greyscale series loaded, walk the full cycle checking field value, preset highlight
    (accent + aria-pressed), × visibility, and hint visibility after EVERY step:
    F-10.1 tap preset .5 -> field 0.5, .5 highlighted, x visible, band drawn.
    F-10.2 tap .5 again -> Off (field empty, highlight and band gone).
    F-10.3 type 20 + Enter -> field snaps to 10 (display==applied), no preset highlighted.
    F-10.4 Escape in field -> Off. F-10.5 type garbage + blur -> Off, pref persisted empty.
    F-10.6 switch RGB bal to Absolute with floor on -> amber hint appears; click hint ->
    Perceptual restored, floor value kept, hint hidden. F-10.7 on a touch device: all row
    targets >=44px (pointer:coarse block in webui-theme.css) and the row reflows without
    clipping at 390px width.


7. SUITE G - UPGRADE & ROLLBACK (every release)
G-01 In-place update from previous release on real hardware: user data preserved; UI
     works without clearing browser cache (see F-01).
G-02 Rollback: old UI against data written by new version does not crash.
G-03 Config migration: added/renamed keys auto-migrate, or refuse-start with message.
G-04 Fresh-flash: brand-new image, first boot, first webui open, full Suite A, zero setup.


8. OBSERVABILITY & EVIDENCE RULES
8.1 Failure filed with: steps, expected/actual, image build ID, Pi model, display
    model/resolution/refresh, photo of BOTH UI and physical display.
8.2 Run log (date, commit SHA, hardware, tester, suites, pass/fail per ID). Release is
    valid only with Suite A + change-class suites + G green for that SHA. API-level
    regression is scripted (Sec 10); its baseline diff is part of the release evidence.
8.3 Waivers are recorded, not silent: waived cases get a reason + date in the run log
    (precedent: 4 slow-route WARNs waived by-design 2026-09-09, converted to B-01 case).


9. CHANGE CLASS -> REQUIRED SUITES
- webui.pm (Perl backend):        A + B + C + F01 + G
- command.pm / client.pm:         A + B02 + B04 + C02 + C05
- webui-*.js frontend:            A + B05 + F(all) + D07 + F01
- icc_profile.js / PGICCProfile:  A + E(all) + C03
- lg.pm / webui-lg.js:            A + B01(slow-route cases) + LG bench routes exercised
                                  (/api/lg/* incl. picture-settings/set, 3d-lut, autocal)
- src/ C++ engine / ofxRPI4Window: A on BOTH targets + D01-D06 + D08
- patches (drm_vc4, mesa_hdr):    D06 + D03/D04 + full display matrix (hotplug, modes)
- image/OTA tooling:              D08 + G(all)
- release manifest/target config: D01 + D02 + G01


10. SCRIPTED ASSETS (tools-testing/, local-only like tools/ - do not commit to
published payload trees without checking AGENTS.md ignore rules)
- pgen_endpoint_fuzz.py: stdlib-only read-only API fuzzer. Safety model: mutating
  routes skipped unless --include-mutating; shell-metachar payloads never sent to
  mutating endpoints; sequential traffic + sleep; pre/post health snapshot of
  /api/ping with SERVICE-DEGRADED exit=2. Self-tested (fake_pgen_app.py).
- pgen_endpoints.txt: typed route file derived from real route map. /api/reboot and
  /api/power must never enter any mutating pass. Known conservative false-skips:
  GET /api/meter/stop/status, /api/lg/scan/saved (substring guard).
- rgb_balance_formula.test.js: characterization suite for the webui RGB balance
  formulas (Perceptual/Absolute/Chromaticity, gain curve, plot-cache key, the
  selectable meterRgbBalanceNoiseFloor input incl. its html options, the
  Flat/Empirical noise-floor mode (per-step k·σ from repeat-reading scatter,
  pre-gain samples, fallback to the flat value), the noise-analysis-context
 fingerprint (formula|grey-ref|gamma|gamut|whitept|tech|ccss — the identity/
 view keys a re-derivation cannot reconcile) plus the ROUND-7 raw-sample
 store: repeat readings are stored as raw XYZ and each sample's pre-gain
 deviation is re-derived under the current common white/black reference at
 judgment time, so ordinary reference drift reconciles instead of wiping
 (run-the-series-twice accumulates) while identical patches never fabricate
 a floor across target/reference edits; the
 sandbox's meterLiveRgbData has a __realCalc branch that runs the REAL
 balance math — stubbed balance math is what hid the round-4/5 fabrications),
  the
  Perceptual-only availability gating, the live-bar noise flags, and the
  within-noise dim + hover-title in the HTML live-RGB columns
  meterGreyTvColumnHtml. Brace-extracts the live functions from webui-app.js
  AND webui-workspace.js (no copies, no hard-coded lines) and stubs
  collaborators. Module-level const/let the extracted functions close over
  must be RESTATED in the sandbox stubs (record's try/catch silently swallows
  the ReferenceError otherwise), and STUBS is String.raw — no backticks in
  its comments. In-repo twin: t/js/rgb_balance_formula.js + t/rgb_balance_
  formula.t (CI); keep both in step when editing either. Run: node
  tools-testing/rgb_balance_formula.test.js. If it fails after editing the
  balance math, the change must be reflected in the tests deliberately.
- Baseline to diff against: BASELINE_FINDINGS.md (2026-09-09, read-only pass clean,
  traversal refused with structured errors).
- OPEN follow-ups: multipart upload tests (C-04); POST-body enum/bit validation
  (C-01 deep path via /api/icc/build, /api/pattern); /api/3d-lut/cube traversal once
  bench has a .cube; trailing-slash route variants (/api/wifi/ap/) vs exact-match eq
  dispatch (likely 404 = fine, confirm frontend never builds them).

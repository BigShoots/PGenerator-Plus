# Working on PGenerator+

This guide applies to the whole repository. Follow more specific `AGENTS.md` files when present, and the user's current instructions. Keep this file accurate when changing an entry point, build requirement, compatibility contract, or validation workflow.

## Working agreement

- Complete authorized implementation and relevant validation. Make routine, reversible choices without repeated permission requests; ask only about consequential missing information or actions outside the agreed scope.
- Start with `git status --short`. Preserve unrelated edits, untracked notes and local artifacts. Do not reset, clean, stage or commit other work as incidental cleanup.
- Read affected code and callers first. Prefer scoped `rg`/`rg --files` searches; use `git ls-files` to distinguish tracked files from local support material.
- Keep changes focused: avoid unrelated refactors, formatting, dependency upgrades and generated-file churn. Fix defects at their owning layer.
- Parallelize bounded independent work when useful, avoid overlapping edits, and review the combined diff.
- Report changes, actual checks and remaining gaps. Distinguish syntax, behavior, packaging and physical-device validation.
- Deployments, restarts, TV calibration, profile installation, flashing and publishing must fit the authorized task and identified target. Existing authorization remains valid. Prepare concrete changes and checks before seeking any additional approval.

## What this repository is

PGenerator+ is a Raspberry Pi display calibration appliance: a precision HDMI pattern renderer, Perl control service and web UI, meter/AutoCal workers, and desktop ICC tools. This repository is primarily a **target filesystem overlay**. Its `etc/`, `usr/`, `var/`, and `lib/` trees become paths under `/` on the appliance. Install this overlay only in the intended appliance environment.

The checked-in Pi 4 runtime targets BiasiLinux and ARM hard-float. Release tooling also describes a Pi 5 Bookworm armhf target supplied through external hardware inputs. Do not infer that arbitrary Raspberry Pi models, current Raspberry Pi OS, or desktop Linux can run the shipped binaries.

There is no root package manager, general-purpose development server, or universal `make test` command. Node is useful for JavaScript validation; the appliance UI has no npm build pipeline. The desktop deploy console is a separate application.

### Repository map

| Path | Responsibility |
| --- | --- |
| `README.md` | Product behavior, protocols, installation, API overview, historical build instructions |
| `docs/calibration-math-architecture.md` | Math ownership, numerical policies, measurement/series contracts |
| `etc/init.d/PGenerator`, `etc/init.d/rcPGenerator` | Appliance startup, runtime directories, permissions, renderer/service lifecycle |
| `etc/PGenerator/PGenerator.conf`, `etc/PGenerator/lut.txt` | Factory configuration and LUT defaults; installed copies are device state |
| `usr/sbin/PGeneratord.pl` | Perl daemon entry point, module loading, threads and startup |
| `usr/share/PGenerator/daemon.pm`, `client.pm`, `resolve.pm`, `discovery.pm` | Network protocols, clients and discovery |
| `usr/share/PGenerator/command.pm`, `conf.pm`, `variables.pm`, `pattern.pm` | Configuration, signal normalization, hardware control, renderer lifecycle and pattern IPC |
| `usr/share/PGenerator/webui.pm`, `webui*`, `icc_profile.*`, `hcfr_chc.js` | HTTP/JSON service, page assembler and browser source files |
| `usr/share/PGenerator/lg.pm`, `usr/sbin/pgenerator-lg` | LG TV orchestration and communication |
| `usr/bin/meter_session.sh`, `meter_series.sh`, `spotread_wrapper.sh`, `spotread_measure.py` | Meter process lifecycle, patch sequences and measurement transport |
| `usr/bin/meter_lg_autocal.pl`, `meter_lg_3d_autocal.pl`, `meter_lg_dv_profile.pl` | Calibration workers |
| `usr/share/PGenerator/PG*.pm`, `usr/bin/pgen_*.py` | Shared math, signal, measurement, series and run-state contracts |
| `usr/share/PGenerator/PGICCProfile.pm`, `usr/bin/icc_*.py` | ICC workflows, profile creation, refinement and packaging |
| `src/pattern_generator/`, `src/ofxRPI4Window/` | C++/openFrameworks renderer and DRM/KMS/EGL/GBM/HDR/DV backend |
| `src/lut_solver/`, `src/common/pgen_colour_math.h` | Native LUT solver and shared C color primitives |
| `usr/share/PGenerator/icc-companion-src/`, `icc-companion/` | Desktop Patch Companion/Profile Loader source and shipped platform payloads |
| `usr/bin/PGenerator_cmd.pl`, `etc/sudo/sudoers.d/PGenerator` | Privileged command boundary |
| `usr/sbin/pgenerator-update`, `usr/share/PGenerator/update-migrations.d/` | On-device OTA updates and cumulative migrations |
| `tools/build_pgenerator_plus_*.sh`, `tools/runtime/` | Image/OTA assembly and shared runtime packaging policy |
| `github-deployer/server.py`, `github-deployer/static/` | Local GitHub snapshot comparison and SSH deployment console |
| `third_party/pi4-numpy-runtime/`, `vendor/ArgyllCMS_ICC4.4` | Pinned numerical-runtime provenance and ArgyllCMS Git submodule |
| `usr/share/PGenerator/ccss/` | Shipped meter correction profiles |

In rows listing several filenames, sibling filenames share the first file's directory.

### Read these before the corresponding work

- Browser changes: [Web UI fragment rules](usr/share/PGenerator/README-webui-fragments.md), `.editorconfig`, `.gitattributes`, and `webui_html()` in `webui.pm`.
- Calibration or color changes: [Calibration maths architecture](docs/calibration-math-architecture.md) and the owning modules below.
- Updates: [Migration contract](usr/share/PGenerator/update-migrations.d/README), both builders, and `tools/runtime/pgen_release_runtime.sh`.
- Numerical-runtime changes: [Pi 4 NumPy provenance](third_party/pi4-numpy-runtime/README.md).
- Desktop ICC changes: [ICC Tools behavior](usr/share/PGenerator/icc-companion-src/README.txt), [Profile Loader behavior](usr/share/PGenerator/icc-companion-src/PROFILE-LOADER-README.txt), and `usr/bin/icc_companion_package.py`.
- Deploy console changes: [Deployer overview](github-deployer/README.md), platform READMEs, and the implementation in `server.py`.

Documentation contains historical references. Verify paths and commands against this checkout; implementation and tracked build policy determine actual behavior. In particular:

- `t/` and `tests/` are ignored and absent from the tracked checkout. Named TAP, conformance and golden tests in existing docs are not automatically available. There are no tracked GitHub Actions workflows; `.github/` currently contains issue templates.
- The current Web UI archive checker is `tools/check_webui_package.pl`, not the README's `t/check_webui_package.pl`.
- Release support files and hardware target bundles are missing; see the release prerequisites below. Some README-linked kernel/build/import scripts are also absent.
- `github-deployer/` is tracked. Its staged Perl checks currently run on the Pi, despite older README text saying they run locally.
- Read the release version from `usr/share/PGenerator/version.pm`; do not copy historical version numbers from README prose.

## Runtime and compatibility rules

### Language and platform boundaries

- Preserve Python 3.5 compatibility in appliance Python scripts. Some scalar/meter helpers explicitly retain Python 2.7 support; retain that where documented. Avoid newer syntax and standard-library APIs unless the deployment runtime changes deliberately. The desktop deployer uses a separate modern Python runtime.
- Pi 4 numerical packages are pinned to CPython 3.5, ARMv7 hard-float, NumPy 1.18.5 and the documented ATLAS runtime. Preserve checksums, licenses, selected-file manifests and ABI checks. Pi 5 uses Bookworm's NumPy and must not receive Pi 4 CPython extensions.
- Legacy Perl `.pm` files use `do` and a shared global namespace with ordered loading. `PGMath`, `PGCalibrationMath`, `PGSignalCode` and `PGMeterReading` are strict packages with exports; `PGAutoCalRun` uses qualified calls. `PGICCProfile.pm` deliberately stays in `package main` for shared WebUI helpers. Preserve these boundaries; do not blanket-add packages/strictness or reorder loading.
- Respect each shell script's shebang. Bash release tooling is not POSIX shell; appliance `/bin/sh` scripts must stay compatible with their target shell. Do not assume the development host's utilities match BiasiLinux or GNU/Linux.
- Preserve executable bits and tracked symlinks. Do not replace binary files with source text, host executables, or Git LFS pointer files.
- Retain license headers and bundled notices. Treat ArgyllCMS, SDL, fonts, firmware and CCSS assets as separately sourced material, not arbitrary generated files.

### Protocol, pattern and HDMI contracts

- Preserve port 85 pattern/ColourSpace compatibility, Calman control on 2100, discovery on UDP 1977, and Resolve's **outbound** client connection (default 20002). Consult `variables.pm` and routing code for the remaining ports and defaults.
- Trace protocol changes through parsing, signal normalization, config persistence, pattern serialization and renderer consumption. Preserve command terminators, responses, aliases and external units. For example, classic `MIN_LUMA` wire values use 0.0001-nit units while config stores nits.
- Pattern source precision, HDMI transport depth, RGB/YCbCr range and display transfer function are separate concepts. Keep `BITS`, `SOURCE_MAX`, `SOURCE_RANGE`, HDR/DV flags and `signal_mode` coherent through existing normalizers.
- Standard Dolby Vision and LLDV are separate transports. Preserve standard DV's ordinary 8-bit client requests and internal higher-precision conversion; clients do not send the renderer's internal `SOURCE_MAX` field.
- The daemon writes `/var/lib/PGenerator/running/operations.txt`; `/var/lib/PGenerator/operations.txt` is the compatibility symlink. Preserve complete-file publication, atomic rename and DSL framing, including `END`. A partially written or stale pattern can invalidate a measurement.
- Preserve renderer startup ordering, DRM ownership, readiness checks and metadata handling. `pgsethdr` is a pre-start fallback; the running renderer owns its HDR metadata. Do not introduce simultaneous DRM-master probes or metadata writers during renderer initialization.

### Concurrency and process lifecycle

- Keep the daemon's pre-start `MALLOC_ARENA_MAX=1` handling and its `perl -c` guard. It addresses a fork/thread allocator deadlock on the Pi 4 runtime.
- `webui.pm` separates serialized general, renderer, TV and meter work from fast/concurrent and compute work. Classify new routes by the resources they touch; cross-device operations need appropriate serialization. A GET request is not automatically concurrent-safe.
- Preserve conservative route allowlists, shared or file-backed state, bounded queues, timeouts, cancellation and stale loopback-pattern rejection. Perl ithreads clone ordinary state; do not assume a normal hash is shared between workers.
- Keep LG helper single-flight locking and meter ownership interlocks. Manual reads, series and calibration workers must not contend for the same physical instrument.
- Preserve request/session/generation identities, matching acknowledgments, atomic status updates, and cleanup after stop/failure. Ensure obsolete work cannot publish results into a newer run. Wait for the intended patch to be presented and settled before reading the meter.
- Keep liveness and status polling responsive during slow TV calls and profile computation. Run diagnostics must remain non-fatal to calibration, as documented in `PGAutoCalRun.pm`.

## Calibration and numerical correctness

Color correctness takes priority over cleanup or speed. Reuse the owner for each runtime; do not copy equations into another caller:

| Contract | Owner |
| --- | --- |
| Python scalar color math, transfer functions, matrices, Lab and Delta E | `usr/bin/pgen_colour_math.py` |
| Perl numerical primitives | `usr/share/PGenerator/PGMath.pm` |
| Calibration targets, gamuts, tolerances and smoothing | `usr/share/PGenerator/PGCalibrationMath.pm` |
| Finite meter records to XYZ | `usr/share/PGenerator/PGMeterReading.pm` |
| Signal percentages to emitted codes | `usr/share/PGenerator/PGSignalCode.pm` |
| Meter parsing and averaged result derivation | `usr/bin/pgen_meter_result.py` |
| Browser color equations | `usr/share/PGenerator/webui-colour-math.js` |
| Native hot-path primitives | `src/common/pgen_colour_math.h` |

- Preserve finite-value checks, units, normalization, gamut/white-point selection, clipping, quantization, rounding and operation order. Make boundary policies explicit at the caller.
- Deliberate differences are contracts: Perl/browser PQ encoding returns exact zero at black; Python/C retain the transfer-function floor. BT.1886 policies and XYZ-to-Lab floors also differ by workflow. Do not make implementations uniform without establishing the intended behavior and testing every affected consumer.
- Validated calibration-target context is immutable and persisted with schema/version information. Restoring a run must not silently adopt current UI settings.
- Server-returned series steps are the execution order. Browser previews, progress, retries, readings and recovery must preserve that order and stable reading identities. Maintain existing recovery-schema migration behavior.
- Low-light modes `a`, `aa`, and `aaa` select Argyll integration on the meter child. Software averaging short reads is not an equivalent replacement. Preserve requested sample count and the supported `pgen_meter_average.py` stdin-JSON/stdout-JSON alias contract.
- Keep dependency-free scalar imports lightweight. Do not make NumPy mandatory for simple meter helpers. ICC NumPy batches preserve explicit float64 reduction order; a BLAS rewrite can cross a serialized 16-bit boundary.
- The native LUT path must preserve the Perl fallback, canonical solve cache and output ordering. Keep `-ffp-contract=off`, `-fno-fast-math` and `-fno-unsafe-math-optimizations`; never use `-Ofast` or `-ffast-math` for this solver.
- ICC calibration placement, VCGT presence, CICP values, matrix/cLUT interpretation and native HDR presentation affect measured output. Preserve the selected pipeline; avoid adding a second correction or PQ conversion in the Companion. Keep patch presentation acknowledgments and unsupported-HDR failure behavior.
- Validate numerical changes with meaningful reference vectors and boundary cases: black/near-black, peak white, range endpoints, non-finite input, singular matrices, quantization boundaries and applicable SDR/HDR/DV policies. Measure performance against the same output contract rather than inferring a speedup from code movement.

## Browser editing rules

The UI is assembled from raw files by Perl into one HTML response. Edit the fragments, not a captured assembled page.

- Preserve raw UTF-8 bytes, LF endings, exact `__PG_*__` markers and splice order. Markers may live inside earlier fragments. Missing/empty files or unconsumed markers trigger the recovery page.
- Do not run Prettier, ESLint `--fix`, global tabs-to-spaces conversions or formatter-on-save across these files. Follow `.editorconfig` and `.gitattributes`; keep unrelated whitespace intact in `webui*`, `icc_profile.*` and `hcfr_chc.js`.
- `webui-colour-math.js`, `webui-app.js` and `webui-workspace.js` share one inline script and its strict-mode directive. Keep new code strict-mode clean, preserve initialization order, and check for collisions in that shared scope.
- Preserve DOM IDs, event bindings, API payloads, busy/stop/retry behavior and recovery state across browser/server changes. Use existing UI patterns and native controls; preserve keyboard access, labels and usable narrow-screen layouts.
- The assembled page is cached per worker. When validating changed fragments on a development Pi, account for daemon-side caching as well as browser caching.
- If the private/local `t/webui_html_golden.t` and `.sha256` files are present, run the test and update the expected hash only after reviewing an intentional page change. Do not invent a golden hash when the suite is absent. Never rerun the historical one-shot `t/slice_webui.pl` on the current layout.
- If adding or renaming a fragment, update the assembler, package checker's exact file set, byte-preservation rules and available tests together. The current checker expects ten fragments and four page assets.

## Local validation

Run commands from the repository root unless stated otherwise. Choose checks for changed areas; a documentation-only edit does not require hardware tests. The examples below do not launch the appliance. Syntax success does not establish runtime dependencies, browser behavior, numerical parity, or hardware correctness.

### Basic diff and syntax checks

```sh
git diff --check
git diff --stat

# Representative Perl checks; use the same include path for affected files.
perl -Iusr/share/PGenerator -c usr/sbin/PGeneratord.pl
perl -Iusr/share/PGenerator -c usr/share/PGenerator/webui.pm
perl -Iusr/share/PGenerator -c usr/bin/meter_lg_autocal.pl

# Check each changed JavaScript file, including deployer code when relevant.
node --check usr/share/PGenerator/webui-app.js
node --check github-deployer/static/app.js

# Select the interpreter from the shebang; -n parses without running the script.
bash -n tools/build_pgenerator_plus_ota.sh
sh -n src/lut_solver/build.sh

# Verify the committed solver source/binary pair without executing the ARM binary.
shasum -a 256 -c src/lut_solver/pgen_lut_solve.manifest
```

`perl -c` still processes `use`/`BEGIN` blocks. Inspect those before applying it to unfamiliar scripts. It does not execute normal `do`-loaded application code, so check changed modules individually. Missing host Perl modules are dependency failures, not proof of an application syntax defect; report the actual missing module. Do not start the daemon or rewrite absolute runtime paths to make a syntax check pass.

Parse changed appliance Python files without imports or bytecode output. Use a host interpreter accepting `feature_version=(3, 5)` for this grammar check, or validate with the target interpreter. Substitute the affected paths:

```sh
python3 - usr/bin/pgen_colour_math.py usr/bin/pgen_meter_result.py <<'PY'
import ast
import sys
import tokenize
for name in sys.argv[1:]:
    with tokenize.open(name) as handle:
        source = handle.read()
    ast.parse(source, filename=name, feature_version=(3, 5))
    print("Syntax OK:", name)
PY
```

For `github-deployer/server.py`, use its supported host Python and `ast.parse(source, filename=name)` without the appliance grammar restriction. A grammar check does not detect unavailable Python 3.5 APIs; validate changed API usage on the target interpreter where possible.

### Behavioral validation by area

| Change | Additional evidence to collect |
| --- | --- |
| Pure math, signal or meter parsing | Reference inputs/outputs and boundary cases; cross-language parity with explicit policy exceptions; target Python compatibility |
| Browser UI | Syntax-check affected fragments, inspect the assembled page and browser console, exercise affected controls and recovery; golden test if available |
| Worker/concurrency changes | Request ordering, stop/retry, stale results, busy interlocks and status responsiveness using an isolated harness; physical measurement checks when authorized |
| Renderer/HDR/DV | Correct-target compilation and artifact identity, startup/restart behavior, actual signal/InfoFrames and measurement on target hardware |
| ICC/Companion | Profile format and numerical output, selected-display identity, pairing/ack lifecycle, native HDR and installation behavior on affected desktop platforms |
| Update/package changes | Archive membership, modes/symlinks, state exclusions, migrations, skipped-version upgrade path and failure recovery in an isolated device/root |
| Deploy console | Python/JS/shell checks plus local UI smoke test; verify pinning/protected-path behavior before any authorized upload |

There is no tracked full test suite to run unconditionally. If a provisioned checkout contains tests named in the math/fragment docs, inspect their dependencies and side effects, then run the relevant subset. Do not claim `prove`, conformance, CI or hardware checks passed unless they actually ran. `.gitignore` excludes `t/`, `tests/` and most `docs/`; ensure any deliberately added tests/docs are included in the patch rather than silently ignored.

The tracked snapshot helper provides a behavioral check for the legacy/shared Delta E threshold contract. This wrapper checks both subprocess exit statuses as well as output equality:

```sh
python3 - <<'PY'
import subprocess
command = ["perl", "tools/benchmark/effective_de_limits_snapshot.pl", "."]
legacy = subprocess.check_output(command + ["legacy", "10000"])
shared = subprocess.check_output(command + ["shared", "10000"])
if legacy != shared:
    raise SystemExit("Effective Delta E limits differ")
print("Effective Delta E limits: 20,000 rows match")
PY
```

For measured math performance, use the existing driver with separate baseline/candidate trees:

```sh
tools/benchmark_math_consolidation.sh --baseline /path/to/baseline \
  --candidate "$PWD" --workload scalar-colour --runs 20
```

Both trees must contain the consolidated modules. Startup workloads require at least 30 pairs; other workloads require 20. Record output hashes alongside timings and memory; this benchmark is not a correctness suite.

## Builds and shipped artifacts

- **Renderer:** `make -C src/pattern_generator` uses openFrameworks 0.11.2 and the patched `ofxRPI4Window` addon in a suitable Pi 4 build environment. It needs the documented DRM/graphics dependencies, `/opt/openFrameworks` and VideoCore support. An arbitrary deployed appliance may lack the complete toolchain. The output is `src/pattern_generator/bin/PGeneratord`.
- **Display mirror:** `make -C src` builds `PGeneratorDisplayMirror`, not the renderer, and requires the VideoCore stack.
- **LUT solver, native validation:** `ZIG=/path/to/zig sh src/lut_solver/build.sh host` creates `src/lut_solver/build/pgen_lut_solve.host` for parity checks. Set `ZIG` to the installed Zig executable.
- **LUT solver, appliance artifact:** `sh src/lut_solver/build.sh` cross-builds the committed ARM binary at `usr/bin/pgen_lut_solve` and regenerates `src/lut_solver/pgen_lut_solve.manifest`. When changing its source or shared header, rebuild and validate the binary/manifest together. Never hand-edit hashes to hide drift; the current manifest hashes the solver source and binary, not every header dependency.
- **Desktop tools:** inspect the relevant platform packaging scripts and source documentation before rebuilding. Companion and deployer source edits do not automatically update shipped executables, installers, ZIPs or DMGs. Preserve their runtime libraries, pairing placeholders and licenses.
- **ArgyllCMS:** `vendor/ArgyllCMS_ICC4.4` is a Git submodule pinned by the superproject. Initialize the recorded revision only when needed; do not update to the remote branch tip as incidental setup. Preserve build/import provenance and target ABI when replacing shipped Argyll tools.

The shipped `usr/sbin/PGeneratord` and `PGeneratord.dv` are separately named authoritative runtime artifacts. Editing C++ does not update them. Do not assume validation of one mode establishes both; confirm the target's build/packaging path and report unrebuilt artifacts.

## Image, OTA and deployment workflows

### Release prerequisites and ownership

The tracked builders are `tools/build_pgenerator_plus_image.sh` and `tools/build_pgenerator_plus_ota.sh`. **This checkout alone cannot complete these builds.** Both require missing `tools/release_modes.sh` before parsing even `--help`, and reference missing `tools/check_release_manifest.sh`. The reviewed `tools/image-targets/<target>.env` manifests/hardware overlays are also absent. After shared support is provisioned, OTA and Pi 5 image builds require target manifests; Pi 4 image builds warn and can continue without one. Supply reviewed release inputs and record their identity; do not fabricate replacements or bypass gates.

Image building requires Linux, root, loop/mount/partition tools and a supplied compatible base image; it copies and overlays that base rather than building a distribution from scratch. OTA tooling requires a Bash version supporting `mapfile` and utilities supporting GNU-style tar/version-sort behavior. Provision these dependencies in the release environment.

Follow `tools/runtime/pgen_release_runtime.sh` for shared file ownership, runtime requirements and exclusions. Shared UI/calibration files originate in the top-level tree; hardware bundles supply target-specific renderer/backend files. Both builders deliberately restore top-level `usr/share/PGenerator/command.pm` for Pi 4 after the target overlay. Trace the staging order for any hardware change so a different input does not overwrite the edited file.

Keep Pi 4/Pi 5 ABIs separate. Preserve Pi 5 usrmerge: its OTA must not contain a root `/lib` entry. Standalone ICC desktop payloads are removed from appliance releases by shared policy and distributed separately; their presence in the source tree does not imply inclusion in an OTA.

### OTA invariants

- Build cumulative overlays of the complete current deployable runtime. Devices download the latest tarball and skip intermediate releases; a Git diff archive is insufficient.
- Updater compatibility is restricted to the same `MAJOR.MINOR` family; installed prerelease/beta versions disable OTA. Kernel/ABI family changes require the appropriate image workflow, not a relaxed version guard.
- Keep live settings and device-owned data out of OTA archives: `PGenerator.conf`, LUTs, per-display calibration state, first-boot flags and transient meter/session files. Ship defaults as `PGenerator.conf.dist` and merge missing keys without overwriting operator values.
- Tar overlays cannot delete files. Runtime removals/renames need version-prefixed, idempotent migrations under `usr/share/PGenerator/update-migrations.d/`. Retain earlier migrations for skipped releases. Execution covers `installed version < migration version <= target version` with `PG_UPDATE_FROM`, `PG_UPDATE_TO` and `PG_MIGRATION_VERSION` supplied.
- Do not execute migrations on the host as tests: most use absolute appliance paths. Use a supported isolated root or disposable target; do not assume every migration honors a root override.
- Preserve previous-release removal checks, archive validation, required runtime/ABI checks, failure cleanup, modes, ownership and symlinks. Do not use `--skip-prev-check` or `--allow-removals` to conceal missing migration work.
- Keep filesystem metadata files such as `._*` out of release archives; retain the builder's metadata-exclusion settings. Validate the Web UI payload with `perl tools/check_webui_package.pl /path/to/release.tar.gz` in addition to the provisioned release-manifest checks. Fragment completeness alone does not prove a valid release.
- Read and update `usr/share/PGenerator/version.pm` as part of an actual versioned release, with corresponding migration and release-note decisions. Routine fixes do not imply an unsolicited version bump or publication.

### Local console and device operations

`python3 github-deployer/server.py --no-open` starts the desktop console on `http://127.0.0.1:8766`; platform launchers are in `github-deployer/`. Opening the console is separate from scanning or modifying a Pi. Its actions use SSH and may replace runtime files or restart processes.

Preserve the console's loopback binding, exact-commit snapshot pinning, regular-file/path restrictions, protected device-state paths, symlink checks, ownership/mode preservation and replacement backups. Uploads and service restarts are separate actions. Its process-status response is not evidence that no calibration is active.

The console's protected set is narrower than OTA exclusions: `etc/BiasiLinux/BiasiLinux.FirstBoot`, `etc/PGenerator/PGenerator.conf`, `var/lib/PGenerator/operations.txt` and `var/lib/PGenerator/running/tmp/.gitkeep`. LUT/calibration files are not automatically protected; inspect selections accordingly.

For an authorized device change, establish the current target, running workload, installed version and rollback artifacts before disrupting services. Verify readiness after a restart and the actual affected behavior. Do not operate another Pi or TV because a default address or stored credential happens to exist.

Never execute appliance init scripts, meter workers, USB reset helpers, privileged commands, OTA `apply`, or disk tools on the development host for a smoke test. Even updater `check` can attempt clock correction. To read the checkout's version without device operation:

```sh
VERSION_FILE="$PWD/usr/share/PGenerator/version.pm" bash usr/sbin/pgenerator-update version
```

## Security and data handling

- Preserve the `pgenerator`/root boundary in `PGenerator_cmd.pl` and sudoers. Base64-encoded arguments are transport, not validation. Validate allowed commands, values, filenames and paths before privilege escalation; prefer argument-vector subprocess calls over interpolated shell commands.
- Treat HTTP input, TV responses, uploaded profiles/archives and GitHub snapshots as untrusted data. Preserve size limits, path containment, archive checks, pairing tokens and request ownership. Do not weaken these checks to simplify a feature.
- Keep credentials, pairing/client keys, Wi-Fi state, measurement histories, backups and device logs out of source patches and generated release payloads. Use synthetic, sanitized fixtures; do not print secrets while diagnosing a failure.
- Review changes to updater extraction, backup/restore, network/firewall configuration, subprocess handling and deployment selection at their trust boundary. Keep new privileged behavior narrowly scoped to the required operation.

## Code Review Rules

- Flag numerical changes that alter units, policy, clipping, rounding or ordering without evidence for affected runtime consumers.
- Flag worker changes that permit concurrent meter/TV access, stale patterns/results, lost cancellation or blocked liveness.
- Flag source changes that leave required shipped binaries, generated manifests, frontend fragments or release inputs inconsistent.
- Flag updates that overwrite device data, omit a required runtime asset/migration, mix target ABIs or bypass packaging checks.
- Flag protocol/API changes that break existing clients, persisted runs, browser recovery or Companion acknowledgment contracts.
- Prefer concrete defects with a reproducible trigger and consequence. Separate verified regressions from pre-existing limitations and untested concerns.

Before handing off, inspect the final diff and file modes, run relevant available checks, and state any missing dependencies, external inputs or hardware verification. Keep the working tree limited to the requested change and explain any remaining artifact rebuild or deployment work.

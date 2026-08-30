# Calibration maths architecture

Calibration arithmetic has one owner per runtime and explicit policy at each
boundary. Callers may select a policy, but they must not copy its equation.

## Runtime owners

| Contract | Owner | Consumers |
| --- | --- | --- |
| Finite scalar colour maths, XYZ derivation, CCT, transfer functions, Lab, CIEDE2000, matrices | `usr/bin/pgen_colour_math.py` | Meter-result and ICC tools |
| Perl transfer, Delta E, matrix and interpolation primitives | `usr/share/PGenerator/PGMath.pm` | Web server, AutoCal workers, TV process and meter simulator |
| Calibration targets, gamut records, tolerances and DPG smoothing | `usr/share/PGenerator/PGCalibrationMath.pm` | AutoCal workers, Web server and meter simulator |
| Finite meter record to XYZ | `usr/share/PGenerator/PGMeterReading.pm` | Both AutoCal workers |
| Signal percentage to emitted code | `usr/share/PGenerator/PGSignalCode.pm` | Server, AutoCal workers and DV profile worker |
| Browser colour equations | `usr/share/PGenerator/webui-colour-math.js` | Charts and pattern previews |
| Native hot-path primitives | `src/common/pgen_colour_math.h` | ICC companion and LUT solver |

The calibration-target context is immutable after validation. Persisted runs
carry its schema and version so a restored run cannot silently inherit the
current UI mode, transfer function or normalization policy.

## Measurement and series ownership

`pgen_meter_result.py` owns parse and average result derivation. The shell
workflows pass a numeric requested sample count; UI labels such as `a`, `aa`
and `aaa` are presentation and telemetry only.

Each series generation is normalised once into a fixed record stream. The
browser may build an immediate preview, capped at 4,096 lattice patches, but
the ordered steps returned by `/api/meter/series` are the execution record.
Progress, readings, recovery and retry use that server order. Browser reading
replacement uses a stable-key index while retaining its ordered array.

Browser recovery cache schema 2 stores each series independently. A mode owns
one reading set and observer records reference it. Dirty recovery state is
written during browser idle time, no later than five seconds after the first
dirty mutation or immediately at 25 successful readings. Completion, page
lifecycle boundaries and the start of another durable measurement operation
force a final write. The schema 1 reader remains only to migrate existing
local storage.

## Supported meter-average command

`/usr/bin/pgen_meter_average.py` is a permanent supported CLI alias for the
average command in `pgen_meter_result.py`. It accepts a JSON array on standard
input and returns one JSON reading on standard output. The environment
variables `PGEN_REQUESTED_SAMPLE_COUNT` and `PGEN_AVERAGE_MODE` remain part of
that command contract. The executable imports and dispatches in the same
Python interpreter; it does not launch a second helper process.

The alias stays in both release builders, the packaging test, Python 3.5
compatibility checks, command-level correctness tests and the paired startup
benchmark. This explicit support decision avoids guessing whether scripts
outside this repository adopted the executable name.

## Deliberate runtime differences

- Perl target evaluation retains named `bt1886_1d_ab`, `bt1886_chart_ab` and
  `bt1886_3d_root_blend_relative` policies because their operation order and
  black handling differ.
- Python finetuning retains a `ratio_floor_1e_minus_9` XYZ-to-Lab policy while
  the other runtimes use signed linear continuation.
- The ICC NumPy matrix batches retain explicit three-term float64 reductions.
  Replacing them with BLAS can change a value across a serialized 16-bit
  boundary.
- ICC `mat_inv`, Bradford and PQ wrappers remain because they add a tolerance,
  failure action or boundary policy. The 3D AutoCal `matrix_mul`,
  `matrix_mul_vec` and `matrix_inverse` aliases were removed because they added
  no policy.
- The native LUT solver retains the exact Perl fallback, canonical solve cache
  and explicit output-order transform. Unsupported models and failed helpers
  fail back to Perl rather than changing the output contract.

## Release inputs

The tracked checkout does not contain `tools/image-targets` manifests and
hardware overlays. The OTA builder and the Pi 5 image target fail with a named
missing-manifest error; the default Pi 4 image target warns and builds without
the hardware overlay. Release engineering must supply a reviewed
`tools/image-targets/<target>.env` and its declared `TARGET_OVERLAY_REL` from
the private hardware-input bundle before building an image or OTA package.

This is an external release input, not a generated calibration artefact. A
clean source checkout can run all maths, packaging-policy and Pi runtime tests,
but cannot produce a hardware image until that bundle is supplied and its
identity is recorded in the release evidence.

## Verification

The principal gates are `t/math_consolidation.t`, `t/math_conformance.js`,
`t/calibration_target_context.t`, `t/signal_code_policy.t`,
`t/meter_reading.t`, `t/meter_average.t`, `t/series_steps.t`,
`t/lg_3d_lut_native_parity.t`, `t/lg_3d_lut_preparation.t`,
`t/icc_numpy_parity.t`, `t/icc_companion_streaming.t`,
`t/webui_lattice_parity.t` and `t/webui_series_runtime.t`.

`tools/benchmark_math_consolidation.sh` records balanced A/B samples, output
hashes, timing and peak resident memory. Performance claims require those
measurements; code movement alone is not a speedup.

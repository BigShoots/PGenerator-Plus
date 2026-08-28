#!/usr/bin/env python3
"""Parity checks for the vectorised ICC mathematical primitives.

These tests deliberately compare the NumPy implementation with the scalar
expressions this PR replaced, recovered verbatim from the upstream main branch
into t/fixtures/scalar_reference.py. They use exact float64 equality wherever the
production path promises identical operation order, then repeat the comparison
after the production 16-bit quantisation step.

The one documented exception is pow: see within_one_ulp() below.
"""

from __future__ import print_function

import importlib.util
import os
import struct
import sys

import numpy as np


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "usr", "bin")
if BIN not in sys.path:
    sys.path.insert(0, BIN)


def load_source(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SCALAR = load_source(
    "pgen_scalar_reference",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "fixtures", "scalar_reference.py"))
BUILDER = load_source(
    "icc_profile_builder_parity",
    os.path.join(ROOT, "usr", "bin", "icc_profile_builder.py"))
COMPANION = load_source(
    "icc_companion_lut_parity",
    os.path.join(ROOT, "usr", "bin", "icc_companion_lut.py"))


checks = 0
ulp_checks = 0


def exact(label, actual, expected):
    global checks
    checks += 1
    actual = np.asarray(actual)
    expected = np.asarray(expected)
    if actual.shape != expected.shape or not np.array_equal(actual, expected):
        mismatch = np.flatnonzero(actual.ravel() != expected.ravel())
        first = int(mismatch[0]) if len(mismatch) else -1
        raise AssertionError("{} differs at flattened index {}: {!r} != {!r}".format(
            label, first,
            actual.ravel()[first] if first >= 0 else actual.shape,
            expected.ravel()[first] if first >= 0 else expected.shape))


# Exact equality is the contract these tests exist to defend, and it holds for
# everything the production paths are built from: +, -, *, /, comparisons,
# rint and the u16 serialisation are correctly rounded and give identical
# results on every platform.
#
# pow is the exception, in one specific direction. NumPy's vectorised
# transcendental loops are compiled in on Linux x86_64 and dispatched on
# AVX512_SKX; on a host that takes them, an ARRAY pow can land one ulp away
# from the SAME NumPy build's SCALAR pow, which falls back to libm. The checks
# below compare exactly those two entry points against one another, so on such
# a host they disagree by an ulp with nothing wrong in the code under test.
#
# That is a property of the runner, not of the production path. GitHub's
# runners are heterogeneous in precisely this feature, which is why the same
# commit passes on one and fails on another; the appliance is ARM with NumPy
# 1.18.5, which has no such loop, and the appliance is the platform the
# bit-exactness promise is made for. Observed on a GitHub runner as
# pq_to_nits(0.04045) giving 0.03742617499852619 from the batch path against
# 0.037426174998526185 from the scalar one -- one ulp, in the second pow.
#
# The allowance is deliberately narrower than "anything using pow". It covers
# only the two checks whose batch side is `array ** float`, the operation that
# actually diverged on the runner. _pow2 and the model error keep EXACT
# equality even though they also raise to a power, because the _pow2
# regression this suite has to catch -- dropping the array exponent, so NumPy
# takes its squaring fast path -- IS a one-ulp difference on about 0.15% of
# inputs. Allowing an ulp there would swallow the very mutation the check
# exists for, and the same runner that failed on PQ decode passed both of
# those. Anything larger than an ulp still fails everywhere.
def within_one_ulp(label, actual, expected):
    global checks, ulp_checks
    checks += 1
    ulp_checks += 1
    actual = np.asarray(actual, dtype=np.float64)
    expected = np.asarray(expected, dtype=np.float64)
    if actual.shape != expected.shape:
        raise AssertionError("{} shape differs: {} != {}".format(
            label, actual.shape, expected.shape))
    close = ((actual == expected)
             | (actual == np.nextafter(expected, np.inf))
             | (actual == np.nextafter(expected, -np.inf)))
    if not close.all():
        index = int(np.flatnonzero(~close.ravel())[0])
        raise AssertionError(
            "{} differs by more than one ulp at flattened index {}: "
            "{!r} != {!r}".format(label, index,
                                  actual.ravel()[index],
                                  expected.ravel()[index]))


def exact_bytes(label, actual, expected):
    global checks
    checks += 1
    if actual != expected:
        first = next(index for index, pair in enumerate(zip(actual, expected))
                     if pair[0] != pair[1])
        raise AssertionError("{} differs at byte {}: {} != {}".format(
            label, first, actual[first], expected[first]))


def values(count):
    # A platform-independent LCG gives edge-heavy and ordinary binary64 input.
    state = 0xC0FFEE
    result = []
    edges = [-0.25, 0.0, np.nextafter(0.0, 1.0), 0.04045, 0.5,
             np.nextafter(1.0, 0.0), 1.0, 1.25]
    result.extend(edges)
    while len(result) < count:
        state = (1664525 * state + 1013904223) & 0xffffffff
        result.append((state / 4294967295.0) * 1.5 - 0.25)
    return np.asarray(result[:count], dtype=np.float64)


positions = values(12000)
table = np.asarray([0.0, 0.001, 0.006, 0.018, 0.075, 0.22, 0.53,
                    0.81, 0.94, 0.985, 1.0], dtype=np.float64)
monotone_with_plateau = np.asarray(
    [0.0, 0.0, 0.004, 0.021, 0.021, 0.19, 0.51, 0.88, 1.0],
    dtype=np.float64)

exact("builder sample_table",
      BUILDER._np_sample_table(table, positions),
      [BUILDER.sample_table(table, value) for value in positions])
exact("builder invert_table",
      BUILDER._np_invert_table(monotone_with_plateau, positions),
      [BUILDER.invert_table(monotone_with_plateau, value)
       for value in positions])
exact("builder calibration inverse",
      BUILDER._np_calibration_to_profile_value(monotone_with_plateau, positions),
      [BUILDER.calibration_to_profile_value(monotone_with_plateau, value)
       for value in positions])

# A deliberately irregular 5^3 table exercises every trilinear corner and all
# six tetrahedral branch orders, including equal-fraction boundaries.
grid = 5
clut = np.asarray([
    ((index * 7919 + channel * 104729) % 65536) / 65535.0
    for index in range(grid ** 3) for channel in range(3)
], dtype=np.float64)
coordinates = values(18000).reshape(-1, 3)
ties = np.asarray([[0.125, 0.125, 0.125], [0.375, 0.125, 0.125],
                   [0.125, 0.375, 0.125], [0.125, 0.125, 0.375],
                   [0.375, 0.375, 0.125], [0.375, 0.125, 0.375],
                   [0.125, 0.375, 0.375]], dtype=np.float64)
coordinates = np.concatenate((coordinates, ties), axis=0)
exact("builder trilinear cLUT",
      BUILDER._np_clut_trilinear(clut, grid, coordinates),
      [BUILDER._sample_mft2_clut(clut, grid, row) for row in coordinates])
exact("builder tetrahedral cLUT",
      BUILDER._np_clut_tetrahedral(clut, grid, coordinates),
      [BUILDER._sample_mft2_clut_tetrahedral(clut, grid, row)
       for row in coordinates])

vectors = values(18000).reshape(-1, 3)
matrix = [0.81231, -0.09417, 0.2269,
          0.1538, 0.7732, 0.0730,
          -0.0181, 0.0867, 1.1142]
scalar_matrix = [[sum(matrix[row * 3 + column] * vector[column]
                      for column in range(3)) for row in range(3)]
                 for vector in vectors]
exact("builder fixed-order matrix",
      BUILDER._np_mat3_apply(matrix, vectors), scalar_matrix)

matrices = []
for index in range(6000):
    bump = (index % 97) / 10000.0
    matrices.append([1.1 + bump, 0.03, -0.02,
                     -0.04, 0.93 + bump, 0.05,
                     0.01, -0.06, 1.07 + bump])
entries = [np.asarray([matrix[index] for matrix in matrices])
           for index in range(9)]
inverses, valid = BUILDER._np_mat_inv3(entries)
exact("builder inverse validity", valid, np.ones(len(matrices), dtype=bool))
exact("builder explicit 3x3 inverse",
      np.stack(inverses, axis=1),
      [[value for row in BUILDER.mat_inv(
          [matrix[0:3], matrix[3:6], matrix[6:9]]) for value in row]
       for matrix in matrices])

unit = np.clip(positions, 0.0, 1.0)
within_one_ulp("builder PQ decode", BUILDER._np_pq_to_nits(unit),
               [BUILDER.pq_to_nits(value) for value in unit])
nits = unit * 12000.0 - 500.0
within_one_ulp("builder PQ encode", BUILDER._np_nits_to_pq(nits),
               [BUILDER.nits_to_pq(value) for value in nits])
exact("builder smoothstep", BUILDER._np_smoothstep(positions),
      [BUILDER.smoothstep(value) for value in positions])
expected_u16 = b"".join(
    np.asarray([max(0, min(65535, int(round(value * 65535.0))))],
               dtype=">u2").tobytes()
    for value in unit)
exact_bytes("builder u16 serialisation", BUILDER._np_u16_bytes(unit), expected_u16)

# Companion keeps its scalar inverse and Bradford setup. Only independent node
# evaluation is batched, with the same explicit three-term reduction order.
exact("companion fixed-order matrix",
      COMPANION.mat_vec_many([matrix[0:3], matrix[3:6], matrix[6:9]], vectors),
      scalar_matrix)
exact("companion table sample", COMPANION.table_sample(table, positions),
      [BUILDER.sample_table(table, value) for value in positions])

# The oracle is the pre-rewrite scalar bisection itself (t/fixtures/
# scalar_reference.py), not a searchsorted paraphrase of it: an oracle written
# with searchsorted shares the vectorised code's blind spot and cannot see a
# non-monotonic curve diverge.
non_monotonic = np.clip(
    (np.arange(4096) / 4095.0) ** 2.2
    + 0.02 * np.sin(9.0 * np.pi * np.arange(4096) / 4095.0), 0.0, 1.0)
dipped = np.asarray([0.0, 0.05, 0.004, 0.021, 0.30, 0.19, 0.51, 0.88, 1.0],
                    dtype=np.float64)
gamma_curve = (np.arange(4096) / 4095.0) ** 2.2
# NaN is in the sweep because the scalar clamp max(0.0, min(1.0, value))
# resolved it to 1.0 rather than propagating it.
sweep = np.concatenate((positions, np.linspace(0.0, 1.0, 8001),
                        np.asarray([np.nan, -np.inf, np.inf])))
for name, curve in (("monotone plateau", monotone_with_plateau),
                    ("monotone gamma", gamma_curve),
                    ("non-monotonic curv tag", non_monotonic),
                    ("dipped curv tag", dipped)):
    exact("companion curve inverse, {}".format(name),
          COMPANION.inverse_curve(curve, sweep),
          [SCALAR.companion_inverse_curve(curve, value) for value in sweep])

# End to end through the matrix fallback route, which is the only production
# caller of inverse_curve: a synthetic matrix-only profile (no B2A cLUT), whose
# tone curves arrive the way curve_values() actually produces them.
def _xyz_tag(x, y, z):
    return b"XYZ " + b"\0" * 4 + struct.pack(
        ">iii", int(round(x * 65536)), int(round(y * 65536)),
        int(round(z * 65536)))


def _curv_tag(entries):
    return (b"curv" + b"\0" * 4 + struct.pack(">I", len(entries))
            + b"".join(struct.pack(">H", entry) for entry in entries))


_ramp = [int(round(((index / 1023.0) ** 2.2) * 65535.0)) for index in range(1024)]
_dip = [min(65535, max(0, value + (900 if 300 <= index < 320 else 0)))
        for index, value in enumerate(_ramp)]
matrix_only_tags = {
    b"rXYZ": _xyz_tag(0.4360, 0.2225, 0.0139),
    b"gXYZ": _xyz_tag(0.3851, 0.7169, 0.0971),
    b"bXYZ": _xyz_tag(0.1431, 0.0606, 0.7141),
    b"rTRC": _curv_tag(_ramp), b"gTRC": _curv_tag(_dip), b"bTRC": _curv_tag(_ramp),
}
matrix_transform = COMPANION.MatrixTransform(matrix_only_tags)
pcs = values(9000).reshape(-1, 3) * 0.9
linear = COMPANION.mat_vec_many(matrix_transform.inverse, pcs)
exact("companion MatrixTransform.apply",
      matrix_transform.apply(pcs),
      [[SCALAR.companion_inverse_curve(matrix_transform.curves[channel],
                                       row[channel]) for channel in range(3)]
       for row in linear])

# The 65-cube build is evaluated NODE_CHUNK nodes at a time so the appliance
# does not have to hold a dozen live (N, 3) temporaries. Every stage is
# elementwise or per-row, so chunking must not move a single byte -- checked
# here on both signal routes at the real production grid.
adaptation = COMPANION.chromatic_adaptation(COMPANION.SOURCE_WHITE_D65,
                                            COMPANION.PCS_WHITE)
full_lattice = COMPANION.lattice(COMPANION.GRID, red_fastest=False)
for route, nits in (("sdr", 1.0), ("hdr10", 600.0)):
    whole = COMPANION.quantize_u16(matrix_transform.apply(
        COMPANION.source_xyz(full_lattice, route, nits, adaptation))).tobytes()
    chunked = b"".join(
        COMPANION.quantize_u16(block).tobytes()
        for block in COMPANION.corrected_nodes(
            matrix_transform, full_lattice, route, nits, adaptation))
    exact_bytes("companion {} build is chunk-invariant".format(route),
                chunked, whole)

for size in (2, 5, 17):
    slow = COMPANION.lattice(size, red_fastest=False)
    fast = COMPANION.lattice(size, red_fastest=True)
    scalar_slow = [[red / (size - 1.0), green / (size - 1.0),
                    blue / (size - 1.0)]
                   for red in range(size) for green in range(size)
                   for blue in range(size)]
    scalar_fast = [[red / (size - 1.0), green / (size - 1.0),
                    blue / (size - 1.0)]
                   for blue in range(size) for green in range(size)
                   for red in range(size)]
    exact("companion red-slowest lattice {}".format(size), slow, scalar_slow)
    exact("companion red-fastest lattice {}".format(size), fast, scalar_fast)

# --- Batch helpers with no leaf-primitive coverage --------------------------
#
# Everything above compares a batch twin with its scalar original. The helpers
# below are the ones that could be mutated -- axis swap, off-by-one, a changed
# quantisation divisor, a shortened Newton budget -- without any test noticing,
# because nothing compared them with anything.

exact("builder _pow2 against CPython x ** 2",
      BUILDER._pow2(positions), [SCALAR.pow2(value) for value in positions])
wide = np.concatenate((positions * 1e-8, positions * 1e6,
                       np.asarray([0.0, -0.0, 1.0, -1.0, 1e-160, 1e150])))
exact("builder _pow2 across magnitudes",
      BUILDER._pow2(wide), [SCALAR.pow2(value) for value in wide])

# Red is the SLOWEST axis, so a red/blue transposition leaves the neutral
# diagonal and every symmetric test cube looking correct. The chunk offsets
# matter as much as the whole walk: the callers solve a 65-cube in
# _BATCH_CHUNK-sized slices.
chunk = BUILDER._BATCH_CHUNK
for lattice_grid in (2, 5, 33, 65):
    walk = SCALAR.lattice_walk(lattice_grid)
    total = lattice_grid ** 3
    windows = [(0, total), (0, min(chunk, total)),
               (max(0, total - 7), total),
               (min(chunk, total), min(2 * chunk, total))]
    for start, stop in sorted(set(pair for pair in windows if pair[0] < pair[1])):
        red, green, blue = BUILDER._np_lattice_axes(lattice_grid, start, stop)
        exact("builder lattice axes grid {} nodes {}:{}".format(
                  lattice_grid, start, stop),
              np.stack([red, green, blue], axis=1),
              [list(node) for node in walk[start:stop]])

# 65535 against 65536 as the mft2 divisor is a 1.5e-5 shift: invisible to an
# eyeball, a whole 16-bit code across a B2A cLUT. The odd leading bytes make
# the offset argument carry weight.
mft2_entries = 4096
mft2_payload = b"\x5a\xa5" * 11 + b"".join(
    struct.pack(">H", (index * 7919) % 65536) for index in range(mft2_entries))
for mft2_offset in (22, 24):
    mft2_count = mft2_entries - (mft2_offset - 22) // 2
    exact("builder mft2 table read at offset {}".format(mft2_offset),
          BUILDER._np_mft2_tables(mft2_payload, mft2_offset, mft2_count),
          SCALAR.mft2_tables(mft2_payload, mft2_offset, mft2_count))

# The anchor scan is deliberately not searchsorted, so the oracle covers a
# non-sorted bound list as well as an ordinary rising one, and the probes run
# off both ends to pin the trailing return and the +1 index offset.
anchor_sets = (
    np.asarray([0.0, 12.0, 25.0, 50.0, 75.0, 100.0]),
    np.asarray([0.0, 0.0, 0.25, 0.25, 0.9, 1.0]),
    np.asarray([0.0, 40.0, 20.0, 90.0, 60.0, 100.0]),
    np.asarray([0.0, 1.0]),
)
probe_values = np.concatenate((
    np.linspace(-10.0, 110.0, 1201), np.linspace(-0.2, 1.2, 701),
    np.asarray([0.0, 12.0, 25.0, 100.0, 0.25, 0.9])))
for set_index, bounds in enumerate(anchor_sets):
    index, found = BUILDER._np_first_at_or_above(bounds, probe_values)
    scalar_scan = [SCALAR.first_at_or_above(bounds, value)
                   for value in probe_values]
    exact("builder anchor scan {} index".format(set_index),
          index, [pair[0] for pair in scalar_scan])
    exact("builder anchor scan {} trailing mask".format(set_index),
          found, [pair[1] for pair in scalar_scan])


# A forward model of multiplies and adds only -- no ``**``, no library call --
# so the scalar and batch spellings are the same binary64 operations in the
# same order and the Newton comparison can stay exact. The cubic channel terms
# flatten near black, which is where the solve stops converging quickly.
def _scalar_forward(device):
    red, green, blue = device[0], device[1], device[2]
    return [
        0.90 * red * red * red + 0.05 * green + 0.05 * blue + 0.20 * red * green * blue,
        0.30 * red + 0.60 * green * green * green + 0.10 * blue + 0.15 * green * blue * red,
        0.10 * red + 0.10 * green + 0.80 * blue * blue * blue + 0.12 * red * blue * green,
    ]


def _batch_forward(device):
    red, green, blue = device[:, 0], device[:, 1], device[:, 2]
    return np.stack([
        0.90 * red * red * red + 0.05 * green + 0.05 * blue + 0.20 * red * green * blue,
        0.30 * red + 0.60 * green * green * green + 0.10 * blue + 0.15 * green * blue * red,
        0.10 * red + 0.10 * green + 0.80 * blue * blue * blue + 0.12 * red * blue * green,
    ], axis=1)


newton_start = np.clip(values(1800).reshape(-1, 3), 0.0, 1.0)
newton_target = np.empty(newton_start.shape, dtype=np.float64)
# Three regimes on purpose. Nodes the model can reach converge and leave the
# active set early, which is the masked drop-out path. The two dark constant
# targets sit where the cubic terms flatten: those nodes are still taking
# accepted, above-threshold steps when the 14-iteration budget runs out, so
# their answer depends on the budget, the damping schedule and the line-search
# acceptance rule rather than only on a fixed point.
newton_target[0::3] = _batch_forward(
    np.clip(newton_start[0::3] * 0.8 + 0.1, 0.0, 1.0))
newton_target[1::3] = 0.05
newton_target[2::3] = 0.0005

exact("builder batched model error",
      BUILDER._np_model_error(_batch_forward, newton_start, newton_target),
      [SCALAR.model_error(_scalar_forward, list(device), list(target))
       for device, target in zip(newton_start, newton_target)])

exact("builder damped Newton solve",
      BUILDER._np_refine_newton(_batch_forward, newton_target, newton_start),
      [SCALAR.solve_node(_scalar_forward, list(target), list(device))
       for device, target in zip(newton_start, newton_target)])

# Guard on the guard above: unless some node's answer actually changes when
# the budget changes, the sweep cannot see an iteration-count mutation at all.
_budget_13 = np.asarray(
    [SCALAR.solve_node(_scalar_forward, list(target), list(device),
                       iterations=13)
     for device, target in zip(newton_start, newton_target)])
_budget_14 = np.asarray(
    [SCALAR.solve_node(_scalar_forward, list(target), list(device))
     for device, target in zip(newton_start, newton_target)])
_budget_sensitive = int(np.count_nonzero(
    np.any(_budget_13 != _budget_14, axis=1)))
checks += 1
if _budget_sensitive < 25:
    raise AssertionError(
        "only {} of {} Newton nodes are still iterating at the budget limit; "
        "the sweep cannot detect an iteration-count change".format(
            _budget_sensitive, len(newton_start)))

# The companion's own node quantisation, which is not the builder's
# _np_u16_bytes and had no oracle of its own.
exact_bytes("companion u16 quantisation",
            COMPANION.quantize_u16(positions).tobytes(),
            SCALAR.companion_u16_bytes(positions))

# The split is printed so that loosening another check is visible in the test
# output rather than only in the diff.
print("{} vector/scalar parity checks passed ({} exact, {} within one ulp)"
      .format(checks, checks - ulp_checks, ulp_checks))

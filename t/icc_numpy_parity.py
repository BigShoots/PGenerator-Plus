#!/usr/bin/env python3
"""Parity checks for the vectorised ICC mathematical primitives.

These tests deliberately compare the NumPy implementation with the scalar
expressions that were on Main. They use exact float64 equality wherever the
production path promises identical operation order, then repeat the comparison
after the production 16-bit quantisation step.
"""

from __future__ import print_function

import importlib.util
import os
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


BUILDER = load_source(
    "icc_profile_builder_parity",
    os.path.join(ROOT, "usr", "bin", "icc_profile_builder.py"))
COMPANION = load_source(
    "icc_companion_lut_parity",
    os.path.join(ROOT, "usr", "bin", "icc_companion_lut.py"))


checks = 0


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
exact("builder PQ decode", BUILDER._np_pq_to_nits(unit),
      [BUILDER.pq_to_nits(value) for value in unit])
nits = unit * 12000.0 - 500.0
exact("builder PQ encode", BUILDER._np_nits_to_pq(nits),
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

curve = monotone_with_plateau


def scalar_companion_inverse(value):
    value = min(1.0, max(0.0, value))
    high = int(np.searchsorted(curve, value, side="left"))
    high = min(len(curve) - 1, max(1, high))
    low = high - 1
    span = curve[high] - curve[low]
    fraction = (value - curve[low]) / span if span > 0.0 else 0.0
    return (low + min(1.0, max(0.0, fraction))) / (len(curve) - 1)


exact("companion curve inverse", COMPANION.inverse_curve(curve, positions),
      [scalar_companion_inverse(value) for value in positions])

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

print("{} exact vector/scalar parity checks passed".format(checks))

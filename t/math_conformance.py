#!/usr/bin/env python3
"""Conformance and ownership checks for the shared Python colour maths."""

from __future__ import print_function

import importlib.util
import json
import math
import os
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "usr", "bin")
if BIN not in sys.path:
    sys.path.insert(0, BIN)

import pgen_colour_math as math_core


def load_source(name):
    path = os.path.join(BIN, name + ".py")
    spec = importlib.util.spec_from_file_location(name + "_conformance", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


with open(os.path.join(ROOT, "t", "fixtures", "math_conformance.json")) as stream:
    FIXTURE = json.load(stream)


checks = 0


def close(label, actual, expected, tolerance=2e-12):
    global checks
    checks += 1
    scale = max(1.0, abs(float(expected)))
    if abs(float(actual) - float(expected)) > tolerance * scale:
        raise AssertionError("{}: {!r} != {!r}".format(label, actual, expected))


def close_tree(label, actual, expected):
    if isinstance(expected, list):
        if len(actual) != len(expected):
            raise AssertionError("{} length differs".format(label))
        for index, value in enumerate(expected):
            close_tree("{}/{}".format(label, index), actual[index], value)
    else:
        close(label, actual, expected)


for row in FIXTURE["pq_encode"]:
    close("PQ encode {} nits".format(row["nits"]),
          math_core.pq_encode_nits(row["nits"], clamp_peak=True), row["signal"])
for row in FIXTURE["pq_decode"]:
    close("PQ decode {}".format(row["signal"]),
          math_core.pq_decode_nits(row["signal"]), row["nits"])

close_tree("matrix inverse",
           math_core.matrix3_inverse(FIXTURE["matrix"]), FIXTURE["inverse"])
close_tree("matrix vector",
           math_core.matrix3_vector_multiply(FIXTURE["matrix"], FIXTURE["vector"]),
           FIXTURE["product"])
close_tree("Bradford D65 to D50",
           math_core.bradford_adaptation(math_core.D65_WHITE,
                                         math_core.ICC_D50_WHITE),
           FIXTURE["bradford_d65_to_d50"])

# Independent Colour 0.4.7 reference values. The slightly wider bounds are
# deliberate: Main used seven-decimal RGB/XYZ coefficients and retaining them
# is required for serial parity. They remain much tighter than a colour-code
# threshold and make that compatibility decision visible.
for index, row in enumerate(FIXTURE["colour_0_4_7_ictcp_reference"]):
    actual = math_core.xyz_to_ictcp(row["xyz"])
    for component, expected in enumerate(row["ictcp"]):
        close("Colour ICtCp {}/{}".format(index, component),
              actual[component], expected, tolerance=2e-7)
for index, row in enumerate(FIXTURE["colour_0_4_7_delta_e_itp_reference"]):
    close("Colour Delta E ITP {}".format(index),
          math_core.delta_e_itp_xyz(row["first"], row["second"]),
          row["delta_e"], tolerance=2e-7)

builder = load_source("icc_profile_builder")
companion = load_source("icc_companion_lut")
finetune = load_source("icc_finetune")
repair = load_source("icc_b2a_repair")


def prior_finetune_de_itp(xyz_a, xyz_b):
    """The exact pre-consolidation expression, retained as a parity oracle."""
    xyz_to_rgb2020 = ((1.7166512, -0.3556708, -0.2533663),
                      (-0.6666844, 1.6164812, 0.0157685),
                      (0.0176399, -0.0427706, 0.9421031))
    rgb_to_lms = ((1688.0 / 4096, 2146.0 / 4096, 262.0 / 4096),
                  (683.0 / 4096, 2951.0 / 4096, 462.0 / 4096),
                  (99.0 / 4096, 309.0 / 4096, 3688.0 / 4096))

    def itp(xyz):
        rgb = [sum(xyz_to_rgb2020[row][column] * xyz[column]
                   for column in range(3)) for row in range(3)]
        lms = [sum(rgb_to_lms[row][column] * max(0.0, rgb[column])
                   for column in range(3)) for row in range(3)]
        encoded = [finetune.nits_to_pq(value) for value in lms]
        return (0.5 * encoded[0] + 0.5 * encoded[1],
                0.5 * (6610 * encoded[0] - 13613 * encoded[1]
                       + 7003 * encoded[2]) / 4096.0,
                (17933 * encoded[0] - 17390 * encoded[1]
                 - 543 * encoded[2]) / 4096.0)

    first, second = itp(xyz_a), itp(xyz_b)
    return 720.0 * math.sqrt(sum((a - b) ** 2
                                 for a, b in zip(first, second)))


state = 0xD17F1E
for index in range(512):
    values = []
    for _ in range(6):
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        values.append(state / 4294967295.0 * 400.0)
    actual = finetune.de_itp(values[:3], values[3:])
    expected = prior_finetune_de_itp(values[:3], values[3:])
    checks += 1
    if actual != expected:
        raise AssertionError("fine-tune dE ITP differs at case {}: {!r} != {!r}"
                             .format(index, actual, expected))

ownership = (
    ("builder matrix multiply", builder.mat_mul, math_core.matrix3_multiply),
    ("builder matrix vector", builder.mat_vec_mul, math_core.matrix3_vector_multiply),
    ("builder PQ decode", builder.pq_to_nits, math_core.pq_decode_nits),
    ("builder PQ encode", builder.nits_to_pq, math_core.pq_encode_nits),
    ("builder table sampling", builder.sample_table, math_core.sample_uniform_table),
    ("builder smoothstep", builder.smoothstep, math_core.smoothstep),
    ("companion matrix multiply", companion.mat_mul, math_core.matrix3_multiply),
    ("companion matrix vector", companion.mat_vec, math_core.matrix3_vector_multiply),
    ("finetune matrix inverse", finetune.mat_inv, math_core.matrix3_inverse),
    ("finetune matrix multiply", finetune.mat_mul, math_core.matrix3_multiply),
    ("finetune matrix vector", finetune.mat_vec, math_core.matrix3_vector_multiply),
    ("finetune table sampling", finetune.sample_values,
     math_core.sample_uniform_table),
    ("finetune smoothstep", finetune.smoothstep, math_core.smoothstep),
    ("repair matrix vector", repair.mmul_b, math_core.matrix3_vector_multiply),
    ("repair table sampling", repair.sample_curve,
     math_core.sample_uniform_table),
)
for label, actual, expected in ownership:
    checks += 1
    if actual is not expected:
        raise AssertionError(label + " is not owned by pgen_colour_math")

print("{} Python colour-math conformance checks passed".format(checks))

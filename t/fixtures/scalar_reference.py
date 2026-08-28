#!/usr/bin/env python3
"""Scalar originals of the primitives the PR replaced with NumPy batches.

PROVENANCE: every function below is copied from the pre-rewrite sources,
recoverable with

    git show upstream/main:usr/bin/icc_companion_lut.py
    git show upstream/main:usr/bin/icc_profile_builder.py

with only the changes needed to lift them out of their enclosing scope: a
renamed function, a forward model passed in rather than closed over, and a
local ValueError in place of the module's fail(). The arithmetic, the operand
order and the loop structure are untouched.

They exist so the vectorised replacements can be parity-checked against the
code they replaced rather than against a paraphrase of themselves -- an oracle
that reuses the new implementation's own idiom shares its blind spots. Nothing
in usr/ imports this module and nothing here may be "tidied": a cleanup that
changes an operation order silently weakens the gate it exists to provide.
"""

from __future__ import print_function

import struct


def _fail(message):
    raise ValueError(message)


# --- usr/bin/icc_companion_lut.py -----------------------------------------

def companion_inverse_curve(table, value):
    """upstream inverse_curve(), icc_companion_lut.py:102."""
    value = max(0.0, min(1.0, value))
    low, high = 0, len(table) - 1
    while high - low > 1:
        middle = (low + high) // 2
        if table[middle] < value:
            low = middle
        else:
            high = middle
    y0, y1 = table[low], table[high]
    fraction = 0.0 if y1 <= y0 else (value - y0) / (y1 - y0)
    return (low + max(0.0, min(1.0, fraction))) / (len(table) - 1)


def companion_u16_bytes(values):
    """upstream build()'s per-node quantisation, icc_companion_lut.py:319."""
    return b"".join(
        struct.pack(">H", int(round(max(0.0, min(1.0, value)) * 65535.0)))
        for value in values)


# --- usr/bin/icc_profile_builder.py ---------------------------------------

def mat_vec_mul(matrix, vector):
    """upstream mat_vec_mul(), icc_profile_builder.py:312.

    The sum() is upstream's, kept verbatim. It is a naive left-to-right
    accumulation on the appliance's CPython 3.5, which is what the batched
    three-term rows reproduce; CPython 3.12 sums floats with Neumaier
    compensation and can land one ulp away when the three terms span very
    different magnitudes. Callers here keep the terms comparably scaled so the
    two spellings agree, but a one-ulp difference seen only on a modern
    interpreter is that, not a defect in the production code.
    """
    return [sum(matrix[row][column] * vector[column] for column in range(3))
            for row in range(3)]


def mat_inv(matrix):
    """upstream mat_inv(), icc_profile_builder.py:316."""
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(determinant) < 1e-9:
        _fail("Measured primary matrix is singular")
    return [
        [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant],
        [(f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant],
        [(d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant],
    ]


def pow2(value):
    """CPython's ``x ** 2``, the exponent _pow2() has to reproduce."""
    return value ** 2


def lattice_walk(grid):
    """upstream cLUT node walk, icc_profile_builder.py:5157 and :2902.

    ``for red: for green: for blue:`` with node index
    ``((red * grid + green) * grid + blue) * 3`` -- red slowest, blue fastest.
    """
    axes = []
    for red in range(grid):
        for green in range(grid):
            for blue in range(grid):
                axes.append((red, green, blue))
    return axes


def mft2_tables(payload, offset, entries):
    """upstream mft2 table read, icc_profile_builder.py:2975 and :2980."""
    return [value / 65535.0 for value in struct.unpack_from(
        ">{}H".format(entries), payload, offset)]


def first_at_or_above(bounds, value):
    """upstream anchor scan, icc_profile_builder.py:3894 and :4049.

    Two spellings appear upstream and agree on the index they settle on:

        for anchor in range(1, len(bounds)):        # measured_xyz_at_code
            if value <= bounds[anchor]: ...
        return <trailing case>

        upper = 1                                   # measured_channel_xyz
        while upper < len(bounds) - 1 and bounds[upper] < value:
            upper += 1

    Both take the first index at or above 1 whose bound is >= value, and both
    stop at len(bounds) - 1. The second flag records whether the for/break
    spelling reached its trailing return.
    """
    for anchor in range(1, len(bounds)):
        if value <= bounds[anchor]:
            return anchor, True
    return len(bounds) - 1, False


def model_error(forward, device, target):
    """upstream model_error(), icc_profile_builder.py:5109."""
    actual = forward(device)
    return sum((actual[channel] - target[channel]) ** 2
               for channel in range(3))


def solve_node(forward, target, initial, iterations=14):
    """upstream solve_node(), icc_profile_builder.py:5114.

    ``forward`` is the closed-over model, passed in here instead. The
    iteration budget is upstream's literal ``range(14)`` as a defaulted
    argument, so a caller can demonstrate that a sweep really does still have
    nodes iterating at the limit -- a converged-only comparison cannot tell a
    14-iteration solver from a 13-iteration one.
    """
    device = list(initial)
    previous_error = model_error(forward, device, target)
    for unused in range(iterations):
        actual = forward(device)
        residual = [target[channel] - actual[channel] for channel in range(3)]
        step = 0.002
        columns = []
        for axis in range(3):
            probe = list(device)
            probe[axis] = (min(1.0, device[axis] + step)
                           if device[axis] < 0.998
                           else max(0.0, device[axis] - step))
            measured = forward(probe)
            denominator = probe[axis] - device[axis]
            columns.append([
                (measured[channel] - actual[channel]) / denominator
                for channel in range(3)
            ])
        jacobian = [[columns[column][row] for column in range(3)]
                    for row in range(3)]
        try:
            delta = mat_vec_mul(mat_inv(jacobian), residual)
        except ValueError:
            break
        scale = 1.0
        accepted = False
        while scale >= 1.0 / 128.0:
            probe = [max(0.0, min(1.0,
                         device[channel] + scale * delta[channel]))
                     for channel in range(3)]
            current_error = model_error(forward, probe, target)
            if current_error < previous_error:
                device = probe
                previous_error = current_error
                accepted = True
                break
            scale /= 2.0
        if (not accepted
                or max(abs(scale * value) for value in delta) < 0.000002):
            break
    return device

#!/usr/bin/env python3
"""Shared, dependency-free colour mathematics for PGenerator+ workers.

This module owns the scalar implementations used by the Python command-line
workers.  NumPy callers may use the exported constants, but keep their array
operations in the caller so importing this module never adds NumPy's startup
cost to small tools.

The ST 2084 constants come from SMPTE ST 2084.  The Bradford matrix is the
standard matrix used by ICC chromatic adaptation.  Cross-language fixtures in
``t/math_consolidation.t`` prevent the Python, Perl, JavaScript and C runtime
boundaries from drifting apart.
"""

from __future__ import division

import math


def _isfinite(value):
    """Python 2.7/3.5-compatible finite check for appliance entry points."""
    return not math.isinf(value) and not math.isnan(value)


PQ_M1 = 2610.0 / 16384.0
PQ_M2 = 2523.0 / 32.0
PQ_C1 = 3424.0 / 4096.0
PQ_C2 = 2413.0 / 128.0
PQ_C3 = 2392.0 / 128.0
PQ_PEAK_NITS = 10000.0

BRADFORD = (
    (0.8951, 0.2664, -0.1614),
    (-0.7502, 1.7135, 0.0367),
    (0.0389, -0.0685, 1.0296),
)
BRADFORD_INVERSE = (
    (0.9869929054667123, -0.14705425642099013, 0.15996265166373122),
    (0.43230526972339456, 0.5183602715367776, 0.0492912282128556),
    (-0.008528664575177328, 0.04004282165408487, 0.9684866957875501),
)

ICC_D50_WHITE = (0.9642, 1.0, 0.8249)
D65_WHITE = (0.9504559, 1.0, 1.0890578)

# BT.2124 / BT.2100 ICtCp matrices. These coefficients deliberately retain
# the precision used by the existing Python fine-tune acceptance metric.
ICTCP_XYZ_TO_RGB2020 = (
    (1.7166512, -0.3556708, -0.2533663),
    (-0.6666844, 1.6164812, 0.0157685),
    (0.0176399, -0.0427706, 0.9421031),
)
ICTCP_RGB_TO_LMS = (
    (1688.0 / 4096.0, 2146.0 / 4096.0, 262.0 / 4096.0),
    (683.0 / 4096.0, 2951.0 / 4096.0, 462.0 / 4096.0),
    (99.0 / 4096.0, 309.0 / 4096.0, 3688.0 / 4096.0),
)


def clamp(value, lower, upper):
    return max(lower, min(upper, value))


def finite_number(value, name="value"):
    """Return a binary64 value or reject booleans and non-finite input."""
    if isinstance(value, bool):
        raise ValueError("%s is not numeric" % name)
    try:
        value = float(value)
    except (TypeError, ValueError):
        raise ValueError("%s is not numeric" % name)
    if not _isfinite(value):
        raise ValueError("%s is not finite" % name)
    return value


def srgb_to_linear_unbounded(value):
    """Decode sRGB without clipping caller-owned extended-range values."""
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def srgb_to_linear_bounded(value):
    """Decode sRGB after clipping to the normalized signal domain."""
    return srgb_to_linear_unbounded(clamp(value, 0.0, 1.0))


def linear_to_srgb_unbounded(value):
    """Encode linear light without clipping caller-owned extended range."""
    if value <= 0.0031308:
        return value * 12.92
    return 1.055 * value ** (1.0 / 2.4) - 0.055


def linear_to_srgb_bounded(value):
    """Encode linear light after clipping to the normalized domain."""
    return linear_to_srgb_unbounded(clamp(value, 0.0, 1.0))


def cct_from_xy(x, y):
    """Estimate display CCT with McCamy's cubic and explicit failure rules.

    Finite input is required. Black, the equation's denominator singularity,
    and estimates outside the useful 1,000--25,000 K display range return 0.
    The function deliberately uses ``0.1858 - y``: reversing that denominator
    is a sign error that reports D65 near 4,664 K instead of about 6,505 K.
    """
    x = finite_number(x, "x")
    y = finite_number(y, "y")
    denominator = 0.1858 - y
    if y <= 0.0 or abs(denominator) <= 1e-15:
        return 0
    n = (x - 0.3320) / denominator
    estimate = 449.0 * n ** 3 + 3525.0 * n ** 2 + 6823.3 * n + 5520.33
    if not _isfinite(estimate) or estimate < 1000.0 or estimate > 25000.0:
        return 0
    return int(round(estimate))


def xyz_derived_fields(X, Y, Z, sum_tolerance=1e-15):
    """Derive xy, luminance, and CCT once from a finite XYZ triple.

    Negative finite components retain the historical arithmetic. If the XYZ
    sum is at or below the explicit tolerance, chromaticity and CCT are zero.
    """
    X = finite_number(X, "X")
    Y = finite_number(Y, "Y")
    Z = finite_number(Z, "Z")
    total = math.fsum((X, Y, Z))
    if total > sum_tolerance:
        x = X / total
        y = Y / total
    else:
        x = 0.0
        y = 0.0
    return {
        "x": x,
        "y": y,
        "luminance": Y,
        "cct": cct_from_xy(x, y),
    }


def pq_decode_nits(signal, clamp_signal=True, denominator_floor=1e-12,
                   nonpositive_result=None):
    """Decode an ST 2084 signal to cd/m2 with an explicit boundary policy.

    Production signal paths use the default bounded ST 2084 domain.  The
    optional policies exist only to preserve the historical behaviour of a
    caller that deliberately accepts values outside that domain.  A
    non-finite signal is a caller error: unlike the removed inline decoder
    (which clamped NaN to 1.0 and reported 10,000 nits) this propagates
    towards zero, and callers gate finiteness before decoding.
    """
    signal = max(0.0, signal)
    if clamp_signal:
        signal = min(1.0, signal)
    power = signal ** (1.0 / PQ_M2)
    denominator = PQ_C2 - PQ_C3 * power
    if denominator <= 0.0 and nonpositive_result is not None:
        return nonpositive_result
    denominator = max(denominator, denominator_floor)
    ratio = max(power - PQ_C1, 0.0) / denominator
    return PQ_PEAK_NITS * ratio ** (1.0 / PQ_M1)


def pq_encode_nits(nits, clamp_peak=False):
    """Encode absolute cd/m2 as an ST 2084 signal value.

    Zero is a deliberate divergence, not an oversight. This function and the C
    header evaluate the transfer function at 0 and return its true value,
    7.3095590257839665e-07; PGMath.pm's pq_encode_normalized and the browser's
    pqEncodeNormalized short-circuit non-positive input to exactly 0. Both
    behaviours are long-established in their own callers -- the Python and C
    paths feed 16-bit ICC tables where the floor value round-trips, the Perl
    and JavaScript paths feed pattern codes where a hard 0 is wanted -- and
    changing either would move shipped output. Each language pins its own zero
    in its own conformance test so the shared fixture's silence on the point
    is not mistaken for agreement.
    """
    nits = max(0.0, nits)
    if clamp_peak:
        nits = min(PQ_PEAK_NITS, nits)
    powered = (nits / PQ_PEAK_NITS) ** PQ_M1
    return ((PQ_C1 + PQ_C2 * powered)
            / (1.0 + PQ_C3 * powered)) ** PQ_M2


def xyz_to_ictcp(xyz, pq_encoder=None, fold_delta_t_weight=False):
    """Convert absolute XYZ to the standard ICtCp components."""
    if pq_encoder is None:
        pq_encoder = lambda value: pq_encode_nits(value, clamp_peak=True)
    rgb = matrix3_vector_multiply(ICTCP_XYZ_TO_RGB2020, xyz)
    rgb = [max(0.0, value) for value in rgb]
    lms = matrix3_vector_multiply(ICTCP_RGB_TO_LMS, rgb)
    lp, mp, sp = [pq_encoder(value) for value in lms]
    t_numerator = 6610.0 * lp - 13613.0 * mp + 7003.0 * sp
    t = ((0.5 * t_numerator if fold_delta_t_weight else t_numerator)
         / 4096.0)
    return (0.5 * lp + 0.5 * mp, t,
            (17933.0 * lp - 17390.0 * mp - 543.0 * sp) / 4096.0)


def delta_e_itp_xyz(xyz_a, xyz_b, pq_encoder=None,
                    legacy_fold_delta_t_weight=False):
    """BT.2124 colour difference between two absolute XYZ stimuli."""
    first = xyz_to_ictcp(
        xyz_a, pq_encoder=pq_encoder,
        fold_delta_t_weight=legacy_fold_delta_t_weight)
    second = xyz_to_ictcp(
        xyz_b, pq_encoder=pq_encoder,
        fold_delta_t_weight=legacy_fold_delta_t_weight)
    if legacy_fold_delta_t_weight:
        return 720.0 * math.sqrt(sum((a - b) ** 2
                                     for a, b in zip(first, second)))
    delta_i = first[0] - second[0]
    delta_t = first[1] - second[1]
    delta_p = first[2] - second[2]
    return 720.0 * math.sqrt(
        delta_i * delta_i + 0.25 * delta_t * delta_t + delta_p * delta_p)


def xyz_to_lab(xyz, white, ratio_policy="signed_linear"):
    """Convert XYZ to Lab under an explicitly named negative-ratio policy."""
    if ratio_policy not in ("signed_linear", "ratio_floor_1e_minus_9"):
        raise ValueError("unknown XYZ-to-Lab ratio policy")

    def f(value):
        return (value ** (1.0 / 3.0)
                if value > (6.0 / 29.0) ** 3
                else value / (3 * (6.0 / 29.0) ** 2) + 4.0 / 29.0)

    ratios = [xyz[index] / white[index] for index in range(3)]
    if ratio_policy == "ratio_floor_1e_minus_9":
        ratios = [max(1e-9, value) for value in ratios]
    fx, fy, fz = [f(value) for value in ratios]
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]


def delta_e_2000_lab(lab_a, lab_b):
    """CIEDE2000 between two Lab triples, preserving scalar evaluation order."""
    l1, a1, b1 = lab_a
    l2, a2, b2 = lab_b
    c1 = math.hypot(a1, b1)
    c2 = math.hypot(a2, b2)
    cm = (c1 + c2) / 2.0
    g = (0.5 * (1 - math.sqrt(cm ** 7 / (cm ** 7 + 25.0 ** 7)))
         if cm > 0 else 0.0)
    a1p, a2p = a1 * (1 + g), a2 * (1 + g)
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1 = math.degrees(math.atan2(b1, a1p)) % 360 if (b1 or a1p) else 0.0
    h2 = math.degrees(math.atan2(b2, a2p)) % 360 if (b2 or a2p) else 0.0
    dl = l2 - l1
    dc = c2p - c1p
    dh = (0.0 if c1p * c2p == 0 else
          (h2 - h1 - 360 if h2 - h1 > 180 else
           h2 - h1 + 360 if h2 - h1 < -180 else h2 - h1))
    dhp = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dh) / 2.0)
    lm = (l1 + l2) / 2.0
    cmp_ = (c1p + c2p) / 2.0
    if c1p * c2p == 0:
        hm = h1 + h2
    elif abs(h1 - h2) <= 180:
        hm = (h1 + h2) / 2.0
    else:
        hm = ((h1 + h2 + 360) / 2.0 if h1 + h2 < 360
              else (h1 + h2 - 360) / 2.0)
    tt = (1 - 0.17 * math.cos(math.radians(hm - 30))
          + 0.24 * math.cos(math.radians(2 * hm))
          + 0.32 * math.cos(math.radians(3 * hm + 6))
          - 0.20 * math.cos(math.radians(4 * hm - 63)))
    sl = 1 + (0.015 * (lm - 50) ** 2) / math.sqrt(20 + (lm - 50) ** 2)
    sc = 1 + 0.045 * cmp_
    sh = 1 + 0.015 * cmp_ * tt
    rt = (-2 * math.sqrt(cmp_ ** 7 / (cmp_ ** 7 + 25.0 ** 7))
          * math.sin(math.radians(
              60 * math.exp(-(((hm - 275) / 25.0) ** 2))))
          if cmp_ > 0 else 0.0)
    return math.sqrt((dl / sl) ** 2 + (dc / sc) ** 2 + (dhp / sh) ** 2
                     + rt * (dc / sc) * (dhp / sh))


def smoothstep(value):
    value = clamp(float(value), 0.0, 1.0)
    return value * value * (3.0 - 2.0 * value)


def sample_uniform_table(table, position):
    """Linearly sample a table whose entries span the unit interval."""
    spot = clamp(position, 0.0, 1.0) * (len(table) - 1)
    low = min(len(table) - 2, int(spot))
    fraction = spot - low
    return table[low] * (1.0 - fraction) + table[low + 1] * fraction


def average_xyz_measurements(readings):
    """Return an accurate arithmetic mean of repeated meter measurements.

    XYZ is linear, so it is the correct space in which to average repeated
    physical readings.  ``math.fsum`` avoids the order-dependent rounding of
    a naive sum.  Derived xy and CCT values are calculated once from the mean
    XYZ; averaging those nonlinear values would be mathematically wrong.
    """
    if not isinstance(readings, (list, tuple)) or not readings:
        raise ValueError("at least one reading is required")
    if len(readings) > 100:
        raise ValueError("too many readings")

    def reading_number(reading, key):
        if not isinstance(reading, dict):
            raise ValueError("every reading must be an object")
        return finite_number(reading.get(key), key)

    count = len(readings)
    xyz = tuple(
        math.fsum(reading_number(reading, key) for reading in readings) / count
        for key in ("X", "Y", "Z")
    )
    result = {
        "X": xyz[0], "Y": xyz[1], "Z": xyz[2],
        "sample_count": count,
    }
    result.update(xyz_derived_fields(xyz[0], xyz[1], xyz[2]))
    return result


# Both products keep sum() rather than an explicit three-term expression
# because that is the established reduction and its results are already in
# shipped profiles. Note what "established" means across interpreters: on the
# appliance's CPython 3.5 sum() is a plain left-to-right addition, while from
# CPython 3.12 it compensates (Neumaier) and can differ by an ulp when the
# three terms span very different magnitudes. Callers here keep the terms
# comparably scaled, so the two agree in practice; a workstation comparison
# against an explicit left-to-right sum is the approximate side of that
# comparison, not this one.
def matrix3_multiply(left, right):
    """Multiply 3x3 matrices in the established scalar reduction order."""
    return [[sum(left[row][k] * right[k][column] for k in range(3))
             for column in range(3)] for row in range(3)]


def matrix3_vector_multiply(matrix, vector):
    """Apply a 3x3 matrix in the established scalar reduction order."""
    return [sum(matrix[row][column] * vector[column]
                for column in range(3)) for row in range(3)]


def matrix3_inverse(matrix, determinant_tolerance=1e-12):
    """Return an adjugate 3x3 inverse, or None below the chosen tolerance."""
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    determinant = (a * (e * i - f * h) - b * (d * i - f * g)
                   + c * (d * h - e * g))
    if (determinant_tolerance is not None
            and abs(determinant) < determinant_tolerance):
        return None
    return [
        [(e * i - f * h) / determinant,
         (c * h - b * i) / determinant,
         (b * f - c * e) / determinant],
        [(f * g - d * i) / determinant,
         (a * i - c * g) / determinant,
         (c * d - a * f) / determinant],
        [(d * h - e * g) / determinant,
         (b * g - a * h) / determinant,
         (a * e - b * d) / determinant],
    ]


def bradford_adaptation(source_white, destination_white,
                        cone_tolerance=1e-12, inclusive=True):
    """Return the Bradford XYZ adaptation matrix, or None if degenerate."""
    source_cone = matrix3_vector_multiply(BRADFORD, source_white)
    destination_cone = matrix3_vector_multiply(BRADFORD, destination_white)
    minimum = min(abs(value) for value in source_cone)
    if ((inclusive and minimum <= cone_tolerance)
            or (not inclusive and minimum < cone_tolerance)):
        return None
    scale = [
        [destination_cone[row] / source_cone[row]
         if row == column else 0.0 for column in range(3)]
        for row in range(3)
    ]
    return matrix3_multiply(
        BRADFORD_INVERSE, matrix3_multiply(scale, BRADFORD))

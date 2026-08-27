#!/usr/bin/env python3
"""Build display ICC profiles from PGenerator+ RGB/XYZ measurements.

The normal and KDE profiles are created by the bundled ArgyllCMS colprof.
Windows Advanced Color profiles add Microsoft's documented MHC2 tag to that
measured matrix/shaper profile.  Only the Python standard library and NumPy
are used.
"""

from __future__ import print_function

import datetime
import io
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np

from pgen_colour_math import (
    BRADFORD,
    PQ_C1,
    PQ_C2,
    PQ_C3,
    PQ_M1,
    PQ_M2,
    bradford_adaptation as shared_bradford_adaptation,
    matrix3_inverse,
    matrix3_multiply as mat_mul,
    matrix3_vector_multiply as mat_vec_mul,
    pq_decode_nits as pq_to_nits,
    pq_encode_nits as nits_to_pq,
    sample_uniform_table as sample_table,
    smoothstep,
)


PROFILE_TYPES = {
    "sdr": "SDR display",
    "windows-sdr": "SDR ICC with MHC2 system calibration",
    "kde-hdr": "HDR ICC for KDE system-wide color management",
    "windows-hdr": "HDR ICC with MHC2 system calibration",
}
PROFILE_MODELS = {
    "clut": {"label": "XYZ cLUT + matrix", "argyll": "X", "family": "clut", "matrix_fallback": True},
    "xyz_clut": {"label": "XYZ cLUT only", "argyll": "x", "family": "clut", "matrix_fallback": False},
    "lab_clut": {"label": "L*a*b* cLUT only", "argyll": "l", "family": "clut", "matrix_fallback": False},
    "matrix": {"label": "Curves + matrix", "argyll": "s", "family": "matrix", "matrix_fallback": True},
    "single_curve_matrix": {"label": "Single curve + matrix", "argyll": "S", "family": "matrix", "matrix_fallback": True},
    "gamma_matrix": {"label": "Gamma + matrix", "argyll": "g", "family": "matrix", "matrix_fallback": True},
    "single_gamma_matrix": {"label": "Single gamma + matrix", "argyll": "G", "family": "matrix", "matrix_fallback": True},
}
PATCH_SET_ALIASES = {"quick": "small", "standard": "medium", "high": "large"}
PATCH_SET_COUNTS = {
    "matrix": {"small": 55, "medium": 95, "large": 225},
    "clut": {"small": 175, "medium": 425, "large": 1000},
}
WINDOWS_SDR_TRANSFERS = ("srgb", "gamma22", "gamma24", "bt1886")
WINDOWS_SDR_TRANSFER_LABELS = {
    "srgb": "sRGB",
    "gamma22": "Gamma 2.2",
    "gamma24": "Gamma 2.4",
    "bt1886": "BT.1886",
}
ICC_PROFILE_VERSIONS = ("auto", "2.2", "4.4")
CICP_COLOUR_PRIMARIES = (1, 5, 6, 9, 11, 12)
CICP_TRANSFER_CHARACTERISTICS = (1, 4, 5, 8, 13, 14, 15, 16, 18)
CICP_MATRIX_COEFFICIENTS = (0, 1, 5, 6, 9, 10)
SAFE_NAME = re.compile(r"[^A-Za-z0-9._ -]+")


class CompanionBuildTimeout(ValueError):
    pass


class CompanionBuildFailed(ValueError):
    pass


def fail(message):
    raise ValueError(message)


def finite_number(value, name):
    try:
        number = float(value)
    except (TypeError, ValueError):
        fail("Missing or invalid " + name)
    if not math.isfinite(number):
        fail("Missing or invalid " + name)
    return number


def profile_icc_settings(payload, profile_type):
    """Validate the requested ICC container and its optional CICP metadata."""
    requested = str(payload.get("icc_version", "auto")).lower()
    if requested not in ICC_PROFILE_VERSIONS:
        fail("Unsupported ICC profile version")
    effective = "4.4" if requested == "auto" and profile_type == "kde-hdr" else requested
    if effective == "auto":
        effective = "2.2"

    hdr = profile_type in ("kde-hdr", "windows-hdr")
    defaults = {
        "colour_primaries": 9 if hdr else 1,
        "transfer_characteristics": 16 if hdr else 13,
        "matrix_coefficients": 0,
        "video_full_range_flag": 1,
    }
    supplied = payload.get("cicp")
    if supplied is None:
        supplied = {}
    if not isinstance(supplied, dict):
        fail("CICP settings must be an object")

    settings = {}
    allowed = {
        "colour_primaries": CICP_COLOUR_PRIMARIES,
        "transfer_characteristics": CICP_TRANSFER_CHARACTERISTICS,
        "matrix_coefficients": CICP_MATRIX_COEFFICIENTS,
        "video_full_range_flag": (0, 1),
    }
    labels = {
        "colour_primaries": "CICP colour primaries",
        "transfer_characteristics": "CICP transfer characteristics",
        "matrix_coefficients": "CICP matrix coefficients",
        "video_full_range_flag": "CICP signal range",
    }
    for key, choices in allowed.items():
        raw = supplied.get(key, defaults[key])
        if isinstance(raw, bool):
            fail("Unsupported " + labels[key].lower())
        try:
            value = int(raw)
        except (TypeError, ValueError):
            fail("Unsupported " + labels[key].lower())
        if str(raw).strip() not in (str(value), "{}.0".format(value)) or value not in choices:
            fail("Unsupported " + labels[key].lower())
        settings[key] = value
    return requested, effective, settings


def effective_patch_set(requested, profile_model, payload, measured_count):
    """Label a preset build from the settings that were actually measured."""
    if requested == "custom":
        return requested
    family = PROFILE_MODELS[profile_model]["family"]
    settings = payload.get("patch_settings")
    configured_count = settings.get("patch_count") if isinstance(settings, dict) else None
    try:
        configured_count = int(round(float(configured_count)))
    except (TypeError, ValueError):
        configured_count = None
    for label, count in PATCH_SET_COUNTS[family].items():
        if configured_count == count:
            return label
    # Generated sets can contain one fewer unique row after duplicate removal.
    for label, count in PATCH_SET_COUNTS[family].items():
        if abs(int(measured_count) - count) <= 1:
            return label
    return requested


def reading_codes(reading):
    maximum = int(finite_number(reading.get("input_max", 255), "input_max"))
    if maximum not in (255, 1023, 4095):
        fail("Unsupported patch bit depth")
    values = []
    for key in ("r_code", "g_code", "b_code"):
        fallback = key[0]
        value = reading.get(key, reading.get(fallback))
        value = int(round(finite_number(value, key)))
        if value < 0 or value > maximum:
            fail("Patch code is outside its declared range")
        values.append(value)
    return tuple(values), maximum


def normalize_measurements(payload):
    code_min = int(round(finite_number(payload.get("code_min", 0), "code_min")))
    code_max = int(round(finite_number(payload.get("code_max", 255), "code_max")))
    if code_min < 0 or code_max <= code_min:
        fail("Invalid profiling code range")
    rows = []
    for raw in payload.get("readings", []):
        if not isinstance(raw, dict) or raw.get("error"):
            continue
        # Series measurement endpoints may prepend automatic white/black
        # reference reads.  They establish chart luminance targets, but are not
        # patches from the ICC characterization set and may use a different
        # transport bit depth (for example an 8-bit reference before a 10-bit
        # HDR chart).  Never feed them to ArgyllCMS or bit-depth validation.
        if str(raw.get("series_type", "")).lower() == "reference" or raw.get("autocal_reference_only"):
            continue
        try:
            codes, maximum = reading_codes(raw)
            xyz = tuple(finite_number(raw.get(key), key) for key in ("X", "Y", "Z"))
        except ValueError:
            continue
        if min(xyz) < 0:
            continue
        if code_max > maximum:
            fail("Profiling code range exceeds the patch bit depth")
        rgb = tuple(max(0.0, min(1.0, (value - code_min) / float(code_max - code_min))) for value in codes)
        rows.append({"codes": codes, "rgb": rgb, "input_max": maximum, "xyz": xyz, "name": str(raw.get("name", ""))})
    if len(rows) < 16:
        fail("At least 16 valid RGB/XYZ measurements are required")
    input_maxima = {row["input_max"] for row in rows}
    if len(input_maxima) != 1:
        fail("All measurements must use the same patch bit depth")
    return rows


def closest_row(rows, target):
    def distance(row):
        return sum(abs(row["rgb"][index] - target[index]) for index in range(3))
    row = min(rows, key=distance)
    if distance(row) > 0.02:
        fail("Required black, white and primary measurements are missing")
    return row


def robust_xyz(rows):
    """Return a robust average XYZ for repeated measurements of one patch."""
    if not rows:
        fail("Cannot average an empty measurement set")
    result = []
    for axis in range(3):
        values = sorted(row["xyz"][axis] for row in rows)
        if len(values) >= 4:
            values = values[1:-1]
        result.append(sum(values) / len(values))
    return tuple(result)


def repeated_target_row(rows, target):
    """Use every repeated exact anchor instead of whichever row came first."""
    exact = [
        row for row in rows
        if max(abs(row["rgb"][axis] - target[axis]) for axis in range(3)) < 1e-9
    ]
    if not exact:
        return closest_row(rows, target)
    combined = dict(exact[0])
    combined["xyz"] = robust_xyz(exact)
    return combined


def profile_measurement_summary(rows):
    black = repeated_target_row(rows, (0, 0, 0))
    white = repeated_target_row(rows, (1, 1, 1))
    primaries = [
        repeated_target_row(rows, (1, 0, 0)),
        repeated_target_row(rows, (0, 1, 0)),
        repeated_target_row(rows, (0, 0, 1)),
    ]
    if white["xyz"][1] <= black["xyz"][1]:
        fail("Measured white must be brighter than measured black")
    for row in primaries:
        if row["xyz"][1] <= black["xyz"][1]:
            fail("Measured RGB primaries are invalid")
    return black, white, primaries


def cgats_quote(value):
    return str(value).replace("\\", "/").replace('"', "'").replace("\r", " ").replace("\n", " ")


def profile_description(payload):
    description = str(payload.get("name", "PGenerator+ display profile"))
    if payload.get("profile_type") in ("sdr", "windows-sdr") and str(payload.get("calibration_mode", "vcgt")).lower() != "none":
        transfer = str(payload.get("target_transfer", "srgb")).lower()
        label = WINDOWS_SDR_TRANSFER_LABELS.get(transfer, "sRGB")
        suffix = (" (SDR MHC2, {})" if payload.get("profile_type") == "windows-sdr"
                  else " (SDR, {})").format(label)
        # Fine-tune recovers the build's target transfer from this marker on
        # profiles that predate the validation sidecar recording it, so a long
        # name must lose its own tail rather than the marker.
        return description[:120 - len(suffix)] + suffix
    return description[:120]


def make_ti3(payload, rows):
    black, white, _ = profile_measurement_summary(rows)
    white_xyz = white["xyz"]
    white_y = white_xyz[1]
    instrument = cgats_quote(payload.get("meter_name", "PGenerator+ meter"))
    description = cgats_quote(profile_description(payload))
    created = datetime.datetime.now().strftime("%a %b %d %H:%M:%S %Y")
    lines = [
        "CTI3",
        "",
        'DESCRIPTOR "PGenerator+ measured display profile"',
        'ORIGINATOR "PGenerator+"',
        'CREATED "{}"'.format(created),
        'DEVICE_CLASS "DISPLAY"',
        'COLOR_REP "RGB_XYZ"',
        'TARGET_INSTRUMENT "{}"'.format(instrument),
        'LUMINANCE_XYZ_CDM2 "{:.8f} {:.8f} {:.8f}"'.format(*white_xyz),
        'NORMALIZED_TO_Y_100 "YES"',
        'PROFILE_DESCRIPTION "{}"'.format(description),
        "",
        "NUMBER_OF_FIELDS 7",
        "BEGIN_DATA_FORMAT",
        "SAMPLE_ID RGB_R RGB_G RGB_B XYZ_X XYZ_Y XYZ_Z",
        "END_DATA_FORMAT",
        "",
        "NUMBER_OF_SETS {}".format(len(rows)),
        "BEGIN_DATA",
    ]
    for index, row in enumerate(rows, 1):
        rgb = [100.0 * value for value in row["rgb"]]
        xyz = [100.0 * value / white_y for value in row["xyz"]]
        lines.append(
            "{} {:.8f} {:.8f} {:.8f} {:.8f} {:.8f} {:.8f}".format(index, *(rgb + xyz))
        )
    lines.extend(["END_DATA", ""])
    return "\n".join(lines), black, white


def mat_inv(matrix):
    inverse = matrix3_inverse(matrix, determinant_tolerance=1e-9)
    if inverse is None:
        fail("Measured primary matrix is singular")
    return inverse


def xy_matrix(primaries, white):
    columns = []
    for x, y in primaries:
        columns.append([x / y, 1.0, (1.0 - x - y) / y])
    base = [[columns[c][r] for c in range(3)] for r in range(3)]
    wx, wy = white
    white_xyz = [wx / wy, 1.0, (1.0 - wx - wy) / wy]
    scales = [sum(mat_inv(base)[r][c] * white_xyz[c] for c in range(3)) for r in range(3)]
    return [[base[r][c] * scales[c] for c in range(3)] for r in range(3)]


def measured_primary_matrix(black, white, primaries):
    black_xyz = black["xyz"]
    white_y = white["xyz"][1] - black_xyz[1]
    columns = [[primary["xyz"][axis] - black_xyz[axis] for axis in range(3)] for primary in primaries]
    matrix = [[columns[column][row] / white_y for column in range(3)] for row in range(3)]
    # Real displays are not perfectly additive. Scale each column so their
    # sum lands on the measured white while retaining measured chromaticity.
    measured_white = [(white["xyz"][axis] - black_xyz[axis]) / white_y for axis in range(3)]
    scales = [sum(mat_inv(matrix)[r][c] * measured_white[c] for c in range(3)) for r in range(3)]
    return [[matrix[r][c] * scales[c] for c in range(3)] for r in range(3)]


def s15fixed16(value):
    if value <= -32768 or value >= 32768:
        fail("MHC2 matrix value is outside the supported range")
    return struct.pack(">i", int(round(value * 65536.0)))


def srgb_to_linear(value):
    value = max(0.0, min(1.0, value))
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def linear_to_srgb(value):
    value = max(0.0, min(1.0, value))
    if value <= 0.0031308:
        return value * 12.92
    return 1.055 * (value ** (1.0 / 2.4)) - 0.055


# Entries in the per-channel calibration curve written to vcgt. A 1D curve can
# afford resolution a 3D cLUT cannot: 33 grid nodes per axis leave only two
# below 1.2 cd/m2 on a display whose shadow response is steep, which is far too
# coarse to invert. The calibration carries that region instead.
VCGT_ENTRIES = 1024
# MHC2 permits up to 4096 1DLUT entries and the OS interpolates to whatever
# the hardware supports. 256 entries are coarse exactly where PQ moves
# fastest (one step ~0.4% of code near the knee), so HDR writes the full
# density. SDR keeps 256: its sRGB-domain curves are smooth and the
# established SDR behaviour is validated on hardware.
MHC2_HDR_LUT_ENTRIES = 4096
MHC2_SDR_LUT_ENTRIES = 256
# Windows has a distinct exact-maximum HDR presentation path. If the MHC2
# matrix sends neutral maximum code to 1.0 or above, that path can clamp one
# or more channels before the per-channel curves run even though every lower
# code is correct. Reserve a small, generic matrix-domain margin and move the
# inverse scale into the curves. The represented correction is unchanged;
# only its location inside the MHC2 pipeline moves away from the clamp.
MHC2_HDR_NEUTRAL_HEADROOM = 0.95
# Closed-loop shadow verification uses actual temporary profile variants.
# One variant raises a single final curve by this amount through the reliable
# 10-35% PQ band, so the measured XYZ difference is the derivative of the
# profile edit itself rather than a source-patch approximation.
MHC2_CURVE_FEEDBACK_DELTA = 4.0 / 1023.0
MHC2_CURVE_FEEDBACK_CODES = (102, 153, 205, 256, 307, 358)
# The cLUT corridor needs anchors above the shadow band as well. The MHC2 path
# gets its top end from the peak candidate and final peak feedback stages, but
# the B2A has no equivalent, so its neutral corridor was left uncorrected above
# roughly code 414 and carried a flat +.0028 dy offset from 767 to 1023, about
# 1.5 chroma dE, where the MHC2 path reached 0.54. These extra codes are
# measured by the same signed cLUT variant series, so they keep cLUT transform
# provenance instead of borrowing the MHC2 peak feedback rows.
# 767 and above are unusable: the profile's own shoulder puts them on the peak
# plateau, where a four code probe moved the measured output by only 0.02% to
# 0.45% against a 2% validity floor, so every anchor was correctly rejected.
# These codes were verified against the profile's measured output, not the
# null-seed ladder, which overestimates response above the knee.
# Code 51 is deliberately absent from the probe sets. Direct probes fail the
# coherence gate (11.16% channel spread at 0.054 nits) and holding the 102
# correction down to black measured worse (cLUT 1.654 to 1.733, code 51 from
# 4.044 to 4.656). The grey-ladder borrowed-Jacobian path in
# apply_mhc2_active_shadow_jacobians is the remaining way to reach it.
MHC2_CLUT_FEEDBACK_CODES = MHC2_CURVE_FEEDBACK_CODES + (460, 563, 665, 716)
# The MHC2 curves have the same hole the cLUT corridor had: shadow anchors fade
# out by code 414 to 429 and the peak stages only begin near 763, so codes 409
# to 716 were left to the unconstrained model. Measure 460 and 563, which sit
# inside the MHC2 mid-band probe envelope. Do not add 665 or 716: the envelope
# ends at 665 so a probe there has no amplitude, which is why codes 767 and
# above were unprobeable. The recoverability validator stays on
# MHC2_CURVE_FEEDBACK_CODES so new anchors cannot fail a build closed.
MHC2_MIDBAND_FEEDBACK_CODES = MHC2_CURVE_FEEDBACK_CODES + (460, 563)
MHC2_PROFILE_RESPONSE_CONTRACT = "signed-independent-v1"
# Shadow chroma closer to D65 than this is treated as already neutral. Near
# black the measured chromaticity carries real meter noise, and solving inside
# that noise trades an invisible error for a visible tint.
MHC2_SHADOW_CHROMA_DEADBAND = 0.003
# Minimum measured luminance for a borrowed grey-ladder chroma anchor. The
# ladder runs down to code 20 at about 0.001 nits, and anchoring there feeds
# meter noise straight into the correction. Code 51 measured 0.054 nits and
# its borrowed anchor made that code worse, 4.044 to 5.042 dE ITP, while the
# anchors just above it improved codes 102, 153 and 205. The active-response
# coherence gate independently rejects probes at 51 for 11.16% channel
# spread, so 0.054 nits is demonstrably below the usable floor on this panel.
MHC2_BORROWED_GREY_MIN_NITS = 0.08
# Fraction of an output table's ceiling below which the peak remap leaves the
# table alone. 0.90 disturbed codes 614 and 716; 0.97 does not.
MHC2_PEAK_TABLE_KNEE = 0.97


def mhc2_lut_entries(profile_type):
    return MHC2_HDR_LUT_ENTRIES if profile_type == "windows-hdr" else MHC2_SDR_LUT_ENTRIES


def mhc2_exact_white_start(entries):
    """First MHC2 entry used by Windows' exact maximum-code HDR path."""
    # Use the lower dense-table neighbour. At 4096 entries, 253/255 falls
    # between two samples; rounding up leaves Windows interpolating part of
    # the held shoulder into exact white. Marking both neighbours as endpoint
    # keeps the probed 253 boundary constant while 99% remains below it.
    return max(1, min(entries - 1, int(math.floor(
        253.0 * (entries - 1) / 255.0))))


def vcgt_from_mhc2(matrix, adjustment_luts, wire, entries=VCGT_ENTRIES):
    """Reproduce MHC2's neutral-axis behaviour as a vcgt table.

    vcgt is only ever used for the grey axis, and on that axis MHC2's 3x3
    reduces to a fixed per-channel gain -- a matrix cannot be expressed as
    three independent curves in general, but along neutral it can. Tabulating
    MHC2's own neutral output therefore gives a vcgt that matches it exactly
    where it is used, so the fallback path and the preferred path agree
    instead of the fallback approximating with per-channel scaling.
    """
    inverse_wire = mat_inv(wire)
    curves = [[], [], []]
    for index in range(entries):
        position = index / float(entries - 1)
        linear = [pq_to_nits(position) / 10000.0] * 3
        target = mat_vec_mul(inverse_wire, mat_vec_mul(matrix, mat_vec_mul(wire, linear)))
        for channel in range(3):
            encoded = nits_to_pq(max(0.0, target[channel]) * 10000.0)
            if adjustment_luts:
                table = adjustment_luts[channel]
                spot = max(0.0, min(1.0, encoded)) * (len(table) - 1)
                low = min(len(table) - 2, int(spot))
                fraction = spot - low
                encoded = table[low] * (1.0 - fraction) + table[low + 1] * fraction
            curves[channel].append(max(0.0, min(1.0, encoded)))
    for channel in range(3):
        previous = 0.0
        for index in range(entries):
            previous = max(previous, curves[channel][index])
            curves[channel][index] = previous
    return curves


def calibration_curves(rows, black, white, primaries, profile_type, target_transfer,
                       entries=VCGT_ENTRIES, balance_white=True):
    """Per-channel 1D calibration: profile value -> panel device value.

    This is the stage ArgyllCMS produces with dispcal and stores in vcgt, and
    the reason its workflow calibrates before it profiles. Linearising each
    channel first means the cLUT fitted afterwards only has to model a
    well-behaved display, instead of a near-black response that changes faster
    than its grid can represent.

    The target spans the panel's own black-to-peak range so the curve always
    covers the full device range: an absolute PQ target would saturate at the
    measured peak and leave everything above it mapped to device maximum.
    """
    channel_samples = neutral_channel_samples(rows, black, primaries)
    black_nits = max(0.0, black["xyz"][1])
    peak_nits = max(white["xyz"][1], black_nits + 1e-4)
    span = peak_nits - black_nits
    peak_pq = nits_to_pq(peak_nits) if profile_type in ("kde-hdr", "windows-hdr") else 0.0
    black_ratio = black_nits / peak_nits if peak_nits > 0 else 0.0
    channel_targets = [1.0, 1.0, 1.0]
    if peak_pq > 0.0 and balance_white:
        physical = measured_primary_matrix(black, white, primaries)
        wire = mhc2_wire_matrix("windows-hdr")
        channel_targets = mat_vec_mul(mat_mul(mat_inv(physical), wire),
                                      (1.0, 1.0, 1.0))
        maximum_target = max(channel_targets)
        if min(channel_targets) <= 1e-6 or maximum_target <= 1e-6:
            fail("HDR calibration has an invalid neutral white target")
        channel_targets = [value / maximum_target for value in channel_targets]
    curves = []
    for channel in range(3):
        values = []
        previous = 0.0
        for index in range(entries):
            position = index / float(entries - 1)
            if peak_pq > 0.0:
                target = (pq_to_nits(position * peak_pq) - black_nits) / span
            else:
                target = target_transfer_to_linear(position, target_transfer or "srgb", black_ratio)
            target = max(0.0, min(1.0, target * channel_targets[channel]))
            device = invert_channel_response(channel_samples[channel], target)
            previous = max(previous, max(0.0, min(1.0, device)))
            values.append(previous)
        values[0] = 0.0
        values[-1] = 1.0
        curves.append(values)
    return curves


def calibration_to_profile_value(curve, device):
    """Invert one calibration curve: panel device value -> profile value."""
    entries = len(curve)
    if device <= curve[0]:
        return 0.0
    if device >= curve[-1]:
        return 1.0
    low, high = 0, entries - 1
    while low < high - 1:
        middle = (low + high) // 2
        if curve[middle] <= device:
            low = middle
        else:
            high = middle
    step = curve[high] - curve[low]
    fraction = 0.0 if step <= 0 else (device - curve[low]) / step
    return (low + fraction) / (entries - 1.0)


def blend_hdr_profile_calibration(direct, modeled, start=0.30, end=0.35):
    """Join measured shadow calibration to the full-range HDR model."""
    if len(direct) != 3 or len(modeled) != 3:
        fail("HDR profile calibration requires three output curves")
    entries = min(min(len(curve) for curve in direct),
                  min(len(curve) for curve in modeled))
    if entries < 2 or not (0.0 <= start < end <= 1.0):
        fail("HDR profile calibration blend is invalid")
    result = [[], [], []]
    for channel in range(3):
        previous = 0.0
        for index in range(entries):
            position = index / float(entries - 1)
            if position <= start:
                weight = 0.0
            elif position >= end:
                weight = 1.0
            else:
                weight = (position - start) / (end - start)
                weight = smoothstep(weight)
            value = (sample_table(direct[channel], position) * (1.0 - weight)
                     + sample_table(modeled[channel], position) * weight)
            previous = max(previous, max(0.0, min(1.0, value)))
            result[channel].append(previous)
        result[channel][0] = 0.0
        result[channel][-1] = 1.0
    return result


def apply_calibration_to_rows(rows, curves):
    """Re-express measurements in the calibrated domain.

    The measurement is panel_device -> XYZ. With the calibration loaded the
    profile is handed a value v and the panel receives curve(v), so the profile
    must model v -> XYZ measured at curve(v). Re-expressing each row's RGB as
    curve^-1(device) states exactly that, which is why no second measurement
    pass through the calibration is needed.
    """
    calibrated = []
    for row in rows:
        rgb = tuple(
            calibration_to_profile_value(curves[channel], row["rgb"][channel])
            for channel in range(3)
        )
        updated = dict(row)
        updated["rgb"] = rgb
        calibrated.append(updated)
    return calibrated


def vcgt_tag(curves):
    """Serialise per-channel calibration curves as an ICC vcgt table tag."""
    entries = len(curves[0])
    data = bytearray()
    data.extend(b"vcgt")
    data.extend(b"\0\0\0\0")
    data.extend(struct.pack(">I", 0))          # 0 = table, 1 = formula
    data.extend(struct.pack(">HHH", 3, entries, 2))
    for curve in curves:
        for value in curve:
            data.extend(struct.pack(">H", max(0, min(65535, int(round(value * 65535.0))))))
    return bytes(data)


def calibration_file_text(curves):
    """Create an Argyll CAL file for calibration incorporated into an ICC."""
    if len(curves) != 3 or any(len(curve) < 2 for curve in curves):
        fail("Profile calibration requires three usable channel curves")
    entries = min(len(curve) for curve in curves)
    lines = [
        "CAL", "", 'DESCRIPTOR "Argyll Device Calibration Curves"',
        'ORIGINATOR "PGenerator+"',
        'CREATED "{}"'.format(datetime.datetime.now().strftime("%a %b %d %H:%M:%S %Y")),
        'DEVICE_CLASS "DISPLAY"', 'COLOR_REP "RGB"', "",
        "NUMBER_OF_FIELDS 4", "BEGIN_DATA_FORMAT", "RGB_I RGB_R RGB_G RGB_B",
        "END_DATA_FORMAT", "", "NUMBER_OF_SETS {}".format(entries), "BEGIN_DATA",
    ]
    for index in range(entries):
        position = index / float(entries - 1)
        lines.append("{:.10f} {:.10f} {:.10f} {:.10f}".format(
            position, curves[0][index], curves[1][index], curves[2][index]))
    lines.extend(("END_DATA", ""))
    return "\n".join(lines)


def apply_profile_calibration(profile_path, curves):
    """Use Argyll applycal to incorporate calibration without adding VCGT."""
    applycal = os.environ.get("PGEN_APPLYCAL", "/usr/bin/applycal")
    if not os.path.isfile(applycal) or not os.access(applycal, os.X_OK):
        fail("ArgyllCMS applycal is unavailable for calibration without VCGT")
    temp_dir = tempfile.mkdtemp(prefix="pgen_applycal_")
    input_path = os.path.join(temp_dir, "profile.icc")
    output_path = profile_path + ".applycal.tmp"
    try:
        cal_path = os.path.join(temp_dir, "profile.cal")
        write_text_atomic(cal_path, calibration_file_text(curves))
        with open(profile_path, "rb") as handle:
            source_profile = handle.read()
        # ArgyllCMS 3.5 applycal cannot copy ICC v4 mluc text tags. They do
        # not participate in either transform, so preserve them byte-for-byte
        # around applycal while it updates only the color and calibration tags.
        mluc_tags = {
            signature: payload for signature, payload in read_icc_tags(source_profile)
            if payload[:4] == b"mluc"
        }
        replacements = {signature: None for signature in mluc_tags}
        if b"desc" in mluc_tags:
            # applycal requires a profile description even though it cannot
            # parse the v4 multi-localized form. Supply a disposable v2 desc
            # tag and restore the original mluc payload after calibration.
            description = b"PGenerator+ display profile\0"
            replacements[b"desc"] = (
                b"desc\0\0\0\0" + struct.pack(">I", len(description)) + description
                + struct.pack(">IIHB", 0, 0, 0, 0) + b"\0" * 67
            )
        if b"cprt" in mluc_tags:
            replacements[b"cprt"] = b"text\0\0\0\0PGenerator+\0"
        applycal_profile = rebuild_icc(source_profile, replacements) if mluc_tags else source_profile
        source_version = source_profile[8:12]
        if source_version[0] >= 4:
            # applycal's calibration metadata writer is also limited to the
            # ICC v2 tag registry. The transform representation is identical
            # here, so present a v2 header during composition and restore the
            # requested v4 header on the finished profile.
            applycal_profile = bytearray(applycal_profile)
            applycal_profile[8:12] = b"\x02\x10\0\0"
            applycal_profile = bytes(applycal_profile)
        with open(input_path, "wb") as handle:
            handle.write(applycal_profile)
        completed = subprocess.Popen(
            [applycal, "-a", cal_path, input_path, output_path],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = completed.communicate()[0]
        if (completed.returncode != 0 or not os.path.isfile(output_path)
                or os.path.getsize(output_path) <= 0):
            detail = (output or "").strip().splitlines()
            fail("ArgyllCMS could not incorporate the calibration into the ICC"
                 + (": " + detail[-1][:240] if detail else ""))
        if mluc_tags or source_version[0] >= 4:
            with open(output_path, "rb") as handle:
                calibrated_profile = handle.read()
            if source_version[0] >= 4:
                calibrated_profile = bytearray(calibrated_profile)
                calibrated_profile[8:12] = source_version
                calibrated_profile = bytes(calibrated_profile)
            if mluc_tags:
                calibrated_profile = rebuild_icc(calibrated_profile, mluc_tags)
            with open(output_path, "wb") as handle:
                handle.write(calibrated_profile)
        os.rename(output_path, profile_path)
    finally:
        try:
            os.unlink(output_path)
        except OSError:
            pass
        shutil.rmtree(temp_dir, ignore_errors=True)


def target_transfer_to_linear(value, transfer, black_ratio=0.0):
    value = max(0.0, min(1.0, value))
    black_ratio = max(0.0, min(0.999, black_ratio))
    if transfer == "srgb":
        absolute = srgb_to_linear(value)
    elif transfer == "gamma22":
        absolute = value ** 2.2
    elif transfer == "gamma24":
        absolute = value ** 2.4
    elif transfer == "bt1886":
        gamma = 2.4
        black_root = black_ratio ** (1.0 / gamma)
        span = max(1e-9, 1.0 - black_root)
        absolute = (span ** gamma) * ((value + black_root / span) ** gamma)
    else:
        fail("Unsupported SDR MHC2 target transfer")
    # Channel measurements are normalized after subtracting the physical
    # black level. Convert the requested absolute target into that same range.
    # Without this conversion, sRGB and power-gamma profiles add black to the
    # requested curve and incorrectly resemble BT.1886 in the shadows.
    return max(0.0, min(1.0, (absolute - black_ratio) / max(1e-9, 1.0 - black_ratio)))


def monotonic_channel_samples(rows, black, primary, channel):
    axis = [primary["xyz"][index] - black["xyz"][index] for index in range(3)]
    denominator = sum(value * value for value in axis)
    if denominator <= 1e-12:
        fail("Measured channel response is invalid")
    samples = []
    for row in rows:
        rgb = row["rgb"]
        if any(rgb[index] > 0.002 for index in range(3) if index != channel):
            continue
        vector = [row["xyz"][index] - black["xyz"][index] for index in range(3)]
        response = sum(vector[index] * axis[index] for index in range(3)) / denominator
        samples.append((rgb[channel], max(0.0, min(1.0, response))))
    samples.sort(key=lambda item: item[0])
    merged = []
    for code, response in samples:
        if merged and abs(code - merged[-1][0]) < 1e-7:
            merged[-1] = (code, (merged[-1][1] + response) * 0.5)
        else:
            merged.append((code, response))
    if len(merged) < 5 or merged[0][0] > 0.002 or merged[-1][0] < 0.998:
        fail("SDR MHC2 calibration requires black-to-primary channel ramps")
    return isotonic_channel_samples(merged)


def isotonic_channel_samples(samples):
    # Fit a non-decreasing response with pool-adjacent-violators instead of a
    # cumulative maximum. Near-black readings are noisy; cumulative-max turns
    # one high sample into a permanent shoulder in the inverse calibration
    # curve, while isotonic regression distributes that noise across only the
    # conflicting samples.
    blocks = []
    for index, (_code, response) in enumerate(samples):
        blocks.append([index, index, response, 1.0])
        while len(blocks) >= 2 and blocks[-2][2] / blocks[-2][3] > blocks[-1][2] / blocks[-1][3]:
            right = blocks.pop()
            left = blocks.pop()
            blocks.append([left[0], right[1], left[2] + right[2], left[3] + right[3]])
    fitted = [0.0] * len(samples)
    for start, end, total, weight in blocks:
        value = max(0.0, min(1.0, total / weight))
        for index in range(start, end + 1):
            fitted[index] = value
    monotonic = [(samples[index][0], fitted[index]) for index in range(len(samples))]
    peak = monotonic[-1][1]
    if peak <= 1e-6:
        fail("Measured channel response has no usable range")
    return [(code, response / peak) for code, response in monotonic]


def neutral_channel_samples(rows, black, primaries):
    # A low-level primary measurement is mostly the display's black light and
    # is a poor signal from which to infer a channel shaper. Neutral patches
    # contain all three channels and provide much stronger meter signal. Solve
    # each neutral XYZ reading against the measured primary axes to recover
    # the three simultaneous channel responses used by the grey axis.
    black_xyz = black["xyz"]
    axes = [[primaries[column]["xyz"][row] - black_xyz[row] for column in range(3)] for row in range(3)]
    inverse_axes = mat_inv(axes)
    samples = [[] for _channel in range(3)]
    for row in rows:
        rgb = row["rgb"]
        if max(rgb) - min(rgb) > 0.002:
            continue
        vector = [row["xyz"][axis] - black_xyz[axis] for axis in range(3)]
        responses = mat_vec_mul(inverse_axes, vector)
        for channel in range(3):
            samples[channel].append((sum(rgb) / 3.0, max(0.0, responses[channel])))
    result = []
    for channel_samples in samples:
        channel_samples.sort(key=lambda item: item[0])
        if len(channel_samples) < 5 or channel_samples[0][0] > 0.002 or channel_samples[-1][0] < 0.998:
            fail("SDR MHC2 calibration requires black-to-white neutral ramps")
        result.append(isotonic_channel_samples(channel_samples))
    return result


def invert_channel_response(samples, target):
    # The isotonic fit often represents a display's HDR shoulder as a flat
    # block. Its values are calculated independently from the caller's target,
    # so the nominal peak can differ by a few ulps. Clamp to the fitted range
    # before searching. Otherwise a target of 1.0 can miss a fitted peak of
    # 0.9999999999999999 and fall through to the final device code, creating a
    # large one-channel jump at the start of the plateau.
    target = min(target, samples[-1][1])
    if target <= samples[0][1]:
        return samples[0][0]
    for index in range(1, len(samples)):
        x0, y0 = samples[index - 1]
        x1, y1 = samples[index]
        if target <= y1 + 1e-12:
            if y1 <= y0 + 1e-12:
                return x0
            fraction = (target - y0) / (y1 - y0)
            return x0 + fraction * (x1 - x0)
    return samples[-1][0]


def windows_sdr_adjustment_luts(rows, black, white, primaries, entries, transfer, wire, adjustment):
    luts = []
    black_ratio = black["xyz"][1] / max(white["xyz"][1], 1e-9)
    channel_samples = neutral_channel_samples(rows, black, primaries)
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(adjustment, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    for channel in range(3):
        samples = channel_samples[channel]
        gain = neutral_gains[channel]
        if gain <= 1e-6:
            fail("SDR MHC2 calibration matrix has an invalid neutral response")
        values = []
        previous = 0.0
        for index in range(entries):
            lut_input = index / float(entries - 1)
            linear_input = srgb_to_linear(lut_input)
            if linear_input <= gain:
                source_encoded = linear_to_srgb(linear_input / gain)
                target = gain * target_transfer_to_linear(source_encoded, transfer, black_ratio)
            else:
                # Neutral white never enters this part of a channel LUT when
                # its matrix gain is below one. Preserve usable headroom for
                # saturated colors and meet the identity endpoint at 1.0.
                target = linear_input
            value = invert_channel_response(samples, target)
            previous = max(previous, max(0.0, min(1.0, value)))
            values.append(previous)
        values[0] = 0.0
        values[-1] = 1.0
        luts.append(values)
    return luts


def neutral_plateau_code(rows):
    """Return the drive above which the measured neutral ramp gains no light.

    Displays that tone-map internally hold peak white over the whole top of
    their range, so nothing above this code buys luminance. A display that
    keeps climbing to full drive reports 1.0 and is therefore unaffected by
    any ceiling derived from this.
    """
    samples = [(sum(row["rgb"]) / 3.0, row["xyz"][1]) for row in rows
               if max(row["rgb"]) - min(row["rgb"]) <= 0.002]
    peak = max([luminance for _code, luminance in samples] or [0.0])
    if peak <= 0.0:
        return 1.0
    return min(code for code, luminance in samples if luminance >= peak * 0.998)


def validate_hdr_neutral_response_continuity(rows):
    """Reject a characterization that crossed HDR presentation states.

    A promoted Windows HDR surface can have a different shadow transfer from
    the composed surface used a moment later. The resulting neutral ramp is
    not a display defect that an ICC curve can invert: it contains a single
    large response jump while the requested PQ codes remain closely spaced.
    Detect that local discontinuity before fitting either KDE B2A shapers or
    Windows MHC2 curves. Smooth native tracking errors remain buildable.
    """
    grouped = {}
    for row in rows:
        if max(row["rgb"]) - min(row["rgb"]) > 0.002:
            continue
        code = sum(row["rgb"]) / 3.0
        if code < 0.03 or code > 0.76:
            continue
        grouped.setdefault(round(code, 6), []).append(row["xyz"][1])
    samples = []
    for code, values in grouped.items():
        ordered = sorted(values)
        middle = len(ordered) // 2
        luminance = (ordered[middle] if len(ordered) % 2 else
                     0.5 * (ordered[middle - 1] + ordered[middle]))
        samples.append((code, luminance))
    samples.sort()
    if len(samples) < 16:
        return
    peak = max(row["xyz"][1] for row in rows)
    intervals = []
    for index in range(1, len(samples)):
        code0, y0 = samples[index - 1]
        code1, y1 = samples[index]
        if code1 - code0 <= 1e-6 or code1 > 0.75:
            continue
        expected_rise = pq_to_nits(code1) - pq_to_nits(code0)
        actual_rise = max(0.0, y1 - y0)
        if expected_rise <= 1e-9:
            continue
        intervals.append({
            "code0": code0,
            "code1": code1,
            "y0": y0,
            "y1": y1,
            "rise": actual_rise,
            "gain": actual_rise / expected_rise,
        })
    for index, interval in enumerate(intervals):
        neighbours = [
            intervals[other]["gain"]
            for other in range(max(0, index - 2), min(len(intervals), index + 3))
            if other != index and intervals[other]["gain"] > 1e-6
        ]
        if len(neighbours) < 2:
            continue
        neighbours.sort()
        local_gain = neighbours[len(neighbours) // 2]
        material_rise = max(0.05, peak * 0.002)
        if (interval["rise"] >= material_rise
                and interval["gain"] > 5.0 * local_gain):
            fail(
                "HDR characterization changed presentation response near "
                "{:.1f}% input ({:.3f} to {:.3f} cd/m2). Keep Patch "
                "Companion on the target display in composed fullscreen "
                "mode and repeat the measurements.".format(
                    interval["code1"] * 100.0,
                    interval["y0"], interval["y1"]))


def validate_mhc2_active_shadow_coverage(rows):
    """Require active-path samples in the device range used by the HDR toe."""
    shadow_codes = sorted(set(
        round(sum(row["rgb"]) / 3.0, 6)
        for row in rows
        if max(row["rgb"]) - min(row["rgb"]) <= 0.002
        and 0.0 < sum(row["rgb"]) / 3.0 <= 0.05
    ))
    if len(shadow_codes) < 4:
        fail("Separate Windows MHC2 measurements need at least four neutral "
             "anchors below 5% device drive so shadow luminance is measured "
             "instead of extrapolated")


MHC2_ACTIVE_SENTINEL_PREFIX = "ICC MHC2 Active Sentinel "
MHC2_INSTALL_SENTINEL_PREFIX = "ICC MHC2 Install Sentinel "
MHC2_FLUSH_PREFIX = "ICC MHC2 Flush "


def is_mhc2_sentinel_name(name):
    """Return whether a row is a measurement-protocol row, not a fit input.

    Sentinel rows exist only to prove the applied Windows transform did not
    change while a series ran.  Flush rows exist only to normalize the
    panel's near-black history before a dark patch is read (QD-OLED panels
    were measured reading up to 1.85x low at codes <= 153 after minutes of
    sustained near-black content, with full recovery seconds after mid-grey
    content).  Both repeat stimuli the characterization already contains, so
    letting them into any fit would double-weight those codes or blend
    different panel history states.
    """
    name = str(name)
    return (name.startswith(MHC2_ACTIVE_SENTINEL_PREFIX)
            or name.startswith(MHC2_INSTALL_SENTINEL_PREFIX)
            or name.startswith(MHC2_FLUSH_PREFIX))


# Both thresholds are generic and sized from hardware evidence, not from any
# panel constant.  A stable applied transform showed 0.9-2.2% per-channel
# pair-mean spread inside one signed probe block and roughly 4-6% benign
# meter/panel drift over five minutes at these neutral codes; the observed
# failure mode was a mid-series transform change of 1.85-1.95x.  The ladder
# row and its probe block are measured up to about eight minutes apart in an
# eleven-minute series, so 15% clears worst-case benign drift with margin
# while sitting far below the failure signature.  A probe block spans under
# one minute, so 10% is already generous for its internal spread.
MHC2_ACTIVE_LADDER_CENTROID_LIMIT = 0.15
MHC2_ACTIVE_PROBE_SPREAD_LIMIT = 0.10


def validate_mhc2_active_response_coherence(rows):
    """Reject active-path rows that were not measured through one transform.

    Every signed shadow probe block centers on a neutral code that the active
    grey ladder also measured.  Under a single applied transform the block's
    six-probe luminance centroid must agree with the ladder row, and the three
    per-channel pair means inside the block must agree with each other.  A
    violation means the effective Windows/Companion transform changed during
    the series; fitting such rows blends two transforms into one correction.
    """
    probe_pattern = re.compile(r"^ICC MHC2 Shadow Jacobian (\d+) ([RGB])([+-])$")
    groups = {}
    for row in rows:
        match = probe_pattern.match(str(row.get("name", "")))
        if match:
            groups.setdefault(int(match.group(1)), {})[
                match.group(2) + match.group(3)] = row
    for code in sorted(groups):
        probes = groups[code]
        if any(channel + sign not in probes
               for channel in "RGB" for sign in "-+"):
            continue
        pair_means = [
            0.5 * (probes[channel + "-"]["xyz"][1]
                   + probes[channel + "+"]["xyz"][1])
            for channel in "RGB"
        ]
        centroid = sum(pair_means) / 3.0
        if centroid <= 0:
            fail("Active Windows path shadow probes at neutral code "
                 "{} returned no light; remeasure the active path".format(code))
        spread = (max(pair_means) - min(pair_means)) / centroid
        if spread > MHC2_ACTIVE_PROBE_SPREAD_LIMIT:
            fail("Active Windows path shadow probes at neutral code {} "
                 "disagree between channels by {:.0f}% (R/G/B pair means "
                 "{:.4f}/{:.4f}/{:.4f} cd/m2). The applied transform drifted "
                 "while the probe block ran; reinstall the seed profile and "
                 "remeasure the active characterization".format(
                     code, spread * 100.0, pair_means[0], pair_means[1],
                     pair_means[2]))
        normalized = code / float(probes["R+"]["input_max"])
        ladder = sorted(
            row["xyz"][1] for row in rows
            if max(row["rgb"]) - min(row["rgb"]) <= 0.002
            and abs(sum(row["rgb"]) / 3.0 - normalized) <= 0.0005
            and not probe_pattern.match(str(row.get("name", ""))))
        if not ladder:
            continue
        middle = len(ladder) // 2
        ladder_y = (ladder[middle] if len(ladder) % 2 else
                    0.5 * (ladder[middle - 1] + ladder[middle]))
        if ladder_y <= 0:
            fail("Active Windows path neutral code {} measured no light in "
                 "the grey ladder; remeasure the active path".format(code))
        ratio = centroid / ladder_y
        if max(ratio, 1.0 / ratio) - 1.0 > MHC2_ACTIVE_LADDER_CENTROID_LIMIT:
            fail("Active Windows path response is incoherent: neutral code "
                 "{} measured Y {:.4f} cd/m2 in the grey ladder but {:.4f} "
                 "cd/m2 at its signed shadow probes ({:.2f}x). The applied "
                 "transform changed between those reads; reinstall the seed "
                 "profile, wait for it to settle, and remeasure the active "
                 "characterization".format(code, ladder_y, centroid, ratio))


def windows_hdr_adjustment_luts(rows, black, white, primaries, entries, wire, adjustment,
                                hold_plateau=True):
    """Invert the measured neutral response in the post-PQ MHC2 stage.

    The table input is a PQ wire code after the MHC2 matrix. Map its absolute
    luminance into the measured panel range, then invert the measured channel
    response. This is the part of the profile that corrects a display's PQ
    tracking and near-black response; an identity table cannot do that.
    """
    channel_samples = neutral_channel_samples(rows, black, primaries)
    black_nits = max(0.0, black["xyz"][1])
    peak_nits = max(white["xyz"][1], black_nits + 0.0001)
    span = peak_nits - black_nits
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(adjustment, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    maximum_gain = max(neutral_gains)
    if min(neutral_gains) <= 1e-6 or maximum_gain <= 1e-6:
        fail("HDR MHC2 calibration matrix has an invalid neutral response")
    # Over the plateau the ramp inverse is no longer unique: a channel asked
    # for the last fraction of a percent of its own peak response resolves
    # anywhere inside the flat top. The channel carrying the largest matrix
    # gain is asked for exactly that, so on its own it runs to the far end of
    # the plateau while the other two stop at the knee, and every input above
    # the display's peak then renders in that channel's colour. Above the peak
    # this table's job is to hold peak white, so hold the whole triplet at the
    # drive that reached the knee instead of letting one channel continue.
    # A ceiling of 1.0 is unreachable, so hold_plateau=False reproduces the
    # unheld tail exactly for callers pinned to it.
    ceiling = neutral_plateau_code(rows) if hold_plateau else 1.0
    channel_limits = [gain / maximum_gain for gain in neutral_gains]
    luts = [[] for _channel in range(3)]
    held = [0.0, 0.0, 0.0]
    clamped = False
    for index in range(entries):
        encoded = index / float(entries - 1)
        neutral = max(0.0, min(1.0, (pq_to_nits(encoded) - black_nits) / span))
        if not clamped:
            values = [
                invert_channel_response(channel_samples[channel],
                                        min(neutral, channel_limits[channel]))
                for channel in range(3)
            ]
            if max(values) > ceiling:
                clamped = True
            else:
                held = [max(held[channel], max(0.0, min(1.0, values[channel])))
                        for channel in range(3)]
        for channel in range(3):
            luts[channel].append(held[channel])
    for values in luts:
        values[0] = 0.0
    return luts


def mhc2_wire_matrix(profile_type):
    if profile_type == "windows-hdr":
        return xy_matrix(((0.708, 0.292), (0.170, 0.797), (0.131, 0.046)), (0.3127, 0.3290))
    return xy_matrix(((0.640, 0.330), (0.300, 0.600), (0.150, 0.060)), (0.3127, 0.3290))


def mhc2_hdr_with_neutral_headroom(adjustment, luts, wire,
                                   headroom=MHC2_HDR_NEUTRAL_HEADROOM):
    """Move a uniform HDR matrix scale into its curves without changing it."""
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(adjustment, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    maximum_gain = max(neutral_gains)
    if min(neutral_gains) <= 1e-6 or maximum_gain <= 1e-6:
        fail("HDR MHC2 calibration matrix has an invalid neutral response")
    if maximum_gain <= headroom:
        return adjustment, luts, 1.0

    scale = headroom / maximum_gain
    scaled = [[value * scale for value in row] for row in adjustment]
    remapped = []
    for curve in luts:
        values = []
        previous = 0.0
        for index in range(len(curve)):
            position = index / float(len(curve) - 1)
            source_position = nits_to_pq(min(10000.0, pq_to_nits(position) / scale))
            value = max(previous, max(0.0, min(1.0, sample_table(curve, source_position))))
            values.append(value)
            previous = value
        values[0] = curve[0]
        remapped.append(values)
    return scaled, remapped, scale


def mhc2_payload(profile_type, black, white, primaries, rows, target_transfer="srgb",
                 apply_calibration=True, adjustment_luts_override=None,
                 hdr_neutral_headroom=False, calibrated_peak_override=None):
    physical = measured_primary_matrix(black, white, primaries)
    wire = mhc2_wire_matrix(profile_type)
    identity = [[1.0 if row == column else 0.0 for column in range(3)] for row in range(3)]
    adjustment = mat_mul(wire, mat_inv(physical)) if apply_calibration else identity
    calibrated_peak = max(white["xyz"][1], black["xyz"][1] + 0.0001)
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(adjustment, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    if not apply_calibration:
        pass
    elif profile_type == "windows-sdr":
        # A white-point correction that asks any channel for more than 1.0
        # clips before reaching the requested chromaticity. Apply a uniform
        # matrix scale so corrected neutral white remains inside RGB range.
        maximum_gain = max(neutral_gains)
        if maximum_gain > 1.0:
            matrix_scale = 1.0 / maximum_gain
            adjustment = [[value * matrix_scale for value in row] for row in adjustment]
            calibrated_peak = black["xyz"][1] + matrix_scale * (white["xyz"][1] - black["xyz"][1])
    else:
        maximum_gain = max(neutral_gains)
        if min(neutral_gains) <= 1e-6 or maximum_gain <= 1e-6:
            fail("HDR MHC2 calibration matrix has an invalid neutral response")
        calibrated_peak = black["xyz"][1] + (white["xyz"][1] - black["xyz"][1]) / maximum_gain
    if calibrated_peak_override is not None:
        calibrated_peak = min(
            calibrated_peak,
            max(black["xyz"][1] + 0.0001,
                finite_number(calibrated_peak_override,
                              "calibrated peak override")),
        )
    entries = mhc2_lut_entries(profile_type)
    # MHC2 curves operate after Windows applies the wire transfer function.
    # They contain only the measured post-transfer adjustment, never the wire
    # transfer function itself. Both HDR and SDR invert the measured channel
    # ramps while the matrix corrects primaries and white point.
    if adjustment_luts_override is not None:
        if (len(adjustment_luts_override) != 3
                or any(len(curve) != entries for curve in adjustment_luts_override)):
            fail("MHC2 adjustment curve override has an invalid size")
        luts = adjustment_luts_override
    elif not apply_calibration:
        luts = [[index / float(entries - 1) for index in range(entries)] for _channel in range(3)]
    elif profile_type == "windows-sdr":
        luts = windows_sdr_adjustment_luts(rows, black, white, primaries, entries, target_transfer, wire, adjustment)
    else:
        luts = windows_hdr_adjustment_luts(rows, black, white, primaries, entries, wire, adjustment)
    if profile_type == "windows-hdr" and apply_calibration and hdr_neutral_headroom:
        adjustment, luts, _ = mhc2_hdr_with_neutral_headroom(adjustment, luts, wire)

    header_size = 36
    matrix_offset = header_size
    lut0_offset = matrix_offset + 48
    lut_bytes = 8 + entries * 4
    offsets = (lut0_offset, lut0_offset + lut_bytes, lut0_offset + 2 * lut_bytes)
    min_luminance = max(0.0, black["xyz"][1])
    peak_luminance = max(calibrated_peak, min_luminance + 0.0001)
    data = bytearray(b"MHC2" + b"\0\0\0\0")
    data.extend(struct.pack(">I", entries))
    data.extend(s15fixed16(min_luminance))
    data.extend(s15fixed16(peak_luminance))
    data.extend(struct.pack(">IIII", matrix_offset, *offsets))
    for row in adjustment:
        for value in (row[0], row[1], row[2], 0.0):
            data.extend(s15fixed16(value))
    for values in luts:
        data.extend(b"sf32" + b"\0\0\0\0")
        for value in values:
            data.extend(s15fixed16(value))
    return bytes(data), adjustment, luts, calibrated_peak


def xyz_tag(xyz):
    return b"XYZ " + b"\0\0\0\0" + b"".join(s15fixed16(value) for value in xyz)


def cicp_tag(values):
    """Build an ICC v4.4 cicpType payload from validated H.273 code points."""
    return b"cicp" + b"\0\0\0\0" + struct.pack(
        "BBBB",
        values["colour_primaries"],
        values["transfer_characteristics"],
        values["matrix_coefficients"],
        values["video_full_range_flag"],
    )


def profile_association_tag(profile_type):
    """Mark which Windows per-user display association owns this profile.

    MHC2 luminance is not a signal-mode discriminator: a bright SDR display
    can exceed a dim HDR display.  Keep the payload deliberately simple and
    private so colour engines ignore it while Profile Loader can classify a
    renamed profile without guessing from its luminance or filename.
    """
    association = {
        "windows-sdr": b"windows-sdr",
        "windows-hdr": b"windows-hdr",
    }.get(profile_type)
    if association is None:
        return None
    return b"text" + b"\0\0\0\0" + association + b"\0"


def profile_calibration_contract_tag(profile_type, calibration_mode, profile_model,
                                     independent_mhc2=False):
    """Record how independent ICC consumers must obtain calibration.

    A Windows HDR profile can serve two consumers that never run together:
    Windows applies MHC2, while Patch Companion's explicit cLUT path evaluates
    B2A0 with Windows colour handling isolated. In no-VCGT profile mode the
    same neutral correction therefore lives in both representations. Keep a
    private marker in the profile so fine-tune can update both without guessing
    from a filename or an external sidecar.
    """
    if (profile_type == "windows-hdr" and calibration_mode == "profile"
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        if independent_mhc2:
            # The Windows-system response was characterized after activating
            # a null MHC2 profile, while B2A was fitted from raw measurements.
            # They are deliberately independent correction paths. Fine-tune
            # must never mirror an MHC2 residual into the explicit cLUT.
            contract = b"mhc2-common-tone+b2a-shapers"
        else:
            # Legacy one-pass profiles derive both representations from the
            # same raw characterization and retain the mirrored contract.
            contract = b"mhc2+b2a-shapers"
    else:
        contract = calibration_mode.encode("ascii")
    return b"text" + b"\0\0\0\0" + contract + b"\0"


def read_icc_tags(profile):
    if len(profile) < 132 or profile[36:40] != b"acsp":
        fail("ArgyllCMS did not create a valid ICC profile")
    count = struct.unpack(">I", profile[128:132])[0]
    if count > 256 or 132 + count * 12 > len(profile):
        fail("ICC tag table is invalid")
    tags = []
    for index in range(count):
        start = 132 + index * 12
        signature, offset, size = struct.unpack(">4sII", profile[start:start + 12])
        if offset + size > len(profile):
            fail("ICC tag data is invalid")
        tags.append((signature, profile[offset:offset + size]))
    return tags


def rebuild_icc(profile, replacements):
    original = read_icc_tags(profile)
    tags = []
    replaced = set()
    for signature, payload in original:
        if signature in replacements:
            if signature not in replaced:
                replacement = replacements[signature]
                if replacement is not None:
                    tags.append((signature, replacement))
                replaced.add(signature)
        else:
            tags.append((signature, payload))
    for signature, payload in replacements.items():
        if signature not in replaced and payload is not None:
            tags.append((signature, payload))
    header = bytearray(profile[:128])
    header[84:100] = b"\0" * 16
    table_size = 4 + len(tags) * 12
    offset = 128 + table_size
    entries = []
    blocks = bytearray()
    for signature, payload in tags:
        padding = (-offset) % 4
        if padding:
            blocks.extend(b"\0" * padding)
            offset += padding
        entries.append((signature, offset, len(payload)))
        blocks.extend(payload)
        offset += len(payload)
    result = header + struct.pack(">I", len(entries))
    for signature, tag_offset, size in entries:
        result.extend(struct.pack(">4sII", signature, tag_offset, size))
    result.extend(blocks)
    struct.pack_into(">I", result, 0, len(result))
    return bytes(result)


# --- Batch (NumPy) twins of the scalar primitives above ---------------------
#
# Every helper below reproduces its scalar original expression by expression so
# the 65-cube B2A solvers can run over whole lattices without changing a single
# rounding decision. The rules that keep them bit-identical:
#
#   * no np.dot / @ / einsum / arr.sum() for order-sensitive accumulations --
#     three-term rows are written out so the left-to-right association of the
#     scalar sum() is preserved,
#   * every division inside a np.where is guarded on both branches, because
#     np.where evaluates the branch it discards and the Perl caller parses this
#     script's stdout: one RuntimeWarning corrupts the protocol,
#   * squaring goes through _pow2 (see its comment),
#   * quantization is always rint -> clip -> ">u2", which is exactly the scalar
#     int(round(x)) then clamp for the finite values these tables hold.
#
# Nodes are processed in chunks by the callers: a 65-cube is 274,625 nodes and
# the appliance cannot hold a dozen live (N, 3) float64 temporaries at once.
# At the 65-cube default, 8192 keeps the peak resident set in the same tens-of-
# MiB range as the scalar implementation without materially affecting runtime.
_BATCH_CHUNK = 8192


def _pow2(values):
    """Square an array the way CPython's ``x ** 2`` does.

    NumPy takes a squaring fast path for a scalar exponent of 2 that disagrees
    with libm pow on roughly 0.15% of inputs by one ulp. An array exponent
    forces the generic pow loop, which matches CPython exactly. Measured 0
    mismatches over 400k samples where the fast path had 648.
    """
    return values ** np.full(np.shape(values), 2.0)


def _np_sample_table(table, position):
    """Batch twin of sample_table()."""
    position = np.clip(position, 0.0, 1.0)
    spot = position * (len(table) - 1)
    low = np.minimum(len(table) - 2, spot.astype(np.intp))
    fraction = spot - low
    return table[low] * (1.0 - fraction) + table[low + 1] * fraction


def _np_table_bisect(table, value):
    """Replay the scalar table bisection over a whole array of values.

    Both scalar inverses converge on the rightmost index whose entry is still
    below the requested value. Replaying the loop rather than translating it
    into a searchsorted side keeps the plateau behaviour correct even if a
    table ever arrives non-monotonic.
    """
    low = np.zeros(np.shape(value), dtype=np.intp)
    high = np.full(np.shape(value), len(table) - 1, dtype=np.intp)
    while True:
        active = low < high - 1
        if not np.any(active):
            return low, high
        middle = (low + high) // 2
        below = table[middle] <= value
        low = np.where(active & below, middle, low)
        high = np.where(active & ~below, middle, high)


def _np_invert_table(table, value):
    """Batch twin of invert_table()."""
    value = np.clip(value, 0.0, 1.0)
    low, high = _np_table_bisect(table, value)
    step = table[high] - table[low]
    positive = step > 0
    fraction = np.where(positive,
                        (value - table[low]) / np.where(positive, step, 1.0),
                        0.0)
    result = (low + fraction) / (len(table) - 1.0)
    # Applied in reverse order so the scalar's first test wins on a degenerate
    # table whose two endpoint conditions can both be true.
    result = np.where(value >= table[-1], 1.0, result)
    return np.where(value <= table[0], 0.0, result)


def _np_calibration_to_profile_value(curve, device):
    """Batch twin of calibration_to_profile_value().

    Identical to _np_invert_table() except that the scalar original does not
    clamp its input first.
    """
    entries = len(curve)
    low, high = _np_table_bisect(curve, device)
    step = curve[high] - curve[low]
    positive = step > 0
    fraction = np.where(positive,
                        (device - curve[low]) / np.where(positive, step, 1.0),
                        0.0)
    result = (low + fraction) / (entries - 1.0)
    result = np.where(device >= curve[-1], 1.0, result)
    return np.where(device <= curve[0], 0.0, result)


def _np_clut_trilinear(table, grid, coordinates):
    """Batch twin of _sample_mft2_clut(); (N, 3) in, (N, 3) out.

    The eight corners are accumulated in the scalar's red/green/blue nesting
    order because floating-point addition is not associative.
    """
    positions = np.clip(coordinates, 0.0, 1.0) * (grid - 1)
    lows = np.minimum(grid - 2, positions.astype(np.intp))
    fractions = positions - lows
    base = (lows[:, 0] * grid * grid + lows[:, 1] * grid + lows[:, 2]) * 3
    result = np.zeros(coordinates.shape, dtype=np.float64)
    for red in (0, 1):
        red_weight = fractions[:, 0] if red else 1.0 - fractions[:, 0]
        for green in (0, 1):
            green_weight = fractions[:, 1] if green else 1.0 - fractions[:, 1]
            for blue in (0, 1):
                blue_weight = fractions[:, 2] if blue else 1.0 - fractions[:, 2]
                weight = red_weight * green_weight * blue_weight
                node = base + (red * grid * grid + green * grid + blue) * 3
                for channel in range(3):
                    result[:, channel] += table[node + channel] * weight
    return result


# Per-tetrahedron middle-node offsets and weight permutations, in the branch
# order of _sample_mft2_clut_tetrahedral(). Case ids follow the scalar tree:
# r>=g ? (g>=b ? 0 : r>=b ? 1 : 2) : (r>=b ? 3 : g>=b ? 4 : 5).
_TETRA_FIRST_MIDDLE = np.array(
    ((1, 0, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 0), (0, 0, 1)),
    dtype=np.intp)
_TETRA_SECOND_MIDDLE = np.array(
    ((1, 1, 0), (1, 0, 1), (1, 0, 1), (1, 1, 0), (0, 1, 1), (0, 1, 1)),
    dtype=np.intp)
_TETRA_WEIGHT_ORDER = np.array(
    ((0, 1, 2), (0, 2, 1), (2, 0, 1), (1, 0, 2), (1, 2, 0), (2, 1, 0)),
    dtype=np.intp)


def _np_clut_tetrahedral(table, grid, coordinates):
    """Batch twin of _sample_mft2_clut_tetrahedral(); (N, 3) in, (N, 3) out."""
    positions = np.clip(coordinates, 0.0, 1.0) * (grid - 1)
    lows = np.minimum(grid - 2, positions.astype(np.intp))
    fractions = positions - lows
    base = (lows[:, 0] * grid * grid + lows[:, 1] * grid + lows[:, 2]) * 3
    red, green, blue = fractions[:, 0], fractions[:, 1], fractions[:, 2]
    # The >= comparisons are the ArgyllCMS contract: ties must land in the
    # same tetrahedron the scalar tree picks.
    case = np.where(red >= green,
                    np.where(green >= blue, 0, np.where(red >= blue, 1, 2)),
                    np.where(red >= blue, 3, np.where(green >= blue, 4, 5)))
    rows = np.arange(coordinates.shape[0])
    weights = fractions[rows[:, None], _TETRA_WEIGHT_ORDER[case]]
    offsets = _TETRA_FIRST_MIDDLE[case]
    first_middle = base + (offsets[:, 0] * grid * grid
                           + offsets[:, 1] * grid + offsets[:, 2]) * 3
    offsets = _TETRA_SECOND_MIDDLE[case]
    second_middle = base + (offsets[:, 0] * grid * grid
                            + offsets[:, 1] * grid + offsets[:, 2]) * 3
    last = base + (grid * grid + grid + 1) * 3
    result = np.empty(coordinates.shape, dtype=np.float64)
    for channel in range(3):
        corner = table[base + channel]
        middle0 = table[first_middle + channel]
        middle1 = table[second_middle + channel]
        result[:, channel] = (corner
                              + weights[:, 0] * (middle0 - corner)
                              + weights[:, 1] * (middle1 - middle0)
                              + weights[:, 2] * (table[last + channel] - middle1))
    return result


def _np_mat3_apply(matrix, vectors):
    """Apply a row-major nine-element 3x3 to an (N, 3) array."""
    result = np.empty(vectors.shape, dtype=np.float64)
    for row in range(3):
        result[:, row] = (matrix[row * 3] * vectors[:, 0]
                          + matrix[row * 3 + 1] * vectors[:, 1]
                          + matrix[row * 3 + 2] * vectors[:, 2])
    return result


def _np_mat_inv3(entries):
    """Elementwise 3x3 adjugate inverse over N matrices.

    ``entries`` is a nine-element sequence of (N,) arrays in row-major order;
    the return is the same shape plus a validity mask replacing mat_inv()'s
    "Measured primary matrix is singular" failure. The explicit adjugate is
    deliberate: np.linalg.inv would round differently from the scalar
    cofactor expressions this mirrors.
    """
    a, b, c, d, e, f, g, h, i = entries
    determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    valid = np.abs(determinant) >= 1e-9
    divisor = np.where(valid, determinant, 1.0)
    inverse = (
        (e * i - f * h) / divisor, (c * h - b * i) / divisor, (b * f - c * e) / divisor,
        (f * g - d * i) / divisor, (a * i - c * g) / divisor, (c * d - a * f) / divisor,
        (d * h - e * g) / divisor, (b * g - a * h) / divisor, (a * e - b * d) / divisor,
    )
    return inverse, valid


def _np_pq_to_nits(value):
    """Batch twin of pq_to_nits()."""
    value = np.clip(value, 0.0, 1.0)
    power = value ** (1.0 / PQ_M2)
    return 10000.0 * (np.maximum(power - PQ_C1, 0.0)
                      / np.maximum(PQ_C2 - PQ_C3 * power, 1e-12)) ** (1.0 / PQ_M1)


def _np_nits_to_pq(nits):
    """Batch twin of nits_to_pq()."""
    ratio = np.maximum(0.0, nits) / 10000.0
    powered = ratio ** PQ_M1
    return ((PQ_C1 + PQ_C2 * powered)
            / (1.0 + PQ_C3 * powered)) ** PQ_M2


def _np_smoothstep(value):
    """Batch twin of smoothstep()."""
    value = np.clip(value, 0.0, 1.0)
    return value * value * (3.0 - 2.0 * value)


def _np_u16_bytes(values):
    """Quantize to big-endian u16 exactly as int(round(x)) then clamp does."""
    return np.clip(np.rint(values * 65535.0), 0.0, 65535.0).astype(">u2").tobytes()


def _np_lattice_axes(grid, start, stop):
    """Integer node axes for a red-slowest/blue-fastest cLUT walk."""
    index = np.arange(start, stop, dtype=np.intp)
    red = index // (grid * grid)
    green = (index // grid) % grid
    blue = index % grid
    return red, green, blue


def _np_mft2_tables(payload, offset, entries):
    return np.frombuffer(payload, dtype=">u2", count=entries,
                         offset=offset) / 65535.0


def _np_first_at_or_above(bounds, values):
    """Batch replay of the scalar ``for i in 1..n-1: if value <= bounds[i]`` scan.

    Returns the matching index and a mask marking the values that ran off the
    end of the scan, where the scalar loops take their trailing return. The
    boolean matrix is used rather than searchsorted so the result does not
    depend on the bounds being sorted; the anchor lists here are short.
    """
    hits = values[:, None] <= bounds[None, 1:]
    found = np.any(hits, axis=1)
    return np.where(found, np.argmax(hits, axis=1) + 1, len(bounds) - 1), found


# Entries processed per neighbourhood-fit block. The distance matrix is
# (block, measurements), so this bounds the largest temporary the local
# Jacobian fit allocates.
_FIT_CHUNK = 512


def regularize_hdr_shadow_balance(curves):
    """Suppress local HDR shadow chroma oscillation without moving luminance.

    The dense neutral solve can follow isolated low-signal meter noise more
    closely than a real display warrants. Smooth only each channel's offset
    from the triplet mean, using the same broad 10% PQ-code neighbourhood as
    fine-tune. The common drive at every entry is retained, so this cannot
    reshape the measured luminance response. Balanced and smoothly varying
    displays are effectively unchanged.
    """
    if (len(curves) != 3 or min(len(curve) for curve in curves) < 2
            or len(set(len(curve) for curve in curves)) != 1):
        fail("HDR shadow regularization requires three equal calibration curves")
    entries = len(curves[0])
    original = [list(curve) for curve in curves]
    result = [list(curve) for curve in curves]

    for index in range(1, entries):
        position = index / float(entries - 1)
        if position >= 0.45:
            break
        own = [original[channel][index] for channel in range(3)]
        own_mean = sum(own) / 3.0
        weighted_offsets = [0.0, 0.0, 0.0]
        weight_sum = 0.0
        for step in range(-4, 5):
            neighbour = position + step * 0.025
            if neighbour < 0.0 or neighbour > 0.45:
                continue
            values = [sample_table(original[channel], neighbour)
                      for channel in range(3)]
            mean = sum(values) / 3.0
            distance = abs(neighbour - position)
            kernel = max(0.0, 1.0 - distance / 0.101)
            signal = pq_to_nits(neighbour)
            reliability = smoothstep((signal - 0.12) / 0.88)
            weight = kernel * (0.20 + 0.80 * reliability)
            for channel in range(3):
                weighted_offsets[channel] += weight * (values[channel] - mean)
            weight_sum += weight
        if weight_sum <= 0.0:
            continue
        # Fade back to the untouched model before leaving the shadow region,
        # preventing a join at 45% while retaining full smoothing through the
        # 10-35% range where sparse HDR reads most often oscillate.
        strength = (1.0 if position <= 0.35 else
                    smoothstep((0.45 - position) / 0.10))
        for channel in range(3):
            raw_offset = own[channel] - own_mean
            smooth_offset = weighted_offsets[channel] / weight_sum
            offset = raw_offset + strength * (smooth_offset - raw_offset)
            # Below roughly 10 nits, measured chromaticity is less reliable
            # than luminance. Retain the broad correction direction but fade
            # its channel separation instead of trusting its full magnitude.
            # The common drive is unchanged, balanced curves remain a no-op,
            # and confidence reaches one before the HDR body begins.
            signal = pq_to_nits(position)
            confidence = 0.65 + 0.35 * smoothstep(
                (signal - 0.12) / (10.0 - 0.12))
            offset *= confidence
            # Keep this a regularizer, not another calibration stage.
            move = max(-0.012, min(0.012, offset - raw_offset))
            result[channel][index] = max(
                0.0, min(1.0, own_mean + raw_offset + move))

    for channel in range(3):
        result[channel][0] = 0.0
        previous = 0.0
        for index in range(entries):
            previous = max(previous, result[channel][index])
            result[channel][index] = previous
    return result


def sample_channel_response(samples, position):
    """Sample a measured, normalized channel-response fit."""
    position = max(0.0, min(1.0, position))
    if position <= samples[0][0]:
        return samples[0][1]
    for index in range(1, len(samples)):
        x0, y0 = samples[index - 1]
        x1, y1 = samples[index]
        if position <= x1:
            fraction = 0.0 if x1 <= x0 else (position - x0) / (x1 - x0)
            return y0 + fraction * (y1 - y0)
    return samples[-1][1]


def isotonic_curve(values):
    """Pool adjacent curve reversals without extending a local high sample."""
    blocks = []
    for index, value in enumerate(values):
        blocks.append([index, index, float(value), 1.0])
        while (len(blocks) >= 2
               and blocks[-2][2] / blocks[-2][3]
               > blocks[-1][2] / blocks[-1][3]):
            right = blocks.pop()
            left = blocks.pop()
            blocks.append([left[0], right[1], left[2] + right[2],
                           left[3] + right[3]])
    fitted = [0.0] * len(values)
    for start, end, total, weight in blocks:
        value = max(0.0, min(1.0, total / weight))
        for index in range(start, end + 1):
            fitted[index] = value
    return fitted


def apply_mhc2_modeled_neutral_residual(luts, rows, black, primaries,
                                         neutral_gains, damping=0.5,
                                         include_body=False):
    """Close the residual left by the fitted HDR MHC2 neutral model.

    The forward profile fit and the per-channel curves are individually good
    approximations, but a small disagreement between them is magnified at a
    steep OLED knee. Predict their composed neutral output through the
    measured simultaneous-channel response, solve only its remaining D65
    error, then invert that same measured response back into MHC2 drive.

    Plateau samples describe one physical output state and therefore share a
    robust correction. When no separately measured active Windows path is
    available, the profile model also closes its smoothed shadow/body
    residual. Every correction is lower-or-hold in response space, bounded in
    device code and protected by a deadband, so an already-neutral display is
    unchanged.

    Returns True when a material plateau correction was applied. Callers use
    this to keep the exact-white tail attached to the corrected shoulder.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(neutral_gains) != 3 or min(neutral_gains) <= 1e-6):
        fail("Modeled MHC2 neutral correction has invalid calibration data")
    channel_samples = neutral_channel_samples(rows, black, primaries)
    black_xyz = black["xyz"]
    axes = [
        [primaries[column]["xyz"][axis] - black_xyz[axis]
         for column in range(3)]
        for axis in range(3)
    ]
    inverse_axes = mat_inv(axes)
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)

    positions = sorted(set(
        [index / 100.0 for index in range(101)]
        + [sum(row["rgb"]) / 3.0 for row in rows
           if max(row["rgb"]) - min(row["rgb"]) <= 0.002]
    ))
    modeled = []
    for source_code in positions:
        responses = []
        for channel in range(3):
            curve_input = nits_to_pq(
                pq_to_nits(source_code) * neutral_gains[channel])
            device_code = sample_table(luts[channel], curve_input)
            responses.append(sample_channel_response(
                channel_samples[channel], device_code))
        xyz = [
            black_xyz[axis] + sum(
                axes[axis][channel] * responses[channel]
                for channel in range(3))
            for axis in range(3)
        ]
        if xyz[1] <= 0.0 or min(responses) <= 1e-8:
            gains = [1.0, 1.0, 1.0]
        else:
            target_response = mat_vec_mul(
                inverse_axes,
                [xyz[1] * d65[axis] - black_xyz[axis]
                 for axis in range(3)],
            )
            if min(target_response) <= 0.0:
                gains = [1.0, 1.0, 1.0]
            else:
                gains = [max(0.85, min(1.15,
                    target_response[channel] / responses[channel]))
                    for channel in range(3)]
                strongest = max(gains)
                gains = [gain / strongest for gain in gains]
                if max(gains) - min(gains) < 0.003:
                    gains = [1.0, 1.0, 1.0]
        modeled.append({
            "code": source_code,
            "y": xyz[1],
            "gains": gains,
            "rolloff": False,
        })

    peak = max(sample["y"] for sample in modeled)
    rolloff_start = 0.90 * peak
    for sample in modeled:
        sample["rolloff"] = pq_to_nits(sample["code"]) >= rolloff_start
    plateau = [sample for sample in modeled
               if sample["rolloff"] and sample["code"] < 0.999]
    stable = [sample for sample in plateau if sample["y"] >= 0.985 * peak]
    if len(stable) < 3:
        stable = plateau
    plateau_material = False
    if stable:
        pooled = []
        for channel in range(3):
            values = sorted(math.log(max(sample["gains"][channel], 1e-6))
                            for sample in stable)
            middle = len(values) // 2
            value = (values[middle] if len(values) % 2 else
                     0.5 * (values[middle - 1] + values[middle]))
            pooled.append(math.exp(value))
        strongest = max(pooled)
        pooled = [gain / strongest for gain in pooled]
        plateau_material = max(pooled) - min(pooled) >= 0.003
        for sample in modeled:
            if sample["rolloff"]:
                sample["gains"] = list(pooled)

    if include_body:
        original_logs = {
            sample["code"]: [math.log(max(gain, 1e-6))
                             for gain in sample["gains"]]
            for sample in modeled if not sample["rolloff"]
        }
        for sample in modeled:
            if sample["rolloff"] or sample["code"] > 0.45:
                continue
            weighted = [0.0, 0.0, 0.0]
            weight_sum = 0.0
            for neighbour in modeled:
                if neighbour["rolloff"]:
                    continue
                distance = abs(neighbour["code"] - sample["code"])
                if distance >= 0.101:
                    continue
                kernel = max(0.0, 1.0 - distance / 0.101)
                reliability = smoothstep((neighbour["y"] - 0.03) / 0.97)
                weight = kernel * (0.20 + 0.80 * reliability)
                logs = original_logs[neighbour["code"]]
                for channel in range(3):
                    weighted[channel] += weight * logs[channel]
                weight_sum += weight
            if weight_sum > 0.0:
                sample["gains"] = [math.exp(value / weight_sum)
                                   for value in weighted]

    effective = []
    for sample in modeled:
        strength = (1.0 if sample["rolloff"] else
                    smoothstep((sample["y"] - 0.03) / 0.97)
                    if include_body else 0.0)
        effective.append((sample["code"], [
            math.exp(damping * strength * math.log(max(gain, 1e-6)))
            for gain in sample["gains"]
        ]))

    def residual_gain(source_code, channel):
        if source_code <= effective[0][0]:
            return effective[0][1][channel]
        for index in range(1, len(effective)):
            x0, gains0 = effective[index - 1]
            x1, gains1 = effective[index]
            if source_code <= x1:
                fraction = 0.0 if x1 <= x0 else (
                    (source_code - x0) / (x1 - x0))
                return (gains0[channel] * (1.0 - fraction)
                        + gains1[channel] * fraction)
        return effective[-1][1][channel]

    maximum_move = 0.0
    entries = len(luts[0])
    for channel in range(3):
        updated = list(luts[channel])
        for index in range(1, entries):
            curve_input = index / float(entries - 1)
            source_nits = pq_to_nits(curve_input) / neutral_gains[channel]
            source_code = nits_to_pq(source_nits)
            gain = residual_gain(source_code, channel)
            if abs(gain - 1.0) < 0.0005:
                continue
            old = luts[channel][index]
            response = sample_channel_response(channel_samples[channel], old)
            new = invert_channel_response(
                channel_samples[channel], max(0.0, response * gain))
            delta = max(-0.012, min(0.012, new - old))
            updated[index] = old + delta
            maximum_move = max(maximum_move, abs(delta))
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return plateau_material and maximum_move >= 0.5 / 65536.0


def apply_mhc2_balanced_peak_cap(luts, rows, black, white, primaries,
                                 neutral_gains):
    """Keep a non-neutral HDR shoulder inside its measurable channel range.

    An internally tone-mapped display can map many upper device codes to the
    same physical peak. Once every MHC2 channel lands on that plateau, its
    matrix correction is no longer observable and white reverts to the native
    peak chromaticity. Use the measured primary ramps to find the brightest
    D65 response that remains inside every channel's useful range, then bring
    only the upper neutral shoulder down to that measured triplet.

    The cap is conditional on a material measured peak-white error. A display
    whose shoulder is already D65 is left byte-for-byte unchanged.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(neutral_gains) != 3 or min(neutral_gains) <= 1e-6):
        fail("Balanced HDR peak correction has invalid calibration data")
    white_sum = sum(white["xyz"])
    if white_sum <= 1e-9:
        return None
    white_xy = (white["xyz"][0] / white_sum, white["xyz"][1] / white_sum)
    if math.hypot(white_xy[0] - 0.3127, white_xy[1] - 0.3290) < 0.0015:
        return None

    neutral = sorted(
        (sum(row["rgb"]) / 3.0, row["xyz"][1])
        for row in rows if max(row["rgb"]) - min(row["rgb"]) <= 0.002
    )
    if len(neutral) < 9:
        return None
    measured_peak = max(value for _code, value in neutral)
    if measured_peak <= 0.0:
        return None
    # The first point within 5% of measured peak is still on the useful side
    # of a hard OLED knee, while a display that rises continuously reaches it
    # near full drive and therefore gives up almost no range.
    safe_code = min(code for code, value in neutral
                    if value >= measured_peak * 0.95)

    channel_samples = []
    for channel in range(3):
        count = sum(
            1 for row in rows
            if row["rgb"][channel] > 0.0
            and all(row["rgb"][other] <= 0.002
                    for other in range(3) if other != channel)
        )
        if count < 6:
            return None
        channel_samples.append(monotonic_channel_samples(
            rows, black, primaries[channel], channel))

    black_xyz = black["xyz"]
    axes = [
        [primaries[column]["xyz"][axis] - black_xyz[axis]
         for column in range(3)]
        for axis in range(3)
    ]
    inverse_axes = mat_inv(axes)
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    response_per_nit = mat_vec_mul(inverse_axes, d65)
    black_response = mat_vec_mul(
        inverse_axes, [-black_xyz[axis] for axis in range(3)])
    safe_responses = [sample_channel_response(samples, safe_code)
                      for samples in channel_samples]
    limits = []
    for channel in range(3):
        slope = response_per_nit[channel]
        if slope <= 1e-9:
            return None
        limits.append((safe_responses[channel] - black_response[channel])
                      / slope)
    balanced_peak = min(limits)
    if (not math.isfinite(balanced_peak) or balanced_peak <= 0.0
            or balanced_peak < measured_peak * 0.50):
        return None
    target_responses = [
        black_response[channel] + balanced_peak * response_per_nit[channel]
        for channel in range(3)
    ]
    target_codes = [
        invert_channel_response(channel_samples[channel],
                                target_responses[channel])
        for channel in range(3)
    ]

    # A candidate-centred probe set measures the exact unequal RGB triplet
    # proposed by the independent-ramp solve and its local one-sided response.
    # The HDR knee is strongly asymmetric, so selecting the best physically
    # measured candidate is safer than extrapolating a symmetric derivative
    # through the flat side of the plateau. Optional refine rows are generated
    # from that one-sided response and participate in the same selection.
    peak_candidates = [
        row for row in rows
        if (re.match(r"^ICC MHC2 Peak Candidate(?: [RGB][+-])?$",
                     str(row.get("name", "")))
            or re.match(r"^ICC MHC2 Peak Refine [A-Z]+$",
                        str(row.get("name", ""))))
        and row["xyz"][1] >= measured_peak * 0.80
    ]
    if peak_candidates:
        def candidate_error(row):
            total = sum(row["xyz"])
            if total <= 1e-9:
                return float("inf")
            x = row["xyz"][0] / total
            y = row["xyz"][1] / total
            return math.hypot(x - 0.3127, y - 0.3290)

        measured_best = min(peak_candidates, key=candidate_error)
        if candidate_error(measured_best) < math.hypot(
                white_xy[0] - 0.3127, white_xy[1] - 0.3290):
            balanced_peak = measured_best["xyz"][1]
            target_codes = list(measured_best["rgb"])

    shoulder_code = min(code for code, value in neutral
                        if value >= measured_peak * 0.90)
    transition_end = min(balanced_peak, pq_to_nits(shoulder_code))
    transition_start = transition_end * 0.80
    entries = len(luts[0])
    for channel in range(3):
        gain = neutral_gains[channel]
        start_input = nits_to_pq(transition_start * gain)
        anchor = sample_table(luts[channel], start_input)
        target = max(anchor, target_codes[channel])
        updated = []
        for index, old in enumerate(luts[channel]):
            position = index / float(entries - 1)
            source_nits = pq_to_nits(position) / gain
            if source_nits <= transition_start:
                updated.append(old)
                continue
            weight = smoothstep((source_nits - transition_start)
                                / max(transition_end - transition_start, 1e-9))
            ceiling = anchor * (1.0 - weight) + target * weight
            updated.append(ceiling)
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return balanced_peak


def apply_mhc2_active_neutral_luminance(luts, rows, black, primaries,
                                         neutral_gains, calibrated_peak):
    """Put modeled RGB balance on the directly measured neutral PQ curve.

    The raw A2B model provides useful level-dependent channel offsets, but its
    common drive is not the Windows Advanced Color response measured through
    the null MHC2 seed.  Preserve those offsets while moving their mean to the
    device code that the active neutral ramp measured at the requested PQ
    luminance.  An already accurate ramp maps back to the same code.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(neutral_gains) != 3 or min(neutral_gains) <= 1e-6):
        fail("Active HDR MHC2 luminance correction has invalid calibration data")

    grouped = {}
    for row in rows:
        if max(row["rgb"]) - min(row["rgb"]) > 0.002:
            continue
        code = sum(row["rgb"]) / 3.0
        grouped.setdefault(round(code, 7), []).append(row["xyz"][1])
    neutral = []
    previous = max(0.0, black["xyz"][1])
    for code in sorted(grouped):
        values = sorted(grouped[code])
        middle = len(values) // 2
        measured = (values[middle] if len(values) % 2 else
                    0.5 * (values[middle - 1] + values[middle]))
        previous = max(previous, measured)
        neutral.append((code, previous))
    if len(neutral) < 9 or neutral[0][0] > 0.002 or neutral[-1][0] < 0.998:
        fail("Active HDR MHC2 luminance correction requires a full neutral ramp")

    def invert_neutral_luminance(target):
        target = max(neutral[0][1], min(neutral[-1][1], target))
        for index in range(1, len(neutral)):
            code0, y0 = neutral[index - 1]
            code1, y1 = neutral[index]
            if target <= y1 + 1e-9:
                if y1 <= y0 + 1e-9:
                    return code0
                # Interpolate in the PQ domain, not in linear luminance. The
                # measured ladder is sparse and its luminance spans orders of
                # magnitude, so a linear-in-Y segment is a poor fit and leaves
                # a slope discontinuity at every knot. Because each channel
                # samples this inversion at its own gain-scaled level, those
                # kinks land at slightly different curve indices per channel
                # and show up as a pure chroma error at the ladder codes.
                # Hardware evidence: the R curve lost 24% of its slope at
                # codes 410-420 and 710-720, both ladder knots, giving 9.9 and
                # 7.1 chroma dE while luminance stayed within 1.2%. PQ is very
                # nearly linear in code, so this removes the kink.
                p0 = nits_to_pq(y0)
                p1 = nits_to_pq(y1)
                pt = nits_to_pq(target)
                if p1 <= p0 + 1e-12:
                    return code0
                return code0 + (pt - p0) * (code1 - code0) / (p1 - p0)
        return neutral[-1][0]

    # Estimate the small luminance contribution of the retained unequal RGB
    # offsets from the measured primary ramps.  The neutral ramp remains the
    # source of truth for the common, potentially non-additive display drive.
    axis_samples = [
        monotonic_channel_samples(rows, black, primaries[channel], channel)
        for channel in range(3)
    ]
    black_y = max(0.0, black["xyz"][1])
    axis_y = [max(0.0, primary["xyz"][1] - black_y)
              for primary in primaries]
    entries = len(luts[0])
    original = [list(curve) for curve in luts]
    updated = [[] for _channel in range(3)]
    peak = max(float(calibrated_peak), black_y + 0.0001)

    for channel in range(3):
        gain = neutral_gains[channel]
        for index in range(entries):
            curve_input = index / float(entries - 1)
            source_nits = pq_to_nits(curve_input) / gain
            source_code = nits_to_pq(source_nits)
            outputs = []
            for other in range(3):
                other_input = nits_to_pq(source_nits * neutral_gains[other])
                outputs.append(sample_table(original[other], other_input))
            mean_output = sum(outputs) / 3.0
            offsets = [value - mean_output for value in outputs]
            target_y = min(source_nits, peak)
            base = invert_neutral_luminance(target_y)
            for _iteration in range(3):
                delta_y = 0.0
                for other in range(3):
                    shifted = max(0.0, min(1.0, base + offsets[other]))
                    delta_y += axis_y[other] * (
                        sample_channel_response(axis_samples[other], shifted)
                        - sample_channel_response(axis_samples[other], base))
                base = invert_neutral_luminance(max(black_y, target_y - delta_y))
            corrected = max(0.0, min(1.0, base + offsets[channel]))
            # Leave the measured peak-cap transition alone.  The common drive
            # is fully measured through the HDR body, then fades out before
            # the separately probed shoulder owns the response.
            weight = 1.0 - smoothstep((target_y / peak - 0.65) / 0.25)
            updated[channel].append(
                original[channel][index] * (1.0 - weight) + corrected * weight)

    # Re-anchor the common-mode grey drive. The per-entry solve above leaves
    # a measured plus or minus 1.9 code oscillation around the ladder
    # inversion at the ladder knots, verified offline on the user's own
    # build: +1.9 at code 205, -1.8 at 307, +1.75 at 358. That is about 3.5
    # percent luminance and 2 to 3.5 dE ITP on the Windows system path,
    # while the cLUT corridor received an equivalent exactness pass and
    # measures clean. Correct the composite drive the way Windows evaluates
    # it, curve first then matrix gain, against the ladder inversion of the
    # PQ target, shifting all three channels equally so the per-channel
    # chroma offsets are preserved. Fade with the same shoulder weight so
    # the separately probed peak transition stays untouched.
    for index in range(entries):
        curve_input = index / float(entries - 1)
        source_nits = pq_to_nits(curve_input)
        target_y = min(source_nits, peak)
        weight = 1.0 - smoothstep((target_y / peak - 0.65) / 0.25)
        if weight <= 0.0:
            continue
        drives = [nits_to_pq(pq_to_nits(updated[channel][index])
                             * neutral_gains[channel])
                  for channel in range(3)]
        delta = (invert_neutral_luminance(max(black_y, target_y))
                 - sum(drives) / 3.0) * weight
        if abs(delta) < 1e-6:
            continue
        for channel in range(3):
            shifted = max(0.0, min(1.0, drives[channel] + delta))
            updated[channel][index] = max(0.0, min(1.0, nits_to_pq(
                pq_to_nits(shifted) / neutral_gains[channel])))

    for channel in range(3):
        updated[channel] = isotonic_curve(updated[channel])
        updated[channel][0] = 0.0
        luts[channel][:] = updated[channel]


def mhc2_shadow_probe_groups(rows):
    """Group complete-looking MHC2 shadow Jacobian probe rows by code."""
    groups = {}
    pattern = re.compile(r"^ICC MHC2 Shadow Jacobian (\d+) ([RGB])([+-])$")
    for row in rows:
        match = pattern.match(str(row.get("name", "")))
        if match:
            groups.setdefault(int(match.group(1)), {})[
                match.group(2) + match.group(3)] = row
    return groups


def mhc2_active_grey_rows(rows):
    """Return the named active grey-ladder rows, last write wins per code."""
    greys = {}
    pattern = re.compile(r"^ICC MHC2 Active Grey (\d+)$")
    for row in rows:
        match = pattern.match(str(row.get("name", "")))
        if not match:
            continue
        xyz = row.get("xyz")
        rgb = row.get("rgb")
        if (not xyz or not rgb or len(xyz) != 3 or len(rgb) != 3
                or not all(math.isfinite(value) for value in xyz)
                or not all(math.isfinite(value) for value in rgb)):
            continue
        greys[int(match.group(1))] = row
    return greys


def mhc2_complete_shadow_probes(probes):
    return probes and all(channel + sign in probes
                          for channel in "RGB" for sign in "-+")


def mhc2_shadow_probe_jacobian(probes):
    """Build a local dXYZ/dRGB Jacobian from a complete signed probe set."""
    if not mhc2_complete_shadow_probes(probes):
        return None
    midpoints = []
    columns = []
    for channel in "RGB":
        low = probes[channel + "-"]
        high = probes[channel + "+"]
        span = high["rgb"]["RGB".index(channel)] - low["rgb"]["RGB".index(channel)]
        if span <= 1e-9:
            return None
        midpoints.append([0.5 * (low["xyz"][axis] + high["xyz"][axis])
                          for axis in range(3)])
        columns.append([(high["xyz"][axis] - low["xyz"][axis]) / span
                        for axis in range(3)])
    if len(columns) != 3:
        return None
    center_xyz = [sum(value[axis] for value in midpoints) / 3.0
                  for axis in range(3)]
    jacobian = [[columns[column][axis] for column in range(3)]
                for axis in range(3)]
    center_code = [
        0.5 * (probes[channel + "-"]["rgb"][index]
               + probes[channel + "+"]["rgb"][index])
        for index, channel in enumerate("RGB")
    ]
    input_max = float(probes["R+"]["input_max"])
    if input_max <= 1e-9:
        return None
    return {
        "jacobian": jacobian,
        "center_xyz": center_xyz,
        "center_code": center_code,
        "input_max": input_max,
    }


def shadow_chroma_lut_delta(center_xyz, center_code, jacobian, source_code,
                            luts, neutral_gains):
    """Solve D65 chromaticity at the measured luminance into a LUT delta.

    Luminance in this region is already owned by the measured neutral ramp in
    apply_mhc2_active_neutral_luminance. Solving the absolute PQ target here
    as well double-counts the common drive, which is what drove codes 205/307
    outside their probe hull on the coherent chain. Target D65 chromaticity at
    the luminance the panel actually produced, so this stage contributes a
    pure chroma rotation and the two stages stay separable.
    """
    center_y = center_xyz[1]
    if center_y <= 1e-9:
        return None
    center_total = sum(center_xyz)
    if center_total <= 1e-9:
        return None
    center_error = math.hypot(center_xyz[0] / center_total - 0.3127,
                              center_xyz[1] / center_total - 0.3290)
    # An already neutral corridor must be left alone.  Near black the
    # measured chroma carries real meter noise, and solving inside that
    # noise injects a visible tint where there was none.
    if center_error <= MHC2_SHADOW_CHROMA_DEADBAND:
        return None
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    delta = mat_vec_mul(mat_inv(jacobian), [
        center_y * d65[axis] - center_xyz[axis] for axis in range(3)
    ])
    if not all(math.isfinite(value) for value in delta):
        return None
    # With the target corrected to pure chroma this is a well aimed
    # one-step Newton move, so apply it in full and let the bound below
    # cap any pathological solve.  Damping a correctly aimed move only
    # leaves a residual too large for the feedback hull to close.
    target_codes = [max(center_code[channel] - 0.03,
                        min(center_code[channel] + 0.03,
                            center_code[channel] + delta[channel]))
                    for channel in range(3)]
    source_nits = pq_to_nits(source_code)
    current = []
    for channel in range(3):
        curve_input = nits_to_pq(source_nits * neutral_gains[channel])
        current.append(sample_table(luts[channel], curve_input))
    raw = [target_codes[channel] - current[channel] for channel in range(3)]
    # Remove the post-gain common-mode so this stage stays the pure chroma
    # rotation it claims to be. Measured on the user's build: these anchors
    # leaked plus or minus 2 codes of grey drive at the anchor codes, which
    # re-added the exact oscillation the neutral re-anchor pass had just
    # removed, since this stage runs after it.
    shifts = []
    for channel in range(3):
        before = nits_to_pq(pq_to_nits(current[channel])
                            * neutral_gains[channel])
        after = nits_to_pq(pq_to_nits(max(0.0, min(1.0,
                current[channel] + raw[channel])))
                * neutral_gains[channel])
        shifts.append(after - before)
    mean_shift = sum(shifts) / 3.0
    adjusted = []
    for channel in range(3):
        before = nits_to_pq(pq_to_nits(current[channel])
                            * neutral_gains[channel])
        wanted = max(0.0, min(1.0, before + shifts[channel] - mean_shift))
        adjusted.append(nits_to_pq(pq_to_nits(wanted)
                        / neutral_gains[channel]) - current[channel])
    return adjusted


def borrowed_shadow_grey_anchors(luts, rows, neutral_gains, probed, groups):
    """Chroma anchors for greys below the lowest viable probe.

    Direct probes at these codes are meter noise, and reusing the lowest
    probed correction value itself was measured to make the cast worse. Use
    each grey row's own measured XYZ as the error and borrow only the
    nearest viable Jacobian for direction and scale.
    """
    if not probed:
        return []
    lowest_probed = min(probed)
    anchors = []
    for code, row in sorted(mhc2_active_grey_rows(rows).items()):
        if code >= lowest_probed:
            continue
        if mhc2_complete_shadow_probes(groups.get(code)):
            continue
        input_max = float(row.get("input_max") or 0.0)
        if input_max <= 1e-9:
            continue
        measured = row.get("xyz")
        if (not measured or len(measured) != 3
                or not math.isfinite(measured[1])
                or measured[1] < MHC2_BORROWED_GREY_MIN_NITS):
            continue
        nearest = min(probed, key=lambda candidate: (
            abs(candidate - code), candidate))
        source_code = code / input_max
        lut_delta = shadow_chroma_lut_delta(
            list(row["xyz"]), list(row["rgb"]),
            probed[nearest]["jacobian"], source_code, luts, neutral_gains)
        if lut_delta is not None:
            anchors.append((source_code, lut_delta))
    return anchors


def apply_interpolated_lut_anchors(luts, anchors, neutral_gains, start, end):
    """Add interpolated RGB deltas to MHC2 or B2A 1D curves."""
    if not anchors:
        return False
    points = [(start, [0.0, 0.0, 0.0])] + anchors + [
        (end, [0.0, 0.0, 0.0])]

    def correction(source_code, channel):
        if source_code <= points[0][0] or source_code >= points[-1][0]:
            return 0.0
        for index in range(1, len(points)):
            x0, values0 = points[index - 1]
            x1, values1 = points[index]
            if source_code <= x1:
                fraction = 0.0 if x1 <= x0 else (
                    (source_code - x0) / (x1 - x0))
                weight = smoothstep(fraction)
                return values0[channel] * (1.0 - weight) + values1[channel] * weight
        return 0.0

    entries = len(luts[0])
    for channel in range(3):
        updated = []
        gain = neutral_gains[channel]
        for index, old in enumerate(luts[channel]):
            curve_input = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
            updated.append(max(0.0, min(1.0,
                old + correction(source_code, channel))))
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return True


def apply_mhc2_active_shadow_jacobians(luts, rows, neutral_gains,
                                        calibrated_peak):
    """Close measured shadow RGB residuals with local active-path probes."""
    groups = mhc2_shadow_probe_groups(rows)
    probed = {}
    anchors = []
    for code in sorted(groups):
        built = mhc2_shadow_probe_jacobian(groups[code])
        if built is None:
            continue
        source_code = code / built["input_max"]
        probed[code] = {
            "jacobian": built["jacobian"],
            "source_code": source_code,
        }
        lut_delta = shadow_chroma_lut_delta(
            built["center_xyz"], built["center_code"], built["jacobian"],
            source_code, luts, neutral_gains)
        if lut_delta is not None:
            anchors.append((source_code, lut_delta))
    borrowed = borrowed_shadow_grey_anchors(
        luts, rows, neutral_gains, probed, groups)
    if borrowed:
        anchors.extend(borrowed)
        lowest_source = probed[min(probed)]["source_code"]
        if not any(abs(source - lowest_source) <= 1e-12
                   for source, _delta in anchors):
            # Keep a probed code's own (zero) correction. A borrowed grey
            # must not drag its edit through a code that already had probes.
            anchors.append((lowest_source, [0.0, 0.0, 0.0]))
    anchors.sort(key=lambda item: item[0])
    if not anchors:
        return False

    start = max(0.0, anchors[0][0] - 0.04)
    end = min(1.0, anchors[-1][0] + 0.07)
    return apply_interpolated_lut_anchors(
        luts, anchors, neutral_gains, start, end)


def apply_mhc2_borrowed_shadow_greys(luts, rows, neutral_gains):
    """Apply only borrowed grey-ladder chroma anchors below the first probe.

    The explicit cLUT path does not consume apply_mhc2_active_shadow_jacobians,
    so without this pass code 51's measured cast never reaches B2A. Fade the
    borrowed edit out at the lowest probed code so every code that already
    has its own probes keeps the correction it already had. The curve
    feedback fade is left untouched.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(luts[0]) < 2 or len(neutral_gains) != 3
            or min(neutral_gains) <= 1e-6):
        return False
    groups = mhc2_shadow_probe_groups(rows)
    probed = {}
    for code in sorted(groups):
        built = mhc2_shadow_probe_jacobian(groups[code])
        if built is None:
            continue
        probed[code] = {
            "jacobian": built["jacobian"],
            "source_code": code / built["input_max"],
        }
    borrowed = borrowed_shadow_grey_anchors(
        luts, rows, neutral_gains, probed, groups)
    if not borrowed:
        return False
    start = max(0.0, borrowed[0][0] - 0.04)
    end = probed[min(probed)]["source_code"]
    return apply_interpolated_lut_anchors(
        luts, borrowed, neutral_gains, start, end)


def apply_mhc2_active_shadow_feedback(luts, rows, neutral_gains,
                                       calibrated_peak, damping=0.5,
                                       label="ICC MHC2 Shadow",
                                       output_mapper=None):
    """Close the residual measured through the provisional MHC2 profile."""
    probe_pattern = re.compile(
        r"^{} Jacobian (\d+) ([RGB])([+-])$".format(re.escape(label)))
    feedback_pattern = re.compile(
        r"^{} Feedback (\d+)$".format(re.escape(label)))
    groups = {}
    feedback = {}
    for row in rows:
        match = probe_pattern.match(str(row.get("name", "")))
        if match:
            groups.setdefault(int(match.group(1)), {})[
                match.group(2) + match.group(3)] = row
            continue
        match = feedback_pattern.match(str(row.get("name", "")))
        if match:
            feedback[int(match.group(1))] = row

    anchors = []
    for code in sorted(set(groups).intersection(feedback)):
        probes = groups[code]
        if any(channel + sign not in probes
               for channel in "RGB" for sign in "-+"):
            continue
        columns = []
        for channel in "RGB":
            low = probes[channel + "-"]
            high = probes[channel + "+"]
            component = "RGB".index(channel)
            span = high["rgb"][component] - low["rgb"][component]
            if span <= 1e-9:
                break
            columns.append([(high["xyz"][axis] - low["xyz"][axis]) / span
                            for axis in range(3)])
        if len(columns) != 3:
            continue
        jacobian = [[columns[column][axis] for column in range(3)]
                    for axis in range(3)]
        inverse = mat_inv(jacobian)
        norm = max(sum(abs(jacobian[row][column]) for row in range(3))
                   for column in range(3))
        inverse_norm = max(sum(abs(inverse[row][column]) for row in range(3))
                           for column in range(3))
        if norm * inverse_norm > 50.0:
            # Near-black meter noise can make two probe columns almost
            # dependent. Such a solve amplifies noise into a large chromatic
            # edit; let adjacent well-conditioned anchors interpolate instead.
            continue
        source_code = code / float(probes["R+"]["input_max"])
        target_y = min(pq_to_nits(source_code), calibrated_peak)
        d65 = (0.3127 / 0.3290, 1.0,
               (1.0 - 0.3127 - 0.3290) / 0.3290)
        measured = feedback[code]["xyz"]
        delta = mat_vec_mul(inverse, [
            target_y * d65[axis] - measured[axis] for axis in range(3)
        ])
        # A local linear solve is only a residual correction. Bound it to a
        # small move so noisy near-black measurements cannot reshape a panel
        # that was already close to target.
        # The probes describe the differential response around the current
        # neutral, but the saved correction is evaluated through a quantized
        # 3D-table corridor and the display response is not perfectly linear.
        # Apply half of the one-step Newton move. This keeps the first closed
        # loop stable while a display that is already accurate receives a
        # correspondingly negligible change.
        anchors.append((source_code, [max(-0.02, min(0.02, value * damping))
                                     for value in delta]))
    if not anchors:
        return False

    start = max(0.0, anchors[0][0] - 0.04)
    end = min(1.0, anchors[-1][0] + 0.07)
    points = [(start, [0.0, 0.0, 0.0])] + anchors + [
        (end, [0.0, 0.0, 0.0])]

    def correction_vector(source_code):
        if source_code <= points[0][0] or source_code >= points[-1][0]:
            return [0.0, 0.0, 0.0]
        for index in range(1, len(points)):
            x0, values0 = points[index - 1]
            x1, values1 = points[index]
            if source_code <= x1:
                fraction = 0.0 if x1 <= x0 else (
                    (source_code - x0) / (x1 - x0))
                weight = smoothstep(fraction)
                correction = [
                    values0[channel] * (1.0 - weight)
                    + values1[channel] * weight for channel in range(3)]
                return (output_mapper(source_code, correction)
                        if output_mapper else correction)
        return [0.0, 0.0, 0.0]

    entries = len(luts[0])
    for channel in range(3):
        updated = []
        gain = neutral_gains[channel]
        for index, old in enumerate(luts[channel]):
            curve_input = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
            correction = correction_vector(source_code)
            updated.append(max(0.0, min(1.0,
                old + correction[channel])))
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return True


def profile_curve_feedback_anchors(rows, label, calibrated_peak,
                                   probe_delta=MHC2_CURVE_FEEDBACK_DELTA,
                                   return_diagnostics=False, codes=None):
    """Choose bounded shadow corrections inside the measured response hull.

    The responses here come from changing the actual profile curve used by
    the selected presentation path. They therefore include Windows, the
    Companion and the display response, unlike source-patch RGB Jacobians.
    Both signs are measured because a one-sided positive probe cannot safely
    predict the negative common correction needed by an over-bright shadow.
    The selected point is a convex combination of Base and the six signed
    probes, so it never relies on a central derivative or a multi-axis corner
    that the hardware did not measure.
    """
    if not math.isfinite(probe_delta) or probe_delta <= 1e-6:
        return []
    by_name = {str(row.get("name", "")): row for row in rows}

    def error_metric(xyz, target_y):
        total = sum(xyz)
        if total <= 1e-9 or xyz[1] <= 1e-9 or target_y <= 1e-9:
            return float("inf")
        chroma = math.hypot(xyz[0] / total - 0.3127,
                            xyz[1] / total - 0.3290) / 0.0015
        luminance = abs(math.log(xyz[1] / target_y)) / 0.04
        return chroma + luminance

    anchors = []
    diagnostics = {}
    for code in (codes or MHC2_CURVE_FEEDBACK_CODES):
        names = {
            "base": "{} Base {}".format(label, code),
            "R+": "{} R+ {}".format(label, code),
            "G+": "{} G+ {}".format(label, code),
            "B+": "{} B+ {}".format(label, code),
            "R-": "{} R- {}".format(label, code),
            "G-": "{} G- {}".format(label, code),
            "B-": "{} B- {}".format(label, code),
        }
        if any(name not in by_name for name in names.values()):
            continue
        measured = {key: by_name[name]["xyz"]
                    for key, name in names.items()}
        base = measured["base"]
        source_code = code / 1023.0
        target_y = min(pq_to_nits(source_code), calibrated_peak)
        if (not all(math.isfinite(value) for value in base)
                or base[1] < target_y * 0.50
                or base[1] > target_y * 1.60):
            continue
        base_total = sum(base)
        if base_total <= 1e-9:
            continue
        chroma_error = math.hypot(
            base[0] / base_total - 0.3127,
            base[1] / base_total - 0.3290)
        luminance_error = abs(base[1] / target_y - 1.0)
        if chroma_error < 0.0007 and luminance_error < 0.02:
            diagnostics[code] = {
                "needed": False,
                "accepted": True,
                "predicted_chroma_error": chroma_error,
            }
            continue

        valid = True
        responses = {}
        for channel in "RGB":
            low = measured[channel + "-"]
            high = measured[channel + "+"]
            if (not all(math.isfinite(value) for probe in (low, high)
                        for value in probe)
                    or min(low[1], high[1]) < base[1] * 0.65
                    or max(low[1], high[1]) > base[1] * 1.35):
                valid = False
                break
            responses[channel + "-"] = [low[axis] - base[axis]
                                          for axis in range(3)]
            responses[channel + "+"] = [high[axis] - base[axis]
                                          for axis in range(3)]
            if max(abs(value) for response in (
                    responses[channel + "-"], responses[channel + "+"])
                    for value in response) < max(1e-5, base[1] * 0.02):
                valid = False
                break
        if not valid:
            continue
        current_error = error_metric(base, target_y)
        current_luminance_error = abs(math.log(base[1] / target_y))
        best = None
        # Twenty-fourth-step weights give a dense, deterministic search of the
        # three-dimensional signed response simplex without an optimizer
        # dependency. The L1 bound is what keeps every result in the convex
        # hull of Base and the six actual probe measurements.
        #
        # An eighth-step grid was coarse enough to be the accuracy limit
        # rather than the measurements: it left code 153 predicting .00631
        # against the .006 recoverability threshold and failed an otherwise
        # good build, while a finer grid of the same constrained problem
        # reaches .00555 there and improves every other code as well.
        weights = [value / 24.0 for value in range(-24, 25)]
        for red in weights:
            for green in weights:
                for blue in weights:
                    vector = (red, green, blue)
                    weight_sum = sum(abs(value) for value in vector)
                    if weight_sum <= 1e-12 or weight_sum > 1.0 + 1e-12:
                        continue
                    delta = [value * probe_delta for value in vector]
                    predicted = list(base)
                    for channel, weight in zip("RGB", vector):
                        if abs(weight) <= 1e-12:
                            continue
                        response = responses[channel + ("+" if weight > 0 else "-")]
                        for axis in range(3):
                            predicted[axis] += abs(weight) * response[axis]
                    predicted_error = error_metric(predicted, target_y)
                    predicted_luminance_error = (
                        abs(math.log(predicted[1] / target_y))
                        if predicted[1] > 1e-9 else float("inf"))
                    # The hard 0.65 to 1.35 window is the real luminance
                    # rail. The incremental allowance only stops the chroma
                    # solve from quietly trading luminance away, so it has to
                    # be loose enough to let a dominant chroma error be fixed.
                    # Measured at code 153: the base sits 5.9% dark with
                    # chroma .01463, and a 0.01 allowance capped the solve at
                    # .00670, failing the .006 recoverability threshold and
                    # blocking every final build. Allowing 0.03 reaches
                    # .00155. By this function's own error_metric, which
                    # scales chroma by 0.0015 and luminance by 0.04, that
                    # trades 0.67 luminance units for 8.7 chroma units.
                    if (predicted[1] < target_y * 0.65
                            or predicted[1] > target_y * 1.35
                            or predicted_luminance_error
                            > current_luminance_error + 0.03):
                        continue
                    candidate = (predicted_error, weight_sum, delta,
                                 predicted)
                    if best is None or candidate[:2] < best[:2]:
                        best = candidate
        # The flushed feedback chain can leave a small residual outside the
        # strict 8% improvement gate after the neutral fit has already moved
        # the same anchor. Preserve the convex-hull requirement, but permit a
        # measured local closure when it improves the chroma error at least 2%.
        accepted = (best is not None and best[0] < current_error * 0.98
                    and max(abs(value) for value in best[2]) >= 0.00015)
        predicted_chroma_error = float("inf")
        if best is not None:
            predicted_total = sum(best[3])
            if predicted_total > 1e-9:
                predicted_chroma_error = math.hypot(
                    best[3][0] / predicted_total - 0.3127,
                    best[3][1] / predicted_total - 0.3290)
        diagnostics[code] = {
            "needed": True,
            "accepted": accepted,
            "predicted_chroma_error": predicted_chroma_error,
        }
        if accepted:
            anchors.append((source_code, best[2]))
    return (anchors, diagnostics) if return_diagnostics else anchors


def validate_profile_curve_feedback_recoverable(rows, label,
                                                calibrated_peak):
    """Reject a stale baseline that one measured response hull cannot close."""
    _anchors, diagnostics = profile_curve_feedback_anchors(
        rows, label, calibrated_peak, return_diagnostics=True)
    bad = [code for code in MHC2_CURVE_FEEDBACK_CODES
           if code not in diagnostics
           or (diagnostics[code]["needed"]
               and (not diagnostics[code]["accepted"]
                    or diagnostics[code]["predicted_chroma_error"] > 0.006))]
    if bad:
        fail("{} baseline is outside its measured correction hull at codes {}. "
             "Remeasure the active profile path instead of reusing stale "
             "feedback.".format(label, ", ".join(str(code) for code in bad)))


def validate_profile_curve_feedback_complete(rows):
    """Require every measured profile variant consumed by the final build."""
    names = {str(row.get("name", "")) for row in rows}
    required = {
        "{} {} {}".format(label, variant, code)
        for label in ("ICC MHC2 Curve Feedback", "ICC cLUT Curve Feedback")
        for variant in ("Base", "R+", "G+", "B+", "R-", "G-", "B-")
        for code in MHC2_CURVE_FEEDBACK_CODES
    }
    required.update(
        "ICC cLUT Curve Feedback {} {}".format(variant, code)
        for variant in ("Base", "R+", "G+", "B+", "R-", "G-", "B-")
        for code in MHC2_CLUT_FEEDBACK_CODES
    )
    required.update(
        "ICC MHC2 Final Feedback " + variant
        for variant in ("Base", "R+", "G+", "B+")
    )
    missing = required.difference(names)
    if missing:
        fail("Final HDR MHC2 build requires the complete measured MHC2 and "
             "cLUT curve-feedback set")


def apply_profile_curve_feedback(luts, rows, neutral_gains, calibrated_peak,
                                 label,
                                 probe_delta=MHC2_CURVE_FEEDBACK_DELTA,
                                 codes=None, hold_top=False):
    """Apply independently validated profile-variant shadow corrections."""
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(luts[0]) < 2 or len(neutral_gains) != 3
            or min(neutral_gains) <= 1e-6):
        return False
    anchors = profile_curve_feedback_anchors(
        rows, label, calibrated_peak, probe_delta, codes=codes)
    if not anchors:
        return False
    start = max(0.0, anchors[0][0] - 0.035)
    if hold_top:
        # Above the knee the device is clipping, so every code from the last
        # anchor to full scale renders the same physical output and needs the
        # same chroma correction. Fading to zero there is what left the cLUT
        # top end with a flat +.0028 dy offset, about 1.5 chroma dE, while the
        # MHC2 path reached 0.54. Hold the last anchor instead of inventing a
        # ramp the hardware never measured.
        points = ([(start, [0.0, 0.0, 0.0])] + anchors
                  + [(1.0, list(anchors[-1][1]))])
    else:
        end = min(1.0, anchors[-1][0] + 0.055)
        points = [(start, [0.0, 0.0, 0.0])] + anchors + [
            (end, [0.0, 0.0, 0.0])]

    def correction(source_code, channel):
        if source_code <= points[0][0] or source_code >= points[-1][0]:
            return 0.0
        for index in range(1, len(points)):
            x0, values0 = points[index - 1]
            x1, values1 = points[index]
            if source_code <= x1:
                fraction = ((source_code - x0) / (x1 - x0)
                            if x1 > x0 else 0.0)
                weight = smoothstep(fraction)
                return (values0[channel] * (1.0 - weight)
                        + values1[channel] * weight)
        return 0.0

    entries = len(luts[0])
    for channel in range(3):
        gain = neutral_gains[channel]
        updated = []
        for index, old in enumerate(luts[channel]):
            curve_input = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
            updated.append(max(0.0, min(1.0,
                old + correction(source_code, channel))))
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return True


def apply_mhc2_final_peak_feedback(luts, rows, neutral_gains,
                                    calibrated_peak, probe_delta=0.01):
    """Close peak white through the finished Windows MHC2 pipeline.

    Patch-domain RGB probes do not measure the same local response as changes
    to MHC2's post-transfer curves.  In particular, an HDR panel may already
    be on its tone-mapping plateau when a patch channel is perturbed.  The
    profile build therefore installs three temporary profiles whose final
    curve shoulders differ by ``probe_delta`` and measures their actual XYZ.
    Solve that measured 3x3 response here.  A display which is already D65
    produces a negligible solve and is left unchanged.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(luts[0]) < 2):
        return False
    names = {
        "base": "ICC MHC2 Final Feedback Base",
        "R": "ICC MHC2 Final Feedback R+",
        "G": "ICC MHC2 Final Feedback G+",
        "B": "ICC MHC2 Final Feedback B+",
    }
    measured = {}
    for row in rows:
        for key, name in names.items():
            if str(row.get("name", "")) == name:
                measured[key] = row
    if any(key not in measured for key in names):
        return False
    if not math.isfinite(probe_delta) or probe_delta <= 1e-6:
        return False

    base = measured["base"]["xyz"]
    if base[1] <= 1e-9 or not all(math.isfinite(value) for value in base):
        return False
    base_total = sum(base)
    if base_total <= 1e-9:
        return False
    base_xy = (base[0] / base_total, base[1] / base_total)
    if math.hypot(base_xy[0] - 0.3127, base_xy[1] - 0.3290) < 0.0005:
        return False
    for channel in "RGB":
        probe = measured[channel]["xyz"]
        if (not all(math.isfinite(value) for value in probe)
                or probe[1] < base[1] * 0.75
                or probe[1] > base[1] * 1.25):
            return False
        probe_total = sum(probe)
        if probe_total <= 1e-9:
            return False
        distance = math.hypot(
            probe[0] / probe_total - base_xy[0],
            probe[1] / probe_total - base_xy[1])
        if distance < 0.00025 or distance > 0.05:
            return False
    columns = [[(measured[channel]["xyz"][axis] - base[axis]) / probe_delta
                for axis in range(3)] for channel in "RGB"]
    jacobian = [[columns[channel][axis] for channel in range(3)]
                for axis in range(3)]
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    try:
        delta = mat_vec_mul(mat_inv(jacobian), [
            base[1] * d65[axis] - base[axis] for axis in range(3)
        ])
    except ValueError:
        return False
    if not all(math.isfinite(value) for value in delta):
        return False

    # MHC2 curves must stay monotonic, so express the solve as raises relative
    # to its weakest channel.  Clamp the vector as a whole: clamping each
    # channel independently can turn a large, meaningful RGB solve into three
    # identical raises.  Those identical post-PQ raises are not neutral after
    # MHC2's unequal matrix gains and can spoil an already-good white point.
    weakest = min(delta)
    delta = [max(0.0, (value - weakest) * 0.9) for value in delta]
    largest = max(delta)
    if largest < 0.00025:
        return False
    if largest > 0.035:
        scale = 0.035 / largest
        delta = [value * scale for value in delta]

    # The measured variants are the authority for this one-pass residual.
    # Reject a noisy or poorly conditioned direction unless it predicts a
    # material xy improvement without giving away more than five percent of
    # peak luminance.  Returning False preserves the measured provisional
    # profile byte-for-byte at the peak.
    predicted = [
        base[axis] + sum(jacobian[axis][channel] * delta[channel]
                         for channel in range(3))
        for axis in range(3)
    ]
    predicted_total = sum(predicted)
    if predicted_total <= 1e-9 or predicted[1] <= 1e-9:
        return False
    predicted_xy = (predicted[0] / predicted_total,
                    predicted[1] / predicted_total)
    current_distance = math.hypot(base_xy[0] - 0.3127,
                                  base_xy[1] - 0.3290)
    predicted_distance = math.hypot(predicted_xy[0] - 0.3127,
                                    predicted_xy[1] - 0.3290)
    if (predicted_distance >= current_distance * 0.92
            or predicted[1] < base[1] * 0.95
            or predicted[1] > base[1] * 1.05):
        return False

    neutral = sorted((sum(row["rgb"]) / 3.0, row["xyz"][1])
                     for row in rows
                     if max(row["rgb"]) - min(row["rgb"]) <= 0.002)
    measured_peak = max((value for _code, value in neutral),
                        default=max(float(calibrated_peak), 0.0001))
    shoulder = next((code for code, value in neutral
                     if value >= measured_peak * 0.80), 0.75)
    transition_end = max(0.55, min(0.98, shoulder))
    transition_start = max(0.0, transition_end - 0.05)
    entries = len(luts[0])
    for channel in range(3):
        updated = []
        gain = neutral_gains[channel] if (
            len(neutral_gains) == 3 and neutral_gains[channel] > 1e-6) else 1.0
        for index, old in enumerate(luts[channel]):
            position = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(position) / gain)
            weight = smoothstep((source_code - transition_start)
                                / max(transition_end - transition_start, 1e-6))
            updated.append(max(0.0, min(1.0,
                old + delta[channel] * weight)))
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return True


MHC2_FINAL_FEEDBACK_NAMES = frozenset((
    "ICC MHC2 Final Feedback Base",
    "ICC MHC2 Final Feedback R+",
    "ICC MHC2 Final Feedback G+",
    "ICC MHC2 Final Feedback B+",
))


def is_profile_response_feedback_name(name):
    """Return whether a row measures a temporary finished-profile variant."""
    name = str(name)
    return (name in MHC2_FINAL_FEEDBACK_NAMES
            or name.startswith("ICC MHC2 Curve Feedback ")
            or name.startswith("ICC cLUT Curve Feedback "))


def windows_hdr_mhc2_from_active_profile(profile, rows, black, white,
                                         primaries, target_transfer):
    """Fit MHC2 for the measured Windows path without changing raw cLUT."""
    # The final applied-profile probes are response measurements of temporary
    # MHC2 variants, not samples of the display characterization.  Letting
    # their four full-white rows participate in the ordinary neutral fit
    # changes the inferred peak, lumi tag and B2A normalization.  That made a
    # peak-only feedback pass reshape the entire cLUT and discarded the
    # already-closed shadow/midtone result.  Keep the characterization fit on
    # the same rows used by the provisional profile. The finished-profile
    # response probes are consumed only by the final output stage.
    fit_rows = [row for row in rows
                if not is_profile_response_feedback_name(row.get("name", ""))
                and not is_mhc2_sentinel_name(row.get("name", ""))]
    if not fit_rows:
        fit_rows = rows
    profile_type = "windows-hdr"
    wire = mhc2_wire_matrix(profile_type)
    _, matrix, seed_luts, _ = mhc2_payload(
        profile_type, black, white, primaries, fit_rows,
        target_transfer or "srgb", apply_calibration=True,
        hdr_neutral_headroom=True)
    fallback = vcgt_from_mhc2(matrix, seed_luts, wire)
    adjustment_luts = windows_hdr_profile_adjustment_luts(
        profile, fit_rows, fallback, black, white, matrix)
    rgb_adjustment = mat_mul(
        mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    balanced_peak = apply_mhc2_balanced_peak_cap(
        adjustment_luts, fit_rows, black, white, primaries, neutral_gains)
    mhc2, matrix, adjustment_luts, calibrated_peak = mhc2_payload(
        profile_type, black, white, primaries, fit_rows,
        target_transfer or "srgb", apply_calibration=True,
        adjustment_luts_override=adjustment_luts,
        hdr_neutral_headroom=True,
        calibrated_peak_override=balanced_peak)
    rgb_adjustment = mat_mul(
        mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    apply_mhc2_active_neutral_luminance(
        adjustment_luts, fit_rows, black, primaries, neutral_gains,
        calibrated_peak)
    apply_mhc2_active_shadow_jacobians(
        adjustment_luts, fit_rows, neutral_gains, calibrated_peak)
    apply_mhc2_active_shadow_feedback(
        adjustment_luts, fit_rows, neutral_gains, calibrated_peak)
    mhc2 = mhc2_with_adjustment_luts(mhc2, adjustment_luts)
    return mhc2, matrix, adjustment_luts, calibrated_peak


def apply_mhc2_profile_exact_white_tail(luts, evaluate, chad, damping=0.5):
    """Solve a profile-predicted exact-white residual in the final entries."""
    if len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1:
        fail("MHC2 exact-white correction requires three equal curves")
    if len(chad) != 3 or any(len(row) != 3 for row in chad):
        fail("MHC2 exact-white correction requires a chromatic-adaptation matrix")
    start = mhc2_exact_white_start(len(luts[0]))
    held = [max(luts[channel][start - 1], luts[channel][start])
            for channel in range(3)]
    actual = evaluate(held)
    if len(actual) != 3 or not all(math.isfinite(value) for value in actual):
        return False
    try:
        raw = mat_vec_mul(mat_inv(chad), actual)
    except ValueError:
        return False
    if raw[1] <= 1e-9:
        return False
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    target = mat_vec_mul(chad, [raw[1] * component for component in d65])
    step = 2.0 / 1023.0
    jacobian = [[0.0] * 3 for _axis in range(3)]
    for channel in range(3):
        probe = list(held)
        probe[channel] = min(1.0, held[channel] + step)
        if probe[channel] <= held[channel]:
            return False
        result = evaluate(probe)
        denominator = probe[channel] - held[channel]
        for axis in range(3):
            jacobian[axis][channel] = (
                result[axis] - actual[axis]) / denominator
    try:
        delta = mat_vec_mul(
            mat_inv(jacobian),
            [target[axis] - actual[axis] for axis in range(3)],
        )
    except ValueError:
        return False
    if not all(math.isfinite(value) for value in delta):
        return False
    floor = min(delta)
    raised = [max(0.0, value - floor) * damping for value in delta]
    if max(raised) < 0.0015:
        return False
    for channel in range(3):
        endpoint = min(1.0, held[channel] + 0.035,
                       held[channel] + raised[channel])
        for index in range(start, len(luts[channel])):
            luts[channel][index] = endpoint
    return True


def invert_table(table, value):
    """Invert a normalized monotonic table with linear interpolation."""
    value = max(0.0, min(1.0, value))
    if value <= table[0]:
        return 0.0
    if value >= table[-1]:
        return 1.0
    low, high = 0, len(table) - 1
    while low < high - 1:
        middle = (low + high) // 2
        if table[middle] <= value:
            low = middle
        else:
            high = middle
    step = table[high] - table[low]
    fraction = 0.0 if step <= 0 else (value - table[low]) / step
    return (low + fraction) / (len(table) - 1.0)


def _sample_mft2_clut(table, grid, coordinates):
    """Trilinearly sample an RGB mft2 cLUT."""
    positions = [max(0.0, min(1.0, value)) * (grid - 1) for value in coordinates]
    lows = [min(grid - 2, int(value)) for value in positions]
    fractions = [positions[channel] - lows[channel] for channel in range(3)]
    result = [0.0, 0.0, 0.0]
    for red in (0, 1):
        red_weight = fractions[0] if red else 1.0 - fractions[0]
        for green in (0, 1):
            green_weight = fractions[1] if green else 1.0 - fractions[1]
            for blue in (0, 1):
                blue_weight = fractions[2] if blue else 1.0 - fractions[2]
                weight = red_weight * green_weight * blue_weight
                node = ((lows[0] + red) * grid * grid
                        + (lows[1] + green) * grid
                        + lows[2] + blue) * 3
                for channel in range(3):
                    result[channel] += table[node + channel] * weight
    return result


def _sample_mft2_clut_tetrahedral(table, grid, coordinates):
    """Tetrahedrally sample an RGB mft2 cLUT, matching ArgyllCMS."""
    positions = [max(0.0, min(1.0, value)) * (grid - 1) for value in coordinates]
    lows = [min(grid - 2, int(value)) for value in positions]
    fractions = [positions[channel] - lows[channel] for channel in range(3)]

    def node(red, green, blue):
        offset = (((lows[0] + red) * grid * grid
                   + (lows[1] + green) * grid
                   + lows[2] + blue) * 3)
        return table[offset:offset + 3]

    red, green, blue = fractions
    first = node(0, 0, 0)
    last = node(1, 1, 1)
    if red >= green:
        if green >= blue:
            middle = (node(1, 0, 0), node(1, 1, 0))
            weights = (red, green, blue)
        elif red >= blue:
            middle = (node(1, 0, 0), node(1, 0, 1))
            weights = (red, blue, green)
        else:
            middle = (node(0, 0, 1), node(1, 0, 1))
            weights = (blue, red, green)
    else:
        if red >= blue:
            middle = (node(0, 1, 0), node(1, 1, 0))
            weights = (green, red, blue)
        elif green >= blue:
            middle = (node(0, 1, 0), node(0, 1, 1))
            weights = (green, blue, red)
        else:
            middle = (node(0, 0, 1), node(0, 1, 1))
            weights = (blue, green, red)
    return [
        first[channel]
        + weights[0] * (middle[0][channel] - first[channel])
        + weights[1] * (middle[1][channel] - middle[0][channel])
        + weights[2] * (last[channel] - middle[1][channel])
        for channel in range(3)
    ]


def mft2_a2b_evaluator(profile):
    """Return a raw-device RGB to relative-PCS evaluator for A2B0."""
    payload = dict(read_icc_tags(profile)).get(b"A2B0")
    if not payload or len(payload) < 52 or payload[:4] != b"mft2":
        fail("Measured HDR calibration requires an mft2 A2B0 transform")
    input_channels, output_channels, grid = payload[8], payload[9], payload[10]
    input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
    if input_channels != 3 or output_channels != 3 or grid < 2:
        fail("Measured HDR calibration requires a three-channel A2B0 transform")
    input_start = 52
    clut_start = input_start + input_channels * input_entries * 2
    clut_values = grid ** input_channels * output_channels
    output_start = clut_start + clut_values * 2
    required = output_start + output_channels * output_entries * 2
    if required > len(payload):
        fail("ICC A2B0 table is truncated")
    matrix = [value / 65536.0 for value in struct.unpack_from(">9i", payload, 12)]
    input_tables = []
    output_tables = []
    for channel in range(3):
        offset = input_start + channel * input_entries * 2
        input_tables.append(_np_mft2_tables(payload, offset, input_entries))
        offset = output_start + channel * output_entries * 2
        output_tables.append(_np_mft2_tables(payload, offset, output_entries))
    clut = _np_mft2_tables(payload, clut_start, clut_values)
    # Both representations are kept deliberately. Single-triple callers stay on
    # the scalar lists, where per-call NumPy dispatch would cost more than it
    # saves; the lattice solvers hand in an (N, 3) array and get one back.
    scalar_input_tables = [table.tolist() for table in input_tables]
    scalar_output_tables = [table.tolist() for table in output_tables]
    scalar_clut = clut.tolist()
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)

    def evaluate(rgb):
        if not isinstance(rgb, np.ndarray) or rgb.ndim == 1:
            shaped = [sample_table(scalar_input_tables[channel], rgb[channel])
                      for channel in range(3)]
            transformed = [
                sum(matrix[row * 3 + column] * shaped[column] for column in range(3))
                for row in range(3)
            ]
            encoded = _sample_mft2_clut_tetrahedral(scalar_clut, grid, transformed)
            return [sample_table(scalar_output_tables[channel], encoded[channel])
                    / xyz_to_mft for channel in range(3)]
        shaped = np.empty(rgb.shape, dtype=np.float64)
        for channel in range(3):
            shaped[:, channel] = _np_sample_table(input_tables[channel],
                                                  rgb[:, channel])
        transformed = _np_mat3_apply(matrix, shaped)
        encoded = _np_clut_tetrahedral(clut, grid, transformed)
        result = np.empty(rgb.shape, dtype=np.float64)
        for channel in range(3):
            result[:, channel] = _np_sample_table(
                output_tables[channel], encoded[:, channel]) / xyz_to_mft
        return result

    return evaluate


def mft2_b2a_evaluator(profile):
    """Return a relative-PCS XYZ to device RGB evaluator for B2A0.

    This deliberately matches the Patch Companion's explicit cLUT path:
    matrix, input tables in the ICC lut16 XYZ encoding, trilinear cLUT, then
    output tables.  Keeping one evaluator for both the builder's MHC2 clone
    and the Companion prevents the two Windows handling choices from growing
    different neutral responses.
    """
    payload = dict(read_icc_tags(profile)).get(b"B2A0")
    if not payload or len(payload) < 52 or payload[:4] != b"mft2":
        fail("Windows HDR cLUT matching requires an mft2 B2A0 transform")
    input_channels, output_channels, grid = payload[8], payload[9], payload[10]
    input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
    if input_channels != 3 or output_channels != 3 or grid < 2:
        fail("Windows HDR cLUT matching requires a three-channel B2A0 transform")
    input_start = 52
    clut_start = input_start + input_channels * input_entries * 2
    clut_values = grid ** input_channels * output_channels
    output_start = clut_start + clut_values * 2
    required = output_start + output_channels * output_entries * 2
    if required > len(payload):
        fail("ICC B2A0 table is truncated")
    matrix = [value / 65536.0 for value in struct.unpack_from(">9i", payload, 12)]
    input_tables = []
    output_tables = []
    for channel in range(3):
        offset = input_start + channel * input_entries * 2
        input_tables.append(_np_mft2_tables(payload, offset, input_entries))
        offset = output_start + channel * output_entries * 2
        output_tables.append(_np_mft2_tables(payload, offset, output_entries))
    clut = _np_mft2_tables(payload, clut_start, clut_values)
    scalar_input_tables = [table.tolist() for table in input_tables]
    scalar_output_tables = [table.tolist() for table in output_tables]
    scalar_clut = clut.tolist()
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)

    def evaluate(xyz):
        if not isinstance(xyz, np.ndarray) or xyz.ndim == 1:
            mapped = [
                sum(matrix[row * 3 + column] * xyz[column] for column in range(3))
                for row in range(3)
            ]
            shaped = [sample_table(scalar_input_tables[channel],
                                   mapped[channel] * xyz_to_mft)
                      for channel in range(3)]
            encoded = _sample_mft2_clut(scalar_clut, grid, shaped)
            return [sample_table(scalar_output_tables[channel], encoded[channel])
                    for channel in range(3)]
        mapped = _np_mat3_apply(matrix, xyz)
        shaped = np.empty(xyz.shape, dtype=np.float64)
        for channel in range(3):
            shaped[:, channel] = _np_sample_table(
                input_tables[channel], mapped[:, channel] * xyz_to_mft)
        encoded = _np_clut_trilinear(clut, grid, shaped)
        result = np.empty(xyz.shape, dtype=np.float64)
        for channel in range(3):
            result[:, channel] = _np_sample_table(output_tables[channel],
                                                  encoded[:, channel])
        return result

    return evaluate


def windows_hdr_b2a_neutral_evaluator(profile):
    """Evaluate the exact neutral HDR source path used by explicit cLUT mode."""
    evaluate = windows_hdr_b2a_source_evaluator(profile)

    def evaluate_neutral(code):
        return evaluate((code, code, code))

    return evaluate_neutral


def windows_hdr_b2a_source_evaluator(profile):
    """Evaluate HDR source RGB through the profile's exact B2A transform."""
    tags = dict(read_icc_tags(profile))
    lumi = tags.get(b"lumi")
    if not lumi or len(lumi) < 20 or lumi[:4] != b"XYZ ":
        fail("Windows HDR cLUT matching requires profile luminance metadata")
    white_nits = read_s15fixed16(lumi, 12)
    if white_nits <= 0.0:
        fail("Windows HDR cLUT matching requires positive profile luminance")
    evaluate_b2a = mft2_b2a_evaluator(profile)
    adaptation = bradford_adaptation(
        (0.9504559, 1.0, 1.0890578), (0.9642, 1.0, 0.8249))
    bt2020_xyz = (
        (0.6369580, 0.1446169, 0.1688810),
        (0.2627002, 0.6779981, 0.0593017),
        (0.0, 0.0280727, 1.0609851),
    )

    def evaluate(codes):
        linear = [pq_to_nits(max(0.0, min(1.0, code))) / white_nits
                  for code in codes]
        source_xyz = mat_vec_mul(bt2020_xyz, linear)
        pcs_xyz = mat_vec_mul(adaptation, source_xyz)
        return evaluate_b2a(pcs_xyz)

    return evaluate


def windows_hdr_b2a_measured_peak_drive(rows):
    """Return the measured best neutral peak drive, or None."""
    best = None
    for row in rows:
        name = str(row.get("name", ""))
        if not (re.match(r"^ICC MHC2 Peak Candidate(?: [RGB][+-])?$", name)
                or re.match(r"^ICC MHC2 Peak Refine [A-Z]+$", name)):
            continue
        xyz = row.get("xyz")
        rgb = row.get("rgb")
        if not xyz or not rgb or len(rgb) != 3:
            continue
        total = sum(xyz)
        if total <= 1e-9:
            continue
        error = math.hypot(xyz[0] / total - 0.3127, xyz[1] / total - 0.3290)
        if best is None or error < best[0]:
            best = (error, [max(0.0, min(1.0, float(v))) for v in rgb])
    return best


def windows_hdr_b2a_grey_ladder(rows):
    """Measured neutral grey ladder as sorted (code fraction, nits)."""
    grouped = {}
    for row in rows:
        match = re.match(r"^ICC MHC2 Active Grey (\d+)$", str(row.get("name", "")))
        if not match:
            continue
        xyz = row.get("xyz")
        if not xyz:
            continue
        grouped.setdefault(int(match.group(1)), []).append(xyz[1])
    ladder = []
    previous = 0.0
    for code in sorted(grouped):
        values = sorted(grouped[code])
        middle = len(values) // 2
        measured = (values[middle] if len(values) % 2 else
                    0.5 * (values[middle - 1] + values[middle]))
        previous = max(previous, measured)
        ladder.append((code / 1023.0, previous))
    return ladder if len(ladder) >= 9 else None


def windows_hdr_b2a_probe_luminance_shifts(rows, label=None, codes=None):
    """Common-mode B2A shift vs source code from the profile's own probes.

    Sensitivity is the finished profile's local dY per code, not the
    null-seed grey-ladder slope. Attempt 3 converted a luminance error with
    that ladder slope, about 0.9 percent per code. At code 358 the profile's
    own probes measure 2.77 percent per code, so that pass applied about 8
    codes where 3.1 were needed and overshot to +17.8 percent.

    The slope is one-sided, in the direction the shift will actually move.
    A two-sided average understates the upward response when the panel is
    lopsided: at code 358, G+ moved Y by +2.57 nits while G- moved it by
    only -0.21 nits, so a +3.1 code shift computed from the symmetric
    slope delivered +12.1 percent. Too dim uses the plus probes only,
    too bright the minus probes only. If that side is non-finite, at or
    below zero, or weaker than a quarter of the symmetric estimate, the
    code is left untrimmed. The wanted shift is -error_fraction / that
    slope, clamped to +/- 5 codes and stored in the 0..1 output domain.
    Prefers ICC cLUT Curve Feedback rows and falls back to the MHC2 label.
    Callers that already know their label and code list can pass them.
    """
    by_name = {}
    for row in rows:
        xyz = row.get("xyz")
        if not xyz:
            continue
        measured = float(xyz[1])
        if not math.isfinite(measured) or measured <= 0.0:
            continue
        by_name.setdefault(str(row.get("name", "")), []).append(measured)

    def median(values):
        values = sorted(values)
        middle = len(values) // 2
        return (values[middle] if len(values) % 2 else
                0.5 * (values[middle - 1] + values[middle]))

    probe_codes = MHC2_CURVE_FEEDBACK_DELTA * 1023.0
    if probe_codes <= 1e-9:
        return None

    def collect(collect_label, collect_codes):
        points = []
        for code in collect_codes:
            base_values = by_name.get("{} Base {}".format(collect_label, code))
            if not base_values:
                continue
            base_y = median(base_values)
            plus_acc = 0.0
            minus_acc = 0.0
            symmetric_acc = 0.0
            complete = True
            for channel in "RGB":
                plus_values = by_name.get(
                    "{} {}+ {}".format(collect_label, channel, code))
                minus_values = by_name.get(
                    "{} {}- {}".format(collect_label, channel, code))
                if not plus_values or not minus_values:
                    complete = False
                    break
                plus_y = median(plus_values)
                minus_y = median(minus_values)
                plus_acc += plus_y - base_y
                minus_acc += base_y - minus_y
                symmetric_acc += 0.5 * abs(plus_y - minus_y)
            if not complete or base_y <= 1e-12:
                continue
            target_y = pq_to_nits(code / 1023.0)
            if target_y <= 1e-12:
                continue
            error_frac = (base_y - target_y) / target_y
            if not math.isfinite(error_frac) or error_frac == 0.0:
                continue
            if error_frac < 0.0:
                side_acc = plus_acc
            else:
                side_acc = minus_acc
            frac_dy_per_code = (side_acc / probe_codes) / base_y
            symmetric_slope = (symmetric_acc / probe_codes) / base_y
            if (not math.isfinite(frac_dy_per_code)
                    or frac_dy_per_code <= 0.0
                    or frac_dy_per_code < 0.25 * abs(symmetric_slope)):
                continue
            shift_codes = -error_frac / frac_dy_per_code
            if not math.isfinite(shift_codes):
                continue
            shift_codes = max(-5.0, min(5.0, shift_codes))
            points.append((code / 1023.0, shift_codes / 1023.0))
        return points

    wanted_codes = codes if codes is not None else MHC2_CLUT_FEEDBACK_CODES
    if label is not None:
        return collect(label, wanted_codes) or None
    points = collect("ICC cLUT Curve Feedback", wanted_codes)
    if not points:
        points = collect("ICC MHC2 Curve Feedback", wanted_codes)
    return points or None


def windows_hdr_b2a_with_ladder_trim(profile, rows, source_start=None,
                                     source_limit=0.77, max_shift=None):
    """Pull the neutral corridor onto the PQ target, common mode.

    The shift is applied equally to all three channels, so channel ratios and
    therefore the chroma corrections already achieved are preserved; only the
    common drive moves. Stops below the plateau, which
    windows_hdr_b2a_with_peak_drive owns.

    Prefer a piecewise-linear shift built from the finished profile's own
    probe rows (ICC cLUT Curve Feedback, then ICC MHC2 Curve Feedback).
    Those measure both the Base luminance error and the local common-mode
    sensitivity, so the trim aims the right way and with the right size.
    Attempt 3 used the null-seed ladder slope instead, about 0.9 percent
    per code against a true 2.77 percent per code at 358, and overshot.

    When the Base and probe rows are absent, invert the null-seed grey ladder
    so non-feedback builds still work. Apply that inverse in the B2A output
    curves, where exact neutral requests are evaluated, rather than at sparse
    cLUT nodes whose interpolation displaced shadow knots by up to 2.52 codes.

    Bounds matter. Probe-derived shifts are clamped to +/- 5 codes, and
    max_shift matches that bound. A 20 count bound let a noisy near-black
    ladder inversion overshoot code 51 to +42.6%.
    """
    probe_shifts = windows_hdr_b2a_probe_luminance_shifts(rows)
    ladder = None if probe_shifts else windows_hdr_b2a_grey_ladder(rows)
    if not probe_shifts and not ladder:
        return profile
    if probe_shifts:
        if source_start is None:
            source_start = 0.09
        if max_shift is None:
            max_shift = 5.0 / 1023.0
    else:
        if source_start is None:
            source_start = 0.09
        if max_shift is None:
            max_shift = 0.008

    def ladder_drive(target):
        if target <= ladder[0][1]:
            return ladder[0][0]
        for index in range(1, len(ladder)):
            code0, y0 = ladder[index - 1]
            code1, y1 = ladder[index]
            if target <= y1:
                p0 = nits_to_pq(y0)
                p1 = nits_to_pq(y1)
                pt = nits_to_pq(target)
                if p1 <= p0 + 1e-12:
                    return code0
                return code0 + (pt - p0) * (code1 - code0) / (p1 - p0)
        return ladder[-1][0]

    def probe_shift(source_code):
        if source_code <= probe_shifts[0][0]:
            return probe_shifts[0][1]
        for index in range(1, len(probe_shifts)):
            code0, shift0 = probe_shifts[index - 1]
            code1, shift1 = probe_shifts[index]
            if source_code <= code1:
                if code1 <= code0 + 1e-12:
                    return shift0
                return (shift0
                        + (source_code - code0) * (shift1 - shift0)
                        / (code1 - code0))
        return probe_shifts[-1][1]

    tags = dict(read_icc_tags(profile))
    lumi = tags.get(b"lumi")
    if not lumi or len(lumi) < 20 or lumi[:4] != b"XYZ ":
        return profile
    white_nits = read_s15fixed16(lumi, 12)
    if white_nits <= 0.0:
        return profile
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)
    d50 = (0.9642, 1.0, 0.8249)
    replacements = {}
    for signature, payload in read_icc_tags(profile):
        if signature not in (b"B2A0", b"B2A1") or signature in replacements:
            continue
        if len(payload) < 52 or payload[:4] != b"mft2":
            continue
        input_channels, output_channels, grid = payload[8], payload[9], payload[10]
        input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
        if input_channels != 3 or output_channels != 3 or grid < 2:
            continue
        input_start = 52
        clut_start = input_start + input_channels * input_entries * 2
        clut_values = grid ** input_channels * output_channels
        output_start = clut_start + clut_values * 2
        if output_start + output_channels * output_entries * 2 > len(payload):
            continue
        input_tables = []
        output_tables = []
        for channel in range(3):
            offset = input_start + channel * input_entries * 2
            input_tables.append([value / 65535.0 for value in
                                 struct.unpack_from(">{}H".format(input_entries),
                                                    payload, offset)])
            offset = output_start + channel * output_entries * 2
            output_tables.append([value / 65535.0 for value in
                                  struct.unpack_from(">{}H".format(output_entries),
                                                     payload, offset)])
        updated = bytearray(payload)

        if ladder:
            # The calibration lives in the dense output curves. Correct it in
            # that same domain: cLUT-node shifts are sampled through surrounding
            # off-diagonal nodes and did not reproduce their requested shift at
            # the exact neutral ladder knots.
            matrix = [value / 65536.0 for value in
                      struct.unpack_from(">9i", payload, 12)]
            clut = [value / 65535.0 for value in struct.unpack_from(
                ">{}H".format(clut_values), payload, clut_start)]
            adaptation = bradford_adaptation(
                (0.9504559, 1.0, 1.0890578), (0.9642, 1.0, 0.8249))
            bt2020_xyz = (
                (0.6369580, 0.1446169, 0.1688810),
                (0.2627002, 0.6779981, 0.0593017),
                (0.0, 0.0280727, 1.0609851),
            )
            anchors = [[] for _channel in range(3)]
            for source_code, _measured_y in ladder:
                if source_code < source_start or source_code >= source_limit:
                    continue
                source_nits = pq_to_nits(source_code)
                linear = [source_nits / white_nits] * 3
                pcs_xyz = mat_vec_mul(
                    adaptation, mat_vec_mul(bt2020_xyz, linear))
                mapped = [
                    sum(matrix[row * 3 + column] * pcs_xyz[column]
                        for column in range(3))
                    for row in range(3)
                ]
                shaped = [
                    sample_table(input_tables[channel],
                                 mapped[channel] * xyz_to_mft)
                    for channel in range(3)
                ]
                encoded = _sample_mft2_clut(clut, grid, shaped)
                current = [sample_table(output_tables[channel], encoded[channel])
                           for channel in range(3)]
                shift = ladder_drive(source_nits) - sum(current) / 3.0
                shift = max(-max_shift, min(max_shift, shift))
                for channel in range(3):
                    anchors[channel].append((encoded[channel], shift))

            touched = 0
            for channel in range(3):
                points = sorted(anchors[channel])
                if len(points) < 2:
                    continue

                def output_shift(position):
                    if position < points[0][0] or position > points[-1][0]:
                        return 0.0
                    for point_index in range(1, len(points)):
                        x0, shift0 = points[point_index - 1]
                        x1, shift1 = points[point_index]
                        if position <= x1:
                            fraction = (0.0 if x1 <= x0 else
                                        (position - x0) / (x1 - x0))
                            return shift0 + fraction * (shift1 - shift0)
                    return 0.0

                table = isotonic_curve([
                    max(0.0, min(1.0,
                        value + output_shift(index / float(output_entries - 1))))
                    for index, value in enumerate(output_tables[channel])
                ])
                for index, value in enumerate(table):
                    struct.pack_into(
                        ">H", updated,
                        output_start + channel * output_entries * 2 + index * 2,
                        max(0, min(65535, int(round(value * 65535.0)))))
                touched += 1
            if touched:
                replacements[signature] = bytes(updated)
            continue

        denominator = float(grid - 1)
        touched = 0
        for red in range(grid):
            for green in range(max(0, red - 1), min(grid, red + 2)):
                for blue in range(max(0, red - 1), min(grid, red + 2)):
                    if max(red, green, blue) - min(red, green, blue) > 1:
                        continue
                    estimates = []
                    for channel, node in enumerate((red, green, blue)):
                        encoded_xyz = invert_table(input_tables[channel],
                                                   node / denominator)
                        pcs = encoded_xyz / xyz_to_mft
                        relative = max(0.0, pcs / d50[channel])
                        estimates.append(nits_to_pq(relative * white_nits))
                    source_code = sorted(estimates)[1]
                    # Stay inside the band where the profile-response probes
                    # measured this common-mode correction. Code 51 has no
                    # Base row.
                    if source_code < source_start or source_code >= source_limit:
                        continue
                    target_y = pq_to_nits(source_code)
                    if target_y <= 0.0:
                        continue
                    node_offset = (((red * grid + green) * grid + blue) * 3)
                    current = []
                    for channel in range(3):
                        node_value = struct.unpack_from(
                            ">H", payload,
                            clut_start + (node_offset + channel) * 2)[0] / 65535.0
                        current.append(sample_table(output_tables[channel],
                                                    node_value))
                    mean_drive = sum(current) / 3.0
                    if probe_shifts:
                        shift = probe_shift(source_code)
                    else:
                        shift = ladder_drive(target_y) - mean_drive
                    if not math.isfinite(shift) or abs(shift) < 1e-6:
                        continue
                    shift = max(-max_shift, min(max_shift, shift))
                    for channel in range(3):
                        desired = max(0.0, min(1.0, current[channel] + shift))
                        encoded = invert_table(output_tables[channel], desired)
                        struct.pack_into(">H", updated,
                                         clut_start + (node_offset + channel) * 2,
                                         max(0, min(65535,
                                             int(round(encoded * 65535.0)))))
                    touched += 1
        if touched:
            replacements[signature] = bytes(updated)
    return rebuild_icc(profile, replacements) if replacements else profile


def apply_mhc2_probe_luminance_trim(luts, rows, neutral_gains,
                                    source_start=0.09, source_limit=0.65,
                                    max_shift=None):
    """Pull MHC2 curves onto the PQ target, common mode.

    Same one-sided probe-calibrated method as
    windows_hdr_b2a_with_ladder_trim, applied to the MHC2 adjustment
    LUTs rather than the B2A cube. Cloning B2A here would erase the
    measured MHC2 shadow correction.

    Stops at source 0.65, the end of the MHC2 mid-band probe envelope,
    so the peak candidate and final peak feedback stages keep the
    region they own near code 763.
    """
    if (len(luts) != 3 or len(set(len(curve) for curve in luts)) != 1
            or len(luts[0]) < 2 or len(neutral_gains) != 3
            or min(neutral_gains) <= 1e-6):
        return False
    if max_shift is None:
        max_shift = 5.0 / 1023.0
    probe_shifts = windows_hdr_b2a_probe_luminance_shifts(
        rows, label="ICC MHC2 Curve Feedback",
        codes=MHC2_MIDBAND_FEEDBACK_CODES)
    if not probe_shifts:
        return False

    def probe_shift(source_code):
        if source_code <= probe_shifts[0][0]:
            return probe_shifts[0][1]
        for index in range(1, len(probe_shifts)):
            code0, shift0 = probe_shifts[index - 1]
            code1, shift1 = probe_shifts[index]
            if source_code <= code1:
                if code1 <= code0 + 1e-12:
                    return shift0
                return (shift0
                        + (source_code - code0) * (shift1 - shift0)
                        / (code1 - code0))
        return probe_shifts[-1][1]

    entries = len(luts[0])
    touched = False
    for channel in range(3):
        gain = neutral_gains[channel]
        updated = []
        for index, old in enumerate(luts[channel]):
            curve_input = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
            if source_code < source_start or source_code >= source_limit:
                updated.append(old)
                continue
            shift = probe_shift(source_code)
            if not math.isfinite(shift) or abs(shift) < 1e-6:
                updated.append(old)
                continue
            shift = max(-max_shift, min(max_shift, shift))
            updated.append(max(0.0, min(1.0, old + shift)))
            touched = True
        updated = isotonic_curve(updated)
        updated[0] = 0.0
        luts[channel][:] = updated
    return touched


def apply_mhc2_upper_neutral_jacobians(luts, rows, neutral_gains,
                                        plateau_start=0.77):
    """Keep reachable upper greys on measured XYZ solves below the plateau."""
    pattern = re.compile(
        r"^ICC Neutral Jacobian ([0-9]{4}) ([RGB])([+-])$")
    groups = {}
    for row in rows:
        match = pattern.match(str(row.get("name", "")))
        if match:
            groups.setdefault(int(match.group(1)), {})[
                match.group(2) + match.group(3)] = row
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    anchors = []
    for code, probes in sorted(groups.items()):
        source_code = code / 1023.0
        if not (plateau_start - 0.08 <= source_code < plateau_start):
            continue
        built = mhc2_shadow_probe_jacobian(probes)
        if built is None:
            continue
        target_y = pq_to_nits(source_code)
        delta = mat_vec_mul(mat_inv(built["jacobian"]), [
            target_y * d65[axis] - built["center_xyz"][axis]
            for axis in range(3)
        ])
        target = [max(built["center_code"][channel] - 0.03,
                      min(built["center_code"][channel] + 0.03,
                          built["center_code"][channel] + delta[channel]))
                  for channel in range(3)]
        source_nits = pq_to_nits(source_code)
        current = [sample_table(
            luts[channel],
            nits_to_pq(source_nits * neutral_gains[channel]))
            for channel in range(3)]
        anchors.append((source_code, [target[channel] - current[channel]
                                     for channel in range(3)]))
    if not anchors:
        return False
    return apply_interpolated_lut_anchors(
        luts, anchors, neutral_gains,
        max(0.0, anchors[0][0] - 0.04), plateau_start)


def windows_hdr_b2a_with_peak_drive(profile, rows, plateau_start=0.77):
    """Drive the B2A plateau with the directly measured best peak triplet.

    The top of the cube is degenerate: its input tables saturate, so several
    nodes decode to one plateau level. That level was being driven at roughly
    768/782/792 while the peak candidate stage had directly measured
    767/773/818 as the best neutral drive at dxy .00031. Blue 26 codes low
    starves Z and pushes y to .3319 against a .3290 target, which is the flat
    1.5 chroma dE the cLUT path carried from code 818 upward while the MHC2
    path, which does use this triplet, reached 0.54.

    This uses raw device-response provenance, the same rows the MHC2 balanced
    peak cap selects from, so it does not borrow MHC2-path feedback.

    plateau_start must exclude code 767 (source 0.7498), whose 981-nit PQ
    target is still below the measured panel peak, while including code 818
    (source 0.7996), whose target exceeds it. A 0.77 boundary keeps the full
    interpolation cell around 75% on its measured local solve and caps the
    unreachable upper requests without
    opening a gap with the common-mode ladder trim.
    """
    best = windows_hdr_b2a_measured_peak_drive(rows)
    if best is None:
        return profile
    drive = best[1]
    probe_pattern = re.compile(
        r"^ICC Neutral Jacobian ([0-9]{4}) ([RGB])([+-])$")
    probe_groups = {}
    for row in rows:
        match = probe_pattern.match(str(row.get("name", "")))
        if match:
            probe_groups.setdefault(int(match.group(1)), {})[
                match.group(2) + match.group(3)] = row
    upper_targets = []
    d65 = (0.3127 / 0.3290, 1.0,
           (1.0 - 0.3127 - 0.3290) / 0.3290)
    for code, probes in sorted(probe_groups.items()):
        if code / 1023.0 < plateau_start - 0.08:
            continue
        built = mhc2_shadow_probe_jacobian(probes)
        if built is None:
            continue
        target_y = pq_to_nits(code / 1023.0)
        delta = mat_vec_mul(mat_inv(built["jacobian"]), [
            target_y * d65[axis] - built["center_xyz"][axis]
            for axis in range(3)
        ])
        target = [max(built["center_code"][channel] - 0.03,
                      min(built["center_code"][channel] + 0.03,
                          built["center_code"][channel] + delta[channel]))
                  for channel in range(3)]
        upper_targets.append((code / 1023.0, target))

    def upper_target(source_code):
        if not upper_targets:
            return None
        if source_code <= upper_targets[0][0]:
            return upper_targets[0][1]
        for index in range(1, len(upper_targets)):
            code0, target0 = upper_targets[index - 1]
            code1, target1 = upper_targets[index]
            if source_code <= code1:
                fraction = ((source_code - code0)
                            / max(code1 - code0, 1e-12))
                return [target0[channel] * (1.0 - fraction)
                        + target1[channel] * fraction
                        for channel in range(3)]
        return upper_targets[-1][1]

    tags = dict(read_icc_tags(profile))
    lumi = tags.get(b"lumi")
    if not lumi or len(lumi) < 20 or lumi[:4] != b"XYZ ":
        return profile
    white_nits = read_s15fixed16(lumi, 12)
    if white_nits <= 0.0:
        return profile
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)
    d50 = (0.9642, 1.0, 0.8249)
    replacements = {}
    for signature, payload in read_icc_tags(profile):
        if signature not in (b"B2A0", b"B2A1") or signature in replacements:
            continue
        if len(payload) < 52 or payload[:4] != b"mft2":
            continue
        input_channels, output_channels, grid = payload[8], payload[9], payload[10]
        input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
        if input_channels != 3 or output_channels != 3 or grid < 2:
            continue
        input_start = 52
        clut_start = input_start + input_channels * input_entries * 2
        clut_values = grid ** input_channels * output_channels
        output_start = clut_start + clut_values * 2
        if output_start + output_channels * output_entries * 2 > len(payload):
            continue
        input_tables = []
        output_tables = []
        for channel in range(3):
            offset = input_start + channel * input_entries * 2
            input_tables.append([value / 65535.0 for value in
                                 struct.unpack_from(">{}H".format(input_entries),
                                                    payload, offset)])
            offset = output_start + channel * output_entries * 2
            output_tables.append([value / 65535.0 for value in
                                  struct.unpack_from(">{}H".format(output_entries),
                                                     payload, offset)])
        updated = bytearray(payload)
        denominator = float(grid - 1)
        touched = 0

        # Stretch each output table's upper end so its maximum reaches the
        # measured drive before writing plateau nodes. The corridor loop below
        # restores the still-reachable 68-76% band from the measured ladder.
        stretched = []
        for channel in range(3):
            table = list(output_tables[channel])
            ceiling = max(table)
            knee = ceiling * MHC2_PEAK_TABLE_KNEE
            target = drive[channel]
            remapped = []
            for value in table:
                if value <= knee:
                    remapped.append(value)
                else:
                    fraction = (value - knee) / max(ceiling - knee, 1e-12)
                    remapped.append(knee + fraction * (target - knee))
            for index in range(1, len(remapped)):
                if remapped[index] < remapped[index - 1]:
                    remapped[index] = remapped[index - 1]
            for index, value in enumerate(remapped):
                struct.pack_into(">H", updated,
                                 output_start + channel * output_entries * 2
                                 + index * 2,
                                 max(0, min(65535,
                                     int(round(value * 65535.0)))))
            stretched.append(remapped)
        output_tables = stretched

        # Walk the one-cell neutral corridor, not just the exact diagonal. An
        # exactly neutral trilinear lookup interpolates across the surrounding
        # cell, so writing only (n,n,n) is diluted by untouched neighbours:
        # that measured only 1.613 peak chroma against a drive whose own
        # measurement is dxy .00031. This mirrors the corridor walk already
        # used by windows_hdr_b2a_with_shadow_luts.
        for red in range(grid):
            for green in range(max(0, red - 1), min(grid, red + 2)):
                for blue in range(max(0, red - 1), min(grid, red + 2)):
                    if max(red, green, blue) - min(red, green, blue) > 1:
                        continue
                    estimates = []
                    for channel, node in enumerate((red, green, blue)):
                        encoded_xyz = invert_table(input_tables[channel],
                                                   node / denominator)
                        pcs = encoded_xyz / xyz_to_mft
                        relative = max(0.0, pcs / d50[channel])
                        estimates.append(nits_to_pq(relative * white_nits))
                    source_code = sorted(estimates)[1]
                    node_offset = (((red * grid + green) * grid + blue) * 3)
                    if source_code < plateau_start:
                        # The measured local RGB-to-XYZ solves at codes 716 and
                        # 767 own the two reachable cells below the plateau.
                        # They correct luminance and D65 together; assigning the
                        # peak triplet here caused the measured 70-75% spike.
                        if source_code < plateau_start - 0.08:
                            continue
                        desired = upper_target(source_code)
                        if desired is None:
                            continue
                    else:
                        desired = drive
                    for channel in range(3):
                        encoded = invert_table(output_tables[channel],
                                               desired[channel])
                        struct.pack_into(">H", updated,
                                         clut_start + (node_offset + channel) * 2,
                                         max(0, min(65535,
                                             int(round(encoded * 65535.0)))))
                    touched += 1
        if touched:
            replacements[signature] = bytes(updated)
    return rebuild_icc(profile, replacements) if replacements else profile


def windows_hdr_b2a_with_shadow_luts(profile, reference_luts, corrected_luts,
                                      neutral_gains,
                                      source_limit=0.35):
    """Put an applied-path shadow residual into B2A's neutral corridor.

    The final MHC2 feedback pass measures the cloned B2A response, so its
    bounded shadow correction is valid for both handling paths.  Rewrite only
    the one-cell neutral corridor touched by an exactly neutral trilinear
    lookup. Nearby colours outside that corridor retain the fitted 3D table.
    """
    if (len(reference_luts) != 3 or len(corrected_luts) != 3
            or any(len(reference_luts[channel]) != len(corrected_luts[channel])
                   for channel in range(3))
            or len(neutral_gains) != 3
            or min(neutral_gains) <= 1e-6):
        fail("Windows HDR shadow matching received invalid correction curves")
    tags = dict(read_icc_tags(profile))
    lumi = tags.get(b"lumi")
    if not lumi or len(lumi) < 20 or lumi[:4] != b"XYZ ":
        fail("Windows HDR shadow matching requires profile luminance metadata")
    white_nits = read_s15fixed16(lumi, 12)
    if white_nits <= 0.0:
        fail("Windows HDR shadow matching requires positive profile luminance")
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)
    d50 = (0.9642, 1.0, 0.8249)
    replacements = {}
    for signature, payload in read_icc_tags(profile):
        if signature not in (b"B2A0", b"B2A1") or signature in replacements:
            continue
        if len(payload) < 52 or payload[:4] != b"mft2":
            continue
        input_channels, output_channels, grid = payload[8], payload[9], payload[10]
        input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
        if input_channels != 3 or output_channels != 3 or grid < 2:
            continue
        input_start = 52
        clut_start = input_start + input_channels * input_entries * 2
        clut_values = grid ** input_channels * output_channels
        output_start = clut_start + clut_values * 2
        if output_start + output_channels * output_entries * 2 > len(payload):
            fail("Windows HDR shadow matching found a truncated B2A table")
        input_tables = []
        output_tables = []
        for channel in range(3):
            offset = input_start + channel * input_entries * 2
            input_tables.append([value / 65535.0 for value in struct.unpack_from(
                ">{}H".format(input_entries), payload, offset)])
            offset = output_start + channel * output_entries * 2
            output_tables.append([value / 65535.0 for value in struct.unpack_from(
                ">{}H".format(output_entries), payload, offset)])
        updated = bytearray(payload)
        denominator = float(grid - 1)
        for red in range(grid):
            for green in range(max(0, red - 1), min(grid, red + 2)):
                for blue in range(max(0, red - 1), min(grid, red + 2)):
                    if max(red, green, blue) - min(red, green, blue) > 1:
                        continue
                    estimates = []
                    for channel, node in enumerate((red, green, blue)):
                        encoded_xyz = invert_table(
                            input_tables[channel], node / denominator)
                        pcs = encoded_xyz / xyz_to_mft
                        relative = max(0.0, pcs / d50[channel])
                        estimates.append(nits_to_pq(relative * white_nits))
                    source_code = sorted(estimates)[1]
                    if source_code > source_limit:
                        continue
                    node_offset = (((red * grid + green) * grid + blue) * 3)
                    for channel in range(3):
                        curve_input = nits_to_pq(
                            pq_to_nits(source_code) * neutral_gains[channel])
                        correction = (
                            sample_table(corrected_luts[channel], curve_input)
                            - sample_table(reference_luts[channel], curve_input))
                        # Inverting a flat output-table value chooses its far
                        # edge. Rewriting a zero correction therefore expanded
                        # the peak plateau down into code 767 even though the
                        # requested node value was unchanged.
                        if abs(correction) < 1e-9:
                            continue
                        node_value = struct.unpack_from(
                            ">H", payload,
                            clut_start + (node_offset + channel) * 2)[0] / 65535.0
                        old_output = sample_table(
                            output_tables[channel], node_value)
                        desired = max(0.0, min(1.0,
                                              old_output + correction))
                        encoded = invert_table(output_tables[channel],
                                               desired)
                        struct.pack_into(">H", updated,
                                         clut_start + (node_offset + channel) * 2,
                                         max(0, min(65535,
                                             int(round(encoded * 65535.0)))))
        replacements[signature] = bytes(updated)
    return rebuild_icc(profile, replacements) if replacements else profile


def hdr_profile_calibration_from_a2b(profile, rows, fallback, entries=4096,
                                     raw_measurement_model=False):
    """Build neutral B2A output curves from the raw measured forward model.

    Dense neutral measurements anchor luminance and the first OLED plateau.
    Argyll's A2B fit supplies only the local, level-dependent RGB-to-XYZ
    Jacobian used for white-point correction. This consumes the original
    characterization set and never requires a post-profile measurement pass.
    A raw-only build retains the measured primary fallback throughout the
    low-signal range; active-path probe builds can use their local Jacobians.
    """
    neutral = []
    for row in rows:
        if max(row["rgb"]) - min(row["rgb"]) <= 0.002:
            neutral.append((sum(row["rgb"]) / 3.0, tuple(row["xyz"])))
    neutral.sort(key=lambda item: item[0])
    if len(neutral) < 9 or neutral[0][0] > 0.002 or neutral[-1][0] < 0.998:
        fail("HDR calibration requires dense black-to-white neutral measurements")
    # Counting rows is not coverage: a set whose neutrals are all black and
    # white repeats passes the count and then fabricates a linear-light
    # neutral by interpolating across the whole range. Require actual
    # mid-range coverage before trusting the interpolation.
    distinct = sorted(set(round(code, 4) for code, _ in neutral))
    largest_gap = max(b - a for a, b in zip(distinct, distinct[1:]))
    if largest_gap > 0.10:
        fail("HDR calibration requires dense black-to-white neutral measurements")

    # Collapse repeated black/white anchors before interpolating chromaticity.
    # The dense neutral measurements contain the physical XYZ information we
    # are trying to correct; using only their Y values and taking chromaticity
    # from the fitted A2B model throws that information away.
    grouped_neutral = []
    for code, xyz in neutral:
        if grouped_neutral and abs(grouped_neutral[-1][0] - code) < 1e-9:
            grouped_neutral[-1][1].append({"xyz": xyz})
        else:
            grouped_neutral.append([code, [{"xyz": xyz}]])
    measured_neutral = [
        (code, robust_xyz(samples)) for code, samples in grouped_neutral
    ]

    def measured_xyz_at_code(code):
        if code <= measured_neutral[0][0]:
            return measured_neutral[0][1]
        for anchor in range(1, len(measured_neutral)):
            x0, xyz0 = measured_neutral[anchor - 1]
            x1, xyz1 = measured_neutral[anchor]
            if code <= x1:
                fraction = 0.0 if x1 <= x0 else (code - x0) / (x1 - x0)
                return tuple(xyz0[channel] * (1.0 - fraction)
                             + xyz1[channel] * fraction for channel in range(3))
        return measured_neutral[-1][1]

    neutral_codes = np.asarray([code for code, _xyz in measured_neutral],
                               dtype=np.float64)
    neutral_xyz = np.asarray([xyz for _code, xyz in measured_neutral],
                             dtype=np.float64)

    def measured_xyz_at_codes(codes):
        """Batch twin of measured_xyz_at_code()."""
        index, found = _np_first_at_or_above(neutral_codes, codes)
        lower = neutral_codes[index - 1]
        span = neutral_codes[index] - lower
        positive = span > 0.0
        fraction = np.where(positive,
                            (codes - lower) / np.where(positive, span, 1.0),
                            0.0)
        result = (neutral_xyz[index - 1] * (1.0 - fraction)[:, None]
                  + neutral_xyz[index] * fraction[:, None])
        result = np.where(found[:, None], result, neutral_xyz[-1])
        return np.where((codes <= neutral_codes[0])[:, None],
                        neutral_xyz[0], result)

    response_neutral = [(code, xyz[1]) for code, xyz in measured_neutral]

    blocks = []
    for index, (_code, response) in enumerate(response_neutral):
        blocks.append([index, index, response, 1.0])
        while (len(blocks) >= 2
               and blocks[-2][2] / blocks[-2][3] > blocks[-1][2] / blocks[-1][3]):
            right = blocks.pop()
            left = blocks.pop()
            blocks.append([left[0], right[1], left[2] + right[2], left[3] + right[3]])
    fitted = [0.0] * len(response_neutral)
    for start, end, total, weight in blocks:
        for index in range(start, end + 1):
            fitted[index] = total / weight
    response_neutral = [(response_neutral[index][0], fitted[index])
                        for index in range(len(response_neutral))]
    peak = max(response for _code, response in response_neutral)
    plateau_code = next(code for code, response in response_neutral
                        if response >= peak * 0.998)

    # Recover the absolute contribution of each channel from every measured
    # neutral patch.  Unlike the independent primary ramps, these samples were
    # measured at the same OLED loading as the grey axis we need to reproduce.
    # Keep the responses absolute: normalising each channel independently
    # would discard the measured white balance that this solve must correct.
    black, _white, primaries = profile_measurement_summary(rows)
    black_xyz = tuple(black["xyz"])
    primary_axes = [
        [primaries[column]["xyz"][axis] - black_xyz[axis]
         for column in range(3)]
        for axis in range(3)
    ]
    inverse_primary_axes = mat_inv(primary_axes)
    absolute_channel_samples = [[] for _channel in range(3)]
    for code, xyz in measured_neutral:
        response = mat_vec_mul(
            inverse_primary_axes,
            [xyz[axis] - black_xyz[axis] for axis in range(3)],
        )
        for channel in range(3):
            absolute_channel_samples[channel].append(
                (code, max(0.0, response[channel])))

    def isotonic_absolute(samples):
        blocks = []
        for sample_index, (_code, response) in enumerate(samples):
            blocks.append([sample_index, sample_index, response, 1.0])
            while (len(blocks) >= 2
                   and blocks[-2][2] / blocks[-2][3]
                   > blocks[-1][2] / blocks[-1][3]):
                right = blocks.pop()
                left = blocks.pop()
                blocks.append([left[0], right[1], left[2] + right[2],
                               left[3] + right[3]])
        fitted_samples = []
        for start, end, total, weight in blocks:
            value = max(0.0, total / weight)
            for sample_index in range(start, end + 1):
                fitted_samples.append((samples[sample_index][0], value))
        return fitted_samples

    absolute_channel_samples = [
        isotonic_absolute(samples) for samples in absolute_channel_samples
    ]

    def invert_response(codes, responses, targets):
        """Batch inverse of one isotonic code-to-response series.

        Serves both the absolute per-channel responses and the neutral
        luminance series: the two scalar originals were the same scan with
        the same flat-segment and plateau clamps.
        """
        index, found = _np_first_at_or_above(responses, targets)
        lower_code = codes[index - 1]
        lower = responses[index - 1]
        upper = responses[index]
        flat = upper <= lower + 1e-12
        span = upper - lower
        fraction = np.where(flat, 0.0,
                            (targets - lower) / np.where(flat, 1.0, span))
        result = np.where(
            flat, np.minimum(codes[index], plateau_code),
            np.minimum(lower_code + fraction * (codes[index] - lower_code),
                       plateau_code))
        result = np.where(found, result, plateau_code)
        return np.where(targets <= responses[0], codes[0], result)

    absolute_channel_codes = [
        np.asarray([code for code, _value in samples], dtype=np.float64)
        for samples in absolute_channel_samples
    ]
    absolute_channel_values = [
        np.asarray([value for _code, value in samples], dtype=np.float64)
        for samples in absolute_channel_samples
    ]

    def measured_axis_rgb(target_xyz):
        """Batch twin: (E, 3) absolute XYZ targets to (E, 3) device codes."""
        offsets = target_xyz - np.asarray(black_xyz, dtype=np.float64)
        result = np.empty(target_xyz.shape, dtype=np.float64)
        for channel in range(3):
            response = (inverse_primary_axes[channel][0] * offsets[:, 0]
                        + inverse_primary_axes[channel][1] * offsets[:, 1]
                        + inverse_primary_axes[channel][2] * offsets[:, 2])
            result[:, channel] = invert_response(
                absolute_channel_codes[channel],
                absolute_channel_values[channel],
                np.maximum(0.0, response))
        return result

    response_codes = np.asarray([code for code, _value in response_neutral],
                                dtype=np.float64)
    response_values = np.asarray([value for _code, value in response_neutral],
                                 dtype=np.float64)

    evaluate = mft2_a2b_evaluator(profile)
    d50 = (0.9642, 1.0, 0.8249)
    d65 = (0.3127 / 0.329, 1.0, (1.0 - 0.3127 - 0.329) / 0.329)
    chad_payload = dict(read_icc_tags(profile)).get(b"chad")
    if not chad_payload or len(chad_payload) < 44 or chad_payload[:4] != b"sf32":
        fail("Measured HDR calibration requires the profile chromatic-adaptation matrix")
    chad = [value / 65536.0 for value in struct.unpack_from(">9i", chad_payload, 8)]
    white_y = max(xyz[1] for code, xyz in measured_neutral if code >= 0.998)
    first_nonzero_y = min(xyz[1] for _code, xyz in measured_neutral if xyz[1] > 0)
    full_model_floor = max(first_nonzero_y * 3.0, 0.03)
    channel_measurements = [[], [], []]
    black_xyz = measured_neutral[0][1]
    for channel in range(3):
        channel_measurements[channel].append((0.0, black_xyz))
    for row in rows:
        for channel in range(3):
            if (row["rgb"][channel] > 0
                    and all(row["rgb"][other] <= 1e-9
                            for other in range(3) if other != channel)):
                channel_measurements[channel].append(
                    (row["rgb"][channel], tuple(row["xyz"])))
    for channel in range(3):
        channel_measurements[channel].sort(key=lambda item: item[0])
        if len(channel_measurements[channel]) < 6:
            fail("HDR low-light calibration requires measured single-channel ramps")

    color_measurements = []
    neutral_probe_groups = {}
    neutral_probe_pattern = re.compile(
        r"^ICC Neutral Jacobian ([0-9]{4}) ([RGB])([+-])$")
    for row in rows:
        rgb = tuple(row["rgb"])
        if max(rgb) - min(rgb) > 0.002:
            measurement = (rgb, tuple(row["xyz"]), str(row.get("name", "")))
            color_measurements.append(measurement)
            match = neutral_probe_pattern.match(measurement[2])
            if match:
                center = int(match.group(1)) / 1023.0
                neutral_probe_groups.setdefault(center, []).append(measurement)

    channel_anchor_codes = [
        np.asarray([code for code, _xyz in channel_measurements[channel]],
                   dtype=np.float64) for channel in range(3)
    ]
    channel_anchor_xyz = [
        np.asarray([xyz for _code, xyz in channel_measurements[channel]],
                   dtype=np.float64) for channel in range(3)
    ]

    def measured_channel_xyz(channel, codes):
        """Batch twin: one channel's ramp sampled at (E,) device codes."""
        anchors = channel_anchor_codes[channel]
        values = channel_anchor_xyz[channel]
        index, _found = _np_first_at_or_above(anchors, codes)
        lower = anchors[index - 1]
        span = anchors[index] - lower
        positive = span > 0.0
        fraction = np.clip(
            np.where(positive, (codes - lower) / np.where(positive, span, 1.0),
                     0.0), 0.0, 1.0)
        result = (values[index - 1] * (1.0 - fraction)[:, None]
                  + values[index] * fraction[:, None])
        result = np.where(positive[:, None], result, values[index - 1])
        return np.where((codes <= anchors[0])[:, None], values[0], result)

    def measured_channel_derivative(channel, codes):
        """Batch twin: one channel ramp's local XYZ derivative."""
        anchors = channel_anchor_codes[channel]
        values = channel_anchor_xyz[channel]
        index, _found = _np_first_at_or_above(anchors, codes)
        span = anchors[index] - anchors[index - 1]
        positive = span > 0.0
        slope = ((values[index] - values[index - 1])
                 / np.where(positive, span, 1.0)[:, None])
        return np.where(positive[:, None], slope, 0.0)

    def additive_xyz(codes):
        # Each primary ramp includes the measured black offset. Count that
        # offset once when combining the three independently measured ramps.
        return (measured_channel_xyz(0, codes)
                + measured_channel_xyz(1, codes)
                + measured_channel_xyz(2, codes)
                - 2.0 * np.asarray(black_xyz, dtype=np.float64))

    def fit_measured_jacobian(code, nearby, dedicated=False):
        """Fit a physical RGB-to-XYZ derivative around one neutral code.

        The dedicated probe-group regime still runs here, once per group. The
        neighbourhood regime is served by fit_local_jacobians() below, which
        fits every curve entry at once against the same expressions.
        """
        minimum = 6 if dedicated else 12
        if len(nearby) < minimum:
            return None, 0.0
        if dedicated:
            # The midpoint of symmetric +/- samples is a cleaner derivative
            # origin than a separate neutral read. It cancels the common
            # loading response and prevents a small center-read offset from
            # being misclassified as a poor directional fit.
            center_xyz = tuple(sum(item[1][axis] for item in nearby)
                               / len(nearby) for axis in range(3))
        else:
            center_xyz = measured_xyz_at_code(code)
        bandwidth2 = max(1e-8, sum(
            (nearby[-1][0][channel] - code) ** 2 for channel in range(3)))
        normal = [[0.0] * 3 for _axis in range(3)]
        cross = [[0.0] * 3 for _axis in range(3)]
        weighted_actual = 0.0
        samples = []
        for rgb, xyz, _name in nearby:
            distance2 = sum((rgb[channel] - code) ** 2 for channel in range(3))
            weight = (1.0 if dedicated else
                      math.exp(-2.0 * distance2 / bandwidth2))
            device_delta = [rgb[channel] - code for channel in range(3)]
            xyz_delta = [xyz[axis] - center_xyz[axis] for axis in range(3)]
            samples.append((weight, device_delta, xyz_delta))
            for first in range(3):
                for second in range(3):
                    normal[first][second] += (weight * device_delta[first]
                                              * device_delta[second])
                for axis in range(3):
                    cross[axis][first] += weight * device_delta[first] * xyz_delta[axis]
            weighted_actual += weight * sum(value * value for value in xyz_delta)
        ridge = max(1e-12, sum(normal[index][index] for index in range(3)) * 1e-7)
        for index in range(3):
            normal[index][index] += ridge
        # The dedicated +/- probes use a deliberately small device-code
        # displacement. Their normal matrix is therefore well-conditioned
        # but has a determinant below mat_inv()'s absolute primary-matrix
        # guard. Normalize its magnitude before inversion so the guard tests
        # conditioning instead of rejecting every measured probe group.
        try:
            if raw_measurement_model:
                inverse = mat_inv(normal)
            else:
                normal_scale = max(abs(value) for row in normal for value in row)
                if normal_scale <= 1e-18:
                    return None, 0.0
                scaled_inverse = mat_inv([
                    [value / normal_scale for value in row] for row in normal
                ])
                inverse = [[value / normal_scale for value in row]
                           for row in scaled_inverse]
        except Exception:
            return None, 0.0
        jacobian = [
            [sum(cross[axis][index] * inverse[index][channel]
                 for index in range(3)) for channel in range(3)]
            for axis in range(3)
        ]
        weighted_error = 0.0
        for weight, device_delta, xyz_delta in samples:
            predicted = mat_vec_mul(jacobian, device_delta)
            weighted_error += weight * sum(
                (xyz_delta[axis] - predicted[axis]) ** 2 for axis in range(3))
        fit = max(0.0, 1.0 - weighted_error / max(weighted_actual, 1e-12))
        radius = math.sqrt(bandwidth2)
        if dedicated:
            # Six symmetric probes at one loading level provide the derivative
            # directly. Their directional fit can still look excellent when
            # the panel changed state between the neutral ramp and this local
            # group, though. Require the midpoint of the six probes to agree
            # with the independent neutral ramp before that derivative owns
            # the correction. This keeps a stable local probe authoritative
            # without letting a loading or presentation transition turn into
            # an over-correction on a display that did not need it.
            confidence = max(0.0, min(1.0, (fit - 0.45) / 0.45))
            reference_xyz = measured_xyz_at_code(code)
            center_sum = sum(center_xyz)
            reference_sum = sum(reference_xyz)
            if center_sum <= 1e-12 or reference_sum <= 1e-12:
                return jacobian, 0.0
            center_xy = (center_xyz[0] / center_sum,
                         center_xyz[1] / center_sum)
            reference_xy = (reference_xyz[0] / reference_sum,
                            reference_xyz[1] / reference_sum)
            chroma_distance = math.hypot(
                center_xy[0] - reference_xy[0],
                center_xy[1] - reference_xy[1])
            chroma_agreement = 1.0 - smoothstep(
                (chroma_distance - 0.0015) / (0.0060 - 0.0015))
            luminance_difference = (abs(center_xyz[1] - reference_xyz[1])
                                    / max(center_xyz[1], reference_xyz[1],
                                          1e-9))
            luminance_agreement = 1.0 - smoothstep(
                (luminance_difference - 0.03) / (0.12 - 0.03))
            confidence *= chroma_agreement * luminance_agreement
            return jacobian, confidence
        # Requiring 32 neighbours made a 425-patch set reach far outside the
        # local HDR shoulder. Its radius then zeroed confidence completely and
        # silently fell back to Argyll's smoothed plateau, even though the 12
        # closest mixed patches form a well-conditioned, high-quality local
        # fit. Fade that fit only once its closest useful neighbourhood grows
        # beyond 0.30 device units.
        coverage = max(0.0, min(1.0, (0.30 - radius) / 0.12))
        confidence = coverage * max(0.0, min(1.0, (fit - 0.35) / 0.55))
        return jacobian, confidence

    dedicated_jacobians = []
    for center, samples in sorted(neutral_probe_groups.items()):
        # Reject incomplete groups. A cancelled measurement run must not turn
        # three or four directional samples into a confident 3x3 inverse.
        directions = set()
        for _rgb, _xyz, name in samples:
            match = neutral_probe_pattern.match(name)
            if match:
                directions.add(match.group(2) + match.group(3))
        if directions != set(("R-", "R+", "G-", "G+", "B-", "B+")):
            continue
        jacobian, confidence = fit_measured_jacobian(
            center, sorted(samples, key=lambda item: sum(
                (item[0][channel] - center) ** 2 for channel in range(3))),
            dedicated=True)
        if jacobian is not None and confidence > 0.0:
            dedicated_jacobians.append((center, jacobian, confidence))

    color_rgb = np.asarray([item[0] for item in color_measurements],
                           dtype=np.float64).reshape(-1, 3)
    color_xyz = np.asarray([item[1] for item in color_measurements],
                           dtype=np.float64).reshape(-1, 3)

    def fit_local_jacobians(codes):
        """Batch neighbourhood fit: the non-dedicated fit_measured_jacobian().

        Every entry takes its twelve closest mixed-colour patches and runs the
        same ridge-regularized weighted normal equations. The twelve slots are
        accumulated in ascending-distance order so the sequential summation
        rounding of the scalar sample loop is reproduced, and the neighbour
        order itself comes from a stable argsort so equal distances resolve
        the way Python's stable sorted() resolves them.
        """
        count = codes.shape[0]
        jacobian = np.zeros((count, 9), dtype=np.float64)
        confidence = np.zeros(count, dtype=np.float64)
        present = np.zeros(count, dtype=bool)
        if len(color_measurements) < 12:
            return jacobian, confidence, present
        for start in range(0, count, _FIT_CHUNK):
            stop = min(count, start + _FIT_CHUNK)
            block = codes[start:stop]
            distance = (_pow2(color_rgb[None, :, 0] - block[:, None])
                        + _pow2(color_rgb[None, :, 1] - block[:, None])
                        + _pow2(color_rgb[None, :, 2] - block[:, None]))
            order = np.argsort(distance, axis=1, kind="stable")[:, :12]
            ordered = np.take_along_axis(distance, order, axis=1)
            bandwidth2 = np.maximum(1e-8, ordered[:, 11])
            center_xyz = measured_xyz_at_codes(block)
            normal = [np.zeros(stop - start, dtype=np.float64) for _ in range(9)]
            cross = [np.zeros(stop - start, dtype=np.float64) for _ in range(9)]
            weighted_actual = np.zeros(stop - start, dtype=np.float64)
            weights = []
            device_deltas = []
            xyz_deltas = []
            for slot in range(12):
                weight = np.exp(-2.0 * ordered[:, slot] / bandwidth2)
                device_delta = color_rgb[order[:, slot]] - block[:, None]
                xyz_delta = color_xyz[order[:, slot]] - center_xyz
                weights.append(weight)
                device_deltas.append(device_delta)
                xyz_deltas.append(xyz_delta)
                for first in range(3):
                    for second in range(3):
                        normal[first * 3 + second] += (
                            weight * device_delta[:, first]
                            * device_delta[:, second])
                    for axis in range(3):
                        cross[axis * 3 + first] += (weight * device_delta[:, first]
                                                    * xyz_delta[:, axis])
                weighted_actual += weight * (xyz_delta[:, 0] * xyz_delta[:, 0]
                                             + xyz_delta[:, 1] * xyz_delta[:, 1]
                                             + xyz_delta[:, 2] * xyz_delta[:, 2])
            ridge = np.maximum(1e-12, (normal[0] + normal[4] + normal[8]) * 1e-7)
            for diagonal in (0, 4, 8):
                normal[diagonal] = normal[diagonal] + ridge
            # The dedicated +/- probes use a deliberately small device-code
            # displacement, so the raw normal matrix can fall below the
            # absolute determinant guard while still being well conditioned.
            # Normalize its magnitude first, exactly as the scalar does.
            if raw_measurement_model:
                inverse, usable = _np_mat_inv3(normal)
            else:
                scale = np.abs(normal[0])
                for entry in normal[1:]:
                    scale = np.maximum(scale, np.abs(entry))
                scaled = scale > 1e-18
                divisor = np.where(scaled, scale, 1.0)
                scaled_inverse, valid = _np_mat_inv3(
                    [entry / divisor for entry in normal])
                inverse = [entry / divisor for entry in scaled_inverse]
                usable = scaled & valid
            fitted = []
            for axis in range(3):
                for channel in range(3):
                    fitted.append(cross[axis * 3] * inverse[channel]
                                  + cross[axis * 3 + 1] * inverse[3 + channel]
                                  + cross[axis * 3 + 2] * inverse[6 + channel])
            weighted_error = np.zeros(stop - start, dtype=np.float64)
            for slot in range(12):
                weight = weights[slot]
                device_delta = device_deltas[slot]
                xyz_delta = xyz_deltas[slot]
                squares = np.zeros(stop - start, dtype=np.float64)
                for axis in range(3):
                    predicted = (fitted[axis * 3] * device_delta[:, 0]
                                 + fitted[axis * 3 + 1] * device_delta[:, 1]
                                 + fitted[axis * 3 + 2] * device_delta[:, 2])
                    squares = squares + _pow2(xyz_delta[:, axis] - predicted)
                weighted_error += weight * squares
            fit = np.maximum(0.0, 1.0 - weighted_error
                             / np.maximum(weighted_actual, 1e-12))
            # Requiring 32 neighbours made a 425-patch set reach far outside
            # the local HDR shoulder. Fade the fit only once its closest
            # useful neighbourhood grows beyond 0.30 device units.
            coverage = np.clip((0.30 - np.sqrt(bandwidth2)) / 0.12, 0.0, 1.0)
            block_confidence = coverage * np.clip((fit - 0.35) / 0.55, 0.0, 1.0)
            for entry in range(9):
                jacobian[start:stop, entry] = np.where(usable, fitted[entry], 0.0)
            confidence[start:stop] = np.where(usable, block_confidence, 0.0)
            present[start:stop] = usable
        return jacobian, confidence, present

    def measured_local_jacobians(codes):
        """Batch twin: fit or interpolate the local RGB-to-XYZ derivative."""
        count = codes.shape[0]
        jacobian = np.zeros((count, 9), dtype=np.float64)
        confidence = np.zeros(count, dtype=np.float64)
        present = np.zeros(count, dtype=bool)
        pending = np.ones(count, dtype=bool)
        if dedicated_jacobians:
            centers = np.asarray([item[0] for item in dedicated_jacobians],
                                 dtype=np.float64)
            matrices = np.asarray(
                [[item[1][axis][channel] for axis in range(3)
                  for channel in range(3)] for item in dedicated_jacobians],
                dtype=np.float64)
            confidences = np.asarray([item[2] for item in dedicated_jacobians],
                                     dtype=np.float64)
            below = codes <= centers[0]
            above = (~below) & (codes >= centers[-1])
            for edge, side in ((below, 0), (above, -1)):
                distance = (centers[0] - codes) if side == 0 else (codes - centers[-1])
                reach = np.clip(1.0 - distance / 0.04, 0.0, 1.0)
                # A zero reach is not a result: the scalar falls through to
                # the neighbourhood fit there.
                taken = edge & (reach > 0.0)
                jacobian[taken] = matrices[side]
                confidence[taken] = (confidences[side] * reach)[taken]
                present |= taken
                pending &= ~taken
            interior = ~(below | above)
            if len(dedicated_jacobians) > 1 and np.any(interior):
                index, found = _np_first_at_or_above(centers, codes)
                span = np.maximum(centers[index] - centers[index - 1], 1e-9)
                fraction = (codes - centers[index - 1]) / span
                taken = interior & found
                blended = (matrices[index - 1] * (1.0 - fraction)[:, None]
                           + matrices[index] * fraction[:, None])
                jacobian[taken] = blended[taken]
                confidence[taken] = (confidences[index - 1] * (1.0 - fraction)
                                     + confidences[index] * fraction)[taken]
                present |= taken
                pending &= ~taken
        if np.any(pending):
            fitted, fitted_confidence, fitted_present = fit_local_jacobians(
                codes[pending])
            jacobian[pending] = fitted
            confidence[pending] = fitted_confidence
            present[pending] = fitted_present
        return jacobian, confidence, present

    step = 2.0 / 1023.0
    encoded = np.arange(entries, dtype=np.float64) / float(entries - 1)
    target_nits = np.minimum(_np_pq_to_nits(encoded), peak)
    base = invert_response(response_codes, response_values, target_nits)
    rgb = np.stack([base, base, base], axis=1)
    actual = evaluate(rgb)
    columns = []
    for channel in range(3):
        probe = rgb.copy()
        moved = np.minimum(1.0, base + step)
        moved = np.where(moved == base, np.maximum(0.0, base - step), moved)
        probe[:, channel] = moved
        # Never zero: a base that clamps at 1.0 going up has room going down.
        columns.append((evaluate(probe) - actual) / (moved - base)[:, None])
    jacobian = []
    for axis in range(3):
        for channel in range(3):
            jacobian.append(columns[channel][:, axis])
    measured_xyz = measured_xyz_at_codes(base)
    target_xyz = target_nits[:, None] * np.asarray(d65, dtype=np.float64)
    axis_rgb = measured_axis_rgb(target_xyz)
    pcs_residual = np.empty((entries, 3), dtype=np.float64)
    for axis in range(3):
        pcs_residual[:, axis] = (
            (chad[axis * 3] * target_xyz[:, 0] / white_y
             + chad[axis * 3 + 1] * target_xyz[:, 1] / white_y
             + chad[axis * 3 + 2] * target_xyz[:, 2] / white_y)
            - (chad[axis * 3] * measured_xyz[:, 0] / white_y
               + chad[axis * 3 + 1] * measured_xyz[:, 1] / white_y
               + chad[axis * 3 + 2] * measured_xyz[:, 2] / white_y))
    inverse, valid = _np_mat_inv3(jacobian)
    delta = np.empty((entries, 3), dtype=np.float64)
    for row in range(3):
        delta[:, row] = np.where(
            valid,
            inverse[row * 3] * pcs_residual[:, 0]
            + inverse[row * 3 + 1] * pcs_residual[:, 1]
            + inverse[row * 3 + 2] * pcs_residual[:, 2],
            0.0)
    # Near black, isolated primary ramps have useful channel directions
    # but their sum does not necessarily equal the display's measured
    # neutral response. Normalize each XYZ row of their Jacobian so equal
    # drive matches the dense neutral measurement at this code, then solve
    # the white-point residual around that physical neutral anchor.
    additive_at_neutral = additive_xyz(base)
    derivatives = [measured_channel_derivative(channel, base)
                   for channel in range(3)]
    normalized_jacobian = []
    for axis in range(3):
        row_scale = np.clip(
            measured_xyz[:, axis]
            / np.maximum(additive_at_neutral[:, axis], 1e-12), 0.1, 10.0)
        for channel in range(3):
            normalized_jacobian.append(derivatives[channel][:, axis] * row_scale)
    xyz_residual = target_xyz - measured_xyz
    normalized_inverse, normalized_valid = _np_mat_inv3(normalized_jacobian)
    normalized_primary_delta = np.empty((entries, 3), dtype=np.float64)
    for row in range(3):
        normalized_primary_delta[:, row] = np.where(
            normalized_valid,
            normalized_inverse[row * 3] * xyz_residual[:, 0]
            + normalized_inverse[row * 3 + 1] * xyz_residual[:, 1]
            + normalized_inverse[row * 3 + 2] * xyz_residual[:, 2],
            delta[:, row])

    # For the shoulder and peak, use the derivative fitted from nearby
    # measured mixed-color patches; isolated primaries do not model OLED
    # power limiting at white.
    local_jacobian, local_confidence, local_present = measured_local_jacobians(base)
    local_inverse, local_valid = _np_mat_inv3(
        [local_jacobian[:, entry] for entry in range(9)])
    use_local = local_present & (local_confidence > 0) & local_valid
    local_delta = np.empty((entries, 3), dtype=np.float64)
    for row in range(3):
        local_delta[:, row] = (local_inverse[row * 3] * xyz_residual[:, 0]
                               + local_inverse[row * 3 + 1] * xyz_residual[:, 1]
                               + local_inverse[row * 3 + 2] * xyz_residual[:, 2])
    if not raw_measurement_model:
        local_delta = np.clip(local_delta, -0.025, 0.025)
    delta = np.where(use_local[:, None],
                     local_delta * local_confidence[:, None]
                     + delta * (1.0 - local_confidence)[:, None],
                     delta)
    additive_full = peak * 0.005
    additive_end = peak * 0.0125
    target_fraction = target_nits / peak
    additive_weight = np.where(
        target_nits <= additive_full, 1.0,
        np.where(target_nits < additive_end,
                 1.0 - (target_nits - additive_full)
                 / (additive_end - additive_full),
                 0.0))
    # A complete, stable same-loading probe group is a direct measurement
    # of this derivative. The independent-primary fallback predates those
    # probes and must not overwrite their solved delta in the low-light
    # band. Partial confidence blends the two; charts without trustworthy
    # local probes retain the established fallback unchanged.
    if not raw_measurement_model:
        additive_weight = additive_weight * (1.0 - local_confidence)
    delta = (normalized_primary_delta * additive_weight[:, None]
             + delta * (1.0 - additive_weight)[:, None])
    delta = np.clip(delta, -0.04, 0.04)

    # Argyll's fitted Jacobian is useful through the uniquely invertible
    # body of the response.  In the shadows it has too little meter signal,
    # and in the OLED shoulder many device codes describe the same light
    # output.  Use the absolute response recovered from the dense measured
    # neutral series in those regions.  This is still a fully offline
    # characterization solve; no post-profile readings are involved.
    body_weight = np.where(
        target_fraction <= 0.0125, 0.0,
        np.where(target_fraction < 0.025,
                 (target_fraction - 0.0125) / 0.0125,
                 np.where(target_fraction <= 0.40, 1.0,
                          np.where(target_fraction < 0.75,
                                   1.0 - (target_fraction - 0.40) / 0.35,
                                   np.minimum(1.0, (target_fraction - 0.75)
                                              / 0.15)))))
    model_weight = np.where(
        target_nits <= first_nonzero_y, 0.0,
        np.where(target_nits < full_model_floor,
                 (target_nits - first_nonzero_y)
                 / (full_model_floor - first_nonzero_y),
                 body_weight))
    # Dedicated probes make the fitted model physically local even below
    # the old 1.25%-of-peak cutoff. Raise its weight only as the actual
    # measured signal becomes reliable; an incomplete or noisy probe set
    # has low confidence and naturally falls back to the axis solution.
    if dedicated_jacobians:
        signal_confidence = _np_smoothstep((target_nits - 0.01) / 0.14)
        model_weight = np.where(
            local_confidence > 0.0,
            np.maximum(model_weight, local_confidence * signal_confidence),
            model_weight)
    curves = []
    for channel in range(3):
        model_value = np.clip(base + delta[:, channel], 0.0, plateau_code)
        fallback_value = np.clip(axis_rgb[:, channel], 0.0, 1.0)
        curves.append((model_weight * model_value
                       + (1.0 - model_weight) * fallback_value).tolist())

    for channel in range(3):
        previous = 0.0
        for index in range(entries):
            previous = max(previous, curves[channel][index])
            curves[channel][index] = previous
        curves[channel][0] = 0.0

        # The display's neutral white response can plateau well before full
        # device drive, but this is a global B2A output shaper: parking it at
        # the white-plateau code through table endpoint 1.0 would also make
        # saturated primary drive above that code unreachable. Neutral HDR
        # never traverses positions above PQ(peak), because its PCS luminance
        # is capped at the measured peak. Reserve that unused tail for a
        # monotonic continuation to full device range so the cLUT can still
        # reproduce the measured gamut.
        neutral_limit = nits_to_pq(peak)
        neutral_value = sample_table(curves[channel], neutral_limit)
        for index in range(entries):
            position = index / float(entries - 1)
            if position <= neutral_limit:
                continue
            fraction = (position - neutral_limit) / (1.0 - neutral_limit)
            continuation = neutral_value + (1.0 - neutral_value) * fraction
            curves[channel][index] = max(curves[channel][index], continuation)
        curves[channel][-1] = 1.0
    return curves


def bradford_adaptation(source_white, destination_white):
    """Return a Bradford XYZ chromatic-adaptation matrix."""
    adaptation = shared_bradford_adaptation(
        source_white, destination_white, cone_tolerance=1e-12)
    if adaptation is None:
        fail("Measured profile white cannot be chromatically adapted")
    return adaptation


def profile_with_measured_chad(profile, black, white):
    """Supply the v2 display white adaptation needed by the HDR solver.

    Argyll v2 display profiles adapt their PCS internally but do not have to
    publish a chad tag. The measured-neutral solver needs the same explicit
    matrix to compare physical XYZ with A2B PCS values. This temporary model
    profile is used only while deriving calibration from the original reads;
    the generated Windows profile remains otherwise untouched.
    """
    tags = dict(read_icc_tags(profile))
    if b"chad" in tags:
        return profile
    black_xyz = black["xyz"]
    span = max(white["xyz"][1] - black_xyz[1], 1e-9)
    source_white = [
        (white["xyz"][axis] - black_xyz[axis]) / span for axis in range(3)
    ]
    adaptation = bradford_adaptation(source_white, (0.9642, 1.0, 0.8249))
    payload = b"sf32" + b"\0\0\0\0" + b"".join(
        s15fixed16(adaptation[row][column])
        for row in range(3) for column in range(3)
    )
    return rebuild_icc(profile, {b"chad": payload})


def windows_hdr_profile_adjustment_luts(profile, rows, fallback, black, white,
                                        matrix, entries=MHC2_HDR_LUT_ENTRIES,
                                        raw_measurement_model=False):
    """Derive Windows' post-PQ MHC2 curves from the fitted forward model.

    The dense neutral measurements determine luminance and the first stable
    HDR plateau. The A2B local model supplies level-dependent white balance.
    MHC2 receives each channel after its matrix gain and PQ encoding, so the
    source-domain calibration is resampled into that coordinate. Values above
    the calibrated neutral peak are held at the first plateau instead of
    jumping to full device drive on one channel.
    """
    model_profile = profile_with_measured_chad(profile, black, white)
    source_curves = hdr_profile_calibration_from_a2b(
        model_profile, rows, fallback, entries=4096,
        raw_measurement_model=raw_measurement_model)
    # The broad legacy smoother protects sparse charts from isolated meter
    # noise, but it also spreads a real 5% correction into an otherwise good
    # 10% point. Dedicated same-loading probes make that guess unnecessary.
    # Preserve their locally solved curve exactly; old charts retain the
    # conservative regularizer.
    if (raw_measurement_model
            or not any(str(row.get("name", "")).startswith(
                       "ICC Neutral Jacobian ") for row in rows)):
        source_curves = regularize_hdr_shadow_balance(source_curves)
    wire = mhc2_wire_matrix("windows-hdr")
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    maximum_gain = max(neutral_gains)
    if min(neutral_gains) <= 1e-6 or maximum_gain <= 1e-6:
        fail("HDR MHC2 calibration matrix has an invalid neutral response")
    black_nits = max(0.0, black["xyz"][1])
    raw_peak = max(white["xyz"][1], black_nits + 0.0001)
    calibrated_peak = black_nits + (raw_peak - black_nits) / maximum_gain
    source_limit = nits_to_pq(calibrated_peak)

    # Once the neutral response enters its HDR shoulder, nearby mixed-colour
    # characterization points no longer constrain a unique three-channel
    # inverse. Continuing to increase the fitted channel separation there can
    # turn a small native-white error into a large warm or cool plateau. Keep
    # the chromatic offset measured at the last well-conditioned part of the
    # response, while retaining the common neutral curve's luminance rise.
    # This is derived entirely from the original characterization set; it does
    # not require a post-calibration measurement pass.
    stable_position = nits_to_pq(
        black_nits + 0.60 * (calibrated_peak - black_nits))
    stable_values = [sample_table(curve, stable_position)
                     for curve in source_curves]
    stable_mean = sum(stable_values) / 3.0
    stable_offsets = [value - stable_mean for value in stable_values]
    for index in range(len(source_curves[0])):
        position = index / float(len(source_curves[0]) - 1)
        if position <= stable_position or position > source_limit:
            continue
        mean = sum(source_curves[channel][index]
                   for channel in range(3)) / 3.0
        for channel in range(3):
            source_curves[channel][index] = max(
                0.0, min(1.0, mean + stable_offsets[channel]))
    for channel in range(3):
        previous = 0.0
        for index in range(len(source_curves[channel])):
            previous = max(previous, source_curves[channel][index])
            source_curves[channel][index] = previous

    luts = []
    for channel in range(3):
        gain = neutral_gains[channel]
        values = []
        previous = 0.0
        for index in range(entries):
            mhc_input = index / float(entries - 1)
            source_nits = pq_to_nits(mhc_input) / gain
            source_position = min(source_limit, nits_to_pq(source_nits))
            value = sample_table(source_curves[channel], source_position)
            previous = max(previous, max(0.0, min(1.0, value)))
            values.append(previous)
        values[0] = 0.0
        luts.append(values)
    apply_mhc2_modeled_neutral_residual(
        luts, rows, black, profile_measurement_summary(rows)[2], neutral_gains,
        include_body=raw_measurement_model)
    endpoint_start = mhc2_exact_white_start(entries)
    if raw_measurement_model:
        chad_payload = dict(read_icc_tags(model_profile)).get(b"chad")
        if (chad_payload and len(chad_payload) >= 44
                and chad_payload[:4] == b"sf32"):
            chad_values = [value / 65536.0 for value in struct.unpack_from(
                ">9i", chad_payload, 8)]
            chad = [chad_values[0:3], chad_values[3:6], chad_values[6:9]]
            held = [luts[channel][endpoint_start - 1]
                    for channel in range(3)]
            exact_probe = [list(curve) for curve in luts]
            if apply_mhc2_profile_exact_white_tail(
                    exact_probe, mft2_a2b_evaluator(model_profile), chad,
                    damping=3.0):
                weakest = min(held)
                spread = max(held) - weakest
                for channel in range(3):
                    if exact_probe[channel][-1] <= held[channel] + 1e-9:
                        endpoint = held[channel]
                    else:
                        fraction = (0.63 if held[channel] <= weakest + 1e-9
                                    else 0.28)
                        movement_limit = max(0.0035, fraction * spread)
                        endpoint = min(held[channel] + 0.035,
                                       held[channel] + movement_limit,
                                       exact_probe[channel][-1])
                    for index in range(endpoint_start, entries):
                        luts[channel][index] = endpoint
    else:
        # Every code on a measured HDR plateau represents the same physical
        # output state. Hold the separately measured active-path shoulder
        # triplet through exact white rather than extrapolating its model.
        for channel in range(3):
            endpoint = luts[channel][endpoint_start - 1]
            for index in range(endpoint_start, entries):
                luts[channel][index] = endpoint
    return luts


def windows_hdr_commuting_adjustment_luts(matrix, modeled_luts, black, white,
                                           calibrated_peak, entries=None):
    """Reduce modeled HDR MHC2 curves to a matrix-safe common tone trim.

    The MHC2 matrix is linear and precedes the post-PQ 1DLUTs. A separate
    per-channel inverse derived from the same neutral measurements can correct
    the panel's white point a second time after the matrix, particularly on an
    OLED shoulder where the inverse is poorly conditioned. Preserve the
    modeled neutral luminance correction as one common light-domain factor,
    while leaving chromatic correction to the matrix. A common factor commutes
    with the matrix in linear light and cannot invent channel separation on a
    display whose measured response does not need it.

    Near black, small absolute meter errors produce large ratios and a common
    code move can still expose unequal physical channel toes. Keep only the
    matrix plus neutral-headroom compensation through 25% PQ, then blend the
    measured common tone correction in by 35%. Fine-tune can add a bounded
    channel residual later, after measuring the actually applied profile.
    """
    if (len(modeled_luts) != 3 or min(len(curve) for curve in modeled_luts) < 2
            or len(set(len(curve) for curve in modeled_luts)) != 1):
        fail("HDR MHC2 modeled curves are invalid")
    if entries is None:
        entries = len(modeled_luts[0])
    if entries != len(modeled_luts[0]):
        fail("HDR MHC2 commuting curves must preserve the modeled table size")

    wire = mhc2_wire_matrix("windows-hdr")
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(matrix, wire))
    final_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    if min(final_gains) <= 1e-6:
        fail("HDR MHC2 calibration matrix has an invalid neutral response")

    black_nits = max(0.0, black["xyz"][1])
    raw_peak = max(white["xyz"][1], black_nits + 0.0001)
    calibrated_span = max(calibrated_peak - black_nits, 0.0001)
    pre_headroom_maximum = (raw_peak - black_nits) / calibrated_span
    scale = max(final_gains) / pre_headroom_maximum
    if not math.isfinite(scale) or scale <= 1e-6 or scale > 1.0001:
        fail("HDR MHC2 neutral-headroom scale is invalid")
    scale = min(1.0, scale)
    source_limit = min(1.0, nits_to_pq(calibrated_peak))

    def baseline_output(position):
        return nits_to_pq(pq_to_nits(position) / scale)

    def common_factor(source_position):
        source_position = max(0.0, min(source_limit, source_position))
        source_nits = pq_to_nits(source_position)
        ratios = []
        for channel in range(3):
            curve_input = nits_to_pq(source_nits * final_gains[channel])
            baseline = baseline_output(curve_input)
            baseline_nits = pq_to_nits(baseline)
            modeled = sample_table(modeled_luts[channel], curve_input)
            if baseline_nits > 1e-8:
                ratios.append(pq_to_nits(modeled) / baseline_nits)
        factor = sorted(ratios)[len(ratios) // 2] if ratios else 1.0
        factor = max(0.25, min(4.0, factor))
        if source_position <= 0.25:
            weight = 0.0
        elif source_position >= 0.35:
            weight = 1.0
        else:
            weight = (source_position - 0.25) / 0.10
            weight = smoothstep(weight)
        return 1.0 + weight * (factor - 1.0)

    luts = []
    for channel in range(3):
        limit_input = nits_to_pq(
            pq_to_nits(source_limit) * final_gains[channel])
        values = []
        previous = 0.0
        for index in range(entries):
            position = index / float(entries - 1)
            active_input = min(position, limit_input)
            source_position = nits_to_pq(
                pq_to_nits(active_input) / final_gains[channel])
            value = nits_to_pq(
                pq_to_nits(baseline_output(active_input))
                * common_factor(source_position))
            previous = max(previous, max(0.0, min(1.0, value)))
            values.append(previous)
        values[0] = 0.0
        luts.append(values)
    return luts


def windows_hdr_mhc2_luts_from_final_b2a(profile, mhc2):
    """Clone the finished explicit-cLUT neutral path into Windows MHC2.

    The cLUT and system paths are two presentations of the same calibrated
    profile.  Building both from separate inverse models lets small fit and
    shoulder decisions accumulate into visibly different greyscale.  At the
    end of the build B2A0 is authoritative, so sample its exact HDR neutral
    response and express that response in the coordinate seen by each MHC2
    curve after the tag matrix.  This is display-independent: a B2A that needs
    no per-channel correction produces matching curves without an added one.
    """
    if len(mhc2) < 84 or mhc2[:4] != b"MHC2":
        fail("Windows HDR cLUT matching requires an MHC2 profile")
    entries = struct.unpack_from(">I", mhc2, 8)[0]
    matrix_offset = struct.unpack_from(">I", mhc2, 20)[0]
    if entries < 2 or entries > 4096 or matrix_offset + 48 > len(mhc2):
        fail("Windows HDR cLUT matching found an invalid MHC2 tag")
    matrix = [
        [read_s15fixed16(mhc2, matrix_offset + row * 16 + column * 4)
         for column in range(3)]
        for row in range(3)
    ]
    wire = mhc2_wire_matrix("windows-hdr")
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    if min(neutral_gains) <= 1e-6:
        fail("Windows HDR cLUT matching found an invalid MHC2 neutral response")
    evaluate = windows_hdr_b2a_neutral_evaluator(profile)
    luts = []
    for channel, gain in enumerate(neutral_gains):
        values = []
        for index in range(entries):
            curve_input = index / float(entries - 1)
            source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
            values.append(max(0.0, min(1.0, evaluate(source_code)[channel])))
        values = isotonic_curve(values)
        values[0] = 0.0
        luts.append(values)
    return luts


def mhc2_with_adjustment_luts(payload, luts):
    """Replace only the three 1DLUTs in an already serialized MHC2 tag."""
    if len(payload) < 36 or payload[:4] != b"MHC2":
        fail("MHC2 payload is invalid")
    entries = struct.unpack_from(">I", payload, 8)[0]
    if (entries < 2 or len(luts) != 3
            or any(len(curve) != entries for curve in luts)):
        fail("MHC2 replacement curves have an invalid size")
    offsets = struct.unpack_from(">III", payload, 24)
    result = bytearray(payload)
    for channel, offset in enumerate(offsets):
        if (offset <= 0 or offset + 8 + entries * 4 > len(result)
                or result[offset:offset + 4] != b"sf32"):
            fail("MHC2 replacement curve offset is invalid")
        for index, value in enumerate(luts[channel]):
            result[offset + 8 + index * 4:offset + 12 + index * 4] = \
                s15fixed16(max(0.0, min(1.0, value)))
    return bytes(result)


def mhc2_adjustment_luts(payload):
    """Read the three adjustment curves from a serialized MHC2 tag."""
    if len(payload) < 36 or payload[:4] != b"MHC2":
        fail("MHC2 payload is invalid")
    entries = struct.unpack_from(">I", payload, 8)[0]
    offsets = struct.unpack_from(">III", payload, 24)
    curves = []
    for offset in offsets:
        if (entries < 2 or offset <= 0
                or offset + 8 + entries * 4 > len(payload)
                or payload[offset:offset + 4] != b"sf32"):
            fail("MHC2 adjustment curve offset is invalid")
        curves.append([
            read_s15fixed16(payload, offset + 8 + index * 4)
            for index in range(entries)
        ])
    return curves


def mhc2_shadow_probe_weight(source_code, fade_start=0.38, fade_span=0.07):
    """Return the PQ curve-probe envelope, 10-35% band by default.

    The cLUT corridor needs anchors nearer the knee than the MHC2 path does,
    because MHC2 gets its top end from the peak candidate and final peak
    feedback stages while B2A has no equivalent. Measured consequence of the
    default envelope: probes at codes 460 through 716 carried zero amplitude,
    so their response was 0.00 to 1.13 nits against a 2% floor of 1.15 to
    12.65 and every anchor was rejected as unmeasurable.
    """
    return (smoothstep((source_code - 0.07) / 0.03)
            * (1.0 - smoothstep((source_code - fade_start) / fade_span)))


# Envelope for the cLUT corridor probes. Reaches zero near source 0.79, which
# keeps codes 460 through 716 inside the measurable band while still dying out
# before the shoulder plateau where no probe can produce a response.
MHC2_CLUT_PROBE_FADE_START = 0.72
MHC2_CLUT_PROBE_FADE_SPAN = 0.07
# MHC2 mid-band envelope. Starts fading at 0.58 so it is gone by source 0.65,
# code 665. That leaves a gap before the peak candidate and final peak
# feedback stages own the region near code 763. Reusing the cLUT fade, which
# reaches source 0.79, let the two mechanisms fight and peak-white went from
# 0.362 to 1.475 dE ITP.
MHC2_MIDBAND_PROBE_FADE_START = 0.58
MHC2_MIDBAND_PROBE_FADE_SPAN = 0.07


def mhc2_profile_with_curve_probe(profile, channel, peak_delta=0.01,
                                  shadow_delta=MHC2_CURVE_FEEDBACK_DELTA):
    """Move one MHC2 curve in the shadow band and highlight shoulder."""
    if (channel not in (0, 1, 2)
            or not math.isfinite(peak_delta) or peak_delta < 0.0
            or not math.isfinite(shadow_delta)
            or abs(shadow_delta) <= 1e-9):
        fail("MHC2 final feedback probe is invalid")
    tags = dict(read_icc_tags(profile))
    payload = tags.get(b"MHC2")
    if not payload or len(payload) < 84 or payload[:4] != b"MHC2":
        fail("MHC2 final feedback probe requires an MHC2 profile")
    entries = struct.unpack(">I", payload[8:12])[0]
    offsets = struct.unpack(">IIII", payload[20:36])[1:]
    curves = []
    for offset in offsets:
        if (entries < 2 or offset < 36 or
                offset + 8 + entries * 4 > len(payload) or
                payload[offset:offset + 4] != b"sf32"):
            fail("MHC2 final feedback probe curve is invalid")
        curves.append([
            read_s15fixed16(payload, offset + 8 + index * 4)
            for index in range(entries)
        ])
    matrix_offset = struct.unpack_from(">I", payload, 20)[0]
    matrix = [
        [read_s15fixed16(payload, matrix_offset + row * 16 + column * 4)
         for column in range(3)]
        for row in range(3)
    ]
    wire = mhc2_wire_matrix("windows-hdr")
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    gain = neutral_gains[channel]
    if gain <= 1e-6:
        fail("MHC2 final feedback probe has an invalid neutral response")
    for index, old in enumerate(curves[channel]):
        position = index / float(entries - 1)
        source_code = nits_to_pq(pq_to_nits(position) / gain)
        shadow_weight = mhc2_shadow_probe_weight(
            source_code, MHC2_MIDBAND_PROBE_FADE_START,
            MHC2_MIDBAND_PROBE_FADE_SPAN)
        peak_weight = smoothstep((source_code - 0.70) / 0.05)
        curves[channel][index] = max(0.0, min(1.0,
            old + shadow_delta * shadow_weight
            + peak_delta * peak_weight))
    curves[channel] = isotonic_curve(curves[channel])
    curves[channel][0] = 0.0
    return rebuild_icc(profile, {
        b"MHC2": mhc2_with_adjustment_luts(payload, curves)
    })


def b2a_profile_with_curve_probe(profile, mhc2, channel,
                                 delta=MHC2_CURVE_FEEDBACK_DELTA):
    """Move one cLUT neutral-corridor output for response probing."""
    if (channel not in (0, 1, 2) or not math.isfinite(delta)
            or abs(delta) <= 1e-9):
        fail("cLUT final feedback probe is invalid")
    matrix_offset = struct.unpack_from(">I", mhc2, 20)[0]
    matrix = [
        [read_s15fixed16(mhc2, matrix_offset + row * 16 + column * 4)
         for column in range(3)]
        for row in range(3)
    ]
    wire = mhc2_wire_matrix("windows-hdr")
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(matrix, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    reference_luts = windows_hdr_mhc2_luts_from_final_b2a(profile, mhc2)
    corrected_luts = [list(curve) for curve in reference_luts]
    entries = len(corrected_luts[channel])
    gain = neutral_gains[channel]
    if gain <= 1e-6:
        fail("cLUT final feedback probe has an invalid neutral response")
    for index, old in enumerate(corrected_luts[channel]):
        curve_input = index / float(entries - 1)
        source_code = nits_to_pq(pq_to_nits(curve_input) / gain)
        corrected_luts[channel][index] = max(0.0, min(1.0,
            old + delta * mhc2_shadow_probe_weight(
                source_code, MHC2_CLUT_PROBE_FADE_START,
                MHC2_CLUT_PROBE_FADE_SPAN)))
    corrected_luts[channel] = isotonic_curve(corrected_luts[channel])
    corrected_luts[channel][0] = 0.0
    # The corridor rewrite has to span the same range as the envelope above,
    # otherwise the widened probe is discarded when the table is written.
    return windows_hdr_b2a_with_shadow_luts(
        profile, reference_luts, corrected_luts, neutral_gains,
        source_limit=1.0)


def reshape_hdr_b2a_for_pq(profile, white_y, incorporated_calibration=None, grid_size=65):
    """Give a KDE HDR B2A table a PQ-domain shaper and neutral corridor.

    Argyll's inverse display table is sampled in linear PCS XYZ. Even a 45^3
    cLUT then places both 5% and 10% PQ inside its first cell, so the OLED toe
    cannot be represented accurately. Reparameterize the table through PQ
    input shapers, resample the original chromatic transform, and reserve the
    one-cell neutral corridor for the calibration stage. With VCGT, that
    corridor stays in source PQ and KWin applies the separate curves. When
    calibration is included without VCGT, keep the neutral cLUT in its
    virtual-device domain and put the calibration in the high-resolution B2A
    output shapers. This preserves sharp HDR rolloffs that a 3D grid cannot.
    """
    d50 = (0.9642, 1.0, 0.8249)
    xyz_to_mft = 65536.0 / (2.0 * 65535.0)
    # KWin's HDR ICC path accepts the full mft2 range through its direct parser.
    # Stay within LittleCMS' signed 16-bit stage limit while retaining enough
    # linear-PCS resolution to distinguish 5% PQ near black.
    new_input_entries = 32767
    new_output_entries = 4096
    replacements = {}
    changed = False
    for signature, payload in read_icc_tags(profile):
        if signature not in (b"B2A0", b"B2A1") or signature in replacements:
            continue
        if len(payload) < 52 or payload[:4] != b"mft2":
            continue
        input_channels, output_channels, source_grid = payload[8], payload[9], payload[10]
        # Keep 65 as the accuracy-oriented default. The neutral corridor below
        # is expressed as a fraction of the cube axis, not as a fixed count of
        # cells: two cells in 65^3 cover the same chromatic distance as one in
        # 33^3. A fixed two-cell corridor made the 33^3 option twice as wide
        # and pulled legitimate near-neutral colours onto the grey axis.
        grid = max(source_grid, grid_size)
        input_entries, output_entries = struct.unpack(">HH", payload[48:52])
        if input_channels != 3 or output_channels != 3 or source_grid < 2 or input_entries < 2 or output_entries < 2:
            continue
        input_start = 52
        clut_start = input_start + input_channels * input_entries * 2
        clut_values = source_grid ** input_channels * output_channels
        output_start = clut_start + clut_values * 2
        required = output_start + output_channels * output_entries * 2
        if required > len(payload):
            fail("ICC B2A table is truncated")
        matrix = [value / 65536.0 for value in struct.unpack_from(">9i", payload, 12)]
        identity = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        if any(abs(matrix[index] - identity[index]) > 1e-5 for index in range(9)):
            fail("KDE HDR PQ shaping requires an identity B2A matrix")
        input_tables = []
        output_tables = []
        for channel in range(3):
            offset = input_start + channel * input_entries * 2
            input_tables.append(_np_mft2_tables(payload, offset, input_entries))
            offset = output_start + channel * output_entries * 2
            output_tables.append(_np_mft2_tables(payload, offset, output_entries))
        if any(bool(np.any(table[:-1] > table[1:]))
               for table in input_tables + output_tables):
            fail("ICC B2A PQ shaping requires monotonic shaper tables")
        old_clut = _np_mft2_tables(payload, clut_start, clut_values)

        updated = bytearray(payload[:48])
        updated[10] = grid
        updated.extend(struct.pack(">HH", new_input_entries, new_output_entries))
        new_input_tables = []
        shaper_index = np.arange(new_input_entries, dtype=np.float64)
        for channel in range(3):
            encoded_xyz = shaper_index / float(new_input_entries - 1)
            pcs = encoded_xyz / xyz_to_mft
            relative = np.maximum(0.0, pcs / d50[channel])
            pq_value = _np_nits_to_pq(relative * white_y)
            quantized_table = np.clip(np.rint(pq_value * 65535.0),
                                      0.0, 65535.0).astype(np.int64)

            # Linear PCS has less than one full mft2 input-table interval at
            # 5% PQ on a bright HDR display. Sampling the analytic shaper only
            # at the fixed table nodes then gives X, Y and Z different PQ
            # errors, which becomes a visible RGB-balance error after the
            # output calibration. Pin the piecewise-linear table to the exact
            # 5% mapping. This changes no target response; it removes the
            # interpolation error at the first normally measurable HDR grey.
            shadow_anchor = 0.05
            anchor_encoded_xyz = (d50[channel]
                                  * pq_to_nits(shadow_anchor) / white_y
                                  * xyz_to_mft)
            anchor_position = anchor_encoded_xyz * (new_input_entries - 1)
            anchor_low = int(anchor_position)
            anchor_fraction = anchor_position - anchor_low
            if (anchor_low >= 0 and anchor_low + 2 < new_input_entries
                    and anchor_fraction > 1e-9):
                low_value = quantized_table[anchor_low] / 65535.0
                needed = ((shadow_anchor
                           - low_value * (1.0 - anchor_fraction))
                          / anchor_fraction)
                lower = quantized_table[anchor_low] / 65535.0
                upper = quantized_table[anchor_low + 2] / 65535.0
                if lower <= needed <= upper:
                    quantized_table[anchor_low + 1] = max(
                        0, min(65535, int(round(float(needed) * 65535.0))))
            updated.extend(quantized_table.astype(">u2").tobytes())
            new_input_tables.append(quantized_table / 65535.0)

        denominator = float(grid - 1)
        # Preserve the same normalized corridor width at each supported cube
        # density. This intentionally evaluates to one cell at 33^3 and two
        # cells at 65^3.
        neutral_corridor_cells = max(
            1, int(round(2.0 * denominator / 64.0)))
        # The lattice is walked in chunks: a 65-cube is 274,625 nodes and the
        # appliance cannot afford whole-cube float64 temporaries. Chunking is
        # elementwise, so it changes no value.
        node_count = grid ** 3
        for chunk_start in range(0, node_count, _BATCH_CHUNK):
            axes = _np_lattice_axes(grid, chunk_start,
                                    min(node_count, chunk_start + _BATCH_CHUNK))
            pq_coordinates = np.stack([axis / denominator for axis in axes],
                                      axis=1)
            # A uniform XYZ input table has fewer than two samples below 5%
            # PQ even at the 32767-entry limit accepted by KWin.  Its linear
            # interpolation therefore produces different PQ coordinates for
            # D50 X, Y and Z.  Recover the PCS represented by each sampled
            # coordinate and normalise it by the corresponding D50 component.
            # A true neutral reconstructs to three equal PQ values, while a
            # nearby chromatic coordinate retains its channel separation.
            # Collapsing these estimates to one median value would fix gray at
            # the cost of desaturating every color inside the corridor.
            pcs = np.empty(pq_coordinates.shape, dtype=np.float64)
            for channel in range(3):
                encoded_xyz = _np_invert_table(new_input_tables[channel],
                                               pq_coordinates[:, channel])
                relative = np.maximum(0.0,
                                      encoded_xyz / xyz_to_mft / d50[channel])
                corrected = _np_nits_to_pq(relative * white_y)
                pcs[:, channel] = (d50[channel] * _np_pq_to_nits(corrected)
                                   / white_y)
            coordinates = np.empty(pq_coordinates.shape, dtype=np.float64)
            for channel in range(3):
                coordinates[:, channel] = _np_sample_table(
                    input_tables[channel], pcs[:, channel] * xyz_to_mft)
            clut_result = _np_clut_trilinear(old_clut, source_grid, coordinates)
            original = np.empty(pq_coordinates.shape, dtype=np.float64)
            for channel in range(3):
                original[:, channel] = _np_sample_table(
                    output_tables[channel], clut_result[:, channel])
            spread = (np.maximum(np.maximum(axes[0], axes[1]), axes[2])
                      - np.minimum(np.minimum(axes[0], axes[1]), axes[2]))
            # Inside the corridor, keep the axis linear. Trilinear
            # interpolation then reproduces an on-axis request exactly,
            # leaving the dense output shapers as the one owner of neutral
            # calibration. Storing the median at every nearby node biases the
            # interpolation between diagonal nodes; a two-thousandth code bias
            # at 20% PQ is enough to create a large OLED shadow colour error.
            result = np.where(
                (spread <= neutral_corridor_cells)[:, None],
                pq_coordinates,
                np.where((spread == neutral_corridor_cells + 1)[:, None],
                         (pq_coordinates + original) * 0.5,
                         original))
            updated.extend(_np_u16_bytes(result))
        curve_position = (np.arange(new_output_entries, dtype=np.float64)
                          / float(new_output_entries - 1))
        for channel in range(3):
            if incorporated_calibration is not None:
                output_curve = _np_sample_table(
                    np.asarray(incorporated_calibration[channel],
                               dtype=np.float64), curve_position)
            else:
                output_curve = curve_position
            updated.extend(_np_u16_bytes(output_curve))
        replacements[signature] = bytes(updated)
        changed = True
    if not changed:
        fail("KDE HDR calibrated profiles require an mft2 B2A transform")
    return rebuild_icc(profile, replacements)


def _np_model_error(forward, device, target):
    """Squared forward-model residual for a whole batch of device triples."""
    difference = forward(device) - target
    return (_pow2(difference[:, 0]) + _pow2(difference[:, 1])
            + _pow2(difference[:, 2]))


def _np_refine_newton(forward, target, initial):
    """Damped Newton solve for a batch of cLUT nodes against a forward model.

    This is the scalar per-node solver run as a masked batch: every active node
    performs the same arithmetic in the same order it would alone -- one
    forward evaluation, three probe evaluations for the central Jacobian, then
    a halving line search that stops at the first strict improvement. A node
    that converges, fails its Jacobian inversion or fails the line search is
    dropped from the active set with its device value frozen, so the remaining
    iterations neither touch it nor spend evaluations on it.
    """
    device = np.array(initial, dtype=np.float64, copy=True)
    previous_error = _np_model_error(forward, device, target)
    active = np.ones(device.shape[0], dtype=bool)
    for _iteration in range(14):
        index = np.nonzero(active)[0]
        if index.size == 0:
            break
        node_device = device[index]
        node_target = target[index]
        node_error = previous_error[index]
        actual = forward(node_device)
        residual = node_target - actual
        step = 0.002
        columns = []
        for axis in range(3):
            probe = node_device.copy()
            position = node_device[:, axis]
            probe[:, axis] = np.where(position < 0.998,
                                      np.minimum(1.0, position + step),
                                      np.maximum(0.0, position - step))
            measured = forward(probe)
            # Never zero: a node below 0.998 cannot clamp at 1.0 after a
            # 0.002 step, and one at or above it always has room to go down.
            denominator = (probe[:, axis] - position)[:, None]
            columns.append((measured - actual) / denominator)
        entries = []
        for row in range(3):
            for column in range(3):
                entries.append(columns[column][:, row])
        inverse, valid = _np_mat_inv3(entries)
        delta = np.empty(node_device.shape, dtype=np.float64)
        for row in range(3):
            delta[:, row] = (inverse[row * 3] * residual[:, 0]
                             + inverse[row * 3 + 1] * residual[:, 1]
                             + inverse[row * 3 + 2] * residual[:, 2])
        # A singular Jacobian is the scalar solver's ValueError: that node
        # stops here with the device value it already had.
        searching = valid.copy()
        accepted = np.zeros(index.size, dtype=bool)
        accepted_scale = np.zeros(index.size, dtype=np.float64)
        scale = 1.0
        while scale >= 1.0 / 128.0:
            live = np.nonzero(searching)[0]
            if live.size == 0:
                break
            probe = np.clip(node_device[live] + scale * delta[live], 0.0, 1.0)
            current_error = _np_model_error(forward, probe, node_target[live])
            improved = current_error < node_error[live]
            if np.any(improved):
                chosen = live[improved]
                node_device[chosen] = probe[improved]
                node_error[chosen] = current_error[improved]
                accepted[chosen] = True
                accepted_scale[chosen] = scale
                searching[chosen] = False
            scale /= 2.0
        device[index] = node_device
        previous_error[index] = node_error
        moved = np.max(np.abs(accepted_scale[:, None] * delta), axis=1)
        active[index] = valid & accepted & (moved >= 0.000002)
    return device


def refine_hdr_b2a_from_forward_model(profile, forward_profile, white_y):
    """Numerically invert the measured A2B model into the PQ B2A cLUT.

    Argyll's independently fitted B2A can diverge from its better-constrained
    forward model on non-additive HDR displays. Solve chromatic cLUT nodes
    against the raw High-quality A2B while retaining the PQ neutral corridor,
    output shapers and unreachable plateau region from the reshaped profile.
    Only the original characterization model is consumed.
    """
    forward = mft2_a2b_evaluator(forward_profile)
    d50 = (0.9642, 1.0, 0.8249)
    replacements = {}
    refined_payloads = {}
    changed = False

    for signature, payload in read_icc_tags(profile):
        if signature not in (b"B2A0", b"B2A1") or signature in replacements:
            continue
        # Perceptual and relative-colorimetric B2A tags are normally linked
        # copies of the same mft2 payload. A 65-cube numerical inversion is
        # expensive, so calculate identical transforms once and reuse the
        # result rather than repeating every forward-model solve.
        if payload in refined_payloads:
            replacements[signature] = refined_payloads[payload]
            changed = True
            continue
        if len(payload) < 52 or payload[:4] != b"mft2":
            continue
        input_channels, output_channels, grid = payload[8], payload[9], payload[10]
        input_entries, output_entries = struct.unpack_from(">HH", payload, 48)
        if input_channels != 3 or output_channels != 3 or grid < 2:
            continue
        input_start = 52
        clut_start = input_start + input_channels * input_entries * 2
        clut_values = grid ** input_channels * output_channels
        output_start = clut_start + clut_values * 2
        required = output_start + output_channels * output_entries * 2
        if required > len(payload):
            fail("ICC B2A forward-model refinement table is truncated")

        input_tables = []
        output_tables = []
        for channel in range(3):
            offset = input_start + channel * input_entries * 2
            input_tables.append(_np_mft2_tables(payload, offset, input_entries))
            offset = output_start + channel * output_entries * 2
            output_tables.append(_np_mft2_tables(payload, offset, output_entries))
        original_clut = _np_mft2_tables(payload, clut_start, clut_values)
        node_clut = original_clut.reshape(grid ** 3, 3)

        denominator = float(grid - 1)
        node_count = grid ** 3
        updated = bytearray(payload[:clut_start])
        for chunk_start in range(0, node_count, _BATCH_CHUNK):
            chunk_stop = min(node_count, chunk_start + _BATCH_CHUNK)
            axes = _np_lattice_axes(grid, chunk_start, chunk_stop)
            pq_coordinates = np.stack([axis / denominator for axis in axes],
                                      axis=1)
            target = np.empty(pq_coordinates.shape, dtype=np.float64)
            for channel in range(3):
                target[:, channel] = (
                    d50[channel] * _np_pq_to_nits(pq_coordinates[:, channel])
                    / white_y)
            # base_device: the reshaped table's own inverse, used as the Newton
            # seed. The 65535/32768 divisor is the mft2 PCS encoding and is
            # deliberately not the xyz_to_mft multiplier used elsewhere -- the
            # two constants differ in their last bit.
            coordinates = np.empty(target.shape, dtype=np.float64)
            for channel in range(3):
                coordinates[:, channel] = _np_sample_table(
                    input_tables[channel],
                    target[:, channel] / (65535.0 / 32768.0))
            pre_clut = _np_clut_trilinear(original_clut, grid, coordinates)
            initial = np.empty(target.shape, dtype=np.float64)
            for channel in range(3):
                initial[:, channel] = _np_sample_table(output_tables[channel],
                                                       pre_clut[:, channel])
            spread = (np.maximum(np.maximum(axes[0], axes[1]), axes[2])
                      - np.minimum(np.minimum(axes[0], axes[1]), axes[2]))
            original = node_clut[chunk_start:chunk_stop]
            solve = ~((spread <= 2) | (pq_coordinates.max(axis=1) > 0.82))
            pre_output = original.copy()
            if np.any(solve):
                device = _np_refine_newton(forward, target[solve],
                                           initial[solve])
                solved = np.empty(device.shape, dtype=np.float64)
                for channel in range(3):
                    solved[:, channel] = _np_calibration_to_profile_value(
                        output_tables[channel], device[:, channel])
                pre_output[solve] = solved
            blend = (spread == 3) | (spread == 4)
            if np.any(blend):
                # Run this arithmetic even where pre_output is still the
                # original: o*(1-w) + o*w is not guaranteed to be bitwise o.
                weight = ((spread[blend] - 2) / 3.0)[:, None]
                pre_output[blend] = (original[blend] * (1.0 - weight)
                                     + pre_output[blend] * weight)
            updated.extend(_np_u16_bytes(pre_output))
        updated.extend(payload[output_start:])
        replacements[signature] = bytes(updated)
        refined_payloads[payload] = replacements[signature]
        changed = True

    if not changed:
        fail("KDE HDR forward-model refinement requires an mft2 B2A transform")
    return rebuild_icc(profile, replacements)


def read_s15fixed16(data, offset):
    if offset < 0 or offset + 4 > len(data):
        fail("MHC2 fixed-point value is outside the tag")
    return struct.unpack(">i", data[offset:offset + 4])[0] / 65536.0


def validate_mhc2_profile(profile, expected_payload, physical, wire, expected_metadata_white,
                          profile_type, expect_calibration=True):
    tags = {}
    for signature, payload in read_icc_tags(profile):
        if signature in tags:
            fail("ICC profile contains a duplicate {} tag".format(signature.decode("ascii", "replace")))
        tags[signature] = payload
    required = (b"MHC2", b"lumi", b"wtpt", b"rXYZ", b"gXYZ", b"bXYZ")
    missing = [signature.decode("ascii") for signature in required if signature not in tags]
    if missing:
        fail("Windows profile is missing required tags: {}".format(", ".join(missing)))
    if profile[12:16] != b"mntr" or profile[16:20] != b"RGB " or profile[20:24] != b"XYZ ":
        fail("Windows profile is not an RGB display profile with XYZ PCS")
    mhc2 = tags[b"MHC2"]
    if mhc2 != expected_payload:
        fail("Saved MHC2 data does not match the generated correction")
    if len(mhc2) < 84 or mhc2[:4] != b"MHC2":
        fail("MHC2 tag header is invalid")
    entries = struct.unpack(">I", mhc2[8:12])[0]
    matrix_offset, red_offset, green_offset, blue_offset = struct.unpack(">IIII", mhc2[20:36])
    if entries < 2 or entries > 4096 or matrix_offset + 48 > len(mhc2):
        fail("MHC2 matrix or curve count is invalid")
    matrix = []
    for row_index in range(3):
        row_offset = matrix_offset + row_index * 16
        row = [read_s15fixed16(mhc2, row_offset + column * 4) for column in range(3)]
        if abs(read_s15fixed16(mhc2, row_offset + 12)) > 1.0 / 65536.0:
            fail("MHC2 matrix affine column must be zero")
        matrix.append(row)
    curves = []
    for offset in (red_offset, green_offset, blue_offset):
        if offset < 36 or offset + 8 + entries * 4 > len(mhc2) or mhc2[offset:offset + 4] != b"sf32":
            fail("MHC2 curve offset or signature is invalid")
        curves.append([read_s15fixed16(mhc2, offset + 8 + index * 4) for index in range(entries)])
    if any(curve[index] > curve[index + 1] + 1.5 / 65536.0
           for curve in curves for index in range(entries - 1)):
        fail("MHC2 correction curve is not monotonic")
    if any(curve[index + 1] - curve[index] > 0.125
           for curve in curves for index in range(entries - 1)):
        fail("MHC2 correction curve contains an implausible single-step jump")
    if expect_calibration:
        residual = mat_mul(physical, mat_mul(mat_inv(wire), matrix))
        # SDR white-point correction and HDR endpoint protection may use a
        # uniform matrix scale. In either case the valid physical round trip
        # is a positive scalar identity, not identity itself.
        matrix_scale = (sum(residual[index][index] for index in range(3)) / 3.0
                        if profile_type in ("windows-sdr", "windows-hdr") else 1.0)
        if matrix_scale <= 0.0 or matrix_scale > 1.002:
            fail("MHC2 correction matrix has an invalid round-trip scale")
        maximum_residual = max(
            abs(residual[row][column]
                - (matrix_scale if row == column else 0.0))
            for row in range(3) for column in range(3)
        )
        if maximum_residual > 0.002:
            fail("MHC2 correction matrix failed its round-trip identity check")
    else:
        matrix_scale = 1.0
        maximum_residual = max(abs(matrix[row][column] - (1.0 if row == column else 0.0))
                               for row in range(3) for column in range(3))
        if maximum_residual > 1.5 / 65536.0:
            fail("No-calibration MHC2 matrix is not identity")
    minimum_luminance = read_s15fixed16(mhc2, 12)
    peak_luminance = read_s15fixed16(mhc2, 16)
    lumi = tags[b"lumi"]
    if len(lumi) < 20 or lumi[:4] != b"XYZ ":
        fail("ICC metadata white luminance tag is invalid")
    metadata_white_luminance = read_s15fixed16(lumi, 12)
    if abs(metadata_white_luminance - expected_metadata_white) > max(0.02, expected_metadata_white / 10000.0):
        fail("ICC metadata white luminance does not match its measurement")
    curves_identity = all(
        abs(value - index / float(entries - 1)) <= 1.5 / 65536.0
        for curve in curves for index, value in enumerate(curve)
    )
    if not expect_calibration and not curves_identity:
        fail("No-calibration MHC2 curves are not identity")
    return {
        "status": "passed",
        "tag_version": "MHC2",
        "matrix_round_trip_max_error": round(maximum_residual, 7),
        "matrix_scale": round(matrix_scale, 7),
        "calibration": "measured correction" if expect_calibration else "none",
        "curve_entries": entries,
        "curves": "identity" if curves_identity else "measured correction",
        "minimum_luminance_nits": round(minimum_luminance, 5),
        "peak_luminance_nits": round(peak_luminance, 3),
        "metadata_white_luminance_nits": round(metadata_white_luminance, 3),
    }


def safe_basename(name):
    cleaned = SAFE_NAME.sub("_", str(name)).strip(" ._-").replace(" ", "_")
    if not cleaned:
        cleaned = "PGenerator+ display profile"
    return cleaned[:80]


def unique_profile_filename(output_dir, filename):
    """Choose a numbered filename instead of replacing profile history."""
    candidate = filename
    stem, extension = os.path.splitext(filename)
    sequence = 1
    while os.path.exists(os.path.join(output_dir, candidate)):
        candidate = "{}_({}){}".format(stem, sequence, extension)
        sequence += 1
    return candidate


# Offload directory shared with the WebUI. The builder writes a job here, the
# Companion collects it through the existing poll channel, and the finished
# profile is written back by the result endpoint.
COMPANION_BUILD_DIR = "/var/lib/PGenerator/icc-companion/build"
COMPANION_BUILD_POLL_SECONDS = 2.0


# The Companion polls every few seconds whenever it is running, whether or not
# it is the selected patch source, so a generous window still catches a missed
# poll or two without waiting on a Companion that has gone.
COMPANION_SEEN_SECONDS = 120


def read_companion_state(state_path):
    """Current companion.json contents, or an empty dict if unreadable."""
    try:
        with io.open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        return state if isinstance(state, dict) else {}
    except (OSError, IOError, ValueError):
        return {}


def companion_seen_recently(state):
    if not state.get("connected"):
        return False
    try:
        seen = float(state.get("seen", 0))
    except (TypeError, ValueError):
        return False
    # Tolerate a clock that has stepped backwards rather than refusing forever.
    return abs(time.time() - seen) <= COMPANION_SEEN_SECONDS


def companion_build_offload(ti3, command, temporary_output, timeout_seconds):
    """Ask a connected Patch Companion to run colprof, returning True on success.

    colprof is single-threaded and the Pi 4 needs roughly ten minutes for a
    high-quality cLUT fit that an x86 desktop finishes in under a minute, so
    the fit is handed to the Companion when one is connected. Only colprof
    moves: the characterization, the MHC2/vcgt derivation and the ICC rebuild
    all stay here, so there is one implementation of the calibration logic
    regardless of where the fit ran.

    Recoverable failures return False and leave the caller to run colprof
    locally. A Companion that consumes the complete deadline raises instead,
    because repeating the same multi-hour fit on the Pi would only cause the
    outer request to time out later.
    """
    if os.environ.get("PGEN_ICC_NO_OFFLOAD"):
        return False
    try:
        state_path = os.path.join(COMPANION_BUILD_DIR, "companion.json")
        if not os.path.isfile(state_path):
            return False
        with io.open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        if not state.get("connected"):
            return False
        # "connected" is written by the poll handler and is never cleared, so a
        # Companion that was closed leaves it true. Without a freshness check
        # the wait below would sit out the whole colprof timeout before falling
        # back, turning a ten-minute local fit into a twenty-five minute one.
        if not companion_seen_recently(state):
            return False
        # Refuse to offload to a different ArgyllCMS than the one here: the same
        # measurements fitted by a different version produce a different profile,
        # and the user would have no way to tell which built theirs.
        local_version = argyll_version()
        remote_version = str(state.get("argyll_version", ""))
        if not local_version or not remote_version or local_version != remote_version:
            return False
        if not os.path.isdir(COMPANION_BUILD_DIR):
            return False
        job_id = "%d-%d" % (int(time.time()), os.getpid())
        result_path = os.path.join(COMPANION_BUILD_DIR, "result.icc")
        error_path = os.path.join(COMPANION_BUILD_DIR, "error.txt")
        claim_path = os.path.join(COMPANION_BUILD_DIR, "claim.json")
        for stale in (result_path, error_path, claim_path):
            if os.path.exists(stale):
                os.remove(stale)
        # Hand over only the arguments that describe the fit. The Companion
        # appends its own "-O <output> <basename>" against its own working
        # directory, so -O, the output path and the input basename all have to
        # go: leaving a bare -O behind makes colprof swallow the basename as an
        # output name and it then exits without ever writing a profile.
        base_name = temporary_output[:-4] if temporary_output.endswith(".icc") else temporary_output
        flags = []
        drop_value = False
        for item in command[1:]:
            if drop_value:
                drop_value = False
                continue
            if item == "-O":
                drop_value = True
                continue
            if item in (temporary_output, base_name):
                continue
            flags.append(item)
        # The characterization goes in its own file rather than inline in the
        # job: the Companion's poll response buffer is 32 KB and a 1000-patch
        # .ti3 is around 76 KB, so inlining would fail on exactly the large
        # profiles that most deserve offloading. The Companion fetches it.
        ti3_path = os.path.join(COMPANION_BUILD_DIR, "job.ti3")
        write_text_atomic(ti3_path, ti3)
        job = {
            "job": job_id,
            "operation": "colprof",
            "argyll_version": local_version,
            "timeout": timeout_seconds,
            "flags": flags,
            "ti3_bytes": len(ti3),
        }
        write_json_atomic(os.path.join(COMPANION_BUILD_DIR, "job.json"), job)
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if os.path.isfile(result_path) and os.path.getsize(result_path) > 128:
                shutil.copyfile(result_path, temporary_output)
                os.remove(result_path)
                return True
            if os.path.isfile(error_path):
                os.remove(error_path)
                return False
            # The Companion runs colprof synchronously and cannot poll during
            # the fit. Once it has fetched the TI3, claim.json proves that this
            # exact job was accepted and the build deadline becomes its
            # liveness bound. Poll freshness still rejects an unclaimed job.
            if not companion_seen_recently(read_companion_state(state_path)):
                claim = read_companion_state(claim_path)
                if str(claim.get("job", "")) != job_id:
                    return False
            time.sleep(COMPANION_BUILD_POLL_SECONDS)
        raise CompanionBuildTimeout(
            "Patch Companion profile creation timed out after {} seconds".format(timeout_seconds))
    except CompanionBuildTimeout:
        raise
    except (OSError, IOError, ValueError, KeyError):
        return False
    finally:
        for leftover in ("job.json", "job.ti3", "claim.json"):
            try:
                os.remove(os.path.join(COMPANION_BUILD_DIR, leftover))
            except OSError:
                pass


def companion_targen_offload(command, output_path, timeout_seconds,
                             precondition_path=None):
    """Run targen on a connected compatible Patch Companion.

    Chart optimization is CPU-only and can be slower than the entire meter
    pass on a Pi 4. The same Companion that runs colprof can run targen too,
    provided it explicitly advertises that capability. Older Companions keep
    using the local path instead of receiving a job type they do not know.
    """
    if os.environ.get("PGEN_ICC_NO_OFFLOAD"):
        return False
    input_path = os.path.join(COMPANION_BUILD_DIR, "job.input")
    try:
        state_path = os.path.join(COMPANION_BUILD_DIR, "companion.json")
        state = read_companion_state(state_path)
        if not companion_seen_recently(state) or not state.get("targen"):
            return False
        local_version = argyll_tool_version(
            os.environ.get("PGEN_TARGEN", "/usr/bin/targen"))
        remote_version = str(state.get("argyll_version", ""))
        if not local_version or local_version != remote_version:
            return False
        if not os.path.isdir(COMPANION_BUILD_DIR):
            return False

        job_id = "%d-%d" % (int(time.time()), os.getpid())
        result_path = os.path.join(COMPANION_BUILD_DIR, "result.icc")
        error_path = os.path.join(COMPANION_BUILD_DIR, "error.txt")
        claim_path = os.path.join(COMPANION_BUILD_DIR, "claim.json")
        for stale in (result_path, error_path, claim_path, input_path):
            if os.path.exists(stale):
                os.remove(stale)

        # Drop the output basename and replace the Pi-only preconditioning
        # path with a staged binary input the Companion names locally.
        flags = []
        index = 1
        has_precondition = False
        while index < len(command):
            item = command[index]
            if index == len(command) - 1:
                index += 1
                continue
            if item == "-c" and index + 1 < len(command):
                has_precondition = True
                index += 2
                continue
            flags.append(item)
            index += 1
        if has_precondition:
            if not precondition_path or not os.path.isfile(precondition_path):
                return False
            temporary_input = input_path + ".tmp"
            shutil.copyfile(precondition_path, temporary_input)
            os.rename(temporary_input, input_path)
        else:
            # Fetching this file is also the job claim. An empty input is
            # intentional for an ordinary un-preconditioned chart.
            with open(input_path + ".tmp", "wb") as handle:
                handle.write(b"")
            os.rename(input_path + ".tmp", input_path)

        job = {
            "job": job_id,
            "operation": "targen",
            "argyll_version": local_version,
            "timeout": timeout_seconds,
            "flags": flags,
            "input_bytes": os.path.getsize(input_path),
            "precondition": has_precondition,
        }
        write_json_atomic(os.path.join(COMPANION_BUILD_DIR, "job.json"), job)
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if os.path.isfile(result_path) and os.path.getsize(result_path) > 32:
                shutil.copyfile(result_path, output_path)
                os.remove(result_path)
                return True
            if os.path.isfile(error_path):
                try:
                    with io.open(error_path, "r", encoding="utf-8") as handle:
                        reason = handle.read(240).strip()
                except (OSError, IOError):
                    reason = "unknown Companion error"
                try:
                    os.remove(error_path)
                except OSError:
                    pass
                # An error file can only be written after this exact job was
                # claimed. Do not disguise a desktop failure by repeating the
                # expensive randomized optimization on the Pi and reporting
                # whatever progress line the fallback happened to print last.
                raise CompanionBuildFailed(
                    "Patch Companion chart generation failed: {}".format(
                        reason or "unknown Companion error"))
            if not companion_seen_recently(read_companion_state(state_path)):
                claim = read_companion_state(claim_path)
                if str(claim.get("job", "")) != job_id:
                    return False
            time.sleep(COMPANION_BUILD_POLL_SECONDS)
        raise CompanionBuildTimeout(
            "Patch Companion chart generation timed out after {} seconds".format(
                timeout_seconds))
    except CompanionBuildTimeout:
        raise
    except CompanionBuildFailed:
        raise
    except (OSError, IOError, ValueError, KeyError):
        return False
    finally:
        for leftover in ("job.json", "job.input", "claim.json"):
            try:
                os.remove(os.path.join(COMPANION_BUILD_DIR, leftover))
            except OSError:
                pass


def argyll_tool_version(tool):
    """Version string reported by one local ArgyllCMS command."""
    try:
        process = subprocess.Popen([tool], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, universal_newlines=True)
        text = process.communicate()[0] or ""
    except (OSError, ValueError):
        return ""
    match = re.search(r"Version\s+([0-9]+(?:\.[0-9]+)+)", text)
    return match.group(1) if match else ""


def argyll_version():
    """Version string of the local colprof, used to gate the offload."""
    return argyll_tool_version(
        os.environ.get("PGEN_COLPROF", "/usr/bin/colprof"))


def colprof_supports_icc44(colprof):
    """Return whether colprof provides the PGenerator+ ICC v4.4/CICP path."""
    try:
        process = subprocess.Popen([colprof, "-?"], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, universal_newlines=True)
        text = process.communicate()[0] or ""
    except (OSError, ValueError):
        return False
    return "Create ICC v4.4 RGB display profile with CICP" in text


def run_colprof(payload, ti3, output_path, profile_model, patch_set, icc_version="2.2"):
    colprof = os.environ.get("PGEN_COLPROF", "/usr/bin/colprof")
    if not os.path.isfile(colprof) or not os.access(colprof, os.X_OK):
        fail("The bundled ArgyllCMS colprof executable is unavailable")
    description = profile_description(payload).replace('"', "'")
    temp_dir = tempfile.mkdtemp(prefix="pgen_icc_")
    try:
        base = os.path.join(temp_dir, "profile")
        with io.open(base + ".ti3", "w", encoding="ascii", errors="replace") as handle:
            handle.write(ti3)
        requested_quality = str(payload.get("profile_quality", "")).lower()
        quality = {"low": "l", "medium": "m", "high": "h", "ultra": "u"}.get(requested_quality)
        if quality is None:
            quality = "h" if patch_set == "large" or len(ti3.splitlines()) > 800 else "m"
        algorithm = PROFILE_MODELS[profile_model]["argyll"]
        temporary_output = base + ".icc"
        command = [
            colprof, "-q" + quality, "-a" + algorithm, "-A", "PGenerator+", "-M", PROFILE_TYPES[payload["profile_type"]],
            "-D", description, "-C", "Created from user measurements by PGenerator+", "-O", temporary_output, base,
        ]
        if icc_version == "4.4":
            if not colprof_supports_icc44(colprof):
                fail("ICC v4.4 profile creation requires the bundled ICC v4.4/CICP build of ArgyllCMS")
            command[1:1] = ["-4"]
        if PROFILE_MODELS[profile_model]["family"] == "clut":
            # targen -V controls where the characterization patches are
            # measured. colprof -V separately controls the inverse cLUT grid.
            # Both use Argyll's 1.0 to 4.0 dark-region concentration scale.
            dark = max(0.0, min(1.0, finite_number(
                payload.get("dark_emphasis", 0.2), "dark-region emphasis")))
            command[-3:-3] = ["-V{:.3f}".format(1.0 + dark * 3.0)]
        average_deviation = payload.get("avg_deviation")
        if average_deviation not in (None, ""):
            average_deviation = finite_number(average_deviation, "measurement deviation")
            if average_deviation < 0.0 or average_deviation > 5.0:
                fail("Measurement deviation must be between 0 and 5 percent")
            # The profiling UI has always described this control as colprof
            # -r, but the builder previously discarded it. Put it before the
            # output/input operands so both local and Companion-offloaded fits
            # receive the same explicit noise estimate.
            command[-3:-3] = ["-r", "{:.6g}".format(average_deviation)]
        # cLUT fitting on the Pi is substantially slower than matrix fitting,
        # and scales with both characterization size and requested quality.
        # Ultra is especially expensive: a normal 1000-patch fit computes to
        # more than 100 minutes with this estimate. Do not clamp that healthy
        # fit to the former 40-minute ceiling.
        line_count = len(ti3.splitlines())
        quality_factor = {"l": 0.5, "m": 1.0, "h": 2.0, "u": 4.0}.get(quality, 1.0)
        if PROFILE_MODELS[profile_model]["family"] == "clut":
            # colprof's current cLUT optimizer runs one fit on one CPU thread, and a
            # normal High fit can need more than eight minutes on Pi 4. Floors
            # prevent small but complex data sets from being killed early;
            # the line-count estimate gives large Ultra fits over two hours.
            # The four-hour ceiling is a runaway guard, not an expected time.
            quality_floor = {"l": 900, "m": 1800, "h": 3600, "u": 7200}.get(quality, 1800)
            timeout_seconds = min(14400, max(quality_floor, int(300 + line_count * quality_factor * 2.0)))
        else:
            timeout_seconds = min(900, max(180, int(90 + line_count * quality_factor * 0.5)))
        if companion_build_offload(ti3, command, temporary_output, timeout_seconds):
            os.rename(temporary_output, output_path)
            return
        if os.environ.get("PGEN_ICC_REQUIRE_OFFLOAD"):
            fail("Patch Companion did not claim the required profile build")
        completed = subprocess.Popen(["timeout", str(timeout_seconds)] + command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = completed.communicate()[0]
        if completed.returncode != 0 or not os.path.isfile(temporary_output) or os.path.getsize(temporary_output) <= 0:
            detail = (output or "").strip().splitlines()
            if completed.returncode == 124:
                fail("ArgyllCMS profile creation timed out after {} seconds".format(timeout_seconds))
            fail("ArgyllCMS profile creation failed" + (": " + detail[-1][:240] if detail else ""))
        os.rename(temporary_output, output_path)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def write_text_atomic(path, content):
    temporary = path + ".tmp"
    with io.open(temporary, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.rename(temporary, path)


def write_json_atomic(path, value):
    temporary = path + ".tmp"
    with io.open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"), sort_keys=True)
    os.rename(temporary, path)


def bounded_integer(value, name, minimum, maximum):
    number = int(round(finite_number(value, name)))
    if number < minimum or number > maximum:
        fail("{} must be between {} and {}".format(name, minimum, maximum))
    return number


def parse_ti1_patches(path):
    with io.open(path, "r", encoding="ascii", errors="replace") as handle:
        lines = [line.strip() for line in handle]
    fields = []
    rows = []
    in_format = False
    in_data = False
    for line in lines:
        if line == "BEGIN_DATA_FORMAT":
            in_format = True
            continue
        if line == "END_DATA_FORMAT":
            in_format = False
            continue
        if line == "BEGIN_DATA":
            in_data = True
            continue
        if line == "END_DATA":
            break
        if in_format and line:
            fields.extend(line.split())
        elif in_data and line:
            values = line.split()
            if len(values) >= len(fields):
                rows.append(dict(zip(fields, values)))
    required = ("RGB_R", "RGB_G", "RGB_B")
    if not rows or any(field not in fields for field in required):
        fail("ArgyllCMS targen produced an invalid RGB test chart")
    patches = []
    for index, row in enumerate(rows, 1):
        rgb = [max(0.0, min(1.0, float(row[field]) / 100.0)) for field in required]
        if max(rgb) - min(rgb) < 1e-7:
            level = int(round(rgb[0] * 100.0))
            name = "ICC White" if level == 100 else "ICC Black" if level == 0 else "ICC Grey {}".format(level)
        elif rgb == [1.0, 0.0, 0.0]:
            name = "ICC Red 100"
        elif rgb == [0.0, 1.0, 0.0]:
            name = "ICC Green 100"
        elif rgb == [0.0, 0.0, 1.0]:
            name = "ICC Blue 100"
        else:
            name = "ICC Optimized {}".format(index)
        patches.append({"r": rgb[0], "g": rgb[1], "b": rgb[2], "name": name})
    return patches


def hdr_neutral_jacobian_probes(payload):
    """Return symmetric, same-loading probes for an HDR neutral derivative.

    A generic optimized chart can place its nearest mixed-colour samples far
    from the grey axis. That is enough for a forward cLUT, but it is not enough
    to decide which channel to trim at a particular HDR grey level. Reserve a
    small, deterministic part of HDR cLUT charts for +/- RGB perturbations at
    useful neutral levels. The measurements let the calibration solve the
    display's local behaviour instead of extrapolating isolated primary ramps.
    """
    profile_type = str(payload.get("profile_type", ""))
    profile_model = str(payload.get("profile_model", ""))
    if (profile_type not in ("kde-hdr", "windows-hdr")
            or profile_model not in PROFILE_MODELS
            or PROFILE_MODELS[profile_model]["family"] != "clut"):
        return []
    levels = (5, 10, 15, 20, 25, 30, 35, 40, 50, 60, 70)
    delta = 12
    probes = []
    for percent in levels:
        center = int(round(percent * 1023.0 / 100.0))
        for channel, label in enumerate("RGB"):
            for direction, suffix in ((-1, "-"), (1, "+")):
                codes = [center, center, center]
                codes[channel] = max(0, min(1023, center + direction * delta))
                probes.append({
                    "r": codes[0] / 1023.0,
                    "g": codes[1] / 1023.0,
                    "b": codes[2] / 1023.0,
                    "name": "ICC Neutral Jacobian {:04d} {}{}".format(
                        center, label, suffix),
                })
    return probes


def inject_hdr_neutral_jacobian_probes(patches, payload, total):
    """Replace redundant optimized rows with local HDR balance probes."""
    requested = hdr_neutral_jacobian_probes(payload)
    if not requested:
        return patches
    quantized = lambda patch: tuple(int(round(max(0.0, min(1.0,
        float(patch[channel]))) * 1023.0)) for channel in ("r", "g", "b"))
    existing = {quantized(patch) for patch in patches}
    additions = []
    for probe in requested:
        key = quantized(probe)
        if key not in existing:
            additions.append(probe)
            existing.add(key)
    optimized = [index for index, patch in enumerate(patches)
                 if str(patch.get("name", "")).startswith("ICC Optimized ")]
    # Custom charts can devote every row to explicitly requested ramps. Add
    # only complete six-probe level groups that fit by replacing optimized
    # rows; never increase the user's requested measurement count.
    replace_count = min(len(additions), len(optimized))
    replace_count -= replace_count % 6
    additions = additions[:replace_count]
    if not additions:
        return patches
    remove = set(optimized[-replace_count:])
    result = [patch for index, patch in enumerate(patches) if index not in remove]
    result.extend(additions)
    if len(result) > total:
        result = result[:total]
    return result


def generate_patches(payload, output_dir):
    targen = os.environ.get("PGEN_TARGEN", "/usr/bin/targen")
    if not os.path.isfile(targen) or not os.access(targen, os.X_OK):
        fail("The bundled ArgyllCMS targen executable is unavailable")
    total = bounded_integer(payload.get("patch_count", 425), "patch count", 34, 11106)
    white = bounded_integer(payload.get("white_patches", 4), "white patches", 1, 32)
    black = bounded_integer(payload.get("black_patches", 4), "black patches", 1, 32)
    single = bounded_integer(payload.get("single_channel_steps", 17), "single-channel steps", 0, 129)
    gray = bounded_integer(payload.get("gray_steps", 49), "grayscale steps", 2, 257)
    neutral = max(0.0, min(1.0, finite_number(payload.get("neutral_emphasis", 0.5), "neutral-axis emphasis")))
    dark = max(0.0, min(1.0, finite_number(payload.get("dark_emphasis", 0.2), "dark-region emphasis")))
    base_minimum = white + black + gray + max(0, single - 2) * 3
    if total < base_minimum:
        fail("Patch count is too small for the selected grayscale and single-channel coverage")
    temp_dir = tempfile.mkdtemp(prefix="pgen_icc_chart_")
    try:
        base = os.path.join(temp_dir, "patches")
        command = [
            targen, "-v", "-d3", "-e{}".format(white), "-B{}".format(black),
            "-s{}".format(single), "-g{}".format(gray), "-m0", "-f{}".format(total),
            "-A1.0", "-N{:.3f}".format(neutral), "-V{:.3f}".format(1.0 + dark * 3.0), "-p1.0",
        ]
        if payload.get("good_optimization", True):
            command.append("-G")
        precondition = str(payload.get("precondition_profile", ""))
        precondition_path = ""
        if precondition:
            if not re.match(r"^[A-Za-z0-9._-]+\.icc$", precondition, re.I):
                fail("Invalid preconditioning profile")
            precondition_path = os.path.join(output_dir, precondition)
            if not os.path.isfile(precondition_path):
                fail("Preconditioning profile was not found")
            command.extend(["-c", precondition_path])
        command.append(base)
        # Optimized and preconditioned charts can spend many iterations in
        # Argyll's re-seeding stage. Give the desktop offload a useful bound
        # and retain a generous local fallback instead of killing targen while
        # its last progress line merely says "Re-seeding".
        timeout_seconds = min(1800, max(300, 120 + total // 4))
        ti1_path = base + ".ti1"
        if companion_targen_offload(command, ti1_path, timeout_seconds,
                                    precondition_path or None):
            patches = parse_ti1_patches(ti1_path)
            patches = inject_hdr_neutral_jacobian_probes(patches, payload, total)
            return {"status": "ok", "patches": patches, "count": len(patches)}
        if os.environ.get("PGEN_ICC_REQUIRE_OFFLOAD"):
            fail("Patch Companion did not claim the required chart generation")
        completed = subprocess.Popen(["timeout", str(timeout_seconds)] + command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = completed.communicate()[0]
        if completed.returncode != 0 or not os.path.isfile(ti1_path):
            detail = (output or "").strip().splitlines()
            if completed.returncode == 124:
                fail("ArgyllCMS patch generation timed out after {} seconds".format(
                    timeout_seconds))
            fail("ArgyllCMS patch generation failed" + (": " + detail[-1][:240] if detail else ""))
        patches = parse_ti1_patches(ti1_path)
        patches = inject_hdr_neutral_jacobian_probes(patches, payload, total)
        return {"status": "ok", "patches": patches, "count": len(patches)}
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def generate_preconditioned_patches(payload, output_dir):
    """Build a temporary matrix profile from a short pre-read, then let targen
    distribute the final chart in the measured display response space."""
    rows = normalize_measurements(payload)
    ti3, _, _ = make_ti3(payload, rows)
    settings = payload.get("patch_settings")
    if not isinstance(settings, dict):
        fail("Missing final patch-set settings")
    temp_dir = tempfile.mkdtemp(prefix="pgen_icc_precondition_")
    try:
        profile_path = os.path.join(temp_dir, "precondition.icc")
        precondition_payload = dict(payload)
        # This profile is only a temporary device model for targen's patch
        # distribution. It is never installed or returned to the user. A
        # Medium matrix/shaper fit over a reusable 425-patch run can consume
        # several minutes on a Pi 4 before any measurement progress appears.
        # Low quality preserves the measured response needed for chart
        # preconditioning while avoiding an unnecessarily expensive final-fit
        # optimization. The requested quality is still used for the real ICC.
        precondition_payload["profile_quality"] = "low"
        run_colprof(precondition_payload, ti3, profile_path, "matrix", "small")
        settings = dict(settings)
        settings["profile_type"] = payload.get("profile_type")
        settings["profile_model"] = payload.get("profile_model")
        settings["precondition_profile"] = "precondition.icc"
        result = generate_patches(settings, temp_dir)
        result["precondition_patches"] = len(rows)
        result["preconditioned"] = True
        return result
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def run_profcheck(ti3_path, profile_path, rows, profile_model, patch_set):
    profcheck = os.environ.get("PGEN_PROFCHECK", "/usr/bin/profcheck")
    if not os.path.isfile(profcheck) or not os.access(profcheck, os.X_OK):
        fail("The bundled ArgyllCMS profcheck executable is unavailable")
    timeout_seconds = min(300, max(45, 30 + len(rows) // 25))
    command = ["timeout", str(timeout_seconds), profcheck, "-v2", "-k", ti3_path, profile_path]
    environment = dict(os.environ)
    environment["LC_ALL"] = "C"
    completed = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, env=environment)
    output = completed.communicate()[0] or ""
    if completed.returncode != 0:
        detail = output.strip().splitlines()
        fail("ArgyllCMS profile validation failed" + (": " + detail[-1][:240] if detail else ""))
    summary = re.search(
        r"Profile check complete, errors\(CIEDE2000\): max\.\s*=\s*([0-9.eE+-]+),\s*avg\.\s*=\s*([0-9.eE+-]+),\s*RMS\s*=\s*([0-9.eE+-]+)",
        output,
    )
    if not summary:
        fail("ArgyllCMS profile validation returned no summary")
    peak, average, rms = [float(value) for value in summary.groups()]
    patch_errors = []
    for match in re.finditer(r"^\[([0-9.eE+-]+)\]\s+(\d+):", output, re.MULTILINE):
        index = int(match.group(2))
        if index < 1 or index > len(rows):
            continue
        row = rows[index - 1]
        patch_errors.append({
            "index": index,
            "name": row.get("name") or "Patch {}".format(index),
            "rgb": [round(value * 100.0, 2) for value in row["rgb"]],
            "de00": round(float(match.group(1)), 4),
        })
    errors = sorted(item["de00"] for item in patch_errors)
    median = 0.0
    p95 = 0.0
    distribution = None
    if errors:
        midpoint = len(errors) // 2
        median = errors[midpoint] if len(errors) % 2 else (errors[midpoint - 1] + errors[midpoint]) / 2.0
        p95 = errors[min(len(errors) - 1, int(math.ceil(len(errors) * 0.95)) - 1)]
        distribution = {
            "within_1_percent": round(100.0 * sum(value <= 1.0 for value in errors) / len(errors), 1),
            "within_2_percent": round(100.0 * sum(value <= 2.0 for value in errors) / len(errors), 1),
            "within_3_percent": round(100.0 * sum(value <= 3.0 for value in errors) / len(errors), 1),
        }
    if average <= 1.0 and rms <= 1.5 and peak <= 4.0:
        rating = "Excellent"
    elif average <= 2.0 and rms <= 2.5 and peak <= 7.0:
        rating = "Good"
    elif average <= 3.0 and rms <= 4.0 and peak <= 10.0:
        rating = "Fair"
    else:
        rating = "Poor"
    with open(profile_path, "rb") as profile_handle:
        profile_header = profile_handle.read(132)
    profile_info = {}
    if len(profile_header) >= 132:
        version = profile_header[8:12]
        major = version[0]
        minor = (version[1] >> 4) & 0x0F
        bugfix = version[1] & 0x0F
        size_bytes = struct.unpack(">I", profile_header[0:4])[0]
        profile_classes = {"mntr": "Display device profile", "link": "Device link profile"}
        rendering_intents = {0: "Perceptual intent", 1: "Relative colorimetric intent", 2: "Saturation intent", 3: "Absolute colorimetric intent"}
        rendering_intent = struct.unpack(">I", profile_header[64:68])[0]
        profile_info = {
            "icc_version": "{}.{}.{}".format(major, minor, bugfix),
            "profile_class": profile_classes.get(profile_header[12:16].decode("ascii", "replace").strip(), profile_header[12:16].decode("ascii", "replace").strip()),
            "color_space": profile_header[16:20].decode("ascii", "replace").strip(),
            "pcs": profile_header[20:24].decode("ascii", "replace").strip(),
            "rendering_intent": rendering_intents.get(rendering_intent, "Intent {}".format(rendering_intent)),
            "tag_count": struct.unpack(">I", profile_header[128:132])[0],
            "size_bytes": size_bytes,
            "size_label": "{:.1f} KiB".format(size_bytes / 1024.0),
        }
    black_row = repeated_target_row(rows, (0, 0, 0))
    white_row = repeated_target_row(rows, (1, 1, 1))
    white_total = sum(white_row["xyz"])
    black_y = black_row["xyz"][1]
    characterization = {
        "white_x": round(white_row["xyz"][0] / white_total, 6) if white_total > 0 else None,
        "white_y": round(white_row["xyz"][1] / white_total, 6) if white_total > 0 else None,
        "white_nits": round(white_row["xyz"][1], 4),
        "black_nits": round(black_y, 6),
        "contrast_ratio": round(white_row["xyz"][1] / black_y, 1) if black_y > 0 else None,
    }
    return {
        "engine": "ArgyllCMS profcheck 3.5.0",
        "method": "CIEDE2000 forward-profile fit against saved characterization data",
        "profile_model": profile_model,
        "profile_model_label": PROFILE_MODELS[profile_model]["label"],
        "patch_set": patch_set,
        "patches": len(rows),
        "rating": rating,
        "average_de00": round(average, 3),
        "rms_de00": round(rms, 3),
        "peak_de00": round(peak, 3),
        "median_de00": round(median, 3) if errors else None,
        "p95_de00": round(p95, 3) if errors else None,
        "distribution": distribution,
        "profile_info": profile_info,
        "characterization": characterization,
        "worst_patches": sorted(patch_errors, key=lambda item: item["de00"], reverse=True)[:10],
        "note": "This mathematical self-check compares the finished ICC transform with the saved characterization data used to build it. Lower values indicate a closer profile fit.",
    }


def build(payload, output_dir):
    profile_type = str(payload.get("profile_type", ""))
    if profile_type not in PROFILE_TYPES:
        fail("Unsupported ICC profile type")
    signal_mode = str(payload.get("signal_mode", "")).lower()
    if profile_type in ("sdr", "windows-sdr") and signal_mode != "sdr":
        fail("SDR profiles require SDR output")
    if profile_type in ("kde-hdr", "windows-hdr") and signal_mode != "hdr10":
        fail("HDR ICC profiles require HDR10 (PQ) output")
    requested_icc_version, icc_version, cicp = profile_icc_settings(payload, profile_type)
    target_transfer = str(payload.get("target_transfer", "srgb")).lower()
    if profile_type in ("sdr", "windows-sdr") and target_transfer not in WINDOWS_SDR_TRANSFERS:
        fail("Unsupported SDR target transfer")
    if profile_type not in ("sdr", "windows-sdr"):
        target_transfer = None
    profile_model = str(payload.get("profile_model", "clut")).lower()
    if profile_model not in PROFILE_MODELS:
        fail("Unsupported ICC profile model")
    if profile_type in ("windows-sdr", "windows-hdr") and not PROFILE_MODELS[profile_model]["matrix_fallback"]:
        fail("MHC2 profiles require a profile model with matrix and tone-curve fallback tags")
    patch_set = PATCH_SET_ALIASES.get(str(payload.get("quality", "medium")).lower(), str(payload.get("quality", "medium")).lower())
    if patch_set not in ("small", "medium", "large", "custom"):
        fail("Unsupported ICC patch set")
    profile_quality = str(payload.get("profile_quality", "")).lower()
    if profile_quality and profile_quality not in ("low", "medium", "high", "ultra"):
        fail("Unsupported ICC profile calculation quality")
    calibration_mode = str(payload.get("calibration_mode", "")).lower()
    if not calibration_mode:
        # Older saved runs only recorded the VCGT checkbox. Preserve their
        # exact meaning when they are rebuilt after this three-mode selector
        # is introduced.
        legacy_vcgt = payload.get("include_vcgt")
        if legacy_vcgt is None:
            calibration_mode = "vcgt"
        elif isinstance(legacy_vcgt, bool):
            calibration_mode = "vcgt" if legacy_vcgt else "none"
        else:
            fail("Include VCGT must be true or false")
    if calibration_mode not in ("vcgt", "profile", "none"):
        fail("Unsupported calibration mode")
    include_vcgt = calibration_mode == "vcgt"
    rows = normalize_measurements(payload)
    metadata_white_names = ("ICC HDR Metadata White", "ICC Full Frame White")
    metadata_white_rows = [row for row in rows if row["name"] in metadata_white_names]
    profile_rows = [row for row in rows if row["name"] not in metadata_white_names]
    mhc2_profile_rows = profile_rows
    supplied_mhc2_readings = payload.get("mhc2_readings")
    if supplied_mhc2_readings is not None:
        if profile_type != "windows-hdr" or calibration_mode == "none":
            fail("Separate MHC2 measurements require a calibrated Windows HDR profile")
        if not isinstance(supplied_mhc2_readings, list):
            fail("Separate MHC2 measurements must be a list")
        mhc2_payload_input = dict(payload)
        mhc2_payload_input["readings"] = supplied_mhc2_readings
        mhc2_rows = normalize_measurements(mhc2_payload_input)
        # Transform-stability sentinels are series-integrity evidence, not
        # characterization samples. Drop them from every fit by name; the
        # raw-measurement rows that own A2B/B2A never carry them.
        mhc2_profile_rows = [
            row for row in mhc2_rows
            if row["name"] not in metadata_white_names
            and not is_mhc2_sentinel_name(row["name"])
        ]
    if profile_type in ("kde-hdr", "windows-hdr"):
        validate_hdr_neutral_response_continuity(profile_rows)
    if mhc2_profile_rows is not profile_rows:
        mhc2_fit_rows = [
            row for row in mhc2_profile_rows
            if not is_profile_response_feedback_name(row.get("name", ""))
        ]
        if not mhc2_fit_rows:
            mhc2_fit_rows = mhc2_profile_rows
        validate_hdr_neutral_response_continuity(mhc2_fit_rows)
        validate_mhc2_active_shadow_coverage(mhc2_fit_rows)
        # Fail closed before any MHC2 fit when the active rows were measured
        # through more than one effective transform. This guards manual
        # payloads too and never touches the raw-measurement A2B/B2A path.
        validate_mhc2_active_response_coherence(mhc2_fit_rows)
        if (profile_type == "windows-hdr"
                and calibration_mode == "profile"
                and PROFILE_MODELS[profile_model]["family"] == "clut"
                and str(payload.get("stage", "")) == "mhc2-final"):
            if (str(payload.get("mhc2_feedback_contract", ""))
                    != MHC2_PROFILE_RESPONSE_CONTRACT):
                fail("Final HDR MHC2 build requires current active-path "
                     "response provenance; remeasure the active profile path")
            validate_profile_curve_feedback_complete(mhc2_profile_rows)
    else:
        mhc2_fit_rows = mhc2_profile_rows
    patch_set = effective_patch_set(patch_set, profile_model, payload, len(profile_rows))
    if profile_type == "windows-hdr" and not metadata_white_rows:
        fail("HDR MHC2 profiling requires an HDR metadata white measurement")
    # MHC2 and the characterization summary use the raw measurements: they
    # describe the panel, not an already calibrated signal.
    black, white, primaries = profile_measurement_summary(profile_rows)
    mhc2_black, mhc2_white, mhc2_primaries = (
        profile_measurement_summary(mhc2_fit_rows)
        if mhc2_profile_rows is not profile_rows
        else (black, white, primaries)
    )
    keeps_mhc2 = profile_type in ("windows-sdr", "windows-hdr")
    # Stage switches for controlled pipeline experiments. Every switch keeps
    # the same measurements and the same surrounding stages so a hardware
    # comparison isolates exactly one construction difference.
    experiment = payload.get("hdr_experiment") if isinstance(payload.get("hdr_experiment"), dict) else {}
    b2a_grid = None
    if (profile_type in ("kde-hdr", "windows-hdr")
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        requested_grid = payload.get("b2a_grid")
        if requested_grid in (None, ""):
            # Preserve old experimental rebuild payloads while the setting
            # graduates to a normal Display Profiler control.
            requested_grid = 33 if experiment.get("grid") == 33 else 65
        try:
            b2a_grid = int(requested_grid)
        except (TypeError, ValueError):
            fail("HDR B2A cube density must be 33 or 65")
        if b2a_grid not in (33, 65):
            fail("HDR B2A cube density must be 33 or 65")
    mhc2_type = profile_type if keeps_mhc2 else (
        "windows-hdr" if profile_type == "kde-hdr" else "windows-sdr")
    mhc2, matrix, adjustment_luts, calibrated_white = mhc2_payload(
        mhc2_type, black, white, primaries, profile_rows, target_transfer or "srgb",
        apply_calibration=calibration_mode != "none",
        hdr_neutral_headroom=(
            profile_type == "windows-hdr" and calibration_mode != "none"
            and PROFILE_MODELS[profile_model]["family"] != "clut"))
    calibration = vcgt_from_mhc2(matrix, adjustment_luts, mhc2_wire_matrix(mhc2_type))
    calibration_degenerate = False
    # A calibration is a trim: below the display's knee it must track the
    # wire near-identically (the dense MSI sets stay within ~1%). Sparse
    # characterizations can degenerate the ramp inversion into a wire-to-
    # linear-light map (a 425-patch Medium set produced cal(0.5)=0.31 with
    # one channel slammed to 1.0 at 75% while another stopped at 0.59). The
    # separate-vcgt architecture cancels such curves by construction, but
    # MHC2 on Windows and the composed KDE flow apply them for real. Fall
    # back to no calibration rather than ship a corrupted one.
    if calibration_mode != "none":
        entries = len(calibration[0])
        deviation = max(
            abs(curve[int(x * (entries - 1))] - x)
            for curve in calibration
            for x in (0.15, 0.30, 0.45, 0.55))
        if deviation > 0.08:
            calibration_degenerate = True
            calibration = [[index / float(entries - 1) for index in range(entries)]
                           for _channel in range(3)]
            identity_entries = mhc2_lut_entries(mhc2_type)
            identity_mhc2 = [[index / float(identity_entries - 1)
                              for index in range(identity_entries)]
                             for _channel in range(3)]
            mhc2, matrix, adjustment_luts, calibrated_white = mhc2_payload(
                mhc2_type, black, white, primaries, profile_rows,
                target_transfer or "srgb", apply_calibration=True,
                adjustment_luts_override=identity_mhc2,
                hdr_neutral_headroom=(
                    profile_type == "windows-hdr"
                    and PROFILE_MODELS[profile_model]["family"] != "clut"))

    # A separate VCGT starts with a profile of the calibrated virtual device.
    # KDE HDR calibration incorporated into B2A needs two models from the same
    # measurements: a raw High-quality forward model to derive the calibration,
    # followed by a calibrated virtual-device model for the actual ICC color
    # transforms. Windows MHC2 remains its own calibration path and continues
    # to characterize the raw display.
    applied_calibration = None
    if (not keeps_mhc2 and calibration_mode in ("vcgt", "profile")
            and isinstance(experiment.get("applied_calibration"), list)):
        # The characterization was measured with these exact curves already
        # applied on the display (each patch drawn at curve[code]), so the
        # rows describe the calibrated device directly. Fit them as-is and
        # carry the same curves - in vcgt for the separate-calibration flow,
        # or composed into the transforms for the incorporated flow. Deriving
        # fresh curves from these rows would find a near-identity correction
        # and lose the calibration.
        applied_calibration = experiment["applied_calibration"]
        if (len(applied_calibration) != 3
                or any(not curve or len(curve) != len(applied_calibration[0])
                       for curve in applied_calibration)):
            fail("applied_calibration must hold three equal-length curves")
        if calibration_mode == "vcgt":
            calibration = applied_calibration
    fit_rows = profile_rows
    if not keeps_mhc2 and calibration_mode == "vcgt" and applied_calibration is None:
        fit_rows = apply_calibration_to_rows(profile_rows, calibration)
    ti3, _, _ = make_ti3(payload, fit_rows)
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir, 0o755)
    stem = safe_basename(payload.get("name", "PGenerator+ display profile"))
    suffix = {
        "sdr": "SDR",
        "windows-sdr": "SDR-MHC2",
        "kde-hdr": "KDE-HDR",
        "windows-hdr": "HDR-MHC2",
    }[profile_type]
    model_suffix = re.sub(r"-+", "-", SAFE_NAME.sub("-", PROFILE_MODELS[profile_model]["label"]).strip("- ").replace(" ", "-"))
    filename = "{}-{}-{}.icc".format(stem, suffix, model_suffix)
    filename = unique_profile_filename(output_dir, filename)
    output_path = os.path.join(output_dir, filename)
    raw_hdr_calibration_fit = (
        calibration_mode == "profile" and not keeps_mhc2
        and profile_type == "kde-hdr"
        and PROFILE_MODELS[profile_model]["family"] == "clut"
    )
    initial_colprof_payload = payload
    if raw_hdr_calibration_fit:
        initial_colprof_payload = dict(payload)
        initial_colprof_payload["profile_quality"] = "high"
    run_colprof(initial_colprof_payload, ti3, output_path, profile_model, patch_set, icc_version)
    mhc2_validation = None
    with open(output_path, "rb") as handle:
        profile = handle.read()
    if (profile_type == "windows-hdr" and calibration_mode != "none"
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        # The first-pass MHC2 curves use only a primary-axis decomposition and
        # are sufficient while no forward model exists. Replace them now with
        # curves derived from the fitted A2B plus every original neutral and
        # mixed-color characterization row. This prevents non-additive HDR
        # plateaus from producing a one-channel jump at peak white.
        has_active_mhc2_measurements = mhc2_profile_rows is not profile_rows
        raw_adjustment_luts = windows_hdr_profile_adjustment_luts(
            profile, profile_rows, calibration, black, white, matrix,
            raw_measurement_model=not has_active_mhc2_measurements)
        raw_mhc2, raw_matrix, raw_adjustment_luts, raw_calibrated_white = mhc2_payload(
            mhc2_type, black, white, primaries, profile_rows,
            target_transfer or "srgb", apply_calibration=True,
            adjustment_luts_override=raw_adjustment_luts,
            hdr_neutral_headroom=has_active_mhc2_measurements)
        raw_calibration = vcgt_from_mhc2(
            raw_matrix, raw_adjustment_luts, mhc2_wire_matrix(mhc2_type))
        if mhc2_profile_rows is profile_rows:
            mhc2 = raw_mhc2
            matrix = raw_matrix
            adjustment_luts = raw_adjustment_luts
            calibrated_white = raw_calibrated_white
        else:
            # Windows changes the Advanced Color path as soon as an MHC2
            # profile becomes active, even when that profile carries a null
            # transform. Characterize that actual path separately so MHC2
            # corrects the pixels Windows presents. The original raw rows
            # still own A2B/B2A and their explicit cLUT calibration below.
            mhc2, matrix, adjustment_luts, calibrated_white = (
                windows_hdr_mhc2_from_active_profile(
                    profile, mhc2_profile_rows, mhc2_black, mhc2_white,
                    mhc2_primaries, target_transfer))
        # Keep the full measured correction in MHC2. The fitted curves are
        # already resampled into the post-matrix coordinate above, so their
        # per-channel separation is the residual the matrix alone cannot
        # express. Replacing them with a common-tone approximation removes the
        # measured shadow inverse and can drive the HDR shoulder into a clamp
        # where the white-point correction disappears.
        # B2A/cLUT is evaluated with Windows colour handling isolated, so it
        # must retain the raw-display calibration. MHC2 above is an independent
        # consumer derived from the active Windows path when those readings
        # were supplied.
        calibration = raw_calibration
    # Generate and insert MHC2, clone its neutral-axis behaviour into vcgt for
    # the legacy single-calibration paths, then remove MHC2 only from profile
    # types whose consumers do not use it.
    replacements = {b"MHC2": mhc2}
    luminance = None
    if keeps_mhc2:
        # SDR uses the measured profiling white. HDR uses a dedicated metadata
        # white measured with the user's selected window or APL patch geometry.
        if metadata_white_rows and profile_type == "windows-hdr":
            raw_profile_peak = max(white["xyz"][1], black["xyz"][1] + 0.0001)
            calibration_scale = (calibrated_white - black["xyz"][1]) / (raw_profile_peak - black["xyz"][1])
            luminance = black["xyz"][1] + calibration_scale * (metadata_white_rows[0]["xyz"][1] - black["xyz"][1])
        else:
            luminance = metadata_white_rows[0]["xyz"][1] if metadata_white_rows else calibrated_white
        replacements[b"lumi"] = xyz_tag((0.0, luminance, 0.0))
    profile = rebuild_icc(profile, replacements)
    profile = rebuild_icc(profile, {b"vcgt": vcgt_tag(calibration) if include_vcgt else None})
    if (profile_type == "kde-hdr" and PROFILE_MODELS[profile_model]["family"] == "clut"
            and calibration_mode == "vcgt"):
        profile = reshape_hdr_b2a_for_pq(
            profile, white["xyz"][1], grid_size=b2a_grid)
    if not keeps_mhc2:
        profile = rebuild_icc(profile, {b"MHC2": None})
    profile = rebuild_icc(profile, {b"cicp": cicp_tag(cicp) if icc_version == "4.4" else None})
    if keeps_mhc2:
        mhc2_validation = validate_mhc2_profile(
            profile, mhc2,
            measured_primary_matrix(mhc2_black, mhc2_white, mhc2_primaries),
            mhc2_wire_matrix(profile_type), luminance, profile_type,
            expect_calibration=calibration_mode != "none",
        )
    with open(output_path, "wb") as handle:
        handle.write(profile)
    if (profile_type == "windows-hdr" and PROFILE_MODELS[profile_model]["family"] == "clut"
            and not experiment.get("skip_corridor")):
        # Backport of the KDE corridor in its raw flavor: rebuild the BToA
        # neutral corridor from the embedded characterization and continue
        # everything at or above measured white at the earliest measured
        # plateau. Calibration is composed into the output shapers only after
        # this raw-domain repair, below. This removes the inverse-extrapolation
        # region that read collapsed-to-white without touching the fitted color
        # transform.
        repair_tool = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "icc_b2a_repair.py")
        repair_dir = tempfile.mkdtemp(prefix="pgen_b2a_repair_")
        try:
            repaired_path = os.path.join(repair_dir, "repaired.icc")
            repair_env = dict(os.environ)
            repair_env["PGEN_BALANCE"] = "0"
            repair_env.pop("PGEN_CAL_JSON", None)
            completed = subprocess.run(
                [sys.executable, repair_tool, output_path, repaired_path],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                universal_newlines=True, timeout=600, env=repair_env)
            if completed.returncode != 0 or not os.path.isfile(repaired_path):
                detail = (completed.stdout or "").strip().splitlines()
                fail("BToA corridor repair failed"
                     + (": " + detail[-1][:200] if detail else ""))
            shutil.move(repaired_path, output_path)
        finally:
            shutil.rmtree(repair_dir, ignore_errors=True)
    if (profile_type == "kde-hdr" and calibration_mode == "vcgt"
            and PROFILE_MODELS[profile_model]["family"] == "clut"
            and applied_calibration is not None
            and experiment.get("corridor")):
        # Opt-in only: on a physically calibrated characterization the
        # in-range neutral axis needs no repair, and the MSI A/B showed the
        # corridor carving a -33% luminance hole into a desaturated mix
        # (Bluish Green, 11.8 dE2000) while leaving the measured rolloff no
        # better than the plain fit. The corridor stays available for
        # devices whose calibrated fit still shows inverse artifacts.
        repair_tool = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "icc_b2a_repair.py")
        repair_dir = tempfile.mkdtemp(prefix="pgen_b2a_repair_")
        try:
            repaired_path = os.path.join(repair_dir, "repaired.icc")
            repair_env = dict(os.environ)
            repair_env["PGEN_BALANCE"] = "0"
            repair_env.pop("PGEN_CAL_JSON", None)
            completed = subprocess.run(
                [sys.executable, repair_tool, output_path, repaired_path],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                universal_newlines=True, timeout=600, env=repair_env)
            if completed.returncode != 0 or not os.path.isfile(repaired_path):
                detail = (completed.stdout or "").strip().splitlines()
                fail("BToA corridor repair failed"
                     + (": " + detail[-1][:200] if detail else ""))
            shutil.move(repaired_path, output_path)
        finally:
            shutil.rmtree(repair_dir, ignore_errors=True)
    if (calibration_mode == "profile"
            and profile_type in ("kde-hdr", "windows-hdr")
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        if profile_type in ("kde-hdr", "windows-hdr"):
            # The dense original neutral series anchors luminance, while the
            # raw A2B local Jacobian supplies level-dependent white correction.
            # Re-express those same measurements through the resulting curves
            # and let colprof fit the calibrated virtual display. Its B2A cLUT
            # therefore describes the domain that KWin actually sends to the
            # output shapers. No validation or second measurement pass is used.
            with open(output_path, "rb") as handle:
                raw_profile = handle.read()
            if keeps_mhc2:
                # Windows and explicit cLUT handling are independent consumers.
                # Preserve the exact MHC2 neutral correction in B2A rather than
                # deriving a nearby composed-only curve family.
                modeled_calibration = calibration
            elif applied_calibration is not None:
                # The rows were measured with these curves physically applied
                # on the display: they arrive as the calibration contract and
                # no derivation runs. A shaper-style characterization has no
                # dense raw-neutral ramp for the derivations to work from.
                modeled_calibration = applied_calibration
            else:
                modeled_calibration = hdr_profile_calibration_from_a2b(
                    raw_profile, profile_rows, calibration)
            # Live MHC2 and vcgt stages hold their tail at the measured
            # plateau. Composed builds do not apply these curves, they resample
            # them into the BToA shapers, the composed A2B and the neutral
            # corridor, and every accepted hardware run of that flow was fitted
            # with the unheld tail. Pin the composed input to that exact form
            # until the two tails are compared on hardware; the held curves
            # remain reachable as calibration_source "mhc2" for that comparison.
            composed_primary = calibration if calibration_degenerate else vcgt_from_mhc2(
                matrix, windows_hdr_adjustment_luts(
                    profile_rows, black, white, primaries, 256,
                    mhc2_wire_matrix(mhc2_type), matrix, hold_plateau=False),
                mhc2_wire_matrix(mhc2_type))
            if (not keeps_mhc2 and applied_calibration is None
                    and experiment.get("calibration_source", "windows") == "windows"):
                # Deriving the calibration the way windows-hdr builds refine
                # their MHC2 curves closed the rolloff band from 3.35 to 2.20
                # average dE-ITP on the MSI 321URX acceptance runs and beat the
                # small MHC2 reference on greyscale and ColorChecker.
                #
                # It is not used unconditionally. Which family a composed build
                # took was decided by whether this characterization's unheld
                # primary tail ran a channel past the plateau, and the accepted
                # builds on both displays were all spiking sets, so they all
                # took the primary-axis branch. That discriminator is a tail
                # defect, not a property of either family - once the tail is
                # held the two agree to 0.002 at peak - so it is no basis for a
                # choice. It is reproduced here rather than replaced because
                # only a hardware comparison can settle which family a composed
                # build should carry, and this keeps the measured configuration
                # intact until that happens. The earlier reading of this as an
                # 18% peak under-drive by the refinement was measuring the
                # unheld tail.
                #
                # The trim guard already replaced a degenerate derivation with
                # identity; keep that rather than swapping in a refinement the
                # same characterization cannot support.
                keep_primary = calibration_degenerate or any(
                    abs(held[-1] - pinned[-1]) > 1e-9
                    for held, pinned in zip(calibration, composed_primary))
                modeled_calibration = composed_primary
                if not keep_primary:
                    win_luts = windows_hdr_profile_adjustment_luts(
                        raw_profile, profile_rows, calibration, black, white, matrix)
                    _, win_matrix, win_luts, win_peak = mhc2_payload(
                        mhc2_type, black, white, primaries, profile_rows,
                        target_transfer or "srgb", apply_calibration=True,
                        adjustment_luts_override=win_luts)
                    # The refinement inverts the measured per-channel ramps,
                    # and a sparse characterization (no dense single-channel
                    # coverage) can make that inversion collapse: one Medium
                    # patch set drove a 310-nit panel's calibrated peak down
                    # to 182 nits and the finished profile rendered an
                    # S-curve. A calibration is a trim, never a 25% peak cut.
                    if win_peak >= 0.75 * white["xyz"][1]:
                        modeled_calibration = vcgt_from_mhc2(
                            win_matrix, win_luts, mhc2_wire_matrix(mhc2_type))
            elif (not keeps_mhc2 and applied_calibration is None
                  and experiment.get("calibration_source") == "mhc2"):
                # The MHC2-equivalent curves as the live stages apply them,
                # tail held at the plateau. This is the A/B against the pinned
                # composed input above.
                modeled_calibration = calibration
            elif (not keeps_mhc2 and applied_calibration is None
                  and experiment.get("calibration_source") == "modeled"):
                pass  # keep hdr_profile_calibration_from_a2b's curves
            # The measured/modelled curve already contains the dense neutral
            # inversion and the level-dependent D65 correction. Do not splice
            # the older independent-primary curve into its lower 30%. That
            # curve can be far below the measured neutral response on an HDR
            # OLED, and the fixed 30-35% blend then creates a visible and
            # measurable luminance jump at exactly that boundary.
            # Same trim-shape guard as the primary curves: below the knee a
            # calibration must track the wire near-identically. A degenerate
            # derivation composed into the transforms renders as a linear-
            # light S-curve on screen, so drop to identity instead.
            entries = len(modeled_calibration[0])
            deviation = 0.0 if applied_calibration is not None else max(
                abs(curve[int(x * (entries - 1))] - x)
                for curve in modeled_calibration
                for x in (0.15, 0.30, 0.45, 0.55))
            if deviation > 0.08:
                # A composed profile whose output tables carry no calibration
                # is a vcgt profile with its vcgt deleted: it emits raw PQ
                # codes to a panel that only tracks PQ through the
                # calibration. Prefer the primary-axis curves when they
                # passed their own trim guard; if every derivation is
                # degenerate the characterization cannot support a composed
                # build, and failing beats shipping a broken profile.
                if not calibration_degenerate:
                    modeled_calibration = [list(curve) for curve in composed_primary]
                else:
                    fail("This characterization lacks the dense neutral ramp a "
                         "no-VCGT (composed) profile needs. Rebuild with "
                         "Calibration with VCGT, or characterize with a grey "
                         "ramp included.")
            incorporated = modeled_calibration
            fit_calibration = modeled_calibration
            if experiment.get("emit_calibration"):
                # Persist the exact curves this build composes into the
                # profile, in wire domain, so a physically-calibrated
                # re-characterization can apply and later embed the same
                # correction (vcgt + applied_calibration flow).
                with io.open(output_path + ".calibration.json", "w",
                             encoding="ascii") as handle:
                    handle.write(json.dumps(fit_calibration))
            if applied_calibration is not None:
                fit_rows = profile_rows
            else:
                fit_rows = apply_calibration_to_rows(profile_rows, fit_calibration)
            virtual_ti3, _, _ = make_ti3(payload, fit_rows)
            virtual_dir = tempfile.mkdtemp(prefix="pgen_hdr_virtual_")
            try:
                virtual_path = os.path.join(virtual_dir, filename)
                run_colprof(payload, virtual_ti3, virtual_path, profile_model,
                            patch_set, icc_version)
                with open(virtual_path, "rb") as handle:
                    virtual_profile = handle.read()

                # applycal owns the forward-transform composition. Preserve
                # its calibrated A2B, but use the pre-applycal virtual B2A for
                # PQ reshaping so calibration appears exactly once in the
                # high-resolution output tables.
                with open(output_path, "wb") as handle:
                    handle.write(virtual_profile)
                # The forward A2B must describe the same virtual device that
                # colprof fitted above. Compose its input shapers with the fit
                # calibration, which deliberately excludes D65 headroom.
                # Headroom belongs only in the final B2A output shapers below;
                # putting it into A2B as well moves KWin's derived shadow
                # colorimetry even when the active B2A table is unchanged.
                apply_profile_calibration(output_path, fit_calibration)
                with open(output_path, "rb") as handle:
                    calibrated_profile = handle.read()
                if experiment.get("skip_reshape"):
                    # Keep applycal's stock composed B2A untouched.
                    if keeps_mhc2:
                        calibrated_tags = dict(read_icc_tags(calibrated_profile))
                        replacements = {
                            signature: calibrated_tags[signature]
                            for signature in (b"B2A0", b"B2A1", b"B2A2")
                            if signature in calibrated_tags
                        }
                        profile = rebuild_icc(raw_profile, replacements)
                    else:
                        profile = calibrated_profile
                else:
                    # The Companion evaluates HDR source PCS relative to the
                    # profile's lumi tag. KDE's tag remains at the measured
                    # characterization white, while calibrated Windows HDR
                    # stores its lower post-MHC2 white there. Shape B2A in the
                    # same domain its consumer will use. Shaping Windows B2A
                    # against raw white made every cLUT request too large by
                    # raw_white/calibrated_white before the calibration curves
                    # ran, even though the MHC2 and B2A curves were identical.
                    b2a_white = (luminance if keeps_mhc2 and luminance
                                 else white["xyz"][1])
                    reshaped_profile = reshape_hdr_b2a_for_pq(
                        virtual_profile, b2a_white,
                        incorporated_calibration=incorporated,
                        grid_size=b2a_grid)
                    reshaped_tags = dict(read_icc_tags(reshaped_profile))
                    shaped_signatures = ((b"B2A0", b"B2A1", b"B2A2")
                                         if keeps_mhc2
                                         else (b"B2A0", b"B2A1", b"B2A2", b"lumi"))
                    replacements = {
                        signature: reshaped_tags[signature]
                        for signature in shaped_signatures
                        if signature in reshaped_tags
                    }
                    profile = rebuild_icc(
                        raw_profile if keeps_mhc2 else calibrated_profile,
                        replacements)
                    if experiment.get("refine"):
                        # Off by default: on the MSI 321URX acceptance runs the
                        # forward-model refinement worsened ColorChecker dE2000
                        # from 1.58 to 2.72 average and added a -3 dx mid-band
                        # grey cast. Kept as an opt-in for comparisons.
                        profile = refine_hdr_b2a_from_forward_model(
                            profile, raw_profile, white["xyz"][1])
                profile = rebuild_icc(profile, {
                    b"MHC2": mhc2 if keeps_mhc2 else None,
                    b"vcgt": None,
                    b"lumi": (xyz_tag((0.0, luminance, 0.0))
                              if keeps_mhc2 else dict(read_icc_tags(profile)).get(b"lumi")),
                    b"cicp": cicp_tag(cicp) if icc_version == "4.4" else None,
                })
            finally:
                shutil.rmtree(virtual_dir, ignore_errors=True)
            with open(output_path, "wb") as handle:
                handle.write(profile)
            if not experiment.get("skip_corridor"):
                # Rebuild the neutral corridor and the region above measured
                # white from the raw characterization: measured neutral codes
                # through the rolloff and the earliest-plateau continuation at
                # the top, so highlight requests never leave the measured
                # range. The balanced-peak white solve stays opt-in until the
                # profiling patch sets carry knee-band samples dense enough
                # for a reliable one-shot solve.
                raw_ti3_text, _, _ = make_ti3(payload, profile_rows)
                repair_tool = os.path.join(
                    os.path.dirname(os.path.abspath(__file__)), "icc_b2a_repair.py")
                repair_dir = tempfile.mkdtemp(prefix="pgen_b2a_repair_")
                try:
                    raw_ti3_path = os.path.join(repair_dir, "raw.ti3")
                    with io.open(raw_ti3_path, "w", encoding="ascii", errors="replace") as handle:
                        handle.write(raw_ti3_text)
                    repaired_path = os.path.join(repair_dir, "repaired.icc")
                    cal_json_path = os.path.join(repair_dir, "calibration.json")
                    with io.open(cal_json_path, "w", encoding="ascii") as handle:
                        handle.write(json.dumps(fit_calibration))
                    repair_env = dict(os.environ)
                    repair_env["PGEN_BALANCE"] = "1" if experiment.get("balanced_peak") else "0"
                    repair_env["PGEN_CAL_JSON"] = cal_json_path
                    completed = subprocess.run(
                        [sys.executable, repair_tool, output_path, repaired_path, raw_ti3_path],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        universal_newlines=True, timeout=600, env=repair_env)
                    if completed.returncode != 0 or not os.path.isfile(repaired_path):
                        fail("BToA corridor repair failed: "
                             + (completed.stdout or "").strip().splitlines()[-1][:200])
                    shutil.move(repaired_path, output_path)
                finally:
                    shutil.rmtree(repair_dir, ignore_errors=True)
    elif calibration_mode == "profile" and not keeps_mhc2:
        apply_profile_calibration(output_path, calibration)

    if (mhc2_profile_rows is not profile_rows
            and profile_type == "windows-hdr"
            and calibration_mode != "none"
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        # All B2A/cLUT construction is complete. Refit the independent MHC2
        # against this exact final A2B model so no intermediate profile can
        # leak into the Windows-system correction. This changes MHC2 and its
        # luminance metadata only; the raw-measurement cLUT remains untouched.
        with open(output_path, "rb") as handle:
            profile = handle.read()
        mhc2, matrix, adjustment_luts, calibrated_white = (
            windows_hdr_mhc2_from_active_profile(
                profile, mhc2_profile_rows, mhc2_black, mhc2_white,
                mhc2_primaries, target_transfer))
        if metadata_white_rows:
            active_peak = max(
                mhc2_white["xyz"][1], mhc2_black["xyz"][1] + 0.0001)
            calibration_scale = (
                (calibrated_white - mhc2_black["xyz"][1])
                / (active_peak - mhc2_black["xyz"][1]))
            luminance = (black["xyz"][1]
                         + calibration_scale
                         * (metadata_white_rows[0]["xyz"][1]
                            - black["xyz"][1]))
        else:
            luminance = calibrated_white
        profile = rebuild_icc(profile, {
            b"MHC2": mhc2,
            b"lumi": xyz_tag((0.0, luminance, 0.0)),
            b"vcgt": None,
            b"cicp": cicp_tag(cicp) if icc_version == "4.4" else None,
        })
        mhc2_validation = validate_mhc2_profile(
            profile, mhc2,
            measured_primary_matrix(
                mhc2_black, mhc2_white, mhc2_primaries),
            mhc2_wire_matrix(profile_type), luminance, profile_type,
            expect_calibration=True,
        )
        with open(output_path, "wb") as handle:
            handle.write(profile)
    if (profile_type == "windows-hdr"
            and calibration_mode == "profile"
            and PROFILE_MODELS[profile_model]["family"] == "clut"):
        # B2A construction and any active-profile feedback are now complete.
        # Make Windows system handling reproduce that exact final neutral
        # transform instead of shipping a separately modelled greyscale.
        with open(output_path, "rb") as handle:
            profile = handle.read()
        final_mhc2 = dict(read_icc_tags(profile)).get(b"MHC2")
        if not final_mhc2:
            fail("Windows HDR cLUT matching requires an MHC2 tag")
        matrix_offset = struct.unpack_from(">I", final_mhc2, 20)[0]
        final_matrix = [
            [read_s15fixed16(
                final_mhc2, matrix_offset + row * 16 + column * 4)
             for column in range(3)]
            for row in range(3)
        ]
        final_wire = mhc2_wire_matrix(profile_type)
        final_rgb_adjustment = mat_mul(
            mat_inv(final_wire), mat_mul(final_matrix, final_wire))
        final_neutral_gains = mat_vec_mul(
            final_rgb_adjustment, (1.0, 1.0, 1.0))

        if str(payload.get("stage", "")) == "mhc2-final":
            validate_profile_curve_feedback_recoverable(
                mhc2_profile_rows, "ICC MHC2 Curve Feedback",
                calibrated_white)

        # Correct the explicit cLUT path only from variants that changed its
        # actual B2A neutral corridor. A profile that already meets the target
        # either lands inside the deadband or fails the improvement gate and
        # remains byte-for-byte unchanged here.
        b2a_reference_luts = windows_hdr_mhc2_luts_from_final_b2a(
            profile, final_mhc2)
        b2a_corrected_luts = [list(curve) for curve in b2a_reference_luts]
        # Code 51 has a clean grey-ladder XYZ but no viable local probe set.
        # Borrow the nearest Jacobian so the independent cLUT corridor can
        # use that measured chroma error. Fade out at the first probed code
        # so curve feedback still owns 102 and above unchanged.
        borrowed_clut = apply_mhc2_borrowed_shadow_greys(
            b2a_corrected_luts, mhc2_profile_rows, final_neutral_gains)
        if apply_profile_curve_feedback(
                b2a_corrected_luts, mhc2_profile_rows,
                final_neutral_gains, calibrated_white,
                # hold_top stays on because the hardware says so, even
                # though it is wrong-signed at the very peak. The last usable
                # anchor at 716 solves to B -0.00277, less blue, correct there
                # and leaving 716 at 0.152 chroma, while the plateau needs
                # more blue to pull y from .3319 toward .3290. Disabling the
                # hold to avoid that mis-sign measured WORSE overall, cLUT
                # average 1.232 against 1.185 and peak 1.678 against 1.645,
                # because the hold still helps codes 767 to 818. Fixing the
                # plateau properly needs its own measured stage, the cLUT
                # analogue of apply_mhc2_final_peak_feedback.
                "ICC cLUT Curve Feedback",
                codes=MHC2_CLUT_FEEDBACK_CODES, hold_top=True) or borrowed_clut:
            # The corridor rewrite has to reach the top now that measured
            # cLUT anchors exist above the shadow band; 0.45 confined every
            # correction to the bottom 45% of the range.
            profile = windows_hdr_b2a_with_shadow_luts(
                profile, b2a_reference_luts, b2a_corrected_luts,
                final_neutral_gains, source_limit=1.0)

        # The corridor feedback cannot reach the plateau: probes there produce
        # no measurable response and extrapolating the last anchor is
        # wrong-signed. Drive it from the directly measured best peak triplet
        # instead, which is the same selection the MHC2 balanced peak cap uses.
        # Common-mode luminance trim first, then the absolute plateau drive.
        # The two operate on disjoint source ranges, below and above 0.77.
        profile = windows_hdr_b2a_with_ladder_trim(profile, mhc2_profile_rows)
        profile = windows_hdr_b2a_with_peak_drive(profile, mhc2_profile_rows)

        # Windows system handling gets its own measured response solve. Keep
        # the independently fitted active-path curves as its baseline. Cloning
        # B2A here erases the measured MHC2 shadow correction before feedback
        # and is exactly the coupling this split-path stage exists to avoid.
        matching_luts = mhc2_adjustment_luts(final_mhc2)
        apply_profile_curve_feedback(
            matching_luts, mhc2_profile_rows, final_neutral_gains,
            calibrated_white, "ICC MHC2 Curve Feedback",
            codes=MHC2_MIDBAND_FEEDBACK_CODES)
        # Common-mode luminance trim on the MHC2 curves themselves. Cloning
        # the B2A here would erase the measured MHC2 shadow correction.
        apply_mhc2_probe_luminance_trim(
            matching_luts, mhc2_profile_rows, final_neutral_gains)
        apply_mhc2_final_peak_feedback(
            matching_luts, mhc2_profile_rows, final_neutral_gains,
            calibrated_white)
        apply_mhc2_upper_neutral_jacobians(
            matching_luts, mhc2_profile_rows, final_neutral_gains)
        final_mhc2 = mhc2_with_adjustment_luts(final_mhc2, matching_luts)
        profile = rebuild_icc(profile, {b"MHC2": final_mhc2})
        with open(output_path, "wb") as handle:
            handle.write(profile)
        mhc2_validation = validate_mhc2_profile(
            profile, final_mhc2,
            measured_primary_matrix(
                mhc2_black, mhc2_white, mhc2_primaries),
            mhc2_wire_matrix(profile_type), luminance, profile_type,
            expect_calibration=True,
        )
    association = profile_association_tag(profile_type)
    calibration_contract = profile_calibration_contract_tag(
        profile_type, calibration_mode, profile_model,
        independent_mhc2=mhc2_profile_rows is not profile_rows)
    if association is not None or calibration_contract is not None:
        with open(output_path, "rb") as handle:
            profile = handle.read()
        profile = rebuild_icc(profile, {
            b"pGAs": association,
            b"pGCm": calibration_contract,
        })
        with open(output_path, "wb") as handle:
            handle.write(profile)

    mhc2_feedback_profiles = None
    if (profile_type == "windows-hdr"
            and str(payload.get("stage", "")) == "mhc2-feedback-provisional"):
        with open(output_path, "rb") as handle:
            feedback_base = handle.read()
        mhc2_feedback_profiles = {
            "base": filename,
            "delta": 0.01,
            "shadow_delta": MHC2_CURVE_FEEDBACK_DELTA,
        }
        feedback_mhc2 = dict(read_icc_tags(feedback_base)).get(b"MHC2")
        if not feedback_mhc2:
            fail("Final feedback profile requires an MHC2 tag")
        for channel, label in enumerate(("R", "G", "B")):
            probe_name = unique_profile_filename(
                output_dir,
                "{}-MHC2-Final-Feedback-{}-Probe.icc".format(stem, label),
            )
            probe_path = os.path.join(output_dir, probe_name)
            probe_profile = mhc2_profile_with_curve_probe(
                feedback_base, channel, 0.01,
                MHC2_CURVE_FEEDBACK_DELTA)
            with open(probe_path, "wb") as handle:
                handle.write(probe_profile)
            mhc2_feedback_profiles[label] = probe_name
            clut_probe_name = unique_profile_filename(
                output_dir,
                "{}-cLUT-Final-Feedback-{}-Probe.icc".format(stem, label),
            )
            clut_probe_path = os.path.join(output_dir, clut_probe_name)
            clut_probe_profile = b2a_profile_with_curve_probe(
                feedback_base, feedback_mhc2, channel,
                MHC2_CURVE_FEEDBACK_DELTA)
            with open(clut_probe_path, "wb") as handle:
                handle.write(clut_probe_profile)
            mhc2_feedback_profiles["clut_" + label] = clut_probe_name
            negative_probe_name = unique_profile_filename(
                output_dir,
                "{}-MHC2-Final-Feedback-{}-Minus-Probe.icc".format(
                    stem, label),
            )
            negative_probe_path = os.path.join(
                output_dir, negative_probe_name)
            negative_probe_profile = mhc2_profile_with_curve_probe(
                feedback_base, channel, 0.0,
                -MHC2_CURVE_FEEDBACK_DELTA)
            with open(negative_probe_path, "wb") as handle:
                handle.write(negative_probe_profile)
            mhc2_feedback_profiles[label + "_minus"] = negative_probe_name
            negative_clut_name = unique_profile_filename(
                output_dir,
                "{}-cLUT-Final-Feedback-{}-Minus-Probe.icc".format(
                    stem, label),
            )
            negative_clut_path = os.path.join(
                output_dir, negative_clut_name)
            negative_clut_profile = b2a_profile_with_curve_probe(
                feedback_base, feedback_mhc2, channel,
                -MHC2_CURVE_FEEDBACK_DELTA)
            with open(negative_clut_path, "wb") as handle:
                handle.write(negative_clut_profile)
            mhc2_feedback_profiles[
                "clut_" + label + "_minus"] = negative_clut_name

    ti3_filename = filename[:-4] + ".ti3"
    ti3_path = os.path.join(output_dir, ti3_filename)
    final_ti3 = ti3
    validation_rows = fit_rows
    if calibration_mode == "profile" and not keeps_mhc2:
        # applycal composes the calibration into both profile directions, so
        # the finished profile once again accepts raw device values. Validate
        # and retain the raw characterization rather than the virtual-device
        # data used for the intermediate colprof fit.
        final_ti3, _, _ = make_ti3(payload, profile_rows)
        validation_rows = profile_rows
    write_text_atomic(ti3_path, final_ti3)
    validation = run_profcheck(ti3_path, output_path, validation_rows, profile_model, patch_set)
    validation["profile_quality"] = profile_quality or ("high" if patch_set == "large" or len(profile_rows) > 800 else "medium")
    validation["b2a_grid"] = b2a_grid
    # Fine-tune has to evaluate this profile against the curve it was built
    # for. Nothing in the ICC records that, and the measurements sidecar is
    # only written for reusable characterizations, so name it here.
    validation["profile_type"] = profile_type
    validation["target_transfer"] = target_transfer
    if mhc2_validation:
        validation["mhc2"] = mhc2_validation
        validation["note"] = "ArgyllCMS checks the saved characterization fit. The MHC2 self-check also verifies the correction tag structure, matrix direction, adjustment curves and luminance metadata."
    write_json_atomic(output_path + ".validation.json", validation)
    # Keep the merged characterization readings with the finished profile.
    # The WebUI can then offer them for a later, larger patch set even after a
    # different series has replaced the live meter state or the page reloads.
    measurement_path = output_path + ".measurements.json"
    reuse_signature = str(payload.get("reuse_signature", "")).lower()
    if re.match(r"^[0-9a-f]{16}$", reuse_signature):
        reusable_rows = []
        for row in rows:
            reusable_rows.append({
                "name": row["name"],
                "r_code": row["codes"][0],
                "g_code": row["codes"][1],
                "b_code": row["codes"][2],
                "input_max": row["input_max"],
                "X": row["xyz"][0],
                "Y": row["xyz"][1],
                "Z": row["xyz"][2],
            })
        write_json_atomic(measurement_path, {
            "created": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
            "profile": filename,
            "profile_type": profile_type,
            "reuse_signature": reuse_signature,
            "signal_mode": str(payload.get("signal_mode", "")),
            "build_config": {
                "profile_type": profile_type,
                "profile_model": profile_model,
                "profile_quality": profile_quality or ("high" if patch_set == "large" or len(profile_rows) > 800 else "medium"),
                "calibration_mode": calibration_mode,
                "include_vcgt": include_vcgt,
                "icc_version": requested_icc_version,
                "cicp": cicp,
                "quality": patch_set,
                "signal_mode": str(payload.get("signal_mode", "")),
                "pattern_provider": str(payload.get("pattern_provider", "")),
                "reuse_signature": reuse_signature,
                "target_transfer": target_transfer,
                "code_min": payload.get("code_min", 0),
                "code_max": payload.get("code_max", 255),
                "patch_settings": payload.get("patch_settings") if isinstance(payload.get("patch_settings"), dict) else None,
                "avg_deviation": payload.get("avg_deviation"),
                "patch_count": len(profile_rows),
                "mhc2_patch_count": (len(mhc2_profile_rows)
                                     if mhc2_profile_rows is not profile_rows
                                     else None),
                "mhc2_feedback_contract": (
                    str(payload.get("mhc2_feedback_contract", "")) or None),
                "b2a_grid": b2a_grid,
            },
            "status": "ok",
            "readings": reusable_rows,
            "mhc2_readings": ([{
                "name": row["name"],
                "r_code": row["codes"][0],
                "g_code": row["codes"][1],
                "b_code": row["codes"][2],
                "input_max": row["input_max"],
                "X": row["xyz"][0],
                "Y": row["xyz"][1],
                "Z": row["xyz"][2],
            } for row in mhc2_profile_rows]
                if mhc2_profile_rows is not profile_rows else None),
        })
    elif os.path.exists(measurement_path):
        os.unlink(measurement_path)
    size = os.path.getsize(output_path)
    return {
        "status": "ok",
        "file": filename,
        "size": size,
        "profile_type": profile_type,
        "profile_model": profile_model,
        "profile_model_label": PROFILE_MODELS[profile_model]["label"],
        "patch_set": patch_set,
        "profile_quality": profile_quality or None,
        "b2a_grid": b2a_grid,
        "calibration_mode": calibration_mode,
        "include_vcgt": include_vcgt,
        "icc_version": icc_version,
        "icc_version_request": requested_icc_version,
        "cicp": cicp if icc_version == "4.4" else None,
        "target_transfer": target_transfer,
        "patches": len(rows),
        "white_nits": white["xyz"][1],
        "calibrated_white_nits": calibrated_white,
        "metadata_white_nits": metadata_white_rows[0]["xyz"][1] if metadata_white_rows else None,
        "black_nits": black["xyz"][1],
        "mhc2_matrix": matrix,
        "mhc2_lut_entries": len(adjustment_luts[0]) if adjustment_luts else None,
        "mhc2_peak_codes": ([int(round(max(0.0, min(1.0, curve[-1]))
                                       * int(payload.get("code_max", 255))))
                             for curve in adjustment_luts]
                            if (profile_type == "windows-hdr"
                                and adjustment_luts) else None),
        "mhc2_feedback_profiles": mhc2_feedback_profiles,
        "mhc2_feedback_contract": (
            MHC2_PROFILE_RESPONSE_CONTRACT
            if mhc2_feedback_profiles is not None else None),
        "validation": validation,
    }


def main():
    patch_mode = len(sys.argv) == 4 and sys.argv[1] == "--patches"
    precondition_mode = len(sys.argv) == 4 and sys.argv[1] == "--precondition-patches"
    special_mode = patch_mode or precondition_mode
    if (not special_mode and len(sys.argv) != 3) or (special_mode and len(sys.argv) != 4):
        print(json.dumps({"status": "error", "message": "Usage: icc_profile_builder.py [--patches|--precondition-patches] INPUT.json OUTPUT_DIR"}))
        return 2
    try:
        input_path = sys.argv[2] if special_mode else sys.argv[1]
        output_dir = sys.argv[3] if special_mode else sys.argv[2]
        with io.open(input_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if patch_mode:
            result = generate_patches(payload, output_dir)
        elif precondition_mode:
            result = generate_preconditioned_patches(payload, output_dir)
        else:
            result = build(payload, output_dir)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (ValueError, OSError, IOError, subprocess.CalledProcessError) as error:
        print(json.dumps({"status": "error", "message": str(error)}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())

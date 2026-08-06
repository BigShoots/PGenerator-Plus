#!/usr/bin/env python3
"""Build display ICC profiles from PGenerator+ RGB/XYZ measurements.

The normal and KDE profiles are created by the bundled ArgyllCMS colprof.
Windows Advanced Color profiles add Microsoft's documented MHC2 tag to that
measured matrix/shaper profile.  Only the Python standard library is used.
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
SAFE_NAME = re.compile(r"[^A-Za-z0-9._ -]+")


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


def profile_measurement_summary(rows):
    black = closest_row(rows, (0, 0, 0))
    white = closest_row(rows, (1, 1, 1))
    primaries = [
        closest_row(rows, (1, 0, 0)),
        closest_row(rows, (0, 1, 0)),
        closest_row(rows, (0, 0, 1)),
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
    if payload.get("profile_type") == "windows-sdr":
        transfer = str(payload.get("target_transfer", "srgb")).lower()
        description += " (SDR MHC2, {})".format(WINDOWS_SDR_TRANSFER_LABELS.get(transfer, "sRGB"))
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


def mat_mul(left, right):
    return [[sum(left[r][k] * right[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


def mat_vec_mul(matrix, vector):
    return [sum(matrix[row][column] * vector[column] for column in range(3)) for row in range(3)]


def mat_inv(matrix):
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(determinant) < 1e-9:
        fail("Measured primary matrix is singular")
    return [
        [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant],
        [(f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant],
        [(d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant],
    ]


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


def pq_to_nits(value):
    """Decode a normalized ST.2084 signal value into absolute cd/m2."""
    value = max(0.0, min(1.0, value))
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    power = value ** (1.0 / m2)
    return 10000.0 * (max(power - c1, 0.0) / max(c2 - c3 * power, 1e-12)) ** (1.0 / m1)


# Entries in the per-channel calibration curve written to vcgt. A 1D curve can
# afford resolution a 3D cLUT cannot: 33 grid nodes per axis leave only two
# below 1.2 cd/m2 on a display whose shadow response is steep, which is far too
# coarse to invert. The calibration carries that region instead.
VCGT_ENTRIES = 1024


def nits_to_pq(nits):
    """Encode absolute cd/m2 as a normalized ST.2084 signal value."""
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    ratio = max(0.0, nits) / 10000.0
    powered = ratio ** m1
    return ((c1 + c2 * powered) / (1.0 + c3 * powered)) ** m2


def calibration_curves(rows, black, white, primaries, profile_type, target_transfer,
                       entries=VCGT_ENTRIES):
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
            target = max(0.0, min(1.0, target))
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
    if target <= samples[0][1]:
        return samples[0][0]
    for index in range(1, len(samples)):
        x0, y0 = samples[index - 1]
        x1, y1 = samples[index]
        if target <= y1:
            if y1 <= y0 + 1e-12:
                return x1
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


def windows_hdr_adjustment_luts(rows, black, white, primaries, entries, wire, adjustment):
    """Invert the measured neutral response in the post-PQ MHC2 stage.

    Windows applies the MHC2 matrix in linear XYZ, encodes the active HDR wire
    transfer function, then evaluates these per-channel adjustment tables. The
    table input is therefore a PQ code, while the measured response is relative
    to the panel's black-to-peak range. Mapping absolute PQ luminance into that
    measured range corrects both channel balance and a display-side roll-off or
    plateau without applying PQ a second time.
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
    luts = []
    for channel in range(3):
        values = []
        previous = 0.0
        # A raw peak-white correction cannot request more than the measured
        # maximum of any physical channel. Hold every channel at the same
        # corrected-white luminance once the largest matrix gain reaches that
        # limit. This preserves the calibrated white point instead of letting
        # all three curves eventually saturate to the uncorrected native white.
        channel_limit = neutral_gains[channel] / maximum_gain
        for index in range(entries):
            encoded = index / float(entries - 1)
            target = max(0.0, min(1.0, (pq_to_nits(encoded) - black_nits) / span))
            target = min(target, channel_limit)
            value = invert_channel_response(channel_samples[channel], target)
            previous = max(previous, max(0.0, min(1.0, value)))
            values.append(previous)
        values[0] = 0.0
        values[-1] = max(values[-2], values[-1])
        luts.append(values)
    return luts


def mhc2_wire_matrix(profile_type):
    if profile_type == "windows-hdr":
        return xy_matrix(((0.708, 0.292), (0.170, 0.797), (0.131, 0.046)), (0.3127, 0.3290))
    return xy_matrix(((0.640, 0.330), (0.300, 0.600), (0.150, 0.060)), (0.3127, 0.3290))


def mhc2_payload(profile_type, black, white, primaries, rows, target_transfer="srgb"):
    physical = measured_primary_matrix(black, white, primaries)
    wire = mhc2_wire_matrix(profile_type)
    adjustment = mat_mul(wire, mat_inv(physical))
    calibrated_peak = max(white["xyz"][1], black["xyz"][1] + 0.0001)
    rgb_adjustment = mat_mul(mat_inv(wire), mat_mul(adjustment, wire))
    neutral_gains = mat_vec_mul(rgb_adjustment, (1.0, 1.0, 1.0))
    if profile_type == "windows-sdr":
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
    entries = 256
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
    # MHC2 curves operate after Windows applies the wire transfer function.
    # They contain only the measured post-transfer adjustment, never the wire
    # transfer function itself. Both HDR and SDR invert the measured channel
    # ramps while the matrix corrects primaries and white point.
    if profile_type == "windows-sdr":
        luts = windows_sdr_adjustment_luts(rows, black, white, primaries, entries, target_transfer, wire, adjustment)
    else:
        luts = windows_hdr_adjustment_luts(rows, black, white, primaries, entries, wire, adjustment)
    for values in luts:
        data.extend(b"sf32" + b"\0\0\0\0")
        for value in values:
            data.extend(s15fixed16(value))
    return bytes(data), adjustment, luts, calibrated_peak


def xyz_tag(xyz):
    return b"XYZ " + b"\0\0\0\0" + b"".join(s15fixed16(value) for value in xyz)


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
                tags.append((signature, replacements[signature]))
                replaced.add(signature)
        else:
            tags.append((signature, payload))
    for signature, payload in replacements.items():
        if signature not in replaced:
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


def read_s15fixed16(data, offset):
    if offset < 0 or offset + 4 > len(data):
        fail("MHC2 fixed-point value is outside the tag")
    return struct.unpack(">i", data[offset:offset + 4])[0] / 65536.0


def validate_mhc2_profile(profile, expected_payload, physical, wire, expected_metadata_white, profile_type):
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
    residual = mat_mul(physical, mat_mul(mat_inv(wire), matrix))
    maximum_residual = max(abs(residual[row][column] - (1.0 if row == column else 0.0)) for row in range(3) for column in range(3))
    if maximum_residual > 0.002:
        fail("MHC2 correction matrix failed its round-trip identity check")
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
    return {
        "status": "passed",
        "tag_version": "MHC2",
        "matrix_round_trip_max_error": round(maximum_residual, 7),
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


def run_colprof(payload, ti3, output_path, profile_model, patch_set):
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
        # cLUT fitting on the Pi is substantially slower than matrix fitting,
        # and scales with both characterization size and requested quality.
        # The former 90-second floor killed a normal 175-patch Medium XYZ cLUT
        # while colprof was still working and left a zero-byte destination.
        line_count = len(ti3.splitlines())
        quality_factor = {"l": 0.5, "m": 1.0, "h": 2.0, "u": 4.0}.get(quality, 1.0)
        if PROFILE_MODELS[profile_model]["family"] == "clut":
            # colprof's current cLUT optimizer runs one fit on one CPU thread, and a
            # normal High fit can need more than eight minutes on Pi 4. The
            # old line-count estimate gave a 425-patch High profile only 508
            # seconds and killed a healthy process at 100% of one CPU core.
            # Keep the timeout below the WebUI's 45-minute build deadline, but
            # give each requested fit quality a realistic floor.
            quality_floor = {"l": 600, "m": 900, "h": 1200, "u": 2400}.get(quality, 900)
            timeout_seconds = min(2400, max(quality_floor, int(180 + line_count * quality_factor * 1.5)))
        else:
            timeout_seconds = min(900, max(180, int(90 + line_count * quality_factor * 0.5)))
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
        if precondition:
            if not re.match(r"^[A-Za-z0-9._-]+\.icc$", precondition, re.I):
                fail("Invalid preconditioning profile")
            precondition_path = os.path.join(output_dir, precondition)
            if not os.path.isfile(precondition_path):
                fail("Preconditioning profile was not found")
            command.extend(["-c", precondition_path])
        command.append(base)
        timeout_seconds = min(900, max(90, 60 + total // 15))
        completed = subprocess.Popen(["timeout", str(timeout_seconds)] + command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = completed.communicate()[0]
        ti1_path = base + ".ti1"
        if completed.returncode != 0 or not os.path.isfile(ti1_path):
            detail = (output or "").strip().splitlines()
            fail("ArgyllCMS patch generation failed" + (": " + detail[-1][:240] if detail else ""))
        patches = parse_ti1_patches(ti1_path)
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
    black_row = closest_row(rows, (0, 0, 0))
    white_row = closest_row(rows, (1, 1, 1))
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
    target_transfer = str(payload.get("target_transfer", "srgb")).lower()
    if profile_type == "windows-sdr" and target_transfer not in WINDOWS_SDR_TRANSFERS:
        fail("Unsupported SDR MHC2 target transfer")
    if profile_type != "windows-sdr":
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
    rows = normalize_measurements(payload)
    metadata_white_names = ("ICC HDR Metadata White", "ICC Full Frame White")
    metadata_white_rows = [row for row in rows if row["name"] in metadata_white_names]
    profile_rows = [row for row in rows if row["name"] not in metadata_white_names]
    patch_set = effective_patch_set(patch_set, profile_model, payload, len(profile_rows))
    if profile_type == "windows-hdr" and not metadata_white_rows:
        fail("HDR MHC2 profiling requires an HDR metadata white measurement")
    # Derive the 1D calibration from the measured neutral ramp, then fit the
    # cLUT in the calibrated domain. MHC2 and the characterization summary keep
    # using the raw measurements: they describe the panel, not the calibrated
    # signal, and neutral_channel_samples reads the measured device values.
    _, _, primaries = profile_measurement_summary(profile_rows)
    measured_black, measured_white, _ = profile_measurement_summary(profile_rows)
    calibration = None
    if payload.get("calibration", True) and PROFILE_MODELS[profile_model]["family"] == "clut":
        try:
            calibration = calibration_curves(
                profile_rows, measured_black, measured_white, primaries,
                profile_type, target_transfer,
            )
        except ValueError:
            # A characterization without a usable black-to-white neutral ramp
            # cannot produce a calibration. Fall back to the uncalibrated fit
            # rather than failing the whole build.
            calibration = None
    ti3_rows = apply_calibration_to_rows(profile_rows, calibration) if calibration else profile_rows
    ti3, black, white = make_ti3(payload, ti3_rows)
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
    output_path = os.path.join(output_dir, filename)
    run_colprof(payload, ti3, output_path, profile_model, patch_set)
    matrix = None
    adjustment_luts = None
    calibrated_white = None
    mhc2_validation = None
    if profile_type in ("windows-sdr", "windows-hdr"):
        with open(output_path, "rb") as handle:
            profile = handle.read()
        mhc2, matrix, adjustment_luts, calibrated_white = mhc2_payload(profile_type, black, white, primaries, profile_rows, target_transfer or "srgb")
        # SDR uses the measured profiling white. HDR uses a dedicated metadata
        # white measured with the user's selected window or APL patch geometry.
        if metadata_white_rows and profile_type == "windows-hdr":
            raw_profile_peak = max(white["xyz"][1], black["xyz"][1] + 0.0001)
            calibration_scale = (calibrated_white - black["xyz"][1]) / (raw_profile_peak - black["xyz"][1])
            luminance = black["xyz"][1] + calibration_scale * (metadata_white_rows[0]["xyz"][1] - black["xyz"][1])
        else:
            luminance = metadata_white_rows[0]["xyz"][1] if metadata_white_rows else calibrated_white
        profile = rebuild_icc(profile, {b"MHC2": mhc2, b"lumi": xyz_tag((0.0, luminance, 0.0))})
        mhc2_validation = validate_mhc2_profile(
            profile, mhc2, measured_primary_matrix(black, white, primaries),
            mhc2_wire_matrix(profile_type), luminance, profile_type,
        )
        with open(output_path, "wb") as handle:
            handle.write(profile)
    if calibration:
        # The cLUT above was fitted in the calibrated domain, so every consumer
        # needs this 1D stage in front of it. vcgt is the portable one: OS
        # profile loaders apply it, and the Companion applies it for HDR where
        # Windows bypasses the GPU LUT. MHC2 carries the same calibration for
        # the OS system-correction path.
        with open(output_path, "rb") as handle:
            profile = handle.read()
        with open(output_path, "wb") as handle:
            handle.write(rebuild_icc(profile, {b"vcgt": vcgt_tag(calibration)}))
    ti3_filename = filename[:-4] + ".ti3"
    ti3_path = os.path.join(output_dir, ti3_filename)
    write_text_atomic(ti3_path, ti3)
    validation = run_profcheck(ti3_path, output_path, profile_rows, profile_model, patch_set)
    validation["profile_quality"] = profile_quality or ("high" if patch_set == "large" or len(profile_rows) > 800 else "medium")
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
                "quality": patch_set,
                "signal_mode": str(payload.get("signal_mode", "")),
                "pattern_provider": str(payload.get("pattern_provider", "")),
                "reuse_signature": reuse_signature,
                "target_transfer": target_transfer,
                "code_min": payload.get("code_min", 0),
                "code_max": payload.get("code_max", 255),
                "patch_settings": payload.get("patch_settings") if isinstance(payload.get("patch_settings"), dict) else None,
                "patch_count": len(profile_rows),
            },
            "status": "ok",
            "readings": reusable_rows,
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
        "target_transfer": target_transfer,
        "patches": len(rows),
        "white_nits": white["xyz"][1],
        "calibrated_white_nits": calibrated_white,
        "metadata_white_nits": metadata_white_rows[0]["xyz"][1] if metadata_white_rows else None,
        "black_nits": black["xyz"][1],
        "mhc2_matrix": matrix,
        "mhc2_lut_entries": len(adjustment_luts[0]) if adjustment_luts else None,
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

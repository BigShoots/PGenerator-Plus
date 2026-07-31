#!/usr/bin/env python3
"""Build display ICC profiles from PGenerator RGB/XYZ measurements.

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
    "windows-sdr": "Windows SDR hardware calibration",
    "kde-hdr": "KDE Plasma HDR",
    "windows-hdr": "Windows HDR",
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
    description = str(payload.get("name", "PGenerator display profile"))
    if payload.get("profile_type") == "windows-sdr":
        transfer = str(payload.get("target_transfer", "srgb")).lower()
        description += " (Windows SDR MHC2, {})".format(WINDOWS_SDR_TRANSFER_LABELS.get(transfer, "sRGB"))
    return description[:120]


def make_ti3(payload, rows):
    black, white, _ = profile_measurement_summary(rows)
    white_xyz = white["xyz"]
    white_y = white_xyz[1]
    instrument = cgats_quote(payload.get("meter_name", "PGenerator meter"))
    description = cgats_quote(profile_description(payload))
    created = datetime.datetime.now().strftime("%a %b %d %H:%M:%S %Y")
    lines = [
        "CTI3",
        "",
        'DESCRIPTOR "PGenerator measured display profile"',
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


def target_transfer_to_linear(value, transfer, black_ratio=0.0):
    value = max(0.0, min(1.0, value))
    if transfer == "srgb":
        return srgb_to_linear(value)
    if transfer == "gamma22":
        return value ** 2.2
    if transfer == "gamma24":
        return value ** 2.4
    if transfer == "bt1886":
        gamma = 2.4
        black_ratio = max(0.0, min(0.999, black_ratio))
        black_root = black_ratio ** (1.0 / gamma)
        span = max(1e-9, 1.0 - black_root)
        luminance = (span ** gamma) * ((value + black_root / span) ** gamma)
        return max(0.0, min(1.0, (luminance - black_ratio) / max(1e-9, 1.0 - black_ratio)))
    fail("Unsupported Windows SDR target transfer")


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
        fail("Windows SDR calibration requires black-to-primary channel ramps")
    # Fit a non-decreasing response with pool-adjacent-violators instead of a
    # cumulative maximum. Near-black readings are noisy; cumulative-max turns
    # one high sample into a permanent shoulder in the inverse calibration
    # curve, while isotonic regression distributes that noise across only the
    # conflicting samples.
    blocks = []
    for index, (_code, response) in enumerate(merged):
        blocks.append([index, index, response, 1.0])
        while len(blocks) >= 2 and blocks[-2][2] / blocks[-2][3] > blocks[-1][2] / blocks[-1][3]:
            right = blocks.pop()
            left = blocks.pop()
            blocks.append([left[0], right[1], left[2] + right[2], left[3] + right[3]])
    fitted = [0.0] * len(merged)
    for start, end, total, weight in blocks:
        value = max(0.0, min(1.0, total / weight))
        for index in range(start, end + 1):
            fitted[index] = value
    monotonic = [(merged[index][0], fitted[index]) for index in range(len(merged))]
    peak = monotonic[-1][1]
    if peak <= 1e-6:
        fail("Measured channel response has no usable range")
    return [(code, response / peak) for code, response in monotonic]


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


def windows_sdr_adjustment_luts(rows, black, white, primaries, entries, transfer):
    luts = []
    black_ratio = black["xyz"][1] / max(white["xyz"][1], 1e-9)
    for channel in range(3):
        samples = monotonic_channel_samples(rows, black, primaries[channel], channel)
        values = []
        previous = 0.0
        for index in range(entries):
            encoded = index / float(entries - 1)
            target = target_transfer_to_linear(encoded, transfer, black_ratio)
            value = invert_channel_response(samples, target)
            previous = max(previous, max(0.0, min(1.0, value)))
            values.append(previous)
        values[0] = 0.0
        values[-1] = 1.0
        luts.append(values)
    return luts


def mhc2_payload(profile_type, black, white, primaries, rows, target_transfer="srgb"):
    physical = measured_primary_matrix(black, white, primaries)
    if profile_type == "windows-hdr":
        wire = xy_matrix(((0.708, 0.292), (0.170, 0.797), (0.131, 0.046)), (0.3127, 0.3290))
    else:
        wire = xy_matrix(((0.640, 0.330), (0.300, 0.600), (0.150, 0.060)), (0.3127, 0.3290))
    adjustment = mat_mul(wire, mat_inv(physical))
    entries = 256
    header_size = 36
    matrix_offset = header_size
    lut0_offset = matrix_offset + 48
    lut_bytes = 8 + entries * 4
    offsets = (lut0_offset, lut0_offset + lut_bytes, lut0_offset + 2 * lut_bytes)
    min_luminance = max(0.0, black["xyz"][1])
    peak_luminance = max(white["xyz"][1], min_luminance + 0.0001)
    data = bytearray(b"MHC2" + b"\0\0\0\0")
    data.extend(struct.pack(">I", entries))
    data.extend(s15fixed16(min_luminance))
    data.extend(s15fixed16(peak_luminance))
    data.extend(struct.pack(">IIII", matrix_offset, *offsets))
    for row in adjustment:
        for value in (row[0], row[1], row[2], 0.0):
            data.extend(s15fixed16(value))
    # MHC2 curves operate after Windows applies the wire transfer function.
    # HDR keeps identity curves so PQ is not applied twice. SDR inverts each
    # measured channel ramp so the resulting scanout follows the sRGB wire
    # response while the matrix corrects primaries and white point.
    if profile_type == "windows-sdr":
        luts = windows_sdr_adjustment_luts(rows, black, white, primaries, entries, target_transfer)
    else:
        luts = [[index / float(entries - 1) for index in range(entries)] for _channel in range(3)]
    for values in luts:
        data.extend(b"sf32" + b"\0\0\0\0")
        for value in values:
            data.extend(s15fixed16(value))
    return bytes(data), adjustment, luts


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


def safe_basename(name):
    cleaned = SAFE_NAME.sub("_", str(name)).strip(" ._-").replace(" ", "_")
    if not cleaned:
        cleaned = "PGenerator display profile"
    return cleaned[:80]


def run_colprof(payload, ti3, output_path):
    colprof = os.environ.get("PGEN_COLPROF", "/usr/bin/colprof")
    if not os.path.isfile(colprof) or not os.access(colprof, os.X_OK):
        fail("The bundled ArgyllCMS colprof executable is unavailable")
    description = profile_description(payload).replace('"', "'")
    temp_dir = tempfile.mkdtemp(prefix="pgen_icc_")
    try:
        base = os.path.join(temp_dir, "profile")
        with io.open(base + ".ti3", "w", encoding="ascii", errors="replace") as handle:
            handle.write(ti3)
        command = [
            colprof, "-qm", "-as", "-A", "PGenerator+", "-M", PROFILE_TYPES[payload["profile_type"]],
            "-D", description, "-C", "Created from user measurements by PGenerator+", "-O", output_path, base,
        ]
        completed = subprocess.Popen(["timeout", "90"] + command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        output = completed.communicate()[0]
        if completed.returncode != 0 or not os.path.isfile(output_path):
            detail = (output or "").strip().splitlines()
            fail("ArgyllCMS profile creation failed" + (": " + detail[-1][:240] if detail else ""))
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


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
        fail("Unsupported Windows SDR target transfer")
    if profile_type != "windows-sdr":
        target_transfer = None
    rows = normalize_measurements(payload)
    full_frame_rows = [row for row in rows if row["name"] == "ICC Full Frame White"]
    profile_rows = [row for row in rows if row["name"] != "ICC Full Frame White"]
    if profile_type == "windows-hdr" and not full_frame_rows:
        fail("Windows HDR profiling requires a full-frame white measurement")
    ti3, black, white = make_ti3(payload, profile_rows)
    _, _, primaries = profile_measurement_summary(profile_rows)
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir, 0o755)
    stem = safe_basename(payload.get("name", "PGenerator display profile"))
    suffix = {
        "sdr": "SDR",
        "windows-sdr": "Windows-SDR-MHC2",
        "kde-hdr": "KDE-HDR",
        "windows-hdr": "Windows-HDR",
    }[profile_type]
    filename = "{}-{}.icc".format(stem, suffix)
    output_path = os.path.join(output_dir, filename)
    run_colprof(payload, ti3, output_path)
    matrix = None
    adjustment_luts = None
    if profile_type in ("windows-sdr", "windows-hdr"):
        with open(output_path, "rb") as handle:
            profile = handle.read()
        mhc2, matrix, adjustment_luts = mhc2_payload(profile_type, black, white, primaries, profile_rows, target_transfer or "srgb")
        # lumi is max full-frame luminance. SDR profiles use the measured
        # profiling white; HDR has a dedicated full-frame measurement.
        luminance = full_frame_rows[0]["xyz"][1] if full_frame_rows else white["xyz"][1]
        profile = rebuild_icc(profile, {b"MHC2": mhc2, b"lumi": xyz_tag((0.0, luminance, 0.0))})
        with open(output_path, "wb") as handle:
            handle.write(profile)
    size = os.path.getsize(output_path)
    return {
        "status": "ok",
        "file": filename,
        "size": size,
        "profile_type": profile_type,
        "target_transfer": target_transfer,
        "patches": len(rows),
        "white_nits": white["xyz"][1],
        "full_frame_white_nits": full_frame_rows[0]["xyz"][1] if full_frame_rows else None,
        "black_nits": black["xyz"][1],
        "mhc2_matrix": matrix,
        "mhc2_lut_entries": len(adjustment_luts[0]) if adjustment_luts else None,
    }


def main():
    if len(sys.argv) != 3:
        print(json.dumps({"status": "error", "message": "Usage: icc_profile_builder.py INPUT.json OUTPUT_DIR"}))
        return 2
    try:
        with io.open(sys.argv[1], "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        result = build(payload, sys.argv[2])
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (ValueError, OSError, IOError, subprocess.CalledProcessError) as error:
        print(json.dumps({"status": "error", "message": str(error)}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())

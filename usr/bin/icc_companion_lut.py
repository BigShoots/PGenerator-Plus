#!/usr/bin/env python3
"""Build a compact RGB correction LUT for PGenerator+ Patch Companion."""

import math
import os
import re
import struct
import sys


GRID = 65


def fail(message):
    raise ValueError(message)


def u32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def s15(data, offset):
    return struct.unpack_from(">i", data, offset)[0] / 65536.0


def tags(data):
    count = u32(data, 128)
    if count > 256 or 132 + count * 12 > len(data):
        fail("ICC tag table is invalid")
    result = {}
    for index in range(count):
        signature, offset, size = struct.unpack_from(">4sII", data, 132 + index * 12)
        if offset < 128 or size < 4 or offset + size > len(data):
            fail("ICC tag range is invalid")
        result[signature] = data[offset:offset + size]
    return result


def inverse3(matrix):
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(det) < 1e-12:
        fail("ICC matrix is singular")
    return [
        [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
        [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
        [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det],
    ]


def mat_vec(matrix, vector):
    return [sum(matrix[row][column] * vector[column] for column in range(3)) for row in range(3)]


def mat_mul(left, right):
    return [[sum(left[row][k] * right[k][column] for k in range(3)) for column in range(3)]
            for row in range(3)]


BRADFORD = (
    (0.8951, 0.2664, -0.1614),
    (-0.7502, 1.7135, 0.0367),
    (0.0389, -0.0685, 1.0296),
)


def chromatic_adaptation(source_white, destination_white):
    """Bradford adaptation from one white point to another."""
    source_cone = mat_vec(BRADFORD, source_white)
    destination_cone = mat_vec(BRADFORD, destination_white)
    if any(abs(value) < 1e-9 for value in source_cone):
        fail("Companion correction has a degenerate media white point")
    scale = [[0.0] * 3 for _ in range(3)]
    for index in range(3):
        scale[index][index] = destination_cone[index] / source_cone[index]
    return mat_mul(inverse3(BRADFORD), mat_mul(scale, BRADFORD))


def table_sample(table, value):
    value = max(0.0, min(1.0, value)) * (len(table) - 1)
    lower = min(len(table) - 2, int(value))
    fraction = value - lower
    return table[lower] * (1.0 - fraction) + table[lower + 1] * fraction


def curve_values(tag):
    if tag[:4] != b"curv" or len(tag) < 12:
        fail("ICC tone curve is unsupported")
    count = u32(tag, 8)
    if count == 0:
        return [0.0, 1.0]
    if count == 1:
        gamma = struct.unpack_from(">H", tag, 12)[0] / 256.0
        return [(index / 4095.0) ** gamma for index in range(4096)]
    if 12 + count * 2 > len(tag):
        fail("ICC tone curve is truncated")
    return [value / 65535.0 for value in struct.unpack_from(">{}H".format(count), tag, 12)]


def inverse_curve(table, value):
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


class MatrixTransform:
    def __init__(self, profile_tags):
        columns = []
        curves = []
        for xyz_name, curve_name in ((b"rXYZ", b"rTRC"), (b"gXYZ", b"gTRC"), (b"bXYZ", b"bTRC")):
            xyz = profile_tags.get(xyz_name, b"")
            if xyz[:4] != b"XYZ " or len(xyz) < 20:
                fail("ICC matrix fallback is unavailable")
            columns.append([s15(xyz, 8), s15(xyz, 12), s15(xyz, 16)])
            curves.append(curve_values(profile_tags.get(curve_name, b"")))
        self.inverse = inverse3([[columns[column][row] for column in range(3)] for row in range(3)])
        self.curves = curves

    def apply(self, xyz):
        linear = mat_vec(self.inverse, xyz)
        return [inverse_curve(self.curves[channel], linear[channel]) for channel in range(3)]


class Lut16Transform:
    def __init__(self, tag):
        if tag[:4] != b"mft2" or len(tag) < 52:
            fail("ICC BToA cLUT is unavailable or unsupported")
        self.inputs, self.outputs, self.grid = tag[8], tag[9], tag[10]
        if self.inputs != 3 or self.outputs != 3 or self.grid < 2:
            fail("ICC BToA cLUT dimensions are unsupported")
        self.matrix = [[s15(tag, 12 + (row * 3 + column) * 4) for column in range(3)] for row in range(3)]
        input_entries, output_entries = struct.unpack_from(">HH", tag, 48)
        if input_entries < 2 or output_entries < 2:
            fail("ICC BToA cLUT tables are invalid")
        offset = 52
        self.input_tables = []
        for _ in range(3):
            size = input_entries * 2
            if offset + size > len(tag):
                fail("ICC BToA input table is truncated")
            self.input_tables.append([value / 65535.0 for value in struct.unpack_from(">{}H".format(input_entries), tag, offset)])
            offset += size
        count = self.grid ** 3 * 3
        size = count * 2
        if offset + size > len(tag):
            fail("ICC BToA cLUT is truncated")
        self.clut = [value / 65535.0 for value in struct.unpack_from(">{}H".format(count), tag, offset)]
        offset += size
        self.output_tables = []
        for _ in range(3):
            size = output_entries * 2
            if offset + size > len(tag):
                fail("ICC BToA output table is truncated")
            self.output_tables.append([value / 65535.0 for value in struct.unpack_from(">{}H".format(output_entries), tag, offset)])
            offset += size

    def apply(self, xyz):
        # ICC v2 LUT16 encodes PCS XYZ over 0.0 through 1.99997.
        values = mat_vec(self.matrix, xyz)
        values = [table_sample(self.input_tables[channel], values[channel] / (65535.0 / 32768.0)) for channel in range(3)]
        base = []
        fraction = []
        for value in values:
            position = max(0.0, min(1.0, value)) * (self.grid - 1)
            lower = min(self.grid - 2, int(position))
            base.append(lower)
            fraction.append(position - lower)
        result = [0.0, 0.0, 0.0]
        for corner in range(8):
            weight = 1.0
            coordinate = []
            for axis in range(3):
                if corner & (1 << axis):
                    weight *= fraction[axis]
                    coordinate.append(base[axis] + 1)
                else:
                    weight *= 1.0 - fraction[axis]
                    coordinate.append(base[axis])
            offset = ((coordinate[0] * self.grid + coordinate[1]) * self.grid + coordinate[2]) * 3
            for channel in range(3):
                result[channel] += weight * self.clut[offset + channel]
        return [table_sample(self.output_tables[channel], result[channel]) for channel in range(3)]


def pq_linear(value):
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    power = max(0.0, min(1.0, value)) ** (1.0 / m2)
    return (max(power - c1, 0.0) / max(c2 - c3 * power, 1e-12)) ** (1.0 / m1)


def srgb_linear(value):
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


PCS_WHITE = (0.9642, 1.0, 0.8249)
SOURCE_WHITE_D65 = (0.9504559, 1.0, 1.0890578)
SRGB_TO_XYZ = (
    (0.4123908, 0.3575843, 0.1804808),
    (0.2126390, 0.7151687, 0.0721923),
    (0.0193308, 0.1191948, 0.9505322),
)
BT2020_TO_XYZ = (
    (0.6369580, 0.1446169, 0.1688810),
    (0.2627002, 0.6779981, 0.0593017),
    (0.0000000, 0.0280727, 1.0609851),
)


def characterization_white_nits(profile_tags):
    """Absolute luminance of the profile's PCS white.

    The measurement set is normalized so PCS Y=1.0 is the profiling white, and
    ArgyllCMS embeds that absolute value as LUMINANCE_XYZ_CDM2 in the retained
    characterization tags. The lumi tag is NOT interchangeable with it: for
    Windows HDR profiles the builder writes the MHC2-calibrated peak there,
    which is lower by the white-balance headroom the matrix takes. Normalizing
    PQ by lumi therefore asks the display for more light than was requested at
    every level.
    """
    for name in (b"targ", b"CIED", b"DevD"):
        tag = profile_tags.get(name, b"")
        if tag[:4] != b"text" or len(tag) < 12:
            continue
        match = re.search(
            br'LUMINANCE_XYZ_CDM2\s*"\s*[-0-9.eE+]+\s+([-0-9.eE+]+)', tag[8:])
        if not match:
            continue
        try:
            white_nits = float(match.group(1))
        except ValueError:
            continue
        if math.isfinite(white_nits) and white_nits > 0.0:
            return white_nits
    return None


def profile_luminance(profile_tags):
    white_nits = characterization_white_nits(profile_tags)
    if white_nits is not None:
        return white_nits
    luminance = profile_tags.get(b"lumi", b"")
    if luminance[:4] != b"XYZ " or len(luminance) < 20:
        fail("HDR Companion correction requires an ICC luminance tag")
    white_nits = s15(luminance, 12)
    if not math.isfinite(white_nits) or white_nits <= 0.0:
        fail("HDR Companion correction has an invalid ICC luminance tag")
    return white_nits


def source_xyz(rgb, signal_mode, white_nits, adaptation):
    if signal_mode == "hdr10":
        # ICC display PCS values are relative to the measured display white,
        # while PQ is absolute with 1.0 representing 10,000 cd/m2. Scale the
        # requested absolute light level into the selected profile's relative
        # PCS before evaluating its PCS-to-device transform.
        linear = [min(1.0, pq_linear(value) * 10000.0 / white_nits) for value in rgb]
        absolute_xyz = mat_vec(BT2020_TO_XYZ, linear)
    else:
        linear = [srgb_linear(value) for value in rgb]
        absolute_xyz = mat_vec(SRGB_TO_XYZ, linear)
    # Display BToA tables are relative-colorimetric and D50-referenced. Adapt
    # the requested absolute XYZ with the same transform the profile was built
    # with, so D65 is corrected to D65 rather than being remapped towards the
    # display's uncalibrated native white.
    return mat_vec(adaptation, absolute_xyz)


def make_transform(profile_path, method, signal_mode):
    if method not in ("clut", "matrix"):
        fail("Unsupported Companion correction method")
    if signal_mode not in ("sdr", "hdr10"):
        fail("Unsupported Companion correction signal mode")
    with open(profile_path, "rb") as handle:
        profile = handle.read()
    if len(profile) < 132 or profile[12:16] != b"mntr" or profile[16:20] != b"RGB " or profile[20:24] != b"XYZ ":
        fail("The selected file is not a supported RGB display profile with XYZ PCS")
    profile_tags = tags(profile)
    transform = Lut16Transform(profile_tags.get(b"B2A0", b"")) if method == "clut" else MatrixTransform(profile_tags)
    white_nits = profile_luminance(profile_tags) if signal_mode == "hdr10" else 1.0
    # Source RGB is D65 in both supported signal modes. The profile's media
    # white and chad describe its measured display, not the source colourspace.
    adaptation = chromatic_adaptation(SOURCE_WHITE_D65, PCS_WHITE)
    return transform, white_nits, adaptation


def write_atomic(output_path, payload):
    mode = "wb" if isinstance(payload, (bytes, bytearray)) else "w"
    temporary = output_path + ".tmp.{}".format(os.getpid())
    with open(temporary, mode) as handle:
        handle.write(payload)
    os.replace(temporary, output_path)


def build(profile_path, method, signal_mode, output_path):
    transform, white_nits, adaptation = make_transform(profile_path, method, signal_mode)
    output = bytearray(b"PGLT" + bytes((1, GRID, 3, 0)))
    output.extend(struct.pack(">I", GRID ** 3))
    output.extend(b"\0\0\0\0")
    for red in range(GRID):
        for green in range(GRID):
            for blue in range(GRID):
                rgb = (red / (GRID - 1.0), green / (GRID - 1.0), blue / (GRID - 1.0))
                corrected = transform.apply(source_xyz(rgb, signal_mode, white_nits, adaptation))
                for value in corrected:
                    output.extend(struct.pack(">H", int(round(max(0.0, min(1.0, value)) * 65535.0))))
    write_atomic(output_path, output)


def build_cube(profile_path, method, signal_mode, output_path, size, title=None):
    if size < 2 or size > 129:
        fail("Unsupported 3D LUT size")
    transform, white_nits, adaptation = make_transform(profile_path, method, signal_mode)
    if title is None:
        title = "{} {} ICC correction".format(
            re.sub(r"\.ic[cm]$", "", os.path.basename(profile_path), flags=re.I), signal_mode)
    lines = ['TITLE "{}"'.format(title.replace('"', "'")),
             "LUT_3D_SIZE {}".format(size),
             "DOMAIN_MIN 0.0 0.0 0.0",
             "DOMAIN_MAX 1.0 1.0 1.0"]
    # Standard .cube node order is red-fastest/blue-slowest -- the reverse of
    # the PGLT payload above. Keeping the PGLT nesting here would hand external
    # tools an R<->B swapped lattice whose neutral axis still looks correct.
    for blue in range(size):
        for green in range(size):
            for red in range(size):
                rgb = (red / (size - 1.0), green / (size - 1.0), blue / (size - 1.0))
                corrected = transform.apply(source_xyz(rgb, signal_mode, white_nits, adaptation))
                lines.append(" ".join(
                    "{:.9f}".format(max(0.0, min(1.0, value))) for value in corrected))
    write_atomic(output_path, "\n".join(lines) + "\n")


def main():
    if len(sys.argv) not in (5, 6):
        print("Usage: icc_companion_lut.py PROFILE clut|matrix sdr|hdr10 OUTPUT [CUBE_SIZE]", file=sys.stderr)
        return 2
    try:
        if len(sys.argv) == 6:
            build_cube(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
        else:
            build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
        return 0
    except (OSError, ValueError, struct.error) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

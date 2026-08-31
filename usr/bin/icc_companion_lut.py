#!/usr/bin/env python3
"""Build a compact RGB correction LUT for PGenerator+ Patch Companion."""

import math
import os
import re
import struct
import sys
import tempfile
from contextlib import contextmanager

# The Perl caller captures this tool's stderr, so an ImportError from a
# partial deploy is at least visible -- but as a multi-line traceback that
# reaches the operator verbatim. Answer with the one-line message main()
# already uses for every other failure, and exit non-zero.
try:
    import numpy as np

    from pgen_colour_math import (
        BRADFORD,
        D65_WHITE,
        ICC_D50_WHITE,
        PQ_C1,
        PQ_C2,
        PQ_C3,
        PQ_M1,
        PQ_M2,
        bradford_adaptation as shared_bradford_adaptation,
        matrix3_inverse,
        matrix3_multiply as mat_mul,
        matrix3_vector_multiply as mat_vec,
    )
except ImportError as import_error:
    print("Companion LUT builder cannot start: {}".format(import_error),
          file=sys.stderr)
    sys.exit(1)


GRID = 65

# Nodes evaluated per pass. A 65-cube is 274,625 nodes and a .cube can ask for
# 129^3; every stage below is elementwise or per-row, so the arithmetic is
# unchanged by the split, but holding a dozen live (N, 3) float64 temporaries
# at once is what the appliance cannot afford. Binary output reaches a stable
# throughput plateau at 8192 nodes. Formatted text is already on its plateau at
# 2048, which keeps its temporary strings and arrays smaller.
PGLT_NODE_CHUNK = 8192
CUBE_NODE_CHUNK = 2048


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
    # Keep the scalar operation order this replaced -- the pre-rewrite body,
    # recoverable with `git show upstream/main:usr/bin/icc_companion_lut.py`.
    # BLAS/LAPACK is excellent
    # for large systems, but a 3x3 inverse is setup work and changing its
    # reduction order can move a value across a 16-bit quantisation boundary.
    inverse = matrix3_inverse(matrix, determinant_tolerance=1e-12)
    if inverse is None:
        fail("ICC matrix is singular")
    return inverse


def mat_vec_many(matrix, vectors):
    """Apply a 3x3 matrix without handing reduction order to BLAS."""
    result = np.empty(vectors.shape, dtype=np.float64)
    for row in range(3):
        result[:, row] = (matrix[row][0] * vectors[:, 0]
                          + matrix[row][1] * vectors[:, 1]
                          + matrix[row][2] * vectors[:, 2])
    return result


def chromatic_adaptation(source_white, destination_white):
    """Bradford adaptation from one white point to another."""
    adaptation = shared_bradford_adaptation(
        source_white, destination_white, cone_tolerance=1e-9,
        inclusive=False)
    if adaptation is None:
        fail("Companion correction has a degenerate media white point")
    return adaptation


def table_sample(table, values):
    """Linear interpolation matching the scalar index/fraction clamping."""
    position = np.clip(values, 0.0, 1.0) * (len(table) - 1)
    lower = np.minimum(len(table) - 2, position.astype(np.intp))
    fraction = position - lower
    return table[lower] * (1.0 - fraction) + table[lower + 1] * fraction


def curve_values(tag):
    if tag[:4] != b"curv" or len(tag) < 12:
        fail("ICC tone curve is unsupported")
    count = u32(tag, 8)
    if count == 0:
        return np.array([0.0, 1.0])
    if count == 1:
        gamma = struct.unpack_from(">H", tag, 12)[0] / 256.0
        return (np.arange(4096) / 4095.0) ** gamma
    if 12 + count * 2 > len(tag):
        fail("ICC tone curve is truncated")
    return np.frombuffer(tag, dtype=">u2", count=count, offset=12) / 65535.0


def inverse_curve(table, values):
    """Invert a tone curve by running the scalar bisection on every node at once.

    np.searchsorted would be shorter but is only defined for sorted input, and
    a curv tag in a supplied display profile is not guaranteed monotonic. On a
    curve that dips, searchsorted picks a different bracket from the bisection
    this replaced and the LUT moves by tens of 8-bit codes. The loop below
    makes the same comparisons the scalar code made, in the same order, so the
    result is identical for monotonic and non-monotonic curves alike.
    """
    values = np.asarray(values, dtype=np.float64)
    # The scalar clamp was max(0.0, min(1.0, value)), which turns a NaN into
    # 1.0; np.clip would propagate it, so the NaN case is restored explicitly.
    values = np.where(np.isnan(values), 1.0, np.clip(values, 0.0, 1.0))
    low = np.zeros(values.shape, dtype=np.intp)
    high = np.full(values.shape, len(table) - 1, dtype=np.intp)
    # Every element starts on the same bracket but an odd width splits
    # unevenly, so nodes settle after different iteration counts; "active"
    # freezes each one exactly where "while high - low > 1" ended for it.
    active = high - low > 1
    while active.any():
        middle = (low + high) // 2
        below = table[middle] < values
        low = np.where(active & below, middle, low)
        high = np.where(active & ~below, middle, high)
        active = high - low > 1
    y0 = table[low]
    y1 = table[high]
    span = y1 - y0
    fraction = np.where(span > 0.0, (values - y0) / np.where(span > 0.0, span, 1.0), 0.0)
    return (low + np.clip(fraction, 0.0, 1.0)) / (len(table) - 1)


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
        self.inverse = inverse3([[columns[column][row]
                                 for column in range(3)] for row in range(3)])
        self.curves = curves

    def apply(self, xyz):
        linear = mat_vec_many(self.inverse, xyz)
        return np.stack([inverse_curve(self.curves[channel], linear[:, channel])
                         for channel in range(3)], axis=1)


class Lut16Transform:
    def __init__(self, tag):
        if tag[:4] != b"mft2" or len(tag) < 52:
            fail("ICC BToA cLUT is unavailable or unsupported")
        self.inputs, self.outputs, self.grid = tag[8], tag[9], tag[10]
        if self.inputs != 3 or self.outputs != 3 or self.grid < 2:
            fail("ICC BToA cLUT dimensions are unsupported")
        self.matrix = [[s15(tag, 12 + (row * 3 + column) * 4)
                        for column in range(3)] for row in range(3)]
        input_entries, output_entries = struct.unpack_from(">HH", tag, 48)
        if input_entries < 2 or output_entries < 2:
            fail("ICC BToA cLUT tables are invalid")
        offset = 52
        self.input_tables = []
        for _ in range(3):
            size = input_entries * 2
            if offset + size > len(tag):
                fail("ICC BToA input table is truncated")
            self.input_tables.append(
                np.frombuffer(tag, dtype=">u2", count=input_entries, offset=offset) / 65535.0)
            offset += size
        count = self.grid ** 3 * 3
        size = count * 2
        if offset + size > len(tag):
            fail("ICC BToA cLUT is truncated")
        self.clut = (np.frombuffer(tag, dtype=">u2", count=count, offset=offset) / 65535.0
                     ).reshape(self.grid, self.grid, self.grid, 3)
        offset += size
        self.output_tables = []
        for _ in range(3):
            size = output_entries * 2
            if offset + size > len(tag):
                fail("ICC BToA output table is truncated")
            self.output_tables.append(
                np.frombuffer(tag, dtype=">u2", count=output_entries, offset=offset) / 65535.0)
            offset += size

    def apply(self, xyz):
        # ICC v2 LUT16 encodes PCS XYZ over 0.0 through 1.99997.
        values = mat_vec_many(self.matrix, xyz)
        values = np.stack([table_sample(self.input_tables[channel],
                                        values[:, channel] / (65535.0 / 32768.0))
                           for channel in range(3)], axis=1)
        position = np.clip(values, 0.0, 1.0) * (self.grid - 1)
        base = np.minimum(self.grid - 2, position.astype(np.intp))
        fraction = position - base
        result = np.zeros_like(values)
        for corner in range(8):
            weight = np.ones(len(values))
            coordinate = []
            for axis in range(3):
                if corner & (1 << axis):
                    weight = weight * fraction[:, axis]
                    coordinate.append(base[:, axis] + 1)
                else:
                    weight = weight * (1.0 - fraction[:, axis])
                    coordinate.append(base[:, axis])
            result += weight[:, None] * self.clut[coordinate[0], coordinate[1], coordinate[2]]
        return np.stack([table_sample(self.output_tables[channel], result[:, channel])
                         for channel in range(3)], axis=1)


def pq_linear(values):
    power = np.clip(values, 0.0, 1.0) ** (1.0 / PQ_M2)
    return (np.maximum(power - PQ_C1, 0.0)
            / np.maximum(PQ_C2 - PQ_C3 * power, 1e-12)) ** (1.0 / PQ_M1)


def srgb_linear(values):
    return np.where(values <= 0.04045, values / 12.92,
                    ((np.maximum(values, 0.04045) + 0.055) / 1.055) ** 2.4)


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
        linear = np.minimum(1.0, pq_linear(rgb) * 10000.0 / white_nits)
        absolute_xyz = mat_vec_many(BT2020_TO_XYZ, linear)
    else:
        linear = srgb_linear(rgb)
        absolute_xyz = mat_vec_many(SRGB_TO_XYZ, linear)
    # Display BToA tables are relative-colorimetric and D50-referenced. Adapt
    # the requested absolute XYZ with the same transform the profile was built
    # with, so D65 is corrected to D65 rather than being remapped towards the
    # display's uncalibrated native white.
    return mat_vec_many(adaptation, absolute_xyz)


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
    adaptation = chromatic_adaptation(D65_WHITE, ICC_D50_WHITE)
    return transform, white_nits, adaptation


@contextmanager
def atomic_writer(output_path, binary):
    """Yield a symlink-safe 0600 sibling and replace output only on success."""
    directory = os.path.dirname(os.path.abspath(output_path))
    prefix = ".{}.tmp.".format(os.path.basename(output_path))
    descriptor, temporary = tempfile.mkstemp(prefix=prefix, dir=directory)
    handle = None
    try:
        handle = os.fdopen(descriptor, "wb" if binary else "w")
        descriptor = None
        yield handle
        handle.close()
        handle = None
        os.replace(temporary, output_path)
        temporary = None
    finally:
        if handle is not None:
            handle.close()
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def write_atomic(output_path, payload):
    with atomic_writer(output_path, isinstance(payload, (bytes, bytearray))) as handle:
        handle.write(payload)


def lattice_coordinates(size, start, stop, red_fastest):
    """One float64 coordinate block in the requested exact nesting order."""
    index = np.arange(start, stop, dtype=np.int64)
    if red_fastest:
        blue = index // (size * size)
        green = (index // size) % size
        red = index % size
    else:
        red = index // (size * size)
        green = (index // size) % size
        blue = index % size
    return np.stack((red, green, blue), axis=1).astype(
        np.float64) / (size - 1.0)


def quantize_u16(values):
    """Quantize to big-endian u16 exactly as the scalar clamp-then-round did.

    np.rint and int(round(x)) both round half to even, and the clip means the
    scaled value can never leave the u16 range, so no second clamp is needed.
    """
    return np.rint(np.clip(values, 0.0, 1.0) * 65535.0).astype(">u2")


def corrected_nodes(transform, size, red_fastest, signal_mode, white_nits,
                    adaptation, chunk_size):
    """Evaluate the lattice a chunk at a time, yielding each corrected block."""
    total = size ** 3
    for start in range(0, total, chunk_size):
        block = lattice_coordinates(
            size, start, min(total, start + chunk_size), red_fastest)
        yield transform.apply(
            source_xyz(block, signal_mode, white_nits, adaptation))


def build(profile_path, method, signal_mode, output_path):
    transform, white_nits, adaptation = make_transform(profile_path, method, signal_mode)
    output = bytearray(b"PGLT" + bytes((1, GRID, 3, 0)))
    output.extend(struct.pack(">I", GRID ** 3))
    output.extend(b"\0\0\0\0")
    for corrected in corrected_nodes(
            transform, GRID, False, signal_mode, white_nits, adaptation,
            PGLT_NODE_CHUNK):
        output.extend(quantize_u16(corrected).tobytes())
    write_atomic(output_path, output)


def build_cube(profile_path, method, signal_mode, output_path, size, title=None):
    if size < 2 or size > 129:
        fail("Unsupported 3D LUT size")
    transform, white_nits, adaptation = make_transform(profile_path, method, signal_mode)
    if title is None:
        title = "{} {} ICC correction".format(
            re.sub(r"\.ic[cm]$", "", os.path.basename(profile_path), flags=re.I), signal_mode)
    header = '\n'.join([
        'TITLE "{}"'.format(title.replace('"', "'")),
        "LUT_3D_SIZE {}".format(size),
        "DOMAIN_MIN 0.0 0.0 0.0",
        "DOMAIN_MAX 1.0 1.0 1.0",
    ]) + '\n'
    # Standard .cube node order is red-fastest/blue-slowest -- the reverse of
    # the PGLT payload above. Keeping the PGLT nesting here would hand external
    # tools an R<->B swapped lattice whose neutral axis still looks correct.
    with atomic_writer(output_path, binary=False) as handle:
        handle.write(header)
        for corrected in corrected_nodes(
                transform, size, True, signal_mode, white_nits, adaptation,
                CUBE_NODE_CHUNK):
            clipped = np.clip(corrected, 0.0, 1.0)
            handle.write("".join(
                "{:.9f} {:.9f} {:.9f}\n".format(row[0], row[1], row[2])
                for row in clipped))


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

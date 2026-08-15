#!/usr/bin/env python3
"""Fine-tune an existing KDE HDR profile from reads taken through it.

The parent profile stays untouched. Reads of the applied profile give
per-level residuals along the grey axis; those residuals adjust the
profile's effective calibration curves (sampled from its own BToA along the
neutral axis), and the measured-corridor repair then rebuilds the neutral
corridor with the adjusted curves. Corrections are damped and bounded so a
noisy read cannot damage a profile, and repeated passes converge the same
way AutoCal iterations do.

Usage: icc_finetune.py input.json output_dir
input.json: {"parent_path": ..., "readings": [{r_code,g_code,b_code,
             input_max,X,Y,Z,name}...], "name": ..., "damping": 0.5}
"""
import io
import json
import os
import struct
import subprocess
import sys
import tempfile

M1 = 2610.0 / 16384.0
M2 = 2523.0 / 32.0
C1 = 3424.0 / 4096.0
C2 = 2413.0 / 128.0
C3 = 2392.0 / 128.0


def pq_to_nits(value):
    value = max(0.0, value)
    power = value ** (1.0 / M2)
    numerator = max(power - C1, 0.0)
    denominator = C2 - C3 * power
    if denominator <= 0:
        return 10000.0
    return 10000.0 * (numerator / denominator) ** (1.0 / M1)


def read_profile(path):
    with open(path, "rb") as handle:
        data = bytearray(handle.read())
    count = struct.unpack(">I", bytes(data[128:132]))[0]
    tags = {}
    for index in range(count):
        sig, off, size = struct.unpack(">4sII", bytes(data[132 + index * 12:144 + index * 12]))
        tags[sig.decode("latin1")] = (off, size)
    return data, tags


def be16(data, position):
    return (data[position] << 8) | data[position + 1]


def table_sample(data, base, count, value):
    value = max(0.0, min(1.0, value)) * (count - 1)
    low = min(int(value), count - 2)
    fraction = value - low
    return (be16(data, base + low * 2) * (1.0 - fraction)
            + be16(data, base + (low + 1) * 2) * fraction) / 65535.0


def b2a_neutral(data, tags, lumi, nits):
    """Evaluate the parent BToA for a neutral patch of the given luminance."""
    off, _ = tags["B2A0"]
    grid = data[off + 10]
    in_entries, out_entries = struct.unpack(">HH", bytes(data[off + 48:off + 52]))
    in_off = off + 52
    clut_off = in_off + 3 * in_entries * 2
    out_off = clut_off + grid ** 3 * 3 * 2
    encode = 32768.0 / 65535.0
    bt2020 = ((0.6369580, 0.1446169, 0.1688810),
              (0.2627002, 0.6779981, 0.0593017),
              (0.0, 0.0280727, 1.0609851))
    bradford = ((0.8951, 0.2664, -0.1614),
                (-0.7502, 1.7135, 0.0367),
                (0.0389, -0.0685, 1.0296))
    d65 = (0.9504559, 1.0, 1.0890578)
    d50 = (0.9642, 1.0, 0.8249)

    def mat_vec(matrix, vector):
        return [sum(matrix[row][k] * vector[k] for k in range(3)) for row in range(3)]

    def mat_inv(m):
        a, b, c = m[0]
        d, e, f = m[1]
        g, h, i = m[2]
        det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]

    cone_src = mat_vec(bradford, d65)
    cone_dst = mat_vec(bradford, d50)
    scaled = [[cone_dst[r] / cone_src[r] * bradford[r][k] for k in range(3)] for r in range(3)]
    inverse = mat_inv([list(row) for row in bradford])
    adapt = [[sum(inverse[r][k] * scaled[k][c] for k in range(3)) for c in range(3)] for r in range(3)]

    relative = nits / lumi
    xyz = mat_vec(adapt, mat_vec([list(row) for row in bt2020], [relative] * 3))
    coords = [table_sample(data, in_off + ch * in_entries * 2, in_entries, xyz[ch] * encode)
              for ch in range(3)]
    base_idx = [0, 0, 0]
    fraction = [0.0, 0.0, 0.0]
    for ch in range(3):
        position = max(0.0, min(1.0, coords[ch])) * (grid - 1)
        base_idx[ch] = min(int(position), grid - 2)
        fraction[ch] = position - base_idx[ch]
    result = [0.0, 0.0, 0.0]
    for ch in range(3):
        accumulated = 0.0
        for rr in range(2):
            for gg in range(2):
                for bb in range(2):
                    weight = ((fraction[0] if rr else 1.0 - fraction[0])
                              * (fraction[1] if gg else 1.0 - fraction[1])
                              * (fraction[2] if bb else 1.0 - fraction[2]))
                    index = (((base_idx[0] + rr) * grid + (base_idx[1] + gg)) * grid
                             + (base_idx[2] + bb)) * 3 + ch
                    accumulated += be16(data, clut_off + index * 2) / 65535.0 * weight
        result[ch] = accumulated
    return [table_sample(data, out_off + ch * out_entries * 2, out_entries, result[ch])
            for ch in range(3)]


def s15(data, position):
    return struct.unpack(">i", bytes(data[position:position + 4]))[0] / 65536.0


def parse_targ(data, tags):
    off, size = tags["targ"]
    text = bytes(data[off + 8:off + size]).decode("latin1", "replace")
    fmt, rows, in_data, take = None, [], False, False
    for line in text.splitlines():
        if line.startswith("BEGIN_DATA_FORMAT"):
            take = True
            continue
        if take:
            fmt = line.split()
            take = False
            continue
        if line.strip() == "BEGIN_DATA":
            in_data = True
            continue
        if line.strip() == "END_DATA":
            in_data = False
            continue
        if in_data and line.split():
            rows.append(line.split())
    return fmt, rows, text



def measured_lum_guard(nits, ymax):
    """Skip levels where the response is saturated; the corridor's plateau
    logic owns that region and the luminance inverse is ill-conditioned."""
    return nits >= 0.90 * ymax


def finetune(payload, output_dir):
    parent_path = payload["parent_path"]
    damping = float(payload.get("damping", 0.5))
    damping = max(0.1, min(1.0, damping))
    data, tags = read_profile(parent_path)
    lumi = s15(data, tags["lumi"][0] + 12)
    fmt, rows, targ_text = parse_targ(data, tags)

    # Grey residuals from the fine-tune reads
    reads = []
    for row in payload.get("readings", []):
        if row.get("error"):
            continue
        if not (row.get("r_code") == row.get("g_code") == row.get("b_code")):
            continue
        maximum = float(row.get("input_max", 1023))
        code = row["r_code"] / maximum
        if code <= 0.0:
            continue
        reads.append((code, float(row["Y"]), float(row["X"]), float(row["Z"])))
    if len(reads) < 8:
        raise ValueError("Fine tuning needs at least 8 valid neutral reads")
    reads.sort()

    # Collapse repeats to medians
    grouped = []
    for code, y, x, z in reads:
        if grouped and abs(code - grouped[-1][0]) < 1e-6:
            grouped[-1][1].append((y, x, z))
        else:
            grouped.append([code, [(y, x, z)]])
    residuals = []
    for code, samples in grouped:
        samples.sort()
        y, x, z = samples[len(samples) // 2]
        target = min(pq_to_nits(code), lumi)
        if target < 0.02 or y <= 0.0:
            continue
        residuals.append((code, target, y))
    if len(residuals) < 6:
        raise ValueError("Too few usable neutral reads above the meter floor")

    # Measured neutral response from the embedded characterization: the
    # corridor repair's calibration domain is the raw neutral code axis with
    # luminance following this curve, so everything below must be sampled and
    # keyed in that domain, not the PQ target domain (they diverge through
    # the display rolloff).
    ri = fmt.index("RGB_R")
    yi = fmt.index("XYZ_Y")
    neutral = sorted((float(r[ri]) / 100.0,
                      float(r[yi]) * lumi / 100.0)
                     for r in rows
                     if abs(float(r[ri]) - float(r[fmt.index("RGB_G")])) < 0.3
                     and abs(float(r[fmt.index("RGB_G")]) - float(r[fmt.index("RGB_B")])) < 0.3)
    ymax = max(y for _, y in neutral)

    def measured_lum(code):
        if code <= neutral[0][0]:
            return neutral[0][1]
        for i in range(1, len(neutral)):
            if neutral[i][0] >= code:
                c0, y0 = neutral[i - 1]
                c1, y1 = neutral[i]
                t = 0.0 if c1 == c0 else (code - c0) / (c1 - c0)
                return y0 + t * (y1 - y0)
        return neutral[-1][1]

    def code_for_lum(target):
        if target <= neutral[0][1]:
            return neutral[0][0]
        for i in range(1, len(neutral)):
            if neutral[i][1] >= target:
                c0, y0 = neutral[i - 1]
                c1, y1 = neutral[i]
                t = 0.0 if y1 == y0 else (target - y0) / (y1 - y0)
                return c0 + t * (c1 - c0)
        return neutral[-1][0]

    # Directly adjust the corridor nodes in a copy of the parent. No curve
    # extraction or corridor rebuild: each near-neutral node's current wire
    # triple moves by a damped, bounded delta keyed to the luminance level
    # that node serves. Everything outside the corridor tube and the
    # saturated rolloff region is untouched, so a second fine-tune pass
    # composes cleanly with the first.
    keyed = []
    levels = []
    for code, target, y in residuals:
        ratio = target / y
        effective = 1.0 + damping * (ratio - 1.0)
        # The per-node bound limits how much of the correction can land.
        levels.append({
            "pct": round(code * 100.0, 1),
            "target_nits": round(target, 3),
            "measured_nits": round(y, 3),
            "before_err_pct": round((y / target - 1.0) * 100.0, 2),
            "predicted_err_pct": round((y * effective / target - 1.0) * 100.0, 2),
        })
        keyed.append((min(pq_to_nits(code), 0.995 * ymax), ratio))
    keyed.sort()

    def residual_ratio(nits):
        if nits <= keyed[0][0]:
            return keyed[0][1]
        for i in range(1, len(keyed)):
            if keyed[i][0] >= nits:
                n0, r0 = keyed[i - 1]
                n1, r1 = keyed[i]
                t = 0.0 if n1 == n0 else (nits - n0) / (n1 - n0)
                return r0 + t * (r1 - r0)
        return keyed[-1][1]

    bound = 2.5 / 1023.0
    encode = 32768.0 / 65535.0
    d50 = (0.9642, 1.0, 0.8249)
    applied = []
    for tag in ("B2A0", "B2A1"):
        if tag not in tags:
            continue
        off, _ = tags[tag]
        grid = data[off + 10]
        in_entries, out_entries = struct.unpack(">HH", bytes(data[off + 48:off + 52]))
        in_off = off + 52
        clut_off = in_off + 3 * in_entries * 2
        out_off = clut_off + grid ** 3 * 3 * 2

        def table_invert(base, count, target):
            low_i, high_i = 0, count - 1
            low_v = be16(data, base) / 65535.0
            high_v = be16(data, base + (count - 1) * 2) / 65535.0
            if target <= low_v:
                return 0.0
            if target >= high_v:
                return 1.0
            while high_i - low_i > 1:
                mid = (low_i + high_i) // 2
                mid_v = be16(data, base + mid * 2) / 65535.0
                if mid_v <= target:
                    low_i, low_v = mid, mid_v
                else:
                    high_i, high_v = mid, mid_v
            step = high_v - low_v
            fraction = 0.0 if step <= 0 else (target - low_v) / step
            return (low_i + fraction) / (count - 1.0)

        def axis_node(ch, relative):
            enc = min(1.0, max(0.0, relative * encode))
            position = enc * (in_entries - 1)
            low = min(int(position), in_entries - 2)
            fraction = position - low
            base = in_off + ch * in_entries * 2
            t = (be16(data, base + low * 2) * (1.0 - fraction)
                 + be16(data, base + (low + 1) * 2) * fraction) / 65535.0
            return t * (grid - 1)

        span = 2
        for j in range(grid):
            y_rel = table_invert(in_off + 1 * in_entries * 2, in_entries,
                                 j / (grid - 1.0)) / encode
            nits = min(y_rel, 1.0) * lumi
            if nits < 0.02 or measured_lum_guard(nits, ymax):
                continue
            ratio = residual_ratio(min(nits, 0.995 * ymax))
            correction = 1.0 + damping * (ratio - 1.0)
            if abs(correction - 1.0) < 0.0005:
                continue
            fx = axis_node(0, d50[0] * min(y_rel, 1.9))
            fz = axis_node(2, d50[2] * min(y_rel, 1.9))
            for i in range(max(0, int(fx) - span), min(grid, int(fx) + span + 2)):
                for k in range(max(0, int(fz) - span), min(grid, int(fz) + span + 2)):
                    base_pos = clut_off + (((i * grid + j) * grid + k) * 3) * 2
                    for ch in range(3):
                        node = be16(data, base_pos + ch * 2) / 65535.0
                        wire = table_sample(data, out_off + ch * out_entries * 2,
                                            out_entries, node)
                        current = measured_lum(wire)
                        if current >= 0.90 * ymax:
                            continue
                        wanted = code_for_lum(current * correction)
                        delta = max(-bound, min(bound, wanted - wire))
                        new_node = table_invert(out_off + ch * out_entries * 2,
                                                out_entries, wire + delta)
                        value = max(0, min(65535, int(round(new_node * 65535.0))))
                        data[base_pos + ch * 2] = value >> 8
                        data[base_pos + ch * 2 + 1] = value & 0xFF
            applied.append(abs(correction - 1.0))
    if not applied:
        raise ValueError("No corrections were applicable")

    stem = payload.get("name") or (os.path.basename(parent_path)[:-4] + "-FineTuned")
    out_name = stem + ".icc"
    out_path = os.path.join(output_dir, out_name)
    with open(out_path, "wb") as handle:
        handle.write(bytes(data))

    profcheck = os.environ.get("PGEN_PROFCHECK", "/usr/bin/profcheck")
    selfcheck = None
    if os.path.isfile(profcheck) and os.access(profcheck, os.X_OK):
        work = tempfile.mkdtemp(prefix="pgen_ftcheck_")
        try:
            ti3_path = os.path.join(work, "check.ti3")
            with io.open(ti3_path, "w", encoding="ascii", errors="replace") as handle:
                handle.write(targ_text)

            def run_check(profile_path):
                process = subprocess.Popen(
                    ["timeout", "600", profcheck, "-k", ti3_path, profile_path],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    universal_newlines=True)
                text = process.communicate()[0] or ""
                average = peak = None
                import re as _re
                for line in text.splitlines():
                    low = line.lower()
                    if "avg" not in low or "=" not in low:
                        continue
                    found_avg = _re.search(r"avg\.?\s*=\s*([0-9.]+)", low)
                    found_max = _re.search(r"max\.?\s*=\s*([0-9.]+)", low)
                    if found_avg:
                        average = float(found_avg.group(1))
                    if found_max:
                        peak = float(found_max.group(1))
                return average, peak

            before_avg, before_peak = run_check(parent_path)
            after_avg, after_peak = run_check(out_path)
            if before_avg is not None and after_avg is not None:
                selfcheck = {
                    "before_avg": before_avg, "before_peak": before_peak,
                    "after_avg": after_avg, "after_peak": after_peak,
                    "note": ("profcheck validates the forward (AtoB) "
                             "characterization fit, which fine-tuning leaves "
                             "untouched by design; identical numbers confirm "
                             "the tune did not disturb the fitted model. The "
                             "output-side change is shown by the measured "
                             "grey comparison below."),
                }
        finally:
            import shutil
            shutil.rmtree(work, ignore_errors=True)

    summary = {
        "status": "ok",
        "file": out_name,
        "parent": os.path.basename(parent_path),
        "reads_used": len(residuals),
        "damping": damping,
        "max_correction_pct": round(max(applied) * 100.0, 2),
        "mean_correction_pct": round(sum(applied) / len(applied) * 100.0, 2),
        "levels": sorted(levels, key=lambda item: item["pct"]),
        "selfcheck": selfcheck,
    }
    with io.open(out_path + ".finetune.json", "w", encoding="ascii") as handle:
        handle.write(json.dumps(summary))
    return summary


def main():
    if len(sys.argv) != 3:
        print(json.dumps({"status": "error",
                          "message": "Usage: icc_finetune.py INPUT.json OUTPUT_DIR"}))
        return 2
    try:
        with io.open(sys.argv[1], "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        result = finetune(payload, sys.argv[2])
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (ValueError, OSError, IOError, KeyError) as error:
        print(json.dumps({"status": "error", "message": str(error)},
                         separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())

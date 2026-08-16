#!/usr/bin/env python3
"""Fine-tune an existing display profile from reads taken through it.

The parent profile stays untouched. Reads of the applied profile give
per-level residuals along the grey axis. Each residual is decomposed into
per-channel gains through the panel's measured primaries, so the tune
corrects chromatic drift as well as luminance. Three profile classes are
supported, selected from the parent's own tags:

- HDR cLUT profiles (cicp + B2A0): corridor nodes in the BToA tables move
  by damped, bounded per-channel deltas. Below the display's rolloff the
  target is absolute PQ; inside the rolloff the luminance is pinned by the
  panel, so gains are normalised to drops and only the white balance of
  the plateau is corrected.
- MHC2 profiles: the corrections land in the MHC2 per-channel adjustment
  curves (and the cloned vcgt when present) in the wire signal domain,
  which is the stage Windows and the patched KWin actually apply.
- SDR cLUT profiles (no PQ cicp): identical corridor treatment with
  targets from the profile white and the transfer the parent was built
  against, instead of PQ.

The request does not name that transfer, so it is recovered from the
profile: the validation sidecar first, then the measurements sidecar, then
the marker in the ICC description.

Corrections are damped and bounded so a noisy read cannot damage a
profile, and repeated passes converge the same way AutoCal iterations do.

Usage: icc_finetune.py input.json output_dir
input.json: {"parent_path": ..., "readings": [{r_code,g_code,b_code,
             input_max,X,Y,Z,name}...], "name": ..., "damping": 0.5,
             "target_transfer": optional override}
"""
import io
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile

M1 = 2610.0 / 16384.0
M2 = 2523.0 / 32.0
C1 = 3424.0 / 4096.0
C2 = 2413.0 / 128.0
C3 = 2392.0 / 128.0

D65_X = 0.3127
D65_Y = 0.3290


def pq_to_nits(value):
    value = max(0.0, value)
    power = value ** (1.0 / M2)
    numerator = max(power - C1, 0.0)
    denominator = C2 - C3 * power
    if denominator <= 0:
        return 10000.0
    return 10000.0 * (numerator / denominator) ** (1.0 / M1)


def nits_to_pq(nits):
    y = max(0.0, min(1.0, nits / 10000.0)) ** M1
    return ((C1 + C2 * y) / (1.0 + C3 * y)) ** M2


XYZ_TO_RGB2020 = [[1.7166512, -0.3556708, -0.2533663],
                  [-0.6666844, 1.6164812, 0.0157685],
                  [0.0176399, -0.0427706, 0.9421031]]
RGB_TO_LMS = [[1688.0 / 4096, 2146.0 / 4096, 262.0 / 4096],
              [683.0 / 4096, 2951.0 / 4096, 462.0 / 4096],
              [99.0 / 4096, 309.0 / 4096, 3688.0 / 4096]]


def de_itp(xyz_a, xyz_b):
    """BT.2124 colour difference between two absolute XYZ stimuli."""
    def itp(xyz):
        rgb = [sum(XYZ_TO_RGB2020[r][k] * xyz[k] for k in range(3)) for r in range(3)]
        lms = [sum(RGB_TO_LMS[r][k] * max(0.0, rgb[k]) for k in range(3)) for r in range(3)]
        lp = [nits_to_pq(c) for c in lms]
        return (0.5 * lp[0] + 0.5 * lp[1],
                0.5 * (6610 * lp[0] - 13613 * lp[1] + 7003 * lp[2]) / 4096.0,
                (17933 * lp[0] - 17390 * lp[1] - 543 * lp[2]) / 4096.0)
    pa, pb = itp(xyz_a), itp(xyz_b)
    return 720.0 * math.sqrt(sum((x - y) ** 2 for x, y in zip(pa, pb)))


REF_NITS = 203.0
LAB_WHITE = [0.95047 * REF_NITS, 1.0 * REF_NITS, 1.08883 * REF_NITS]


def _lab(xyz):
    def f(t):
        return t ** (1.0 / 3.0) if t > (6.0 / 29.0) ** 3 else t / (3 * (6.0 / 29.0) ** 2) + 4.0 / 29.0
    fx, fy, fz = (f(max(1e-9, xyz[i] / LAB_WHITE[i])) for i in range(3))
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]


def de2000(xyz_a, xyz_b):
    """CIEDE2000 against a 203 cd/m2 diffuse white - the metric colour
    acceptance is judged in, so convergence is measured the same way."""
    l1, a1, b1 = _lab(xyz_a)
    l2, a2, b2 = _lab(xyz_b)
    c1 = math.hypot(a1, b1)
    c2 = math.hypot(a2, b2)
    cm = (c1 + c2) / 2.0
    g = 0.5 * (1 - math.sqrt(cm ** 7 / (cm ** 7 + 25.0 ** 7))) if cm > 0 else 0.0
    a1p, a2p = a1 * (1 + g), a2 * (1 + g)
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1 = math.degrees(math.atan2(b1, a1p)) % 360 if (b1 or a1p) else 0.0
    h2 = math.degrees(math.atan2(b2, a2p)) % 360 if (b2 or a2p) else 0.0
    dl = l2 - l1
    dc = c2p - c1p
    dh = 0.0 if c1p * c2p == 0 else (h2 - h1 - 360 if h2 - h1 > 180 else
                                     h2 - h1 + 360 if h2 - h1 < -180 else h2 - h1)
    dhp = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dh) / 2.0)
    lm = (l1 + l2) / 2.0
    cmp_ = (c1p + c2p) / 2.0
    if c1p * c2p == 0:
        hm = h1 + h2
    elif abs(h1 - h2) <= 180:
        hm = (h1 + h2) / 2.0
    else:
        hm = (h1 + h2 + 360) / 2.0 if h1 + h2 < 360 else (h1 + h2 - 360) / 2.0
    tt = (1 - 0.17 * math.cos(math.radians(hm - 30)) + 0.24 * math.cos(math.radians(2 * hm))
          + 0.32 * math.cos(math.radians(3 * hm + 6)) - 0.20 * math.cos(math.radians(4 * hm - 63)))
    sl = 1 + (0.015 * (lm - 50) ** 2) / math.sqrt(20 + (lm - 50) ** 2)
    sc = 1 + 0.045 * cmp_
    sh = 1 + 0.015 * cmp_ * tt
    rt = (-2 * math.sqrt(cmp_ ** 7 / (cmp_ ** 7 + 25.0 ** 7))
          * math.sin(math.radians(60 * math.exp(-(((hm - 275) / 25.0) ** 2)))) if cmp_ > 0 else 0.0)
    return math.sqrt((dl / sl) ** 2 + (dc / sc) ** 2 + (dhp / sh) ** 2
                     + rt * (dc / sc) * (dhp / sh))


def read_profile(path):
    with open(path, "rb") as handle:
        data = bytearray(handle.read())
    count = struct.unpack(">I", bytes(data[128:132]))[0]
    tags = {}
    for index in range(count):
        sig, off, size = struct.unpack(">4sII", bytes(data[132 + index * 12:144 + index * 12]))
        tags[sig.decode("latin1")] = (off, size)
    return data, tags


SDR_TRANSFERS = ("srgb", "gamma22", "gamma24", "bt1886")
# The labels profile_description writes into the ICC description.
DESCRIPTION_TRANSFERS = {
    "srgb": "srgb",
    "gamma 2.2": "gamma22",
    "gamma 2.4": "gamma24",
    "bt.1886": "bt1886",
}


def read_text_tag(data, tags, signature):
    entry = tags.get(signature)
    if entry is None:
        return ""
    off, size = entry
    kind = bytes(data[off:off + 4])
    if kind == b"desc":
        count = struct.unpack(">I", bytes(data[off + 8:off + 12]))[0]
        return bytes(data[off + 12:off + 12 + max(0, count - 1)]).decode("latin1", "replace")
    if kind == b"mluc":
        if struct.unpack(">I", bytes(data[off + 8:off + 12]))[0] < 1:
            return ""
        length, first = struct.unpack(">II", bytes(data[off + 20:off + 28]))
        return bytes(data[off + first:off + first + length]).decode("utf-16-be", "replace")
    if kind == b"text":
        return bytes(data[off + 8:off + size]).split(b"\0")[0].decode("latin1", "replace")
    return ""


def transfer_from_description(text):
    """Recover a build's SDR target transfer from the ICC description.

    Builds append a "(SDR, <label>)" or "(SDR MHC2, <label>)" marker. It is the
    only record of the transfer carried inside profiles built before the
    validation sidecar started naming it.
    """
    found = re.search(r"\(SDR(?:\s+MHC2)?,\s*([^)]+)\)\s*$", text.strip())
    if not found:
        return ""
    return DESCRIPTION_TRANSFERS.get(found.group(1).strip().lower(), "")


def transfer_from_sidecar(parent_path, suffix, keys):
    try:
        with io.open(parent_path + suffix, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, IOError, ValueError):
        return ""
    for key in keys:
        if not isinstance(record, dict):
            return ""
        record = record.get(key)
    value = str(record or "").lower()
    return value if value in SDR_TRANSFERS else ""


def resolve_transfer(payload, parent_path, data, tags):
    """Recover the transfer the parent profile was actually built against.

    The fine-tune request carries no transfer, so an unresolved one silently
    evaluates an sRGB profile against pure 2.2. Those two differ by a factor of
    three at 5% drive because sRGB has a linear toe, and the tune then chases
    an error that exists only in its own target model.
    """
    requested = str(payload.get("target_transfer", "")).lower()
    if requested in SDR_TRANSFERS:
        return requested, "request"
    for suffix, keys in ((".validation.json", ("target_transfer",)),
                         (".measurements.json", ("build_config", "target_transfer"))):
        found = transfer_from_sidecar(parent_path, suffix, keys)
        if found:
            return found, suffix.strip(".").split(".")[0]
    found = transfer_from_description(read_text_tag(data, tags, "desc"))
    if found:
        return found, "description"
    return "gamma22", "default"


def be16(data, position):
    return (data[position] << 8) | data[position + 1]


def s15(data, position):
    return struct.unpack(">i", bytes(data[position:position + 4]))[0] / 65536.0


def put_s15(data, position, value):
    raw = int(round(value * 65536.0))
    raw = max(-(1 << 31), min((1 << 31) - 1, raw))
    data[position:position + 4] = struct.pack(">i", raw)


def table_sample(data, base, count, value):
    value = max(0.0, min(1.0, value)) * (count - 1)
    low = min(int(value), count - 2)
    fraction = value - low
    return (be16(data, base + low * 2) * (1.0 - fraction)
            + be16(data, base + (low + 1) * 2) * fraction) / 65535.0


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


def mat_inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(det) < 1e-12:
        return None
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def mat_vec(m, v):
    return [sum(m[r][k] * v[k] for k in range(3)) for r in range(3)]


def d65_xyz(nits):
    return [nits * D65_X / D65_Y, nits, nits * (1.0 - D65_X - D65_Y) / D65_Y]


def srgb_eotf(v):
    if v <= 0.04045:
        return v / 12.92
    return ((v + 0.055) / 1.055) ** 2.4


def srgb_inverse(v):
    if v <= 0.0031308:
        return v * 12.92
    return 1.055 * v ** (1.0 / 2.4) - 0.055


def finetune(payload, output_dir):
    parent_path = payload["parent_path"]
    damping = float(payload.get("damping", 0.5))
    damping = max(0.1, min(1.0, damping))
    data, tags = read_profile(parent_path)
    if "targ" not in tags or "lumi" not in tags:
        raise ValueError("The profile lacks the embedded characterization fine-tune needs")
    lumi = s15(data, tags["lumi"][0] + 12)
    fmt, rows, targ_text = parse_targ(data, tags)
    has_mhc2 = "MHC2" in tags
    transfer, transfer_source = resolve_transfer(payload, parent_path, data, tags)

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

    # Collapse repeats to medians (by luminance; X and Z travel with it)
    grouped = []
    for code, y, x, z in reads:
        if grouped and abs(code - grouped[-1][0]) < 1e-6:
            grouped[-1][1].append((y, x, z))
        else:
            grouped.append([code, [(y, x, z)]])

    # Measured neutral response and native primaries from the embedded
    # characterization. The corridor's calibration domain is the raw neutral
    # code axis with luminance following this curve.
    ri = fmt.index("RGB_R")
    gi = fmt.index("RGB_G")
    bi = fmt.index("RGB_B")
    xi = fmt.index("XYZ_X")
    yi = fmt.index("XYZ_Y")
    zi = fmt.index("XYZ_Z")
    neutral = sorted((float(r[ri]) / 100.0,
                      float(r[yi]) * lumi / 100.0)
                     for r in rows
                     if abs(float(r[ri]) - float(r[gi])) < 0.3
                     and abs(float(r[gi]) - float(r[bi])) < 0.3)
    if len(neutral) < 4:
        raise ValueError("The embedded characterization has no neutral axis")
    ymax = max(y for _, y in neutral)
    ymin = min(y for _, y in neutral)

    # HDR or SDR device model? cicp is authoritative when present, but many
    # profile classes (MHC2, pre-4.4 KDE builds) carry none. The embedded
    # neutral response settles it: at half drive a PQ-driven panel sits near
    # pq(0.5) = 92 nits regardless of peak, while an SDR panel sits near
    # white * 0.5^2.2. Compare in log space against the measured curve.
    def neutral_at(code_value):
        prev_code, prev_y = neutral[0]
        for code_i, y_i in neutral[1:]:
            if code_i >= code_value:
                span = code_i - prev_code
                t = 0.0 if span <= 0 else (code_value - prev_code) / span
                return prev_y + t * (y_i - prev_y)
            prev_code, prev_y = code_i, y_i
        return neutral[-1][1]

    # cicp names the transfer, and SDR v4.4 builds carry one too (13, sRGB).
    # Its mere presence is not an HDR marker; only a PQ or HLG characteristic
    # is, and anything else falls through to the measured response.
    cicp_transfer = data[tags["cicp"][0] + 9] if "cicp" in tags else None
    if cicp_transfer in (16, 18):
        is_hdr = True
    elif cicp_transfer is not None and cicp_transfer in (1, 4, 6, 8, 13, 14, 15):
        is_hdr = False
    else:
        measured_half = max(neutral_at(0.5), 1e-6)
        pq_err = abs(math.log(measured_half / max(pq_to_nits(0.5), 1e-6)))
        sdr_half = max(ymin + (lumi - ymin) * 0.5 ** 2.2, 1e-6)
        sdr_err = abs(math.log(measured_half / sdr_half))
        is_hdr = pq_err < sdr_err

    primaries = {}
    for r in rows:
        drive = [float(r[ri]), float(r[gi]), float(r[bi])]
        for ch in range(3):
            others = [drive[k] for k in range(3) if k != ch]
            if drive[ch] >= 99.0 and max(others) <= 0.5:
                current = primaries.get(ch)
                if current is None or drive[ch] > current[0]:
                    primaries[ch] = (drive[ch],
                                     [float(r[xi]) * lumi / 100.0,
                                      float(r[yi]) * lumi / 100.0,
                                      float(r[zi]) * lumi / 100.0])
    primary_matrix = None
    if len(primaries) == 3:
        cols = [primaries[ch][1] for ch in range(3)]
        primary_matrix = [[cols[c][r] for c in range(3)] for r in range(3)]
        primary_inverse = mat_inv(primary_matrix)
        if primary_inverse is None:
            primary_matrix = None

    def channel_gains(measured_xyz, target_xyz):
        """Per-channel gains that move the measured colour to the target,
        through the panel's native primaries. Falls back to a pure
        luminance ratio when the decomposition is unavailable."""
        if primary_matrix is not None:
            rgb_m = mat_vec(primary_inverse, measured_xyz)
            rgb_t = mat_vec(primary_inverse, target_xyz)
            if min(rgb_m) > 1e-6:
                return [max(0.5, min(2.0, rgb_t[k] / rgb_m[k])) for k in range(3)]
        ratio = max(0.5, min(2.0, target_xyz[1] / max(measured_xyz[1], 1e-9)))
        return [ratio, ratio, ratio]

    def sdr_target_for(name, code):
        if name == "srgb":
            linear = srgb_eotf(code)
        elif name == "gamma24":
            linear = code ** 2.4
        elif name == "bt1886":
            gamma = 2.4
            lw, lb = lumi, max(0.0, ymin)
            a = (lw ** (1.0 / gamma) - lb ** (1.0 / gamma)) ** gamma
            b = lb ** (1.0 / gamma) / max(lw ** (1.0 / gamma) - lb ** (1.0 / gamma), 1e-9)
            return a * max(code + b, 0.0) ** gamma
        else:
            linear = code ** 2.2
        return ymin + (lumi - ymin) * linear

    def sdr_target(code):
        return sdr_target_for(transfer, code)

    def level_target_nits(code):
        if is_hdr:
            return min(pq_to_nits(code), 0.995 * ymax)
        return min(sdr_target(code), 0.995 * ymax)

    rolloff_start = 0.90 * ymax
    keyed = []
    levels = []
    shape = []
    for code, samples in grouped:
        samples.sort()
        y, x, z = samples[len(samples) // 2]
        if y <= 0.0:
            continue
        request = pq_to_nits(code) if is_hdr else sdr_target(code)
        target = level_target_nits(code)
        if target < 0.02:
            continue
        in_rolloff = is_hdr and request >= rolloff_start
        if in_rolloff:
            # The panel pins the luminance here; correct only the balance.
            gains = channel_gains([x, y, z], d65_xyz(y))
            top = max(gains)
            gains = [g / top for g in gains]
        else:
            gains = channel_gains([x, y, z], d65_xyz(target))
        effective = [1.0 + damping * (g - 1.0) for g in gains]
        # Convergence metric in the acceptance colour difference: against the
        # absolute target below the rolloff, and against D65 at the achieved
        # luminance inside it, where only the balance is correctable.
        reference = d65_xyz(y) if in_rolloff else d65_xyz(target)
        level_de = de_itp([x, y, z], reference)
        levels.append({
            "pct": round(code * 100.0, 1),
            "target_nits": round(target, 3),
            "measured_nits": round(y, 3),
            "rolloff": in_rolloff,
            "de_itp": round(level_de, 3),
            "gains": [round(g, 4) for g in gains],
            "before_err_pct": round((y / target - 1.0) * 100.0, 2),
            "predicted_err_pct": round((y * ((effective[0] + effective[1] + effective[2]) / 3.0)
                                        / target - 1.0) * 100.0, 2),
        })
        keyed.append((min(request, 0.995 * ymax), effective))
        shape.append((code, y, target, in_rolloff))
    if len(keyed) < 6:
        raise ValueError("Too few usable neutral reads above the meter floor")
    keyed.sort()

    # AutoCal-style sessions pass a tolerance: when every ladder level is
    # already inside it, leave the profile untouched and report convergence
    # instead of accumulating pointless micro-edits pass after pass.
    target_de = float(payload.get("target_de", 0.0) or 0.0)
    worst_de = max(lv["de_itp"] for lv in levels)
    if target_de > 0.0 and worst_de <= target_de:
        inr_de = [lv["de_itp"] for lv in levels if not lv["rolloff"]]
        top_de = [lv["de_itp"] for lv in levels if lv["rolloff"]]
        return {
            "status": "ok",
            "converged": True,
            "file": os.path.basename(parent_path),
            "parent": os.path.basename(parent_path),
            "mode": ("mhc2" if has_mhc2 else "b2a") + ("-hdr" if is_hdr else "-sdr"),
            "target_transfer": None if is_hdr else transfer,
            "target_transfer_source": None if is_hdr else transfer_source,
            "worst_de": round(worst_de, 3),
            "before_de": {
                "inrange_mean": round(sum(inr_de) / len(inr_de), 3) if inr_de else None,
                "inrange_max": round(max(inr_de), 3) if inr_de else None,
                "rolloff_mean": round(sum(top_de) / len(top_de), 3) if top_de else None,
                "rolloff_max": round(max(top_de), 3) if top_de else None,
            },
            "levels": sorted(levels, key=lambda item: item["pct"]),
            "selfcheck": None,
        }

    # A wrong target model describes a display no panel resembles: the bottom
    # of the ladder off by tens of percent, all in one direction, while
    # everything from the mid range up is already on target. Acting on that
    # shape saturates the gain clamp in the shadows and crushes them. A profile
    # that is genuinely bad is wrong across its whole reachable range, so the
    # body test below is what separates the two. Levels under a fifth of a
    # candela are excluded: there the meter's own noise exceeds the signal, and
    # a single noisy toe read must not be able to block a valid tune.
    inrange = [item for item in shape if not item[3]]
    shadow = sorted(item[1] / item[2] - 1.0 for item in inrange
                    if item[0] < 0.25 and item[2] >= 0.2)
    body = [abs(item[1] / item[2] - 1.0) for item in inrange if item[0] >= 0.35]
    if (len(shadow) >= 3 and len(body) >= 3 and max(body) <= 0.10
            and (shadow[0] > 0.0 or shadow[-1] < 0.0)
            and abs(shadow[len(shadow) // 2]) >= 0.25):
        message = ("The measured grey ladder tracks its target to within {:.0f}% above 35% "
                   "drive but is {:.0f}% off below 25%. That is a target mismatch, not a "
                   "display error, and correcting it would crush the shadows. This profile "
                   "is being evaluated as {} (transfer resolved from: {}).").format(
                       max(body) * 100.0, abs(shadow[len(shadow) // 2]) * 100.0,
                       "HDR PQ" if is_hdr else transfer, transfer_source)
        if not is_hdr:
            scored = []
            for name in SDR_TRANSFERS:
                worst = 0.0
                for code, measured, _target, _roll in inrange:
                    want = sdr_target_for(name, code)
                    if want >= 0.02:
                        worst = max(worst, abs(measured / want - 1.0))
                scored.append((worst, name))
            scored.sort()
            if scored[0][1] != transfer:
                message += (" The readings fit {} far better ({:.0f}% worst error against "
                            "{:.0f}%). Rebuild the profile or pass target_transfer.").format(
                                scored[0][1], scored[0][0] * 100.0,
                                dict((n, w) for w, n in scored)[transfer] * 100.0)
        raise ValueError(message)

    def residual_gains(nits):
        if nits <= keyed[0][0]:
            return keyed[0][1]
        for i in range(1, len(keyed)):
            if keyed[i][0] >= nits:
                n0, g0 = keyed[i - 1]
                n1, g1 = keyed[i]
                t = 0.0 if n1 == n0 else (nits - n0) / (n1 - n0)
                return [g0[k] + t * (g1[k] - g0[k]) for k in range(3)]
        return keyed[-1][1]

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

    # Local slope of the neutral response just below the knee, in wire code
    # per unit log-luminance. Inside the plateau the luminance inverse is
    # degenerate, so balance corrections there move codes along this slope.
    knee_c1 = code_for_lum(0.85 * ymax)
    knee_c2 = code_for_lum(0.60 * ymax)
    knee_slope = (knee_c1 - knee_c2) / max(math.log(0.85) - math.log(0.60), 1e-9)

    applied = []
    bound = 2.5 / 1023.0
    plateau_bound = 3.0 / 1023.0
    # The corridor edits wire codes, where a couple of codes per pass is the
    # right step. MHC2 corrections live in the normalised signal domain of a
    # 256-entry curve, and the same numeric bound would cap a pass at 0.24%
    # of full scale - two dozen passes to close a rolloff that measured 44%
    # low. Curve edits get a proportionally larger step, still damped.
    curve_bound = 0.06

    if has_mhc2:
        # The operative correction of an MHC2 profile is its per-channel
        # adjustment curve set, applied in the wire signal domain by Windows
        # and by the patched KWin. Edit those curves, and mirror the same
        # change into the cloned vcgt so both consumers stay in step.
        off, _ = tags["MHC2"]
        entries = struct.unpack(">I", bytes(data[off + 8:off + 12]))[0]
        lut_offsets = struct.unpack(">III", bytes(data[off + 24:off + 36]))
        for ch in range(3):
            base = off + lut_offsets[ch] + 8
            for index in range(entries):
                position = index / (entries - 1.0)
                request = pq_to_nits(position) if is_hdr else sdr_target(position)
                if request < 0.02:
                    continue
                eff = residual_gains(min(request, 0.995 * ymax))[ch]
                if abs(eff - 1.0) < 0.0005:
                    continue
                old = s15(data, base + index * 4)
                clipped = max(0.0, min(1.0, old))
                if is_hdr:
                    new = nits_to_pq(pq_to_nits(clipped) * eff)
                else:
                    linear = clipped ** 2.2 if transfer != "srgb" else srgb_eotf(clipped)
                    linear = max(0.0, min(1.0, linear * eff))
                    new = linear ** (1.0 / 2.2) if transfer != "srgb" else srgb_inverse(linear)
                delta = max(-curve_bound, min(curve_bound, new - clipped))
                put_s15(data, base + index * 4, old + delta)
                applied.append(abs(eff - 1.0))
        if "vcgt" in tags:
            voff, _ = tags["vcgt"]
            vchannels, ventries, vwidth = struct.unpack(">HHH", bytes(data[voff + 12:voff + 18]))
            if vwidth == 2 and vchannels == 3:
                vbase = voff + 18
                for ch in range(3):
                    for index in range(ventries):
                        position = index / (ventries - 1.0)
                        request = pq_to_nits(position) if is_hdr else sdr_target(position)
                        if request < 0.02:
                            continue
                        eff = residual_gains(min(request, 0.995 * ymax))[ch]
                        if abs(eff - 1.0) < 0.0005:
                            continue
                        pos = vbase + (ch * ventries + index) * 2
                        old = be16(data, pos) / 65535.0
                        if is_hdr:
                            new = nits_to_pq(pq_to_nits(old) * eff)
                        else:
                            linear = old ** 2.2 if transfer != "srgb" else srgb_eotf(old)
                            linear = max(0.0, min(1.0, linear * eff))
                            new = linear ** (1.0 / 2.2) if transfer != "srgb" else srgb_inverse(linear)
                        delta = max(-curve_bound, min(curve_bound, new - old))
                        value = max(0, min(65535, int(round((old + delta) * 65535.0))))
                        data[pos] = value >> 8
                        data[pos + 1] = value & 0xFF
    else:
        encode = 32768.0 / 65535.0
        d50 = (0.9642, 1.0, 0.8249)
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
                nits = min(y_rel, 1.9) * lumi
                if nits < 0.02:
                    continue
                gains = residual_gains(min(nits, 0.995 * ymax))
                if max(abs(g - 1.0) for g in gains) < 0.0005:
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
                            eff = gains[ch]
                            if current >= rolloff_start:
                                # Plateau: the luminance inverse is flat, so
                                # move the code along the knee slope instead.
                                delta = math.log(max(eff, 1e-6)) * knee_slope
                                delta = max(-plateau_bound, min(plateau_bound, delta))
                            else:
                                wanted = code_for_lum(current * eff)
                                delta = max(-bound, min(bound, wanted - wire))
                            if abs(delta) < 0.25 / 1023.0:
                                continue
                            new_node = table_invert(out_off + ch * out_entries * 2,
                                                    out_entries, wire + delta)
                            value = max(0, min(65535, int(round(new_node * 65535.0))))
                            data[base_pos + ch * 2] = value >> 8
                            data[base_pos + ch * 2 + 1] = value & 0xFF
                applied.append(max(abs(g - 1.0) for g in gains))

    # ---- colour corrections -------------------------------------------------
    # Each colour reading edits only the cLUT cell surrounding its own PCS
    # position: per-channel gains through the panel primaries, converted to
    # wire deltas along the local slope of that channel's drive level, scaled
    # by the corner's trilinear weight so neighbouring colours are disturbed
    # no more than their interpolation share. Damped, bounded, iterative -
    # the same doctrine as the grey corridor.
    color_levels = []
    color_rows = payload.get("color_readings") or []
    if color_rows and not has_mhc2:
        bradford = ((0.8951, 0.2664, -0.1614),
                    (-0.7502, 1.7135, 0.0367),
                    (0.0389, -0.0685, 1.0296))
        d65w = (0.9504559, 1.0, 1.0890578)
        d50w = (0.9642, 1.0, 0.8249)
        cone_src = mat_vec([list(r) for r in bradford], list(d65w))
        cone_dst = mat_vec([list(r) for r in bradford], list(d50w))
        scaled = [[cone_dst[r] / cone_src[r] * bradford[r][k] for k in range(3)]
                  for r in range(3)]
        brad_inv = mat_inv([list(r) for r in bradford])
        adapt = [[sum(brad_inv[r][k] * scaled[k][c] for k in range(3))
                  for c in range(3)] for r in range(3)]
        encode = 32768.0 / 65535.0

        def local_slope(wire):
            """Wire code per unit log-luminance around this drive level."""
            low = max(0.02, wire - 0.06)
            high = min(0.98, wire + 0.06)
            y_low = max(measured_lum(low), 1e-4)
            y_high = max(measured_lum(high), y_low * 1.0001)
            return (high - low) / (math.log(y_high) - math.log(y_low))

        color_bound = 2.5 / 1023.0
        for row in color_rows:
            if row.get("error") or row.get("target_Yn") is None:
                continue
            tx = float(row.get("target_x", 0.0))
            ty = float(row.get("target_y", 0.0))
            tyn = float(row["target_Yn"]) * 1000.0
            if ty <= 0.0 or tyn < 0.05:
                continue
            target = [tyn * tx / ty, tyn, tyn * (1.0 - tx - ty) / ty]
            measured = [float(row.get("X", 0.0)), float(row.get("Y", 0.0)),
                        float(row.get("Z", 0.0))]
            if measured[1] <= 0.0:
                continue
            # Chart endpoints are referenced to a 1000 cd/m2 display, and a
            # saturated primary is capped by that primary alone, not by white:
            # this panel's red peaks near 83 cd/m2 against a 263 cd/m2 target.
            # Decompose the target through the measured primaries and skip any
            # patch that would need a channel beyond full drive. Those are out
            # of range, not miscalibrated, and chasing them only distorts
            # their neighbours.
            if primary_matrix is not None:
                rgb_target = mat_vec(primary_inverse, target)
                if max(rgb_target) > 1.0:
                    continue
            elif tyn > 0.95 * ymax:
                continue
            gains = channel_gains(measured, target)
            # A channel that barely contributes to a colour has a meaningless
            # ratio: saturated cyan carries almost no red, so its red ratio is
            # numerical noise that ran straight into the clamp and asked for a
            # doubling. Correct only the channels the colour is actually made
            # of, and leave the rest alone.
            if primary_matrix is not None:
                rgb_m = mat_vec(primary_inverse, measured)
                strongest = max(rgb_m)
                if strongest > 0:
                    gains = [g if rgb_m[k] > 0.12 * strongest else 1.0
                             for k, g in enumerate(gains)]
            effective = [1.0 + damping * (g - 1.0) for g in gains]
            # Fine-tune moves, not gross corrections: a colour cell should
            # never shift by more than a few percent in one pass.
            effective = [max(0.90, min(1.11, e)) for e in effective]
            before = de2000(measured, target)
            color_levels.append({
                "name": str(row.get("name", "")),
                "target_nits": round(target[1], 3),
                "measured_nits": round(measured[1], 3),
                "de2000": round(before, 3),
                "gains": [round(g, 4) for g in gains],
            })
            if max(abs(e - 1.0) for e in effective) < 0.0015:
                continue
            pcs = mat_vec(adapt, [c / lumi for c in target])
            for tag in ("B2A0", "B2A1"):
                if tag not in tags:
                    continue
                off, _ = tags[tag]
                grid = data[off + 10]
                in_entries, out_entries = struct.unpack(
                    ">HH", bytes(data[off + 48:off + 52]))
                in_off = off + 52
                clut_off = in_off + 3 * in_entries * 2
                out_off = clut_off + grid ** 3 * 3 * 2
                coords = []
                for ch in range(3):
                    t = table_sample(data, in_off + ch * in_entries * 2,
                                     in_entries, pcs[ch] * encode)
                    coords.append(max(0.0, min(1.0, t)) * (grid - 1))
                base_idx = [min(int(c), grid - 2) for c in coords]
                frac = [coords[ch] - base_idx[ch] for ch in range(3)]

                def out_invert(base, count, value):
                    low_i, high_i = 0, count - 1
                    low_v = be16(data, base) / 65535.0
                    high_v = be16(data, base + (count - 1) * 2) / 65535.0
                    if value <= low_v:
                        return 0.0
                    if value >= high_v:
                        return 1.0
                    while high_i - low_i > 1:
                        mid = (low_i + high_i) // 2
                        mid_v = be16(data, base + mid * 2) / 65535.0
                        if mid_v <= value:
                            low_i, low_v = mid, mid_v
                        else:
                            high_i, high_v = mid, mid_v
                    step = high_v - low_v
                    fraction = 0.0 if step <= 0 else (value - low_v) / step
                    return (low_i + fraction) / (count - 1.0)

                for di in range(2):
                    for dj in range(2):
                        for dk in range(2):
                            weight = ((frac[0] if di else 1.0 - frac[0])
                                      * (frac[1] if dj else 1.0 - frac[1])
                                      * (frac[2] if dk else 1.0 - frac[2]))
                            if weight < 0.05:
                                continue
                            pos = clut_off + ((((base_idx[0] + di) * grid
                                                + (base_idx[1] + dj)) * grid
                                               + (base_idx[2] + dk)) * 3) * 2
                            for ch in range(3):
                                node = be16(data, pos + ch * 2) / 65535.0
                                wire = table_sample(
                                    data, out_off + ch * out_entries * 2,
                                    out_entries, node)
                                if wire < 0.01:
                                    continue
                                delta = (math.log(max(effective[ch], 1e-6))
                                         * local_slope(wire) * weight)
                                delta = max(-color_bound, min(color_bound, delta))
                                if abs(delta) < 0.2 / 1023.0:
                                    continue
                                new_node = out_invert(
                                    out_off + ch * out_entries * 2,
                                    out_entries, wire + delta)
                                value = max(0, min(65535,
                                                   int(round(new_node * 65535.0))))
                                data[pos + ch * 2] = value >> 8
                                data[pos + ch * 2 + 1] = value & 0xFF
            applied.append(max(abs(e - 1.0) for e in effective))
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

    inr_de = [lv["de_itp"] for lv in levels if not lv["rolloff"]]
    top_de = [lv["de_itp"] for lv in levels if lv["rolloff"]]
    summary = {
        "status": "ok",
        "converged": False,
        "worst_de": round(worst_de, 3),
        "file": out_name,
        "parent": os.path.basename(parent_path),
        "mode": ("mhc2" if has_mhc2 else "b2a") + ("-hdr" if is_hdr else "-sdr"),
        "target_transfer": None if is_hdr else transfer,
        "target_transfer_source": None if is_hdr else transfer_source,
        "chroma_capable": primary_matrix is not None,
        "before_de": {
            "inrange_mean": round(sum(inr_de) / len(inr_de), 3) if inr_de else None,
            "inrange_max": round(max(inr_de), 3) if inr_de else None,
            "rolloff_mean": round(sum(top_de) / len(top_de), 3) if top_de else None,
            "rolloff_max": round(max(top_de), 3) if top_de else None,
        },
        "reads_used": len(keyed),
        "damping": damping,
        "max_correction_pct": round(max(applied) * 100.0, 2),
        "mean_correction_pct": round(sum(applied) / len(applied) * 100.0, 2),
        "levels": sorted(levels, key=lambda item: item["pct"]),
        "color_levels": color_levels,
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

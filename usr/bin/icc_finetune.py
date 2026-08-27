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
- MHC2 profiles: neutral corrections land in the MHC2 per-channel adjustment
  curves and in the selected secondary representation: cloned vcgt, or B2A
  output shapers for a no-VCGT dual-consumer profile. Reachable colour reads
  fit a small D65-preserving residual correction into MHC2 and independently
  correct B2A, so Windows handling and explicit cLUT handling remain complete.
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

from pgen_colour_math import (
    ICTCP_XYZ_TO_RGB2020 as XYZ_TO_RGB2020,
    D65_WHITE,
    ICC_D50_WHITE,
    bradford_adaptation,
    delta_e_itp_xyz,
    matrix3_inverse as mat_inv,
    matrix3_multiply as mat_mul,
    matrix3_vector_multiply as mat_vec,
    pq_decode_nits,
    pq_encode_nits,
    sample_uniform_table as sample_values,
    smoothstep,
)

D65_X = 0.3127
D65_Y = 0.3290

SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
OUTPUT_RE = re.compile(r"^[A-Za-z0-9._()-]{1,80}$")


def write_atomic(path, content, mode=0o644):
    """Replace one session artifact without exposing a partial file."""
    directory = os.path.dirname(path)
    handle, temporary = tempfile.mkstemp(prefix=".icc-finetune-write-",
                                         dir=directory)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def session_paths(output_dir, session):
    if not SESSION_RE.match(str(session or "")):
        raise ValueError("Invalid fine-tune session")
    prefix = os.path.join(output_dir, ".icc-finetune-session-" + session)
    return prefix + ".json", prefix + ".best-profile", prefix + ".best-sidecar"


def checkpoint_session(payload, output_dir, profile_data, score, before_de,
                       profile_name, mode, color_de=None, worst_de=None):
    """Retain the best profile that was actually measured in this session.

    The tuner writes the next candidate over the public FineTuned filename.
    This private checkpoint is therefore the only authoritative way to put
    the best measured bytes back after a later pass regresses or after the
    pass budget is exhausted.
    """
    session = payload.get("session")
    if not session:
        return None
    state_path, best_path, sidecar_path = session_paths(output_dir, session)
    output = str(payload.get("name") or "")
    if not OUTPUT_RE.match(output) or output.endswith(".icc") or ".." in output:
        raise ValueError("Invalid fine-tune output name")
    state = {}
    if os.path.isfile(state_path):
        try:
            with io.open(state_path, "r", encoding="ascii") as handle:
                state = json.load(handle)
        except (ValueError, OSError, IOError):
            state = {}
    if state and state.get("output") != output:
        raise ValueError("Fine-tune session output changed")
    prior = state.get("best_score", state.get("best_worst_de"))
    if prior is None or float(score) < float(prior):
        write_atomic(best_path, bytes(profile_data))
        parent_path = payload.get("parent_path") or ""
        parent_sidecar = parent_path + ".finetune.json"
        if os.path.isfile(parent_sidecar):
            with open(parent_sidecar, "rb") as handle:
                write_atomic(sidecar_path, handle.read())
        else:
            try:
                os.unlink(sidecar_path)
            except OSError:
                pass
        state = {
            "output": output,
            "best_score": round(float(score), 3),
            "best_worst_de": round(float(worst_de if worst_de is not None else score), 3),
            "best_before_de": before_de,
            "best_color_de": color_de,
            "best_pass": int(payload.get("pass", 0) or 0),
            "best_profile": os.path.basename(profile_name),
            "mode": mode,
        }
        write_atomic(state_path, json.dumps(state, separators=(",", ":")).encode("ascii"),
                     mode=0o600)
    return state


def finalize_session(payload, output_dir):
    """Promote the best measured checkpoint and discard private artifacts."""
    session = payload.get("session")
    state_path, best_path, sidecar_path = session_paths(output_dir, session)
    if not os.path.isfile(state_path) or not os.path.isfile(best_path):
        raise ValueError("Fine-tune session has no measured checkpoint")
    with io.open(state_path, "r", encoding="ascii") as handle:
        state = json.load(handle)
    output = str(payload.get("name") or "")
    if (not OUTPUT_RE.match(output) or output.endswith(".icc") or ".." in output
            or output != state.get("output")):
        raise ValueError("Invalid fine-tune output name")
    out_name = output + ".icc"
    out_path = os.path.join(output_dir, out_name)
    with open(best_path, "rb") as handle:
        write_atomic(out_path, handle.read())

    metadata = {}
    if os.path.isfile(sidecar_path):
        try:
            with io.open(sidecar_path, "r", encoding="ascii") as handle:
                metadata = json.load(handle)
        except (ValueError, OSError, IOError):
            metadata = {}
    metadata.update({
        "status": "ok",
        "file": out_name,
        "mode": state.get("mode"),
        "worst_de": state.get("best_worst_de"),
        "before_de": state.get("best_before_de"),
        "color_de": state.get("best_color_de"),
        "selection_score": state.get("best_score", state.get("best_worst_de")),
        "selection": {
            "method": "best_measured_global_colour_score",
            "pass": state.get("best_pass"),
            "measured_profile": state.get("best_profile"),
        },
    })
    write_atomic(out_path + ".finetune.json",
                 json.dumps(metadata, separators=(",", ":")).encode("ascii"))
    for path in (state_path, best_path, sidecar_path):
        try:
            os.unlink(path)
        except OSError:
            pass
    return {
        "status": "ok",
        "file": out_name,
        "best_pass": state.get("best_pass"),
        "best_worst_de": state.get("best_worst_de"),
        "best_before_de": state.get("best_before_de"),
        "best_color_de": state.get("best_color_de"),
        "best_score": state.get("best_score", state.get("best_worst_de")),
        "measured_profile": state.get("best_profile"),
    }


def pq_to_nits(value):
    return pq_decode_nits(
        value, clamp_signal=False, nonpositive_result=10000.0)


def nits_to_pq(nits):
    return pq_encode_nits(nits, clamp_peak=True)


def de_itp(xyz_a, xyz_b):
    """BT.2124 colour difference between two absolute XYZ stimuli."""
    return delta_e_itp_xyz(
        xyz_a, xyz_b, pq_encoder=nits_to_pq,
        legacy_fold_delta_t_weight=True)


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


def median(values):
    ordered = sorted(float(value) for value in values)
    if not ordered:
        raise ValueError("Cannot take the median of an empty sequence")
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return 0.5 * (ordered[middle - 1] + ordered[middle])


def isotonic_values(values):
    """Pool adjacent violations without turning a local dip into a tail.

    MHC2 is required to be monotonic. Independent residual edits can otherwise
    leave a one-entry reversal, especially in the sparse HDR toe. Pooling the
    conflicting neighbourhood distributes that correction locally instead of
    using a cumulative maximum that would propagate one noisy sample through
    every brighter level.
    """
    blocks = []
    for index, value in enumerate(values):
        blocks.append([index, index, float(value), 1.0])
        while (len(blocks) >= 2
               and blocks[-2][2] / blocks[-2][3] > blocks[-1][2] / blocks[-1][3]):
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


def isotonic_channel_samples(samples):
    """Fit a normalized physical channel response from raw neutral reads."""
    grouped = []
    for code, response in sorted(samples):
        if grouped and abs(code - grouped[-1][0]) < 1e-7:
            grouped[-1][1].append(response)
        else:
            grouped.append([code, [response]])
    collapsed = [(code, median(responses)) for code, responses in grouped]
    if len(collapsed) < 5:
        return None
    fitted = isotonic_values([response for _code, response in collapsed])
    peak = fitted[-1]
    if peak <= 1e-9:
        return None
    return [(collapsed[index][0], fitted[index] / peak)
            for index in range(len(collapsed))]


def sample_pairs(samples, position):
    if position <= samples[0][0]:
        return samples[0][1]
    for index in range(1, len(samples)):
        if samples[index][0] >= position:
            x0, y0 = samples[index - 1]
            x1, y1 = samples[index]
            fraction = 0.0 if x1 <= x0 else (position - x0) / (x1 - x0)
            return y0 + fraction * (y1 - y0)
    return samples[-1][1]


def invert_pairs(samples, target):
    target = max(samples[0][1], min(samples[-1][1], target))
    if target <= samples[0][1]:
        return samples[0][0]
    for index in range(1, len(samples)):
        x0, y0 = samples[index - 1]
        x1, y1 = samples[index]
        if target <= y1 + 1e-12:
            if y1 <= y0 + 1e-12:
                return x0
            return x0 + (target - y0) / (y1 - y0) * (x1 - x0)
    return samples[-1][0]


def invert_values(values, target):
    """Invert a normalized monotonic table, choosing the start of plateaus."""
    target = max(values[0], min(values[-1], target))
    if target <= values[0]:
        return 0.0
    low, high = 0, len(values) - 1
    while high - low > 1:
        middle = (low + high) // 2
        if values[middle] < target:
            low = middle
        else:
            high = middle
    before, after = values[low], values[high]
    fraction = 0.0 if after <= before else (target - before) / (after - before)
    return (low + fraction) / float(len(values) - 1)


def mhc2_neutral_curves(matrix, adjustment_luts, entries=4096):
    """Clone Windows HDR MHC2's complete neutral-axis output as three curves."""
    wire = [[0.6369580, 0.1446169, 0.1688810],
            [0.2627002, 0.6779981, 0.0593017],
            [0.0000000, 0.0280727, 1.0609851]]
    inverse_wire = mat_inv(wire)
    if inverse_wire is None:
        raise ValueError("BT.2020 wire matrix is invalid")
    curves = [[], [], []]
    for index in range(entries):
        position = index / float(entries - 1)
        linear = [pq_to_nits(position) / 10000.0] * 3
        target = mat_vec(inverse_wire, mat_vec(matrix, mat_vec(wire, linear)))
        for channel in range(3):
            encoded = nits_to_pq(max(0.0, target[channel]) * 10000.0)
            encoded = sample_values(adjustment_luts[channel], encoded)
            curves[channel].append(max(0.0, min(1.0, encoded)))
    for channel in range(3):
        curves[channel] = isotonic_values(curves[channel])
    return curves


def remap_b2a_output_calibration(data, tags, old_curves, new_curves):
    """Replace C_old(base) with C_new(base) in every mft2 B2A shaper."""
    changed = False
    for tag in ("B2A0", "B2A1"):
        if tag not in tags:
            continue
        off, size = tags[tag]
        if size < 52 or bytes(data[off:off + 4]) != b"mft2":
            continue
        inputs, outputs, grid = data[off + 8], data[off + 9], data[off + 10]
        in_entries, out_entries = struct.unpack(">HH", bytes(data[off + 48:off + 52]))
        if inputs != 3 or outputs != 3 or grid < 2 or min(in_entries, out_entries) < 2:
            continue
        out_off = off + 52 + inputs * in_entries * 2 + grid ** inputs * outputs * 2
        if out_off + outputs * out_entries * 2 > off + size:
            raise ValueError("The profile has a truncated B2A output shaper")
        for channel in range(3):
            base = out_off + channel * out_entries * 2
            previous = 0
            for index in range(out_entries):
                composed = be16(data, base + index * 2) / 65535.0
                raw = invert_values(old_curves[channel], composed)
                updated = sample_values(new_curves[channel], raw)
                value = max(previous, max(0, min(65535, int(round(updated * 65535.0)))))
                data[base + index * 2] = value >> 8
                data[base + index * 2 + 1] = value & 0xFF
                previous = value
        changed = True
    if not changed:
        raise ValueError("The profile lacks the B2A shapers required by its calibration contract")


def stable_tail_start(values, tolerance=4.0 / 65536.0):
    """Find an existing held plateau, or return len(values) when none exists."""
    if len(values) < 4:
        return len(values)
    endpoint = values[-1]
    index = len(values) - 1
    while index > 0 and abs(values[index - 1] - endpoint) <= tolerance:
        index -= 1
    return index if len(values) - index >= 4 else len(values)


def mhc2_endpoint_start(entries):
    """First table entry Windows uses for exact maximum-code HDR white."""
    # 253/255 lies between dense-table samples. Start at its lower neighbour
    # so interpolation cannot mix the ordinary held shoulder into exact white.
    return max(1, min(entries - 1, int(math.floor(
        253.0 * (entries - 1) / 255.0))))


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


def mhc2_residual_matrix(samples, damping):
    """Fit a small measured-XYZ to target-XYZ correction for MHC2.

    MHC2 has no 3D table, so colour fine-tuning can only remove the global
    linear residual left by its matrix.  Fit chromaticity-normalised samples
    with a weak identity prior, force D65 to remain invariant, then bound the
    per-pass move.  Grayscale luminance and balance remain the curve tuner's
    responsibility.
    """
    if len(samples) < 6:
        return None
    gram = [[0.0] * 3 for _row in range(3)]
    cross = [[0.0] * 3 for _row in range(3)]
    for measured, target in samples:
        scale = max(float(target[1]), 1e-6)
        m = [float(value) / scale for value in measured]
        t = [float(value) / scale for value in target]
        for row in range(3):
            for column in range(3):
                gram[row][column] += m[row] * m[column]
                cross[row][column] += t[row] * m[column]
    # A weak identity prior stabilizes a chart whose reachable colours occupy
    # only part of the display gamut without overpowering real measurements.
    ridge = 0.25
    for index in range(3):
        gram[index][index] += ridge
        cross[index][index] += ridge
    inverse = mat_inv(gram)
    if inverse is None:
        return None
    fitted = mat_mul(cross, inverse)
    white = d65_xyz(1.0)
    white_norm = sum(value * value for value in white)
    # Project the residual onto the subspace C*D65=D65.  This prevents colour
    # reads from fighting the denser and less noisy neutral ladder.
    fitted_white = mat_vec(fitted, white)
    white_error = [white[row] - fitted_white[row] for row in range(3)]
    fitted = [[fitted[row][column] + white_error[row] * white[column] / white_norm
               for column in range(3)] for row in range(3)]
    delta = [[float(damping) * (fitted[row][column]
              - (1.0 if row == column else 0.0))
              for column in range(3)] for row in range(3)]
    # Re-project the damped delta so it has exactly zero effect on D65.
    drift = mat_vec(delta, white)
    delta = [[delta[row][column] - drift[row] * white[column] / white_norm
              for column in range(3)] for row in range(3)]
    diagonal_bound = 0.04
    cross_bound = 0.025
    scale = 1.0
    for row in range(3):
        for column in range(3):
            bound = diagonal_bound if row == column else cross_bound
            if abs(delta[row][column]) > bound:
                scale = min(scale, bound / abs(delta[row][column]))
    delta = [[value * scale for value in row] for row in delta]
    correction = [[(1.0 if row == column else 0.0) + delta[row][column]
                   for column in range(3)] for row in range(3)]
    if mat_inv(correction) is None:
        return None
    before_mean = sum(de2000(measured, target)
                      for measured, target in samples) / len(samples)
    after_mean = sum(de2000(mat_vec(correction, measured), target)
                     for measured, target in samples) / len(samples)
    # A least-squares XYZ improvement is not automatically a perceptual one.
    # Ignore fits whose dE00 gain is too small to distinguish from chart noise.
    minimum_gain = max(0.01, before_mean * 0.01)
    if after_mean > before_mean - minimum_gain:
        return None
    return correction


def d65_xyz(nits):
    return [nits * D65_X / D65_Y, nits, nits * (1.0 - D65_X - D65_Y) / D65_Y]


def regularize_mhc2_neutral_samples(samples, damping):
    """Make MHC2 residuals match the regions the hardware can distinguish.

    The HDR shoulder is one physical output state, even though the fine-tune
    ladder samples it at many input codes. Give that whole state one robust
    white-balance correction. In the toe, retain broad measured trends but
    suppress point chroma below the meter's reliable floor and smooth adjacent
    samples in log-gain space. This keeps one noisy dark read from carving a
    visible step into a high-resolution MHC2 curve.
    """
    plateau = [sample for sample in samples if sample["rolloff"]]
    # Windows Advanced Color does not render an exact maximum-code neutral
    # through the same effective control point as the held HDR shoulder. On
    # hardware, identical MHC2 values from the knee through the end of the
    # table still measured one white balance at 76-99% and a different one at
    # 100%, repeatably. Keep that final sample out of the shoulder pool. Its
    # correction is made raise-only below, which preserves MHC2 monotonicity
    # while allowing the endpoint to meet the already-correct held plateau.
    endpoint = max(plateau, key=lambda sample: sample["code"]) if plateau else None
    if endpoint is not None and endpoint["code"] < 0.999:
        endpoint = None
    plateau_body = [sample for sample in plateau if sample is not endpoint]
    if plateau:
        pool = plateau_body or plateau
        peak = max(sample["measured_y"] for sample in pool)
        stable = [sample for sample in pool
                  if sample["measured_y"] >= 0.985 * peak]
        if len(stable) < 3:
            stable = pool
        pooled = [math.exp(median(
            math.log(max(sample["gains"][channel], 1e-6))
            for sample in stable)) for channel in range(3)]
        top = max(pooled)
        pooled = [gain / top for gain in pooled]
        for sample in plateau_body:
            sample["gains"] = list(pooled)
        if endpoint is not None:
            # The shoulder's normalized gains lower the channels measured too
            # strong. Its separate high-tail control cannot be lowered below
            # the monotonic held body, so express the same ratio by raising the
            # weak channels instead. A hardware threshold sweep found that
            # Windows samples the final ~3% of the MHC2 table for exact 100%
            # white, while 76-99% stays on the ordinary held shoulder.
            floor = max(min(endpoint["gains"]), 1e-6)
            endpoint["gains"] = [min(1.12, gain / floor)
                                 for gain in endpoint["gains"]]
            endpoint["mhc2_endpoint"] = True

    body = [sample for sample in samples if not sample["rolloff"]]
    original = dict((sample["code"], [math.log(max(gain, 1e-6))
                                      for gain in sample["gains"]])
                    for sample in body)
    for sample in body:
        # Above 45% the meter has ample signal and the response changes fast
        # enough near the HDR knee that a local smoothing kernel is not useful.
        if sample["code"] > 0.45:
            continue
        weighted_chroma = [0.0, 0.0, 0.0]
        weight_sum = 0.0
        for neighbour in body:
            distance = abs(neighbour["code"] - sample["code"])
            if distance >= 0.101:
                continue
            kernel = max(0.0, 1.0 - distance / 0.101)
            signal = max(neighbour["target"], neighbour["measured_y"])
            reliability = smoothstep((signal - 0.12) / 0.88)
            weight = kernel * (0.20 + 0.80 * reliability)
            logs = original[neighbour["code"]]
            neighbour_common = sum(logs) / 3.0
            for channel in range(3):
                weighted_chroma[channel] += weight * (
                    logs[channel] - neighbour_common)
            weight_sum += weight
        if weight_sum <= 0.0:
            continue
        own_logs = original[sample["code"]]
        common = sum(own_logs) / 3.0
        chroma = [value / weight_sum for value in weighted_chroma]
        signal = max(sample["target"], sample["measured_y"])
        # Luminance becomes useful before chromaticity. Below 0.12 cd/m2 both
        # are left to the denser characterization that built the parent.
        luminance_strength = smoothstep((signal - 0.12) / 0.68)
        chroma_strength = smoothstep((signal - 0.25) / 1.75)
        sample["gains"] = [math.exp(common * luminance_strength
                                    + chroma[channel] * chroma_strength)
                           for channel in range(3)]

    for sample in samples:
        sample["effective"] = [1.0 + damping * (gain - 1.0)
                               for gain in sample["gains"]]


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
    measured_profile_data = bytes(data)
    if "targ" not in tags or "lumi" not in tags:
        raise ValueError("The profile lacks the embedded characterization fine-tune needs")
    lumi = s15(data, tags["lumi"][0] + 12)
    fmt, rows, targ_text = parse_targ(data, tags)
    has_mhc2 = "MHC2" in tags
    calibration_contract = read_text_tag(data, tags, "pGCm")
    mirrors_mhc2_in_b2a = calibration_contract == "mhc2+b2a-shapers"
    independent_mhc2_and_b2a = (
        calibration_contract == "mhc2-common-tone+b2a-shapers")
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
    neutral_xyz = sorted(
        (sum(float(r[index]) for index in (ri, gi, bi)) / 300.0,
         [float(r[index]) * lumi / 100.0 for index in (xi, yi, zi)])
        for r in rows
        if abs(float(r[ri]) - float(r[gi])) < 0.3
        and abs(float(r[gi]) - float(r[bi])) < 0.3)
    neutral = [(code, xyz[1]) for code, xyz in neutral_xyz]
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
    panel_channel_samples = None
    if len(primaries) == 3:
        cols = [primaries[ch][1] for ch in range(3)]
        primary_matrix = [[cols[c][r] for c in range(3)] for r in range(3)]
        primary_inverse = mat_inv(primary_matrix)
        if primary_inverse is None:
            primary_matrix = None
        else:
            # The MHC2 curves output raw panel drive, not PQ light. Recover
            # each physical channel response from the embedded neutral ramp so
            # a requested gain can be inverted in the panel's actual domain.
            # The former PQ(old_curve_value) approximation is especially bad
            # in OLED shadows and creates the visible 10-35% oscillation.
            black_xyz = neutral_xyz[0][1]
            axes = [[primaries[column][1][row] - black_xyz[row]
                     for column in range(3)] for row in range(3)]
            axes_inverse = mat_inv(axes)
            if axes_inverse is not None:
                raw_samples = [[] for _channel in range(3)]
                for code, xyz in neutral_xyz:
                    response = mat_vec(
                        axes_inverse,
                        [xyz[row] - black_xyz[row] for row in range(3)])
                    for channel in range(3):
                        raw_samples[channel].append(
                            (code, max(0.0, response[channel])))
                fitted = [isotonic_channel_samples(channel_samples)
                          for channel_samples in raw_samples]
                if all(curve is not None for curve in fitted):
                    panel_channel_samples = fitted

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

    def bt2390_tonemap(lsrc, lmax, ldisp):
        # Port of the WebUI's bt2390Tonemap (webui.pm): BT.2390 EETF Hermite
        # spline in the normalized PQ domain. The verification chart judges
        # HDR greys against PQ + BT.2390 into the display peak; fine-tune must
        # aim at the same curve or every pass walks the profile away from the
        # reference it is graded by.
        if lmax <= 0.0 or ldisp <= 0.0:
            return lsrc
        if ldisp >= lmax:
            return min(lsrc, lmax)
        if lsrc <= 0.0:
            return 0.0
        emax = nits_to_pq(lmax)
        if emax <= 0.0:
            return lsrc
        e1 = nits_to_pq(lsrc) / emax
        max_lum = nits_to_pq(ldisp) / emax
        knee = 1.5 * max_lum - 0.5
        if e1 < knee or knee >= 1.0:
            e2 = e1
        else:
            t = (e1 - knee) / (1.0 - knee)
            t2 = t * t
            t3 = t2 * t
            e2 = ((2.0 * t3 - 3.0 * t2 + 1.0) * knee
                  + (t3 - 2.0 * t2 + t) * (1.0 - knee)
                  + (-2.0 * t3 + 3.0 * t2) * max_lum)
        return pq_to_nits(e2 * emax)

    def hdr_mastering_nits():
        for row in payload.get("readings") or []:
            try:
                candidate = float(row.get("max_luma") or 0.0)
            except (TypeError, ValueError):
                candidate = 0.0
            if candidate > 0.0:
                return candidate
        return 1000.0

    mastering = hdr_mastering_nits()

    def level_target_nits(code):
        if is_hdr:
            # Mirror the verification chart exactly: PQ decode capped at the
            # mastering peak, BT.2390-rolled into the profile peak. A panel
            # whose peak covers the mastering level gets a plain clip (the
            # EETF's own degenerate case) -- rolling from the 10000-nit
            # container instead put the knee near 325 nits and graded a
            # PQ-tracking panel 25 dE wrong through the mids.
            return bt2390_tonemap(min(pq_to_nits(code), mastering), mastering,
                                  0.995 * ymax)
        return min(sdr_target(code), 0.995 * ymax)

    # Resolve colour targets once for both cLUT cell edits and MHC2's global
    # residual-matrix solve.  HDR chart Yn is normalized to its mastering
    # reference (normally 1000 nits); SDR Yn is relative to the profile white.
    # The old unconditional *1000 made SDR colour fine-tuning chase HDR light
    # levels, so keep the signal domains explicit here.
    color_levels = []
    color_samples = []
    for row in payload.get("color_readings") or []:
        if row.get("error") or row.get("target_Yn") is None:
            continue
        tx = float(row.get("target_x", 0.0))
        ty = float(row.get("target_y", 0.0))
        reference_nits = (float(row.get("max_luma", 1000.0) or 1000.0)
                          if is_hdr else lumi)
        target_y = float(row["target_Yn"]) * reference_nits
        if ty <= 0.0 or target_y < 0.05:
            continue
        target = [target_y * tx / ty, target_y,
                  target_y * (1.0 - tx - ty) / ty]
        measured = [float(row.get("X", 0.0)), float(row.get("Y", 0.0)),
                    float(row.get("Z", 0.0))]
        if measured[1] <= 0.0:
            continue
        rgb_target = None
        reachable = True
        if primary_matrix is not None:
            rgb_target = mat_vec(primary_inverse, target)
            reachable = min(rgb_target) >= -0.02 and max(rgb_target) <= 1.0
        elif target_y > 0.95 * ymax:
            reachable = False
        if not reachable:
            continue
        gains = channel_gains(measured, target)
        if primary_matrix is not None:
            rgb_m = mat_vec(primary_inverse, measured)
            strongest = max(rgb_m)
            if strongest > 0:
                gains = [gain if rgb_m[channel] > 0.12 * strongest else 1.0
                         for channel, gain in enumerate(gains)]
        level = {
            "name": str(row.get("name", "")),
            "target_nits": round(target[1], 3),
            "measured_nits": round(measured[1], 3),
            "de2000": round(de2000(measured, target), 3),
            "gains": [round(gain, 4) for gain in gains],
        }
        color_levels.append(level)
        chromatic = abs(tx - D65_X) > 0.002 or abs(ty - D65_Y) > 0.002
        if chromatic and target_y >= 0.5:
            color_samples.append({
                "row": row, "measured": measured, "target": target,
                "gains": gains, "level": level,
            })

    rolloff_start = 0.90 * ymax
    neutral_samples = []
    keyed = []
    mhc2_keyed = []
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
        # Convergence metric in the acceptance colour difference: against the
        # absolute target below the rolloff, and against D65 at the achieved
        # luminance inside it, where only the balance is correctable.
        reference = d65_xyz(y) if in_rolloff else d65_xyz(target)
        level_de = de_itp([x, y, z], reference)
        neutral_samples.append({
            "code": code, "request": request, "target": target,
            "measured_y": y, "measured": [x, y, z],
            "rolloff": in_rolloff, "de_itp": level_de,
            "gains": gains,
        })

    if has_mhc2 and is_hdr:
        regularize_mhc2_neutral_samples(neutral_samples, damping)
    else:
        for sample in neutral_samples:
            sample["effective"] = [1.0 + damping * (gain - 1.0)
                                   for gain in sample["gains"]]

    for sample in neutral_samples:
        code = sample["code"]
        request = sample["request"]
        target = sample["target"]
        y = sample["measured_y"]
        in_rolloff = sample["rolloff"]
        gains = sample["gains"]
        effective = sample["effective"]
        levels.append({
            "pct": round(code * 100.0, 1),
            "target_nits": round(target, 3),
            "measured_nits": round(y, 3),
            "rolloff": in_rolloff,
            "de_itp": round(sample["de_itp"], 3),
            "gains": [round(g, 4) for g in gains],
            "before_err_pct": round((y / target - 1.0) * 100.0, 2),
            "predicted_err_pct": round((y * ((effective[0] + effective[1] + effective[2]) / 3.0)
                                        / target - 1.0) * 100.0, 2),
        })
        keyed.append((min(request, 0.995 * ymax), effective))
        mhc2_keyed.append((code, effective))
        shape.append((code, y, target, in_rolloff))
    if len(keyed) < 6:
        raise ValueError("Too few usable neutral reads above the meter floor")
    keyed.sort(key=lambda item: item[0])
    mhc2_keyed.sort(key=lambda item: item[0])

    # AutoCal-style sessions pass a tolerance: when every ladder level is
    # already inside it, leave the profile untouched and report convergence
    # instead of accumulating pointless micro-edits pass after pass.
    target_de = float(payload.get("target_de", 0.0) or 0.0)
    worst_de = max(lv["de_itp"] for lv in levels)
    inr_de = [lv["de_itp"] for lv in levels if not lv["rolloff"]]
    top_de = [lv["de_itp"] for lv in levels if lv["rolloff"]]
    before_de = {
        "inrange_mean": round(sum(inr_de) / len(inr_de), 3) if inr_de else None,
        "inrange_max": round(max(inr_de), 3) if inr_de else None,
        "rolloff_mean": round(sum(top_de) / len(top_de), 3) if top_de else None,
        "rolloff_max": round(max(top_de), 3) if top_de else None,
    }
    chromatic_des = [sample["level"]["de2000"] for sample in color_samples]
    color_de = {
        "mean": round(sum(chromatic_des) / len(chromatic_des), 3),
        "max": round(max(chromatic_des), 3),
        "patches": len(chromatic_des),
    } if chromatic_des else None

    def robust_worst(values):
        # The panel's white chroma drifts over a dE between reads in the
        # clipped band, so a single-patch max let one noisy reading out-score
        # a pass that improved every mean and the in-range max, stopping the
        # session and discarding the better result. Average the two largest
        # errors per band instead: still dominated by the worst region, no
        # longer vetoed by one reading.
        if not values:
            return 0.0
        ranked = sorted(values, reverse=True)
        return sum(ranked[:2]) / float(min(2, len(ranked)))

    def band_score(values):
        """Grade a region without letting one noisy point veto its mean.

        MHC2 fine-tuning is measured close to the meter floor and across a
        physically clipped HDR shoulder.  A max-only checkpoint selector can
        therefore discard a candidate that improved almost every level (and
        colour) because one dark or exact-white read moved by normal hardware
        noise.  Retain meaningful worst-point pressure, but make the regional
        mean the authority used to select the profile that is actually kept.
        """
        if not values:
            return 0.0
        mean = sum(values) / float(len(values))
        return 0.75 * mean + 0.25 * robust_worst(values)

    # Regional means should beat ordinary one-read noise, but they must not
    # hide a genuinely broken isolated level.  Keep half of the absolute
    # worst point as a generic safety rail.  It is deliberately softer than
    # max-only selection (so a 4-5 dE noisy white read cannot erase broad
    # gains), while a catastrophic spike such as 9 dE cannot win merely
    # because the colour-patch mean improved.
    point_guard = 0.5 * worst_de
    selection_score = max(band_score(inr_de), band_score(top_de), point_guard,
                          color_de["mean"] if color_de else 0.0)
    mode = ("mhc2" if has_mhc2 else "b2a") + ("-hdr" if is_hdr else "-sdr")
    checkpoint = checkpoint_session(payload, output_dir, measured_profile_data,
                                    selection_score, before_de, parent_path, mode,
                                    color_de=color_de, worst_de=worst_de)
    target_color_de = float(payload.get("target_color_de", 2.0) or 0.0)
    color_converged = not color_de or target_color_de <= 0.0 or color_de["mean"] <= target_color_de
    if target_de > 0.0 and worst_de <= target_de and color_converged:
        return {
            "status": "ok",
            "converged": True,
            "file": os.path.basename(parent_path),
            "parent": os.path.basename(parent_path),
            "mode": mode,
            "target_transfer": None if is_hdr else transfer,
            "target_transfer_source": None if is_hdr else transfer_source,
            "worst_de": round(worst_de, 3),
            "before_de": before_de,
            "color_de": color_de,
            "selection_score": round(selection_score, 3),
            "session_best_pass": checkpoint.get("best_pass") if checkpoint else None,
            "session_best_worst_de": checkpoint.get("best_worst_de") if checkpoint else None,
            "session_best_score": checkpoint.get("best_score") if checkpoint else None,
            "levels": sorted(levels, key=lambda item: item["pct"]),
            "color_levels": color_levels,
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

    def interpolate_gains(points, position):
        if position <= points[0][0]:
            return points[0][1]
        for i in range(1, len(points)):
            if points[i][0] >= position:
                n0, g0 = points[i - 1]
                n1, g1 = points[i]
                t = 0.0 if n1 == n0 else (position - n0) / (n1 - n0)
                return [g0[k] + t * (g1[k] - g0[k]) for k in range(3)]
        return points[-1][1]

    def residual_gains(nits):
        return interpolate_gains(keyed, nits)

    def mhc2_residual_gains(source_code):
        return interpolate_gains(mhc2_keyed, source_code)

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
    matrix_correction = None
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
        # adjustment curve set, applied in the wire signal domain by Windows.
        # Profiles that clone the same calibration into B2A need the edit
        # mirrored so Windows handling and explicit cLUT evaluation continue
        # to represent the same measured correction.
        off, _ = tags["MHC2"]
        entries = struct.unpack(">I", bytes(data[off + 8:off + 12]))[0]
        matrix_offset = struct.unpack(">I", bytes(data[off + 20:off + 24]))[0]
        current_matrix = [
            [s15(data, off + matrix_offset + row * 16 + column * 4)
             for column in range(3)] for row in range(3)
        ]
        original_matrix = [list(row) for row in current_matrix]
        matrix_samples = [(sample["measured"], sample["target"])
                          for sample in color_samples]
        matrix_correction = mhc2_residual_matrix(matrix_samples, damping)
        if matrix_correction is not None:
            # The builder's validated MHC2 direction is
            # physical * inverse(wire) * matrix.  A fitted correction maps the
            # measured XYZ residual back to target XYZ, so it belongs on the
            # right of the existing matrix.
            updated_matrix = mat_mul(current_matrix, matrix_correction)
            if all(math.isfinite(value) and abs(value) < 4.0
                   for row in updated_matrix for value in row):
                for row in range(3):
                    for column in range(3):
                        put_s15(data, off + matrix_offset + row * 16 + column * 4,
                                updated_matrix[row][column])
                current_matrix = updated_matrix
                move = max(abs(matrix_correction[row][column]
                               - (1.0 if row == column else 0.0))
                           for row in range(3) for column in range(3))
                if move >= 1e-5:
                    applied.append(move)
                for sample in color_samples:
                    predicted = mat_vec(matrix_correction, sample["measured"])
                    sample["level"]["predicted_de2000"] = round(
                        de2000(predicted, sample["target"]), 3)
            else:
                matrix_correction = None
        lut_offsets = struct.unpack(">III", bytes(data[off + 24:off + 36]))
        original_luts = []
        for ch in range(3):
            base = off + lut_offsets[ch] + 8
            original_luts.append([s15(data, base + index * 4)
                                  for index in range(entries)])
        # MHC2's matrix precedes its curves. A neutral source therefore enters
        # the three curves at different post-matrix PQ positions. Map each
        # curve input back to the original source code before looking up its
        # measured residual. Treating the curve index itself as source PQ was
        # shifting shadow corrections and the plateau boundary independently
        # in R, G and B.
        mhc2_neutral_gains = mat_vec(
            XYZ_TO_RGB2020, mat_vec(current_matrix, d65_xyz(1.0)))
        if min(mhc2_neutral_gains) <= 1e-6:
            mhc2_neutral_gains = [1.0, 1.0, 1.0]
        updated_luts = []
        endpoint_sample = next(
            (sample for sample in neutral_samples
             if sample.get("mhc2_endpoint")), None)
        # Hardware boundary probes located a clean split at normalized entry
        # 253: 99% remains on the corrected shoulder while exact maximum code
        # responds to entries 253-255. Use the same normalized boundary for
        # dense 4096-entry profiles rather than special-casing one table size.
        endpoint_start = mhc2_endpoint_start(entries)
        for ch in range(3):
            base = off + lut_offsets[ch] + 8
            original_curve = [s15(data, base + index * 4)
                              for index in range(entries)]
            updated_curve = list(original_curve)
            for index in range(entries):
                position = index / (entries - 1.0)
                if is_hdr:
                    source_nits = pq_to_nits(position) / mhc2_neutral_gains[ch]
                    source_code = nits_to_pq(source_nits)
                    request = source_nits
                    eff = mhc2_residual_gains(source_code)[ch]
                else:
                    request = sdr_target(position)
                    eff = residual_gains(min(request, 0.995 * ymax))[ch]
                if request < 0.02:
                    continue
                if abs(eff - 1.0) < 0.0005:
                    continue
                old = original_curve[index]
                clipped = max(0.0, min(1.0, old))
                if (is_hdr and index >= endpoint_start
                        and endpoint_sample is not None):
                    # Exact maximum code is a separate Windows Advanced Color
                    # tail region. Defer it until after the physical shoulder
                    # has been held, so every pass rebuilds it from the body
                    # rather than accumulating an endpoint-only offset.
                    new = clipped
                elif is_hdr and panel_channel_samples is not None:
                    response = sample_pairs(panel_channel_samples[ch], clipped)
                    new = invert_pairs(panel_channel_samples[ch],
                                       max(0.0, min(1.0, response * eff)))
                elif is_hdr:
                    new = nits_to_pq(pq_to_nits(clipped) * eff)
                else:
                    linear = clipped ** 2.2 if transfer != "srgb" else srgb_eotf(clipped)
                    linear = max(0.0, min(1.0, linear * eff))
                    new = linear ** (1.0 / 2.2) if transfer != "srgb" else srgb_inverse(linear)
                delta = max(-curve_bound, min(curve_bound, new - clipped))
                updated_curve[index] = old + delta
                if abs(delta) >= 0.5 / 65536.0:
                    applied.append(abs(eff - 1.0))
            updated_curve = isotonic_values(updated_curve)
            if is_hdr:
                tail_source = (original_curve[:endpoint_start]
                               if endpoint_sample is not None
                               else original_curve)
                tail = stable_tail_start(tail_source)
                if tail < entries - 1:
                    # Hold the shoulder independently of exact maximum code.
                    # Letting updated_curve[-1] select this value made the
                    # special 100% path recolour every 76-99% patch even though
                    # the display has only one physical plateau there.
                    held = max(updated_curve[tail],
                               updated_curve[tail - 1] if tail else 0.0)
                    if endpoint_sample is not None:
                        endpoint_value = min(
                            held + 0.035,
                            held * endpoint_sample["effective"][ch])
                    else:
                        endpoint_value = max(held, updated_curve[-1])
                    body_end = (endpoint_start if endpoint_sample is not None
                                else entries)
                    for index in range(tail, body_end):
                        updated_curve[index] = held
                    for index in range(body_end, entries):
                        updated_curve[index] = endpoint_value
            for index, value in enumerate(updated_curve):
                put_s15(data, base + index * 4, value)
            updated_luts.append(updated_curve)
        if mirrors_mhc2_in_b2a:
            if not is_hdr:
                raise ValueError("The B2A/MHC2 calibration contract requires HDR PQ")
            old_curves = mhc2_neutral_curves(original_matrix, original_luts)
            new_curves = mhc2_neutral_curves(current_matrix, updated_luts)
            remap_b2a_output_calibration(data, tags, old_curves, new_curves)
        elif independent_mhc2_and_b2a:
            # The explicit cLUT was fitted from the characterization directly.
            # Fine-tune readings in this branch measured Windows system
            # handling, so they contain no evidence that B2A needs the same
            # edit. Preserve its independently calibrated shapers.
            pass
        if "vcgt" in tags:
            voff, _ = tags["vcgt"]
            vchannels, ventries, vwidth = struct.unpack(">HHH", bytes(data[voff + 12:voff + 18]))
            if vwidth == 2 and vchannels == 3:
                vbase = voff + 18
                for ch in range(3):
                    previous = 0.0
                    for index in range(ventries):
                        position = index / (ventries - 1.0)
                        pos = vbase + (ch * ventries + index) * 2
                        if is_hdr:
                            # vcgt is the neutral-axis clone of matrix+MHC2.
                            # Rebuild it from those updated stages instead of
                            # applying a second, differently parameterized edit.
                            curve_input = nits_to_pq(
                                pq_to_nits(position) * mhc2_neutral_gains[ch])
                            new = sample_values(updated_luts[ch], curve_input)
                            previous = max(previous, max(0.0, min(1.0, new)))
                            value = max(0, min(65535,
                                               int(round(previous * 65535.0))))
                        else:
                            request = sdr_target(position)
                            if request < 0.02:
                                continue
                            eff = residual_gains(min(request, 0.995 * ymax))[ch]
                            if abs(eff - 1.0) < 0.0005:
                                continue
                            old = be16(data, pos) / 65535.0
                            linear = old ** 2.2 if transfer != "srgb" else srgb_eotf(old)
                            linear = max(0.0, min(1.0, linear * eff))
                            new = linear ** (1.0 / 2.2) if transfer != "srgb" else srgb_inverse(linear)
                            delta = max(-curve_bound, min(curve_bound, new - old))
                            value = max(0, min(65535,
                                               int(round((old + delta) * 65535.0))))
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

    # ---- local cLUT colour corrections --------------------------------------
    # A cLUT edits only the cell surrounding each colour's PCS position. In an
    # MHC2+cLUT profile, the two stages serve independent consumers. Windows
    # handling applies MHC2 without B2A, while explicit cLUT handling applies
    # B2A with Windows colour handling isolated. Give B2A the full measured
    # residual rather than subtracting a matrix stage absent from that path.
    # Matrix-family MHC2 profiles have no B2A table and stop above.
    if color_samples and "B2A0" in tags:
        adapt = bradford_adaptation(D65_WHITE, ICC_D50_WHITE)
        encode = 32768.0 / 65535.0

        def local_slope(wire):
            """Wire code per unit log-luminance around this drive level."""
            low = max(0.02, wire - 0.06)
            high = min(0.98, wire + 0.06)
            y_low = max(measured_lum(low), 1e-4)
            y_high = max(measured_lum(high), y_low * 1.0001)
            return (high - low) / (math.log(y_high) - math.log(y_low))

        color_bound = 2.5 / 1023.0
        for sample in color_samples:
            row = sample["row"]
            target = sample["target"]
            measured = sample["measured"]
            gains = channel_gains(measured, target)
            if primary_matrix is not None:
                rgb_m = mat_vec(primary_inverse, measured)
                strongest = max(rgb_m)
                if strongest > 0:
                    gains = [gain if rgb_m[channel] > 0.12 * strongest else 1.0
                             for channel, gain in enumerate(gains)]
            if has_mhc2 and matrix_correction is not None:
                sample["level"]["post_matrix_de2000"] = round(
                    de2000(mat_vec(matrix_correction, measured), target), 3)
            effective = [1.0 + damping * (g - 1.0) for g in gains]
            # Fine-tune moves, not gross corrections: a colour cell should
            # never shift by more than a few percent in one pass.
            effective = [max(0.90, min(1.11, e)) for e in effective]
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

    summary = {
        "status": "ok",
        "converged": False,
        "worst_de": round(worst_de, 3),
        "file": out_name,
        "parent": os.path.basename(parent_path),
        "mode": mode,
        "target_transfer": None if is_hdr else transfer,
        "target_transfer_source": None if is_hdr else transfer_source,
        "chroma_capable": primary_matrix is not None,
        "before_de": before_de,
        "color_de": color_de,
        "selection_score": round(selection_score, 3),
        "session_best_pass": checkpoint.get("best_pass") if checkpoint else None,
        "session_best_worst_de": checkpoint.get("best_worst_de") if checkpoint else None,
        "session_best_score": checkpoint.get("best_score") if checkpoint else None,
        "reads_used": len(keyed),
        "damping": damping,
        "max_correction_pct": round(max(applied) * 100.0, 2),
        "mean_correction_pct": round(sum(applied) / len(applied) * 100.0, 2),
        "levels": sorted(levels, key=lambda item: item["pct"]),
        "color_levels": color_levels,
        "mhc2_matrix_correction": (
            [[round(value, 7) for value in row] for row in matrix_correction]
            if matrix_correction is not None else None),
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
        if payload.get("action") == "finalize":
            result = finalize_session(payload, sys.argv[2])
        else:
            result = finetune(payload, sys.argv[2])
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except (ValueError, OSError, IOError, KeyError) as error:
        print(json.dumps({"status": "error", "message": str(error)},
                         separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())

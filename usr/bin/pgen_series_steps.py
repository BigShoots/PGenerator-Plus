#!/usr/bin/env python3
"""Normalize one generation of meter-series steps into a NUL stream."""

from __future__ import print_function

import json
import math
import os
import sys


SCHEMA_NAME = "pgen-series-steps"
SCHEMA_VERSION = "1"
READING_FIELDS = (
    "input_max", "patch_size", "stimulus", "signal_r_pct",
    "signal_g_pct", "signal_b_pct", "signal_mode", "target_gamma",
    "max_luma", "dv_map_mode", "analysis_ire", "target_ire",
    "transport_stimulus", "final_white_refresh", "target_x", "target_y",
    "target_Yn", "target_X", "target_Y", "target_Z",
    "dv_absolute_white_y", "dv_absolute_target_y",
    "dv_absolute_rolloff_pct", "dv_absolute_tunnel_gamma",
    "dv_absolute_st2084_precomp", "series_target_white_y",
    "lg_target_white_y", "series_target_black_y", "series_type",
    "series_color", "sat_pct", "point_role", "series_mode",
    "series_white_reference", "icc_reuse_signature", "autocal_code",
    "autocal_white_reference", "autocal_reference_only",
    "autocal_read_only", "autocal_slot_locked", "ddc_slot_locked",
    "autocal_legal_white_anchor", "ddc_target_ire", "autocal_order_ire",
    "autocal_target_label", "preview_r", "preview_g", "preview_b",
)


def finite(value):
    return not math.isinf(value) and not math.isnan(value)


def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return value if finite(value) else None


def scalar_text(value):
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"), allow_nan=False)
    return str(value)


def reject_nul(value, location="steps"):
    if isinstance(value, str):
        if "\0" in value:
            raise ValueError("embedded NUL is not allowed in %s" % location)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_nul(item, "%s[%d]" % (location, index))
    elif isinstance(value, dict):
        for key, item in value.items():
            reject_nul(key, "%s key" % location)
            reject_nul(item, "%s.%s" % (location, key))


def integer_field(step, name, index, minimum=0, default=None):
    value = step.get(name, default)
    if isinstance(value, bool):
        raise ValueError("step %d %s is not an integer" % (index, name))
    try:
        integer = int(value)
    except (TypeError, ValueError):
        raise ValueError("step %d %s is not an integer" % (index, name))
    if str(value).strip() not in (str(integer), str(float(integer))):
        raise ValueError("step %d %s is not an integer" % (index, name))
    if integer < minimum:
        raise ValueError("step %d %s is below its domain" % (index, name))
    return integer


def validate_step(step, index):
    if not isinstance(step, dict):
        raise ValueError("step %d is not an object" % index)
    reject_nul(step, "step %d" % index)
    input_max = integer_field(step, "input_max", index, 1, 255)
    codes = [integer_field(step, channel, index) for channel in ("r", "g", "b")]
    if any(code > input_max for code in codes):
        raise ValueError("step %d drive code exceeds input_max" % index)
    ire = number(step.get("ire"))
    if ire is None:
        raise ValueError("step %d ire is not finite" % index)
    name = step.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("step %d name is empty or not text" % index)
    return codes, input_max, ire, name


def expected_luminance(step):
    for key in ("target_Y", "dv_absolute_target_y"):
        if key in step:
            value = number(step.get(key))
            return value if value is not None and value >= 0 else None
    if "custom_target_nits" in step:
        value = number(step.get("custom_target_nits"))
        return value if value is not None and value > 0 else None
    target_yn = number(step.get("target_Yn"))
    black_y = number(step.get("series_target_black_y"))
    if black_y is None or black_y < 0:
        black_y = 0.0
    if target_yn is None or target_yn < 0:
        return None
    if target_yn == 0:
        return black_y
    for key in ("dv_absolute_white_y", "series_target_white_y",
                "lg_target_white_y"):
        white_y = number(step.get(key))
        if white_y is not None and white_y > 0:
            return max(black_y, target_yn * white_y)
    return None


def effective_low_light_mode(step, selected_mode, trigger):
    if selected_mode not in ("a", "aa", "aaa"):
        return "off"
    trigger = number(trigger)
    if trigger is None or trigger <= 0:
        return "off"
    expected = expected_luminance(step)
    if expected is None or expected < 0 or not finite(expected):
        return "off"
    return selected_mode if expected < trigger else "off"


def reading_metadata(step, codes, observer):
    metadata = {
        "ire": step["ire"],
        "name": step["name"],
        "r_code": codes[0],
        "g_code": codes[1],
        "b_code": codes[2],
        "observer": observer,
    }
    for field in READING_FIELDS:
        if field in step:
            metadata[field] = step[field]
    encoded = json.dumps(metadata, separators=(",", ":"), allow_nan=False)
    return encoded[1:-1]


def write_field(value):
    data = scalar_text(value).encode("utf-8") + b"\0"
    sys.stdout.buffer.write(data)


def normalize(path, generation, selected_mode, trigger, observer):
    with open(path) as handle:
        steps = json.load(handle)
    if not isinstance(steps, list):
        raise ValueError("steps root must be an array")
    if len(steps) > 100000:
        raise ValueError("too many series steps")
    write_field(SCHEMA_NAME)
    write_field(SCHEMA_VERSION)
    write_field(generation)
    write_field(len(steps))
    for index, step in enumerate(steps):
        codes, input_max, ire, name = validate_step(step, index)
        full_json = json.dumps(step, separators=(",", ":"), allow_nan=False)
        fields = (
            index, codes[0], codes[1], codes[2], input_max,
            step.get("patch_size", ""), step.get("read_delay_ms", ""),
            step["ire"], name, step.get("series_white_reference", ""),
            step.get("final_white_refresh", ""), step.get("target_Yn", ""),
            effective_low_light_mode(step, selected_mode, trigger),
            step.get("autocal_white_reference", ""), full_json,
            reading_metadata(step, codes, observer),
        )
        for field in fields:
            write_field(field)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 6 or argv[0] != "normalize":
        sys.stderr.write(
            "usage: pgen_series_steps.py normalize PATH GENERATION MODE "
            "TRIGGER OBSERVER\n")
        return 1
    try:
        normalize(argv[1], argv[2], argv[3], argv[4], argv[5])
    except (IOError, OSError, TypeError, ValueError) as exc:
        sys.stderr.write("series-step normalization failed: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

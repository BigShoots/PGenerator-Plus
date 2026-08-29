#!/usr/bin/env python3
"""Parse and average PGenerator+ meter records with one maths owner."""

from __future__ import print_function

import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgen_colour_math import (average_xyz_measurements, cct_from_xy,
                              finite_number, xyz_derived_fields)


NUMBER = (r"[+-]?(?:(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
          r"|inf(?:inity)?|nan)")
RESULT_RE = re.compile(
    r"Result is XYZ:\s*(%s)\s+(%s)\s+(%s)"
    r"(?:\s*,\s*Yxy:\s*(%s)\s+(%s)\s+(%s))?" % ((NUMBER,) * 6),
    re.IGNORECASE)
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def parse_spotread_result(text, timestamp=None):
    """Return the last complete spotread result in *text* as a JSON record."""
    if not isinstance(text, str):
        raise ValueError("spotread result must be text")
    matches = list(RESULT_RE.finditer(ANSI_RE.sub("", text.replace("\r", ""))))
    if not matches:
        raise ValueError("no complete spotread result found")
    values = matches[-1].groups()
    X = finite_number(values[0], "X")
    Y = finite_number(values[1], "Y")
    Z = finite_number(values[2], "Z")
    result = {"X": X, "Y": Y, "Z": Z}
    if values[3] is None:
        result.update(xyz_derived_fields(X, Y, Z))
    else:
        luminance = finite_number(values[3], "luminance")
        x = finite_number(values[4], "x")
        y = finite_number(values[5], "y")
        result.update({
            "luminance": luminance,
            "x": x,
            "y": y,
            "cct": cct_from_xy(x, y),
        })
    result["timestamp"] = int(time.time() if timestamp is None else timestamp)
    result["sample_count"] = 1
    result["requested_sample_count"] = 1
    result["average_mode"] = "off"
    return result


def average_record(readings, mode=None, requested_sample_count=None,
                   timestamp=None):
    """Average readings in XYZ, then derive nonlinear fields once."""
    averaged = average_xyz_measurements(readings)
    requested = (len(readings) if requested_sample_count is None
                 else int(requested_sample_count))
    if requested < 1 or requested > 100:
        raise ValueError("requested sample count is outside its domain")
    if requested != len(readings):
        raise ValueError("requested sample count does not match actual readings")
    result = dict(readings[0])
    result.update(averaged)
    result["timestamp"] = int(time.time() if timestamp is None else timestamp)
    if mode is not None:
        if mode not in ("off", "a", "aa", "aaa"):
            raise ValueError("unsupported average mode")
        result["average_mode"] = mode
    result["requested_sample_count"] = requested
    return result


def emit_record(record):
    json.dump(record, sys.stdout, separators=(",", ":"), allow_nan=False)
    sys.stdout.write("\n")


def parse_main():
    emit_record(parse_spotread_result(sys.stdin.read()))


def average_main(legacy_environment=False):
    readings = json.load(sys.stdin)
    if legacy_environment:
        mode = os.environ.get("PGEN_AVERAGE_MODE", "off")
        requested = os.environ.get("PGEN_REQUESTED_SAMPLE_COUNT",
                                   str(len(readings)))
    else:
        mode = os.environ.get("PGEN_AVERAGE_MODE")
        requested = os.environ.get("PGEN_REQUESTED_SAMPLE_COUNT")
    emit_record(average_record(readings, mode, requested))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if argv == ["parse"]:
            parse_main()
        elif argv == ["average"]:
            average_main()
        else:
            raise ValueError("usage: pgen_meter_result.py parse|average")
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        sys.stderr.write("meter result failed: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

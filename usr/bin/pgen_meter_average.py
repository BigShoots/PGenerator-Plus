#!/usr/bin/env python3
"""Average repeated meter readings in linear CIE XYZ space.

Input is a JSON array of reading objects on stdin.  Output is one reading
object.  XYZ is reduced with CPython's compensated math.fsum; chromaticity and
CCT are derived once from the averaged XYZ, never averaged independently.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgen_colour_math import average_xyz_measurements


def main():
    try:
        readings = json.load(sys.stdin)
        averaged = average_xyz_measurements(readings)
        mode = os.environ.get("PGEN_AVERAGE_MODE", "off")
        expected_by_mode = {"off": 1, "a": 2, "aa": 3, "aaa": 5}
        if mode not in expected_by_mode:
            raise ValueError("unsupported average mode")
        requested = int(
            os.environ.get("PGEN_REQUESTED_SAMPLE_COUNT", str(len(readings)))
        )
        if requested != len(readings) or requested != expected_by_mode[mode]:
            raise ValueError("sample count does not match the requested mode")
        result = dict(readings[0])
        result.update(averaged)
        result["timestamp"] = int(time.time())
        result["average_mode"] = mode
        result["requested_sample_count"] = requested
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        sys.stderr.write("meter average failed: %s\n" % exc)
        return 1
    json.dump(result, sys.stdout, separators=(",", ":"), allow_nan=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

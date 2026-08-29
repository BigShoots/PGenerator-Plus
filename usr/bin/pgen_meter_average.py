#!/usr/bin/env python3
"""Average repeated meter readings in linear CIE XYZ space.

Input is a JSON array of reading objects on stdin.  Output is one reading
object.  XYZ is reduced with CPython's compensated math.fsum; chromaticity and
CCT are derived once from the averaged XYZ, never averaged independently.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pgen_meter_result import average_main


def main():
    try:
        average_main(legacy_environment=True)
    except (ValueError, TypeError) as exc:
        sys.stderr.write("meter average failed: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

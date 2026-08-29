#!/usr/bin/env python3
from __future__ import print_function

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "usr", "bin"))

from pgen_colour_math import delta_e_2000_lab, xyz_to_lab
from icc_finetune import finetune_de2000

with open(os.path.join(ROOT, "t", "fixtures", "ciede2000_sharma.json")) as stream:
    fixture = json.load(stream)

for index, row in enumerate(fixture["pairs"]):
    actual = delta_e_2000_lab(row["first"], row["second"])
    if abs(actual - row["delta_e"]) > 0.00005:
        raise AssertionError("published pair {} differs: {} != {}".format(
            index, actual, row["delta_e"]))

actual = xyz_to_lab(
    [-1, 0, 2], [0.95047 * 203, 203, 1.08883 * 203],
    ratio_policy="ratio_floor_1e_minus_9")
expected = [9.0329629642837972e-07, 0, -14.089976383223624]
for index, (value, wanted) in enumerate(zip(actual, expected)):
    if abs(value - wanted) > 2e-12:
        raise AssertionError("ratio-floor component {} differs".format(index))

finetune_snapshots = [
    ([20, 30, 10], [22, 29, 11], 4.9581479141253029),
    ([0, 0, 0], [0.01, 0.02, 0.03], 0.28170350759596502),
    ([-1, 0, 2], [3, -0.5, 1], 29.96586619848641),
]
for index, (first, second, wanted) in enumerate(finetune_snapshots):
    actual = finetune_de2000(first, second)
    if abs(actual - wanted) > 2e-14:
        raise AssertionError("pre-move fine-tune snapshot {} differs".format(index))

print("{} published Python CIEDE2000 pairs passed".format(len(fixture["pairs"])))

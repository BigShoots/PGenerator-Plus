#!/usr/bin/env python3
"""End-to-end gates for chunk-bounded Companion LUT output."""

from __future__ import print_function

import glob
import hashlib
import importlib.util
import os
import resource
import shutil
import stat
import sys
import tempfile

import numpy as np


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "usr", "bin")
if BIN not in sys.path:
    sys.path.insert(0, BIN)

spec = importlib.util.spec_from_file_location(
    "icc_companion_lut_streaming",
    os.path.join(BIN, "icc_companion_lut.py"))
COMPANION = importlib.util.module_from_spec(spec)
spec.loader.exec_module(COMPANION)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return digest.hexdigest()
            digest.update(block)


class EchoTransform(object):
    def apply(self, xyz):
        return xyz


class FailingTransform(object):
    def __init__(self):
        self.calls = 0

    def apply(self, xyz):
        self.calls += 1
        if self.calls == 2:
            raise ValueError("injected second-chunk failure")
        return xyz


def fake_transform(transform):
    return (transform, 1.0,
            ((1.0, 0.0, 0.0),
             (0.0, 1.0, 0.0),
             (0.0, 0.0, 1.0)))


def expected_coordinates(size, start, stop, red_fastest):
    expected = []
    if red_fastest:
        walk = ((red, green, blue)
                for blue in range(size)
                for green in range(size)
                for red in range(size))
    else:
        walk = ((red, green, blue)
                for red in range(size)
                for green in range(size)
                for blue in range(size))
    denominator = size - 1.0
    for index, node in enumerate(walk):
        if index >= stop:
            break
        if index >= start:
            expected.append([axis / denominator for axis in node])
    return np.asarray(expected, dtype=np.float64)


for size in (2, 5, 65, 129):
    total = size ** 3
    windows = ((0, min(total, 17)),
               (max(0, size * size - 3), min(total, size * size + 4)),
               (max(0, total - 11), total))
    for red_fastest in (False, True):
        for start, stop in windows:
            actual = COMPANION.lattice_coordinates(
                size, start, stop, red_fastest)
            expected = expected_coordinates(
                size, start, stop, red_fastest)
            require(np.array_equal(actual, expected),
                    "lattice order differs for size {} {} nodes {}:{}".format(
                        size, "red-fastest" if red_fastest else "red-slowest",
                        start, stop))


original_make_transform = COMPANION.make_transform
directory = tempfile.mkdtemp(prefix="pgen-companion-stream-")
try:
    COMPANION.make_transform = lambda *args: fake_transform(EchoTransform())
    expected_hashes = {
        "fixture.pglt": "4ebf7dfa85bd7812e7589301f24ddc8117b2d37817825aae7530efdab85f5643",
        "fixture-65.cube": "cad6f98f789accdf5c069a9d8056b67ebddedbf1d5c7288f728a0305a1b85a05",
        "fixture-129.cube": "4a9eac3452fe1daf34c6f5d055772a6e94669e8e70c7871846c3bd1401f49cd9",
    }
    pglt = os.path.join(directory, "fixture.pglt")
    COMPANION.build("fixture.icc", "matrix", "sdr", pglt)
    cube65 = os.path.join(directory, "fixture-65.cube")
    COMPANION.build_cube("fixture.icc", "matrix", "sdr", cube65, 65,
                         title="fixture")
    cube129 = os.path.join(directory, "fixture-129.cube")
    COMPANION.build_cube("fixture.icc", "matrix", "sdr", cube129, 129,
                         title="fixture")
    for path in (pglt, cube65, cube129):
        require(sha256_file(path) == expected_hashes[os.path.basename(path)],
                "{} differs from the approved pre-streaming bytes".format(
                    os.path.basename(path)))
        require(stat.S_IMODE(os.stat(path).st_mode) == 0o600,
                "{} was not created with mode 0600".format(
                    os.path.basename(path)))

    # The old predictable output.tmp.PID name followed this symlink and
    # overwrote the victim before replacing the link. A secure exclusive temp
    # in the destination directory never touches it.
    victim = os.path.join(directory, "symlink-victim")
    with open(victim, "wb") as handle:
        handle.write(b"victim-must-survive")
    guarded = os.path.join(directory, "guarded.pglt")
    predictable = guarded + ".tmp.{}".format(os.getpid())
    os.symlink(victim, predictable)
    COMPANION.build("fixture.icc", "matrix", "sdr", guarded)
    with open(victim, "rb") as handle:
        require(handle.read() == b"victim-must-survive",
                "predictable temporary symlink target was overwritten")

    # A streamed file has already received its header and first block when
    # this failure fires. The destination must remain intact and no random
    # temporary may survive the finally path.
    failed = os.path.join(directory, "failed.cube")
    with open(failed, "wb") as handle:
        handle.write(b"approved-existing-output")
    before = set(glob.glob(os.path.join(directory, ".failed.cube.tmp.*")))
    COMPANION.make_transform = lambda *args: fake_transform(FailingTransform())
    try:
        COMPANION.build_cube("fixture.icc", "matrix", "sdr", failed, 129,
                             title="fixture")
        raise AssertionError("injected chunk failure was not raised")
    except ValueError as error:
        require(str(error) == "injected second-chunk failure",
                "unexpected injected failure: {}".format(error))
    with open(failed, "rb") as handle:
        require(handle.read() == b"approved-existing-output",
                "failed streamed output replaced the destination")
    after = set(glob.glob(os.path.join(directory, ".failed.cube.tmp.*")))
    require(after == before, "failed streamed output left an orphan temporary")
finally:
    COMPANION.make_transform = original_make_transform
    shutil.rmtree(directory)


peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
if sys.platform != "darwin":
    peak_rss *= 1024
limit = 96 * 1024 * 1024
require(peak_rss <= limit,
        "streaming fixture peak RSS {} bytes exceeds {} bytes".format(
            peak_rss, limit))
print("Companion streaming parity and safety passed; peak_rss_bytes={}".format(
    peak_rss))

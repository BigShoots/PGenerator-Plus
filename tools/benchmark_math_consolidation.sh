#!/usr/bin/env bash

# Paired fresh-process benchmarks for calibration-maths changes. Correctness
# stays in TAP/conformance tests; this driver records timing, CPU, RSS, output
# size and output hash without adding elapsed-time assertions to those tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_ROOT=""
CANDIDATE_ROOT="$DEFAULT_ROOT"
WORKLOAD="scalar-colour"
RUNS=20
SEED=1729
OUTPUT=""
BENCH_PYTHON="${PGEN_BENCH_PYTHON:-python3}"
BENCH_PERL="${PGEN_BENCH_PERL:-perl}"

usage() {
 cat <<'EOF'
Usage: tools/benchmark_math_consolidation.sh --baseline DIR [options]

Options:
  --candidate DIR   Candidate checkout or staged tree. Default: this checkout.
  --workload NAME   perl-startup, python-startup, scalar-colour, or meter-average.
  --runs N          Number of paired samples. Default: 20. Startup requires 30.
  --seed N          Deterministic balanced AB/BA block seed. Default: 1729.
  --output PATH     Save the TSV samples. Default: temporary file plus stdout.
  -h, --help        Show this help.

Each pair contains one baseline and one candidate sample. Consecutive pairs
form a balanced block containing one AB and one BA order; the seeded generator
randomizes which order starts the block. Every sample runs in a fresh wrapper
process, so maximum RSS is a per-workload high-water mark.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

while [[ $# -gt 0 ]]; do
 case "$1" in
  --baseline) [[ $# -ge 2 ]] || die "Missing --baseline value"; BASELINE_ROOT="$2"; shift 2 ;;
  --candidate) [[ $# -ge 2 ]] || die "Missing --candidate value"; CANDIDATE_ROOT="$2"; shift 2 ;;
  --workload) [[ $# -ge 2 ]] || die "Missing --workload value"; WORKLOAD="$2"; shift 2 ;;
  --runs) [[ $# -ge 2 ]] || die "Missing --runs value"; RUNS="$2"; shift 2 ;;
  --seed) [[ $# -ge 2 ]] || die "Missing --seed value"; SEED="$2"; shift 2 ;;
  --output) [[ $# -ge 2 ]] || die "Missing --output value"; OUTPUT="$2"; shift 2 ;;
  -h|--help) usage; exit 0 ;;
  *) die "Unknown option: $1" ;;
 esac
done

[[ -n "$BASELINE_ROOT" ]] || die "--baseline is required"
[[ -d "$BASELINE_ROOT" ]] || die "Baseline directory does not exist: $BASELINE_ROOT"
[[ -d "$CANDIDATE_ROOT" ]] || die "Candidate directory does not exist: $CANDIDATE_ROOT"
[[ "$RUNS" =~ ^[0-9]+$ ]] && [[ "$RUNS" -gt 0 ]] || die "--runs must be a positive integer"
[[ "$SEED" =~ ^[0-9]+$ ]] || die "--seed must be a non-negative integer"
case "$WORKLOAD" in
 perl-startup|python-startup|scalar-colour|meter-average) ;;
 *) die "Unsupported workload: $WORKLOAD" ;;
esac
if [[ "$WORKLOAD" == *-startup ]] && [[ "$RUNS" -lt 30 ]]; then
 die "$WORKLOAD requires at least 30 paired samples"
fi
command -v "$BENCH_PYTHON" >/dev/null 2>&1 || die "Python is unavailable: $BENCH_PYTHON"
command -v "$BENCH_PERL" >/dev/null 2>&1 || die "Perl is unavailable: $BENCH_PERL"

TEMP_OUTPUT=0
if [[ -z "$OUTPUT" ]]; then
 OUTPUT="$(mktemp "${TMPDIR:-/tmp}/pgen-math-benchmark.XXXXXX")"
 TEMP_OUTPUT=1
else
 mkdir -p "$(dirname "$OUTPUT")"
 : >"$OUTPUT"
fi

cleanup() {
 local status=$?
 if [[ "$TEMP_OUTPUT" -eq 1 ]]; then
  rm -f -- "$OUTPUT"
 fi
 return "$status"
}
trap cleanup EXIT

commit_for_root() {
 git -C "$1" rev-parse HEAD 2>/dev/null || printf '%s\n' unknown
}

echo "# workload=$WORKLOAD runs=$RUNS seed=$SEED" >&2
echo "# platform=$(uname -srm)" >&2
echo "# python=$($BENCH_PYTHON --version 2>&1)" >&2
echo "# baseline=$BASELINE_ROOT commit=$(commit_for_root "$BASELINE_ROOT")" >&2
echo "# candidate=$CANDIDATE_ROOT commit=$(commit_for_root "$CANDIDATE_ROOT")" >&2
printf 'pair\torder\trole\twall_ms\tuser_ms\tsystem_ms\tmax_rss_bytes\toutput_bytes\tsha256\n' >"$OUTPUT"

run_sample() {
 local pair="$1"
 local order="$2"
 local role="$3"
 local root="$4"
 local metrics
 metrics="$($BENCH_PYTHON - "$root" "$WORKLOAD" "$BENCH_PYTHON" <<'PY'
from __future__ import print_function

import hashlib
import json
import os
import resource
import subprocess
import sys
import time

root, workload, python = sys.argv[1:4]
env = dict(os.environ)
env["PYTHONDONTWRITEBYTECODE"] = "1"
stdin_data = None

if workload == "perl-startup":
    perl = os.environ.get("PGEN_BENCH_PERL", "perl")
    command = [perl, "-I" + os.path.join(root, "usr", "share", "PGenerator"),
               "-MPGCalibrationMath=dpg_smooth_blend_index",
               "-e", "print dpg_smooth_blend_index(), qq{\\n}"]
elif workload == "python-startup":
    code = ("import sys; sys.path.insert(0, sys.argv[1]); "
            "import pgen_colour_math; print(pgen_colour_math.PQ_C2)")
    command = [python, "-c", code, os.path.join(root, "usr", "bin")]
elif workload == "scalar-colour":
    code = """from __future__ import print_function
import sys
sys.path.insert(0, sys.argv[1])
import pgen_colour_math as m
value = 0.0
for index in range(250000):
    nits = (index % 10001) * 0.9999
    encoded = m.pq_encode_nits(nits, clamp_peak=True)
    value += m.pq_decode_nits(encoded)
print(\"{:.17g}\".format(value))
"""
    command = [python, "-c", code, os.path.join(root, "usr", "bin")]
elif workload == "meter-average":
    command = [python, os.path.join(root, "usr", "bin", "pgen_meter_average.py")]
    env["PGEN_AVERAGE_MODE"] = "aaa"
    env["PGEN_REQUESTED_SAMPLE_COUNT"] = "5"
    stdin_data = json.dumps([
        {"X": 0.9404559, "Y": 0.99, "Z": 1.0790578},
        {"X": 0.9454559, "Y": 0.995, "Z": 1.0840578},
        {"X": 0.9504559, "Y": 1.0, "Z": 1.0890578},
        {"X": 0.9554559, "Y": 1.005, "Z": 1.0940578},
        {"X": 0.9604559, "Y": 1.01, "Z": 1.0990578},
    ]).encode("ascii")
else:
    raise SystemExit("unknown workload")

started = time.monotonic()
process = subprocess.Popen(command, stdin=subprocess.PIPE if stdin_data is not None else None,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
stdout, stderr = process.communicate(stdin_data)
elapsed = time.monotonic() - started
usage = resource.getrusage(resource.RUSAGE_CHILDREN)
if process.returncode != 0:
    sys.stderr.write(stderr.decode("utf-8", "replace"))
    raise SystemExit(process.returncode)
rss = int(usage.ru_maxrss)
if sys.platform != "darwin":
    rss *= 1024
hash_bytes = stdout
if workload == "meter-average":
    normalized = json.loads(stdout.decode("utf-8"))
    normalized.pop("timestamp", None)
    hash_bytes = json.dumps(normalized, sort_keys=True,
                            separators=(",", ":")).encode("utf-8")
print("{:.6f}\t{:.6f}\t{:.6f}\t{}\t{}\t{}".format(
    elapsed * 1000.0, usage.ru_utime * 1000.0, usage.ru_stime * 1000.0,
    rss, len(stdout), hashlib.sha256(hash_bytes).hexdigest()))
PY
)"
 printf '%s\t%s\t%s\t%s\n' "$pair" "$order" "$role" "$metrics" | tee -a "$OUTPUT"
}

# Each two-pair block has one AB and one BA pair. The LCG decides which comes
# first, avoiding a fixed old/new alternation while retaining exact balance.
state=$((SEED % 2147483648))
for ((pair=1; pair<=RUNS; pair++)); do
 block_index=$(((pair-1)/2))
 if (( (pair-1)%2 == 0 )); then
  state=$(((1103515245*state+12345) % 2147483648))
  block_first=$((state % 2))
 fi
 if (( ((pair-1)%2) == block_first )); then
  order="AB"
  run_sample "$pair" "$order" baseline "$BASELINE_ROOT"
  run_sample "$pair" "$order" candidate "$CANDIDATE_ROOT"
 else
  order="BA"
  run_sample "$pair" "$order" candidate "$CANDIDATE_ROOT"
  run_sample "$pair" "$order" baseline "$BASELINE_ROOT"
 fi
done

$BENCH_PYTHON - "$OUTPUT" <<'PY'
from __future__ import print_function

import csv
import random
import statistics
import sys

path = sys.argv[1]
with open(path) as stream:
    rows = list(csv.DictReader((line for line in stream if not line.startswith("#")),
                               delimiter="\t"))

def confidence(values, seed):
    rng = random.Random(seed)
    samples = []
    for unused in range(10000):
        picked = [values[rng.randrange(len(values))] for ignored in values]
        samples.append(statistics.median(picked))
    samples.sort()
    return samples[int(0.025 * len(samples))], samples[int(0.975 * len(samples))]

by_pair = {}
for row in rows:
    by_pair.setdefault(row["pair"], {})[row["role"]] = row

for field, unit in (("wall_ms", "ms"), ("max_rss_bytes", "bytes")):
    absolute = []
    relative = []
    for pair in sorted(by_pair, key=int):
        old = float(by_pair[pair]["baseline"][field])
        new = float(by_pair[pair]["candidate"][field])
        absolute.append(new - old)
        relative.append(new / old - 1.0 if old else 0.0)
    alo, ahi = confidence(absolute, 11939)
    rlo, rhi = confidence(relative, 47843)
    print("summary {} median_absolute={:.6f}{} ci95=[{:.6f},{:.6f}] "
          "median_relative={:.6%} ci95=[{:.6%},{:.6%}]".format(
              field, statistics.median(absolute), unit, alo, ahi,
              statistics.median(relative), rlo, rhi))

hashes = {}
for row in rows:
    hashes.setdefault(row["role"], set()).add(row["sha256"])
if len(hashes.get("baseline", ())) != 1 or len(hashes.get("candidate", ())) != 1:
    raise SystemExit("workload output was not deterministic within a side")
if hashes["baseline"] != hashes["candidate"]:
    raise SystemExit("baseline and candidate output hashes differ")
print("summary output_hash={} exact_match=yes".format(next(iter(hashes["baseline"]))))
PY

if [[ "$TEMP_OUTPUT" -eq 0 ]]; then
 echo "Saved samples: $OUTPUT" >&2
fi

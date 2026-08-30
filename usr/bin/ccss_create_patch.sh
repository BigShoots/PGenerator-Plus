#!/usr/bin/env bash

set -euo pipefail

R="${1:-0}"
G="${2:-0}"
B="${3:-0}"
PATCH_SIZE="${PG_CCSS_PATCH_SIZE:-18}"
SIGNAL_MODE="${PG_CCSS_SIGNAL_MODE:-sdr}"
MAX_LUMA="${PG_CCSS_MAX_LUMA:-1000}"
SETTLE_SEC="${PG_CCSS_SETTLE_SEC:-0.8}"

curl -fsS http://127.0.0.1/api/pattern \
 -X POST \
 -H 'Content-Type: application/json' \
 -d "{\"name\":\"patch\",\"r\":${R},\"g\":${G},\"b\":${B},\"size\":${PATCH_SIZE},\"input_max\":255,\"signal_mode\":\"${SIGNAL_MODE}\",\"max_luma\":${MAX_LUMA}}" \
 >/dev/null

sleep "$SETTLE_SEC"
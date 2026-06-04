#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHON_BIN="${PYTHON_BIN:-python3}"
HELPER="$(awk '/^nonblack_zero_reading\(\) \{/{flag=1} flag{print} flag && /^}/{exit}' "$ROOT/usr/bin/meter_series.sh")"
eval "$HELPER"
NORMALIZER="$(awk '/^normalize_oled_zero_black_reading\(\) \{/{flag=1} flag{print} flag && /^}/{exit}' "$ROOT/usr/bin/meter_series.sh")"
eval "$NORMALIZER"

assert_true() {
 if ! "$@"; then
  echo "Expected success: $*" >&2
  exit 1
 fi
}

assert_false() {
 if "$@"; then
  echo "Expected failure: $*" >&2
  exit 1
 fi
}

ZERO='{"X":0,"Y":0,"Z":0,"luminance":0,"x":0,"y":0}'
NONZERO='{"X":0.1,"Y":0,"Z":0,"luminance":0,"x":0,"y":0}'

assert_true nonblack_zero_reading "$ZERO" 10 26 26 26
assert_true nonblack_zero_reading "$ZERO" "" 255 0 0
assert_false nonblack_zero_reading "$ZERO" 0 0 0 0
assert_false nonblack_zero_reading "$NONZERO" 10 26 26 26

export DISPLAY_TYPE="oled_generic"
TINY_BLACK='{"X":0.003356,"Y":0.001273,"Z":0.000001,"x":0.724745,"y":0.274947,"luminance":0.001273,"ire":0,"name":"0%","series_type":"greyscale","target_Yn":0}'
NORMALIZED=$(normalize_oled_zero_black_reading "$TINY_BLACK")
printf '%s' "$NORMALIZED" | grep -q '"Y":0'
printf '%s' "$NORMALIZED" | grep -q '"luminance":0'
printf '%s' "$NORMALIZED" | grep -q '"raw_y":0.274947'
printf '%s' "$NORMALIZED" | grep -q '"black_normalization_reason":"sdr_oled_series_zero_target"'
if printf '%s' "$NORMALIZED" | grep -q '"x":'; then
 echo "normalized OLED black should not keep unstable x" >&2
 exit 1
fi

export DISPLAY_TYPE="lcd"
assert_false normalize_oled_zero_black_reading "$TINY_BLACK"

export CCSS_FILE="/usr/share/PGenerator/ccss/WRGB_OLED_LG.ccss"
NORMALIZED=$(normalize_oled_zero_black_reading "$TINY_BLACK")
printf '%s' "$NORMALIZED" | grep -q '"Y":0'
printf '%s' "$NORMALIZED" | grep -q '"black_normalization_reason":"sdr_oled_series_zero_target"'

echo "meter-series-zero-guard OK"

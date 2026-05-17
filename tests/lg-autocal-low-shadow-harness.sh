#!/usr/bin/env bash
# Focused LG 26pt low-shadow AutoCal run.
#
# This reads target white, resets the LG 1D DDC state, calibrates 109% to
# establish the headroom-derived white reference, then calibrates only the low
# greyscale slots. It intentionally skips a full 26pt pass and post-series read.

set -euo pipefail

LABEL="${1:-low-shadow}"
export STEP_LIST="${STEP_LIST:-109,2.3,3,4,5,7,10}"
export POST_COMMIT_POLISH="${POST_COMMIT_POLISH:-false}"
export DELAY_MS="${DELAY_MS:-1800}"
export PATCH_SIZE="${PATCH_SIZE:-10}"
export PROFILE="${PROFILE:-ccss_LG_C2_(WRGB_OLED)_-_JETI_1501_HiRes_2nm.ccss}"

exec "$(dirname "$0")/lg-autocal-ab-harness.sh" "$LABEL"

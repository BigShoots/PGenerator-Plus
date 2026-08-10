#!/bin/sh

set -eu

# Standalone ICC Tools are distributed from their own GitHub release. Remove
# copies inherited from 2.11.1 so an OTA installation matches a fresh image.
rm -f -- /usr/bin/icc_companion_package.py
rm -rf -- /usr/share/PGenerator/icc-companion
rm -rf -- /usr/share/PGenerator/icc-companion-src

printf 'Removed bundled ICC Tools for %s -> %s\n' \
 "${PG_UPDATE_FROM:-unknown}" "${PG_UPDATE_TO:-unknown}"

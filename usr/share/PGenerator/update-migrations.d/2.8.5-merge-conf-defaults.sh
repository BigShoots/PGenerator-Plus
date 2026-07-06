#!/bin/sh
#
# 2.8.5-merge-conf-defaults.sh — bridge migration for the OTA packaging
# change that stopped shipping /etc/PGenerator/PGenerator.conf inside the
# OTA tarball (it holds operator state and was being reset to factory
# defaults on every update). Factory defaults now ship as
# PGenerator.conf.dist.
#
# Updaters from 2.8.5 onward merge new default keys themselves
# (merge_conf_defaults in pgenerator-update). Devices on 2.8.1-2.8.4 run
# their OLD updater when applying this release, so this migration performs
# the same merge for them: append any default key missing from the live
# conf, never touching existing values.

set -eu

DIST="/etc/PGenerator/PGenerator.conf.dist"
CONF="/etc/PGenerator/PGenerator.conf"

[ -f "$DIST" ] || exit 0

if [ ! -f "$CONF" ]; then
 cp -a "$DIST" "$CONF"
 echo "conf: installed factory defaults (no existing PGenerator.conf)"
 exit 0
fi

added=0
while IFS= read -r line; do
 case "$line" in ''|'#'*) continue ;; esac
 key="${line%%=*}"
 [ -n "$key" ] || continue
 case "$key" in *[!A-Za-z0-9_]* ) continue ;; esac
 if ! grep -q "^${key}=" "$CONF"; then
  printf '%s\n' "$line" >> "$CONF"
  added=$((added + 1))
  echo "conf: added new default key ${key}"
 fi
done < "$DIST"

[ "$added" -gt 0 ] && sync
exit 0

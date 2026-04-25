#!/usr/bin/env bash

set -euo pipefail

targets=(
  /usr/sbin/PGeneratord.hdr
  /usr/sbin/PGeneratord.hdr.*
  /usr/sbin/PGeneratord.pl.*
  /usr/sbin/PGeneratord.agent*
  /usr/sbin/PGeneratord.backup*
  /usr/sbin/PGeneratord.bak*
  /usr/sbin/PGeneratord.lastnight*
  /usr/sbin/PGeneratord.oldhdr*
  /usr/sbin/PGeneratord.pre*
  /usr/sbin/PGeneratord.rebuilt_*
  /usr/sbin/PGeneratord.tmp-*
  /usr/sbin/PGeneratord.dv.agent*
  /usr/sbin/PGeneratord.dv.backup*
  /usr/sbin/PGeneratord.dv.bak*
  /usr/sbin/PGeneratord.dv.linkbackup_test
  /usr/sbin/PGeneratord.dv.pre*
  /usr/sbin/PGeneratord.dv.probe*
  /usr/sbin/PGeneratord.dv.restore_test
  /usr/sbin/PGeneratord.dv.tmp-*
)

removed=0

for pattern in "${targets[@]}"; do
 for path in $pattern; do
  [[ -e "$path" ]] || continue
  rm -f -- "$path"
  removed=$((removed + 1))
  printf 'Removed stale renderer artifact: %s\n' "$path"
 done
done

printf 'Renderer cleanup complete for %s -> %s; removed=%d\n' \
 "${PG_UPDATE_FROM:-unknown}" "${PG_UPDATE_TO:-unknown}" "$removed"
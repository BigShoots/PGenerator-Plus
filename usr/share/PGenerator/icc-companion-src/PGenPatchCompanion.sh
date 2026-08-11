#!/bin/sh

app_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
export LD_LIBRARY_PATH="$app_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$app_dir/PGenPatchCompanion.bin" "$@"

#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
pid_file="$app_dir/.server.pid"
python_bin="$app_dir/runtime/python/bin/python3"

if [ ! -x "$python_bin" ]; then
  echo "The bundled Python runtime is missing."
  echo "Extract the complete PGenerator GitHub Deployer ZIP and try again."
  read -r _
  exit 1
fi

if [ -f "$pid_file" ]; then
  old_pid=$(sed -n '1p' "$pid_file")
  case "$old_pid" in
    *[!0-9]*|"") ;;
    *)
      if kill -0 "$old_pid" 2>/dev/null; then
        echo "GitHub deployer is already running with PID $old_pid." >&2
        exit 1
      fi
      ;;
  esac
fi

cd "$app_dir"
printf '%s\n' "$$" > "$pid_file"

exec "$python_bin" server.py "$@"

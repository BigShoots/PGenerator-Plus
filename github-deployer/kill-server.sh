#!/bin/sh
set -eu

app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
pid_file="$app_dir/.server.pid"
pids=""

is_deployer_process() {
  candidate=$1
  [ -d "/proc/$candidate" ] || return 1
  process_dir=$(readlink "/proc/$candidate/cwd" 2>/dev/null || true)
  if [ "$process_dir" != "$app_dir" ]; then
    case "$process_dir" in
      */github-deployer) ;;
      *) return 1 ;;
    esac
  fi
  command_line=$(tr '\000' ' ' < "/proc/$candidate/cmdline" 2>/dev/null || true)
  case "$command_line" in
    *"server.py"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -f "$pid_file" ]; then
  recorded_pid=$(sed -n '1p' "$pid_file")
  case "$recorded_pid" in
    *[!0-9]*|"") ;;
    *)
      if is_deployer_process "$recorded_pid"; then
        pids="$recorded_pid"
      fi
      ;;
  esac
fi

if [ -z "$pids" ]; then
  for process in /proc/[0-9]*; do
    candidate=${process##*/}
    if is_deployer_process "$candidate"; then
      pids="$pids $candidate"
    fi
  done
fi

if [ -z "$pids" ]; then
  unlink "$pid_file" 2>/dev/null || true
  echo "GitHub deployer is not running."
  exit 0
fi

for pid in $pids; do
  kill "$pid" 2>/dev/null || true
done

attempt=0
while [ "$attempt" -lt 30 ]; do
  running=""
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      running="$running $pid"
    fi
  done
  [ -z "$running" ] && break
  attempt=$((attempt + 1))
  sleep 0.1
done

for pid in $pids; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done

unlink "$pid_file" 2>/dev/null || true
echo "GitHub deployer stopped."

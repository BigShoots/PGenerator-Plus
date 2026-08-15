#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
pid_file="$app_dir/.server.pid"

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

# Bash publishes exported shell functions as environment variables named
# BASH_FUNC_<name>%%, and environment-modules exports three of them (module,
# ml, _module_raw). systemd refuses a variable whose name contains '%', so
# every time this server opens a browser, KIO hands it the environment and
# KDE logs "Not passing environment variable ... illegal characters" once per
# function. Whether it shows up is purely a matter of what /bin/sh is: dash
# drops those names on entry, so Debian and Ubuntu never see it, while Arch
# and Fedora point /bin/sh at bash, which imports and re-exports them.
# Nothing launched from here needs an exported shell function. The names are
# not valid shell identifiers, so `unset` cannot remove them portably --
# `env -u` takes them literally.
strip_env=""
for stripped_name in $(env | sed -n 's/^\(BASH_FUNC_[^=]*\)=.*/\1/p'); do
  strip_env="$strip_env -u $stripped_name"
done

# Deliberate word splitting: $strip_env is a list of env arguments, and an
# exported function's name can never contain whitespace.
# shellcheck disable=SC2086
exec env $strip_env python3 server.py "$@"

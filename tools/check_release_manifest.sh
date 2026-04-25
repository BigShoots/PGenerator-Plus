#!/usr/bin/env bash

set -euo pipefail

MODE=""
ROOT_PATH=""
TARBALL_PATH=""
WORKDIR=""

REQUIRED_PATHS=(
  etc/default/rcPGenerator
  etc/init.d/PGenerator
  etc/init.d/rcPGenerator
  etc/PGenerator/PGenerator.conf
  etc/PGenerator/lut.txt
  usr/bin/PGenerator_cmd.pl
  usr/bin/meter_series.sh
  usr/bin/meter_session.sh
  usr/bin/spotread
  usr/bin/spotread_wrapper.sh
  usr/sbin/PGeneratord
  usr/sbin/PGeneratord.dv
  usr/sbin/PGeneratord.pl
  usr/sbin/pgenerator-update
  usr/share/PGenerator/command.pm
  usr/share/PGenerator/conf.pm
  usr/share/PGenerator/daemon.pm
  usr/share/PGenerator/update-migrations.d
  usr/share/PGenerator/variables.pm
  usr/share/PGenerator/version.pm
  usr/share/PGenerator/webui.pm
  var/lib/PGenerator/operations.txt
  var/lib/PGenerator/running/tmp
)

ALLOWED_RENDERER_FILES=(
  PGeneratord
  PGeneratord.dv
  PGeneratord.pl
)

usage() {
 cat <<'EOF'
Usage:
  ./tools/check_release_manifest.sh --root PATH
  ./tools/check_release_manifest.sh --tarball PATH

Validates that a staged release root or OTA tarball contains the expected
runtime files and only the supported canonical renderer filenames.
EOF
}

die() {
 echo "ERROR: $*" >&2
 exit 1
}

cleanup() {
 set +e
 if [[ -n "$WORKDIR" ]] && [[ -d "$WORKDIR" ]]; then
  rm -rf "$WORKDIR"
 fi
}

trap cleanup EXIT

require_commands() {
 local missing=()
 local cmd
 for cmd in find mktemp sha256sum sort tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
   missing+=("$cmd")
  fi
 done
 if [[ ${#missing[@]} -gt 0 ]]; then
  die "Missing required tools: ${missing[*]}"
 fi
}

parse_args() {
 while [[ $# -gt 0 ]]; do
  case "$1" in
   --root)
    [[ $# -ge 2 ]] || die "Missing value for --root"
    MODE="root"
    ROOT_PATH="$2"
    shift 2
    ;;
   --tarball)
    [[ $# -ge 2 ]] || die "Missing value for --tarball"
    MODE="tarball"
    TARBALL_PATH="$2"
    shift 2
    ;;
   -h|--help)
    usage
    exit 0
    ;;
   *)
    die "Unknown argument: $1"
    ;;
  esac
 done

 [[ -n "$MODE" ]] || die "Specify exactly one of --root or --tarball"
}

contains_allowed_renderer() {
 local candidate="$1"
 local allowed
 for allowed in "${ALLOWED_RENDERER_FILES[@]}"; do
  if [[ "$candidate" == "$allowed" ]]; then
   return 0
  fi
 done
 return 1
}

validate_root() {
 local root="$1"
 local missing=()
 local extras=()
 local rel path file base_hash dv_hash

 [[ -d "$root" ]] || die "Root path does not exist: $root"

 for rel in "${REQUIRED_PATHS[@]}"; do
  if [[ ! -e "$root/$rel" ]]; then
   missing+=("$rel")
  fi
 done

 if [[ -d "$root/usr/sbin" ]]; then
  while IFS= read -r path; do
   [[ -n "$path" ]] || continue
   file="${path##*/}"
   if ! contains_allowed_renderer "$file"; then
    extras+=("usr/sbin/$file")
   fi
  done < <(find "$root/usr/sbin" -maxdepth 1 -type f -name 'PGeneratord*' | sort)
 fi

 if [[ -f "$root/usr/sbin/PGeneratord" ]] && [[ -f "$root/usr/sbin/PGeneratord.dv" ]]; then
  base_hash="$(sha256sum "$root/usr/sbin/PGeneratord" | awk '{print $1}')"
  dv_hash="$(sha256sum "$root/usr/sbin/PGeneratord.dv" | awk '{print $1}')"
  if [[ "$base_hash" != "$dv_hash" ]]; then
   extras+=("renderer-hash-mismatch:PGeneratord!=PGeneratord.dv")
  fi
 fi

 if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'Missing required release paths:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  return 1
 fi

 if [[ ${#extras[@]} -gt 0 ]]; then
  printf 'Unexpected renderer artifacts in release payload:\n' >&2
  printf '  %s\n' "${extras[@]}" >&2
  return 1
 fi

 echo "Release manifest OK: $root"
}

extract_tarball() {
 WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-manifest.XXXXXX")"
 tar xzf "$TARBALL_PATH" -C "$WORKDIR"
 ROOT_PATH="$WORKDIR"
}

validate_tarball_metadata() {
 local bad_entries=()
 local line owner path

 while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  owner="$(awk '{print $2}' <<<"$line")"
  path="$(awk '{print $6}' <<<"$line")"
  [[ -n "$path" ]] || continue
  case "$path" in
   etc/*|usr/*|var/*|lib/*|etc/|usr/|var/|lib/)
    if [[ "$owner" != "0/0" ]]; then
     bad_entries+=("$owner $path")
    fi
    ;;
  esac
 done < <(tar --numeric-owner -tvzf "$TARBALL_PATH")

 if [[ ${#bad_entries[@]} -gt 0 ]]; then
  printf 'Tarball contains non-root ownership metadata:\n' >&2
  printf '  %s\n' "${bad_entries[@]:0:20}" >&2
  if [[ ${#bad_entries[@]} -gt 20 ]]; then
   printf '  ... and %d more\n' "$(( ${#bad_entries[@]} - 20 ))" >&2
  fi
  return 1
 fi
}

main() {
 parse_args "$@"
 require_commands

 if [[ "$MODE" == "tarball" ]]; then
  [[ -f "$TARBALL_PATH" ]] || die "Tarball does not exist: $TARBALL_PATH"
  validate_tarball_metadata
  extract_tarball
 fi

 validate_root "$ROOT_PATH"
}

main "$@"
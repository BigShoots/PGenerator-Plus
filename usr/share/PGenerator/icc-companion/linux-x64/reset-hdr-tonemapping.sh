#!/usr/bin/env bash

set -euo pipefail

program_name=${0##*/}
dry_run=false
assume_yes=false
keep_sdr=false
selected_output=""

usage() {
    cat <<EOF
Usage: $program_name [OPTIONS]

Reset KDE/KWin HDR tone-mapping values to display-advertised defaults while
leaving the selected ICC profile and HDR profile source unchanged.

Options:
  --output NAME  Reset only this connector name or numeric KScreen output ID
  --keep-sdr     Preserve the current SDR reference brightness
  --dry-run      Show the operations without changing the display
  --yes          Do not ask for confirmation
  -h, --help     Show this help

With no --output option, all connected, enabled HDR outputs are reset.
EOF
}

while (($#)); do
    case $1 in
    --output)
        (($# >= 2)) || { echo "$program_name: --output needs a value" >&2; exit 2; }
        selected_output=$2
        shift 2
        ;;
    --keep-sdr)
        keep_sdr=true
        shift
        ;;
    --dry-run)
        dry_run=true
        shift
        ;;
    --yes)
        assume_yes=true
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "$program_name: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

for command in kscreen-doctor jq awk sed; do
    command -v "$command" >/dev/null || {
        echo "$program_name: required command not found: $command" >&2
        exit 1
    }
done

# This makes the script usable from an SSH shell connected to the logged-in
# Plasma user as well as from a terminal inside the desktop session.
user_id=$(id -u)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$user_id}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-wayland}

config_json=$(kscreen-doctor -j)
doctor_text=$(LC_ALL=C kscreen-doctor -o | sed $'s/\033\\[[0-9;]*[mK]//g')

output_filter='select(.connected and .enabled and .hdr)'
if [[ -n $selected_output ]]; then
    output_filter+=" | select(.name == \$selected or (.id | tostring) == \$selected)"
fi

mapfile -t outputs < <(
    jq -r --arg selected "$selected_output" ".outputs[] | $output_filter | [.id, .name, .wcg, .[\"sdr-brightness\"]] | @tsv" <<<"$config_json"
)

if ((${#outputs[@]} == 0)); then
    if [[ -n $selected_output ]]; then
        echo "$program_name: no connected, enabled HDR output matched '$selected_output'" >&2
    else
        echo "$program_name: no connected, enabled HDR outputs were found" >&2
    fi
    exit 1
fi

advertised_max_average() {
    local output_id=$1
    awk -v wanted="$output_id" '
        $1 == "Output:" { in_output = ($2 == wanted) }
        in_output && /Max average brightness:/ {
            for (i = 1; i <= NF; ++i) {
                if ($i == "brightness:") {
                    value = $(i + 1)
                    gsub(/[^0-9.]/, "", value)
                    if (value != "") {
                        printf "%.0f\n", value
                        exit
                    }
                }
            }
        }
    ' <<<"$doctor_text"
}

default_sdr_brightness() {
    local max_average=$1
    if [[ ! $max_average =~ ^[0-9]+$ ]] || ((max_average == 0)); then
        max_average=200
    fi
    if ((max_average < 200)); then
        echo 200
    elif ((max_average > 500)); then
        echo 500
    else
        echo "$max_average"
    fi
}

declare -a ids names wcg_values old_sdr_values new_sdr_values

echo "HDR tone-mapping reset plan:"
for record in "${outputs[@]}"; do
    IFS=$'\t' read -r output_id output_name output_wcg output_sdr <<<"$record"
    max_average=$(advertised_max_average "$output_id")
    new_sdr=$(default_sdr_brightness "$max_average")

    ids+=("$output_id")
    names+=("$output_name")
    wcg_values+=("$output_wcg")
    old_sdr_values+=("$output_sdr")
    new_sdr_values+=("$new_sdr")

    printf '  %s (output %s): clear peak/average/minimum overrides' "$output_name" "$output_id"
    if $keep_sdr; then
        printf ', keep SDR reference at %s cd/m2\n' "$output_sdr"
    else
        printf ', SDR reference %s -> %s cd/m2\n' "$output_sdr" "$new_sdr"
    fi
done

echo "  Selected ICC paths and HDR profile sources will not be changed."
echo "  Each selected output will briefly leave and re-enter HDR mode."

if ! $dry_run && ! $assume_yes; then
    read -r -p "Continue? [y/N] " answer
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || exit 0
fi

run_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
    if ! $dry_run; then
        "$@"
    fi
}

echo "Clearing overrides and disabling HDR:"
for index in "${!ids[@]}"; do
    id=${ids[$index]}
    run_command kscreen-doctor \
        "output.$id.maxBrightnessOverride.disable" \
        "output.$id.maxAverageBrightnessOverride.disable" \
        "output.$id.minBrightnessOverride.disable" \
        "output.$id.hdr.disable"
done

if ! $dry_run; then
    sleep 2
fi

echo "Re-enabling HDR with display defaults:"
for index in "${!ids[@]}"; do
    id=${ids[$index]}
    declare -a settings=("output.$id.hdr.enable")
    if [[ ${wcg_values[$index]} == true ]]; then
        settings+=("output.$id.wcg.enable")
    else
        settings+=("output.$id.wcg.disable")
    fi
    if ! $keep_sdr; then
        settings+=("output.$id.sdr-brightness.${new_sdr_values[$index]}")
    fi
    run_command kscreen-doctor "${settings[@]}"
done

if ! $dry_run; then
    sleep 2
    echo "Result:"
    LC_ALL=C kscreen-doctor -o
fi

echo "Done. ICC selections were left untouched."

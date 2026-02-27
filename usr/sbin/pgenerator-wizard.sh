#!/bin/bash
###############################################################################
# pgenerator-wizard.sh -- Step-by-Step Setup Wizard for PGenerator
#
# A dialog-based guided wizard that walks the user through PGenerator
# configuration in the correct order, following the AVS Forum PGenerator
# guide.
#
# Flow:
#   1. WiFi connection (so the user knows their IP)
#   2. Signal Mode: SDR or HDR
#   3. Output Format: Color Format, Colorimetry (-> Set AVI InfoFrame)
#   4. If HDR: DRM InfoFrame metadata (EOTF, Primaries, Luminance)
#   5. Optional advanced settings (Resolution, GPU Memory, etc.)
#   6. Summary -> Continue to PGenerator
#
# The IP address is shown continuously in the title bar after connecting.
#
# Copyright 2026 -- Released under GPLv3 to match PGenerator licensing
###############################################################################

set -o pipefail

export TERM=linux
export HOME="${HOME:-/root}"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

# Debug log
WIZARD_LOG="/tmp/wizard-trace.log"
exec 3>>"$WIZARD_LOG"
echo "$(date) Wizard PID=$$ started, TERM=$TERM, TTY=$(tty 2>&1)" >&3
trap 'echo "$(date) EXIT status=$?" >&3' EXIT
trap 'echo "$(date) ERR at line $LINENO: $BASH_COMMAND" >&3' ERR

###############################################################################
# Configuration paths
###############################################################################
PGENERATOR_CONF="/etc/PGenerator/PGenerator.conf"
BOOTLOADER_FILE="/boot/loader/boot_dir/config.txt"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
WPA_SUPPLICANT_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
RC_DEFAULT="/etc/default/rcPGenerator"
HOSTNAME_FILE="/etc/hostname"
DISCOVERABLE_FILE="/etc/PGenerator/DISCOVERABLE.disabled"

WPA_CLI="/usr/bin/wpa_cli"
WPA_PASSPHRASE="/usr/bin/wpa_passphrase"
TVSERVICE="/opt/vc/bin/tvservice"
MODETEST="/usr/bin/modetest"

DIALOG_HEIGHT=20
DIALOG_WIDTH=70
DIALOG_TIMEOUT=15

# Persistent title bar -- updated after WiFi connects
BACKTITLE="PGenerator Setup"
NEEDS_REBOOT=0

###############################################################################
# Utility functions
###############################################################################

is_pi4_kms() {
 local model
 model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
 [[ "$model" =~ "Pi 4" ]] && [ -e "/dev/dri/card0" ]
}

read_pg_conf() {
 grep "^${1}=" "$PGENERATOR_CONF" 2>/dev/null | cut -d'=' -f2
}

write_pg_conf() {
 if grep -q "^${1}=" "$PGENERATOR_CONF" 2>/dev/null; then
  sed -i "s/^${1}=.*/${1}=${2}/" "$PGENERATOR_CONF"
 else
  echo "${1}=${2}" >> "$PGENERATOR_CONF"
 fi
 sync
}

read_boot_conf() {
 grep "^${1}=" "$BOOTLOADER_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2
}

write_boot_conf() {
 if grep -q "^${1}=" "$BOOTLOADER_FILE" 2>/dev/null; then
  sed -i "s/^${1}=.*/${1}=${2}/" "$BOOTLOADER_FILE"
 else
  echo "${1}=${2}" >> "$BOOTLOADER_FILE"
 fi
 sync
}

apply_bootloader() {
 if [ -x "/usr/bin/bootloader" ]; then
  COPY_ONLY_FILES="config.txt" /usr/bin/bootloader
 elif [ -d "/boot" ]; then
  cp "$BOOTLOADER_FILE" /boot/config.txt 2>/dev/null || true
 fi
}

# Get all IPs as a compact string for the title bar
get_ip_string() {
 local ips=""
 local iface addr
 for iface in eth0 wlan0 usb0 bt-pan; do
  addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
  [ -n "$addr" ] && ips="${ips}${iface}:${addr}  "
 done
 echo "$ips"
}

# Get IPs formatted for display in dialog body
get_all_ips() {
 local ips=""
 local iface addr
 for iface in eth0 wlan0 usb0 bt-pan; do
  addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
  [ -n "$addr" ] && ips="${ips}  ${iface}: ${addr}\n"
 done
 [ -z "$ips" ] && ips="  (no network addresses yet)\n"
 echo -e "$ips"
}

# Update the backtitle with current IPs
update_backtitle() {
 local ips
 ips=$(get_ip_string)
 if [ -n "$ips" ]; then
  BACKTITLE="PGenerator | ${ips}| Port: $(read_pg_conf port_pattern)"
 fi
}

###############################################################################
# Dialog wrappers (all include --backtitle for persistent IP display)
###############################################################################

show_info() {
 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "$1" --ok-label "Next" \
  --msgbox "$2" $DIALOG_HEIGHT $DIALOG_WIDTH || true
}

ask_yesno() {
 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "$1" --yes-label "Yes" \
  --no-label "No" --yesno "$2" $DIALOG_HEIGHT $DIALOG_WIDTH
}

get_input() {
 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "$1" --ok-label "Next" \
  --cancel-label "Back" --inputbox "$2" \
  $DIALOG_HEIGHT $DIALOG_WIDTH "$3" 2>&1 >/dev/tty
}

get_password() {
 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "$1" --ok-label "Next" \
  --cancel-label "Back" --insecure --passwordbox "$2" \
  $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty
}

show_menu() {
 local title="$1" prompt="$2"
 shift 2
 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "$title" --ok-label "Next" \
  --cancel-label "Back" --menu "$prompt" \
  $DIALOG_HEIGHT $DIALOG_WIDTH 10 "$@" 2>&1 >/dev/tty
}

###############################################################################
# Step 1: WiFi Connection
###############################################################################

step_wifi() {
 local interface="wlan0"

 # Check if WiFi hardware is available
 if grep -q "^dtoverlay=disable-wifi" "$BOOTLOADER_FILE" 2>/dev/null; then
  return
 fi

 if ! ask_yesno "Network Setup" \
  "Do you want to connect to a WiFi network?\n\n\
Current network addresses:\n$(get_all_ips)\n\
If you are using a wired connection, you can skip this.\n\
WiFi is needed for wireless calibration sessions."; then
  return
 fi

 # Set regulatory domain for 5GHz support
 local current_country
 current_country=$(wpa_cli -i "$interface" get country 2>/dev/null)
 if [ -z "$current_country" ] || [ "$current_country" = "FAIL" ] || [ "$current_country" = "00" ]; then
  local country
  country=$(get_input "WiFi Region" \
   "Enter your 2-letter country code for WiFi.\n\nThis enables 5GHz networks and sets the correct\nregulatory domain (e.g., US, GB, CA, AU, DE, FR)." \
   "US")
  if [ -n "$country" ]; then
   country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
   wpa_cli -i "$interface" set country "$country" &>/dev/null
   wpa_cli -i "$interface" save_config &>/dev/null
   iw reg set "$country" 2>/dev/null || true
   if ! grep -q "^country=" "$WPA_SUPPLICANT_CONF" 2>/dev/null; then
    sed -i "2i country=$country" "$WPA_SUPPLICANT_CONF" 2>/dev/null || true
   else
    sed -i "s/^country=.*/country=$country/" "$WPA_SUPPLICANT_CONF" 2>/dev/null || true
   fi
   wpa_cli -i "$interface" disconnect &>/dev/null
   sleep 1
   wpa_cli -i "$interface" reconnect &>/dev/null
   sleep 2
  fi
 fi

 # Scan for networks
 dialog --backtitle "$BACKTITLE" --title "WiFi Setup" --infobox \
  "Scanning for available WiFi networks...\n\nThis may take a few seconds." 6 $DIALOG_WIDTH
 $WPA_CLI -i "$interface" scan &>/dev/null 2>&1 || true
 sleep 4

 local scan_results
 scan_results=$($WPA_CLI -i "$interface" scan_results 2>/dev/null | tail -n +2 | grep -v '\\x00' | sed 's/[^[:print:]\t]//g')

 local ssid=""
 if [ -z "$scan_results" ]; then
  ssid=$(get_input "WiFi SSID" "No networks found.\nEnter the WiFi network name (SSID) manually:" "")
 else
  local menu_args=()
  local i=1
  while IFS=$'\t' read -r bssid freq signal flags ssid_col; do
   [ -z "$ssid_col" ] && continue
   local signal_pct=$(( (signal + 100) * 2 ))
   [ $signal_pct -gt 100 ] && signal_pct=100
   [ $signal_pct -lt 0 ] && signal_pct=0
   menu_args+=("$ssid_col" "Signal: ${signal_pct}% ${flags}")
   i=$((i + 1))
   [ $i -gt 15 ] && break
  done <<< "$scan_results"

  if [ ${#menu_args[@]} -eq 0 ]; then
   ssid=$(get_input "WiFi SSID" "No networks found. Enter SSID manually:" "")
  else
   ssid=$(show_menu "Select WiFi Network" "Choose your WiFi network:" \
    "${menu_args[@]}")
  fi
 fi
 [ -z "$ssid" ] && return

 local password
 password=$(get_password "WiFi Password" "Enter password for '$ssid':")
 [ -z "$password" ] && return

 # Connect
 local psk
 psk=$($WPA_PASSPHRASE "$ssid" <<< "$password" 2>/dev/null | grep -v '#' | grep 'psk=' | cut -d'=' -f2)

 if [ -n "$psk" ]; then
  $WPA_CLI -i "$interface" remove_network 0 &>/dev/null
  $WPA_CLI -i "$interface" flush &>/dev/null
  $WPA_CLI -i "$interface" add_network 0 &>/dev/null
  $WPA_CLI -i "$interface" set_network 0 ssid "\"$ssid\"" &>/dev/null
  $WPA_CLI -i "$interface" set_network 0 psk "$psk" &>/dev/null
  $WPA_CLI -i "$interface" enable_network 0 &>/dev/null
  $WPA_CLI -i "$interface" save_config &>/dev/null
  $WPA_CLI -i "$interface" reassociate &>/dev/null
  $WPA_CLI -i "$interface" reconnect &>/dev/null

  local ip_addr="" wait_secs=15
  for t in $(seq 1 $wait_secs); do
   echo $(( t * 100 / wait_secs )) | dialog --backtitle "$BACKTITLE" \
    --title "Connecting" --gauge \
    "Connecting to $ssid...\n($t/$wait_secs seconds)" 8 $DIALOG_WIDTH 0
   ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
   [ -n "$ip_addr" ] && break
   sleep 1
  done

  # Update backtitle with new IP
  update_backtitle

  if [ -n "$ip_addr" ]; then
   show_info "WiFi Connected" \
    "Connected to: $ssid\n\nIP Address: $ip_addr\nPort: $(read_pg_conf port_pattern)\n\nThis IP will be shown at the top of each screen."
  else
   show_info "WiFi Configured" \
    "WiFi configured for: $ssid\n\nThe connection may still be establishing.\nCheck the title bar for your IP address."
  fi
 else
  show_info "Error" "Failed to generate WiFi credentials.\nCheck the SSID and password."
 fi
}

###############################################################################
# Step 2: Signal Mode (SDR / HDR)
###############################################################################

step_signal_mode() {
 echo "$(date) step_signal_mode()" >&3

 if ! is_pi4_kms; then
  show_info "Signal Mode" \
   "On Pi models before Pi 4, the output is SDR.\n\nHDR requires a Pi 4 with KMS driver, or an\nexternal HD Fury device for metadata injection.\n\nContinuing with SDR settings."
  write_pg_conf "is_sdr" "1"
  write_pg_conf "is_hdr" "0"
  return 1  # SDR
 fi

 local choice
 choice=$(show_menu "Step 1: Output Mode" \
  "Select the output signal mode.\n\nThis is the first setting to configure.\nAll subsequent options depend on this choice." \
  "sdr"    "SDR -- Standard Dynamic Range (Rec.709)" \
  "hdr"    "HDR10 -- Static HDR (PQ / ST.2084)" \
  "hlg"    "HLG -- Hybrid Log-Gamma (broadcast HDR)" \
  "dv_ll"  "Dolby Vision -- Low Latency (LLDV)" \
  "dv_std" "Dolby Vision -- Standard (TV-led)")

 # Show explanation if user picked a DV option
 case "$choice" in
  dv_ll)
   show_info "Dolby Vision -- Low Latency" \
    "LLDV is the recommended mode for DV calibration.\n\n\
The PGenerator sends RPU metadata and the TV applies\n\
its Dolby Vision processing in real time. The source\n\
controls tone mapping parameters (minPQ, maxPQ, etc).\n\n\
Use this when:\n\
  - Your TV supports DV (most 2018+ LG, Sony, etc.)\n\
  - You want to calibrate the TV's DV picture mode\n\
  - You are using CalMAN or LightSpace for DV cal"
   ;;
  dv_std)
   show_info "Dolby Vision -- Standard" \
    "Standard DV is the TV-led (display-managed) mode.\n\n\
The TV receives DV metadata and performs its own tone\n\
mapping based on its internal Dolby Vision profile.\n\
The source has less control over the final image.\n\n\
Use this when:\n\
  - Your workflow requires TV-led DV processing\n\
  - Testing how content looks with the TV's built-in\n\
    Dolby Vision tone mapping\n\n\
For most calibration, Low Latency (LLDV) is preferred."
   ;;
 esac

 case "$choice" in
  hdr)
   write_pg_conf "is_sdr" "0"
   write_pg_conf "is_hdr" "1"
   write_pg_conf "is_ll_dovi" "0"
   write_pg_conf "is_std_dovi" "0"
   write_pg_conf "dv_status" "0"
   return 0  # HDR
   ;;
  hlg)
   write_pg_conf "is_sdr" "0"
   write_pg_conf "is_hdr" "1"
   write_pg_conf "is_ll_dovi" "0"
   write_pg_conf "is_std_dovi" "0"
   write_pg_conf "eotf" "3"
   return 2  # HLG
   ;;
  dv_ll)
   write_pg_conf "is_sdr" "0"
   write_pg_conf "is_hdr" "0"
   write_pg_conf "is_ll_dovi" "1"
   write_pg_conf "is_std_dovi" "0"
   write_pg_conf "dv_status" "1"
   return 3  # DV Low Latency
   ;;
  dv_std)
   write_pg_conf "is_sdr" "0"
   write_pg_conf "is_hdr" "0"
   write_pg_conf "is_ll_dovi" "0"
   write_pg_conf "is_std_dovi" "1"
   write_pg_conf "dv_status" "1"
   return 4  # DV Standard
   ;;
  *)
   write_pg_conf "is_sdr" "1"
   write_pg_conf "is_hdr" "0"
   write_pg_conf "is_ll_dovi" "0"
   write_pg_conf "is_std_dovi" "0"
   write_pg_conf "dv_status" "0"
   return 1  # SDR
   ;;
 esac
}

###############################################################################
# Step 3: Color Format (AVI InfoFrame - Output Format)
###############################################################################

step_color_format() {
 local mode_label="$1"  # "SDR" or "HDR"

 if ! is_pi4_kms; then
  return
 fi

 local recommended="RGB Full (0-255) is recommended for calibration."
 if [ "$mode_label" = "HDR" ]; then
  recommended="RGB Full (0-255) is recommended.\nYCbCr may be needed for some displays in HDR."
 fi

 local choice
 choice=$(show_menu "Step 2: Color Format" \
  "Select the output color format.\n\n${recommended}\n\nThis sets the COLOR FORMAT field in the AVI InfoFrame." \
  "0" "RGB Full (0-255) -- recommended" \
  "1" "YCbCr 444 (Limited 16-235)" \
  "2" "YCbCr 422 (Limited) -- 10/12-bit only")

 if [ -n "$choice" ]; then
  write_pg_conf "color_format" "$choice"
 fi
}

###############################################################################
# Step 4: Colorimetry (AVI InfoFrame)
###############################################################################

step_colorimetry() {
 local mode_label="$1"  # "SDR" or "HDR"

 if ! is_pi4_kms; then
  return
 fi

 if [ "$mode_label" = "HDR" ]; then
  # For HDR, BT2020 is auto-set. Give user option to change.
  write_pg_conf "colorimetry" "1"
  if ! ask_yesno "Step 3: Colorimetry" \
   "Colorimetry set to BT2020 for HDR.\n\nBT2020 is the standard colorimetry for HDR10 content.\nIt sets the COLORIMETRY field in the AVI InfoFrame.\n\nAccept BT2020? Select No to change."; then
   local choice
   choice=$(show_menu "Step 3: Colorimetry" \
    "Select the output colorimetry." \
    "1" "BT2020 (HDR standard) -- recommended" \
    "0" "BT709 (SDR standard)")
   if [ -n "$choice" ]; then
    write_pg_conf "colorimetry" "$choice"
   fi
  fi
 else
  local choice
  choice=$(show_menu "Step 3: Colorimetry" \
   "Select the output colorimetry.\n\nBT709 is the standard for SDR calibration.\nBT2020 is used for HDR or wide color gamut.\n\nThis sets the COLORIMETRY field in the AVI InfoFrame." \
   "0" "BT709 (SDR standard) -- recommended" \
   "1" "BT2020 (wide color gamut)")

  if [ -n "$choice" ]; then
   write_pg_conf "colorimetry" "$choice"
  fi
 fi
}

###############################################################################
# Step 5: Bit Depth
###############################################################################

step_bit_depth() {
 local mode_label="$1"

 if ! is_pi4_kms; then
  return
 fi

 if [ "$mode_label" = "DV" ]; then
  # Dolby Vision requires 12-bit
  write_pg_conf "max_bpc" "12"
  if ! ask_yesno "Step 4: Bit Depth" \
   "Bit depth set to 12-bit for Dolby Vision.\n\nDolby Vision requires 12 bits per channel.\n\nAccept 12-bit? Select No to change."; then
   local choice
   choice=$(show_menu "Step 4: Bit Depth" \
    "Select the output bit depth per channel." \
    "12" "12-bit -- Dolby Vision standard" \
    "10" "10-bit")
   if [ -n "$choice" ]; then
    write_pg_conf "max_bpc" "$choice"
   fi
  fi
 elif [ "$mode_label" = "HDR" ]; then
  # HDR uses 10-bit. Always set to 10 (fix leftover 12-bit from DV).
  write_pg_conf "max_bpc" "10"
  if ! ask_yesno "Step 4: Bit Depth" \
   "Bit depth set to 10-bit for HDR.\n\nHDR10 uses 10 bits per channel.\n\nAccept 10-bit? Select No to change."; then
   local choice
   choice=$(show_menu "Step 4: Bit Depth" \
    "Select the output bit depth per channel." \
    "10" "10-bit -- HDR10 standard" \
    "8"  "8-bit  -- SDR")
   if [ -n "$choice" ]; then
    write_pg_conf "max_bpc" "$choice"
   fi
  fi
 else
  local choice
  choice=$(show_menu "Step 4: Bit Depth" \
   "Select the output bit depth per channel.\n\n8-bit is standard for SDR.\n10-bit for HDR10, 12-bit for Dolby Vision." \
   "8"  "8-bit  (SDR standard) -- recommended" \
   "10" "10-bit (HDR10)" \
   "12" "12-bit (Dolby Vision)")

  if [ -n "$choice" ]; then
   write_pg_conf "max_bpc" "$choice"
  fi
 fi
}

###############################################################################
# Step 5b: Quantization Range
###############################################################################

step_quant_range() {
 local mode_label="$1"

 if ! is_pi4_kms; then
  return
 fi

 # Auto-set quantization range based on signal mode
 if [ "$mode_label" = "DV" ]; then
  # DV handles quantization internally
  write_pg_conf "rgb_quant_range" "0"
  show_info "Step 5: Quantization Range" \
   "Quantization range set to Default (auto) for Dolby Vision.\n\nDolby Vision handles quantization internally\nthrough its own metadata and processing pipeline."
  return
 fi

 if [ "$mode_label" = "HDR" ]; then
  # HDR: auto-set Full for calibration, explain
  write_pg_conf "rgb_quant_range" "2"
  if ask_yesno "Step 5: Quantization Range" \
   "Quantization range auto-set to Full (0-255).\n\nFor HDR calibration with RGB output, Full range is\nrecommended. Make sure your calibration software's\npatch scale also uses 0-255 (Full).\n\nIf your display requires Limited range for HDR,\nselect No to change it."; then
   return
  fi
 else
  # SDR: auto-set Full for calibration, explain
  write_pg_conf "rgb_quant_range" "2"
  if ask_yesno "Step 5: Quantization Range" \
   "Quantization range auto-set to Full (0-255).\n\nFull range is standard for SDR calibration.\nYour calibration software patch scale should\nalso be set to 0-255.\n\nIf your display requires Limited (16-235),\nselect No to change it."; then
   return
  fi
 fi

 # User chose to change it
 local choice
 choice=$(show_menu "Step 5: Quantization Range" \
  "Select the RGB quantization range.\n\nFull (0-255) is recommended for calibration.\nLimited (16-235) if your display requires it.\nMake sure your software patch scale matches." \
  "2" "Full (0-255) -- recommended" \
  "1" "Limited (16-235)" \
  "0" "Default (auto-detect)")

 if [ -n "$choice" ]; then
  write_pg_conf "rgb_quant_range" "$choice"
 fi
}

###############################################################################
# HDR Steps: DRM InfoFrame (Mastering Display Color Volume Metadata)
###############################################################################

###############################################################################
# Dolby Vision Steps
###############################################################################

step_dv_settings() {
 local dv_type="$1"  # "ll" or "std"

 local type_name="Low Latency"
 [ "$dv_type" = "std" ] && type_name="Standard"

 # Auto-set DV Interface to match the mode already selected
 if [ "$dv_type" = "ll" ]; then
  write_pg_conf "dv_interface" "1"
 else
  write_pg_conf "dv_interface" "0"
 fi

 # DV Color Space
 local choice
 choice=$(show_menu "DV: Color Space" \
  "Select the Dolby Vision output color space." \
  "0" "YCbCr 422 (12-bit) -- standard" \
  "1" "RGB 444 (8-bit tunnel)" \
  "2" "YCbCr 444 (10-bit)")
 if [ -n "$choice" ]; then
  write_pg_conf "dv_color_space" "$choice"
 fi

 # DV Metadata
 choice=$(show_menu "DV: Metadata" \
  "Select the Dolby Vision metadata type." \
  "0" "Type 1 -- static metadata" \
  "1" "Type 4 -- dynamic metadata")
 if [ -n "$choice" ]; then
  write_pg_conf "dv_metadata" "$choice"
 fi

 # DV Target display diagonal
 local current
 current=$(read_pg_conf "dv_diagonal")
 [ -z "$current" ] && current="65"
 local value
 value=$(get_input "DV: Display Diagonal" \
  "Enter the target display diagonal (inches).\n\nUsed by Dolby Vision tone mapping.\n\nDefault: 65" \
  "$current")
 if [ -n "$value" ]; then
  write_pg_conf "dv_diagonal" "$value"
 fi

 local dv_cs_name="YCbCr 422 (12-bit)"
 case "$(read_pg_conf dv_color_space)" in
  1) dv_cs_name="RGB 444 (8-bit tunnel)" ;;
  2) dv_cs_name="YCbCr 444 (10-bit)" ;;
 esac
 local dv_md_name="Type 1 (static)"
 [ "$(read_pg_conf dv_metadata)" = "1" ] && dv_md_name="Type 4 (dynamic)"
 local dv_diag
 dv_diag=$(read_pg_conf "dv_diagonal")
 [ -z "$dv_diag" ] && dv_diag="65"

 if ! ask_yesno "Dolby Vision Summary" \
  "Dolby Vision ($type_name) configured:\n\n\
  Bit Depth:    12-bit\n\
  Colorimetry:  BT2020\n\
  Color Space:  $dv_cs_name\n\
  Metadata:     $dv_md_name\n\
  Diagonal:     ${dv_diag} inches\n\n\
Accept these settings? Select No to reconfigure."; then
  step_dv_settings "$dv_type"
 fi
}

###############################################################################
# HDR Steps: DRM InfoFrame (Mastering Display Color Volume Metadata)
###############################################################################

step_hdr_eotf() {
 local choice
 choice=$(show_menu "Step 6: EOTF" \
  "Select the Electro-Optical Transfer Function.\n\nSMPTE ST.2084 (PQ) is the standard for HDR10.\nHLG is used for broadcast HDR.\n\nThis is the first field in the DRM InfoFrame." \
  "2" "SMPTE ST.2084 (PQ) -- HDR10 standard" \
  "3" "HLG (Hybrid Log-Gamma)")

 if [ -n "$choice" ]; then
  write_pg_conf "eotf" "$choice"
  if [ "$choice" = "3" ]; then
   show_info "HLG Note" \
    "HLG selected.\n\nWhen using HLG as the EOTF, all subsequent DRM\nInfoFrame settings (Primaries, Luminance, MaxCLL,\nMaxFALL) will be ignored/zeroed by the standard.\n\nHLG should not contain this information."
   return 1  # Signal HLG mode
  fi
 fi
 return 0
}

step_hdr_primaries() {
 local choice
 choice=$(show_menu "Step 7: Primaries / White Point" \
  "Select the mastering display primaries and white point.\n\nREC.2020/D65 is the standard for HDR10.\nP3/D65 is common for HDR mastering monitors.\n\nThese define the color volume in the DRM InfoFrame." \
  "1" "REC.2020 / D65 -- recommended (BT.2020 primaries, D65 white)" \
  "2" "P3 / D65 (DCI-P3 primaries, D65 white)" \
  "3" "P3 / DCI Theater (DCI-P3 primaries, DCI white)")

 if [ -n "$choice" ]; then
  write_pg_conf "primaries" "$choice"
 fi
}

step_hdr_max_luma() {
 local current
 current=$(read_pg_conf "max_luma")
 [ -z "$current" ] && current="1000"

 local value
 value=$(get_input "Step 8: Maximum Luminance" \
  "Enter maximum mastering display luminance (nits).\n\nCommon values:\n  1000 nits -- most HDR content\n  4000 nits -- high-end mastering\n  10000 nits -- full PQ range\n\nDefault: 1000" \
  "$current")

 if [ -n "$value" ]; then
  write_pg_conf "max_luma" "$value"
 fi
}

step_hdr_min_luma() {
 local current
 current=$(read_pg_conf "min_luma")
 [ -z "$current" ] && current="1"

 local value
 value=$(get_input "Step 9: Minimum Luminance" \
  "Enter minimum mastering display luminance.\n\nThis value is divided by 10000 to get nits.\nExamples:\n  1   = 0.0001 nits\n  5   = 0.0005 nits\n  50  = 0.005 nits\n  100 = 0.01 nits\n\nDefault: 1 (= 0.0001 nits)" \
  "$current")

 if [ -n "$value" ]; then
  write_pg_conf "min_luma" "$value"
 fi
}

step_hdr_maxcll() {
 local current
 current=$(read_pg_conf "max_cll")
 [ -z "$current" ] && current="1000"

 local value
 value=$(get_input "Step 10: MaxCLL" \
  "Enter Maximum Content Light Level (nits).\n\nThis is the brightest pixel in the content.\nTypically matches the maximum luminance.\n\nDefault: 1000" \
  "$current")

 if [ -n "$value" ]; then
  write_pg_conf "max_cll" "$value"
 fi
}

step_hdr_maxfall() {
 local current
 current=$(read_pg_conf "max_fall")
 [ -z "$current" ] && current="250"

 local value
 value=$(get_input "Step 11: MaxFALL" \
  "Enter Maximum Frame-Average Light Level (nits).\n\nThis is the brightest average frame in the content.\n\nDefault: 250" \
  "$current")

 if [ -n "$value" ]; then
  write_pg_conf "max_fall" "$value"
 fi
}

###############################################################################
# Advanced Settings (optional, accessible from end of wizard)
###############################################################################

step_advanced() {
 if ! ask_yesno "Advanced Settings" \
  "Do you want to configure advanced settings?\n\n\
  - Display Resolution\n\
  - GPU Memory Allocation\n\
  - Device Hostname\n\
  - Network Discovery\n\
  - WiFi & Bluetooth Modules\n\n\
These are optional. Default values work for most setups."; then
  return
 fi

 local done=0
 while [ $done -eq 0 ]; do
  local choice
  choice=$(show_menu "Advanced Settings" \
   "Select a setting to configure:" \
   "resolution" "Display Resolution" \
   "gpu"        "GPU Memory Allocation" \
   "hostname"   "Device Hostname" \
   "discovery"  "Network Discovery" \
   "wireless"   "WiFi & Bluetooth Modules" \
   "back"       "<< Back to wizard")

  case "$choice" in
   resolution) adv_resolution ;;
   gpu)        adv_gpu_memory ;;
   hostname)   adv_hostname ;;
   discovery)  adv_discovery ;;
   wireless)   adv_wireless ;;
   back|"")    done=1 ;;
  esac
 done
}

adv_resolution() {
 if ! is_pi4_kms; then
  show_info "Resolution" "Resolution is set in config.txt on legacy Pi models."
  return
 fi

 local modes_menu=()
 local modetest_output
 modetest_output=$($MODETEST -M vc4 -c 2>/dev/null || echo "")

 local found_connector=0
 while IFS= read -r line; do
  [[ "$line" =~ connected ]] && { found_connector=1; continue; }
  [ $found_connector -eq 0 ] && continue
  [[ "$line" =~ ^[[:space:]]+props: ]] && break
  [[ "$line" =~ ^[[:space:]]+[0-9]+[[:space:]] ]] && break

  if [[ "$line" =~ \#([0-9]+)[[:space:]]+([0-9]+x[0-9]+)[[:space:]]+([0-9]+\.[0-9]+) ]]; then
   local idx="${BASH_REMATCH[1]}"
   local res="${BASH_REMATCH[2]}"
   local hz="${BASH_REMATCH[3]}"
   local hz_int="${hz%%.*}"
   local type_info=""
   [[ "$line" =~ type:\ (.*)$ ]] && type_info="${BASH_REMATCH[1]}"
   [[ "$res" =~ i$ ]] && continue

   local desc="${res} ${hz_int}Hz"
   [[ "$type_info" =~ preferred ]] && desc="$desc (preferred)"
   modes_menu+=("$idx" "$desc")
  fi
 done <<< "$modetest_output"
 modes_menu+=("auto" "Auto-detect from display EDID")

 if [ ${#modes_menu[@]} -le 2 ]; then
  show_info "No Modes" "Could not detect display modes.\nMake sure HDMI is connected."
  return
 fi

 local choice
 choice=$(show_menu "Display Resolution" \
  "Select the output resolution.\nFor calibration, 1080p is sufficient even for 4K TVs." \
  "${modes_menu[@]}")

 if [ -n "$choice" ]; then
  if [ "$choice" = "auto" ]; then
   sed -i '/^mode_idx=/d' "$PGENERATOR_CONF" 2>/dev/null || true
   sed -i '/^resolution=/d' "$PGENERATOR_CONF" 2>/dev/null || true
   sync
   show_info "Resolution" "Mode cleared. Auto-detect from display EDID."
  else
   write_pg_conf "mode_idx" "$choice"
   local res_label=""
   for ((i=0; i<${#modes_menu[@]}; i+=2)); do
    [ "${modes_menu[$i]}" = "$choice" ] && { res_label="${modes_menu[$((i+1))]}"; break; }
   done
   write_pg_conf "resolution" "$res_label"
   show_info "Resolution Set" "Mode #$choice: $res_label"
  fi
 fi
}

adv_gpu_memory() {
 local current_mem
 current_mem=$(read_boot_conf "gpu_mem")
 [ -z "$current_mem" ] && current_mem="64"

 local choice
 choice=$(show_menu "GPU Memory" \
  "GPU memory allocation.\n\n64 MB:  Standard PGenerator usage\n128 MB: Ted's Pattern Disk\n192 MB: HCFR internal patterns\n\nCurrent: ${current_mem} MB" \
  "64"  "64 MB -- standard (default)" \
  "128" "128 MB -- Ted's Pattern Disk" \
  "192" "192 MB -- HCFR internal patterns" \
  "256" "256 MB -- maximum")

 if [ -n "$choice" ] && [ "$choice" != "$current_mem" ]; then
  write_boot_conf "gpu_mem" "$choice"
  NEEDS_REBOOT=1
  show_info "GPU Memory" "GPU memory set to ${choice} MB.\nA reboot is required."
 fi
}

adv_hostname() {
 local current
 current=$(cat "$HOSTNAME_FILE" 2>/dev/null || hostname)

 local new_name
 new_name=$(get_input "Hostname" \
  "Enter a hostname for this PGenerator device." "$current")

 if [ -n "$new_name" ] && [ "$new_name" != "$current" ]; then
  echo "$new_name" > "$HOSTNAME_FILE"
  sync
  hostname "$new_name" 2>/dev/null || true
  show_info "Hostname" "Hostname changed to: $new_name"
 fi
}

adv_discovery() {
 local disc_status="enabled"
 [ -f "$DISCOVERABLE_FILE" ] && disc_status="disabled"

 if ask_yesno "Network Discovery" \
  "Allow calibration software to auto-discover\nthis PGenerator on the network?\n\nCurrently: $disc_status"; then
  rm -f "$DISCOVERABLE_FILE" 2>/dev/null
 else
  echo "DISABLED" > "$DISCOVERABLE_FILE"
 fi
 sync
}

adv_wireless() {
 local wifi_disabled=0 bt_disabled=0
 grep -q "^dtoverlay=disable-wifi" "$BOOTLOADER_FILE" 2>/dev/null && wifi_disabled=1
 grep -q "^dtoverlay=disable-bt" "$BOOTLOADER_FILE" 2>/dev/null && bt_disabled=1

 local wifi_status="ENABLED" bt_status="ENABLED"
 [ $wifi_disabled -eq 1 ] && wifi_status="DISABLED"
 [ $bt_disabled -eq 1 ] && bt_status="DISABLED"

 local choice
 choice=$(show_menu "Wireless Modules" \
  "WiFi: $wifi_status | Bluetooth: $bt_status" \
  "enable_both"  "Enable both WiFi and Bluetooth" \
  "disable_both" "Disable both (wired only)" \
  "wifi_only"    "Enable WiFi only" \
  "bt_only"      "Enable Bluetooth only" \
  "keep"         "Keep current settings")

 case "$choice" in
  enable_both)
   sed -i '/^dtoverlay=disable-wifi/d' "$BOOTLOADER_FILE"
   sed -i '/^dtoverlay=disable-bt/d' "$BOOTLOADER_FILE"
   sync; NEEDS_REBOOT=1 ;;
  disable_both)
   grep -q "^dtoverlay=disable-wifi" "$BOOTLOADER_FILE" || echo "dtoverlay=disable-wifi" >> "$BOOTLOADER_FILE"
   grep -q "^dtoverlay=disable-bt" "$BOOTLOADER_FILE" || echo "dtoverlay=disable-bt" >> "$BOOTLOADER_FILE"
   sync; NEEDS_REBOOT=1 ;;
  wifi_only)
   sed -i '/^dtoverlay=disable-wifi/d' "$BOOTLOADER_FILE"
   grep -q "^dtoverlay=disable-bt" "$BOOTLOADER_FILE" || echo "dtoverlay=disable-bt" >> "$BOOTLOADER_FILE"
   sync; NEEDS_REBOOT=1 ;;
  bt_only)
   grep -q "^dtoverlay=disable-wifi" "$BOOTLOADER_FILE" || echo "dtoverlay=disable-wifi" >> "$BOOTLOADER_FILE"
   sed -i '/^dtoverlay=disable-bt/d' "$BOOTLOADER_FILE"
   sync; NEEDS_REBOOT=1 ;;
  *) return ;;
 esac
 show_info "Wireless" "Updated. Reboot required."
}

###############################################################################
# Summary
###############################################################################

show_summary() {
 local sdr_hdr="SDR"
 [ "$(read_pg_conf is_hdr)" = "1" ] && sdr_hdr="HDR"
 [ "$(read_pg_conf is_ll_dovi)" = "1" ] && sdr_hdr="Dolby Vision (LL)"
 [ "$(read_pg_conf is_std_dovi)" = "1" ] && sdr_hdr="Dolby Vision (Std)"

 local color_fmt="RGB Full"
 case "$(read_pg_conf color_format)" in
  1) color_fmt="YCbCr 444 (Limited)" ;;
  2) color_fmt="YCbCr 422 (Limited)" ;;
 esac

 local colorimetry="BT709"
 [ "$(read_pg_conf colorimetry)" = "1" ] && colorimetry="BT2020"

 local bit_depth
 bit_depth=$(read_pg_conf "max_bpc")
 [ -z "$bit_depth" ] && bit_depth="8"

 local quant_range="Full (0-255)"
 case "$(read_pg_conf rgb_quant_range)" in
  0) quant_range="Default (auto)" ;;
  1) quant_range="Limited (16-235)" ;;
 esac

 local eotf_name="N/A"
 if [ "$sdr_hdr" = "HDR" ]; then
  case "$(read_pg_conf eotf)" in
   2) eotf_name="SMPTE ST.2084 (PQ)" ;;
   3) eotf_name="HLG" ;;
   *) eotf_name="$(read_pg_conf eotf)" ;;
  esac
 fi

 local primaries_name="N/A"
 if [ "$sdr_hdr" = "HDR" ]; then
  case "$(read_pg_conf primaries)" in
   2) primaries_name="P3 / D65" ;;
   3) primaries_name="REC.2020 / D65" ;;
   *) primaries_name="$(read_pg_conf primaries)" ;;
  esac
 fi

 local net_ips
 net_ips=$(get_all_ips)

 local summary="Network:\n${net_ips}\
  Signal Mode:   $sdr_hdr\n\
  Color Format:  $color_fmt\n\
  Colorimetry:   $colorimetry\n\
  Bit Depth:     ${bit_depth}-bit\n\
  Quant Range:   $quant_range\n"

 if [ "$sdr_hdr" = "HDR" ]; then
  summary="${summary}\
  EOTF:          $eotf_name\n\
  Primaries:     $primaries_name\n\
  Max Luma:      $(read_pg_conf max_luma) nits\n\
  Min Luma:      $(read_pg_conf min_luma) (x0.0001 nits)\n\
  MaxCLL:        $(read_pg_conf max_cll) nits\n\
  MaxFALL:       $(read_pg_conf max_fall) nits\n"
 fi

 if [[ "$sdr_hdr" =~ "Dolby Vision" ]]; then
  local dv_cs="YCbCr 422 (12-bit)"
  case "$(read_pg_conf dv_color_space)" in
   1) dv_cs="RGB 444 (8-bit tunnel)" ;;
   2) dv_cs="YCbCr 444 (10-bit)" ;;
  esac
  local dv_md="Type 1 (static)"
  [ "$(read_pg_conf dv_metadata)" = "1" ] && dv_md="Type 4 (dynamic)"
  summary="${summary}\
  DV Color Space: $dv_cs\n\
  DV Metadata:    $dv_md\n\
  DV Diagonal:    $(read_pg_conf dv_diagonal) inches\n"
 fi

 summary="${summary}\n\
$([ "${NEEDS_REBOOT:-0}" -eq 1 ] && echo "A REBOOT is required for some changes.\n")\
All settings saved. Continue to start PGenerator?"

 dialog --backtitle "$BACKTITLE" --timeout $DIALOG_TIMEOUT --title "Configuration Summary" \
  --yesno "$summary" 24 $DIALOG_WIDTH
}

###############################################################################
# Auto-set resolution to 4K 30Hz (or best available)
###############################################################################

auto_set_resolution() {
 if ! is_pi4_kms; then
  return
 fi

 # Already configured? Skip.
 local cur_mode
 cur_mode=$(read_pg_conf "mode_idx")
 [ -n "$cur_mode" ] && return

 local modetest_output
 modetest_output=$($MODETEST -M vc4 -c 2>/dev/null || echo "")
 [ -z "$modetest_output" ] && return

 # Look for 3840x2160 30Hz first, then 3840x2160 at any rate, then preferred
 local target_idx="" target_desc=""
 local preferred_idx="" preferred_desc=""

 local found_connector=0
 while IFS= read -r line; do
  [[ "$line" =~ connected ]] && { found_connector=1; continue; }
  [ $found_connector -eq 0 ] && continue
  [[ "$line" =~ ^[[:space:]]+props: ]] && break
  [[ "$line" =~ ^[[:space:]]+[0-9]+[[:space:]] ]] && break

  if [[ "$line" =~ \#([0-9]+)[[:space:]]+([0-9]+x[0-9]+)[[:space:]]+([0-9]+\.[0-9]+) ]]; then
   local idx="${BASH_REMATCH[1]}"
   local res="${BASH_REMATCH[2]}"
   local hz="${BASH_REMATCH[3]}"
   local hz_int="${hz%%.*}"
   local type_info=""
   [[ "$line" =~ type:\ (.*)$ ]] && type_info="${BASH_REMATCH[1]}"
   [[ "$res" =~ i$ ]] && continue

   # Track preferred mode as fallback
   if [[ "$type_info" =~ preferred ]] && [ -z "$preferred_idx" ]; then
    preferred_idx="$idx"
    preferred_desc="${res} ${hz_int}Hz"
   fi

   # Best match: 4K 30Hz
   if [ "$res" = "3840x2160" ] && [ "$hz_int" = "30" ] && [ -z "$target_idx" ]; then
    target_idx="$idx"
    target_desc="${res} ${hz_int}Hz"
   fi
  fi
 done <<< "$modetest_output"

 # Use 4K 30Hz if found, otherwise preferred mode
 if [ -n "$target_idx" ]; then
  write_pg_conf "mode_idx" "$target_idx"
  write_pg_conf "resolution" "$target_desc"
  echo "$(date) auto_set_resolution: 4K30 mode_idx=$target_idx" >&3
 elif [ -n "$preferred_idx" ]; then
  write_pg_conf "mode_idx" "$preferred_idx"
  write_pg_conf "resolution" "$preferred_desc"
  echo "$(date) auto_set_resolution: preferred mode_idx=$preferred_idx ($preferred_desc)" >&3
 fi
}

###############################################################################
# Main Wizard Flow -- Step-by-Step
###############################################################################

main_wizard() {
 NEEDS_REBOOT=0
 echo "$(date) main_wizard() entered" >&3

 # Clean console
 stty sane 2>/dev/null || true
 printf '\033c' 2>/dev/null || true
 printf '\033[2J\033[H' 2>/dev/null || true
 clear 2>/dev/null || true

 update_backtitle

 # Welcome -- if nobody presses OK within 15 seconds, skip the wizard
 # entirely and start PGenerator with the current (existing) settings.
 if ! dialog --backtitle "$BACKTITLE" --timeout 15 \
  --title "PGenerator Setup Wizard" --msgbox \
  "Welcome to PGenerator Setup!\n\n\
This wizard will walk you through configuration\n\
step by step, following the recommended order.\n\n\
Current network addresses:\n$(get_all_ips)\n\
Press OK to begin, or wait 15 seconds to skip\n\
and start PGenerator with current settings." \
  18 $DIALOG_WIDTH; then

  echo "$(date) Welcome timed out -- skipping wizard" >&3
  dialog --backtitle "$BACKTITLE" --title "PGenerator Starting" --infobox \
   "No input detected.\n\n\
Starting PGenerator with current settings...\n\n\
Network addresses:\n$(get_all_ips)\n\
Connect your calibration software to any IP above.\n\n\
This wizard will appear again on next boot." \
   14 $DIALOG_WIDTH
  sleep 3
  clear
  return
 fi

 #---------------------------------------------------------------------------
 # Step 0: Auto-set resolution to 4K 30Hz if available
 #---------------------------------------------------------------------------
 auto_set_resolution

 #---------------------------------------------------------------------------
 # Step 1: Network / WiFi
 #---------------------------------------------------------------------------
 step_wifi
 update_backtitle

 #---------------------------------------------------------------------------
 # Step 2: Signal Mode (SDR / HDR)
 #---------------------------------------------------------------------------
 step_signal_mode
 local signal_mode=$?
 # 0=HDR, 1=SDR, 2=HLG, 3=DV_LL, 4=DV_STD

 local mode_label="SDR"
 [ $signal_mode -eq 0 ] && mode_label="HDR"
 [ $signal_mode -eq 2 ] && mode_label="HDR"
 [ $signal_mode -eq 3 ] && mode_label="DV"
 [ $signal_mode -eq 4 ] && mode_label="DV"

 #---------------------------------------------------------------------------
 # Steps 3-5: Output Format (AVI InfoFrame settings)
 #---------------------------------------------------------------------------
 step_color_format "$mode_label"
 step_colorimetry "$mode_label"
 step_bit_depth "$mode_label"
 step_quant_range "$mode_label"

 #---------------------------------------------------------------------------
 # HDR Steps 6-11: DRM InfoFrame (Mastering Display Metadata)
 #---------------------------------------------------------------------------
 if [ $signal_mode -eq 0 ]; then
  # HDR10 (PQ)
  show_info "DRM InfoFrame" \
   "Now configuring the HDR metadata.\n\nThese values are sent in the DRM InfoFrame and\ntell the display about the mastering environment.\n\nEach parameter should be set and applied in order.\nThe first time you use HDR, default values are\nprovided as a good starting point."

  step_hdr_eotf
  local eotf_mode=$?

  if [ $eotf_mode -eq 0 ]; then
   # PQ mode -- set all metadata
   step_hdr_primaries
   step_hdr_max_luma
   step_hdr_min_luma
   step_hdr_maxcll
   step_hdr_maxfall
  fi
  # If HLG was selected in EOTF step, metadata is zeroed/ignored
 elif [ $signal_mode -eq 2 ]; then
  # HLG -- set colorimetry to BT2020, no DRM metadata needed
  write_pg_conf "colorimetry" "1"
  write_pg_conf "max_bpc" "10"
  show_info "HLG Configuration" \
   "HLG mode configured.\n\nColorimetry: BT2020\nBit Depth: 10-bit\n\nHLG does not use DRM InfoFrame luminance metadata.\nPrimaries and luminance values will be ignored."
 elif [ $signal_mode -eq 3 ]; then
  # Dolby Vision Low Latency
  write_pg_conf "colorimetry" "1"
  step_dv_settings "ll"
 elif [ $signal_mode -eq 4 ]; then
  # Dolby Vision Standard
  write_pg_conf "colorimetry" "1"
  step_dv_settings "std"
 fi

 #---------------------------------------------------------------------------
 # Advanced Settings (optional)
 #---------------------------------------------------------------------------
 step_advanced

 #---------------------------------------------------------------------------
 # Summary
 #---------------------------------------------------------------------------
 show_summary || true

 # Apply bootloader changes
 echo "50" | dialog --backtitle "$BACKTITLE" --title "Applying" \
  --gauge "Applying settings..." 8 $DIALOG_WIDTH 0
 apply_bootloader
 sleep 1
 echo "100" | dialog --backtitle "$BACKTITLE" --title "Applying" \
  --gauge "Done!" 8 $DIALOG_WIDTH 0
 sleep 1

 # Final
 if [ "${NEEDS_REBOOT:-0}" -eq 1 ]; then
  if ask_yesno "Reboot Required" \
   "Some settings require a reboot.\n\nReboot now?"; then
   dialog --backtitle "$BACKTITLE" --title "Rebooting" \
    --infobox "Rebooting PGenerator..." 5 $DIALOG_WIDTH
   sleep 2
   /sbin/reboot
  fi
 fi

 update_backtitle
 local final_ips
 final_ips=$(get_all_ips)
 dialog --backtitle "$BACKTITLE" --title "PGenerator Starting" --infobox \
  "Settings applied! PGenerator is starting...\n\n\
Network addresses:\n${final_ips}\n\
Connect your calibration software to any IP above.\n\n\
This wizard will appear again on next boot." \
  12 $DIALOG_WIDTH
 sleep 4

 clear
}

###############################################################################
# Entry point
###############################################################################

echo "$(date) Checking for dialog..." >&3
if ! command -v dialog &>/dev/null; then
 echo "ERROR: 'dialog' is required but not installed."
 exit 1
fi

if [ ! -f "$PGENERATOR_CONF" ]; then
 echo "ERROR: PGenerator configuration not found at $PGENERATOR_CONF"
 exit 1
fi

echo "$(date) About to call main_wizard" >&3
main_wizard
echo "$(date) main_wizard returned" >&3

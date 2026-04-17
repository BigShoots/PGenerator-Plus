#!/bin/bash
# spotread_wrapper.sh - Non-interactive spotread wrapper with JSON output
# Uses 'script' command to provide PTY for spotread
# Usage:
#   spotread_wrapper.sh --detect              Detect connected meter
#   spotread_wrapper.sh [-d type] [-n count]  Take readings
#     -d type: l=LCD, c=CRT/OLED, p=projector (default: l)
#     -n count: number of readings (default: 1)
#     --timeout secs: per-reading timeout (default: 30)

set -o pipefail

SPOTREAD_BIN="/usr/bin/spotread"
TMPDIR="/tmp"
API_BASE="http://127.0.0.1/api"

# Known USB meter IDs
declare -A KNOWN_METERS=(
 ["0765:5020"]="Calibrite/X-Rite i1Display Pro Plus"
 ["0765:5001"]="X-Rite i1 Pro"
 ["0971:2000"]="X-Rite i1 Pro"
 ["0971:2007"]="X-Rite i1 Display Pro / ColorMunki Display"
 ["085c:0500"]="Datacolor Spyder 5"
 ["085c:0a00"]="Datacolor SpyderX"
 ["04db:0100"]="ColorVision Spyder"
 ["0670:0001"]="Sequel Chroma 5"
)

kill_stale() {
 # Kill any stale spotread/script/wrapper processes from previous reads
 # Must run as root to kill root-owned processes
 # Note: don't match "spotread_wrapper" broadly here — we are spotread_wrapper!
 # Use fuzzy pattern that excludes our own PID via pgrep -f | grep -v $$
 pkill -9 -x spotread 2>/dev/null
 pkill -9 -f 'script.*spotread' 2>/dev/null
 pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null
 pkill -9 -f 'meter_series\.sh' 2>/dev/null
 # Remove stale temp files (NOT /tmp/meter_read.json.tmp — that is the
 # daemon's live stdout redirection target while the wrapper is running;
 # removing it unlinks our own inode and the daemon sees no output).
 rm -f /tmp/spotread_cmd_* /tmp/spotread_out_* /tmp/spotread_series_* 2>/dev/null
 # Drop port cache if older than 1h so we re-probe a valid port
 if [[ -f /tmp/spotread_port_cache ]]; then
  local cage
  cage=$(( $(date +%s) - $(stat -c %Y /tmp/spotread_port_cache 2>/dev/null || echo 0) ))
  (( cage > 3600 )) && rm -f /tmp/spotread_port_cache
 fi
 sleep 0.3
}

detect_meter() {
 local found=false name="" usb_id="" port=""
 while IFS= read -r line; do
  local id
  id=$(echo "$line" | grep -oP 'ID\s+\K[0-9a-f]{4}:[0-9a-f]{4}')
  if [[ -n "$id" && -n "${KNOWN_METERS[$id]}" ]]; then
   found=true
   name="${KNOWN_METERS[$id]}"
   usb_id="$id"
   local bus dev
   bus=$(echo "$line" | grep -oP 'Bus\s+\K\d+')
   dev=$(echo "$line" | grep -oP 'Device\s+\K\d+')
   port="/dev/bus/usb/$bus/$dev"
   break
  fi
 done < <(lsusb 2>/dev/null)

 local sr_avail=false
 [[ -x "$SPOTREAD_BIN" ]] && sr_avail=true

 if $found; then
  printf '{"detected":true,"name":"%s","usb_id":"%s","port":"%s","spotread_available":%s}\n' \
   "$name" "$usb_id" "$port" "$sr_avail"
 else
  printf '{"detected":false,"name":null,"usb_id":null,"port":null,"spotread_available":%s}\n' \
   "$sr_avail"
 fi
}

find_port() {
 # Cache the spotread port number to avoid re-running spotread -? for every reading
 local cache="/tmp/spotread_port_cache"
 if [[ -f "$cache" ]]; then
  local cached age
  cached=$(cat "$cache" 2>/dev/null)
  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
  if (( age < 86400 )) && [[ -n "$cached" ]]; then
   echo "$cached"
   return
  fi
 fi
 local help_out
 help_out=$(timeout 5 "$SPOTREAD_BIN" -? 2>&1 || true)
 local port_num="1"
 while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]+([0-9]+)[[:space:]]*=[[:space:]]*\'/dev/bus/usb/ ]]; then
   port_num="${BASH_REMATCH[1]}"
   break
  fi
 done <<< "$help_out"
 echo "$port_num" > "$cache"
 # Allow USB device to fully release after spotread -? probe
 sleep 2
 echo "$port_num"
}

take_readings() {
 local display_type="$1" count="$2" timeout_per="$3" ccss_file="$4"
 local port_num
 port_num=$(find_port)

 local outfile="$TMPDIR/spotread_out_$$"
 rm -f "$outfile"
 touch "$outfile"

 # Build spotread command
 local sr_cmd="$SPOTREAD_BIN -e -y $display_type -c $port_num -x"
 if [[ -n "$ccss_file" && -f "$ccss_file" ]]; then
  sr_cmd="$SPOTREAD_BIN -e -y $display_type -X '$ccss_file' -c $port_num -x"
 fi
 # Override refresh rate if specified
 if [[ -n "$refresh_rate" ]]; then
  sr_cmd="$sr_cmd -Y R:$refresh_rate"
 fi

 # Disable AIO mode for i1D3 meters if requested
 if $disable_aio; then
  export I1D3_DISABLE_AIO=1
 fi

 # Create a named pipe for sending keystrokes to spotread
 local cmdpipe="$TMPDIR/spotread_cmd_$$"
 rm -f "$cmdpipe"
 mkfifo "$cmdpipe"

 # Start spotread in background: feeder reads from cmdpipe, pipes to script
 # The cat keeps the pipe open so script doesn't get EOF
 cat "$cmdpipe" | script -qfc "$sr_cmd" /dev/null > "$outfile" 2>&1 &
 local bg_pid=$!

 # Open write end of pipe (this unblocks the cat)
 exec 3>"$cmdpipe"

 local readings=()
 local i=0
 local total_timeout=$(( 15 + count * (timeout_per + 5) ))
 local start=$SECONDS

 # Wait for spotread prompt; if it doesn't arrive, force-cleanup and retry once
 local ready=false
 local init_try=0
 while (( init_try < 2 )); do
  while (( SECONDS - start < 30 )); do
   if grep -q "to take a reading:" "$outfile" 2>/dev/null; then
    ready=true; break
   fi
   sleep 0.1
  done
  $ready && break
  # First attempt failed — tear down, force cleanup, retry
  init_try=$((init_try + 1))
  printf "Q" >&3 2>/dev/null
  exec 3>&- 2>/dev/null
  kill -9 "$bg_pid" 2>/dev/null
  wait "$bg_pid" 2>/dev/null
  rm -f "$outfile" "$cmdpipe" 2>/dev/null
  pkill -9 -x spotread 2>/dev/null
  pkill -9 -f 'script.*spotread' 2>/dev/null
  rm -f /tmp/spotread_port_cache 2>/dev/null
  sleep 2
  port_num=$(find_port)
  touch "$outfile"
  mkfifo "$cmdpipe"
  cat "$cmdpipe" | script -qfc "$sr_cmd" /dev/null > "$outfile" 2>&1 &
  bg_pid=$!
  exec 3>"$cmdpipe"
  start=$SECONDS
 done
 if ! $ready; then
  printf '{"status":"error","readings":[],"count":0,"error":"Meter init failed"}\n'
  printf "Q" >&3 2>/dev/null; exec 3>&- 2>/dev/null
  kill -9 "$bg_pid" 2>/dev/null; wait "$bg_pid" 2>/dev/null
  pkill -9 -x spotread 2>/dev/null
  rm -f "$outfile" "$cmdpipe" 2>/dev/null
  return 1
 fi

 # Refresh-rate calibration: in CRT/OLED mode spotread may first ask for an
 # 80% white patch to calibrate refresh frequency. Satisfy that prompt once,
 # then restore the requested patch before the actual measurement loop.
 local clean_init
 clean_init=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$outfile" 2>/dev/null | tr -d '\r')
 if echo "$clean_init" | grep -qi "calibrate refresh frequency"; then
  if [[ -n "$patch_size" ]]; then
   curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"patch\",\"r\":255,\"g\":255,\"b\":255,\"size\":$patch_size,\"input_max\":255}" >/dev/null 2>&1 || true
   sleep 1.5
  fi
  local initial_prompts cur_prompts cal_wait=0
  initial_prompts=$(echo "$clean_init" | grep -c "to take a reading:")
  printf " " >&3
  while (( cal_wait < 30 )); do
   clean_init=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$outfile" 2>/dev/null | tr -d '\r')
   cur_prompts=$(echo "$clean_init" | grep -c "to take a reading:")
   if (( cur_prompts > initial_prompts )); then
    break
   fi
   sleep 0.1
   cal_wait=$((cal_wait + 1))
  done
  if [[ -n "$patch_r" && -n "$patch_g" && -n "$patch_b" ]]; then
   curl -s "$API_BASE/pattern" -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"patch\",\"r\":$patch_r,\"g\":$patch_g,\"b\":$patch_b,\"size\":$patch_size,\"input_max\":255}" >/dev/null 2>&1 || true
   sleep 0.5
  fi
 fi

 # count_results: strip ANSI, count result lines
 count_results() {
  local n
  n=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$outfile" 2>/dev/null | tr -d '\r' | grep -c "Result is XYZ:" 2>/dev/null) || true
  echo "${n:-0}" | tr -d '[:space:]'
 }

 # Take readings
 while (( i < count && SECONDS - start < total_timeout )); do
  local prev_count
  prev_count=$(count_results)

  # Send space to trigger reading
  printf " " >&3

  # Wait for result
  local read_start=$SECONDS
  while (( SECONDS - read_start < timeout_per )); do
   local cur_count
   cur_count=$(count_results)
   if (( cur_count > prev_count )); then
    break
   fi
   sleep 0.1
  done

  # Parse latest result - strip ANSI codes first
  local clean_out
  clean_out=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$outfile" 2>/dev/null | tr -d '\r')
  local result_line
  result_line=$(echo "$clean_out" | grep "Result is XYZ:" | tail -1)
  if [[ -n "$result_line" ]]; then
   # Parse: "Result is XYZ: X Y Z, Yxy: lum x y"
   local xyz_part yxy_part
   xyz_part=$(echo "$result_line" | sed 's/.*XYZ:\s*//' | sed 's/,.*//')
   yxy_part=$(echo "$result_line" | sed 's/.*Yxy:\s*//')

   local X Y Z lum x_chr y_chr
   X=$(echo "$xyz_part" | awk '{print $1}')
   Y=$(echo "$xyz_part" | awk '{print $2}')
   Z=$(echo "$xyz_part" | awk '{print $3}')
   lum=$(echo "$yxy_part" | awk '{print $1}')
   x_chr=$(echo "$yxy_part" | awk '{print $2}')
   y_chr=$(echo "$yxy_part" | awk '{print $3}')

   # McCamy CCT approximation
   local cct=0
   if [[ -n "$x_chr" && -n "$y_chr" && "$y_chr" != "0.000000" ]]; then
    cct=$(python -c "
x=$x_chr; y=$y_chr
if y > 0:
 n = (x - 0.3320) / (0.1858 - y)
 print(int(round(449*n**3 + 3525*n**2 + 6823.3*n + 5520.33)))
else:
 print(0)
" 2>/dev/null || echo 0)
   fi

   local ts
   ts=$(date +%s)
   readings+=("{\"X\":$X,\"Y\":$Y,\"Z\":$Z,\"x\":$x_chr,\"y\":$y_chr,\"luminance\":$lum,\"cct\":$cct,\"timestamp\":$ts}")
   i=$((i + 1))

   # Wait for prompt again if more readings needed
   if (( i < count )); then
    sleep 0.1
   fi
  else
   break
  fi
 done

 # Send Q to quit spotread
 printf "Q" >&3
 exec 3>&- 2>/dev/null
 sleep 0.2

 # Aggressively kill the entire process tree (cat | script -> spotread)
 # First try killing the pipeline lead
 kill "$bg_pid" 2>/dev/null
 # Kill any child processes of the pipeline (script, spotread)
 local kids
 kids=$(pgrep -P "$bg_pid" 2>/dev/null)
 for p in $kids; do
  local grandkids
  grandkids=$(pgrep -P "$p" 2>/dev/null)
  kill -9 $grandkids 2>/dev/null
  kill -9 "$p" 2>/dev/null
 done
 kill -9 "$bg_pid" 2>/dev/null
 wait "$bg_pid" 2>/dev/null
 # Final safety: kill any lingering spotread processes
 pkill -9 -x spotread 2>/dev/null
 rm -f "$outfile" "$cmdpipe"

 # Build JSON output
 local readings_json
 readings_json=$(printf "%s," "${readings[@]}" | sed 's/,$//')
 if (( ${#readings[@]} > 0 )); then
  printf '{"status":"ok","readings":[%s],"count":%d}\n' "$readings_json" "${#readings[@]}"
 else
  printf '{"status":"error","readings":[],"count":0,"error":"No readings obtained"}\n'
 fi
}

# Parse arguments
display_type="l"
count=1
timeout_per=30
detect_only=false
kill_only=false
ccss_file=""
refresh_rate=""
disable_aio=false
patch_r=""
patch_g=""
patch_b=""
patch_size="10"

while [[ $# -gt 0 ]]; do
 case "$1" in
  --detect) detect_only=true; shift ;;
  --kill) kill_only=true; shift ;;
  -d) display_type="$2"; shift 2 ;;
  -n) count="$2"; shift 2 ;;
  --timeout) timeout_per="$2"; shift 2 ;;
  -X) ccss_file="$2"; shift 2 ;;
  --refresh-rate) refresh_rate="$2"; shift 2 ;;
  --disable-aio) disable_aio=true; shift ;;
  --patch-r) patch_r="$2"; shift 2 ;;
  --patch-g) patch_g="$2"; shift 2 ;;
  --patch-b) patch_b="$2"; shift 2 ;;
  --patch-size) patch_size="$2"; shift 2 ;;
  *) shift ;;
 esac
done

# Map friendly names
case "$display_type" in
 lcd|LCD) display_type="l" ;;
 oled|OLED|crt|CRT) display_type="c" ;;
 projector|proj) display_type="p" ;;
esac

if $detect_only; then
 detect_meter
elif $kill_only; then
 kill_stale
else
 kill_stale
 take_readings "$display_type" "$count" "$timeout_per" "$ccss_file"
fi

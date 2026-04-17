#!/bin/bash
set -x
SPOTREAD_BIN="/usr/bin/spotread"

pkill -9 -x spotread 2>/dev/null
pkill -9 -f 'script.*spotread' 2>/dev/null
sleep 0.5

# find port
PORT_NUM=$(timeout 5 $SPOTREAD_BIN -? 2>&1 | grep -oP '^\s+\K[0-9]+(?=\s*=\s*./dev/bus/usb/)' | head -1)
echo "PORT=$PORT_NUM"

OUTFILE="/tmp/test_sr_out_$$"
CMDPIPE="/tmp/test_sr_pipe_$$"
rm -f "$OUTFILE" "$CMDPIPE"
touch "$OUTFILE"
mkfifo "$CMDPIPE"

SR_CMD="$SPOTREAD_BIN -e -y l -c ${PORT_NUM:-1} -x"
echo "CMD=$SR_CMD"
cat "$CMDPIPE" | script -qfc "$SR_CMD" /dev/null > "$OUTFILE" 2>&1 &
BG_PID=$!
exec 3>"$CMDPIPE"

echo "BG_PID=$BG_PID"
READY=false
for w in $(seq 1 15); do
  if grep -q "to take a reading:" "$OUTFILE" 2>/dev/null; then
    READY=true
    break
  fi
  sleep 0.5
done

echo "READY=$READY"
echo "=== OUTFILE CONTENT ==="
cat "$OUTFILE" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r' | head -20
echo "=== END ==="

printf "Q" >&3 2>/dev/null
exec 3>&- 2>/dev/null
kill $BG_PID 2>/dev/null
pkill -9 -x spotread 2>/dev/null
rm -f "$OUTFILE" "$CMDPIPE"

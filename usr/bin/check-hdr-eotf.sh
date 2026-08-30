#!/bin/bash
# check-hdr-eotf.sh — verify the live on-wire HDR_OUTPUT_METADATA on the Pi4
#
# Reads the vc4 HDMI-A connector property blob via `modetest -M vc4 -c N -p`
# and decodes the static HDR metadata block:
#   byte 4      = EOTF  (0=SDR, 1=Traditional HDR, 2=PQ/ST.2084, 3=HLG)
#   byte 22-23  = max_dml (peak cd/m^2)
#   byte 24-25  = min_dml (0.0001 cd/m^2 units)
#   byte 26-27  = max_cll (cd/m^2)
#   byte 28-29  = max_fall (cd/m^2)
#
# Also surfaces the kernel's HDMI RAM_PACKET_CONFIG register.  bit7 is the
# "DRM/HDR infoframe enable" bit — if it's 0 the TV never sees the EOTF
# even though the connector property blob is set, and the panel will
# decode the PQ-coded signal as gamma (which is the classic "20% reads
# ~10x target" autocal failure mode).
#
# Usage:  check-hdr-eotf.sh            # auto-find connected HDMI connector
#         check-hdr-eotf.sh 33         # force connector id
#
# Exit:   0  = EOTF on wire is ST.2084 (PQ) AND RAM_PACKET_CONFIG bit7 is set
#         1  = anything else (with a diagnostic printed first)
#         2  = modetest not available

set -u

CONN="${1:-}"

MODETEST="$(command -v modetest 2>/dev/null || echo /usr/bin/modetest)"
if [ ! -x "$MODETEST" ]; then
    echo "FAIL: modetest not found on this device (tried $MODETEST)" >&2
    exit 2
fi

# --- find a connected HDMI-A connector if user didn't pin one ------------
if [ -z "$CONN" ]; then
    LISTING="$("$MODETEST" -M vc4 2>/dev/null || true)"
    CONN="$(printf '%s\n' "$LISTING" \
        | awk '/^[0-9]+\s+[0-9]+\s+connected/ && $4 ~ /^HDMI-A-/ { print $1; exit }')"
    if [ -z "$CONN" ]; then
        echo "FAIL: no connected HDMI-A connector on vc4" >&2
        echo "      listing was:" >&2
        printf '%s\n' "$LISTING" | sed 's/^/      /' >&2
        exit 1
    fi
fi

# --- capture modetest property dump ---------------------------------------
TMP="$(mktemp /tmp/mt_hdr.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
if ! "$MODETEST" -M vc4 -c "$CONN" -p > "$TMP" 2>/dev/null; then
    echo "FAIL: modetest -M vc4 -c $CONN -p failed" >&2
    exit 1
fi

# --- collect RAM_PACKET_CONFIG for both HDMI controllers ------------------
RPC=""
for f in /sys/kernel/debug/dri/*/hdmi*_regs; do
    [ -f "$f" ] || continue
    val="$(grep -i 'RAM_PACKET_CONFIG' "$f" 2>/dev/null | head -1 \
        | sed -E 's/.*=\s*//')"
    [ -n "$val" ] && RPC="$RPC$f = $val"$'\n'
done

# --- decode the blob ------------------------------------------------------
python2 - "$CONN" "$RPC" "$TMP" <<'PY'
import sys, re

conn = sys.argv[1]
rpc  = sys.argv[2]
path = sys.argv[3]
raw  = open(path, "rb").read()
text = raw.decode("utf-8", errors="replace")

EOTF = {0: "SDR (traditional gamma)",
        1: "HDR (traditional gamma, rarely used)",
        2: "ST.2084 / PQ",
        3: "BT.2100 HLG"}

print "=== HDR_OUTPUT_METADATA on-wire check (vc4 connector %s) ===" % conn
if rpc.strip():
    print "RAM_PACKET_CONFIG (bit1=DV-VSIF  bit2=AVI  bit3=SPD  bit7=DRM/HDR):"
    for ln in rpc.strip().splitlines():
        v = ln.rsplit("=", 1)[-1].strip()
        try:
            iv = int(v, 16)
            bit7 = "ON " if iv & 0x80 else "OFF"
            bit2 = "on " if iv & 0x04 else "off"
            bit1 = "on " if iv & 0x02 else "off"
            print "  %s  [DRM/HDR-bit7=%s  AVI-bit2=%s  DV-VSIF-bit1=%s]" \
                % (ln, bit7, bit2, bit1)
        except ValueError:
            print "  %s" % ln
else:
    print "RAM_PACKET_CONFIG: (no hdmi*_regs debugfs files readable)"

# Find HDR_OUTPUT_METADATA and collect contiguous hex lines that follow
lines = text.splitlines()
i = 0
found = False
hexbuf = ""
hdr_lineno = -1
while i < len(lines):
    if "HDR_OUTPUT_METADATA" in lines[i] and re.search(r"^\s*\d+\s", lines[i]):
        found = True
        hdr_lineno = i
        j = i + 1
        while j < len(lines) and j < i + 30:
            s = lines[j].strip()
            # stop at next property header "<id> NAME:" once we have any hex
            if hexbuf and re.match(r"^\d+\s+\S+:", s):
                break
            # stop if we leave this connector's block
            if s and not s.startswith("#") and re.match(r"^[0-9]+\s+\d+\s+", s):
                # a new "id encoder status" connector header
                break
            if re.match(r"^[0-9a-fA-F]+$", s) and len(s) >= 8 and len(s) % 2 == 0:
                hexbuf += s
            j += 1
        break
    i += 1

if not found:
    print ""
    print "FAIL: HDR_OUTPUT_METADATA property is NOT exposed on connector %s." % conn
    print "      (vc4-hdmi only creates it for an active HDMI-A link; check the"
    print "       cable/connector and that `modetest -M vc4 -c %s` shows"
    print "       status: connected)" % conn
    sys.exit(1)

if not hexbuf:
    print ""
    print "FAIL: HDR_OUTPUT_METADATA property is exposed but the blob is EMPTY."
    print "      The renderer is NOT attaching metadata -- the TV is decoding"
    print "      in SDR even if the renderer was supposedly started in HDR."
    sys.exit(1)

# blob = [0:4] wrapper (4 bytes metadata_type) + 26-byte CTA-861-G static
# metadata block, for a total of 30 bytes in our typical 32-byte payload
# (some kernels append padding; we only inspect the meaningful 30).
b = bytearray.fromhex(hexbuf)
if len(b) < 30:
    print "FAIL: blob is only %d bytes, need >=30 for CTA-861-G static block" % len(b)
    print "      raw: %s" % hexbuf
    sys.exit(1)

def u16(o):
    return b[o] | (b[o+1] << 8)

eotf = b[4]
print ""
print "blob bytes (%d): %s" % (len(b), hexbuf)
print "EOTF (byte 4)     = %d  (%s)" % (eotf, EOTF.get(eotf, "UNKNOWN"))
print "max_dml (22-23)   = %d cd/m^2"  % u16(22)
print "min_dml (24-25)   = %d  (= %.4f cd/m^2)" % (u16(24), u16(24) * 0.0001)
print "max_cll (26-27)   = %d cd/m^2"  % u16(26)
print "max_fall (28-29)  = %d cd/m^2"  % u16(28)
# primaries as 0.00002 units
def coord(o):
    return u16(o) * 0.00002
r = (coord(6),  coord(8))
g = (coord(10), coord(12))
bl = (coord(14), coord(16))
w = (coord(18), coord(20))
print "primaries          R=(%.4f,%.4f) G=(%.4f,%.4f) B=(%.4f,%.4f)" % (r+g+bl)
print "white point        = (%.4f,%.4f)" % w

# RAM_PACKET_CONFIG bit7 is the DRM/HDR infoframe gate
rpc_bit7 = False
for ln in rpc.strip().splitlines():
    m = re.search(r"=\s*([0-9A-Fa-fx]+)\s*$", ln)
    if m:
        try:
            if int(m.group(1), 16) & 0x80:
                rpc_bit7 = True
        except ValueError:
            pass

print ""
if eotf == 2 and rpc_bit7:
    print "PASS: wire EOTF is ST.2084 (PQ) AND the DRM/HDR infoframe is enabled."
    print "      The TV is being told HDR-PQ. If 20%% still reads ~10x target,"
    print "      the issue is panel-side (dynamic contrast / ABL on small"
    print "      windows / picture-mode tone-map), not the source."
    sys.exit(0)
elif eotf == 2 and not rpc_bit7:
    print "FAIL: blob says EOTF=2 (PQ) but RAM_PACKET_CONFIG bit7 is OFF."
    print "      The TV never receives the HDR infoframe and decodes the"
    print "      PQ-coded signal as gamma -> autocal targets are unreachable."
    print "      Likely cause: PGeneratord is down (the renderer is the only"
    print "      path that re-enables the bit on every atomic commit)."
    print "      Try:  /etc/init.d/PGenerator restart"
    sys.exit(1)
else:
    print "FAIL: wire EOTF is %d (%s), NOT PQ." % (eotf, EOTF.get(eotf, "?"))
    print "      The renderer is sending an SDR or wrong-HDR infoframe."
    print "      The autocal's 20%% read will sit ~10x above target."
    sys.exit(1)
PY

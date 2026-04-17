#!/usr/bin/env python
"""Non-interactive spotread wrapper with JSON output.

Usage: spotread_measure.py [options]
  -n count        Number of readings (default: 1)
  -d type         Display type: l=LCD, c=CRT/OLED, p=projector (maps to spotread -y)
  --json          Output as JSON (default)
  --detect        Just detect meter, don't measure
  --timeout secs  Per-reading timeout (default: 30)
"""
import os, sys, subprocess, select, time, re, json

KNOWN_METERS = {
    "0765:5020": "Calibrite/X-Rite i1Display Pro Plus",
    "0765:5001": "X-Rite i1 Pro",
    "0971:2000": "X-Rite i1 Pro",
    "0971:2007": "X-Rite i1 Display Pro / ColorMunki Display",
    "085c:0500": "Datacolor Spyder 5",
    "085c:0a00": "Datacolor SpyderX",
    "04db:0100": "ColorVision Spyder",
    "0670:0001": "Sequel Chroma 5",
}

def detect_meter():
    """Detect connected USB colorimeter."""
    try:
        lsusb = os.popen("lsusb 2>/dev/null").read()
        for line in lsusb.strip().split("\n"):
            m = re.search(r"ID\s+([0-9a-f]{4}:[0-9a-f]{4})", line, re.I)
            if m:
                usb_id = m.group(1).lower()
                if usb_id in KNOWN_METERS:
                    bus_dev = re.search(r"Bus\s+(\d+)\s+Device\s+(\d+)", line)
                    port = ""
                    if bus_dev:
                        port = "/dev/bus/usb/%s/%s" % (bus_dev.group(1), bus_dev.group(2))
                    return {
                        "detected": True,
                        "name": KNOWN_METERS[usb_id],
                        "usb_id": usb_id,
                        "port": port
                    }
    except Exception:
        pass
    return {"detected": False, "name": None, "usb_id": None, "port": None}


def find_spotread_port():
    """Find the meter port number from lsusb."""
    # Default to port 1 - the first USB device is almost always correct
    return "1"


def run_spotread(args, count=1, timeout_per_read=30):
    """Run spotread and collect measurements using script(1) for PTY."""
    port = find_spotread_port()
    sr_cmd = "spotread -e -c %s -x %s" % (port, " ".join(args))

    sys.stderr.write("CMD: %s\n" % sr_cmd)

    # Use script(1) to provide a PTY - avoids os.fork()/pty issues in daemon context
    proc = subprocess.Popen(
        ["script", "-qfc", sr_cmd, "/dev/null"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    sys.stderr.write("PID %d\n" % proc.pid)

    import fcntl
    # Set stdout to non-blocking so we can poll it
    fd = proc.stdout.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)

    results = []
    buf = ""
    readings_taken = 0
    STATE_WAIT_PROMPT = 0
    STATE_WAIT_RESULT = 1
    state = STATE_WAIT_PROMPT

    try:
        start = time.time()
        total_timeout = 15 + (count * timeout_per_read)
        while readings_taken < count and (time.time() - start) < total_timeout:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    data = os.read(fd, 4096)
                    if not data:
                        break
                    buf += data
                except OSError:
                    pass

            if state == STATE_WAIT_PROMPT:
                if "any other key to take a reading:" in buf or "to take a reading:" in buf:
                    sys.stderr.write("Got prompt, sending space\n")
                    time.sleep(0.5)
                    proc.stdin.write(" ")
                    proc.stdin.flush()
                    buf = ""
                    state = STATE_WAIT_RESULT
                elif "Unsupported function" in buf:
                    sys.stderr.write("Meter error: Unsupported function\n")
                    break
                elif "Error" in buf and ("failed" in buf.lower() or "breakdown" in buf.lower()):
                    sys.stderr.write("Spotread error: %s\n" % buf.strip()[:200])
                    break

            elif state == STATE_WAIT_RESULT:
                m = re.search(
                    r"Result is XYZ:\s*([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)"
                    r",\s*Yxy:\s*([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)",
                    buf
                )
                if m:
                    X = float(m.group(1))
                    Y = float(m.group(2))
                    Z = float(m.group(3))
                    lum = float(m.group(4))
                    x_chrom = float(m.group(5))
                    y_chrom = float(m.group(6))

                    # Compute CCT (McCamy's approximation)
                    cct = 0
                    if y_chrom > 0:
                        n = (x_chrom - 0.3320) / (y_chrom - 0.1858)
                        cct = int(round(449*n**3 + 3525*n**2 + 6823.3*n + 5520.33))

                    results.append({
                        "X": round(X, 6),
                        "Y": round(Y, 6),
                        "Z": round(Z, 6),
                        "x": round(x_chrom, 6),
                        "y": round(y_chrom, 6),
                        "luminance": round(lum, 4),
                        "cct": cct,
                        "timestamp": int(time.time())
                    })
                    readings_taken += 1
                    buf = buf[m.end():]
                    state = STATE_WAIT_PROMPT
                elif "Error" in buf:
                    sys.stderr.write("Measurement error: %s\n" % buf.strip())
                    break
    except Exception as e:
        sys.stderr.write("Error: %s\n" % str(e))
    finally:
        try:
            proc.stdin.write("q")
            proc.stdin.flush()
        except:
            pass
        try:
            proc.wait()
        except:
            pass

    return results


if __name__ == "__main__":
    count = 1
    args = []
    detect_only = False
    timeout_per_read = 30
    display_type = "l"  # default LCD
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "-n" and i + 1 < len(sys.argv):
            count = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "-d" and i + 1 < len(sys.argv):
            display_type = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--detect":
            detect_only = True
            i += 1
        elif sys.argv[i] == "--timeout" and i + 1 < len(sys.argv):
            timeout_per_read = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--json":
            i += 1  # already default
        else:
            args.append(sys.argv[i])
            i += 1

    if detect_only:
        info = detect_meter()
        info["spotread_available"] = os.path.isfile("/usr/bin/spotread")
        print(json.dumps(info))
        sys.exit(0)

    # Map display type to spotread -y flag
    dtype_map = {"l": "l", "c": "c", "p": "p", "lcd": "l", "oled": "c", "projector": "p"}
    y_flag = dtype_map.get(display_type.lower(), "l")
    args = ["-y", y_flag] + args

    results = run_spotread(args, count, timeout_per_read)
    output = {
        "status": "ok" if results else "error",
        "readings": results,
        "count": len(results)
    }
    if not results:
        output["error"] = "No readings obtained"
    print(json.dumps(output))
    sys.exit(0 if results else 1)

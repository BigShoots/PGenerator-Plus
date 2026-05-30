#!/usr/bin/env python

import argparse
import io
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time
import traceback


ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MENU_RE = re.compile(r"Press\s+1\s*\.\.\s*\d+", re.I)
CONTINUE_RE = re.compile(r"(press|hit).*(any )?key|press return|key to continue", re.I)
ERROR_RE = re.compile(r"(no instrument|no device|instrument.*not connected|communications failure|initialisation failed|can't open|failed)", re.I)
# Prompts that require the user to physically position the instrument. These
# must NOT be auto-dismissed: the i1 Pro is calibrated on its white tile and
# then aimed at the screen, and the user's button press satisfies the prompt.
PLACEMENT_RE = re.compile(r"place the instrument|white reference|reflective|on the (?:test|display|spot|screen)|reposition|spot reading", re.I)


try:
    text_type = unicode
except NameError:
    text_type = str


def utf8_text(value):
    if isinstance(value, text_type):
        return value
    try:
        return value.decode("utf-8", "ignore")
    except Exception:
        return text_type(value)


def sanitize(text):
    text = utf8_text(text)
    text = ANSI_RE.sub("", text)
    return text.replace("\r", "\n")


class Runner:
    def __init__(self, args):
        self.args = args
        self.child = None
        self.master_fd = None
        self.measure_sent = False
        self.compute_sent = False
        self.exit_sent = False
        self.last_option3 = ""
        self.line_buffer = ""
        self.cancel_requested = False
        self.last_continue = 0.0
        self.last_message = ""
        self.recent = ""

    def write_state(self, status, message, **extra):
        payload = {"status": status, "message": message, "filename": os.path.basename(self.args.output_path)}
        payload.update(dict((key, value) for key, value in extra.items() if value not in (None, "")))
        tmp_path = "%s.tmp" % self.args.state_file
        json_text = utf8_text(json.dumps(payload, ensure_ascii=True))
        with io.open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write(json_text)
        os.rename(tmp_path, self.args.state_file)
        self.last_message = message

    def append_log(self, text):
        if not text:
            return
        with io.open(self.args.log_file, "a", encoding="utf-8", errors="ignore") as handle:
            handle.write(utf8_text(text))

    def fail(self, message, detail=""):
        if detail:
            self.append_log("%s\n" % utf8_text(detail))
        self.write_state("error", message, detail=detail)
        return 1

    def send(self, text):
        if self.master_fd is None:
            return
        data = text.encode("utf-8") if isinstance(text, text_type) else text
        os.write(self.master_fd, data)

    def terminate(self, signum=None, frame=None):
        self.cancel_requested = True
        self.write_state("cancelled", "CCSS creation cancelled")
        if self.child and self.child.poll() is None:
            try:
                self.child.terminate()
                self._wait_for_exit(2.0)
            except Exception:
                try:
                    self.child.kill()
                except Exception:
                    pass

    def _wait_for_exit(self, timeout_sec):
        if self.child is None:
            return None
        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            returncode = self.child.poll()
            if returncode is not None:
                return returncode
            time.sleep(0.05)
        return self.child.poll()

    def handle_line(self, line):
        text = line.strip()
        if not text:
            return
        self.recent = (self.recent + " " + text)[-800:]
        if text.startswith("3)"):
            self.last_option3 = text
        if CONTINUE_RE.search(text):
            if PLACEMENT_RE.search(self.recent):
                low = self.recent.lower()
                if "white reference" in low or "reflective" in low:
                    self.write_state(
                        "running",
                        "Rotate the i1 Pro to its white calibration tile (closed position) and press the i1 Pro button to calibrate.",
                        detail=text,
                    )
                else:
                    self.write_state(
                        "running",
                        "Point the i1 Pro at the patch on the screen and press the i1 Pro button to take the reading.",
                        detail=text,
                    )
                # Physical action required: wait for the user's button press;
                # do NOT auto-advance (that would calibrate/measure mid-air).
                return
            now = time.time()
            if now - self.last_continue > 0.8:
                self.send("\n")
                self.last_continue = now
            return
        if ERROR_RE.search(text):
            self.write_state("running", "ccxxmake reported a problem", detail=text)
            return
        lowered = text.lower()
        if "button" in lowered or "switch" in lowered:
            self.write_state("running", "Press the i1 Pro button to take the current reading", detail=text)
        elif "measure" in lowered or "reading" in lowered:
            self.write_state("running", "Measuring display patches with the i1 Pro", detail=text)
        elif "comput" in lowered or "save" in lowered:
            self.write_state("running", "Computing and saving the CCSS profile", detail=text)

    def maybe_advance_menu(self, window):
        if not MENU_RE.search(window):
            return
        if not self.measure_sent:
            # Wait for the full menu to render before selecting, otherwise the
            # keystroke can land mid-redraw and the instrument open misfires.
            if "2) Measure" not in window:
                return
            self.send("2\n")
            self.measure_sent = True
            self.write_state(
                "running",
                "Starting measurement. When prompted, calibrate the i1 Pro on its white tile, then aim it at the screen and use its button.",
            )
            return
        if self.measure_sent and not self.compute_sent and self.last_option3 and "[" not in self.last_option3:
            self.send("3\n")
            self.compute_sent = True
            self.write_state("running", "Computing and saving the CCSS profile")
            return
        if self.compute_sent and not self.exit_sent:
            self.send("4\n")
            self.exit_sent = True

    def run(self):
        self.write_state("starting", "Starting CCSS creation")
        with io.open(self.args.pid_file, "w", encoding="utf-8") as handle:
            handle.write(utf8_text(str(os.getpid())))

        signal.signal(signal.SIGTERM, self.terminate)
        signal.signal(signal.SIGINT, self.terminate)

        env = os.environ.copy()
        env["PG_CCSS_PATCH_SIZE"] = str(self.args.patch_size)
        env["PG_CCSS_SIGNAL_MODE"] = self.args.signal_mode
        env["PG_CCSS_MAX_LUMA"] = str(self.args.max_luma)
        env.setdefault("PG_CCSS_SETTLE_SEC", "0.8")

        ccxxmake_bin = self.args.ccxxmake_bin or env.get("PG_CCSS_CCXXMAKE_BIN") or "ccxxmake"
        if os.path.sep in ccxxmake_bin and not os.access(ccxxmake_bin, os.X_OK):
            return self.fail("Failed to launch ccxxmake", "%s is not executable" % ccxxmake_bin)

        cmd = [
            ccxxmake_bin,
            # PGenerator is headless and drives the TV via the -C patch command
            # (POST /api/pattern), so ccxxmake must not try to open an X11
            # display. "dummy" is Argyll's invisible no-op display.
            "-d",
            "dummy",
            "-S",
            "-t",
            self.args.disptech,
            "-C",
            self.args.patch_cmd,
            "-I",
            self.args.display_name,
            "-E",
            self.args.display_name,
        ]
        comport = re.sub(r"[^0-9]", "", str(self.args.comport or ""))
        if comport:
            cmd.extend(["-c", comport])
        if self.args.refresh_rate:
            cmd.extend(["-Y", "R:%s" % self.args.refresh_rate])
        cmd.append(self.args.output_path)
        self.append_log("Command: %s\n" % " ".join([utf8_text(part) for part in cmd]))

        master_fd, slave_fd = pty.openpty()
        self.master_fd = master_fd
        try:
            self.child = subprocess.Popen(
                cmd,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                env=env,
                close_fds=True,
            )
        except Exception as exc:
            os.close(slave_fd)
            return self.fail("Failed to launch ccxxmake", str(exc))
        os.close(slave_fd)

        window = ""
        while True:
            if self.cancel_requested:
                break
            ready, _, _ = select.select([master_fd], [], [], 0.25)
            if master_fd in ready:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if self.child and self.child.poll() is not None:
                        break
                    return self.fail("ccxxmake I/O failed", str(exc))
                if not chunk:
                    break
                text = sanitize(chunk.decode("utf-8", errors="ignore"))
                self.append_log(text)
                self.line_buffer += text
                window = (window + text)[-4000:]
                while "\n" in self.line_buffer:
                    line, self.line_buffer = self.line_buffer.split("\n", 1)
                    self.handle_line(line)
                self.maybe_advance_menu(window)
            if self.child.poll() is not None and master_fd not in ready:
                break

        try:
            returncode = 0 if self.child is None else self._wait_for_exit(2.0)
        except Exception:
            returncode = self.child.poll() if self.child else 1
        if self.cancel_requested:
            return 1
        if returncode == 0 and os.path.isfile(self.args.output_path):
            self.write_state("complete", "CCSS profile created", filename=os.path.basename(self.args.output_path))
            return 0

        detail = self.last_message or "ccxxmake failed to create a CCSS profile"
        if os.path.isfile(self.args.log_file):
            try:
                with io.open(self.args.log_file, "r", encoding="utf-8", errors="ignore") as handle:
                    lines = [line.strip() for line in handle.readlines() if line.strip()]
                if lines:
                    detail = lines[-1]
            except Exception:
                pass
        if returncode not in (None, 0):
            detail = "ccxxmake exited with status %s: %s" % (returncode, detail)
        self.write_state("error", detail)
        return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--patch-cmd", required=True)
    parser.add_argument("--output-path", required=True)
    parser.add_argument("--disptech", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--signal-mode", default="sdr")
    parser.add_argument("--max-luma", default="1000")
    parser.add_argument("--patch-size", default="18")
    parser.add_argument("--refresh-rate", default="")
    parser.add_argument("--ccxxmake-bin", default="")
    parser.add_argument("--comport", default="")
    args = parser.parse_args()

    runner = Runner(args)
    try:
        return runner.run()
    except Exception as exc:
        runner.append_log(traceback.format_exc())
        runner.write_state("error", "CCSS create helper crashed", detail=utf8_text(exc))
        return 1
    finally:
        try:
            os.unlink(args.pid_file)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
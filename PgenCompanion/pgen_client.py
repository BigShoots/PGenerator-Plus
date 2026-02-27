"""
PGenerator protocol client — thin wrapper around the TCP command interface.

All commands are sent as ``<cmd>\\x02\\r`` and replies end with ``\\x02\\r``.
The Calman port (2100) uses ``\\x03`` framing and ``\\x06`` ACKs instead.
"""

import socket
import time
import base64
import threading

# PGenerator framing constants
_END = b"\x02\r"
_CALMAN_END = b"\x03"
_ACK = b"\x06"

DISCOVERY_PORT = 1977
DISCOVERY_MSG = b"Who is a PGenerator"
DISCOVERY_REPLY = b"I am a PGenerator"

DEFAULT_PORT = 85


class PGenClient:
    """Blocking TCP client for PGenerator daemon (port 85)."""

    def __init__(self, host: str, port: int = DEFAULT_PORT, timeout: float = 5.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------
    def connect(self) -> None:
        self.close()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect((self.host, self.port))
        self._sock = s

    def close(self) -> None:
        if self._sock:
            try:
                self._sock.sendall(b"QUIT" + _END)
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    # ------------------------------------------------------------------
    # Low-level
    # ------------------------------------------------------------------
    def _send(self, cmd: str) -> str:
        """Send *cmd* and read the response up to *_END*."""
        with self._lock:
            if not self._sock:
                raise ConnectionError("Not connected")
            self._sock.sendall(cmd.encode() + _END)
            return self._recv()

    def _recv(self) -> str:
        buf = b""
        while True:
            try:
                chunk = self._sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if buf.endswith(_END):
                break
        return buf.rstrip(b"\x02\r").decode(errors="replace")

    # ------------------------------------------------------------------
    # High-level helpers — match DeviceControl command set
    # ------------------------------------------------------------------
    def is_alive(self) -> bool:
        try:
            return self._send("IS_ALIVE") == "ALIVE"
        except Exception:
            return False

    def cmd(self, command: str) -> str:
        """Send CMD:<command> and return the response after 'OK:'."""
        resp = self._send(f"CMD:{command}")
        if resp.startswith("OK:"):
            return resp[3:]
        return resp

    def cmd_multiple(self, *commands: str) -> dict[str, str]:
        """Send CMD:MULTIPLE:... and return {cmd: value} dict."""
        joined = ":".join(commands)
        raw = self._send(f"CMD:MULTIPLE:{joined}")
        result: dict[str, str] = {}
        for line in raw.split("\n"):
            line = line.strip()
            if not line or line.startswith("OK"):
                continue
            parts = line.split(":", 1)
            if len(parts) == 2:
                result[parts[0]] = parts[1]
        return result

    def set_conf(self, key: str, value: str) -> str:
        """SET_PGENERATOR_CONF_<KEY>:<value> — updates PGenerator.conf live."""
        return self.cmd(f"SET_PGENERATOR_CONF_{key.upper()}:{value}")

    def get_conf(self, key: str) -> str:
        return self.cmd(f"GET_PGENERATOR_CONF_{key.upper()}")

    def get_conf_all(self) -> dict[str, str]:
        raw = self.cmd("GET_PGENERATOR_CONF_ALL")
        try:
            decoded = base64.b64decode(raw).decode()
        except Exception:
            decoded = raw
        result: dict[str, str] = {}
        for line in decoded.split("\n"):
            line = line.strip()
            if not line:
                continue
            parts = line.split(":", 1)
            if len(parts) == 2:
                result[parts[0]] = parts[1]
        return result

    def get_edid(self) -> str:
        raw = self.cmd("GET_EDID_INFO")
        try:
            return base64.b64decode(raw).decode()
        except Exception:
            return raw

    def get_version(self) -> str:
        return self.cmd("GET_PGENERATOR_VERSION")

    def get_temperature(self) -> str:
        return self.cmd("GET_TEMPERATURE")

    def get_resolution(self) -> str:
        return self.cmd("GET_RESOLUTION")

    def get_hdmi_info(self) -> str:
        return self.cmd("GET_HDMI_INFO")

    def get_hostname(self) -> str:
        return self.cmd("GET_HOSTNAME")

    def set_hostname(self, name: str) -> str:
        return self.cmd(f"SET_HOSTNAME:{name}")

    def get_device_model(self) -> str:
        return self.cmd("GET_DEVICE_MODEL")

    def restart_pgenerator(self) -> str:
        return self._send("RESTARTPGENERATOR:")

    def reboot(self) -> str:
        return self.cmd("REBOOT")

    def shutdown(self) -> str:
        return self.cmd("HALT")

    def set_resolution(self, mode_idx: str) -> str:
        return self.cmd(f"SET_MODE:{mode_idx}")

    def set_refresh(self, cea_mode: str) -> str:
        return self.cmd(f"SET_REFRESH:{cea_mode}")

    def set_output_range(self, value: str) -> str:
        """value: 1=RGB limited, 2=RGB full"""
        return self.cmd(f"SET_OUTPUT_RANGE:{value}")

    def set_gpu_memory(self, value: str) -> str:
        return self.cmd(f"SET_GPU_MEMORY:{value}")

    # Pattern commands
    def send_rgb(self, draw: str, dim: str, res: str, rgb: str,
                 bg: str = "", pos: str = "", text: str = "") -> str:
        return self._send(f"RGB={draw};{dim};{res};{rgb};{bg};{pos};{text}")

    def test_pattern(self, name: str, draw: str, dim: str, res: str,
                     rgb: str) -> str:
        return self._send(f"TESTPATTERN:{name}:{draw}:{dim}:{res}:{rgb}:")

    # Discovery
    @staticmethod
    def discover(timeout: float = 3.0) -> list[str]:
        """Broadcast UDP discovery — returns list of IPs that respond."""
        found: list[str] = []
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM,
                             socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(timeout)
        sock.bind(("", 0))
        try:
            sock.sendto(DISCOVERY_MSG,
                        ("<broadcast>", DISCOVERY_PORT))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    data, addr = sock.recvfrom(256)
                    if DISCOVERY_REPLY in data:
                        found.append(addr[0])
                except socket.timeout:
                    break
        finally:
            sock.close()
        return found

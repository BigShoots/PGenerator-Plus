#!/usr/bin/env python3
"""Local-only PGenerator source/Pi comparison and deployment server."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import secrets
import shlex
import subprocess
import tarfile
import tempfile
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from typing import Any


APP_DIR = Path(__file__).resolve().parent
REPO_ROOT = APP_DIR.parent
STATIC_DIR = APP_DIR / "static"
DEPLOY_ROOTS = ("etc", "lib", "usr", "var")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")
IDLE_PATTERN = r"[m]eter_|[s]potread|[c]hartread|[c]olprof"
RENDERER_PATTERN = r"[P]Generatord(\.dv)?([[:space:]]|$)"
MAX_BODY = 2 * 1024 * 1024
KNOWN_HOSTS = "/tmp/pgen-deployer-known-hosts"


class AppError(Exception):
    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST):
        super().__init__(message)
        self.status = status


def run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    timeout: int = 45,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            cwd=REPO_ROOT,
            env=env,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise AppError(f"Required command is not installed: {args[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise AppError(f"Command timed out after {timeout} seconds", HTTPStatus.GATEWAY_TIMEOUT) from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        if "Permission denied" in detail:
            detail = "SSH authentication failed"
        raise AppError(detail or f"{args[0]} exited with status {result.returncode}", HTTPStatus.BAD_GATEWAY)
    return result


def connection_from(payload: dict[str, Any]) -> dict[str, str]:
    host = str(payload.get("host", "")).strip()
    user = str(payload.get("user", "root")).strip()
    password = str(payload.get("password", ""))
    if not HOST_RE.fullmatch(host) or host.startswith("-"):
        raise AppError("Enter a valid IP address or hostname.")
    if not USER_RE.fullmatch(user):
        raise AppError("Enter a valid SSH username.")
    return {"host": host, "user": user, "password": password}


def ssh_base(connection: dict[str, str], command: str = "ssh") -> tuple[list[str], dict[str, str]]:
    env = os.environ.copy()
    args: list[str] = []
    if connection["password"]:
        env["SSHPASS"] = connection["password"]
        args.extend(["sshpass", "-e"])
    args.extend(
        [
            command,
            "-o",
            "BatchMode=no" if connection["password"] else "BatchMode=yes",
            "-o",
            "ConnectTimeout=7",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            f"UserKnownHostsFile={KNOWN_HOSTS}",
        ]
    )
    return args, env


def ssh(
    connection: dict[str, str],
    remote_command: str,
    *,
    input_text: str | None = None,
    timeout: int = 45,
) -> str:
    args, env = ssh_base(connection)
    args.extend(["-T", f"{connection['user']}@{connection['host']}", remote_command])
    return run(args, env=env, input_text=input_text, timeout=timeout).stdout


def tracked_deployable_files() -> list[str]:
    result = run(["git", "ls-files", "-z"], timeout=10)
    files: list[str] = []
    for raw in result.stdout.split("\0"):
        if not raw:
            continue
        path = PurePosixPath(raw)
        if (
            path.parts
            and path.parts[0] in DEPLOY_ROOTS
            and len(path.parts) > 1
            and (REPO_ROOT / raw).is_file()
            and not (REPO_ROOT / raw).is_symlink()
        ):
            files.append(raw)
    return sorted(files)


def validate_selected(paths: Any) -> list[str]:
    if not isinstance(paths, list) or not paths:
        raise AppError("Select at least one file.")
    allowed = set(tracked_deployable_files())
    selected: list[str] = []
    for value in paths:
        path = str(value)
        if path not in allowed:
            raise AppError(f"File is not a deployable tracked source file: {path}")
        if path not in selected:
            selected.append(path)
    return selected


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def remote_file_state(connection: dict[str, str], paths: list[str]) -> dict[str, dict[str, Any]]:
    command = r"""
while IFS= read -r rel; do
  target="/$rel"
  if [ -f "$target" ]; then
    set -- $(sha256sum "$target" 2>/dev/null)
    hash="$1"
    mode=$(stat -c %a "$target" 2>/dev/null || echo "?")
    size=$(wc -c < "$target" 2>/dev/null || echo "0")
    printf '%s\t%s\t%s\t%s\n' "$hash" "$mode" "$size" "$rel"
  else
    printf 'MISSING\t-\t0\t%s\n' "$rel"
  fi
done
""".strip()
    output = ssh(connection, command, input_text="\n".join(paths) + "\n", timeout=120)
    states: dict[str, dict[str, Any]] = {}
    for line in output.splitlines():
        parts = line.split("\t", 3)
        if len(parts) != 4:
            continue
        remote_hash, mode, size, path = parts
        states[path] = {
            "hash": None if remote_hash == "MISSING" else remote_hash,
            "mode": mode,
            "size": int(size.strip() or "0"),
        }
    return states


def scan_files(connection: dict[str, str]) -> dict[str, Any]:
    paths = tracked_deployable_files()
    if not paths:
        raise AppError("No tracked deployable files were found in this repository.")
    remote = remote_file_state(connection, paths)
    entries: list[dict[str, Any]] = []
    counts = {"different": 0, "missing": 0, "same": 0}
    for rel in paths:
        local_path = REPO_ROOT / rel
        local_hash = digest(local_path)
        local_mode = f"{local_path.stat().st_mode & 0o777:o}"
        remote_state = remote.get(rel, {"hash": None, "mode": "-", "size": 0})
        if remote_state["hash"] is None:
            status = "missing"
        elif remote_state["hash"] != local_hash or remote_state["mode"] != local_mode:
            status = "different"
        else:
            status = "same"
        counts[status] += 1
        entries.append(
            {
                "path": rel,
                "status": status,
                "localSize": local_path.stat().st_size,
                "remoteSize": remote_state["size"],
                "localMode": local_mode,
                "remoteMode": remote_state["mode"],
                "sensitive": rel.startswith(("etc/PGenerator/", "var/lib/PGenerator/")),
            }
        )
    busy = remote_busy_state(connection)
    return {"files": entries, "counts": counts, "total": len(entries), "busy": busy}


def remote_busy_state(connection: dict[str, str]) -> dict[str, Any]:
    command = (
        f"busy=$(ps w 2>/dev/null | grep -E {shlex.quote(IDLE_PATTERN)} || true); "
        f"renderer=$(ps w 2>/dev/null | grep -E {shlex.quote(RENDERER_PATTERN)} || true); "
        "printf '%s\\n--RENDERER--\\n%s\\n' \"$busy\" \"$renderer\""
    )
    output = ssh(connection, command, timeout=12)
    busy_text, _, renderer_text = output.partition("\n--RENDERER--\n")
    return {
        "idle": not bool(busy_text.strip()),
        "activity": busy_text.strip(),
        "rendererRunning": bool(renderer_text.strip()),
    }


def require_idle(connection: dict[str, str]) -> dict[str, Any]:
    state = remote_busy_state(connection)
    if not state["idle"]:
        raise AppError(
            "The Pi has an active calibration or meter process. Stop it before uploading or restarting.\n"
            + state["activity"],
            HTTPStatus.CONFLICT,
        )
    return state


def perl_syntax_checks(paths: list[str]) -> list[str]:
    checked: list[str] = []
    for rel in paths:
        path = REPO_ROOT / rel
        first_line = path.open("rb").readline(256).lower()
        if path.suffix in {".pl", ".pm"} or (first_line.startswith(b"#!") and b"perl" in first_line):
            run(["perl", "-c", rel], timeout=30)
            checked.append(rel)
    return checked


def upload_files(connection: dict[str, str], paths: list[str]) -> dict[str, Any]:
    require_idle(connection)
    checked = perl_syntax_checks(paths)
    token = secrets.token_hex(8)
    timestamp = f"{time.strftime('%Y%m%d-%H%M%S')}-{token[:6]}"
    remote_stage = f"/tmp/pgen-deployer-{token}"
    remote_archive = f"{remote_stage}.tar"

    with tempfile.NamedTemporaryFile(prefix="pgen-deployer-", suffix=".tar") as archive_file:
        with tarfile.open(fileobj=archive_file, mode="w") as archive:
            for index, rel in enumerate(paths):
                archive.add(REPO_ROOT / rel, arcname=f"payload/{index:04d}", recursive=False)
        archive_file.flush()
        args, env = ssh_base(connection, "scp")
        args.extend(
            [
                "-p",
                archive_file.name,
                f"{connection['user']}@{connection['host']}:{remote_archive}",
            ]
        )
        run(args, env=env, timeout=180)

    manifest_lines = []
    for index, rel in enumerate(paths):
        mode = f"{(REPO_ROOT / rel).stat().st_mode & 0o777:o}"
        manifest_lines.append(f"{index:04d}\t{mode}\t{rel}")
    manifest = "\n".join(manifest_lines) + "\n"
    command = f"""
set -e
stage={shlex.quote(remote_stage)}
archive={shlex.quote(remote_archive)}
backup={shlex.quote(f"/root/pgen-backups/{timestamp}")}
mkdir -p "$stage" "$backup"
tar -xf "$archive" -C "$stage"
while IFS="$(printf '\\t')" read -r idx mode rel; do
  target="/$rel"
  parent=$(dirname "$target")
  mkdir -p "$parent"
  if [ -e "$target" ]; then
    saved="$backup/$rel"
    mkdir -p "$(dirname "$saved")"
    cp -a "$target" "$saved"
  fi
  replacement="$target.pgen-new"
  cp "$stage/payload/$idx" "$replacement"
  chmod "$mode" "$replacement"
  if [ -e "$target" ]; then
    chown --reference="$target" "$replacement" 2>/dev/null || true
  fi
  mv "$replacement" "$target"
done
rm -rf "$stage"
rm -f "$archive"
printf '%s\\n' "$backup"
""".strip()
    try:
        output = ssh(connection, command, input_text=manifest, timeout=180)
    except AppError:
        try:
            ssh(connection, f"rm -f {shlex.quote(remote_archive)}", timeout=10)
        except AppError:
            pass
        raise
    backup = output.strip().splitlines()[-1] if output.strip() else f"/root/pgen-backups/{timestamp}"
    return {"uploaded": paths, "backup": backup, "syntaxChecked": checked}


def restart_renderer(connection: dict[str, str]) -> dict[str, Any]:
    require_idle(connection)
    command = r"""
response=$(wget -q -O - http://127.0.0.1/api/restart 2>/dev/null || true)
i=0
while [ "$i" -lt 20 ]; do
  if ps w 2>/dev/null | grep -Eq '[P]Generatord(\.dv)?([[:space:]]|$)'; then
    printf '%s\n' "$response"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done
echo "Renderer did not return within 20 seconds" >&2
exit 1
""".strip()
    output = ssh(connection, command, timeout=30)
    return {"restarted": True, "message": output.strip() or "Pattern renderer restarted."}


class Handler(BaseHTTPRequestHandler):
    server_version = "PGeneratorLocalDeployer/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def send_json(self, value: Any, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise AppError("Invalid request length.") from exc
        if length <= 0 or length > MAX_BODY:
            raise AppError("Invalid request body.")
        try:
            value = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            raise AppError("Invalid JSON request.") from exc
        if not isinstance(value, dict):
            raise AppError("Request must be a JSON object.")
        return value

    def do_GET(self) -> None:
        if self.path == "/api/health":
            self.send_json({"ok": True, "repo": str(REPO_ROOT)})
            return
        path = "index.html" if self.path in {"/", ""} else self.path.lstrip("/")
        file_path = (STATIC_DIR / path).resolve()
        if STATIC_DIR not in file_path.parents or not file_path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content = file_path.read_bytes()
        content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self) -> None:
        try:
            payload = self.read_json()
            connection = connection_from(payload)
            if self.path == "/api/scan":
                result = scan_files(connection)
            elif self.path == "/api/upload":
                result = upload_files(connection, validate_selected(payload.get("paths")))
            elif self.path == "/api/restart":
                result = restart_renderer(connection)
            elif self.path == "/api/status":
                result = remote_busy_state(connection)
            else:
                raise AppError("Unknown endpoint.", HTTPStatus.NOT_FOUND)
            self.send_json({"ok": True, **result})
        except AppError as exc:
            self.send_json({"ok": False, "error": str(exc)}, exc.status)
        except Exception as exc:
            self.send_json({"ok": False, "error": f"Unexpected server error: {exc}"}, HTTPStatus.INTERNAL_SERVER_ERROR)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local PGenerator deployment dashboard.")
    parser.add_argument("--port", type=int, default=8765, help="local port (default: 8765)")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser automatically")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}"
    print(f"PGenerator deployer: {url}")
    print(f"Repository: {REPO_ROOT}")
    if not args.no_open:
        import webbrowser

        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

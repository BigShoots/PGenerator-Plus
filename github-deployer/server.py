#!/usr/bin/env python3
"""Local PGenerator deployment console backed by a pinned GitHub snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from typing import Any

try:
    import paramiko
except ImportError:
    paramiko = None


APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
# Shown in the dashboard and reported by /api/health so a support thread can
# establish which console someone is running. Bump when behaviour changes.
DEPLOYER_BUILD = "1.1"
# The console's own files as they appear in the repository snapshot. They are
# not deployable, but they are extracted alongside the snapshot so the running
# console can notice that the repository carries a different version of itself:
# builds before 2026-08-09 syntax-checked Perl on the desktop instead of on the
# Pi, and a stale copy kept producing misleading missing-module errors.
DEPLOYER_SELF_FILES = (
    "github-deployer/server.py",
    "github-deployer/static/app.js",
    "github-deployer/static/index.html",
)
PID_FILE = APP_DIR / ".server.pid"
DEPLOY_ROOTS = ("etc", "lib", "usr", "var")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")
REPO_PART_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
REF_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ID_RE = re.compile(r"^[0-9a-f]{24}$")
RENDERER_PATTERN = r"[P]Generatord(\.dv)?([[:space:]]|$)"
DAEMON_PATTERN = r"[P]Generatord\.pl"
PS_COMMAND = "ps -e w"
KNOWN_HOSTS = str(Path(tempfile.gettempdir()) / "pgen-github-deployer-known-hosts")
CACHE_ROOT = Path(tempfile.gettempdir()) / "pgenerator-github-deployer"
MAX_BODY = 2 * 1024 * 1024
MAX_ARCHIVE = 1024 * 1024 * 1024
MAX_EXTRACTED = 2 * 1024 * 1024 * 1024
SNAPSHOT_TTL = 2 * 60 * 60
GITHUB_API = "https://api.github.com"
PROTECTED_PATHS = {
    "etc/BiasiLinux/BiasiLinux.FirstBoot": "First-boot marker",
    "etc/PGenerator/PGenerator.conf": "Device-specific runtime configuration",
    "var/lib/PGenerator/operations.txt": "Runtime command-file symlink",
    "var/lib/PGenerator/running/tmp/.gitkeep": "Repository-only directory placeholder",
}

SNAPSHOTS: dict[str, dict[str, Any]] = {}
SNAPSHOT_LOCK = threading.Lock()


class AppError(Exception):
    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST):
        super().__init__(message)
        self.status = status


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    timeout: int = 45,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            cwd=cwd or APP_DIR,
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
        raise AppError("Enter a valid Pi IP address or hostname.")
    if not USER_RE.fullmatch(user):
        raise AppError("Enter a valid SSH username.")
    return {"host": host, "user": user, "password": password}


def github_source_from(payload: dict[str, Any]) -> dict[str, str]:
    raw_repo = str(payload.get("repository", "")).strip()
    ref = str(payload.get("ref", "main")).strip()
    token = str(payload.get("githubToken", "")).strip()
    repo = raw_repo
    for prefix in ("https://github.com/", "http://github.com/", "github.com/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix) :]
            break
    repo = repo.rstrip("/")
    if repo.endswith(".git"):
        repo = repo[:-4]
    parts = repo.split("/")
    if len(parts) != 2 or not all(REPO_PART_RE.fullmatch(part) for part in parts):
        raise AppError("Enter a GitHub repository as owner/repository or a github.com URL.")
    if (
        not REF_RE.fullmatch(ref)
        or ".." in ref
        or ref.startswith(("-", "/", "."))
        or ref.endswith(("/", ".lock"))
    ):
        raise AppError("Enter a valid GitHub branch, tag, or commit.")
    return {"owner": parts[0], "repo": parts[1], "repository": "/".join(parts), "ref": ref, "token": token}


def ssh_base(connection: dict[str, str], command: str = "ssh") -> tuple[list[str], dict[str, str]]:
    env = os.environ.copy()
    # Never let ssh reach for a graphical passphrase prompt. Without this it
    # falls back to SSH_ASKPASS whenever it cannot authenticate on the current
    # attempt, which on a KDE desktop raises a ksshaskpass dialog even though
    # the deployer already holds the password. Clearing DISPLAY as well covers
    # ssh builds that consult it before SSH_ASKPASS_REQUIRE.
    env["SSH_ASKPASS_REQUIRE"] = "never"
    env.pop("SSH_ASKPASS", None)
    env.pop("DISPLAY", None)
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
    if connection["password"]:
        # Go straight to password auth so sshpass answers the first prompt.
        # KbdInteractiveAuthentication remains enabled because this image may
        # need it for password authentication.
        args.extend(
            [
                "-o",
                "PreferredAuthentications=password",
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "NumberOfPasswordPrompts=1",
            ]
        )
    return args, env


def use_paramiko(connection: dict[str, str]) -> bool:
    if os.name == "nt":
        return True
    return bool(connection["password"] and shutil.which("sshpass") is None and paramiko is not None)


def paramiko_client(connection: dict[str, str], timeout: int):
    if paramiko is None:
        raise AppError(
            "Windows SSH support is not installed. Close the server and run run-windows.bat again."
        )
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=connection["host"],
            username=connection["user"],
            password=connection["password"] or None,
            timeout=min(timeout, 15),
            banner_timeout=min(timeout, 15),
            auth_timeout=min(timeout, 15),
            look_for_keys=not bool(connection["password"]),
            allow_agent=not bool(connection["password"]),
        )
    except paramiko.AuthenticationException as exc:
        client.close()
        raise AppError("SSH authentication failed", HTTPStatus.BAD_GATEWAY) from exc
    except (paramiko.SSHException, OSError, socket.timeout) as exc:
        client.close()
        raise AppError(f"Could not connect to the Pi over SSH: {exc}", HTTPStatus.BAD_GATEWAY) from exc
    return client


def paramiko_ssh(
    connection: dict[str, str],
    remote_command: str,
    *,
    input_text: str | None = None,
    timeout: int = 45,
) -> str:
    client = paramiko_client(connection, timeout)
    try:
        stdin, stdout, stderr = client.exec_command(remote_command, timeout=timeout)
        if input_text is not None:
            stdin.write(input_text)
            stdin.flush()
        stdin.channel.shutdown_write()
        output = stdout.read().decode("utf-8", errors="replace")
        error = stderr.read().decode("utf-8", errors="replace")
        status = stdout.channel.recv_exit_status()
    except socket.timeout as exc:
        raise AppError(f"SSH command timed out after {timeout} seconds", HTTPStatus.GATEWAY_TIMEOUT) from exc
    except (OSError, paramiko.SSHException) as exc:
        raise AppError(f"SSH command failed: {exc}", HTTPStatus.BAD_GATEWAY) from exc
    finally:
        client.close()
    if status:
        detail = (error or output).strip()
        raise AppError(detail or f"Remote command exited with status {status}", HTTPStatus.BAD_GATEWAY)
    return output


def ssh(
    connection: dict[str, str],
    remote_command: str,
    *,
    input_text: str | None = None,
    timeout: int = 45,
) -> str:
    if use_paramiko(connection):
        return paramiko_ssh(connection, remote_command, input_text=input_text, timeout=timeout)
    args, env = ssh_base(connection)
    args.extend(["-T", f"{connection['user']}@{connection['host']}", remote_command])
    return run(args, env=env, input_text=input_text, timeout=timeout).stdout


def upload_remote_file(
    connection: dict[str, str],
    local_path: Path,
    remote_path: str,
    *,
    timeout: int = 300,
) -> None:
    if use_paramiko(connection):
        client = paramiko_client(connection, timeout)
        try:
            sftp = client.open_sftp()
            try:
                sftp.get_channel().settimeout(timeout)
                sftp.put(str(local_path), remote_path)
            finally:
                sftp.close()
        except socket.timeout as exc:
            raise AppError(f"SFTP upload timed out after {timeout} seconds", HTTPStatus.GATEWAY_TIMEOUT) from exc
        except (OSError, paramiko.SSHException) as exc:
            raise AppError(f"SFTP upload failed: {exc}", HTTPStatus.BAD_GATEWAY) from exc
        finally:
            client.close()
        return
    args, env = ssh_base(connection, "scp")
    args.extend(["-p", str(local_path), f"{connection['user']}@{connection['host']}:{remote_path}"])
    run(args, env=env, timeout=timeout)


def github_headers(token: str, accept: str = "application/vnd.github+json") -> dict[str, str]:
    headers = {
        "Accept": accept,
        "User-Agent": "PGenerator-GitHub-Deployer",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_open(url: str, token: str, accept: str = "application/vnd.github+json", timeout: int = 45):
    request = urllib.request.Request(url, headers=github_headers(token, accept))
    try:
        return urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            message = "GitHub rejected the token."
        elif exc.code == 403:
            message = "GitHub denied the request or the API rate limit was reached. Add a token and try again."
        elif exc.code == 404:
            message = "GitHub repository or requested branch/tag was not found."
        else:
            message = f"GitHub returned HTTP {exc.code}."
        raise AppError(message, HTTPStatus.BAD_GATEWAY) from exc
    except urllib.error.URLError as exc:
        raise AppError(f"Could not reach GitHub: {exc.reason}", HTTPStatus.BAD_GATEWAY) from exc


def github_commit(source: dict[str, str]) -> dict[str, str]:
    owner = urllib.parse.quote(source["owner"], safe="")
    repo = urllib.parse.quote(source["repo"], safe="")
    ref = urllib.parse.quote(source["ref"], safe="")
    url = f"{GITHUB_API}/repos/{owner}/{repo}/commits/{ref}"
    with github_open(url, source["token"]) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise AppError("GitHub commit response was unexpectedly large.", HTTPStatus.BAD_GATEWAY)
    try:
        data = json.loads(raw)
        sha = str(data["sha"]).lower()
        commit = data["commit"]
        date = str((commit.get("committer") or commit.get("author") or {}).get("date", ""))
        message = str(commit.get("message", "")).splitlines()[0][:200]
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise AppError("GitHub returned an invalid commit response.", HTTPStatus.BAD_GATEWAY) from exc
    if not SHA_RE.fullmatch(sha):
        raise AppError("GitHub returned an invalid commit identifier.", HTTPStatus.BAD_GATEWAY)
    return {"sha": sha, "date": date, "message": message}


def cleanup_snapshots() -> None:
    cutoff = time.time() - SNAPSHOT_TTL
    stale: list[dict[str, Any]] = []
    with SNAPSHOT_LOCK:
        for snapshot_id, snapshot in list(SNAPSHOTS.items()):
            if snapshot["created"] < cutoff:
                stale.append(SNAPSHOTS.pop(snapshot_id))
        active_roots = {Path(snapshot["root"]) for snapshot in SNAPSHOTS.values()}
    for snapshot in stale:
        shutil.rmtree(snapshot["root"], ignore_errors=True)
    if CACHE_ROOT.is_dir():
        for path in CACHE_ROOT.iterdir():
            try:
                is_stale = path.is_dir() and ID_RE.fullmatch(path.name) and path.stat().st_mtime < cutoff
            except OSError:
                continue
            if is_stale and path not in active_roots:
                shutil.rmtree(path, ignore_errors=True)


def snapshot_mtime(commit_date: str) -> int:
    try:
        return int(datetime.fromisoformat(commit_date.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def create_snapshot(source: dict[str, str]) -> dict[str, Any]:
    cleanup_snapshots()
    commit = github_commit(source)
    owner = urllib.parse.quote(source["owner"], safe="")
    repo = urllib.parse.quote(source["repo"], safe="")
    url = f"{GITHUB_API}/repos/{owner}/{repo}/tarball/{commit['sha']}"
    snapshot_id = secrets.token_hex(12)
    root = CACHE_ROOT / snapshot_id
    root.mkdir(parents=True, exist_ok=False)
    files: dict[str, dict[str, Any]] = {}
    extracted_size = 0
    default_mtime = snapshot_mtime(commit["date"])

    try:
        with tempfile.NamedTemporaryFile(prefix="pgen-github-", suffix=".tar.gz") as archive_file:
            with github_open(url, source["token"], "application/vnd.github+json", timeout=120) as response:
                try:
                    content_length = int(response.headers.get("Content-Length", "0") or "0")
                except ValueError:
                    content_length = 0
                if content_length > MAX_ARCHIVE:
                    raise AppError("GitHub archive exceeds the 1 GB safety limit.")
                downloaded = 0
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    downloaded += len(block)
                    if downloaded > MAX_ARCHIVE:
                        raise AppError("GitHub archive exceeds the 1 GB safety limit.")
                    archive_file.write(block)
            archive_file.flush()
            archive_file.seek(0)
            try:
                archive = tarfile.open(fileobj=archive_file, mode="r:gz")
            except tarfile.TarError as exc:
                raise AppError("GitHub returned an invalid source archive.", HTTPStatus.BAD_GATEWAY) from exc
            with archive:
                for member in archive:
                    if not member.isfile():
                        continue
                    parts = PurePosixPath(member.name).parts
                    if len(parts) < 3:
                        continue
                    relative = PurePosixPath(*parts[1:])
                    if relative.is_absolute() or ".." in relative.parts:
                        continue
                    if relative.as_posix() in DEPLOYER_SELF_FILES:
                        # Kept beside the deployable tree, never in `files`, purely
                        # so the running console can compare itself against it.
                        source_file = archive.extractfile(member)
                        if source_file is not None:
                            target = root / "_deployer" / relative.as_posix()
                            target.parent.mkdir(parents=True, exist_ok=True)
                            with source_file, target.open("wb") as output:
                                shutil.copyfileobj(source_file, output, length=1024 * 1024)
                        continue
                    if relative.parts[0] not in DEPLOY_ROOTS or len(relative.parts) < 2:
                        continue
                    rel = relative.as_posix()
                    if any(character in rel for character in ("\n", "\r", "\t", "\0")):
                        continue
                    extracted_size += member.size
                    if extracted_size > MAX_EXTRACTED:
                        raise AppError("Deployable GitHub files exceed the 2 GB safety limit.")
                    source_file = archive.extractfile(member)
                    if source_file is None:
                        continue
                    target = root / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source_file, target.open("wb") as output:
                        shutil.copyfileobj(source_file, output, length=1024 * 1024)
                    mode = member.mode & 0o777
                    if not mode:
                        mode = 0o644
                    target.chmod(mode)
                    files[rel] = {
                        "mode": f"{mode:o}",
                        "size": member.size,
                        "modified": int(member.mtime or default_mtime),
                    }
        if not files:
            raise AppError("No deployable files were found in the GitHub snapshot.")
        deployer_outdated = False
        for rel in DEPLOYER_SELF_FILES:
            in_snapshot = root / "_deployer" / rel
            running = APP_DIR / PurePosixPath(rel).relative_to("github-deployer")
            if in_snapshot.is_file() and running.is_file() and digest(in_snapshot) != digest(running):
                deployer_outdated = True
                break
        snapshot = {
            "id": snapshot_id,
            "root": root,
            "files": files,
            "created": time.time(),
            "repository": source["repository"],
            "ref": source["ref"],
            "commit": commit["sha"],
            "commitDate": commit["date"],
            "commitMessage": commit["message"],
            "deployerOutdated": deployer_outdated,
        }
        with SNAPSHOT_LOCK:
            SNAPSHOTS[snapshot_id] = snapshot
        return snapshot
    except Exception:
        shutil.rmtree(root, ignore_errors=True)
        raise


def get_snapshot(snapshot_id: Any) -> dict[str, Any]:
    value = str(snapshot_id or "")
    if not ID_RE.fullmatch(value):
        raise AppError("The GitHub snapshot is invalid. Scan again.")
    cleanup_snapshots()
    with SNAPSHOT_LOCK:
        snapshot = SNAPSHOTS.get(value)
    if not snapshot or not Path(snapshot["root"]).is_dir():
        raise AppError("The GitHub snapshot expired. Scan again.", HTTPStatus.GONE)
    return snapshot


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def expected_difference(path: str, status: str) -> str | None:
    if status == "same":
        return None
    if path == "etc/BiasiLinux/BiasiLinux.FirstBoot" and status == "missing":
        return "Removed after first boot"
    if path == "etc/PGenerator/PGenerator.conf":
        return "Device-specific runtime settings"
    if path == "var/lib/PGenerator/operations.txt":
        return "Runtime command-file symlink"
    if path == "var/lib/PGenerator/running/tmp/.gitkeep" and status == "missing":
        return "Repository-only directory placeholder"
    return None


def remote_file_state(connection: dict[str, str], paths: list[str]) -> dict[str, dict[str, Any]]:
    command = r"""
while IFS= read -r rel; do
  target="/$rel"
  if [ -L "$target" ]; then
    type="symlink"
    if [ -f "$target" ]; then
      set -- $(sha256sum "$target" 2>/dev/null)
      hash="$1"
      size=$(wc -c < "$target" 2>/dev/null || echo "0")
    else
      hash="SYMLINK"
      size=0
    fi
    mode=$(stat -c %a "$target" 2>/dev/null || echo "?")
    modified=$(stat -c %Y "$target" 2>/dev/null || echo "0")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$hash" "$mode" "$size" "$modified" "$type" "$rel"
  elif [ -f "$target" ]; then
    set -- $(sha256sum "$target" 2>/dev/null)
    hash="$1"
    mode=$(stat -c %a "$target" 2>/dev/null || echo "?")
    size=$(wc -c < "$target" 2>/dev/null || echo "0")
    modified=$(stat -c %Y "$target" 2>/dev/null || echo "0")
    printf '%s\t%s\t%s\t%s\tfile\t%s\n' "$hash" "$mode" "$size" "$modified" "$rel"
  else
    printf 'MISSING\t-\t0\t0\tmissing\t%s\n' "$rel"
  fi
done
""".strip()
    output = ssh(connection, command, input_text="\n".join(paths) + "\n", timeout=180)
    states: dict[str, dict[str, Any]] = {}
    for line in output.splitlines():
        parts = line.split("\t", 5)
        if len(parts) != 6:
            continue
        remote_hash, mode, size, modified, file_type, path = parts
        states[path] = {
            "hash": None if remote_hash == "MISSING" else remote_hash,
            "mode": mode,
            "size": int(size.strip() or "0"),
            "modified": int(modified.strip() or "0"),
            "type": file_type,
        }
    return states


def scan_snapshot(connection: dict[str, str], snapshot: dict[str, Any]) -> dict[str, Any]:
    paths = sorted(snapshot["files"])
    remote = remote_file_state(connection, paths)
    entries: list[dict[str, Any]] = []
    counts = {"different": 0, "missing": 0, "same": 0, "expected": 0}
    root = Path(snapshot["root"])
    for rel in paths:
        source_state = snapshot["files"][rel]
        source_hash = digest(root / rel)
        remote_state = remote.get(
            rel,
            {"hash": None, "mode": "-", "size": 0, "modified": 0, "type": "missing"},
        )
        if remote_state["hash"] is None:
            status = "missing"
        elif remote_state["hash"] != source_hash:
            status = "different"
        else:
            status = "same"
        counts[status] += 1
        expected_reason = expected_difference(rel, status)
        if expected_reason:
            counts["expected"] += 1
        entries.append(
            {
                "path": rel,
                "status": status,
                "expected": bool(expected_reason),
                "expectedReason": expected_reason,
                "protected": rel in PROTECTED_PATHS,
                "sourceSize": source_state["size"],
                "remoteSize": remote_state["size"],
                "sourceModified": source_state["modified"],
                "remoteModified": remote_state["modified"],
                "sourceMode": source_state["mode"],
                "remoteMode": remote_state["mode"],
                "remoteType": remote_state["type"],
                "sensitive": rel.startswith(("etc/PGenerator/", "var/lib/PGenerator/")),
            }
        )
    busy = remote_busy_state(connection)
    return {"files": entries, "counts": counts, "total": len(entries), "busy": busy}


def remote_busy_state(connection: dict[str, str]) -> dict[str, Any]:
    command = (
        f"procs=$({PS_COMMAND} 2>/dev/null); "
        f"renderer=$(printf '%s\\n' \"$procs\" | grep -E {shlex.quote(RENDERER_PATTERN)} || true); "
        f"daemon=$(printf '%s\\n' \"$procs\" | grep -E {shlex.quote(DAEMON_PATTERN)} || true); "
        "printf '%s\\n--DAEMON--\\n%s\\n' \"$renderer\" \"$daemon\""
    )
    output = ssh(connection, command, timeout=12)
    renderer_text, _, daemon_text = output.partition("\n--DAEMON--\n")
    return {
        "idle": True,
        "activity": "",
        "rendererRunning": bool(renderer_text.strip()),
        "daemonRunning": bool(daemon_text.strip()),
    }


def validate_selected(snapshot: dict[str, Any], paths: Any) -> list[str]:
    if not isinstance(paths, list) or not paths:
        raise AppError("Select at least one file.")
    allowed = snapshot["files"]
    selected: list[str] = []
    for value in paths:
        path = str(value)
        if path not in allowed:
            raise AppError(f"File is not part of the pinned GitHub snapshot: {path}")
        if path in PROTECTED_PATHS:
            raise AppError(f"Protected runtime file cannot be uploaded: {path}")
        if path not in selected:
            selected.append(path)
    return selected


def perl_source_paths(snapshot: dict[str, Any], paths: list[str]) -> list[str]:
    root = Path(snapshot["root"])
    perl_paths: list[str] = []
    for rel in paths:
        path = root / rel
        first_line = path.open("rb").readline(256).lower()
        if path.suffix in {".pl", ".pm"} or (first_line.startswith(b"#!") and b"perl" in first_line):
            perl_paths.append(rel)
    return perl_paths


def upload_files(connection: dict[str, str], snapshot: dict[str, Any], paths: list[str]) -> dict[str, Any]:
    checked = perl_source_paths(snapshot, paths)
    token = secrets.token_hex(8)
    timestamp = f"{time.strftime('%Y%m%d-%H%M%S')}-{token[:6]}"
    remote_stage = f"/tmp/pgen-github-deployer-{token}"
    remote_archive = f"{remote_stage}.tar"
    root = Path(snapshot["root"])

    with tempfile.TemporaryDirectory(prefix="pgen-github-upload-") as upload_dir:
        archive_path = Path(upload_dir) / "payload.tar"
        with tarfile.open(archive_path, mode="w") as archive:
            for index, rel in enumerate(paths):
                archive.add(root / rel, arcname=f"payload/{index:04d}", recursive=False)
        try:
            upload_remote_file(connection, archive_path, remote_archive, timeout=300)
        except AppError:
            try:
                ssh(connection, f"rm -f {shlex.quote(remote_archive)}", timeout=10)
            except AppError:
                pass
            raise

    manifest_lines = [
        f"{index:04d}\t{snapshot['files'][rel]['mode']}\t{'perl' if rel in checked else '-'}\t{rel}"
        for index, rel in enumerate(paths)
    ]
    manifest = "\n".join(manifest_lines) + "\n"
    command = f"""
set -e
stage={shlex.quote(remote_stage)}
archive={shlex.quote(remote_archive)}
backup={shlex.quote(f"/root/pgen-backups/{timestamp}-github")}
mkdir -p "$stage" "$backup"
tar -xf "$archive" -C "$stage"
manifest="$stage/manifest"
cat > "$manifest"
while IFS="$(printf '\\t')" read -r idx mode check rel; do
  target="/$rel"
  if [ -L "$target" ]; then
    echo "Refusing to replace symbolic link: $target" >&2
    exit 4
  fi
done < "$manifest"
while IFS="$(printf '\\t')" read -r idx mode check rel; do
  if [ "$check" = "perl" ]; then
    if ! perl -c "$stage/payload/$idx"; then
      echo "Syntax check of $rel failed on the target device $(hostname 2>/dev/null) running Perl $(perl -e 'print $^V' 2>/dev/null). Every PGenerator+ image ships the modules the runtime needs, so a missing-module failure usually means the Host field points at a machine that is not a PGenerator+ device." >&2
      exit 5
    fi
  fi
done < "$manifest"
while IFS="$(printf '\\t')" read -r idx mode check rel; do
  target="/$rel"
  parent=$(dirname "$target")
  mkdir -p "$parent"
  target_mode="$mode"
  target_uid=0
  target_gid=0
  if [ -e "$target" ]; then
    saved="$backup/$rel"
    mkdir -p "$(dirname "$saved")"
    cp -a "$target" "$saved"
    target_mode=$(stat -c %a "$target" 2>/dev/null || echo "$mode")
    target_uid=$(stat -c %u "$target" 2>/dev/null || echo 0)
    target_gid=$(stat -c %g "$target" 2>/dev/null || echo 0)
  fi
  replacement="$target.pgen-new"
  cp "$stage/payload/$idx" "$replacement"
  chmod "$target_mode" "$replacement"
  chown "$target_uid:$target_gid" "$replacement"
  mv "$replacement" "$target"
done < "$manifest"
rm -rf "$stage"
rm -f "$archive"
printf '%s\\n' "$backup"
""".strip()
    try:
        output = ssh(connection, command, input_text=manifest, timeout=300)
    except AppError:
        try:
            ssh(
                connection,
                f"rm -rf {shlex.quote(remote_stage)}; rm -f {shlex.quote(remote_archive)}",
                timeout=10,
            )
        except AppError:
            pass
        raise
    backup = output.strip().splitlines()[-1] if output.strip() else f"/root/pgen-backups/{timestamp}-github"
    return {
        "uploaded": paths,
        "backup": backup,
        "syntaxChecked": checked,
        "commit": snapshot["commit"],
    }


def restart_renderer(connection: dict[str, str]) -> dict[str, Any]:
    command = r"""
response=$(wget -q -O - http://127.0.0.1/api/restart 2>/dev/null || true)
i=0
while [ "$i" -lt 20 ]; do
  if ps -e w 2>/dev/null | grep -Eq '[P]Generatord(\.dv)?([[:space:]]|$)'; then
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


def restart_daemon(connection: dict[str, str]) -> dict[str, Any]:
    command = r"""
/etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &
i=0
while [ "$i" -lt 45 ]; do
  sleep 1
  if ps -e w 2>/dev/null | grep -Eq '[P]Generatord\.pl'; then
    ping=$(wget -q -O - http://127.0.0.1/api/ping 2>/dev/null || true)
    case "$ping" in
      *'"ok"'*) printf '%s\n' "$ping"; exit 0 ;;
    esac
  fi
  i=$((i + 1))
done
echo "PGenerator did not answer /api/ping within 45 seconds" >&2
tail -n 5 /tmp/PGenerator-restart.log 2>/dev/null >&2
exit 1
""".strip()
    output = ssh(connection, command, timeout=70)
    state = remote_busy_state(connection)
    message = "PGenerator daemon restarted and is answering."
    if not state["rendererRunning"]:
        message += " The renderer was not detected yet. Give it a moment or restart it."
    return {"restarted": True, "message": message, "ping": output.strip(), "busy": state}


class Handler(BaseHTTPRequestHandler):
    server_version = f"PGeneratorGitHubDeployer/{DEPLOYER_BUILD}"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def send_json(self, value: Any, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'")
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
            self.send_json({"ok": True, "build": DEPLOYER_BUILD})
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
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'")
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self) -> None:
        try:
            payload = self.read_json()
            connection = connection_from(payload)
            if self.path == "/api/scan":
                source = github_source_from(payload)
                snapshot = create_snapshot(source)
                result = scan_snapshot(connection, snapshot)
                public_snapshot = {
                    key: snapshot[key]
                    for key in ("id", "repository", "ref", "commit", "commitDate", "commitMessage", "deployerOutdated")
                }
                result["snapshot"] = public_snapshot
                result["deployerBuild"] = DEPLOYER_BUILD
            elif self.path == "/api/upload":
                snapshot = get_snapshot(payload.get("snapshotId"))
                selected = validate_selected(snapshot, payload.get("paths"))
                result = upload_files(connection, snapshot, selected)
            elif self.path == "/api/restart":
                result = restart_renderer(connection)
            elif self.path == "/api/restart-daemon":
                result = restart_daemon(connection)
            elif self.path == "/api/status":
                result = remote_busy_state(connection)
            else:
                raise AppError("Unknown endpoint.", HTTPStatus.NOT_FOUND)
            self.send_json({"ok": True, **result})
        except AppError as exc:
            self.send_json({"ok": False, "error": str(exc)}, exc.status)
        except Exception as exc:
            self.send_json(
                {"ok": False, "error": f"Unexpected server error: {exc}"},
                HTTPStatus.INTERNAL_SERVER_ERROR,
            )


def drop_exported_shell_functions() -> list[str]:
    """Remove exported shell functions from our own environment.

    Bash publishes them as BASH_FUNC_<name>%%, and environment-modules exports
    three (module, ml, _module_raw). systemd rejects a variable whose name
    contains '%', so when we open a browser through KIO, KDE logs "Not passing
    environment variable ... illegal characters" once per function. Children
    inherit os.environ, so clearing it here covers xdg-open regardless of how
    this server was started -- run.sh strips them too, but only for the paths
    that go through it, and running server.py directly bypasses that.

    Distributions where /bin/sh is dash never see this, because dash discards
    those names on entry; Arch and Fedora point /bin/sh at bash, which keeps
    them.
    """
    dropped = [name for name in list(os.environ) if name.startswith("BASH_FUNC_") or "%" in name]
    for name in dropped:
        del os.environ[name]
    return dropped


def main() -> None:
    drop_exported_shell_functions()
    parser = argparse.ArgumentParser(description="Run the GitHub-backed PGenerator deployment dashboard.")
    parser.add_argument("--port", type=int, default=8766, help="local port (default: 8766)")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser automatically")
    args = parser.parse_args()
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    PID_FILE.write_text(f"{os.getpid()}\n", encoding="ascii")
    url = f"http://127.0.0.1:{args.port}"
    print(f"PGenerator GitHub deployer: {url}")
    if not args.no_open:
        import webbrowser

        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        server.server_close()
        try:
            if PID_FILE.read_text(encoding="ascii").strip() == str(os.getpid()):
                PID_FILE.unlink()
        except (FileNotFoundError, OSError):
            pass


if __name__ == "__main__":
    main()

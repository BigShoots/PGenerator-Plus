#!/usr/bin/env python3
"""Local PGenerator deployment console backed by a pinned GitHub snapshot."""

from __future__ import annotations

import argparse
import hashlib
import hmac
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
DEPLOYER_BUILD = "1.5"
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
# The panel capability library under this subtree is atomic. tv/sources.json and
# tv/lg/index.json name the sibling profile and recipe files that make up a
# valid library, so installing only some of them leaves the manifest pointing at
# a file that was never copied. The device then fails library validation and
# silently falls back to a conservative profile that blocks calibration.
# Deploying any file in this subtree therefore pulls the whole pinned-snapshot
# subtree, so the installed library is always internally consistent.
# (2026-09-18: a partial deploy shipped tv/lg/index.json without the newly added
# tv/lg/series/g3.json it references and disabled C1 calibration until the
# missing file was copied over by hand.)
CAPABILITY_TREE_PREFIX = "usr/share/PGenerator/tv/"
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")
REPO_PART_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
REF_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ID_RE = re.compile(r"^[0-9a-f]{24}$")
RENDERER_PATTERN = r"[P]Generatord(\.dv)?([[:space:]]|$)"
DAEMON_PATTERN = r"[P]Generatord\.pl"
PS_COMMAND = "ps -e w"
# Operator-populated host-key file, deliberately persistent (issue #51: a
# temp-dir file plus permissive policies meant every session was trust-on-first-
# use with no warning). Populate it with:
#   ssh-keyscan -f known_hosts.example 192.168.1.4 >> known_hosts
KNOWN_HOSTS = str(APP_DIR / "known_hosts")
# Shared-session guard for the HTTP API. The console binds to loopback, but any
# local process — or any webpage aimed at 127.0.0.1 via a rebinding DNS name —
# could previously trigger uploads and restarts with zero validation. A fresh
# token is generated at each server start and injected into the served page;
# every state-changing POST must echo it, and its Origin must match the Host.
# PGEN_DEPLOYER_TOKEN overrides the random token (tests and automation only).
DEPLOYER_TOKEN = os.environ.get("PGEN_DEPLOYER_TOKEN") or secrets.token_urlsafe(32)
SESSION_HEADER = "X-Deployer-Session"
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
        elif "Host key verification failed" in detail:
            # StrictHostKeyChecking=yes refusal (issue #51): show the operator
            # the fix instead of raw OpenSSH stderr. run() has no connection
            # context, so the host placeholder keeps the sentence grammatical;
            # the file path is what the operator actually needs.
            detail = (
                "The Pi's SSH host key is unknown or changed. Verify it out of band, then add it "
                f"to {KNOWN_HOSTS} (replacing the old line if the Pi was re-imaged), "
                f"e.g.:  ssh-keyscan <pi-address> >> {KNOWN_HOSTS}"
            )
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
    # `... or "main"` after the strip, not a dict default: the frontend
    # sends ref:"" when the picker field is untouched (the input starts
    # empty so the datalist stays unfiltered), and dict.get only defaults
    # on a MISSING key, so "" would reach REF_RE and fail the scan.
    # Trim first so whitespace-only refs resolve the same way.
    ref = str(payload.get("ref") or "").strip() or "main"
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


def host_key_hint(host: str) -> str:
    return (
        f"The host key for {host} is unknown or changed. Verify the key out of band, then add it "
        f"to {KNOWN_HOSTS}, e.g.:  ssh-keyscan {host} >> {KNOWN_HOSTS}"
    )


def host_key_changed_hint(host: str) -> str:
    return (
        f"The host key for {host} does not match its line in {KNOWN_HOSTS}. If the Pi was "
        f"re-imaged, verify the new fingerprint and REPLACE the old line (ssh-keyscan {host}); "
        "otherwise treat this as a possible man-in-the-middle."
    )


LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def host_name(value: str) -> str:
    """Bare hostname of a Host or Origin value, port and brackets stripped."""
    value = value.strip()
    # Only real URLs may go through the scheme parser: urlsplit() treats a
    # schemeless "localhost:8766" as scheme:path (registered-scheme rule),
    # which emptied the Host header for any non-IP host:port value and 403'd
    # the console when opened as http://localhost:PORT. "://" separates URLs
    # from bare host values; Host headers never carry a scheme, Origins always do.
    if "://" in value:
        value = urllib.parse.urlsplit(value).netloc
    if value.startswith("["):  # IPv6 literal: [::1]:8766
        return value.split("]", 1)[0][1:]
    if ":" in value:
        # Two or more colons can only be a bare (unbracketed) IPv6 address —
        # "port" splitting would chew the address itself ("::1" -> ":").
        if value.count(":") >= 2:
            return value
        head, _, port = value.rpartition(":")
        return head if port.isdigit() else value
    return value


def port_part(value: str) -> str:
    """Port component of a Host header or Origin URL; '' when the port is
    absent (a browser omits a scheme-default port from both headers)."""
    value = value.strip()
    if "://" in value:
        value = urllib.parse.urlsplit(value).netloc
    value = value.split("/", 1)[0]
    if value.startswith("["):  # [::1]:8766
        tail = value.partition("]")[2]
        return tail[1:] if tail.startswith(":") else ""
    if value.count(":") == 1:
        port = value.rpartition(":")[2]
        return port if port.isdigit() else ""
    return ""


def same_authority(origin: str, host_header: str) -> bool:
    """Same host AND same port — the full origin check.

    host_name() alone compares two values port-blind, and the port carries
    the entire origin separation on loopback: a page served from
    localhost:9999 has host_name 'localhost', equal to this console's Host
    at localhost:PORT. A port-blind check therefore lets ANY other local
    service (a dev server, a tool with an XSS) read /session.js via a
    <script src> and drive every gated POST once it holds the leaked token
    — the same webpage-aims-at-127.0.0.1 class issue #51 is about. The
    browser sends Host and Origin from the same request URL, so a genuine
    console page always matches; the other service's port never can."""
    return host_name(origin) == host_name(host_header) and port_part(origin) == port_part(host_header)


def check_local_request(request_headers, token: str) -> None:  # noqa: ANN001
    """Gate every state-changing POST (issue #51).

    Three checks, each closing a distinct hole:
    1. Host must name a loopback interface — kills DNS-rebinding, where a
       hostile domain resolves to 127.0.0.1 and the browser would otherwise
       send same-origin requests to this server.
    2. If Origin is present it must name the same host:port as the Host
       header — an embedding page on another site (or another local port,
       see same_authority) may not drive the API or read /session.js.
    3. The per-startup token must echo the one handed to the served page.
       compare_digest so the value is not byte-by-byte oracleable.
    """
    host_header = request_headers.get("Host", "")
    host = host_name(host_header)
    if host not in LOOPBACK_HOSTS:
        raise AppError("Requests must target the loopback address.", HTTPStatus.FORBIDDEN)
    origin = request_headers.get("Origin", "").strip()
    if origin and not same_authority(origin, host_header):
        raise AppError("Cross-origin requests are not allowed.", HTTPStatus.FORBIDDEN)
    # Header values arrive ISO-8859-1-decoded, so encode("latin-1") maps any
    # byte a client sent back to its raw form. compare_digest refuses non-ASCII
    # str inputs with TypeError, which would turn a hostile header into a 500
    # instead of a clean 401; comparing bytes sidesteps that entirely.
    provided = request_headers.get(SESSION_HEADER, "")
    if not hmac.compare_digest(provided.encode("latin-1", "ignore"), token.encode("utf-8", "surrogateescape")):
        raise AppError(
            "Missing or invalid session token. Reload the deploy console page in the browser.",
            HTTPStatus.UNAUTHORIZED,
        )


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
            "StrictHostKeyChecking=yes",
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


_HOST_KEY_POLICY_BASE = paramiko.MissingHostKeyPolicy if paramiko is not None else object


class KnownHostsOrReject(_HOST_KEY_POLICY_BASE):  # type: ignore[misc]
    """Reject unknown hosts with an actionable hint instead of auto-adding.

    Duck-types paramiko.MissingHostKeyPolicy (only missing_host_key is called)
    so the module still imports when paramiko is absent. AutoAddPolicy silently
    trusted the first key it saw (issue #51), which put the Pi password and
    repo pushes at MITM risk. Keys come from the same persistent known_hosts
    file the OpenSSH path uses, so one `ssh-keyscan` populates both. Windows
    builds ship paramiko without a usable ssh-keyscan, so the message names the
    exact file and the key line to append.
    """

    def missing_host_key(self, client, hostname, key):  # noqa: ANN001
        raise AppError(host_key_hint(hostname), HTTPStatus.BAD_GATEWAY)


def paramiko_client(connection: dict[str, str], timeout: int):
    if paramiko is None:
        raise AppError(
            "Windows SSH support is not installed. Close the server and run run-windows.bat again."
        )
    client = paramiko.SSHClient()
    # load_host_keys raises IOError when the file is unreadable — the common
    # fresh-Windows case, since only known_hosts.example ships. Surface the
    # operator fix instead of an unexpected 500 naming a raw [Errno 2].
    try:
        client.load_host_keys(KNOWN_HOSTS)
    except OSError:
        raise AppError(host_key_hint(connection["host"]), HTTPStatus.BAD_GATEWAY)
    client.set_missing_host_key_policy(KnownHostsOrReject())
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
    except paramiko.BadHostKeyException as exc:
        # A key that is present but differs from the offered one: distinguish
        # it from the transport catch-all below so the operator is told to
        # REPLACE the line, not append a second key.
        client.close()
        raise AppError(host_key_changed_hint(exc.hostname), HTTPStatus.BAD_GATEWAY) from exc
    except AppError:
        # KnownHostsOrReject raises this mid-connect; it is already operator
        # wording, not a transport failure — do not re-wrap it as one.
        client.close()
        raise
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


# Branch list cache keyed by "owner/repo": short-lived so a freshly pushed
# branch shows up on the next focus without hammering the API on every click.
REFS_CACHE: dict[str, tuple[float, list[dict[str, Any]]]] = {}
REFS_CACHE_TTL = 60
REFS_MAX_PAGES = 6


def github_refs(source: dict[str, str]) -> dict[str, Any]:
    """List repository branches (default first) for the ref picker.

    Uses the unauthenticated-friendly branch list endpoint with pagination;
    an explicit `?per_page=100` keeps round-trips low on repos with many
    branches. Tags and raw SHAs stay typeable in the same field — this only
    saves re-typing common branch names.
    """
    owner = urllib.parse.quote(source["owner"], safe="")
    repo = urllib.parse.quote(source["repo"], safe="")
    key = f"{owner}/{repo}"
    cached = REFS_CACHE.get(key)
    if cached and time.time() - cached[0] < REFS_CACHE_TTL:
        return {"branches": cached[1], "cached": True}
    branches: list[dict[str, Any]] = []
    default_branch = ""
    try:
        with github_open(f"{GITHUB_API}/repos/{owner}/{repo}", source["token"]) as response:
            info = json.loads(response.read(1024 * 1024 + 1))
        default_branch = str(info.get("default_branch", ""))
    except AppError:
        raise
    for page in range(1, REFS_MAX_PAGES + 1):
        url = f"{GITHUB_API}/repos/{owner}/{repo}/branches?per_page=100&page={page}"
        with github_open(url, source["token"]) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
        try:
            batch = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise AppError("GitHub returned an invalid branch list.", HTTPStatus.BAD_GATEWAY) from exc
        if not isinstance(batch, list):
            raise AppError("GitHub returned an invalid branch list.", HTTPStatus.BAD_GATEWAY)
        for item in batch:
            name = str((item or {}).get("name", ""))
            sha = str(((item or {}).get("commit") or {}).get("sha", ""))
            if name:
                branches.append({"name": name, "sha": sha.lower() if SHA_RE.fullmatch(sha) else "",
                                 "default": name == default_branch})
        if len(batch) < 100:
            break
    branches.sort(key=lambda b: (not b["default"], b["name"].lower()))
    REFS_CACHE[key] = (time.time(), branches)
    return {"branches": branches, "cached": False}


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


def capability_library_closure(
    snapshot: dict[str, Any], selected: list[str]
) -> tuple[list[str], list[str]]:
    """Expand the selection so the panel capability library ships as one unit.

    If the operator selected any file under CAPABILITY_TREE_PREFIX, add every
    other file in that subtree from the pinned snapshot. The library manifest
    (tv/lg/index.json) references sibling files by name, so deploying a subset
    leaves the installed library inconsistent and fails validation on the
    device. Over-including files already identical on the Pi is harmless -- the
    apply step backs each target up and rewrites it in place.

    Returns (paths, added); added lists the files pulled in by the closure so
    the caller can report them.
    """
    if not any(rel.startswith(CAPABILITY_TREE_PREFIX) for rel in selected):
        return selected, []
    chosen = list(selected)
    present = set(chosen)
    added: list[str] = []
    for rel in sorted(snapshot["files"]):
        if not rel.startswith(CAPABILITY_TREE_PREFIX):
            continue
        if rel in PROTECTED_PATHS or rel in present:
            continue
        chosen.append(rel)
        present.add(rel)
        added.append(rel)
    return chosen, added


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
            for rel in paths:
                # Stage under the real relative path, not an index. Perl modules
                # in usr/share/PGenerator resolve siblings by their own file
                # name (webui.pm and the workers `use PGMath`), so a staged copy
                # named 0008 next to a PGMath.pm named 0003 cannot compile even
                # though the installed tree is fine. Real names keep `perl -c`
                # honest and make its messages readable.
                archive.add(root / rel, arcname=f"tree/{rel}", recursive=False)
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
modules="$stage/tree/usr/share/PGenerator"
if [ -d "$modules" ]; then
  # Backfill with the installed module directory, never overwriting what
  # this upload staged, so a module LEFT OUT of the selection still resolves
  # itself into this same tree. Several usr/share/PGenerator modules locate
  # their own shared directory from their own __FILE__ at compile time
  # (`unshift @INC, "$directory/../share/PGenerator"` in usr/sbin scripts,
  # `use lib File::Basename::dirname(__FILE__)` in some .pm files). If such
  # a module is not part of this upload, it loads from its real installed
  # path, and its own self-location re-prioritizes /usr/share/PGenerator
  # ahead of $modules for the REST of this perl -c process (@INC is
  # process-global) -- so a sibling's new export in the staged tree goes
  # unseen even though the file on disk is correct. (2026-09-21 incident:
  # PGAutomation.pm's own `unshift @INC, $directory` shadowed a staged
  # PGLGCapabilities.pm export this way and wrongly failed the check.)
  # `cp -an` never overwrites an already-staged file, so the files actually
  # being deployed still win; a failure here degrades to the old behaviour
  # rather than aborting the deploy.
  cp -an /usr/share/PGenerator/. "$modules/" 2>/dev/null || true
fi
while IFS="$(printf '\\t')" read -r idx mode check rel; do
  if [ "$check" = "perl" ]; then
    # Siblings being uploaded in this same batch take precedence over the
    # installed copies, then the installed module directory covers anything
    # not part of this upload -- the same view the file has once installed.
    # perl -c reports success on stderr ("syntax OK"), so keep its output
    # unless it actually failed.
    if ! result=$(perl -c -I "$modules" -I /usr/share/PGenerator "$stage/tree/$rel" 2>&1); then
      echo "Syntax check of $rel failed on the target device $(hostname 2>/dev/null) running Perl $(perl -e 'print $^V' 2>/dev/null); dependencies were searched in this upload and in /usr/share/PGenerator:" >&2
      printf '%s\\n' "$result" >&2
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
  cp "$stage/tree/$rel" "$replacement"
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
        if self.path == "/session.js":
            # Per-startup session token, delivered as a classic script so it
            # stays inside CSP 'self' and loads before app.js. A page on
            # another origin COULD include this file with <script src> — the
            # assignment would then execute in the loader's context and leak
            # the token — so the Origin header the browser attaches to
            # cross-origin script loads is what actually blocks it. The
            # check is loopback membership (a rebinding attacker's Host
            # equals its own Origin, so name equality alone would pass) AND
            # same authority INCLUDING PORT: the loopback port separates
            # origins, and without it any page served from another local
            # port reads the token here and wins every gated POST. no-store
            # keeps the token out of any cache.
            origin = self.headers.get("Origin", "").strip()
            if origin and (
                host_name(origin) not in LOOPBACK_HOSTS
                or not same_authority(origin, self.headers.get("Host", ""))
            ):
                self.send_error(HTTPStatus.FORBIDDEN)
                return
            body = (
                "/* PGenerator deploy console session bootstrap — do not cache. */\n"
                f"window.__PGEN_SESSION__ = {json.dumps(DEPLOYER_TOKEN)};\n"
            ).encode()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'")
            self.end_headers()
            self.wfile.write(body)
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
            # Issue #51: uploads, restarts and ref lookups are state-changing
            # or credential-adjacent. Nothing runs before this gate.
            check_local_request(self.headers, DEPLOYER_TOKEN)
            payload = self.read_json()
            # The ref picker queries GitHub only — no Pi credentials required,
            # so it must resolve before connection_from() validates the host.
            if self.path == "/api/refs":
                # No ref pre-default here: github_source_from() normalizes
                # empty/missing/whitespace refs to "main" itself (one site).
                source = github_source_from(payload)
                self.send_json({"ok": True, **github_refs(source)})
                return
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
                selected, auto_included = capability_library_closure(snapshot, selected)
                result = upload_files(connection, snapshot, selected)
                if auto_included:
                    result["autoIncluded"] = auto_included
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

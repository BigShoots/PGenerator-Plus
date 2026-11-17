#!/usr/bin/python3
"""Create and restore versioned PGenerator+ user-data backups.

The archive is intentionally limited to persistent PGenerator+ configuration,
profiles and calibration history. Runtime state, device identity, caches,
logs and pairing tokens are never included.
"""

from __future__ import print_function

import argparse
import datetime
import hashlib
import io
import json
import os
import posixpath
import pwd
import grp
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time


FORMAT = "pgenerator-system-backup-v1"
SCHEMA_VERSION = 1
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 100000

# USB rescue paths. PG_USB_SCAN_ROOT overrides the sysfs block root so
# tests can fake a stick; PG_USB_MOUNT_BASE overrides the mount point;
# PG_MOUNT_BIN/PG_UMOUNT_BIN substitute the mount tools for tests.
USB_SCAN_ROOT = os.environ.get("PG_USB_SCAN_ROOT", "/sys/block")
USB_MOUNT_BASE = os.environ.get("PG_USB_MOUNT_BASE", "/var/lib/PGenerator/usb-mnt")
MOUNT_BIN = os.environ.get("PG_MOUNT_BIN", "/bin/mount")
UMOUNT_BIN = os.environ.get("PG_UMOUNT_BIN", "/bin/umount")
# Per-mount/umount bound in seconds (first-boot path must never wedge).
# The seam lets tests exercise the timeout path with a hanging stub.
USB_CMD_TIMEOUT = int(os.environ.get("PG_USB_CMD_TIMEOUT", "60"))
# Directories on the stick that never hold a user backup, and never make
# a stick "non-empty" for the export guard either: Windows, macOS and
# ext4 all leave these on a factory-formatted or freshly-touched drive.
USB_SKIP_DIRS = set(["system volume information", ".trash", ".trash-info",
                     ".system volume information", "$recycle.bin", ".fseventsd",
                     ".spotlight-v100", ".documentrevisions-v100",
                     "lost+found", "system volume information.tmp"])
# Rescue opt-in marker. usb-export writes it next to the archive; the
# first-boot rescue only restores from a partition that carries it, so a
# random stick (or a compromised one) planted in an unattended device
# cannot push settings — rescue requires a stick this WebUI prepared.
# Scope note: the sentinel is a plain name, not a signature; an attacker
# with physical access can plant it alongside an archive. It stops
# accidents and casual media, not a deliberate plant — what still holds
# against a plant is archive validation (format, manifest, per-file
# sha256) and the OTA trust-key strip below.
RESCUE_SENTINEL = "PGEN_USB_RESCUE"
# Name shape of an archive THIS button wrote (usb_export builds exactly
# this). Orphan recovery keys on it: an interrupted export dies between
# the archive rename and the sentinel write, and the half-prepared stick
# must stay refreshable by the same button. A foreign-named hand-copied
# archive is NOT an orphan signature — it stays somebody's data.
CANONICAL_EXPORT_RE = re.compile(r"^PGenerator_plus_system_backup_.*\.pgbackup$", re.IGNORECASE)


def canonical_rescue_archive(name):
    return bool(CANONICAL_EXPORT_RE.match(name))


# Conf keys the unattended USB rescue must never apply. The browser
# import is a deliberate user action and may restore them; first-boot
# restore runs with no user and no chance to review, so OTA trust keys
# (the same set the generic conf writer denies, webui.pm) are stripped.
USB_RESTORE_DENY_CONF_KEYS = set(["ota_repo", "ota_repo_trusted", "ota_target"])
CONF_DEST = "/etc/PGenerator/PGenerator.conf"

# kind, source/destination, component label
BACKUP_SPECS = (
    ("file", "/etc/PGenerator/PGenerator.conf", "PGenerator+ configuration"),
    ("file", "/etc/PGenerator/hdr20_postcal_shadow_matrix.json", "HDR calibration configuration"),
    ("file", "/var/lib/PGenerator/meter_settings.json", "meter and calibration settings"),
    ("dir", "/var/lib/PGenerator/custom-series", "custom measurement series"),
    ("dir", "/var/lib/PGenerator/ccss/custom", "custom meter profiles"),
    ("dir", "/var/lib/PGenerator/images", "custom diagnostic images"),
    ("dir", "/var/lib/PGenerator/video", "custom diagnostic videos"),
    ("dir", "/var/lib/PGenerator/icc", "ICC profiles and measurements"),
    ("file", "/var/lib/PGenerator/lg/clients.json", "paired LG displays"),
    ("dir", "/var/lib/PGenerator/lg/calibration-history", "1D LUT and Dolby Vision history"),
    ("dir", "/var/lib/PGenerator/lg/luts", "3D LUT history"),
    ("dir", "/var/lib/PGenerator/lg/autocal-runs", "AutoCal run history"),
    ("dir", "/var/lib/PGenerator/lg/profile-captures", "calibration profile captures"),
    ("dir", "/var/lib/PGenerator/lg/ddc", "LG DDC configuration"),
    ("dir", "/var/lib/PGenerator/reports/full-autocal", "Full AutoCal reports"),
)


class BackupError(Exception):
    pass


def utc_stamp():
    return datetime.datetime.utcnow().strftime("%Y%m%d-%H%M%S")


def utc_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def archive_name(path):
    return "data" + path


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def iter_source_entries(kind, source):
    if kind == "file":
        if os.path.isfile(source) and not os.path.islink(source):
            yield source
        return
    if not os.path.isdir(source) or os.path.islink(source):
        return
    for root, dirs, files in os.walk(source):
        # Diagnostic-video frame caches are regenerated from the original
        # uploaded video and can be many times larger than the source file.
        dirs[:] = sorted([name for name in dirs if name != ".diagseq" and not os.path.islink(os.path.join(root, name))])
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.isfile(path) and not os.path.islink(path):
                yield path


def collect_backup_files():
    files = []
    components = []
    total_bytes = 0
    for kind, source, label in BACKUP_SPECS:
        component_count = 0
        component_bytes = 0
        for path in iter_source_entries(kind, source):
            size = os.path.getsize(path)
            item = {
                "path": archive_name(path),
                "size": size,
                "sha256": sha256_file(path),
            }
            files.append((path, item))
            total_bytes += size
            component_bytes += size
            component_count += 1
        if component_count:
            components.append({
                "name": label,
                "source": source,
                "files": component_count,
                "bytes": component_bytes,
            })
    files.sort(key=lambda entry: entry[1]["path"])
    return files, components, total_bytes


def create_archive(output_path, software_version):
    files, components, total_bytes = collect_backup_files()
    if not files:
        raise BackupError("No PGenerator+ settings or profile data were found")
    manifest = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "created_utc": utc_iso(),
        "software_version": software_version or "unknown",
        "file_count": len(files),
        "uncompressed_bytes": total_bytes,
        "components": components,
        "files": [item for unused_path, item in files],
    }
    parent = os.path.dirname(output_path) or "."
    if not os.path.isdir(parent):
        os.makedirs(parent)
    temp_path = output_path + ".tmp"
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    with tarfile.open(temp_path, "w:gz", dereference=True) as archive:
        raw = json.dumps(manifest, sort_keys=True, indent=2).encode("utf-8")
        info = tarfile.TarInfo("manifest.json")
        info.size = len(raw)
        info.mode = 0o644
        info.mtime = int(time.time())
        archive.addfile(info, io.BytesIO(raw))
        for source, item in files:
            archive.add(source, arcname=item["path"], recursive=False)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, output_path)
    return manifest


def normalized_member_name(name):
    if not isinstance(name, str):
        raise BackupError("Archive contains an invalid path")
    name = name.replace("\\", "/")
    if name.startswith("/") or "\x00" in name:
        raise BackupError("Archive contains an unsafe path")
    normalized = posixpath.normpath(name)
    if normalized in ("", ".") or normalized == ".." or normalized.startswith("../"):
        raise BackupError("Archive contains an unsafe path")
    return normalized


def allowed_archive_path(name):
    if name == "manifest.json":
        return True
    for kind, destination, unused_label in BACKUP_SPECS:
        base = archive_name(destination)
        if kind == "file" and name == base:
            return True
        if kind == "dir" and (name == base or name.startswith(base + "/")):
            return True
    return False


def inspect_archive(archive_path, check_specs=True):
    # check_specs=False relaxes the BACKUP_SPECS allowlist (unsafe-path,
    # duplicate, special-file, size and manifest self-consistency checks
    # all still apply). The export sweep uses it when choosing which old
    # archive to keep as a fallback: a valid archive written before a
    # spec change lists paths the CURRENT build no longer recognises,
    # and enforcing the allowlist there would delete every fallback the
    # moment the spec moved. Rescue still enforces it (default True) —
    # it is the one that restores from the file.
    if not os.path.isfile(archive_path):
        raise BackupError("Backup upload is missing")
    if os.path.getsize(archive_path) > MAX_ARCHIVE_BYTES:
        raise BackupError("Backup exceeds the 512 MB size limit")
    try:
        archive = tarfile.open(archive_path, "r:*")
    except (tarfile.TarError, IOError) as error:
        raise BackupError("Backup archive is invalid: %s" % error)
    members = archive.getmembers()
    if len(members) > MAX_MEMBERS:
        archive.close()
        raise BackupError("Backup contains too many files")
    expanded = 0
    seen = set()
    manifest_member = None
    for member in members:
        name = normalized_member_name(member.name)
        if name in seen:
            archive.close()
            raise BackupError("Backup contains duplicate paths")
        seen.add(name)
        if check_specs and not allowed_archive_path(name):
            archive.close()
            raise BackupError("Backup contains unsupported data: %s" % name)
        if not (member.isfile() or member.isdir()):
            archive.close()
            raise BackupError("Backup contains links or special files")
        if member.isfile():
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                archive.close()
                raise BackupError("Expanded backup exceeds the safety limit")
        if name == "manifest.json":
            manifest_member = member
    if manifest_member is None or not manifest_member.isfile():
        archive.close()
        raise BackupError("Backup manifest is missing")
    try:
        manifest_raw = archive.extractfile(manifest_member).read()
        manifest = json.loads(manifest_raw.decode("utf-8"))
    except Exception as error:
        archive.close()
        raise BackupError("Backup manifest is invalid: %s" % error)
    if manifest.get("format") != FORMAT or int(manifest.get("schema_version", 0)) != SCHEMA_VERSION:
        archive.close()
        raise BackupError("This is not a supported PGenerator+ system backup")
    listed = manifest.get("files")
    if not isinstance(listed, list) or len(listed) > MAX_MEMBERS:
        archive.close()
        raise BackupError("Backup file manifest is invalid")
    expected = {}
    for item in listed:
        if not isinstance(item, dict):
            archive.close()
            raise BackupError("Backup file manifest is invalid")
        name = normalized_member_name(item.get("path", ""))
        if name == "manifest.json" or (check_specs and not allowed_archive_path(name)) or name in expected:
            archive.close()
            raise BackupError("Backup file manifest contains an invalid path")
        expected[name] = item
    actual_files = set(normalized_member_name(member.name) for member in members if member.isfile() and normalized_member_name(member.name) != "manifest.json")
    if actual_files != set(expected.keys()):
        archive.close()
        raise BackupError("Backup contents do not match its manifest")
    return archive, members, manifest, expected


def extract_and_verify(archive_path, staging_dir):
    archive, members, manifest, expected = inspect_archive(archive_path)
    try:
        for member in members:
            name = normalized_member_name(member.name)
            if name == "manifest.json":
                continue
            target = os.path.join(staging_dir, *name.split("/"))
            if member.isdir():
                if not os.path.isdir(target):
                    os.makedirs(target)
                continue
            parent = os.path.dirname(target)
            if not os.path.isdir(parent):
                os.makedirs(parent)
            source = archive.extractfile(member)
            digest = hashlib.sha256()
            size = 0
            with open(target, "wb") as output:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
            item = expected[name]
            if size != int(item.get("size", -1)) or digest.hexdigest() != str(item.get("sha256", "")):
                raise BackupError("Backup integrity check failed for %s" % name)
    finally:
        archive.close()
    return manifest


def copy_file_atomic(source, destination):
    parent = os.path.dirname(destination)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    temp_path = destination + ".restore.tmp"
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    shutil.copyfile(source, temp_path)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, destination)


def merge_tree(source, destination):
    if not os.path.isdir(destination):
        os.makedirs(destination)
    for root, dirs, files in os.walk(source):
        relative = os.path.relpath(root, source)
        target_root = destination if relative == "." else os.path.join(destination, relative)
        if not os.path.isdir(target_root):
            os.makedirs(target_root)
        for name in dirs:
            target_dir = os.path.join(target_root, name)
            if not os.path.isdir(target_dir):
                os.makedirs(target_dir)
        for name in files:
            copy_file_atomic(os.path.join(root, name), os.path.join(target_root, name))


def apply_pgenerator_ownership(path):
    try:
        uid = pwd.getpwnam("pgenerator").pw_uid
        gid = grp.getgrnam("pgenerator").gr_gid
    except KeyError:
        return
    paths = [path]
    if os.path.isdir(path):
        paths = []
        for root, dirs, files in os.walk(path):
            paths.append(root)
            paths.extend(os.path.join(root, name) for name in dirs)
            paths.extend(os.path.join(root, name) for name in files)
    for item in paths:
        try:
            os.chown(item, uid, gid)
            mode = os.stat(item).st_mode & 0o777
            if os.path.isdir(item):
                os.chmod(item, mode | 0o700)
            else:
                os.chmod(item, mode | 0o600)
        except OSError:
            pass


ROLLBACK_DIR = "/var/lib/PGenerator/system-backups"


def create_rollback_snapshot(software_version):
    directory = ROLLBACK_DIR
    if not os.path.isdir(directory):
        os.makedirs(directory)
    path = os.path.join(directory, "pre-import-%s.pgbackup" % utc_stamp())
    create_archive(path, software_version)
    backups = sorted(
        [os.path.join(directory, name) for name in os.listdir(directory) if name.startswith("pre-import-") and name.endswith(".pgbackup")],
        key=lambda item: os.path.getmtime(item),
        reverse=True,
    )
    for stale in backups[3:]:
        try:
            os.unlink(stale)
        except OSError:
            pass
    return path


def strip_denied_conf_keys(conf_path):
    # Unattended first-boot restore must not plant the OTA trust keys
    # (same set the generic conf writer denies in webui.pm): a restored
    # ota_repo + ota_repo_trusted=1 would let pgenerator-update apply an
    # unsigned tarball as root with nobody having chosen the repo.
    try:
        with open(conf_path, "r") as handle:
            lines = handle.readlines()
    except IOError:
        return
    kept = []
    dropped = False
    for line in lines:
        match = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", line)
        if match and match.group(1) in USB_RESTORE_DENY_CONF_KEYS:
            dropped = True
            continue
        kept.append(line)
    if not dropped:
        return
    temp_path = conf_path + ".deny.tmp"
    with open(temp_path, "w") as handle:
        handle.writelines(kept)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, conf_path)


def restore_archive(archive_path, software_version, unattended=False):
    staging_dir = tempfile.mkdtemp(prefix="pgenerator-backup-restore-")
    try:
        manifest = extract_and_verify(archive_path, staging_dir)
        rollback_path = create_rollback_snapshot(software_version)
        restored_components = []
        restored_files = 0
        for kind, destination, label in BACKUP_SPECS:
            source = os.path.join(staging_dir, *archive_name(destination).split("/"))
            if kind == "file":
                if not os.path.isfile(source):
                    continue
                if unattended and destination == CONF_DEST:
                    # Strip OTA trust keys from the STAGED copy first: the
                    # live conf must never hold them, even momentarily —
                    # strip-then-rename means the atomic install either
                    # shows the old conf or the clean one, never the raw
                    # restored one.
                    strip_denied_conf_keys(source)
                copy_file_atomic(source, destination)
                restored_files += 1
            else:
                if not os.path.isdir(source):
                    continue
                restored_files += sum(len(files) for unused_root, unused_dirs, files in os.walk(source))
                merge_tree(source, destination)
            if destination.startswith("/var/lib/PGenerator/"):
                apply_pgenerator_ownership(destination)
            restored_components.append(label)
        return {
            "status": "ok",
            "message": "System settings and profile history imported",
            "source_version": manifest.get("software_version", "unknown"),
            "restored_files": restored_files,
            "components": restored_components,
            "rollback_backup": rollback_path,
            "restart_required": True,
        }
    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)


def run_cmd(argv, timeout=None):
    # Every mount/umount/sync is bounded: this runs on the first-boot
    # path BEFORE the daemon starts, and a flaky stick that hangs mount
    # must not wedge the boot. A timed-out child is killed and reported
    # as failure (rc 124) so the caller skips the stick.
    if timeout is None:
        timeout = USB_CMD_TIMEOUT
    # Own session so a timeout can kill the WHOLE process group: mount
    # runs as /bin/sh wrappers and helpers, and killing only the direct
    # child leaves a grandchild holding the stdout pipe open, which
    # blocks communicate() on EOF and wedges the caller anyway.
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            preexec_fn=os.setsid)
    try:
        out, err = proc.communicate(timeout=(timeout if timeout > 0 else None))
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.communicate()
        except Exception:
            pass
        return (124, b"", b"")
    return (proc.returncode, out or b"", err or b"")


def root_block_nodes():
    # Block node names holding the root filesystem (avoids touching the
    # boot device itself when the appliance boots from USB): base name of
    # the /dev node and, for a partition, its parent disk name.
    roots = set()
    try:
        with open("/proc/mounts", "r") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) < 2 or parts[1] != "/":
                    continue
                node = parts[0].rsplit("/", 1)[-1]
                # Kernel-less setups (and some vendor images) mount root
                # as /dev/root, a symlink to the real node: resolve it or
                # the boot disk is never excluded on a USB-booted unit.
                dev_link = "/dev/" + node
                if os.path.islink(dev_link) or os.path.exists(dev_link):
                    node = os.path.realpath(dev_link).rsplit("/", 1)[-1]
                roots.add(node)
                match = re.match(r"^(.*(?:mmcblk\d|sd[a-z]+|nvme\d+n\d+))p?\d+$", node)
                if match:
                    roots.add(match.group(1))
    except IOError:
        pass
    return roots


def list_usb_backup_candidates():
    # USB-attached block partitions, excluding the one holding root
    # (the appliance may boot from USB; never touch its own disk).
    candidates = []
    try:
        devs = sorted(os.listdir(USB_SCAN_ROOT))
    except OSError:
        return candidates
    root_nodes = root_block_nodes()
    for dev in devs:
        if not re.match(r"^sd[a-z]+$", dev):
            continue
        real = os.path.realpath(os.path.join(USB_SCAN_ROOT, dev))
        if "/usb" not in real:
            continue
        if dev in root_nodes:
            continue
        try:
            entries = sorted(os.listdir(os.path.join(USB_SCAN_ROOT, dev)))
        except OSError:
            entries = []
        parts = [name for name in entries if re.match("^%s[0-9]+$" % dev, name)]
        if not parts:
            # Unpartitioned stick (superfloppy): the whole disk is the
            # candidate, and its sysfs node lives at the scan root.
            parts = [dev]
        for part in parts:
            if part in root_nodes:
                continue
            if part != dev:
                # Real kernels nest partitions INSIDE the disk directory
                # (/sys/block/sdb/sdb1), never as siblings — checking
                # /sys/block/sdb1 drops every partitioned stick.
                if not os.path.isdir(os.path.join(USB_SCAN_ROOT, dev, part)):
                    continue
            # Superfloppy case (part == dev): the whole disk is a single
            # filesystem with NO sysfs subdirectory beneath it, so the
            # nested check must not apply or every unpartitioned stick
            # is silently dropped.
            candidates.append(part)
    return candidates


def mount_ro(part):
    dest = os.path.join(USB_MOUNT_BASE, part)
    created = False
    if not os.path.isdir(dest):
        os.makedirs(dest)
        created = True
    rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "/dev/" + part, dest])
    if rc == 0:
        return dest
    rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "-t", "vfat", "/dev/" + part, dest])
    if rc == 0:
        return dest
    # Both attempts failed: do not leave an empty mount dir behind for
    # every unreadable partition we probed.
    if created:
        try:
            os.rmdir(dest)
        except OSError:
            pass
    return None


def umount_path(dest):
    run_cmd([UMOUNT_BIN, dest])
    try:
        os.rmdir(dest)
    except OSError:
        pass


def find_archives_on(part):
    # Returns (archives, mount_point_or_None); archives are
    # (part, relative_name, absolute_path) tuples. A partition only
    # counts as a rescue source if it carries the PGEN_USB_RESCUE
    # sentinel written by usb-export: rescue is opt-in, so an arbitrary
    # stick cannot push settings onto an unattended first boot.
    # Top-level only: usb-export always writes the sentinel and the
    # archive at the stick root, so a deep directory of unrelated files
    # is never walked (or matched into) a rescue decision.
    dest = mount_ro(part)
    found = []
    if dest is None:
        return (found, None)
    try:
        names = os.listdir(dest)
    except OSError:
        return (found, dest)
    if RESCUE_SENTINEL not in names:
        return (found, dest)
    for name in names:
        if name.lower().endswith(".pgbackup"):
            full = os.path.join(dest, name)
            if os.path.isfile(full):
                found.append((part, name, full))
    return (found, dest)


def validate_candidate(full, check_specs=True):
    # One gzip pass per candidate: structure + manifest check, every
    # manifest-listed member streamed through sha256, and created_utc
    # lifted from the manifest the inspection already opened. The first
    # boot re-validates each archive on every boot, so the old shape
    # (inspect + verify + inspect-for-sort, then inspect + extract for
    # the winner) multiplied a ~100 MB archive's gunzip cost on the
    # daemon-blocking boot path. Returns created_utc; raises BackupError
    # on any invalidity so the caller falls through to older archives.
    # check_specs=False (export sweep) skips only the BACKUP_SPECS
    # allowlist so a pre-spec-change archive is not misjudged corrupt.
    archive, members, manifest, expected = inspect_archive(full, check_specs=check_specs)
    try:
        by_name = {}
        for member in members:
            name = normalized_member_name(member.name)
            if member.isfile() and name in expected:
                by_name[name] = member
        for name, member in by_name.items():
            digest = hashlib.sha256()
            source = archive.extractfile(member)
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != str(expected[name].get("sha256", "")):
                raise BackupError("Backup integrity check failed for %s" % name)
    finally:
        archive.close()
    return str(manifest.get("created_utc", ""))


def usb_restore(software_version):
    parts = list_usb_backup_candidates()
    if not parts:
        raise BackupError("No USB drive found")
    archives = []
    mounts = []
    try:
        for part in parts:
            found, dest = find_archives_on(part)
            if dest is not None:
                mounts.append(dest)
            archives.extend(found)
        if not archives:
            raise BackupError("No .pgbackup found on the USB drive")
        # Validate every candidate in ONE pass each, ranking by the
        # created_utc that pass already read; a corrupt archive falls
        # through to an older valid one instead of aborting the rescue.
        usable = []
        for part, rel, full in archives:
            try:
                created = validate_candidate(full)
            except BackupError:
                continue
            usable.append((created, os.path.getmtime(full), part, rel, full))
        if not usable:
            raise BackupError("No valid .pgbackup found on the USB drive")
        usable.sort(reverse=True)
        unused_created, unused_mtime, part, rel, full = usable[0]
        result = restore_archive(full, software_version, unattended=True)
        result["usb_device"] = part
        result["usb_archive"] = rel
        return result
    finally:
        for dest in mounts:
            umount_path(dest)


def archive_name_stamp(name):
    # Export names embed a UTC stamp: ..._YYYYMMDD-HHMMSS.pgbackup.
    # Fallback selection must rank by that stamp, NOT by whole-name
    # sort: the name also carries the version, and lexical order
    # disagrees with time across version strings (v2.9 > v2.10).
    # Names without a stamp rank oldest.
    match = re.search(r"_(\d{8}-\d{6})\.pgbackup$", name, re.IGNORECASE)
    return match.group(1) if match else ""


def stick_is_blank(dest):
    # A freshly formatted or Windows/macOS-touched stick counts as blank:
    # only entries outside USB_SKIP_DIRS are somebody's data. A stranded
    # write temp from an interrupted export also does not count, or the
    # retry could never proceed. A rescue stick THIS button already wrote
    # counts as blank too — provenance is the SENTINEL, not the file
    # extension: *.pgbackup is tolerated only when the sentinel sits next
    # to it. A user stick whose only content is a hand-copied backup has
    # no sentinel and is somebody's data stick: export refuses it, so the
    # button can never turn a data drive into a rescue source. Restore
    # validates candidates and ranks them by the manifest created_utc
    # (newest first), so a refreshed stick resolves to the latest export
    # and usb-export retires the older rescue archives as superseded.
    entries = os.listdir(dest)
    has_sentinel = RESCUE_SENTINEL in entries
    for entry in entries:
        if entry.lower() in USB_SKIP_DIRS:
            continue
        if entry.lower().endswith(".pgbackup.tmp"):
            continue
        if entry == RESCUE_SENTINEL:
            continue
        if entry.lower().endswith(".pgbackup"):
            # A rescue stick THIS button wrote tolerates its archives.
            # Without the sentinel, only the button's CANONICAL export
            # name is tolerated: it is the signature of an interrupted
            # export (crash between the archive rename and the sentinel
            # write), which the pre-write sweep now retires on the
            # retry. A foreign-named archive without the sentinel is
            # somebody's data, not our orphan — export refuses it.
            if has_sentinel or canonical_rescue_archive(entry):
                continue
        return False
    return True


def usb_export(software_version):
    parts = list_usb_backup_candidates()
    if not parts:
        raise BackupError("No USB drive found")
    # Remember WHY each stick was passed over: the generic "no empty
    # drive" message told a user with a FULL stick to go buy a blank
    # one, and hid genuine write failures (ENOSPC, read-only) behind it.
    saw_data_stick = False
    write_failure = None
    for part in parts:
        # Write only to an empty stick: a drive that already holds files
        # is somebody's data stick, not a rescue target (a rescue stick
        # THIS button wrote — sentinel + its archives — is refreshable).
        # Check emptiness READ-ONLY first — mounting rw would set the
        # vfat dirty bit before we even know the stick is blank — and
        # remount rw only for the winning stick. The finally below
        # unmounts EVERY stick we mounted, empty or not.
        dest = os.path.join(USB_MOUNT_BASE + "-rw", part)
        created = False
        if not os.path.isdir(dest):
            os.makedirs(dest)
            created = True
        rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "/dev/" + part, dest])
        if rc != 0:
            rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "-t", "vfat", "/dev/" + part, dest])
        if rc != 0:
            # Both ro attempts failed: do not leave an empty mount dir
            # for every unreadable partition probed (the mount_ro twin
            # already does this). Only rmdir when WE created it.
            if created:
                try:
                    os.rmdir(dest)
                except OSError:
                    pass
            continue
        try:
            try:
                if not stick_is_blank(dest):
                    saw_data_stick = True
                    continue
            except OSError:
                continue
            rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "remount,rw", dest])
            if rc != 0:
                # Filesystems without remount support: try a fresh rw mount.
                run_cmd([UMOUNT_BIN, dest])
                rc, _out, _err = run_cmd([MOUNT_BIN, "/dev/" + part, dest])
                if rc != 0:
                    rc, _out, _err = run_cmd([MOUNT_BIN, "-t", "vfat", "/dev/" + part, dest])
            if rc != 0:
                write_failure = "USB drive %s could not be mounted read-write" % part
                continue
            try:
                # A failed create_archive can leave <name>.pgbackup.tmp;
                # clear one before writing so the stick is never poisoned
                # for the next attempt (stick_is_blank tolerates it too).
                for stale in os.listdir(dest):
                    if stale.lower().endswith(".pgbackup.tmp"):
                        try:
                            os.unlink(os.path.join(dest, stale))
                        except OSError:
                            pass
                # Superseded rescue archives retire BEFORE the write:
                # keeping every refresh means first-boot validation
                # re-reads each one and ENOSPC gets likelier with each
                # export. Prune first (keep the newest VALID canonical
                # one as a fallback against a corrupt fresh write), then
                # write — the stick then holds at most new + one
                # fallback. The sweep covers EVERY top-level
                # *.pgbackup, not just canonical names: rescue ranks
                # all of them by manifest created_utc, so a hand-copied
                # browser archive left on a rescue stick could out-rank
                # the intended export. A stick reaching this code is
                # either sentinel-verified (this button wrote it) or a
                # blank stick plus OUR orphan from an interrupted export
                # (crash between the archive rename and the sentinel
                # write): canonical_rescue_archive names only, never a
                # foreign archive — a data stick fails stick_is_blank
                # first, so no user data on a foreign drive is ever
                # deleted here. The valid orphan doubles as the
                # corrupt-write fallback, and the half-prepared stick
                # never needs manual cleanup to retry. Ranking is by
                # the embedded UTC stamp, not the whole name: a version
                # bump like v2.9 -> v2.10 makes lexical name order
                # disagree with chronology. The kept fallback is
                # VALIDATED (full manifest + per-file sha256 pass):
                # stamp order alone could keep a corrupt newest archive
                # and delete the older VALID one, leaving nothing
                # restorable if the fresh write then fails (ENOSPC,
                # detached stick).
                entries = os.listdir(dest)
                rescue_stick = RESCUE_SENTINEL in entries
                # The sentinel-or-canonical filter is defense in depth
                # for a state change between the blankness check and
                # this sweep: blankness already refuses a foreign
                # *.pgbackup on a sentinel-less stick, so in the normal
                # flow the filter is a no-op. It only bites if a
                # foreign archive lands in that window, and then it
                # keeps the foreign file out of the FALLBACK seat (the
                # delete loop below still treats it as superseded).
                ranked_archives = sorted(
                    [name for name in entries
                     if name.lower().endswith(".pgbackup")
                     and (rescue_stick or canonical_rescue_archive(name))],
                    key=lambda name: (archive_name_stamp(name), name),
                    reverse=True)
                keep_fallback = None
                for name in ranked_archives:
                    try:
                        # check_specs=False: keep any structurally valid
                        # archive; a pre-spec-change fallback is still
                        # the better rescue candidate than none, and
                        # rescue itself applies the allowlist.
                        validate_candidate(os.path.join(dest, name), check_specs=False)
                    except BackupError:
                        continue
                    keep_fallback = name
                    break
                for stale in list(os.listdir(dest)):
                    if not stale.lower().endswith(".pgbackup"):
                        continue
                    if stale == keep_fallback:
                        continue
                    try:
                        os.unlink(os.path.join(dest, stale))
                    except OSError:
                        pass
                stamp = utc_stamp()
                out_path = os.path.join(dest, "PGenerator_plus_system_backup_v%s_%s.pgbackup" % (
                    (software_version or "unknown"), stamp))
                manifest = create_archive(out_path, software_version)
                try:
                    os.chmod(out_path, 0o644)
                except OSError:
                    pass
                # Opt-in marker the first-boot rescue looks for: no
                # sentinel, no rescue from this stick.
                with open(os.path.join(dest, RESCUE_SENTINEL), "w") as handle:
                    handle.write("pgenerator-usb-rescue\n")
                run_cmd(["/bin/sync"])
                return {
                    "status": "ok",
                    "message": "Backup written to the USB drive",
                    "usb_device": part,
                    "usb_archive": os.path.basename(out_path),
                    "file_count": manifest["file_count"],
                    "uncompressed_bytes": manifest["uncompressed_bytes"],
                }
            except (BackupError, OSError, IOError) as error:
                # ENOSPC, read-only media, removed stick: keep the real
                # reason instead of blaming stick contents.
                write_failure = "USB drive %s: %s" % (part, error)
                continue
        finally:
            run_cmd([UMOUNT_BIN, dest])
            try:
                # Only remove a mount dir this probe created, and never
                # while it is still a live mountpoint. The ismount check
                # (not the umount exit code) is what makes this safe in
                # both directions: a failed unmount leaves a real mount
                # that must survive, while the rw-fallback path already
                # unmounted the stick mid-body — there the cleanup
                # umount "fails" only because the device is already
                # detached, and the dir we created is now removable.
                if created and not os.path.ismount(dest):
                    os.rmdir(dest)
            except OSError:
                pass
    if write_failure is not None:
        raise BackupError(write_failure)
    if saw_data_stick:
        raise BackupError("USB drive is not empty; use a blank drive (or one this button previously wrote)")
    raise BackupError("No writable empty USB drive found")


def main():
    parser = argparse.ArgumentParser(description="PGenerator+ system backup")
    subparsers = parser.add_subparsers(dest="command")
    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--version", default="unknown")
    import_parser = subparsers.add_parser("import")
    import_parser.add_argument("--input", required=True)
    import_parser.add_argument("--version", default="unknown")
    usb_restore_parser = subparsers.add_parser("usb-restore")
    usb_restore_parser.add_argument("--version", default="unknown")
    usb_export_parser = subparsers.add_parser("usb-export")
    usb_export_parser.add_argument("--version", default="unknown")
    args = parser.parse_args()
    try:
        if args.command == "export":
            manifest = create_archive(args.output, args.version)
            result = {
                "status": "ok",
                "file_count": manifest["file_count"],
                "uncompressed_bytes": manifest["uncompressed_bytes"],
                "components": manifest["components"],
            }
        elif args.command == "import":
            result = restore_archive(args.input, args.version)
        elif args.command == "usb-restore":
            result = usb_restore(args.version)
        elif args.command == "usb-export":
            result = usb_export(args.version)
        else:
            parser.error("an export or import command is required")
            return 2
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except BackupError as error:
        print(json.dumps({"status": "error", "message": str(error)}, separators=(",", ":")))
        return 1
    except Exception as error:
        print(json.dumps({"status": "error", "message": "System backup failed: %s" % error}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())

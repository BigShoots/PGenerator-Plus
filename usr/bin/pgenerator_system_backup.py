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
import shutil
import sys
import tarfile
import tempfile
import time


FORMAT = "pgenerator-system-backup-v1"
SCHEMA_VERSION = 1
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 100000

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


def inspect_archive(archive_path):
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
        if not allowed_archive_path(name):
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
        if name == "manifest.json" or not allowed_archive_path(name) or name in expected:
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


def create_rollback_snapshot(software_version):
    directory = "/var/lib/PGenerator/system-backups"
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


def restore_archive(archive_path, software_version):
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


def main():
    parser = argparse.ArgumentParser(description="PGenerator+ system backup")
    subparsers = parser.add_subparsers(dest="command")
    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--version", default="unknown")
    import_parser = subparsers.add_parser("import")
    import_parser.add_argument("--input", required=True)
    import_parser.add_argument("--version", default="unknown")
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

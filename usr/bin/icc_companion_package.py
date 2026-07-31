#!/usr/bin/env python3
"""Create a PGenerator-paired ICC Companion download package."""

import os
import re
import sys
import time
import zipfile


ROOT = "/usr/share/PGenerator"
PLATFORMS = {
    "windows-x64": ("PGenerator-ICC-Companion-Windows-x64.zip", ("PGenICCCompanion.exe", "SDL3.dll")),
    "linux-x64": ("PGenerator-ICC-Companion-Linux-x64.zip", ("PGenICCCompanion", "libSDL3.so.0")),
}
SAFE_SERVER = re.compile(r"^http://[A-Za-z0-9._\-\[\]:]+$")
SAFE_TOKEN = re.compile(r"^[0-9a-f]{64}$")


def fail(message):
    raise ValueError(message)


def add_file(archive, path, name, mode=0o644):
    modified = time.localtime(os.path.getmtime(path))[:6]
    if modified[0] < 1980:
        modified = (1980, 1, 1, 0, 0, 0)
    info = zipfile.ZipInfo(name, modified)
    info.create_system = 3
    info.external_attr = (mode & 0xFFFF) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    with open(path, "rb") as handle:
        archive.writestr(info, handle.read(), compress_type=zipfile.ZIP_DEFLATED)


def build(platform, server, token, output_path):
    if platform not in PLATFORMS:
        fail("Unsupported companion platform")
    if not SAFE_SERVER.match(server):
        fail("Invalid PGenerator address")
    if not SAFE_TOKEN.match(token):
        fail("Invalid pairing token")
    filename, files = PLATFORMS[platform]
    binary_dir = os.path.join(ROOT, "icc-companion", platform)
    source_dir = os.path.join(ROOT, "icc-companion-src")
    config = "# Paired automatically by PGenerator\nSERVER={}\nTOKEN={}\n".format(server, token)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        config_info = zipfile.ZipInfo("PGenICCCompanion.conf")
        config_info.create_system = 3
        config_info.external_attr = 0o600 << 16
        archive.writestr(config_info, config)
        add_file(archive, os.path.join(source_dir, "README.txt"), "README.txt")
        add_file(archive, os.path.join(ROOT, "icc-companion", "SDL3-LICENSE.txt"), "SDL3-LICENSE.txt")
        for name in files:
            path = os.path.join(binary_dir, name)
            if not os.path.isfile(path):
                fail("Companion package is not installed")
            mode = 0o755 if platform == "linux-x64" and name == "PGenICCCompanion" else 0o644
            add_file(archive, path, name, mode)
    return filename


def main():
    if len(sys.argv) != 5:
        print("Usage: icc_companion_package.py PLATFORM SERVER TOKEN OUTPUT", file=sys.stderr)
        return 2
    try:
        filename = build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
        print(filename)
        return 0
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Generate the Companion's embedded window icon from the shipped favicon.

Windows takes its icon from pgen-icc-companion.rc, which points at
../favicon.ico. Linux has no resource section, and the Companion ships as a
small zip that must not gain a runtime file dependency, so the same artwork is
compiled in as a raw RGBA byte array instead.

Regenerate after changing usr/share/PGenerator/favicon.ico:

    python3 usr/share/PGenerator/icc-companion-src/make-icon-header.py

Requires Pillow, which is only needed to regenerate the header, never to build
the Companion.
"""

import os
import sys

from PIL import Image


HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.normpath(os.path.join(HERE, os.pardir, "favicon.ico"))
TARGET = os.path.join(HERE, "pgen-icc-companion-icon.h")


def main():
    icon = Image.open(SOURCE)
    size = max(icon.info.get("sizes") or {icon.size})
    icon.size = size
    icon.load()
    image = icon.convert("RGBA")
    width, height = image.size
    pixels = image.tobytes()

    lines = []
    for offset in range(0, len(pixels), 16):
        chunk = pixels[offset:offset + 16]
        lines.append("    " + "".join("0x%02x," % value for value in chunk))

    with open(TARGET, "w", encoding="ascii", newline="\n") as handle:
        handle.write(
            "/* PGenerator+ Patch Companion window icon.\n"
            " *\n"
            " * Generated from usr/share/PGenerator/favicon.ico, the same artwork the\n"
            " * Windows resource script compiles in as icon resource 1. Do not edit by\n"
            " * hand; regenerate with:\n"
            " *\n"
            " *     python3 usr/share/PGenerator/icc-companion-src/make-icon-header.py\n"
            " */\n"
            "\n"
            "#ifndef PGEN_ICC_COMPANION_ICON_H\n"
            "#define PGEN_ICC_COMPANION_ICON_H\n"
            "\n"
            "#define PGEN_COMPANION_ICON_WIDTH %d\n"
            "#define PGEN_COMPANION_ICON_HEIGHT %d\n"
            "\n"
            "/* Straight (non-premultiplied) RGBA, row major, no padding. */\n"
            "static const unsigned char pgen_companion_icon_rgba[%d] = {\n"
            % (width, height, len(pixels))
        )
        handle.write("\n".join(lines))
        handle.write("\n};\n\n#endif\n")

    sys.stderr.write("wrote %s (%dx%d, %d bytes of pixels)\n"
                     % (TARGET, width, height, len(pixels)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

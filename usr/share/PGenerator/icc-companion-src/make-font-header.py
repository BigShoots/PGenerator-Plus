#!/usr/bin/env python3
"""Generate the Profile Loader's embedded UI font atlases.

SDL3 on its own can only draw its 8x8 monospace debug font, which reads as
terminal output rather than an application. SDL_ttf would fix that but would
add a shared library, a font file and a freetype stack to a package that is
meant to stay small and self-contained, so the glyphs are baked into a set of
alpha atlases instead - the same approach as the embedded window icon.

Faces are rendered at roughly twice their typical point size so a HiDPI window
samples them close to 1:1 and a 1x window downscales cleanly. All metrics are
emitted in atlas texels; the loader scales by wanted_points / design_size, so
the atlas pixel size is never a second scale factor.

Regenerate with:

    python3 make-font-header.py

Requires Pillow and the DejaVu fonts, both only needed to regenerate the
header, never to build the loader. DejaVu is used because its licence (the
Bitstream Vera licence) explicitly permits redistribution; the licence ships
alongside the binary. Set PGEN_FONT_DIR if the fonts are somewhere this script
does not already look.
"""

import os
import sys

from PIL import Image, ImageFont


HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "pgen-ui-font.h")
# Distributions disagree about where DejaVu lives; Debian and Fedora between them
# cover nearly every host this is regenerated on.
FONT_DIRS = (
    os.environ.get("PGEN_FONT_DIR", ""),
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/dejavu",
    "/usr/share/fonts/dejavu-sans-fonts",
)
FONT_DIR = next((path for path in FONT_DIRS
                 if path and os.path.isfile(os.path.join(path, "DejaVuSans.ttf"))),
                FONT_DIRS[1])

# name, file, em height of the atlas in texels.
FACES = (
    ("REGULAR", "DejaVuSans.ttf", 28),
    ("BOLD", "DejaVuSans-Bold.ttf", 28),
    ("TITLE", "DejaVuSans-Bold.ttf", 36),
    ("MONO", "DejaVuSansMono.ttf", 24),
)
FIRST_CHAR = 32
LAST_CHAR = 126


def build_face(path, pixel_size):
    font = ImageFont.truetype(path, pixel_size)
    ascent, descent = font.getmetrics()
    glyphs = []
    total_width = 0
    max_height = 1
    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        character = chr(code)
        advance = font.getlength(character)
        box = font.getbbox(character)
        left, top, right, bottom = box
        width = max(0, right - left)
        height = max(0, bottom - top)
        image = None
        if width and height:
            image = Image.new("L", (width, height), 0)
            from PIL import ImageDraw
            ImageDraw.Draw(image).text((-left, -top), character, font=font, fill=255)
            max_height = max(max_height, height)
        glyphs.append({
            "code": code,
            "image": image,
            "w": width,
            "h": height,
            "bx": left,
            # Distance from the baseline up to the top of the glyph box.
            "by": ascent - top,
            "advance": advance,
            "x": total_width,
        })
        total_width += width
    total_width = max(total_width, 1)
    atlas = Image.new("L", (total_width, max_height), 0)
    for glyph in glyphs:
        if glyph["image"] is not None:
            atlas.paste(glyph["image"], (glyph["x"], 0))
    return font, ascent, descent, glyphs, atlas


def hex_lines(data):
    text = data.hex()
    return ['    "%s"' % text[offset:offset + 96] for offset in range(0, len(text), 96)]


def main():
    output = []
    output.append(
        "/* PGenerator+ Profile Loader UI font atlases.\n"
        " *\n"
        " * Generated from the DejaVu fonts. Do not edit by hand; regenerate with:\n"
        " *\n"
        " *     python3 make-font-header.py\n"
        " *\n"
        " * Each face is an alpha-only atlas laid out as one row of tightly cropped\n"
        " * glyphs for ASCII %d..%d. Metrics are in atlas texels.\n"
        " */\n"
        "\n"
        "#ifndef PGEN_UI_FONT_H\n"
        "#define PGEN_UI_FONT_H\n"
        "\n"
        "#define PGEN_FONT_FIRST_CHAR %d\n"
        "#define PGEN_FONT_LAST_CHAR %d\n"
        "#define PGEN_FONT_GLYPH_COUNT %d\n"
        "\n"
        "typedef struct {\n"
        "    short x, width, height;   /* Position and size inside the atlas */\n"
        "    short bearing_x;          /* Pen offset to the left edge of the box */\n"
        "    short bearing_y;          /* Baseline to the top edge of the box */\n"
        "    float advance;            /* Pen movement for this character */\n"
        "} PgenGlyph;\n"
        "\n"
        "typedef struct {\n"
        "    const char *name;\n"
        "    int atlas_width, atlas_height;\n"
        "    float design_size;        /* Em height of the atlas, in texels */\n"
        "    float ascent, descent, line_height;\n"
        "    const PgenGlyph *glyphs;\n"
        "    const char *alpha_hex;    /* atlas_width * atlas_height alpha bytes */\n"
        "} PgenFace;\n"
        % (FIRST_CHAR, LAST_CHAR, FIRST_CHAR, LAST_CHAR, LAST_CHAR - FIRST_CHAR + 1)
    )

    face_entries = []
    for name, filename, pixel_size in FACES:
        path = os.path.join(FONT_DIR, filename)
        if not os.path.isfile(path):
            sys.stderr.write("missing font: %s\n" % path)
            return 1
        _, ascent, descent, glyphs, atlas = build_face(path, pixel_size)
        lower = name.lower()
        output.append("\nstatic const PgenGlyph pgen_font_%s_glyphs[PGEN_FONT_GLYPH_COUNT] = {" % lower)
        for glyph in glyphs:
            output.append("    {%d,%d,%d,%d,%d,%.4ff}," % (
                glyph["x"], glyph["w"], glyph["h"], glyph["bx"], glyph["by"], glyph["advance"]))
        output.append("};\n")
        output.append("static const char pgen_font_%s_alpha[] =" % lower)
        output.extend(hex_lines(atlas.tobytes()))
        output.append(";\n")
        # design_size and the metrics are in ATLAS TEXELS, so a caller drawing at
        # P points scales by P/design_size and gets exactly P points of em box.
        # pixel_size is chosen at roughly twice the typical point size purely so
        # a 2x display samples the atlas near 1:1; it is not a second scale
        # factor and must never be folded into these numbers.
        face_entries.append(
            '    {"%s", %d, %d, %.4ff, %.4ff, %.4ff, %.4ff, pgen_font_%s_glyphs, pgen_font_%s_alpha},'
            % (name, atlas.width, atlas.height, float(pixel_size),
               float(ascent), float(descent), float(ascent + descent), lower, lower))

    output.append("\ntypedef enum {")
    for index, (name, _, _) in enumerate(FACES):
        output.append("    PGEN_FACE_%s = %d," % (name, index))
    output.append("    PGEN_FACE_COUNT")
    output.append("} PgenFaceId;\n")
    output.append("static const PgenFace pgen_font_faces[PGEN_FACE_COUNT] = {")
    output.extend(face_entries)
    output.append("};\n")
    output.append("#endif")

    with open(TARGET, "w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(output) + "\n")
    sys.stderr.write("wrote %s\n" % TARGET)
    return 0


if __name__ == "__main__":
    sys.exit(main())

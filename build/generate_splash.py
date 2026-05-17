#!/usr/bin/env python3
"""
Generate boot splash framebuffer image for PGenerator+.

Takes Pgenerator+.png logo and creates:
  - build/splash.png  (1920x1080 PNG preview)
  - build/splash.fb   (1920x1080 RGB565 raw framebuffer)

The .fb file is written to /dev/fb0 at boot by rcPGenerator.

Usage:
    python3 build/generate_splash.py
"""

import struct
from pathlib import Path
from PIL import Image

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent
LOGO_PATH = PROJECT_DIR / "Pgenerator+.png"
SPLASH_PNG = SCRIPT_DIR / "splash.png"
SPLASH_FB = SCRIPT_DIR / "splash.fb"

WIDTH, HEIGHT = 1920, 1080
BG_COLOR = (0x10, 0x10, 0x1E)  # dark navy matching web UI


def rgb888_to_rgb565(r, g, b):
    """Convert 8-bit RGB to 16-bit RGB565 (little-endian)."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def main():
    # Create dark background
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BG_COLOR)

    # Open and resize logo to fit nicely (max 60% of screen width, keep aspect)
    logo = Image.open(LOGO_PATH).convert("RGBA")
    max_w = int(WIDTH * 0.6)
    max_h = int(HEIGHT * 0.6)
    ratio = min(max_w / logo.width, max_h / logo.height)
    new_size = (int(logo.width * ratio), int(logo.height * ratio))
    logo = logo.resize(new_size, Image.LANCZOS)

    # Center logo on canvas
    x = (WIDTH - logo.width) // 2
    y = (HEIGHT - logo.height) // 2
    canvas.paste(logo, (x, y), logo)  # use alpha channel as mask

    # Save PNG preview
    canvas.save(SPLASH_PNG)
    print(f"Saved {SPLASH_PNG} ({WIDTH}x{HEIGHT})")

    # Convert to RGB565 raw framebuffer
    pixels = canvas.load()
    fb_data = bytearray(WIDTH * HEIGHT * 2)
    for row in range(HEIGHT):
        for col in range(WIDTH):
            r, g, b = pixels[col, row]
            val = rgb888_to_rgb565(r, g, b)
            offset = (row * WIDTH + col) * 2
            struct.pack_into("<H", fb_data, offset, val)

    with open(SPLASH_FB, "wb") as f:
        f.write(fb_data)
    print(f"Saved {SPLASH_FB} ({len(fb_data)} bytes, RGB565)")


if __name__ == "__main__":
    main()

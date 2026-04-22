#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


SCRIPT_START = "<script>"
SCRIPT_END = "</script>"
SLICE_START = "// D65 reference white chromaticity"
SLICE_END = "function hcfrGreyRef("


def extract_script_block(webui_text: str) -> str:
    start = webui_text.find(SCRIPT_START)
    end = webui_text.rfind(SCRIPT_END)
    if start < 0 or end < 0 or end <= start:
        raise ValueError("Could not locate the main WebUI <script> block")
    return webui_text[start + len(SCRIPT_START) : end]


def extract_meter_math_slice(script_text: str) -> str:
    start = script_text.find(SLICE_START)
    end = script_text.find(SLICE_END)
    if start < 0 or end < 0 or end <= start:
        raise ValueError("Could not locate the meter math slice markers in webui.pm")
    return script_text[start:end].strip() + "\n"


def build_bundle(source_path: Path, slice_text: str) -> str:
    source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()[:12]
    lines = [
        "// Generated file. Do not edit directly.",
        f"// Source: {source_path}",
        f"// Source SHA-256: {source_hash}",
        "// Extracted by tools/extract_webui_meter_math.py",
        "",
        slice_text,
    ]
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract the meter/chart math slice from usr/share/PGenerator/webui.pm"
    )
    parser.add_argument(
        "--input",
        default="usr/share/PGenerator/webui.pm",
        help="Path to webui.pm",
    )
    parser.add_argument(
        "--output",
        default="tests/generated/webui-meter-math.js",
        help="Path to the generated browser bundle",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()

    webui_text = source_path.read_text(encoding="utf-8")
    script_text = extract_script_block(webui_text)
    slice_text = extract_meter_math_slice(script_text)
    bundle_text = build_bundle(source_path, slice_text)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(bundle_text, encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""Rasterize printable ASCII in two sizes with Pillow and store one coverage byte per pixel."""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def rasterize(source, output, width, height, size, baseline):
    font = ImageFont.truetype(str(source), size)
    x = (width - round(font.getlength("0"))) // 2
    coverage = bytearray()
    for code in range(0x20, 0x7F):
        character = chr(code)
        left, top, right, bottom = font.getbbox(character, anchor="ls")
        if not (0 <= x + left <= x + right <= width and 0 <= baseline + top <= baseline + bottom <= height):
            raise ValueError(f"{character!r} does not fit inside {width}x{height}")
        glyph = Image.new("L", (width, height))
        ImageDraw.Draw(glyph).text((x, baseline), character, font=font, anchor="ls", fill=255)
        coverage.extend(glyph.tobytes())
    if not any(0 < value < 255 for value in coverage):
        raise ValueError("expected antialiased coverage")
    (output / f"ui-{width}x{height}.coverage").write_bytes(coverage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("font", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rasterize(args.font, args.output, 8, 14, size=13, baseline=11)
    rasterize(args.font, args.output, 16, 24, size=23, baseline=19)


if __name__ == "__main__":
    main()

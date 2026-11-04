#!/usr/bin/env python3
"""Regenerate Companion brand PNGs from the EP-19 vector sources.

- MenuBarGlyph: monochrome template glyph (black on transparent).
- CompanionBadge: Ember red tile with white sheet + slate pen (window header).

Geometry mirrors Brand.Sources/*.source.svg. Run:
    python3 generate-brand.py
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
ASSETS = HERE.parent / "Assets.xcassets"

EMBER = (178, 58, 46, 255)
SLATE = (31, 41, 55, 255)
FOLD = (239, 233, 222, 255)
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)


def draw_glyph(draw: ImageDraw.ImageDraw, s: float) -> None:
    # 20x20 box; sheet outline
    draw.rounded_rectangle(
        [3.5 * s, 2 * s, 12 * s, 16 * s], radius=2 * s, outline=BLACK, width=max(1, round(2 * s))
    )
    draw.polygon([(8 * s, 2 * s), (12 * s, 2 * s), (12 * s, 6 * s)], fill=BLACK)
    for y in (9.0, 11.8):
        draw.line([5.8 * s, y * s, 9.8 * s, y * s], fill=BLACK, width=max(1, round(1.4 * s)))
    draw.line([10.5 * s, 14.5 * s, 16.5 * s, 4.5 * s], fill=BLACK, width=max(1, round(2 * s)))
    draw.polygon(
        [(10.5 * s, 14.5 * s), (12.4 * s, 13.9 * s), (10.9 * s, 16.2 * s)], fill=BLACK
    )


def render_glyph(px: int) -> Image.Image:
    ss = 8
    scale = px / 18
    box = round(20 * scale * ss)
    img = Image.new("RGBA", (box, box), (0, 0, 0, 0))
    draw_glyph(ImageDraw.Draw(img), ss * scale)
    canvas = Image.new("RGBA", (px * ss, px * ss), (0, 0, 0, 0))
    offset = round((px - 20 * scale) / 2 * ss)
    canvas.alpha_composite(img, (offset, offset))
    return canvas.resize((px, px), Image.LANCZOS)


def draw_badge(draw: ImageDraw.ImageDraw, s: float) -> None:
    # 136 box (mirrors CompanionBadge.source.svg)
    draw.rounded_rectangle([0, 0, 136 * s, 136 * s], radius=32 * s, fill=EMBER)
    draw.rounded_rectangle([41 * s, 26 * s, 95 * s, 110 * s], radius=8 * s, fill=WHITE)
    draw.polygon([(73 * s, 26 * s), (95 * s, 26 * s), (95 * s, 48 * s)], fill=FOLD)
    draw.rounded_rectangle([49 * s, 58 * s, 87 * s, 65 * s], radius=3.5 * s, fill=EMBER)
    draw.rounded_rectangle([49 * s, 72 * s, 79 * s, 79 * s], radius=3.5 * s, fill=EMBER)
    draw.line([88 * s, 34 * s, 52 * s, 96 * s], fill=SLATE, width=max(1, round(12 * s)))
    draw.polygon([(48 * s, 94 * s), (56 * s, 98 * s), (44 * s, 106 * s)], fill=SLATE)


def render_badge(px: int) -> Image.Image:
    ss = 4
    img = Image.new("RGBA", (136 * ss, 136 * ss), (0, 0, 0, 0))
    draw_badge(ImageDraw.Draw(img), ss)
    return img.resize((px, px), Image.LANCZOS)


def main() -> None:
    glyph_dir = ASSETS / "MenuBarGlyph.imageset"
    badge_dir = ASSETS / "CompanionBadge.imageset"
    glyph_dir.mkdir(parents=True, exist_ok=True)
    badge_dir.mkdir(parents=True, exist_ok=True)
    for px in (18, 36):
        render_glyph(px).save(glyph_dir / f"MenuBarGlyph-{px}.png")
        print(f"wrote {glyph_dir / f'MenuBarGlyph-{px}.png'}")
    for px in (34, 68, 102):
        render_badge(px).save(badge_dir / f"CompanionBadge-{px}.png")
        print(f"wrote {badge_dir / f'CompanionBadge-{px}.png'}")


if __name__ == "__main__":
    main()

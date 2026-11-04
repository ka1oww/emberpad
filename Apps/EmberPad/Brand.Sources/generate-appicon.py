#!/usr/bin/env python3
"""Regenerate the EmberPad iPad AppIcon PNG from the EP-19 vector source.

Original art (no stock, no GoodNotes reference): Ember red field, white
worksheet with folded corner and taupe rules, dark-slate pen diagonal.
Geometry matches Brand.Sources/AppIcon.source.svg; this script is the
raster exporter so the icon rebuilds without proprietary tools.

Usage: python3 generate-appicon.py   # writes ../Assets.xcassets/AppIcon.appiconset/
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "Assets.xcassets" / "AppIcon.appiconset"

EMBER = (178, 58, 46, 255)
SLATE = (31, 41, 55, 255)
TAUPE = (156, 138, 120, 255)
FOLD = (239, 233, 222, 255)
CREASE = (216, 205, 189, 255)
WHITE = (255, 255, 255, 255)

# Icon geometry in a 1024 box (mirrors AppIcon.source.svg).
SHEET = (256, 168, 768, 856, 56)
FOLD_PTS = ((608, 168), (768, 168), (768, 328))
CREASE_LINE = ((608, 168), (768, 328), 8)
TITLE = (328, 360, 528, 396, 18)
RULES = [
    (328, 440, 696, 470, 15),
    (328, 520, 696, 550, 15),
    (328, 600, 696, 630, 15),
]
PEN = ((804, 138), (392, 768), 88)
PEN_LIGHT = ((778, 168), (400, 740), 10)
NIB_PTS = ((360, 747), (424, 789), (332, 860))
COLLAR = ((375, 757), (409, 779), 8)


def draw_icon(draw: ImageDraw.ImageDraw, s: float) -> None:
    sc = lambda v: v * s
    draw.rectangle([0, 0, 1024 * s, 1024 * s], fill=EMBER)
    x0, y0, x1, y1, r = SHEET
    draw.rounded_rectangle([sc(x0), sc(y0), sc(x1), sc(y1)], radius=sc(r), fill=WHITE)
    draw.polygon([(sc(x), sc(y)) for x, y in FOLD_PTS], fill=FOLD)
    (ax, ay), (bx, by), w = CREASE_LINE
    draw.line([sc(ax), sc(ay), sc(bx), sc(by)], fill=CREASE, width=max(1, round(sc(w))))
    x0, y0, x1, y1, r = TITLE
    draw.rounded_rectangle([sc(x0), sc(y0), sc(x1), sc(y1)], radius=sc(r), fill=EMBER)
    for x0, y0, x1, y1, r in RULES:
        draw.rounded_rectangle([sc(x0), sc(y0), sc(x1), sc(y1)], radius=sc(r), fill=TAUPE)
    (ax, ay), (bx, by), w = PEN
    draw.line([sc(ax), sc(ay), sc(bx), sc(by)], fill=SLATE, width=round(sc(w)))
    (ax, ay), (bx, by), w = PEN_LIGHT
    draw.line(
        [sc(ax), sc(ay), sc(bx), sc(by)],
        fill=(255, 255, 255, 217),
        width=max(1, round(sc(w))),
    )
    draw.polygon([(sc(x), sc(y)) for x, y in NIB_PTS], fill=SLATE)
    (ax, ay), (bx, by), w = COLLAR
    draw.line([sc(ax), sc(ay), sc(bx), sc(by)], fill=WHITE, width=max(1, round(sc(w))))


def render(size: int, supersample: int = 4) -> Image.Image:
    big = Image.new("RGBA", (size * supersample, size * supersample), EMBER)
    draw_icon(ImageDraw.Draw(big), supersample * size / 1024)
    return big.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    render(1024).convert("RGB").save(OUT / "AppIcon-1024.png")
    print(f"wrote {OUT / 'AppIcon-1024.png'}")


if __name__ == "__main__":
    main()

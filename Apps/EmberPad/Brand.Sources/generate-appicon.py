#!/usr/bin/env python3
"""Regenerate the EmberPad iPad AppIcon PNGs from the EP-74 vector sources.

Art (EP-73 direction 4B navy): the Ember four-point star in Ember red on
brand navy, its bottom point a split pen nib writing a cream ink stroke.
Original art; the star is traced from the Ember Education logo.

The two SVGs in this folder are the authority; this script reads their
geometry and colours directly, so there is nothing to keep in sync:

- ``AppIcon.source.svg``       full design, used for every slot above 40 px.
- ``AppIcon-small.source.svg`` bolder-nib rendition, used for slots of
  40 px and below (20 pt @1x/@2x, 29 pt @1x, 40 pt @1x).

The renderer understands exactly the SVG subset the sources use (a
userSpaceOnUse radialGradient, rect, circle, and paths made of M/L/Z plus
semicircle ``a`` arcs, filled with the nonzero rule, and one clipPath on a
group) and fails loudly on anything else. It needs no proprietary tools,
only Pillow and NumPy (``pip install pillow numpy``).

Usage: python3 generate-appicon.py   # writes ../Assets.xcassets/AppIcon.appiconset/
"""
from __future__ import annotations

import json
import math
import pathlib
import re
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageChops, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "Assets.xcassets" / "AppIcon.appiconset"
FULL_SRC = HERE / "AppIcon.source.svg"
SMALL_SRC = HERE / "AppIcon-small.source.svg"

BOX = 1024  # source viewBox edge
SUPERSAMPLE = 4  # render at 4096 px, then downsample
SMALL_MAX_PX = 40  # slots at or below this pixel size use the small rendition

SVG = "{http://www.w3.org/2000/svg}"

# iPad app icon slots (TARGETED_DEVICE_FAMILY = 2): (idiom, size pt, scale).
SLOTS = [
    ("ipad", 20, 1),
    ("ipad", 20, 2),
    ("ipad", 29, 1),
    ("ipad", 29, 2),
    ("ipad", 40, 1),
    ("ipad", 40, 2),
    ("ipad", 76, 1),
    ("ipad", 76, 2),
    ("ipad", 83.5, 2),
    ("ios-marketing", 1024, 1),
]


def hex_rgb(value: str) -> tuple[int, int, int]:
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})", value.strip())
    if not m:
        raise ValueError(f"unsupported colour {value!r}")
    h = m.group(1)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


# ---------------------------------------------------------------- paths

def path_subpaths(d: str) -> list[list[tuple[float, float]]]:
    """Flatten an SVG path (M/L/Z and semicircle a/A arcs) to polygons."""
    tokens = re.findall(r"[MLZAmlza]|-?\d*\.?\d+(?:[eE][-+]?\d+)?", d)
    subpaths: list[list[tuple[float, float]]] = []
    cur: list[tuple[float, float]] = []
    x = y = 0.0
    i = 0
    cmd = ""

    def num() -> float:
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    while i < len(tokens):
        if re.fullmatch(r"[A-Za-z]", tokens[i]):
            cmd = tokens[i]
            i += 1
        if cmd in "Zz":
            if cur:
                subpaths.append(cur)
            cur = []
            continue
        if cmd in "Mm":
            if cur:
                subpaths.append(cur)
            dx, dy = num(), num()
            x, y = (x + dx, y + dy) if cmd == "m" else (dx, dy)
            cur = [(x, y)]
            cmd = "l" if cmd == "m" else "L"
        elif cmd in "Ll":
            dx, dy = num(), num()
            x, y = (x + dx, y + dy) if cmd == "l" else (dx, dy)
            cur.append((x, y))
        elif cmd in "Aa":
            rx, ry, rot, large, sweep = num(), num(), num(), num(), num()
            ex, ey = num(), num()
            if cmd == "a":
                ex, ey = x + ex, y + ey
            chord = math.hypot(ex - x, ey - y)
            if rx != ry or rot != 0 or abs(chord - 2 * rx) > 1e-6:
                raise ValueError("only semicircle arcs are supported")
            cx, cy = (x + ex) / 2, (y + ey) / 2
            a0 = math.atan2(y - cy, x - cx)
            step = math.pi if sweep else -math.pi
            for k in range(1, 65):
                a = a0 + step * k / 64
                cur.append((cx + rx * math.cos(a), cy + rx * math.sin(a)))
            x, y = ex, ey
        else:
            raise ValueError(f"unsupported path command {cmd!r}")
    if cur:
        subpaths.append(cur)
    return subpaths


def signed_area(poly: list[tuple[float, float]]) -> float:
    return 0.5 * sum(
        x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1])
    )


# ---------------------------------------------------------------- masks

def shape_mask(el: ET.Element, px: int) -> Image.Image:
    """Coverage mask (mode L) of one rect, circle or path at px resolution."""
    s = px / BOX
    mask = Image.new("L", (px, px), 0)
    draw = ImageDraw.Draw(mask)
    tag = el.tag.removeprefix(SVG)
    if tag == "rect":
        x, y = float(el.get("x", 0)), float(el.get("y", 0))
        w, h = float(el.get("width")), float(el.get("height"))
        draw.rectangle([x * s, y * s, (x + w) * s - 1, (y + h) * s - 1], fill=255)
    elif tag == "circle":
        cx, cy, r = (float(el.get(k)) for k in ("cx", "cy", "r"))
        draw.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=255)
    elif tag == "path":
        polys = path_subpaths(el.get("d"))
        # Union is the nonzero fill only when every subpath winds the same way.
        signs = {math.copysign(1, signed_area(p)) for p in polys}
        if len(signs) != 1:
            raise ValueError("mixed-winding paths are not supported")
        for poly in polys:
            draw.polygon([(x * s, y * s) for x, y in poly], fill=255)
    else:
        raise ValueError(f"unsupported shape <{tag}>")
    return mask


def radial_fill(grad: ET.Element, px: int) -> Image.Image:
    if grad.get("gradientUnits") != "userSpaceOnUse":
        raise ValueError("radialGradient must use userSpaceOnUse")
    cx, cy, r = (float(grad.get(k)) for k in ("cx", "cy", "r"))
    stops = [
        (float(st.get("offset")), np.array(hex_rgb(st.get("stop-color")), float))
        for st in grad.findall(f"{SVG}stop")
    ]
    coords = (np.arange(px) + 0.5) * BOX / px
    gx, gy = np.meshgrid(coords, coords)
    t = np.clip(np.hypot(gx - cx, gy - cy) / r, 0.0, 1.0)
    offsets = [o for o, _ in stops]
    rgb = np.stack(
        [np.interp(t, offsets, [c[ch] for _, c in stops]) for ch in range(3)], axis=-1
    )
    return Image.fromarray(np.round(rgb).astype(np.uint8), "RGB")


# ---------------------------------------------------------------- render

def render_svg(path: pathlib.Path, px: int) -> Image.Image:
    root = ET.parse(path).getroot()
    if root.get("viewBox") != f"0 0 {BOX} {BOX}":
        raise ValueError(f"{path.name}: expected a {BOX} viewBox")
    gradients = {g.get("id"): g for g in root.iter(f"{SVG}radialGradient")}
    clips = {c.get("id"): c for c in root.iter(f"{SVG}clipPath")}

    canvas = Image.new("RGB", (px, px), (0, 0, 0))

    def paint(el: ET.Element, clip: Image.Image | None) -> None:
        fill = el.get("fill")
        mask = shape_mask(el, px)
        if clip is not None:
            mask = ImageChops.multiply(mask, clip)
        m = re.fullmatch(r"url\(#(.+)\)", fill or "")
        if m:
            layer = radial_fill(gradients[m.group(1)], px)
        else:
            layer = Image.new("RGB", (px, px), hex_rgb(fill))
        canvas.paste(layer, (0, 0), mask)

    for el in root:
        tag = el.tag.removeprefix(SVG)
        if tag in ("defs", "clipPath"):
            continue
        if tag == "g":
            ref = re.fullmatch(r"url\(#(.+)\)", el.get("clip-path", ""))
            if not ref:
                raise ValueError("only clip-path groups are supported")
            clip = Image.new("L", (px, px), 0)
            for shape in clips[ref.group(1)]:
                clip = ImageChops.lighter(clip, shape_mask(shape, px))
            for child in el:
                paint(child, clip)
        else:
            paint(el, None)
    return canvas


def slot_px(size: float, scale: int) -> int:
    return round(size * scale)


def slot_name(px: int, small: bool) -> str:
    return f"AppIcon-{'small-' if small else ''}{px}.png"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    big = {
        False: render_svg(FULL_SRC, BOX * SUPERSAMPLE),
        True: render_svg(SMALL_SRC, BOX * SUPERSAMPLE),
    }
    for old in OUT.glob("AppIcon-*.png"):
        old.unlink()
    images = []
    written: set[str] = set()
    for idiom, size, scale in SLOTS:
        px = slot_px(size, scale)
        small = px <= SMALL_MAX_PX
        name = slot_name(px, small)
        if name not in written:
            big[small].resize((px, px), Image.LANCZOS).save(OUT / name)
            written.add(name)
            print(f"wrote {OUT / name}")
        size_str = f"{size:g}"
        images.append(
            {
                "filename": name,
                "idiom": idiom,
                "scale": f"{scale}x",
                "size": f"{size_str}x{size_str}",
            }
        )
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {OUT / 'Contents.json'}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Regenerate the Companion brand PNGs from the iPad AppIcon vector sources.

The Companion wears the same mark as the iPad app (EP-73 direction 4B navy:
the Ember four-point star in Ember red on brand navy, its bottom point a split
pen nib writing a cream ink stroke). Nothing is redrawn here: the art comes
from ``Apps/EmberPad/Brand.Sources/AppIcon.source.svg`` and its small-size
rendition ``AppIcon-small.source.svg``, rendered by that folder's
``generate-appicon.py``.

Outputs, all under ``../Assets.xcassets``:

- ``AppIcon.appiconset``  macOS app icon, every slot 16-512 pt @1x/@2x. The
  full-bleed iPad art is masked to the macOS rounded-square plate (824 of
  1024 px, the standard macOS icon-grid margin) with a soft drop shadow. Slots
  of 40 px and below use the small rendition, as the iPad icon does.
- ``CompanionBadge.imageset``  34 pt window-header badge (1x/2x/3x): the same
  star on navy, full-bleed (the view clips it to a rounded rectangle).
- ``MenuBarGlyph.imageset``  18 pt menu-bar template glyph (1x/2x): the star
  silhouette with its pen-nib vent and slit cut out, black on transparent. macOS tints it for light
  and dark menu bars through the imageset's ``template-rendering-intent``.
  ``MenuBarGlyph.source.svg`` is written alongside as its vector record.

Needs Pillow and NumPy (``pip install pillow numpy``). Run:
    python3 generate-brand.py
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
ASSETS = HERE.parent / "Assets.xcassets"
IPAD_SOURCES = HERE.parent.parent / "EmberPad" / "Brand.Sources"
GLYPH_SVG = HERE / "MenuBarGlyph.source.svg"


def load_ipad_renderer():
    sys.dont_write_bytecode = True  # keep __pycache__ out of the iPad folder
    spec = importlib.util.spec_from_file_location(
        "generate_appicon", IPAD_SOURCES / "generate-appicon.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


APPICON = load_ipad_renderer()
BOX = APPICON.BOX  # 1024 source viewBox
SUPERSAMPLE = APPICON.SUPERSAMPLE
SMALL_MAX_PX = APPICON.SMALL_MAX_PX
FULL_SRC = APPICON.FULL_SRC
SMALL_SRC = APPICON.SMALL_SRC
SVG = APPICON.SVG

# macOS icon grid (1024 canvas): 824 px rounded-square plate centred with a
# 100 px margin, corner radius 185.4 px, soft shadow below the plate.
PLATE = 824
MARGIN = (BOX - PLATE) // 2
CORNER = 185.4
SHADOW_ALPHA = 0.30
SHADOW_BLUR = 10  # px at 1024
SHADOW_DY = 10  # px at 1024

# macOS app icon slots: (size pt, scale).
MAC_SLOTS = [(s, k) for s in (16, 32, 128, 256, 512) for k in (1, 2)]

BADGE_PT = 34
GLYPH_PT = 18
GLYPH_STAR_PT = 15.6  # star height inside the 18 pt box, before emboldening
GLYPH_BOLD_PT = 0.5  # outward stroke so the thin star arms read at 18 pt
GLYPH_SLIT_REACH = 0.6  # slit runs this fraction of the way from vent to tip


# ---------------------------------------------------------------- source art

def star_and_nib(path: pathlib.Path):
    """Star polygon and nib (slit rect, vent circle) from an AppIcon source."""
    root = ET.parse(path).getroot()
    star = None
    for clip in root.iter(f"{SVG}clipPath"):
        (shape,) = list(clip)
        (star,) = APPICON.path_subpaths(shape.get("d"))
    group = next(el for el in root if el.tag == f"{SVG}g")
    rect = next(el for el in group if el.tag == f"{SVG}rect")
    circle = next(el for el in group if el.tag == f"{SVG}circle")
    slit = tuple(float(rect.get(k)) for k in ("x", "y", "width", "height"))
    vent = tuple(float(circle.get(k)) for k in ("cx", "cy", "r"))
    if star is None:
        raise ValueError(f"{path.name}: no star clipPath")
    return star, slit, vent


# ---------------------------------------------------------------- app icon

def plate_mask(px: int) -> Image.Image:
    s = px / BOX
    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [MARGIN * s, MARGIN * s, (MARGIN + PLATE) * s - 1, (MARGIN + PLATE) * s - 1],
        radius=CORNER * s,
        fill=255,
    )
    return mask


def render_mac_icon(art: Image.Image) -> Image.Image:
    """Mask full-bleed art (any size) onto the macOS plate, with a shadow."""
    px = art.width
    s = px / BOX
    plate_px = round(PLATE * s)
    inset = art.resize((plate_px, plate_px), Image.LANCZOS)
    layer = Image.new("RGB", (px, px), (0, 0, 0))
    layer.paste(inset, (round(MARGIN * s), round(MARGIN * s)))
    mask = plate_mask(px)

    shadow_mask = ImageChops.offset(mask, 0, round(SHADOW_DY * s)).filter(
        ImageFilter.GaussianBlur(SHADOW_BLUR * s)
    )
    shadow_alpha = shadow_mask.point(lambda v: round(v * SHADOW_ALPHA))
    icon = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    icon.paste(Image.new("RGBA", (px, px), (0, 0, 0, 255)), (0, 0), shadow_alpha)
    plate = layer.convert("RGBA")
    plate.putalpha(mask)
    icon.alpha_composite(plate)
    return icon


def write_app_icon(big_mac: dict[bool, Image.Image]) -> None:
    out = ASSETS / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("AppIcon-*.png"):
        old.unlink()
    images = []
    written: set[str] = set()
    for size, scale in MAC_SLOTS:
        px = size * scale
        small = px <= SMALL_MAX_PX
        name = APPICON.slot_name(px, small)
        if name not in written:
            big_mac[small].resize((px, px), Image.LANCZOS).save(out / name)
            written.add(name)
            print(f"wrote {out / name}")
        images.append(
            {"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"}
        )
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (out / "Contents.json").write_text(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")
    print(f"wrote {out / 'Contents.json'}")


# ---------------------------------------------------------------- badge

def write_badge(big_art: dict[bool, Image.Image]) -> None:
    out = ASSETS / "CompanionBadge.imageset"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("CompanionBadge-*.png"):
        old.unlink()
    images = []
    for scale in (1, 2, 3):
        px = BADGE_PT * scale
        name = f"CompanionBadge-{px}.png"
        big_art[px <= SMALL_MAX_PX].resize((px, px), Image.LANCZOS).save(out / name)
        print(f"wrote {out / name}")
        images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (out / "Contents.json").write_text(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")


# ---------------------------------------------------------------- menu-bar glyph

def glyph_geometry():
    """Star silhouette and nib cut-outs in 18 pt glyph coordinates, from the
    small rendition (its bolder nib reads better at menu-bar size)."""
    star, (sx, sy, sw, _sh), (vx, vy, vr) = star_and_nib(SMALL_SRC)
    ys = [y for _, y in star]
    xs = [x for x, _ in star]
    k = GLYPH_STAR_PT / (max(ys) - min(ys))
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2

    def t(x: float, y: float) -> tuple[float, float]:
        return (GLYPH_PT / 2 + (x - cx) * k, GLYPH_PT / 2 + (y - cy) * k)

    outline = [t(x, y) for x, y in star]
    tip = max(y for _, y in star)
    slit = (*t(sx, sy), sw * k, (tip - sy) * GLYPH_SLIT_REACH * k)
    vent = (*t(vx, vy), vr * k)
    return outline, slit, vent


def write_glyph_svg() -> None:
    outline, (rx, ry, rw, rh), (vx, vy, vr) = glyph_geometry()
    pts = " ".join(f"{x:.3f},{y:.3f}" for x, y in outline)
    GLYPH_SVG.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {GLYPH_PT} {GLYPH_PT}">\n'
        "  <!-- EmberPad Companion menu-bar template glyph: the Ember star silhouette with its pen-nib vent and slit cut out. -->\n"
        "  <!-- Derived from Apps/EmberPad/Brand.Sources/AppIcon-small.source.svg; written by generate-brand.py, do not hand-edit. -->\n"
        '  <defs><mask id="nib"><rect width="18" height="18" fill="#FFFFFF"/>'
        f'<rect x="{rx:.3f}" y="{ry:.3f}" width="{rw:.3f}" height="{rh:.3f}" fill="#000000"/>'
        f'<circle cx="{vx:.3f}" cy="{vy:.3f}" r="{vr:.3f}" fill="#000000"/></mask></defs>\n'
        f'  <polygon points="{pts}" fill="#000000" stroke="#000000" stroke-width="{2 * GLYPH_BOLD_PT}"'
        ' stroke-linejoin="round" mask="url(#nib)"/>\n'
        "</svg>\n"
    )
    print(f"wrote {GLYPH_SVG}")


def render_glyph(px: int) -> Image.Image:
    ss = 16
    s = px / GLYPH_PT * ss
    outline, (rx, ry, rw, rh), (vx, vy, vr) = glyph_geometry()
    alpha = Image.new("L", (px * ss, px * ss), 0)
    draw = ImageDraw.Draw(alpha)
    pts = [(x * s, y * s) for x, y in outline]
    bold = round(2 * GLYPH_BOLD_PT * s)
    draw.polygon(pts, fill=255)
    draw.line(pts + pts[:1], fill=255, width=bold, joint="curve")
    for x, y in pts:  # round joins
        draw.ellipse([x - bold / 2, y - bold / 2, x + bold / 2, y + bold / 2], fill=255)
    draw.rectangle([rx * s, ry * s, (rx + rw) * s - 1, (ry + rh) * s - 1], fill=0)
    draw.ellipse([(vx - vr) * s, (vy - vr) * s, (vx + vr) * s, (vy + vr) * s], fill=0)
    img = Image.new("RGBA", alpha.size, (0, 0, 0, 0))
    img.paste(Image.new("RGBA", alpha.size, (0, 0, 0, 255)), (0, 0), alpha)
    return img.resize((px, px), Image.LANCZOS)


def write_glyph() -> None:
    out = ASSETS / "MenuBarGlyph.imageset"
    out.mkdir(parents=True, exist_ok=True)
    for px in (GLYPH_PT, GLYPH_PT * 2):
        render_glyph(px).save(out / f"MenuBarGlyph-{px}.png")
        print(f"wrote {out / f'MenuBarGlyph-{px}.png'}")
    write_glyph_svg()


# ---------------------------------------------------------------- main

def main() -> None:
    big_art = {
        False: APPICON.render_svg(FULL_SRC, BOX * SUPERSAMPLE),
        True: APPICON.render_svg(SMALL_SRC, BOX * SUPERSAMPLE),
    }
    big_mac = {small: render_mac_icon(art) for small, art in big_art.items()}
    write_app_icon(big_mac)
    write_badge(big_art)
    write_glyph()


if __name__ == "__main__":
    main()

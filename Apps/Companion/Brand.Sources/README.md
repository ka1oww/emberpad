# Companion brand sources (EP-19)

Original artwork, Ember House palette, no outside material.

- `MenuBarGlyph.source.svg` — monochrome template glyph (20pt box, black
  on transparent); macOS renders it via the imageset's
  `template-rendering-intent`.
- `CompanionBadge.source.svg` — 34pt window-header badge (Ember red tile,
  white sheet, slate pen), matching design 5.7.
- `generate-brand.py` — raster exporter (Pillow): `python3 generate-brand.py`
  writes the `MenuBarGlyph` and `CompanionBadge` imagesets.

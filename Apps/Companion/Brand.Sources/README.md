# Companion brand sources

The Companion wears the iPad app's mark (EP-73 direction 4B navy: the Ember
four-point star in Ember red on brand navy, its bottom point a split pen nib
writing a cream ink stroke). The vector authority is
`Apps/EmberPad/Brand.Sources/AppIcon.source.svg` and its small rendition
`AppIcon-small.source.svg`; nothing is redrawn here.

- `generate-brand.py` — raster exporter (needs Pillow and NumPy; reuses the
  iPad folder's `generate-appicon.py` renderer). Running
  `python3 generate-brand.py` rewrites, under `../Assets.xcassets/`:
  - `AppIcon.appiconset` — the macOS app icon, every slot 16-512 pt @1x/@2x:
    the iPad art masked to the macOS rounded-square plate (824 of 1024 px)
    with a soft drop shadow; slots of 40 px and below use the small rendition.
  - `CompanionBadge.imageset` — the 34 pt window-header badge, the same star
    on navy (the view clips it to a rounded rectangle).
  - `MenuBarGlyph.imageset` — the 18 pt menu-bar template glyph: the star
    silhouette, slightly emboldened, with the nib vent and slit cut out.
    Black on transparent; macOS tints it via `template-rendering-intent`.
- `MenuBarGlyph.source.svg` — vector record of the menu-bar glyph, written
  by `generate-brand.py` (do not hand-edit).

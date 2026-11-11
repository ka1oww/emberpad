# EmberPad AppIcon sources (EP-74)

Original artwork (EP-73 direction 4B navy): the Ember four-point star in
Ember red on brand navy, its bottom point a split pen nib writing a cream
ink stroke. The star is traced from the Ember Education logo.

- `AppIcon.source.svg` — the full design, the vector authority (1024 box,
  full-bleed; iOS applies the rounded mask). Used for every slot above 40 px.
- `AppIcon-small.source.svg` — the small-size rendition with a bolder nib,
  used for slots of 40 px and below.
- `generate-appicon.py` — raster exporter (needs Pillow and NumPy). Running
  `python3 generate-appicon.py` reads both SVGs and rewrites
  `../Assets.xcassets/AppIcon.appiconset/` (every iPad slot plus
  `Contents.json`).

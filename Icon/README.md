# App icon

Variant 2a: red grooved disc on a black squircle.

`AppIcon.iconset/` is the source. `Scripts/make-app.sh` runs `iconutil` over it
and writes `Contents/Resources/AppIcon.icns` into the bundle, so the `.icns` is
a build product and is not tracked.

| File | Pixels |
|---|---|
| `icon_16x16.png` | 16 |
| `icon_16x16@2x.png`, `icon_32x32.png` | 32 |
| `icon_32x32@2x.png` | 64 |
| `icon_128x128.png` | 128 |
| `icon_128x128@2x.png`, `icon_256x256.png` | 256 |
| `icon_256x256@2x.png`, `icon_512x512.png` | 512 |
| `icon_512x512@2x.png` | 1024 |

The `@2x` name and the plain name one step up are the same image at the same
pixel size — that duplication is what the `.iconset` format expects, not a
mistake. `icon_512x512@2x.png` doubles as the 1024 master.

To build one by hand:

```bash
iconutil -c icns Icon/AppIcon.iconset -o AppIcon.icns
```

## Notes on the artwork

Corners are transparent and the squircle is baked into the artwork, as
`.iconset` expects. No drop shadow is baked in; macOS adds one.

Groove detail is coarsened at 128 and 64 and removed at 32 and 16, so the small
renderings stay legible rather than turning into moiré.

## If Xcode arrives

An asset catalog needs `actool`, which ships with Xcode rather than Command
Line Tools — hence `.icns`, which `iconutil` can build here today. With Xcode,
drop these PNGs into the `AppIcon` catalog slots of matching size instead.

On macOS 26 and later, Icon Composer takes `icon_512x512@2x.png` as a single
full-bleed layer and applies the mask, shadow and appearance variants itself.

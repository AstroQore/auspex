# Auspex Icon Composer layers

The artwork is grouped for Apple's Icon Composer workflow on a 1024 × 1024
canvas. Import one appearance folder at a time; its numbered child folders
become groups and sort from back to front.

```text
Default/                         Dark/                           Mono/
├── 01-Background/              ├── 01-Background/              ├── 01-Background/
│   └── 01-background.png       │   └── 01-background.png       │   └── 01-background.png
├── 02-Bird/                    ├── 02-Bird/                    ├── 02-Bird/
│   └── 01-pixel-bird.png       │   └── 01-pixel-bird.png       │   └── 01-pixel-bird.png
└── 03-Status/                  └── 03-Status/                  └── 03-Status/
    ├── 01-blue.png                 ├── 01-blue.png                 ├── 01-blue.png
    ├── 02-amber.png                ├── 02-amber.png                ├── 02-amber.png
    └── 03-green.png                └── 03-green.png                └── 03-green.png
```

Recommended group settings:

- `01-Background`: Combined; Liquid Glass effects off; full-bleed and opaque.
- `02-Bird`: Combined; effects on; blur 0; translucency 0; use Icon Composer's
  system specular/refraction controls instead of baked effects.
- `03-Status`: Individual, so the three status lamps remain separate glass
  pieces; blur 0; translucency 0.

The sources intentionally contain no rounded-square mask, bezel, glow, blur,
cast shadow, or baked specular highlight. Icon Composer and macOS apply the
platform crop and material effects. The flattened PNGs beside this directory
are previews/fallbacks, not import groups.

Apple guidance:

- https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer
- https://developer.apple.com/design/human-interface-guidelines/app-icons/

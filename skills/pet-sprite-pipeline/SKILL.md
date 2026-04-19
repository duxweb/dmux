---
name: pet-sprite-pipeline
description: Use when rebuilding or importing pet sprite assets: processing numbered PNG sequences into sprite sheets, updating animation timing metadata, or wiring new bundled sprite files into the dmux pet UI.
---

# Pet Sprite Pipeline

Use this only for asset pipeline work. For pet gameplay rules or UI behavior, read `skills/dmux-pet-system/SKILL.md`.

## Directory Layout

```
scripts/pet-sprites/
├── bg_remove.py           # BFS background removal + palette quantization (shared lib)
├── seq_to_sprite.py       # Directory of numbered PNGs → sprite sheet PNG + JSON
├── image_to_sprite.py     # Single PNG → single-frame sprite sheet
├── process_voidcat.py     # Run this to rebuild voidcat sprites
├── process_rusthound.py
├── process_goose.py
└── process_chaossprite.py

Sources/DmuxWorkspace/Resources/Pets/
└── <species>/
    ├── egg.png / egg.json
    ├── infant_idle.png / infant_idle.json
    ├── child_idle.png / child_idle.json
    ├── adult_idle.png / adult_idle.json
    └── evo_* / mega_* sprite sheets
```

## Sprite Sheet Format

Each PNG is a horizontal strip of frames. JSON with the same stem stores clip metadata beside it.

Raw source files live under `RawAssets/Pets/<species>/...`.

## Rebuild commands

```bash
cd /Volumes/Web/未命名文件夹
python3 scripts/pet-sprites/process_voidcat.py
python3 scripts/pet-sprites/process_rusthound.py
python3 scripts/pet-sprites/process_goose.py
python3 scripts/pet-sprites/process_chaossprite.py
```

The processors write directly into `Sources/DmuxWorkspace/Resources/Pets/<species>/`.

## Processor expectations

- Sequence processors expect numbered PNG frames in the raw asset directory.
- `image_to_sprite.py` is used for single-frame assets like eggs.
- Main tuning knobs:
  - `size`
  - `duration`
  - `tolerance`
  - `alpha_erode`
  - `num_colors`
  - `content_pct`

## After rebuilding

1. Verify output files landed in `Sources/DmuxWorkspace/Resources/Pets/<species>/`.
2. Rebuild the app:
   - `swift build`
   - or `./dev.sh`
3. Check the target animation in the dev app pet popover.

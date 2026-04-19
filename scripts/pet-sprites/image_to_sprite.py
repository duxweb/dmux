#!/usr/bin/env python3
"""静态图 -> 调色盘量化 PNG sprite sheet + JSON。
BFS 去白底 + 64 色自动调色盘,消除白边,保留像素风硬边。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bg_remove import remove_white_bg, build_shared_palette, apply_palette


def center_crop(img: Image.Image, ratio: float) -> Image.Image:
    w, h = img.size
    nw, nh = int(w * ratio), int(h * ratio)
    left = (w - nw) // 2
    top  = (h - nh) // 2
    return img.crop((left, top, left + nw, top + nh))


def crop_and_fit(rgba: Image.Image, target: int, content_pct: float) -> Image.Image:
    bbox = rgba.getbbox()
    if bbox is None:
        raise ValueError("没有非透明像素")
    cropped = rgba.crop(bbox)
    cw, ch = cropped.size
    max_c = int(target * content_pct)
    scale = min(max_c / max(cw, 1), max_c / max(ch, 1))
    nw = max(1, round(cw * scale))
    nh = max(1, round(ch * scale))

    inter_w = min(cw, target * 4)
    inter_h = int(ch * inter_w / max(cw, 1))
    mid   = cropped.resize((inter_w, inter_h), Image.Resampling.LANCZOS)
    sized = mid.resize((nw, nh), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (target, target), (0, 0, 0, 0))
    canvas.paste(sized, ((target - nw) // 2, (target - nh) // 2), sized)
    return canvas


def image_to_sprite(img_path: Path, output_png: Path, output_json: Path,
                    state: str, size: int, duration_ms: int,
                    tolerance: int, center_crop_ratio: float,
                    content_pct: float, num_colors: int = 64,
                    internal_island_min_area: int = 0,
                    internal_island_rules: list[dict] | None = None) -> None:
    img = Image.open(img_path).convert("RGB")
    if center_crop_ratio < 1.0:
        img = center_crop(img, center_crop_ratio)
    rgba   = remove_white_bg(
        img,
        tolerance=tolerance,
        internal_island_min_area=internal_island_min_area,
        internal_island_rules=internal_island_rules,
    )
    fitted = crop_and_fit(rgba, size, content_pct)

    palette_ref = build_shared_palette([fitted], num_colors)
    quantized   = apply_palette(fitted, palette_ref)

    output_png.parent.mkdir(parents=True, exist_ok=True)
    quantized.save(str(output_png), "PNG")

    meta = {
        "frame_size": [size, size],
        "frame_count": 1,
        "fullcolor": False,
        "num_colors": num_colors,
        "frames": [{"name": f"{state}_0", "duration_ms": duration_ms,
                    "x": 0, "y": 0, "w": size, "h": size}],
        "clip": output_png.stem,
    }
    output_json.write_text(
        json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  [ok] {img_path.name} -> {output_png.name} ({size}x{size}px, {num_colors}色)")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("--output-png",  required=True)
    p.add_argument("--output-json", required=True)
    p.add_argument("--state",        default="egg")
    p.add_argument("--size",         type=int,   default=256)
    p.add_argument("--duration",     type=int,   default=800)
    p.add_argument("--tolerance",    type=int,   default=30)
    p.add_argument("--center-crop",  type=float, default=0.92)
    p.add_argument("--content-pct",  type=float, default=0.85)
    p.add_argument("--num-colors",   type=int,   default=64)
    p.add_argument("--internal-island-min-area", type=int, default=0)
    p.add_argument("--internal-rules-json", default="")
    args = p.parse_args()

    rules = json.loads(args.internal_rules_json) if args.internal_rules_json else None

    image_to_sprite(
        img_path=Path(args.image).expanduser().resolve(),
        output_png=Path(args.output_png).expanduser().resolve(),
        output_json=Path(args.output_json).expanduser().resolve(),
        state=args.state,
        size=args.size,
        duration_ms=args.duration,
        tolerance=args.tolerance,
        center_crop_ratio=args.center_crop,
        content_pct=args.content_pct,
        num_colors=args.num_colors,
        internal_island_min_area=args.internal_island_min_area,
        internal_island_rules=rules,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

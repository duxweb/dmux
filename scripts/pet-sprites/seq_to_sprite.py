#!/usr/bin/env python3
"""图片序列目录 -> 调色盘量化 PNG sprite sheet + JSON。
读取目录下数字命名的 PNG 帧（1.png, 2.png … 或 01.png …），
BFS 去白底 + 共享调色盘量化，跳过非数字文件名。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bg_remove import remove_white_bg, build_shared_palette, apply_palette


def erode_alpha(rgba: Image.Image, pixels: int) -> Image.Image:
    """对 alpha 通道做 N 像素腐蚀，消除抗锯齿白边残留。"""
    if pixels <= 0:
        return rgba
    alpha = rgba.split()[3]
    for _ in range(pixels):
        alpha = alpha.filter(ImageFilter.MinFilter(3))
    r, g, b, _ = rgba.split()
    return Image.merge("RGBA", (r, g, b, alpha))


def center_crop(img: Image.Image, ratio: float) -> Image.Image:
    w, h = img.size
    nw, nh = int(w * ratio), int(h * ratio)
    left = (w - nw) // 2
    top  = (h - nh) // 2
    return img.crop((left, top, left + nw, top + nh))


def compute_union_bbox(rgbas: list[Image.Image],
                       pad: int) -> tuple[int, int, int, int]:
    union = None
    for rgba in rgbas:
        b = rgba.getbbox()
        if b is None:
            continue
        union = b if union is None else (
            min(union[0], b[0]), min(union[1], b[1]),
            max(union[2], b[2]), max(union[3], b[3]),
        )
    if union is None:
        raise ValueError("所有帧都没有非透明内容")
    w, h = rgbas[0].size
    return (max(0, union[0] - pad), max(0, union[1] - pad),
            min(w, union[2] + pad), min(h, union[3] + pad))


def fit_to_square(rgba: Image.Image, bbox: tuple[int, int, int, int],
                  target: int, content_pct: float) -> Image.Image:
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


def seq_to_sprite(seq_dir: Path, output_png: Path, output_json: Path,
                  state: str, size: int, duration_ms: int,
                  tolerance: int, center_crop_ratio: float,
                  bbox_pad: int, content_pct: float,
                  num_colors: int = 128, alpha_erode: int = 1,
                  internal_island_min_area: int = 0,
                  internal_island_rules: list[dict] | None = None,
                  max_frames: int = 0) -> None:
    # 只取文件名为纯数字的 PNG，按数值排序
    frame_paths = sorted(
        [p for p in seq_dir.glob("*.png") if p.stem.isdigit()],
        key=lambda p: int(p.stem),
    )
    if max_frames > 0:
        frame_paths = frame_paths[:max_frames]
    if not frame_paths:
        print(f"  [skip 无数字 PNG] {seq_dir.name}/")
        return
    print(f"  找到 {len(frame_paths)} 帧: {[p.name for p in frame_paths]}")

    print("  去背中 (BFS)...")
    rgbas: list[Image.Image] = []
    for fp in frame_paths:
        img = Image.open(fp).convert("RGB")
        if center_crop_ratio < 1.0:
            img = center_crop(img, center_crop_ratio)
        rgba = remove_white_bg(
            img,
            tolerance=tolerance,
            internal_island_min_area=internal_island_min_area,
            internal_island_rules=internal_island_rules,
        )
        rgba = erode_alpha(rgba, alpha_erode)
        rgbas.append(rgba)

    union = compute_union_bbox(rgbas, pad=bbox_pad)
    print(f"  union bbox = {union} "
          f"(尺寸 {union[2]-union[0]}×{union[3]-union[1]})")

    fitted: list[Image.Image] = [
        fit_to_square(rgba, union, size, content_pct) for rgba in rgbas
    ]

    print(f"  量化调色盘 ({num_colors} 色)...")
    palette_ref = build_shared_palette(fitted, num_colors)
    quantized   = [apply_palette(fr, palette_ref) for fr in fitted]

    sheet = Image.new("RGBA", (size * len(quantized), size), (0, 0, 0, 0))
    meta_frames = []
    for i, fr in enumerate(quantized):
        x = i * size
        sheet.paste(fr, (x, 0))
        meta_frames.append({
            "name": f"{state}_{i}",
            "duration_ms": duration_ms,
            "x": x, "y": 0, "w": size, "h": size,
        })

    output_png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(str(output_png), "PNG")

    meta = {
        "frame_size": [size, size],
        "frame_count": len(quantized),
        "fullcolor": False,
        "num_colors": num_colors,
        "frames": meta_frames,
        "clip": output_png.stem,
    }
    output_json.write_text(
        json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  [ok] -> {output_png.name} ({len(quantized)} 帧, {size}x{size}px, {num_colors}色)")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("seq_dir", help="包含数字命名 PNG 帧的目录")
    p.add_argument("--output-png",  required=True)
    p.add_argument("--output-json", required=True)
    p.add_argument("--state",        default="idle")
    p.add_argument("--size",         type=int,   default=256)
    p.add_argument("--duration",     type=int,   default=150)
    p.add_argument("--tolerance",    type=int,   default=30)
    p.add_argument("--center-crop",  type=float, default=0.85)
    p.add_argument("--bbox-pad",     type=int,   default=6)
    p.add_argument("--content-pct",  type=float, default=0.85)
    p.add_argument("--num-colors",   type=int,   default=128)
    p.add_argument("--alpha-erode",  type=int,   default=1)
    p.add_argument("--internal-island-min-area", type=int, default=0)
    p.add_argument("--internal-rules-json", default="")
    p.add_argument("--max-frames",   type=int,   default=0,
                   help="最多读取前N帧，0=全部")
    args = p.parse_args()

    rules = json.loads(args.internal_rules_json) if args.internal_rules_json else None

    seq_to_sprite(
        seq_dir=Path(args.seq_dir).expanduser().resolve(),
        output_png=Path(args.output_png).expanduser().resolve(),
        output_json=Path(args.output_json).expanduser().resolve(),
        state=args.state,
        size=args.size,
        duration_ms=args.duration,
        tolerance=args.tolerance,
        center_crop_ratio=args.center_crop,
        bbox_pad=args.bbox_pad,
        content_pct=args.content_pct,
        num_colors=args.num_colors,
        alpha_erode=args.alpha_erode,
        internal_island_min_area=args.internal_island_min_area,
        internal_island_rules=rules,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

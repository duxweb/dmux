#!/usr/bin/env python3
"""一键处理墨瞳猫全部素材 -> 调色盘量化 PNG sprite sheet + JSON"""

from __future__ import annotations
import subprocess, sys
from pathlib import Path

TOOLS     = Path(__file__).resolve().parent
REPO_ROOT = TOOLS.parent.parent          # /Volumes/Web/未命名文件夹
ASSETS    = REPO_ROOT / "RawAssets/Pets/voidcat"
OUTPUT    = REPO_ROOT / "Sources/DmuxWorkspace/Resources/Pets/voidcat"

def run(cmd: list[str]) -> None:
    print(" ".join(str(c) for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("STDERR:", r.stderr[-800:], file=sys.stderr)
        raise RuntimeError(f"命令失败: {cmd[0]}")
    if r.stdout.strip():
        print(r.stdout.strip())

def seq2s(dirname: str, state: str, size: int, dur_ms: int,
          content_pct: float = 0.85, num_colors: int = 128,
          tolerance: int = 30, alpha_erode: int = 1) -> None:
    src = ASSETS / dirname
    if not src.exists():
        print(f"  [skip 不存在] {dirname}/")
        return
    stem = dirname.replace("voidcat_", "")
    run([
        sys.executable, str(TOOLS / "seq_to_sprite.py"),
        str(src),
        "--output-png",  str(OUTPUT / f"{stem}.png"),
        "--output-json", str(OUTPUT / f"{stem}.json"),
        "--state",       state,
        "--size",        str(size),
        "--duration",    str(dur_ms),
        "--tolerance",   str(tolerance),
        "--center-crop", "0.85",
        "--bbox-pad",    "6",
        "--content-pct", str(content_pct),
        "--num-colors",  str(num_colors),
        "--alpha-erode", str(alpha_erode),
    ])

def i2s(png: str, state: str, size: int, dur_ms: int = 800,
        num_colors: int = 128) -> None:
    src = ASSETS / png
    if not src.exists():
        print(f"  [skip 不存在] {png}")
        return
    stem = png.replace("voidcat_", "").replace(".png", "")
    run([
        sys.executable, str(TOOLS / "image_to_sprite.py"),
        str(src),
        "--output-png",  str(OUTPUT / f"{stem}.png"),
        "--output-json", str(OUTPUT / f"{stem}.json"),
        "--state",       state,
        "--size",        str(size),
        "--duration",    str(dur_ms),
        "--tolerance",   "30",
        "--center-crop", "0.92",
        "--content-pct", "0.85",
        "--num-colors",  str(num_colors),
    ])

OUTPUT.mkdir(parents=True, exist_ok=True)

# ── 静态图 ──────────────────────────────────────────────────────────────────
i2s("voidcat_egg.png",              "egg",   256)

# ── 图片序列:幼年 / 成长 / 成年 ──────────────────────────────────────────────
seq2s("voidcat_infant_idle",        "idle",  256, dur_ms=625, tolerance=45, alpha_erode=2)
seq2s("voidcat_child_idle",         "idle",  320, dur_ms=625)
seq2s("voidcat_adult_idle",         "idle",  320, dur_ms=750)

# ── 进化 A ────────────────────────────────────────────────────────────────
seq2s("voidcat_evo_a_idle",         "idle",  384, dur_ms=600)
seq2s("voidcat_evo_a_sleep",        "sleep", 384, dur_ms=625)

# ── 进化 B ────────────────────────────────────────────────────────────────
seq2s("voidcat_evo_b_idle",         "idle",  384, dur_ms=600)
seq2s("voidcat_evo_b_sleep",        "sleep", 384, dur_ms=625)

# ── 超进化:特效填满全帧,content_pct 调高避免裁剪 ──────────────────────────
seq2s("voidcat_mega_a_idle",        "idle",  512, dur_ms=600,
      content_pct=0.95, num_colors=160)
seq2s("voidcat_mega_a_sleep",       "sleep", 512, dur_ms=625,
      content_pct=0.95, num_colors=160)
seq2s("voidcat_mega_b_idle",        "idle",  512, dur_ms=600,
      content_pct=0.95, num_colors=160)
seq2s("voidcat_mega_b_sleep",       "sleep", 512, dur_ms=625,
      content_pct=0.95, num_colors=160)

print("\n✓ 完成。输出目录:", OUTPUT)

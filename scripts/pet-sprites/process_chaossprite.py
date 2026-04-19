#!/usr/bin/env python3
"""一键处理混沌精全部素材 -> 调色盘量化 PNG sprite sheet + JSON"""

from __future__ import annotations
import json
import subprocess, sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
REPO_ROOT = TOOLS.parent.parent
ASSETS = REPO_ROOT / "RawAssets/Pets/chaossprite"
OUTPUT = REPO_ROOT / "Sources/DmuxWorkspace/Resources/Pets/chaossprite"

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
          tolerance: int = 30, alpha_erode: int = 1,
          internal_island_min_area: int = 0,
          internal_rules: list[dict] | None = None) -> None:
    src = ASSETS / dirname
    if not src.exists():
        print(f"  [skip 不存在] {dirname}/")
        return
    stem = dirname.replace("chaossprite_", "")
    cmd = [
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
        "--internal-island-min-area", str(internal_island_min_area),
    ]
    if internal_rules:
        cmd.extend(["--internal-rules-json", json.dumps(internal_rules, ensure_ascii=True)])
    run(cmd)

def i2s(png: str, state: str, size: int, dur_ms: int = 800,
        num_colors: int = 128, internal_island_min_area: int = 0) -> None:
    src = ASSETS / png
    if not src.exists():
        print(f"  [skip 不存在] {png}")
        return
    stem = png.replace("chaossprite_", "").replace(".png", "")
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
        "--internal-island-min-area", str(internal_island_min_area),
    ])

OUTPUT.mkdir(parents=True, exist_ok=True)

i2s("chaossprite_egg.png", "egg", 256)

seq2s("chaossprite_infant_idle", "idle", 256, dur_ms=625, tolerance=45, alpha_erode=2)
seq2s("chaossprite_child_idle", "idle", 320, dur_ms=625, internal_island_min_area=10000)
seq2s("chaossprite_adult_idle", "idle", 320, dur_ms=750, internal_island_min_area=10000)

seq2s("chaossprite_evo_idle", "idle", 384, dur_ms=600,
      internal_island_min_area=100,
      internal_rules=[
          {"min_area": 100000, "max_area": 250000, "rect": [300, 850, 850, 1250]},
          {"min_area": 100000, "max_area": 250000, "rect": [1200, 850, 1750, 1250]},
      ])
seq2s("chaossprite_evo_sleep", "sleep", 384, dur_ms=625)
seq2s("chaossprite_mega_idle", "idle", 512, dur_ms=600,
      content_pct=0.95, num_colors=160,
      internal_rules=[
          {"min_area": 30000, "max_area": 80000, "rect": [850, 620, 1200, 900]},
          {"min_area": 300, "max_area": 1500, "rect": [1600, 300, 1750, 470]},
      ])
seq2s("chaossprite_mega_sleep", "sleep", 512, dur_ms=625,
      content_pct=0.95, num_colors=160)

print("\n✓ 完成。输出目录:", OUTPUT)

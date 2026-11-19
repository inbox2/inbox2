#!/usr/bin/env python3
"""Cut the hero shot into the pieces the website assembles on scroll.

From the untouched 2x captures `website/assets-src/shots/accounts{,-light}.png`
(taken by shots.py --only inbox) this writes, per theme, into
`website/public/assets/shots/hero/`:

  chrome[-light].webp   — the window with every pane blacked out: the title bar
                          and the frame edge are the real capture, the inside is
                          a flat near-black the parts land on
  <part>[-light].webp   — each pane cropped out of the same capture

Regions are fractions of the window (left, top, width, height); the part rules
in HeroBuild.module.css carry the same numbers — change both.

    python3 website/scripts/hero-parts.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
RAW = REPO / "website/assets-src/shots"
OUT = REPO / "website/public/assets/shots/hero"
WEBP_WIDTH = 2000
# The fill the parts fall onto. Near-black, not #000: the window's own frame
# edge still reads against it, and the site's --ink is #111.
VOID = (10, 10, 13)

# (left, top, width, height) as fractions of the window. The title bar (0–5.6%)
# stays part of the chrome.
PARTS = {
    "channels": (0.0, 0.056, 1.0, 0.070),
    "sidebar": (0.0, 0.126, 0.084, 0.818),
    "list": (0.084, 0.126, 0.416, 0.818),
    "reading": (0.50, 0.126, 0.50, 0.659),
    "composer": (0.50, 0.785, 0.50, 0.159),
    "strip": (0.0, 0.944, 1.0, 0.056),      # the Touch Strip along the bottom
}
# Everything below the title bar is void on the chrome.
VOID_FROM = 0.056


def crop(img: Image.Image, region: tuple[float, float, float, float]) -> Image.Image:
    w, h = img.size
    l, t, pw, ph = region
    return img.crop((round(l * w), round(t * h), round((l + pw) * w), round((t + ph) * h)))


def save(img: Image.Image, path: Path, full_width: int) -> None:
    scale = WEBP_WIDTH / full_width
    if scale < 1:
        img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
    img.save(path, "WEBP", quality=84, method=6)
    print(f"  → {path.relative_to(REPO)} ({path.stat().st_size // 1024} KB, {img.width}×{img.height})")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-light"):
        src = RAW / f"accounts{suffix}.png"
        if not src.exists():
            raise SystemExit(f"{src} missing — run website/scripts/shots.py --only inbox first")
        img = Image.open(src).convert("RGB")
        print(f"[{suffix or 'dark'}] {img.width}×{img.height}")
        chrome = img.copy()
        ImageDraw.Draw(chrome).rectangle((0, round(VOID_FROM * img.height), img.width, img.height), fill=VOID)
        save(chrome, OUT / f"chrome{suffix}.webp", img.width)
        for name, region in PARTS.items():
            save(crop(img, region), OUT / f"{name}{suffix}.webp", img.width)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build the golden "DEV" dev-icon set by stamping a badge directly onto the
native prod icons — base art is never resampled, so the dev icon is the prod
app icon plus a corner badge (no border, no size/brightness drift).

Usage: python3 scripts/make-dev-icons.py
Run from ui/desktop/. Requires ImageMagick (`magick`) + macOS `iconutil`.
"""
import subprocess, sys, tempfile, shutil
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src-tauri"
PROD = SRC / "icons"
DEV = SRC / "icons-dev"
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
GOLD = "#FFC121"
INK = "#241a02"


def width(p): return int(subprocess.check_output(["magick", "identify", "-format", "%w", str(p)]))


def stamp(src: Path, dst: Path):
    """Composite a proportional gold DEV badge (bottom-right) onto src -> dst."""
    w = width(src)
    r = round(w * 0.205)            # disc radius (diameter ~0.41w)
    m = round(w * 0.045)            # corner margin
    c = w - m - r                   # disc center (x == y)
    sh = max(1, round(w * 0.012))   # shadow offset
    blur = max(1, round(w * 0.010))
    ps = round(w * 0.16)            # DEV pointsize
    cmd = ["magick", str(src),
           # soft shadow (depth, not a border)
           "(", "-size", f"{w}x{w}", "xc:none", "-fill", "black",
           "-draw", f"circle {c},{c+sh} {c},{c+sh-r}", "-blur", f"0x{blur}",
           "-channel", "A", "-evaluate", "multiply", "0.30", "+channel", ")", "-composite",
           # flat gold disc
           "(", "-size", f"{w}x{w}", "xc:none", "-fill", GOLD,
           "-draw", f"circle {c},{c} {c},{c-r}", ")", "-composite"]
    if w >= 96:  # DEV text only legible at larger sizes
        dx, dy = c - w // 2, c - w // 2
        cmd += ["-gravity", "Center", "-font", FONT, "-pointsize", str(ps),
                "-fill", INK, "-annotate", f"{dx:+d}{dy:+d}", "DEV"]
    cmd.append(str(dst))
    subprocess.run(cmd, check=True)


def main():
    if not PROD.exists():
        sys.exit(f"prod icons not found: {PROD}")
    DEV.mkdir(exist_ok=True)

    # 1) macOS .icns — stamp each NATIVE prod iconset slice, then repack.
    with tempfile.TemporaryDirectory() as td:
        iset = Path(td) / "dev.iconset"
        subprocess.run(["iconutil", "-c", "iconset", str(PROD / "icon.icns"),
                        "-o", str(iset)], check=True)
        for f in iset.glob("*.png"):
            stamp(f, f)
        subprocess.run(["iconutil", "-c", "icns", str(iset),
                        "-o", str(DEV / "icon.icns")], check=True)

    # 2) Standalone PNGs Tauri references — stamp the matching prod PNG.
    for name in ["32x32.png", "128x128.png", "128x128@2x.png", "icon.png",
                 "Square30x30Logo.png", "Square44x44Logo.png", "Square71x71Logo.png",
                 "Square89x89Logo.png", "Square107x107Logo.png", "Square142x142Logo.png",
                 "Square150x150Logo.png", "Square284x284Logo.png", "Square310x310Logo.png",
                 "StoreLogo.png"]:
        if (PROD / name).exists():
            stamp(PROD / name, DEV / name)

    # 3) Windows .ico from the badged 256 png.
    big = DEV / "Square284x284Logo.png"
    if big.exists():
        subprocess.run(["magick", str(big), "-resize", "256x256",
                        "-define", "icon:auto-resize=256,128,64,48,32,16",
                        str(DEV / "icon.ico")], check=True)

    print(f"dev icon set written to {DEV}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Render every user-selectable app icon from the 1024 masters in brand/alt-icons/.

    python3 brand/make-alt-icons.py

Each `<name>.png` master fans out to three places:

  ui/ios/.../AppIcon.appiconset/icon-1024.png
        The DEFAULT icon's master, full-bleed and flattened (Apple HIG: no alpha).
        Kept in step here so the home-screen icon can't drift from its picker row.

  ui/ios/Resources/AppIcon-<name>@2x.png (120pt) + @3x.png (180pt)
        Loose PNGs at the bundle root — what `CFBundleAlternateIcons` and
        `setAlternateIconName(_:)` read. Alternate icons cannot come out of the
        asset catalog, and SwiftUI's `Image(_:)` cannot load them either (it only
        searches catalogs), so the picker uses `UIImage(named:)` on these same files.
        The primary icon ships a loose copy purely so its row has a thumbnail.

  ui/ios/Resources/AppIcon-<name>76x76@2x~ipad.png (152) + 83.5x83.5@2x~ipad.png (167)
        The iPad sizes, listed under `CFBundleIcons~ipad`. Alternates only: the
        primary's iPad sizes come from the asset catalog.

  ui/desktop/src-tauri/icons/alt/<name>.png (512)
        Squircle-inset with a transparent margin, matching the shipped desktop
        icons. `include_bytes!`d into the Rust binary and handed to
        NSApplication.setApplicationIconImage / WebviewWindow::set_icon.

  ui/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_<name>_foreground.png (432)
        Foreground layer of the adaptive icon each `<activity-alias>` points at. The
        tile sits in the middle 72dp of the 108dp canvas — the only part the
        launcher's mask is guaranteed to show — so the gradient rim survives instead
        of being cropped away. The bleed is transparent and the alias's adaptive XML
        paints the icon's own colour behind it. xxxhdpi only, Android downsamples for
        lower densities.

  ui/android/app/src/main/res/drawable-nodpi/app_icon_<name>.png (128)
        Preview swatch for the Android picker (an AdaptiveIconDrawable can't go
        through Compose's painterResource).

  ui/web/public/app-icons/<name>.png (128)
        Preview swatch for the desktop picker in Settings › Theme (the web app
        cannot read files out of the Tauri bundle).

The DEFAULT icon additionally fans out to:

  ui/web/public/favicon-{32,128,512}.png + favicon.ico
        Browser tab, apple-touch-icon, and the icon browsers pin on Web
        Notification popups. Full-bleed squircle (no desktop margin).

  ui/android/app/src/main/res/mipmap-*/ic_launcher_monochrome.png
        The one white silhouette shared by every launcher alias's <monochrome>
        (themed icons) AND NotificationHelper's setSmallIcon — the glyph Android
        push notifications show in the status bar. Drawn as the classic tile's
        card with the "2" knocked through, not from the master PNG — a silhouette
        needs paths, not a flattened tile.

Adding an icon: drop a 1024 master here, re-run this, then wire it up in
`AppIconOption` (iOS) + project.yml `CFBundleAlternateIcons`, and in `APP_ICONS`
(ui/desktop/src-tauri/src/app_icon.rs + ui/web/src/lib/appIcon.js), and on Android in
`AppIconOption.kt` + a `<activity-alias>` and `mipmap-anydpi-v26/ic_launcher_<name>.xml`.

Requires rsvg-convert + ImageMagick.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTERS = ROOT / "brand/alt-icons"
IOS = ROOT / "ui/ios/Resources"
IOS_PRIMARY = ROOT / "ui/ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
DESKTOP = ROOT / "ui/desktop/src-tauri/icons/alt"
DESKTOP_BUNDLE = ROOT / "ui/desktop/src-tauri/icons"
WEB_PUBLIC = ROOT / "ui/web/public"
WEB = ROOT / "ui/web/public/app-icons"
ANDROID_RES = ROOT / "ui/android/app/src/main/res"
ANDROID_FG = ANDROID_RES / "mipmap-xxxhdpi"
ANDROID_PREVIEW = ANDROID_RES / "drawable-nodpi"
# Adaptive-icon canvas: 108dp @ xxxhdpi, of which only the middle 72dp survives the
# launcher mask. The tile fills exactly that, so a squircle mask shows all of it and a
# circular one clips just the corners — same as every other platform rounds them.
ANDROID_CANVAS, ANDROID_ART = 432, 288
IOS_SIZES = {"@2x": 120, "@3x": 180}
IOS_IPAD_SIZES = {"76x76@2x~ipad": 152, "83.5x83.5@2x~ipad": 167}
# Must match DEFAULT_APP_ICON in ui/web/src/lib/appIcon.js, the `.classic` primary in
# AppIconOption.swift, and the enabled <activity-alias> + DEFAULT on Android.
DEFAULT_ICON = "classic"
INSET = 824 / 1024          # Big Sur squircle: art 824 in a 1024 box

# The brand gradient border: the tile is filled with a top-to-bottom gradient and
# the artwork sits on an inset rounded card, so the gradient shows as a rim. Each
# icon draws its stops from its *own* palette rather than the house violet-pink-amber
# — `classic` already has its rim baked into the historical PNG, so it has no entry
# and passes through untouched.
RINGS = {
    # cream / vermillion / white disc  ->  warm descent, ray red through to amber
    "sun": ["#FFF6E4", "#FF9166", "#D6272B"],
    # the three venn discs, in their own order
    "vennlight": ["#3B2E9E", "#FF0080", "#FFBF40"],
    # the piece's own colours: letter teal, arrow orange, hexagon crimson
    "graffiti": ["#3FB5AE", "#E8722E", "#B4302B"],
}

# Inset card the artwork is clipped to, spanning 56..968 of 1024 (lifted from the
# pre-venn app icon SVG, deleted 2026-10-13, so the rim matches `classic` exactly).
CARD = (
    "M 689.600 56.000 c 97.449 0 146.174 0 183.394 18.965 a 174.000 174.000 0 0 1 76.041 76.041 "
    "c 18.965 37.221 18.965 85.945 18.965 183.394 L 968.000 689.600 c 0 97.449 0 146.174 "
    "-18.965 183.394 a 174.000 174.000 0 0 1 -76.041 76.041 c -37.221 18.965 -85.945 18.965 "
    "-183.394 18.965 L 334.400 968.000 c -97.449 0 -146.174 0 -183.394 -18.965 "
    "a 174.000 174.000 0 0 1 -76.041 -76.041 c -18.965 -37.221 -18.965 -85.945 -18.965 -183.394 "
    "L 56.000 334.400 c 0 -97.449 0 -146.174 18.965 -183.394 a 174.000 174.000 0 0 1 "
    "76.041 -76.041 c 37.221 -18.965 85.945 -18.965 183.394 -18.965 Z"
)

# Geometry for the Android monochrome silhouette: the "2" is the brand glyph from
# brand/inbox2-mark.svg as a path, GLYPH_CAP px tall inside the card.
MONO_SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
GLYPH_CAP = 501
TWO = ("M56.9688 154V137.828L96.8125 100.562C101.708 96.0312 105.406 92.2552 107.906 89.2344C110.406 86.2135 "
 "112.099 83.5052 112.984 81.1094C113.922 78.7135 114.391 76.2135 114.391 73.6094V73.4531C114.391 70.3802 "
 "113.661 67.6719 112.203 65.3281C110.745 62.9323 108.714 61.0573 106.109 59.7031C103.557 58.349 100.615 "
 "57.6719 97.2812 57.6719C93.4271 57.6719 90.0417 58.4531 87.125 60.0156C84.2083 61.526 81.9167 63.6354 "
 "80.25 66.3438C78.5833 69 77.6979 72.0208 77.5938 75.4062L77.5156 76.1094H55.6406V75.4844C55.6406 68.401 "
 "57.4375 62.151 61.0312 56.7344C64.625 51.2656 69.5469 46.9948 75.7969 43.9219C82.099 40.849 89.2083 "
 "39.3125 97.125 39.3125C105.094 39.3125 112.099 40.7188 118.141 43.5312C124.182 46.2917 128.896 50.1458 "
 "132.281 55.0938C135.667 60.0417 137.359 65.7188 137.359 72.125V72.2812C137.359 76.8125 136.526 81.0312 "
 "134.859 84.9375C133.245 88.7917 130.562 92.9062 126.812 97.2812C123.062 101.604 117.932 106.76 111.422 "
 "112.75L78.7656 142.516L87.8281 126.656V142.516L78.8438 135.25H138.922V154H56.9688Z")
GLYPH_CX, GLYPH_CY, GLYPH_H = 97.28, 96.66, 114.69

# Apple squircle, 1024 box, spans 32..992 (same path as brand/make-app-icons.py)
SQUIRCLE = (
    "M 648 32 c 120.411 0 180.617 0 226.608 23.434 a 215 215 0 0 1 93.958 93.958 "
    "c 23.434 45.991 23.434 106.197 23.434 226.608 L 992 648 c 0 120.411 0 180.617 "
    "-23.434 226.608 a 215 215 0 0 1 -93.958 93.958 c -45.991 23.434 -106.197 23.434 "
    "-226.608 23.434 L 376 992 c -120.411 0 -180.617 0 -226.608 -23.434 a 215 215 0 0 1 "
    "-93.958 -93.958 c -23.434 -45.991 -23.434 -106.197 -23.434 -226.608 L 32 376 "
    "c 0 -120.411 0 -180.617 23.434 -226.608 a 215 215 0 0 1 93.958 -93.958 "
    "c 45.991 -23.434 106.197 -23.434 226.608 -23.434 Z"
)


def squircle_mask(td):
    """White inset squircle on black — an alpha mask for the desktop tiles."""
    s = INSET * 1024 / 960
    t = (1024 - INSET * 1024) / 2 - 32 * s
    svg = Path(td) / "sq.svg"
    svg.write_text(
        f'<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
        f'<rect width="1024" height="1024" fill="black"/>'
        f'<path d="{SQUIRCLE}" fill="white" transform="translate({t:.2f} {t:.2f}) scale({s:.4f})"/>'
        f"</svg>")
    out = Path(td) / "sq.png"
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", str(svg), "-o", str(out)], check=True)
    return out


def monochrome_classic(td):
    """White-on-transparent classic silhouette at 1024: the inset card with the
    "2" knocked through. Alpha is all Android reads from it."""
    place = (f'transform="translate(512 512) scale({GLYPH_CAP / GLYPH_H:.4f}) '
             f'translate({-GLYPH_CX} {-GLYPH_CY})"')
    svg = Path(td) / "mono.svg"
    svg.write_text(
        f'<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
        f'<defs><mask id="ko"><rect width="1024" height="1024" fill="white"/>'
        f'<path d="{TWO}" fill="black" {place}/></mask></defs>'
        f'<path d="{CARD}" mask="url(#ko)" fill="white"/></svg>')
    out = Path(td) / "mono.png"
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", str(svg), "-o", str(out)], check=True)
    return out


def with_ring(src, stops, td):
    """Composite the master onto a gradient tile, clipped to the inset card."""
    import base64
    data = base64.b64encode(src.read_bytes()).decode()
    step = 100 / (len(stops) - 1)
    ramp = "".join(f'<stop offset="{i * step:.0f}%" stop-color="{c}"/>' for i, c in enumerate(stops))
    svg = Path(td) / f"{src.stem}-ring.svg"
    svg.write_text(
        f'<svg width="1024" height="1024" viewBox="0 0 1024 1024" '
        f'xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
        f'<defs><linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">{ramp}</linearGradient>'
        f'<clipPath id="card"><path d="{CARD}"/></clipPath></defs>'
        f'<rect width="1024" height="1024" fill="url(#rim)"/>'
        f'<g clip-path="url(#card)">'
        f'<image x="0" y="0" width="1024" height="1024" xlink:href="data:image/png;base64,{data}"/>'
        f"</g></svg>")
    out = Path(td) / f"{src.stem}-ring.png"
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", str(svg), "-o", str(out)], check=True)
    return out


def favicons(src, td):
    """Web favicons follow the default icon — the browser tab, apple-touch-icon,
    and what browsers pin on Web Notification popups. Full-bleed squircle: no
    desktop margin, tabs are tiny enough already."""
    svg = Path(td) / "favmask.svg"
    svg.write_text(
        f'<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
        f'<rect width="1024" height="1024" fill="black"/>'
        f'<path d="{SQUIRCLE}" fill="white"/></svg>')
    mask = Path(td) / "favmask.png"
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", str(svg), "-o", str(mask)], check=True)
    tile = ["magick", str(src), str(mask), "-alpha", "off",
            "-compose", "CopyOpacity", "-composite"]
    for px in (512, 128, 32):
        subprocess.run(tile + ["-resize", f"{px}x{px}", str(WEB_PUBLIC / f"favicon-{px}.png")],
                       check=True)
    subprocess.run(tile + ["-resize", "64x64", "-define", "icon:auto-resize=64,32,16",
                    str(WEB_PUBLIC / "favicon.ico")], check=True)


def desktop_bundle(src, mask):
    """The desktop app's own bundle icon — what the Dock, Finder and the Now Playing
    widget show when the app is NOT running.

    It has to be the default icon: `set_app_icon` only repaints the running process,
    so on quit the tile falls back to this. Shipping a different mark here meant
    quitting visibly changed the icon to one that wasn't even in the picker.
    """
    tile = ["magick", str(src), "-resize", "824x824", "-background", "none",
            "-gravity", "center", "-extent", "1024x1024",
            str(mask), "-alpha", "off", "-compose", "CopyOpacity", "-composite"]
    for name, px in [("32x32.png", 32), ("128x128.png", 128), ("128x128@2x.png", 256),
                     ("icon.png", 512), ("Square30x30Logo.png", 30),
                     ("Square44x44Logo.png", 44), ("Square71x71Logo.png", 71),
                     ("Square89x89Logo.png", 89), ("Square107x107Logo.png", 107),
                     ("Square142x142Logo.png", 142), ("Square150x150Logo.png", 150),
                     ("Square284x284Logo.png", 284), ("Square310x310Logo.png", 310),
                     ("StoreLogo.png", 50)]:
        subprocess.run(tile + ["-resize", f"{px}x{px}", str(DESKTOP_BUNDLE / name)], check=True)

    with tempfile.TemporaryDirectory() as td:
        iset = Path(td) / "icon.iconset"
        iset.mkdir()
        for base in (16, 32, 128, 256, 512):
            for suffix, px in ((f"_{base}x{base}", base), (f"_{base}x{base}@2x", base * 2)):
                subprocess.run(tile + ["-resize", f"{px}x{px}", str(iset / f"icon{suffix}.png")],
                               check=True)
        subprocess.run(["iconutil", "-c", "icns", str(iset),
                        "-o", str(DESKTOP_BUNDLE / "icon.icns")], check=True)

    subprocess.run(["magick", str(DESKTOP_BUNDLE / "Square284x284Logo.png"), "-resize", "256x256",
                    "-define", "icon:auto-resize=256,128,64,48,32,16",
                    str(DESKTOP_BUNDLE / "icon.ico")], check=True)

    # The golden DEV set is stamped from the prod one, so it has to follow.
    subprocess.run([sys.executable, "scripts/make-dev-icons.py"],
                   cwd=ROOT / "ui/desktop", check=True)


def main():
    masters = sorted(MASTERS.glob("*.png"))
    if not masters:
        sys.exit(f"no masters in {MASTERS}")
    for d in (IOS, DESKTOP, WEB, ANDROID_FG, ANDROID_PREVIEW):
        d.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        mask = squircle_mask(td)
        for master in masters:
            # Bare art in, ringed tile out — the masters stay ring-free so a re-run
            # never stacks a second rim on top of the first.
            src = with_ring(master, RINGS[master.stem], td) if master.stem in RINGS else master
            sizes = IOS_SIZES if master.stem == DEFAULT_ICON else {**IOS_SIZES, **IOS_IPAD_SIZES}
            for suffix, px in sizes.items():
                # Flattened, no alpha, no rounding — iOS masks the corners itself.
                subprocess.run(["magick", str(src), "-resize", f"{px}x{px}",
                                "-alpha", "remove", "-alpha", "off",
                                f"PNG24:{IOS}/AppIcon-{master.stem}{suffix}.png"], check=True)

            # Desktop: the tile floats in a transparent margin so the Cmd+Tab
            # selection rect has room. The art is SCALED DOWN into the squircle
            # rather than cropped by it — the gradient rim lives in the outer band
            # of the 1024 master, and a straight crop at 824 cuts it clean off.
            subprocess.run(["magick", str(src), "-resize", "824x824",
                            "-background", "none", "-gravity", "center", "-extent", "1024x1024",
                            str(mask), "-alpha", "off", "-compose", "CopyOpacity", "-composite",
                            "-resize", "512x512", f"{DESKTOP}/{master.stem}.png"], check=True)

            subprocess.run(["magick", str(src), "-resize", "128x128",
                            f"{WEB}/{master.stem}.png"], check=True)
            subprocess.run(["magick", str(src), "-resize", "128x128",
                            f"{ANDROID_PREVIEW}/app_icon_{master.stem}.png"], check=True)

            subprocess.run(["magick", str(src), "-resize", f"{ANDROID_ART}x{ANDROID_ART}",
                            "-background", "none", "-gravity", "center",
                            "-extent", f"{ANDROID_CANVAS}x{ANDROID_CANVAS}",
                            f"{ANDROID_FG}/ic_launcher_{master.stem}_foreground.png"], check=True)

            if master.stem == DEFAULT_ICON:
                subprocess.run(["magick", str(src), "-resize", "1024x1024",
                                "-alpha", "remove", "-alpha", "off",
                                f"PNG24:{IOS_PRIMARY}"], check=True)
                desktop_bundle(src, mask)
                favicons(src, td)

        # Android's shared monochrome (themed launcher icons + the notification
        # small icon) is the default classic's silhouette. Art fills the middle 2/3
        # of the canvas — the same 72/108dp safe zone as the colour foregrounds.
        mono = monochrome_classic(td)
        for dpi, canvas in MONO_SIZES.items():
            art = round(canvas * 2 / 3)
            subprocess.run(["magick", str(mono), "-resize", f"{art}x{art}",
                            "-background", "none", "-gravity", "center",
                            "-extent", f"{canvas}x{canvas}",
                            str(ANDROID_RES / f"mipmap-{dpi}" / "ic_launcher_monochrome.png")],
                           check=True)

    print(f"{len(masters)} icons -> iOS, desktop, Android, web previews")


if __name__ == "__main__":
    main()

# Re-skins an Archify render in inbox2's website style. build.sh runs it after every finalize:
#   python3 docs/diagrams/inbox2-skin.py docs/diagrams/<name>/<name>.html
# Lineage: Tuli's docs/diagrams/tuli-skin.py, generalised to every Archify diagram type.
# ponytail: string patches against Archify 3.2.0 markup; asserts fail loudly if a new version changes it.
import base64
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LOGO = REPO / "website/public/assets/inbox2-wordmark-dark.svg"  # black text: reads on the light page
LOGO_DARK = REPO / "website/public/assets/inbox2-wordmark-light.svg"

p = sys.argv[1]
h = open(p).read()
assert "inbox2-skin" not in h, "already skinned"

# Workflow lanes: titles without the "01 / " index. Other diagram types have no lanes.
h = re.sub(r'(class="t-muted" font-size="10" font-weight="600">)\d\d / ', r"\1", h)

# No dot grid.
h = h.replace('<rect width="100%" height="100%" fill="url(#grid)" />', "", 1)

# Light by default; the toggle and a stored choice still win.
old = "window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'"
assert h.count(old) == 2, "theme default not found"
h = h.replace(old, "'light'")


def data_uri(svg: Path) -> str:
    return "data:image/svg+xml;base64," + base64.b64encode(svg.read_bytes()).decode()


# Wordmark left of the title, in place of the pulse dot. An <img>, because the viewer resizes inline SVGs;
# two images, one per theme, toggled by CSS.
logo = (f'<img class="i2-logo i2-logo-light" alt="inbox2" src="{data_uri(LOGO)}">'
        f'<img class="i2-logo i2-logo-dark" alt="inbox2" src="{data_uri(LOGO_DARK)}">')
old = '<div class="pulse-dot"></div>'
assert h.count(old) == 1, "pulse dot not found"
h = h.replace(old, logo, 1)

kinds = ["frontend", "backend", "database", "messagebus", "security", "external", "cloud"]
fills = "".join(
    f"svg [data-node-id] > rect.c-{k}, svg [data-legend-kind] > rect.c-{k}, svg [data-participant-id] > rect.c-{k} "
    f"{{ fill: var(--{k}-fill) !important; stroke: var(--{k}-stroke) !important; stroke-width: 1px !important; }}\n"
    for k in kinds
)

skin = """
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,400..900&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style id="inbox2-skin">
""" + (HERE / "inbox2-theme.css").read_text() + """
body, .toolbar, .card, .cards, svg text { font-family: "Inter", system-ui, sans-serif !important; letter-spacing: 0 !important; }
h1 { font-family: "Archivo", "Inter", sans-serif !important; font-variation-settings: "wdth" 118; font-weight: 800 !important; letter-spacing: -.03em !important; }
html[data-theme="light"][data-preset] { --canvas-dot:transparent; --grid:transparent; }
html[data-theme="dark"][data-preset] { --canvas-dot:transparent; --grid:transparent; }
/* Nodes and legend swatches: hairline border in the kind's colour, pastel fill. */
svg [data-node-id] > rect:not(.c-mask) { rx: 8px; }
""" + fills + """
svg [data-node-id] .semantic-sigil { display: none !important; }
svg [data-node-id] text.t-primary { font-weight: 600 !important; fill: var(--text) !important; }
svg [data-node-id] text.t-muted { fill: var(--text-muted) !important; }
/* Lanes and boundaries: plain bands, small caps titles. */
svg rect.c-lane { stroke-dasharray: none !important; }
svg text.t-muted[font-size="10"] { fill: var(--text) !important; font-weight: 700 !important; text-transform: uppercase; letter-spacing: .06em !important; font-size: 9px; }
/* Edge labels: white pills. */
svg g[data-edge-from] > rect.c-mask, svg g[data-connection-id] > rect.c-mask { fill: var(--panel) !important; stroke: var(--panel-border) !important; rx: 7px; }
/* No glow, no particles, no counts or indexes. */
svg * { filter: none !important; }
svg [data-flow-particle], svg .flow-particle, svg [class*="pulse"], svg [class*="halo"], svg [class*="glow"] { display: none !important; }
svg [data-legend-count-badge], .diagram-guide-index { display: none !important; }
.node-outline, .rail-reveal { display: none !important; }
/* Cards: field lists in the code font. */
.card li { font-family: "JetBrains Mono", ui-monospace, monospace !important; font-size: 12px; }
.card-dot { border-radius: 50% !important; transform: none !important; }
.card { box-shadow: none !important; border-radius: 8px !important; }
.header .header-row img.i2-logo { display: block !important; height: 30px !important; width: 105px !important; max-width: 105px !important; flex: 0 0 105px !important; box-sizing: content-box; margin-right: 16px; padding-right: 16px; border-right: 1px solid var(--panel-border); object-fit: contain; }
html[data-theme="light"] .header .header-row img.i2-logo-dark, html[data-theme="dark"] .header .header-row img.i2-logo-light { display: none !important; }
</style>
"""
h = h.replace("</head>", skin + "</head>", 1)
open(p, "w").write(h)
print("skinned", p)

#!/usr/bin/env bash
# Build one inbox2 diagram: Archify render + inbox2 skin + 2x PNG (for the manual) + PDF.
#   docs/diagrams/build.sh <name>            # type read from candidate.json's diagram_type
#   PAGE_HEIGHT=2400 docs/diagrams/build.sh <name>   # taller page when cards are cut off
# Lineage: Tuli's docs/diagrams/build.sh. See docs/diagrams/README.md.
set -euo pipefail
name="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="docs/diagrams/$name"
archify="${ARCHIFY:-$HOME/.claude/skills/archify/bin/archify.mjs}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
evidence="$(mktemp -d)"   # Archify's browser-check receipts stay out of the repo

cd "$root"
type="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['diagram_type'])" "$dir/candidate.json")"
node "$archify" finalize "$type" "$dir/candidate.json" "$dir/$name.html" \
  --quality showcase --out-dir "$evidence" --json >"$evidence/finalize.out" \
  || { cat "$evidence/finalize.out"; exit 1; }
rm -f "$dir/$name".*.json
python3 docs/diagrams/inbox2-skin.py "$dir/$name.html"
# PNG = full-page 2x screenshot without the viewer controls. Printing the page loses the diagram inside
# Archify's viewer, so the PDF is the same raster.
# ponytail: raster, fixed height per diagram (PAGE_HEIGHT); raise it if the cards get cut.
sed 's#</head>#<style>.toolbar,.diagram-nav,.no-print{display:none!important}.diagram-container{min-height:0!important}</style></head>#' \
  "$dir/$name.html" >"$evidence/$name.html"
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size="${PAGE_WIDTH:-1600}","${PAGE_HEIGHT:-1400}" --virtual-time-budget=6000 \
  --screenshot="$dir/$name.png" "file://$evidence/$name.html" 2>/dev/null
# Trim the empty canvas below the content so the manual gets a tight figure.
uv run --quiet --with pillow==11.3.0 python3 - "$dir/$name.png" <<'EOF'
import sys
from PIL import Image, ImageChops
p = sys.argv[1]; im = Image.open(p).convert("RGB")
bg = Image.new("RGB", im.size, im.getpixel((im.width - 1, im.height - 1)))
box = ImageChops.difference(im, bg).getbbox()
if box: im.crop((0, 0, im.width, min(im.height, box[3] + 48))).save(p)
EOF
sips -s format pdf "$dir/$name.png" --out "$root/$dir/$name.pdf" >/dev/null
echo "built $dir/$name.html, $dir/$name.png and $dir/$name.pdf"

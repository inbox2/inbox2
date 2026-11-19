# inbox2 diagrams

Architecture and flow diagrams in inbox2's own look, made with [Archify](https://archify.si) and re-skinned afterwards. They are the figures in `docs/desktop-spec` (printed by `docs/manual/build.py`).

```
docs/diagrams/
  build.sh          one command: render, skin, PNG, PDF
  inbox2-skin.py    turns Archify's output into the website look
  inbox2-theme.css  the palette for light and dark, from website/app/styles/tokens.css
  <name>/
    candidate.json  the diagram source
    <name>.html     the explorable page (dark/light toggle, zoom, export)
    <name>.png      a 2x screenshot without the viewer controls: the figure the book embeds
    <name>.pdf      the same raster as a one-page PDF
```

## Build

```sh
docs/diagrams/build.sh system-map
PAGE_HEIGHT=2400 docs/diagrams/build.sh core-layers   # taller window when cards are cut off
```

Needs the Archify skill (`~/.claude/skills/archify/bin/archify.mjs`; set `ARCHIFY=` for another path), Google Chrome (`CHROME=`), `uv` (for the PNG trim) and `sips` (macOS). `build.sh` reads `diagram_type` from the candidate, runs Archify's `finalize` (validation, render, a real-browser check; its receipts go to a temporary folder), applies the skin, screenshots the page at 2x with the toolbar hidden and the canvas padding removed, trims the empty bottom, and converts the PNG to PDF.

Never run `inbox2-skin.py` twice on the same file; it refuses.

## Make a new diagram

1. `mkdir docs/diagrams/<name>` and write `candidate.json`. Read the Archify skill first: `SKILL.md` (type router), `references/authoring-defaults.md`, the schema for the type under `schemas/`, and the matching example under `examples/`. Set `meta.output` to `docs/diagrams/<name>/<name>.html` and `meta.quality_profile` to `showcase`; omit `viewBox`, `animation` and `visual_preset`.
2. Name the legend: `meta.legend.entries.<kind>.label` says what each colour means in this diagram.
3. `docs/diagrams/build.sh <name>`. A failure names the node or edge at fault; repair and rerun.
4. Look at the PNG before using it.

Types used so far: `architecture` (component maps, with `boundaries` for layers), `workflow` v2 (swimlane flows; `mainPath` only moves right), `sequence` (call chains).

## What the skin changes

| Change | Detail |
|---|---|
| Theme | light by default on the paper tone `#FAFAF7`; the dark toggle still works and uses the ink palette |
| Text | Inter for the page and the diagram, Archivo for the title, JetBrains Mono for the field lists in cards |
| Nodes | hairline border in the kind's colour, pastel fill, no icons, glow or particles |
| Lanes | plain bands, small-caps titles without Archify's "01 /" index |
| Edge labels | white pills |
| Legend | filled swatches, no count badges |
| Header | the inbox2 wordmark in place of Archify's pulse dot (one per theme) |
| Node index | hidden |

Node kinds and the meaning the inbox2 diagrams give them:

| Kind | Fill | Use for |
|---|---|---|
| `frontend` | periwinkle | UI, windows, people |
| `backend` | grey | the Rust core and its services |
| `database` | green | SQLite and stores |
| `messagebus` | yellow | queues, workers, ticks, events |
| `security` | red | secrets, sealed mail, gates, approvals |
| `external` | light grey | providers and third-party services |
| `cloud` | blue | the inbox2 cloud (Rails API, cable, proxy) |

## Things that broke along the way

- **Padded canvas:** Archify's viewer sizes the diagram to the window height, so a 1400 px window left a 650 px diagram floating in white. The PNG copy sets `.diagram-container { min-height: 0 }` so the canvas is intrinsic.
- **Two wordmarks:** the skin's `display:none` per theme lost to the `.header .header-row img` rule on specificity. Both selectors now carry the full path.
- **Printing:** Chrome's print-to-PDF leaves the diagram blank inside the viewer, so the PDF is a raster.
- **Patching Archify's markup:** `inbox2-skin.py` matches exact strings in Archify 3.2.0 output and asserts fail loudly when an update changes them. Fix the patterns, keep the asserts.

# Printing a book from Markdown chapters

`docs/manual/build.py` prints a folder of numbered Markdown chapters as an A4 PDF in inbox2's website look: an ink cover with the aurora glow, a contents page with real page numbers, a full-bleed opener per chapter, then paper pages with hairline tables, code on ink, numbered steps, figures and callouts.

```sh
uv run docs/manual/build.py docs/desktop-spec docs/desktop-spec/inbox2-desktop-spec.pdf
```

Needs Google Chrome (headless printing) and `uv`. Fonts (Archivo, Inter, JetBrains Mono) load from Google Fonts at print time, so the first run needs the network. The book is rendered twice: the first pass tells us which page every chapter landed on, the second prints those numbers.

## Files

```
docs/manual/
  build.py       the renderer (uv script; Markdown → HTML → Chrome → PDF)
  manual.html    the page template: cover, contents, $body, back cover
  manual.css     the print styles on the website tokens (website/app/styles/tokens.css)
  assets/        the wordmarks the cover and openers use
docs/desktop-spec/
  00-front.md    cover text + "how to read" page
  01-*.md …      one chapter per file, rendered in filename order
  inbox2-desktop-spec.pdf   the result, committed with the chapters
```

## Writing a chapter

Front matter, then sections:

```markdown
---
part: "03"            # or "A" for an appendix
title: The Rust core
subtitle: Crates, module layers, the run loop and the workers.
eyebrow: Core         # shown as "03 / CORE" on the opener
lede: One or two sentences for the opener page.
appendix: true        # plain dark opener instead of the deep indigo one
---

## A section           (listed in the contents and on the opener)
### A subsection
#### A SMALL MONO LABEL
```

- No `#` heading: the title comes from the front matter.
- `00-front.md` has no opener. Its `title`, `subtitle`, `eyebrow` and `edition` go on the cover, `running` is the page footer, `contact` the back cover line, and its body is the page after the contents.
- Figures: `![alt](../diagrams/x/x.png "Caption")` on its own line. Numbered "Figure 3.4" per chapter, printed at half the image's pixel width (2x captures stay sharp) and capped to the column. Add `{.half}` after it to float it right.
- Callouts: a blockquote starting with `**Tip**`, `**Note**`, `**Watch out**` or `**Decision**`. Two callouts in a row need a blank line between them (the builder keeps them apart).
- Ordered lists become numbered steps, fenced code is highlighted (name the language), tables are hairline tables.
- Keep tables to four columns and cells to a line or two; A4 is narrow.

## Diagrams

Diagrams come from `docs/diagrams/` (see its README): an Archify candidate per diagram, built by `docs/diagrams/build.sh <name>` into a skinned HTML page and a 2x PNG that the chapter embeds.

## Lineage

The mechanism is gluon's `marketing/src/build.py` `handbook` step, cut down to the book alone and made project-agnostic: everything brand-specific is in `manual.html`, `manual.css` and the chapter front matter. The diagram skin is Tuli's `docs/diagrams/tuli-skin.py` on the inbox2 palette.

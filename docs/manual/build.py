# /// script
# requires-python = ">=3.12"
# dependencies = ["markdown==3.9", "pygments==2.19.2", "pypdf==6.1.1", "pillow==11.3.0"]
# ///
"""Print a book from numbered Markdown chapters: `uv run docs/manual/build.py <chapters-dir> <out.pdf>`.

    uv run docs/manual/build.py docs/desktop-spec docs/desktop-spec/inbox2-desktop-spec.pdf

Lineage: gluon's marketing/src/build.py `handbook` step, cut down to the book alone and made
project-agnostic: everything brand-specific is in manual.html / manual.css (and the chapter folder's
00-front.md front matter). See docs/manual/README.md for the chapter conventions.

Rendered twice: the first PDF tells us on which page every chapter and section landed (Chrome writes a
named destination for every link target in the contents), the second prints those numbers.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from string import Template

import markdown
from markdown.extensions.toc import slugify
from PIL import Image
from pypdf import PdfReader

HERE = Path(__file__).resolve().parent
CHROME = os.environ.get("CHROME") or next(
    (c for c in (shutil.which(n) for n in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome")) if c),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
)  # $CHROME, then PATH, then the macOS app
CALLOUTS = {"Tip": "+", "Note": "i", "Watch out": "!", "Decision": "§"}


def chrome(*args: str) -> None:
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--allow-file-access-from-files", "--hide-scrollbars",
         "--no-pdf-header-footer", "--virtual-time-budget=8000", *args],
        check=True, capture_output=True,
    )


def chapter(md_file: Path, index: int) -> dict:
    """One Markdown chapter: front matter, sections (for the contents) and HTML with figures and callouts.

    Conventions for chapter writers (NN-name.md, rendered in filename order):
    - Front matter: part ("01", or "A" for an appendix), title, subtitle (second headline line), eyebrow
      (shown as "01 / EYEBROW"), lede (one or two sentences for the opener), appendix: true for a plain
      opener. 00-front.md has no opener: its title, subtitle, eyebrow go on the cover, its body is the
      "how to read" page after the contents; `running` sets the page footer, `contact` the back cover line.
    - No "#" headings: the title comes from front matter. "##" sections (listed in the contents and on
      the opener), "###" subsections, "####" a small mono label.
    - Images on their own line: ![alt](path "Caption"), numbered "Figure 3.4" per chapter, printed at
      natural width / 2 (2x captures stay sharp) capped to the column. {.half} floats it right.
    - Callouts: a quote starting with **Tip**, **Note**, **Watch out**, or **Decision**.
    - Ordered lists are numbered steps; fenced code blocks are highlighted; tables are hairline tables.
    """
    text = md_file.read_text()
    meta: dict = {}
    if text.startswith("---"):
        _, front, text = text.split("---", 2)
        # One `key: value` per line, values are plain strings (so a colon in a lede is fine); `true`/`false` are bools.
        for line in front.strip().splitlines():
            k, _, v = line.partition(":")
            v = v.strip().strip('"')
            meta[k.strip()] = {"true": True, "false": False}.get(v, v)
    # Python-Markdown merges blockquotes separated by one blank line; a comment keeps two callouts apart.
    text = re.sub(r"(?m)^(> [^\n]*)\n\n(?=> \*\*)", r"\1\n\n<!-- -->\n\n", text)
    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "attr_list", "sane_lists", "toc", "codehilite"],
        extension_configs={
            "toc": {"toc_depth": "2", "slugify": lambda v, sep: f"c{index}-{slugify(v, sep)}"},
            "codehilite": {"guess_lang": False, "css_class": "codehilite"},
        },
    )
    html = md.convert(text)
    part = str(meta.get("part", f"{index:02d}"))
    figures = 0

    def figure(m: re.Match) -> str:
        nonlocal figures
        figures += 1
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        caption = attrs.get("title") or attrs.get("alt", "")
        classes = attrs.get("class", "")
        label = f"<b>Figure {int(part) if part.isdigit() else part}.{figures}</b>"
        path = (md_file.parent / attrs.get("src", "")).resolve()
        if not path.is_file():
            print(f"manual: missing image {path}", file=sys.stderr)
            return (f'<figure class="missing {classes}"><div class="ph">missing: {attrs.get("src")}</div>'
                    f"<figcaption>{label}{caption}</figcaption></figure>")
        width = Image.open(path).width // 2
        return (f'<figure class="{classes}"><img src="{path.as_uri()}" width="{width}" alt="{attrs.get("alt", "")}">'
                f"<figcaption>{label}{caption}</figcaption></figure>")

    html = re.sub(r"<p>(<img [^>]*>)</p>", figure, html)

    def callout(m: re.Match) -> str:
        kind = m.group(1)
        cls = kind.lower().replace(" ", "-")
        return f'<div class="callout {cls}"><div class="tile">{CALLOUTS[kind]}</div><div><p><strong>{kind}</strong>'

    html = re.sub(r"<blockquote>\s*<p><strong>(" + "|".join(map(re.escape, CALLOUTS)) + r")</strong>",
                  callout, html)
    html = re.sub(r"(<div class=\"callout[^\"]*\">.*?)</blockquote>", r"\1</div></div>", html, flags=re.S)

    sections = [(i, n) for i, n in re.findall(r'<h2 id="([^"]+)">([^<]+)</h2>', html)]
    return {
        "id": f"ch{index}", "part": part, "title": meta.get("title", md_file.stem),
        "subtitle": meta.get("subtitle", ""), "eyebrow": meta.get("eyebrow", ""), "lede": meta.get("lede", ""),
        "appendix": bool(meta.get("appendix")), "meta": meta, "sections": sections, "html": html,
    }


def build(src: Path, pdf: Path) -> None:
    files = sorted(src.glob("[0-9][0-9]-*.md"))
    if not files:
        sys.exit(f"manual: no chapters in {src}")
    chapters = [chapter(f, i) for i, f in enumerate(files)]
    front = chapters.pop(0) if files[0].name.startswith("00") else None
    meta = front["meta"] if front else {}
    work = Path(tempfile.mkdtemp())

    def render(pages: dict[str, int]) -> Path:
        toc, body = "", ""
        if front:
            body += f'<section class="front">{front["html"]}</section>'
        for ch in chapters:
            p = lambda i: pages.get(i, "")  # noqa: E731
            subs = "".join(f'<li><a href="#{i}"><span></span><span>{n}</span><span class="p">{p(i)}</span></a></li>'
                           for i, n in ch["sections"])
            toc += (f'<li><a href="#{ch["id"]}"><span class="n">{ch["part"]}</span><span class="t">{ch["title"]}'
                    f'</span><span class="p">{p(ch["id"])}</span></a>'
                    f"<ul>{subs}</ul></li>")
            sections = "".join(f"<li>{n}</li>" for _, n in ch["sections"])
            body += (f'<section class="bleed opener {"plain" if ch["appendix"] else "deep"}" id="{ch["id"]}">'
                     f'<div class="lockup"><img src="$logo_light" alt="inbox2"></div><div class="bottom">'
                     f'<span class="eyebrow">{ch["part"]} / {ch["eyebrow"]}</span>'
                     f'<h1>{ch["title"]}<span class="muted">{ch["subtitle"]}</span></h1>'
                     f'<p class="lede">{ch["lede"]}</p><ul class="sections">{sections}</ul></div></section>'
                     f'<section class="chapter">{ch["html"]}</section>')
        html = Template((HERE / "manual.html").read_text()).safe_substitute(
            base=HERE.as_uri() + "/", toc=toc, body=body,
            eyebrow=meta.get("eyebrow", ""), title=meta.get("title", src.name), subtitle=meta.get("subtitle", ""),
            contact=meta.get("contact", ""), edition=meta.get("edition", ""),
            running=" ".join(str(meta.get("running") or meta.get("title", "")).split()).replace("\\", "\\\\").replace('"', '\\"'),
        )
        html = Template(html).safe_substitute(
            logo_light=(HERE / "assets/wordmark-light.svg").as_uri(), logo_dark=(HERE / "assets/wordmark-dark.svg").as_uri())
        page = work / "manual.html"
        page.write_text(html)
        pdf.parent.mkdir(parents=True, exist_ok=True)
        chrome(f"--print-to-pdf={pdf}", page.as_uri())
        return pdf

    reader = PdfReader(render({}))
    pages = {name.lstrip("/"): reader.get_destination_page_number(dest) + 1
             for name, dest in reader.named_destinations.items()}
    missing = [ch["id"] for ch in chapters if ch["id"] not in pages]
    if missing:
        print(f"manual: no page found for {missing}", file=sys.stderr)
    render(pages)
    print(f"built {pdf} ({len(PdfReader(pdf).pages)} pages)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())

"""HTML → readable plain text for the terminal.

Many messages are HTML-only (no text/plain part), so the preview pane needs to
render HTML as text. We use `html2text` (HTML → markdown-ish text, drops
style/script, keeps links/lists/emphasis) with a tag-stripping fallback so the
app still works if the library is missing — the same best-effort-with-fallback
pattern as the logo image rendering.
"""

from __future__ import annotations

import html as _html
import re

_TAG_RE = re.compile(r"<[^>]+>")
_STYLE_SCRIPT_RE = re.compile(r"<(style|script)[^>]*>.*?</\1>", re.DOTALL | re.IGNORECASE)


def html_to_text(html: str) -> str:
    try:
        import html2text

        h = html2text.HTML2Text()
        h.ignore_images = True
        h.body_width = 0  # don't hard-wrap; let the TUI wrap to the pane width
        return h.handle(html).strip()
    except Exception:
        # Fallback: drop style/script, strip tags, unescape entities.
        stripped = _STYLE_SCRIPT_RE.sub("", html)
        return _html.unescape(_TAG_RE.sub("", stripped)).strip()


def message_text(message: dict) -> str:
    """Best display text for a message: prefer text/plain, else render HTML."""
    body = (message.get("body_plain") or "").strip()
    if body:
        return body
    html = message.get("body_html")
    if html:
        return html_to_text(html) or "(no text body)"
    return "(no text body)"


def message_markdown(message: dict) -> str:
    """Message body as Markdown for rich rendering. html2text already emits
    Markdown (headings/bold/lists/links), so HTML bodies render as an
    approximation of the original; plain-text bodies pass through as-is."""
    plain = (message.get("body_plain") or "").strip()
    if plain:
        return plain
    html = message.get("body_html")
    if html:
        return html_to_text(html) or "_(no text body)_"
    return "_(no text body)_"

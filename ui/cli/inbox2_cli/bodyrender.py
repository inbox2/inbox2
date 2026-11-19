"""Render a message body into a Rich ``Text`` with recorded hyperlink spans.

The body the CLI shows is markdown-ish (html2text output) or plain text. To make
links navigable *inline* — highlighted where they appear and opened by keyboard —
we render the body ourselves into a ``Text`` and return the character spans of
each link, rather than handing it to Rich's Markdown (whose link positions we
can't address). A pragmatic markdown subset is handled: links, bare URLs, bold,
italic, inline code, headings, list items and horizontal rules.

``render_body(md) -> (Text, links)`` where ``links`` is an ordered list of
``(start, end, url)`` spans into the returned ``Text``.
"""

from __future__ import annotations

import re

from rich.text import Text

_SUBTEXT = "#a6adc8"
_LINK_STYLE = "underline #89b4fa"
_HEADING_STYLE = "bold #89b4fa"
_CODE_STYLE = "#f9e2af on #313244"
_TRAILING = ".,;:!?)]}>\"'"

# One regex, alternatives tried in order: markdown link, bare URL, bold, code,
# italic. Link is first so a URL inside `[..](..)` isn't also matched as bare.
_TOKEN = re.compile(
    r"(?P<link>\[(?P<ltext>[^\]]*)\]\(\s*<?(?P<lurl>[^)>\s]+)>?\s*\))"
    r"|(?P<bare>(?:https?://|www\.|mailto:)[^\s<>\"')\]]+)"
    r"|(?P<bold>\*\*(?P<btext>[^*]+)\*\*|__(?P<btext2>[^_]+)__)"
    r"|(?P<code>`(?P<ctext>[^`]+)`)"
    r"|(?P<ital>(?<![\w*_])[*_](?P<itext>[^*_\n]+)[*_](?![\w*_]))",
    re.I,
)


def _normalize(url: str) -> str:
    url = url.strip().rstrip(_TRAILING)
    if url.lower().startswith("www."):
        return "http://" + url
    return url


def render_body(md: str | None) -> tuple[Text, list[tuple[int, int, str]]]:
    text = Text()
    links: list[tuple[int, int, str]] = []
    if not md:
        return text, links
    for i, line in enumerate(md.split("\n")):
        if i:
            text.append("\n")
        _render_line(line, text, links)
    return text, links


def _render_line(line: str, text: Text, links: list) -> None:
    heading = re.match(r"^(#{1,6})\s+(.*)$", line)
    if heading:
        start = len(text.plain)
        _render_inline(heading.group(2), text, links)
        text.stylize(_HEADING_STYLE, start, len(text.plain))
        return
    bullet = re.match(r"^(\s*)(?:[-*+]|\d+\.)\s+(.*)$", line)
    if bullet:
        text.append(f"{bullet.group(1)}• ", style=_SUBTEXT)
        _render_inline(bullet.group(2), text, links)
        return
    if re.match(r"^\s*([-*_])\1{2,}\s*$", line):
        text.append("─" * 24, style=_SUBTEXT)
        return
    _render_inline(line, text, links)


def _render_inline(s: str, text: Text, links: list) -> None:
    pos = 0
    for m in _TOKEN.finditer(s):
        if m.start() > pos:
            text.append(s[pos : m.start()])
        if m.group("link"):
            label = (m.group("ltext") or "").strip() or m.group("lurl")
            _append_link(text, links, label, _normalize(m.group("lurl")))
        elif m.group("bare"):
            raw = m.group("bare").rstrip(_TRAILING)
            _append_link(text, links, raw, _normalize(raw))
        elif m.group("code"):
            text.append(m.group("ctext"), style=_CODE_STYLE)
        elif m.group("bold") or m.group("ital"):
            # Recurse so links nested inside emphasis are still detected, then
            # layer the emphasis style over the whole span.
            inner = m.group("btext") or m.group("btext2") or m.group("itext")
            start = len(text.plain)
            _render_inline(inner, text, links)
            text.stylize("bold" if m.group("bold") else "italic", start, len(text.plain))
        pos = m.end()
    if pos < len(s):
        text.append(s[pos:])


def _append_link(text: Text, links: list, label: str, url: str) -> None:
    start = len(text.plain)
    text.append(label, style=_LINK_STYLE)
    links.append((start, len(text.plain), url))

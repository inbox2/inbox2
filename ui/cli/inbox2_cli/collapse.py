"""Quoted-reply and signature collapsing for the terminal message view.

Ports the web app's detection logic (`ui/web/src/lib/quoteDetector.js` +
`signatureDetector.js`) to the CLI. The web detectors walk the HTML DOM; here we
work on the already-converted message text (html2text turns `<blockquote>` into
`>`-prefixed lines and keeps attribution lines like "On <date> X wrote:"),
splitting on newlines instead of `<br>`.

`split_message(text) -> Segments(body, signature, quoted)` — each field a text
string (possibly empty). Quotes are detected first; the signature detector then
runs on the remaining (non-quoted) body, matching the web's ordering (so a
signature buried inside a quoted reply is not separately collapsed).
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# ── Quote detection (mirrors LINE_QUOTE_PATTERNS) ────────────────────────────
_LINE_QUOTE_PATTERNS = [
    re.compile(r"\s*-{4,}\s*Original Message\s*-{4,}", re.I),
    re.compile(r"\s*-{4,}\s*Forwarded message\s*-{4,}", re.I),
    re.compile(r"\s*-{4,}\s*Oorspronkelijk bericht\s*-{4,}", re.I),
    re.compile(r"\s*-{4,}\s*Message original\s*-{4,}", re.I),
    re.compile(r"\s*-{4,}\s*Ursprüngliche Nachricht\s*-{4,}", re.I),
    re.compile(r"^On .{10,120} wrote:\s*$", re.I),
    re.compile(r"^Le .{10,80} a écrit\s?:\s*$", re.I),
    re.compile(r"^Am .{10,80} schrieb .{3,40}:\s*$", re.I),
    re.compile(r"^Op .{10,80} schreef .{3,40}:\s*$", re.I),
    re.compile(r"^El .{10,80} escribió:\s*$", re.I),
    re.compile(r"^Em .{10,80} escreveu:\s*$", re.I),
    re.compile(r"^Il .{10,80} ha scritto:\s*$", re.I),
]

# A markdown blockquote line (html2text's rendering of <blockquote> / gmail_quote).
_BLOCKQUOTE_LINE = re.compile(r"^\s*>")

# ── Signature detection (mirrors signatureDetector.js) ───────────────────────
_SIG_DELIM = re.compile(r"^--\s?$")
_MAX_SIG_LINES = 12
_CONTACT_LINE = re.compile(
    r"^(Phone|Mobile|Cell|Fax|Tel|Telephone|Office|Direct|Work|Home)\s*[:.]?\s*[\d(+]", re.I
)
_BARE_PHONE = re.compile(r"^\+?[(]?[\d][\d\s()._-]{6,}$")


@dataclass
class Segments:
    body: str
    signature: str
    quoted: str

    @property
    def has_signature(self) -> bool:
        return bool(self.signature)

    @property
    def has_quote(self) -> bool:
        return bool(self.quoted)


def split_message(text: str | None) -> Segments:
    """Split a message body into (body, signature, quoted) text segments."""
    lines = (text or "").split("\n")
    q_start = _find_quote_start(lines)
    if q_start is None:
        body_lines, quoted_lines = lines, []
    else:
        body_lines, quoted_lines = lines[:q_start], lines[q_start:]

    body_lines, sig_lines = _split_signature(body_lines)
    return Segments(
        body="\n".join(body_lines).strip(),
        signature="\n".join(sig_lines).strip(),
        quoted="\n".join(quoted_lines).strip(),
    )


def _find_quote_start(lines: list[str]) -> int | None:
    """Index of the first quoted line, or None. Strategy 1: a line matching a
    known quote-start pattern (attribution / "Original Message" banners).
    Strategy 2: the start of a trailing run of markdown blockquote (`>`) lines —
    html2text's rendering of structural quote containers."""
    for i, line in enumerate(lines):
        t = line.strip()
        if not t:
            continue
        if any(p.search(t) for p in _LINE_QUOTE_PATTERNS):
            return i

    # Trailing blockquote run: find the last non-empty line; if it's a `>` line,
    # walk up across `>`/blank lines to the start of the block.
    last = len(lines) - 1
    while last > 0 and not lines[last].strip():
        last -= 1
    if last <= 0 or not _BLOCKQUOTE_LINE.match(lines[last]):
        return None
    start = last
    seen_quote = False
    while start > 0:
        prev = lines[start - 1]
        if _BLOCKQUOTE_LINE.match(prev):
            seen_quote = True
            start -= 1
        elif not prev.strip():
            start -= 1  # absorb blank lines inside the quoted region
        else:
            break
    # Don't collapse a quote that starts at line 0 (the whole message is quoted).
    return start if (seen_quote and start > 0) else None


def _split_signature(lines: list[str]) -> tuple[list[str], list[str]]:
    """Return (body_lines, signature_lines). Strategy 2: the RFC 3676 `-- `
    delimiter. Strategy 3: a contact-block heuristic (name + phone lines)."""
    delim = _detect_by_delimiter(lines)
    if delim is not None:
        return delim
    contact = _detect_contact_block(lines)
    if contact is not None:
        return contact
    return lines, []


def _detect_by_delimiter(lines: list[str]) -> tuple[list[str], list[str]] | None:
    for i, line in enumerate(lines):
        if _SIG_DELIM.match(line.strip()):
            remaining = [l for l in lines[i + 1 :] if l.strip()]
            if len(remaining) <= _MAX_SIG_LINES and i > 0:
                return lines[:i], lines[i:]
            return None  # first delimiter failed the guard — give up (as the web does)
    return None


def _is_contact_line(text: str) -> bool:
    return bool(_CONTACT_LINE.search(text) or _BARE_PHONE.match(text))


def _is_signature_label(text: str) -> bool:
    """A short line that could be a name/company/title/sign-off (not body prose)."""
    return 0 < len(text) < 40 and len(text.split()) <= 4 and not re.search(r"\d", text)


def _detect_contact_block(lines: list[str]) -> tuple[list[str], list[str]] | None:
    """Port of detectContactBlock: a name + contact-info block at the message end,
    even without a `-- ` delimiter. Wraps only the block; trailing content (e.g. a
    URL below the signature) is preserved in the body."""
    texts = [l.strip() for l in lines]
    scan_end = len(lines) - 1
    while scan_end > 0 and not texts[scan_end]:
        scan_end -= 1

    contact_end = contact_start = -1
    for i in range(scan_end, -1, -1):
        if _is_contact_line(texts[i]):
            if contact_end == -1:
                contact_end = i
            contact_start = i
        elif contact_end != -1:
            break
    if contact_start < 0:
        return None

    block_start = contact_start
    idx = contact_start - 1
    extras = 0
    while idx > 0 and not texts[idx]:
        idx -= 1
    while idx > 0 and extras < 3:
        if not texts[idx]:
            idx -= 1
            continue
        if _is_signature_label(texts[idx]):
            block_start = idx
            extras += 1
            idx -= 1
            while idx > 0 and not texts[idx]:
                idx -= 1
        else:
            break

    if not _is_signature_label(texts[block_start]) or block_start <= 0:
        return None

    wrap_start = block_start
    while wrap_start > 1 and not texts[wrap_start - 1]:
        wrap_start -= 1

    body = lines[:wrap_start] + lines[contact_end + 1 :]
    sig = lines[wrap_start : contact_end + 1]
    return body, sig

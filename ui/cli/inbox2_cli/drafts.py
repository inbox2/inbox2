"""Plain-text reply/forward body builders.

Text-only port of `ui/web/src/lib/draftBuilders.js`. The CLI only handles text
bodies, so quotes use the conventional `>` prefix and forwards use the standard
delimiter block, rather than the web app's HTML blockquotes.
"""

from __future__ import annotations

from typing import Iterable


def _fmt_date(value: str | None) -> str:
    return value or ""


def quote_reply(message: dict) -> str:
    """A `>`-prefixed quote of a single message, for replies."""
    sender = message.get("from_address") or ""
    date = _fmt_date(message.get("created_at"))
    body = (message.get("body_plain") or "").rstrip()
    header = f"On {date}, {sender} wrote:" if date or sender else "Previously:"
    quoted = "\n".join(f"> {line}" for line in body.splitlines()) if body else "> "
    return f"\n\n{header}\n{quoted}\n"


def forward_one(message: dict) -> str:
    """A forwarded-message block for a single message."""
    lines = [
        "",
        "",
        "---------- Forwarded message ----------",
        f"From: {message.get('from_address') or ''}",
        f"Date: {_fmt_date(message.get('created_at'))}",
        f"Subject: {message.get('subject') or ''}",
        f"To: {message.get('to_address') or ''}",
        "",
        (message.get("body_plain") or "").rstrip(),
        "",
    ]
    return "\n".join(lines)


def forward_chain(messages: Iterable[dict]) -> str:
    """Forward an entire conversation (newest first), each as a block."""
    blocks = [forward_one(m) for m in messages]
    return "\n".join(blocks)


def reply_subject(subject: str | None) -> str:
    subject = subject or ""
    return subject if subject.startswith("Re: ") else f"Re: {subject}"


def forward_subject(subject: str | None) -> str:
    subject = subject or ""
    return subject if subject.startswith("Fwd: ") else f"Fwd: {subject}"


def reply_all_recipients(message: dict, self_address: str | None) -> str:
    """Comma-joined recipient list for reply-all, excluding self."""
    addresses: list[str] = []
    for field in ("from_address", "to_address", "cc_address"):
        value = message.get(field)
        if not value:
            continue
        for addr in str(value).split(","):
            addr = addr.strip()
            if addr and addr != self_address and addr not in addresses:
                addresses.append(addr)
    return ", ".join(addresses)

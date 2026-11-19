"""Gmail-style search operators → SQL, for the local FTS5 search.

Port of `ui/web/src/lib/searchQuery.js` (`parse` + `toSqlite`): the search box
speaks `from: to: cc: subject: filename: type: is:/has: in: larger: smaller:
after: before:` plus free text. Free text becomes an FTS5 MATCH over
`messages_fts` (prefix-matched words, quoted phrases kept whole); the operators
become plain WHERE fragments on the `messages` (`m`) / `conversations` (`c`)
aliases. Anything that isn't a recognised operator stays in the free text.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .constants import STATUS_ARCHIVED, STATUS_OPEN, STATUS_SPAM, STATUS_TRASH

LIST_FIELDS = ("from", "to", "cc", "subject", "filename", "type")
IS_FLAGS = ("read", "unread", "urgent", "important", "attachment")
IN_SCOPES = ("inbox", "archive", "trash", "spam", "anywhere")
_SCOPE_STATUS = {"inbox": STATUS_OPEN, "archive": STATUS_ARCHIVED, "trash": STATUS_TRASH, "spam": STATUS_SPAM}
# A search never reaches into trash/spam unless asked (`in:trash` / `in:anywhere`).
DISCARDED_STATUSES = (STATUS_TRASH, STATUS_SPAM)

_SIZE_UNITS = {"b": 1, "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9}
_TOKEN = re.compile(r'(?:[^\s"]+:)?"[^"]*"|\S+')
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_WORD = re.compile(r"\w[\w@.'-]*", re.UNICODE)  # tokens start on a word char: `-x` is `x`


@dataclass
class Query:
    text: str = ""
    from_: list[str] = field(default_factory=list)
    to: list[str] = field(default_factory=list)
    cc: list[str] = field(default_factory=list)
    subject: list[str] = field(default_factory=list)
    filename: list[str] = field(default_factory=list)
    type: list[str] = field(default_factory=list)
    is_: list[str] = field(default_factory=list)
    in_: str | None = None
    larger: int | None = None
    smaller: int | None = None
    after: str | None = None
    before: str | None = None

    def lists(self, name: str) -> list[str]:
        return getattr(self, "from_" if name == "from" else name)

    @property
    def is_empty(self) -> bool:
        return not self.text and not self.has_operators

    @property
    def has_operators(self) -> bool:
        return bool(
            any(self.lists(f) for f in LIST_FIELDS) or self.is_ or self.in_
            or self.larger is not None or self.smaller is not None or self.after or self.before
        )


def parse_size(raw: str) -> int | None:
    m = re.match(r"^(\d+(?:\.\d+)?)\s*([a-z]*)$", raw.strip(), re.I)
    if not m:
        return None
    unit = _SIZE_UNITS.get(m.group(2).lower() or "b")
    return round(float(m.group(1)) * unit) if unit else None


def _unquote(v: str) -> str:
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] == '"' else v


def parse(text: str | None) -> Query:
    q = Query()
    free: list[str] = []
    for token in _TOKEN.findall(text or ""):
        at = token.find(":")
        if at <= 0:
            free.append(token)
            continue
        fld, value = token[:at].lower(), _unquote(token[at + 1 :])
        if not value:
            free.append(token)
        elif fld in LIST_FIELDS:
            q.lists(fld).append(value)
        elif fld in ("is", "has"):
            flag = value.lower()
            if flag in IS_FLAGS:
                if flag not in q.is_:
                    q.is_.append(flag)
            else:
                free.append(token)
        elif fld == "in":
            if value.lower() in IN_SCOPES:
                q.in_ = value.lower()
            else:
                free.append(token)
        elif fld in ("larger", "smaller"):
            n = parse_size(value)
            if n is None:
                free.append(token)
            else:
                setattr(q, fld, n)
        elif fld in ("after", "before"):
            if _DATE.match(value):
                setattr(q, fld, value)
            else:
                free.append(token)
        else:
            free.append(token)
    q.text = " ".join(free)
    return q


def fts_match(text: str) -> str:
    """Free text → an FTS5 MATCH expression: each word prefix-matched, quoted
    phrases kept whole. Everything is re-quoted so user punctuation can't turn
    into FTS syntax (a bare `-` or `:` is a syntax error there)."""
    parts: list[str] = []
    for tok in _TOKEN.findall(text):
        if len(tok) >= 2 and tok[0] == tok[-1] == '"':
            phrase = " ".join(_WORD.findall(tok[1:-1]))
            if phrase:
                parts.append(f'"{phrase}"')
        else:
            for w in _WORD.findall(tok):
                parts.append(f'"{w}"*')
    return " ".join(parts)


def to_sql(q: Query, *, mx: bool = False) -> tuple[list[str], list]:
    """WHERE fragments + bound params for the operators. ``m`` is the message
    alias, ``c`` the conversation alias. The MX mirror keeps message fields in a
    JSON payload, so there the people/subject/attachment operators fall back to
    the conversation's own columns."""
    where: list[str] = []
    params: list = []

    def any_like(col: str, values: list[str]) -> None:
        where.append("(" + " OR ".join(f"LOWER({col}) LIKE ?" for _ in values) + ")")
        params.extend(f"%{v.lower()}%" for v in values)

    if q.from_:
        any_like("c.from_address" if mx else "m.from_address", q.from_)
    if q.to:
        any_like("c.to_address" if mx else "m.to_address", q.to)
    if q.cc and not mx:
        any_like("m.cc_address", q.cc)
    if q.subject:
        any_like("c.subject", q.subject)
    if not mx:
        if q.filename:
            any_like("m.attachment_names", q.filename)
        if q.type:
            any_like("m.attachment_names", ["." + t.lstrip(".") for t in q.type])
        if q.larger is not None:
            where.append("m.attachment_max_size > ?")
            params.append(q.larger)
        if q.smaller is not None:
            where.append("m.attachment_max_size > 0 AND m.attachment_max_size < ?")
            params.append(q.smaller)
        if "attachment" in q.is_:
            where.append("c.has_attachment = 1")
        if "urgent" in q.is_:
            where.append("c.priority_urgent = 1")
        if "important" in q.is_:
            where.append("c.priority_important = 1")
    if "read" in q.is_:
        where.append("c.read = 1")
    if "unread" in q.is_:
        where.append("c.read = 0")
    if q.after:
        where.append("c.updated_at >= ?")
        params.append(q.after)
    if q.before:
        where.append("c.updated_at < ?")
        params.append(f"{q.before}T23:59:59Z")
    status = _SCOPE_STATUS.get(q.in_ or "")
    if status:
        where.append("c.status = ?")
        params.append(status)
    elif q.in_ != "anywhere":
        where.append("c.status NOT IN (" + ",".join("?" for _ in DISCARDED_STATUSES) + ")")
        params.extend(DISCARDED_STATUSES)
    return where, params

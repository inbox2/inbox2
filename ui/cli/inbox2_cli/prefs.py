"""Client-side CLI preferences.

Mirrors the web app's Settings (mark-as-read mechanism, theme, sort order,
notifications, signature). The web client stores these in its own (webview)
localStorage; the CLI is a separate process, so it keeps its own copy in
``<data_dir>/cli_prefs.json``. Mark-as-read defaults to Outlook's "after 5
seconds" dwell and implements the same four modes.

Environment overrides (handy for testing): ``INBOX2_MARK_READ_MODE`` and
``INBOX2_MARK_READ_DELAY``.
"""

from __future__ import annotations

import json
import os

from .constants import (
    DEFAULT_MARK_READ_DELAY,
    DEFAULT_MARK_READ_MODE,
    DEFAULT_THEME,
    MARK_READ_MODES,
    SORT_NEWEST,
    SORT_ORDERS,
)
from .runtime import default_data_dir

_cache: dict | None = None


def _path():
    return default_data_dir() / "cli_prefs.json"


def _file() -> dict:
    global _cache
    if _cache is None:
        try:
            _cache = json.loads(_path().read_text())
        except (OSError, ValueError):
            _cache = {}
    return _cache


def get(key: str, default=None):
    return _file().get(key, default)


def set(key: str, value) -> None:  # noqa: A001 — mirrors localStorage's get/set
    data = _file()
    if data.get(key) == value:
        return
    data[key] = value
    try:
        _path().parent.mkdir(parents=True, exist_ok=True)
        _path().write_text(json.dumps(data, indent=2))
    except OSError:
        pass  # a convenience default; never fail the action over it


def mark_read_mode() -> str:
    env = os.environ.get("INBOX2_MARK_READ_MODE")
    if env in MARK_READ_MODES:
        return env
    v = get("mark_read_mode")
    return v if v in MARK_READ_MODES else DEFAULT_MARK_READ_MODE


def mark_read_delay() -> float:
    raw = os.environ.get("INBOX2_MARK_READ_DELAY")
    if raw is None:
        raw = get("mark_read_delay")
    try:
        n = float(raw)
        return n if n > 0 else DEFAULT_MARK_READ_DELAY
    except (TypeError, ValueError):
        return DEFAULT_MARK_READ_DELAY


def theme() -> str:
    return get("theme") or DEFAULT_THEME


def sort_order() -> str:
    v = get("sort")
    return v if v in SORT_ORDERS else SORT_NEWEST


def notifications() -> bool:
    return bool(get("notifications", True))


def signature() -> str:
    return (get("signature") or "").strip()


def last_account(kind: str) -> str | None:
    """The account last sent from (``from``) / last created an event on
    (``event``) — the default when no channel is filtered."""
    return get(f"last_{kind}_account")


def set_last_account(kind: str, account_key: str) -> None:
    if account_key:
        set(f"last_{kind}_account", account_key)

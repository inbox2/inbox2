"""Shared fixtures: a seeded temp SQLite DB and an in-process fake engine bus.

These let the Textual Pilot tests drive the whole TUI headlessly — no daemon, no
socket, no network, no live accounts.
"""

from __future__ import annotations

import datetime as dt
import sqlite3

import pytest

from inbox2_cli.db import Database

# Minimal subset of the real schema (001_create_schema.sql) the CLI touches.
SCHEMA = """
CREATE TABLE external_accounts (
  key TEXT PRIMARY KEY, display_name TEXT, email_address TEXT,
  provider_type TEXT, status TEXT, sort_order INTEGER DEFAULT 0
);
CREATE TABLE conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, organization_id TEXT,
  subject TEXT, from_address TEXT, to_address TEXT, snippet TEXT,
  read INTEGER DEFAULT 0, status TEXT DEFAULT 'open', has_attachment INTEGER DEFAULT 0,
  priority_urgent INTEGER DEFAULT 0, priority_important INTEGER DEFAULT 0, priority_triaged INTEGER DEFAULT 0,
  triage_label TEXT, triage_priority REAL, space_slug TEXT, space_manual INTEGER DEFAULT 0,
  updated_at TEXT
);
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, conversation_key TEXT,
  account_key TEXT, from_address TEXT, to_address TEXT, cc_address TEXT,
  subject TEXT, body_plain TEXT, body_html TEXT, attachment_names TEXT, attachment_max_size INTEGER,
  is_inbound INTEGER DEFAULT 1, is_draft INTEGER DEFAULT 0, message_id_header TEXT, created_at TEXT
);
-- FTS5 over messages, kept in sync by the same triggers the engine installs.
CREATE VIRTUAL TABLE messages_fts USING fts5(
  subject, body_plain, from_address, to_address, attachment_names, content=messages, content_rowid=id);
CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES (new.id, new.subject, new.body_plain, new.from_address, new.to_address, new.attachment_names);
END;
CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES ('delete', old.id, old.subject, old.body_plain, old.from_address, old.to_address, old.attachment_names);
  INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address, attachment_names)
  VALUES (new.id, new.subject, new.body_plain, new.from_address, new.to_address, new.attachment_names);
END;
CREATE TABLE engine_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE outbox_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, account_key TEXT, payload TEXT,
  status TEXT DEFAULT 'pending', retry_count INTEGER DEFAULT 0, error_message TEXT,
  created_at TEXT, kind TEXT DEFAULT 'send', draft_key TEXT
);
-- MX mirror (docs/MX-Sync.md) — the columns the CLI reads.
CREATE TABLE mx_sync_state (organization_id TEXT PRIMARY KEY, user_key TEXT, backfill_done INTEGER DEFAULT 0);
CREATE TABLE mx_directory (organization_id TEXT, type TEXT, key TEXT, position INTEGER DEFAULT 0, payload TEXT);
CREATE TABLE mx_conversations (
  key TEXT PRIMARY KEY, organization_id TEXT, domain_key TEXT, subject TEXT, from_address TEXT, to_address TEXT, snippet TEXT,
  read INTEGER DEFAULT 0, status TEXT, updated_at TEXT, payload TEXT,
  triage_label TEXT, triage_priority REAL, space_slug TEXT);
CREATE TABLE mx_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, conversation_key TEXT, organization_id TEXT,
  is_draft INTEGER DEFAULT 0, created_at TEXT, payload TEXT, plain TEXT, search_text TEXT);
CREATE VIRTUAL TABLE mx_messages_fts USING fts5(search_text, content=mx_messages, content_rowid=id);
CREATE TRIGGER mx_messages_fts_ai AFTER INSERT ON mx_messages BEGIN
  INSERT INTO mx_messages_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;
CREATE TABLE external_folders (
  key TEXT PRIMARY KEY, account_key TEXT, provider_name TEXT, well_known_role TEXT, flags TEXT, sync_enabled INTEGER DEFAULT 0
);
CREATE TABLE message_provider_state (
  message_key TEXT, account_key TEXT, folder_key TEXT, labels TEXT
);
CREATE TABLE calendars (
  key TEXT UNIQUE, account_key TEXT, name TEXT, color TEXT,
  provider_id TEXT, is_primary INTEGER DEFAULT 0, is_writable INTEGER DEFAULT 1,
  is_owned INTEGER DEFAULT 1
);
CREATE TABLE calendar_events (
  key TEXT UNIQUE, calendar_key TEXT, account_key TEXT, provider_id TEXT,
  title TEXT, description TEXT, location TEXT, start_at TEXT, end_at TEXT,
  all_day INTEGER DEFAULT 0, status TEXT DEFAULT 'confirmed', organizer_email TEXT, organizer_name TEXT,
  metadata TEXT
);
CREATE TABLE calendar_attendees (
  key TEXT UNIQUE, event_key TEXT, email TEXT, name TEXT, response_status TEXT DEFAULT 'needs_action',
  is_organizer INTEGER DEFAULT 0, is_optional INTEGER DEFAULT 0
);
"""

ACCOUNT_KEY = "acct_a"


def seed(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.execute(
        "INSERT INTO external_accounts VALUES (?,?,?,?,?,?)",
        (ACCOUNT_KEY, "Work", "me@work.com", "gmail", "connected", 0),
    )
    conn.execute(
        "INSERT INTO external_accounts VALUES (?,?,?,?,?,?)",
        ("acct_b", "Personal", "me@home.com", "microsoft", "connected", 1),
    )
    # Two open conversations (one unread) + one archived. conv2 carries an
    # attachment (drives the paperclip + attachments-view tests).
    conns = [
        ("conv1", "Hello there", "bob@x.com", 0, "open", 0, "2026-05-30T10:00:00Z"),
        ("conv2", "Lunch?", "sue@x.com", 1, "open", 1, "2026-05-29T09:00:00Z"),
        ("conv3", "Old thread", "ned@x.com", 1, "archived", 0, "2026-05-01T09:00:00Z"),
    ]
    for key, subj, frm, read, status, has_attachment, updated in conns:
        conn.execute(
            "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, has_attachment, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (key, ACCOUNT_KEY, subj, frm, "me@work.com", subj, read, status, has_attachment, updated),
        )
    conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, is_inbound, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        ("msg1", "conv1", ACCOUNT_KEY, "bob@x.com", "me@work.com", "Hello there",
         "Hi, how are you?\n\nOn Mon, May 4 2026 Sue <sue@x.com> wrote:\n> earlier message\n> second line",
         1, "2026-05-30T10:00:00Z"),
    )
    # conv2's message is HTML-only (no text/plain) — exercises HTML→text rendering.
    conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, body_html, is_inbound, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("msg2", "conv2", ACCOUNT_KEY, "sue@x.com", "me@work.com", "Lunch?", "",
         "<html><body><p>Lunch at <b>noon</b>? See <a href='http://example.com/menu'>the menu</a> "
         "or <a href='http://example.com/book'>book</a>.</p></body></html>",
         1, "2026-05-29T09:00:00Z"),
    )
    # Inbox membership is synced provider folder state (the desktop's inbox rule):
    # each account's inbox folder, and the open threads' messages filed in it.
    for acct in (ACCOUNT_KEY, "acct_b"):
        conn.execute(
            "INSERT INTO external_folders (key, account_key, provider_name, well_known_role, sync_enabled) VALUES (?,?,?,?,1)",
            (f"{acct}:INBOX", acct, "INBOX", "inbox"),
        )
    for msg in ("msg1", "msg2"):
        conn.execute(
            "INSERT INTO message_provider_state (message_key, account_key, folder_key, labels) VALUES (?,?,?,?)",
            (msg, ACCOUNT_KEY, f"{ACCOUNT_KEY}:INBOX", '["INBOX"]'),
        )
    # A calendar + an event in the current month so the agenda window catches it.
    conn.execute(
        "INSERT INTO calendars (key, account_key, name, color, provider_id, is_primary, is_writable, is_owned)"
        " VALUES (?,?,?,?,?,?,?,?)",
        ("cal_a", ACCOUNT_KEY, "Primary", "#3B82F6", "primary-gcal", 1, 1, 1),
    )
    # An account with no primary calendar, whose read-only "Birthdays" sorts
    # ahead of the writable one — creating an event there 403s.
    conn.executemany(
        "INSERT INTO calendars (key, account_key, name, color, provider_id, is_primary, is_writable, is_owned)"
        " VALUES (?,?,?,?,?,?,?,?)",
        (
            ("cal_ro", "acct_ro", "Birthdays", "#888888", "birthdays-gcal", 0, 0, 1),
            ("cal_rw", "acct_ro", "Work", "#3B82F6", "work-gcal", 0, 1, 1),
            # Someone else's calendar, shared with write access: writable, not
            # ours, so it must not be offered as a create target either.
            ("cal_shared", "acct_ro", "Transferred from ali", "#888888", "ali-gcal", 0, 1, 0),
        ),
    )
    today = dt.date.today()
    start = dt.datetime(today.year, today.month, 15, 14, 0, 0)
    end = start + dt.timedelta(hours=1)
    conn.execute(
        "INSERT INTO calendar_events (key, calendar_key, account_key, provider_id, title, start_at, end_at, all_day, status) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        ("ev1", "cal_a", ACCOUNT_KEY, "gcal-ev-1", "Standup", start.isoformat() + "Z", end.isoformat() + "Z", 0, "confirmed"),
    )
    conn.commit()
    conn.close()


def file_in_inbox(conn, conversation_key: str, account_key: str, message_key: str | None = None) -> None:
    """What a real sync does with new mail: a message of the thread filed in the
    account's inbox folder — which is what puts the thread in the Inbox (db.inbox)."""
    folder = f"{account_key}:INBOX"
    conn.execute(
        "INSERT OR IGNORE INTO external_folders (key, account_key, provider_name, well_known_role, sync_enabled) VALUES (?,?,?,?,1)",
        (folder, account_key, "INBOX", "inbox"),
    )
    msg = message_key or f"{conversation_key}_m"
    conn.execute(
        "INSERT OR IGNORE INTO messages (key, conversation_key, account_key, created_at) VALUES (?,?,?,?)",
        (msg, conversation_key, account_key, "2026-06-01T00:00:00Z"),
    )
    conn.execute(
        "INSERT INTO message_provider_state (message_key, account_key, folder_key, labels) VALUES (?,?,?,?)",
        (msg, account_key, folder, '["INBOX"]'),
    )


class FakeBus:
    """Records RPC calls and lets tests push events into the app."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []
        self.on_event = None
        self.results: dict[str, object] = {}

    async def call(self, method: str, params: dict | None = None, timeout: float = 60.0):
        self.calls.append((method, params or {}))
        return self.results.get(method)

    async def close(self):
        return None

    def push(self, event: str, payload: dict | None = None):
        if self.on_event:
            self.on_event(event, payload or {})

    def methods(self) -> list[str]:
        return [m for m, _ in self.calls]

    def last(self, method: str) -> dict | None:
        for m, p in reversed(self.calls):
            if m == method:
                return p
        return None


@pytest.fixture
def db_path(tmp_path):
    path = str(tmp_path / "inbox2.db")
    seed(path)
    return path


@pytest.fixture
def database(db_path):
    db = Database(db_path)
    yield db
    db.close()


@pytest.fixture
def fake_bus():
    return FakeBus()


@pytest.fixture
def make_app(db_path, fake_bus):
    from inbox2_cli.app import Inbox2App

    def _make():
        return Inbox2App(db=Database(db_path), bus=fake_bus)

    return _make

"""Direct SQLite access to the shared `inbox2.db`.

The Python TUI reads lists/threads/calendar straight from the same WAL database
the Rust engine writes — exactly like the desktop webview reads via
tauri-plugin-sql. All provider I/O and write-back goes through the engine bus
(see `bus.py`); the only writes done here are the optimistic conversation
status/read flips the UI applies for immediate feedback (mirroring the web app's
useInboxKeyboardNav, which also UPDATEs SQLite directly before the engine syncs).

Synced data convention (see store.rs): a conversation's `organization_id` is the
owning account's key, and `messages.account_key` is that same key.
"""

from __future__ import annotations

import json
import sqlite3
from email.utils import parseaddr
from datetime import datetime, timezone
from typing import Sequence

from . import search as searchq
from .constants import (
    OUTBOX_SENT,
    FOLDER_ROLE_INBOX,
    INBOX_HIDDEN_STATUSES,
    MX_TAG_IMPORTANT,
    MX_TAG_LATER,
    MX_TAG_URGENT,
    PROVIDER_INBOX2,
    SPACE_TRIAGE,
    STATUS_OPEN,
    STATUS_SPAM,
    STATUS_TRASH,
    TRIAGE_LABELS,
    VIEW_DRAFTS,
    VIEW_SENT,
)

# The list-row columns every conversation query returns, so the screen renders
# channel rows and MX rows the same way.
_CONV_FIELDS = (
    "key", "organization_id", "subject", "from_address", "to_address", "snippet", "read", "status",
    "has_attachment", "priority_urgent", "priority_important", "triage_label", "triage_priority",
    "space_slug", "updated_at",
)


def _cols(alias: str = "") -> str:
    p = f"{alias}." if alias else ""
    return ", ".join(f"{p}organization_id AS account_key" if f == "organization_id" else f"{p}{f}" for f in _CONV_FIELDS)


_CONV_COLS = _cols()


def _mx_account(alias: str = "") -> str:
    """An MX thread's channel: its domain (`mx_conversations.domain_key`, the
    column the engine syncs — the desktop has one tab per domain), or the org
    itself for a thread the server gave no domain."""
    p = f"{alias}." if alias else ""
    return f"COALESCE({p}domain_key, {p}organization_id)"


def _mx_has_tag(alias: str, *names: str) -> str:
    """SQL: the MX thread carries one of these tag names (priority lives in tags)."""
    p = f"{alias}." if alias else ""
    quoted = ", ".join(f"'{n}'" for n in names)
    return (f"(json_valid({p}payload) AND EXISTS (SELECT 1 FROM json_each({p}payload, '$.tags') t "
            f"WHERE json_extract(t.value, '$.name') IN ({quoted})))")


_HIDDEN = ", ".join(f"'{s}'" for s in INBOX_HIDDEN_STATUSES)
# Local triaged = placed in a quadrant: a priority flag, or Later's explicit marker
# (web useUnifiedInbox LOCAL_TRIAGED_SQL).
_LOCAL_TRIAGED = "(priority_urgent = 1 OR priority_important = 1 OR priority_triaged = 1)"
# An MX thread's Inbox: open, and something has come in on it (the API's rule).
_MX_LORE_DONE = "COALESCE(CASE WHEN json_valid(payload) THEN json_extract(payload, '$.lore_done') END, 0)"
_MX_INBOX = f"status = '{STATUS_OPEN}' AND COALESCE(CASE WHEN json_valid(payload) THEN json_extract(payload, '$.sent_only') END, 0) = 0"
_MX_TRIAGED = _mx_has_tag("", MX_TAG_URGENT, MX_TAG_IMPORTANT, MX_TAG_LATER)
# The MX mirror has no attachment/priority columns (those ride in `payload` /
# don't exist for org mail), so it selects constants in their place.
_MX_CONV_COLS = ", ".join(
    "0 AS has_attachment" if f == "has_attachment"
    else "0 AS priority_urgent" if f == "priority_urgent"
    else "0 AS priority_important" if f == "priority_important"
    else f"{_mx_account()} AS account_key" if f == "organization_id"
    else f
    for f in _CONV_FIELDS
)
# Provider labels the sidebar never shows: Gmail's category tabs and the
# inbox2/<quadrant> triage labels (those render as the quadrant marks instead).
_HIDDEN_LABEL_PREFIXES = ("CATEGORY_", "inbox2/")


def _when(stamp: str | None) -> datetime:
    """Sort key across sources: channel rows and the MX mirror don't promise one
    timestamp spelling ('…T10:00:00Z', '… 10:00:00', '+00:00'), and comparing them
    as text misorders the same day."""
    try:
        parsed = datetime.fromisoformat((stamp or "").replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def _parse_addresses(raw: str | None) -> list[tuple[str, str]]:
    """`"Name" <a@x>, b@y` → [(Name, a@x), ("", b@y)]. Commas inside a quoted
    display name are kept with the name."""
    from email.utils import getaddresses

    out = []
    for name, email in getaddresses([raw or ""]):
        if email and "@" in email:
            out.append((name.strip().strip('"'), email.strip()))
    return out


def _merge(rows: list[dict], mx: list[dict], limit: int) -> list[dict]:
    if mx:
        rows = sorted(rows + mx, key=lambda r: _when(r["updated_at"]), reverse=True)
    return rows[:limit]


class Database:
    def __init__(self, path: str):
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        # Cooperate with the engine's concurrent writes.
        self.conn.execute("PRAGMA busy_timeout = 4000")
        try:
            self.conn.execute("PRAGMA journal_mode = WAL")
        except sqlite3.OperationalError:
            pass

    def close(self) -> None:
        self.conn.close()

    # ── change detection (cheap refresh coalescing) ─────────────────────────
    def data_version(self) -> int:
        """SQLite's per-connection change counter; bumps when another connection
        commits. Used to skip redundant re-queries between bus events."""
        row = self.conn.execute("PRAGMA data_version").fetchone()
        return int(row[0]) if row else 0

    def _rows(self, sql: str, params: Sequence = ()) -> list[dict]:
        return [dict(r) for r in self.conn.execute(sql, params).fetchall()]

    # ── accounts / channels ──────────────────────────────────────────────────
    def list_accounts(self) -> list[dict]:
        rows = self.conn.execute(
            "SELECT key, display_name, email_address, provider_type, status "
            "FROM external_accounts ORDER BY sort_order, display_name"
        ).fetchall()
        return [dict(r) for r in rows] + self.mx_accounts()

    def is_mx(self, account_key: str) -> bool:
        return any(a["key"] == account_key for a in self.mx_accounts())

    def _split(self, account_keys: Sequence[str]) -> tuple[list[str], list[str]]:
        """(channel keys, MX org keys) — MX orgs only exist in the mx_* tables."""
        mx = {a["key"] for a in self.mx_accounts()}
        return [k for k in account_keys if k not in mx], [k for k in account_keys if k in mx]

    def engine_setting(self, key: str):
        """A JSON value from `engine_settings` (the engine's own key/value store),
        or None. Non-JSON values come back as their raw string."""
        try:
            row = self.conn.execute("SELECT value FROM engine_settings WHERE key = ?", (key,)).fetchone()
        except sqlite3.OperationalError:
            return None
        if not row:
            return None
        try:
            return json.loads(row[0])
        except ValueError:
            return row[0]

    # ── MX mirror (docs/MX-Sync.md) ────────────────────────────────────────
    # inbox2-hosted mail the engine keeps in the `mx_*` tables, one "account" per
    # mirrored org. Each row's `payload` is the API's JSON; the list columns are
    # real. An older database without the tables simply has no MX accounts.
    def _mx(self, sql: str, params: Sequence = ()) -> list:
        try:
            return self.conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as e:
            # Only "this database predates the mirror". A lock, corruption or a bad
            # query must not read as "no MX mail".
            if "no such table" in str(e):
                return []
            raise

    @staticmethod
    def _payload(raw: str | None) -> dict:
        """One unreadable payload must cost one row, not the whole list."""
        try:
            value = json.loads(raw) if raw else {}
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}

    def _mx_write(self, sql: str, params: Sequence) -> None:
        try:
            self.conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "no such table" not in str(e):
                raise

    def mx_accounts(self) -> list[dict]:
        """One channel per mirrored domain, like the desktop's per-domain tabs
        (`org_key` is the org the engine's MX calls take); an org the directory
        lists no domains for is one channel keyed by the org."""
        rows = self._mx(
            "SELECT s.organization_id AS key, d.payload AS org, s.backfill_done "
            "FROM mx_sync_state s LEFT JOIN mx_directory d "
            "ON d.organization_id = s.organization_id AND d.type = 'organization' "
            "ORDER BY s.organization_id"
        )
        accounts = []
        for r in rows:
            org = self._payload(r["org"])
            status = "connected" if r["backfill_done"] else "syncing"
            # The org's domains as the engine mirrors them: `domains` directory rows.
            domains = [
                {"id": d["key"], "name": self._payload(d["payload"]).get("name")}
                for d in self._mx(
                    "SELECT key, payload FROM mx_directory WHERE organization_id = ? AND type = 'domains' "
                    "ORDER BY position, key",
                    (r["key"],),
                )
            ]
            # Threads assigned or shared from a domain the member isn't scoped to
            # still carry its key: give each such domain a channel too, named
            # after an address on it (the directory has no row for it).
            known = {d["id"] for d in domains}
            for k, addr in self._mx(
                "SELECT domain_key, MAX(to_address) FROM mx_conversations "
                "WHERE organization_id = ? AND domain_key IS NOT NULL GROUP BY domain_key ORDER BY domain_key",
                (r["key"],),
            ):
                if k not in known:
                    host = (addr or "").rpartition("@")[2].strip("> ,") or None
                    domains.append({"id": k, "name": host})
            me = self._mx_me(r["key"])
            # Threads without a domain are keyed by the org (_mx_account), so they
            # need the org-wide channel too, even beside domain channels.
            if not domains or self._mx(
                "SELECT 1 FROM mx_conversations WHERE organization_id = ? AND domain_key IS NULL LIMIT 1",
                (r["key"],),
            ):
                domains.append({"id": r["key"], "name": None})
            for d in domains:
                sendable = self._mx_from_addresses(me, (d.get("name") or org.get("domain") or "").lower())
                accounts.append({
                    "key": d["id"],
                    "org_key": r["key"],
                    # A domain tab is named for its domain; the org-wide fallback for the org.
                    "display_name": d.get("name") or org.get("name") or r["key"],
                    # Who you send as here (Membership#from_addresses on this host).
                    "email_address": sendable[0] if sendable else "",
                    "from_addresses": sendable,
                    "provider_type": PROVIDER_INBOX2,
                    "status": status,
                })
        return accounts

    def _mx_me(self, org_key: str) -> dict:
        """The signed-in user's `members` directory row in an org."""
        for r in self._mx(
            "SELECT d.payload, s.user_key FROM mx_directory d JOIN mx_sync_state s "
            "ON s.organization_id = d.organization_id WHERE d.organization_id = ? AND d.type = 'members'",
            (org_key,),
        ):
            p = self._payload(r["payload"])
            if (p.get("user") or {}).get("id") == r["user_key"]:
                return p
        return {}

    @staticmethod
    def _mx_from_addresses(me: dict, host: str) -> list[str]:
        """Membership#from_addresses for one domain: username@ it when the member
        sees it, plus their mailboxes and send-as grants there. The server still
        decides (can_send_as?); this is what the desktop offers as From."""
        if not host or not me:
            return []
        user = (me.get("user") or {}).get("username") or ""
        sees = me.get("all_domains") or host in {(d.get("name") or "").lower() for d in me.get("domains") or []}
        out = [f"{user.lower()}@{host}"] if user and sees else []
        out += [a.lower() for a in (me.get("email_addresses") or []) + (me.get("send_as_addresses") or [])
                if a.lower().rsplit("@", 1)[-1] == host]
        return list(dict.fromkeys(out))

    def send_call(self, account_key: str, message: dict) -> tuple[str, dict]:
        """The engine call that sends `message` from `account_key`: the channel
        outbox, or for an inbox2 domain the server (the desktop's Rails path),
        threaded by `conversation_key`."""
        if not any(a["key"] == account_key for a in self.mx_accounts()):
            msg = {k: v for k, v in message.items() if k not in ("conversation_key", "mx_draft")}
            return "send_message", {"account_key": account_key, "message": msg}
        if message.get("attachments"):
            # ponytail: the desktop uploads to orgs/:id/attachments first; add that when the CLI needs it.
            raise ValueError("attachments on inbox2 sends aren't supported in the CLI yet — send it from the desktop")
        body = {k: message.get(k) for k in ("from_address", "to_address", "cc_address", "bcc_address", "subject", "body_plain")}
        body.update(conversation_id=message.get("conversation_key"), content_type="text/plain",
                    reply_to_message_id=message.get("reply_to_message_key"),
                    attachment_keys=message.get("attachment_keys"))
        return "mx_send", {"org": self.mx_org(account_key), "message": {k: v for k, v in body.items() if v}}

    def mx_user_key(self, org: str) -> str:
        rows = self._mx("SELECT user_key FROM mx_sync_state WHERE organization_id = ?", (org,))
        return rows[0]["user_key"] if rows else ""

    def mx_sender_sealed(self, account_key: str, from_address: str | None) -> bool:
        """Whether mail from this address is end-to-end encrypted on its domain."""
        host = parseaddr(from_address or "")[1].rpartition("@")[2].lower()
        return any((d.get("name") or "").lower() == host and d.get("e2ee_enabled")
                   for d in self.mx_directory([account_key], "domains"))

    def mx_org(self, account_key: str) -> str:
        """The org an MX channel (domain) belongs to — what mx_action takes."""
        return next((a["org_key"] for a in self.mx_accounts() if a["key"] == account_key), account_key)

    def mx_directory(self, account_keys: Sequence[str], kind: str) -> list[dict]:
        """The payloads of one directory type (spaces, triage_labels, tags, …)
        for the given orgs, in the server's order."""
        _, mx = self._split(account_keys)
        orgs = sorted({self.mx_org(k) for k in mx})
        if not orgs:
            return []
        placeholders = ",".join("?" for _ in orgs)
        rows = self._mx(
            f"SELECT payload FROM mx_directory WHERE organization_id IN ({placeholders}) AND type = ? "
            "ORDER BY position, key",
            [*orgs, kind],
        )
        return [p for p in (self._payload(r["payload"]) for r in rows) if p]

    def _mx_conversations(self, account_keys: Sequence[str], where: str, params: Sequence, limit: int) -> list[dict]:
        if not account_keys:
            return []
        placeholders = ",".join("?" for _ in account_keys)
        sql = (
            f"SELECT {_MX_CONV_COLS}, payload FROM mx_conversations "
            f"WHERE {_mx_account()} IN ({placeholders}) AND {where} "
            "ORDER BY updated_at DESC, key DESC LIMIT ?"
        )
        out = []
        for r in self._mx(sql, [*account_keys, *params, limit]):
            row = dict(r)
            payload = self._payload(row.pop("payload"))
            row["has_attachment"] = 1 if payload.get("has_attachment") else 0
            row["lore_done"] = bool(payload.get("lore_done"))
            out.append(row)
        return out

    def _mx_messages(self, conversation_key: str) -> list[dict]:
        rows = self._mx(
            "SELECT key, conversation_key, organization_id, is_draft, created_at, payload, plain, "
            f"(SELECT {_mx_account('c')} FROM mx_conversations c WHERE c.key = mx_messages.conversation_key) AS channel "
            "FROM mx_messages WHERE conversation_key = ? ORDER BY created_at ASC, key ASC",
            (conversation_key,),
        )
        out = []
        for r in rows:
            p = self._payload(r["payload"])
            # A sealed message the engine has opened reads from `plain`; one it
            # hasn't is shown as what it is rather than as an empty mail.
            opened = self._payload(r["plain"]) or None
            header, body = (opened or {}).get("header", {}), (opened or {}).get("body", {})
            sealed = p.get("encryption_scheme") not in (None, "none")
            out.append({
                "key": r["key"],
                "conversation_key": r["conversation_key"],
                "from_address": header.get("from") or p.get("from_address"),
                "to_address": header.get("to") or p.get("to_address"),
                "cc_address": header.get("cc") or p.get("cc_address"),
                "bcc_address": p.get("bcc_address"),
                "subject": header.get("subject") or p.get("subject"),
                "body_plain": body.get("plain") or p.get("body_plain")
                or ("[Encrypted — unlock in the desktop app to read]" if sealed and not opened else None),
                "body_html": body.get("html") or p.get("body_html"),
                "is_inbound": 1 if p.get("is_inbound", True) else 0,
                "is_draft": r["is_draft"],
                "message_id_header": p.get("message_id"),
                "account_key": r["channel"] or r["organization_id"],
                "created_at": r["created_at"],
                "sealed": sealed,
                "mx_attachments": [
                    {"attachment_id": a.get("id"), "filename": a.get("filename") or "attachment",
                     "mime_type": a.get("content_type"), "size": a.get("size_bytes") or 0,
                     "download_url": a["download_url"], "sealed": sealed}
                    for a in p.get("attachments") or [] if a.get("download_url")
                ],
            })
        return out

    # ── conversations ──────────────────────────────────────────────────────
    def _conversations_where(
        self, account_keys: Sequence[str], where: str, params: Sequence, unread_only: bool, limit: int, mx_only: str = ""
    ) -> list[dict]:
        """Channel rows + MX rows for one WHERE clause (both tables share the
        list columns), merged newest-first. ``mx_only`` narrows the MX side alone."""
        channel, mx = self._split(account_keys)
        unread = "AND read = 0 " if unread_only else ""
        rows: list[dict] = []
        if channel:
            placeholders = ",".join("?" for _ in channel)
            rows = self._rows(
                f"SELECT {_CONV_COLS} FROM conversations "
                f"WHERE organization_id IN ({placeholders}) AND {where} {unread}"
                "ORDER BY updated_at DESC, id DESC LIMIT ?",
                [*channel, *params, limit],
            )
        return _merge(rows, self._mx_conversations(mx, f"{where} {unread}{mx_only}", params, limit), limit)

    def conversations(
        self,
        account_keys: Sequence[str],
        status: str = STATUS_OPEN,
        unread_only: bool = False,
        limit: int = 500,
    ) -> list[dict]:
        if not account_keys:
            return []
        return self._conversations_where(account_keys, "status = ?", [status], unread_only, limit)

    def conversation(self, account_keys: Sequence[str], key: str) -> dict | None:
        """One conversation's list row by key (channel or MX), or None."""
        rows = self._conversations_where(account_keys, "key = ?", [key], False, 1)
        return rows[0] if rows else None

    def _optional(self, sql: str, params: Sequence = ()) -> list[dict]:
        """Rows from a query on columns/tables a store from an older engine may
        not have yet: those read as none, anything else still raises."""
        try:
            return self._rows(sql, params)
        except sqlite3.OperationalError as e:
            if "no such column" in str(e) or "no such table" in str(e):
                return []
            raise

    def conversation_summary(self, key: str) -> dict:
        """The AI summary + next action the host's triage worker cached on a
        channel conversation (empty for MX threads and untriaged mail)."""
        rows = self._optional(
            "SELECT ai_summary_short, ai_summary_medium, next_action_title, next_action_due_on, "
            "next_action_amount_cents, next_action_currency FROM conversations WHERE key = ?",
            (key,),
        )
        return {k: v for k, v in (rows[0] if rows else {}).items() if v not in (None, "")}

    def lore_items(self, account_keys: Sequence[str], done: bool = False, limit: int = 1000) -> list[dict]:
        """Lore's open workload (lib/lore.js): every thread carrying a Jev label,
        still open (or, with ``done``, recently archived). A Lore item IS a
        thread — ticking it off archives it; on a shared domain a personal bucket
        is hidden for this member instead (``lore_done``, api LoreMemberDone)."""
        status = "archived" if done else STATUS_OPEN
        labeled = "triage_label IS NOT NULL AND triage_label <> 'resolved'"
        # Filtered in SQL: done rows must not use up the limit.
        rows = self._conversations_where(account_keys, f"status = ? AND {labeled}", [status], False, limit,
                                         mx_only="" if done else f"AND {_MX_LORE_DONE} = 0")
        if done:
            _, mx = self._split(account_keys)
            have = {r["key"] for r in rows}
            ticked = self._mx_conversations(mx, f"status = ? AND {_MX_LORE_DONE} = 1 AND {labeled}", [STATUS_OPEN], limit)
            rows = _merge(rows, [r for r in ticked if r["key"] not in have], limit)
        if rows:
            extra = {
                r["key"]: r for r in self._optional(
                    "SELECT key, ai_summary_short, next_action_title, next_action_due_on, "
                    "next_action_amount_cents, next_action_currency FROM conversations "
                    f"WHERE key IN ({','.join('?' for _ in rows)})",
                    [r["key"] for r in rows],
                )
            }
            for r in rows:
                r.update({k: v for k, v in extra.get(r["key"], {}).items() if k != "key"})
        return rows

    def wa_lore(self, done: bool = False, limit: int = 200) -> list[dict]:
        """WhatsApp asks (wa_lore, written by the desktop's WhatsApp Lore worker)
        and tracked business groups' to-dos — none on a store without them."""
        status = "done" if done else "open"
        asks = self._optional(
            "SELECT 'ask' AS wa_kind, chat_id AS id, chat_id, chat_name, coalesce(title, summary, '') AS text, "
            "summary, label, sender, ask_at AS at "
            "FROM wa_lore WHERE status = ? AND coalesce(done_reason, '') <> 'tracked' "
            "AND chat_id NOT IN (SELECT chat_id FROM wa_groups WHERE ignored = 1) ORDER BY ask_at DESC LIMIT ?",
            (status, limit),
        )
        todos = self._optional(
            "SELECT 'todo' AS wa_kind, t.id, t.chat_id, g.chat_name, t.title AS text, t.summary, NULL AS label, "
            "t.owner AS sender, t.at FROM wa_group_todos t "
            "JOIN wa_groups g ON g.chat_id = t.chat_id "
            "WHERE t.status = ? AND g.business = 1 AND g.ignored = 0 ORDER BY t.at DESC LIMIT ?",
            (status, limit),
        )
        return asks + todos

    def conversations_by_space(
        self, account_keys: Sequence[str], slug: str, unread_only: bool = False, limit: int = 500
    ) -> list[dict]:
        """Open conversations Jev (or the user) filed into a Space."""
        if not account_keys:
            return []
        return self._conversations_where(
            account_keys, "status = ? AND space_slug = ?", [STATUS_OPEN, slug], unread_only, limit
        )

    def conversations_by_triage_label(
        self, account_keys: Sequence[str], slug: str, unread_only: bool = False, limit: int = 500
    ) -> list[dict]:
        if not account_keys:
            return []
        return self._conversations_where(
            account_keys, "status = ? AND triage_label = ?", [STATUS_OPEN, slug], unread_only, limit
        )

    def conversations_with_message(
        self,
        account_keys: Sequence[str],
        *,
        draft: bool,
        unread_only: bool = False,
        limit: int = 500,
    ) -> list[dict]:
        """Conversations backing the Sent / Drafts views, derived from synced
        provider folder membership (`message_provider_state.folder_key` →
        `external_folders.well_known_role`) — the same authoritative source the
        desktop uses. Sent = a message filed under the account's `sent` folder;
        Drafts = a message under `drafts`, or a locally-composed draft
        (`is_draft = 1`) not yet synced to a folder. `is_inbound` is deliberately
        not used: the Gmail adapter marks every message inbound, so it can't tell
        sent mail apart. Same column shape as `conversations()`."""
        channel, mx = self._split(account_keys)
        mx_drafts = []
        if draft and mx:
            where = f"key IN (SELECT conversation_key FROM mx_messages WHERE is_draft = 1) {'AND read = 0' if unread_only else ''}"
            mx_drafts = self._mx_conversations(mx, where, [], limit)
        if not channel:
            return mx_drafts
        placeholders = ",".join("?" for _ in channel)
        role = VIEW_DRAFTS if draft else VIEW_SENT
        in_folder = (
            "EXISTS (SELECT 1 FROM messages m "
            "JOIN message_provider_state mps ON mps.message_key = m.key "
            "JOIN external_folders f ON f.key = mps.folder_key "
            "WHERE m.conversation_key = c.key AND f.well_known_role = ?)"
        )
        if draft:
            # Locally-composed drafts may have no provider folder membership yet.
            membership = (
                f"({in_folder} OR EXISTS (SELECT 1 FROM messages md "
                "WHERE md.conversation_key = c.key AND md.is_draft = 1))"
            )
        else:
            membership = in_folder
        sql = (
            f"SELECT {_cols('c')} FROM conversations c "
            f"WHERE c.organization_id IN ({placeholders}) AND {membership} "
        )
        params: list = [*channel, role]
        if unread_only:
            sql += "AND c.read = 0 "
        sql += "ORDER BY c.updated_at DESC, c.id DESC LIMIT ?"
        params.append(limit)
        return _merge(self._rows(sql, params), mx_drafts, limit)

    # ── the inbox rule (one place; the desktop's useUnifiedInbox / useInboxConversations) ──
    def _inbox_where(self, channel: Sequence[str]) -> tuple[str, list]:
        """Local channels: not archived/spam/trash, and a message in the account's
        inbox folder (synced provider membership — not merely status='open', which
        also covers sent-only threads and mail filed only under other folders)."""
        placeholders = ",".join("?" for _ in channel)
        return (
            f"status NOT IN ({_HIDDEN}) AND key IN ("
            "SELECT m.conversation_key FROM message_provider_state mps "
            "JOIN messages m ON m.key = mps.message_key "
            "JOIN external_folders f ON f.key = mps.folder_key "
            f"WHERE mps.account_key IN ({placeholders}) AND f.account_key = mps.account_key "
            f"AND f.well_known_role = '{FOLDER_ROLE_INBOX}')",
            list(channel),
        )

    def in_inbox(self, account_key: str, key: str) -> bool:
        """Whether one thread is in its channel's Inbox (the same rule as `inbox`,
        minus the unified triage exclusion and the row cap)."""
        channel, mx = self._split([account_key])
        if mx:
            return bool(self._mx(f"SELECT 1 FROM mx_conversations WHERE key = ? AND {_MX_INBOX}", (key,)))
        where, params = self._inbox_where(channel)
        return bool(self._rows(f"SELECT 1 FROM conversations WHERE key = ? AND {where}", [key, *params]))

    def inbox(
        self,
        account_keys: Sequence[str],
        unified: bool = False,
        unread_only: bool = False,
        limit: int = 500,
    ) -> list[dict]:
        """The Inbox. Per channel it is every inbox thread; the unified stream
        (`unified`) also leaves out the threads placed in a quadrant, which live
        in the Priority/Delegate/Schedule/Later views (the desktop's matrix)."""
        return self._inbox_rows(account_keys, unified=unified, quadrant=None, unread_only=unread_only, limit=limit)

    def _inbox_rows(self, account_keys, *, unified: bool, quadrant, unread_only: bool, limit: int) -> list[dict]:
        if not account_keys:
            return []
        channel, mx = self._split(account_keys)
        unread = "AND read = 0 " if unread_only else ""
        rows: list[dict] = []
        if channel:
            where, params = self._inbox_where(channel)
            placeholders = ",".join("?" for _ in channel)
            if quadrant is not None:
                where += " AND " + self._local_quadrant(*quadrant)
            elif unified:
                where += f" AND NOT {_LOCAL_TRIAGED}"
            rows = self._rows(
                f"SELECT {_CONV_COLS} FROM conversations "
                f"WHERE organization_id IN ({placeholders}) AND {where} {unread}"
                "ORDER BY updated_at DESC, id DESC LIMIT ?",
                [*channel, *params, limit],
            )
        mx_where = _MX_INBOX
        if quadrant is not None:
            mx_where += " AND " + self._mx_quadrant(*quadrant)
        elif unified:
            mx_where += f" AND NOT {_MX_TRIAGED}"
        mx_rows = self._mx_conversations(mx, f"{mx_where} {unread}", [], limit)
        if quadrant is not None or unified:
            for r in mx_rows:  # the quadrant mark in the list gutter
                r["priority_urgent"], r["priority_important"] = self._mx_flags(r["key"])
        return _merge(rows, mx_rows, limit)

    @staticmethod
    def _local_quadrant(urgent: bool, important: bool) -> str:
        if not urgent and not important:  # Later: no flags, but explicitly placed
            return "priority_urgent = 0 AND priority_important = 0 AND priority_triaged = 1"
        return f"priority_urgent = {int(urgent)} AND priority_important = {int(important)}"

    @staticmethod
    def _mx_quadrant(urgent: bool, important: bool) -> str:
        u, i = _mx_has_tag("", MX_TAG_URGENT), _mx_has_tag("", MX_TAG_IMPORTANT)
        if not urgent and not important:
            return f"NOT {u} AND NOT {i} AND {_mx_has_tag('', MX_TAG_LATER)}"
        return f"{'' if urgent else 'NOT '}{u} AND {'' if important else 'NOT '}{i}"

    def _mx_flags(self, key: str) -> tuple[int, int]:
        r = self._mx(
            f"SELECT {_mx_has_tag('', MX_TAG_URGENT)} AS u, {_mx_has_tag('', MX_TAG_IMPORTANT)} AS i "
            "FROM mx_conversations WHERE key = ?", (key,))
        return (int(r[0]["u"]), int(r[0]["i"])) if r else (0, 0)

    def conversations_by_quadrant(
        self,
        account_keys: Sequence[str],
        urgent: bool,
        important: bool,
        unread_only: bool = False,
        limit: int = 500,
    ) -> list[dict]:
        """Inbox threads placed in one quadrant (the desktop's Eisenhower matrix):
        local by the priority flags (+ Later's marker), MX by its priority tags."""
        return self._inbox_rows(account_keys, unified=False, quadrant=(urgent, important),
                                unread_only=unread_only, limit=limit)

    def conversations_in_label(
        self, account_keys: Sequence[str], label_key: str, unread_only: bool = False, limit: int = 500
    ) -> list[dict]:
        """Conversations carrying a provider label/folder (the desktop's Labels
        sidebar): a message filed in that folder, or a Gmail message whose
        `labels` JSON lists the label's id (`external_folders.flags[0]`)."""
        label = self._label(label_key)
        if not label:
            return []
        sql = (
            f"SELECT DISTINCT {_cols('c')} "
            "FROM conversations c JOIN messages m ON m.conversation_key = c.key "
            "JOIN message_provider_state mps ON mps.message_key = m.key "
            "WHERE c.organization_id = ? AND (mps.folder_key = ? OR mps.labels LIKE ?) "
            "AND c.status NOT IN (?, ?) "
        )
        params: list = [label["account_key"], label_key, f'%"{label["id"]}"%', STATUS_SPAM, STATUS_TRASH]
        if unread_only:
            sql += "AND c.read = 0 "
        sql += "ORDER BY c.updated_at DESC, c.id DESC LIMIT ?"
        params.append(limit)
        return self._rows(sql, params)

    def search(self, account_keys: Sequence[str], query: str, unread_only: bool = False, limit: int = 200) -> list[dict]:
        """Gmail-style search (see `search.py`): free text through FTS5 on both
        the channel and MX mirrors, operators as SQL. A MATCH the engine rejects
        (it shouldn't — terms are re-quoted — but belt and braces) falls back to
        a LIKE over the list columns rather than an empty result."""
        q = searchq.parse(query)
        if q.is_empty or not account_keys:
            return []
        channel, mx = self._split(account_keys)
        unread = "AND c.read = 0 " if unread_only else ""
        rows: list[dict] = []
        cols = _cols("c")
        try:
            if channel:
                where, params = searchq.to_sql(q)
                placeholders = ",".join("?" for _ in channel)
                sql = (
                    f"SELECT DISTINCT {cols} FROM conversations c JOIN messages m ON m.conversation_key = c.key "
                )
                bind: list = []
                if q.text:
                    sql += "JOIN messages_fts f ON f.rowid = m.id "
                sql += f"WHERE c.organization_id IN ({placeholders}) "
                bind += channel
                if q.text:
                    sql += "AND messages_fts MATCH ? "
                    bind.append(searchq.fts_match(q.text))
                for w in where:
                    sql += f"AND {w} "
                bind += params
                sql += unread + "ORDER BY c.updated_at DESC LIMIT ?"
                bind.append(limit)
                rows = self._rows(sql, bind)
            if mx:
                where, params = searchq.to_sql(q, mx=True)
                placeholders = ",".join("?" for _ in mx)
                mx_cols = ", ".join(
                    "0 AS has_attachment" if f == "has_attachment"
                    else "0 AS priority_urgent" if f == "priority_urgent"
                    else "0 AS priority_important" if f == "priority_important"
                    else f"{_mx_account('c')} AS account_key" if f == "organization_id"
                    else f"c.{f}"
                    for f in _CONV_FIELDS
                )
                sql = f"SELECT DISTINCT {mx_cols}, c.payload FROM mx_conversations c "
                bind = []
                if q.text:
                    sql += "JOIN mx_messages m ON m.conversation_key = c.key JOIN mx_messages_fts f ON f.rowid = m.id "
                sql += f"WHERE {_mx_account('c')} IN ({placeholders}) "
                bind += mx
                if q.text:
                    sql += "AND mx_messages_fts MATCH ? "
                    bind.append(searchq.fts_match(q.text))
                for w in where:
                    sql += f"AND {w} "
                bind += params
                sql += unread + "ORDER BY c.updated_at DESC LIMIT ?"
                bind.append(limit)
                mx_rows = []
                for r in self._mx(sql, bind):
                    row = dict(r)
                    row["has_attachment"] = 1 if self._payload(row.pop("payload")).get("has_attachment") else 0
                    mx_rows.append(row)
                rows = _merge(rows, mx_rows, limit)
        except sqlite3.OperationalError:
            like = f"%{(q.text or query).lower()}%"
            rows = self._conversations_where(
                account_keys,
                "(LOWER(subject) LIKE ? OR LOWER(from_address) LIKE ? OR LOWER(snippet) LIKE ?)",
                [like, like, like], unread_only, limit,
            )
        return rows

    def conversation_messages(self, conversation_key: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT key, conversation_key, from_address, to_address, cc_address, subject, "
            "body_plain, body_html, is_inbound, is_draft, message_id_header, account_key, created_at "
            "FROM messages WHERE conversation_key = ? ORDER BY created_at ASC, id ASC",
            (conversation_key,),
        ).fetchall()
        return [dict(r) for r in rows] or self._mx_messages(conversation_key)

    # ── contacts (compose autocomplete; port of hooks/useContactSuggestions.js) ─
    def contacts(self, account_keys: Sequence[str], limit: int = 2000) -> list[str]:
        """Every address seen in from/to on non-discarded conversations, as
        `Name <email>` (or the bare email), most-seen first."""
        channel, mx = self._split(account_keys)
        seen: dict[str, tuple[str, int]] = {}
        sql = "SELECT from_address, to_address FROM {t} WHERE {acct} IN ({p}) AND status NOT IN (?, ?) ORDER BY updated_at DESC LIMIT ?"
        for table, acct, keys in (("conversations", "organization_id", channel), ("mx_conversations", _mx_account(), mx)):
            if not keys:
                continue
            placeholders = ",".join("?" for _ in keys)
            rows = self._mx(sql.format(t=table, acct=acct, p=placeholders), [*keys, STATUS_SPAM, STATUS_TRASH, limit])
            for r in rows:
                for raw in (r["from_address"], r["to_address"]):
                    for name, email in _parse_addresses(raw):
                        e = email.lower()
                        label, n = seen.get(e, (email, 0))
                        if name and (" " in name or label == email):
                            label = f"{name} <{email}>"
                        seen[e] = (label, n + 1)
        return [label for label, _ in sorted(seen.values(), key=lambda v: -v[1])]

    # ── sidebar: counts · labels · spaces · triage labels · outbox ───────────
    def unread_count(self, account_keys: Sequence[str], status: str = STATUS_OPEN) -> int:
        """Unread threads in a folder; for the Inbox, by the inbox rule (`inbox`),
        so the count agrees with the list (the desktop's badge does the same)."""
        if status == STATUS_OPEN:
            return len(self.inbox(account_keys, unread_only=True, limit=100000))
        channel, mx = self._split(account_keys)
        n = 0
        if channel:
            placeholders = ",".join("?" for _ in channel)
            n += self.conn.execute(
                f"SELECT COUNT(*) FROM conversations WHERE organization_id IN ({placeholders}) AND status = ? AND read = 0",
                [*channel, status],
            ).fetchone()[0]
        if mx:
            placeholders = ",".join("?" for _ in mx)
            rows = self._mx(
                f"SELECT COUNT(*) AS n FROM mx_conversations WHERE {_mx_account()} IN ({placeholders}) AND status = ? AND read = 0",
                [*mx, status],
            )
            n += rows[0]["n"] if rows else 0
        return int(n)

    def labels(self, account_keys: Sequence[str]) -> list[dict]:
        """Provider labels/folders without a well-known role — the desktop's
        Labels sidebar (Gmail labels, Outlook folders, IMAP mailboxes), minus
        Gmail's category tabs and the inbox2/<quadrant> triage labels."""
        channel, _ = self._split(account_keys)
        if not channel:
            return []
        placeholders = ",".join("?" for _ in channel)
        out = []
        for r in self._rows(
            "SELECT key, account_key, provider_name, flags FROM external_folders "
            f"WHERE account_key IN ({placeholders}) AND well_known_role IS NULL ORDER BY provider_name",
            channel,
        ):
            name = r["provider_name"] or ""
            if name.startswith(_HIDDEN_LABEL_PREFIXES):
                continue
            out.append({"key": r["key"], "account_key": r["account_key"], "name": name, "id": self._first_flag(r["flags"], name)})
        return out

    @staticmethod
    def _first_flag(flags: str | None, default: str) -> str:
        """`external_folders.flags` is a JSON list whose first entry is the
        provider's id for the label (Gmail label id / Graph folder id)."""
        try:
            value = json.loads(flags) if flags else []
        except ValueError:
            value = []
        return value[0] if isinstance(value, list) and value and isinstance(value[0], str) else default

    def _label(self, label_key: str) -> dict | None:
        row = self.conn.execute(
            "SELECT key, account_key, provider_name, flags FROM external_folders WHERE key = ?", (label_key,)
        ).fetchone()
        if not row:
            return None
        return {"key": row["key"], "account_key": row["account_key"], "name": row["provider_name"],
                "id": self._first_flag(row["flags"], row["provider_name"] or "")}

    def folders(self, account_key: str) -> list[dict]:
        """Every folder/label of one account, roles first — the move-to-folder
        picker (the engine's move_conversations resolves key / role / name)."""
        return self._rows(
            "SELECT key, account_key, provider_name AS name, well_known_role AS role FROM external_folders "
            "WHERE account_key = ? ORDER BY well_known_role IS NULL, well_known_role, provider_name",
            (account_key,),
        )

    def spaces(self, account_keys: Sequence[str]) -> list[dict]:
        """The Spaces threads can be filed into: the org taxonomy pushed to this
        device + the user's personal Spaces (engine_settings) for channel
        accounts, the org's own Spaces (mx_directory) for MX orgs; deduped by
        slug, the Jev holding pen last."""
        channel, _ = self._split(account_keys)
        seen: dict[str, str] = {}
        if channel:
            for key in ("space_taxonomy", "personal_spaces"):
                for s in self.engine_setting(key) or []:
                    if isinstance(s, dict) and s.get("slug"):
                        seen.setdefault(s["slug"], s.get("name") or s["slug"])
        for s in self.mx_directory(account_keys, "spaces"):
            if s.get("slug"):
                seen.setdefault(s["slug"], s.get("name") or s["slug"])
        seen.pop(SPACE_TRIAGE[0], None)
        out = [{"slug": k, "name": v} for k, v in seen.items()]
        out.append({"slug": SPACE_TRIAGE[0], "name": SPACE_TRIAGE[1]})
        return out

    def triage_labels(self, account_keys: Sequence[str]) -> list[dict]:
        """Enabled triage labels: the built-ins, overridden/extended by the
        user's list (engine_settings.triage_labels) and the org's (mx_directory)."""
        labels = dict(TRIAGE_LABELS)
        for src in (self.engine_setting("triage_labels") or [], self.mx_directory(account_keys, "triage_labels")):
            for l in src:
                if isinstance(l, dict) and l.get("slug") and l.get("enabled", True):
                    labels[l["slug"]] = l.get("name") or l["slug"]
        return [{"slug": k, "name": v} for k, v in labels.items()]

    def outbox(self, account_keys: Sequence[str]) -> list[dict]:
        """Queued/failed sends and draft saves: channel accounts' `outbox_messages`
        plus the engine's `mx_outbox`. Delivered MX rows linger briefly for their
        caller, so they're left out."""
        channel, mx = self._split(account_keys)
        mx_rows = self._mx_outbox(mx)
        if not channel:
            return mx_rows
        placeholders = ",".join("?" for _ in channel)
        try:
            rows = self._rows(
                "SELECT key, account_key, kind, status, error_message, retry_count, created_at, payload "
                f"FROM outbox_messages WHERE account_key IN ({placeholders}) ORDER BY created_at DESC LIMIT 200",
                channel,
            )
        except sqlite3.OperationalError:
            return mx_rows
        out = []
        for r in rows:
            p = self._payload(r.pop("payload"))
            r["subject"] = p.get("subject") or "(no subject)"
            r["to_address"] = p.get("to_address") or ""
            out.append(r)
        return sorted([*out, *mx_rows], key=lambda r: r["created_at"], reverse=True)

    def _mx_outbox(self, mx: Sequence[str]) -> list[dict]:
        # ponytail: a row is per org, so it shows on each of that org's domain tabs.
        account_for_org = {self.mx_org(k): k for k in reversed(mx)}
        if not account_for_org:
            return []
        placeholders = ",".join("?" for _ in account_for_org)
        out = []
        for r in self._mx(
            "SELECT key, org_id, kind, status, error_message, retry_count, created_at, payload "
            f"FROM mx_outbox WHERE org_id IN ({placeholders}) AND status != '{OUTBOX_SENT}' ORDER BY created_at DESC LIMIT 200",
            tuple(account_for_org),
        ):
            row = dict(r)
            p = self._payload(row.pop("payload"))
            row.update(account_key=account_for_org[row.pop("org_id")], subject=p.get("subject") or "(no subject)",
                       to_address=p.get("to_address") or "")
            out.append(row)
        return out

    def outbox_counts(self, account_keys: Sequence[str]) -> tuple[int, int]:
        """(pending, failed) — the sidebar badge."""
        rows = self.outbox(account_keys)
        pending = sum(1 for r in rows if r["status"] in ("pending", "sending"))
        failed = sum(1 for r in rows if r["status"] == "failed")
        return pending, failed

    # ── optimistic local mutations (provider write-back goes via the bus) ────
    def set_conversation_status(self, conversation_key: str, status: str) -> None:
        self.conn.execute(
            "UPDATE conversations SET status = ? WHERE key = ?",
            (status, conversation_key),
        )
        # An MX thread: the same optimistic column write (the engine's mx_action then
        # does it properly, payload included — see App.dispatch_action).
        self._mx_write("UPDATE mx_conversations SET status = ? WHERE key = ?", (status, conversation_key))
        self.conn.commit()

    def set_conversation_read(self, conversation_key: str, read: bool) -> None:
        self.conn.execute(
            "UPDATE conversations SET read = ? WHERE key = ?",
            (1 if read else 0, conversation_key),
        )
        self._mx_write("UPDATE mx_conversations SET read = ? WHERE key = ?", (1 if read else 0, conversation_key))
        self.conn.commit()

    def set_conversation_priority(self, conversation_key: str, urgent: bool, important: bool) -> None:
        self.conn.execute(
            "UPDATE conversations SET priority_urgent = ?, priority_important = ? WHERE key = ?",
            (1 if urgent else 0, 1 if important else 0, conversation_key),
        )
        self.conn.commit()

    def set_mx_lore_done(self, conversation_key: str, done: bool) -> None:
        """The optimistic half of a member's Lore tick; the engine's action queue
        writes the same field and sends it (docs/MX-Sync.md)."""
        self._mx_write(
            "UPDATE mx_conversations SET payload = json_set(payload, '$.lore_done', json(?)) WHERE key = ?",
            ("true" if done else "false", conversation_key),
        )
        self.conn.commit()

    def apply_action_locally(self, conversation_key: str, action: str) -> None:
        """Optimistically reflect an action's read/status effect locally. Single
        source for both the action path and undo/redo."""
        from .constants import ACTION_LORE_DONE, ACTION_LORE_UNDONE, ACTION_MARK_READ, ACTION_MARK_UNREAD, ACTION_TO_STATUS

        if action in (ACTION_MARK_READ, ACTION_MARK_UNREAD):
            self.set_conversation_read(conversation_key, action == ACTION_MARK_READ)
        elif action in ACTION_TO_STATUS:
            self.set_conversation_status(conversation_key, ACTION_TO_STATUS[action])
        elif action in (ACTION_LORE_DONE, ACTION_LORE_UNDONE):
            self.set_mx_lore_done(conversation_key, action == ACTION_LORE_DONE)

    # ── calendar ─────────────────────────────────────────────────────────────
    def calendars(self, account_keys: Sequence[str]) -> list[dict]:
        if not account_keys:
            return []
        placeholders = ",".join("?" for _ in account_keys)
        rows = self.conn.execute(
            "SELECT key, account_key, name, color, provider_id, is_primary, "
            "IFNULL(is_writable, 1) AS is_writable, IFNULL(is_owned, 1) AS is_owned "
            f"FROM calendars WHERE account_key IN ({placeholders}) ORDER BY is_primary DESC, name",
            list(account_keys),
        ).fetchall()
        return [dict(r) for r in rows]

    def events(
        self,
        account_keys: Sequence[str],
        start_iso: str,
        end_iso: str,
    ) -> list[dict]:
        """Events overlapping [start_iso, end_iso). Joins the calendar to expose
        its provider_id (needed by the calendar write RPCs)."""
        if not account_keys:
            return []
        placeholders = ",".join("?" for _ in account_keys)
        rows = self.conn.execute(
            "SELECT e.key, e.calendar_key, e.account_key, e.provider_id, "
            "c.provider_id AS calendar_provider_id, c.name AS calendar_name, c.color, "
            "e.title, e.description, e.location, e.start_at, e.end_at, e.all_day, "
            "e.status, e.organizer_email "
            "FROM calendar_events e JOIN calendars c ON e.calendar_key = c.key "
            f"WHERE e.account_key IN ({placeholders}) "
            "AND e.start_at < ? AND e.end_at > ? "
            "ORDER BY e.start_at ASC",
            [*account_keys, end_iso, start_iso],
        ).fetchall()
        return [dict(r) for r in rows]

    def event(self, event_key: str) -> dict | None:
        row = self.conn.execute(
            "SELECT e.key, e.calendar_key, e.account_key, e.provider_id, "
            "c.provider_id AS calendar_provider_id, c.name AS calendar_name, e.title, e.description, "
            "e.location, e.start_at, e.end_at, e.all_day, e.status, e.organizer_email, e.organizer_name "
            "FROM calendar_events e JOIN calendars c ON e.calendar_key = c.key "
            "WHERE e.key = ?",
            (event_key,),
        ).fetchone()
        return dict(row) if row else None

    def attendees(self, event_key: str) -> list[dict]:
        """Attendees + their RSVP: the `calendar_attendees` rows, else the
        provider payload's attendee list kept in `calendar_events.metadata`."""
        try:
            rows = self._rows(
                "SELECT email, name, response_status, is_organizer FROM calendar_attendees "
                "WHERE event_key = ? ORDER BY is_organizer DESC, email",
                (event_key,),
            )
        except sqlite3.OperationalError:
            rows = []
        if rows:
            return rows
        try:
            raw = self.conn.execute("SELECT metadata FROM calendar_events WHERE key = ?", (event_key,)).fetchone()
        except sqlite3.OperationalError:
            return []
        meta = self._payload(raw[0] if raw else None)
        return [
            {
                "email": a.get("email") or "",
                "name": a.get("name"),
                "response_status": a.get("responseStatus") or a.get("response_status") or "needs_action",
                "is_organizer": 1 if a.get("organizer") or a.get("is_organizer") else 0,
            }
            for a in meta.get("attendees") or []
            if isinstance(a, dict)
        ]

    def event_conference_url(self, event_key: str) -> str | None:
        try:
            raw = self.conn.execute("SELECT metadata FROM calendar_events WHERE key = ?", (event_key,)).fetchone()
        except sqlite3.OperationalError:
            return None
        conf = self._payload(raw[0] if raw else None).get("conference")
        if isinstance(conf, str):
            return conf
        if isinstance(conf, dict):
            return conf.get("url") or conf.get("join_url") or conf.get("joinUrl")
        return None

    def primary_calendar(self, account_key: str) -> dict | None:
        """The calendar a new event should be created on.

        Writable and ours: a subscribed/holiday/birthday calendar is a perfectly
        normal row here and sorts ahead of a writable secondary one, but the
        provider 403s every create against it — and a calendar someone else
        shared with write access is not where your own events belong.
        """
        cals = self.writable_calendars(account_key)
        if not cals:
            return None
        for c in cals:
            if c.get("is_primary"):
                return c
        return cals[0]

    def writable_calendars(self, account_key: str) -> list[dict]:
        return [c for c in self.calendars([account_key]) if c.get("is_writable") and c.get("is_owned")]

"""Inbox2 — terminal client (Textual) over the shared Rust engine bus.

Mirrors the Tauri desktop app: unified inbox (list view), per-channel browsing,
and calendar, all keyboard-driven and text-only. Reads conversations/calendar
straight from the shared SQLite DB; mutations/fetch/send/calendar-writes go
through the engine bus (the desktop app or a spawned `engine_daemon`).
"""

from __future__ import annotations

import asyncio
import tempfile
from dataclasses import dataclass
from email.utils import getaddresses
from pathlib import Path
from typing import Callable, Optional

from textual.app import App
from textual.binding import Binding
from textual.message import Message

from . import mxfiles, os_notify, prefs, runtime
from .bus import AsyncSocketBus, BusError, NullBus
from .constants import (
    MX_OUTBOX_PREFIX,
    OUTBOX_FAILED,
    OUTBOX_SENT,
    CAL_VIEWS,
    INVERSE_ACTION,
    MX_ACTION,
    PROVIDER_INBOX2,
    QUADRANTS,
    SECTION_CALENDAR,
    SECTION_LABELS,
    SECTION_LORE,
    SECTION_MAIL,
    SECTION_ORDER,
    SECTION_RULES,
    SECTION_WHATSAPP,
    VIEW_OUTBOX,
)
from .db import Database
from .modals import (
    DETAIL_DELETE,
    DETAIL_EDIT,
    ActionsMenuModal,
    AttachmentsModal,
    CommandPaletteModal,
    ComposeModal,
    EventDetailModal,
    EventEditorModal,
    InviteModal,
    PickerModal,
    SettingsModal,
    ShortcutsModal,
    SourceModal,
)
from .screens import CalendarScreen, LoginScreen, MailScreen, _display_name

# Engine event names (core/src/sync/engine/mod.rs `event`) — the wire contract.
EVENT_SYNC = "sync"
EVENT_NEW_MESSAGE = "new-message"
EVENT_CALENDAR_CHANGED = "calendar-changed"
EVENT_STATUS = "status"
EVENT_OUTBOX_CHANGED = "outbox-changed"
EVENT_TRIAGE_UPDATED = "triage-updated"
EVENT_SPACE_UPDATED = "space-updated"
# `sync` phases that end a run (SyncPhase::as_str).
_SYNC_END_PHASES = ("completed", "failed")


@dataclass
class UndoRecord:
    account_key: str
    conversation_key: str
    action: str


class BusEvent(Message):
    """A refresh event broadcast by the engine host."""

    def __init__(self, event: str, payload: dict) -> None:
        super().__init__()
        self.event = event
        self.payload = payload


class Inbox2App(App):
    TITLE = "Inbox2"
    SUB_TITLE = "terminal"

    CSS = """
    Screen { background: $background; }
    """

    BINDINGS = [
        # Channels via function keys (F1 = unified, F2..F9 = account N).
        Binding("f1", "channel(-1)", "Unified", show=False),
        Binding("f2", "channel(0)", "Ch 1", show=False),
        Binding("f3", "channel(1)", "Ch 2", show=False),
        Binding("f4", "channel(2)", "Ch 3", show=False),
        Binding("f5", "channel(3)", "Ch 4", show=False),
        Binding("f6", "channel(4)", "Ch 5", show=False),
        Binding("f7", "channel(5)", "Ch 6", show=False),
        Binding("f8", "channel(6)", "Ch 7", show=False),
        Binding("f9", "channel(7)", "Ch 8", show=False),
        # Sections.
        Binding("ctrl+right", "section(1)", "Next section"),
        Binding("ctrl+left", "section(-1)", "Prev section", show=False),
        # `g` + letter jumps straight to a section (vim/Gmail-style go-to).
        Binding("g", "goto_prefix", "Go to…", show=False),
        # Global.
        Binding("c", "compose", "Compose"),
        Binding("s", "sync", "Sync", show=False),
        Binding("comma", "settings", "Settings", show=False),
        Binding("ctrl+k", "palette", "Palette"),
        Binding("question_mark", "shortcuts", "Help"),
        Binding("ctrl+z", "undo", "Undo", show=False),
        Binding("ctrl+y,ctrl+shift+z", "redo", "Redo", show=False),
        Binding("q", "quit", "Quit"),
        Binding("ctrl+q", "quit", "Quit", show=False),
    ]

    def __init__(
        self,
        db: Optional[Database] = None,
        bus=None,
        accounts: Optional[list[dict]] = None,
        child=None,
        db_file: Optional[Path] = None,
    ):
        super().__init__()
        self.db = db
        self.db_file = db_file
        self.bus = bus if bus is not None else NullBus()
        # Let the bus deliver events back into the app loop.
        if hasattr(self.bus, "on_event"):
            self.bus.on_event = self._relay_bus_event
        if accounts is not None:
            self.accounts = accounts
        elif self.db is not None:
            self.accounts = self.db.list_accounts()
        else:
            self.accounts = []
        self.active_channel: Optional[int] = None  # None = unified
        self.unread_only = False
        self.section = SECTION_MAIL
        self._child = child
        self.undo_stack: list[UndoRecord] = []
        self.redo_stack: list[UndoRecord] = []
        self._last_data_version = -1
        self._syncing: set[str] = set()
        self._mail = MailScreen()
        self._cal = CalendarScreen()
        self._sections: dict = {SECTION_MAIL: self._mail, SECTION_CALENDAR: self._cal}

    # ── lifecycle ────────────────────────────────────────────────────────
    def on_mount(self) -> None:
        theme = prefs.theme()
        self.theme = theme if theme in self.available_themes else "catppuccin-mocha"
        if self.accounts:
            self.push_screen(self._mail)
        else:
            self.push_screen(LoginScreen())

    def set_theme(self, name: str) -> None:
        if name in self.available_themes:
            self.theme = name
            prefs.set("theme", name)
            # Hand-built Rich text (brand, sidebar, list rows) carries the
            # palette it was drawn with — redraw it for the new one.
            self.call_after_refresh(self._mail.refresh_palette)

    def account_count(self) -> int:
        """How many accounts are connected right now — re-read from disk so the
        welcome screen's recheck sees accounts added in the desktop app."""
        if self.db is not None:
            try:
                return len(self.db.list_accounts())
            except Exception:
                return 0
        if self.db_file and Path(self.db_file).exists():
            import sqlite3

            try:
                conn = sqlite3.connect(str(self.db_file))
                n = conn.execute("SELECT COUNT(*) FROM external_accounts").fetchone()[0]
                conn.close()
                return int(n)
            except Exception:
                return 0
        return 0

    async def on_unmount(self) -> None:
        try:
            await self.bus.close()
        except Exception:
            pass
        if self._child is not None and self._child.poll() is None:
            self._child.terminate()

    # ── bus events → diffed refresh ─────────────────────────────────────────
    def _relay_bus_event(self, event: str, payload: dict) -> None:
        # Called from the bus reader task (same loop); hop through the message
        # pump so widget mutations happen on the app's turn. (Name must not be
        # `_on_bus_event` — that collides with Textual's private handler slot for
        # the BusEvent message.)
        self.post_message(BusEvent(event, payload))

    def on_bus_event(self, message: BusEvent) -> None:
        event, payload = message.event, message.payload or {}
        mail = self._mail if isinstance(self.screen, MailScreen) else None

        if event == EVENT_SYNC:
            # Syncing indicator: a run starts on `started`, ends on completed/failed.
            key = payload.get("accountKey") or payload.get("account_key") or ""
            phase = payload.get("phase") or ""
            if phase == "started":
                self._syncing.add(key)
            elif phase in _SYNC_END_PHASES:
                self._syncing.discard(key)
                if phase == "failed" and payload.get("error"):
                    self.notify(f"Sync failed: {payload['error']}", severity="error")
            if mail:
                mail.set_syncing(bool(self._syncing))
        elif event == EVENT_STATUS:
            key = payload.get("accountKey")
            for a in self.accounts:
                if a["key"] == key:
                    a["status"] = payload.get("status") or a.get("status")
                    if payload.get("error"):
                        self.notify(f"{a.get('email_address') or key}: {payload['error']}", severity="warning")
            if mail:
                mail.update_channelbar()
        elif event == EVENT_NEW_MESSAGE and prefs.notifications():
            sender = _display_name(payload.get("from_address")) or payload.get("from_address") or "New mail"
            self.notify(f"✉ {sender}: {payload.get('subject') or '(no subject)'}", title="New mail", timeout=6)
            # Attached to another host means the desktop app is up and alerting already.
            if self._child is not None:
                os_notify.send(sender, payload.get("subject") or "(no subject)")

        # The engine broadcasts a folder-complete on every poll tick; skip work
        # when the DB is unchanged since our last refresh (cheap PRAGMA counter),
        # and only refresh the relevant screen.
        version = self.db.data_version()
        if version == self._last_data_version:
            return
        self._last_data_version = version
        if event == EVENT_CALENDAR_CHANGED:
            if isinstance(self.screen, CalendarScreen):
                self.screen.refresh_events()
        elif hasattr(self.screen, "refresh_data"):
            self.screen.refresh_data()
        elif mail:
            if event in (EVENT_NEW_MESSAGE, EVENT_OUTBOX_CHANGED, EVENT_STATUS) or event == EVENT_SYNC and payload.get("phase") in _SYNC_END_PHASES:
                mail.rebuild_sidebar()
            mail.refresh_conversations()

    def refresh_active(self, force: bool = False) -> None:
        screen = self.screen
        if isinstance(screen, MailScreen):
            screen.refresh_conversations(force=force)
        elif isinstance(screen, CalendarScreen):
            screen.refresh_events()
        elif hasattr(screen, "refresh_data"):
            screen.refresh_data()

    # ── channels & sections ──────────────────────────────────────────────
    def action_channel(self, index: int) -> None:
        # -1 = unified; otherwise account N (0-based).
        self.active_channel = None if index < 0 else index
        if self.section != SECTION_MAIL:
            self.goto_section(SECTION_MAIL)
        self._mail.selected_keys.clear()
        self._mail.update_channelbar()
        self._mail.rebuild_sidebar()
        self._mail.refresh_conversations(force=True)

    def section_screen(self, section: str):
        """The (lazily built) screen for a section."""
        screen = self._sections.get(section)
        if screen is None:
            if section == SECTION_LORE:
                from .lore import LoreScreen as cls
            elif section == SECTION_RULES:
                from .rules import RulesScreen as cls
            else:
                from .whatsapp import WhatsAppScreen as cls
            screen = self._sections[section] = cls()
        return screen

    def goto_section(self, section: str) -> None:
        if section not in SECTION_ORDER:
            return
        self.section = section
        if section == SECTION_CALENDAR:
            self._cal._last_sig = None
        screen = self.section_screen(section)
        if self.screen is not screen:
            self.switch_screen(screen)
        elif hasattr(screen, "refresh_data"):
            screen.refresh_data()

    def action_section(self, direction: int) -> None:
        idx = (SECTION_ORDER.index(self.section) + direction) % len(SECTION_ORDER)
        self.goto_section(SECTION_ORDER[idx])

    _GOTO_KEYS = {"m": SECTION_MAIL, "c": SECTION_CALENDAR, "l": SECTION_LORE, "r": SECTION_RULES, "w": SECTION_WHATSAPP}

    def action_goto_prefix(self) -> None:
        # The next key is taken in on_event, before any screen or modal sees it —
        # no modal to mount first, so a fast `g m` can't leak `m` to the screen.
        self._goto_pending = True
        self.notify("Go to: m Mail · c Calendar · l Lore · r Rules · w WhatsApp", timeout=2)

    async def on_event(self, event) -> None:
        from textual import events

        if isinstance(event, events.Key) and getattr(self, "_goto_pending", False) and event.key != "g":
            self._goto_pending = False
            target = self._GOTO_KEYS.get(event.key)
            if target:
                event.stop()
                event.prevent_default()
                self.clear_notifications()
                self.goto_section(target)
                return
        await super().on_event(event)

    def section_tabs(self) -> "Text":
        """`Mail · Calendar · Lore · …` with the active section highlighted (screen headers)."""
        from rich.text import Text

        t = Text()
        for i, sec in enumerate(SECTION_ORDER):
            if i:
                t.append(" · ", style="dim")
            t.append(SECTION_LABELS[sec], style="bold reverse" if sec == self.section else "dim")
        return t

    # ── compose / send / drafts ─────────────────────────────────────────────
    def signature_block(self) -> str:
        """The user's signature as the RFC 3676 `-- ` block that goes above any
        quoted text, or '' when none is set."""
        sig = prefs.signature()
        return f"\n\n-- \n{sig}\n" if sig else ""

    def action_compose(self) -> None:
        account_key = self._default_account_key("from")
        draft = {
            "account_key": account_key,
            "from_address": self._self_address(account_key),
            "to": "",
            "subject": "",
            "body": self.signature_block().lstrip("\n"),
            "focus": "to",
        }
        self.open_compose(draft, "New message")

    def open_compose(self, draft: dict, title: str) -> None:
        def _result(message: Optional[dict]) -> None:
            if not message:
                return
            if message.pop("intent", "send") == "draft":
                self.save_draft(message)
            else:
                self.send_message(message)

        keys = [a["key"] for a in self.accounts]
        self.push_screen(ComposeModal(draft, title, accounts=self.accounts, contacts=self.db.contacts(keys)), _result)

    def send_message(self, message: dict) -> None:
        account_key = message.pop("account_key", None) or self._default_account_key("from")
        prefs.set_last_account("from", account_key)
        if self.is_mx(account_key) and (message.get("attachments") or message.get("mx_draft")):
            self.run_worker(self._send_mx_files(account_key, message), name="send")
            return
        message.pop("draft_key", None)
        try:
            method, params = self.db.send_call(account_key, message)
        except ValueError as e:
            self.notify(str(e), severity="error")
            return
        self.run_worker(self._mx_send_call(params) if method == "mx_send" else self._rpc(method, params, ok="Sent"),
                        name="send")

    def save_draft(self, message: dict) -> None:
        account_key = message.pop("account_key", None) or self._default_account_key("from")
        if self.is_mx(account_key):
            self.run_worker(self._save_mx_draft(account_key, message), name="draft")
            return
        message.pop("mx_draft", None)
        draft_key = message.pop("draft_key", None) or ""
        self.run_worker(
            self._rpc("save_draft", {"account_key": account_key, "draft_key": draft_key, "message": message},
                      ok="Draft saved"),
            name="draft",
        )

    # ── inbox2-hosted files and drafts (mxfiles.py) ───────────────────────
    async def _mx_token(self) -> Optional[str]:
        try:
            token = await self.bus.call("get_rails_token", {})
        except Exception:  # noqa: BLE001
            token = None
        if not token:
            self.notify("Sign in to inbox2 in the desktop app first.", severity="warning")
        return token

    def _refuse_mx_sealed(self, account_key: str, message: dict) -> bool:
        # ponytail: sealed attachments and drafts need client-side crypto the CLI doesn't have.
        if not self.db.mx_sender_sealed(account_key, message.get("from_address")):
            return False
        self.notify("Files and drafts on encrypted domains stay in the desktop app.", severity="warning")
        return True

    async def _mx_send_call(self, params: dict) -> Optional[str]:
        """Hand a send to the engine's durable outbox. Returns its status, or None
        if it failed for good."""
        try:
            result = await self.bus.call("mx_send", params)
        except Exception as e:  # noqa: BLE001
            self.notify(f"Not sent: {e}", severity="error")
            return None
        status = (result or {}).get("status") or OUTBOX_SENT  # an older host just answers with the message
        if status == OUTBOX_FAILED:
            self.notify(f"Not sent: {result.get('error_message')}", severity="error")
            return None
        self.notify("Sent" if status == OUTBOX_SENT else "Queued in the Outbox; it will send when the server is reachable.")
        return status

    async def _mx_refresh(self, org: str) -> None:
        try:
            await self.bus.call("mx_sync", {"org": org, "user_key": self.db.mx_user_key(org)})
        except Exception:  # noqa: BLE001 — the next sync catches up
            pass

    async def _save_mx_draft(self, account_key: str, message: dict) -> None:
        if self._refuse_mx_sealed(account_key, message):
            return
        token = await self._mx_token()
        if not token:
            return
        org = self.db.mx_org(account_key)
        try:
            await asyncio.to_thread(mxfiles.save_draft, org, message, token)
        except Exception as e:  # noqa: BLE001
            self.notify(f"Draft not saved: {e}", severity="error")
            return
        self.notify("Draft saved")
        await self._mx_refresh(org)

    async def _send_mx_files(self, account_key: str, message: dict) -> None:
        if self._refuse_mx_sealed(account_key, message):
            return
        token = await self._mx_token()
        if not token:
            return
        org = self.db.mx_org(account_key)
        try:
            draft_id, keys = await asyncio.to_thread(mxfiles.save_draft, org, message, token)
        except Exception as e:  # noqa: BLE001
            self.notify(f"Not sent, the attachments didn't upload: {e}", severity="error")
            return
        try:
            _, params = self.db.send_call(account_key, {**message, "attachments": None, "attachment_keys": keys})
        except ValueError as e:
            self.notify(f"Not sent, kept in Drafts: {e}", severity="error")
            return
        # ponytail: a queued send keeps its draft, since deleting it before delivery
        # would take the files; the leftover draft is the user's to delete.
        if await self._mx_send_call(params) != OUTBOX_SENT:
            return
        try:
            # After the send: it has moved the attachments onto the sent message.
            await asyncio.to_thread(mxfiles.delete_draft, org, draft_id, token)
        except Exception:  # noqa: BLE001 — a leftover draft, not a failed send
            self.notify("Sent, but the draft is still in Drafts.", severity="warning")
        await self._mx_refresh(org)

    def reopen_mx_draft(self, conv: dict) -> bool:
        """Open an inbox2 thread's draft in the composer. False leaves the row to
        the normal preview (channel drafts have no engine call to replace them on send)."""
        account_key = conv.get("account_key")
        if not account_key or not self.is_mx(account_key):
            return False
        msg = next((m for m in reversed(self.db.conversation_messages(conv["key"])) if m["is_draft"]), None)
        if not msg:
            return False
        if msg["sealed"]:
            self.notify("Files and drafts on encrypted domains stay in the desktop app.", severity="warning")
            return True
        attached = [{"key": a["attachment_id"], "filename": a["filename"]} for a in msg["mx_attachments"]]
        draft = {
            "account_key": account_key, "from_address": msg["from_address"], "to": msg["to_address"] or "",
            "cc": msg["cc_address"] or "", "bcc": msg["bcc_address"] or "", "subject": msg["subject"] or "",
            "body": msg["body_plain"] or "", "conversation_key": conv["key"], "draft_key": msg["key"],
            "mx_draft": {"id": msg["key"], "attachment_keys": [a["key"] for a in attached], "attachments": attached},
        }
        self.open_compose(draft, "Edit draft")
        return True

    # ── conversation actions ─────────────────────────────────────────────
    def is_mx(self, account_key: str) -> bool:
        return any(a["key"] == account_key and a.get("provider_type") == PROVIDER_INBOX2 for a in self.accounts)

    def dispatch_action(self, account_key: str, conversation_keys: list[str], action: str) -> None:
        # A mirrored inbox2 org: the engine's MX queue applies it to the mirror, keeps
        # it durable and sends it (docs/MX-Sync.md) — not the channel write-back.
        if self.is_mx(account_key):
            self.run_worker(
                self._rpc("mx_action", {"org": self.db.mx_org(account_key), "threads": conversation_keys,
                                        "action": MX_ACTION.get(action, action)}),
                name="action",
            )
            return
        self.run_worker(
            self._rpc(
                "perform_conversation_action",
                {"account_key": account_key, "conversation_keys": conversation_keys, "action": action},
            ),
            name="action",
        )

    def move_to_folder(self, account_key: str, conversation_keys: list[str], folder: str) -> None:
        """Move to a folder by key / well-known role / name. MX threads have no
        provider folders: a role maps onto its status verb, anything else is
        refused rather than silently archived."""
        if self.is_mx(account_key):
            verb = {"inbox": "open", "archive": "archive", "trash": "trash", "spam": "spam"}.get(folder)
            if not verb:
                self.notify("inbox2 mail has no folders — use Archive / Spam / Trash.", severity="warning")
                return
            self.run_worker(self._rpc("mx_action", {"org": self.db.mx_org(account_key), "threads": conversation_keys, "action": verb},
                                      ok="Moved"), name="action")
            return
        for key in conversation_keys:
            # Optimistic: a move takes the thread out of the inbox (the engine does
            # the same locally; back to inbox is `unarchive`).
            self.db.apply_action_locally(key, "unarchive" if folder == "inbox" else "archive")
        self.run_worker(
            self._rpc("move_conversations", {"account_key": account_key, "conversation_keys": conversation_keys,
                                             "folder": folder}, ok="Moved"),
            name="action",
        )

    def open_folder_picker(self, account_key: str, done: Callable[[Optional[str]], None]) -> None:
        if self.is_mx(account_key):
            items = [("inbox", "Inbox"), ("archive", "Archived"), ("spam", "Spam"), ("trash", "Trash")]
        else:
            items = [(f["key"], f"{f['name']}" + (f"  ({f['role']})" if f.get("role") else ""))
                     for f in self.db.folders(account_key)]
        if not items:
            self.notify("No folders synced for this account yet.")
            return
        self.push_screen(PickerModal("Move to folder", items), done)

    def push_undo(self, account_key: str, conversation_key: str, action: str, quiet: bool = False) -> None:
        if action in INVERSE_ACTION:
            self.undo_stack.append(UndoRecord(account_key, conversation_key, action))
            self.redo_stack.clear()
            if not quiet:
                self.notify(f"{action.replace('_', ' ')} — ctrl+z to undo", timeout=7)

    def action_undo(self) -> None:
        if not self.undo_stack:
            return
        rec = self.undo_stack.pop()
        inverse = INVERSE_ACTION.get(rec.action)
        if not inverse:
            return
        self.db.apply_action_locally(rec.conversation_key, inverse)
        self.dispatch_action(rec.account_key, [rec.conversation_key], inverse)
        self.redo_stack.append(rec)
        self.refresh_active(force=True)

    def action_redo(self) -> None:
        if not self.redo_stack:
            return
        rec = self.redo_stack.pop()
        self.db.apply_action_locally(rec.conversation_key, rec.action)
        self.dispatch_action(rec.account_key, [rec.conversation_key], rec.action)
        self.undo_stack.append(rec)
        self.refresh_active(force=True)

    # ── attachments ──────────────────────────────────────────────────────────
    def open_attachments(self, attachments: list[dict]) -> None:
        def _result(att: Optional[dict]) -> None:
            if att:
                self.save_attachment(att)

        self.push_screen(AttachmentsModal(attachments), _result)

    def save_attachment(self, att: dict) -> None:
        self.run_worker(self._save_attachment(att), name="download")

    async def _save_attachment(self, att: dict) -> None:
        """Have the host download the attachment to its cache, then copy it into
        the user's Downloads dir (host + CLI share the machine, so the path the
        host returns is directly readable here)."""
        import shutil

        if att.get("download_url"):
            await self._save_mx_attachment(att)
            return
        result = await self._rpc(
            "download_attachment",
            {
                "account_key": att["account_key"],
                "message_key": att["message_key"],
                "attachment_id": att["attachment_id"],
                "filename": att["filename"],
            },
        )
        src = (result or {}).get("path")
        if not src or not Path(src).exists():
            return  # _rpc already surfaced any error
        dest_dir = Path.home() / "Downloads"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = self._unique_path(dest_dir / Path(att["filename"]).name)
        try:
            shutil.copyfile(src, dest)
            self.notify(f"Saved {dest.name} to Downloads")
        except OSError as e:
            self.notify(f"Save failed: {e}", severity="error")

    async def fetch_for_forward(self, attachments: list[dict]) -> tuple[list[str], list[str]]:
        """Local paths for a forward's attachments, and the names that couldn't be fetched."""
        paths: list[str] = []
        missed: list[str] = []
        for att in attachments:
            try:
                if att.get("sealed"):
                    raise ValueError("sealed")
                if att.get("download_url"):
                    token = await self._mx_token()
                    if not token:
                        raise ValueError("not signed in")
                    data = await asyncio.to_thread(mxfiles.download, att["download_url"], token)
                    # ponytail: left for the OS to clear; the composer reads them at send.
                    dest = Path(tempfile.mkdtemp(prefix="inbox2-forward-")) / Path(att["filename"]).name
                    dest.write_bytes(data)
                    paths.append(str(dest))
                else:
                    result = await self.bus.call("download_attachment", {
                        "account_key": att["account_key"], "message_key": att["message_key"],
                        "attachment_id": att["attachment_id"], "filename": att["filename"]})
                    paths.append(result["path"])
            except Exception:  # noqa: BLE001 — named in the warning instead
                missed.append(att["filename"])
        return paths, missed

    async def _save_mx_attachment(self, att: dict) -> None:
        if att.get("sealed"):
            self.notify("Files on encrypted domains stay in the desktop app.", severity="warning")
            return
        token = await self._mx_token()
        if not token:
            return
        try:
            data = await asyncio.to_thread(mxfiles.download, att["download_url"], token)
            dest_dir = Path.home() / "Downloads"
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = self._unique_path(dest_dir / Path(att["filename"]).name)
            dest.write_bytes(data)
        except Exception as e:  # noqa: BLE001
            self.notify(f"Save failed: {e}", severity="error")
            return
        self.notify(f"Saved {dest.name} to Downloads")

    @staticmethod
    def _unique_path(path: Path) -> Path:
        if not path.exists():
            return path
        for i in range(1, 1000):
            candidate = path.with_name(f"{path.stem} ({i}){path.suffix}")
            if not candidate.exists():
                return candidate
        return path

    # ── meeting invites (docs/Meeting-Invites.md) ───────────────────────────
    def open_invite(self, invite: dict) -> None:
        def _result(choice: Optional[str]) -> None:
            if not choice:
                return
            params = {"account_key": invite["account_key"], "message_key": invite["message_key"],
                      "attachment_id": invite.get("attachment_id") or ""}
            if choice == "add":
                import time

                params["device_timezone"] = time.tzname[0] if time.tzname else None
                self.run_worker(self._rpc("add_invite_to_calendar", params, ok="Added to calendar"), name="invite")
            elif choice.startswith("rsvp:"):
                params["response"] = choice[len("rsvp:"):]
                self.run_worker(self._rpc("respond_to_invite", params, ok=f"RSVP: {params['response']}"), name="invite")

        self.push_screen(InviteModal(invite), _result)

    # ── outbox ───────────────────────────────────────────────────────────────
    def retry_outbox(self, account_key: str, key: str) -> None:
        if key.startswith(MX_OUTBOX_PREFIX):
            self.run_worker(self._rpc("mx_outbox_retry", {"key": key}, ok="Retrying"), name="outbox")
            return
        self.run_worker(self._rpc("retry_outbox_message", {"account_key": account_key, "key": key}, ok="Retrying…"),
                        name="outbox")

    # ── triage (priority quadrants) ──────────────────────────────────────────
    def _refuse_mx_priority(self, account_key: str) -> bool:
        """MX priority lives in server-side tags, which the channel RPCs can't reach:
        they'd report success and change nothing."""
        if not self.is_mx(account_key):
            return False
        self.notify("Priority on inbox2 domains is set in the desktop app for now.", severity="warning")
        return True

    def apply_priority(self, account_key: str, conversation_keys: list[str], quadrant_key: str) -> None:
        if self._refuse_mx_priority(account_key):
            return
        q = QUADRANTS.get(quadrant_key)
        if not q:
            return
        urgent, important = q["urgent"], q["important"]
        if not urgent and not important:
            # The Later quadrant carries no flags — same as untag in a column model.
            self.clear_priority(account_key, conversation_keys)
            return
        for key in conversation_keys:
            self.db.set_conversation_priority(key, urgent, important)
        self.run_worker(
            self._rpc(
                "set_priority",
                {"account_key": account_key, "conversation_keys": conversation_keys,
                 "urgent": urgent, "important": important},
                ok=f"Triaged: {q['label']}",
            ),
            name="priority",
        )

    def clear_priority(self, account_key: str, conversation_keys: list[str]) -> None:
        if self._refuse_mx_priority(account_key):
            return
        for key in conversation_keys:
            self.db.set_conversation_priority(key, False, False)
        self.run_worker(
            self._rpc(
                "clear_priority",
                {"account_key": account_key, "conversation_keys": conversation_keys},
                ok="Untagged",
            ),
            name="priority",
        )

    # ── Jev: Spaces · triage labels · re-run (docs/Triage.md) ────────────────
    def open_space_picker(self, account_keys: list[str], current: Optional[str], done) -> None:
        items = [(s["slug"], s["name"]) for s in self.db.spaces(account_keys)]
        self.push_screen(PickerModal("Move to Space", items, current=current), done)

    def open_label_picker(self, account_keys: list[str], current: Optional[str], done) -> None:
        items = [(l["slug"], l["name"]) for l in self.db.triage_labels(account_keys)]
        self.push_screen(PickerModal("Triage label", items, current=current), done)

    def set_space(self, conversation_keys: list[str], slug: str) -> None:
        async def _run() -> None:
            for key in conversation_keys:
                await self._rpc("set_conversation_space", {"conversation_key": key, "slug": slug})
            self.notify(f"Moved to Space: {slug}")
            self.refresh_active(force=True)

        self.run_worker(_run(), name="space")

    def set_label(self, conversation_keys: list[str], slug: str) -> None:
        async def _run() -> None:
            for key in conversation_keys:
                await self._rpc("set_conversation_label", {"conversation_key": key, "label": slug})
            self.notify(f"Label: {slug}")
            self.refresh_active(force=True)

        self.run_worker(_run(), name="label")

    def retriage(self, conversation_key: str) -> None:
        async def _run() -> None:
            label = await self._rpc("retriage_conversation", {"conversation_key": conversation_key})
            if label is not None:
                self.notify(f"Jev: {label}")
                self.refresh_active(force=True)

        self.run_worker(_run(), name="retriage")

    # ── actions menu / view source ───────────────────────────────────────────
    def open_actions_menu(self, screen, conv: dict, selected: int = 0, has_invite: bool = False) -> None:
        def _run(action_id: Optional[str]) -> None:
            if not action_id:
                return
            if action_id == "mark":
                (screen.action_mark_unread if conv.get("read") else screen.action_mark_read)()
            elif action_id.startswith("triage_") and action_id != "triage_clear":
                screen.action_triage(action_id[len("triage_"):])
            else:
                handler = getattr(screen, f"action_{action_id}", None)
                if handler:
                    handler()

        self.push_screen(ActionsMenuModal(conv, selected=selected, has_invite=has_invite), _run)

    def open_source(self, account_key: str, message_key: str) -> None:
        async def _load() -> None:
            result = await self._rpc(
                "get_message_source", {"account_key": account_key, "message_key": message_key}
            )
            raw = (result or {}).get("raw") if result else None
            self.push_screen(SourceModal(raw or "(source unavailable)"))

        self.run_worker(_load(), name="source")

    # ── calendar ────────────────────────────────────────────────────────────
    def open_event_editor(self, event: Optional[dict]) -> None:
        account_key = event["account_key"] if event else self._default_account_key("event")
        default_cal = self.db.primary_calendar(account_key) if account_key else None
        calendars = self.db.writable_calendars(account_key) if account_key else []
        attendees = self.db.attendees(event["key"]) if event else []

        def _result(draft: Optional[dict]) -> None:
            if not draft:
                return
            account = draft["account_key"]
            params = {
                "account_key": account,
                "calendar_provider_id": draft.get("calendar_provider_id"),
                "event": draft["event"],
            }
            if event:
                params["event_provider_id"] = draft.get("event_provider_id")
                self.run_worker(self._rpc("calendar_update_event", params, ok="Event updated"), name="cal")
            else:
                prefs.set_last_account("event", account)
                self.run_worker(self._rpc("calendar_create_event", params, ok="Event created"), name="cal")

        self.push_screen(EventEditorModal(event, default_cal, account_key or "", calendars=calendars, attendees=attendees), _result)

    def open_event_detail(self, event: dict) -> None:
        full = self.db.event(event["key"]) or event

        def _result(action: Optional[str]) -> None:
            if action == DETAIL_EDIT:
                self.open_event_editor(event)
            elif action == DETAIL_DELETE:
                self.delete_event(event)
            elif action and action.startswith("rsvp:"):
                self.rsvp_event(event, action[len("rsvp:"):])

        self.push_screen(
            EventDetailModal(full, self.db.attendees(event["key"]), self.db.event_conference_url(event["key"])),
            _result,
        )

    def delete_event(self, event: dict) -> None:
        self.run_worker(
            self._rpc(
                "calendar_delete_event",
                {
                    "account_key": event["account_key"],
                    "calendar_provider_id": event.get("calendar_provider_id"),
                    "event_provider_id": event.get("provider_id"),
                },
                ok="Event deleted",
            ),
            name="cal",
        )

    def rsvp_event(self, event: dict, response: str) -> None:
        self.run_worker(
            self._rpc(
                "calendar_respond_event",
                {
                    "account_key": event["account_key"],
                    "calendar_provider_id": event.get("calendar_provider_id"),
                    "event_provider_id": event.get("provider_id"),
                    "response": response,
                },
                ok=f"RSVP: {response}",
            ),
            name="cal",
        )

    # ── top-bar: sync / settings ─────────────────────────────────────────────
    def sync_now(self) -> None:
        keys = [a["key"] for a in self.accounts if a.get("provider_type") != PROVIDER_INBOX2]
        if not keys:
            return
        self.notify("Syncing…")
        if isinstance(self.screen, MailScreen):
            self._syncing.update(keys)
            self.screen.set_syncing(True)
        for key in keys:
            self.run_worker(self._rpc("start_sync", {"account_key": key}), name="sync")

    def open_settings(self) -> None:
        self.push_screen(SettingsModal(self.accounts, str(self.theme), self.db_file, themes=sorted(self.available_themes)))

    def open_conversation(self, conversation_key: str) -> None:
        """Jump to Mail with one conversation open (from Lore / an entity page)."""
        conv = self.db.conversation([a["key"] for a in self.accounts], conversation_key)
        if not conv:
            self.notify("That conversation isn't on this device.", severity="warning")
            return
        self.goto_section(SECTION_MAIL)
        self.call_after_refresh(lambda: self._mail.show_conversation(conv))

    def open_accounts(self) -> None:
        from .accounts import AccountsModal

        self.push_screen(AccountsModal())

    def reload_accounts(self) -> None:
        """Re-read the account list after an add/remove and redraw the tabs."""
        if self.db is not None:
            self.accounts = self.db.list_accounts()
        self._mail.update_channelbar()
        self._mail.rebuild_sidebar()
        self._mail.refresh_conversations(force=True)

    def action_sync(self) -> None:
        self.sync_now()

    def action_settings(self) -> None:
        # Don't stack a second copy if the overview is already on top.
        if isinstance(self.screen, SettingsModal):
            return
        self.open_settings()

    # ── palette / help ──────────────────────────────────────────────────────
    def action_palette(self) -> None:
        def _run(cmd: Optional[str]) -> None:
            if not cmd:
                return
            mail = self._mail
            if cmd == "compose":
                self.action_compose()
            elif cmd == "unified":
                self.action_channel(-1)
            elif cmd in (SECTION_CALENDAR, SECTION_MAIL, SECTION_LORE, SECTION_RULES, SECTION_WHATSAPP):
                self.goto_section(cmd)
            elif cmd == "accounts":
                self.open_accounts()
            elif cmd == "intelligence":
                from .intelligence import IntelligenceModal

                self.push_screen(IntelligenceModal())
            elif cmd.startswith("cal_"):
                self.goto_section(SECTION_CALENDAR)
                view = cmd[len("cal_"):]
                if view in CAL_VIEWS:
                    self._cal.action_view(view)
            elif cmd == "sync":
                self.sync_now()
            elif cmd == "settings":
                self.open_settings()
            elif cmd == "refresh":
                self.refresh_active(force=True)
            elif cmd == "shortcuts":
                self.action_shortcuts()
            elif cmd == "theme":
                self.push_screen(
                    PickerModal("Theme", [(t, t) for t in sorted(self.available_themes)], current=str(self.theme)),
                    lambda name: self.set_theme(name) if name else None,
                )
            elif cmd == "quit":
                self.exit()
            elif isinstance(self.screen, MailScreen):
                {
                    "search": mail.action_focus_search,
                    "unread": mail.action_toggle_unread,
                    "sort": mail.action_cycle_sort,
                    "outbox": lambda: mail.set_view(VIEW_OUTBOX),
                    "move": mail.action_move,
                    "space": mail.action_space,
                    "label": mail.action_label,
                    "retriage": mail.action_retriage,
                }.get(cmd, lambda: None)()

        self.push_screen(CommandPaletteModal(), _run)

    def action_shortcuts(self) -> None:
        self.push_screen(ShortcutsModal())

    # ── helpers ──────────────────────────────────────────────────────────
    def _default_account_key(self, kind: str | None = None) -> str:
        """The filtered channel → (with ``kind``) the account last used for it
        (``from`` / ``event``, see prefs) → the first."""
        if self.active_channel is not None and 0 <= self.active_channel < len(self.accounts):
            return self.accounts[self.active_channel]["key"]
        last = prefs.last_account(kind) if kind else None
        if any(a["key"] == last for a in self.accounts):
            return last
        return self.accounts[0]["key"] if self.accounts else ""

    def _self_address(self, account_key: str, msg: Optional[dict] = None) -> str:
        """Who you send as from an account. On an inbox2 domain with several
        sendable addresses, a reply keeps the one the thread used (the desktop's
        replyFromAddress: From first, then To, then Cc)."""
        for a in self.accounts:
            if a["key"] == account_key:
                own = a.get("from_addresses") or []
                if msg and len(own) > 1:
                    for _, addr in getaddresses([msg.get(f) or "" for f in ("from_address", "to_address", "cc_address")]):
                        if addr.lower() in own:
                            return addr.lower()
                return a.get("email_address", "")
        return ""

    async def _rpc(self, method: str, params: dict, ok: Optional[str] = None):
        try:
            result = await self.bus.call(method, params)
            if ok:
                self.notify(ok)
            return result
        except BusError as e:
            self.notify(f"{method} failed: {e}", severity="error")
        except Exception as e:  # noqa: BLE001
            self.notify(f"{method} error: {e}", severity="error")
        return None


def run_tui(data_path: Path, api_base: Optional[str] = None, jwt: Optional[str] = None) -> None:
    """Open the Textual app over the shared data dir (the `inbox2` command with
    no subcommand — see cli.py)."""
    db_file = data_path / "inbox2.db"

    # Determine login state without spawning the engine: connected only if the DB
    # exists and has at least one account.
    db: Optional[Database] = Database(str(db_file)) if db_file.exists() else None
    accounts = db.list_accounts() if db is not None else []

    if not accounts:
        # Logged out — show the welcome screen, no engine.
        app = Inbox2App(db=db, bus=NullBus(), accounts=[], db_file=db_file)
        try:
            app.run()
        finally:
            if db is not None:
                db.close()
        return

    # Logged in — ensure the shared engine + connect the bus.
    try:
        sock, child = runtime.ensure_engine(data_path, api_base=api_base, jwt=jwt)
    except RuntimeError as e:
        raise SystemExit(str(e))

    bus = AsyncSocketBus()

    async def _connect() -> None:
        try:
            await bus.connect(str(sock))
        except OSError:
            pass

    app = Inbox2App(db=db, bus=bus, child=child, db_file=db_file, accounts=accounts)
    # Connect the bus right after the app loop starts.
    app.call_after_refresh(lambda: app.run_worker(_connect(), name="connect"))
    try:
        app.run()
    finally:
        db.close()
        if child is not None and child.poll() is None:
            child.terminate()


def main() -> None:  # kept for `python -m inbox2_cli.app`; the console script is cli.main
    from .cli import main as cli_main

    cli_main()


if __name__ == "__main__":
    main()

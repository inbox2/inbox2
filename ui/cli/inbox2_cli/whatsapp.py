"""WhatsApp section — the desktop's local WhatsApp tab in the terminal
(docs/Local-WhatsApp.md, web pages/whatsapp/WhatsAppPage.jsx).

The engine host reads WhatsApp Desktop's own database read-only (macOS) and
sends by driving WhatsApp Desktop itself; this screen only talks to it over the
bus (`wa_status` · `wa_chats` · `wa_messages` · `wa_search` · `wa_send` ·
`wa_open_in_whatsapp`). It polls `wa_status` every few seconds and reloads only
when its `version` moves — the same cheap change marker the desktop polls.
"""

from __future__ import annotations

import datetime as dt
from typing import Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen, Screen
from textual.widgets import DataTable, Footer, Input, Static

from .screens import _accent, _muted, _short, brand_text

POLL_SECONDS = 5.0
PAGE = 60
SEARCH_LIMIT = 100
# WhatsApp's ZMESSAGETYPE values that render as something other than text
# (mirrors web lib/localWhatsApp.js WA_KIND).
KIND_LABEL = {
    1: "photo", 2: "video", 3: "voice message", 4: "contact", 5: "location", 8: "document",
    10: "call", 11: "GIF", 14: "deleted", 15: "sticker", 46: "poll", 66: "poll",
}
KIND_SYSTEM = 6
# macOS guards WhatsApp's container: whoever hosts the engine needs Full Disk Access.
NO_ACCESS_HINT = (
    "Give the app hosting the engine (Inbox2, or this terminal when the CLI's "
    "engine_daemon hosts it) Full Disk Access in System Settings › Privacy & Security."
)


def _when(ms: int | None) -> dt.datetime:
    return dt.datetime.fromtimestamp((ms or 0) / 1000)


def _clock(ms: int | None) -> str:
    """A list-row time: hh:mm today, else the date (like the mail list)."""
    if not ms:
        return ""
    at = _when(ms)
    if at.year > dt.date.today().year + 1:
        return "pinned"  # WhatsApp parks pins thousands of years ahead
    return at.strftime("%H:%M") if at.date() == dt.date.today() else at.strftime("%-d %b")


def message_line(m: dict) -> str:
    """One message's text, with a placeholder for media/calls/etc."""
    kind = m.get("kind") or 0
    text = (m.get("text") or "").strip()
    label = KIND_LABEL.get(kind)
    if label:
        name = (m.get("media") or {}).get("name") or (m.get("media") or {}).get("title")
        tag = f"[{label}{': ' + name if name else ''}]"
        return f"{tag} {text}".strip()
    return text


IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic")


def image_cells(width: int, height: int, max_cols: int = 100, max_rows: int = 40) -> tuple[int, int]:
    """Pixel size for a half-block render that fits max_cols × max_rows cells
    (one cell = 1 px wide, 2 px tall), keeping the aspect ratio."""
    if width <= 0 or height <= 0:
        return max_cols, max_rows * 2
    scale = min(max_cols / width, (max_rows * 2) / height, 1.0)
    return max(1, int(width * scale)), max(2, int(height * scale) // 2 * 2)


class MediaPreviewModal(ModalScreen[None]):
    """A photo drawn inline in truecolor half-blocks (rich-pixels) — the desktop
    viewer, in the terminal. escape closes; o opens it full size."""

    DEFAULT_CSS = """
    MediaPreviewModal { align: center middle; }
    MediaPreviewModal > Vertical { width: auto; height: auto; max-height: 95%; border: thick $accent; background: $surface; padding: 0 1; }
    MediaPreviewModal #mp-title { height: 1; color: $text-muted; }
    """
    BINDINGS = [Binding("escape,q,enter", "close", "Close"), Binding("o", "open", "Open full size")]

    def __init__(self, file: str, pixels):
        super().__init__()
        self.file = file
        self.pixels, self.cols, self.rows = pixels if isinstance(pixels, tuple) else (pixels, 40, 20)

    @staticmethod
    def render_image(file: str, cols: int, rows: int):
        """(renderable, width in cells, height in cells) for a photo; raises on a file
        PIL can't read. rich-pixels doesn't report its size, so the modal sizes
        itself from these."""
        from PIL import Image
        from rich_pixels import Pixels

        with Image.open(file) as im:
            w, h = image_cells(*im.size, max_cols=cols, max_rows=rows)
            return Pixels.from_image(im.convert("RGB"), resize=(w, h)), w, h // 2

    def compose(self) -> ComposeResult:
        with Vertical(id="mp-box"):
            yield Static(f"{self.file.rsplit('/', 1)[-1]} · o open full size · escape close", id="mp-title")
            yield Static(self.pixels, id="mp-image")

    def on_mount(self) -> None:
        # Size from the render (rich-pixels has no measure); the title needs room too.
        self.query_one("#mp-box").styles.width = max(self.cols, 44) + 4
        self.query_one("#mp-image").styles.width = self.cols
        self.query_one("#mp-image").styles.height = self.rows

    def action_open(self) -> None:
        import subprocess
        import sys

        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", self.file],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def action_close(self) -> None:
        self.dismiss(None)


class WhatsAppScreen(Screen):
    """Chats | messages + composer, keyboard-driven."""

    DEFAULT_CSS = """
    WhatsAppScreen { layout: vertical; }
    #wa-header { height: 1; background: $panel; }
    #wa-brand { width: auto; padding: 0 1; }
    #wa-tabs { width: 1fr; }
    #wa-state { width: auto; padding: 0 1; color: $text-muted; }
    #wa-body { height: 1fr; }
    #wa-left { width: 40; height: 1fr; border-right: solid $panel; }
    #wa-search { height: 1; border: none; background: $boost; padding: 0 1; }
    #wa-chats { height: 1fr; }
    #wa-right { width: 1fr; height: 1fr; }
    #wa-title { height: 1; padding: 0 1; background: $panel; text-style: bold; }
    #wa-log { height: 1fr; padding: 0 1; }
    #wa-log:focus { border-left: thick $accent; }
    #wa-files { height: 1; border: none; background: $boost; padding: 0 1; display: none; }
    #wa-files.-shown { display: block; }
    #wa-compose { height: 3; border: tall $accent; }
    #wa-unavailable { height: 1fr; padding: 2 4; }
    """

    BINDINGS = [
        Binding("slash", "search", "Search"),
        Binding("A", "toggle_archived", "Archived"),
        Binding("o", "open_in_whatsapp", "Open in WhatsApp"),
        Binding("m", "media", "Media"),
        Binding("ctrl+o", "attach", "Attach"),
        Binding("i", "compose", "Write", show=False),
        Binding("k,up", "older", "Older", show=False),
        Binding("j,down", "newer", "Newer", show=False),
        Binding("escape", "back", "Back", show=False),
        Binding("question_mark", "noop", "", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.status: dict = {}
        self.chats: list[dict] = []
        self.hits: Optional[list[dict]] = None  # search results replace the chat list
        self.show_archived = False
        self.chat: Optional[dict] = None
        self._sending: set[int] = set()  # chats with a wa_send in flight
        self.messages: list[dict] = []
        self.has_earlier = False
        self._row_ids: list = []
        self._version: Optional[str] = None

    # ── layout ───────────────────────────────────────────────────────────
    def compose(self) -> ComposeResult:
        with Horizontal(id="wa-header"):
            yield Static(brand_text(self.app), id="wa-brand")
            yield Static(self.app.section_tabs(), id="wa-tabs")
            yield Static("", id="wa-state")
        with Horizontal(id="wa-body"):
            with Vertical(id="wa-left"):
                yield Input(placeholder="/ search messages", id="wa-search")
                table = DataTable(id="wa-chats", cursor_type="row", zebra_stripes=True)
                table.add_columns("Chat", "", "When")
                yield table
            with Vertical(id="wa-right"):
                yield Static("Pick a chat", id="wa-title")
                with VerticalScroll(id="wa-log"):
                    yield Static("", id="wa-messages")
                yield Input(placeholder="attach: file paths, comma-separated", id="wa-files")
                yield Input(placeholder="Message (enter sends)", id="wa-compose")
        yield Static("", id="wa-unavailable")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#wa-unavailable").display = False
        self.query_one("#wa-log").can_focus = True
        self.set_interval(POLL_SECONDS, self._poll_if_shown)
        self.refresh_data()
        self.query_one("#wa-chats", DataTable).focus()

    def on_screen_resume(self) -> None:
        self.query_one("#wa-tabs", Static).update(self.app.section_tabs())
        self.refresh_data()

    # ── data ─────────────────────────────────────────────────────────────
    def refresh_data(self) -> None:
        self.run_worker(self._poll(force=True), name="wa-poll", exclusive=True)

    def _poll_if_shown(self) -> None:
        if self.app.screen is self:
            self.run_worker(self._poll(), name="wa-poll", exclusive=True)

    async def _poll(self, force: bool = False) -> None:
        # Not via _rpc: a host without WhatsApp would toast an error every poll.
        try:
            status = await self.app.bus.call("wa_status", {})
        except Exception:  # noqa: BLE001 — shown as "unavailable" below
            status = None
        self.status = status or {"available": False, "error": "The engine host doesn't serve WhatsApp (update the desktop app or engine_daemon)."}
        self._show_availability()
        if not self.status.get("available"):
            return
        version = self.status.get("version")
        if not force and version == self._version:
            return
        self._version = version
        self.chats = await self.app._rpc("wa_chats", {}) or []
        self._render_chats()
        if self.chat:
            await self._load_messages(self.chat["id"])

    def _show_availability(self) -> None:
        ok = bool(self.status.get("available"))
        self.query_one("#wa-body").display = ok
        box = self.query_one("#wa-unavailable", Static)
        box.display = not ok
        state = self.query_one("#wa-state", Static)
        if ok:
            unread = self.status.get("unread") or 0
            state.update(f"{unread} unread" if unread else "")
            return
        state.update("unavailable")
        err = self.status.get("error") or "WhatsApp isn't readable right now."
        msg = Text("WhatsApp\n\n", style="bold")
        msg.append(err + "\n\n")
        if "macOS" in err:
            msg.append("Local WhatsApp reads WhatsApp Desktop's database, which only exists on a Mac.", style=_muted(self.app))
        elif "not installed" in err:
            msg.append("Install WhatsApp Desktop from the App Store and sign in, then come back here.", style=_muted(self.app))
        else:
            msg.append(NO_ACCESS_HINT, style=_muted(self.app))
        box.update(msg)

    def _visible_chats(self) -> list[dict]:
        rows = [c for c in self.chats if self.show_archived or not c.get("archived")]
        # Pinned on top (WhatsApp itself keeps pins first), then newest.
        return sorted(rows, key=lambda c: (not c.get("pinned"), -(c.get("last_at") or 0)))

    def _render_chats(self) -> None:
        table = self.query_one("#wa-chats", DataTable)
        prior = self._row_ids[table.cursor_row] if self._row_ids and table.cursor_row is not None and table.cursor_row < len(self._row_ids) else None
        table.clear()
        self._row_ids = []
        if self.hits is not None:
            for h in self.hits:
                name = Text(_short(h.get("chat_name") or "", 18), style="bold")
                name.append(f"  {_short(h.get('text') or '', 40)}", style=_muted(self.app))
                table.add_row(name, "", _clock(h.get("at")), key=f"hit:{h['id']}")
                self._row_ids.append(("hit", h))
        else:
            for c in self._visible_chats():
                unread = c.get("unread") or 0
                name = Text(("☰ " if c.get("is_group") else "") + _short(c.get("name") or c.get("jid") or "", 26),
                            style="bold" if unread else "")
                if c.get("last_text"):
                    name.append(f"\n{_short(c['last_text'], 34)}", style=_muted(self.app))
                badge = Text(str(unread), style=f"bold {_accent(self.app)}") if unread else Text("")
                when = "📌" if c.get("pinned") else _clock(c.get("last_at"))
                table.add_row(name, badge, Text(when, style=_muted(self.app)), key=f"chat:{c['id']}", height=2 if c.get("last_text") else 1)
                self._row_ids.append(("chat", c))
        if prior in self._row_ids:
            table.move_cursor(row=self._row_ids.index(prior))

    async def _load_messages(self, chat_id: int, around: Optional[int] = None) -> None:
        params: dict = {"chat_id": chat_id, "limit": PAGE}
        if around:
            params["around"] = around
        page = await self.app._rpc("wa_messages", params) or {}
        self.messages = page.get("messages") or []
        self.has_earlier = bool(page.get("has_earlier"))
        self._render_messages(scroll_end=not around)

    async def _load_earlier(self) -> None:
        if not (self.chat and self.messages and self.has_earlier):
            return
        page = await self.app._rpc("wa_messages", {"chat_id": self.chat["id"], "before": self.messages[0]["id"], "limit": PAGE}) or {}
        older = page.get("messages") or []
        self.has_earlier = bool(page.get("has_earlier"))
        self.messages = older + self.messages
        self._render_messages(scroll_end=False)

    def _render_messages(self, scroll_end: bool = True) -> None:
        t = Text()
        if self.has_earlier:
            t.append("↑ k at the top loads earlier messages\n", style=_muted(self.app))
        day = None
        for m in self.messages:
            at = _when(m.get("at"))
            if at.date() != day:
                day = at.date()
                t.append(f"\n── {at.strftime('%a %-d %b %Y')} ──\n", style=f"bold {_muted(self.app)}")
            body = message_line(m)
            if m.get("kind") == KIND_SYSTEM:
                t.append(f"   {body}\n", style=f"italic {_muted(self.app)}")
                continue
            who = "You" if m.get("from_me") else (m.get("sender") or (self.chat or {}).get("name") or "")
            t.append(f"{at.strftime('%H:%M')} ", style=_muted(self.app))
            t.append(f"{who}: ", style=f"bold {_accent(self.app)}" if m.get("from_me") else "bold")
            t.append(f"{body}\n")
        self.query_one("#wa-messages", Static).update(t)
        if scroll_end:
            self.call_after_refresh(lambda: self.query_one("#wa-log", VerticalScroll).scroll_end(animate=False))

    # ── events ───────────────────────────────────────────────────────────
    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        idx = event.cursor_row
        if idx is None or not (0 <= idx < len(self._row_ids)):
            return
        kind, row = self._row_ids[idx]
        if kind == "hit":
            chat = next((c for c in self.chats if c["id"] == row["chat_id"]), {"id": row["chat_id"], "name": row.get("chat_name")})
            self._open_chat(chat, around=row["id"])
        else:
            self._open_chat(row)

    def _open_chat(self, chat: dict, around: Optional[int] = None) -> None:
        self.chat = chat
        title = ("☰ " if chat.get("is_group") else "") + (chat.get("name") or chat.get("jid") or "")
        self.query_one("#wa-title", Static).update(title)
        self.run_worker(self._load_messages(chat["id"], around), name="wa-msgs", exclusive=True)
        self.query_one("#wa-compose", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "wa-search":
            self.run_worker(self._search(event.value.strip()), name="wa-search", exclusive=True)
        elif event.input.id in ("wa-compose", "wa-files"):
            self._send()

    async def _search(self, query: str) -> None:
        if not query:
            self.hits = None
        else:
            self.hits = await self.app._rpc("wa_search", {"query": query, "limit": SEARCH_LIMIT}) or []
            if not self.hits:
                self.app.notify("No messages found.")
        self._render_chats()
        self.query_one("#wa-chats", DataTable).focus()

    def _send(self) -> None:
        if not self.chat:
            self.app.notify("Pick a chat first.", severity="warning")
            return
        compose = self.query_one("#wa-compose", Input)
        files_in = self.query_one("#wa-files", Input)
        text = compose.value.strip()
        files = [f.strip() for f in files_in.value.split(",") if f.strip()]
        if not text and not files:
            return
        chat_id = self.chat["id"]
        # One send per chat at a time: enter again while it's in flight must not
        # send the same text twice (the draft only clears once it landed).
        if chat_id in self._sending:
            self.app.notify("Still sending…", timeout=2)
            return
        self._sending.add(chat_id)

        async def _go() -> None:
            # wa_send returns once WhatsApp's own database shows the message; the
            # draft is cleared only then, so a failed send keeps what was typed.
            try:
                await self.app.bus.call("wa_send", {"chat_id": chat_id, "text": text or None, "files": files}, timeout=120)
            except Exception as e:  # noqa: BLE001
                self.app.notify(f"Not sent: {e}", severity="error")
                return
            finally:
                self._sending.discard(chat_id)
            if compose.value.strip() == text:
                compose.value = ""
            if [f.strip() for f in files_in.value.split(",") if f.strip()] == files:
                files_in.value = ""
                files_in.remove_class("-shown")
            await self._load_messages(chat_id)

        self.run_worker(_go(), name="wa-send")
        compose.focus()

    # ── actions ──────────────────────────────────────────────────────────
    def action_search(self) -> None:
        self.query_one("#wa-search", Input).focus()

    def action_toggle_archived(self) -> None:
        self.show_archived = not self.show_archived
        self.app.notify("Showing archived chats" if self.show_archived else "Hiding archived chats")
        self._render_chats()

    def action_open_in_whatsapp(self) -> None:
        if isinstance(self.app.focused, Input):
            return
        chat = self.chat
        table = self.query_one("#wa-chats", DataTable)
        if self.app.focused is table and self._row_ids and table.cursor_row is not None:
            kind, row = self._row_ids[table.cursor_row]
            chat = row if kind == "chat" else {"id": row["chat_id"]}
        if chat:
            self.run_worker(self.app._rpc("wa_open_in_whatsapp", {"chat_id": chat["id"]}), name="wa-open")

    def media_items(self, chat_media: list[dict]) -> list[tuple[str, str]]:
        """Photos/videos/GIFs (wa_chat_media) plus the documents and voice notes in
        the loaded messages, newest first, as (container path, label)."""
        seen, items = set(), []
        docs = [{"path": (m.get("media") or {}).get("path"), "at": m.get("at"), "name": (m.get("media") or {}).get("name"),
                 "kind": m.get("kind"), "from_me": m.get("from_me"), "sender": m.get("sender")}
                for m in self.messages if (m.get("media") or {}).get("path")]
        for it in sorted(list(chat_media) + docs, key=lambda i: i.get("at") or 0, reverse=True):
            path = it.get("path")
            if not path or path in seen:
                continue
            seen.add(path)
            who = "You" if it.get("from_me") else (it.get("sender") or "")
            name = it.get("name") or path.rsplit("/", 1)[-1]
            when = _when(it["at"]).strftime("%-d %b %H:%M") if it.get("at") else ""  # ms, like every wa_* time
            items.append((path, f"{name}  ·  {who}  {when}".strip()))
        return items

    def action_media(self) -> None:
        """The desktop's media viewer, terminal-native: pick a file, then open it in
        its default app or save a copy to ~/Downloads."""
        if isinstance(self.app.focused, Input) or not self.chat:
            return
        from .modals import PickerModal

        async def _run() -> None:
            media = await self.app._rpc("wa_chat_media", {"chat_id": self.chat["id"]}) or []
            items = self.media_items(media)
            if not items:
                self.app.notify("No downloaded media in this chat.")
                return

            def _picked(path: Optional[str]) -> None:
                if path:
                    choices = [("open", "Open"), ("save", "Save to Downloads")]
                    if path.lower().endswith(IMAGE_EXTS):
                        choices.insert(0, ("preview", "Preview here"))
                    self.app.push_screen(
                        PickerModal("Media", choices),
                        lambda how: self.app.run_worker(self._media_do(path, how), name="wa-media") if how else None,
                    )

            self.app.push_screen(PickerModal(f"Media — {self.chat.get('name') or ''}", items), _picked)

        self.run_worker(_run(), name="wa-media-list")

    async def _media_do(self, path: str, how: str) -> None:
        import shutil
        import subprocess
        import sys
        from pathlib import Path

        file = await self.app._rpc("wa_media_file", {"path": path})
        if not file:
            return
        if how == "preview":
            try:
                pixels = MediaPreviewModal.render_image(
                    file, max(20, self.app.size.width - 8), max(10, self.app.size.height - 6))
                self.app.push_screen(MediaPreviewModal(file, pixels))
            except Exception as e:  # noqa: BLE001 — an unreadable/odd image format (HEIC without a plugin)
                self.app.notify(f"Can't preview that one ({e}); opening it instead.", severity="warning")
                how = "open"
            else:
                return
        if how == "open":
            opener = "open" if sys.platform == "darwin" else "xdg-open"
            subprocess.Popen([opener, file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        dest = self.app._unique_path(Path.home() / "Downloads" / Path(file).name)
        shutil.copy2(file, dest)
        self.app.notify(f"Saved to {dest}")

    def action_attach(self) -> None:
        files = self.query_one("#wa-files", Input)
        files.add_class("-shown")
        files.focus()

    def action_compose(self) -> None:
        if not isinstance(self.app.focused, Input):
            self.query_one("#wa-compose", Input).focus()

    def action_older(self) -> None:
        log = self.query_one("#wa-log", VerticalScroll)
        if self.app.focused is log:
            if log.scroll_y <= 0 and self.has_earlier:
                self.run_worker(self._load_earlier(), name="wa-earlier", exclusive=True)
            else:
                log.scroll_up()
        elif self.app.focused is self.query_one("#wa-chats"):
            self.query_one("#wa-chats", DataTable).action_cursor_up()

    def action_newer(self) -> None:
        log = self.query_one("#wa-log", VerticalScroll)
        if self.app.focused is log:
            log.scroll_down()
        elif self.app.focused is self.query_one("#wa-chats"):
            self.query_one("#wa-chats", DataTable).action_cursor_down()

    def action_back(self) -> None:
        focused = self.app.focused
        search = self.query_one("#wa-search", Input)
        if focused is search or self.hits is not None:
            search.value = ""
            self.hits = None
            self._render_chats()
        self.query_one("#wa-chats", DataTable).focus()

    def action_noop(self) -> None:
        pass

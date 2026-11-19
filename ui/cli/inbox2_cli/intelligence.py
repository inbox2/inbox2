"""Settings › Intelligence: the desktop's On-device AI, Triage & sync and
Connected apps (MCP) pages, in one terminal page.

Keys are validated by the host with one real call and kept in the engine's
encrypted secret store — the same place the desktop keeps them — so either app
sees what the other set.
"""

from __future__ import annotations

import asyncio

from importlib.metadata import PackageNotFoundError, version
from typing import Optional

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import DataTable, Input, Label, Select, Static, Switch

# core triage::ProcessingWindow, in widening order (the desktop's slider).
WINDOWS = [("new_only", "New mail only"), ("1_month", "Last month"), ("3_months", "3 months"),
           ("6_months", "6 months"), ("1_year", "1 year"), ("everything", "Everything")]
# Lore's "Handled for you" groups that can run on their own (core LoreAutoSettings).
LORE_AUTO = [("fyi", "FYI threads → archive"), ("receipt", "Receipts → archive"), ("notification", "Sign-in codes & alerts → trash")]
KEYS = [("jev", "set_jev_key", "typesafe_api_key", "Jev key (triage labels + priority)"),
        ("openai", "set_openai_key", "openai_api_key", "OpenAI key (summaries, smart replies)")]


def cli_version() -> str:
    try:
        return version("inbox2-cli")
    except PackageNotFoundError:
        return "dev"


def progress_line(p: Optional[dict]) -> str:
    """`triage_progress` → one line (desktop Triage & sync header)."""
    if not p:
        return "Triage progress unavailable."
    status = {"ok": "Jev connected", "missing": "no Jev key — rules only", "unauthorized": "Jev key rejected"}.get(
        p.get("jevStatus"), p.get("jevStatus") or "")
    return f"Triaged {p.get('done', 0)} of {p.get('inWindow', 0)} in the window · {p.get('pending', 0)} pending · {status}"


class IntelligenceModal(ModalScreen[None]):
    DEFAULT_CSS = """
    IntelligenceModal { align: center middle; }
    IntelligenceModal > VerticalScroll { width: 92; height: 90%; border: thick $accent; background: $surface; padding: 1 2; }
    IntelligenceModal .in-title { text-style: bold; height: 1; margin-top: 1; }
    IntelligenceModal .in-muted { color: $text-muted; height: auto; }
    IntelligenceModal .row { height: 3; }
    IntelligenceModal .row > Label { width: 40; height: 3; content-align: left middle; }
    IntelligenceModal .row > Input, IntelligenceModal .row > Select { width: 1fr; }
    IntelligenceModal DataTable { height: auto; max-height: 8; }
    """
    BINDINGS = [
        Binding("escape", "close", "Close", priority=True),
        Binding("ctrl+n", "add_app", "Add app by token", priority=True),
        Binding("ctrl+x", "remove_app", "Remove app", priority=True),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.connections: list[dict] = []
        self._loading = True  # don't save the controls' initial values back
        self._window: Optional[str] = None  # the stored window, to restore on a refused save
        self._auto: dict = {}  # the stored Lore auto settings
        # One save at a time, in the order made (asyncio.Lock is FIFO): rapid
        # changes can't land on the host out of order.
        self._save_lock = asyncio.Lock()

    def compose(self) -> ComposeResult:
        with VerticalScroll():
            yield Label("Intelligence", classes="in-title")
            yield Static("", id="in-progress", classes="in-muted")
            yield Label("Keys", classes="in-title")
            for kid, _, _, label in KEYS:
                with Horizontal(classes="row"):
                    yield Label(label, id=f"in-{kid}-label")
                    yield Input(placeholder="paste a key · enter saves · empty + enter removes", password=True, id=f"in-{kid}")
            yield Label("Triage & sync", classes="in-title")
            with Horizontal(classes="row"):
                yield Label("Process mail from")
                yield Select([(label, v) for v, label in WINDOWS], allow_blank=True, id="in-window")
            yield Static("Handled for you — let Lore act on its own:", classes="in-muted")
            for key, label in LORE_AUTO:
                with Horizontal(classes="row"):
                    yield Label(label)
                    yield Switch(id=f"in-auto-{key}")
            yield Label("Connected apps (Send to…)", classes="in-title")
            table = DataTable(id="in-apps", cursor_type="row")
            table.add_columns("App", "URL", "Sign-in", "Status")
            yield table
            yield Static("ctrl+n add by URL + token · ctrl+x remove the highlighted app · browser sign-in apps: add in the desktop app",
                         classes="in-muted")
            yield Label("About", classes="in-title")
            yield Static(f"inbox2 CLI {cli_version()}", id="in-about", classes="in-muted")

    def on_mount(self) -> None:
        self.run_worker(self._load(), group="in", exclusive=True)

    async def _call(self, method: str, params: Optional[dict] = None, quiet: bool = False):
        try:
            return await self.app.bus.call(method, params or {}, timeout=60)
        except Exception as e:  # noqa: BLE001
            if not quiet:
                self.app.notify(f"{method}: {e}", severity="error")
            return None

    async def _load(self) -> None:
        self._loading = True
        self.query_one("#in-progress", Static).update(progress_line(await self._call("triage_progress", quiet=True)))
        for kid, _, secret, label in KEYS:
            has = await self._call("has_secret", {"name": secret}, quiet=True)
            self.query_one(f"#in-{kid}-label", Label).update(f"{label}  {'✓ set' if has else '— not set'}")
        window = await self._call("get_processing_window", quiet=True)
        self._window = window if window in {v for v, _ in WINDOWS} else None
        if window in {v for v, _ in WINDOWS}:
            self.query_one("#in-window", Select).value = window
        auto = await self._call("get_lore_auto", quiet=True) or {}
        self._auto = {key: bool(auto.get(key)) for key, _ in LORE_AUTO}
        for key, _ in LORE_AUTO:
            self.query_one(f"#in-auto-{key}", Switch).value = self._auto[key]
        await self._load_apps()
        self.call_after_refresh(self._done_loading)

    def _done_loading(self) -> None:
        self._loading = False

    async def _load_apps(self) -> None:
        self.connections = await self._call("mcp_list_connections", quiet=True) or []
        table = self.query_one("#in-apps", DataTable)
        table.clear()
        for c in self.connections:
            table.add_row(c.get("name") or "", c.get("url") or "", c.get("auth") or "", c.get("status") or "", key=c["id"])
        if not self.connections:
            table.add_row("No apps connected.", "", "", "")

    # ── saving ──────────────────────────────────────────────────────────────
    def on_input_submitted(self, event: Input.Submitted) -> None:
        for kid, method, _, label in KEYS:
            if event.input.id == f"in-{kid}":
                key = event.value.strip()

                async def _save(method=method, key=key, label=label) -> None:
                    self.app.notify("Checking the key…" if key else "Removing the key…", timeout=2)
                    try:
                        await self.app.bus.call(method, {"key": key or None}, timeout=60)
                    except Exception as e:  # noqa: BLE001 — the host's validation said no
                        self.app.notify(f"Not saved: {e}", severity="error")
                        return
                    event.input.value = ""
                    self.app.notify(f"{label.split(' (')[0]} {'saved' if key else 'removed'}.")
                    await self._load()

                self.run_worker(_save(), group="in-key", exclusive=True)

    def on_select_changed(self, event: Select.Changed) -> None:
        # Not while loading, and not for the stored value (a load's own Changed
        # can arrive after `_loading` clears).
        if event.select.id == "in-window" and not self._loading and event.value not in (Select.NULL, self._window):
            window, previous = event.value, self._window

            async def _save() -> None:
                try:
                    async with self._save_lock:
                        await self.app.bus.call("set_processing_window", {"window": window}, timeout=60)
                except Exception as e:  # noqa: BLE001 — the host refused: put the old value back
                    self.app.notify(f"Not saved: {e}", severity="error")
                    self._loading = True
                    self.query_one("#in-window", Select).value = previous if previous else Select.NULL
                    self.call_after_refresh(self._done_loading)
                    return
                self._window = window
                self.app.notify("Processing window saved — wider windows backfill in the background.")

            self.run_worker(_save(), group="in-save")

    def on_switch_changed(self, event: Switch.Changed) -> None:
        if self._loading or not (event.switch.id or "").startswith("in-auto-"):
            return
        settings = {key: self.query_one(f"#in-auto-{key}", Switch).value for key, _ in LORE_AUTO}
        if settings == self._auto:  # a load's own Changed, arriving after `_loading` cleared
            return
        previous, self._auto = self._auto, settings

        async def _save() -> None:
            try:
                async with self._save_lock:
                    await self.app.bus.call("set_lore_auto", {"settings": settings}, timeout=60)
            except Exception as e:  # noqa: BLE001 — refused: show what is actually stored
                self.app.notify(f"Not saved: {e}", severity="error")
                self._auto = previous
                self._loading = True
                for key, _ in LORE_AUTO:
                    self.query_one(f"#in-auto-{key}", Switch).value = bool(previous.get(key))
                self.call_after_refresh(self._done_loading)

        self.run_worker(_save(), group="in-save")

    # ── connected apps ───────────────────────────────────────────────────────
    def action_add_app(self) -> None:
        from .sendto import TokenConnectionModal

        def _added(req: Optional[dict]) -> None:
            if req:
                async def _go() -> None:
                    if await self._call("mcp_add_token_connection", req) is not None:
                        self.app.notify(f"Connected {req.get('name') or req['url']}.")
                    await self._load_apps()

                self.run_worker(_go(), group="in-apps", exclusive=True)

        self.app.push_screen(TokenConnectionModal(), _added)

    def action_remove_app(self) -> None:
        table = self.query_one("#in-apps", DataTable)
        if not self.connections or table.cursor_row is None or table.cursor_row >= len(self.connections):
            return
        conn = self.connections[table.cursor_row]

        async def _go() -> None:
            try:
                await self.app.bus.call("mcp_remove_connection", {"id": conn["id"]}, timeout=60)
            except Exception as e:  # noqa: BLE001
                self.app.notify(f"Not removed: {e}", severity="error")
            else:
                self.app.notify(f"Removed {conn['name']}.")
            await self._load_apps()

        self.run_worker(_go(), group="in-apps", exclusive=True)

    def action_close(self) -> None:
        self.dismiss(None)

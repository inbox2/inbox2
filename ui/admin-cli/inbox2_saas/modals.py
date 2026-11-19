"""Reusable modal dialogs: confirm, type-to-confirm, single input, choice, and
the live org/user search palette (ctrl+k)."""

from __future__ import annotations

from typing import Optional

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, ListItem, ListView, Static


class ConfirmModal(ModalScreen[bool]):
    DEFAULT_CSS = """
    ConfirmModal { align: center middle; }
    ConfirmModal > Vertical { width: 60; height: auto; padding: 1 2; border: thick $accent; background: $surface; }
    ConfirmModal Horizontal { height: auto; align-horizontal: right; margin-top: 1; }
    ConfirmModal Button { margin-left: 2; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, message: str):
        super().__init__()
        self._message = message

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(self._message)
            with Horizontal():
                yield Button("Cancel", id="no")
                yield Button("Confirm", variant="error", id="yes")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_cancel(self) -> None:
        self.dismiss(False)


class TypeToConfirmModal(ModalScreen[bool]):
    """Destructive guard: the operator must type `phrase` exactly to confirm."""

    DEFAULT_CSS = """
    TypeToConfirmModal { align: center middle; }
    TypeToConfirmModal > Vertical { width: 64; height: auto; padding: 1 2; border: thick $error; background: $surface; }
    TypeToConfirmModal Input { margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, message: str, phrase: str):
        super().__init__()
        self._message = message
        self._phrase = phrase

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(self._message)
            yield Static(f"Type [b]{self._phrase}[/b] to confirm:")
            yield Input(placeholder=self._phrase, id="confirm-input")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip() == self._phrase)

    def action_cancel(self) -> None:
        self.dismiss(False)


class InputModal(ModalScreen[Optional[str]]):
    DEFAULT_CSS = """
    InputModal { align: center middle; }
    InputModal > Vertical { width: 60; height: auto; padding: 1 2; border: thick $accent; background: $surface; }
    InputModal Input { margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, prompt: str, placeholder: str = ""):
        super().__init__()
        self._prompt = prompt
        self._placeholder = placeholder

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(self._prompt)
            yield Input(placeholder=self._placeholder, id="value")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)

    def action_cancel(self) -> None:
        self.dismiss(None)


class ChoiceModal(ModalScreen[Optional[str]]):
    DEFAULT_CSS = """
    ChoiceModal { align: center middle; }
    ChoiceModal > Vertical { width: 50; height: auto; max-height: 80%; padding: 1 2; border: thick $accent; background: $surface; }
    ChoiceModal ListView { height: auto; max-height: 16; margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, prompt: str, choices: list[str]):
        super().__init__()
        self._prompt = prompt
        self._choices = choices

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(self._prompt)
            lv = ListView()
            yield lv

    def on_mount(self) -> None:
        lv = self.query_one(ListView)
        for c in self._choices:
            item = ListItem(Label(c))
            item.value = c  # type: ignore[attr-defined]
            lv.append(item)
        lv.focus()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        self.dismiss(getattr(event.item, "value", None))

    def action_cancel(self) -> None:
        self.dismiss(None)


class SearchPalette(ModalScreen[Optional[tuple]]):
    """Type-to-search across orgs + users. Dismisses with ("org"|"user", key)."""

    DEFAULT_CSS = """
    SearchPalette { align: center top; }
    SearchPalette > Vertical { width: 80; height: auto; max-height: 80%; margin-top: 4; border: thick $accent; background: $surface; }
    SearchPalette Input { margin: 0; }
    SearchPalette ListView { height: auto; max-height: 18; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, api):
        super().__init__()
        self._api = api

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Input(placeholder="Search orgs & users…", id="q")
            yield ListView(id="results")

    def on_mount(self) -> None:
        self.query_one("#q", Input).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._search(event.value)

    def _search(self, q: str) -> None:
        self.run_worker(self._do_search(q), exclusive=True)

    async def _do_search(self, q: str) -> None:
        lv = self.query_one("#results", ListView)
        lv.clear()
        if not q.strip():
            return
        try:
            res = await self._api.search(q)
        except Exception:  # noqa: BLE001 — palette stays usable on a failed keystroke
            return
        for o in res.get("organizations", []):
            item = ListItem(Label(f"[#cba6f7]org[/]  {o.get('name','')}  ·  {o.get('domain','')}"))
            item.ref = ("org", o.get("id"))  # type: ignore[attr-defined]
            lv.append(item)
        for u in res.get("users", []):
            item = ListItem(Label(f"[#a6e3a1]usr[/]  {u.get('username','')}  ·  {u.get('billing_email') or ''}"))
            item.ref = ("user", u.get("id"))  # type: ignore[attr-defined]
            lv.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        self.dismiss(getattr(event.item, "ref", None))

    def action_cancel(self) -> None:
        self.dismiss(None)

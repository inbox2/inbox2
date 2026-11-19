"""Modal screens: compose, pickers, event editor/detail, invite, settings,
shortcuts help, command palette."""

from __future__ import annotations

import csv
import io
import datetime as dt
import uuid
from pathlib import Path
from typing import Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Grid, Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.suggester import Suggester
from textual.widgets import Button, Checkbox, DataTable, Input, Label, ListItem, ListView, Select, Static, Switch, TextArea

from . import prefs
from .constants import (
    CAL_VIEWS,
    MARK_READ_MODE_DELAY,
    MARK_READ_MODES,
    QUADRANT_ORDER,
    QUADRANTS,
    RSVP_ACCEPTED,
    RSVP_DECLINED,
    RSVP_LABELS,
    RSVP_TENTATIVE,
    SHORTCUTS,
    SHORTCUT_GROUPS,
    SORT_LABELS,
    SORT_ORDERS,
    STATUS_OPEN,
    human_size,
)

# Dismiss values of the draft-close prompt.
CLOSE_SAVE = "save"
CLOSE_DISCARD = "discard"
CLOSE_KEEP = "keep"


class DraftCloseModal(ModalScreen[str]):
    """What to do with a non-empty draft on close: save it to Drafts, throw it
    away, or keep editing."""

    DEFAULT_CSS = """
    DraftCloseModal { align: center middle; }
    DraftCloseModal > Grid {
        grid-size: 3; grid-gutter: 1 2; padding: 1 2;
        width: 66; height: 11; border: thick $background 80%; background: $surface;
    }
    DraftCloseModal #question { column-span: 3; height: 3; content-align: center middle; }
    DraftCloseModal Button { width: 100%; }
    """

    BINDINGS = [Binding("escape", "keep", "Keep")]

    def compose(self) -> ComposeResult:
        with Grid():
            yield Label("Save this draft?", id="question")
            yield Button("Save draft", variant="primary", id=CLOSE_SAVE)
            yield Button("Discard", variant="error", id=CLOSE_DISCARD)
            yield Button("Keep editing", id=CLOSE_KEEP)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id or CLOSE_KEEP)

    def action_keep(self) -> None:
        self.dismiss(CLOSE_KEEP)


# Kept for callers/tests that only need the yes/no shape.
ConfirmDiscardModal = DraftCloseModal


class ContactSuggester(Suggester):
    """Inline completion for a recipient field: completes the segment after the
    last comma against the contacts seen in the mailbox (→ accepts)."""

    def __init__(self, contacts: list[str]) -> None:
        super().__init__(case_sensitive=False)
        self._contacts = contacts

    async def get_suggestion(self, value: str) -> str | None:
        head, _, tail = value.rpartition(",")
        needle = tail.lstrip()
        if not needle:
            return None
        for c in self._contacts:
            cl = c.lower()
            if cl.startswith(needle) or ("<" in cl and cl.split("<", 1)[1].startswith(needle)):
                # Textual completes by appending to the typed value, so the
                # suggestion must start with what's typed: for a match on the
                # email inside `Name <email>` complete to the email alone.
                completion = c if cl.startswith(needle) else c.split("<", 1)[1].rstrip(">")
                return f"{head},{tail[: len(tail) - len(needle)]}{completion}" if head else f"{tail[: len(tail) - len(needle)]}{completion}"
        return None


def _parse_attachment_list(raw: str) -> list[str]:
    return [p.strip() for p in next(csv.reader([raw], skipinitialspace=True), [])]


def format_attachment_paths(paths: list[str]) -> str:
    """The composer's attachment field: comma-separated, a path with a comma quoted."""
    out = io.StringIO()
    csv.writer(out, lineterminator="").writerow(paths)
    return out.getvalue()


class ComposeModal(ModalScreen[Optional[dict]]):
    """Full compose window for new message / reply-all / forward.

    Dismisses with an OutgoingMessage-shaped dict (plus `account_key` and
    `intent`: ``send`` or ``draft``) — or `None` on discard. Attachments are
    local file paths; the host reads them (it shares the machine), so bytes
    never ride the JSON bus.
    """

    DEFAULT_CSS = """
    ComposeModal { align: center middle; }
    ComposeModal > Vertical {
        width: 90%; height: 90%; max-width: 120; border: thick $accent; background: $surface; padding: 1 2;
    }
    ComposeModal .field { height: 3; margin-bottom: 0; }
    ComposeModal #compose-title { text-style: bold; height: 1; margin-bottom: 1; }
    ComposeModal #compose-from { height: 3; margin-bottom: 0; }
    ComposeModal #compose-body { height: 1fr; margin-top: 1; }
    ComposeModal #compose-hint { height: 1; color: $text-muted; }
    ComposeModal .field-hint { height: 1; color: $text-muted; }
    """

    BINDINGS = [
        Binding("ctrl+enter", "send", "Send", priority=True),
        Binding("ctrl+s", "send", "Send", priority=True),
        Binding("ctrl+d", "save_draft", "Save draft", priority=True),
        Binding("ctrl+g", "ai_draft", "Draft with AI", priority=True),
        Binding("escape", "close", "Close", priority=True),
    ]

    def __init__(self, draft: dict, title: str = "New message", accounts: Optional[list[dict]] = None,
                 contacts: Optional[list[str]] = None):
        super().__init__()
        self.draft = draft
        self.title_text = title
        self.accounts = accounts or []
        self._suggester = ContactSuggester(contacts) if contacts else None
        # One key for every saved version of this draft (the engine replaces the
        # provider's copy rather than adding another).
        self.draft_key = draft.get("draft_key") or f"draft_{uuid.uuid4().hex[:21]}"

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(self.title_text, id="compose-title")
            if len(self.accounts) > 1:
                options = [(a.get("email_address") or a.get("display_name") or a["key"], a["key"]) for a in self.accounts]
                current = self.draft.get("account_key")
                yield Select(options, value=current if any(v == current for _, v in options) else options[0][1],
                             allow_blank=False, id="compose-from")
            for field, label in (("to", "To"), ("cc", "Cc"), ("bcc", "Bcc")):
                yield Input(value=self.draft.get(field, ""), placeholder=label, id=f"compose-{field}", classes="field",
                            suggester=self._suggester)
            yield Input(value=self.draft.get("subject", ""), placeholder="Subject", id="compose-subject", classes="field")
            yield Input(value=self.draft.get("attachments", ""), placeholder="Attachments — file paths, comma-separated",
                        id="compose-attachments", classes="field")
            if (self.draft.get("mx_draft") or {}).get("attachments"):
                yield Label("Already attached — delete a name to remove that file", classes="field-hint")
                yield Input(value=format_attachment_paths([a["filename"] for a in self.draft["mx_draft"]["attachments"]]),
                            placeholder="No files kept", id="compose-existing", classes="field")
            yield TextArea(self.draft.get("body", ""), id="compose-body")
            yield Static("ctrl+enter send · ctrl+d save draft · escape close", id="compose-hint")

    def on_mount(self) -> None:
        focus = self.draft.get("focus", "to")
        target = {"to": "#compose-to", "body": "#compose-body"}.get(focus, "#compose-to")
        try:
            self.query_one(target).focus()
        except Exception:
            pass

    def _value(self, selector: str) -> str:
        return self.query_one(selector, Input).value.strip()

    def _account_key(self) -> str:
        try:
            return str(self.query_one("#compose-from", Select).value)
        except Exception:
            return self.draft.get("account_key") or ""

    def _is_dirty(self) -> bool:
        body = self.query_one("#compose-body", TextArea).text.strip()
        # Dirty if the user added body text beyond the prefill, or set a recipient.
        return bool(body and body != (self.draft.get("body", "") or "").strip()) or bool(self._value("#compose-to"))

    def _attachments(self) -> list[dict]:
        raw = self._value("#compose-attachments")
        out = []
        for part in _parse_attachment_list(raw):
            if not part:
                continue
            path = Path(part).expanduser()
            if not path.is_file():
                raise FileNotFoundError(part)
            out.append({"path": str(path), "filename": path.name, "mime_type": None})
        return out

    def _reconciled_mx_draft(self) -> dict:
        """The reopened draft with the files the user kept and the ones they removed.
        KeyError names an entry that isn't one of its files."""
        mx_draft = self.draft["mx_draft"]
        pool = list(mx_draft.get("attachments") or [])
        if not pool:
            return mx_draft
        kept = []
        for name in filter(None, _parse_attachment_list(self._value("#compose-existing"))):
            match = next((a for a in pool if a["filename"] == name), None)
            if match is None:
                raise KeyError(name)
            pool.remove(match)  # a name can appear twice; each entry keeps one file
            kept.append(match["key"])
        return {**mx_draft, "attachment_keys": kept, "removed_keys": [a["key"] for a in pool]}

    def _message(self, intent: str) -> Optional[dict]:
        try:
            attachments = self._attachments()
        except FileNotFoundError as e:
            self.app.notify(f"Attachment not found: {e}", severity="error")
            return None
        mx_draft = None
        if self.draft.get("mx_draft"):
            try:
                mx_draft = self._reconciled_mx_draft()
            except KeyError as e:
                self.app.notify(f"Not one of this draft's files: {e.args[0]}", severity="error")
                return None
        account_key = self._account_key()
        # The draft's own From (a reply picks the address the thread was sent to)
        # while its account is still the one chosen.
        from_address = (self.draft.get("from_address") if account_key == self.draft.get("account_key") else None) or next(
            (a.get("email_address", "") for a in self.accounts if a["key"] == account_key), self.draft.get("from_address", ""))
        return {
            "intent": intent,
            "draft_key": self.draft_key,
            "account_key": account_key,
            "from_address": from_address,
            "to_address": self._value("#compose-to"),
            "cc_address": self._value("#compose-cc") or None,
            "bcc_address": self._value("#compose-bcc") or None,
            "subject": self._value("#compose-subject"),
            "body_plain": self.query_one("#compose-body", TextArea).text,
            "body_html": None,
            "attachments": attachments,
            # Present on reply drafts: threads the reply via the engine's
            # In-Reply-To/References hydration. None for new mail / forwards.
            "reply_to_message_key": self.draft.get("reply_to_message_key"),
            "conversation_key": self.draft.get("conversation_key"),  # an inbox2 reply threads by it
            **({"mx_draft": mx_draft} if mx_draft else {}),
        }

    def action_send(self) -> None:
        message = self._message("send")
        if message is None:
            return
        if not message["to_address"]:
            self.app.notify("Add a recipient first.", severity="warning")
            self.query_one("#compose-to", Input).focus()
            return
        self.dismiss(message)

    def action_ai_draft(self) -> None:
        """The desktop's AI compose: what you typed is the instruction, the quoted
        thread is the context, and the draft replaces your instruction."""
        body = self.query_one("#compose-body", TextArea)
        instruction, tail = split_instruction(body.text)
        prompt = (f"Instruction: {instruction or 'Write a fitting reply.'}\n\nThread:\n{tail.strip()}").strip()

        async def _run() -> None:
            self.app.notify("Drafting…", timeout=2)
            try:
                text = await self.app.bus.call("generative_generate", {"system": AI_DRAFT_SYSTEM, "prompt": prompt}, timeout=120)
            except Exception as e:  # noqa: BLE001
                self.app.notify(f"AI draft: {e}", severity="warning")
                return
            body.text = f"{(text or '').strip()}\n{tail}"

        self.run_worker(_run(), group="ai", exclusive=True)

    def action_save_draft(self) -> None:
        message = self._message("draft")
        if message is not None:
            self.dismiss(message)

    def action_close(self) -> None:
        if not self._is_dirty():
            self.dismiss(None)
            return

        def _after(choice: str) -> None:
            if choice == CLOSE_SAVE:
                self.action_save_draft()
            elif choice == CLOSE_DISCARD:
                self.dismiss(None)

        self.app.push_screen(DraftCloseModal(), _after)

    # Backwards-compatible alias (older tests/callers).
    action_discard = action_close


AI_DRAFT_SYSTEM = (
    "You are an assistant that drafts email replies on behalf of the user. "
    "Write a clear, concise, professional reply in the first person. "
    "Output only the reply body — no subject line, no quoted original, no preamble or sign-off placeholders."
)  # same prompt as the desktop's AIComposePopup


def split_instruction(body: str) -> tuple[str, str]:
    """(what the person typed, the quoted/signature tail) of a compose body —
    the AI draft replaces the first and keeps the second."""
    for marker in ("\n-- \n", "\nOn ", "\n> ", "\n---------- Forwarded"):
        i = body.find(marker)
        if i != -1:
            return body[:i].strip(), body[i:]
    return body.strip(), ""


class PickerModal(ModalScreen[Optional[str]]):
    """A type-to-filter list of (key, label) choices — folders, Spaces, triage
    labels, themes, calendar views. Dismisses with the chosen key or `None`."""

    DEFAULT_CSS = """
    PickerModal { align: center top; }
    PickerModal > Vertical {
        width: 60; height: auto; max-height: 80%; margin-top: 4;
        border: thick $accent; background: $surface;
    }
    PickerModal #pk-title { text-style: bold; height: 1; padding: 0 1; margin-top: 1; }
    PickerModal Input { margin: 0; }
    PickerModal ListView { height: auto; max-height: 18; }
    """

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, title: str, items: list[tuple[str, str]], current: Optional[str] = None, placeholder: str = "Type to filter…"):
        super().__init__()
        self.title_text = title
        self.items = items
        self.current = current
        self.placeholder = placeholder

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(self.title_text, id="pk-title")
            yield Input(placeholder=self.placeholder, id="pk-input")
            yield ListView(id="pk-list")

    def on_mount(self) -> None:
        self._populate("")
        self.query_one("#pk-input", Input).focus()

    def _populate(self, query: str) -> None:
        lv = self.query_one("#pk-list", ListView)
        lv.clear()
        q = query.lower()
        for key, label in self.items:
            if q and q not in label.lower() and q not in key.lower():
                continue
            text = Text()
            text.append("● " if key == self.current else "  ", style="bold")
            text.append(label)
            item = ListItem(Label(text))
            item.pick_key = key  # type: ignore[attr-defined]
            lv.append(item)

    def on_input_changed(self, event: Input.Changed) -> None:
        self._populate(event.value)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        lv = self.query_one("#pk-list", ListView)
        target = lv.highlighted_child or (lv.children[0] if lv.children else None)
        self.dismiss(getattr(target, "pick_key", None))

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        self.dismiss(getattr(event.item, "pick_key", None))

    def on_key(self, event) -> None:
        # Arrow keys from the filter box drive the list.
        if event.key in ("down", "up") and self.app.focused is self.query_one("#pk-input"):
            lv = self.query_one("#pk-list", ListView)
            lv.focus()
            (lv.action_cursor_down if event.key == "down" else lv.action_cursor_up)()
            event.stop()

    def action_cancel(self) -> None:
        self.dismiss(None)


def _next_hour() -> dt.datetime:
    now = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    return now + dt.timedelta(hours=1)


def _iso(value: dt.datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


class EventEditorModal(ModalScreen[Optional[dict]]):
    """Create or edit a calendar event. Dismisses with an EventDraft-shaped dict
    (plus `account_key`/provider ids when editing), or `None` on cancel."""

    DEFAULT_CSS = """
    EventEditorModal { align: center middle; }
    EventEditorModal > Vertical {
        width: 76; height: auto; max-height: 95%; border: thick $accent; background: $surface; padding: 1 2;
    }
    EventEditorModal .field { height: 3; margin-bottom: 0; }
    EventEditorModal #ev-title-label { text-style: bold; height: 1; margin-bottom: 1; }
    EventEditorModal #ev-calendar { height: 3; }
    EventEditorModal #ev-flags { height: 3; }
    EventEditorModal #ev-flags Checkbox { width: 1fr; }
    EventEditorModal #ev-hint { height: 1; color: $text-muted; }
    """

    BINDINGS = [
        Binding("ctrl+s", "save", "Save", priority=True),
        Binding("escape", "cancel", "Cancel", priority=True),
    ]

    def __init__(
        self,
        event: Optional[dict],
        default_calendar: Optional[dict],
        account_key: str,
        calendars: Optional[list[dict]] = None,
        attendees: Optional[list[dict]] = None,
    ):
        super().__init__()
        self.event = event or {}
        self.default_calendar = default_calendar or {}
        self.account_key = account_key
        self.calendars = calendars or ([default_calendar] if default_calendar else [])
        self.attendees = attendees or []

    def compose(self) -> ComposeResult:
        e = self.event
        start = e.get("start_at") or _iso(_next_hour())
        end = e.get("end_at") or _iso(_next_hour() + dt.timedelta(hours=1))
        with Vertical():
            yield Label("Edit event" if e else "New event", id="ev-title-label")
            yield Input(value=e.get("title", ""), placeholder="Title", id="ev-title", classes="field")
            if not e and len(self.calendars) > 1:
                options = [(c["name"], c["provider_id"]) for c in self.calendars if c.get("provider_id")]
                yield Select(options, value=self.default_calendar.get("provider_id") or options[0][1],
                             allow_blank=False, id="ev-calendar")
            yield Input(value=start, placeholder="Start (2026-05-30T14:00:00Z)", id="ev-start", classes="field")
            yield Input(value=end, placeholder="End (2026-05-30T15:00:00Z)", id="ev-end", classes="field")
            yield Input(value=e.get("location", "") or "", placeholder="Location", id="ev-location", classes="field")
            yield Input(value=", ".join(a["email"] for a in self.attendees if not a.get("is_organizer")),
                        placeholder="Attendees — emails, comma-separated", id="ev-attendees", classes="field")
            yield Input(value=e.get("description", "") or "", placeholder="Description", id="ev-desc", classes="field")
            with Horizontal(id="ev-flags"):
                yield Checkbox("All day", value=bool(e.get("all_day")), id="ev-allday")
                if not e:
                    yield Checkbox("Add video meeting (Meet / Teams)", value=False, id="ev-conference")
            yield Static("ctrl+s save · escape cancel", id="ev-hint")

    def on_mount(self) -> None:
        self.query_one("#ev-title", Input).focus()

    def _checked(self, selector: str) -> bool:
        try:
            return bool(self.query_one(selector, Checkbox).value)
        except Exception:
            return False

    def action_save(self) -> None:
        attendees = [a.strip() for a in self.query_one("#ev-attendees", Input).value.split(",") if a.strip()]
        draft = {
            "account_key": self.account_key,
            "event": {
                "title": self.query_one("#ev-title", Input).value.strip(),
                "start_at": self.query_one("#ev-start", Input).value.strip(),
                "end_at": self.query_one("#ev-end", Input).value.strip(),
                "location": self.query_one("#ev-location", Input).value.strip() or None,
                "description": self.query_one("#ev-desc", Input).value.strip() or None,
                "all_day": self._checked("#ev-allday"),
                "attendees": attendees,
                "conference": self._checked("#ev-conference"),
            },
        }
        if not draft["event"]["title"]:
            self.app.notify("Give the event a title.", severity="warning")
            return
        if self.event:
            draft["event_provider_id"] = self.event.get("provider_id")
            draft["calendar_provider_id"] = self.event.get("calendar_provider_id")
        else:
            try:
                draft["calendar_provider_id"] = str(self.query_one("#ev-calendar", Select).value)
            except Exception:
                draft["calendar_provider_id"] = self.default_calendar.get("provider_id")
        self.dismiss(draft)

    def action_cancel(self) -> None:
        self.dismiss(None)


# Dismiss values of the event detail view.
DETAIL_EDIT = "edit"
DETAIL_DELETE = "delete"


class EventDetailModal(ModalScreen[Optional[str]]):
    """An event's full card (the desktop's EventDetailPopup): when, where, who
    and their RSVPs, the video link. Keys inside act on it: `e` edit, `d`
    delete, `y`/`Y`/`x` RSVP. Dismisses with the action or `None`."""

    DEFAULT_CSS = """
    EventDetailModal { align: center middle; }
    EventDetailModal > Vertical {
        width: 76; height: auto; max-height: 90%; border: thick $accent; background: $surface; padding: 1 2;
    }
    EventDetailModal #ed-title { text-style: bold; height: auto; margin-bottom: 1; }
    EventDetailModal #ed-body { height: auto; max-height: 24; }
    EventDetailModal #ed-hint { height: 1; color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [
        Binding("escape,q,enter", "close", "Close", priority=True),
        Binding("e", "edit", "Edit"),
        Binding("d", "delete", "Delete"),
        Binding("y", f"rsvp('{RSVP_ACCEPTED}')", "Accept"),
        Binding("Y", f"rsvp('{RSVP_TENTATIVE}')", "Tentative"),
        Binding("x", f"rsvp('{RSVP_DECLINED}')", "Decline"),
    ]

    def __init__(self, event: dict, attendees: list[dict], conference_url: Optional[str] = None):
        super().__init__()
        self.event = event
        self.attendees = attendees
        self.conference_url = conference_url

    def _card(self) -> Text:
        e = self.event
        t = Text()
        when = f"{e.get('start_at', '')[:16].replace('T', ' ')} → {e.get('end_at', '')[:16].replace('T', ' ')}"
        if e.get("all_day"):
            when = f"{e.get('start_at', '')[:10]} (all day)"
        rows = [
            ("When", when),
            ("Calendar", e.get("calendar_name") or ""),
            ("Where", e.get("location") or ""),
            ("Organizer", e.get("organizer_name") or e.get("organizer_email") or ""),
            ("Status", e.get("status") or ""),
            ("Join", self.conference_url or ""),
        ]
        for label, value in rows:
            if value:
                t.append(f"{label:>10}  ", style="bold")
                t.append(f"{value}\n")
        if self.attendees:
            t.append(f"{'Who':>10}  ", style="bold")
            marks = {"accepted": "✓", "declined": "✗", "tentative": "?", "needs_action": "·", "needsAction": "·"}
            parts = []
            for a in self.attendees:
                mark = marks.get(a.get("response_status") or "", "·")
                name = a.get("name") or a.get("email") or ""
                parts.append(f"{mark} {name}" + (" (organizer)" if a.get("is_organizer") else ""))
            t.append(", ".join(parts) + "\n")
        if e.get("description"):
            t.append("\n" + (e["description"] or "").strip())
        return t

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(Text(self.event.get("title") or "(untitled)", style="bold"), id="ed-title")
            with VerticalScroll(id="ed-body"):
                yield Static(self._card())
            yield Static("e edit · d delete · y accept · Y tentative · x decline · escape close", id="ed-hint")

    def action_close(self) -> None:
        self.dismiss(None)

    def action_edit(self) -> None:
        self.dismiss(DETAIL_EDIT)

    def action_delete(self) -> None:
        self.dismiss(DETAIL_DELETE)

    def action_rsvp(self, response: str) -> None:
        self.dismiss(f"rsvp:{response}")


class InviteModal(ModalScreen[Optional[str]]):
    """An emailed meeting invite (docs/Meeting-Invites.md): the parsed ICS +
    the choices the desktop banner offers — RSVP (for a REQUEST) and/or add it
    to your calendar. Dismisses with `rsvp:<response>`, `add`, or `None`."""

    DEFAULT_CSS = """
    InviteModal { align: center middle; }
    InviteModal > Vertical {
        width: 72; height: auto; border: thick $accent; background: $surface; padding: 1 2;
    }
    InviteModal #inv-title { text-style: bold; height: auto; margin-bottom: 1; }
    InviteModal #inv-card { height: auto; }
    InviteModal #inv-buttons { height: 3; margin-top: 1; }
    InviteModal #inv-buttons Button { margin-right: 1; }
    InviteModal #inv-hint { height: 1; color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [
        Binding("escape,q", "close", "Close", priority=True),
        Binding("y", f"rsvp('{RSVP_ACCEPTED}')", "Accept"),
        Binding("Y", f"rsvp('{RSVP_TENTATIVE}')", "Tentative"),
        Binding("x", f"rsvp('{RSVP_DECLINED}')", "Decline"),
        Binding("a", "add", "Add to calendar"),
    ]

    def __init__(self, invite: dict):
        super().__init__()
        self.invite = invite

    @property
    def is_request(self) -> bool:
        return (self.invite.get("method") or "REQUEST").upper() == "REQUEST" and bool(self.invite.get("organizer_email"))

    def compose(self) -> ComposeResult:
        i = self.invite
        card = Text()
        when = f"{(i.get('start') or '')[:16].replace('T', ' ')} → {(i.get('end') or '')[:16].replace('T', ' ')}"
        if i.get("all_day"):
            when = f"{(i.get('start') or '')[:10]} (all day)"
        for label, value in (
            ("When", when + (f"  {i['timezone']}" if i.get("timezone") else "")),
            ("Where", i.get("location") or ""),
            ("Organizer", i.get("organizer_name") or i.get("organizer_email") or ""),
            ("Your reply", i.get("current_status") or ""),
            ("Calendar", "already on your calendar" if i.get("matched_event_key") else ""),
        ):
            if value:
                card.append(f"{label:>10}  ", style="bold")
                card.append(f"{value}\n")
        with Vertical():
            yield Static(Text(f"📅 {i.get('summary') or '(untitled meeting)'}", style="bold"), id="inv-title")
            yield Static(card, id="inv-card")
            with Horizontal(id="inv-buttons"):
                if self.is_request:
                    for response in (RSVP_ACCEPTED, RSVP_TENTATIVE, RSVP_DECLINED):
                        variant = "success" if response == RSVP_ACCEPTED else "error" if response == RSVP_DECLINED else "default"
                        yield Button(RSVP_LABELS[response], variant=variant, id=f"rsvp-{response}")
                if not i.get("matched_event_key"):
                    yield Button("Add to calendar", variant="primary", id="add")
            yield Static("y accept · Y tentative · x decline · a add to calendar · escape close", id="inv-hint")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        self.dismiss("add" if bid == "add" else f"rsvp:{bid[len('rsvp-'):]}")

    def action_rsvp(self, response: str) -> None:
        if self.is_request:
            self.dismiss(f"rsvp:{response}")

    def action_add(self) -> None:
        self.dismiss("add")

    def action_close(self) -> None:
        self.dismiss(None)


class AttachmentsModal(ModalScreen[Optional[dict]]):
    """The attachments view for the open conversation. Lists every attachment in
    the thread; dismisses with the chosen attachment dict (to save) or `None`."""

    DEFAULT_CSS = """
    AttachmentsModal { align: center middle; }
    AttachmentsModal > Vertical {
        width: 76; height: auto; max-height: 80%; border: thick $accent; background: $surface; padding: 1 2;
    }
    AttachmentsModal #att-title { text-style: bold; height: 1; margin-bottom: 1; }
    AttachmentsModal DataTable { height: auto; max-height: 18; }
    AttachmentsModal #att-hint { height: 1; color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [
        Binding("enter,s", "save", "Save", priority=True),
        Binding("escape,q", "close", "Close", priority=True),
    ]

    def __init__(self, attachments: list[dict]):
        super().__init__()
        self.attachments = attachments

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(f"📎 Attachments ({len(self.attachments)})", id="att-title")
            table = DataTable(cursor_type="row", id="att-table")
            table.add_columns("Name", "Size", "Type")
            yield table
            yield Static("enter / s save to ~/Downloads · escape close", id="att-hint")

    def on_mount(self) -> None:
        table = self.query_one("#att-table", DataTable)
        for a in self.attachments:
            table.add_row(
                a.get("filename") or "attachment",
                human_size(a.get("size")),
                a.get("mime_type") or "",
            )
        table.focus()

    def _selected(self) -> Optional[dict]:
        table = self.query_one("#att-table", DataTable)
        idx = table.cursor_row
        if idx is None or not (0 <= idx < len(self.attachments)):
            return None
        return self.attachments[idx]

    def action_save(self) -> None:
        self.dismiss(self._selected())

    def action_close(self) -> None:
        self.dismiss(None)


class ActionsMenuModal(ModalScreen[Optional[str]]):
    """The conversation actions menu — the TUI equivalent of the desktop's
    right-click / ellipsis menu. Same action order as conversationActions.js.
    Dismisses with the chosen action id (e.g. 'archive', 'triage_DO_FIRST')."""

    DEFAULT_CSS = """
    ActionsMenuModal { align: center middle; }
    ActionsMenuModal > Vertical {
        width: 48; height: auto; max-height: 90%; border: thick $accent; background: $surface;
    }
    ActionsMenuModal #am-title { text-style: bold; height: 1; padding: 0 1; margin: 1 0; }
    ActionsMenuModal ListView { height: auto; max-height: 26; }
    ActionsMenuModal .am-sep { color: $text-muted; height: 1; padding: 0 1; }
    """

    BINDINGS = [Binding("escape,q", "cancel", "Cancel")]

    def __init__(self, conv: dict, selected: int = 0, has_invite: bool = False):
        super().__init__()
        self.conv = conv
        self.selected = selected
        self.has_invite = has_invite

    def _items(self) -> list[tuple[str, str]]:
        read = self.conv.get("read")
        n = self.selected
        items = [
            ("reply", "Reply  [r]"),
            ("reply_all", "Reply All  [a]"),
            ("forward", "Forward  [f]"),
            ("__sep__", "──────────"),
            ("view_source", "View Source  [ctrl+u]"),
        ]
        if self.has_invite:
            items.append(("invite", "Meeting invite…"))
        items += [
            ("__sep__", f"── {n} selected ──" if n > 1 else "──────────"),
        ]
        if self.conv.get("status") != STATUS_OPEN:
            items.append(("move_inbox", "Move to Inbox"))
        items += [
            ("mark", "Mark as Read  [I]" if not read else "Mark as Unread  [U]"),
            ("archive", "Archive  [e]"),
            ("spam", "Spam  [!]"),
            ("trash", "Delete  [del]"),
            ("move", "Move to folder…  [v]"),
            ("__sep__", "── Triage ──"),
        ]
        for key in QUADRANT_ORDER:
            q = QUADRANTS[key]
            items.append((f"triage_{key}", f"{q['mark']}  {q['label']}"))
        items.append(("triage_clear", "✕  Untag  [alt+x]"))
        items += [
            ("__sep__", "── Jev ──"),
            ("space", "Move to Space…  [alt+m]"),
            ("label", "Triage label…  [alt+t]"),
            ("retriage", "Re-run Jev  [alt+j]"),
        ]
        return items

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Actions", id="am-title")
            lv = ListView(id="am-list")
            yield lv

    def on_mount(self) -> None:
        lv = self.query_one("#am-list", ListView)
        for action_id, label in self._items():
            # markup=False: bracketed hints like "[r]"/"[I]" are literal text, not
            # Rich console tags (otherwise single-letter ones get parsed away).
            if action_id == "__sep__":
                item = ListItem(Label(label, markup=False))
                item.add_class("am-sep")
                item.disabled = True
            else:
                item = ListItem(Label(label, markup=False))
                item.action_id = action_id  # type: ignore[attr-defined]
            lv.append(item)
        lv.focus()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        action_id = getattr(event.item, "action_id", None)
        if action_id:
            self.dismiss(action_id)

    def action_cancel(self) -> None:
        self.dismiss(None)


class SourceModal(ModalScreen[None]):
    """Read-only raw message source (RFC 822), fetched via get_message_source."""

    DEFAULT_CSS = """
    SourceModal { align: center middle; }
    SourceModal > Vertical {
        width: 90%; height: 90%; max-width: 140; border: thick $accent; background: $surface; padding: 1 2;
    }
    SourceModal #src-title { text-style: bold; height: 1; margin-bottom: 1; }
    SourceModal TextArea { height: 1fr; }
    SourceModal #src-hint { height: 1; color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [Binding("escape,q", "close", "Close", priority=True)]

    def __init__(self, raw: str):
        super().__init__()
        self.raw = raw

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Message source", id="src-title")
            ta = TextArea(self.raw, read_only=True, id="src-text")
            yield ta
            yield Static("escape close", id="src-hint")

    def on_mount(self) -> None:
        self.query_one("#src-text", TextArea).focus()

    def action_close(self) -> None:
        self.dismiss(None)


class SettingsModal(ModalScreen[None]):
    """Settings: connected accounts, and the client preferences the desktop
    keeps in localStorage — theme, mark-as-read, sort, notifications, signature.
    Changes apply immediately and persist to cli_prefs.json."""

    DEFAULT_CSS = """
    SettingsModal { align: center middle; }
    SettingsModal > Vertical {
        width: 84; height: auto; max-height: 95%; border: thick $accent; background: $surface; padding: 1 2;
    }
    SettingsModal #set-title { text-style: bold; height: 1; margin-bottom: 1; }
    SettingsModal .set-label { color: $text-muted; height: 1; margin-top: 1; }
    SettingsModal DataTable { height: auto; max-height: 8; }
    SettingsModal .set-row { height: 3; }
    SettingsModal .set-row Label { width: 18; height: 3; content-align: left middle; }
    SettingsModal .set-row Select { width: 1fr; }
    SettingsModal .set-row Input { width: 12; }
    SettingsModal #set-signature { height: 5; }
    SettingsModal #set-hint { height: 1; color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [Binding("escape,q", "close", "Close", priority=True),
                Binding("ctrl+g", "intelligence", "Intelligence", priority=True)]

    def __init__(self, accounts: list[dict], theme: str, data_file=None, themes: Optional[list[str]] = None):
        super().__init__()
        self.accounts = accounts
        self.theme_name = theme
        self.data_file = data_file
        self.themes = themes or [theme]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Settings", id="set-title")
            yield Label("Connected accounts", classes="set-label")
            table = DataTable(cursor_type="row", id="set-accounts")
            table.add_columns("Email", "Provider", "Status")
            yield table
            with Horizontal(classes="set-row"):
                yield Label("Theme")
                yield Select([(t, t) for t in self.themes], value=self.theme_name, allow_blank=False, id="set-theme")
            with Horizontal(classes="set-row"):
                yield Label("Mark as read")
                yield Select([(m, m) for m in MARK_READ_MODES], value=prefs.mark_read_mode(), allow_blank=False, id="set-markread")
                yield Input(value=f"{prefs.mark_read_delay():g}", placeholder="secs", id="set-delay", type="number")
            with Horizontal(classes="set-row"):
                yield Label("Sort")
                yield Select([(SORT_LABELS[s], s) for s in SORT_ORDERS], value=prefs.sort_order(), allow_blank=False, id="set-sort")
            with Horizontal(classes="set-row"):
                yield Label("Notifications")
                yield Switch(value=prefs.notifications(), id="set-notify")
            yield Label("Signature (added to new messages and replies)", classes="set-label")
            yield TextArea(prefs.signature(), id="set-signature")
            yield Static(f"Data: {self.data_file or '—'}", classes="set-label")
            yield Static("changes save as you make them · ctrl+g intelligence (AI keys, triage, apps) · escape close", id="set-hint")

    def on_mount(self) -> None:
        table = self.query_one("#set-accounts", DataTable)
        for a in self.accounts:
            table.add_row(
                a.get("email_address") or a.get("display_name") or a.get("key", ""),
                a.get("provider_type") or "",
                a.get("status") or "",
            )

    def on_select_changed(self, event: Select.Changed) -> None:
        value = event.value
        if event.select.id == "set-theme" and isinstance(value, str):
            self.app.set_theme(value)  # type: ignore[attr-defined]
        elif event.select.id == "set-markread" and isinstance(value, str):
            prefs.set("mark_read_mode", value)
        elif event.select.id == "set-sort" and isinstance(value, str):
            prefs.set("sort", value)
            self.app.refresh_active(force=True)  # type: ignore[attr-defined]

    def on_switch_changed(self, event: Switch.Changed) -> None:
        if event.switch.id == "set-notify":
            prefs.set("notifications", bool(event.value))

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "set-delay":
            try:
                n = float(event.value)
            except ValueError:
                return
            if n > 0:
                prefs.set("mark_read_delay", n)

    def on_text_area_changed(self, event: TextArea.Changed) -> None:
        if event.text_area.id == "set-signature":
            prefs.set("signature", event.text_area.text.strip())

    @staticmethod
    def _mark_read_summary() -> str:
        mode = prefs.mark_read_mode()
        if mode == MARK_READ_MODE_DELAY:
            return f"{mode} ({prefs.mark_read_delay():g}s)"
        return mode

    def action_intelligence(self) -> None:
        from .intelligence import IntelligenceModal

        self.app.push_screen(IntelligenceModal())

    def action_close(self) -> None:
        self.dismiss(None)


class ShortcutsModal(ModalScreen[None]):
    """The `?` help overlay, generated from the keymap registry."""

    DEFAULT_CSS = """
    ShortcutsModal { align: center middle; }
    ShortcutsModal > Vertical {
        width: 80; height: 90%; border: thick $accent; background: $surface; padding: 1 2;
    }
    ShortcutsModal #sc-title { text-style: bold; height: 1; margin-bottom: 1; }
    ShortcutsModal DataTable { height: 1fr; }
    """

    BINDINGS = [Binding("escape,q,question_mark", "close", "Close")]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Keyboard shortcuts", id="sc-title")
            table = DataTable(cursor_type="row", id="sc-table")
            table.add_columns("Key", "Action", "Group")
            yield table

    def on_mount(self) -> None:
        table = self.query_one("#sc-table", DataTable)
        by_group: dict[str, list] = {g: [] for g in SHORTCUT_GROUPS}
        for keys, label, group in SHORTCUTS:
            by_group.setdefault(group, []).append((keys, label))
        for group in SHORTCUT_GROUPS:
            for keys, label in by_group.get(group, []):
                table.add_row(keys, label, group)

    def action_close(self) -> None:
        self.dismiss(None)


class CommandPaletteModal(ModalScreen[Optional[str]]):
    """Command palette (ctrl+k). Returns a command id."""

    DEFAULT_CSS = """
    CommandPaletteModal { align: center top; }
    CommandPaletteModal > Vertical {
        width: 70; height: auto; max-height: 80%; margin-top: 4;
        border: thick $accent; background: $surface;
    }
    CommandPaletteModal Input { margin: 0; }
    CommandPaletteModal ListView { height: auto; max-height: 16; }
    """

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    COMMANDS = [
        ("compose", "Compose new message"),
        ("unified", "Go to Unified inbox"),
        ("calendar", "Go to Calendar"),
        ("mail", "Go to Mail"),
        ("lore", "Go to Lore (open work · people · orgs)"),
        ("rules", "Go to Rules (local rules · agent runs)"),
        ("whatsapp", "Go to WhatsApp"),
        ("accounts", "Accounts (add · remove · resync · diagnostics)"),
        ("intelligence", "Intelligence (AI keys · triage window · Lore auto · connected apps · about)"),
        ("search", "Search mail"),
        ("unread", "Toggle unread only"),
        ("sort", "Cycle sort order"),
        ("outbox", "Show Outbox"),
        ("move", "Move conversation to folder…"),
        ("space", "Move conversation to Space…"),
        ("label", "Set triage label…"),
        ("retriage", "Re-run Jev on conversation"),
        ("theme", "Change theme…"),
        ("sync", "Sync (resync all channels)"),
        ("settings", "Settings"),
        ("refresh", "Refresh"),
        ("shortcuts", "Keyboard shortcuts"),
        ("quit", "Quit"),
    ] + [(f"cal_{v}", f"Calendar: {v} view") for v in CAL_VIEWS]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Input(placeholder="Type a command…", id="palette-input")
            lv = ListView(id="palette-list")
            yield lv

    def on_mount(self) -> None:
        self._populate("")
        self.query_one("#palette-input", Input).focus()

    def _populate(self, query: str) -> None:
        lv = self.query_one("#palette-list", ListView)
        lv.clear()
        q = query.lower()
        for cmd_id, label in self.COMMANDS:
            if q in label.lower() or q in cmd_id:
                item = ListItem(Label(label))
                item.command_id = cmd_id  # type: ignore[attr-defined]
                lv.append(item)

    def on_input_changed(self, event: Input.Changed) -> None:
        self._populate(event.value)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        lv = self.query_one("#palette-list", ListView)
        if lv.children:
            first = lv.children[0]
            self.dismiss(getattr(first, "command_id", None))

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        self.dismiss(getattr(event.item, "command_id", None))

    def action_cancel(self) -> None:
        self.dismiss(None)

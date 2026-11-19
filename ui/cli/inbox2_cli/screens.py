"""Mail and Calendar screens for the Inbox2 TUI."""

from __future__ import annotations

import datetime as dt
import webbrowser
from typing import Optional

from pathlib import Path

from rich.markdown import Markdown as RichMarkdown
from rich.text import Text
from rich.theme import Theme
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.color import Color
from textual.geometry import Region
from textual.message import Message
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Input, Label, ListItem, ListView, Static

from . import drafts
from .modals import format_attachment_paths
from .bodyrender import render_body
from .collapse import split_message
from .htmltext import message_markdown, message_text
from . import prefs
from .constants import (
    ACTION_ARCHIVE,
    ACTION_MARK_READ,
    ACTION_MARK_UNREAD,
    ACTION_SPAM,
    ACTION_TRASH,
    ACTION_UNARCHIVE,
    CAL_AGENDA,
    CAL_DAY,
    CAL_MONTH,
    CAL_VIEWS,
    CAL_WEEK,
    CAL_WORKWEEK,
    MARK_READ_MODE_DELAY,
    MARK_READ_MODE_IMMEDIATE,
    MARK_READ_MODE_NEVER,
    MARK_READ_MODE_SELECTION_CHANGE,
    FOLDERS,
    LOGO_ASCII,
    OUTBOX_FAILED,
    OUTBOX_KIND_DRAFT,
    QUADRANT_ORDER,
    QUADRANTS,
    RSVP_ACCEPTED,
    RSVP_DECLINED,
    RSVP_TENTATIVE,
    SORT_LABELS,
    SORT_OLDEST,
    SORT_ORDERS,
    SORT_UNREAD_FIRST,
    STATUS_OPEN,
    TRIAGE_LABELS,
    TRIAGE_PRIORITY_HIGH,
    TRIAGE_PRIORITY_URGENT,
    VIEW_DRAFTS,
    VIEW_LABEL_PREFIX,
    VIEW_OUTBOX,
    VIEW_SENT,
    VIEW_SPACE_PREFIX,
    VIEW_TLABEL_PREFIX,
    VIEW_TRIAGE_PREFIX,
    human_size,
    quadrant_for,
)


def _short(addr: str | None, n: int = 28) -> str:
    addr = addr or ""
    return addr if len(addr) <= n else addr[: n - 1] + "…"


def _body_empty(m: dict) -> bool:
    """True when a message has no locally-stored body. Microsoft bodies are
    fetched lazily (the Graph delta `$select` omits the body, see
    docs/Channels.md), so freshly-synced MS messages land here until hydrated."""
    return not (m.get("body_plain") or "").strip() and not (m.get("body_html") or "").strip()


def _rel_date(stamp: str | None, now: dt.datetime | None = None) -> str:
    """Mail-client date: time today, weekday this week, `12 Sep` this year,
    else the year. Always ≤ 6 cells so the column stays narrow."""
    if not stamp:
        return ""
    try:
        when = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return stamp[:10]
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    now = now or dt.datetime.now(dt.timezone.utc)
    local = when.astimezone()
    today = now.astimezone().date()
    if local.date() == today:
        return local.strftime("%H:%M")
    if (today - local.date()).days < 7:
        return local.strftime("%a")
    if local.year == today.year:
        return local.strftime("%-d %b")
    return local.strftime("%Y")


def _local_stamp(stamp: Optional[str]) -> str:
    """A full date and time in the local zone, the zone the list's dates are in."""
    try:
        when = dt.datetime.fromisoformat((stamp or "").replace("Z", "+00:00"))
    except ValueError:
        return (stamp or "")[:16].replace("T", " ")
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    return when.astimezone().strftime("%Y-%m-%d %H:%M")


def _is_ics(att: dict) -> bool:
    mime = (att.get("mime_type") or "").lower()
    name = (att.get("filename") or "").lower()
    return mime.startswith("text/calendar") or name.endswith(".ics")


# Per-sender avatar: two-cell initials chip with a deterministic two-stop
# gradient fill — the terminal echo of the desktop's gradient-ring avatar. Two
# cells wide ≈ square at a terminal's ~1:2 cell aspect. Gradient pairs are walked
# along the Catppuccin accent wheel so neighbouring senders read as distinct hues.
_AVATAR_GRADIENTS = [
    ("#f38ba8", "#fab387"),  # red → peach
    ("#fab387", "#f9e2af"),  # peach → yellow
    ("#a6e3a1", "#94e2d5"),  # green → teal
    ("#89dceb", "#74c7ec"),  # sky → sapphire
    ("#89b4fa", "#b4befe"),  # blue → lavender
    ("#cba6f7", "#f5c2e7"),  # mauve → pink
    ("#f5c2e7", "#f38ba8"),  # pink → red
    ("#94e2d5", "#89b4fa"),  # teal → blue
]
# Crust / pure-white text, picked per cell for contrast against the gradient.
_AVATAR_DARK = "#11111b"
_AVATAR_LIGHT = "#ffffff"


def _display_name(addr: str | None) -> str:
    """Pull a human name out of a From value, which may be `"Name" <email>`,
    `Name <email>`, or a bare address. Falls back to the local-part."""
    addr = (addr or "").strip()
    if not addr:
        return ""
    if "<" in addr:
        name = addr.split("<", 1)[0].strip().strip('"').strip()
        if name:
            return name
        addr = addr.split("<", 1)[1].split(">", 1)[0]
    return addr.split("@", 1)[0]


def _initials(addr: str | None) -> str:
    """Two-character initials for the avatar — first letters of the first two
    name words, or two letters from a single-word name / email local-part."""
    name = _display_name(addr)
    words = [w for w in name.replace(".", " ").replace("_", " ").split() if w]
    if not words:
        return "??"
    if len(words) == 1:
        w = words[0]
        return (w[0] + (w[1] if len(w) > 1 else "")).upper()
    return (words[0][0] + words[1][0]).upper()


def _contrast(hex_color: str) -> str:
    """Dark or light foreground for legibility against a given fill colour."""
    r, g, b = (int(hex_color[i : i + 2], 16) for i in (1, 3, 5))
    # Rec. 601 luma; >150 is a light fill, so use dark ink.
    return _AVATAR_DARK if (0.299 * r + 0.587 * g + 0.114 * b) > 150 else _AVATAR_LIGHT


def _avatar(addr: str | None) -> Text:
    """A two-cell initials chip with a deterministic gradient fill. Returns just
    the chip; callers add their own trailing space."""
    a, b = _AVATAR_GRADIENTS[sum(map(ord, _display_name(addr))) % len(_AVATAR_GRADIENTS)]
    c0, c1 = _initials(addr).ljust(2)[:2]
    t = Text()
    t.append(c0, style=f"bold {_contrast(a)} on {a}")
    t.append(c1, style=f"bold {_contrast(b)} on {b}")
    return t


# Compact brand mark for the top-left of the channel bar. The filled hexagon is
# the isometric cube's silhouette (the desktop app's logo); the accented "2"
# echoes the logo's "2".
_BRAND_MAUVE = "#cba6f7"
_BRAND_TEXT = "#cdd6f4"
_SUBTEXT = "#a6adc8"


# Theme-aware ink for Rich Text we build by hand (the CSS side already uses
# $variables). Falls back to the Mocha constants before the app has a theme.
def _tv(app, name: str, fallback: str) -> str:
    try:
        value = app.theme_variables.get(name)
    except Exception:
        value = None
    return value if value and value.startswith("#") else fallback


def _fg(app) -> str:
    return _tv(app, "foreground", _BRAND_TEXT)


def _accent(app) -> str:
    return _tv(app, "accent", _BRAND_MAUVE)


def _muted(app) -> str:
    """Textual's text-muted is `auto 60%`, which Rich can't take — blend it."""
    try:
        return Color.parse(_fg(app)).blend(Color.parse(_tv(app, "background", "#1e1e2e")), 0.4).hex
    except Exception:
        return _SUBTEXT


_WARN = "#f9e2af"
_ERROR = "#f38ba8"
# Single-width attachment marker shown in the list gutter (next to the unread dot).
_ATTACH_MARK = "‡"
# List columns: gutter (4) + sender · subject + Jev chip · date, sized to fit the
# 68-cell list pane (3 cells of DataTable cell padding per column).
_FROM_W, _SUBJECT_W, _DATE_W = 24, 32, 6
_SELECT_MARK = "✓"
_NBSP = "\u00a0"


def _compose_label() -> Text:
    """The Compose button label, surfacing its global `c` shortcut as a hint."""
    t = Text()
    t.append("✎ Compose ", style="bold")
    t.append("c")
    return t


def brand_text(app=None) -> Text:
    t = Text()
    t.append("⬢", style=f"bold {_accent(app)}")
    t.append(" inbox", style=f"bold {_fg(app)}")
    t.append("2", style=f"bold {_accent(app)}")
    return t


def triage_chip(label_slug: str | None, priority: float | None, names: dict[str, str] | None = None, app=None) -> Text:
    """The Jev triage chip for a list row / thread title: `!!` urgent · `!` high,
    then the label name (docs/Triage.md). Empty when there's nothing to show."""
    t = Text()
    if priority is not None:
        try:
            p = float(priority)
        except (TypeError, ValueError):
            p = 0.0
        if p >= TRIAGE_PRIORITY_URGENT:
            t.append("!! ", style=f"bold {_ERROR}")
        elif p >= TRIAGE_PRIORITY_HIGH:
            t.append("! ", style=f"bold {_WARN}")
    if label_slug:
        name = (names or TRIAGE_LABELS).get(label_slug) or TRIAGE_LABELS.get(label_slug) or label_slug
        t.append(f"[{name}]", style=f"italic {_muted(app)}")
    return t


# Rich bakes the "markdown.block_quote" style (default: magenta) into quoted text
# at parse time, so it must be overridden as a NAMED style, not at render time.
# Mute quoted/forwarded text to a soft blue-gray (Catppuccin subtext) and tint
# headings blue instead of magenta.
_MD_THEME = Theme(
    {
        "markdown.block_quote": "italic #a6adc8",
        "markdown.h1": "bold #89b4fa",
        "markdown.h2": "bold #89b4fa",
        "markdown.h3": "bold #89b4fa",
        "markdown.h4": "bold #89b4fa",
    },
    inherit=True,
)


class ThemedMarkdown:
    """Renders Rich Markdown under `_MD_THEME` so quoted text is muted blue-gray
    (not Rich's default magenta) — applied at render time via the console's
    theme stack so the parse-time style resolution picks it up."""

    def __init__(self, markup: str) -> None:
        self._markup = markup

    def __rich_console__(self, console, options):
        with console.use_theme(_MD_THEME):
            yield RichMarkdown(self._markup)


def logo_renderable(size: int = 32):
    """Render the inbox2 logo. Prefers a real raster image (rich-pixels renders
    a PNG as half-block truecolor cells — works in any modern terminal); falls
    back to the ASCII cube when the library or asset is unavailable.

    For full-resolution images, a terminal with the Kitty/iTerm/Sixel graphics
    protocol plus the `textual-image` package can be dropped in here later.
    """
    try:
        from rich_pixels import Pixels

        logo = Path(__file__).parent / "assets" / "logo.png"
        if logo.exists():
            return Pixels.from_image_path(str(logo), resize=(size, size))
    except Exception:
        pass
    return LOGO_ASCII


class LoginScreen(Screen):
    """Shown when no account is connected: branding + "log in from desktop"."""

    DEFAULT_CSS = """
    LoginScreen { align: center middle; }
    LoginScreen > Vertical { width: auto; height: auto; align: center middle; }
    LoginScreen #logo { width: auto; height: auto; content-align: center middle; }
    LoginScreen #wordmark { text-style: bold; color: $accent; margin-top: 1; }
    LoginScreen #message { color: $text; margin-top: 1; width: 56; text-align: center; }
    LoginScreen #status { color: $text-muted; margin-top: 1; }
    """

    BINDINGS = [
        Binding("l", "sign_in", "Sign in"),
        Binding("r", "recheck", "Recheck"),
        Binding("q,escape", "quit_app", "Quit"),
    ]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Static(logo_renderable(), id="logo")
            yield Static("inbox2", id="wordmark")
            yield Static(
                "Not connected.\n\nPress l to sign in to inbox2 in your browser, or "
                "connect an account in the desktop app and restart.",
                id="message",
            )
            yield Static("l sign in · r recheck · q quit", id="status")

    def action_sign_in(self) -> None:
        self.run_worker(self._sign_in(), name="signin", exclusive=True)

    async def _sign_in(self) -> None:
        from . import signin

        status = self.query_one("#status", Static)
        status.update("Waiting for approval in your browser…")
        try:
            await signin.sign_in(Path(self.app.db_file).parent, lambda url: None)
        except Exception as e:  # noqa: BLE001
            status.update(f"Sign-in failed: {e}")
            return
        status.update("✓ Signed in — restart inbox2 to open your mail.")

    def action_recheck(self) -> None:
        count = self.app.account_count()
        if count > 0:
            self.query_one("#status", Static).update(
                f"✓ {count} account(s) connected — restart inbox2 to open your mail."
            )
        else:
            self.query_one("#status", Static).update("Still not connected · r recheck · q quit")

    def action_quit_app(self) -> None:
        self.app.exit()


class ChannelTab(Static):
    """A clickable channel selector in the channel bar (F1 = unified, F2.. = account N)."""

    class Selected(Message):
        def __init__(self, index: int) -> None:
            self.index = index
            super().__init__()

    def __init__(self, label, index: int) -> None:
        super().__init__(label, id=f"chan{index}")
        self.index = index
        self.add_class("chan-tab")

    def on_click(self) -> None:
        self.post_message(self.Selected(self.index))


class BarButton(Static):
    """A compact icon button in the top bar (Settings · Sync)."""

    class Clicked(Message):
        def __init__(self, action: str) -> None:
            self.action = action
            super().__init__()

    def __init__(self, label, action: str, **kwargs) -> None:
        super().__init__(label, **kwargs)
        self._action = action
        self.add_class("bar-btn")

    def on_click(self) -> None:
        self.post_message(self.Clicked(self._action))


class ToolbarButton(BarButton):
    """A focusable button in the conversation action toolbar. Arrow keys move
    along the row (left/right, handled by the screen's pane navigation so they
    win over the screen's priority left/right bindings); up/down step out of the
    toolbar (into the thread below); enter/space activates."""

    can_focus = True
    BINDINGS = [
        Binding("down,j", "into_thread", "Into thread", show=False),
        Binding("up,k", "noop", show=False),
        Binding("enter,space", "activate", "Activate", show=False),
    ]

    def action_activate(self) -> None:
        self.post_message(self.Clicked(self._action))

    def action_into_thread(self) -> None:
        if isinstance(self.screen, MailScreen):
            self.screen.focus_first_thread_item()

    def action_noop(self) -> None:
        pass


_ARROW_OPEN = "▾"
_ARROW_CLOSED = "▸"


# Shared on each thread widget (Textual only merges BINDINGS from DOMNode
# subclasses, so a plain mixin's BINDINGS are ignored — spread these in instead).
_NAV_BINDINGS = [
    Binding("down,j", "nav(1)", "Next", show=False),
    Binding("up,k", "nav(-1)", "Prev", show=False),
]


class ThreadItem:
    """Mixin for focusable thread widgets: up/down (and j/k) move focus across
    the thread's items, handled by the focused widget so the key is consumed
    before the scroll container sees it (Textual merges scroll bindings down the
    MRO, so they can't simply be cleared on the container). Action methods
    resolve via normal Python MRO even though the mixin isn't a DOMNode."""

    def action_nav(self, delta: int) -> None:
        screen = self.screen
        if isinstance(screen, MailScreen):
            screen.thread_focus(delta)


class SectionToggle(ThreadItem, Vertical):
    """A focusable, independently collapsible signature / quoted-text section
    (the keyboard-navigable equivalent of the web's QuotedText toggles)."""

    can_focus = True
    BINDINGS = [*_NAV_BINDINGS, Binding("enter,space", "toggle", "Toggle")]

    def __init__(self, label: str, body_markup: str) -> None:
        super().__init__()
        self._label = label
        self._body_markup = body_markup
        self.is_open = False

    def compose(self) -> ComposeResult:
        yield Static(self._title(), classes="st-title")
        yield Static(ThemedMarkdown(self._body_markup), classes="st-body collapsed-body")

    def on_mount(self) -> None:
        self.set_class(not self.is_open, "-closed")

    def action_toggle(self) -> None:
        self.is_open = not self.is_open
        self.set_class(not self.is_open, "-closed")
        self.query_one(".st-title", Static).update(self._title())

    def _title(self) -> Text:
        arrow = _ARROW_OPEN if self.is_open else _ARROW_CLOSED
        return Text(f"{arrow} ··· {self._label}", style=_muted(self.app))


class MessageBody(ThreadItem, Static):
    """A message body with inline, keyboard-navigable hyperlinks. Focusable only
    when the body contains links. Up/down step the highlight between links in
    place (scrolling each into view) and, at the first/last link, hand focus to
    the previous/next thread item; enter/space opens the highlighted link."""

    BINDINGS = [
        Binding("down,j", "step(1)", "Next", show=False),
        Binding("up,k", "step(-1)", "Prev", show=False),
        Binding("enter,space", "open", "Open link"),
    ]

    def __init__(self, body_md: str) -> None:
        self._text, self._links = render_body(body_md or "_(no text body)_")
        self.active = 0
        self._enter_dir = 1  # set by thread_focus so we land on the near edge
        super().__init__(self._text, classes="msg-body")
        self.can_focus = bool(self._links)  # only bodies with links are focus stops

    def _apply(self, focused: bool) -> None:
        if self._links and focused:
            highlighted = self._text.copy()
            start, end, _ = self._links[self.active]
            highlighted.stylize("reverse", start, end)
            self.update(highlighted)
        else:
            self.update(self._text)

    def _scroll_active_into_view(self) -> None:
        if not self._links:
            return
        row = self._text.plain[: self._links[self.active][0]].count("\n")
        try:
            self.scroll_to_region(Region(0, row, max(self.size.width, 1), 1), animate=False)
        except Exception:
            pass

    def on_focus(self) -> None:
        # Entering downward → first link (top); upward → last link (bottom).
        self.active = 0 if self._enter_dir >= 0 else len(self._links) - 1
        self._apply(True)
        self._scroll_active_into_view()

    def on_blur(self) -> None:
        self._apply(False)

    def action_step(self, delta: int) -> None:
        target = self.active + delta
        if self._links and 0 <= target < len(self._links):
            self.active = target
            self._apply(True)
            self._scroll_active_into_view()
        elif isinstance(self.screen, MailScreen):  # past first/last link → leave body
            self.screen.thread_focus(delta)

    def action_open(self) -> None:
        if not self._links:
            return
        url = self._links[self.active][2]
        try:
            webbrowser.open(url)
            self.app.notify(f"Opening {url}")
        except Exception as e:  # noqa: BLE001
            self.app.notify(f"Couldn't open link: {e}", severity="error")


def _addr(raw: Optional[str]) -> str:
    """The bare lowercase address of `"Name" <a@x>`."""
    from email.utils import parseaddr

    return parseaddr(raw or "")[1].lower()


class MessageCard(ThreadItem, Vertical):
    """A thread message rendered as a Gmail-style card: a header that is always
    shown plus a body that collapses. Mirrors the desktop MessageCard, including
    "all collapsed except the last" defaults and keyboard expand/collapse."""

    can_focus = True
    BINDINGS = [*_NAV_BINDINGS, Binding("enter,space", "toggle", "Expand/collapse")]

    def __init__(self, message: dict, collapsed: bool) -> None:
        super().__init__()
        self.message = message
        self.is_collapsed = collapsed
        self.seg = split_message(message_markdown(message))

    def compose(self) -> ComposeResult:
        yield Static(self._header(), classes="mc-header")
        with Vertical(classes="mc-body"):
            yield from self._body_children()

    def _body_children(self) -> list:
        children: list = []
        details = self._details()
        if details is not None:
            children.append(Static(details, classes="mc-details"))
        # MessageBody renders the body with inline, navigable hyperlinks.
        children.append(MessageBody(self.seg.body))
        if self.seg.has_signature:
            children.append(SectionToggle("signature", self.seg.signature))
        if self.seg.has_quote:
            children.append(SectionToggle("quoted text", self.seg.quoted))
        return children

    def _details(self) -> Optional[Text]:
        """Recipient details (To / Cc) shown under the header when expanded — the
        terminal equivalent of the desktop's MessageDetails. (Bcc isn't synced to
        the local store, so it can't be shown.)"""
        m = self.message
        rows = [(lbl, m.get(field)) for lbl, field in (("To", "to_address"), ("Cc", "cc_address"))]
        rows = [(lbl, val) for lbl, val in rows if val]
        if not rows:
            return None
        t = Text()
        for i, (lbl, val) in enumerate(rows):
            if i:
                t.append("\n")
            t.append(f"{lbl}: ", style=f"bold {_muted(self.app)}")
            t.append(val, style=_muted(self.app))
        return t

    def on_mount(self) -> None:
        self.set_class(self.is_collapsed, "-collapsed")

    def action_toggle(self) -> None:
        self.is_collapsed = not self.is_collapsed
        self.set_class(self.is_collapsed, "-collapsed")
        self.query_one(".mc-header", Static).update(self._header())

    def rehydrate(self, message: dict) -> None:
        """Re-render the card after its body was lazily fetched (Microsoft).
        Recomputes the collapse segments and rebuilds the body container in
        place so the header snippet and body reflect the now-present text."""
        self.message = message
        self.seg = split_message(message_markdown(message))
        self.query_one(".mc-header", Static).update(self._header())
        body = self.query_one(".mc-body", Vertical)
        body.remove_children()
        body.mount(*self._body_children())

    def _header(self) -> Text:
        m = self.message
        frm = m.get("from_address") or ""
        date = _local_stamp(m.get("created_at"))
        t = Text()
        t.append(f"{_ARROW_CLOSED if self.is_collapsed else _ARROW_OPEN} ", style=_muted(self.app))
        t.append_text(_avatar(frm))
        t.append(f" {_short(_display_name(frm) or frm, 32)}", style="bold")
        if self.is_collapsed:
            snippet = " ".join(message_text(m).split())[:80]
            t.append(f"  {snippet}", style=_muted(self.app))
        t.append(f"   {date}", style=_muted(self.app))
        opens = self.message.get("_opens")
        if opens:
            # Same rule as the web badge: only non-proxied opens count as opened;
            # Apple MPP / Gmail-proxy prefetches are shown apart.
            real = [o for o in opens if not o.get("proxied")]
            proxied = len(opens) - len(real)
            if real:
                last = real[-1]
                where = ", ".join(x for x in (last.get("geo_city"), last.get("geo_country")) if x)
                t.append(f"   👁 opened {len(real)}×", style=f"bold {_accent(self.app)}")
                t.append(f" · last {(last.get('opened_at') or '')[:16].replace('T', ' ')}{f' ({where})' if where else ''}", style=_muted(self.app))
            if proxied:
                t.append(f"   {proxied} proxy prefetch{'es' if proxied != 1 else ''}", style=_muted(self.app))
        return t

    def set_opens(self, opens: list[dict]) -> None:
        self.message["_opens"] = opens
        self.query_one(".mc-header", Static).update(self._header())


class AttachmentBar(ThreadItem, Static):
    """A focusable attachments row at the foot of the thread — enter opens the
    attachments view (the "go into attachments" target of message navigation)."""

    can_focus = True
    BINDINGS = [*_NAV_BINDINGS, Binding("enter,space", "open", "Open")]

    def action_open(self) -> None:
        screen = self.screen
        if isinstance(screen, MailScreen):
            screen.action_attachments()


class InviteBar(ThreadItem, Static):
    """The meeting-invite banner (docs/Meeting-Invites.md) above the thread —
    focusable; enter opens the RSVP / add-to-calendar choices."""

    can_focus = True
    BINDINGS = [*_NAV_BINDINGS, Binding("enter,space", "open", "Open")]

    def action_open(self) -> None:
        screen = self.screen
        if isinstance(screen, MailScreen):
            screen.action_invite()


class MailScreen(Screen):
    """Unified inbox / per-channel list view."""

    DEFAULT_CSS = """
    MailScreen { layout: vertical; }
    /* All bar items are height 1; align:middle drops them onto the centre row. */
    #channelbar { height: 3; background: $panel; align: left middle; padding-right: 1; }
    #brand { width: auto; height: 1; padding: 0 1; }
    #brand-sep { width: auto; height: 1; color: $text-muted; }
    .chan-tab { width: auto; height: 1; padding: 0 1; color: $text-muted; }
    .chan-tab:hover { background: $boost; }
    .chan-tab.-active { background: $accent; color: $background; text-style: bold; }
    /* Search flexes to fill the bar so the fixed-width controls to its right
       (settings · sync) are always pinned on-screen, never clipped off the edge. */
    #search { width: 1fr; min-width: 16; max-width: 44; height: 1; border: none; background: $boost; color: $text; padding: 0 1; }
    #search:focus { background: $surface; }
    /* Compact bar buttons. Base sizing here; placement/colour scoped per bar below. */
    .bar-btn { width: auto; height: 1; min-width: 5; padding: 0 1; content-align: center middle; color: $text; }
    .bar-btn:hover { background: $accent; color: $background; text-style: bold; }
    #channelbar .bar-btn { margin-left: 1; background: $panel-lighten-2; }
    #channelbar #btn-compose { background: $accent; color: $background; text-style: bold; }
    #btn-sync.-syncing { color: $warning; }
    #mail-body { height: 1fr; }
    #folders { width: 23; height: 1fr; border-right: solid $panel; padding-left: 1; }
    #folders .folder-section { color: $text-muted; margin-top: 1; background: transparent; }
    /* height:1fr so the table fills the pane — its scrollbar sits at the screen bottom. */
    #conv-table { width: 1fr; height: 1fr; }
    /* The list header line above the table: view name · count · filters. */
    #list-pane { width: 68; height: 1fr; }
    #list-status { height: 1; padding: 0 1; color: $text-muted; background: $panel; }
    /* Right pane = the desktop-style action toolbar above + the scrolling thread
       below; the divider line spans both. The toolbar shows once a conversation
       is open. The bar is 3 rows tall so the filled buttons read as buttons (with
       a blank row of breathing space above and below). */
    #right-pane { width: 1fr; height: 1fr; border-left: solid $panel; }
    #conv-toolbar { height: 3; background: $panel; align: left middle; padding: 0 1; display: none; }
    #conv-toolbar.-active { display: block; }
    #conv-toolbar .bar-btn {
        height: 1; margin: 0 1 0 0; padding: 0 1; background: $primary-darken-2; color: $text;
    }
    #conv-toolbar .bar-btn:hover { background: $primary; color: $background; text-style: bold; }
    #conv-toolbar .bar-btn:focus { background: $accent; color: $background; text-style: bold; }
    #preview-wrap { width: 1fr; height: 1fr; padding: 1 1 0 1; }
    #thread { width: 1fr; height: auto; }
    #thread .thread-subject { width: 1fr; height: auto; padding-bottom: 1; margin-bottom: 1; border-bottom: solid $panel; }
    #thread .msg-body { width: 1fr; height: auto; }
    #thread .collapsed-body { color: $text-muted; }
    /* #thread prefix needed: a bare type selector loses to Vertical's default height:1fr. */
    #thread MessageCard { width: 1fr; height: auto; margin-bottom: 1; border-left: blank; }
    #thread MessageCard .mc-header { width: 1fr; }
    #thread MessageCard .mc-body { width: 1fr; height: auto; }
    #thread MessageCard .mc-details { width: 1fr; height: auto; color: $text-muted; margin-bottom: 1; }
    #thread MessageCard.-collapsed .mc-body { display: none; }
    #thread MessageCard:focus { border-left: thick $accent; }
    #thread MessageCard:focus > .mc-header { text-style: bold; color: $text; }
    #thread SectionToggle { width: 1fr; height: auto; padding-left: 1; border-left: blank; }
    #thread SectionToggle .st-body { width: 1fr; height: auto; }
    #thread SectionToggle.-closed .st-body { display: none; }
    #thread SectionToggle:focus { border-left: thick $accent; }
    #thread SectionToggle:focus > .st-title { color: $accent; text-style: bold; }
    #thread MessageBody { border-left: blank; }
    #thread MessageBody:focus { border-left: thick $accent; }
    #invite-bar { width: 1fr; height: auto; display: none; border-left: blank; padding: 0 1; margin-bottom: 1; background: $boost; }
    #invite-bar.has-invite { display: block; }
    #invite-bar:focus { border-left: thick $accent; text-style: bold; }
    #attach-bar { width: 1fr; height: auto; color: $text-muted; margin-top: 1; display: none; border-left: blank; }
    #attach-bar.has-items { display: block; }
    #attach-bar:focus { border-left: thick $accent; text-style: bold; color: $text; }
    """

    BINDINGS = [
        Binding("j,down", "next", "Next", show=False),
        Binding("k,up", "prev", "Prev", show=False),
        Binding("enter", "open", "Open", show=False),
        Binding("right", "pane_right", "Pane →", show=False, priority=True),
        Binding("left", "pane_left", "← Pane", show=False, priority=True),
        Binding("r", "reply", "Reply"),
        Binding("a", "reply_all", "Reply all", show=False),
        Binding("f", "forward", "Forward", show=False),
        Binding("e", "archive", "Archive"),
        Binding("exclamation_mark", "spam", "Spam", show=False),
        Binding("delete,backspace", "trash", "Trash"),
        Binding("I", "mark_read", "Mark read", show=False),
        Binding("U", "mark_unread", "Mark unread", show=False),
        Binding("o", "attachments", "Attachments", show=False),
        Binding("v", "move", "Move"),
        Binding("x", "select", "Select", show=False),
        Binding("ctrl+a", "select_all", "Select all", show=False),
        Binding("u", "toggle_unread", "Unread"),
        Binding("O", "cycle_sort", "Sort", show=False),
        Binding("slash", "focus_search", "Search"),
        Binding("full_stop", "menu", "Actions"),
        Binding("ctrl+u", "view_source", "Source", show=False),
        # On-device AI (the desktop app hosts the models): summary + smart replies.
        Binding("S", "summarize", "Summarize", show=False),
        Binding("R", "smart_reply", "Smart reply", show=False),
        Binding("T", "send_to", "Send to…", show=False),
        Binding("i", "images", "Images", show=False),
        # Triage (Eisenhower quadrants) — alt-combos, mirroring the desktop.
        Binding("alt+p", "triage('DO_FIRST')", "Priority", show=False),
        Binding("alt+d", "triage('DELEGATE')", "Delegate", show=False),
        Binding("alt+s", "triage('SCHEDULE')", "Schedule", show=False),
        Binding("alt+l", "triage('LATER')", "Later", show=False),
        Binding("alt+x", "triage_clear", "Untag", show=False),
        # Jev: Spaces + triage labels (docs/Triage.md).
        Binding("alt+m", "space", "Space", show=False),
        Binding("alt+t", "label", "Label", show=False),
        Binding("alt+j", "retriage", "Re-run Jev", show=False),
        Binding("escape", "back", "Back", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.folder_status = FOLDERS[0][1]  # the active sidebar view kind
        self.conv_by_key: dict[str, dict] = {}
        self._row_keys: list[str] = []
        self.selected_key: Optional[str] = None
        self.selected_keys: set[str] = set()  # multi-select (x / ctrl+a)
        self._last_sig: Optional[tuple] = None
        self._previewed_key: Optional[str] = None
        self.current_messages: list[dict] = []
        self._cards: dict[str, MessageCard] = {}
        self.attachments: list[dict] = []
        self.invite: Optional[dict] = None
        self.search_query = ""
        self._search_timer = None
        self._toolbar_idx = 0  # last-focused toolbar button, for up/down round-trips
        self._mark_read_timer = None  # pending dwell timer (delay mode)
        self._pinned_conv: Optional[dict] = None  # see show_conversation
        self._semantic_for: Optional[tuple] = None  # (`~query`, account keys) whose hits are loaded
        self._semantic_rows: list[dict] = []
        self._triage_names: dict[str, str] = dict(TRIAGE_LABELS)

    def compose(self) -> ComposeResult:
        with Horizontal(id="channelbar"):
            yield Static(brand_text(self.app), id="brand")
            yield Static("│", id="brand-sep")
            for label, idx in self._channel_items():
                yield ChannelTab(label, idx)
            # Search flexes (1fr) to fill the gap, pinning the action controls to
            # the right edge so none of them (notably Sync) clips off-screen.
            yield Input(placeholder="Search…  from:  is:unread  has:attachment  ( / )", id="search")
            yield BarButton(_compose_label(), "compose", id="btn-compose")
            settings = BarButton("⚙", "settings", id="btn-settings")
            settings.tooltip = "Settings (,)"
            yield settings
            sync = BarButton("⟳", "sync", id="btn-sync")
            sync.tooltip = "Sync (s)"
            yield sync
        with Horizontal(id="mail-body"):
            yield ListView(id="folders")
            with Vertical(id="list-pane"):
                yield Static("", id="list-status")
                table = DataTable(id="conv-table", cursor_type="row", zebra_stripes=True)
                table.add_column("From", key="from", width=_FROM_W)
                table.add_column("Subject", key="subject", width=_SUBJECT_W)
                table.add_column("Date", key="date", width=_DATE_W)
                yield table
            with Vertical(id="right-pane"):
                with Horizontal(id="conv-toolbar"):
                    for label, action, btn_id in self._toolbar_items():
                        yield ToolbarButton(label, action, id=btn_id)
                preview = VerticalScroll(id="preview-wrap")
                with preview:
                    yield InviteBar("", id="invite-bar")
                    with Vertical(id="thread"):
                        yield Static("Select a conversation.")
                    yield AttachmentBar("", id="attach-bar")
        yield Footer()

    def on_mount(self) -> None:
        self.rebuild_sidebar()
        self.refresh_conversations()
        self.update_channelbar()
        self.query_one("#conv-table", DataTable).focus()

    # ── sidebar ──────────────────────────────────────────────────────────────
    def _section_header(self, text: str) -> ListItem:
        """A non-selectable sidebar section label, mirroring the desktop
        sidebar's FOLDERS / LABELS group headers."""
        item = ListItem(Label(Text(text.upper(), style=f"bold {_muted(self.app)}")))
        item.disabled = True  # skipped by list navigation; carries no folder_status
        item.add_class("folder-section")
        return item

    @staticmethod
    def _sidebar_item(label: Text, view: str) -> ListItem:
        item = ListItem(Label(label))
        item.folder_status = view  # type: ignore[attr-defined]
        return item

    def _row(self, icon: str, name: str, count: int | str | None = None, icon_style: str | None = None) -> Text:
        t = Text()
        t.append(f"{icon}  ", style=icon_style or _muted(self.app))
        t.append(name)
        if count:
            t.append(f"{_NBSP}{_NBSP}{count}", style=f"bold {_accent(self.app)}")
        return t

    def rebuild_sidebar(self) -> None:
        """(Re)build the sidebar for the active channel: Folders (+ unread count),
        Outbox, Spaces, Triage quadrants, Jev labels, and provider labels."""
        folders = self.query_one("#folders", ListView)
        keys = self.account_keys()
        db = self.app.db
        current = self.folder_status
        folders.clear()
        items: list[ListItem] = []

        items.append(self._section_header("Folders"))
        unread = db.unread_count(keys)
        for name, status, icon in FOLDERS:
            items.append(self._sidebar_item(self._row(icon, name, unread if status == STATUS_OPEN else None), status))
        pending, failed = db.outbox_counts(keys)
        if pending or failed:
            badge = f"{failed} failed" if failed else f"{pending}"
            items.append(self._sidebar_item(self._row("⇡", "Outbox", badge, _ERROR if failed else None), VIEW_OUTBOX))

        spaces = db.spaces(keys)
        if len(spaces) > 1:  # the Jev holding pen alone isn't a Spaces section
            items.append(self._section_header("Spaces"))
            for s in spaces:
                items.append(self._sidebar_item(self._row("▦", s["name"]), f"{VIEW_SPACE_PREFIX}{s['slug']}"))

        # Triage quadrants — the terminal equivalent of the desktop's LABELS
        # section. Each carries a colour-matched dot and filters by quadrant flags.
        items.append(self._section_header("Triage"))
        for key in QUADRANT_ORDER:
            q = QUADRANTS[key]
            items.append(self._sidebar_item(self._row("●", q["label"], icon_style=q["color"]), f"{VIEW_TRIAGE_PREFIX}{key}"))
        labels = db.triage_labels(keys)
        self._triage_names = {l["slug"]: l["name"] for l in labels}
        for l in labels:
            items.append(self._sidebar_item(self._row("◇", l["name"]), f"{VIEW_TLABEL_PREFIX}{l['slug']}"))

        provider_labels = db.labels(keys)
        if provider_labels:
            items.append(self._section_header("Labels"))
            for l in provider_labels:
                items.append(self._sidebar_item(self._row("⌗", l["name"]), f"{VIEW_LABEL_PREFIX}{l['key']}"))

        folders.extend(items)
        # Keep the highlight on the active view when it survives the rebuild.
        for i, it in enumerate(items):
            if getattr(it, "folder_status", None) == current:
                folders.index = i
                break

    # ── channel bar ─────────────────────────────────────────────────────────
    def _channel_items(self) -> list[tuple[Text, int]]:
        items = [(Text("F1 Unified"), -1)]
        for i, acct in enumerate(getattr(self.app, "accounts", [])):
            label = acct.get("email_address") or acct.get("display_name") or acct["key"]
            t = Text(f"F{i + 2} {label}")
            if acct.get("status") not in (None, "", "connected", "syncing"):
                t.append(" ⚠", style=f"bold {_WARN}")
            items.append((t, i))
        return items

    def update_channelbar(self) -> None:
        active = getattr(self.app, "active_channel", None)
        labels = {idx: label for label, idx in self._channel_items()}
        for tab in self.query(ChannelTab):
            is_active = tab.index == -1 if active is None else tab.index == active
            tab.set_class(is_active, "-active")
            if tab.index in labels:
                tab.update(labels[tab.index])

    def refresh_palette(self) -> None:
        """Redraw everything whose colours were baked in from the previous theme."""
        if not self.is_mounted:
            return
        self.query_one("#brand", Static).update(brand_text(self.app))
        self.rebuild_sidebar()
        self._previewed_key = None
        self.refresh_conversations(force=True)
        conv = self.conv_by_key.get(self.selected_key or "")
        if conv and not conv.get("_outbox"):
            self._render_preview(conv)

    def set_syncing(self, syncing: bool) -> None:
        """The Sync button doubles as the syncing indicator."""
        btn = self.query_one("#btn-sync", BarButton)
        btn.set_class(syncing, "-syncing")
        btn.update("⟳ syncing" if syncing else "⟳")

    def on_channel_tab_selected(self, message: ChannelTab.Selected) -> None:
        # Mouse click on a channel tab → switch channel.
        self.app.action_channel(message.index)

    # ── conversation action toolbar ───────────────────────────────────────────
    @staticmethod
    def _toolbar_items() -> list[tuple[str, str, str]]:
        """The clickable conversation action row, mirroring the desktop toolbar
        (Reply · All · Fwd · Archive · Delete · More). As on the desktop, the
        long tail — spam, mark read/unread, triage, view source — lives behind
        the "More" menu rather than as top-level buttons."""
        return [
            ("↩ Reply", "reply", "tb-reply"),
            ("↩ All", "reply_all", "tb-all"),
            ("↪ Fwd", "forward", "tb-fwd"),
            ("▣ Archive", "archive", "tb-archive"),
            ("✕ Delete", "trash", "tb-trash"),
            ("⋯ More", "menu", "tb-more"),
        ]

    # ── account scope ─────────────────────────────────────────────────────
    def account_keys(self) -> list[str]:
        app = self.app
        active = getattr(app, "active_channel", None)
        if active is None:
            return [a["key"] for a in app.accounts]
        if 0 <= active < len(app.accounts):
            return [app.accounts[active]["key"]]
        return []

    # ── data refresh (flicker-guarded) ──────────────────────────────────────
    def _rows_for_view(self) -> list[dict]:
        db = self.app.db
        keys = self.account_keys()
        unread_only = getattr(self.app, "unread_only", False)
        view = self.folder_status
        if self.search_query.startswith("~"):
            # `~words` = semantic search (the desktop's vector index, over the bus).
            q = self.search_query[1:].strip()
            scope = (q, tuple(keys))  # the same words on another account are a new search
            if q and scope != self._semantic_for:
                self._semantic_for, self._semantic_rows = scope, []
                self.run_worker(self._semantic_search(scope), group="semantic", exclusive=True)
            return list(self._semantic_rows)
        if self.search_query:
            return db.search(keys, self.search_query, unread_only=unread_only)
        if view == VIEW_OUTBOX:
            return [dict(r, _outbox=True) for r in db.outbox(keys)]
        if view.startswith(VIEW_TRIAGE_PREFIX):
            q = QUADRANTS[view[len(VIEW_TRIAGE_PREFIX):]]
            return db.conversations_by_quadrant(keys, q["urgent"], q["important"], unread_only=unread_only)
        if view.startswith(VIEW_SPACE_PREFIX):
            return db.conversations_by_space(keys, view[len(VIEW_SPACE_PREFIX):], unread_only=unread_only)
        if view.startswith(VIEW_TLABEL_PREFIX):
            return db.conversations_by_triage_label(keys, view[len(VIEW_TLABEL_PREFIX):], unread_only=unread_only)
        if view.startswith(VIEW_LABEL_PREFIX):
            return db.conversations_in_label(keys, view[len(VIEW_LABEL_PREFIX):], unread_only=unread_only)
        if view in (VIEW_SENT, VIEW_DRAFTS):
            return db.conversations_with_message(keys, draft=(view == VIEW_DRAFTS), unread_only=unread_only)
        if view == STATUS_OPEN:
            # The Inbox, by the desktop's rule (db.inbox); the Unified tab also leaves
            # quadrant-placed threads to the Triage views, like the desktop's matrix.
            return db.inbox(keys, unified=self.app.active_channel is None, unread_only=unread_only)
        return db.conversations(keys, status=view, unread_only=unread_only)

    @staticmethod
    def _sorted(rows: list[dict], order: str) -> list[dict]:
        if order == SORT_OLDEST:
            return list(reversed(rows))
        if order == SORT_UNREAD_FIRST:
            return sorted(rows, key=lambda r: bool(r.get("read")))  # stable: newest-first within each group
        return rows

    def _view_title(self) -> str:
        view = self.folder_status
        if self.search_query:
            return f"Search: {self.search_query}"
        if view == VIEW_OUTBOX:
            return "Outbox"
        for name, status, _ in FOLDERS:
            if status == view:
                return name
        if view.startswith(VIEW_TRIAGE_PREFIX):
            return QUADRANTS[view[len(VIEW_TRIAGE_PREFIX):]]["label"]
        if view.startswith(VIEW_SPACE_PREFIX):
            slug = view[len(VIEW_SPACE_PREFIX):]
            return next((s["name"] for s in self.app.db.spaces(self.account_keys()) if s["slug"] == slug), slug)
        if view.startswith(VIEW_TLABEL_PREFIX):
            slug = view[len(VIEW_TLABEL_PREFIX):]
            return self._triage_names.get(slug, slug)
        if view.startswith(VIEW_LABEL_PREFIX):
            label = self.app.db._label(view[len(VIEW_LABEL_PREFIX):])
            return label["name"] if label else "Label"
        return view

    def _update_status(self, rows: list[dict]) -> None:
        t = Text()
        t.append(self._view_title(), style=f"bold {_fg(self.app)}")
        t.append(f"{_NBSP}{_NBSP}{len(rows)}", style=_muted(self.app))
        if getattr(self.app, "unread_only", False):
            t.append("  · unread only", style=_WARN)
        order = prefs.sort_order()
        if order != SORT_ORDERS[0]:
            t.append(f"  · {SORT_LABELS[order].lower()}", style=_muted(self.app))
        if self.selected_keys:
            t.append(f"  · {len(self.selected_keys)} selected", style=f"bold {_accent(self.app)}")
        self.query_one("#list-status", Static).update(t)

    def refresh_conversations(self, force: bool = False) -> None:
        if force:
            self._last_sig = None
        rows = self._sorted(self._rows_for_view(), prefs.sort_order())
        # A thread opened from Lore/an entity page beyond the list's row cap stays
        # listed (so actions keep targeting it) until the view changes.
        pin = self._pinned_conv
        if pin:
            # Re-read it: an archive/move/delete since it was pinned takes it out of here.
            fresh = self.app.db.conversation(self.account_keys(), pin["key"])
            pin = self._pinned_conv = (dict(pin, **fresh) if fresh else None)
            if pin and (pin.get("status") or STATUS_OPEN) != self.folder_status:
                pin = self._pinned_conv = None
            # The Inbox is folder membership, not status: a pinned thread that was in
            # the Inbox and has been moved to another folder leaves it. (One opened
            # from Lore that never was — sent-only — stays pinned.)
            if pin and self.folder_status == STATUS_OPEN:
                now_in = self.app.db.in_inbox(pin["account_key"], pin["key"])
                if pin.setdefault("_in_inbox", now_in) and not now_in:
                    pin = self._pinned_conv = None
        # The Inbox's own rule (folder membership, Unified's triage exclusion) never
        # drops a pin: it was opened on purpose, so it stays until the view changes.
        if pin and not self.search_query and (pin.get("status") or STATUS_OPEN) == self.folder_status \
                and pin.get("account_key") in self.account_keys() \
                and pin["key"] not in {r["key"] for r in rows}:
            rows.append(pin)
        # Selections only survive while their rows are listed.
        self.selected_keys &= {r["key"] for r in rows}
        sig = tuple(
            (r["key"], r.get("read"), r.get("subject"), r.get("from_address"), r.get("status"),
             r.get("triage_label"), r.get("space_slug"), r["key"] in self.selected_keys)
            for r in rows
        )
        if sig == self._last_sig:
            return  # nothing changed — skip the redraw (minimise flicker)
        self._last_sig = sig
        self._update_status(rows)

        table = self.query_one("#conv-table", DataTable)
        prior_key = self.selected_key
        table.clear()
        self.conv_by_key = {}
        self._row_keys = []
        for r in rows:
            self.conv_by_key[r["key"]] = r
            self._row_keys.append(r["key"])
            if r.get("_outbox"):
                table.add_row(*self._outbox_cells(r), key=r["key"])
                continue
            table.add_row(*self._conv_cells(r), key=r["key"])
        # Restore cursor on the same conversation if it's still present.
        if prior_key and prior_key in self.conv_by_key:
            try:
                table.move_cursor(row=self._row_keys.index(prior_key))
            except Exception:
                pass
        elif rows:
            self.selected_key = rows[0]["key"]

    def _conv_cells(self, r: dict) -> tuple[Text, Text, Text]:
        unread = not r.get("read")
        # Single-width gutter slots: selection · unread dot · attachment · triage quadrant.
        frm = Text()
        frm.append(_SELECT_MARK if r["key"] in self.selected_keys else " ", style=f"bold {_accent(self.app)}")
        frm.append("●" if unread else " ", style=f"bold {_accent(self.app)}")
        frm.append(_ATTACH_MARK if r.get("has_attachment") else " ", style=_muted(self.app))
        quad = quadrant_for(r.get("priority_urgent"), r.get("priority_important"))
        if quad:
            frm.append(QUADRANTS[quad]["mark"], style=f"bold {QUADRANTS[quad]['color']}")
        else:
            frm.append(" ")
        frm.append(_NBSP)
        frm.append(_short(_display_name(r.get("from_address")) or r.get("from_address") or "", _FROM_W - 5), style="bold" if unread else "")
        chip = triage_chip(r.get("triage_label"), r.get("triage_priority"), self._triage_names, self.app)
        room = _SUBJECT_W - (len(chip.plain) + 2 if chip.plain else 0)
        if room < 20:
            # The label would eat the subject: keep only the !!/! priority marks.
            chip = triage_chip(None, r.get("triage_priority"), app=self.app)
            room = _SUBJECT_W - (len(chip.plain) + 2 if chip.plain else 0)
        subj = Text(_short(r.get("subject") or "(no subject)", max(room, 12)), style="bold" if unread else "")
        if chip.plain:
            subj.append(f"{_NBSP}{_NBSP}")
            subj.append_text(chip)
        return frm, subj, Text(_rel_date(r.get("updated_at")), style=_muted(self.app))

    def _outbox_cells(self, r: dict) -> tuple[Text, Text, Text]:
        status = r.get("status") or ""
        style = _ERROR if status == OUTBOX_FAILED else _WARN if status in ("pending", "sending") else _muted(self.app)
        frm = Text()
        frm.append(f"{'✎' if r.get('kind') == OUTBOX_KIND_DRAFT else '⇡'} ", style=_muted(self.app))
        frm.append(status, style=f"bold {style}")
        frm.append(f"  {_short(r.get('to_address') or '', 18)}")
        subj = Text(_short(r.get("subject") or "(no subject)", 40))
        if r.get("error_message"):
            subj.append(f"  {_short(r['error_message'], 40)}", style=_ERROR)
        return frm, subj, Text(_rel_date(r.get("created_at")), style=_muted(self.app))

    def _selected_conv(self) -> Optional[dict]:
        table = self.query_one("#conv-table", DataTable)
        idx = table.cursor_row
        if idx is None or not (0 <= idx < len(self._row_keys)):
            return None
        self.selected_key = self._row_keys[idx]
        conv = self.conv_by_key.get(self.selected_key)
        return None if conv is None or conv.get("_outbox") else conv

    def _targets(self) -> list[dict]:
        """The conversations an action applies to: the multi-selection when
        there is one, else the cursor row."""
        if self.selected_keys:
            return [self.conv_by_key[k] for k in self._row_keys if k in self.selected_keys and k in self.conv_by_key]
        conv = self._selected_conv()
        return [conv] if conv else []

    @staticmethod
    def _by_account(convs: list[dict]) -> dict[str, list[str]]:
        groups: dict[str, list[str]] = {}
        for c in convs:
            groups.setdefault(c["account_key"], []).append(c["key"])
        return groups

    # ── navigation ───────────────────────────────────────────────────────
    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        # Auto-refresh the preview pane as the cursor moves through the list.
        key = event.row_key.value if event.row_key is not None else None
        if not key or key not in self.conv_by_key:
            return
        self.selected_key = key
        conv = self.conv_by_key[key]
        if not conv.get("_outbox"):
            self._render_preview(conv)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        # DataTable consumes Enter at the widget level; open the conversation.
        self.action_open()

    def action_next(self) -> None:
        # In the message thread, j/down is handled by the focused card itself
        # (ThreadItem); here it only drives the conversation list.
        self.query_one("#conv-table", DataTable).action_cursor_down()

    def action_prev(self) -> None:
        self.query_one("#conv-table", DataTable).action_cursor_up()

    # ── selection (x / ctrl+a) ─────────────────────────────────────────────
    def action_select(self) -> None:
        conv = self._selected_conv()
        if not conv:
            return
        if conv["key"] in self.selected_keys:
            self.selected_keys.discard(conv["key"])
        else:
            self.selected_keys.add(conv["key"])
        self.refresh_conversations(force=True)
        self.action_next()

    def action_select_all(self) -> None:
        keys = {k for k, c in self.conv_by_key.items() if not c.get("_outbox")}
        self.selected_keys = set() if self.selected_keys == keys else keys
        self.refresh_conversations(force=True)

    def clear_selection(self) -> None:
        if self.selected_keys:
            self.selected_keys.clear()
            self.refresh_conversations(force=True)

    # ── filters: unread · sort ─────────────────────────────────────────────
    def action_toggle_unread(self) -> None:
        self.app.unread_only = not getattr(self.app, "unread_only", False)
        self.refresh_conversations(force=True)

    def action_cycle_sort(self) -> None:
        order = SORT_ORDERS[(SORT_ORDERS.index(prefs.sort_order()) + 1) % len(SORT_ORDERS)]
        prefs.set("sort", order)
        self.app.notify(f"Sort: {SORT_LABELS[order]}")
        self.refresh_conversations(force=True)

    # ── zone navigation (folders ↔ list ↔ message thread) ────────────────────
    def _in_thread(self) -> bool:
        foc = self.app.focused
        if foc is None:
            return False
        wrap = self.query_one("#preview-wrap")
        return any(a is wrap for a in foc.ancestors_with_self)

    def _thread_focusables(self) -> list:
        """Focusable thread widgets (cards, section toggles, attachment bar) in
        tab order — Textual's focus_chain already excludes hidden/collapsed ones."""
        wrap = self.query_one("#preview-wrap")
        return [
            w for w in self.focus_chain
            if w is not wrap and any(a is wrap for a in w.ancestors_with_self)
        ]

    def thread_focus(self, delta: int) -> None:
        items = self._thread_focusables()
        if not items:
            return
        foc = self.app.focused
        idx = items.index(foc) if foc in items else 0
        if idx == 0 and delta < 0:
            # Above the first message → step up into the action toolbar.
            self.focus_toolbar()
            return
        target = items[max(0, min(idx + delta, len(items) - 1))]
        # Tell a MessageBody which edge to land on (top link when entering from
        # above, bottom link when entering from below).
        if hasattr(target, "_enter_dir"):
            target._enter_dir = delta
        target.focus()

    # ── action toolbar focus ──────────────────────────────────────────────────
    def _toolbar_buttons(self) -> list:
        return list(self.query(ToolbarButton))

    def focus_toolbar(self) -> None:
        btns = self._toolbar_buttons()
        if btns:
            self._toolbar_idx = min(self._toolbar_idx, len(btns) - 1)
            btns[self._toolbar_idx].focus()

    def focus_first_thread_item(self) -> None:
        items = self._thread_focusables()
        if items:
            items[0].focus()

    def toolbar_move(self, delta: int) -> bool:
        """Move focus along the toolbar. Returns True if it handled the key.
        Going left past the first button exits to the conversation list."""
        btns = self._toolbar_buttons()
        foc = self.app.focused
        if not btns or foc not in btns:
            return False
        target = btns.index(foc) + delta
        if target < 0:
            self.query_one("#conv-table", DataTable).focus()
        elif target < len(btns):
            self._toolbar_idx = target
            btns[target].focus()
        # past the last button → stay put
        return True

    def show_conversation(self, conv: dict) -> None:
        """Open one conversation from outside the list (Lore, an entity page).
        The list switches to the folder holding it and the cursor lands on its
        row, so every list action (archive, reply, …) targets this thread."""
        self.selected_key = conv["key"]
        # Clear what would hide it: another channel's tab, the unread filter.
        keys = [a["key"] for a in self.app.accounts]
        if self.app.active_channel is not None and keys[self.app.active_channel:self.app.active_channel + 1] != [conv["account_key"]]:
            self.app.active_channel = None
            self.update_channelbar()
            self.rebuild_sidebar()
        if self.app.unread_only:
            self.app.unread_only = False
        self.set_view(conv.get("status") or STATUS_OPEN)
        table = self.query_one("#conv-table", DataTable)
        if conv["key"] not in self.conv_by_key:
            # Older than the list's row cap: pin its row, so it is the cursor's
            # (and every list action's) target, through later refreshes too.
            self._pinned_conv = conv
            self.refresh_conversations(force=True)
        if conv["key"] not in self._row_keys:  # no view can list it (e.g. its account is gone)
            self.app.notify("That conversation isn't in any list here.", severity="warning")
            return
        table.move_cursor(row=self._row_keys.index(conv["key"]))
        self._previewed_key = None
        self._render_preview(self.conv_by_key[conv["key"]])
        self.call_after_refresh(self._enter_thread)

    def _enter_thread(self) -> None:
        items = self._thread_focusables()
        if items:
            items[0].focus()

    def action_pane_left(self) -> None:
        if isinstance(self.app.focused, Input):
            return  # let the quick-reply box keep left/right for cursor moves
        if isinstance(self.app.focused, ToolbarButton):
            self.toolbar_move(-1)
        elif self._in_thread():
            self.query_one("#conv-table", DataTable).focus()
        elif self.app.focused is self.query_one("#conv-table"):
            self.query_one("#folders").focus()

    def action_pane_right(self) -> None:
        if isinstance(self.app.focused, Input) or self._in_thread():
            return
        if isinstance(self.app.focused, ToolbarButton):
            self.toolbar_move(1)
        elif self.app.focused is self.query_one("#folders"):
            # Stepping right out of the sidebar also switches to the highlighted
            # folder (not just `enter`), so j/k → → reads as "pick this folder".
            folders = self.query_one("#folders", ListView)
            self._apply_folder(folders.highlighted_child)
            self.query_one("#conv-table", DataTable).focus()
        else:  # conversation list → step into the message thread
            self._enter_thread()

    def _apply_folder(self, item) -> bool:
        """Switch the conversation list to the view carried by a sidebar item.
        Returns whether a switch happened (item carries a view kind)."""
        status = getattr(item, "folder_status", None)
        if not status:
            return False
        self.set_view(status)
        return True

    def set_view(self, status: str) -> None:
        self._pinned_conv = None
        self.folder_status = status
        self.selected_keys.clear()
        # A sidebar pick leaves search mode (the desktop clears the box too).
        if self.search_query:
            self.search_query = ""
            self.query_one("#search", Input).value = ""
        self.refresh_conversations(force=True)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        if self._apply_folder(event.item):
            self.query_one("#conv-table", DataTable).focus()

    def _render_preview(self, conv: dict) -> None:
        # Rebuild only when the conversation changes — preserves per-message
        # expand/collapse state across list refreshes (bus events, actions).
        if conv["key"] == self._previewed_key:
            return
        prev_key = self._previewed_key
        self._previewed_key = conv["key"]
        # Auto-mark-read follows the user's Outlook-style preference.
        self._schedule_mark_read(conv, prev_key)
        # A conversation is open now → show the desktop-style action toolbar.
        self.query_one("#conv-toolbar").add_class("-active")
        self.current_messages = self.app.db.conversation_messages(conv["key"])
        thread = self.query_one("#thread", Vertical)
        thread.remove_children()
        msgs = self.current_messages
        # Conversation subject + message count + triage as the thread title.
        title = Text(conv.get("subject") or "(no subject)", style=f"bold {_fg(self.app)}")
        n = len(msgs)
        meta: list[Text] = []
        if n:
            meta.append(Text(f"{n} message{'s' if n != 1 else ''}", style=_muted(self.app)))
        quad = quadrant_for(conv.get("priority_urgent"), conv.get("priority_important"))
        if quad:
            q = QUADRANTS[quad]
            meta.append(Text(f"{q['mark']} {q['label']}", style=f"bold {q['color']}"))
        chip = triage_chip(conv.get("triage_label"), conv.get("triage_priority"), self._triage_names, self.app)
        if chip.plain:
            meta.append(chip)
        if conv.get("space_slug"):
            meta.append(Text(f"▦ {conv['space_slug']}", style=_muted(self.app)))
        if meta:
            title.append("\n")
            for i, part in enumerate(meta):
                if i:
                    title.append(f"{_NBSP}·{_NBSP}", style=_muted(self.app))
                title.append_text(part)
        # The AI summary + next action the host's triage worker cached (desktop's
        # summary card); nothing for MX or untriaged threads.
        ai = self.app.db.conversation_summary(conv["key"])
        if ai.get("next_action_title"):
            title.append(f"\n→ {ai['next_action_title']}", style=f"bold {_accent(self.app)}")
            if ai.get("next_action_due_on"):
                title.append(f"  due {ai['next_action_due_on']}", style=_WARN)
            if ai.get("next_action_amount_cents"):
                title.append(f"  {ai['next_action_amount_cents'] / 100:.2f} {ai.get('next_action_currency') or ''}".rstrip(), style=_WARN)
        summary = ai.get("ai_summary_medium") or ai.get("ai_summary_short")
        if summary:
            title.append(f"\n✦ {summary}", style=_muted(self.app))
        thread.mount(Static(title, classes="thread-subject"))
        self._cards = {}
        if msgs:
            last = len(msgs) - 1
            # Gmail-style: collapse every message except the last in a thread.
            cards = [MessageCard(m, collapsed=(len(msgs) > 1 and i != last)) for i, m in enumerate(msgs)]
            thread.mount(*cards)
            self._cards = {m["key"]: c for m, c in zip(msgs, cards)}
        else:
            thread.mount(Static(ThemedMarkdown("*(empty)*")))
        # Attachment metadata isn't in the local DB, and Microsoft bodies are
        # fetched lazily — both are resolved on demand from the provider. Reset the
        # bars and hydrate in the background when there's anything to fetch.
        self.attachments = []
        self.invite = None
        self._update_invite_bar()
        bar = self.query_one("#attach-bar", AttachmentBar)
        bar.remove_class("has-items")
        bar.update("")
        has_attachment = bool(conv.get("has_attachment"))
        if has_attachment:
            bar.add_class("has-items")
            bar.update("📎 loading attachments…")
        mine = [m for m in msgs if not self.app.is_mx(m["account_key"])
                and _addr(m.get("from_address")) == self.app._self_address(m["account_key"]).lower()]
        if mine:
            self.run_worker(self._load_opens(conv["key"], mine), name="opens", group="opens", exclusive=True)
        if has_attachment or any(_body_empty(m) for m in msgs):
            self.run_worker(
                self._hydrate_thread(conv["key"], has_attachment), name="hydrate", exclusive=True
            )

    async def _load_opens(self, conv_key: str, sent: list[dict]) -> None:
        """Open-tracking badges on the messages you sent (docs/Open-Tracking.md);
        the engine returns none when tracking is off for the channel."""
        for m in sent:
            try:
                opens = await self.app.bus.call("get_message_opens", {"message_key": m["key"]})
            except Exception:
                return  # an older host without the method: no badges, no noise
            if self.selected_key != conv_key:
                return
            card = self._cards.get(m["key"])
            if opens and card is not None:
                card.set_opens(list(opens))

    async def _hydrate_thread(self, conv_key: str, want_attachments: bool) -> None:
        """Resolve lazily-loaded message bodies (Microsoft) and attachments via the
        engine's fetch_message RPC. One fetch per message that needs either; the
        RPC persists the body to the local store, so we also re-render the card in
        place. An ICS attachment is then parsed into the invite banner. Failures
        are skipped."""
        found: list[dict] = []
        for m in self.current_messages:
            if "mx_attachments" in m:  # listed in the mirrored payload; no provider to ask
                found.extend(dict(a, message_key=m["key"], account_key=m["account_key"]) for a in m["mx_attachments"])
                continue
            need_body = _body_empty(m)
            if not (need_body or want_attachments):
                continue
            try:
                res = await self.app.bus.call(
                    "fetch_message",
                    {"account_key": m["account_key"], "message_key": m["key"]},
                )
            except Exception:
                continue
            res = res or {}
            # The user may have moved on while we were fetching — bail before touching UI.
            if self.selected_key != conv_key:
                return
            if need_body and (res.get("body_plain") or res.get("body_html")):
                m["body_plain"] = res.get("body_plain")
                m["body_html"] = res.get("body_html")
                card = self._cards.get(m["key"])
                if card is not None:
                    card.rehydrate(m)
            for a in res.get("attachments", []):
                found.append(
                    {
                        "message_key": m["key"],
                        "account_key": m["account_key"],
                        "attachment_id": a.get("attachment_id"),
                        "filename": a.get("filename") or "attachment",
                        "mime_type": a.get("mime_type"),
                        "size": a.get("size") or 0,
                    }
                )
        if self.selected_key != conv_key:
            return
        self.attachments = found
        self._update_attach_bar()
        ics = next((a for a in found if _is_ics(a)), None)
        if ics:
            try:
                invite = await self.app.bus.call(
                    "invite_for_attachment",
                    {"account_key": ics["account_key"], "message_key": ics["message_key"],
                     "attachment_id": ics["attachment_id"]},
                )
            except Exception:
                invite = None
            if invite and self.selected_key == conv_key:
                self.invite = dict(invite, account_key=ics["account_key"], message_key=ics["message_key"])
                self._update_invite_bar()

    def _update_attach_bar(self) -> None:
        bar = self.query_one("#attach-bar", AttachmentBar)
        if not self.attachments:
            bar.remove_class("has-items")
            bar.update("")
            return
        names = ", ".join(
            f"{a['filename']} ({human_size(a['size'])})" for a in self.attachments[:4]
        )
        more = "" if len(self.attachments) <= 4 else f" +{len(self.attachments) - 4} more"
        bar.add_class("has-items")
        bar.update(f"📎 {len(self.attachments)} attachment(s): {names}{more}  ·  enter to save")

    def _update_invite_bar(self) -> None:
        bar = self.query_one("#invite-bar", InviteBar)
        inv = self.invite
        if not inv:
            bar.remove_class("has-invite")
            bar.update("")
            return
        t = Text("📅 ", style="bold")
        t.append(inv.get("summary") or "Meeting invite", style="bold")
        when = (inv.get("start") or "")[:16].replace("T", " ")
        if when:
            t.append(f"  ·  {when}", style=_muted(self.app))
        if inv.get("organizer_email"):
            t.append(f"  ·  from {inv.get('organizer_name') or inv['organizer_email']}", style=_muted(self.app))
        if inv.get("current_status"):
            t.append(f"  ·  you: {inv['current_status']}", style=_WARN)
        t.append("  ·  enter to respond", style=_muted(self.app))
        bar.add_class("has-invite")
        bar.update(t)

    def action_attachments(self) -> None:
        if not self.attachments:
            self.app.notify("No attachments in this conversation.")
            return
        self.app.open_attachments(list(self.attachments))

    def action_invite(self) -> None:
        if not self.invite:
            self.app.notify("No meeting invite in this conversation.")
            return
        self.app.open_invite(dict(self.invite))

    def action_open(self) -> None:
        if self.folder_status == VIEW_OUTBOX:
            self._retry_outbox()
            return
        conv = self._selected_conv()
        if not conv:
            return
        if self.folder_status == VIEW_DRAFTS and self.app.reopen_mx_draft(conv):
            return
        # _render_preview schedules auto-mark-read per the user's preference.
        self._render_preview(conv)

    def _retry_outbox(self) -> None:
        table = self.query_one("#conv-table", DataTable)
        idx = table.cursor_row
        if idx is None or not (0 <= idx < len(self._row_keys)):
            return
        row = self.conv_by_key.get(self._row_keys[idx]) or {}
        if row.get("status") == OUTBOX_FAILED:
            self.app.retry_outbox(row["account_key"], row["key"])
        else:
            self.app.notify(f"Outbox entry is {row.get('status')}; only failed sends can be retried.")

    # ── search & top-bar buttons ─────────────────────────────────────────────
    def action_focus_search(self) -> None:
        self.query_one("#search", Input).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id != "search":
            return
        # Debounced: FTS runs once typing pauses, not per keystroke.
        if self._search_timer is not None:
            self._search_timer.stop()
        value = event.value.strip()

        def _apply() -> None:
            self._search_timer = None
            self.search_query = value
            self.refresh_conversations(force=True)

        self._search_timer = self.set_timer(0.25, _apply)

    def on_bar_button_clicked(self, message: BarButton.Clicked) -> None:
        # Top-bar controls + the conversation action toolbar both post here.
        action = message.action
        if action == "settings":
            self.app.open_settings()
        elif action == "sync":
            self.app.sync_now()
        elif action == "compose":
            self.app.action_compose()
        else:
            # Toolbar buttons map 1:1 onto the existing keyboard actions.
            handler = getattr(self, f"action_{action}", None)
            if handler:
                handler()

    def action_back(self) -> None:
        search = self.query_one("#search", Input)
        if self.app.focused is search or self.search_query:
            # Escape from search clears the filter and returns to the list.
            search.value = ""
            self.search_query = ""
            self.refresh_conversations(force=True)
            self.query_one("#conv-table", DataTable).focus()
            return
        if self.selected_keys:
            self.clear_selection()
            return
        self.query_one("#conv-table", DataTable).focus()

    # ── auto-mark-read (Outlook-style; see prefs / web useMarkRead.js) ───────
    def _cancel_mark_read_timer(self) -> None:
        if self._mark_read_timer is not None:
            self._mark_read_timer.stop()
            self._mark_read_timer = None

    def _schedule_mark_read(self, conv: dict, prev_key) -> None:
        """Mark the previewed conversation read per the user's preference. Called
        when the previewed conversation changes (cursor move / open)."""
        self._cancel_mark_read_timer()
        mode = prefs.mark_read_mode()

        if mode == MARK_READ_MODE_NEVER:
            return

        if mode == MARK_READ_MODE_SELECTION_CHANGE:
            # Selection moved off the previous conversation → mark it read.
            if prev_key and prev_key != conv["key"]:
                prev = self.conv_by_key.get(prev_key)
                if prev and not prev.get("read"):
                    self._mark([prev], ACTION_MARK_READ, undo=False)
            return

        # immediate / delay act on the conversation shown now.
        if conv.get("read"):
            return

        if mode == MARK_READ_MODE_IMMEDIATE:
            self._mark([conv], ACTION_MARK_READ, undo=False)
            return

        if mode == MARK_READ_MODE_DELAY:
            # Dwell timer; cancelled above if the cursor moves on first.
            key = conv["key"]

            def _fire() -> None:
                self._mark_read_timer = None
                c = self.conv_by_key.get(key)
                if c and not c.get("read"):
                    self._mark([c], ACTION_MARK_READ, undo=False)

            self._mark_read_timer = self.set_timer(prefs.mark_read_delay(), _fire)

    # ── status actions ───────────────────────────────────────────────────
    def _mark(self, convs: list[dict], action: str, undo: bool = True) -> None:
        """Apply a status/read action to conversations: optimistic local update +
        one provider RPC per account."""
        if not convs:
            return
        for conv in convs:
            self.app.db.apply_action_locally(conv["key"], action)
        for account_key, keys in self._by_account(convs).items():
            self.app.dispatch_action(account_key, keys, action)
            if undo:
                for key in keys:
                    self.app.push_undo(account_key, key, action, quiet=len(convs) > 1)
        if undo and len(convs) > 1:
            self.app.notify(f"{action.replace('_', ' ')} × {len(convs)} — ctrl+z to undo", timeout=7)
        self.selected_keys.clear()
        self.refresh_conversations(force=True)

    def action_archive(self) -> None:
        self._mark(self._targets(), ACTION_ARCHIVE)

    def action_spam(self) -> None:
        self._mark(self._targets(), ACTION_SPAM)

    def action_trash(self) -> None:
        self._mark(self._targets(), ACTION_TRASH)

    def action_mark_read(self) -> None:
        self._mark(self._targets(), ACTION_MARK_READ)

    def action_mark_unread(self) -> None:
        self._mark(self._targets(), ACTION_MARK_UNREAD)

    def action_move_inbox(self) -> None:
        self._mark(self._targets(), ACTION_UNARCHIVE)

    # ── move to folder ───────────────────────────────────────────────────────
    def action_move(self) -> None:
        targets = self._targets()
        if not targets:
            return
        accounts = {c["account_key"] for c in targets}
        if len(accounts) > 1:
            self.app.notify("Select conversations from one account to move them.", severity="warning")
            return
        account_key = targets[0]["account_key"]

        def _done(folder: Optional[str]) -> None:
            if folder:
                self.app.move_to_folder(account_key, [c["key"] for c in targets], folder)
                self.selected_keys.clear()
                self.refresh_conversations(force=True)

        self.app.open_folder_picker(account_key, _done)

    # ── triage (priority quadrants) ──────────────────────────────────────────
    def action_triage(self, quadrant: str) -> None:
        targets = self._targets()
        for account_key, keys in self._by_account(targets).items():
            self.app.apply_priority(account_key, keys, quadrant)
        self.selected_keys.clear()
        self.refresh_conversations(force=True)

    def action_triage_clear(self) -> None:
        targets = self._targets()
        for account_key, keys in self._by_account(targets).items():
            self.app.clear_priority(account_key, keys)
        self.selected_keys.clear()
        self.refresh_conversations(force=True)

    # ── Jev: Space · triage label · re-run ───────────────────────────────────
    def action_space(self) -> None:
        targets = self._targets()
        if not targets:
            return

        def _done(slug: Optional[str]) -> None:
            if slug:
                self.app.set_space([c["key"] for c in targets], slug)
                self.selected_keys.clear()
                self.refresh_conversations(force=True)

        self.app.open_space_picker(self.account_keys(), targets[0].get("space_slug"), _done)

    def action_label(self) -> None:
        targets = self._targets()
        if not targets:
            return

        def _done(slug: Optional[str]) -> None:
            if slug:
                self.app.set_label([c["key"] for c in targets], slug)
                self.selected_keys.clear()
                self.refresh_conversations(force=True)

        self.app.open_label_picker(self.account_keys(), targets[0].get("triage_label"), _done)

    def action_retriage(self) -> None:
        for conv in self._targets():
            self.app.retriage(conv["key"])

    # ── actions menu / view source ───────────────────────────────────────────
    def action_menu(self) -> None:
        conv = self._selected_conv()
        if conv:
            self.app.open_actions_menu(self, conv, selected=len(self.selected_keys), has_invite=bool(self.invite))

    def action_view_source(self) -> None:
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        target = self._last_inbound()
        if target:
            self.app.open_source(target["account_key"], target["key"])

    # ── compose ───────────────────────────────────────────────────────────
    async def _semantic_search(self, scope: tuple) -> None:
        query, keys = scope[0], list(scope[1])
        try:
            hits = await self.app.bus.call("vector_search", {"query": query, "limit": 50}) or []
        except Exception as e:  # noqa: BLE001 — e.g. the daemon (not the desktop app) hosts
            self.app.notify(f"Semantic search: {e}", severity="warning")
            hits = []
        rows, seen = [], set()
        for h in hits:
            ck = h.get("conversation_key")
            if ck and ck not in seen:
                seen.add(ck)
                row = self.app.db.conversation(keys, ck)
                if row:
                    rows.append(row)
        if self._semantic_for == scope:
            self._semantic_rows = rows
            self.refresh_conversations(force=True)

    def _thread_text(self, limit: int = 6) -> str:
        """The newest messages as plain text, oldest first — the AI prompt context."""
        parts = []
        for m in self.current_messages[-limit:]:
            parts.append(f"From: {m.get('from_address') or ''}\n{message_text(m).strip()}")
        return "\n\n---\n\n".join(parts)

    def action_summarize(self) -> None:
        """The desktop's AI summary panel: summarize the open thread on demand."""
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        text = self._thread_text()

        async def _run() -> None:
            self.app.notify("Summarizing…", timeout=2)
            try:
                summary = await self.app.bus.call("generative_summarize", {"text": text}, timeout=120)
            except Exception as e:  # noqa: BLE001
                self.app.notify(f"Summary: {e}", severity="warning")
                return
            from .modals import SourceModal

            self.app.push_screen(SourceModal(f"Summary — {conv.get('subject') or ''}\n\n{summary}"))

        self.run_worker(_run(), group="ai", exclusive=True)

    def action_images(self) -> None:
        """The thread's remote images, fetched privately through the Rails image
        proxy (like the desktop) and drawn inline."""
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        from .remoteimages import remote_images

        images = [img for m in self.current_messages for img in remote_images(m.get("body_html"))]
        if not images:
            self.app.notify("No remote images in this conversation.")
            return
        from .modals import PickerModal

        self.app.push_screen(PickerModal("Images (loaded privately via inbox2)", images),
                             lambda url: self.app.run_worker(self._show_image(url), name="img") if url else None)

    async def _show_image(self, url: str) -> None:
        import asyncio

        from .remoteimages import fetch_via_proxy
        from .whatsapp import MediaPreviewModal

        try:
            token = await self.app.bus.call("get_rails_token", {})
        except Exception:  # noqa: BLE001
            token = None
        if not token:
            self.app.notify("Images load through inbox2's privacy proxy — sign in to inbox2 in the desktop app first.",
                            severity="warning")
            return
        try:
            path = await asyncio.to_thread(fetch_via_proxy, url, token)
            pixels = MediaPreviewModal.render_image(path, max(20, self.app.size.width - 8), max(10, self.app.size.height - 6))
        except Exception as e:  # noqa: BLE001 — host refused the proxy, SVG, odd format
            self.app.notify(f"Couldn't load that image privately: {e}", severity="warning")
            return
        self.app.push_screen(MediaPreviewModal(path, pixels))

    def action_send_to(self) -> None:
        """Send to… (Linear, GitHub, Jira, HubSpot, Notion) — draft-only, like the desktop."""
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        from .sendto import SendToModal, item_from_conversation

        detail = (self.app.db.conversation_summary(conv["key"]).get("ai_summary_medium")
                  or " ".join(message_text(self._last_inbound() or {}).split())[:600])
        self.app.push_screen(SendToModal(item_from_conversation(conv, detail)))

    def action_smart_reply(self) -> None:
        """The desktop's smart-reply chips: pick one, it opens in the composer."""
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        target = self._last_inbound()
        if not target:
            return
        sender = _display_name(target.get("from_address")) or target.get("from_address") or ""

        async def _run() -> None:
            try:
                replies = await self.app.bus.call(
                    "generative_smart_replies", {"text": message_text(target), "sender_name": sender}, timeout=120)
            except Exception as e:  # noqa: BLE001
                self.app.notify(f"Smart replies: {e}", severity="warning")
                return
            if not replies:
                self.app.notify("No suggestions for this one.")
                return
            from .modals import PickerModal

            def _use(text: Optional[str]) -> None:
                if not text:
                    return
                current = self._selected_conv()
                if not current or current["key"] != conv["key"]:  # moved on: not this thread's reply
                    self.app.notify("Selection changed — smart reply discarded.", severity="warning")
                    return
                self._open_compose("reply", text)

            self.app.push_screen(PickerModal("Smart reply", [(r, r) for r in replies]), _use)

        self.run_worker(_run(), group="ai", exclusive=True)

    def _last_inbound(self) -> Optional[dict]:
        for m in reversed(self.current_messages):
            if m.get("is_inbound"):
                return m
        return self.current_messages[-1] if self.current_messages else None

    def action_reply(self) -> None:
        self._open_compose("reply")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "search":
            if self._search_timer is not None:
                self._search_timer.stop()
                self._search_timer = None
            self.search_query = event.value.strip()
            self.refresh_conversations(force=True)
            self.query_one("#conv-table", DataTable).focus()

    def action_reply_all(self) -> None:
        self._open_compose("reply_all")

    def action_forward(self) -> None:
        self._open_compose("forward")

    def _open_compose(self, mode: str, text: str = "") -> None:
        conv = self._selected_conv()
        if not conv:
            return
        if not self.current_messages:
            self.current_messages = self.app.db.conversation_messages(conv["key"])
        target = self._last_inbound()
        self_addr = self.app._self_address(conv["account_key"], target)
        sig = self.app.signature_block()
        if mode in ("reply", "reply_all") and target:
            draft = {
                "account_key": conv["account_key"],
                "from_address": self_addr,
                "to": target.get("from_address", "") if mode == "reply" else drafts.reply_all_recipients(target, self_addr),
                "subject": drafts.reply_subject(conv.get("subject")),
                "body": text + sig + drafts.quote_reply(target),
                "reply_to_message_key": target.get("key"),
                "conversation_key": conv["key"],
                "focus": "body",
            }
            self.app.open_compose(draft, "Reply" if mode == "reply" else "Reply all")
        elif mode == "forward":
            draft = {
                "account_key": conv["account_key"],
                "from_address": self_addr,
                "to": "",
                "subject": drafts.forward_subject(conv.get("subject")),
                "body": sig + drafts.forward_chain(self.current_messages),
                "focus": "to",
            }
            self.run_worker(self._forward_with_files(conv, draft), name="forward")

    async def _forward_with_files(self, conv: dict, draft: dict) -> None:
        message_keys = {m["key"] for m in self.current_messages}
        if conv.get("has_attachment") and not self.attachments:  # f pressed before the thread finished loading
            await self._hydrate_thread(conv["key"], True)
        if self.selected_key != conv["key"]:  # moved on: self.attachments is another thread's now
            self.app.notify("Selection changed — forward cancelled.", severity="warning")
            return
        files = [a for a in self.attachments if a["message_key"] in message_keys]
        if files:
            self.app.notify("Fetching attachments…")
        paths, missed = await self.app.fetch_for_forward(files)
        draft["attachments"] = format_attachment_paths(paths)
        self.app.open_compose(draft, "Forward")
        if missed:
            self.app.notify(f"Not attached: {', '.join(missed)}", severity="warning")


class CalendarScreen(Screen):
    """Calendar: month / week / work week / day / agenda lists (the desktop's
    FullCalendar views as keyboard-friendly day-grouped lists) with
    create/edit/delete/RSVP."""

    DEFAULT_CSS = """
    CalendarScreen { layout: vertical; }
    #cal-header { height: 1; background: $panel; }
    #cal-brand { width: auto; padding: 0 1; }
    #cal-brand-sep { width: auto; color: $text-muted; }
    #cal-header-text { width: 1fr; }
    #cal-views { width: auto; padding: 0 1; color: $text-muted; }
    #cal-table { height: 1fr; }
    """

    BINDINGS = [
        Binding("left", "prev_period", "Prev"),
        Binding("right", "next_period", "Next"),
        Binding("t", "today", "Today"),
        Binding("m", f"view('{CAL_MONTH}')", "Month"),
        Binding("w", f"view('{CAL_WEEK}')", "Week"),
        Binding("W", f"view('{CAL_WORKWEEK}')", "Work week", show=False),
        Binding("d", f"view('{CAL_DAY}')", "Day"),
        Binding("a", f"view('{CAL_AGENDA}')", "Agenda"),
        Binding("n", "new_event", "New"),
        Binding("enter", "detail", "Details", show=False),
        Binding("e", "edit_event", "Edit"),
        Binding("D", "delete_event", "Delete", show=False),
        Binding("y", "rsvp_accept", "Accept", show=False),
        Binding("Y", "rsvp_tentative", "Tentative", show=False),
        Binding("x", "rsvp_decline", "Decline", show=False),
        Binding("question_mark", "noop", "", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.anchor = dt.date.today()
        self.view = CAL_MONTH
        self.event_by_key: dict[str, dict] = {}
        self._row_keys: list[str] = []
        self._last_sig: Optional[tuple] = None

    def compose(self) -> ComposeResult:
        with Horizontal(id="cal-header"):
            yield Static(brand_text(self.app), id="cal-brand")
            yield Static("│", id="cal-brand-sep")
            yield Static(self._header(), id="cal-header-text")
            yield Static(self._views_text(), id="cal-views")
        table = DataTable(id="cal-table", cursor_type="row", zebra_stripes=True)
        table.add_columns("When", "Title", "Calendar", "Where", "Status")
        yield table
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_events()
        self.query_one("#cal-table", DataTable).focus()

    # ── period window per view ───────────────────────────────────────────────
    def _window(self) -> tuple[dt.date, dt.date]:
        a = self.anchor
        if self.view == CAL_MONTH:
            start = a.replace(day=1)
            end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(month=start.month + 1)
        elif self.view in (CAL_WEEK, CAL_WORKWEEK):
            start = a - dt.timedelta(days=a.weekday())  # Monday
            end = start + dt.timedelta(days=5 if self.view == CAL_WORKWEEK else 7)
        elif self.view == CAL_DAY:
            start, end = a, a + dt.timedelta(days=1)
        else:  # agenda: the next 7 days from the anchor
            start, end = a, a + dt.timedelta(days=7)
        return start, end

    def _step(self) -> dt.timedelta | None:
        return {CAL_WEEK: dt.timedelta(days=7), CAL_WORKWEEK: dt.timedelta(days=7),
                CAL_DAY: dt.timedelta(days=1), CAL_AGENDA: dt.timedelta(days=7)}.get(self.view)

    def _header(self) -> str:
        start, end = self._window()
        last = end - dt.timedelta(days=1)
        if self.view == CAL_MONTH:
            label = start.strftime("%B %Y")
        elif self.view == CAL_DAY:
            label = start.strftime("%A %-d %B %Y")
        else:
            label = f"{start.strftime('%-d %b')} – {last.strftime('%-d %b %Y')}"
        return f" Calendar — {label}"

    def _views_text(self) -> Text:
        t = Text()
        for v in CAL_VIEWS:
            key = {CAL_MONTH: "m", CAL_WEEK: "w", CAL_WORKWEEK: "W", CAL_DAY: "d", CAL_AGENDA: "a"}[v]
            t.append(f" {key}:{v} ", style=f"bold {_accent(self.app)}" if v == self.view else _muted(self.app))
        return t

    def account_keys(self) -> list[str]:
        return [a["key"] for a in self.app.accounts]

    def refresh_events(self) -> None:
        start, end = self._window()
        rows = self.app.db.events(
            self.account_keys(),
            start.isoformat(),
            end.isoformat() + "T00:00:00Z",
        )
        sig = (self.view, self.anchor, tuple((r["key"], r["title"], r["start_at"], r["status"]) for r in rows))
        if sig == self._last_sig:
            return
        self._last_sig = sig
        self.query_one("#cal-header-text", Static).update(self._header())
        self.query_one("#cal-views", Static).update(self._views_text())
        table = self.query_one("#cal-table", DataTable)
        table.clear()
        self.event_by_key = {}
        self._row_keys = []
        today = dt.date.today()
        day: Optional[str] = None
        for r in rows:
            r_day = (r["start_at"] or "")[:10]
            if self.view != CAL_DAY and r_day != day:
                day = r_day
                try:
                    d = dt.date.fromisoformat(r_day)
                    label = d.strftime("%a %-d %b") + ("  · today" if d == today else "")
                except ValueError:
                    label = r_day
                table.add_row(Text(label, style=f"bold {_accent(self.app) if d == today else _muted(self.app)}"), "", "", "", "", key=f"day:{r_day}")
                self._row_keys.append(f"day:{r_day}")
            self.event_by_key[r["key"]] = r
            self._row_keys.append(r["key"])
            if r.get("all_day"):
                when = "all day"
            else:
                when = f"{r['start_at'][11:16]}–{(r.get('end_at') or '')[11:16]}"
            table.add_row(
                Text(when, style=_muted(self.app)),
                _short(r["title"], 40),
                _short(r.get("calendar_name"), 18),
                _short(r.get("location"), 20),
                r.get("status") or "",
                key=r["key"],
            )

    def _selected_event(self) -> Optional[dict]:
        table = self.query_one("#cal-table", DataTable)
        idx = table.cursor_row
        if idx is None or not (0 <= idx < len(self._row_keys)):
            return None
        return self.event_by_key.get(self._row_keys[idx])

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        # DataTable consumes Enter at the widget level; open the event's card.
        self.action_detail()

    def action_view(self, view: str) -> None:
        if view in CAL_VIEWS:
            self.view = view
            self.refresh_events()

    def action_prev_period(self) -> None:
        step = self._step()
        if step:
            self.anchor -= step
        else:
            self.anchor = (self.anchor.replace(day=1) - dt.timedelta(days=1)).replace(day=1)
        self.refresh_events()

    def action_next_period(self) -> None:
        step = self._step()
        if step:
            self.anchor += step
        else:
            self.anchor = self._window()[1]
        self.refresh_events()

    def action_today(self) -> None:
        self.anchor = dt.date.today()
        self.refresh_events()

    def action_new_event(self) -> None:
        self.app.open_event_editor(None)

    def action_detail(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.open_event_detail(ev)

    def action_edit_event(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.open_event_editor(ev)

    def action_delete_event(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.delete_event(ev)

    def action_rsvp_accept(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.rsvp_event(ev, RSVP_ACCEPTED)

    def action_rsvp_tentative(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.rsvp_event(ev, RSVP_TENTATIVE)

    def action_rsvp_decline(self) -> None:
        ev = self._selected_event()
        if ev:
            self.app.rsvp_event(ev, RSVP_DECLINED)

    def action_noop(self) -> None:
        pass

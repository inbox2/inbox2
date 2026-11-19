"""Shared constants for the Inbox2 TUI.

Mirrors the Rust/JS sources so we never hardcode duplicate enum strings:
  - conversation actions + their inverses come from
    `ui/desktop/src-tauri/src/sync/interactive.rs`,
  - conversation status values from the local SQLite schema
    (`001_create_schema.sql`: conversations.status),
  - the keymap registry mirrors `ui/web/src/lib/shortcuts.js` +
    `docs/Keyboard-Shortcuts.md`.
"""

from __future__ import annotations

# ── Theme ────────────────────────────────────────────────────────────────────
# Textual ships the Catppuccin palette as a built-in theme.
DEFAULT_THEME = "catppuccin-mocha"

# ── Branding ─────────────────────────────────────────────────────────────────
# ASCII fallback logo (an isometric cube, echoing the desktop app icon). Shown on
# the welcome screen when no real image can be rendered (see screens.logo_renderable).
LOGO_ASCII = r"""
      ┌───────────┐
     ╱           ╱│
    ╱  i n b o x╱ │
   ┌───────────┐  │
   │           │  │
   │     2     │  ╱
   │           │ ╱
   └───────────┘╱
"""

# ── Conversation status (conversations.status) ──────────────────────────────
STATUS_OPEN = "open"
STATUS_ARCHIVED = "archived"
STATUS_SPAM = "spam"
STATUS_TRASH = "trash"

# Non-status folder views. Derived from synced provider folder membership
# (message_provider_state.folder_key → external_folders.well_known_role), the
# same authoritative source the desktop uses (useFolderViews.js `well_known_role`).
# These string values ARE the `well_known_role` values, so they double as the SQL
# filter in db.conversations_with_message.
VIEW_SENT = "sent"
VIEW_DRAFTS = "drafts"
# Triage (Eisenhower quadrant) sidebar views — the terminal equivalent of the
# desktop's LABELS section (Delegate · Schedule · Later · Priority). The view kind
# is f"{VIEW_TRIAGE_PREFIX}{quadrant_key}"; the list is then filtered by the
# quadrant's (urgent, important) flags (see db.conversations_by_quadrant).
VIEW_TRIAGE_PREFIX = "triage:"
# Other sidebar view kinds, each a prefix + the thing's key/slug:
VIEW_SPACE_PREFIX = "space:"        # a Jev Space slug (conversations.space_slug)
VIEW_TLABEL_PREFIX = "tlabel:"      # a triage label slug (conversations.triage_label)
VIEW_LABEL_PREFIX = "label:"        # a provider label/folder (external_folders.key)
VIEW_OUTBOX = "outbox"              # the durable send/draft queue (outbox_messages)
# The Jev holding pen: a thread Jev couldn't place (or the user parked) lives here.
SPACE_TRIAGE = ("triage", "Triage")

# Folders shown in the per-channel / unified left list, in the desktop's order
# and labels (InboxSidebar.jsx: Inbox · Sent · Drafts · Archived · Spam · Trash).
# Each entry is (label, view kind, icon): the view kind is either a conversation
# status or one of the VIEW_* message-flag views above. Icons are single-width
# monochrome glyphs — the terminal stand-in for the desktop's SF Symbols (tray /
# paperplane / doc / archivebox / nosign / trash).
FOLDERS = [
    ("Inbox", STATUS_OPEN, "□"),
    ("Sent", VIEW_SENT, "↗"),
    ("Drafts", VIEW_DRAFTS, "✎"),
    ("Archived", STATUS_ARCHIVED, "▣"),
    ("Spam", STATUS_SPAM, "⊘"),
    ("Trash", STATUS_TRASH, "✕"),
]

# ── Conversation actions (provider write-back verbs) ─────────────────────────
ACTION_ARCHIVE = "archive"
ACTION_TRASH = "trash"
ACTION_SPAM = "spam"
ACTION_MARK_READ = "mark_read"
ACTION_MARK_UNREAD = "mark_unread"
# provider_type of an inbox2-hosted org mirrored on this device (docs/MX-Sync.md) —
# the same value the web app uses for MX tabs.
PROVIDER_INBOX2 = "inbox2"
# MX threads have no provider folders to move between: every restore verb is "open".
MX_ACTION = {"unarchive": "open", "untrash": "open", "unspam": "open"}

# Statuses that keep a thread out of the inbox (web lib/conversationStatus.js
# INBOX_HIDDEN_STATUSES): the Inbox is everything else that sits in the inbox folder.
INBOX_HIDDEN_STATUSES = (STATUS_TRASH, STATUS_SPAM, STATUS_ARCHIVED)
# Folder role of a provider inbox (external_folders.well_known_role).
FOLDER_ROLE_INBOX = "inbox"
# MX priority lives in tags (web lib/priority.js): the quadrant an org thread sits in.
MX_TAG_URGENT = "Urgent"
MX_TAG_IMPORTANT = "Important"
MX_TAG_LATER = "Later"

ACTION_UNARCHIVE = "unarchive"
# Lore's per-member tick on a shared domain (api LoreMemberDone).
ACTION_LORE_DONE = "lore_done"
ACTION_LORE_UNDONE = "lore_undone"
ACTION_UNTRASH = "untrash"
ACTION_UNSPAM = "unspam"

# ── Mark-as-read mechanism (mirrors Outlook + web lib/markReadPref.js) ───────
# When the conversation shown in the reading pane is automatically marked read.
MARK_READ_MODE_IMMEDIATE = "immediate"            # as soon as it's highlighted
MARK_READ_MODE_DELAY = "delay"                    # after it's shown N seconds
MARK_READ_MODE_SELECTION_CHANGE = "selection-change"  # when selection moves off it
MARK_READ_MODE_NEVER = "never"                    # manual only
MARK_READ_MODES = (
    MARK_READ_MODE_IMMEDIATE,
    MARK_READ_MODE_DELAY,
    MARK_READ_MODE_SELECTION_CHANGE,
    MARK_READ_MODE_NEVER,
)
DEFAULT_MARK_READ_MODE = MARK_READ_MODE_DELAY     # desktop-sized: keyboard nav → dwell avoids accidental reads
DEFAULT_MARK_READ_DELAY = 5.0                     # seconds

# Action → resulting conversation status, for the optimistic local update the UI
# applies before the provider write-back lands (same pattern as the web app).
ACTION_TO_STATUS = {
    ACTION_ARCHIVE: STATUS_ARCHIVED,
    ACTION_TRASH: STATUS_TRASH,
    ACTION_SPAM: STATUS_SPAM,
    ACTION_UNARCHIVE: STATUS_OPEN,
    ACTION_UNTRASH: STATUS_OPEN,
    ACTION_UNSPAM: STATUS_OPEN,
}

# Inverse action for undo (see useUndoStack.js / Keyboard-Shortcuts.md "Undo").
INVERSE_ACTION = {
    ACTION_ARCHIVE: ACTION_UNARCHIVE,
    ACTION_TRASH: ACTION_UNTRASH,
    ACTION_SPAM: ACTION_UNSPAM,
    ACTION_MARK_READ: ACTION_MARK_UNREAD,
    ACTION_MARK_UNREAD: ACTION_MARK_READ,
    ACTION_LORE_DONE: ACTION_LORE_UNDONE,
    ACTION_LORE_UNDONE: ACTION_LORE_DONE,
}

# ── Sort order (mirrors ui/web/src/hooks/useSortOrder.js) ─────────────────────
SORT_NEWEST = "newest"
SORT_OLDEST = "oldest"
SORT_UNREAD_FIRST = "unread-first"
SORT_ORDERS = (SORT_NEWEST, SORT_OLDEST, SORT_UNREAD_FIRST)
SORT_LABELS = {SORT_NEWEST: "Newest first", SORT_OLDEST: "Oldest first", SORT_UNREAD_FIRST: "Unread first"}

# ── Triage labels (docs/Triage.md; mirrors core/src/triage.rs TriageLabel) ────
# The built-in label slugs → display names. An org/user can add custom labels
# (engine_settings.triage_labels / mx_directory triage_labels); those are read
# at runtime and merged over these.
TRIAGE_LABELS = {
    "needs_answer": "Needs answer",
    "needs_answer_other": "Reply from someone else",
    "waiting_reply": "Waiting for reply",
    "needs_approval": "Needs approval",
    "scheduling": "Scheduling",
    "action_required": "Action required",
    "fyi": "FYI",
    "resolved": "Resolved",
    "payment_due": "To pay",
    "to_review": "To review",
    "read_later": "Read later",
    "receipt": "Receipt",
    "notification": "Notification",
}
# Jev priority score thresholds (0–4): the web shows an Urgent chip ≥ 3.5 and a
# High chip ≥ 2.5 (docs/Triage.md).
TRIAGE_PRIORITY_URGENT = 3.5
TRIAGE_PRIORITY_HIGH = 2.5

# ── Outbox (mirrors core/src/sync/model.rs OutboxStatus / OutboxKind) ─────────
OUTBOX_PENDING = "pending"
OUTBOX_SENDING = "sending"
OUTBOX_SENT = "sent"
OUTBOX_FAILED = "failed"
OUTBOX_KIND_SEND = "send"
OUTBOX_KIND_DRAFT = "draft"
MX_OUTBOX_PREFIX = "mxo_"  # keys of engine `mx_outbox` rows

# ── Formatting helpers ───────────────────────────────────────────────────────
def human_size(num_bytes: int | None) -> str:
    """Human-readable byte count for attachment sizes (e.g. '240.5 KB')."""
    n = float(num_bytes or 0)
    if n < 1024:
        return f"{int(n)} B"
    for unit in ("KB", "MB", "GB"):
        n /= 1024
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
    return f"{n:.1f} GB"


# ── App sections ─────────────────────────────────────────────────────────────
SECTION_MAIL = "mail"
SECTION_CALENDAR = "calendar"
SECTION_LORE = "lore"            # open workload + people/orgs (docs/Ontology.md, docs/plans/lore.md)
SECTION_RULES = "rules"          # local rules + agent runs (docs/Agentic-Filters.md)
SECTION_WHATSAPP = "whatsapp"    # local WhatsApp, macOS (docs/Local-WhatsApp.md)
SECTION_ORDER = [SECTION_MAIL, SECTION_CALENDAR, SECTION_LORE, SECTION_RULES, SECTION_WHATSAPP]
SECTION_LABELS = {
    SECTION_MAIL: "Mail", SECTION_CALENDAR: "Calendar", SECTION_LORE: "Lore",
    SECTION_RULES: "Rules", SECTION_WHATSAPP: "WhatsApp",
}

# ── Triage / Eisenhower quadrants (mirrors ui/web/src/lib/priority.js) ────────
# Two boolean dimensions (urgent, important) compose into four quadrants. `mark`
# is the single-width gutter glyph; `color` matches the web quadrant colors.
QUADRANTS = {
    "DO_FIRST": {"urgent": True, "important": True, "label": "Priority", "mark": "P", "color": "#e06060"},
    "DELEGATE": {"urgent": True, "important": False, "label": "Delegate", "mark": "D", "color": "#d4a843"},
    "SCHEDULE": {"urgent": False, "important": True, "label": "Schedule", "mark": "S", "color": "#6ea8d9"},
    "LATER": {"urgent": False, "important": False, "label": "Later", "mark": "L", "color": "#6b7280"},
}
QUADRANT_ORDER = ["DO_FIRST", "DELEGATE", "SCHEDULE", "LATER"]


def quadrant_for(urgent, important) -> str | None:
    """The quadrant key for a conversation's priority flags. Returns None when
    neither flag is set (no triage) — matching the web's getConvQuadrant."""
    if not urgent and not important:
        return None
    for key, q in QUADRANTS.items():
        if q["urgent"] == bool(urgent) and q["important"] == bool(important):
            return key
    return None


# ── RSVP responses (calendar + emailed invites) ──────────────────────────────
RSVP_ACCEPTED = "accepted"
RSVP_DECLINED = "declined"
RSVP_TENTATIVE = "tentative"
RSVP_LABELS = {RSVP_ACCEPTED: "Accept", RSVP_TENTATIVE: "Tentative", RSVP_DECLINED: "Decline"}

# ── Calendar views (mirrors ui/web/src/pages/calendar/CalendarPage.jsx VIEW_MAP) ─
CAL_MONTH = "month"
CAL_WEEK = "week"
CAL_WORKWEEK = "workweek"
CAL_DAY = "day"
CAL_AGENDA = "agenda"
CAL_VIEWS = (CAL_MONTH, CAL_WEEK, CAL_WORKWEEK, CAL_DAY, CAL_AGENDA)

# ── Keyboard shortcuts registry ──────────────────────────────────────────────
# Single source of truth for the help overlay. Each entry: (keys, label, group).
# Textual Binding objects are derived from these in the screens. Mirrors
# docs/Keyboard-Shortcuts.md (with terminal-appropriate substitutions: ctrl for
# the desktop's cmd, function keys for channel switching).
SHORTCUTS = [
    # Message actions
    ("r", "Reply", "Message"),
    ("a", "Reply all", "Message"),
    ("f", "Forward", "Message"),
    ("e", "Archive", "Message"),
    ("shift+i", "Mark read", "Message"),
    ("shift+u", "Mark unread", "Message"),
    ("!", "Spam", "Message"),
    ("delete / backspace", "Trash", "Message"),
    ("o", "Attachments (view · save)", "Message"),
    ("v", "Move to folder…", "Message"),
    (".", "Actions menu", "Message"),
    ("ctrl+u", "View source", "Message"),
    ("shift+s", "Summarize thread (AI)", "Message"),
    ("shift+r", "Smart reply suggestions (AI)", "Message"),
    ("shift+t", "Send to… (Linear · GitHub · Jira · HubSpot · Notion)", "Message"),
    ("i", "Images in the email (loaded privately, drawn inline)", "Message"),
    # List (selection · filters)
    ("x", "Select / deselect conversation", "List"),
    ("ctrl+a", "Select all", "List"),
    ("u", "Toggle unread only", "List"),
    ("shift+o", "Cycle sort order", "List"),
    # Triage (Eisenhower quadrants) — alt-combos, app-specific (no Gmail equivalent).
    ("alt+p", "Triage: Priority", "Triage"),
    ("alt+d", "Triage: Delegate", "Triage"),
    ("alt+s", "Triage: Schedule", "Triage"),
    ("alt+l", "Triage: Later", "Triage"),
    ("alt+x", "Triage: Untag", "Triage"),
    ("alt+m", "Move to Space…", "Triage"),
    ("alt+t", "Triage label…", "Triage"),
    ("alt+j", "Re-run Jev", "Triage"),
    # Navigation
    ("j / k · down / up", "Move (conversations · messages & sections in thread)", "Navigation"),
    ("enter", "Open conversation", "Navigation"),
    ("right", "Step folders → list → message thread", "Navigation"),
    ("left", "Step back a zone (thread → list → folders)", "Navigation"),
    ("enter / space", "Expand/collapse message · toggle section · open link / attachments", "Navigation"),
    ("j / k · up / down", "Step inline links within a focused message body", "Navigation"),
    ("escape", "Back / clear / close", "Navigation"),
    # Composer
    ("ctrl+enter", "Send", "Composer"),
    ("ctrl+d", "Save draft", "Composer"),
    ("ctrl+g", "Draft with AI (what you typed = the instruction)", "Composer"),
    ("escape", "Close (save / discard if dirty)", "Composer"),
    # Channels & sections
    ("F1", "Unified (all channels)", "Channels"),
    ("F2…F9", "Switch to channel N", "Channels"),
    ("ctrl+left / ctrl+right", "Cycle Mail · Calendar · Lore · Rules · WhatsApp", "Sections"),
    ("g then m / c / l / r / w", "Go to Mail / Calendar / Lore / Rules / WhatsApp", "Sections"),
    # Global
    ("c", "Compose", "Global"),
    ("s", "Sync (resync all channels)", "Global"),
    (",", "Settings", "Global"),
    ("/", "Search (start with ~ for semantic search)", "Global"),
    ("ctrl+k", "Command palette", "Global"),
    ("ctrl+z", "Undo", "Global"),
    ("ctrl+y / ctrl+shift+z", "Redo", "Global"),
    ("?", "Keyboard shortcuts", "Global"),
    # Calendar
    ("left / right", "Previous / next period", "Calendar"),
    ("t", "Today", "Calendar"),
    ("m / w / shift+w / d / a", "Month / week / work week / day / agenda", "Calendar"),
    ("n", "New event", "Calendar"),
    ("enter", "Event details", "Calendar"),
    ("e", "Edit event", "Calendar"),
    ("shift+d", "Delete event", "Calendar"),
    ("y / shift+y / x", "RSVP accept / tentative / decline", "Calendar"),
    # Lore
    ("space / x", "Tick off (archive) · restore in History", "Lore"),
    ("enter", "Open thread (or the chat in WhatsApp)", "Lore"),
    ("h", "Handled for you: archive FYI/receipts, trash notifications", "Lore"),
    ("shift+h", "History (recently done)", "Lore"),
    ("tab", "Today → People & orgs → Graph", "Lore"),
    ("j / k · enter (Graph)", "Pick a node · open its page", "Lore"),
    ("t", "Send to… (a connected app)", "Lore"),
    ("enter (entity page)", "Open a thread · step to a connection (the graph)", "Lore"),
    ("1…5", "People: all / orgs / people / products / projects", "Lore"),
    # Rules
    ("1 / 2 / 3 / 4", "Rules / Runs / Approvals / Agents", "Rules"),
    ("n · e · shift+d", "New · edit · delete rule", "Rules"),
    ("space", "Rule on/off · agent on/off", "Rules"),
    ("p · shift+a", "Preview matches · apply to existing mail", "Rules"),
    ("f · r", "Runs: failed only · retry", "Rules"),
    ("y / n", "Approve / deny an agent action", "Rules"),
    # WhatsApp
    ("i · enter", "Focus composer · send (in composer) / open chat", "WhatsApp"),
    ("ctrl+o", "Attach files", "WhatsApp"),
    ("/ · o · shift+a", "Search · open in WhatsApp · show archived", "WhatsApp"),
    ("m", "Media: open or save to Downloads", "WhatsApp"),
    # Accounts (palette › Accounts)
    ("a · r · shift+d", "Add (Gmail · Microsoft · IMAP · WhatsApp Business · Messenger · Instagram) · reconnect · remove", "Accounts"),
    ("ctrl+g (in Settings)", "Intelligence: Jev/OpenAI keys · triage window · Lore auto · connected apps · about", "Accounts"),
    ("shift+r · d · l · t", "Resync · diagnostics · sync log · open tracking", "Accounts"),
]

SHORTCUT_GROUPS = ["Message", "List", "Triage", "Navigation", "Composer", "Channels", "Sections", "Global", "Calendar",
                   "Lore", "Rules", "WhatsApp", "Accounts"]

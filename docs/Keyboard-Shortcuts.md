# Keyboard Shortcuts

Canonical reference for keyboard shortcuts in the web/desktop client. The scheme follows
Gmail / Outlook-web conventions for the universal actions; the Eisenhower triage actions use
`Alt`-combos (app-specific, no Gmail equivalent).

There is a **single source of truth**: `ui/web/src/lib/shortcuts.js`. That registry drives
three consumers at once — the keydown dispatcher, the hint shown in every action menu, and the
`?` help overlay. Add a shortcut in one place and all three update.

## Shortcuts

### Message actions
Fire only when a conversation is selected/focused **and** the user is not typing in an
input/textarea/contentEditable **and** no overlay (modal, command palette, compose window) is
open.

| Key | Action | Registry id | Dispatch |
|-----|--------|-------------|----------|
| `R` | Reply | `reply` | draft (`useDraftActions.reply`) |
| `A` | Reply All | `reply-all` | draft (`useDraftActions.replyAll`) |
| `F` | Forward | `forward` | draft (`useDraftActions.forward`) |
| `⇧I` | Mark read | `mark_read` | status action `mark_read` |
| `⇧U` | Mark unread | `mark_unread` | status action `mark_unread` |
| `E` | Archive | `archive` | status action `archive` |
| `!` | Spam | `spam` | status action `spam` |
| `⌫` / `Delete` | Delete (trash) | `trash` | see note below |

### Triage (Eisenhower quadrants)
Quadrant keys/labels/icons come from `ui/web/src/lib/priority.js` (`QUADRANTS`) — never
hardcoded here.

| Key | Action | Registry id | Dispatch |
|-----|--------|-------------|----------|
| `⌥P` | Priority (Do First) | `triage_DO_FIRST` | triage `DO_FIRST` |
| `⌥D` | Delegate | `triage_DELEGATE` | triage `DELEGATE` |
| `⌥S` | Schedule | `triage_SCHEDULE` | triage `SCHEDULE` |
| `⌥L` | Later | `triage_LATER` | triage `LATER` |
| `⌥X` | Untag | `triage_clear` | triage `null` (clears flags) |

### Navigation & global (pre-existing)
These are handled by other code (listed under "Where each is handled") and appear in the help
overlay for discoverability.

| Key | Action |
|-----|--------|
| `J` / `↓` | Next conversation |
| `K` / `↑` | Previous conversation |
| `→` | Open / focus messages · `←` back a zone |
| `⇧↑` / `⇧↓` | Extend list selection |
| `Space` | Expand/collapse focused message |
| `Esc` | Back / clear selection / close overlay |
| `⌘Z` / `Ctrl Z` | Undo last action |
| `⌘Y` / `⌘⇧Z` | Redo |
| `C` | Compose |
| `S` | Sync / resync all channels |
| `,` | Settings |
| `/` | Focus search |
| `⌘K` / `Ctrl K` | Command palette |
| `⇧⌘D` / `Ctrl Shift D` | Demo data on / off (see below) |
| `?` | This shortcuts overlay |

## Where each is handled

| Concern | File |
|---------|------|
| Registry (keys, labels, matchers, hints) | `ui/web/src/lib/shortcuts.js` |
| Message-action dispatcher | `ui/web/src/hooks/useMessageActionShortcuts.js` |
| Reply/forward draft builders | `ui/web/src/hooks/useDraftActions.js`, `ui/web/src/lib/draftBuilders.js` |
| Mount point (binds the hook inside DraftProvider) | `ui/web/src/components/MessageShortcuts/MessageShortcuts.jsx` |
| `?` help overlay | `ui/web/src/components/ShortcutsHelp/`, `ui/web/src/hooks/useShortcutHelp.js` |
| Menu hint rendering | `ui/web/src/lib/conversationActions.js` (attaches `shortcut`), `DropdownMenu.jsx` / `ContextMenu.jsx` (render it) |
| List nav (`j/k`, arrows, Space, Esc) + `Backspace`/`Delete`=trash (channel view) | `ui/web/src/hooks/useInboxKeyboardNav.js` |
| `⌘P` palette (+ `⇧⌘D` demo data) | `GlobalCommandPalette` in `ui/web/src/routes.jsx` — mounted once, works on every screen |
| Palette actions a page can offer (compose, toggle unread, …) | `ui/web/src/stores/paletteStore.js` → `usePaletteActions` |
| `/` search / `C` compose | per-page effects + `ComposeWidgets` |
| `S` sync / `,` settings | `ui/web/src/components/Chrome/ChromeBar.jsx` (global keydown, mirrors the toolbar buttons) |
| `⌘Z` undo / `⌘Y`·`⌘⇧Z` redo | `ui/web/src/stores/undoStore.js` (global keydown + command history) |

### Per-view coverage
- **Channel / per-account view** (`pages/inbox/InboxPage.jsx` → `ConversationDetail`): all message + triage shortcuts; `Backspace`/`Delete`=trash via `useInboxKeyboardNav`.
- **Unified list view** (`pages/inbox/UnifiedInboxView.jsx`): all shortcuts, **list mode only** (grid view has no single selection). Triage maps the quadrant → `applyPriority`/`removePriority`; `Backspace`/`Delete`=trash is bound locally.
- **Search results** (`pages/search/SearchResultsView.jsx`): **reply / reply-all / forward + `?` only.** Status/triage/delete are out of scope (no result-mutation plumbing). Those keys are inert there.

## Demo mode (`⇧⌘D`)

For screenshots and live demos: every address, name, subject, snippet and body on its way to the
screen is swapped for a fictional stand-in, deterministically — one real address is always the same
fake person, so threads, Spaces and the channel tabs stay coherent. Counts, timestamps, read state
and attachments are untouched, so the app looks exactly as busy as it really is.

- **Nothing is written.** It rewrites the *reads*, at three chokepoints: `lib/db.js` (local channels,
  a Proxy over `select`), `lib/api.js` (MX — GETs only) and `hooks/useAccounts.js` (the channel tabs).
  Anything that slips through gets one more `scrubIfDemo()` call at its own source.
- The flag lives in **sessionStorage**: it survives the reload that applies it, and dies with the
  window — nobody comes back the next morning wondering where their mail went.
- Toggle with `⇧⌘D` or the palette's *Turn demo data on/off*. While it's on, the palette also offers
  **Demo: new email alert / meeting starting soon / meeting invitation** (`lib/demoNotifications.js`),
  so a notification can be made to land on cue during a demo.
- **Read-only while it's on.** Nothing leaves the machine: sending, provider write-backs
  (archive/read/priority/RSVP/calendar) and every MX write or upload are refused at their boundaries
  — `lib/providers/index.js` (`DEMO_BLOCKED`, the whole local-channel write surface), `lib/api.js`
  (non-GET; `/auth/*` still works so you can sign in) and `lib/mxWriteback.js` (enqueue **and** drain
  are paused — a 403 would read as a *permanent* failure and throw away actions queued before the
  demo). Sending shows the refusal in the compose window and keeps the draft.
  Local SQLite writes still happen, so clicking around behaves normally; the next real sync
  reconciles them, exactly as after any failed write-back. Mail already in the engine's outbox or
  its own write-back queue when you switched on still goes out — it was queued for real.
- Live provider reads are scrubbed too (`fetchMessage` bodies, the outbox, a parsed ICS invite), as
  are engine events (`sync-manager.js` — otherwise a real mail arriving mid-demo pops a notification
  with the real sender on it) and JSON blob columns (`calendar_events.metadata` hides the attendee
  list and the conference link). **Raw message source is hidden** on both paths, since real MIME
  headers are nothing a field-level scrub can fix.
- `scrub()` is **idempotent** — a value can pass more than one chokepoint, and re-hashing an
  already-fake value would rename the same person on a second screen.
- On desktop, an MX conversation action (archive/read/spam) does its local mirror write and reports
  success without calling the server, so a demo behaves normally; the next sync re-derives the
  mirror from the server. A **send** never does that — it fails loudly and keeps the draft. On the
  web build (no local mirror) every mutation is refused visibly.
- Nothing generated from demo text is persisted: AI summaries and sentiment/intent classification
  skip their SQLite write (`localData.persistConversationSummary`, `ai/useAIClassification`), or a
  demo would overwrite a real thread's summary with one about fictional people.
- Local search still matches the real text, not what's on screen.
- The mail itself is in `ui/web/src/lib/demoCorpus.js`: 18 subject/body **pairs**, two or three
  paragraphs each, picked by ONE hash — so a thread's subject, its list preview (the body's first
  sentence) and the open message all agree, and every `Re:` under one subject lands on the same
  thread. HTML bodies are rebuilt as real `<p>` paragraphs so the reading pane doesn't show one
  run-on block. Written in the register of the Enron corpus (`rake datasets:load[enron]`) — two or
  three short paragraphs, one concrete number, a hedge and an ask — but **not its text**: that
  corpus carries real names, real HR decisions about named employees, personal family mail and the
  odd slur, none of which belongs in a product screenshot.
- The field rules and the cast live in `ui/web/src/lib/demoData.js`.

## Undo / Redo

`⌘Z` undoes the most recent email action and `⌘Y` (or `⌘⇧Z`) redoes it. This is a global
command history (`ui/web/src/stores/undoStore.js`, Zustand) — the keydown listener is bound once
at module load (capture phase) and works in every view; it is skipped while typing so `⌘Z` stays
as text-undo in inputs/editors.

Every state-changing action is recorded by the **dispatcher**, so menus, context menus, keyboard
shortcuts, drag-drop, and the hover popup are all undoable with no per-caller code:
- Channel view → `ui/web/src/hooks/useConversationActions.js` (`executeAction`, `executePriority`).
- Unified view → `ui/web/src/hooks/useUnifiedInbox.js` (`performConversationAction`, `applyPriority`, `removePriority`).

Each dispatcher exposes a `{ record = true }` option; the undo/redo closures call the raw
(non-recording) inner functions so undoing never re-records. A new action clears the redo branch.
Reply/Forward are **not** undoable (they only open a draft — discard it to back out).

Reverse actions: archive/trash/spam restore to status `open` — org/MX accounts via the bulk
`open` endpoint, external (Gmail/Office365) accounts via the provider verbs
`unarchive`/`untrash`/`unspam` (`ui/desktop/src-tauri/src/sync/interactive.rs`). Mark read/unread
and triage are their own inverses. A 7-second `UndoToast` surfaces the most recent action; the
command history persists (capped ~50) for keyboard undo/redo.

## Conventions & gotchas

- **Alt combos match on `event.code`** (e.g. `KeyP`), not `event.key` — macOS Option emits
  special characters in `event.key`. Bare/Shift keys match on `event.key`.
- **`!` is matched by `event.key === '!'`**, not Shift+1, so it works regardless of layout.
- **`trash` is documented in the registry but has no live matcher.** `Backspace`/`Delete` is
  owned by `useInboxKeyboardNav` (channel view) and a local effect (unified list) to avoid
  double-binding a destructive action.
- **Overlay guard:** the dispatcher and `?` binding skip when any element with
  `[data-overlay-open]` is present. That attribute lives on the `Modal`, `CommandPalette`, and
  `ComposePopup` roots — so shortcuts are suppressed while composing or in a dialog.
- **Bulk (multi-select) menus** do not show hints — the shortcuts act on a single selected
  conversation.

## Adding a new shortcut

1. **Registry** — add an entry to `SHORTCUTS` in `ui/web/src/lib/shortcuts.js` with
   `{id, display, label, category, scope, match}`. Use `scope: 'message'` + a `match` matcher
   if the dispatcher should fire it; use `scope: 'doc'` for reference-only keys handled
   elsewhere.
2. **Dispatch** — handle the new `id` in `useMessageActionShortcuts.js` (or wire its callback
   through `MessageShortcuts` props from each view).
3. **Menu hint (optional)** — in `ui/web/src/lib/conversationActions.js`, add
   `shortcut: shortcutHint('<id>')` to the relevant menu item. The menu renderers display it
   automatically.
4. The `?` overlay picks it up automatically from the registry.

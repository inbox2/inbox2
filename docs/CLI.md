# CLI — Python/Textual terminal client

A keyboard-driven terminal client (Textual 8) with feature parity to the
Tauri desktop app — **Unified Inbox** (list view, search, selection, Spaces/triage
views), **Channels** (per-account browsing), **Compose** (drafts, attachments,
Bcc, From), meeting invites, Outbox, **Calendar** (month/week/day/agenda,
create/edit/RSVP), **Lore** (open workload + people/orgs), **Rules** (local
rules, agent runs, approvals), **WhatsApp** (macOS) and **Accounts** (add via
browser sign-in or IMAP, remove, resync, diagnostics, open tracking). Text-only
bodies; the AI summary/next action the host cached shows above each thread. See
[Parity](#parity-with-the-desktop) at the bottom for what is deliberately not here. It reuses the desktop app's already-connected
accounts and the **same** SQLite DB + credential key, and shares **one** sync
engine instance with the desktop app when both run.

- Code: `ui/cli/inbox2_cli/`
- Engine host binary: `ui/desktop/src-tauri/src/bin/engine_daemon.rs`
- Shared engine bus: `ui/desktop/src-tauri/src/sync/{ipc,rpc,events}.rs`

> **MX mail (2026-09-20):** inbox2-hosted mail is mirrored into local SQLite by the engine and read here through `db.py` (`mx_accounts`, `_mx_conversations`, `_mx_messages`) + `App.dispatch_action`. Protocol, rules (incl. sealed mail never reaching an agent) and status: [MX-Sync.md](MX-Sync.md).

## Architecture

```
            engine.lock-free election via the socket file itself
            engine.sock (events + RPC)        ~/Library/Application Support/com.inbox2.desktop/
                  ▲           ▲                   inbox2.db (WAL)   .credential_key
   ┌──────────────┘           └────────────────┐
   │ HOST = whoever starts first               │ CLIENTS attach
   │  • runs SyncEngine.run() (60s poll + 5s    │  • subscribe to events
   │    write-back) → writes inbox2.db          │  • send RPC (actions/fetch/send/cal)
   │  • binds engine.sock, broadcasts events    │  • read inbox2.db directly (queries)
   │  • serves RPC                              │
   └─ Desktop app  OR  cli `engine_daemon` ─────┘   ── Python TUI  AND/OR desktop webview
```

Only the **host** opens providers and writes the DB. Every UI reads lists/bodies
straight from SQLite and uses the socket for events + mutations. This is the same
split the desktop webview uses (reads SQLite via tauri-plugin-sql, reacts to Tauri
events) — the CLI just swaps Tauri events for the socket bus.

### One engine, shared

Election is the socket file (`engine.sock`), no lockfile needed:

1. `connect(engine.sock)` succeeds → a live host exists → become a **client**.
2. connect fails → unlink any stale socket, then `bind`. Bind wins → **host**;
   bind loses a race → retry connect → client.

So when the desktop app and the CLI both run, the first starter hosts the engine
and the second attaches — never two engines polling Gmail/MS or racing write-back.
The desktop app participates via the same `EngineBus::start_or_attach` in
`lib.rs`: as host it emits to both its webview and the socket (`CompositeSink`); as
client it relays the host's events to its webview and routes sync-control commands
over the bus.

### Bus protocol (`sync/ipc.rs`)

Line-delimited JSON over the Unix socket, both directions:

| Direction | Shape |
|-----------|-------|
| event (host→client) | `{"type":"event","event":"sync","payload":{…}}` |
| rpc (client→host) | `{"type":"rpc","id":N,"method":"…","params":{…}}` |
| result (host→client) | `{"type":"rpc_result","id":N,"ok":true,"result":…}` / `{…,"ok":false,"error":"…"}` |

RPC methods (`sync/rpc.rs`): `list_accounts`, `list_folders`, `start_sync`,
`stop_sync`, `get_sync_status`, `fetch_message`, `get_message_source`,
`download_attachment`, `send_message`, `save_draft`, `list_outbox`,
`retry_outbox_message`, `perform_conversation_action`, `move_conversations`,
`set_priority`, `clear_priority`, `queue_writeback_action`,
`get_effective_spaces`, `get_triage_labels`, `set_conversation_space`,
`set_conversation_label`, `retriage_conversation`, `invite_for_attachment`,
`detected_invite`, `respond_to_invite`, `add_invite_to_calendar`, `mx_action`, `mx_send`,
`calendar_{create,update,delete,respond}_event`, and (2026-11-06, for the CLI's
parity sections) `remove_external_account`, `{get,set}_open_tracking`,
`get_message_opens`, `lore_entities`, `lore_entity`, the agentic-filter set
(`detect_local_agents`, `set_local_agent_enabled`, `{list,upsert,delete}_local_rule(s)`,
`preview_rule_matches`, `apply_rule_to_existing`, `list_agent_runs`,
`list_failed_agent_runs`, `retry_agent_run`, `list_agent_approvals`,
`resolve_agent_approval` — served from `local_agents::HOSTED`, which
`build_runner` fills in whichever process hosts the engine) and WhatsApp
(`wa_status`, `wa_chats`, `wa_messages`, `wa_search`, `wa_send`,
`wa_open_in_whatsapp`, `wa_chat_media`, `wa_media_file`, `wa_lore_set_done`, `wa_group_todo_set_done`; macOS only —
the hosting process needs Full Disk Access, and Accessibility to send). An outgoing message's
attachment may be given as a `path` instead of `data`: the host reads the file
(it shares the machine), so bytes never ride the line-delimited bus.

### Python modules (`ui/cli/inbox2_cli/`)

| File | Role |
|------|------|
| `runtime.py` | locate data dir + `engine_daemon`; election-aware spawn/attach |
| `bus.py` | asyncio Unix-socket client (events + RPC) |
| `db.py` | read-only WAL queries (lists, FTS search, labels, Spaces, triage labels, outbox, calendar) + optimistic status/read flips |
| `constants.py` | actions/status/views/sort/triage labels + the keymap registry |
| `search.py` | Gmail-style operators → FTS5 MATCH + SQL (port of `lib/searchQuery.js`) |
| `drafts.py` | plain-text reply/forward builders |
| `app.py` | the Textual `App`: sections, channels, undo, palette, bus wiring |
| `screens.py` | `MailScreen` (sidebar · list · thread + invite/attachment bars), `CalendarScreen` |
| `modals.py` | compose, draft-close prompt, picker, event editor/detail, invite, settings, shortcuts, palette, `g` key chord |
| `lore.py` | `LoreScreen`: Today buckets (lib/lore.js rules) + People & orgs (`lore_entities`) + `EntityModal` |
| `rules.py` | `RulesScreen`: rules · runs · approvals · agents tabs + `RuleEditorModal` |
| `whatsapp.py` | `WhatsAppScreen`: chats · messages · composer · search over the `wa_*` RPCs |
| `accounts.py` | `AccountsModal`: loopback OAuth (Gmail/Microsoft via the Rails proxy), IMAP form, remove/resync/diagnostics/sync log/open tracking |

Refresh is **diff-guarded**: a bus event re-queries SQLite, computes a row
signature, and only redraws the `DataTable` when it changed (cursor preserved) —
minimising flicker.

## Running

**Release bundle** (what the website links): `.github/workflows/cli-release.yml`
builds `ui/cli/tools/build.sh` on four runners — macOS arm64 + x86_64, Linux
x86_64 + aarch64 — a PyInstaller one-dir app with `engine_daemon` beside it,
plus a wheel, and publishes everything on the moving `cli-latest` GitHub
release. Version = `MAJOR.MINOR` from `pyproject.toml` + the commit count
(bin/version's scheme). `runtime.find_daemon_binary` looks next to the frozen
executable first. No Windows: the bus is a Unix socket.

```sh
curl -L https://github.com/inbox2/inbox2/releases/download/cli-latest/inbox2-cli-$(uname -s | tr A-Z a-z)-$(uname -m).tar.gz | tar xz
./inbox2/inbox2
```

**Scripting.** The same command carries subcommands that skip the UI
(`cli.py`): `inbox2 accounts`, `inbox2 list [--folder sent] [--unread]
[--account you@x] [--limit N]`, `inbox2 search "invoice from:ana is:unread"`,
`inbox2 read <conv_key>` (HTML converted to text), and `inbox2 send --to …
--subject … [--body … | < file] [--attach f.pdf]… [--account …]`. Reads go
straight to SQLite — no engine, so they work from cron or a pipe; `send`
attaches to the running engine (or spawns the daemon for the call) and goes
through the durable outbox. `--json` on the read commands prints JSON for
scripts and agents.

**From source:**

```sh
cd ui/desktop/src-tauri && cargo build --bin engine_daemon   # once
cd ui/cli
python -m venv .venv && .venv/bin/pip install -e ".[test]"
.venv/bin/inbox2                       # uses the desktop app's data dir + accounts
# options: --data-dir <dir>  --api-base http://localhost:4000/api/v1  --jwt <token>
```

Prerequisite: connect an account in the desktop app first (the CLI reuses its
`inbox2.db` + encrypted tokens + `.credential_key`, exactly like `sync_check`).
If no engine is running, the CLI spawns `engine_daemon` and manages its lifecycle;
if the desktop app (or another daemon) is already hosting, the CLI attaches.

**Not logged in.** If no DB exists yet, or it has no connected accounts, the CLI
shows a welcome screen (the inbox2 logo + "log in from the desktop app, then
restart") instead of an empty inbox — no engine is spawned. The logo is a real
raster image rendered as truecolor half-blocks via `rich-pixels` (works in any
modern terminal), with an ASCII-cube fallback (`constants.LOGO_ASCII`) when the
library or asset is unavailable. For full-resolution graphics on capable
terminals (Kitty/iTerm/Sixel), `textual-image` can be dropped into
`screens.logo_renderable`.

**Theme.** Defaults to Textual's built-in **Catppuccin Mocha** palette
(`constants.DEFAULT_THEME`); any of Textual's 21 built-in themes can be picked in
Settings (`,`) or via the palette's "Change theme…", and the choice persists in
`cli_prefs.json`. All screen/modal CSS uses theme variables (`$background`,
`$panel`, `$accent`, …).

**Search.** The search box speaks the desktop's Gmail-style operators
(`search.py`, a port of `lib/searchQuery.js`): free text + `from: to: cc:
subject: filename: type: is:read|unread|urgent|important has:attachment
in:inbox|archive|trash|spam|anywhere larger:5mb smaller: after:YYYY-MM-DD
before:`. Free text goes through FTS5 (`messages_fts`, and `mx_messages_fts`
for mirrored orgs; words prefix-matched, quoted phrases kept whole); operators
become SQL. Typing is debounced (250 ms); `enter` searches immediately; `escape`
clears and returns to the folder. Trash/spam stay hidden unless scoped with
`in:`.

**Sidebar.** `Folders` (Inbox carries its unread count) · an `Outbox` row when
sends/drafts are queued or failed (`enter` retries a failed send) · `Spaces`
(the org taxonomy pushed to the device + personal Spaces for channel accounts,
the org's own Spaces for a mirrored org; `conversations.space_slug`) · `Triage`
(the four Eisenhower quadrants, then the Jev triage labels —
`conversations.triage_label`) · `Labels` (provider labels/folders without a
well-known role: Gmail labels, Outlook folders, IMAP mailboxes — minus Gmail's
category tabs and the `inbox2/<quadrant>` labels). The list row shows a Jev
chip after the subject (`!!` ≥ 3.5 urgent, `!` ≥ 2.5 high, then `[Label]`), and
a `Date` column (time today · weekday this week · `12 Sep` · year).

**Selection + bulk actions.** `x` toggles the cursor row (and moves on),
`ctrl+a` selects all, `escape` clears. Every action — archive, trash, spam,
mark, triage, move, Space, label — applies to the selection when there is one
(one RPC per account), and undo covers each conversation.

**Compose.** From (a `Select` over every account when there's more than one),
To, Cc, Bcc, Subject, Attachments (file paths, comma-separated — the host reads
them), body. `ctrl+enter` sends, `ctrl+d` saves a draft (`save_draft` → the
engine's durable outbox, `kind='draft'`, delivered to the provider's Drafts and
replaced in place on every save), `escape` on a dirty draft asks *Save draft /
Discard / Keep editing*. The Settings signature is inserted as an RFC 3676
`-- ` block above any quoted text.

**Meeting invites.** When a thread's attachments include an `.ics` /
`text/calendar` part, `_hydrate_thread` asks the host to parse it
(`invite_for_attachment`) and shows the invite banner above the thread (title ·
when · organizer · your current reply). It's a focus stop like the attachments
row: `enter` opens the RSVP / add-to-calendar choices (`y` accept · `Y`
tentative · `x` decline · `a` add to calendar), which call `respond_to_invite` /
`add_invite_to_calendar` — the same engine paths the desktop banner uses
(docs/Meeting-Invites.md).

**Compose autocomplete.** The To/Cc/Bcc fields complete the segment after the
last comma against every correspondent seen in from/to (`db.contacts`, the
port of `useContactSuggestions.js`), inline, `→` accepts — Textual's own
`Suggester` hook, no extra dependency.

**Screenshots for the website.** `ui/cli/tools/shots.py` runs the TUI
headlessly over a throwaway DB of fictional mail, exports each screen as SVG,
and writes `website/public/assets/shots/t-*.webp` in both themes (Mocha and
Latte — the site's shot switch picks between them). Never run it against the
real data dir; it doesn't need one.

**Live indicators.** The engine's `sync` events drive the ⟳ button (`⟳ syncing`
while any account runs; a failed run surfaces its error), `status` events mark
an account tab with ⚠ and toast the error, `new-message` events toast the sender
+ subject (switchable in Settings), and `outbox-changed` re-counts the Outbox
row.

**Lazy body hydration.** Microsoft bodies aren't synced eagerly (the Graph delta
`$select` omits the body — see [Channels.md](Channels.md)), so they read as empty
from the local store. On thread open, `_hydrate_thread` calls the `fetch_message`
RPC for any body-less message (and for attachments), then re-renders the card in
place via `MessageCard.rehydrate`. Messages that already have a local body (Gmail)
are never re-fetched.

**Body collapsing.** Quoted replies and signatures are collapsed behind `···`
toggles in the preview, Gmail-style — the terminal port of the web's body
collapsing (see [Email-Body-Collapsing.md](Email-Body-Collapsing.md)).
`collapse.split_message()` reuses the web detectors' line-based logic
(`quoteDetector.js` / `signatureDetector.js`) on the converted message text:
quote-start patterns (`On … wrote:`, `-----Original Message-----`, multilingual
variants) and trailing markdown blockquotes for quotes; the `-- ` RFC 3676
delimiter and the contact-block heuristic for signatures. Quotes are detected
first so a signature buried in a quote isn't separately collapsed. Each message
renders as body + independent `Collapsible` toggles (signature, then quote).

## Keyboard map

Mirrors `docs/Keyboard-Shortcuts.md` with terminal substitutions (`ctrl` for the
desktop's `cmd`; function keys for channels). Press `?` in-app for the full list.

- **Message**: `r` reply · `a` reply-all · `f` forward · `e` archive ·
  `shift+i`/`shift+u` mark read/unread · `!` spam · `delete`/`backspace` trash ·
  `v` move to folder (picker; Inbox/Archive/Spam/Trash for a mirrored org) ·
  `o` attachments (view + save to `~/Downloads`) · `.` actions menu · `ctrl+u` view source.
- **List**: `x` select/deselect · `ctrl+a` select all · `u` unread only ·
  `shift+o` cycle sort (newest · oldest · unread first).
- **Triage** (Eisenhower quadrants, alt-combos like the desktop): `alt+p` Priority ·
  `alt+d` Delegate · `alt+s` Schedule · `alt+l` Later · `alt+x` untag. The quadrant
  shows as a colored letter in the list gutter (`P`/`D`/`S`). **Jev**: `alt+m`
  move to Space… · `alt+t` triage label… · `alt+j` re-run Jev.
- **Navigation**: `j`/`k` (or arrows) move · `enter` open · `right` steps folders → list
  → message thread; `left` steps back a zone · `escape` back. **In the thread**: `j`/`k`
  (or up/down) move between messages and their quote/signature sections; `enter`/`space`
  expands/collapses the focused message or toggles a quoted-text/signature section,
  and opens the attachments view when the attachments row is focused. Hyperlinks are
  navigable **inline** in the body: a body is a focus stop only when it has links, and
  `j`/`k` (or up/down) step the highlight between links in place — scrolling each into
  view, and handing focus to the previous/next message at the first/last link — while
  `enter` opens the highlighted link in the browser. Messages default to
  all-collapsed-except-the-last (Gmail-style), mirroring the desktop MessageCard.
- **Composer**: `ctrl+enter` / `ctrl+s` send · `ctrl+d` save draft · `escape` close
  (save / discard / keep when dirty).
- **Channels**: `F1` unified · `F2…F9` channel N.
- **Sections**: `ctrl+left`/`ctrl+right` cycle Mail · Calendar · Lore · Rules ·
  WhatsApp; `g` then `m`/`c`/`l`/`r`/`w` jumps straight to one (the app takes the
  second key before any screen sees it, so a fast `g m` can't also hit the
  current screen's own `m`).
- **Global**: `c` compose · `/` search · `s` sync · `,` settings · `ctrl+k` palette ·
  `ctrl+z`/`ctrl+y` undo/redo · `?` help · `q` quit. A Textual `Footer` shows the key hints
  for the current screen.

The top bar carries the brand + account switcher on the left and, on the right, a
**Compose** button (✎ — new message, same as `c`), the search field, a Settings
button (⚙ — accounts · theme · mark-as-read · sort · notifications · signature;
changes save as you make them), and a Sync button (⟳ — forces an immediate sync,
and doubles as the syncing indicator). Above the open thread sits
a clickable **action toolbar** mirroring the desktop's: `↩ Reply · ↩ All · ↪ Fwd ·
▣ Archive · ✕ Delete · ⋯ More` — each button maps onto the matching keyboard
action, and (as on the desktop) the long tail — spam, mark read/unread, triage,
view source — lives behind **More** (the actions menu) rather than as its own
button. The toolbar appears once a conversation is open. It is fully keyboard
operable: from the top message press `up` to step into the toolbar, `left`/`right`
to move between buttons (`left` past the first returns to the list), `enter`/
`space` to activate, and `down` to drop back into the thread. The open conversation
shows its subject, message count, and triage quadrant (e.g. `P Priority`,
colour-matched) as the thread title; each expanded message shows its `To` / `Cc`
recipients under the header (Bcc isn't synced to the local store).

**The Inbox is the desktop's Inbox** — one rule, `db.inbox`, behind the list, the
unread badge and `inbox2 list` (ports of web `useUnifiedInbox` /
`useInboxConversations`): a local thread is in the Inbox when it isn't
archived/spam/trash **and** one of its messages is filed in the account's inbox
folder (`message_provider_state` → `external_folders.well_known_role = inbox`) —
not merely `status = 'open'`, which also takes in sent-only threads and mail filed
only under other folders (on real data that was 57 rows where the desktop shows
28). The **Unified** tab also leaves out threads placed in a quadrant (a priority
flag, or Later's `priority_triaged`; MX: the `Urgent`/`Important`/`Later` tags) —
they live in the Triage views, the desktop's matrix; an account's own tab keeps
them, marked. inbox2-hosted mail has **one channel per domain** like the desktop's
tabs (`mx_accounts` from the org's `domains`; a thread's channel is its
`domain_id`, `mx_org()` maps back for `mx_action`).

**Sending from an inbox2 domain** goes where the desktop sends it: the server
(`POST orgs/:org/messages`), not the channel outbox, which only knows Gmail /
Microsoft / IMAP. `db.send_call()` picks the path; the engine's `mx_send` RPC
posts with the session's bearer, then pulls once so the sent copy mirrors. A
reply passes `conversation_id` (the server threads and, on an E2EE domain, seals
it). From is the member's sendable address on that domain (`Membership#from_addresses`
read from the mirrored `members` row: username@ when the domain is visible, plus
mailboxes and send-as grants); a reply keeps the address the thread used. Like
the desktop's Rails send it is online-only. Not yet in the CLI: attachments and
saved drafts on inbox2 domains (refused with a message — use the desktop).

The left sidebar carries the same folder set the desktop shows, in the same order
— `Inbox · Sent · Drafts · Archived · Spam · Trash`. Archived/Spam/Trash map
to conversation `status`; Sent/Drafts come from synced provider folder membership
(`message_provider_state.folder_key` → `external_folders.well_known_role`), the
same authoritative source the desktop uses — Sent = a message filed under the
account's `sent` folder, Drafts = a message under `drafts` or a locally-composed
draft (`is_draft=1`); see `db.conversations_with_message`. (`is_inbound` is not
used: the Gmail adapter marks every synced message inbound, so it can't tell sent
mail apart.) Below the folders is a **Triage**
section — the terminal equivalent of the desktop's LABELS group — listing the four
Eisenhower quadrants with colour-matched dots (`● Priority · ● Delegate · ●
Schedule · ● Later`); selecting one filters the list to conversations in that
quadrant (`db.conversations_by_quadrant`, matched on the `priority_urgent` /
`priority_important` flags). The Spaces, Jev-label and provider-label sections
are described under *Sidebar* above. The desktop's Views and Workflow (Rules /
Tags / Team) sections are org/server features and aren't mirrored locally.
- **Calendar**: `m`/`w`/`shift+w`/`d`/`a` month · week · work week · day · agenda
  (rows grouped under day separators, today highlighted) · `←/→` previous/next
  period · `t` today · `n` new · `enter` event card (where · who + RSVPs · join
  link; `e`/`d`/`y`/`Y`/`x` act from inside it) · `e` edit · `shift+d` delete ·
  `y`/`shift+y`/`x` accept / tentative / decline. The editor has a calendar
  picker, all-day, attendees and "add video meeting" (Meet/Teams) fields.

## Parity sections (2026-11-06)

**Notifications** (`os_notify.py`). New mail is a toast, and also a system notification when the CLI started its own engine, so the desktop app never doubles up. It follows the notifications setting.

**Sign-in** (`signin.py`). `inbox2 login`, or `l` on the login screen, runs the device link (docs/Device-Link.md) over a loopback listener, gives the token to the engine, and starts one mirror pass per organization. It needs a browser on the same machine, so it does not work over plain SSH.

**Files and drafts on inbox2 domains** (`mxfiles.py`). `o` lists a thread's
attachments from its mirrored payload and saves them to ~/Downloads. `ctrl+d` saves a
server draft, `enter` in Drafts reopens one (its files are listed, and deleting a name
removes that file through `DELETE attachments/:id`), and sending with files follows the web's
order: draft, uploads against it, the send names them, the draft is deleted. These
are direct REST calls with `get_rails_token`, not engine RPCs. Sealed domains are
refused because the CLI has no attachment crypto. Sends go through the engine's
durable `mx_outbox` (`mx_send`), and queued or failed ones appear in the Outbox, where
`enter` retries a failed one (`mx_outbox_retry`).

**Lore** (`g l`). *Today* is the web's Lore page: every open thread with a Jev
label (channel + MX mirror, `db.lore_items`) plus WhatsApp asks and tracked-group
to-dos (`db.wa_lore`), grouped To pay · To reply · Work · Meetings · To review ·
Read later · Waiting, then *Handled for you*. A Lore item IS a thread: `space`
ticks it off by archiving (undoable), `h` runs the suggest-only Handled bulk
action, `H` shows History, `enter` opens the thread in Mail — the list switches to
the folder holding it so Mail's actions act on that thread. *People & orgs* (`tab`)
lists ontology entities over the bus; `enter` opens facts + mentioning threads
and the entity's neighbourhood from `lore_graph` drawn as a two-hop tree (the
Explorer's graph: its strongest connections and theirs), plus the connections
list — `enter` on one steps to that entity.
`/` filters the list. `inbox2 lore [--json]` prints the same buckets without the UI.

**Rules** (`g r`). The desktop's local rules (docs/Agentic-Filters.md): edit
conditions + a built-in action or a `run_agent` action, preview matches, apply to
existing mail, watch runs (retry failed), answer approvals, enable installed
agents. The runner lives in the engine host, so rules fire whether the desktop app
or `engine_daemon` hosts.

**WhatsApp** (`g w`). WhatsApp Desktop's own database, read by the host
(docs/Local-WhatsApp.md): chats, messages with day separators, search, send
(text + file paths), `j`/`k` to step newer/older, open in WhatsApp, and `m` for the chat's media (photos,
videos, documents, voice notes) — photos preview inline as truecolor
half-blocks (`rich-pixels`), anything opens in its default app or copies to
~/Downloads; the host resolves the path inside WhatsApp's container only
(`wa_chat_media`, `wa_media_file`). Polls `wa_status` every 5 s and reloads
only when its `version` moves.

**Accounts** (palette › Accounts). Adding Gmail/Microsoft is the desktop's flow,
terminal-native: a stdlib loopback server on `127.0.0.1:0`, the consent URL from
`/api/v1/auth/{google,microsoft}/authorize` opened in the browser (and printed to
copy), the code exchanged through the Rails proxy, then `add_external_account` +
`start_sync`. `INBOX2_API_ORIGIN` points it at a local API. Meta channels
(WhatsApp Business, Messenger, Instagram) take the desktop form's fields — app ID,
app secret, System User token, the channel's asset ID (+ the WhatsApp Business
account ID) — and go through `add_meta_account` (docs/Meta-Setup.md).

**Graph** (`tab` again from People & orgs): the Explorer's canvas in characters —
the 40 busiest connected entities laid out by a deterministic Fruchterman–Reingold
force layout (the family d3-force belongs to), edges dotted, kind glyphs + names;
`j`/`k` pick a node (its edges light up), `enter` opens its page.

**Email images** (`i` in a thread): the body's remote images (tracking pixels and
inline `cid:`/`data:` skipped), each fetched server-side through the Rails image
proxy with the engine's inbox2 token in the header — the sender never sees this
machine — and drawn inline like WhatsApp photos. Every CLI call to the API sends
`User-Agent: inbox2-cli`: Cloudflare 403s urllib's default agent.

**Intelligence** (Settings › `ctrl+g`, or the palette): the desktop's On-device AI,
Triage & sync and Connected apps pages — the Jev and OpenAI keys (validated by the
host with one real call, kept in the engine's encrypted secret store where the
desktop keeps them: `set_jev_key`, `set_openai_key`, `has_secret`), triage
progress, the processing window, Lore's "Handled for you" auto mode
(`{get,set}_processing_window`, `triage_progress`, `{get,set}_lore_auto`),
connected MCP apps (add by token, remove), and the CLI version.

**When only the CLI runs.** `engine_daemon` now hosts what the desktop host runs
in the background: the Jev triage worker (Jev key from the secret store; the
OpenAI key as the summary lane only when the lane choice allows it — with
on-device chosen, the daemon triages with rules + Jev and writes no summaries), the Lore ontology miner, WhatsApp Lore (still
gated by its stored on/off setting — `whatsapp_lore::arm()`), and the
embedding pipeline behind semantic search. So triage, Lore and search stay
current without the desktop app open.

**Send to…** (`t` on a Lore item, `T` in a thread; docs/MCP-Client.md). The
desktop's SendToDialog: pick a connected app, then an action; the form is
prefilled by the same templates (`sendto.py` ports web `lib/mcpClient.js`), and
nothing is called until `ctrl+s`. Bus: `mcp_list_connections`, `mcp_list_tools`,
`mcp_call_tool`, `mcp_presets`, `mcp_remove_connection`, and
`mcp_add_token_connection` (`ctrl+n` in the dialog). A server that signs in
through the browser is added in the desktop app — the host's OAuth needs its
browser + loopback — and is then usable here.

**AI + semantic search** over the bus. `generative_{summarize,smart_replies,generate}`
use the desktop's on-device backend (`ai::generative_commands::HOSTED`, set in
`setup.rs`) when it has one, and otherwise — or when it fails — the user's OpenAI
key from the engine's secret store (`openai_api_key`), **only if the user's lane
allows it**: the desktop records its effective choice in `engine_settings`
`ai_generation` (`openai` | `on_device`) on every `set_ai_config`, and with
`on_device` no mail goes to OpenAI — the call says to open the desktop app,
where the on-device model runs (`sync::commands::openai_allowed`). A
never-recorded choice keeps the desktop's old `auto` default (the key when
there is one). `vector_search{,_similar}` read
`vector::commands::HOSTED`, which both hosts set (the daemon on the model it
already warms, plus the embedding pipeline); the model loads on first use. In a
thread `S` summarizes on demand and `R` offers smart replies (the pick lands in
the composer); in the composer `ctrl+g` drafts with AI — what you typed is the
instruction, the quoted thread the context (AIComposePopup's prompt); a search
starting with `~` runs the hybrid semantic search.

**Thread extras.** The cached AI summary and next action (title · due · amount)
show under the thread title; messages you sent carry an open-tracking badge that
counts only non-proxied opens (proxy prefetches listed apart, like the web).

## Testing

```sh
# Python — headless Textual Pilot against a seeded temp DB + fake bus (no daemon/network)
cd ui/cli && .venv/bin/python -m pytest -q

# Rust — bus framing/election, RPC, calendar-write adapters (wiremock)
cd ui/desktop/src-tauri && cargo test --lib sync::
```

The Pilot tests (`tests/test_app.py`) drive the whole TUI in-process — list nav,
actions→RPC, bulk selection, FTS search, move/Space/label pickers, compose +
draft + attachment payloads, the invite banner, outbox retry, event-driven
refresh + indicators, undo, channel/section switching, calendar views/editor —
with no TTY, network, or live accounts. `tests/test_search.py` covers the operator
parser and the query layer. The test schema in `conftest.py` mirrors the real
`001_create_schema.sql` columns the CLI reads — keep it honest (the MX mirror has
no `has_attachment`/`priority_*` columns, for example) or a query can pass here
and fail on a real database.

## Parity with the desktop

Covered: unified/channel inboxes, folders, labels, Spaces, triage quadrants +
Jev labels (view and set), search operators, selection + bulk actions, undo,
reply/reply-all/forward/compose with Bcc/From/attachments/drafts/signature,
attachments, view source, meeting invites, outbox, sync/status indicators,
notifications, calendar month/week/work-week/day/agenda with create/edit/
delete/RSVP + event cards, settings (theme/mark-read/sort/notifications/
signature).

Also covered since 2026-11-06: Lore (today + people/orgs + the entity graph as a
force-layout canvas and per-entity two-hop trees), email images via the privacy
proxy, local rules + agent runs/approvals, WhatsApp (chats,
search, send, media with inline photo previews), accounts (Gmail/Microsoft/IMAP/
Meta add, remove, reconnect, resync, diagnostics, sync log), open tracking +
badges, AI summary/smart replies/AI drafts, semantic search, Send to….

Not here, on purpose: Bridge (voice — a mobile feature; the desktop has none);
adding a browser-sign-in MCP server (add it in the desktop app, then use it
here); HTML layout (bodies render as text, images on `i`); MX tags/views/members
(org-side features — the mirror has the data but the desktop hides them in
Tauri too); detected (ICS-less) meetings; a conference link only when the
provider payload carries one. The desktop's own gaps (snooze, star, pin,
scheduled send) aren't invented here either.

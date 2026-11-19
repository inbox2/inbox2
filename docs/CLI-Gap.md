# CLI gap check

A working list, not part of the desktop specification. It records what the desktop client does that `ui/cli` does not, so the CLI can be brought closer. Delete it when the gaps are closed; the specification in `docs/desktop-spec` stays.

Built on 2026-11-07 from a code survey of `ui/cli` and the desktop spec. Paths are repo-relative; `web/` is `ui/web/src`.

## How the CLI is wired

`ui/cli` is a Python/Textual app over the engine bus (`<data dir>/engine.sock`, line-delimited JSON, `bus.py`). It attaches to a live host or spawns `engine_daemon` (`runtime.py` looks in `INBOX2_ENGINE_DAEMON`, then the desktop build dirs, then `PATH`). It reads SQLite directly (`db.py`, WAL, `PRAGMA data_version` for change detection). It writes through RPC (`sync/rpc.rs`, 98 methods), plus two optimistic direct updates: status and read, and the priority flags. It handles the bus events `sync`, `status`, `new-message`, `calendar-changed` and `outbox-changed`. The bus is Unix-only, so there is no CLI on Windows.

Scripting commands: `inbox2 accounts | lore | list | search | read | send`, with `--json` on reads.

## Feature matrix

Status: **yes** = at parity for the purpose; **partial** = present with a stated limit; **no** = absent.

| Desktop feature | CLI | Notes |
|---|---|---|
| Accounts and channels | yes | F1 unified, F2 to F9 for eight channels; a ninth has no key |
| MX domain channels, org fallback channel, out-of-scope domains | yes | `db.mx_accounts` |
| Folders: Inbox, Sent, Drafts, Archived, Spam, Trash | partial | Sent is empty for MX |
| Spaces, quadrants, Jev labels, provider labels, Outbox in the sidebar | yes | |
| Saved views, Workflow, Team | no | |
| Conversation list: unread-only, sort, quadrant gutter, Jev chip | yes | |
| Reading: HTML layout | no | html2text, quote and signature collapsing, link stepping; sealed MX unopened shows a placeholder |
| Remote images | yes | through the Rails proxy with the stored token, drawn as half-blocks |
| Compose with From, Cc, Bcc, attachments, contact autocomplete, signature | yes | |
| Reply | yes | `r` and `a` both open the full composer; the one-line quick reply is gone (decided 2026-11-08) |
| Forward | yes | the thread's files pre-fill the composer and can be removed; sealed MX files are named as left out |
| Reply threading (`reply_to_message_key`) | yes | |
| MX send | partial | text/plain only; attachments work in the TUI, not `inbox2 send`, and are refused on sealed domains; forward on MX starts a new thread |
| Drafts | partial | `ctrl+d` on channels and MX; MX drafts reopen, channel drafts don't; sealed domains refused |
| Outbox and retry | yes | channel and MX; MX sends are durable through `mx_outbox` |
| Search with operators, FTS on channel and MX | yes | `~` prefix runs `vector_search`, which the desktop UI itself does not expose |
| Mark read and unread, four auto modes | yes | its own `cli_prefs.json`, default delay 5 s (desktop 2.5 s) |
| Archive, trash, spam, bulk, undo and redo | yes | |
| Move to folder | yes | MX: inbox, archive, spam, trash only |
| MX tags | no | read only as priority |
| Snooze, star, pin, scheduled send | no | the desktop has no conversation snooze either |
| Attachments: list and save | partial | saved to `~/Downloads`; no preview, no drag out; sealed MX files refused |
| Priority quadrants | partial | channels only; refused on MX threads |
| Spaces, labels, re-run Jev | yes | `alt+m`, `alt+t`, `alt+j` |
| Meeting invites (ICS) | yes | RSVP and add to calendar; detected ICS-less meetings: no |
| Calendar: month, week, work week, day, agenda; create, edit, delete, RSVP; attendees; video meeting | yes | |
| Zones, time-zone planner, scheduling assistant, meet links | no | |
| Lore: Today, tick-off, Handled, History, People, entity pages, graph | yes | plus `inbox2 lore` |
| Explorer graph | partial | the Lore graph tab, force layout |
| Rules and agents: rules, runs, approvals, agents | yes | MX excluded from the editor; no `auto_reply` built-in |
| Notifications | partial | toasts, plus a system notification when the CLI runs its own engine (macOS, Linux); no sounds, no badge, no tray |
| Settings: theme, mark-read, sort, notifications, signature; Intelligence modal | partial | Textual's own themes only; no text size |
| Provider accounts: Gmail and Microsoft OAuth, IMAP, Meta; reconnect, remove, resync, diagnostics, sync log, open tracking | yes | loopback OAuth through the Rails proxy |
| inbox2 sign-in and device link | yes | `inbox2 login` or `l` on the login screen; needs a browser on the machine, so not plain SSH |
| AI: cached summary and next action; summarize; smart replies; AI draft; semantic search | yes | the lane is decided by the engine (`openai_allowed`) |
| Triage Lab, prompt editing, lane choice, model downloads | no | |
| MCP server toggle and access tier | no | |
| Send to… (MCP client) | partial | token connections only; browser-OAuth servers must be added in the desktop |
| Local WhatsApp | yes | macOS host: chats, messages, search, send text and files, open in WhatsApp, media previews |
| Vault, cloud backup, E2EE unlock | no | the vault RPCs exist and are unused |
| Open tracking badge per message | yes | `get_message_opens` |
| Touch Strip, DropBlock, themes with backdrops | no | webview only |
| Disk, console | no | web only on the desktop too |
| Updater | no | the CLI ships through `cli-release.yml` |
| Keyboard operability | yes | the full keymap is in `docs/CLI.md` |

## RPC the CLI never calls

`list_folders`, `list_outbox`, `get_effective_spaces`, `get_triage_labels` (it reads SQLite instead), `get_sync_status`, `get_syncing_accounts`, `stop_sync`, `queue_writeback_action`, `detected_invite`, `vector_search_similar`, `mcp_presets` (listed in `docs/CLI.md` as used; it is not), `mx_sync`, `mx_forget`, `set_api_context`, `get/set/clear_secret`, `register_push`, `deregister_push`, `ingest_meta_event`, and every vault and cloud-backup method.

## Smaller mismatches found

All four closed on 2026-11-08: the `?` overlay, the `docs/CLI.md` keymap, a test for `s` and `c` on Calendar and Lore, and a local pre-push step that runs the CLI tests when `ui/cli` changes (`.git/hooks` is per-machine; there is still no CI job).

## Unverified items, traced 2026-11-08

- **MX attachment download did not work.** `fetch_message` and `download_attachment` go through `interactive_provider`, which needs a row in `accounts`. Fixed the same day by `mxfiles.py`.
- **MX priority did not work.** It showed "Triaged" and changed nothing: `conversations` holds no MX row, and `enqueue_for_conversations` skips a thread with no provider state. MX priority is stored as server tags (`web/lib/mxPriority.js`). The CLI now refuses it with a warning.
- **Editing an existing draft was not built.** MX drafts now reopen on `enter` in Drafts. The composer lists the files already on a reopened draft, and deleting a name removes that file from the draft. Channel drafts still don't: the engine has no call to delete the old provider copy after a send, so reopening one would leave a duplicate.

## Order of closing

Ranked by the value to a terminal user, these gaps come first:

1. ~~MX attachments and drafts~~ Done 2026-11-08 (`mxfiles.py`), with sealed domains refused. Not run against a live server yet.
2. ~~Forwarding with attachments~~ Done 2026-11-08.
3. ~~The full composer on `r`~~ Done 2026-11-08.
4. ~~The MX outbox listing~~ Done 2026-11-08, with CLI sends moved onto the durable outbox. The list had assumed they were already on it.
5. ~~An inbox2 sign-in through the device link~~ Done 2026-11-08. Not run against the live server yet.
6. ~~OS notifications from the engine's `new-message` event~~ Done 2026-11-08, only when the desktop app isn't the host.

The rest is webview-only by nature or out of scope by decision (Bridge, browser-OAuth MCP servers, HTML layout).

## Notes collected from the specification chapters

- The CLI builds no mirror itself. It reads the mirror the desktop or `engine_daemon` built and needs the stored inbox2 token. The CLI has no inbox2 sign-in of its own, and refuses MX attachments and drafts. (from chapter `05-sync.md`)
- The CLI keeps its own `cli_prefs.json` (theme, mark-read mode and delay, sort, notifications, signature). The desktop's localStorage stays unread. The CLI shares only what is in `engine_settings` and `app_secrets`: the processing window, Lore auto, open tracking, the Jev and OpenAI keys, triage labels and spaces. The CLI has no text size and no lane choice; the engine's `openai_allowed` decides the lane for it. (from chapter `07-settings.md`)
- The CLI has Send to… with token connections only. A server that needs browser OAuth must be added in the desktop. The CLI has no Triage Lab, no prompt editor and no lane choice. Its summaries and smart replies run through the same engine RPCs. (from chapter `08-ai.md`)
- The CLI suite is the only place the engine bus is exercised end to end, and no hook runs it. (from chapter `11-tests.md`)

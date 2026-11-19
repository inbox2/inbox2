---
part: "12"
title: Decisions
subtitle: The settled choices with their dates and reasons.
eyebrow: Decisions
lede: Every decision here is final. A change to one of them is a new decision with its own date and reason, recorded in the doc it points at. Each group opens with the terms a first-time reader needs.
---

## Terms used in the decisions

Each decision comes with the date it was taken (or "undated" when the docs record no date), the reason that was given, and the file that records it. The reason says what went wrong or what was at stake, and that is what keeps the decision from being undone by accident. The terms:

| Term | Meaning |
|---|---|
| MX mail | mail for a domain hosted on inbox2; the server owns it, the desktop mirrors it |
| local channel | a Gmail, Microsoft 365, IMAP or Meta account the person connected; the desktop syncs it from the provider and the inbox2 server never sees it |
| the mirror | the local copy of MX mail in the `mx_*` tables |
| write-back queue | the table of actions (archive, read, move) waiting to be sent to the provider or the server |
| settle guard | the rule that a freshly written row is protected from a sync page fetched before the write landed |
| sealed mail | end-to-end encrypted mail: the server holds ciphertext, the device opens it |
| lane | which model answers a text request: Apple Intelligence, a local model, or OpenAI |
| Jev | the TypeSafe judgment model that triages mail (label, priority, Space) |
| agent | an AI program that reads the inbox through MCP, or a coding agent a rule runs |
| identity | the bundle id an app build carries, prod or dev, which decides its data directory and update stream |

## Sync architecture

inbox2 Desktop shows two kinds of mail in one inbox, and they are synced in two different ways. The decisions in this group keep those two ways apart, say how the local copy of MX mail is kept correct, and say what a write does before the server or the provider has confirmed it.

| Decision | Date | Reason | Source |
|---|---|---|---|
| Two sync modes are kept apart. MX mail syncs with the Rails API. Local channels are client-side SQLite and the API never sees them. A feature that spans both kinds of mail is built twice, once per path. | invariant | the privacy promise of connected mailboxes: the person's Gmail stays between the person and Google | `CLAUDE.md`, `docs/Routing.md` |
| MX mail is mirrored in its own `mx_*` tables, away from the channel tables `conversations` and `messages`. Code that should see MX mail opts in on purpose. | 2026-09-20 | about 400 SQL statements in 39 files assumed every row is channel mail; sharing tables would have triaged, ruled and counted MX mail twice | `docs/MX-Sync.md` |
| D1: the MX sync client lives in the Rust core, so desktop, iOS, Android and the CLI share one implementation. The browser has no SQLite and stays on REST. | 2026-09-20 | one implementation for every client | `docs/MX-Sync.md` |
| D2: the whole history is mirrored, newest first. `mx_sync_window_days` (0 = unlimited) can cap it. | 2026-09-20 | replaced a 90-day window picked earlier the same day | `docs/MX-Sync.md` |
| D3: the directory (org, domains, mailboxes, members, tags, spaces, labels, views) is mirrored too. | 2026-09-20 | an offline client still needs tabs, spaces, labels, assignees and From identities | `docs/MX-Sync.md` |
| D4: sealed mail is opened on the device and the plaintext is kept locally, under five conditions: the file relies on OS disk encryption; sealed rows never go to a cloud AI lane; the file is excluded from backups; the org's rows are wiped on sign-out, identity switch or loss of the grant; rows stay ciphertext until unlocked. Keys stay in memory, are zeroized, and never cross the engine bus. | 2026-09-20 | end-to-end encryption is a promise about what the server holds; channel mail already sits in plaintext in the same file | `docs/MX-Sync.md` |
| D5: the server's generic `sync/push` endpoint, which let a client push raw column values, was deleted. A client write replays the real REST endpoint through the write-back queue. | 2026-09-20 | a raw column push skips validation, activity events and broadcasts | `docs/MX-Sync.md` |
| D6: every MX-sync change is reviewed by Codex before it is committed. | 2026-09-20 | process | `docs/MX-Sync.md` |
| The engine owns the MX write-back queue on every platform; the webview's own drain was deleted. The settle guard holds a written row for 60 s and lapses after 15 min. | 2026-09-20 | one owner; a page read before a write must not undo the write | `docs/MX-Sync.md` |
| Composing MX mail stays online. Sending while offline is out of scope. | 2026-09-20 | | `docs/MX-Sync.md` |
| The mirror is a cache. The `mx_*` tables are never altered in place; a schema bump drops and re-syncs them. Queued actions survive the reset. | 2026-09-20 | queued actions are the person's intent | `docs/MX-Sync.md` |
| `localData.js` answers only when the mirror is complete for the signed-in user, and `null` means "not synced yet", never "empty". Search is local first (the mirror's FTS5 index) with the API as fallback. Unread counts stay on the API. | 2026-09-20 | "known empty" and "not synced yet" are different states | `docs/MX-Sync.md` |
| MX mail does not take part in Bridge, the on-device triage worker, local rules, vector embeddings or unread badges. The server's Jev is authoritative for MX triage. | 2026-09-20 | each would be its own decision | `docs/MX-Sync.md` |
| The `agent_*` views enforce the sealed rule for agent reads that go through them: a sealed message, and every message of a thread that contains one, is absent. A tool that reads `mx_*` directly (the MCP attachment tools) applies the same thread-wide check itself. | 2026-09-20 | an MCP client may be a cloud model | `docs/MX-Sync.md` |
| One engine serves the desktop app and the CLI. The first process to bind `engine.sock` hosts it; the next one attaches as a client. | undated | two engines would poll Gmail twice and race the write-back queue | `docs/CLI.md`, `docs/Channels.md` |
| If the database cannot open: retry three times, then show a native dialog with Restart. There is no temporary database. | undated | a temporary database once produced a "No accounts connected" split brain | `docs/Channels.md` |
| Shutdown takes the engine lock with `try_lock`, releases the socket and kills the AI sidecars; it does not wait for in-flight syncs. | undated | waiting hung the exit; an engine that outlived the app split-brained the next launch | `docs/Channels.md` |
| A local action writes the row's status and read flags first (never `updated_at`), then queues the write-back. A completed write-back is kept 180 s. | undated | a sync page fetched before the provider applied the change must not bring the old state back | `CLAUDE.md` |
| OAuth refresh goes straight to the provider when the build has client credentials, otherwise through the Rails proxy; first authorisation always uses the proxy. A 4xx on refresh marks the account `needs_reauth`, with one prompt per 5 minutes. | undated | Microsoft rotates refresh tokens; constant prompts drove people away | `docs/Channels.md` |
| A Gmail HTTP 403 for quota is transient, never `needs_reauth`. | undated | Gmail signals its per-minute quota with 403 | `CLAUDE.md` |
| Background throttling is off on the main window. | 2026-09-19 | WebKit suspended the hidden webview and dropped the cable frames that announce new mail | `docs/Tauri-Desktop.md` |
| Cloud push for local channels: the client creates the Gmail watch or Graph subscription and tells Rails only the mapping, so Rails learns "mailbox X changed" and nothing else. Paid plans only; the toggle defaults to on. | undated | the provider token never leaves the client | `docs/Cloud-Push.md` |
| Open tracking is the one deliberate deviation from "local channels never touch the API": local clients poll the API for opens with a capability token. | undated | a pixel hit on the server cannot reach a SQLite file on a laptop | `docs/Open-Tracking.md` |

## Shell and release

The shell is the native Tauri layer. These decisions set how it looks, how two builds live side by side, how a release is cut without CI, and how installed copies learn about a new version.

| Decision | Date | Reason | Source |
|---|---|---|---|
| Tauri 2 with custom chrome: the UI draws its own title bar under macOS overlay traffic lights and starts a drag with `startDragging()`, with 78 px of padding. | undated | `startDragging()` works across several screens; the declarative drag region did not | `docs/Tauri-Desktop.md` |
| Two identities: `com.inbox2.desktop` (prod) and `com.inbox2.desktop.dev` (dev, golden badge), each with its own data directory, keychain item, single-instance lock, socket and deep-link scheme. | undated | recordings never show real mail; both can run at once | `docs/Tauri-Desktop.md` |
| The API origin is baked in at build time (`VITE_API_ORIGIN`) and code calls `apiBaseUrl()`. The desktop authenticates with a bearer token from the engine's store, not a cookie. | undated | the webview runs on `tauri://localhost`, so the page origin is useless | `docs/Tauri-Desktop.md` |
| The updater is configured only in `tauri.release.conf.json`. `yarn install:app`, which builds the prod identity locally, is the one dev build that joins the update stream. | undated | dev builds need no signing key and must never replace themselves with prod | `docs/Desktop-Release.md` |
| A release is the local command `bin/release-desktop`, run after pushing to main. The CI job was removed. | 2026-09 | the launchd runner went stale and timed the job out silently; four releases never shipped | `docs/Desktop-Release.md` |
| The version is `MAJOR.MINOR` from `tauri.conf.json` plus the commit count. No tags, no bumps, no changelog. | undated | every push is a strictly larger version, which is what the updater compares | `docs/Desktop-Release.md` |
| macOS builds are Apple Silicon only. | undated | the ONNX runtime ships no x86_64 macOS binary | `docs/Desktop-Release.md` |
| Windows and Linux builds carry only the updater signature, no OS signature. Linux ships as `.deb`. | undated | Azure Trusted Signing was never set up; an AppImage cannot run under Rosetta | `docs/Desktop-Release.md` |
| Windows and Linux draw their own window controls and set no app menu. The Linux tray is a two-item menu. Under Wayland the new-mail card is a system notification. | 2026-11-07 | the native title bar doubled the chrome bar; appindicator sends no click events; Wayland lets no client position a window | `shell/setup.rs`, `shell/tray.rs`, `docs/Tauri-Desktop.md` |
| The Windows installer bundles the five Visual C++ runtime DLLs beside the exe. The Windows unread badge is an overlay icon; the tray popover opens above a bottom taskbar. | 2026-11-07 | a clean Windows has no VC++ runtime and the app exited with no log; `setBadgeCount` is a no-op on Windows; the popover placement assumed a top menu bar | `shell/tauri.windows.conf.json`, `hooks/useDockBadge.js`, `shell/tray.rs`, `docs/Desktop-Release.md` |
| An update is trusted by its ed25519 signature, never by where it was downloaded from. One key, generated 2026-06-24. | 2026-06-24 | | `docs/Desktop-Release.md` |
| Releases publish to the Pushleft `downloads` volume, newest three kept; the manifest is written last and served with a 60 s TTL. | 2026-11 | Rancher is gone; a statically served manifest hid new releases behind caches | `docs/Desktop-Release.md` |
| In-app update: a poll every 2 minutes, then an amber Update tag on the bell, a row in the notification panel, and Settings › About. | undated | | `docs/Desktop-Release.md` |
| Hardened-runtime JIT entitlements stay on; `strip = false` stays in `Cargo.toml`. | undated | notarized builds crashed on inference; the updater reads a symbol that stripping removes | `docs/Desktop-Release.md` |
| The notification and tray windows are non-activating NSPanels. Actions on a card are optimistic. The window hides on dismiss and stays alive. | undated | a plain window took focus from whatever the person was doing | `docs/Notifications.md` |
| Three notification modes: the custom card window (default), system notifications, or none. | undated | | `docs/Notifications.md` |
| The unread badge has exactly two writers and is never derived from a list. | undated | a third writer broke it repeatedly | `docs/Notifications.md` |
| Meeting reminders fire on the client, on a 30 s tick. | undated | a server scheduler could reach only the MX half of the calendar | `docs/Notifications.md` |
| The invitation card offers Accept and Decline only. | undated | | `docs/Notifications.md` |
| Sign-in code detection runs where mail is read, and skips sealed mail. | undated | the parity fixtures define it once for every client | `docs/Notifications.md` |

## Frontend rules

These are the binding rules for the React UI: how it is styled, which components it may use, how mail is rendered safely, and how navigation state is kept.

| Decision | Date | Reason | Source |
|---|---|---|---|
| F1: CSS Modules only. No Tailwind. An inline `style` prop is a lint error that fails the build. A dynamic value goes through `setProperty('--var')`. | binding | | `docs/Reference-Implementation.md` |
| F2: every piece of UI comes from the component library. F3: icons are SF Symbols through `Icon`. F4: everything is reachable by keyboard. | binding | | same |
| F5: no native date pickers; every calendar is `components/DateField`. | 2026-10-02 | the browser's popup drew a white system calendar over the dark theme | `CLAUDE.md` |
| Two design layers: the light "management" look for auth, onboarding and admin; the dark Aero look for the mail client. | undated | | `CLAUDE.md` |
| The high-contrast and solarized themes were removed. | undated | | `CLAUDE.md` |
| The Touch Strip uses the Spaces stat-panel look; the Aero chrome-glass look was tried and rejected. | 2026-09-29 | | `docs/Touch-Strip.md` |
| HTML mail renders in a sandboxed iframe with no scripts and a strict CSP; plain text renders inline. | undated | opening a message must not phone home | `docs/Email-Rendering.md` |
| Remote images are blocked by default and fetched through the proxy. A direct load needs explicit consent and is offered only for hosts the proxy refused. | undated | images are a tracking vector; the IP exposure stays consented and minimal | `docs/Email-Rendering.md` |
| Quote and signature collapsing is the shared JS package `@inbox2/email-body`, not a Rust port. | undated | every platform renders mail in a DOM, so the same JS runs everywhere | `docs/Desktop-Capabilities.md` |
| Mark-as-read has four Outlook-style modes, default "after a delay". | undated | keyboard navigation touches many messages; a delay avoids marking them read by accident | `CLAUDE.md` |
| After the person deselects a thread on purpose, a sync does not reselect the last one. | undated | | `CLAUDE.md` |
| Export to `.eml`: local channels save the provider's raw source; MX builds the MIME. | undated | the MX mirror keeps no raw MIME | `docs/Tauri-Desktop.md` |
| Selecting a conversation uses `replaceStack`; in-app browser navigations live on `navigationStore.stack`. | undated | a plain `replace` broke the back button | `docs/Routing.md` |
| Non-mail routes use the org's primary slug, never a domain slug; the Space filter overrides the domain filter; some slugs are reserved; the console has its own host. | 2026-10-04, 2026-10-07 | | `docs/Routing.md` |

## AI

The client uses models for two different jobs: judgments (which label, which priority, which Space) and text (summaries, replies, drafts). These decisions say which model does which job, what the model may see, and what it may never do on its own.

| Decision | Date | Reason | Source |
|---|---|---|---|
| Every text capability runs on one of three lanes: Apple Intelligence, a local model, or OpenAI with the person's key. The local model is Qwen2.5-1.5B on every platform; Gemma 3 1B is an opt-in variant. | undated | Gemma 3 1B is English-only, misread Dutch and had the worst JSON compliance | `docs/AI-Lanes-and-Eval.md` |
| All prompts live in `prompts.toml` with per-device overrides. An invalid override changes nothing. The `[triage]` section is retired. | undated | a broken edit must not take triage or Bridge down | `docs/AI-Lanes-and-Eval.md` |
| Triage (label, priority, Space) is a typed call to Jev. The OpenAI and on-device classifiers are gone. Summaries stay on the text lanes. Local channels use the person's own Jev key; without one they get rules only. | 2026-09-19 | a judgment model returns typed answers and cannot be prompted into writing text | `docs/Triage.md` |
| Sealed mail gets label, priority and Space, and no summary. | undated | a stored summary is plaintext | `docs/Triage.md` |
| Five labels were added (`payment_due`, `to_review`, `read_later`, `receipt`, `notification`). Auto mode archives or trashes per bucket, after opt-in, never on manual labels, on threads the person sent in, on shared MX inboxes, or on local mail older than 72 h. A one-time re-triage is capped at 500 threads. | 2026-10-20 | suggest first; every auto action is undoable | `docs/Triage.md`, `docs/plans/lore.md` |
| The triage label drives badges, sorting and the opted-in auto actions. Nothing else acts on it. | undated | a label is model output, and model output can be steered by a crafted email | `docs/Triage.md` |
| Bridge (the mobile voice assistant) drafts only. It never sends, saves or RSVPs. | undated | | `CLAUDE.md` |
| Local rules run on local channels and the desktop only. `run_agent`, which starts a coding agent on the message, is the single Tier-2 action and replaced the webhook idea. Each rule chooses `allowlist`, `approval_first` or `full_auto`. The agent's result is read from `result.json`. The on-device gate fails closed. | undated | one concept, called agents; the agent's input is an email an attacker may have written | `docs/Agentic-Filters.md` |
| The MCP server runs inside the app over loopback HTTP with a bearer token, not over stdio. It speaks both the stateless 2026-07-28 protocol and the legacy session protocol. Three access tiers, `read` by default. Every call is audited. | undated | stdio is a one-client pipe owned by the host app; the engine is always on | `docs/Vector-MCP.md` |
| MCP sends and drafts are durable queue rows. Gmail permanent delete is refused. Tags are added one at a time. | undated | Codex review; a stale mirror must not undo a teammate's tag | `docs/Vector-MCP.md` |
| Local full-text search does not index attachment content; the provider's own search is merged in. | 2026-10-07 | indexing would mean downloading every attachment | `docs/Vector-MCP.md` |
| The MCP client ("Send to…") lives in the core and only drafts: only the Create button calls a tool; results and schemas are untrusted; only the fields the person sees leave the device. Desktop only. | 2026-10-20 | the same rule as Bridge | `docs/MCP-Client.md` |
| Lore: a to-do is the thread itself, so done equals archived. The ontology and the Explorer swap shipped in the same pass. | 2026-10-20 | local to-do state then syncs through the provider and stays off the API | `docs/plans/lore.md` |
| The ontology has a fixed schema (organisation, person, product, project). A deterministic header pass runs on every plan; a grounded LLM pass adds facts with a confidence formula. There is no review queue. The local miner reads channel mail only. | 2026-10-20 | accepted trade-off: a wrong entity stays until edited by hand | `docs/Ontology.md` |
| Explorer opens on the entity graph; the mailbox graph is a toggle. Lore pages follow Notion's layout. Logos are fetched server-side per domain, never for freemail domains. | 2026-10-20 | | `docs/Explorer.md`, `docs/plans/lore.md` |

## Local WhatsApp, calendar, security, Disk

The last group covers the features around the inbox: WhatsApp read from the desktop client's own database, the calendar and its invitations, how the person signs in, and the Disk file product.

| Decision | Date | Reason | Source |
|---|---|---|---|
| WhatsApp Desktop's database is opened read-only, one short statement at a time, never with `immutable=1`. Messages are never copied out. | undated | the WhatsApp client must never be blocked from writing; `immutable=1` gave torn reads | `docs/Local-WhatsApp.md` |
| Nothing writes to WhatsApp's database. A reply or a mark-read is acted out in WhatsApp's own window through its `open-chat` link and the Accessibility API, and each send is confirmed against the database. Nothing is sent automatically. | undated | a direct write would corrupt the store and the server would never know | `docs/Local-WhatsApp.md` |
| WhatsApp asks feed Lore; Jev judges whether a reply completed one. Business groups are tracked, ignorable and summarised per day. | 2026-10-25, 2026-10-26 | | `docs/plans/lore.md`, `docs/Local-WhatsApp.md` |
| Calendar create, update and delete go through the MX API only. Local-channel calendars are client-side, and the calendar view merges both. | undated | the two sync modes | `docs/Calendar.md` |
| An internal invitation is one event: `visible_to` and `editable_by` are separate lists, so there is no copy per attendee. Free/busy is org-wide and busy-only. Devices upload busy blocks from local calendars. | undated | copies drift; a private calendar used to read as free all week | `docs/Calendar.md` |
| Zones (focus blocks) are per person and do not count as busy by default; blocking is optional since 2026-10-21. The zone card stays until clicked away, and a dismissal syncs across devices. | 2026-10-21 | | `docs/Calendar.md` |
| Scheduling settings live in the mail app, not in the console. | undated | | `docs/Calendar.md` |
| Dragging an event on Google or Microsoft patches the times only. Every event editor has the Repeat UI. | 2026-10-25 | patching attendees resets their RSVPs | `docs/Calendar.md` |
| ICS invites keep their `TZID`, normalised to an IANA name, and hand the provider a wall-clock time plus a separate time zone. Google uses `events.import`. A meeting detected in plain text is add-only. | undated | Google rejects other zone names; `insert` would mint a new UID | `docs/Meeting-Invites.md` |
| Device link: the desktop signs in through the browser, which approves it over a loopback listener with PKCE and mints a device-scoped `ink_` key that does not expire. The desktop runs the exchange in Rust. | undated | 30-day sessions expired silently and disarmed cloud push | `docs/Device-Link.md` |
| App OAuth (brokered provider sign-in for third-party apps) uses a separate Google web client. | 2026-08-20 | the installed-app client allows loopback redirects only | `docs/App-OAuth.md` |
| The credential vault is zero-knowledge and opened with the account password. At-rest encryption of the local database was dropped in favour of OS disk encryption. | undated | tokens are low stakes because they can be obtained again | `docs/E2EE.md` |
| A notification for sealed mail is a content-free signal followed by a local decrypt. | undated | | `docs/E2EE.md` |
| Disk on the desktop was decided as the web UI in a tab, with no sync client and no offline mode. As shipped, the Tauri app redirects `/disk/*` to the inbox and Disk is used in the browser; the tab is open work. Sealed folders are shared whole, to named people, under one key. Disk keeps its own light shell. | 2026-10-03 | a separate app doubles the release work; the cross-origin isolation Disk needs | `docs/plans/disk-build.md`, `docs/plans/disk-spec.md` |
| A Gmail channel and an MX domain for the same address may coexist during a migration; the channel is removed at cutover step 5. Imported history is private to its owner. | 2026-10-07 | | `docs/plans/mail-import.md` |
| Demo mode (⇧⌘D) is read-only, scrubs data on read, and lives in sessionStorage. | undated | | `docs/Keyboard-Shortcuts.md` |
| Native CRM and Zapier integrations, and embeddable widgets, are not built. | 2026-07 | product decision | `docs/TODO.md` |

## Contradictions between the docs

- `CLAUDE.md` still says "no recurrence UI"; `docs/Calendar.md` says Repeat shipped on 2026-10-25. Only "reminders never fire" and "no ICS export" still hold.
- `CLAUDE.md` lists the high-contrast and solarized themes under Design direction and says they were removed under Web frontend gotchas. They are removed.
- `CLAUDE.md` points to a per-domain-settings gap in `docs/Routing.md` that the file no longer describes.
- Spec 16.7.3 (PowerSync) and TODO 35.3 (`/sync/push`) are superseded by MX-Sync D1 and D5.
- `docs/Tauri-Desktop.md` still describes adapter stubs, a forced dark theme and a short capabilities list; the tray popover follows the selected theme.
- `docs/Client-AI.md` and `docs/Desktop-Capabilities.md` say no email content leaves the machine; since 2026-09-19 triage text goes to TypeSafe when a key is set.

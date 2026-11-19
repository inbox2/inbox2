# Local WhatsApp (desktop, macOS)

Reads WhatsApp Desktop's own database on this Mac — live and read-only; the chats and messages
themselves are never copied — and shows it as a WhatsApp tab, in global search, and in Lore.

**What Inbox2 does keep** (in its own `inbox2.db`, on this Mac): for Lore, one `wa_lore` row per chat
with an ask — the chat's name and avatar path, who asked, the ask's message ids, time and change
marker, the model's label, priority, to-do title and one-line summary, a due date / amount, and the
done state — plus ontology rows (people, organizations, projects, short verbatim quotes) mined from
the asks under `wa:<chat_id>`, and the worker's cursor and retry list in `engine_settings`. It never sends anything on its own. Replying
and marking read happen only when the person presses Send / the WhatsApp button, *inside* WhatsApp Desktop, as if typed there (see
[Replying and marking read](#replying-and-marking-read)). **What leaves the Mac:** for Lore, the messages that ask something of the owner (plus a
few before them) go to Jev (TypeSafe) and the user's text lane (on-device, or their own OpenAI key),
exactly as local mail does. The Add-account copy says so.
Separate from the Meta Cloud API WhatsApp channel ([Meta-Setup.md](Meta-Setup.md)).

Turned on from **Add account › Social channels › "Use WhatsApp on this Mac"** (the same place
turns it off). The switch is a localStorage pref (`inbox2_local_whatsapp`) mirrored into the
engine setting `wa_lore_enabled` so the Lore worker knows.

## Where the data is

`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/`

| File | What we read |
|---|---|
| `ChatStorage.sqlite` | `ZWACHATSESSION` (chats: type 0 = 1:1, 1 = group), `ZWAMESSAGE` (messages; dates are seconds since 2001-01-01), `ZWAMEDIAITEM` (media path, caption, quote metadata), `ZWAGROUPMEMBER`, `ZWAPROFILEPUSHNAME`, `ZWAPROFILEPICTUREITEM`, `ZWAGROUPINFO` |
| `ContactsV2.sqlite` | `ZWAADDRESSBOOKCONTACT` — address-book names by LID or phone JID (attached as `c`) |
| `Message/Media/…` | downloaded attachments; `Media/Profile/<x>.jpg` / `.thumb` avatars |

Sender names: address book → group member row → push name (`~name`) → `+number`.

## Not disturbing the WhatsApp client

`ChatStorage.sqlite` is WAL. We open it `SQLITE_OPEN_READ_ONLY` (attached DBs inherit it), run one
short autocommit statement at a time and never hold a transaction, so WhatsApp's writer is never
blocked and its checkpoint is never held back. Never `immutable=1` (it skips the WAL: torn reads).
macOS guards other apps' containers: the file is visible but `open()` is refused (SQLite says only
"unable to open database file") until Inbox2 has **Full Disk Access**. `open()` checks that first and
returns `NO_ACCESS`, which the UI shows with an "Open Full Disk Access" button
(`wa_open_privacy_settings`). Dev and prod builds are separate entries in that list.

Pages are cut on `(ZMESSAGEDATE, Z_PK)`, the sort order, so messages sharing a timestamp never fall
between two pages.

## Code

- `ui/desktop/src-tauri/src/whatsapp.rs` — the reader: `wa_status` (change marker `max(Z_PK)` + unread
  chats), `wa_chats`, `wa_messages` (`before` pages back, `around` centres on a message), `wa_search`
  (every word `LIKE` over text + captions — ASCII-only case folding), `wa_open_media`, and the
  `wamedia://localhost/<relative path>` protocol, which refuses anything outside the container.
- `ui/web/src/lib/localWhatsApp.js` — pref, invoke wrappers, `waMediaUrl`, and one shared 4-second poll
  of the change marker (`useWaStatus`) that the tab badge, chat list and open thread reload on.
- `lib/waMessages.js` — WhatsApp rows → `ChatThread` messages (media, system rows, "not on this Mac").
- `components/WaChatPane`, `pages/whatsapp/WhatsAppPage.jsx` (route `/whatsapp?chat=&msg=`), the chrome
  tab in `ChromeBar`, a WhatsApp column in `SearchResultsView` (plain words only).
- `ChatThread` gained group sender labels/avatars, system rows, clickable attachments and
  Load earlier (keeps the scroll position).

## Replying and marking read

Every chat pane has a reply box and a **WhatsApp** button, green while the chat has unread messages.
There is no separate switch (there was one at first; it hid the reply box behind a setting nobody
found): the first Send asks macOS for Accessibility with its own prompt.
WhatsApp Desktop has no API, AppleScript, or share extension on the Mac, so Inbox2 does what a
person would do in WhatsApp's own window. Messages go out from the person's own WhatsApp; Inbox2
never writes to WhatsApp's database (the server wouldn't know, and it would corrupt the store).

**Opening a chat** uses WhatsApp's own widget link, which takes a chat JID (`ZCONTACTJID`), so
groups and LID-only contacts open too (`whatsapp://send?phone=` reaches neither):

```
whatsapp://widget-open-app/open-chat?chatJid=<jid>
```

The host and the `chatJid` parameter are short Swift strings inlined into the code (not in
`strings` output). They were decoded from the URL parser in `SharedModules.framework` (WhatsApp 26.41.28).
A rename in a WhatsApp update shows in WhatsApp's own plaintext log
(`Logs/WhatsApp_*/…log`: `widget-deep-link-url/parsing/invalid-host`). Opened with `open -g`, it
selects the chat without bringing WhatsApp forward. **Open in WhatsApp** (the pane's button) is the
same link without `-g`. Needs no permission.

**Marking read** is that WhatsApp button: it shows the chat in WhatsApp, which reads it there (blue
ticks go out exactly as when reading in WhatsApp). There's no separate Mark read button: it did the
same thing, opening the chat. Unread is read from `ZUNREADCOUNT`, so the button turns back from
green once WhatsApp has read the chat.

**Sending** drives WhatsApp's window through the Accessibility API (`whatsapp_ax.rs`; Inbox2 must be
allowed under System Settings › Privacy & Security › Accessibility: the first Send is the only
place that asks). The window carries stable accessibility identifiers, the ones Meta's UI tests use:

| Identifier | What |
|---|---|
| `ChatBar_ComposerTextView` | message box (value settable) |
| `ChatBar_SendButton` | appears in place of `ChatBar_VoiceMessageButton` once WhatsApp sees text |
| `WAMultiSendPreviewView`, `MultiSend_MediaBrowserItem` | photo/video preview after a paste, one item per pasted file |
| `WAMultiSendBottomBarView_SendButton`, `DocumentShareView_SendButton` | Send in the photo / document preview |
| `MultiSend_BackButton` | cancel the preview |

- **Text:** focus the box, set its value, then a space + delete posted to WhatsApp's process alone
  (`CGEventPostToPid`, never system-wide, so the person's own typing is untouched). Setting the value
  alone doesn't register: the mic button stays. Then press `ChatBar_SendButton`.
- **Attachment** (one message each, before the text): save the person's clipboard, put the file on it,
  ⌘V into the focused box, wait for the preview, **count its items**: more than one → press Back and
  fail, never send. Then press the preview's Send and put the clipboard back. During testing a ⌘V sent
  as V-with-Command-flag (no Command key events) repeated for ~2 s and sent an album of ~100 copies;
  `paste()` now sends Command down, V down, V up, Command up.
- **Before typing,** the right chat must be on screen: WhatsApp's log names the selected chat
  (`chatlist//select-row/ chatJID: <******1234@g.us>`, last four digits kept), and `open_chat` waits
  for that line after its own link.
- **After,** the database must show exactly one new outgoing message in that chat per item
  (`confirm_sent`); fewer or more is an error the UI shows.
- **Background first:** everything runs with WhatsApp behind other apps. When a step doesn't take
  (keys aren't delivered to an app that hasn't been active since launch, or WhatsApp has no window
  after a hidden launch), WhatsApp is shown for a moment and Inbox2 is brought back.
- One action at a time (`BUSY` mutex).

Code: `ui/desktop/src-tauri/src/whatsapp_actions.rs` (commands `wa_send`,
`wa_open_in_whatsapp`, `wa_pick_files`, `wa_actions_status`, `wa_request_accessibility`,
`wa_open_accessibility_settings`), `whatsapp_ax.rs` (AX element walk, keys to one pid, clipboard save
and restore), web `components/WaChatPane/WaComposer.jsx` (Enter sends, attachments via the native
picker; the Accessibility prompt on the first send) + the pane's WhatsApp button.

## Agents (MCP)

The in-app MCP server has three read-only tools over the same queries: `whatsapp_chats`, `whatsapp_messages` and `whatsapp_search` (`mcp/tools/whatsapp.rs`, docs/Vector-MCP.md). An agent with Read permission can read every chat. No tool sends.

## Lore

`ui/desktop/src-tauri/src/whatsapp_lore.rs`, table `wa_lore` (core schema), one row per chat.

- **The ask** = messages after the owner's last reply that need them: every inbound message in a
  1:1 chat; in a group only those whose **first** @mention is the owner, or that quote one of
  their messages without @-addressing anyone (`ZWAMEDIAITEM.ZMETADATA` carries the quoted
  participant **and** every mentioned JID, so it only counts when the text mentions no one). "Hi
  @X, following up on @You's message" (a quote-reply that names the owner) asks X, not you
  (2026-10-26). A mention must be the whole number, in the text or a media caption. The owner's JIDs: WhatsApp keeps its own number encrypted
  (`OwnPhoneNumber`), so candidates are group members that never authored a message, the one named
  in quotes of the owner's own messages (stanza id + JID in the same metadata) is proven, and its
  LID ↔ phone half comes from `LID.sqlite` (`ZWAZACCOUNT`). Without any quote, only a LID + phone
  pair that `LID.sqlite` records as one account, both silent members of ¾ of those groups, stands
  in; otherwise group messages never count as the owner's. `@<number>` mentions display as `@Name` (owner: `@You`).
- The worker reads everything after the owner's last reply (up to 500 messages) plus 12 before it,
  so an ask is never cut off by a fixed window; each model call sees at most the newest 12 of those
  (so a long chat can't outgrow Jev's request limit).
- An open item's `ask_sig` (message count + Core Data `Z_OPT` sums over the ask's messages and their
  media rows, where captions and quote metadata live) is re-checked every pass: an edited ask is
  judged again; one with no message left that still needs the owner (deleted, or edited so the
  group mention is gone) closes (`done_reason = gone`). A chat whose
  judging fails is retried on later passes (`wa_lore_retry`, 5 attempts) while the others go on.
- Every 20 s, per chat changed since the cursor (`wa_lore_cursor`; a first run starts 7 days back):
  a new ask → one Jev call (same labels + priority question as mail), the to-do title from the
  user's text lane, due date / amount from `next_action::extract`, the ontology's grounded pass
  (`ontology::mine_text`, conversation key `wa:<chat_id>`; 1:1 partners also become people).
- **Done** (decided 2026-11-10, replacing Jev judging each reply): any reply from the owner after
  an open ask closes it (`done_reason = reply`), and anything still open three days after its ask
  closes too, counted in calendar days (`done_reason = aged`, every pass, `AGE_OUT_DAYS`; an untick restarts the count): asks handled outside WhatsApp
  otherwise piled up for good. A tick in Lore marks it done too, and unticking reopens it; a newer
  ask reopens it. New asks still need a Jev key; without one the worker only ages items out.
- Without a text lane the title is the ask's opening on one line and the summary is the ask itself
  (up to 280 chars), so a mention-only first line ("@You") isn't the whole item. Items judged
  before that got their summary once from the stored ask range (`wa_lore_summary_backfill`).
- Web: `waItem` in `lib/lore.js`, `fetchWhatsApp` in `hooks/useLore.js`; opening an item (title,
  preview line or sender) peeks the chat (LorePeek) or goes to the WhatsApp tab at the ask.

### Tracked groups

`ui/desktop/src-tauri/src/whatsapp_groups.rs`, tables `wa_groups` + `wa_group_todos` (core
schema). Decided 2026-10-26: Lore keeps a running to-do list for business groups — everyone's
open asks, not only the owner's — and Jev picks the groups.

- **Which groups**: the first time a group changes, one Jev choice (business: clients, prospects,
  partners, suppliers, colleagues, a project; personal: family, friends, hobbies, community, news)
  over its name and newest 12 messages → `wa_groups.business`, `source = ai`. Never judged again;
  the group's Lore page has **Stop tracking / Track this group** (`wa_group_set_tracked`,
  `source = user`). Personal groups go the usual owner-only way. Every active group's newest
  messages reach Jev once for this judgement.
- **The list**: per change of a business group, the user's text lane reads the open to-dos (with
  ids + owners) and the messages since `todo_through_id` (newest 40, each tagged `#<Z_PK>`) and
  answers `{"new":[{title, owner, summary, from}], "done":[ids]}`. `from` must be a message it was
  shown (else the newest), `done` only this group's open ids. `owner` = "You" → `mine`.
- A tracked group's list replaces its owner-only `wa_lore` ask (closed with `done_reason =
  tracked`), so nothing shows twice. **Without a text lane there is no list**: the group keeps
  the owner-only ask.
- Done: the list update marks it (`done_reason = chat`), or a tick (`wa_group_todo_set_done`).
  Also (2026-11-10): your own message in the group closes your earlier to-dos there
  (`done_reason = reply`), and any to-do open three days closes (`done_reason = aged`).
- **Ignore** (2026-10-26): the group page's **Ignore this group** (`wa_group_set_ignored`,
  `wa_groups.ignored`) keeps a group out of Lore entirely: the worker never reads it again (no
  judgement, no list, no owner-only ask) and the web hides what it already holds. Listed in the
  sidebar as "ignored" so **Stop ignoring** stays reachable.
- **Day summary** (2026-10-26): a tracked group's page opens on today's summary, ‹ › stepping
  through earlier days. `wa_group_day_summary(chat, day, fromMs, toMs)` reads that local day's
  messages (`lore_messages_between`, first 200) and asks the text lane for 2–6 bullets (decided,
  asked + who owns it, dates/amounts, open questions). Cached in `wa_group_summaries` per
  (chat, day) and rewritten only when the day has a message newer than `through_id`. Written on
  open, not in the background: an unopened day costs nothing.
- Web: `waTodoItem` (yours → `action_required` → Work & requests; others' → `waiting_reply` →
  Waiting on others), `waGroupsFrom` → `lore.entities.groups` → the **WhatsApp groups** sidebar
  section and `/lore/group/:chatId` (`pages/lore/LoreWaGroup.jsx`: Yours / Waiting on others /
  Recently done + the tracking switch). Each to-do row names its group (a link to that page).

Tests: `cd ui/desktop/src-tauri && cargo test --release --lib whatsapp` (incl. `whatsapp_groups::tests`) (runs against this Mac's
database when present — the debug profile's proc-macros don't load on this macOS build), and
`ui/web/src/lib/__tests__/waMessages.test.js` + `lore.test.js` (tracked-group to-dos).

## Demo mode

With demo data on (`lib/demoData.js`, ⌘K "Turn demo data on"), every WhatsApp read in
`lib/localWhatsApp.js` answers from a fictional set of chats (`lib/demoWhatsApp.js`: 1:1 chats, two
groups, an archived chat, photos from `public/images`, a PDF not on this Mac) — the tab, the columns,
global search, the media viewer and Lore (three asks: a contract, a launch approval, an invoice). The
real `wa_lore` rows are never read (their chat text isn't covered by the demo scrub), and nothing is
sent, marked read, saved or opened. The tab shows in demo mode even when local WhatsApp is off. Demo
mode also pauses the Lore worker (the main window tells the engine `wa_lore_enabled = false` on load;
leaving demo mode — a reload — restores the switch's setting), so no real chat reaches a model during a
demo. Turning local WhatsApp off waits for the engine to confirm before the switch flips, and the
engine confirms only once no Lore pass is running (a pass checks the switch between chats and stops).
The worker is also unarmed at each launch until the main window has sent the effective setting, so a
demo-mode launch can't reach a real chat before the page pauses it.

Demo notifications (⌘K, demo mode only, `lib/demoNotifications.js`): new email, several emails
(stacking), sign-in code (OTP), sign-in link, new WhatsApp message, meeting starting soon, meeting
invitation — all through the real `new-message` path.

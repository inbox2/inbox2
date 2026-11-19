# Notifications

New-message notifications fire when the Rust sync engine detects a previously-unseen message during a poll cycle. The engine emits a Tauri event; the frontend bridges it into the UI.

> **Cloud push** ([Cloud-Push.md](Cloud-Push.md)) adds a second, faster trigger for Gmail/Office365: a provider webhook reaches Rails, which fans a content-free "go sync" signal out over ActionCable (`PushSyncChannel`) to the client. The client then runs a normal sync — which detects the new message and feeds this same path. So cloud push shortens the *time-to-detect*; the notification path below is unchanged.

> **MX mail** takes a second trigger into the same bus. Rails' `MobilePushSender.new_message` — the one place that decides who is alerted for a thread (visible-to audience, no hidden threads, sealed mail content-free or `{from, subject}` preview, new threads held until Jev triage files them) — also broadcasts the finished alert as `{type: "new_message", …}` on the user's own `push_sync_<user>` stream. `lib/pushSync.js` maps it to the engine's `NewMessageNotification` shape (`providerType: 'inbox2'`, `orgId`, `orgSlug` = the domain's workspace slug, no `accountKey`) and emits `new-message`. Desktop and browser both get it; it is not gated on the mobile-push plan. On the card, `lib/notificationActions.js` routes MX: open → the domain inbox (`alertMailTarget`), Read/Archive/Delete → `bulkConversations` (engine-queued on a mirrored desktop), no Triage button (MX triage is tag-based).

## Trigger path

```
Rust sync engine (background poll)
        │
        │  detects new message
        │
        ▼
Tauri event: 'new-message'
        │
        ▼
SyncManager.emit('new-message', payload)
        │
        ▼
useNewMessageNotifications hook (mounted once at app root)
        │
        ├── playPing()              — always
        │
        ├── [Tauri] ────────────────► External notification window
        │                              (frameless, transparent, always-on-top)
        │
        └── [Browser] ──┬───────────► In-app popup (NewMessagePopup portal)
                        │
                        └───────────► System Notification API (when tab is hidden)
```

## Notification modes

Settings → Notifications offers three delivery modes (`ui/web/src/lib/notificationPref.js`,
`NOTIFICATION_MODES`):

- **`custom`** (default) — the bespoke light frosted-glass cards. Desktop uses the
  external Tauri window (`NotificationPage`); browser uses the in-app popup
  (`NewMessagePopup`). Both share the same look: stacked cards, newest at the
  bottom fully expanded, older cards collapsed to title + action buttons, an
  animated blue gradient bottom time-bar.
- **`system`** — native OS notification via `@tauri-apps/plugin-notification`
  (desktop) or the Web Notification API (browser). See `lib/systemNotification.js`.
- **`none`** — no popup; the message is still recorded to the activity feed.

Sound is an independent toggle. The legacy `inbox2_notifications_enabled` boolean
is migrated to a mode on first read (`false` → `none`).

## Meeting invitations on the mail card

A `custom` card for mail that carries an answerable invite
([Meeting-Invites.md](Meeting-Invites.md)) grows an **Accept / Decline** strip
*above* the Read/Archive/Delete/Reply row, borrowing the meeting reminder's look
(brand mark, time line, primary button, amber rail) so an invite reads as
calendar rather than mail. It also takes the reminder's `high` priority, so it
dwells 14s instead of 8s. Tentative is deliberately absent — the reader's banner
(`MeetingInvite.jsx`) keeps the three-way answer; a card that auto-dismisses gets
the two answers people actually give from a notification.

Recognising the invite happens in `useNewMessageNotifications` *before* the card
is built (the alert payload is what the separate notification webview gets), via
`inviteForAlert` in `lib/invites.js`. That is two live provider calls — message
detail, then the ICS bytes — so it is gated twice: the engine's
`hasAttachment` flag on the payload, and a 2.5s timeout after which the card
simply renders as ordinary mail. Answering calls `respond_to_invite` the same way
the reader's banner does, and the message detail it fetched is cached for the
read that usually follows.

MX alerts skip the probe: Rails sends the parsed invite (`messages.calendar_invite`
+ `rsvp_status`, never for sealed mail) with the alert, and Accept/Decline posts to
`orgs/:id/messages/:id/rsvp` — the endpoint the reader's banner uses. The payload carries
`messageKey` + `hasAttachment` for exactly this (`NewMessageNotification`) — the
card's own `key` is the *conversation*.

## Sign-in codes and links on the mail card

A sign-in mail swaps the card's actions on every client. A **code** ("482910 is
your code") shows large with **Copy & delete / Archive / Delete**; Copy & delete
puts the code on the clipboard (grouping space/dash removed) and trashes the
mail. A **sign-in link** (magic link, "verify your email") shows "Opens <host>"
with **Open & delete / Archive / Delete**; the mail is trashed only once the
browser has the link. A code wins when a mail carries both. Desktop cards get
the 14s `high` dwell.

**Detection** runs where the mail is read, never on a client from a body it was
sent: the Rust core's `otp::detect` (`ui/desktop/core/src/otp.rs`) for local
channels, inside `message_notification`, and Rails' `OtpDetector`
(`api/app/services/otp_detector.rb`) for inbox2-hosted mail, inside
`MobilePushSender.new_message` — never for sealed mail. Both are locked to the
`otp` cases in `fixtures/parity/fixtures.json` (real Messy and Husttle login
mails included). Rules: a sign-in vocabulary gate (EN + NL — what keeps a promo's
"use code SAVE20" or an "Order confirmation" off; bare "confirm" doesn't count);
then a code within 80 chars after a word ending in "code" (passcode,
verificatiecode — not "codes") or "PIN"/"OTP", with URLs removed first (or a 4–8
digit number in a subject that itself names a code or sign-in — a pipeline
mail's commit hash in the subject once got a Copy button); else an `https` anchor ranked sign-in
button text › sign-in href (`login`, `verif`, `validat`, `token`, …) › a
generic "Continue"/"Confirm" button, skipping unsubscribe/privacy links; else a
bare sign-in URL in the text.

**Wire shape**: `otp: {code}` or `{link, host}` on the engine's
`NewMessageNotification` and on Rails' desktop cable alert (`lib/pushSync.js`
passes it through). The APNs/FCM push carries flat `otp_code` / `otp_link` +
`otp_host` data keys, sets `aps.category` to `OTP_CODE` / `OTP_LINK` (else
`MAIL`), and leads the alert body with "Code 482910 — " or "Sign-in link · host — ".

**Site icon**: the link's host — `/favicon.ico`, always fetched through the
Rails image proxy (the card never contacts a host the mail named). It sits in
the same 40px slot every mail card has (next section).

**Desktop clipboard**: the panel can never be key window, so copying goes through
`tauri-plugin-clipboard-manager` (`clipboard-manager:allow-write-text`), not
`navigator.clipboard`.

## Sender icon on the mail card

Every `custom` mail card (and the browser's system notification) shows a 40px
icon left of the sender line: the sender's profile picture when the channel has
one (Meta DMs — `from_avatar` on the engine's `NewMessageNotification`), else
the favicon of the sender's domain (a sign-in link's host wins — see above).
Freemail domains (gmail, outlook, icloud, …) get no favicon: that icon names the
provider, not the sender. Nothing found → the slot is simply absent; the card
reads as it did before.

The fetch happens in the main window before the card is built (`lib/otp.js`
`fetchSiteIcon`: image proxy, 1.5s cap, 64KB cap, cached per URL for the
session, misses included) and rides along as a data URL — the Tauri card window
has no API session. Collapsed cards hide the icon.

**Mobile** follows the same order (avatar → sign-in host → sender domain,
freemail skipped, image proxy, 1.5s): iOS posts it as a communication
notification, the icon as the `INSendMessageIntent` sender's image, so it sits small
on the card's left like the desktop (`NotificationManager.withSenderIcon`; needs the
`usernotifications.communication` entitlement + `NSUserActivityTypes`). It used to be
a `UNNotificationAttachment`, which iOS blows up to full width when the card is
expanded (2026-11-05). Android posts
first and re-posts with `setLargeIcon` (`NotificationHelper.postNewMessage`).
MX pushes carry the sender's domain as `from_host` (the push title is a display
name). iOS MX pushes are visible APNs alerts the app never touches, so they stay
icon-less until a Notification Service Extension exists. Known ceiling: a site that
only declares its icon via `<link rel=icon>` has no `/favicon.ico` and shows
nothing; a proper lookup would need an HTML fetch + parse per domain.

## Key files

| File | Purpose |
|---|---|
| `ui/web/src/hooks/useNewMessageNotifications.js` | Global listener — routes events to the correct surface per mode |
| `ui/web/src/lib/notificationPref.js` | Mode + sound preference store (custom / system / none) |
| `ui/web/src/lib/systemNotification.js` | Native OS notification (Tauri plugin / Web Notification API) |
| `ui/web/src/stores/notificationStore.js` | Zustand queue (max 4 visible, 8s auto-dismiss, dedup by key) |
| `ui/web/src/components/NewMessagePopup/NewMessagePopup.jsx` | In-app popup (browser mode) — portal to `document.body`, fixed top-right |
| `ui/web/src/components/MeetingAlert/MeetingAlert.jsx` | The calendar pieces both surfaces slot in — meeting glyph/detail/actions + the invite Accept/Decline strip |
| `ui/web/src/lib/invites.js` | Invite helpers shared by the card and the reader banner — `isRequest`, `formatWhen`, `inviteForAlert`, `respondToAlertInvite` |
| `ui/web/src/pages/notification/NotificationPage.jsx` | Standalone page rendered inside the Tauri notification window |
| `ui/web/src/lib/notificationSound.js` | Plays `/sounds/notification.mp3` at 50% volume |
| `ui/web/src/lib/sync-manager.js` | Event bus bridge — Tauri events → local `on('new-message')` subscribers |

## Unread badges (tabs, account switcher, dock)

One number per channel, in `stores/unreadStore.js` (`byChannel` + the summed
`total`). It has exactly **two** writers, and adding a third is what broke it
repeatedly:

| Writer | What it is | Where |
|---|---|---|
| `setChannelCount(key, n)` | The truth, recounted | `hooks/useChannelUnreadCounts.js` — the ONLY caller |
| `adjust(key, delta)` | Optimistic move on click | every action dispatcher, via `unreadDelta` |

**The count is never derived from a conversation list.** Lists are paginated and
grow as you scroll (see below), so a list-derived badge meant something different
on every screen — MX tabs silently capped at the page size, and the number
changed as you navigated. The recount instead:

- **local channels** — one grouped `COUNT(*)` over SQLite, inbox-folder `EXISTS`
  (must match what the inbox list shows; see the comment in the hook).
- **MX/org** — `GET /orgs/:id/conversations/unread-count[?domain=|?space=]`, an
  exact server-side count over the open pool. Same endpoint the iOS/Android
  app-icon badge uses (`AppBadge.swift` — channel half + domain half).

Recounts fire on: the tab set changing, sync data-change events (throttled 5s),
new MX mail over ActionCable, and window focus. Between recounts the badge moves
by `unreadDelta(action, unread, inInbox)` — the single rule for how an action
moves the number. `inInbox` is judged by the **folder in view**, not the row's
status: filing a thread from inside Spam must not decrement the inbox badge,
while moving it back to the inbox must increment it.

A recount reads asynchronously, so it stamps itself and drops its result if a
local `adjust` landed while it was in flight (`unreadStore.mutations`) —
otherwise a read that started before your click puts the old number back, which
is what "the counter is stuck until I click the tab" always was.

### Why the badge can exceed what a list shows

Both mail lists page, and both load the next page as you scroll:

| List | Page | Scroll trigger |
|---|---|---|
| Channel inbox (`useInboxConversations`) | 50, MX only (local channels read SQLite) | list body near its bottom → `loadMoreConversations` |
| Unified columns (`useUnifiedInbox`) | 50 per column, MX + local alike | a column near its bottom → `loadMoreColumn`; the grid's horizontal rail near its right edge → `loadMoreAllColumns` |

Three rules both share, learned the hard way:

- **Dedupe by id.** Pages are offsets into a list that keeps moving (mail
  arrives, threads get filed), so rows repeat across pages.
- **A short page ends it.** With repeats deduped away, the loaded length can
  never reach the reported total, so the count alone would ask forever.
- **A refresh must not eat the scroll.** Both lists reload themselves (sync, new
  mail, focus, a failsafe tick) and each reload fetches page 1. It refreshes the
  head and keeps the pages below it; only a genuinely different query (folder
  switch, filter, space drill) starts back at the top.

**The Eisenhower matrix is not fed by the pages.** It shows the TRIAGED threads
(the stream shows the rest), and a thread triaged weeks ago sits far below any
first page — deriving it from the loaded rows silently dropped everything past
the page size. Each column fetches its triaged set as a second query alongside
page 1 (`fetchAccount(..., { triagedOnly: true })`: the `Urgent`/`Important`/
`Later` tags server-side for MX, the `priority_*` columns in SQLite for local
channels) and merges it into the same list. That query is one page deep — a
quadrant would under-report before anything vanishes.

While a mobile app is closed the server owns its badge
(`MobilePushSender.badge_count`, stamped absolute on every push). It counts
per membership through `Conversation.visible_to` — the same scope
`#unread_count` serves — so the number on the icon and the number the app
computes when it opens agree for a member who can't see every domain.

## Message payload shape

```js
{
  key: string,             // conversation/message ID (used for dedup + navigation)
  from_address: string,    // "Name <email>" format
  subject: string,
  snippet: string,         // body preview (first ~100 chars)
  updated_at: string,      // ISO timestamp
  email: string,           // receiving account's email address
  accountKey: string,      // channel account key (for navigation)
}
```

## Desktop (Tauri) notification window

A separate Tauri `WebviewWindow` labeled `'notification'`:

- **Position**: top-right of screen, 16px padding from edges
- **Width**: 436px (frozen; `WINDOW_W` in `NotificationPage.jsx` must equal `winW` in the creator). **Height auto-fits** the card stack — `NotificationPage` measures its content (`ResizeObserver`) and calls `setSize`.
- **Styling**: light frosted-glass cards (`backdrop-filter` blur, fixed light palette regardless of app theme), larger type, animated gradient left rail (looping `railSweep`).
- **Properties**: frameless, transparent background, always-on-top, skip-taskbar, non-focusable; converted once to a non-activating NSPanel on macOS. On Windows and X11 the flags alone give the non-activating behaviour. Verified on Windows 11 (2026-11-07): the card appears top-right of the work area and Read / Archive / Delete reach the write-back queue; the frosted light glass shows the main window through it, since no OS blur sits behind a transparent webview there either.
- **Wayland**: no client may position a window, keep it on top or hide it from the taskbar, so the card would land anywhere. `popup_windows_supported` (`commands.rs`, reads `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE`, honours `GDK_BACKEND=x11`) returns false there and `showTauriNotification` posts the system notification instead.
- **Windows toasts** (the "system" mode) only appear from the installed app: the notification plugin sets the AppUserModelID only when it finds the installer's shortcut, so a `tauri dev` run on Windows shows nothing.
- **First-click + keyboard focus (macOS)**: a click that lands in the panel would otherwise promote it to *key window* and yank keyboard focus off the user's active app — tauri-nspanel hardcodes `RawNSPanel.canBecomeKeyWindow` to YES, so the non-activating style mask alone isn't enough. `install_panel_focus_overrides()` (in `commands.rs`, run during panel conversion) does two things: overrides `-[RawNSPanel canBecomeKeyWindow]` → NO so the panel can *never* become key (window-level, so the WKWebView's private subviews can't slip past it — the card has no text input, so it never needs key), and swizzles `-[NSView acceptsFirstMouse:]` → YES for views inside an `NSPanel` so a single click on the now-always-inactive window still reaches the button instead of being swallowed. The click lands on the button; keyboard focus stays with the active app. Other windows chain the original `acceptsFirstMouse:` and keep stock behaviour.
- **Stacking**: the page holds a queue (newest on top, max 4, deduped by key). Each `notification-show` event *pushes* a card; each card auto-dismisses per priority. The window **hides** (not destroys) when the stack empties — the persistent NSPanel is reused for the next alert.
- **Actions**: optimistic — the card is removed immediately and the provider IPC runs fire-and-forget. Safe because the webview persists (only hidden), so the in-flight call isn't aborted. This is what removed the ~1s delay before a card disappeared.
- **Reuse**: if the window already exists, reuses it via `emitTo('notification', 'notification-show', message)` + `show()`.
- **Navigation**: clicking anywhere in the card's text region (header / subject / sender / snippet) or pressing Reply emits `'notification-navigate'` to the main window, which calls `navigateTo()` and focuses the main window. The whole text block is one click target (`.clickable`); the action-button row is excluded.
- **Gestures**: the card text is non-selectable (`user-select: none`) so a drag never starts a selection. A pointer drag rubber-bands left and, when dragged right past `SWIPE_THRESHOLD` (96px), flings the card off-screen and removes it — the macOS swipe-to-dismiss feel. A pointer press that moves less than `TAP_SLOP` (5px) is treated as a tap (open), not a drag, so click and swipe share one gesture handler.

## Browser in-app popup

- Rendered via React portal to `document.body`
- Fixed position, top-right, z-index 9998
- Queue-based: up to 4 stacked, oldest dropped when at capacity
- Each card has an 8s countdown progress bar
- Clicking anywhere on the card navigates to the conversation
- Deduplication: same `key` won't show twice while already visible

## Browser system notification (Notification API)

- Only fires when `document.hidden` is true (tab not focused)
- Permission requested on first mount (if `'default'`)
- Tagged with `inbox2-${key}` to prevent OS-level duplicates
- Silent (sound handled by `playPing()`)
- Auto-closes after 6s

## Meeting reminders

New mail is not the only thing that raises a card. `hooks/useMeetingReminders.js`
ticks every 30s and fires a `meeting_reminder` alert before a meeting starts,
onto the same three surfaces — so `custom` / `system` / `none` and the sound
toggle all work for meetings without a second preference.

```
useMeetingReminders (30s tick, mounted beside useNewMessageNotifications)
        │
        ├── local SQLite  ── fetchEventsInRange()   ← Gmail / Office365 / IMAP
        └── MX API        ── GET /orgs/:id/events   ← inbox2-hosted domains
                │
                ▼
        lib/meetingAlerts.js — dueAlert(): which lead time is owed?
                │
                ▼
        deliverMeetingAlert() → notificationStore → the same card surfaces
```

**Client-side by design.** MX events live in Postgres; local-channel events live
only in the client's SQLite and never touch Rails. A server-side scheduler could
only ever reach half the calendar, so one client tick reads both.

### The firing rule (`lib/meetingAlerts.js`)

Kept free of React and of the app's import graph — it holds the actual rules, so
it is the part with the test (`lib/__tests__/meetingAlerts.test.js`).

| | |
|---|---|
| **Lead times** | The event's own `calendar_reminders` (`method: "popup"`) when it has any, else `10` and `0` minutes. Anything longer than the 2-hour read horizon falls back to the default rather than firing late and mislabelled. |
| **Fired once** | `{ "<eventId>:<lead>": <start ms> }` in `localStorage`, so relaunching at 10:29 doesn't replay the 10:20 alert. Swept after 6h. |
| **Catching up** | Every lead whose moment has passed is spent at once; the *smallest* one is shown, because it's the honest description of how long you actually have. |
| **Grace** | Nothing fires more than 5 minutes after the start — opening the app at lunchtime must not replay the morning. |
| **Snooze** | `snoozeMeeting(eventId)` un-fires the event's keys and holds it for 5 minutes; the next tick re-fires it. One owner of "when does an alert appear", even though the button lives in another webview (the panel emits `meeting-snooze` to `main`). |

### The card

`components/MeetingAlert/MeetingAlert.jsx` supplies the head glyph, the detail
lines and the action row; both surfaces slot them into their *own* CSS module
rather than growing a third card component that would drift from both.

- **Head** — the provider's brand mark, and a label the alert writes itself
  ("Meeting in 10 minutes" / "Starting now").
- **Rail** — amber (`meeting`), turning red and persisting until touched once the
  meeting has started (`priority: urgent`).
- **Detail** — `10:30 – 11:30 · Google Meet`, then location / organiser / the
  RSVP tally.
- **Actions** — **Join**, Snooze 5m, Open (goes to the calendar, not the mail
  list). An event with no link simply has no Join button rather than a dead one.

### Join links (`components/MeetingProviderIcon/meetingProvider.js`)

`detectMeeting(event)` answers one question: where do I click to get into this?

1. **The provider's structured link wins** — Google `conferenceData.entryPoints`
   (video) or `hangoutLink`, Microsoft `onlineMeeting.joinUrl` or
   `onlineMeetingUrl`. Both are pulled by the Rust calendar adapters into
   `calendar_events.metadata.conference` as `{ url, label, code }`
   (`sync/calendar.rs`), so they survive a body that a forwarding client mangled.
   Not necessarily the host brand: a Zoom add-on inside Google Calendar writes
   its own solution into the same field.
2. **Otherwise scan the free text** — `location`, `description`, `title`, `url`,
   first URL on a known conferencing host. This is the only path an emailed ICS
   or an MX event has, and `&amp;` is decoded first or a Zoom link loses its
   `?pwd=` half.

Adding a provider is one row in `HOSTS`. The same call feeds the Join button in
`EventDetailPopup` and the `NextMeeting` sidebar footer (which shows it only
inside its existing ≤30m "soon" window).

## Testing notifications locally

**Auto harness (dev builds):** `ui/web/src/lib/notificationTestHarness.js` fires one
alert ~1.5s after launch, then two more 3s later, then a meeting reminder at 7s
(a Meet link 8 minutes out), so the desktop window's sizing, click-feel, stacking
and the Join button can be eyeballed on every restart. Guarded by
`import.meta.env.DEV`; flip `ENABLED` to `false` to silence it. Armed from
`NewMessageNotifierInner` (main window only).

**Manual:** emit a synthetic event through the sync manager after a delay:

```js
// In browser console, or temporarily in main.jsx:
import('./lib/sync-manager.js').then(m => {
  m.default.emit('new-message', {
    key: 'test-' + Date.now(),
    from_address: 'Sarah Chen <sarah.chen@example.com>',
    subject: 'Q3 Pipeline Review — action needed',
    snippet: 'Hey team, can you review slides 4-8 before standup?',
    updated_at: new Date().toISOString(),
    email: 'team@inbox2.dev',
    accountKey: 'demo',
  });
});
```

**Important**: calling `notificationStore.show()` directly only triggers the in-app popup. To test the full path (including the Tauri system window and sound), always emit through `syncManager`.

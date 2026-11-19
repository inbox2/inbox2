# Mail Live Activity (iOS)

The lock-screen / Dynamic Island card that shows the newest unread message with
inline **Read / Archive / Trash** buttons and a **+N** unread pill (EasyPark-style
persistent card). Buttons act on the mail without opening the app; the card then
advances to the next unread or disappears when the inbox is clear.

This doc is the single reference for how it works end to end and the open
reliability question. Companion detail lives in [iOS-App.md](iOS-App.md) ("Mail
Live Activity") and [Cloud-Push.md](Cloud-Push.md) ("Live Activity"); this doc is
the one to read before iterating.

## TL;DR of the current state (2026-09-13)

- **MX mail** (inbox2-hosted domains): reliable. Rails pushes the card start
  itself with full content.
- **Card actions** (Read/Archive/Trash from the card, and from the notification
  long-press menu): reliable. The card reacts instantly, the action is applied
  durably, and the thread's notification banner is cleared at the same moment.
- **Channel mail** (Gmail/Office365/IMAP) **while the phone is locked**: NOT yet
  reliable. The card depends on iOS delivering a background push, which iOS
  throttles. This is the open question — see [The reliability problem](#the-reliability-problem).

The design was deliberately left in the "app-requested start" shape (below) rather
than switching to a Rails-driven placeholder card, pending a clean retest after
iOS's per-app background-push budget resets (today's session burned it with ~10
rapid test pushes in an hour). If the retest still fails, switch to
[Alternative A](#alternative-a-rails-starts-the-card-directly).

## What it is built from

| File | Role |
|------|------|
| `ui/ios/LiveActivity/MailActivityAttributes.swift` | The `ActivityAttributes` + `ContentState` (the wire contract with Rails) and `MailActivityActionIntent` (the button App Intent). Compiled into **both** the app and the widget extension. |
| `ui/ios/Widgets/Inbox2Widgets.swift` | The `WidgetKit` extension: lock-screen card + Dynamic Island UI. Its own target (`Inbox2Widgets`), embedded in the app. |
| `ui/ios/Sources/MailLiveActivity.swift` | `MailActivityManager` — the app-side brain: starts/updates/ends the card, computes the newest unread, observes ActivityKit, reports tokens, runs button actions. |
| `ui/ios/Sources/PushRegistrar.swift` | `reportLiveActivity(...)` (send tokens to Rails) and `requestLiveActivityStart(_:)` (ask Rails to push-start a card). |
| `ui/ios/Sources/NotificationManager.swift` | `perform(_:)` shared by card + notification buttons; clears the banner up front. |
| `ui/ios/Sources/Inbox2App.swift` | `App.init` wires the singletons + `startObserving()`; `.onOpenURL` handles the card tap. |
| `api/app/services/mobile_push_sender.rb` | `live_activity(...)` fan-out + `KIND_LIVE_ACTIVITY`; `new_message` calls it, `channel_sync` deliberately does not. |
| `api/app/services/mobile_push_payload_builder.rb` | `apns_live_activity_{headers,body}` — the ActivityKit APNs payload. |
| `api/app/jobs/mobile_push_delivery_job.rb` | `deliver_live_activity` — picks `start` vs `update` per device; dead-token recovery. |
| `api/app/services/apns_client.rb` | `ApnsClient::Notification` subclass adding the push-to-start keys Apnotic lacks. |
| `api/app/controllers/api/v1/push_devices_controller.rb` | `live_activity` (token report) + `live_activity_start` (app-requested start, allow-listed content). |

`push_devices` carries two token columns (migration
`20260913000001_add_live_activity_tokens_to_push_devices.rb`): both write-only
through the API like the device token.

- `live_activity_start_token` — the long-lived **push-to-start** token (lets Rails
  create a card while the app isn't running).
- `live_activity_token` — the **running card's** update token (nil when no card).

## The wire contract (`ContentState`)

`MailActivityAttributes.ContentState` (Codable) is the exact shape Rails writes
into the ActivityKit `content-state`. **A missing or renamed key makes iOS drop
the push silently** — keep Swift and `MobilePushSender.live_activity_state` in sync.

```
conversationKey  // the thread to open / act on
accountKey       // channel account key; "" for MX mail
orgId            // MX org key (org_…); "" for channel mail
sender, subject, snippet
unread           // total unread (channel + MX) — the "+N" pill; stamped per device
receivedAt       // epoch seconds (ActivityKit content-state can't carry a Date)
```

`isDomain` = `!orgId.isEmpty`. The card's tap target is
`inbox2://conversation/<conversationKey>` (handled by `.onOpenURL` →
`NotificationManager.pendingConversationKey`, the same path a notification tap uses).

## How a card appears

iOS rule: **an app can only _start_ a Live Activity while in the foreground; it
can _update_ a running one from the background, but never _start_ one there.** So
mail that lands while the phone is locked needs an **APNs push-to-start**. There
are two start paths, by mail type:

### MX mail — Rails starts it (reliable)

`MobilePushSender.new_message` already runs on Rails with the full content, so
right after enqueuing the alert it calls `live_activity(user, content_state:
live_activity_state(...))`. The delivery job sends a push-to-start (or update)
straight to the device. One hop; no dependence on the app waking first.

### Channel mail — the app asks Rails (the open question)

Rails never sees channel mail (Gmail/Office365 sync is client-side SQLite, see
[Channels.md](Channels.md)), so it can't put content on a card. The flow:

1. Gmail's watch → Rails → silent `channel_sync` push wakes the app.
2. The app syncs (`PushRegistrar` `didReceiveRemoteNotification`), then calls
   `MailActivityManager.refresh()`.
3. `refresh()` finds the newest unread. If there's no card and the app is **not**
   foreground, it calls `PushRegistrar.requestLiveActivityStart(state)` — a
   `POST push-devices/live-activity/start` handing Rails the (allow-listed)
   content for **this device only**.
4. Rails' `live_activity_start` action calls `MobilePushSender.live_activity(...,
   devices: [device])`; the delivery job sends the push-to-start with real content.
5. iOS creates the card; `MailActivityManager` observes `activityUpdates`, adopts
   it, and reports its update token back.

**Why not have Rails push-start on `channel_sync` directly?** It was tried and
removed. `channel_sync` fires on *any* mailbox change, including the Gmail-watch
echo of the user's own archive/trash. A direct placeholder start therefore
spawned a spurious "Syncing…" card on every action from any device. The
app-requested path only asks after a sync that actually found new unread mail, so
it never conjures a card from an echo — at the cost of the extra background hops
that iOS throttles.

## How a card updates, advances, and ends

`MailActivityManager.refresh(excluding:)` is the one reconciler. It recomputes the
newest unread across **channels** (`InboxStore.conversations(accountKey: nil,
folder: .inbox, filter: .unread)`) and **MX** (`CloudSession.conversations(view:
"Unread")`), then:

- newest unread exists → `update` the running card to it (or start, per above);
- nothing unread → `end` the card immediately.

It is called on: foreground, every `new-message` event, after a `channel_sync`
wake-sync, after any conversation action (`EngineModel.perform`,
`CloudSession.markChanged`), and after the notification-action queue drains.

**Card-first on a button press.** `MailActivityManager.perform(...)` calls
`refresh(excluding: conversationKey)` **before** applying the action, so the card
moves to the next unread (or ends) instantly instead of waiting for the write-back
+ badge round-trip. The action is durable (engine queue for channels, one API call
for MX), and a trailing `refresh()` reconciles.

## The buttons (App Intents)

`MailActivityActionIntent` is a `LiveActivityIntent` with `openAppWhenRun = false`.
iOS runs its `perform()` **in the app's process** (launching it in the background
if needed). The extension never touches the engine — `#if !INBOX2_WIDGET` compiles
the engine-touching body out of the widget target, and `MailActivityManager.perform`
runs only in the app.

Button `perform()` reuses `NotificationManager.perform(_:)`, the same durable queue
the notification long-press buttons use, so both surfaces share one code path.

`NotificationManager.perform` also **clears the thread's banner up front**
(`removeDelivered`), and `EngineModel.perform` / `CloudSession.perform` /
`markRead` clear it for archive/trash/spam/read done anywhere in the app
(`NotificationManager.bannerClearingVerbs`) — so acting on the card removes both
the card and its notification at once, not on the next sync reconciliation.

## Token lifecycle

`MailActivityManager.startObserving()` (called from `App.init`, so it runs even on
a background launch) sets up three observers:

- `pushToStartTokenUpdates` → `reportLiveActivity(startToken:)`. Persisted and
  re-sent after a fresh device registration (a new device row has no tokens), and
  retried on foreground until the API acknowledges it (`ensureRegistered`).
- each card's `pushTokenUpdates` → `reportLiveActivity(activityToken:)`.
- each card's `activityStateUpdates`: on `.ended`/`.dismissed`, if no card remains,
  report `activityToken: nil` so Rails stops updating a dead token.

At start, if no card is running after a 5 s settle (ActivityKit may not have listed
cards yet), the manager reports `activityToken: nil` to clear a stale server token
(reinstall / swipe-away while the process was dead).

**Delivery-side recovery** (`MobilePushDeliveryJob`): a 410/Unregistered on a
live-activity `update` means the *card* is gone, not the device — the job clears
`live_activity_token` and push-starts a fresh card in the same run. A 410 on the
device's own push token still deletes the device row as before.

## The APNs payload

`MobilePushPayloadBuilder.apns_live_activity_headers`:

```
apns-push-type: liveactivity
apns-priority:  10
apns-topic:     com.inbox2.ios.push-type.liveactivity   # <bundle>.push-type.liveactivity
```

`apns_live_activity_body(spec, event:, unread:)`:

- always: `timestamp`, `event` (`start`|`update`), `content-state` (the ContentState
  keys + per-device `unread` + `receivedAt`).
- `start` only: `attributes-type: "MailActivityAttributes"`, `attributes: {}`, and
  an `alert` (title = sender, body = subject) — what iOS shows on the lock
  screen / Watch when creating the card.

`ApnsClient::Notification` subclasses Apnotic's `Notification` to emit
`attributes-type` / `attributes`, which Apnotic doesn't know.

## The reliability problem

iOS applies delivery discretion to **background** pushes — both silent
`content-available` pushes and, in practice, `liveactivity` push-to-starts —
especially when the device is idle/locked and when an app has sent many pushes
recently. Every path that needs the phone to act in the background before a card
appears is exposed to this:

```
channel mail while locked:
  Gmail watch → channel_sync push  [throttleable]
             → app wakes + syncs
             → requestLiveActivityStart → Rails
             → liveactivity push-to-start [throttleable]
             → card
```

Observed 2026-09-13 (test 10): the silent wake *did* arrive, the app asked Rails,
Rails sent the push-to-start, APNs accepted it — but iOS did not render the card
until the app was opened (foreground local start). Test 9: the silent wake never
arrived at all. Both are consistent with heavy throttling after ~10 test pushes in
an hour.

MX mail avoids the first two hops (Rails starts directly) and was reliable
throughout.

### Diagnosing it

The manager writes a plain-text trace to
`Documents/inbox2/live-activity.log` on the device (via `note(...)`), pullable
**without root**:

```sh
xcrun devicectl device copy from \
  --device <CoreDevice-UUID> \
  --domain-type appDataContainer --domain-identifier com.inbox2.ios \
  --source Documents/inbox2/live-activity.log --destination /tmp/la.log
```

Cross-check the server side (prod):

```sh
export KUBECONFIG=deploy/prod/kubeconfig.yaml
kubectl -n inbox2-prod logs deploy/api    --since=5m | grep live-activity
kubectl -n inbox2-prod logs deploy/worker --since=5m | grep MobilePushDeliveryJob
kubectl -n inbox2-prod exec deploy/api -c api -- bin/rails runner \
  'd=PushDevice.where(platform:"ios").first; puts "start=#{d.live_activity_start_token.present?} act=#{d.live_activity_token.present?}"'
```

A useful sequence in the phone log is `asking Rails to push-start …` with no
following `activity appeared …` → iOS dropped the push-to-start.

### To retest cleanly

Send **one** mail to a channel address with the phone locked and untouched for a
few minutes first, so the app isn't in the throttled state a test burst creates.
If the card appears on its own within ~a minute, the app-requested design holds.

## Alternatives considered

### Alternative A — Rails starts the card directly (on `channel_sync`)

Have Rails push-start on the Gmail signal (the high-priority `liveactivity` lane is
delivered more reliably than a silent `content-available` push), with a
content-free placeholder ("Syncing…") that the app fills in after its sync.

- **Pro:** one hop, most reliable delivery while locked.
- **Con:** a ~1 s "Syncing…" flash, and an archive/trash from **any** device
  briefly spawns a card (the echo). Mitigate with a per-device **suppression
  window**: when the phone performs an action it tells Rails to skip
  `channel_sync` live-activity starts for ~90 s. Kills the phone's own echoes;
  desktop-originated echoes still leak occasionally.

This is the fallback if the app-requested design proves unreliable in normal use.
The placeholder plumbing was fully built once (kind `KIND_LIVE_ACTIVITY` +
`placeholder` flag) and removed in commit history — reintroducing it is mechanical.

### Alternative B — Rails-direct, sender-only header

Rails push-starts with whatever it can see (nothing for channels → "New mail").
Reliable but uninformative for channel mail; rejected.

## Requirements / gotchas

- `NSSupportsLiveActivities: true` and the `inbox2` `CFBundleURLTypes` scheme
  (both in `ui/ios/project.yml`).
- New file under `Sources/`/`LiveActivity/`/`Widgets/` → `xcodegen generate`
  before building (the `.xcodeproj` is generated + gitignored).
- The `Inbox2Widgets` target must **not** link the engine; keep engine-touching
  code behind `#if !INBOX2_WIDGET`.
- ContentState is the wire contract — a schema drift between Swift and Rails is a
  silent no-show, not an error.
- The extension has no theme runtime: card colours are literals in
  `Inbox2Widgets.swift` (dark navy surface, plain dark buttons, red Trash, brand
  mark = the downscaled app-icon master in `Widgets/Assets.xcassets`).
- iOS ends any Live Activity after ~8 h; the next foreground or push-to-start
  recreates it.
- The card and the ordinary notification banner both show for the same mail by
  design (the banner plays the sound, carries the long-press menu, and remains in
  Notification Center history). To show only the card while locked, suppress the
  banner when a card exists for that conversation — not currently done.

## Android parity

Tracked in [Android-App.md](Android-App.md) §10. The Android counterpart is an
**ongoing notification** (`setOngoing(true)`, `BigTextStyle`, three `addAction`s →
the same receiver as the notification buttons), posted/updated from the same
"newest unread" query and cancelled at zero unread. No ActivityKit tokens or
push-to-start plumbing needed there (FCM already wakes the app), and Android can
show the action buttons **inline on the collapsed card**, which iOS cannot.

## Lore: "Next up · Done"

A second, separate card for Lore's Today page (TODO 48.13), modelled on the zones card and
`ZoneDoneIntent`. **Opt-in**: the lock icon on the Next up card (`LoreActivityManager.isEnabled`,
off by default). It shows `LoreToday.nextUp` with its bucket tag, sender and a **+N** for what is
left.

- `ui/ios/LiveActivity/LoreActivityAttributes.swift` (attributes + `LoreDoneIntent`, both targets),
  `ui/ios/Sources/LoreLiveActivity.swift` (the manager), `LoreLiveActivity` in
  `Widgets/Inbox2Widgets.swift`.
- Started only from the foreground (`Activity.request` needs it); no push-to-start. `sync(_:)` runs
  after every Lore reload and starts, updates or ends the card.
- Done runs in the app process: the verb goes through the notification-action queue
  (`NotificationManager.perform`, durable, waits for a cold-started engine) — `archive`, or
  `lore_done` for a personal bucket on a shared domain — then the manager re-reads Today and moves
  the card on. A background update never starts a new card.
- iOS ends a Live Activity after its time limit; the next foreground reload starts a fresh one.

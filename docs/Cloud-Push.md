# Cloud Push for Local Channels (Gmail / Office365)

Realtime new-mail delivery for external channels (Gmail, Office365) **without ever
exposing the user's OAuth token to our cloud infrastructure**. Local channels are
otherwise fully client-side (see [Channels.md](Channels.md) and the memory note
`feedback_sync_architecture`): the Rust sync engine holds the encrypted tokens and
talks to providers directly, learning about new mail only by polling every 60s.
Cloud push closes that latency gap while keeping tokens on the device.

## The key idea — token never leaves the client

- The **client** (which already has the token) creates the provider-side push
  subscription, pointing its webhook/topic at **our Rails backend**:
  - Gmail: `users.watch` → a Cloud Pub/Sub topic we own.
  - Microsoft: `POST /subscriptions` with `notificationUrl` → our Rails endpoint.
- The provider POSTs a **content-free change signal** to Rails (Gmail:
  `{emailAddress, historyId}`; Microsoft: subscription id + `clientState`). No token,
  no message body.
- Rails maps the signal to the user and **fans it out over ActionCable** as a
  lightweight "this mailbox changed — go sync" nudge.
- The client receives the nudge and runs its normal `connect_and_sync` against the
  provider with its own token.

**Rails only ever sees "mailbox X changed" — never the token, never the message.**

```
Add Gmail/O365 channel  ──▶  Frontend: GET /channel-push-subscriptions?email=…
                                   │
              ┌────────────────────┴───────────────────────┐
       sub exists & active                          no sub  &  push_enabled?
              │                                            │
     subscribe to                              invoke('register_push', {accountKey})
     PushSyncChannel (WS)                       └─ engine: users.watch / POST /subscriptions
                                                   (client token + config from Rails)
                                                └─ engine: POST /channel-push-subscriptions
                                                   (mapping only: email, sub id, expiry)
                                                └─ frontend subscribes to PushSyncChannel

Provider detects new mail ─▶ POST /api/v1/push/{gmail,microsoft}  (content-free, no token)
   └─ Rails verifies (OIDC/token | validationToken+clientState)
        └─ ActionCable.broadcast "push_sync_<usr_key>"
             └─ Frontend PushSyncChannel.received({provider,email})
                  └─ map email→accountKey ─▶ syncManager.resyncChannel ─▶ start_sync
```

## Responsibilities

| Layer | Owns |
|-------|------|
| **Rust engine** | Provider-subscription *lifecycle* (create/renew/delete — needs the token) + reporting the mapping to Rails. |
| **Frontend (web)** | The receive websocket (`@rails/actioncable`), the register/check orchestration, the on/off toggle, offline catch-up. |
| **Rails** | Mapping store, provider webhook receivers, ActionCable fan-out, gating, lease GC. |

## Rails

### Model — `ChannelPushSubscription` (`cpsub_…`)
Per-user (personal mailboxes), distinct from the browser-Web-Push `PushSubscription`.
Stores only the **mapping** — `provider`, `external_email`, `provider_subscription_id`,
`client_state`, `expires_at` (provider-side), `lease_expires_at`/`last_seen_at`
(Rails-side lease), `status`. **No OAuth token.** Enums are model constants
(`PROVIDERS`, `STATUSES`). Unique on `(user_id, provider, external_email)` so any
device can (re)register idempotently.

### Endpoints
- `GET  /api/v1/channel-push-subscriptions?email=` — the client's "does a sub already
  exist?" check; returns active subs + `push_enabled`.
- `POST /api/v1/channel-push-subscriptions` — client reports a sub it created
  (idempotent upsert; **gated** by `push_enabled?`). Bumps the lease.
- `PATCH /…/:id`, `DELETE /…/:id` — renew / teardown.
- `GET  /…/config` (action `push_config`) — topic name + webhook base + gating, so the
  engine can build the Gmail `topicName` / Microsoft `notificationUrl`.
- `POST /api/v1/push/gmail`, `POST /api/v1/push/microsoft` — **unauthenticated**
  provider webhook receivers (`PushWebhooksController` inherits `ApplicationController`,
  not `BaseController`).

### Webhook verification
- **Gmail** (`GmailPushVerifier`): the shared verification token on the Pub/Sub push URL
  (`?token=…`, env `GMAIL_PUBSUB_VERIFICATION_TOKEN`). When unset (dev/test) requests are
  accepted. *TODO: production should also verify the OIDC bearer JWT (JWKS signature, `aud`,
  service-account `email`).*
- **Microsoft**: the subscription-creation handshake echoes `validationToken` as
  `text/plain`; each notification's `clientState` is `secure_compare`d against the stored
  secret.

### Fan-out & channel
`ChannelPushBroadcaster.call(sub, history_id:)` broadcasts `{type:"channel_sync",
provider, email, history_id}` to `push_sync_<usr_key>`. Payload is a pure indication —
**never** message content. `PushSyncChannel` streams from that per-user topic; auth is the
existing `ApplicationCable::Connection` token query param.

### Lease / lifecycle (reclaiming abandoned subs)
A user can register a sub then never return. Two layers reclaim it:
- **Provider side (automatic):** Gmail watch (~7d) and Graph subscriptions (~3d) only
  survive while a running client renews them. Walk away → webhooks cease within days.
- **Rails lease:** every connect/renew stamps `last_seen_at` + `lease_expires_at = now +
  30 days`. **Opening the channel at least once a month keeps the lease alive.**
  `ChannelPushSubscriptionSweeperJob` (daily, `config/recurring.yml`) flips lapsed rows to
  `expired`; expired rows are skipped by the broadcaster and webhook receivers. Coming back
  re-registers transparently (the `index` reports "no active sub" → the engine's normal
  register path runs).

### Gating (paid feature — flipped, TODO 45.6)
A single chokepoint `User#push_enabled?`: true when any of the user's active orgs is on a
paid plan (`PUSH_FREE_FOR_ALL=1` restores the ungated behavior for dev/promos). Gates both
cloud push for local channels AND mobile push (`MobilePushDeliveryJob`). The client's
toggle is ANDed with this — push runs only when **both** are on.

### Production webhook auth (TODO 45.6)
`GmailPushVerifier` enforces two layers when configured: the shared `?token=` secret
(`GMAIL_PUBSUB_VERIFICATION_TOKEN`) and the Pub/Sub OIDC bearer JWT — verified against
Google's JWKS via googleauth (`Google::Auth::IDTokens`), with `aud` = the webhook URL
(`GMAIL_PUBSUB_AUDIENCE`, defaults from `PUSH_WEBHOOK_BASE_URL`) and the service-account
`email` claim pinned to `GMAIL_PUBSUB_SERVICE_ACCOUNT`. The topic, push subscription
(with its `oidc_token` block), and push service account are Terraform-managed in
`deploy/gcp-pubsub/` — its outputs name the env values to set on the API.

## Rust engine

- `ProviderAdapter` gains `create_push_subscription` / `renew_push_subscription` /
  `delete_push_subscription` (default: `UnsupportedCapability`, so IMAP — which uses IDLE
  — is unaffected). Implemented for Gmail (`users.watch` / `users.stop`) and Microsoft
  (`/subscriptions` create / PATCH-renew / DELETE). They use the adapter's own
  `TokenManager` — the token is never sent to Rails.
- `sync/push.rs` orchestrates: `register_push`, `renew_push_due`, `deregister_push`. It
  fetches config + reports the mapping to Rails using the `rails_jwt` from `ApiContext`.
  Renewal is **idempotent** — re-POST and Rails upserts + re-stamps the lease.
- Local table `push_subscription_state` (in `001_create_schema.sql`) holds sub metadata
  (never tokens) for renewal timing. Renewal runs on the engine's 60s poll tick; **polling
  remains the fallback** so push failures degrade gracefully.
- Tauri commands `register_push` / `deregister_push` (routed over the IPC bus like
  `add_external_account`, so the CLI host handles them).

## Frontend (web)

- `lib/pushSync.js` (singleton): opens `PushSyncChannel` via the shared `getConsumer()`
  (`lib/cable.js`); on a `channel_sync` signal it maps `email → accountKey` and calls
  `syncManager.resyncChannel`. `ensureForAccount` runs the check-then-register flow;
  `disableAll` tears down on toggle-off.
- `hooks/usePushSync.js`: lifecycle — ensures subscriptions for connected accounts,
  reacts to the toggle, and on regaining connectivity (`window 'online'`) re-ensures +
  `resyncAll()` to catch up missed pushes (ActionCable handles reconnect/backoff itself).
  Wired in from `useExternalAccountSync`; new channels register from `startProviderSync`.
- Toggle: `lib/cloudPushPref.js` (`cloudPushPref`, defaults **on**), surfaced as a Switch
  on the Notifications settings tab (`pages/settings/NotificationSettings.jsx`).

## Mobile push (APNs / FCM)

The websocket fan-out only reaches running desktop clients; mobile apps get real
platform push. Same privacy split as everything above:

- **`channel_sync` (silent)** — mirrors the ActionCable signal for Gmail/Microsoft
  channels. APNs: `content-available: 1`, push-type `background`, priority 5, no
  alert. FCM: data-only (no `notification` key), priority HIGH. The app wakes, runs
  its normal all-accounts sync with its own tokens, and the engine's `new-message`
  events post the rich **local** notification — content never transits Rails. iOS
  throttles silent pushes; BGAppRefresh (15-min wakes) remains the fallback.
- **`new_message` (visible)** — MX-pool mail lives in Rails, so the push carries
  sender/subject + `conversation_id` for tap-to-open. Fanned out to every active
  human member of the org (`InboundMailProcessor#notify_mobile_devices`); spam
  conversations never alert.
- **`remove_notification` (silent)** — clears a *delivered* banner once its MX
  conversation has left the inbox elsewhere (trash/archive/spam/snooze/merge), so a
  stale lockscreen alert doesn't linger after you dealt with the mail on another
  device. APNs has no server-side "delete notification" — the app must call
  `removeDeliveredNotifications`, so this rides the silent lane to wake it. Fired
  from `ConversationsController` (single + bulk actions) via
  `MobilePushSender.remove_for_org`, keyed `rm-<conversation_key>`; iOS/Android match
  the delivered notification by conversation key (`thread-id` / tray tag) and cancel
  it. MX-pool only — Rails never sees channel mail, so a desktop delete of a
  Gmail/Microsoft thread can't be pushed. **Channels reconcile client-side instead:**
  after a `channel_sync` wake-sync (and on app foreground) the app re-reads its local
  SQLite and drops any on-screen notification whose conversation is now gone
  (deleted/merged), hidden (trash/archive/spam), or **already read** —
  `PushRegistrar.reconcileDeliveredNotifications` (iOS) /
  `SyncWorker.reconcileNotifications` (Android). Caveat: silent delivery is
  best-effort (throttled when locked / Low Power), so removal is timely-but-not-
  guaranteed on iOS; FCM data messages are more reliable on Android.

### App-icon unread badge

The badge reflects the **unified** unread count = offline-channel unread (local
SQLite) **+** inbox2-domain (MX) unread. Two cooperating sources keep it right
whether the app is alive or closed:

**Client (authoritative while running).** The app owns both halves and sets the exact
total whenever it runs.
- **iOS** (`AppBadge`): channel half from `InboxStore.unreadCount(nil)`, refreshed on
  every data-changing engine event, after a background sync, and on foreground
  (`EngineModel.refreshChannelBadge`). Domain half from `GET
  …/conversations/unread-count` (open + unread) via `CloudSession.refreshUnreadCount`,
  refreshed on sign-in, after each domain mutation, and on foreground; cleared on
  sign-out. `UNUserNotificationCenter.setBadgeCount(sum)`.
- **Android**: stock Android has no arbitrary app-icon number — the launcher badge is
  driven by the count of active notifications. So the badge is kept correct by keeping
  the tray in sync (post on new mail, remove/reconcile on read/delete/hide). No
  `setBadgeCount` equivalent; we avoid OEM badge hacks (ShortcutBadger et al.).

**Server (closed-app accuracy, iOS/APNs only).** So a push that lands while the app is
closed shows the right count, the delivery job stamps an absolute `aps.badge` on every
iOS push = the user's domain/MX unread (`MobilePushSender.badge_count`) **+** the
device's last-reported channel unread. The client reports its channel unread to `POST
…/push-devices/unread` (on change, via `PushRegistrar.reportChannelUnread`) and it's
stored on `PushDevice.channel_unread`. FCM has no app-icon badge, so Android skips
this. The next time the app runs it overrides the stamped value with the exact live
total, so any drift (e.g. channels changed while closed) self-corrects.

- **`badge` (no notification, iOS only)** — the push that exists purely to carry that
  stamped count, for when the unread pool moves on ANOTHER device (mark read/unread,
  spam, trash, archive, restore from spam/trash, unsnooze). Payload is `aps.badge` and
  nothing else: no alert (no banner, no sound) and no `content-available` (the app
  isn't woken; whatever it computes on its next run wins anyway). Fired from
  `ConversationsController` via `MobilePushSender.refresh_badge_for_org`, collapse key
  `badge`, skipped for Android in `MobilePushDeliveryJob`.
  **It rides the alert lane, not the background lane, and that's the whole point:**
  removal pushes already carried a fresh badge, but as `apns-push-type: background`
  they're throttled — marking spam on the desktop left the iPhone badge stale until the
  app was next opened, and mark-as-read sent no push at all. A badge-only payload is a
  user-visible change, so APNs delivers it at priority 10.
  **Debounced on the trailing edge** (`MobilePushSender::BADGE_DEBOUNCE`, 15s): dwell
  auto-read marks a thread read after 5s, so working through an inbox would fire one
  push per device per thread to settle on a single number. The first change claims the
  window with an `unless_exist` cache write (atomic in solid_cache — a row lock, so it
  holds across pods) and schedules one delivery `wait: 15.seconds` out; every change
  inside the window rides it, because the job reads the count when it *runs*, not when
  it's enqueued. Trailing edge, not leading: a leading-edge throttle would push the
  first count and swallow the rest, leaving the badge stale at exactly the value the
  user has already moved past. Only badge pushes are debounced — `new_message` and
  `remove_notification` still go out immediately.
  The clients must keep **both halves** fresh on a background wake for this to hold: a
  sync that recomputes only the channel half re-applies `channel + last-known domain`
  and would overwrite the pushed number, so the `channel_sync` handler and the
  BGAppRefresh task call `CloudSession.refreshUnreadCount()` alongside
  `refreshChannelBadge()`.

**Rails**: `PushDevice` (`pdev_…`, unique global `token`, `platform` ios|android,
`environment` sandbox|production — debug iOS builds get sandbox APNs tokens).
`POST /api/v1/push-devices` (idempotent upsert on token; a device that signs into a
different account moves with it), `DELETE /api/v1/push-devices?token=…` (user-scoped).
`MobilePushSender` builds a platform-agnostic spec and enqueues `MobilePushDeliveryJob`
per device; `MobilePushPayloadBuilder` maps spec → wire payloads;
`ApnsClient` (apnotic, HTTP/2, p8 token auth, per-environment pools) /
`FcmClient` (googleauth + FCM v1). Dead tokens (APNs 410/`Unregistered`, FCM
`UNREGISTERED`) delete the row — never retried; transient failures retry with backoff.
Env (`MobilePushConfig`, each platform independently optional): `APNS_KEY_P8`
(\n-escaped PEM), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (default
`com.inbox2.ios`), `FCM_SERVICE_ACCOUNT_JSON`, `FCM_PROJECT_ID`.

**iOS** (`Sources/PushRegistrar.swift`): `@UIApplicationDelegateAdaptor`; registers
for remote notifications at launch (silent pushes need no permission), POSTs the hex
token with the image-proxy bearer (API key, else MX session), `environment: sandbox`
in DEBUG. Silent `channel_sync` → `EngineModel.syncAllAndWait()` then
`reconcileDeliveredNotifications`; `remove_notification` →
`NotificationManager.removeDelivered(conversationKeys:)`. Entitlement
(`aps-environment`) + `remote-notification` background mode come from `project.yml`.

**Android** (`fcm/FcmService.kt`, `fcm/FcmTokenManager.kt`): google-services plugin +
`app/google-services.json` (Firebase project `inbox2-497321`, committed — not secret).
`channel_sync` → expedited `SyncWorker.syncNow()` (a full sync doesn't fit
`onMessageReceived`'s ~10s budget; the worker then runs `reconcileNotifications`);
`remove_notification` → `NotificationHelper.removeDelivered`. `new_message` is
**data-only** (title/body in the data map — a `notification` message would be rendered
by the system while backgrounded, with no action buttons), so `FcmService` posts it
through the same `NotificationHelper.postNewMessage` as channel mail: tagged by
conversation key (so removal/reconcile can cancel it), Mark as read / Archive / Trash
inline (`NotificationActions`, routed by `organization_id`), taps land in
`consumeNotificationTap` via the `conversation_id` extra. Token registration is deferred until a bearer exists and
re-runs after MX login; sign-out forgets the marker so the next login re-registers.

FCM sender identity: service account `inbox2-fcm@inbox2-497321.iam.gserviceaccount.com`
(`roles/firebasecloudmessaging.admin`), key kept out of git (test env: tfvars).
APNs is configured (token auth, team `KF53B4S5HD`): the `.p8` Auth Keys live in
`deploy/test/terraform.tfvars` (gitignored) — production key `YY282MH435`
(`APNS_KEY_P8`/`APNS_KEY_ID`) plus a sandbox-only key `7R2X5PW65D`
(`APNS_SANDBOX_KEY_P8`/`APNS_SANDBOX_KEY_ID`), since debug builds register
`environment: sandbox` and a portal key can be environment-restricted. One token
key is account-wide (all topics, both gateways). The values reach the cluster as a
k8s secret on `terraform apply`; `MobilePushConfig.apns_configured?` gates delivery
on them being present, so if iOS pushes aren't arriving, confirm the latest
`terraform apply` ran (the secret data is sensitive — not visible in tf state) and
that the device registered the matching environment. The `.p8` files themselves are
kept out of git; do not paste private keys into docs.

### Live Activity (ActivityKit push)

The iOS **Mail Live Activity** (lock-screen / Dynamic Island card with the newest
unread message + Archive / Read / Trash, see [iOS-App.md](iOS-App.md) "Mail Live
Activity") can only be *started* by the app while it is in the foreground; iOS lets
the app *update* a running card from the background but never create one. So for
mail that lands while the phone is locked the start comes from Rails
(push-to-start, iOS 17.2+):

- **Tokens.** `PushDevice` carries two ActivityKit tokens the app reports via
  `POST push-devices/live-activity` (`start_token` / `activity_token`, each applied
  only when present, `activity_token: null` when the card ends):
  `live_activity_start_token` (long-lived push-to-start token) and
  `live_activity_token` (the running card's update token). Both are write-only
  like the device token.
- **Sender.** `MobilePushSender.live_activity(user, content_state:, devices:)`
  fans a `live_activity` spec (kind `KIND_LIVE_ACTIVITY`) to the user's iOS devices
  holding either token. Two callers: `new_message` (MX) with real content
  (`live_activity_state`: `conversationKey`/`orgId`/`sender`/`subject`/`snippet`,
  sealed mail gets the same bounded preview as the alert), and the **app itself**
  via `POST push-devices/live-activity/start` (allow-listed `content_state`, this
  device only) after a channel wake-sync finds new unread mail with no card up.
  `channel_sync` deliberately starts nothing: Rails can't tell new mail from the
  Gmail-watch echo of the user's own archive/trash write-back, and a placeholder
  card on every mailbox change was exactly that noise.
- **Delivery.** `MobilePushDeliveryJob#deliver_live_activity` picks the event per
  device: `update` to `live_activity_token` when the card is running, else `start`
  via the start token. `MobilePushPayloadBuilder.apns_live_activity_body` builds the ActivityKit
  payload (`timestamp`, `event`, `content-state` + per-device `unread` = the badge
  count and `receivedAt`; a start adds `attributes-type: MailActivityAttributes`,
  `attributes: {}` and an `alert`), headers `apns-push-type: liveactivity`,
  priority 10, topic `<bundle>.push-type.liveactivity`. `ApnsClient::Notification`
  subclasses Apnotic's to add the two push-to-start keys it lacks.
- **Dead tokens.** A 410/Unregistered on a live-activity push means the *card* is
  gone (ended/dismissed before the app could report it), not the device: the job
  clears `live_activity_token` and the next push starts a fresh card.
- **Content-state keys are the wire contract** with the Swift `ContentState`
  (Codable): a missing or renamed key makes iOS drop the push silently.

## Development — Tailscale Funnel

Provider webhooks need a **public HTTPS** URL; dev Rails is `localhost:4000`. Use the paid
Tailscale **Funnel**:

```sh
tailscale funnel 4000          # public https://<machine>.<tailnet>.ts.net → localhost:4000
```

Env (API):

```sh
PUSH_WEBHOOK_BASE_URL=https://<machine>.<tailnet>.ts.net   # serves microsoft notificationUrl base
GMAIL_PUBSUB_TOPIC=projects/<proj>/topics/<topic>           # Gmail users.watch topicName
GMAIL_PUBSUB_VERIFICATION_TOKEN=<random>                    # appended to the Pub/Sub push URL
```

Gmail one-time GCP setup: create the topic + a **push subscription** delivering to
`<base>/api/v1/push/gmail?token=<verification-token>`, and grant the topic publish rights
to `gmail-api-push@system.gserviceaccount.com`. Microsoft needs no console setup — the
client supplies the `notificationUrl` per subscription. Prod uses the same env keys with
the real domain; no code change.

> **The Gmail push-subscription endpoint is GCP infra, not repo/Terraform** — changing
> `PUSH_WEBHOOK_BASE_URL` does **not** repoint it. When the webhook host changes (e.g. the
> test→prod cutover, which left `gmail-push-to-rails` aimed at the destroyed
> `test-api.inbox2.com`), update it manually or Gmail webhooks silently stop: `users.watch`
> still succeeds and subs read `active`, but `last_notification_at` never advances and no
> `/api/v1/push/gmail` requests arrive. See Go-Live §4.1 for the `gcloud … subscriptions
> update` command. Microsoft is immune (per-subscription `notificationUrl` follows the host).

### Backend reset and stale mobile registrations
Mobile registration (`/push-devices`) dedupes client-side on a stored marker so it only
POSTs when the token/environment change. That marker is **scoped to the API base**, and a
`/push-devices/unread` **404** (the API has no row for this token — e.g. a fresh prod
database) clears it and forces a re-register. Without this, a server-side device wipe under
an unchanged hostname would leave a device believing it's registered forever (`PushDevice`
count stuck at 0, silent `channel_sync`/visible pushes never delivered) — exactly what the
prod cutover produced before the fix. See `ui/ios/Sources/PushRegistrar.swift`.

## Verification

1. **Rails specs:** `cd api && bundle exec rspec spec/requests/api/v1/channel_push_subscriptions_spec.rb
   spec/requests/api/v1/push_webhooks_spec.rb spec/channels/push_sync_channel_spec.rb
   spec/jobs/channel_push_subscription_sweeper_job_spec.rb spec/services/channel_push_broadcaster_spec.rb`.
2. **Engine:** `cd ui/desktop/src-tauri && cargo test --lib push`. Rebuild the app for live
   use (Rust changes need a full rebuild — `feedback_rebuild_tauri`).
3. **Live e2e (Tailscale):** connect a real Gmail + O365 account → confirm a row lands in
   `channel_push_subscriptions`. Send a test email → provider POST → ActionCable broadcast →
   frontend `resyncChannel` → message arrives **before** the 60s poll would fire.
4. **Resilience:** go offline (DevTools), send mail, restore → ActionCable reconnects and
   the `online` handler's `resyncAll` catches up. Fast-forward `expires_at` → the poll-tick
   renewal re-registers idempotently (no duplicate rows).
5. **Toggle:** flip the Notifications → "Cloud push" switch off → provider subs are
   deregistered, the WS drops, polling continues; on → realtime resumes.
6. **Lease GC:** backdate `lease_expires_at`, run `ChannelPushSubscriptionSweeperJob` → row
   goes `expired`, broadcaster stops, reconnecting re-registers.

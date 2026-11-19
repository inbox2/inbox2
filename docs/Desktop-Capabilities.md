# Desktop Client Capabilities — local-channel parity baseline

This document is the **capability surface** of the Tauri desktop client, written as
the reference spec for the upcoming **native iOS and Android** ports. It focuses on
the **local channels** path (Gmail / Office 365 / IMAP synced into on-device
SQLite) — the part of the product that is fully client-side and therefore the part a
mobile app must re-implement or re-host rather than just call an API for.

> **Scope.** This is *not* the MX/domain path (that lands in PostgreSQL via the
> Rails API and is reachable from any client over HTTP — see the top-level
> [CLAUDE.md](../CLAUDE.md) and the memory note `feedback_sync_architecture`).
> Local channels never touch the API except to proxy OAuth refresh and to proxy
> remote images. Everything else — sync, threading, storage, write-back, body
> rendering, on-device AI — happens on the device.

For the deep mechanics behind each capability, follow the cross-references; this doc
deliberately stays at the "what must a client provide" altitude and tags each item
with a **reuse verdict** for the mobile ports:

- 🟢 **Reuse Rust** — already in the Rust engine; ports link the same code.
- 🟡 **Port logic** — today lives in JS/React; the *algorithm* is portable but must
  be re-homed (ideally into the shared Rust core so iOS + Android + desktop share one
  implementation).
- 🔵 **Re-implement native** — platform-presentation; must be rebuilt per platform
  against that platform's HIG.

---

## 1. The local-channel engine (🟢 reuse Rust)

All of this is `ui/desktop/src-tauri/src/sync/` and is **provider-agnostic**: the
engine never branches on provider type. See **[Channels.md](Channels.md)** for the
full architecture.

| Capability | What it does | Source |
|---|---|---|
| **`ProviderAdapter` trait** | One interface; `ImapAdapter`, `GmailAdapter`, `MicrosoftAdapter` behind it. Adding a provider = one adapter. | `sync/provider.rs`, `sync/adapters/*` |
| **Opaque cursor sync** | Folder sync position is a provider-defined `String` (IMAP UID / Gmail `historyId` / Graph `deltaLink`); engine just stores & replays. | `engine/` |
| **Initial + incremental sync** | Batched full sync with a ramping page size (25, 25, 50, 200) so newest paints first; delta sync since cursor. | `engine/` |
| **`SyncStore`** | Conversation threading, per-`(account, Message-ID)` dedup, orphan cleanup, cursor persistence, integrity invariants. Adapters never write message tables. | `store.rs` |
| **Optimistic write + write-back queue** | User action hits SQLite first (status/read only, never `updated_at`), then enqueues a provider write-back with exponential-backoff retry. | `engine/`, `actions.rs` |
| **Sync-vs-write-back guard** | A racing sync that pulls pre-mutation provider state is ignored while a pending write-back row exists — local intent wins until it settles. Memory: `project_sync_writeback_guard`. | `store.rs` |
| **One-sync-per-account slot** | `try_begin_sync` atomically claims; duplicate triggers coalesce. Adapter lock is held across I/O, map lock never is. | `engine/` |
| **`InteractiveProvider`** | On-demand `fetch_message` (body + inline `cid:` images), `download_attachment`, `get_message_source`, `send_message`, `perform_action`. | `interactive.rs` |
| **`CalendarAdapter`** | Google + Graph calendars on the same 60s poll tick. | `calendar.rs` |
| **Encrypted credentials** | AES-256-GCM tokens at rest, keyed by an OS-stored `.credential_key`. | `crypto.rs` |
| **OAuth refresh** | `TokenManager` refreshes on 401 via the Rails OAuth proxy. **See §6 — this is the one piece that must change for mobile.** | `oauth.rs` |
| **Cloud push** | Realtime Gmail Pub/Sub `users.watch` + Graph `/subscriptions` → content-free nudge over ActionCable; token never leaves device; 60s poll is the fallback. | `sync/push.rs`, [Cloud-Push.md](Cloud-Push.md) |
| **Bus election (HOST/CLIENT)** | One engine across desktop + CLI; both open the same `inbox2.db`. **Mobile is single-process — this collapses to "always HOST".** | `sync::ipc` |
| **Integrity harness** | `sync_check` drives the real engine against a throwaway DB and asserts 5 invariants. | `bin/sync_check.rs` |

**Data model** (`migrations/001_create_schema.sql`): `external_accounts`,
`external_account_credentials`, `external_folders`, `messages` / `conversations`,
`message_provider_state` (one row per folder/label a message appears in),
`writeback_actions`, `push_subscription_state`, `calendars` / `calendar_events` /
`calendar_attendees`. This schema is portable verbatim.

**Port implication.** The engine is already a self-contained Rust crate boundary in
all but name. The mobile work here is *packaging* (expose it to Swift/Kotlin) and
*OAuth* (§6), not re-writing sync.

---

## 2. Email body rendering — collapse & quoting (🟡 port logic)

Gmail-style independent `···` toggles for quoted replies and signatures. Today this
is JS (`ui/web/src/lib/quoteDetector.js`, `signatureDetector.js`, the `QuotedText`
React component). See **[Email-Body-Collapsing.md](Email-Body-Collapsing.md)**.

| Capability | Detail |
|---|---|
| **Quote detection** | Strategy 1: HTML-structural selectors (gmail_quote, `blockquote[type=cite]`, Outlook `divRplyFwdMsg`, …). Strategy 2: line-based patterns (`-----Original Message-----`, `On <date> … wrote:`) with FR/DE/NL/ES/PT/IT variants. |
| **Signature detection** | Run *after* quotes (skips `[data-quoted-block]`). Strategy 1: structural selectors. Strategy 2: `-- ` RFC 3676 delimiter with a ≤12-line guard. Strategy 3: contact-block heuristic (name/company/phone). |
| **Independent toggles** | A message can carry both a signature toggle and a quote toggle; each expands independently; expanded signatures de-emphasized. |

**Resolution (done).** Rather than a Rust port, this logic was extracted into a
standalone framework-free JS package, **`@inbox2/email-body`** (`packages/email-body`):
`detectQuotes`, `detectSignatures`, `blockRemoteContent`, and a pure
`shouldProxyImages`. Both the desktop iframe and the iOS/Android WKWebViews render in a
real DOM, so the **same JS runs on every platform** — written once, identical behavior,
and no second implementation to keep in sync (a Rust port would have left the browser
web app's JS copy in place anyway). The web app consumes it via a Vite alias; the
mobile WebViews bundle the esbuild single-file build. See
[Mobile-iOS-Plan.md](Mobile-iOS-Plan.md) Phase 2.

---

## 3. Remote-image privacy (🟡 port logic + 🔵 native render)

Email remote images are **blocked by default** and, when loaded, fetched through the
**Rails image proxy** so the sender never sees the reader's IP. Hook:
`ui/web/src/hooks/useRemoteImages.js`; memory: `project_remote_image_privacy`.

| Rule | Behavior |
|---|---|
| **Block on render** | `blockRemoteContent` neutralizes `src`/`srcset`/`bg` into `data-blocked-*` before display. |
| **Proxy-only auto-load** | With a token, images **always** load via the proxy (`api.fetchProxiedImage` → blob URL). The sender's server is hit by Rails, not the device. |
| **Direct load is the exception** | A direct fetch (which leaks IP) is allowed **only** on an explicit per-message "Show images" tap **with no token available** — never automatically. |
| **Strict CSP** | The body renders under `img-src data: blob:` so a missed vector still can't phone home. |
| **Late-reveal handling** | A `MutationObserver` re-scans when a quote/signature expands; blob URLs revoked on cleanup. |
| **Per-sender / always trust** | "Show once" (per message), "Always from this sender" (safe-sender list), "Always show all". |

**Port implication.** The *policy* (block-by-default, proxy-only auto-load, explicit-
direct-only, trust lists) is portable logic that belongs in the shared core. The
*enforcement* (CSP, blob swap-in, mutation re-scan) is presentation and must be
re-done in each platform's HTML renderer. The Rails image proxy itself is reused
as-is (it piggybacks the cloud-push token).

---

## 4. On-device AI (🟢 reuse Rust for native models / 🔵 re-do Apple-FM bridge)

All inference is on-device; no email content leaves the machine. See
**[Client-AI.md](Client-AI.md)**.

| Tier | Capability | Desktop backend | Mobile note |
|---|---|---|---|
| **A — classify** | Sentiment, intent (zero-shot NLI), embeddings | Apple Intelligence (when present) else native ONNX (`ort` crate) in Rust | iOS: Apple Foundation Models exist on-device (iOS 18+/26) — re-do the Swift bridge against the iOS framework. ONNX-in-Rust path reuses directly. Embeddings always need the native path. |
| **B — generate** | Thread summary, smart replies | Apple FM, else llama.cpp sidecar (GGUF) | iOS: Apple FM bridge re-done in Swift. A llama.cpp sidecar is impractical on iOS — fall back to "no generative" or Apple FM only. |

**Port implication.** The native ONNX engine (`ai/inference.rs`) is reusable Rust.
The Apple Foundation Models bridge is a macOS Swift CLI today; on iOS it becomes an
in-process Swift call (no subprocess) — a re-implementation, but a small one, and the
model lives in the OS. Embeddings (for vector search) reuse the Rust path.

---

## 5. Notifications & cloud push (🟢 core / 🔵 native surface)

The **trigger** is reusable; the **surface** is platform-native. See
**[Notifications.md](Notifications.md)** and **[Cloud-Push.md](Cloud-Push.md)**.

| Piece | Desktop | Mobile |
|---|---|---|
| **New-message detection** | Engine emits `new-message` on poll/push | 🟢 same engine event |
| **Cloud-push nudge** | Provider webhook → Rails → ActionCable `PushSyncChannel` → resync | 🟢 reuse — but iOS background execution is constrained (see plan); APNs may need to carry the nudge |
| **Delivery surface** | Custom frosted-glass window / in-app popup / OS Notification API | 🔵 iOS: `UNUserNotificationCenter` (banners) + in-app toast; no custom always-on-top window |

**Port implication.** This is where the desktop "custom notification window" feel does
**not** translate — mobile must use the OS notification center to feel native. The
*content-free nudge* model is a strong fit for APNs (the push carries "mailbox
changed", the app syncs with its own on-device token — token still never leaves the
device).

---

## 6. The one thing that must change: OAuth (⚠️ blocking design item)

Today `TokenManager` refreshes via the **Rails OAuth proxy** because the desktop app
reuses the web app's **confidential** OAuth client (whose `client_secret` can't ship
in a distributed binary). [Channels.md §OAuth](Channels.md#oauth--token-refresh)
already flags the fix:

> A native app should use a **public OAuth client + PKCE** (Google "iOS/Desktop app",
> Azure "Mobile & desktop"), refreshing **directly against the provider** — no secret,
> no proxy. Microsoft **rotates refresh tokens** on every refresh, so a direct-refresh
> impl must persist the new `refresh_token` (today `TokenManager` keeps the same one —
> correct for Google, needs a tweak for Microsoft). The loopback redirect is already
> wired in `commands.rs::start_*_oauth`.

For mobile this becomes **ASWebAuthenticationSession** (iOS) / **Custom Tabs**
(Android) with a per-platform public client ID and an app-scheme/universal-link
redirect. This is net-new and is the first real engineering decision of the port —
it unblocks everything else.

---

## 7. Capabilities we can simplify on mobile

Per the product direction, the unified inbox does **not** need full desktop fidelity
on a phone:

- **Drop the grid / Eisenhower-quadrant view** — list-first on mobile.
- **Simplify the unified pool** — a single chronological/triaged list per account or a
  light unified list, not the desktop's multi-pane grid.
- **No multi-window / no Sync Console** — the desktop bus election (HOST/CLIENT) and the
  external notification window have no mobile equivalent; collapse to single-process.
- **Calendar** — likely a read-mostly first cut.

What must **not** be simplified (these are the product's identity): collapse/quoting,
remote-image privacy, on-device AI, and the local-channel sync guarantees (no dupes,
no lost mail, optimistic actions that survive a racing sync).

---

## 8. Reuse scorecard (what a mobile app inherits vs rebuilds)

| Layer | Verdict | Effort |
|---|---|---|
| Sync engine, store, adapters, write-back, cursors | 🟢 reuse Rust | packaging only |
| Calendar sync | 🟢 reuse Rust | packaging only |
| Native ONNX classification + embeddings | 🟢 reuse Rust | packaging only |
| Cloud-push subscription lifecycle | 🟢 reuse Rust | + APNs glue |
| SQLite schema | 🟢 reuse | verbatim |
| Quote / signature detection | ✅ shared JS pkg `@inbox2/email-body` | done |
| Remote-image privacy policy | ✅ shared JS pkg (`shouldProxyImages`) | done |
| OAuth (proxy → PKCE direct) | ⚠️ net-new | small but blocking |
| Apple Foundation Models bridge | 🔵 re-implement (Swift, in-process) | small |
| Body HTML rendering surface | 🔵 native | medium |
| All UI / navigation / chrome | 🔵 native per HIG | the bulk of the work |

The headline: **the hard, correctness-critical half of the app (sync, storage,
privacy/AI logic) is reusable Rust.** The mobile work is a native presentation layer
plus an OAuth swap — not a rewrite of the engine.

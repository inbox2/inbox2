# Native Mobile Plan — iOS first

Goal: ship **separate native apps** for iOS and Android with **feature parity** to the
desktop client on the things that define the product (local-channel sync, collapse/
quoting, remote-image privacy, on-device AI), while feeling **native to each platform's
HIG** and **simplifying** the parts that don't translate to a phone (the unified grid /
Eisenhower view, multi-window, the custom notification window).

The parity baseline is **[Desktop-Capabilities.md](Desktop-Capabilities.md)** — read it
first; this plan executes against its reuse scorecard.

## Resolved architecture decisions

| Decision | Choice | Consequence |
|---|---|---|
| **Engine packaging** | **UniFFI shared core** — extract `sync/store/adapters` into a standalone `inbox2-core` Rust crate, generate Swift + Kotlin bindings. | One engine, two native UIs. The same crate ships an `.xcframework` for iOS and a `.so`+`jniLibs` for Android. |
| **Body logic (quote/sig/privacy)** | **Shared framework-free JS package** (`@inbox2/email-body`), bundled into the WebView. (Superseded the earlier "lift into Rust `core::body`" idea: both desktop and iOS render in a WebView with a real DOM, and the browser web app can never drop its JS copy — so a Rust port would mean maintaining two implementations.) | One implementation, run identically in the desktop iframe and the iOS/Android WKWebViews. **Done** — see Phase 2. |
| **Body rendering surface** | **WKWebView + strict CSP** (`img-src data: blob:`), reusing the desktop blocked-image swap-in model. | Real HTML email renders correctly; the privacy story ports directly. SwiftUI drives the toggles over a JS bridge. |
| **OAuth** | **Public client + PKCE, direct-to-provider** via `ASWebAuthenticationSession`. No Rails proxy. | Net-new (the one true blocking item). Microsoft refresh-token rotation must be persisted. |
| **UI** | **SwiftUI**, iOS 17+ target (Apple FM features gate to iOS 18/26 at runtime). | Native navigation, list-first, no grid. |

---

## Phase 0 — Extract `inbox2-core` (shared, benefits Android too) — ✅ LANDED

The engine is now a standalone `inbox2-core` crate (Cargo workspace at `ui/desktop`,
members `core` + `src-tauri`). What shipped:

1. **Crate carved.** `core/src/sync/` holds the engine, store, model, provider,
   adapters, interactive, actions, outbox, calendar, crypto, oauth, push, mime,
   deletion, threading, util, error, and the canonical schema
   (`inbox2_core::SCHEMA_SQL`). Desktop's `sync/mod.rs` re-exports them so existing
   `crate::sync::*` paths are unchanged.
2. **De-Tauri'd via the existing `EventSink` trait.** The trait + `NullSink`/
   `CompositeSink` live in core; `TauriSink` moved to the desktop crate. The bus
   election (HOST/CLIENT) and IPC stay desktop-only — **mobile is single-process,
   always HOST.**
3. **Rule engine in core.** The portable half of the agentic-filters funnel
   (`core::rules::{conditions, gate, actions}`) moved in too, behind an injected
   `OnDeviceAi` trait (desktop wraps its ONNX engine; mobile injects its own / `None`).
   The CLI-agent harness (`run_agent`) stays desktop-only; built-in actions run on
   mobile. The engine pings `rules_scan_notify()` after a sync brings in new mail so a
   (push-driven) resync applies rules immediately — the link the mobile runner mirrors.

**UniFFI surface — ✅ landed (host-verified):** `core::ffi` (behind the `mobile-ffi`
feature, so desktop never pulls UniFFI) exposes an `InboxEngine` facade —
`new(dataDir, listener)`, `start_sync`, `perform_action`, `list_accounts_json`,
`shutdown` — over an owned tokio runtime, with engine events flowing back through an
`EngineEventListener` callback (the same `(event, payload_json)` pairs the webview/IPC
consume). `cargo build --features mobile-ffi` builds the cdylib and the in-crate
`uniffi-bindgen` generates a valid Swift `InboxEngine` binding. Expand the facade
(fetch_message, scan_and_apply_rules, register_push, calendar) as the iOS screens need
them.

**Still to do for iOS (deferred to iOS kickoff):**
- **Build the xcframework.** `core/build-ios-xcframework.sh` is ready, but needs a
  **rustup** toolchain with the iOS targets (`rustup target add aarch64-apple-ios
  aarch64-apple-ios-sim`) — the dev box's Homebrew rust only has the macOS target, so
  this is the first setup step on a machine that will build for device/sim.
- **SQLite story.** On iOS the engine owns its own connection to the app-group
  container DB (no `tauri-plugin-sql`); expose a read handle for native list/detail
  queries (mirrors how the web UI reads SQLite directly today).

**Done:** core 176 + desktop 79 Rust tests pass; full workspace (app +
`engine_daemon` + `sync_check`) builds — a zero-behavior refactor.

---

## Phase 1 — OAuth (PKCE) — the unblocker

Per [Desktop-Capabilities.md §6](Desktop-Capabilities.md). Net-new and gates real
accounts.

1. Register **public OAuth clients**: Google "iOS app", Azure "Mobile & desktop". App-
   scheme / universal-link redirect (`com.inbox2.ios://oauth`).
2. iOS auth flow via **`ASWebAuthenticationSession`** → authorization code + PKCE
   verifier → token exchange **directly against the provider** (no Rails).
3. In `core`: add a **direct-refresh** path to `TokenManager` alongside the existing
   proxy path (feature-flagged by client type). **Persist the rotated `refresh_token`
   for Microsoft** (Google keeps the same one).
4. Tokens land in the existing AES-256-GCM encrypted store; the credential key lives in
   the **iOS Keychain** (replacing the desktop `.credential_key` file).

**Exit criteria:** connect a real Gmail + a real Office365 account on-device, tokens
refresh through a 401 with no server involvement.

---

## Phase 2 — `@inbox2/email-body`: shared JS body processing — ✅ LANDED

Quote/signature collapsing and the remote-image privacy policy now live in a
standalone, framework-free package (`packages/email-body`) instead of a Rust
`core::body`. Both the desktop iframe and the iOS/Android WebViews render in a real
DOM, so the same JS runs everywhere — no Rust port, no double-maintenance, no
HTML-serialization parity headaches. What shipped:

1. **The package** — `detectQuotes`, `detectSignatures`, `blockRemoteContent`
   ([Email-Body-Collapsing.md](Email-Body-Collapsing.md)) moved verbatim, plus a pure
   `shouldProxyImages` extracted from `useRemoteImages` (block-by-default,
   proxy-only-auto-load, explicit-direct-only; memory `project_remote_image_privacy`),
   an `index` barrel, and a `processBody` chain. No React / app deps — only the DOM.
2. **Consumption** — `ui/web` imports `@inbox2/email-body` via a Vite alias
   (EmailFrame, QuotedText, PreviewPane, useRemoteImages); the old `lib/*.js`
   detectors are deleted (single source of truth). The trust lists (safe-sender,
   always-show, shown-once) stay host-side and feed the pure policy.
3. **Parity tests** — the previously-missing detector/policy tests now exist in the
   package (jsdom), run under the web app's vitest, and double as the iOS conformance
   suite. An esbuild `build` emits a single-file IIFE (`dist/email-body.js`, global
   `Inbox2EmailBody`) for the mobile WebViews to inject.

**iOS work (deferred):** bundle `dist/email-body.js` into the WKWebView and drive the
same `···` collapse toggles + image-proxy banner from SwiftUI (Phase 3).

**Done:** web unit suite 108 passing (96 + 12 new), lint clean.

**Exit criteria:** Rust detector tests pass on the desktop fixtures; output spans match
the current JS output on a sample corpus.

---

## Phase 3 — Reading experience (the product's identity on a phone)

> **First milestone — ✅ landed (runs in the simulator).** The SwiftUI app lives in
> `ui/ios` (`./bootstrap.sh` → `./build.sh`). It links the `InboxCore.xcframework` +
> UniFFI binding and constructs `InboxEngine` on-device (home screen shows the core
> *running* + the accounts list), and its `WKWebView` reader runs the shared
> `@inbox2/email-body` package — quote/signature `···` collapsing and remote-image
> blocking under the strict CSP, verified on an iPhone 16 sim (`quote: true ·
> signature: true · remote images blocked: 1`). Remaining below: real
> conversation/thread data, swipe actions, compose.

1. **Conversation list** — SwiftUI `List`, native swipe actions (archive/trash/
   mark-read) wired to `perform_action` (optimistic: update the in-memory list, the
   engine owns SQLite — same contract as desktop's `useConversationActions`). Pull-to-
   refresh → `start_sync`.
2. **Thread view** — message cards; body in a **`WKWebView`** with the strict CSP
   (`img-src data: blob:`). The bundled **`@inbox2/email-body`** (Phase 2) marks the
   quote/signature blocks that drive the `···` collapse toggles (SwiftUI chrome around
   the webview, or a small JS bridge inside it). Lazy bodies
   hydrate via `fetch_message` on open (Gmail/MS/IMAP bodies are header-only until
   opened — [Channels.md](Channels.md) "bodies are lazy").
3. **Remote images** — enforce `image_policy`: blocked placeholder + a "Show images"
   affordance; proxy load via the existing Rails image proxy → blob swap-in inside the
   webview. Trust-list taps ("always this sender") persist to the store.
4. **Compose / reply / send** — `send_message` over the `InteractiveProvider`
   (Gmail/MS APIs; IMAP→SMTP via `lettre`). Native compose sheet.

**Exit criteria:** a real thread renders with correct quote/signature collapsing,
images blocked-then-proxied, and a reply sends.

---

## Phase 4 — Sync surfacing, notifications, push

1. **Sync state** — subscribe to the `EngineEvents` sink; a lightweight native
   "Syncing…" indicator (no Sync Console — that's desktop-only).
2. **Local notifications** — `UNUserNotificationCenter` banners on the `new-message`
   event when foregrounded/backgrounded; in-app toast. **No custom always-on-top
   window** (doesn't exist on iOS).
3. **Cloud push + APNs** — reuse the content-free nudge model
   ([Cloud-Push.md](Cloud-Push.md)). iOS background execution is constrained, so the
   provider→Rails→client path likely terminates in an **APNs silent/alert push** that
   wakes the app to run a normal sync with its **on-device token** (token still never
   leaves the device). Rails gains an APNs sender alongside ActionCable; the
   subscription-lifecycle Rust (`sync/push.rs`) is reused.
4. **Background refresh** — `BGAppRefreshTask` as the 60s-poll equivalent (iOS won't
   allow a literal 60s loop); push is primary, periodic refresh is the floor.

**Exit criteria:** a sent test email surfaces as an APNs-driven notification before a
manual refresh would have fired.

---

## Phase 5 — On-device AI (native bridge)

Per [Client-AI.md](Client-AI.md).

1. **Tier A (classify/embed)** — reuse the **native ONNX engine in Rust**
   (`ai/inference.rs`) through the core; embeddings always use it. Sentiment/intent
   prefer Apple FM when present.
2. **Apple Foundation Models** — re-implement the macOS Swift CLI bridge as an
   **in-process Swift call** to the iOS Foundation Models framework (no subprocess).
   Gate at runtime (iOS 18/26 + Apple Intelligence enabled).
3. **Tier B (generative)** — Apple FM for summary/smart-replies where available; the
   **llama.cpp GGUF sidecar is impractical on iOS**, so degrade to "no generative" when
   Apple FM is absent (the app is fully functional without AI — existing guarantee).

**Exit criteria:** AI summary + smart replies work on an Apple-Intelligence device;
classification + vector search work everywhere via the ONNX path.

---

## Explicitly simplified vs desktop

- **No unified grid / no Eisenhower-quadrant view** — list-first.
- **Unified inbox simplified** — a light unified or per-account chronological/triaged
  list, not the multi-pane desktop grid.
- **No multi-window, no bus election, no Sync Console, no custom notification window.**
- **Calendar** — read-mostly first cut.

## Risk register

| Risk | Mitigation |
|---|---|
| Phase 0 refactor regresses sync | `sync_check` integrity harness gates every step; zero-behavior-change refactor. |
| iOS background limits throttle sync | Push-primary (APNs) + `BGAppRefreshTask` floor; never rely on a foreground poll loop. |
| MS refresh-token rotation lost → re-auth loops | Persist rotated `refresh_token` on every refresh (Phase 1, explicit). |
| WKWebView ↔ SwiftUI toggle bridge complexity | Keep collapse state in SwiftUI; webview only renders span-marked HTML + reports height. |
| UniFFI async ergonomics | Back UniFFI async with the engine's existing tokio runtime; keep the exported surface coarse (few high-level calls, not chatty). |
| llama.cpp on iOS | Don't ship it; Apple FM or no-generative. |

## Sequencing summary

```
Phase 0  Extract inbox2-core (engine + rules)    ── ✅ landed (UniFFI surface = iOS kickoff)
Phase 1  OAuth PKCE (ASWebAuthenticationSession) ── unblocks real accounts
Phase 2  @inbox2/email-body (shared JS package)  ── ✅ landed, parity guard
Phase 3  Reading experience (List + WKWebView)   ── 🟡 app runs in sim; data/actions next
Phase 4  Notifications + APNs cloud push
Phase 5  On-device AI (Apple FM bridge + ONNX)
         └─ Android follows, reusing Phases 0/1/2 wholesale
```

The desktop-validated shared foundation (Phase 0 crate extraction + rule engine, and
the Phase 2 body package) is **done and green on desktop**. What remains for iOS is
net-new mobile work — the UniFFI surface, OAuth PKCE, and the SwiftUI UI. Android
reuses Phases 0, 1 (Custom Tabs instead of
ASWebAuthenticationSession), and 2 without change — which is the whole point of the
shared-core decision.

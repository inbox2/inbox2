# Inbox2 — iOS app

A native SwiftUI shell over the **shared Rust core** (`inbox2-core` via UniFFI) and
the **shared `@inbox2/email-body` JS** (rendered in a `WKWebView`). This is the iOS
port tracked in [docs/Mobile-iOS-Plan.md](../../docs/Mobile-iOS-Plan.md); this first
milestone proves both shared halves run on-device.

## What works today

- **Rust core runs on iOS** — `InboxEngine` (the UniFFI facade over the sync engine)
  opens the local SQLite store, starts its poll + write-back loops, and surfaces
  account/event state to SwiftUI. Home screen shows it live.
- **Shared email-body rendering** — the reader screen runs the exact same
  `@inbox2/email-body` package the desktop uses inside a `WKWebView`: quote/signature
  `···` collapsing and remote-image blocking (strict `img-src data: blob:` CSP).

## Build & run

Prereq — a `rustup` toolchain with the iOS targets (Homebrew rust only has the host
target):

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

Then:

```sh
./bootstrap.sh        # build core xcframework + binding + JS bundle + xcodeproj
./build.sh            # build, install, launch (home screen)
./build.sh reader     # launch straight into the WebView reader
```

Everything generated (`Inbox2.xcodeproj/`, `Sources/Generated/`,
`Resources/email-body.js`, `build/`) is reproduced by `bootstrap.sh` and gitignored;
only the hand-written `Sources/` + `project.yml` + scripts are committed.

## Layout

```
project.yml              XcodeGen spec (links ../desktop/target/InboxCore.xcframework)
Sources/
  Inbox2App.swift        @main app
  EngineModel.swift      owns InboxEngine, bridges the event callback
  Views/RootView.swift   core status + accounts + nav to the reader
  Views/ReaderView.swift WKWebView that runs @inbox2/email-body
  Generated/             UniFFI Swift binding (generated)
Resources/email-body.js  esbuild bundle of @inbox2/email-body (generated)
bootstrap.sh / build.sh
```

## Next

OAuth (PKCE via `ASWebAuthenticationSession`), a SQLite read layer for the
conversation list/thread (the engine is write/sync; the UI reads SQLite directly, as
on desktop), expanding the `InboxEngine` facade (`fetch_message`, `scan_and_apply_rules`,
`register_push`), and APNs. See the plan doc.

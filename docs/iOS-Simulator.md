# iOS Simulator — build, run, and drive the app

How to build, launch, screenshot, and UI-test the Inbox2 iOS app
(`ui/ios`, scheme `Inbox2`) on the iOS Simulator — both by hand and via the MCP
tooling Claude uses to drive the simulator autonomously.

> The app is a native SwiftUI shell over the shared Rust core (`inbox2-core` via
> UniFFI) and the shared `@inbox2/email-body` JS. See [Mobile-iOS-Plan.md](Mobile-iOS-Plan.md)
> and [ui/ios/README.md](../ui/ios/README.md).

---

## 1. One-time machine setup

### Rust → iOS toolchain
The core cross-compiles to iOS, which needs **rustup** with the iOS targets
(Homebrew rust only ships the host target):

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

### Simulator-driving toolchain (idb)
The UI-automation MCP server talks to the simulator through Facebook's `idb`:

```sh
brew install pipx python@3.11 facebook/fb/idb-companion
pipx ensurepath
# fb-idb breaks on Python 3.14 (asyncio "no current event loop") — pin 3.11:
pipx install fb-idb --python "$(brew --prefix python@3.11)/bin/python3.11"
idb list-targets        # verify
```

### MCP servers (user scope, for Claude Code)
```sh
claude mcp add XcodeBuildMCP -s user -e XCODEBUILDMCP_SENTRY_DISABLED=true -- npx -y xcodebuildmcp@latest mcp
claude mcp add ios-simulator -s user -- npx -y ios-simulator-mcp
claude mcp list         # both should say "Connected"
```
`XcodeBuildMCP` = build/test/run/screenshot; `ios-simulator` = tap/swipe/type +
accessibility tree. (MCP tools only appear after a Claude Code **restart**.)

> Apple's native `xcode` MCP (`xcrun mcpbridge`, Xcode 26.3+) is optional and was
> dropped here — it failed the health check and the two servers above cover the loop.

---

## 2. Build & run (command line)

```sh
cd ui/ios
./bootstrap.sh        # core xcframework + UniFFI binding + email-body bundle + xcodeproj
./build.sh            # build → install → launch (home screen)
./build.sh reader     # launch straight into the WebView reader
```

`bootstrap.sh` must run after a fresh checkout and whenever the FFI surface or the
`@inbox2/email-body` package changes (it regenerates everything gitignored). Plain
`xcodebuild` also works:

```sh
xcodebuild -project Inbox2.xcodeproj -scheme Inbox2 -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

### ⚠️ Apple-Silicon arch gotcha
The Rust core only builds an **arm64** simulator slice, so the simulator build must
exclude x86_64. This is baked into `project.yml`
(`EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`), so XcodeBuildMCP and plain
`xcodebuild` both build cleanly. If you ever see `ld: ... required architecture
x86_64`, that setting was lost — regenerate with `xcodegen`.

---

## 3. Driving the simulator (what Claude does)

The loop for any iOS change — **build → launch → screenshot → inspect → interact →
re-screenshot**:

1. **Session defaults (once per session):** `session_show_defaults`, then
   `session_set_defaults` with project `ui/ios/Inbox2.xcodeproj`, scheme `Inbox2`,
   a simulator (e.g. iPhone 16), bundle id `com.inbox2.ios`.
2. **Build + run:** `build_run_sim` (reads structured errors — fix Swift and rebuild
   until clean, don't read raw logs).
3. **Screenshot:** `XcodeBuildMCP.screenshot` (or `ios-simulator.screenshot`).
4. **Accessibility tree:** `ios-simulator.ui_describe_all` → locate elements by
   `AXLabel` / frame. Prefer this over guessing coordinates.
5. **Interact:** `ui_tap` / `ui_type` / `ui_swipe` (find the element first via
   `ui_describe_all` or `ui_find_element`, tap its frame center).
6. **Re-screenshot** to confirm the change.

Useful tools: `list_sims`, `boot_sim`, `install_app_sim`, `launch_app_sim`,
`stop_app_sim`, `test_sim` (XCTest with per-test results), `record_sim_video`.

### Manual equivalents (`simctl` + `idb`)
```sh
UDID=$(xcrun simctl list devices available | grep -m1 'iPhone 16 (' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID"; open -a Simulator
xcrun simctl install "$UDID" ui/ios/build/Build/Products/Debug-iphonesimulator/Inbox2.app
xcrun simctl launch "$UDID" com.inbox2.ios
xcrun simctl io "$UDID" screenshot /tmp/shot.png
idb ui describe-all --udid "$UDID"          # accessibility tree
idb ui tap --udid "$UDID" 196 499           # tap x y
# Pass a launch env (e.g. open the reader): SIMCTL_CHILD_INBOX2_SCREEN=reader xcrun simctl launch ...
```

### Logs
`build_run_sim` captures build + runtime + os_log paths in its result. Manually:
`xcrun simctl spawn "$UDID" log stream --predicate 'process == "Inbox2"'`.

---

## 4. Conventions

- **Interact by accessibility identifier/label**, not raw coordinates, wherever
  possible — set `.accessibilityIdentifier(...)` on SwiftUI views that tests drive.
- **Before/after screenshots** for any UI change.
- **Tests:** use `test_sim` and report per-test results.
- The Rust core runs a real tokio runtime + SQLite in the app sandbox
  (`Documents/inbox2/inbox2.db`); `erase` the simulator or delete the app to reset
  local state.

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| `ld: required architecture x86_64` | `EXCLUDED_ARCHS` lost — `cd ui/ios && xcodegen generate`. |
| `import inbox2_coreFFI` not found | xcframework missing — `./bootstrap.sh` (needs rustup iOS targets). |
| `idb list-targets` empty / hangs | `idb-companion` not running or wrong Python — reinstall fb-idb under python3.11. |
| ios-simulator MCP can't find idb | ensure `~/.local/bin` (pipx) is on the MCP server's PATH. |
| MCP tools absent after `claude mcp add` | restart Claude Code (tools register only on a fresh session). |

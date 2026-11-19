# inbox2 Android MCP

The Android analog of XcodeBuildMCP / the `ios-simulator` MCP: build the shared Rust
core + the Compose app, drive the emulator, and automate/inspect the UI from an MCP
client. It's a thin wrapper over [`bin/android`](../../../bin/android), so anything the
script does is available as a tool.

## Setup

```sh
cd ui/android/tools/android-mcp
npm install
```

Register it (project `.mcp.json` at the repo root already does this):

```json
{ "mcpServers": { "inbox2-android": {
    "command": "node",
    "args": ["ui/android/tools/android-mcp/server.js"] } } }
```

## Tools

| Tool | What it does |
|------|--------------|
| `android_core` | Rebuild `inbox2-core` for Android (cargo-ndk `.so` + UniFFI Kotlin). Run after Rust changes. |
| `android_build` | Build the Compose APK (`debug`/`release`). |
| `android_boot` | Boot the emulator (default AVD) and wait. |
| `android_install` / `android_launch` / `android_stop` | Install / launch / force-stop. |
| `android_run` | boot + build + install + launch. |
| `android_seed` | Seed the desktop `inbox2.db` + credential key (real mail, no OAuth). |
| `android_screenshot` | Capture the screen, returned as an image. |
| `android_ui` | Dump the uiautomator view hierarchy. |
| `android_tap` / `android_swipe` / `android_text` / `android_key` | UI automation. |
| `android_logcat` | Capture core + app logs. |
| `android_devices` | List devices/emulators. |

## Requirements

Android SDK + an NDK under `~/Library/Android/sdk`, a JDK 17 (`bin/android` finds the
Homebrew one), cargo-ndk + the Android Rust targets, and an AVD (e.g. `Pixel_7_API_35`).
See [docs/Android-App.md](../../../../docs/Android-App.md).

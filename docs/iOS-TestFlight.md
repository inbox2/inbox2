# iOS TestFlight

How the iPhone and iPad app (`com.inbox2.ios`) reaches TestFlight. A release is one local command, `bin/ios-release --upload`. There is no CI job.

## What the command does

1. Regenerates the Xcode project from `ui/ios/project.yml`.
2. With `--xcframework`, rebuilds the Rust core and syncs the UniFFI binding.
3. Archives the Release configuration for a generic iOS device.
4. Exports a signed App Store `.ipa` to `ui/ios/build/release/export/` using `ui/ios/ExportOptions.plist`.
5. With `--upload`, validates the `.ipa` and uploads it to App Store Connect.

```sh
bin/ios-release --upload                # Swift-only change
bin/ios-release --upload --xcframework  # anything under ui/desktop/core changed
```

Use `--xcframework` on a fresh checkout too: the framework lives under `ui/desktop/target/`, which is not committed. Do not run it while `tauri dev` is watching, because both use the Cargo lock.

## Authentication

Signing and upload use one App Store Connect API key, the same one `bin/release-desktop` uses. Xcode does not need a signed-in account.

| Setting | Value |
|---|---|
| Key id (`ASC_KEY_ID`) | `H9PLG58DB9` |
| Issuer (`ASC_ISSUER_ID`) | `d5f5385b-5e34-4d70-925d-0debd3a3e090` |
| Private key | `~/.appstoreconnect/private_keys/AuthKey_H9PLG58DB9.p8`, local only |
| Team | `KF53B4S5HD` |
| Signing certificate | "Apple Distribution: Waseem Sadiq" in the login keychain |

Xcode creates the App Store provisioning profiles for the app, ShareExtension and Widgets on demand.

## One-time setup

1. **Create the app record.** App Store Connect › Apps › + › New App: platform iOS, bundle ID `com.inbox2.ios`, any unique SKU such as `inbox2-ios`. The API key cannot do this. The bundle IDs are already registered.
2. **The internal testing group** is `Team` on the app's TestFlight tab, with access to all builds. Internal testers must be App Store Connect users with access to this app, and their builds need no Beta App Review.
3. **Install TestFlight** on each device and sign in with that tester's Apple ID.

## Each release

1. Run the command. The build number is assigned at export (`manageAppVersionAndBuildNumber`), so there is nothing to bump. `CFBundleShortVersionString` is `1.0`.
2. Wait for processing in App Store Connect, usually 5–30 minutes.
3. Testers in a group with access to all builds get it automatically. Install from the TestFlight app.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `project.yml`, so builds skip Apple's prompt. Waseem declared the app exempt on 2026-11-08. The app uses HTTPS and also its own end-to-end encryption for sealed mail (AES-GCM, `crypto_box`, ChaCha20-Poly1305 in `ui/desktop/core/src/sync/seal.rs`). Review this declaration before an external TestFlight or App Store release.

## How TestFlight differs from a device build

| | `bin/ios-deploy-device` | TestFlight |
|---|---|---|
| Signing | Development | App Store distribution |
| `aps-environment` | `development` | `production`, switched at export |
| API push environment | `sandbox` (`#if DEBUG`) | `production` |
| Rust core | Whatever is in `target/` | Release build |
| Needs the device connected | Yes | No |
| Expires | With the profile | 90 days after upload |

The app re-registers its push token when the environment changes, so moving between the two is safe. Both use the same bundle ID, so each install replaces the other and the app's data stays. Use `bin/ios-deploy-device --seed` only on development installs.

## Reading kills and crashes

TestFlight crash reports appear in App Store Connect under TestFlight › Crashes and in Xcode's Organizer. Jetsam reports stay on the device until shared or pulled: Settings › Privacy & Security › Analytics & Improvements › Analytics Data, files named `JetsamEvent-*` and `Inbox2-*`, or `idevicecrashreport` over a connection.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Export fails, no app or "no accounts" | The app record is missing, or the API key is not being passed. Create the record, then check `P8` exists. |
| Upload rejected for a duplicate build number | The record is unreachable at export. Check the key's App Store Connect role. |
| Build stuck on Missing Compliance | The build predates the `project.yml` key. Answer the encryption question on it. |
| Validation rejects a framework (`MinimumOSVersion`, `CFBundleVersion`) | MediaPipe ships incomplete `Info.plist` files. `bin/ios-release` fills them on the archive before export; extend that loop if a new key is reported. |
| "No orientations were specified" | iPad multitasking needs all four in `UISupportedInterfaceOrientations~ipad` (`project.yml`). |
| `API key not found` | Copy the `.p8` to `~/.appstoreconnect/private_keys/`. |
| Cargo looks hung with `--xcframework` | `tauri dev` holds the Cargo lock. Stop the watcher first. |

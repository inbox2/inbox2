# iOS Device — build, install, and seed on a physical iPhone

How to build, sign, install, and run the Inbox2 iOS app (`ui/ios`, scheme
`Inbox2`) on a **physical iPhone**, and how to seed its SQLite store from the
desktop so you don't have to re-authenticate every channel.

> Companion: [iOS-Simulator.md](iOS-Simulator.md) (the simulator flow + UI
> automation), [iOS-App.md](iOS-App.md) (architecture). The read/write split,
> data dir, and credential-key mechanism are identical to the simulator — only
> the install + file-copy transport differs (`devicectl` instead of `simctl`).

---

## 1. One-time setup

- **Rust → iOS targets** (same as the simulator): `rustup target add
  aarch64-apple-ios aarch64-apple-ios-sim`.
- **Signing is already configured** in `ui/ios/project.yml`:
  `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: KF53B4S5HD`, so device
  builds sign without per-build flags or hand-configuring Xcode. Pass
  `-allowProvisioningUpdates` so the CLI can mint/refresh the provisioning
  profile.
- **Pair + trust** the iPhone once (plug in / Wi-Fi; tap *Trust* on the device).
  Confirm it's visible:

  ```sh
  xcrun devicectl list devices          # note the coredevice identifier (UUID)
  ```

  The bundle id is `com.inbox2.ios`. Two identifiers matter and are **not**
  the same value:
  - the **coredevice identifier** (a UUID like `815166A7-…`) — used by every
    `xcrun devicectl …` call below (`--device`).
  - the **hardware UDID** (`00008140-…`) — used only by `log stream --device`.
    Get it with `xcrun devicectl device info details --device <UUID>`.

---

## 2. The xcframework

The app links `../desktop/target/InboxCore.xcframework` (by the relative path in
`project.yml`). It must contain the **`ios-arm64` device slice** (the simulator
slice alone won't link a device build). Rebuild it whenever the Rust core
(`ui/desktop/core`) changed since the last build:

```sh
cd ui/desktop/core
./build-ios-xcframework.sh            # builds device + sim slices, regenerates bindings
ls ../target/InboxCore.xcframework    # expect: ios-arm64  ios-arm64-simulator
```

Skip it if `git diff --stat -- ui/desktop/core` is clean **and** the existing
xcframework already has an `ios-arm64` directory newer than your last source
change. If you added/removed Swift files, re-run `xcodegen generate` in
`ui/ios` first.

---

## 3. Build, sign, install, launch

```sh
DEV=<coredevice-UUID>                  # from `xcrun devicectl list devices`
cd ui/ios

# Build + sign for the device (Debug). Output lands in build/device/… (gitignored).
xcodebuild -project Inbox2.xcodeproj -scheme Inbox2 -configuration Debug \
  -destination "id=$DEV" -derivedDataPath build/device \
  -allowProvisioningUpdates build

APP=build/device/Build/Products/Debug-iphoneos/Inbox2.app

# Install (an *update* install — preserves the app's data container).
xcrun devicectl device install app --device "$DEV" "$APP"

# Launch once (this creates the data container + Documents/inbox2/ on first run).
xcrun devicectl device process launch --device "$DEV" com.inbox2.ios
```

`build/` under `ui/ios` is gitignored — don't commit build products.

### Wireless deploy (dev-build OTA)

A dev build installs **over the air** — no cable — once the iPhone is paired to
this Mac over Wi-Fi. `devicectl device install` then transparently uses the
network tunnel. This is the OTA path for *your own* paired device; a shareable
tap-to-install link for other devices is a separate setup (Ad Hoc signing + an
`itms-services` manifest over HTTPS — not set up here).

**One-time: enable network pairing.**

1. Connect the iPhone **once with a cable** and tap **Trust** on the device.
2. Open Xcode › **Window › Devices and Simulators** (⇧⌘2), select the iPhone, and
   tick **“Connect via network.”**
3. Unplug. The phone stays reachable whenever it's on the **same network** as the
   Mac (and awake/unlocked). Confirm it's listed without a cable:

   ```sh
   xcrun devicectl list devices      # the iPhone should appear as "available (paired)"
   ```

**Verify the connection is wireless.** Transport should be `localNetwork` with the
tunnel connected:

```sh
DEV=<coredevice-UUID>                 # from `xcrun devicectl list devices`
xcrun devicectl device info details --device "$DEV" | grep -iE "transport|tunnel"
# transportType: localNetwork   /   tunnelState: connected
```

(If `tunnelState` is `disconnected`, it reconnects on the next `devicectl` call as
long as the phone is awake on the same network. A `usb` transport just means the
cable is also plugged in — install still works; unplug to confirm it's truly OTA.)

**Deploy.** `bin/ios-deploy-device` wraps the whole build → sign → install →
launch loop and auto-selects the paired iPhone:

```sh
bin/ios-deploy-device                 # Debug build, wireless install, launch
bin/ios-deploy-device --release       # Release config
bin/ios-deploy-device --xcframework   # rebuild InboxCore.xcframework first (after core changes)
bin/ios-deploy-device --seed          # also seed the store from the desktop (see §4)
bin/ios-deploy-device --no-launch     # install only
bin/ios-deploy-device --device <UUID> # target a specific coredevice id
```

Device selection order: `--device`, else `$INBOX2_IOS_DEVICE`, else the first
paired iPhone.

**Or by hand** (what the script runs — see §3 for the build step):

```sh
DEV=<coredevice-UUID>
APP=ui/ios/build/device/Build/Products/Debug-iphoneos/Inbox2.app
xcrun devicectl device install app --device "$DEV" "$APP"          # OTA install
xcrun devicectl device process launch --device "$DEV" com.inbox2.ios
```

**Troubleshooting.**
- *“no paired iPhone found”* — the phone is asleep, off-network, or network
  pairing isn't enabled. Wake/unlock it, confirm same Wi-Fi, re-do the one-time
  step. `xcrun devicectl list devices` should show it.
- *Install hangs or times out* — large first install over Wi-Fi is slower than
  USB; subsequent installs ship only changed files. Keep the phone unlocked.
- *Build fails on signing* — ensure `-allowProvisioningUpdates` (the script
  passes it) so the CLI can refresh the provisioning profile.

---

## 4. Seed the store (skip re-auth)

The engine opens `Documents/inbox2/inbox2.db` and decrypts stored OAuth/IMAP
tokens with a 32-byte `Documents/inbox2/.credential_key` (plain file, **not** the
Keychain — `crypto.rs CredentialEncryptor`). Copy both from the desktop store and
the engine connects + syncs the real accounts with **no OAuth round-trip**. (Same
mechanism as the simulator — see `memory/project_ios_real_data`; only the
transport changes: `devicectl device copy to --domain-type appDataContainer`
instead of `simctl get_app_container` + `cp`.)

```sh
DEV=<coredevice-UUID>
BID=com.inbox2.ios
DESK="$HOME/Library/Application Support/com.inbox2.desktop"

# 0. The app must have launched once (§3) so Documents/inbox2/ exists.

# 1. Terminate the app so the engine isn't writing WAL while we overwrite the DB.
PID=$(xcrun devicectl device info processes --device "$DEV" \
      | grep -i "Inbox2.app/Inbox2" | awk '{print $1}' | head -1)
[ -n "$PID" ] && xcrun devicectl device process terminate --device "$DEV" --pid "$PID"

# 2. Consistent snapshot of the live (WAL) desktop DB — a single self-contained file.
sqlite3 "$DESK/inbox2.db" ".backup '/tmp/inbox2-seed.db'"

# 3. Push the DB + credential key into the app's data container.
xcrun devicectl device copy to --device "$DEV" \
  --domain-type appDataContainer --domain-identifier "$BID" \
  --source /tmp/inbox2-seed.db --destination Documents/inbox2/inbox2.db
xcrun devicectl device copy to --device "$DEV" \
  --domain-type appDataContainer --domain-identifier "$BID" \
  --source "$DESK/.credential_key" --destination Documents/inbox2/.credential_key

# 4. Neutralize any stale -wal/-shm left by the first empty launch, so SQLite
#    doesn't try to replay an old WAL against the freshly seeded DB.
: > /tmp/empty
for ext in wal shm; do
  xcrun devicectl device copy to --device "$DEV" \
    --domain-type appDataContainer --domain-identifier "$BID" \
    --source /tmp/empty --destination "Documents/inbox2/inbox2.db-$ext"
done

# 5. Relaunch — the engine opens the seeded DB and syncs the real accounts.
xcrun devicectl device process launch --device "$DEV" "$BID"
```

Verify the files landed:

```sh
xcrun devicectl device info files --device "$DEV" \
  --domain-type appDataContainer --domain-identifier com.inbox2.ios \
  --subdirectory Documents/inbox2
# expect inbox2.db (~200 MB), .credential_key (32 bytes), and a growing -wal once running
```

Notes:
- The data container **survives an update install** (§3 reinstall), so you only
  seed once — rebuilds keep the DB.
- Without `.credential_key` the DB still loads (read-only UI works via optimistic
  local state), but connect/sync/send fail because tokens can't be decrypted.
- The DB is WAL-mode; the Swift reader opens it read-write but SELECT-only so it
  coexists with the engine's writes.

---

## 5. Logs

App-side `os.Logger` (subsystem `com.inbox2.app`) and the Rust core
(`com.inbox2.core`). Stream from the device using the **hardware UDID**:

```sh
UDID=$(xcrun devicectl device info details --device "$DEV" | awk '/udid:/{print $NF; exit}')
log stream --device "$UDID" --style compact --info \
  --predicate 'subsystem BEGINSWITH "com.inbox2"'
```

`log stream` only shows logs from the moment it attaches — start it first, then
relaunch the app to capture a clean engine boot. (Network log streaming is
flaky; if nothing comes through, view logs in Console.app with the device
selected, filtering by subsystem.)

---

## 6. Audio on device (vs. simulator)

The simulator is forgiving about `AVAudioSession`; a physical device is not. Two
device-only gotchas for the Bridge voice:

- **TTS playback needs no permission** — only the microphone/speech (STT) side
  does (`NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`,
  already in `project.yml`; `ListeningManager` requests record + speech auth at
  use).
- **Every playback path must activate a `.playback` session.** A spoken-audio
  `.playback` session is required for TTS to be audible *and* to ignore the
  hardware silent/ring switch. A listening turn calls `setActive(false)` on
  release (`ListeningManager`), so any TTS afterwards must re-activate it.
  `Speaker.activatePlaybackSession()` is the single place this happens; both the
  Apple `AVSpeechSynthesizer` path and the OpenAI/Kokoro `AVAudioPlayer` path
  call it. If you add a new audio path, call it there too.

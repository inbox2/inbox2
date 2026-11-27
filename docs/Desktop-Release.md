# Desktop Release — build, sign, distribute & auto-update

How the Tauri desktop client (`ui/desktop/`) is versioned, built for all three
OSes, signed, served by the Rails app, surfaced for download in `/console`,
and auto-updated in place.

> **A release is one local command.** After pushing to main, run
> `bin/release-desktop` from a terminal on Waseem's Mac: macOS (Developer ID,
> notarized), Windows (cross-compiled with cargo-xwin + NSIS) and Linux `.deb`
> (in Docker), all signed for the updater, published into a Pushleft
> bucket that Rails redirects downloads to. The building Mac skips the poll cycle: the fresh app is swapped into
> `/Applications/Inbox2.app` directly — a running copy is quit and relaunched
> on the new version. Other machines poll every two minutes and grow an
> **Update** tag on
> the bell. (This used to be a `desktop` CI job on a launchd runner on the same
> Mac; the runner kept going stale and silently timing the job out — in Sep
> 2026 four releases in a row never shipped — so the job was removed.)

---

## 1. The pieces

| Concern | Where |
|---|---|
| Version | `bin/version` — `MAJOR.MINOR` from `tauri.conf.json`, patch = commit count |
| Build + sign + publish (all OSes) | `bin/release-desktop` (`yarn release` in `ui/desktop` is an alias) |
| Release trigger | manual: `bin/release-desktop` after pushing (no CI job) |
| Release-only Tauri config | `src-tauri/tauri.release.conf.json` (updater pubkey + endpoint, `createUpdaterArtifacts`) |
| Linux builder image | `ui/desktop/Dockerfile.linux-build` |
| Manifest generator | `ui/desktop/scripts/gen-manifest.mjs` |
| Updater plugin + commands | `src-tauri/src/updater.rs`, registered conditionally in `lib.rs` |
| Update UI | `stores/updateStore.js`, bell tag in `Chrome/ChromeBar.jsx`, row in `NotificationPanel`, `pages/settings/AboutSettings.jsx` |
| Rails serving | `DesktopReleasesController`, `app/services/desktop_releases.rb` |
| Release store on prod | Pushleft bucket `pl-5329d773-desktop-downloads-acfdda72` (20 GiB quota; `DESKTOP_S3_*` in `.pl.yaml`, key in the secrets `DESKTOP_S3_ACCESS_KEY`/`_SECRET_KEY` for Rails; the release script uses `pl storage` and needs no key) |
| `/console` download card | `components/StoreBadges/StoreBadges.jsx` |

---

## 2. Versioning (`bin/version`)

```
bin/version          0.1.1543
bin/version --long   0.1.1543+eea0897
```

`MAJOR.MINOR` is whatever `ui/desktop/src-tauri/tauri.conf.json` says (`0.1`);
`PATCH` is `git rev-list --count HEAD`. Every push to main therefore ships a
strictly larger SemVer without anyone bumping anything — which is what the
updater compares. The short sha is build metadata (ignored for ordering) so a
version traces to its commit. A real bump (`0.2`) is a one-line edit to
`tauri.conf.json`.

No tags, no release commits, no changelog. `tauri.conf.json` / `Cargo.toml` /
`package.json` keep `0.1.0`; the real version is injected at build time with
`--config '{"version":"<v>"}'`, so `getVersion()` in the app reports it.

---

## 3. The build (`bin/release-desktop`)

```sh
bin/release-desktop              # build all three, publish to prod
bin/release-desktop --no-publish # build all three into dist/desktop/<version>/
```

What it does, in order:

1. `yarn install` in `ui/web` (`--ignore-scripts`: sharp's postinstall aborts
   here) and `ui/desktop`; builds the web client **once** with
   `VITE_API_ORIGIN=https://api.inbox2.com`. `tauri.release.conf.json` blanks
   `beforeBuildCommand` so the three OS builds share that `dist/`.
2. **macOS (aarch64)** — `tauri build -c src-tauri/tauri.release.conf.json
   --bundles app,dmg`. Developer ID signed + notarized via the App Store Connect
   key in `~/.appstoreconnect` (`APPLE_API_KEY=H9PLG58DB9`).
3. **Windows (x86_64)** — same, `--runner cargo-xwin --target
   x86_64-pc-windows-msvc --bundles nsis`. Needs `brew install nsis llvm`,
   `cargo install cargo-xwin`, `rustup target add x86_64-pc-windows-msvc`.
   Not Authenticode-signed (Azure Trusted Signing was never set up) —
   SmartScreen warns on first run; updates don't care. The exe imports the
   Visual C++ runtime (`MSVCP140.dll` + `VCRUNTIME140.dll`, pulled in by the
   prebuilt ONNX Runtime static libs), which a clean Windows does not have:
   without it the app exits at once with `0xC0000135` and no log (found on a
   fresh Windows 11 VM, 2026-11-07). `src-tauri/tauri.windows.conf.json`
   therefore bundles the five x64 runtime DLLs from `src-tauri/vcredist/x64/`
   (extracted from Microsoft's `vc_redist.x64.exe`) next to `Inbox2.exe`;
   app-local wins over `System32` in the DLL search order, so a machine that
   does have the redistributable is unaffected.
4. **Linux (x86_64)** — inside `Dockerfile.linux-build` as `linux/amd64` under
   Docker Desktop's emulation (cold ~30 min, then minutes: the target dir and
   cargo registry are named volumes `inbox2-linux-target` / `inbox2-linux-cargo`
   / `inbox2-linux-cache`). Only the Rust side compiles there; the web `dist/`
   is mounted in. Cargo runs 3 jobs (`LINUX_BUILD_JOBS`), not one per core —
   under emulation the gtk/webkit crates get SIGKILLed by the ~8 GB Docker VM
   when 18 rustc's fan out. Since 2026-11 even one job is not enough: the app
   crate's own rustc at opt-level 3 alone outgrows ~8 GB, so raise Docker's
   memory (24 GB works). `SKIP_LINUX=1` builds macOS + Windows without
   publishing: the server serves the newest version for every platform, so a
   release without Linux would drop it from the manifest and the Console. A `.deb` only — linuxdeploy's AppImage plugin is a static-pie
   binary Rosetta can't run. The `.deb` is signed on the Mac side with `tauri
   signer sign` (no key in the container). The image is cached by the
   Dockerfile's md5; after editing it, run the script once from a terminal so
   the new image builds (under launchd, `docker build`'s credential helper
   hangs).
5. `gen-manifest.mjs --mac-arch aarch64` writes `latest.json` from whichever
   `.sig` files are present.
6. Publish: `pl storage cp` every file into `<bucket>:<version>/` (your
   `pl login` as an Admin; `pl` mints a one-hour key for that bucket alone),
   `latest.json` last, so a client that polls mid-upload keeps getting the
   previous release (a version without its manifest never ranks). `pl storage`
   uploads large files in 16 MiB parts, each tried up to five times, so the old `pl cp` relay
   workaround (2 MB chunks joined on the server, 2026-11-07/08) is gone, and a
   push to `main` during a publish no longer breaks it. (Until 2026-11-16 this
   went into a `downloads` volume on the `api` role; before 2026-11 `kubectl cp`
   into Rancher.)
7. Prune with `pl storage ls` + `pl storage rm -r`: keep the newest 3 releases (`INBOX2_KEEP_RELEASES`), delete the rest.
   A client only ever downloads the newest version's artifact, never its own,
   so old ones are dead weight.

Secrets stay on the Mac: the updater key in `~/.inbox2-updater-key/` (a copy of
`~/Desktop/inbox2-updater-key/`), the notarization key in
`~/.appstoreconnect/`, the Developer ID certificate in the login keychain.
Publishing needs `pl login` as an Admin of the Pushleft organization. Never
`pl storage bucket create --set-secret` for this kind of bucket: it writes
`S3_ENDPOINT`/`S3_BUCKET`, which would repoint attachments. Look inside with
`pl storage ls pl-5329d773-desktop-downloads-acfdda72[:<version>/]`. Never put a
test `latest.json` in the bucket: any `<version>/latest.json` is live for every
client within a minute.

Output:

```
dist/desktop/0.1.1543/
  Inbox2_0.1.1543_aarch64.dmg
  Inbox2.app.tar.gz                    Inbox2.app.tar.gz.sig
  Inbox2_0.1.1543_x64-setup.exe        Inbox2_0.1.1543_x64-setup.exe.sig
  Inbox2_0.1.1543_amd64.deb            Inbox2_0.1.1543_amd64.deb.sig
  latest.json
```

> **macOS is Apple-Silicon-only.** The `ort` (ONNX Runtime) crate ships no
> prebuilt for `x86_64-apple-darwin`, so the manifest is tagged `--mac-arch
> aarch64` and Intel Macs are never offered an arm64 binary.

### CI: `.github/workflows/desktop.yml`

Every push to `main` runs the same release on GitHub-hosted runners: macOS
(signed with the Developer ID identity from `APPLE_CERTIFICATE`, notarized with
the App Store Connect key), Windows (native NSIS build) and Linux (`.deb`,
signed for the updater after the build), then one `publish` job that writes
`latest.json` and uploads into the Pushleft bucket with `PUSHLEFT_TOKEN`.
`bin/release-desktop` stays as the local fallback and also swaps the build into
`/Applications`. The old GitLab `desktop` job on a launchd Mac runner kept going
stale; hosted runners don't have that problem.

`bin/version` adds `PATCH_BASE` (2300) to the commit count: the private history
was squashed when the repo went public, and without the offset the first public
build would have been 0.1.1, which no installed copy (0.1.2283) would take.

---

## 4. The updater manifest (`latest.json`)

Generated by `gen-manifest.mjs` from the `.sig` files. One file holds **all**
platforms with both canonical and multi-installer keys:

```jsonc
{
  "version": "0.1.1543",
  "notes": "",
  "pub_date": "2026-08-31T00:00:00Z",
  "platforms": {
    "darwin-aarch64":        { "signature": "<.sig content>", "url": ".../Inbox2.app.tar.gz" },
    "darwin-aarch64-app":    { "signature": "…",              "url": ".../Inbox2.app.tar.gz" },
    "windows-x86_64":        { "signature": "…",              "url": ".../Inbox2_0.1.1543_x64-setup.exe" },
    "windows-x86_64-nsis":   { "signature": "…",              "url": ".../…setup.exe" },
    "linux-x86_64":          { "signature": "…",              "url": ".../…amd64.deb" },
    "linux-x86_64-deb":      { "signature": "…",              "url": ".../…amd64.deb" }
  }
}
```

- **`signature` is the *content* of the `.sig` file**, not a path or URL.
- The bare `{target}-{arch}` key is what older clients read; the
  `…-{installer}` keys are what multi-installer updates (plugin ≥ 2.10) need.
  A platform with no `.sig` in the folder is simply absent.

---

## 5. Signing

### 5.1 Updater signature (all OSes) — required

One minisign/ed25519 keypair, generated 2026-06-24. Lives outside the repo in
`~/Desktop/inbox2-updater-key/` with the copy `bin/release-desktop` reads in
`~/.inbox2-updater-key/`:

| file | what it is |
|---|---|
| `inbox2.key` | the private half — signs releases, never leaves that folder |
| `inbox2.key.pub` | the public half, pasted into `tauri.release.conf.json` → `plugins.updater.pubkey` |
| `password.txt` | the passphrase protecting the private key |

Updates are trusted because they are signed, not because of where they were
downloaded from: a compromised host can serve any bytes and the app refuses
them.

> ⚠️ **Back that folder up somewhere that is not this Mac.** Lose the key or its
> password and no future update can ever be signed — every installed copy is
> stranded on its version and must be reinstalled by hand. A new key does not
> open the doors the old one locked (`yarn tauri signer generate -w …` only if
> the old one is gone).

The updater config lives in `tauri.release.conf.json`, not the main config, on
purpose: `lib.rs` only registers the updater plugin when `plugins.updater` is
present, so `yarn dev` and `install:app:dev` builds neither need the key nor
offer to replace themselves with a prod build.

`yarn install:app` (the prod identity) is the exception, and deliberately so:
`install-local.mjs` reads that same `plugins.updater` block out of
`tauri.release.conf.json` and stamps the build with `bin/version`, so this Mac's
own build sits in the update stream like any other machine and the next release
reaches it. It still makes no updater *artifacts* (those are for other machines
to download) — so it needs no signing key. Without the version stamp the build
would carry `tauri.conf.json`'s `0.1.0` and read every published release as
newer, replacing itself on first launch.

### 5.2 macOS — Developer ID + notarization

Hardened runtime is on with `entitlements.plist` (JIT / unsigned-executable-memory
/ disable-library-validation — ONNX Runtime + bundled AI runtimes JIT; without
them notarized builds crash on first inference). Identity `Developer ID
Application: Waseem Sadiq (KF53B4S5HD)` from the login keychain; notarization
via `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_PATH`, all defaulted
in `bin/release-desktop`.

### 5.3 Windows / Linux

Not OS-signed. The updater `.sig` is the only signature; first installs get a
SmartScreen warning (Windows) or nothing (Linux, as usual). Azure Trusted
Signing / GPG detached signatures are the upgrade path when there is an
external audience.

---

## 6. Rails serving

`DesktopReleasesController` (routes in `config/routes.rb`):

| Route | Purpose | Cache |
|---|---|---|
| `GET /downloads/desktop/latest.json` | Tauri updater manifest (newest version) | **60 s** |
| `GET /api/v1/desktop/releases/latest` | `/console` download list (per-OS) | 60 s |
| `GET /downloads/desktop/<version>/<file>` | binaries: `302` to a 15-minute presigned bucket GET (`404` if absent) | 5 min |

`app/services/desktop_releases.rb` lists the bucket (cached 60 s in
`Rails.cache`, the same as the manifest's max-age), picks the highest stable version (prereleases never rank on the stable channel) and re-serves its
`latest.json` with a short TTL. `latest` returns `204` when nothing is
published; the manifest `404`. Tested in `spec/requests/desktop_releases_spec.rb`.

The bucket is private; the redirect keeps every URL under `api.inbox2.com`,
so manifests already in the field keep working. The `api` role holds no volume
for this, which lets its deploys roll with no downtime: with the volume, every
push cost ~85 s of 503s (stop-before-start, 2026-11-16).

---

## 7. `/console` download card

`StoreBadgesRow` fetches `/api/v1/desktop/releases/latest` and renders a
download button per OS — macOS `.dmg`, Windows `-setup.exe`, Linux `.deb`. URLs
come only from the API. When no build is published it shows the platforms
disabled.

---

## 8. In-app auto-update

Wired in `src-tauri/src/updater.rs` + `lib.rs`; UI in `stores/updateStore.js`.

- **Poll:** `updater::check_on_startup` waits 3 s after launch, then checks
  every 2 minutes (one small GET against our own server). On a hit it emits
  `update://available` with `{ version, current_version, notes, date }`.
- **Store:** `lib/updater.js → initUpdateNudge()` (main.jsx) feeds that into
  `useUpdateStore`. While `update` is set:
  - the bell in the chrome (`ChromeBar.jsx`) wears an amber **Update** tag;
  - the notification panel (`NotificationPanel.jsx`) shows an update row at the
    top of the feed — the same amber "one click needed" register as the
    message list's *Sign-in expired* banner (`layout.reauthBanner`) — with an
    **Update** button, then `Downloading 35%` → `Restarting…`;
  - Settings → *About & updates* shows the same update with **Install &
    relaunch**, plus a manual **Check for updates**.
- **Install:** `download_and_install_update` downloads (progress on
  `update://progress`), installs, `app.restart()`s. On Linux `.deb` the install
  hands off to a privileged system prompt — the UI says so and stays running.
- A build without the updater (`yarn dev`, `install:app:dev`) never polls, and
  the commands return an error instead of hanging.

---

## 9. Known gotchas (handled)

- **`strip = false` stays in `Cargo.toml`.** The CLI embeds a
  `__TAURI_BUNDLE_TYPE` symbol the updater reads to know which installer it is
  running as. Strip it and multi-installer updates silently pick the wrong
  artifact.
- **`latest.json` short TTL** — served via controller at 60 s, never statically.
- **`.sig` content, not path**, goes in the manifest `signature` field.
- **macOS hardened runtime** entitlements for JIT/unsigned memory (ONNX/AI),
  else notarized builds crash.
- **Keep files off the `api` role's disk.** A volume makes every api deploy
  stop-before-start (85 s of 503s per push); that is why releases moved to the
  bucket. Pruned to the newest three releases on every publish.
- **A release is visible only once its `latest.json` is there.**
  `DesktopReleases.latest_version` skips a version directory without one,
  because the publish copies the manifest last: ranking a half-uploaded release
  404s the endpoint for the minutes the copy takes, and every running client's
  update check fails with "Could not fetch a valid release JSON from the
  remote".
- **Do not run `bin/release-desktop` while `./bin/dev`'s Tauri watcher runs**
  unless `CARGO_TARGET_DIR` points elsewhere (CI uses
  `~/.cache/inbox2-desktop-target`) — they contend for the Cargo lock.

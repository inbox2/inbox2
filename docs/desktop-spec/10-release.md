---
part: "10"
title: Build and release
subtitle: From a push to main to an installed update.
eyebrow: Release
lede: A release is one local command run after pushing to main. There are no tags, no bumps and no release commits; the version is the commit count.
---

## Versioning

`bin/version` prints `MAJOR.MINOR.PATCH`: `MAJOR.MINOR` from `tauri.conf.json` (`0.1`), `PATCH` from `git rev-list --count HEAD`. Every push to main is therefore a strictly larger SemVer, which is what the updater compares. `--long` appends the short sha as build metadata. The config files keep `0.1.0`; the real version is injected at build time with `--config '{"version":"<v>"}'`, so `getVersion()` in the app reports it.

> **Decision** No tags, no release commits, no changelog. A real bump (`0.2`) is a one-line edit of `tauri.conf.json`. Source: `docs/Desktop-Release.md`.

## Building

```sh
bin/release-desktop                # build macOS, Windows, Linux; publish to prod
bin/release-desktop --no-publish   # build into dist/desktop/<version>/
SKIP_LINUX=1 bin/release-desktop   # macOS and Windows only, never published
```

1. `yarn install --ignore-scripts` in `ui/web` (sharp's postinstall aborts) and `ui/desktop`; one web build with `VITE_API_ORIGIN=https://api.inbox2.com`. `tauri.release.conf.json` blanks `beforeBuildCommand` so the three OS builds share that `dist/`.
2. macOS (Apple Silicon only; `ort` ships no x86_64 build): `tauri build -c src-tauri/tauri.release.conf.json --bundles app,dmg`, Developer ID signed and notarized with the App Store Connect key in `~/.appstoreconnect`.
3. Windows (x86_64): the same with `--runner cargo-xwin --target x86_64-pc-windows-msvc`, NSIS installer. It carries no Authenticode signature, so SmartScreen warns on first run.
4. Linux: built in Docker (`ui/desktop/Dockerfile.linux-build`, linux/amd64 under emulation, about 30 min cold, needs Docker Desktop at 24 GB), `.deb` only. AppImage cannot run under Rosetta.
5. Every artifact is signed with the updater key. `scripts/gen-manifest.mjs` writes `latest.json` from the `.sig` files.
6. If `/Applications/Inbox2.app` exists, the fresh build is swapped in and relaunched on this Mac.

Secrets stay on the release machine: `~/.inbox2-updater-key`, `~/.appstoreconnect`, and a Pushleft login as an admin of the organisation.

> **Decision** The `desktop` CI job was removed (September 2026). Its launchd runner kept going stale and silently timed the job out, so four releases in a row never shipped. Source: `docs/Desktop-Release.md`.

## The manifest

One `latest.json` serves all platforms. Older clients read the bare `{target}-{arch}` keys. Multi-installer updates (plugin ≥ 2.10) read the `…-{installer}` keys:

```jsonc
{
  "version": "0.1.2103",
  "pub_date": "2026-11-07T00:00:00Z",
  "platforms": {
    "darwin-aarch64":      { "signature": "<.sig content>", "url": ".../Inbox2.app.tar.gz" },
    "darwin-aarch64-app":  { "signature": "…", "url": ".../Inbox2.app.tar.gz" },
    "windows-x86_64":      { "signature": "…", "url": ".../Inbox2_0.1.2103_x64-setup.exe" },
    "windows-x86_64-nsis": { "signature": "…", "url": ".../…setup.exe" },
    "linux-x86_64":        { "signature": "…", "url": ".../…amd64.deb" },
    "linux-x86_64-deb":    { "signature": "…", "url": ".../…amd64.deb" }
  }
}
```

`signature` holds the content of the `.sig` file.

## Publishing

Releases live on the Pushleft `downloads` volume (5 GiB) of the `api` role, mounted at `/rails/public/downloads/desktop`. `DesktopReleasesController` serves the binaries as static files and the manifest through a controller with a 60 s TTL, so a new release is seen within a minute. The script copies with `pl cp` in verified, resumable 8 MB chunks, because the relay drops long copies. It writes `latest.json` last, so a half-uploaded release never ranks, and prunes to the newest three. The `/console` download card (`components/StoreBadges`) reads the same manifest.

> **Watch out** Do not push to main while a publish runs. A push redeploys the single `api` replica and the copy fails with "no ready instance". A re-run of the script skips files already up with the right checksum.

## In-app update

Release builds only: `plugins.updater` exists only in `tauri.release.conf.json`, and `lib.rs` registers the plugin only when it does. `updater::check_on_startup` waits 3 s, then checks every 2 minutes. On a hit it emits `update://available`. `updateStore` then shows the amber **Update** tag on the bell, a row at the top of the notification panel, and Settings › About with **Install & relaunch**. `download_and_install_update` reports `update://progress`, installs and restarts. On Linux the `.deb` install hands off to a privileged system prompt.

`yarn install:app` builds the prod identity into `/Applications` stamped with `bin/version`, so a locally built copy joins the update stream. `install:app:dev` and `yarn dev` skip the poll.

## Traps that are handled

- `strip = false` stays in `Cargo.toml`. The updater reads `__TAURI_BUNDLE_TYPE` to pick the right installer, and macOS 27 rejects stripped proc-macros ("mis-aligned LINKEDIT string pool").
- Hardened-runtime JIT entitlements, or notarized builds crash on inference.
- The release volume pins `api` to one replica; more replicas means moving releases to object storage first.

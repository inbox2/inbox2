---
part: "09"
title: Security and privacy
subtitle: Data boundaries, secrets and sealed mail.
eyebrow: Security
lede: Local mail stays off the inbox2 server, with one deliberate exception. Secrets are encrypted with a device-bound key. Sealed mail is decrypted on the device and stays out of every model and agent.
---

## Data that leaves the machine

| Data | Goes to | When |
|---|---|---|
| MX mail, actions, drafts | api.inbox2.com | always; the server owns it |
| Local channel mail | the provider only | never the inbox2 server |
| Push mapping ("mailbox X changed") | Rails | cloud push on; the token stays local |
| Triage text of local threads | TypeSafe (Jev) | only with the person's own key |
| Text for summaries and replies | OpenAI | only on the `openai` lane with the person's key |
| Remote image URLs | the Rails image proxy | only after the person loads images; direct load only on explicit consent |
| Open-tracking token | api.inbox2.com | the one deviation from "local channels never touch the API": a pixel hit cannot reach SQLite, so local clients poll opens with an unauthenticated capability token |
| Entity domain names (for logos) | the server | Lore imagery, never for freemail domains |
| Fields the person sees in Send to… | the chosen MCP server | only on Create |
| Contact enrichment query | api.apollo.io | only with an Apollo key; the one http allow-list entry |

> **Decision** Open tracking is the single deliberate deviation from the local-channel rule. Source: `docs/Open-Tracking.md`.

> **Note** `docs/Client-AI.md` still says "no email content leaves the machine". Since 2026-09-19 triage text goes to TypeSafe when a key is set. The settings copy states it; the older doc does not.

## Secrets

Provider tokens, IMAP passwords, the inbox2 `ink_` key (`cloud_auth_token`), the Jev, OpenAI and Apollo keys, and MCP client tokens are rows in `app_secrets` or `external_account_credentials`. The device-bound key from `core/sync/crypto.rs` encrypts them. A release desktop build keeps that key in the OS keychain; a debug build, `tauri dev` and the mobile apps keep it in `.credential_key`, an owner-only file beside the database, so a debug build's secrets are only as safe as the disk. A Linux release build does the same on a fresh store (no `.credential_keyring` marker and no `inbox2.db` yet) when the Secret Service is unavailable (no keyring daemon, no default collection), because otherwise the app could not open its database at all; the log says so with a warning. Once a store exists, a keyring failure is reported as a locked keychain and retried, never replaced by a new file key. The database check covers installs from before the marker existed. The webview keeps them out of localStorage. It asks the engine with `get_secret`, and the engine hands the token to the caller that needs it (`get_rails_token` for the image proxy, for example). The engine bus socket is mode 0600 because `get_secret` over it is unauthenticated.

The credential vault (`core/sync/vault.rs`, `vault_state`) backs credentials up to the cloud zero-knowledge. An Argon2id KEK comes from the account password. `rotate_vault` rotates it when the password changes, and `restore_from_cloud` restores the credentials on a new device.

> **Decision** Tauri local-at-rest encryption of the database was dropped; rely on OS full-disk encryption. The vault is low stakes because tokens are re-obtainable. Source: `docs/E2EE.md`.

## Sealed mail

A sealed domain's mail is end-to-end encrypted: the server holds ciphertext. The desktop opens it with `core/sync/seal.rs` using the member key handed in with `mx_set_domain_keys`. That key lives in memory only, is zeroized, and stays off the engine bus. Decision D4 (`docs/MX-Sync.md`) sets five conditions. The file is plain SQLite protected by disk encryption. Sealed rows go to no cloud AI lane. They are excluded from backups. They are wiped on sign-out or loss of the grant. They stay ciphertext until unlocked. Sealed rows are excluded from the `agent_*` views, from summaries, from Lore mining by a server model, from OTP detection, and from content conditions in MX rules.

## Signing in

The desktop signs in through the browser. `start_device_link` runs a loopback listener with PKCE. The web app's `/link` page approves the Mac. The shell then receives a device-scoped `ink_` key that does not expire. Password, passkey and TOTP logic stay on the web. A password login in the wizard's sign-in step also works. Passkeys fail there, because `tauri://` is an invalid passkey origin. The API origin is baked in at build time, and the bearer token comes from the engine's store.

> **Decision** Device link exists because 30-day sessions silently expired and disarmed cloud push. Source: `docs/Device-Link.md`.

## Rendering mail

HTML mail renders in `<iframe srcdoc>` with `sandbox="allow-same-origin"` and no scripts, under a strict CSP built by `buildSrcDoc.js` after `sanitizeEmailHtml.js`. Links are intercepted and opened outside the app (`email-link-router` → `open-external-link` → the opener plugin). Remote images are blocked until the person loads them. The proxy hides the person's IP from the image host. "Load directly" is offered only for hosts the proxy refused. Safe senders and "always show" are per-sender preferences.

> **Watch out** Safari revokes `allow-same-origin` when `allow-popups-to-escape-sandbox` is also set, which blanked the inbox once. Keep the sandbox exactly `allow-same-origin`.

## Agents and models

- The MCP server defaults to the `read` tier. Mutations need `read_write`; send and delete need `full`. Every call is audited. Full access sets auto-approve, so an agent with Full access sends and deletes unattended.
- Local rules that run a coding agent default to `allowlist`. `full_auto` is opt-in per rule with the trade-off shown. The first firing of an `approval_first` rule waits for a human.
- The MCP client calls a tool only from the Create button. Tool output is shown as text and stays out of every prompt.
- The triage label drives badges, sorting and the opted-in auto archive and trash. Nothing else acts on it.
- Bridge (mobile) drafts only. It does not send, save or RSVP.

## Notifications and the tray

The notification window shows a summary. For sealed mail it shows a content-free signal, then decrypts locally. Sign-in codes detected in unsealed mail are offered as a copy action through `clipboard-manager`. The window cannot become key, so it cannot capture input meant for another app.

## Updates

Updates are trusted by their signature, not by where they were downloaded from. One ed25519 minisign key, generated 2026-06-24, signs them; its public half is in `tauri.release.conf.json`. Losing the private key (`~/.inbox2-updater-key`) strands every installed copy. The manifest is served with a 60 s TTL from the api role. macOS builds are also Developer ID signed and notarized. Windows and Linux carry the updater signature only.

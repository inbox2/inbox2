# inbox2

Collaborative domain-based team email. All mail for a connected domain lands in a unified pool; members define filtered views over it. Routing rules push patterns to people, AI agents, or webhooks.

## Documentation

- **[docs/Feature-Spec.md](docs/Feature-Spec.md)** — Full feature specification (v1.10). Every item numbered (e.g. `7.3.5`) with release priority P0/P1/P2.
- **[docs/Reference-Implementation.md](docs/Reference-Implementation.md)** — API surface (A1–A17), screen map (S1–S13), engineering standards (E1–E5 API, F1–F4 frontend), design system (G1–G2), repo structure (H1–H5).
- **[docs/Explorer.md](docs/Explorer.md)** — Command Center network graph: the default entity graph (Lore ontology, MX + local merged, kind colours, domain logos, click → Lore pages) and the mailbox graph behind the toggle: architecture, data model, precomputed snapshots, search, Canvas rendering, benchmark results.
- **[docs/Ontology.md](docs/Ontology.md)** — Lore ontology: organizations/people/products/projects mined from mail. Deterministic header pass (every plan) + gluon-ported grounded LLM pass (verbatim-quote `ground`, `defang`, `salvage`, confidence `(1-0.5^support)*grounding` capped 0.95, floor 0.5, no review queue); MX → Postgres `lore_entities`/`lore_facts`/`lore_mentions` domain-scoped (`LoreMiner`, `LoreMineJob`, `lore:backfill`, `/lore/*` API), local channels → SQLite (`core/src/ontology.rs`, `lore_*` Tauri commands); sealed and private mail never mined by a server model.
- **[docs/MX-Inbound.md](docs/MX-Inbound.md)** — MX inbound receiver: architecture, SMTP flow, NATS integration, authentication, logging, test harness, concurrency model, inbound idempotency, DSN/ARF report routing.
- **[docs/MX-Sync.md](docs/MX-Sync.md)** — MX sync: the local mirror of inbox2-hosted mail, built on every client (step log + "What is left" at the bottom). Why MX mail was REST-only on every client, the decisions (Rust-core client, all history, directory included, sealed mail stored decrypted locally + its conditions), the protocol (trigger-stamped `change_seq`/`change_xid`, the transaction-horizon cursor that makes commit order safe, `sync/head|pull|backfill|keys`, tombstones with `parent_key`, visibility-loss-as-delete, key-set reconcile), client apply rules (version guard, hydrate-replaces-thread, settle guard), why MX mail has its own `mx_*` tables (a reader audit found ~400 statements assuming channel mail), the engine-owned action queue + settle guard, desktop/iOS/Android/CLI wiring, local FTS, the `agent_*` views that keep sealed mail from MCP clients, the mirror-is-a-cache schema versioning, and the `SyncTriggers`-vs-`schema.rb` arrangement.
- **[docs/Mail-Deliverability.md](docs/Mail-Deliverability.md)** — Making outbound mail trusted + learning when it isn't: central-key DKIM signing (`dkim:generate`), the suppression list, DSN bounce + ARF complaint processing, retry/state machine, `receiving_mail` promotion, MTA-STS serving, real ARC signing, and the remaining deliverability roadmap.
- **[docs/Disk-Sync.md](docs/Disk-Sync.md)** — Disk in Finder (macOS 15+): the Disk sync feed (`disk/sync/head|pull|keys|nodes`, trigger-stamped `change_seq` + `disk_sync_events`, `base_version` conflicts), the Rust engine in `ui/desktop/core/src/disk/` (`disk.db` remote tree + change log, resumable multipart uploads and ranged downloads, conflicted copies, sealed crypto ported byte for byte), the Swift File Provider extension (`ui/desktop/fileprovider/`, `build.sh` signs it before Tauri copies it into PlugIns), the app side (`disk_finder.rs`: config in the App Group container, domain add/remove, 30 s signal) and the FileVault rule (sealed shares open only while FileVault is on; the key is removed and sealed files evicted when it goes off).
- **[docs/ESP.md](docs/ESP.md)** — The ESP: an application sends mail through `POST /api/v1/esp/emails` with an org sending key (`isk_…`, `Esp::Key`) and reads per-recipient status and events back. Own tables (`esp_*`, models under `Esp::`), never conversations; hosted and send-only domains (`Esp::Domain`, verified by the DKIM CNAME); one delivery and one bounce address (`b+<token>@bounces.inbox2.com`) per recipient; rides the same NATS queue as inbox2's own mail (`Esp::Publisher`, results routed by the `ed_` key in `NatsSubscriber`); `email.*` webhook events; paid plans with `Plan::ESP_MONTHLY_SENDS`; the integrator's request and response shapes; what is not built (console UI, opens and clicks, feedback loops) and the go-live DNS.
- **[docs/Mail-Clients.md](docs/Mail-Clients.md)** — IMAP and SMTP submission for inbox2-hosted mail, off per org by default (`organizations.mail_clients_enabled`): the Go frontend (`mta/cmd/imap`, `mta/internal/mailclient`) holds no mail and calls Rails `/api/v1/mail-client` with the person's own app password (`MailClientPassword`, `imc_…`) on every request; the contract table; a person's own mail only (`Conversation.personal_to`), five folders derived from thread status, UIDs in `imap_messages`/`imap_folders` reconciled on access, `\Seen` = thread read, expunge never deletes for good, COPY = move; messages rebuilt from parsed fields with the original headers (`messages.raw_headers`, `MailClient::Mime`); sending through `MailClient::Submit`; limits (body signatures fail, no Drafts) and the production switch-on steps.
- **[docs/Tauri-Desktop.md](docs/Tauri-Desktop.md)** — Tauri desktop client: architecture, window chrome, external mailbox sync engine, IPC commands, testing, build config, and the macOS menu bar item (tray icon + `/tray` popover: unread summaries, coming up, month with day hover; title driven from the main window).
- **[docs/Desktop-Spec.md](docs/Desktop-Spec.md)** — The desktop client specification as a printed book (`docs/desktop-spec/*.md` → `docs/desktop-spec/inbox2-desktop-spec.pdf` via `docs/manual/build.py`, diagrams in `docs/diagrams/` built by `build.sh` with the Archify skill + the inbox2 skin): shell, core, data, sync, features, settings, AI, security, release, tests, the settled decisions with dates, and Appendix A, what is not built. Change a chapter, rebuild, commit the PDF with it. The CLI gap check is the separate working file `docs/CLI-Gap.md` (delete it once the CLI is brought level).
- **[docs/Desktop-Release.md](docs/Desktop-Release.md)** — Desktop release pipeline: every push to `main` releases through `.github/workflows/desktop.yml` (`bin/release-desktop` is the local fallback) — `bin/version` (`MAJOR.MINOR` from `tauri.conf.json`, patch = commit count + `PATCH_BASE`, no tags/bumps), macOS Developer ID + notarized, Windows via cargo-xwin + NSIS, Linux `.deb` in Docker; all updater-signed, `tauri.release.conf.json` (the only config carrying the updater), the `latest.json` manifest (multi-installer keys, `.sig` = signature content), publishing with `pl storage cp` into a Pushleft bucket, Rails serving (short-TTL manifest controller + 302 to presigned bucket GETs, so the api role has no volume and deploys with zero downtime), the `/console` download card, and the in-app flow (2-min poll → `updateStore` → amber **Update** tag on the bell + row in the notification panel + Settings › About).
- **[docs/CLI.md](docs/CLI.md)** — Python/Textual terminal client: shared single-engine bus (Unix socket + socket-file election), `engine_daemon` host, RPC surface, SQLite read path, full keymap, headless Pilot tests.
- **[docs/iOS-App.md](docs/iOS-App.md)** — Native iOS client (`ui/ios/`): architecture (read SQLite / write FFI), the `InboxEngine` UniFFI surface, the `InboxStore` SQL read layer, screen-by-screen layout, models/managers/components, design tokens, the loopback OAuth flow, logging, parity status, and Android-port notes.
- **[docs/Android-App.md](docs/Android-App.md)** — Native Android client (`ui/android/`): the feature-by-feature Jetpack Compose port of the iOS app over the same Rust core (UniFFI Kotlin bindings), same SQL, same FFI surface. The `:inboxcore`/`:app` Gradle modules, the `bin/android` build/drive driver + the `inbox2-android` MCP server (`ui/android/tools/android-mcp/`), the Rust-for-Android changes (vendored OpenSSL, oslog↔android_logger), design-token/screen/component parity, loopback OAuth via Custom Tabs, the inbox2 mx client, on-device AI (shared three-lane model manager + LiteRT/sherpa wiring), and parity status.
- **[docs/iOS-Device.md](docs/iOS-Device.md)** — Build, sign, install & run the iOS app on a physical iPhone (`xcodebuild` + `devicectl`), seed its SQLite store + `.credential_key` from the desktop to skip re-auth, device logs, and the on-device `AVAudioSession` gotchas for Bridge voice.
- **[docs/iOS-TestFlight.md](docs/iOS-TestFlight.md)** — Shipping the iPhone/iPad app through TestFlight: `bin/ios-release --upload [--xcframework]`, the App Store Connect API key used for both signing and upload, one-time app record + tester setup, the per-build flow and export compliance (declared exempt 2026-11-08), how TestFlight differs from `bin/ios-deploy-device`, and where kill and crash reports live.
- **[docs/Local-WhatsApp.md](docs/Local-WhatsApp.md)** — Local WhatsApp (desktop, macOS): WhatsApp Desktop's own database read live and read-only (WAL, never blocks the client), the WhatsApp tab + `wamedia://` media, a WhatsApp column in global search, and Lore items from asks (1:1 + group first-mentions/quotes) with Jev judging whether your reply completed them, plus **tracked business groups** (Jev picks them; the text lane keeps everyone's to-dos per group, `whatsapp_groups.rs`, `/lore/group/:chatId`); plus replying (text + attachments) and mark-read acted out in WhatsApp Desktop itself: the `widget-open-app/open-chat?chatJid=` link + Accessibility (`whatsapp_actions.rs`/`whatsapp_ax.rs`), each send confirmed against the database.
- **[docs/Channels.md](docs/Channels.md)** — External mailbox channels: the provider-agnostic Rust sync engine, the `ProviderAdapter`/`InteractiveProvider`/`CalendarAdapter` interfaces, Gmail/Microsoft/IMAP adapters, OAuth/token refresh, peculiarities, and the `sync-check` live e2e harness.
- **[docs/Client-AI.md](docs/Client-AI.md)** — Client-side AI: capability detection, classification (Tier A), Apple Intelligence summarization (Tier B), Swift bridge, progressive matching, setup flow.
- **[docs/AI-Lanes-and-Eval.md](docs/AI-Lanes-and-Eval.md)** — Unified AI model lanes (same Qwen2.5-1.5B free lane on all platforms, manifest-sourced), the user-editable prompt template file (`prompts.toml` + overrides over FFI/Tauri), and the triage eval harness (core runner, `triage-eval` CLI, desktop Triage Lab at `/triage-lab`, mobile FFI).
- **[docs/Vector-MCP.md](docs/Vector-MCP.md)** — Vector search & MCP agent interface: embedding pipeline, hybrid search (semantic + FTS5 + RRF), MCP server (in-core over loopback HTTP, dual-era: spec 2026-07-28 stateless + legacy `initialize`; 27 tools incl. attachments, drafts, send, tags, move, delete, calendar event create and read-only WhatsApp; 4 resources; writes defer to the sync engine's write-back queue), 3-tier permissions, audit logging, agent auto-approve.
- **[docs/Triage.md](docs/Triage.md)** — Triage on Jev (TypeSafe System One): one typed call per thread picks the action label (8 built-ins + org/user custom labels), a 0–4 priority score and the Space (with `not_for` contrasts); the shared question contract + `jev_triage` parity fixture (Ruby `JevTriage` ↔ Rust `triage::jev_questions`), MX flow (`TYPESAFE_API_KEY`, `triage_labels` table + API, re-triage per inbound, `waiting_reply` on send, sealed mail gets no summary), local flow (the user's own key as an AI integration, rules-only without one, `triage_priority` column), thresholds, errors, and the summaries that stay on OpenAI/on-device lanes.
- **[docs/MCP-Client.md](docs/MCP-Client.md)** — Outbound MCP client (Lore "Send to…"): Rust-core Streamable-HTTP JSON-RPC client (`core/src/mcp_client/`), OAuth 2.1 discovery + DCR + PKCE over the device-link loopback, connections in `engine_settings` + tokens in encrypted `app_secrets`, the `mcp_*` Tauri commands, verified presets (Linear/GitHub/Atlassian/Notion/Sentry/HubSpot/Asana/Salesforce), `SendToDialog` draft-only templates, and the threat model (tool results untrusted, never auto-called).
- **[docs/Agentic-Filters.md](docs/Agentic-Filters.md)** — Agentic filters for local channels: the static-rule → on-device-gate → `run_agent` funnel (the single Tier-2 action; replaces the old webhook idea). An `AgentAdapter` trait wraps four installed CLI agents (Claude Code/Codex/OpenCode/Gemini) with verified unattended invocations, a filesystem-contract harness (scratch dir + `result.json`), per-rule permission posture (`allowlist`/`approval_first`/`full_auto`), the `local_agents`/`local_rules`/`agent_runs` tables, the `AgentRunner` queue worker, and the prompt-injection threat model.
- **[docs/Notifications.md](docs/Notifications.md)** — Notification system: trigger path (Rust sync → Tauri event → SyncManager), desktop Tauri window vs browser popup vs Notification API, payload shape, testing.
- **[docs/Live-Activity.md](docs/Live-Activity.md)** — iOS Mail Live Activity: the lock-screen/Dynamic Island card with inline Read/Archive/Trash + a "+N" pill, the `MailActivityAttributes.ContentState` wire contract, the two start paths (Rails-direct for MX vs app-requested `push-devices/live-activity/start` for channel mail), token lifecycle, App-Intent buttons (run in the app process, share the notification-action queue, clear the banner up front), the `liveactivity` APNs payload, the iOS background-throttling reliability problem + on-device `live-activity.log` diagnostics, and the Rails-direct-placeholder fallback (Alternative A) kept in reserve.
- **[docs/Cloud-Push.md](docs/Cloud-Push.md)** — Cloud push for local channels: realtime Gmail/Office365 delivery via Rails-backed Pub/Sub watch + Graph subscriptions without exposing the OAuth token; `ChannelPushSubscription` mapping, provider webhook receivers, `PushSyncChannel` fan-out, idempotent renewal, 30-day lease GC, gating, and the Tailscale Funnel dev setup.
- **[docs/Device-Link.md](docs/Device-Link.md)** — "Link this device to your inbox2 account" (OAuth-style loopback + PKCE): the `DeviceLinkRequest` one-time code + `auth/device-link/{authorize,token}` endpoints minting a device-scoped non-expiring `ink_` `ApiKey` (`device_platform`), the web `/link` approval page + `?next=` login bounce, the desktop `start_device_link` Tauri command, the iOS/Android `DeviceLinkService` + `CloudSession.adoptLinkedToken`, and the account "Linked devices" revoke UI.
- **[docs/App-OAuth.md](docs/App-OAuth.md)** — Brokered provider OAuth for registered third-party applications: an org admin registers an app in the console (name, icon, exact-match redirect-URL whitelist), the app's server opens a flow with an inbox2 API key, the person sees a branded "«App» wants to connect your Google account — powered by inbox2" consent screen, and the app receives the **provider's** access/refresh tokens at its whitelisted callback (single-use `oag_` flow key + API key at redemption; tokens encrypted on the row and wiped on read). Also the `OauthProvider` registry that now backs the pre-existing per-client Google/Microsoft proxies, and the Google/Azure redirect-URI registration this needs before it works.
- **[docs/App-OAuth-Integration.md](docs/App-OAuth-Integration.md)** — Integrator-facing manual for the *calling* application (hand this to a partner or a coding agent; self-contained, no inbox2 internals): what you get and the fixed scope set, the three things to ask the inbox2 admin for (write-scoped `ink_` key, registered app, `oap_` id), the four HTTP calls with full request/response shapes, `state` handling, the `?error=access_denied|server_error` returns, single-use redemption + the 15-min/10-min windows, refreshing through `auth/app-oauth/refresh` (and the Microsoft-rotates-refresh-tokens trap), a worked Express example, token-storage rules, and an error/troubleshooting table.
- **[docs/Meta-Setup.md](docs/Meta-Setup.md)** — End-user manual (+ PDF) for connecting WhatsApp / Messenger / Instagram: concrete click-by-click steps to create a Meta app, add products, copy the App Secret, generate a never-expiring System User token with the right scopes, assign assets, find the one asset ID (WABA / Page), then paste the three fields into inbox2's Add-account form. Covers testing/App-Review, coexisting with another tool on the same number/Page, the WhatsApp 24h rule, and a troubleshooting table. No inbox2 internals — engineering detail lives in [Channels.md](docs/Channels.md) + [Cloud-Push.md](docs/Cloud-Push.md).
- **[docs/Calendar.md](docs/Calendar.md)** — MX server-side calendar: the `calendars`/`calendar_events`/`calendar_attendees` model, the single/recurring-master/occurrence-override row shapes and the `cev_x@20260209T090000Z` occurrence-id scheme, RRULE expansion via ice_cube (`CalendarOccurrences` — pass it an UNFILTERED scope, cancelled overrides are tombstones), outbound invitations (`CalendarInviteDispatch` + `IcsRequest` → `messages.calendar_reply`, METHOD read from the ICS body, SEQUENCE bumping), inbound REPLY/CANCEL (`InboundCalendarResponse`), accepting an emailed invite onto your calendar (`CalendarInviteImport`), `Calendar.primary_for` auto-provisioning, `CalendarChannel`, and what is still not built (reminders never fire, no recurrence UI, no ICS export). Also the Google-style **internal invitation** model (one canonical event; `visible_to` includes anything you're an attendee of, `editable_by` does not — no row copying), **org-wide busy-only free/busy** (deliberate: a colleague with a private calendar used to read as free all week), and the **scheduling assistant** (`GET events/availability` → attendees + working hours + ranked slots; `SchedulingAssistant.jsx` Exchange-style grid). Per-user **working hours + out-of-office** live on `users` (jsonb minutes-from-midnight + one OOO period, edited in Settings › Scheduling; OOO counts as busy **and fires an RFC 3834 auto-reply** — `OutOfOfficeResponder`, once per sender per absence via the `out_of_office_replies` UNIQUE index, with loop guards read from the raw MIME because the MX ships only nine fixed headers), and **counter-proposals** run the full RFC 5546 COUNTER/DECLINECOUNTER loop (`CalendarProposal`; accept moves the event and re-invites, organizer-only). **Zones**: user-scoped soft focus blocks (`zones`/`zone_categories`, palette-key colours) that never count as busy; each client raises a sticky "You're in the zone" card when one starts. **External busy**: devices upload busy-only blocks from local Gmail/Office365 calendars (`mx_push_busy` → `PUT orgs/:id/external-busy` → `external_busy_blocks`, per-device `source`), folded into FreeBusy like blocked time.
- **[docs/Conferencing-Setup.md](docs/Conferencing-Setup.md)** — Setting up Google Meet / Teams link generation from scratch (meet links → accept): create/reuse the Google web OAuth client + enable the Meet REST API + the sensitive `meetings.space.created` scope, the Entra app Web platform + delegated `OnlineMeetings.ReadWrite`, the exact conferencing callback redirect URIs, env vars (`GOOGLE_WEB_CLIENT_ID` pair vs installed-app fallback), verification notes, and a troubleshooting table. No inbox2 internals — those live in [Calendar.md](docs/Calendar.md).
- **[docs/Meeting-Invites.md](docs/Meeting-Invites.md)** — Meeting invites (ICS): parse `text/calendar` events + either answer them (Accept/Tentative/Decline) or **add them to your calendar** (`METHOD:PUBLISH` confirmations/bookings — MX `POST messages/:id/calendar-import`, local channels `add_invite_to_calendar` writing through the provider API with Google `events.import` so the UID survives), from an Outlook-style banner below the email header. Also the **time-zone rules**: keep the `TZID`, normalise it to IANA (`X-LIC-LOCATION` → looks-IANA → CLDR Windows table) or Google 400s, and hand the provider a bare wall clock plus a separate `timeZone`. MX path (Rails: inbound parse → `messages.calendar_invite`/`rsvp_status` → `POST messages/:id/rsvp` → emailed `METHOD:REPLY` via the outbound pipeline). Local path (Rust core: `ics.rs` parser + `invite_from_attachment`/`respond_invite` → provider calendar API when the UID matches a synced event, else emailed REPLY via the outbox). Web/iOS/Android banners + the desktop Tauri commands + the bare-`text/calendar`-lands-in-body gotcha.
- **[docs/Open-Tracking.md](docs/Open-Tracking.md)** — Email open tracking: per-domain (MX) / per-channel (local) opt-in, the 1×1 pixel injected across all three send paths (inbox2/ESP/local), the public `GET /o/:token.gif` endpoint, server-side open collection (Postgres for MX, unauthenticated capability poll for local channels — the one unavoidable server touch), token correlation (`messages.tracking_token` vs body-embedded token), custom tracking domains via Cloudflare-for-SaaS + the DNS-only "grey cloud" rule (the verna gotcha), and Apple-MPP/Gmail-proxy prefetch flagging.
- **[docs/Email-Body-Collapsing.md](docs/Email-Body-Collapsing.md)** — Email body collapsing: quote detection (HTML-structural + line-based), signature detection (structural + RFC 3676 delimiter + contact-block heuristic), QuotedText component.
- **[docs/Touch-Strip.md](docs/Touch-Strip.md)** — The app-wide Touch Bar-style bottom bar (web/desktop): world clocks + meeting planner, weather, squarified stock treemap, crypto sparklines, RSS news ticker, public IP; tap a key for its full-width view; pinned/floating/hidden via `usePaneMode`. Public throttled `GET /api/v1/strip/*` feeds (Yahoo chart for stocks AND crypto pairs — unofficial, no key; Open-Meteo; ip-api; user RSS through `PrivateAddressGuard`), all server-cached, and the layout synced in `users.touch_strip` via `account/touch-strip`.
- **[docs/Keyboard-Shortcuts.md](docs/Keyboard-Shortcuts.md)** — Keyboard shortcuts: the single-source-of-truth registry (`lib/shortcuts.js`) driving the dispatcher, menu hints, and `?` help overlay; Gmail/Outlook scheme; per-view coverage; how to add a shortcut.
- **[docs/Routing.md](docs/Routing.md)** — Web URL routing (user → org → domain): the domain-slug workspace scheme (`/:domainSlug/mail/inbox`, unified at `/:orgSlug/mail`), slug derivation (`name.parameterize`), the `resolveWorkspace` resolver + API `key||slug` resolution, the `parseUrl`/`navigationStore`/`ChromeBar` core, the org-level-vs-domain-level golden rule (non-mail routes use the org's primary slug), the Space-overrides-domain-filter rule, console card slugs, and the not-yet-wired per-domain-settings gap.
- **[docs/DropBlock.md](docs/DropBlock.md)** — DropBlock mini-game (web/desktop): source layout, the two build outputs (web/desktop `yarn build` vs the generated `ui/ios/Resources/dropblock-game.html` WebView overlay — note: removed from iOS, see SpaceShooter) and how to regenerate them, the native state-resume bridge, touch/keyboard input, desktop focus pause/resume, and power-ups.
- **[docs/SpaceShooter.md](docs/SpaceShooter.md)** — NEON STRIKE: the native SceneKit space shooter in the iOS Bridge (replaced DropBlock on iOS). Source layout (`ui/ios/Sources/Game/`), the retro low-res/flat-shaded synthwave rendering, procedural ship kit, the `renderer(_:updateAtTime:)` engine (spawning/AI/weapons/collisions/biomes/bosses), Codable+UserDefaults resume, Bridge integration, and the Higgsfield icon.
- **[docs/VoxelStrike.md](docs/VoxelStrike.md)** — VOXEL STRIKE: the native Kotlin + OpenGL ES voxel destruction shooter in the Android Bridge (counterpart to NEON STRIKE; deliberately the opposite look — bright daytime Minecraft-lineage voxels, not synthwave). Source layout (`ui/android/app/.../game/`), the chunk-meshed GPU renderer, the `128×64×128` hash-noise world, cheap "connectivity + grid gravity" destruction (carve sphere → ground support flood-fill → falling voxels), the four-weapon power curve, the golden-egg → next-level loop, the Higgsfield weapon/egg sprites, GL-thread/worker threading, and Bridge overlay integration + `SharedPreferences` resume.
- **[docs/Deployment.md](docs/Deployment.md)** — Cloud deployment on **Pushleft** (Rancher is dead since 2026-11): `.pl.yaml` roles (release/api/worker/nats-subscriber/nats/garage/rspamd/mail), the one image `deploy/pushleft/Dockerfile` + `run` env mapping, GitHub Actions `pl up --production` on `main`, operating prod with `pl logs/exec/cp/db connect/secrets`, Cloudflare Pages for the web app, DNS (`deploy/dns` still holds stale Rancher IPs), and the local-only secrets policy.
- **[docs/Go-Live.md](docs/Go-Live.md)** — Production go-live: the `deploy/prod` env (`api.inbox2.com` API + `mail.inbox2.com` web on Cloudflare Pages), the web cross-origin `VITE_API_ORIGIN`/`--mode pages` build, no-demo-data seed guard, and the launch checklist — secrets rotation, Google OAuth verification + CASA, Microsoft publisher verification, Gmail Pub/Sub hardening, email deliverability (DKIM/SPF/PTR/MTA-STS), and APNs prod tokens.
- **[docs/SaaS.md](docs/SaaS.md)** — SaaS operations (platform admin): the cross-tenant operator API (`/api/v1/saas`) gated by mTLS client cert + IP allowlist (no user login), `AdminCredential`/`SaasAuditLog`, per-org plan override + mailbox-limit model, org create/suspend/GDPR-wipe/usage, org user management, password-reset mail via the ported Messy client, the dashboard + type-to-search, the `ui/admin-cli` Textual operator client, and the deferred ingress-mTLS wiring.
- **[docs/Waitlist.md](docs/Waitlist.md)** — Invite-only waitlist + its prod deployment: the public Turnstile-gated `/waitlist` form (deduped without leaking existence), the `INVITE_ENABLED` signup gate, SaaS/admin-cli invite flow, in-repo Messy HTML emails, the Cloudflare Turnstile setup, the Terraform env wiring + gitignored-tfvars secrets, the one-time prod DB-table step, and the `-target` apply procedure (with the CI image-pin trap).
- **[docs/TODO.md](docs/TODO.md)** — Implementation checklist ordered by priority.

## Repository structure

```
api/          — Rails JSON API (Ruby 3.3.8, Rails 8.1)
mta/          — Go mail transport (MX inbound receiver + SMTP outbound sender: DKIM signing, MX delivery, retry)
ui/web/       — React web app (Vite, CSS Modules, Storybook)
ui/desktop/   — Tauri desktop client (Tauri v2, custom chrome, offline sync)
ui/cli/       — Python/Textual CLI (Textual TUI over the shared Rust engine bus; see docs/CLI.md)
ui/admin-cli/ — Python/Textual SaaS-ops TUI (httpx + mTLS over /api/v1/saas; see docs/SaaS.md)
ui/ios/       — Native iOS client (SwiftUI over the shared Rust core; see docs/iOS-App.md)
ui/android/   — Native Android client (Jetpack Compose over the shared Rust core; see docs/Android-App.md)
data/         — Database dumps for fast dev setup
deploy/       — Pushleft image + run script (deploy/pushleft), Gmail Pub/Sub Terraform (deploy/gcp-pubsub)
docs/         — Specs, reference impl, MX docs, TODO
website/      — Prelaunch landing page (Cloudflare Pages)
```

## Tech stack

| Component | Technology |
|-----------|-----------|
| API | Rails 8.1, PostgreSQL, Alba serializer, Solid Queue |
| Frontend | React 19, Vite, CSS Modules, Storybook |
| Graph viz | react-force-graph-2d (d3-force + Canvas) |
| Queue | NATS + JetStream (Docker, nats-pure gem, nats.go client) |
| MX inbound | Go (mta/cmd/mx — SMTP server, SPF/DKIM/DMARC, publishes to NATS) |
| SMTP outbound | Go (mta/cmd/smtp — DKIM signing, MX lookup, delivery + retry, NATS consumer) |
| Object store | Garage S3-compatible (aws-sdk-s3, S3StorageService, config/storage.yml) |
| Desktop | Tauri v2 (Rust backend, SQLite, custom chrome, IMAP sync) |
| iOS | SwiftUI + the shared Rust core via UniFFI (xcframework); WKWebView email body |
| Android | Jetpack Compose + the shared Rust core via UniFFI Kotlin (cargo-ndk JNI); WebView email body |
| Spam filter | Rspamd + Redis (k8s, `deploy/modules/rspamd`; Rails scores plaintext + trains, MX scores sealed mail inline) |

## Running locally

```sh
# Full stack (herdr workspace, recommended)
./bin/dev

# One process, as each herdr pane runs it (up-arrow reruns it)
bin/run react|rails|tunnel|docker|mx|nats|garage|website|tauri

# Or manually:

# API
cd api
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server -p 4000

# Frontend
cd ui/web
yarn install
yarn dev             # Vite dev server on :4173 (proxies /api to :4000)
yarn storybook       # Storybook on :6006

# Object storage (attachments) — Garage, needed for any attachment download
docker compose -f docker/docker-compose.yml --profile storage up -d
bin/garage-init          # idempotent: cluster layout + access key + bucket

# Tests
cd api && bundle exec rspec
cd ui/web && yarn lint

# Seed data: username=demo password=password123
```

## Database dumps

Pre-built dumps in `data/` for fast dev setup — skip the 20-minute corpus download + parse.

```sh
# Restore Enron dump (118K conversations, 210K messages, 13K mailboxes, ~10 sec)
cd api
bin/rails db:drop db:create
pg_restore --no-owner --dbname=api_development ../data/enron_db.dump
```

To rebuild the dump from scratch:

```sh
cd api
bin/rails db:create db:migrate db:seed
rake datasets:load[enron]                # ~20 min (downloads 423MB corpus)
pg_dump api_development --format=custom --compress=6 -f ../data/enron_db.dump
```

## Way of working

### API standards (binding, from spec E1–E5)

- **E1 Testing**: Every endpoint has positive + negative tests, mapped to spec item numbers.
- **E2 Templated responses**: All JSON via Alba serializers, never inline `render json: {...}`. Error responses via `ErrorSerializer`.
- **E3 Tenant isolation**: Every org-scoped query is scoped to the authenticated user's membership. Cross-tenant access returns 404.
- **E4 Minimal I/O**: Explicit allow-lists for params; serializers expose only declared fields.
- **E5 Public IDs**: All API-facing IDs are prefixed nanoids (`usr_`, `org_`, `conv_`, `msg_`). Internal numeric IDs never leak.

### Frontend standards (binding, from spec F1–F5)

- **F1 CSS architecture**: CSS Modules only. No Tailwind. No inline styles (`style={{}}` banned by ESLint — build fails).
- **F2 Component library**: All UI in `ui/web/src/components/`. Check the library before building new UI.
- **F3 Iconography**: SF Symbols via the `Icon` component.
- **F4 Keyboard operability**: Full keyboard reachability is a hard guarantee.
- **F5 No native date pickers**: never `<input type="date">`, `type="datetime-local"` or `type="month"`. Their popup is browser chrome no stylesheet reaches, so it drops a white system calendar over the dark theme (2026-10-02, the zone editor's "repeat until"). Every calendar in the UI is ours: use `components/DateField` (the catalog `MiniCalendar` in a `Popover`; `time` prop for date+time). `type="time"` alone is tolerated, with `color-scheme` following the theme.

### Design direction

Vista Aero atmosphere × modern operational SaaS. Deep navy-charcoal surfaces, warm steel accents, gradient buttons with beveled highlights, panel architecture with groove borders and inset shadows. Design tokens in `ui/web/src/styles/tokens.css` (dark + light + high-contrast + solarized themes).

### Commit discipline

- Commit after each logical unit of work.
- Commit message: short summary, then bullet list of changes.
- Always include `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

### No duplicated enums

Status values, roles, kinds, and other enum-like strings MUST be defined as constants on their model and referenced everywhere — never hardcoded as raw strings.

### No hardcoded data in frontend

All data displayed in production components MUST come from API calls. Static UI structure (command palette commands, filter fields) is acceptable.

### No inline styles

ESLint bans `style={{}}`. Dynamic values use CSS custom properties set via `ref.current.style.setProperty('--var', value)`.

## Project knowledge & gotchas

Non-obvious architecture and traps not otherwise captured in the docs above. Full detail lives in the linked `docs/` files; these are the load-bearing reminders.

### Architecture invariants
- **Two sync modes, never conflate them**: **MX** syncs with the Rails API / PostgreSQL (inbox2-hosted domains); **offline channels** (Gmail/Office365/IMAP) are fully client-side SQLite via the SyncChannel pattern and **never touch the API**. MX mail is *also* mirrored locally since 2026-09-20 (docs/MX-Sync.md) — in its own `mx_*` tables, never in `conversations`/`messages`, so channel-only code can't pick it up by accident; a consumer that should see MX mail opts in on purpose, and anything agent-facing reads the `agent_*` views (sealed mail never reaches an agent). New cross-mode features need two paths — never propose server-side sync jobs for Gmail/Office365 data. Cloud sync of channels for the web client (server-held provider tokens and mail) was considered and declined by Waseem on 2026-11-11; the web client stays MX-only for mail, and the "connected mailboxes never touch our servers" claim stands.
- **Org owns the domain model** (not the user): org has many first-class `Domain`s (DNS/MX/MTA-STS per domain); subscription + plan enforcement live on the org; `owner_id` = primary owner, `owners` = role:owner memberships; addresses are per-domain `Mailbox` rows; billing is org-scoped.
- **Plan tiers**: code identity is `Plan#tier` slug (`free`/`paid`/`max`); name is a label only. AI auto-triage (Spaces → OpenAI) is paid-only, gated via `Plan#ai_triage` / `Organization#ai_triage_enabled?` at enqueue + `ClassifySpaceJob`.
- **Web proxy defaults to REMOTE PROD API**: `ui/web` (:4173) proxies `/api` to `api.inbox2.com` (live prod data — test env destroyed) unless `INBOX2_API_ORIGIN` is set. Local Rails changes won't show unless you point it locally.

### Web frontend gotchas
- **HTML emails render in a sandboxed `<iframe srcdoc>`** (`allow-same-origin`, no scripts); image-proxy/link-interception/quote-collapsing/height all operate on `iframe.contentDocument`. Plain-text keeps the inline `QuotedText` path. See `EmailFrame.jsx`.
- **Remote images blocked by default**, loaded via the Rails image proxy; new reading panes must reuse `useRemoteImages`.
- **Mark-as-read**: Outlook-style 4 modes (default 5s dwell); reuse the shared `useMarkRead` hook + `markReadPref`.
- **Nav**: conversation selection must use `replaceStack` (not `replace`) or the back button breaks. In-app browser navigations live on `navigationStore.stack`; `browserStore` is a pure webview controller.
- **Sync-vs-writeback guard**: agreement-based; completed write-backs retained 180s so a stale sync can't resurrect a mutated thread.
- **Aero bevel-white color literals are intentional**; accent tints via `color-mix` over tokens. Theme runtime is in `lib/themes.js` + `useTheme` (high-contrast/solarized removed).
- **Two design layers**: light bento "management" look (`styles/management.css`, `components/management/*`) for auth/onboarding/admin; dark Aero theme for the mail client.
- Channel inbox must **not** re-select the last conversation on sync when the user deliberately deselected.

### Desktop (Tauri)
- **Dev/prod split**: `com.inbox2.desktop` (prod, /Applications, real mail) vs `.dev` (golden badge, demo data, `yarn dev`); `INBOX2_BUNDLE_ID` override + `tauri.dev.conf.json`; `install:app` / `install:app:dev`.
- Window/plugin APIs fail silently unless the permission is in `capabilities/default.json` (e.g. `allow-set-size`); rebuild after changes.
- **macOS**: CSS `backdrop-filter` can't frost the desktop behind the transparent webview (floats must stay near-opaque); native child WKWebViews composite over floating windows regardless of window level (need occlusion/step-aside, not a level bump).
- Windows parity: `data-os` CSS, `formatShortcut` glyphs, `default_data_dir`, opener plugin, systemicons, single-instance deep links.

### iOS / Android
- **iOS reads `inbox2.db` directly** (`InboxStore`), writes via FFI. Seed the sim/device from the desktop DB to test without OAuth. Android (`ui/android/`) is a Compose port over the **same `inbox2-core` Rust core** (UniFFI Kotlin) — same SQL, same FFI, same tokens; build/drive via `bin/android` + the `inbox2-android` MCP.
- **Styling single-source**: fonts via `AppFont` only, brand hues via `ChannelColor`, ring via `palette.ringGradient`. Channel colors are deterministic per-channel gradients keyed on `accountKey`.
- **iOS OOM/jetsam**: app was killed while suspended holding the ~1.6GB on-device LLM — fixed via foreground-gated loads + unload on background/memory-pressure + `isAvailable` gate. Keep model loads foreground-gated.
- New iOS entitlement (App Groups etc.) fails `bin/ios-deploy-device` with "No Accounts" until a one-time Xcode sign-in / ASC API key registers it on the portal.
- `GameModel` (NEON STRIKE) must route HUD state through `publish()` on the main thread — render-thread `@Published` writes freeze the app.
- iOS `.contextMenu` on a row subview fires for the whole cell; use `Menu(primaryAction:)` for region-scoped row menus.

### On-device AI / Bridge
- **Bridge never sends**: the voice agent only drafts to screen — never auto-sends mail or saves/RSVPs invites.
- Bridge uses a structured-JSON **intent layer** (intent + confidence); Apple Intelligence uses `@Generable` guided generation, Gemma/OpenAI use text-JSON.
- **Apple Intelligence is OFF on the user's iPhone** — the on-device lane falls back to OpenAI when a key exists (Bridge + triage).
- **TTS break-in is mandatory**: every TTS surface arms the shared `KeywordSpotter` (iOS) / `BargeInListener` (Android); stop-words cancel/stop/ok/okay/enough mirrored cross-platform. **Arm the mic before TTS starts** or the first second is clipped.
- Free NLU lane = Qwen2.5-1.5B (default) + a Gemma 3 1B variant (mobile Gemma is HF-token-gated; turn formats differ per model).
- Triage worker: on-device generation must time out (worker blocks inline); pending excludes exhausted poison; failure-reactivation is one-shot.
- **Bridge car mode**: top-left toggle; car = full brief, normal = terse headline. CarPlay and Android Auto each have a brief list (`CarPlaySceneDelegate.swift`, `car/BridgeCarScreen.kt`) that speaks through the session with barge-in armed; the CarPlay scene never starts until Apple grants the `carplay-communication` entitlement, which is not in `Inbox2.entitlements`.

> Contributor setup and release pipelines: [CONTRIBUTING.md](CONTRIBUTING.md) and `.github/workflows/`. Maintainers keep personal working preferences in a gitignored `CLAUDE.local.md`.

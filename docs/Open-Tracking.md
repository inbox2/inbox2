# Open Tracking

Email **open tracking**: a per-domain (MX) / per-channel (local) opt-in that injects a
1×1 tracking pixel into every outgoing HTML message and records each recipient render —
time, IP, coarse location, device/client, and whether the hit was a real human open or a
mail-provider proxy/prefetch. Works across **all three send paths**: inbox2-hosted (MX)
domains, external channels (Gmail/Office365/IMAP) on the desktop/mobile core, and
customer-configured ESPs. Surfaced in every client (web, desktop, iOS, Android).

## The one hard architectural fact

A recipient's mail client fetches the pixel from the public internet — a client-side
SQLite store can't receive that HTTP hit. So **open collection is always server-side**,
even for otherwise-serverless local channels. This is the single deliberate deviation
from the *"local channels never touch the API"* invariant, and it is unavoidable:

- **MX**: pixel → Rails, opens stored in Postgres, served inline with the message.
- **Local channels**: the client injects the pixel at send (send stays local), the
  recipient hits the **same Rails pixel endpoint**, and the client **polls read-only** for
  opens with the secrets behind its tokens. The secret is the capability, so the poll needs
  no account (iOS has no Rails JWT). Opens read back **only on the device that sent the
  mail** (decided 2026-11-09): the secret never leaves it.

## Token & correlation

Every tracked send embeds `https://<host>/o/<token>.gif`. On a local channel the device
makes a random secret and the token is the first 24 characters of its SHA-256 in unpadded
URL-safe base64 (`tracking::token_for_secret`, `Tracking.token_for`; the secret sits in
`tracked_token_secrets`). A recipient holds only the token, so they can't read the other
recipients' opens. `POST tracking/opens` takes `secrets`, and `tokens` for local pixels from
before this (22 characters, no organization); a hosted message's opens are never served
there. Registering or verifying a custom tracking host needs a signed-in account. Correlation
back to a message:

- **MX**: `messages.tracking_token` column; the pixel controller resolves the org via it.
- **Local**: the token lives in the sent message's own `body_html` (it *is* the pixel), so
  a message row correlates to its opens by extracting the token back out of its body — no
  fragile Message-ID mapping (Gmail rewrites Message-ID).

Opens are stored keyed on the raw `token` string in **one** table per store
(`message_opens`), so both modes share the same shape.

## Tracking host & custom domains

Two options, per domain (MX) or per channel (local):

1. **inbox2 default host** — pixel served from `visit.inbox2.com` (`INBOX2_TRACKING_HOST`, else
   `visit.<INBOX2_MAIL_DOMAIN>`). For local channels the default is derived from the API base
   host so the pixel lands on the same Rails app the client polls. No customer DNS.
2. **Custom domain** (e.g. `track.tuli.com`, recommended as a subdomain of the sending
   domain) — the customer adds one **DNS-only CNAME** to the inbox2 tracking host. TLS for
   the custom hostname is terminated via **Cloudflare-for-SaaS custom hostnames**
   (`CloudflareCustomHostname`, platform token + `CLOUDFLARE_TRACKING_ZONE_ID`). When that
   env is unset the default host still works; only custom-host TLS is unavailable.

### The Cloudflare grey-cloud rule (the verna gotcha)

verna's `CLAUDE.md:259` says Cloudflare records "should be proxied (orange cloud)". For a
*tracking* CNAME the **opposite** is required. A proxied (orange) record resolves to
Cloudflare's edge IPs instead of following the CNAME to us, so:

- CF-for-SaaS can't validate the custom hostname (error 1014 CNAME cross-user banned), and
- the edge caches the 1×1 pixel → inflated/one-shot opens and no per-open IP.

`TrackingDns` detects this: if the CNAME doesn't resolve to us but the host's A records sit
inside Cloudflare's published ranges, it flags the record as proxied and tells the user to
switch it to **DNS-only (grey cloud)**.

## Proxy / prefetch handling

Apple Mail Privacy Protection prefetches the pixel from Apple relay IPs the instant mail
arrives; Gmail proxies it through `googleusercontent.com`. Both are recorded but **flagged**
(`proxied` + `proxy_kind`) and **excluded from the "real open" count**, so numbers stay
honest. Detection today is UA-substring based (`GoogleImageProxy`, …) plus a missing-UA
heuristic; the upgrade path (Apple egress-IP ranges) is noted in `Tracking::PROXY_UA_MARKERS`.
Real client IP is read across proxy forwards: `CF-Connecting-IP` first (authoritative behind
Cloudflare), then the leftmost `X-Forwarded-For` hop. Coarse geo is resolved lazily out of
the pixel request path (`ResolveOpenGeoJob`, cached ip-api lookup).

## Where it lives

**Rails (`api/`)**
- `app/services/tracking.rb` — host/URL/tag, idempotent inject, proxy classification.
- `app/controllers/pixel_controller.rb` + route `GET /o/:token.gif` (public, no-store GIF).
- `app/models/message_open.rb`, `messages.tracking_token`, `domains.open_tracking_enabled`
  / `tracking_domain` / `tracking_domain_verified_at` / `tracking_cf_hostname_id`.
- `app/services/outbound_mail_publisher.rb` — injects on the MX send funnel (plaintext +
  E2EE + ESP), gated on the sending domain.
- `app/services/tracking_dns.rb` + `cloudflare_custom_hostname.rb` — custom-host DNS verify
  + TLS provisioning. `DomainsController#tracking / update_tracking / verify_tracking`.
- `app/controllers/api/v1/tracking_controller.rb` — `POST /api/v1/tracking/opens` (the
  unauthenticated capability poll for local channels).
- Serializers: `MessageSerializer` (`tracked`/`open_stats`/`opens`), `MessageOpenSerializer`,
  `DomainSerializer` (`open_tracking_enabled`/`tracking_domain`/`tracking_verified`).

**Rust core (`ui/desktop/core/`)**
- `src/sync/tracking.rs` — pure helpers (token, inject, extract, pixel base).
- `src/sync/engine/tracking.rs` — `maybe_inject_tracking_pixel` (hung off `enqueue_send`),
  `poll_tracking_opens` (runtime loop), `message_opens`.
- `src/sync/store/tracking.rs` — per-account settings + `tracked_tokens` + `message_opens`.
- FFI: `set_open_tracking` / `open_tracking_settings_json` / `message_opens_json`.

**Clients**
- Web/desktop: console `TrackingPanel` (per-domain), `AccountTracking` (per-channel, Tauri),
  `OpenTrackingBadge` (reading-pane indicator + history). Tauri commands `set_open_tracking`
  / `get_open_tracking` / `get_message_opens`.
- iOS/Android: per-channel toggle + open-history view over the shared FFI.

## Link tracking (the click shortener)

A sibling per-domain opt-in (`domains.link_tracking_enabled`, MX only for now).
When on, `OutboundMailPublisher` rewrites every trackable `<a href>` in the
outgoing HTML to `https://<track-host>/l/<token>`; the click hits `LinkController`,
which records a `LinkClick` (real IP via `CF-Connecting-IP`, UA, lazy geo,
security-scanner flag) then **302s to the original URL**. It shares the message's
`tracking_token`:

- `TrackedLink` — one row per unique URL per message (`token → url`, grouped by
  `message_tracking_token`); repeated URLs and recompose/retry reuse one row so
  clicks aggregate per link. `Tracking.rewrite_links` does the HTML surgery
  (dedupes, HTML-unescapes the target, skips `mailto:`/anchors/our own hosts).
- `LinkClick` — keyed on the link token, `.real` scope excludes bots. Email
  security scanners that prefetch links at delivery (Microsoft SafeLinks,
  Proofpoint URLDefense, Mimecast, Barracuda) are flagged via
  `Tracking.classify_click_bot` and excluded from the click count — the link
  analog of the pixel's proxy/prefetch handling.
- `GET /l/:token` is a **capability** and never an open redirect: an unknown
  token 404s, and it only ever redirects to a URL we ourselves stored at compose
  time (validated `http(s)` scheme).
- `MessageSerializer` adds `link_stats` + `links` (per-link click history); the
  web reading pane shows a `LinkClicksBadge` next to the open indicator.

Open + link tracking are independent toggles on the same console **Email
tracking** panel and share one custom tracking host + `messages.tracking_token`.

## Deployment / DNS

**Default host — one inbox2-side record, no customer DNS.** The pixel + link
redirect are served by Rails at the app root (`/o/...`, `/l/...`), so the host
just needs to reach the API origin:

- `visit.inbox2.com` — a **proxied** record → the api origin (a route domain of
  the Pushleft `api` role in `.pl.yaml`; on Rancher it was `168.119.64.32`),
  **added manually in the Cloudflare dashboard**, not in the Terraform DNS root
  (like `mail.inbox2.com`). Proxied is deliberate — the opposite of the
  customer-side rule: Cloudflare terminates TLS at the edge (the origin has no cert
  for this name) **and** passes the real client IP via `CF-Connecting-IP`, which
  the pixel/link controllers read. The `/o/` + `/l/` endpoints send
  `Cache-Control: no-store`, so the edge never caches them and every render/click
  is counted. This is the MX default pixel host + the CNAME target custom hosts
  point at; until it exists, MX default-host tracking won't resolve.
- `api.inbox2.com` already resolves/serves, so the **local-channel** default host
  (derived from the API base) needs nothing new — local tracking works today.

**No SPF/DKIM/DMARC changes** are needed for tracking — the pixel/link are plain
HTTP(S) fetches, not authenticated mail. A same-domain `track.` subdomain helps
*spam scoring* but isn't an auth record.

**Custom hosts** (`track.tuli.com`) live on the customer's zone (we can't manage
them). They add one DNS-only CNAME → `visit.inbox2.com`; the app auto-provisions
the TLS via Cloudflare-for-SaaS (`CloudflareCustomHostname`, needs
`CLOUDFLARE_TRACKING_ZONE_ID` + a token with SSL/custom-hostname edit set on the
API). wrangler is not involved — it has no DNS-record command.

## Testing

- `api/spec/requests/pixel_spec.rb` — pixel records/dedup/proxy-flag/CF-IP/unknown-token.
- `api/spec/services/open_tracking_injection_spec.rb` — MX injection + serialization + poll.
- `api/spec/services/tracking_dns_spec.rb` — CNAME verify, Cloudflare orange-cloud detection,
  settings endpoints.
- `ui/desktop/core` unit tests in `src/sync/tracking.rs` — inject/extract/base.

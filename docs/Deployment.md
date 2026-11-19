# Deployment

How inbox2 gets to the cloud. There is **one environment: production.** Since
November 2026 it runs on **Pushleft** (our own platform, `~/Development/pushleft`,
migration in its `docs/robot-migration-plan.md`, phase 3). The Rancher "empire"
cluster (`rancher.erip.me`) is **dead**: no kubectl, no kubeconfig, no Terraform
apply against it; its Terraform moved to the private inbox2/internal repo when
this one went public (2026-11-20). GitHub Actions deploys every push to `main`
with `pl up --production` and publishes the web app to Cloudflare Pages.

## Topology

| Thing | Value |
|---|---|
| Platform | Pushleft production, project `inbox2`, region `fsn1` (`.pl.yaml` at the repo root) |
| Image | one image for every role, `deploy/pushleft/Dockerfile`, built and scanned by Pushleft |
| Database | Pushleft managed PostgreSQL, database `inbox2` (`data.postgres` in `.pl.yaml`) |
| Public API host | `https://api.inbox2.com` + `visit.inbox2.com` (the `api` role's route, Cloudflare-proxied) |
| Mail host | `mx.inbox2.com` = failover IP `138.201.227.97` (PTR `mx.inbox2.com`), TCP 25 → the `mail` role |
| Public web host | `https://mail.inbox2.com` (Cloudflare Pages — see below) |
| Git remote / CI | github.com/inbox2/inbox2 (public), GitHub Actions (`.github/workflows/`) |

Roles in `.pl.yaml` (each runs its command through `deploy/pushleft/run`, which
exports secrets from `/run/secrets/*` and maps Pushleft's `PG*` and
`PUSHLEFT_ROLE_<ROLE>_HOST` variables onto inbox2's own names):

| Role | Kind | Command | Notes |
|---|---|---|---|
| `release` | release | create Solid schemas, `rails db:prepare` | runs before each rollout: **migrations run here** |
| `api` | web | `puma` | port 4000, `/up`, no volume, so deploys roll with no downtime; desktop releases are in a Pushleft bucket (docs/Desktop-Release.md) |
| `worker` | worker | `rake solid_queue:start` | background jobs + recurring schedule |
| `nats-subscriber` | worker | `ruby lib/nats_subscriber.rb` | inbound-mail consumer + MX domain-lookup responder |
| `nats` | private | `nats-server --js` | JetStream on a 20 GiB volume (the streams reserve ~12.3 GB) |
| `rspamd` | private | `inbox2-rspamd` (unbound + `rspamd -f`) | spam scoring; bayes on the managed Valkey, DNS through its own unbound (Spamhaus/DNSWL refuse shared resolvers) |
| `mail` | worker | `mx` + `smtp` | inbound SMTP (public 25 → 2525) and the outbound sender, from `138.201.227.97` |

Roles reach each other by private name (`<role>.inbox2.internal`). Mail
attachments live in a Pushleft bucket (`pl storage`, `S3_*` env; the garage
role was dropped 2026-11-17). Disk files live in Cloudflare R2 (`DISK_S3_*`).

## CI auto-deploy

> **Every push to `main` deploys prod.** There is no path filter — even a
> docs-only commit on `main` redeploys. A push is the deploy.

`.github/workflows/deploy.yml`:

1. **pushleft** — downloads a pinned, checksummed `pl` and runs
   `pl up --production`. Pushleft uploads the checkout (minus `.plignore`),
   builds `deploy/pushleft/Dockerfile`, scans the image (production is gated on
   fixable criticals), runs the `release` role, then rolls every role. A
   concurrency group keeps one production rollout at a time.
2. **web** / **website** — the web app and marketing site to Cloudflare Pages
   (see Frontend below); the website only when `website/` changed.

The other workflows: `ci.yml` (tests on every push and PR), `desktop.yml`
(desktop release on every push, docs/Desktop-Release.md), `ios.yml` (TestFlight),
`android.yml` (Firebase App Distribution), `cli-release.yml`. Source scanning is
Pushleft's (`SECURITY.md`, "Automated scanning").

Repository secrets (Settings → Secrets and variables → Actions):

| Variable | Content |
|---|---|
| `PUSHLEFT_TOKEN` | member service token of the Pushleft production organization (masked, protected) |
| `CLOUDFLARE_API_TOKEN` | token with **Pages:Edit** on the inbox2 account (Pages deploy) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account id owning the Pages projects |
| `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | desktop updater key |
| `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID Application identity (.p12, base64) |
| `IOS_SIGNING_P12`, `IOS_SIGNING_P12_PASSWORD` | Apple Development + Distribution identities (.p12, base64) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (notarization, provisioning, TestFlight upload) |
| `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD` | Android upload key (alias `upload`) |
| `FIREBASE_SERVICE_ACCOUNT_JSON`, `FIREBASE_ANDROID_APP_ID` | Firebase App Distribution |

### No demo data in prod

1. The `release` role runs `db:prepare` only — create + migrate, **never seed**.
2. `api/db/seeds.rb` seeds Plan config and then **stops** when
   `RAILS_ENV=production`, unless `ALLOW_DEMO_SEED=1`.

Do not run `db:seed` against prod.

## Operating prod (`pl`)

`pl login` once (personal token; `pl exec`, `pl cp` and `pl tunnel` need the
Admin role). From the repo root:

```sh
pl logs --production                                  # service logs, last day
pl logs --production --role api --since 2026-11-16T06:30:00Z --until 2026-11-16T06:41:00Z  # a time window
pl storage ls|cp|rm <bucket>[:<key>] --production     # files in a bucket (desktop releases)
pl exec api --production -- bin/rails console
pl exec api --production                               # a shell
pl cp ./file api:/rails/tmp --production               # copy into a running role
pl db connect <database id>                            # psql to the managed database
pl secrets set NAME --production < file                # a secret (write-only)
pl volume ...                                          # volume usage / resize
pl up --production                                     # what CI runs
```

Restarting after an out-of-band `ALTER` (Rails caches the column list per
process): redeploy with `pl up --production` (or push to `main`).

Config: plain env lives in `.pl.yaml` (`env:` and per-role `env:`); secrets are
listed per role under `secrets:` and set with `pl secrets set`. A change to
either ships with the next `pl up`.

## Frontend — Cloudflare Pages (`mail.inbox2.com`)

The web app (`ui/web`) is a static SPA (Vite + React, no SSR), served by
**Cloudflare Pages**, not Pushleft. Auth is token-based (no cookies), so it
talks to the API **cross-origin** (`mail.inbox2.com` → `api.inbox2.com`) cleanly.

- **Build:** `yarn install --ignore-scripts && yarn build:pages`, output `dist`,
  `NODE_VERSION=22`. `build:pages` = `vite build --mode pages`, loading
  `ui/web/.env.pages` (`VITE_API_ORIGIN=https://api.inbox2.com`). `--ignore-scripts`
  sidesteps the known `sharp` postinstall failure. The default `yarn build` (Tauri
  desktop bundle) is unchanged and stays same-origin.
- **Cross-origin wiring:** `ui/web/src/lib/apiOrigin.js` centralizes the origin;
  `api.js` / `oauthProvider.js` / `cable.js` read it. When `VITE_API_ORIGIN` is
  unset (dev / desktop) requests stay relative (`/api/v1`, `${host}/cable`).
- **API side (`.pl.yaml` `env:`):** `FRONTEND_URL` (CORS), `CABLE_ALLOWED_ORIGINS`
  (ActionCable `wss://api.inbox2.com/cable`), `WEBAUTHN_ORIGIN` include
  `https://mail.inbox2.com`.
- **SPA routing:** `ui/web/public/_redirects` (`/*  /index.html  200`).
- No client-side AI runs on the web (Tauri-only), so no COOP/COEP headers needed.

**Deploy is via CI** (`deploy_pages` on `main`): `yarn build:pages` then
`wrangler pages deploy dist --project-name=inbox2`. Wrangler creates the
project on first run.

> **One-time, in the Cloudflare dashboard/API:** attach the custom domain
> `mail.inbox2.com` to the `inbox2` Pages project (Wrangler deploys content but
> doesn't bind the domain). After that, every push to `main` redeploys the web app.

## Secrets policy

The repo is headed for open source — **no credentials in git, ever**.

| Secret | Lives at |
|---|---|
| App secrets (master key, OAuth, APNs/FCM, DKIM, S3/R2 keys, Web Bot Auth, …) | Pushleft secrets of production (`pl secrets set`), listed in `.pl.yaml` |
| CI tokens and signing keys | GitHub Actions repository secrets (table above) |
| Cloudflare API token | the CI secret + `deploy/dns/.envrc` in the private inbox2/internal repo |
| Rails master key | `api/config/master.key` (gitignored, Rails default) |
| Dev OAuth / push secrets | `api/.env` (gitignored, never tracked) |

Pushleft secret values are write-only: nothing prints one back, so keep the
source files local.

## DNS

`deploy/dns` (Cloudflare Terraform, token in `deploy/dns/.envrc`) manages the
inbox2.com service records: `mx.inbox2.com` (DNS-only A → `138.201.227.97`, the
`mail` role; the MX record names the hostname, never an address), `_spf`
(`v=spf1 ip4:138.201.227.97 ~all`), DKIM, DMARC and the SES records.

Not managed there, on purpose: `api.inbox2.com` and `visit.inbox2.com` are
Pushleft route domains (`pl domain list` shows "DNS: pushleft applied"), so
Pushleft owns their proxied records through its Cloudflare connection;
`mail.inbox2.com` is owned by the Cloudflare Pages project. Adding any of them
back to `variables.tf` would fight the owner on every apply.

`terraform apply` on 2026-11-07 dropped the dead Rancher node `168.119.64.32`
from `_spf`; state and the live records agree. The token in `deploy/dns/.envrc`
is a scoped Cloudflare account token ("inbox2 deploy/dns terraform", id
`a30d8c0d…`, DNS Write + Zone Read on inbox2.com only), minted the same day from
the account token Pushleft uses. Mint a new one the same way if it is ever lost.

## Client host configuration (which app points where)

All clients now default to **prod** (`api.inbox2.com`); all are overridable.

| Client | Default API base | Override |
|---|---|---|
| iOS (`AppConfig.swift`) | `api.inbox2.com` | UserDefaults `inbox2_cloud_api_base` |
| Android (`AppConfig.kt`) | `api.inbox2.com` | `apiBase` / build config |
| Desktop Instagram redirect (`oauth.rs`) | `api.inbox2.com` | `INBOX2_CLOUD_API_BASE` |
| admin-cli (`config.py`) | `api.inbox2.com` | `--origin` flag |
| Web app dev proxy (`vite.config.js`) | `api.inbox2.com` | `INBOX2_API_ORIGIN` env |
| Web app Pages build (`.env.pages`) | `api.inbox2.com` | Pages dashboard env var |

## Go-live constraints

Standing up the infra is not the whole story — the third-party integrations
(Google/Microsoft OAuth verification, Gmail Pub/Sub hardening, email
deliverability DNS, APNs prod tokens) have their own checklist with real lead
time. See **[Go-Live.md](Go-Live.md)** for the full production-readiness analysis
and the launch-blocker summary.

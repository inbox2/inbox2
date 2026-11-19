# Go-Live — production readiness

What it takes to move inbox2 from the single `test` environment to a real
production environment at **`api.inbox2.com`** (API) + **`mail.inbox2.com`** (web,
on Cloudflare Pages), and to get the third-party integrations out of "test mode".

Status legend: **P0** = hard blocker for any public launch · **P1** = needed for a
real (non-friends-and-family) launch · **P2** = hardening, can follow shortly after.

Each item notes where the work lives: **DNS**, **console** (Google/Microsoft/Apple/
Cloudflare dashboards), **secret**, **infra** (Terraform/k8s/CI), or **code**.

---

## 0. Infrastructure cutover — DONE in this branch

These were built alongside this document:

- **`deploy/prod/`** Terraform root — namespace `inbox2-prod`, `api.inbox2.com`,
  `mail.inbox2.com`, own data path, `enable_mx`/`enable_garage` toggles, prod
  `FRONTEND_URL`/`WEBAUTHN_ORIGIN`/`WEB_APP_URL`/`APP_URL`/`CABLE_ALLOWED_ORIGINS`.
- **DNS** — `api` (A, proxied) + `mail` (CNAME → Pages) added to `deploy/dns`.
- **Web cross-origin** — `VITE_API_ORIGIN` support (`ui/web/src/lib/apiOrigin.js`,
  wired into `api.js` / `oauthProvider.js` / `cable.js`); `--mode pages` build
  (`.env.pages`, `build:pages`, `public/_redirects`). Dev + desktop unchanged.
- **CI** — `deploy_prod` + `deploy_pages` auto on push to `main` (single env; test dropped).
- **No demo data** — `db/seeds.rb` seeds Plans only under `RAILS_ENV=production`.

### Infra status — prod is LIVE

`deploy/prod` is applied: `inbox2-prod` namespace running (api ×2, worker,
nats-subscriber, mx, postgres, nats, garage), the `api.inbox2.com` ingress + DNS
are up, and `https://api.inbox2.com/up` returns 200. The old `inbox2-test` env was
destroyed and removed from the repo.

| # | P | Where | Action | Status |
|---|---|-------|--------|--------|
| 0.1 | P0 | infra | `deploy/prod` tfvars + `terraform apply` | ✅ done (secrets derived from the old test env) |
| 0.2 | P0 | DNS | Publish `api.inbox2.com` (+ remove dead test records) | ✅ done |
| 0.3 | P0 | console | Cloudflare Pages: app deployed to the `inbox2` project, `mail.inbox2.com` custom domain attached + CNAME added | ✅ done (CI `deploy_pages` redeploys on push to `main`) |
| 0.4 | P1 | infra | Object storage: in-cluster Garage now; switch to AWS S3 (`enable_garage=false` + `s3_*`) for durability | ⏳ optional |
| 0.5 | P1 | secret | Rotate to dedicated prod secrets (postgres/object-storage already fresh; OAuth/master-key currently shared with the old test env) | ⏳ see §1 |
| 0.6 | P2 | infra | Resource requests/limits once load is known (`api_replicas`=2) | ⏳ later |

---

## 1. Secrets hygiene — P0, do this first

The local `api/.env` (Google/Microsoft client secrets, `GMAIL_PUBSUB_VERIFICATION_TOKEN`,
Messy key) is a **dev-only on-disk file** — gitignored by `api/.gitignore`
(`/.env*`) and **never committed** (verified: not in the index, not in history).
So there's no git-history scrub to do for it; the planned move to GitHub with a
fresh history additionally drops any other historical on-disk artifacts.

The real action is **don't reuse dev/test secrets in prod**:

- **1.1 (P0, secret):** Treat the dev OAuth client secrets as compromised-by-
  exposure if they've ever been shared, and use production OAuth apps' own
  credentials for prod (set in `deploy/prod/terraform.tfvars` → k8s Secret, not
  in any `.env`).
- **1.2 (P0, secret):** Generate a **separate** prod secret set: new
  `postgres_password`, prod `RAILS_MASTER_KEY`, new Garage/S3 keys, new
  `WEB_BOT_AUTH_KEY` (`rake web_bot_auth:generate_key`), new DKIM key
  (`rake dkim:generate`). Prod and test must not share secrets.

---

## 2. Google OAuth — leaving "Testing" mode — P0

The Gmail adapter requests **restricted/sensitive** scopes
(`api/app/controllers/api/v1/google_oauth_proxy_controller.rb`):

```
gmail.modify   ← restricted
calendar       ← sensitive
contacts.readonly, email, profile
```

While the OAuth consent screen is in **Testing**, only the ≤100 explicitly-added
test users can connect, and refresh tokens expire after 7 days. To serve real
users you must publish + verify:

- **2.1 (P0, console):** In Google Cloud Console → OAuth consent screen: complete
  branding (app name, logo, **the `mail.inbox2.com` homepage**, privacy-policy +
  terms URLs), add authorized domains (`inbox2.com`), then **Publish** and submit
  for **OAuth verification**.
- **2.2 (P0, console):** Because `gmail.modify` is *restricted*, Google requires an
  annual **CASA (Cloud Application Security Assessment)** by a third-party
  assessor. This has lead time (weeks) and recurring cost — **start early**.
- **2.3 (P1, console/code):** Confirm the OAuth client is a **Desktop/Installed
  app** type — the redirect allow-list is loopback only
  (`http://localhost:<port>/oauth-callback`, `127.0.0.1`) in
  `oauth_proxy_controller.rb`, plus the mobile deep link `inbox2://oauth-callback`.
  No HTTPS web redirect is used for Gmail/MS, so no redirect URI registration is
  needed beyond confirming the client type.
- **2.4 (P1):** Verify the production GCP project. The client ID's project number
  `336750114074` maps to project `inbox2-497321` (also used for Gmail Pub/Sub +
  FCM). Decide whether prod uses this project or a clean one, and keep Pub/Sub +
  FCM in the same project as the OAuth client.

> Scope reduction lowers the verification burden. If full Gmail write isn't needed
> day one, `gmail.modify` → `gmail.readonly`/`gmail.labels` would drop you out of
> the *restricted* tier (no CASA). Product decision — flag before submitting.

---

## 3. Microsoft / Office 365 OAuth — P1

The Microsoft app is multi-tenant + personal accounts (`/common/`) with scopes
`Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.Read User.Read offline_access openid`
(`microsoft_oauth_proxy_controller.rb`). It's registered as a **confidential
client** (a client secret is used).

- **3.1 (P1, console):** Complete **Microsoft Publisher Verification** (MPN) on the
  Azure app registration. Without it, multi-tenant consent shows the "unverified"
  warning and some tenants' admin-consent policies will block sign-in.
- **3.2 (P1, console):** Fill the app registration's publisher domain, privacy/ToS
  URLs, and logo to match `inbox2.com`.
- **3.3 (P1, secret):** The Microsoft client secret expires (max 24 months). Track
  its expiry and rotate; a confidential-client secret expiry silently breaks all
  Office365 reconnects.
- **3.4 (P2):** Decide whether to keep personal Microsoft accounts (`/common/`) or
  restrict to organizational (`/organizations/`); affects the consent experience.

---

## 4. Cloud push (Gmail Pub/Sub + Microsoft Graph) — P1

Realtime delivery for local Gmail/Office365 channels. The webhook base is now
`https://api.inbox2.com` in prod (`PUSH_WEBHOOK_BASE_URL`).

- **4.1 (P1, console/infra):** Gmail one-time GCP setup — create the Pub/Sub topic
  and a **push subscription** delivering to
  `https://api.inbox2.com/api/v1/push/gmail?token=<verification-token>`, and grant
  `gmail-api-push@system.gserviceaccount.com` publish rights on the topic. Set
  `GMAIL_PUBSUB_TOPIC` + `GMAIL_PUBSUB_VERIFICATION_TOKEN`. (TODO 45.6 wants this
  in Terraform.)
  - **Gotcha (test→prod host swap):** the push-subscription endpoint is GCP infra,
    **not** in the repo or Terraform, so a `PUSH_WEBHOOK_BASE_URL` change does **not**
    update it. The prod cutover left subscription `gmail-push-to-rails` (project
    `inbox2-497321`, topic `gmail-push`) still pointing at the destroyed
    `https://test-api.inbox2.com/...`, so Gmail webhooks POSTed into the void —
    `users.watch` still succeeds, subs look `active`, but `last_notification_at`
    stays empty and **no `/api/v1/push/gmail` hits ever reach prod**. Fix /
    re-verify with:
    ```sh
    gcloud pubsub subscriptions list --project=inbox2-497321 \
      --format="table(name,topic,pushConfig.pushEndpoint)"
    gcloud pubsub subscriptions update gmail-push-to-rails --project=inbox2-497321 \
      --push-endpoint="https://api.inbox2.com/api/v1/push/gmail?token=<verification-token>"
    ```
    (Microsoft is immune — its `notificationUrl` is supplied per-subscription by the
    client from `PUSH_WEBHOOK_BASE_URL`, so it follows the host automatically.)
- **4.2 (P1, code):** `GmailPushVerifier` only checks the shared `?token=` today
  and **accepts unverified requests when the token is unset** (see its TODO). For
  prod, set the token and implement OIDC JWT verification (JWKS signature, `aud`,
  service-account `email`).
- **4.3 (P1, code):** Push gating — `User#push_enabled?` returns `true`
  unconditionally. Wire it to the paid-plan / entitlement flip before launch if
  push is a gated feature.
- **4.4 (P2):** Microsoft needs no console setup (the client supplies
  `notificationUrl`), but verify subscription renewal under the prod webhook host.

---

## 5. Email deliverability — P1 (P0 if inbound/outbound mail is a launch feature)

`docs/Mail-Deliverability.md` + `docs/MX-Inbound.md` are the deep refs. For a
production sending/receiving domain:

- **5.1 (P0 for mail, secret/DNS):** DKIM — generate the prod key
  (`rake dkim:generate`), set `DKIM_PRIVATE_KEY` on **both** the Rails API and the
  Go SMTP sender, and publish the printed TXT at `<selector>._domainkey.inbox2.com`.
  Without a key, **outbound mail sends unsigned**.
- **5.2 (P0 for mail, DNS):** Publish/confirm `_spf.inbox2.com` lists the real
  sending IPs, and that `mx.inbox2.com` resolves to the MX node.
- **5.3 (P1, infra):** Reverse DNS / **PTR** for the sending IP, plus IP warmup +
  throttling (TODO 46.11). Missing rDNS tanks deliverability to Gmail/Outlook.
- **5.4 (P1, infra):** MX receiver prod gaps — the `mx` deployment is running in
  prod (`enable_mx=true`, node `:25`), but still set `MX_TLS_CERT`/`MX_TLS_KEY`
  (no TLS yet), front port 25 with the firewall/LB, and store attachment content
  to S3/Garage (TODO 41).
- **5.5 (P2, code/infra):** Outbound **MTA-STS enforcement** (TODO 46.9),
  TLS-RPT + DMARC `rua` ingestion (46.10), MX-edge spam defense — greylisting /
  RBL / rate-limiting / Rspamd (46.13). DANE/REQUIRETLS are already enforced
  outbound.
- **5.6 (P2, DNS):** Ramp apex `inbox2.com` DMARC from `p=none` → `quarantine`/
  `reject` after reviewing aggregate reports (it carries live M365 mail today).

---

## 6. Mobile push (APNs / FCM) — P1

- **6.1 (P1, console):** APNs `PushDevice.environment` is `sandbox|production`;
  **debug builds register sandbox tokens**. App Store / TestFlight builds must
  register and target the **production** APNs gateway with the production `.p8`
  (key `YY282MH435`, team `KF53B4S5HD`). Split keys are already wired in tfvars.
- **6.2 (P1, secret):** FCM service-account JSON (`inbox2-fcm@inbox2-497321…`) set
  in prod `api_secret_env`. FCM is already e2e on Android.

---

## 7. Known config gaps to resolve — P2

- **7.1 (code):** `APP_URL` is overloaded — `saml_config.rb` uses it as the
  *frontend* SAML ACS base, while `list_unsubscribe_service.rb` uses it as the
  *API* base. They can't both be right with one value. Prod sets
  `APP_URL=https://api.inbox2.com` (so one-click unsubscribe works); SAML SSO is
  assumed not a launch feature. Split these into two env vars before enabling SSO.
- **7.2 (code, DONE):** All client default hosts now point at **prod**
  (`api.inbox2.com`): `ui/ios/AppConfig.swift`, `ui/android/AppConfig.kt`, desktop
  `oauth.rs` `DEFAULT_CLOUD_API_BASE`, `ui/admin-cli/config.py`, the Instagram
  callback string in `AddAccountModal.jsx`, and the web dev proxy
  (`ui/web/vite.config.js`) + Pages build (`.env.pages`). Ship new desktop/mobile
  builds so the flipped defaults reach devices.
- **7.3 (code):** `password_reset_service.rb` default literal is
  `https://app.inbox2.com`; prod overrides via `WEB_APP_URL=https://mail.inbox2.com`
  but consider updating the source default to avoid confusion.

---

## 8. Meta channels (WhatsApp / Messenger / Instagram) — out of scope, flagged

If/when these go live they have their own **Meta App Review + Business
Verification** path (`docs/Meta-Setup.md`) — separate from Google/Microsoft and
not required for the Gmail/Office365 launch.

---

## Launch-blocker summary (the P0s)

1. Rotate + scrub committed secrets (`api/.env`), generate a fresh prod secret set. (§1)
2. `terraform apply` prod + DNS; create the Pages project for `mail.inbox2.com`. (§0)
3. Google OAuth: publish + verify, and start the **CASA** assessment for
   `gmail.modify` (long lead time). (§2)
4. If mail is a launch feature: prod DKIM key + SPF + MX/PTR. (§5)

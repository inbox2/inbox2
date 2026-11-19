# App OAuth — brokered provider sign-in for registered applications

Let a third-party application connect a user's **Google** or **Microsoft 365**
mailbox *through inbox2*, without owning a Google Cloud project or an Azure app
registration of its own. inbox2 holds the provider client credentials (it already
does, for its own clients — `OauthProxyController`); a registered application
borrows them behind a branded consent screen and receives the resulting mailbox
tokens at a whitelisted callback.

This is **not** the same thing as [Device-Link](Device-Link.md), which mints an
inbox2 `ink_` key for a *device*. Here the credential handed over is the
**provider's** — an access + refresh token for the Gmail/Graph account the person
picked — and the calling application stores it and talks to the provider itself.

> **Building the calling application?** You want
> [App-OAuth-Integration.md](App-OAuth-Integration.md) — the public HTTP contract,
> self-contained, no inbox2 internals. This file is the inbox2 side.

**Status:** live on prod since 2026-08-20. Both providers have the callback
registered (Google via a dedicated web client, Microsoft on the existing app
registration) — see Deployment prerequisites below.

## Flow

```
App server                     Browser                inbox2 web            inbox2 API                 Provider
  │ POST auth/app-oauth/authorize (Bearer ink_…) ─────────────────────────────▶│ OauthGrant (pending)
  │ ◀── { authorize_url, flow: "oag_…" } ─────────────────────────────────────│
  │ send the user to authorize_url ──▶│                                        │
  │                                   │ GET /oauth/consent?flow= ─▶│           │
  │                                   │                            │ GET auth/app-oauth/consent ─▶│ app name/icon/provider
  │                                   │  ┌──────────────────────────────────┐  │
  │                                   │  │  [icon]  →  Google               │  │
  │                                   │  │  Acme CRM wants to connect your  │  │
  │                                   │  │  Google account                  │  │
  │                                   │  │  [ Continue ]  [ Not now ]       │  │
  │                                   │  │  Powered by inbox2               │  │
  │                                   │  └──────────────────────────────────┘  │
  │                                   │ Continue → GET auth/app-oauth/start ──▶│ 302 ──────────────▶│ consent
  │                                   │                                        │◀── ?code&state=oag_│
  │                                   │                                        │ exchange + userinfo│
  │                                   │◀── 302 https://app.example.com/cb?flow=oag_…&state=… ──────│
  │ POST auth/app-oauth/token (Bearer ink_…) { flow } ────────────────────────▶│ redeem (single use)
  │ ◀── { credential: { provider, email, access_token, refresh_token, … } } ───│
```

Two secrets, two different holders. The **flow key** (`oag_…`) travels through
browser URLs the way an OAuth `code` does — single-use, 15-minute TTL, and worth
nothing on its own. Redemption additionally requires an **inbox2 API key** whose
user is a member of the application's org, so intercepting the redirect does not
get you a mailbox. The provider tokens sit encrypted on the grant row for the few
minutes between the provider callback and redemption, and are wiped from the row
when the app reads them.

## Registering an application

Console → **Applications** (`/console/applications`, org admins/owners only):

| Field | Notes |
|---|---|
| Name | Shown on the consent screen. Unique per org; also usable as the `app` identifier. |
| Icon | PNG/JPEG/GIF/WebP under 2MB, sniffed by magic bytes (`ImageAssets`), stored in S3, streamed by a public endpoint (the consent screen has no session). |
| Callback URLs | The exact-match whitelist. One per environment (production, staging, local). `https` only, except `http` on `localhost`/`127.0.0.1`/`::1`. No fragments. |

The page shows the resulting **application ID** (`oap_…`) to copy.

## API

All paths under `/api/v1`.

### Console CRUD (org-scoped, admin)

- `GET|POST /orgs/:org_id/oauth-apps`
- `GET|PATCH|DELETE /orgs/:org_id/oauth-apps/:id`
- `POST /orgs/:org_id/oauth-apps/:id/icon` — multipart `file`
- `GET /oauth/apps/:app_id/icon` — **public**, streams the icon for the consent screen

`redirect_uris` accepts an array or a newline/comma separated string.

### The flow

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST auth/app-oauth/authorize` | inbox2 API key (write scope) | Open a flow. `app` (`oap_…` or the registered name), `provider` (`google`\|`microsoft`), `redirect_uri` (must be whitelisted), `state` (optional, echoed back). → `{ authorize_url, flow, expires_at }` |
| `GET auth/app-oauth/consent?flow=` | public | What the consent screen renders: `{ app: { name, icon_url }, provider, provider_label }` |
| `GET auth/app-oauth/start?flow=` | public | Continue → 302 to the provider |
| `GET auth/app-oauth/cancel?flow=` | public | Not now → 302 back to the app with `?error=access_denied` |
| `GET auth/app-oauth/callback` | public | The provider's redirect. Exchanges the code, then 302s to the app's `redirect_uri` with `?flow=…&state=…` (or `?error=…`) |
| `POST auth/app-oauth/token` | inbox2 API key (write scope) | Redeem once: `{ flow }` → `{ credential: { provider, email, access_token, refresh_token, expires_at, scope, state } }` |
| `POST auth/app-oauth/refresh` | inbox2 API key (write scope) | `{ provider, refresh_token }` → the provider's token JSON |

Refresh through **this** endpoint, not the per-client proxy's
`auth/google/refresh`. A refresh token minted here belongs to the *web* OAuth
client (see Deployment prerequisites); the proxy refreshes against the
installed-app client and the provider rejects the mismatch.

Failure modes the app must handle on its callback: `?error=access_denied` (the
person said no, at our consent screen or the provider's) and `?error=server_error`
(the provider rejected the code exchange).

## Backend

- **`OauthProvider`** (`app/services/oauth_provider.rb`) — the registry: endpoints,
  scopes, credentials, per-provider quirks (Google's `access_type=offline`,
  Microsoft's `response_mode=query` + scope echoed on token calls), plus
  `authorize_uri` / `exchange_code` / `refresh_tokens` / `fetch_email`. The
  pre-existing per-client proxies (`GoogleOauthProxyController`,
  `MicrosoftOauthProxyController`) now read from it too, so the provider config
  lives in exactly one place. The brokered entry points use `web_client_id` /
  `web_client_secret`, which prefer `<PROVIDER>_WEB_CLIENT_ID/_SECRET` and fall
  back to the shared client.
- **`OauthApp`** (`oap_`) — org-scoped registration + the redirect whitelist.
  `allows_redirect?` is an exact string match; prefix matching is how open
  redirects get in.
- **`OauthGrant`** (`oag_`) — one in-flight authorization: `pending` →
  `authorized` → `consumed`. `access_token`/`refresh_token` use ActiveRecord
  `encrypts`. 15-minute flow TTL, 10-minute redemption window after the provider
  answers.
- **`Api::V1::AppOauthController`** — the six endpoints above. The browser legs
  (`consent`/`start`/`cancel`/`callback`) skip authentication entirely: the person
  granting mailbox access is not necessarily an inbox2 user.
- Specs: `spec/requests/api/v1/app_oauth_spec.rb` (whitelist enforcement, unknown
  app/provider, cross-tenant, expiry, denial pass-through, exchange failure,
  single-use redemption, token wipe) and `spec/requests/api/v1/oauth_apps_spec.rb`.

## Web

- **`/oauth/consent`** (`pages/auth/AppOauthConsentPage.jsx`) — the branded
  consent screen. Outside every auth wrapper. Continue/Not now are plain
  navigations to the API (the next hop is the provider's domain, so the server
  builds it).
- **`/console/applications`** (`pages/admin/ConsoleApplications.jsx`) — register,
  edit, delete, upload the icon; shows the application ID and a short
  starting-a-flow snippet.

## Deployment prerequisites

**The callback must be registered with the providers.** Unlike every other OAuth
path in this codebase, this one redirects to an HTTPS host we control rather than
a loopback listener, so both providers need it on their allow-list:

```
https://api.inbox2.com/api/v1/auth/app-oauth/callback     # prod
http://localhost:4000/api/v1/auth/app-oauth/callback      # local API
```

Until that is done, `start` reaches the provider and the provider refuses with
`redirect_uri_mismatch` (Google) / `AADSTS50011` (Microsoft).

Both were registered on 2026-08-20; the steps below are kept for a new
environment, a rotated client, or a rebuild.

### Google

Prod uses a **separate** OAuth client for this flow — `GOOGLE_WEB_CLIENT_ID` /
`GOOGLE_WEB_CLIENT_SECRET` (client `336750114074-6s1677jg…`), because the shared
`GOOGLE_CLIENT_ID` is a desktop/installed client and Google will not put an HTTPS
redirect on one. `OauthProvider.web_client_id` prefers it and falls back to the
shared client when unset.

1. <https://console.cloud.google.com/apis/credentials>, project **`inbox2-497321`**
   (project number `336750114074` — the prefix of `GOOGLE_CLIENT_ID`).
2. Under **OAuth 2.0 Client IDs**, find the row whose client ID matches
   `GOOGLE_CLIENT_ID` and read its **Type** column. This decides everything:
   - **Web application** → open it → **Authorised redirect URIs** → *+ ADD URI*
     for each of the two URLs above → **Save**. Leave the existing entries alone.
     Changes can take a few minutes to propagate.
   - **Desktop app** → *there is no redirect-URI field, and one cannot be added.*
     Google only permits loopback + custom-scheme redirects on installed-app
     clients, and the desktop/mobile clients need that type because they bind
     ephemeral loopback ports. Create a **second** client instead:
     *+ CREATE CREDENTIALS → OAuth client ID → Application type: Web application*,
     name it `inbox2 app-oauth broker`, add the two URIs, **Create**, then copy the
     new client ID + secret into `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_WEB_CLIENT_SECRET`
     — `OauthProvider` must be taught to prefer those for the brokered flow only
     (a few lines; the per-client proxy keeps using the desktop client).
3. The consent screen must be **Published**, not in Testing — see Go-Live 2.1.
   In Testing, only listed test users can finish a flow and refresh tokens die
   after 7 days.

### Microsoft

One app registration serves both flows — Azure allows a Web platform and a
"Mobile and desktop applications" platform side by side.

1. <https://portal.azure.com> → **Microsoft Entra ID** → **App registrations** →
   **All applications** → the app whose Application (client) ID matches
   `MICROSOFT_CLIENT_ID`.
2. **Authentication** → **Platform configurations**.
   - No **Web** platform yet: *+ Add a platform* → **Web** → paste
     `https://api.inbox2.com/api/v1/auth/app-oauth/callback` → **Configure**.
   - Already a Web platform: *Add URI* under it.
3. Add `http://localhost:4000/api/v1/auth/app-oauth/callback` as a second Web URI.
   Azure permits plain `http` **only** for `localhost` — `127.0.0.1` is rejected on
   the Web platform, so use the hostname.
4. **Save**. Do not touch the existing loopback URIs under "Mobile and desktop
   applications" — the desktop/mobile clients still need them.
5. No secret change: the registration is already a confidential client and the
   brokered exchange sends `MICROSOFT_CLIENT_SECRET` the same way.

### Verifying

```sh
curl -sX POST https://api.inbox2.com/api/v1/auth/app-oauth/authorize \
  -H "Authorization: Bearer ink_…" -H 'Content-Type: application/json' \
  -d '{"app":"oap_…","provider":"google","redirect_uri":"https://…","state":"t1"}'
```

Open the returned `authorize_url`, click Continue: a `redirect_uri_mismatch` means
the URI hasn't propagated or went on the wrong client; reaching the provider's own
account picker means it's live.

Testing locally needs the web dev server pointed at the local API
(`INBOX2_API_ORIGIN=http://localhost:4000 yarn dev`) — it proxies to prod by
default, whose `WEB_APP_URL` sends the consent page to `mail.inbox2.com`.

Env: `WEB_APP_URL` (where the consent page lives) and `API_PUBLIC_URL` (icon URLs)
are already set in `deploy/prod/main.tf`. `OAUTH_APP_CALLBACK_URL` overrides the
callback when the API is reached on a different public name than Rails sees;
unset, it's derived from the serving host.

Google's verified-scope posture applies: mailboxes connected this way consent to
**inbox2's** OAuth client and its scopes, and the consent screen shown by Google
carries inbox2's name. The registered application's branding lives on our
interstitial, not Google's.

## Not built

- No per-app secret. The calling app authenticates with an ordinary inbox2 API
  key, which is what its owner already has. Add a client secret only if apps ever
  need to act without a user's key.
- No per-app scope narrowing — every flow requests the full provider scope set.
- No listing of which mailboxes an app has connected: we hand over the tokens and
  keep nothing, so there is nothing to list.

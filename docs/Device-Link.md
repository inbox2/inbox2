# Device Link

OAuth-style **"link this device to your inbox2 account"** — bind a desktop or
mobile client to an account via a browser approval instead of pasting a key or
re-typing credentials in the app. Loopback redirect + PKCE, the same shape as the
external-provider OAuth the clients already run (`OAuthService`), but pointed at
the inbox2 account.

Clients: desktop, iOS, Android and the CLI (`inbox2 login`, platform `cli`; see [CLI.md](CLI.md)).

## Why

Native clients used to authenticate cloud features by either an in-app
username/password login (which mints a **30-day `Session`** that silently expires
— the "session expired" churn that disarmed cloud push on desktop) or by pasting
a personal `ink_` API key. Linking mints a **device-scoped, non-expiring `ink_`
key** through a browser the user is already (or easily) logged into, so all
password / TOTP / OAuth / passkey logic stays on the web, and the credential is
durable + independently revocable per device.

## Flow

```
Client (desktop/iOS/Android)                         Web (mail.inbox2.com)        API (Rails)
  │  PKCE verifier+challenge, state                        │                          │
  │  bind 127.0.0.1:<port>/cb  (loopback listener)         │                          │
  │  open system browser ───────────────────────────────▶ /link?device_name&platform │
  │                                                        &redirect_uri&state        │
  │                                                        &code_challenge&method=S256 │
  │                                          user logs in (cookie) + approves          │
  │                                                        │ POST auth/device-link/    │
  │                                                        │   authorize  (cookie) ───▶│ mint pending
  │                                                        │ ◀── { code } ─────────────│ DeviceLinkRequest
  │  ◀── 302 127.0.0.1/cb?code&state ──────────────────────│                          │
  │  verify state, ack the tab                             │                          │
  │  POST auth/device-link/token { code, code_verifier, redirect_uri } ──────────────▶│ verify PKCE+
  │  ◀── { token: ink_…, api_key, user } ─────────────────────────────────────────────│ redirect, mint
  │  store as the account bearer; arm push                 │                          │ device ApiKey
```

PKCE (S256) binds the browser-delivered `code` to the client that started the
flow — a local app that intercepts the loopback redirect can't redeem the code
without the verifier, which never left the device. `state` is CSRF defense; the
`redirect_uri` is validated **loopback-only** server-side so a code can't be
exfiltrated to an arbitrary host. The code is single-use with a 5-minute TTL.

## Backend (Rails)

- **`DeviceLinkRequest`** (`dlr_`, `app/models/device_link_request.rb`) — a
  short-lived, single-use authorization code (`dlc_` raw, stored as SHA256 digest
  + indexed prefix, like `Session`/`ApiKey`). Holds the PKCE challenge, device
  name/platform, loopback `redirect_uri`, owning user, status, `expires_at`.
  `.authenticate(code)` resolves a pending/unexpired row (constant-time);
  `verifier_matches?` checks `BASE64URL(SHA256(verifier)) == code_challenge`.
- **`Api::V1::DeviceLinkController`**
  (`app/controllers/api/v1/device_link_controller.rb`):
  - `POST /api/v1/auth/device-link/authorize` — **session/cookie authed** (the web
    approval page). Mints a code for `current_user`, returns `{ code, redirect_uri }`.
  - `POST /api/v1/auth/device-link/token` — **public** (`skip authenticate_user!`).
    The holder of the PKCE verifier matching the approved challenge IS the
    authorized client. Verifies code + verifier + redirect match, mints a
    device-scoped `ApiKey` (`scopes: read+write`, `device_platform`), consumes the
    request, returns `{ token: "ink_…", api_key, user }`.
- **`ApiKey.device_platform`** distinguishes linked-device keys from
  manually-created ones; the account "Linked devices" UI keys off it. Resolution is
  unchanged — `ApplicationController#authenticate_user` already accepts an `ink_`
  key anywhere a `Session` works (incl. `ApplicationCable::Connection`).
- Specs: `spec/requests/api/v1/device_link_spec.rb` (auth, loopback guard, bad
  platform, non-S256, single-use, wrong verifier, redirect mismatch, expiry).

## Web (`ui/web`)

- **`/link`** (`pages/auth/LinkDevicePage.jsx`) — the browser approval surface. Not
  guest/protected-wrapped: it gates on auth itself and bounces signed-out users
  through `/login?next=` (or `/signup?next=`, both honor a local-only `next`). On
  approve it `POST`s `authorize` then sets `window.location` to the loopback with
  the one-time code + state.
- **`lib/deviceLink.js`** — shared helpers: PKCE param parsing, loopback-only
  redirect validation, public-origin resolution, and `startDesktopDeviceLink()`
  (hands the loopback dance to the Rust command + pushes `set_api_context`).
- **Desktop entry points** — a "Link to inbox2 account" button on `LoginPage`
  (MX-login surface) and in the setup wizard's enrichment step beside the manual
  `ink_` field (the recommended, durable path).
- **`/console/api-keys`** (`ApiKeysPage`) renders device-link keys as a **Linked
  devices** section with per-device **Unlink** (reuses the revoke path).

## Desktop (Tauri)

`start_device_link` (`src-tauri/src/sync/commands/device_link.rs`) runs the whole
loopback exchange in Rust — the system browser can't reach the webview's
custom-protocol origin. It binds an ephemeral `tiny_http` listener, opens the
browser via the opener plugin, verifies `state`, POSTs to the token endpoint, and
**adopts the minted bearer into the engine** (`set_api_context` → persists
`cloud_auth_token`, arms cloud push). Device name defaults to the hostname; 180s
deadline.

## Mobile

Each app mirrors its own external-provider `OAuthService` loopback machinery:

- **iOS** (`Sources/Cloud/DeviceLinkService.swift`) — reuses `OAuthService`'s
  `LoopbackServer`; `CloudSession.adoptLinkedToken` stores the token in Keychain
  (`tokenKey`), validates via `GET /account`, then `PushRegistrar.ensureRegistered`.
- **Android** (`cloud/DeviceLinkService.kt`) — `ServerSocket(127.0.0.1)` + Custom
  Tab; `CloudSession.adoptLinkedToken` stores `SecureStore.MX_TOKEN`, validates via
  `GET /account`, then `FcmTokenManager.ensureRegistered`.

Both add a "Link to inbox2 account" button beside the username/password fields.
Because `GET /account` accepts an `ink_` key as a bearer, adopting the minted token
signs the app in exactly like a password login.

## Protocol summary (for any new client)

1. PKCE: `code_verifier` = 64 random bytes base64url (no padding); `code_challenge`
   = base64url(SHA256(verifier)) (no padding); method `S256`. Random `state`.
2. Bind `127.0.0.1:<port>`, callback `/cb`; `redirect_uri = http://127.0.0.1:<port>/cb`.
3. Open `{web}/link?device_name&platform&redirect_uri&state&code_challenge&code_challenge_method=S256`.
4. Catch `GET /cb?code&state`, verify `state`, ack the tab.
5. `POST {api}/auth/device-link/token { code, code_verifier, redirect_uri }` (no
   auth header) → `{ token, api_key, user }`. Store `token` as the bearer.
6. ~180s deadline + listener cleanup; cancel/timeout is non-fatal.

`platform` ∈ `desktop` | `ios` | `android`. Defaults: web `https://mail.inbox2.com/link`,
api `https://api.inbox2.com/api/v1` (reuse the client's configured API base).

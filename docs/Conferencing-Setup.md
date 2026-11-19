# Conferencing setup — Google Meet & Teams link generation

Click-by-click instructions to set up the Google and Microsoft sides of
**conferencing connections** from scratch — the per-user OAuth grants that let
an accepted meeting request carry a generated Google Meet or Teams link
(docs/Calendar.md → "Meet links"). Written for a fresh deployment; if the
Google/Microsoft apps already exist (they do for inbox2 prod, shared with the
mail OAuth + App-OAuth broker), skip the creation steps and only add the
redirect URI, the API/permissions, and the scopes.

What the feature uses:

* **Scopes** (from `ConferencingConnection::SCOPES` — deliberately narrow, no
  mail/calendar access):
  * Google: `https://www.googleapis.com/auth/meetings.space.created email`
  * Microsoft: `OnlineMeetings.ReadWrite User.Read offline_access`
* **Redirect URIs** (from `ConferencingController#callback_uri`, must match
  byte-for-byte):
  * `https://api.inbox2.com/api/v1/conferencing/google/callback`
  * `https://api.inbox2.com/api/v1/conferencing/microsoft/callback`

  (Replace the host for another environment: it is the **API** origin, not the
  web app.)
* **Env vars** (Rails api pods): Google uses `GOOGLE_WEB_CLIENT_ID` /
  `GOOGLE_WEB_CLIENT_SECRET` when set, else falls back to `GOOGLE_CLIENT_ID` /
  `GOOGLE_CLIENT_SECRET`. The fallback is the desktop **installed-app** client,
  which cannot take HTTPS redirect URIs — so a real deployment needs the web
  client pair (same one the App-OAuth broker uses). Microsoft uses the single
  `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` registration for
  everything. `WEB_APP_URL` is where the callback bounces the user afterwards
  (`/:org/settings?section=scheduling&conferencing=connected|error`).

## Google, from scratch

1. **Project**: [console.cloud.google.com](https://console.cloud.google.com) →
   project picker → **New project** (or reuse the existing inbox2 project that
   owns the Gmail OAuth clients — recommended, one consent screen).
2. **Enable the API**: **APIs & Services → Library** → search **"Google Meet
   API"** → **Enable** (direct:
   `console.cloud.google.com/apis/library/meet.googleapis.com`).
3. **Consent screen** (skip if the project already has one): **Google Auth
   Platform → Branding** — app name, support email, domain; **Audience**:
   *External*. A brand-new screen starts in **Testing** mode: only listed test
   users can connect until you publish.
4. **Scopes**: **Google Auth Platform → Data Access** → **Add or remove
   scopes** → add `https://www.googleapis.com/auth/meetings.space.created`
   (and `email` if it isn't already there from the mail scopes) → **Update** →
   **Save**.
   * `meetings.space.created` is **sensitive but not restricted**: publishing
     with it triggers Google's scope-justification review (days, no CASA).
     Until approved, consent shows the unverified-scope warning but still
     works. It is *principal-scoped* — it can only create/manage Meet spaces
     the connected account itself created, which is exactly what accept does.
5. **Web OAuth client**: **APIs & Services → Credentials** (newer consoles:
   **Google Auth Platform → Clients**) → **+ Create credentials → OAuth client
   ID** → Application type **Web application** → name it (e.g. "inbox2 web
   broker"). Under **Authorized redirect URIs → Add URI** paste the Google
   redirect URI above. **Create**, then copy the client ID + secret.
   * Existing deployment: just open the client whose ID matches
     `GOOGLE_WEB_CLIENT_ID` and add the URI. The App-OAuth broker URIs already
     on it stay.
   * Changes take **5 minutes to a few hours** to propagate — an immediate
     `redirect_uri_mismatch` usually just needs waiting.
6. **Env**: set `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_WEB_CLIENT_SECRET` on the api
   deployment (secrets are Pushleft secrets, set with `pl secrets set` and listed in `.pl.yaml` — see docs/Deployment.md).

## Microsoft, from scratch

1. **App registration**: [entra.microsoft.com](https://entra.microsoft.com) →
   **Identity → Applications → App registrations** → **New registration** (or
   open the existing app matching `MICROSOFT_CLIENT_ID`). Supported account
   types: **Accounts in any organizational directory and personal Microsoft
   accounts** — the code authorizes against the `/common` endpoint.
2. **Redirect URI**: **Authentication** → if there is no **Web** platform yet,
   **+ Add a platform → Web** (additive; the desktop/mobile platform entries
   stay) → **Add URI** → paste the Microsoft redirect URI above → **Save**.
   No propagation delay.
3. **Permissions**: **API permissions → Add a permission → Microsoft Graph →
   Delegated permissions** → add **`OnlineMeetings.ReadWrite`** (plus
   `User.Read`, `offline_access`, `openid` if not already listed from the mail
   scopes). Delegated `OnlineMeetings.ReadWrite` is user-consentable — no
   admin consent needed unless a customer tenant restricts user consent (their
   admin then approves via **Grant admin consent** or on first use).
4. **Client secret** (new registrations only): **Certificates & secrets → New
   client secret**. Note the expiry — Microsoft secrets max out at 24 months
   and the connect flow dies silently when it lapses; calendar the renewal.
5. **Env**: `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` on the api
   deployment.

## Verify end to end

1. Settings › Scheduling → **Connect** under Conferencing → provider consent →
   you land back on Settings › Scheduling with the "Connected" notice and the
   account email on the card.
2. Create a meet link with **Google Meet — generated on accept** (the option
   only enables once the *invitee's* connection exists), request a slot from
   the public page in a private window, accept from the inbox banner.
3. The event's location carries a `meet.google.com/…` (or `teams.microsoft.com/…`)
   URL, the visitor's ICS invite includes it, and the provider icon shows
   everywhere via the existing `detectMeeting` path.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Provider shows `redirect_uri_mismatch` / invalid redirect | URI not registered, typo'd, or (Google) still propagating — must match `https://<api-host>/api/v1/conferencing/<provider>/callback` byte-for-byte |
| Bounced back with `?conferencing=error` right after consent | Check `kubectl logs deploy/api \| grep conferencing` — token exchange failed (wrong secret, secret expired) or the provider returned no refresh token |
| Google consent shows "unverified app" warning | The sensitive scope is pending review (or the screen is in Testing mode and the user isn't a test user) — functional either way for consented users |
| Connect works but accepts return `conference_error` | Meet API not enabled on the project; or Microsoft account is a personal MSA (`/me/onlineMeetings` is work/school only); or the connection was disconnected after the link was created |
| Teams generation stops after months of working | Rotated refresh token lost (shouldn't happen — `ConferenceLink` persists rotations) or the client secret expired — check logs, reconnect from Settings |
| Callback 500s | Should not happen (redirects carry `allow_other_host`); check api logs for the exception |

Engineering internals (state signing, encrypted token storage, generation at
accept time, failure semantics) live in docs/Calendar.md → "Meet links".

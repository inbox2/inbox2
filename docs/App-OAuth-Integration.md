# Connecting a mailbox through inbox2 — integration guide

**Audience:** an engineer (or coding agent) building the *calling* application.
You do not need access to the inbox2 codebase to follow this; everything below is
the public HTTP contract against production.

## What this gets you

Your application can ask a person to connect their **Gmail** or **Microsoft 365**
mailbox, and receive that provider's **access token + refresh token** — without
you registering a Google Cloud project, going through Google's OAuth verification,
or passing a CASA security assessment. inbox2 owns the verified OAuth clients; you
borrow them behind a consent screen that carries *your* name and icon.

After the flow you hold ordinary provider credentials. You call the Gmail API or
Microsoft Graph directly. inbox2 keeps no copy of the tokens and never sees the
mail.

**Scopes granted** (all-or-nothing today — you cannot request a subset):

| Provider | Scopes |
|---|---|
| Google | `gmail.modify`, `calendar`, `contacts.readonly`, `email`, `profile` |
| Microsoft | `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Contacts.Read`, `User.Read`, `offline_access`, `openid` |

## Before you write code

Ask the inbox2 org admin for three things:

1. **An API key** — inbox2 console → *API keys & devices* → Create a key with
   **Read & write** access. Looks like `ink_…`. It authenticates *your server*, not
   the end user. A read-only key gets `403` on every call here.
2. **A registered application** — inbox2 console → *Applications* → Register.
   They set the name and icon shown on the consent screen, and the list of
   **callback URLs** you are allowed to return to. Give them every environment you
   need up front (production, staging, local) — the match is exact, so
   `https://app.example.com/cb` will not accept `https://app.example.com/cb/`.
   `https` only, except `http` on `localhost`/`127.0.0.1`.
3. **The application ID** — shown on that page, looks like `oap_…`. The registered
   name works as an identifier too.

Base URLs (production):

```
API   https://api.inbox2.com/api/v1
Web   https://mail.inbox2.com
```

## The flow

```
 your server                    the person's browser                inbox2 / provider

 1. POST auth/app-oauth/authorize  ──────────────────────────────────▶
    ◀── { authorize_url, flow }
 2. redirect the browser to authorize_url ─▶  consent screen  ─▶ Google/Microsoft
 3.                                        ◀── back to YOUR callback:
                                               ?flow=oag_…&state=…
 4. POST auth/app-oauth/token { flow }  ─────────────────────────────▶
    ◀── { credential: { access_token, refresh_token, email, … } }
 5. store it; call Gmail / Graph yourself
```

Steps 1 and 4 are **server-to-server** and carry your API key. Never put the API
key in the browser.

### 1. Open a flow

```http
POST https://api.inbox2.com/api/v1/auth/app-oauth/authorize
Authorization: Bearer ink_…
Content-Type: application/json

{
  "app": "oap_…",
  "provider": "google",
  "redirect_uri": "https://app.example.com/oauth/inbox2/callback",
  "state": "<random, unguessable, tied to this user's session>"
}
```

`provider` is `google` or `microsoft`. `redirect_uri` must be one of the
registered callbacks, byte for byte. `state` is optional but you should always
send one — it comes back verbatim and is how you tie the return trip to the
person who started it.

```json
201 Created
{
  "flow": "oag_V1StGXR8Z5jdHi6BmyT",
  "authorize_url": "https://mail.inbox2.com/oauth/consent?flow=oag_V1StGXR8Z5jdHi6BmyT",
  "expires_at": "2026-08-20T10:15:00.000Z"
}
```

Store `flow` against the user's session (or rely on `state`), then redirect the
browser to `authorize_url`. The whole flow must finish within **15 minutes**.

### 2. What the person sees

The consent screen shows your icon, *"«Your app» wants to connect your Google
account"*, a **Continue** button, **Not now**, and a "Powered by inbox2" footer.
Continue sends them to the provider's own sign-in and consent, exactly as normal.

### 3. They come back to your callback

Success:

```
GET https://app.example.com/oauth/inbox2/callback?flow=oag_…&state=…
```

Failure:

```
?error=access_denied&state=…     the person declined (on our screen or the provider's)
?error=server_error&state=…      the provider rejected the code exchange
```

Verify `state` matches what you issued before doing anything else. The `flow`
value in the URL is **not** a credential — it is worthless without your API key —
but treat it as one-time regardless.

### 4. Redeem the credential

```http
POST https://api.inbox2.com/api/v1/auth/app-oauth/token
Authorization: Bearer ink_…
Content-Type: application/json

{ "flow": "oag_V1StGXR8Z5jdHi6BmyT" }
```

```json
200 OK
{
  "credential": {
    "provider": "google",
    "email": "person@gmail.com",
    "access_token": "ya29.…",
    "refresh_token": "1//…",
    "expires_at": "2026-08-20T11:00:00.000Z",
    "scope": "https://www.googleapis.com/auth/gmail.modify …",
    "state": "<your state, echoed>"
  }
}
```

**Single use.** The tokens are wiped from inbox2 the moment you read them — a
second call returns `400`. Persist them before you do anything else. You have
**10 minutes** from the provider callback to redeem.

`email` is which mailbox they actually picked, which is not necessarily the
account you expected — use it, don't assume.

### 5. Refresh

Access tokens last about an hour.

```http
POST https://api.inbox2.com/api/v1/auth/app-oauth/refresh
Authorization: Bearer ink_…
Content-Type: application/json

{ "provider": "google", "refresh_token": "1//…" }
```

The provider's own token response comes back verbatim (`access_token`,
`expires_in`, `token_type`, …).

Use **this** endpoint. Refreshing directly against Google/Microsoft will fail —
you don't have the client secret, and it isn't yours to have.

> **Microsoft rotates refresh tokens.** Its refresh response contains a *new*
> `refresh_token`; store it, replacing the old one, or the next refresh fails.
> Google's response has no `refresh_token` — keep the original.

A `400` here means the provider rejected the grant: the person revoked access, or
changed their password. Treat it as "this mailbox needs reconnecting" and send
them through the flow again — do not retry.

### 6. Use the tokens

Ordinary provider APIs, `Authorization: Bearer <access_token>`:

- Google → `https://gmail.googleapis.com/gmail/v1/users/me/…`, `https://www.googleapis.com/calendar/v3/…`
- Microsoft → `https://graph.microsoft.com/v1.0/me/…`

## Worked example (Express)

```js
const API = 'https://api.inbox2.com/api/v1';
const KEY = process.env.INBOX2_API_KEY;          // ink_…
const APP = process.env.INBOX2_APP_ID;           // oap_…
const CB  = 'https://app.example.com/oauth/inbox2/callback';

const call = (path, body) =>
  fetch(`${API}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }).then(async (r) => {
    const json = await r.json();
    if (!r.ok) throw new Error(json.errors?.[0]?.message || `inbox2 ${r.status}`);
    return json;
  });

// Start: send the person to inbox2.
app.get('/connect/:provider', async (req, res) => {
  const state = crypto.randomBytes(32).toString('hex');
  req.session.oauthState = state;
  const { authorize_url } = await call('/auth/app-oauth/authorize', {
    app: APP, provider: req.params.provider, redirect_uri: CB, state,
  });
  res.redirect(authorize_url);
});

// Return: verify state, redeem once, store.
app.get('/oauth/inbox2/callback', async (req, res) => {
  const { flow, state, error } = req.query;
  if (state !== req.session.oauthState) return res.status(400).send('State mismatch');
  delete req.session.oauthState;
  if (error) return res.redirect(`/settings?connect=${error}`);

  const { credential } = await call('/auth/app-oauth/token', { flow });
  await db.mailboxes.upsert({
    userId: req.session.userId,
    provider: credential.provider,
    email: credential.email,
    accessToken: encrypt(credential.access_token),
    refreshToken: encrypt(credential.refresh_token),
    expiresAt: credential.expires_at,
  });
  res.redirect('/settings?connect=ok');
});
```

## Storing what you receive

You are now holding live credentials to someone's mailbox. Treat them as such:

- Encrypt both tokens at rest. A refresh token does not expire on its own.
- Never log them, never put them in a URL, never send them to the browser.
- Give the person a way to disconnect, and drop your copy when they do. (Revoking
  at the provider is separate — Google: myaccount.google.com/permissions.)
- The inbox2 API key is equally sensitive: anyone holding it can start flows in
  your application's name. Rotate it from the console if it leaks.

## Errors

All errors share one shape:

```json
{ "errors": [{ "message": "…" }], "status": 404 }
```

| Where | Code | Meaning | Fix |
|---|---|---|---|
| any | `401` | Missing/invalid API key | Check the `Authorization: Bearer ink_…` header |
| any | `403` | Key is read-only | Reissue with **Read & write** |
| authorize | `404` | Unknown application | Wrong `app`, or the key belongs to a different org |
| authorize | `422` | `redirect_uri is not registered` | Exact-match failure — trailing slash, http vs https, wrong port |
| authorize | `422` | `Unsupported provider` | Only `google` and `microsoft` |
| authorize | `400` | Missing parameter | `app`, `provider`, `redirect_uri` are all required |
| consent page | `404` | "This link has expired" | Over 15 minutes, or already used — restart |
| token | `404` | Unknown authorization | Wrong `flow`, or a key from a different org |
| token | `400` | "not ready or has already been used" | Redeemed twice, redeemed before the provider answered, or past the 10-minute window |
| refresh | `400` | Provider rejected | Access revoked or password changed — reconnect |
| callback | `?error=access_denied` | The person declined | Not an error; show a friendly state |
| callback | `?error=server_error` | Provider rejected the code exchange | Retry the flow; if it persists, tell the inbox2 admin |

## Limits and things not offered

- One flow = one mailbox. To connect several, run it once per mailbox.
- Scopes are fixed; you cannot request a narrower set.
- No webhooks — inbox2 does not notify you of anything after redemption.
- No listing of previously connected mailboxes. inbox2 keeps nothing after you
  redeem, so it has nothing to list; track them on your side.
- Flow: 15 minutes end to end. Redemption: 10 minutes after the provider answers.
  Single use.

---

inbox2-side internals (data model, controllers, provider registration) live in
[App-OAuth.md](App-OAuth.md) — you don't need it to integrate.

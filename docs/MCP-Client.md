# MCP Client — inbox2 as a client of remote MCP servers

inbox2 can send a Lore item to another app (Linear, GitHub, Jira, Notion, HubSpot, …) through that
app's hosted MCP server. This is the handoff in [plans/lore.md §5](plans/lore.md): the client is in
the Rust core, it only makes drafts, and the person presses **Create**.

This doc is about the **client**. inbox2's own MCP **server** (agents reading your mail) is in
[Vector-MCP.md](Vector-MCP.md).

## Architecture

```
SendToDialog.jsx / McpConnectionsSettings.jsx   (ui/web, desktop only)
        │  invoke('mcp_*')            lib/mcpClient.js — IPC + argument builders
        ▼
src-tauri/src/mcp_client.rs        Tauri commands; loopback listener + browser (sign-in only)
        │
        ▼
core/src/mcp_client/
  mod.rs    connections, encrypted credentials, presets, list_tools / call_tool,
            refresh-and-retry, status
  rpc.rs    Streamable HTTP JSON-RPC session (initialize, Mcp-Session-Id, SSE responses)
  oauth.rs  discovery → dynamic client registration → PKCE authorize URL → code exchange → refresh
```

The core has no Tauri code, so iOS/Android can use it through UniFFI later. The host owns only the
part that needs a UI: binding the loopback port, opening the browser, and waiting for the code.
On desktop, the waiting reuses `wait_for_callback` / `open_in_browser` from
`src-tauri/src/sync/commands/device_link.rs`.

### Transport

Streamable HTTP: each JSON-RPC message is one `POST` with
`Accept: application/json, text/event-stream`. The answer is plain JSON, or an SSE stream that the
client reads until the event with the matching `id` arrives. Notifications in the stream before it
are skipped. The `Mcp-Session-Id` from `initialize` is sent back on every later request, together
with `MCP-Protocol-Version`.

- We offer protocol `2025-06-18` in `initialize`. Hosted servers answer with that version or an
  older one.
- Every operation opens a new session (`initialize` → `notifications/initialized` → the request).
  That is three round trips. These calls only happen when a person clicks, and a new session never
  runs into an expired one.
- **Not implemented:** the 2024-11-05 HTTP+SSE transport (a `GET` stream plus an `endpoint` event).
  Every preset uses Streamable HTTP. Add it when someone brings a server that has only `/sse`.
- **Not implemented:** the 2026-07-28 stateless era, where requests carry `_meta` and there is no
  `initialize`. Servers of that era still accept the handshake (our own server does, see
  Vector-MCP.md).

### Storage (no new table)

| What | Where |
|------|-------|
| Connection list `[{id, name, url, auth, status, error}]` | `engine_settings` key `mcp_client_connections` (JSON) |
| Token / OAuth state per connection | `app_secrets` row `mcp_client:<id>`, AES-256-GCM with the device credential key (`SyncStore::store_app_secret`, the same store as the Rails token) |

The stored credential holds `access_token`, `refresh_token`, `expires_at`, `token_endpoint`,
`client_id`, `client_secret`, `resource` and `registered_client`. Removing a connection deletes both
rows. The settings JSON never holds a token (a unit test checks this).

`status` is written after each operation: `connected` when a request succeeds, `needs_auth` after a
401 that a refresh could not fix, and `error` after a transport failure. A JSON-RPC error, such as
bad tool arguments, does not change the status.

## OAuth flow

1. With no token, `mcp_add_connection` sends a request without authentication. A 401 starts sign-in.
   The `WWW-Authenticate` header gives `resource_metadata` and `scope`.
2. **Protected-resource metadata** (RFC 9728): first the URL from the header. If there is none,
   `/.well-known/oauth-protected-resource<path>`, then the same path at the root. The metadata gives
   `authorization_servers[0]` and `resource`. If there is no metadata, the server's origin is the
   authorization server and the server URL is the resource.
3. **Authorization-server metadata**: `/.well-known/oauth-authorization-server<path>`, then
   `openid-configuration` (inserted into the path and added to the end of it). If there is none, the
   2025-03-26 defaults apply: `/authorize`, `/token` and `/register` at the origin.
4. **Dynamic client registration** (RFC 7591) as a public client (`token_endpoint_auth_method:
   none`) with the loopback redirect URI. If the server has no `registration_endpoint`, the person
   must give an access token or the client ID (and secret) of an OAuth app they made there.
5. **Authorize** with PKCE S256, `state`, `resource` (RFC 8707) and `scope`. The scope comes from
   the 401, or else from the metadata's `scopes_supported`. The browser comes back to
   `http://127.0.0.1:<ephemeral>/cb`. The listener checks `state` and times out after 300 s.
6. **Exchange** the code. **Refresh** before expiry, or once after a 401. If the provider sends a new
   refresh token, it replaces the old one; if it sends none, the old one stays.
7. **Sign in again** registers a new dynamic client every time (the loopback port changes, and a
   registered client is tied to its redirect URI). A client the person supplied is used again.

Tokens only go over TLS. `validate_url` rejects `http://` unless the host is loopback.

## Tauri commands

All return `Result<_, String>`. The error string `needs_auth` means "offer Sign in again".

| Command | Args (JS camelCase) | Returns |
|---------|---------------------|---------|
| `mcp_presets` | — | `[{ name, url, auth: "oauth"\|"token"\|"client_id", verified, note }]` |
| `mcp_list_connections` | — | `[{ id, name, url, auth: "oauth"\|"token"\|"none", status: "connected"\|"needs_auth"\|"error", error? }]` |
| `mcp_add_connection` | `{ name, url, token?, clientId?, clientSecret? }` | connection. If the server asks for it, OAuth runs in the browser first. |
| `mcp_reauth_connection` | `{ id, token? }` | connection. Runs OAuth again, or stores a new token, then checks the connection. |
| `mcp_remove_connection` | `{ id }` | — |
| `mcp_list_tools` | `{ id }` | `[{ name, description, input_schema }]` |
| `mcp_call_tool` | `{ id, tool, arguments }` | `{ content, is_error }`. `content` holds the server's MCP content blocks as they came. |

## Presets

Checked on 2026-10-20 by sending `initialize` to each URL. Each one answered 401, and in most cases
the reply pointed to OAuth metadata.

| App | URL | Sign-in | Notes |
|-----|-----|---------|-------|
| Linear | `https://mcp.linear.app/mcp` | OAuth + DCR | verified |
| GitHub | `https://api.githubcopilot.com/mcp/` | token | verified. The authorization server is `github.com/login/oauth`, which has no DCR, so the person pastes a PAT. |
| Atlassian (Jira, Confluence) | `https://mcp.atlassian.com/v1/mcp` | OAuth + DCR | verified. There is no protected-resource metadata; the origin's AS metadata is used. |
| Notion | `https://mcp.notion.com/mcp` | OAuth + DCR | verified |
| Sentry | `https://mcp.sentry.dev/mcp` | OAuth + DCR | verified |
| HubSpot | `https://mcp.hubspot.com/` | client ID | verified. No DCR: the person makes an MCP auth app in HubSpot. |
| Asana | `https://mcp.asana.com/v2/mcp` | client ID | verified. The V2 authorization server is `app.asana.com`, which has no DCR. The legacy `/sse` endpoint has DCR, but we do not speak that transport. |
| Salesforce | `https://api.salesforce.com/platform/mcp/v1/platform/sobject-all` | client ID | **unverified path**. It answers 401, but the server name depends on which server the org turns on in Setup › MCP Servers. Needs an External Client App. |

## Send-to dialog

`ui/web/src/components/Lore/SendToDialog.jsx`. Props:
`{ item: { subject, detail, from, address, domain, source, id }, onClose, onSent }`.

- The dialog lists the connected destinations, with logos from `useBrand(serverDomain(url))`
  (`mcp.linear.app` → `linear.app`, `githubcopilot.com` → `github.com`). It shows the tools of the
  selected destination, with tools that create something listed first.
- Arguments are prefilled. Known tools (Linear and GitHub create issue, Jira create issue, HubSpot
  contact and note, Notion create page) use hand-written templates in `lib/mcpClient.js`. Template
  output is kept only for keys that the tool's schema actually has. For other tools, a title-like key
  gets the subject, and a body-like key gets the detail plus "From inbox2: <from> — <subject>".
- The form is built from `input_schema`: string, number, integer, boolean and enum fields. Object
  and array fields are shown as JSON. Required fields are marked, and **Create** stays disabled until
  they are filled.
- **Create** calls the tool. After a success, the dialog calls
  `onSent({ connection, tool, summary })`. `summary` is the first text block of the result, such as
  the new issue's URL. When the result has `is_error: true`, the dialog shows the error and does not
  call `onSent`.
- The web build shows "Available in the desktop app".

## Phones (iOS and Android)

The Send-to sheet is `ui/ios/Sources/Views/SendToSheet.swift` and
`ui/android/.../ui/screens/SendToSheet.kt`, opened from a Lore row's long-press menu. The form logic
is one Rust implementation (`core/src/mcp_client/draft.rs`, the same rules as `lib/mcpClient.js`).

| FFI (`InboxEngine`) | Returns |
|---------------------|---------|
| `mcp_presets_json`, `mcp_connections_json` | JSON arrays |
| `mcp_begin_connect(name, url, token?, client_id?, client_secret?, redirect_uri)`, `mcp_begin_reauth(id, token?, redirect_uri)` | `{ connected }` or `{ state, authorize_url }` |
| `mcp_finish_connect(state, code)` | connection |
| `mcp_remove_connection(id)` | — |
| `mcp_drafts_json(id, item_json)` | ranked tools, each with `fields` and prefilled string `values` |
| `mcp_create(id, tool, values_json)` | `{ summary, is_error }`. The only call that runs a tool. |
| `lore_sent_add`, `lore_sent_list_json` | the reference chip (the desktop's `item_key` format, `mx:`/`local:` + the thread) |

Sign-in follows the device-link pattern: the phone binds a loopback port and opens
SFSafariViewController or a Custom Tab; the core keeps the PKCE verifier and the state until
`mcp_finish_connect`. A sign-in in progress is held in memory, so killing the app mid-sign-in means
starting it again.

## Threat model

- **Nothing is called unprompted.** The engine, rules and AI lanes never call `call_tool`. The only
  place that calls it is the Create button. This repeats the Bridge rule ("never sends").
- **Tool results are untrusted.** A remote server or a compromised account can return anything. The
  UI shows only the first text block, as text: no HTML, no links that open by themselves, and the
  text is never passed to a model as instructions. Do not feed tool output into an agent prompt
  without the injection handling in [Agentic-Filters.md](Agentic-Filters.md).
- **Tool descriptions and schemas are untrusted too.** Their text appears only as labels and hints
  in the form, cut to a short length.
- **Mail leaves the device only in the fields the person sees.** The prefill uses the subject, the
  Lore detail and the sender. The full body is never sent. The person can edit or clear every field
  before Create.
- **Tokens are encrypted at rest** with the device credential key, are sent only to the connection's
  own URL and to its authorization server's token endpoint, and only over TLS (loopback excepted).
- **OAuth:** PKCE S256 on every flow, a CSRF `state` checked on the loopback, and a resource
  indicator so a token is bound to its server. The listener binds `127.0.0.1` on a random port and
  closes after one callback or 300 s.

## Tests

- `cd ui/desktop/core && cargo test --lib mcp_client` runs wiremock MCP servers. The tests cover
  `initialize` with a session id, an SSE `tools/list` that has a notification before the response,
  `tools/call`, a bearer connection, 401 → `needs_auth` (recorded), storage without plaintext tokens,
  and OAuth discovery (well-known fallback), DCR, the authorize URL, code exchange and refresh. They
  also cover the RFC 7636 PKCE test vector and the https rule.
- `cd ui/web && npx vitest run src/lib/__tests__/mcpClient.test.js` covers templates, schema
  defaults, type conversion, JSON fields and helpers.

## Not built yet

- The Lore item does not store the external reference (`TUL-412`) yet. `onSent` returns the summary
  for the caller to keep.
- Unknown servers get prefill from key-name guesses only. Filling arguments from the schema with a
  model (plan §5) needs a capable model lane.

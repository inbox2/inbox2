# Inbox2 — Reference Implementation: API & Screens

**Version:** 1.7 (draft)
**Status:** For review
**Companion to:** Inbox2 — Full Feature Specification v1.11
**Scope:** This document maps out (A) the complete HTTP API surface, (B) every screen, title, and navigation path of the React web application, and the cross-cutting engineering standards both must follow. Section E covers API engineering standards, section F frontend engineering standards, section G the design system / look & feel, and section H the repository structure. Entries cross-reference the feature-spec item(s) they implement (e.g. *spec 3.3.1*).

### Changes in v1.7

- **A18** — New API group: Delivery Channels & Tracking. CRUD for external delivery channels (SMTP relay, SES), channel health check, per-message delivery status, delivery attempt log, per-channel statistics, and organization-wide delivery log.
- **S9.12** — New screen: Delivery channels settings (channel list, add/edit external channel, health check, delivery stats).
- **S5.1 / S5.4** — Conversation view and properties sidebar updated to show per-message delivery status.
- **Part D** — Build order updated: P0 delivery tracking in Wave 1; P1 external channels in Wave 2.

### Changes in v1.6

- No API or screen changes — the feature-spec v1.10 additions (MX/SMTP test, seed and performance suites; email-standards coverage) are backend/component concerns, not new HTTP endpoints or screens.
- Stale references to feature-spec "17.4" (per-component test suites) corrected to **17.1.4** following the section 17 restructure.
- Part D build order re-pointed to feature spec section 19 and notes the MX/SMTP suites and email-standards conformance as P0 Wave-1 work.

### Changes in v1.5

- **A10.6** — Search endpoint noted as PostgreSQL full-text search (feature spec 6.3); always tenant-scoped. Returns a `suggestion` (spelling correction from the org's own vocabulary via `pg_trgm`, 6.3.6) when the query matched nothing.
- **H3** — `ui/desktop/` now also houses the local datastore and offline sync layer (feature spec 16.7).
- No new endpoints — offline sync (feature spec 16.7) is a desktop-client architecture concern using a sync engine (PowerSync) against Postgres, not a new API surface; the existing REST API remains the upload path.

### Changes in v1.4

- **New section F4** — Keyboard operability: the full app is operable by keyboard alone (implements feature spec 12.1.10). Old F4 (output note) renumbered F5.
- **S3.4** — Command palette promoted P1 → P0; it is the keyboard entry point to every screen and action.

### Changes in v1.3

- **A7 / S6.1** — Mail size limit is now plan-dependent: **20 MB Free, 100 MB paid**. Cross-cutting note and composer screen updated.
- **A15.3 / S9.6** — LLM spam-screening opt-in removed; spam filtering is Rspamd-only and paid-plan-only.
- **H5** — New `deploy/` folder added to the repository structure: Terraform for the Rancher / Kubernetes deployment.

### Changes in v1.2

- **A16** — Billing group rewritten for the concrete plans (Free; Paid USD 19/mo); adds the plans endpoint and downgrade endpoint, plus a cross-cutting plan-limit-enforcement note.
- **A7** — Send and attachment endpoints now enforce the 20 MB mail size limit; cross-cutting note added.
- **S8.3 / S6.1 / S12.3** — Billing screen reflects the concrete plans; composer shows the 20 MB limit; past-due banner re-pointed to spec 13.2.4.
- **S12.6** — New "upgrade required" screen for Free-plan limit boundaries.

### Changes in v1.1

- New section **E** — API engineering standards (testing, templated responses, tenant isolation, input/output minimisation, public ID policy). These apply to *every* endpoint in Part A.
- New section **F** — Frontend engineering standards (CSS architecture, no Tailwind, no inline styles, the tracked component library, SF Icons per section). These apply to *every* screen in Part B.
- New section **G** — Design system: fonts (SF Pro, SF Icons, Fira Code) and look & feel (neumorphic, technical, dark, modern, readable).
- New section **H** — Repository structure (`api`, `ui/web`, `ui/desktop`, `ui/cli`).

---

## 0. Conventions

- **API base:** all endpoints are prefixed `/api/v1`. All requests and responses are JSON (spec 16.3.2).
- **Organization scoping:** most resources live inside an organization (a domain). The pattern is `/api/v1/orgs/{org_id}/...`. Account-level resources sit at `/api/v1/account/...`.
- **Real-time:** anything marked **[WS]** is also delivered as an Action Cable channel event, not only as a REST resource (spec 16.3.4).
- **Auth:** human sessions use a session token; agentic users and developers use scoped API keys (spec 5.5.2, 14.5).
- **Priority tags** (P0/P1/P2) carry over from the feature spec so the API and screens can be built in the same release waves.
- **Numbering** is stable. API endpoints are grouped `A1`–`A17`; screens are grouped `S1`–`S13`.
- **IDs** shown as `{org_id}`, `{id}`, etc. are opaque public IDs, never internal numeric IDs — see standard E5.
- **Cross-cutting standards** in sections E (API) and F (frontend) apply to every endpoint and screen below; they are not repeated per item.

---

# Section E — API Engineering Standards

These standards are **binding on every endpoint in Part A**. They are not per-endpoint items; they are global rules that the build and review of each endpoint must satisfy. Each endpoint's test suite and code review checks against this section.

## E1. Testing — positive and negative

| # | Standard | Pri |
|---|----------|-----|
| E1.1 | Every endpoint (and therefore every feature it implements) must be specced and covered by **both positive and negative tests**. Positive: the endpoint works for valid, authorised input. Negative: it correctly rejects invalid input, malformed payloads, missing/invalid auth, and unauthorised access. | P0 |
| E1.2 | Negative coverage explicitly includes a **tenant-isolation test** per endpoint (see E3) and an **unauthorised-role test** where roles apply. | P0 |
| E1.3 | Tests are mapped to feature-spec item numbers so the > 95% spec-item coverage gate (feature spec 0.1, section 17) can be measured. | P0 |
| E1.4 | An endpoint without both a positive and a negative test is treated as incomplete, regardless of whether code exists. | P0 |

## E2. Templated responses — no inline JSON

| # | Standard | Pri |
|---|----------|-----|
| E2.1 | **All API responses are rendered through a template/serializer layer.** Inline/ad-hoc JSON construction in controllers (e.g. `render json: {...}` with hand-built hashes) is prohibited. | P0 |
| E2.2 | The serializer is **Alba** (feature spec 16.3.2), or jbuilder as the conservative fallback — one choice, applied consistently across the whole API. Each resource has a named serializer/view; controllers select a serializer, never assemble JSON. | P0 |
| E2.3 | Error responses are templated too — a single, consistent error shape across all endpoints. | P0 |

## E3. Tenant isolation

| # | Standard | Pri |
|---|----------|-----|
| E3.1 | Every endpoint that touches organization-scoped data must **enforce and be tested for tenant isolation**: a member of organization A can never read or write organization B's data, even with a valid session and a guessed/enumerated ID. | P0 |
| E3.2 | Isolation is enforced server-side at the query layer (scope every query to the authenticated context's organization), not merely by URL structure. | P0 |
| E3.3 | A cross-tenant access attempt returns a not-found / no-access response (E2.3) and is recorded in the audit log (feature spec 11.3.2). | P0 |
| E3.4 | Account-level endpoints (`/api/v1/account/...`) are isolated per account on the same principle. | P0 |

## E4. Input & output minimisation

| # | Standard | Pri |
|---|----------|-----|
| E4.1 | Each endpoint accepts **only the inputs it needs** — requests are validated against an explicit allow-list of permitted fields; unexpected fields are rejected or ignored, never blindly persisted (no mass-assignment). | P0 |
| E4.2 | Each endpoint returns **only the outputs the client needs** — the serializer (E2) exposes an explicit field list. Internal data (internal IDs, internal flags, audit fields, other tenants' data, implementation detail) is never serialised. | P0 |
| E4.3 | The serializer is the single enforcement point for E4.2: if a field is not declared in the serializer, it cannot leak. | P0 |
| E4.4 | This is verified by test — output-shape assertions confirm no internal field appears in any response. | P0 |

## E5. Public identifiers

| # | Standard | Pri |
|---|----------|-----|
| E5.1 | All IDs exposed in the API — in URLs, request bodies, and responses — are **opaque, unique public IDs** (e.g. UUIDs or prefixed random identifiers such as `conv_…`, `org_…`, `msg_…`). | P0 |
| E5.2 | Internal sequential/numeric IDs are an implementation detail of the datastore and **must never appear in the API** — not in URLs, not in payloads, not in errors. | P0 |
| E5.3 | Public IDs are non-guessable and non-enumerable, which also reinforces tenant isolation (E3). | P0 |
| E5.4 | Verified by test — response-shape and URL tests assert that no internal numeric ID is ever exposed. | P0 |

> These five standards (E1–E5) form a per-endpoint review checklist: positive + negative tests, templated response, tenant-isolation test, minimal in/out, public IDs only. Part A's "every endpoint" therefore implicitly carries all of E1–E5.

---

# Part A — API Surface

## A1. Authentication & session — *spec 2.1*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A1.1 | `POST /api/v1/auth/signup` | Create account owner with username + password. | 2.1.1 | P0 |
| A1.2 | `POST /api/v1/auth/login` | Log in, returns session token. | 2.1.3 | P0 |
| A1.3 | `POST /api/v1/auth/logout` | End current session. | 2.1.3 | P0 |
| A1.4 | `POST /api/v1/auth/password/reset-request` | Begin password reset. | 2.1.3 | P0 |
| A1.5 | `POST /api/v1/auth/password/reset` | Complete password reset with token. | 2.1.3 | P0 |
| A1.6 | `GET /api/v1/auth/sessions` | List active sessions. | 2.1.4 | P0 |
| A1.7 | `DELETE /api/v1/auth/sessions` | Sign out of all sessions. | 2.1.4 | P0 |
| A1.8 | `POST /api/v1/auth/2fa/totp/enroll` · `…/verify` · `DELETE …` | Manage TOTP second factor. | 2.1.5 | P1 |
| A1.9 | `POST /api/v1/auth/2fa/passkey/register` · `…/authenticate` · `DELETE …` | Manage passkeys (WebAuthn). | 2.1.5 | P1 |
| A1.10 | `GET /api/v1/auth/sso/{provider}` · `…/callback` | Social/SSO sign-in (Google, Microsoft). | 2.1.6 | P1 |
| A1.11 | `POST /api/v1/auth/saml/...` | SAML SSO endpoints. | 2.1.7 | P2 |

## A2. Account — *spec 2.2, 2.1.8*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A2.1 | `GET /api/v1/account` | Read account: owner, settings, defaults. | 2.2.2 | P0 |
| A2.2 | `PATCH /api/v1/account` | Update account settings (name, default tz/language). | 2.2.2 | P0 |
| A2.3 | `PUT /api/v1/account/billing-email` | Set/replace the external billing email; warns if Inbox2-hosted. | 2.1.8 | P0 |
| A2.4 | `GET /api/v1/account/organizations` | List all organizations on the account (for the switcher). | 2.2.7 | P1 |
| A2.5 | `POST /api/v1/account/transfer-ownership` | Transfer account ownership. | 2.2.6 | P1 |

## A3. Organizations & domains — *spec 2.2, 2.3*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A3.1 | `POST /api/v1/orgs` | Add a domain → creates its organization (wizard). | 2.3.1, 2.2.1 | P0 |
| A3.2 | `GET /api/v1/orgs/{org_id}` | Read organization settings. | 2.2.3 | P0 |
| A3.3 | `PATCH /api/v1/orgs/{org_id}` | Update organization settings. | 2.2.3 | P0 |
| A3.4 | `DELETE /api/v1/orgs/{org_id}` | Delete organization with full data removal. | 11.3.4 | P1 |
| A3.5 | `GET /api/v1/orgs/{org_id}/dns` | Get required DNS records + per-record pass/fail status. | 2.3.2, 2.3.3 | P0 |
| A3.6 | `POST /api/v1/orgs/{org_id}/dns/verify` | Trigger a re-check of DNS records. | 2.3.2 | P0 |
| A3.7 | `POST /api/v1/orgs/{org_id}/dns/cloudflare` | One-click Cloudflare setup via scoped API token. | 2.3.2 | P0 |
| A3.8 | `POST /api/v1/orgs/{org_id}/aliases` · `DELETE …/{id}` | Manage alias domains. | 2.2.5 | P1 |
| A3.9 | `GET /api/v1/orgs/{org_id}/health` | Domain health (ongoing MX/SPF/DKIM/DMARC monitoring). | 2.3.6 | P1 |
| A3.10 | `POST /api/v1/orgs/{org_id}/transfer-ownership` | Transfer a single organization. | 2.2.6 | P1 |
| A3.11 | `POST /api/v1/orgs/{org_id}/test-email` | Onboarding diagnostic — send a test email, watch it land. | 2.4.2 | P0 |
| A3.12 | `GET /api/v1/orgs/{org_id}/onboarding` | First-run checklist state. | 2.4.1 | P0 |

## A4. Members & roles — *spec 5.1, 5.2.5*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A4.1 | `GET /api/v1/orgs/{org_id}/members` | List members (status + type human/agent). | 5.1.3 | P0 |
| A4.2 | `POST /api/v1/members/invite-mx` | Invite a member by email to mailboxes on one or more domains (sends the invite email). | 5.1.1 | P0 |
| A4.3 | `POST /api/v1/members/accept-invite` | Invitee accepts, sets username + password. | 5.1.1 | P0 |
| A4.4 | `PATCH /api/v1/orgs/{org_id}/members/{id}` | Update member role / enable / disable. | 5.1.5, 5.1.4 | P0 |
| A4.5 | `DELETE /api/v1/orgs/{org_id}/members/{id}` | Remove member; reassign/release their conversations. | 5.1.4 | P0 |
| A4.6 | `PUT /api/v1/orgs/{org_id}/members/{id}/availability` | Set out-of-office / unavailable flag. | 5.2.5 | P1 |
| A4.7 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/roles` | Custom roles with granular permissions. | 5.1.8 | P2 |
| A4.8 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/member-groups` | Member groups / teams. | 5.1.9 | P2 |

## A5. Agentic users — *spec 5.5*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A5.1 | `POST /api/v1/orgs/{org_id}/agents` | Create an agentic user. | 5.5.1 | P1 |
| A5.2 | `GET /api/v1/orgs/{org_id}/agents` · `GET …/{id}` | List / read agents. | 5.5.1 | P1 |
| A5.3 | `PATCH /api/v1/orgs/{org_id}/agents/{id}` | Update agent (permission scope, supervisor, approval mode). | 5.5.4, 5.5.6 | P1 |
| A5.4 | `DELETE /api/v1/orgs/{org_id}/agents/{id}` | Remove an agent. | 5.5.1 | P1 |
| A5.5 | `POST /api/v1/orgs/{org_id}/agents/{id}/credentials` · `DELETE …` | Issue / revoke the agent's scoped API credential. | 5.5.2 | P1 |
| A5.6 | `GET /api/v1/orgs/{org_id}/agents/{id}/feed` | The agent's routed feed, since-cursor paged. | 5.5.3, 14.2 | P1 |
| A5.7 | `GET /api/v1/orgs/{org_id}/agents/{id}/run-log` | Agent run log (inputs, actions, outcomes). | 5.5.9 | P2 |
| A5.8 | `PUT /api/v1/orgs/{org_id}/agents/{id}/limits` | Rate / spend limits. | 5.5.8 | P2 |
| A5.9 | `GET /api/v1/orgs/{org_id}/agents/approval-queue` | Replies awaiting human sign-off. | 5.5.7 | P1 |

## A6. Conversations & the pool — *spec 3.1, 3.4, 4.2*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A6.1 | `GET /api/v1/orgs/{org_id}/conversations` | List conversations; accepts filter, sort, view, pagination params. **[WS]** | 3.1.1, 3.4.1, 3.4.2, 3.4.6 | P0 |
| A6.2 | `GET /api/v1/orgs/{org_id}/conversations/{id}` | Read a conversation: thread, messages, notes, metadata. | 3.1.4, 4.1.1 | P0 |
| A6.3 | `PATCH /api/v1/orgs/{org_id}/conversations/{id}` | Set status, read/unread. **[WS]** | 4.2.2, 4.2.6, 6.1.2 | P0 |
| A6.4 | `POST /api/v1/orgs/{org_id}/conversations/bulk` | Bulk action on many conversations. | 3.4.3 | P0 |
| A6.5 | `POST /api/v1/orgs/{org_id}/conversations/{id}/archive` · `…/trash` · `…/spam` | Archive / trash / mark spam. **[WS]** | 4.2.6, 11.1.3 | P0 |
| A6.6 | `POST /api/v1/orgs/{org_id}/conversations/{id}/snooze` · `DELETE …` | Snooze / unsnooze until a time. | 4.2.7 | P1 |
| A6.7 | `POST /api/v1/orgs/{org_id}/conversations/{id}/merge` | Merge two conversations. | 4.2.8 | P1 |
| A6.8 | `POST /api/v1/orgs/{org_id}/conversations/{id}/split` | Split a message into a new conversation. | 4.2.8 | P1 |
| A6.9 | `GET /api/v1/orgs/{org_id}/conversations/{id}/activity` | Activity-log timeline. | 4.3.4 | P1 |
| A6.10 | `GET /api/v1/orgs/{org_id}/conversations/{id}/raw/{message_id}` | Original raw source / full headers. | 4.1.5 | P0 |
| A6.11 | `GET /api/v1/orgs/{org_id}/conversations/{id}/export` | Export conversation to PDF. | 4.1.6 | P1 |
| A6.12 | `POST /api/v1/orgs/{org_id}/conversations/{id}/tasks` | Convert conversation to a task with due date. | 4.2.10 | P2 |

## A7. Messages, attachments & sending — *spec 4.1, 8.1*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A7.1 | `POST /api/v1/orgs/{org_id}/messages` | Send a message: reply / reply-all / forward / new; choose From address. Rejects if total message size (body + attachments) exceeds the org's per-plan limit (20 MB Free / 100 MB paid). | 4.2.1, 8.1.2, 11.5.3 | P0 |
| A7.2 | `GET /api/v1/orgs/{org_id}/attachments/{id}` | Download / stream an attachment (from S3 store). | 4.1.4 | P0 |
| A7.3 | `POST /api/v1/orgs/{org_id}/attachments` | Upload an attachment for composing. Rejects an upload that would take the draft over the org's per-plan size limit. | 8.1.3, 11.5.3 | P0 |
| A7.4 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/drafts` | Manage drafts (incl. shared drafts & the agent approval queue); a draft reports its current total size against the org's per-plan size limit. | 8.1.5, 8.1.10, 11.5.3 | P0 |
| A7.5 | `POST /api/v1/orgs/{org_id}/drafts/{id}/schedule` | Schedule a send for later. | 8.1.8 | P1 |
| A7.6 | `POST /api/v1/orgs/{org_id}/messages/{id}/cancel-send` | Undo send within the cancellation window. | 8.1.9 | P1 |

> **Attachments on the message payload.** `MessageSerializer` carries an
> `attachments` array (`id`, `filename`, `content_type`, `size_bytes`,
> `has_content`, `download_url`, plus the sealed-filename blobs for E2EE
> domains) and `ConversationSerializer` carries `has_attachment` for the row
> paperclip. Any endpoint rendering messages must preload
> `includes(messages: :attachments)` or it N+1s per message; the conversation
> **list** must not preload (it precomputes the page's paperclip set in one
> query instead — see `ConversationsController#index`). A7.2 streams the bytes
> through Rails rather than redirecting to a presigned URL: the web app is a
> different origin from the API and the desktop runs on `tauri://localhost`, so
> a cross-origin fetch of the S3 URL needs bucket CORS that Garage doesn't have.
> `has_content` is false while a row exists but its bytes don't (a sealed
> attachment's ciphertext is spooled after the row), and the client must not
> offer a download then.

> **Mail size limit (cross-cutting, spec 11.5).** Every email is capped by the organization's plan — **20 MB on Free, 100 MB on paid** (body + all attachments). Inbound enforcement happens at SMTP time in the Go MX component (spec 11.5.2) — outside this HTTP API — so oversized mail never reaches storage; the MX resolves the receiving domain's plan to apply the right limit. Outbound enforcement is at the API: A7.1/A7.3/A7.4 above. Both limits are configurable system constants (spec 11.5.4); the active limit is exposed to clients via A16.1 plan metadata so the composer can show it. Verified by negative tests per E1.

## A8. Assignment & access — *spec 5.2, 5.3*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A8.1 | `PUT /api/v1/orgs/{org_id}/conversations/{id}/assignees` | Set/replace assignees (human or agent). **[WS]** | 5.2.1, 5.2.2 | P0 |
| A8.2 | `DELETE /api/v1/orgs/{org_id}/conversations/{id}/assignees/{member_id}` | Unassign one member. | 5.2.3 | P0 |
| A8.3 | `PUT /api/v1/orgs/{org_id}/conversations/{id}/access` | Grant conversation access by tagging members. **[WS]** | 5.3.1, 5.3.2 | P0 |
| A8.4 | `DELETE /api/v1/orgs/{org_id}/conversations/{id}/access/{member_id}` | Revoke a member's access. | 5.3.3 | P0 |

## A9. Tags & statuses — *spec 6.1, 6.2*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A9.1 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/tags` | Manage org-level tags (name, color). | 6.2.1 | P0 |
| A9.2 | `PUT /api/v1/orgs/{org_id}/conversations/{id}/tags` | Apply/remove tags on a conversation. **[WS]** | 6.2.2, 4.2.4 | P0 |
| A9.3 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/tag-groups` | Tag groups / categories. | 6.2.3 | P1 |
| A9.4 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/statuses` | Custom statuses (core statuses are built-in). | 6.1.4 | P2 |

## A10. Views & search — *spec 3.2, 3.3, 6.3*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A10.1 | `GET /api/v1/orgs/{org_id}/views` | List views available to the member (system + personal + shared). | 3.2.x, 3.3.5 | P0 |
| A10.2 | `POST /api/v1/orgs/{org_id}/views` | Create a personal saved view (if member is permitted). | 3.3.1, 3.3.2 | P0 |
| A10.3 | `PATCH/DELETE /api/v1/orgs/{org_id}/views/{id}` | Update / delete / reorder a view. | 3.3.5 | P0 |
| A10.4 | `POST /api/v1/orgs/{org_id}/views/{id}/share` | Publish a view as a shared/team view (admin). | 3.3.6 | P1 |
| A10.5 | `GET /api/v1/orgs/{org_id}/views/counts` | Unread counts/badges per view. **[WS]** | 3.3.7 | P1 |
| A10.6 | `GET /api/v1/orgs/{org_id}/search` | Full-text search (PostgreSQL full-text search engine, spec 6.3); operators; scope to view/org/account; always tenant-scoped. | 6.3.1, 6.3.2, 6.3.3 | P0 |
| A10.7 | `POST /api/v1/orgs/{org_id}/search/save` | Save a search as a view. | 6.3.4 | P1 |
| A10.8 | `PUT /api/v1/orgs/{org_id}/settings/view-policy` | Admin sets whether members may create their own views. | 3.3.1 | P0 |

## A11. Routing rules — *spec 7*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A11.1 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/rules` | Manage routing rules (conditions + actions). | 7.1.1, 7.1.2, 7.2.x, 7.3.x | P0 |
| A11.2 | `PUT /api/v1/orgs/{org_id}/rules/order` | Reorder rule priority. | 7.1.2 | P0 |
| A11.3 | `PATCH /api/v1/orgs/{org_id}/rules/{id}/toggle` | Enable / disable a rule. | 7.1.2 | P0 |
| A11.4 | `POST /api/v1/orgs/{org_id}/rules/{id}/dry-run` | Test a rule against recent pool messages. | 7.1.6 | P1 |
| A11.5 | `GET /api/v1/orgs/{org_id}/rules/{id}/run-log` | Per-rule run log. | 7.1.5 | P1 |
| A11.6 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/webhooks` | Manage webhook endpoints used by rule actions. | 7.3.5, 7.4.1, 7.4.5 | P0 |
| A11.7 | `GET /api/v1/orgs/{org_id}/webhooks/{id}/deliveries` | Webhook delivery log (status, response, retries). | 7.4.3, 7.4.4 | P1 |

## A12. Notes & collaboration — *spec 9.1*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A12.1 | `POST /api/v1/orgs/{org_id}/conversations/{id}/notes` | Add a private note; @mentions notify + grant access. **[WS]** | 9.1.1, 9.1.3, 9.1.4 | P0 |
| A12.2 | `PATCH/DELETE /api/v1/orgs/{org_id}/notes/{id}` | Edit / delete own note; edit history. | 9.1.6 | P1 |
| A12.3 | `GET /api/v1/orgs/{org_id}/conversations/{id}/presence` | Collision detection / presence on a conversation. **[WS]** | 5.4.1, 5.4.2, 5.4.3 | P0 |

## A13. Templates / canned responses — *spec 8.2*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A13.1 | `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/templates` | Manage canned responses (personal + shared). | 8.2.1, 8.2.2 | P1 |
| A13.2 | `GET /api/v1/orgs/{org_id}/signatures` · `PUT …` | Personal & org signatures. | 8.1.7 | P1 |

## A14. Notifications — *spec 10*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A14.1 | `GET /api/v1/notifications` | In-app notification feed. **[WS]** | 10.1 | P0 |
| A14.2 | `POST /api/v1/notifications/read` | Mark notification(s) read. | 10.1 | P0 |
| A14.3 | `GET/PUT /api/v1/notifications/preferences` | Per-member notification preferences & per-event toggles. | 10.2, 10.3 | P0 |
| A14.4 | `POST /api/v1/notifications/push/subscribe` | Register browser/desktop push. | 10.4 | P1 |

## A15. Spam, mail-handling & security — *spec 11*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A15.1 | `GET/POST/DELETE /api/v1/orgs/{org_id}/blocklist` · `…/allowlist` | Manage block / allow lists. | 11.1.4, 11.1.5 | P0 |
| A15.2 | `POST /api/v1/orgs/{org_id}/conversations/{id}/spam-feedback` | Mark spam / not-spam, feeding the engine. | 11.1.3 | P0 |
| A15.3 | `GET/PUT /api/v1/orgs/{org_id}/settings/spam` | Rspamd spam aggressiveness, structured-aliases-only mode. (Paid plan only — Free has no spam filter.) | 11.1.6, 11.1.7 | P1 |
| A15.4 | `POST /api/v1/orgs/{org_id}/imports` · `GET …/{id}` | Start / track a mail import (IMAP or export file). | 11.2.1 | P1 |
| A15.5 | `GET /api/v1/orgs/{org_id}/audit-log` | Administrative audit log. | 11.3.2 | P0 |
| A15.6 | `POST /api/v1/orgs/{org_id}/export` · `GET …/exports` · `GET …/exports/{id}/download` | Full data export for an organization (see *Data export* below). | 11.3.3 | P1 |
| A15.7 | `POST /api/v1/orgs/{org_id}/gdpr/contact-request` | GDPR contact data export / deletion. | 11.3.5 | P1 |

### Data export (A15.6)

Admin/owner only (403 otherwise, 404 cross-tenant). Built 2026-09-25; replaces the old stub that only returned counts.

- **`POST /orgs/{org_id}/export`** → `202 { data_export }`. Creates a `DataExport` (`dex_`) and queues `DataExportJob`. One export in flight per org, enforced by a partial unique index (`status IN ('queued','running')`): asking again returns the one already running. An export stuck in flight longer than `DataExport::STALE_AFTER` (6h, a dead worker) is failed on the next request so it can't block the org.
- **`GET /orgs/{org_id}/exports`** → `{ data_exports: [...] }`, latest first (20). Fields: `id, status (queued|running|ready|failed|expired), byte_size, counts, error, expires_at, created_at, updated_at`.
- **`GET /orgs/{org_id}/exports/{id}/download`** → streams the zip (200), `409` while not ready, `410` once expired, `503` if storage is down. Streams through Rails because prod Garage is in-cluster only, so a presigned URL is unreachable from a browser (same reason as attachments, A7.2).
- **The zip** (`DataExportJob`): `<domain>/mail.mbox` (mboxrd, every non-draft message of the domain's threads; `other/mail.mbox` for threads with no domain), `calendars/<name>-<cal key>.ics` (one VCALENDAR per calendar, VEVENTs built by `IcsRequest` so UID/RRULE/RECURRENCE-ID/attendees match invitations), `README.txt` (contents, counts, import steps). Plaintext messages are rebuilt with the `mail` gem from stored headers + `body_plain`/`body_html` + attachments pulled from object storage (raw MIME isn't kept). Sealed (e2ee) messages are exported as stored: a `sealed.json` part with the ciphertext columns plus each attachment's ciphertext; never decrypted server-side. Unfetchable attachments are counted (`attachments_missing`) and listed in the README instead of failing the export. Messages stream in batches straight into the zip entry on disk, then the file uploads to object storage (`storage_key`).
- **Retention**: `expires_at` = ready + 7 days. `DataExport.sweep!` (daily, `config/recurring.yml`) deletes expired files, marks them `expired`, and fails stalled exports.
- **UI**: `ui/web/src/pages/admin/DataExportCard.jsx` on Console › Billing & plan: start, status, size + expiry, download link, polls every 5s while building. The download is a plain link that rides the session cookie (web console); a bearer-only local dev session can't use it.
- Known limits: events go out in UTC (IcsRequest has no VTIMEZONE), so a weekly RRULE on a DST-observing local time drifts an hour across the change in some clients. Single `put_object` upload (5 GB cap).

## A16. Billing & plans — *spec 13*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A16.1 | `GET /api/v1/plans` | List available plans (Free; Startup €19.99/mo; Serial Entrepreneur €49.99/mo, excluding VAT) with their limits. | 13.1.1, 13.1.2 | P0 |
| A16.2 | `GET /api/v1/account/billing` | Current subscription: plan, payment method, status, limits, current usage. | 13.2.1, 13.2.3 | P0 |
| A16.3 | `POST /api/v1/account/billing/subscribe` · `PATCH …` | Upgrade to paid / change plan. | 13.1.2, 13.2.1 | P0 |
| A16.4 | `POST /api/v1/account/billing/downgrade` | Downgrade to Free — accepts the choice of which single domain remains active (13.2.5). | 13.2.5 | P1 |
| A16.5 | `GET /api/v1/account/billing/invoices` | Invoice / billing history. | 13.2.1 | P0 |
| A16.6 | `PUT /api/v1/account/billing/payment-method` | Update payment method. | 13.2.1 | P0 |
| A16.7 | `GET /api/v1/account/billing/usage` | Usage vs plan limits: domains, collaborators, storage, message volume. | 13.2.3 | P1 |
| A16.8 | `POST /api/v1/account/billing/trial` | Start free trial of the paid plan. | 13.2.2 | P0 |

> **Plan-limit enforcement (cross-cutting, spec 13.1.4).** Endpoints that create plan-limited resources must enforce the active plan's limits server-side and return a clear "upgrade required" response, not a generic error: `POST /orgs` (A3.1) blocks a 2nd domain on Free; `POST /members/invite-mx` (A4.2) blocks a 2nd collaborator on Free. The spam-filtering endpoints and pipeline (A15.1–A15.3) are inactive for Free-plan organizations (spec 13.1.1). This is verified by negative tests per E1.

## A17. Developer & MCP surface — *spec 14*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A17.1 | `GET/POST/DELETE /api/v1/account/api-keys` | Manage scoped API keys. | 14.5 | P1 |
| A17.2 | `GET/POST/DELETE /api/v1/orgs/{org_id}/event-webhooks` | Outbound event webhooks (new conversation, status change, etc.). | 14.4 | P1 |
| A17.3 | `MCP` endpoint (`/mcp`) | MCP server exposing an agent's feed + permitted tools. | 14.3 | P1 |

> Note: A17.1–A17.2 are the developer/account-level programmatic surface; the REST API in A1–A16 *is* item 14.1. The per-rule webhook (A11.6) is distinct from outbound event webhooks (A17.2) — spec 14.4.

## A18. Delivery channels & tracking — *spec 20*

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A18.1 | `GET /api/v1/orgs/{org_id}/delivery-channels` | List delivery channels (built-in + configured external). | 20.1.1, 20.1.2 | P0 |
| A18.2 | `POST /api/v1/orgs/{org_id}/delivery-channels` | Add an external delivery channel (SMTP relay or SES). Credentials are write-only. | 20.1.2, 20.1.6 | P1 |
| A18.3 | `GET /api/v1/orgs/{org_id}/delivery-channels/{id}` | Read channel config (credentials redacted). | 20.1.2 | P1 |
| A18.4 | `PATCH /api/v1/orgs/{org_id}/delivery-channels/{id}` | Update channel settings, credentials, or status. | 20.1.2, 20.1.5 | P1 |
| A18.5 | `DELETE /api/v1/orgs/{org_id}/delivery-channels/{id}` | Remove an external channel (built-in cannot be deleted). | 20.1.2 | P1 |
| A18.6 | `POST /api/v1/orgs/{org_id}/delivery-channels/{id}/test` | Health check — test connectivity and auth against the channel. | 20.1.4 | P1 |
| A18.7 | `PUT /api/v1/orgs/{org_id}/delivery-channels/default` | Set the organization's default delivery channel. | 20.1.3 | P1 |
| A18.8 | `GET /api/v1/orgs/{org_id}/delivery-channels/{id}/stats` | Per-channel delivery statistics (success/failure/bounce rates, avg latency). | 20.2.7 | P1 |

## A19. Weather (Bridge morning brief)

| # | Method & path | Purpose | Spec | Pri |
|---|---------------|---------|------|-----|
| A19.1 | `GET /api/v1/weather` | Current weather for the caller's IP — feeds the Bridge morning brief. Public + unauthenticated (no tenant data); IP-geolocation + Open-Meteo server-side, short server cache. Always 200; `{short, temp_c, code, place}` with `short` null when unavailable (client omits the line). | — | P2 |
| A18.9 | `GET /api/v1/orgs/{org_id}/messages/{message_id}/delivery` | Delivery status + attempt log for a specific outbound message. | 20.2.1, 20.2.4 | P0 |
| A18.10 | `GET /api/v1/orgs/{org_id}/delivery-log` | Organization-wide delivery log — searchable/filterable by status, channel, date, recipient domain. | 20.2.8 | P1 |

> **Delivery tracking (cross-cutting, spec 20.2).** Every outbound message (A7.1) now carries a delivery status that progresses through *Queued → Sending → Delivered / Failed / Bounced / Deferred*. The SMTP outbound component manages retry and status updates; the API surfaces the status per-message (A18.9) and in aggregate (A18.10). Bounce processing (spec 20.2.6) links DSN bounces received by the MX inbound component back to the original outbound message. Delivery failure notifications use the existing notification system (A14). Verified by tests per E1.

---

# Section F — Frontend Engineering Standards

Binding on **every screen and component in Part B**. Like section E, these are global rules verified at build and review time, not per-screen items.

## F1. CSS architecture

| # | Standard | Pri |
|---|----------|-----|
| F1.1 | A **proper CSS architecture** is set up before feature work begins. **Tailwind is not used.** | P0 |
| F1.2 | The architecture is component-scoped styling — CSS Modules or a CSS-in-JS solution that compiles to real stylesheets — organised with a clear convention (design tokens → base → components → screens). The exact technique is chosen once, up front, and applied consistently. | P0 |
| F1.3 | **No inline styles.** The `style={{…}}` attribute is prohibited except for genuinely dynamic, computed values that cannot be expressed in CSS (and even those are kept to a minimum). All presentation lives in CSS. | P0 |
| F1.4 | A single design-token layer (colours, spacing, typography, radii, shadows, elevation) is the source of truth; components reference tokens, never hard-coded values. The two themes — dark (default) and light (feature spec 12.1.2–12.1.3) — are token sets. | P0 |
| F1.5 | Linting enforces F1.1 and F1.3 (no Tailwind classes, no inline `style`) in CI. | P0 |

## F2. Component library & Storybook

| # | Standard | Pri |
|---|----------|-----|
| F2.1 | The project maintains a **tracked component library** documented in **Storybook**. It is the single source of UI components. | P0 |
| F2.2 | **Before building any new feature or screen, the component library is checked first.** New UI is composed from existing components wherever possible. | P0 |
| F2.3 | When an existing component is close but not exact, the library is **extended** — a new variant is added to that component and documented in Storybook — rather than building a one-off. | P0 |
| F2.4 | When nothing fits, a **new component** is created in the library, with its Storybook story, before it is used in a screen. | P0 |
| F2.5 | Storybook stays in sync with the codebase: every library component has a story covering its variants and states; this is part of the definition of done. | P0 |
| F2.6 | Component tests (feature spec 17.1.4) live alongside the library; visual states are exercised through Storybook. | P0 |

## F3. Iconography

| # | Standard | Pri |
|---|----------|-----|
| F3.1 | **Every section/area in the navigation, menus, and settings has an equivalent SF Icons (SF Symbols) icon.** Sidebar views, settings sections, toolbar actions, and primary navigation each carry a consistent SF icon. | P0 |
| F3.2 | A single icon mapping is maintained — one chosen SF Symbol per section/action — so iconography is consistent across the web app (and reusable by the desktop and CLI clients where applicable). | P0 |
| F3.3 | Icons are part of the component library (F2) — an `Icon` component wrapping the SF Symbol set, themed via tokens (F1.4). | P0 |

## F4. Keyboard operability

Binding on every screen and component in Part B. Implements feature spec 12.1.10.

| # | Standard | Pri |
|---|----------|-----|
| F4.1 | **The full application is operable by keyboard alone — no mouse required for any screen, view, control, dialog, or navigation path.** This is a hard guarantee, not a best-effort. | P0 |
| F4.2 | Every interactive element is keyboard-focusable, has a visible focus state (from the design tokens, F1.4), and a logical focus/tab order; no element is reachable only by pointer. | P0 |
| F4.3 | The **command palette** (screen S3.4) is the keyboard entry point to any screen or action — every screen in Part B and every primary action is reachable through it. | P0 |
| F4.4 | High-frequency actions also have direct shortcuts (feature spec 12.1.5); a discoverable, in-app keyboard-shortcut reference lists them. | P0 |
| F4.5 | Components in the library (F2) ship keyboard support as part of their definition of done — a component is not "done" if it cannot be operated by keyboard; Storybook stories exercise keyboard interaction. | P0 |
| F4.6 | Verified by test — automated interaction tests cover keyboard navigation and operation; full keyboard reachability is part of the screen test suite (feature spec 17.1.4). | P0 |
| F4.7 | Applies to the Tauri desktop client (which wraps the web app) as well as the web client. The Textual CLI is keyboard-only by nature. | P0 |

## F5. Output of these standards

The screen tables in Part B (S1–S13) each gain, in practice, an associated SF icon (F3.1), are built from the tracked component library (F2.2), and are fully keyboard-operable (F4). The "Notes" column names the screen's purpose; the icon mapping (F3.2) and the keyboard-shortcut/command-palette reference (F4.3–F4.4) are maintained as living artifacts alongside Storybook.

---

# Part B — React Web Application: Screen & Navigation Map

## B0. Navigation model

The app has three navigation tiers:

1. **Account shell** — top-level chrome present everywhere: organization switcher, notifications, account menu. (Maps to spec 2.2.7, 10.)
2. **Organization workspace** — the email client itself, scoped to one organization (one domain). The left sidebar lists views; the main area is list + conversation. This is where users spend ~all their time.
3. **Settings** — a separate sectioned area, account-level and organization-level.

Unauthenticated users see only the **Auth** screens (S1). Onboarding (S2) runs after first signup and after adding any new domain.

```
Auth (S1) ──▶ Onboarding (S2) ──▶ Organization Workspace (S4–S7)
                                         │
            Account shell (S3) ──────────┤── Settings (S8–S12)
                                         └── Agents (S13)
```

---

## S1. Authentication — *spec 2.1*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S1.1 | Sign up | "Create your Inbox2 account" | Username + password; no email required. | P0 |
| S1.2 | Log in | "Log in to Inbox2" | Username + password; passkey option. | P0 |
| S1.3 | Forgot password | "Reset your password" | — | P0 |
| S1.4 | Reset password | "Choose a new password" | Reached via reset link. | P0 |
| S1.5 | Accept invitation | "Join {organization} on Inbox2" | Invitee sets username + password. | P0 |
| S1.6 | Two-factor challenge | "Verify it's you" | TOTP or passkey at login. | P1 |
| S1.7 | SSO callback / interstitial | "Signing you in…" | Google/Microsoft return. | P1 |

## S2. Onboarding — *spec 2.3, 2.4*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S2.1 | Onboarding checklist | "Set up {organization}" | The first-run checklist (2.4.1); progress-tracked. | P0 |
| S2.2 | Add domain wizard | "Connect a domain" | Domain entry → DNS step. | P0 |
| S2.3 | DNS setup | "Point your domain to Inbox2" | Per-record pass/fail; copy-paste snippets; Cloudflare one-click. | P0 |
| S2.4 | Verification waiting | "Checking your DNS…" | Live re-check; status PendingDNS→Verified. | P0 |
| S2.5 | Invite team | "Invite your team" | Optional step; bulk invite. | P0 |
| S2.6 | First rule prompt | "Create your first routing rule" | Optional; links into S9.1. | P0 |
| S2.7 | Test email confirmation | "Send a test email" | Diagnostic — watch a message land in the pool. | P0 |

## S3. Account shell (global chrome) — *spec 2.2.7, 10*

| # | Element | Title / label | Notes | Pri |
|---|---------|---------------|-------|-----|
| S3.1 | Organization switcher | (dropdown) | Switch between domains/orgs; "Add domain"; account overview. | P1 (single-org works without it at P0) |
| S3.2 | Notification center | "Notifications" | Panel: assignments, mentions, access grants, agent escalations. | P0 |
| S3.3 | Account menu | (avatar dropdown) | Profile, settings, log out. | P0 |
| S3.4 | Global command palette | (overlay) | Quick navigation / actions; the keyboard entry point to every screen and action (F4.3, spec 12.1.6). | P0 |
| S3.5 | Organizations overview | "Your domains" | At-a-glance list of all orgs on the account. | P1 |

## S4. Inbox — conversation list — *spec 3.2, 3.3, 3.4*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S4.1 | Sidebar — views | (persistent) | System views (All Mail, Assigned to me, Mentioned, Unassigned, Sent, Drafts, Snoozed, Archived, Spam, Trash) + personal + shared saved views, reorderable. | P0 |
| S4.2 | Conversation list | "{view name}" | Sender, subject, snippet, time, tags, assignees, status, unread; sort control; density toggle. | P0 |
| S4.3 | Bulk-action bar | (contextual) | Appears on multi-select: assign, tag, status, archive, delete, read/unread. | P0 |
| S4.4 | Empty / zero state | "Inbox zero" / "No mail yet" | Encouraging empty states; seed-data prompt if pool is new. | P0 |
| S4.5 | Saved-view editor | "New view" / "Edit view" | Filter-criteria builder (AND, then OR/grouping); hidden if member lacks permission. | P0 |
| S4.6 | Search results | "Results for '{query}'" | Operators; scope selector (view / org / account); "save as view". | P0 |

## S5. Conversation view — *spec 4*

| # | Screen / panel | Title | Notes | Pri |
|---|----------------|-------|-------|-----|
| S5.1 | Conversation thread | "{subject}" | Expandable messages, trimmed-quote toggle, safe HTML render, attachment list, raw-source view; **delivery status indicator on sent messages** (spec 20.2.2). | P0 |
| S5.2 | Conversation toolbar | (in-view) | Reply / reply-all / forward, status, assign, tag, grant-access, archive/delete/spam, snooze, merge/split. | P0 |
| S5.3 | Context sidebar — contact | "Contact" | Sender details + prior conversation history. | P0 |
| S5.4 | Context sidebar — properties | "Details" | Original recipient address, matched rules, status, tags, assignees, members with access, **delivery status + attempt log for sent messages** (spec 20.2.4). | P0 |
| S5.5 | Context sidebar — activity | "Activity" | Event timeline incl. agent actions. | P1 |
| S5.6 | Context sidebar — attachments | "Attachments" | Whole-conversation attachment gallery. | P1 |
| S5.7 | Private notes (inline) | (in thread) | Notes interleaved chronologically, visually distinct, @mention. | P0 |
| S5.8 | Presence indicator | (in-view) | Collision detection: who's viewing / replying. | P0 |

## S6. Composer — *spec 8.1, 8.2*

| # | Screen / panel | Title | Notes | Pri |
|---|----------------|-------|-------|-----|
| S6.1 | Composer | "New message" / "Reply" / "Forward" | Rich text, From-address picker, CC/BCC, drag-drop attachments, inline images, auto-save draft; shows current message size against the org's per-plan limit (20 MB Free / 100 MB paid) and blocks oversize sends (spec 11.5.3). | P0 |
| S6.2 | Template picker | "Insert template" | Canned responses with placeholder variables. | P1 |
| S6.3 | Schedule-send dialog | "Send later" | Pick a time. | P1 |
| S6.4 | Shared-draft / review state | "Draft — awaiting review" | Also the agent approval-queue review surface. | P1 |

## S7. Approval queue (agent oversight) — *spec 5.5.7*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S7.1 | Approval queue | "Agent replies to review" | Agent-drafted replies held for human sign-off; review, edit, send/reject. | P1 |

## S8. Settings — account level — *spec 2.2, 13*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S8.1 | Account settings | "Account" | Name, default tz/language, ownership transfer. | P0 |
| S8.2 | Billing email | "Billing & account email" | The external (non-Inbox2) contact email; warning if Inbox2-hosted. | P0 |
| S8.3 | Billing & plan | "Billing & plan" | Plan comparison (Free: 1 domain, no collaborators, no spam filter; Startup: €19.99/mo, 2 domains, owner + 2 collaborators; Serial Entrepreneur: €49.99/mo, unlimited domains and collaborators; spam filter on both paid tiers), upgrade/downgrade, payment method, invoices, trial, usage-vs-limits indicators. | P0 |
| S8.4 | Security | "Security & sign-in" | Password, passkeys, TOTP, active sessions, SSO. | P0 (passkeys/TOTP P1) |
| S8.5 | API keys | "API keys" | Scoped key management. | P1 |

## S9. Settings — organization level — *spec 2.3, 6.2, 7, 11*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S9.1 | Routing rules | "Routing rules" | Rule list, ordering, enable/disable; rule builder (conditions + actions incl. webhook & route-to-agent); dry-run; run log. | P0 |
| S9.2 | Webhooks | "Webhooks" | Endpoint management + delivery log. | P0 |
| S9.3 | Tags | "Tags" | Tag CRUD with colors; tag groups. | P0 |
| S9.4 | Members | "Team" | Member list, invite, roles, enable/disable, availability. | P0 |
| S9.5 | Domain & DNS | "Domain" | DNS status, re-verify, alias domains, sending/DKIM, health monitoring. | P0 |
| S9.6 | Spam & filtering | "Spam & filtering" | Rspamd block/allow lists, aggressiveness, structured-aliases-only mode. Paid plan only — Free shows an upgrade prompt. | P0 |
| S9.7 | Mail import | "Import mail" | Start/track IMAP or file imports. | P1 |
| S9.8 | Organization preferences | "Organization settings" | Name, tz, language, view-creation policy. | P0 |
| S9.9 | Audit log | "Audit log" | Administrative event history. | P0 |
| S9.10 | Templates & signatures | "Templates & signatures" | Canned responses, personal + org signatures. | P1 |
| S9.11 | Data & compliance | "Data & privacy" | Data export, org deletion, GDPR contact requests. | P1 |
| S9.12 | Delivery channels | "Delivery" | Channel list (built-in + external), add/edit SMTP relay or SES channel, health-check button, per-channel delivery stats, link to organization delivery log. | P1 |

## S10. Member preferences — *spec 10, 12*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S10.1 | Profile | "Your profile" | Username, display name. | P0 |
| S10.2 | Notification preferences | "Notifications" | Per-event toggles, digest mode, push opt-in. | P0 |
| S10.3 | Appearance | "Appearance" | Dark (default) / light theme, list density, default view. | P0 |
| S10.4 | Personal signature | "Your signature" | Per-From-address signatures. | P1 |

## S11. Agents — *spec 5.5, 14.3*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S11.1 | Agents list | "Agents" | Agentic users in the org, status. | P1 |
| S11.2 | Agent detail / config | "{agent name}" | Permission scope, approval mode, supervisor, credentials, MCP connection info. | P1 |
| S11.3 | Agent run log | "Agent activity" | Inputs consumed, actions, outcomes. | P2 |
| S11.4 | Agent limits | "Limits & budget" | Rate / token-spend limits. | P2 |

## S12. System & error screens

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S12.1 | Not found | "Page not found" | 404. | P0 |
| S12.2 | No access | "You don't have access" | Permission / Limited-Member boundary. | P0 |
| S12.3 | Billing past-due banner | (global banner) | Surfaces the billing grace period (spec 13.2.4) without cutting off mail. | P0 |
| S12.4 | Connection-lost indicator | (global) | Action Cable disconnect / reconnect state. | P0 |
| S12.5 | Generic error | "Something went wrong" | — | P0 |
| S12.6 | Upgrade required | "Upgrade to add this" | Shown when a Free-plan action hits a limit (2nd domain, 2nd collaborator); explains the limit and links to S8.3. Maps to spec 13.1.4. | P0 |

## S13. Help & onboarding aids — *spec 2.4.3*

| # | Screen | Title | Notes | Pri |
|---|--------|-------|-------|-----|
| S13.1 | Product tour overlay | (contextual) | Interactive first-use tour. | P1 |
| S13.2 | Diagnostics | "Is mail working?" | Re-runnable test-email diagnostic, reachable from settings. | P1 |

---

# Section G — Design System: Look & Feel

The visual language for all clients (web first, desktop and CLI reusing it where the medium allows).

## G1. Typography

| # | Standard | Pri |
|---|----------|-----|
| G1.1 | **Primary UI typeface: Apple San Francisco (SF Pro).** All interface text — navigation, lists, conversation content chrome, settings — uses SF Pro. | P0 |
| G1.2 | **Iconography: Apple SF Symbols (SF Icons)** — see F3. Icons and type come from the same family for visual coherence. | P0 |
| G1.3 | **Monospace / code typeface: a code font such as Fira Code or Hack** — used for technical information: raw email source and headers, IDs, API keys, DNS records, webhook payloads, rule expressions, audit-log detail. One code font is chosen and applied consistently. | P0 |
| G1.4 | The type system (sizes, weights, line-heights) is part of the design-token layer (F1.4); screens never hard-code type values. | P0 |
| G1.5 | Licensing/availability of SF fonts is confirmed for web embedding; if redistribution is constrained, an approved fallback stack is defined in the token layer. (Open item flagged for legal/build review.) | P1 |

## G2. Visual style

| # | Standard | Pri |
|---|----------|-----|
| G2.1 | Overall aesthetic: **neumorphic, technical, dark, modern, readable.** Dark is the primary theme (feature spec 12.1.2); light is a full alternative (12.1.3). | P0 |
| G2.2 | **Neumorphic** — soft, tactile surfaces using subtle dual-direction shadow and elevation tokens rather than hard borders. Elevation is a token set (F1.4); contrast is kept high enough to remain readable (G2.4), avoiding the low-contrast trap neumorphism can fall into. | P0 |
| G2.3 | **Technical** — the UI is comfortable showing technical detail (headers, IDs, rules, payloads) cleanly, using the code font (G1.3) to set that content apart. | P0 |
| G2.4 | **Readable** — readability is a hard constraint that overrides style: text contrast, hit targets, and focus states must meet the accessibility bar (feature spec 12.3.1) in both themes. Where neumorphic softness conflicts with contrast, contrast wins. | P0 |
| G2.5 | The look & feel is expressed entirely through the design-token layer and the component library, so it is consistent and themeable, and a future restyle is a token change. | P0 |

---

# Section H — Repository Structure

The codebase is organised into one repository (or a workspace) with the following top-level structure, matching the components in feature spec section 16.

| # | Path | Contents | Spec |
|---|------|----------|------|
| H1 | `api/` | The Rails JSON API (feature spec 16.3.2) — controllers, serializers/templates, models, the test suite. Implements all of Part A. | 16.3.2 |
| H2 | `ui/web/` | The React web application — implements Part B; contains the CSS architecture (F1), the component library and Storybook (F2), and the design tokens (G). | 12.2.1, 16.4.1 |
| H3 | `ui/desktop/` | The Tauri desktop client — wraps `ui/web` for macOS/Windows/Linux; additionally houses the local datastore and offline sync layer (feature spec 16.7). | 12.2.2, 16.4.2, 16.7 |
| H4 | `ui/cli/` | The Python/Textual CLI client. Consumes the same Part A API. | 12.2.4, 16.4.3 |
| H5 | `deploy/` | Infrastructure-as-code — Terraform files managing the Rancher / Kubernetes deployment. Details of how it works are to be filled in later. | 16.5 |

Notes: the Go MX and SMTP components, the NATS/JetStream queue, Rspamd, PostgreSQL, and the Garage object store (feature spec 16.2, 16.3, 16.5) are deployed services. Their service definitions sit outside the `api/` and `ui/` application code; `deploy/` (H5) holds the Terraform that provisions and manages them on Rancher/K8s.

---

## Part C — Coverage check

Every Part A and Part B item references at least one feature-spec item, satisfying the traceability needed for the > 95% spec-item test-coverage gate (feature spec 0.1, section 17). The cross-cutting standards add further per-item obligations: every Part A endpoint additionally carries the E1–E5 checklist (positive + negative tests, templated response, tenant-isolation test, minimal in/out, public IDs only), and every Part B screen is built under F1–F4 (CSS architecture, component-library-first, SF icon per section, full keyboard operability). Three intentional gaps to note for review:

- **C.1** Spec items 4.2.10 (conversation→task) and 9.1.7 (note reactions) are P2 and surfaced only minimally in the screen map; full screens are deferred.
- **C.2** The CLI and desktop clients (feature spec 12.2.2, 12.2.4) reuse this same API surface; this document maps only the React web app's screens, as requested.
- **C.3** SF font web-embedding licensing (G1.5) is an open item for legal/build review; an approved fallback stack is required if redistribution is constrained.

---

## Part D — Suggested build order

Aligned to the feature spec's release waves (feature spec section 19):

1. **Wave 1 (P0):** A1–A4, A6–A12, A14–A16, A18.1/A18.9 (delivery status reads) and S1–S6, S8–S10, S12 — auth, one organization, the pool, conversations, sending with per-message delivery tracking, routing rules, notes, notifications, spam, billing. A working single-domain email client. The MX/SMTP components ship in Wave 1 with their test, seed, and performance suites (feature spec 17.2–17.4) and email-standards conformance (feature spec section 18) — these are P0, not optional.
2. **Wave 2 (P1):** A5, A13, A17, A18.2–A18.8/A18.10 (external channels + delivery log) and S3 (switcher), S7, S9.12 (delivery channels), S11, S13 — agentic users and the MCP/agent surface, multi-organization chrome, templates, the developer surface, external delivery channels; plus desktop offline sync (feature spec 16.7).
3. **Wave 3 (P2):** remaining P2 endpoints and screens — custom roles/statuses, agent run-logs and limits, tasks, per-address/per-rule channel overrides.

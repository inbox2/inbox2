# SaaS Operations (platform admin)

The platform operator surface for running inbox2 as a SaaS: manage **every** org and
user across the whole tenant base from one place — create/block/wipe orgs, set
plans and mailbox limits, do org user management, initiate password resets, and
read account-wide metrics.

It is deliberately separate from the existing tenant "admin" surface
(`AdminController` / `AdminUsersController`), which is org owners/admins managing
*their own* domains. SaaS acts **across tenants** and is gated by network
controls, not by a user login.

**Since 2026-11-09 the production surface is the `operator` role** (`.pl.yaml`): a private role
with no public route, the only one with `SAAS_OPERATOR_PLANE=1`. `/api/v1/saas` is not routed on
the public `api` role, so nothing a request says (Host, port, headers) reaches it. The way in:

```sh
pl tunnel operator 4000 --production --local-port 4900
.venv/bin/inbox2-saas --origin http://127.0.0.1:4900 --mode header --client-cert "$DIR/client.pem" --client-key "$DIR/client.key"
```

`pl tunnel` needs the Pushleft Admin role, and that is the access control. The role sets
`SAAS_ALLOW_HEADER_AUTH=1`, so the fingerprint names the operator for the audit log.

> Phase 1 ships the **backend only**. The Python/Textual admin CLI and the
> nginx/Terraform mTLS wiring are deferred (see [Deferred](#deferred)).

## The Pushleft Admin page

The operator back office is the **Admin page of the Pushleft console**. It is served by the `api`
role under `/_pushleft/admin` (`admin: { role: api }` in `.pl.yaml`) and implemented in one
controller, `PushleftAdminController`, with its spec in `api/spec/requests/pushleft_admin_spec.rb`.
The protocol is Pushleft's App admin, version 1.

- **Who gets in.** A person signed in to Pushleft as Owner or Admin of the organization. Pushleft
  signs every request for that one request (ES256; the method, the path with its query string and
  the SHA-256 of the body are claims) and the controller verifies all of it against
  `PUSHLEFT_ADMIN_JWKS` and `PUSHLEFT_ADMIN_AUDIENCE`. Pushleft sets both on the role. Without
  them every path under the prefix answers 404. The app holds no secret.
- **What applies on the path.** Nothing of the app's own: no session, cookie, API key,
  organization scope, rate limit (safelisted in `config/initializers/rack_attack.rb`) or redirect.
  Pushleft's ingress also closes the path to every address but its control plane.
- **What it does.** Lists and shows users, organizations, memberships, domains, plans and the
  waitlist, with an overview of the dashboard counts. Writes are the ones `/api/v1/saas` has, through
  the same models and services: organization name, mailbox limit and disk quota as fields; Suspend,
  Unsuspend, Set plan and Wipe on an organization; Reset password, Disable, Enable and Offboard on a
  user; Remove on a membership; Invite on a waitlist signup. Creating an organization and adding a
  member are still only in `/api/v1/saas`.
- **Audit.** Each write is a `SaasAuditLog` row with no `admin_credential`; the person's Pushleft
  email is `metadata.operator` and the request id `metadata.request_id`.
- **Last sign-in.** `users.last_sign_in_at` is set when a session is created
  (`ApplicationController#create_session_for`). The users list sorts on it, newest first.

`/api/v1/saas`, the `operator` role and the terminal client below are unchanged.

## Auth model — client cert only

There is **no bearer/user auth** on this surface. Two gates, both in
`Api::V1::Saas::BaseController`:

1. **IP allowlist** (`enforce_ip_allowlist!`) — `request.remote_ip` must fall in
   `SAAS_IP_ALLOWLIST` (comma-separated CIDR list). Unset = allow all (dev
   convenience); **production must set it**. Matching uses `IPAddr` (same idiom as
   `PrivateAddressGuard`). For `remote_ip` to be the *real* client behind the
   ingress, `TRUSTED_PROXIES` must list the ingress/Cloudflare ranges
   (`config.action_dispatch.trusted_proxies`, set in `production.rb`).

2. **mTLS client certificate** (`authenticate_saas!`) — the
   TLS-terminating ingress verifies the client cert and passes it upstream as
   headers. We require `ssl-client-verify == SUCCESS` and look up
   `ssl-client-fingerprint` against an active `AdminCredential` (matched on the
   SHA-256 fingerprint). The credential row maps a verified cert to a named
   operator and records `last_used_at` / `last_used_ip`. Revoke by setting
   `revoked_at`.

   The ingress **must strip any client-supplied copies** of the `ssl-client-*`
   headers and set only its own verified values.

**Local/dev testing without a proxy:** when `SAAS_ALLOW_HEADER_AUTH` is set
(never in production), the `ssl-client-*` headers may be injected directly. In
production header-trust is always on (the ingress is the only hop).

```sh
# dev smoke (header-auth mode)
curl -H 'ssl-client-verify: SUCCESS' \
     -H 'ssl-client-fingerprint: <fingerprint>' \
     http://localhost:4000/api/v1/saas/dashboard
```

### Managing operators (`AdminCredential`)
One row per operator, keyed by cert fingerprint (`adm_…`). Fingerprints are
normalised (lowercased, `:` stripped, optional `sha256:` prefix removed) on write
and lookup, so any proxy format matches.

**Onboard an operator (runbook):**

```sh
# 1. Generate the operator's client cert (kept private, outside the repo).
DIR="$HOME/Library/Application Support/com.inbox2.saas"; mkdir -p "$DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$DIR/client.key" -out "$DIR/client.pem" -days 3650 \
  -subj "/CN=inbox2-saas-operator/O=inbox2"
chmod 600 "$DIR/client.key" "$DIR/client.pem"

# 2. Compute the fingerprint to store.
cd ui/admin-cli && .venv/bin/inbox2-saas fingerprint "$DIR/client.pem"

# 3. Create the credential on the API host (cluster: kubectl exec deploy/api -- …).
#    bin/rails runner:
#    AdminCredential.create!(label: "waseem", email: "waseem@…", cert_fingerprint: "<fp>")

# 4. Point the CLI at it (header mode until ingress mTLS lands):
.venv/bin/inbox2-saas --origin https://test-api.inbox2.com \
  --mode header --client-cert "$DIR/client.pem" --client-key "$DIR/client.key" --save
```

**Revoke:** `AdminCredential.find_by(label: "…").update!(revoked_at: Time.current)`.

**Deployed test env (status):** one operator (`label: waseem`) exists; access is
**fingerprint-only** — `SAAS_IP_ALLOWLIST` is unset and ingress mTLS is not yet
configured, so the fingerprint is effectively a bearer secret reachable from the
internet. Keep the cert/key private. `last_used_ip` currently records the
Cloudflare edge IP because `TRUSTED_PROXIES` is unset, so an IP allowlist won't
evaluate the true client until that (or ingress mTLS) is set up.

## Audit trail
Every mutating action writes a `SaasAuditLog` (`sal_…`) with the operator,
action (constants on the model), target public key + type, client IP, and a JSON
metadata blob. It is **separate** from the org-scoped `audit_logs` and stores the
target by *key* (not an association) so the row survives a hard wipe.

## Endpoints

All under `/api/v1/saas`. JSON via Alba serializers (`::Saas::*`),
errors via `ErrorSerializer`. Public IDs only (E5).

| Method & path | Purpose |
|---|---|
| `GET /dashboard` | Account-wide metrics (`Saas::DashboardMetrics`) |
| `GET /search?q=` | Type-to-search across orgs + users (≤10 each) |
| `GET /organizations?q=&page=&per_page=` | List/search orgs |
| `POST /organizations` | Create org (`owner_id` = user key) |
| `GET /organizations/:id` | Show org |
| `PATCH /organizations/:id` | Update name/slug/domain/timezone/language/`data_retention_days`/brand |
| `POST /organizations/:id/suspend` `…/unsuspend` | Operational block (`suspended_at`) |
| `DELETE /organizations/:id/wipe` | **GDPR hard wipe** — destroys the org + all dependents (cascade) |
| `GET /organizations/:id/usage` | Counts + attachment storage bytes |
| `POST /organizations/:id/plan` | Set/clear per-org plan (`plan: "Free"\|"Paid"\|"plan_…"\|"inherit"`) |
| `POST /organizations/:id/mailbox_limit` | `preset: single\|team\|unlimited` or `mailbox_limit: <int>\|null` |
| `GET/POST/DELETE /organizations/:id/members[...]` | Org user management (add invited / offboard) |
| `GET /users?q=` `GET /users/:id` | List/search/show users (all tenants) |
| `POST /users/:id/reset_password` | Issue token + send reset mail (via Messy) |
| `POST /users/:id/disable` `…/enable` | Disable/enable all memberships (+ revoke sessions) |
| `DELETE /users/:id/offboard` | Global offboard across every domain |
| `GET /waitlist_signups?q=&page=&per_page=` | List/search pre-launch prospects (name/email/company) |
| `GET /waitlist_signups/:id` | Show one prospect + everything they submitted |
| `POST /waitlist_signups/:id/invite` | Mint a single-use invite token + send the invite email (re-invitable) |

Reused services: `UserOffboarder`, `SessionRevoker`, `AdminOverview` patterns.

## Per-org plan & mailbox model

Billing was historically **per owner-user** (`Subscription belongs_to :user`). We
added a **per-org override**:

- `organizations.plan_id` — optional override. `Organization#effective_plan` =
  `plan || owner.subscription.plan || Plan.free`. The three former owner-plan call
  sites now read the org's effective plan: `members_controller`,
  `inbound_mail_processor` (spam-filter gate), `nats_subscriber` (inbound size).
- `organizations.mailbox_limit` — optional cap (a "mailbox" = an active
  membership). Presets in `Organization::MAILBOX_LIMIT_PRESETS`
  (`single`=1, `team`=5, `unlimited`=`Plan::UNLIMITED`).

**Enforcement precedence:** an explicit `mailbox_limit` override **supersedes**
plan gating and is enforced on every membership-creating path —
`members#invite`, `members#invite_mx`, `admin_users#assign`, and the SaaS
add (`Organization#mailbox_override_reached?`). With no override, the legacy
free-plan rule stands (Free = 1 collaborator, any paid plan = unlimited).

## Email (password reset)

Reset mail goes through **Messy** (`https://api.messy.sh`, the fixed default;
override with `MESSY_API_URL` if ever needed), ported from
`lalaaji-v3` as `MessyClient` (stdlib `net/http`, email-only) + `MessyTriggerJob`
(retrying Active Job). `PasswordResetService` issues the token
(`User#generate_reset_token!`) and enqueues the `password.reset` template with
`{ name, reset_url, token }`. The same service now also backs the public
`POST /auth/password/reset-request`.

> The `password.reset` template + its variables must exist on the Messy account
> the API key belongs to.

## Waitlist (invite-only signups)

Pre-launch, direct signups are gated behind a waitlist. The public, unauthenticated
form (`POST /api/v1/waitlist`, web `/waitlist`) captures a prospect — name, company,
email, industry + note, which email services (Gmail count, Office 365, free-form
others), and social business accounts. It is **bot-gated by Cloudflare Turnstile**
(`TurnstileVerifier`, a no-op when `TURNSTILE_SECRET` is unset) and **deduped on
email without leaking existence**: input is validated independently of existence and
the response is always `202` whether the email is new or already present (mirrors the
`reset_password_request` enumeration guard). A new signup enqueues an on-brand
notification email to `WAITLIST_NOTIFY_EMAIL`.

Operators browse + invite from the SaaS surface (`/waitlist_signups`, and the
admin-cli **Waitlist** screen — press `w`). `POST …/invite` calls
`WaitlistSignup#generate_invite_token!` (status → `invited`), audits
`SaasAuditLog::ACTION_WAITLIST_INVITE`, and sends the invite email with a link to
`{WEB_APP_URL}/signup?invite=<token>`.

Both emails are **raw on-brand HTML** rendered from in-repo ERB
(`app/views/waitlist_mailer/{admin_notification,invite}.html.erb`) and sent via
`MessyClient#send_message` (`WaitlistMailerService`) — so unlike `password.reset`,
the design lives in the repo, not on the Messy account.

Signup gating lives in `auth#signup`: when `INVITE_ENABLED`, a valid outstanding
invite token is required (email/display name taken from the waitlist row), and
redeeming it flips the row to `registered` + links the new `User`. Flip
`INVITE_ENABLED` off for the open prod rollout.

## Environment variables

| Var | Purpose |
|---|---|
| `SAAS_IP_ALLOWLIST` | CIDR allowlist for the surface (prod must set) |
| `SAAS_ALLOW_HEADER_AUTH` | Trust the `ssl-client-*` headers. **Opt-in in every environment since 2026-10-18** (production used to trust them unconditionally); unset = the operator plane is closed. Set only with `SAAS_IP_ALLOWLIST` + `TRUSTED_PROXIES`, or once ingress mTLS strips client copies. Terraform: `saas_allow_header_auth`, `saas_ip_allowlist`, `trusted_proxies` in `deploy/prod`. |
| `TRUSTED_PROXIES` | CIDR list of ingress/edge hops so `remote_ip` is the real client |
| `PUSHLEFT_ADMIN_JWKS` | Public keys (a JSON Web Key Set) that verify the Pushleft Admin page's requests. Set by Pushleft on the `api` role; unset = `/_pushleft/admin` answers 404 |
| `PUSHLEFT_ADMIN_AUDIENCE` | The `aud` those requests must carry (`<organization id>/inbox2/<environment>`). Set by Pushleft |
| `MESSY_API_KEY` | Messy transactional-email API key (secret_env) — the only required Messy var |
| `MESSY_API_URL` | Optional override; defaults to the fixed `https://api.messy.sh` |
| `WEB_APP_URL` | Base for the reset + invite links in the email |
| `INVITE_ENABLED` | Gate `auth#signup` to invite-only (default off) |
| `TURNSTILE_SECRET` | Cloudflare Turnstile server-verify secret (waitlist form); unset = no bot check |
| `TURNSTILE_SITE_KEY` | Turnstile site key, served to the SPA via `GET /waitlist/config` |
| `WAITLIST_NOTIFY_EMAIL` | Recipient of new-signup notifications (default `waseem@sadiq.nl`) |

## Admin CLI

`ui/admin-cli/` (package `inbox2_saas`, console script `inbox2-saas`) is a
Textual TUI over this API — catppuccin-themed, mirroring `ui/cli`. It connects by
TLS client cert: `--mode mtls` presents the cert (ingress injects the headers),
`--mode header` sends `ssl-client-verify`/`ssl-client-fingerprint` directly (dev,
or before ingress mTLS). `inbox2-saas fingerprint client.pem` prints the value to
store as `AdminCredential#cert_fingerprint`. Screens: dashboard, orgs list/detail
(suspend/plan/mailbox-limit/wipe/members), users list/detail (reset/disable/
enable/offboard), and a `ctrl+k` search palette. Config via flags →
`SAAS_API_ORIGIN`/`SAAS_MODE`/`SAAS_CLIENT_CERT`/… env → `saas_config.json`. See
`ui/admin-cli/README.md`.

## Deferred

1. **Replaced 2026-11-09 by the `operator` role (above).** Old plan, ingress mTLS — nginx `auth-tls-verify-client` / `auth-tls-secret`
   (CA-bundle K8s secret) / `auth-tls-pass-certificate-to-upstream` on a
   grey-cloud `ops-api.inbox2.com` host (so the TLS handshake reaches nginx
   instead of terminating at the Cloudflare edge), plus the `TRUSTED_PROXIES` /
   allowlist env in the Terraform config maps (see [docs/Deployment.md](Deployment.md)).
   Until it lands, gate the public surface with `SAAS_IP_ALLOWLIST` (bastion CIDR)
   before creating any `AdminCredential`, since production trusts the headers.

# Waitlist & invite-only signups

Pre-launch, direct self-serve signup is **blocked behind an invite-only waitlist**.
Prospects fill a public form; an operator invites them from the SaaS surface; the
invite email links them to a normal account-creation screen. The whole gate is a
single env flag (`INVITE_ENABLED`) so it flips off for the open prod rollout.

This doc covers the feature surface and — primarily — the **deployment / ops runbook**
(env vars, Cloudflare Turnstile, Terraform wiring, the prod apply procedure, and the
DB-table step). Operator-API detail also lives in [SaaS.md](SaaS.md).

---

## How it works

```
  mail.inbox2.com/waitlist ──POST /api/v1/waitlist──▶ WaitlistSignup (pending)
        (Turnstile-gated)                                    │
                                                             ├─▶ notify email → WAITLIST_NOTIFY_EMAIL
                                                             ▼
  admin-cli (press w) / SaaS API ──POST …/invite──▶ token + status=invited
                                                             │
                                                             ├─▶ invite email → prospect
                                                             ▼
  mail.inbox2.com/signup?invite=<token> ──POST /auth/signup (INVITE_ENABLED)──▶ User
                                                             ▼
                                                  WaitlistSignup → registered (linked)
```

- **Public form** — `POST /api/v1/waitlist` (no auth). Captures name, company, email,
  industry + note, which email services (Gmail count, Office 365, free-form others),
  and social business accounts. **Cloudflare Turnstile** bot-gate (`TurnstileVerifier`,
  a no-op when `TURNSTILE_SECRET` is unset). **Deduped on email without leaking
  existence** — input is validated independently of existence and the response is
  always `202`, new or not (same enumeration guard as `auth#reset_password_request`).
- **Signup gate** — `auth#signup`: when `INVITE_ENABLED`, a valid outstanding invite
  token is required; the account's email/display name come from the waitlist row, and
  redeeming the token flips the row to `registered` + links the `User`. With
  `INVITE_ENABLED` off, signup is open (today's behavior).
- **Operator** — SaaS `/waitlist_signups` (index/show/invite) and the admin-cli
  **Waitlist** screen (`w` to open, `i` to invite). Invite mints a single-use token,
  audits `SaasAuditLog::ACTION_WAITLIST_INVITE`, and sends the invite email.
- **Emails** — both the admin notification and the invite are **raw on-brand HTML
  rendered from in-repo ERB** (`app/views/waitlist_mailer/{admin_notification,invite}.html.erb`)
  and sent via `MessyClient#send_message` (`WaitlistMailerService`). Unlike
  `password.reset`, the design lives in the repo, not on the Messy account.

### Endpoints

| Method & path | Auth | Purpose |
|---|---|---|
| `POST /api/v1/waitlist` | public | Submit the form (Turnstile-gated; always `202`) |
| `GET /api/v1/waitlist/config` | public | `{ invite_enabled, turnstile_site_key }` for the SPA |
| `GET /api/v1/waitlist/invite?token=` | public | Prefill (`{ email, name }`) for the account-creation screen |
| `GET /api/v1/saas/waitlist_signups?q=` | mTLS | List/search prospects |
| `GET /api/v1/saas/waitlist_signups/:id` | mTLS | Show one + everything submitted |
| `POST /api/v1/saas/waitlist_signups/:id/invite` | mTLS | Mint token + send invite (re-invitable) |

### Source map

| Concern | Path |
|---|---|
| Model (status lifecycle, token, dedupe, `invite_only?`) | `api/app/models/waitlist_signup.rb` |
| Public endpoints | `api/app/controllers/api/v1/waitlist_controller.rb` |
| Signup gate | `api/app/controllers/api/v1/auth_controller.rb#signup` |
| SaaS operator endpoints | `api/app/controllers/api/v1/saas/waitlist_signups_controller.rb` |
| Turnstile verify | `api/app/services/turnstile_verifier.rb` |
| Email compose/send | `api/app/services/waitlist_mailer_service.rb` + `api/app/views/waitlist_mailer/*` |
| Web form + primitives | `ui/web/src/pages/auth/WaitlistPage.jsx`, `components/management/{MgmtSelect,MgmtStepper}.jsx` |
| Web signup gate | `ui/web/src/pages/auth/SignupPage.jsx` |
| admin-cli | `ui/admin-cli/inbox2_saas/{screens.py,api.py}` (Waitlist screen) |

---

## Environment variables

| Var | Where | Purpose | Default |
|---|---|---|---|
| `INVITE_ENABLED` | configmap (`var.invite_enabled`) | Gate `auth#signup` to invite-only | `true` |
| `TURNSTILE_SITE_KEY` | **secret**, written by Pushleft (`turnstile:` in `.pl.yaml`) | Public Turnstile key, served via `/waitlist/config` | `""` = no challenge |
| `TURNSTILE_SECRET` | **secret**, written by Pushleft (`turnstile:` in `.pl.yaml`) | Turnstile server-verify secret | unset = no challenge |
| `WAITLIST_NOTIFY_EMAIL` | configmap (`var.waitlist_notify_email`) | New-signup notification recipient | `waseem@sadiq.nl` |
| `WEB_APP_URL` | configmap (reused) | Base for the invite link (`…/signup?invite=`) | `https://app.inbox2.com` |
| `MESSY_API_KEY` | **secret** (reused) | Messy transactional-email key (already set for password reset) | — |

Pushleft makes the widget (its domains: the environment's custom domains plus `inbox2.com` and
`mail.inbox2.com`) and writes both keys. Both are unset
→ the form works with **no** bot challenge (graceful), so dev needs nothing.

---

## Cloudflare Turnstile setup

Wrangler cannot manage Turnstile (no `turnstile` command; its OAuth token lacks the
scope), so the widget is created by hand in the dashboard:

1. **Turnstile → Add widget**
2. **Hostnames:** `mail.inbox2.com` (add `localhost` to test the form locally)
3. **Widget mode:** Managed
4. Copy the **Site Key** (public) and **Secret Key**

Then wire them into the prod env (next section): site key → `turnstile_site_key`,
secret → `api_secret_env.TURNSTILE_SECRET`. The widget is bound to its hostname, so a key
pair only validates challenges served from `mail.inbox2.com`.

---

## Prod deployment

Prod is `inbox2-prod` (`api.inbox2.com` API in-cluster; `mail.inbox2.com` web on
Cloudflare Pages). Config is Terraform in `deploy/prod/` — non-secret env in
`local.rails_env` (configmap, `main.tf`); secret env in `var.api_secret_env` (the
**gitignored** `terraform.tfvars`). The same env is shared by `module.api`,
`module.worker`, and `module.nats_subscriber`.

### 1. Terraform wiring (committed)

`deploy/prod/variables.tf` declares `invite_enabled`, `turnstile_site_key`,
`waitlist_notify_email`. `deploy/prod/main.tf` adds them to `rails_env` — the Turnstile
site key is `merge`d in only when non-empty (an empty map value renders as `null` in the
configmap):

```hcl
rails_env = merge(var.turnstile_site_key == "" ? {} : { TURNSTILE_SITE_KEY = var.turnstile_site_key }, {
  # … existing env …
  INVITE_ENABLED        = tostring(var.invite_enabled)
  WAITLIST_NOTIFY_EMAIL = var.waitlist_notify_email
})
```

### 2. Secret + values (local, gitignored `terraform.tfvars`)

```hcl
turnstile_site_key = "0x4AAAA…"          # public Turnstile site key

api_secret_env = {
  # … existing secrets …
  TURNSTILE_SECRET = "0x4AAAA…"          # Turnstile secret key
}
# invite_enabled / waitlist_notify_email use their defaults (true / waseem@sadiq.nl).
```

> **Historical (Rancher, 2026-10).** Steps 3–4 below were the one-time rollout on the
> dead Rancher cluster. On Pushleft, env goes in `.pl.yaml` `env:`, secrets via
> `pl secrets set NAME --production`, and migrations run in the `release` role
> (see [Deployment.md](Deployment.md)).

### 3. Create the DB table on prod (one-time, additive)

The deploy is `kubectl set image` — it **does not create tables**. New tables (this one,
and any future one) must be added to the prod DB additively, preserving data (never
`db:schema:load` against prod):

```sh
export KUBECONFIG=deploy/prod/kubeconfig.yaml
POD=$(kubectl get pods -n inbox2-prod -l app=api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n inbox2-prod $POD -- bin/rails runner '
  unless ActiveRecord::Base.connection.table_exists?(:waitlist_signups)
    ActiveRecord::Schema.define { create_table("waitlist_signups", force: :cascade) { |t| ... } }
  end'
```

(Use the exact column/index block from `api/db/schema.rb`.)

### 4. Apply

Terraform no longer manages the running image (CI deploys by digest, and the
deployments ignore image changes; see [Deployment.md](Deployment.md#ci-vs-terraform-image-ownership)),
so there is nothing to re-pin before applying.

Then apply **only** the env-bearing resources (a `-target` apply avoids stripping the
Rancher `cattle.io` namespace annotations and the unrelated mx/ingress drift). Changing a
configmap does **not** restart pods — the deployment's `inbox2/config-hash` annotation
forces it, so target the deployment too:

```sh
cd deploy/prod
terraform apply -input=false -auto-approve \
  -target=module.api.kubernetes_config_map.env  -target=module.api.kubernetes_secret.env  -target=module.api.kubernetes_deployment.this \
  -target=module.worker.kubernetes_config_map.env -target=module.worker.kubernetes_secret.env -target=module.worker.kubernetes_deployment.this \
  -target=module.nats_subscriber.kubernetes_config_map.env -target=module.nats_subscriber.kubernetes_secret.env -target=module.nats_subscriber.kubernetes_deployment.this
```

### 5. Verify

```sh
curl -s https://api.inbox2.com/api/v1/waitlist/config
# → {"invite_enabled":true,"turnstile_site_key":"0x4AAAA…"}

curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.inbox2.com/api/v1/auth/signup \
  -d username=x -d password=password123
# → 422  (Signups are invite-only)

curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.inbox2.com/api/v1/waitlist \
  -d name=x -d email=x@example.com
# → 422  (Verification failed — Turnstile rejects a tokenless submit)
```

---

## Operations

**Invite a prospect** — `ui/admin-cli` (`inbox2-saas`), press `w` → select → `i`. Or
`POST /api/v1/saas/waitlist_signups/<key>/invite`. Re-inviting re-sends a fresh link.

**Go open (lift invite-only)** — set `INVITE_ENABLED: "false"` in `.pl.yaml` and push (was: tfvars + re-apply)
(step 4). `/auth/signup` immediately accepts again and the web `/signup` shows the normal
form (it reads `/waitlist/config` on load).

**Rotate / disable Turnstile** — change `turnstile_site_key` + `TURNSTILE_SECRET` and
re-apply. Clearing both disables the challenge without code changes.

**Funnel** — the marketing landing page (`website/index.html`) CTAs point to
`mail.inbox2.com/waitlist`; the web `/signup` route self-gates via `/waitlist/config`.

> See [project memory `project_prod_tf_envvar_apply`] for the image-pin trap and the
> targeted-apply recipe, and [SaaS.md](SaaS.md) for the operator-API auth model.

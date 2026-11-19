# inbox2-saas — SaaS operations TUI

A Textual terminal client for the platform **SaaS ops** API (`/api/v1/saas`):
dashboard metrics, type-to-search across orgs/users, and org/user management
(suspend, plan, mailbox limit, GDPR wipe, members, password reset, disable,
offboard). Catppuccin-themed, mirrors `ui/cli`. See `docs/SaaS.md` for the API.

Intended to run over an SSH bastion against the IP-allowlisted SaaS endpoints.

## Install

```sh
cd ui/admin-cli
python -m venv .venv && .venv/bin/pip install -e ".[test]"
```

## Auth

The SaaS API authenticates by **TLS client certificate** (mapped to an
`AdminCredential` by SHA-256 fingerprint). Two transports:

- **`--mode mtls`** (production): present the cert; the ingress verifies it and
  injects the `ssl-client-*` headers. Needs the ingress mTLS to be configured.
- **`--mode header`** (dev, or before ingress mTLS exists): send the verified
  headers directly — only works where the backend trusts them
  (`SAAS_ALLOW_HEADER_AUTH` locally, or production until mTLS lands).

Find your fingerprint (the value to store as `AdminCredential#cert_fingerprint`):

```sh
.venv/bin/inbox2-saas fingerprint client.pem
```

Then seed it once on the API host:

```ruby
AdminCredential.create!(label: "waseem-bastion", email: "waseem@…", cert_fingerprint: "<fingerprint>")
```

## Run

```sh
# mTLS against the deployed env
inbox2-saas --origin https://test-api.inbox2.com \
            --mode mtls --client-cert client.pem --client-key client.key

# header mode against local Rails (SAAS_ALLOW_HEADER_AUTH=1)
inbox2-saas --origin http://localhost:4000 --mode header --client-cert client.pem

# persist the connection so future runs need no flags
inbox2-saas --origin … --mode mtls --client-cert … --save
```

Config resolution: CLI flag → env (`SAAS_API_ORIGIN`, `SAAS_MODE`,
`SAAS_CLIENT_CERT`, `SAAS_CLIENT_KEY`, `SAAS_CA_BUNDLE`, `SAAS_FINGERPRINT`) →
`<data_dir>/saas_config.json` → default.

## Keys

| Screen | Keys |
|---|---|
| Global | `ctrl+k` search · `q` quit |
| Dashboard | `o` orgs · `u` users · `r` refresh |
| Orgs / Users list | `/` filter · `enter` open · `r` refresh · `esc` back |
| Org detail | `s` suspend · `p` plan · `m` mailbox limit · `a` add member · `x` remove member · `w` wipe · `r` refresh |
| User detail | `r` reset password · `d` disable · `e` enable · `o` offboard |

## Test

```sh
.venv/bin/pytest
```

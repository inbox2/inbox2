# Mail Deliverability

How inbox2 makes outbound mail *trusted* (so it lands) and *learns when it doesn't*
(so reputation is protected). This is the layer on top of the raw send path in
[MX-Inbound.md](MX-Inbound.md) (inbound) and `mta/cmd/smtp` (outbound delivery).

```
Compose → OutboundMailPublisher → NATS MAIL_OUTBOUND → Go sender (DKIM sign, MX, STARTTLS)
                │                                              │
       suppression check                               MAIL_DELIVERY_STATUS
                                                               ↓
                                          NatsSubscriber → DeliveryRetryService → suppression
Inbound DSN/ARF → InboundMailProcessor → InboundReportRouter → DeliveryStatus + suppression
```

## Prod deployment of the sender

Until 2026-10-07 the Go sender was never deployed: `MAIL_OUTBOUND` had no
consumer and every MX send sat at `queued` forever. It now runs as the `smtp`
deployment (`deploy/prod/main.tf`, the worker module with `command = ["/smtp"]`)
from the same image as the MX receiver (`mta/Dockerfile` builds both binaries);
CI rolls it with the mx digest. (That was Rancher; on Pushleft it is the `mail`
role, below.)

- **Egress**: since the Pushleft move (2026-11) `mx` and `smtp` run together as
  the `mail` role (`.pl.yaml`) on the failover IP `138.201.227.97`, which is in
  `_spf.inbox2.com` and has PTR `mx.inbox2.com`; `SMTP_DOMAIN` (EHLO) is
  `mx.inbox2.com`, so forward-confirmed rDNS holds. (On Rancher it sent from
  `168.119.64.32`, PTR `rancher-node-0.erip.me`.)
- **Spamhaus sender guidelines** (checked 2026-11-17): the EHLO name carries
  its own SPF (`mx.inbox2.com TXT v=spf1 ip4:138.201.227.97 -all`), apex DMARC
  is `p=quarantine`, and `https://mx.inbox2.com` answers 301 → inbox2.com with
  a Let's Encrypt certificate. The `mx-web` role in `.pl.yaml` answers the 301;
  the route is the custom-domain claim `pl domain add mx.inbox2.com --role
  mx-web` (deliberately not `route.domains`), served by the node's ingress on
  80/443 of the same IP. The A record stays DNS-only for SMTP.
- **DKIM**: `DKIM_PRIVATE_KEY` is a Pushleft secret (from `deploy/dns` state,
  the key behind `inbox2._domainkey.inbox2.com`).
- **Payload size**: the whole MIME rides base64 inside the job JSON (~1.8× the
  attachments). NATS `max_payload` is raised to its 64MB ceiling via a mounted
  config file (`deploy/modules/nats`); the 1MB default failed any send with an
  attachment over ~700KB.
- **Not wired yet**: `SMTP_DELIVERY_PRIVATE_KEY` (sealed E2EE domains can't
  send until the deliverykey pair is generated) and `SMTP_WARMUP_START`.

## DKIM signing (central key)

inbox2 uses **one platform keypair**, not a keypair per org. Every connected
domain publishes a CNAME that delegates DKIM to the service domain:

```
<selector>._domainkey.<org-domain>  CNAME  <selector>._domainkey.inbox2.com
```

So the public key lives once at `inbox2.com`, and a single private key signs for
every org with `d=<org domain>` — which keeps DMARC alignment (the From-header
domain equals the DKIM `d=` domain) without per-org provisioning.

| Piece | Where |
|-------|-------|
| Key accessor | `DkimKey` (`app/services/dkim_key.rb`) — reads `DKIM_PRIVATE_KEY` (PEM, `\n` escapes allowed), selector from `DKIM_SELECTOR` (default `inbox2`) |
| Key generation | `bin/rails dkim:generate` — prints the private key + the DNS TXT record to publish |
| Outbound wiring | `OutboundMailPublisher#build_payload` puts `{domain, selector, private_key_pem}` in the NATS payload; the Go sender signs in `maybeSign` (`mta/internal/outbound/sender.go`) |
| DNS records shown to users | `DnsRecordsSerializer` emits the delegating CNAME |

**Operational setup:** run `dkim:generate`, set `DKIM_PRIVATE_KEY` on both the API
(`api`) and the SMTP sender (`mta/cmd/smtp`), and publish the printed TXT at the
CNAME target. Without a key, mail still composes and sends — just **unsigned**
(the `private_key_pem` field is empty and the Go signer skips signing).

The Go sender can alternatively load keys from `SMTP_DKIM_KEY_DIR`; a local key
there wins over the payload key.

## Suppression list

`SuppressionEntry` (`app/models/suppression_entry.rb`) is the list of addresses
inbox2 must not send to. Sending to a dead or complaining address is what wrecks
sender reputation, so the list is enforced **before** queueing and populated from
every failure signal.

| Reason | Source |
|--------|--------|
| `hard_bounce` | DSN with a 5.x.x status (`InboundReportRouter`) |
| `complaint` | ARF feedback report (`InboundReportRouter`) |
| `permanent_failure` | SMTP 5xx that is address-shaped — 5.1.x / 550-553 only (`DeliveryRetryService`); content/policy rejections do **not** suppress |
| `manual` | reserved for an admin UI |

- Enforcement: `OutboundMailPublisher#publish` drops suppressed recipients; if
  **all** recipients are suppressed it marks the `DeliveryStatus` failed with a
  `suppressed: …` diagnostic and never touches NATS.
- `SuppressionEntry.record!` is idempotent and never *downgrades* a reason
  (a later soft signal won't overwrite a hard bounce), but refreshes the detail.
- Uniqueness is `(organization_id, address)`, addresses normalized lowercase.

## Bounce & complaint processing (inbound reports)

DSN bounces (RFC 3464) and ARF complaints (RFC 5965) arrive at the MX like any
other mail, addressed to the envelope sender we used. `InboundMailProcessor`
hands every inbound message to **`InboundReportRouter`** first:

- It detects `multipart/report; report-type=delivery-status|feedback-report`
  from the Content-Type.
- **Bounce** → parse via `DsnBounceParser`, match the originating `DeliveryStatus`
  (by returned Message-ID, else by recipient within a 30-day window), update it
  to `bounced`/`failed`, and suppress the address on a hard bounce.
- **Complaint** → suppress the complaining recipient (`Original-Rcpt-To`).
- Either way the router returns a symbol and the processor **skips normal
  threading** — reports never become user-visible conversations.

Synchronous SMTP-time failures (the remote MTA rejects during the session) come
back over `MAIL_DELIVERY_STATUS` and are handled separately by
`DeliveryRetryService`. The router handles the *asynchronous* bounces that arrive
minutes/hours after a 250-acceptance.

## Retry & delivery state

- **One `DeliveryStatus` per DESTINATION, not per message.** A destination is a
  recipient domain for the builtin MTA, or the ESP itself (`destination:
  "esp:<kind>"`) for a BYO-ESP channel, which fans out to every domain on its
  own. `OutboundMailPublisher#publish` groups the envelope recipients by domain
  and queues one NATS job per group, returning one row per destination.

  Why: a queued job is only safe to retry while it maps to exactly one SMTP
  envelope. The Go sender does a single MX lookup (`rcpt_to[0]`'s domain) and
  RCPTs every address to that one host, and `sendEnvelope` aborts the whole
  envelope on the first rejection — so a mixed-domain job used to fail for
  *everyone* (the far MX rejects the foreign addresses as relaying), and any
  scheme that delivered to several destinations under one row would duplicate
  mail for the recipients who already received it whenever the job retried.

- `published_at` is stamped only after the NATS publish (or ESP handoff)
  returns. A row that exists but was never published is a **failed publish**, and
  `OutboundDeliveryJob` re-publishes it — it does not read the row's mere
  presence as "already sent". That guard used to swallow every failure silently:
  the row is written before the publish is attempted, so the ActiveJob retry
  returned early, nothing reached the failed-jobs table, and the message sat at
  `queued` forever while the UI said Sent. See the 2026-09-09 note below.
- `DeliveryStatus` states: `queued, sending, delivered, failed, bounced, deferred`.
- `DeliveryRetryService` — 5 retries, exponential backoff (1/2/4/8/16 min). The
  retry timer is owned solely by the NATS status consumer
  (`OutboundRetryJob.set(wait:)`), so there's one source of truth.
- `OutboundRetryJob` re-publishes onto the **existing** `DeliveryStatus`
  (`publish(delivery_status:)`) so attempt history accrues on one record instead
  of spawning a new status per retry. On that path the publisher re-sends only
  **that row's** recipients — never the full list, which by then may include
  people who already received the mail.
- Bounce matching (`InboundReportRouter#match_delivery_status`) prefers the
  destination row whose envelope actually held the bounced address. Matching on
  `messages.to_address` alone never matched a cc'd recipient and could never
  match a bcc'd one (there is no Bcc header to return).

### 2026-09-09: outbound had never worked in production

Two bugs, one masking the other:

1. `ensure_stream` called `js.find_stream_by_subject`, which nats-pure does not
   have (it is `find_stream_name_by_subject`). The `NoMethodError` fired *past*
   the `NATS::JetStream::Error::NotFound` rescue, so `MAIL_OUTBOUND` was never
   created and every publish raised.
2. `OutboundDeliveryJob`'s idempotency guard (`return if
   message.delivery_status.present?`) then made the ActiveJob retry a no-op,
   because the row had already been created before the publish was attempted. No
   failed job, no notification, no user-visible error — the message just stayed
   `queued`.

The publisher spec had stubbed NATS with a loose `double(find_stream_by_subject:
true, publish: true)`, which answered the typo happily. It now stubs a **real**
`NATS::JetStream` instance so `verify_partial_doubles` rejects any method the gem
does not have. (An `instance_double` cannot work here: the gem `extend`s its
`Manager` module per instance inside `initialize`, so the class defines none of
the stream methods.)

**Still open:** `mta/Dockerfile` builds only `cmd/mx`, and there is no image, CI
job or k8s deployment for `cmd/smtp` — so nothing consumes `mail.outbound.>` in
prod yet. Publishing works again; delivery needs the sender deployed.

## Cloudflare one-click DNS setup

Manual DNS entry is the #1 setup failure (records added in the wrong zone, or a
**proxied** DKIM CNAME that resolves to Cloudflare's edge IPs so DKIM never
verifies). When a domain's nameservers are Cloudflare (`DnsResolver#ns` →
`*.ns.cloudflare.com`, surfaced as `provider: "cloudflare"` on `GET …/domains/:id/dns`),
the setup UI offers **Auto-configure**: the admin pastes a scoped **Zone · DNS ·
Edit** API token, and `POST …/domains/:id/dns/cloudflare` (`CloudflareDns`) writes
all four required records into the zone, then re-verifies.

- Single source of truth: `DnsRecordsSerializer.required_records` feeds the setup
  table, `DnsChecker`, AND the Cloudflare writer — they can't drift.
- Idempotent upsert: MX/DKIM enforced, SPF **merged** into any existing `v=spf1`
  record, DMARC created only if absent (never clobber a custom policy).
- The DKIM CNAME is forced `proxied: false` (DNS-only) — the whole point.
- The token is used transiently (never stored). Non-Cloudflare domains fall back
  to the manual records table. Shared across onboarding, the console Verify modal,
  and the domain-settings DNS tab via `DnsVerify`.

## receiving_mail promotion

An org's status flows `pending_dns → verified → receiving_mail`. `DnsCheckJob`
deliberately never sets `receiving_mail`; the **inbound pipeline** promotes a
`verified` org the first time real mail flows through
(`InboundMailProcessor#promote_receiving_mail`). The transition is one-way until
DNS breaks.

## TLS / standards endpoints

| Standard | Status |
|----------|--------|
| **MTA-STS** (RFC 8461) | Policy **served** at `mta-sts.<domain>/.well-known/mta-sts.txt` (`WellKnownController#mta_sts`, resolved from the request Host). Outbound *enforcement* (the Go sender fetching + honoring recipient policies) is still TODO. |
| **DANE / REQUIRETLS** | Enforced on outbound today (`mta/internal/dane`, `mta/internal/requiretls`). |
| **ARC** (RFC 8617) | `ArcHeaderService` produces real RSA-SHA256 signatures (relaxed canonicalization, central key). Not yet wired into a forwarding path. |
| **TLS-RPT** (RFC 8460) | DNS record generation only — no report ingestion yet. |
| **DMARC `rua`** | We publish `rua=mailto:dmarc@inbox2.com` but do not yet ingest aggregate reports. |

## Outbound send throttling (reputation-based)

`SendQuota` (`api/app/services/send_quota.rb`) caps how much mail an org may
push through **our own SMTP**. Two classes of external sending are
deliberately unlimited: client-side channels (Gmail/O365/IMAP never touch
this API), and orgs whose active default `DeliveryChannel` is a
customer-owned ESP (SendGrid/SES/Mailgun/Postmark/Messy/smtp_relay) — the
quota checks `DeliveryChannel.active_for` and stands down, since those sends
spend the customer's provider reputation, not our shared IP. The goal is that
a fresh signup can't burn the shared sending IP / domain reputation.

Tiers combine **account age** and a **track record of real delivered mail**
(lifetime `DeliveryStatus` rows in `delivered` — bounces don't count). Age
alone never earns volume; both conditions must hold. At 6 months the org is
unconditionally unlimited.

| Tier | Age ≥ | Delivered ≥ | Hourly | Daily | Max rcpt/msg |
|------|-------|-------------|--------|-------|--------------|
| new account | 0 | 0 | 15 | 125 | 10 |
| 1+ week | 1w | 25 | 50 | 400 | 25 |
| 1+ month | 1m | 150 | 150 | 1,200 | 50 |
| 3+ months | 3m | 750 | 400 | 4,000 | 100 |
| established | 6m | — | ∞ | ∞ | ∞ |

Windows count **recipients** (to + cc, min 1/message) of outbound non-draft
messages at *acceptance time* (a slow queue must not grant extra headroom).
Enforced with **429** before any row is written at all three send
entry points: `MessagesController#create`, `#schedule` (checked when the
draft is promoted), and MCP agent `send_reply`. Specs:
`spec/services/send_quota_spec.rb` + `spec/requests/api/v1/send_throttle_spec.rb`.

## Hardening layer (TODO §46 — built 2026-07)

The former "remaining roadmap" is done; the load-bearing knobs:

1. **MTA-STS outbound enforcement** (`mta/internal/mtasts`) — TXT discovery +
   HTTPS policy fetch, cached per `max_age` (stale policy survives a fetch
   outage; no-policy is negative-cached 10 min). In `enforce` mode the sender
   only delivers to policy-matching MX hosts over PKIX-verified TLS; any
   downgrade is a transient failure, never a cleartext send.
2. **TLS-RPT + DMARC `rua` ingestion** — `InboundReportRouter` detects both
   (TLS-RPT: `multipart/report; report-type=tlsrpt`, JSON/gzip; DMARC: a
   zip/gz/xml attachment with a `<feedback>` root) and stores `MailAuthReport`
   rows (reporter, window, total/failure counts, jsonb summary; resends dedupe
   on report id). Admins read them at
   `GET /orgs/:org/deliverability/auth-reports` (`?failures_only=1`).
3. **IP reputation** (`mta/internal/outbound/reputation.go`) — startup
   FCrDNS/PTR self-check (`SMTP_PUBLIC_IP`, log-only), a warmup daily send
   budget ramping 50→25000 over four weeks (`SMTP_WARMUP_START=YYYY-MM-DD`;
   in memory, so a restart hands out the day's budget again,
   checked *before* job fetch so no message ages against AckWait), and
   per-recipient-domain concurrency + rate pacing
   (`SMTP_DOMAIN_CONCURRENCY`=4, `SMTP_DOMAIN_RATE`=60/min; a 2-min acquire
   timeout transient-fails back to Rails backoff).
4. **Prometheus metrics** (`mta/internal/metrics`) — counters on
   `MX_METRICS_ADDR` / `SMTP_METRICS_ADDR` `/metrics`: connections, rejects by
   reason, accepted messages/bytes, deliveries by result, throttle timeouts.
5. **Delivery-failure notifications** — `delivery_failure` `Notification` kind;
   `DeliveryFailureNotifier` (sender mailbox owner + assignees) fires from a
   `DeliveryStatus` callback on first entry into failed/bounced.
6. **MX-edge spam defense** (`mta/internal/smtpd/edge.go`) — opt-in DNSBL
   rejects (`MX_RBL_ZONES`, needs a dedicated resolver/DQS key), per-IP
   new-connection rate limit, and greylisting of first-contact
   (net/from/rcpt) triples from PTR-less clients (2-min delay, /24 & /64
   bucketing, 7-day approval; `MX_GREYLIST=off` to disable).

## First message from pfase.com went to Gmail spam (2026-11-11)

One test message from a domain added that day, from the unwarmed IP, landed in
Gmail's spam folder with `spf=pass`, `dkim=pass` and `dmarc=pass`. So
authentication was not the cause. What was wrong on our side: every outbound
message carried `List-Unsubscribe` and `List-Unsubscribe-Post`, which marks a
person's own mail as list mail. That is removed (`OutboundMailPublisher`).
What is left is reputation: an IP with no sending history and a domain with
none either. The warm-up, and people marking mail as not spam, are what move
that. Google Postmaster Tools is not set up for any sending domain yet.

## Relay for Pushleft customer mail (built 2026-11-11, off in prod)

Pushleft sends its customers' mail through inbox2's IP (`138.201.227.97`), so
one IP is warmed and watched. `mta/internal/outbound/relay.go`, started by
`cmd/smtp`.

- **Shape**: implicit-TLS SMTP submission with `AUTH PLAIN`, one recipient per
  transaction. On `DATA` the relay delivers to the recipient's MX while the
  client waits, and the `DATA` reply is the remote MX's own code and text
  (its 250 included), ending in ` [remote <mx-host>]`. Pushleft treats only a
  marked reply as the recipient's answer; an unmarked one (530, 535, size,
  451) is the relay's own. One transaction gets 150 s in total, under
  Pushleft's 180 s client timeout, so a late answer cannot cause a resend.
  There is no queue, so inbox2 never accepts a message and bounces it later:
  retries and bounce handling stay with pushleft-mail. Late bounces are DSNs
  from the remote to Pushleft's VERP address, directly.
- **Unchanged in transit**: no DKIM signing, no `Received` header, envelope
  sender kept (`relay_test.go` checks the bytes).
- **Not a remote verdict → 451**: MX unreachable, per-domain pacing, a cap.
- **Caps**: the warm-up budget is shared with inbox2's own mail. During the
  warm-up one customer (envelope-sender domain, `pl-bounces.` stripped) gets a
  quarter of the day's budget. After day 28 there are no caps.
- **Off switch**: no `RELAY_PASSWORD`, no listener.
- **Env**: `RELAY_PASSWORD`, `RELAY_USER` (`pushleft`), `RELAY_LISTEN`
  (`:4650`), `RELAY_TLS_CERT` + `RELAY_TLS_KEY` (required; the relay will not
  take the credential in the clear), `RELAY_DOMAIN` (greeting name).

Switched on 2026-11-11 (`.pl.yaml`, mail role):

- Pushleft issues and renews the certificate for `mx.inbox2.com`
  (`certificates:` on the role; files under
  `/run/secrets/certificates/mx.inbox2.com/`) and restarts the role with it.
- `RELAY_PASSWORD` is a secret on the role. Public port 4465 forwards to the
  relay (`RELAY_LISTEN` `:4650`). Not 465: mail clients expect submission
  there (docs/Mail-Clients.md).
- **The relay takes no mail until `SMTP_WARMUP_START` is set.** With no start
  date every relay send answers 451: an IP that was never warmed must not
  carry a customer's volume uncapped. Set it on the mail role to day 1 of the
  ramp, the day Pushleft's mail service goes live. It also starts the cap on
  inbox2's own mail.
- Pushleft's side: firewall for 4465, `include:_spf.inbox2.com` on its bounce
  domain, the `?passthrough=true` relay mode (a 5xx is the recipient's answer,
  180 s timeout), and the Vault entry `platform/mail/esp-relay#url`.

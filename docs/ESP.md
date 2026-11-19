# ESP: sending mail through the API

An application sends mail with one HTTP call and reads back what happened to
each recipient. API sends have their own log. They never become conversations,
so they never reach the domain's inbox or a client's sync.

Decisions and their dates: [plans/esp.md](plans/esp.md). Spec items: Feature-Spec 21.

## For the calling application

### What to ask the inbox2 admin for

1. A **sending key** (`isk_…`). It belongs to the organization, not a person.
   It is shown once.
2. A **domain to send from**: a domain the organization hosts on inbox2, or a
   send-only domain the admin has added and verified.

### Send

```
POST https://api.inbox2.com/api/v1/esp/emails
Authorization: Bearer isk_…
Idempotency-Key: order-1042-receipt        (optional)
Content-Type: application/json

{
  "from": "Acme <billing@acme.com>",
  "to": ["jane@example.com"],
  "cc": [], "bcc": [],
  "reply_to": "support@acme.com",
  "subject": "Your receipt",
  "text": "Thanks for your order.",
  "html": "<p>Thanks for your order.</p>",
  "headers": { "X-Order": "1042" },
  "tag": "receipt",
  "metadata": { "order_id": "1042" },
  "attachments": [
    { "filename": "receipt.pdf", "content_type": "application/pdf", "content": "<base64>" }
  ]
}
```

`202 Accepted`:

```
{ "email": {
    "id": "em_…", "from": "Acme <billing@acme.com>", "to": ["jane@example.com"],
    "subject": "Your receipt", "tag": "receipt", "metadata": { "order_id": "1042" },
    "message_id": "<…@acme.com>", "size_bytes": 1830, "created_at": "…",
    "deliveries": [ { "id": "ed_…", "recipient": "jane@example.com", "status": "queued", … } ]
} }
```

Rules:

- `from` names exactly one address. `to` is required; `text` or `html` is required. At most 50 recipients over
  to, cc and bcc together. The message may be at most 10 MB.
- Each recipient is one delivery with its own status. Bcc recipients are in the
  envelope only, never in the message.
- With an `Idempotency-Key`, a repeated request returns the first send with
  `200` and sends nothing.
- Custom headers may not be `From`, `To`, `Subject`, `Message-ID`, `Reply-To`,
  `DKIM-Signature`, `Received`, `Return-Path`, any `Content-*` header, or
  contain a line break.
- A recipient that bounced or complained before is not sent to. Its delivery
  comes back `failed` with a reason.

| Status | Meaning |
|---|---|
| 401 | No key, a wrong key, or a revoked key |
| 403 | The From domain is not this organization's, not verified, or sealed; or the plan has no API sending |
| 413 | Message larger than 10 MB |
| 422 | A field is missing or invalid; the body says which |
| 429 | Monthly allowance reached, or more than 600 sends a minute on one key |

### Read

`GET /api/v1/esp/emails` (paged, `?tag=`) and `GET /api/v1/esp/emails/:id`.
The single read adds `events`.

### Delivery statuses

| Status | Meaning |
|---|---|
| `queued` | Accepted, not yet attempted |
| `sending` | Handed to the mail queue for one attempt |
| `delivered` | The recipient's mail server accepted it |
| `deferred` | A temporary failure; it will be retried, up to five attempts over about half an hour |
| `bounced` | The recipient's server refused it for good, at once or in a later bounce |
| `failed` | Retries ran out, the address is suppressed, or a later report said delivery failed |
| `complained` | The recipient marked it as spam |

### Webhooks

The admin adds a webhook in the console and subscribes it to any of
`email.delivered`, `email.deferred`, `email.bounced`, `email.failed`,
`email.complained`. Each event is a POST:

```
X-Inbox2-Event: email.bounced
X-Inbox2-Signature: sha256=<HMAC-SHA256 of the body with the webhook secret>

{ "id": "ev_…", "type": "email.bounced", "email_id": "em_…",
  "recipient": "jane@example.com", "tag": "receipt", "metadata": { "order_id": "1042" },
  "detail": { "smtp_code": "550", "response": "5.1.1 no such user", "mx_host": "…", "attempt": 1 },
  "created_at": "…" }
```

A 5xx or 429 answer is retried five times; any other non-2xx is dropped.

## For the inbox2 admin

All under `/api/v1/orgs/:org/esp`, admins only. The console page is `/console/sending` (`ui/web/src/pages/admin/ConsoleSending.jsx`): this month's use, sending keys, send-only domains with a DNS check, and the send log.

| Call | Does |
|---|---|
| `GET keys`, `POST keys {name}`, `DELETE keys/:id` | List, create (token returned once), revoke |
| `GET domains`, `POST domains {domain}`, `POST domains/:id/verify`, `DELETE domains/:id` | Send-only domains |
| `GET emails`, `GET emails/:id` | The send log (`?tag=`, `?status=`) |
| `GET usage` | This month's sends against the allowance |

A **send-only domain** hosts no mail on inbox2: no MX, no mailboxes, no inbox.
It needs one DNS record, the DKIM CNAME the API returns in `records`. The
DMARC record is recommended. It does not count against the plan's domain limit.

## How it works

```
POST /esp/emails ─▶ Esp::Send ─▶ esp_messages (the composed message)
                              └▶ esp_deliveries (one per recipient) ─▶ Esp::DeliverJob
Esp::Publisher ─▶ NATS MAIL_OUTBOUND ─▶ Go sender (DKIM d=From domain) ─▶ recipient MX
Go sender ─▶ NATS MAIL_DELIVERY_STATUS ─▶ NatsSubscriber (key starts "ed_") ─▶ Esp::Delivery#record_result!
late bounce ─▶ MX ─▶ InboundMailProcessor (rcpt at the bounce domain) ─▶ Esp::BounceProcessor
every status change ─▶ esp_events ─▶ EspWebhookJob for subscribed webhooks
```

- **Tables**: `esp_keys`, `esp_domains`, `esp_messages`, `esp_deliveries`,
  `esp_events`. Models under `Esp::` (`api/app/models/esp/`).
- **One delivery per recipient.** The Go sender does one MX lookup per job,
  and a job that maps to one envelope is safe to retry.
- **Bounce address.** Each delivery leaves from `b+<token>@bounces.inbox2.com`
  (`ESP_BOUNCE_DOMAIN`). `NatsSubscriber#handle_domain_lookup` accepts that
  domain for the MX; it belongs to no organization.
- **DMARC** passes on DKIM: the central key signs with `d=` the From domain.
  The envelope sender is on the shared bounce domain, so SPF passes but is not
  aligned with the customer's domain.
- **One attempt, one verdict.** A job claims a delivery before it publishes
  (`Esp::Delivery#claim!`), so two jobs for one delivery send once. The key
  the Go sender echoes back is `<delivery key>:<attempt number>`; a verdict
  for any other attempt, or for a delivery that is no longer in flight, is
  dropped. NATS redelivers, and this is what keeps a repeat from counting
  twice or overwriting a settled delivery.
- **Nothing accepted is stranded.** A repeated request with the same
  `Idempotency-Key` queues again whatever never reached the mail queue, and
  `Esp::RequeueJob` does the same every five minutes for deliveries that have
  waited 20 minutes with no job. It also takes back a claim whose job died
  before publishing, and fails a delivery that was published and got no
  verdict in 73 hours, after which the mail queue no longer holds it.
- **Suppression** is the organization's existing list (`SuppressionEntry`).
- **Allowance**: `Plan::ESP_MONTHLY_SENDS`, counted as deliveries created in
  the calendar month. It is checked and spent under one lock per organization,
  so concurrent sends cannot both fit into the last of it.
- **Stored message**: `esp_messages.raw_mime`, in Postgres, dropped after 30
  days by `Esp::PurgeJob`. The log row stays. A retry after that cannot happen;
  retries end within the hour.
- **Warm-up**: ESP mail shares the daily budget and per-domain pacing in
  `mta/internal/outbound/reputation.go` with everything else on the IP.

## Not built

- Open and click tracking for API sends.
- Complaints: a feedback report is matched to an API send only when it arrives
  at a domain of the same organization. inbox2 is not registered with any
  mailbox provider's feedback loop.
- A custom return path per customer domain.

## Go-live

`bounce.inbox2.com` (singular) is taken: it is the Amazon SES MAIL FROM domain
for inbox2's own transactional mail. The ESP uses `bounces.inbox2.com`.

1. DNS: `bounces.inbox2.com` MX 10 `mx.inbox2.com`, and TXT
   `v=spf1 include:_spf.inbox2.com ~all`. Until the MX record exists, late
   bounces are lost; rejections at send time still work.
2. Set the real allowance numbers in `Plan::ESP_MONTHLY_SENDS`.

# MX Inbound Receiver

The MX component is a Go SMTP server that receives inbound email for verified domains, validates SPF/DKIM/DMARC, and hands messages to the Rails app via NATS JetStream.

```
Internet → MX (Go, :4025) → NATS JetStream → Rails subscriber → PostgreSQL
                                   ↕
                         Domain lookup (req/reply)
```

## Quick start

```sh
# 1. Start NATS (Docker)
docker compose --profile queue up -d

# 2. Start the Rails NATS subscriber
cd api && bundle exec ruby lib/nats_subscriber.rb

# 3. Start the MX server
cd mta && go run ./cmd/mx

# 4. Send a test message
cd mta && go run ./cmd/mxtest -smoke -to support@acme.com
```

Or use `bin/dev` which starts everything in tmux.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MX_LISTEN` | `:4025` | SMTP listen address |
| `MX_DOMAIN` | `mx.inbox2.local` | Server hostname (EHLO banner) |
| `MX_TLS_CERT` | _(none)_ | Path to TLS certificate for STARTTLS |
| `MX_TLS_KEY` | _(none)_ | Path to TLS private key |
| `MX_LOG_FILE` | _(none)_ | Path to JSON log file (append mode). If unset, only stdout text logs. |
| `NATS_URL` | `nats://localhost:4222` | NATS connection URL |

## Architecture

### Message flow

1. **MAIL FROM** — sender recorded, logged
2. **RCPT TO** (per recipient) — extract domain, look up via NATS request-reply (`inbox2.domain.lookup`), validate domain is `verified` or `receiving_mail`, cache result (5 min TTL)
3. **DATA** — read message with size limit (strictest plan across all recipients), run SPF/DKIM/DMARC, parse RFC 5322 + MIME, publish to NATS JetStream per domain
4. Rails subscriber picks up from `MAIL_INBOUND` stream, threads into conversation, runs routing rules, broadcasts via ActionCable

### SMTP error codes

| Code | Enhanced | When |
|------|----------|------|
| 550 5.1.2 | RCPT TO | Domain not found |
| 550 5.1.3 | RCPT TO | Malformed recipient address |
| 450 4.1.2 | RCPT TO | Domain not yet verified (DNS pending) |
| 451 4.4.3 | RCPT TO | Domain lookup timeout (NATS unreachable) |
| 552 5.3.4 | DATA | Message exceeds plan size limit |
| 550 5.7.1 | DATA | DMARC policy=reject and authentication failed |
| 451 4.3.0 | DATA | NATS publish failed (temporary, sender retries) |
| 503 5.5.1 | DATA | No valid recipients (DATA before RCPT TO) |

4xx errors tell the sending MTA to retry. 5xx errors cause an immediate bounce.

### Size limits

The MX server advertises `SIZE 104857600` (100 MB, the paid plan limit). The actual per-message limit is the **strictest plan limit** across all recipients:

- Free plan: 20 MB
- Paid plan: 100 MB

Enforcement happens at SMTP time — oversized messages never enter the system.

### Authentication

| Check | Library | Behavior |
|-------|---------|----------|
| **SPF** | `blitiri.com.ar/go/spf` | Validates sender IP against domain's SPF record via DNS |
| **DKIM** | `emersion/go-msgauth/dkim` | Verifies DKIM signatures on raw message bytes. Pass if any signature valid. |
| **DMARC** | Custom (DNS TXT lookup + Public Suffix List) | Evaluated against the **RFC5322.From header domain** (per RFC 7489), not the SMTP envelope sender. Looks up `_dmarc.<from-domain>`, falling back to the organizational domain's record (applying its `sp=` subdomain policy). Relaxed alignment compares organizational (registrable) domains via `golang.org/x/net/publicsuffix`. Only `p=reject` triggers hard rejection; `p=quarantine` flags the message for the Rails app. |

All checks run during the DATA phase, after the message is parsed (so the From header domain is available for DMARC). DKIM verifies the original received bytes before the trace header below is added. Auth results are included in the NATS payload for downstream use.

A `Received:` trace header (RFC 5321 §4.4) is prepended to the raw message before it is published, recording the relay hop and enabling downstream loop detection.

### Domain lookup

The MX server doesn't query PostgreSQL directly. It sends a NATS request to `inbox2.domain.lookup`, and the Rails subscriber responds with the organization's verified status and plan size limit.

**Request**: `{"domain": "acme.com"}`

**Response**:
```json
{
  "found": true,
  "org_id": 42,
  "org_key": "org_abc123",
  "status": "verified",
  "max_message_size_mb": 20
}
```

Results are cached for 5 minutes. If the lookup times out (2 seconds), the MX returns a 451 temporary error.

### NATS stream config

| Setting | Value |
|---------|-------|
| Stream name | `MAIL_INBOUND` |
| Subject pattern | `mail.inbound.<domain>` |
| Retention | WorkQueue (consumed = deleted) |
| Max age | 72 hours |
| Max bytes | 10 GB |
| Max message size | 110 MB |
| Storage | File |

The Rails consumer uses a durable pull consumer (`RAILS_INBOUND_PROCESSOR`) with explicit ack, max 5 redeliveries, 60-second ack wait.

## NATS message schema

Each accepted message is published as JSON to `mail.inbound.<domain>`:

```json
{
  "version": 1,
  "received_at": "2026-05-24T15:30:00Z",
  "envelope": {
    "mail_from": "sender@example.com",
    "rcpt_to": ["support@acme.com"],
    "client_ip": "203.0.113.42",
    "helo_domain": "mail-out.example.com"
  },
  "headers": {
    "message_id": "<id@example.com>",
    "in_reply_to": "<prev@example.com>",
    "references": "<first@example.com> <prev@example.com>",
    "from": "Alice <sender@example.com>",
    "to": "support@acme.com",
    "cc": "",
    "subject": "Re: Order question",
    "date": "Sat, 24 May 2026 15:29:00 +0000",
    "content_type": "multipart/mixed; boundary=..."
  },
  "body": {
    "plain": "Hello, I have a question...",
    "html": "<div>Hello...</div>"
  },
  "attachments": [
    {
      "filename": "receipt.pdf",
      "content_type": "application/pdf",
      "size_bytes": 45200,
      "content_id": "",
      "is_inline": false
    }
  ],
  "authentication": {
    "spf":   { "result": "pass", "domain": "example.com" },
    "dkim":  { "result": "pass", "domain": "example.com", "selector": "s1" },
    "dmarc": { "result": "pass", "domain": "example.com", "policy": "none" }
  },
  "raw_size_bytes": 52340,
  "raw_message_b64": "<base64-encoded raw RFC 5322 message>"
}
```

Attachment **content** is not in the JSON — only metadata. The full raw message is in `raw_message_b64` for archival and future S3 extraction.

## Rails inbound consumer

### Threading algorithm

Before threading, two short-circuits run:

- **Report routing** — DSN bounces (`multipart/report; report-type=delivery-status`) and ARF complaints (`report-type=feedback-report`) are handed to `InboundReportRouter` and never become conversations. A bounce updates the originating `DeliveryStatus` and suppresses hard-bounced addresses; a complaint suppresses the complainer. See [Mail-Deliverability.md](Mail-Deliverability.md).
- **Idempotency** — the inbound consumer is **at-least-once** (`max_deliver: 5`), and `process_inbound_message` naks on *any* error, so a failure in a post-insert step (rules, broadcast, mobile push, space classify) would otherwise redeliver and create a duplicate. A message whose `message_id_header` already exists in the org is skipped. **New reading/ingest paths must preserve this dedupe.**

When a message arrives, the `InboundMailProcessor` threads it into an existing conversation or creates a new one, in this order:

1. **In-Reply-To** — look up a message with matching `message_id_header`. Most reliable.
2. **References** — walk the list from newest to oldest, match any `message_id_header`.
3. **Subject fallback** — strip `Re:` / `Fwd:` prefixes (17 international variants), find a conversation with the same normalized subject created within 30 days. Subjects shorter than 5 characters are skipped to avoid false matches.
4. **New conversation** — create with status `open` (or `spam` if DMARC quarantine).

### What happens after threading

- Message record created with `is_inbound: true`
- Attachments extracted from the raw message and uploaded to S3/Garage (`storage_key` populated)
- Conversation snippet updated from plain text body
- `RuleExecutor` runs all enabled routing rules
- ActionCable broadcasts `new_message` to the organization channel
- A `verified` org is promoted to `receiving_mail` on the first message through the pipe (`DnsCheckJob` never sets this state)

### Running the subscriber

```sh
cd api && bundle exec ruby lib/nats_subscriber.rb
```

The subscriber handles both domain lookups and inbound message processing in a single process. It shuts down gracefully on SIGINT/SIGTERM.

## Logging

The MX server uses Go's `log/slog` for structured logging:

- **stdout** — human-readable text (level: Info)
- **JSON log file** — machine-parseable (level: Debug), enabled via `MX_LOG_FILE`

### Log events

| Event | Level | Key fields |
|-------|-------|------------|
| `server.start` | Info | addr, domain, nats_url, tls |
| `server.stop` | Info | — |
| `nats.connected` | Info | url |
| `smtp.mail_from` | Info | client_ip, from |
| `smtp.rcpt_to` | Info | client_ip, to, domain, org, duration_ms |
| `smtp.rcpt_reject` | Warn | client_ip, to, domain, code, reason |
| `smtp.data_accepted` | Info | client_ip, from, to, size_bytes, message_id, subject, domains, duration_ms |
| `smtp.data_reject` | Warn | client_ip, from, code, reason |
| `auth.result` | Info | client_ip, message_id, spf, dkim, dmarc, dmarc_policy, duration_ms |
| `domain.lookup` | Debug | domain, found, org, status, cached, duration_ms |
| `nats.publish` | Info | domain, message_id, size_bytes, duration_ms |
| `parse.complete` | Debug | message_id, has_plain, has_html, attachments, duration_ms |

Every timed operation includes `duration_ms`. Use `client_ip` + `message_id` to correlate events across a single delivery.

### Example JSON log line

```json
{"time":"2026-05-24T15:30:00.123Z","level":"INFO","msg":"smtp.data_accepted","client_ip":"203.0.113.42","from":"sender@example.com","to":["support@acme.com"],"size_bytes":4096,"message_id":"<abc@example.com>","subject":"Hello World","domains":1,"duration_ms":12.5}
```

## Test harness

`mta/cmd/mxtest` is a CLI tool for injecting messages and load testing a running MX server.

### Modes

```sh
# Smoke test — single inline message
go run ./cmd/mxtest -addr localhost:4025 -smoke -to support@acme.com

# Inject a single .eml file
go run ./cmd/mxtest -addr localhost:4025 -file testdata/corpus/plain.eml -to support@acme.com

# Inject all corpus files
go run ./cmd/mxtest -addr localhost:4025 -corpus testdata/corpus/ -to support@acme.com

# Load test — 1000 messages, 50 concurrent connections
go run ./cmd/mxtest -addr localhost:4025 -load -count 1000 -concurrency 50 -to support@acme.com
```

### Load test output

```
Load test: 1000 messages, 50 concurrent → localhost:4025

══════════════════════════════════════
  Results
══════════════════════════════════════
  Total:        1000 messages
  Succeeded:    1000
  Failed:       0
  Duration:     2.34s
  Throughput:   427.3 msg/sec

  Latency:
    Min:        1.2ms
    Median:     4.5ms
    P95:        12.3ms
    P99:        28.7ms
    Max:        45.1ms
    Mean:       5.8ms
══════════════════════════════════════
```

### Test corpus

Six `.eml` files in `mta/testdata/corpus/`:

| File | Tests |
|------|-------|
| `plain.eml` | Simple text/plain message |
| `html.eml` | HTML-only content |
| `multipart.eml` | multipart/alternative with In-Reply-To + References |
| `attachment.eml` | multipart/mixed with PDF attachment + CC |
| `unicode.eml` | RFC 2047 encoded headers + UTF-8 body |
| `malformed.eml` | Minimal headers, no Content-Type |

## Go test suite

```sh
cd mta

# Run all tests
go test ./...

# With race detector
go test ./... -race

# Verbose
go test ./... -v

# Benchmarks (parser throughput, SMTP delivery latency)
go test ./internal/smtpd/ -bench=. -benchmem -run=^$
```

### Test coverage by package

| Package | Tests | Covers |
|---------|-------|--------|
| `queue` | 6 | Stream creation, publish/receive, domain lookup (success/not-found/timeout) |
| `smtpd` | 14 | Valid delivery, domain rejection (550/450), oversized (552), multi-recipient, RSET, 20 concurrent connections, DATA without RCPT, domain cache (hit/miss/invalidate/concurrent) |
| `parser` | 7 | Plain, HTML, multipart, attachment, Unicode/RFC 2047, malformed, empty body |
| `auth` | 10 | SPF edge cases, DKIM no-signature, DMARC alignment + policy parsing |
| `mxlog` | 3 | Text output, JSON file output, duration helper |
| `dane` | 2 | TLSA parsing, cert matching |
| `requiretls` | 4 | Server support, header parsing, enforce/reject |

All tests use an **embedded NATS server** (no external dependencies). Auth tests use a mock authenticator to avoid real DNS lookups.

## Concurrency model

- go-smtp spawns **one goroutine per SMTP connection** — unlimited concurrency
- Each `Session` struct is connection-local — no cross-session shared state
- `DomainCache` uses `sync.RWMutex` — safe for concurrent reads
- NATS client (`nats.go`) is inherently thread-safe
- All tests pass with Go's `-race` detector

## Ports (development)

| Port | Service |
|------|---------|
| 4000 | Rails API |
| 4025 | MX inbound SMTP |
| 4173 | Vite React dev server |
| 4222 | NATS client protocol |
| 4223 | NATS HTTP monitoring |

## Go dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `emersion/go-smtp` | 0.24.0 | SMTP server (ESMTP, STARTTLS, SIZE, PIPELINING) |
| `emersion/go-msgauth` | 0.7.0 | DKIM verification |
| `blitiri.com.ar/go/spf` | 1.5.1 | SPF checking (RFC 7208) |
| `nats-io/nats.go` | 1.42.0 | NATS client + JetStream |
| `nats-io/nats-server/v2` | 2.11.3 | Embedded NATS for tests |

## Known limitations

- **No TLS in development** — STARTTLS works when `MX_TLS_CERT` and `MX_TLS_KEY` are set, but dev mode runs plain SMTP on :4025
- **Connection cap** — concurrent SMTP connections are bounded (`MaxConnections`, default 1024, override with `MX_MAX_CONNECTIONS`) via a `netutil.LimitListener`, since each in-flight message holds several times its size in memory. Still front with a firewall/LB in production.
- **No Prometheus metrics** — logging provides observability but no scrape endpoint yet
- **Attachment content not stored** — metadata only until S3/Garage integration (TODO 41) is built. The raw message is still carried base64-encoded **and** the parsed body is duplicated in the payload, so the NATS stream `MaxMsgSize` is budgeted at 260 MB to keep a 100 MB message publishable; offloading the raw to object storage is the long-term fix.
- **SPF/DKIM/DMARC use real DNS** — no internal caching beyond the OS resolver
- **Single NATS subscriber process** — no horizontal scaling of the Rails consumer yet

The domain lookup cache is size-bounded (50k entries with expiry sweep) and uses a short 30 s TTL for negative/not-yet-verified results so a freshly verified domain starts accepting mail quickly and a RCPT flood to random domains cannot grow memory without bound.

# E2EE — per-MX message sealing (IMPLEMENTED — Phases A–I landed)

> **Status: implemented.** All phases (A schema/flags, B key provisioning, C Go MX seal
> pipeline, D Rails dual-mode consumer, E triage worker + ClassificationProviders, F read
> path + web client crypto + recovery onboarding, G content-free push, H leak audit,
> I outbound & drafts sealing) are committed. This doc remains the architecture reference;
> where it and the repo disagree, the repo wins. Remaining follow-ons are listed under
> "Out of scope" (key rotation on member removal, client-side rich push enrichment,
> on-device search, mobile client decryption wiring, outbound-attachment upload encryption,
> deploy wiring for the triage worker + MX spool/S3/delivery-key env).
>
> **Note:** a **sibling** feature — the **credential vault** — reuses the same
> double-envelope wrapping pattern and is also implemented. See
> ["Credential vault" below](#credential-vault-implemented).

## Credential vault (IMPLEMENTED)

Zero-knowledge cloud backup of **external-mailbox channel credentials** (Gmail/Microsoft OAuth
tokens, IMAP passwords, Meta BYOK secrets), so a user signing into their inbox2 account on a new
device pulls + decrypts them locally and **skips re-OAuth**. This is separate from message sealing
(which protects MX-pooled *mail*); the vault protects the *credentials* the offline sync engine
holds. It is opt-in and built on the same wrapping idea this doc describes.

**Crypto (double envelope).** A random 32-byte **DEK** encrypts each account's credential bundle
(account config + tokens) with AES-256-GCM. The DEK is wrapped twice: once under the device's
OS-keychain key (transparent same-device unlock at boot) and once under `KEK = Argon2id(inbox2
password, salt)` (cross-device restore). The server stores both opaque wrapped copies + salt +
Argon params + the per-account ciphertext, and can unwrap **neither**.

**The vault secret is the user's inbox2 account password** (not a separate generated recovery
passphrase as message-sealing uses). Honest trade: the password transits to Rails at login
(bcrypt-verified, never stored) — an honest server never retains it; a malicious one could capture
it at login. Accepted because the stakes are low (tokens are re-obtainable via OAuth). Lost password
+ no still-logged-in device → reconnect via OAuth (no permanent loss).

**Password change → full rotation.** Changing the inbox2 password re-encrypts every backed-up
credential under a **fresh** DEK (`rotate_vault`), so an exposed old password can't derive the new
key.

**Identity binding.** The vault is bound to one inbox2 `user_id`; sign-out / account switch calls
`clear_vault_session` (drops the in-memory DEK + local state + per-account flags) so identity A's
tokens never upload into identity B's vault. One vault per user; orgs/domains don't affect it.

**Where it lives.**
- **Rails** (zero-knowledge blob store): `credential_vaults` (wrapped DEK copies + Argon params,
  one per user) + `stored_credentials` (per-account ciphertext blob + plaintext `provider`/
  `external_email` metadata only, for the management card). `Api::V1::StoredCredentialsController`
  (`/stored-credentials` + `/stored-credentials/vault`), Alba serializers that never expose the
  blob in list views.
- **Rust core** (`ui/desktop/core/src/sync/`): `vault.rs` (crypto), `store/vault.rs` (local
  `vault_state` + per-account `cloud_backup_enabled`/`backup_dirty`), `vault_sync.rs` (engine
  orchestration: enable/unlock/rotate/restore + the backup drain). FFI surface in `ffi.rs`
  (`enable_cloud_backup`, `unlock_vault`, `rotate_vault`, `restore_from_cloud`,
  `clear_vault_session`, …; `add_account`/`add_meta_account` gain a `cloud_backup` flag).
- **Clients**: Tauri commands (`commands/vault.rs` + `rpc.rs`); web add-account "Save this login"
  toggle (gated on an MX session) + the `/console` "Saved logins" management card; iOS/Android
  wire the same FFI.

Token refreshes mark the credential backup-dirty so the rotated token re-uploads on the next engine
drain; removing a channel deletes its cloud blob.

## What we are building (and the claim we make)

End-to-end **message sealing for MX-pooled mail**, toggleable per **domain**, gated behind a
paid plan entitlement, forced off in dev/test. Sealed messages are stored as ciphertext; the
server moves opaque blobs and never holds a usable secret key.

**The security claim — stated honestly:**

- Durable stores hold **only ciphertext**: Postgres (rows, WAL, replicas, backups), the
  durable `mail.inbound` JetStream (FileStorage), `solid_queue_jobs.arguments`, logs, APNs/FCM
  payloads. A DBA, a backup restore, a disk image, or an operator browsing the DB cannot read
  sealed message content, subject, sender, or snippet.
- Plaintext exists **transiently and only in RAM**: the Go MX process during sealing, a
  **memory-only NATS stream** (`triage.inbound.*`, ~10 min TTL, lost on restart), and the
  triage worker's RAM during a classification call.
- We **do not** claim that a live compromise of the running NATS/MX/triage host reveals
  nothing — in-flight plaintext is readable there for seconds–minutes. This is a deliberate,
  documented trade to keep server-side triage and good notifications working.
- **The claim covers OUTBOUND mail too** (Phase I, landed): sent/draft rows are sealed under
  the domain key and the queued outbound MIME under the **MTA delivery key**, so the durable
  `MAIL_OUTBOUND` stream holds ciphertext only. Outbound from/to/cc stay plaintext (wire/
  deliverability metadata); subject + bodies are sealed.
- **Accepted plaintext exceptions (documented):** DSN/ARF machine reports (routed down the
  plaintext path even for sealed domains — they can quote original content); outbound
  from/to/cc; draft/outbound attachment bytes in object storage (client upload path —
  follow-on). BYO-ESP delivery of sealed mail is refused with a clear diagnostic rather than
  leaked.

This is **not** the Tauri local-at-rest concern (deferred — see "Out of scope").

## Why this shape

Plaintext legitimately exists in exactly two trustworthy places: the **Go MX at ingestion**
(transiently, before it seals) and the **client after decryption**. The server (Rails /
Postgres / durable NATS) is out by definition. So:

- **Fast, local processing happens at the MX, then we seal immediately** — threading hashes,
  snippet, header packing, sealing. All sub-millisecond, no external I/O. Cheap, strong claim.
- **Slow / external processing (classification) is decoupled** onto a separate worker fed by a
  **non-durable** plaintext stream. This keeps OpenAI (or any vendor) off the ingestion
  critical path — preserving today's scaling profile — while never writing the body to Postgres.

Putting the classification call inline at ingestion was rejected: it makes a slow, rate-limited,
flaky external call the dominant cost on the mail-acceptance path, collapses per-worker
throughput, raises memory/concurrency, couples mail intake to vendor availability, and
complicates retry/idempotency.

## Data flow

```
Go MX (has plaintext, seals here)
 ├─ resolve effective_e2ee(recipient domain) via domain-lookup (cached)
 ├─ SEALED path:
 │    • gen DEK (xchacha20poly1305)
 │    • encrypt body + header{subject,from,snippet}  (AAD = domain_id | key_version | message_id)
 │    • crypto_box_seal(DEK -> domain current public key)
 │    • encrypt attachments w/ DEK -> spool ciphertext to disk -> async upload to Garage (off accept path)
 │    • compute threading HMACs (message-id, references[], normalized-subject)
 │    • PUBLISH ciphertext  -> mail.inbound.<domain>     (durable, FileStorage)   <- NO plaintext
 │    • PUBLISH excerpt     -> triage.inbound.<domain>   (MemoryStorage, ~10m TTL) <- plaintext, RAM only
 │    • zero plaintext + DEK
 └─ PLAINTEXT path (effective_e2ee == false): unchanged, encryption_scheme = none

Rails inbound consumer (nats_subscriber)        Triage worker (NEW, separate consumer)
 • sealed -> write ciphertext row                 • pull triage.inbound.>  (memory stream)
   group by HMAC                                   • ClassificationProvider.classify(excerpt)
   store sealed header/snippet                       (OpenAI today; switchable / on-prem later)
   search_vector = null                            • write back ONLY the label to the sealed row
   skip Rspamd, skip inline classify               • body never touches Postgres
   route CONTENT-FREE push (see Phase G)           • idempotent; row-not-yet-present -> redeliver
 • plaintext -> unchanged                                                   -> TTL expiry -> no label
```

## Decisions (locked)

- **Granularity: domain-level.** Entitlement (`plans.e2ee`) + operational switch
  (`domains.e2ee_enabled`). No per-mailbox override. The MX domain-lookup is already
  per-domain, so this is the cheap, natural fit.
- **Key unit: the DOMAIN, not the "mailbox".** (Repo-reality correction: in this codebase a
  `Mailbox` is one member's address — membership × domain — while all mail for a domain lands in
  the org-wide pool readable by every member. A per-address key can't serve pooled mail.) Keys
  are `domain_keys` (versioned public key per domain, `retired_at` on rotation) +
  `domain_key_grants` (the domain secret key sealed to each **membership**'s user identity key).
  The MX seals the DEK to the domain's current public key; every member with a grant decrypts.
  Member removal ⇒ rotate the domain key (mint v+1, re-grant remaining members). Everywhere this
  doc previously said "mailbox key", read "domain key".
- **Envelope & sender metadata: sealed — keep the strong claim.** Sealed rows store **no
  plaintext sender/recipient headers**: `messages.from_address` / `to_address` / `cc_address`
  are null (schema: relax `from_address` NOT NULL), and the sealed header ciphertext carries
  `{subject, from, snippet}`. Consequences, all handled in the MX ingestion window (it has
  plaintext anyway): sender **blocklist/allowlist** checks and sender-based routing rules move
  MX-inline for sealed domains (Rails `check_mail_filters` is skipped — it has nothing to read);
  **DSN/ARF reports** are detected at the MX (multipart/report sniff) and routed down the
  **plaintext** path — machine delivery telemetry, documented accepted leak (they can quote
  original content; accepted v1). Conversations mirror this: sealed conversations keep
  `subject`/`snippet`/`from_address`/`to_address`/`search_vector` null and get a `subject_hmac`
  for threading; `update_conversation_preview` is skipped for sealed.
- **Notification previews: per-domain toggle, DEFAULT ON (accepted risk).** Rich push alerts
  for sealed mail carry a plaintext copy of exactly **{from, subject}** — nothing else, never
  the body/snippet — attached by the MX alongside the sealed payload
  (`domains.e2ee_notification_preview`, toggled in the Encryption settings tab). The leak
  surface is the durable NATS payload, `solid_queue_jobs.arguments`, and the APNs/FCM wire
  (Apple/Google); the preview is never stored on the message row. Turning it off per domain
  restores the fully content-free "New message" alert with zero leakage — the truly paranoid
  posture. Boundary is pinned by the Phase-H audit (subject may appear in push args when on;
  the body marker must never appear anywhere).
- **Dedup/idempotency for sealed mail: `msgid_hmac`.** The inbound consumer's at-least-once
  dedup uses `message_id_header` today; sealed rows dedupe via a partial unique index on
  `(organization_id, msgid_hmac)` instead (HMACs are deterministic, so redeliveries collide
  exactly like plaintext Message-IDs do).
- **Classification egress: accepted, behind a switchable provider.** Plaintext excerpts go to
  a classification vendor. This MUST follow a `ClassificationProviders` adapter pattern
  (mirroring the existing `DeliveryProviders` ESP framework) so we can swap vendors
  (OpenAI / Azure OpenAI / Anthropic) or run an **on-prem / on-device** model later without
  touching the pipeline. Secrets write-only, per-org configurable, with a catalog.
- **Label stored as plaintext metadata: accepted.** The Space slug / quadrant is stored
  cleartext alongside the ciphertext. The server learns "this is in Space X" but not content.
  Known, accepted metadata leak (note: Space *names* can themselves be sensitive).
- **Attachments: sealed in v1, in the MX, direct async upload.** The MX extracts + encrypts
  attachments and uploads ciphertext straight to Garage on a background queue (durable local
  spool + retry) so throughput is unaffected. See "Attachments (sealed)".

## Assumptions still to confirm

- None — attachments resolved (sealed in-MX, direct async upload; see "Attachments (sealed)"),
  outbound/drafts resolved (Phase I).

## Key loss & recovery

The server only ever holds the user's identity private key **wrapped** (under an Argon2id
password-KEK, and a second copy under a recovery code). The server cannot unwrap either — so it
**cannot** reset a password and recover data the way a normal app can. Recovery is layered:

1. **Forgot password → self-service via the recovery passphrase.** `recover(passphrase, blob)`
   unwraps the recovery copy and re-wraps the identity key under a new password. No data loss, no
   message re-encryption. The passphrase is human-friendly but high-entropy (generated Diceware),
   shown once on screen, and additionally backed up to the user's email — see Option A below.
2. **Forgot password + lost recovery code, but the domain has other members → recoverable by
   re-grant.** Mail is sealed to the **domain** key, not the individual; the lost identity key
   only gated that user's *grant*. As long as ≥1 other member still holds a grant, an
   admin/member re-issues a fresh grant to the user's **new** identity public key and they regain
   full historical + future access. The org loses nothing.
3. **Forgot password + lost recovery code + no surviving grant-holder on the domain →
   unrecoverable, permanently.** This is the unavoidable cost of "operators/DBAs cannot read
   mail": zero-knowledge and a server-side reset button are mutually exclusive.

**Decision (locked): no admin escrow — user-controlled email backup instead (Option A).** We do
not build an org/admin recovery key. Operators can never recover a user's keys, and "not even
admins can read it" holds in full. To cut accidental loss we add a backup the **user** controls:

- **Recovery passphrase (single secret).** Generated client-side, **human-friendly but
  high-entropy** — Diceware-style (~6 random words, lowercase, hyphen-joined; no symbol soup).
  **Generated, never user-chosen** (a chosen "easy" password would be offline-brute-forceable
  against the emailed file; ~77-bit Diceware behind Argon2id is not). It wraps a copy of the
  identity key (Argon2id MODERATE); the wrapped blob is stored server-side as
  `recovery_encrypted_private_key`.
- **Email backup via Messy.** At signup the client also produces the passphrase-wrapped recovery
  file (opaque ciphertext) and hands the server **only that blob**; the server emails it to the
  user's registered address through a new inbox2 **Messy welcome template** as a portable offsite
  backup. **The passphrase and plaintext key never touch our infra** — server, Messy, and the
  user's inbox only ever hold a blob useless without the passphrase.
- **Recovery paths:** enter the passphrase (from a vault/memory) against the server-stored blob,
  or against the file in the welcome email → unwrap → re-wrap under a new login password.
- **Accepted loss:** lose the passphrase → both the email file and the server blob are
  unopenable → that user's access is gone. No reset, by design. (A surviving domain grant held by
  another member still restores access via re-grant — case 2.)

This is defense-in-depth against losing the on-screen copy, with **no** reduction in the
operator-can't-read guarantee.

**Onboarding messaging (required this round).** Backup must be imperative, not incidental: show
the recovery passphrase once behind a **hard save-gate** (explicit "I've saved it" confirmation,
ideally type-back; cannot proceed otherwise), state plainly that **inbox2 cannot recover it and
loss is permanent**, and prompt storage in a password manager. The welcome email reinforces the
same.

## Attachments (sealed)

Sealed **in the MX** and uploaded **directly to Garage**, with the upload **async** so it never
blocks SMTP acceptance.

- **Encrypt synchronously, upload asynchronously.** In the ingestion window the MX extracts each
  attachment, encrypts it under the message DEK (streaming AEAD, AAD part = `att:<index>`), and
  **durably spools the ciphertext to local disk**; then it discards plaintext. A background
  uploader worker drains the spool to Garage with retry and deletes the local copy on success.
  The slow network upload is off the accept path — only the streaming encrypt + a local fsync are
  added synchronously.
- **Crash-safety / at-least-once.** Plaintext is gone right after encryption, so the spooled
  ciphertext is the only copy until upload completes — it must be durably written **before** the
  SMTP DATA ack (alongside the sealed-message NATS publish). If the MX restarts, the uploader
  resumes from the spool. If Garage is slow/down the spool grows (bounded, ciphertext-only) and
  retries; SMTP acceptance is unaffected.
- **Object key assigned at encrypt time**, carried in the sealed NATS payload with the sealed
  filename, nonce, size, and content-type. Rails writes the attachment row immediately; the bytes
  land in Garage slightly later, so readers tolerate a brief "not uploaded yet" (404 → short
  retry) — same flavor as the triage race.
- **Metadata sealing.** Filenames leak content (`Q3_layoffs.xlsx`) — store `sealed_filename`
  ciphertext, not the plaintext `filename`. No `content_text`, no `attachments.search_vector` for
  sealed rows.
- **Bytes never transit NATS for sealed mail** (metadata only) — aligns with the offload-raw-MIME
  direction. **New dependency:** the MX needs Garage credentials + network access (today Rails
  uploads).
- **Read:** client fetches ciphertext via presigned GET, decrypts locally (streaming) and decrypts
  the filename; inline `cid:` images are decrypted and injected as blob URLs at render time. Branch
  on `encryption_scheme`.
- **Compose/outbound:** the sending client encrypts the at-rest copy before upload; the SMTP
  message to external recipients still carries the attachment in plaintext (E2EE protects our
  storage, not the wire to non-inbox2 recipients).

## UX impact (sealed mailboxes)

Plaintext mailboxes are unaffected. For sealed mailboxes the throughline is: **anything the
server does *to the content* must move — to the MX ingestion window, to the client, or it's
lost.** What survives untouched is the metadata layer: counts, read/unread, assignment,
mailbox/label filtering, threading (via HMAC), delivery status.

### The MX as a trusted content processor (rescues a lot of this)

The MX at ingestion is the one server-side place that legitimately holds plaintext. Treat it as a
**content-processor pipeline**: any feature that is a *one-time function of the inbound message*
can run here and emit a durable result, so the feature survives without the server ever reading
content again. Same fast/slow split as spam vs triage:

- **Inline (fast, local, self-hosted)** — runs before sealing, on the accept path: spam scoring,
  attachment AV scan, content-based routing-rule evaluation, sentiment/intent. Keep these quick.
- **Async transient worker (slow, external — LLM)** — fed by the memory stream, off the accept
  path: Spaces triage, conversation summaries. Best-effort; lost if the provider is down past TTL.

**Output rule — the line that keeps the encryption meaningful:**
- **Low-information results → cleartext metadata** (accepted leak): Space slug, spam score, AV
  verdict (clean/infected), sentiment enum, routing outcome (assignee/tag).
- **Results that reconstruct content → MUST be sealed** (encrypted with the message DEK, like the
  body): conversation summaries, extracted snippets, OCR/attachment text, thumbnails. A plaintext
  `ai_summary` column would leak the content we just encrypted. The client decrypts these like any
  other sealed field.

**Constraints that come with ingestion-time processing:**
- **One-shot.** Computed once at ingestion; *not* re-runnable server-side later. Change a rule,
  add a Space, swap the summary model → it does not retroactively apply to already-sealed mail.
- **Transient surface grows for full-body processors.** Triage needs only an excerpt; summaries
  need the full body — so the memory stream carries full plaintext for those (still RAM-only,
  TTL-bounded, but a larger transient exposure than the excerpt).
- **Content egress stays a per-feature trust decision** (summaries/triage to an LLM; a rule that
  POSTs the body to a webhook). Same call as the OpenAI-egress decision — fine via a switchable
  provider, but it *is* plaintext leaving the box.

### Rescued by ingestion-time processing
- **Spaces triage** — transient worker; cleartext label. (Already in plan, Phase E.)
- **Conversation summaries (`ai_summary_*`)** — transient worker; **sealed** output; full body on
  the memory stream.
- **Sentiment / intent** — inline; cleartext enums.
- **Attachment AV / malware scan** — inline at MX; cleartext verdict.
- **Attachment thumbnails / previews** — generated at MX from plaintext; **sealed** asset.
- **Content-based routing rules** — evaluated inline at MX against plaintext; only the routing
  *outcome* (assignee/tag/queue) is stored. Webhook *content delivery* = an egress decision, done
  at ingestion or not at all.

### Genuinely lost server-side (moves fully client-side, or gone)
- **Full-text keyword search** — on-device only (local decrypted FTS). **A pure browser client
  with no local index loses search of sealed mail.**
- **Semantic / vector search** — out for now; on-device later.
- **Attachment content search & server-side filename search** — gone (filenames sealed).
- **Content-based filtered views / saved searches** — server can only filter on metadata.
- **Interactive / on-demand AI** (ask-your-mailbox, summarize-this-thread-now) — client-side /
  on-device only; needs plaintext at query time, not ingestion time.
- **"Mark as spam/ham" training feedback** — server can't rebuild a sealed message to train;
  must be client-driven (the client has plaintext).
- **Outbound composition** — client-side; the server can't build outgoing MIME from a sealed
  store. **Scheduled send / send-later / undo-send** need the client online at send time or a
  client-prepared payload.
- **Webhook payloads carrying subject/body** — only via MX-at-ingestion egress; not from stored
  sealed data.
- **Operator / support content viewing** — never (by design).
- **Server-side content export** (e.g. GDPR data-access) — client-side with keys. (Deletion /
  GDPR-wipe still works.)
- **Analytics / reporting over subject/body** — impossible server-side.

### Degraded
- **Mobile push previews** — content-free until client NSE/FCM enrichment is built (Phase G).
- **List-view snippet / subject / sender** — sealed; shown only after the client decrypts
  (nothing pre-unlock).
- **Threading** — HMAC exact-match only; loses today's fuzzy subject-matching heuristic.

### New friction
- **Per-session / new-device unlock** to derive keys before reading any sealed mail.
- **New member** can't read until an online member issues a grant; **member removal** forces key
  rotation + re-granting.
- **Signup** recovery-passphrase save-gate.
- **Lost passphrase + no surviving grant** → permanent loss (accepted).

---

## Phases (one PR each)

### Phase A — schema, flag, crypto deps, lookup
- Schema (edit `db/schema.rb` directly per the no-migration-explosion rule, then
  `db:schema:load`):
  - `messages`: add `encryption_scheme` (enum **constants on `Message`**, like
    `Domain::STATUSES`: `ENCRYPTION_SCHEMES = %w[none sealed_box_v1].freeze` + `ENCRYPTION_SCHEME_*`),
    `domain_key_version`, `sealed_dek`, `body_nonce`, `body_ciphertext`, `header_nonce`,
    `header_ciphertext`. Keep `body_plain` / `body_html` / `subject` **nullable** (plaintext
    path untouched) and **relax `from_address` to nullable** (sealed rows store no plaintext
    sender — it lives in the sealed header).
  - Threading HMAC columns on `messages` (`msgid_hmac`, `refs_hmac` array, `subject_hmac`) —
    **populated for ALL messages** (plaintext too) so mixed-mode grouping is uniform. Partial
    unique index `(organization_id, msgid_hmac)` (sealed-mail dedup) + GIN on `refs_hmac` +
    `(organization_id, subject_hmac)`.
  - `conversations.subject_hmac` (step-3 subject threading finds *conversations*, so the HMAC
    must live there too) + index `(organization_id, subject_hmac)`.
  - `plans.e2ee` boolean → mirror `ai_triage` in `Plan::DEFAULTS` / `seed_defaults!`
    (free=false, paid/max=true).
  - `domains.e2ee_enabled` boolean (operational switch).
  - Key tables: `user_keys` (one per user: public key + password-wrapped + recovery-wrapped
    private blobs + KDF params), `domain_keys` (versioned public key per domain, `retired_at`),
    `domain_key_grants` (domain secret sealed to a **membership**'s identity key). **Blob-only —
    no usable secret-key column.**
  - `attachments`: add `sealed_filename` (ciphertext) + AEAD params (nonce) for the stored
    object; reuse the existing object-key column; keep `filename` / `content_text` /
    `search_vector` **nullable** (unused for sealed rows).
- `Organization#e2ee_entitled?` → `effective_plan.e2ee` (named "entitled" to distinguish the
  plan gate from the per-domain switch). `E2ee.available?` reads `INBOX2_E2EE_FORCE_OFF`
  (forced off by default outside production). Single `E2ee.effective?(domain)` resolver =
  `entitled && enabled && !force_off`. Entitlement guard (Domain validation) rejects enabling
  without entitlement (clear paywall error, no half-enable). The lookup responder additionally
  requires a minted `domain_keys` row before reporting `e2ee: true` — enabled-but-keyless falls
  back to plaintext, never half-seals.
- Extend the domain-lookup NATS responder (`nats_subscriber.rb:80` ↔ `publisher.go:31`
  `DomainInfo`) to return `e2ee` decision + the domain's current **public key** + `key_version`.
- Deps: `libsodium-wrappers-sumo` (web); promote `golang.org/x/crypto/nacl/box` to a direct
  dep (MX). Define a server-side **HMAC threading key** secret, delivered to the MX via config.
- Tests: resolver truth table (entitled × enabled × force_off), entitlement guard, enum
  inclusion validation.

### Phase B — key provisioning (blob-only)
- Endpoints: upload/fetch `user_keys` (wrapped private blob + public key); mint `domain_keys`
  v1 + issue `domain_key_grants` (per membership); fetch domain public keys. Rails stores
  opaque blobs only.
- Goal: a sealed domain has a current public key for the MX to seal to.
- Key **rotation** on member-removal = later phase (mint v+1, re-grant remaining members,
  set `retired_at` on v).
- Tests: assert no endpoint/serializer ever returns a usable secret key; grants are sealed
  blobs only.

### Phase C — Go MX seal pipeline
- In `session.go` between parse (`:142`) and building `InboundMessage` (`:194`): if
  `effective_e2ee`, gen DEK, build header `{subject, from, snippet}` (port a minimal snippet
  builder — mirrors `SnippetBuilder` / the Rust core `build_snippet`), encrypt body+header
  with AAD `domain_id|key_version|message_id`, `crypto_box_seal` the DEK to the domain public
  key, compute threading HMACs, publish **ciphertext** to `mail.inbound`, publish a
  **plaintext excerpt** (subject + from + first ~1200 chars, matching
  `SpaceClassifier.email_excerpt`) to `triage.inbound.<domain>`, then zero plaintext + DEK.
- **Spam scoring runs here, inline.** Unlike triage, Rspamd is self-hosted + fast (~tens of ms,
  no third-party egress, no rate limit), so it's safe on the accept path. The MX scores the raw
  MIME via Rspamd and stores `spam_score` / `spam_action` / `spam_symbols` as **plaintext
  metadata** on the sealed row (same accepted-leak category as the label) — Rails then routes by
  that metadata without ever needing the raw MIME. (Forward-looking: this also enables SMTP-time
  reject/quarantine later; not required for v1. Alternative considered + rejected: a transient
  spam worker fed the *full* raw MIME — larger plaintext on a stream than MX-inline.)
- **Attachments** (see "Attachments (sealed)"): extract each attachment, encrypt under the
  message DEK (streaming AEAD, AAD `att:<index>`), spool ciphertext to durable local disk before
  ack, and drain to Garage on a background uploader; put object key + sealed filename + nonce in
  the sealed payload. MX gains Garage credentials.
- **Other inline processors share this window** (one-shot; emit cleartext metadata or sealed
  assets per the output rule in "UX impact"): attachment AV scan, content-based routing-rule
  evaluation, sentiment/intent. v1-vs-follow-on per processor is a scope call.
- **Sender filtering + report routing move here for sealed domains** (per the envelope
  decision): evaluate the org blocklist/allowlist MX-inline (fetch via the domain-lookup reply
  or a sibling request), and sniff `multipart/report` (DSN/ARF) **before** sealing — reports go
  down the plaintext path so Rails report routing keeps working.
- Stand up the memory stream next to `ensureStream` (`publisher.go:153`): `MemoryStorage`,
  `MaxAge ~10m`, `MaxBytes` cap, `DiscardOld`.
- Scrub subject from `DataAccepted` logging (`mxlog/logger.go:129`) when sealed.
- Plaintext path unchanged.
- Tests: sealed `mail.inbound` payload has no body/subject/from/raw-MIME plaintext; AAD tamper
  fails decrypt; memory-stream config asserted; log scrub; attachment bytes in Garage are
  ciphertext only; spooled ciphertext survives a simulated MX restart and uploads on resume.

### Phase D — Rails inbound consumer dual-mode + HMAC threading
- `InboundMailProcessor`: sealed branch writes the ciphertext row (`create_message`, `:291`),
  groups via the HMAC columns instead of cleartext In-Reply-To/References/subject
  (`find_or_create_conversation`, `:247`), stores sealed header/snippet, leaves `search_vector`
  null, **does not enqueue `ClassifySpaceJob`** (triage is decoupled — Phase E), **routes spam
  by the MX-provided `spam_action` metadata** (no raw MIME needed server-side; no Rails-side
  Rspamd call for sealed mail), and routes a **content-free push** (see Phase G). Compute +
  store threading HMACs for plaintext messages too (uniform
  grouping; mixed-mode safe — a sealed reply to a plaintext original still threads).
- **Sealed-branch scrubs (per the envelope decision):** `from_address` / `to_address` /
  `cc_address` null on the row; **skip `check_mail_filters`** (moved MX-inline); dedup via
  `msgid_hmac` instead of `message_id_header`; **skip `update_conversation_preview`** and keep
  the conversation's `subject`/`snippet`/`from_address`/`to_address`/`search_vector` null —
  set `conversations.subject_hmac` for step-3 threading.
- **Attachments:** store sealed attachment metadata (object key, `sealed_filename`, nonce, size,
  content-type); no `content_text` / `search_vector` for sealed; tolerate an object not yet
  uploaded to Garage (pending → reader retries).
- Plaintext branch unchanged.
- Tests: sealed row has null `body_plain` / `subject` / `from_address` + populated ciphertext;
  mixed-mode conversation threads correctly; no `ClassifySpaceJob` for sealed; no Rspamd for
  sealed; sealed conversation preview columns stay null.

### Phase E — triage worker (new) on the transient stream
- New consumer process (sibling to `nats_subscriber.rb`) — durable pull consumer on
  `triage.inbound.>`. Calls `ClassificationProvider` (see below), writes back **only the
  label** (`conversation.space_id` / quadrant) to the already-sealed row. Body never persisted.
- **`ClassificationProviders` adapter framework** (mirror `DeliveryProviders`): interface
  `classify(excerpt) -> { slug, sentiment?, intent? }`; adapters `OpenAIProvider` (wraps the
  existing `Llm::Client` / `SpaceClassifier` logic), with `AzureOpenAIProvider`,
  `AnthropicProvider`, and `LocalProvider` (on-prem / on-device lane) as future entries. Catalog
  + per-org config, secrets write-only. The worker calls the configured provider, never a
  vendor SDK directly. Refactor `SpaceClassifier` behind this interface (the plaintext path can
  use it too, replacing its direct `Llm::Client` call).
- **This generalizes to an ingestion content-processor lane.** Triage is the first processor;
  conversation summaries are the natural second — same lane, but **sealed** output (encrypted with
  the message DEK; full body carried on the stream, not just the excerpt). See "UX impact → MX as
  a trusted content processor." Which processors ship in v1 vs follow-on is a scope call.
- Idempotent on `message_id`. If the sealed row isn't written yet (race), nak/redeliver until
  it appears or the stream TTL expires (then the message is simply never labeled — the seal
  already stands). Hard timeout + fallback, consistent with the existing triage-worker timeout
  invariant.
- Tests: label written back; body never persisted; idempotency; row-not-yet-present race;
  provider-down ⇒ sealed row stands label-less; provider swap (OpenAI → a stub Local provider)
  changes nothing else.

### Failure & backpressure semantics (triage stream)

- **Mail storage never depends on the classifier.** The durable `mail.inbound` consumer writes
  the sealed row to Postgres and acks immediately, independent of any provider. Mail is safe
  whether or not triage runs.
- **Provider down:** the triage worker naks → redelivers with backoff. If the provider recovers
  within the stream TTL, the message is labeled; if not, the excerpt **ages out of the memory
  stream and is discarded** — that message stays permanently unlabeled (seal stands, mail
  readable). It never piles up, never persists to disk, never blocks intake.
- **Provider slow / burst:** the memory stream fills toward `MaxBytes`, then `DiscardOld` drops
  the oldest excerpts (lost labels) rather than growing unbounded — the correct failure mode for
  bounding transient plaintext.
- **Tunable:** longer TTL ⇒ more labels survive an outage but more plaintext held in RAM longer;
  ~10 min is a starting point.
- **Mitigation via the provider abstraction:** configure a `LocalProvider` (on-prem / on-device
  lane) as a fallback so labels keep flowing when the cloud vendor is unavailable.

### Phase F — read path dual-mode + minimal client crypto (round-trip)
- `MessageSerializer` (+ `sync_controller`, `mcp_controller`) return ciphertext blobs for
  sealed messages; renderers / list views branch on `encryption_scheme`
  (`none` → plaintext columns; `sealed_box_v1` → decrypt client-side).
- Minimal TS crypto module (`libsodium-wrappers-sumo`, shared by React + Tauri webview):
  `unlock`, `decryptMessage` (pick keypair by `domain_key_version`, verify AAD). Enough to
  satisfy the round-trip acceptance test. Full account setup / password-wrap / key-rotation UX =
  follow-on.
- **Recovery backup + onboarding (this round):** generate the human-friendly Diceware recovery
  passphrase client-side; the on-screen hard save-gate + imperative messaging; client-side
  production of the passphrase-wrapped recovery file; a server endpoint that forwards the
  **opaque** blob to Messy; the inbox2 Messy welcome template. Server never sees the passphrase or
  plaintext key.
- **Attachments:** fetch ciphertext (presigned GET), decrypt locally (streaming) + decrypt the
  filename; render inline `cid:` images by decrypting and injecting blob URLs; tolerate a
  not-yet-uploaded object (brief retry).
- Tests: seal → store → unseal → correct plaintext; AAD-bound metadata tamper fails decrypt;
  attachment round-trip (encrypt → spool → upload → fetch → decrypt) yields correct bytes.

### Phase G — notifications under sealing  ← (the gap we almost missed)
The new-mail notification path is a first-class leak surface and needs explicit handling.

- **Today (leaks):** `InboundMailProcessor` → `MobilePushSender.new_message` → `fan_out` →
  `MobilePushDeliveryJob.perform_later(device.id, spec)`. `spec` carries `alert.title =
  from_address` and `alert.body = subject + snippet` → lands in **`solid_queue_jobs.arguments`
  (plaintext at rest)** AND in the **APNs/FCM payload**.
- **Server side (sealed mail):** the server has no plaintext (subject/snippet are sealed/null),
  so build a **content-free push spec** — generic title ("New message"), no body content, plus
  a data payload `{ conversation_key, message_key, sealed: true, domain_key_version }`. No
  plaintext in `spec` → no leak in job args or APNs/FCM. This mirrors the existing IDs-only
  `channel_sync` push and the content-free ActionCable broadcast (`inbound_mail_processor.rb:436`).
- **Client side (rich notifications, the Signal-style pattern — follow-on):** the device
  receives the content-free push, and an **iOS Notification Service Extension** / **Android FCM
  data-message handler** fetches the sealed message, **decrypts locally** with the device's
  keys, and rebuilds the rich notification (real sender/subject) on-device. Requires keys
  reachable from the extension (App Group + keychain on iOS) and ties to Phase F's client
  crypto. Design the payload now (IDs + `sealed` flag + `key_version`) so the client has what it
  needs; implement enrichment as a follow-on. Until then, sealed mail shows a generic "New
  message" on the lock screen.
- **Desktop / web:** already driven by a content-free ActionCable signal + a local-first fetch;
  since these clients hold keys and decrypt locally, they can render rich notifications without
  any server content. Confirm + leave as-is for sealed.
- Tests: for sealed mail, `MobilePushDeliveryJob` args contain no from/subject/snippet; APNs/FCM
  payload is content-free + carries IDs; plaintext mail notifications unchanged.

### Phase H — leak audit + automated plaintext-scan test
- Apply conditional scrubbing across the Phase-0 inventory for `encryption_scheme != none`
  (MX subject log, push args, `search_vector`, snippet, Rspamd, Rails classify).
- Automated test: seal a message bearing a known marker token, then scan Postgres columns, the
  durable `mail.inbound` store, `solid_queue_jobs.arguments`, and log output for the token; fail
  if found. (The memory `triage.inbound` stream is deliberately **excluded** — that's the
  accepted transient surface.)

### Phase I — outbound & drafts sealing  ← (added on repo re-review)
Inbound sealing alone leaves a hole the size of the feature: **replies quote sealed content**,
and today `OutboundMailPublisher` composes plaintext MIME from the plaintext row and publishes
it to the **durable FileStorage `MAIL_OUTBOUND` stream** (base64 `rfc5322_b64`). Two leak
surfaces to close for sealed domains:

- **The stored sent/draft row (Postgres).** Seal outbound messages under the **domain key**,
  same `sealed_box_v1` columns as inbound. v1: **server-side sealing at persist time** — the
  compose endpoint receives plaintext (it must: the wire to external recipients is plaintext by
  nature), builds the outbound MIME + threading HMACs **in RAM**, seals the at-rest copy, and
  never writes plaintext columns. This is a documented widening of the trusted transient window
  (Rails RAM during compose/send, same trust class as the MX ingestion window). Client-side
  compose sealing (client seals the row copy itself; server never sees the stored form) is the
  follow-on that shrinks it. Drafts of sealed domains: same server-side sealing on every
  autosave (plaintext transits, ciphertext persists).
- **The outbound queue (JetStream, durable).** Introduce a static **MTA delivery keypair**: the
  Go SMTP sender holds the private key (it already holds DKIM private keys — it is a trusted
  key-holder by construction); Rails seals `rfc5322_b64` to the public key for sealed domains.
  The durable stream then holds ciphertext only; the sender decrypts in RAM at delivery time,
  DKIM-signs, and delivers. Retry semantics unchanged (the sealed payload redelivers like any
  other). `DeliveryStatus` / DSN diagnostics must not embed message content for sealed mail.
- **Scheduled send / undo-send** for sealed domains ride the same path (the sealed queued copy
  is what eventually goes out); no client-online-at-send-time requirement with server-side
  sealing (revisit if/when compose sealing moves client-side).
- **BYO-ESP (`DeliveryChannel.custom?`)**: a sealed row cannot be re-composed for a provider
  API (no plaintext server-side at delivery time), so sealed messages on a custom-ESP org
  **fail fast with a clear diagnostic** rather than silently sending an empty message.
  Sealed domains deliver via the inbox2 MTA. (Implemented.)
- **Outbound recipients stay plaintext metadata** (from/to/cc on the sealed sent row): RCPT TO
  delivery, DSN mapping, and suppression are impossible without them. Subject + bodies are
  sealed; the header ciphertext carries the full display copy.
- **Draft/outbound ATTACHMENTS at rest remain plaintext in object storage for now** — they ride
  the pre-existing client upload path; client-side upload encryption is the follow-on that
  closes it. (Flagged, not silent.)
- Tests: sent sealed row has null plaintext columns + decrypts round-trip; `MAIL_OUTBOUND`
  payload for sealed domains contains no plaintext MIME; Go sender delivers a sealed payload
  correctly; drafts persist ciphertext-only; the Phase-H marker-token scan extended to cover
  the outbound queue + sent rows.
- **Implementation notes (landed):** Rails seals in the request's RAM window using rbnacl
  (libsodium; added to the API image). The MIME is composed pre-save (`OutboundMailPublisher`
  accepts an explicit attachment set) and sealed to the MTA delivery key with AAD = the message
  key; the envelope is stored on `messages.sealed_mime` so undo-window/scheduled/retry delivery
  never needs plaintext. Keypair generator: `cd mta && go run ./cmd/deliverykey` →
  `SMTP_DELIVERY_PRIVATE_KEY` (Go sender) + `INBOX2_MTA_DELIVERY_PUBLIC_KEY` (Rails). Scheduling
  an already-sealed draft is rejected 422 (no plaintext to compose from) — send it directly, or
  a future client-supplied-plaintext schedule variant.

---

## Phase-0 recon (entry points, for reference)

- **MX plaintext / seal hook:** after `parser.Parse` (`mta/internal/smtpd/session.go:142`),
  before building `queue.InboundMessage` (`:194`); publish at `:225`.
- **MX → Rails write:** `lib/nats_subscriber.rb` pull consumer → `InboundMailProcessor#create_message`
  (`app/services/inbound_mail_processor.rb:291`); threading in `#find_or_create_conversation` (`:247`).
- **Read / decrypt point:** `MessageSerializer` (`app/serializers/message_serializer.rb`);
  also `sync_controller.rb`, `mcp_controller.rb`.
- **Outbound path (Phase I):** `OutboundMailPublisher` (`app/services/outbound_mail_publisher.rb`)
  composes MIME in `#compose_rfc5322` and publishes `rfc5322_b64` to durable `MAIL_OUTBOUND`;
  the BYO-ESP branch hands plaintext to `DeliveryProviders.for(channel).deliver`.
- **`search_vector` lives on `conversations` + `attachments`** (not `messages`); conversation
  preview plaintext is written by `InboundMailProcessor#update_conversation_preview`.
- **Notification trigger:** `inbound_mail_processor.rb:456` → `MobilePushSender` →
  `MobilePushDeliveryJob`.
- **Flag pattern to match:** `plans.ai_triage` → `Organization#ai_triage_enabled?` →
  enforced at enqueue (`inbound_mail_processor.rb:85`) + re-checked in job
  (`classify_space_job.rb:12`); force-off via a service `enabled?`/`configured?` reading ENV.
- **Provider pattern to match:** `DeliveryProviders` ESP adapter framework + catalog.
- **No APM/Sentry installed** (one fewer leak sink). **No libsodium anywhere yet.**
- **No PowerSync** (spec was wrong): MX mail = Rails/Postgres reached via REST + JS local-first
  SQLite cache; the Rust sync engine handles external channels only.

## Out of scope (flagged, not silent)

- **Tauri local-at-rest encryption (Concern B)** — dropped per decision; rely on OS full-disk
  encryption. Revisit only if non-FDE devices must be protected.
- **Server-side search for sealed mail** — none; on-device FTS over decrypted cache is a later
  phase.
- **Semantic search on sealed mail** — out; on-device embeddings later (the embedder exists).
- **Key rotation on member removal**, full key-management UX, recovery codes — follow-on.
- **Backfill-and-seal** of existing plaintext — not built.

## Fixed weakness — header and body were interchangeable under one AAD (found 2026-09-20, fixed 2026-11-09)

`header_ciphertext` and `body_ciphertext` of one message are sealed under the **same DEK and
the same AAD** (`domain|key version|message id`). The cipher therefore cannot tell them apart:
whoever serves the bundle — the server, which is the adversary this design exists for — can
swap the two `(nonce, ciphertext)` pairs and both still authenticate. It discloses nothing (no
key is involved) but it is an integrity gap: a client that trusted the result would show a
body as headers and vice versa. Cross-message swaps are *not* possible (the message id is in
the AAD).

- **Mitigated for v1 mail** in both readers (`ui/desktop/core/src/sync/seal.rs`, `e2ee.js`): a
  part wearing the other's fields is refused.
- **`sealed_box_v2` is the fix (2026-11-09). The readers shipped first, then both writers
  (`mta/internal/smtpd/sealer.go`, `OutboundMessageSealer`) switched:** the part's role goes in the AAD
  (`<aad>|header`, `<aad>|body`) and the bundle names the scheme. A swap, or a bundle relabelled
  to the other scheme, now fails in the cipher. Attachments already carried their own roles
  (`|att:<i>`, `|att:<i>|name`) and did not change. Mail sealed as v1 stays readable, and the two
  readers keep refusing a swapped v1 part by its fields. Fixtures: `sealed_fixture.json` / `sealed_by_go.json` are frozen v1;
  `sealed_v2_fixture.json` / `sealed_v2_by_go.json` come from `mta/cmd/sealfixture`.

## Open questions

None outstanding. (Attachments resolved — sealed in-MX with direct async upload; see
"Attachments (sealed)".)

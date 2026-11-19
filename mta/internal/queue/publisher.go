// Package queue provides NATS JetStream publishing for the MX inbound receiver.
package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	StreamName          = "MAIL_INBOUND"
	SubjectPrefix       = "mail.inbound."
	DomainLookupSubject = "inbox2.domain.lookup"
	DomainLookupTimeout = 2 * time.Second
	// DefaultMaxMsgSize must hold the JSON payload for a max-plan (100MB) message:
	// the raw is carried base64-encoded (×4/3 ≈ 133MB) AND the extracted plain/html
	// body is duplicated (worst case ≈ the raw again), plus headers/overhead. We
	// budget 260MB so a message within the advertised SIZE is always publishable.
	// (Long-term fix: offload the raw to object storage — TODO 41 — and drop the
	// base64 blob from the payload.)
	DefaultMaxMsgSize     = 260 * 1024 * 1024
	DefaultStreamMaxAge   = 72 * time.Hour
	DefaultStreamMaxBytes = 1 * 1024 * 1024 * 1024 // 1GB (dev JetStream store auto-caps ~4.6GB; a 10GB WorkQueue reservation fails with err 10047)
	// DuplicateWindow is the JetStream duplicate-tracking window for
	// MAIL_INBOUND: publishes carrying the same Nats-Msg-Id within this window
	// are dropped by the server. Covers an SMTP sender retrying a transaction
	// we 451'd after some recipient domains already published (session.go).
	// ponytail: 2m only catches quick retries — senders on slower schedules
	// (Postfix defaults to 5m+) fall outside it; widen if duplicates show up.
	DuplicateWindow = 2 * time.Minute

	// Transient triage stream (docs/E2EE.md): MEMORY storage only — plaintext
	// excerpts for the classification worker live in RAM, age out fast, and are
	// lost on restart by design. DiscardOld bounds the plaintext held.
	TriageStreamName     = "TRIAGE_INBOUND"
	TriageSubjectPrefix  = "triage.inbound."
	TriageStreamMaxAge   = 10 * time.Minute
	TriageStreamMaxBytes = 256 * 1024 * 1024
)

// DomainInfo holds the result of a domain lookup via NATS request-reply.
//
// The E2EE fields (docs/E2EE.md) drive per-domain message sealing: when E2EE is
// true, Rails guarantees a current sealing key exists and includes its public
// key (base64), version, and the numeric domain id (bound into the seal AAD).
// E2EE false ⇒ plaintext path, all sealing fields empty.
type DomainInfo struct {
	Found          bool   `json:"found"`
	OrgID          int64  `json:"org_id"`
	OrgKey         string `json:"org_key"`
	Status         string `json:"status"`
	MaxMessageSize int64  `json:"max_message_size_mb"`
	E2EE           bool   `json:"e2ee"`
	E2EEPublicKey  string `json:"e2ee_public_key,omitempty"`
	E2EEKeyVersion int    `json:"e2ee_key_version,omitempty"`
	DomainID       int64  `json:"domain_id,omitempty"`
	// Per-domain toggle (docs/E2EE.md): include a plaintext {from, subject}
	// notification preview alongside the sealed payload so push alerts stay
	// rich. A deliberate, documented leak of exactly those two fields.
	// Default ON (accepted risk); switchable off per domain for a fully
	// content-free posture.
	E2EENotificationPreview bool `json:"e2ee_notification_preview,omitempty"`
	// Org sender filters, present only for E2EE domains: Rails can't evaluate
	// them for sealed mail (no plaintext sender server-side), so the MX applies
	// them in the ingestion window. Values are lowercase addresses or bare
	// domains, matching MailFilter semantics. Staleness ≤ the domain-cache TTL.
	Blocklist []string `json:"blocklist,omitempty"`
	Allowlist []string `json:"allowlist,omitempty"`
}

// InboundMessage is the JSON payload published to the MAIL_INBOUND stream.
//
// For E2EE domains (docs/E2EE.md) EncryptionScheme is "sealed_box_v2", Sealed
// carries the ciphertext + threading HMACs, and every plaintext content field
// (headers, body, raw MIME, sender envelope) is zeroed before publish — the
// durable stream must hold no plaintext for sealed mail.
type InboundMessage struct {
	Version          int                   `json:"version"`
	ReceivedAt       time.Time             `json:"received_at"`
	Envelope         Envelope              `json:"envelope"`
	Headers          Headers               `json:"headers"`
	Body             Body                  `json:"body"`
	Attachments      []AttachmentMeta      `json:"attachments"`
	Authentication   AuthenticationResults `json:"authentication"`
	RawSizeBytes     int64                 `json:"raw_size_bytes"`
	RawMessageB64    string                `json:"raw_message_b64"`
	EncryptionScheme string                `json:"encryption_scheme,omitempty"`
	Sealed           *SealedPayload        `json:"sealed,omitempty"`
}

// SealedPayload is the ciphertext + metadata for a sealed message. Threading
// HMACs are cleartext by design (deterministic, keyed server-side) so Rails can
// group conversations without reading content. Spam fields are the accepted
// low-information metadata leak (same category as the Space label).
type SealedPayload struct {
	DomainID   int64 `json:"domain_id"`
	KeyVersion int   `json:"key_version"`
	// AAD is the exact additional-authenticated-data string bound into every
	// ciphertext of this message (see seal.AAD). Stored on the row and served
	// to clients verbatim — they cannot rebuild it (it embeds the internal
	// domain id, which is never otherwise exposed).
	AAD              string             `json:"aad"`
	SealedDEK        string             `json:"sealed_dek"`
	BodyNonce        string             `json:"body_nonce"`
	BodyCiphertext   string             `json:"body_ciphertext"`
	HeaderNonce      string             `json:"header_nonce"`
	HeaderCiphertext string             `json:"header_ciphertext"`
	MsgidHmac        string             `json:"msgid_hmac,omitempty"`
	RefsHmac         []string           `json:"refs_hmac,omitempty"`
	SubjectHmac      string             `json:"subject_hmac,omitempty"`
	SpamScore        *float64           `json:"spam_score,omitempty"`
	SpamAction       string             `json:"spam_action,omitempty"`
	SpamSymbols      []string           `json:"spam_symbols,omitempty"`
	Attachments      []SealedAttachment `json:"attachments,omitempty"`
	// NotificationPreview is present unless the domain opted OUT of rich push
	// alerts for sealed mail (DomainInfo.E2EENotificationPreview): a plaintext
	// copy of exactly {from, subject} — nothing else — used for the alert and
	// never stored on the message row. Deliberate, documented leak.
	NotificationPreview *NotificationPreview `json:"notification_preview,omitempty"`
}

// NotificationPreview is the opt-in plaintext alert content for sealed mail.
type NotificationPreview struct {
	From    string `json:"from"`
	Subject string `json:"subject"`
}

// SealedAttachment describes one attachment whose ciphertext the MX spooled for
// direct upload to object storage. The filename is sealed (filenames leak
// content); the object key/nonces/content-type are metadata Rails stores as-is.
type SealedAttachment struct {
	Index          int    `json:"index"`
	ObjectKey      string `json:"object_key"`
	SealedFilename string `json:"sealed_filename"`
	FilenameNonce  string `json:"filename_nonce"`
	ContentNonce   string `json:"content_nonce"`
	SizeBytes      int64  `json:"size_bytes"`
	ContentType    string `json:"content_type"`
	ContentID      string `json:"content_id,omitempty"`
	IsInline       bool   `json:"is_inline"`
}

// TriageExcerpt is the transient plaintext published to the MEMORY-backed
// triage stream (never durable; ~10 min TTL). Carries just enough for the
// classification worker: routing ids + the classifier excerpt.
type TriageExcerpt struct {
	OrgID      int64     `json:"org_id"`
	DomainID   int64     `json:"domain_id"`
	MsgidHmac  string    `json:"msgid_hmac"`
	Subject    string    `json:"subject"`
	From       string    `json:"from"`
	To         string    `json:"to"`
	Excerpt    string    `json:"excerpt"`
	ReceivedAt time.Time `json:"received_at"`
}

// Envelope holds SMTP envelope data.
type Envelope struct {
	MailFrom   string   `json:"mail_from"`
	RcptTo     []string `json:"rcpt_to"`
	ClientIP   string   `json:"client_ip"`
	HeloDomain string   `json:"helo_domain"`
}

// Headers holds parsed RFC 5322 headers.
type Headers struct {
	MessageID   string `json:"message_id"`
	InReplyTo   string `json:"in_reply_to"`
	References  string `json:"references"`
	From        string `json:"from"`
	To          string `json:"to"`
	CC          string `json:"cc"`
	Subject     string `json:"subject"`
	Date        string `json:"date"`
	ContentType string `json:"content_type"`
}

// Body holds extracted text and HTML parts.
type Body struct {
	Plain string `json:"plain"`
	HTML  string `json:"html"`
}

// AttachmentMeta holds metadata for a MIME attachment (content stored separately).
type AttachmentMeta struct {
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
	ContentID   string `json:"content_id,omitempty"`
	IsInline    bool   `json:"is_inline"`
}

// AuthenticationResults holds SPF/DKIM/DMARC check results.
type AuthenticationResults struct {
	SPF   AuthResult `json:"spf"`
	DKIM  AuthResult `json:"dkim"`
	DMARC AuthResult `json:"dmarc"`
}

// AuthResult is a single authentication check result.
type AuthResult struct {
	Result   string `json:"result"`
	Domain   string `json:"domain,omitempty"`
	Selector string `json:"selector,omitempty"`
	Policy   string `json:"policy,omitempty"`
}

// Publisher wraps a NATS connection for publishing inbound mail to JetStream.
type Publisher struct {
	nc     *nats.Conn
	js     jetstream.JetStream
	stream jetstream.Stream
}

// NewPublisher connects to NATS and ensures the MAIL_INBOUND stream exists.
func NewPublisher(natsURL string) (*Publisher, error) {
	nc, err := nats.Connect(natsURL,
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2*time.Second),
		nats.Name("inbox2-mx"),
	)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("jetstream context: %w", err)
	}

	p := &Publisher{nc: nc, js: js}
	if err := p.ensureStream(); err != nil {
		nc.Close()
		return nil, err
	}
	return p, nil
}

// NewPublisherFromConn creates a Publisher from an existing NATS connection (for testing).
func NewPublisherFromConn(nc *nats.Conn) (*Publisher, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream context: %w", err)
	}

	p := &Publisher{nc: nc, js: js}
	if err := p.ensureStream(); err != nil {
		return nil, err
	}
	return p, nil
}

func (p *Publisher) ensureStream() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := p.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:       StreamName,
		Subjects:   []string{SubjectPrefix + ">"},
		Retention:  jetstream.WorkQueuePolicy,
		MaxAge:     DefaultStreamMaxAge,
		MaxBytes:   DefaultStreamMaxBytes,
		MaxMsgSize: int32(DefaultMaxMsgSize),
		Storage:    jetstream.FileStorage,
		Discard:    jetstream.DiscardOld,
		Duplicates: DuplicateWindow,
	})
	if err != nil {
		return fmt.Errorf("ensure stream %s: %w", StreamName, err)
	}
	p.stream = stream
	return p.ensureTriageStream()
}

// ensureTriageStream stands up the MEMORY-backed transient stream for triage
// excerpts (docs/E2EE.md). Limits retention: every excerpt ages out at MaxAge
// (or is displaced under MaxBytes pressure) whether or not it was consumed —
// the hard bound on transient plaintext. Never spilled to disk.
func (p *Publisher) ensureTriageStream() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := p.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:      TriageStreamName,
		Subjects:  []string{TriageSubjectPrefix + ">"},
		Retention: jetstream.LimitsPolicy,
		MaxAge:    TriageStreamMaxAge,
		MaxBytes:  TriageStreamMaxBytes,
		Storage:   jetstream.MemoryStorage,
		Discard:   jetstream.DiscardOld,
	})
	if err != nil {
		return fmt.Errorf("ensure stream %s: %w", TriageStreamName, err)
	}
	return nil
}

// Publish sends an InboundMessage to the MAIL_INBOUND stream for the given
// domain. msgID, when non-empty, is set as the JetStream Nats-Msg-Id: it must
// be deterministic across SMTP-level retries of the same transaction, so a
// sender retrying after a partial multi-domain publish failure (session.go
// returns 451) doesn't duplicate the domains that already published. Dedupe
// only holds within the stream's DuplicateWindow.
func (p *Publisher) Publish(ctx context.Context, domain, msgID string, msg *InboundMessage) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal message: %w", err)
	}

	var opts []jetstream.PublishOpt
	if msgID != "" {
		opts = append(opts, jetstream.WithMsgID(msgID))
	}
	subject := SubjectPrefix + domain
	_, err = p.js.Publish(ctx, subject, data, opts...)
	if err != nil {
		return fmt.Errorf("publish to %s: %w", subject, err)
	}
	return nil
}

// PublishTriage sends a transient plaintext excerpt to the memory-backed triage
// stream. Best-effort by contract: a failure here must never fail mail
// acceptance (the message just goes unlabeled).
func (p *Publisher) PublishTriage(ctx context.Context, domain string, excerpt *TriageExcerpt) error {
	data, err := json.Marshal(excerpt)
	if err != nil {
		return fmt.Errorf("marshal excerpt: %w", err)
	}
	subject := TriageSubjectPrefix + domain
	if _, err := p.js.Publish(ctx, subject, data); err != nil {
		return fmt.Errorf("publish to %s: %w", subject, err)
	}
	return nil
}

// LookupDomain sends a request-reply to the Rails app to validate a recipient domain.
func (p *Publisher) LookupDomain(domain string) (*DomainInfo, error) {
	req, err := json.Marshal(map[string]string{"domain": domain})
	if err != nil {
		return nil, fmt.Errorf("marshal lookup request: %w", err)
	}

	resp, err := p.nc.Request(DomainLookupSubject, req, DomainLookupTimeout)
	if err != nil {
		return nil, fmt.Errorf("domain lookup for %s: %w", domain, err)
	}

	var info DomainInfo
	if err := json.Unmarshal(resp.Data, &info); err != nil {
		return nil, fmt.Errorf("unmarshal domain lookup response: %w", err)
	}
	return &info, nil
}

// Connected returns true if the NATS connection is active.
func (p *Publisher) Connected() bool {
	return p.nc.IsConnected()
}

// Close drains and closes the NATS connection.
func (p *Publisher) Close() error {
	return p.nc.Drain()
}

package smtpd

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/inbox2/mta/internal/parser"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/seal"
	"github.com/inbox2/mta/internal/spool"
)

// EncryptionSchemeSealedBoxV2 mirrors Message::ENCRYPTION_SCHEME_SEALED_BOX_V2.
const EncryptionSchemeSealedBoxV2 = "sealed_box_v2"

// Rails' step-3 subject threading refuses normalized subjects shorter than 5
// chars (grouping on "hi" would be garbage). Sealed rows only carry the HMAC,
// so the length safeguard must be applied HERE, before hashing.
const minSubjectThreadingLength = 5

// sealedHeader is the plaintext structure encrypted into header_ciphertext.
// Everything a client needs to render the message row without the body.
type sealedHeader struct {
	Subject   string `json:"subject"`
	From      string `json:"from"`
	To        string `json:"to"`
	CC        string `json:"cc,omitempty"`
	Snippet   string `json:"snippet"`
	MessageID string `json:"message_id,omitempty"`
	InReplyTo string `json:"in_reply_to,omitempty"`
	Date      string `json:"date,omitempty"`
}

// sealedBody is the plaintext structure encrypted into body_ciphertext.
type sealedBody struct {
	Plain string `json:"plain"`
	HTML  string `json:"html"`
}

// sealer builds sealed InboundMessages in the ingestion window. Stateless
// except for the attachment spool; safe for concurrent sessions.
type sealer struct {
	hmacKey []byte
	store   *spool.Store // nil ⇒ attachment sealing unavailable (stripped, logged)
	kick    func()       // nudges the spool uploader after a Put (may be nil)
}

// available reports whether sealing can run at all (threading key delivered).
func (sl *sealer) available() bool {
	return sl != nil && len(sl.hmacKey) > 0
}

// sealMessage converts a parsed message into the sealed InboundMessage +
// transient triage excerpt for one recipient domain. On return, the durable
// payload holds no plaintext content or sender identity.
func (sl *sealer) sealMessage(
	parsed *parser.ParsedMessage,
	info *queue.DomainInfo,
	rcptAddrs []string,
	receivedAt time.Time,
	rawSize int64,
	authResults queue.AuthenticationResults,
	spam *spamVerdict,
) (*queue.InboundMessage, *queue.TriageExcerpt, []string, error) {
	// Threading HMACs (deterministic, keyed — shared derivation with Rails).
	msgidHmac := ""
	if parsed.MessageID != "" {
		msgidHmac = seal.ThreadingHMAC(sl.hmacKey, parsed.MessageID)
	}
	// refs_hmac carries References plus In-Reply-To (appended last, deduped):
	// Rails walks the list newest-first, so In-Reply-To — the most reliable
	// parent pointer — is checked first, mirroring the plaintext threading.
	var refsHmac []string
	seen := map[string]bool{}
	for _, ref := range strings.Fields(parsed.References) {
		h := seal.ThreadingHMAC(sl.hmacKey, strings.TrimSpace(ref))
		if !seen[h] {
			refsHmac = append(refsHmac, h)
			seen[h] = true
		}
	}
	if irt := strings.TrimSpace(parsed.InReplyTo); irt != "" {
		if h := seal.ThreadingHMAC(sl.hmacKey, irt); !seen[h] {
			refsHmac = append(refsHmac, h)
		}
	}
	subjectHmac := ""
	if normalized := seal.NormalizeSubject(parsed.Subject); utf8.RuneCountInString(normalized) >= minSubjectThreadingLength {
		subjectHmac = seal.ThreadingHMAC(sl.hmacKey, normalized)
	}

	dek, err := seal.GenerateDEK()
	if err != nil {
		return nil, nil, nil, err
	}
	defer zero(dek)
	aad := seal.AAD(info.DomainID, info.E2EEKeyVersion, msgidHmac)

	snippet := seal.BuildSnippet(parsed.BodyPlain, parsed.BodyHTML)
	headerJSON, err := json.Marshal(sealedHeader{
		Subject: parsed.Subject, From: parsed.From, To: parsed.To, CC: parsed.CC,
		Snippet: snippet, MessageID: parsed.MessageID, InReplyTo: parsed.InReplyTo, Date: parsed.Date,
	})
	if err != nil {
		return nil, nil, nil, err
	}
	bodyJSON, err := json.Marshal(sealedBody{Plain: parsed.BodyPlain, HTML: parsed.BodyHTML})
	if err != nil {
		return nil, nil, nil, err
	}

	headerNonce, headerCT, err := seal.Encrypt(dek, headerJSON, seal.PartAAD(aad, seal.RoleHeader))
	if err != nil {
		return nil, nil, nil, err
	}
	bodyNonce, bodyCT, err := seal.Encrypt(dek, bodyJSON, seal.PartAAD(aad, seal.RoleBody))
	if err != nil {
		return nil, nil, nil, err
	}
	sealedDEK, err := seal.SealDEK(dek, info.E2EEPublicKey)
	if err != nil {
		return nil, nil, nil, err
	}

	sealedAtts, warnings, err := sl.sealAttachments(dek, aad, info, parsed.Attachments)
	if err != nil {
		return nil, nil, nil, err
	}

	payload := &queue.SealedPayload{
		DomainID:         info.DomainID,
		KeyVersion:       info.E2EEKeyVersion,
		AAD:              string(aad),
		SealedDEK:        base64.StdEncoding.EncodeToString(sealedDEK),
		BodyNonce:        base64.StdEncoding.EncodeToString(bodyNonce),
		BodyCiphertext:   base64.StdEncoding.EncodeToString(bodyCT),
		HeaderNonce:      base64.StdEncoding.EncodeToString(headerNonce),
		HeaderCiphertext: base64.StdEncoding.EncodeToString(headerCT),
		MsgidHmac:        msgidHmac,
		RefsHmac:         refsHmac,
		SubjectHmac:      subjectHmac,
		Attachments:      sealedAtts,
	}
	if spam != nil {
		payload.SpamScore = &spam.Score
		payload.SpamAction = spam.Action
		payload.SpamSymbols = spam.Symbols
	}
	// Rich alerts (default ON, per-domain switchable): exactly from + subject,
	// nothing else (no snippet, no body). Domains that opt out get the fully
	// content-free push.
	if info.E2EENotificationPreview {
		payload.NotificationPreview = &queue.NotificationPreview{
			From:    parsed.From,
			Subject: parsed.Subject,
		}
	}

	msg := &queue.InboundMessage{
		Version:    1,
		ReceivedAt: receivedAt,
		// Sender identity (MAIL FROM / client IP / HELO) is deliberately absent:
		// the sealed header carries From/To for the client, and sender filtering
		// already ran MX-inline. RcptTo alone routes the message org-side.
		Envelope: queue.Envelope{RcptTo: rcptAddrs},
		// Auth verdicts stay (metadata); the sender-identifying domain/selector
		// details do not.
		Authentication: queue.AuthenticationResults{
			SPF:   queue.AuthResult{Result: authResults.SPF.Result},
			DKIM:  queue.AuthResult{Result: authResults.DKIM.Result},
			DMARC: queue.AuthResult{Result: authResults.DMARC.Result, Policy: authResults.DMARC.Policy},
		},
		RawSizeBytes:     rawSize,
		EncryptionScheme: EncryptionSchemeSealedBoxV2,
		Sealed:           payload,
	}

	body := parsed.BodyPlain
	if strings.TrimSpace(body) == "" {
		body = seal.BuildSnippet("", parsed.BodyHTML) // stripped HTML fallback
	}
	excerpt := &queue.TriageExcerpt{
		OrgID:      info.OrgID,
		DomainID:   info.DomainID,
		MsgidHmac:  msgidHmac,
		Subject:    parsed.Subject,
		From:       parsed.From,
		To:         parsed.To,
		Excerpt:    truncateRunes(body, 1200),
		ReceivedAt: receivedAt,
	}

	return msg, excerpt, warnings, nil
}

// sealAttachments encrypts each attachment under the message DEK and durably
// spools the ciphertext for async upload. Filenames are sealed alongside
// (plaintext filenames leak content). With no spool configured, attachments
// are STRIPPED rather than silently stored in plaintext — the caller logs the
// returned warnings.
func (sl *sealer) sealAttachments(dek, aad []byte, info *queue.DomainInfo, atts []parser.Attachment) ([]queue.SealedAttachment, []string, error) {
	if len(atts) == 0 {
		return nil, nil, nil
	}
	if sl.store == nil {
		return nil, []string{fmt.Sprintf("stripped %d attachment(s): sealed-attachment spool not configured", len(atts))}, nil
	}

	var out []queue.SealedAttachment
	for i, att := range atts {
		attAAD := append(append([]byte{}, aad...), []byte(fmt.Sprintf("|att:%d", i))...)
		nameAAD := append(append([]byte{}, attAAD...), []byte("|name")...)

		contentNonce, contentCT, err := seal.Encrypt(dek, att.Content, attAAD)
		if err != nil {
			return nil, nil, err
		}
		filename := att.Filename
		if filename == "" {
			filename = "unnamed"
		}
		nameNonce, nameCT, err := seal.Encrypt(dek, []byte(filename), nameAAD)
		if err != nil {
			return nil, nil, err
		}

		objectKey := fmt.Sprintf("%s/sealed/%s/%s/att-%d",
			info.OrgKey, time.Now().UTC().Format("2006/01/02"), randomHex(8), i)
		// Durable BEFORE the SMTP ack: from here the spooled ciphertext is the
		// only copy of the attachment.
		if err := sl.store.Put(objectKey, contentCT); err != nil {
			return nil, nil, fmt.Errorf("spool attachment %d: %w", i, err)
		}

		out = append(out, queue.SealedAttachment{
			Index:          i,
			ObjectKey:      objectKey,
			SealedFilename: base64.StdEncoding.EncodeToString(nameCT),
			FilenameNonce:  base64.StdEncoding.EncodeToString(nameNonce),
			ContentNonce:   base64.StdEncoding.EncodeToString(contentNonce),
			SizeBytes:      att.SizeBytes,
			ContentType:    att.ContentType,
			ContentID:      att.ContentID,
			IsInline:       att.IsInline,
		})
	}
	if sl.kick != nil {
		sl.kick()
	}
	return out, nil, nil
}

// senderBlocked applies the org blocklist (delivered on DomainInfo for sealed
// domains) against the envelope sender and header-From address.
func senderBlocked(info *queue.DomainInfo, mailFrom, headerFrom string) bool {
	return filterMatches(info.Blocklist, mailFrom) || filterMatches(info.Blocklist, headerFrom)
}

// senderAllowlisted mirrors Rails: an allowlisted sender skips spam scoring.
func senderAllowlisted(info *queue.DomainInfo, mailFrom, headerFrom string) bool {
	return filterMatches(info.Allowlist, mailFrom) || filterMatches(info.Allowlist, headerFrom)
}

func filterMatches(patterns []string, address string) bool {
	address = strings.ToLower(strings.TrimSpace(strings.Trim(address, "<>")))
	if address == "" || len(patterns) == 0 {
		return false
	}
	domain := ""
	if at := strings.LastIndex(address, "@"); at >= 0 {
		domain = address[at+1:]
	}
	for _, p := range patterns {
		if p == address || (domain != "" && p == domain) {
			return true
		}
	}
	return false
}

// isReport detects DSN/ARF machine reports (multipart/report), which route down
// the PLAINTEXT path even for sealed domains — Rails' delivery-status and
// complaint processing needs the raw MIME. Documented accepted leak.
func isReport(contentType string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(contentType)), "multipart/report")
}

func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}

func randomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "00000000"
	}
	return hex.EncodeToString(buf)
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

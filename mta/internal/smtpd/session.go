package smtpd

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/mail"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-smtp"
	"github.com/inbox2/mta/internal/auth"
	"github.com/inbox2/mta/internal/metrics"
	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/parser"
	"github.com/inbox2/mta/internal/queue"
)

// recipient tracks a validated RCPT TO address and its domain info.
type recipient struct {
	address string
	domain  string
	info    *queue.DomainInfo
}

// Session handles a single SMTP connection/transaction.
type Session struct {
	backend    *Backend
	clientIP   string
	heloDomain string
	mailFrom   string
	recipients []recipient
}

// Mail handles the MAIL FROM command.
func (s *Session) Mail(from string, opts *smtp.MailOptions) error {
	s.mailFrom = from
	s.backend.log.MailFrom(s.clientIP, from)
	return nil
}

// Rcpt handles the RCPT TO command. Rejections count against the client IP's
// failure budget (backend.go); an exhausted budget tempfails every further
// RCPT from that IP for the rest of the window (directory-harvest brake).
func (s *Session) Rcpt(to string, opts *smtp.RcptOptions) error {
	if s.backend.rcptBudgetExhausted(s.clientIP) {
		s.backend.log.RcptReject(s.clientIP, to, "", 451, "per-IP RCPT failure budget exhausted")
		return &smtp.SMTPError{
			Code:         451,
			EnhancedCode: smtp.EnhancedCode{4, 7, 1},
			Message:      "Too many failed recipients, try later",
		}
	}
	err := s.rcpt(to)
	if err != nil {
		s.backend.recordRcptFailure(s.clientIP)
		return err
	}
	// Greylisting (edge.go) runs AFTER recipient validation so a tempfailed
	// first contact is a real deliverable triple — and doesn't burn the
	// client's RCPT-failure budget (it's not a bad address).
	if s.backend.greylisted(s.clientIP, s.mailFrom, to) {
		s.backend.log.RcptReject(s.clientIP, to, "", 451, "greylisted, retry shortly")
		metrics.Inc("mx_rejects_total", "reason", "greylist")
		return &smtp.SMTPError{
			Code:         451,
			EnhancedCode: smtp.EnhancedCode{4, 7, 1},
			Message:      "Greylisted, please retry shortly",
		}
	}
	return nil
}

// rcpt validates one recipient (domain lookup via NATS) and records it.
func (s *Session) rcpt(to string) error {
	start := time.Now()
	domain := extractDomain(to)
	if domain == "" {
		s.backend.log.RcptReject(s.clientIP, to, "", 550, "bad recipient address")
		return &smtp.SMTPError{
			Code:         550,
			EnhancedCode: smtp.EnhancedCode{5, 1, 3},
			Message:      "Bad recipient address",
		}
	}

	info, err := s.backend.domains.Get(domain)
	if err != nil {
		s.backend.log.RcptReject(s.clientIP, to, domain, 451, fmt.Sprintf("lookup error: %v", err))
		return &smtp.SMTPError{
			Code:         451,
			EnhancedCode: smtp.EnhancedCode{4, 4, 3},
			Message:      "Domain lookup timeout, try later",
		}
	}

	if !info.Found {
		s.backend.log.RcptReject(s.clientIP, to, domain, 550, "no such domain")
		return &smtp.SMTPError{
			Code:         550,
			EnhancedCode: smtp.EnhancedCode{5, 1, 2},
			Message:      "No such domain",
		}
	}

	if info.Status != "verified" && info.Status != "receiving_mail" {
		s.backend.log.RcptReject(s.clientIP, to, domain, 450, fmt.Sprintf("domain status: %s", info.Status))
		return &smtp.SMTPError{
			Code:         450,
			EnhancedCode: smtp.EnhancedCode{4, 1, 2},
			Message:      "Domain not yet ready, try later",
		}
	}

	s.recipients = append(s.recipients, recipient{address: to, domain: domain, info: info})
	s.backend.log.RcptTo(s.clientIP, to, domain, info.OrgKey, mxlog.DurationMs(time.Since(start)))
	return nil
}

// Data handles the DATA command. Reads the message, parses it, checks auth, publishes to NATS.
func (s *Session) Data(r io.Reader) error {
	dataStart := time.Now()

	if len(s.recipients) == 0 {
		s.backend.log.DataReject(s.clientIP, s.mailFrom, 503, "no valid recipients")
		return &smtp.SMTPError{
			Code:         503,
			EnhancedCode: smtp.EnhancedCode{5, 5, 1},
			Message:      "No valid recipients",
		}
	}

	// Use the smallest size limit across all recipients (strictest plan wins)
	maxSizeMB := s.recipients[0].info.MaxMessageSize
	for _, rcpt := range s.recipients[1:] {
		if rcpt.info.MaxMessageSize < maxSizeMB {
			maxSizeMB = rcpt.info.MaxMessageSize
		}
	}
	maxSize := maxSizeMB * 1024 * 1024
	if maxSize <= 0 {
		maxSize = 20 * 1024 * 1024 // fallback to 20MB
	}
	limitedReader := io.LimitReader(r, maxSize+1) // +1 to detect oversized

	var buf bytes.Buffer
	n, err := io.Copy(&buf, limitedReader)
	if err != nil {
		s.backend.log.DataReject(s.clientIP, s.mailFrom, 451, fmt.Sprintf("read error: %v", err))
		return &smtp.SMTPError{
			Code:         451,
			EnhancedCode: smtp.EnhancedCode{4, 3, 0},
			Message:      "Internal server error",
		}
	}

	if n > maxSize {
		s.backend.log.DataReject(s.clientIP, s.mailFrom, 552, fmt.Sprintf("size %d exceeds %dMB limit", n, maxSizeMB))
		return &smtp.SMTPError{
			Code:         552,
			EnhancedCode: smtp.EnhancedCode{5, 3, 4},
			Message:      fmt.Sprintf("Message size exceeds limit (%dMB)", maxSizeMB),
		}
	}

	rawBytes := buf.Bytes()

	// Parse the message first so DMARC can be evaluated against the RFC5322.From
	// header domain (per RFC 7489), not the SMTP envelope sender.
	parseStart := time.Now()
	parsed, err := parser.Parse(rawBytes)
	parseDuration := time.Since(parseStart)

	if err != nil {
		s.backend.log.ParseError(err)
		parsed = &parser.ParsedMessage{
			Subject: "(parse error)",
		}
	}

	fromHeaderDomain := headerDomain(parsed.From)

	// Run authentication checks. DKIM verifies the original received bytes
	// (before we prepend our own Received header).
	authStart := time.Now()
	authResults := s.checkAuthentication(rawBytes, fromHeaderDomain)
	authDuration := time.Since(authStart)

	// Check DMARC policy enforcement
	if authResults.DMARC.Result == "fail" && authResults.DMARC.Policy == "reject" {
		s.backend.log.AuthResult(s.clientIP, parsed.MessageID, authResults.SPF.Result, authResults.DKIM.Result, authResults.DMARC.Result, authResults.DMARC.Policy, mxlog.DurationMs(authDuration))
		s.backend.log.DataReject(s.clientIP, s.mailFrom, 550, "DMARC policy reject")
		return &smtp.SMTPError{
			Code:         550,
			EnhancedCode: smtp.EnhancedCode{5, 7, 1},
			Message:      "Authentication failed (DMARC policy reject)",
		}
	}

	s.backend.log.AuthResult(s.clientIP, parsed.MessageID, authResults.SPF.Result, authResults.DKIM.Result, authResults.DMARC.Result, authResults.DMARC.Policy, mxlog.DurationMs(authDuration))
	s.backend.log.ParseComplete(parsed.MessageID, parsed.BodyPlain != "", parsed.BodyHTML != "", len(parsed.Attachments), mxlog.DurationMs(parseDuration))

	// Prepend a trace header (RFC 5321 §4.4). DKIM has already verified the
	// original bytes above, so adding this does not affect authentication.
	finalRaw := s.prependReceived(rawBytes, parsed.MessageID)
	n = int64(len(finalRaw))
	rawB64 := base64.StdEncoding.EncodeToString(finalRaw)
	allAddrs := make([]string, len(s.recipients))
	for i, r := range s.recipients {
		allAddrs[i] = r.address
	}

	// Group recipients by domain and publish one message per domain
	byDomain := make(map[string][]string)
	infoByDomain := make(map[string]*queue.DomainInfo)
	for _, rcpt := range s.recipients {
		byDomain[rcpt.domain] = append(byDomain[rcpt.domain], rcpt.address)
		infoByDomain[rcpt.domain] = rcpt.info
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	anySealed := false
	for domain, addrs := range byDomain {
		info := infoByDomain[domain]
		receivedAt := time.Now().UTC()
		// Deterministic per-(transaction, domain) dedupe id: if a later domain's
		// publish fails we return 451 and the sender retries the WHOLE
		// transaction — without this, domains that already published would get
		// the message twice. Keyed on the original received bytes (identical on
		// retry; finalRaw is NOT — the prepended Received header carries a fresh
		// queue id + timestamp) plus envelope identity.
		msgID := inboundMsgID(rawBytes, s.mailFrom, domain, addrs)

		// E2EE seal path (docs/E2EE.md Phase C). DSN/ARF machine reports stay
		// plaintext even for sealed domains — Rails report routing needs the
		// raw MIME (documented accepted leak).
		if info.E2EE && !isReport(parsed.ContentType) {
			if !s.backend.sealer.available() {
				s.backend.log.Warn("seal.unavailable_fallback_plaintext", "domain", domain,
					"reason", "MX_THREADING_HMAC_KEY not configured")
			} else {
				headerFrom := ""
				if addr, err := mail.ParseAddress(parsed.From); err == nil {
					headerFrom = addr.Address
				}

				// Sender blocklist runs MX-inline for sealed domains (Rails has
				// no plaintext sender to check). Same semantics as Rails: the
				// message is accepted on the wire but not stored.
				if senderBlocked(info, s.mailFrom, headerFrom) {
					s.backend.log.Info("seal.sender_blocked", "domain", domain, "message_id", parsed.MessageID)
					continue
				}

				// Inline spam scoring (self-hosted, fast, no egress). Verdict is
				// cleartext metadata on the sealed row. Allowlisted senders skip,
				// mirroring Rails.
				var spam *spamVerdict
				if s.backend.rspamd != nil && !senderAllowlisted(info, s.mailFrom, headerFrom) {
					verdict, spamErr := s.backend.rspamd.check(finalRaw, s.clientIP, s.mailFrom, addrs[0])
					if spamErr != nil {
						s.backend.log.Warn("seal.rspamd_failed", "domain", domain, "error", spamErr.Error())
					} else {
						spam = verdict
					}
				}

				msg, excerpt, warnings, sealErr := s.backend.sealer.sealMessage(
					parsed, info, addrs, receivedAt, n, authResults, spam)
				if sealErr != nil {
					// Never store plaintext for a sealed domain; tempfail so the
					// sender retries once the seal problem is fixed.
					s.backend.log.Error("seal.failed", "domain", domain, "error", sealErr.Error())
					return &smtp.SMTPError{
						Code:         451,
						EnhancedCode: smtp.EnhancedCode{4, 3, 0},
						Message:      "Mail system temporarily unavailable",
					}
				}
				for _, w := range warnings {
					s.backend.log.Warn("seal.attachment_warning", "domain", domain, "warning", w)
				}

				pubStart := time.Now()
				if err := s.backend.publisher.Publish(ctx, domain, msgID, msg); err != nil {
					s.backend.log.NATSPublishError(domain, err)
					return &smtp.SMTPError{
						Code:         451,
						EnhancedCode: smtp.EnhancedCode{4, 3, 0},
						Message:      "Mail system temporarily unavailable",
					}
				}
				// Transient plaintext excerpt for the triage worker — strictly
				// best-effort; the seal already stands.
				if err := s.backend.publisher.PublishTriage(ctx, domain, excerpt); err != nil {
					s.backend.log.Warn("seal.triage_publish_failed", "domain", domain, "error", err.Error())
				}
				s.backend.log.NATSPublish(domain, parsed.MessageID, len(finalRaw), mxlog.DurationMs(time.Since(pubStart)))
				anySealed = true
				continue
			}
		}

		msg := &queue.InboundMessage{
			Version:    1,
			ReceivedAt: receivedAt,
			Envelope: queue.Envelope{
				MailFrom:   s.mailFrom,
				RcptTo:     addrs,
				ClientIP:   s.clientIP,
				HeloDomain: s.heloDomain,
			},
			Headers: queue.Headers{
				MessageID:   parsed.MessageID,
				InReplyTo:   parsed.InReplyTo,
				References:  parsed.References,
				From:        parsed.From,
				To:          parsed.To,
				CC:          parsed.CC,
				Subject:     parsed.Subject,
				Date:        parsed.Date,
				ContentType: parsed.ContentType,
			},
			Body: queue.Body{
				Plain: parsed.BodyPlain,
				HTML:  parsed.BodyHTML,
			},
			Attachments:    convertAttachments(parsed.Attachments),
			Authentication: authResults,
			RawSizeBytes:   n,
			RawMessageB64:  rawB64,
		}

		pubStart := time.Now()
		if err := s.backend.publisher.Publish(ctx, domain, msgID, msg); err != nil {
			s.backend.log.NATSPublishError(domain, err)
			return &smtp.SMTPError{
				Code:         451,
				EnhancedCode: smtp.EnhancedCode{4, 3, 0},
				Message:      "Mail system temporarily unavailable",
			}
		}
		s.backend.log.NATSPublish(domain, parsed.MessageID, len(finalRaw), mxlog.DurationMs(time.Since(pubStart)))
	}

	// Subject is scrubbed from the acceptance log when any recipient domain is
	// sealed — logs are a durable plaintext store (docs/E2EE.md Phase C).
	loggedSubject := parsed.Subject
	if anySealed {
		loggedSubject = "[sealed]"
	}
	s.backend.log.DataAccepted(s.clientIP, s.mailFrom, allAddrs, n, parsed.MessageID, loggedSubject, len(byDomain), mxlog.DurationMs(time.Since(dataStart)))
	metrics.Inc("mx_messages_accepted_total")
	metrics.Add("mx_message_bytes_total", n)
	return nil
}

// Reset is called between transactions (RSET command).
func (s *Session) Reset() {
	s.backend.log.Reset(s.clientIP)
	s.mailFrom = ""
	s.recipients = nil
}

// Logout is called when the connection is closed.
func (s *Session) Logout() error {
	s.backend.releaseConn(s.clientIP)
	s.backend.log.ConnectionClose(s.clientIP)
	return nil
}

// inboundMsgID derives the Nats-Msg-Id for one (transaction, domain) publish.
// Inputs must be stable across an SMTP-level retry of the same transaction:
// the raw bytes as received (before our Received header is prepended), the
// envelope sender, and the sorted recipient set for the domain.
func inboundMsgID(rawBytes []byte, mailFrom, domain string, addrs []string) string {
	sorted := append([]string(nil), addrs...)
	sort.Strings(sorted)
	h := sha256.New()
	h.Write(rawBytes)
	fmt.Fprintf(h, "\x00%s\x00%s\x00%s", mailFrom, domain, strings.Join(sorted, ","))
	return hex.EncodeToString(h.Sum(nil)[:16])
}

func (s *Session) checkAuthentication(rawBytes []byte, fromHeaderDomain string) queue.AuthenticationResults {
	return s.backend.auth.Check(s.clientIP, s.mailFrom, s.heloDomain, fromHeaderDomain, rawBytes)
}

// prependReceived builds an RFC 5321 §4.4 Received trace header and prepends it
// to the raw message. This records the relay hop and enables loop detection
// downstream (by counting Received headers).
func (s *Session) prependReceived(rawBytes []byte, messageID string) []byte {
	id := queueID()
	now := time.Now().UTC().Format(time.RFC1123Z)

	helo := s.heloDomain
	if helo == "" {
		helo = "unknown"
	}

	var b bytes.Buffer
	fmt.Fprintf(&b, "Received: from %s (%s)\r\n", helo, s.clientIP)
	fmt.Fprintf(&b, "\tby %s with ESMTP id %s;\r\n", s.backend.config.Domain, id)
	fmt.Fprintf(&b, "\t%s\r\n", now)
	b.Write(rawBytes)
	return b.Bytes()
}

// queueID returns a random hex identifier for the Received header / tracing.
// If the system RNG fails, fall back to a timestamp-derived ID — a constant
// would make trace headers useless for correlating a specific message.
func queueID() string {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return strings.ToUpper(strconv.FormatInt(time.Now().UnixNano(), 16))
	}
	return strings.ToUpper(hex.EncodeToString(buf[:]))
}

// defaultAuthenticator runs real SPF/DKIM/DMARC checks.
type defaultAuthenticator struct{}

func (a *defaultAuthenticator) Check(clientIP, mailFrom, heloDomain, fromHeaderDomain string, rawBytes []byte) queue.AuthenticationResults {
	results := queue.AuthenticationResults{}

	senderDomain := extractDomain(mailFrom)
	spfResult := auth.CheckSPF(clientIP, mailFrom, heloDomain)
	results.SPF = queue.AuthResult{
		Result: spfResult.Result,
		Domain: senderDomain,
	}

	dkimResult := auth.VerifyDKIM(rawBytes)
	results.DKIM = queue.AuthResult{
		Result:   dkimResult.Result,
		Domain:   dkimResult.Domain,
		Selector: dkimResult.Selector,
	}

	// DMARC is evaluated against the RFC5322.From header domain.
	dmarcResult := auth.CheckDMARC(fromHeaderDomain, spfResult, dkimResult)
	results.DMARC = queue.AuthResult{
		Result: dmarcResult.Result,
		Domain: fromHeaderDomain,
		Policy: dmarcResult.Policy,
	}

	return results
}

// headerDomain extracts the domain from an RFC5322 From header value, which may
// be "Display Name <user@domain>" or a bare address.
func headerDomain(from string) string {
	from = strings.TrimSpace(from)
	if from == "" {
		return ""
	}
	if addr, err := mail.ParseAddress(from); err == nil {
		return extractDomain(addr.Address)
	}
	// Fall back to scanning for the last @ in the raw value.
	return extractDomain(from)
}

func extractDomain(addr string) string {
	// Handle <user@domain> or user@domain
	addr = strings.TrimSpace(addr)
	addr = strings.TrimPrefix(addr, "<")
	addr = strings.TrimSuffix(addr, ">")

	parts := strings.SplitN(addr, "@", 2)
	if len(parts) != 2 {
		return ""
	}
	return strings.ToLower(parts[1])
}

func convertAttachments(parsed []parser.Attachment) []queue.AttachmentMeta {
	out := make([]queue.AttachmentMeta, len(parsed))
	for i, a := range parsed {
		out[i] = queue.AttachmentMeta{
			Filename:    a.Filename,
			ContentType: a.ContentType,
			SizeBytes:   a.SizeBytes,
			ContentID:   a.ContentID,
			IsInline:    a.IsInline,
		}
	}
	return out
}

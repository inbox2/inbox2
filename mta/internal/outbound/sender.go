package outbound

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"

	"github.com/inbox2/mta/internal/seal"

	"github.com/inbox2/mta/internal/dane"
	"github.com/inbox2/mta/internal/mtasts"
	"github.com/inbox2/mta/internal/requiretls"
)

// dialTimeout bounds how long we wait for a TCP connection to an MX host.
const dialTimeout = 30 * time.Second

// Resolver looks up MX records for a domain. Injectable for testing.
type Resolver interface {
	Lookup(domain string) ([]MXRecord, error)
}

// Sender delivers outbound messages via SMTP to remote MTAs.
//
// Retries across time are owned by Rails (DeliveryRetryService re-publishes a
// transient_failure after a backoff), so Send makes a single pass over the MX
// hosts and never blocks a worker with sleeps.
type Sender struct {
	mx       Resolver
	domain   string // EHLO hostname
	port     string // SMTP port (default "25")
	log      *Logger
	keystore *DKIMKeyStore
	// deliveryKey is the MTA delivery private key (docs/E2EE.md Phase I) that
	// opens sealed outbound MIME queued for E2EE domains. Nil ⇒ sealed
	// payloads fail permanently with a clear diagnostic.
	deliveryKey *[32]byte
	// sts caches recipient-domain MTA-STS policies (RFC 8461). In enforce
	// mode a downgraded delivery (non-matching MX, no TLS, invalid cert) is
	// refused as a transient failure instead of sent in the clear.
	sts *mtasts.Store
}

// NewSender creates a Sender with the given EHLO domain and logger.
func NewSender(ehloDomain string, logger *Logger) *Sender {
	return &Sender{
		mx:     NewMXResolver(),
		domain: ehloDomain,
		port:   "25",
		log:    logger,
		sts:    mtasts.NewStore(),
	}
}

// SetSTSStore overrides the MTA-STS policy store (nil disables enforcement —
// used by tests whose sinks can't satisfy PKIX verification).
func (s *Sender) SetSTSStore(store *mtasts.Store) {
	s.sts = store
}

// SetResolver overrides the MX resolver (for testing — point delivery to a sink).
func (s *Sender) SetResolver(r Resolver) {
	s.mx = r
}

// SetPort overrides the SMTP port (for testing — connect to a sink on a non-standard port).
func (s *Sender) SetPort(port string) {
	s.port = port
}

// SetKeyStore configures a local DKIM key store. Keys found locally take
// precedence over keys carried in the message.
func (s *Sender) SetKeyStore(ks *DKIMKeyStore) {
	s.keystore = ks
}

// SetDeliveryKey installs the MTA delivery private key (32 bytes) used to
// decrypt sealed outbound MIME in RAM at delivery time.
func (s *Sender) SetDeliveryKey(priv []byte) error {
	if len(priv) != 32 {
		return fmt.Errorf("delivery key must be 32 bytes, got %d", len(priv))
	}
	var k [32]byte
	copy(k[:], priv)
	s.deliveryKey = &k
	return nil
}

// openSealedMIME decrypts a sealed outbound payload: unseal the DEK with the
// delivery keypair (public derived from the private scalar), then open the
// XChaCha20-Poly1305 ciphertext bound to the message key.
func (s *Sender) openSealedMIME(msg *OutboundMessage) ([]byte, error) {
	if s.deliveryKey == nil {
		return nil, fmt.Errorf("sealed outbound MIME but no SMTP_DELIVERY_PRIVATE_KEY configured")
	}
	sealedDEK, err := base64.StdEncoding.DecodeString(msg.SealedMIME.SealedDEK)
	if err != nil {
		return nil, fmt.Errorf("decode sealed dek: %w", err)
	}
	var pub [32]byte
	curve25519.ScalarBaseMult(&pub, s.deliveryKey)
	dek, ok := box.OpenAnonymous(nil, sealedDEK, &pub, s.deliveryKey)
	if !ok {
		return nil, fmt.Errorf("unseal delivery DEK failed (wrong delivery key?)")
	}
	defer func() {
		for i := range dek {
			dek[i] = 0
		}
	}()
	nonce, err := base64.StdEncoding.DecodeString(msg.SealedMIME.Nonce)
	if err != nil {
		return nil, fmt.Errorf("decode nonce: %w", err)
	}
	ct, err := base64.StdEncoding.DecodeString(msg.SealedMIME.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("decode ciphertext: %w", err)
	}
	return seal.Decrypt(dek, nonce, ct, []byte(msg.MessageKey))
}

// Send delivers an outbound message and returns the delivery result.
// It handles MX lookup, DKIM signing, and a single SMTP delivery pass.
func (s *Sender) Send(msg *OutboundMessage) *DeliveryResult {
	start := time.Now()

	// Decode the RFC 5322 message. Sealed payloads (E2EE domains) decrypt in
	// RAM here — the durable queue held only ciphertext.
	var rawMessage []byte
	var err error
	if msg.SealedMIME != nil {
		rawMessage, err = s.openSealedMIME(msg)
		if err != nil {
			return s.failResult(msg, "permanent_failure", "", "", fmt.Sprintf("open sealed message: %v", err), "", 1)
		}
	} else {
		rawMessage, err = base64.StdEncoding.DecodeString(msg.RFC5322B64)
		if err != nil {
			return s.failResult(msg, "permanent_failure", "", "", fmt.Sprintf("decode message: %v", err), "", 1)
		}
	}

	// DKIM sign if a key is available (local key store wins over message key).
	rawMessage = s.maybeSign(msg, rawMessage)

	// Determine REQUIRETLS policy from the message headers (RFC 8689).
	tlsPolicy := parseRequireTLS(rawMessage)

	// Determine recipient domain for MX lookup
	rcptDomain := extractRecipientDomain(msg.Envelope.RcptTo)
	if rcptDomain == "" {
		return s.failResult(msg, "permanent_failure", "", "", "no valid recipient domain", "", 1)
	}

	// MX lookup
	mxStart := time.Now()
	mxRecords, err := s.mx.Lookup(rcptDomain)
	if err != nil {
		s.log.MXLookupError(rcptDomain, err)
		return s.failResult(msg, "transient_failure", "", "", fmt.Sprintf("MX lookup: %v", err), "", 1)
	}
	s.log.MXLookup(rcptDomain, len(mxRecords), DurationMs(time.Since(mxStart)))

	// MTA-STS (RFC 8461): in enforce mode only policy-matching MX hosts are
	// candidates, and TLS with a PKIX-valid certificate becomes mandatory.
	var stsPolicy *mtasts.Policy
	if s.sts != nil {
		stsPolicy = s.sts.Get(rcptDomain)
	}
	stsEnforce := stsPolicy.Enforce()

	// Single pass over MX hosts in preference order. Rails handles time-based
	// retries; we only walk hosts to find one that accepts (or hard-rejects).
	var lastResult *DeliveryResult
	for _, mx := range mxRecords {
		host := strings.TrimSuffix(mx.Host, ".")
		if stsEnforce && !stsPolicy.MXMatches(host) {
			s.log.Warn("mtasts.mx_skipped", "message_key", msg.MessageKey, "domain", rcptDomain, "host", host)
			continue
		}
		if !msg.Deadline.IsZero() && time.Until(msg.Deadline) <= 0 {
			break // out of time: no further MX hosts
		}
		result := s.deliverToHost(host, msg.Envelope, rawMessage, tlsPolicy, stsEnforce, msg.Deadline)

		s.log.SMTPAttempt(msg.MessageKey, host, 1, result.Result, result.SMTPCode, DurationMs(time.Since(start)))

		result.DeliveryStatusKey = msg.DeliveryStatusKey
		result.MessageKey = msg.MessageKey
		result.AttemptNumber = 1
		result.DeliveredAt = time.Now().UTC()

		if result.Result == "success" || result.Result == "permanent_failure" {
			return result
		}
		lastResult = result // transient — try the next MX host
	}

	if lastResult == nil {
		if stsEnforce {
			return s.failResult(msg, "transient_failure", "", "",
				fmt.Sprintf("no MX host for %s matches its MTA-STS policy", rcptDomain), "", 1)
		}
		return s.failResult(msg, "transient_failure", "", "", "no MX hosts available", "", 1)
	}
	return lastResult
}

// maybeSign DKIM-signs the message if a key is available. Signing failures are
// logged but never fail delivery.
func (s *Sender) maybeSign(msg *OutboundMessage, rawMessage []byte) []byte {
	domain := msg.DKIM.Domain
	selector := msg.DKIM.Selector
	if domain == "" || selector == "" {
		return rawMessage
	}

	keyPEM := msg.DKIM.PrivateKeyPEM
	usedLocalKey := false
	if s.keystore != nil {
		if localKey, ok := s.keystore.Lookup(domain, selector); ok {
			keyPEM = localKey
			usedLocalKey = true
		}
	}
	if keyPEM == "" {
		return rawMessage
	}
	if !usedLocalKey {
		// Signing with key material carried inline in the queue payload —
		// fail-open kept deliberately pending an ops decision on prod keystore
		// provisioning; this line just makes the fallback visible.
		s.log.Warn("dkim.inline_key_fallback", "message_key", msg.MessageKey, "domain", domain, "selector", selector)
	}

	signStart := time.Now()
	signed, err := SignMessage(rawMessage, domain, selector, keyPEM)
	if err != nil {
		s.log.DKIMSignError(msg.MessageKey, err)
		return rawMessage // deliver unsigned rather than not at all
	}
	s.log.DKIMSigned(msg.MessageKey, domain, selector, DurationMs(time.Since(signStart)))
	return signed
}

// deliverToHost attempts SMTP delivery to a single MX host.
func (s *Sender) deliverToHost(host string, envelope OutboundEnvelope, rawMessage []byte, policy requiretls.Policy, stsEnforce bool, deadline time.Time) *DeliveryResult {
	result := &DeliveryResult{Version: 1, MXHost: host}

	// DANE: if the host publishes TLSA records, TLS is mandatory and the
	// certificate must match (downgrade/MITM protection, RFC 7672).
	tlsaRecords, _ := dane.LookupTLSA(host, 25)
	tlsRequired := policy.Required || len(tlsaRecords) > 0 || stsEnforce

	client, err := s.connect(host, deadline)
	if err != nil {
		result.Result = "transient_failure"
		result.ResponseMessage = err.Error()
		return result
	}
	defer func() { client.Close() }()

	// STARTTLS handling.
	if ok, _ := client.Extension("STARTTLS"); ok {
		// Opportunistic by default: skip verification at the handshake and verify
		// explicitly afterwards only when DANE or REQUIRETLS demands it. This lets
		// us encrypt to the many MTAs that present self-signed/mismatched certs.
		tlsConfig := &tls.Config{
			ServerName:         host,
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: true,
		}
		if err := client.StartTLS(tlsConfig); err != nil {
			s.log.STARTTLSFailed(host, err)
			// The connection is unusable after a failed TLS handshake.
			if tlsRequired {
				result.Result = "transient_failure"
				result.ResponseMessage = fmt.Sprintf("TLS required but STARTTLS failed: %v", err)
				return result
			}
			// Reconnect in the clear and continue (opportunistic downgrade). The
			// deferred close captures `client` by reference, so it closes the
			// reconnected client.
			client.Close()
			client, err = s.connect(host, deadline)
			if err != nil {
				result.Result = "transient_failure"
				result.ResponseMessage = fmt.Sprintf("reconnect after STARTTLS failure: %v", err)
				return result
			}
		} else {
			state, _ := client.TLSConnectionState()
			result.TLSVersion = tlsVersionString(state.Version)

			if len(tlsaRecords) > 0 {
				if r := dane.VerifyConnectionState(state, tlsaRecords); !r.Verified {
					result.Result = "transient_failure"
					result.ResponseMessage = fmt.Sprintf("DANE verification failed for %s: %v", host, r.Error)
					return result
				}
			}
			if policy.Required {
				if err := requiretls.ValidateConnectionState(state, host); err != nil {
					result.Result = "transient_failure"
					result.ResponseMessage = err.Error()
					return result
				}
			}
			// MTA-STS enforce demands the same PKIX bar: valid chain + name
			// match (RFC 8461 §4.2); a failed check must not fall back to
			// cleartext or an unverified session.
			if stsEnforce {
				if err := requiretls.ValidateConnectionState(state, host); err != nil {
					result.Result = "transient_failure"
					result.ResponseMessage = fmt.Sprintf("MTA-STS: %v", err)
					return result
				}
			}
		}
	} else if tlsRequired {
		result.Result = "transient_failure"
		result.ResponseMessage = "TLS required but server does not offer STARTTLS"
		return result
	}

	// MAIL FROM + RCPT TO. Domains go out punycoded and a non-ASCII local part
	// negotiates SMTPUTF8 (RFC 6531) — see eai.go.
	if err := sendEnvelope(client, envelope.MailFrom, envelope.RcptTo); err != nil {
		return classifySMTPError(result, err)
	}

	// DATA, by hand on the text connection: net/smtp's Data().Close() throws
	// away the text of the final 250, and the relay passes it on.
	id, err := client.Text.Cmd("DATA")
	if err != nil {
		return classifySMTPError(result, err)
	}
	client.Text.StartResponse(id)
	_, _, err = client.Text.ReadResponse(354)
	client.Text.EndResponse(id)
	if err != nil {
		return classifySMTPError(result, err)
	}
	wc := client.Text.DotWriter()
	if _, err := wc.Write(rawMessage); err != nil {
		wc.Close()
		result.Result = "transient_failure"
		result.ResponseMessage = fmt.Sprintf("DATA write: %v", err)
		return result
	}
	if err := wc.Close(); err != nil {
		result.Result = "transient_failure"
		result.ResponseMessage = fmt.Sprintf("DATA write: %v", err)
		return result
	}
	_, text, err := client.Text.ReadResponse(250)
	if err != nil {
		return classifySMTPError(result, err)
	}

	// The remote has accepted the message. Say QUIT but do not wait for the
	// 221: a slow goodbye must not hold the result back.
	client.Text.PrintfLine("QUIT")

	result.Result = "success"
	result.SMTPCode = "250"
	result.EnhancedCode = "2.0.0"
	result.ResponseMessage = text
	return result
}

// connect dials the host and completes EHLO.
// A non-zero deadline bounds the whole conversation on this connection.
func (s *Sender) connect(host string, deadline time.Time) (*smtp.Client, error) {
	addr := net.JoinHostPort(host, s.port)
	timeout := dialTimeout
	if !deadline.IsZero() {
		if timeout = min(timeout, time.Until(deadline)); timeout <= 0 {
			return nil, fmt.Errorf("connect: out of time")
		}
	}
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if !deadline.IsZero() {
		conn.SetDeadline(deadline)
	}
	client, err := smtp.NewClient(conn, host)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("smtp client: %w", err)
	}
	if err := client.Hello(s.domain); err != nil {
		client.Close()
		return nil, fmt.Errorf("EHLO: %w", err)
	}
	return client, nil
}

// classifySMTPError maps an SMTP error to a delivery result. It uses the
// structured SMTP reply code when available (textproto.Error) rather than
// string-slicing, so non-protocol errors are correctly treated as transient.
func classifySMTPError(result *DeliveryResult, err error) *DeliveryResult {
	var protoErr *textproto.Error
	if errors.As(err, &protoErr) {
		result.SMTPCode = fmt.Sprintf("%d", protoErr.Code)
		result.ResponseMessage = err.Error()
		if protoErr.Code >= 500 && protoErr.Code < 600 {
			result.Result = "permanent_failure"
		} else {
			result.Result = "transient_failure"
		}
		return result
	}

	// Not an SMTP reply (e.g. connection reset, timeout): transient.
	result.Result = "transient_failure"
	result.ResponseMessage = err.Error()
	return result
}

func (s *Sender) failResult(msg *OutboundMessage, result, code, enhanced, response, host string, attempt int) *DeliveryResult {
	return &DeliveryResult{
		Version:           1,
		DeliveryStatusKey: msg.DeliveryStatusKey,
		MessageKey:        msg.MessageKey,
		Result:            result,
		SMTPCode:          code,
		EnhancedCode:      enhanced,
		ResponseMessage:   response,
		MXHost:            host,
		AttemptNumber:     attempt,
		DeliveredAt:       time.Now().UTC(),
	}
}

func extractRecipientDomain(rcptTo []string) string {
	if len(rcptTo) == 0 {
		return ""
	}
	parts := strings.SplitN(rcptTo[0], "@", 2)
	if len(parts) != 2 {
		return ""
	}
	// Punycode: DNS has no Unicode labels, so an MX lookup for "مثال.السعودية"
	// only resolves in its A-label form.
	return toASCIIDomain(strings.ToLower(parts[1]))
}

// parseRequireTLS extracts the REQUIRETLS policy from the message's TLS-Required
// header (RFC 8689).
func parseRequireTLS(rawMessage []byte) requiretls.Policy {
	msg, err := mail.ReadMessage(bytes.NewReader(rawMessage))
	if err != nil {
		return requiretls.Policy{}
	}
	return requiretls.ParseHeader(map[string]string{
		requiretls.HeaderField: msg.Header.Get(requiretls.HeaderField),
	})
}

func tlsVersionString(v uint16) string {
	switch v {
	case tls.VersionTLS10:
		return "TLS 1.0"
	case tls.VersionTLS11:
		return "TLS 1.1"
	case tls.VersionTLS12:
		return "TLS 1.2"
	case tls.VersionTLS13:
		return "TLS 1.3"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}

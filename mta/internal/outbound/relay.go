package outbound

import (
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-sasl"
	gosmtp "github.com/emersion/go-smtp"

	"github.com/inbox2/mta/internal/metrics"
)

// Authenticated pass-through relay (docs/Mail-Deliverability.md "Relay"). A
// trusted sender (Pushleft's customer mail) submits one message per recipient;
// we deliver it to the recipient's MX while the client waits and answer DATA
// with the remote MX's own reply. Nothing is queued, so nothing is ever
// accepted here and bounced later: retries and bounce handling stay with the
// client. Message bytes and the envelope sender pass through unchanged — no
// DKIM signing (the message carries no DKIM config), no Received header.

// The client holds its DATA open while we deliver, and Pushleft gives up after
// 180s. If we answered later than that, it would retry a message the remote
// may already have taken. So one transaction gets relayDeadline in total, of
// which at most relayAcquireTimeout waiting for a per-domain pacing slot.
const (
	relayDeadline       = 150 * time.Second
	relayAcquireTimeout = 60 * time.Second
)

// RelayBackend is the go-smtp backend of the relay listener.
type RelayBackend struct {
	user, password string
	sender         *Sender
	throttle       *Throttle
	log            *Logger
}

// NewRelayServer builds the relay's SMTP server. The caller owns the listener
// (implicit TLS in production).
func NewRelayServer(domain, user, password string, sender *Sender, throttle *Throttle, log *Logger) *gosmtp.Server {
	s := gosmtp.NewServer(&RelayBackend{user: user, password: password, sender: sender, throttle: throttle, log: log})
	s.Domain = domain
	s.MaxRecipients = 1 // one reply per recipient is what makes the reply truthful
	s.MaxMessageBytes = 16 * 1024 * 1024
	s.ReadTimeout = 60 * time.Second
	s.WriteTimeout = 5 * time.Minute // DATA waits on the remote MX
	s.AllowInsecureAuth = true       // the listener is TLS already (or deliberately plain in tests)
	return s
}

func (b *RelayBackend) NewSession(*gosmtp.Conn) (gosmtp.Session, error) {
	return &relaySession{b: b}, nil
}

type relaySession struct {
	b      *RelayBackend
	authed bool
	from   string
	to     string
}

func (s *relaySession) AuthMechanisms() []string { return []string{sasl.Plain} }

func (s *relaySession) Auth(string) (sasl.Server, error) {
	return sasl.NewPlainServer(func(_, username, password string) error {
		// ponytail: one shared credential and no lockout; the password is a long
		// random secret. Per-client credentials when a second client appears.
		userOK := subtle.ConstantTimeCompare([]byte(username), []byte(s.b.user))
		passOK := subtle.ConstantTimeCompare([]byte(password), []byte(s.b.password))
		if userOK&passOK != 1 {
			s.b.log.Warn("relay.auth_failed", "username", username)
			return &gosmtp.SMTPError{Code: 535, EnhancedCode: gosmtp.EnhancedCode{5, 7, 8}, Message: "Authentication failed"}
		}
		s.authed = true
		return nil
	}), nil
}

func (s *relaySession) Mail(from string, _ *gosmtp.MailOptions) error {
	if !s.authed {
		return &gosmtp.SMTPError{Code: 530, EnhancedCode: gosmtp.EnhancedCode{5, 7, 0}, Message: "Authentication required"}
	}
	s.from = from
	return nil
}

func (s *relaySession) Rcpt(to string, _ *gosmtp.RcptOptions) error {
	s.to = to
	return nil
}

func (s *relaySession) Data(r io.Reader) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(relayDeadline)
	customer := RelayCustomer(s.from)
	rcptDomain := extractRecipientDomain([]string{s.to})

	if reason := s.b.throttle.ReserveRelay(customer, time.Now()); reason != "" {
		s.b.log.Warn("relay.capped", "customer", customer, "reason", reason)
		metrics.Inc("smtp_relay_total", "result", "capped")
		return &gosmtp.SMTPError{Code: 451, EnhancedCode: gosmtp.EnhancedCode{4, 7, 1}, Message: reason + ", retry tomorrow"}
	}
	if !s.b.throttle.AcquireDomain(rcptDomain, relayAcquireTimeout) {
		metrics.Inc("smtp_relay_total", "result", "paced")
		return &gosmtp.SMTPError{Code: 451, EnhancedCode: gosmtp.EnhancedCode{4, 7, 1}, Message: "per-domain pacing, retry later"}
	}
	defer s.b.throttle.ReleaseDomain(rcptDomain)

	key := "relay_" + strconv.FormatInt(time.Now().UnixNano(), 36)
	result := s.b.sender.Send(&OutboundMessage{
		Version:    1,
		MessageKey: key,
		Envelope:   OutboundEnvelope{MailFrom: s.from, RcptTo: []string{s.to}},
		RFC5322B64: base64.StdEncoding.EncodeToString(raw),
		Deadline:   deadline,
	})
	metrics.Inc("smtp_relay_total", "result", result.Result)
	s.b.log.Info("relay.result", "message_key", key, "customer", customer, "rcpt_domain", rcptDomain,
		"result", result.Result, "smtp_code", result.SMTPCode, "mx_host", result.MXHost, "response", result.ResponseMessage)
	return relayReply(result)
}

func (s *relaySession) Reset()        { s.from, s.to = "", "" }
func (s *relaySession) Logout() error { return nil }

// RelayCustomer is the per-customer cap key: the envelope sender's domain with
// Pushleft's VERP label stripped (pl-bounces.acme.com -> acme.com).
func RelayCustomer(mailFrom string) string {
	at := strings.LastIndexByte(mailFrom, '@')
	if at < 0 || at == len(mailFrom)-1 {
		return "unknown"
	}
	return strings.TrimPrefix(strings.ToLower(mailFrom[at+1:]), "pl-bounces.")
}

// relayReply turns a delivery result into the DATA reply. A reply that came
// from the remote MX, 250 included, goes back with its own code and text (the
// text starts with the remote's enhanced code) and ends in " [remote <mx>]".
// That marker is the contract with Pushleft: only a marked reply is the
// recipient's answer. Everything else is ours and is a 451, so the client
// retries.
func relayReply(r *DeliveryResult) error {
	code, _ := strconv.Atoi(r.SMTPCode)
	remote := r.MXHost != "" && (r.Result == "success" && code == 250 ||
		r.Result == "permanent_failure" && code >= 500 && code < 600 ||
		r.Result == "transient_failure" && code >= 400 && code < 500)
	if !remote {
		return &gosmtp.SMTPError{Code: 451, EnhancedCode: gosmtp.EnhancedCode{4, 4, 0},
			Message: fmt.Sprintf("not delivered: %s", r.ResponseMessage)}
	}
	text := strings.TrimPrefix(r.ResponseMessage, r.SMTPCode+" ")
	return &gosmtp.SMTPError{Code: code, EnhancedCode: gosmtp.NoEnhancedCode,
		Message: fmt.Sprintf("%s [remote %s]", text, r.MXHost)}
}

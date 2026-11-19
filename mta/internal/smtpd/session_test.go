package smtpd_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/smtp"
	"strings"
	"sync"
	"testing"
	"time"

	natsserver "github.com/nats-io/nats-server/v2/server"
	natstest "github.com/nats-io/nats-server/v2/test"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/smtpd"
)

// passAuthenticator always returns pass for all auth checks (avoids real DNS in tests).
type passAuthenticator struct{}

func (a *passAuthenticator) Check(clientIP, mailFrom, heloDomain, fromHeaderDomain string, rawMessage []byte) queue.AuthenticationResults {
	return queue.AuthenticationResults{
		SPF:   queue.AuthResult{Result: "pass", Domain: "example.com"},
		DKIM:  queue.AuthResult{Result: "none"},
		DMARC: queue.AuthResult{Result: "pass", Domain: "example.com", Policy: "none"},
	}
}

type testEnv struct {
	ns       *natsserver.Server
	nc       *nats.Conn
	pub      *queue.Publisher
	server   *smtpd.Backend
	smtpAddr string
	cleanup  func()
}

func setupTestEnv(t *testing.T) *testEnv {
	t.Helper()

	// Start embedded NATS
	opts := natstest.DefaultTestOptions
	opts.Port = -1
	opts.JetStream = true
	opts.StoreDir = t.TempDir()
	ns := natstest.RunServer(&opts)

	nc, err := nats.Connect(ns.ClientURL())
	if err != nil {
		ns.Shutdown()
		t.Fatalf("connect NATS: %v", err)
	}

	// Set up domain lookup responder
	sub, err := nc.Subscribe(queue.DomainLookupSubject, func(msg *nats.Msg) {
		var req map[string]string
		json.Unmarshal(msg.Data, &req)
		domain := req["domain"]

		var resp queue.DomainInfo
		switch domain {
		case "acme.com":
			resp = queue.DomainInfo{
				Found: true, OrgID: 1, OrgKey: "org_acme",
				Status: "verified", MaxMessageSize: 20,
			}
		case "pending.com":
			resp = queue.DomainInfo{
				Found: true, OrgID: 2, OrgKey: "org_pending",
				Status: "pending_dns", MaxMessageSize: 20,
			}
		default:
			resp = queue.DomainInfo{Found: false}
		}
		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		nc.Close()
		ns.Shutdown()
		t.Fatalf("subscribe: %v", err)
	}

	// Create publisher
	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		sub.Unsubscribe()
		nc.Close()
		ns.Shutdown()
		t.Fatalf("NewPublisherFromConn: %v", err)
	}

	// Start SMTP server on a random port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		pub.Close()
		sub.Unsubscribe()
		nc.Close()
		ns.Shutdown()
		t.Fatalf("listen: %v", err)
	}

	logger := mxlog.NewFromWriter(io.Discard)
	cfg := smtpd.DefaultConfig()
	cfg.ListenAddr = listener.Addr().String()
	cfg.MaxMessageSize = 1024 * 1024 // 1MB for tests
	cfg.MaxConnsPerIP = 0            // tests hammer from one IP; the cap has its own unit test (limits_test.go)

	backend := smtpd.NewBackend(cfg, pub, logger)
	backend.SetAuthenticator(&passAuthenticator{})
	srv := smtpd.NewServer(backend)

	go srv.Serve(listener)

	return &testEnv{
		ns:       ns,
		nc:       nc,
		pub:      pub,
		server:   backend,
		smtpAddr: listener.Addr().String(),
		cleanup: func() {
			srv.Close()
			pub.Close()
			sub.Unsubscribe()
			nc.Close()
			ns.Shutdown()
		},
	}
}

func TestSMTP_ValidDelivery(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	// Send a message via SMTP
	msg := "From: sender@example.com\r\n" +
		"To: support@acme.com\r\n" +
		"Subject: Test delivery\r\n" +
		"Message-ID: <test-delivery-001@example.com>\r\n" +
		"\r\n" +
		"Hello, this is a test message.\r\n"

	err := smtp.SendMail(env.smtpAddr, nil, "sender@example.com", []string{"support@acme.com"}, []byte(msg))
	if err != nil {
		t.Fatalf("SendMail: %v", err)
	}

	// Verify message arrived on the NATS stream
	js, _ := jetstream.New(env.nc)
	ctx := context.Background()
	stream, err := js.Stream(ctx, queue.StreamName)
	if err != nil {
		t.Fatalf("stream: %v", err)
	}

	cons, err := stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
		FilterSubject: "mail.inbound.acme.com",
	})
	if err != nil {
		t.Fatalf("consumer: %v", err)
	}

	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(5*time.Second))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}

	var received queue.InboundMessage
	for m := range msgs.Messages() {
		if err := json.Unmarshal(m.Data(), &received); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		m.Ack()
	}

	if received.Version != 1 {
		t.Errorf("version = %d, want 1", received.Version)
	}
	if received.Headers.Subject != "Test delivery" {
		t.Errorf("subject = %q, want %q", received.Headers.Subject, "Test delivery")
	}
	if received.Headers.MessageID != "<test-delivery-001@example.com>" {
		t.Errorf("message_id = %q", received.Headers.MessageID)
	}
	if received.Envelope.MailFrom != "sender@example.com" {
		t.Errorf("mail_from = %q", received.Envelope.MailFrom)
	}
	if len(received.Envelope.RcptTo) != 1 || received.Envelope.RcptTo[0] != "support@acme.com" {
		t.Errorf("rcpt_to = %v", received.Envelope.RcptTo)
	}
	if received.RawSizeBytes <= 0 {
		t.Errorf("raw_size_bytes = %d, want > 0", received.RawSizeBytes)
	}
	if received.RawMessageB64 == "" {
		t.Error("raw_message_b64 should not be empty")
	}
}

func TestSMTP_UnknownDomain(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	msg := "From: sender@example.com\r\nTo: user@unknown.com\r\nSubject: Test\r\n\r\nBody\r\n"
	err := smtp.SendMail(env.smtpAddr, nil, "sender@example.com", []string{"user@unknown.com"}, []byte(msg))
	if err == nil {
		t.Fatal("expected error for unknown domain")
	}
	if !strings.Contains(err.Error(), "550") {
		t.Errorf("expected 550 error, got: %v", err)
	}
}

func TestSMTP_PendingDomain(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	msg := "From: sender@example.com\r\nTo: user@pending.com\r\nSubject: Test\r\n\r\nBody\r\n"
	err := smtp.SendMail(env.smtpAddr, nil, "sender@example.com", []string{"user@pending.com"}, []byte(msg))
	if err == nil {
		t.Fatal("expected error for pending domain")
	}
	if !strings.Contains(err.Error(), "450") {
		t.Errorf("expected 450 error, got: %v", err)
	}
}

func TestSMTP_OversizedMessage(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	// The domain lookup returns 20MB limit, but the test server advertises 1MB.
	// The per-plan limit (20MB * 1024 * 1024) is larger than what go-smtp allows (1MB),
	// so the server-level SIZE limit kicks in first.
	// Create a message larger than 1MB (the test server's MaxMessageBytes)
	bigBody := strings.Repeat("X", 1100*1024) // ~1.1MB
	msg := "From: sender@example.com\r\nTo: support@acme.com\r\nSubject: Big\r\n\r\n" + bigBody + "\r\n"

	err := smtp.SendMail(env.smtpAddr, nil, "sender@example.com", []string{"support@acme.com"}, []byte(msg))
	if err == nil {
		t.Fatal("expected error for oversized message")
	}
	// go-smtp should reject with 552 or similar
}

func TestSMTP_MultipleRecipientsSameDomain(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	msg := "From: sender@example.com\r\n" +
		"To: alice@acme.com, bob@acme.com\r\n" +
		"Subject: Multi-recipient\r\n" +
		"Message-ID: <multi-rcpt@example.com>\r\n" +
		"\r\nHello both\r\n"

	err := smtp.SendMail(env.smtpAddr, nil, "sender@example.com",
		[]string{"alice@acme.com", "bob@acme.com"}, []byte(msg))
	if err != nil {
		t.Fatalf("SendMail: %v", err)
	}

	// Should produce one NATS message with both recipients
	js, _ := jetstream.New(env.nc)
	ctx := context.Background()
	stream, _ := js.Stream(ctx, queue.StreamName)
	cons, _ := stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
		FilterSubject: "mail.inbound.acme.com",
	})
	msgs, _ := cons.Fetch(1, jetstream.FetchMaxWait(5*time.Second))

	var received queue.InboundMessage
	for m := range msgs.Messages() {
		json.Unmarshal(m.Data(), &received)
		m.Ack()
	}

	if len(received.Envelope.RcptTo) != 2 {
		t.Errorf("rcpt_to count = %d, want 2", len(received.Envelope.RcptTo))
	}
}

func TestSMTP_RSETBetweenTransactions(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	// Use raw SMTP client to test RSET behavior
	conn, err := net.Dial("tcp", env.smtpAddr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	c, err := smtp.NewClient(conn, "localhost")
	if err != nil {
		t.Fatalf("client: %v", err)
	}

	// First transaction — send to unknown domain (should fail at RCPT)
	c.Mail("sender@example.com")
	err = c.Rcpt("user@unknown.com")
	if err == nil {
		t.Fatal("expected RCPT error for unknown domain")
	}

	// RSET and start new transaction — should work with valid domain
	c.Reset()
	c.Mail("sender@example.com")
	if err := c.Rcpt("support@acme.com"); err != nil {
		t.Fatalf("RCPT after RSET: %v", err)
	}

	wc, err := c.Data()
	if err != nil {
		t.Fatalf("DATA: %v", err)
	}
	wc.Write([]byte("From: sender@example.com\r\nTo: support@acme.com\r\nSubject: After RSET\r\n\r\nBody\r\n"))
	if err := wc.Close(); err != nil {
		t.Fatalf("DATA close: %v", err)
	}
	c.Quit()
}

func TestSMTP_ConcurrentConnections(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	const concurrent = 20
	var wg sync.WaitGroup
	errors := make(chan error, concurrent)

	for i := 0; i < concurrent; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			msg := fmt.Sprintf(
				"From: sender%d@example.com\r\nTo: support@acme.com\r\nSubject: Concurrent %d\r\nMessage-ID: <concurrent-%d@test>\r\n\r\nBody %d\r\n",
				id, id, id, id,
			)
			if err := smtp.SendMail(env.smtpAddr, nil, fmt.Sprintf("sender%d@example.com", id),
				[]string{"support@acme.com"}, []byte(msg)); err != nil {
				errors <- fmt.Errorf("goroutine %d: %w", id, err)
			}
		}(i)
	}
	wg.Wait()
	close(errors)

	for err := range errors {
		t.Errorf("concurrent delivery failed: %v", err)
	}

	// Verify all messages arrived on the stream
	js, _ := jetstream.New(env.nc)
	ctx := context.Background()
	stream, _ := js.Stream(ctx, queue.StreamName)
	info, _ := stream.Info(ctx)
	if info.State.Msgs < uint64(concurrent) {
		t.Errorf("stream has %d messages, want >= %d", info.State.Msgs, concurrent)
	}
}

func TestSMTP_DataWithoutRcpt(t *testing.T) {
	env := setupTestEnv(t)
	defer env.cleanup()

	conn, err := net.Dial("tcp", env.smtpAddr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	c, err := smtp.NewClient(conn, "localhost")
	if err != nil {
		t.Fatalf("client: %v", err)
	}

	c.Mail("sender@example.com")
	// Skip RCPT TO — go straight to DATA
	_, err = c.Data()
	if err == nil {
		t.Fatal("expected error for DATA without RCPT TO")
	}
	c.Quit()
}

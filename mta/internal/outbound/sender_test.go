package outbound_test

import (
	"encoding/base64"
	"io"
	"net/smtp"
	"strings"
	"sync"
	"testing"

	"github.com/inbox2/mta/internal/outbound"
)

// staticResolver always returns a fixed host (the test sink).
type staticResolver struct {
	host string
	port string
}

func (r *staticResolver) Lookup(domain string) ([]outbound.MXRecord, error) {
	return []outbound.MXRecord{{Host: r.host, Pref: 10}}, nil
}

func newTestSender(t *testing.T, sink *outbound.Sink) *outbound.Sender {
	t.Helper()
	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)

	// Parse sink address to get host (without port) — the sender connects on :25 by default,
	// but our sink is on a random port. We need to use the full addr.
	// Since the sender hardcodes port 25, we'll use a resolver that returns the sink host
	// and override the port. Actually, the sender calls net.JoinHostPort(host, "25"),
	// so we need to work around that. Let's instead have the resolver return "127.0.0.1:<port>"
	// as the host — but that won't work either since JoinHostPort will add :25.
	// The cleanest approach: the sink listens on port 25... which requires root.
	// Alternative: make the sender's port configurable. Let me add that.
	_ = sink
	return sender
}

func TestSender_InvalidBase64(t *testing.T) {
	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)

	msg := &outbound.OutboundMessage{
		Version:           1,
		DeliveryStatusKey: "ds_bad",
		MessageKey:        "msg_bad",
		Envelope: outbound.OutboundEnvelope{
			MailFrom: "sender@acme.com",
			RcptTo:   []string{"recipient@example.com"},
		},
		RFC5322B64: "!!!not-base64!!!",
	}

	result := sender.Send(msg)
	if result.Result != "permanent_failure" {
		t.Errorf("result = %q, want %q for invalid base64", result.Result, "permanent_failure")
	}
}

func TestSender_NoRecipients(t *testing.T) {
	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)

	msg := &outbound.OutboundMessage{
		Version:           1,
		DeliveryStatusKey: "ds_norcp",
		MessageKey:        "msg_norcp",
		Envelope: outbound.OutboundEnvelope{
			MailFrom: "sender@acme.com",
			RcptTo:   []string{},
		},
		RFC5322B64: base64.StdEncoding.EncodeToString([]byte("From: a@b.com\r\n\r\nBody\r\n")),
	}

	result := sender.Send(msg)
	if result.Result != "permanent_failure" {
		t.Errorf("result = %q, want %q for no recipients", result.Result, "permanent_failure")
	}
}

func TestSender_DeliverToSink(t *testing.T) {
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(sinkPort(t, sink))

	rawMsg := "From: sender@acme.com\r\nTo: recipient@example.com\r\nSubject: Sink Delivery\r\nMessage-ID: <sink-001@acme.com>\r\n\r\nHello from sender test!\r\n"

	msg := &outbound.OutboundMessage{
		Version:           1,
		DeliveryStatusKey: "ds_sink_001",
		MessageKey:        "msg_sink_001",
		Envelope: outbound.OutboundEnvelope{
			MailFrom: "sender@acme.com",
			RcptTo:   []string{"recipient@example.com"},
		},
		RFC5322B64: base64.StdEncoding.EncodeToString([]byte(rawMsg)),
	}

	result := sender.Send(msg)
	if result.Result != "success" {
		t.Fatalf("Send result = %q (code=%s, msg=%s), want success", result.Result, result.SMTPCode, result.ResponseMessage)
	}
	if result.SMTPCode != "250" {
		t.Errorf("SMTP code = %q, want 250", result.SMTPCode)
	}
	if result.DeliveryStatusKey != "ds_sink_001" {
		t.Errorf("DeliveryStatusKey = %q", result.DeliveryStatusKey)
	}

	// Verify message arrived at the sink
	if sink.MessageCount() != 1 {
		t.Fatalf("sink.MessageCount() = %d, want 1", sink.MessageCount())
	}
	sinkMsgs := sink.Messages()
	if sinkMsgs[0].From != "sender@acme.com" {
		t.Errorf("sink from = %q", sinkMsgs[0].From)
	}
	if !strings.Contains(string(sinkMsgs[0].Data), "Subject: Sink Delivery") {
		t.Error("sink message missing subject")
	}
}

func TestSender_DeliverWithDKIM(t *testing.T) {
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		t.Fatalf("GenerateTestDKIMKey: %v", err)
	}

	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(sinkPort(t, sink))

	rawMsg := "From: sender@acme.com\r\nTo: recipient@example.com\r\nSubject: DKIM Test\r\nMessage-ID: <dkim-send@acme.com>\r\n\r\nBody with DKIM\r\n"

	msg := &outbound.OutboundMessage{
		Version:           1,
		DeliveryStatusKey: "ds_dkim",
		MessageKey:        "msg_dkim",
		Envelope: outbound.OutboundEnvelope{
			MailFrom: "sender@acme.com",
			RcptTo:   []string{"recipient@example.com"},
		},
		RFC5322B64: base64.StdEncoding.EncodeToString([]byte(rawMsg)),
		DKIM: outbound.DKIMConfig{
			Domain:        "acme.com",
			Selector:      "test",
			PrivateKeyPEM: keyPEM,
		},
	}

	result := sender.Send(msg)
	if result.Result != "success" {
		t.Fatalf("Send result = %q, want success", result.Result)
	}

	// Verify DKIM-Signature was added
	sinkMsgs := sink.Messages()
	if !strings.Contains(string(sinkMsgs[0].Data), "DKIM-Signature:") {
		t.Error("delivered message missing DKIM-Signature header")
	}
}

func TestSender_ConcurrentDeliveries(t *testing.T) {
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("test.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})
	sender.SetPort(sinkPort(t, sink))

	const concurrent = 20
	var wg sync.WaitGroup
	results := make(chan *outbound.DeliveryResult, concurrent)

	for i := 0; i < concurrent; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			rawMsg := strings.Join([]string{
				"From: sender@acme.com",
				"To: recipient@example.com",
				"Subject: Concurrent " + strings.Repeat("x", id),
				"Message-ID: <concurrent-" + string(rune('A'+id)) + "@acme.com>",
				"",
				"Body " + string(rune('A'+id)),
				"",
			}, "\r\n")

			msg := &outbound.OutboundMessage{
				Version:           1,
				DeliveryStatusKey: "ds_conc_" + string(rune('A'+id)),
				MessageKey:        "msg_conc_" + string(rune('A'+id)),
				Envelope: outbound.OutboundEnvelope{
					MailFrom: "sender@acme.com",
					RcptTo:   []string{"recipient@example.com"},
				},
				RFC5322B64: base64.StdEncoding.EncodeToString([]byte(rawMsg)),
			}
			results <- sender.Send(msg)
		}(i)
	}
	wg.Wait()
	close(results)

	successes := 0
	for r := range results {
		if r.Result == "success" {
			successes++
		} else {
			t.Errorf("delivery failed: %s (code=%s, msg=%s)", r.Result, r.SMTPCode, r.ResponseMessage)
		}
	}

	if successes != concurrent {
		t.Errorf("successes = %d, want %d", successes, concurrent)
	}
	if sink.MessageCount() < concurrent {
		t.Errorf("sink received %d messages, want >= %d", sink.MessageCount(), concurrent)
	}
}

func TestSink_AcceptsMessages(t *testing.T) {
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	rawMsg := "From: sender@acme.com\r\nTo: recipient@test.com\r\nSubject: Sink\r\n\r\nBody\r\n"
	err = smtp.SendMail(sink.Addr(), nil, "sender@acme.com", []string{"recipient@test.com"}, []byte(rawMsg))
	if err != nil {
		t.Fatalf("SendMail to sink: %v", err)
	}

	if sink.MessageCount() != 1 {
		t.Errorf("sink.MessageCount() = %d, want 1", sink.MessageCount())
	}

	msgs := sink.Messages()
	if msgs[0].From != "sender@acme.com" {
		t.Errorf("from = %q", msgs[0].From)
	}
	if !strings.Contains(string(msgs[0].Data), "Subject: Sink") {
		t.Errorf("message data missing subject")
	}
}

func TestSink_MultipleSenders(t *testing.T) {
	sink, err := outbound.NewSink()
	if err != nil {
		t.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	for i := 0; i < 5; i++ {
		msg := "From: test@acme.com\r\nTo: dest@test.com\r\nSubject: Multi\r\n\r\nBody\r\n"
		if err := smtp.SendMail(sink.Addr(), nil, "test@acme.com", []string{"dest@test.com"}, []byte(msg)); err != nil {
			t.Fatalf("iteration %d: %v", i, err)
		}
	}

	if sink.MessageCount() != 5 {
		t.Errorf("sink.MessageCount() = %d, want 5", sink.MessageCount())
	}
}

// sinkPort extracts the port from the sink's listener address.
func sinkPort(t *testing.T, sink *outbound.Sink) string {
	t.Helper()
	addr := sink.Addr()
	parts := strings.Split(addr, ":")
	return parts[len(parts)-1]
}

package queue_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/queue"
	"github.com/nats-io/nats-server/v2/server"
	natstest "github.com/nats-io/nats-server/v2/test"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func startTestNATS(t *testing.T) (*server.Server, *nats.Conn) {
	t.Helper()
	opts := natstest.DefaultTestOptions
	opts.Port = -1 // random port
	opts.JetStream = true
	opts.StoreDir = t.TempDir()

	ns := natstest.RunServer(&opts)
	t.Cleanup(ns.Shutdown)

	nc, err := nats.Connect(ns.ClientURL())
	if err != nil {
		t.Fatalf("connect to test NATS: %v", err)
	}
	t.Cleanup(nc.Close)

	return ns, nc
}

func TestNewPublisherFromConn_CreatesStream(t *testing.T) {
	_, nc := startTestNATS(t)

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	// Verify stream was created
	js, _ := jetstream.New(nc)
	ctx := context.Background()
	stream, err := js.Stream(ctx, queue.StreamName)
	if err != nil {
		t.Fatalf("stream not found: %v", err)
	}

	info, err := stream.Info(ctx)
	if err != nil {
		t.Fatalf("stream info: %v", err)
	}
	if info.Config.Name != queue.StreamName {
		t.Errorf("stream name = %q, want %q", info.Config.Name, queue.StreamName)
	}
	if info.Config.Retention != jetstream.WorkQueuePolicy {
		t.Errorf("retention = %v, want WorkQueuePolicy", info.Config.Retention)
	}
}

func TestPublish_SendsToStream(t *testing.T) {
	_, nc := startTestNATS(t)

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	msg := &queue.InboundMessage{
		Version:    1,
		ReceivedAt: time.Now().UTC(),
		Envelope: queue.Envelope{
			MailFrom:   "sender@example.com",
			RcptTo:     []string{"support@acme.com"},
			ClientIP:   "203.0.113.42",
			HeloDomain: "mail.example.com",
		},
		Headers: queue.Headers{
			MessageID: "<test-123@example.com>",
			From:      "sender@example.com",
			To:        "support@acme.com",
			Subject:   "Test message",
			Date:      time.Now().UTC().Format(time.RFC3339),
		},
		Body: queue.Body{
			Plain: "Hello, this is a test.",
		},
		RawSizeBytes: 42,
	}

	ctx := context.Background()
	if err := pub.Publish(ctx, "acme.com", "dedupe-id-1", msg); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// Same Nats-Msg-Id within the Duplicates window must be dropped, not stored.
	if err := pub.Publish(ctx, "acme.com", "dedupe-id-1", msg); err != nil {
		t.Fatalf("duplicate Publish: %v", err)
	}

	// Read the message back from the stream
	js, _ := jetstream.New(nc)
	stream, _ := js.Stream(ctx, queue.StreamName)

	// Dedupe check before consuming (acks are async): two publishes with the
	// same Nats-Msg-Id must store exactly one message.
	info, err := stream.Info(ctx)
	if err != nil {
		t.Fatalf("stream info: %v", err)
	}
	if info.Config.Duplicates != queue.DuplicateWindow {
		t.Errorf("duplicates window = %v, want %v", info.Config.Duplicates, queue.DuplicateWindow)
	}
	if got := info.State.Msgs; got != 1 {
		t.Errorf("stream msgs after duplicate publish = %d, want 1", got)
	}

	cons, err := stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
		FilterSubject: "mail.inbound.acme.com",
	})
	if err != nil {
		t.Fatalf("create consumer: %v", err)
	}

	msgs, err := cons.Fetch(1, jetstream.FetchMaxWait(2*time.Second))
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
	if received.Headers.MessageID != "<test-123@example.com>" {
		t.Errorf("message_id = %q, want %q", received.Headers.MessageID, "<test-123@example.com>")
	}
	if received.Headers.Subject != "Test message" {
		t.Errorf("subject = %q, want %q", received.Headers.Subject, "Test message")
	}
	if received.Envelope.ClientIP != "203.0.113.42" {
		t.Errorf("client_ip = %q, want %q", received.Envelope.ClientIP, "203.0.113.42")
	}
}

func TestLookupDomain_Success(t *testing.T) {
	_, nc := startTestNATS(t)

	// Set up a mock domain responder
	sub, err := nc.Subscribe(queue.DomainLookupSubject, func(msg *nats.Msg) {
		var req map[string]string
		json.Unmarshal(msg.Data, &req)

		resp := queue.DomainInfo{
			Found:          true,
			OrgID:          42,
			OrgKey:         "org_abc123",
			Status:         "verified",
			MaxMessageSize: 20,
		}
		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	defer sub.Unsubscribe()

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	info, err := pub.LookupDomain("acme.com")
	if err != nil {
		t.Fatalf("LookupDomain: %v", err)
	}
	if !info.Found {
		t.Error("expected Found=true")
	}
	if info.OrgID != 42 {
		t.Errorf("OrgID = %d, want 42", info.OrgID)
	}
	if info.MaxMessageSize != 20 {
		t.Errorf("MaxMessageSize = %d, want 20", info.MaxMessageSize)
	}
}

func TestLookupDomain_NotFound(t *testing.T) {
	_, nc := startTestNATS(t)

	sub, err := nc.Subscribe(queue.DomainLookupSubject, func(msg *nats.Msg) {
		resp := queue.DomainInfo{Found: false}
		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	defer sub.Unsubscribe()

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	info, err := pub.LookupDomain("unknown.com")
	if err != nil {
		t.Fatalf("LookupDomain: %v", err)
	}
	if info.Found {
		t.Error("expected Found=false")
	}
}

func TestLookupDomain_Timeout(t *testing.T) {
	_, nc := startTestNATS(t)

	// No responder — should time out
	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	_, err = pub.LookupDomain("acme.com")
	if err == nil {
		t.Fatal("expected timeout error, got nil")
	}
}

func TestConnected(t *testing.T) {
	_, nc := startTestNATS(t)

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		t.Fatalf("NewPublisherFromConn: %v", err)
	}
	defer pub.Close()

	if !pub.Connected() {
		t.Error("expected Connected=true")
	}
}

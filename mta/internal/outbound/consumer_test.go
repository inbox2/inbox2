package outbound_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/outbound"
	natstest "github.com/nats-io/nats-server/v2/test"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func startTestNATS(t *testing.T) *nats.Conn {
	t.Helper()
	opts := natstest.DefaultTestOptions
	opts.Port = -1
	opts.JetStream = true
	opts.StoreDir = t.TempDir()

	ns := natstest.RunServer(&opts)
	t.Cleanup(ns.Shutdown)

	nc, err := nats.Connect(ns.ClientURL())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(nc.Close)
	return nc
}

func TestNewConsumerFromConn_CreatesStreams(t *testing.T) {
	nc := startTestNATS(t)

	cons, err := outbound.NewConsumerFromConn(nc)
	if err != nil {
		t.Fatalf("NewConsumerFromConn: %v", err)
	}
	defer cons.Close()

	js, _ := jetstream.New(nc)
	ctx := context.Background()

	// Verify outbound stream
	stream, err := js.Stream(ctx, outbound.OutboundStreamName)
	if err != nil {
		t.Fatalf("outbound stream not found: %v", err)
	}
	info, _ := stream.Info(ctx)
	if info.Config.Name != outbound.OutboundStreamName {
		t.Errorf("outbound stream = %q, want %q", info.Config.Name, outbound.OutboundStreamName)
	}

	// Verify status stream
	statusStream, err := js.Stream(ctx, outbound.StatusStreamName)
	if err != nil {
		t.Fatalf("status stream not found: %v", err)
	}
	sinfo, _ := statusStream.Info(ctx)
	if sinfo.Config.Name != outbound.StatusStreamName {
		t.Errorf("status stream = %q, want %q", sinfo.Config.Name, outbound.StatusStreamName)
	}
}

func TestConsumer_FetchAndPublishResult(t *testing.T) {
	nc := startTestNATS(t)

	cons, err := outbound.NewConsumerFromConn(nc)
	if err != nil {
		t.Fatalf("NewConsumerFromConn: %v", err)
	}
	defer cons.Close()

	// Publish a test outbound message
	js, _ := jetstream.New(nc)
	ctx := context.Background()

	msg := outbound.OutboundMessage{
		Version:           1,
		DeliveryStatusKey: "ds_test123",
		MessageKey:        "msg_test456",
		Envelope: outbound.OutboundEnvelope{
			MailFrom: "sender@acme.com",
			RcptTo:   []string{"recipient@example.com"},
		},
		RFC5322B64: "dGVzdA==", // "test" base64
	}
	data, _ := json.Marshal(msg)
	js.Publish(ctx, outbound.OutboundSubjectPrefix+"example.com", data)

	// Fetch the message
	msgs, err := cons.Fetch(1, 5*time.Second)
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("got %d messages, want 1", len(msgs))
	}

	parsed, err := outbound.ParseMessage(msgs[0].Data())
	if err != nil {
		t.Fatalf("ParseMessage: %v", err)
	}
	if parsed.DeliveryStatusKey != "ds_test123" {
		t.Errorf("DeliveryStatusKey = %q, want %q", parsed.DeliveryStatusKey, "ds_test123")
	}
	if parsed.MessageKey != "msg_test456" {
		t.Errorf("MessageKey = %q, want %q", parsed.MessageKey, "msg_test456")
	}
	msgs[0].Ack()

	// Publish a result
	result := &outbound.DeliveryResult{
		Version:           1,
		DeliveryStatusKey: "ds_test123",
		MessageKey:        "msg_test456",
		Result:            "success",
		SMTPCode:          "250",
		MXHost:            "mx.example.com",
	}
	if err := cons.PublishResult(ctx, result); err != nil {
		t.Fatalf("PublishResult: %v", err)
	}
}

package outbound

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Consumer wraps a NATS JetStream connection for consuming outbound send jobs
// and publishing delivery results.
type Consumer struct {
	nc       *nats.Conn
	js       jetstream.JetStream
	outbound jetstream.Stream
	status   jetstream.Stream
	cons     jetstream.Consumer
}

// NewConsumer connects to NATS and ensures the outbound + status streams exist.
func NewConsumer(natsURL string) (*Consumer, error) {
	nc, err := nats.Connect(natsURL,
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2*time.Second),
		nats.Name("inbox2-smtp"),
	)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}

	return NewConsumerFromConn(nc)
}

// NewConsumerFromConn creates a Consumer from an existing NATS connection (for testing).
func NewConsumerFromConn(nc *nats.Conn) (*Consumer, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream context: %w", err)
	}

	c := &Consumer{nc: nc, js: js}
	if err := c.ensureStreams(); err != nil {
		return nil, err
	}
	if err := c.ensureConsumer(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Consumer) ensureStreams() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	outbound, err := c.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:       OutboundStreamName,
		Subjects:   []string{OutboundSubjectPrefix + ">"},
		Retention:  jetstream.WorkQueuePolicy,
		MaxAge:     DefaultStreamMaxAge,
		MaxBytes:   DefaultStreamMaxBytes,
		MaxMsgSize: int32(DefaultMaxMsgSize),
		Storage:    jetstream.FileStorage,
		Discard:    jetstream.DiscardOld,
	})
	if err != nil {
		return fmt.Errorf("ensure stream %s: %w", OutboundStreamName, err)
	}
	c.outbound = outbound

	status, err := c.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:      StatusStreamName,
		Subjects:  []string{StatusSubjectPrefix + ">"},
		Retention: jetstream.InterestPolicy,
		MaxAge:    24 * time.Hour,
		MaxBytes:  1024 * 1024 * 1024, // 1GB
		Storage:   jetstream.FileStorage,
		Discard:   jetstream.DiscardOld,
	})
	if err != nil {
		return fmt.Errorf("ensure stream %s: %w", StatusStreamName, err)
	}
	c.status = status

	return nil
}

func (c *Consumer) ensureConsumer() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cons, err := c.outbound.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Name:          ConsumerName,
		Durable:       ConsumerName,
		FilterSubject: OutboundSubjectPrefix + ">",
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       5 * time.Minute, // generous — SMTP can be slow
		// Retries across time are owned by Rails (re-publish after backoff), so
		// a healthy worker never needs redelivery. But a worker can crash between
		// Fetch and Ack, or fail to publish its DeliveryResult (see cmd/smtp) —
		// with MaxDeliver 1 the WorkQueue message would be terminated after
		// AckWait with no result ever reaching Rails: silent mail loss. A small
		// bound lets un-acked jobs redeliver while still capping poison messages.
		MaxDeliver:    5,
		MaxAckPending: DefaultWorkers,
	})
	if err != nil {
		return fmt.Errorf("ensure consumer %s: %w", ConsumerName, err)
	}
	c.cons = cons
	return nil
}

// Fetch pulls up to maxMessages from the outbound stream.
// Returns nil on timeout (no messages available).
func (c *Consumer) Fetch(maxMessages int, timeout time.Duration) ([]jetstream.Msg, error) {
	msgs, err := c.cons.Fetch(maxMessages, jetstream.FetchMaxWait(timeout))
	if err != nil {
		return nil, err
	}

	var result []jetstream.Msg
	for m := range msgs.Messages() {
		result = append(result, m)
	}
	return result, nil
}

// ParseMessage deserializes a NATS message into an OutboundMessage.
func ParseMessage(data []byte) (*OutboundMessage, error) {
	var msg OutboundMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return nil, fmt.Errorf("unmarshal outbound message: %w", err)
	}
	return &msg, nil
}

// PublishResult sends a delivery result to the status stream for Rails to consume.
func (c *Consumer) PublishResult(ctx context.Context, result *DeliveryResult) error {
	data, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("marshal result: %w", err)
	}

	subject := StatusSubjectPrefix + result.DeliveryStatusKey
	_, err = c.js.Publish(ctx, subject, data)
	if err != nil {
		return fmt.Errorf("publish result to %s: %w", subject, err)
	}
	return nil
}

// Connected returns true if the NATS connection is active.
func (c *Consumer) Connected() bool {
	return c.nc.IsConnected()
}

// Close drains and closes the NATS connection.
func (c *Consumer) Close() error {
	return c.nc.Drain()
}

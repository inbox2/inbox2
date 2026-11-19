package smtpd_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/smtp"
	"testing"
	"time"

	natstest "github.com/nats-io/nats-server/v2/test"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/parser"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/smtpd"
)

func setupBenchEnv(b *testing.B) (string, func()) {
	b.Helper()

	opts := natstest.DefaultTestOptions
	opts.Port = -1
	opts.JetStream = true
	opts.StoreDir = b.TempDir()
	ns := natstest.RunServer(&opts)

	nc, err := nats.Connect(ns.ClientURL())
	if err != nil {
		ns.Shutdown()
		b.Fatalf("connect NATS: %v", err)
	}

	sub, _ := nc.Subscribe(queue.DomainLookupSubject, func(msg *nats.Msg) {
		resp := queue.DomainInfo{
			Found: true, OrgID: 1, OrgKey: "org_bench",
			Status: "verified", MaxMessageSize: 100,
		}
		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})

	pub, err := queue.NewPublisherFromConn(nc)
	if err != nil {
		sub.Unsubscribe()
		nc.Close()
		ns.Shutdown()
		b.Fatalf("publisher: %v", err)
	}

	// Set up a draining consumer so the WorkQueue stream doesn't fill up.
	// WorkQueue allows one consumer with explicit ack — we ack immediately.
	js, _ := jetstream.New(nc)
	ctx := context.Background()
	cons, err := js.CreateOrUpdateConsumer(ctx, queue.StreamName, jetstream.ConsumerConfig{
		Name:          "bench-drain",
		FilterSubject: "mail.inbound.>",
		AckPolicy:     jetstream.AckExplicitPolicy,
	})
	if err != nil {
		pub.Close()
		sub.Unsubscribe()
		nc.Close()
		ns.Shutdown()
		b.Fatalf("create drain consumer: %v", err)
	}
	drainCtx, drainCancel := context.WithCancel(context.Background())
	go func() {
		for drainCtx.Err() == nil {
			msgs, err := cons.Fetch(100, jetstream.FetchMaxWait(500*time.Millisecond))
			if err != nil {
				continue
			}
			for m := range msgs.Messages() {
				m.Ack()
			}
		}
	}()
	_ = drainCtx

	listener, _ := net.Listen("tcp", "127.0.0.1:0")

	logger := mxlog.NewFromWriter(io.Discard)
	cfg := smtpd.DefaultConfig()
	cfg.ListenAddr = listener.Addr().String()

	backend := smtpd.NewBackend(cfg, pub, logger)
	backend.SetAuthenticator(&passAuthenticator{})
	srv := smtpd.NewServer(backend)
	go srv.Serve(listener)

	return listener.Addr().String(), func() {
		drainCancel()
		srv.Close()
		pub.Close()
		sub.Unsubscribe()
		nc.Close()
		ns.Shutdown()
	}
}

// BenchmarkSMTP_SingleConnection measures throughput on a single persistent SMTP connection
// (multiple messages via RSET, no TCP connection overhead per message).
func BenchmarkSMTP_SingleConnection(b *testing.B) {
	addr, cleanup := setupBenchEnv(b)
	defer cleanup()

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		b.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	c, err := smtp.NewClient(conn, "localhost")
	if err != nil {
		b.Fatalf("client: %v", err)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.Mail("bench@example.com")
		c.Rcpt("support@acme.com")
		wc, err := c.Data()
		if err != nil {
			b.Fatalf("iteration %d DATA: %v", i, err)
		}
		fmt.Fprintf(wc, "From: bench@example.com\r\nTo: support@acme.com\r\nSubject: Bench %d\r\nMessage-ID: <bench-%d@test>\r\n\r\nBenchmark body\r\n", i, i)
		if err := wc.Close(); err != nil {
			b.Fatalf("iteration %d DATA close: %v", i, err)
		}
		c.Reset()
	}
	c.Quit()
}

// BenchmarkSMTP_NewConnection measures per-message latency including TCP connection setup.
func BenchmarkSMTP_NewConnection(b *testing.B) {
	addr, cleanup := setupBenchEnv(b)
	defer cleanup()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		msg := fmt.Sprintf(
			"From: bench@example.com\r\nTo: support@acme.com\r\nSubject: Bench %d\r\nMessage-ID: <bench-%d@test>\r\n\r\nBenchmark body\r\n",
			i, i,
		)
		if err := smtp.SendMail(addr, nil, "bench@example.com", []string{"support@acme.com"}, []byte(msg)); err != nil {
			b.Fatalf("iteration %d: SendMail: %v", i, err)
		}
	}
}

// BenchmarkParser measures message parsing throughput (no network, pure CPU).
func BenchmarkParser(b *testing.B) {
	raw := []byte("From: alice@example.com\r\nTo: support@acme.com\r\nSubject: Benchmark\r\n" +
		"Message-ID: <bench@test>\r\nContent-Type: multipart/alternative; boundary=\"bnd\"\r\n\r\n" +
		"--bnd\r\nContent-Type: text/plain\r\n\r\nPlain text body\r\n" +
		"--bnd\r\nContent-Type: text/html\r\n\r\n<p>HTML body</p>\r\n--bnd--\r\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parser.Parse(raw)
	}
}

// BenchmarkParser_Plain measures plain text parsing throughput.
func BenchmarkParser_Plain(b *testing.B) {
	raw := []byte("From: alice@example.com\r\nTo: support@acme.com\r\nSubject: Plain\r\n" +
		"Message-ID: <plain@test>\r\n\r\nHello this is a plain text message body.\r\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parser.Parse(raw)
	}
}

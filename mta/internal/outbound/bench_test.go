package outbound_test

import (
	"encoding/base64"
	"fmt"
	"io"
	"testing"

	"github.com/inbox2/mta/internal/outbound"
)

// BenchmarkDKIMSign measures DKIM signing throughput.
func BenchmarkDKIMSign(b *testing.B) {
	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		b.Fatalf("GenerateTestDKIMKey: %v", err)
	}

	rawMessage := []byte("From: sender@example.com\r\nTo: recipient@acme.com\r\nSubject: Bench DKIM\r\n" +
		"Date: Sat, 24 May 2026 12:00:00 +0000\r\nMessage-ID: <bench-dkim@example.com>\r\n" +
		"Content-Type: text/plain\r\n\r\nBenchmark body for DKIM signing.\r\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := outbound.SignMessage(rawMessage, "example.com", "bench", keyPEM)
		if err != nil {
			b.Fatalf("SignMessage: %v", err)
		}
	}
}

// BenchmarkSender_ToSink measures delivery throughput on a single connection to the embedded sink.
func BenchmarkSender_ToSink(b *testing.B) {
	sink, err := outbound.NewSink()
	if err != nil {
		b.Fatalf("NewSink: %v", err)
	}
	defer sink.Close()

	logger := outbound.NewLoggerFromWriter(io.Discard)
	sender := outbound.NewSender("bench.local", logger)
	sender.SetResolver(&staticResolver{host: "127.0.0.1"})

	parts := splitAddr(sink.Addr())
	sender.SetPort(parts)

	rawMsg := "From: bench@acme.com\r\nTo: dest@example.com\r\nSubject: Bench\r\nMessage-ID: <bench@acme.com>\r\n\r\nBody\r\n"
	b64 := base64.StdEncoding.EncodeToString([]byte(rawMsg))

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		msg := &outbound.OutboundMessage{
			Version:           1,
			DeliveryStatusKey: fmt.Sprintf("ds_bench_%d", i),
			MessageKey:        fmt.Sprintf("msg_bench_%d", i),
			Envelope: outbound.OutboundEnvelope{
				MailFrom: "bench@acme.com",
				RcptTo:   []string{"dest@example.com"},
			},
			RFC5322B64: b64,
		}
		result := sender.Send(msg)
		if result.Result != "success" {
			b.Fatalf("delivery %d failed: %s", i, result.ResponseMessage)
		}
	}
}

func splitAddr(addr string) string {
	for i := len(addr) - 1; i >= 0; i-- {
		if addr[i] == ':' {
			return addr[i+1:]
		}
	}
	return addr
}

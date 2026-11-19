package outbound_test

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/outbound"
)

func TestLogger_TextOutput(t *testing.T) {
	var buf bytes.Buffer
	logger := outbound.NewLoggerFromWriter(&buf)

	logger.ServerStart(10, "smtp.test", "nats://localhost:4222")
	logger.NATSConnected("nats://localhost:4222")
	logger.NATSConsume("msg_123", "ds_456")
	logger.DKIMSigned("msg_123", "acme.com", "inbox2", 1.5)
	logger.MXLookup("example.com", 3, 2.1)
	logger.SMTPAttempt("msg_123", "mx.example.com", 1, "success", "250", 15.3)
	logger.DeliverySuccess("msg_123", "mx.example.com", "TLS 1.3", 18.7)
	logger.PublishResult("ds_456", "success")
	logger.ServerStop()

	out := buf.String()

	for _, want := range []string{
		"server.start",
		"nats.connected",
		"nats.consume",
		"dkim.signed",
		"mx.lookup",
		"smtp.attempt",
		"delivery.success",
		"nats.publish_result",
		"server.stop",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q", want)
		}
	}

	for _, want := range []string{
		"workers=10",
		"message_key=msg_123",
		"domain=acme.com",
		"host=mx.example.com",
		"result=success",
		"tls=\"TLS 1.3\"",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing field %q", want)
		}
	}
}

func TestLogger_JSONFile(t *testing.T) {
	logFile := t.TempDir() + "/smtp.log"
	logger, err := outbound.NewLogger(logFile)
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}

	logger.ServerStart(5, "smtp.test", "nats://localhost:4222")
	logger.DeliveryFailure("msg_fail", "permanent_failure", "550 user unknown", 3, 45.2)
	logger.DKIMSignError("msg_fail", fmt.Errorf("invalid key"))
	logger.ServerStop()
	logger.Close()

	data, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	content := string(data)

	for _, want := range []string{
		`"msg":"server.start"`,
		`"msg":"delivery.failure"`,
		`"msg":"dkim.sign_error"`,
		`"msg":"server.stop"`,
		`"workers":5`,
		`"result":"permanent_failure"`,
		`"reason":"550 user unknown"`,
	} {
		if !strings.Contains(content, want) {
			t.Errorf("JSON log missing %q", want)
		}
	}
}

func TestDurationMs(t *testing.T) {
	tests := []struct {
		us   int
		want float64
	}{
		{1000, 1.0},
		{1500, 1.5},
		{500, 0.5},
		{0, 0.0},
	}
	for _, tt := range tests {
		d := time.Duration(tt.us) * time.Microsecond
		got := outbound.DurationMs(d)
		if got != tt.want {
			t.Errorf("DurationMs(%v) = %v, want %v", d, got, tt.want)
		}
	}
}

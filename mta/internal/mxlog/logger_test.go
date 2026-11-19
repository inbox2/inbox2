package mxlog_test

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/mxlog"
)

func TestNewFromWriter(t *testing.T) {
	var buf bytes.Buffer
	logger := mxlog.NewFromWriter(&buf)

	logger.ServerStart(":4025", "mx.inbox2.local", "nats://localhost:4222", false)
	logger.MailFrom("203.0.113.42", "sender@example.com")
	logger.RcptTo("203.0.113.42", "support@acme.com", "acme.com", "org_abc", 1.2)
	logger.RcptReject("203.0.113.42", "user@bad.com", "bad.com", 550, "no such domain")
	logger.AuthResult("203.0.113.42", "<test@example.com>", "pass", "none", "pass", "none", 5.3)
	logger.DataAccepted("203.0.113.42", "sender@example.com", []string{"support@acme.com"}, 4096, "<test@example.com>", "Hello World", 1, 12.5)
	logger.ServerStop()

	out := buf.String()

	// Verify key events are present
	for _, want := range []string{
		"server.start",
		"smtp.mail_from",
		"smtp.rcpt_to",
		"smtp.rcpt_reject",
		"auth.result",
		"smtp.data_accepted",
		"server.stop",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q", want)
		}
	}

	// Verify structured fields are present
	for _, want := range []string{
		"client_ip=203.0.113.42",
		"from=sender@example.com",
		"domain=acme.com",
		"org=org_abc",
		"message_id=<test@example.com>",
		"spf=pass",
		"dkim=none",
		"size_bytes=4096",
		"duration_ms=12.5",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing field %q", want)
		}
	}
}

func TestNewWithLogFile(t *testing.T) {
	logFile := t.TempDir() + "/mx.log"
	logger, err := mxlog.New(logFile)
	if err != nil {
		t.Fatalf("New(%s): %v", logFile, err)
	}

	logger.ServerStart(":4025", "mx.test", "nats://localhost:4222", true)
	logger.NATSConnected("nats://localhost:4222")
	logger.MailFrom("10.0.0.1", "alice@example.com")
	logger.DataAccepted("10.0.0.1", "alice@example.com", []string{"bob@acme.com"}, 2048, "<msg-1@test>", "Test subject", 1, 3.7)
	logger.ServerStop()
	logger.Close()

	data, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	content := string(data)

	// JSON log file should contain structured JSON lines
	for _, want := range []string{
		`"msg":"server.start"`,
		`"msg":"nats.connected"`,
		`"msg":"smtp.mail_from"`,
		`"msg":"smtp.data_accepted"`,
		`"msg":"server.stop"`,
		`"addr":":4025"`,
		`"tls":true`,
		`"message_id":"<msg-1@test>"`,
		`"size_bytes":2048`,
		`"duration_ms":3.7`,
	} {
		if !strings.Contains(content, want) {
			t.Errorf("JSON log missing %q\nFull content:\n%s", want, content)
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
		got := mxlog.DurationMs(d)
		if got != tt.want {
			t.Errorf("DurationMs(%v) = %v, want %v", d, got, tt.want)
		}
	}
}

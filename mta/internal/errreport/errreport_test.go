package errreport

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
)

type sink struct{ events []*sentry.Event }

func (s *sink) Flush(time.Duration) bool              { return true }
func (s *sink) FlushWithContext(context.Context) bool { return true }
func (s *sink) Configure(sentry.ClientOptions)        {}
func (s *sink) SendEvent(e *sentry.Event)             { s.events = append(s.events, e) }
func (s *sink) Close()                                {}

func TestErrorRecordsGoToSentryAndStillLog(t *testing.T) {
	var out bytes.Buffer
	log := slog.New(Handler(slog.NewTextHandler(&out, nil))).With("op", "fetch", "remote", "203.0.113.9:4242")

	log.Error("off.error") // SENTRY_DSN unset: nothing to send, still logged
	s := &sink{}
	if err := sentry.Init(sentry.ClientOptions{Dsn: "https://k@errors.example/1", Transport: s}); err != nil {
		t.Fatal(err)
	}
	on = true
	defer func() { on = false }()

	log.Info("nats.connected")
	log.Error("nats.error", "error", "boom", "login", "someone@example.com")

	if len(s.events) != 1 || s.events[0].Message != "nats.error" {
		t.Fatalf("events = %+v", s.events)
	}
	if got := s.events[0].Contexts["log"]; got["error"] != "boom" || got["op"] != "fetch" || got["login"] != nil || got["remote"] != nil {
		t.Fatalf("log context = %v", got)
	}
	for _, m := range []string{"off.error", "nats.connected", "nats.error"} {
		if !strings.Contains(out.String(), m) {
			t.Fatalf("%s not logged: %s", m, out.String())
		}
	}
}

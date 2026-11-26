// Package errreport sends errors to Sentry (Pushleft's Errors page) when
// SENTRY_DSN is set. Without it (local, tests) nothing is sent.
//
// The release comes from SENTRY_RELEASE and the environment from
// SENTRY_ENVIRONMENT; deploy/pushleft/run and .pl.yaml set both.
package errreport

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/getsentry/sentry-go"
)

var on bool

// Init starts Sentry. Defer the returned func in main: it reports a panic of
// the main goroutine and sends what is still queued.
// ponytail: panics in other goroutines are not caught; add sentry.Recover there if one bites.
func Init(server string) func() {
	if os.Getenv("SENTRY_DSN") == "" {
		return func() {}
	}
	if err := sentry.Init(sentry.ClientOptions{ServerName: server, TracesSampleRate: 0.1}); err != nil {
		fmt.Fprintln(os.Stderr, "sentry:", err)
		return func() {}
	}
	on = true
	return func() {
		if r := recover(); r != nil {
			sentry.CurrentHub().Recover(r)
			sentry.Flush(2 * time.Second)
			panic(r)
		}
		sentry.Flush(2 * time.Second)
	}
}

// Exit sends what is queued, then exits: os.Exit skips deferred functions.
func Exit(code int) {
	if on {
		sentry.Flush(2 * time.Second)
	}
	os.Exit(code)
}

// The attributes an event carries; the rest (the IMAP/submission login, the
// client's address, anything added later) stays in the log only. "error" is
// the Go error text: from the API it is the ErrorSerializer message, no mail.
var shared = map[string]bool{"error": true, "op": true, "domain": true, "worker_id": true, "addr": true, "value": true, "delivery_status_key": true}

// Handler wraps h so that every Error record is also sent to Sentry, its
// attributes as the "log" context. The message (e.g. "nats.error") groups the issue.
func Handler(h slog.Handler) slog.Handler { return &handler{inner: h} }

type handler struct {
	inner slog.Handler
	attrs []slog.Attr
}

func (h *handler) Enabled(ctx context.Context, l slog.Level) bool {
	return (on && l >= slog.LevelError) || h.inner.Enabled(ctx, l)
}

func (h *handler) Handle(ctx context.Context, r slog.Record) error {
	if on && r.Level >= slog.LevelError {
		ev := sentry.NewEvent()
		ev.Level = sentry.LevelError
		ev.Message = r.Message
		data := sentry.Context{}
		add := func(a slog.Attr) bool {
			if shared[a.Key] {
				data[a.Key] = a.Value.String()
			}
			return true
		}
		for _, a := range h.attrs {
			add(a)
		}
		r.Attrs(add)
		ev.Contexts["log"] = data
		sentry.CaptureEvent(ev)
	}
	if !h.inner.Enabled(ctx, r.Level) {
		return nil
	}
	return h.inner.Handle(ctx, r)
}

func (h *handler) WithAttrs(as []slog.Attr) slog.Handler {
	return &handler{inner: h.inner.WithAttrs(as), attrs: append(append([]slog.Attr{}, h.attrs...), as...)}
}

func (h *handler) WithGroup(name string) slog.Handler {
	return &handler{inner: h.inner.WithGroup(name), attrs: h.attrs}
}

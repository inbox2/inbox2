package outbound

import (
	"context"
	"io"
	"log/slog"
	"os"
	"time"

	"github.com/inbox2/mta/internal/errreport"
)

// Logger provides structured logging for the SMTP outbound sender.
type Logger struct {
	s    *slog.Logger
	file *os.File
}

// NewLogger creates a Logger. If logFile is non-empty, JSON logs are appended to that file.
func NewLogger(logFile string) (*Logger, error) {
	l := &Logger{}

	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			return nil, err
		}
		l.file = f
		l.s = slog.New(newMultiHandler(
			slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}),
			slog.NewJSONHandler(f, &slog.HandlerOptions{Level: slog.LevelDebug}),
		))
	} else {
		l.s = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	}

	l.s = slog.New(errreport.Handler(l.s.Handler()))
	return l, nil
}

// NewLoggerFromWriter creates a Logger writing to a specific writer (for testing).
func NewLoggerFromWriter(w io.Writer) *Logger {
	return &Logger{
		s: slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelDebug})),
	}
}

// Close flushes and closes the log file.
func (l *Logger) Close() {
	if l.file != nil {
		l.file.Sync()
		l.file.Close()
	}
}

func (l *Logger) ServerStart(workers int, domain, natsURL string) {
	l.s.Info("server.start", "workers", workers, "domain", domain, "nats_url", natsURL)
}

func (l *Logger) ServerStop() {
	l.s.Info("server.stop")
}

func (l *Logger) NATSConnected(url string) {
	l.s.Info("nats.connected", "url", url)
}

func (l *Logger) NATSConsume(messageKey, deliveryStatusKey string) {
	l.s.Info("nats.consume", "message_key", messageKey, "delivery_status_key", deliveryStatusKey)
}

func (l *Logger) MXLookup(domain string, recordCount int, durationMs float64) {
	l.s.Debug("mx.lookup", "domain", domain, "records", recordCount, "duration_ms", durationMs)
}

func (l *Logger) MXLookupError(domain string, err error) {
	l.s.Error("mx.lookup_error", "domain", domain, "error", err.Error())
}

func (l *Logger) DKIMSigned(messageKey, domain, selector string, durationMs float64) {
	l.s.Info("dkim.signed", "message_key", messageKey, "domain", domain, "selector", selector, "duration_ms", durationMs)
}

func (l *Logger) DKIMSignError(messageKey string, err error) {
	l.s.Warn("dkim.sign_error", "message_key", messageKey, "error", err.Error())
}

func (l *Logger) SMTPConnect(host string) {
	l.s.Debug("smtp.connect", "host", host)
}

func (l *Logger) STARTTLSFailed(host string, err error) {
	l.s.Warn("smtp.starttls_failed", "host", host, "error", err.Error())
}

func (l *Logger) SMTPAttempt(messageKey, host string, attempt int, result, smtpCode string, durationMs float64) {
	l.s.Info("smtp.attempt", "message_key", messageKey, "host", host, "attempt", attempt, "result", result, "smtp_code", smtpCode, "duration_ms", durationMs)
}

func (l *Logger) DeliverySuccess(messageKey, host, tlsVersion string, durationMs float64) {
	l.s.Info("delivery.success", "message_key", messageKey, "host", host, "tls", tlsVersion, "duration_ms", durationMs)
}

func (l *Logger) DeliveryFailure(messageKey, result, reason string, attempts int, durationMs float64) {
	l.s.Warn("delivery.failure", "message_key", messageKey, "result", result, "reason", reason, "attempts", attempts, "duration_ms", durationMs)
}

func (l *Logger) PublishResult(deliveryStatusKey, result string) {
	l.s.Info("nats.publish_result", "delivery_status_key", deliveryStatusKey, "result", result)
}

func (l *Logger) PublishResultError(deliveryStatusKey string, err error) {
	l.s.Error("nats.publish_result_error", "delivery_status_key", deliveryStatusKey, "error", err.Error())
}

func (l *Logger) WorkerStarted(id int) {
	l.s.Debug("worker.started", "worker_id", id)
}

func (l *Logger) WorkerStopped(id int) {
	l.s.Debug("worker.stopped", "worker_id", id)
}

func (l *Logger) Info(msg string, args ...any) {
	l.s.Info(msg, args...)
}

func (l *Logger) Warn(msg string, args ...any) {
	l.s.Warn(msg, args...)
}

func (l *Logger) Error(msg string, args ...any) {
	l.s.Error(msg, args...)
}

// DurationMs converts a duration to milliseconds with one decimal.
func DurationMs(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000.0
}

// multiHandler fans out log records to multiple slog.Handlers.
type multiHandler struct {
	handlers []slog.Handler
}

func newMultiHandler(handlers ...slog.Handler) *multiHandler {
	return &multiHandler{handlers: handlers}
}

func (m *multiHandler) Enabled(ctx context.Context, level slog.Level) bool {
	for _, h := range m.handlers {
		if h.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (m *multiHandler) Handle(ctx context.Context, r slog.Record) error {
	for _, h := range m.handlers {
		if err := h.Handle(ctx, r); err != nil {
			return err
		}
	}
	return nil
}

func (m *multiHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	handlers := make([]slog.Handler, len(m.handlers))
	for i, h := range m.handlers {
		handlers[i] = h.WithAttrs(attrs)
	}
	return &multiHandler{handlers: handlers}
}

func (m *multiHandler) WithGroup(name string) slog.Handler {
	handlers := make([]slog.Handler, len(m.handlers))
	for i, h := range m.handlers {
		handlers[i] = h.WithGroup(name)
	}
	return &multiHandler{handlers: handlers}
}

// Package mxlog provides structured logging for the MX inbound receiver.
//
// Logs are written as JSON to a file (for machine parsing / insights) and
// as human-readable text to stdout (for development). The log file path is
// set via MX_LOG_FILE; if empty, only stdout is used.
package mxlog

import (
	"context"
	"io"
	"log/slog"
	"os"
	"time"
)

// Logger wraps slog for MX-specific structured events.
type Logger struct {
	s    *slog.Logger
	file *os.File // nil if stdout-only
}

// New creates a Logger. If logFile is non-empty, JSON logs are appended to that
// file in addition to human-readable text on stdout.
func New(logFile string) (*Logger, error) {
	l := &Logger{}

	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			return nil, err
		}
		l.file = f
		// JSON to file, text to stdout — use a multi-handler
		l.s = slog.New(newMultiHandler(
			slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}),
			slog.NewJSONHandler(f, &slog.HandlerOptions{Level: slog.LevelDebug}),
		))
	} else {
		l.s = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	}

	return l, nil
}

// NewFromWriter creates a Logger that writes to a specific writer (for testing).
func NewFromWriter(w io.Writer) *Logger {
	return &Logger{
		s: slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelDebug})),
	}
}

// Close flushes and closes the log file if one was opened.
func (l *Logger) Close() {
	if l.file != nil {
		l.file.Sync()
		l.file.Close()
	}
}

// --- Server lifecycle ---

func (l *Logger) ServerStart(addr, domain, natsURL string, tlsEnabled bool) {
	l.s.Info("server.start",
		"addr", addr,
		"domain", domain,
		"nats_url", natsURL,
		"tls", tlsEnabled,
	)
}

func (l *Logger) ServerStop() {
	l.s.Info("server.stop")
}

func (l *Logger) NATSConnected(url string) {
	l.s.Info("nats.connected", "url", url)
}

func (l *Logger) NATSError(err error) {
	l.s.Error("nats.error", "error", err.Error())
}

// --- Connection lifecycle ---

func (l *Logger) ConnectionOpen(clientIP string) {
	l.s.Debug("connection.open", "client_ip", clientIP)
}

func (l *Logger) ConnectionClose(clientIP string) {
	l.s.Debug("connection.close", "client_ip", clientIP)
}

// --- SMTP commands ---

func (l *Logger) MailFrom(clientIP, from string) {
	l.s.Info("smtp.mail_from",
		"client_ip", clientIP,
		"from", from,
	)
}

func (l *Logger) RcptTo(clientIP, to, domain, orgKey string, durationMs float64) {
	l.s.Info("smtp.rcpt_to",
		"client_ip", clientIP,
		"to", to,
		"domain", domain,
		"org", orgKey,
		"duration_ms", durationMs,
	)
}

func (l *Logger) RcptReject(clientIP, to, domain string, code int, reason string) {
	l.s.Warn("smtp.rcpt_reject",
		"client_ip", clientIP,
		"to", to,
		"domain", domain,
		"code", code,
		"reason", reason,
	)
}

func (l *Logger) DataAccepted(clientIP, from string, rcptTo []string, sizeBytes int64, messageID, subject string, domainCount int, durationMs float64) {
	l.s.Info("smtp.data_accepted",
		"client_ip", clientIP,
		"from", from,
		"to", rcptTo,
		"size_bytes", sizeBytes,
		"message_id", messageID,
		"subject", truncate(subject, 80),
		"domains", domainCount,
		"duration_ms", durationMs,
	)
}

func (l *Logger) DataReject(clientIP, from string, code int, reason string) {
	l.s.Warn("smtp.data_reject",
		"client_ip", clientIP,
		"from", from,
		"code", code,
		"reason", reason,
	)
}

func (l *Logger) Reset(clientIP string) {
	l.s.Debug("smtp.rset", "client_ip", clientIP)
}

// --- Authentication ---

func (l *Logger) AuthResult(clientIP, messageID string, spf, dkim, dmarc string, dmarcPolicy string, durationMs float64) {
	l.s.Info("auth.result",
		"client_ip", clientIP,
		"message_id", messageID,
		"spf", spf,
		"dkim", dkim,
		"dmarc", dmarc,
		"dmarc_policy", dmarcPolicy,
		"duration_ms", durationMs,
	)
}

// --- Domain lookup ---

func (l *Logger) DomainLookup(domain string, found bool, orgKey, status string, cached bool, durationMs float64) {
	l.s.Debug("domain.lookup",
		"domain", domain,
		"found", found,
		"org", orgKey,
		"status", status,
		"cached", cached,
		"duration_ms", durationMs,
	)
}

func (l *Logger) DomainLookupError(domain string, err error) {
	l.s.Error("domain.lookup_error",
		"domain", domain,
		"error", err.Error(),
	)
}

// --- NATS publish ---

func (l *Logger) NATSPublish(domain, messageID string, sizeBytes int, durationMs float64) {
	l.s.Info("nats.publish",
		"domain", domain,
		"message_id", messageID,
		"size_bytes", sizeBytes,
		"duration_ms", durationMs,
	)
}

func (l *Logger) NATSPublishError(domain string, err error) {
	l.s.Error("nats.publish_error",
		"domain", domain,
		"error", err.Error(),
	)
}

// --- Parser ---

func (l *Logger) ParseComplete(messageID string, hasPlain, hasHTML bool, attachments int, durationMs float64) {
	l.s.Debug("parse.complete",
		"message_id", messageID,
		"has_plain", hasPlain,
		"has_html", hasHTML,
		"attachments", attachments,
		"duration_ms", durationMs,
	)
}

func (l *Logger) ParseError(err error) {
	l.s.Warn("parse.error", "error", err.Error())
}

// --- Generic ---

func (l *Logger) Warn(msg string, args ...any) {
	l.s.Warn(msg, args...)
}

func (l *Logger) Error(msg string, args ...any) {
	l.s.Error(msg, args...)
}

func (l *Logger) Info(msg string, args ...any) {
	l.s.Info(msg, args...)
}

// DurationMs converts a duration to milliseconds with one decimal.
func DurationMs(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000.0
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
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

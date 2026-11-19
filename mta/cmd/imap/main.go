// Command imap serves mail clients: IMAP and SMTP submission, both on
// implicit TLS, in front of Rails' /api/v1/mail-client (docs/Mail-Clients.md).
package main

import (
	"context"
	"crypto/tls"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/inbox2/mta/internal/mailclient"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	fatal := func(msg string, args ...any) {
		log.Error(msg, args...)
		os.Exit(1)
	}

	backendURL := os.Getenv("MAILCLIENT_BACKEND_URL")
	certFile, keyFile := os.Getenv("MAILCLIENT_TLS_CERT"), os.Getenv("MAILCLIENT_TLS_KEY")
	if backendURL == "" {
		fatal("MAILCLIENT_BACKEND_URL is required")
	}
	if certFile == "" || keyFile == "" {
		// No plaintext fallback: these listeners carry passwords.
		fatal("MAILCLIENT_TLS_CERT and MAILCLIENT_TLS_KEY are required")
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		fatal("loading the TLS certificate", "error", err.Error())
	}
	tlsConfig := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}

	listen := func(addr string) net.Listener {
		ln, err := tls.Listen("tcp", addr, tlsConfig)
		if err != nil {
			fatal("listen", "addr", addr, "error", err.Error())
		}
		return ln
	}
	imapLn := listen(env("IMAP_LISTEN", ":9930"))
	smtpLn := listen(env("SUBMISSION_LISTEN", ":4651"))

	backend := mailclient.NewBackend(backendURL)
	imapSrv := (&mailclient.IMAP{Backend: backend, Log: log}).Server()
	smtpSrv := mailclient.NewSubmissionServer(backend, log, env("MAILCLIENT_DOMAIN", "mx.inbox2.com"), false)

	errs := make(chan error, 2)
	go func() { errs <- imapSrv.Serve(imapLn) }()
	go func() { errs <- smtpSrv.Serve(smtpLn) }()
	log.Info("mailclient.started", "imap", imapLn.Addr().String(), "submission", smtpLn.Addr().String(), "backend", backendURL)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	code := 0
	select {
	case <-ctx.Done():
		log.Info("mailclient.stopping")
	case err := <-errs:
		log.Error("mailclient.serve_failed", "error", err)
		code = 1
	}
	// Submission finishes the message in flight; IMAP connections are
	// long-lived (IDLE) and are closed, the clients reconnect.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	smtpSrv.Shutdown(shutdownCtx)
	imapSrv.Close()
	os.Exit(code)
}

// Command mx is the Inbox2 MX inbound SMTP receiver (spec 16.2.1).
//
// It receives inbound SMTP mail for verified domains, validates authentication
// (SPF/DKIM/DMARC), enforces per-plan size limits, and publishes accepted
// messages to NATS JetStream for the Rails app to consume.
//
// Logs are written as human-readable text to stdout. If MX_LOG_FILE is set,
// JSON structured logs are also appended to that file for analysis.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/inbox2/mta/internal/metrics"
	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/smtpd"
	"github.com/inbox2/mta/internal/spool"
)

func main() {
	logFile := os.Getenv("MX_LOG_FILE")
	logger, err := mxlog.New(logFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to open log file %s: %v\n", logFile, err)
		os.Exit(1)
	}
	defer logger.Close()

	cfg := smtpd.DefaultConfig()

	// Override from environment
	if addr := os.Getenv("MX_LISTEN"); addr != "" {
		cfg.ListenAddr = addr
	}
	if domain := os.Getenv("MX_DOMAIN"); domain != "" {
		cfg.Domain = domain
	}
	if cert := os.Getenv("MX_TLS_CERT"); cert != "" {
		cfg.TLSCertFile = cert
	}
	if key := os.Getenv("MX_TLS_KEY"); key != "" {
		cfg.TLSKeyFile = key
	}
	if mc := os.Getenv("MX_MAX_CONNECTIONS"); mc != "" {
		if n, err := strconv.Atoi(mc); err == nil && n >= 0 {
			cfg.MaxConnections = n
		}
	}
	// E2EE threading HMAC secret (docs/E2EE.md) — shared with Rails
	// (INBOX2_THREADING_HMAC_KEY). Unset ⇒ E2EE domains fall back to plaintext.
	if hk := os.Getenv("MX_THREADING_HMAC_KEY"); hk != "" {
		cfg.ThreadingHMACKey = []byte(hk)
	}
	// MX-inline spam scoring for sealed mail (self-hosted Rspamd).
	cfg.RspamdURL = os.Getenv("MX_RSPAMD_URL")
	// Edge spam defense (smtpd/edge.go). DNSBL zones are opt-in — most public
	// RBLs refuse queries via shared resolvers (e.g. MX_RBL_ZONES=zen.spamhaus.org
	// only works with a paid DQS key or dedicated resolver).
	if zones := os.Getenv("MX_RBL_ZONES"); zones != "" {
		for _, z := range strings.Split(zones, ",") {
			if z = strings.TrimSpace(z); z != "" {
				cfg.RBLZones = append(cfg.RBLZones, z)
			}
		}
	}
	if os.Getenv("MX_GREYLIST") == "off" {
		cfg.GreylistEnabled = false
	}
	// Sealed-attachment spool (ciphertext staging for async Garage upload).
	cfg.SpoolDir = os.Getenv("MX_SPOOL_DIR")

	natsURL := os.Getenv("NATS_URL")
	if natsURL == "" {
		natsURL = "nats://localhost:4222"
	}

	logger.Info("nats.connecting", "url", natsURL)
	pub, err := queue.NewPublisher(natsURL)
	if err != nil {
		logger.NATSError(err)
		os.Exit(1)
	}
	defer pub.Close()
	logger.NATSConnected(natsURL)

	backend := smtpd.NewBackend(cfg, pub, logger)

	// Sealed attachments: spool + background uploader to Garage (docs/E2EE.md).
	// Both the spool dir AND S3 credentials must be present; otherwise sealed
	// mail carries no attachments (stripped, never plaintext).
	s3cfg := spool.S3Config{
		Endpoint:  os.Getenv("S3_ENDPOINT"),
		Bucket:    os.Getenv("S3_BUCKET"),
		AccessKey: os.Getenv("S3_ACCESS_KEY_ID"),
		SecretKey: os.Getenv("S3_SECRET_ACCESS_KEY"),
		Region:    os.Getenv("S3_REGION"),
	}
	var uploader *spool.Uploader
	if cfg.SpoolDir != "" && s3cfg.Configured() {
		store, err := spool.NewStore(cfg.SpoolDir)
		if err != nil {
			logger.Error("spool.init_failed", "error", err.Error())
			os.Exit(1)
		}
		s3client, err := spool.NewS3Client(s3cfg)
		if err != nil {
			logger.Error("spool.s3_init_failed", "error", err.Error())
			os.Exit(1)
		}
		uploader = spool.NewUploader(store, s3client, 5*time.Second, func(event string, kv ...any) {
			logger.Info(event, kv...)
		})
		uploader.Start()
		defer uploader.Stop()
		backend.SetSealSpool(store, uploader.Kick)
		logger.Info("spool.ready", "dir", cfg.SpoolDir, "bucket", s3cfg.Bucket)
	} else if cfg.SpoolDir != "" || s3cfg.Configured() {
		logger.Warn("spool.partially_configured",
			"spool_dir_set", cfg.SpoolDir != "", "s3_set", s3cfg.Configured(),
			"effect", "sealed mail attachments will be stripped")
	}

	// Prometheus metrics (TODO 46.12): /metrics on MX_METRICS_ADDR (e.g.
	// ":9090"); empty = disabled.
	metrics.Serve(os.Getenv("MX_METRICS_ADDR"), func(err error) {
		logger.Error("metrics.serve_failed", "error", err.Error())
	})

	server := smtpd.NewServer(backend)

	listener, err := backend.Listen()
	if err != nil {
		logger.Error("server.listen_failed", "error", err.Error())
		os.Exit(1)
	}

	// Start SMTP server in background
	go func() {
		if err := server.Serve(listener); err != nil {
			logger.Error("server.fatal", "error", err.Error())
			os.Exit(1)
		}
	}()

	// Wait for shutdown signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	received := <-sig
	logger.Info("server.signal", "signal", received.String())

	// Graceful shutdown: stop accepting and let in-flight transactions finish.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		logger.Error("server.shutdown_error", "error", err.Error())
	}
	logger.ServerStop()
}

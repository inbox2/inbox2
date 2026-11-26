// Command smtp is the Inbox2 SMTP outbound sender (spec 16.2.2).
//
// It consumes outbound send jobs from NATS JetStream, DKIM-signs messages,
// delivers via SMTP to remote MTAs, and publishes delivery status results
// back to NATS for the Rails app to update delivery tracking.
//
// Logs are written as human-readable text to stdout. If SMTP_LOG_FILE is set,
// JSON structured logs are also appended to that file.
package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/inbox2/mta/internal/errreport"
	"github.com/inbox2/mta/internal/metrics"
	"github.com/inbox2/mta/internal/outbound"
)

func main() {
	defer errreport.Init("smtp")()
	logFile := os.Getenv("SMTP_LOG_FILE")
	logger, err := outbound.NewLogger(logFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to open log file %s: %v\n", logFile, err)
		errreport.Exit(1)
	}
	defer logger.Close()

	domain := os.Getenv("SMTP_DOMAIN")
	if domain == "" {
		domain = "smtp.inbox2.local"
	}

	natsURL := os.Getenv("NATS_URL")
	if natsURL == "" {
		natsURL = "nats://localhost:4222"
	}

	workers := outbound.DefaultWorkers
	if w := os.Getenv("SMTP_WORKERS"); w != "" {
		if n, err := strconv.Atoi(w); err == nil && n > 0 {
			workers = n
		}
	}

	logger.Info("nats.connecting", "url", natsURL)
	consumer, err := outbound.NewConsumer(natsURL)
	if err != nil {
		logger.Error("nats.error", "error", err.Error())
		errreport.Exit(1)
	}
	defer consumer.Close()
	logger.NATSConnected(natsURL)

	sender := outbound.NewSender(domain, logger)
	if keyDir := os.Getenv("SMTP_DKIM_KEY_DIR"); keyDir != "" {
		sender.SetKeyStore(outbound.NewDKIMKeyStore(keyDir))
		logger.Info("dkim.keystore", "dir", keyDir)
	}
	// MTA delivery key (docs/E2EE.md Phase I): opens sealed outbound MIME queued
	// for E2EE domains. Generate a pair with `go run ./cmd/deliverykey`.
	if dk := os.Getenv("SMTP_DELIVERY_PRIVATE_KEY"); dk != "" {
		raw, err := base64.StdEncoding.DecodeString(dk)
		if err != nil {
			logger.Error("delivery_key.invalid", "error", err.Error())
			errreport.Exit(1)
		}
		if err := sender.SetDeliveryKey(raw); err != nil {
			logger.Error("delivery_key.invalid", "error", err.Error())
			errreport.Exit(1)
		}
		logger.Info("delivery_key.loaded")
	}

	// IP-reputation guardrails (outbound/reputation.go). PTR self-check is
	// log-only; warmup + per-domain pacing shape actual send flow.
	if publicIP := os.Getenv("SMTP_PUBLIC_IP"); publicIP != "" {
		if problems := outbound.CheckPTR(publicIP, domain); len(problems) > 0 {
			for _, p := range problems {
				logger.Warn("reputation.ptr", "problem", p)
			}
		} else {
			logger.Info("reputation.ptr_ok", "ip", publicIP, "domain", domain)
		}
	}
	var warmupStart time.Time
	if ws := os.Getenv("SMTP_WARMUP_START"); ws != "" {
		t, err := time.Parse("2006-01-02", ws)
		if err != nil {
			logger.Error("warmup.invalid_start", "value", ws, "error", err.Error())
			errreport.Exit(1)
		}
		warmupStart = t
		logger.Info("warmup.enabled", "start", ws)
	}
	domainConcurrency := envInt("SMTP_DOMAIN_CONCURRENCY", 4)
	domainRate := envInt("SMTP_DOMAIN_RATE", 60) // per domain per minute
	throttle := outbound.NewThrottle(domainConcurrency, domainRate, time.Minute, warmupStart)

	// Prometheus metrics (TODO 46.12): /metrics on SMTP_METRICS_ADDR (e.g.
	// ":9090"); empty = disabled.
	metrics.Serve(os.Getenv("SMTP_METRICS_ADDR"), func(err error) {
		logger.Error("metrics.serve_failed", "error", err.Error())
	})

	startRelay(domain, sender, throttle, logger)

	logger.ServerStart(workers, domain, natsURL)

	// Shutdown signal
	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		received := <-sig
		logger.Info("server.signal", "signal", received.String())
		cancel()
	}()

	// Start worker pool
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runWorker(ctx, id, consumer, sender, throttle, logger)
		}(i)
	}

	wg.Wait()
	logger.ServerStop()
}

// startRelay opens the authenticated pass-through relay (outbound/relay.go).
// Off switch: no RELAY_PASSWORD, no listener. It needs a certificate
// (RELAY_TLS_CERT + RELAY_TLS_KEY, implicit TLS) and refuses to serve the
// credential in the clear.
func startRelay(domain string, sender *outbound.Sender, throttle *outbound.Throttle, logger *outbound.Logger) {
	password := os.Getenv("RELAY_PASSWORD")
	if password == "" {
		return
	}
	cert, err := tls.LoadX509KeyPair(os.Getenv("RELAY_TLS_CERT"), os.Getenv("RELAY_TLS_KEY"))
	if err != nil {
		logger.Error("relay.tls_failed", "error", err.Error())
		return
	}
	addr := os.Getenv("RELAY_LISTEN")
	if addr == "" {
		addr = ":4650"
	}
	user := os.Getenv("RELAY_USER")
	if user == "" {
		user = "pushleft"
	}
	if d := os.Getenv("RELAY_DOMAIN"); d != "" {
		domain = d
	}
	ln, err := tls.Listen("tcp", addr, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		logger.Error("relay.listen_failed", "addr", addr, "error", err.Error())
		return
	}
	logger.Info("relay.listening", "addr", addr, "user", user)
	go func() {
		if err := outbound.NewRelayServer(domain, user, password, sender, throttle, logger).Serve(ln); err != nil {
			logger.Error("relay.serve_failed", "error", err.Error())
		}
	}()
}

func envInt(name string, fallback int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return fallback
}

func runWorker(ctx context.Context, id int, consumer *outbound.Consumer, sender *outbound.Sender, throttle *outbound.Throttle, logger *outbound.Logger) {
	logger.WorkerStarted(id)
	defer logger.WorkerStopped(id)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Warmup gate BEFORE fetching: a fetched job ages against AckWait, so
		// waiting out the daily budget must happen while we hold nothing.
		if !throttle.WarmupBudgetLeft(time.Now()) {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Minute):
			}
			continue
		}

		// Fetch one message at a time
		msgs, err := consumer.Fetch(1, 5*time.Second)
		if err != nil {
			// Timeout or transient error — loop back
			continue
		}
		if len(msgs) == 0 {
			continue
		}

		natsMsg := msgs[0]
		msg, err := outbound.ParseMessage(natsMsg.Data())
		if err != nil {
			logger.Error("parse.error", "worker_id", id, "error", err.Error())
			natsMsg.Ack() // Ack bad messages to prevent redelivery loops
			continue
		}

		logger.NATSConsume(msg.MessageKey, msg.DeliveryStatusKey)

		// Deliver the message, paced per recipient domain. The 2-minute
		// acquire deadline stays well inside AckWait (5m); on timeout the job
		// transient-fails so Rails reschedules it with backoff instead of the
		// worker sitting on an aging un-acked message.
		start := time.Now()
		var result *outbound.DeliveryResult
		rcptDomain := outbound.RecipientDomain(msg.Envelope.RcptTo)
		if throttle.AcquireDomain(rcptDomain, 2*time.Minute) {
			throttle.CountSend(time.Now())
			result = sender.Send(msg)
			throttle.ReleaseDomain(rcptDomain)
		} else {
			logger.Warn("throttle.domain_timeout", "domain", rcptDomain, "message_key", msg.MessageKey)
			metrics.Inc("smtp_throttle_timeouts_total")
			result = outbound.ThrottledResult(msg)
		}
		metrics.Inc("smtp_deliveries_total", "result", result.Result)

		if result.Result == "success" {
			logger.DeliverySuccess(msg.MessageKey, result.MXHost, result.TLSVersion, outbound.DurationMs(time.Since(start)))
		} else {
			logger.DeliveryFailure(msg.MessageKey, result.Result, result.ResponseMessage, result.AttemptNumber, outbound.DurationMs(time.Since(start)))
		}

		// Publish result back to Rails. Invariant: never Ack a job whose
		// DeliveryResult Rails hasn't received — Acking a delivered-but-
		// unreported job makes Rails re-publish it and the recipient gets the
		// mail twice. Retry the publish briefly; if it still fails, skip the
		// Ack so JetStream redelivers after AckWait (consumer MaxDeliver > 1).
		//
		// Residual duplicate-send window: if delivery succeeded but every
		// publish attempt fails, redelivery re-runs Send and can deliver the
		// message a second time — the payload carries no attempt marker, so a
		// redelivered job is indistinguishable from a fresh one. Accepted: a
		// rare duplicate (NATS down for the whole retry burst) beats silent
		// loss, and Rails re-publishing on a missing result would duplicate
		// anyway.
		published := false
		for attempt := 1; attempt <= 3; attempt++ {
			pubCtx, pubCancel := context.WithTimeout(context.Background(), 5*time.Second)
			err := consumer.PublishResult(pubCtx, result)
			pubCancel()
			if err == nil {
				published = true
				logger.PublishResult(result.DeliveryStatusKey, result.Result)
				break
			}
			logger.PublishResultError(result.DeliveryStatusKey, err)
			time.Sleep(time.Duration(attempt) * time.Second)
		}
		if !published {
			continue // no Ack — redelivered after AckWait
		}

		// Ack the outbound message
		natsMsg.Ack()
	}
}

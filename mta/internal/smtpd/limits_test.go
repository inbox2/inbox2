package smtpd

import (
	"testing"
	"time"
)

func limitBackend() *Backend {
	cfg := DefaultConfig()
	cfg.MaxConnsPerIP = 2
	cfg.RcptFailLimit = 3
	cfg.RcptFailWindow = 10 * time.Minute
	return &Backend{
		config:     cfg,
		connsPerIP: make(map[string]int),
		rcptFails:  make(map[string]*rcptFailWindow),
	}
}

func TestPerIPConnCap(t *testing.T) {
	b := limitBackend()

	if !b.acquireConn("1.2.3.4") || !b.acquireConn("1.2.3.4") {
		t.Fatal("first two connections should be admitted")
	}
	if b.acquireConn("1.2.3.4") {
		t.Fatal("third concurrent connection should be refused")
	}
	if !b.acquireConn("5.6.7.8") {
		t.Fatal("other IPs must be unaffected")
	}

	b.releaseConn("1.2.3.4")
	if !b.acquireConn("1.2.3.4") {
		t.Fatal("slot should free up after release")
	}

	// Full drain self-cleans the map entry.
	b.releaseConn("1.2.3.4")
	b.releaseConn("1.2.3.4")
	if _, ok := b.connsPerIP["1.2.3.4"]; ok {
		t.Fatal("zeroed IP should be deleted from the map")
	}
}

func TestRcptFailureBudget(t *testing.T) {
	b := limitBackend()
	ip := "1.2.3.4"

	for i := 0; i < 3; i++ {
		if b.rcptBudgetExhausted(ip) {
			t.Fatalf("budget exhausted after only %d failures", i)
		}
		b.recordRcptFailure(ip)
	}
	if !b.rcptBudgetExhausted(ip) {
		t.Fatal("budget should be exhausted after RcptFailLimit failures")
	}
	if b.rcptBudgetExhausted("5.6.7.8") {
		t.Fatal("other IPs must be unaffected")
	}

	// Window rollover resets the budget.
	b.rcptFails[ip].start = time.Now().Add(-11 * time.Minute)
	if b.rcptBudgetExhausted(ip) {
		t.Fatal("expired window should reset the budget")
	}

	// A failure after expiry starts a fresh window and sweeps stale entries.
	b.rcptFails["9.9.9.9"] = &rcptFailWindow{start: time.Now().Add(-11 * time.Minute), count: 3}
	b.lastSweep = time.Now().Add(-11 * time.Minute)
	b.recordRcptFailure(ip)
	if b.rcptFails[ip].count != 1 {
		t.Fatalf("fresh window count = %d, want 1", b.rcptFails[ip].count)
	}
	if _, ok := b.rcptFails["9.9.9.9"]; ok {
		t.Fatal("sweep should drop expired windows")
	}
}

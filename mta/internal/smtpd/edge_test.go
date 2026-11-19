package smtpd

import (
	"fmt"
	"testing"
	"time"
)

func edgeBackend(t *testing.T) *Backend {
	t.Helper()
	cfg := DefaultConfig()
	b := &Backend{
		config:     cfg,
		connsPerIP: make(map[string]int),
		rcptFails:  make(map[string]*rcptFailWindow),
		edge:       newEdgeState(),
	}
	return b
}

func TestReverseIP(t *testing.T) {
	if got := reverseIP("1.2.3.4"); got != "4.3.2.1" {
		t.Fatalf("v4 reverse = %q", got)
	}
	if got := reverseIP("garbage"); got != "" {
		t.Fatalf("garbage reverse = %q", got)
	}
	// v6: 32 reversed nibbles.
	if got := reverseIP("2001:db8::1"); len(got) != 63 {
		t.Fatalf("v6 reverse unexpected length: %q", got)
	}
}

func TestRBLListedAndCached(t *testing.T) {
	b := edgeBackend(t)
	b.config.RBLZones = []string{"rbl.test"}
	lookups := 0
	b.edge.lookupHost = func(host string) ([]string, error) {
		lookups++
		if host == "4.3.2.1.rbl.test" {
			return []string{"127.0.0.2"}, nil
		}
		return nil, fmt.Errorf("NXDOMAIN")
	}

	if listed, zone := b.rblListed("1.2.3.4"); !listed || zone != "rbl.test" {
		t.Fatalf("expected listed on rbl.test, got %v %q", listed, zone)
	}
	if listed, _ := b.rblListed("5.6.7.8"); listed {
		t.Fatal("clean IP flagged as listed")
	}
	// Cached: verdicts don't re-query.
	b.rblListed("1.2.3.4")
	b.rblListed("5.6.7.8")
	if lookups != 2 {
		t.Fatalf("expected 2 lookups (cache), got %d", lookups)
	}
}

func TestConnRateLimit(t *testing.T) {
	b := edgeBackend(t)
	b.config.ConnRateLimit = 3
	b.config.ConnRateWindow = time.Minute

	for i := 0; i < 3; i++ {
		if b.connRateExceeded("9.9.9.9") {
			t.Fatalf("connection %d rejected below the limit", i+1)
		}
	}
	if !b.connRateExceeded("9.9.9.9") {
		t.Fatal("connection over the limit was allowed")
	}
	if b.connRateExceeded("8.8.8.8") {
		t.Fatal("other IP affected by the limit")
	}
}

func TestGreylistPTRlessTripleTempfailsThenPasses(t *testing.T) {
	b := edgeBackend(t)
	b.edge.lookupAddr = func(string) ([]string, error) { return nil, fmt.Errorf("no PTR") }

	if !b.greylisted("1.2.3.4", "a@x.com", "b@team.com") {
		t.Fatal("first contact should be greylisted")
	}
	// Immediate retry: still inside the delay.
	if !b.greylisted("1.2.3.4", "a@x.com", "b@team.com") {
		t.Fatal("retry inside the delay should stay greylisted")
	}
	// Age the entry past the delay; a sibling IP in the same /24 retries.
	key := greylistKey("1.2.3.4", "a@x.com", "b@team.com")
	b.edge.greylist[key].firstSeen = time.Now().Add(-greylistDelay - time.Second)
	if b.greylisted("1.2.3.9", "a@x.com", "b@team.com") {
		t.Fatal("retry after the delay (same /24) should pass")
	}
	// Approved triples keep passing.
	if b.greylisted("1.2.3.4", "a@x.com", "b@team.com") {
		t.Fatal("approved triple should pass")
	}
	// A different triple starts its own cycle.
	if !b.greylisted("1.2.3.4", "other@x.com", "b@team.com") {
		t.Fatal("new triple should be greylisted")
	}
}

func TestGreylistSkipsClientsWithPTR(t *testing.T) {
	b := edgeBackend(t)
	b.edge.lookupAddr = func(string) ([]string, error) { return []string{"mail.example.com."}, nil }

	if b.greylisted("1.2.3.4", "a@x.com", "b@team.com") {
		t.Fatal("client with PTR should never be greylisted")
	}
}

func TestGreylistDisabled(t *testing.T) {
	b := edgeBackend(t)
	b.config.GreylistEnabled = false
	b.edge.lookupAddr = func(string) ([]string, error) { return nil, fmt.Errorf("no PTR") }

	if b.greylisted("1.2.3.4", "a@x.com", "b@team.com") {
		t.Fatal("disabled greylist must pass everything")
	}
}

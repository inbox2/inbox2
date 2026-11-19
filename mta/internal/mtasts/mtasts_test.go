package mtasts

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParsePolicy(t *testing.T) {
	p, err := ParsePolicy("version: STSv1\r\nmode: enforce\r\nmx: mail.example.com\r\nmx: *.backup.example.com\r\nmax_age: 86400\r\n")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if p.Mode != ModeEnforce || len(p.MXPatterns) != 2 || p.MaxAge != 24*time.Hour {
		t.Fatalf("unexpected policy: %+v", p)
	}
}

func TestParsePolicyRejectsBadVersionAndMode(t *testing.T) {
	if _, err := ParsePolicy("version: STSv2\nmode: enforce\nmx: a.b\n"); err == nil {
		t.Fatal("expected version error")
	}
	if _, err := ParsePolicy("version: STSv1\nmode: sideways\nmx: a.b\n"); err == nil {
		t.Fatal("expected mode error")
	}
	if _, err := ParsePolicy("version: STSv1\nmode: enforce\n"); err == nil {
		t.Fatal("expected missing-mx error")
	}
}

func TestMXMatches(t *testing.T) {
	p := &Policy{MXPatterns: []string{"mail.example.com", "*.relay.example.com"}}
	cases := map[string]bool{
		"mail.example.com":        true,
		"MAIL.EXAMPLE.COM.":       true,
		"mx1.relay.example.com":   true,
		"a.b.relay.example.com":   false, // wildcard = one label only
		"relay.example.com":       false, // wildcard doesn't match the bare suffix
		"evil.com":                false,
		"notmail.example.com":     false,
	}
	for host, want := range cases {
		if got := p.MXMatches(host); got != want {
			t.Errorf("MXMatches(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestStoreFetchAndCache(t *testing.T) {
	fetches := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetches++
		fmt.Fprint(w, "version: STSv1\nmode: enforce\nmx: mail.example.com\nmax_age: 3600\n")
	}))
	defer srv.Close()

	s := NewStore()
	s.lookupTXT = func(string) ([]string, error) { return []string{"v=STSv1; id=20260710"}, nil }
	s.policyURL = func(string) string { return srv.URL }
	s.client = srv.Client()

	p := s.Get("example.com")
	if !p.Enforce() {
		t.Fatalf("expected enforce policy, got %+v", p)
	}
	// Second read is served from cache.
	s.Get("example.com")
	if fetches != 1 {
		t.Fatalf("expected 1 fetch, got %d", fetches)
	}
}

func TestStoreNoPolicyIsCachedNegative(t *testing.T) {
	lookups := 0
	s := NewStore()
	s.lookupTXT = func(string) ([]string, error) { lookups++; return nil, fmt.Errorf("NXDOMAIN") }

	if p := s.Get("nopolicy.test"); p != nil {
		t.Fatalf("expected nil policy, got %+v", p)
	}
	s.Get("nopolicy.test")
	if lookups != 1 {
		t.Fatalf("expected 1 lookup (negative cache), got %d", lookups)
	}
}

func TestStoreKeepsStalePolicyOnFetchFailure(t *testing.T) {
	healthy := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !healthy {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		fmt.Fprint(w, "version: STSv1\nmode: enforce\nmx: mail.example.com\nmax_age: 60\n")
	}))
	defer srv.Close()

	s := NewStore()
	s.lookupTXT = func(string) ([]string, error) { return []string{"v=STSv1; id=1"}, nil }
	s.policyURL = func(string) string { return srv.URL }
	s.client = srv.Client()

	if p := s.Get("example.com"); !p.Enforce() {
		t.Fatal("expected enforce policy on first fetch")
	}
	// Expire the entry, then break the policy host: the stale policy stays in effect.
	s.mu.Lock()
	e := s.entries["example.com"]
	e.expires = time.Now().Add(-time.Second)
	s.entries["example.com"] = e
	s.mu.Unlock()
	healthy = false

	if p := s.Get("example.com"); !p.Enforce() {
		t.Fatal("expected stale policy to remain in effect on fetch failure")
	}
}

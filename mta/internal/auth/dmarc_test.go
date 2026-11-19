package auth

import (
	"testing"
)

func TestDomainAligns(t *testing.T) {
	tests := []struct {
		authDomain string
		fromDomain string
		want       bool
	}{
		{"example.com", "example.com", true},        // exact match
		{"mail.example.com", "example.com", true},   // subdomain relaxed
		{"example.com", "mail.example.com", true},   // reverse subdomain relaxed
		{"other.com", "example.com", false},         // different domain
		{"sub.other.com", "sub.example.com", false}, // different org domain
		{"Example.COM", "example.com", true},        // case insensitive
		{"a.b.example.com", "example.com", true},    // deep subdomain
	}

	for _, tt := range tests {
		got := domainAligns(tt.authDomain, tt.fromDomain)
		if got != tt.want {
			t.Errorf("domainAligns(%q, %q) = %v, want %v", tt.authDomain, tt.fromDomain, got, tt.want)
		}
	}
}

func TestOrgDomain(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"example.com", "example.com"},
		{"mail.example.com", "example.com"},
		{"a.b.example.com", "example.com"},
		{"com", "com"},
	}

	for _, tt := range tests {
		got := orgDomain(tt.input)
		if got != tt.want {
			t.Errorf("orgDomain(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestParseDMARCPolicy(t *testing.T) {
	tests := []struct {
		record string
		want   string
	}{
		{"v=DMARC1; p=reject; rua=mailto:dmarc@example.com", "reject"},
		{"v=DMARC1; p=quarantine", "quarantine"},
		{"v=DMARC1; p=none", "none"},
		{"v=DMARC1", "none"},            // no p= tag
		{"v=DMARC1; p=invalid", "none"}, // invalid policy
	}

	for _, tt := range tests {
		got := parseDMARCPolicy(tt.record)
		if got != tt.want {
			t.Errorf("parseDMARCPolicy(%q) = %q, want %q", tt.record, got, tt.want)
		}
	}
}

func TestCheckDMARC_Pass_SPFAligned(t *testing.T) {
	spf := SPFResult{Result: "pass", Domain: "example.com"}
	dkim := DKIMResult{Result: "none"}
	result := CheckDMARC("example.com", spf, dkim)

	// This will do a real DNS lookup for _dmarc.example.com which may or may not exist
	// In any case, SPF is aligned so if there's a DMARC record it should pass
	// If no record, result is "none"
	if result.Result != "pass" && result.Result != "none" {
		t.Errorf("result = %q, want pass or none", result.Result)
	}
}

// TestDomainAligns_SpoofedFrom locks in the DMARC fix: an authenticated
// identifier from an attacker-controlled domain must NOT align with a spoofed
// From header domain, even when both sit under the same public suffix.
func TestDomainAligns_SpoofedFrom(t *testing.T) {
	spoofs := []struct{ auth, from string }{
		{"evil.com", "bigbank.com"},        // unrelated org domains
		{"attacker.co.uk", "victim.co.uk"}, // same ccTLD public suffix, different orgs
		{"a.attacker.com", "b.victim.com"}, // different org domains via subdomains
	}
	for _, s := range spoofs {
		if domainAligns(s.auth, s.from) {
			t.Errorf("domainAligns(%q, %q) = true, want false (spoof must not align)", s.auth, s.from)
		}
	}
}

func TestCheckDMARC_EmptyDomain(t *testing.T) {
	spf := SPFResult{Result: "pass", Domain: "example.com"}
	dkim := DKIMResult{Result: "pass", Domain: "example.com"}
	result := CheckDMARC("", spf, dkim)
	if result.Result != "none" {
		t.Errorf("result = %q, want %q for empty domain", result.Result, "none")
	}
}

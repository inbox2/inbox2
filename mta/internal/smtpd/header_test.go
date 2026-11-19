package smtpd

import "testing"

// TestHeaderDomain locks in the DMARC fix: the domain used for DMARC must come
// from the RFC5322.From header value, regardless of display name formatting.
func TestHeaderDomain(t *testing.T) {
	tests := []struct {
		from string
		want string
	}{
		{"Alice <alice@example.com>", "example.com"},
		{"alice@example.com", "example.com"},
		{"\"Bank, The\" <noreply@BigBank.com>", "bigbank.com"},
		{"", ""},
		{"garbage-no-at", ""},
	}
	for _, tt := range tests {
		if got := headerDomain(tt.from); got != tt.want {
			t.Errorf("headerDomain(%q) = %q, want %q", tt.from, got, tt.want)
		}
	}
}

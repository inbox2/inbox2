package auth

import (
	"testing"
)

func TestSplitAddress(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"user@example.com", "example.com"},
		{"alice@mail.example.org", "mail.example.org"},
		{"nodomain", ""},
		{"", ""},
		{"user@", ""},
	}

	for _, tt := range tests {
		got := splitAddress(tt.input)
		if got != tt.want {
			t.Errorf("splitAddress(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestCheckSPF_InvalidIP(t *testing.T) {
	result := CheckSPF("not-an-ip", "sender@example.com", "mail.example.com")
	if result.Result != "none" {
		t.Errorf("result = %q, want %q for invalid IP", result.Result, "none")
	}
}

func TestCheckSPF_EmptyIP(t *testing.T) {
	result := CheckSPF("", "sender@example.com", "mail.example.com")
	if result.Result != "none" {
		t.Errorf("result = %q, want %q for empty IP", result.Result, "none")
	}
}

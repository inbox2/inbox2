package auth

import (
	"testing"
)

func TestVerifyDKIM_NoSignature(t *testing.T) {
	// Message without DKIM-Signature header
	raw := []byte("From: test@example.com\r\nTo: dest@acme.com\r\nSubject: No DKIM\r\n\r\nBody\r\n")
	result := VerifyDKIM(raw)
	if result.Result != "none" {
		t.Errorf("result = %q, want %q for message without DKIM", result.Result, "none")
	}
}

func TestVerifyDKIM_MalformedMessage(t *testing.T) {
	// Completely malformed input
	raw := []byte("not a valid email at all")
	result := VerifyDKIM(raw)
	// Should not panic, should return none or temperror
	if result.Result != "none" && result.Result != "temperror" {
		t.Errorf("result = %q, want none or temperror for malformed input", result.Result)
	}
}

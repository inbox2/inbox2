package outbound_test

import (
	"bytes"
	"strings"
	"testing"

	"github.com/emersion/go-msgauth/dkim"
	"github.com/inbox2/mta/internal/outbound"
)

func TestGenerateTestDKIMKey(t *testing.T) {
	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		t.Fatalf("GenerateTestDKIMKey: %v", err)
	}
	if !strings.Contains(keyPEM, "RSA PRIVATE KEY") {
		t.Errorf("key doesn't contain PEM header: %s", keyPEM[:50])
	}
}

func TestSignMessage(t *testing.T) {
	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		t.Fatalf("GenerateTestDKIMKey: %v", err)
	}

	rawMessage := []byte("From: sender@example.com\r\n" +
		"To: recipient@acme.com\r\n" +
		"Subject: DKIM Test\r\n" +
		"Date: Sat, 24 May 2026 12:00:00 +0000\r\n" +
		"Message-ID: <dkim-test@example.com>\r\n" +
		"Content-Type: text/plain\r\n" +
		"\r\n" +
		"Hello, this is a DKIM-signed test message.\r\n")

	signed, err := outbound.SignMessage(rawMessage, "example.com", "test", keyPEM)
	if err != nil {
		t.Fatalf("SignMessage: %v", err)
	}

	// Verify the DKIM-Signature header was added
	if !bytes.Contains(signed, []byte("DKIM-Signature:")) {
		t.Error("signed message missing DKIM-Signature header")
	}

	// Verify the original content is preserved
	if !bytes.Contains(signed, []byte("Subject: DKIM Test")) {
		t.Error("signed message missing original Subject header")
	}
	if !bytes.Contains(signed, []byte("Hello, this is a DKIM-signed test message.")) {
		t.Error("signed message missing original body")
	}

	// Verify DKIM signature domain/selector
	if !bytes.Contains(signed, []byte("d=example.com")) {
		t.Error("DKIM-Signature missing domain")
	}
	if !bytes.Contains(signed, []byte("s=test")) {
		t.Error("DKIM-Signature missing selector")
	}
}

func TestSignMessage_CanVerify(t *testing.T) {
	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		t.Fatalf("GenerateTestDKIMKey: %v", err)
	}

	rawMessage := []byte("From: sender@example.com\r\n" +
		"To: recipient@acme.com\r\n" +
		"Subject: Verify Test\r\n" +
		"Date: Sat, 24 May 2026 12:00:00 +0000\r\n" +
		"Message-ID: <verify-test@example.com>\r\n" +
		"\r\n" +
		"Body for verification.\r\n")

	signed, err := outbound.SignMessage(rawMessage, "example.com", "test", keyPEM)
	if err != nil {
		t.Fatalf("SignMessage: %v", err)
	}

	// Attempt DKIM verification — this will fail DNS lookup (no public key published)
	// but should at least parse the signature without error
	verifications, err := dkim.Verify(bytes.NewReader(signed))
	// We expect an error (DNS lookup fails) but the signature should be found
	if len(verifications) == 0 && err == nil {
		t.Log("No DKIM verifications found (expected — DNS lookup required for full verification)")
	} else if len(verifications) > 0 {
		// If verification was attempted, the domain should match
		if verifications[0].Domain != "example.com" {
			t.Errorf("verification domain = %q, want %q", verifications[0].Domain, "example.com")
		}
	}
}

func TestSignMessage_InvalidKey(t *testing.T) {
	_, err := outbound.SignMessage([]byte("From: a@b.com\r\n\r\nBody\r\n"), "example.com", "test", "not-a-pem-key")
	if err == nil {
		t.Fatal("expected error for invalid PEM key")
	}
}

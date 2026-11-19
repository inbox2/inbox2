package outbound

import (
	"crypto/rand"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/inbox2/mta/internal/seal"
	"golang.org/x/crypto/nacl/box"
)

// Phase I round-trip: what Rails produces (DEK sealed to the delivery public
// key + XChaCha ciphertext with AAD = message key) must open in the sender.
func sealMIMEForTest(t *testing.T, pub *[32]byte, mime []byte, messageKey string) *SealedMIME {
	t.Helper()
	dek, err := seal.GenerateDEK()
	if err != nil {
		t.Fatal(err)
	}
	nonce, ct, err := seal.Encrypt(dek, mime, []byte(messageKey))
	if err != nil {
		t.Fatal(err)
	}
	sealedDEK, err := box.SealAnonymous(nil, dek, pub, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &SealedMIME{
		SealedDEK:  base64.StdEncoding.EncodeToString(sealedDEK),
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(ct),
	}
}

func TestOpenSealedMIMERoundTrip(t *testing.T) {
	pub, priv, _ := box.GenerateKey(rand.Reader)
	s := &Sender{}
	if err := s.SetDeliveryKey(priv[:]); err != nil {
		t.Fatal(err)
	}

	mime := []byte("From: a@sealed.example\r\nSubject: SECRET-OUTBOUND\r\n\r\nquoted sealed content\r\n")
	msg := &OutboundMessage{
		MessageKey: "msg_abc123",
		SealedMIME: sealMIMEForTest(t, pub, mime, "msg_abc123"),
	}

	got, err := s.openSealedMIME(msg)
	if err != nil {
		t.Fatalf("openSealedMIME: %v", err)
	}
	if string(got) != string(mime) {
		t.Fatal("round-trip mismatch")
	}
}

func TestOpenSealedMIMERejectsWrongKeyAndTamper(t *testing.T) {
	pub, _, _ := box.GenerateKey(rand.Reader)
	_, otherPriv, _ := box.GenerateKey(rand.Reader)

	s := &Sender{}
	_ = s.SetDeliveryKey(otherPriv[:])
	msg := &OutboundMessage{
		MessageKey: "msg_abc123",
		SealedMIME: sealMIMEForTest(t, pub, []byte("body"), "msg_abc123"),
	}
	if _, err := s.openSealedMIME(msg); err == nil {
		t.Fatal("wrong delivery key accepted")
	}

	// No delivery key configured at all → clear diagnostic.
	s3 := &Sender{}
	if _, err := s3.openSealedMIME(msg); err == nil || !strings.Contains(err.Error(), "SMTP_DELIVERY_PRIVATE_KEY") {
		t.Fatalf("expected clear no-key diagnostic, got %v", err)
	}
}

func TestOpenSealedMIMERejectsTamperedAAD(t *testing.T) {
	pub, priv, _ := box.GenerateKey(rand.Reader)
	s := &Sender{}
	_ = s.SetDeliveryKey(priv[:])

	sealed := sealMIMEForTest(t, pub, []byte("body"), "msg_original")
	msg := &OutboundMessage{MessageKey: "msg_grafted", SealedMIME: sealed}
	if _, err := s.openSealedMIME(msg); err == nil {
		t.Fatal("AAD tamper accepted")
	}
}

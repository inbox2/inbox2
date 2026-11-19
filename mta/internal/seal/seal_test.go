package seal

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"strings"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

func TestEncryptDecryptRoundTrip(t *testing.T) {
	dek, err := GenerateDEK()
	if err != nil {
		t.Fatalf("GenerateDEK: %v", err)
	}
	plaintext := []byte("Confidential: Q3 layoffs plan")
	aad := AAD(42, 1, "<msg-1@example.com>")

	nonce, ciphertext, err := Encrypt(dek, plaintext, aad)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if bytes.Contains(ciphertext, []byte("Confidential")) {
		t.Fatal("ciphertext leaks plaintext")
	}

	got, err := Decrypt(dek, nonce, ciphertext, aad)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Fatalf("round-trip mismatch: got %q", got)
	}
}

// A sealed blob must be bound to its row identity: decrypting under a
// different domain/key-version/message-id AAD must fail.
func TestDecryptRejectsTamperedAAD(t *testing.T) {
	dek, _ := GenerateDEK()
	nonce, ciphertext, err := Encrypt(dek, []byte("body"), AAD(42, 1, "<msg-1@example.com>"))
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	for _, aad := range [][]byte{
		AAD(43, 1, "<msg-1@example.com>"), // different domain
		AAD(42, 2, "<msg-1@example.com>"), // different key version
		AAD(42, 1, "<msg-2@example.com>"), // grafted onto another message
	} {
		if _, err := Decrypt(dek, nonce, ciphertext, aad); err == nil {
			t.Fatalf("Decrypt accepted tampered AAD %q", aad)
		}
	}
}

func TestSealDEKOpensWithSecretKey(t *testing.T) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	dek, _ := GenerateDEK()

	sealed, err := SealDEK(dek, base64.StdEncoding.EncodeToString(pub[:]))
	if err != nil {
		t.Fatalf("SealDEK: %v", err)
	}
	if bytes.Contains(sealed, dek) {
		t.Fatal("sealed blob contains the raw DEK")
	}

	opened, ok := box.OpenAnonymous(nil, sealed, pub, priv)
	if !ok {
		t.Fatal("OpenAnonymous failed")
	}
	if !bytes.Equal(opened, dek) {
		t.Fatal("unsealed DEK mismatch")
	}

	// The wrong secret key must not open it.
	otherPub, otherPriv, _ := box.GenerateKey(rand.Reader)
	if _, ok := box.OpenAnonymous(nil, sealed, otherPub, otherPriv); ok {
		t.Fatal("sealed DEK opened with the wrong key")
	}
}

func TestSealDEKRejectsBadPublicKey(t *testing.T) {
	dek, _ := GenerateDEK()
	if _, err := SealDEK(dek, "not base64!!"); err == nil {
		t.Fatal("accepted invalid base64")
	}
	short := base64.StdEncoding.EncodeToString([]byte("short"))
	if _, err := SealDEK(dek, short); err == nil {
		t.Fatal("accepted a non-32-byte key")
	}
}

func TestThreadingHMAC(t *testing.T) {
	key := []byte("test-threading-key")
	a := ThreadingHMAC(key, "<msg-1@example.com>")
	b := ThreadingHMAC(key, "<msg-1@example.com>")
	if a != b {
		t.Fatal("HMAC not deterministic")
	}
	if a == ThreadingHMAC(key, "<msg-2@example.com>") {
		t.Fatal("distinct values collided")
	}
	if a == ThreadingHMAC([]byte("other-key"), "<msg-1@example.com>") {
		t.Fatal("HMAC ignores the key")
	}
	if len(a) != 64 || strings.ToLower(a) != a {
		t.Fatalf("expected lowercase hex sha256, got %q", a)
	}
}

// Package seal implements the crypto primitives for E2EE message sealing
// (docs/E2EE.md): XChaCha20-Poly1305 AEAD for body/header/attachment content,
// libsodium-compatible anonymous sealed boxes for wrapping the per-message DEK
// to a domain's public key, and the keyed threading HMACs shared with Rails.
//
// Interop contract: the web/desktop clients decrypt with libsodium
// (libsodium-wrappers-sumo). box.SealAnonymous == crypto_box_seal and
// chacha20poly1305.NewX == crypto_aead_xchacha20poly1305_ietf_*, so everything
// produced here opens client-side. Threading HMACs are HMAC-SHA256 under the
// server-side threading key (MX_THREADING_HMAC_KEY here,
// INBOX2_THREADING_HMAC_KEY in Rails) — both sides must derive identical
// values for mixed-mode threading. Subject normalization (the Go port of
// SubjectNormalizer) lands with the Phase-C seal pipeline.
package seal

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/nacl/box"
)

// DEKSize is the length of a per-message data-encryption key.
const DEKSize = chacha20poly1305.KeySize // 32

// GenerateDEK returns a fresh random per-message data-encryption key.
func GenerateDEK() ([]byte, error) {
	dek := make([]byte, DEKSize)
	if _, err := rand.Read(dek); err != nil {
		return nil, fmt.Errorf("generate DEK: %w", err)
	}
	return dek, nil
}

// Encrypt seals plaintext under the DEK with XChaCha20-Poly1305, binding aad
// (see AAD) into the authentication tag. Returns a fresh random nonce and the
// ciphertext (tag appended).
func Encrypt(dek, plaintext, aad []byte) (nonce, ciphertext []byte, err error) {
	aead, err := chacha20poly1305.NewX(dek)
	if err != nil {
		return nil, nil, fmt.Errorf("init aead: %w", err)
	}
	nonce = make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, fmt.Errorf("generate nonce: %w", err)
	}
	return nonce, aead.Seal(nil, nonce, plaintext, aad), nil
}

// Decrypt reverses Encrypt. It fails if the ciphertext or aad was tampered
// with. (The MX only needs this for tests; clients decrypt with libsodium.)
func Decrypt(dek, nonce, ciphertext, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(dek)
	if err != nil {
		return nil, fmt.Errorf("init aead: %w", err)
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}
	return plaintext, nil
}

// SealDEK wraps the DEK to a recipient public key (base64, 32-byte X25519, as
// delivered in DomainInfo.E2EEPublicKey) using a libsodium-compatible
// anonymous sealed box. Only a holder of the matching secret key can unwrap.
func SealDEK(dek []byte, publicKeyB64 string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(publicKeyB64)
	if err != nil {
		return nil, fmt.Errorf("decode public key: %w", err)
	}
	if len(raw) != 32 {
		return nil, fmt.Errorf("public key must be 32 bytes, got %d", len(raw))
	}
	var pk [32]byte
	copy(pk[:], raw)
	sealed, err := box.SealAnonymous(nil, dek, &pk, rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("seal DEK: %w", err)
	}
	return sealed, nil
}

// AAD builds the additional authenticated data binding a sealed blob to its
// domain, key version, and RFC 5322 Message-ID — so a DBA can't graft one
// message's ciphertext onto another row undetected. Format is shared with the
// clients: "domain_id|key_version|message_id".
func AAD(domainID int64, keyVersion int, messageID string) []byte {
	return []byte(fmt.Sprintf("%d|%d|%s", domainID, keyVersion, messageID))
}

// Part roles bound into the AAD of a sealed_box_v2 message.
const (
	RoleHeader = "header"
	RoleBody   = "body"
)

// PartAAD binds a part's role to the message AAD, so a header and a body of
// one message can't stand in for each other.
func PartAAD(aad []byte, role string) []byte {
	return append(append([]byte{}, aad...), "|"+role...)
}

// ThreadingHMAC derives the deterministic threading hash of a Message-ID,
// References entry, or normalized subject: hex HMAC-SHA256 under the shared
// threading key. Deliberately keyed — an unkeyed hash would let anyone confirm
// a guessed Message-ID or subject against the stored columns.
func ThreadingHMAC(key []byte, value string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil))
}

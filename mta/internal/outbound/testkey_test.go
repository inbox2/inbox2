package outbound

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
)

// GenerateTestDKIMKey creates a test RSA key pair for use in tests.
// Returns a PEM-encoded private key. It lives in a _test.go file so it is never
// compiled into the production binary.
func GenerateTestDKIMKey() (privateKeyPEM string, err error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return "", fmt.Errorf("generate key: %w", err)
	}

	privBytes := x509.MarshalPKCS1PrivateKey(key)
	privPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: privBytes,
	})

	return string(privPEM), nil
}

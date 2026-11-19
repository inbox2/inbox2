package outbound

import (
	"bytes"
	"crypto"
	"crypto/x509"
	"encoding/pem"
	"fmt"

	"github.com/emersion/go-msgauth/dkim"
)

// SignedHeaders are the headers included in the DKIM signature.
var SignedHeaders = []string{
	"From",
	"To",
	"Subject",
	"Date",
	"Message-ID",
	"MIME-Version",
	"Content-Type",
	"In-Reply-To",
	"References",
}

// SignMessage adds a DKIM-Signature header to the raw RFC 5322 message.
// Uses relaxed/relaxed canonicalization with rsa-sha256.
func SignMessage(rawMessage []byte, domain, selector, privateKeyPEM string) ([]byte, error) {
	key, err := parsePEMPrivateKey(privateKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse DKIM private key: %w", err)
	}

	opts := &dkim.SignOptions{
		Domain:                 domain,
		Selector:               selector,
		Signer:                 key,
		Hash:                   crypto.SHA256,
		HeaderCanonicalization: dkim.CanonicalizationRelaxed,
		BodyCanonicalization:   dkim.CanonicalizationRelaxed,
		HeaderKeys:             SignedHeaders,
	}

	var signed bytes.Buffer
	if err := dkim.Sign(&signed, bytes.NewReader(rawMessage), opts); err != nil {
		return nil, fmt.Errorf("dkim sign: %w", err)
	}

	return signed.Bytes(), nil
}

func parsePEMPrivateKey(pemData string) (crypto.Signer, error) {
	block, _ := pem.Decode([]byte(pemData))
	if block == nil {
		return nil, fmt.Errorf("no PEM block found")
	}

	// Try PKCS#8 first (modern format)
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err == nil {
		if signer, ok := key.(crypto.Signer); ok {
			return signer, nil
		}
		return nil, fmt.Errorf("PKCS#8 key does not implement crypto.Signer")
	}

	// Fall back to PKCS#1 (RSA-specific format)
	rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err == nil {
		return rsaKey, nil
	}

	return nil, fmt.Errorf("unsupported private key format")
}

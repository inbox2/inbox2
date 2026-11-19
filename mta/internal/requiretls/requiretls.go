// Package requiretls implements REQUIRETLS per RFC 8689 (spec 18.3.4).
//
// REQUIRETLS is an SMTP extension that mandates TLS for message delivery.
// When a message has the REQUIRETLS flag, the receiving MTA must:
// 1. Use TLS for the connection
// 2. Verify the server certificate (DANE or PKIX)
// 3. Reject delivery if TLS cannot be established
package requiretls

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"strings"
)

// Policy represents the REQUIRETLS policy for a message.
type Policy struct {
	Required bool
	// TLSReporting enables TLS-RPT reporting for this message
	TLSReporting bool
}

// SMTPExtension is the REQUIRETLS SMTP extension keyword.
const SMTPExtension = "REQUIRETLS"

// HeaderField is the header that signals REQUIRETLS in the message.
const HeaderField = "TLS-Required"

// HeaderValueYes indicates REQUIRETLS is required.
const HeaderValueYes = "Yes"

// HeaderValueNo indicates REQUIRETLS is not required.
const HeaderValueNo = "No"

// CheckServerSupport verifies that the remote SMTP server advertises REQUIRETLS.
func CheckServerSupport(ehloResponse string) bool {
	for _, line := range strings.Split(ehloResponse, "\n") {
		if strings.TrimSpace(strings.ToUpper(line)) == SMTPExtension {
			return true
		}
	}
	return false
}

// ValidateTLS checks that the TLS connection meets REQUIRETLS requirements:
// - TLS 1.2 or higher
// - Valid certificate chain
// - Matching server name
func ValidateTLS(conn *tls.Conn, expectedHost string) error {
	return ValidateConnectionState(conn.ConnectionState(), expectedHost)
}

// ValidateConnectionState validates an established TLS connection state against
// REQUIRETLS requirements: TLS 1.2+, a certificate chain that verifies against
// the system roots, and a matching server name. Used with net/smtp.
func ValidateConnectionState(state tls.ConnectionState, expectedHost string) error {
	// Must be TLS 1.2+
	if state.Version < tls.VersionTLS12 {
		return fmt.Errorf("REQUIRETLS: TLS version %x below minimum 1.2", state.Version)
	}

	// Must have peer certificates
	if len(state.PeerCertificates) == 0 {
		return fmt.Errorf("REQUIRETLS: no peer certificates presented")
	}

	// Verify the full chain against the system roots and the server name.
	leaf := state.PeerCertificates[0]
	intermediates := x509.NewCertPool()
	for _, c := range state.PeerCertificates[1:] {
		intermediates.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		DNSName:       expectedHost,
		Intermediates: intermediates,
	}); err != nil {
		return fmt.Errorf("REQUIRETLS: certificate verification failed: %w", err)
	}

	return nil
}

// ParseHeader extracts REQUIRETLS policy from message headers.
func ParseHeader(headers map[string]string) Policy {
	val, ok := headers[HeaderField]
	if !ok {
		return Policy{Required: false}
	}
	return Policy{
		Required: strings.EqualFold(strings.TrimSpace(val), HeaderValueYes),
	}
}

// EnforceOrReject determines whether to deliver or reject based on policy and TLS state.
func EnforceOrReject(policy Policy, tlsEstablished bool, tlsValid bool) (deliver bool, err error) {
	if !policy.Required {
		return true, nil
	}

	if !tlsEstablished {
		return false, fmt.Errorf("REQUIRETLS: message requires TLS but connection is not encrypted")
	}

	if !tlsValid {
		return false, fmt.Errorf("REQUIRETLS: message requires TLS but certificate validation failed")
	}

	return true, nil
}

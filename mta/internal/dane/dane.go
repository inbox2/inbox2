// Package dane implements DNS-based Authentication of Named Entities (DANE)
// for SMTP per RFC 7672 (spec 18.3.3).
//
// DANE uses TLSA DNS records to authenticate TLS certificates for mail servers,
// providing certificate verification independent of the CA system.
package dane

import (
	"crypto/sha256"
	"crypto/sha512"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"net"
	"strings"
)

// TLSARecord represents a DNS TLSA record (RFC 6698).
type TLSARecord struct {
	Usage        uint8  // 0=CA, 1=Service, 2=Trust anchor, 3=Domain-issued
	Selector     uint8  // 0=Full cert, 1=SubjectPublicKeyInfo
	MatchingType uint8  // 0=Full, 1=SHA-256, 2=SHA-512
	CertData     string // Hex-encoded certificate data
}

// Usage constants
const (
	UsageCAConstraint uint8 = 0
	UsageServiceCert  uint8 = 1
	UsageTrustAnchor  uint8 = 2
	UsageDomainIssued uint8 = 3
)

// Result holds the outcome of a DANE verification.
type Result struct {
	Verified bool
	Record   *TLSARecord
	Error    error
}

// LookupTLSA queries DNS for TLSA records for the given MX host and port.
// Returns nil if no TLSA records exist (DANE not configured).
func LookupTLSA(host string, port int) ([]TLSARecord, error) {
	name := fmt.Sprintf("_%d._tcp.%s", port, strings.TrimSuffix(host, "."))
	records, err := net.LookupTXT(name)
	if err != nil {
		// No TLSA records — DANE not configured for this host
		return nil, nil
	}

	var tlsa []TLSARecord
	for _, r := range records {
		rec, err := parseTLSA(r)
		if err == nil {
			tlsa = append(tlsa, rec)
		}
	}
	return tlsa, nil
}

// VerifyCertificate checks the peer certificate against TLSA records.
func VerifyCertificate(conn *tls.Conn, records []TLSARecord) Result {
	if len(records) == 0 {
		return Result{Verified: true} // No DANE records = no DANE enforcement
	}
	if conn == nil {
		return Result{Verified: false, Error: fmt.Errorf("no TLS connection")}
	}
	return VerifyConnectionState(conn.ConnectionState(), records)
}

// VerifyConnectionState checks the peer certificate from an established TLS
// connection state against TLSA records. This is the form used with net/smtp,
// which exposes tls.ConnectionState but not the underlying *tls.Conn.
func VerifyConnectionState(state tls.ConnectionState, records []TLSARecord) Result {
	if len(records) == 0 {
		return Result{Verified: true} // No DANE records = no DANE enforcement
	}

	if len(state.PeerCertificates) == 0 {
		return Result{Verified: false, Error: fmt.Errorf("no peer certificates")}
	}

	cert := state.PeerCertificates[0]

	for _, rec := range records {
		rec := rec
		if matchTLSA(cert, rec) {
			return Result{Verified: true, Record: &rec}
		}
	}

	return Result{Verified: false, Error: fmt.Errorf("no TLSA record matched the certificate")}
}

func matchTLSA(cert *x509.Certificate, rec TLSARecord) bool {
	var data []byte
	switch rec.Selector {
	case 0: // Full certificate
		data = cert.Raw
	case 1: // SubjectPublicKeyInfo
		data = cert.RawSubjectPublicKeyInfo
	default:
		return false
	}

	var hash string
	switch rec.MatchingType {
	case 0: // Full match
		hash = hex.EncodeToString(data)
	case 1: // SHA-256
		h := sha256.Sum256(data)
		hash = hex.EncodeToString(h[:])
	case 2: // SHA-512
		h := sha512.Sum512(data)
		hash = hex.EncodeToString(h[:])
	default:
		return false
	}

	return strings.EqualFold(hash, rec.CertData)
}

func parseTLSA(txt string) (TLSARecord, error) {
	parts := strings.Fields(txt)
	if len(parts) < 4 {
		return TLSARecord{}, fmt.Errorf("invalid TLSA record format")
	}

	var usage, selector, matching uint8
	_, err := fmt.Sscanf(parts[0]+" "+parts[1]+" "+parts[2], "%d %d %d", &usage, &selector, &matching)
	if err != nil {
		return TLSARecord{}, err
	}

	return TLSARecord{
		Usage:        usage,
		Selector:     selector,
		MatchingType: matching,
		CertData:     strings.Join(parts[3:], ""),
	}, nil
}

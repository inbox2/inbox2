// Package auth provides email authentication checks (SPF, DKIM, DMARC)
// for the MX inbound receiver.
package auth

import (
	"net"

	"blitiri.com.ar/go/spf"
)

// SPFResult holds the outcome of an SPF check.
type SPFResult struct {
	Result string // "pass", "fail", "softfail", "neutral", "none", "temperror", "permerror"
	Domain string
}

// CheckSPF validates the sending IP against the sender domain's SPF record.
func CheckSPF(clientIP, mailFrom, heloDomain string) SPFResult {
	ip := net.ParseIP(clientIP)
	if ip == nil {
		return SPFResult{Result: "none"}
	}

	// The reported domain is the MAIL FROM domain, falling back to the HELO
	// domain for null-sender (bounce) envelopes.
	domain := heloDomain
	if d := splitAddress(mailFrom); d != "" {
		domain = d
	}

	result, err := spf.CheckHostWithSender(ip, heloDomain, mailFrom)
	if err != nil {
		switch result {
		case spf.TempError:
			return SPFResult{Result: "temperror", Domain: domain}
		case spf.PermError:
			return SPFResult{Result: "permerror", Domain: domain}
		default:
			return SPFResult{Result: "none", Domain: domain}
		}
	}

	return SPFResult{
		Result: spfResultString(result),
		Domain: domain,
	}
}

func spfResultString(r spf.Result) string {
	switch r {
	case spf.Pass:
		return "pass"
	case spf.Fail:
		return "fail"
	case spf.SoftFail:
		return "softfail"
	case spf.Neutral:
		return "neutral"
	case spf.None:
		return "none"
	case spf.TempError:
		return "temperror"
	case spf.PermError:
		return "permerror"
	default:
		return "none"
	}
}

func splitAddress(addr string) string {
	for i := len(addr) - 1; i >= 0; i-- {
		if addr[i] == '@' {
			return addr[i+1:]
		}
	}
	return ""
}

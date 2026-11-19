package auth

import (
	"context"
	"net"
	"strings"
	"time"

	"golang.org/x/net/publicsuffix"
)

// DMARCResult holds the outcome of a DMARC evaluation.
type DMARCResult struct {
	Result string // "pass", "fail", "none", "temperror", "permerror"
	Domain string
	Policy string // "none", "quarantine", "reject"
}

// CheckDMARC evaluates DMARC policy for the RFC5322.From header domain based on
// SPF and DKIM results. Per RFC 7489, DMARC is evaluated against the From header
// domain (not the SMTP envelope sender), and alignment is checked against the
// organizational (registrable) domain.
func CheckDMARC(fromDomain string, spfResult SPFResult, dkimResult DKIMResult) DMARCResult {
	if fromDomain == "" {
		return DMARCResult{Result: "none", Policy: "none"}
	}
	fromDomain = strings.ToLower(strings.TrimSuffix(fromDomain, "."))

	// Discover the applicable policy: try the From domain, then fall back to the
	// organizational domain's record (using its sp= subdomain policy if present).
	policy, found := discoverDMARCPolicy(fromDomain)
	if !found {
		return DMARCResult{Result: "none", Domain: fromDomain, Policy: "none"}
	}

	// Relaxed alignment: the authenticated identifier's organizational domain must
	// match the From organizational domain, and the underlying check must pass.
	spfAligned := spfResult.Result == "pass" && domainAligns(spfResult.Domain, fromDomain)
	dkimAligned := dkimResult.Result == "pass" && domainAligns(dkimResult.Domain, fromDomain)

	if spfAligned || dkimAligned {
		return DMARCResult{Result: "pass", Domain: fromDomain, Policy: policy}
	}
	return DMARCResult{Result: "fail", Domain: fromDomain, Policy: policy}
}

// discoverDMARCPolicy looks up the DMARC record for the domain, falling back to
// the organizational domain (applying its sp= subdomain policy). Returns the
// effective policy and whether any record was found.
func discoverDMARCPolicy(fromDomain string) (string, bool) {
	if rec, ok := lookupDMARCRecord(fromDomain); ok {
		return parseDMARCPolicy(rec), true
	}

	org := orgDomain(fromDomain)
	if org != fromDomain {
		if rec, ok := lookupDMARCRecord(org); ok {
			// A subdomain with no record of its own inherits the org domain's
			// subdomain policy (sp=) when present, else its main policy (p=).
			if sp := parseDMARCSubPolicy(rec); sp != "" {
				return sp, true
			}
			return parseDMARCPolicy(rec), true
		}
	}
	return "", false
}

func lookupDMARCRecord(domain string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resolver := &net.Resolver{}
	records, err := resolver.LookupTXT(ctx, "_dmarc."+domain)
	if err != nil {
		return "", false
	}
	for _, r := range records {
		if strings.HasPrefix(strings.TrimSpace(r), "v=DMARC1") {
			return r, true
		}
	}
	return "", false
}

func parseDMARCPolicy(record string) string {
	return dmarcTag(record, "p")
}

func parseDMARCSubPolicy(record string) string {
	return dmarcTag(record, "sp")
}

// dmarcTag extracts a policy tag ("p" or "sp"), returning "" if absent or
// invalid. The main "p" tag normalizes an invalid/absent value to "none".
func dmarcTag(record, tag string) string {
	for _, part := range strings.Split(record, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) == 2 && strings.TrimSpace(kv[0]) == tag {
			switch strings.TrimSpace(kv[1]) {
			case "none", "quarantine", "reject":
				return strings.TrimSpace(kv[1])
			}
			// Tag present but invalid value.
			if tag == "p" {
				return "none"
			}
			return ""
		}
	}
	if tag == "p" {
		return "none"
	}
	return ""
}

// domainAligns checks relaxed DMARC alignment: the two domains share the same
// organizational (registrable) domain.
func domainAligns(authDomain, fromDomain string) bool {
	authDomain = strings.ToLower(strings.TrimSuffix(authDomain, "."))
	fromDomain = strings.ToLower(strings.TrimSuffix(fromDomain, "."))
	if authDomain == "" || fromDomain == "" {
		return false
	}
	if authDomain == fromDomain {
		return true
	}
	return orgDomain(authDomain) == orgDomain(fromDomain)
}

// orgDomain returns the organizational (registrable) domain using the Public
// Suffix List, e.g. "mail.example.co.uk" → "example.co.uk". Falls back to the
// input when no eTLD+1 can be derived (e.g. the input is itself a public suffix).
func orgDomain(d string) string {
	d = strings.ToLower(strings.TrimSuffix(d, "."))
	org, err := publicsuffix.EffectiveTLDPlusOne(d)
	if err != nil || org == "" {
		return d
	}
	return org
}

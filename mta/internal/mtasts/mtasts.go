// Package mtasts implements outbound MTA-STS enforcement per RFC 8461
// (spec 18.3.1, TODO 46.9).
//
// Before delivering to a recipient domain, the sender asks this store for the
// domain's published policy (DNS TXT discovery + HTTPS policy fetch, cached per
// max_age). In enforce mode, delivery is refused unless the MX host matches a
// policy mx pattern AND the connection is TLS with a PKIX-valid certificate —
// a downgrade (no STARTTLS, bad cert, rogue MX) becomes a transient failure
// instead of a cleartext send.
package mtasts

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Mode is the policy's declared mode.
type Mode string

const (
	ModeEnforce Mode = "enforce"
	ModeTesting Mode = "testing"
	ModeNone    Mode = "none"
)

// Policy is a parsed MTA-STS policy file.
type Policy struct {
	Mode       Mode
	MXPatterns []string
	MaxAge     time.Duration
}

// Enforce reports whether delivery must be refused on TLS/MX mismatch.
func (p *Policy) Enforce() bool { return p != nil && p.Mode == ModeEnforce }

// MXMatches reports whether an MX host is allowed by the policy's mx patterns.
// A leading "*." wildcard matches exactly one leftmost label (RFC 8461 §4.1).
func (p *Policy) MXMatches(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	for _, pat := range p.MXPatterns {
		pat = strings.ToLower(pat)
		if strings.HasPrefix(pat, "*.") {
			suffix := pat[1:] // ".example.com"
			if strings.HasSuffix(h, suffix) && !strings.Contains(strings.TrimSuffix(h, suffix), ".") && h != suffix[1:] {
				return true
			}
		} else if h == pat {
			return true
		}
	}
	return false
}

const (
	fetchTimeout = 10 * time.Second
	maxPolicySize = 64 * 1024
	// negativeTTL caches "no policy published" so the common case (most
	// domains have no MTA-STS) costs one TXT lookup per domain per window.
	negativeTTL = 10 * time.Minute
	minTTL      = time.Minute
	maxTTL      = 24 * time.Hour // re-check daily even for year-long max_age
)

type cacheEntry struct {
	policy  *Policy // nil = no policy published
	expires time.Time
}

// Store fetches and caches MTA-STS policies per recipient domain.
type Store struct {
	mu      sync.Mutex
	entries map[string]cacheEntry

	// Injectable for tests.
	lookupTXT func(name string) ([]string, error)
	policyURL func(domain string) string
	client    *http.Client
}

// NewStore returns a Store using live DNS + HTTPS.
func NewStore() *Store {
	return &Store{
		entries:   make(map[string]cacheEntry),
		lookupTXT: net.LookupTXT,
		policyURL: func(domain string) string {
			return fmt.Sprintf("https://mta-sts.%s/.well-known/mta-sts.txt", domain)
		},
		client: &http.Client{
			Timeout: fetchTimeout,
			// RFC 8461 §3.3: the policy host must not redirect.
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return fmt.Errorf("mta-sts: redirects not allowed")
			},
		},
	}
}

// Get returns the active policy for a recipient domain, or nil when the domain
// publishes none (or the policy is unfetchable and nothing usable is cached).
func (s *Store) Get(domain string) *Policy {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))

	s.mu.Lock()
	entry, ok := s.entries[domain]
	s.mu.Unlock()
	if ok && time.Now().Before(entry.expires) {
		return entry.policy
	}

	policy, err := s.fetch(domain)
	if err != nil {
		// Fetch trouble: keep serving a stale cached policy if we have one
		// (RFC 8461 §3.4 — existing policies stay in effect), else treat as
		// no-policy for a short window.
		if ok && entry.policy != nil {
			s.put(domain, entry.policy, entry.policy.MaxAge)
			return entry.policy
		}
		s.put(domain, nil, negativeTTL)
		return nil
	}
	if policy == nil {
		s.put(domain, nil, negativeTTL)
		return nil
	}
	s.put(domain, policy, policy.MaxAge)
	return policy
}

func (s *Store) put(domain string, p *Policy, ttl time.Duration) {
	if ttl < minTTL {
		ttl = minTTL
	}
	if ttl > maxTTL {
		ttl = maxTTL
	}
	s.mu.Lock()
	s.entries[domain] = cacheEntry{policy: p, expires: time.Now().Add(ttl)}
	s.mu.Unlock()
}

// fetch discovers (TXT) and downloads (HTTPS) the domain's policy.
// Returns (nil, nil) when the domain publishes no policy.
func (s *Store) fetch(domain string) (*Policy, error) {
	txts, err := s.lookupTXT("_mta-sts." + domain)
	if err != nil {
		// NXDOMAIN and lookup errors are indistinguishable across platforms
		// here; both mean "no usable STS record right now".
		return nil, nil //nolint:nilerr — absence of the TXT record is the no-policy case
	}
	found := false
	for _, txt := range txts {
		if strings.HasPrefix(strings.TrimSpace(txt), "v=STSv1") {
			found = true
			break
		}
	}
	if !found {
		return nil, nil
	}

	resp, err := s.client.Get(s.policyURL(domain))
	if err != nil {
		return nil, fmt.Errorf("policy fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("policy fetch: HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxPolicySize))
	if err != nil {
		return nil, fmt.Errorf("policy read: %w", err)
	}
	return ParsePolicy(string(body))
}

// ParsePolicy parses an mta-sts.txt policy file (RFC 8461 §3.2).
func ParsePolicy(text string) (*Policy, error) {
	p := &Policy{MaxAge: 24 * time.Hour}
	version := ""
	for _, line := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		switch key {
		case "version":
			version = value
		case "mode":
			p.Mode = Mode(value)
		case "mx":
			p.MXPatterns = append(p.MXPatterns, value)
		case "max_age":
			if secs, err := strconv.Atoi(value); err == nil {
				p.MaxAge = time.Duration(secs) * time.Second
			}
		}
	}
	if version != "STSv1" {
		return nil, fmt.Errorf("mta-sts: unsupported policy version %q", version)
	}
	switch p.Mode {
	case ModeEnforce, ModeTesting, ModeNone:
	default:
		return nil, fmt.Errorf("mta-sts: invalid mode %q", p.Mode)
	}
	if p.Mode == ModeEnforce && len(p.MXPatterns) == 0 {
		return nil, fmt.Errorf("mta-sts: enforce policy without mx patterns")
	}
	return p, nil
}

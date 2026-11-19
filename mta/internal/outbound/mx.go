package outbound

import (
	"context"
	"fmt"
	"net"
	"sort"
	"sync"
	"time"
)

const mxCacheTTL = 5 * time.Minute

// MXRecord holds a single MX record from DNS.
type MXRecord struct {
	Host string
	Pref uint16
}

type cachedMX struct {
	records   []MXRecord
	expiresAt time.Time
}

// MXResolver looks up and caches MX records for recipient domains.
type MXResolver struct {
	mu      sync.RWMutex
	entries map[string]cachedMX
}

// NewMXResolver creates a new MX resolver with an empty cache.
func NewMXResolver() *MXResolver {
	return &MXResolver{
		entries: make(map[string]cachedMX),
	}
}

// Lookup returns the MX records for the given domain, sorted by preference.
// Falls back to the domain itself if no MX records exist (RFC 5321 section 5.1).
func (r *MXResolver) Lookup(domain string) ([]MXRecord, error) {
	// Check cache
	r.mu.RLock()
	if entry, ok := r.entries[domain]; ok && time.Now().Before(entry.expiresAt) {
		r.mu.RUnlock()
		return entry.records, nil
	}
	r.mu.RUnlock()

	// DNS lookup
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	resolver := &net.Resolver{}
	mxRecords, err := resolver.LookupMX(ctx, domain)
	if err != nil {
		// No MX records — fallback to A/AAAA (RFC 5321 section 5.1)
		// First check if the domain resolves at all
		addrs, lookupErr := resolver.LookupHost(ctx, domain)
		if lookupErr != nil || len(addrs) == 0 {
			return nil, fmt.Errorf("no MX or A/AAAA records for %s: %w", domain, err)
		}
		records := []MXRecord{{Host: domain, Pref: 0}}
		r.cache(domain, records)
		return records, nil
	}

	if len(mxRecords) == 0 {
		// Empty MX list — fallback to domain itself
		records := []MXRecord{{Host: domain, Pref: 0}}
		r.cache(domain, records)
		return records, nil
	}

	records := make([]MXRecord, len(mxRecords))
	for i, mx := range mxRecords {
		records[i] = MXRecord{
			Host: mx.Host,
			Pref: mx.Pref,
		}
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].Pref < records[j].Pref
	})

	r.cache(domain, records)
	return records, nil
}

func (r *MXResolver) cache(domain string, records []MXRecord) {
	r.mu.Lock()
	r.entries[domain] = cachedMX{
		records:   records,
		expiresAt: time.Now().Add(mxCacheTTL),
	}
	r.mu.Unlock()
}

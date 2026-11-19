// Package smtpd implements the SMTP server for inbound mail reception.
package smtpd

import (
	"sync"
	"time"

	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/queue"
)

const (
	// positiveCacheTTL caches a verified, deliverable domain.
	positiveCacheTTL = 5 * time.Minute
	// negativeCacheTTL caches not-found / not-yet-verified results for a much
	// shorter window so a newly added or freshly verified domain starts
	// accepting mail quickly (and so RCPT-flood probing churns out fast).
	negativeCacheTTL = 30 * time.Second
	// maxCacheEntries bounds memory: a flood of RCPTs to unique random domains
	// cannot grow the cache without limit.
	maxCacheEntries = 50000
)

type cachedDomain struct {
	info      *queue.DomainInfo
	expiresAt time.Time
}

// DomainCache provides a TTL-based, size-bounded cache for domain lookups to
// avoid hitting NATS on every RCPT TO command.
type DomainCache struct {
	mu      sync.RWMutex
	entries map[string]cachedDomain
	lookup  func(domain string) (*queue.DomainInfo, error)
	log     *mxlog.Logger
}

// NewDomainCache creates a cache backed by the given lookup function.
func NewDomainCache(lookup func(string) (*queue.DomainInfo, error), logger *mxlog.Logger) *DomainCache {
	return &DomainCache{
		entries: make(map[string]cachedDomain),
		lookup:  lookup,
		log:     logger,
	}
}

// Get returns the DomainInfo for the given domain, consulting the cache first.
func (c *DomainCache) Get(domain string) (*queue.DomainInfo, error) {
	c.mu.RLock()
	if entry, ok := c.entries[domain]; ok && time.Now().Before(entry.expiresAt) {
		info := entry.info
		c.mu.RUnlock()
		c.log.DomainLookup(domain, info.Found, info.OrgKey, info.Status, true, 0)
		return info, nil
	}
	c.mu.RUnlock()

	start := time.Now()
	info, err := c.lookup(domain)
	elapsed := time.Since(start)

	if err != nil {
		c.log.DomainLookupError(domain, err)
		return nil, err
	}

	c.store(domain, info)
	c.log.DomainLookup(domain, info.Found, info.OrgKey, info.Status, false, mxlog.DurationMs(elapsed))
	return info, nil
}

// store caches a lookup result with a TTL chosen by deliverability, bounding the
// total number of entries.
func (c *DomainCache) store(domain string, info *queue.DomainInfo) {
	ttl := negativeCacheTTL
	if info.Found && (info.Status == "verified" || info.Status == "receiving_mail") {
		ttl = positiveCacheTTL
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.entries) >= maxCacheEntries {
		c.evictExpiredLocked()
		// If sweeping expired entries didn't free space, drop one arbitrary
		// entry so the map stays bounded under sustained pressure.
		if len(c.entries) >= maxCacheEntries {
			for k := range c.entries {
				delete(c.entries, k)
				break
			}
		}
	}

	c.entries[domain] = cachedDomain{
		info:      info,
		expiresAt: time.Now().Add(ttl),
	}
}

// evictExpiredLocked removes all expired entries. Caller must hold c.mu.
func (c *DomainCache) evictExpiredLocked() {
	now := time.Now()
	for k, v := range c.entries {
		if now.After(v.expiresAt) {
			delete(c.entries, k)
		}
	}
}

// Invalidate removes a domain from the cache.
func (c *DomainCache) Invalidate(domain string) {
	c.mu.Lock()
	delete(c.entries, domain)
	c.mu.Unlock()
}

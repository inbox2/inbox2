package smtpd

import (
	"fmt"
	"net"
	"strings"
	"time"
)

// Edge spam defense (TODO 46.13): refuse abusive traffic at SMTP time instead
// of scoring it after acceptance. Three independent brakes, all in-memory
// (reset on restart — fine for abuse ceilings, same trade as the RCPT budget):
//
//   - DNSBL (RBL): reject clients listed on configured zones (554 at session
//     open). Zones are opt-in via MX_RBL_ZONES — most public RBLs refuse
//     queries via shared resolvers, so listing them by default would silently
//     no-op or, worse, false-positive.
//   - Connection rate: cap NEW connections per IP per window (on top of the
//     existing concurrent-connection cap) — 421 when exceeded.
//   - Greylisting: first-contact (net, from, rcpt) triples from clients with
//     no PTR record get 451; a retry after the delay passes. Real MTAs retry,
//     drive-by spam cannon fodder doesn't. PTR-gated so well-run senders are
//     never delayed.

// rblResult caches one IP's DNSBL verdict.
type rblResult struct {
	listed  bool
	zone    string
	expires time.Time
}

// greyEntry tracks one (net, from, rcpt) triple.
type greyEntry struct {
	firstSeen time.Time
	allowed   bool
	expires   time.Time
}

// connRateWindow is a fixed-window new-connection counter for one client IP.
// ponytail: fixed window, same trade as rcptFailWindow — up to 2× budget on a
// boundary-straddling burst.
type connRateWindow struct {
	start time.Time
	count int
}

const (
	rblCacheTTL      = 30 * time.Minute
	ptrCacheTTL      = time.Hour
	greylistDelay    = 2 * time.Minute
	greylistUnseen   = 24 * time.Hour  // a triple that never retries expires
	greylistApproved = 7 * 24 * time.Hour
)

// edgeState carries the edge-defense caches. Embedded in Backend.
type edgeState struct {
	rblCache  map[string]rblResult
	ptrCache  map[string]struct {
		has     bool
		expires time.Time
	}
	greylist      map[string]*greyEntry
	connRates     map[string]*connRateWindow
	lastGreySweep time.Time

	// Injectable DNS for tests.
	lookupHost func(host string) ([]string, error)
	lookupAddr func(addr string) ([]string, error)
}

func newEdgeState() edgeState {
	return edgeState{
		rblCache: make(map[string]rblResult),
		ptrCache: make(map[string]struct {
			has     bool
			expires time.Time
		}),
		greylist:   make(map[string]*greyEntry),
		connRates:  make(map[string]*connRateWindow),
		lookupHost: net.LookupHost,
		lookupAddr: net.LookupAddr,
	}
}

// rblListed reports whether ip is listed on any configured DNSBL zone.
// Lookup errors (including NXDOMAIN = not listed) fail open.
func (b *Backend) rblListed(ip string) (bool, string) {
	if len(b.config.RBLZones) == 0 || ip == "" {
		return false, ""
	}
	b.limitMu.Lock()
	cached, ok := b.edge.rblCache[ip]
	b.limitMu.Unlock()
	if ok && time.Now().Before(cached.expires) {
		return cached.listed, cached.zone
	}

	listed, zone := false, ""
	if rev := reverseIP(ip); rev != "" {
		for _, z := range b.config.RBLZones {
			if addrs, err := b.edge.lookupHost(rev + "." + z); err == nil && len(addrs) > 0 {
				// DNSBL convention: any 127.0.0.x answer means listed.
				listed, zone = true, z
				break
			}
		}
	}
	b.limitMu.Lock()
	b.edge.rblCache[ip] = rblResult{listed: listed, zone: zone, expires: time.Now().Add(rblCacheTTL)}
	b.limitMu.Unlock()
	return listed, zone
}

// reverseIP renders an IP in DNSBL query order: dotted-quad reversed for v4,
// reversed nibbles for v6. Empty for unparseable input.
func reverseIP(ip string) string {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return ""
	}
	if v4 := parsed.To4(); v4 != nil {
		return fmt.Sprintf("%d.%d.%d.%d", v4[3], v4[2], v4[1], v4[0])
	}
	v6 := parsed.To16()
	nibbles := make([]string, 0, 32)
	for i := len(v6) - 1; i >= 0; i-- {
		nibbles = append(nibbles, fmt.Sprintf("%x", v6[i]&0xf), fmt.Sprintf("%x", v6[i]>>4))
	}
	return strings.Join(nibbles, ".")
}

// connRateExceeded counts one new connection against ip's window and reports
// whether the budget is blown.
func (b *Backend) connRateExceeded(ip string) bool {
	if b.config.ConnRateLimit <= 0 || ip == "" {
		return false
	}
	now := time.Now()
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	w := b.edge.connRates[ip]
	if w == nil || now.Sub(w.start) >= b.config.ConnRateWindow {
		b.edge.connRates[ip] = &connRateWindow{start: now, count: 1}
		return false
	}
	w.count++
	return w.count > b.config.ConnRateLimit
}

// hasPTR reports whether the client IP has any reverse-DNS record (cached).
func (b *Backend) hasPTR(ip string) bool {
	b.limitMu.Lock()
	cached, ok := b.edge.ptrCache[ip]
	b.limitMu.Unlock()
	if ok && time.Now().Before(cached.expires) {
		return cached.has
	}
	names, err := b.edge.lookupAddr(ip)
	has := err == nil && len(names) > 0
	b.limitMu.Lock()
	b.edge.ptrCache[ip] = struct {
		has     bool
		expires time.Time
	}{has: has, expires: time.Now().Add(ptrCacheTTL)}
	b.limitMu.Unlock()
	return has
}

// greylisted applies greylisting to one (client net, from, rcpt) triple and
// reports whether this attempt must be tempfailed. Only clients WITHOUT a PTR
// record are subjected — a resolvable sender is a real mail system and gets
// through first try.
func (b *Backend) greylisted(ip, from, rcpt string) bool {
	if !b.config.GreylistEnabled || ip == "" {
		return false
	}
	if b.hasPTR(ip) {
		return false
	}

	key := greylistKey(ip, from, rcpt)
	now := time.Now()
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	b.sweepGreylistLocked(now)

	e := b.edge.greylist[key]
	if e == nil || now.After(e.expires) {
		b.edge.greylist[key] = &greyEntry{firstSeen: now, expires: now.Add(greylistUnseen)}
		return true
	}
	if e.allowed {
		return false
	}
	if now.Sub(e.firstSeen) >= greylistDelay {
		e.allowed = true
		e.expires = now.Add(greylistApproved)
		return false
	}
	return true // retried too fast — still inside the delay
}

// greylistKey buckets IPv4 clients by /24 and IPv6 by /64 so an MTA pool
// retrying from a sibling address still matches its triple.
func greylistKey(ip, from, rcpt string) string {
	network := ip
	if parsed := net.ParseIP(ip); parsed != nil {
		if v4 := parsed.To4(); v4 != nil {
			network = fmt.Sprintf("%d.%d.%d.0/24", v4[0], v4[1], v4[2])
		} else {
			network = parsed.Mask(net.CIDRMask(64, 128)).String() + "/64"
		}
	}
	return network + "|" + strings.ToLower(from) + "|" + strings.ToLower(rcpt)
}

// sweepGreylistLocked drops expired triples, at most once per delay period.
// Caller holds limitMu.
func (b *Backend) sweepGreylistLocked(now time.Time) {
	if now.Sub(b.edge.lastGreySweep) < greylistUnseen/24 { // ~hourly
		return
	}
	b.edge.lastGreySweep = now
	for k, e := range b.edge.greylist {
		if now.After(e.expires) {
			delete(b.edge.greylist, k)
		}
	}
}

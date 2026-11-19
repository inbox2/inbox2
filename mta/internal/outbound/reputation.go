package outbound

import (
	"fmt"
	"net"
	"sync"
	"time"
)

// IP-reputation guardrails (TODO 46.11). Three pieces:
//
//   - CheckPTR: startup self-check that our sending IP has forward-confirmed
//     reverse DNS matching the EHLO domain — the #1 reason big providers
//     junk/refuse mail from a fresh IP. Log-only (DNS can't be fixed from
//     here), but loud.
//   - Warmup: a global daily send budget that ramps over the first days of a
//     new IP's life. Checked BEFORE fetching a job so no message sits un-acked
//     while we wait out the budget (AckWait would redeliver it → double-send).
//   - Per-recipient-domain throttle: bounded concurrency + a fixed send-rate
//     window per destination domain, so a burst to one provider (the classic
//     "500 mails to gmail.com") is smeared out instead of tripping their
//     rate defenses.

// warmupSchedule is the daily send cap by day-since-warmup-start: a four-week
// ramp, shared by inbox2's own mail and the relay (relay.go). Past the last
// entry the IP is considered warmed and the cap lifts.
// ponytail: fixed table, and the counters live in memory, so a restart (every
// deploy) hands out the day's budget again. Keep them in a NATS KV bucket if
// deploys during a warm-up start to matter.
var warmupSchedule = []int{
	50, 50, 100, 100, 150, 200, 200,
	300, 400, 500, 600, 800, 1000, 1000,
	1500, 2000, 2500, 3000, 4000, 5000, 5000,
	7500, 10000, 12500, 15000, 20000, 25000, 25000,
}

// relayCustomerShare: one relay customer may use this fraction (1/n) of the
// day's warm-up budget, so a single customer cannot spend the whole IP.
const relayCustomerShare = 4

// Throttle owns the outbound pacing state shared by all workers.
type Throttle struct {
	mu   sync.Mutex
	cond *sync.Cond

	// Per-domain limits.
	domainConcurrency int           // max in-flight deliveries per recipient domain
	domainRate        int           // max sends per domain per window
	domainWindow      time.Duration // rate window length
	inflight          map[string]int
	windows           map[string]*rateWindow

	// Warmup.
	warmupStart time.Time // zero = warmup disabled
	sentToday   int
	today       string         // YYYY-MM-DD the counters belong to
	relayToday  map[string]int // relay sends per customer today
}

type rateWindow struct {
	start time.Time
	count int
}

// NewThrottle builds a Throttle with the given per-domain limits. warmupStart
// zero disables the warmup budget.
func NewThrottle(domainConcurrency, domainRate int, domainWindow time.Duration, warmupStart time.Time) *Throttle {
	t := &Throttle{
		domainConcurrency: domainConcurrency,
		domainRate:        domainRate,
		domainWindow:      domainWindow,
		inflight:          make(map[string]int),
		windows:           make(map[string]*rateWindow),
		warmupStart:       warmupStart,
	}
	t.cond = sync.NewCond(&t.mu)
	return t
}

// WarmupBudgetLeft reports whether today's warmup budget allows another send.
// Call BEFORE fetching a job; when false the worker should sleep and re-check.
func (t *Throttle) WarmupBudgetLeft(now time.Time) bool {
	if t.warmupStart.IsZero() {
		return true
	}
	day := int(now.Sub(t.warmupStart).Hours() / 24)
	if day < 0 {
		day = 0
	}
	if day >= len(warmupSchedule) {
		return true // warmed up
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.rollDayLocked(now)
	return t.sentToday < warmupSchedule[day]
}

// CountSend records one delivery attempt against today's warmup budget.
func (t *Throttle) CountSend(now time.Time) {
	if t.warmupStart.IsZero() {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.rollDayLocked(now)
	t.sentToday++
}

// ReserveRelay takes one send from today's warm-up budget for a relay
// customer. It returns "" when the send may go ahead, else the reason for the
// 451. Once the warm-up has run its course there are no caps. With no warm-up
// start set the relay takes nothing: an IP that was never warmed must not
// carry a customer's volume uncapped.
func (t *Throttle) ReserveRelay(customer string, now time.Time) string {
	if t.warmupStart.IsZero() {
		return "relay is not open yet (no warm-up start date)"
	}
	day := max(int(now.Sub(t.warmupStart).Hours()/24), 0)
	if day >= len(warmupSchedule) {
		return ""
	}
	budget := warmupSchedule[day]
	t.mu.Lock()
	defer t.mu.Unlock()
	t.rollDayLocked(now)
	if t.sentToday >= budget {
		return "daily warm-up cap reached"
	}
	if t.relayToday[customer] >= max(budget/relayCustomerShare, 1) {
		return "daily cap for this sender domain reached"
	}
	if t.relayToday == nil {
		t.relayToday = make(map[string]int)
	}
	t.relayToday[customer]++
	t.sentToday++
	return ""
}

func (t *Throttle) rollDayLocked(now time.Time) {
	d := now.UTC().Format("2006-01-02")
	if d != t.today {
		t.today = d
		t.sentToday = 0
		t.relayToday = nil
	}
}

// AcquireDomain blocks until the recipient domain has a free concurrency slot
// AND rate-window budget, or the deadline passes. Returns false on timeout —
// the caller should transient-fail so Rails reschedules with backoff.
func (t *Throttle) AcquireDomain(domain string, deadline time.Duration) bool {
	if t.domainConcurrency <= 0 && t.domainRate <= 0 {
		return true
	}
	timeout := time.AfterFunc(deadline, func() { t.cond.Broadcast() })
	defer timeout.Stop()
	limit := time.Now().Add(deadline)

	t.mu.Lock()
	defer t.mu.Unlock()
	for {
		now := time.Now()
		if t.tryAcquireLocked(domain, now) {
			return true
		}
		if now.After(limit) {
			return false
		}
		// Wake on a slot release or on a periodic tick (rate windows expire by
		// time, not by an event — re-check every second).
		tick := time.AfterFunc(time.Second, func() { t.cond.Broadcast() })
		t.cond.Wait()
		tick.Stop()
	}
}

func (t *Throttle) tryAcquireLocked(domain string, now time.Time) bool {
	if t.domainConcurrency > 0 && t.inflight[domain] >= t.domainConcurrency {
		return false
	}
	if t.domainRate > 0 {
		w := t.windows[domain]
		if w == nil || now.Sub(w.start) >= t.domainWindow {
			t.windows[domain] = &rateWindow{start: now, count: 1}
		} else if w.count >= t.domainRate {
			return false
		} else {
			w.count++
		}
		t.sweepWindowsLocked(now)
	}
	t.inflight[domain]++
	return true
}

// ReleaseDomain frees the concurrency slot taken by AcquireDomain.
func (t *Throttle) ReleaseDomain(domain string) {
	if t.domainConcurrency <= 0 && t.domainRate <= 0 {
		return
	}
	t.mu.Lock()
	if t.inflight[domain] <= 1 {
		delete(t.inflight, domain)
	} else {
		t.inflight[domain]--
	}
	t.mu.Unlock()
	t.cond.Broadcast()
}

// sweepWindowsLocked drops expired rate windows so the map stays bounded by
// one window's worth of active destinations. Caller holds mu.
func (t *Throttle) sweepWindowsLocked(now time.Time) {
	if len(t.windows) < 4096 {
		return
	}
	for d, w := range t.windows {
		if now.Sub(w.start) >= t.domainWindow {
			delete(t.windows, d)
		}
	}
}

// RecipientDomain exposes recipient-domain extraction for the worker loop's
// per-domain throttle key.
func RecipientDomain(rcptTo []string) string {
	return extractRecipientDomain(rcptTo)
}

// ThrottledResult is the transient failure reported when a job couldn't take
// a per-domain pacing slot in time — Rails reschedules it with backoff.
func ThrottledResult(msg *OutboundMessage) *DeliveryResult {
	return &DeliveryResult{
		Version:           1,
		DeliveryStatusKey: msg.DeliveryStatusKey,
		MessageKey:        msg.MessageKey,
		Result:            "transient_failure",
		ResponseMessage:   "locally throttled (per-domain pacing), retry later",
		AttemptNumber:     1,
		DeliveredAt:       time.Now().UTC(),
	}
}

// CheckPTR verifies forward-confirmed reverse DNS for the sending IP and that
// the PTR name matches the EHLO domain. Returns a human-readable problem list
// (empty = healthy). Log-only by design.
func CheckPTR(publicIP, ehloDomain string) []string {
	var problems []string
	names, err := net.LookupAddr(publicIP)
	if err != nil || len(names) == 0 {
		return []string{fmt.Sprintf("no PTR record for %s — most providers will junk or refuse this IP's mail", publicIP)}
	}

	ptrMatchesEhlo := false
	forwardConfirmed := false
	for _, name := range names {
		host := name[:len(name)-1] // strip trailing dot
		if host == ehloDomain {
			ptrMatchesEhlo = true
		}
		if addrs, err := net.LookupHost(host); err == nil {
			for _, a := range addrs {
				if a == publicIP {
					forwardConfirmed = true
				}
			}
		}
	}
	if !forwardConfirmed {
		problems = append(problems, fmt.Sprintf("PTR %v does not resolve back to %s (no FCrDNS)", names, publicIP))
	}
	if !ptrMatchesEhlo {
		problems = append(problems, fmt.Sprintf("PTR %v does not match EHLO domain %s", names, ehloDomain))
	}
	return problems
}

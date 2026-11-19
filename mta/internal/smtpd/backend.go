package smtpd

import (
	"crypto/tls"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/emersion/go-smtp"
	"github.com/inbox2/mta/internal/metrics"
	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/spool"
	"golang.org/x/net/netutil"
)

// Config holds the MX server configuration.
type Config struct {
	ListenAddr     string
	Domain         string // Server hostname for EHLO banner
	TLSCertFile    string
	TLSKeyFile     string
	MaxRecipients  int
	MaxConnections int // Max concurrent SMTP connections (0 = unlimited)
	MaxConnsPerIP  int // Max concurrent SMTP connections per client IP (0 = unlimited)
	// RcptFailLimit / RcptFailWindow: per-IP RCPT-failure budget. After
	// RcptFailLimit rejected RCPTs within one window, further RCPTs from that
	// IP get 451 until the window rolls over (directory-harvest brake).
	// RcptFailLimit 0 = unlimited.
	RcptFailLimit  int
	RcptFailWindow time.Duration
	ReadTimeout    time.Duration
	WriteTimeout   time.Duration
	MaxMessageSize int64 // Advertised SIZE (bytes), defaults to 100MB
	// ThreadingHMACKey keys the threading HMACs (msgid/refs/subject) computed at
	// seal time for E2EE domains (docs/E2EE.md). Shared with Rails via
	// INBOX2_THREADING_HMAC_KEY so both sides derive identical values. Empty ⇒
	// sealing is unavailable and E2EE domains fall back to plaintext.
	ThreadingHMACKey []byte
	// RspamdURL enables MX-inline spam scoring for sealed mail (Rails can't
	// score a sealed row — no raw MIME server-side). Empty ⇒ no verdict.
	RspamdURL string
	// SpoolDir is the durable staging directory for sealed attachment
	// ciphertext awaiting upload to object storage. Empty ⇒ attachments on
	// sealed mail are stripped (never stored plaintext), loudly logged.
	SpoolDir string
	// Edge spam defense (edge.go). RBLZones lists DNSBL zones to reject
	// against (empty = disabled — public RBLs refuse shared-resolver queries,
	// so this must be a deliberate ops choice). ConnRateLimit caps NEW
	// connections per IP per ConnRateWindow (0 = unlimited). GreylistEnabled
	// tempfails first-contact triples from PTR-less clients.
	RBLZones        []string
	ConnRateLimit   int
	ConnRateWindow  time.Duration
	GreylistEnabled bool
}

// DefaultConfig returns sensible defaults for local development.
func DefaultConfig() Config {
	return Config{
		ListenAddr:     ":4025",
		Domain:         "mx.inbox2.local",
		MaxRecipients:  100,
		MaxConnections: 1024, // bound memory: each in-flight message holds several × its size
		MaxConnsPerIP:  16,   // one abusive IP can't eat the global connection budget
		RcptFailLimit:  20,
		RcptFailWindow: 10 * time.Minute,
		ReadTimeout:    5 * time.Minute,
		WriteTimeout:   5 * time.Minute,
		MaxMessageSize: 100 * 1024 * 1024, // 100MB (largest plan limit)
		ConnRateLimit:   60, // new connections per IP per window
		ConnRateWindow:  10 * time.Minute,
		GreylistEnabled: true,
	}
}

// Authenticator runs SPF/DKIM/DMARC checks. Injectable for testing.
// fromHeaderDomain is the RFC5322.From header domain used for DMARC evaluation.
type Authenticator interface {
	Check(clientIP, mailFrom, heloDomain, fromHeaderDomain string, rawMessage []byte) queue.AuthenticationResults
}

// Backend implements smtp.Backend for the MX inbound receiver.
type Backend struct {
	config    Config
	publisher *queue.Publisher
	domains   *DomainCache
	auth      Authenticator
	log       *mxlog.Logger
	sealer    *sealer
	rspamd    *rspamdClient

	// Per-IP abuse limits (internet-facing port 25). In-memory only — resets
	// on restart, which is fine for an abuse brake.
	// ponytail: one mutex + plain maps; shard if lock contention ever shows.
	limitMu    sync.Mutex
	connsPerIP map[string]int
	rcptFails  map[string]*rcptFailWindow
	lastSweep  time.Time
	// Edge spam defense caches (RBL/greylist/conn-rate — edge.go), guarded by
	// the same limitMu.
	edge edgeState
}

// rcptFailWindow is a fixed-window RCPT-failure counter for one client IP.
// ponytail: fixed window, not sliding — a burst straddling the boundary can
// get up to 2× the budget; acceptable for an abuse ceiling.
type rcptFailWindow struct {
	start time.Time
	count int
}

// acquireConn reserves a per-IP connection slot; false means the IP is at cap.
func (b *Backend) acquireConn(ip string) bool {
	if b.config.MaxConnsPerIP <= 0 || ip == "" {
		return true
	}
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	if b.connsPerIP[ip] >= b.config.MaxConnsPerIP {
		return false
	}
	b.connsPerIP[ip]++
	return true
}

// releaseConn frees the slot taken by acquireConn (called from Session.Logout).
func (b *Backend) releaseConn(ip string) {
	if b.config.MaxConnsPerIP <= 0 || ip == "" {
		return
	}
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	if b.connsPerIP[ip] <= 1 {
		delete(b.connsPerIP, ip) // keys self-clean at zero — no sweep needed
	} else {
		b.connsPerIP[ip]--
	}
}

// rcptBudgetExhausted reports whether ip has burned its RCPT-failure budget
// for the current window.
func (b *Backend) rcptBudgetExhausted(ip string) bool {
	if b.config.RcptFailLimit <= 0 || ip == "" {
		return false
	}
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	w := b.rcptFails[ip]
	if w == nil || time.Since(w.start) >= b.config.RcptFailWindow {
		return false
	}
	return w.count >= b.config.RcptFailLimit
}

// recordRcptFailure counts one rejected RCPT against ip's current window.
func (b *Backend) recordRcptFailure(ip string) {
	if b.config.RcptFailLimit <= 0 || ip == "" {
		return
	}
	now := time.Now()
	b.limitMu.Lock()
	defer b.limitMu.Unlock()
	b.sweepLocked(now)
	w := b.rcptFails[ip]
	if w == nil || now.Sub(w.start) >= b.config.RcptFailWindow {
		b.rcptFails[ip] = &rcptFailWindow{start: now, count: 1}
		return
	}
	w.count++
}

// sweepLocked drops expired failure windows, at most once per window period.
// Lazy — piggybacks on traffic, so the map is bounded by one window's worth
// of failing IPs. Caller holds limitMu.
func (b *Backend) sweepLocked(now time.Time) {
	if now.Sub(b.lastSweep) < b.config.RcptFailWindow {
		return
	}
	b.lastSweep = now
	for ip, w := range b.rcptFails {
		if now.Sub(w.start) >= b.config.RcptFailWindow {
			delete(b.rcptFails, ip)
		}
	}
}

// NewBackend creates an SMTP backend connected to NATS for domain lookups and publishing.
func NewBackend(cfg Config, pub *queue.Publisher, logger *mxlog.Logger) *Backend {
	b := &Backend{
		config:     cfg,
		publisher:  pub,
		auth:       &defaultAuthenticator{},
		log:        logger,
		sealer:     &sealer{hmacKey: cfg.ThreadingHMACKey},
		rspamd:     newRspamdClient(cfg.RspamdURL),
		connsPerIP: make(map[string]int),
		rcptFails:  make(map[string]*rcptFailWindow),
		edge:       newEdgeState(),
	}
	b.domains = NewDomainCache(pub.LookupDomain, logger)
	return b
}

// SetSealSpool attaches the sealed-attachment spool + uploader kick (wired in
// main once S3 config is known).
func (b *Backend) SetSealSpool(store *spool.Store, kick func()) {
	b.sealer.store = store
	b.sealer.kick = kick
}

// SetAuthenticator overrides the default authenticator (for testing).
func (b *Backend) SetAuthenticator(a Authenticator) {
	b.auth = a
}

// NewSession is called for each new SMTP connection.
func (b *Backend) NewSession(conn *smtp.Conn) (smtp.Session, error) {
	clientIP := ""
	if addr := conn.Conn().RemoteAddr(); addr != nil {
		if tcpAddr, ok := addr.(*net.TCPAddr); ok {
			clientIP = tcpAddr.IP.String()
		} else {
			clientIP = addr.String()
		}
	}

	metrics.Inc("mx_connections_total")

	// Edge defense, cheapest first: connection rate → DNSBL → concurrency cap.
	if b.connRateExceeded(clientIP) {
		b.log.Warn("conn.rate_limit", "client_ip", clientIP, "limit", b.config.ConnRateLimit)
		metrics.Inc("mx_rejects_total", "reason", "conn_rate")
		return nil, &smtp.SMTPError{
			Code:         421,
			EnhancedCode: smtp.EnhancedCode{4, 7, 0},
			Message:      "Connection rate exceeded, try later",
		}
	}
	if listed, zone := b.rblListed(clientIP); listed {
		b.log.Warn("conn.rbl_reject", "client_ip", clientIP, "zone", zone)
		metrics.Inc("mx_rejects_total", "reason", "rbl")
		return nil, &smtp.SMTPError{
			Code:         554,
			EnhancedCode: smtp.EnhancedCode{5, 7, 1},
			Message:      fmt.Sprintf("Your IP is listed on %s", zone),
		}
	}

	// Per-IP concurrency cap. NewSession runs at EHLO time; on refusal go-smtp
	// answers 451 and keeps no session, so Logout (our release) never fires for
	// refused connections — the slot is only taken on success.
	if !b.acquireConn(clientIP) {
		b.log.Warn("conn.per_ip_limit", "client_ip", clientIP, "limit", b.config.MaxConnsPerIP)
		metrics.Inc("mx_rejects_total", "reason", "per_ip_conns")
		return nil, &smtp.SMTPError{
			Code:         421,
			EnhancedCode: smtp.EnhancedCode{4, 7, 0},
			Message:      "Too many concurrent connections from your IP, try later",
		}
	}

	b.log.ConnectionOpen(clientIP)

	return &Session{
		backend:  b,
		clientIP: clientIP,
	}, nil
}

// NewServer creates and configures the go-smtp server.
func NewServer(b *Backend) *smtp.Server {
	s := smtp.NewServer(b)

	s.Addr = b.config.ListenAddr
	s.Domain = b.config.Domain
	s.ReadTimeout = b.config.ReadTimeout
	s.WriteTimeout = b.config.WriteTimeout
	s.MaxMessageBytes = b.config.MaxMessageSize
	s.MaxRecipients = b.config.MaxRecipients
	s.AllowInsecureAuth = true // We're not doing SMTP AUTH, just receiving

	tlsEnabled := false
	if b.config.TLSCertFile != "" && b.config.TLSKeyFile != "" {
		cert, err := tls.LoadX509KeyPair(b.config.TLSCertFile, b.config.TLSKeyFile)
		if err != nil {
			b.log.Warn("tls.load_failed", "error", err.Error())
		} else {
			s.TLSConfig = &tls.Config{
				Certificates: []tls.Certificate{cert},
				MinVersion:   tls.VersionTLS12,
			}
			tlsEnabled = true
		}
	}

	s.EnableSMTPUTF8 = true

	b.log.ServerStart(b.config.ListenAddr, b.config.Domain, "", tlsEnabled)

	return s
}

// Listen opens the listener for the configured address, applying a concurrent
// connection cap (go-smtp itself imposes no limit, so without this a flood of
// connections — each holding several times its message size in memory — can
// exhaust RAM).
func (b *Backend) Listen() (net.Listener, error) {
	ln, err := net.Listen("tcp", b.config.ListenAddr)
	if err != nil {
		return nil, err
	}
	if b.config.MaxConnections > 0 {
		ln = netutil.LimitListener(ln, b.config.MaxConnections)
	}
	return ln, nil
}

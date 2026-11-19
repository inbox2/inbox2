package outbound

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// DKIMKeyStore resolves DKIM signing keys from local files so the private key
// does not have to travel in every NATS job (which would expose it on the wire
// and in JetStream storage). Keys live in a directory as
// "<selector>._domainkey.<domain>.pem" or "<domain>/<selector>.pem".
//
// When a local key is found it takes precedence over any key carried in the
// message, letting operators stop transmitting secrets once keys are
// provisioned on the sender host.
type DKIMKeyStore struct {
	dir   string
	mu    sync.RWMutex
	cache map[string]string // "selector:domain" -> PEM
}

// NewDKIMKeyStore creates a key store rooted at dir. A nil store (dir == "")
// simply never resolves keys, so callers fall back to the per-message key.
func NewDKIMKeyStore(dir string) *DKIMKeyStore {
	return &DKIMKeyStore{dir: dir, cache: make(map[string]string)}
}

// Lookup returns the PEM-encoded private key for the domain/selector, or ""
// (and false) if the store is unconfigured or no key file exists.
func (s *DKIMKeyStore) Lookup(domain, selector string) (string, bool) {
	if s == nil || s.dir == "" || domain == "" || selector == "" {
		return "", false
	}

	key := selector + ":" + domain
	s.mu.RLock()
	if pem, ok := s.cache[key]; ok {
		s.mu.RUnlock()
		return pem, pem != ""
	}
	s.mu.RUnlock()

	pem := s.readKeyFile(domain, selector)

	s.mu.Lock()
	s.cache[key] = pem // cache misses too, to avoid repeated disk hits
	s.mu.Unlock()

	return pem, pem != ""
}

func (s *DKIMKeyStore) readKeyFile(domain, selector string) string {
	candidates := []string{
		filepath.Join(s.dir, selector+"._domainkey."+domain+".pem"),
		filepath.Join(s.dir, domain, selector+".pem"),
	}
	for _, path := range candidates {
		if data, err := os.ReadFile(path); err == nil && strings.Contains(string(data), "PRIVATE KEY") {
			return string(data)
		}
	}
	return ""
}

package smtpd

import (
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/inbox2/mta/internal/mxlog"
	"github.com/inbox2/mta/internal/queue"
)

var testLogger = mxlog.NewFromWriter(io.Discard)

func TestDomainCache_HitAndMiss(t *testing.T) {
	callCount := atomic.Int32{}
	lookup := func(domain string) (*queue.DomainInfo, error) {
		callCount.Add(1)
		if domain == "acme.com" {
			return &queue.DomainInfo{Found: true, OrgID: 1, Status: "verified", MaxMessageSize: 20}, nil
		}
		return &queue.DomainInfo{Found: false}, nil
	}

	cache := NewDomainCache(lookup, testLogger)

	// First call — cache miss
	info, err := cache.Get("acme.com")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !info.Found {
		t.Error("expected Found=true")
	}
	if callCount.Load() != 1 {
		t.Errorf("callCount = %d, want 1", callCount.Load())
	}

	// Second call — cache hit
	info, err = cache.Get("acme.com")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !info.Found {
		t.Error("expected Found=true on cache hit")
	}
	if callCount.Load() != 1 {
		t.Errorf("callCount = %d, want 1 (cached)", callCount.Load())
	}

	// Different domain — cache miss
	info, err = cache.Get("unknown.com")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if info.Found {
		t.Error("expected Found=false for unknown domain")
	}
	if callCount.Load() != 2 {
		t.Errorf("callCount = %d, want 2", callCount.Load())
	}
}

func TestDomainCache_LookupError(t *testing.T) {
	lookup := func(domain string) (*queue.DomainInfo, error) {
		return nil, errors.New("NATS timeout")
	}

	cache := NewDomainCache(lookup, testLogger)
	_, err := cache.Get("acme.com")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestDomainCache_Invalidate(t *testing.T) {
	callCount := atomic.Int32{}
	lookup := func(domain string) (*queue.DomainInfo, error) {
		callCount.Add(1)
		return &queue.DomainInfo{Found: true, OrgID: 1, Status: "verified"}, nil
	}

	cache := NewDomainCache(lookup, testLogger)
	cache.Get("acme.com") // miss
	cache.Get("acme.com") // hit
	if callCount.Load() != 1 {
		t.Fatalf("callCount = %d before invalidate", callCount.Load())
	}

	cache.Invalidate("acme.com")
	cache.Get("acme.com") // miss after invalidate
	if callCount.Load() != 2 {
		t.Errorf("callCount = %d after invalidate, want 2", callCount.Load())
	}
}

func TestDomainCache_ConcurrentAccess(t *testing.T) {
	callCount := atomic.Int32{}
	lookup := func(domain string) (*queue.DomainInfo, error) {
		callCount.Add(1)
		return &queue.DomainInfo{Found: true, OrgID: 1, Status: "verified", MaxMessageSize: 20}, nil
	}

	cache := NewDomainCache(lookup, testLogger)
	const goroutines = 50
	const domains = 10

	var wg sync.WaitGroup
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func(id int) {
			defer wg.Done()
			domain := fmt.Sprintf("domain-%d.com", id%domains)
			for j := 0; j < 100; j++ {
				info, err := cache.Get(domain)
				if err != nil {
					t.Errorf("goroutine %d: Get(%s): %v", id, domain, err)
					return
				}
				if !info.Found {
					t.Errorf("goroutine %d: expected Found=true", id)
					return
				}
			}
		}(i)
	}
	wg.Wait()

	// With 10 unique domains, should have at most 10 * goroutines lookups
	// (thundering herd), but likely much fewer due to caching
	if callCount.Load() > int32(goroutines*domains) {
		t.Errorf("excessive lookups: %d", callCount.Load())
	}
}

func TestDomainCache_ConcurrentGetAndInvalidate(t *testing.T) {
	lookup := func(domain string) (*queue.DomainInfo, error) {
		return &queue.DomainInfo{Found: true, OrgID: 1, Status: "verified"}, nil
	}

	cache := NewDomainCache(lookup, testLogger)
	const goroutines = 20

	var wg sync.WaitGroup
	wg.Add(goroutines * 2)

	// Readers
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				cache.Get("acme.com")
			}
		}()
	}

	// Invalidators
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				cache.Invalidate("acme.com")
			}
		}()
	}

	wg.Wait()
	// No panic or data race = success (run with -race flag)
}

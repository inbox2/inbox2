package outbound_test

import (
	"sync"
	"testing"

	"github.com/inbox2/mta/internal/outbound"
)

func TestMXResolver_LookupReal(t *testing.T) {
	resolver := outbound.NewMXResolver()

	// Lookup a well-known domain that has MX records
	records, err := resolver.Lookup("google.com")
	if err != nil {
		t.Fatalf("Lookup google.com: %v", err)
	}
	if len(records) == 0 {
		t.Fatal("expected MX records for google.com")
	}
	// Verify sorted by preference
	for i := 1; i < len(records); i++ {
		if records[i].Pref < records[i-1].Pref {
			t.Errorf("MX records not sorted by preference: %v", records)
			break
		}
	}
}

func TestMXResolver_CacheHit(t *testing.T) {
	resolver := outbound.NewMXResolver()

	// First lookup — cache miss
	records1, err := resolver.Lookup("google.com")
	if err != nil {
		t.Fatalf("first lookup: %v", err)
	}

	// Second lookup — should be cached
	records2, err := resolver.Lookup("google.com")
	if err != nil {
		t.Fatalf("second lookup: %v", err)
	}

	if len(records1) != len(records2) {
		t.Errorf("cache inconsistency: %d vs %d records", len(records1), len(records2))
	}
}

func TestMXResolver_NonexistentDomain(t *testing.T) {
	resolver := outbound.NewMXResolver()

	_, err := resolver.Lookup("this-domain-definitely-does-not-exist-12345.invalid")
	if err == nil {
		t.Fatal("expected error for nonexistent domain")
	}
}

func TestMXResolver_ConcurrentAccess(t *testing.T) {
	resolver := outbound.NewMXResolver()
	const goroutines = 30
	domains := []string{"google.com", "microsoft.com", "yahoo.com"}

	var wg sync.WaitGroup
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func(id int) {
			defer wg.Done()
			domain := domains[id%len(domains)]
			for j := 0; j < 20; j++ {
				records, err := resolver.Lookup(domain)
				if err != nil {
					t.Errorf("goroutine %d: Lookup(%s): %v", id, domain, err)
					return
				}
				if len(records) == 0 {
					t.Errorf("goroutine %d: no records for %s", id, domain)
					return
				}
			}
		}(i)
	}
	wg.Wait()
	// No panic or data race = success (run with -race flag)
}

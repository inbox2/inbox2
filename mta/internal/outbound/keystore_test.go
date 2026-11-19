package outbound_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/inbox2/mta/internal/outbound"
)

func TestDKIMKeyStore_Lookup(t *testing.T) {
	dir := t.TempDir()
	keyPEM, err := outbound.GenerateTestDKIMKey()
	if err != nil {
		t.Fatalf("GenerateTestDKIMKey: %v", err)
	}

	// Provision a key as "<selector>._domainkey.<domain>.pem".
	path := filepath.Join(dir, "sel._domainkey.acme.com.pem")
	if err := os.WriteFile(path, []byte(keyPEM), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	ks := outbound.NewDKIMKeyStore(dir)

	got, ok := ks.Lookup("acme.com", "sel")
	if !ok || got != keyPEM {
		t.Errorf("Lookup(acme.com, sel) ok=%v, match=%v", ok, got == keyPEM)
	}

	if _, ok := ks.Lookup("missing.com", "sel"); ok {
		t.Errorf("Lookup(missing.com) = found, want miss")
	}

	// A nil/unconfigured store never resolves keys (callers fall back to the
	// per-message key).
	var nilStore *outbound.DKIMKeyStore
	if _, ok := nilStore.Lookup("acme.com", "sel"); ok {
		t.Errorf("nil store returned a key")
	}
	if _, ok := outbound.NewDKIMKeyStore("").Lookup("acme.com", "sel"); ok {
		t.Errorf("empty-dir store returned a key")
	}
}

package spool

import (
	"bytes"
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"
)

type fakePutter struct {
	mu      sync.Mutex
	objects map[string][]byte
	fail    bool
}

func (f *fakePutter) PutObject(_ context.Context, key string, data []byte, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return errors.New("garage down")
	}
	if f.objects == nil {
		f.objects = map[string][]byte{}
	}
	f.objects[key] = append([]byte(nil), data...)
	return nil
}

func (f *fakePutter) get(key string) []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.objects[key]
}

func (f *fakePutter) setFail(v bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail = v
}

func TestPutRoundTripsObjectKeyWithUnderscoresAndSlashes(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	key := "org_ab12/2026/07/03/deadbeef/report.pdf.seal"
	if err := store.Put(key, []byte("ciphertext")); err != nil {
		t.Fatal(err)
	}
	pending, err := store.Pending()
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0][0] != key {
		t.Fatalf("round-trip failed: %+v", pending)
	}
}

func TestUploaderDrainsAndDeletes(t *testing.T) {
	dir := t.TempDir()
	store, _ := NewStore(dir)
	putter := &fakePutter{}

	if err := store.Put("org_x/a", []byte("aaa")); err != nil {
		t.Fatal(err)
	}
	if err := store.Put("org_x/b", []byte("bbb")); err != nil {
		t.Fatal(err)
	}

	u := NewUploader(store, putter, 10*time.Millisecond, nil)
	u.Start()
	defer u.Stop()
	u.Kick()

	deadline := time.After(3 * time.Second)
	for {
		if bytes.Equal(putter.get("org_x/a"), []byte("aaa")) && bytes.Equal(putter.get("org_x/b"), []byte("bbb")) {
			break
		}
		select {
		case <-deadline:
			t.Fatal("uploads did not complete")
		case <-time.After(20 * time.Millisecond):
		}
	}

	// Spool is emptied after successful upload.
	waitEmpty := time.After(2 * time.Second)
	for {
		pending, _ := store.Pending()
		if len(pending) == 0 {
			return
		}
		select {
		case <-waitEmpty:
			t.Fatalf("spool not cleaned: %+v", pending)
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// The crash-safety contract: entries survive a "restart" (new Store + Uploader
// over the same dir) and upload once the object store recovers.
func TestUploaderRetriesAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	store, _ := NewStore(dir)
	putter := &fakePutter{fail: true}

	if err := store.Put("org_y/att", []byte("sealed-bytes")); err != nil {
		t.Fatal(err)
	}

	u := NewUploader(store, putter, 10*time.Millisecond, nil)
	u.Start()
	u.Kick()
	time.Sleep(60 * time.Millisecond)
	u.Stop()

	if putter.get("org_y/att") != nil {
		t.Fatal("upload should have failed while garage is down")
	}
	pending, _ := store.Pending()
	if len(pending) != 1 {
		t.Fatalf("entry must survive failed uploads, got %+v", pending)
	}

	// "Restart": fresh store+uploader over the same directory, garage back up.
	store2, _ := NewStore(dir)
	putter.setFail(false)
	u2 := NewUploader(store2, putter, 10*time.Millisecond, nil)
	u2.Start()
	defer u2.Stop()

	deadline := time.After(3 * time.Second)
	for putter.get("org_y/att") == nil {
		select {
		case <-deadline:
			t.Fatal("upload did not resume after restart")
		case <-time.After(20 * time.Millisecond):
		}
	}
	if !bytes.Equal(putter.get("org_y/att"), []byte("sealed-bytes")) {
		t.Fatal("uploaded bytes mismatch")
	}
}

func TestPutIsDurableBeforeReturn(t *testing.T) {
	dir := t.TempDir()
	store, _ := NewStore(dir)
	if err := store.Put("k", []byte("v")); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("expected exactly one durable file, got %d", len(entries))
	}
	if entries[0].Name() == "" || entries[0].Name()[len(entries[0].Name())-5:] != ".seal" {
		t.Fatalf("unexpected spool artifact: %s", entries[0].Name())
	}
}

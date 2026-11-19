// Package spool implements the durable local staging area for sealed
// attachment ciphertext (docs/E2EE.md "Attachments (sealed)").
//
// Contract: in the SMTP ingestion window the MX encrypts each attachment and
// calls Put, which fsyncs the ciphertext to disk BEFORE the DATA ack — from
// that moment the spooled file is the only copy (plaintext is discarded). A
// background Uploader drains the spool to S3-compatible object storage
// (Garage) with retry and deletes each file after a successful upload. If the
// MX restarts, the uploader resumes from whatever is on disk. Only ciphertext
// ever touches the spool, so a slow/down Garage grows a bounded ciphertext
// backlog and never blocks SMTP acceptance.
package spool

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Store is the on-disk ciphertext spool. Filenames encode the destination
// object key (path separators escaped) so no sidecar metadata is needed.
type Store struct {
	dir string
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create spool dir: %w", err)
	}
	return &Store{dir: dir}, nil
}

// encodeName maps an object key to a flat spool filename via URL path escaping
// ("/" → %2F; "%" itself is escaped), so any object-key alphabet round-trips.
func encodeName(objectKey string) string { return url.PathEscape(objectKey) + ".seal" }

func decodeName(name string) string {
	key, err := url.PathUnescape(strings.TrimSuffix(name, ".seal"))
	if err != nil {
		return ""
	}
	return key
}

func isSpoolFile(name string) bool       { return strings.HasSuffix(name, ".seal") }
func (s *Store) path(name string) string { return filepath.Join(s.dir, name) }

// Put durably writes ciphertext destined for objectKey: temp file → fsync →
// rename (atomic on POSIX), so a crash never leaves a half-written spool entry
// that the uploader would ship as a truncated object.
func (s *Store) Put(objectKey string, ciphertext []byte) error {
	final := s.path(encodeName(objectKey))
	tmp := final + ".tmp"

	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("spool open: %w", err)
	}
	if _, err := f.Write(ciphertext); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("spool write: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("spool fsync: %w", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("spool close: %w", err)
	}
	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("spool rename: %w", err)
	}
	return nil
}

// Pending lists spooled entries as (objectKey, path) pairs, oldest first.
func (s *Store) Pending() ([][2]string, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	type item struct {
		key, path string
		mod       time.Time
	}
	var items []item
	for _, e := range entries {
		if e.IsDir() || !isSpoolFile(e.Name()) {
			continue
		}
		key := decodeName(e.Name())
		if key == "" {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		items = append(items, item{key, s.path(e.Name()), info.ModTime()})
	}
	for i := 1; i < len(items); i++ {
		for j := i; j > 0 && items[j].mod.Before(items[j-1].mod); j-- {
			items[j], items[j-1] = items[j-1], items[j]
		}
	}
	out := make([][2]string, len(items))
	for i, it := range items {
		out[i] = [2]string{it.key, it.path}
	}
	return out, nil
}

// ObjectPutter uploads one object. Satisfied by the minio client wrapper in
// s3.go; injectable for tests.
type ObjectPutter interface {
	PutObject(ctx context.Context, objectKey string, data []byte, contentType string) error
}

// Uploader drains the spool to object storage in the background.
type Uploader struct {
	store    *Store
	putter   ObjectPutter
	interval time.Duration
	logf     func(event string, keysAndValues ...any)

	wake chan struct{}
	stop chan struct{}
	wg   sync.WaitGroup
}

func NewUploader(store *Store, putter ObjectPutter, interval time.Duration, logf func(string, ...any)) *Uploader {
	if interval <= 0 {
		interval = 5 * time.Second
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Uploader{
		store: store, putter: putter, interval: interval, logf: logf,
		wake: make(chan struct{}, 1), stop: make(chan struct{}),
	}
}

// Start launches the drain loop. Kick after each Put for prompt uploads; the
// ticker covers retries and restart recovery.
func (u *Uploader) Start() {
	u.wg.Add(1)
	go func() {
		defer u.wg.Done()
		ticker := time.NewTicker(u.interval)
		defer ticker.Stop()
		u.drain()
		for {
			select {
			case <-u.stop:
				return
			case <-u.wake:
				u.drain()
			case <-ticker.C:
				u.drain()
			}
		}
	}()
}

// Kick nudges the uploader without blocking (coalesces if already pending).
func (u *Uploader) Kick() {
	select {
	case u.wake <- struct{}{}:
	default:
	}
}

func (u *Uploader) Stop() {
	close(u.stop)
	u.wg.Wait()
}

func (u *Uploader) drain() {
	pending, err := u.store.Pending()
	if err != nil {
		u.logf("spool.list_error", "error", err.Error())
		return
	}
	for _, entry := range pending {
		objectKey, path := entry[0], entry[1]
		data, err := os.ReadFile(path)
		if err != nil {
			u.logf("spool.read_error", "path", path, "error", err.Error())
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		err = u.putter.PutObject(ctx, objectKey, data, "application/octet-stream")
		cancel()
		if err != nil {
			// Leave the file for the next pass — at-least-once with retry.
			u.logf("spool.upload_retry", "object_key", objectKey, "error", err.Error())
			continue
		}
		if err := os.Remove(path); err != nil {
			u.logf("spool.cleanup_error", "path", path, "error", err.Error())
		}
		u.logf("spool.uploaded", "object_key", objectKey, "bytes", len(data))
	}
}

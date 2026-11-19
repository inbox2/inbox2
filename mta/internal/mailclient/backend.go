// Package mailclient is the IMAP and SMTP submission frontend for mail
// clients (docs/Mail-Clients.md). It holds no mail: every command becomes a
// call to Rails' /api/v1/mail-client, signed in as the connected person.
package mailclient

import (
	"bytes"
	"container/list"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Creds are the login and app password of the connected person. They go out
// as HTTP Basic on every backend call.
type Creds struct{ Login, Password string }

// ErrAuth is a 401 from the backend: bad credentials.
var ErrAuth = errors.New("mailclient: bad credentials")

// RefusedError is a 403: signed in but not allowed. Message is meant for the
// person.
type RefusedError struct{ Message string }

func (e *RefusedError) Error() string { return "mailclient: refused: " + e.Message }

// StatusError is any other non-2xx answer.
type StatusError struct {
	Status  int
	Message string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("mailclient: backend %d: %s", e.Status, e.Message)
}

func isStatus(err error, status int) bool {
	var se *StatusError
	return errors.As(err, &se) && se.Status == status
}

type Folder struct {
	Name        string  `json:"name"`
	SpecialUse  *string `json:"special_use"`
	UIDValidity uint32  `json:"uidvalidity"`
	UIDNext     uint32  `json:"uidnext"`
	Exists      uint32  `json:"exists"`
	Unseen      uint32  `json:"unseen"`
}

type Message struct {
	UID          uint32    `json:"uid"`
	Flags        []string  `json:"flags"`
	InternalDate time.Time `json:"internal_date"`
	Size         int64     `json:"size"`
}

type FolderMessages struct {
	UIDValidity uint32    `json:"uidvalidity"`
	UIDNext     uint32    `json:"uidnext"`
	Messages    []Message `json:"messages"`
}

type Moved struct {
	UID   uint32 `json:"uid"`
	ToUID uint32 `json:"to_uid"`
}

// Backend is the HTTP client for the mail-client contract.
type Backend struct {
	baseURL string
	http    *http.Client
	cache   *byteCache
}

func NewBackend(baseURL string) *Backend {
	return &Backend{
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    &http.Client{Timeout: 2 * time.Minute}, // raw messages with attachments are slow
		cache:   &byteCache{max: 64 << 20, items: map[string]*list.Element{}},
	}
}

// do sends one call. out is nil, a *[]byte for raw bytes, or a JSON target.
func (b *Backend) do(c Creds, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		buf, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(buf)
	}
	req, err := http.NewRequest(method, b.baseURL+"/"+path, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(c.Login, c.Password)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := b.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		var e struct {
			Errors []struct {
				Message string `json:"message"`
			} `json:"errors"`
		}
		msg := http.StatusText(resp.StatusCode)
		if json.Unmarshal(data, &e) == nil && len(e.Errors) > 0 && e.Errors[0].Message != "" {
			msg = e.Errors[0].Message
		}
		switch resp.StatusCode {
		case http.StatusUnauthorized:
			return ErrAuth
		case http.StatusForbidden:
			return &RefusedError{Message: msg}
		}
		return &StatusError{Status: resp.StatusCode, Message: msg}
	}
	switch out := out.(type) {
	case nil:
		return nil
	case *[]byte:
		*out = data
		return nil
	}
	return json.Unmarshal(data, out)
}

func folderPath(folder, rest string) string {
	return "folders/" + url.PathEscape(folder) + "/" + rest
}

// Session checks the credentials and returns the person's canonical login.
func (b *Backend) Session(c Creds) (string, error) {
	var out struct {
		Login string `json:"login"`
	}
	return out.Login, b.do(c, "GET", "session", nil, &out)
}

func (b *Backend) Folders(c Creds) ([]Folder, error) {
	var out struct {
		Folders []Folder `json:"folders"`
	}
	return out.Folders, b.do(c, "GET", "folders", nil, &out)
}

func (b *Backend) Messages(c Creds, folder string) (*FolderMessages, error) {
	var out FolderMessages
	return &out, b.do(c, "GET", folderPath(folder, "messages"), nil, &out)
}

func cacheKey(c Creds, folder string, uid uint32, kind string) string {
	return fmt.Sprintf("%s\x00%s\x00%d\x00%s", strings.ToLower(c.Login), folder, uid, kind)
}

// Header returns the header block. It never asks for the whole message: a
// cached raw message answers it, otherwise the cheap header endpoint does.
func (b *Backend) Header(c Creds, folder string, uid uint32) ([]byte, error) {
	if raw, ok := b.cache.get(cacheKey(c, folder, uid, "raw")); ok {
		return headerOf(raw), nil
	}
	key := cacheKey(c, folder, uid, "header")
	if h, ok := b.cache.get(key); ok {
		return h, nil
	}
	var h []byte
	if err := b.do(c, "GET", folderPath(folder, fmt.Sprintf("messages/%d/header", uid)), nil, &h); err != nil {
		return nil, err
	}
	b.cache.put(key, h)
	return h, nil
}

func (b *Backend) Raw(c Creds, folder string, uid uint32) ([]byte, error) {
	key := cacheKey(c, folder, uid, "raw")
	if raw, ok := b.cache.get(key); ok {
		return raw, nil
	}
	var raw []byte
	if err := b.do(c, "GET", folderPath(folder, fmt.Sprintf("messages/%d/raw", uid)), nil, &raw); err != nil {
		return nil, err
	}
	b.cache.put(key, raw)
	return raw, nil
}

func headerOf(raw []byte) []byte {
	if i := bytes.Index(raw, []byte("\r\n\r\n")); i >= 0 {
		return raw[:i+4]
	}
	if i := bytes.Index(raw, []byte("\n\n")); i >= 0 {
		return raw[:i+2]
	}
	return raw
}

// Flags changes flags; mode is "add", "remove" or "set". It returns the
// resulting flags of each message.
func (b *Backend) Flags(c Creds, folder string, uids []uint32, mode string, flags []string) ([]Message, error) {
	var out struct {
		Messages []Message `json:"messages"`
	}
	in := map[string]any{"uids": uids, "mode": mode, "flags": flags}
	return out.Messages, b.do(c, "POST", folderPath(folder, "flags"), in, &out)
}

func (b *Backend) Move(c Creds, folder string, uids []uint32, to string) ([]Moved, error) {
	var out struct {
		Moved []Moved `json:"moved"`
	}
	in := map[string]any{"uids": uids, "to": to}
	return out.Moved, b.do(c, "POST", folderPath(folder, "move"), in, &out)
}

func (b *Backend) Expunge(c Creds, folder string, uids []uint32) ([]uint32, error) {
	var out struct {
		Expunged []uint32 `json:"expunged"`
	}
	in := map[string]any{"uids": uids}
	return out.Expunged, b.do(c, "POST", folderPath(folder, "expunge"), in, &out)
}

// Search takes any subset of the contract's fields (from, to, subject, text,
// since, before).
func (b *Backend) Search(c Creds, folder string, query map[string]string) ([]uint32, error) {
	var out struct {
		UIDs []uint32 `json:"uids"`
	}
	return out.UIDs, b.do(c, "POST", folderPath(folder, "search"), query, &out)
}

func (b *Backend) Append(c Creds, folder string, raw []byte, flags []string) (uint32, error) {
	var out struct {
		UID uint32 `json:"uid"`
	}
	if flags == nil {
		flags = []string{}
	}
	in := map[string]any{"raw_b64": base64.StdEncoding.EncodeToString(raw), "flags": flags}
	return out.UID, b.do(c, "POST", folderPath(folder, "append"), in, &out)
}

func (b *Backend) Submit(c Creds, mailFrom string, rcptTo []string, raw []byte) (string, error) {
	var out struct {
		ID string `json:"id"`
	}
	in := map[string]any{"mail_from": mailFrom, "rcpt_to": rcptTo, "raw_b64": base64.StdEncoding.EncodeToString(raw)}
	return out.ID, b.do(c, "POST", "submit", in, &out)
}

// byteCache is an LRU bounded by total bytes. A message is immutable per
// (login, folder, uid), so entries never go stale.
type byteCache struct {
	mu    sync.Mutex
	max   int
	size  int
	order list.List // front = most recent
	items map[string]*list.Element
}

type cacheEntry struct {
	key  string
	data []byte
}

func (c *byteCache) get(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.items[key]
	if !ok {
		return nil, false
	}
	c.order.MoveToFront(el)
	return el.Value.(*cacheEntry).data, true
}

func (c *byteCache) put(key string, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.items[key]; ok || len(data) > c.max/4 {
		return
	}
	c.items[key] = c.order.PushFront(&cacheEntry{key, data})
	c.size += len(data)
	for c.size > c.max {
		el := c.order.Back()
		e := c.order.Remove(el).(*cacheEntry)
		delete(c.items, e.key)
		c.size -= len(e.data)
	}
}

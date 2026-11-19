package mailclient

import (
	"bytes"
	"container/list"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/smtp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-sasl"
)

// ---- fake backend: the docs/Mail-Clients.md contract, in memory ----

const (
	janeLogin = "jane@acme.com"
	janePass  = "app-password"
	offLogin  = "off@acme.com" // signs in, but the org has mail clients off
	offMsg    = "Mail clients are not switched on for your organization"
)

type fakeMsg struct {
	uid   uint32
	flags []string
	date  time.Time
	raw   []byte
}

type fakeFolder struct {
	name, specialUse string
	uidNext          uint32
	msgs             []*fakeMsg
}

type fakeBackend struct {
	mu         sync.Mutex
	folders    []*fakeFolder
	rawHits    int
	headerHits int
	moves      []string // "INBOX->Archive:2"
	submits    []map[string]any
}

func mail(from, subject, body string) []byte {
	return []byte("From: " + from + "\r\nTo: Jane <jane@acme.com>\r\nSubject: " + subject +
		"\r\nMessage-ID: <" + strings.ReplaceAll(subject, " ", "-") + "@example.com>\r\nDate: Wed, 11 Nov 2026 10:00:00 +0000\r\n" +
		"Content-Type: text/plain\r\n\r\n" + body + "\r\n")
}

var multipartMail = []byte("From: Carol <carol@example.com>\r\nTo: jane@acme.com\r\nSubject: Report\r\n" +
	"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=XX\r\n\r\n" +
	"--XX\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n" +
	"--XX\r\nContent-Type: application/pdf; name=r.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n" +
	"--XX--\r\n")

func newFake() *fakeBackend {
	f := &fakeBackend{}
	for _, d := range [][2]string{{"INBOX", ""}, {"Archive", `\Archive`}, {"Sent", `\Sent`}, {"Trash", `\Trash`}, {"Junk", `\Junk`}} {
		f.folders = append(f.folders, &fakeFolder{name: d[0], specialUse: d[1], uidNext: 1})
	}
	f.add("INBOX", mail("Alice <alice@example.com>", "Hello", "Hi Jane"), `\Seen`)
	f.add("INBOX", mail("Bob <bob@example.com>", "Invoice 42", "Please pay"))
	f.add("INBOX", multipartMail)
	f.add("Sent", mail("Jane <jane@acme.com>", "Sent one", "Already filed"), `\Seen`)
	return f
}

func (f *fakeBackend) folder(name string) *fakeFolder {
	for _, fo := range f.folders {
		if fo.name == name {
			return fo
		}
	}
	return nil
}

func (f *fakeBackend) add(folder string, raw []byte, flags ...string) uint32 {
	f.mu.Lock()
	defer f.mu.Unlock()
	fo := f.folder(folder)
	m := &fakeMsg{uid: fo.uidNext, flags: flags, date: time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC), raw: raw}
	fo.uidNext++
	fo.msgs = append(fo.msgs, m)
	return m.uid
}

func (f *fakeBackend) flagsOf(folder string, uid uint32) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, m := range f.folder(folder).msgs {
		if m.uid == uid {
			return slices.Clone(m.flags)
		}
	}
	return nil
}

func fakeError(w http.ResponseWriter, status int, msg string) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"errors": []map[string]string{{"message": msg}}, "status": status})
}

func (f *fakeBackend) handler() http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any) { json.NewEncoder(w).Encode(v) }
	type request struct {
		UIDs    []uint32 `json:"uids"`
		Mode    string   `json:"mode"`
		Flags   []string `json:"flags"`
		To      string   `json:"to"`
		RawB64  string   `json:"raw_b64"`
		From    string   `json:"from"`
		Subject string   `json:"subject"`
		Text    string   `json:"text"`
	}
	// in a folder: decode the body, find the folder, run fn under the lock
	folderCall := func(fn func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			var req request
			if r.Method == "POST" {
				json.NewDecoder(r.Body).Decode(&req)
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			fo := f.folder(r.PathValue("name"))
			if fo == nil {
				fakeError(w, 404, "No such folder")
				return
			}
			fn(w, r, fo, &req)
		}
	}
	find := func(fo *fakeFolder, r *http.Request) *fakeMsg {
		uid, _ := strconv.Atoi(r.PathValue("uid"))
		for _, m := range fo.msgs {
			if m.uid == uint32(uid) {
				return m
			}
		}
		return nil
	}

	mux.HandleFunc("GET /session", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]string{"login": janeLogin, "name": "Jane"})
	})
	mux.HandleFunc("GET /folders", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		var out []map[string]any
		for _, fo := range f.folders {
			unseen := 0
			for _, m := range fo.msgs {
				if !slices.Contains(m.flags, `\Seen`) {
					unseen++
				}
			}
			var su any
			if fo.specialUse != "" {
				su = fo.specialUse
			}
			out = append(out, map[string]any{"name": fo.name, "special_use": su, "uidvalidity": 7,
				"uidnext": fo.uidNext, "exists": len(fo.msgs), "unseen": unseen})
		}
		reply(w, map[string]any{"folders": out})
	})
	mux.HandleFunc("GET /folders/{name}/messages", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, _ *request) {
		out := []map[string]any{}
		for _, m := range fo.msgs {
			out = append(out, map[string]any{"uid": m.uid, "flags": append([]string{}, m.flags...),
				"internal_date": m.date.Format(time.RFC3339), "size": len(m.raw)})
		}
		reply(w, map[string]any{"uidvalidity": 7, "uidnext": fo.uidNext, "messages": out})
	}))
	mux.HandleFunc("GET /folders/{name}/messages/{uid}/header", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, _ *request) {
		m := find(fo, r)
		if m == nil {
			fakeError(w, 404, "No such message")
			return
		}
		f.headerHits++
		w.Header().Set("Content-Type", "message/rfc822")
		w.Write(headerOf(m.raw))
	}))
	mux.HandleFunc("GET /folders/{name}/messages/{uid}/raw", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, _ *request) {
		m := find(fo, r)
		if m == nil {
			fakeError(w, 404, "No such message")
			return
		}
		f.rawHits++
		w.Write(m.raw)
	}))
	mux.HandleFunc("POST /folders/{name}/flags", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request) {
		out := []map[string]any{}
		for _, m := range fo.msgs {
			if !slices.Contains(req.UIDs, m.uid) {
				continue
			}
			switch req.Mode {
			case "set":
				m.flags = slices.Clone(req.Flags)
			case "add":
				for _, fl := range req.Flags {
					if !slices.Contains(m.flags, fl) {
						m.flags = append(m.flags, fl)
					}
				}
			case "remove":
				m.flags = slices.DeleteFunc(m.flags, func(fl string) bool { return slices.Contains(req.Flags, fl) })
			}
			out = append(out, map[string]any{"uid": m.uid, "flags": append([]string{}, m.flags...)})
		}
		reply(w, map[string]any{"messages": out})
	}))
	mux.HandleFunc("POST /folders/{name}/move", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request) {
		dest := f.folder(req.To)
		out := []map[string]any{}
		fo.msgs = slices.DeleteFunc(fo.msgs, func(m *fakeMsg) bool {
			if dest == nil || !slices.Contains(req.UIDs, m.uid) {
				return false
			}
			old := m.uid
			m.uid = dest.uidNext
			dest.uidNext++
			dest.msgs = append(dest.msgs, m)
			out = append(out, map[string]any{"uid": old, "to_uid": m.uid})
			f.moves = append(f.moves, fmt.Sprintf("%s->%s:%d", fo.name, dest.name, old))
			return true
		})
		reply(w, map[string]any{"moved": out})
	}))
	mux.HandleFunc("POST /folders/{name}/expunge", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request) {
		out := []uint32{}
		fo.msgs = slices.DeleteFunc(fo.msgs, func(m *fakeMsg) bool {
			if !slices.Contains(m.flags, `\Deleted`) || (req.UIDs != nil && !slices.Contains(req.UIDs, m.uid)) {
				return false
			}
			out = append(out, m.uid)
			return true
		})
		reply(w, map[string]any{"expunged": out})
	}))
	mux.HandleFunc("POST /folders/{name}/search", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request) {
		has := func(hay []byte, needle string) bool {
			return bytes.Contains(bytes.ToLower(hay), []byte(strings.ToLower(needle)))
		}
		line := func(m *fakeMsg, name string) []byte {
			for _, l := range bytes.Split(headerOf(m.raw), []byte("\r\n")) {
				if bytes.HasPrefix(l, []byte(name+":")) {
					return l
				}
			}
			return nil
		}
		out := []uint32{}
		for _, m := range fo.msgs {
			if has(line(m, "From"), req.From) && has(line(m, "Subject"), req.Subject) && has(m.raw, req.Text) {
				out = append(out, m.uid)
			}
		}
		reply(w, map[string]any{"uids": out})
	}))
	mux.HandleFunc("POST /folders/{name}/append", folderCall(func(w http.ResponseWriter, r *http.Request, fo *fakeFolder, req *request) {
		raw, _ := base64.StdEncoding.DecodeString(req.RawB64)
		for _, m := range fo.msgs {
			if bytes.Equal(m.raw, raw) {
				reply(w, map[string]any{"uid": m.uid})
				return
			}
		}
		fakeError(w, 422, "Only a copy of a message you sent can be added")
	}))
	mux.HandleFunc("POST /submit", func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		json.NewDecoder(r.Body).Decode(&req)
		if req["mail_from"] != janeLogin {
			fakeError(w, 403, "You may not send as that address")
			return
		}
		f.mu.Lock()
		f.submits = append(f.submits, req)
		f.mu.Unlock()
		reply(w, map[string]string{"id": "msg_1"})
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		switch {
		case pass != janePass || (user != janeLogin && user != offLogin):
			fakeError(w, 401, "Bad credentials")
		case user == offLogin:
			fakeError(w, 403, offMsg)
		default:
			mux.ServeHTTP(w, r)
		}
	})
}

// ---- harness ----

type rig struct {
	fake    *fakeBackend
	backend *Backend
	log     *slog.Logger
}

func newRig(t *testing.T) *rig {
	t.Helper()
	fake := newFake()
	ts := httptest.NewServer(fake.handler())
	t.Cleanup(ts.Close)
	return &rig{fake: fake, backend: NewBackend(ts.URL), log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func listen(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return ln
}

// imapAddr starts the IMAP server on loopback.
func (r *rig) imapAddr(t *testing.T, insecureAuth bool) string {
	t.Helper()
	srv := (&IMAP{Backend: r.backend, Log: r.log, InsecureAuth: insecureAuth, IdleInterval: 20 * time.Millisecond}).Server()
	ln := listen(t)
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return ln.Addr().String()
}

func dial(t *testing.T, addr string, h *imapclient.UnilateralDataHandler) *imapclient.Client {
	t.Helper()
	c, err := imapclient.DialInsecure(addr, &imapclient.Options{UnilateralDataHandler: h})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

// client is a signed-in IMAP client with INBOX selected.
func (r *rig) client(t *testing.T, h *imapclient.UnilateralDataHandler) *imapclient.Client {
	t.Helper()
	c := dial(t, r.imapAddr(t, true), h)
	if err := c.Login(janeLogin, janePass).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Select("INBOX", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	return c
}

func wantNo(t *testing.T, err error, contains string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), contains) {
		t.Fatalf("want an error containing %q, got %v", contains, err)
	}
}

func fetch(t *testing.T, c *imapclient.Client, set imap.NumSet, o *imap.FetchOptions) []*imapclient.FetchMessageBuffer {
	t.Helper()
	msgs, err := c.Fetch(set, o).Collect()
	if err != nil {
		t.Fatal(err)
	}
	return msgs
}

// ---- IMAP ----

func TestIMAPLogin(t *testing.T) {
	r := newRig(t)
	addr := r.imapAddr(t, true)

	if err := dial(t, addr, nil).Login(janeLogin, janePass).Wait(); err != nil {
		t.Fatalf("login: %v", err)
	}
	if err := dial(t, addr, nil).Authenticate(sasl.NewPlainClient("", janeLogin, janePass)); err != nil {
		t.Fatalf("authenticate plain: %v", err)
	}
	wantNo(t, dial(t, addr, nil).Login(janeLogin, "wrong").Wait(), "Authentication failed")
	wantNo(t, dial(t, addr, nil).Login(offLogin, janePass).Wait(), offMsg)
}

func TestIMAPLoginNeedsTLS(t *testing.T) {
	r := newRig(t)
	c := dial(t, r.imapAddr(t, false), nil)
	wantNo(t, c.Login(janeLogin, janePass).Wait(), "TLS is required")
}

func TestIMAPCapabilities(t *testing.T) {
	c := newRig(t).client(t, nil)
	for _, cap := range []imap.Cap{imap.CapIMAP4rev1, imap.CapMove, imap.CapUIDPlus, imap.CapSpecialUse, imap.CapIdle, imap.CapNamespace} {
		if !c.Caps().Has(cap) {
			t.Errorf("capability %s not advertised", cap)
		}
	}
}

func TestIMAPListFolders(t *testing.T) {
	c := newRig(t).client(t, nil)
	boxes, err := c.List("", "*", nil).Collect()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, b := range boxes {
		got[b.Mailbox] = fmt.Sprint(b.Attrs)
	}
	want := map[string]string{"INBOX": "[]", "Archive": `[\Archive]`, "Sent": `[\Sent]`, "Trash": `[\Trash]`, "Junk": `[\Junk]`}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("LIST = %v, want %v", got, want)
	}
	wantNo(t, c.Create("Projects", nil).Wait(), "Folders are fixed")
}

func TestIMAPSelectAndStatus(t *testing.T) {
	r := newRig(t)
	c := dial(t, r.imapAddr(t, true), nil)
	if err := c.Login(janeLogin, janePass).Wait(); err != nil {
		t.Fatal(err)
	}
	data, err := c.Select("inbox", nil).Wait()
	if err != nil {
		t.Fatal(err)
	}
	if data.NumMessages != 3 || data.UIDNext != 4 || data.UIDValidity != 7 {
		t.Fatalf("SELECT = %+v", data)
	}
	st, err := c.Status("Sent", &imap.StatusOptions{NumMessages: true, NumUnseen: true, UIDNext: true}).Wait()
	if err != nil {
		t.Fatal(err)
	}
	if *st.NumMessages != 1 || *st.NumUnseen != 0 || st.UIDNext != 2 {
		t.Fatalf("STATUS = %+v", st)
	}
	_, err = c.Select("Nope", nil).Wait()
	wantNo(t, err, "No such mailbox")
}

func TestIMAPFetchMetadataUsesHeaderOnly(t *testing.T) {
	r := newRig(t)
	c := r.client(t, nil)
	headerFields := &imap.FetchItemBodySection{Specifier: imap.PartSpecifierHeader, HeaderFields: []string{"Subject"}, Peek: true}
	msgs := fetch(t, c, imap.SeqSetNum(2), &imap.FetchOptions{
		Flags: true, UID: true, RFC822Size: true, InternalDate: true, Envelope: true,
		BodySection: []*imap.FetchItemBodySection{headerFields},
	})
	if len(msgs) != 1 {
		t.Fatalf("got %d messages", len(msgs))
	}
	m := msgs[0]
	if m.UID != 2 || m.RFC822Size != int64(len(mail("Bob <bob@example.com>", "Invoice 42", "Please pay"))) || len(m.Flags) != 0 {
		t.Fatalf("metadata = uid %d size %d flags %v", m.UID, m.RFC822Size, m.Flags)
	}
	if !m.InternalDate.Equal(time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("internal date = %v", m.InternalDate)
	}
	if m.Envelope.Subject != "Invoice 42" || m.Envelope.From[0].Addr() != "bob@example.com" || m.Envelope.From[0].Name != "Bob" {
		t.Fatalf("envelope = %+v", m.Envelope)
	}
	if got := string(m.FindBodySection(headerFields)); got != "Subject: Invoice 42\r\n\r\n" {
		t.Fatalf("HEADER.FIELDS = %q", got)
	}
	// the same header again comes from the cache
	fetch(t, c, imap.SeqSetNum(2), &imap.FetchOptions{Envelope: true})

	r.fake.mu.Lock()
	defer r.fake.mu.Unlock()
	if r.fake.rawHits != 0 || r.fake.headerHits != 1 {
		t.Fatalf("raw hits = %d (want 0), header hits = %d (want 1)", r.fake.rawHits, r.fake.headerHits)
	}
}

func TestIMAPFetchBodySetsSeen(t *testing.T) {
	r := newRig(t)
	c := r.client(t, nil)
	want := mail("Bob <bob@example.com>", "Invoice 42", "Please pay")

	peek := &imap.FetchItemBodySection{Peek: true}
	msgs := fetch(t, c, imap.UIDSetNum(2), &imap.FetchOptions{BodySection: []*imap.FetchItemBodySection{peek}})
	if !bytes.Equal(msgs[0].FindBodySection(peek), want) {
		t.Fatalf("BODY.PEEK[] = %q", msgs[0].FindBodySection(peek))
	}
	if flags := r.fake.flagsOf("INBOX", 2); len(flags) != 0 {
		t.Fatalf("PEEK changed the flags: %v", flags)
	}

	whole := &imap.FetchItemBodySection{}
	msgs = fetch(t, c, imap.UIDSetNum(2), &imap.FetchOptions{BodySection: []*imap.FetchItemBodySection{whole}})
	if !bytes.Equal(msgs[0].FindBodySection(whole), want) {
		t.Fatalf("BODY[] = %q", msgs[0].FindBodySection(whole))
	}
	if !slices.Contains(msgs[0].Flags, imap.FlagSeen) {
		t.Fatalf("the fetch did not report \\Seen: %v", msgs[0].Flags)
	}
	if flags := r.fake.flagsOf("INBOX", 2); !slices.Contains(flags, `\Seen`) {
		t.Fatalf("backend flags = %v, want \\Seen", flags)
	}

	text := &imap.FetchItemBodySection{Specifier: imap.PartSpecifierText, Peek: true}
	part := &imap.FetchItemBodySection{Peek: true, Partial: &imap.SectionPartial{Offset: 6, Size: 3}}
	msgs = fetch(t, c, imap.UIDSetNum(2), &imap.FetchOptions{BodySection: []*imap.FetchItemBodySection{text, part}})
	if got := string(msgs[0].FindBodySection(text)); got != "Please pay\r\n" {
		t.Fatalf("BODY[TEXT] = %q", got)
	}
	if got := string(msgs[0].FindBodySection(part)); got != "Bob" {
		t.Fatalf("BODY[]<6.3> = %q", got)
	}
	r.fake.mu.Lock()
	defer r.fake.mu.Unlock()
	if r.fake.rawHits != 1 {
		t.Fatalf("raw hits = %d, want 1 (the rest from the cache)", r.fake.rawHits)
	}
}

func TestIMAPBodyStructureMultipart(t *testing.T) {
	c := newRig(t).client(t, nil)
	part2 := &imap.FetchItemBodySection{Part: []int{2}, Peek: true}
	msgs := fetch(t, c, imap.SeqSetNum(3), &imap.FetchOptions{
		BodyStructure: &imap.FetchItemBodyStructure{Extended: true},
		BodySection:   []*imap.FetchItemBodySection{part2},
	})
	mp, ok := msgs[0].BodyStructure.(*imap.BodyStructureMultiPart)
	if !ok || mp.Subtype != "mixed" || len(mp.Children) != 2 {
		t.Fatalf("body structure = %#v", msgs[0].BodyStructure)
	}
	pdf := mp.Children[1].(*imap.BodyStructureSinglePart)
	if pdf.MediaType() != "application/pdf" || pdf.Encoding != "base64" || pdf.Params["name"] != "r.pdf" {
		t.Fatalf("second part = %+v", pdf)
	}
	if got := string(msgs[0].FindBodySection(part2)); got != "JVBERg==" {
		t.Fatalf("BODY[2] = %q", got)
	}
}

func TestIMAPStore(t *testing.T) {
	r := newRig(t)
	c := r.client(t, nil)
	msgs, err := c.Store(imap.SeqSetNum(2), &imap.StoreFlags{Op: imap.StoreFlagsAdd, Flags: []imap.Flag{imap.FlagFlagged, imap.FlagSeen}}, nil).Collect()
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || !slices.Contains(msgs[0].Flags, imap.FlagFlagged) || !slices.Contains(msgs[0].Flags, imap.FlagSeen) {
		t.Fatalf("STORE +FLAGS answered %+v", msgs)
	}
	msgs, err = c.Store(imap.UIDSetNum(2), &imap.StoreFlags{Op: imap.StoreFlagsDel, Silent: true, Flags: []imap.Flag{imap.FlagSeen}}, nil).Collect()
	if err != nil || len(msgs) != 0 {
		t.Fatalf("STORE -FLAGS.SILENT answered %+v, %v", msgs, err)
	}
	if flags := r.fake.flagsOf("INBOX", 2); fmt.Sprint(flags) != `[\Flagged]` {
		t.Fatalf("backend flags = %v", flags)
	}
	if _, err = c.Store(imap.UIDSetNum(2), &imap.StoreFlags{Op: imap.StoreFlagsSet, Flags: []imap.Flag{imap.FlagAnswered}}, nil).Collect(); err != nil {
		t.Fatal(err)
	}
	if flags := r.fake.flagsOf("INBOX", 2); fmt.Sprint(flags) != `[\Answered]` {
		t.Fatalf("backend flags after set = %v", flags)
	}
}

func TestIMAPMove(t *testing.T) {
	r := newRig(t)
	var expunged []uint32
	c := r.client(t, &imapclient.UnilateralDataHandler{Expunge: func(seq uint32) { expunged = append(expunged, seq) }})

	data, err := c.Move(imap.UIDSetNum(2), "Archive").Wait()
	if err != nil {
		t.Fatal(err)
	}
	if data.UIDValidity != 7 || data.SourceUIDs.String() != "2" || data.DestUIDs.String() != "1" {
		t.Fatalf("COPYUID = %+v", data)
	}
	if fmt.Sprint(expunged) != "[2]" {
		t.Fatalf("EXPUNGE after MOVE = %v, want [2]", expunged)
	}
	// the source shrank: sequence 2 is now the old uid 3
	msgs := fetch(t, c, imap.SeqSetNum(1, 2), &imap.FetchOptions{UID: true})
	if len(msgs) != 2 || msgs[1].UID != 3 {
		t.Fatalf("after MOVE: %+v", msgs)
	}

	// COPY is the same move; the EXPUNGE comes with the poll that follows it
	if _, err := c.Copy(imap.SeqSetNum(1), "Archive").Wait(); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(expunged) != "[2 1]" {
		t.Fatalf("EXPUNGE after COPY = %v, want [2 1]", expunged)
	}
	r.fake.mu.Lock()
	defer r.fake.mu.Unlock()
	if fmt.Sprint(r.fake.moves) != "[INBOX->Archive:2 INBOX->Archive:1]" {
		t.Fatalf("backend moves = %v", r.fake.moves)
	}
}

func TestIMAPExpunge(t *testing.T) {
	r := newRig(t)
	c := r.client(t, nil)
	del := &imap.StoreFlags{Op: imap.StoreFlagsAdd, Silent: true, Flags: []imap.Flag{imap.FlagDeleted}}
	if err := c.Store(imap.SeqSetNum(1, 3), del, nil).Close(); err != nil {
		t.Fatal(err)
	}
	// UID EXPUNGE of a message that is not \Deleted does nothing
	if seqs, err := c.UIDExpunge(imap.UIDSetNum(2)).Collect(); err != nil || len(seqs) != 0 {
		t.Fatalf("UID EXPUNGE 2 = %v, %v", seqs, err)
	}
	if seqs, err := c.UIDExpunge(imap.UIDSetNum(3)).Collect(); err != nil || fmt.Sprint(seqs) != "[3]" {
		t.Fatalf("UID EXPUNGE 3 = %v, %v", seqs, err)
	}
	if seqs, err := c.Expunge().Collect(); err != nil || fmt.Sprint(seqs) != "[1]" {
		t.Fatalf("EXPUNGE = %v, %v", seqs, err)
	}
	r.fake.mu.Lock()
	defer r.fake.mu.Unlock()
	if left := r.fake.folder("INBOX").msgs; len(left) != 1 || left[0].uid != 2 {
		t.Fatalf("backend INBOX has %d messages left", len(left))
	}
}

func TestIMAPSearch(t *testing.T) {
	c := newRig(t).client(t, nil)
	search := func(uid bool, crit *imap.SearchCriteria) string {
		t.Helper()
		cmd := c.Search(crit, nil)
		if uid {
			cmd = c.UIDSearch(crit, nil)
		}
		data, err := cmd.Wait()
		if err != nil {
			t.Fatal(err)
		}
		return data.All.String()
	}
	from := func(v string) imap.SearchCriteria {
		return imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "From", Value: v}}}
	}
	bob, alice := from("bob"), from("alice")

	for _, tc := range []struct {
		name string
		uid  bool
		crit imap.SearchCriteria
		want string
	}{
		{"UNSEEN", false, imap.SearchCriteria{NotFlag: []imap.Flag{imap.FlagSeen}}, "2:3"},
		{"SEEN", true, imap.SearchCriteria{Flag: []imap.Flag{imap.FlagSeen}}, "1"},
		{"FROM bob", true, bob, "2"},
		{"OR FROM alice FROM bob", false, imap.SearchCriteria{Or: [][2]imap.SearchCriteria{{alice, bob}}}, "1:2"},
		{"NOT FROM bob", false, imap.SearchCriteria{Not: []imap.SearchCriteria{bob}}, "1,3"},
		{"SUBJECT invoice UNSEEN", false, imap.SearchCriteria{NotFlag: []imap.Flag{imap.FlagSeen},
			Header: []imap.SearchCriteriaHeaderField{{Key: "Subject", Value: "invoice"}}}, "2"},
		{"TEXT attached", false, imap.SearchCriteria{Text: []string{"attached"}}, "3"},
		{"2:* LARGER 200", false, imap.SearchCriteria{SeqNum: []imap.SeqSet{{{Start: 2, Stop: 0}}}, Larger: 200}, "3"},
		{"SINCE 11-Nov", false, imap.SearchCriteria{Since: time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)}, "1:3"},
		{"BEFORE 11-Nov", false, imap.SearchCriteria{Before: time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)}, ""},
	} {
		if got := search(tc.uid, &tc.crit); got != tc.want {
			t.Errorf("SEARCH %s = %q, want %q", tc.name, got, tc.want)
		}
	}

	_, err := c.Search(&imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "X-Spam", Value: "yes"}}}, nil).Wait()
	wantNo(t, err, "not supported")
}

// watch returns a client whose EXISTS / EXPUNGE / FETCH FLAGS updates land on
// a channel.
func (r *rig) watch(t *testing.T) (*imapclient.Client, chan string) {
	updates := make(chan string, 16)
	c := r.client(t, &imapclient.UnilateralDataHandler{
		Mailbox: func(d *imapclient.UnilateralDataMailbox) {
			if d.NumMessages != nil {
				updates <- fmt.Sprintf("exists %d", *d.NumMessages)
			}
		},
		Expunge: func(seq uint32) { updates <- fmt.Sprintf("expunge %d", seq) },
		Fetch: func(msg *imapclient.FetchMessageData) {
			buf, _ := msg.Collect()
			updates <- fmt.Sprintf("flags %d %v", buf.SeqNum, buf.Flags)
		},
	})
	return c, updates
}

func wantUpdates(t *testing.T, updates chan string, want ...string) {
	t.Helper()
	for _, w := range want {
		select {
		case got := <-updates:
			if got != w {
				t.Fatalf("update = %q, want %q", got, w)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("no %q update", w)
		}
	}
}

// changeElsewhere is another client at work: uid 1 goes, uid 3 is read, a new
// message arrives.
func (r *rig) changeElsewhere() {
	f := r.fake
	f.mu.Lock()
	inbox := f.folder("INBOX")
	inbox.msgs = inbox.msgs[1:]
	inbox.msgs[1].flags = []string{`\Seen`}
	f.mu.Unlock()
	f.add("INBOX", mail("Dave <dave@example.com>", "New one", "Fresh"))
}

func TestIMAPNoopSeesChanges(t *testing.T) {
	r := newRig(t)
	c, updates := r.watch(t)
	r.changeElsewhere()
	if err := c.Noop().Wait(); err != nil {
		t.Fatal(err)
	}
	wantUpdates(t, updates, "expunge 1", "exists 3", `flags 2 [\Seen]`)
	msgs := fetch(t, c, imap.SeqSetNum(3), &imap.FetchOptions{Envelope: true, UID: true})
	if msgs[0].UID != 4 || msgs[0].Envelope.Subject != "New one" {
		t.Fatalf("new message = %+v", msgs[0])
	}
}

func TestIMAPIdleSeesChanges(t *testing.T) {
	r := newRig(t)
	c, updates := r.watch(t)
	idle, err := c.Idle()
	if err != nil {
		t.Fatal(err)
	}
	r.changeElsewhere()
	wantUpdates(t, updates, "expunge 1", "exists 3", `flags 2 [\Seen]`)
	if err := idle.Close(); err != nil {
		t.Fatal(err)
	}
	if err := idle.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestIMAPAppend(t *testing.T) {
	c := newRig(t).client(t, nil)
	appendMsg := func(raw []byte) (*imap.AppendData, error) {
		cmd := c.Append("Sent", int64(len(raw)), &imap.AppendOptions{Flags: []imap.Flag{imap.FlagSeen}})
		cmd.Write(raw)
		cmd.Close()
		return cmd.Wait()
	}
	data, err := appendMsg(mail("Jane <jane@acme.com>", "Sent one", "Already filed"))
	if err != nil {
		t.Fatal(err)
	}
	if data.UID != 1 || data.UIDValidity != 7 {
		t.Fatalf("APPENDUID = %+v", data)
	}
	_, err = appendMsg(mail("Jane <jane@acme.com>", "A draft", "Not sent"))
	wantNo(t, err, "Only a copy of a message you sent can be added")
}

// ---- submission ----

func (r *rig) smtpClient(t *testing.T) *smtp.Client {
	t.Helper()
	srv := NewSubmissionServer(r.backend, r.log, "mx.test", true)
	ln := listen(t)
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	c, err := smtp.Dial(ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func send(c *smtp.Client, from string, to []string, raw []byte) error {
	if err := c.Mail(from); err != nil {
		return err
	}
	for _, rcpt := range to {
		if err := c.Rcpt(rcpt); err != nil {
			return err
		}
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	w.Write(raw)
	return w.Close()
}

func TestSubmission(t *testing.T) {
	r := newRig(t)
	c := r.smtpClient(t)
	raw := mail("Jane <jane@acme.com>", "Outbound", "Hello there")

	wantNo(t, c.Mail(janeLogin), "530")
	if err := c.Reset(); err != nil {
		t.Fatal(err)
	}
	if err := c.Auth(smtp.PlainAuth("", janeLogin, janePass, "127.0.0.1")); err != nil {
		t.Fatalf("auth: %v", err)
	}
	if err := send(c, janeLogin, []string{"a@example.com", "b@example.com"}, raw); err != nil {
		t.Fatalf("send: %v", err)
	}
	r.fake.mu.Lock()
	got := r.fake.submits
	r.fake.mu.Unlock()
	if len(got) != 1 || fmt.Sprint(got[0]["rcpt_to"]) != "[a@example.com b@example.com]" ||
		got[0]["raw_b64"] != base64.StdEncoding.EncodeToString(raw) {
		t.Fatalf("backend saw %v", got)
	}

	// sending as someone else: the backend's 403 and its message
	err := send(c, "ceo@acme.com", []string{"a@example.com"}, raw)
	wantNo(t, err, "550 5.7.1 You may not send as that address")
}

func TestSubmissionAuthFailures(t *testing.T) {
	r := newRig(t)
	wantNo(t, r.smtpClient(t).Auth(smtp.PlainAuth("", janeLogin, "wrong", "127.0.0.1")), "535 5.7.8")
	wantNo(t, r.smtpClient(t).Auth(smtp.PlainAuth("", offLogin, janePass, "127.0.0.1")), offMsg)
}

type loginAuth struct{ user, pass string }

func (a loginAuth) Start(*smtp.ServerInfo) (string, []byte, error) { return "LOGIN", nil, nil }
func (a loginAuth) Next(fromServer []byte, more bool) ([]byte, error) {
	if !more {
		return nil, nil
	}
	if string(fromServer) == "Username:" {
		return []byte(a.user), nil
	}
	return []byte(a.pass), nil
}

func TestSubmissionAuthLogin(t *testing.T) {
	r := newRig(t)
	c := r.smtpClient(t)
	if err := c.Auth(loginAuth{janeLogin, janePass}); err != nil {
		t.Fatalf("AUTH LOGIN: %v", err)
	}
	if err := send(c, janeLogin, []string{"a@example.com"}, []byte("Subject: x\r\n\r\nhi\r\n")); err != nil {
		t.Fatal(err)
	}
	wantNo(t, r.smtpClient(t).Auth(loginAuth{janeLogin, "wrong"}), "535 5.7.8")
}

// ---- cache ----

func TestByteCacheEvictsOldest(t *testing.T) {
	c := &byteCache{max: 100, items: map[string]*list.Element{}}
	c.put("a", make([]byte, 20))
	c.put("b", make([]byte, 20))
	c.put("big", make([]byte, 26)) // over a quarter of the cache: not kept
	for i := range 4 {
		c.get("a") // keep "a" recent
		c.put(fmt.Sprint("fill", i), make([]byte, 20))
	}
	if _, ok := c.get("a"); !ok {
		t.Error("recently used entry was evicted")
	}
	if _, ok := c.get("b"); ok {
		t.Error("oldest entry was not evicted")
	}
	if _, ok := c.get("big"); ok {
		t.Error("oversized entry was cached")
	}
	if c.size > c.max {
		t.Errorf("size %d over max %d", c.size, c.max)
	}
}

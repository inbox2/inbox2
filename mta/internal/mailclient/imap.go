package mailclient

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-message/textproto"
)

const (
	folderDelim = '/'
	appendLimit = 30 << 20
)

// IMAP is the IMAP4rev1 frontend.
type IMAP struct {
	Backend *Backend
	Log     *slog.Logger
	// InsecureAuth lets a client sign in without TLS. Tests only.
	InsecureAuth bool
	// IdleInterval is how often an idling session asks the backend for
	// changes. Zero means 20 seconds.
	IdleInterval time.Duration
}

// Server builds the IMAP server. The caller owns the listener (implicit TLS
// in production).
func (s *IMAP) Server() *imapserver.Server {
	return imapserver.New(&imapserver.Options{
		NewSession: func(c *imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			log := s.Log.With("remote", c.NetConn().RemoteAddr().String())
			log.Info("imap.connect")
			return &imapSession{srv: s, b: s.Backend, log: log}, &imapserver.GreetingData{}, nil
		},
		Caps: imap.CapSet{
			imap.CapIMAP4rev1:  {},
			imap.CapMove:       {},
			imap.CapUIDPlus:    {},
			imap.CapSpecialUse: {},
			imap.CapNamespace:  {},
		},
		Logger:       slog.NewLogLogger(s.Log.Handler(), slog.LevelWarn),
		InsecureAuth: s.InsecureAuth,
	})
}

type imapSession struct {
	srv   *IMAP
	b     *Backend
	log   *slog.Logger
	creds Creds

	// Idle runs on its own goroutine, so the selected state has a lock.
	mu       sync.Mutex
	folder   string // "" = nothing selected
	readOnly bool
	// quiet is set by a successful FETCH/STORE/SEARCH and makes the poll right
	// after it a no-op. Without it every UID FETCH would re-list the folder.
	quiet bool
	// view is the folder as the client knows it: sequence number = index + 1.
	// It changes only when the client has been told (EXISTS/EXPUNGE/FETCH).
	view []Message
}

var (
	_ imapserver.SessionMove        = (*imapSession)(nil)
	_ imapserver.SessionNamespace   = (*imapSession)(nil)
	_ imapserver.SessionAppendLimit = (*imapSession)(nil)
)

func no(code imap.ResponseCode, text string) error {
	return &imap.Error{Type: imap.StatusResponseTypeNo, Code: code, Text: text}
}

// fail turns a backend error into the NO the client sees.
func (s *imapSession) fail(op string, err error) error {
	var refused *RefusedError
	var status *StatusError
	switch {
	case errors.Is(err, ErrAuth):
		return imapserver.ErrAuthFailed
	case errors.As(err, &refused):
		return no(imap.ResponseCodeNoPerm, refused.Message)
	case errors.As(err, &status) && status.Status == 404:
		return no(imap.ResponseCodeNonExistent, "No such mailbox")
	case errors.As(err, &status) && status.Status == 422:
		return no("", status.Message)
	}
	s.log.Error("imap.backend_error", "op", op, "login", s.creds.Login, "error", err.Error())
	return no(imap.ResponseCodeUnavailable, "Temporary server error, try again later")
}

func canonFolder(name string) string {
	if strings.EqualFold(name, "INBOX") {
		return "INBOX"
	}
	return name
}

func hasFlag(flags []string, flag string) bool {
	for _, f := range flags {
		if strings.EqualFold(f, flag) {
			return true
		}
	}
	return false
}

func sameFlags(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for _, f := range a {
		if !hasFlag(b, f) {
			return false
		}
	}
	return true
}

func imapFlags(flags []string) []imap.Flag {
	out := make([]imap.Flag, len(flags))
	for i, f := range flags {
		out[i] = imap.Flag(f)
	}
	return out
}

func (s *imapSession) Close() error { return nil }

func (s *imapSession) Login(username, password string) error {
	c := Creds{Login: username, Password: password}
	if _, err := s.b.Session(c); err != nil {
		s.log.Warn("imap.login_failed", "login", username, "error", err.Error())
		return s.fail("session", err)
	}
	s.creds = c
	s.log.Info("imap.login", "login", username)
	return nil
}

func (s *imapSession) Namespace() (*imap.NamespaceData, error) {
	return &imap.NamespaceData{Personal: []imap.NamespaceDescriptor{{Delim: folderDelim}}}, nil
}

func (s *imapSession) AppendLimit() uint32 { return appendLimit }

// The folders are fixed (docs/Mail-Clients.md).
func (s *imapSession) Create(string, *imap.CreateOptions) error {
	return no(imap.ResponseCodeCannot, "Folders are fixed")
}
func (s *imapSession) Delete(string) error { return no(imap.ResponseCodeCannot, "Folders are fixed") }
func (s *imapSession) Rename(string, string, *imap.RenameOptions) error {
	return no(imap.ResponseCodeCannot, "Folders are fixed")
}
func (s *imapSession) Subscribe(string) error   { return nil }
func (s *imapSession) Unsubscribe(string) error { return nil }

func statusData(f *Folder, o *imap.StatusOptions) *imap.StatusData {
	d := &imap.StatusData{Mailbox: f.Name}
	if o.NumMessages {
		d.NumMessages = &f.Exists
	}
	if o.NumUnseen {
		d.NumUnseen = &f.Unseen
	}
	if o.NumRecent {
		d.NumRecent = new(uint32)
	}
	if o.UIDNext {
		d.UIDNext = imap.UID(f.UIDNext)
	}
	if o.UIDValidity {
		d.UIDValidity = f.UIDValidity
	}
	return d
}

func (s *imapSession) List(w *imapserver.ListWriter, ref string, patterns []string, o *imap.ListOptions) error {
	if len(patterns) == 0 { // LIST "" "": the client asks for the delimiter
		return w.WriteList(&imap.ListData{Attrs: []imap.MailboxAttr{imap.MailboxAttrNoSelect}, Delim: folderDelim})
	}
	folders, err := s.b.Folders(s.creds)
	if err != nil {
		return s.fail("folders", err)
	}
	for i := range folders {
		f := &folders[i]
		match := false
		for _, p := range patterns {
			match = match || imapserver.MatchList(f.Name, folderDelim, ref, p)
		}
		if !match || (o.SelectSpecialUse && f.SpecialUse == nil) {
			continue
		}
		d := &imap.ListData{Mailbox: f.Name, Delim: folderDelim}
		if f.SpecialUse != nil {
			d.Attrs = append(d.Attrs, imap.MailboxAttr(*f.SpecialUse))
		}
		if o.ReturnStatus != nil {
			d.Status = statusData(f, o.ReturnStatus)
		}
		if err := w.WriteList(d); err != nil {
			return err
		}
	}
	return nil
}

func (s *imapSession) findFolder(name string) (*Folder, error) {
	folders, err := s.b.Folders(s.creds)
	if err != nil {
		return nil, s.fail("folders", err)
	}
	for i := range folders {
		if folders[i].Name == canonFolder(name) {
			return &folders[i], nil
		}
	}
	return nil, no(imap.ResponseCodeNonExistent, "No such mailbox")
}

func (s *imapSession) Status(mailbox string, o *imap.StatusOptions) (*imap.StatusData, error) {
	f, err := s.findFolder(mailbox)
	if err != nil {
		return nil, err
	}
	return statusData(f, o), nil
}

func (s *imapSession) Select(mailbox string, o *imap.SelectOptions) (*imap.SelectData, error) {
	name := canonFolder(mailbox)
	fm, err := s.b.Messages(s.creds, name)
	if err != nil {
		return nil, s.fail("messages", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.folder, s.readOnly, s.view = name, o.ReadOnly, fm.Messages

	flags := []imap.Flag{imap.FlagSeen, imap.FlagAnswered, imap.FlagFlagged, imap.FlagDeleted, imap.FlagForwarded}
	d := &imap.SelectData{
		Flags:          flags,
		PermanentFlags: append(flags[:len(flags):len(flags)], imap.FlagWildcard),
		NumMessages:    uint32(len(s.view)),
		UIDNext:        imap.UID(fm.UIDNext),
		UIDValidity:    fm.UIDValidity,
	}
	for i, m := range s.view {
		if !hasFlag(m.Flags, `\Seen`) {
			d.FirstUnseenSeqNum = uint32(i + 1)
			break
		}
	}
	return d, nil
}

func (s *imapSession) Unselect() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.folder, s.view = "", nil
	return nil
}

func (s *imapSession) Append(mailbox string, r imap.LiteralReader, o *imap.AppendOptions) (*imap.AppendData, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	flags := make([]string, len(o.Flags))
	for i, f := range o.Flags {
		flags[i] = string(f)
	}
	uid, err := s.b.Append(s.creds, canonFolder(mailbox), raw, flags)
	if err != nil {
		return nil, s.fail("append", err)
	}
	f, err := s.findFolder(mailbox)
	if err != nil {
		return nil, nil // appended; only the APPENDUID code is lost
	}
	return &imap.AppendData{UID: imap.UID(uid), UIDValidity: f.UIDValidity}, nil
}

// pick resolves a sequence or UID set against the view and returns indexes
// into it, ascending. "*" is the last message.
func (s *imapSession) pick(numSet imap.NumSet) ([]int, error) {
	if imap.IsSearchRes(numSet) {
		return nil, no("", "SEARCHRES is not supported")
	}
	var out []int
	switch set := numSet.(type) {
	case imap.SeqSet:
		for i := range set {
			staticRange(&set[i].Start, &set[i].Stop, uint32(len(s.view)))
		}
		for i := range s.view {
			if set.Contains(uint32(i + 1)) {
				out = append(out, i)
			}
		}
	case imap.UIDSet:
		var max uint32
		if n := len(s.view); n > 0 {
			max = s.view[n-1].UID
		}
		for i := range set {
			staticRange((*uint32)(&set[i].Start), (*uint32)(&set[i].Stop), max)
		}
		for i, m := range s.view {
			if set.Contains(imap.UID(m.UID)) {
				out = append(out, i)
			}
		}
	}
	return out, nil
}

// staticRange replaces "*" (zero) with max, as imapmemserver does.
func staticRange(start, stop *uint32, max uint32) {
	dyn := *start == 0 || *stop == 0
	if *start == 0 {
		*start = max
	}
	if *stop == 0 {
		*stop = max
	}
	if dyn && *start > *stop {
		*start, *stop = *stop, *start
	}
}

func (s *imapSession) uids(idx []int) []uint32 {
	out := make([]uint32, len(idx))
	for i, n := range idx {
		out[i] = s.view[n].UID
	}
	return out
}

func (s *imapSession) applyFlags(changed []Message) {
	byUID := make(map[uint32][]string, len(changed))
	for _, m := range changed {
		byUID[m.UID] = m.Flags
	}
	for i := range s.view {
		if flags, ok := byUID[s.view[i].UID]; ok {
			s.view[i].Flags = flags
		}
	}
}

// remove drops uids from the view, highest sequence number first so the
// numbers the client is told stay valid.
func (s *imapSession) remove(uids []uint32, expunge func(seqNum uint32) error) error {
	gone := make(map[uint32]bool, len(uids))
	for _, uid := range uids {
		gone[uid] = true
	}
	for i := len(s.view) - 1; i >= 0; i-- {
		if !gone[s.view[i].UID] {
			continue
		}
		s.view = append(s.view[:i], s.view[i+1:]...)
		if err := expunge(uint32(i + 1)); err != nil {
			return err
		}
	}
	return nil
}

func headerOnly(bs *imap.FetchItemBodySection) bool {
	return bs.Specifier == imap.PartSpecifierHeader && len(bs.Part) == 0
}

func (s *imapSession) Fetch(w *imapserver.FetchWriter, numSet imap.NumSet, o *imap.FetchOptions) (err error) {
	if len(o.BinarySection)+len(o.BinarySectionSize) > 0 {
		return no("", "BINARY is not supported")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() { s.quiet = err == nil }()
	idx, err := s.pick(numSet)
	if err != nil {
		return err
	}

	needHeader, needRaw, markSeen := o.Envelope, o.BodyStructure != nil, false
	for _, bs := range o.BodySection {
		if headerOnly(bs) {
			needHeader = true
		} else {
			needRaw = true
		}
		markSeen = markSeen || !bs.Peek
	}

	writeFlags := o.Flags
	if markSeen && !s.readOnly {
		var unseen []uint32
		for _, i := range idx {
			if !hasFlag(s.view[i].Flags, `\Seen`) {
				unseen = append(unseen, s.view[i].UID)
			}
		}
		if len(unseen) > 0 {
			changed, err := s.b.Flags(s.creds, s.folder, unseen, "add", []string{`\Seen`})
			if err != nil {
				return s.fail("flags", err)
			}
			s.applyFlags(changed)
			writeFlags = true // the client must learn about the new \Seen
		}
	}

	// ponytail: one backend call per message, in order. A first sync of a big
	// folder is N header calls; a batch header endpoint in the contract is the
	// upgrade.
	for _, i := range idx {
		m := s.view[i]
		var src []byte // the header block, or the whole message when the body is needed
		switch {
		case needRaw:
			src, err = s.b.Raw(s.creds, s.folder, m.UID)
		case needHeader:
			src, err = s.b.Header(s.creds, s.folder, m.UID)
		}
		if isStatus(err, 404) {
			continue // expunged elsewhere; the next poll tells the client
		}
		if err != nil {
			return s.fail("fetch", err)
		}

		rw := w.CreateMessage(uint32(i + 1))
		if o.UID {
			rw.WriteUID(imap.UID(m.UID))
		}
		if writeFlags {
			rw.WriteFlags(imapFlags(m.Flags))
		}
		if o.InternalDate {
			rw.WriteInternalDate(m.InternalDate)
		}
		if o.RFC822Size {
			rw.WriteRFC822Size(m.Size)
		}
		if o.Envelope {
			h, _ := textproto.ReadHeader(bufio.NewReader(bytes.NewReader(src)))
			rw.WriteEnvelope(imapserver.ExtractEnvelope(h))
		}
		if o.BodyStructure != nil {
			rw.WriteBodyStructure(imapserver.ExtractBodyStructure(bytes.NewReader(src)))
		}
		for _, bs := range o.BodySection {
			var b []byte
			if bs.Specifier == imap.PartSpecifierNone && len(bs.Part) == 0 {
				// BODY[]: the bytes as stored, not the library's re-serialised header
				b = partial(src, bs.Partial)
			} else {
				b = imapserver.ExtractBodySection(bytes.NewReader(src), bs)
			}
			wc := rw.WriteBodySection(bs, int64(len(b)))
			_, werr := wc.Write(b)
			if err := errors.Join(werr, wc.Close()); err != nil {
				return err
			}
		}
		if err := rw.Close(); err != nil {
			return err
		}
	}
	return nil
}

func partial(b []byte, p *imap.SectionPartial) []byte {
	if p == nil {
		return b
	}
	if p.Offset > int64(len(b)) {
		return nil
	}
	return b[p.Offset:min(p.Offset+p.Size, int64(len(b)))]
}

func (s *imapSession) Store(w *imapserver.FetchWriter, numSet imap.NumSet, flags *imap.StoreFlags, _ *imap.StoreOptions) (err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() { s.quiet = err == nil }()
	if s.readOnly {
		return no("", "Mailbox is read-only")
	}
	idx, err := s.pick(numSet)
	if err != nil || len(idx) == 0 {
		return err
	}
	mode := map[imap.StoreFlagsOp]string{imap.StoreFlagsSet: "set", imap.StoreFlagsAdd: "add", imap.StoreFlagsDel: "remove"}[flags.Op]
	names := make([]string, len(flags.Flags))
	for i, f := range flags.Flags {
		names[i] = string(f)
	}
	changed, err := s.b.Flags(s.creds, s.folder, s.uids(idx), mode, names)
	if err != nil {
		return s.fail("flags", err)
	}
	s.applyFlags(changed)
	if flags.Silent {
		return nil
	}
	_, byUID := numSet.(imap.UIDSet)
	for _, i := range idx {
		rw := w.CreateMessage(uint32(i + 1))
		if byUID {
			rw.WriteUID(imap.UID(s.view[i].UID))
		}
		rw.WriteFlags(imapFlags(s.view[i].Flags))
		if err := rw.Close(); err != nil {
			return err
		}
	}
	return nil
}

func (s *imapSession) Expunge(w *imapserver.ExpungeWriter, uids *imap.UIDSet) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readOnly {
		return nil // CLOSE after EXAMINE lands here and must not delete
	}
	// Always by uid, never the contract's "{} = every \Deleted": the client
	// expunges only what it has itself seen as deleted.
	var doomed []uint32
	for _, m := range s.view {
		if hasFlag(m.Flags, `\Deleted`) && (uids == nil || uids.Contains(imap.UID(m.UID))) {
			doomed = append(doomed, m.UID)
		}
	}
	if len(doomed) == 0 {
		return nil
	}
	gone, err := s.b.Expunge(s.creds, s.folder, doomed)
	if err != nil {
		return s.fail("expunge", err)
	}
	return s.remove(gone, w.WriteExpunge)
}

// move is MOVE and COPY both: a message lives in exactly one folder here, so
// a copy cannot leave the original behind.
func (s *imapSession) move(numSet imap.NumSet, dest string) (*imap.CopyData, []uint32, error) {
	if s.readOnly {
		return nil, nil, no("", "Mailbox is read-only")
	}
	if canonFolder(dest) == s.folder {
		return nil, nil, no("", "Source and destination mailboxes are identical")
	}
	f, err := s.findFolder(dest)
	if err != nil {
		return nil, nil, err
	}
	idx, err := s.pick(numSet)
	if err != nil || len(idx) == 0 {
		return nil, nil, err
	}
	moved, err := s.b.Move(s.creds, s.folder, s.uids(idx), f.Name)
	if err != nil {
		return nil, nil, s.fail("move", err)
	}
	if len(moved) == 0 {
		return nil, nil, nil
	}
	data := &imap.CopyData{UIDValidity: f.UIDValidity}
	var gone []uint32
	for _, m := range moved {
		data.SourceUIDs.AddNum(imap.UID(m.UID))
		data.DestUIDs.AddNum(imap.UID(m.ToUID))
		gone = append(gone, m.UID)
	}
	return data, gone, nil
}

func (s *imapSession) Move(w *imapserver.MoveWriter, numSet imap.NumSet, dest string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, gone, err := s.move(numSet, dest)
	if err != nil || data == nil {
		return err
	}
	if err := w.WriteCopyData(data); err != nil {
		return err
	}
	return s.remove(gone, w.WriteExpunge)
}

// Copy is the same backend move (see move). The view is left alone: the poll
// that follows every COPY finds the messages gone and sends the EXPUNGEs.
func (s *imapSession) Copy(numSet imap.NumSet, dest string) (*imap.CopyData, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, _, err := s.move(numSet, dest)
	return data, err
}

// sync brings the client's view in line with the backend: EXPUNGE for what is
// gone, EXISTS for what is new, FETCH FLAGS for what changed. A backend
// failure is logged and skipped (an error here would drop the connection).
//
// ponytail: re-lists the whole folder on every poll and idle tick. Fine for
// thousands of messages; a "changes since" call in the contract is the
// upgrade.
func (s *imapSession) sync(w *imapserver.UpdateWriter) error {
	fm, err := s.b.Messages(s.creds, s.folder)
	if err != nil {
		s.log.Warn("imap.sync_failed", "login", s.creds.Login, "folder", s.folder, "error", err.Error())
		return nil
	}
	fresh := make(map[uint32]Message, len(fm.Messages))
	for _, m := range fm.Messages {
		fresh[m.UID] = m
	}
	var gone []uint32
	for _, m := range s.view {
		if _, ok := fresh[m.UID]; !ok {
			gone = append(gone, m.UID)
		}
	}
	if err := s.remove(gone, w.WriteExpunge); err != nil {
		return err
	}

	var changed []int
	for i, old := range s.view {
		if m := fresh[old.UID]; !sameFlags(old.Flags, m.Flags) {
			s.view[i].Flags = m.Flags
			changed = append(changed, i)
		}
		delete(fresh, old.UID)
	}
	known := len(s.view)
	for _, m := range fm.Messages {
		if _, isNew := fresh[m.UID]; isNew {
			s.view = append(s.view, m)
		}
	}
	if len(s.view) > known {
		if err := w.WriteNumMessages(uint32(len(s.view))); err != nil {
			return err
		}
	}
	for _, i := range changed {
		if err := w.WriteMessageFlags(uint32(i+1), imap.UID(s.view[i].UID), imapFlags(s.view[i].Flags)); err != nil {
			return err
		}
	}
	return nil
}

func (s *imapSession) Poll(w *imapserver.UpdateWriter, allowExpunge bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	quiet := s.quiet
	s.quiet = false
	// After FETCH/STORE/SEARCH an EXPUNGE is not allowed, so changes wait for
	// the next command.
	if s.folder == "" || !allowExpunge || quiet {
		return nil
	}
	return s.sync(w)
}

func (s *imapSession) Idle(w *imapserver.UpdateWriter, stop <-chan struct{}) error {
	interval := s.srv.IdleInterval
	if interval == 0 {
		interval = 20 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return nil
		case <-t.C:
			s.mu.Lock()
			var err error
			if s.folder != "" {
				err = s.sync(w)
			}
			s.mu.Unlock()
			if err != nil {
				return err
			}
		}
	}
}

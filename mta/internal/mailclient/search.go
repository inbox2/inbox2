package mailclient

import (
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

type matcher func(seqNum uint32, m *Message) bool

func (s *imapSession) Search(kind imapserver.NumKind, criteria *imap.SearchCriteria, o *imap.SearchOptions) (data *imap.SearchData, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() { s.quiet = err == nil }()
	if o.ReturnSave {
		return nil, no("", "SEARCHRES is not supported")
	}
	match, err := s.compile(criteria)
	if err != nil {
		return nil, err
	}
	data = &imap.SearchData{}
	var seqs imap.SeqSet
	var uids imap.UIDSet
	for i := range s.view {
		seq := uint32(i + 1)
		if !match(seq, &s.view[i]) {
			continue
		}
		num := seq
		if kind == imapserver.NumKindUID {
			num = s.view[i].UID
		}
		seqs.AddNum(seq)
		uids.AddNum(imap.UID(s.view[i].UID))
		if data.Min == 0 {
			data.Min = num
		}
		data.Max = num
		data.Count++
	}
	if kind == imapserver.NumKindUID {
		data.All = uids
	} else {
		data.All = seqs
	}
	return data, nil
}

// compile turns criteria into a matcher over the view. Flags, dates, sizes
// and number sets are answered from the view; text criteria ask the backend
// for the matching uids, one call per criterion. Anything the contract cannot
// answer is a NO, never a guess.
func (s *imapSession) compile(c *imap.SearchCriteria) (matcher, error) {
	unsupported := func(what string) (matcher, error) {
		return nil, no(imap.ResponseCodeCannot, "SEARCH "+what+" is not supported")
	}
	if c.ModSeq != nil {
		return unsupported("MODSEQ")
	}
	if !c.SentSince.IsZero() || !c.SentBefore.IsZero() {
		return unsupported("by sent date")
	}

	var remote []map[uint32]bool
	ask := func(field, value string) error {
		if value == "" {
			return no(imap.ResponseCodeCannot, "SEARCH with an empty string is not supported")
		}
		uids, err := s.b.Search(s.creds, s.folder, map[string]string{field: value})
		if err != nil {
			return s.fail("search", err)
		}
		set := make(map[uint32]bool, len(uids))
		for _, uid := range uids {
			set[uid] = true
		}
		remote = append(remote, set)
		return nil
	}
	for _, h := range c.Header {
		key := strings.ToLower(h.Key)
		if key != "from" && key != "to" && key != "subject" {
			return unsupported("on the " + h.Key + " header")
		}
		if err := ask(key, h.Value); err != nil {
			return nil, err
		}
	}
	for _, v := range c.Text {
		if err := ask("text", v); err != nil {
			return nil, err
		}
	}
	// ponytail: BODY is answered by the contract's "text", which also looks at
	// headers, so it can return a message that matches in a header only. A
	// "body" field in the search call is the upgrade.
	for _, v := range c.Body {
		if err := ask("text", v); err != nil {
			return nil, err
		}
	}

	for i := range c.SeqNum {
		if _, err := s.pick(c.SeqNum[i]); err != nil { // makes "*" static
			return nil, err
		}
	}
	for i := range c.UID {
		if _, err := s.pick(c.UID[i]); err != nil {
			return nil, err
		}
	}

	var nots []matcher
	for i := range c.Not {
		m, err := s.compile(&c.Not[i])
		if err != nil {
			return nil, err
		}
		nots = append(nots, m)
	}
	var ors [][2]matcher
	for i := range c.Or {
		a, err := s.compile(&c.Or[i][0])
		if err != nil {
			return nil, err
		}
		b, err := s.compile(&c.Or[i][1])
		if err != nil {
			return nil, err
		}
		ors = append(ors, [2]matcher{a, b})
	}

	return func(seq uint32, m *Message) bool {
		for i := range c.SeqNum {
			if !c.SeqNum[i].Contains(seq) {
				return false
			}
		}
		for _, set := range c.UID {
			if !set.Contains(imap.UID(m.UID)) {
				return false
			}
		}
		// Dates compare without time or zone (RFC 3501).
		d := m.InternalDate
		day := time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, time.UTC)
		if !c.Since.IsZero() && day.Before(c.Since) {
			return false
		}
		if !c.Before.IsZero() && !day.Before(c.Before) {
			return false
		}
		for _, f := range c.Flag {
			if !hasFlag(m.Flags, string(f)) {
				return false
			}
		}
		for _, f := range c.NotFlag {
			if hasFlag(m.Flags, string(f)) {
				return false
			}
		}
		if c.Larger != 0 && m.Size <= c.Larger {
			return false
		}
		if c.Smaller != 0 && m.Size >= c.Smaller {
			return false
		}
		for _, set := range remote {
			if !set[m.UID] {
				return false
			}
		}
		for _, not := range nots {
			if not(seq, m) {
				return false
			}
		}
		for _, or := range ors {
			if !or[0](seq, m) && !or[1](seq, m) {
				return false
			}
		}
		return true
	}, nil
}

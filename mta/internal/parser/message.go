// Package parser handles RFC 5322 + MIME message parsing for inbound mail.
package parser

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"strings"

	"golang.org/x/net/html/charset"
)

// maxMultipartDepth bounds nested multipart recursion to prevent a crafted
// message with deeply nested boundaries from exhausting the stack (DoS).
const maxMultipartDepth = 20

// maxParts bounds the total number of MIME parts processed per message so a
// message with a huge number of trivial parts can't pin CPU/memory.
const maxParts = 1000

// ParsedMessage holds the extracted contents of an email message.
type ParsedMessage struct {
	MessageID   string
	InReplyTo   string
	References  string
	From        string
	To          string
	CC          string
	Subject     string
	Date        string
	ContentType string
	BodyPlain   string
	BodyHTML    string
	Attachments []Attachment
}

// Attachment holds metadata for a MIME part that is an attachment.
type Attachment struct {
	Filename    string
	ContentType string
	SizeBytes   int64 // decoded size
	ContentID   string
	IsInline    bool
	// Content holds the decoded attachment bytes. Used by the E2EE seal path
	// (the MX encrypts + uploads attachments itself for sealed domains); the
	// plaintext path continues to re-extract from the raw MIME in Rails.
	Content []byte
}

// parseState carries cross-part counters through the recursive walk.
type parseState struct {
	parts int
}

// Parse reads raw RFC 5322 bytes and extracts headers, body parts, and attachment metadata.
func Parse(raw []byte) (*ParsedMessage, error) {
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("read message: %w", err)
	}

	parsed := &ParsedMessage{
		MessageID:   cleanMessageID(msg.Header.Get("Message-Id")),
		InReplyTo:   cleanMessageID(msg.Header.Get("In-Reply-To")),
		References:  msg.Header.Get("References"),
		From:        decodeHeader(msg.Header.Get("From")),
		To:          decodeHeader(msg.Header.Get("To")),
		CC:          decodeHeader(msg.Header.Get("Cc")),
		Subject:     decodeHeader(msg.Header.Get("Subject")),
		Date:        msg.Header.Get("Date"),
		ContentType: msg.Header.Get("Content-Type"),
	}

	ct := msg.Header.Get("Content-Type")
	if ct == "" {
		ct = "text/plain"
	}

	state := &parseState{}
	cte := msg.Header.Get("Content-Transfer-Encoding")
	parsePart(msg.Body, ct, cte, msg.Header.Get("Content-Disposition"), parsed, state, 0)

	return parsed, nil
}

// parsePart dispatches a single MIME part by media type, recursing into
// multipart containers. contentType/cte are the raw header values for this part.
func parsePart(body io.Reader, contentType, cte, disposition string, parsed *ParsedMessage, state *parseState, depth int) {
	if state.parts >= maxParts {
		return
	}
	state.parts++

	mediaType, params, err := mime.ParseMediaType(contentType)
	if err != nil {
		// Unparseable Content-Type: treat as plain text.
		if data, ok := readDecoded(body, cte); ok && parsed.BodyPlain == "" {
			parsed.BodyPlain = string(data)
		}
		return
	}

	if strings.HasPrefix(mediaType, "multipart/") {
		if depth >= maxMultipartDepth {
			return
		}
		parseMultipart(body, params["boundary"], parsed, state, depth+1)
		return
	}

	// Determine whether this leaf part is an attachment/inline rather than body.
	dispType := ""
	var dispParams map[string]string
	if disposition != "" {
		dispType, dispParams, _ = mime.ParseMediaType(disposition)
	}
	// Any non-text leaf is an attachment regardless of disposition — binary
	// content (e.g. a bare application/zip DMARC report) must never land in
	// the body columns, where NUL bytes make the Postgres insert fail.
	isInline := dispType == "inline" && !strings.HasPrefix(mediaType, "text/")
	isAttachment := dispType == "attachment" ||
		(!isInline && !strings.HasPrefix(mediaType, "text/"))

	if isAttachment || isInline {
		data, _ := readDecoded(body, cte)
		filename := ""
		if dispParams != nil {
			filename = dispParams["filename"]
		}
		if filename == "" {
			filename = params["name"]
		}
		parsed.Attachments = append(parsed.Attachments, Attachment{
			Filename:    decodeHeader(filename),
			ContentType: mediaType,
			SizeBytes:   int64(len(data)),
			IsInline:    isInline,
			Content:     data,
		})
		return
	}

	// Text body parts — first wins. Transfer decoding (readDecoded) yields the
	// part's bytes in their ORIGINAL charset; convert to UTF-8 before storing
	// or an iso-8859-1 body lands in the database as mojibake.
	data, ok := readDecoded(body, cte)
	if !ok {
		return
	}
	text := string(toUTF8(data, params["charset"]))
	switch mediaType {
	case "text/html":
		if parsed.BodyHTML == "" {
			parsed.BodyHTML = text
		}
	default: // text/plain and anything else treated as text
		if parsed.BodyPlain == "" {
			parsed.BodyPlain = text
		}
	}
}

// toUTF8 converts body bytes from the declared charset to UTF-8. UTF-8 /
// us-ascii (or an absent/unknown label) pass through unchanged.
func toUTF8(data []byte, label string) []byte {
	switch strings.ToLower(strings.TrimSpace(label)) {
	case "", "utf-8", "utf8", "us-ascii", "ascii":
		return data
	}
	r, err := charset.NewReaderLabel(label, bytes.NewReader(data))
	if err != nil {
		return data
	}
	converted, err := io.ReadAll(r)
	if err != nil {
		return data
	}
	return converted
}

func parseMultipart(r io.Reader, boundary string, parsed *ParsedMessage, state *parseState, depth int) {
	if boundary == "" {
		// Malformed multipart with no boundary — salvage as plain text.
		if data, err := io.ReadAll(r); err == nil && parsed.BodyPlain == "" {
			parsed.BodyPlain = string(data)
		}
		return
	}

	mr := multipart.NewReader(r, boundary)
	for {
		if state.parts >= maxParts {
			return
		}
		part, err := mr.NextRawPart()
		if err != nil {
			// io.EOF (normal) or a malformed boundary — stop walking this level.
			return
		}

		partCT := part.Header.Get("Content-Type")
		if partCT == "" {
			partCT = "text/plain"
		}
		partCTE := part.Header.Get("Content-Transfer-Encoding")
		partDisp := part.Header.Get("Content-Disposition")
		partCID := part.Header.Get("Content-Id")

		// NextRawPart leaves transfer-encoding intact; we decode in parsePart.
		if cid := cleanMessageID(partCID); cid != "" {
			// Capture Content-Id for inline attachments by wrapping the reader's
			// downstream attachment append. We handle this by parsing then patching.
			before := len(parsed.Attachments)
			parsePart(part, partCT, partCTE, partDisp, parsed, state, depth)
			if len(parsed.Attachments) > before {
				parsed.Attachments[len(parsed.Attachments)-1].ContentID = cid
			}
		} else {
			parsePart(part, partCT, partCTE, partDisp, parsed, state, depth)
		}
		part.Close()
	}
}

// readDecoded reads a part body and decodes it according to the
// Content-Transfer-Encoding. On decode failure it falls back to the raw bytes
// so we never lose content. The bool reports whether any data was read.
func readDecoded(r io.Reader, cte string) ([]byte, bool) {
	switch strings.ToLower(strings.TrimSpace(cte)) {
	case "base64":
		raw, err := io.ReadAll(r)
		if err != nil {
			return nil, false
		}
		decoded, derr := decodeBase64Lenient(raw)
		if derr != nil {
			return raw, true // fall back to raw on malformed base64
		}
		return decoded, true
	case "quoted-printable":
		decoded, err := io.ReadAll(quotedprintable.NewReader(r))
		if err != nil {
			return decoded, len(decoded) > 0 // partial decode is better than nothing
		}
		return decoded, true
	default: // 7bit, 8bit, binary, empty
		raw, err := io.ReadAll(r)
		if err != nil {
			return nil, false
		}
		return raw, true
	}
}

// decodeBase64Lenient strips CR/LF/whitespace (common in MIME base64) before decoding.
func decodeBase64Lenient(raw []byte) ([]byte, error) {
	cleaned := bytes.Map(func(r rune) rune {
		switch r {
		case '\r', '\n', ' ', '\t':
			return -1
		}
		return r
	}, raw)
	return base64.StdEncoding.DecodeString(string(cleaned))
}

func cleanMessageID(id string) string {
	// Keep the angle brackets — they are part of the RFC 5322 Message-ID format.
	return strings.TrimSpace(id)
}

func decodeHeader(s string) string {
	dec := &mime.WordDecoder{
		CharsetReader: charsetReader,
	}
	decoded, err := dec.DecodeHeader(s)
	if err != nil {
		return s // return as-is on decode failure
	}
	return decoded
}

// charsetReader converts a non-UTF-8 charset to UTF-8 for RFC 2047 header decoding.
func charsetReader(label string, input io.Reader) (io.Reader, error) {
	return charset.NewReaderLabel(label, input)
}

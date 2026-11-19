package parser_test

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/inbox2/mta/internal/parser"
)

func readCorpus(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "testdata", "corpus", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read corpus file %s: %v", name, err)
	}
	return data
}

func TestParse_PlainText(t *testing.T) {
	raw := readCorpus(t, "plain.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if msg.MessageID != "<plain-001@example.com>" {
		t.Errorf("MessageID = %q, want %q", msg.MessageID, "<plain-001@example.com>")
	}
	if msg.From != "Alice Sender <alice@example.com>" {
		t.Errorf("From = %q", msg.From)
	}
	if msg.To != "support@acme.com" {
		t.Errorf("To = %q", msg.To)
	}
	if msg.Subject != "Plain text test message" {
		t.Errorf("Subject = %q", msg.Subject)
	}
	if !strings.Contains(msg.BodyPlain, "plain text test message") {
		t.Errorf("BodyPlain doesn't contain expected text: %q", msg.BodyPlain)
	}
	if msg.BodyHTML != "" {
		t.Errorf("BodyHTML should be empty for plain text, got %q", msg.BodyHTML)
	}
	if len(msg.Attachments) != 0 {
		t.Errorf("Attachments = %d, want 0", len(msg.Attachments))
	}
}

func TestParse_HTML(t *testing.T) {
	raw := readCorpus(t, "html.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if msg.MessageID != "<html-001@example.com>" {
		t.Errorf("MessageID = %q", msg.MessageID)
	}
	if !strings.Contains(msg.BodyHTML, "<strong>HTML</strong>") {
		t.Errorf("BodyHTML doesn't contain expected HTML: %q", msg.BodyHTML)
	}
	if msg.BodyPlain != "" {
		t.Errorf("BodyPlain should be empty for HTML-only, got %q", msg.BodyPlain)
	}
}

func TestParse_Multipart(t *testing.T) {
	raw := readCorpus(t, "multipart.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if msg.MessageID != "<multipart-001@example.com>" {
		t.Errorf("MessageID = %q", msg.MessageID)
	}
	if msg.InReplyTo != "<plain-001@example.com>" {
		t.Errorf("InReplyTo = %q, want %q", msg.InReplyTo, "<plain-001@example.com>")
	}
	if msg.References != "<plain-001@example.com>" {
		t.Errorf("References = %q", msg.References)
	}
	if !strings.Contains(msg.BodyPlain, "plain text version") {
		t.Errorf("BodyPlain missing expected text: %q", msg.BodyPlain)
	}
	if !strings.Contains(msg.BodyHTML, "<em>HTML</em>") {
		t.Errorf("BodyHTML missing expected HTML: %q", msg.BodyHTML)
	}
}

func TestParse_Attachment(t *testing.T) {
	raw := readCorpus(t, "attachment.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if msg.MessageID != "<attach-001@example.com>" {
		t.Errorf("MessageID = %q", msg.MessageID)
	}
	if msg.CC != "info@acme.com" {
		t.Errorf("CC = %q, want %q", msg.CC, "info@acme.com")
	}
	if !strings.Contains(msg.BodyPlain, "attached document") {
		t.Errorf("BodyPlain missing expected text: %q", msg.BodyPlain)
	}
	if len(msg.Attachments) != 1 {
		t.Fatalf("Attachments = %d, want 1", len(msg.Attachments))
	}
	att := msg.Attachments[0]
	if att.Filename != "report.pdf" {
		t.Errorf("attachment filename = %q, want %q", att.Filename, "report.pdf")
	}
	if att.ContentType != "application/pdf" {
		t.Errorf("attachment content-type = %q, want %q", att.ContentType, "application/pdf")
	}
	if att.SizeBytes <= 0 {
		t.Errorf("attachment size = %d, want > 0", att.SizeBytes)
	}
}

// Google DMARC aggregate reports are single-part application/zip messages —
// the zip must become an attachment (via the top-level Content-Disposition),
// never binary body text, whose NUL bytes would fail the Postgres insert.
func TestParse_TopLevelZipAttachment(t *testing.T) {
	zip := []byte{0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02, 0x03}
	raw := strings.Join([]string{
		"From: noreply-dmarc-support@google.com",
		"To: dmarc@inbox2.com",
		"Subject: Report domain: inbox2.com Submitter: google.com",
		"Message-ID: <zip-001@google.com>",
		`Content-Type: application/zip; name="google.com!inbox2.com.zip"`,
		`Content-Disposition: attachment; filename="google.com!inbox2.com.zip"`,
		"Content-Transfer-Encoding: base64",
		"",
		base64.StdEncoding.EncodeToString(zip),
	}, "\r\n")

	msg, err := parser.Parse([]byte(raw))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if msg.BodyPlain != "" {
		t.Errorf("BodyPlain = %q, want empty (zip must not leak into body)", msg.BodyPlain)
	}
	if len(msg.Attachments) != 1 {
		t.Fatalf("Attachments = %d, want 1", len(msg.Attachments))
	}
	if got := msg.Attachments[0].Filename; got != "google.com!inbox2.com.zip" {
		t.Errorf("attachment filename = %q", got)
	}
}

func TestParse_Unicode(t *testing.T) {
	raw := readCorpus(t, "unicode.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if msg.MessageID != "<unicode-001@example.fr>" {
		t.Errorf("MessageID = %q", msg.MessageID)
	}
	// RFC 2047 encoded From header should be decoded
	if !strings.Contains(msg.From, "Émilie Dupont") {
		t.Errorf("From not decoded correctly: %q", msg.From)
	}
	// RFC 2047 encoded Subject should be decoded
	if !strings.Contains(msg.Subject, "Réponse") {
		t.Errorf("Subject not decoded correctly: %q", msg.Subject)
	}
	if !strings.Contains(msg.BodyPlain, "日本語テスト") {
		t.Errorf("BodyPlain missing Unicode text: %q", msg.BodyPlain)
	}
}

func TestParse_Malformed(t *testing.T) {
	raw := readCorpus(t, "malformed.eml")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v (should succeed for malformed messages)", err)
	}

	if msg.MessageID != "<malformed-001@example.com>" {
		t.Errorf("MessageID = %q", msg.MessageID)
	}
	if msg.Subject != "Malformed message" {
		t.Errorf("Subject = %q", msg.Subject)
	}
	if !strings.Contains(msg.BodyPlain, "minimal headers") {
		t.Errorf("BodyPlain missing expected text: %q", msg.BodyPlain)
	}
}

func TestParse_QuotedPrintableBody(t *testing.T) {
	raw := []byte("From: a@example.com\r\n" +
		"To: support@acme.com\r\n" +
		"Subject: QP\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n" +
		"Content-Transfer-Encoding: quoted-printable\r\n" +
		"\r\n" +
		"Caf=C3=A9 = the place=\r\n" +
		" to be\r\n")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !strings.Contains(msg.BodyPlain, "Café") {
		t.Errorf("quoted-printable body not decoded: %q", msg.BodyPlain)
	}
	// Soft line break (trailing =) should be removed.
	if strings.Contains(msg.BodyPlain, "=\r\n") {
		t.Errorf("soft line break not collapsed: %q", msg.BodyPlain)
	}
}

func TestParse_Latin1BodyConvertedToUTF8(t *testing.T) {
	// "Café" with é as the single iso-8859-1 byte 0xE9 (invalid as UTF-8).
	raw := []byte("From: a@example.com\r\n" +
		"To: support@acme.com\r\n" +
		"Subject: Latin-1\r\n" +
		"Content-Type: text/plain; charset=ISO-8859-1\r\n" +
		"Content-Transfer-Encoding: quoted-printable\r\n" +
		"\r\n" +
		"Caf=E9\r\n")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !strings.Contains(msg.BodyPlain, "Café") {
		t.Errorf("iso-8859-1 body not converted to UTF-8: %q", msg.BodyPlain)
	}
}

func TestParse_Windows1252HTMLBodyConvertedToUTF8(t *testing.T) {
	// Curly apostrophe (0x92) only exists in windows-1252, not iso-8859-1/UTF-8.
	raw := []byte("From: a@example.com\r\n" +
		"To: support@acme.com\r\n" +
		"Subject: CP1252\r\n" +
		"Content-Type: text/html; charset=windows-1252\r\n" +
		"Content-Transfer-Encoding: quoted-printable\r\n" +
		"\r\n" +
		"<p>It=92s here</p>\r\n")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !strings.Contains(msg.BodyHTML, "It’s here") {
		t.Errorf("windows-1252 body not converted to UTF-8: %q", msg.BodyHTML)
	}
}

func TestParse_Base64AttachmentDecodedSize(t *testing.T) {
	// "Hello, World!" base64-encoded is 13 decoded bytes / 20 encoded chars.
	raw := []byte("From: a@example.com\r\n" +
		"To: support@acme.com\r\n" +
		"Subject: b64\r\n" +
		"Content-Type: multipart/mixed; boundary=bnd\r\n" +
		"\r\n" +
		"--bnd\r\n" +
		"Content-Type: text/plain\r\n\r\nsee attachment\r\n" +
		"--bnd\r\n" +
		"Content-Type: application/octet-stream; name=\"f.bin\"\r\n" +
		"Content-Disposition: attachment; filename=\"f.bin\"\r\n" +
		"Content-Transfer-Encoding: base64\r\n\r\n" +
		"SGVsbG8sIFdvcmxkIQ==\r\n" +
		"--bnd--\r\n")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(msg.Attachments) != 1 {
		t.Fatalf("attachments = %d, want 1", len(msg.Attachments))
	}
	if msg.Attachments[0].SizeBytes != 13 {
		t.Errorf("decoded attachment size = %d, want 13 (decoded, not encoded)", msg.Attachments[0].SizeBytes)
	}
}

func TestParse_DeeplyNestedMultipartTerminates(t *testing.T) {
	// A pathological deeply-nested multipart must not exhaust the stack; Parse
	// should return within the depth cap rather than recursing unbounded.
	var b strings.Builder
	b.WriteString("From: a@example.com\r\nTo: support@acme.com\r\nSubject: nested\r\n")
	const depth = 200
	for i := 0; i < depth; i++ {
		b.WriteString(fmt.Sprintf("Content-Type: multipart/mixed; boundary=b%d\r\n", i))
		if i == 0 {
			b.WriteString("\r\n")
		}
		b.WriteString(fmt.Sprintf("--b%d\r\n", i))
	}
	msg, err := parser.Parse([]byte(b.String()))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	_ = msg // success = it returned without crashing
}

func TestParse_EmptyBody(t *testing.T) {
	raw := []byte("From: test@example.com\r\nTo: dest@acme.com\r\nSubject: Empty\r\nMessage-ID: <empty@test>\r\n\r\n")
	msg, err := parser.Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if msg.BodyPlain != "" {
		t.Errorf("BodyPlain = %q, want empty", msg.BodyPlain)
	}
}

package smtpd

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/inbox2/mta/internal/parser"
	"github.com/inbox2/mta/internal/queue"
	"github.com/inbox2/mta/internal/seal"
	"github.com/inbox2/mta/internal/spool"
	"golang.org/x/crypto/nacl/box"
)

func testDomainInfo(pub string) *queue.DomainInfo {
	return &queue.DomainInfo{
		Found: true, OrgID: 7, OrgKey: "org_test", Status: "receiving_mail",
		E2EE: true, E2EEPublicKey: pub, E2EEKeyVersion: 1, DomainID: 42,
	}
}

func testParsed() *parser.ParsedMessage {
	return &parser.ParsedMessage{
		MessageID:  "<seal-1@sender.example>",
		InReplyTo:  "<parent@sender.example>",
		References: "<root@sender.example> <parent@sender.example>",
		From:       "Eve Sender <eve@sender.example>",
		To:         "team@sealed.test",
		Subject:    "Re: SECRET-MARKER-SUBJECT layoffs",
		Date:       "Thu, 02 Jul 2026 10:00:00 +0000",
		BodyPlain:  "SECRET-MARKER-BODY the plan is attached",
		BodyHTML:   "<p>SECRET-MARKER-BODY the plan is attached</p>",
		Attachments: []parser.Attachment{{
			Filename: "SECRET-MARKER-FILENAME.xlsx", ContentType: "application/vnd.ms-excel",
			SizeBytes: 20, Content: []byte("SECRET-MARKER-ATTACHMENT-BYTES"),
		}},
	}
}

// The core Phase-C guarantee: the durable payload contains no plaintext
// content, subject, sender, filename, or raw MIME — and the client can decrypt
// everything back with the domain secret key.
func TestSealMessageDurablePayloadHasNoPlaintext(t *testing.T) {
	pub, priv, _ := box.GenerateKey(rand.Reader)
	store, _ := spool.NewStore(t.TempDir())
	sl := &sealer{hmacKey: []byte("threading-key"), store: store}

	msg, excerpt, warnings, err := sl.sealMessage(
		testParsed(), testDomainInfo(base64.StdEncoding.EncodeToString(pub[:])),
		[]string{"team@sealed.test"}, time.Now().UTC(), 1234,
		queue.AuthenticationResults{
			SPF:   queue.AuthResult{Result: "pass", Domain: "sender.example"},
			DKIM:  queue.AuthResult{Result: "pass", Domain: "sender.example", Selector: "s1"},
			DMARC: queue.AuthResult{Result: "pass", Domain: "sender.example", Policy: "reject"},
		}, nil)
	if err != nil {
		t.Fatalf("sealMessage: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}

	durable, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{
		"SECRET-MARKER", "eve@sender.example", "Eve Sender", "sender.example",
		"seal-1@", "layoffs", "plan is attached",
	} {
		if strings.Contains(string(durable), marker) {
			t.Errorf("durable payload leaks %q", marker)
		}
	}
	if msg.EncryptionScheme != EncryptionSchemeSealedBoxV2 {
		t.Fatalf("scheme = %q", msg.EncryptionScheme)
	}
	if msg.RawMessageB64 != "" || msg.Body.Plain != "" || msg.Headers.Subject != "" || msg.Envelope.MailFrom != "" {
		t.Fatal("plaintext fields not zeroed")
	}
	if len(msg.Sealed.RefsHmac) != 2 || msg.Sealed.MsgidHmac == "" || msg.Sealed.SubjectHmac == "" {
		t.Fatalf("threading HMACs missing: %+v", msg.Sealed)
	}

	// Subject HMAC uses the NORMALIZED subject (strips Re:).
	wantSubject := seal.ThreadingHMAC([]byte("threading-key"), "SECRET-MARKER-SUBJECT layoffs")
	if msg.Sealed.SubjectHmac != wantSubject {
		t.Fatal("subject HMAC not computed over the normalized subject")
	}

	// Client-side decrypt round-trip with the domain secret key.
	sealedDEK, _ := base64.StdEncoding.DecodeString(msg.Sealed.SealedDEK)
	dek, ok := box.OpenAnonymous(nil, sealedDEK, pub, priv)
	if !ok {
		t.Fatal("could not unseal DEK")
	}
	aad := seal.AAD(42, 1, msg.Sealed.MsgidHmac)
	headerNonce, _ := base64.StdEncoding.DecodeString(msg.Sealed.HeaderNonce)
	headerCT, _ := base64.StdEncoding.DecodeString(msg.Sealed.HeaderCiphertext)
	headerJSON, err := seal.Decrypt(dek, headerNonce, headerCT, seal.PartAAD(aad, seal.RoleHeader))
	if err != nil {
		t.Fatalf("header decrypt: %v", err)
	}
	var header sealedHeader
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		t.Fatal(err)
	}
	if header.Subject != "Re: SECRET-MARKER-SUBJECT layoffs" || !strings.Contains(header.From, "eve@sender.example") {
		t.Fatalf("header round-trip mismatch: %+v", header)
	}
	if !strings.Contains(header.Snippet, "SECRET-MARKER-BODY") {
		t.Fatalf("snippet missing: %+v", header)
	}

	bodyNonce, _ := base64.StdEncoding.DecodeString(msg.Sealed.BodyNonce)
	bodyCT, _ := base64.StdEncoding.DecodeString(msg.Sealed.BodyCiphertext)
	bodyJSON, err := seal.Decrypt(dek, bodyNonce, bodyCT, seal.PartAAD(aad, seal.RoleBody))
	if err != nil {
		t.Fatalf("body decrypt: %v", err)
	}
	var body sealedBody
	json.Unmarshal(bodyJSON, &body)
	if body.Plain != "SECRET-MARKER-BODY the plan is attached" {
		t.Fatalf("body round-trip mismatch: %q", body.Plain)
	}

	// Attachment: spooled ciphertext only; decrypts to the original bytes.
	if len(msg.Sealed.Attachments) != 1 {
		t.Fatalf("expected 1 sealed attachment, got %d", len(msg.Sealed.Attachments))
	}
	att := msg.Sealed.Attachments[0]
	pending, _ := store.Pending()
	if len(pending) != 1 || pending[0][0] != att.ObjectKey {
		t.Fatalf("attachment not spooled under its object key: %+v", pending)
	}
	spooled, err := readFile(pending[0][1])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(spooled), "SECRET-MARKER") {
		t.Fatal("spooled attachment is not ciphertext")
	}
	attAAD := append(append([]byte{}, aad...), []byte("|att:0")...)
	contentNonce, _ := base64.StdEncoding.DecodeString(att.ContentNonce)
	plainAtt, err := seal.Decrypt(dek, contentNonce, spooled, attAAD)
	if err != nil {
		t.Fatalf("attachment decrypt: %v", err)
	}
	if string(plainAtt) != "SECRET-MARKER-ATTACHMENT-BYTES" {
		t.Fatal("attachment round-trip mismatch")
	}
	nameAAD := append(append([]byte{}, attAAD...), []byte("|name")...)
	nameNonce, _ := base64.StdEncoding.DecodeString(att.FilenameNonce)
	nameCT, _ := base64.StdEncoding.DecodeString(att.SealedFilename)
	name, err := seal.Decrypt(dek, nameNonce, nameCT, nameAAD)
	if err != nil || string(name) != "SECRET-MARKER-FILENAME.xlsx" {
		t.Fatalf("filename round-trip failed: %v %q", err, name)
	}

	// Triage excerpt (transient stream) carries the plaintext by design.
	if !strings.Contains(excerpt.Excerpt, "SECRET-MARKER-BODY") || excerpt.MsgidHmac != msg.Sealed.MsgidHmac {
		t.Fatalf("triage excerpt malformed: %+v", excerpt)
	}
}

// AAD binding: ciphertext grafted onto a different message/domain/version must
// not decrypt.
func TestSealMessageAADTamperFailsDecrypt(t *testing.T) {
	pub, priv, _ := box.GenerateKey(rand.Reader)
	store, _ := spool.NewStore(t.TempDir())
	sl := &sealer{hmacKey: []byte("threading-key"), store: store}

	msg, _, _, err := sl.sealMessage(
		testParsed(), testDomainInfo(base64.StdEncoding.EncodeToString(pub[:])),
		[]string{"team@sealed.test"}, time.Now().UTC(), 1234, queue.AuthenticationResults{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	sealedDEK, _ := base64.StdEncoding.DecodeString(msg.Sealed.SealedDEK)
	dek, _ := box.OpenAnonymous(nil, sealedDEK, pub, priv)
	nonce, _ := base64.StdEncoding.DecodeString(msg.Sealed.BodyNonce)
	ct, _ := base64.StdEncoding.DecodeString(msg.Sealed.BodyCiphertext)

	for _, aad := range [][]byte{
		seal.AAD(43, 1, msg.Sealed.MsgidHmac),
		seal.AAD(42, 2, msg.Sealed.MsgidHmac),
		seal.AAD(42, 1, "other-hmac"),
	} {
		if _, err := seal.Decrypt(dek, nonce, ct, aad); err == nil {
			t.Fatalf("tampered AAD %q accepted", aad)
		}
	}
}

func TestSealWithoutSpoolStripsAttachments(t *testing.T) {
	pub, _, _ := box.GenerateKey(rand.Reader)
	sl := &sealer{hmacKey: []byte("k")} // no store

	msg, _, warnings, err := sl.sealMessage(
		testParsed(), testDomainInfo(base64.StdEncoding.EncodeToString(pub[:])),
		[]string{"team@sealed.test"}, time.Now().UTC(), 10, queue.AuthenticationResults{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(msg.Sealed.Attachments) != 0 {
		t.Fatal("attachments should be stripped without a spool")
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "stripped") {
		t.Fatalf("expected a loud strip warning, got %v", warnings)
	}
}

func TestSenderFilters(t *testing.T) {
	info := &queue.DomainInfo{
		Blocklist: []string{"spammer@bad.example", "bad-domain.example"},
		Allowlist: []string{"friend@good.example"},
	}
	if !senderBlocked(info, "spammer@bad.example", "") {
		t.Fatal("exact blocklist miss")
	}
	if !senderBlocked(info, "<anyone@bad-domain.example>", "") {
		t.Fatal("domain blocklist miss")
	}
	if !senderBlocked(info, "innocent@ok.example", "spammer@bad.example") {
		t.Fatal("header-From blocklist miss")
	}
	if senderBlocked(info, "innocent@ok.example", "") {
		t.Fatal("false positive")
	}
	if !senderAllowlisted(info, "friend@good.example", "") {
		t.Fatal("allowlist miss")
	}
}

func TestIsReport(t *testing.T) {
	if !isReport(`multipart/report; report-type=delivery-status; boundary="b"`) {
		t.Fatal("DSN not detected")
	}
	if isReport("multipart/alternative") || isReport("text/plain") {
		t.Fatal("false report detection")
	}
}

func readFile(path string) ([]byte, error) { return os.ReadFile(path) }

// The per-domain notification-preview opt-in (docs/E2EE.md): exactly from +
// subject ride the durable payload in plaintext — and nothing else does.
func TestSealMessageNotificationPreviewOptIn(t *testing.T) {
	pub, _, _ := box.GenerateKey(rand.Reader)
	store, _ := spool.NewStore(t.TempDir())
	sl := &sealer{hmacKey: []byte("threading-key"), store: store}

	info := testDomainInfo(base64.StdEncoding.EncodeToString(pub[:]))
	info.E2EENotificationPreview = true

	msg, _, _, err := sl.sealMessage(
		testParsed(), info, []string{"team@sealed.test"}, time.Now().UTC(), 10,
		queue.AuthenticationResults{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if msg.Sealed.NotificationPreview == nil {
		t.Fatal("preview missing despite opt-in")
	}
	if msg.Sealed.NotificationPreview.From != "Eve Sender <eve@sender.example>" ||
		msg.Sealed.NotificationPreview.Subject != "Re: SECRET-MARKER-SUBJECT layoffs" {
		t.Fatalf("preview content wrong: %+v", msg.Sealed.NotificationPreview)
	}

	// The leak is bounded to those two fields: body/snippet/filename stay sealed.
	durable, _ := json.Marshal(msg)
	for _, marker := range []string{"SECRET-MARKER-BODY", "SECRET-MARKER-FILENAME", "plan is attached"} {
		if strings.Contains(string(durable), marker) {
			t.Errorf("preview opt-in leaked more than from+subject: %q", marker)
		}
	}

	// And with the flag off (the default), nothing at all — pinned by
	// TestSealMessageDurablePayloadHasNoPlaintext.
	info.E2EENotificationPreview = false
	msg2, _, _, _ := sl.sealMessage(testParsed(), info, []string{"team@sealed.test"},
		time.Now().UTC(), 10, queue.AuthenticationResults{}, nil)
	if msg2.Sealed.NotificationPreview != nil {
		t.Fatal("preview present without opt-in")
	}
}

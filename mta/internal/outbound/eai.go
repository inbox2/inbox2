package outbound

import (
	"fmt"
	"net/smtp"
	"strings"

	"golang.org/x/net/idna"
)

// Internationalized email (EAI, RFC 6531) on the delivery side.
//
// Two separate problems hide behind "the address has non-ASCII in it":
//
//   - A Unicode DOMAIN (سعيد@مثال.السعودية). DNS speaks A-labels, so the MX
//     lookup and the RCPT TO domain must be punycode. This needs no cooperation
//     from the receiving server — the wire form is plain ASCII.
//   - A Unicode LOCAL PART (مستخدم@example.com). This cannot be transliterated;
//     it can only go out over a session where the server advertised SMTPUTF8,
//     and the envelope command must carry the SMTPUTF8 parameter.
//
// The stdlib net/smtp client has no SMTPUTF8 support, so mailUTF8 issues the
// MAIL FROM itself over the client's textproto connection.

// toASCIIDomain converts a Unicode domain to its punycode (A-label) form.
// Returns the input unchanged when it is already ASCII or cannot be converted,
// so a malformed domain fails later at MX lookup with its original spelling in
// the diagnostic rather than an opaque idna error.
func toASCIIDomain(domain string) string {
	if isASCII(domain) {
		return domain
	}
	ascii, err := idna.Lookup.ToASCII(domain)
	if err != nil {
		return domain
	}
	return ascii
}

// punycodeAddress rewrites the domain half of an addr-spec to punycode, leaving
// the local part exactly as it is — local parts are octet-preserving and must
// never be transformed.
func punycodeAddress(addr string) string {
	at := strings.LastIndex(addr, "@")
	if at < 0 {
		return addr
	}
	return addr[:at+1] + toASCIIDomain(addr[at+1:])
}

// needsSMTPUTF8 reports whether any envelope address has a non-ASCII LOCAL
// part, which is the only case that requires the RFC 6531 extension. A Unicode
// domain does not — punycodeAddress has already made it ASCII on the wire.
func needsSMTPUTF8(mailFrom string, rcptTo []string) bool {
	if !isASCIILocalPart(mailFrom) {
		return true
	}
	for _, r := range rcptTo {
		if !isASCIILocalPart(r) {
			return true
		}
	}
	return false
}

func isASCIILocalPart(addr string) bool {
	at := strings.LastIndex(addr, "@")
	if at < 0 {
		return isASCII(addr)
	}
	return isASCII(addr[:at])
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 127 {
			return false
		}
	}
	return true
}

// mailUTF8 sends `MAIL FROM:<addr> SMTPUTF8`. net/smtp's Mail() has no way to
// append the parameter, so we drive the textproto connection directly — the
// same thing Client.Mail does internally, plus the extension keyword.
func mailUTF8(client *smtp.Client, from string) error {
	id, err := client.Text.Cmd("MAIL FROM:<%s> SMTPUTF8", from)
	if err != nil {
		return err
	}
	client.Text.StartResponse(id)
	defer client.Text.EndResponse(id)
	_, _, err = client.Text.ReadResponse(250)
	return err
}

// sendEnvelope issues MAIL FROM + RCPT TO, using SMTPUTF8 when the addresses
// need it. Domains are punycoded on the way out regardless.
func sendEnvelope(client *smtp.Client, mailFrom string, rcptTo []string) error {
	from := punycodeAddress(mailFrom)
	rcpts := make([]string, len(rcptTo))
	for i, r := range rcptTo {
		rcpts[i] = punycodeAddress(r)
	}

	if needsSMTPUTF8(from, rcpts) {
		if ok, _ := client.Extension("SMTPUTF8"); !ok {
			// Permanent by nature: this server can never accept this address,
			// and retrying the same envelope will fail identically.
			return fmt.Errorf("550 recipient requires SMTPUTF8 (RFC 6531) which the server does not offer")
		}
		if err := mailUTF8(client, from); err != nil {
			return err
		}
	} else if err := client.Mail(from); err != nil {
		return err
	}

	for _, rcpt := range rcpts {
		if err := client.Rcpt(rcpt); err != nil {
			return err
		}
	}
	return nil
}

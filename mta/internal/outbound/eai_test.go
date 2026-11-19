package outbound

import "testing"

func TestPunycodeAddress(t *testing.T) {
	cases := []struct{ in, want string }{
		{"user@example.com", "user@example.com"},
		{"user@مثال.السعودية", "user@xn--mgbh0fb.xn--mgberp4a5d4ar"},
		{"user@例え.jp", "user@xn--r8jz45g.jp"},
		// Local part is octet-preserving — never transformed, even when Unicode.
		{"مستخدم@example.com", "مستخدم@example.com"},
		{"not-an-address", "not-an-address"},
	}
	for _, c := range cases {
		if got := punycodeAddress(c.in); got != c.want {
			t.Errorf("punycodeAddress(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNeedsSMTPUTF8(t *testing.T) {
	// A Unicode domain alone never needs the extension — punycode covers it.
	if needsSMTPUTF8("a@xn--r8jz45g.jp", []string{"b@example.com"}) {
		t.Error("ASCII local parts must not require SMTPUTF8")
	}
	if !needsSMTPUTF8("a@example.com", []string{"مستخدم@example.com"}) {
		t.Error("non-ASCII recipient local part must require SMTPUTF8")
	}
	if !needsSMTPUTF8("发件人@example.com", []string{"b@example.com"}) {
		t.Error("non-ASCII sender local part must require SMTPUTF8")
	}
}

func TestExtractRecipientDomainPunycodes(t *testing.T) {
	got := extractRecipientDomain([]string{"user@例え.jp"})
	if got != "xn--r8jz45g.jp" {
		t.Errorf("extractRecipientDomain = %q, want punycode A-label", got)
	}
}

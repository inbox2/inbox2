package seal

import (
	"regexp"
	"strings"
)

// NormalizeSubject is the Go port of the Rails SubjectNormalizer (RFC 5256 §2.1
// "base subject" with extended international prefixes). The two implementations
// MUST stay byte-identical — the threading subject_hmac is computed here for
// sealed mail and in Rails for plaintext mail, and a divergence silently breaks
// mixed-mode threading. Parity is pinned by testdata/subject_vectors.json,
// generated from the Ruby class and asserted by both test suites.

// Latin-script reply/forward prefixes (case-insensitive) — keep in sync with
// SubjectNormalizer::LATIN_PREFIXES.
var latinPrefixes = []string{
	"re", "fw", "fwd", "sv", "aw", "tr", "vs", "ref", "rif", "ynt", "odp", "atb", "enc", "doorst",
	"va", "vá", "res", "fs", "vb", "rv", "pd", "wg", "rép", "rep", "beantw", "antw", "svar",
}

// Non-Latin prefixes — keep in sync with SubjectNormalizer::NON_LATIN_PREFIXES.
var nonLatinPrefixes = []string{
	"回复", "转发", "回覆", "轉寄", "답장", "전달", "返信", "転送",
	"השב", "הועבר", "رد", "إعادة توجيه", "उत्तर", "अग्रेषित",
	"ΑΠ", "ΠΡΘ", "НА", "ОТВ", "ПЕР",
}

var (
	prefixPattern  = buildPrefixPattern()
	listTagPattern = regexp.MustCompile(`^\s*\[[^\]]{1,40}\]\s*`)
	spacesPattern  = regexp.MustCompile(`\s+`)
)

func buildPrefixPattern() *regexp.Regexp {
	esc := func(list []string) string {
		parts := make([]string, len(list))
		for i, p := range list {
			parts[i] = regexp.QuoteMeta(p)
		}
		return strings.Join(parts, "|")
	}
	// (?i) case-insensitive to mirror Ruby's /i (Go regexp is Unicode-aware for
	// simple case folding, matching Ruby's behavior for these prefixes).
	return regexp.MustCompile(`(?i)^\s*(?:(?:` + esc(latinPrefixes) + `)(?:\[\d+\])?|(?:` + esc(nonLatinPrefixes) + `)(?:\[\d+\])?):\s*`)
}

// NormalizeSubject reduces a subject to its base form for threading comparison:
// strips reply/forward prefixes and mailing-list tags, collapses whitespace.
// Never returns anything but a plain trimmed string.
func NormalizeSubject(subject string) string {
	s := strings.TrimSpace(subject)
	s = spacesPattern.ReplaceAllString(s, " ")

	for {
		before := s
		s = listTagPattern.ReplaceAllString(s, "")
		s = prefixPattern.ReplaceAllString(s, "")
		s = strings.TrimSpace(s)
		if s == before {
			break
		}
	}
	return s
}

package seal

import (
	"regexp"
	"strconv"
	"strings"
)

// Minimal port of the Rails SnippetBuilder for the sealed header snippet. Exact
// byte-parity with Ruby is NOT required here (unlike NormalizeSubject): the
// snippet only ever lives inside the header ciphertext for client display —
// Rails never computes one for sealed mail, so there is nothing to diverge
// from. Same shape: strip markup + invisible padding, decode common entities,
// collapse whitespace, cap at 200 chars.

const snippetMaxLength = 200

var (
	styleScriptRe = regexp.MustCompile(`(?is)<(style|script|head)[^>]*>.*?</\s*(style|script|head)\s*>`)
	tagRe         = regexp.MustCompile(`(?s)<[^>]*>`)
	entityRe      = regexp.MustCompile(`&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);`)
	invisibleRe   = regexp.MustCompile(`[\x{200B}-\x{200D}\x{2060}\x{FEFF}\x{00AD}\x{034F}]`)
)

var namedEntities = map[string]string{
	"amp": "&", "quot": `"`, "apos": "'",
	"nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
	"rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
	"mdash": "—", "ndash": "–", "hellip": "…", "bull": "•",
}

// BuildSnippet derives the preview text sealed into the header: plain body
// preferred, HTML stripped otherwise.
func BuildSnippet(plain, html string) string {
	text := plain
	if strings.TrimSpace(text) == "" {
		text = stripHTML(html)
	}
	text = invisibleRe.ReplaceAllString(text, "")
	text = spacesPattern.ReplaceAllString(text, " ")
	text = strings.TrimSpace(text)

	runes := []rune(text)
	if len(runes) > snippetMaxLength {
		text = strings.TrimSpace(string(runes[:snippetMaxLength]))
	}
	return text
}

func stripHTML(html string) string {
	if strings.TrimSpace(html) == "" {
		return ""
	}
	s := styleScriptRe.ReplaceAllString(html, " ")
	s = tagRe.ReplaceAllString(s, " ")
	return entityRe.ReplaceAllStringFunc(s, decodeEntity)
}

// decodeEntity resolves one HTML entity. Angle brackets deliberately stay
// encoded (mirrors Ruby): consumers may re-parse snippets as HTML, and a
// decoded bracket could turn escaped text back into live markup.
func decodeEntity(m string) string {
	body := m[1 : len(m)-1]
	if strings.HasPrefix(body, "#") {
		var n int64
		var err error
		if strings.HasPrefix(body, "#x") || strings.HasPrefix(body, "#X") {
			n, err = strconv.ParseInt(body[2:], 16, 32)
		} else {
			n, err = strconv.ParseInt(body[1:], 10, 32)
		}
		if err != nil || n <= 0 || n == '<' || n == '>' {
			return " "
		}
		return string(rune(n))
	}
	if r, ok := namedEntities[strings.ToLower(body)]; ok {
		return r
	}
	return " "
}

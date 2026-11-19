//! Small helpers shared across the sync module (the interactive-provider and
//! calendar paths in particular).

use serde_json::Value;
use unicode_normalization::UnicodeNormalization;

/// Normalize text to Unicode NFC before it is stored or searched.
///
/// Senders transmit either normalization form — a macOS-composed Arabic "أ" or
/// Vietnamese "ế" often arrives decomposed — and two byte-different spellings of
/// the same word never match each other in a `LIKE`/FTS search. Normalizing on
/// the way into the store gives every row one spelling; queries normalize the
/// same way. Cheap: NFC on already-normalized text is a scan with no allocation
/// beyond the result.
pub(crate) fn nfc(s: &str) -> String {
    s.nfc().collect()
}

/// [`nfc`] over an optional column value.
pub(crate) fn nfc_opt(s: &Option<String>) -> Option<String> {
    s.as_deref().map(nfc)
}

/// Clean-up for a header that is displayed as text (Subject, From): NFC plus
/// HTML-entity decoding — senders do put `&amp;`/`&gt;` in these, and Gmail
/// shows them decoded. Applied on the way into the store only; older rows
/// keep whatever they had.
pub(crate) fn header_text(s: &str) -> String {
    crate::sync::threading::decode_text_entities(&nfc(s))
}

/// [`header_text`] over an optional column value.
pub(crate) fn header_text_opt(s: &Option<String>) -> Option<String> {
    s.as_deref().map(header_text)
}

/// Read a string field from a JSON object, returning `None` if absent or not a
/// string. (Returns an owned `String` — the common need at the call sites.)
pub(crate) fn json_str(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(String::from)
}

/// `v[key]` as an owned array, or empty when the key is absent or not an array.
/// Centralises the `.get(k).and_then(as_array).cloned().unwrap_or_default()`
/// dance repeated across the JSON provider adapters.
pub(crate) fn json_array(v: &Value, key: &str) -> Vec<Value> {
    v.get(key)
        .and_then(|a| a.as_array())
        .cloned()
        .unwrap_or_default()
}

/// `v[key]` as a bool, returning `None` if absent or not a JSON bool.
pub(crate) fn json_bool(v: &Value, key: &str) -> Option<bool> {
    v.get(key).and_then(|x| x.as_bool())
}

/// Look up an RFC-822 header (case-insensitive) in a provider's JSON header
/// array of `{name, value}` objects — the shape both Gmail (`payload.headers`)
/// and Graph (`internetMessageHeaders`) use in their message payloads.
pub(crate) fn header_value(headers: Option<&Value>, name: &str) -> Option<String> {
    headers.and_then(|h| h.as_array()).and_then(|hs| {
        hs.iter().find_map(|h| {
            let n = h.get("name").and_then(|v| v.as_str())?;
            if n.eq_ignore_ascii_case(name) {
                h.get("value").and_then(|v| v.as_str()).map(String::from)
            } else {
                None
            }
        })
    })
}

/// Percent-encode a string for use in a URL query/path component (RFC 3986
/// unreserved set passes through; everything else is `%XX`-escaped).
pub(crate) fn urlencode(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => c.to_string(),
            _ => format!("%{:02X}", c as u32),
        })
        .collect()
}

/// Render a plain-text mail body as the HTML alternative part.
///
/// Every mobile/CLI send arrives with `body_html: None` (their composers are
/// plain `TextEditor`s), and the MIME builder then emits a `text/plain`
/// singlepart — so a reply typed on the phone reaches the recipient as a
/// text-only mail with a `> `-prefixed quote that no client collapses. Building
/// the alternative here keeps one plain source of truth and still ships the
/// HTML part every modern client expects.
///
/// ponytail: escaping + linkifying + quote-blockquoting, no markdown. Reach for
/// a real renderer only if the composers ever gain rich text.
pub(crate) fn plain_to_html(text: &str) -> String {
    let mut out = String::from(
        "<div style=\"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;color:#111\">",
    );
    let lines: Vec<&str> = text.split('\n').map(|l| l.trim_end_matches('\r')).collect();
    let mut i = 0;
    while i < lines.len() {
        if is_quoted(lines[i]) {
            // Consecutive `> ` lines become one blockquote, so Gmail/Outlook
            // collapse the quoted original instead of inlining it verbatim.
            let start = i;
            while i < lines.len() && is_quoted(lines[i]) {
                i += 1;
            }
            out.push_str("<blockquote type=\"cite\" style=\"margin:0 0 0 4px;padding-left:10px;border-left:2px solid #ccc;color:#555\">");
            out.push_str(&render_lines(lines[start..i].iter().map(|l| unquote(l))));
            out.push_str("</blockquote>");
        } else {
            let start = i;
            while i < lines.len() && !is_quoted(lines[i]) {
                i += 1;
            }
            out.push_str(&render_lines(lines[start..i].iter().map(|l| l.to_string())));
        }
    }
    out.push_str("</div>");
    out
}

fn is_quoted(line: &str) -> bool {
    line.starts_with('>')
}

/// Strip one level of `> ` quoting (nested levels stay as text inside the block).
fn unquote(line: &str) -> String {
    line.strip_prefix("> ").or_else(|| line.strip_prefix('>')).unwrap_or(line).to_string()
}

fn render_lines(lines: impl Iterator<Item = String>) -> String {
    lines.map(|l| linkify(&escape_html(&l))).collect::<Vec<_>>().join("<br>")
}

fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Wrap bare `http(s)://` runs in anchors — plain-text clients autolink URLs,
/// HTML ones mostly don't, so without this a pasted link goes dead.
fn linkify(escaped: &str) -> String {
    escaped
        .split(' ')
        .map(|tok| {
            if !(tok.starts_with("http://") || tok.starts_with("https://")) {
                return tok.to_string();
            }
            let url = tok.trim_end_matches(['.', ',', ')', ';', ':', '!', '?']);
            let tail = &tok[url.len()..];
            format!("<a href=\"{url}\">{url}</a>{tail}")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn json_str_reads_present_string_only() {
        let v = json!({ "a": "x", "b": 3, "c": null });
        assert_eq!(json_str(&v, "a"), Some("x".to_string()));
        assert_eq!(json_str(&v, "b"), None);
        assert_eq!(json_str(&v, "c"), None);
        assert_eq!(json_str(&v, "missing"), None);
    }

    #[test]
    fn json_array_returns_array_or_empty() {
        let v = json!({ "value": [1, 2, 3], "scalar": 7 });
        assert_eq!(json_array(&v, "value").len(), 3);
        // Missing key → empty; present-but-not-array → empty (no panic).
        assert!(json_array(&v, "missing").is_empty());
        assert!(json_array(&v, "scalar").is_empty());
    }

    #[test]
    fn json_bool_reads_present_bool_only() {
        let v = json!({ "isRead": true, "isDraft": false, "x": "true" });
        assert_eq!(json_bool(&v, "isRead"), Some(true));
        assert_eq!(json_bool(&v, "isDraft"), Some(false));
        // String "true" is not a JSON bool → None.
        assert_eq!(json_bool(&v, "x"), None);
        assert_eq!(json_bool(&v, "missing"), None);
    }

    #[test]
    fn urlencode_escapes_reserved_chars() {
        assert_eq!(urlencode("a b/c?"), "a%20b%2Fc%3F");
        assert_eq!(urlencode("safe-_.~AZ09"), "safe-_.~AZ09");
    }

    #[test]
    fn nfc_composes_decomposed_text() {
        // Arabic alef + combining hamza-above → precomposed alef-with-hamza.
        let decomposed = "\u{0627}\u{0654}";
        assert_eq!(nfc(decomposed), "\u{0623}");
        // Already-composed text is a fixed point.
        assert_eq!(nfc("\u{0623}hmed"), "\u{0623}hmed");
        // Untouched scripts pass through.
        assert_eq!(nfc("订单 report"), "订单 report");
    }

    #[test]
    fn plain_to_html_escapes_breaks_quotes_and_links() {
        let html = plain_to_html("Hi <you> & co\nsee https://x.test/a?b=1.\n\n> On Mon, A wrote:\n> old text");
        assert!(html.contains("Hi &lt;you&gt; &amp; co<br>"), "{html}");
        assert!(html.contains("<a href=\"https://x.test/a?b=1\">https://x.test/a?b=1</a>."), "{html}");
        // The quoted run is one blockquote with the `> ` markers stripped.
        assert_eq!(html.matches("<blockquote").count(), 1, "{html}");
        assert!(html.contains("On Mon, A wrote:<br>old text</blockquote>"), "{html}");
        assert!(!html.contains("&gt; old"), "{html}");
    }
}

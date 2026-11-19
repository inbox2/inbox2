//! Strip quoted / forwarded trailers from a plain-text email body.
//!
//! Used wherever a message's OWN words must be isolated from the prior thread it quotes:
//! the triage summariser input (so summaries — and the spoken read-out built from them —
//! describe the new message, not the quoted history) and the Bridge `draft_reply` context.
//! Mirrors the line patterns in the web quote detector
//! (`packages/email-body/src/quoteDetector.js`).
//!
//! Everything from the first quote boundary onward is dropped, as is a leading `>`-quoted
//! block. A fully-quoted body (a bare forward) strips to empty on purpose: the caller adds
//! the subject/sender context, and we never want the forwarded block read aloud or summed.

/// Drop quoted/forwarded content, returning only the lines before the first quote boundary.
/// May return an empty string when the whole body is quoted (a bare forward).
pub(crate) fn strip_quoted_text(text: &str) -> String {
    let mut kept: Vec<&str> = Vec::new();
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        let next = lines.get(i + 1).map_or("", |l| l.trim());
        if is_quote_boundary(line) || opens_two_line_header(line, next) {
            break;
        }
        kept.push(line);
    }
    while kept.last().is_some_and(|l| l.trim().is_empty()) {
        kept.pop();
    }
    kept.join("\n").trim().to_string()
}

/// Quote headers that only read as one across two lines: a Gmail attribution wrapped at
/// 76 columns ("On Fri, Sep 25, 2026 at 6:55 PM Fraz <f@x.ae>" / "wrote:"), and an Outlook
/// header block with no divider above it ("From: …" / "Sent: …", Gmail's `*From:*` too).
fn opens_two_line_header(line: &str, next: &str) -> bool {
    let t = line.trim();
    let lower = t.to_ascii_lowercase();
    if lower.starts_with("on ") && is_quote_boundary(&format!("{t} {next}")) {
        return true;
    }
    let bare = |s: &str| s.trim_start_matches('*').to_ascii_lowercase();
    bare(t).starts_with("from:") && ["sent:", "date:"].iter().any(|k| bare(next).starts_with(k))
}

/// True when `line` opens a quoted/forwarded section: a `>`-prefixed quote line, an Outlook
/// underscore divider, a "Begin forwarded message:" marker, an "-----Original Message-----"
/// / "Forwarded message" banner (incl. NL/FR/DE variants), or an "On … wrote:" attribution
/// line (incl. FR/DE/NL/ES/PT/IT variants).
pub(crate) fn is_quote_boundary(line: &str) -> bool {
    let t = line.trim();
    if t.is_empty() {
        return false;
    }
    // Plain-text reply quoting ("> previous line").
    if t.starts_with('>') {
        return true;
    }
    // Outlook horizontal divider preceding the quoted header block.
    if t.len() >= 10 && t.chars().all(|c| c == '_') {
        return true;
    }
    let lower = t.to_ascii_lowercase();
    // Apple Mail forward marker.
    if lower.starts_with("begin forwarded message") {
        return true;
    }
    // "-----Original Message-----" / "----- Forwarded message -----" + localized variants.
    let banner = lower.trim_matches(|c| c == '-' || c == ' ' || c == '_');
    if matches!(
        banner,
        "original message"
            | "forwarded message"
            | "oorspronkelijk bericht"
            | "message original"
            | "ursprüngliche nachricht"
    ) {
        return true;
    }
    // "On <date>, <name> wrote:" attribution.
    if lower.starts_with("on ") && lower.ends_with("wrote:") && t.len() <= 200 {
        return true;
    }
    // Localized attribution lines, all ending in a colon ("… a écrit :", "… schrieb …:").
    if t.len() <= 200
        && lower.ends_with(':')
        && (lower.contains("a écrit")
            || lower.contains("schrieb")
            || lower.contains("schreef")
            || lower.contains("escribió")
            || lower.contains("escreveu")
            || lower.contains("ha scritto"))
    {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_reply_attribution_and_quoted_lines() {
        let body = "Sounds good, let's ship it.\n\n\
                    On Mon, Jan 1, 2024 at 9:00 AM Bob <b@x.com> wrote:\n\
                    > Are we still on?\n> Let me know.";
        assert_eq!(strip_quoted_text(body), "Sounds good, let's ship it.");
    }

    #[test]
    fn bare_forward_strips_to_empty() {
        let body = "---------- Forwarded message ---------\n\
                    From: Gas Co <billing@gas.example>\n\
                    Subject: gas invoice\n\n\
                    Your invoice for €42 is due.";
        assert_eq!(strip_quoted_text(body), "");
    }

    #[test]
    fn apple_mail_begin_forwarded_marker() {
        let body = "FYI below.\n\nBegin forwarded message:\nFrom: someone";
        assert_eq!(strip_quoted_text(body), "FYI below.");
    }

    #[test]
    fn keeps_unquoted_body_intact() {
        let body = "Hi team,\n\nLunch at noon?\n\nThanks";
        assert_eq!(strip_quoted_text(body), "Hi team,\n\nLunch at noon?\n\nThanks");
    }

    #[test]
    fn wrapped_attribution_and_outlook_header() {
        let gmail = "Can you test these points?\n\nOn Fri, Sep 25, 2026 at 6:55 PM Fraz <f@x.ae>\nwrote:\n\n> Dear Rizwan,";
        assert_eq!(strip_quoted_text(gmail), "Can you test these points?");
        let outlook = "Noted.\n\n*From:* Rizwan [mailto:r@x.com]\n*Sent:* Friday, 25 September 2026 11:49 AM\nTo: Fraz";
        assert_eq!(strip_quoted_text(outlook), "Noted.");
    }
}

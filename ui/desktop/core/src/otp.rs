//! Sign-in codes and one-click sign-in links in a just-arrived email, so every
//! client's alert can offer Copy / Open link instead of making you open the
//! thread (docs/Notifications.md "Sign-in codes and links"). The Ruby twin is
//! `api/app/services/otp_detector.rb` (inbox2-hosted mail); both are locked to
//! the `otp` cases in `fixtures/parity/fixtures.json`.
//!
//! ponytail: keyword + proximity heuristics, English and Dutch only. Misses a
//! code that sits far from any keyword; upgrade to a Jev judgment if it misfires.

use regex::Regex;
use serde::Serialize;
use std::sync::OnceLock;

/// What the alert offers: a code to copy, or a link to open (and its host, so
/// the card can say where it goes).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Otp {
    Code { code: String },
    Link { link: String, host: String },
}

macro_rules! re {
    ($pat:expr) => {{
        static RE: OnceLock<Regex> = OnceLock::new();
        RE.get_or_init(|| Regex::new($pat).expect("otp regex"))
    }};
}

// The mail has to be about signing in at all — this keeps a promo's "use code
// SAVE20" or an "Order confirmation" off the card. Bare "confirm" or
// "verified" is not enough: an order or a review says those too.
fn sign_in() -> &'static Regex {
    re!(r"(?i-u)verification|\bverify\b|one[- ]time|\botp\b|passcode|security code|sign[- ]?in|log[- ]?in|\blogin\b|two[- ]factor|\b2fa\b|authenticat|confirm your (?:e-?mail|account|sign|log)|magic link|inlog|toegangscode|verificatie")
}
// Words a code follows ("Your code is 482910", "Uw code: 4829"). `code\b`
// keeps "passcode"/"verificatiecode" but not "codes"/"codebase" — a commit
// message reading "Sign-in codes…" made a GitLab mail a sign-in card.
fn code_word() -> &'static Regex {
    re!(r"(?i-u)code\b|\bpin\b|\botp\b")
}
// A code: "123 456"/"123-456", 4–8 digits, or 6–8 upper-case letters + digits
// (the mixed rule is checked in `is_code`).
fn code() -> &'static Regex {
    re!(r"(?-u)\b(\d{3}[ -]\d{3}|\d{4,8}|[A-Z0-9]{6,8})\b")
}
fn digits() -> &'static Regex {
    re!(r"(?-u)\b(\d{4,8})\b")
}
fn url_any() -> &'static Regex {
    re!(r"https?://\S+")
}
fn url_https() -> &'static Regex {
    re!(r#"https://[^\s<>"')\]]+"#)
}
fn anchor() -> &'static Regex {
    re!(r#"(?i)<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#)
}
fn tag() -> &'static Regex {
    re!(r"<[^>]*>")
}
/// How far into the text a sign-in cue may sit for a link (not a code) to count.
const LINK_LEAD_CHARS: usize = 600;

// An unsubscribe footer: bulk mail, never a one-off sign-in link.
fn bulk() -> &'static Regex {
    re!(r"(?i-u)unsubscribe|uitschrijven|afmelden voor|afmelden|manage (?:your )?(?:e-?mail )?preferences|e-?mail preferences|nieuwsbrief")
}

// Link ranking, strongest first: the button names the sign-in, then the URL
// does, then a generic "Continue"/"Confirm" button.
fn link_text() -> &'static Regex {
    re!(r"(?i-u)sign[- ]?in|log[- ]?in|\blogin\b|verify|magic|activate|inloggen|aanmelden|bevestig")
}
fn link_href() -> &'static Regex {
    re!(r"(?i-u)token|magic|verif|validat|login|signin|sign-in|auth|confirm")
}
fn link_text_weak() -> &'static Regex {
    re!(r"(?i-u)continue|confirm|open")
}
fn not_this_link() -> &'static Regex {
    re!(r"(?i-u)unsubscribe|privacy|terms|help|support|preferences|afmelden")
}

/// The first `n` chars of `s` (char-safe).
fn head(s: &str, n: usize) -> &str {
    s.char_indices().nth(n).map_or(s, |(i, _)| &s[..i])
}

/// All digits, or upper-case letters mixed with digits ("X7K2QP", not "UNIQUE").
fn is_code(c: &str) -> bool {
    let has_digit = c.bytes().any(|b| b.is_ascii_digit());
    has_digit && (c.bytes().all(|b| b.is_ascii_digit() || b == b' ' || b == b'-') || c.bytes().any(|b| b.is_ascii_uppercase()))
}

fn find_code(subject: &str, text: &str) -> Option<String> {
    for m in code_word().find_iter(text) {
        let window = head(&text[m.end()..], 80);
        if let Some(c) = code().captures_iter(window).map(|c| c[1].to_string()).find(|c| is_code(c)) {
            return Some(c);
        }
    }
    // "482910 is your Instagram code" — the code comes first, in a subject that
    // says so itself. Not any number in any subject: "Failed pipeline | 30931582"
    // is a commit hash.
    if !code_word().is_match(subject) && !sign_in().is_match(subject) {
        return None;
    }
    digits().captures(subject).map(|c| c[1].to_string())
}

fn decode(s: &str) -> String {
    s.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'")
}

fn find_link(html: &str, text: &str) -> Option<String> {
    let anchors: Vec<(String, String)> = anchor()
        .captures_iter(html)
        .map(|c| (decode(c[1].trim()), tag().replace_all(&c[2], " ").into_owned()))
        .filter(|(href, label)| {
            href.get(..8).is_some_and(|p| p.eq_ignore_ascii_case("https://"))
                && !not_this_link().is_match(href)
                && !not_this_link().is_match(label)
        })
        .collect();
    let pick = |f: &dyn Fn(&(String, String)) -> bool| anchors.iter().find(|a| f(a)).map(|a| a.0.clone());
    pick(&|a| link_text().is_match(&a.1))
        .or_else(|| pick(&|a| link_href().is_match(&a.0)))
        .or_else(|| pick(&|a| link_text_weak().is_match(&a.1)))
        // Plain-text mail: a bare URL that looks like a sign-in link.
        .or_else(|| {
            url_https()
                .find_iter(text)
                .map(|m| m.as_str())
                .find(|u| link_href().is_match(u) && !not_this_link().is_match(u))
                .map(str::to_string)
        })
}

/// `Code` or `Link` for a sign-in mail, else None. A code wins when the mail
/// carries both.
pub fn detect(subject: Option<&str>, body_plain: Option<&str>, body_html: Option<&str>, snippet: Option<&str>) -> Option<Otp> {
    let subject = subject.unwrap_or("");
    let text = head(body_plain.filter(|s| !s.is_empty()).or(snippet).unwrap_or(""), 5000);
    if !sign_in().is_match(subject) && !sign_in().is_match(text) {
        return None;
    }
    // URLs out first: a token in a magic link ("…/login/eyJ…") is not a code.
    if let Some(code) = find_code(subject, &url_any().replace_all(text, " ")) {
        return Some(Otp::Code { code });
    }
    // A link needs more than a sign-in word anywhere (a newsletter's footer "log in
    // to your account" + its tracking links read as a magic link, 2026-10-20): the
    // subject names the sign-in, or the opening lines do in a mail with no
    // unsubscribe footer. Codes keep the looser gate — a bare code is rarely marketing.
    let lead_ok = sign_in().is_match(head(text, LINK_LEAD_CHARS)) && !bulk().is_match(text)
        && !bulk().is_match(head(body_html.unwrap_or(""), 200_000));
    if !sign_in().is_match(subject) && !lead_ok {
        return None;
    }
    let link = find_link(head(body_html.unwrap_or(""), 200_000), text)?;
    let url = url::Url::parse(&link).ok()?;
    let host = match (url.host_str(), url.port()) {
        (Some(h), Some(p)) => format!("{h}:{p}"),
        (Some(h), None) => h.to_string(),
        _ => return None,
    };
    Some(Otp::Link { link, host })
}

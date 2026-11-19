//! Email-to-voice: turn one thread's LATEST message into a spoken read-out. The summary is
//! the triage worker's PREGENERATED summary — the one-line `ai_summary_short` for a quick
//! "what's my latest email", or the fuller `ai_summary_medium` for an explicit "read the
//! full email aloud". Both are used as-is when current for the latest message (instant, no
//! model round-trip); on a cache miss the caller regenerates with the SAME triage
//! summarizer ([`crate::ai_worker::summarize_conversation`]) — never a second hand-rolled
//! prompt. The body text here is only thread context for `draft_reply`.
//!
//! Used two ways: behind the email-detail audio button (FFI `bridge_email_voice`) and as
//! the agent's read-aloud path for voice commands.

use super::brief::sender_name;
use crate::sync::store::SyncStore;
use crate::sync::threading::normalize_subject;
use rusqlite::{params, OptionalExtension};

const STATUS_FILTER: &str = "status NOT IN ('archived','trash','spam')";

/// Body budget fed to the JIT summariser (matches the triage worker's order of
/// magnitude — enough to capture the ask without overflowing the prompt).
const SUMMARY_BODY_CHARS: usize = 1200;

/// Upper bound on the plain text read aloud after the summary, so a giant newsletter
/// doesn't turn into a ten-minute monologue. Personal mail is well under this.
const READOUT_BODY_CHARS: usize = 4000;

/// One thread reduced to what the spoken read-out needs: its latest message's text plus
/// the stored medium summary when it's still current for that message.
pub struct ThreadReadout {
    pub subject: String,
    /// The latest message's key — the staleness anchor for the stored summary.
    pub latest_key: String,
    /// Display name of the latest sender ("you" when the inbox owner sent it).
    who: String,
    /// Full plain text of the latest message, cleaned + capped at [`READOUT_BODY_CHARS`].
    body_text: String,
    /// `ai_summary_medium` IF it was written for this exact latest message (else `None`).
    /// The fuller summary, read for an explicit "read the full email aloud".
    stored_medium: Option<String>,
    /// `ai_summary_short` IF current — the one-liner, read for a quick "what's my latest
    /// email" query.
    stored_short: Option<String>,
    /// Provenance of the stored summary (`triage_source`, whose `model:…` part
    /// names the summary engine; none = the deterministic snippet) — lets the read-out decide whether the cache is
    /// good enough for the currently-selected lane.
    stored_source: Option<String>,
}

impl ThreadReadout {
    /// The pregenerated MEDIUM summary when it's current for the latest message — read for
    /// an explicit "read the full email aloud". `None` ⇒ regenerate via the triage
    /// summarizer (see [`super::agent::email_voice_text`]).
    pub fn fresh_medium(&self) -> Option<&str> {
        self.stored_medium.as_deref().filter(|s| !s.trim().is_empty())
    }

    /// The pregenerated SHORT (one-line) summary when current — read for a quick "what's
    /// my latest email" query. `None` ⇒ regenerate.
    pub fn fresh_short(&self) -> Option<&str> {
        self.stored_short.as_deref().filter(|s| !s.trim().is_empty())
    }

    /// Whether the cached summary was produced by OpenAI (vs on-device / a rule). The
    /// read-out uses this to avoid serving a weaker on-device cache when the user has
    /// selected the OpenAI lane.
    pub fn cached_from_openai(&self) -> bool {
        // Provenance is `+`-joined (`rule:x+jev:m+model:openai:gpt-4o-mini`).
        self.stored_source.as_deref().is_some_and(|s| s.contains("model:openai"))
    }

    /// Whether the cached summary came from a model at all (vs a deterministic `rule:*`
    /// snippet). A rule snippet is just the opening of the body — the read-out prefers to
    /// regenerate a real summary when one can be produced.
    pub fn cached_is_model(&self) -> bool {
        self.stored_source.as_deref().is_some_and(|s| s.contains("model:"))
    }

    /// The cached summary's provenance tag for log lines (`model:openai` / `rule:*` /
    /// `none`).
    pub fn cache_source(&self) -> &str {
        self.stored_source.as_deref().unwrap_or("none")
    }

    /// User-content prompt with a tighter body budget — thread context for `draft_reply`.
    pub fn summary_user_prompt(&self) -> String {
        let body: String = self.body_text.chars().take(SUMMARY_BODY_CHARS).collect();
        format!("Subject: {}\nFrom: {}\n\n{}", self.subject, self.who, body)
    }
}

/// Assemble the read-out for `conversation_key`, or `None` when the thread has no
/// messages to read.
pub fn assemble(store: &SyncStore, conversation_key: &str) -> rusqlite::Result<Option<ThreadReadout>> {
    let conn = store.connection();
    let conn = conn.lock();

    // Conversation-level facts: subject + the pregenerated short/medium summaries and the
    // message they were written for (so we can tell whether they're still current).
    let row: Option<(String, Option<String>, Option<String>, Option<String>, Option<String>)> = conn
        .query_row(
            "SELECT COALESCE(subject, '(no subject)'), ai_summary_medium, ai_summary_short, ai_meta_msg_key, triage_source
             FROM conversations WHERE key = ?1",
            params![conversation_key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;
    let (subject, summary_medium, summary_short, summary_msg_key, triage_source) =
        row.unwrap_or_else(|| ("(no subject)".to_string(), None, None, None, None));
    // Read the clean conversation subject aloud — strip "Re:/Fwd:/[list]" noise.
    let subject = normalize_subject(&subject);

    // The latest message — the one we read out.
    let latest: Option<(String, String, String, String, i64)> = conn
        .query_row(
            "SELECT key, COALESCE(from_address, ''), COALESCE(body_plain, ''), COALESCE(body_html, ''), is_inbound
             FROM messages
             WHERE conversation_key = ?1
             ORDER BY created_at DESC
             LIMIT 1",
            params![conversation_key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;

    let Some((latest_key, from, body_plain, body_html, is_inbound)) = latest else {
        return Ok(None);
    };

    let who = if is_inbound != 0 { sender_name(&from) } else { "you".to_string() };
    let body_text = body_text(&body_plain, &body_html);
    // Use the stored summaries only if they were written for THIS latest message.
    let (stored_medium, stored_short, stored_source) = match summary_msg_key {
        Some(k) if k == latest_key => (summary_medium, summary_short, triage_source),
        _ => (None, None, None),
    };

    Ok(Some(ThreadReadout { subject, latest_key, who, body_text, stored_medium, stored_short, stored_source }))
}

/// The most-recent unread conversation key, for the agent's read-aloud "last unread".
pub fn latest_unread_key(store: &SyncStore) -> Option<String> {
    let conn = store.connection();
    let conn = conn.lock();
    conn.query_row(
        &format!(
            "SELECT key FROM conversations WHERE read = 0 AND {STATUS_FILTER}
             ORDER BY updated_at DESC LIMIT 1"
        ),
        [],
        |r| r.get(0),
    )
    .ok()
}

/// The most-recent conversation key regardless of read state ("latest").
pub fn latest_key(store: &SyncStore) -> Option<String> {
    let conn = store.connection();
    let conn = conn.lock();
    conn.query_row(
        &format!("SELECT key FROM conversations WHERE {STATUS_FILTER} ORDER BY updated_at DESC LIMIT 1"),
        [],
        |r| r.get(0),
    )
    .ok()
}

/// Readable plain text for a message body: prefer the stored plain part; otherwise render
/// the HTML to text. Collapses runs of blank lines and caps at [`READOUT_BODY_CHARS`].
fn body_text(plain: &str, html: &str) -> String {
    let text = if !plain.trim().is_empty() {
        plain.to_string()
    } else {
        html_to_text(html)
    };
    let text = tidy(&text);
    // Bridge reads only the sender's OWN words — drop quoted/forwarded trailers so the
    // draft-reply context never carries the prior thread.
    let text = crate::quotes::strip_quoted_text(&text);
    if text.chars().count() > READOUT_BODY_CHARS {
        text.chars().take(READOUT_BODY_CHARS).collect::<String>() + "…"
    } else {
        text
    }
}

/// Render HTML to readable plain text for a spoken read-out. Unlike a naive tag stripper,
/// this DROPS the content of `<style>`/`<script>`/`<head>` (so a marketing email's CSS
/// isn't read aloud) and turns block-level tags into line breaks, then decodes entities.
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let bytes = html.as_bytes();
    let lower = html.to_ascii_lowercase();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            // Find the tag's end.
            let Some(rel_end) = lower[i..].find('>') else { break };
            let end = i + rel_end;
            let tag = &lower[i + 1..end]; // contents between < and >
            let name: String = tag
                .trim_start_matches('/')
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric())
                .collect();
            // Skip the entire content of style/script/head blocks — and of `blockquote`,
            // which carries quoted replies (Apple Mail/Thunderbird `type=cite`, the inner
            // block of a Gmail quote) that Bridge must not read aloud.
            if matches!(name.as_str(), "style" | "script" | "head" | "blockquote") && !tag.starts_with('/') {
                let close = format!("</{name}");
                if let Some(rel_close) = lower[end..].find(&close) {
                    let close_start = end + rel_close;
                    i = lower[close_start..].find('>').map(|r| close_start + r + 1).unwrap_or(bytes.len());
                    continue;
                }
            }
            // Block-level tags become line breaks so the text stays readable.
            if matches!(
                name.as_str(),
                "br" | "p" | "div" | "li" | "tr" | "table" | "h1" | "h2" | "h3" | "h4" | "h5"
                    | "h6" | "ul" | "ol" | "section" | "article" | "header"
                    | "footer" | "hr"
            ) {
                out.push('\n');
            }
            i = end + 1;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    decode_entities(&out)
}

/// Decode the handful of HTML entities that matter for a spoken read-out.
fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&rsquo;", "'")
        .replace("&lsquo;", "'")
        .replace("&ldquo;", "\"")
        .replace("&rdquo;", "\"")
        .replace("&mdash;", "—")
        .replace("&ndash;", "–")
}

/// Collapse intra-line whitespace and runs of blank lines into single breaks, trimming
/// the result — so HTML's incidental whitespace doesn't bloat the read-out.
fn tidy(text: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    for line in text.lines() {
        let collapsed = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if collapsed.is_empty() {
            // keep at most one blank separator between blocks
            if lines.last().map(|l| !l.is_empty()).unwrap_or(false) {
                lines.push(String::new());
            }
        } else {
            lines.push(collapsed);
        }
    }
    lines.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::store::SyncStore;

    fn seed_msg(conn: &rusqlite::Connection, conv: &str, key: &str, from: &str, plain: &str, html: &str, inbound: bool, created: &str) {
        conn.execute(
            "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, body_html, is_inbound, created_at)
             VALUES (?1, ?2, 'org', ?3, ?4, ?5, ?6, ?7)",
            params![key, conv, from, plain, html, inbound as i64, created],
        )
        .unwrap();
    }

    #[test]
    fn uses_stored_short_and_medium_when_fresh_for_latest_message() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, ai_summary_medium, ai_summary_short, ai_meta_msg_key, updated_at)
                 VALUES ('c1', 'org', 'Project Falcon', 'Alice needs the Q3 budget by Friday.', 'Alice: Q3 budget?', 'm2', '2024-01-03T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "c1", "m1", "Alice <a@x.com>", "Can you send the budget?", "", true, "2024-01-01T00:00:00+00:00");
            seed_msg(&conn, "c1", "m2", "Alice <a@x.com>", "Any update on the Q3 budget?", "", true, "2024-01-03T00:00:00+00:00");
        }
        let r = assemble(&store, "c1").unwrap().expect("readout");
        assert_eq!(r.latest_key, "m2");
        // Cache hit: quick query → short; "full" read → medium. Both verbatim, no raw body.
        assert_eq!(r.fresh_short(), Some("Alice: Q3 budget?"));
        assert_eq!(r.fresh_medium(), Some("Alice needs the Q3 budget by Friday."));
    }

    #[test]
    fn stale_stored_summary_is_ignored() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            // Summary anchored to an OLD message — a newer one has since arrived.
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, ai_summary_medium, ai_meta_msg_key, updated_at)
                 VALUES ('c2', 'org', 'Hi', 'Old summary', 'm1', '2024-01-02T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "c2", "m1", "Bob <b@x.com>", "first", "", true, "2024-01-01T00:00:00+00:00");
            seed_msg(&conn, "c2", "m2", "Bob <b@x.com>", "second and newer", "", true, "2024-01-02T00:00:00+00:00");
        }
        let r = assemble(&store, "c2").unwrap().expect("readout");
        assert_eq!(r.latest_key, "m2");
        assert_eq!(r.fresh_medium(), None, "stale summary must not be reused");
        assert_eq!(r.fresh_short(), None, "stale summary must not be reused");
        // On a cache miss the (draft-context) body prompt carries the latest body.
        assert!(r.summary_user_prompt().contains("second and newer"));
    }

    #[test]
    fn html_only_body_drops_style_and_script() {
        let store = SyncStore::new_in_memory().unwrap();
        let html = "<html><head><style>.x{color:red;font-size:14px}</style></head>\
                    <body><script>var a=1;trackPixel();</script>\
                    <p>Hello there!</p><p>Your order <b>#42</b> has shipped.</p></body></html>";
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES ('c3', 'org', 'Shipped', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "c3", "m1", "Shop <s@x.com>", "", html, true, "2024-01-01T00:00:00+00:00");
        }
        let r = assemble(&store, "c3").unwrap().expect("readout");
        // The body that feeds the summariser (and the deterministic fallback) is clean.
        let body = r.summary_user_prompt();
        assert!(body.contains("Hello there!"), "{body}");
        assert!(body.contains("Your order #42 has shipped."), "{body}");
        assert!(!body.contains("color:red"), "CSS leaked into read-out: {body}");
        assert!(!body.contains("trackPixel"), "script leaked into read-out: {body}");
    }

    #[test]
    fn prefers_plain_part_over_html() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES ('c4', 'org', 'Hi', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "c4", "m1", "A <a@x.com>", "The plain part.", "<p>The HTML part.</p>", true, "2024-01-01T00:00:00+00:00");
        }
        let r = assemble(&store, "c4").unwrap().expect("readout");
        let body = r.summary_user_prompt();
        assert!(body.contains("The plain part."), "{body}");
        assert!(!body.contains("HTML part"), "{body}");
    }

    #[test]
    fn strips_plain_text_quoted_reply() {
        let store = SyncStore::new_in_memory().unwrap();
        let plain = "Sounds good, let's ship it.\n\n\
                     On Mon, Jan 1, 2024 at 9:00 AM Bob <b@x.com> wrote:\n\
                     > Are we still on for the launch?\n> Let me know.";
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES ('q1', 'org', 'Launch', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "q1", "m1", "Me <me@x.com>", plain, "", false, "2024-01-01T00:00:00+00:00");
        }
        let r = assemble(&store, "q1").unwrap().expect("readout");
        let body = r.summary_user_prompt();
        assert!(body.contains("Sounds good, let's ship it."), "{body}");
        assert!(!body.contains("still on for the launch"), "quoted reply leaked: {body}");
        assert!(!body.contains("wrote:"), "attribution line leaked: {body}");
    }

    #[test]
    fn strips_html_blockquote_reply() {
        let store = SyncStore::new_in_memory().unwrap();
        let html = "<p>Approved, go ahead.</p>\
                    <blockquote type=\"cite\"><p>Can I get sign-off on the budget?</p></blockquote>";
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES ('q2', 'org', 'Budget', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "q2", "m1", "Me <me@x.com>", "", html, false, "2024-01-01T00:00:00+00:00");
        }
        let r = assemble(&store, "q2").unwrap().expect("readout");
        let body = r.summary_user_prompt();
        assert!(body.contains("Approved, go ahead."), "{body}");
        assert!(!body.contains("sign-off on the budget"), "quoted blockquote leaked: {body}");
    }

    #[test]
    fn bare_forward_strips_quoted_block_from_draft_context() {
        // Entire body is a forwarded block — the draft-reply context must NOT carry it
        // (the subject/sender still anchor the prompt).
        let store = SyncStore::new_in_memory().unwrap();
        let plain = "-----Original Message-----\nFrom: Bob\n\nThe original content.";
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES ('q3', 'org', 'Fwd', '2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            seed_msg(&conn, "q3", "m1", "Me <me@x.com>", plain, "", false, "2024-01-01T00:00:00+00:00");
        }
        let r = assemble(&store, "q3").unwrap().expect("readout");
        assert!(!r.summary_user_prompt().contains("The original content."));
    }

    #[test]
    fn latest_unread_lookup_skips_read_and_archived() {
        let store = SyncStore::new_in_memory().unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, read, status, updated_at) VALUES
                   ('old',  'org', 'Old',  0, 'open',     '2024-01-01T00:00:00+00:00'),
                   ('read', 'org', 'Read', 1, 'open',     '2024-01-05T00:00:00+00:00'),
                   ('arch', 'org', 'Arch', 0, 'archived', '2024-01-06T00:00:00+00:00'),
                   ('new',  'org', 'New',  0, 'open',     '2024-01-04T00:00:00+00:00')",
                [],
            )
            .unwrap();
        }
        assert_eq!(latest_unread_key(&store).as_deref(), Some("new"));
    }
}

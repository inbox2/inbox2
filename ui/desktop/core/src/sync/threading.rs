//! Conversation threading and subject normalization.
//!
//! These functions own the "which conversation does this message belong to?"
//! decision and the conversation-status bookkeeping that follows from a
//! message's flags. They operate on an already-locked rusqlite [`Connection`]
//! passed in by [`crate::sync::store::SyncStore`], so they hold no state and the
//! caller controls the lock scope.

use rusqlite::{params, Connection, OptionalExtension};

use crate::sync::error::Result;
use crate::sync::model::{ConversationStatus, UnifiedFlags, UnifiedMessage, WellKnownFolder};
use crate::sync::store::SyncStore;

/// Thread a message into an existing conversation or create a new one, returning
/// the conversation key.
///
/// Strategy, in order of authority:
/// 1. Provider-native thread id (Gmail `threadId` / Microsoft `conversationId`)
///    — authoritative when present; we thread *only* on it and never fall back
///    to headers/subject, which would wrongly merge distinct provider threads
///    that share a subject line.
/// 2. (No thread id — IMAP) In-Reply-To header.
/// 3. References header, newest first.
/// 4. Exact normalized subject **and** a shared non-recipient participant.
/// 5. Otherwise, create a new conversation.
pub(crate) fn find_or_create_conversation(
    conn: &Connection,
    account_key: &str,
    msg: &UnifiedMessage,
    now: &str,
) -> Result<String> {
    let provider_thread = msg
        .provider_thread_id
        .as_deref()
        .filter(|t| !t.is_empty());

    // Canonical key for the subject fallback; also stored on new rows.
    let match_key = msg
        .subject
        .as_deref()
        .map(subject_match_key)
        .filter(|k| !k.is_empty());

    if let Some(thread_id) = provider_thread {
        // Provider-native thread id is authoritative — it already accounts for
        // reply/forward chains. When present we thread *only* on it.
        let conv_key: Option<String> = conn
            .query_row(
                "SELECT key FROM conversations
                 WHERE organization_id = ?1 AND provider_thread_id = ?2
                 LIMIT 1",
                params![account_key, thread_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(key) = conv_key {
            return Ok(key);
        }
    } else {
        // No provider thread id (IMAP): thread on RFC headers, then subject.

        // 1. In-Reply-To header.
        if let Some(ref in_reply_to) = msg.in_reply_to {
            if let Some(conv_key) =
                find_conversation_by_message_id(conn, account_key, in_reply_to)?
            {
                return Ok(conv_key);
            }
        }

        // 2. References header (newest first).
        if let Some(ref refs) = msg.references_header {
            for ref_id in refs.split_whitespace().rev() {
                if let Some(conv_key) =
                    find_conversation_by_message_id(conn, account_key, ref_id)?
                {
                    return Ok(conv_key);
                }
            }
        }

        // 3. Subject fallback (no threading headers). Require the *exact*
        //    normalized subject AND a shared non-recipient participant: the
        //    incoming sender must already be a party to the candidate, or the
        //    incoming recipient must be its originator. This re-threads replies
        //    that lost their References header while preventing unrelated mail
        //    that merely shares a generic subject ("", "Without subject",
        //    "Invoice") from collapsing — a common "to me" recipient alone never
        //    merges. An exact substring match is also avoided: it over-merges a
        //    short subject contained in a longer one.
        if let Some(ref key) = match_key {
            let from = msg.from_address.to_lowercase();
            let to = msg.to_address.as_deref().unwrap_or_default().to_lowercase();
            let conv_key: Option<String> = conn
                .query_row(
                    "SELECT key FROM conversations
                     WHERE organization_id = ?1 AND normalized_subject = ?2
                       AND ( lower(from_address) = ?3
                          OR lower(to_address)   = ?3
                          OR lower(from_address) = ?4 )
                     ORDER BY updated_at DESC LIMIT 1",
                    params![account_key, key, from, to],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(key) = conv_key {
                return Ok(key);
            }
        }
    }

    // 4. Create new conversation.
    let conv_key = SyncStore::generate_key("conv");
    let snippet = build_snippet(msg.body_plain.as_deref(), msg.body_html.as_deref());
    let status = ConversationStatus::from_flags(&msg.flags);

    // Seed the conversation timeline from the message's own date, not the sync
    // wall-clock — the inbox sorts and displays by this, so it must reflect real
    // recency. Fall back to the provider's internal/received timestamp when the
    // Date header is missing/unparseable (mirrors upsert_synced_message).
    let msg_date = msg
        .date
        .or(msg.internal_date)
        .map(|d| d.to_rfc3339())
        .unwrap_or_else(|| now.to_string());

    conn.execute(
        "INSERT INTO conversations
         (key, organization_id, subject, provider_thread_id, normalized_subject,
          from_address, to_address, status, snippet, read, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            conv_key,
            account_key,
            crate::sync::util::header_text_opt(&msg.subject),
            provider_thread,
            match_key.as_deref(),
            crate::sync::util::header_text(&msg.from_address),
            msg.to_address,
            status.as_str(),
            snippet,
            msg.flags.read as i32,
            msg_date,
            msg_date,
        ],
    )?;

    Ok(conv_key)
}

/// Find the conversation a message belongs to, by its RFC Message-ID header,
/// scoped to one account.
pub(crate) fn find_conversation_by_message_id(
    conn: &Connection,
    account_key: &str,
    message_id: &str,
) -> Result<Option<String>> {
    conn.query_row(
        "SELECT conversation_key FROM messages
         WHERE message_id_header = ?1 AND account_key = ?2 LIMIT 1",
        params![message_id, account_key],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

/// Mirror a message's read/status flags onto its conversation.
///
/// Flag/status changes (read, archive, …) are not new activity — this
/// deliberately does NOT touch `updated_at`, or every sync would reset the inbox
/// ordering to wall-clock time.
///
/// Only the thread's *newest* message defines its status — see
/// [`defines_thread_status`]. Read is still mirrored from whichever message
/// synced, matching the write-back guard's message-at-a-time model.
pub(crate) fn update_conversation_from_flags(
    conn: &Connection,
    message_key: &str,
    flags: &UnifiedFlags,
) -> Result<()> {
    let conv_key: Option<String> = conn
        .query_row(
            "SELECT conversation_key FROM messages WHERE key = ?1",
            params![message_key],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(conv_key) = conv_key {
        if defines_thread_status(conn, &conv_key, message_key)? {
            let mut status = ConversationStatus::from_flags(flags);
            if status == ConversationStatus::Archived && has_inbox_copy(conn, &conv_key)? {
                status = ConversationStatus::Open;
            }
            conn.execute(
                "UPDATE conversations SET read = ?1, status = ?2 WHERE key = ?3",
                params![flags.read as i32, status.as_str(), conv_key],
            )?;
        } else {
            conn.execute(
                "UPDATE conversations SET read = ?1 WHERE key = ?2",
                params![flags.read as i32, conv_key],
            )?;
            // An older message that sits in the inbox still reopens an archived thread.
            if has_inbox_copy(conn, &conv_key)? {
                conn.execute(
                    "UPDATE conversations SET status = ?1 WHERE key = ?2 AND status = ?3",
                    params![ConversationStatus::Open.as_str(), conv_key, ConversationStatus::Archived.as_str()],
                )?;
            }
        }
    }
    Ok(())
}

/// Whether any message of the thread still has a live copy in the inbox folder.
/// Gmail shows a thread in the inbox while ANY of its messages carries INBOX, so a
/// newest message that was archived (or filtered past the inbox) must not archive
/// a thread whose older, unread reply still sits there.
///
/// Safe against the staleness [`defines_thread_status`] guards: an INBOX row is
/// removed the moment Gmail history reports the message left the label, and the
/// inbox folder syncs first — so archiving in Gmail drops these rows before the
/// All Mail copy re-decides the thread. A local archive is covered by the
/// write-back guard, which blocks the whole mirror until the provider agrees.
fn has_inbox_copy(conn: &Connection, conv_key: &str) -> Result<bool> {
    conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM messages m
             JOIN message_provider_state ps ON ps.message_key = m.key
             JOIN external_folders f ON f.key = ps.folder_key
             WHERE m.conversation_key = ?1 AND f.well_known_role = ?2
               AND COALESCE(json_extract(ps.flags, '$.archived'), 0) = 0
               AND COALESCE(json_extract(ps.flags, '$.trashed'), 0) = 0
               AND COALESCE(json_extract(ps.flags, '$.spam'), 0) = 0)",
        params![conv_key, WellKnownFolder::Inbox.as_str()],
        |row| row.get(0),
    )
    .map_err(Into::into)
}

/// Whether this message is the one whose flags define its thread's status: the
/// newest message in the thread that still lives in a status-bearing folder.
///
/// The mirror is otherwise last-write-wins, so a thread holding one old trashed
/// message got dragged back into Trash on every sync — Gmail syncs INBOX before
/// TRASH, so the stale copy always wrote last and a live reply vanished from the
/// inbox. Deferring to the newest message keeps the status tracking the same
/// message the conversation row already denormalizes its sender/snippet/date
/// from.
///
/// Sent/Drafts copies are excluded, for the same reason the caller skips
/// mirroring them at all: an outbound copy always reports open/unarchived
/// regardless of the thread's real state, so letting your own last reply define
/// the status would strand archived threads in the inbox.
///
/// ponytail: newest-message-wins, not a fold over every copy's flags. Gmail's
/// real rule is label union across the thread, but the provider-state rows can't
/// carry it — a trashed message keeps a stale All Mail row claiming
/// `archived:true, trashed:false` until a full sync prunes it, so a union would
/// pop trashed threads back out of Trash. Revisit if per-message folder state
/// ever becomes reliable enough to union.
fn defines_thread_status(conn: &Connection, conv_key: &str, message_key: &str) -> Result<bool> {
    let newest: Option<String> = conn
        .query_row(
            "SELECT m.key FROM messages m
             JOIN message_provider_state ps ON ps.message_key = m.key
             LEFT JOIN external_folders f ON f.key = ps.folder_key
             WHERE m.conversation_key = ?1
               AND COALESCE(f.well_known_role, '') NOT IN ('sent', 'drafts')
             ORDER BY m.created_at DESC, m.id DESC
             LIMIT 1",
            params![conv_key],
            |row| row.get(0),
        )
        .optional()?;

    // No status-bearing copy left in the thread (all Sent/Drafts, or provider
    // state not written yet) — fall back to mirroring, which is the old
    // behaviour and never worse than writing nothing.
    Ok(newest.is_none_or(|k| k == message_key))
}

// ---------------------------------------------------------------------------
// Snippet + subject helpers
// ---------------------------------------------------------------------------

/// Build a one-line conversation preview from a message body. Prefers the HTML
/// part stripped to bare text (via `ammonia`), like Gmail: senders neglect the
/// `text/plain` alternative — a "your client can't display HTML" stub, or a
/// stale template in another language — so it disagrees with what the reader
/// sees. Falls back to the plain part for plain-only mail. Leaked CSS rules and invisible
/// preheader padding are removed, internal whitespace is collapsed and the
/// result is truncated to 200 characters.
pub(crate) fn build_snippet(body_plain: Option<&str>, body_html: Option<&str>) -> String {
    // Close up entity references the sender wrapped mid-reference *before*
    // anything parses them — see `join_wrapped_entities`.
    let body_plain = body_plain.map(join_wrapped_entities);
    let body_html = body_html.map(join_wrapped_entities);
    let (body_plain, body_html) = (body_plain.as_deref(), body_html.as_deref());
    let strip_html = |h: &str| {
        ammonia::Builder::new()
            .tags(std::collections::HashSet::new())
            .clean(h)
            .to_string()
    };
    let mut text = body_html.map(strip_html).unwrap_or_default();
    if text.trim().is_empty() {
        // Plain-only or image-only mail. Some senders put their HTML *source*
        // in the text/plain part (so the preview would otherwise read
        // "<!DOCTYPE html> <html> <head>…") — strip the tags in that case too.
        text = match body_plain {
            Some(p) if looks_like_html_source(p) => strip_html(p),
            Some(p) => p.to_string(),
            None => String::new(),
        };
    }
    sanitize_snippet_text(&text)
}

/// An HTML body as readable text, for surfaces that show the whole message
/// (the MCP read tools) rather than a one-line preview. Block tags become line
/// breaks, every tag goes (and with it inline `data:` images: one 2 KB mail
/// came back as 600 KB of base64), script/style content goes, entities decode.
/// Nothing is truncated.
pub fn html_to_text(html: &str) -> String {
    const BLOCK: [&str; 16] =
        ["br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "table", "ul", "ol", "blockquote"];
    let mut spaced = String::with_capacity(html.len());
    for (i, part) in html.split('<').enumerate() {
        if i > 0 {
            let name: String = part
                .trim_start_matches('/')
                .chars()
                .take_while(char::is_ascii_alphanumeric)
                .take(12)
                .collect::<String>()
                .to_ascii_lowercase();
            if BLOCK.contains(&name.as_str()) {
                spaced.push('\n');
            }
            spaced.push('<');
        }
        spaced.push_str(part);
    }
    let text = ammonia::Builder::new().tags(std::collections::HashSet::new()).clean(&spaced).to_string();
    let text = decode_text_entities(&strip_invisible(&text));
    let mut out = String::with_capacity(text.len());
    let mut blank = false;
    for line in text.lines() {
        let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if line.is_empty() && blank {
            continue;
        }
        blank = line.is_empty();
        out.push_str(&line);
        out.push('\n');
    }
    out.trim().to_string()
}

/// True when text is actually HTML source rather than prose — a tag soup that
/// would read as gibberish in a one-line preview. Fires when the content opens
/// with a document/root marker, *or* when it carries two or more recognisable
/// HTML element tags (`<div>`, `<td>`, `<input …>`, `</p>` …) — the case where
/// a sender crams the HTML *source* into the `text/plain` part without a
/// leading doctype (marketing/ad-builder mail). Conservative on prose: a stray
/// `<` ("a < b") or a lone `<placeholder>` word never trips it, because a name
/// must match a known HTML element and at least two must be present.
pub(crate) fn looks_like_html_source(s: &str) -> bool {
    let head: String = s.trim_start().chars().take(15).flat_map(|c| c.to_lowercase()).collect();
    if head.starts_with("<!doctype") || head.starts_with("<html") {
        return true;
    }
    count_html_tags(s) >= 2
}

/// Recognisable HTML element names — the tags marketing/newsletter/ad-builder
/// mail actually emits. Used to tell HTML tag-soup from prose that merely
/// contains a `<`. Kept in sync with the Ruby `SnippetBuilder::HTML_TAGS`.
const HTML_TAGS: &[&str] = &[
    "html", "head", "body", "title", "meta", "link", "style", "script", "div", "span", "p", "br",
    "hr", "a", "img", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "ul", "ol", "li", "dl",
    "dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "i", "em", "u", "small", "sup",
    "sub", "font", "center", "blockquote", "pre", "code", "form", "input", "button", "textarea",
    "select", "option", "label", "header", "footer", "section", "article", "nav", "main", "aside",
    "figure", "figcaption", "picture", "source", "map", "area",
];

/// Count occurrences of a recognisable HTML element tag (`<name …>`, `<name/>`,
/// `</name>`). Case-insensitive; the byte after the name must terminate the tag
/// name (whitespace, `>`, or `/`) so prose like `<pretend to>` doesn't match on
/// `pre`. Stops early once two are found — the only threshold callers care about.
fn count_html_tags(s: &str) -> usize {
    let bytes = s.as_bytes();
    let mut count = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'<' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        if j < bytes.len() && bytes[j] == b'/' {
            j += 1;
        }
        let name_start = j;
        while j < bytes.len() && bytes[j].is_ascii_alphanumeric() {
            j += 1;
        }
        let name = &s[name_start..j];
        let terminates = j >= bytes.len() || matches!(bytes[j], b' ' | b'\t' | b'\n' | b'\r' | b'>' | b'/');
        if !name.is_empty() && terminates && HTML_TAGS.iter().any(|t| t.eq_ignore_ascii_case(name)) {
            count += 1;
            if count >= 2 {
                return count;
            }
        }
        // Skip past the name we just scanned; `i == j` can't happen (j > i).
        i = j.max(i + 1);
    }
    count
}

/// The sanitize half of [`build_snippet`]: decode HTML entities, strip leaked
/// CSS + invisible padding + decorative separator runs, collapse whitespace to
/// one line, truncate to 200 chars. Also used by the store's open-time scrub to detect previews stored
/// before these helpers existed (a clean snippet is a fixed point of this
/// function) — so entity-laden snippets written before decoding existed get
/// rebuilt on open too.
pub(crate) fn sanitize_snippet_text(text: &str) -> String {
    strip_separator_runs(&strip_cids(&strip_urls(&strip_css_rules(&strip_invisible(&strip_known_tags(
        &decode_html_entities(text),
    ))))))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(200)
        .collect()
}

/// Remove bare URLs from a one-line preview. Marketing/notification mail inlines
/// long tracking links in the `text/plain` part — e.g. "… Hero image (
/// https://clicks.example.com/f/a/6tE-ICN4hzqPMl7BfMqPEg~~/…" — which would
/// otherwise fill the notification body with an opaque URL and eat the 200-char
/// budget. We drop the scheme-to-whitespace span and tidy up an empty
/// `( )`/`[ ]`/`< >` wrapper the link leaves behind. Idempotent: text with no
/// URLs is returned unchanged, so a clean snippet stays a fixed point of
/// [`sanitize_snippet_text`].
fn strip_urls(s: &str) -> String {
    let starts = |rest: &str, p: &str| rest.get(..p.len()).is_some_and(|h| h.eq_ignore_ascii_case(p));
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while !rest.is_empty() {
        if starts(rest, "http://") || starts(rest, "https://") {
            // The URL runs from the scheme to the next whitespace (or the end).
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            rest = &rest[end..];
            // If the link was wrapped — "( <url> )" / "[url]" / "<url>" — drop
            // the now-dangling opener already in `out` and its matching closer.
            trim_trailing_ws(&mut out);
            if let Some(opener) = out.chars().last().filter(|c| matches!(c, '(' | '[' | '<')) {
                let closer = match opener {
                    '(' => ')',
                    '[' => ']',
                    _ => '>',
                };
                out.truncate(out.len() - opener.len_utf8());
                if let Some(after) = rest.trim_start().strip_prefix(closer) {
                    rest = after;
                }
            }
        } else {
            let ch = rest.chars().next().unwrap();
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        }
    }
    out
}

/// Remove decorative separator runs — three or more consecutive characters
/// from the divider set (`====`, `----`, `____`, `*~*~`, `———`, box-drawing
/// lines) that plain-text mail uses as horizontal rules. Gmail drops these
/// from its preview; without this a notification body fills up with `====…`
/// before the real content. Runs after `strip_urls` so a dashed URL path is
/// removed whole rather than broken mid-link. Idempotent: the output never
/// contains a separator run (replaced by a single space; runs of one or two
/// — "--", "C++-style prose" — are kept).
fn strip_separator_runs(s: &str) -> String {
    let is_sep = |c: char| {
        matches!(c, '=' | '-' | '_' | '*' | '~' | '#')
            || matches!(c, '\u{2013}'..='\u{2015}') // – — ―
            || matches!(c, '\u{2500}'..='\u{257F}') // box-drawing lines
    };
    let mut out = String::with_capacity(s.len());
    let mut run = String::new();
    for c in s.chars() {
        if is_sep(c) {
            run.push(c);
            continue;
        }
        if run.chars().count() >= 3 {
            out.push(' ');
        } else {
            out.push_str(&run);
        }
        run.clear();
        out.push(c);
    }
    if run.chars().count() >= 3 {
        out.push(' ');
    } else {
        out.push_str(&run);
    }
    out
}

/// Truncate trailing whitespace from a `String` in place.
fn trim_trailing_ws(out: &mut String) {
    out.truncate(out.trim_end().len());
}

/// Remove inline content-id image placeholders that some senders leak into the
/// `text/plain` alternative where an inline image sat — e.g. "Kindly approve
/// the change [cid:logo_ecbea85b-c03e-44b5-a1f2@inbox2]". Without this the raw
/// `cid:` token fills the notification body (the reported bug). Drops the cid
/// reference together with a `( )`/`[ ]`/`< >` wrapper, mirroring [`strip_urls`].
/// Idempotent: text with no `cid:` refs is returned unchanged.
fn strip_cids(s: &str) -> String {
    let starts = |rest: &str, p: &str| rest.get(..p.len()).is_some_and(|h| h.eq_ignore_ascii_case(p));
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while !rest.is_empty() {
        // Only strip when a content-id actually follows the scheme — a literal
        // "cid:" with nothing after it is left as ordinary text.
        if starts(rest, "cid:")
            && rest["cid:".len()..].starts_with(|c: char| !c.is_whitespace() && !matches!(c, ')' | ']' | '>'))
        {
            // The reference runs to the next whitespace or closing wrapper —
            // the content-id itself contains neither.
            let end = rest
                .find(|c: char| c.is_whitespace() || matches!(c, ')' | ']' | '>'))
                .unwrap_or(rest.len());
            rest = &rest[end..];
            // If the ref was wrapped — "[<cid>]" / "(<cid>)" / "<<cid>>" — drop
            // the now-dangling opener already in `out` and its matching closer.
            trim_trailing_ws(&mut out);
            if let Some(opener) = out.chars().last().filter(|c| matches!(c, '(' | '[' | '<')) {
                let closer = match opener {
                    '(' => ')',
                    '[' => ']',
                    _ => '>',
                };
                out.truncate(out.len() - opener.len_utf8());
                if let Some(after) = rest.trim_start().strip_prefix(closer) {
                    rest = after;
                }
            }
        } else {
            let ch = rest.chars().next().unwrap();
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        }
    }
    out
}

/// Remove residual well-formed HTML tags a preview can still carry when the
/// body wasn't run through `ammonia` — the common case being a lone tracking
/// pixel (`<img src="…">`) or a single link in an otherwise-plain `text/plain`
/// part, which [`looks_like_html_source`] deliberately ignores (it needs two
/// tags to avoid mangling prose). Without this, the raw tag leaks into the
/// preview, and `strip_urls` chews the `src` URL out mid-tag, leaving
/// `<img src=" width="5" …>`. Only known [`HTML_TAGS`] are dropped, so prose
/// like "a < b" or "<coffee>" survives untouched. Idempotent.
/// ponytail: naive `<…>` span drop — an attribute value containing `>` would
/// cut short, harmless for a one-line preview.
fn strip_known_tags(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'<' {
            let ch = s[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }
        let mut j = i + 1;
        if j < bytes.len() && bytes[j] == b'/' {
            j += 1;
        }
        let name_start = j;
        while j < bytes.len() && bytes[j].is_ascii_alphanumeric() {
            j += 1;
        }
        let name = &s[name_start..j];
        let is_tag = !name.is_empty() && HTML_TAGS.iter().any(|t| t.eq_ignore_ascii_case(name));
        match (is_tag, s[i..].find('>')) {
            (true, Some(gt)) => i += gt + 1, // drop `<`..`>` inclusive
            _ => {
                out.push('<');
                i += 1;
            }
        }
    }
    out
}

/// Rejoin an HTML entity reference that a hard line break splits in two.
/// Senders wrap the raw body at the SMTP 998-byte line limit without regard for
/// entity boundaries — Thuisbezorgd's preheader padding arrives as `…&nbsp` +
/// newline + `;&#8204;…` — and the HTML parser then decodes the truncated
/// reference (`&nbsp` is a legacy no-semicolon form) and leaves the tail as
/// literal text, so the notification read "… review ; R 04; &n bsp; & #8204;".
/// Runs before `ammonia` for that reason, and before our own decoder for the
/// `text/plain` path. Only joined when the whitespace-free body is a reference
/// we know, so prose ("R & D;") is left exactly as written.
fn join_wrapped_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        out.push('&');
        match wrapped_entity_body(&rest[1..]) {
            Some((len, body)) => {
                out.push_str(&body);
                out.push(';');
                rest = &rest[1 + len..];
            }
            None => rest = &rest[1..],
        }
    }
    out.push_str(rest);
    out
}

/// The body of a whitespace-broken entity reference at the start of `s` (which
/// begins just after the `&`), as (bytes consumed through the `;`, body without
/// the whitespace). `None` when the reference is intact, too long to be one, or
/// doesn't decode.
fn wrapped_entity_body(s: &str) -> Option<(usize, String)> {
    let mut body = String::new();
    let mut broken = false;
    // Bounded scan: a reference plus the whitespace a wrap inserts is short, and
    // without the cap a body of "&" + megabytes of spaces would be quadratic.
    for (i, c) in s.char_indices().take(24) {
        match c {
            ';' => return (broken && decode_entity(&body).is_some()).then(|| (i + 1, body)),
            c if c.is_whitespace() => broken = true,
            c if c.is_ascii_alphanumeric() || c == '#' => body.push(c),
            _ => return None,
        }
    }
    None
}

/// Decode common HTML entities left behind after tag stripping: `ammonia`
/// removes markup but keeps the text content HTML-escaped, so HTML-only mail
/// (no `text/plain` part) would otherwise show `&amp;`/`&nbsp;`/`&#39;`
/// literally in list previews and notifications. Single pass over the input —
/// `&amp;lt;` decodes to `&lt;`, not `<`. Unknown entities pass through
/// unchanged. Deliberately never emits `<` or `>` (skips `lt`/`gt` and their
/// numeric forms): stored snippets are re-parsed as HTML by some consumers, so
/// decoded angle brackets could turn escaped text back into live markup.
fn decode_html_entities(s: &str) -> String {
    decode_entities_with(s, false)
}

/// Entity decoding for plain-text surfaces that are never re-parsed as HTML
/// (notification title/subtitle): same single pass, but `&lt;`/`&gt;` decode
/// too, so a subject like `Dashboard &gt; Leads` reads as the sender meant it.
pub(crate) fn decode_text_entities(s: &str) -> String {
    decode_entities_with(s, true)
}

fn decode_entities_with(s: &str, allow_angle: bool) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        // An entity is `&` + a short name + `;`; scan a bounded window.
        let semi = rest[1..]
            .char_indices()
            .take(10)
            .find(|(_, c)| *c == ';')
            .map(|(i, _)| i + 1);
        let decoded = |name: &str| match (allow_angle, name) {
            (true, "lt" | "#60" | "#x3c" | "#x3C") => Some('<'),
            (true, "gt" | "#62" | "#x3e" | "#x3E") => Some('>'),
            _ => decode_entity(name),
        };
        match semi.and_then(|semi| decoded(&rest[1..semi])) {
            Some(c) => {
                out.push(c);
                rest = &rest[semi.unwrap() + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Decode a single entity name (the part between `&` and `;`). Numeric forms
/// (`#39`, `#x2019`) cover the long tail; the named list covers what mail
/// senders actually emit. Returns `None` for unknown names, control
/// characters, and angle brackets (see [`decode_html_entities`]).
fn decode_entity(name: &str) -> Option<char> {
    if let Some(num) = name.strip_prefix('#') {
        let code = match num.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => num.parse::<u32>().ok()?,
        };
        return char::from_u32(code)
            // Tab/CR/LF references (`&#x0009;`, a mail-merge leftover) become a
            // space — the control-char filter below would otherwise leave them
            // in the preview verbatim.
            .map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c })
            .filter(|c| !c.is_control() && *c != '<' && *c != '>');
    }
    Some(match name {
        "amp" => '&',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" | "ensp" | "emsp" | "thinsp" => ' ',
        "rsquo" => '\u{2019}',
        "lsquo" => '\u{2018}',
        "rdquo" => '\u{201D}',
        "ldquo" => '\u{201C}',
        "mdash" => '\u{2014}',
        "ndash" => '\u{2013}',
        "hellip" => '\u{2026}',
        "bull" => '\u{2022}',
        "middot" => '\u{B7}',
        "copy" => '\u{A9}',
        "reg" => '\u{AE}',
        "trade" => '\u{2122}',
        "deg" => '\u{B0}',
        "euro" => '\u{20AC}',
        "pound" => '\u{A3}',
        "yen" => '\u{A5}',
        "cent" => '\u{A2}',
        "laquo" => '\u{AB}',
        "raquo" => '\u{BB}',
        "plusmn" => '\u{B1}',
        "times" => '\u{D7}',
        "frac12" => '\u{BD}',
        "frac14" => '\u{BC}',
        // Invisible-format entities decode to their characters so
        // `strip_invisible` removes them with the rest of the padding.
        "zwnj" => '\u{200C}',
        "zwj" => '\u{200D}',
        "shy" => '\u{AD}',
        _ => return None,
    })
}

/// Remove invisible format characters senders pad marketing previews with
/// (zero-width joiners after every glyph, soft hyphens, BOMs, the combining
/// grapheme joiner). They aren't whitespace, so they'd survive the collapse in
/// [`build_snippet`] and eat the 200-char budget while rendering as nothing.
fn strip_invisible(s: &str) -> String {
    s.chars()
        .filter(|c| !matches!(c, '\u{200B}'..='\u{200D}' | '\u{2060}' | '\u{FEFF}' | '\u{00AD}' | '\u{034F}'))
        .collect()
}

/// Remove CSS rule blocks — `selector { prop: value; }` — that some senders
/// leak into the `text/plain` part verbatim (the rule is the first "text" in
/// the mail, so it lands at the front of the preview). Brace blocks whose
/// content is not declaration-shaped (prose like "use {braces} wisely") are
/// kept untouched.
fn strip_css_rules(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(open) = rest.find('{') {
        // Find the matching close brace (depth-tracked for nested @media blocks).
        let mut depth = 0usize;
        let mut close = None;
        for (i, c) in rest[open..].char_indices() {
            match c {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(open + i);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(close) = close else { break };
        if looks_like_css_decls(&rest[open + 1..close]) {
            out.push_str(trim_selector_suffix(&rest[..open]));
            out.push(' ');
        } else {
            out.push_str(&rest[..close + 1]);
        }
        rest = &rest[close + 1..];
    }
    out.push_str(rest);
    out
}

/// Whether brace-block content reads as CSS declarations (`property: value`,
/// `;`-separated, property names alphanumeric-with-dashes) or wraps a nested
/// rule (an `@media` body).
fn looks_like_css_decls(inner: &str) -> bool {
    inner.contains('{')
        || inner.split(';').any(|d| {
            let Some((prop, val)) = d.split_once(':') else { return false };
            let prop = prop.trim();
            !prop.is_empty()
                && !val.trim().is_empty()
                && prop.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
}

/// Drop the selector tokens directly before a stripped CSS block: tokens that
/// carry CSS marker characters (`* . # @ : > [`) always go; one plain
/// tag-like word (`body`, `td`) goes too; comma-ended tokens continue a
/// selector list. Ordinary prose before the rule stays.
fn trim_selector_suffix(prefix: &str) -> &str {
    let mut keep = prefix.trim_end();
    let mut first = true;
    for _ in 0..6 {
        let Some(token) = keep.split_whitespace().last() else { break };
        let markers = ['*', '.', '#', '@', ':', '>', '['];
        // A bare word ("body", "td") only reads as a selector right before the
        // brace — further back it's prose ("…see you soon .btn { … }").
        let tag_like = token.len() <= 10
            && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && token.chars().next().is_some_and(|c| c.is_ascii_alphabetic());
        if !(token.contains(markers) || token.ends_with(',') || (first && tag_like)) {
            break;
        }
        keep = keep[..keep.len() - token.len()].trim_end();
        first = false;
    }
    keep
}

/// Latin-script reply/forward prefixes, compared ASCII-case-insensitively. Each
/// is matched as `<prefix>` + optional `[n]`/`(n)` count + `:`. Kept in parity
/// with the Rails `SubjectNormalizer::LATIN_PREFIXES`.
const REPLY_PREFIXES: &[&str] = &[
    "re",   // English / Italian / Spanish / Portuguese / French
    "fwd", "fw", // English forward
    "aw",   // German (Antwort)
    "wg",   // German forward (Weitergeleitet)
    "antw", // Dutch (Antwoord)
    "beantw", // Afrikaans (Beantwoord)
    "doorst", // Dutch forward (Doorsturen)
    "sv",   // Swedish/Norwegian/Danish (Svar)
    "svar", // Scandinavian full word
    "vs",   // Icelandic / Finnish (Vastaus)
    "vb",   // Icelandic forward (Viðbrögð)
    "fs",   // Icelandic (Framsent)
    "enc",  // Spanish/Portuguese forward (Encaminhar)
    "rv",   // Norwegian Bokmål reply
    "ref",  // Italian (Riferimento) / generic
    "rif",  // Italian (Riferimento, alt.)
    "res",  // Portuguese/Catalan (Resposta)
    "tr",   // French forward (Transféré)
    "rép", "rep", // French (Répondre)
    "odp",  // Polish reply (Odpowiedź)
    "pd",   // Czech/Slovak forward
    "ynt",  // Turkish (Yanıt)
    "atb",  // Welsh (Ateb)
    "va", "vá", // Hungarian (Válasz)
];

/// East-Asian ideographic reply/forward prefixes, matched exactly. The colon
/// (ASCII `:` or full-width `：`) is OPTIONAL for these — East-Asian clients
/// often omit it.
const REPLY_PREFIXES_CJK: &[&str] = &["回复", "回覆", "答复", "转发", "轉發", "轉寄"];

/// Non-Latin alphabetic reply/forward prefixes (Korean, Japanese, Hebrew,
/// Arabic, Hindi, Greek, Cyrillic), matched case-insensitively. A colon (ASCII
/// `:` or full-width `：`) is REQUIRED — these abbreviations collide with
/// ordinary words in their scripts (e.g. Bulgarian "На"), so a bare prefix must
/// not be stripped. Kept in parity with `SubjectNormalizer::NON_LATIN_PREFIXES`.
const REPLY_PREFIXES_COLON: &[&str] = &[
    "답장", "전달",            // Korean (reply / forward)
    "返信", "転送",            // Japanese (reply / forward)
    "השב", "הועבר",            // Hebrew (reply / forward)
    "رد", "إعادة توجيه",       // Arabic (reply / forward)
    "उत्तर", "अग्रेषित",          // Hindi (reply / forward)
    "ΑΠ", "ΠΡΘ",              // Greek (Απάντηση / Προώθηση)
    "ОТВ", "ПЕР", "НА",        // Russian / Bulgarian (reply / forward)
];

/// Strip reply/forward prefixes and leading mailing-list tags from a subject,
/// then collapse internal whitespace. Case is preserved (this is the canonical
/// thread subject). For *matching*, use [`subject_match_key`].
pub(crate) fn normalize_subject(subject: &str) -> String {
    let mut s = subject.trim();
    loop {
        // Leading mailing-list tag, e.g. "[list-name] Subject" → "Subject".
        if let Some(rest) = s.strip_prefix('[') {
            if let Some(close) = rest.find(']') {
                let after = rest[close + 1..].trim_start();
                if !after.is_empty() {
                    s = after;
                    continue;
                }
            }
        }

        // East-Asian ideographic prefixes, optionally followed by ':' or '：'.
        if let Some(stripped) = REPLY_PREFIXES_CJK.iter().find_map(|p| {
            s.strip_prefix(*p).map(|rest| {
                let rest = rest.trim_start();
                rest.strip_prefix(':')
                    .or_else(|| rest.strip_prefix('：'))
                    .unwrap_or(rest)
                    .trim_start()
            })
        }) {
            s = stripped;
            continue;
        }

        // Non-Latin alphabetic prefixes, case-insensitive, colon REQUIRED.
        let mut matched_colon = false;
        for p in REPLY_PREFIXES_COLON {
            let plen = p.chars().count();
            let head: String = s.chars().take(plen).collect();
            if head.chars().count() != plen || head.to_lowercase() != p.to_lowercase() {
                continue;
            }
            let rest = s[head.len()..].trim_start();
            if let Some(body) = rest.strip_prefix(':').or_else(|| rest.strip_prefix('：')) {
                s = body.trim_start();
                matched_colon = true;
                break;
            }
        }
        if matched_colon {
            continue;
        }

        // ASCII prefixes: "<prefix>" + optional "[n]"/"(n)" + ':'.
        let mut matched = false;
        for p in REPLY_PREFIXES {
            // Byte-safe ASCII case-insensitive prefix test.
            let Some(head) = s.get(..p.len()) else { continue };
            if !head.eq_ignore_ascii_case(p) {
                continue;
            }
            let mut rest = s[p.len()..].trim_start();
            if let Some(r) = rest.strip_prefix('[') {
                if let Some(c) = r.find(']') {
                    rest = r[c + 1..].trim_start();
                }
            } else if let Some(r) = rest.strip_prefix('(') {
                if let Some(c) = r.find(')') {
                    rest = r[c + 1..].trim_start();
                }
            }
            if let Some(body) = rest.strip_prefix(':') {
                s = body.trim_start();
                matched = true;
                break;
            }
        }
        if matched {
            continue;
        }

        break;
    }

    // Collapse runs of internal whitespace to a single space.
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Canonical key for subject-based threading: the normalized subject, lowercased
/// so case differences ("Report" vs "report") thread together. Returns "" for
/// subjects that carry no threadable text.
pub(crate) fn subject_match_key(subject: &str) -> String {
    normalize_subject(subject).to_lowercase()
}

#[cfg(test)]
mod tests {
    #[test]
    fn html_to_text_keeps_lines_and_drops_markup() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Beste W\u{e9}seem,</p>\
                    <p>Zie <b>bijlage</b> &amp; <img src=\"data:image/png;base64,AAAA\">z.s.m.</p><div>Groet<br>RVO</div></body></html>";
        assert_eq!(html_to_text(html), "Beste W\u{e9}seem,\n\nZie bijlage & z.s.m.\n\nGroet\nRVO");
    }

    use super::*;

    #[test]
    fn test_normalize_subject() {
        assert_eq!(normalize_subject("Re: Hello"), "Hello");
        assert_eq!(normalize_subject("RE: RE: Hello"), "Hello");
        assert_eq!(normalize_subject("Fwd: Re: Hello"), "Hello");
        assert_eq!(normalize_subject("FW: Hello"), "Hello");
        assert_eq!(normalize_subject("Hello"), "Hello");
        assert_eq!(normalize_subject("  Re:  Hello  "), "Hello");
    }

    #[test]
    fn extended_normalize_subject_handles_locales_and_tags() {
        assert_eq!(normalize_subject("AW: Bericht"), "Bericht"); // German
        assert_eq!(normalize_subject("SV: Rapport"), "Rapport"); // Scandinavian
        assert_eq!(normalize_subject("Antw: Vraag"), "Vraag"); // Dutch
        assert_eq!(normalize_subject("WG: Bericht"), "Bericht"); // German fwd
        assert_eq!(normalize_subject("Re[2]: Hello"), "Hello"); // bracketed count
        assert_eq!(normalize_subject("RE : spaced colon"), "spaced colon");
        assert_eq!(normalize_subject("[team-list] Standup notes"), "Standup notes");
        assert_eq!(normalize_subject("Fwd: [list] Re: Topic"), "Topic"); // mixed
        assert_eq!(normalize_subject("Re:  spread   out"), "spread out"); // ws collapse
        assert_eq!(normalize_subject("Re:"), ""); // bare prefix → no text
        // "Enc..." is only a forward prefix when followed by a colon.
        assert_eq!(normalize_subject("Encyclopedia entry"), "Encyclopedia entry");
    }

    #[test]
    fn normalize_subject_handles_non_latin_scripts() {
        // Colon-required non-Latin prefixes across scripts (parity with the Rails
        // SubjectNormalizer::NON_LATIN_PREFIXES set).
        assert_eq!(normalize_subject("답장: 회의"), "회의"); // Korean reply
        assert_eq!(normalize_subject("전달: 회의"), "회의"); // Korean forward
        assert_eq!(normalize_subject("返信: 会議"), "会議"); // Japanese reply
        assert_eq!(normalize_subject("転送: 会議"), "会議"); // Japanese forward
        assert_eq!(normalize_subject("השב: פגישה"), "פגישה"); // Hebrew
        assert_eq!(normalize_subject("رد: اجتماع"), "اجتماع"); // Arabic reply
        assert_eq!(normalize_subject("إعادة توجيه: اجتماع"), "اجتماع"); // Arabic fwd (multi-word)
        assert_eq!(normalize_subject("उत्तर: बैठक"), "बैठक"); // Hindi
        assert_eq!(normalize_subject("ΑΠ: Συνάντηση"), "Συνάντηση"); // Greek
        assert_eq!(normalize_subject("ПЕР: Встреча"), "Встреча"); // Russian forward
        assert_eq!(normalize_subject("НА: Среща"), "Среща"); // Bulgarian
        // Colon is REQUIRED for these: a bare prefix collides with ordinary words.
        assert_eq!(normalize_subject("НА масата има хляб"), "НА масата има хляб");
        // New Latin locales gained colon-required stripping too.
        assert_eq!(normalize_subject("YNT: konu"), "konu"); // Turkish
        assert_eq!(normalize_subject("Rép: Réunion"), "Réunion"); // French
        // Mixed-script stack: Chinese (colon-optional) then Latin Re.
        assert_eq!(normalize_subject("回复: Re: 项目更新"), "项目更新");
    }

    #[test]
    fn subject_match_key_is_case_insensitive() {
        assert_eq!(subject_match_key("Re: Report"), subject_match_key("report"));
        assert_eq!(subject_match_key("FWD: Hello"), "hello");
        assert_eq!(subject_match_key(""), "");
        assert_eq!(subject_match_key("Re:"), "");
    }

    #[test]
    fn build_snippet_prefers_html_then_plain() {
        assert_eq!(build_snippet(Some("hi there"), None), "hi there");
        // HTML wins over a stale/stub plain part (Gmail-style preview).
        assert_eq!(
            build_snippet(Some("Your email software can't display HTML"), Some("<p>Hi Waseem</p>")),
            "Hi Waseem"
        );
        // Image-only HTML falls back to the plain part.
        assert_eq!(build_snippet(Some("plain text"), Some("<img src=x>")), "plain text");
        // Falls back to HTML, stripped to bare text and whitespace-collapsed.
        assert_eq!(
            build_snippet(None, Some("<p>hello</p>\n  <b>world</b>")),
            "hello world"
        );
        // Empty plain part falls through to HTML.
        assert_eq!(build_snippet(Some("   "), Some("<p>fallback</p>")), "fallback");
        assert_eq!(build_snippet(None, None), "");
        // HTML source in the text/plain part is stripped, not shown verbatim.
        assert_eq!(
            build_snippet(Some("<!DOCTYPE html>\n  <html>\n  <head><title>ADCB</title></head>\n  <body>Hello world</body></html>"), None),
            "ADCB Hello world"
        );
        // A stray '<' in genuine prose is left alone.
        assert_eq!(build_snippet(Some("if a < b then ok"), None), "if a < b then ok");
        // HTML source in the text/plain part WITHOUT a leading doctype (the
        // ad-builder/marketing case) is still detected and stripped, so the raw
        // markup never leaks into the list preview or push notification.
        assert_eq!(
            build_snippet(
                Some("<div class=\"card\">\n  <h2>Cold-call pain</h2>\n  <textarea>Buyer ko call karna band karo.</textarea>\n  <button>Create draft ad</button>\n</div>"),
                None
            ),
            "Cold-call pain Buyer ko call karna band karo. Create draft ad"
        );
    }

    #[test]
    fn build_snippet_strips_lone_tracking_pixel_tag() {
        // The field case: a single tracking-pixel <img> in the text/plain part.
        // Only one tag, so looks_like_html_source ignores it — the residual-tag
        // pass in sanitize must still drop it (and its src URL) rather than let
        // strip_urls chew the URL out mid-tag into `<img src=" width="5" …>`.
        assert_eq!(
            build_snippet(
                Some("<img src=\"https://track.example.com/o.gif\" width=\"5\" height=\"5\" alt=\"\" /> Bekijk e-mail online"),
                None
            ),
            "Bekijk e-mail online"
        );
        // Prose with a stray '<' or unknown "<tag>" word is left untouched.
        assert_eq!(build_snippet(Some("use <name> and a < b"), None), "use <name> and a < b");
    }

    #[test]
    fn build_snippet_strips_decorative_separator_runs() {
        // The reported bug: Facebook's text/plain part opens with `====` rules,
        // so the push notification read "===== Learn more ===== Hi Waseem" while
        // Gmail's preview showed the real content.
        assert_eq!(
            build_snippet(
                Some("================================\nLearn more\n================================\nHi Waseem, we're opening up our ads MCP server"),
                None
            ),
            "Learn more Hi Waseem, we're opening up our ads MCP server"
        );
        // Mixed and unicode separator runs go too; short runs stay prose.
        assert_eq!(build_snippet(Some("a *~*~*~ b ——— c"), None), "a b c");
        assert_eq!(build_snippet(Some("re-send -- see C++ notes"), None), "re-send -- see C++ notes");
    }

    #[test]
    fn looks_like_html_source_needs_two_known_tags() {
        // Doctype/root marker short-circuits.
        assert!(looks_like_html_source("<!DOCTYPE html><html>"));
        assert!(looks_like_html_source("  <HTML lang=en>"));
        // Two or more recognisable element tags anywhere reads as HTML source.
        assert!(looks_like_html_source("<div><p>hi</p></div>"));
        assert!(looks_like_html_source("intro <br> then <img src=x>"));
        // A single tag, or none, stays prose (no over-stripping of real text).
        assert!(!looks_like_html_source("if a < b then ok"));
        assert!(!looks_like_html_source("email me at <a>")); // one tag only
        assert!(!looks_like_html_source("compare 5 < 10 and 10 > 5"));
        // Unknown "tag" words in prose don't count.
        assert!(!looks_like_html_source("use <name> and <place> placeholders"));
    }

    #[test]
    fn build_snippet_strips_leaked_css_and_preheader_padding() {
        // The field case: a marketing text/plain part that opens with a CSS rule
        // and pads the preview with zero-width junk after every glyph.
        assert_eq!(
            build_snippet(
                Some("Vestiaire Collective    * { font-family: Arial,\nsans-serif !important; }   Maybe it\u{2019}s time\u{034F}\u{200C} \u{034F}\u{200C} \u{034F}\u{200C}"),
                None
            ),
            "Vestiaire Collective Maybe it\u{2019}s time"
        );
        // Selector lists and nested @media bodies go too.
        assert_eq!(
            build_snippet(Some("Hi! .btn, a:hover { color: red } @media all { td { margin: 0 } } Sale on now"), None),
            "Hi! Sale on now"
        );
        // Prose braces that aren't declaration-shaped are kept.
        assert_eq!(build_snippet(Some("use {braces} wisely"), None), "use {braces} wisely");
    }

    #[test]
    fn build_snippet_rejoins_entities_split_by_line_wrapping() {
        // The field case: Thuisbezorgd's preheader padding, hard-wrapped at the
        // SMTP 998-byte line limit mid-reference. The HTML parser decoded the
        // truncated `&nbsp` and left the tail behind, so the push notification
        // read "Be a star and leave a review ; R 04; &n bsp; & #8204; …".
        assert_eq!(
            build_snippet(
                Some("<div>Be a star and leave a review</div>\n<div>&nbsp;&#8204;&nbsp\n;&#8204;&nbsp;&#820\n4;</div>\n<p>Would you recommend them?</p>"),
                None
            ),
            "Be a star and leave a review Would you recommend them?"
        );
        // Same break in a text/plain body (no tags to strip).
        assert_eq!(build_snippet(Some("3&nbsp\n;new &#82\n04;updates"), None), "3 new updates");
        // Prose that merely straddles a break is untouched — the body has to be
        // a reference we know before anything is joined.
        assert_eq!(build_snippet(Some("R &\nD; and Q&A"), None), "R & D; and Q&A");
        // Tab references (a mail-merge leftover) collapse instead of showing raw.
        assert_eq!(build_snippet(Some("Telefoon:010-4769447 &#x0009;&#x0009;De heer"), None), "Telefoon:010-4769447 De heer");
    }

    #[test]
    fn build_snippet_decodes_entities_from_html_only_mail() {
        // ammonia strips tags but leaves text HTML-escaped — the notification
        // field case: an HTML-only sender mail showing `&amp;`/`&#39;` raw.
        assert_eq!(
            build_snippet(None, Some("<p>Meta &amp; you &#8211; you&#39;ve got 3&nbsp;new updates&hellip;</p>")),
            "Meta & you \u{2013} you've got 3 new updates\u{2026}"
        );
        // Hex numeric form.
        assert_eq!(build_snippet(None, Some("it&#x2019;s here")), "it\u{2019}s here");
        // Decoded invisible-format entities are stripped like literal ones.
        assert_eq!(build_snippet(None, Some("pad&#8203;ded&zwnj; text")), "padded text");
    }

    #[test]
    fn text_entities_decode_angle_brackets_single_pass() {
        assert_eq!(decode_text_entities("Dashboard &gt; Leads &amp; Co"), "Dashboard > Leads & Co");
        assert_eq!(decode_text_entities("&amp;gt; &#60;b&#62;"), "&gt; <b>");
        assert_eq!(decode_html_entities("a &gt; b"), "a &gt; b");
    }

    #[test]
    fn entity_decoding_is_single_pass_and_never_emits_markup() {
        // Double-escaped input decodes one level only.
        assert_eq!(sanitize_snippet_text("&amp;lt;b&amp;gt;"), "&lt;b&gt;");
        // `lt`/`gt` (named or numeric) stay escaped: snippets are re-parsed as
        // HTML by some consumers, so decoding them could create live markup.
        assert_eq!(
            sanitize_snippet_text("&lt;img src=x onerror=alert(1)&gt; &#60;b&#62;"),
            "&lt;img src=x onerror=alert(1)&gt; &#60;b&#62;"
        );
        // Unknown entities and bare ampersands pass through unchanged.
        assert_eq!(sanitize_snippet_text("AT&T; R&D and Q&A"), "AT&T; R&D and Q&A");
    }

    #[test]
    fn entity_laden_snippets_are_not_fixed_points() {
        // The open-time scrub rebuilds any stored snippet that sanitize
        // changes — entity decoding must make pre-fix snippets dirty.
        let stored = "You&#39;re mentioned in a comment&nbsp;&mdash; reply now";
        assert_ne!(sanitize_snippet_text(stored), stored);
    }

    #[test]
    fn strips_inline_tracking_urls_from_snippet() {
        // The Treatwell case: a wrapped tracking link in the text/plain part.
        assert_eq!(
            build_snippet(
                Some("Nu live in de nieuwste 96 Hero image ( https://clicks.treatwell.com/f/a/6tE-ICN4hzqPMl7BfMqPEg~~/AAAHahA~/NFtcpMkHm7uRbZd ) Boek nu"),
                None,
            ),
            "Nu live in de nieuwste 96 Hero image Boek nu"
        );
        // Bare URL mid-sentence.
        assert_eq!(
            build_snippet(Some("Reset your password at https://example.com/reset?t=abc now"), None),
            "Reset your password at now"
        );
        // Bracket variants and http.
        assert_eq!(build_snippet(Some("See [http://example.com/x] here"), None), "See here");
        assert_eq!(build_snippet(Some("Link <https://example.com/y>"), None), "Link");
        // URL-free text is untouched (and a fixed point).
        assert_eq!(sanitize_snippet_text("no links here"), "no links here");
        // A snippet that still holds a raw URL must be rebuilt by the scrub.
        let stored = "Open ( https://clicks.example.com/abc ) to continue";
        assert_ne!(sanitize_snippet_text(stored), stored);
    }

    #[test]
    fn strips_leaked_cid_image_placeholders_from_snippet() {
        // The reported case: an inline-image content-id leaked into the
        // text/plain part fills the notification body with "[cid:logo_…]".
        assert_eq!(
            build_snippet(
                Some("Kindly approve Mandatory 'Component' Field [cid:logo_ecbea85b-c03e-44b5-a1f2@inbox2]"),
                None,
            ),
            "Kindly approve Mandatory 'Component' Field"
        );
        // Bracket variants and a bare ref mid-sentence.
        assert_eq!(build_snippet(Some("See <cid:abc@x> the logo"), None), "See the logo");
        assert_eq!(build_snippet(Some("Logo ( cid:abc@x ) here"), None), "Logo here");
        assert_eq!(build_snippet(Some("Top cid:hero_42@mail bottom"), None), "Top bottom");
        // A literal "cid:" with no content-id is ordinary text, left untouched.
        assert_eq!(sanitize_snippet_text("the cid: prefix"), "the cid: prefix");
        // cid-free text is a fixed point; a leaked one must be rebuilt by the scrub.
        assert_eq!(sanitize_snippet_text("no images here"), "no images here");
        let stored = "Field [cid:logo_ecbea85b@inbox2]";
        assert_ne!(sanitize_snippet_text(stored), stored);
    }
}

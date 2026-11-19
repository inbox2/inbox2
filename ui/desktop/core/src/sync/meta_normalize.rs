//! Normalize Meta webhook payloads into the unified conversation/message model.
//!
//! Pure functions: given a parsed webhook body, produce a flat list of
//! [`NormalizedMetaEvent`]s. No I/O, no provider calls — exhaustively unit-tested
//! against fixture payloads. The store-application + dedup happens in
//! `store::SyncStore::apply_meta_message`; the fetch/verify transport lives in
//! `sync/meta_push.rs` (step 6).
//!
//! Dispatch is on the payload's top-level `object`, not the receiving account's
//! channel, because one Page object carries both Messenger DMs *and* Facebook
//! Page feed comments, and one Instagram object carries DMs, comments and
//! @mentions. The per-message `channel` string is the finer surface
//! (`messenger`/`facebook`/`instagram`/`whatsapp`) used by the UI; the account's
//! [`MetaChannel`](crate::sync::model::MetaChannel) is the coarser account type.

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use std::collections::HashSet;

use crate::sync::model::{ProviderMessageId, UnifiedFlags, UnifiedMessage};

/// Surface a normalized event belongs to (mirrors `conversations.channel`).
pub mod channel {
    pub const MESSENGER: &str = "messenger";
    pub const FACEBOOK: &str = "facebook";
    pub const INSTAGRAM: &str = "instagram";
    pub const WHATSAPP: &str = "whatsapp";
}

/// Event kind (mirrors `messages.kind`).
pub mod kind {
    pub const DM: &str = "dm";
    pub const COMMENT: &str = "comment";
    pub const MENTION: &str = "mention";
    pub const POSTBACK: &str = "postback";
}

/// A normalized inbound message/comment/postback/mention ready to upsert.
#[derive(Debug, Clone)]
pub struct NormalizedMessage {
    pub msg: UnifiedMessage,
    pub provider_id: ProviderMessageId,
    /// Surface string for `conversations.channel` / `messages.channel`.
    pub channel: &'static str,
    /// Event kind for `messages.kind`.
    pub kind: &'static str,
    /// Reply target stored on the conversation (Messenger PSID / IG-scoped id /
    /// WhatsApp wa_id). `None` for comments (their reply target is the comment
    /// id, addressed per-message via `reply_to_message_key`).
    pub recipient_id: Option<String>,
    /// For inbound DMs, the timestamp that (re)opens the 24h customer-service
    /// window. `None` for comments/mentions (they don't open a CS window).
    pub window_inbound_at: Option<DateTime<Utc>>,
    /// WhatsApp media descriptors as JSON (`[{"id","mime","name"}]`) — WhatsApp
    /// delivers media by id, not URL, so it's fetched on demand via the Media API
    /// (`download_attachment`). `None` for text + URL-based (Messenger/IG) media.
    pub media: Option<String>,
}

/// One normalized webhook event.
#[derive(Debug, Clone)]
pub enum NormalizedMetaEvent {
    /// A new inbound message/comment/postback/mention.
    Message(Box<NormalizedMessage>),
    /// A reaction added/removed against an existing message.
    Reaction {
        target_id: String,
        emoji: Option<String>,
        removed: bool,
    },
    /// A delivery/read status for one of our outbound messages (WhatsApp; also
    /// Messenger delivery/read). `error_code` is set for `failed`.
    Status {
        target_id: String,
        status: String,
        error_code: Option<i64>,
    },
}

/// Normalize one webhook payload into a flat list of events. Unknown shapes are
/// skipped (returns an empty/partial list) rather than erroring — Meta adds
/// fields over time and a single unrecognized entry must not drop the batch.
pub fn normalize(payload: &Value) -> Vec<NormalizedMetaEvent> {
    match payload.get("object").and_then(|o| o.as_str()) {
        Some("page") => normalize_page(payload),
        Some("instagram") => normalize_instagram(payload),
        Some("whatsapp_business_account") => normalize_whatsapp(payload),
        _ => Vec::new(),
    }
}

// ── Messenger / Facebook Page (object: page) ─────────────────────────────────

fn normalize_page(payload: &Value) -> Vec<NormalizedMetaEvent> {
    let mut out = Vec::new();
    for entry in array(payload, "entry") {
        let entry_time = entry.get("time");
        // Messenger DMs / postbacks / reactions / delivery / read.
        for m in array(entry, "messaging") {
            push_messaging(&mut out, m, entry_time, channel::MESSENGER, "messenger");
        }
        // Facebook Page feed comments (and only comments — skip likes/statuses).
        for change in array(entry, "changes") {
            if change.get("field").and_then(|f| f.as_str()) == Some("feed") {
                if let Some(ev) = page_feed_comment(change.get("value")) {
                    out.push(ev);
                }
            }
        }
    }
    out
}

/// A Facebook Page `feed` change. We keep only `item == "comment"`; verb
/// `remove` is dropped (the comment is gone), `add`/`edit` upsert it.
fn page_feed_comment(value: Option<&Value>) -> Option<NormalizedMetaEvent> {
    let v = value?;
    if v.get("item").and_then(|i| i.as_str()) != Some("comment") {
        return None;
    }
    let verb = v.get("verb").and_then(|x| x.as_str()).unwrap_or("add");
    if verb == "remove" {
        return None;
    }
    let comment_id = str_field(v, "comment_id")?;
    let post_id = str_field(v, "post_id").unwrap_or_else(|| comment_id.clone());
    let text = str_field(v, "message").unwrap_or_default();
    let from = from_name(v.get("from"));
    let when = epoch_to_dt(v.get("created_time"));

    let msg = build_msg(
        &comment_id,
        format!("fb_comment:{post_id}"),
        from,
        text,
        when,
        false,
    );
    Some(NormalizedMetaEvent::Message(Box::new(NormalizedMessage {
        msg,
        provider_id: pid(&comment_id),
        channel: channel::FACEBOOK,
        kind: kind::COMMENT,
        recipient_id: None,
        window_inbound_at: None,
        media: None,
    })))
}

// ── Instagram (object: instagram) ────────────────────────────────────────────

fn normalize_instagram(payload: &Value) -> Vec<NormalizedMetaEvent> {
    let mut out = Vec::new();
    for entry in array(payload, "entry") {
        let entry_time = entry.get("time");
        for m in array(entry, "messaging") {
            push_messaging(&mut out, m, entry_time, channel::INSTAGRAM, "ig");
        }
        for change in array(entry, "changes") {
            match change.get("field").and_then(|f| f.as_str()) {
                Some("comments") => {
                    if let Some(ev) = ig_comment(change.get("value"), entry_time, kind::COMMENT) {
                        out.push(ev);
                    }
                }
                Some("mentions") => {
                    if let Some(ev) = ig_comment(change.get("value"), entry_time, kind::MENTION) {
                        out.push(ev);
                    }
                }
                _ => {}
            }
        }
    }
    out
}

fn ig_comment(value: Option<&Value>, entry_time: Option<&Value>, k: &'static str) -> Option<NormalizedMetaEvent> {
    let v = value?;
    let comment_id = str_field(v, "id").or_else(|| str_field(v, "comment_id"))?;
    // Comments thread under their media/post; mentions under the mentioned media.
    let media_id = v
        .get("media")
        .and_then(|m| m.get("id"))
        .and_then(|i| i.as_str())
        .map(str::to_string)
        .or_else(|| str_field(v, "media_id"))
        .unwrap_or_else(|| comment_id.clone());
    let text = str_field(v, "text").unwrap_or_default();
    let from = from_name(v.get("from"));
    let when = epoch_to_dt(v.get("created_time")).or_else(|| epoch_to_dt(entry_time));
    let thread = if k == kind::MENTION {
        format!("ig_mention:{media_id}")
    } else {
        format!("ig_comment:{media_id}")
    };
    let msg = build_msg(&comment_id, thread, from, text, when, false);
    Some(NormalizedMetaEvent::Message(Box::new(NormalizedMessage {
        msg,
        provider_id: pid(&comment_id),
        channel: channel::INSTAGRAM,
        kind: k,
        recipient_id: None,
        window_inbound_at: None,
        media: None,
    })))
}

// ── Shared messaging[] parser (Messenger + Instagram DMs) ────────────────────

fn push_messaging(
    out: &mut Vec<NormalizedMetaEvent>,
    m: &Value,
    entry_time: Option<&Value>,
    chan: &'static str,
    thread_prefix: &str,
) {
    let sender = m.get("sender").and_then(|s| s.get("id")).and_then(|i| i.as_str());
    // Live webhooks carry only `sender.id`; the Conversations-API backfill also
    // injects `sender.name` (from the message's `from`), so use it as the display
    // when present, falling back to the id. Threading always keys on the id.
    let sender_name = m.get("sender").and_then(|s| s.get("name")).and_then(|n| n.as_str());
    let when = epoch_to_dt(m.get("timestamp")).or_else(|| epoch_to_dt(entry_time));

    // Reaction.
    if let Some(reaction) = m.get("reaction") {
        if let Some(mid) = reaction.get("mid").and_then(|x| x.as_str()) {
            out.push(NormalizedMetaEvent::Reaction {
                target_id: mid.to_string(),
                emoji: reaction.get("emoji").and_then(|e| e.as_str()).map(str::to_string),
                removed: reaction.get("action").and_then(|a| a.as_str()) == Some("unreact"),
            });
            return;
        }
    }
    // Delivery / read receipts (for our outbound).
    if m.get("delivery").is_some() || m.get("read").is_some() {
        let status = if m.get("read").is_some() { "read" } else { "delivered" };
        // Messenger delivery carries mids[]; read carries a watermark (no mid).
        let mids = m.get("delivery").and_then(|d| d.get("mids")).and_then(|v| v.as_array());
        if let Some(mids) = mids {
            for mid in mids.iter().filter_map(|x| x.as_str()) {
                out.push(NormalizedMetaEvent::Status {
                    target_id: mid.to_string(),
                    status: status.to_string(),
                    error_code: None,
                });
            }
        }
        return;
    }
    // Postback (button tap).
    if let Some(pb) = m.get("postback") {
        let Some(sender) = sender else { return };
        let title = pb.get("title").and_then(|t| t.as_str()).unwrap_or_default();
        let payload = pb.get("payload").and_then(|p| p.as_str()).unwrap_or_default();
        let mid = pb
            .get("mid")
            .and_then(|x| x.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| format!("postback:{sender}:{}", when.map(|d| d.timestamp_millis()).unwrap_or(0)));
        let body = if title.is_empty() { payload.to_string() } else { format!("{title} ({payload})") };
        let msg = build_msg(&mid, format!("{thread_prefix}:{sender}"), sender_name.unwrap_or(sender).to_string(), body, when, true);
        out.push(NormalizedMetaEvent::Message(Box::new(NormalizedMessage {
            msg,
            provider_id: pid(&mid),
            channel: chan,
            kind: kind::POSTBACK,
            recipient_id: Some(sender.to_string()),
            window_inbound_at: when,
            media: None,
        })));
        return;
    }
    // Ordinary message (text and/or attachments). Skip echoes of our own sends.
    if let Some(message) = m.get("message") {
        if message.get("is_echo").and_then(|e| e.as_bool()) == Some(true) {
            return;
        }
        let Some(sender) = sender else { return };
        let Some(mid) = message.get("mid").and_then(|x| x.as_str()) else { return };
        let text = message.get("text").and_then(|t| t.as_str()).unwrap_or_default().to_string();
        let attachments = message.get("attachments").and_then(|a| a.as_array());
        let has_attachment = attachments.map(|a| !a.is_empty()).unwrap_or(false);
        let body = if text.is_empty() && has_attachment {
            attachment_placeholder(attachments)
        } else {
            text.clone()
        };
        let mut msg = build_msg(mid, format!("{thread_prefix}:{sender}"), sender_name.unwrap_or(sender).to_string(), body, when, true);
        msg.has_attachment = has_attachment;
        // Render image/file attachments inline (images) or as links (files) so the
        // reading pane shows the media; remote <img> routes through the privacy proxy.
        if let Some(atts) = attachments.filter(|a| !a.is_empty()) {
            let (names, html) = render_attachments(&text, atts);
            msg.attachment_names = names;
            msg.body_html = html;
        }
        // A reply to a specific message (story reply / quoted) — keep the link.
        if let Some(reply_to) = message.get("reply_to").and_then(|r| r.get("mid")).and_then(|x| x.as_str()) {
            msg.in_reply_to = Some(reply_to.to_string());
        }
        out.push(NormalizedMetaEvent::Message(Box::new(NormalizedMessage {
            msg,
            provider_id: pid(mid),
            channel: chan,
            kind: kind::DM,
            recipient_id: Some(sender.to_string()),
            window_inbound_at: when,
            media: None,
        })));
    }
}

// ── WhatsApp (object: whatsapp_business_account) ─────────────────────────────

fn normalize_whatsapp(payload: &Value) -> Vec<NormalizedMetaEvent> {
    let mut out = Vec::new();
    for entry in array(payload, "entry") {
        for change in array(entry, "changes") {
            if change.get("field").and_then(|f| f.as_str()) != Some("messages") {
                continue;
            }
            let Some(value) = change.get("value") else { continue };
            // Map wa_id → display name where the contacts[] block provides it.
            let contact_name = value
                .get("contacts")
                .and_then(|c| c.as_array())
                .and_then(|a| a.first())
                .and_then(|c| c.get("profile"))
                .and_then(|p| p.get("name"))
                .and_then(|n| n.as_str());

            for msg in array(value, "messages") {
                if let Some(ev) = wa_message(msg, contact_name) {
                    out.push(ev);
                }
            }
            for st in array(value, "statuses") {
                if let Some(ev) = wa_status(st) {
                    out.push(ev);
                }
            }
        }
    }
    out
}

fn wa_message(m: &Value, contact_name: Option<&str>) -> Option<NormalizedMetaEvent> {
    let wamid = str_field(m, "id")?;
    let from = str_field(m, "from")?; // wa_id (phone)
    let when = epoch_to_dt(m.get("timestamp"));
    let ty = m.get("type").and_then(|t| t.as_str()).unwrap_or("text");

    // A reaction is delivered as a message of type "reaction".
    if ty == "reaction" {
        if let Some(r) = m.get("reaction") {
            if let Some(target) = r.get("message_id").and_then(|x| x.as_str()) {
                return Some(NormalizedMetaEvent::Reaction {
                    target_id: target.to_string(),
                    emoji: r.get("emoji").and_then(|e| e.as_str()).map(str::to_string),
                    removed: r.get("emoji").and_then(|e| e.as_str()).map(|e| e.is_empty()).unwrap_or(false),
                });
            }
        }
        return None;
    }

    let body = match ty {
        "text" => m.get("text").and_then(|t| t.get("body")).and_then(|b| b.as_str()).unwrap_or_default().to_string(),
        "button" => m.get("button").and_then(|b| b.get("text")).and_then(|t| t.as_str()).unwrap_or_default().to_string(),
        "interactive" => wa_interactive_body(m.get("interactive")),
        "location" => "[location]".to_string(),
        "contacts" => "[contact]".to_string(),
        other => format!("[{other}]"),
    };
    let media_types = ["image", "video", "audio", "document", "sticker"];
    let has_attachment = media_types.contains(&ty);
    let body = if body.is_empty() && has_attachment { format!("[{ty}]") } else { body };

    // WhatsApp media is delivered by id (not URL) — capture {id, mime, name} so it
    // can be fetched on demand via the Media API. Filename only on documents.
    let media = if has_attachment {
        m.get(ty).map(|mo| {
            let id = mo.get("id").and_then(|x| x.as_str()).unwrap_or_default();
            let mime = mo.get("mime_type").and_then(|x| x.as_str()).unwrap_or_default();
            let name = mo
                .get("filename")
                .and_then(|x| x.as_str())
                .map(str::to_string)
                .unwrap_or_else(|| format!("{ty}-{id}"));
            serde_json::json!([{ "id": id, "mime": mime, "name": name }]).to_string()
        })
    } else {
        None
    };

    let display = contact_name.map(str::to_string).unwrap_or_else(|| from.clone());
    let mut msg = build_msg(&wamid, format!("wa:{from}"), display, body, when, true);
    msg.has_attachment = has_attachment;
    if let Some(ctx) = m.get("context").and_then(|c| c.get("id")).and_then(|x| x.as_str()) {
        msg.in_reply_to = Some(ctx.to_string());
    }
    Some(NormalizedMetaEvent::Message(Box::new(NormalizedMessage {
        msg,
        provider_id: pid(&wamid),
        channel: channel::WHATSAPP,
        kind: kind::DM,
        recipient_id: Some(from),
        window_inbound_at: when,
        media,
    })))
}

fn wa_interactive_body(interactive: Option<&Value>) -> String {
    let Some(i) = interactive else { return "[interactive]".to_string() };
    if let Some(r) = i.get("button_reply") {
        return r.get("title").and_then(|t| t.as_str()).unwrap_or("[button]").to_string();
    }
    if let Some(r) = i.get("list_reply") {
        return r.get("title").and_then(|t| t.as_str()).unwrap_or("[list]").to_string();
    }
    "[interactive]".to_string()
}

fn wa_status(s: &Value) -> Option<NormalizedMetaEvent> {
    let target = str_field(s, "id")?;
    let status = str_field(s, "status").unwrap_or_default();
    let error_code = s
        .get("errors")
        .and_then(|e| e.as_array())
        .and_then(|a| a.first())
        .and_then(|e| e.get("code"))
        .and_then(|c| c.as_i64());
    Some(NormalizedMetaEvent::Status { target_id: target, status, error_code })
}

// ── Builders & small helpers ─────────────────────────────────────────────────

pub(crate) fn build_msg(
    meta_id: &str,
    thread_id: String,
    from: String,
    body: String,
    when: Option<DateTime<Utc>>,
    inbound: bool,
) -> UnifiedMessage {
    UnifiedMessage {
        key: String::new(),
        message_id: meta_id.to_string(),
        subject: None,
        from_address: from,
        to_address: None,
        cc_address: None,
        in_reply_to: None,
        references_header: None,
        provider_thread_id: Some(thread_id),
        body_plain: Some(body),
        body_html: None,
        has_attachment: false,
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: inbound,
        flags: UnifiedFlags { read: !inbound, ..Default::default() },
        labels: HashSet::new(),
        folders: HashSet::new(),
        date: when,
        internal_date: when,
    }
}

/// Build a Gmail/Microsoft-shaped provider id (NULL uid → dedup on
/// provider_message_id, exactly like the other label/folder providers).
pub(crate) fn pid(meta_id: &str) -> ProviderMessageId {
    ProviderMessageId { uid: None, mod_seq: None, provider_id: Some(meta_id.to_string()) }
}

fn attachment_placeholder(attachments: Option<&Vec<Value>>) -> String {
    let ty = attachments
        .and_then(|a| a.first())
        .and_then(|a| a.get("type"))
        .and_then(|t| t.as_str())
        .unwrap_or("attachment");
    format!("[{ty}]")
}

/// Minimal HTML/attribute escaping for untrusted text/URLs embedded in the
/// generated attachment HTML (we don't bundle a templating crate).
fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Build `(attachment_names, body_html)` from webhook-shape `attachments[]`
/// (`{type, payload:{url}, name?}`). Images render inline; everything else as a
/// download link. `text` (if any) leads the HTML so caption + media stay together.
/// Returns `(None, None)` when there are no attachments.
fn render_attachments(text: &str, attachments: &[Value]) -> (Option<String>, Option<String>) {
    if attachments.is_empty() {
        return (None, None);
    }
    let mut names = Vec::new();
    let mut html = String::new();
    if !text.is_empty() {
        html.push_str(&format!("<p>{}</p>", esc(text)));
    }
    for a in attachments {
        let ty = a.get("type").and_then(|t| t.as_str()).unwrap_or("file");
        let url = a.get("payload").and_then(|p| p.get("url")).and_then(|u| u.as_str());
        let name = a
            .get("name")
            .and_then(|n| n.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| format!("{ty} attachment"));
        names.push(name.clone());
        match (ty, url) {
            ("image", Some(u)) => {
                html.push_str(&format!("<p><img src=\"{}\" alt=\"{}\" /></p>", esc(u), esc(&name)))
            }
            (_, Some(u)) => {
                html.push_str(&format!("<p><a href=\"{}\">{}</a></p>", esc(u), esc(&name)))
            }
            (_, None) => html.push_str(&format!("<p>[{}]</p>", esc(ty))),
        }
    }
    (Some(names.join(" ")), Some(html))
}

fn array<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v.get(key).and_then(|x| x.as_array()).map(|a| a.as_slice()).unwrap_or(&[])
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(str::to_string)
}

/// A sender object's display label: `username` (IG) or `name` (FB) when present,
/// else the raw id.
fn from_name(from: Option<&Value>) -> String {
    let Some(f) = from else { return String::new() };
    f.get("username")
        .and_then(|u| u.as_str())
        .or_else(|| f.get("name").and_then(|n| n.as_str()))
        .or_else(|| f.get("id").and_then(|i| i.as_str()))
        .unwrap_or_default()
        .to_string()
}

/// Parse a Meta timestamp: an epoch in seconds or milliseconds (number or
/// string). Meta is inconsistent — messaging uses ms, WhatsApp uses string
/// seconds, feed uses seconds. Heuristic: values past ~ year 2001 in seconds
/// (>1e11) are already milliseconds.
fn epoch_to_dt(v: Option<&Value>) -> Option<DateTime<Utc>> {
    let n: i64 = match v? {
        Value::Number(num) => num.as_i64()?,
        Value::String(s) => s.parse().ok()?,
        _ => return None,
    };
    if n <= 0 {
        return None;
    }
    let ms = if n > 100_000_000_000 { n } else { n * 1000 };
    Utc.timestamp_millis_opt(ms).single()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn messages(events: &[NormalizedMetaEvent]) -> Vec<&NormalizedMessage> {
        events
            .iter()
            .filter_map(|e| match e {
                NormalizedMetaEvent::Message(m) => Some(m.as_ref()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn messenger_text_dm() {
        let p = json!({
            "object": "page",
            "entry": [{ "id": "PAGE", "time": 1700000000000i64, "messaging": [{
                "sender": { "id": "PSID1" }, "recipient": { "id": "PAGE" },
                "timestamp": 1700000000000i64,
                "message": { "mid": "mid.1", "text": "hello there" }
            }]}]
        });
        let ev = normalize(&p);
        let msgs = messages(&ev);
        assert_eq!(msgs.len(), 1);
        let m = msgs[0];
        assert_eq!(m.channel, channel::MESSENGER);
        assert_eq!(m.kind, kind::DM);
        assert_eq!(m.msg.message_id, "mid.1");
        assert_eq!(m.msg.provider_thread_id.as_deref(), Some("messenger:PSID1"));
        assert_eq!(m.msg.body_plain.as_deref(), Some("hello there"));
        assert!(m.msg.is_inbound);
        assert_eq!(m.recipient_id.as_deref(), Some("PSID1"));
        assert!(m.window_inbound_at.is_some());
    }

    #[test]
    fn messenger_attachment_and_postback_and_reaction() {
        let p = json!({
            "object": "page",
            "entry": [{ "id": "PAGE", "time": 1700000000000i64, "messaging": [
                { "sender": {"id":"P"}, "message": {"mid":"m1","attachments":[{"type":"image","payload":{"url":"u"}}]}},
                { "sender": {"id":"P"}, "postback": {"mid":"m2","title":"Get Started","payload":"GS"}},
                { "sender": {"id":"P"}, "reaction": {"mid":"m1","action":"react","emoji":"❤"}}
            ]}]
        });
        let ev = normalize(&p);
        let msgs = messages(&ev);
        // Attachment DM + postback message.
        assert_eq!(msgs.len(), 2);
        assert!(msgs[0].msg.has_attachment);
        assert_eq!(msgs[0].msg.body_plain.as_deref(), Some("[image]"));
        // The image renders inline as HTML (proxied at display time) + a name.
        let html = msgs[0].msg.body_html.as_deref().unwrap_or("");
        assert!(html.contains("<img src=\"u\""), "expected inline <img>, got: {html}");
        assert!(msgs[0].msg.attachment_names.is_some());
        assert_eq!(msgs[1].kind, kind::POSTBACK);
        assert_eq!(msgs[1].msg.body_plain.as_deref(), Some("Get Started (GS)"));
        // Reaction is an update, not a message.
        assert!(matches!(&ev[2], NormalizedMetaEvent::Reaction { target_id, .. } if target_id == "m1"));
    }

    #[test]
    fn messenger_echo_is_skipped() {
        let p = json!({
            "object": "page",
            "entry": [{ "id": "PAGE", "messaging": [{
                "sender": {"id":"PAGE"}, "message": {"mid":"e1","text":"our reply","is_echo": true}
            }]}]
        });
        assert!(messages(&normalize(&p)).is_empty());
    }

    #[test]
    fn facebook_feed_keeps_only_comments() {
        let p = json!({
            "object": "page",
            "entry": [{ "id":"PAGE", "changes": [
                { "field":"feed", "value": {"item":"comment","comment_id":"c1","post_id":"p1","message":"nice!","from":{"id":"u","name":"Ann"},"verb":"add","created_time":1700000000}},
                { "field":"feed", "value": {"item":"like","verb":"add"}},
                { "field":"feed", "value": {"item":"comment","comment_id":"c2","verb":"remove"}}
            ]}]
        });
        let ev = normalize(&p);
        let msgs = messages(&ev);
        assert_eq!(msgs.len(), 1, "only the added comment, not the like or the removal");
        assert_eq!(msgs[0].channel, channel::FACEBOOK);
        assert_eq!(msgs[0].kind, kind::COMMENT);
        assert_eq!(msgs[0].msg.from_address, "Ann");
        assert_eq!(msgs[0].msg.provider_thread_id.as_deref(), Some("fb_comment:p1"));
        assert!(msgs[0].recipient_id.is_none());
    }

    #[test]
    fn instagram_dm_comment_and_mention() {
        let p = json!({
            "object": "instagram",
            "entry": [{ "id":"IG", "time": 1700000000000i64,
                "messaging": [{ "sender":{"id":"IGSID"}, "message":{"mid":"ig.m1","text":"dm hi"}}],
                "changes": [
                    { "field":"comments", "value":{"id":"igc1","text":"love it","from":{"id":"x","username":"fan"},"media":{"id":"media1"}}},
                    { "field":"mentions", "value":{"id":"igm1","media_id":"media2","text":"@me look"}}
                ]
            }]
        });
        let ev = normalize(&p);
        let msgs = messages(&ev);
        assert_eq!(msgs.len(), 3);
        let dm = msgs.iter().find(|m| m.kind == kind::DM).unwrap();
        assert_eq!(dm.channel, channel::INSTAGRAM);
        assert_eq!(dm.msg.provider_thread_id.as_deref(), Some("ig:IGSID"));
        let comment = msgs.iter().find(|m| m.kind == kind::COMMENT).unwrap();
        assert_eq!(comment.msg.from_address, "fan");
        assert_eq!(comment.msg.provider_thread_id.as_deref(), Some("ig_comment:media1"));
        let mention = msgs.iter().find(|m| m.kind == kind::MENTION).unwrap();
        assert_eq!(mention.msg.provider_thread_id.as_deref(), Some("ig_mention:media2"));
    }

    #[test]
    fn whatsapp_text_message_and_status() {
        let p = json!({
            "object": "whatsapp_business_account",
            "entry": [{ "id":"WABA", "changes": [{
                "field":"messages",
                "value": {
                    "metadata": {"phone_number_id":"PNID"},
                    "contacts": [{"profile":{"name":"Sam"},"wa_id":"15551234567"}],
                    "messages": [{"from":"15551234567","id":"wamid.1","timestamp":"1700000000","type":"text","text":{"body":"hi shop"}}],
                    "statuses": [{"id":"wamid.out1","status":"delivered","timestamp":"1700000005","recipient_id":"15551234567"}]
                }
            }]}]
        });
        let ev = normalize(&p);
        let msgs = messages(&ev);
        assert_eq!(msgs.len(), 1);
        let m = msgs[0];
        assert_eq!(m.channel, channel::WHATSAPP);
        assert_eq!(m.msg.message_id, "wamid.1");
        assert_eq!(m.msg.from_address, "Sam");
        assert_eq!(m.msg.provider_thread_id.as_deref(), Some("wa:15551234567"));
        assert_eq!(m.recipient_id.as_deref(), Some("15551234567"));
        assert!(m.window_inbound_at.is_some());
        // Status update present.
        assert!(matches!(&ev[1], NormalizedMetaEvent::Status { target_id, status, .. }
            if target_id == "wamid.out1" && status == "delivered"));
    }

    #[test]
    fn whatsapp_failed_status_carries_error_code() {
        let p = json!({
            "object": "whatsapp_business_account",
            "entry": [{ "id":"WABA", "changes": [{
                "field":"messages",
                "value": { "statuses": [{"id":"wamid.x","status":"failed","errors":[{"code":131049,"title":"freq cap"}]}] }
            }]}]
        });
        let ev = normalize(&p);
        assert!(matches!(&ev[0], NormalizedMetaEvent::Status { error_code: Some(131049), .. }));
    }

    #[test]
    fn whatsapp_media_message_marks_attachment() {
        let p = json!({
            "object": "whatsapp_business_account",
            "entry": [{ "id":"WABA", "changes": [{
                "field":"messages",
                "value": { "messages": [{"from":"1555","id":"wamid.img","timestamp":"1700000000","type":"image","image":{"id":"mediaid"}}] }
            }]}]
        });
        let m = messages(&normalize(&p))[0].clone();
        assert!(m.msg.has_attachment);
        assert_eq!(m.msg.body_plain.as_deref(), Some("[image]"));
        // The media id is captured for on-demand fetch via the Media API.
        let media = m.media.as_deref().unwrap_or("");
        assert!(media.contains("\"id\":\"mediaid\""), "media json: {media}");
    }

    #[test]
    fn unknown_object_yields_nothing() {
        assert!(normalize(&json!({"object":"unknown","entry":[]})).is_empty());
        assert!(normalize(&json!({})).is_empty());
    }

    #[test]
    fn timestamp_seconds_and_millis_both_parse() {
        // seconds
        let s = epoch_to_dt(Some(&json!("1700000000"))).unwrap();
        // millis
        let ms = epoch_to_dt(Some(&json!(1700000000000i64))).unwrap();
        assert_eq!(s.timestamp(), 1700000000);
        assert_eq!(ms.timestamp(), 1700000000);
    }
}

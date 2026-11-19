//! Shared MIME parsing for the IMAP path.
//!
//! Gmail and Microsoft return a pre-decomposed JSON payload (parts, bodies,
//! attachment ids) from their APIs. IMAP gives us only the raw RFC822 bytes, so
//! we parse them ourselves with `mailparse` into the same shape the interactive
//! provider needs: a plain body, an HTML body, and a flat list of parts that are
//! attachments or inline images.
//!
//! Part numbering follows the IMAP convention (RFC 3501 §6.4.5): a non-multipart
//! message is part `1`; a multipart's children are `1`, `2`, …; nested parts are
//! `2.1`, `2.2`, … These ids are what the UI hands back to `download_attachment`.

use mailparse::{DispositionType, MailHeaderMap, ParsedMail};

/// One non-body MIME part — a real attachment or an inline (e.g. `cid:`) image.
#[derive(Debug, Clone)]
pub struct MimeAttachment {
    /// IMAP-style part path (`2`, `2.1`). Stable id for `download_attachment`.
    pub part_id: String,
    pub filename: String,
    pub mime_type: String,
    pub size: u64,
    /// `Content-ID` with the surrounding `<>` stripped, when present.
    pub content_id: Option<String>,
    /// Shown inside the HTML body via its `cid:` reference (see [`is_inline_part`]).
    pub is_inline: bool,
    /// Transfer-decoded bytes (base64 / quoted-printable already undone).
    pub data: Vec<u8>,
}

/// The result of parsing one raw message.
#[derive(Debug, Clone, Default)]
pub struct ParsedMime {
    pub body_plain: Option<String>,
    pub body_html: Option<String>,
    /// Both real attachments and inline parts (distinguished by `is_inline`).
    pub attachments: Vec<MimeAttachment>,
}

/// Parse a raw RFC822 message into bodies + attachment parts. On a parse error
/// the raw bytes are surfaced as a best-effort plain body so the message is
/// never rendered blank.
pub fn parse_message(raw: &[u8]) -> ParsedMime {
    let mut out = ParsedMime::default();
    match mailparse::parse_mail(raw) {
        Ok(root) => {
            if is_multipart(&root) {
                for (i, child) in root.subparts.iter().enumerate() {
                    walk(child, &(i + 1).to_string(), &mut out);
                }
            } else {
                walk(&root, "1", &mut out);
            }
        }
        Err(_) => {
            out.body_plain = Some(String::from_utf8_lossy(raw).to_string());
        }
    }
    // The HTML body can come after its images, so the cid check runs once the walk is done.
    for a in &mut out.attachments {
        a.is_inline = a.is_inline && is_inline_part(false, a.content_id.as_deref(), out.body_html.as_deref());
    }
    out
}

/// Whether a part is displayed inside the HTML body rather than listed as an attachment.
///
/// A `Content-ID` alone proves nothing: Gmail stamps one on every attachment it sends, and a
/// forwarded message keeps images its new HTML no longer references. So a part is inline only
/// when it isn't marked `attachment`, has a Content-ID, and the HTML actually uses `cid:<id>`.
/// With no HTML to check (a metadata-only fetch) a Content-ID is taken at its word.
pub fn is_inline_part(attachment_disposition: bool, content_id: Option<&str>, html: Option<&str>) -> bool {
    match (attachment_disposition, content_id, html) {
        (true, _, _) | (false, None, _) => false,
        (false, Some(cid), Some(h)) => h.to_ascii_lowercase().contains(&format!("cid:{}", cid.to_ascii_lowercase())),
        (false, Some(_), None) => true,
    }
}

fn is_multipart(part: &ParsedMail) -> bool {
    part.ctype.mimetype.to_lowercase().starts_with("multipart/")
}

fn walk(part: &ParsedMail, id: &str, out: &mut ParsedMime) {
    if is_multipart(part) {
        for (i, child) in part.subparts.iter().enumerate() {
            walk(child, &format!("{id}.{}", i + 1), out);
        }
        return;
    }

    let mime = part.ctype.mimetype.to_lowercase();
    let disposition = part.get_content_disposition();
    let filename = disposition
        .params
        .get("filename")
        .cloned()
        .or_else(|| part.ctype.params.get("name").cloned())
        .unwrap_or_default();
    let content_id = part
        .headers
        .get_first_value("Content-ID")
        .map(|v| v.trim().trim_matches(|c| c == '<' || c == '>').to_string())
        .filter(|s| !s.is_empty());

    let is_attachment_disposition = matches!(disposition.disposition, DispositionType::Attachment);
    // Provisional: parse_message confirms the cid is referenced once the HTML body is known.
    let is_inline = is_inline_part(is_attachment_disposition, content_id.as_deref(), None);

    // A text part with no filename and not flagged as an attachment is body
    // content; everything else (named parts, non-text, inline images) is a part.
    let is_body_candidate =
        !is_attachment_disposition && filename.is_empty() && content_id.is_none();

    if is_body_candidate && mime == "text/plain" {
        if out.body_plain.is_none() {
            out.body_plain = decode_text_body(part)
                .inspect_err(|e| log::warn!("text/plain body part unparseable, dropped: {e}"))
                .ok()
                .map(strip_boundary_crlf);
        }
        return;
    }
    if is_body_candidate && mime == "text/html" {
        if out.body_html.is_none() {
            out.body_html = decode_text_body(part)
                .inspect_err(|e| log::warn!("text/html body part unparseable, dropped: {e}"))
                .ok()
                .map(strip_boundary_crlf);
        }
        return;
    }

    // Treat as an attachment / inline part.
    let data = part.get_body_raw().unwrap_or_else(|e| {
        log::warn!("attachment part body unparseable, stored empty: {e}");
        Vec::new()
    });
    let filename = if !filename.is_empty() {
        filename
    } else if let Some(cid) = &content_id {
        format!("{cid}.{}", ext_for_mime(&mime))
    } else {
        "attachment".to_string()
    };
    out.attachments.push(MimeAttachment {
        part_id: id.to_string(),
        size: data.len() as u64,
        filename,
        mime_type: if mime.is_empty() {
            "application/octet-stream".to_string()
        } else {
            mime
        },
        content_id,
        is_inline,
        data,
    });
}

/// Transfer-decode a text body part and resolve it to a UTF-8 string.
///
/// `mailparse::get_body()` decodes using the part's declared charset, which
/// defaults to `us-ascii` when none is present — and the `charset` crate maps
/// `us-ascii`/`iso-8859-1` to windows-1252 (WHATWG). So a UTF-8 body in a part
/// that omits the charset, or mislabels it `iso-8859-1`, is decoded as
/// windows-1252 and a UTF-8 "ë" (`0xC3 0xAB`) renders as "Ã«" — mojibake in the
/// list preview and notification body.
///
/// We instead transfer-decode to raw bytes and try UTF-8 first: valid UTF-8 is
/// almost never an accident, so it wins outright and fixes the mislabelled /
/// unlabelled case. Only when the bytes are not valid UTF-8 do we honour the
/// declared charset, falling back to windows-1252 (the latin1 superset that
/// decodes every byte) for unknown labels.
fn decode_text_body(part: &ParsedMail) -> Result<String, mailparse::MailParseError> {
    let raw = part.get_body_raw()?;
    if let Ok(s) = std::str::from_utf8(&raw) {
        return Ok(s.to_string());
    }
    let cs = charset::Charset::for_label(part.ctype.charset.as_bytes())
        .or_else(|| charset::Charset::for_label(b"windows-1252"))
        .expect("windows-1252 is always available");
    Ok(cs.decode(&raw).0.into_owned())
}

/// Strip the single trailing CRLF (or lone LF) that `mailparse` leaves on a
/// body part inside a multipart container — per RFC 2046 the CRLF preceding the
/// `--boundary` delimiter belongs to the delimiter, not the body content.
fn strip_boundary_crlf(mut s: String) -> String {
    if s.ends_with("\r\n") {
        s.truncate(s.len() - 2);
    } else if s.ends_with('\n') {
        s.truncate(s.len() - 1);
    }
    s
}

/// Best-effort file extension for a MIME type, used to name inline parts that
/// carry only a `Content-ID`.
fn ext_for_mime(mime: &str) -> &'static str {
    match mime {
        "image/png" => "png",
        "image/jpeg" | "image/jpg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/svg+xml" => "svg",
        _ => "bin",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_only() {
        let raw = b"Subject: Hi\r\nContent-Type: text/plain\r\n\r\nhello world";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("hello world"));
        assert!(m.body_html.is_none());
        assert!(m.attachments.is_empty());
    }

    #[test]
    fn prefers_html_and_plain_from_alternative() {
        let raw = b"Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n\
--b\r\nContent-Type: text/plain\r\n\r\nplain body\r\n\
--b\r\nContent-Type: text/html\r\n\r\n<p>html body</p>\r\n\
--b--\r\n";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("plain body"));
        assert_eq!(m.body_html.as_deref(), Some("<p>html body</p>"));
    }

    #[test]
    fn decodes_quoted_printable_body() {
        let raw = b"Content-Type: text/plain; charset=UTF-8\r\n\
Content-Transfer-Encoding: quoted-printable\r\n\r\ncaf=C3=A9";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("café"));
    }

    #[test]
    fn decodes_latin1_body_by_declared_charset() {
        // Genuine iso-8859-1: "cliënt" with ë = byte 0xEB (invalid UTF-8), so
        // the declared charset is honoured.
        let raw = b"Content-Type: text/plain; charset=iso-8859-1\r\n\
Content-Transfer-Encoding: quoted-printable\r\n\r\ncli=EBnt";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("cliënt"));
    }

    #[test]
    fn utf8_body_mislabelled_latin1_is_not_mojibake() {
        // Sender bug: a UTF-8 body (ë = 0xC3 0xAB) labelled iso-8859-1. Decoding
        // by the label would yield "cliÃ«nt"; trying UTF-8 first recovers it.
        let raw = b"Content-Type: text/plain; charset=iso-8859-1\r\n\
Content-Transfer-Encoding: 8bit\r\n\r\ncli\xc3\xabnt";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("cliënt"));
    }

    #[test]
    fn utf8_body_without_declared_charset_is_not_mojibake() {
        // No charset param → mailparse defaults to us-ascii → windows-1252,
        // which would mangle the UTF-8 bytes. UTF-8-first decoding fixes it.
        let raw = b"Content-Type: text/plain\r\n\
Content-Transfer-Encoding: 8bit\r\n\r\nGeachte cli\xc3\xabnt";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("Geachte cliënt"));
    }

    #[test]
    fn extracts_base64_attachment_and_skips_it_from_body() {
        // multipart/mixed: a text part + a base64 PDF attachment.
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"PDFDATA");
        let raw = format!(
            "Content-Type: multipart/mixed; boundary=\"x\"\r\n\r\n\
--x\r\nContent-Type: text/plain\r\n\r\nsee attached\r\n\
--x\r\nContent-Type: application/pdf; name=\"doc.pdf\"\r\n\
Content-Disposition: attachment; filename=\"doc.pdf\"\r\n\
Content-Transfer-Encoding: base64\r\n\r\n{b64}\r\n\
--x--\r\n"
        );
        let m = parse_message(raw.as_bytes());
        assert_eq!(m.body_plain.as_deref(), Some("see attached"));
        assert_eq!(m.attachments.len(), 1);
        let att = &m.attachments[0];
        assert_eq!(att.filename, "doc.pdf");
        assert_eq!(att.mime_type, "application/pdf");
        assert!(!att.is_inline);
        assert_eq!(att.data, b"PDFDATA");
        assert_eq!(att.part_id, "2");
    }

    /// Gmail stamps a Content-ID on every attachment, and a forward keeps images its HTML no
    /// longer shows. Both must list as attachments (2026-09-28: nine logos went missing).
    #[test]
    fn content_id_alone_does_not_make_a_part_inline() {
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"PNG");
        let raw = format!(
            "Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n\
--m\r\nContent-Type: text/html\r\n\r\n<p>see attached</p>\r\n\
--m\r\nContent-Type: image/png; name=\"a.png\"\r\nContent-Disposition: attachment; filename=\"a.png\"\r\n\
Content-ID: <f_a>\r\nContent-Transfer-Encoding: base64\r\n\r\n{b64}\r\n\
--m\r\nContent-Type: image/png; name=\"b.png\"\r\nContent-ID: <f_b>\r\n\
Content-Transfer-Encoding: base64\r\n\r\n{b64}\r\n\
--m--\r\n"
        );
        let m = parse_message(raw.as_bytes());
        assert_eq!(m.attachments.len(), 2);
        assert!(m.attachments.iter().all(|a| !a.is_inline));
    }

    #[test]
    fn is_inline_part_needs_a_referenced_cid() {
        assert!(!is_inline_part(true, Some("x"), Some("<img src=\"cid:x\">")));
        assert!(!is_inline_part(false, None, Some("<img src=\"cid:x\">")));
        assert!(!is_inline_part(false, Some("x"), Some("<p>no image</p>")));
        assert!(is_inline_part(false, Some("x"), Some("<img src=\"CID:x\">")));
        assert!(is_inline_part(false, Some("x"), None));
    }

    #[test]
    fn flags_inline_image_with_content_id() {
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"PNG");
        let raw = format!(
            "Content-Type: multipart/related; boundary=\"r\"\r\n\r\n\
--r\r\nContent-Type: text/html\r\n\r\n<img src=\"cid:logo\">\r\n\
--r\r\nContent-Type: image/png\r\nContent-ID: <logo>\r\n\
Content-Transfer-Encoding: base64\r\n\r\n{b64}\r\n\
--r--\r\n"
        );
        let m = parse_message(raw.as_bytes());
        assert_eq!(m.body_html.as_deref(), Some("<img src=\"cid:logo\">"));
        assert_eq!(m.attachments.len(), 1);
        let img = &m.attachments[0];
        assert!(img.is_inline);
        assert_eq!(img.content_id.as_deref(), Some("logo"));
        assert_eq!(img.mime_type, "image/png");
    }

    #[test]
    fn nested_multipart_part_ids() {
        // mixed -> [ alternative -> [plain, html], pdf ]
        let raw = b"Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n\
--m\r\nContent-Type: multipart/alternative; boundary=\"a\"\r\n\r\n\
--a\r\nContent-Type: text/plain\r\n\r\nP\r\n\
--a\r\nContent-Type: text/html\r\n\r\n<b>H</b>\r\n\
--a--\r\n\
--m\r\nContent-Type: application/octet-stream; name=\"f.bin\"\r\n\
Content-Disposition: attachment; filename=\"f.bin\"\r\n\r\nrawbytes\r\n\
--m--\r\n";
        let m = parse_message(raw);
        assert_eq!(m.body_plain.as_deref(), Some("P"));
        assert_eq!(m.body_html.as_deref(), Some("<b>H</b>"));
        assert_eq!(m.attachments.len(), 1);
        assert_eq!(m.attachments[0].part_id, "2");
    }
}

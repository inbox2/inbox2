use sha2::{Digest, Sha256};

/// Maximum characters per chunk (~512 tokens).
const MAX_CHUNK_CHARS: usize = 2000;

/// Overlap between adjacent chunks (20%).
const OVERLAP_CHARS: usize = 400;

/// A chunk of text ready for embedding.
#[derive(Debug, Clone)]
pub struct TextChunk {
    pub text: String,
    pub chunk_index: usize,
    pub text_hash: String,
}

/// Extract embeddable text from a message, chunked for the embedding model.
///
/// Strategy:
/// - Prefer `body_plain`; fall back to HTML stripped via `ammonia`.
/// - Prepend metadata prefix (From / Subject) to improve retrieval quality.
/// - Split on paragraph boundaries at ~2000 chars with 20% overlap.
/// - SHA-256 hash each chunk for dedup (skip re-embedding unchanged content).
pub fn chunk_message(
    from: &str,
    subject: Option<&str>,
    body_plain: Option<&str>,
    body_html: Option<&str>,
) -> Vec<TextChunk> {
    let body = extract_plain_text(body_plain, body_html);
    if body.trim().is_empty() {
        return Vec::new();
    }

    // Metadata prefix for retrieval quality
    let prefix = format!(
        "From: {} | Subject: {} | ",
        from,
        subject.unwrap_or("(no subject)")
    );

    let full_text = format!("{prefix}{body}");

    if full_text.len() <= MAX_CHUNK_CHARS {
        let hash = sha256_hex(&full_text);
        return vec![TextChunk {
            text: full_text,
            chunk_index: 0,
            text_hash: hash,
        }];
    }

    // Split into overlapping chunks on paragraph boundaries
    split_into_chunks(&full_text)
}

/// Strip HTML to plain text, or return body_plain directly.
fn extract_plain_text(body_plain: Option<&str>, body_html: Option<&str>) -> String {
    if let Some(plain) = body_plain {
        if !plain.trim().is_empty() {
            return plain.to_string();
        }
    }
    if let Some(html) = body_html {
        // Strip ALL HTML tags by allowing none — ammonia::clean() keeps safe
        // tags, but we want pure text for embeddings.
        return ammonia::Builder::new()
            .tags(std::collections::HashSet::new())
            .clean(html)
            .to_string();
    }
    String::new()
}

fn split_into_chunks(text: &str) -> Vec<TextChunk> {
    let mut chunks = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let total = chars.len();
    let mut start = 0;

    while start < total {
        let end = (start + MAX_CHUNK_CHARS).min(total);

        // Try to break on a paragraph or sentence boundary
        let actual_end = if end < total {
            find_break_point(&chars, start, end)
        } else {
            end
        };

        let chunk_text: String = chars[start..actual_end].iter().collect();
        let hash = sha256_hex(&chunk_text);
        chunks.push(TextChunk {
            text: chunk_text,
            chunk_index: chunks.len(),
            text_hash: hash,
        });

        // Advance with overlap, but always move forward by at least one char.
        // A degenerate break point (e.g. a single token longer than the overlap
        // window with no whitespace) could otherwise leave `start` unchanged and
        // spin forever.
        let advance = if actual_end - start > OVERLAP_CHARS {
            actual_end - start - OVERLAP_CHARS
        } else {
            actual_end - start
        };
        start += advance.max(1);
    }

    chunks
}

/// Find the best break point near `target` by looking for paragraph breaks,
/// then sentence breaks, then word breaks.
fn find_break_point(chars: &[char], start: usize, target: usize) -> usize {
    // Search window: look back up to 200 chars from target
    let search_start = if target > start + 200 {
        target - 200
    } else {
        start
    };

    // Prefer double-newline (paragraph break)
    for i in (search_start..target).rev() {
        if i + 1 < chars.len() && chars[i] == '\n' && chars[i + 1] == '\n' {
            return i + 2;
        }
    }

    // Fall back to sentence-ending punctuation followed by space
    for i in (search_start..target).rev() {
        if i + 1 < chars.len()
            && (chars[i] == '.' || chars[i] == '!' || chars[i] == '?')
            && chars[i + 1].is_whitespace()
        {
            return i + 1;
        }
    }

    // Fall back to any whitespace
    for i in (search_start..target).rev() {
        if chars[i].is_whitespace() {
            return i + 1;
        }
    }

    target
}

fn sha256_hex(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_chunk_for_short_message() {
        let chunks = chunk_message("alice@x.com", Some("Hi"), Some("Hello world"), None);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].text.contains("From: alice@x.com"));
        assert!(chunks[0].text.contains("Hello world"));
        assert_eq!(chunks[0].chunk_index, 0);
    }

    #[test]
    fn empty_body_returns_no_chunks() {
        let chunks = chunk_message("a@x.com", None, None, None);
        assert!(chunks.is_empty());

        let chunks = chunk_message("a@x.com", None, Some(""), None);
        assert!(chunks.is_empty());
    }

    #[test]
    fn html_fallback_strips_tags() {
        let chunks = chunk_message(
            "a@x.com",
            Some("Test"),
            None,
            Some("<p>Hello <b>world</b></p>"),
        );
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].text.contains("Hello world"));
        assert!(!chunks[0].text.contains("<p>"));
    }

    #[test]
    fn long_text_produces_multiple_chunks() {
        let body = "word ".repeat(1000); // ~5000 chars
        let chunks = chunk_message("a@x.com", Some("Test"), Some(&body), None);
        assert!(chunks.len() > 1);
        // Each chunk should have a unique hash
        let hashes: std::collections::HashSet<_> = chunks.iter().map(|c| &c.text_hash).collect();
        assert_eq!(hashes.len(), chunks.len());
    }

    #[test]
    fn hash_is_deterministic() {
        let c1 = chunk_message("a@x.com", Some("Hi"), Some("body"), None);
        let c2 = chunk_message("a@x.com", Some("Hi"), Some("body"), None);
        assert_eq!(c1[0].text_hash, c2[0].text_hash);
    }

    #[test]
    fn single_unbroken_token_terminates_and_is_covered() {
        // A token far longer than MAX_CHUNK_CHARS with no whitespace exercises the
        // forward-progress guard: find_break_point finds no break, so chunks must
        // still advance and the loop must terminate.
        let body = "x".repeat(MAX_CHUNK_CHARS * 3);
        let chunks = chunk_message("a@x.com", Some("S"), Some(&body), None);
        assert!(chunks.len() >= 3, "long token should split into several chunks");
        // Every original 'x' must appear across the chunks (overlap means total
        // length >= original), and no chunk may exceed the max size.
        let total: usize = chunks.iter().map(|c| c.text.chars().count()).sum();
        assert!(total >= body.chars().count());
        for c in &chunks {
            assert!(c.text.chars().count() <= MAX_CHUNK_CHARS);
        }
    }
}

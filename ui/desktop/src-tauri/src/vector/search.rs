use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::sync::Arc;

use crate::sync::error::{Result, SyncError};
use crate::vector::store::blob_to_f32_vec;

/// A search result from semantic or hybrid search.
#[derive(Debug, Clone, serde::Serialize)]
pub struct SearchResult {
    pub message_key: String,
    pub conversation_key: String,
    pub subject: Option<String>,
    pub from_address: Option<String>,
    pub snippet: String,
    pub score: f32,
    pub created_at: Option<String>,
    pub account_key: Option<String>,
}

/// Semantic similarity search using cosine distance on stored embeddings.
///
/// This is a brute-force scan over all embeddings — O(N) where N is the
/// number of embedded chunks. At 200K messages with 384-dim vectors,
/// this takes ~50-100ms on Apple Silicon. Upgrade to sqlite-vec ANN
/// index if this becomes a bottleneck.
pub fn semantic_search(
    conn: &Arc<Mutex<Connection>>,
    query_embedding: &[f32],
    limit: usize,
    account_key: Option<&str>,
) -> Result<Vec<SearchResult>> {
    let conn = conn.lock();

    // Load all embeddings and compute cosine similarity in Rust.
    // This avoids needing a custom SQL function while keeping the
    // interface clean for a future sqlite-vec migration.
    let query = if account_key.is_some() {
        "SELECT me.message_key, me.embedding, m.conversation_key, m.subject,
                m.from_address, m.body_plain, m.created_at, m.account_key
         FROM message_embeddings me
         JOIN messages m ON m.key = me.message_key
         WHERE m.account_key = ?1"
    } else {
        "SELECT me.message_key, me.embedding, m.conversation_key, m.subject,
                m.from_address, m.body_plain, m.created_at, m.account_key
         FROM message_embeddings me
         JOIN messages m ON m.key = me.message_key"
    };

    let mut stmt = conn.prepare(query)?;

    let mut scored: Vec<SearchResult> = if let Some(acct) = account_key {
        collect_scored_results(&mut stmt, params![acct], query_embedding)?
    } else {
        collect_scored_results(&mut stmt, [], query_embedding)?
    };

    // Sort by score descending (highest similarity first)
    scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));

    // Deduplicate by conversation_key (keep best-scoring chunk per conversation)
    // BEFORE truncating — truncating first can drop a conversation whose best
    // chunk ranked just outside `limit`, leaving fewer than `limit` results even
    // when more distinct conversations matched.
    let mut seen = std::collections::HashSet::new();
    scored.retain(|r| seen.insert(r.conversation_key.clone()));
    scored.truncate(limit);

    Ok(scored)
}

/// Find messages similar to a given message.
pub fn search_similar(
    conn: &Arc<Mutex<Connection>>,
    message_key: &str,
    limit: usize,
) -> Result<Vec<SearchResult>> {
    // Get the embedding for the source message (first chunk)
    let embedding = {
        let c = conn.lock();
        let blob: Option<Vec<u8>> = c
            .query_row(
                "SELECT embedding FROM message_embeddings
                 WHERE message_key = ?1 AND chunk_index = 0",
                params![message_key],
                |row| row.get(0),
            )
            .optional()?;
        match blob {
            Some(b) => blob_to_f32_vec(&b),
            None => return Err(SyncError::Other("No embedding found for message".into())),
        }
    };

    let mut results = semantic_search(conn, &embedding, limit + 1, None)?;
    // Remove the source message from results
    results.retain(|r| r.message_key != message_key);
    results.truncate(limit);
    Ok(results)
}

/// Narrows a keyword search to a date range (ISO 8601 prefixes compared as text:
/// `after` inclusive, `before` exclusive) and/or orders it newest first.
#[derive(Debug, Default, Clone, Copy)]
pub struct Window<'a> {
    pub after: Option<&'a str>,
    pub before: Option<&'a str>,
    pub newest_first: bool,
}

/// Keyword search using FTS5.
pub fn keyword_search(
    conn: &Arc<Mutex<Connection>>,
    query: &str,
    limit: usize,
    account_key: Option<&str>,
    window: Window,
) -> Result<Vec<SearchResult>> {
    // Chinese/Japanese/Korean are written without word delimiters, and FTS5's
    // unicode61 tokenizer only breaks on separator characters — so a whole run
    // of Han/Kana/Hangul indexes as ONE token and `MATCH '订单'` never finds
    // "您的订单已发货". Substring-match those queries instead, which is also
    // exactly what the mail list's own filter does (`LIKE %q%`), so both search
    // surfaces agree.
    if query.chars().any(is_unsegmented_script) {
        return substring_search(conn, query, limit, account_key, window);
    }

    let conn = conn.lock();

    // Escape FTS5 special characters
    let safe_query = fts5_escape(query);
    if safe_query.is_empty() {
        return Ok(Vec::new());
    }

    let sql = format!(
        "SELECT m.key, m.conversation_key, m.subject, m.from_address,
                snippet(messages_fts, 1, '', '', '…', 32), m.created_at, m.account_key,
                rank, m.body_html
         FROM messages_fts fts
         JOIN messages m ON m.id = fts.rowid
         WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.account_key = ?2)
           AND (?4 IS NULL OR m.created_at >= ?4) AND (?5 IS NULL OR m.created_at < ?5)
         ORDER BY {}
         LIMIT ?3",
        if window.newest_first { "m.created_at DESC" } else { "rank" }
    );

    let mut stmt = conn.prepare(&sql)?;
    let results = stmt
        .query_map(params![safe_query, account_key, limit as i32, window.after, window.before], |row| {
            Ok(SearchResult {
                message_key: row.get(0)?,
                conversation_key: row.get(1)?,
                subject: row.get(2)?,
                from_address: row.get(3)?,
                snippet: match_snippet(row.get(4)?, row.get(8)?),
                created_at: row.get(5)?,
                account_key: row.get(6)?,
                score: -(row.get::<_, f64>(7)? as f32), // FTS5 rank is negative; invert
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    Ok(results)
}

/// Hybrid search: combine semantic and keyword results via reciprocal rank fusion.
///
/// `alpha` controls the balance: 0.0 = pure keyword, 1.0 = pure semantic.
pub fn hybrid_search(
    conn: &Arc<Mutex<Connection>>,
    query: &str,
    query_embedding: &[f32],
    limit: usize,
    alpha: f32,
    account_key: Option<&str>,
) -> Result<Vec<SearchResult>> {
    let semantic_limit = limit * 3; // over-fetch for fusion
    let keyword_limit = limit * 3;

    let semantic_results = semantic_search(conn, query_embedding, semantic_limit, account_key)?;
    let keyword_results = keyword_search(conn, query, keyword_limit, account_key, Window::default())?;

    // Reciprocal Rank Fusion (RRF)
    let k = 60.0f32; // standard RRF constant
    let mut scores: std::collections::HashMap<String, (f32, SearchResult)> =
        std::collections::HashMap::new();

    for (rank, result) in semantic_results.into_iter().enumerate() {
        let rrf_score = alpha / (k + rank as f32 + 1.0);
        scores
            .entry(result.message_key.clone())
            .and_modify(|(s, _)| *s += rrf_score)
            .or_insert((rrf_score, result));
    }

    for (rank, result) in keyword_results.into_iter().enumerate() {
        let rrf_score = (1.0 - alpha) / (k + rank as f32 + 1.0);
        scores
            .entry(result.message_key.clone())
            .and_modify(|(s, _)| *s += rrf_score)
            .or_insert((rrf_score, result));
    }

    let mut fused: Vec<SearchResult> = scores
        .into_values()
        .map(|(score, mut r)| {
            r.score = score;
            r
        })
        .collect();

    fused.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    fused.truncate(limit);

    Ok(fused)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn collect_scored_results(
    stmt: &mut rusqlite::Statement,
    params: impl rusqlite::Params,
    query_embedding: &[f32],
) -> Result<Vec<SearchResult>> {
    let rows = stmt.query_map(params, |row| {
        let blob: Vec<u8> = row.get(1)?;
        let embedding = blob_to_f32_vec(&blob);
        let score = cosine_similarity(query_embedding, &embedding);

        Ok(SearchResult {
            message_key: row.get(0)?,
            conversation_key: row.get(2)?,
            subject: row.get(3)?,
            from_address: row.get(4)?,
            snippet: make_snippet(row.get::<_, Option<String>>(5)?.as_deref()),
            created_at: row.get(6)?,
            account_key: row.get(7)?,
            score,
        })
    })?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
}

/// Cosine similarity between two vectors. Returns 0.0 for zero-magnitude vectors.
pub(crate) fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut norm_a = 0.0f32;
    let mut norm_b = 0.0f32;
    for (x, y) in a.iter().zip(b.iter()) {
        dot += x * y;
        norm_a += x * x;
        norm_b += y * y;
    }
    let denom = norm_a.sqrt() * norm_b.sqrt();
    if denom < 1e-12 {
        0.0
    } else {
        dot / denom
    }
}

/// True for scripts written without spaces between words, where a tokenizer
/// that splits on separators produces one token per sentence: Han (Chinese +
/// kanji), Hiragana, Katakana, Hangul. Arabic is deliberately absent — it is
/// space-delimited and tokenizes correctly.
fn is_unsegmented_script(c: char) -> bool {
    matches!(c as u32,
        0x3040..=0x30FF |    // Hiragana + Katakana
        0x3400..=0x4DBF |    // CJK Unified Ideographs Extension A
        0x4E00..=0x9FFF |    // CJK Unified Ideographs
        0xF900..=0xFAFF |    // CJK Compatibility Ideographs
        0xAC00..=0xD7AF |    // Hangul Syllables
        0x1100..=0x11FF |    // Hangul Jamo
        0x20000..=0x2FA1F    // CJK Extension B-F + Compatibility Supplement
    )
}

/// Substring search over the same columns FTS5 indexes. Used for queries FTS5
/// cannot tokenize usefully (see [`keyword_search`]).
///
/// ponytail: sequential scan, no index — the trigram tokenizer would index
/// every message body three-characters-at-a-time to avoid it. Acceptable while
/// this path only serves agent/MCP queries; revisit if CJK search becomes hot.
fn substring_search(
    conn: &Arc<Mutex<Connection>>,
    query: &str,
    limit: usize,
    account_key: Option<&str>,
    window: Window,
) -> Result<Vec<SearchResult>> {
    let conn = conn.lock();
    // Escape LIKE wildcards so a literal % or _ in the query isn't a pattern.
    let pattern = format!(
        "%{}%",
        nfc(query)
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    );

    let sql = "SELECT m.key, m.conversation_key, m.subject, m.from_address,
                      m.body_plain, m.created_at, m.account_key
               FROM messages m
               WHERE (m.subject LIKE ?1 ESCAPE '\\' OR m.body_plain LIKE ?1 ESCAPE '\\'
                      OR m.from_address LIKE ?1 ESCAPE '\\' OR m.to_address LIKE ?1 ESCAPE '\\'
                      OR m.attachment_names LIKE ?1 ESCAPE '\\')
                 AND (?2 IS NULL OR m.account_key = ?2)
                 AND (?4 IS NULL OR m.created_at >= ?4) AND (?5 IS NULL OR m.created_at < ?5)
               ORDER BY m.created_at DESC
               LIMIT ?3";

    let mut stmt = conn.prepare(sql)?;
    let results = stmt
        .query_map(params![pattern, account_key, limit as i32, window.after, window.before], |row| {
            Ok(SearchResult {
                message_key: row.get(0)?,
                conversation_key: row.get(1)?,
                subject: row.get(2)?,
                from_address: row.get(3)?,
                snippet: make_snippet(row.get::<_, Option<String>>(4)?.as_deref()),
                created_at: row.get(5)?,
                account_key: row.get(6)?,
                // No BM25 rank on a LIKE scan; a flat score keeps these rows
                // fusing sanely with the semantic half in the RRF step.
                score: 1.0,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(results)
}

/// NFC-normalize a search query so it matches text the store normalized on
/// write (see `inbox2_core::sync::util::nfc`).
fn nfc(s: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    s.nfc().collect()
}

/// Escape FTS5 special characters to prevent query syntax errors.
fn fts5_escape(query: &str) -> String {
    // Every word becomes a quoted phrase, so `-`, `.`, `@`, `&`, `/` never reach
    // FTS5 as syntax ("S&O-verklaring" used to fail with "no such column:
    // verklaring"); the tokenizer splits the phrase the way it split the body.
    // A bare OR/AND/NOT between two words stays an operator.
    let q = nfc(query);
    let words: Vec<&str> = q.split_whitespace().collect();
    let mut out: Vec<String> = Vec::new();
    for (i, w) in words.iter().enumerate() {
        if matches!(*w, "OR" | "AND" | "NOT") {
            // Only between two words; at either end it's a dangling operator.
            if i > 0 && i + 1 < words.len() {
                out.push(w.to_string());
            }
            continue;
        }
        let clean: String = w.chars().filter(|c| *c != '"').collect();
        if clean.chars().any(char::is_alphanumeric) {
            out.push(format!("\"{clean}\""));
        }
    }
    // Two operators in a row, or one left dangling by a dropped word, is still a syntax error.
    while out.first().is_some_and(|w| matches!(w.as_str(), "OR" | "AND" | "NOT")) {
        out.remove(0);
    }
    out.dedup_by(|a, b| matches!(a.as_str(), "OR" | "AND" | "NOT") && matches!(b.as_str(), "OR" | "AND" | "NOT"));
    while out.last().is_some_and(|w| matches!(w.as_str(), "OR" | "AND" | "NOT")) {
        out.pop();
    }
    out.join(" ")
}

/// The body around the matched words (FTS5 `snippet()`), or for HTML-only mail
/// (no indexed plain body) the start of its text.
fn match_snippet(around_match: Option<String>, html: Option<String>) -> String {
    match around_match.filter(|s| !s.trim().is_empty()) {
        Some(s) => make_snippet(Some(&s)),
        None => make_snippet(html.as_deref().map(crate::sync::threading::html_to_text).as_deref()),
    }
}

/// Truncate body text to a snippet for search results.
fn make_snippet(body: Option<&str>) -> String {
    // Whitespace collapsed first: mail bodies spend half of 200 chars on \r\n runs.
    body.unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ").chars().take(200).collect()
}

use rusqlite::OptionalExtension;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cosine_similarity_identical() {
        let a = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &a) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn unsegmented_scripts_route_around_fts5() {
        // These have no word delimiters — unicode61 indexes a whole sentence as
        // one token, so they must take the substring path.
        for q in ["订单", "発送", "주문", "查询 status"] {
            assert!(q.chars().any(is_unsegmented_script), "{q} should bypass FTS5");
        }
        // Space-delimited scripts tokenize correctly and keep the ranked FTS path.
        for q in ["invoice", "الميزانية", "фактура", "café"] {
            assert!(!q.chars().any(is_unsegmented_script), "{q} should stay on FTS5");
        }
    }

    #[test]
    fn fts5_escape_keeps_non_latin_and_normalizes() {
        // is_alphanumeric() is Unicode-aware, so Arabic/Cyrillic survive escaping.
        assert_eq!(fts5_escape("الميزانية"), "\"الميزانية\"");
        // Decomposed alef+hamza normalizes to the precomposed form the store writes.
        assert_eq!(fts5_escape("\u{0627}\u{0654}"), "\"\u{0623}\"");
        // Syntax characters land inside a phrase; OR between words survives.
        assert_eq!(fts5_escape("foo* OR (bar)"), "\"foo*\" OR \"(bar)\"");
        assert_eq!(fts5_escape("S&O-verklaring"), "\"S&O-verklaring\"");
        assert_eq!(fts5_escape("OR a@b.nl OR"), "\"a@b.nl\"");
        assert_eq!(fts5_escape("\"\""), "");
    }

    #[test]
    fn cosine_similarity_orthogonal() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        assert!(cosine_similarity(&a, &b).abs() < 1e-6);
    }

    #[test]
    fn cosine_similarity_opposite() {
        let a = vec![1.0, 0.0];
        let b = vec![-1.0, 0.0];
        assert!((cosine_similarity(&a, &b) + 1.0).abs() < 1e-6);
    }

    #[test]
    fn cosine_similarity_zero_vector() {
        let a = vec![1.0, 2.0];
        let b = vec![0.0, 0.0];
        assert_eq!(cosine_similarity(&a, &b), 0.0);
    }
}

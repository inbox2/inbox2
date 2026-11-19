//! `SyncStore` — Lore todos with no email behind them (docs/plans/lore.md §6).
//!
//! A Lore item is normally a thread (open = in the inbox, done = archived); a
//! `lore_todos` row is the one kind that has no thread: "remind me to call the
//! bank" said to the Bridge, or typed into the "+ Add todo" row on mobile.

use super::*;

/// Where a todo came from.
pub const LORE_SOURCE_MANUAL: &str = "manual";
pub const LORE_SOURCE_VOICE: &str = "voice";

#[derive(Debug, Clone, serde::Serialize)]
pub struct LoreTodo {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub done_at: Option<String>,
    pub source: String,
}

/// What "Send to…" made in another app, for the chip on the Lore item.
#[derive(Debug, Clone, serde::Serialize)]
pub struct LoreSent {
    pub item_key: String,
    pub connection_name: String,
    pub reference: Option<String>,
    pub url: Option<String>,
    pub sent_at: String,
}

/// The new item's link and short name out of a tool's answer: the first http(s) URL,
/// and the first token shaped like `TUL-412` or `#88`, falling back to the URL's
/// last path segment. ponytail: reads the text the tool returned, so a tool that
/// answers in prose with no id gets a plain "Sent to X" chip.
pub fn parse_sent_reference(summary: &str) -> (Option<String>, Option<String>) {
    let trim = |t: &str| t.trim_matches(|c: char| "()[]{}<>,;:.'\"".contains(c)).to_string();
    let tokens: Vec<String> = summary.split_whitespace().map(trim).collect();
    let url = tokens.iter().find(|t| t.starts_with("https://") || t.starts_with("http://")).cloned();
    let is_issue_id = |t: &str| {
        let Some((head, tail)) = t.split_once('-') else { return false };
        head.len() >= 2 && head.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            && head.starts_with(|c: char| c.is_ascii_uppercase())
            && !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit())
    };
    let is_number = |t: &str| t.len() > 1 && t.starts_with('#') && t[1..].chars().all(|c| c.is_ascii_digit());
    let from_url = url.as_deref().and_then(|u| u.trim_end_matches('/').rsplit('/').next())
        .filter(|s| is_issue_id(s) || s.chars().all(|c| c.is_ascii_digit())).map(str::to_string);
    let reference = tokens.iter().find(|t| is_issue_id(t) || is_number(t)).cloned().or(from_url);
    (reference, url)
}

impl SyncStore {
    /// Remember what "Send to…" made for a Lore item.
    pub fn add_lore_sent(&self, item_key: &str, connection_name: &str, summary: &str) -> Result<LoreSent> {
        let (reference, url) = parse_sent_reference(summary);
        let row = LoreSent {
            item_key: item_key.to_string(),
            connection_name: connection_name.to_string(),
            reference,
            url,
            sent_at: Utc::now().to_rfc3339(),
        };
        self.conn.lock().execute(
            "INSERT INTO lore_sent (id, item_key, connection_name, reference, url, sent_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![Self::generate_key("lsn"), row.item_key, row.connection_name, row.reference, row.url, row.sent_at],
        )?;
        Ok(row)
    }

    /// Every sent reference, newest first.
    pub fn lore_sent(&self) -> Result<Vec<LoreSent>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT item_key, connection_name, reference, url, sent_at FROM lore_sent ORDER BY sent_at DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(LoreSent { item_key: r.get(0)?, connection_name: r.get(1)?, reference: r.get(2)?, url: r.get(3)?, sent_at: r.get(4)? })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Add an open todo. Blank titles are refused.
    pub fn add_lore_todo(&self, title: &str, source: &str) -> Result<LoreTodo> {
        let title = title.trim();
        if title.is_empty() {
            return Err(SyncError::Other("todo title is empty".into()));
        }
        let todo = LoreTodo {
            id: Self::generate_key("ltd"),
            title: title.to_string(),
            created_at: Utc::now().to_rfc3339(),
            done_at: None,
            source: source.to_string(),
        };
        self.conn.lock().execute(
            "INSERT INTO lore_todos (id, title, created_at, done_at, source) VALUES (?1, ?2, ?3, NULL, ?4)",
            params![todo.id, todo.title, todo.created_at, todo.source],
        )?;
        Ok(todo)
    }

    /// Open todos, oldest first (the order they were asked for).
    pub fn open_lore_todos(&self) -> Result<Vec<LoreTodo>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, title, created_at, done_at, source FROM lore_todos
             WHERE done_at IS NULL ORDER BY created_at ASC, id ASC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(LoreTodo {
                    id: r.get(0)?,
                    title: r.get(1)?,
                    created_at: r.get(2)?,
                    done_at: r.get(3)?,
                    source: r.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Tick a todo off. Returns whether an open row matched.
    pub fn complete_lore_todo(&self, id: &str) -> Result<bool> {
        let changed = self.conn.lock().execute(
            "UPDATE lore_todos SET done_at = ?1 WHERE id = ?2 AND done_at IS NULL",
            params![Utc::now().to_rfc3339(), id],
        )?;
        Ok(changed > 0)
    }
}

#[cfg(test)]
mod lore_tests {
    use super::*;

    #[test]
    fn lore_todo_add_list_complete() {
        let store = SyncStore::new_in_memory().unwrap();
        assert!(store.add_lore_todo("   ", LORE_SOURCE_MANUAL).is_err());
        let a = store.add_lore_todo(" Call the bank ", LORE_SOURCE_VOICE).unwrap();
        let b = store.add_lore_todo("Send the invoice", LORE_SOURCE_MANUAL).unwrap();
        assert_eq!(a.title, "Call the bank");
        let open = store.open_lore_todos().unwrap();
        assert_eq!(open.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec![a.id.as_str(), b.id.as_str()]);
        assert!(store.complete_lore_todo(&a.id).unwrap());
        assert!(!store.complete_lore_todo(&a.id).unwrap(), "already done");
        let open = store.open_lore_todos().unwrap();
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].id, b.id);
    }
}

#[cfg(test)]
mod sent_reference_tests {
    use super::parse_sent_reference as p;

    #[test]
    fn finds_the_id_and_the_link() {
        assert_eq!(p("Created TUL-412: https://linear.app/x/issue/TUL-412/fix."),
                   (Some("TUL-412".into()), Some("https://linear.app/x/issue/TUL-412/fix".into())));
        assert_eq!(p("Opened #88 (https://github.com/a/b/issues/88)"),
                   (Some("#88".into()), Some("https://github.com/a/b/issues/88".into())));
    }

    #[test]
    fn falls_back_to_the_last_path_segment_and_leaves_prose_alone() {
        assert_eq!(p("Done: https://x.hubspot.com/deals/991").0.as_deref(), Some("991"));
        assert_eq!(p("Created the task for well-known reasons"), (None, None));
    }
}

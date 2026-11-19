//! `SyncStore` — Lore's part of local triage (docs/Triage.md): the next-action
//! columns written with every label, the "Handled for you" auto-mode setting
//! and candidate check, and the one-time re-triage after the 2026-10-20 labels.

use super::*;
use crate::triage::TriageLabel;

/// Engine setting: `{fyi, receipt, notification}` booleans (auto mode).
const LORE_AUTO_SETTING: &str = "lore_auto";
/// Engine setting set once the upgrade re-triage has run on this device.
pub const LORE_RETRIAGE_MARKER: &str = "lore_labels_retriaged_v1";
/// Labels the re-triage revisits: the ones the five new labels overlap.
const RETRIAGE_LABELS: [TriageLabel; 4] =
    [TriageLabel::Fyi, TriageLabel::ActionRequired, TriageLabel::Scheduling, TriageLabel::NeedsApproval];
const RETRIAGE_DAYS: i64 = 90;
const RETRIAGE_CAP: i64 = 500;
/// Auto mode only files away fresh mail, never a backlog relabelled later
/// (a key arriving, the re-triage). ponytail: age gate, not a per-job flag.
const AUTO_MAX_AGE_HOURS: i64 = 72;
/// Provenance suffix on an auto-filed thread (`…+auto`).
pub const AUTO_SOURCE_SUFFIX: &str = "+auto";

/// Per-bucket auto mode (all off by default, decided 2026-10-20).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct LoreAutoSettings {
    pub fyi: bool,
    pub receipt: bool,
    pub notification: bool,
}

impl LoreAutoSettings {
    /// The write-back verb for a label switched to auto, if any.
    pub fn action_for(&self, label: &str) -> Option<&'static str> {
        match TriageLabel::from_str(label)? {
            TriageLabel::Fyi if self.fyi => Some("archive"),
            TriageLabel::Receipt if self.receipt => Some("archive"),
            TriageLabel::Notification if self.notification => Some("trash"),
            _ => None,
        }
    }
}

/// What the re-triage did: threads relabelled by the rules right away, and how
/// many were queued for Jev. `None` from [`SyncStore::lore_retriage`] = already done.
#[derive(Debug, Default)]
pub struct LoreRetriage {
    pub relabeled: Vec<(String, String)>,
    pub queued: usize,
}

/// Recompute a thread's next-action columns from its current label, subject and
/// newest inbound message. Called wherever the label is written.
pub(crate) fn refresh_next_action(conn: &Connection, conversation_key: &str) -> Result<()> {
    let Some((label, subject)) = conn
        .query_row(
            "SELECT triage_label, subject FROM conversations WHERE key = ?1",
            params![conversation_key],
            |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()?
    else {
        return Ok(());
    };
    let (body, created): (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT body_plain, created_at FROM messages WHERE conversation_key = ?1 AND is_inbound = 1
             ORDER BY created_at DESC, key DESC LIMIT 1",
            params![conversation_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .unwrap_or_default();
    let day = created.as_deref().and_then(utc_day);
    let text = crate::quotes::strip_quoted_text(body.as_deref().unwrap_or(""));
    let na = crate::next_action::extract(label.as_deref(), subject.as_deref(), &text, day);
    conn.execute(
        "UPDATE conversations SET next_action_due_on = ?2, next_action_amount_cents = ?3, next_action_currency = ?4
         WHERE key = ?1",
        params![conversation_key, na.due_on, na.amount_cents, na.currency],
    )?;
    Ok(())
}

fn utc_day(s: &str) -> Option<chrono::NaiveDate> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc).date_naive())
        .ok()
        .or_else(|| chrono::NaiveDate::parse_from_str(s.get(..10)?, "%Y-%m-%d").ok())
}

impl SyncStore {
    pub fn lore_auto(&self) -> LoreAutoSettings {
        self.get_engine_setting(LORE_AUTO_SETTING)
            .ok()
            .flatten()
            .and_then(|v| serde_json::from_str(&v).ok())
            .unwrap_or_default()
    }

    pub fn set_lore_auto(&self, settings: LoreAutoSettings) -> Result<LoreAutoSettings> {
        let json = serde_json::to_string(&settings).map_err(|e| SyncError::Other(e.to_string()))?;
        self.set_engine_setting(LORE_AUTO_SETTING, &json)?;
        Ok(settings)
    }

    /// `(account_key, verb)` when auto mode should file this thread away now:
    /// its label's bucket is on, the label isn't manual, it's still in the
    /// inbox, the person never replied in it, and its newest message is fresh.
    pub fn lore_auto_candidate(&self, conversation_key: &str) -> Result<Option<(String, &'static str)>> {
        let settings = self.lore_auto();
        if settings == LoreAutoSettings::default() {
            return Ok(None);
        }
        let conn = self.conn.lock();
        let row = conn
            .query_row(
                "SELECT c.triage_label, ifnull(c.triage_source, ''), c.status,
                        (SELECT COUNT(*) FROM messages m WHERE m.conversation_key = c.key AND m.is_inbound = 0),
                        (SELECT m.account_key FROM messages m WHERE m.conversation_key = c.key
                          ORDER BY m.created_at DESC, m.key DESC LIMIT 1),
                        (SELECT MAX(m.created_at) FROM messages m WHERE m.conversation_key = c.key)
                 FROM conversations c WHERE c.key = ?1",
                params![conversation_key],
                |r| {
                    Ok((
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, Option<String>>(4)?,
                        r.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()?;
        let Some((Some(label), source, status, sent, Some(account), Some(newest))) = row else {
            return Ok(None);
        };
        let Some(verb) = settings.action_for(&label) else { return Ok(None) };
        let fresh = chrono::DateTime::parse_from_rfc3339(&newest)
            .is_ok_and(|d| Utc::now().signed_duration_since(d) <= chrono::Duration::hours(AUTO_MAX_AGE_HOURS));
        let open = status.as_deref().is_none_or(|s| s == ConversationStatus::Open.as_str());
        if source.starts_with(crate::triage::MANUAL_SOURCE) || sent > 0 || !open || !fresh {
            return Ok(None);
        }
        Ok(Some((account, verb)))
    }

    /// Record that auto mode filed this thread (provenance `…+auto`).
    pub fn mark_lore_auto(&self, conversation_key: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE conversations SET triage_source = ifnull(triage_source, '') || ?2
             WHERE key = ?1 AND ifnull(triage_source, '') NOT LIKE '%' || ?2",
            params![conversation_key, AUTO_SOURCE_SUFFIX],
        )?;
        Ok(())
    }

    /// The one-time re-triage after the five new labels (docs/Triage.md
    /// "Upgrade re-triage"). Open threads from the last 90 days, labelled by a
    /// rule or Jev (never by hand) with one of [`RETRIAGE_LABELS`], newest 500:
    /// a rule-labelled thread gets the rules again here; a Jev-labelled one loses
    /// its label and is queued, so the worker's fast path asks Jev for the label
    /// (summaries kept). Without a Jev key those wait: the marker is only set
    /// when nothing was left for Jev. Runs from the worker, never at store open.
    pub fn lore_retriage(&self, has_jev_key: bool) -> Result<Option<LoreRetriage>> {
        if self.get_engine_setting(LORE_RETRIAGE_MARKER)?.is_some() {
            return Ok(None);
        }
        let conn = self.conn.lock();
        let cutoff = (Utc::now() - chrono::Duration::days(RETRIAGE_DAYS)).to_rfc3339();
        let labels: Vec<&str> = RETRIAGE_LABELS.iter().map(|l| l.as_str()).collect();
        let mut stmt = conn.prepare(
            "SELECT key, subject, triage_source, updated_at FROM conversations
             WHERE status = ?1 AND updated_at >= ?2 AND triage_label IN (?3, ?4, ?5, ?6)
               AND triage_source IS NOT NULL AND triage_source NOT LIKE ?7 || '%'
               AND label_manual_msg_key IS NULL
             ORDER BY updated_at DESC, key DESC LIMIT ?8",
        )?;
        let rows: Vec<(String, Option<String>, String, String)> = stmt
            .query_map(
                params![
                    ConversationStatus::Open.as_str(),
                    cutoff,
                    labels[0],
                    labels[1],
                    labels[2],
                    labels[3],
                    crate::triage::MANUAL_SOURCE,
                    RETRIAGE_CAP
                ],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )?
            .collect::<rusqlite::Result<_>>()?;
        drop(stmt);

        let mut out = LoreRetriage::default();
        let mut waiting_for_jev = false;
        for (key, subject, source, updated_at) in rows {
            if source.starts_with("rule:") {
                let analysis = super::ai_triage::detect_label(&conn, &key, subject.as_deref())?;
                if let Some(label) = analysis.label {
                    // Keep whatever followed the rule part (`+jev:…+model:…`).
                    let rest = source.find('+').map_or("", |i| &source[i..]);
                    conn.execute(
                        "UPDATE conversations SET triage_label = ?2, triage_source = ?3 WHERE key = ?1",
                        params![key, label.as_str(), format!("{}{rest}", analysis.source)],
                    )?;
                    refresh_next_action(&conn, &key)?;
                    out.relabeled.push((key, label.as_str().to_string()));
                    continue;
                }
            }
            if !has_jev_key {
                waiting_for_jev = true;
                continue;
            }
            conn.execute("UPDATE conversations SET triage_label = NULL WHERE key = ?1", params![key])?;
            super::ai_triage::enqueue_triage_job(&conn, &key, &updated_at)?;
            out.queued += 1;
        }
        drop(conn);
        if !waiting_for_jev {
            self.set_engine_setting(LORE_RETRIAGE_MARKER, &Utc::now().to_rfc3339())?;
        }
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> SyncStore {
        SyncStore::new_in_memory().unwrap()
    }

    fn thread(s: &SyncStore, key: &str, label: &str, source: &str, status: &str, age_days: i64, body: &str) {
        let at = (Utc::now() - chrono::Duration::days(age_days)).to_rfc3339();
        let conn = s.conn.lock();
        conn.execute(
            "INSERT INTO conversations (key, organization_id, subject, status, updated_at, triage_label, triage_source)
             VALUES (?1, 'o', 'Hello', ?2, ?3, ?4, ?5)",
            params![key, status, at, label, source],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages (key, conversation_key, organization_id, account_key, from_address, body_plain, is_inbound, created_at)
             VALUES (?1, ?2, 'o', 'acc', 'a@x.com', ?3, 1, ?4)",
            params![format!("{key}_m"), key, body, at],
        )
        .unwrap();
    }

    fn label_of(s: &SyncStore, key: &str) -> Option<String> {
        s.conn.lock().query_row("SELECT triage_label FROM conversations WHERE key = ?1", params![key], |r| r.get(0)).unwrap()
    }

    #[test]
    fn next_action_follows_the_label() {
        let s = store();
        thread(&s, "c1", "payment_due", "jev:x", "open", 0, "Total €386,00 due within 14 days");
        refresh_next_action(&s.conn.lock(), "c1").unwrap();
        let (cents, cur, due): (Option<i64>, Option<String>, Option<String>) = s
            .conn
            .lock()
            .query_row(
                "SELECT next_action_amount_cents, next_action_currency, next_action_due_on FROM conversations WHERE key='c1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!((cents, cur.as_deref()), (Some(38600), Some("EUR")));
        assert!(due.is_some());
    }

    #[test]
    fn auto_candidate_rules() {
        let s = store();
        thread(&s, "fresh", "fyi", "jev:x", "open", 0, "hi");
        thread(&s, "old", "fyi", "jev:x", "open", 10, "hi");
        thread(&s, "manual", "fyi", "manual", "open", 0, "hi");
        thread(&s, "note", "notification", "rule:otp", "open", 0, "code 1234");
        assert_eq!(s.lore_auto_candidate("fresh").unwrap(), None, "off by default");

        s.set_lore_auto(LoreAutoSettings { fyi: true, receipt: false, notification: true }).unwrap();
        assert_eq!(s.lore_auto(), LoreAutoSettings { fyi: true, receipt: false, notification: true });
        assert_eq!(s.lore_auto_candidate("fresh").unwrap(), Some(("acc".into(), "archive")));
        assert_eq!(s.lore_auto_candidate("note").unwrap(), Some(("acc".into(), "trash")));
        assert_eq!(s.lore_auto_candidate("old").unwrap(), None);
        assert_eq!(s.lore_auto_candidate("manual").unwrap(), None);

        s.conn
            .lock()
            .execute(
                "INSERT INTO messages (key, conversation_key, organization_id, account_key, is_inbound, created_at)
                 VALUES ('fresh_sent', 'fresh', 'o', 'acc', 0, ?1)",
                params![Utc::now().to_rfc3339()],
            )
            .unwrap();
        assert_eq!(s.lore_auto_candidate("fresh").unwrap(), None, "replied in");

        s.mark_lore_auto("note").unwrap();
        s.mark_lore_auto("note").unwrap();
        let src: String =
            s.conn.lock().query_row("SELECT triage_source FROM conversations WHERE key='note'", [], |r| r.get(0)).unwrap();
        assert_eq!(src, "rule:otp+auto");
    }

    #[test]
    fn retriage_scope_marker_and_cap() {
        let s = store();
        thread(&s, "jev", "fyi", "jev:jev-1.13.0", "open", 1, "hi");
        thread(&s, "manual", "fyi", "manual", "open", 1, "hi");
        thread(&s, "archived", "fyi", "jev:x", "archived", 1, "hi");
        thread(&s, "old", "fyi", "jev:x", "open", 120, "hi");
        thread(&s, "other", "needs_answer", "jev:x", "open", 1, "hi");

        // No key: nothing Jev-labelled is touched and the marker waits.
        let r = s.lore_retriage(false).unwrap().unwrap();
        assert_eq!(r.queued, 0);
        assert_eq!(label_of(&s, "jev").as_deref(), Some("fyi"));
        assert!(s.get_engine_setting(LORE_RETRIAGE_MARKER).unwrap().is_none());

        let r = s.lore_retriage(true).unwrap().unwrap();
        assert_eq!(r.queued, 1);
        assert_eq!(label_of(&s, "jev"), None);
        for k in ["manual", "archived", "old", "other"] {
            assert!(label_of(&s, k).is_some(), "{k} must keep its label");
        }
        let queued: i64 = s.conn.lock().query_row("SELECT COUNT(*) FROM ai_triage_queue", [], |r| r.get(0)).unwrap();
        assert_eq!(queued, 1);
        // Marker set: a second run is a no-op.
        assert!(s.lore_retriage(true).unwrap().is_none());
    }

    #[test]
    fn retriage_reruns_rules_for_rule_labels() {
        let s = store();
        thread(&s, "bill", "action_required", "rule:action+jev:jev-1.13.0", "open", 1, "Your bill is ready. Amount due €20");
        let r = s.lore_retriage(true).unwrap().unwrap();
        assert_eq!(r.relabeled, vec![("bill".to_string(), "payment_due".to_string())]);
        let src: String =
            s.conn.lock().query_row("SELECT triage_source FROM conversations WHERE key='bill'", [], |r| r.get(0)).unwrap();
        assert_eq!(src, "rule:payment+jev:jev-1.13.0");
    }

    #[test]
    fn retriage_caps_at_500_newest_first() {
        let s = store();
        for i in 0..(RETRIAGE_CAP + 3) {
            thread(&s, &format!("c{i:04}"), "fyi", "jev:x", "open", 1, "hi");
        }
        assert_eq!(s.lore_retriage(true).unwrap().unwrap().queued, RETRIAGE_CAP as usize);
    }
}

//! `SyncStore` — write-back action queue, outbox, and integrity report.

use super::*;

impl SyncStore {

    // -----------------------------------------------------------------------
    // Write-back actions
    // -----------------------------------------------------------------------

    pub fn enqueue_action(&self, action: &WritebackAction) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let payload = serde_json::to_string(&action.action_type).unwrap_or_default();
        let provider_snapshot = action
            .provider_snapshot
            .as_ref()
            .and_then(|p| serde_json::to_string(p).ok());
        conn.execute(
            "INSERT INTO writeback_actions
             (key, account_key, action_type, message_key, folder_key, payload,
              provider_snapshot, status, retry_count, max_retries, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                action.key,
                action.account_key,
                action.action_type.as_str(),
                action.message_key,
                action.folder_key,
                payload,
                provider_snapshot,
                ActionStatus::Pending.as_str(),
                0,
                action.max_retries,
                now,
                now,
            ],
        )?;
        Ok(())
    }

    /// Total actions still awaiting the provider (pending or in-progress) across all
    /// accounts, regardless of `next_retry_at` backoff — a cheap COUNT for drain-loop
    /// observability (distinguishes "queue empty" from "queue stuck").
    pub fn pending_action_count(&self) -> Result<usize> {
        let conn = self.conn.lock();
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM writeback_actions WHERE status IN (?1, ?2)",
            params![
                ActionStatus::Pending.as_str(),
                ActionStatus::InProgress.as_str()
            ],
            |r| r.get(0),
        )?;
        Ok(n as usize)
    }

    pub fn get_pending_actions(&self, account_key: &str) -> Result<Vec<WritebackAction>> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let mut stmt = conn.prepare(
            "SELECT key, account_key, action_type, message_key, folder_key, payload,
                    status, retry_count, max_retries, next_retry_at, error_message,
                    provider_snapshot
             FROM writeback_actions
             WHERE account_key = ?1
               AND status IN (?2, ?3)
               AND (next_retry_at IS NULL OR next_retry_at <= ?4)
             ORDER BY created_at ASC",
        )?;
        let rows = stmt.query_map(
            params![
                account_key,
                ActionStatus::Pending.as_str(),
                ActionStatus::InProgress.as_str(),
                now
            ],
            |row| {
            let payload: String = row.get(5)?;
            // The JSON payload is the source of truth (it carries the structured
            // variants' fields) and is written for every row — a parse failure
            // is corruption, not a missing column.
            let action_type = serde_json::from_str(&payload).unwrap_or_else(|e| {
                log::error!("unparseable writeback action payload ({e}); treating as mark_read");
                ActionType::MarkRead
            });
            let status_str: String = row.get(6)?;
            let provider_snapshot = row
                .get::<_, Option<String>>(11)?
                .and_then(|s| serde_json::from_str(&s).ok());
            Ok(WritebackAction {
                key: row.get(0)?,
                account_key: row.get(1)?,
                action_type,
                message_key: row.get(3)?,
                folder_key: row.get(4)?,
                provider_snapshot,
                status: ActionStatus::from_str(&status_str),
                retry_count: row.get::<_, i32>(7)? as u32,
                max_retries: row.get::<_, i32>(8)? as u32,
                next_retry_at: None,
                error_message: row.get(10)?,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn update_action_status(
        &self,
        key: &str,
        status: &ActionStatus,
        retry_count: u32,
        next_retry_at: Option<&str>,
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE writeback_actions
             SET status = ?1, retry_count = ?2, next_retry_at = ?3,
                 error_message = ?4, updated_at = ?5
             WHERE key = ?6",
            params![status.as_str(), retry_count as i32, next_retry_at, error, now, key],
        )?;
        Ok(())
    }

    /// Snapshot of sync-integrity metrics for the whole store. Used by the
    /// `sync-check` CLI to validate a full sync end-to-end.
    pub fn integrity_report(&self) -> Result<IntegrityReport> {
        let conn = self.conn.lock();
        let count = |sql: &str| -> Result<i64> {
            conn.query_row(sql, [], |row| row.get(0)).map_err(Into::into)
        };
        Ok(IntegrityReport {
            accounts: count("SELECT COUNT(*) FROM external_accounts")?,
            folders: count("SELECT COUNT(*) FROM external_folders")?,
            sync_enabled_folders: count(
                "SELECT COUNT(*) FROM external_folders WHERE sync_enabled = 1",
            )?,
            folders_with_cursor: count(
                "SELECT COUNT(*) FROM external_folders WHERE sync_enabled = 1 \
                 AND (sync_cursor IS NOT NULL OR (uid_validity IS NOT NULL AND last_synced_uid > 0))",
            )?,
            messages: count("SELECT COUNT(*) FROM messages")?,
            conversations: count("SELECT COUNT(*) FROM conversations")?,
            provider_states: count("SELECT COUNT(*) FROM message_provider_state")?,
            calendars: count("SELECT COUNT(*) FROM calendars")?,
            calendar_events: count("SELECT COUNT(*) FROM calendar_events")?,
            // Integrity violations — all of these should be zero.
            orphan_provider_states: count(
                "SELECT COUNT(*) FROM message_provider_state mps \
                 LEFT JOIN messages m ON m.key = mps.message_key WHERE m.key IS NULL",
            )?,
            messages_missing_conversation: count(
                "SELECT COUNT(*) FROM messages m \
                 LEFT JOIN conversations c ON c.key = m.conversation_key WHERE c.key IS NULL",
            )?,
            messages_without_provider_state: count(
                "SELECT COUNT(*) FROM messages m \
                 LEFT JOIN message_provider_state mps ON mps.message_key = m.key \
                 WHERE mps.message_key IS NULL",
            )?,
            duplicate_message_ids: count(
                "SELECT COUNT(*) FROM (SELECT account_key, message_id_header \
                 FROM messages GROUP BY account_key, message_id_header HAVING COUNT(*) > 1)",
            )?,
            events_missing_calendar: count(
                "SELECT COUNT(*) FROM calendar_events e \
                 LEFT JOIN calendars c ON c.key = e.calendar_key WHERE c.key IS NULL",
            )?,
        })
    }

    pub fn delete_completed_actions(&self) -> Result<u64> {
        let conn = self.conn.lock();
        // Retain completed actions for a short settle grace rather than reaping
        // them immediately. The sync-vs-writeback guard
        // (`writeback_blocks_mirror`) leans on completed actions to keep an
        // optimistic mutation alive until the provider's settled flags are
        // re-synced; a sync snapshot taken *before* the write-back can land
        // shortly *after* it completes, so reaping the action the instant it
        // completes reopens the resurrection race. RFC3339-UTC timestamps sort
        // lexicographically, matching the comparison used elsewhere.
        let cutoff = (Utc::now()
            - chrono::Duration::seconds(WRITEBACK_SETTLE_GRACE_SECS))
        .to_rfc3339();
        // Log what we're about to drop. A reaped action is indistinguishable from one
        // that was never enqueued once the row is gone, which is exactly the hole a
        // "trashed here, still in Gmail" report falls into.
        {
            let mut stmt = conn.prepare(
                "SELECT key, account_key, action_type, message_key FROM writeback_actions
                 WHERE status = ?1 AND updated_at < ?2",
            )?;
            let doomed = stmt
                .query_map(params![ActionStatus::Completed.as_str(), &cutoff], |r| {
                    Ok(format!(
                        "{}({} {} msg {})",
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?
                    ))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            if !doomed.is_empty() {
                log::info!(
                    "[writeback] reaping {} settled action(s): {}",
                    doomed.len(),
                    doomed.join(", ")
                );
            }
        }
        let changes = conn.execute(
            "DELETE FROM writeback_actions
             WHERE status = ?1 AND updated_at < ?2",
            params![ActionStatus::Completed.as_str(), cutoff],
        )?;
        Ok(changes as u64)
    }

    // -----------------------------------------------------------------------
    // Outbox (durable provider sends)
    // -----------------------------------------------------------------------

    pub fn enqueue_outbox(&self, entry: &OutboxMessage) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let payload = serde_json::to_string(&entry.message)
            .map_err(|e| SyncError::Other(format!("serialize outbox payload: {e}")))?;
        conn.execute(
            "INSERT INTO outbox_messages
             (key, account_key, payload, status, retry_count, max_retries, created_at, updated_at, kind, draft_key)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                entry.key,
                entry.account_key,
                payload,
                OutboxStatus::Pending.as_str(),
                0,
                entry.max_retries,
                now,
                now,
                entry.kind.as_str(),
                entry.draft_key,
            ],
        )?;
        Ok(())
    }

    /// Queue a new version of a draft. Only the latest version matters: an
    /// undelivered pending version is overwritten in place (and a failed one
    /// dropped), so a burst of saves costs one provider write. A version that is
    /// already in flight is left alone and this one queues behind it (see the
    /// per-draft guard in [`Self::claim_outbox_for_send`]). Returns the row's key.
    pub fn enqueue_draft_version(&self, entry: &OutboxMessage) -> Result<String> {
        let draft_key = entry.draft_key.as_deref().ok_or_else(|| SyncError::Other("draft without draft_key".into()))?;
        let payload = serde_json::to_string(&entry.message)
            .map_err(|e| SyncError::Other(format!("serialize outbox payload: {e}")))?;
        let now = Utc::now().to_rfc3339();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        // A draft key names one draft in one account; reusing it elsewhere would
        // overwrite the other account's version.
        let elsewhere: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM outbox_messages WHERE draft_key = ?1 AND account_key != ?2)
                 OR EXISTS(SELECT 1 FROM draft_refs WHERE draft_key = ?1 AND target != ?2)",
            params![draft_key, entry.account_key],
            |r| r.get(0),
        )?;
        if elsewhere {
            return Err(SyncError::Other(format!("draft '{draft_key}' belongs to another account")));
        }
        tx.execute(
            "DELETE FROM outbox_messages WHERE draft_key = ?1 AND kind = ?2 AND status = ?3",
            params![draft_key, OutboxKind::Draft.as_str(), OutboxStatus::Failed.as_str()],
        )?;
        // Only the newest version may absorb this one; an older row is either in
        // flight or about to be retired.
        let existing: Option<String> = tx
            .query_row(
                "SELECT key FROM outbox_messages WHERE draft_key = ?1 AND kind = ?2 AND status = ?3
                   AND id = (SELECT MAX(id) FROM outbox_messages WHERE draft_key = ?1)",
                params![draft_key, OutboxKind::Draft.as_str(), OutboxStatus::Pending.as_str()],
                |r| r.get(0),
            )
            .optional()?;
        let key = match existing {
            Some(key) => {
                tx.execute(
                    "UPDATE outbox_messages SET payload = ?2, retry_count = 0, next_retry_at = NULL,
                            error_message = NULL, updated_at = ?3
                     WHERE key = ?1",
                    params![key, payload, now],
                )?;
                key
            }
            None => {
                tx.execute(
                    "INSERT INTO outbox_messages
                     (key, account_key, payload, status, retry_count, max_retries, created_at, updated_at, kind, draft_key)
                     VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?6, ?7, ?8)",
                    params![
                        entry.key,
                        entry.account_key,
                        payload,
                        OutboxStatus::Pending.as_str(),
                        entry.max_retries,
                        now,
                        OutboxKind::Draft.as_str(),
                        draft_key,
                    ],
                )?;
                entry.key.clone()
            }
        };
        tx.commit()?;
        Ok(key)
    }

    /// One entry by key, as it is now: a drain re-reads after claiming, so a
    /// draft version saved in between is the one delivered.
    pub fn get_outbox(&self, key: &str) -> Result<Option<OutboxMessage>> {
        let conn = self.conn.lock();
        Ok(conn
            .query_row(
                "SELECT key, account_key, payload, status, retry_count, max_retries,
                        next_retry_at, provider_message_id, error_message, kind, draft_key
                 FROM outbox_messages WHERE key = ?1",
                params![key],
                Self::row_to_outbox,
            )
            .optional()?)
    }

    /// A draft version failed. In one transaction (so no save can slip between
    /// the check and the requeue): if a newer version exists it is dropped —
    /// retried later it would overwrite the newer draft — otherwise it is
    /// requeued as `status`. Returns whether it was kept.
    pub fn requeue_draft_version(
        &self,
        key: &str,
        status: &OutboxStatus,
        retry_count: u32,
        next_retry_at: Option<&str>,
        error: &str,
    ) -> Result<bool> {
        let now = Utc::now().to_rfc3339();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let kept = tx.execute(
            "UPDATE outbox_messages SET status = ?2, retry_count = ?3, next_retry_at = ?4, error_message = ?5, updated_at = ?6
             WHERE key = ?1 AND NOT EXISTS (SELECT 1 FROM outbox_messages o
                                            WHERE o.draft_key = outbox_messages.draft_key AND o.id > outbox_messages.id)",
            params![key, status.as_str(), retry_count as i32, next_retry_at, error, now],
        )? == 1;
        if !kept {
            tx.execute("DELETE FROM outbox_messages WHERE key = ?1", params![key])?;
        }
        tx.commit()?;
        Ok(kept)
    }

    /// A draft version landed: in one transaction mark it sent, remember the
    /// provider's id for the next version, and drop any older versions — so no
    /// claim can ever see the next version without the id.
    pub fn complete_draft(&self, key: &str, draft_key: &str, target: &str, provider_draft_id: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE outbox_messages SET status = ?2, provider_message_id = ?3, error_message = NULL, updated_at = ?4 WHERE key = ?1",
            params![key, OutboxStatus::Sent.as_str(), provider_draft_id, now],
        )?;
        tx.execute(
            "INSERT INTO draft_refs (draft_key, target, provider_draft_id, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(draft_key) DO UPDATE SET provider_draft_id = excluded.provider_draft_id, updated_at = excluded.updated_at",
            params![draft_key, target, provider_draft_id, now],
        )?;
        tx.execute(
            "DELETE FROM outbox_messages WHERE draft_key = ?1
               AND id < (SELECT id FROM outbox_messages WHERE key = ?2)",
            params![draft_key, key],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// The provider id the last delivered version of a draft got, if any.
    pub fn draft_ref(&self, draft_key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .lock()
            .query_row("SELECT provider_draft_id FROM draft_refs WHERE draft_key = ?1", params![draft_key], |r| r.get(0))
            .optional()?
            .flatten())
    }


    pub fn get_pending_outbox(&self, account_key: &str) -> Result<Vec<OutboxMessage>> {
        let conn = self.conn.lock();
        let now = Utc::now();
        let now_s = now.to_rfc3339();
        // A 'sending' row whose attempt never resolved (process crashed mid-send)
        // is reclaimed after this window so it isn't stranded forever.
        let stale = (now - chrono::Duration::seconds(STALE_SENDING_SECS)).to_rfc3339();
        let mut stmt = conn.prepare(
            "SELECT key, account_key, payload, status, retry_count, max_retries,
                    next_retry_at, provider_message_id, error_message, kind, draft_key
             FROM outbox_messages
             WHERE account_key = ?1
               AND (
                 (status = ?4 AND (next_retry_at IS NULL OR next_retry_at <= ?2))
                 OR (status = ?5 AND updated_at <= ?3)
               )
             ORDER BY created_at ASC",
        )?;
        let rows = stmt.query_map(
            params![
                account_key,
                now_s,
                stale,
                OutboxStatus::Pending.as_str(),
                OutboxStatus::Sending.as_str()
            ],
            Self::row_to_outbox,
        )?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Atomically claim an entry for a delivery attempt (pending → sending, or
    /// reclaim a stale `sending`). Returns `true` iff this caller won the claim,
    /// guaranteeing at most one sender per entry across the command task and the
    /// drain loop — a non-idempotent send must never run twice.
    pub fn claim_outbox_for_send(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let now = Utc::now();
        let now_s = now.to_rfc3339();
        let stale = (now - chrono::Duration::seconds(STALE_SENDING_SECS)).to_rfc3339();
        let changed = conn.execute(
            // Drafts: a version waits while another version of the same draft is
            // in flight (two concurrent saves would each create a draft), and only
            // the newest version is ever claimed (an older one would overwrite it).
            "UPDATE outbox_messages
             SET status = ?4, updated_at = ?1
             WHERE key = ?2
               AND (status = ?5 OR (status = ?4 AND updated_at <= ?3))
               AND NOT (draft_key IS NOT NULL AND EXISTS (
                     SELECT 1 FROM outbox_messages o
                     WHERE o.draft_key = outbox_messages.draft_key AND o.key != outbox_messages.key
                       AND ((o.status = ?4 AND o.updated_at > ?3)
                            OR (o.id > outbox_messages.id AND o.status IN (?5, ?4)))))",
            params![
                now_s,
                key,
                stale,
                OutboxStatus::Sending.as_str(),
                OutboxStatus::Pending.as_str()
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn list_outbox(&self, account_key: &str) -> Result<Vec<OutboxMessage>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT key, account_key, payload, status, retry_count, max_retries,
                    next_retry_at, provider_message_id, error_message, kind, draft_key
             FROM outbox_messages
             WHERE account_key = ?1 AND kind = 'send'
             ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map(params![account_key], Self::row_to_outbox)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    fn row_to_outbox(row: &rusqlite::Row) -> rusqlite::Result<OutboxMessage> {
        let payload: String = row.get(2)?;
        // A row with an unparseable payload can never be delivered; surface a
        // placeholder rather than failing the whole query so the UI can show it.
        let message = serde_json::from_str(&payload).unwrap_or(OutgoingMessage {
            subject: Some("(corrupt outbox payload)".into()),
            ..Default::default()
        });
        let status_str: String = row.get(3)?;
        Ok(OutboxMessage {
            key: row.get(0)?,
            account_key: row.get(1)?,
            kind: OutboxKind::from_str(&row.get::<_, String>(9)?),
            draft_key: row.get(10)?,
            message,
            status: OutboxStatus::from_str(&status_str),
            retry_count: row.get::<_, i32>(4)? as u32,
            max_retries: row.get::<_, i32>(5)? as u32,
            next_retry_at: None,
            provider_message_id: row.get(7)?,
            error_message: row.get(8)?,
        })
    }

    pub fn update_outbox_status(
        &self,
        key: &str,
        status: &OutboxStatus,
        retry_count: u32,
        next_retry_at: Option<&str>,
        provider_message_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE outbox_messages
             SET status = ?1, retry_count = ?2, next_retry_at = ?3,
                 provider_message_id = COALESCE(?4, provider_message_id),
                 error_message = ?5, updated_at = ?6
             WHERE key = ?7",
            params![
                status.as_str(),
                retry_count as i32,
                next_retry_at,
                provider_message_id,
                error,
                now,
                key
            ],
        )?;
        Ok(())
    }

    pub fn delete_sent_outbox(&self) -> Result<u64> {
        let conn = self.conn.lock();
        let changes = conn.execute(
            "DELETE FROM outbox_messages WHERE status = ?1",
            params![OutboxStatus::Sent.as_str()],
        )?;
        Ok(changes as u64)
    }

    /// Delete a single outbox entry by key (cancel a queued/failed send). Returns
    /// whether a row matched.
    pub fn delete_outbox(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let changes = conn.execute(
            "DELETE FROM outbox_messages WHERE key = ?1",
            params![key],
        )?;
        Ok(changes > 0)
    }
}

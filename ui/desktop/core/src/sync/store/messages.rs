//! `SyncStore` — message upsert/threading, provider state, and conversation status.

use super::*;

/// The text to store as `body_plain`: the sender's `text/plain` part when there
/// is one, else the HTML stripped to text. `messages_fts` indexes `body_plain`
/// only, so an HTML-only mail (order confirmations, newsletters — 12% of a real
/// mailbox) with a NULL plain part was invisible to body search: "fiio" found
/// nothing while the order mail sat right there. Also gives reply-quoting and
/// triage a readable body for the same mail.
pub(crate) fn plain_or_text(plain: Option<&str>, html: Option<&str>) -> Option<String> {
    match plain {
        Some(p) if !p.trim().is_empty() => Some(p.to_string()),
        _ => html.filter(|h| !h.trim().is_empty()).map(threading::html_to_text),
    }
}

impl SyncStore {

    // -----------------------------------------------------------------------
    // Messages (populates existing conversations + messages tables)
    // -----------------------------------------------------------------------

    /// Upsert a message into the existing conversations/messages tables,
    /// plus track provider state in message_provider_state.
    /// Returns `true` if a brand-new message row (not just a new provider-state
    /// row for an already-known message) was created — used to drive new-message
    /// notifications.
    /// Outcome of [`SyncStore::upsert_synced_message`]: the conversation the
    /// message belongs to (for fine-grained refresh alerts) and whether the
    /// message was newly inserted (for new-mail notifications).
    pub fn upsert_synced_message(
        &self,
        account_key: &str,
        folder_key: &str,
        msg: &UnifiedMessage,
        provider_id: &ProviderMessageId,
    ) -> Result<MessageUpsert> {
        let conn = self.conn.lock();
        // One WAL commit per message instead of one per statement: the body
        // below issues ~10 writes, and initial sync calls this in a tight
        // per-page loop, so autocommit turns a 200-message page into ~2000
        // commits. An error drops the tx and rolls the whole message back.
        let tx = conn.unchecked_transaction()?;
        let now = Utc::now().to_rfc3339();

        // The provider message id is the UID-independent stable id: IMAP
        // Message-ID header, Gmail messages.id, Graph id.
        let pmid: String = provider_id
            .provider_id
            .clone()
            .unwrap_or_else(|| msg.message_id.clone());

        // Prefer the parsed Date header; fall back to the provider's
        // internal/received timestamp when the header is missing or
        // unparseable (old mail often carries non-RFC-2822 Date lines).
        // Only when neither exists do we use the sync wall-clock — otherwise
        // an unparseable header would re-date old mail to "now" and bump the
        // whole thread to the top.
        let date_str = msg
            .date
            .or(msg.internal_date)
            .map(|d| d.to_rfc3339())
            .unwrap_or_else(|| now.clone());

        // Check if message already exists by message_id_header, scoped to this
        // account (cross-account isolation: the same Message-ID may legitimately
        // exist in two connected accounts and must not be merged).
        let mut existing_msg_key: Option<String> = conn
            .query_row(
                "SELECT key FROM messages WHERE message_id_header = ?1 AND account_key = ?2",
                params![msg.message_id, account_key],
                |row| row.get(0),
            )
            .optional()?;

        // Same provider id already tracked for this account. This is what makes
        // the local copy of a message we just sent (see
        // `SyncEngine::record_sent_copy`) merge with the provider's Sent copy
        // instead of duplicating it: Gmail/Graph rewrite the Message-ID they
        // were handed, so the header lookup misses, but the id the send
        // returned is exactly the one this sync reports.
        if existing_msg_key.is_none() && !pmid.is_empty() {
            existing_msg_key = conn
                .query_row(
                    "SELECT message_key FROM message_provider_state
                     WHERE account_key = ?1 AND provider_message_id = ?2 LIMIT 1",
                    params![account_key, pmid],
                    |row| row.get(0),
                )
                .optional()?;
        }

        // Last resort for the same merge when the provider returned neither a
        // usable id nor our Message-ID (Graph's sendMail 202s with no body):
        // a Sent-folder message can claim a local outgoing row that no provider
        // sync has ever touched, sent to the same recipient with the same
        // subject inside a 15-minute window.
        // ponytail: heuristic match — it is the only handle left in that case.
        // Delete it if Graph ever hands back a message id on send.
        // Only a just-sent message can still have a local placeholder, so an old
        // message skips the scan outright — otherwise the initial sync of a big
        // Sent folder would run it once per message.
        let sent_recently = msg
            .date
            .or(msg.internal_date)
            .map(|d| (Utc::now() - d).num_seconds().abs() <= 900)
            .unwrap_or(true);
        if existing_msg_key.is_none()
            && !msg.is_inbound
            && sent_recently
            && matches!(self.folder_role(&conn, folder_key)?, Some(WellKnownFolder::Sent))
        {
            existing_msg_key = conn
                .query_row(
                    "SELECT m.key FROM messages m
                     LEFT JOIN message_provider_state s ON s.message_key = m.key
                     WHERE m.account_key = ?1 AND m.is_inbound = 0 AND s.id IS NULL
                       AND IFNULL(m.subject, '') = IFNULL(?2, '')
                       AND IFNULL(m.to_address, '') = IFNULL(?3, '')
                       AND ABS(strftime('%s', m.created_at) - strftime('%s', ?4)) <= 900
                     ORDER BY m.created_at DESC LIMIT 1",
                    params![
                        account_key,
                        crate::sync::util::header_text_opt(&msg.subject),
                        msg.to_address,
                        date_str,
                    ],
                    |row| row.get(0),
                )
                .optional()?;
        }

        let was_new = existing_msg_key.is_none();
        let (message_key, conversation_key) = if let Some(key) = existing_msg_key {
            // Message already exists — update flags via provider state only.
            let conv: String = conn.query_row(
                "SELECT conversation_key FROM messages WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )?;
            // When this is the provider's copy of a local sent message, its
            // headers are the authoritative ones from here on: replies have to
            // quote the Message-ID the recipient actually received, and the
            // conversation needs the provider thread id so the reply threads
            // into it. Both are no-ops on an ordinary re-sync.
            if !msg.message_id.is_empty() {
                conn.execute(
                    "UPDATE messages SET message_id_header = ?1, updated_at = ?2
                     WHERE key = ?3 AND IFNULL(message_id_header, '') != ?1",
                    params![msg.message_id, now, key],
                )?;
            }
            if let Some(tid) = msg.provider_thread_id.as_deref().filter(|t| !t.is_empty()) {
                conn.execute(
                    "UPDATE conversations SET provider_thread_id = ?1
                     WHERE key = ?2 AND IFNULL(provider_thread_id, '') = ''",
                    params![tid, conv],
                )?;
            }
            (key, conv)
        } else {
            // Find or create conversation by threading
            let conversation_key =
                threading::find_or_create_conversation(&conn, account_key, msg, &now)?;

            // Create message record
            let msg_key = Self::generate_key("msg");

            conn.execute(
                "INSERT INTO messages
                 (key, conversation_key, organization_id, from_address, to_address,
                  cc_address, subject, body_plain, body_html, is_inbound, is_draft,
                  message_id_header, in_reply_to, references_header, account_key,
                  created_at, updated_at, synced_at, attachment_names,
                  attachment_max_size)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
                params![
                    msg_key,
                    conversation_key,
                    account_key,
                    crate::sync::util::header_text(&msg.from_address),
                    msg.to_address,
                    msg.cc_address,
                    // NFC so search matches regardless of the sender's
                    // normalization form, entities decoded (util::header_text).
                    crate::sync::util::header_text_opt(&msg.subject),
                    plain_or_text(msg.body_plain.as_deref(), msg.body_html.as_deref()),
                    msg.body_html,
                    msg.is_inbound as i32,
                    msg.flags.draft as i32,
                    msg.message_id,
                    msg.in_reply_to,
                    msg.references_header,
                    account_key,
                    date_str,
                    now,
                    now,
                    crate::sync::util::nfc_opt(&msg.attachment_names),
                    msg.attachment_max_size,
                ],
            )?;

            // Advance the conversation's last-activity time to this message's
            // date when it's newer (threads sort by their newest message). Only
            // genuinely new messages move it — never sync wall-clock.
            //
            // The list row's sender + preview are denormalized columns on the
            // conversation, so refresh them to THIS message in the same guarded
            // update — otherwise the row would show the newest message's
            // timestamp but the thread-creating message's sender/snippet. The
            // `updated_at < ?1` guard means only a genuinely-newer message
            // overwrites them, so an out-of-order/backfilled older message can't
            // clobber the header. Keep the existing snippet when this message has
            // no body yet (headers-first IMAP sync) so the preview never blanks.
            let snippet = threading::build_snippet(
                msg.body_plain.as_deref(),
                msg.body_html.as_deref(),
            );
            conn.execute(
                "UPDATE conversations
                 SET updated_at = ?1,
                     from_address = ?3,
                     snippet = CASE WHEN ?4 != '' THEN ?4 ELSE snippet END
                 WHERE key = ?2 AND updated_at < ?1",
                params![date_str, conversation_key, crate::sync::util::header_text(&msg.from_address), snippet],
            )?;

            // Enqueue for vector embedding (background pipeline, every 5s). Gated
            // on the message date by its own (wider) window so syncing a deep
            // archive doesn't embed the whole history — keyword/FTS search still
            // covers all of it; only semantic search is bounded. Out-of-window
            // mail is simply never queued.
            if super::ai_triage::within_embedding_window(&conn, &date_str) {
                let now_eq = Utc::now().to_rfc3339();
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO embedding_queue (message_key, status, created_at, updated_at)
                     VALUES (?1, ?4, ?2, ?3)",
                    params![msg_key, now_eq, now_eq, EmbeddingStatus::Pending.as_str()],
                );
            }
            (msg_key, conversation_key)
        };

        // A thread shows the paperclip if ANY message has an attachment. Set it
        // on every upsert (new OR re-synced) so a forced resync backfills threads
        // synced before this was tracked. Only ever flip it on — a later
        // attachment-less reply must not clear it. (The column lives on the
        // conversation, not the message row, so we set it here.)
        if msg.has_attachment {
            conn.execute(
                "UPDATE conversations SET has_attachment = 1 WHERE key = ?1",
                params![conversation_key],
            )?;
        }

        // Upsert provider state (keyed on `pmid`, resolved at the top).
        let flags_json = serde_json::to_string(&msg.flags).unwrap_or_default();
        let labels_json = serde_json::to_string(&msg.labels).unwrap_or_default();

        if provider_id.uid.is_some() {
            // IMAP: dedup on the (account, folder, uid) unique constraint.
            conn.execute(
                "INSERT INTO message_provider_state
                 (message_key, account_key, folder_key, provider_uid, provider_mod_seq,
                  provider_message_id, flags, labels, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(account_key, folder_key, provider_uid) DO UPDATE SET
                  message_key = excluded.message_key,
                  provider_mod_seq = excluded.provider_mod_seq,
                  provider_message_id = excluded.provider_message_id,
                  flags = excluded.flags,
                  labels = excluded.labels,
                  updated_at = excluded.updated_at",
                params![
                    message_key,
                    account_key,
                    folder_key,
                    provider_id.uid.map(|u| u as i64),
                    provider_id.mod_seq.map(|m| m as i64),
                    pmid,
                    flags_json,
                    labels_json,
                    now,
                    now,
                ],
            )?;
        } else {
            // Gmail/Microsoft: provider_uid is NULL, so the UID unique constraint
            // never fires. Dedup on (account, folder, provider_message_id), which
            // the partial index idx_msg_provider_state_gmail_mid covers.
            let existing_id: Option<i64> = conn
                .query_row(
                    "SELECT id FROM message_provider_state
                     WHERE account_key = ?1 AND folder_key = ?2 AND provider_message_id = ?3",
                    params![account_key, folder_key, pmid],
                    |row| row.get(0),
                )
                .optional()?;

            if let Some(id) = existing_id {
                conn.execute(
                    "UPDATE message_provider_state
                     SET message_key = ?1, flags = ?2, labels = ?3, updated_at = ?4
                     WHERE id = ?5",
                    params![message_key, flags_json, labels_json, now, id],
                )?;
            } else {
                conn.execute(
                    "INSERT INTO message_provider_state
                     (message_key, account_key, folder_key, provider_uid, provider_mod_seq,
                      provider_message_id, flags, labels, created_at, updated_at)
                     VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9)",
                    params![
                        message_key,
                        account_key,
                        folder_key,
                        provider_id.mod_seq.map(|m| m as i64),
                        pmid,
                        flags_json,
                        labels_json,
                        now,
                        now,
                    ],
                )?;
            }
        }

        // Update conversation read/status based on flags — but only if no local
        // write-back for this message is still settling on the provider.
        // Archive/trash/mark-read are applied optimistically to the local
        // conversation the instant the user acts, then queued to the provider.
        // Until that write-back round-trips, a concurrent sync still pulls the
        // *pre-mutation* provider flags (e.g. a just-deleted message still
        // carrying INBOX, trashed=false). Mirroring those onto the conversation
        // here would resurrect the thread — the sync-vs-writeback race.
        //
        // The guard covers two phases: while the action is pending/in_progress
        // it always blocks the mirror; once it's completed it keeps blocking
        // until the incoming provider flags actually *agree* with the action's
        // intent (`settled_by_flags`). The completed phase matters because a
        // sync that snapshotted the pre-mutation state can be in flight when the
        // write-back lands — applying that stale snapshot just after the action
        // completed (and before the provider's settled state is re-synced) is
        // exactly what made a deleted message flicker back into the inbox.
        let writeback_blocks_mirror = self.writeback_blocks_mirror(
            &conn,
            &conversation_key,
            &message_key,
            account_key,
            &msg.flags,
        )?;

        // Outbound folders never define a conversation's inbox lifecycle. A Sent
        // (or Drafts) copy always reports archived=false/spam=false/trashed=false
        // and read=true regardless of the thread's real state, so mirroring its
        // flags would resurrect an archived thread into the inbox and mark unread
        // threads read the next time the Sent folder is synced. Inbox/Archive/
        // Spam/Trash copies remain the source of truth. (Matches the Sent/Drafts
        // exclusion already applied on the notification path.)
        let outbound_folder = matches!(
            self.folder_role(&conn, folder_key)?,
            Some(WellKnownFolder::Sent) | Some(WellKnownFolder::Drafts)
        );
        if !writeback_blocks_mirror && !outbound_folder {
            threading::update_conversation_from_flags(&conn, &message_key, &msg.flags)?;
        }

        // Enqueue a new message's conversation for async triage + summaries (see
        // crate::ai_worker). Runs after the status mirror so the gate sees the
        // thread's real status: eligible when the message is inside the processing
        // window OR the thread is open (the inbox is always triaged; the window
        // only bounds history). A first sync of a deep archive therefore doesn't
        // queue everything. Priority is the thread's latest activity (updated_at)
        // so a recent reply to an old thread still drains first. A new message on
        // an existing thread re-upserts the row back to pending — that is the
        // re-classification trigger.
        if was_new && super::ai_triage::triage_eligible(&conn, &conversation_key, &date_str) {
            let priority: String = conn
                .query_row(
                    "SELECT updated_at FROM conversations WHERE key = ?1",
                    params![conversation_key],
                    |r| r.get(0),
                )
                .unwrap_or_else(|_| date_str.clone());
            let _ = super::ai_triage::enqueue_triage_job(&conn, &conversation_key, &priority);
        }

        // (New messages are enqueued for embedding inside the new-message branch
        // above, gated by the embedding window — see `within_embedding_window`.)

        tx.commit()?;
        Ok(MessageUpsert { conversation_key, message_key, was_new })
    }

    /// Whether a settling write-back for this message's *conversation* should
    /// block the status/read mirror during sync.
    ///
    /// The guard is conversation-scoped, not message-scoped, because the
    /// mutation it protects is conversation-level (archive/trash/mark-read flip
    /// the whole thread) while the provider re-syncs flags one message at a
    /// time. A keyed-by-message guard left every sibling unprotected: a thread
    /// the user just archived would be resurrected the instant a sync mirrored
    /// the pre-mutation `archived=false` flags of any message in it that lacked
    /// its *own* live write-back row — a new reply, a second folder copy under a
    /// different `message_key`, or a sibling whose action had already reaped.
    /// That is the archive-then-reappear-then-vanish flicker.
    ///
    /// An action blocks the mirror for the message being synced whenever the
    /// incoming `flags` don't yet reflect its intent (`settled_by_flags`):
    /// pending/in-progress actions haven't reached the provider, and a
    /// completed action keeps protecting the local intent until a sync actually
    /// carries the settled flags — a pre-mutation snapshot can still be in
    /// flight when the write-back lands. Flags that already agree are harmless
    /// (they reproduce the optimistic state) and don't block. Completed actions
    /// are retained by `delete_completed_actions` for a short settle grace so
    /// they're still visible to this check.
    fn writeback_blocks_mirror(
        &self,
        conn: &Connection,
        conversation_key: &str,
        message_key: &str,
        account_key: &str,
        flags: &UnifiedFlags,
    ) -> Result<bool> {
        let mut stmt = conn.prepare(
            "SELECT wa.key, wa.payload, wa.status, wa.message_key
             FROM writeback_actions wa
             JOIN messages m ON m.key = wa.message_key
             WHERE m.conversation_key = ?1 AND wa.account_key = ?2
               AND wa.status IN (?3, ?4, ?5)",
        )?;
        let rows = stmt
            .query_map(
                params![
                    conversation_key,
                    account_key,
                    ActionStatus::Pending.as_str(),
                    ActionStatus::InProgress.as_str(),
                    ActionStatus::Completed.as_str()
                ],
                |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let mut blocks = false;
        // Completed actions whose intent the provider's flags now reflect: the
        // local mutation has fully round-tripped, so drop the action and stop
        // guarding it. Reaping on agreement (rather than only on the time-based
        // settle grace) means a genuine later remote change isn't blocked. Only
        // reap an action when the *agreeing* flags are its own message's — a
        // sibling's flags agreeing doesn't mean the provider round-tripped this
        // particular message's mutation.
        let mut settled_keys: Vec<String> = Vec::new();

        for (key, payload, status_str, action_message_key) in rows {
            // The JSON payload is authoritative (carries structured variants'
            // fields) and is written for every row — a parse failure is
            // corruption, not a missing column.
            let action_type =
                serde_json::from_str::<ActionType>(&payload).unwrap_or_else(|e| {
                    log::error!(
                        "unparseable writeback action payload ({e}); treating as mark_read"
                    );
                    ActionType::MarkRead
                });
            let flags_agree = action_type.settled_by_flags(flags);
            match ActionStatus::from_str(&status_str) {
                // Optimistic mutation not yet confirmed on the provider. Block
                // the mirror unless these flags already match the intent, in
                // which case mirroring just reproduces the optimistic state.
                ActionStatus::Pending | ActionStatus::InProgress => {
                    if !flags_agree {
                        blocks = true;
                    }
                }
                // Confirmed on the provider, but keep protecting the local
                // intent until a sync actually carries the settled flags — a
                // stale in-flight snapshot could still contradict them.
                ActionStatus::Completed => {
                    if flags_agree {
                        if action_message_key == message_key {
                            settled_keys.push(key);
                        }
                    } else {
                        blocks = true;
                    }
                }
                // A permanently failed write-back never reached the provider, so
                // the provider's flags are the truth — let the mirror run.
                ActionStatus::Failed => {}
            }
        }
        drop(stmt);

        for key in &settled_keys {
            conn.execute("DELETE FROM writeback_actions WHERE key = ?1", params![key])?;
        }
        if !settled_keys.is_empty() {
            // The other place a completed action disappears — here it's dropped because
            // the provider's flags now agree, i.e. the mutation genuinely round-tripped.
            log::info!(
                "[writeback] settled by provider flags, dropping {} action(s) for msg {}: {}",
                settled_keys.len(),
                message_key,
                settled_keys.join(", ")
            );
        }
        Ok(blocks)
    }

    /// Well-known role of a folder by its key, if the folder is known and
    /// classified. Used to gate per-folder behaviour (e.g. not mirroring an
    /// outbound copy's flags onto the conversation). Unknown/unclassified
    /// folders return `None`.
    fn folder_role(
        &self,
        conn: &Connection,
        folder_key: &str,
    ) -> Result<Option<WellKnownFolder>> {
        let role: Option<Option<String>> = conn
            .query_row(
                "SELECT well_known_role FROM external_folders WHERE key = ?1",
                params![folder_key],
                |row| row.get(0),
            )
            .optional()?;
        Ok(role.flatten().map(|s| WellKnownFolder::from_str(&s)))
    }

    /// Notification payload for a freshly-synced message, looked up by its
    /// provider id (mirrors the JS new-message query).
    ///
    /// Returns None when the message's conversation is spam or trash. The
    /// engine already skips messages whose own flags mark them spam/trash, but
    /// a new message can thread into a conversation that is *already* spam/trash
    /// (e.g. a repeat promo threading into a thread the user previously marked
    /// spam, or a reply arriving via INBOX without its own spam flag). Notifying
    /// for such a message is the confusing "click it, the inbox list looks
    /// empty" case, since the conversation is filtered out of the inbox.
    pub fn message_notification(
        &self,
        account_key: &str,
        provider_id: &str,
    ) -> Result<Option<NewMessageNotification>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT c.key, c.subject, c.from_address, c.snippet, c.updated_at, c.status,
                    m.key, c.has_attachment, m.body_plain, m.body_html, c.from_avatar
             FROM messages m
             JOIN conversations c ON c.key = m.conversation_key
             JOIN message_provider_state mps ON mps.message_key = m.key
             WHERE mps.provider_message_id = ?1 AND mps.account_key = ?2 LIMIT 1",
            params![provider_id, account_key],
            |row| {
                let status: String = row.get(5)?;
                Ok((
                    NewMessageNotification {
                        key: row.get(0)?,
                        // Rows written before util::header_text existed still
                        // carry raw entities; decoding is idempotent on clean text.
                        subject: row.get::<_, Option<String>>(1)?.as_deref().map(threading::decode_text_entities),
                        from_address: row.get::<_, Option<String>>(2)?.as_deref().map(threading::decode_text_entities),
                        snippet: row.get(3)?,
                        updated_at: row.get(4)?,
                        from_avatar: row.get(10)?,
                        account_key: account_key.to_string(),
                        email: String::new(),
                        message_key: row.get(6)?,
                        has_attachment: row.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0,
                        otp: {
                            let subject: Option<String> = row.get(1)?;
                            let snippet: Option<String> = row.get(3)?;
                            let plain: Option<String> = row.get(8)?;
                            let html: Option<String> = row.get(9)?;
                            crate::otp::detect(subject.as_deref(), plain.as_deref(), html.as_deref(), snippet.as_deref())
                        },
                    },
                    status,
                ))
            },
        )
        .optional()
        .map(|row| {
            row.and_then(|(notif, status)| {
                if ConversationStatus::from_str(&status).is_hidden_from_inbox() {
                    None
                } else {
                    Some(notif)
                }
            })
        })
        .map_err(Into::into)
    }

    // -----------------------------------------------------------------------
    // Provider state queries
    // -----------------------------------------------------------------------

    pub fn get_provider_state(
        &self,
        account_key: &str,
        folder_key: &str,
        provider_uid: u32,
    ) -> Result<Option<(String, ProviderMessageId)>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT message_key, provider_uid, provider_mod_seq, provider_message_id
             FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_uid = ?3",
            params![account_key, folder_key, provider_uid as i64],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    ProviderMessageId {
                        uid: row.get::<_, Option<i64>>(1)?.map(|v| v as u32),
                        mod_seq: row.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                        provider_id: row.get(3)?,
                    },
                ))
            },
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_provider_state_by_message(
        &self,
        message_key: &str,
        account_key: &str,
    ) -> Result<Option<(String, ProviderMessageId)>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT folder_key, provider_uid, provider_mod_seq, provider_message_id
             FROM message_provider_state
             WHERE message_key = ?1 AND account_key = ?2 LIMIT 1",
            params![message_key, account_key],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    ProviderMessageId {
                        uid: row.get::<_, Option<i64>>(1)?.map(|v| v as u32),
                        mod_seq: row.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                        provider_id: row.get(3)?,
                    },
                ))
            },
        )
        .optional()
        .map_err(Into::into)
    }

    /// Locate a message's (folder_key, UID) by its stable provider id
    /// (Message-ID for IMAP). Used by the IMAP interactive `perform_action`,
    /// which is handed only provider ids but needs a folder + UID to act.
    pub fn provider_state_by_provider_id(
        &self,
        account_key: &str,
        provider_id: &str,
    ) -> Result<Option<(String, u32)>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT folder_key, provider_uid
             FROM message_provider_state
             WHERE account_key = ?1 AND provider_message_id = ?2 AND provider_uid IS NOT NULL
             LIMIT 1",
            params![account_key, provider_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u32)),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_known_uids(&self, account_key: &str, folder_key: &str) -> Result<Vec<u32>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT provider_uid FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_uid IS NOT NULL
             ORDER BY provider_uid",
        )?;
        let rows = stmt.query_map(params![account_key, folder_key], |row| {
            Ok(row.get::<_, i64>(0)? as u32)
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn get_known_message_ids(
        &self,
        account_key: &str,
        folder_key: &str,
    ) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT provider_message_id FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_message_id IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![account_key, folder_key], |row| row.get(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Distinct provider message ids known *anywhere* in an account (across all
    /// folders). Lets the Gmail All-Mail sync fetch only the archived-only delta
    /// — messages we don't already hold from INBOX/SENT/etc. — instead of
    /// re-downloading the whole mailbox. Account-wide counterpart to the
    /// per-folder [`Self::get_known_message_ids`].
    pub fn known_provider_ids_for_account(&self, account_key: &str) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT provider_message_id FROM message_provider_state
             WHERE account_key = ?1 AND provider_message_id IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![account_key], |row| row.get(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Provider message ids already stored in one folder of an account.
    pub fn known_provider_ids_for_folder(
        &self,
        account_key: &str,
        folder_key: &str,
    ) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT provider_message_id FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_message_id IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![account_key, folder_key], |row| row.get(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Local conversations holding any of `provider_ids` (provider message ids) or
    /// `message_ids` (bare RFC 5322 Message-IDs, no angle brackets) in an account:
    /// how a provider-side search hit maps back onto the local mirror. The
    /// Message-ID leg covers Graph ids, which change when a message moves folder.
    pub fn conversation_keys_for_hits(
        &self,
        account_key: &str,
        provider_ids: &[String],
        message_ids: &[String],
    ) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT m.conversation_key FROM messages m
             WHERE m.account_key = ?1 AND m.conversation_key IS NOT NULL AND (
               m.key IN (SELECT s.message_key FROM message_provider_state s
                         WHERE s.account_key = ?1
                           AND s.provider_message_id IN (SELECT value FROM json_each(?2)))
               OR trim(m.message_id_header, '<> ') IN (SELECT value FROM json_each(?3)))",
        )?;
        // Vec<String> → JSON can't fail.
        let ids = serde_json::Value::from(provider_ids.to_vec()).to_string();
        let mids = serde_json::Value::from(message_ids.to_vec()).to_string();
        let rows = stmt.query_map(params![account_key, ids, mids], |row| row.get(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn delete_provider_state_for_uid(
        &self,
        account_key: &str,
        folder_key: &str,
        uid: u32,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_uid = ?3",
            params![account_key, folder_key, uid as i64],
        )?;
        Ok(())
    }

    /// Delete a message that disappeared from the provider, cascading message →
    /// conversation when nothing else references them. See
    /// [`crate::sync::deletion::cascade_delete_message`].
    pub fn cascade_delete_message(
        &self,
        account_key: &str,
        folder_key: &str,
        pid: &ProviderMessageId,
    ) -> Result<()> {
        let conn = self.conn.lock();
        deletion::cascade_delete_message(&conn, account_key, folder_key, pid)
    }

    /// After a full folder sync, remove locally-known messages whose provider id
    /// was not present in the remote listing (`seen`). Returns the count removed.
    /// See [`crate::sync::deletion::prune_unseen_provider_ids`].
    pub fn prune_unseen_provider_ids(
        &self,
        account_key: &str,
        folder_key: &str,
        seen: &std::collections::HashSet<String>,
    ) -> Result<usize> {
        let known = self.get_known_message_ids(account_key, folder_key)?;
        let mut conn = self.conn.lock();
        // One transaction for the whole prune: each orphan cascade issues several
        // statements, and without this each ran as its own implicit transaction
        // (one fsync per orphan). `Transaction` derefs to `Connection`, so the
        // cascade logic is unchanged.
        let tx = conn.transaction()?;
        let removed = deletion::prune_unseen_provider_ids(&tx, account_key, folder_key, &known, seen)?;
        tx.commit()?;
        Ok(removed)
    }

    pub fn invalidate_folder_uids(&self, account_key: &str, folder_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE message_provider_state SET provider_uid = NULL
             WHERE account_key = ?1 AND folder_key = ?2",
            params![account_key, folder_key],
        )?;
        conn.execute(
            "UPDATE external_folders SET uid_validity = NULL, highest_mod_seq = 0,
             last_synced_uid = 0, sync_cursor = NULL, updated_at = ?1 WHERE key = ?2",
            params![Utc::now().to_rfc3339(), folder_key],
        )?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Interactive-op support (on-demand fetch / send / actions)
    // -----------------------------------------------------------------------

    /// Provider message id stored for a local message (if any).
    pub fn get_provider_id_for_message(
        &self,
        account_key: &str,
        message_key: &str,
    ) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT provider_message_id FROM message_provider_state
             WHERE message_key = ?1 AND account_key = ?2 AND provider_message_id IS NOT NULL LIMIT 1",
            params![message_key, account_key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Threading context of a local message, for replying to it: its RFC
    /// Message-ID, its References chain, and its conversation's provider-native
    /// thread id (Gmail `threadId`). `None` when the message doesn't exist.
    pub fn reply_context(
        &self,
        message_key: &str,
    ) -> Result<Option<(Option<String>, Option<String>, Option<String>)>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT m.message_id_header, m.references_header, c.provider_thread_id
             FROM messages m LEFT JOIN conversations c ON c.key = m.conversation_key
             WHERE m.key = ?1 LIMIT 1",
            params![message_key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(Into::into)
    }

    /// RFC Message-ID header for a local message (used to search the provider).
    /// Drop a message's provider-state rows.
    ///
    /// Used for a locally-recorded sent copy whose provider returned no message
    /// id (Graph's `sendMail`): the upsert would otherwise fall back to our own
    /// Message-ID as the provider handle, which is not one — write-back would
    /// hand it to the API, and the Sent copy could not adopt the row on sync.
    /// No state row is the truthful state: we don't know the provider's id yet.
    pub fn clear_provider_state(&self, message_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM message_provider_state WHERE message_key = ?1",
            params![message_key],
        )?;
        Ok(())
    }

    pub fn get_message_id_header(&self, message_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT message_id_header FROM messages WHERE key = ?1 LIMIT 1",
            params![message_key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn first_folder_key(&self, account_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT key FROM external_folders WHERE account_key = ?1 LIMIT 1",
            params![account_key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Backfill a provider id discovered via on-demand search, so future lookups
    /// are fast (mirrors the JS resolve*Id backfill).
    pub fn backfill_provider_state(
        &self,
        message_key: &str,
        account_key: &str,
        folder_key: &str,
        provider_id: &str,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "INSERT OR IGNORE INTO message_provider_state
             (message_key, account_key, folder_key, provider_uid, provider_message_id,
              flags, labels, created_at, updated_at)
             VALUES (?1, ?2, ?3, NULL, ?4, '{}', '[]', ?5, ?5)",
            params![message_key, account_key, folder_key, provider_id, now],
        )?;
        Ok(())
    }

    pub fn update_message_body(
        &self,
        message_key: &str,
        body_html: Option<&str>,
        body_plain: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET body_html = ?1, body_plain = ?2, updated_at = ?3 WHERE key = ?4",
            params![body_html, plain_or_text(body_plain, body_html), Utc::now().to_rfc3339(), message_key],
        )?;

        // Backfill the conversation snippet for lazily-loaded bodies: providers
        // like Microsoft (and HTML-only mail with no text/plain part) leave the
        // body absent at sync time, so the upsert advanced the row's sender +
        // timestamp to this message but had to keep the prior snippet (its body
        // was empty). Now that we have the body, repoint the snippet to it —
        // but ONLY when this message is the conversation's newest (or the
        // snippet is still empty). Keying off "is this the newest message?"
        // rather than "is the snippet empty?" is the fix for the reported bug:
        // a newer reply arriving body-less left the row showing its sender but
        // the *previous* message's summary text, because the old empty-only
        // guard refused to overwrite the (non-empty) stale snippet. An older
        // message's late body still won't clobber the preview — it isn't the
        // newest, so the guard skips it.
        let snippet = threading::build_snippet(body_plain, body_html);
        if !snippet.is_empty() {
            conn.execute(
                "UPDATE conversations SET snippet = ?1
                 WHERE key = (SELECT conversation_key FROM messages WHERE key = ?2)
                   AND (
                     snippet IS NULL OR snippet = ''
                     OR ?2 = (
                       SELECT key FROM messages
                       WHERE conversation_key = conversations.key
                       ORDER BY created_at DESC, rowid DESC LIMIT 1
                     )
                   )",
                params![snippet, message_key],
            )?;
        }
        Ok(())
    }

    /// Record a message's attachment filenames so they become searchable
    /// (messages_fts indexes `messages.attachment_names`). The sync list payload
    /// only carries filenames for some providers (Gmail), so IMAP/Microsoft/Meta
    /// backfill here the first time a message is fetched/opened. No-op when
    /// `names` is empty or already stored, so reopening a message is free. The
    /// `messages_au` trigger keeps the FTS index in step.
    ///
    /// `max_size` is the largest attachment's size in bytes (the `larger:`/
    /// `smaller:` filters) — learned from the same fetch as the filenames.
    pub fn backfill_attachment_names(
        &self,
        message_key: &str,
        names: &str,
        max_size: Option<i64>,
    ) -> Result<()> {
        if names.is_empty() {
            return Ok(());
        }
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET attachment_names = ?1, attachment_max_size = ?3
             WHERE key = ?2 AND (attachment_names IS NULL OR attachment_names <> ?1
                                 OR attachment_max_size IS NULL)",
            params![names, message_key, max_size],
        )?;
        Ok(())
    }

    /// Unconditionally set a message's `attachment_names` — an empty string means
    /// "checked, no real attachments". Used by the one-time backfill sweep so a
    /// message whose `has_attachment` came from an inline-only image isn't
    /// re-fetched forever (the candidate query keys off `attachment_names IS NULL`).
    pub fn set_attachment_names(
        &self,
        message_key: &str,
        names: &str,
        max_size: Option<i64>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET attachment_names = ?1, attachment_max_size = ?3 WHERE key = ?2",
            params![names, message_key, max_size],
        )?;
        Ok(())
    }

    /// Messages that carry attachments but have no indexed filenames yet —
    /// `(account_key, message_key)` ordered by account so the caller can reuse one
    /// provider per account. These predate filename indexing (or were synced by a
    /// provider that doesn't expose filenames up front); the backfill sweep fetches
    /// each and records its names so a filename search finds it. Ordered, bounded.
    pub fn messages_needing_filename_backfill(
        &self,
        limit: usize,
    ) -> Result<Vec<(String, String)>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT m.account_key, m.key
             FROM messages m
             JOIN conversations c ON c.key = m.conversation_key
             WHERE c.has_attachment = 1
               AND m.attachment_names IS NULL
               AND m.account_key IS NOT NULL
             ORDER BY m.account_key
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// One batch of the HTML-only body-text backfill (see [`plain_or_text`]):
    /// messages with `id > after` whose plain part is empty but carry HTML get
    /// `body_plain` derived from it; the FTS trigger re-indexes them. Stripping
    /// happens with the lock released. Returns the last id visited (`None` once
    /// the table is exhausted) so the caller can page without a marker per row.
    pub fn backfill_html_body_text(&self, after: i64, limit: usize) -> Result<Option<i64>> {
        let rows: Vec<(i64, String)> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT id, body_html FROM messages
                 WHERE id > ?1 AND COALESCE(body_plain, '') = '' AND COALESCE(body_html, '') != ''
                 ORDER BY id LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![after, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        let Some(&(last, _)) = rows.last() else { return Ok(None) };
        let texts: Vec<(i64, Option<String>)> =
            rows.iter().map(|(id, html)| (*id, plain_or_text(None, Some(html)))).collect();
        let conn = self.conn.lock();
        for (id, text) in texts {
            conn.execute("UPDATE messages SET body_plain = ?1 WHERE id = ?2", params![text, id])?;
        }
        Ok(Some(last))
    }

    /// One-shot cleanup for previews stored before the snippet sanitizer
    /// existed: any conversation whose snippet isn't a fixed point of
    /// [`threading::sanitize_snippet_text`] (leaked CSS rules, invisible
    /// preheader padding) gets it rebuilt from its newest message that has a
    /// body. Idempotent and cheap on a clean store (one snippet scan, no
    /// writes), so it simply runs at every open. Returns how many were fixed.
    pub fn scrub_dirty_snippets(&self) -> Result<usize> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT key, snippet FROM conversations WHERE COALESCE(snippet,'') != ''")?;
        let rows: Vec<(String, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);
        let mut scrubbed = 0;
        for (key, snippet) in rows {
            let clean = threading::sanitize_snippet_text(&snippet);
            // A snippet is dirty if sanitizing changes it (leaked CSS / padding)
            // OR if it's raw HTML source (sanitize keeps tags, so it'd be a fixed
            // point, but it still reads as gibberish and must be rebuilt/stripped).
            if clean == snippet && !threading::looks_like_html_source(&snippet) {
                continue;
            }
            // Rebuild from the body: the stored snippet was truncated with the
            // junk still inside, so sanitizing the snippet alone would drop tail
            // text the body still has.
            let body: Option<(Option<String>, Option<String>)> = conn
                .query_row(
                    "SELECT body_plain, body_html FROM messages
                     WHERE conversation_key = ?1
                       AND (COALESCE(body_plain,'') != '' OR COALESCE(body_html,'') != '')
                     ORDER BY created_at DESC LIMIT 1",
                    params![key],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let next = match body {
                Some((p, h)) => threading::build_snippet(p.as_deref(), h.as_deref()),
                None => clean,
            };
            if next != snippet {
                conn.execute(
                    "UPDATE conversations SET snippet = ?1 WHERE key = ?2",
                    params![next, key],
                )?;
                scrubbed += 1;
            }
        }
        Ok(scrubbed)
    }

    /// One-shot realignment for conversations stored before the sync path
    /// refreshed the denormalized preview on every new message: older builds set
    /// `from_address`/`snippet` only at thread creation, so a thread's row could
    /// show the newest message's timestamp but an *older* message's sender and
    /// snippet. This repoints both to the conversation's newest message.
    ///
    /// Detection is a single indexed scan (newest message per conversation via
    /// `idx_messages_conv`); only rows whose stored `from_address` already
    /// disagrees with that newest message are rewritten, so it's a no-op once
    /// the store is written by the current sync path — same "runs at open,
    /// idempotent" contract as [`Self::scrub_dirty_snippets`]. The snippet is
    /// kept when the newest message has no body yet (headers-first sync).
    /// Returns how many rows were realigned.
    pub fn realign_conversation_previews(&self) -> Result<usize> {
        let conn = self.conn.lock();
        // A message's `created_at` is its own date, so the MAX(created_at)
        // message is the same "newest" the inbox sorts by (conversations
        // `updated_at`). `rowid` breaks same-timestamp ties deterministically.
        let mut stmt = conn.prepare(
            "SELECT c.key, m.from_address, m.body_plain, m.body_html
             FROM conversations c
             JOIN messages m ON m.key = (
                 SELECT key FROM messages
                 WHERE conversation_key = c.key
                 ORDER BY created_at DESC, rowid DESC LIMIT 1
             )
             WHERE COALESCE(c.from_address, '') != COALESCE(m.from_address, '')",
        )?;
        #[allow(clippy::type_complexity)]
        let rows: Vec<(String, Option<String>, Option<String>, Option<String>)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);
        let mut fixed = 0;
        for (key, from_address, body_plain, body_html) in rows {
            let snippet =
                threading::build_snippet(body_plain.as_deref(), body_html.as_deref());
            conn.execute(
                "UPDATE conversations
                 SET from_address = ?2,
                     snippet = CASE WHEN ?3 != '' THEN ?3 ELSE snippet END
                 WHERE key = ?1",
                params![key, from_address, snippet],
            )?;
            fixed += 1;
        }
        Ok(fixed)
    }

    /// Reconstruct a minimal RFC822 source from local data (fallback for
    /// "view source" when the provider call fails).
    pub fn local_message_source(&self, message_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT from_address, to_address, cc_address, subject, created_at,
                    message_id_header, body_plain, body_html
             FROM messages WHERE key = ?1 LIMIT 1",
            params![message_key],
            |row| {
                let from: Option<String> = row.get(0)?;
                let to: Option<String> = row.get(1)?;
                let cc: Option<String> = row.get(2)?;
                let subject: Option<String> = row.get(3)?;
                let date: Option<String> = row.get(4)?;
                let mid: Option<String> = row.get(5)?;
                let plain: Option<String> = row.get(6)?;
                let html: Option<String> = row.get(7)?;
                let mut headers = vec![
                    format!("From: {}", from.unwrap_or_default()),
                    format!("To: {}", to.unwrap_or_default()),
                ];
                if let Some(cc) = cc {
                    if !cc.is_empty() {
                        headers.push(format!("Cc: {cc}"));
                    }
                }
                headers.push(format!("Subject: {}", subject.unwrap_or_default()));
                headers.push(format!("Date: {}", date.unwrap_or_default()));
                headers.push(format!("Message-ID: {}", mid.unwrap_or_default()));
                let body = plain.or(html).unwrap_or_default();
                Ok(format!("{}\n\n{}", headers.join("\n"), body))
            },
        )
        .optional()
        .map_err(Into::into)
    }

    /// Provider message ids for every message in a conversation (for write-back
    /// of conversation-level actions).
    pub fn provider_ids_for_conversation(
        &self,
        account_key: &str,
        conversation_key: &str,
    ) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT mps.provider_message_id
             FROM messages m
             JOIN message_provider_state mps ON mps.message_key = m.key
             WHERE m.conversation_key = ?1 AND mps.account_key = ?2
               AND mps.provider_message_id IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![conversation_key, account_key], |row| row.get(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Message keys (+ their folder) for a conversation on an account. Used to
    /// enqueue per-message write-back actions, which the queue keys by
    /// message_key and applies via the provider's folder/UID-aware path.
    pub fn message_keys_for_conversation(
        &self,
        account_key: &str,
        conversation_key: &str,
    ) -> Result<Vec<(String, Option<String>)>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT m.key, mps.folder_key
             FROM messages m
             JOIN message_provider_state mps ON mps.message_key = m.key
             WHERE m.conversation_key = ?1 AND mps.account_key = ?2",
        )?;
        let rows = stmt.query_map(params![conversation_key, account_key], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn set_conversation_priority(
        &self,
        conversation_key: &str,
        urgent: bool,
        important: bool,
        triaged: bool,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE conversations SET priority_urgent = ?1, priority_important = ?2,
             priority_triaged = ?3, updated_at = ?4 WHERE key = ?5",
            params![
                urgent as i32,
                important as i32,
                triaged as i32,
                Utc::now().to_rfc3339(),
                conversation_key
            ],
        )?;
        Ok(())
    }

    /// Optimistically apply a user action's status/read change to a conversation,
    /// before the write-back round-trips to the provider. This is the single
    /// place local conversation state is updated for archive/trash/spam and
    /// mark-read/unread — call sites only do in-memory UI updates and never
    /// write the DB directly, so a concurrent sync re-query reflects the action
    /// immediately rather than resurrecting the old state.
    ///
    /// Like `update_conversation_from_flags`, this deliberately does NOT touch
    /// `updated_at`: a status/read change is not new activity and must not
    /// resort the inbox.
    pub fn set_conversation_status(
        &self,
        conversation_key: &str,
        status: Option<ConversationStatus>,
        read: Option<bool>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        if let Some(status) = status {
            conn.execute(
                "UPDATE conversations SET status = ?1 WHERE key = ?2",
                params![status.as_str(), conversation_key],
            )?;
        }
        if let Some(read) = read {
            conn.execute(
                "UPDATE conversations SET read = ?1 WHERE key = ?2",
                params![read as i32, conversation_key],
            )?;
        }
        Ok(())
    }
}

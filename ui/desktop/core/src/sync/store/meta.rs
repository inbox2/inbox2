//! `SyncStore` — apply normalized Meta events into the unified model.
//!
//! Builds on [`SyncStore::upsert_synced_message`] (which owns threading + dedup
//! + provider state) and then stamps the Meta-specific columns: `messages.channel`
//! / `messages.kind`, and `conversations.channel` / `cs_recipient_id` /
//! `cs_window_last_inbound_at`. Dedup is inherited — re-applying the same event
//! (Meta retries) is a no-op for the message row.

use super::*;
use crate::sync::meta_normalize::{NormalizedMessage, NormalizedMetaEvent};

/// The WhatsApp / Meta customer-service window: a business may freely send
/// session messages within 24h of the customer's last inbound message.
const CS_WINDOW_HOURS: i64 = 24;

impl SyncStore {
    /// Apply one normalized event. `Message` events upsert into the unified
    /// model; `Reaction`/`Status` are best-effort updates (reactions and delivery
    /// receipts have no first-class home in the unified model yet — they are
    /// logged so the information isn't silently lost). Returns the
    /// [`MessageUpsert`] for `Message` events (for new-message notifications),
    /// `None` otherwise.
    pub fn apply_meta_event(
        &self,
        account_key: &str,
        folder_key: &str,
        event: &NormalizedMetaEvent,
    ) -> Result<Option<MessageUpsert>> {
        match event {
            NormalizedMetaEvent::Message(m) => {
                Ok(Some(self.apply_meta_message(account_key, folder_key, m)?))
            }
            NormalizedMetaEvent::Reaction { target_id, emoji, removed } => {
                let value = if *removed { None } else { emoji.as_deref() };
                if let Err(e) = self.set_message_reaction(account_key, target_id, value) {
                    log::warn!("[meta] reaction on {target_id}: {e}");
                }
                Ok(None)
            }
            NormalizedMetaEvent::Status { target_id, status, error_code } => {
                // `failed` records the error code alongside so the UI can explain it.
                let stored = match error_code {
                    Some(code) => format!("failed:{code}"),
                    None => status.clone(),
                };
                if let Err(e) = self.set_message_delivery_status(account_key, target_id, &stored) {
                    log::warn!("[meta] status {status} on {target_id}: {e}");
                }
                Ok(None)
            }
        }
    }

    /// Upsert a normalized Meta message and stamp its channel/kind + the
    /// conversation's channel/recipient/CS-window.
    pub fn apply_meta_message(
        &self,
        account_key: &str,
        folder_key: &str,
        m: &NormalizedMessage,
    ) -> Result<MessageUpsert> {
        let upsert = self.upsert_synced_message(account_key, folder_key, &m.msg, &m.provider_id)?;

        let conn = self.conn.lock();
        // Stamp the message surface + kind (+ WhatsApp media descriptors).
        conn.execute(
            "UPDATE messages SET channel = ?1, kind = ?2, meta_media = COALESCE(?4, meta_media) WHERE key = ?3",
            params![m.channel, m.kind, upsert.message_key, m.media],
        )?;

        // Stamp the conversation channel + kind + reply target. A Meta thread is
        // single-kind (DMs/comments/mentions thread separately), so kind lives on
        // the conversation for channel/kind sub-views. cs_recipient_id is only set
        // for DMs (comments reply per-message via reply_to_message_key).
        conn.execute(
            "UPDATE conversations SET channel = ?1, kind = ?2 WHERE key = ?3 AND (channel IS NULL OR channel = ?1)",
            params![m.channel, m.kind, upsert.conversation_key],
        )?;
        if let Some(recipient) = &m.recipient_id {
            conn.execute(
                "UPDATE conversations SET cs_recipient_id = ?1 WHERE key = ?2 AND cs_recipient_id IS NULL",
                params![recipient, upsert.conversation_key],
            )?;
        }

        // (Re)open the 24h CS window from the customer's latest inbound message.
        // Monotonic: only advance the anchor (never move it backwards on an
        // out-of-order delivery). RFC-3339 UTC strings compare lexicographically.
        if let Some(when) = m.window_inbound_at {
            let ts = when.to_rfc3339();
            conn.execute(
                "UPDATE conversations
                 SET cs_window_last_inbound_at = ?1
                 WHERE key = ?2
                   AND (cs_window_last_inbound_at IS NULL OR cs_window_last_inbound_at < ?1)",
                params![ts, upsert.conversation_key],
            )?;
        }

        Ok(upsert)
    }

    /// Mark conversations read in bulk (read state lives on the conversation, not
    /// the message). Used by the historical backfill so a first sync doesn't
    /// surface every past thread as unread — Meta exposes no inbound read state,
    /// and live messages still arrive unread.
    pub fn mark_conversations_read(&self, conversation_keys: &[String]) -> Result<()> {
        let conn = self.conn.lock();
        for chunk in conversation_keys.chunks(400) {
            if chunk.is_empty() {
                continue;
            }
            let placeholders = std::iter::repeat("?").take(chunk.len()).collect::<Vec<_>>().join(",");
            let sql = format!("UPDATE conversations SET read = 1 WHERE key IN ({placeholders})");
            let bound: Vec<&dyn rusqlite::ToSql> = chunk.iter().map(|k| k as &dyn rusqlite::ToSql).collect();
            conn.execute(&sql, bound.as_slice())?;
        }
        Ok(())
    }

    /// Update a message's reaction emoji (None clears it), keyed by the Meta
    /// provider message id. No-op if the target message isn't stored locally.
    pub fn set_message_reaction(
        &self,
        account_key: &str,
        provider_message_id: &str,
        emoji: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET reaction = ?1
             WHERE key IN (
               SELECT message_key FROM message_provider_state
               WHERE account_key = ?2 AND provider_message_id = ?3
             )",
            params![emoji, account_key, provider_message_id],
        )?;
        Ok(())
    }

    /// Update a message's delivery state ('delivered'/'read'/'failed:<code>'),
    /// keyed by the Meta provider message id. No-op if not stored locally.
    pub fn set_message_delivery_status(
        &self,
        account_key: &str,
        provider_message_id: &str,
        status: &str,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET delivery_status = ?1
             WHERE key IN (
               SELECT message_key FROM message_provider_state
               WHERE account_key = ?2 AND provider_message_id = ?3
             )",
            params![status, account_key, provider_message_id],
        )?;
        Ok(())
    }

    /// Stamp a resolved contact (Graph User Profile `name` + `profile_pic`) onto
    /// every conversation in this account whose reply target is `recipient_id`,
    /// plus that conversation's message rows still showing the raw id as the
    /// sender. Best-effort display polish — only fills the name when one was
    /// resolved, and only overwrites message senders that are still the raw id.
    pub fn stamp_meta_contact(
        &self,
        account_key: &str,
        recipient_id: &str,
        name: Option<&str>,
        avatar: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        if let Some(name) = name {
            conn.execute(
                "UPDATE conversations SET from_address = ?1
                 WHERE organization_id = ?2 AND cs_recipient_id = ?3",
                params![name, account_key, recipient_id],
            )?;
            conn.execute(
                "UPDATE messages SET from_address = ?1
                 WHERE from_address = ?3
                   AND conversation_key IN (
                     SELECT key FROM conversations
                     WHERE organization_id = ?2 AND cs_recipient_id = ?3
                   )",
                params![name, account_key, recipient_id],
            )?;
        }
        if let Some(avatar) = avatar {
            conn.execute(
                "UPDATE conversations SET from_avatar = ?1
                 WHERE organization_id = ?2 AND cs_recipient_id = ?3",
                params![avatar, account_key, recipient_id],
            )?;
        }
        Ok(())
    }

    /// Record (or refresh) the webhook-relay registration for a Meta account:
    /// the relay's public ids (for teardown) and the report timestamp (for the
    /// monthly lease keep-alive). No Meta secrets are stored.
    pub fn upsert_meta_subscription_state(
        &self,
        account_key: &str,
        rails_keys: &[String],
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let keys_json = serde_json::to_string(rails_keys).unwrap_or_else(|_| "[]".into());
        conn.execute(
            "INSERT INTO meta_subscription_state (account_key, rails_keys, reported_at, updated_at)
             VALUES (?1, ?2, ?3, ?3)
             ON CONFLICT(account_key) DO UPDATE SET
               rails_keys = excluded.rails_keys,
               reported_at = excluded.reported_at,
               updated_at = excluded.updated_at",
            params![account_key, keys_json, now],
        )?;
        Ok(())
    }

    /// `(rails_keys, reported_at)` for a Meta account, if registered.
    pub fn get_meta_subscription_state(
        &self,
        account_key: &str,
    ) -> Result<Option<(Vec<String>, String)>> {
        let conn = self.conn.lock();
        let row: Option<(Option<String>, String)> = conn
            .query_row(
                "SELECT rails_keys, reported_at FROM meta_subscription_state WHERE account_key = ?1",
                params![account_key],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row.map(|(keys, reported)| {
            let parsed = keys
                .and_then(|k| serde_json::from_str::<Vec<String>>(&k).ok())
                .unwrap_or_default();
            (parsed, reported)
        }))
    }

    pub fn delete_meta_subscription_state(&self, account_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM meta_subscription_state WHERE account_key = ?1",
            params![account_key],
        )?;
        Ok(())
    }

    /// The CS-window state for a conversation: `(window_open, expires_at_rfc3339)`.
    /// `window_open` is true when the customer's last inbound message was within
    /// [`CS_WINDOW_HOURS`]. Returns `None` when the conversation has no inbound
    /// anchor (e.g. comment-only, or no customer message yet).
    pub fn meta_window_state(&self, conversation_key: &str) -> Result<Option<(bool, String)>> {
        let conn = self.conn.lock();
        let anchor: Option<String> = conn
            .query_row(
                "SELECT cs_window_last_inbound_at FROM conversations WHERE key = ?1",
                params![conversation_key],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        let Some(anchor) = anchor else { return Ok(None) };
        let parsed = chrono::DateTime::parse_from_rfc3339(&anchor)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|e| SyncError::Parse(format!("cs window anchor: {e}")))?;
        let expires = parsed + chrono::Duration::hours(CS_WINDOW_HOURS);
        let open = expires > Utc::now();
        Ok(Some((open, expires.to_rfc3339())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::meta_normalize::normalize;
    use serde_json::json;

    fn seed_account(store: &SyncStore) -> (String, String) {
        let account = ExternalAccount {
            key: String::new(),
            display_name: "WA".into(),
            email_address: "wa:PNID".into(),
            provider_type: ProviderType::WhatsApp,
            host: None,
            port: None,
            use_tls: false,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: false,
            auth_method: "oauth2".into(),
            status: AccountStatus::Connected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };
        let key = store.create_account(&account).unwrap();
        let folder = format!("{key}::inbox");
        // The engine persists the synthetic Inbox folder via list_folders before
        // sync; mirror that here so the provider-state FK is satisfied.
        store
            .upsert_folder(&UnifiedFolder {
                key: folder.clone(),
                account_key: key.clone(),
                provider_name: "Inbox".into(),
                role: Some(WellKnownFolder::Inbox),
                separator: None,
                flags: vec![],
                uid_validity: None,
                highest_mod_seq: 0,
                last_synced_uid: 0,
                sync_cursor: None,
                sync_enabled: true,
            })
            .unwrap();
        (key, folder)
    }

    #[test]
    fn whatsapp_message_threads_stamps_channel_and_opens_window() {
        let store = SyncStore::new_in_memory().unwrap();
        let (acct, folder) = seed_account(&store);

        let p = json!({
            "object":"whatsapp_business_account",
            "entry":[{"id":"WABA","changes":[{"field":"messages","value":{
                "contacts":[{"profile":{"name":"Sam"},"wa_id":"15551234567"}],
                "messages":[{"from":"15551234567","id":"wamid.1","timestamp":"1700000000","type":"text","text":{"body":"hi"}}]
            }}]}]
        });
        let events = normalize(&p);
        let up = store
            .apply_meta_event(&acct, &folder, &events[0])
            .unwrap()
            .expect("message upsert");
        assert!(up.was_new);

        // Re-applying the same event dedups (Meta retries) — no new message.
        let up2 = store.apply_meta_event(&acct, &folder, &events[0]).unwrap().unwrap();
        assert!(!up2.was_new);
        assert_eq!(up.conversation_key, up2.conversation_key);

        // Channel + window stamped.
        let conn = store.conn.lock();
        let (chan, recipient, anchor): (Option<String>, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT channel, cs_recipient_id, cs_window_last_inbound_at FROM conversations WHERE key = ?1",
                params![up.conversation_key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(chan.as_deref(), Some("whatsapp"));
        assert_eq!(recipient.as_deref(), Some("15551234567"));
        assert!(anchor.is_some());
        drop(conn);

        // Window opened at the message time (2023-11-14) — 24h later it's closed
        // relative to "now", so this historical message reports closed.
        let (open, _expires) = store.meta_window_state(&up.conversation_key).unwrap().unwrap();
        assert!(!open, "a 2023 message's 24h window is long expired");
    }

    #[test]
    fn window_open_for_recent_inbound() {
        let store = SyncStore::new_in_memory().unwrap();
        let (acct, folder) = seed_account(&store);
        let now = Utc::now().timestamp();
        let p = json!({
            "object":"whatsapp_business_account",
            "entry":[{"id":"WABA","changes":[{"field":"messages","value":{
                "messages":[{"from":"1555","id":"wamid.recent","timestamp": now.to_string(),"type":"text","text":{"body":"now"}}]
            }}]}]
        });
        let events = normalize(&p);
        let up = store.apply_meta_event(&acct, &folder, &events[0]).unwrap().unwrap();
        let (open, _) = store.meta_window_state(&up.conversation_key).unwrap().unwrap();
        assert!(open, "a message sent now is inside the 24h window");
    }
}

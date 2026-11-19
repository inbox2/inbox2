use chrono::{Duration, Utc};
use std::sync::Arc;

use crate::sync::error::{Result, SyncError};
use crate::sync::interactive::OutgoingMessage;
use crate::sync::model::*;
use crate::sync::store::SyncStore;

/// Durable outbox for user-composed provider sends (Gmail/Microsoft Graph).
///
/// Unlike the [`crate::sync::actions::WritebackQueue`], which references an
/// already-synced message by key, the outbox persists the full composed
/// payload so a send survives an app restart and is retried with exponential
/// backoff on transient failure (offline, 429, 5xx) instead of being lost.
pub struct OutboxQueue {
    store: Arc<SyncStore>,
}

/// Attempts before a send is permanently failed. Lower than the write-back
/// queue's budget because a send is not idempotent. The backoff curve itself is
/// shared with the write-back queue (see [`crate::sync::retry`]).
const MAX_RETRIES: u32 = 3;

impl OutboxQueue {
    pub fn new(store: Arc<SyncStore>) -> Self {
        Self { store }
    }

    /// Persist a new send. Returns the stored entry (status `Pending`) so the
    /// caller can attempt immediate delivery.
    pub fn enqueue(&self, account_key: &str, message: OutgoingMessage) -> Result<OutboxMessage> {
        let entry = OutboxMessage {
            key: format!("obx_{}", nanoid::nanoid!(21)),
            account_key: account_key.to_string(),
            kind: OutboxKind::Send,
            draft_key: None,
            message,
            status: OutboxStatus::Pending,
            retry_count: 0,
            max_retries: MAX_RETRIES,
            next_retry_at: None,
            provider_message_id: None,
            error_message: None,
        };
        self.store.enqueue_outbox(&entry)?;
        Ok(entry)
    }

    /// Queue the latest version of a draft (see
    /// [`SyncStore::enqueue_draft_version`]). Returns the entry as stored: the
    /// key is the existing pending row's when this version replaced it.
    pub fn enqueue_draft(&self, account_key: &str, draft_key: &str, message: OutgoingMessage) -> Result<OutboxMessage> {
        let mut entry = OutboxMessage {
            key: format!("obx_{}", nanoid::nanoid!(21)),
            account_key: account_key.to_string(),
            kind: OutboxKind::Draft,
            draft_key: Some(draft_key.to_string()),
            message,
            status: OutboxStatus::Pending,
            retry_count: 0,
            // A draft save is idempotent (it replaces the draft), so it can
            // afford the write-back queue's patience rather than a send's.
            max_retries: 10,
            next_retry_at: None,
            provider_message_id: None,
            error_message: None,
        };
        entry.key = self.store.enqueue_draft_version(&entry)?;
        Ok(entry)
    }

    /// Pending sends for an account whose backoff window has elapsed.
    pub fn pending(&self, account_key: &str) -> Result<Vec<OutboxMessage>> {
        self.store.get_pending_outbox(account_key)
    }

    /// Atomically claim an entry for delivery. Only the winner should send;
    /// this is what stops the immediate attempt and the drain loop from both
    /// firing the same (non-idempotent) message.
    pub fn claim(&self, key: &str) -> Result<bool> {
        self.store.claim_outbox_for_send(key)
    }

    /// All outbox entries for an account (any status), newest first — for the UI.
    pub fn list(&self, account_key: &str) -> Result<Vec<OutboxMessage>> {
        self.store.list_outbox(account_key)
    }

    /// Mark a send as accepted by the provider.
    pub fn mark_sent(&self, key: &str, provider_message_id: &str) -> Result<()> {
        self.store.update_outbox_status(
            key,
            &OutboxStatus::Sent,
            0,
            None,
            Some(provider_message_id),
            None,
        )
    }

    /// Record a failed attempt: schedule a backoff retry, or give up
    /// permanently (`Failed`) once `max_retries` is reached.
    pub fn mark_failed(&self, entry: &OutboxMessage, error: &SyncError) -> Result<bool> {
        let new_retry_count = entry.retry_count + 1;
        if new_retry_count >= entry.max_retries {
            self.store.update_outbox_status(
                &entry.key,
                &OutboxStatus::Failed,
                new_retry_count,
                None,
                None,
                Some(&error.to_string()),
            )?;
            Ok(true) // permanently failed
        } else {
            let backoff_secs = crate::sync::retry::next_backoff_secs(new_retry_count);
            let next_retry = Utc::now() + Duration::seconds(backoff_secs);
            self.store.update_outbox_status(
                &entry.key,
                &OutboxStatus::Pending,
                new_retry_count,
                Some(&next_retry.to_rfc3339()),
                None,
                Some(&error.to_string()),
            )?;
            Ok(false)
        }
    }

    /// Give up immediately, no retry — for failures that can't succeed on a
    /// retry (e.g. a 4xx like a bad recipient). Keeps the error for the UI.
    pub fn fail_permanently(&self, entry: &OutboxMessage, error: &SyncError) -> Result<()> {
        self.store.update_outbox_status(
            &entry.key,
            &OutboxStatus::Failed,
            entry.retry_count + 1,
            None,
            None,
            Some(&error.to_string()),
        )
    }

    /// Re-queue a permanently-failed send for another round of attempts.
    pub fn retry(&self, key: &str) -> Result<()> {
        self.store
            .update_outbox_status(key, &OutboxStatus::Pending, 0, None, None, None)
    }

    /// Drop delivered sends to keep the table from growing unbounded.
    pub fn cleanup_sent(&self) -> Result<u64> {
        self.store.delete_sent_outbox()
    }

    /// Cancel a queued/failed send by removing its entry. Returns whether it existed.
    pub fn delete(&self, key: &str) -> Result<bool> {
        self.store.delete_outbox(key)
    }
}

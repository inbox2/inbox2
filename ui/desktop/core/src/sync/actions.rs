use chrono::{Duration, Utc};
use std::sync::Arc;

use crate::sync::error::{Result, SyncError};
use crate::sync::model::*;
use crate::sync::store::SyncStore;

/// Manages the write-back action queue with exponential backoff retry.
///
/// Actions are queued when the user modifies a synced message locally
/// (mark read, flag, archive, move, etc.) and applied asynchronously
/// to the provider. The provider is the source of truth on conflict.
pub struct WritebackQueue {
    store: Arc<SyncStore>,
}

/// Attempts before a write-back action is permanently failed. Write-backs are
/// idempotent flag/label flips, so they tolerate a longer retry budget than the
/// outbox (whose sends are not idempotent).
const MAX_RETRIES: u32 = 10;

impl WritebackQueue {
    pub fn new(store: Arc<SyncStore>) -> Self {
        Self { store }
    }

    /// Queue a new write-back action.
    pub fn enqueue(
        &self,
        account_key: &str,
        action_type: ActionType,
        message_key: &str,
        folder_key: Option<&str>,
        provider_snapshot: Option<crate::sync::model::ProviderMessageId>,
    ) -> Result<String> {
        let key = format!("wba_{}", nanoid::nanoid!(21));
        let action = WritebackAction {
            key: key.clone(),
            account_key: account_key.to_string(),
            action_type,
            message_key: message_key.to_string(),
            folder_key: folder_key.map(String::from),
            provider_snapshot,
            status: ActionStatus::Pending,
            retry_count: 0,
            max_retries: MAX_RETRIES,
            next_retry_at: None,
            error_message: None,
        };
        self.store.enqueue_action(&action)?;
        Ok(key)
    }

    /// Get all pending actions for an account that are ready to process.
    pub fn pending_actions(&self, account_key: &str) -> Result<Vec<WritebackAction>> {
        self.store.get_pending_actions(account_key)
    }

    /// Count of actions still awaiting the provider (pending/in-progress) across all
    /// accounts — used by the drain loop for "queue ran / had work" observability.
    pub fn total_pending(&self) -> Result<usize> {
        self.store.pending_action_count()
    }

    /// Mark an action as completed (successfully applied to provider).
    pub fn mark_completed(&self, action_key: &str) -> Result<()> {
        self.store.update_action_status(
            action_key,
            &ActionStatus::Completed,
            0,
            None,
            None,
        )
    }

    /// Mark an action as failed with exponential backoff for retry.
    ///
    /// If `retry_count >= max_retries`, the action is permanently failed.
    /// Otherwise, it's scheduled for retry after an exponential delay.
    pub fn mark_failed(
        &self,
        action: &WritebackAction,
        error: &SyncError,
    ) -> Result<()> {
        let new_retry_count = action.retry_count + 1;

        if new_retry_count >= action.max_retries {
            // Permanently failed
            self.store.update_action_status(
                &action.key,
                &ActionStatus::Failed,
                new_retry_count,
                None,
                Some(&error.to_string()),
            )
        } else {
            // Schedule retry with exponential backoff
            let backoff_secs = crate::sync::retry::next_backoff_secs(new_retry_count);
            let next_retry = Utc::now() + Duration::seconds(backoff_secs);
            self.store.update_action_status(
                &action.key,
                &ActionStatus::Pending,
                new_retry_count,
                Some(&next_retry.to_rfc3339()),
                Some(&error.to_string()),
            )
        }
    }

    /// Permanently fail an action without consuming the retry schedule — used when
    /// the error is known non-retryable (a 4xx) or the credentials are dead
    /// (401/403), so the drain gives up immediately instead of burning the whole
    /// backoff before reaching `max_retries`.
    pub fn fail_permanently(&self, action: &WritebackAction, error: &SyncError) -> Result<()> {
        self.store.update_action_status(
            &action.key,
            &ActionStatus::Failed,
            action.retry_count + 1,
            None,
            Some(&error.to_string()),
        )
    }

    /// Handle a write conflict: the provider state changed during our write.
    /// The provider wins — discard our action and accept the server state.
    pub fn handle_conflict(&self, action_key: &str) -> Result<()> {
        self.store.update_action_status(
            action_key,
            &ActionStatus::Completed, // Treat as completed — server wins
            0,
            None,
            Some("conflict: server state accepted"),
        )
    }

    /// Clean up completed actions to prevent table bloat.
    pub fn cleanup_completed(&self) -> Result<u64> {
        self.store.delete_completed_actions()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // writeback_actions.account_key is FK'd to external_accounts, so the row
    // needs a real account. Returns the store, queue, and the account key.
    fn store_and_queue() -> (Arc<SyncStore>, WritebackQueue, String) {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let account_key = store
            .create_account(&ExternalAccount {
                key: String::new(),
                display_name: "T".into(),
                email_address: "t@example.com".into(),
                provider_type: ProviderType::Imap,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: AuthMethod::OAuth2.as_str().into(),
                status: AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap();
        let queue = WritebackQueue::new(store.clone());
        (store, queue, account_key)
    }

    #[test]
    fn fail_permanently_drops_action_from_the_pending_queue() {
        let (store, queue, acct) = store_and_queue();
        let key = queue
            .enqueue(&acct, ActionType::Archive, "msg_1", None, None)
            .unwrap();

        // Freshly enqueued → visible as pending.
        let pending = store.get_pending_actions(&acct).unwrap();
        assert_eq!(pending.len(), 1);
        let action = pending.into_iter().next().unwrap();
        assert_eq!(action.key, key);

        // A known-permanent (4xx) failure must drop it immediately — not leave it
        // to consume the retry budget the way mark_failed would.
        queue
            .fail_permanently(
                &action,
                &SyncError::HttpStatus { code: 400, context: "bad label id".into() },
            )
            .unwrap();

        assert!(
            store.get_pending_actions(&acct).unwrap().is_empty(),
            "permanently-failed action must not remain pending"
        );
    }

    #[test]
    fn mark_failed_reschedules_with_backoff_instead_of_dropping() {
        let (store, queue, acct) = store_and_queue();
        queue
            .enqueue(&acct, ActionType::Flag, "msg_2", None, None)
            .unwrap();
        let action = store
            .get_pending_actions(&acct)
            .unwrap()
            .into_iter()
            .next()
            .unwrap();

        // A transient failure (well below max_retries) reschedules: the row stays
        // in the queue (status Pending, next_retry_at in the future) rather than
        // being dropped — the contrast with fail_permanently above.
        queue.mark_failed(&action, &SyncError::Http("503".into())).unwrap();
        assert_eq!(queue.total_pending().unwrap(), 1);
        // ...but it's back-off-scheduled, so not *immediately* due.
        assert!(store.get_pending_actions(&acct).unwrap().is_empty());
    }
}

use async_trait::async_trait;
use tokio::sync::mpsc;

use crate::sync::error::Result;
use crate::sync::model::*;

/// The provider adapter interface.
///
/// Every provider (IMAP, Gmail, Microsoft) implements this trait.
/// The sync engine is provider-agnostic and interacts only through this interface.
///
/// # Design for future adapters
///
/// **Gmail (separate task):** Uses Gmail API + Cloud Pub/Sub push with historyId
/// deltas and X-GM-LABELS for the label model — NOT IMAP. Gmail's label model
/// (a message has many labels; no folders) maps onto the unified model's tag set.
/// `list_folders` returns labels as folders with `role = Other(label_name)`.
/// `start_watching` registers a Pub/Sub watch; `incremental_sync` calls
/// `history.list(startHistoryId)`. The `labels` capability is true.
///
/// **Microsoft (separate task):** Uses Microsoft Graph change-notification
/// subscriptions + delta queries. Folders + categories map to unified folders +
/// tags. `start_watching` creates a subscription; `incremental_sync` uses the
/// delta link from the previous sync. Requires an Entra app registration.
#[async_trait]
pub trait ProviderAdapter: Send {
    /// Connect to the provider, authenticate, and report capabilities.
    ///
    /// - IMAP: establish TLS connection, LOGIN or XOAUTH2, read CAPABILITY.
    /// - Gmail: validate OAuth token, check API scopes.
    /// - Microsoft: validate token, discover mailbox capabilities.
    async fn connect(&mut self, credentials: &ProviderCredentials) -> Result<ProviderCapabilities>;

    /// Disconnect cleanly, releasing all connections and resources.
    async fn disconnect(&mut self) -> Result<()>;

    /// Current capabilities (from last successful connect).
    fn capabilities(&self) -> &ProviderCapabilities;

    /// List all folders/labels, mapped to unified well-known roles.
    ///
    /// - IMAP: LIST + SPECIAL-USE attributes.
    /// - Gmail: labels.list(), map system labels to well-known roles.
    /// - Microsoft: mailFolders, map well-known folder names.
    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>>;

    /// Initial sync of a folder: fetch messages, flags, and provider IDs.
    ///
    /// Called once per folder on first sync. Returns `has_more = true` when
    /// batching; caller should call again with `from_uid` advanced.
    ///
    /// - IMAP: SELECT + UID FETCH from_uid:* (FLAGS BODY.PEEK[HEADER] MODSEQ).
    /// - Gmail: messages.list() + messages.get() with historyId.
    /// - Microsoft: messages delta query with $select.
    async fn initial_sync(
        &mut self,
        folder: &UnifiedFolder,
        batch_size: u32,
        continuation: Continuation,
    ) -> Result<FolderSyncResult>;

    /// Start push subscription: watch folders for changes, emit events.
    ///
    /// Runs until `stop_watching()` is called or the connection drops.
    /// On connection loss, emits `ProviderEvent::Disconnected`.
    ///
    /// - IMAP: NOTIFY (one connection, all folders) if supported; else one
    ///   IDLE connection per folder. IDLE re-issued every ~9 minutes.
    /// - Gmail: watch() + Pub/Sub subscription on the user's mailbox.
    /// - Microsoft: create change-notification subscription, poll webhook.
    async fn start_watching(
        &mut self,
        folders: &[UnifiedFolder],
        credentials: &ProviderCredentials,
        tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()>;

    /// Stop watching all folders. Idempotent.
    async fn stop_watching(&mut self) -> Result<()>;

    /// Create a cloud push subscription that delivers change notifications to our
    /// Rails backend (Gmail Pub/Sub `users.watch` → topic; Microsoft Graph
    /// `/subscriptions` → notificationUrl). Uses the adapter's own OAuth token; the
    /// token is never sent to Rails. Default: unsupported (IMAP uses IDLE instead).
    /// See docs/Cloud-Push.md.
    async fn create_push_subscription(&mut self, _config: &PushSubConfig) -> Result<PushSubInfo> {
        Err(crate::sync::error::SyncError::UnsupportedCapability(
            "cloud push".into(),
        ))
    }

    /// Renew an existing cloud push subscription before it lapses.
    async fn renew_push_subscription(
        &mut self,
        config: &PushSubConfig,
        _existing: &PushSubInfo,
    ) -> Result<PushSubInfo> {
        // Default: re-create (Gmail's watch is renew-by-recall).
        self.create_push_subscription(config).await
    }

    /// Tear down a cloud push subscription (on disconnect / toggle-off).
    async fn delete_push_subscription(&mut self, _existing: &PushSubInfo) -> Result<()> {
        Ok(())
    }

    /// Incremental resync from a stored cursor after reconnect or push event.
    ///
    /// On UIDVALIDITY change, returns `SyncError::UidValidityChanged`; the
    /// engine must then invalidate cached UIDs and re-run `initial_sync`.
    ///
    /// - IMAP: SELECT + UID FETCH 1:* FLAGS (CHANGEDSINCE cursor.highest_mod_seq);
    ///   compare UID set to detect expunges.
    /// - Gmail: history.list(startHistoryId=cursor.highest_mod_seq).
    /// - Microsoft: delta query with the stored deltaLink.
    async fn incremental_sync(
        &mut self,
        folder: &UnifiedFolder,
        cursor: &SyncCursor,
    ) -> Result<FolderSyncResult>;

    /// Apply a write-back action to the remote provider.
    ///
    /// Uses conditional writes where supported (CONDSTORE UNCHANGEDSINCE for IMAP).
    /// Returns `SyncError::WriteConflict` if the server state changed; the engine
    /// should then re-read and accept the server's version.
    ///
    /// - IMAP: UID STORE (UNCHANGEDSINCE) / UID MOVE / UID COPY+EXPUNGE.
    /// - Gmail: messages.modify() with addLabelIds / removeLabelIds.
    /// - Microsoft: PATCH message properties, POST move.
    async fn apply_action(
        &mut self,
        action: &WritebackAction,
        provider_state: &ProviderMessageId,
    ) -> Result<()>;

    /// Map provider-native flags/labels to unified flags.
    fn normalize_flags(&self, provider_flags: &ProviderFlags) -> UnifiedFlags;

    /// Map unified flags back to provider-native representation.
    fn denormalize_flags(&self, unified: &UnifiedFlags, folder: Option<&str>) -> ProviderFlags;
}

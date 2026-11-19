//! The connect-and-sync flow: full account sync bracketed by lifecycle
//! events, per-folder initial/incremental sync, and the page-size ramp.

use super::*;

pub(super) const DEFAULT_BATCH_SIZE: u32 = 200;
/// Per-page sizes for the first few pages of an initial folder sync. Small
/// early pages surface the newest messages quickly (each batch refreshes the
/// UI); later pages fall back to `DEFAULT_BATCH_SIZE` for throughput.
const INITIAL_PAGE_RAMP: &[u32] = &[25, 25, 50];

/// Page size for the `page`-th batch (0-based) of an initial folder sync.
pub(super) fn initial_page_size(page: usize) -> u32 {
    INITIAL_PAGE_RAMP
        .get(page)
        .copied()
        .unwrap_or(DEFAULT_BATCH_SIZE)
}

/// Order enabled folders so the inbox syncs first (the view the user is most
/// likely watching), keeping the remaining folders in their existing order.
pub(super) fn order_inbox_first(folders: &mut [UnifiedFolder]) {
    folders.sort_by_key(|f| if f.role == Some(WellKnownFolder::Inbox) { 0 } else { 1 });
}

impl SyncEngine {

    /// Connect + sync an account, bracketed by the sync-lifecycle events
    /// (started → … → completed/failed) so the UI has one coherent signal.
    pub async fn connect_and_sync(&self, account_key: &str) -> Result<()> {
        self.ensure_account_registered(account_key).await?;

        // Coalesce duplicate triggers. Boot, the frontend's resync, setup's
        // start_sync, and reconnects can all fire for the same account; a
        // second concurrent full sync re-pages every folder from the start,
        // duplicating batches (the jumbled, non-monotonic progress in the log).
        // The guard releases the slot on drop, so a cancelled sync can't strand
        // the account in `syncing` (and latch the UI's "Syncing…" indicator).
        let mut guard = match self.begin_sync_guard(account_key, true) {
            Some(g) => g,
            None => {
                log::info!("[sync] {account_key}: already syncing — skipping duplicate trigger");
                return Ok(());
            }
        };

        self.update_status(account_key, AccountStatus::Connecting, None)
            .await?;
        self.sync_event(account_key, SyncPhase::Started, serde_json::json!({}));
        log::info!("[sync] {account_key}: started");
        let started = std::time::Instant::now();

        let result = self.connect_and_sync_inner(account_key).await;

        // Normal completion: emit the precise terminal event ourselves, then
        // disarm so the guard's Drop only releases the slot (no duplicate event).
        guard.disarm();
        let secs = started.elapsed().as_secs();
        match &result {
            Ok(summary) => {
                log::info!(
                    "[sync] {account_key}: complete — {} folder(s), {} message(s) in {secs}s",
                    summary.folders,
                    summary.messages
                );
                self.sync_event(
                    account_key,
                    SyncPhase::Completed,
                    serde_json::json!({
                        "folders": summary.folders,
                        "messages": summary.messages,
                        "elapsedSecs": secs,
                    }),
                );
                // New mail landed — wake the host's local-rules worker now rather
                // than letting it wait out its poll interval. This is the
                // push → resync → rules link (and a latency win for normal polls).
                // The triage worker is woken the same way so freshly-synced
                // conversations get classified/summarized promptly.
                if summary.messages > 0 {
                    self.rules_scan.notify_one();
                    self.ai_scan.notify_one();
                }
                // First connect of a Meta account: provision its webhook relay
                // (subscribe app webhooks + register asset routing). Idempotent
                // and only on first registration — the poll loop's
                // renew_meta_push_due handles the ongoing 30-day lease.
                if let Ok(Some(account)) = self.store().get_account(account_key) {
                    if account.provider_type.is_meta()
                        && matches!(self.store().get_meta_subscription_state(account_key), Ok(None))
                    {
                        if let Err(e) = self.register_meta_push(account_key).await {
                            log::warn!("[meta] {account_key}: initial relay registration failed: {e}");
                        }
                    }
                }
            }
            Err(e) => {
                // Persist a terminal status so clients (which read `status` /
                // `error_message` from the store) can show *why* the account
                // stopped syncing. An auth failure means the stored tokens are
                // dead → `NeedsReauth` (sticky, prompts re-auth); anything else is
                // treated as transient `Error` that the next successful sync
                // clears back to `Connected`. (The connect phase sets its own
                // status; this catches failures during folder sync — the common
                // path for an expired token that couldn't refresh.)
                let status = Self::status_for_error(&e);
                if status == AccountStatus::NeedsReauth {
                    log::warn!(
                        "[sync] {account_key}: FAILED after {secs}s — {e}; flagging NeedsReauth (user must re-authenticate)"
                    );
                } else {
                    log::warn!("[sync] {account_key}: FAILED after {secs}s — {e}");
                }
                let _ = self
                    .update_status(account_key, status, Some(&e.to_string()))
                    .await;
                self.sync_event(
                    account_key,
                    SyncPhase::Failed,
                    serde_json::json!({ "error": e.to_string() }),
                );
            }
        }
        result.map(|_| ())
    }

    async fn connect_and_sync_inner(&self, account_key: &str) -> Result<SyncSummary> {
        // Get credentials
        let credentials = {
            let accounts = self.accounts.lock().await;
            let state = accounts
                .get(account_key)
                .ok_or_else(|| SyncError::Other("account not found".into()))?;
            state.credentials.clone()
        };

        // Connect. Hold only the per-account adapter lock across the network
        // round-trip, never the accounts map.
        let adapter = self
            .adapter_handle(account_key)
            .await
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        let connect_result = adapter.lock().await.connect(&credentials).await;

        let capabilities = match connect_result {
            Ok(caps) => {
                {
                    let mut accounts = self.accounts.lock().await;
                    if let Some(state) = accounts.get_mut(account_key) {
                        state.reconnect_backoff_secs = INITIAL_RECONNECT_SECS;
                    }
                }
                // Through update_status (not a bare store write) so the
                // `status` event fires: every sync emits `connecting` at its
                // start, and a UI tracking those events live would otherwise
                // latch on "connecting" forever — recovery must be heard too.
                self.update_status(account_key, AccountStatus::Connected, None)
                    .await?;
                caps
            }
            Err(e) => {
                let status = Self::status_for_error(&e);
                if status == AccountStatus::NeedsReauth {
                    log::warn!(
                        "Connect failed for {account_key}: {e}; flagging NeedsReauth (user must re-authenticate)"
                    );
                } else {
                    log::warn!("Connect failed for {account_key}: {e}");
                }
                self.update_status(account_key, status, Some(&e.to_string()))
                    .await?;
                return Err(e);
            }
        };

        log::info!(
            "[sync] {account_key}: connected (push={}, incremental={}, condstore={})",
            capabilities.push,
            capabilities.incremental_sync,
            capabilities.conditional_store
        );

        // List folders (reuse the per-account adapter handle from connect).
        let folders = adapter.lock().await.list_folders().await?;

        let default_sync_roles = [
            WellKnownFolder::Inbox,
            WellKnownFolder::Sent,
            WellKnownFolder::Drafts,
            WellKnownFolder::Archive,
            WellKnownFolder::Spam,
            WellKnownFolder::Trash,
        ];

        // The IMAP adapter mints a fresh `fld_` key per listing, so a re-list on
        // reconnect inserted a second row for every folder (five "Inbox" rows after
        // five failed connects, 2026-11-07). Reuse the stored key for the same
        // provider name; the upsert then updates in place and keeps the cursor. A
        // store that already holds duplicates keeps using the one that synced.
        let existing = self.store.get_folders_for_account(account_key)?;
        let mut folders = folders;
        for folder in &mut folders {
            if let Some(prev) = existing
                .iter()
                .filter(|f| f.provider_name == folder.provider_name)
                .max_by_key(|f| f.last_synced_uid)
            {
                folder.key = prev.key.clone();
            }
            folder.account_key = account_key.to_string();
            folder.sync_enabled = folder
                .role
                .as_ref()
                .map(|r| default_sync_roles.contains(r))
                .unwrap_or(false);
        }

        // Persist folders
        for folder in &folders {
            self.store.upsert_folder(folder)?;
        }

        {
            let mut accounts = self.accounts.lock().await;
            if let Some(state) = accounts.get_mut(account_key) {
                state.folders = folders.clone();
            }
        }

        // Sync the inbox first so the view the user is most likely watching
        // populates fastest; remaining folders keep their listed order. The
        // sync-lifecycle events (started/completed/failed) are emitted by the
        // connect_and_sync wrapper; per-folder events come from sync_folder.
        let mut sync_folders: Vec<_> = folders.iter().filter(|f| f.sync_enabled).cloned().collect();
        order_inbox_first(&mut sync_folders);
        log::info!(
            "[sync] {account_key}: {} folder(s) listed, {} enabled — syncing {}",
            folders.len(),
            sync_folders.len(),
            sync_folders
                .iter()
                .map(|f| f.provider_name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );

        let mut summary = SyncSummary::default();
        let total_folders = sync_folders.len();
        for (i, folder) in sync_folders.iter().enumerate() {
            summary.messages += self
                .sync_folder(account_key, folder, i + 1, total_folders)
                .await?;
            summary.folders += 1;
        }
        // Sync calendars (Gmail/Microsoft only; no-op for IMAP).
        self.sync_calendars(account_key).await;

        // Start IDLE watchers for IMAP accounts with push support.
        if capabilities.push {
            let _ = adapter
                .lock()
                .await
                .start_watching(&sync_folders, &credentials, self.event_tx.clone())
                .await;
        }

        Ok(summary)
    }

    /// Sync one folder. Returns the number of messages synced/changed (for the
    /// account-level summary). `folder_index`/`total_folders` (1-based) position
    /// this folder in the run so the UI can show deterministic progress.
    pub(super) async fn sync_folder(
        &self,
        account_key: &str,
        folder: &UnifiedFolder,
        folder_index: usize,
        total_folders: usize,
    ) -> Result<usize> {
        self.sync_event(
            account_key,
            SyncPhase::FolderStarted,
            serde_json::json!({
                "folderKey": folder.key,
                "folderName": folder.provider_name,
                "folderIndex": folder_index,
                "totalFolders": total_folders,
            }),
        );
        let stored_folders = self.store.get_folders_for_account(account_key)?;
        let stored = stored_folders.iter().find(|f| f.key == folder.key);

        let has_cursor = stored
            .map(|f| f.sync_cursor.is_some() || (f.uid_validity.is_some() && f.last_synced_uid > 0))
            .unwrap_or(false);

        if has_cursor {
            let s = stored.unwrap();
            let cursor = SyncCursor {
                uid_validity: s.uid_validity.unwrap_or(0),
                highest_mod_seq: s.highest_mod_seq,
                last_synced_uid: s.last_synced_uid,
                token: s.sync_cursor.clone(),
            };
            self.incremental_sync_folder(account_key, folder, &cursor, folder_index, total_folders)
                .await
        } else {
            self.initial_sync_folder(account_key, folder, folder_index, total_folders)
                .await
        }
    }

    async fn initial_sync_folder(
        &self,
        account_key: &str,
        folder: &UnifiedFolder,
        folder_index: usize,
        total_folders: usize,
    ) -> Result<usize> {
        log::info!(
            "[sync] {account_key}/{}: initial sync starting",
            folder.provider_name
        );

        let mut continuation: Continuation = None;
        let mut last_uid: u32 = 0;
        let mut total_messages = 0;
        let mut seen: HashSet<String> = HashSet::new();
        let mut have_seen_set = false;
        let mut page = 0usize;
        // Provider's folder-size estimate (first batch), the progress denominator.
        let mut folder_total: Option<u32> = None;

        loop {
            // Ramp the page size: small first pages get the newest messages on
            // screen fast (each batch emits folder-progress → the UI refreshes),
            // then settle into the larger size for throughput.
            let batch_size = initial_page_size(page);
            page += 1;
            let result = {
                let adapter = self
                    .adapter_handle(account_key)
                    .await
                    .ok_or(SyncError::NotConnected)?;
                let mut guard = adapter.lock().await;
                guard
                    .initial_sync(folder, batch_size, continuation.clone())
                    .await?
            };

            let mut batch_convs: HashSet<String> = HashSet::new();
            for (msg, provider_id) in &result.messages {
                let up = self
                    .store
                    .upsert_synced_message(account_key, &folder.key, msg, provider_id)?;
                batch_convs.insert(up.conversation_key);
                if let Some(uid) = provider_id.uid {
                    last_uid = last_uid.max(uid);
                }
            }
            total_messages += result.messages.len();
            if folder_total.is_none() {
                folder_total = result.total_estimate;
            }

            // folder-progress per batch: the list fills progressively as the
            // import streams (the frontend coalesces these), and the folder +
            // conversation keys let subscribers refresh only what changed.
            let added = result.messages.len();
            if added > 0 {
                log::info!(
                    "[sync] {account_key}/{}: batch {page} +{added} ({total_messages}{} total)",
                    folder.provider_name,
                    folder_total.map(|t| format!("/~{t}")).unwrap_or_default()
                );
                self.sync_event(
                    account_key,
                    SyncPhase::FolderProgress,
                    serde_json::json!({
                        "folderKey": folder.key,
                        "folderName": folder.provider_name,
                        "folderIndex": folder_index,
                        "totalFolders": total_folders,
                        "batch": page,
                        "added": added,
                        "synced": total_messages,
                        "folderTotal": folder_total,
                        "conversationKeys": batch_convs,
                    }),
                );
            }

            if let Some(ref s) = result.seen_provider_ids {
                have_seen_set = true;
                seen.extend(s.iter().cloned());
            }

            // Persist the opaque provider cursor only once the folder is fully
            // drained — the historyId/deltaLink is valid only after a complete
            // sync, so an interrupted batch must not advance it.
            let token = if result.has_more {
                None
            } else {
                result.next_token.as_deref()
            };
            self.store.update_folder_sync_state(
                &folder.key,
                result.uid_validity,
                result.new_highest_mod_seq,
                last_uid,
                token,
            )?;

            continuation = result.continuation;
            if !result.has_more {
                break;
            }
        }

        // Full-sync deletion detection: prune locally-known messages the provider
        // no longer lists (providers that detect deletions incrementally — IMAP —
        // return no seen-set and are skipped here).
        if have_seen_set {
            match self
                .store
                .prune_unseen_provider_ids(account_key, &folder.key, &seen)
            {
                Ok(removed) if removed > 0 => log::info!(
                    "Pruned {removed} orphaned message(s) from {}",
                    folder.provider_name
                ),
                Ok(_) => {}
                Err(e) => log::warn!("Orphan prune failed for {}: {e}", folder.provider_name),
            }
        }

        log::info!(
            "[sync] {account_key}/{}: initial sync complete — {total_messages} message(s) in {page} batch(es)",
            folder.provider_name
        );
        self.sync_event(
            account_key,
            SyncPhase::FolderComplete,
            serde_json::json!({
                "folderKey": folder.key,
                "folderName": folder.provider_name,
                "folderIndex": folder_index,
                "totalFolders": total_folders,
                "synced": total_messages,
                "folderTotal": folder_total,
                "batches": page,
            }),
        );
        Ok(total_messages)
    }

    async fn incremental_sync_folder(
        &self,
        account_key: &str,
        folder: &UnifiedFolder,
        cursor: &SyncCursor,
        folder_index: usize,
        total_folders: usize,
    ) -> Result<usize> {
        log::info!(
            "[sync] {account_key}/{}: incremental sync starting (modseq={})",
            folder.provider_name,
            cursor.highest_mod_seq
        );

        let result = {
            let adapter = self
                .adapter_handle(account_key)
                .await
                .ok_or(SyncError::NotConnected)?;
            let mut guard = adapter.lock().await;
            guard.incremental_sync(folder, cursor).await
        };

        let result = match result {
            Ok(r) => r,
            Err(SyncError::UidValidityChanged {
                folder: fname,
                expected,
                actual,
            }) => {
                log::warn!(
                    "UIDVALIDITY changed for {fname}: {expected} -> {actual}; re-syncing"
                );
                self.store
                    .invalidate_folder_uids(account_key, &folder.key)?;
                return self
                    .initial_sync_folder(account_key, folder, folder_index, total_folders)
                    .await;
            }
            Err(SyncError::CursorExpired) => {
                log::warn!(
                    "Sync cursor expired for {}; full resync",
                    folder.provider_name
                );
                self.store
                    .invalidate_folder_uids(account_key, &folder.key)?;
                return self
                    .initial_sync_folder(account_key, folder, folder_index, total_folders)
                    .await;
            }
            Err(e) => return Err(e),
        };

        // Spam and Trash folders never raise notifications — a notification
        // whose conversation is filtered out of the inbox list is confusing
        // (the user clicks it, the message opens, but the list looks empty).
        // Sent and Drafts are excluded too: messages the user authored are not
        // arriving mail. (Adapters hardcode is_inbound = true, so the folder
        // role is the only reliable signal that a message is outbound.)
        //
        // Archive is excluded as well. Gmail's synthetic "All Mail" carries every
        // message in the mailbox, so genuinely-new inbound mail already alerts via
        // INBOX — an All Mail copy is only ever a duplicate of that alert, or a
        // message re-surfaced by a label change we caused (e.g. mark-unread bumps
        // the UNREAD label, and the All Mail re-walk then re-emits the thread as
        // "new"). For IMAP/Microsoft, Archive is where the user files read mail,
        // never where arriving mail lands. Either way, Archive isn't new mail.
        let folder_notifiable = !matches!(
            folder.role,
            Some(WellKnownFolder::Spam)
                | Some(WellKnownFolder::Trash)
                | Some(WellKnownFolder::Sent)
                | Some(WellKnownFolder::Drafts)
                | Some(WellKnownFolder::Archive)
        );

        // Account email backs the self-authored notification guard below. Resolved
        // lazily (get_account takes the shared SQLite lock) — most syncs find no
        // new inbound mail, so the common path must not pay for it on every folder.
        let mut account_email: Option<String> = None;

        let mut new_message_ids: Vec<String> = Vec::new();
        let mut changed_convs: HashSet<String> = HashSet::new();
        for (msg, provider_id) in &result.messages {
            let up =
                self.store
                    .upsert_synced_message(account_key, &folder.key, msg, provider_id)?;
            changed_convs.insert(up.conversation_key);
            // Skip spam/trash-flagged messages too (Gmail tags via labels rather
            // than a dedicated folder, so the folder role alone isn't enough).
            // Drafts are skipped by flag as well as folder role: an autosaved
            // reply (Outlook) can carry isDraft=true while filed in a notifiable
            // folder, and an unsent draft is never arriving mail.
            // Only alert for *unread* arriving mail. A newly-synced message can
            // already be read — read on another device before this sync, or
            // surfaced by a historical backfill walk — and an already-read
            // message is never a notification.
            if up.was_new && msg.is_inbound && !msg.flags.read && !msg.flags.spam && !msg.flags.trashed && !msg.flags.draft {
                // Adapters hardcode is_inbound = true, so the folder role is the
                // only signal that a message is outbound — but a sent copy can
                // still surface in a *notifiable* folder (Gmail All Mail / a thread
                // label, IMAP servers that file the reply back into INBOX). The
                // provider-agnostic guard: never alert for mail the account owner
                // sent themselves. Log every decision with the cause fields so
                // misfires stay diagnosable from deployment-site logs.
                let email = account_email.get_or_insert_with(|| {
                    self.store
                        .get_account(account_key)
                        .ok()
                        .flatten()
                        .map(|a| a.email_address)
                        .unwrap_or_default()
                });
                let from_is_self = !email.is_empty()
                    && msg.from_address.to_ascii_lowercase().contains(&email.to_ascii_lowercase());
                if !folder_notifiable {
                    log::debug!(
                        target: "notify",
                        "[notify] {account_key}: skip new-inbound msg in non-notifiable folder='{}' role={:?} from='{}'",
                        folder.provider_name, folder.role, msg.from_address,
                    );
                } else if from_is_self {
                    // Sender is us → a sent item misclassified as inbound. Suppress
                    // the alert (the message is still synced/recorded normally).
                    log::info!(
                        target: "notify",
                        "[notify] {account_key}: SUPPRESS self-authored alert — from='{}' matches account email in folder='{}' role={:?} subject={:?}",
                        msg.from_address, folder.provider_name, folder.role, msg.subject,
                    );
                } else {
                    log::info!(
                        target: "notify",
                        "[notify] {account_key}: ALERT folder='{}' role={:?} from='{}' draft={} subject={:?}",
                        folder.provider_name, folder.role, msg.from_address, msg.flags.draft, msg.subject,
                    );
                    if let Some(pid) = &provider_id.provider_id {
                        new_message_ids.push(pid.clone());
                    }
                }
            }
        }

        // Handle deletions (IMAP EXPUNGE by UID; Gmail messagesDeleted / Microsoft
        // @removed by provider id) — cascade to message + conversation.
        for pid in &result.deletions {
            self.store
                .cascade_delete_message(account_key, &folder.key, pid)?;
        }

        // Notify the frontend of genuinely-new inbound messages. account_email is
        // Some here — a non-empty new_message_ids means the guard above resolved it.
        if !new_message_ids.is_empty() {
            let email = account_email.unwrap_or_default();
            log::info!(
                target: "notify",
                "[notify] {account_key}: emitting {} new-message alert(s) from folder='{}' role={:?}",
                new_message_ids.len(),
                folder.provider_name,
                folder.role,
            );
            for pid in &new_message_ids {
                if let Ok(Some(mut notif)) = self.store.message_notification(account_key, pid) {
                    notif.email = email.clone();
                    self.emit(event::NEW_MESSAGE, notif);
                }
            }
        }
        let changed_count = result.messages.len() + result.deletions.len();

        let new_last_uid = result
            .messages
            .iter()
            .filter_map(|(_, pid)| pid.uid)
            .max()
            .unwrap_or(cursor.last_synced_uid);

        self.store.update_folder_sync_state(
            &folder.key,
            result.uid_validity,
            result.new_highest_mod_seq.max(cursor.highest_mod_seq),
            new_last_uid,
            result.next_token.as_deref(),
        )?;

        log::info!(
            "[sync] {account_key}/{}: incremental sync complete — {} new/updated, {} deleted, {} flag update(s)",
            folder.provider_name,
            result.messages.len(),
            result.deletions.len(),
            result.flag_updates.len()
        );
        self.sync_event(
            account_key,
            SyncPhase::FolderComplete,
            serde_json::json!({
                "folderKey": folder.key,
                "folderName": folder.provider_name,
                "folderIndex": folder_index,
                "totalFolders": total_folders,
                "synced": changed_count,
                "added": result.messages.len(),
                "deleted": result.deletions.len(),
                "conversationKeys": changed_convs,
            }),
        );
        Ok(changed_count)
    }

}

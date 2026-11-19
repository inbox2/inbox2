//! The engine run loop: provider events, periodic polling, and shutdown,
//! plus the account-status bookkeeping they share.

use super::*;

impl SyncEngine {
    // -----------------------------------------------------------------------
    // Event loop
    // -----------------------------------------------------------------------

    pub async fn run(&self) -> Result<()> {
        let mut event_rx = self
            .event_rx
            .lock()
            .await
            .take()
            .ok_or_else(|| SyncError::Other("event loop already running".into()))?;

        let shutdown = self.shutdown.clone();
        let mut poll_interval = tokio::time::interval(Duration::from_secs(60));
        poll_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // Skip the first (immediate) tick — initial sync already ran on connect
        poll_interval.tick().await;

        log::info!("[engine] sync run loop started (60s poll, 5s write-back drain + WAL checkpoint)");
        loop {
            tokio::select! {
                event = event_rx.recv() => {
                    match event {
                        Some(event) => self.handle_event(event).await,
                        None => break,
                    }
                }
                _ = shutdown.notified() => {
                    log::info!("[engine] sync run loop received shutdown signal");
                    break;
                }
                _ = tokio::time::sleep(Duration::from_secs(5)) => {
                    let account_keys: Vec<String> = {
                        self.accounts.lock().await.keys().cloned().collect()
                    };
                    // Surface the live account set + total queued work once per drain so a
                    // "queue never ran" report is distinguishable from "ran, nothing to do"
                    // or "account not loaded". Only when there's actually pending work, to
                    // keep the idle 5s tick quiet.
                    let pending_total = self.writeback.total_pending().unwrap_or(0);
                    if pending_total > 0 {
                        log::info!(
                            "[writeback] drain tick: {} pending across {} loaded account(s): [{}]",
                            pending_total,
                            account_keys.len(),
                            account_keys.join(", ")
                        );
                    }
                    for key in &account_keys {
                        match self.process_writeback(key).await {
                            Ok(n) if n > 0 => {
                                log::info!("[writeback] {key}: {n} action(s) settled this drain")
                            }
                            Ok(_) => {}
                            Err(e) => log::warn!("[writeback] {key}: drain error: {e}"),
                        }
                        if let Err(e) = self.process_outbox(key).await {
                            log::warn!("Outbox processing error for {key}: {e}");
                        }
                    }
                    let _ = self.writeback.cleanup_completed();
                    let _ = self.outbox.cleanup_sent();
                    // Mirror any dirty (created / refreshed) credentials to the cloud
                    // vault. No-op when backup is off or the vault is locked.
                    self.drain_backup_dirty().await;
                    // Reclaim the WAL frequently and non-blockingly (PASSIVE), so the
                    // UI's read connection never scans a large WAL and is never
                    // stalled by a checkpoint's exclusive lock.
                    // Queued MX conversation actions (docs/MX-Sync.md) — same 5s beat
                    // as the channel write-back above.
                    self.mx_drain().await;
                    self.mx_outbox_drain().await;
                    if let Err(e) = self.store.checkpoint_wal() {
                        log::warn!("[engine] WAL checkpoint failed: {e}");
                    }
                }
                _ = poll_interval.tick() => {
                    self.poll_all_accounts().await;
                    // The MX mirror's failsafe beat; hints and foregrounding drive
                    // it between ticks (docs/MX-Sync.md).
                    self.mx_tick().await;
                    // Renew any cloud-push subscriptions nearing expiry (idempotent).
                    self.renew_push_due().await;
                    // Keep Meta webhook-relay registrations (30-day lease) alive.
                    self.renew_meta_push_due().await;
                    // Provision CF TLS for any per-channel custom tracking hosts, then
                    // pull open-tracking opens for tracked local sends (docs/Open-Tracking.md).
                    self.ensure_custom_hosts_registered().await;
                    self.poll_tracking_opens().await;
                }
            }
        }

        log::info!("[engine] sync run loop stopped");
        Ok(())
    }

    /// Periodic incremental sync for all connected accounts.
    /// Acts as a fallback when IDLE events are missed or unavailable.
    ///
    /// Two cohorts, by status:
    /// - `Connected` → cheap incremental poll (the IDLE fallback below).
    /// - `Error` → a transient failure (network blip, provider 5xx, a Gmail
    ///   per-user quota throttle). The account is otherwise healthy, so attempt
    ///   a full reconnect to recover it within the session instead of stranding
    ///   it until the next app boot. `NeedsReauth` is deliberately excluded —
    ///   that's a dead credential the user must fix; auto-retrying it is futile
    ///   and would silently re-prompt forever. `Disconnected`/`Connecting` are
    ///   skipped too (paused, or already in flight).
    async fn poll_all_accounts(&self) {
        let (connected, errored): (Vec<String>, Vec<String>) = {
            let accounts = self.accounts.lock().await;
            (
                accounts
                    .iter()
                    .filter(|(_, s)| s.status == AccountStatus::Connected)
                    .map(|(k, _)| k.clone())
                    .collect(),
                accounts
                    .iter()
                    .filter(|(_, s)| s.status == AccountStatus::Error)
                    .map(|(k, _)| k.clone())
                    .collect(),
            )
        };

        // Recover transiently-failed accounts first. `connect_and_sync` claims
        // its own sync guard (and skips if one is already in flight), so it must
        // NOT be called while holding one.
        for account_key in &errored {
            // Gmail's 429 names a lockout deadline; retrying before it extends
            // the lockout. Sit it out.
            let deadline = self
                .store
                .get_account(account_key)
                .ok()
                .flatten()
                .and_then(|a| a.error_message)
                .and_then(|m| crate::sync::error::retry_after_deadline(&m));
            if deadline.is_some_and(|d| chrono::Utc::now() < d) {
                log::debug!("[sync] {account_key}: errored, waiting out provider lockout");
                continue;
            }
            log::info!("[sync] {account_key}: poll retry of errored account (full reconnect)");
            if let Err(e) = self.connect_and_sync(account_key).await {
                log::warn!("[sync] {account_key}: poll reconnect failed: {e}");
            }
        }

        for account_key in &connected {
            // Don't race a full sync (boot/setup/reconnect) or another poll —
            // claim the slot first, skip the account if one is already running.
            // The guard releases the slot on every exit path (`continue`, normal
            // end, or cancellation), so a dropped poll future can't strand it.
            let _guard = match self.begin_sync_guard(account_key, false) {
                Some(g) => g,
                None => {
                    log::debug!("[sync] {account_key}: poll skipped (sync in progress)");
                    continue;
                }
            };

            let folders = match self.store.get_folders_for_account(account_key) {
                Ok(f) => f,
                Err(e) => {
                    log::warn!("[sync] {account_key}: poll failed to list folders: {e}");
                    continue;
                }
            };

            let enabled: Vec<_> = folders.iter().filter(|f| f.sync_enabled).collect();
            let total = enabled.len();
            let mut dead_credential = false;
            for (i, folder) in enabled.iter().enumerate() {
                if let Err(e) = self.sync_folder(account_key, folder, i + 1, total).await {
                    log::warn!(
                        "[sync] {account_key}/{}: poll sync failed: {e}",
                        folder.provider_name
                    );
                    // A revoked/expired refresh token fails identically on every
                    // folder and every tick. Persist it so the UI can prompt for
                    // re-auth — otherwise the account keeps reading as `connected`
                    // while silently receiving no mail, and nothing surfaces it.
                    if e.is_auth() {
                        dead_credential = true;
                        break;
                    }
                }
            }
            if dead_credential {
                let _ = self
                    .update_status(
                        account_key,
                        AccountStatus::NeedsReauth,
                        Some("Sign-in expired — reconnect this account"),
                    )
                    .await;
                continue;
            }

            // Calendars on the same poll tick.
            self.sync_calendars(account_key).await;
        }
    }

    async fn handle_event(&self, event: ProviderEvent) {
        match event {
            ProviderEvent::NewMessages {
                account_key,
                folder_key,
            }
            | ProviderEvent::FlagsChanged {
                account_key,
                folder_key,
            } => {
                log::debug!("Push event for {account_key}/{folder_key}");
                let folders = match self.store.get_folders_for_account(&account_key) {
                    Ok(f) => f,
                    Err(e) => {
                        log::warn!("Failed to get folders for {account_key}: {e}");
                        return;
                    }
                };
                if let Some(folder) = folders.iter().find(|f| f.key == folder_key) {
                    // Serialize against an in-flight sync/poll — a running sync
                    // already covers the new messages, so coalesce the push. The
                    // guard releases the slot on drop (incl. cancellation).
                    let _guard = match self.begin_sync_guard(&account_key, false) {
                        Some(g) => g,
                        None => {
                            log::debug!("[sync] {account_key}: push for {folder_key} coalesced into running sync");
                            return;
                        }
                    };
                    // Push targets a single folder, so it's "1 of 1" for progress.
                    if let Err(e) = self.sync_folder(&account_key, folder, 1, 1).await {
                        log::warn!(
                            "[sync] {account_key}/{folder_key}: sync after push failed: {e}"
                        );
                    }
                }
            }
            ProviderEvent::MessagesExpunged {
                account_key,
                folder_key,
                uids,
            } => {
                for uid in &uids {
                    let _ = self
                        .store
                        .delete_provider_state_for_uid(&account_key, &folder_key, *uid);
                }
            }
            ProviderEvent::Disconnected {
                account_key,
                error,
            } => {
                log::warn!(
                    "Account {account_key} disconnected: {}",
                    error.as_deref().unwrap_or("unknown")
                );
                let _ = self
                    .update_status(&account_key, AccountStatus::Error, error.as_deref())
                    .await;

                let backoff = {
                    let mut accounts = self.accounts.lock().await;
                    if let Some(state) = accounts.get_mut(&account_key) {
                        let b = state.reconnect_backoff_secs;
                        state.reconnect_backoff_secs = (b * 2).min(MAX_RECONNECT_SECS);
                        b
                    } else {
                        return;
                    }
                };

                let event_tx = self.event_tx.clone();
                let account_key_owned = account_key.clone();
                let handle = tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    log::info!(
                        "Scheduling reconnect for {account_key_owned} after {backoff}s"
                    );
                    let _ = event_tx.send(ProviderEvent::Reconnected {
                        account_key: account_key_owned,
                    });
                });
                // Track the sleeper and abort any prior one, so a flapping account
                // doesn't accumulate a backoff task per disconnect.
                if let Some(state) = self.accounts.lock().await.get_mut(&account_key) {
                    if let Some(old) = state.reconnect_task.replace(handle) {
                        old.abort();
                    }
                }
            }
            ProviderEvent::Reconnected { account_key } => {
                log::info!("Reconnect signal for {account_key}");
                if let Err(e) = self.connect_and_sync(&account_key).await {
                    log::warn!("Reconnect failed for {account_key}: {e}");
                }
            }
        }
    }

    pub async fn shutdown(&self) {
        log::info!("[shutdown] sync engine: stopping run loop + disconnecting adapters");
        self.shutdown.notify_one();
        // Collect adapter handles under a brief map lock, then disconnect each
        // without holding the map.
        let adapters: Vec<AdapterHandle> = {
            let accounts = self.accounts.lock().await;
            accounts.values().map(|s| s.adapter.clone()).collect()
        };
        let total = adapters.len();
        let mut disconnected = 0usize;
        let mut busy = 0usize;
        for adapter in adapters {
            // `try_lock`, not `lock`: a sync mid-batch holds this adapter lock
            // across its network I/O. Waiting for it would hang shutdown for the
            // length of a fetch (and block the UI, since exit runs this on the
            // main thread). A graceful disconnect is best-effort cleanup — if
            // the adapter is busy we skip it; the OS closes the socket on exit.
            match adapter.try_lock() {
                Ok(mut guard) => {
                    // Bound even the idle disconnect, so a half-dead connection
                    // can't stall exit.
                    let _ =
                        tokio::time::timeout(Duration::from_secs(2), guard.disconnect()).await;
                    disconnected += 1;
                }
                Err(_) => busy += 1,
            }
        }
        log::info!(
            "[shutdown] sync engine stopped ({disconnected}/{total} adapter(s) disconnected, \
             {busy} mid-sync left to the OS)"
        );
    }

    /// Map a sync failure to the account status to persist: an auth failure
    /// (dead/revoked tokens) is sticky `NeedsReauth` so the UI prompts for
    /// re-auth; everything else is transient `Error` that the next successful
    /// sync clears back to `Connected`.
    pub(super) fn status_for_error(e: &SyncError) -> AccountStatus {
        if e.is_auth() {
            AccountStatus::NeedsReauth
        } else {
            AccountStatus::Error
        }
    }

    pub(super) async fn update_status(
        &self,
        account_key: &str,
        status: AccountStatus,
        error: Option<&str>,
    ) -> Result<()> {
        {
            let mut accounts = self.accounts.lock().await;
            if let Some(state) = accounts.get_mut(account_key) {
                state.status = status.clone();
            }
        }
        self.emit(
            event::STATUS,
            serde_json::json!({
                "accountKey": account_key,
                "status": status.as_str(),
                "error": error,
            }),
        );
        self.store
            .update_account_status(account_key, &status, error)
    }
}

//! The write-back and outbox queues: draining pending provider actions and
//! durable sends, with per-entry retry/backoff.

use super::*;

impl SyncEngine {
    // -----------------------------------------------------------------------
    // Write-back processing
    // -----------------------------------------------------------------------

    pub async fn process_writeback(&self, account_key: &str) -> Result<usize> {
        let actions = self.writeback.pending_actions(account_key)?;
        if !actions.is_empty() {
            log::info!(
                "[writeback] {account_key}: draining {} pending action(s)",
                actions.len()
            );
        }
        let mut processed = 0;

        // Built lazily on the first Interactive action and reused for the rest of
        // the batch — all actions here share one account, so rebuilding a
        // TokenManager + reqwest::Client (and re-querying account/credentials)
        // per action was pure waste.
        let mut interactive: Option<Box<dyn crate::sync::interactive::InteractiveProvider>> = None;

        for action in &actions {
            let provider_info = self
                .store
                .get_provider_state_by_message(&action.message_key, account_key)?;

            let snapshot_has_id = |s: &crate::sync::model::ProviderMessageId| {
                s.provider_id.is_some() || s.uid.is_some()
            };
            let (_folder_key, provider_id) = match provider_info {
                Some(info) => info,
                // Live provider-state row is gone (e.g. pruned by a racing sync). Fall
                // back to the identity captured at enqueue time so the action still
                // reaches the server — no silent loss.
                None => match action.provider_snapshot.clone() {
                    Some(snap) if snapshot_has_id(&snap) => {
                        log::info!(
                            "[writeback] {account_key}: action {} — live provider-state gone, using enqueue-time snapshot (provider_id={})",
                            action.key,
                            snap.provider_id.as_deref().unwrap_or("<none>")
                        );
                        (action.folder_key.clone().unwrap_or_default(), snap)
                    }
                    // No live row AND no usable snapshot: do NOT mark completed (that's a
                    // silent drop). Fail it so it retries / surfaces in the queue.
                    _ => {
                        let err = SyncError::Other(format!(
                            "no provider-id for msg {} (no live provider-state and no enqueue snapshot)",
                            action.message_key
                        ));
                        log::warn!(
                            "[writeback] {account_key}: action {} ({}) — {err}; NOT marking sent, will retry/surface",
                            action.key,
                            action.action_type.as_str()
                        );
                        self.writeback.mark_failed(action, &err)?;
                        continue;
                    }
                },
            };

            log::info!(
                "[writeback] {account_key}: applying {} to msg {} (action {}, provider_id={}, retry {})",
                action.action_type.as_str(),
                action.message_key,
                action.key,
                provider_id.provider_id.as_deref().unwrap_or("<none>"),
                action.retry_count
            );

            let result = if let ActionType::Interactive { verb } = &action.action_type {
                // Apply via the provider's verb path (label/category logic for
                // spam/quadrant). interactive_provider builds from the store, so
                // no accounts lock is needed/held across the await.
                match provider_id.provider_id.clone() {
                    Some(pid) => {
                        let provider = match &interactive {
                            Some(p) => Ok(&**p),
                            None => self
                                .interactive_provider(account_key)
                                .map(|p| &**interactive.insert(p)),
                        };
                        match provider {
                            Ok(p) => p.perform_action(&[pid], verb).await,
                            Err(e) => Err(e),
                        }
                    }
                    None => {
                        // Provider-state row exists but carries no server id — same
                        // silent-drop hazard as above. Surface it as a failure (retry/
                        // visible) rather than reporting a phantom success.
                        Err(SyncError::Other(format!(
                            "no provider message id for msg {} (action {verb}) — cannot apply to provider",
                            action.message_key
                        )))
                    }
                }
            } else {
                match self.adapter_handle(account_key).await {
                    Some(adapter) => adapter.lock().await.apply_action(action, &provider_id).await,
                    None => {
                        log::warn!(
                            "[writeback] {account_key}: action {} ({}) — adapter NOT connected; will retry next drain",
                            action.key,
                            action.action_type.as_str()
                        );
                        Err(SyncError::NotConnected)
                    }
                }
            };

            match result {
                Ok(()) => {
                    log::info!(
                        "[writeback] {account_key}: action {} ({}) applied OK",
                        action.key,
                        action.action_type.as_str()
                    );
                    self.writeback.mark_completed(&action.key)?;
                    processed += 1;
                }
                Err(SyncError::WriteConflict) => {
                    log::info!(
                        "[writeback] {account_key}: write conflict for action {} — accepting server state",
                        action.key
                    );
                    self.writeback.handle_conflict(&action.key)?;
                    processed += 1;
                }
                Err(e) if e.is_auth() => {
                    // Dead credentials — don't retry, and flag the account so the
                    // UI prompts for re-auth (mirrors the sync/connect path).
                    log::warn!(
                        "[writeback] {account_key}: action {} ({}) auth-failed: {e}; flagging NeedsReauth, giving up",
                        action.key,
                        action.action_type.as_str()
                    );
                    let _ = self.writeback.fail_permanently(action, &e);
                    let _ = self
                        .update_status(
                            account_key,
                            crate::sync::model::AccountStatus::NeedsReauth,
                            Some(&e.to_string()),
                        )
                        .await;
                    processed += 1;
                }
                Err(e) if e.is_permanent() => {
                    // A 4xx (bad label id, deleted move-target, malformed request)
                    // can't succeed on retry — fail it now instead of burning the
                    // whole backoff schedule.
                    log::warn!(
                        "[writeback] {account_key}: action {} ({}) permanently failed: {e}; giving up",
                        action.key,
                        action.action_type.as_str()
                    );
                    let _ = self.writeback.fail_permanently(action, &e);
                    processed += 1;
                }
                Err(e) => {
                    log::warn!(
                        "[writeback] {account_key}: action {} ({}) FAILED (retry {} of {}): {e}",
                        action.key,
                        action.action_type.as_str(),
                        action.retry_count,
                        action.max_retries
                    );
                    self.writeback.mark_failed(action, &e)?;
                }
            }
        }

        Ok(processed)
    }

    // -----------------------------------------------------------------------
    // Outbox (durable provider sends)
    // -----------------------------------------------------------------------

    /// Resolve a reply's threading context from the store: when the composer
    /// set `reply_to_message_key`, fill `in_reply_to` (the parent's Message-ID),
    /// `references` (the parent's chain + its Message-ID, per RFC 5322 §3.6.4)
    /// and `provider_thread_id` (the parent conversation's Gmail `threadId`).
    /// Hydrated BEFORE the outbox persists the payload, so retries are
    /// self-contained. Caller-set values win — only missing fields are filled.
    pub(crate) fn hydrate_reply_context(&self, message: &mut OutgoingMessage) {
        let Some(parent_key) = message.reply_to_message_key.clone() else { return };
        let ctx = match self.store.reply_context(&parent_key) {
            Ok(Some(ctx)) => ctx,
            Ok(None) => {
                log::warn!("[outbox] reply parent {parent_key} not found; sending unthreaded");
                return;
            }
            Err(e) => {
                log::warn!("[outbox] reply context lookup failed for {parent_key}: {e}");
                return;
            }
        };
        let (parent_mid, parent_refs, thread_id) = ctx;
        let parent_mid = parent_mid.filter(|s| !s.is_empty());
        if message.in_reply_to.is_none() {
            message.in_reply_to = parent_mid.clone();
        }
        if message.references.is_none() {
            // The new message's References = parent's References ⧺ parent's
            // Message-ID (an empty parent chain degrades to just the ID).
            let chain = [parent_refs.unwrap_or_default(), parent_mid.unwrap_or_default()]
                .iter()
                .filter(|s| !s.is_empty())
                .cloned()
                .collect::<Vec<_>>()
                .join(" ");
            message.references = Some(chain).filter(|s| !s.is_empty());
        }
        if message.provider_thread_id.is_none() {
            message.provider_thread_id = thread_id.filter(|s| !s.is_empty());
        }
    }

    /// Persist a composed message to the outbox and attempt immediate delivery.
    /// Never throws on a delivery failure — the send is durably queued and the
    /// returned status tells the caller whether it went out (`Sent`) or is
    /// waiting to retry (`Pending`/`Failed`). Only a storage error propagates.
    pub async fn enqueue_send(
        &self,
        account_key: &str,
        mut message: OutgoingMessage,
    ) -> Result<OutboxSendResult> {
        self.hydrate_reply_context(&mut message);
        // Plain-only senders (iOS/Android/CLI composers) would otherwise go out
        // as a text/plain singlepart — build the HTML alternative from the plain
        // body here, once, instead of in every client. Before the tracking pixel:
        // injection needs an HTML part to land in.
        if message.body_html.as_deref().unwrap_or_default().is_empty() {
            if let Some(plain) = message.body_plain.as_deref().filter(|p| !p.trim().is_empty()) {
                message.body_html = Some(crate::sync::util::plain_to_html(plain));
            }
        }
        // Mint the Message-ID here (not per delivery attempt) so it is stable
        // across retries and matches the copy we store locally. Domain comes
        // from the sender so the header isn't a deliverability red flag on the
        // providers that keep it (IMAP/SMTP; Gmail and Graph rewrite it).
        if message.message_id.as_deref().unwrap_or_default().is_empty() {
            message.message_id = Some(format!("<{}@{}>", nanoid::nanoid!(24), message_id_domain(&message.from_address)));
        }
        // Open tracking (docs/Open-Tracking.md): one injection point covers Gmail/
        // Office365/IMAP — the pixel is in the persisted outbox payload, so it
        // survives retries and lands in the synced sent copy too.
        self.maybe_inject_tracking_pixel(account_key, &mut message).await;
        let entry = self.outbox.enqueue(account_key, message)?;
        self.emit(
            event::OUTBOX_CHANGED,
            serde_json::json!({ "accountKey": account_key, "key": entry.key, "status": OutboxStatus::Pending.as_str() }),
        );
        // Claim before attempting so a concurrent drain-loop pass can't also
        // send this entry. If we lose the claim, it's already in flight.
        if !self.outbox.claim(&entry.key).unwrap_or(false) {
            return Ok(OutboxSendResult {
                outbox_key: entry.key,
                status: OutboxStatus::Pending,
                provider_message_id: None,
                error_message: None,
            });
        }
        match self.interactive_provider(account_key) {
            Ok(provider) => Ok(self.deliver_outbox_entry(account_key, &*provider, &entry).await),
            Err(e) => {
                // Couldn't build the provider for an immediate attempt; back it
                // off (which also releases the claim) and let the loop retry.
                let permanent = self.outbox.mark_failed(&entry, &e).unwrap_or(false);
                Ok(OutboxSendResult {
                    outbox_key: entry.key,
                    status: if permanent {
                        OutboxStatus::Failed
                    } else {
                        OutboxStatus::Pending
                    },
                    provider_message_id: None,
                    error_message: Some(e.to_string()),
                })
            }
        }
    }

    /// Queue a version of the draft `draft_key` for the account's Drafts, with
    /// the reply threading and HTML alternative a send gets, and try it now.
    /// Durable like a send; unlike one, only the latest version is kept: a newer
    /// save overwrites a version still waiting, and each delivered version
    /// replaces the previous draft at the provider (`draft_refs`).
    pub async fn enqueue_draft(
        &self,
        account_key: &str,
        draft_key: &str,
        mut message: OutgoingMessage,
    ) -> Result<OutboxSendResult> {
        self.hydrate_reply_context(&mut message);
        if message.body_html.as_deref().unwrap_or_default().is_empty() {
            if let Some(plain) = message.body_plain.as_deref().filter(|p| !p.trim().is_empty()) {
                message.body_html = Some(crate::sync::util::plain_to_html(plain));
            }
        }
        // The same Message-ID on every version: IMAP finds the previous copy by it.
        message.message_id = Some(format!("<{draft_key}@{}>", message_id_domain(&message.from_address)));
        let queued = self.outbox.enqueue_draft(account_key, draft_key, message)?;
        let claimed = self.outbox.claim(&queued.key).unwrap_or(false);
        // Re-read after the claim: a concurrent save may have replaced the payload.
        let entry = match (claimed, self.store.get_outbox(&queued.key)?) {
            (true, Some(entry)) => entry,
            _ => queued,
        };
        if !claimed {
            // An older version is in flight; the drain loop delivers this one next.
            return Ok(OutboxSendResult {
                outbox_key: entry.key,
                status: OutboxStatus::Pending,
                provider_message_id: None,
                error_message: None,
            });
        }
        match self.interactive_provider(account_key) {
            Ok(provider) => Ok(self.deliver_outbox_entry(account_key, &*provider, &entry).await),
            Err(e) => {
                let permanent = self.outbox.mark_failed(&entry, &e).unwrap_or(false);
                Ok(OutboxSendResult {
                    outbox_key: entry.key,
                    status: if permanent { OutboxStatus::Failed } else { OutboxStatus::Pending },
                    provider_message_id: None,
                    error_message: Some(e.to_string()),
                })
            }
        }
    }

    /// Deliver pending outbox entries for an account whose backoff has elapsed.
    /// Returns the number successfully sent this pass.
    pub async fn process_outbox(&self, account_key: &str) -> Result<usize> {
        let entries = self.outbox.pending(account_key)?;
        if entries.is_empty() {
            return Ok(0);
        }
        // One provider for the whole batch (same account) — avoids rebuilding a
        // TokenManager + client per message, like process_writeback.
        let provider = match self.interactive_provider(account_key) {
            Ok(p) => p,
            Err(e) => {
                log::warn!("Outbox: cannot build provider for {account_key}: {e}");
                return Ok(0); // retry on the next tick
            }
        };
        let mut sent = 0;
        for entry in &entries {
            // Claim each entry so an immediate enqueue_send attempt (or a manual
            // retry) racing this pass can't double-send it.
            if !self.outbox.claim(&entry.key).unwrap_or(false) {
                continue;
            }
            // Deliver what the row holds now: a newer draft version may have
            // overwritten it between the listing and the claim.
            let Ok(Some(entry)) = self.store.get_outbox(&entry.key) else { continue };
            let res = self.deliver_outbox_entry(account_key, &*provider, &entry).await;
            if matches!(res.status, OutboxStatus::Sent) {
                sent += 1;
            }
        }
        Ok(sent)
    }

    /// Attempt a single send via an already-built provider, update the row
    /// (sent, or failed-with-backoff), emit a change event, and report status.
    async fn deliver_outbox_entry(
        &self,
        account_key: &str,
        provider: &dyn crate::sync::interactive::InteractiveProvider,
        entry: &OutboxMessage,
    ) -> OutboxSendResult {
        let draft_key = entry.draft_key.as_deref().filter(|_| entry.kind == OutboxKind::Draft);
        let attempt = match draft_key {
            Some(dk) => {
                let existing = self.store.draft_ref(dk).ok().flatten();
                provider.save_draft(&entry.message, existing.as_deref()).await
            }
            None => provider.send_message(&entry.message).await,
        };
        match attempt {
            Ok(provider_message_id) => {
                match draft_key {
                    Some(dk) => {
                        // A crash before this commit loses the id, not the draft:
                        // save_draft also finds it by its stable Message-ID.
                        let _ = self.store.complete_draft(&entry.key, dk, account_key, &provider_message_id);
                    }
                    None => {
                        let _ = self.outbox.mark_sent(&entry.key, &provider_message_id);
                        let _ = self.record_sent_copy(account_key, &entry.message, &provider_message_id);
                    }
                }
                self.emit(
                    event::OUTBOX_CHANGED,
                    serde_json::json!({
                        "accountKey": account_key,
                        "key": entry.key,
                        "status": OutboxStatus::Sent.as_str(),
                    }),
                );
                OutboxSendResult {
                    outbox_key: entry.key.clone(),
                    status: OutboxStatus::Sent,
                    provider_message_id: Some(provider_message_id),
                    error_message: None,
                }
            }
            Err(e) if draft_key.is_some() => {
                // Drafts requeue atomically against newer versions (see
                // requeue_draft_version); a superseded one is dropped.
                let retry_count = entry.retry_count + 1;
                let give_up = e.is_permanent() || retry_count >= entry.max_retries;
                let status = if give_up { OutboxStatus::Failed } else { OutboxStatus::Pending };
                let next = (!give_up).then(|| {
                    (chrono::Utc::now() + chrono::Duration::seconds(crate::sync::retry::next_backoff_secs(retry_count)))
                        .to_rfc3339()
                });
                let kept = self
                    .store
                    .requeue_draft_version(&entry.key, &status, retry_count, next.as_deref(), &e.to_string())
                    .unwrap_or(true);
                log::warn!("Outbox draft {} failed{}: {e}", entry.key, if kept { "" } else { " (superseded, dropped)" });
                OutboxSendResult {
                    outbox_key: entry.key.clone(),
                    status: if kept { status } else { OutboxStatus::Deleted },
                    provider_message_id: None,
                    error_message: Some(e.to_string()),
                }
            }
            Err(e) => {
                // A 4xx (bad recipient, forbidden) can't succeed on retry —
                // fail it now instead of burning the backoff schedule.
                let permanent = if e.is_permanent() {
                    let _ = self.outbox.fail_permanently(entry, &e);
                    true
                } else {
                    self.outbox.mark_failed(entry, &e).unwrap_or(false)
                };
                let status = if permanent {
                    OutboxStatus::Failed
                } else {
                    OutboxStatus::Pending
                };
                log::warn!(
                    "Outbox send {} failed (attempt {}/{}{}): {e}",
                    entry.key,
                    entry.retry_count + 1,
                    entry.max_retries,
                    if permanent { ", giving up" } else { "" },
                );
                self.emit(
                    event::OUTBOX_CHANGED,
                    serde_json::json!({
                        "accountKey": account_key,
                        "key": entry.key,
                        "status": status.as_str(),
                        "error": e.to_string(),
                    }),
                );
                OutboxSendResult {
                    outbox_key: entry.key.clone(),
                    status,
                    provider_message_id: None,
                    error_message: Some(e.to_string()),
                }
            }
        }
    }

    /// Write the just-sent message into the local store so it shows up in the
    /// thread immediately, instead of only once the Sent folder next syncs
    /// (minutes later). The provider's own copy adopts this row when it arrives
    /// — matched on the provider id we just got back, our Message-ID, or, for
    /// providers that return neither, the un-synced-placeholder heuristic in
    /// `SyncStore::upsert_synced_message` — so the thread never shows both.
    ///
    /// Best-effort: a failure here only costs the instant echo, never the send.
    /// Returns the upsert (`None` when nothing was stored) for the tests.
    pub(crate) fn record_sent_copy(
        &self,
        account_key: &str,
        msg: &OutgoingMessage,
        provider_message_id: &str,
    ) -> Option<crate::sync::store::MessageUpsert> {
        let sent_folder = match self.store.get_folders_for_account(account_key) {
            Ok(folders) => folders
                .into_iter()
                .find(|f| matches!(f.role, Some(WellKnownFolder::Sent))),
            Err(e) => {
                log::warn!("[outbox] sent copy: folder lookup failed for {account_key}: {e}");
                return None;
            }
        };
        // No Sent folder means nothing will ever sync a server copy back into
        // this account, so there is also no row for the placeholder to merge
        // with. Skipping keeps the store free of messages no folder owns.
        let folder = sent_folder?;

        let now = chrono::Utc::now();
        let names = msg
            .attachments
            .iter()
            .map(|a| a.filename.as_str())
            .filter(|f| !f.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        let unified = UnifiedMessage {
            key: String::new(), // assigned by the store
            message_id: msg.message_id.clone().unwrap_or_default(),
            subject: msg.subject.clone(),
            from_address: msg.from_address.clone(),
            to_address: Some(msg.to_address.clone()),
            cc_address: msg.cc_address.clone(),
            in_reply_to: msg.in_reply_to.clone(),
            references_header: msg.references.clone(),
            provider_thread_id: msg.provider_thread_id.clone(),
            body_plain: msg.body_plain.clone(),
            body_html: msg.body_html.clone(),
            has_attachment: !msg.attachments.is_empty(),
            attachment_names: Some(names).filter(|n| !n.is_empty()),
            attachment_max_size: msg.attachments.iter().map(|a| a.data.len() as i64).max(),
            is_inbound: false,
            flags: UnifiedFlags { read: true, ..Default::default() },
            labels: HashSet::new(),
            folders: HashSet::new(),
            date: Some(now),
            internal_date: Some(now),
        };
        let provider_id = ProviderMessageId {
            uid: None,
            mod_seq: None,
            provider_id: Some(provider_message_id.to_string()).filter(|s| !s.is_empty()),
        };
        match self
            .store
            .upsert_synced_message(account_key, &folder.key, &unified, &provider_id)
        {
            Ok(up) => {
                // Providers that answer a send with no id (Graph) leave the
                // upsert nothing to key provider state on but our own
                // Message-ID, which is not a provider handle — drop it.
                if provider_id.provider_id.is_none() {
                    let _ = self.store.clear_provider_state(&up.message_key);
                }
                // Same data-change alert the sync path emits, so every client
                // (web, iOS, Android) refreshes the open thread the usual way.
                self.sync_event(
                    account_key,
                    SyncPhase::FolderComplete,
                    serde_json::json!({
                        "folderKey": folder.key,
                        "folderName": folder.provider_name,
                        "synced": 1,
                        "added": 1,
                        "conversationKeys": [up.conversation_key],
                    }),
                );
                Some(up)
            }
            Err(e) => {
                log::warn!("[outbox] sent copy for {account_key} not stored: {e}");
                None
            }
        }
    }

    /// Re-queue a permanently-failed outbox entry and attempt it immediately.
    pub async fn retry_outbox_message(&self, account_key: &str, key: &str) -> Result<()> {
        self.outbox.retry(key)?;
        self.emit(
            event::OUTBOX_CHANGED,
            serde_json::json!({ "accountKey": account_key, "key": key, "status": OutboxStatus::Pending.as_str() }),
        );
        let _ = self.process_outbox(account_key).await;
        Ok(())
    }

    /// Cancel a queued/failed send by deleting its outbox entry.
    pub async fn delete_outbox_message(&self, account_key: &str, key: &str) -> Result<bool> {
        let existed = self.outbox.delete(key)?;
        if existed {
            self.emit(
                event::OUTBOX_CHANGED,
                serde_json::json!({ "accountKey": account_key, "key": key, "status": OutboxStatus::Deleted.as_str() }),
            );
        }
        Ok(existed)
    }

}

/// The domain part of a sender address, for minting Message-IDs that aren't a
/// deliverability red flag on the providers that keep them.
fn message_id_domain(from: &str) -> String {
    from.rsplit_once('@')
        .map(|(_, d)| d.trim_end_matches('>').trim())
        .filter(|d| !d.is_empty())
        .unwrap_or("inbox2.local")
        .to_string()
}

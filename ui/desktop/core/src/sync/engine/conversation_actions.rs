//! Conversation actions: applying a user verb (archive, trash, mark-read,
//! priority, labels) optimistically to the local store and enqueueing the
//! durable provider write-back.

use super::*;

impl SyncEngine {
    /// Apply a provider action to every message in the given conversations.
    /// Shared by the Tauri command and the bus RPC.
    pub async fn perform_conversation_action(
        &self,
        account_key: &str,
        conversation_keys: &[String],
        action: &str,
    ) -> Result<()> {
        // All actions are ENQUEUED so they survive offline/restart and retry
        // with backoff — otherwise a failed or app-closed call was silently lost
        // and the next sync overwrote the local change. Structured verbs become
        // their ActionType; the rest (spam/unspam/untrash) become an Interactive
        // action applied via the provider's perform_action path. The 5s loop
        // drains the queue; we also kick it once here for an instant apply when
        // connected, leaving any failures queued for retry.
        // Optimistically reflect the action in the local conversation state up
        // front — the single source of truth for archive/trash/spam and
        // mark-read/unread persistence. Callers (web/CLI) only update their
        // in-memory UI; they never write the DB. Doing it here (before the
        // network write-back) means a sync re-query that races the action sees
        // the new state and can't resurrect the old one. The sync guard in
        // upsert_synced_message then preserves it until the write-back lands.
        // Entry log: proves the verb crossed the FFI at all, and with which account.
        // Without it, a UI-side drop and a store-side drop look identical after the
        // fact — the queue rows are reaped, so a lost action leaves no trace.
        log::info!(
            "[action] {account_key}: {action} on {} conversation(s): {}",
            conversation_keys.len(),
            conversation_keys.join(",")
        );
        let (status, read) = local_state_for_action(action);
        if status.is_some() || read.is_some() {
            for conv in conversation_keys {
                self.store.set_conversation_status(conv, status, read)?;
            }
            log::info!(
                "[action] {account_key}: local state set (status={status:?} read={read:?}) for {} conversation(s)",
                conversation_keys.len()
            );
        }

        let action_type = ActionType::from_request(action, None, None)
            .unwrap_or_else(|_| ActionType::Interactive { verb: action.to_string() });
        self.enqueue_for_conversations(account_key, conversation_keys, action_type)
            .await
    }

    /// Enqueue one write-back action per message in the given conversations,
    /// then kick the write-back loop for an immediate apply attempt.
    pub async fn enqueue_for_conversations(
        &self,
        account_key: &str,
        conversation_keys: &[String],
        action_type: ActionType,
    ) -> Result<()> {
        let mut enqueued = 0usize;
        for conv in conversation_keys {
            let messages = self.store.message_keys_for_conversation(account_key, conv)?;
            if messages.is_empty() {
                // No message has a provider_state row for this conversation, so there's
                // nothing to write back — the action is applied locally but never reaches
                // the provider. This is the "deleted on device, still in Gmail" silent
                // drop; surface it loudly so it's diagnosable rather than vanishing.
                log::warn!(
                    "[writeback] {account_key}: conversation {conv} ({}) expanded to ZERO messages — nothing enqueued; the action will NOT reach the provider",
                    action_type.as_str()
                );
                continue;
            }
            log::info!(
                "[writeback] {account_key}: enqueuing {} ({} message(s)) for conversation {conv}",
                action_type.as_str(),
                messages.len()
            );
            for (message_key, folder_key) in messages {
                // Snapshot the message's provider identity NOW. If a racing sync later
                // prunes its provider-state row, the action still knows which server
                // message to act on (no silent loss).
                let snapshot = self
                    .store
                    .get_provider_state_by_message(&message_key, account_key)
                    .ok()
                    .flatten()
                    .map(|(_, pid)| pid);
                self.writeback.enqueue(
                    account_key,
                    action_type.clone(),
                    &message_key,
                    folder_key.as_deref(),
                    snapshot,
                )?;
                enqueued += 1;
            }
        }
        if enqueued > 0 {
            let _ = self.process_writeback(account_key).await;
        }
        Ok(())
    }

    /// Set urgent/important priority on conversations + sync the quadrant label.
    pub async fn set_conversation_priority(
        &self,
        account_key: &str,
        conversation_keys: &[String],
        urgent: bool,
        important: bool,
    ) -> Result<()> {
        let action = Quadrant::from_priority(urgent, important).set_verb();
        // Optimistic local update, then enqueue the provider-side label change so
        // it's durable + retried like every other action.
        for conv in conversation_keys {
            // triaged=true: placing into any quadrant (incl. Later) is a triage.
            self.store.set_conversation_priority(conv, urgent, important, true)?;
        }
        self.enqueue_for_conversations(
            account_key,
            conversation_keys,
            ActionType::Interactive { verb: action },
        )
        .await
    }

    /// Clear priority on conversations + remove quadrant labels.
    pub async fn clear_conversation_priority(
        &self,
        account_key: &str,
        conversation_keys: &[String],
    ) -> Result<()> {
        for conv in conversation_keys {
            // triaged=false: clearing returns the conversation to the untriaged stream.
            self.store.set_conversation_priority(conv, false, false, false)?;
        }
        self.enqueue_for_conversations(
            account_key,
            conversation_keys,
            ActionType::Interactive { verb: "clear_quadrant".to_string() },
        )
        .await
    }

    /// Move conversations to a folder, named by its key, well-known role
    /// (`inbox`/`archive`/`trash`/`spam`) or display name. The role folders go
    /// through their own verbs, which each provider already maps; any other
    /// folder is a `Move` to its provider id and takes the thread out of the
    /// inbox locally.
    pub async fn move_conversations(&self, account_key: &str, conversation_keys: &[String], folder: &str) -> Result<()> {
        let target = self.resolve_folder(account_key, folder)?;
        let target = &target;
        let verb = match &target.role {
            Some(WellKnownFolder::Inbox) => Some("unarchive"),
            Some(WellKnownFolder::Archive) => Some("archive"),
            Some(WellKnownFolder::Trash) => Some("trash"),
            Some(WellKnownFolder::Spam) => Some("spam"),
            _ => None,
        };
        if let Some(verb) = verb {
            return self.perform_conversation_action(account_key, conversation_keys, verb).await;
        }
        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        // IMAP moves by mailbox name; Gmail and Graph by the id kept in flags[0].
        let provider_id = if account.provider_type == ProviderType::Imap {
            target.provider_name.clone()
        } else {
            target.flags.first().cloned().unwrap_or_else(|| target.provider_name.clone())
        };
        for conv in conversation_keys {
            self.store.set_conversation_status(conv, Some(ConversationStatus::Archived), None)?;
        }
        self.enqueue_for_conversations(account_key, conversation_keys, ActionType::Move { target_folder: provider_id })
            .await
    }

    /// A folder named by its key, well-known role or display name.
    pub fn resolve_folder(&self, account_key: &str, folder: &str) -> Result<UnifiedFolder> {
        let folders = self.store.get_folders_for_account(account_key)?;
        folders
            .iter()
            .find(|f| f.key == folder || f.role.as_ref().is_some_and(|r| r.as_str() == folder))
            .or_else(|| folders.iter().find(|f| f.provider_name.eq_ignore_ascii_case(folder)))
            .cloned()
            .ok_or_else(|| SyncError::Other(format!("no folder '{folder}' on this account")))
    }

    /// Add or remove a tag on every message in the given conversations: a Gmail
    /// label (must already exist; matched by name), an Outlook category, or an
    /// IMAP folder of that name.
    pub async fn tag_conversations(
        &self,
        account_key: &str,
        conversation_keys: &[String],
        tag: &str,
        add: bool,
    ) -> Result<()> {
        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        // A tag is a user label. System folders (INBOX, TRASH, …) are statuses
        // with their own verbs: tagging one would trash or delete through the
        // back door (Gmail +TRASH; IMAP removing the INBOX "label" expunges).
        let folders = self.store.get_folders_for_account(account_key)?;
        let is_system = |name: &str| {
            name.eq_ignore_ascii_case("inbox")
                || folders.iter().any(|f| {
                    f.role.is_some() && (f.provider_name.eq_ignore_ascii_case(name) || f.flags.first().is_some_and(|id| id == name))
                })
        };
        if is_system(tag) {
            return Err(SyncError::Other(format!("'{tag}' is a system folder, not a tag; use move_to_folder or its own action")));
        }
        let label = match account.provider_type {
            // Gmail wants the label id, not its name.
            ProviderType::Gmail => folders
                .iter()
                .filter(|f| f.role.is_none())
                .find(|f| f.provider_name.eq_ignore_ascii_case(tag) || f.flags.first().is_some_and(|id| id == tag))
                .and_then(|f| f.flags.first().cloned())
                .ok_or_else(|| SyncError::Other(format!("no Gmail label named '{tag}'")))?,
            ProviderType::Imap if !add => {
                // An IMAP "label" is a folder copy. Where it's the folder the
                // message actually lives in, removing it deletes the message.
                for conv in conversation_keys {
                    for (_, folder_key) in self.store.message_keys_for_conversation(account_key, conv)? {
                        let home = folders.iter().find(|f| Some(&f.key) == folder_key.as_ref());
                        if home.is_some_and(|f| f.provider_name.eq_ignore_ascii_case(tag)) {
                            return Err(SyncError::Other(format!(
                                "'{tag}' is where these messages live; removing it would delete them (use move_to_folder)"
                            )));
                        }
                    }
                }
                tag.to_string()
            }
            _ => tag.to_string(),
        };
        let action = if add { ActionType::AddLabel { label } } else { ActionType::RemoveLabel { label } };
        self.enqueue_for_conversations(account_key, conversation_keys, action).await
    }

    /// Add a provider label to every message in the given conversations (the
    /// auto-label rule action). Provider-side only — labels live in provider state,
    /// so the local view reflects it on the next sync. Durable + retried like every
    /// other write-back.
    pub async fn add_conversation_label(
        &self,
        account_key: &str,
        conversation_keys: &[String],
        label: String,
    ) -> Result<()> {
        self.enqueue_for_conversations(
            account_key,
            conversation_keys,
            ActionType::AddLabel { label },
        )
        .await
    }

}

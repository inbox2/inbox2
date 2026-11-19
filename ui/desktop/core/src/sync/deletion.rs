//! Message deletion cascade + remote-disappearance pruning.
//!
//! Operates on an already-locked rusqlite [`Connection`] passed in by
//! [`crate::sync::store::SyncStore`], which keeps the public, lock-acquiring
//! wrappers thin and the cascade logic in one place.

use std::collections::HashSet;

use rusqlite::{params, Connection, OptionalExtension};

use crate::sync::error::Result;
use crate::sync::model::ProviderMessageId;

/// Delete a message that disappeared from the provider, cascading like the JS
/// `cascadeDeleteMessage`: remove the provider-state row for this folder; if the
/// message has no remaining provider state, delete the message; if its
/// conversation then has no messages, delete the conversation. Identifies the
/// row by UID (IMAP) or provider_message_id (Gmail/Microsoft).
pub(crate) fn cascade_delete_message(
    conn: &Connection,
    account_key: &str,
    folder_key: &str,
    pid: &ProviderMessageId,
) -> Result<()> {
    // Resolve the affected message_key and delete the provider-state row.
    let message_key: Option<String> = if let Some(uid) = pid.uid {
        let mk = conn
            .query_row(
                "SELECT message_key FROM message_provider_state
                 WHERE account_key = ?1 AND folder_key = ?2 AND provider_uid = ?3",
                params![account_key, folder_key, uid as i64],
                |row| row.get(0),
            )
            .optional()?;
        conn.execute(
            "DELETE FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_uid = ?3",
            params![account_key, folder_key, uid as i64],
        )?;
        mk
    } else if let Some(ref pmid) = pid.provider_id {
        let mk = conn
            .query_row(
                "SELECT message_key FROM message_provider_state
                 WHERE account_key = ?1 AND folder_key = ?2 AND provider_message_id = ?3",
                params![account_key, folder_key, pmid],
                |row| row.get(0),
            )
            .optional()?;
        conn.execute(
            "DELETE FROM message_provider_state
             WHERE account_key = ?1 AND folder_key = ?2 AND provider_message_id = ?3",
            params![account_key, folder_key, pmid],
        )?;
        mk
    } else {
        None
    };

    // Cascade to message + conversation if nothing else references them.
    if let Some(mkey) = message_key {
        let remaining: i64 = conn.query_row(
            "SELECT COUNT(*) FROM message_provider_state WHERE message_key = ?1",
            params![mkey],
            |row| row.get(0),
        )?;
        if remaining == 0 {
            let conv_key: Option<String> = conn
                .query_row(
                    "SELECT conversation_key FROM messages WHERE key = ?1",
                    params![mkey],
                    |row| row.get(0),
                )
                .optional()?;
            conn.execute("DELETE FROM messages WHERE key = ?1", params![mkey])?;
            if let Some(ck) = conv_key {
                let msgs_left: i64 = conn.query_row(
                    "SELECT COUNT(*) FROM messages WHERE conversation_key = ?1",
                    params![ck],
                    |row| row.get(0),
                )?;
                if msgs_left == 0 {
                    conn.execute("DELETE FROM conversations WHERE key = ?1", params![ck])?;
                }
            }
        }
    }
    Ok(())
}

/// After a full folder sync, remove locally-known messages (`known` provider
/// ids) whose id was not present in the remote listing (`seen`). Equivalent to
/// the JS `removeOrphanedMessages(folderKey, seenProviderIds)`. Returns the
/// count removed.
pub(crate) fn prune_unseen_provider_ids(
    conn: &Connection,
    account_key: &str,
    folder_key: &str,
    known: &[String],
    seen: &HashSet<String>,
) -> Result<usize> {
    let mut removed = 0;
    for pmid in known {
        if !seen.contains(pmid) {
            cascade_delete_message(
                conn,
                account_key,
                folder_key,
                &ProviderMessageId {
                    uid: None,
                    mod_seq: None,
                    provider_id: Some(pmid.clone()),
                },
            )?;
            removed += 1;
        }
    }
    Ok(removed)
}

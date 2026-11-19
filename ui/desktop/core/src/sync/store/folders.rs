//! `SyncStore` — folder metadata and per-folder sync state.

use super::*;

impl SyncStore {

    // -----------------------------------------------------------------------
    // Folders
    // -----------------------------------------------------------------------

    pub fn upsert_folder(&self, folder: &UnifiedFolder) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let flags_json = serde_json::to_string(&folder.flags).unwrap_or_default();
        let role_str = folder.role.as_ref().map(|r| r.as_str().to_string());

        // On conflict we update only metadata; sync-state columns
        // (uid_validity, highest_mod_seq, last_synced_uid, sync_cursor) are
        // PRESERVED so that re-listing folders on reconnect does not wipe the
        // cursor and force a full resync.
        conn.execute(
            "INSERT INTO external_folders
             (key, account_key, provider_name, well_known_role, separator, flags,
              uid_validity, highest_mod_seq, last_synced_uid, sync_cursor, sync_enabled, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(key) DO UPDATE SET
              provider_name = excluded.provider_name,
              well_known_role = excluded.well_known_role,
              separator = excluded.separator,
              flags = excluded.flags,
              sync_enabled = excluded.sync_enabled,
              updated_at = excluded.updated_at",
            params![
                folder.key,
                folder.account_key,
                folder.provider_name,
                role_str,
                folder.separator,
                flags_json,
                folder.uid_validity.map(|v| v as i64),
                folder.highest_mod_seq as i64,
                folder.last_synced_uid as i64,
                folder.sync_cursor,
                folder.sync_enabled as i32,
                now,
                now,
            ],
        )?;
        Ok(())
    }

    pub fn get_folders_for_account(&self, account_key: &str) -> Result<Vec<UnifiedFolder>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT key, account_key, provider_name, well_known_role, separator, flags,
                    uid_validity, highest_mod_seq, last_synced_uid, sync_cursor, sync_enabled
             FROM external_folders WHERE account_key = ?1",
        )?;
        let rows = stmt.query_map(params![account_key], |row| {
            // Tolerate a NULL/blank flags column (e.g. externally-seeded rows):
            // treat it as no flags rather than failing the whole query.
            let flags_json: Option<String> = row.get(5)?;
            let flags: Vec<String> = flags_json
                .as_deref()
                .map(|s| serde_json::from_str(s).unwrap_or_default())
                .unwrap_or_default();
            let role_str: Option<String> = row.get(3)?;
            Ok(UnifiedFolder {
                key: row.get(0)?,
                account_key: row.get(1)?,
                provider_name: row.get(2)?,
                role: role_str.map(|s| WellKnownFolder::from_str(&s)),
                separator: row.get(4)?,
                flags,
                uid_validity: row.get::<_, Option<i64>>(6)?.map(|v| v as u32),
                highest_mod_seq: row.get::<_, i64>(7)? as u64,
                last_synced_uid: row.get::<_, i64>(8)? as u32,
                sync_cursor: row.get::<_, Option<String>>(9)?,
                sync_enabled: row.get::<_, i32>(10)? != 0,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Persist folder sync state. `token` is the opaque provider cursor
    /// (Gmail historyId / Microsoft deltaLink); pass `None` to leave the stored
    /// cursor unchanged (e.g. between initial-sync batches), `Some` to set it.
    pub fn update_folder_sync_state(
        &self,
        folder_key: &str,
        uid_validity: u32,
        highest_mod_seq: u64,
        last_synced_uid: u32,
        token: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE external_folders
             SET uid_validity = ?1, highest_mod_seq = ?2, last_synced_uid = ?3,
                 sync_cursor = COALESCE(?4, sync_cursor),
                 last_sync_at = ?5, updated_at = ?6
             WHERE key = ?7",
            params![
                uid_validity as i64,
                highest_mod_seq as i64,
                last_synced_uid as i64,
                token,
                now,
                now,
                folder_key,
            ],
        )?;
        Ok(())
    }
}

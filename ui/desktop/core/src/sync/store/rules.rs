//! `SyncStore` — local-rules writes for native (iOS/Android) clients.
//!
//! The portable rule *engine* lives in `crate::rules`; the desktop crate owns
//! the rich `AgentRunStore` (which also manages CLI-agent runs). Native clients
//! only need to read the `local_rules` table (done directly over SQLite) and
//! perform two writes — toggle `enabled` and create a built-in rule — so those
//! two writes live here against the same schema, keeping the desktop-only
//! `AgentRunStore` out of the mobile build.
//!
//! Conditions/action are passed through as already-serialized JSON strings
//! (the native side constructs them), so this layer is schema-shape-agnostic
//! and doesn't pull in the rule structs.

use super::*;

impl SyncStore {
    /// Flip a rule's `enabled` flag. Returns whether a row matched.
    pub fn set_local_rule_enabled(&self, key: &str, enabled: bool) -> Result<bool> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE local_rules SET enabled = ?1, updated_at = ?2 WHERE key = ?3",
            params![if enabled { 1 } else { 0 }, now, key],
        )?;
        Ok(changed > 0)
    }

    /// Create a built-in local rule (`run_agent` rules stay desktop-only).
    /// `conditions_json` is a JSON array of `{field, op, value}`; `action_json`
    /// is a `{"type":"perform_action", "builtin":…}` object — both validated as
    /// well-formed JSON before insert. Returns the generated `lrul_…` key.
    pub fn create_local_rule(
        &self,
        name: &str,
        conditions_json: &str,
        action_json: &str,
        account_key: Option<&str>,
        enabled: bool,
    ) -> Result<String> {
        // Validate the caller's JSON so we never persist a rule the engine
        // can't parse at scan time.
        let _: serde_json::Value = serde_json::from_str(conditions_json)
            .map_err(|e| SyncError::Other(format!("invalid conditions JSON: {e}")))?;
        let _: serde_json::Value = serde_json::from_str(action_json)
            .map_err(|e| SyncError::Other(format!("invalid action JSON: {e}")))?;

        let key = Self::generate_key("lrul");
        let now = Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO local_rules
             (key, name, account_key, conditions, ai_gate, action, enabled, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6, ?7, ?8)",
            params![
                key,
                name,
                account_key,
                conditions_json,
                action_json,
                if enabled { 1 } else { 0 },
                now,
                now,
            ],
        )?;
        Ok(key)
    }

    /// Update a built-in rule's name + conditions + action (validated JSON).
    /// Returns whether a row matched.
    pub fn update_local_rule(
        &self,
        key: &str,
        name: &str,
        conditions_json: &str,
        action_json: &str,
    ) -> Result<bool> {
        let _: serde_json::Value = serde_json::from_str(conditions_json)
            .map_err(|e| SyncError::Other(format!("invalid conditions JSON: {e}")))?;
        let _: serde_json::Value = serde_json::from_str(action_json)
            .map_err(|e| SyncError::Other(format!("invalid action JSON: {e}")))?;
        let now = Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        let changed = conn.execute(
            "UPDATE local_rules SET name = ?1, conditions = ?2, action = ?3, updated_at = ?4
             WHERE key = ?5",
            params![name, conditions_json, action_json, now, key],
        )?;
        Ok(changed > 0)
    }

    /// Delete a local rule by key. Returns whether a row matched.
    pub fn delete_local_rule(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let changed = conn.execute("DELETE FROM local_rules WHERE key = ?1", params![key])?;
        Ok(changed > 0)
    }
}

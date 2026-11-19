use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Arc;

/// Permission levels for agent tool access.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum PermissionLevel {
    Read,
    ReadWrite,
    Full,
}

impl PermissionLevel {
    pub fn from_str(s: &str) -> Self {
        match s {
            "read_write" => Self::ReadWrite,
            "full" => Self::Full,
            _ => Self::Read,
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Read => "read",
            Self::ReadWrite => "read_write",
            Self::Full => "full",
        }
    }
}

/// Registered agent info.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Agent {
    pub key: String,
    pub name: String,
    pub description: Option<String>,
    pub permission_level: String,
    pub auto_approve: bool,
    pub default_account_key: Option<String>,
    pub is_active: bool,
    pub rate_limit_rpm: i32,
    pub last_connected_at: Option<String>,
    pub created_at: String,
}

/// Agent permission checker and registration.
pub struct PermissionManager {
    conn: Arc<Mutex<Connection>>,
}

impl PermissionManager {
    pub fn new(conn: Arc<Mutex<Connection>>) -> Self {
        Self { conn }
    }

    /// Register a new agent or update last_connected_at. Returns the agent key.
    pub fn register_or_touch(&self, name: &str, description: Option<&str>) -> Result<Agent, String> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();

        // Check if agent exists by name
        let existing: Option<Agent> = conn
            .query_row(
                "SELECT key, name, description, permission_level, auto_approve,
                        default_account_key, is_active, rate_limit_rpm, last_connected_at, created_at
                 FROM agents WHERE name = ?1",
                params![name],
                |row| {
                    Ok(Agent {
                        key: row.get(0)?,
                        name: row.get(1)?,
                        description: row.get(2)?,
                        permission_level: row.get(3)?,
                        auto_approve: row.get::<_, i32>(4)? != 0,
                        default_account_key: row.get(5)?,
                        is_active: row.get::<_, i32>(6)? != 0,
                        rate_limit_rpm: row.get(7)?,
                        last_connected_at: row.get(8)?,
                        created_at: row.get(9)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())?;

        if let Some(mut agent) = existing {
            conn.execute(
                "UPDATE agents SET last_connected_at = ?1 WHERE key = ?2",
                params![now, agent.key],
            )
            .map_err(|e| e.to_string())?;
            agent.last_connected_at = Some(now);
            Ok(agent)
        } else {
            let key = format!("agt_{}", nanoid::nanoid!(21));
            let default_perm = conn
                .query_row(
                    "SELECT value FROM vector_settings WHERE key = 'mcp_permission_default'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap_or_else(|_| "read".to_string());

            conn.execute(
                "INSERT INTO agents
                 (key, name, description, permission_level, auto_approve, is_active,
                  rate_limit_rpm, last_connected_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, 0, 1, 60, ?5, ?5, ?5)",
                params![key, name, description, default_perm, now],
            )
            .map_err(|e| e.to_string())?;

            Ok(Agent {
                key,
                name: name.to_string(),
                description: description.map(String::from),
                permission_level: default_perm,
                auto_approve: false,
                default_account_key: None,
                is_active: true,
                rate_limit_rpm: 60,
                last_connected_at: Some(now.clone()),
                created_at: now,
            })
        }
    }

    /// Check if an agent has permission for a given tool.
    pub fn check_permission(&self, agent_key: &str, required: &PermissionLevel) -> Result<bool, String> {
        let conn = self.conn.lock();
        let level: String = conn
            .query_row(
                "SELECT permission_level FROM agents WHERE key = ?1 AND is_active = 1",
                params![agent_key],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;

        let agent_level = PermissionLevel::from_str(&level);
        Ok(agent_level >= *required)
    }

    /// Check if an action requires human approval (for privileged tools).
    pub fn needs_approval(&self, agent_key: &str) -> Result<bool, String> {
        let conn = self.conn.lock();

        // Check global auto-approve
        let global_auto: String = conn
            .query_row(
                "SELECT value FROM vector_settings WHERE key = 'agent_auto_approve'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_else(|_| "false".to_string());

        if global_auto == "true" {
            return Ok(false);
        }

        // Check per-agent auto-approve
        let agent_auto: i32 = conn
            .query_row(
                "SELECT auto_approve FROM agents WHERE key = ?1",
                params![agent_key],
                |row| row.get(0),
            )
            .unwrap_or(0);

        Ok(agent_auto == 0)
    }

    /// Log a tool call to the audit trail.
    pub fn log_action(
        &self,
        agent_key: &str,
        action_type: &str,
        params: Option<&str>,
        result_summary: Option<&str>,
        status: &str,
        error_message: Option<&str>,
        duration_ms: Option<i64>,
    ) -> Result<(), String> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO agent_audit_log
             (agent_key, action_type, action_params, result_summary, status,
              error_message, duration_ms, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                agent_key,
                action_type,
                params,
                result_summary,
                status,
                error_message,
                duration_ms,
                now,
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Set an agent's access. `full` also turns on auto-approve: nothing in the
    /// app asks a person to approve, so full without it acts like read_write.
    pub fn set_access(&self, agent_key: &str, level: &PermissionLevel) -> Result<(), String> {
        let n = self
            .conn
            .lock()
            .execute(
                "UPDATE agents SET permission_level = ?2, auto_approve = ?3 WHERE key = ?1",
                params![agent_key, level.as_str(), (*level == PermissionLevel::Full) as i32],
            )
            .map_err(|e| e.to_string())?;
        if n == 0 {
            return Err(format!("Agent '{agent_key}' not found"));
        }
        Ok(())
    }

    /// List all registered agents.
    pub fn list_agents(&self) -> Result<Vec<Agent>, String> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(
                "SELECT key, name, description, permission_level, auto_approve,
                        default_account_key, is_active, rate_limit_rpm, last_connected_at, created_at
                 FROM agents ORDER BY created_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok(Agent {
                    key: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    permission_level: row.get(3)?,
                    auto_approve: row.get::<_, i32>(4)? != 0,
                    default_account_key: row.get(5)?,
                    is_active: row.get::<_, i32>(6)? != 0,
                    rate_limit_rpm: row.get(7)?,
                    last_connected_at: row.get(8)?,
                    created_at: row.get(9)?,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::store::SyncStore;

    fn manager() -> PermissionManager {
        let store = SyncStore::new_in_memory().unwrap();
        PermissionManager::new(store.connection())
    }

    #[test]
    fn permission_level_ordering_and_strings() {
        assert!(PermissionLevel::Read < PermissionLevel::ReadWrite);
        assert!(PermissionLevel::ReadWrite < PermissionLevel::Full);
        assert_eq!(PermissionLevel::from_str("full"), PermissionLevel::Full);
        assert_eq!(PermissionLevel::from_str("read_write"), PermissionLevel::ReadWrite);
        // Unknown / missing → least privilege.
        assert_eq!(PermissionLevel::from_str("bogus"), PermissionLevel::Read);
        assert_eq!(PermissionLevel::Full.as_str(), "full");
    }

    #[test]
    fn register_then_touch_returns_same_key() {
        let mgr = manager();
        let a = mgr.register_or_touch("agent-x", Some("desc")).unwrap();
        assert!(a.key.starts_with("agt_"));
        // Default permission from the seeded vector_settings is "read".
        assert_eq!(a.permission_level, "read");
        let b = mgr.register_or_touch("agent-x", None).unwrap();
        assert_eq!(a.key, b.key, "re-registering by name must reuse the key");
        assert_eq!(mgr.list_agents().unwrap().len(), 1);
    }

    #[test]
    fn check_permission_respects_tiers() {
        let mgr = manager();
        let agent = mgr.register_or_touch("reader", None).unwrap();
        assert!(mgr.check_permission(&agent.key, &PermissionLevel::Read).unwrap());
        assert!(!mgr.check_permission(&agent.key, &PermissionLevel::ReadWrite).unwrap());
        assert!(!mgr.check_permission(&agent.key, &PermissionLevel::Full).unwrap());

        // Promote to full and re-check.
        mgr.conn
            .lock()
            .execute(
                "UPDATE agents SET permission_level = 'full' WHERE key = ?1",
                params![agent.key],
            )
            .unwrap();
        assert!(mgr.check_permission(&agent.key, &PermissionLevel::Full).unwrap());
    }

    #[test]
    fn needs_approval_honors_global_and_per_agent_flags() {
        let mgr = manager();
        let agent = mgr.register_or_touch("privileged", None).unwrap();

        // Default: no auto-approve anywhere → approval required.
        assert!(mgr.needs_approval(&agent.key).unwrap());

        // Per-agent auto-approve clears it.
        mgr.conn
            .lock()
            .execute(
                "UPDATE agents SET auto_approve = 1 WHERE key = ?1",
                params![agent.key],
            )
            .unwrap();
        assert!(!mgr.needs_approval(&agent.key).unwrap());

        // Reset per-agent; global auto-approve also clears it.
        mgr.conn
            .lock()
            .execute(
                "UPDATE agents SET auto_approve = 0 WHERE key = ?1",
                params![agent.key],
            )
            .unwrap();
        assert!(mgr.needs_approval(&agent.key).unwrap());
        mgr.conn
            .lock()
            .execute(
                "UPDATE vector_settings SET value = 'true' WHERE key = 'agent_auto_approve'",
                [],
            )
            .unwrap();
        assert!(!mgr.needs_approval(&agent.key).unwrap());
    }

    #[test]
    fn log_action_records_error_message() {
        let mgr = manager();
        mgr.log_action("agt_1", "trash", Some("{}"), None, "error", Some("boom"), Some(5))
            .unwrap();
        let conn = mgr.conn.lock();
        let (status, err): (String, Option<String>) = conn
            .query_row(
                "SELECT status, error_message FROM agent_audit_log WHERE agent_key = 'agt_1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(status, "error");
        assert_eq!(err.as_deref(), Some("boom"));
    }
}

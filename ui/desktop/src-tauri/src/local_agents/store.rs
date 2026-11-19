// AgentRunStore — all SQLite state for agentic filters, over the shared sync
// connection (same inbox2.db, same Arc<Mutex<Connection>> the UI uses).
//
// Tables: local_agents, local_rules, agent_runs (+ reused agent_audit_log,
// agent_approvals, vector_settings). See docs/Agentic-Filters.md §4.

use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Arc;

use crate::sync::error::Result;
use crate::sync::store::SyncStore;

use super::adapter::{AgentActionType, DetectedAgent, PermissionMode};
use super::harness::{HarnessAttachment, MessageInput};
use super::rules::{conditions_match, Condition, MessageFields};

const CURSOR_KEY: &str = "agentic_filters_cursor";
pub const MAX_ATTEMPTS: i64 = 3;

/// Lifecycle status of an agent run. Single source for the persisted status
/// strings, so a renamed/added status can't silently break a query or the UI
/// (CLAUDE.md: no duplicated enums).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    Pending,
    AwaitingApproval,
    Running,
    Succeeded,
    Failed,
    Timeout,
}

impl RunStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            RunStatus::Pending => "pending",
            RunStatus::AwaitingApproval => "awaiting_approval",
            RunStatus::Running => "running",
            RunStatus::Succeeded => "succeeded",
            RunStatus::Failed => "failed",
            RunStatus::Timeout => "timeout",
        }
    }
}

/// Lifecycle status of an `agent_approvals` row: a queued `run_agent` approval is
/// `Pending` until the user resolves it to `Approved` or `Rejected`. Single source
/// for the persisted strings (CLAUDE.md: no duplicated enums).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalStatus {
    Pending,
    Approved,
    Rejected,
}

impl ApprovalStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            ApprovalStatus::Pending => "pending",
            ApprovalStatus::Approved => "approved",
            ApprovalStatus::Rejected => "rejected",
        }
    }
}

/// Outcome recorded in `agent_audit_log` for a finished run — a coarse
/// success/error distinct from the per-run [`RunStatus`] lifecycle. Single source
/// for the persisted strings (CLAUDE.md: no duplicated enums).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuditStatus {
    Success,
    Error,
}

impl AuditStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            AuditStatus::Success => "success",
            AuditStatus::Error => "error",
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LocalRule {
    #[serde(default)]
    pub key: String,
    pub name: String,
    #[serde(default)]
    pub account_key: Option<String>,
    pub conditions: Vec<Condition>,
    #[serde(default)]
    pub ai_gate: Option<serde_json::Value>,
    pub action: RuleAction,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RuleAction {
    // "run_agent" (invoke a CLI agent) or "perform_action" (a built-in outcome).
    #[serde(rename = "type", default = "run_agent_type")]
    pub action_type: String,
    // Built-in action kind when action_type == "perform_action":
    // archive | delete | mark_read | auto_triage | auto_label | auto_reply.
    #[serde(default)]
    pub builtin: Option<String>,
    // Follow-up config for built-ins: target quadrant for auto_triage
    // ("auto" | DO_FIRST | SCHEDULE | DELEGATE | LATER), reply body for auto_reply.
    #[serde(default)]
    pub quadrant: Option<String>,
    #[serde(default)]
    pub reply: Option<String>,
    // The fields below apply to "run_agent" actions; defaulted so a
    // "perform_action" rule (which omits them) still deserializes.
    #[serde(default)]
    pub adapter_id: String,
    #[serde(default)]
    pub task: String,
    #[serde(default = "default_permission_mode")]
    pub permission_mode: String,
    #[serde(default = "default_timeout")]
    pub timeout_s: u64,
}

fn default_true() -> bool {
    true
}
fn run_agent_type() -> String {
    AgentActionType::RunAgent.as_str().to_string()
}
fn default_permission_mode() -> String {
    PermissionMode::ApprovalFirst.as_str().to_string()
}
fn default_timeout() -> u64 {
    120
}

/// Whether `table` exists. Table names here are hardcoded constants, never user
/// input, so the format!-built PRAGMA/queries carry no injection risk.
fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        params![table],
        |r| r.get(0),
    )?;
    Ok(n > 0)
}

/// Whether `table` has a column named `column` (PRAGMA can't bind the table name).
fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AgentRunRow {
    pub key: String,
    pub rule_key: Option<String>,
    pub message_key: String,
    pub account_key: String,
    pub adapter_id: String,
    pub task: String,
    pub permission_mode: String,
    pub status: String,
    pub attempts: i64,
    pub timeout_s: i64,
    pub scratch_dir: Option<String>,
    pub result_json: Option<String>,
    pub exit_code: Option<i64>,
    pub cost_usd: Option<f64>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub error: Option<String>,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub duration_ms: Option<i64>,
    pub created_at: String,
    pub updated_at: String,
}

/// Cost + token usage parsed from an agent's own output (see runner `extract_metrics`).
/// All optional — an agent that doesn't report them leaves them null.
#[derive(Default, Clone, Copy)]
pub struct RunMetrics {
    pub cost_usd: Option<f64>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
}

/// Parameters for enqueuing a run.
pub struct EnqueueRun {
    pub rule_key: Option<String>,
    pub message_key: String,
    pub account_key: String,
    pub adapter_id: String,
    pub task: String,
    pub permission_mode: String,
    pub timeout_s: u64,
}

pub struct AgentRunStore {
    conn: Arc<Mutex<Connection>>,
}

impl AgentRunStore {
    pub fn new(conn: Arc<Mutex<Connection>>) -> Self {
        Self { conn }
    }

    /// Bring the agentic-filter tables up to the current schema on an existing
    /// dev database. The schema file is edited in place (CLAUDE.md: no
    /// incremental migrations until production), and `CREATE TABLE IF NOT EXISTS`
    /// never adds a column to a table an earlier build already created — so a dev
    /// DB can carry a stale `agent_runs`/`local_rules`/`local_agents` that's
    /// missing a column the current code reads (e.g. `timeout_s`). These three
    /// tables hold only disposable local state (run history, dev rules, detection
    /// cache), so a stale one is dropped and recreated from the canonical schema.
    /// `agent_approvals` (the shared MCP approval queue) is deliberately untouched,
    /// as is every synced-mail table. A no-op once the schema matches.
    pub fn ensure_schema(&self) -> Result<()> {
        // (table, a column present only in the current schema — absent ⇒ stale).
        const CHECKS: &[(&str, &str)] = &[
            ("agent_runs", "input_tokens"),
            ("local_rules", "ai_gate"),
            ("local_agents", "binary_path"),
        ];
        let conn = self.conn.lock();
        let mut dropped_any = false;
        for (table, col) in CHECKS {
            if table_exists(&conn, table)? && !column_exists(&conn, table, col)? {
                conn.execute_batch(&format!("DROP TABLE IF EXISTS {table};"))?;
                dropped_any = true;
            }
        }
        if !dropped_any {
            return Ok(());
        }
        // Recreate the dropped tables (+ indexes) from the canonical schema. Every
        // statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE) — the sync
        // store already re-runs this same batch on every boot — so untouched
        // tables are left exactly as they are.
        conn.execute_batch(inbox2_core::SCHEMA_SQL)?;
        Ok(())
    }

    // ─── Settings ────────────────────────────────────────────────────────────

    pub fn filters_enabled(&self) -> bool {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT value FROM vector_settings WHERE key = 'agentic_filters_enabled'",
            [],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
        .map(|v| v == "true")
        .unwrap_or(false)
    }

    // ─── Detection persistence ───────────────────────────────────────────────

    /// Record a detection result, preserving the user's `enabled` choice.
    pub fn upsert_detection(&self, d: &DetectedAgent) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO local_agents
               (key, adapter_id, display_name, binary_path, version, enabled, last_detected_at, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, ?6)
             ON CONFLICT(adapter_id) DO UPDATE SET
               display_name = excluded.display_name,
               binary_path = excluded.binary_path,
               version = excluded.version,
               last_detected_at = excluded.last_detected_at,
               updated_at = excluded.updated_at",
            params![
                SyncStore::generate_key("lagt"),
                d.adapter_id,
                d.display_name,
                d.binary_path,
                d.version,
                now,
            ],
        )?;
        Ok(())
    }

    pub fn set_enabled(&self, adapter_id: &str, enabled: bool) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE local_agents SET enabled = ?2, updated_at = ?3 WHERE adapter_id = ?1",
            params![adapter_id, enabled as i32, chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn is_enabled(&self, adapter_id: &str) -> bool {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT enabled FROM local_agents WHERE adapter_id = ?1",
            params![adapter_id],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .ok()
        .flatten()
        .map(|v| v != 0)
        .unwrap_or(false)
    }

    // ─── Rules ───────────────────────────────────────────────────────────────

    pub fn list_rules(&self) -> Result<Vec<LocalRule>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT key, name, account_key, conditions, ai_gate, action, enabled
             FROM local_rules ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(LocalRule {
                key: r.get(0)?,
                name: r.get(1)?,
                account_key: r.get(2)?,
                conditions: serde_json::from_str(&r.get::<_, String>(3)?).unwrap_or_default(),
                ai_gate: r
                    .get::<_, Option<String>>(4)?
                    .and_then(|s| serde_json::from_str(&s).ok()),
                action: serde_json::from_str(&r.get::<_, String>(5)?)
                    .unwrap_or_else(|_| placeholder_action()),
                enabled: r.get::<_, i64>(6)? != 0,
            })
        })?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    /// Fetch a single rule by key (None if it was deleted). Used by the
    /// apply-to-existing backfill, which acts on one freshly-saved rule.
    pub fn get_rule(&self, key: &str) -> Result<Option<LocalRule>> {
        let conn = self.conn.lock();
        let row = conn
            .query_row(
                "SELECT key, name, account_key, conditions, ai_gate, action, enabled
                 FROM local_rules WHERE key = ?1",
                params![key],
                |r| {
                    Ok(LocalRule {
                        key: r.get(0)?,
                        name: r.get(1)?,
                        account_key: r.get(2)?,
                        conditions: serde_json::from_str(&r.get::<_, String>(3)?)
                            .unwrap_or_default(),
                        ai_gate: r
                            .get::<_, Option<String>>(4)?
                            .and_then(|s| serde_json::from_str(&s).ok()),
                        action: serde_json::from_str(&r.get::<_, String>(5)?)
                            .unwrap_or_else(|_| placeholder_action()),
                        enabled: r.get::<_, i64>(6)? != 0,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    /// Insert or update a rule. Returns its key (generated when absent).
    pub fn upsert_rule(&self, rule: &LocalRule) -> Result<String> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        let key = if rule.key.is_empty() {
            SyncStore::generate_key("lrul")
        } else {
            rule.key.clone()
        };
        let conditions = serde_json::to_string(&rule.conditions).unwrap_or_else(|_| "[]".into());
        let ai_gate = rule
            .ai_gate
            .as_ref()
            .map(|g| serde_json::to_string(g).unwrap_or_default());
        let action = serde_json::to_string(&rule.action).unwrap_or_default();
        conn.execute(
            "INSERT INTO local_rules
               (key, name, account_key, conditions, ai_gate, action, enabled, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
             ON CONFLICT(key) DO UPDATE SET
               name = excluded.name, account_key = excluded.account_key,
               conditions = excluded.conditions, ai_gate = excluded.ai_gate,
               action = excluded.action, enabled = excluded.enabled,
               updated_at = excluded.updated_at",
            params![
                key,
                rule.name,
                rule.account_key,
                conditions,
                ai_gate,
                action,
                rule.enabled as i32,
                now,
            ],
        )?;
        Ok(key)
    }

    pub fn delete_rule(&self, key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM local_rules WHERE key = ?1", params![key])?;
        Ok(())
    }

    // ─── Run queue ───────────────────────────────────────────────────────────

    /// Enqueue a run. `approval_first` with no prior succeeded run for the rule
    /// starts in `awaiting_approval` (+ an approval row); everything else `pending`.
    pub fn enqueue_run(&self, e: &EnqueueRun) -> Result<String> {
        // Only real rules gate on approval; ad-hoc/test runs (no rule_key) run now.
        let needs_approval = PermissionMode::parse(&e.permission_mode) == Some(PermissionMode::ApprovalFirst)
            && e.rule_key.is_some()
            && !self.rule_previously_succeeded(e.rule_key.as_deref());
        let status = if needs_approval {
            RunStatus::AwaitingApproval
        } else {
            RunStatus::Pending
        };
        let key = SyncStore::generate_key("arun");
        let now = chrono::Utc::now().to_rfc3339();
        {
            let conn = self.conn.lock();
            conn.execute(
                "INSERT INTO agent_runs
                   (key, rule_key, message_key, account_key, adapter_id, task,
                    permission_mode, status, attempts, timeout_s, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, ?10, ?10)",
                params![
                    key,
                    e.rule_key,
                    e.message_key,
                    e.account_key,
                    e.adapter_id,
                    e.task,
                    e.permission_mode,
                    status.as_str(),
                    e.timeout_s as i64,
                    now,
                ],
            )?;
        }
        if needs_approval {
            self.create_approval(&key, &e.adapter_id)?;
        }
        Ok(key)
    }

    /// Record a completed built-in action (archive/mark-read/auto-triage/…) as a
    /// terminal run, so it surfaces in the conversation's routing panel alongside
    /// agent runs. `action_key` (e.g. "archive") goes in the adapter_id column; the
    /// panel renders it as the run's label. No queue/retry — the durable mutation
    /// lives in the sync engine's write-back queue, this is just the audit trail.
    pub fn record_action_run(
        &self,
        rule_key: &str,
        message_key: &str,
        account_key: &str,
        action_key: &str,
        status: RunStatus,
        summary: Option<&str>,
        error: Option<&str>,
    ) -> Result<String> {
        let key = SyncStore::generate_key("arun");
        let now = chrono::Utc::now().to_rfc3339();
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO agent_runs
               (key, rule_key, message_key, account_key, adapter_id, task,
                permission_mode, status, attempts, timeout_s, result_json, error,
                started_at, finished_at, duration_ms, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, '', 'full_auto', ?6, 1, 0, ?7, ?8, ?9, ?9, 0, ?9, ?9)",
            params![
                key,
                rule_key,
                message_key,
                account_key,
                action_key,
                status.as_str(),
                summary,
                error,
                now,
            ],
        )?;
        Ok(key)
    }

    fn rule_previously_succeeded(&self, rule_key: Option<&str>) -> bool {
        let Some(rule_key) = rule_key else {
            return false;
        };
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_runs WHERE rule_key = ?1 AND status = ?2)",
            params![rule_key, RunStatus::Succeeded.as_str()],
            |r| r.get::<_, bool>(0),
        )
        .unwrap_or(false)
    }

    /// Atomically claim the oldest `pending` run, transitioning it to `running`.
    pub fn claim_next_pending(&self) -> Result<Option<AgentRunRow>> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        let pending = RunStatus::Pending.as_str();
        let key: Option<String> = conn
            .query_row(
                "SELECT key FROM agent_runs WHERE status = ?1 ORDER BY id ASC LIMIT 1",
                params![pending],
                |r| r.get(0),
            )
            .optional()?;
        let Some(key) = key else { return Ok(None) };
        conn.execute(
            "UPDATE agent_runs
             SET status = ?2, attempts = attempts + 1, started_at = ?3, updated_at = ?3
             WHERE key = ?1 AND status = ?4",
            params![key, RunStatus::Running.as_str(), now, pending],
        )?;
        row_by_key(&conn, &key)
    }

    pub fn finish_run(
        &self,
        key: &str,
        status: RunStatus,
        result_json: Option<&str>,
        exit_code: Option<i64>,
        metrics: RunMetrics,
        error: Option<&str>,
        duration_ms: i64,
        scratch_dir: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE agent_runs SET status = ?2, result_json = ?3, exit_code = ?4,
               cost_usd = ?5, input_tokens = ?6, output_tokens = ?7, error = ?8,
               duration_ms = ?9, scratch_dir = ?10, finished_at = ?11, updated_at = ?11
             WHERE key = ?1",
            params![
                key,
                status.as_str(),
                result_json,
                exit_code,
                metrics.cost_usd,
                metrics.input_tokens,
                metrics.output_tokens,
                error,
                duration_ms,
                scratch_dir,
                now
            ],
        )?;
        Ok(())
    }

    /// Re-queue a failed run for another attempt if under the cap. Returns true if
    /// re-queued, false if the cap is reached (caller should mark it failed).
    pub fn requeue_if_retriable(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let attempts: i64 = conn
            .query_row(
                "SELECT attempts FROM agent_runs WHERE key = ?1",
                params![key],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(MAX_ATTEMPTS);
        if attempts >= MAX_ATTEMPTS {
            return Ok(false);
        }
        conn.execute(
            "UPDATE agent_runs SET status = ?2, updated_at = ?3 WHERE key = ?1",
            params![key, RunStatus::Pending.as_str(), chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(true)
    }

    /// Manually re-queue a run (the sidebar "Retry" button). Resets to pending
    /// regardless of attempt count.
    pub fn retry_run(&self, key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE agent_runs SET status = ?2, error = NULL, updated_at = ?3
             WHERE key = ?1",
            params![key, RunStatus::Pending.as_str(), chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn list_runs(&self, message_key: Option<&str>, limit: i64) -> Result<Vec<AgentRunRow>> {
        let conn = self.conn.lock();
        let mut out = Vec::new();
        if let Some(mk) = message_key {
            let mut stmt = conn.prepare(&format!("{RUN_SELECT} WHERE message_key = ?1 ORDER BY id DESC LIMIT ?2"))?;
            let rows = stmt.query_map(params![mk, limit], map_run)?;
            for r in rows {
                out.push(r?);
            }
        } else {
            let mut stmt = conn.prepare(&format!("{RUN_SELECT} ORDER BY id DESC LIMIT ?1"))?;
            let rows = stmt.query_map(params![limit], map_run)?;
            for r in rows {
                out.push(r?);
            }
        }
        Ok(out)
    }

    /// Runs in any of the given statuses, newest first (powers the "find failed
    /// processes" view). `["failed","timeout"]` surfaces everything that broke.
    pub fn list_runs_by_status(&self, statuses: &[&str], limit: i64) -> Result<Vec<AgentRunRow>> {
        if statuses.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock();
        let placeholders = statuses.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("{RUN_SELECT} WHERE status IN ({placeholders}) ORDER BY id DESC LIMIT {limit}");
        let mut stmt = conn.prepare(&sql)?;
        let p = statuses.iter().map(|s| s as &dyn rusqlite::ToSql).collect::<Vec<_>>();
        let rows = stmt.query_map(rusqlite::params_from_iter(p), map_run)?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    /// Runs for every message in a conversation (powers the sidebar panel).
    pub fn list_runs_for_conversation(
        &self,
        conversation_key: &str,
        limit: i64,
    ) -> Result<Vec<AgentRunRow>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!(
            "{RUN_SELECT} WHERE message_key IN
               (SELECT key FROM messages WHERE conversation_key = ?1)
             ORDER BY id DESC LIMIT ?2"
        ))?;
        let rows = stmt.query_map(params![conversation_key, limit], map_run)?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    // ─── Approvals ───────────────────────────────────────────────────────────

    fn create_approval(&self, run_key: &str, adapter_id: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO agent_approvals (key, agent_key, action_type, action_params, status, created_at)
             VALUES (?1, ?2, ?5, ?3, ?6, ?4)",
            params![
                SyncStore::generate_key("appr"),
                adapter_id,
                serde_json::json!({ "run_key": run_key }).to_string(),
                now,
                AgentActionType::RunAgent.as_str(),
                ApprovalStatus::Pending.as_str(),
            ],
        )?;
        Ok(())
    }

    /// Resolve an approval: approve flips the linked run to `pending`; reject fails it.
    pub fn resolve_approval(&self, approval_key: &str, approved: bool) -> Result<()> {
        let run_key: Option<String> = {
            let conn = self.conn.lock();
            let params_json: Option<String> = conn
                .query_row(
                    "SELECT action_params FROM agent_approvals WHERE key = ?1",
                    params![approval_key],
                    |r| r.get(0),
                )
                .optional()?;
            conn.execute(
                "UPDATE agent_approvals SET status = ?2, resolved_at = ?3 WHERE key = ?1",
                params![
                    approval_key,
                    if approved {
                        ApprovalStatus::Approved.as_str()
                    } else {
                        ApprovalStatus::Rejected.as_str()
                    },
                    chrono::Utc::now().to_rfc3339()
                ],
            )?;
            params_json
                .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                .and_then(|v| v.get("run_key").and_then(|k| k.as_str().map(String::from)))
        };
        if let Some(run_key) = run_key {
            let conn = self.conn.lock();
            if approved {
                conn.execute(
                    "UPDATE agent_runs SET status = ?2, updated_at = ?3
                     WHERE key = ?1 AND status = ?4",
                    params![
                        run_key,
                        RunStatus::Pending.as_str(),
                        chrono::Utc::now().to_rfc3339(),
                        RunStatus::AwaitingApproval.as_str()
                    ],
                )?;
            } else {
                conn.execute(
                    "UPDATE agent_runs SET status = ?2, error = 'approval rejected', updated_at = ?3
                     WHERE key = ?1 AND status = ?4",
                    params![
                        run_key,
                        RunStatus::Failed.as_str(),
                        chrono::Utc::now().to_rfc3339(),
                        RunStatus::AwaitingApproval.as_str()
                    ],
                )?;
            }
        }
        Ok(())
    }

    /// Pending approvals joined to their run for display (sidebar approve/reject).
    pub fn list_pending_approvals(&self) -> Result<Vec<PendingApproval>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT a.key, json_extract(a.action_params,'$.run_key'), a.agent_key,
                    r.task, r.message_key, a.created_at
             FROM agent_approvals a
             LEFT JOIN agent_runs r ON r.key = json_extract(a.action_params,'$.run_key')
             WHERE a.status = ?1
             ORDER BY a.id DESC",
        )?;
        let rows = stmt.query_map(params![ApprovalStatus::Pending.as_str()], |r| {
            Ok(PendingApproval {
                approval_key: r.get(0)?,
                run_key: r.get(1)?,
                adapter_id: r.get(2)?,
                task: r.get(3)?,
                message_key: r.get(4)?,
                created_at: r.get(5)?,
            })
        })?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    // ─── Audit ───────────────────────────────────────────────────────────────

    pub fn audit(
        &self,
        adapter_id: &str,
        params_json: &str,
        result_summary: &str,
        status: AuditStatus,
        error: Option<&str>,
        duration_ms: i64,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO agent_audit_log
               (agent_key, action_type, action_params, result_summary, status, error_message, duration_ms, created_at)
             VALUES (?1, ?8, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                adapter_id,
                params_json,
                result_summary,
                status.as_str(),
                error,
                duration_ms,
                chrono::Utc::now().to_rfc3339(),
                AgentActionType::RunAgent.as_str(),
            ],
        )?;
        Ok(())
    }

    // ─── New-message scan (Tier-0 enqueue source) ────────────────────────────

    /// Read the watermark of the last messages.id processed by the filter scan.
    pub fn scan_cursor(&self) -> i64 {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT value FROM vector_settings WHERE key = ?1",
            params![CURSOR_KEY],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
    }

    pub fn set_scan_cursor(&self, id: i64) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO vector_settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![CURSOR_KEY, id.to_string()],
        )?;
        Ok(())
    }

    /// Inbound messages newer than `after_id`, with the fields Tier-0 needs.
    pub fn messages_after(&self, after_id: i64, limit: i64) -> Result<Vec<ScannedMessage>> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare(&format!("{SCAN_SELECT} AND m.id > ?1 ORDER BY m.id ASC LIMIT ?2"))?;
        let rows = stmt.query_map(params![after_id, limit], map_scanned)?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    /// The most recent `limit` inbound messages (newest first). Backs the rule
    /// editor's existing-mail preview and the apply-to-existing backfill, which
    /// both look backwards over current mail rather than forward from the cursor.
    pub fn recent_inbound(&self, limit: i64) -> Result<Vec<ScannedMessage>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!("{SCAN_SELECT} ORDER BY m.id DESC LIMIT ?1"))?;
        let rows = stmt.query_map(params![limit], map_scanned)?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    /// Inbound messages of one conversation (newest first) — the routing panel's
    /// manual "Run" applies a rule to just the open conversation.
    pub fn conversation_messages(
        &self,
        conversation_key: &str,
        limit: i64,
    ) -> Result<Vec<ScannedMessage>> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare(&format!("{SCAN_SELECT} AND m.conversation_key = ?1 ORDER BY m.id DESC LIMIT ?2"))?;
        let rows = stmt.query_map(params![conversation_key, limit], map_scanned)?;
        Ok(rows.filter_map(|x| x.ok()).collect())
    }

    /// Existing inbound messages whose envelope satisfies a rule's Tier-0
    /// conditions — the editor's "which existing emails would this affect?" review
    /// step. Scans the most recent `scan_limit` messages (newest first) and returns
    /// up to `sample_limit` previews, the total matched, and how many were examined
    /// (so the UI can flag a capped scan). Tier-0 only — a rule's optional Tier-1
    /// gate is not applied here (rules built in the editor never set one).
    pub fn preview_rule_matches(
        &self,
        rule: &LocalRule,
        sample_limit: usize,
        scan_limit: i64,
    ) -> Result<(Vec<MatchPreview>, usize, usize)> {
        let msgs = self.recent_inbound(scan_limit)?;
        let scanned = msgs.len();
        let mut samples = Vec::new();
        let mut total = 0usize;
        for m in &msgs {
            if let Some(acc) = &rule.account_key {
                if acc != &m.account_key {
                    continue;
                }
            }
            if !conditions_match(&rule.conditions, &m.fields) {
                continue;
            }
            total += 1;
            if samples.len() < sample_limit {
                samples.push(MatchPreview {
                    message_key: m.message_key.clone(),
                    conversation_key: m.conversation_key.clone(),
                    account_key: m.account_key.clone(),
                    from: m.fields.from.clone(),
                    subject: m.fields.subject.clone(),
                    date: m.created_at.clone(),
                    has_attachment: m.fields.has_attachment,
                });
            }
        }
        Ok((samples, total, scanned))
    }

    /// Build the harness input for a message (reconstructs a minimal RFC822).
    pub fn message_input(&self, message_key: &str) -> Result<Option<MessageInput>> {
        let conn = self.conn.lock();
        let row = conn
            .query_row(
                "SELECT COALESCE(account_key,''), COALESCE(from_address,''),
                        COALESCE(to_address,''), COALESCE(cc_address,''),
                        COALESCE(subject,''), COALESCE(body_plain,''),
                        COALESCE(body_html,''), COALESCE(created_at,'')
                 FROM messages WHERE key = ?1",
                params![message_key],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, String>(5)?,
                        r.get::<_, String>(6)?,
                        r.get::<_, String>(7)?,
                    ))
                },
            )
            .optional()?;
        let Some((account, from, to, cc, subject, body_plain, body_html, date)) = row else {
            return Ok(None);
        };
        let eml = format!(
            "From: {from}\r\nTo: {to}\r\nCc: {cc}\r\nSubject: {subject}\r\nDate: {date}\r\n\r\n{}",
            if body_plain.is_empty() {
                &body_html
            } else {
                &body_plain
            }
        )
        .into_bytes();
        Ok(Some(MessageInput {
            message_key: message_key.to_string(),
            account_key: account,
            from,
            to,
            cc,
            subject,
            date,
            body_plain,
            body_html,
            eml,
            attachments: Vec::<HarnessAttachment>::new(),
        }))
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PendingApproval {
    pub approval_key: String,
    pub run_key: Option<String>,
    pub adapter_id: String,
    pub task: Option<String>,
    pub message_key: Option<String>,
    pub created_at: String,
}

#[derive(Debug)]
pub struct ScannedMessage {
    pub id: i64,
    pub message_key: String,
    pub conversation_key: String,
    pub account_key: String,
    pub created_at: String,
    pub fields: MessageFields,
}

/// One existing message matched by a rule's Tier-0 conditions, with just the
/// fields the editor's preview needs to render a row.
#[derive(Debug, Clone, serde::Serialize)]
pub struct MatchPreview {
    pub message_key: String,
    pub conversation_key: String,
    pub account_key: String,
    pub from: String,
    pub subject: String,
    pub date: String,
    pub has_attachment: bool,
}

/// The inbound-message scan projection shared by `messages_after` (cursor scan),
/// `recent_inbound`, and the preview. has_attachment lives on the conversation,
/// not the message row, so it's joined in; created_at is selected for the preview.
/// Callers append the row filter (`AND m.id > ?`), ordering, and LIMIT.
const SCAN_SELECT: &str = "SELECT m.id, m.key, COALESCE(m.conversation_key,''), COALESCE(m.account_key,''),
            COALESCE(m.from_address,''), COALESCE(m.to_address,''), COALESCE(m.subject,''),
            COALESCE(m.body_plain, m.body_html, ''), COALESCE(c.has_attachment, 0),
            COALESCE(m.created_at,'')
     FROM messages m
     LEFT JOIN conversations c ON c.key = m.conversation_key
     WHERE COALESCE(m.is_inbound,1) = 1 AND COALESCE(m.is_draft,0) = 0";

fn map_scanned(r: &rusqlite::Row) -> rusqlite::Result<ScannedMessage> {
    Ok(ScannedMessage {
        id: r.get(0)?,
        message_key: r.get(1)?,
        conversation_key: r.get(2)?,
        account_key: r.get(3)?,
        created_at: r.get(9)?,
        fields: MessageFields {
            from: r.get(4)?,
            to: r.get(5)?,
            subject: r.get(6)?,
            body: r.get(7)?,
            has_attachment: r.get::<_, i64>(8)? != 0,
        },
    })
}

const RUN_SELECT: &str = "SELECT key, rule_key, message_key, account_key, adapter_id, task,
       permission_mode, status, attempts, timeout_s, scratch_dir, result_json,
       exit_code, cost_usd, input_tokens, output_tokens, error, started_at, finished_at, duration_ms, created_at, updated_at
       FROM agent_runs";

fn map_run(r: &rusqlite::Row) -> rusqlite::Result<AgentRunRow> {
    Ok(AgentRunRow {
        key: r.get(0)?,
        rule_key: r.get(1)?,
        message_key: r.get(2)?,
        account_key: r.get(3)?,
        adapter_id: r.get(4)?,
        task: r.get(5)?,
        permission_mode: r.get(6)?,
        status: r.get(7)?,
        attempts: r.get(8)?,
        timeout_s: r.get(9)?,
        scratch_dir: r.get(10)?,
        result_json: r.get(11)?,
        exit_code: r.get(12)?,
        cost_usd: r.get(13)?,
        input_tokens: r.get(14)?,
        output_tokens: r.get(15)?,
        error: r.get(16)?,
        started_at: r.get(17)?,
        finished_at: r.get(18)?,
        duration_ms: r.get(19)?,
        created_at: r.get(20)?,
        updated_at: r.get(21)?,
    })
}

fn row_by_key(conn: &Connection, key: &str) -> Result<Option<AgentRunRow>> {
    let row = conn
        .query_row(
            &format!("{RUN_SELECT} WHERE key = ?1"),
            params![key],
            map_run,
        )
        .optional()?;
    Ok(row)
}

fn placeholder_action() -> RuleAction {
    RuleAction {
        action_type: "run_agent".into(),
        builtin: None,
        quadrant: None,
        reply: None,
        adapter_id: String::new(),
        task: String::new(),
        permission_mode: "approval_first".into(),
        timeout_s: 120,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> AgentRunStore {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, conversation_key TEXT,
               account_key TEXT, from_address TEXT, to_address TEXT, cc_address TEXT, subject TEXT,
               body_plain TEXT, body_html TEXT, is_inbound INTEGER DEFAULT 1, is_draft INTEGER DEFAULT 0,
               created_at TEXT);
             CREATE TABLE conversations (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, has_attachment INTEGER DEFAULT 0);
             CREATE TABLE local_agents (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, adapter_id TEXT UNIQUE,
               display_name TEXT, binary_path TEXT, version TEXT, enabled INTEGER DEFAULT 0,
               last_detected_at TEXT, created_at TEXT, updated_at TEXT);
             CREATE TABLE local_rules (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, name TEXT,
               account_key TEXT, conditions TEXT, ai_gate TEXT, action TEXT, enabled INTEGER DEFAULT 1,
               created_at TEXT, updated_at TEXT);
             CREATE TABLE agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, rule_key TEXT,
               message_key TEXT, account_key TEXT, adapter_id TEXT, task TEXT, permission_mode TEXT,
               status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, timeout_s INTEGER DEFAULT 120,
               scratch_dir TEXT, result_json TEXT, exit_code INTEGER, cost_usd REAL,
               input_tokens INTEGER, output_tokens INTEGER, error TEXT,
               started_at TEXT, finished_at TEXT, duration_ms INTEGER, created_at TEXT, updated_at TEXT);
             CREATE TABLE agent_audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_key TEXT, action_type TEXT,
               action_params TEXT, result_summary TEXT, status TEXT, error_message TEXT, duration_ms INTEGER, created_at TEXT);
             CREATE TABLE agent_approvals (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, agent_key TEXT,
               action_type TEXT, action_params TEXT, status TEXT DEFAULT 'pending', user_note TEXT,
               expires_at TEXT, resolved_at TEXT, created_at TEXT);
             CREATE TABLE vector_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO vector_settings VALUES ('agentic_filters_enabled','true');",
        )
        .unwrap();
        AgentRunStore::new(Arc::new(Mutex::new(conn)))
    }

    fn enqueue(store: &AgentRunStore, mode: &str, rule_key: Option<&str>) -> String {
        store
            .enqueue_run(&EnqueueRun {
                rule_key: rule_key.map(String::from),
                message_key: "msg_1".into(),
                account_key: "acc_1".into(),
                adapter_id: "claude-code".into(),
                task: "t".into(),
                permission_mode: mode.into(),
                timeout_s: 60,
            })
            .unwrap()
    }

    #[test]
    fn full_auto_enqueues_pending_and_claims_to_running() {
        let store = setup();
        let key = enqueue(&store, "full_auto", None);
        let claimed = store.claim_next_pending().unwrap().unwrap();
        assert_eq!(claimed.key, key);
        assert_eq!(claimed.status, "running");
        assert_eq!(claimed.attempts, 1);
        assert!(store.claim_next_pending().unwrap().is_none(), "no double-claim");
    }

    #[test]
    fn approval_first_waits_then_runs_on_approve() {
        let store = setup();
        enqueue(&store, "approval_first", Some("lrul_x"));
        // Not claimable while awaiting approval.
        assert!(store.claim_next_pending().unwrap().is_none());
        let runs = store.list_runs(None, 10).unwrap();
        assert_eq!(runs[0].status, "awaiting_approval");
        // Approve the pending approval row.
        let appr_key: String = {
            let conn = store.conn.lock();
            conn.query_row("SELECT key FROM agent_approvals LIMIT 1", [], |r| r.get(0))
                .unwrap()
        };
        store.resolve_approval(&appr_key, true).unwrap();
        let claimed = store.claim_next_pending().unwrap().unwrap();
        assert_eq!(claimed.status, "running");
    }

    #[test]
    fn approval_skipped_after_a_prior_success() {
        let store = setup();
        let k1 = enqueue(&store, "approval_first", Some("lrul_y"));
        store
            .finish_run(&k1, RunStatus::Succeeded, None, Some(0), RunMetrics::default(), None, 5, None)
            .unwrap();
        // Second firing of the same rule should skip approval → pending immediately.
        enqueue(&store, "approval_first", Some("lrul_y"));
        assert!(store.claim_next_pending().unwrap().is_some());
    }

    #[test]
    fn retry_cap_enforced() {
        let store = setup();
        let key = enqueue(&store, "full_auto", None);
        for _ in 0..MAX_ATTEMPTS {
            let _ = store.claim_next_pending().unwrap();
            // simulate failure → bump attempts already happened on claim
            store.requeue_if_retriable(&key).ok();
        }
        // attempts now >= MAX after claims; requeue refuses.
        // Drain to running to bump attempts to the cap.
        while store.claim_next_pending().unwrap().is_some() {}
        assert!(!store.requeue_if_retriable(&key).unwrap());
    }

    #[test]
    fn rules_round_trip() {
        let store = setup();
        let rule = LocalRule {
            key: String::new(),
            name: "Invoices".into(),
            account_key: None,
            conditions: vec![Condition {
                field: "from".into(),
                op: "contains".into(),
                value: "billing@acme.com".into(),
            }],
            ai_gate: None,
            action: RuleAction {
                action_type: "run_agent".into(),
                builtin: None,
                quadrant: None,
                reply: None,
                adapter_id: "claude-code".into(),
                task: "extract".into(),
                permission_mode: "approval_first".into(),
                timeout_s: 90,
            },
            enabled: true,
        };
        let key = store.upsert_rule(&rule).unwrap();
        let listed = store.list_rules().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].key, key);
        assert_eq!(listed[0].action.adapter_id, "claude-code");
        store.delete_rule(&key).unwrap();
        assert!(store.list_rules().unwrap().is_empty());
    }

    #[test]
    fn record_action_run_inserts_terminal_run() {
        let store = setup();
        let key = store
            .record_action_run(
                "rul_x",
                "msg_1",
                "acc_1",
                "archive",
                RunStatus::Succeeded,
                Some("archived"),
                None,
            )
            .unwrap();
        let runs = store.list_runs(Some("msg_1"), 50).unwrap();
        assert_eq!(runs.len(), 1);
        let r = &runs[0];
        assert_eq!(r.key, key);
        assert_eq!(r.rule_key.as_deref(), Some("rul_x"));
        assert_eq!(r.adapter_id, "archive");
        assert_eq!(r.status, "succeeded");
        assert_eq!(r.result_json.as_deref(), Some("archived"));
        assert!(r.finished_at.is_some());
    }

    #[test]
    fn perform_action_rule_round_trips() {
        // A "perform_action" rule omits adapter_id/task/permission_mode in its JSON;
        // the serde defaults must let it deserialize so it round-trips intact.
        let store = setup();
        let json = r#"{"type":"perform_action","builtin":"archive"}"#;
        let action: RuleAction = serde_json::from_str(json).unwrap();
        let rule = LocalRule {
            key: String::new(),
            name: "Archive newsletters".into(),
            account_key: None,
            conditions: vec![Condition {
                field: "subject".into(),
                op: "contains".into(),
                value: "newsletter".into(),
            }],
            ai_gate: None,
            action,
            enabled: true,
        };
        let key = store.upsert_rule(&rule).unwrap();
        let listed = store.list_rules().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].action.action_type, "perform_action");
        assert_eq!(listed[0].action.builtin.as_deref(), Some("archive"));
        assert!(listed[0].action.adapter_id.is_empty());
        store.delete_rule(&key).unwrap();
    }

    #[test]
    fn message_scan_and_input_reconstruction() {
        let store = setup();
        {
            let conn = store.conn.lock();
            conn.execute(
                "INSERT INTO messages (key, account_key, from_address, to_address, subject, body_plain, created_at)
                 VALUES ('msg_1','acc_1','billing@acme.com','me@x.com','Invoice #42','pay up','2026-06-06')",
                [],
            )
            .unwrap();
        }
        let scanned = store.messages_after(0, 50).unwrap();
        assert_eq!(scanned.len(), 1);
        assert_eq!(scanned[0].fields.from, "billing@acme.com");
        store.set_scan_cursor(scanned[0].id).unwrap();
        assert_eq!(store.scan_cursor(), scanned[0].id);
        assert!(store.messages_after(store.scan_cursor(), 50).unwrap().is_empty());

        let input = store.message_input("msg_1").unwrap().unwrap();
        assert_eq!(input.subject, "Invoice #42");
        assert!(String::from_utf8_lossy(&input.eml).contains("Subject: Invoice #42"));
    }

    #[test]
    fn get_rule_fetches_one_or_none() {
        let store = setup();
        assert!(store.get_rule("lrul_missing").unwrap().is_none());
        let key = store
            .upsert_rule(&LocalRule {
                key: String::new(),
                name: "Newsletters".into(),
                account_key: Some("acc_1".into()),
                conditions: vec![Condition {
                    field: "subject".into(),
                    op: "contains".into(),
                    value: "newsletter".into(),
                }],
                ai_gate: None,
                action: placeholder_action(),
                enabled: true,
            })
            .unwrap();
        let got = store.get_rule(&key).unwrap().unwrap();
        assert_eq!(got.key, key);
        assert_eq!(got.account_key.as_deref(), Some("acc_1"));
        assert_eq!(got.conditions.len(), 1);
    }

    #[test]
    fn preview_rule_matches_counts_and_samples_existing_mail() {
        let store = setup();
        {
            let conn = store.conn.lock();
            for i in 0..3 {
                conn.execute(
                    "INSERT INTO messages (key, account_key, from_address, subject, body_plain, created_at)
                     VALUES (?1,'acc_1','billing@acme.com',?2,'body','2026-06-0' || ?3)",
                    params![format!("mb_{i}"), format!("Invoice #{i}"), i + 1],
                )
                .unwrap();
            }
            // A non-matching message and a different-account match.
            conn.execute(
                "INSERT INTO messages (key, account_key, from_address, subject)
                 VALUES ('mx','acc_1','newsletter@x.com','Weekly digest')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, account_key, from_address, subject)
                 VALUES ('mo','acc_2','billing@acme.com','Invoice other')",
                [],
            )
            .unwrap();
        }
        let rule = LocalRule {
            key: "lrul_p".into(),
            name: "Acme billing".into(),
            account_key: Some("acc_1".into()),
            conditions: vec![Condition {
                field: "from".into(),
                op: "contains".into(),
                value: "billing@acme.com".into(),
            }],
            ai_gate: None,
            action: placeholder_action(),
            enabled: true,
        };
        // Sample cap of 2: 3 acc_1 matches counted, 2 sampled; acc_2 match excluded.
        let (samples, total, scanned) = store.preview_rule_matches(&rule, 2, 5000).unwrap();
        assert_eq!(total, 3);
        assert_eq!(samples.len(), 2);
        assert!(samples.iter().all(|s| s.from.contains("billing@acme.com")));
        assert_eq!(scanned, 5); // every inbound message was examined

        // No account scope → both billing messages (acc_1 ×3 + acc_2 ×1) match.
        let mut all_accounts = rule.clone();
        all_accounts.account_key = None;
        let (_, total_all, _) = store.preview_rule_matches(&all_accounts, 10, 5000).unwrap();
        assert_eq!(total_all, 4);
    }

    #[test]
    fn failed_runs_are_findable_by_status() {
        let store = setup();
        let ok = enqueue(&store, "full_auto", None);
        let bad = enqueue(&store, "full_auto", None);
        store.finish_run(&ok, RunStatus::Succeeded, None, Some(0), RunMetrics::default(), None, 1, None).unwrap();
        store
            .finish_run(&bad, RunStatus::Failed, None, Some(1), RunMetrics::default(), Some("attachment download failed"), 1, None)
            .unwrap();
        let failures = store.list_runs_by_status(&["failed", "timeout"], 50).unwrap();
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].key, bad);
        assert_eq!(failures[0].error.as_deref(), Some("attachment download failed"));
    }

    #[test]
    fn has_attachment_is_joined_from_conversation() {
        let store = setup();
        {
            let conn = store.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, has_attachment) VALUES ('conv_1', 1)",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, account_key, from_address, subject)
                 VALUES ('msg_a','conv_1','acc_1','billing@acme.com','Invoice')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, account_key, from_address, subject)
                 VALUES ('msg_b','acc_1','x@y.com','hi')",
                [],
            )
            .unwrap();
        }
        let scanned = store.messages_after(0, 50).unwrap();
        let by_key = |k: &str| scanned.iter().find(|m| m.message_key == k).unwrap();
        assert!(by_key("msg_a").fields.has_attachment);
        assert!(!by_key("msg_b").fields.has_attachment); // no conversation → false
    }

    #[test]
    fn pending_approvals_join_their_run() {
        let store = setup();
        enqueue(&store, "approval_first", Some("lrul_z"));
        let pending = store.list_pending_approvals().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].adapter_id, "claude-code");
        assert!(pending[0].run_key.is_some());
        assert_eq!(pending[0].task.as_deref(), Some("t"));
        // Resolving clears it from the pending list.
        store.resolve_approval(&pending[0].approval_key, true).unwrap();
        assert!(store.list_pending_approvals().unwrap().is_empty());
    }

    #[test]
    fn detection_preserves_enabled_flag() {
        let store = setup();
        let d = DetectedAgent {
            adapter_id: "claude-code".into(),
            display_name: "Claude Code".into(),
            binary: "claude".into(),
            install_url: "url".into(),
            installed: true,
            binary_path: Some("/usr/bin/claude".into()),
            version: Some("2.1".into()),
            supports_allowlist: true,
        };
        store.upsert_detection(&d).unwrap();
        store.set_enabled("claude-code", true).unwrap();
        // Re-detect (e.g. version bump) must NOT reset the enabled flag.
        let mut d2 = d.clone();
        d2.version = Some("2.2".into());
        store.upsert_detection(&d2).unwrap();
        assert!(store.is_enabled("claude-code"));
    }

    #[test]
    fn schema_helpers_detect_table_and_column() {
        let store = setup();
        let conn = store.conn.lock();
        assert!(table_exists(&conn, "agent_runs").unwrap());
        assert!(!table_exists(&conn, "no_such_table").unwrap());
        assert!(column_exists(&conn, "agent_runs", "timeout_s").unwrap());
        assert!(!column_exists(&conn, "agent_runs", "no_such_col").unwrap());
    }

    #[test]
    fn stale_agent_runs_missing_timeout_is_detected() {
        // A pre-`timeout_s` agent_runs from an older build — the case that broke
        // list_runs_by_status. ensure_schema keys its heal off exactly this check.
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE,
               attempts INTEGER, status TEXT);",
        )
        .unwrap();
        assert!(table_exists(&conn, "agent_runs").unwrap());
        assert!(!column_exists(&conn, "agent_runs", "timeout_s").unwrap());
    }

    #[test]
    fn ensure_schema_is_noop_and_preserves_data_when_current() {
        // setup()'s tables already carry the current columns, so ensure_schema must
        // NOT drop anything — enqueued runs survive.
        let store = setup();
        let key = enqueue(&store, "full_auto", None);
        store.ensure_schema().unwrap();
        let conn = store.conn.lock();
        assert!(row_by_key(&conn, &key).unwrap().is_some());
    }
}

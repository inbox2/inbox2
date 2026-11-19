// Tauri IPC surface for agentic filters. See docs/Agentic-Filters.md §5.3.

use std::sync::Arc;

use tauri::State;

use super::adapter::DetectedAgent;
use super::detect::detect_all;
use super::runner::AgentRunner;
use super::store::{
    AgentRunRow, AgentRunStore, EnqueueRun, LocalRule, MatchPreview, PendingApproval, RunStatus,
};

pub struct LocalAgentState {
    pub store: Arc<AgentRunStore>,
    /// The background runner — also drives the "apply to existing" backfill, which
    /// needs the sync + on-device engines the runner holds (the store can't act).
    pub runner: Arc<AgentRunner>,
}

/// A detected agent (its fields flattened in) merged with the stored enable flag.
#[derive(serde::Serialize)]
pub struct LocalAgentInfo {
    #[serde(flatten)]
    pub detected: DetectedAgent,
    pub enabled: bool,
}

/// Probe PATH for every shipped agent, persist the detection, and return each one
/// merged with its stored enable flag. Pure read of the filesystem.
#[tauri::command]
pub async fn detect_local_agents(
    state: State<'_, LocalAgentState>,
) -> Result<Vec<LocalAgentInfo>, String> {
    let detected = detect_all();
    let mut out = Vec::with_capacity(detected.len());
    for d in detected {
        let _ = state.store.upsert_detection(&d);
        // A not-installed agent can't be enabled.
        let enabled = state.store.is_enabled(&d.adapter_id) && d.installed;
        out.push(LocalAgentInfo { detected: d, enabled });
    }
    Ok(out)
}

#[tauri::command]
pub async fn set_local_agent_enabled(
    state: State<'_, LocalAgentState>,
    adapter_id: String,
    enabled: bool,
) -> Result<(), String> {
    state
        .store
        .set_enabled(&adapter_id, enabled)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_local_rules(state: State<'_, LocalAgentState>) -> Result<Vec<LocalRule>, String> {
    state.store.list_rules().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn upsert_local_rule(
    state: State<'_, LocalAgentState>,
    rule: LocalRule,
) -> Result<String, String> {
    state.store.upsert_rule(&rule).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_local_rule(
    state: State<'_, LocalAgentState>,
    key: String,
) -> Result<(), String> {
    state.store.delete_rule(&key).map_err(|e| e.to_string())
}

/// Existing-mail match preview for the rule editor's review step. `total` is the
/// number of current messages matching the rule's conditions; `samples` is a
/// capped display slice; `scanned_capped` is true when the scan hit its examine
/// limit, so the counts are a lower bound.
#[derive(serde::Serialize)]
pub struct RulePreview {
    pub samples: Vec<MatchPreview>,
    pub total: usize,
    pub scanned_capped: bool,
}

/// Which existing emails a (possibly unsaved) rule would affect. Read-only — runs
/// the rule's Tier-0 conditions against current local-channel mail; mutates
/// nothing. Powers the wizard's "Review" step.
#[tauri::command]
pub async fn preview_rule_matches(
    state: State<'_, LocalAgentState>,
    rule: LocalRule,
) -> Result<RulePreview, String> {
    const SAMPLE_LIMIT: usize = 12;
    const SCAN_LIMIT: i64 = 5000;
    let (samples, total, scanned) = state
        .store
        .preview_rule_matches(&rule, SAMPLE_LIMIT, SCAN_LIMIT)
        .map_err(|e| e.to_string())?;
    Ok(RulePreview {
        samples,
        total,
        scanned_capped: scanned as i64 >= SCAN_LIMIT,
    })
}

/// Run a saved rule's action against existing matching mail (the wizard's "apply
/// to existing emails" option on a persisted rule). Returns the number acted on.
#[tauri::command]
pub async fn apply_rule_to_existing(
    state: State<'_, LocalAgentState>,
    rule_key: String,
) -> Result<usize, String> {
    const SCAN_LIMIT: i64 = 5000;
    state
        .runner
        .apply_rule_to_existing(&rule_key, SCAN_LIMIT)
        .await
}

/// Run an unsaved rule's action against existing matching mail once, without
/// persisting the rule (the wizard's "run once": apply to existing with "apply to
/// new" off). Returns the number of messages acted on.
#[tauri::command]
pub async fn run_rule_once(
    state: State<'_, LocalAgentState>,
    rule: LocalRule,
) -> Result<usize, String> {
    const SCAN_LIMIT: i64 = 5000;
    state.runner.run_rule_once(rule, SCAN_LIMIT).await
}

/// Run a saved rule against a single conversation now (the routing panel's manual
/// "Run" for a matched rule that hasn't fired on this conversation yet). Returns
/// the number of messages acted on.
#[tauri::command]
pub async fn run_rule_on_conversation(
    state: State<'_, LocalAgentState>,
    rule_key: String,
    conversation_key: String,
) -> Result<usize, String> {
    state
        .runner
        .run_rule_on_conversation(&rule_key, &conversation_key)
        .await
}

/// Run an agent against one message right now, bypassing rules. Powers the
/// settings "Test run" button. Returns the run key to poll.
#[tauri::command]
pub async fn test_run_agent(
    state: State<'_, LocalAgentState>,
    adapter_id: String,
    message_key: String,
    account_key: String,
    task: String,
    permission_mode: String,
) -> Result<String, String> {
    state
        .store
        .enqueue_run(&EnqueueRun {
            rule_key: None,
            message_key,
            account_key,
            adapter_id,
            task,
            permission_mode,
            timeout_s: 120,
        })
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_agent_runs(
    state: State<'_, LocalAgentState>,
    conversation_key: Option<String>,
    message_key: Option<String>,
    limit: Option<i64>,
) -> Result<Vec<AgentRunRow>, String> {
    let limit = limit.unwrap_or(50);
    let result = match conversation_key {
        Some(ck) => state.store.list_runs_for_conversation(&ck, limit),
        None => state.store.list_runs(message_key.as_deref(), limit),
    };
    result.map_err(|e| e.to_string())
}

/// All runs that broke (failed or timed out), newest first — the "find failed
/// processes" view. See docs/Agentic-Filters.md §5.2.
#[tauri::command]
pub async fn list_failed_agent_runs(
    state: State<'_, LocalAgentState>,
    limit: Option<i64>,
) -> Result<Vec<AgentRunRow>, String> {
    state
        .store
        .list_runs_by_status(&[RunStatus::Failed.as_str(), RunStatus::Timeout.as_str()], limit.unwrap_or(100))
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn retry_agent_run(
    state: State<'_, LocalAgentState>,
    run_key: String,
) -> Result<(), String> {
    state.store.retry_run(&run_key).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_agent_approvals(
    state: State<'_, LocalAgentState>,
) -> Result<Vec<PendingApproval>, String> {
    state.store.list_pending_approvals().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resolve_agent_approval(
    state: State<'_, LocalAgentState>,
    approval_key: String,
    approved: bool,
) -> Result<(), String> {
    state
        .store
        .resolve_approval(&approval_key, approved)
        .map_err(|e| e.to_string())
}

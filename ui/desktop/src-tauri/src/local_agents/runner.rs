// AgentRunner — the background worker. Scans new local-channel mail against
// enabled rules (Tier 0), enqueues matches, and drains the agent_runs queue:
// build scratch → spawn the CLI agent with a hard timeout → evaluate result.json
// → audit + retry. See docs/Agentic-Filters.md §5.1.

use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use inbox2_core::rules::OnDeviceAi;

use crate::sync::engine::SyncEngine;
use crate::vector::search::cosine_similarity;

use super::actions::{self, BuiltinAction};
use super::adapter::{AgentActionType, PermissionMode};
use super::adapters::adapter_for;
use super::gate::{embed_text, parse_gate, AiGate};
use super::harness::{build_scratch, evaluate_result, HarnessAttachment, MessageInput, RunOutcome};
use super::rules::conditions_match;
use super::store::{
    AgentRunRow, AgentRunStore, AuditStatus, EnqueueRun, LocalRule, RunMetrics, RunStatus,
    ScannedMessage,
};

const POLL_INTERVAL: Duration = Duration::from_secs(5);
const SCAN_BATCH: i64 = 200;
const PUMP_THREAD_SLEEP: Duration = Duration::from_millis(50);

pub struct AgentRunner {
    store: Arc<AgentRunStore>,
    base_dir: PathBuf,
    /// On-device engine for the Tier-1 gate. None disables gating (gates fail closed).
    engine: Option<Arc<dyn OnDeviceAi>>,
    /// Sync engine for fetching the raw message + attachments on a match.
    sync_engine: Option<Arc<SyncEngine>>,
}

impl AgentRunner {
    pub fn new(
        store: Arc<AgentRunStore>,
        app_data_dir: &std::path::Path,
        engine: Option<Arc<dyn OnDeviceAi>>,
        sync_engine: Option<Arc<SyncEngine>>,
    ) -> Self {
        Self {
            store,
            base_dir: app_data_dir.join("agent_runs"),
            engine,
            sync_engine,
        }
    }

    /// Long-lived loop. Spawn via `tauri::async_runtime::spawn`.
    pub async fn run(&self) {
        log::info!("Agent runner started");
        // The engine pings this after a sync brings in new mail, so a
        // (cloud-push-driven) resync applies rules immediately instead of waiting
        // out the poll interval. Falls back to pure polling if there's no engine.
        let scan_signal = self.sync_engine.as_ref().map(|e| e.rules_scan_notify());
        loop {
            if self.store.filters_enabled() {
                if let Err(e) = self.scan_and_enqueue().await {
                    log::warn!("agent filter scan error: {e}");
                }
            }
            // Always drain — picks up test runs and just-approved runs even when
            // background scanning is off.
            self.drain_queue().await;
            // Wake on whichever comes first: the next poll tick, or the engine
            // signalling that a sync just landed new mail.
            match &scan_signal {
                Some(notify) => {
                    tokio::select! {
                        _ = tokio::time::sleep(POLL_INTERVAL) => {}
                        _ = notify.notified() => {}
                    }
                }
                None => tokio::time::sleep(POLL_INTERVAL).await,
            }
        }
    }

    /// Tier-0 (static) then Tier-1 (on-device gate) before enqueuing a run.
    async fn scan_and_enqueue(&self) -> Result<(), String> {
        let cursor = self.store.scan_cursor();
        let msgs = self
            .store
            .messages_after(cursor, SCAN_BATCH)
            .map_err(|e| e.to_string())?;
        if msgs.is_empty() {
            return Ok(());
        }
        let rules = self.store.list_rules().map_err(|e| e.to_string())?;
        // Cache each distinct gate phrase's embedding across the whole scan pass so
        // a rule's phrase is embedded once, not per matching message.
        let mut phrase_emb: HashMap<String, Option<Vec<f32>>> = HashMap::new();
        let mut max_id = cursor;
        for m in &msgs {
            max_id = max_id.max(m.id);
            // The message embedding is the same for every gate on this message —
            // compute it at most once.
            let mut msg_emb: Option<Option<Vec<f32>>> = None;
            for rule in &rules {
                self.maybe_apply_rule(rule, m, &mut phrase_emb, &mut msg_emb).await;
            }
        }
        self.store.set_scan_cursor(max_id).map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Evaluate one rule against one message — Tier-0 conditions, then the Tier-1
    /// on-device gate when set — and act on a match (enqueue an agent run or run
    /// the built-in action). Shared by the live scan and the apply-to-existing
    /// backfill so both fire rules identically. Returns true if the rule fired.
    async fn maybe_apply_rule(
        &self,
        rule: &LocalRule,
        m: &ScannedMessage,
        phrase_emb: &mut HashMap<String, Option<Vec<f32>>>,
        msg_emb: &mut Option<Option<Vec<f32>>>,
    ) -> bool {
        if !rule.enabled {
            return false;
        }
        if let Some(acc) = &rule.account_key {
            if acc != &m.account_key {
                return false;
            }
        }
        if !conditions_match(&rule.conditions, &m.fields) {
            return false;
        }
        // Tier 1: on-device gate, applied to every action kind. Fail-closed — if a
        // gate is set but can't run (no engine / models not loaded), don't act.
        if let Some(g) = parse_gate(rule.ai_gate.as_ref()) {
            if !self.passes_gate(&g, m, phrase_emb, msg_emb).await {
                log::info!("rule {} Tier-1 gate skipped msg {}", rule.key, m.message_key);
                return false;
            }
        }

        match AgentActionType::parse(&rule.action.action_type) {
            Some(AgentActionType::RunAgent) => {
                if !self.store.is_enabled(&rule.action.adapter_id) {
                    log::info!(
                        "rule {} matched but agent {} is disabled — skipping",
                        rule.key,
                        rule.action.adapter_id
                    );
                    return false;
                }
                match self.store.enqueue_run(&EnqueueRun {
                    // A keyless rule (a one-time "run once") associates no runs and
                    // skips approval gating — it's an explicit, single user action.
                    rule_key: (!rule.key.is_empty()).then(|| rule.key.clone()),
                    message_key: m.message_key.clone(),
                    account_key: m.account_key.clone(),
                    adapter_id: rule.action.adapter_id.clone(),
                    task: rule.action.task.clone(),
                    permission_mode: rule.action.permission_mode.clone(),
                    timeout_s: rule.action.timeout_s,
                }) {
                    Ok(key) => {
                        log::info!("rule {} matched msg {} → run {}", rule.key, m.message_key, key);
                        true
                    }
                    Err(e) => {
                        log::warn!("rule {} enqueue failed for msg {}: {e}", rule.key, m.message_key);
                        false
                    }
                }
            }
            Some(AgentActionType::PerformAction) => {
                self.run_builtin_action(rule, m).await;
                true
            }
            None => {
                log::warn!(
                    "rule {} has unknown action type {:?}",
                    rule.key,
                    rule.action.action_type
                );
                false
            }
        }
    }

    /// Apply a saved rule to existing mail — the wizard's "apply to existing
    /// emails" backfill, keyed by the just-saved rule. Runs regardless of the
    /// rule's enabled flag (an explicit action): a rule can be saved disabled for
    /// new mail yet still get a one-time existing-mail pass.
    pub async fn apply_rule_to_existing(
        &self,
        rule_key: &str,
        scan_limit: i64,
    ) -> Result<usize, String> {
        let mut rule = self
            .store
            .get_rule(rule_key)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "rule not found".to_string())?;
        rule.enabled = true;
        let acted = self.apply_rule_existing(&rule, scan_limit).await?;
        log::info!("apply_rule_to_existing {rule_key}: fired on {acted} message(s)");
        Ok(acted)
    }

    /// Apply an *unsaved* rule definition to existing mail once, without persisting
    /// it — the wizard's "run once" (apply to existing with "apply to new" off).
    /// The key is cleared so enqueued runs carry no rule association and skip
    /// approval gating.
    pub async fn run_rule_once(&self, mut rule: LocalRule, scan_limit: i64) -> Result<usize, String> {
        rule.enabled = true;
        rule.key = String::new();
        let acted = self.apply_rule_existing(&rule, scan_limit).await?;
        log::info!("run_rule_once: fired on {acted} message(s)");
        Ok(acted)
    }

    /// Run one saved rule against a single conversation's inbound mail now — the
    /// routing panel's manual "Run" for a matched rule that hasn't fired here yet.
    /// Keeps the rule key, so the rule's normal semantics apply (an `approval_first`
    /// first run still routes to `awaiting_approval`). Returns the number fired on.
    pub async fn run_rule_on_conversation(
        &self,
        rule_key: &str,
        conversation_key: &str,
    ) -> Result<usize, String> {
        let mut rule = self
            .store
            .get_rule(rule_key)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "rule not found".to_string())?;
        rule.enabled = true; // explicit action — run even if disabled for new mail
        let msgs = self
            .store
            .conversation_messages(conversation_key, 200)
            .map_err(|e| e.to_string())?;
        let acted = self.apply_rule_to_messages(&rule, &msgs).await;
        log::info!("run_rule_on_conversation {rule_key} on {conversation_key}: fired on {acted} message(s)");
        Ok(acted)
    }

    /// Shared core for both apply-to-existing paths: run `rule` over the most recent
    /// `scan_limit` inbound messages, firing exactly as the live scan would but
    /// scoped to this single rule and without touching the scan cursor (so the
    /// forward scan is unaffected). `rule` must already be enabled.
    async fn apply_rule_existing(&self, rule: &LocalRule, scan_limit: i64) -> Result<usize, String> {
        let msgs = self.store.recent_inbound(scan_limit).map_err(|e| e.to_string())?;
        Ok(self.apply_rule_to_messages(rule, &msgs).await)
    }

    /// Fire one (already-enabled) rule over a fixed set of messages, returning how
    /// many it acted on. The single message-iteration path shared by every
    /// apply-to-existing / manual-run entry point.
    async fn apply_rule_to_messages(&self, rule: &LocalRule, msgs: &[ScannedMessage]) -> usize {
        let mut phrase_emb: HashMap<String, Option<Vec<f32>>> = HashMap::new();
        let mut acted = 0usize;
        for m in msgs {
            let mut msg_emb: Option<Option<Vec<f32>>> = None;
            if self.maybe_apply_rule(rule, m, &mut phrase_emb, &mut msg_emb).await {
                acted += 1;
            }
        }
        acted
    }

    /// Execute a "perform_action" rule inline. Mutations are durable via the sync
    /// engine's write-back queue; AI-backed actions (auto-triage/auto-label) fail
    /// closed when the on-device models aren't loaded. Runs wherever the engine is
    /// hosted (GUI or headless daemon), so CLI sessions get it too.
    async fn run_builtin_action(&self, rule: &LocalRule, m: &ScannedMessage) {
        let Some(kind) = rule.action.builtin.as_deref().and_then(BuiltinAction::from_key) else {
            log::warn!("rule {} has unknown builtin action {:?}", rule.key, rule.action.builtin);
            return;
        };
        let Some(engine) = &self.sync_engine else {
            log::warn!("rule {} {} skipped: no sync engine", rule.key, kind.as_key());
            return;
        };
        let (status, summary, error) = match actions::execute(
            kind,
            engine,
            self.engine.as_deref(),
            &m.account_key,
            &m.conversation_key,
            &m.fields,
            rule.action.quadrant.as_deref(),
            rule.action.reply.as_deref(),
        )
        .await
        {
            Ok(summary) => {
                log::info!("rule {} {} on msg {} → {}", rule.key, kind.as_key(), m.message_key, summary);
                (RunStatus::Succeeded, Some(summary), None)
            }
            Err(e) => {
                log::warn!("rule {} {} on msg {} failed: {}", rule.key, kind.as_key(), m.message_key, e);
                (RunStatus::Failed, None, Some(e))
            }
        };
        // Surface the outcome in the routing panel (best-effort; the mutation itself
        // is already durable in the write-back queue).
        if let Err(e) = self.store.record_action_run(
            &rule.key,
            &m.message_key,
            &m.account_key,
            kind.as_key(),
            status,
            summary.as_deref(),
            error.as_deref(),
        ) {
            log::warn!("failed to record action run for rule {}: {e}", rule.key);
        }
    }

    /// Tier-1 gate: embedding similarity, fail-closed. Returns true to dispatch.
    /// `phrase_emb` caches phrase vectors across the scan; `msg_emb` caches the
    /// message vector across the gates on one message. `false` means reject OR the
    /// engine isn't ready (a gated rule never dispatches without its gate).
    async fn passes_gate(
        &self,
        gate: &AiGate,
        m: &ScannedMessage,
        phrase_emb: &mut HashMap<String, Option<Vec<f32>>>,
        msg_emb: &mut Option<Option<Vec<f32>>>,
    ) -> bool {
        let Some(engine) = &self.engine else {
            return false;
        };
        if msg_emb.is_none() {
            let text = format!(
                "From: {} | Subject: {} | {}",
                m.fields.from, m.fields.subject, m.fields.body
            );
            *msg_emb = Some(embed_text(engine.as_ref(), &text).await);
        }
        let Some(msg_vec) = msg_emb.as_ref().and_then(|e| e.as_ref()) else {
            return false;
        };
        if !phrase_emb.contains_key(&gate.phrase) {
            let e = embed_text(engine.as_ref(), &gate.phrase).await;
            phrase_emb.insert(gate.phrase.clone(), e);
        }
        let Some(target) = phrase_emb.get(&gate.phrase).and_then(|e| e.as_ref()) else {
            return false;
        };
        cosine_similarity(msg_vec, target) >= gate.threshold
    }

    /// Drain pending runs sequentially. A small fixed concurrency pool is a future
    /// refinement (docs §8).
    async fn drain_queue(&self) {
        loop {
            let claimed = match self.store.claim_next_pending() {
                Ok(Some(r)) => r,
                Ok(None) => break,
                Err(e) => {
                    log::warn!("claim error: {e}");
                    break;
                }
            };
            self.process_run(claimed).await;
        }
    }

    /// Fetch the message + attachments (async, off the agent), then run the agent
    /// on a blocking thread. A provider/attachment failure is a tracked, retriable
    /// run failure — so a download problem is findable, not silently skipped.
    async fn process_run(&self, run: AgentRunRow) {
        let input = match self.prepare_input(&run).await {
            Ok(i) => i,
            Err(e) => {
                requeue_or_fail(&self.store, &run, RunStatus::Failed, &e, Instant::now(), None, None);
                return;
            }
        };
        let store = self.store.clone();
        let base = self.base_dir.clone();
        let _ = tokio::task::spawn_blocking(move || run_agent_blocking(&store, &base, run, input)).await;
    }

    /// Assemble the harness input: DB headers/body, then — when the sync engine is
    /// available — the real RFC822 source and every attachment's bytes.
    async fn prepare_input(&self, run: &AgentRunRow) -> Result<MessageInput, String> {
        let mut input = self
            .store
            .message_input(&run.message_key)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "message not found".to_string())?;

        let Some(engine) = &self.sync_engine else {
            return Ok(input);
        };
        if run.account_key.is_empty() {
            return Ok(input);
        }
        let provider = engine
            .interactive_provider(&run.account_key)
            .map_err(|e| format!("provider unavailable: {e}"))?;

        // Prefer the real RFC822 source over the reconstructed one.
        if let Ok(src) = provider.get_message_source(&run.message_key).await {
            if !src.is_empty() {
                input.eml = src.into_bytes();
            }
        }
        // Enumerate attachments and ensure each is in the shared cache (downloading
        // only on a miss — reused across retries and the open-attachment feature).
        // The agent is pointed at the cached paths, not given copies. Any failure is
        // fatal-and-tracked so the run shows up as failed rather than running blind.
        let fetched = provider
            .fetch_message(&run.message_key)
            .await
            .map_err(|e| format!("fetch_message failed: {e}"))?;
        let store = engine.store();
        for att in &fetched.attachments {
            let path = store.message_attachment_path(&run.account_key, &run.message_key, &att.filename);
            if !path.exists() {
                let bytes = provider
                    .download_attachment(&run.message_key, &att.attachment_id)
                    .await
                    .map_err(|e| format!("attachment '{}' download failed: {e}", att.filename))?;
                store
                    .cache_message_attachment(&run.account_key, &run.message_key, &att.filename, &bytes)
                    .map_err(|e| format!("attachment '{}' cache write failed: {e}", att.filename))?;
            }
            input.attachments.push(HarnessAttachment {
                filename: att.filename.clone(),
                path: path.to_string_lossy().into_owned(),
            });
        }
        log::info!(
            "run {} prepared with {} attachment(s)",
            run.key,
            input.attachments.len()
        );
        Ok(input)
    }
}

/// Run one prepared run to completion. Pure blocking — call via spawn_blocking.
fn run_agent_blocking(
    store: &AgentRunStore,
    base_dir: &std::path::Path,
    run: AgentRunRow,
    input: MessageInput,
) {
    let started = Instant::now();

    let Some(adapter) = adapter_for(&run.adapter_id) else {
        terminal_fail(store, &run, RunStatus::Failed, "unknown agent", started, None, None);
        return;
    };
    let mode = PermissionMode::parse(&run.permission_mode).unwrap_or_default();

    let ctx = match build_scratch(base_dir, &run.key, &input, &run.task) {
        Ok(c) => c,
        Err(e) => {
            terminal_fail(store, &run, RunStatus::Failed, &format!("scratch setup failed: {e}"), started, None, None);
            return;
        }
    };
    let scratch = ctx.scratch_dir.clone();

    let mut cmd = adapter.build_command(&ctx, mode);
    // Spawn the agent with the same augmented PATH detection used to find it —
    // a GUI-launched app otherwise hands the child a slim PATH and the bare
    // binary name (`claude`, `codex`) fails to resolve even though we detected
    // it. The agent's own subprocesses (bash/node) inherit this too.
    cmd.env("PATH", super::detect::search_path());
    let exec = run_with_timeout(cmd, Duration::from_secs(run.timeout_s.max(1) as u64));
    let outcome = evaluate_result(&scratch, exec.exit_ok, exec.timed_out);
    let metrics = extract_metrics(&exec.stdout);
    let duration = started.elapsed().as_millis() as i64;
    let exit_code = exec.exit_code;
    let result_json = std::fs::read_to_string(scratch.join("result.json")).ok();
    let scratch_str = scratch.to_string_lossy().to_string();

    match outcome {
        RunOutcome::Succeeded { summary } => {
            let _ = store.finish_run(
                &run.key,
                RunStatus::Succeeded,
                result_json.as_deref(),
                exit_code,
                metrics,
                None,
                duration,
                Some(&scratch_str),
            );
            let _ = store.audit(&run.adapter_id, &audit_params(&run), &summary, AuditStatus::Success, None, duration);
            // Tidy up on success; keep the dir on failure for debugging.
            let _ = std::fs::remove_dir_all(&scratch);
        }
        RunOutcome::Timeout => {
            requeue_or_fail(store, &run, RunStatus::Timeout, "timed out", started, exit_code, Some(&scratch_str));
        }
        RunOutcome::Failed(reason) => {
            let detail = if exec.stderr.trim().is_empty() {
                reason
            } else {
                format!("{reason}; stderr: {}", truncate(&exec.stderr, 500))
            };
            requeue_or_fail(store, &run, RunStatus::Failed, &detail, started, exit_code, Some(&scratch_str));
        }
    }
}

/// Re-queue a failed run if attempts remain, otherwise record it terminally with
/// the given status (`Failed` or `Timeout`).
fn requeue_or_fail(
    store: &AgentRunStore,
    run: &AgentRunRow,
    terminal: RunStatus,
    reason: &str,
    started: Instant,
    exit_code: Option<i64>,
    scratch: Option<&str>,
) {
    let duration = started.elapsed().as_millis() as i64;
    if store.requeue_if_retriable(&run.key).unwrap_or(false) {
        let _ = store.audit(&run.adapter_id, &audit_params(run), reason, AuditStatus::Error, Some(reason), duration);
        log::info!("run {} failed ({reason}); re-queued for retry", run.key);
    } else {
        terminal_fail(store, run, terminal, reason, started, exit_code, scratch);
    }
}

fn terminal_fail(
    store: &AgentRunStore,
    run: &AgentRunRow,
    status: RunStatus,
    reason: &str,
    started: Instant,
    exit_code: Option<i64>,
    scratch: Option<&str>,
) {
    let duration = started.elapsed().as_millis() as i64;
    let _ = store.finish_run(&run.key, status, None, exit_code, RunMetrics::default(), Some(reason), duration, scratch);
    let _ = store.audit(&run.adapter_id, &audit_params(run), reason, AuditStatus::Error, Some(reason), duration);
}

fn audit_params(run: &AgentRunRow) -> String {
    serde_json::json!({
        "run_key": run.key,
        "message_key": run.message_key,
        "permission_mode": run.permission_mode,
        "task": truncate(&run.task, 200),
    })
    .to_string()
}

// ─── Subprocess execution with hard timeout ──────────────────────────────────

pub struct ExecResult {
    pub exit_ok: bool,
    pub timed_out: bool,
    pub exit_code: Option<i64>,
    pub stdout: String,
    pub stderr: String,
}

/// Spawn a command, stream its output, and kill it if it overruns `timeout`.
/// stdin is closed so an agent that prompts can never block forever waiting on it;
/// the timeout is the backstop for CLIs with known headless-hang bugs.
pub fn run_with_timeout(mut cmd: Command, timeout: Duration) -> ExecResult {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Put the agent in its own process group so a timeout can kill the whole tree
    // (a grandchild that inherits the stdout/stderr pipe would otherwise keep the
    // pipe open and hang the drain threads' `read_to_string` below forever).
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return ExecResult {
                exit_ok: false,
                timed_out: false,
                exit_code: None,
                stdout: String::new(),
                stderr: format!("spawn failed: {e}"),
            }
        }
    };

    // Drain pipes on dedicated threads so a chatty agent can't deadlock on a full
    // pipe buffer while we poll for exit.
    let mut out_pipe = child.stdout.take();
    let mut err_pipe = child.stderr.take();
    let out_handle = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(p) = out_pipe.as_mut() {
            let _ = p.read_to_string(&mut s);
        }
        s
    });
    let err_handle = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(p) = err_pipe.as_mut() {
            let _ = p.read_to_string(&mut s);
        }
        s
    });

    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if start.elapsed() >= timeout {
                    // Kill the whole process group (negative pid) so grandchildren
                    // holding the pipes die too; then reap the direct child.
                    #[cfg(unix)]
                    {
                        let _ = std::process::Command::new("kill")
                            .arg("-KILL")
                            .arg(format!("-{}", child.id()))
                            .status();
                    }
                    let _ = child.kill();
                    let _ = child.wait();
                    timed_out = true;
                    break None;
                }
                std::thread::sleep(PUMP_THREAD_SLEEP);
            }
            Err(_) => break None,
        }
    };

    let stdout = out_handle.join().unwrap_or_default();
    let stderr = err_handle.join().unwrap_or_default();
    let exit_code = status.as_ref().and_then(|s| s.code()).map(|c| c as i64);
    let exit_ok = !timed_out && status.map(|s| s.success()).unwrap_or(false);

    ExecResult {
        exit_ok,
        timed_out,
        exit_code,
        stdout,
        stderr,
    }
}

/// Best-effort cost + token extraction from the agent's own stdout. Claude/Codex/
/// Gemini emit a final JSON line carrying `total_cost_usd` and a `usage` object;
/// scan for the last line that has them. Input tokens fold in cache reads/creation.
/// Everything is optional — an agent that reports nothing yields a default.
fn extract_metrics(stdout: &str) -> RunMetrics {
    let mut m = RunMetrics::default();
    for line in stdout.lines() {
        let line = line.trim();
        if !line.starts_with('{') {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(c) = v.get("total_cost_usd").and_then(|c| c.as_f64()) {
            m.cost_usd = Some(c);
        }
        if let Some(u) = v.get("usage").filter(|u| u.is_object()) {
            let get = |k: &str| u.get(k).and_then(|x| x.as_i64());
            let input: i64 = [
                get("input_tokens"),
                get("cache_read_input_tokens"),
                get("cache_creation_input_tokens"),
            ]
            .into_iter()
            .flatten()
            .sum();
            if input > 0 {
                m.input_tokens = Some(input);
            }
            if let Some(out) = get("output_tokens") {
                m.output_tokens = Some(out);
            }
        }
    }
    m
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn runs_a_quick_command_and_captures_stdout() {
        let mut cmd = Command::new("/bin/sh");
        cmd.args(["-c", "echo hello; exit 0"]);
        let r = run_with_timeout(cmd, Duration::from_secs(5));
        assert!(r.exit_ok);
        assert!(!r.timed_out);
        assert_eq!(r.exit_code, Some(0));
        assert!(r.stdout.contains("hello"));
    }

    #[cfg(unix)]
    #[test]
    fn nonzero_exit_is_not_ok() {
        let mut cmd = Command::new("/bin/sh");
        cmd.args(["-c", "exit 7"]);
        let r = run_with_timeout(cmd, Duration::from_secs(5));
        assert!(!r.exit_ok);
        assert_eq!(r.exit_code, Some(7));
    }

    #[cfg(unix)]
    #[test]
    fn kills_an_overrunning_command() {
        let mut cmd = Command::new("/bin/sh");
        cmd.args(["-c", "sleep 30"]);
        let start = Instant::now();
        let r = run_with_timeout(cmd, Duration::from_millis(300));
        assert!(r.timed_out, "should have timed out");
        assert!(!r.exit_ok);
        assert!(start.elapsed() < Duration::from_secs(5), "must not wait for the sleep");
    }

    #[cfg(unix)]
    #[test]
    fn end_to_end_success_via_result_file() {
        // Simulate an agent that writes result.json then exits 0.
        let tmp = tempfile::tempdir().unwrap();
        let scratch = tmp.path();
        let mut cmd = Command::new("/bin/sh");
        cmd.current_dir(scratch).args([
            "-c",
            "printf '{\"status\":\"ok\",\"summary\":\"done\"}' > result.json",
        ]);
        let exec = run_with_timeout(cmd, Duration::from_secs(5));
        let outcome = evaluate_result(scratch, exec.exit_ok, exec.timed_out);
        assert_eq!(outcome, RunOutcome::Succeeded { summary: "done".into() });
    }

    #[test]
    fn extracts_cost_and_tokens_when_present() {
        let stdout = "{\"type\":\"result\",\"result\":\"ok\",\"total_cost_usd\":0.0123,\
            \"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":20,\"output_tokens\":50}}";
        let m = extract_metrics(stdout);
        assert_eq!(m.cost_usd, Some(0.0123));
        assert_eq!(m.input_tokens, Some(120)); // input + cache read
        assert_eq!(m.output_tokens, Some(50));
        let empty = extract_metrics("no json here");
        assert_eq!(empty.cost_usd, None);
        assert_eq!(empty.input_tokens, None);
    }

    #[test]
    fn spawn_failure_is_reported_not_panicked() {
        let cmd = Command::new("/nonexistent/binary/xyz");
        let r = run_with_timeout(cmd, Duration::from_secs(2));
        assert!(!r.exit_ok);
        assert!(r.stderr.contains("spawn failed"));
    }
}

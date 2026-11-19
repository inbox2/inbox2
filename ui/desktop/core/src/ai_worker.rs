//! `TriageWorker` — the background drain that triages conversations and writes
//! their medium/short summaries off the sync path.
//!
//! Spawned once per host (mobile: in `ffi::InboxEngine::new`; desktop: beside the
//! embedding pipeline). Each pass drains the [`ai_triage_queue`] newest-first
//! (priority = the conversation's `updated_at`), then sleeps until a 5-second tick
//! or the engine's `ai_scan` notify (pinged after a sync brings in new mail).
//!
//! Per thread (contract: `docs/Triage.md`): the deterministic rules run first;
//! with a Jev key ONE Jev call fills the label (only when no rule fired), the
//! priority (always) and the Space (when sorting is on); summaries come
//! separately from the user's text lane ([`agent::generate_text`] with the
//! `[summary]` prompt), falling back to subject/snippet summaries when no model
//! is up. Without a key the thread is still processed — rule label or none —
//! and a key arriving later re-enqueues what's missing
//! ([`SyncEngine::set_jev_key`]).
//!
//! Robustness: a job is `processing` while in flight and deleted only on a
//! successful, non-stale write; a new message landing mid-process re-enqueues
//! it (back to `pending`) so the fresher thread is reprocessed. A transient Jev
//! error defers the job (backoff); a 401 stops Jev calls until the key changes;
//! failures bump the attempt count and eventually park a poison thread.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::bridge::agent::{self, BridgeConfig, GenSource};
use crate::bridge::{prompts, LocalGenerator};
use crate::sync::engine::{event, SyncEngine};
use crate::sync::ics::DetectedMeeting;
use crate::sync::store::TriageInput;
use crate::triage::{self, JevVerdict, SpaceDef, TriageLabel, TriageLabelDef};
use crate::typesafe::{self, JevError};

/// Poll interval between drain passes when nothing pings the worker.
const POLL_INTERVAL: Duration = Duration::from_secs(5);

/// Hard ceiling on processing ONE conversation (Jev call + summary). The drain
/// runs on a single task, so a generation that stalls — a wedged on-device
/// model, or a request whose connection hangs (common on mobile across a
/// network change) — would otherwise block the loop indefinitely and freeze the
/// clients' "Catching up" bar. Bounding each job here means any hang just
/// charges an attempt and the queue keeps draining. Generous enough not to cut
/// off a legitimately slow on-device completion on an older phone.
const GENERATION_TIMEOUT: Duration = Duration::from_secs(90);

/// The background triage + summary worker. Holds only an engine handle; all state
/// lives in the store's `ai_triage_queue`.
pub struct TriageWorker {
    engine: Arc<SyncEngine>,
    /// When the last `triage-progress` snapshot was emitted. Each snapshot runs
    /// COUNT queries over `conversations` under the store's global connection
    /// lock and makes every client repaint its bar, so the per-result emits are
    /// throttled to one per second; the pass-end emit always goes out so the
    /// final state lands.
    last_progress: std::sync::Mutex<Option<Instant>>,
    /// One-shot guard for the first drain pass: retry failures that were really
    /// "no model available" (written by the pre-Jev worker) and enqueue the
    /// in-window backlog (seeded / pre-worker conversations never went through the
    /// message-upsert enqueue path, so without this they'd never get triaged).
    recovered: AtomicBool,
}

/// What happened to one job in a drain pass.
enum Outcome {
    /// A (non-stale) result was written; the job is complete.
    Wrote,
    /// A newer message re-enqueued the thread mid-process; leave it pending.
    Stale,
    /// Jev had a transient failure; park it and retry after the backoff.
    Deferred,
    /// Jev's account is blocked (credits, billing): hand the job back and stop the pass.
    Paused,
}

impl TriageWorker {
    pub fn new(engine: Arc<SyncEngine>) -> Self {
        Self { engine, recovered: AtomicBool::new(false), last_progress: std::sync::Mutex::new(None) }
    }

    /// Run forever: drain, emit progress, wait for the next tick or notify.
    pub async fn run(self) {
        let notify = self.engine.ai_scan_notify();
        loop {
            self.drain().await;
            self.emit_progress();
            tokio::select! {
                _ = tokio::time::sleep(POLL_INTERVAL) => {}
                _ = notify.notified() => {}
            }
        }
    }

    /// Drain every claimable job, one at a time.
    async fn drain(&self) {
        // Every host pushes its AI config at launch; until it has, idle rather than
        // write snippet summaries for threads the user's model lane should summarize.
        let Some(cfg) = self.engine.ai_config_snapshot() else {
            log::debug!("[triage] drain: no AI config pushed yet — idling");
            return;
        };
        let generator = self.engine.generator_handle();
        // The summary lane is optional: when it can't run, summaries fall back to
        // the deterministic subject/snippet pair instead of blocking triage.
        let summary_cfg = summary_lane_ready(&cfg, generator.as_ref()).await.then_some(&cfg);
        // Deferred jobs (a transient Jev failure) come back after their backoff.
        match self.engine.store().reactivate_deferred_triage() {
            Ok(n) if n > 0 => log::info!("[triage] reactivated {n} deferred job(s)"),
            Ok(_) => {}
            Err(e) => log::warn!("[triage] reactivating deferred jobs failed: {e}"),
        }
        if !self.recovered.swap(true, Ordering::Relaxed) {
            match self.engine.store().reactivate_unavailable_failures() {
                Ok(n) => log::info!("[triage] recovery: reactivated {n} no-model failure(s)"),
                Err(e) => log::warn!("[triage] reactivating no-model failures failed: {e}"),
            }
            match self.engine.store().backfill_triage_queue() {
                Ok(n) => log::info!("[triage] recovery: backfilled {n} unqueued in-window conversation(s)"),
                Err(e) => log::warn!("[triage] queue backfill failed: {e}"),
            }
            // One-time re-triage after the 2026-10-20 labels (marker-gated, off the main thread).
            match self.engine.store().lore_retriage(self.engine.jev_key().is_some()) {
                Ok(Some(r)) => {
                    log::info!("[triage] lore re-triage: {} relabelled by rules, {} queued for Jev", r.relabeled.len(), r.queued);
                    for (key, label) in r.relabeled {
                        let meta = self.engine.store().triage_meta(&key).ok().flatten().unwrap_or_default();
                        self.engine.emit_event(
                            event::TRIAGE_UPDATED,
                            json!({ "conversationKey": key, "label": label, "priority": meta.priority, "summaryShort": meta.summary_short }),
                        );
                    }
                }
                Ok(None) => {}
                Err(e) => log::warn!("[triage] lore re-triage failed: {e}"),
            }
        }

        // Jev's account is blocked: leave the queue alone until the next probe
        // (a skipped thread would be marked done without its label or Space).
        if self.engine.jev_paused() {
            return;
        }

        // Per-pass outcome tally + a stale-loop tripwire. If the claimer hands us a job
        // we already saw go `Stale` THIS pass, the queue is cycling the same row(s)
        // without progress (the wedge signature) — log it loudly and end the pass so we
        // don't spin; the next tick (or a real new message) retries.
        let mut wrote = 0u32;
        let mut stale = 0u32;
        let mut deferred = 0u32;
        let mut failed = 0u32;
        let mut staled_keys: std::collections::HashSet<String> = std::collections::HashSet::new();
        loop {
            let claimed = match self.engine.store().claim_next_triage_job() {
                Ok(Some(key)) => key,
                Ok(None) => break,
                Err(e) => {
                    log::warn!("[triage] claim failed: {e}");
                    break;
                }
            };
            if staled_keys.contains(&claimed) {
                log::warn!(
                    "[triage] stale-loop tripwire: re-claimed {claimed} after it went stale this pass \
                     (wrote={wrote} stale={stale}) — ending pass to avoid spin"
                );
                break;
            }
            // Bound each job so a hung lane can't freeze the single-threaded drain.
            // A timeout charges an attempt so the job eventually parks as poison.
            let processed = tokio::time::timeout(
                GENERATION_TIMEOUT,
                self.process(&claimed, summary_cfg, generator.as_ref()),
            )
            .await
            .unwrap_or_else(|_| Err(format!("generation timed out after {}s", GENERATION_TIMEOUT.as_secs())));
            match processed {
                Ok(Outcome::Wrote) => {
                    wrote += 1;
                    if let Err(e) = self.engine.store().complete_triage_job(&claimed) {
                        log::warn!("[triage] {claimed}: completing job failed: {e}");
                    }
                    self.emit_progress_throttled();
                }
                // Stale (a newer message re-enqueued it) — leave it pending.
                Ok(Outcome::Stale) => {
                    stale += 1;
                    staled_keys.insert(claimed.clone());
                }
                Ok(Outcome::Paused) => {
                    if let Err(e) = self.engine.store().release_triage_job(&claimed) {
                        log::warn!("[triage] {claimed}: releasing job failed: {e}");
                    }
                    break;
                }
                Ok(Outcome::Deferred) => {
                    deferred += 1;
                    if let Err(e) = self.engine.store().defer_triage_job(&claimed) {
                        log::warn!("[triage] {claimed}: deferring job failed: {e}");
                    }
                }
                Err(e) => {
                    failed += 1;
                    log::warn!("[triage] {claimed}: {e}");
                    if let Err(e2) = self.engine.store().fail_triage_job(&claimed, &e) {
                        log::warn!("[triage] {claimed}: recording failure failed: {e2}");
                    }
                }
            }
        }

        // Give exhausted (poison) threads a deterministic fallback label so the bar can
        // reach 100% instead of parking forever.
        self.finalize_exhausted();

        // Pass summary — only when something actually happened, so an idle worker stays
        // quiet. A pass that claimed jobs but wrote nothing while work remains is the
        // wedge — flag it.
        if wrote + stale + deferred + failed > 0 {
            match (self.engine.store().triage_progress(), self.engine.store().triage_diagnostics()) {
                (Ok(p), Ok(d)) => {
                    let stuck = wrote == 0 && p.pending > 0;
                    let line = format!(
                        "[triage] pass done: wrote={wrote} stale={stale} deferred={deferred} failed={failed} \
                         | done={}/{} pending={} | queue[pending={} processing={} failed={} deferred={}] \
                         poison={} attempts[min={} max={}] unenqueued_in_window={} jev={}",
                        p.done, p.in_window, p.pending,
                        d.q_pending, d.q_processing, d.q_failed, d.q_deferred,
                        d.poison, d.min_attempts, d.max_attempts, d.unenqueued_in_window,
                        self.engine.jev_status().as_str(),
                    );
                    if stuck {
                        log::warn!("{line} <- STUCK: claimed work but wrote nothing while {} pending", p.pending);
                    } else {
                        log::info!("{line}");
                    }
                }
                (Err(e), _) | (_, Err(e)) => log::warn!("[triage] pass summary: progress/diagnostics query failed: {e}"),
            }
        }
    }

    /// Label exhausted (poison) threads deterministically so they leave the queue and
    /// the "Catching up" bar can finish: the rule label when there is one, else `fyi`,
    /// with a deterministic snippet summary. Provenance records the fallback. Runs
    /// every drain pass; cheap and idempotent (a labeled thread isn't re-listed).
    fn finalize_exhausted(&self) {
        let keys = match self.engine.store().exhausted_unlabeled_triage_keys() {
            Ok(k) => k,
            Err(e) => {
                log::warn!("[triage] listing exhausted jobs failed: {e}");
                return;
            }
        };
        if keys.is_empty() {
            return;
        }
        let mut finalized = 0u32;
        for key in &keys {
            let input = match self.engine.store().conversation_triage_input(key) {
                Ok(Some(i)) => i,
                // No messages left — just drop the orphan queue row.
                Ok(None) => {
                    let _ = self.engine.store().delete_triage_job(key);
                    continue;
                }
                Err(e) => {
                    log::warn!("[triage] {key}: exhausted-finalize read failed: {e}");
                    continue;
                }
            };
            let (medium, short) = deterministic_summaries(&input);
            let label = input.deterministic.unwrap_or(TriageLabel::Fyi);
            let source = match input.deterministic {
                Some(_) => format!("{}+fallback:exhausted", input.det_source),
                None => "fallback:exhausted".to_string(),
            };
            match persist(&self.engine, key, Some(label.as_str()), None, &medium, &short, &input, &source) {
                // Labeled — remove the poison row for good.
                Ok(true) => {
                    let _ = self.engine.store().delete_triage_job(key);
                    finalized += 1;
                }
                // A newer message re-enqueued it mid-finalize (attempts reset) — leave it.
                Ok(false) => {}
                Err(e) => log::warn!("[triage] {key}: exhausted-finalize write failed: {e}"),
            }
        }
        if finalized > 0 {
            log::info!("[triage] finalized {finalized} exhausted thread(s) with a deterministic fallback label");
            self.emit_progress();
        }
    }

    /// Triage + summarize one conversation. `summary_cfg` is the text lane for
    /// summaries (`None` → deterministic summaries).
    async fn process(
        &self,
        conversation_key: &str,
        summary_cfg: Option<&BridgeConfig>,
        generator: Option<&Arc<dyn LocalGenerator>>,
    ) -> Result<Outcome, String> {
        let store = self.engine.store();
        let input = match store.conversation_triage_input(conversation_key) {
            Ok(Some(i)) => i,
            // No messages (deleted between enqueue and now) — drop the orphan job.
            Ok(None) => return Ok(Outcome::Wrote),
            Err(e) => return Err(e.to_string()),
        };
        let labels = store.triage_labels();
        let meta = store.triage_meta(conversation_key).map_err(|e| e.to_string())?.unwrap_or_default();
        // A hand-placed Space is never re-asked (the store refuses to overwrite it anyway).
        let spaces = if store.space_classify_enabled() && !meta.space_manual {
            store.effective_spaces()
        } else {
            Vec::new()
        };
        let jev_key = self.engine.jev_key();

        // Fast path: the bundle is current for the newest message (anchor matches),
        // so this job exists only to fill what Jev adds — a key arrived after the
        // thread was processed, Space sorting was switched on, or a duplicate
        // enqueue. Summaries are kept; only the missing Jev fields are asked (a
        // label is present — rule, Jev or manual — so it is never re-asked here).
        if meta.msg_key.as_deref() == Some(input.newest_msg_key.as_str()) {
            let Some(key) = jev_key else { return Ok(Outcome::Wrote) };
            let ask_label = meta.label.is_none();
            let spaces = if meta.space.is_none() { spaces } else { Vec::new() };
            if !ask_label && meta.priority.is_some() && spaces.is_empty() {
                return Ok(Outcome::Wrote);
            }
            let v = match self.jev_step(&key, &input, &labels, &spaces, ask_label).await {
                JevStep::Answered(v) => v,
                JevStep::Skip => return Ok(Outcome::Wrote),
                JevStep::Defer => return Ok(Outcome::Deferred),
                JevStep::Pause => return Ok(Outcome::Paused),
            };
            let source = with_jev_part(meta.source.as_deref().unwrap_or(""), &v.model);
            let wrote = store
                .write_jev_fill(conversation_key, v.label.as_deref(), v.priority, &input.newest_msg_key, &source)
                .map_err(|e| e.to_string())?;
            if !wrote {
                return Ok(Outcome::Stale);
            }
            self.engine.emit_event(
                event::TRIAGE_UPDATED,
                json!({
                    "conversationKey": conversation_key,
                    "label": v.label.or(meta.label),
                    "priority": v.priority.or(meta.priority),
                    "summaryShort": meta.summary_short,
                }),
            );
            if let Some(slug) = &v.space {
                write_space(&self.engine, conversation_key, slug, &input.newest_msg_key);
            }
            apply_lore_auto(&self.engine, conversation_key).await;
            return Ok(Outcome::Wrote);
        }

        // Full path: rules, then one Jev call for whatever is still open. A label
        // the user set by hand holds until a new message arrives (it beats the
        // rules too); after that the thread is judged afresh.
        let manual_label = meta.label_is_manual(&input.newest_msg_key);
        // A soft rule (bill wording) asks Jev for the label when there's a key.
        let soft = !manual_label && jev_key.is_some() && input.rule_defers_to_jev();
        let rule = if manual_label || soft { None } else { input.deterministic };
        let verdict = match &jev_key {
            Some(key) => match self.jev_step(key, &input, &labels, &spaces, rule.is_none() && !manual_label).await {
                JevStep::Answered(v) => Some(v),
                JevStep::Skip => None,
                JevStep::Defer => return Ok(Outcome::Deferred),
                JevStep::Pause => return Ok(Outcome::Paused),
            },
            None => None,
        };
        let jev_label = verdict.as_ref().and_then(|v| v.label.clone());
        let label = if manual_label {
            meta.label.clone()
        } else {
            rule.map(|l| l.as_str().to_string())
                .or_else(|| jev_label.clone())
                // Jev gave no label for a soft rule's thread: the rule still stands in.
                .or_else(|| if soft { input.deterministic.map(|l| l.as_str().to_string()) } else { None })
        };
        // Provenance names who decided: a soft rule that Jev overruled isn't the source.
        let rule_source = if manual_label { triage::MANUAL_SOURCE } else if soft && jev_label.is_some() { "" } else { input.det_source };
        let priority = verdict.as_ref().and_then(|v| v.priority);

        let (medium, short, summary_source, meeting, title) = summarize(&self.engine, &input, summary_cfg, generator).await;
        let source = join_source(&[
            rule_source,
            &verdict.as_ref().map(|v| format!("jev:{}", v.model)).unwrap_or_default(),
            &summary_source,
        ]);
        let wrote = persist(&self.engine, conversation_key, label.as_deref(), priority, &medium, &short, &input, &source)?;
        if !wrote {
            return Ok(Outcome::Stale);
        }
        // Only a model pass can see a meeting; the snippet fallback leaves any earlier one alone.
        if summary_cfg.is_some() {
            write_meeting(&self.engine, &input.newest_msg_key, meeting.as_ref());
        }
        // The title too, but only when a model actually answered (a failed lane
        // falls back to "" provenance and keeps the earlier title).
        if !summary_source.is_empty() {
            write_title(&self.engine, conversation_key, title.as_deref());
        }
        if let Some(slug) = verdict.as_ref().and_then(|v| v.space.as_deref()) {
            write_space(&self.engine, conversation_key, slug, &input.newest_msg_key);
        }
        apply_lore_auto(&self.engine, conversation_key).await;
        Ok(Outcome::Wrote)
    }

    /// One Jev call, with the worker's error policy: a transient failure defers
    /// the job; a 401 marks the key rejected and a malformed request is logged —
    /// both then carry on without Jev, so the thread isn't retried for them.
    async fn jev_step(
        &self,
        key: &str,
        input: &TriageInput,
        labels: &[TriageLabelDef],
        spaces: &[SpaceDef],
        ask_label: bool,
    ) -> JevStep {
        match jev_classify(&self.engine.jev_endpoint(), key, input, labels, spaces, ask_label).await {
            Ok(v) => {
                if self.engine.clear_jev_blocked() {
                    log::info!("[triage] Jev answered again — resuming");
                    self.emit_progress();
                }
                JevStep::Answered(v)
            }
            Err(JevError::Blocked(e)) => {
                log::warn!("[triage] Jev refused the account ({e}) — pausing, probing every minute");
                self.engine.mark_jev_blocked(e);
                self.emit_progress();
                JevStep::Pause
            }
            Err(JevError::Unauthorized) => {
                log::warn!("[triage] Jev rejected the API key (401) — pausing Jev until the key changes");
                self.engine.mark_jev_unauthorized();
                self.emit_progress();
                JevStep::Skip
            }
            Err(JevError::Invalid(e)) => {
                log::warn!("[triage] Jev rejected the request (not retried): {e}");
                JevStep::Skip
            }
            Err(e @ JevError::Transient(_)) => {
                log::info!("[triage] {e} — deferring");
                JevStep::Defer
            }
        }
    }

    /// Per-result progress emit, at most one per second (see `last_progress`).
    fn emit_progress_throttled(&self) {
        {
            let last = self.last_progress.lock().unwrap();
            if last.is_some_and(|t| t.elapsed() < Duration::from_secs(1)) {
                return;
            }
        }
        self.emit_progress();
    }

    /// Emit a `triage-progress` snapshot for the clients' progress bar.
    fn emit_progress(&self) {
        *self.last_progress.lock().unwrap() = Some(Instant::now());
        if let Ok(p) = self.engine.store().triage_progress() {
            self.engine.emit_event(event::TRIAGE_PROGRESS, progress_json(&self.engine, &p));
        }
    }
}

/// The `triage-progress` payload (also the cold-start snapshot the hosts return):
/// `{inWindow, done, pending, currentDate, jevStatus, jevError, summaryError}`.
pub fn progress_json(engine: &SyncEngine, p: &crate::sync::store::TriageProgress) -> serde_json::Value {
    json!({
        "inWindow": p.in_window,
        "done": p.done,
        "pending": p.pending,
        "currentDate": p.current_date,
        "jevStatus": engine.jev_status().as_str(),
        // Why triage is degraded, for the progress panel: `null` when fine.
        "jevError": engine.jev_error(),
        "summaryError": engine.summary_error(),
    })
}

/// What the worker does after a Jev call.
enum JevStep {
    Answered(JevVerdict),
    /// Carry on without Jev (401 / malformed request).
    Skip,
    /// Transient failure: park the job and retry after the backoff.
    Defer,
    /// The account is blocked (credits, billing): hand the job back, pause the queue.
    Pause,
}

/// Whether the summary lane can generate right now. On-device falls back to
/// OpenAI when a key is present (see `agent::on_device_or_openai`), so either counts.
async fn summary_lane_ready(cfg: &BridgeConfig, generator: Option<&Arc<dyn LocalGenerator>>) -> bool {
    let has_key = cfg.openai_key.as_deref().is_some_and(|k| !k.is_empty());
    match cfg.generation {
        GenSource::OpenAi => has_key,
        GenSource::OnDevice => has_key || matches!(generator, Some(g) if g.is_available().await),
    }
}

/// Ask Jev about one thread: label (when `ask_label`), priority, and space (when
/// `spaces` is non-empty), read per the contract. Shared by the worker, the
/// forced re-run and the eval harness.
pub async fn jev_classify(
    endpoint: &str,
    key: &str,
    input: &TriageInput,
    labels: &[TriageLabelDef],
    spaces: &[SpaceDef],
    ask_label: bool,
) -> Result<JevVerdict, JevError> {
    let state = triage::jev_state(&input.owner, input.subject.as_deref().unwrap_or(""), &input.messages);
    let questions = triage::jev_questions(labels, spaces, ask_label);
    let resp = typesafe::ask(endpoint, key, &state, &questions).await?;
    Ok(triage::read_jev_answers(&resp, &questions))
}

/// `+`-join the non-empty provenance parts (`rule:x`, `jev:<model>`, `model:…`).
fn join_source(parts: &[&str]) -> String {
    parts.iter().filter(|p| !p.is_empty()).copied().collect::<Vec<_>>().join("+")
}

/// Put `jev:<model>` into an existing provenance tag, after its rule part and
/// replacing any older `jev:` part: `rule:x+model:y` → `rule:x+jev:m+model:y`.
fn with_jev_part(existing: &str, model: &str) -> String {
    let parts: Vec<&str> = existing.split('+').filter(|p| !p.is_empty() && !p.starts_with("jev:")).collect();
    let jev = format!("jev:{model}");
    let (rules, rest): (Vec<&str>, Vec<&str>) =
        parts.into_iter().partition(|p| p.starts_with("rule:") || *p == triage::MANUAL_SOURCE);
    let mut all = rules;
    all.push(&jev);
    all.extend(rest);
    join_source(&all)
}

/// The (medium, short) summaries plus the provenance of the engine that wrote
/// them (`model:…`, or "" for the deterministic fallback), the meeting and the
/// Lore to-do title (`None` from the fallback). A model failure falls back
/// rather than failing the job — the Jev result must not be lost to it.
async fn summarize(
    engine: &SyncEngine,
    input: &TriageInput,
    cfg: Option<&BridgeConfig>,
    generator: Option<&Arc<dyn LocalGenerator>>,
) -> (String, String, String, Option<DetectedMeeting>, Option<String>) {
    if let Some(cfg) = cfg {
        match model_summarize(input, cfg, generator).await {
            Ok(r) => {
                engine.set_summary_error(None);
                return r;
            }
            Err(e) => {
                log::info!("[triage] summary lane failed, using the snippet fallback: {e}");
                engine.set_summary_error(Some(e));
            }
        }
    }
    let (m, s) = deterministic_summaries(input);
    (m, s, String::new(), None, None)
}

/// Ask the text lane for the summaries (`[summary]` prompt, tolerant parse), plus
/// the meeting it read out of the body, if any.
async fn model_summarize(
    input: &TriageInput,
    cfg: &BridgeConfig,
    generator: Option<&Arc<dyn LocalGenerator>>,
) -> Result<(String, String, String, Option<DetectedMeeting>, Option<String>), String> {
    let (text, source) =
        agent::generate_text_traced(generator, cfg, &prompts::summary_instructions(), &triage_user_prompt(input)).await?;
    let (m, s) = parse_summary_json(&text).ok_or_else(|| format!("unparseable summary: {}", truncate(&text, 200)))?;
    let mut meeting = parse_meeting_json(&text);
    // Small on-device models (Apple Intelligence) read the appointment into the
    // summary yet leave the extra `meeting` field empty. When the thread names a clock
    // time, ask once more with a meeting-only prompt — one focused question they do answer.
    if meeting.is_none() && has_clock_time(input.messages.last().map_or("", |m| m.text.as_str())) {
        match agent::generate_text_traced(generator, cfg, MEETING_PROMPT, &triage_user_prompt(input)).await {
            Ok((reply, _)) => {
                meeting = parse_meeting_reply(&reply);
                log::info!("[triage] {}: meeting-only reply: {}", input.newest_msg_key, truncate(&reply, 300));
            }
            Err(e) => log::info!("[triage] {}: meeting-only call failed: {e}", input.newest_msg_key),
        }
    }
    let meeting = meeting.filter(|m| meeting_is_plausible(input, m));
    // Which engine answered and whether it saw a meeting — a missing banner is
    // otherwise indistinguishable from "no model ran". The raw reply rides along
    // only when there's no meeting, to see what the model actually wrote.
    match &meeting {
        Some(mt) => log::info!("[triage] {}: summary by {source}, meeting {} at {}", input.newest_msg_key, mt.title, mt.start),
        None => log::info!("[triage] {}: summary by {source}, no meeting — reply: {}", input.newest_msg_key, truncate(&text, 400)),
    }
    Ok((m, s, source, meeting, parse_summary_title(&text)))
}

/// Models read a proposal ("can we schedule a call tomorrow?", "Wednesday morning
/// works") as a booking and invent the clock time. So a meeting only stands when the
/// newest message's own words (quotes stripped) name a clock time, and it doesn't lie
/// before that message was sent. A reply that only says "confirmed" to a time quoted
/// below is lost — the price of not inventing meetings.
fn meeting_is_plausible(input: &TriageInput, m: &DetectedMeeting) -> bool {
    let own_words = input.messages.last().map_or("", |msg| msg.text.as_str());
    let sent_day = input.newest_at.as_deref().and_then(|d| d.get(..10));
    has_clock_time(own_words) && sent_day.is_none_or(|day| m.start.get(..10).is_some_and(|s| s >= day))
}

/// The optional `meeting` object next to the summaries. Anything malformed is
/// simply no meeting — it must never cost the summaries.
fn parse_meeting_json(text: &str) -> Option<DetectedMeeting> {
    let (start, end) = (text.find('{')?, text.rfind('}')?);
    let v: serde_json::Value = serde_json::from_str(text.get(start..=end)?)
        .or_else(|_| serde_json::from_str(&strip_trailing_commas(&text[start..=end])))
        .ok()?;
    DetectedMeeting::from_model(v.get("meeting")?)
}

/// The optional `title` next to the summaries (the Lore to-do line), clamped to
/// one line of at most [`TITLE_MAX`] chars. `None` when the model left it out —
/// e.g. a user's `[summary]` override written before the field existed.
fn parse_summary_title(text: &str) -> Option<String> {
    let from_object = || -> Option<String> {
        let (start, end) = (text.find('{')?, text.rfind('}')?);
        let raw = text.get(start..=end)?;
        let v: serde_json::Value =
            serde_json::from_str(raw).or_else(|_| serde_json::from_str(&strip_trailing_commas(raw))).ok()?;
        v.get("title")?.as_str().map(str::to_string)
    };
    // The meeting object has its own "title": only the top-level one counts, so
    // the by-name fallback is for an object that didn't parse at all.
    let title = from_object().or_else(|| json_str_field(text.split("\"meeting\"").next()?, "title"))?;
    let title = first_line(&title).trim_matches(|c: char| c == '"' || c == '.' || c.is_whitespace()).to_string();
    (!title.is_empty()).then(|| title.chars().take(TITLE_MAX).collect::<String>().trim_end().to_string())
}

/// `conversations.next_action_title` limit (MX `Conversation::NEXT_ACTION_TITLE_MAX`).
const TITLE_MAX: usize = 80;

/// Record the Lore to-do title the summary lane wrote (or clear it).
fn write_title(engine: &SyncEngine, conversation_key: &str, title: Option<&str>) {
    if let Err(e) = engine.store().write_next_action_title(conversation_key, title) {
        log::warn!("[triage] {conversation_key}: next-action title not written: {e}");
    }
}

/// The follow-up question when the summary skipped `meeting` (see [`model_summarize`]).
/// Same rules as the `[summary]` prompt's `meeting` field and MX `MeetingDetector::PROMPT`.
const MEETING_PROMPT: &str = r#"You read one email thread and decide whether it books or confirms one specific
appointment or meeting the recipient takes part in, with a concrete date AND clock
time (a viewing, a call, a visit, "I confirm our appointment on ... at ...").
If it does, reply with STRICT JSON only:
{"title": "<short English title>", "start": "YYYY-MM-DDTHH:MM", "end": "YYYY-MM-DDTHH:MM or null", "location": "<address or place, or null>"}
Times exactly as written in the email, no time-zone conversion. Resolve a relative
date ("next Friday") against the newest message's date. A deadline, a proposal still
being negotiated, several options to pick from, or a webinar / marketing event is NOT
a meeting. Otherwise reply: null"#;

/// The meeting-only reply: the bare object (or one wrapped as `{"meeting": …}`).
fn parse_meeting_reply(text: &str) -> Option<DetectedMeeting> {
    let (start, end) = (text.find('{')?, text.rfind('}')?);
    let v: serde_json::Value = serde_json::from_str(text.get(start..=end)?).ok()?;
    DetectedMeeting::from_model(v.get("meeting").unwrap_or(&v))
}

/// Whether the text names a clock time — "16:30", "4.30", "16h30", "4 pm", "16 uur".
/// Gates the meeting-only call, like MX `MeetingDetector::CLOCK_TIME`.
/// ponytail: byte scan, no regex crate; a time written in words slips through.
fn has_clock_time(text: &str) -> bool {
    let b = text.as_bytes();
    let digit = |i: usize| b.get(i).is_some_and(u8::is_ascii_digit);
    (0..b.len()).any(|i| {
        if !digit(i) || (i > 0 && digit(i - 1)) {
            return false;
        }
        let h = if digit(i + 1) { i + 2 } else { i + 1 };
        let hour: u32 = text[i..h].parse().unwrap_or(99);
        if hour > 23 {
            return false;
        }
        // H:MM / H.MM / HhMM
        if matches!(b.get(h), Some(b':' | b'.' | b'h')) && digit(h + 1) && digit(h + 2) && !digit(h + 3) {
            return b[h + 1] <= b'5';
        }
        // "4 pm", "16 uur"
        let rest = text[h..].trim_start().to_ascii_lowercase();
        rest.starts_with("uur") || rest.starts_with("am") || rest.starts_with("pm")
    })
}

/// Record the detected meeting on the message the summary was written for
/// (`None` clears one an earlier pass found). A write failure only loses the banner.
fn write_meeting(engine: &SyncEngine, message_key: &str, meeting: Option<&DetectedMeeting>) {
    let json = meeting.and_then(|m| serde_json::to_string(m).ok());
    if let Err(e) = engine.store().write_detected_meeting(message_key, json.as_deref()) {
        log::warn!("[triage] {message_key}: detected meeting not written: {e}");
    }
}

/// Write a result (label + priority + summaries + provenance) and emit
/// `triage-updated` (`{conversationKey, label, priority, summaryShort}`).
#[allow(clippy::too_many_arguments)]
fn persist(
    engine: &SyncEngine,
    conversation_key: &str,
    label: Option<&str>,
    priority: Option<f64>,
    medium: &str,
    short: &str,
    input: &TriageInput,
    source: &str,
) -> Result<bool, String> {
    let wrote = engine
        .store()
        .write_triage_result(conversation_key, label, priority, medium, short, &input.newest_msg_key, source, &input.signals)
        .map_err(|e| e.to_string())?;
    if wrote {
        engine.emit_event(
            event::TRIAGE_UPDATED,
            json!({
                "conversationKey": conversation_key,
                "label": label,
                "priority": priority,
                // The list row shows this as its preview line, so it rides along
                // and the row upgrades from snippet → summary without a reload.
                "summaryShort": short,
            }),
        );
    }
    Ok(wrote)
}

/// Lore auto mode (docs/Triage.md "Auto mode"): when the label that just landed
/// is in a bucket the person switched to auto, file the thread away through the
/// normal write-back path (same as a user archive/trash, so it reaches Gmail /
/// Microsoft) and mark the provenance `+auto`. Emits `triage-updated` with
/// `autoAction` so open lists can drop the row.
async fn apply_lore_auto(engine: &SyncEngine, conversation_key: &str) {
    let (account, verb) = match engine.store().lore_auto_candidate(conversation_key) {
        Ok(Some(c)) => c,
        Ok(None) => return,
        Err(e) => return log::warn!("[lore-auto] {conversation_key}: check failed: {e}"),
    };
    if let Err(e) = engine.perform_conversation_action(&account, &[conversation_key.to_string()], verb).await {
        return log::warn!("[lore-auto] {conversation_key}: {verb} failed: {e}");
    }
    let _ = engine.store().mark_lore_auto(conversation_key);
    log::info!("[lore-auto] {conversation_key}: {verb}");
    let meta = engine.store().triage_meta(conversation_key).ok().flatten().unwrap_or_default();
    engine.emit_event(
        event::TRIAGE_UPDATED,
        json!({
            "conversationKey": conversation_key,
            "label": meta.label,
            "priority": meta.priority,
            "summaryShort": meta.summary_short,
            "autoAction": verb,
        }),
    );
}

/// Write a Space verdict (staleness-checked) and emit `space-updated`.
fn write_space(engine: &SyncEngine, conversation_key: &str, slug: &str, anchor: &str) {
    match engine.store().write_space_result(conversation_key, slug, anchor) {
        Ok(true) => {
            log::info!("[space] {conversation_key}: {slug}");
            engine.emit_event(event::SPACE_UPDATED, json!({ "conversationKey": conversation_key, "slug": slug }));
        }
        Ok(false) => {} // stale — a newer message re-enqueued it
        Err(e) => log::warn!("[space] {conversation_key}: write failed: {e}"),
    }
}

/// The user-content prompt fed to the summary model: subject + the direction-tagged
/// thread text.
pub fn triage_user_prompt(input: &TriageInput) -> String {
    let date = input.newest_at.as_deref().map(|d| format!("Newest message sent: {d}\n")).unwrap_or_default();
    format!("Subject: {}\n{date}\n{}", input.subject.as_deref().unwrap_or("(no subject)"), input.thread_text)
}

/// Re-run triage + summaries for ONE conversation — the reader's "Process with"
/// action (mobile, an explicit summary lane) and "Re-run Jev" ([`rerun_jev`]).
/// The user is asking again, so both manual marks are dropped: Jev (and the
/// rules) decide the label afresh and the Space is re-filed. Summaries come from
/// `cfg` when given (an error fails the call — the user chose that engine);
/// with `None` the current summaries are kept (subject/snippet fallback when the
/// thread has none for its newest message). A Jev failure fails the call and
/// leaves the thread untouched. Writes the result (staleness-checked like the
/// worker), emits `triage-updated` / `space-updated`, and returns the
/// provenance tag it recorded.
pub async fn reprocess_conversation(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    cfg: Option<&BridgeConfig>,
    conversation_key: &str,
) -> Result<String, String> {
    let store = engine.store();
    let input = store
        .conversation_triage_input(conversation_key)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "conversation has no messages".to_string())?;
    let meta = store.triage_meta(conversation_key).map_err(|e| e.to_string())?.unwrap_or_default();
    let spaces = if store.space_classify_enabled() { store.effective_spaces() } else { Vec::new() };
    let verdict = match engine.jev_key() {
        Some(key) => {
            match jev_classify(&engine.jev_endpoint(), &key, &input, &store.triage_labels(), &spaces, input.deterministic.is_none() || input.rule_defers_to_jev())
                .await
            {
                Ok(v) => Some(v),
                Err(e) => {
                    match &e {
                        JevError::Unauthorized => engine.mark_jev_unauthorized(),
                        JevError::Blocked(m) => engine.mark_jev_blocked(m.clone()),
                        _ => {}
                    }
                    log::warn!("[triage] reprocess {conversation_key}: {e}");
                    return Err(e.to_string());
                }
            }
        }
        None => None,
    };
    let (medium, short, summary_source, meeting, title) = match cfg {
        Some(cfg) => {
            let (m, s, src, meeting, title) = model_summarize(&input, cfg, local).await?;
            (m, s, src, Some(meeting), Some(title))
        }
        None if meta.msg_key.as_deref() == Some(input.newest_msg_key.as_str()) => (
            meta.summary_medium.clone().unwrap_or_default(),
            meta.summary_short.clone().unwrap_or_default(),
            // Keep the `model:` part naming who wrote the kept summaries.
            meta.source.as_deref().unwrap_or("").split('+').filter(|p| p.starts_with("model:")).collect::<Vec<_>>().join("+"),
            None,
            None,
        ),
        None => {
            let (m, s) = deterministic_summaries(&input);
            (m, s, String::new(), None, None)
        }
    };
    store.clear_manual_triage(conversation_key).map_err(|e| e.to_string())?;
    // With no Jev answer (no key) a label that was manual stays as a plain value.
    let jev_label = verdict.as_ref().and_then(|v| v.label.clone());
    let soft = input.rule_defers_to_jev() && jev_label.is_some();
    let label = (if soft { jev_label.clone() } else { None })
        .or_else(|| input.deterministic.map(|l| l.as_str().to_string()))
        .or(jev_label)
        .or(meta.label);
    let priority = verdict.as_ref().and_then(|v| v.priority).or(meta.priority);
    let source = join_source(&[
        if soft { "" } else { input.det_source },
        &verdict.as_ref().map(|v| format!("jev:{}", v.model)).unwrap_or_default(),
        &summary_source,
    ]);
    if persist(engine, conversation_key, label.as_deref(), priority, &medium, &short, &input, &source)? {
        // `None` = no model ran (the kept summaries): leave the stored meeting alone.
        if let Some(meeting) = meeting {
            write_meeting(engine, &input.newest_msg_key, meeting.as_ref());
        }
        if let Some(title) = title {
            write_title(engine, conversation_key, title.as_deref());
        }
    }
    if let Some(slug) = verdict.as_ref().and_then(|v| v.space.as_deref()) {
        write_space(engine, conversation_key, slug, &input.newest_msg_key);
    }
    Ok(source)
}

/// Shown when "Re-run Jev" has nothing to run: no Jev key and no rule applies.
pub const NO_JEV_KEY: &str = "Add a Jev key in Settings to re-run triage";

/// "Re-run Jev" (desktop reader/list menus): [`reprocess_conversation`] with the
/// host's summary lane when it's up (else the summaries are kept). Errors with
/// [`NO_JEV_KEY`] when there is no key and no rule fires — nothing would change.
pub async fn rerun_jev(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    conversation_key: &str,
) -> Result<String, String> {
    if engine.jev_key().is_none() {
        let input = engine
            .store()
            .conversation_triage_input(conversation_key)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "conversation has no messages".to_string())?;
        if input.deterministic.is_none() {
            return Err(NO_JEV_KEY.to_string());
        }
    }
    let cfg = match engine.ai_config_snapshot() {
        Some(cfg) if summary_lane_ready(&cfg, local).await => Some(cfg),
        _ => None,
    };
    if cfg.is_none() {
        log::info!("[triage] rerun {conversation_key}: summary lane not ready — summaries kept, no meeting check");
    }
    reprocess_conversation(engine, local, cfg.as_ref(), conversation_key).await
}

/// Move a thread into a Space by hand: one of the effective Spaces (org +
/// personal) or the holding pen. It sticks (see [`SyncStore::set_manual_space`])
/// and emits `space-updated` (`{conversationKey, slug}`).
pub fn set_conversation_space(engine: &SyncEngine, conversation_key: &str, slug: &str) -> Result<(), String> {
    let store = engine.store();
    if slug != triage::HOLDING_PEN && !store.effective_spaces().iter().any(|s| s.slug == slug) {
        return Err(format!("unknown Space: {slug}"));
    }
    if !store.set_manual_space(conversation_key, slug).map_err(|e| e.to_string())? {
        return Err("conversation not found".to_string());
    }
    engine.emit_event(event::SPACE_UPDATED, json!({ "conversationKey": conversation_key, "slug": slug }));
    Ok(())
}

/// Set a thread's label by hand: an enabled label slug. It holds until a new
/// message arrives (see [`SyncStore::set_manual_label`]); priority and summaries
/// are kept. Emits `triage-updated` (`{conversationKey, label, priority, summaryShort}`).
pub fn set_conversation_label(engine: &SyncEngine, conversation_key: &str, label: &str) -> Result<(), String> {
    let store = engine.store();
    if !store.triage_labels().iter().any(|l| l.enabled && l.slug == label) {
        return Err(format!("unknown label: {label}"));
    }
    if !store.set_manual_label(conversation_key, label).map_err(|e| e.to_string())? {
        return Err("conversation not found".to_string());
    }
    let meta = store.triage_meta(conversation_key).map_err(|e| e.to_string())?.unwrap_or_default();
    engine.emit_event(
        event::TRIAGE_UPDATED,
        json!({
            "conversationKey": conversation_key,
            "label": label,
            "priority": meta.priority,
            "summaryShort": meta.summary_short,
        }),
    );
    Ok(())
}

/// Extract `{"medium","short"}` from a model response that may be wrapped in
/// prose or code fences, or truncated. `short` is clamped to one line. `None`
/// when neither summary is recoverable.
fn parse_summary_json(text: &str) -> Option<(String, String)> {
    let object = |t: &str| -> Option<(String, String)> {
        let (start, end) = (t.find('{')?, t.rfind('}')?);
        if end <= start {
            return None;
        }
        let v: serde_json::Value = serde_json::from_str(&t[start..=end]).ok()?;
        let field = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
        Some((field("medium"), field("short")))
    };
    let (medium, short) = object(text)
        .or_else(|| object(&strip_trailing_commas(text)))
        // Last resort: pull fields by name from a malformed/truncated object.
        .unwrap_or_else(|| {
            (json_str_field(text, "medium").unwrap_or_default(), json_str_field(text, "short").unwrap_or_default())
        });
    let (medium, short) = (medium.trim().to_string(), first_line(&short));
    (!medium.is_empty() || !short.is_empty()).then_some((medium, short))
}

/// First non-empty trimmed line — `short` is clamped to one line defensively.
fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").trim().to_string()
}

/// Drop a comma that directly precedes a closing `}`/`]` (ignoring whitespace).
fn strip_trailing_commas(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == ',' {
            let mut j = i + 1;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if j < chars.len() && (chars[j] == '}' || chars[j] == ']') {
                i += 1; // skip the dangling comma
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Extract a string value for `"key"` from possibly-broken/truncated JSON: find the key,
/// the next `:`, the opening quote, then read to the closing quote (honoring `\` escapes).
/// Returns `None` if the value is missing or the string never closes (truncated value).
fn json_str_field(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let after_key = &text[text.find(&needle)? + needle.len()..];
    let after_colon = &after_key[after_key.find(':')? + 1..];
    let body = &after_colon[after_colon.find('"')? + 1..];
    let mut out = String::new();
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            }
            '"' => return Some(out),
            _ => out.push(c),
        }
    }
    None
}

/// Summarize one conversation with the SAME lane + `[summary]` prompt the worker
/// uses — the email read-out's cache-miss path, so it never hand-rolls a second
/// summarizer. Returns `(medium, short)`, falling back to the deterministic
/// summaries when generation fails. `None` only when the conversation has no messages.
pub async fn summarize_conversation(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    conversation_key: &str,
) -> Option<(String, String)> {
    let input = engine.store().conversation_triage_input(conversation_key).ok().flatten()?;
    let (m, s, _, _, _) = summarize(engine, &input, Some(config), local).await;
    Some((m, s))
}

/// Deterministic (medium, short) summaries for a deterministically-labeled thread
/// — no model call. `short` is the subject; `medium` is a trimmed snippet of the
/// body (falling back to the subject when the body is empty).
pub fn deterministic_summaries(input: &TriageInput) -> (String, String) {
    let subject = input
        .subject
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("(no subject)");
    let short = truncate(subject.lines().next().unwrap_or(subject).trim(), 90);
    // Drop the per-message direction header lines we add for the model's context.
    let body: String = input
        .thread_text
        .lines()
        .filter(|l| {
            let t = l.trim();
            !t.is_empty()
                && !t.starts_with("From the owner (sent):")
                && !t.starts_with("From ")
        })
        .collect::<Vec<_>>()
        .join(" ");
    let medium = if body.trim().is_empty() { short.clone() } else { truncate(body.trim(), 220) };
    (medium, short)
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let t: String = s.chars().take(max).collect();
        format!("{t}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::{EventSink, NullSink};
    use crate::sync::store::{EvalSeedMessage, SyncStore};
    use crate::triage::ProcessingWindow;
    use async_trait::async_trait;
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// A generator that never returns — models a wedged on-device model or a hung
    /// HTTP request. The worker must time it out rather than block the drain.
    struct HangingGenerator;
    #[async_trait]
    impl LocalGenerator for HangingGenerator {
        async fn is_available(&self) -> bool {
            true
        }
        async fn generate(&self, _system: String, _user: String, _model: Option<String>) -> Result<String, String> {
            std::future::pending().await
        }
    }

    /// Records every emitted event.
    #[derive(Default)]
    struct Capture(std::sync::Mutex<Vec<(String, serde_json::Value)>>);
    impl EventSink for Capture {
        fn emit(&self, event: &str, payload: serde_json::Value) {
            self.0.lock().unwrap().push((event.to_string(), payload));
        }
    }

    fn seed(store: &SyncStore, key: &str, subject: &str, body: &str) {
        store
            .seed_eval_thread(
                key,
                Some(subject),
                &[EvalSeedMessage {
                    from: Some("sam@x.com"),
                    message_id_header: None,
                    body_plain: body,
                    body_html: None,
                    sent_by_owner: false,
                }],
            )
            .unwrap();
    }

    /// An ambiguous thread (`conv1`) and a rule-labelled bill (`bill`), enqueued.
    fn store_with_threads() -> Arc<SyncStore> {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed(&store, "conv1", "Re: lunch?", "Are you free for lunch tomorrow?");
        seed(&store, "bill", "Your bill", "Your monthly bill for account 123 is ready. Amount due: $40");
        // seed_eval_thread dates threads in 2024, so widen the window to enqueue them.
        store.set_processing_window(ProcessingWindow::Everything).unwrap();
        assert_eq!(store.backfill_triage_queue().unwrap(), 2);
        store
    }

    /// `(label, priority, source, summary_short, space)` for one conversation.
    fn row(store: &SyncStore, key: &str) -> (Option<String>, Option<f64>, Option<String>, Option<String>, Option<String>) {
        let conn = store.connection();
        let conn = conn.lock();
        conn.query_row(
            "SELECT triage_label, triage_priority, triage_source, ai_summary_short, space_slug FROM conversations WHERE key = ?1",
            [key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap()
    }

    fn jev_reply(label: &str, score: f64, space: Option<(&str, f64)>) -> ResponseTemplate {
        let mut answers = json!({
            "label": {"type": "choice", "choice": label, "probabilities": {label: 0.9}, "confidence": 0.8},
            "priority": {"type": "score", "score": score, "confidence": 0.7},
        });
        if let Some((slug, p)) = space {
            answers["space"] = json!({"type": "choice", "choice": slug, "probabilities": {slug: p}, "confidence": 0.5});
        }
        ResponseTemplate::new(200).set_body_json(json!({"model": "jev-1.13.0", "answers": answers}))
    }

    /// An engine whose host pushed an AI config with no usable summary lane (no
    /// OpenAI key) — summaries take the deterministic fallback.
    fn engine(store: Arc<SyncStore>, sink: Arc<dyn EventSink>) -> Arc<SyncEngine> {
        let engine = Arc::new(SyncEngine::new(store, sink));
        engine.set_ai_config(BridgeConfig {
            generation: GenSource::OpenAi,
            openai_key: None,
            model: "gpt-4o-mini".into(),
            on_device_model: None,
            concise: false,
            weather: None,
        });
        engine
    }

    async fn jev_engine(store: Arc<SyncStore>, server: &MockServer, sink: Arc<Capture>) -> Arc<SyncEngine> {
        let engine = engine(store, sink);
        engine.set_jev_endpoint(server.uri());
        engine.set_jev_key(Some("k".into()));
        engine
    }

    fn bodies(reqs: &[wiremock::Request]) -> Vec<serde_json::Value> {
        reqs.iter().map(|r| serde_json::from_slice(&r.body).unwrap()).collect()
    }

    #[tokio::test]
    async fn without_a_key_rules_label_and_ambiguous_stays_unlabelled_but_done() {
        let store = store_with_threads();
        let bare = Arc::new(SyncEngine::new(store.clone(), Arc::new(NullSink)));
        TriageWorker::new(bare).drain().await;
        assert_eq!(store.triage_progress().unwrap().pending, 2, "idles until the host pushes its AI config");

        TriageWorker::new(engine(store.clone(), Arc::new(NullSink))).drain().await;
        let (label, priority, source, short, _) = row(&store, "conv1");
        assert_eq!((label, priority), (None, None), "no key: the ambiguous thread stays unlabelled");
        assert_eq!(source.as_deref(), Some(""), "no rule, no Jev, no model");
        assert_eq!(short.as_deref(), Some("Re: lunch?"), "deterministic summary fallback");
        let (label, priority, source, _, _) = row(&store, "bill");
        assert_eq!(label.as_deref(), Some("payment_due"));
        assert_eq!(priority, None);
        assert_eq!(source.as_deref(), Some("rule:payment"));
        let p = store.triage_progress().unwrap();
        assert_eq!((p.pending, p.done, p.in_window), (0, 2, 2), "processed, not deferred forever");
    }

    #[tokio::test]
    async fn with_a_key_jev_labels_ambiguous_and_scores_rule_threads() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(jev_reply("needs_answer", 2.7, None)).mount(&server).await;
        let store = store_with_threads();
        let sink = Arc::new(Capture::default());
        let engine = jev_engine(store.clone(), &server, sink.clone()).await;
        TriageWorker::new(engine).drain().await;

        let (label, priority, source, _, _) = row(&store, "conv1");
        assert_eq!(label.as_deref(), Some("needs_answer"));
        assert_eq!(priority, Some(2.7));
        assert_eq!(source.as_deref(), Some("jev:jev-1.13.0"));
        // Bill wording is a soft rule: with a key Jev decides the label (a paid
        // receipt reads the same), and its answer wins.
        let (label, priority, source, _, _) = row(&store, "bill");
        assert_eq!(label.as_deref(), Some("needs_answer"));
        assert_eq!(priority, Some(2.7));
        assert_eq!(source.as_deref(), Some("jev:jev-1.13.0"));

        let sent = bodies(&server.received_requests().await.unwrap());
        assert_eq!(sent.len(), 2);
        let bill = sent.iter().find(|b| b["state"]["thread"]["subject"] == "Your bill").unwrap();
        assert!(bill["questions"].get("label").is_some(), "bill wording asks Jev for the label");
        assert!(bill["questions"].get("space").is_none(), "sorting off: no space question");
        assert_eq!(bill["model"], "jev-1.13.0");
        let events = sink.0.lock().unwrap();
        let updated = events.iter().find(|(e, p)| e == event::TRIAGE_UPDATED && p["conversationKey"] == "conv1").unwrap();
        assert_eq!(updated.1["priority"], 2.7);
        assert_eq!(updated.1["label"], "needs_answer");
    }

    #[tokio::test]
    async fn space_follows_the_probability_threshold() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(jev_reply("fyi", 0.4, Some(("sales", 0.4))))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST")).respond_with(jev_reply("fyi", 0.4, Some(("sales", 0.8)))).mount(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed(&store, "a", "Hello", "Some mail");
        store.set_processing_window(ProcessingWindow::Everything).unwrap();
        store.set_space_classify_enabled(true).unwrap();
        store.set_space_taxonomy(r#"[{"slug":"sales","name":"Sales","description":"deals"}]"#).unwrap();
        store.backfill_triage_queue().unwrap();
        let engine = jev_engine(store.clone(), &server, Arc::new(Capture::default())).await;
        let worker = TriageWorker::new(engine.clone());
        worker.drain().await;
        assert_eq!(row(&store, "a").4.as_deref(), Some(triage::HOLDING_PEN), "p < 0.5 → holding pen");

        // A second thread gets the confident answer.
        seed(&store, "b", "Quote", "Price for 200 units?");
        store.backfill_triage_queue().unwrap();
        worker.drain().await;
        assert_eq!(row(&store, "b").4.as_deref(), Some("sales"));
    }

    #[tokio::test]
    async fn out_of_credits_pauses_the_queue_without_skipping_threads() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(402).set_body_json(json!({ "error": { "message": "Out of credits" } })))
            .mount(&server)
            .await;
        let store = store_with_threads();
        let engine = jev_engine(store.clone(), &server, Arc::new(Capture::default())).await;
        let worker = TriageWorker::new(engine.clone());
        worker.drain().await;
        worker.drain().await; // inside the probe interval: no call

        assert_eq!(server.received_requests().await.unwrap().len(), 1, "one 402, then paused");
        assert_eq!(engine.jev_error().as_deref(), Some("Out of credits"));
        // Nothing was marked done without Jev, and nothing was charged toward poison.
        assert_eq!(store.triage_progress().unwrap().pending, 2);
        assert_eq!(row(&store, "conv1").0, None);
        let p = progress_json(&engine, &store.triage_progress().unwrap());
        assert_eq!(p["jevError"], "Out of credits");

        assert!(engine.clear_jev_blocked(), "an answered call clears it");
        assert_eq!(engine.jev_error(), None);
    }

    #[tokio::test]
    async fn unauthorized_stops_calling_until_the_key_changes() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(401)).mount(&server).await;
        let store = store_with_threads();
        let engine = jev_engine(store.clone(), &server, Arc::new(Capture::default())).await;
        TriageWorker::new(engine.clone()).drain().await;

        assert_eq!(server.received_requests().await.unwrap().len(), 1, "one 401, then no more calls");
        assert_eq!(engine.jev_status(), crate::typesafe::JevStatus::Unauthorized);
        assert!(engine.jev_key().is_none());
        // Both threads were still processed without Jev.
        assert_eq!(row(&store, "conv1").0, None);
        assert_eq!(row(&store, "bill").0.as_deref(), Some("payment_due"));
        assert_eq!(store.triage_progress().unwrap().pending, 0);

        engine.set_jev_key(Some("new".into()));
        assert_eq!(engine.jev_status(), crate::typesafe::JevStatus::Ok);
    }

    #[tokio::test]
    async fn transient_errors_defer_without_writing() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(529)).mount(&server).await;
        let store = store_with_threads();
        let engine = jev_engine(store.clone(), &server, Arc::new(Capture::default())).await;
        TriageWorker::new(engine).drain().await;

        assert_eq!(row(&store, "conv1").0, None);
        let conn = store.connection();
        let conn = conn.lock();
        let (deferred, processed): (i64, i64) = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM ai_triage_queue WHERE status = 'deferred'),
                        (SELECT COUNT(*) FROM conversations WHERE ai_meta_msg_key IS NOT NULL)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((deferred, processed), (2, 0), "both deferred for retry, nothing written");
    }

    #[tokio::test]
    async fn a_key_arriving_later_fills_label_and_priority_keeping_summaries() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(jev_reply("needs_answer", 3.6, None)).mount(&server).await;
        let store = store_with_threads();
        let engine = engine(store.clone(), Arc::new(Capture::default()));
        engine.set_jev_endpoint(server.uri());
        let worker = TriageWorker::new(engine.clone());
        worker.drain().await; // no key yet
        assert_eq!(row(&store, "conv1").0, None);

        engine.set_jev_key(Some("k".into()));
        assert_eq!(store.triage_progress().unwrap().pending, 2, "both re-enqueued (label or priority missing)");
        worker.drain().await;
        let (label, priority, source, short, _) = row(&store, "conv1");
        assert_eq!(label.as_deref(), Some("needs_answer"));
        assert_eq!(priority, Some(3.6));
        assert_eq!(source.as_deref(), Some("jev:jev-1.13.0"));
        assert_eq!(short.as_deref(), Some("Re: lunch?"), "fast path keeps the summaries");
        let (label, priority, source, _, _) = row(&store, "bill");
        assert_eq!((label.as_deref(), priority), (Some("payment_due"), Some(3.6)));
        assert_eq!(source.as_deref(), Some("rule:payment+jev:jev-1.13.0"));
        let sent = bodies(&server.received_requests().await.unwrap());
        assert!(sent.iter().all(|b| b["questions"].get("priority").is_some()));
        assert_eq!(sent.iter().filter(|b| b["questions"].get("label").is_some()).count(), 1);
    }

    // Regression: a summary generation that hangs must not wedge the single-threaded
    // drain (the recurring "Catching up" freeze). Each timed-out attempt charges the
    // job and backs it off; across passes it marches to the attempt cap and is
    // finalized with a deterministic fallback label, leaving `pending == 0`.
    // `start_paused` lets tokio auto-advance through each 90s timeout instantly.
    #[tokio::test(start_paused = true)]
    async fn hung_generation_times_out_instead_of_wedging_the_drain() {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed(&store, "conv1", "Re: lunch?", "Are you free for lunch tomorrow?");
        store.set_processing_window(ProcessingWindow::Everything).unwrap();
        assert_eq!(store.backfill_triage_queue().unwrap(), 1, "the thread is enqueued");

        let engine = Arc::new(SyncEngine::new(store.clone(), Arc::new(NullSink)));
        engine.set_generator(Arc::new(HangingGenerator));
        engine.set_ai_config(BridgeConfig {
            generation: GenSource::OnDevice,
            openai_key: None,
            model: "gpt-4o".into(),
            on_device_model: Some("qwen".into()),
            concise: false,
            weather: None,
        });

        // Age every queue row past the fail-backoff so the failed job is claimable again.
        let age = |store: &SyncStore| {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute("UPDATE ai_triage_queue SET updated_at = '2000-01-01T00:00:00+00:00'", []).unwrap();
        };
        let worker = TriageWorker::new(engine.clone());
        for _ in 0..5 {
            worker.drain().await;
            age(&store);
        }
        assert_eq!(store.triage_progress().unwrap().pending, 0, "a perpetually-hanging job must exhaust");
        assert_eq!(row(&store, "conv1").2.as_deref(), Some("fallback:exhausted"));
    }

    fn sql(store: &SyncStore, q: &str) {
        store.connection().lock().execute(q, []).unwrap();
    }

    fn enqueue(store: &SyncStore, key: &str) {
        sql(
            store,
            &format!(
                "INSERT INTO ai_triage_queue (conversation_key, priority, status, attempts, created_at, updated_at)
                 VALUES ('{key}', '2024-01-01T00:00:00+00:00', 'pending', 0, 'x', 'x')
                 ON CONFLICT(conversation_key) DO UPDATE SET status = 'pending', attempts = 0"
            ),
        );
    }

    #[tokio::test]
    async fn a_manual_space_survives_refiling_and_the_worker() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(jev_reply("fyi", 1.0, Some(("sales", 0.9)))).mount(&server).await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed(&store, "a", "Hello", "Some mail");
        seed(&store, "b", "Other", "More mail");
        store.set_processing_window(ProcessingWindow::Everything).unwrap();
        store.set_space_classify_enabled(true).unwrap();
        store.set_space_taxonomy(r#"[{"slug":"sales","name":"Sales","description":"deals"}]"#).unwrap();
        store.backfill_triage_queue().unwrap();
        let sink = Arc::new(Capture::default());
        let engine = jev_engine(store.clone(), &server, sink.clone()).await;

        assert!(set_conversation_space(&engine, "a", "nope").is_err(), "unknown slug");
        assert!(set_conversation_space(&engine, "zzz", "sales").is_err(), "unknown conversation");
        set_conversation_space(&engine, "a", "reading").unwrap(); // a personal Space
        set_conversation_space(&engine, "b", triage::HOLDING_PEN).unwrap();
        assert!(sink.0.lock().unwrap().iter().any(|(e, p)| e == event::SPACE_UPDATED && p["slug"] == "reading"));

        // The worker files everything else, but not the hand-placed threads.
        TriageWorker::new(engine.clone()).drain().await;
        assert_eq!(row(&store, "a").4.as_deref(), Some("reading"));
        assert_eq!(row(&store, "b").4.as_deref(), Some(triage::HOLDING_PEN));
        let sent = bodies(&server.received_requests().await.unwrap());
        assert!(sent.iter().all(|b| b["questions"].get("space").is_none()), "a manual Space is never asked");

        // An org Space change re-files everything except the manual placements…
        store
            .set_space_taxonomy(r#"[{"slug":"sales","name":"Sales","description":"deals"},{"slug":"ops","name":"Ops","description":"ops"}]"#)
            .unwrap();
        assert_eq!(row(&store, "a").4.as_deref(), Some("reading"));
        assert_eq!(row(&store, "b").4.as_deref(), Some(triage::HOLDING_PEN));
        // …unless the hand-picked Space itself is gone: then Jev files it again.
        store.set_personal_spaces(vec![]).unwrap();
        assert_eq!(row(&store, "a").4, None);
        assert_eq!(store.backfill_space_queue().unwrap(), 0, "already queued by the re-file");
        TriageWorker::new(engine).drain().await;
        assert_eq!(row(&store, "a").4.as_deref(), Some("sales"));
        assert_eq!(row(&store, "b").4.as_deref(), Some(triage::HOLDING_PEN), "the holding pen never goes away");
    }

    #[tokio::test]
    async fn a_manual_label_holds_until_a_new_message_arrives() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(jev_reply("needs_answer", 2.0, None)).mount(&server).await;
        let store = store_with_threads();
        let sink = Arc::new(Capture::default());
        let engine = jev_engine(store.clone(), &server, sink.clone()).await;
        let worker = TriageWorker::new(engine.clone());
        worker.drain().await;
        assert_eq!(row(&store, "conv1").0.as_deref(), Some("needs_answer"));

        assert!(set_conversation_label(&engine, "conv1", "nope").is_err(), "unknown label");
        let mut labels = store.triage_labels();
        labels.iter_mut().find(|l| l.slug == "resolved").unwrap().enabled = false;
        store.set_triage_labels(labels).unwrap();
        assert!(set_conversation_label(&engine, "conv1", "resolved").is_err(), "disabled label");
        set_conversation_label(&engine, "conv1", "fyi").unwrap();
        set_conversation_label(&engine, "bill", "scheduling").unwrap(); // beats the rule too
        let (label, priority, source, _, _) = row(&store, "conv1");
        assert_eq!((label.as_deref(), priority, source.as_deref()), (Some("fyi"), Some(2.0), Some(triage::MANUAL_SOURCE)));
        let updated = sink.0.lock().unwrap().iter().rev().find(|(e, p)| e == event::TRIAGE_UPDATED && p["conversationKey"] == "conv1").cloned().unwrap();
        assert_eq!((updated.1["label"].as_str(), updated.1["priority"].as_f64()), (Some("fyi"), Some(2.0)));

        // The fast path (a key re-push re-queues a missing priority) keeps the label.
        sql(&store, "UPDATE conversations SET triage_priority = NULL WHERE key = 'conv1'");
        assert_eq!(store.requeue_for_jev().unwrap(), 1);
        worker.drain().await;
        let (label, priority, source, _, _) = row(&store, "conv1");
        assert_eq!((label.as_deref(), priority), (Some("fyi"), Some(2.0)));
        assert_eq!(source.as_deref(), Some("manual+jev:jev-1.13.0"));

        // A full re-run with no new message (e.g. the anchor was reset) keeps it too.
        sql(&store, "UPDATE conversations SET ai_meta_msg_key = NULL");
        store.backfill_triage_queue().unwrap();
        worker.drain().await;
        assert_eq!(row(&store, "conv1").0.as_deref(), Some("fyi"));
        assert_eq!(row(&store, "conv1").2.as_deref(), Some("manual+jev:jev-1.13.0"));
        assert_eq!(row(&store, "bill").0.as_deref(), Some("scheduling"));
        let sent = bodies(&server.received_requests().await.unwrap());
        assert!(sent.iter().skip(2).all(|b| b["questions"].get("label").is_none()), "a manual label is never asked");

        // New mail: a new situation, so Jev judges the label again.
        sql(
            &store,
            "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, is_inbound, created_at)
             VALUES ('conv1_m9', 'conv1', 'eval', 'sam@x.com', 'Any news?', 1, '2024-01-02T00:00:00+00:00')",
        );
        enqueue(&store, "conv1");
        worker.drain().await;
        let (label, _, source, _, _) = row(&store, "conv1");
        assert_eq!((label.as_deref(), source.as_deref()), (Some("needs_answer"), Some("jev:jev-1.13.0")));
    }

    #[tokio::test]
    async fn rerun_jev_drops_the_manual_marks() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(jev_reply("needs_answer", 3.0, Some(("sales", 0.9)))).mount(&server).await;
        let store = store_with_threads();
        store.set_space_classify_enabled(true).unwrap();
        store.set_space_taxonomy(r#"[{"slug":"sales","name":"Sales","description":"deals"}]"#).unwrap();
        let engine = engine(store.clone(), Arc::new(Capture::default()));
        engine.set_jev_endpoint(server.uri());
        TriageWorker::new(engine.clone()).drain().await; // no key: summaries written, conv1 unlabelled
        let short = row(&store, "conv1").3;

        // No key and no rule: nothing to re-run.
        assert_eq!(rerun_jev(&engine, None, "conv1").await.unwrap_err(), NO_JEV_KEY);

        engine.set_jev_key(Some("k".into()));
        set_conversation_label(&engine, "conv1", "fyi").unwrap();
        set_conversation_space(&engine, "conv1", "reading").unwrap();
        let source = rerun_jev(&engine, None, "conv1").await.unwrap();
        assert_eq!(source, "jev:jev-1.13.0");
        let (label, priority, _, kept, space) = row(&store, "conv1");
        assert_eq!((label.as_deref(), priority, space.as_deref()), (Some("needs_answer"), Some(3.0), Some("sales")));
        assert_eq!(kept, short, "no summary lane: summaries kept");
        let meta = store.triage_meta("conv1").unwrap().unwrap();
        assert!(!meta.space_manual && meta.label_manual_msg_key.is_none());
    }

    #[test]
    fn parses_summary_json_tolerantly() {
        assert_eq!(
            parse_summary_json(r#"{"medium":"They asked for the report.","short":"Send the report"}"#),
            Some(("They asked for the report.".into(), "Send the report".into()))
        );
        let fenced = "Sure!\n```json\n{\"medium\": \"Newsletter.\", \"short\": \"Weekly digest\"}\n```";
        assert_eq!(parse_summary_json(fenced).unwrap().1, "Weekly digest");
        assert_eq!(parse_summary_json(r#"{"medium":"m","short":"line one\nline two"}"#).unwrap().1, "line one");
        assert_eq!(parse_summary_json(r#"{"medium":"m","short":"s",}"#).unwrap().1, "s");
        // Truncated mid-medium: the complete short still lands.
        assert_eq!(parse_summary_json(r#"{"short": "Pay", "medium": "2-4 weeks before the"#).unwrap(), ("".into(), "Pay".into()));
        assert_eq!(parse_summary_json("no json here"), None);
        // The meeting rides along; a missing or malformed one is just no meeting.
        let with = r#"{"medium":"m","short":"s","meeting":{"title":"Viewing","start":"2026-10-07T16:30","end":null,"location":"Rotterdam"}}"#;
        assert_eq!(parse_meeting_json(with).unwrap().start, "2026-10-07T16:30:00");
        assert_eq!(parse_summary_json(with).unwrap().1, "s");
        assert_eq!(parse_meeting_json(r#"{"medium":"m","short":"s","meeting":null}"#), None);
        assert_eq!(parse_meeting_json(r#"{"medium":"m","short":"s"}"#), None);
        assert_eq!(parse_meeting_reply(r#"{"title":"Call","start":"2026-10-07T09:00"}"#).unwrap().title, "Call");
        assert_eq!(parse_meeting_reply("null"), None);
        assert!(has_clock_time("vrijdag 7 oktober 2026 om 16:30 uur"));
        assert!(has_clock_time("at 4 pm tomorrow") && has_clock_time("om 16 uur") && has_clock_time("16h30"));
        assert!(!has_clock_time("Pay €32.42 within 30 days, ref 52295211771071"));
        assert!(!has_clock_time("version 1.2.3 released on 2026-10-07"));
        assert_eq!(parse_summary_json(r#"{"medium":"","short":""}"#), None);
    }

    #[test]
    fn parses_the_title_next_to_the_summaries() {
        let t = |s: &str| parse_summary_title(s);
        assert_eq!(
            t(r#"{"medium":"m","short":"s","title":"Pay Schiphol Privium membership invoice","meeting":null}"#).as_deref(),
            Some("Pay Schiphol Privium membership invoice")
        );
        // Clamped to one line, trailing period dropped, ≤ 80 chars.
        assert_eq!(t(r#"{"title":"Reply to Chadi.\nmore"}"#).as_deref(), Some("Reply to Chadi"));
        assert_eq!(t(&format!(r#"{{"title":"{}"}}"#, "x".repeat(200))).unwrap().chars().count(), TITLE_MAX);
        // Trailing comma / truncated object: still recovered.
        assert_eq!(t(r#"{"medium":"m","title":"Sign the KVK amendment",}"#).as_deref(), Some("Sign the KVK amendment"));
        assert_eq!(t(r#"{"short":"s","title":"Review the ADCB statement","medium":"cut off"#).as_deref(), Some("Review the ADCB statement"));
        // Omitted (an old [summary] override) or empty → None; the meeting's own title never counts.
        assert_eq!(t(r#"{"medium":"m","short":"s"}"#), None);
        assert_eq!(t(r#"{"medium":"m","short":"s","title":"  "}"#), None);
        assert_eq!(t(r#"{"medium":"m","short":"s","meeting":{"title":"Viewing","start":"2026-10-07T16:30"}}"#), None);
        assert_eq!(t(r#"{"short":"s","meeting":{"title":"Viewing","start":"2026-10-07T16:"#), None);
        assert_eq!(t("no json here"), None);
    }

    /// A summary lane that always answers `reply`.
    struct ReplyGenerator(&'static str);
    #[async_trait]
    impl LocalGenerator for ReplyGenerator {
        async fn is_available(&self) -> bool {
            true
        }
        async fn generate(&self, _system: String, _user: String, _model: Option<String>) -> Result<String, String> {
            Ok(self.0.to_string())
        }
    }

    fn title_of(store: &SyncStore, key: &str) -> Option<String> {
        let conn = store.connection();
        let conn = conn.lock();
        conn.query_row("SELECT next_action_title FROM conversations WHERE key = ?1", [key], |r| r.get(0)).unwrap()
    }

    async fn drain_with(store: &Arc<SyncStore>, reply: &'static str) {
        let engine = Arc::new(SyncEngine::new(store.clone(), Arc::new(NullSink)));
        engine.set_generator(Arc::new(ReplyGenerator(reply)));
        engine.set_ai_config(BridgeConfig {
            generation: GenSource::OnDevice,
            openai_key: None,
            model: "gpt-4o".into(),
            on_device_model: Some("qwen".into()),
            concise: false,
            weather: None,
        });
        TriageWorker::new(engine).drain().await;
    }

    #[tokio::test]
    async fn the_summary_call_writes_the_title_and_a_missing_one_clears_it() {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        seed(&store, "conv1", "factuurnummer 1186795 (Dossier", "Graag betalen voor 24 oktober: € 386,00");
        store.set_processing_window(ProcessingWindow::Everything).unwrap();
        store.backfill_triage_queue().unwrap();
        drain_with(&store, r#"{"medium":"Invoice.","short":"Pay €386","title":"Pay the dossier invoice 1186795","meeting":null}"#)
            .await;
        assert_eq!(row(&store, "conv1").3.as_deref(), Some("Pay €386"), "summaries unchanged");
        assert_eq!(title_of(&store, "conv1").as_deref(), Some("Pay the dossier invoice 1186795"));

        // A model that omits the field (an old override) leaves the title NULL.
        enqueue(&store, "conv1");
        sql(&store, "UPDATE conversations SET ai_meta_msg_key = NULL WHERE key = 'conv1'");
        drain_with(&store, r#"{"medium":"Invoice.","short":"Pay €386","meeting":null}"#).await;
        assert_eq!(row(&store, "conv1").3.as_deref(), Some("Pay €386"));
        assert_eq!(title_of(&store, "conv1"), None);
    }

    #[test]
    fn meeting_needs_a_clock_time_in_the_newest_message() {
        let input = |text: &str| TriageInput {
            subject: None,
            thread_text: String::new(),
            newest_msg_key: "m".into(),
            newest_at: Some("2026-09-28T12:40:33+00:00".into()),
            deterministic: None,
            det_source: "",
            signals: Default::default(),
            owner: String::new(),
            messages: vec![crate::triage::JevMessage { direction: "received".into(), from: "w".into(), text: text.into() }],
        };
        let at = |start: &str| DetectedMeeting { title: "Visit".into(), start: start.into(), end: None, location: None };
        // The two false banners: a proposal with no clock time, and a meeting before the mail.
        assert!(!meeting_is_plausible(&input("In principe zou ik woensdagochtend beschikbaar zijn."), &at("2026-09-30T09:00:00")));
        assert!(!meeting_is_plausible(&input("Confirmed for 16:30."), &at("2026-09-26T16:30:00")));
        assert!(meeting_is_plausible(&input("Tot woensdag om 10:00 op kantoor."), &at("2026-09-30T10:00:00")));
    }

    #[test]
    fn provenance_joins_and_inserts_jev() {
        assert_eq!(join_source(&["rule:action", "", "model:openai:x"]), "rule:action+model:openai:x");
        assert_eq!(with_jev_part("rule:action+model:openai:x", "jev-1.13.0"), "rule:action+jev:jev-1.13.0+model:openai:x");
        assert_eq!(with_jev_part("model:on_device:q+jev:old", "jev-2"), "jev:jev-2+model:on_device:q");
        assert_eq!(with_jev_part("", "jev-1.13.0"), "jev:jev-1.13.0");
        assert_eq!(with_jev_part("manual", "jev-1.13.0"), "manual+jev:jev-1.13.0");
    }

    #[test]
    fn json_str_field_honors_escapes() {
        assert_eq!(json_str_field(r#"{"short":"a \"quote\" here"}"#, "short").as_deref(), Some(r#"a "quote" here"#));
        assert_eq!(json_str_field(r#"{"label":"fyi"}"#, "medium"), None);
    }
}

// Agentic filters — local CLI agent invocation. See docs/Agentic-Filters.md.
//
// These are OUTBOUND processes we spawn (Claude Code, Codex, OpenCode, Gemini),
// distinct from the inbound MCP `agents` subsystem in `crate::mcp`.

pub mod adapter;
pub mod adapters;
pub mod ai_bridge;
pub mod commands;
pub mod detect;
pub mod harness;
pub mod runner;
pub mod store;

// The portable rule engine (Tier-0 conditions, Tier-1 gate, built-in actions) now
// lives in `inbox2-core` so the native mobile apps share it. Re-exported under the
// historical module names so the desktop-only runner/store keep using
// `super::rules` / `super::gate` / `super::actions` unchanged.
pub use inbox2_core::rules::conditions as rules;
pub use inbox2_core::rules::{actions, gate};

pub use adapter::{AgentAdapter, DetectedAgent, PermissionMode, RunContext};
pub use adapters::{adapter_for, all_adapters};
pub use detect::detect_all;
pub use harness::{
    build_scratch, evaluate_result, HarnessAttachment, MessageInput, RunOutcome, PREAMBLE,
};

use std::path::Path;
use std::sync::Arc;

use tokio::sync::Mutex;

use inbox2_core::rules::OnDeviceAi;

use crate::ai::inference::AIInferenceEngine;
use crate::sync::engine::SyncEngine;

/// The process's agent store + runner, once `build_runner` ran (bus RPC reads it).
pub static HOSTED: std::sync::OnceLock<commands::LocalAgentState> = std::sync::OnceLock::new();

/// Build the agent-run store (healing a stale dev schema) and the background
/// `AgentRunner` that scans local-channel mail and triggers agents. Shared by the
/// desktop app and the headless `engine_daemon`, so rule triggering runs wherever
/// the engine is hosted — not just inside the GUI.
///
/// The caller spawns `runner.run()` on its own runtime and (in the GUI) manages
/// the returned store as Tauri state. `ai_engine` is the warmed Tier-A inference
/// engine for Tier-1 gates; pass `None` to run Tier-0 (static) rules only —
/// gated rules then fail closed.
pub fn build_runner(
    engine: Arc<SyncEngine>,
    data_dir: &Path,
    ai_engine: Option<Arc<Mutex<AIInferenceEngine>>>,
) -> (Arc<store::AgentRunStore>, Arc<runner::AgentRunner>) {
    let agent_store = Arc::new(store::AgentRunStore::new(engine.store().connection()));
    // Heal a dev DB whose agentic tables predate a schema edit. No-op once current.
    if let Err(e) = agent_store.ensure_schema() {
        log::warn!("agentic-filters schema reconcile failed: {e}");
    }
    // Adapt the concrete ONNX engine to core's host-agnostic `OnDeviceAi` seam.
    let ai: Option<Arc<dyn OnDeviceAi>> =
        ai_engine.map(|e| Arc::new(ai_bridge::InferenceAi(e)) as Arc<dyn OnDeviceAi>);
    let runner = Arc::new(runner::AgentRunner::new(
        agent_store.clone(),
        data_dir,
        ai,
        Some(engine),
    ));
    // ponytail: one runner per process, so the bus RPC (sync/rpc.rs) finds it here
    // instead of threading it through EngineRpc's two construction sites.
    let _ = HOSTED.set(commands::LocalAgentState { store: agent_store.clone(), runner: runner.clone() });
    (agent_store, runner)
}

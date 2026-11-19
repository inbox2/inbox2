//! Tauri commands for the async triage + multi-level summary subsystem: the
//! processing window get/set, a progress snapshot, and pushing the user's AI
//! model selection to the background worker.
//!
//! These read/write the shared SQLite store directly (the same DB the host's
//! worker drains), so they work whether or not this process hosts the engine.
//! The `set_*` paths additionally nudge the in-process worker; an off-host
//! instance relies on the host worker's 5-second poll to notice.

use tauri::State;

use super::SyncState;
use inbox2_core::bridge::agent::{BridgeConfig, GenSource};
use inbox2_core::bridge::prompts;
use inbox2_core::triage::{ProcessingWindow, SpaceDef, TriageLabelDef};

/// The configured processing window (`1_month` | `3_months` | `6_months` |
/// `1_year` | `everything`).
#[tauri::command]
pub fn get_processing_window(sync: State<'_, SyncState>) -> Result<String, String> {
    Ok(sync.engine.store().processing_window().as_str().to_string())
}

/// Set the processing window. Widening it backfills newly-in-window conversations
/// and wakes the worker. Errors on an unknown value.
#[tauri::command]
pub fn set_processing_window(sync: State<'_, SyncState>, window: String) -> Result<(), String> {
    let w = ProcessingWindow::from_str(&window)
        .ok_or_else(|| format!("unknown window: {window}"))?;
    sync.engine.store().set_processing_window(w).map_err(|e| e.to_string())?;
    sync.engine.store().backfill_triage_queue().map_err(|e| e.to_string())?;
    sync.engine.ai_scan_notify().notify_one();
    Ok(())
}

/// Triage progress as JSON `{inWindow, done, pending, currentDate, jevStatus}`
/// for a cold start (live updates arrive as `triage-progress` events).
/// `jevStatus` is `missing` | `ok` | `unauthorized`.
#[tauri::command]
pub fn triage_progress(sync: State<'_, SyncState>) -> Result<serde_json::Value, String> {
    let p = sync.engine.store().triage_progress().map_err(|e| e.to_string())?;
    Ok(inbox2_core::ai_worker::progress_json(&sync.engine, &p))
}

/// Run the triage eval harness over a fixtures JSON document: the rules, then
/// Jev with the engine's live key and labels — so the Triage Lab's scores are
/// what real mail would get. Returns the `EvalReport` as JSON.
#[tauri::command]
pub async fn triage_eval(
    sync: State<'_, SyncState>,
    fixtures_json: String,
) -> Result<serde_json::Value, String> {
    let cases = inbox2_core::triage_eval::parse_cases(&fixtures_json)?;
    let engine = sync.engine.clone();
    let (key, endpoint) = (engine.jev_key(), engine.jev_endpoint());
    let lane = key.as_deref().map(|key| inbox2_core::triage_eval::JevLane { endpoint: &endpoint, key });
    let labels = engine.store().triage_labels();
    let report = inbox2_core::triage_eval::run(cases, lane, &labels).await;
    serde_json::to_value(&report).map_err(|e| e.to_string())
}

/// Push the user's Jev key (secret `typesafe_api_key`; `null`/empty clears). A
/// new key re-enqueues in-window threads still missing a label, priority or
/// space and wakes the worker. The desktop also loads the saved key at startup.
#[tauri::command]
pub fn set_jev_key(sync: State<'_, SyncState>, key: Option<String>) {
    sync.engine.set_jev_key(key);
}

/// Check a Jev key with one minimal real call (Settings "Test & save"). The
/// error string is user-presentable.
#[tauri::command]
pub async fn validate_jev_key(sync: State<'_, SyncState>, key: String) -> Result<(), String> {
    let endpoint = sync.engine.jev_endpoint();
    inbox2_core::typesafe::validate_key(&endpoint, &key).await
}

/// The triage labels (built-ins + custom), position order:
/// `[{slug,name,description,not_for,color,builtin,enabled},…]`.
#[tauri::command]
pub fn get_triage_labels(sync: State<'_, SyncState>) -> Vec<TriageLabelDef> {
    sync.engine.store().triage_labels()
}

/// Replace the triage label list (validated: slugs `[a-z0-9_]{1,40}`, unique,
/// not `no_match`; every built-in present; `fyi` enabled; name + description
/// required; `builtin` recomputed). Returns the list as stored.
#[tauri::command]
pub fn set_triage_labels(
    sync: State<'_, SyncState>,
    labels: Vec<TriageLabelDef>,
) -> Result<Vec<TriageLabelDef>, String> {
    sync.engine.store().set_triage_labels(labels).map_err(|e| e.to_string())
}

/// "Re-run Jev" for ONE conversation (reader/list Triage menus). The rules are
/// evaluated fresh, Jev decides what they leave open (label, priority, Space),
/// and a hand-set label/Space is dropped — the user asked Jev again. Summaries
/// come from the configured lane when it's up, else they're kept. Writes the
/// result, fires `triage-updated`/`space-updated`, returns the provenance tag.
/// Errors "Add a Jev key in Settings to re-run triage" when there's no key and
/// no rule applies.
#[tauri::command]
pub async fn retriage_conversation(
    sync: State<'_, SyncState>,
    conversation_key: String,
) -> Result<String, String> {
    let engine = sync.engine.clone();
    let generator = engine.generator_handle();
    inbox2_core::ai_worker::rerun_jev(&engine, generator.as_ref(), &conversation_key).await
}

/// Move a conversation into a Space by hand: a slug from `get_effective_spaces`
/// or the holding pen `triage`. Sticks until "Re-run Jev". Fires `space-updated`
/// (`{conversationKey, slug}`).
#[tauri::command]
pub fn set_conversation_space(sync: State<'_, SyncState>, conversation_key: String, slug: String) -> Result<(), String> {
    inbox2_core::ai_worker::set_conversation_space(&sync.engine, &conversation_key, &slug)
}

/// Set a conversation's triage label by hand (an enabled label slug). Holds
/// until a new message arrives in the thread. Fires `triage-updated`
/// (`{conversationKey, label, priority, summaryShort}`).
#[tauri::command]
pub fn set_conversation_label(sync: State<'_, SyncState>, conversation_key: String, label: String) -> Result<(), String> {
    inbox2_core::ai_worker::set_conversation_label(&sync.engine, &conversation_key, &label)
}

/// The Spaces Jev files into (org as pushed, then personal; deduped) — the
/// list `set_conversation_space` accepts, minus the holding pen `triage`.
#[tauri::command]
pub fn get_effective_spaces(sync: State<'_, SyncState>) -> Vec<SpaceDef> {
    sync.engine.store().effective_spaces()
}

/// Whether Space sorting (Jev) is enabled.
#[tauri::command]
pub fn get_space_classify_enabled(sync: State<'_, SyncState>) -> Result<bool, String> {
    Ok(sync.engine.store().space_classify_enabled())
}

/// Toggle Space sorting (Settings → Triage & sync). Enabling backfills every
/// in-window thread with no Space yet — already-triaged threads take the
/// worker's fast path (one Jev call, no summary re-run) — and wakes the worker.
#[tauri::command]
pub fn set_space_classify_enabled(sync: State<'_, SyncState>, enabled: bool) -> Result<(), String> {
    sync.engine.store().set_space_classify_enabled(enabled).map_err(|e| e.to_string())?;
    if enabled {
        sync.engine.store().backfill_space_queue().map_err(|e| e.to_string())?;
        sync.engine.ai_scan_notify().notify_one();
    }
    Ok(())
}

/// Push the org's classifiable Spaces for Jev to file into — JSON
/// `[{slug,name,description,not_for},…]` (legacy `[["slug","description"],…]`
/// still accepted; the web layer syncs this whenever it loads the org's
/// spaces). Invalid JSON errors.
#[tauri::command]
pub fn set_space_taxonomy(sync: State<'_, SyncState>, spaces_json: String) -> Result<(), String> {
    let requeued = sync.engine.store().set_space_taxonomy(&spaces_json).map_err(|e| e.to_string())?;
    if requeued > 0 {
        sync.engine.ai_scan_notify().notify_one();
    }
    Ok(())
}

/// This device's personal Spaces (defaults: Reading, Personal). Jev files into
/// the org's Spaces plus these; they are never shown to the team.
#[tauri::command]
pub fn get_personal_spaces(sync: State<'_, SyncState>) -> Vec<SpaceDef> {
    sync.engine.store().personal_spaces()
}

/// Replace the personal Spaces (validated: slugs `[a-z0-9_-]{1,40}`, unique,
/// not `triage`/`no_match`; a name on each). A changed list re-files Spaces like
/// an org taxonomy change and wakes the worker. Returns the list as stored.
#[tauri::command]
pub fn set_personal_spaces(sync: State<'_, SyncState>, spaces: Vec<SpaceDef>) -> Result<Vec<SpaceDef>, String> {
    let (stored, requeued) = sync.engine.store().set_personal_spaces(spaces).map_err(|e| e.to_string())?;
    if requeued > 0 {
        sync.engine.ai_scan_notify().notify_one();
    }
    Ok(stored)
}

/// The embedded starter fixtures (JSON text) — seeds the Triage Lab's editor.
#[tauri::command]
pub fn triage_eval_fixtures() -> String {
    inbox2_core::triage_eval::STARTER_FIXTURES.to_string()
}

/// Build an eval case from a REAL conversation (the Lab's mail search →
/// "add as test message"). Returns the `EvalCase` JSON, `expected` unset.
#[tauri::command]
pub fn triage_eval_case(
    sync: State<'_, SyncState>,
    conversation_key: String,
) -> Result<serde_json::Value, String> {
    let case = sync
        .engine
        .store()
        .eval_case_for_conversation(&conversation_key)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "conversation has no messages".to_string())?;
    serde_json::to_value(&case).map_err(|e| e.to_string())
}

/// Where the effective AI lane choice is remembered for hosts without the
/// desktop window (engine_daemon, the bus): `openai` or `on_device`. The window
/// keeps the picker in its own storage; this is the engine-side copy, written on
/// every `set_ai_config`.
pub const AI_GENERATION_SETTING: &str = "ai_generation";

/// Whether mail may go to the user's OpenAI key. Not when on-device AI was
/// chosen; a never-recorded choice keeps the old `auto` default (the key when
/// there is one), as the desktop does for someone who never picked a lane.
pub fn openai_allowed(store: &crate::sync::store::SyncStore) -> bool {
    store.get_engine_setting(AI_GENERATION_SETTING).ok().flatten().as_deref() != Some("on_device")
}

/// Push the user's AI model selection (from Settings) to the background triage
/// worker, so it summarizes with the same model the Bridge uses.
/// `generation` is `"openai"` or `"apple"` (anything non-`openai` = on-device).
#[tauri::command]
pub fn set_ai_config(
    sync: State<'_, SyncState>,
    generation: String,
    openai_key: Option<String>,
    model: Option<String>,
    on_device_model: Option<String>,
) -> Result<(), String> {
    let cfg = BridgeConfig {
        generation: if generation == "openai" { GenSource::OpenAi } else { GenSource::OnDevice },
        openai_key,
        model: model.unwrap_or_else(prompts::openai_chat_model),
        on_device_model,
        // Triage worker config — verbosity/weather are brief-only, so neither applies.
        concise: false,
        weather: None,
    };
    let choice = if cfg.generation == GenSource::OpenAi { "openai" } else { "on_device" };
    sync.engine.store().set_engine_setting(AI_GENERATION_SETTING, choice).map_err(|e| e.to_string())?;
    sync.engine.set_ai_config(cfg);
    sync.engine.ai_scan_notify().notify_one();
    Ok(())
}

/// Lore "Handled for you" auto mode (docs/Triage.md "Auto mode"): which buckets
/// file new mail away by themselves. `{fyi, receipt, notification}`, all false
/// until the person turns one on.
#[tauri::command]
pub fn get_lore_auto(sync: State<'_, SyncState>) -> inbox2_core::sync::store::LoreAutoSettings {
    sync.engine.store().lore_auto()
}

/// Replace the auto-mode buckets (missing keys = false). Returns what was stored.
#[tauri::command]
pub fn set_lore_auto(
    sync: State<'_, SyncState>,
    settings: inbox2_core::sync::store::LoreAutoSettings,
) -> Result<inbox2_core::sync::store::LoreAutoSettings, String> {
    sync.engine.store().set_lore_auto(settings).map_err(|e| e.to_string())
}

#[cfg(test)]
mod lane_choice_tests {
    use super::{openai_allowed, AI_GENERATION_SETTING};
    use crate::sync::store::SyncStore;

    #[test]
    fn on_device_choice_keeps_mail_off_openai() {
        let store = SyncStore::new_in_memory().unwrap();
        assert!(openai_allowed(&store)); // never chosen: the old `auto` default
        store.set_engine_setting(AI_GENERATION_SETTING, "on_device").unwrap();
        assert!(!openai_allowed(&store));
        store.set_engine_setting(AI_GENERATION_SETTING, "openai").unwrap();
        assert!(openai_allowed(&store));
    }
}

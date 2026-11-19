// Desktop Bridge commands — reuse the shared `inbox2_core::bridge` for brief
// assembly + OpenAI, routing on-device generation to the existing generative
// backend (Apple Foundation Models bridge / native LLM sidecar).

use std::sync::Arc;

use crate::ai::generative_commands::{GenerativeBackend, GenerativeState};
use crate::sync::commands::SyncState;
use inbox2_core::bridge::{agent, brief, openai::OpenAiClient, prompts};
use tauri::State;

/// Generate the spoken daily brief. Brief assembly + OpenAI are shared with mobile;
/// on-device generation routes to the desktop's generative backend; otherwise the
/// deterministic spoken fallback.
#[tauri::command]
pub async fn bridge_brief(
    sync: State<'_, SyncState>,
    generative: State<'_, Arc<GenerativeState>>,
    openai_key: Option<String>,
) -> Result<String, String> {
    let engine = sync.engine.clone();
    let brief = brief::assemble_now(engine.store()).map_err(|e| e.to_string())?;
    let facts = brief.facts_prompt();
    let system = prompts::brief_instructions();

    // OpenAI path (shared client).
    if let Some(key) = openai_key.filter(|k| !k.is_empty()) {
        return OpenAiClient::new(key)
            .generate(&system, &facts, &prompts::openai_chat_model())
            .await;
    }

    // On-device path via the desktop generative backend.
    let backend = *generative.backend.lock().await;
    let on_device: Option<String> = match backend {
        GenerativeBackend::AppleFoundationModels => {
            let guard = generative.apple_bridge.lock().await;
            guard
                .as_ref()
                .and_then(|b| b.generate(&system, &facts, 400).ok())
        }
        GenerativeBackend::NativeLLM => {
            let guard = generative.native_llm.lock().await;
            match guard.as_ref() {
                Some(p) => p.generate(&system, &facts, 0.5, 400).await.ok(),
                None => None,
            }
        }
        GenerativeBackend::None => None,
    };

    Ok(on_device.unwrap_or_else(|| brief.spoken_fallback()))
}

/// Validate an OpenAI key (shared).
#[tauri::command]
pub async fn bridge_validate_openai(key: String) -> Result<(), String> {
    agent::validate_openai(&key).await
}

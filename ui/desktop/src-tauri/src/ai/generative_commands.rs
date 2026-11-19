// Tauri commands for Tier B generative AI inference.
// Routes to Apple Foundation Models bridge or native LLM sidecar.

use std::sync::Arc;

use async_trait::async_trait;
use tauri::State;
use tokio::sync::Mutex;

use inbox2_core::bridge::models::Lane;

use crate::ai::apple_bridge::AppleFoundationModelsBridge;
use crate::ai::native_llm::NativeLLMProvider;

/// Sampling for the background triage worker's on-device generation — the
/// core's shared constants, so desktop and mobile free lanes match exactly.
const TRIAGE_MAX_TOKENS: u32 = inbox2_core::bridge::ON_DEVICE_MAX_OUTPUT_TOKENS;
const TRIAGE_TEMPERATURE: f32 = inbox2_core::bridge::ON_DEVICE_TEMPERATURE;

/// Shared generative AI state. Managed as an `Arc` so the same instance backs
/// both the Tauri commands and the core sync engine's background triage worker
/// (via [`GenerativeStateGenerator`]).
pub struct GenerativeState {
    pub apple_bridge: Mutex<Option<AppleFoundationModelsBridge>>,
    pub native_llm: Mutex<Option<NativeLLMProvider>>,
    pub backend: Mutex<GenerativeBackend>,
    pub app_data_dir: std::path::PathBuf,
}

#[derive(Clone, Copy, PartialEq)]
pub enum GenerativeBackend {
    None,
    AppleFoundationModels,
    NativeLLM,
}

/// Adapts the desktop [`GenerativeState`] (Apple FM / native LLM sidecar) to the
/// core's [`inbox2_core::bridge::LocalGenerator`] seam, so the background triage
/// worker generates through the very same on-device backend the desktop Bridge
/// uses. The OpenAI lane needs no adapter — the worker calls core's OpenAI client
/// directly when that lane is selected.
pub struct GenerativeStateGenerator(pub Arc<GenerativeState>);

/// The desktop's generative state, for the engine bus (sync/rpc.rs) — set only
/// when the desktop app runs; a headless `engine_daemon` has no Tier-B backend.
pub static HOSTED: std::sync::OnceLock<Arc<GenerativeState>> = std::sync::OnceLock::new();

#[async_trait]
impl inbox2_core::bridge::LocalGenerator for GenerativeStateGenerator {
    async fn is_available(&self) -> bool {
        *self.0.backend.lock().await != GenerativeBackend::None
    }

    // The per-call model hint isn't honored here: the desktop backend is whatever
    // `initialize_generative` warmed (Apple FM or the sidecar's loaded GGUF), and
    // swapping engines per call would mean spawning a second sidecar. The host
    // keeps `on_device_model` consistent with the warmed backend instead.
    async fn generate(&self, system: String, user: String, _model: Option<String>) -> Result<String, String> {
        let backend = *self.0.backend.lock().await;
        log::info!("[generative] on-device generate via {}", match backend {
            GenerativeBackend::AppleFoundationModels => "Apple Foundation Models",
            GenerativeBackend::NativeLLM => "local model sidecar",
            GenerativeBackend::None => "nothing",
        });
        match backend {
            GenerativeBackend::AppleFoundationModels => {
                let guard = self.0.apple_bridge.lock().await;
                let bridge = guard.as_ref().ok_or("Apple FM bridge not initialized")?;
                bridge.generate(&system, &user, TRIAGE_MAX_TOKENS)
            }
            GenerativeBackend::NativeLLM => {
                let guard = self.0.native_llm.lock().await;
                let provider = guard.as_ref().ok_or("Native LLM not initialized")?;
                provider
                    .generate(&system, &user, TRIAGE_TEMPERATURE, TRIAGE_MAX_TOKENS)
                    .await
            }
            GenerativeBackend::None => Err("no generative backend available".into()),
        }
    }
}

/// Initialize the generative backend.
///
/// `lane` mirrors the Settings lane picker: `"native"` = Apple Foundation
/// Models only, `"free"` = the local model sidecar only, absent = auto (Apple FM
/// first, sidecar fallback — the pre-lane behavior every old call site keeps).
/// `free_model` is the free lane's variant choice (a manifest GGUF id — Qwen by
/// default, or Gemma); absent keeps whatever runs, else the default. Already
/// running the requested backend (and variant) → no-op; switching shuts the
/// previous backend down first.
#[tauri::command]
pub async fn initialize_generative(
    state: State<'_, Arc<GenerativeState>>,
    lane: Option<String>,
    free_model: Option<String>,
) -> Result<(), String> {
    let prefer = match lane.as_deref() {
        None => None,
        Some(s) => Some(Lane::from_str(s).ok_or_else(|| format!("unknown generative lane: {s}"))?),
    };
    let mut backend_guard = state.backend.lock().await;

    // Already on the requested backend → done. (Auto accepts either; a sidecar
    // counts only when it serves the requested variant.)
    let satisfied = match (*backend_guard, prefer) {
        (GenerativeBackend::AppleFoundationModels, Some(Lane::Native) | None) => true,
        (GenerativeBackend::NativeLLM, Some(Lane::Free) | None) => match free_model.as_deref() {
            None => true,
            Some(id) => state
                .native_llm
                .lock()
                .await
                .as_ref()
                .is_some_and(|p| p.model_id() == id),
        },
        _ => false,
    };
    if satisfied {
        return Ok(());
    }

    // Switching lanes: stop whatever runs now so backends never stack.
    if let Some(bridge) = state.apple_bridge.lock().await.take() {
        bridge.shutdown();
    }
    if let Some(provider) = state.native_llm.lock().await.take() {
        provider.stop();
    }
    *backend_guard = GenerativeBackend::None;

    // Apple Foundation Models (macOS only) — for `native` and `auto`.
    #[cfg(target_os = "macos")]
    if prefer != Some(Lane::Free) {
        let binary_path =
            AppleFoundationModelsBridge::resolve_binary_path(&state.app_data_dir);
        let mut bridge = AppleFoundationModelsBridge::new(binary_path);

        match bridge.initialize() {
            Ok(true) => {
                *state.apple_bridge.lock().await = Some(bridge);
                *backend_guard = GenerativeBackend::AppleFoundationModels;
                return Ok(());
            }
            Ok(false) => {
                log::info!("Apple Foundation Models not available");
            }
            Err(e) => {
                log::warn!("Apple FM bridge error: {e}");
            }
        }
        if prefer == Some(Lane::Native) {
            return Err("Apple Intelligence isn't available on this Mac".to_string());
        }
        log::info!("falling back to the local model sidecar");
    }
    #[cfg(not(target_os = "macos"))]
    if prefer == Some(Lane::Native) {
        return Err("No native generative engine on this platform".to_string());
    }

    // The local model sidecar — for `free` and `auto`-fallback, serving the
    // requested variant (default: Qwen).
    let model_id = free_model
        .unwrap_or_else(|| crate::ai::native_llm::DEFAULT_MANIFEST_MODEL_ID.to_string());
    let mut provider = NativeLLMProvider::new(&state.app_data_dir, &model_id);

    if !provider.is_model_downloaded() {
        // Download the model
        provider.download_model().await.map_err(|e| {
            format!("Failed to download generative model: {e}")
        })?;
    }

    if provider.is_server_available() {
        // start_server spawns the llama-server sidecar and blocks polling its
        // /health endpoint for up to 30s — run it off the async runtime so it
        // doesn't stall a Tokio worker.
        let provider = tokio::task::spawn_blocking(move || {
            provider.start_server().map(|()| provider)
        })
        .await
        .map_err(|e| format!("server startup task failed: {e}"))??;
        *state.native_llm.lock().await = Some(provider);
        *backend_guard = GenerativeBackend::NativeLLM;
        Ok(())
    } else {
        Err("No inference server binary available. Please install llama-server.".to_string())
    }
}

/// Generate smart reply suggestions.
#[tauri::command]
pub async fn generative_smart_replies(
    state: State<'_, Arc<GenerativeState>>,
    text: String,
    sender_name: String,
) -> Result<Vec<String>, String> {
    smart_replies_on(&state, text, sender_name).await
}

pub async fn smart_replies_on(state: &GenerativeState, text: String, sender_name: String) -> Result<Vec<String>, String> {
    let backend = *state.backend.lock().await;

    match backend {
        GenerativeBackend::AppleFoundationModels => {
            let guard = state.apple_bridge.lock().await;
            let bridge = guard.as_ref().ok_or("Apple FM bridge not initialized")?;
            bridge.smart_replies(&text, &sender_name)
        }
        GenerativeBackend::NativeLLM => {
            let guard = state.native_llm.lock().await;
            let provider = guard.as_ref().ok_or("Native LLM not initialized")?;
            provider.smart_replies(&text, &sender_name).await
        }
        GenerativeBackend::None => {
            Err("No generative backend available".to_string())
        }
    }
}

/// Summarize text.
#[tauri::command]
pub async fn generative_summarize(
    state: State<'_, Arc<GenerativeState>>,
    text: String,
) -> Result<String, String> {
    summarize_on(&state, text).await
}

pub async fn summarize_on(state: &GenerativeState, text: String) -> Result<String, String> {
    let backend = *state.backend.lock().await;

    match backend {
        GenerativeBackend::AppleFoundationModels => {
            let guard = state.apple_bridge.lock().await;
            let bridge = guard.as_ref().ok_or("Apple FM bridge not initialized")?;
            bridge.summarize(&text)
        }
        GenerativeBackend::NativeLLM => {
            let guard = state.native_llm.lock().await;
            let provider = guard.as_ref().ok_or("Native LLM not initialized")?;
            provider.summarize(&text).await
        }
        GenerativeBackend::None => {
            Err("No generative backend available".to_string())
        }
    }
}

/// Free-form generation.
#[tauri::command]
pub async fn generative_generate(
    state: State<'_, Arc<GenerativeState>>,
    system: String,
    prompt: String,
    max_tokens: Option<u32>,
    temperature: Option<f32>,
) -> Result<String, String> {
    generate_on(&state, system, prompt, max_tokens, temperature).await
}

pub async fn generate_on(
    state: &GenerativeState,
    system: String,
    prompt: String,
    max_tokens: Option<u32>,
    temperature: Option<f32>,
) -> Result<String, String> {
    let backend = *state.backend.lock().await;
    let max_t = max_tokens.unwrap_or(300);
    let temp = temperature.unwrap_or(0.5);

    match backend {
        GenerativeBackend::AppleFoundationModels => {
            let guard = state.apple_bridge.lock().await;
            let bridge = guard.as_ref().ok_or("Apple FM bridge not initialized")?;
            bridge.generate(&system, &prompt, max_t)
        }
        GenerativeBackend::NativeLLM => {
            let guard = state.native_llm.lock().await;
            let provider = guard.as_ref().ok_or("Native LLM not initialized")?;
            provider.generate(&system, &prompt, temp, max_t).await
        }
        GenerativeBackend::None => {
            Err("No generative backend available".to_string())
        }
    }
}

/// Stop the generative backend and free resources.
#[tauri::command]
pub async fn stop_generative(state: State<'_, Arc<GenerativeState>>) -> Result<(), String> {
    let mut backend_guard = state.backend.lock().await;

    if let Some(bridge) = state.apple_bridge.lock().await.take() {
        bridge.shutdown();
    }
    if let Some(provider) = state.native_llm.lock().await.take() {
        provider.stop();
    }

    *backend_guard = GenerativeBackend::None;
    Ok(())
}

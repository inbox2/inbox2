use std::sync::Arc;

use serde::Deserialize;
use tauri::{AppHandle, State};
use tokio::sync::Mutex;

use crate::ai::download::{
    self, DiskUsage, DownloadResult, ModelDownloadRequest,
};
use crate::ai::inference::{AIInferenceEngine, EmbeddingResult, IntentResult, SentimentResult};

/// Shared AI state managed by Tauri.
pub struct AIState {
    pub engine: Arc<Mutex<AIInferenceEngine>>,
    pub app_data_dir: std::path::PathBuf,
}

// ─── Capability Detection ────────────────────────────────────────────────────

/// Whether Apple Foundation Models can run here (macOS 26+, Apple Silicon).
/// Shared by the capability-detection command and the lane manager's device
/// profile. Foundation Models framework availability is approximated by
/// platform checks; the Swift bridge's own `check` is the definitive probe.
pub fn apple_fm_supported() -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::process::Command;

        if std::env::consts::ARCH != "aarch64" {
            return false;
        }
        // Check macOS version via sw_vers — macOS 26 = Tahoe (Foundation Models
        // introduced).
        match Command::new("sw_vers").arg("-productVersion").output() {
            Ok(out) => {
                let version = String::from_utf8_lossy(&out.stdout);
                let major: u32 = version
                    .trim()
                    .split('.')
                    .next()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                major >= 26
            }
            Err(_) => false,
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Check if Apple Foundation Models are available (macOS 26+, Apple Silicon).
#[tauri::command]
pub async fn check_apple_foundation_models() -> bool {
    apple_fm_supported()
}

// ─── Model Management ────────────────────────────────────────────────────────

/// Download AI models to the app data directory.
#[tauri::command]
pub async fn download_ai_models(
    app_handle: AppHandle,
    state: State<'_, AIState>,
    models: Vec<ModelDownloadRequest>,
) -> Result<DownloadResult, String> {
    let result = download::download_models(&app_handle, &state.app_data_dir, models).await;
    Ok(result)
}

/// Remove all downloaded AI models.
#[tauri::command]
pub async fn remove_ai_models(state: State<'_, AIState>) -> Result<(), String> {
    download::remove_models(&state.app_data_dir)
}

/// Get disk usage for AI models.
#[tauri::command]
pub async fn get_ai_model_disk_usage(state: State<'_, AIState>) -> Result<DiskUsage, String> {
    Ok(download::get_disk_usage(&state.app_data_dir))
}

// ─── Inference ───────────────────────────────────────────────────────────────

/// Run a CPU-bound inference call on a blocking thread so the synchronous ONNX
/// `Session::run` never stalls a Tokio worker (and never holds the engine lock
/// across the async runtime). `blocking_lock` is valid here because the closure
/// runs on a `spawn_blocking` thread, not in async context.
async fn run_on_engine<T, F>(engine: Arc<Mutex<AIInferenceEngine>>, f: F) -> Result<T, String>
where
    F: FnOnce(&mut AIInferenceEngine) -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(move || f(&mut engine.blocking_lock()))
        .await
        .map_err(|e| format!("inference task failed: {e}"))?
}

/// Warm up AI models (pre-load ONNX sessions).
#[tauri::command]
pub async fn warmup_ai_models(state: State<'_, AIState>) -> Result<(), String> {
    run_on_engine(state.engine.clone(), |e| e.warmup()).await
}

/// Run sentiment analysis.
#[derive(Debug, Deserialize)]
pub struct InferenceRequest {
    pub text: String,
}

#[tauri::command]
pub async fn ai_sentiment(
    state: State<'_, AIState>,
    text: String,
) -> Result<SentimentResult, String> {
    run_on_engine(state.engine.clone(), move |e| e.run_sentiment(&text)).await
}

/// Run intent classification.
#[tauri::command]
pub async fn ai_intent(
    state: State<'_, AIState>,
    text: String,
) -> Result<IntentResult, String> {
    run_on_engine(state.engine.clone(), move |e| e.run_intent(&text)).await
}

/// Run text embedding.
#[tauri::command]
pub async fn ai_embedding(
    state: State<'_, AIState>,
    text: String,
) -> Result<EmbeddingResult, String> {
    run_on_engine(state.engine.clone(), move |e| e.run_embedding(&text)).await
}

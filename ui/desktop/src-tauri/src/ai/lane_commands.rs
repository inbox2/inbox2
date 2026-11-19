//! Tauri commands exposing the core three-lane model manager on desktop —
//! the same `model_lanes` / `model_download` / `model_delete` surface the
//! mobile apps consume over FFI, so the Settings lane picker renders identical
//! information everywhere. Download progress flows as `model-download` Tauri
//! events (the payload shape core's `DownloadManager` emits).

use std::sync::Arc;

use inbox2_core::bridge::models::{Capability, DeviceProfile, ModelManager};
use inbox2_core::sync::events::EventSink;
use tauri::{Emitter, Manager, State};

/// The core model manager, managed as Tauri state.
pub struct LaneState {
    pub models: Arc<ModelManager>,
}

/// Forwards core model-manager events (`model-download` progress) to the webview.
struct TauriSink {
    handle: tauri::AppHandle,
}

impl EventSink for TauriSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        let _ = self.handle.emit(event, payload);
    }
}

/// Build the model manager over the app data dir and register it as state.
/// The device profile drives native-lane availability: Apple Intelligence on
/// a capable Mac, nothing native elsewhere.
pub fn init(app: &tauri::App, app_data_dir: &std::path::Path) {
    let sink: Arc<dyn EventSink> = Arc::new(TauriSink { handle: app.handle().clone() });
    let models = Arc::new(ModelManager::new(app_data_dir, sink));
    let os = if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    };
    models.set_device_profile(DeviceProfile {
        os: os.into(),
        os_major: 0,
        os_minor: 0,
        apple_intelligence: crate::ai::commands::apple_fm_supported(),
        android_native_speech: false,
    });
    app.manage(LaneState { models });
}

/// The three lanes (native / free / openai) for a capability (`nlu` | `tts` |
/// `stt`), with availability + install state — drives the Settings lane picker.
#[tauri::command]
pub fn model_lanes(
    state: State<'_, LaneState>,
    capability: String,
    has_valid_key: bool,
) -> Result<Vec<serde_json::Value>, String> {
    let cap = Capability::from_str(&capability)
        .ok_or_else(|| format!("unknown capability: {capability}"))?;
    Ok(state
        .models
        .lanes(cap, has_valid_key)
        .into_iter()
        .map(|l| {
            serde_json::json!({
                "lane": l.lane.as_str(),
                "id": l.id,
                "available": l.available,
                "reason": l.reason,
                "state": l.state,
                "totalBytes": l.total_bytes,
                "license": l.license,
            })
        })
        .collect())
}

/// The free lane's variants for a capability, in manifest (default-first) order
/// with install state — drives the variant picker (NLU: Qwen vs Gemma).
#[tauri::command]
pub fn free_model_variants(
    state: State<'_, LaneState>,
    capability: String,
) -> Result<Vec<serde_json::Value>, String> {
    let cap = Capability::from_str(&capability)
        .ok_or_else(|| format!("unknown capability: {capability}"))?;
    Ok(state
        .models
        .free_variants(cap)
        .into_iter()
        .map(|v| {
            serde_json::json!({
                "id": v.id,
                "state": v.state,
                "totalBytes": v.total_bytes,
                "license": v.license,
            })
        })
        .collect())
}

/// Start (or resume) downloading a free model. Returns immediately; progress
/// arrives as `model-download` events.
#[tauri::command]
pub fn model_download(state: State<'_, LaneState>, id: String) -> Result<(), String> {
    let entry = state.models.entry_for_download(&id)?;
    let models = state.models.clone();
    tauri::async_runtime::spawn(async move {
        models.downloads().run(entry).await;
    });
    Ok(())
}

/// Delete a downloaded free model, reclaiming its disk.
#[tauri::command]
pub fn model_delete(state: State<'_, LaneState>, id: String) -> Result<(), String> {
    state.models.delete(&id)
}

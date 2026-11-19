//! The Tauri-specific [`EventSink`]. Lives in the desktop crate (not core) so
//! `inbox2-core` stays free of any Tauri dependency.

use inbox2_core::sync::events::EventSink;

/// Forwards engine events to the desktop webview via `AppHandle::emit`.
pub struct TauriSink(pub tauri::AppHandle);

impl EventSink for TauriSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        use tauri::Emitter;
        if let Err(e) = self.0.emit(event, payload) {
            log::warn!("Failed to emit {event} to webview: {e}");
        }
    }
}

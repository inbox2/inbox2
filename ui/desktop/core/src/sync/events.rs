//! Event sink abstraction for the sync engine.
//!
//! The engine emits events (`sync` — the lifecycle backbone, `new-message`,
//! `calendar-changed`, `status`) through a single chokepoint. It goes through an
//! [`EventSink`] so the same engine can drive any host:
//!   - the desktop webview (the desktop crate's `TauriSink`),
//!   - external clients over the IPC socket (the desktop crate's `BroadcastSink`),
//!   - both at once ([`CompositeSink`], used when the desktop app is the bus host),
//!   - a native mobile callback (Swift/Kotlin), or
//!   - nothing ([`NullSink`], used by `sync_check` and unit tests).
//!
//! Host-specific sinks (e.g. `TauriSink`) live in the host crate, not here, so
//! core stays free of any UI/runtime dependency.

use std::sync::Arc;

/// Anything that can receive a serialized engine event.
pub trait EventSink: Send + Sync {
    /// Best-effort delivery of `event` with a JSON `payload`. Never panics.
    fn emit(&self, event: &str, payload: serde_json::Value);
}

/// Drops every event. Used headless (`sync_check`, tests).
pub struct NullSink;

impl EventSink for NullSink {
    fn emit(&self, _event: &str, _payload: serde_json::Value) {}
}

/// Fans an event out to several sinks (e.g. webview + socket clients).
pub struct CompositeSink(pub Vec<Arc<dyn EventSink>>);

impl EventSink for CompositeSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        for sink in &self.0 {
            sink.emit(event, payload.clone());
        }
    }
}

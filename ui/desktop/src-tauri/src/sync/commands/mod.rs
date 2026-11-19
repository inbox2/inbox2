//! Tauri command surface for the sync engine, split by concern:
//!
//! - [`accounts`] — external-account CRUD + credential retrieval
//! - [`sync_control`] — start/stop/resync, push registration, status, diagnostics,
//!   write-back enqueue, folder listing
//! - [`secrets`] — Rails API context + the encrypted app-secret KV store
//! - [`oauth`] — localhost OAuth callback listeners (Gmail / Microsoft)
//! - [`interactive`] — on-demand fetch / attachments / source / send / actions
//! - [`data`] — the "clear all local data" danger action
//!
//! Everything is re-exported flat so the historical `sync::commands::<name>`
//! paths (used by `lib.rs`'s invoke_handler, `sync::rpc`, and `ai`) are unchanged.

use std::sync::Arc;


use crate::sync::engine::SyncEngine;

mod accounts;
mod data;
mod device_link;
mod interactive;
mod mx;
mod oauth;
mod ontology;
mod secrets;
mod sync_control;
mod triage;
mod vault;

pub use accounts::*;
pub use data::*;
pub use device_link::*;
pub use interactive::*;
pub use mx::*;
pub use oauth::*;
pub use ontology::*;
pub use secrets::*;
pub use sync_control::*;
pub use triage::*;
pub use vault::*;

/// Shared engine state managed by Tauri.
///
/// The engine is an `Arc` (not a `Mutex`) because its long-running `run()` loop
/// is spawned at startup and holds an `Arc` clone; all engine methods take
/// `&self` and synchronize internally, so commands share the same `Arc`.
pub struct SyncState {
    pub engine: Arc<SyncEngine>,
    /// Set when this process is a *client* of the engine bus (another process —
    /// the CLI daemon — hosts the engine). Sync-control commands route here so we
    /// never run a second syncing engine. `None` when we host the engine locally.
    pub bus: Option<Arc<crate::sync::ipc::BusClient>>,
}

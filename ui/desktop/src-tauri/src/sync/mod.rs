//! Desktop `sync` module.
//!
//! The provider-agnostic engine now lives in the `inbox2-core` crate. We re-export
//! its modules here so existing desktop code keeps referring to them as
//! `crate::sync::engine`, `crate::sync::store`, etc. The desktop-only glue —
//! the Tauri command wrappers, the IPC bus (host/client election + RPC), and the
//! Tauri event sink — stays in this crate.

pub use inbox2_core::sync::{
    actions, adapters, calendar, crypto, deletion, engine, error, events, ics, interactive,
    mime, model, mx_sync, oauth, outbox, provider, push, seal, store, threading,
};

pub mod commands;
pub mod ipc;
pub mod rpc;
pub mod tauri_sink;

pub use tauri_sink::TauriSink;

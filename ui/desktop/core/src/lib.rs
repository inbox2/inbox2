//! `inbox2-core` — the provider-agnostic sync engine.
//!
//! This crate holds everything that is independent of the host shell (Tauri
//! desktop today; native iOS/Android later): the [`sync`] engine, store,
//! provider adapters, OAuth, calendar, and cloud-push lifecycle. The host
//! supplies an [`sync::events::EventSink`] (desktop: a Tauri emitter; mobile: a
//! Swift/Kotlin callback) and a data directory; the engine drives every provider
//! through one trait and never touches the UI layer.

pub mod ai_worker;
pub mod bridge;
pub mod ontology;
pub mod mcp_client;
pub mod next_action;
pub mod otp;
pub mod quotes;
pub mod rules;
pub mod sync;
pub mod triage;
pub mod triage_eval;
pub mod typesafe;

// Cross-language parity tests against fixtures/parity/fixtures.json (Ruby half in
// api/spec/services/cross_language_parity_spec.rb). See fixtures/parity/README.md.
#[cfg(test)]
mod parity_tests;

// The UniFFI surface for the native iOS/Android apps (off for the desktop build).
#[cfg(feature = "mobile-ffi")]
uniffi::setup_scaffolding!();
#[cfg(feature = "mobile-ffi")]
pub mod ffi;

/// Canonical SQLite schema. Single source of truth, shared by the engine's
/// [`sync::store::SyncStore`] (which executes it on open) and the desktop's
/// `tauri-plugin-sql` migration (which applies the identical text so the JS read
/// path and the Rust write path agree).
pub const SCHEMA_SQL: &str = include_str!("../migrations/001_create_schema.sql");

/// Bundle identifier used to locate the per-user data directory and the OS
/// keystore entry for the credential master key. Overridable at compile time via
/// `INBOX2_BUNDLE_ID` so a side-by-side "dev" build (`com.inbox2.desktop.dev`)
/// gets a fully separate data dir + keychain key and can run alongside the prod
/// app. Must stay in lock-step with the Tauri config's `identifier` (the GUI's
/// runtime `app_data_dir()` comes from there). `core/build.rs` forces a rebuild
/// when the env var changes. Default is the canonical prod identifier.
pub const BUNDLE_ID: &str = match option_env!("INBOX2_BUNDLE_ID") {
    Some(id) => id,
    None => "com.inbox2.desktop",
};

/// The app's per-user data directory, matching Tauri's `app_data_dir()` on each
/// platform. Used by the headless binaries (engine_daemon, sync_check) which have
/// no `AppHandle` to ask. macOS: `~/Library/Application Support/<id>`; Windows:
/// `%APPDATA%\<id>`; Linux: `$XDG_DATA_HOME` (or `~/.local/share`) `/<id>`.
pub fn default_data_dir() -> std::path::PathBuf {
    use std::path::PathBuf;

    #[cfg(target_os = "macos")]
    let base = PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join("Library/Application Support");
    #[cfg(target_os = "windows")]
    let base = PathBuf::from(std::env::var("APPDATA").unwrap_or_default());
    #[cfg(all(unix, not(target_os = "macos")))]
    let base = PathBuf::from(
        std::env::var("XDG_DATA_HOME")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                let home = std::env::var("HOME").unwrap_or_default();
                format!("{home}/.local/share")
            }),
    );

    base.join(BUNDLE_ID)
}

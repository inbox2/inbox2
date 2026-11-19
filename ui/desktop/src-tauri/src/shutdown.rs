//! Graceful teardown of long-lived pipelines on app exit.

use crate::ai::generative_commands::GenerativeState;
use crate::sync::commands::SyncState;

/// Run pipeline shutdown exactly once, even if Exit follows ExitRequested.
pub static SHUTDOWN_ONCE: std::sync::Once = std::sync::Once::new();

/// Tear down every long-lived pipeline cleanly on app exit and log each step.
///
/// Without this the sync engine's run loop and the AI sidecar child processes
/// outlive the window: a stale engine keeps holding `engine.sock`, so the next
/// launch attaches to a dead host (split-brain — accounts/sync look broken),
/// and orphaned `FoundationModelsBridge`/LLM processes linger. `Exit`
/// force-terminates the process, so their `Drop` impls never run — we must do
/// it explicitly here.
pub fn graceful_shutdown(app: &tauri::AppHandle) {
    use tauri::Manager;
    log::info!("Lifecycle: graceful shutdown starting");

    // 1. Sync engine — stop the run loop and disconnect every adapter.
    if let Some(sync) = app.try_state::<SyncState>() {
        tauri::async_runtime::block_on(sync.engine.shutdown());
        // The host (no bus client) owns the engine socket; release it so the
        // next launch elects a fresh host instead of attaching to a dead one.
        if sync.bus.is_none() {
            if let Ok(dir) = app.path().app_data_dir() {
                let sock = crate::sync::ipc::socket_path(&dir);
                match std::fs::remove_file(&sock) {
                    Ok(()) => log::info!("Shutdown: released engine bus socket"),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => log::warn!("Shutdown: failed to remove engine socket: {e}"),
                }
            }
        } else {
            log::info!("Shutdown: bus client detached (another process hosts the engine)");
        }
    }

    // 2. AI sidecars — kill the Swift / native-LLM child processes.
    if let Some(gen) = app.try_state::<std::sync::Arc<GenerativeState>>() {
        tauri::async_runtime::block_on(async {
            if let Some(bridge) = gen.apple_bridge.lock().await.as_ref() {
                bridge.shutdown();
                log::info!("Shutdown: Apple Foundation Models bridge stopped");
            }
            if let Some(llm) = gen.native_llm.lock().await.as_ref() {
                llm.stop();
                log::info!("Shutdown: native LLM provider stopped");
            }
        });
    }

    log::info!("Lifecycle: graceful shutdown complete");
}

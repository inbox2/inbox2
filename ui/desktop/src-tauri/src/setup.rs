//! `tauri::Builder::setup` helpers. The setup closure in `run()` wires up a lot
//! of independent concerns — menu, window chrome, the sync store + engine bus,
//! the MCP server, and the AI/vector/agent subsystems. Each is a named function
//! here so the closure reads as a sequence of steps.

use std::path::Path;
use std::sync::Arc;

use tauri::{Emitter, Listener, Manager};
use tokio::sync::Mutex;

use crate::ai::commands::AIState;
use crate::ai::generative_commands::{GenerativeBackend, GenerativeState};
use crate::ai::inference::AIInferenceEngine;
use crate::sync;
use crate::sync::engine::SyncEngine;
use crate::sync::store::SyncStore;
use crate::vector::commands::VectorState;
use crate::vector::pipeline::EmbeddingPipeline;
use crate::vector::store::VectorStore;

/// Custom app menu. The default macOS menu binds ⌘W to "Close Window" and ⌘Q to
/// "Quit" as native accelerators that JS can't intercept. Rebind them: ⌘W →
/// "Close Tab" (frontend closes the active in-app browser tab, else ignores) and
/// ⌘Q → "Quit" routed through a confirm dialog. Cut/Copy/Paste/Select-All are
/// preserved. Undo/Redo are deliberately NOT added: the native predefined items
/// steal ⌘Z / ⌘⇧Z before the event reaches the webview, which broke the app's own
/// undo (un-archive etc.). Without them, ⌘Z falls through to JS (undoStore's
/// global handler) for app-level undo, while focused text fields still get the
/// webview's built-in text undo (our handler bails when an input is focused).
///
/// macOS only: on Windows and Linux `set_menu` draws a menu bar inside the window,
/// a second strip above the chrome bar. The chrome bar carries the window
/// controls there, and closing the window reaches the same quit confirm.
#[cfg(not(target_os = "macos"))]
pub fn build_app_menu(_app: &tauri::App) -> tauri::Result<()> {
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn build_app_menu(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{AboutMetadata, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
    let handle = app.handle();
    let close_tab = MenuItemBuilder::new("Close Tab")
        .id("close_tab")
        .accelerator("CmdOrCtrl+W")
        .build(handle)?;
    let quit = MenuItemBuilder::new("Quit Inbox2")
        .id("quit")
        .accelerator("CmdOrCtrl+Q")
        .build(handle)?;
    let app_menu = SubmenuBuilder::new(handle, "Inbox2")
        .about(Some(AboutMetadata::default()))
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .item(&quit)
        .build()?;
    let edit_menu = SubmenuBuilder::new(handle, "Edit")
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;
    let window_menu = SubmenuBuilder::new(handle, "Window")
        .minimize()
        .item(&close_tab)
        .build()?;
    let menu = MenuBuilder::new(handle)
        .items(&[&app_menu, &edit_menu, &window_menu])
        .build()?;
    handle.set_menu(menu)?;
    Ok(())
}

/// Log panics to the log file. Without this, a panic in a spawned task or the
/// main loop dies on stderr — invisible when the app is launched from Finder —
/// so the app "just shuts down" with no trace. Chain the previous hook so
/// default behaviour (abort/backtrace on stderr) is preserved.
pub fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown location".into());
        let msg = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<non-string panic payload>".into());
        let thread = std::thread::current()
            .name()
            .unwrap_or("unnamed")
            .to_string();
        let backtrace = std::backtrace::Backtrace::force_capture();
        log::error!("PANIC in thread '{thread}' at {location}: {msg}\n{backtrace}");
        default_hook(info);
    }));
}

/// Apply the native window material (macOS vibrancy / Windows acrylic) and
/// contain the restored window to the current screen.
pub fn apply_window_chrome(app: &tauri::App) {
    // Windows/Linux: `titleBarStyle: Overlay` is macOS-only, so the native title
    // bar would sit above the chrome bar. Drop the decorations; the chrome bar
    // draws minimize / maximize / close itself (web/components/Chrome/WindowControls)
    // and resizing stays on the frame edges (tao's borderless resize).
    #[cfg(not(target_os = "macos"))]
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_decorations(false);
    }

    // macOS: force dark chrome + re-apply vibrancy (window-state plugin can
    // reset effects when it restores saved geometry)
    #[cfg(target_os = "macos")]
    {
        use tauri::window::{Effect, EffectState, EffectsBuilder};

        if let Some(win) = app.get_webview_window("main") {
            let _ = win.set_theme(Some(tauri::Theme::Dark));
            let _ = win.set_effects(
                EffectsBuilder::new()
                    .effect(Effect::HudWindow)
                    .state(EffectState::Active)
                    .build(),
            );
        }

        // Side-by-side dev identity: set the Dock icon at runtime. A `tauri dev`
        // run is a bare binary (not an `.app` bundle), so macOS ignores
        // `bundle.icon` and shows a generic Dock icon. This stamps the embedded
        // golden "DEV" icon so the dev window is unmistakable next to the prod
        // app. No-op for the prod identity (its installed `.app` carries `.icns`).
        if crate::BUNDLE_ID.ends_with(".dev") {
            apply_dev_dock_icon();
        }
    }

    // Windows: apply a native window material so the chrome shows real desktop
    // translucency, mirroring macOS vibrancy. Acrylic blurs the desktop behind
    // the window (the closest match to classic Aero glass and to the macOS
    // HudWindow look); supported on Win10 1803+ and Win11. The dark tint keeps it
    // consistent with the forced-dark chrome — the alpha controls how much desktop
    // blur shows vs. tint. The CSS side makes .app transparent and drops
    // backdrop-filter on Windows (see styles/layout.module.css) so this material
    // shows through.
    // NOTE: window-vibrancy's acrylic (ACCENT_ENABLE_ACRYLICBLURBEHIND) dims to a
    // flat tint when the window is inactive and can stutter while dragging — a
    // known OS limitation. Switch the effect to Effect::Mica (Win11, more stable,
    // subtler) if that matters more than the live blur.
    #[cfg(target_os = "windows")]
    {
        use tauri::window::{Color, Effect, EffectState, EffectsBuilder};

        if let Some(win) = app.get_webview_window("main") {
            let _ = win.set_theme(Some(tauri::Theme::Dark));
            let _ = win.set_effects(
                EffectsBuilder::new()
                    .effect(Effect::Acrylic)
                    .state(EffectState::Active)
                    .color(Color(16, 20, 28, 140))
                    .build(),
            );
        }
    }

    // Containing the restored window to the screen happens in
    // spawn_display_watcher, NOT here: the window-state plugin restores saved
    // geometry via queued window messages that are still in flight while setup
    // runs, so a synchronous clamp here measures the pre-restore config-default
    // size and wrongly concludes the window fits.
}

/// macOS: replace the running app's Dock icon with the embedded golden "DEV"
/// icon. Used only for the dev identity (see `apply_window_chrome`) — a `tauri
/// dev` run has no `.app` bundle, so this is the only way to give it the badged
/// icon. Runs on the main thread (called from `setup`), as AppKit requires.
#[cfg(target_os = "macos")]
fn apply_dev_dock_icon() {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    // Golden DEV icon (badged prod art), embedded at compile time.
    const ICON_PNG: &[u8] = include_bytes!("../icons-dev/icon.png");

    unsafe {
        let data: *mut Object = msg_send![class!(NSData),
            dataWithBytes: ICON_PNG.as_ptr() as *const std::ffi::c_void
            length: ICON_PNG.len()];
        if data.is_null() {
            return;
        }
        let image: *mut Object = msg_send![class!(NSImage), alloc];
        let image: *mut Object = msg_send![image, initWithData: data];
        if image.is_null() {
            return;
        }
        let ns_app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![ns_app, setApplicationIconImage: image];
    }
}

// Main-window minimum size from tauri.conf.json (logical px). The OS refuses to
// resize below it, so the clamp must move the window left/up instead of
// shrinking when there isn't enough room.
const MIN_WIDTH: f64 = 900.0;
const MIN_HEIGHT: f64 = 600.0;

/// Clamp the window onto the visible desktop: the top-left corner always lands
/// on a display's work area, and an edge that overflows the display is shrunk
/// back so it sits exactly on the display's edge (right side hits the right
/// edge of the screen). A window that already fits is left untouched.
pub fn contain_window_to_screen(win: &tauri::WebviewWindow) {
    let monitors = match win.available_monitors() {
        Ok(m) if !m.is_empty() => m,
        _ => return,
    };
    let (Ok(pos), Ok(size)) = (win.outer_position(), win.outer_size()) else {
        return;
    };

    log::info!(
        "[contain] window pos=({},{}) size={}x{} scale={:?}; monitors: {}",
        pos.x,
        pos.y,
        size.width,
        size.height,
        win.scale_factor(),
        monitors
            .iter()
            .map(|m| {
                let wa = m.work_area();
                format!(
                    "[{} pos=({},{}) size={}x{} wa=({},{}) {}x{} scale={}]",
                    m.name().map(|s| s.as_str()).unwrap_or("?"),
                    m.position().x,
                    m.position().y,
                    m.size().width,
                    m.size().height,
                    wa.position.x,
                    wa.position.y,
                    wa.size.width,
                    wa.size.height,
                    m.scale_factor()
                )
            })
            .collect::<Vec<_>>()
            .join(" ")
    );

    let overlap = |m: &tauri::Monitor| -> i64 {
        let wa = m.work_area();
        let ox = (pos.x + size.width as i32).min(wa.position.x + wa.size.width as i32)
            - pos.x.max(wa.position.x);
        let oy = (pos.y + size.height as i32).min(wa.position.y + wa.size.height as i32)
            - pos.y.max(wa.position.y);
        ox.max(0) as i64 * oy.max(0) as i64
    };

    // The monitor whose work area holds the top-left corner; else the one the
    // window overlaps most; else primary (window is off every display).
    let target = monitors
        .iter()
        .find(|m| {
            let wa = m.work_area();
            pos.x >= wa.position.x
                && pos.x < wa.position.x + wa.size.width as i32
                && pos.y >= wa.position.y
                && pos.y < wa.position.y + wa.size.height as i32
        })
        .cloned()
        .or_else(|| monitors.iter().filter(|m| overlap(m) > 0).max_by_key(|m| overlap(m)).cloned())
        .or_else(|| win.primary_monitor().ok().flatten())
        .or_else(|| monitors.first().cloned());
    let Some(target) = target else { return };

    let wa = target.work_area();
    let scale = target.scale_factor();
    let min_w = (MIN_WIDTH * scale).round() as i32;
    let min_h = (MIN_HEIGHT * scale).round() as i32;
    let wa_right = wa.position.x + wa.size.width as i32;
    let wa_bottom = wa.position.y + wa.size.height as i32;

    // Top-left onto the visible surface, leaving room for at least the minimum
    // window size to its right/below.
    let x = pos.x.clamp(wa.position.x, (wa_right - min_w).max(wa.position.x));
    let y = pos.y.clamp(wa.position.y, (wa_bottom - min_h).max(wa.position.y));

    // Overflowing edges shrink back onto the screen edge.
    let mut w = size.width as i32;
    let mut h = size.height as i32;
    if x + w > wa_right {
        w = (wa_right - x).max(min_w);
    }
    if y + h > wa_bottom {
        h = (wa_bottom - y).max(min_h);
    }

    if (x, y) != (pos.x, pos.y) || (w, h) != (size.width as i32, size.height as i32) {
        log::info!(
            "Containing window to display: pos ({},{})→({x},{y}), size {}x{}→{w}x{h}",
            pos.x, pos.y, size.width, size.height
        );
        let _ = win.set_position(tauri::PhysicalPosition { x, y });
        let _ = win.set_size(tauri::PhysicalSize {
            width: w as u32,
            height: h as u32,
        });
    }
}

/// After a display resolution/scale change macOS resizes the NSWindow, but the
/// WKWebView inside can keep its old frame. The page then renders in a block in
/// the top-left of a larger window, with the window's background showing around it
/// (seen 2026-11-06 after a monitor went to a lower resolution and back). A real
/// resize makes the webview lay out again, so shrink by one pixel and restore
/// (growing can be clamped when the window already fills the display).
fn nudge_webview_layout(win: &tauri::WebviewWindow) {
    let Ok(s) = win.inner_size() else { return };
    let _ = win.set_size(tauri::PhysicalSize { width: s.width, height: s.height - 1 });
    std::thread::sleep(std::time::Duration::from_millis(50));
    let _ = win.set_size(s);
}

/// Re-contain the main window whenever the display configuration changes —
/// external monitor unplugged, lid closed/opened. The OS moves windows around
/// on its own in those moments and can leave ours wider than the remaining
/// display or with its top-left off-screen. Tauri exposes no display-changed
/// event, so poll the monitor layout and clamp when it changes.
pub fn spawn_display_watcher(app: &tauri::App) {
    let Some(win) = app.get_webview_window("main") else {
        return;
    };
    std::thread::Builder::new()
        .name("display-watcher".into())
        .spawn(move || {
            let signature = |w: &tauri::WebviewWindow| -> Option<String> {
                let monitors = w.available_monitors().ok()?;
                Some(
                    monitors
                        .iter()
                        .map(|m| {
                            let p = m.position();
                            let s = m.size();
                            format!("{},{},{}x{}@{};", p.x, p.y, s.width, s.height, m.scale_factor())
                        })
                        .collect(),
                )
            };
            // Startup pass: wait out the window-state plugin's geometry restore
            // (it lands via queued window messages shortly after setup), then
            // contain the restored frame. The plugin restores the saved size
            // verbatim and only guards position against being fully off-screen,
            // so relaunching on a smaller display than the geometry was saved on
            // leaves an oversized, possibly mispositioned window.
            std::thread::sleep(std::time::Duration::from_millis(1500));
            contain_window_to_screen(&win);

            let mut last = signature(&win);
            loop {
                std::thread::sleep(std::time::Duration::from_secs(2));
                let Some(current) = signature(&win) else {
                    continue;
                };
                if last.as_deref() == Some(current.as_str()) {
                    continue;
                }
                let had_baseline = last.is_some();
                last = Some(current);
                if !had_baseline {
                    continue;
                }
                log::info!("Display configuration changed; re-containing main window");
                // Give the OS a moment to finish shuffling windows between
                // displays before measuring.
                std::thread::sleep(std::time::Duration::from_millis(1200));
                contain_window_to_screen(&win);
                nudge_webview_layout(&win);
                // The settle delay may itself span another change; re-baseline
                // so the next tick doesn't re-trigger on it.
                if let Some(s) = signature(&win) {
                    last = Some(s);
                }
            }
        })
        .expect("failed to spawn display-watcher thread");
}

/// Open the sync store, retrying briefly to ride out transient SQLITE_BUSY at
/// startup (busy_timeout covers most of it). We NEVER fall back to a throwaway
/// DB — that silently diverges data into a file the rest of the app can't see
/// (the split-brain that looks like "No accounts connected"). A genuine failure
/// (corrupt DB, disk full, permissions) is fatal: show a blocking error with a
/// Restart button and exit, rather than launching into a broken state.
///
/// The `SyncStore` opens its own rusqlite connection (WAL mode) to the same DB
/// that tauri-plugin-sql manages.
pub fn open_sync_store(app: &tauri::App, db_path: &Path, app_data_dir: &Path) -> Arc<SyncStore> {
    use crate::sync::error::SyncError;
    // Riding out a locked keychain (macOS dark wake) can take a while — the key
    // only becomes readable once the machine is fully awake. Back off up to this
    // many times (capped delay) before giving up; the budget is generous because a
    // short Power Nap wake returns to full wake quickly, and a genuinely overnight
    // dark wake means no user is watching anyway.
    const KEYCHAIN_MAX_RETRIES: u32 = 15;
    let mut attempt = 0;
    let mut keychain_attempt: u32 = 0;
    loop {
        match SyncStore::new(db_path, app_data_dir) {
            Ok(s) => {
                log::info!("Sync store opened at {}", db_path.display());
                break Arc::new(s);
            }
            // Dark wake / locked keychain: the DB is fine, the OS just won't hand
            // us the master key right now. A modal is useless here ("no UI
            // possible"), so quietly back off and retry until the machine wakes.
            Err(SyncError::KeychainLocked(e)) => {
                if keychain_attempt < KEYCHAIN_MAX_RETRIES {
                    keychain_attempt += 1;
                    let delay = std::cmp::min(2u64.saturating_mul(keychain_attempt as u64), 10);
                    log::warn!(
                        "Keychain locked (dark wake?), retry {keychain_attempt}/{KEYCHAIN_MAX_RETRIES} in {delay}s: {e}"
                    );
                    std::thread::sleep(std::time::Duration::from_secs(delay));
                } else {
                    // Still locked after the budget: almost certainly an overnight
                    // dark wake with no one present. Exit cleanly rather than leave
                    // a stuck dialog — the next real launch (full wake) succeeds.
                    log::error!(
                        "Keychain still locked after {KEYCHAIN_MAX_RETRIES} retries; exiting (will retry on next launch): {e}"
                    );
                    std::process::exit(0);
                }
            }
            Err(e) if attempt < 2 => {
                attempt += 1;
                log::warn!("Sync store open failed (attempt {attempt}/3): {e}; retrying");
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
            Err(e) => {
                log::error!(
                    "Sync store FATAL: could not open {} after retries: {e}",
                    db_path.display()
                );
                let result = rfd::MessageDialog::new()
                    .set_level(rfd::MessageLevel::Error)
                    .set_title("Inbox2 can't open its database")
                    .set_description(format!(
                        "Inbox2 couldn't open its local database:\n{}\n\n{e}\n\n\
                         Your mail is safe on the server. Restart to try again. If \
                         this keeps happening, check available disk space and that \
                         no other copy of Inbox2 is running.",
                        db_path.display()
                    ))
                    .set_buttons(rfd::MessageButtons::OkCancelCustom(
                        "Restart".into(),
                        "Quit".into(),
                    ))
                    .show();
                // Default to restart on anything but an explicit Quit/Cancel, so an
                // unexpected dialog result still self-heals.
                let quit = matches!(result, rfd::MessageDialogResult::Cancel)
                    || matches!(&result, rfd::MessageDialogResult::Custom(s) if s == "Quit");
                if quit {
                    std::process::exit(1);
                } else {
                    app.handle().restart();
                }
            }
        }
    }
}

/// Engine bus: exactly one engine instance across desktop + CLI. Elect this
/// process host or client of the shared Unix-socket bus. The HOST runs the engine
/// + sync loop and broadcasts events; a CLIENT defers to an existing host (e.g.
/// the CLI's engine_daemon) and only relays its events to the webview, so the two
/// never double-sync.
///
/// Returns the engine (`Arc`, shared with the spawned run loop) and, when this
/// process is a bus *client*, the `BusClient` so sync-control commands route to
/// the host and its events refresh the UI.
/// Dev convenience (debug builds only): read the OAuth client credentials from
/// the repo's `api/.env` — the same values the Rails proxy uses — so a plain
/// `tauri dev` refreshes tokens directly against Google/Microsoft without
/// exporting anything. Real env vars win (already stored by
/// `load_oauth_clients_from_env`); release builds never touch the file.
#[cfg(debug_assertions)]
fn load_dev_oauth_clients(engine: &SyncEngine) {
    use crate::sync::model::ProviderType;

    let env_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../api/.env");
    let Ok(content) = std::fs::read_to_string(env_path) else {
        return;
    };
    let mut vars = std::collections::HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            vars.insert(
                k.trim().to_string(),
                v.trim().trim_matches('"').trim_matches('\'').to_string(),
            );
        }
    }
    for (provider, id_key, secret_key) in [
        (ProviderType::Gmail, "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"),
        (ProviderType::Microsoft, "MICROSOFT_CLIENT_ID", "MICROSOFT_CLIENT_SECRET"),
    ] {
        if std::env::var(id_key).is_ok() {
            continue; // the real env already supplied this provider
        }
        if let Some(id) = vars.get(id_key).filter(|s| !s.is_empty()) {
            let secret = vars.get(secret_key).filter(|s| !s.is_empty());
            if let Err(e) = engine.set_oauth_client(&provider, id, secret.map(String::as_str)) {
                log::warn!("dev oauth client ({id_key}): {e}");
            }
        }
    }
}

pub fn init_engine(
    app: &tauri::App,
    store: Arc<SyncStore>,
    app_data_dir: &Path,
) -> (Arc<SyncEngine>, Option<Arc<sync::ipc::BusClient>>) {
    let bus_role = sync::ipc::start_or_attach(app_data_dir);

    let sink: Arc<dyn sync::events::EventSink> = match &bus_role {
        #[cfg(unix)]
        Ok(sync::ipc::BusRole::Host { registry, .. }) => {
            Arc::new(sync::events::CompositeSink(vec![
                Arc::new(sync::TauriSink(app.handle().clone())),
                Arc::new(sync::ipc::BroadcastSink(registry.clone())),
            ]))
        }
        _ => Arc::new(sync::TauriSink(app.handle().clone())),
    };
    let engine = Arc::new(SyncEngine::new(store, sink));
    // OAuth client credentials from the env (or baked in at build) let token
    // refresh go directly to Google/Microsoft — the Rails proxy then only
    // serves first auth.
    engine.load_oauth_clients_from_env();
    #[cfg(debug_assertions)]
    load_dev_oauth_clients(&engine);

    // A BusClient when we lose the election, so the host's events refresh our UI
    // and sync-control commands can be routed to the host.
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut bus_client: Option<Arc<sync::ipc::BusClient>> = None;

    match bus_role {
        #[cfg(unix)]
        Ok(sync::ipc::BusRole::Host { listener, registry, .. }) => {
            log::info!(
                "Engine: elected HOST — running sync loop, serving bus at {}",
                sync::ipc::socket_path(app_data_dir).display()
            );
            // Borrow a tokio handle from tauri's runtime for bus RPC, then serve
            // the accept loop on a dedicated thread.
            let (htx, hrx) = std::sync::mpsc::channel();
            tauri::async_runtime::spawn(async move {
                let _ = htx.send(tokio::runtime::Handle::current());
            });
            if let Ok(handle) = hrx.recv() {
                let dispatcher = sync::rpc::EngineRpc::new(engine.clone(), handle);
                std::thread::spawn(move || sync::ipc::serve(listener, registry, dispatcher));
            }

            // Sync loop + boot — only the host syncs.
            let run_engine = engine.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = run_engine.run().await {
                    log::error!("Sync engine loop exited: {e}");
                }
            });
            let boot_engine = engine.clone();
            tauri::async_runtime::spawn(async move {
                boot_engine.boot_all_accounts().await;
                // Make pre-existing HTML-only mail body-searchable (local, one-time).
                boot_engine.backfill_html_body_text().await;
                boot_engine.reindex_mx_html_search_text().await;
                // Index attachment filenames once the boot sync has populated
                // messages — so a fresh install gets searchable filenames in the
                // same session (incl. providers that don't carry them at sync,
                // e.g. Microsoft/IMAP). Drains to a no-op once caught up.
                boot_engine.backfill_attachment_filenames().await;
            });
        }
        #[cfg(unix)]
        Ok(sync::ipc::BusRole::Client { sock_path }) => {
            log::info!("Engine already hosted at {}; attaching as client", sock_path.display());
            let evt_handle = app.handle().clone();
            match sync::ipc::BusClient::connect(&sock_path, move |event, payload| {
                use tauri::Emitter;
                let _ = evt_handle.emit(event.as_str(), payload);
            }) {
                Ok(c) => bus_client = Some(c),
                Err(e) => log::warn!("Failed to attach to engine bus: {e}"),
            }
        }
        #[cfg(not(unix))]
        Ok(never) => match never {},
        Err(e) => {
            // No bus (socket dir unavailable, or an OS without Unix sockets):
            // fall back to running the engine locally without the shared bus.
            log::warn!("Engine bus unavailable ({e}); running engine locally");
            let run_engine = engine.clone();
            tauri::async_runtime::spawn(async move {
                let _ = run_engine.run().await;
            });
            let boot_engine = engine.clone();
            tauri::async_runtime::spawn(async move {
                boot_engine.boot_all_accounts().await;
                boot_engine.backfill_html_body_text().await;
                boot_engine.reindex_mx_html_search_text().await;
                boot_engine.backfill_attachment_filenames().await;
            });
        }
    }

    (engine, bus_client)
}

/// MCP HTTP interface. Host the MCP server in-core over loopback HTTP. It shares
/// the engine's live DB connection and write-back queue, so agent-driven writes
/// defer to the same sync engine the UI uses. This makes the interface
/// UI-agnostic: identical whether a Tauri window or a pure agent/MCP client is in
/// front. Gated by vector_settings.
pub fn maybe_start_mcp(app_data_dir: &Path, engine: &Arc<SyncEngine>) {
    let mcp_enabled = VectorStore::new(engine.store().connection())
        .get_setting("mcp_server_enabled")
        .ok()
        .flatten()
        .as_deref()
        == Some("true");
    if !mcp_enabled {
        log::info!("MCP server disabled (vector_settings.mcp_server_enabled != 'true')");
        return;
    }
    ensure_mcp_started(app_data_dir, engine);
}

/// Start the MCP HTTP server once per process and return its (port, token).
/// Later calls return the running one: Settings turns it on live, and turning
/// it off only closes the gate (`mcp::http::set_enabled`).
pub fn ensure_mcp_started(app_data_dir: &Path, engine: &Arc<SyncEngine>) -> (u16, String) {
    static STARTED: std::sync::OnceLock<(u16, String)> = std::sync::OnceLock::new();
    crate::mcp::http::set_enabled(true);
    STARTED.get_or_init(|| start_mcp(app_data_dir, engine)).clone()
}

fn start_mcp(app_data_dir: &Path, engine: &Arc<SyncEngine>) -> (u16, String) {
    use std::io::Write;
    let token_path = app_data_dir.join("mcp-token");
    let token = std::fs::read_to_string(&token_path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let t = nanoid::nanoid!(40);
            if let Ok(mut f) = std::fs::File::create(&token_path) {
                // Restrict to the owner BEFORE writing the secret — the token
                // authorizes the full MCP write surface, so a co-resident process
                // must not be able to read it. Mirrors `.credential_key`.
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = f.set_permissions(std::fs::Permissions::from_mode(0o600));
                }
                let _ = f.write_all(t.as_bytes());
            }
            t
        });
    let port: u16 = std::env::var("INBOX2_MCP_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8765);
    let mcp_server = Arc::new(crate::mcp::server::McpServer::new(engine.clone()));
    crate::mcp::http::spawn(mcp_server, token.clone(), port);
    log::info!("MCP bearer token at {}", token_path.display());
    (port, token)
}

/// Listen for deep-link URLs (OAuth callbacks). When the OS delivers
/// `inbox2://oauth-callback?code=X&state=Y`, parse out code+state and forward it
/// as a Tauri event to the frontend (matching the loopback listener's payload).
pub fn register_oauth_deeplink_listener(app: &tauri::App) {
    let app_handle = app.handle().clone();
    app.listen("deep-link://new-url", move |event| {
        // Logged so a platform where the URL never arrives (a Linux .desktop
        // entry without `%u`, seen 2026-11-07) is visible in the log.
        log::info!("[deep-link] {}", event.payload());
        if let Some(urls) = event.payload().strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            // Payload is a JSON array of URL strings
            for url_str in urls.split(',') {
                let url_str = url_str.trim().trim_matches('"');
                if !url_str.contains("oauth-callback") {
                    continue;
                }
                // Parse out code+state so the payload matches what the loopback
                // listener emits ({code, state}) — the frontend listeners expect
                // an object, not a raw URL string.
                let Ok(parsed) = url::Url::parse(url_str) else { continue };
                let code = parsed.query_pairs().find(|(k, _)| k == "code").map(|(_, v)| v.to_string());
                let Some(code) = code else { continue };
                let state = parsed
                    .query_pairs()
                    .find(|(k, _)| k == "state")
                    .map(|(_, v)| v.to_string())
                    .unwrap_or_default();
                let payload = serde_json::json!({ "code": code, "state": state });
                // The URL doesn't identify the provider, so emit to both — only
                // the active listener consumes it.
                let _ = app_handle.emit("gmail-oauth-callback", payload.clone());
                let _ = app_handle.emit("microsoft-oauth-callback", payload);
            }
        }
    });
}

/// Initialize the AI inference engine (Tier A), the vector search subsystem +
/// background embedding pipeline, the agentic-filter runner, and the generative
/// AI state (Tier B). All share the sync engine's DB connection; `engine` is the
/// clone retained before the original is moved into `SyncState`.
pub fn init_ai_subsystems(app: &tauri::App, engine: Arc<SyncEngine>, app_data_dir: &Path) {
    // User prompt overrides: <app data dir>/prompts.toml, edited by hand or via a
    // future Settings editor. Missing file = embedded defaults; a rejected file is
    // logged and ignored so a broken edit can't take triage or the Bridge down.
    let prompts_path = app_data_dir.join("prompts.toml");
    if let Ok(text) = std::fs::read_to_string(&prompts_path) {
        match inbox2_core::bridge::prompts::set_overrides(Some(&text)) {
            Ok(()) => log::info!("prompt overrides loaded from {}", prompts_path.display()),
            Err(e) => log::warn!("prompt overrides rejected ({}): {e}", prompts_path.display()),
        }
    }

    // The core three-lane model manager — drives the Settings lane picker
    // (availability + download state) and the free-model downloads, with the
    // same manifest/installation layout mobile uses.
    crate::ai::lane_commands::init(app, app_data_dir);

    // Tier A inference engine.
    let ai_engine = AIInferenceEngine::new(app_data_dir);
    let ai_engine_arc = Arc::new(Mutex::new(ai_engine));

    app.manage(AIState {
        engine: ai_engine_arc.clone(),
        app_data_dir: app_data_dir.to_path_buf(),
    });

    // Vector search subsystem — shares the sync store's DB connection and the AI
    // engine.
    {
        let sync_conn = engine.store().connection();
        let vector_store = Arc::new(VectorStore::new(sync_conn.clone()));

        app.manage(VectorState {
            store: vector_store.clone(),
            engine: ai_engine_arc.clone(),
            db_conn: sync_conn.clone(),
        });
        let _ = crate::vector::commands::HOSTED.set(VectorState {
            store: vector_store.clone(),
            engine: ai_engine_arc.clone(),
            db_conn: sync_conn.clone(),
        });

        // Start the background embedding pipeline.
        let pipeline = Arc::new(EmbeddingPipeline::new(
            vector_store,
            ai_engine_arc.clone(),
            50, // batch size
        ));
        tauri::async_runtime::spawn(async move {
            pipeline.run().await;
        });
    }

    // Agentic filters — local CLI agent invocation (docs/Agentic-Filters.md).
    // Shares the engine + sync store; runs its own background worker. The same
    // `build_runner` is used by engine_daemon so triggering also works headless
    // (whichever process hosts the engine).
    {
        let (agent_store, runner) = crate::local_agents::build_runner(
            engine.clone(),
            app_data_dir,
            Some(ai_engine_arc.clone()),
        );
        app.manage(crate::local_agents::commands::LocalAgentState {
            store: agent_store,
            runner: runner.clone(),
        });
        tauri::async_runtime::spawn(async move {
            runner.run().await;
        });
    }

    // Generative AI state (Tier B). Held in an `Arc` so the same backend serves
    // both the Tauri commands and the core engine's background triage worker.
    let generative = Arc::new(GenerativeState {
        apple_bridge: Mutex::new(None),
        native_llm: Mutex::new(None),
        backend: Mutex::new(GenerativeBackend::None),
        app_data_dir: app_data_dir.to_path_buf(),
    });

    // Inject the on-device generator into the engine so the triage worker can use
    // the same Apple FM / native-LLM backend the Bridge does (the OpenAI lane
    // needs no injection — the worker calls core's OpenAI client directly).
    engine.set_generator(Arc::new(
        crate::ai::generative_commands::GenerativeStateGenerator(generative.clone()),
    ));
    let _ = crate::ai::generative_commands::HOSTED.set(generative.clone());
    app.manage(generative);

    // The saved Jev key (Settings → AI integrations → Jev), so triage classifies
    // before the webview pushes it. The web's `set_jev_key` keeps it current.
    let jev_secret = format!("{}typesafe_api_key", crate::sync::commands::SECRET_KV_PREFIX);
    if let Ok(Some(key)) = engine.store().get_app_secret(&jev_secret) {
        engine.set_jev_key(Some(key));
    }

    // Background triage + summary worker (mirrors the embedding pipeline
    // above): rules + Jev classify, the lane pushed via `set_ai_config`
    // summarizes; drains the triage queue newest-first.
    let triage_engine = engine.clone();
    tauri::async_runtime::spawn(async move {
        inbox2_core::ai_worker::TriageWorker::new(triage_engine).run().await;
    });

    // Lore ontology miner (docs/Ontology.md): headers catch-up + a few grounded
    // LLM reads per minute through the same lane, local channel mail only.
    let ontology_engine = engine.clone();
    tauri::async_runtime::spawn(async move {
        inbox2_core::ontology::run(ontology_engine).await;
    });

    // Local WhatsApp → Lore (whatsapp_lore.rs): idles until the person turns it on.
    let wa_engine = engine.clone();
    tauri::async_runtime::spawn(async move {
        crate::whatsapp_lore::run(wa_engine).await;
    });
}

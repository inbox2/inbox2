//! App-level Tauri commands that don't belong to a subsystem module: native
//! file-type icons, quit, JS logging, the notification NSPanel conversion, and
//! attachment open/cache.

use crate::sync::commands::SyncState;

/// Get the native OS file type icon for a given extension as a data URI.
#[tauri::command]
pub async fn get_file_type_icon(ext: String, size: i32) -> Result<String, String> {
    let ext_clean = ext.trim_start_matches('.').to_lowercase();
    let png = native_file_type_icon_png(&ext_clean, size)?;

    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
    Ok(format!("data:image/png;base64,{b64}"))
}

/// macOS: render the native icon via NSWorkspace through an inline Swift script,
/// which gives the crispest Finder-matching result. Returns raw PNG bytes.
#[cfg(target_os = "macos")]
fn native_file_type_icon_png(ext_clean: &str, size: i32) -> Result<Vec<u8>, String> {
    use std::process::Command;

    let script = format!(
        r#"
import AppKit
import UniformTypeIdentifiers
guard let utType = UTType(filenameExtension: "{ext_clean}") else {{ exit(1) }}
let ws = NSWorkspace.shared
let icon = ws.icon(for: utType)
icon.size = NSSize(width: {size}, height: {size})
let cgRef = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cgRef)
rep.size = icon.size
let data = rep.representation(using: .png, properties: [:])!
FileHandle.standardOutput.write(data)
"#
    );

    let output = Command::new("swift")
        .args(["-e", &script])
        .output()
        .map_err(|e| format!("Failed to run swift: {e}"))?;

    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Icon script failed: {err}"));
    }
    Ok(output.stdout)
}

/// Windows / Linux: resolve the native shell icon for the extension via the
/// `systemicons` crate (SHGetFileInfo on Windows, the GTK icon theme on Linux).
/// A synthetic `file.<ext>` name is used so the shell/content-type lookup keys
/// off the extension without the file needing to exist. Returns raw PNG bytes.
#[cfg(target_os = "windows")]
fn native_file_type_icon_png(ext_clean: &str, size: i32) -> Result<Vec<u8>, String> {
    systemicons::get_icon(&format!("file.{ext_clean}"), size)
        .map_err(|e| format!("Icon lookup failed: {}", e.message))
}

/// Linux: no native lookup (see Cargo.toml); the UI draws its generic file icon.
#[cfg(target_os = "linux")]
fn native_file_type_icon_png(_ext_clean: &str, _size: i32) -> Result<Vec<u8>, String> {
    Err("no native file-type icons on Linux".into())
}

/// Open a path with the OS default handler. The `opener` plugin dispatches to
/// the right mechanism per platform (`open` on macOS, ShellExecute on Windows,
/// `xdg-open` on Linux) — never shell out to a hardcoded `open` (macOS-only).
pub(crate) fn open_path_default(app: &tauri::AppHandle, path: &std::path::Path) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_path(path.to_string_lossy().to_string(), None::<&str>)
        .map_err(|e| e.to_string())
}

/// Whether the app can place its own popup windows (the new-mail card). Under
/// Wayland no client may position a window, keep it on top or hide it from the
/// taskbar, so the card would land wherever the compositor puts it; the UI then
/// routes the "custom" alert mode to the system notification instead. An
/// explicit `GDK_BACKEND=x11` (XWayland) keeps the popups.
#[tauri::command]
pub fn popup_windows_supported() -> bool {
    #[cfg(target_os = "linux")]
    {
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t == "wayland");
        let forced_x11 = std::env::var("GDK_BACKEND").is_ok_and(|b| b.split(',').next() == Some("x11"));
        !wayland || forced_x11
    }
    #[cfg(not(target_os = "linux"))]
    true
}

/// Whether the webview draws without a GPU. WebKit reports a made-up WebGL renderer,
/// so the page can't tell; on Linux no DRM render node (a VM, a container, no
/// driver) or `LIBGL_ALWAYS_SOFTWARE` means Mesa's llvmpipe draws every frame on
/// the CPU, and the UI then keeps its backdrop still.
#[tauri::command]
pub fn software_rendering() -> bool {
    #[cfg(target_os = "linux")]
    {
        let forced = std::env::var("LIBGL_ALWAYS_SOFTWARE").is_ok_and(|v| v != "0");
        let render_node = std::fs::read_dir("/dev/dri").is_ok_and(|d| {
            d.flatten().any(|e| e.file_name().to_string_lossy().starts_with("renderD"))
        });
        forced || !render_node
    }
    #[cfg(not(target_os = "linux"))]
    false
}

/// Quit the app after the frontend's confirm dialog. Tears down auxiliary
/// windows first so the always-on-top notification panel doesn't linger.
#[tauri::command]
pub fn quit_app(app: tauri::AppHandle) {
    use tauri::Manager;
    for (label, w) in app.webview_windows() {
        if label != "main" {
            let _ = w.destroy();
        }
    }
    app.exit(0);
}

/// Log a message from the JS webview to the Rust log.
#[tauri::command]
pub async fn js_log(level: String, message: String) {
    match level.as_str() {
        "error" => log::error!("[JS] {message}"),
        "warn" => log::warn!("[JS] {message}"),
        "debug" => log::debug!("[JS] {message}"),
        _ => log::info!("[JS] {message}"),
    }
}

/// macOS: convert the new-mail popup into a *non-activating* NSPanel via
/// tauri-nspanel.
///
/// The popup is a separate window owned by this app; on macOS, clicking any of
/// its action buttons (Archive / Delete / Read) would otherwise activate the
/// app and yank the main window forward. A non-activating panel receives clicks
/// without activating the owning app, so fire-and-forget actions leave the app
/// where it is. The "Read"/"Reply" path still raises the main window on purpose
/// via the `notification-navigate` event.
///
/// Idempotent: the popup window is persistent (hidden between alerts, never
/// destroyed) and converted exactly once. The plugin's panel registry isn't
/// cleaned up on window destroy, so re-converting a recreated same-label window
/// would drop a dangling `RawNSPanel` and double-free — hence persist + convert
/// once, guarded by the `get_webview_panel` check below.
#[tauri::command]
pub fn convert_notification_to_panel(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use tauri::Manager;
        let Some(window) = app.get_webview_window("notification") else {
            return Err("notification window not found".into());
        };
        let app = app.clone();
        // AppKit window mutation (the class swap + msg_sends) must run on the
        // main thread.
        window
            .run_on_main_thread(move || {
                use tauri_nspanel::{ManagerExt, WebviewWindowExt};
                if app.get_webview_panel("notification").is_ok() {
                    return; // already converted — don't re-insert into the store
                }
                let Some(win) = app.get_webview_window("notification") else {
                    return;
                };
                match win.to_panel() {
                    Ok(panel) => {
                        // 1 << 7 = NSWindowStyleMaskNonactivatingPanel.
                        panel.set_style_mask(1 << 7);
                        // Setting that mask after the window exists doesn't reach
                        // the window server, so a click (Delete/Archive) still
                        // activated the app and raised the main window. The
                        // private setter Electron uses for the same bug fixes it.
                        prevent_activation(&win);
                        panel.set_becomes_key_only_if_needed(true);
                        panel.set_floating_panel(true);
                        // NSFloatingWindowLevel — keep it above normal windows,
                        // replacing the always-on-top the plain window had.
                        panel.set_level(3);
                        // We hide the popup between alerts and only destroy it on
                        // app quit; let Tauri own the lifetime so close() doesn't
                        // release a window the plugin still holds.
                        panel.set_released_when_closed(false);
                        // A non-activating panel isn't key, so AppKit treats the
                        // first click as "make this window key" and swallows it —
                        // the action button (Delete/Archive/…) only fires on the
                        // second click. Teach views inside the panel to accept the
                        // first mouse so a single click acts immediately, and to
                        // decline key-window promotion so the click never yanks
                        // keyboard focus off the user's active app.
                        install_panel_focus_overrides();
                    }
                    Err(_) => log::warn!("notification to_panel conversion failed"),
                }
            })
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
    Ok(())
}

#[cfg(target_os = "macos")]
fn prevent_activation(win: &tauri::WebviewWindow) {
    use objc::runtime::{Object, BOOL, NO, YES};
    use objc::{msg_send, sel, sel_impl};
    let Ok(ns) = win.ns_window() else { return };
    let ns = ns as *mut Object;
    unsafe {
        let ok: BOOL = msg_send![ns, respondsToSelector: sel!(_setPreventsActivation:)];
        if ok != NO {
            let _: () = msg_send![ns, _setPreventsActivation: YES];
        } else {
            log::warn!("_setPreventsActivation: unavailable — panel clicks may activate the app");
        }
    }
}

/// Keep the notification panel from ever stealing keyboard focus, while still
/// letting a single click hit its buttons. Installed exactly once and must run
/// on the main thread (called from inside `run_on_main_thread` above, after
/// `to_panel()` has registered the `RawNSPanel` class).
///
/// 1. `-[RawNSPanel canBecomeKeyWindow]` → NO. tauri-nspanel hardcodes this to
///    YES, so `becomesKeyOnlyIfNeeded` isn't enough — a click that lands in the
///    WKWebView still promotes the panel to key window and yanks keyboard focus
///    off the user's active app. Overriding it window-level (not per hit-view,
///    which the webview's private subviews slip past) means the panel can never
///    become key. The card has no text input, so it never needs to be key.
/// 2. `-[NSView acceptsFirstMouse:]` → YES for views inside an `NSPanel`: with
///    the panel never key, every click is a "first mouse" on an inactive window;
///    this makes that click reach the button instead of being swallowed. Gated
///    to panel views so every other window chains the original and keeps stock
///    behaviour.
#[cfg(target_os = "macos")]
pub(crate) static KEYABLE_PANEL: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

#[cfg(target_os = "macos")]
pub(crate) fn install_panel_focus_overrides() {
    use objc::runtime::{
        class_getInstanceMethod, method_getImplementation, method_setImplementation, Class, Imp,
        Method, Object, Sel, BOOL, NO, YES,
    };
    use objc::{class, msg_send, sel, sel_impl};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Once;

    // Original IMP so non-panel views keep stock behaviour. Stored as usize
    // because fn pointers aren't atomic.
    static ORIG_FIRST_MOUSE: AtomicUsize = AtomicUsize::new(0);
    static SWIZZLE: Once = Once::new();

    // The menu bar popover (tray.rs) is the one panel that MUST become key — it
    // closes itself on resign-key and takes Escape — so it is let through by
    // identity. A non-activating panel going key doesn't activate the app.
    extern "C" fn cannot_become_key(this: &Object, _cmd: Sel) -> BOOL {
        if this as *const Object as usize == KEYABLE_PANEL.load(Ordering::SeqCst) {
            YES
        } else {
            NO
        }
    }

    extern "C" fn accepts_first_mouse(this: &Object, cmd: Sel, event: *mut Object) -> BOOL {
        unsafe {
            let window: *mut Object = msg_send![this, window];
            if !window.is_null() {
                let is_panel: BOOL = msg_send![window, isKindOfClass: class!(NSPanel)];
                if is_panel != NO {
                    return YES;
                }
            }
            let original = ORIG_FIRST_MOUSE.load(Ordering::SeqCst);
            if original != 0 {
                let original: extern "C" fn(&Object, Sel, *mut Object) -> BOOL =
                    std::mem::transmute(original);
                return original(this, cmd, event);
            }
            NO
        }
    }

    SWIZZLE.call_once(|| unsafe {
        // tauri-nspanel registers the panel under the "RawNSPanel" class name and
        // gives it a `canBecomeKeyWindow` returning YES — flip that IMP to NO.
        match Class::get("RawNSPanel") {
            Some(cls) => {
                let m = class_getInstanceMethod(cls, sel!(canBecomeKeyWindow));
                if m.is_null() {
                    log::warn!("canBecomeKeyWindow not found on RawNSPanel — skipping");
                } else {
                    let imp: Imp =
                        std::mem::transmute(cannot_become_key as extern "C" fn(&Object, Sel) -> BOOL);
                    method_setImplementation(m as *mut Method, imp);
                }
            }
            None => log::warn!("RawNSPanel class not registered — skipping canBecomeKeyWindow"),
        }

        let fm = class_getInstanceMethod(class!(NSView), sel!(acceptsFirstMouse:));
        if fm.is_null() {
            log::warn!("acceptsFirstMouse: not found on NSView — skipping swizzle");
        } else {
            ORIG_FIRST_MOUSE.store(method_getImplementation(fm) as usize, Ordering::SeqCst);
            let imp: Imp = std::mem::transmute(
                accepts_first_mouse as extern "C" fn(&Object, Sel, *mut Object) -> BOOL,
            );
            method_setImplementation(fm as *mut Method, imp);
        }
    });
}

/// Save attachment bytes to the shared per-message cache and open with the system
/// default handler. Message-namespaced so the same file shared by the user-open
/// flow and the agent runner (docs/Agentic-Filters.md) never collides across
/// different messages.
#[tauri::command]
pub async fn save_and_open_attachment(
    app: tauri::AppHandle,
    state: tauri::State<'_, SyncState>,
    account_key: String,
    message_key: String,
    filename: String,
    data: Vec<u8>,
) -> Result<String, String> {
    let path = state
        .engine
        .store()
        .cache_message_attachment(&account_key, &message_key, &filename, &data)
        .map_err(|e| e.to_string())?;

    // Open with the OS default handler (cross-platform via the opener plugin).
    open_path_default(&app, &path)?;

    Ok(path.to_string_lossy().to_string())
}

/// Show a native "Save As…" dialog seeded with `filename`, then write the
/// attachment bytes to the chosen location. Returns the saved path, or `None`
/// if the user cancelled the dialog.
///
/// The panel is presented on the main thread and parented to the app window —
/// without a parent it can open *behind* the app and only surface once the user
/// blurs and refocuses the window.
#[tauri::command]
pub async fn save_attachment_as(
    window: tauri::WebviewWindow,
    filename: String,
    data: Vec<u8>,
) -> Result<Option<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let win = window.clone();
    window
        .run_on_main_thread(move || {
            let path = rfd::FileDialog::new()
                .set_file_name(&filename)
                .set_parent(&win)
                .save_file();
            let _ = tx.send(path);
        })
        .map_err(|e| e.to_string())?;

    let Some(path) = rx.await.map_err(|e| e.to_string())? else {
        return Ok(None); // user cancelled
    };

    std::fs::write(&path, &data).map_err(|e| e.to_string())?;
    Ok(Some(path.to_string_lossy().to_string()))
}

/// Open an attachment from the shared per-message cache if it exists, otherwise error.
#[tauri::command]
pub async fn open_cached_attachment(
    app: tauri::AppHandle,
    state: tauri::State<'_, SyncState>,
    account_key: String,
    message_key: String,
    filename: String,
) -> Result<String, String> {
    let path = state
        .engine
        .store()
        .message_attachment_path(&account_key, &message_key, &filename);

    if !path.exists() {
        return Err("Not cached".to_string());
    }

    // Open with the OS default handler (cross-platform via the opener plugin).
    open_path_default(&app, &path)?;

    Ok(path.to_string_lossy().to_string())
}

/// Read an attachment's bytes from the on-disk per-message cache if present.
/// Lets the byte-based flows (Forward / Save-as) reuse a file already downloaded
/// in a previous session instead of re-fetching it from the provider.
#[tauri::command]
pub async fn read_cached_attachment(
    state: tauri::State<'_, SyncState>,
    account_key: String,
    message_key: String,
    filename: String,
) -> Result<Vec<u8>, String> {
    let path = state
        .engine
        .store()
        .message_attachment_path(&account_key, &message_key, &filename);

    if !path.exists() {
        return Err("Not cached".to_string());
    }
    std::fs::read(&path).map_err(|e| e.to_string())
}

/// Write attachment bytes to the on-disk per-message cache (no open). Lets a
/// provider download persist across restarts so later Open/Forward/Save-as hit
/// the disk cache.
#[tauri::command]
pub async fn cache_attachment_bytes(
    state: tauri::State<'_, SyncState>,
    account_key: String,
    message_key: String,
    filename: String,
    data: Vec<u8>,
) -> Result<String, String> {
    let path = state
        .engine
        .store()
        .cache_message_attachment(&account_key, &message_key, &filename, &data)
        .map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().to_string())
}

// ─── Drag out of the window (tauri-plugin-drag) ──────────────────────────────
// macOS starts a drag only inside the mouse event, so the page prepares the
// file first (these commands) and starts the drag synchronously on dragstart.

/// A file icon for dragging something with no picture of its own.
pub(crate) fn drag_icon_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    use tauri::Manager;
    let icon = app.path().app_cache_dir().map_err(|e| e.to_string())?.join("drag-icon.png");
    if !icon.exists() {
        std::fs::create_dir_all(icon.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&icon, include_bytes!("../icons/Square71x71Logo.png")).map_err(|e| e.to_string())?;
    }
    Ok(icon)
}

#[tauri::command]
pub fn drag_fallback_icon(app: tauri::AppHandle) -> Result<String, String> {
    Ok(drag_icon_path(&app)?.to_string_lossy().into_owned())
}

/// An attachment's file in the per-message cache (written by Open / Forward /
/// a drag preparation), when it is there.
#[tauri::command]
pub fn attachment_cache_path(
    state: tauri::State<'_, SyncState>,
    account_key: String,
    message_key: String,
    filename: String,
) -> Option<String> {
    let path = state.engine.store().message_attachment_path(&account_key, &message_key, &filename);
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

//! Menu bar (system tray) item + its popover window.
//!
//! The icon is a template image (the app-icon box, 2 knocked out) the system
//! tints for a light or dark menu bar. A click toggles the `tray` webview — the
//! web app's `/tray` route — hung under the icon; it hides again as soon as it
//! loses focus, like any menu bar popover. The main window drives the text next
//! to the icon (unread count / next meeting) through `tray_set_title`, because
//! the hidden tray webview is suspended by WebKit and can't tick on its own.
//!
//! macOS: the window is converted to a NON-ACTIVATING NSPanel, so opening the
//! popover never activates inbox2 (which dragged the main window to the front).
//! Unlike the notification popup it is allowed to become key — see
//! `commands::KEYABLE_PANEL` — because resign-key is what closes it.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

const TRAY_ID: &str = "inbox2";
pub const WINDOW: &str = "tray";

// Must agree with TrayPage.module.css: the popover card is CARD_W wide and sits
// at the right of a wider transparent window, so the day-hover preview has room
// to fly out to its left (a webview can't draw outside its own window).
const WINDOW_W: f64 = 620.0;
const WINDOW_H: f64 = 780.0;
const CARD_W: f64 = 360.0;
const CARD_INSET: f64 = 8.0; // .window's right padding (--space-2)

// Clicking the icon while the popover is open blurs (hides) it on mouse-down,
// then the same click's mouse-up would toggle it straight back open. A click this
// soon after a blur-hide IS the closing click: swallow it.
//
// The same window guards the other side: a resign-key this soon after showing is
// not the user clicking away, it is the window settling — take key back.
const SETTLE: Duration = Duration::from_millis(400);
static BLUR_HIDDEN_AT: Mutex<Option<Instant>> = Mutex::new(None);
static SHOWN_AT: Mutex<Option<Instant>> = Mutex::new(None);

fn within(mark: &Mutex<Option<Instant>>) -> bool {
    mark.lock().ok().and_then(|m| *m).is_some_and(|t| t.elapsed() < SETTLE)
}

fn stamp(mark: &Mutex<Option<Instant>>) {
    if let Ok(mut m) = mark.lock() {
        *m = Some(Instant::now());
    }
}

/// Bring `main` to the front: unminimize, show, focus. Shared by the Linux tray
/// menu and the Windows/Linux single-instance callback.
#[cfg(not(target_os = "macos"))]
pub fn focus_main(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        if let Ok(true) = win.is_minimized() {
            let _ = win.unminimize();
        }
        let _ = win.show();
        let _ = win.set_focus();
    }
}

pub fn init(app: &tauri::AppHandle) -> tauri::Result<()> {
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-template.png"))?;
    let builder = TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .icon_as_template(true)
        .tooltip("inbox2");

    // Linux: the appindicator backend never emits click events (tray-icon:
    // "Linux: Unsupported"), and without a menu the icon may not even show. So
    // the tray is a two-item menu there, and the popover window is not built.
    #[cfg(target_os = "linux")]
    {
        use tauri::menu::{MenuBuilder, MenuItemBuilder};
        let open = MenuItemBuilder::with_id("tray_open", "Open Inbox2").build(app)?;
        let quit = MenuItemBuilder::with_id("tray_quit", "Quit Inbox2").build(app)?;
        let menu = MenuBuilder::new(app).items(&[&open, &quit]).build()?;
        builder
            .menu(&menu)
            .show_menu_on_left_click(true)
            .on_menu_event(|app, event| match event.id().as_ref() {
                "tray_open" => focus_main(app),
                "tray_quit" => {
                    let _ = app.emit_to("main", "menu:quit-request", ());
                }
                _ => {}
            })
            .build(app)?;
        return Ok(());
    }

    #[cfg(not(target_os = "linux"))]
    builder
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                toggle(tray.app_handle(), rect);
            }
        })
        .build(app)?;
    // Build the popover now, hidden, rather than on the first click: a window's
    // first moments are a burst of focus churn (creation, the panel class swap,
    // the webview taking first responder) that read as "focus lost" and closed
    // it the instant it appeared. It also means the page is already loaded, so
    // the first open isn't a blank card.
    #[cfg(not(target_os = "linux"))]
    if let Err(e) = build_window(app) {
        log::warn!("tray: window creation failed: {e}");
    }
    #[cfg(not(target_os = "linux"))]
    Ok(())
}

fn toggle(app: &tauri::AppHandle, icon: tauri::Rect) {
    if within(&BLUR_HIDDEN_AT) {
        return; // this click already closed it (see SETTLE)
    }
    let window = match app.get_webview_window(WINDOW) {
        Some(w) => w,
        None => match build_window(app) {
            Ok(w) => w,
            Err(e) => {
                log::warn!("tray: window creation failed: {e}");
                return;
            }
        },
    };
    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        return;
    }

    // The click rect is in physical pixels and spans the whole item (icon + title).
    // Probe the monitor at the item's CENTRE: its origin sits on the screen's top
    // edge, where the lookup found nothing, the scale fell back to 1 and the
    // popover landed ~220pt right of the icon on a Retina display.
    let pos = icon.position.to_physical::<f64>(1.0);
    let size = icon.size.to_physical::<f64>(1.0);
    let (cx, cy) = (pos.x + size.width / 2.0, pos.y + size.height / 2.0);
    let monitor = app
        .monitor_from_point(cx, cy)
        .ok()
        .flatten()
        .or_else(|| app.primary_monitor().ok().flatten());
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    // Centre the CARD (the window's right-hand CARD_W, inset by CARD_INSET) under
    // the item, but never let it run off the right edge of that screen.
    let mut x = cx - (WINDOW_W - CARD_INSET - CARD_W / 2.0) * scale;
    // macOS: the item sits in the menu bar, so the popover hangs below it.
    // Windows: the icon sits in the taskbar, normally along the bottom edge, so
    // the popover opens above it; a top-docked taskbar still hangs it below.
    let mut y = pos.y + size.height;
    if let Some(m) = &monitor {
        let left = m.position().x as f64;
        let right = left + m.size().width as f64;
        x = x.min(right - WINDOW_W * scale).max(left);
        let bottom = m.position().y as f64 + m.size().height as f64;
        if cy > m.position().y as f64 + m.size().height as f64 / 2.0 {
            y = (pos.y - WINDOW_H * scale).max(m.position().y as f64);
        }
        y = y.min(bottom - WINDOW_H * scale).max(m.position().y as f64);
    }
    let _ = window.set_position(PhysicalPosition::new(x.round(), y.round()));
    stamp(&SHOWN_AT);
    show(app, &window);
    // Hidden webviews are suspended; tell the page to re-read theme + data now.
    let _ = app.emit_to(WINDOW, "tray-opened", ());
}

fn build_window(app: &tauri::AppHandle) -> tauri::Result<tauri::WebviewWindow> {
    let window = WebviewWindowBuilder::new(app, WINDOW, WebviewUrl::App("/tray".into()))
        .title("")
        .inner_size(WINDOW_W, WINDOW_H)
        .visible(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .build()?;
    let handle = window.clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::Focused(false) = event {
            if !handle.is_visible().unwrap_or(false) {
                return; // hidden already (startup, or our own hide) — nothing to close
            }
            if within(&SHOWN_AT) {
                show(handle.app_handle(), &handle);
                return;
            }
            stamp(&BLUR_HIDDEN_AT);
            let _ = handle.hide();
        }
    });
    #[cfg(target_os = "macos")]
    to_key_panel(&window);
    Ok(window)
}

/// Order front + make key WITHOUT activating the app (macOS); elsewhere a plain
/// show + focus.
fn show(app: &tauri::AppHandle, window: &tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    {
        use tauri_nspanel::ManagerExt;
        if let Ok(panel) = app.get_webview_panel(WINDOW) {
            panel.show();
            return;
        }
    }
    let _ = app;
    let _ = window.show();
    let _ = window.set_focus();
    // Windows never delivers `Focused(false)` for this window (keyboard focus
    // sits in the WebView2 child, verified 2026-11-07), so poll instead: once
    // it stops being the active window, hide it like the blur handler would.
    #[cfg(target_os = "windows")]
    {
        let w = window.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(150));
            if !w.is_visible().unwrap_or(false) {
                break;
            }
            if !w.is_focused().unwrap_or(true) && !within(&SHOWN_AT) {
                stamp(&BLUR_HIDDEN_AT);
                let _ = w.hide();
                break;
            }
        });
    }
}

/// Once per window (it lives for the session, hidden between opens) — same
/// lifetime rules as the notification panel, see commands.rs.
#[cfg(target_os = "macos")]
fn to_key_panel(window: &tauri::WebviewWindow) {
    use std::sync::atomic::Ordering;
    use tauri_nspanel::WebviewWindowExt;
    match window.to_panel() {
        Ok(panel) => {
            panel.set_style_mask(1 << 7); // NSWindowStyleMaskNonactivatingPanel
            panel.set_level(25); // NSStatusWindowLevel — above floating windows
            panel.set_released_when_closed(false);
            let ptr = &*panel as *const tauri_nspanel::raw_nspanel::RawNSPanel as usize;
            crate::commands::KEYABLE_PANEL.store(ptr, Ordering::SeqCst);
            crate::commands::install_panel_focus_overrides();
        }
        Err(_) => log::warn!("tray: to_panel conversion failed — popover will activate the app"),
    }
}

/// Text beside the menu bar icon ("12", "Standup · in 10m"); empty clears it.
#[tauri::command]
pub fn tray_set_title(app: tauri::AppHandle, title: String) -> Result<(), String> {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return Ok(()); // no tray on this platform/session — nothing to label
    };
    tray.set_title(if title.is_empty() { None } else { Some(title) })
        .map_err(|e| e.to_string())
}

/// Close the popover from the page (Escape, a row click, the transparent gutter).
#[tauri::command]
pub fn tray_hide(app: tauri::AppHandle) {
    if let Some(w) = app.get_webview_window(WINDOW) {
        let _ = w.hide();
    }
}

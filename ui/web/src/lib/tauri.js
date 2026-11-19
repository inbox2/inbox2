// Tauri desktop detection helper.
// Sync engine is started by the Tauri app itself, not by the web app.

export function isTauri() {
  return typeof window !== 'undefined' && window.__TAURI_INTERNALS__ !== undefined;
}

// Host OS, best-effort from the navigator. Single source of truth for every
// platform branch (CSS data-os attribute, shortcut-glyph rendering, …) so the
// detection logic can't drift between call sites.
export function getOS() {
  const platform =
    (typeof navigator !== 'undefined' &&
      (navigator.userAgentData?.platform || navigator.platform)) || '';
  if (/mac|iphone|ipad/i.test(platform)) return 'macos';
  if (/win/i.test(platform)) return 'windows';
  return 'linux';
}

// The word for "this machine" in copy: "Mac" on macOS, "computer" on Windows and
// Linux (where "On this Mac" read wrong in the setup wizard, 2026-11-07).
export function deviceWord() {
  return getOS() === 'macos' ? 'Mac' : 'computer';
}

// Programmatic window drag — bypasses WKWebView data-tauri-drag-region bugs.
// Use as onMouseDown={startDrag} on drag-region elements.
export function startDrag(e) {
  if (e.button !== 0 || !isTauri()) return;
  // Never start a window drag from an interactive control. Besides being the
  // correct behaviour (clicking a button shouldn't move the window), invoking
  // start_dragging on a control-click crashes tao's drag_window: the async IPC
  // runs after the click resolves, so [NSApp currentEvent] is nil → a panic
  // ("messaging to nil"). This fired when clicking the chrome bar's gear/tabs.
  if (e.target?.closest?.('button, a, input, select, textarea, [role="button"], [contenteditable]')) return;
  import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
    getCurrentWindow().startDragging();
  });
}

// Windows/Linux draw no native title bar (decorations are off there, see
// src-tauri/src/setup.rs), so the chrome bar carries the window controls and a
// double-click on it maximizes, like a title bar would.
export function hasOwnWindowControls() {
  return isTauri() && getOS() !== 'macos';
}

export function toggleMaximizeOnDoubleClick(e) {
  if (!hasOwnWindowControls()) return;
  if (e.target?.closest?.('button, a, input, select, textarea, [role="button"], [contenteditable]')) return;
  import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
    getCurrentWindow().toggleMaximize();
  });
}

// Whether the app may place its own popup windows (the new-mail card). False
// under Wayland, where no client can position a window; the alert then goes to
// the system notification instead. Asked once per session.
let popupSupport;
export function popupWindowsSupported() {
  if (!isTauri()) return Promise.resolve(false);
  popupSupport ??= import('@tauri-apps/api/core')
    .then(({ invoke }) => invoke('popup_windows_supported'))
    .catch(() => true);
  return popupSupport;
}

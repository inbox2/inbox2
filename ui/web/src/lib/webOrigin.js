// The hosted web app origin (mail.inbox2.com). The desktop app runs the same
// frontend bundled in a Tauri webview, so admin/console surfaces that would
// otherwise replace the mail UI are opened here in the system browser instead.
// Overridable via VITE_ACCOUNT_URL (dev / staging).
export const ACCOUNT_WEB_URL =
  (import.meta.env.VITE_ACCOUNT_URL || 'https://mail.inbox2.com').replace(/\/+$/, '');

// The hosted admin console (console.inbox2.com), with its pages at the root.
// Overridable via VITE_CONSOLE_URL (dev / staging).
export const CONSOLE_WEB_URL =
  (import.meta.env.VITE_CONSOLE_URL || 'https://console.inbox2.com').replace(/\/+$/, '');

// Disk on the web (disk.inbox2.com): web only, so the desktop app opens it in the system browser.
// Overridable via VITE_DISK_URL (dev / staging).
export const DISK_WEB_URL =
  (import.meta.env.VITE_DISK_URL || 'https://disk.inbox2.com').replace(/\/+$/, '');

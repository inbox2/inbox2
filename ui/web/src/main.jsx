if (import.meta.env.DEV) {
  import("react-grab");
}

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router';
import AuthProvider from './hooks/AuthProvider';
import AppRoutes from './routes';
import ErrorBoundary from './components/ErrorBoundary/ErrorBoundary';
import NativeTitleTooltips from './components/Tooltip/NativeTitleTooltips';
import { isTauri, getOS } from './lib/tauri';
import { initUpdateNudge } from './lib/updater';
import { applyStoredAppIcon } from './lib/appIcon';
import { openLink } from './lib/openLink';
import { THEME } from './lib/storageKeys';
import { applyTheme, DEFAULT_THEME_ID } from './lib/themes';
import { startAmbientMotion } from './lib/ambientMotion';
import { initSentry } from './lib/sentry';
import './styles/tokens.css';
import './styles/reset.css';
import './styles/management.css';

// Apply the saved theme at boot so every page — including the pre-app login /
// onboarding screens — inherits the right token set AND the variant overrides
// (e.g. the Warm theme's violet button). The stored value is a theme *id*
// (e.g. "dark-warm"); applyTheme resolves it to its `data-theme` mode + overrides.
// Setting the raw id as `data-theme` matched no token block (→ fell back to brown).
applyTheme(localStorage.getItem(THEME) || DEFAULT_THEME_ID);

// Pause ambient motion once nobody is at the window (lib/ambientMotion.js).
startAmbientMotion();

// Flag Tauri desktop environment for CSS (traffic light padding, etc.)
if (isTauri()) {
  document.documentElement.setAttribute('data-tauri', '');

  // Tag the host OS so CSS can branch on it: macOS overlays window controls on
  // the webview (needs traffic-light inset + native vibrancy), while Windows/Linux
  // use a native title bar and CSS-glass chrome. (see styles/layout.module.css)
  document.documentElement.setAttribute('data-os', getOS());

  // Auto-update: surface the startup check's "update available" result as a
  // window event the About panel (and any future chrome badge) can react to.
  initUpdateNudge();

  // A running process can't rewrite its own bundle icon, so the chosen Dock/taskbar
  // icon has to be re-applied on every launch (Settings > Theme > App icon).
  applyStoredAppIcon();

  // Email-iframe links: WKWebView can't deliver iframe clicks to JS, so the Rust
  // navigation handler cancels the in-frame navigation and forwards the URL here.
  // Registered at the entry point so it's always active (not tied to sync init).
  import('@tauri-apps/api/event').then(({ listen }) => {
    listen('open-external-link', (e) => {
      if (e?.payload) openLink(e.payload);
    });
  });

  // WKWebView's own right-click menu (Back / Reload / AutoFill) is browser chrome
  // that means nothing in an app window. Suppress it everywhere except where the
  // native edit menu is genuinely useful: text fields and selected text.
  document.addEventListener('contextmenu', (e) => {
    if (e.target?.closest?.('input, textarea, [contenteditable]:not([contenteditable="false"])')) return;
    if (!window.getSelection()?.isCollapsed) return;
    e.preventDefault();
  });

  // Track fullscreen state — traffic lights hide in fullscreen, so chrome padding adjusts
  import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
    const win = getCurrentWindow();
    const sync = () => win.isFullscreen().then(fs => {
      document.documentElement.toggleAttribute('data-tauri-fullscreen', fs);
    });
    sync();
    win.onResized(sync);
  });
}

initSentry();

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <BrowserRouter>
      <ErrorBoundary>
        <AuthProvider>
          <AppRoutes />
          {/* Every native `title` renders as our own tooltip instead of the
              OS bubble — see NativeTitleTooltips. */}
          <NativeTitleTooltips />
        </AuthProvider>
      </ErrorBoundary>
    </BrowserRouter>
  </StrictMode>,
);

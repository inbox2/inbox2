// Single source for the desktop setup-mode flag written by SetupWizardPage.
//
// Read and write it ONLY through the helpers here. It used to be compared
// against raw literals in three places that disagreed: the wizard wrote '1' for
// MX mode, this module treated `!== '1'` as standalone, and routes.jsx treated
// `!== 'mx'` as standalone — so an MX install matched BOTH definitions and
// ProtectedRoute handed over the app without ever requiring a login.
import { isTauri } from './tauri';

export const SETUP_COMPLETE_KEY = 'inbox2_setup_complete';

export const SETUP_MODE = {
  // Domain mail through inbox2: the app authenticates with a web session/token.
  MX: 'mx',
  // Offline desktop client over local channels only, no web session. Cloud
  // extras (image proxy, push) authenticate with a personal ink_ API key.
  STANDALONE: 'standalone',
};

// '1' was the original MX value. Installs in the wild still hold it, so map it
// rather than treating it as unset — that would throw an existing user back into
// the setup wizard on upgrade.
const LEGACY_MX = '1';

/** The stored mode, normalised, or null when setup has never been completed. */
export function getSetupMode() {
  const raw = localStorage.getItem(SETUP_COMPLETE_KEY);
  if (!raw) return null;
  if (raw === LEGACY_MX) {
    // Migrate in place so the legacy value is read exactly once.
    localStorage.setItem(SETUP_COMPLETE_KEY, SETUP_MODE.MX);
    return SETUP_MODE.MX;
  }
  return raw === SETUP_MODE.MX ? SETUP_MODE.MX : SETUP_MODE.STANDALONE;
}

export function setSetupMode(mode) {
  localStorage.setItem(
    SETUP_COMPLETE_KEY,
    mode === SETUP_MODE.MX ? SETUP_MODE.MX : SETUP_MODE.STANDALONE
  );
}

/** Send the user back through the wizard (the login screen's "Back"). */
export function clearSetupMode() {
  localStorage.removeItem(SETUP_COMPLETE_KEY);
}

/** Has the desktop first-run wizard been completed at all? */
export function isSetupComplete() {
  return getSetupMode() !== null;
}

/**
 * Standalone desktop — no web session, so cloud features fall back to the
 * personal API key. False on the web build, which is never standalone.
 */
export function isStandaloneDesktop() {
  return isTauri() && getSetupMode() === SETUP_MODE.STANDALONE;
}

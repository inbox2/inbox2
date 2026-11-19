// Desktop auto-update bridge.
//
// The whole flow (check → download → install → relaunch) lives in Rust behind
// two Tauri commands; this is a thin invoke wrapper so the UI doesn't need the
// JS updater/process plugin packages. No-ops gracefully on web.

import { isTauri } from './tauri';
import log from './log';

// Check the release endpoint for a newer signed build.
// Returns null when up to date (or on web), or { version, current_version,
// notes, date } when an update is available.
export async function checkForUpdates() {
  if (!isTauri()) return null;
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('check_for_updates');
}

// Download + install the pending update, then relaunch. `onProgress({ downloaded,
// content_length })` is called repeatedly during the download. The promise only
// resolves if the install is deferred (deb/rpm hand off to a privileged prompt);
// on macOS/Windows/AppImage the app relaunches before it resolves.
export async function installUpdate(onProgress) {
  if (!isTauri()) throw new Error('Updates need the desktop app');
  const { invoke } = await import('@tauri-apps/api/core');
  const { listen } = await import('@tauri-apps/api/event');
  let unlisten = () => {};
  if (onProgress) {
    unlisten = await listen('update://progress', (e) => onProgress(e.payload));
  }
  try {
    await invoke('download_and_install_update');
  } finally {
    unlisten();
  }
}

// Listen for the Rust poll's result. Emitted a few seconds after launch and
// every couple of minutes after that, only when an update is available.
// Returns an unlisten fn.
export async function onUpdateAvailable(handler) {
  if (!isTauri()) return () => {};
  const { listen } = await import('@tauri-apps/api/event');
  return listen('update://available', (e) => handler(e.payload));
}

// One-liner wired from main.jsx: feed the poll into the update store, which the
// chrome bell tag, the notification panel and Settings › About all read.
export function initUpdateNudge() {
  if (!isTauri()) return;
  onUpdateAvailable(async (info) => {
    log.info('updater', `update available: ${info?.current_version} → ${info?.version}`);
    const { default: useUpdateStore } = await import('../stores/updateStore');
    useUpdateStore.getState().found(info);
  });
}

import { useState, useEffect, useCallback } from 'react';
import syncManager from '../lib/sync-manager';
import log from '../lib/log';

/**
 * Async triage + multi-level summary state for the desktop (Tauri) client:
 * the worker's progress (live via `triage-progress` events) and the processing
 * window get/set. Mirrors the iOS EngineModel triage surface.
 */
export default function useTriage() {
  const [progress, setProgress] = useState({ inWindow: 0, done: 0, pending: 0, jevStatus: null });
  const [window, setWindowState] = useState('1_month');
  const [spaceClassify, setSpaceClassifyState] = useState(false);

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const w = await invoke('get_processing_window');
        if (active && w) setWindowState(w);
        const p = await invoke('triage_progress');
        if (active && p) setProgress(typeof p === 'string' ? JSON.parse(p) : p);
        const sc = await invoke('get_space_classify_enabled');
        if (active) setSpaceClassifyState(!!sc);
      } catch (e) {
        log.warn('useTriage', `load failed: ${e?.message || e}`);
      }
    })();
    const off = syncManager.on('triage-progress', (payload) => {
      if (payload) setProgress(payload);
    });
    return () => { active = false; off(); };
  }, []);

  const setWindow = useCallback(async (w) => {
    setWindowState(w); // optimistic
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('set_processing_window', { window: w });
    } catch (e) {
      log.warn('useTriage', `set window failed: ${e?.message || e}`);
    }
  }, []);

  // Toggle the on-device Space classifier. Enabling backfills the in-window
  // backlog (space-only jobs), so the progress bar may start moving again.
  const setSpaceClassify = useCallback(async (on) => {
    setSpaceClassifyState(on); // optimistic
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('set_space_classify_enabled', { enabled: on });
    } catch (e) {
      log.warn('useTriage', `set space classify failed: ${e?.message || e}`);
    }
  }, []);

  // Re-read the snapshot (e.g. `jevStatus` right after the Jev key changes).
  const refreshProgress = useCallback(async () => {
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      const p = await invoke('triage_progress');
      if (p) setProgress(typeof p === 'string' ? JSON.parse(p) : p);
    } catch (e) {
      log.warn('useTriage', `progress refresh failed: ${e?.message || e}`);
    }
  }, []);

  return { progress, window, setWindow, spaceClassify, setSpaceClassify, refreshProgress };
}

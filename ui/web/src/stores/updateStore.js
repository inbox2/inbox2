import { create } from 'zustand';
import { installUpdate } from '../lib/updater';
import log from '../lib/log';

/**
 * UpdateStore — a newer desktop build is published.
 *
 * Fed by the Rust updater's poll (lib/updater.js → `found`). While `update` is
 * set the bell in the chrome wears an "Update" tag and the notification panel
 * shows the row that takes it; `install` downloads, installs and relaunches.
 */
const useUpdateStore = create((set, get) => ({
  update: null,    // { version, current_version, notes, date } or null
  busy: false,     // downloading / installing
  progress: null,  // 0..1 while busy (null = server sent no length)
  deferred: false, // deb/rpm: the installer prompt took over, we stay running
  error: '',

  found: (info) => set((s) => (
    s.busy || !info?.version || s.update?.version === info.version ? {} : { update: info, error: '' }
  )),

  install: async () => {
    if (!get().update || get().busy) return;
    set({ busy: true, progress: null, error: '', deferred: false });
    try {
      await installUpdate(({ downloaded, content_length }) => {
        set({ progress: content_length ? Math.min(1, downloaded / content_length) : null });
      });
      // Reached only when the install defers to a privileged prompt (deb/rpm);
      // macOS/Windows/AppImage relaunch before this resolves.
      set({ busy: false, deferred: true });
    } catch (err) {
      log.error('updater', 'install failed', err);
      set({ busy: false, progress: null, error: String(err?.message || err) });
    }
  },
}));

export default useUpdateStore;

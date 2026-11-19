// Drag a real file out of the window into Finder / Mail / other apps
// (tauri-plugin-drag, desktop only). macOS starts a drag only inside the mouse
// event, so nothing may be awaited once it begins: `prepareFile` finds the file
// ahead (on hover), and `dragFile` starts the drag on `dragstart` if it's there.
// A lookup that finds nothing isn't remembered, so the next hover looks again.
import { invoke } from '@tauri-apps/api/core';
import { startDrag } from '@crabnebula/tauri-plugin-drag';
import { isTauri } from './tauri';
import log from './log';

let icon = null; // the fallback drag icon's path (or the promise of it)
const files = new Map(); // key → absolute path, or the promise of one

/** Make (once) the file to drag for `key`; `make()` resolves to its absolute path. */
export function prepareFile(key, make) {
  if (!isTauri() || files.has(key)) return;
  if (!icon) icon = invoke('drag_fallback_icon').then((p) => { icon = p; return p; }).catch(() => { icon = null; });
  files.set(key, make()
    .then((p) => { if (p) files.set(key, p); else files.delete(key); return p; })
    .catch((e) => { files.delete(key); log.info('Drag', `preparing ${key} failed: ${e?.message || e}`); }));
}

/** On `dragstart`: drag the prepared file (`picture`: an image of it, else the app icon). → whether it started. */
export function dragFile(e, key, picture = null) {
  e.preventDefault();
  const path = files.get(key);
  if (typeof path !== 'string') return false;
  startDrag({ item: [path], icon: picture || (typeof icon === 'string' ? icon : path) }).catch(() => {});
  return true;
}

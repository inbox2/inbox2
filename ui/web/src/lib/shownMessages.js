// Messages the user chose to show images for, remembered so re-opening the same
// message shows them again without another click. Keyed by message id. A
// per-client view preference (like safeSenders), persisted in localStorage.
import { SHOWN_MESSAGES } from './storageKeys';

function load() {
  try {
    return new Set(JSON.parse(localStorage.getItem(SHOWN_MESSAGES) || '[]'));
  } catch {
    return new Set();
  }
}

let _ids = load();

export function isShownMessage(id) {
  return !!id && _ids.has(id);
}

export function markShownMessage(id) {
  if (!id || _ids.has(id)) return;
  _ids.add(id);
  // Cap the set so it can't grow unbounded; keep the most recent ~1000.
  if (_ids.size > 1000) _ids = new Set([..._ids].slice(-1000));
  localStorage.setItem(SHOWN_MESSAGES, JSON.stringify([..._ids]));
}

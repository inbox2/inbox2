// Trusted senders whose remote images load directly without the "Show images"
// prompt. A persisted set of lowercased email addresses, populated from the
// banner's "Always show from this sender" action.
import { SAFE_SENDERS } from './storageKeys';

function load() {
  try {
    return new Set(JSON.parse(localStorage.getItem(SAFE_SENDERS) || '[]'));
  } catch {
    return new Set();
  }
}

let _senders = load();

function persist() {
  localStorage.setItem(SAFE_SENDERS, JSON.stringify([..._senders]));
}

export function isSafeSender(email) {
  return !!email && _senders.has(email.trim().toLowerCase());
}

export function addSafeSender(email) {
  const e = email?.trim().toLowerCase();
  if (!e || _senders.has(e)) return;
  _senders.add(e);
  persist();
}

export function removeSafeSender(email) {
  const e = email?.trim().toLowerCase();
  if (!e || !_senders.delete(e)) return;
  persist();
}

export function getSafeSenders() {
  return [..._senders];
}

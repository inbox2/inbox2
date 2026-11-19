// Persisted account/tab order — the full key list (MX domain ids + external
// acc_ keys) as last arranged by drag & drop in the account switcher or the
// chrome tab strip. useAccounts sorts the merged list by it, so MX and external
// accounts interleave freely. Keys not in the list (new accounts) keep their
// natural composition order at the end.
import { useSyncExternalStore } from 'react';
import { createExternalStore } from './prefStore';
import { ACCOUNT_ORDER } from './storageKeys';

function read() {
  try { return JSON.parse(localStorage.getItem(ACCOUNT_ORDER)) || []; } catch { return []; }
}

let order = read();
const store = createExternalStore(() => order);

export function setAccountOrder(keys) {
  order = keys;
  localStorage.setItem(ACCOUNT_ORDER, JSON.stringify(keys));
  store.emit();
}

export default function useAccountOrder() {
  return useSyncExternalStore(store.subscribe, store.getSnapshot);
}

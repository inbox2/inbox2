// Sound preferences — a master enable plus the chosen sound for receiving and
// sending mail. A small external store (like markReadPref/notificationPref) so
// playback paths can read the current value synchronously via getSoundPref(),
// while the settings panel stays reactive through useSoundPref().
import { useSyncExternalStore, useCallback } from 'react';
import { SOUNDS_ENABLED, SOUND_RECEIVE, SOUND_SEND } from './storageKeys';
import {
  RECEIVE_SOUNDS, SEND_SOUNDS, DEFAULT_RECEIVE_SOUND, DEFAULT_SEND_SOUND,
} from './soundCatalog';
import { createExternalStore, readBool } from './prefStore';

function readId(key, valid, fallback) {
  const v = localStorage.getItem(key);
  return v && valid.has(v) ? v : fallback;
}

const RECEIVE_IDS = new Set(RECEIVE_SOUNDS.map((s) => s.id));
const SEND_IDS = new Set(SEND_SOUNDS.map((s) => s.id));

let _enabled = readBool(SOUNDS_ENABLED, true);
let _receive = readId(SOUND_RECEIVE, RECEIVE_IDS, DEFAULT_RECEIVE_SOUND);
let _send = readId(SOUND_SEND, SEND_IDS, DEFAULT_SEND_SOUND);

const _store = createExternalStore(() => ({
  enabled: _enabled,
  receive: _receive,
  send: _send,
}));
export const getSoundPref = _store.getSnapshot;

export function setSoundsEnabled(value) {
  const v = !!value;
  if (v === _enabled) return;
  _enabled = v;
  localStorage.setItem(SOUNDS_ENABLED, String(v));
  _store.emit();
}

export function setReceiveSound(id) {
  const v = RECEIVE_IDS.has(id) ? id : DEFAULT_RECEIVE_SOUND;
  if (v === _receive) return;
  _receive = v;
  localStorage.setItem(SOUND_RECEIVE, v);
  _store.emit();
}

export function setSendSound(id) {
  const v = SEND_IDS.has(id) ? id : DEFAULT_SEND_SOUND;
  if (v === _send) return;
  _send = v;
  localStorage.setItem(SOUND_SEND, v);
  _store.emit();
}

export default function useSoundPref() {
  const { enabled, receive, send } = useSyncExternalStore(_store.subscribe, _store.getSnapshot);
  return {
    enabled,
    receive,
    send,
    setEnabled: useCallback((v) => setSoundsEnabled(v), []),
    setReceive: useCallback((v) => setReceiveSound(v), []),
    setSend: useCallback((v) => setSendSound(v), []),
  };
}

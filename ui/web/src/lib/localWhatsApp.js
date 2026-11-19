// Local WhatsApp (desktop, macOS): reads WhatsApp Desktop's own database on
// this Mac, live and read-only — nothing is copied into inbox2. The Rust side is
// ui/desktop/src-tauri/src/whatsapp.rs; media and avatars come through its
// `wamedia://` protocol. Replying and marking read go through WhatsApp Desktop
// itself (whatsapp_actions.rs), opt-in, behind macOS Accessibility.
import { useSyncExternalStore } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { createBoolPref, createExternalStore } from './prefStore';
import { LOCAL_WHATSAPP_ENABLED } from './storageKeys';
import { isTauri } from './tauri';
import { isDemoMode } from './demoData';
import {
  demoWaStatus, demoWaChats, demoWaMessages, demoWaSearch, demoWaChatMedia,
} from './demoWhatsApp';

// Demo mode (lib/demoData.js): every read below answers from a fictional set of
// chats (lib/demoWhatsApp.js) and nothing is written or sent, so a screenshot
// or a live demo never shows — or touches — a real chat.
const demo = () => isDemoMode();
const demoOk = (value) => Promise.resolve(value);

// The search-results column key and the tab's route.
export const WA_LOCAL_KEY = 'whatsapp-local';
export const WA_PATH = 'whatsapp';

// WhatsApp's own ZMESSAGETYPE values that render as something other than text.
export const WA_KIND = {
  TEXT: 0, IMAGE: 1, VIDEO: 2, AUDIO: 3, CONTACT: 4, LOCATION: 5, SYSTEM: 6,
  LINK: 7, DOCUMENT: 8, CALL: 10, GIF: 11, DELETED: 14, STICKER: 15, POLL: 46, POLL_V2: 66,
};

const pref = createBoolPref(LOCAL_WHATSAPP_ENABLED, { defaultValue: false });
// The desktop's WhatsApp Lore worker runs only while this is on, so the engine
// gets told too (whatsapp_lore.rs ENABLED_KEY).
const tellEngine = (on) => invoke('wa_lore_set_enabled', { on });
/**
 * Switch local WhatsApp on or off. The engine is told first and the switch
 * only flips once it has agreed — "off" must mean the Lore worker stopped
 * reading chats. Rejects (switch unchanged) when the engine didn't take it.
 */
export async function setLocalWhatsAppEnabled(on) {
  if (isTauri()) await tellEngine(!!on);
  pref.setEnabled(on);
}
// On launch, bring the engine's setting in line with the switch (it may have
// missed a change, or kept one from before this setting existed). Demo mode
// pauses the Lore worker — no real chat is read or sent to a model during a
// demo — and leaving it (a reload) restores the switch's setting. The main
// window decides: the tray and notification windows have their own
// sessionStorage, so their demo flag isn't this one.
function reconcileEngine() {
  if (!isTauri()) return;
  import('@tauri-apps/api/window')
    .then(({ getCurrentWindow }) => {
      if (getCurrentWindow().label !== 'main') return;
      return tellEngine(pref.getPref().enabled && !isDemoMode());
    })
    .catch(() => {});
}
reconcileEngine();
// Demo mode shows the (fictional) WhatsApp tab on any desktop, for screenshots.
export const getLocalWhatsAppEnabled = () => isTauri() && (pref.getPref().enabled || demo());
export const useLocalWhatsAppEnabled = () => {
  const { enabled } = pref.usePref();
  return isTauri() && (enabled || demo());
};
/** The switch itself, demo mode aside — what the settings control shows. */
export const useLocalWhatsAppSwitch = () => {
  const { enabled } = pref.usePref();
  return isTauri() && enabled;
};

export const waStatus = () => (demo() ? demoOk(demoWaStatus()) : invoke('wa_status'));
export const waChats = () => (demo() ? demoOk(demoWaChats()) : invoke('wa_chats'));
export const waMessages = (chatId, { before = null, around = null, limit = 200 } = {}) =>
  (demo() ? demoOk(before ? { messages: [], has_earlier: false } : demoWaMessages(chatId)) : invoke('wa_messages', { chatId, before, around, limit }));
export const waSearch = (query, limit = 100) => (demo() ? demoOk(demoWaSearch(query).slice(0, limit)) : invoke('wa_search', { query, limit }));
export const waOpenMedia = (path) => (demo() ? demoOk(null) : invoke('wa_open_media', { path }));
export const waOpenPrivacySettings = () => invoke('wa_open_privacy_settings');

// whatsapp.rs NO_ACCESS: macOS refused the read until Inbox2 has Full Disk Access.
const NO_ACCESS = 'no_access: ';
export const isNoAccess = (error) => String(error || '').startsWith(NO_ACCESS);
export const waErrorText = (error) => String(error || '').replace(NO_ACCESS, '').replace(/^no_ax: /, '');

// ── Media: the viewer's gallery, saving, Finder ──────────────────────────────
export const waChatMedia = (chatId) => (demo() ? demoOk(demoWaChatMedia(chatId)) : invoke('wa_chat_media', { chatId }));
/** Copy an attachment out: to ~/Downloads, or (ask) where the person picks. → saved path | null. */
export const waSaveMedia = (path, name, ask = false) => (demo() ? demoOk(null) : invoke('wa_save_media', { path, name, ask }));
export const waRevealMedia = (path) => (demo() ? demoOk(null) : invoke('wa_reveal_media', { path }));

// ── Acting through WhatsApp Desktop (whatsapp_actions.rs) ────────────────────
// Sending needs Accessibility: macOS is asked on the first send, nowhere else.
/** → `{ trusted, running }`: may Inbox2 use Accessibility, is WhatsApp running. */
export const waActionsStatus = () => (demo() ? demoOk({ trusted: true, running: true }) : invoke('wa_actions_status'));
/** Shows macOS's own Accessibility prompt (once) → trusted now? */
export const waRequestAccessibility = () => invoke('wa_request_accessibility');
export const waOpenAccessibilitySettings = () => invoke('wa_open_accessibility_settings');
// Demo mode: nothing reaches WhatsApp (a demo send just "lands").
export const waOpenInWhatsApp = (chatId) => (demo() ? demoOk(null) : invoke('wa_open_in_whatsapp', { chatId }));
/** Attachments first (one message each), then the text. Resolves once WhatsApp's database shows them. */
export const waSend = (chatId, text, files = []) => (demo() ? demoOk(null) : invoke('wa_send', { chatId, text, files }));
export const waPickFiles = () => invoke('wa_pick_files');
// whatsapp_actions.rs NO_AX: Inbox2 isn't allowed Accessibility yet.
export const isNoAx = (error) => String(error || '').startsWith('no_ax: ');

export const waLoreSetDone = (chatId, done) => (demo() ? demoOk(null) : invoke('wa_lore_set_done', { chatId, done }));
// Tracked groups (whatsapp_groups.rs): tick a group to-do; track a group or stop.
export const waGroupTodoSetDone = (id, done) => (demo() ? demoOk(null) : invoke('wa_group_todo_set_done', { id, done }));
export const waGroupSetTracked = (chatId, chatName, on) => (demo() ? demoOk(null) : invoke('wa_group_set_tracked', { chatId, chatName, on }));
export const waGroupSetIgnored = (chatId, chatName, on) => (demo() ? demoOk(null) : invoke('wa_group_set_ignored', { chatId, chatName, on }));
/** One day of a group, summarised (cached per day) → { summary: '- …\n- …', messages }. `fromMs`/`toMs` = the local day's bounds. */
export const waGroupDaySummary = (chatId, chatName, day, fromMs, toMs) =>
  (demo() ? demoOk({ summary: '', messages: 0 }) : invoke('wa_group_day_summary', { chatId, chatName, day, fromMs, toMs }));

/** The WhatsApp tab at a chat, scrolled to a message (a Lore item, a search hit). */
export const waChatPath = (chatId, msgId = null) =>
  `/${WA_PATH}?chat=${chatId}${msgId ? `&msg=${msgId}` : ''}`;

// A container-relative path → a URL the webview can load. An absolute path is
// the app's own (demo mode's photos under public/images) and passes through.
export const waMediaUrl = (rel) => {
  if (!rel) return null;
  if (rel.startsWith('/')) return rel;
  return `wamedia://localhost/${rel.split('/').map(encodeURIComponent).join('/')}`;
};

// ── Live status: one shared poll of the cheap change marker ──────────────────
// Every view that shows WhatsApp data (tab badge, chat list, open thread) reads
// this; `head` moves whenever a message lands, which is their cue to reload.
// ponytail: 4s poll of max(Z_PK); a file watcher on the WAL if that's ever too slow.
const POLL_MS = 4000;
let status = { available: false, error: null, head: 0, unread: 0, version: '', loaded: false };
const store = createExternalStore(() => status);
let timer = null;
let users = 0;

async function poll() {
  try {
    const next = await waStatus();
    if (next.version !== status.version || next.unread !== status.unread || next.available !== status.available || !status.loaded) {
      status = { ...next, loaded: true };
      store.emit();
    }
  } catch (e) {
    status = { available: false, error: String(e?.message || e), head: 0, unread: 0, version: '', loaded: true };
    store.emit();
  }
}

function subscribe(cb) {
  const off = store.subscribe(cb);
  if (users++ === 0) {
    poll();
    timer = setInterval(poll, POLL_MS);
  }
  return () => {
    off();
    if (--users === 0) { clearInterval(timer); timer = null; }
  };
}

/** Something just changed in WhatsApp (a chat read here): poll now, not in up to 4s. */
export const waPollNow = () => { if (users) poll(); };

const idle = { available: false, error: null, head: 0, unread: 0, version: '', loaded: false };
const noop = () => () => {};

/** Live `{ available, error, head, unread, version, loaded }`; idle unless the pref is on.
 *  Reload on `version`: it moves on new messages AND on edits, archiving, unread changes. */
export function useWaStatus() {
  const enabled = useLocalWhatsAppEnabled();
  return useSyncExternalStore(enabled ? subscribe : noop, enabled ? store.getSnapshot : () => idle);
}

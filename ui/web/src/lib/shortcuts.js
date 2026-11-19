// spec 12.1.5 / F4.4 — Keyboard shortcuts registry (single source of truth).
//
// This registry drives three things at once:
//   1. The keydown dispatcher (useMessageActionShortcuts) — via `MESSAGE_SHORTCUTS` + `matchShortcut`.
//   2. The hint shown in every action menu (conversationActions.js) — via `shortcutHint`.
//   3. The `?` help overlay (ShortcutsHelp) — via `SHORTCUTS` grouped by `category`.
//
// See docs/Keyboard-Shortcuts.md for the full reference and how to add a shortcut.
import { QUADRANTS, QUADRANT_ORDER } from './priority';
import { getOS } from './tauri';

// ── Matcher helpers ──
// A shortcut only fires when no foreign modifier is held. `bare` keys forbid every
// modifier; shift/alt variants forbid the others. Alt combos key off `event.code`
// (physical key) because macOS Option emits special characters in `event.key`.
const bareKey = (k) => (e) => !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && e.key === k;
const shiftKey = (k) => (e) => e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && e.key === k;
const altCode = (code) => (e) => e.altKey && !e.metaKey && !e.ctrlKey && e.code === code;

const CATEGORY = {
  MESSAGE: 'Message',
  TRIAGE: 'Triage',
  NAVIGATION: 'Navigation',
  GLOBAL: 'Global',
};

// ── Triage entries derived from the Eisenhower quadrants (no duplicated enums) ──
const ALT_CODE_BY_QUADRANT = {
  DO_FIRST: 'KeyP',
  DELEGATE: 'KeyD',
  SCHEDULE: 'KeyS',
  LATER: 'KeyL',
};
const ALT_DISPLAY_BY_QUADRANT = {
  DO_FIRST: '⌥P',
  DELEGATE: '⌥D',
  SCHEDULE: '⌥S',
  LATER: '⌥L',
};

const triageShortcuts = [
  ...QUADRANT_ORDER.map((key) => ({
    id: `triage_${key}`,
    display: ALT_DISPLAY_BY_QUADRANT[key],
    label: QUADRANTS[key].label,
    icon: QUADRANTS[key].icon,
    category: CATEGORY.TRIAGE,
    scope: 'message',
    match: altCode(ALT_CODE_BY_QUADRANT[key]),
  })),
  {
    id: 'triage_clear',
    display: '⌥X',
    label: 'Untag',
    icon: 'tag.slash',
    category: CATEGORY.TRIAGE,
    scope: 'message',
    match: altCode('KeyX'),
  },
];

// ── The registry ──
// `scope: 'message'` entries with a `match` are dispatched by useMessageActionShortcuts.
// `scope: 'doc'` entries are reference-only (handled elsewhere) and appear in the overlay.
const SHORTCUTS = [
  // Message actions
  { id: 'reply', display: 'R', label: 'Reply', category: CATEGORY.MESSAGE, scope: 'message', match: bareKey('r') },
  { id: 'reply-all', display: 'A', label: 'Reply all', category: CATEGORY.MESSAGE, scope: 'message', match: bareKey('a') },
  { id: 'forward', display: 'F', label: 'Forward', category: CATEGORY.MESSAGE, scope: 'message', match: bareKey('f') },
  { id: 'mark_read', display: '⇧I', label: 'Mark read', category: CATEGORY.MESSAGE, scope: 'message', match: shiftKey('I') },
  { id: 'mark_unread', display: '⇧U', label: 'Mark unread', category: CATEGORY.MESSAGE, scope: 'message', match: shiftKey('U') },
  { id: 'archive', display: 'E', label: 'Archive', category: CATEGORY.MESSAGE, scope: 'message', match: bareKey('e') },
  { id: 'spam', display: '!', label: 'Spam', category: CATEGORY.MESSAGE, scope: 'message', match: (e) => !e.metaKey && !e.ctrlKey && !e.altKey && e.key === '!' },
  // Delete (trash) is handled by useInboxKeyboardNav (Backspace/Delete) — reference only here.
  { id: 'trash', display: '⌫', label: 'Delete', category: CATEGORY.MESSAGE, scope: 'doc' },

  // Triage
  ...triageShortcuts,

  // Navigation (handled by useInboxKeyboardNav — reference only)
  { id: 'next', display: 'J', label: 'Next conversation', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'prev', display: 'K', label: 'Previous conversation', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'open', display: '→', label: 'Open the conversation', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'back', display: 'Esc', label: 'Back / clear selection', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'view_toggle', display: '⌘/', label: 'Toggle list / grid view', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'unread_toggle', display: '⌘U', label: 'Show only unread', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'nav_back', display: '⌘←', label: 'Back', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'nav_forward', display: '⌘→', label: 'Forward', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'channel_prev', display: '⌘[', label: 'Previous channel tab', category: CATEGORY.NAVIGATION, scope: 'doc' },
  { id: 'channel_next', display: '⌘]', label: 'Next channel tab', category: CATEGORY.NAVIGATION, scope: 'doc' },

  // Global (handled elsewhere — reference only)
  { id: 'undo', display: '⌘Z', label: 'Undo last action', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'redo', display: '⌘Y', label: 'Redo', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'compose', display: '⌘C', label: 'Compose', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'sync', display: '⌘S', label: 'Check for new mail', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'settings', display: '⌘,', label: 'Settings', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'search', display: '/', label: 'Search', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'search_focus', display: '⌘K', label: 'Focus global search', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'palette', display: '⌘P', label: 'Command palette', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'demo', display: '⇧⌘D', label: 'Demo data on / off', category: CATEGORY.GLOBAL, scope: 'doc' },
  { id: 'help', display: '?', label: 'Keyboard shortcuts', category: CATEGORY.GLOBAL, scope: 'doc' },
];

// Message-scope shortcuts that have a live matcher (the dispatchable set).
const MESSAGE_SHORTCUTS = SHORTCUTS.filter((s) => s.scope === 'message' && typeof s.match === 'function');

// id → display string, for menu hints.
const DISPLAY_BY_ID = new Map(SHORTCUTS.map((s) => [s.id, s.display]));

/** Resolve a KeyboardEvent to a dispatchable message-action id, or null. */
export function matchShortcut(event) {
  for (const s of MESSAGE_SHORTCUTS) {
    if (s.match(event)) return s.id;
  }
  return null;
}

// ── Platform-aware glyph rendering ──
// The registry stores Mac glyphs (⌘ ⌥ ⇧ ⌃) as the canonical form. The keydown
// dispatchers already match cross-platform (metaKey || ctrlKey, event.code for
// Alt), so only what we *display* needs adapting: on a PC keyboard ⌘K should read
// "Ctrl+K", not show a Command glyph the user has no key for.
const IS_MAC = getOS() === 'macos';

const GLYPH_TO_PC = { '⌘': 'Ctrl+', '⌃': 'Ctrl+', '⌥': 'Alt+', '⇧': 'Shift+' };
const GLYPH_RE = /[⌘⌃⌥⇧]/g;

/** Render a shortcut display string for the current platform (no-op on macOS). */
export function formatShortcut(display) {
  if (!display || IS_MAC) return display;
  return display.replace(GLYPH_RE, (g) => GLYPH_TO_PC[g] || g);
}

/** Display string (e.g. "⇧I" / "Shift+I") for an action id, or '' if none. */
export function shortcutHint(id) {
  return formatShortcut(DISPLAY_BY_ID.get(id) ?? '');
}

/**
 * Tooltip / title text for a control that has a shortcut: "Settings (⌘,)".
 * Every hover label goes through here so the glyph never gets typed by hand —
 * changing a binding in the registry above updates every surface at once.
 * Unknown id → the plain text, so a control without a binding still reads fine.
 */
export function withShortcut(text, id) {
  const hint = shortcutHint(id);
  return hint ? `${text} (${hint})` : text;
}

/** Ordered category list for grouping in the help overlay. */
export const CATEGORY_ORDER = [CATEGORY.MESSAGE, CATEGORY.TRIAGE, CATEGORY.NAVIGATION, CATEGORY.GLOBAL];

export { SHORTCUTS, MESSAGE_SHORTCUTS, CATEGORY };
export default SHORTCUTS;

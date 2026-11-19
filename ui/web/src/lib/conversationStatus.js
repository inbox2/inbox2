// Conversation lifecycle status — the single source for these string values on
// the frontend (mirrors the desktop engine's ConversationStatus). Never inline
// 'archived' / 'spam' / 'trash' as raw literals; reference these instead so the
// inbox/label/unified queries can't drift apart (they did — archived once
// leaked into label views because one query's filter was missing it).

export const CONV_STATUS = {
  OPEN: 'open',
  PENDING: 'pending', // MX only (Conversation::STATUS_PENDING)
  ARCHIVED: 'archived',
  SPAM: 'spam',
  TRASH: 'trash',
};

// Hidden from the inbox and unified list: deleted, junk, or archived.
export const INBOX_HIDDEN_STATUSES = [CONV_STATUS.TRASH, CONV_STATUS.SPAM, CONV_STATUS.ARCHIVED];

// "Not real mail" — deleted or junk. Archived still counts (e.g. for contact
// suggestions and the relationship graph, which include archived threads).
export const DISCARDED_STATUSES = [CONV_STATUS.TRASH, CONV_STATUS.SPAM];

// Every status that is still real mail — the Spaces board's "All items" view.
export const KEPT_STATUSES = [CONV_STATUS.OPEN, CONV_STATUS.PENDING, CONV_STATUS.ARCHIVED];

// Human folder label for a conversation whose status places it outside the
// inbox — used to tag cross-folder search results (Gmail-style "this hit lives
// in Archive/Spam/Trash"). Returns null for `open` (it IS the inbox), so callers
// only badge results that aren't where you're searching from.
export function statusFolderLabel(status) {
  switch (status) {
    case CONV_STATUS.ARCHIVED: return 'Archive';
    case CONV_STATUS.SPAM: return 'Spam';
    case CONV_STATUS.TRASH: return 'Trash';
    default: return null;
  }
}

// Build a `<col> NOT IN ('a', 'b', …)` SQL fragment from a status list. Values
// are fixed constants from this module (never user input), so interpolation is
// safe. `col` lets callers qualify with a table alias, e.g. 'c.status'.
export function statusNotIn(statuses, col = 'status') {
  return `${col} NOT IN (${statuses.map(s => `'${s}'`).join(', ')})`;
}

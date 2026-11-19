/**
 * Centralized conversation action definitions.
 * Every context menu, toolbar, and action menu in the app should
 * reference these builders so action order and icons stay consistent.
 *
 * Shared action order (all menus):
 *   Reply / Reply All / Forward
 *   ──────────────────────────
 *   (message-only: Show Details, View Source)
 *   ──────────────────────────
 *   Mark as Read/Unread
 *   Archive
 *   Spam
 *   Delete
 *   ──────────────────────────
 *   Triage ▸
 */
import { QUADRANTS, QUADRANT_ORDER } from './priority';
import { CONV_STATUS } from './conversationStatus';
import { FOLDER_ROLE } from './folderRoles';
import { shortcutHint } from './shortcuts';
import log from './log';
import useUndoStore from '../stores/undoStore';

// ── Action verbs (single source) ──
// The provider-action verbs the UI dispatches. Centralized so callers don't
// scatter raw 'archive'/'trash'/'mark_read' literals (the no-duplicated-enums
// rule), and so the removal set / reverse verbs / undo labels stay in sync.
export const CONV_ACTION = {
  ARCHIVE: 'archive',
  TRASH: 'trash',
  SPAM: 'spam',
  MARK_READ: 'mark_read',
  MARK_UNREAD: 'mark_unread',
  UNARCHIVE: 'unarchive',
  UNTRASH: 'untrash',
  UNSPAM: 'unspam',
  // UI-level action: restore a conversation from spam/trash/archived back to the
  // inbox. The dispatcher resolves it to 'open' (org) or the matching un-* verb
  // (external) based on the conversation's current status.
  MOVE_TO_INBOX: 'move_to_inbox',
  // Lore's per-member tick on a shared domain: the thread stays put for everyone
  // else, so these are not removals and never move the unread badge.
  LORE_DONE: 'lore_done',
  LORE_UNDONE: 'lore_undone',
};

// Statuses a conversation can be restored to the inbox from (the spam/trash/
// archived folders show a "Move to Inbox" action).
export const RESTORABLE_STATUSES = [CONV_STATUS.ARCHIVED, CONV_STATUS.SPAM, CONV_STATUS.TRASH];

// The forward removal action that put a conversation into a given status — used
// to reverse it (external un-* verb) and to re-apply on undo of a restore.
export const STATUS_FORWARD_ACTION = {
  [CONV_STATUS.ARCHIVED]: CONV_ACTION.ARCHIVE,
  [CONV_STATUS.SPAM]: CONV_ACTION.SPAM,
  [CONV_STATUS.TRASH]: CONV_ACTION.TRASH,
};

// Actions that remove a conversation from the inbox list (and are undoable).
export const REMOVAL_ACTIONS = [CONV_ACTION.ARCHIVE, CONV_ACTION.TRASH, CONV_ACTION.SPAM];

// Reverse verb to restore a removed conversation (undo of a removal).
export const REVERSE_VERB = {
  [CONV_ACTION.ARCHIVE]: CONV_ACTION.UNARCHIVE,
  [CONV_ACTION.TRASH]: CONV_ACTION.UNTRASH,
  [CONV_ACTION.SPAM]: CONV_ACTION.UNSPAM,
  [CONV_ACTION.LORE_DONE]: CONV_ACTION.LORE_UNDONE,
};

// Past-tense label for undo toasts.
export const REMOVAL_PAST_TENSE = {
  [CONV_ACTION.ARCHIVE]: 'Archived',
  [CONV_ACTION.TRASH]: 'Deleted',
  [CONV_ACTION.SPAM]: 'Marked as spam',
  [CONV_ACTION.LORE_DONE]: 'Marked done',
};

// How an action moves the unread badge for a thread whose current state is
// `unread`. Removal takes it out of the inbox the badge counts; mark read/unread
// flips the flag; a restore puts an unread thread back into the pool. Triage and
// priority leave the thread unread and in the inbox, so they must return 0.
//
// `inInbox` — is this thread currently in the pool the badge counts? Acting on a
// thread you're looking at in Spam/Trash/Archive must NOT move the inbox badge:
// deleting a spam thread clears nothing from the inbox, while moving it back to
// the inbox adds to it. Judge this by the FOLDER in view, not the row's status:
// a Gmail thread can sit in the inbox with a conversation status of 'archived'.
//
// The single source for every optimistic badge move — the inbox views, search,
// the Spaces dashboard and the notification popup all apply it. The truth is
// recounted separately (useChannelUnreadCounts); this only decides how the
// number moves between recounts.
export function unreadDelta(action, unread, inInbox = true) {
  if (action === CONV_ACTION.MARK_READ) return unread && inInbox ? -1 : 0;
  if (action === CONV_ACTION.MARK_UNREAD) return !unread && inInbox ? 1 : 0;
  if (REMOVAL_ACTIONS.includes(action)) return unread && inInbox ? -1 : 0;
  if (action === CONV_ACTION.LORE_UNDONE) return 0; // the thread never left the inbox
  if (action === CONV_STATUS.OPEN
    || action === CONV_ACTION.MOVE_TO_INBOX
    || Object.values(REVERSE_VERB).includes(action)) return unread && !inInbox ? 1 : 0;
  return 0;
}

// Copy for the toast shown when an action can't reach the server. Keyed by the
// same verbs, including the org path's bare 'open' restore.
export const ACTION_FAILED_LABEL = {
  [CONV_ACTION.ARCHIVE]: "Couldn't archive",
  [CONV_ACTION.TRASH]: "Couldn't delete",
  [CONV_ACTION.SPAM]: "Couldn't mark as spam",
  [CONV_ACTION.MARK_READ]: "Couldn't mark as read",
  [CONV_ACTION.MARK_UNREAD]: "Couldn't mark as unread",
  [CONV_ACTION.UNARCHIVE]: "Couldn't move to Inbox",
  [CONV_ACTION.UNTRASH]: "Couldn't move to Inbox",
  [CONV_ACTION.UNSPAM]: "Couldn't move to Inbox",
  [CONV_STATUS.OPEN]: "Couldn't move to Inbox",
  [CONV_ACTION.LORE_DONE]: "Couldn't mark it done",
  [CONV_ACTION.LORE_UNDONE]: "Couldn't put it back",
};

// Run the server-side half of a conversation action. Returns true if it landed,
// false if it didn't — on false the caller MUST skip its optimistic update and
// its undo entry (or revert, if it already applied one).
//
// Every dispatcher funnels through here because this failure is otherwise
// invisible. localFirstApi used to swallow the error and return `{ success:
// true }` on the theory that the local write + pending_changes queue would
// catch up; neither is true (an MX thread has no local row, and nothing drains
// pending_changes). A 502 on "mark as spam" therefore removed the row, never
// reached the server, and the next poll brought it back. Unlike local channels
// — which have a real durable writeback_actions queue with retry — this path
// has no retry, so the only honest outcomes are "it worked" or "tell the user".
export async function commitAction(action, fn) {
  try {
    await fn();
    return true;
  } catch (e) {
    log.error('ConversationAction', `${action} failed: ${e?.message || e}`);
    useUndoStore.getState().notify({
      description: `${ACTION_FAILED_LABEL[action] || "Couldn't apply that"} . Check your connection and try again.`,
      variant: 'danger',
      icon: 'exclamationmark.triangle',
    });
    return false;
  }
}

// SF Symbol shown in the undo toast's icon badge, per action (single source —
// shares the same glyphs the context/toolbar menus use in coreActions above).
export const ACTION_ICON = {
  [CONV_ACTION.ARCHIVE]: 'archivebox',
  [CONV_ACTION.TRASH]: 'trash',
  [CONV_ACTION.SPAM]: 'nosign',
  [CONV_ACTION.MARK_READ]: 'envelope.open',
  [CONV_ACTION.MARK_UNREAD]: 'envelope.badge',
};

// Classify a folder/view into the well-known mailbox role that governs which
// destructive toolbar actions are redundant there. Returns a CONV_STATUS
// (archived/spam/trash), FOLDER_ROLE.SENT, or null for the inbox / a custom
// view. Covers both org system views (status / direction filters) and external
// account folders (well-known role on the gmail_label filter).
export function viewFolderRole(view) {
  if (!view) return null;
  const filters = view.filters || [];
  const status = filters.find(f => f.field === 'status')?.value;
  if (status === CONV_STATUS.ARCHIVED || view.name === 'Archived') return CONV_STATUS.ARCHIVED;
  if (status === CONV_STATUS.TRASH || view.name === 'Trash') return CONV_STATUS.TRASH;
  if (status === CONV_STATUS.SPAM || view.name === 'Spam') return CONV_STATUS.SPAM;
  if (view.name === 'Sent'
    || filters.some(f => f.wellKnownRole === FOLDER_ROLE.SENT)
    || filters.some(f => f.field === 'direction' && f.value === 'outbound')) {
    return FOLDER_ROLE.SENT;
  }
  return null;
}

// Which destructive toolbar buttons are redundant (so disabled) in a folder:
//   • Archive folder  → Archive is a no-op
//   • Trash folder    → both Archive and Delete are no-ops
//   • Sent folder     → Archive (a sent message lives in the archive already)
export function disabledFolderActions(view) {
  const role = viewFolderRole(view);
  return {
    archive: role === CONV_STATUS.ARCHIVED || role === CONV_STATUS.TRASH || role === FOLDER_ROLE.SENT,
    trash: role === CONV_STATUS.TRASH,
  };
}

// ── Triage submenu builder ──
// `manual` (from useManualTriage) adds Jev's manual triage on top: Move to Space ›,
// Label › (current one checked) and Re-run Jev. Without it (bulk selections,
// the composer) the menu is the Eisenhower quadrants alone.
export function triageSubmenu(convIds, executePriority, { afterAction, manual } = {}) {
  const pick = (fn) => () => { fn(); afterAction?.(); };
  const manualItems = !manual ? [] : [
    ...(manual.spaces?.length ? [{
      value: 'triage_space', icon: 'square.grid.2x2', label: 'Move to Space',
      submenu: manual.spaces.map(s => ({
        value: `triage_space_${s.slug}`, label: s.name, checked: s.slug === manual.currentSpace,
        onSelect: pick(() => manual.moveToSpace(s.slug)),
      })),
    }] : []),
    ...(manual.labels?.length ? [{
      value: 'triage_label', icon: 'tag', label: 'Label',
      submenu: manual.labels.map(l => ({
        value: `triage_label_${l.slug}`, label: l.name || l.slug, checked: l.slug === manual.currentLabel,
        onSelect: pick(() => manual.setLabel(l.slug)),
      })),
    }] : []),
    { value: 'triage_rerun', icon: 'arrow.triangle.2.circlepath', label: 'Re-run Jev', onSelect: pick(manual.rerun) },
    { separator: true },
  ];
  return {
    value: 'triage', icon: 'tag.fill', label: 'Triage',
    submenu: [
      ...manualItems,
      ...QUADRANT_ORDER.map(key => ({
        value: `triage_${key}`,
        icon: QUADRANTS[key].icon,
        label: QUADRANTS[key].label,
        shortcut: shortcutHint(`triage_${key}`),
        onSelect: pick(() => executePriority(convIds, key)),
      })),
      { separator: true },
      { value: 'triage_clear', icon: 'tag.slash', label: 'Untag', shortcut: shortcutHint('triage_clear'), onSelect: pick(() => executePriority(convIds, null)) },
    ],
  };
}

// ── Shared action items (mark, archive, spam, delete, triage) ──
function coreActions(conv, { onMarkReadUnread, onArchive, onSpam, onTrash, executePriority, onMoveToInbox, manualTriage, folderRole }) {
  // In spam/trash/archived, surface "Move to Inbox" at the top and drop the
  // redundant removal item that matches the current folder (no "Spam" in Spam).
  // Which "already there" state governs that is the FOLDER in view, not the row's
  // own status: a Gmail thread can sit in the inbox while its conversation status
  // is 'archived' (mixed inbox/archived messages), and Archive must stay offered
  // on it. Folder-scoped callers pass folderRole; cross-folder ones (search,
  // spaces) pass nothing and fall back to the row's status.
  const where = folderRole !== undefined ? folderRole : conv?.status;
  const restorable = onMoveToInbox && RESTORABLE_STATUSES.includes(where);
  return [
    ...(restorable
      ? [{ value: 'move_to_inbox', icon: 'tray.and.arrow.down', label: 'Move to Inbox', onSelect: onMoveToInbox }, { separator: true }]
      : []),
    { value: 'mark', icon: conv?.read ? 'envelope.badge' : 'envelope.open', label: conv?.read ? 'Mark as unread' : 'Mark as read', shortcut: shortcutHint(conv?.read ? 'mark_unread' : 'mark_read'), onSelect: onMarkReadUnread },
    ...(where === CONV_STATUS.ARCHIVED ? [] : [{ value: 'archive', icon: 'archivebox', label: 'Archive', shortcut: shortcutHint('archive'), onSelect: onArchive }]),
    ...(where === CONV_STATUS.SPAM ? [] : [{ value: 'spam', icon: 'nosign', label: 'Spam', shortcut: shortcutHint('spam'), onSelect: onSpam }]),
    { separator: true },
    triageSubmenu([conv?.id], executePriority, { manual: manualTriage }),
    // Delete is always the last item, styled destructive (red) — shown even for
    // hits already in Trash (a re-trash is a harmless no-op; hiding it reads as
    // a missing option, not a smart menu).
    { separator: true },
    { value: 'trash', icon: 'trash', label: 'Delete', danger: true, shortcut: shortcutHint('trash'), onSelect: onTrash },
  ];
}

// ── Single conversation context menu (right-click on list item) ──
export function conversationContextMenuItems(conv, { onReply, onReplyAll, onForward, onMarkReadUnread, onArchive, onSpam, onTrash, executePriority, onMoveToInbox, manualTriage, folderRole }) {
  return [
    // Reply section only where a composer is reachable (no onReply → surface
    // without a reading pane, e.g. the Spaces dashboard strips).
    ...(onReply ? [
      { value: 'reply', icon: 'arrowshape.turn.up.left', label: 'Reply', shortcut: shortcutHint('reply'), onSelect: onReply },
      { value: 'reply-all', icon: 'arrowshape.turn.up.left.2', label: 'Reply all', shortcut: shortcutHint('reply-all'), onSelect: onReplyAll },
      { value: 'forward', icon: 'arrowshape.turn.up.right', label: 'Forward', shortcut: shortcutHint('forward'), onSelect: onForward },
      { separator: true },
    ] : []),
    ...coreActions(conv, { onMarkReadUnread, onArchive, onSpam, onTrash, executePriority, onMoveToInbox, manualTriage, folderRole }),
  ];
}

// ── Per-message action menu (ellipsis button on a message card) ──
export function messageActionMenuItems(conv, { onReply, onReplyAll, onForward, onDetails, onSource, onExportEml, onMarkReadUnread, onArchive, onSpam, onTrash, executePriority, detailsOpen, onCreateRule, onMoveToInbox, manualTriage, folderRole }) {
  return [
    { value: 'reply', icon: 'arrowshape.turn.up.left', label: 'Reply', shortcut: shortcutHint('reply'), onSelect: onReply },
    { value: 'reply-all', icon: 'arrowshape.turn.up.left.2', label: 'Reply all', shortcut: shortcutHint('reply-all'), onSelect: onReplyAll },
    { value: 'forward', icon: 'arrowshape.turn.up.right', label: 'Forward', shortcut: shortcutHint('forward'), onSelect: onForward },
    { separator: true },
    { value: 'details', icon: 'doc.text.fill', label: detailsOpen ? 'Hide details' : 'Show details', onSelect: onDetails },
    { value: 'source', icon: 'doc', label: 'View source', onSelect: onSource },
    ...(onExportEml ? [{ value: 'export-eml', icon: 'tray.and.arrow.down', label: 'Export as .eml…', onSelect: onExportEml }] : []),
    { separator: true },
    // "Create rule" only appears where a handler is wired (desktop reading pane).
    ...(onCreateRule ? [{ value: 'create_rule', icon: 'arrow.triangle.branch', label: 'Create rule…', onSelect: onCreateRule }, { separator: true }] : []),
    ...coreActions(conv, { onMarkReadUnread, onArchive, onSpam, onTrash, executePriority, onMoveToInbox, manualTriage, folderRole }),
  ];
}

// ── Bulk selection action menu ──
export function bulkActionMenuItems(selectedIds, { hasUnread, onArchive, onSpam, onTrash, onMarkReadUnread, executePriority, afterAction, onMoveToInbox, folderRole }) {
  return [
    // Restorable folder (spam/trash/archived): bulk "Move to Inbox" up top.
    ...(onMoveToInbox
      ? [{ value: 'move_to_inbox', label: 'Move all to Inbox', icon: 'tray.and.arrow.down', onSelect: onMoveToInbox }, { separator: true }]
      : []),
    // Same order as the single-conversation menu: mark, archive, spam … delete last.
    {
      value: 'read',
      label: hasUnread ? 'Mark all as read' : 'Mark all as unread',
      icon: hasUnread ? 'envelope.open' : 'envelope.badge',
      onSelect: onMarkReadUnread,
    },
    ...(folderRole === CONV_STATUS.ARCHIVED ? [] : [{ value: 'archive', label: 'Archive all', icon: 'archivebox.fill', onSelect: onArchive }]),
    // Same "already there" rule as the single-conversation menu: no "Spam" in Spam.
    ...(!onSpam || folderRole === CONV_STATUS.SPAM ? [] : [{ value: 'spam', label: 'Mark all as spam', icon: 'nosign', onSelect: onSpam }]),
    { separator: true },
    triageSubmenu([...selectedIds], executePriority, { afterAction }),
    // Delete is always the last item, styled destructive (red).
    { separator: true },
    { value: 'trash', label: 'Delete all', icon: 'trash', danger: true, onSelect: onTrash },
  ];
}

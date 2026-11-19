// Apply a notification action (Read / Archive / Delete / Triage) via the
// provider layer. Shared by the in-app NewMessagePopup and the standalone Tauri
// notification window (NotificationPage), which had copy-pasted this switch.
//
// `record`, when provided, is the undo-store recorder (receives an entry to
// which the notification key is attached) — the in-app popup records undo for
// archive/trash/triage; the standalone window passes none.
//
// `onUnread(delta)` applies an optimistic unread-badge change. Which actions
// move the badge is decided HERE so both callers agree; only the transport
// differs, because the standalone notification panel is its own Tauri window
// with its own store and has to hand the change to the main window.

import { isTauri } from './tauri.js';
import { QUADRANTS } from './priority.js';
import { CONV_ACTION, ACTION_ICON, unreadDelta, commitAction } from './conversationActions.js';
import { CONV_STATUS } from './conversationStatus.js';
import { PROVIDER } from './providerTypes.js';
import log from './log.js';

// MX mail alerts (Rails' per-user `new_message` cable signal, see pushSync.js)
// carry the org + workspace slug instead of a local account key.
export const isMxAlert = (notif) => notif?.providerType === PROVIDER.INBOX2;

// Where opening a mail alert lands. MX threads open in their domain's own inbox
// (/:domainSlug/mail/inbox), the same target a unified-inbox card click uses.
export function alertMailTarget(notif) {
  return isMxAlert(notif)
    ? { page: 'mail', orgSlug: notif.orgSlug, accountKey: null, conversationId: notif.key, unified: false }
    : { page: 'mail', accountKey: notif.accountKey, conversationId: notif.key };
}

// MX actions go through the same bulk endpoint as the inbox (engine-queued on a
// mirrored desktop, straight to the API in a browser). Triage is not offered on
// MX cards — it is tag-based there and needs the org's tag list.
async function runMxAction(notif, action, { record }) {
  const { default: api } = await import('./localFirstApi.js');
  const org = notif.orgId;
  const keys = [notif.key];
  const run = (verb) => commitAction(verb, () => api.bulkConversations(org, keys, verb));
  if (!await run(action)) return false;
  if (action === CONV_ACTION.ARCHIVE || action === CONV_ACTION.TRASH) {
    record?.({
      key: notif.key,
      description: `${action === CONV_ACTION.ARCHIVE ? 'Archived' : 'Deleted'} "${notif.subject || 'message'}"`,
      variant: action === CONV_ACTION.ARCHIVE ? 'triage' : 'danger',
      icon: ACTION_ICON[action],
      undo: () => run(CONV_STATUS.OPEN),
      redo: () => run(action),
    });
  }
  return true;
}

export async function runNotificationAction(notif, action, quadrantKey, { record, onUnread } = {}) {
  // A demo card is scrubbed but keeps the real thread's key; the standalone
  // window's own demo guards can't see demo mode, so refuse here for both.
  if (notif.demo) {
    log.warn('Notification', `action=${action} refused — demo data is on`);
    return;
  }
  if (isMxAlert(notif)) {
    const ok = await runMxAction(notif, action, { record });
    log.info('Notification', `mx action=${action} ok=${ok} key=${notif.key}`);
    return;
  }
  if (!isTauri()) return;
  // Before the await, not after: the provider write plus the refetch behind it
  // is the two seconds the badge used to spend still counting a thread the user
  // had already dealt with. A notification is raised for a new arrival, so treat
  // it as unread; if it had been read elsewhere, adjust()'s clamp and the next
  // full recount cover the drift.
  const delta = unreadDelta(action, true);
  if (delta) onUnread?.(delta);
  try {
    const { performAction, setPriority, clearPriority } = await import('./providers/index.js');
    const keys = [notif.key];
    const ak = notif.accountKey;
    const subject = notif.subject || notif.title || 'message';
    const rec = (entry) => record?.({ key: notif.key, ...entry });

    switch (action) {
      case CONV_ACTION.MARK_READ:
        await performAction(ak, keys, CONV_ACTION.MARK_READ);
        break;
      case CONV_ACTION.ARCHIVE:
        await performAction(ak, keys, CONV_ACTION.ARCHIVE);
        rec({
          description: `Archived "${subject}"`, variant: 'triage', icon: ACTION_ICON[CONV_ACTION.ARCHIVE],
          undo: () => { onUnread?.(1); return performAction(ak, keys, CONV_ACTION.UNARCHIVE); },
          redo: () => { onUnread?.(-1); return performAction(ak, keys, CONV_ACTION.ARCHIVE); },
        });
        break;
      case CONV_ACTION.TRASH:
        await performAction(ak, keys, CONV_ACTION.TRASH);
        rec({
          description: `Deleted "${subject}"`, variant: 'danger', icon: ACTION_ICON[CONV_ACTION.TRASH],
          undo: () => { onUnread?.(1); return performAction(ak, keys, CONV_ACTION.UNTRASH); },
          redo: () => { onUnread?.(-1); return performAction(ak, keys, CONV_ACTION.TRASH); },
        });
        break;
      case 'triage': {
        const q = QUADRANTS[quadrantKey];
        if (q) {
          await setPriority(ak, keys, q.urgent, q.important);
          rec({
            description: `Moved to ${q.label}`, variant: 'triage', icon: q.icon,
            undo: () => clearPriority(ak, keys),
            redo: () => setPriority(ak, keys, q.urgent, q.important),
          });
        }
        break;
      }
      case 'untriage':
        await clearPriority(ak, keys);
        break;
    }
    log.info('Notification', `action=${action} quadrant=${quadrantKey || '-'} key=${notif.key}`);
  } catch (e) {
    log.warn('Notification', `action failed: ${action}: ${e?.message || e}`);
  }
}

import { useCallback } from 'react';
import api from '../lib/localFirstApi';
import { isRealOrgId } from '../lib/org';
import { QUADRANTS, getConvQuadrant } from '../lib/priority';
import { setMxPriorityTags, clearMxPriorityTags } from '../lib/mxPriority';
import log from '../lib/log';
import useNavigationStore from '../stores/navigationStore';
import useUndoStore from '../stores/undoStore';
import useUnreadStore from '../stores/unreadStore';
import { CONV_STATUS } from '../lib/conversationStatus';
import {
  CONV_ACTION, REVERSE_VERB, REMOVAL_ACTIONS, REMOVAL_PAST_TENSE,
  ACTION_ICON, STATUS_FORWARD_ACTION, commitAction, unreadDelta,
} from '../lib/conversationActions';

export default function useConversationActions({
  activeAccountKey,
  orgId,
  conversations,
  displayedConversations,
  selectedId,
  setConversations,
  setSelectedConv,
  badgeKey,
  inInboxView = true,
  // The desktop reading pane follows the cursor: a removal opens the next thread
  // and undo reopens the restored one. The phone shell (src/mobile/) shows the
  // list between threads, so it turns that off and closes the thread itself.
  followSelection = true,
}) {
  // Move this channel's tab badge the instant the user acts. The truth is
  // recounted by useChannelUnreadCounts (a COUNT query / the API count
  // endpoint), but that's async and event-driven — this is what makes the number
  // move on click. Any drift is reconciled by the next recount.
  //
  // `rows` overrides where the conversations are read from, for restores that
  // act on threads already out of the list (undo holds the snapshots). `inInbox`
  // overrides the folder-in-view rule for those same restores: a thread coming
  // back from spam/trash re-enters the badge's pool no matter what's on screen.
  const moveBadge = useCallback((convIds, action, { rows, inInbox = inInboxView } = {}) => {
    const delta = (rows || conversations)
      .filter(c => convIds.includes(c.id))
      .reduce((n, c) => n + unreadDelta(action, !c.read, inInbox), 0);
    if (delta) useUnreadStore.getState().adjust(badgeKey, delta);
  }, [conversations, badgeKey, inInboxView]);

  const removeAndSelectNext = useCallback((convIds) => {
    // Use the displayed (sorted/filtered) list to find the next visible
    // conversation, so the selection moves exactly one row in the UI.
    const visible = displayedConversations || conversations;
    const idx = visible.findIndex(c => c.id === selectedId);
    const visibleRemaining = visible.filter(c => !convIds.includes(c.id));
    const nextConv = visibleRemaining[Math.min(idx, visibleRemaining.length - 1)] || null;

    setConversations(prev => prev.filter(c => !convIds.includes(c.id)));

    if (followSelection && convIds.includes(selectedId)) {
      setSelectedConv(nextConv);
      useNavigationStore.getState().navigateTo(
        { conversationId: nextConv?.id || null }, { replace: true, replaceStack: true }
      );
    }
  }, [selectedId, conversations, displayedConversations, setConversations, setSelectedConv, followSelection]);

  // Raw forward action — performs the mutation + writeback, no undo recording.
  const runAction = useCallback(async (convIds, action) => {
    if (activeAccountKey) {
      moveBadge(convIds, action);
      // Optimistic in-memory UI update only. Local SQLite persistence is owned
      // by the Rust `perform_conversation_action` command (via performAction),
      // which writes the conversation status/read before the write-back — the
      // single source of truth, so a racing sync re-query can't resurrect it.
      if (action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD) {
        setConversations(prev => prev.map(c =>
          convIds.includes(c.id) ? { ...c, read: action === CONV_ACTION.MARK_READ } : c
        ));
      } else {
        removeAndSelectNext(convIds);
      }

      import('../lib/providers/index.js').then(({ performAction }) =>
        performAction(activeAccountKey, convIds, action)
      ).catch(e => log.warn('Writeback', `Failed: ${e?.message || e}`));
    } else if (isRealOrgId(orgId)) {
      // Applied, or durably queued for retry — either way the optimistic update
      // is honest. Refused outright: leave the list untouched and report false so
      // the caller skips its undo entry (undoing something that never happened
      // would push a bogus command onto the stack).
      if (!await commitAction(action, () => api.bulkConversations(orgId, convIds, action))) return false;
      moveBadge(convIds, action);
      if (REMOVAL_ACTIONS.includes(action)) {
        removeAndSelectNext(convIds);
      } else if (action === CONV_ACTION.MARK_READ) {
        setConversations(prev => prev.map(c => convIds.includes(c.id) ? { ...c, read: true } : c));
      } else if (action === CONV_ACTION.MARK_UNREAD) {
        setConversations(prev => prev.map(c => convIds.includes(c.id) ? { ...c, read: false } : c));
      }
    }
  }, [activeAccountKey, orgId, removeAndSelectNext, setConversations, moveBadge]);

  // Restore archived/trashed/spammed conversations back to the inbox (undo of a removal).
  // `snapshots` are { conv, index } captured before removal so we can re-insert in place.
  const restoreConversations = useCallback(async (snapshots, originalAction) => {
    const ids = snapshots.map(s => s.conv.id);
    if (activeAccountKey) {
      // The reverse verb routes through Rust, which sets the status back to
      // 'open' locally before its write-back (same path as the forward action).
      const reverse = REVERSE_VERB[originalAction];
      if (reverse) {
        import('../lib/providers/index.js').then(({ performAction }) =>
          performAction(activeAccountKey, ids, reverse)
        ).catch(e => log.warn('Writeback', `Restore failed: ${e?.message || e}`));
      }
    } else if (isRealOrgId(orgId)) {
      // Refused: the threads are still where they were, so don't re-insert them
      // into the inbox list — that would show a restore that didn't happen.
      if (!await commitAction(CONV_STATUS.OPEN, () => api.bulkConversations(orgId, ids, CONV_STATUS.OPEN))) return;
    }
    // Back in the pool the badge counts: the threads were filed until now, so
    // this counts as a restore regardless of which folder is on screen.
    moveBadge(ids, REVERSE_VERB[originalAction] || CONV_STATUS.OPEN,
      { rows: snapshots.map(s => s.conv), inInbox: false });
    // Re-insert at original positions (ascending so earlier indices land first).
    setConversations(prev => {
      const next = [...prev];
      for (const { conv, index } of [...snapshots].sort((a, b) => a.index - b.index)) {
        if (next.some(c => c.id === conv.id)) continue;
        next.splice(Math.min(index, next.length), 0, { ...conv, status: CONV_STATUS.OPEN });
      }
      return next;
    });

    // Move the cursor back to the conversation undo just restored.
    const restored = snapshots[0]?.conv;
    if (restored && followSelection) {
      setSelectedConv({ ...restored, status: CONV_STATUS.OPEN });
      useNavigationStore.getState().navigateTo(
        { conversationId: restored.id }, { replace: true, replaceStack: true }
      );
    }
  }, [activeAccountKey, orgId, setConversations, setSelectedConv, moveBadge, followSelection]);

  // Re-apply a removal so a "Move to Inbox" can be undone — sends the conversations
  // back to the spam/trash/archived folder they came from, re-inserts them in
  // place, and restores the cursor (mirrors restoreConversations, reversed).
  const restoreToStatus = useCallback(async (snapshots, fromStatus) => {
    const ids = snapshots.map(s => s.conv.id);
    const forward = STATUS_FORWARD_ACTION[fromStatus];
    if (activeAccountKey) {
      if (forward) {
        import('../lib/providers/index.js').then(({ performAction }) =>
          performAction(activeAccountKey, ids, forward)
        ).catch(e => log.warn('Writeback', `Re-remove failed: ${e?.message || e}`));
      }
    } else if (isRealOrgId(orgId) && forward) {
      if (!await commitAction(forward, () => api.bulkConversations(orgId, ids, forward))) return;
    }
    // Undo of "Move to Inbox": the threads are in the inbox pool right now, and
    // this takes them back out of it.
    moveBadge(ids, forward, { rows: snapshots.map(s => s.conv), inInbox: true });
    setConversations(prev => {
      const next = [...prev];
      for (const { conv, index } of [...snapshots].sort((a, b) => a.index - b.index)) {
        if (next.some(c => c.id === conv.id)) continue;
        next.splice(Math.min(index, next.length), 0, { ...conv, status: fromStatus });
      }
      return next;
    });
    const restored = snapshots[0]?.conv;
    if (restored && followSelection) {
      setSelectedConv({ ...restored, status: fromStatus });
      useNavigationStore.getState().navigateTo(
        { conversationId: restored.id }, { replace: true, replaceStack: true }
      );
    }
  }, [activeAccountKey, orgId, setConversations, setSelectedConv, moveBadge, followSelection]);

  // Raw "move to inbox" — optimistic removal from the current folder list + the
  // restore writeback (un-* verb via Rust, or 'open' for org). No undo recording.
  const runMoveToInbox = useCallback(async (convIds, fromStatus) => {
    // Filed until now, so an unread one re-enters the inbox badge's pool.
    const restoreBadge = () => moveBadge(convIds, CONV_ACTION.MOVE_TO_INBOX, { inInbox: false });
    if (activeAccountKey) {
      // Local channels stay optimistic-first: the Rust write-back queue is
      // durable, so the action cannot be lost even if the provider is offline.
      restoreBadge();
      removeAndSelectNext(convIds);
      const verb = REVERSE_VERB[STATUS_FORWARD_ACTION[fromStatus]];
      if (verb) {
        import('../lib/providers/index.js').then(({ performAction }) =>
          performAction(activeAccountKey, convIds, verb)
        ).catch(e => log.warn('Writeback', `Move to inbox failed: ${e?.message || e}`));
      }
      return;
    }
    if (isRealOrgId(orgId)
      && !await commitAction(CONV_STATUS.OPEN, () => api.bulkConversations(orgId, convIds, CONV_STATUS.OPEN))) {
      return false;
    }
    restoreBadge();
    removeAndSelectNext(convIds);
  }, [activeAccountKey, orgId, removeAndSelectNext, moveBadge]);

  // Restore conversations from spam/trash/archived back to the inbox + record an
  // undo that sends them back to the folder they came from.
  const moveToInbox = useCallback(async (convIds, { record = true } = {}) => {
    const snapshots = convIds
      .map(id => {
        const index = conversations.findIndex(c => c.id === id);
        return index >= 0 ? { conv: conversations[index], index } : null;
      })
      .filter(Boolean);
    const fromStatus = snapshots[0]?.conv?.status;

    if (await runMoveToInbox(convIds, fromStatus) === false) return;

    if (!record) return;

    const subject = snapshots[0]?.conv?.subject || 'conversation';
    useUndoStore.getState().record({
      description: convIds.length > 1 ? `Moved ${convIds.length} conversations to Inbox` : `Moved "${subject}" to Inbox`,
      icon: 'tray.and.arrow.down',
      key: convIds.join(','),
      undo: () => restoreToStatus(snapshots, fromStatus),
      redo: () => runMoveToInbox(convIds, fromStatus),
    });
  }, [conversations, runMoveToInbox, restoreToStatus]);

  const executeAction = useCallback(async (convIds, action, { record = true } = {}) => {
    if (action === CONV_ACTION.MOVE_TO_INBOX) {
      await moveToInbox(convIds, { record });
      return;
    }
    const isRemoval = REMOVAL_ACTIONS.includes(action);
    // Snapshot full objects + index before the forward action mutates the list.
    const snapshots = isRemoval
      ? convIds
          .map(id => {
            const index = conversations.findIndex(c => c.id === id);
            return index >= 0 ? { conv: conversations[index], index } : null;
          })
          .filter(Boolean)
      : [];

    // Only an explicit false means the server refused it; the local-channel
    // branch returns undefined and records undo as before.
    if (await runAction(convIds, action) === false) return;

    if (!record) return;

    if (isRemoval) {
      const subject = snapshots[0]?.conv?.subject || 'conversation';
      const verb = REMOVAL_PAST_TENSE[action];
      useUndoStore.getState().record({
        description: convIds.length > 1 ? `${verb} ${convIds.length} conversations` : `${verb} "${subject}"`,
        variant: action === CONV_ACTION.TRASH ? 'danger' : 'triage',
        icon: ACTION_ICON[action],
        key: convIds.join(','),
        undo: () => restoreConversations(snapshots, action),
        redo: () => runAction(convIds, action),
      });
    } else if (action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD) {
      const opposite = action === CONV_ACTION.MARK_READ ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ;
      useUndoStore.getState().record({
        description: action === CONV_ACTION.MARK_READ ? 'Marked as read' : 'Marked as unread',
        icon: ACTION_ICON[action],
        key: convIds.join(','),
        undo: () => runAction(convIds, opposite),
        redo: () => runAction(convIds, action),
      });
    }
  }, [conversations, runAction, restoreConversations, moveToInbox]);

  // Raw forward priority — optimistic update + writeback, no undo recording.
  const runPriority = useCallback(async (convIds, quadrantKey) => {
    const q = quadrantKey ? QUADRANTS[quadrantKey] : null;
    const urgent = q ? q.urgent : false;
    const important = q ? q.important : false;

    // Optimistic update — show labels immediately
    const uVal = urgent ? 1 : 0;
    const iVal = important ? 1 : 0;
    setConversations(prev => prev.map(c =>
      convIds.includes(c.id)
        ? { ...c, priority_urgent: uVal, priority_important: iVal }
        : c
    ));

    if (activeAccountKey) {
      // Local SQLite persistence is owned by the Rust set_priority/clear_priority
      // commands (set_conversation_priority); the UI update above is optimistic.
      if (quadrantKey) {
        import('../lib/providers/index.js').then(({ setPriority }) =>
          setPriority(activeAccountKey, convIds, urgent, important)
        ).catch(e => log.warn('Priority', `Writeback failed: ${e?.message || e}`));
      } else {
        import('../lib/providers/index.js').then(({ clearPriority }) =>
          clearPriority(activeAccountKey, convIds)
        ).catch(e => log.warn('Priority', `Writeback failed: ${e?.message || e}`));
      }
    } else if (isRealOrgId(orgId)) {
      for (const convId of convIds) {
        const conv = conversations.find(c => c.id === convId) || { id: convId };
        if (quadrantKey) await setMxPriorityTags(orgId, conv, { urgent, important });
        else await clearMxPriorityTags(orgId, conv);
      }
    }
  }, [activeAccountKey, orgId, conversations, setConversations]);

  const executePriority = useCallback(async (convIds, quadrantKey, { record = true } = {}) => {
    // Capture each conversation's prior quadrant so undo can restore per-conversation.
    const prevByConv = new Map(
      convIds.map(id => [id, getConvQuadrant(conversations.find(c => c.id === id) || {})?.key || null])
    );

    await runPriority(convIds, quadrantKey);

    if (!record) return;

    useUndoStore.getState().record({
      description: quadrantKey ? `Moved to ${QUADRANTS[quadrantKey].label}` : 'Removed priority',
      variant: 'triage',
      icon: quadrantKey ? QUADRANTS[quadrantKey].icon : 'tag.slash',
      key: convIds.join(','),
      undo: async () => {
        for (const id of convIds) {
          await runPriority([id], prevByConv.get(id) || null);
        }
      },
      redo: () => runPriority(convIds, quadrantKey),
    });
  }, [conversations, runPriority]);

  return { executeAction, executePriority };
}

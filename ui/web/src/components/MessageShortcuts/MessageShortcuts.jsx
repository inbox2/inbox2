import { useEffect, useRef } from 'react';
import useDraftActions from '../../hooks/useDraftActions';
import useMessageActionShortcuts from '../../hooks/useMessageActionShortcuts';
import useSealedMessages from '../../hooks/useSealedMessages';

/**
 * Binds the message-action keyboard shortcuts for the selected conversation.
 * Renders nothing — it exists so the draft actions can use `useDrafts`, which
 * requires being mounted inside a DraftProvider (the page's own top-level hooks
 * run outside that boundary).
 *
 * Each view passes the callbacks it supports; omitted callbacks make the
 * corresponding shortcuts no-ops (e.g. search supplies only draft actions).
 */
export default function MessageShortcuts({ conversation: rawConversation, orgId, defaultFrom, enabled = true, onStatusAction, onTriage }) {
  // Drafts need the decrypted sender/subject/body of a sealed (E2EE) thread —
  // the reading pane decrypts its own copy, which may not be mounted.
  const { conversation } = useSealedMessages(rawConversation, orgId);
  const draftActions = useDraftActions({ conversation, defaultFrom });
  useMessageActionShortcuts({ conversation, enabled, onStatusAction, onTriage, draftActions });

  // Reply / Forward / Reply All requested from the list context menu (need DraftProvider
  // context, which the page body — where the menu handlers live — is outside of).
  // A sealed thread has no sender until it decrypts (async), so a request that
  // lands first waits for it instead of opening an unaddressed draft.
  const lastMsg = conversation?.messages?.[conversation.messages.length - 1];
  const ready = !lastMsg || !!lastMsg.from_address;
  const pending = useRef(null);
  useEffect(() => { pending.current = null; }, [conversation?.id]);
  useEffect(() => {
    if (ready && pending.current) {
      const action = pending.current;
      pending.current = null;
      draftActions[action]();
    }
    const handlers = { 'compose-reply': 'reply', 'compose-forward': 'forward', 'compose-reply-all': 'replyAll' };
    const listeners = Object.entries(handlers).map(([event, action]) => {
      const fn = () => { if (ready) draftActions[action](); else pending.current = action; };
      document.addEventListener(event, fn);
      return [event, fn];
    });
    return () => listeners.forEach(([event, fn]) => document.removeEventListener(event, fn));
  }, [draftActions, ready]);

  return null;
}

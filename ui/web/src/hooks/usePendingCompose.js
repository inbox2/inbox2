import { useState, useEffect, useCallback } from 'react';

const COMPOSE_EVENT = { forward: 'compose-forward', 'reply-all': 'compose-reply-all', reply: 'compose-reply' };

// Reply/Forward intent fired from a list context menu. Reply only needs the
// composer mounted (conversation loaded); forward needs the messages loaded to
// build the chain. If the target row isn't loaded yet, select it via
// `onSelectConversation` and fire the intent once `selectedConv` catches up.
export default function usePendingCompose({ selectedConv, onSelectConversation }) {
  const [pending, setPending] = useState(null); // { convId, intent }

  const fireCompose = useCallback((intent) => {
    document.dispatchEvent(new CustomEvent(COMPOSE_EVENT[intent] || COMPOSE_EVENT.reply));
  }, []);

  const composeReady = useCallback(
    (conv, intent) =>
      selectedConv?.id === conv?.id && (intent === 'reply' || selectedConv?.messages?.length > 0),
    [selectedConv]
  );

  const requestCompose = useCallback((conv, intent) => {
    if (!conv) return;
    if (composeReady(conv, intent)) {
      fireCompose(intent);
    } else {
      onSelectConversation(conv);
      setPending({ convId: conv.id, intent });
    }
  }, [composeReady, fireCompose, onSelectConversation]);

  /* eslint-disable react-hooks/set-state-in-effect, react-hooks/exhaustive-deps -- fire queued compose intent once the conversation loads */
  useEffect(() => {
    if (!pending) return;
    if (composeReady({ id: pending.convId }, pending.intent)) {
      fireCompose(pending.intent);
      setPending(null);
    }
  }, [selectedConv, pending]);
  /* eslint-enable react-hooks/set-state-in-effect, react-hooks/exhaustive-deps */

  return requestCompose;
}

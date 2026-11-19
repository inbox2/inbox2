import { useState, useCallback } from 'react';
import { QUADRANTS } from '../lib/priority';
import { CONV_ACTION } from '../lib/conversationActions';

export default function useInboxDragDrop({ applyPriority, removePriority, performConversationAction }) {
  const [activeDragId, setActiveDragId] = useState(null);

  const handleDragStart = useCallback((event) => {
    setActiveDragId(event.active.id);
  }, []);

  const handleDragEnd = useCallback((event) => {
    const { active, over } = event;
    setActiveDragId(null);

    if (!over || !active) return;

    const conv = active.data?.current?.conversation;
    if (!conv) return;

    const targetId = over.id;

    // Each dispatcher records its own undo/redo entry — no manual push needed.

    // Priority quadrant drop
    if (QUADRANTS[targetId]) {
      const q = QUADRANTS[targetId];
      applyPriority(conv.id, conv.accountKey, q.urgent, q.important);
      return;
    }

    // Action drop zones
    if (targetId === 'action::archive') {
      performConversationAction(conv.id, conv.accountKey, CONV_ACTION.ARCHIVE);
      return;
    }

    if (targetId === 'action::untag') {
      removePriority(conv.id, conv.accountKey);
      return;
    }

    if (targetId === 'action::delete') {
      performConversationAction(conv.id, conv.accountKey, CONV_ACTION.TRASH);
    }
  }, [applyPriority, removePriority, performConversationAction]);

  const handleDragCancel = useCallback(() => {
    setActiveDragId(null);
  }, []);

  return {
    activeDragId,
    handleDragStart,
    handleDragEnd,
    handleDragCancel,
  };
}

import { useState, useCallback, useRef } from 'react';
import useNavigationStore from '../stores/navigationStore';

// Multi-select (cmd/ctrl-toggle, shift-range) + right-click context-menu state
// for a conversation list. A plain click clears the selection and navigates to
// the conversation; modifier clicks build a selection without navigating.
// Right-clicking a row that's part of the selection keeps it (the menu acts on
// the batch); right-clicking elsewhere resets to that single row.
//
// `orderedConversations` is the list as displayed (for shift-range), `selectedId`
// is the currently open conversation, `setWasUnread` records read-state for the
// mark-as-read flow.
export default function useConversationSelection({ orderedConversations, selectedId, setWasUnread }) {
  const [selectedIds, setSelectedIds] = useState(new Set());
  const [contextMenu, setContextMenu] = useState({ open: false, position: null, conv: null });
  const lastClickedIndexRef = useRef(null);

  const clearSelection = useCallback(() => {
    setSelectedIds(new Set());
    lastClickedIndexRef.current = null;
  }, []);

  const navigateToConv = useCallback((conv) => {
    setWasUnread(!conv.read);
    useNavigationStore.getState().navigateTo({ conversationId: conv.id }, { replace: true, replaceStack: true });
  }, [setWasUnread]);

  const handleConversationClick = useCallback((conv, index, e) => {
    if (e.shiftKey && lastClickedIndexRef.current != null) {
      const start = Math.min(lastClickedIndexRef.current, index);
      const end = Math.max(lastClickedIndexRef.current, index);
      setSelectedIds(prev => {
        const next = new Set(prev);
        for (let i = start; i <= end; i++) next.add(orderedConversations[i].id);
        return next;
      });
      return; // Don't navigate on shift-click
    }
    if (e.metaKey || e.ctrlKey) {
      setSelectedIds(prev => {
        const next = new Set(prev);
        if (next.has(conv.id)) next.delete(conv.id);
        else next.add(conv.id);
        return next;
      });
      lastClickedIndexRef.current = index;
      return; // Don't navigate on cmd/ctrl-click
    }
    clearSelection();
    navigateToConv(conv);
    lastClickedIndexRef.current = index;
  }, [orderedConversations, clearSelection, navigateToConv]);

  const handleConversationContextMenu = useCallback((conv, e) => {
    e.preventDefault();
    e.stopPropagation();
    const inSelection = selectedIds.has(conv.id);
    if (!inSelection && selectedId !== conv.id) {
      clearSelection();
      navigateToConv(conv);
    }
    setContextMenu(prev =>
      (prev.open && prev.conv?.id === conv.id)
        ? prev
        : { open: true, position: { x: e.clientX, y: e.clientY }, conv }
    );
  }, [selectedIds, selectedId, clearSelection, navigateToConv]);

  const closeContextMenu = useCallback(() => {
    setContextMenu({ open: false, position: null, conv: null });
  }, []);

  return {
    selectedIds, setSelectedIds, clearSelection,
    contextMenu, closeContextMenu,
    handleConversationClick, handleConversationContextMenu,
  };
}

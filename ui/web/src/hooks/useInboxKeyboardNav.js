import { useState, useEffect, useCallback, useRef } from 'react';
import useNavigationStore from '../stores/navigationStore';
import { CONV_STATUS } from '../lib/conversationStatus';
import { CONV_ACTION } from '../lib/conversationActions';

export default function useInboxKeyboardNav({
  filteredConversations,
  selectedId,
  selectedConv,
  selectedIds,
  setSelectedIds,
  setWasUnread,
  clearSelection,
  executeAction,
  deselectConversation,
  switchView,
  activeView,
  folderViews,
  listBodyRef,
}) {
  const [keyZone, setKeyZone] = useState('list');
  const [focusedMsgIndex, setFocusedMsgIndex] = useState(-1);

  const focusedIndexRef = useRef(null);
  const filteredRef = useRef(filteredConversations);
  const selectedIdRef = useRef(selectedId);
  useEffect(() => { filteredRef.current = filteredConversations; }, [filteredConversations]);
  useEffect(() => { selectedIdRef.current = selectedId; }, [selectedId]);

  const navigateList = useCallback((direction, shiftHeld) => {
    const list = filteredRef.current;
    if (list.length === 0) return;

    const currentIndex = focusedIndexRef.current ?? list.findIndex(c => c.id === selectedIdRef.current);
    let nextIndex;

    if (currentIndex === -1 || currentIndex == null) {
      nextIndex = direction === 1 ? 0 : list.length - 1;
    } else {
      nextIndex = currentIndex + direction;
    }

    if (nextIndex < 0 || nextIndex >= list.length) return;

    focusedIndexRef.current = nextIndex;
    const conv = list[nextIndex];

    if (shiftHeld) {
      setSelectedIds(prev => {
        const next = new Set(prev);
        if (prev.size === 0 && currentIndex >= 0 && currentIndex < list.length) {
          next.add(list[currentIndex].id);
        }
        next.add(conv.id);
        return next;
      });
    } else {
      clearSelection();
      setWasUnread(!conv.read);
      useNavigationStore.getState().navigateTo({ conversationId: conv.id }, { replace: true, replaceStack: true });
      // Marking read is handled centrally by useMarkRead (driven by selectedId).
    }

    if (listBodyRef.current) {
      const items = listBodyRef.current.children;
      if (items[nextIndex]) {
        items[nextIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
    }
  }, [clearSelection, setSelectedIds, setWasUnread, listBodyRef]);

  // Build navigable folder list for keyboard nav
  const allFolderItems = [
    ...folderViews.map(v => ({ type: 'folder', view: v })),
    { type: 'folder', view: { name: 'Archived', filters: [{ field: 'status', value: CONV_STATUS.ARCHIVED }] } },
    { type: 'folder', view: { name: 'Spam', filters: [{ field: 'status', value: CONV_STATUS.SPAM }] } },
    { type: 'folder', view: { name: 'Trash', filters: [{ field: 'status', value: CONV_STATUS.TRASH }] } },
  ];

  const focusedFolderRef = useRef(-1);

  // Click-to-focus: clicking anywhere inside a pane makes that pane the active
  // key zone, so the user can drive it with the arrow keys without first
  // walking over with ArrowLeft/ArrowRight. Folder-cursor position is derived
  // from the active view at navigation time, so this only needs to flip zones.
  const focusZone = useCallback((zone) => {
    setKeyZone(zone);
    if (zone === 'list') setFocusedMsgIndex(-1);
  }, []);

  // Clicking a specific message card makes it the active card, so the ring lands
  // on the one you clicked and arrow keys continue from there.
  const focusMessage = useCallback((index) => {
    setKeyZone('messages');
    setFocusedMsgIndex(index);
  }, []);

  useEffect(() => {
    const isInputFocused = () => {
      const el = document.activeElement;
      if (!el) return false;
      const tag = el.tagName;
      return tag === 'INPUT' || tag === 'TEXTAREA' || el.contentEditable === 'true';
    };

    const handler = (e) => {
      if (isInputFocused()) return;

      if (e.key === 'ArrowLeft') {
        e.preventDefault();
        if (keyZone === 'list') {
          setKeyZone('folders');
          const idx = allFolderItems.findIndex(f => f.view.name === activeView?.name);
          focusedFolderRef.current = idx >= 0 ? idx : 0;
        } else if (keyZone === 'messages') {
          setKeyZone('list');
          setFocusedMsgIndex(-1);
        }
        return;
      }
      if (e.key === 'ArrowRight') {
        e.preventDefault();
        if (keyZone === 'folders') {
          setKeyZone('list');
          // Auto-select first conversation if none selected
          if (!selectedIdRef.current && filteredRef.current.length > 0) {
            focusedIndexRef.current = null;
            navigateList(1, false);
          }
        } else if (keyZone === 'list' && selectedConv?.messages?.length > 0) {
          setKeyZone('messages');
          setFocusedMsgIndex(0);
        }
        return;
      }

      if (e.key === 'Escape') {
        e.preventDefault();
        if (keyZone === 'messages') {
          setKeyZone('list');
          setFocusedMsgIndex(-1);
        } else if (selectedIds.size > 0) {
          clearSelection();
        } else if (selectedIdRef.current) {
          // Nothing focused into and no multi-select — deselect the open
          // conversation so the reading pane falls back to its empty state.
          deselectConversation?.();
        }
        return;
      }

      if (e.key === 'ArrowDown' || e.key === 'j') {
        e.preventDefault();
        if (keyZone === 'folders') {
          const curIdx = allFolderItems.findIndex(f => f.view.name === activeView?.name);
          const from = curIdx >= 0 ? curIdx : focusedFolderRef.current;
          const next = Math.min(from + 1, allFolderItems.length - 1);
          focusedFolderRef.current = next;
          switchView(allFolderItems[next].view);
        } else if (keyZone === 'messages') {
          setFocusedMsgIndex(prev => Math.min(prev + 1, (selectedConv?.messages?.length || 1) - 1));
        } else {
          navigateList(1, e.shiftKey);
        }
        return;
      }
      if (e.key === 'ArrowUp' || e.key === 'k') {
        e.preventDefault();
        if (keyZone === 'folders') {
          const curIdx = allFolderItems.findIndex(f => f.view.name === activeView?.name);
          const from = curIdx >= 0 ? curIdx : focusedFolderRef.current;
          const next = Math.max(from - 1, 0);
          focusedFolderRef.current = next;
          switchView(allFolderItems[next].view);
        } else if (keyZone === 'messages') {
          setFocusedMsgIndex(prev => Math.max(prev - 1, 0));
        } else {
          navigateList(-1, e.shiftKey);
        }
        return;
      }

      if ((e.key === ' ' || e.key === 'Enter') && keyZone === 'messages' && focusedMsgIndex >= 0) {
        e.preventDefault();
        const cards = document.querySelectorAll('[data-message-card]');
        if (cards[focusedMsgIndex]) {
          const header = cards[focusedMsgIndex].querySelector('[class*="header"]');
          if (header) header.click();
        }
        return;
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [navigateList, selectedIds.size, clearSelection, deselectConversation, keyZone, activeView, selectedConv, focusedMsgIndex, switchView]);

  // Reset focused index when selected conversation changes externally
  useEffect(() => {
    if (selectedId) {
      const idx = filteredConversations.findIndex(c => c.id === selectedId);
      if (idx >= 0) focusedIndexRef.current = idx;
    }
  }, [selectedId, filteredConversations]);

  // ── Mass actions ──

  const handleBulkAction = useCallback((action) => {
    const ids = [...selectedIds];
    if (ids.length === 0) return;
    executeAction(ids, action).then(() => clearSelection()).catch(() => {});
  }, [selectedIds, executeAction, clearSelection]);

  const hasUnreadInSelection = filteredConversations.some(c => selectedIds.has(c.id) && !c.read);

  const handleArchive = useCallback(() => {
    if (!selectedConv) return;
    executeAction([selectedConv.id], CONV_ACTION.ARCHIVE);
  }, [selectedConv, executeAction]);

  const handleTrash = useCallback(() => {
    if (!selectedConv) return;
    executeAction([selectedConv.id], CONV_ACTION.TRASH);
  }, [selectedConv, executeAction]);

  // Backspace / Delete key → trash
  useEffect(() => {
    const isInputFocused = () => {
      const el = document.activeElement;
      if (!el) return false;
      const tag = el.tagName;
      return tag === 'INPUT' || tag === 'TEXTAREA' || el.contentEditable === 'true';
    };
    const handler = (e) => {
      if (isInputFocused()) return;
      if (e.key !== 'Backspace' && e.key !== 'Delete') return;
      e.preventDefault();
      if (selectedIds.size > 0) {
        handleBulkAction(CONV_ACTION.TRASH);
      } else {
        handleTrash();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [selectedIds.size, handleBulkAction, handleTrash]);

  return {
    keyZone,
    focusZone,
    focusMessage,
    focusedMsgIndex,
    handleBulkAction,
    handleArchive,
    handleTrash,
    hasUnreadInSelection,
  };
}

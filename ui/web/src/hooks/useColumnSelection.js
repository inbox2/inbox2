import { useState, useCallback, useRef } from 'react';

// Multi-select for the column views (unified inbox + search results).
// Cmd/ctrl-click toggles a row, shift-click extends a range, a plain click
// clears the selection and falls through to "open this conversation".
//
// Selection is per column: each lane is a different channel (and a different
// backend write path), so an anchor in another column resets rather than
// building a cross-channel batch.
export default function useColumnSelection() {
  const [selectedIds, setSelectedIds] = useState(() => new Set());
  const anchorRef = useRef(null); // { columnKey, index }

  const clearSelection = useCallback(() => {
    setSelectedIds(new Set());
    anchorRef.current = null;
  }, []);

  // Returns true when the click was a selection gesture — the caller should
  // then NOT open/select the conversation.
  const handleRowClick = useCallback((conv, e, columnConvs, index) => {
    const columnKey = conv.accountKey;
    const sameColumn = anchorRef.current?.columnKey === columnKey;

    if (e?.shiftKey && sameColumn) {
      const from = Math.min(anchorRef.current.index, index);
      const to = Math.max(anchorRef.current.index, index);
      setSelectedIds(new Set(columnConvs.slice(from, to + 1).map(c => c.id)));
      return true;
    }
    if (e?.metaKey || e?.ctrlKey) {
      setSelectedIds(prev => {
        const next = sameColumn ? new Set(prev) : new Set();
        if (next.has(conv.id)) next.delete(conv.id);
        else next.add(conv.id);
        return next;
      });
      anchorRef.current = { columnKey, index };
      return true;
    }
    clearSelection();
    anchorRef.current = { columnKey, index };
    return false;
  }, [clearSelection]);

  // Right-click keeps a selection the row belongs to (menu acts on the batch);
  // anywhere else it drops back to the single row under the cursor.
  const keepOrResetSelection = useCallback((conv) => {
    if (!selectedIds.has(conv.id)) clearSelection();
  }, [selectedIds, clearSelection]);

  return { selectedIds, clearSelection, handleRowClick, keepOrResetSelection };
}

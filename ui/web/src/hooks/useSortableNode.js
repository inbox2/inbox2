import { useRef, useEffect, useCallback } from 'react';
import { useSortable } from '@dnd-kit/sortable';

// useSortable with its transform applied via style.setProperty — inline
// style={{}} is banned (F1), so the drag translate can't go through props.
// Returns the ref to put on the sortable element plus the usual dnd-kit bits.
export default function useSortableNode(id) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id });

  const nodeRef = useRef(null);
  const ref = useCallback((node) => {
    nodeRef.current = node;
    setNodeRef(node);
  }, [setNodeRef]);

  useEffect(() => {
    const el = nodeRef.current;
    if (!el) return;
    if (transform) {
      el.style.setProperty('transform', `translate3d(${Math.round(transform.x)}px, ${Math.round(transform.y)}px, 0)`);
    } else {
      el.style.removeProperty('transform');
    }
    el.style.setProperty('transition', transition || '');
  }, [transform, transition]);

  return { ref, attributes, listeners, isDragging };
}

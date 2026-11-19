import { useRef, useCallback, useEffect } from 'react';
import { useDraggable } from '@dnd-kit/core';
import Avatar from '../Avatar';
import Icon from '../Icon';
import QuickActions from '../QuickActions';
import { CONV_ACTION } from '../../lib/conversationActions';
import { statusFolderLabel } from '../../lib/conversationStatus';
import { displayName as senderName } from '../../lib/emailAddress';
import { formatMailTimeCompact } from '../../lib/relativeTime';
import { cleanSubject } from '../../lib/cleanSubject';
import styles from './MiniCard.module.css';

export default function MiniCard({ conv, onClick, onOpen, onContextMenu, onHover, onHoverEnd, onQuickAction, onForward, active, selected, hideAvatar }) {
  const name = senderName(conv.from_address);
  // Cross-folder hits (search spans all mail): badge where the thread lives.
  // Inbox rows have status 'open' → null → no badge.
  const folder = statusFolderLabel(conv.status);

  const {
    attributes,
    listeners,
    setNodeRef,
    isDragging,
  } = useDraggable({
    id: conv.id,
    data: { conversation: conv },
  });

  const didDragRef = useRef(false);

  const handlePointerDown = useCallback((e) => {
    didDragRef.current = false;
    listeners?.onPointerDown?.(e);
  }, [listeners]);

  // The event rides along so the list can read cmd/shift for multi-select.
  const handleClick = useCallback((e) => {
    if (didDragRef.current) return;
    onClick?.(conv, e);
  }, [onClick, conv]);

  useEffect(() => {
    if (isDragging) didDragRef.current = true;
  }, [isDragging]);

  const cls = [styles.miniCard];
  if (isDragging) cls.push(styles.miniCardDragging);
  if (active) cls.push(styles.miniCardActive);
  if (selected) cls.push(styles.miniCardSelected);

  return (
    <div
      ref={setNodeRef}
      className={cls.join(' ')}
      onClick={handleClick}
      onDoubleClick={() => onOpen?.(conv)}
      onContextMenu={(e) => { e.preventDefault(); onContextMenu?.(conv, e); }}
      onMouseEnter={(e) => onHover?.(conv, e)}
      onMouseLeave={() => onHoverEnd?.()}
      {...listeners}
      {...attributes}
      onPointerDown={handlePointerDown}
      onKeyDown={(e) => {
        if (e.key === 'Enter') { e.preventDefault(); onOpen?.(conv); }
        else if (e.key === ' ') { e.preventDefault(); onClick?.(conv); }
      }}
      role="button"
      tabIndex={0}
    >
      {!hideAvatar && <Avatar name={name} size={16} />}
      {!conv.read && <span className={styles.miniCardUnreadDot} />}
      <span className={styles.miniCardFrom}>{name}</span>
      <span className={styles.miniCardSubject}>{cleanSubject(conv.subject) || '(no subject)'}</span>
      {/* Body preview — fills the remaining space; usually empty (snippet not
          loaded in list/triage), so it just leaves a gap before the time. */}
      <span className={styles.miniCardSnippet}>{conv.snippet || ''}</span>
      {conv.has_attachment && <Icon name="paperclip" size={9} className={styles.miniCardAttach} />}
      {folder && <span className={styles.miniCardFolder}>{folder}</span>}
      <span className={styles.miniCardTime}>{formatMailTimeCompact(conv.updated_at)}</span>
      {onQuickAction && (
        <QuickActions
          className={styles.quickActions}
          unread={!conv.read}
          onForward={onForward ? () => onForward(conv) : undefined}
          onMarkRead={() => onQuickAction(conv, conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ)}
          onArchive={() => onQuickAction(conv, CONV_ACTION.ARCHIVE)}
          onTrash={() => onQuickAction(conv, CONV_ACTION.TRASH)}
        />
      )}
    </div>
  );
}

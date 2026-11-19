import { useRef, useCallback, useEffect, memo } from 'react';
import { motion } from 'motion/react';
import { useDraggable } from '@dnd-kit/core';
import Avatar from '../Avatar';
import Icon from '../Icon';
import QuickActions from '../QuickActions';
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import { CONV_ACTION } from '../../lib/conversationActions';
import { displayName as senderName, emailOnly } from '../../lib/emailAddress';
import { formatMailTime } from '../../lib/relativeTime';
import { conversationPreview } from '../../lib/conversationPreview';
import styles from './EmailCard.module.css';

// Memoized: the unified inbox renders one card per conversation and its handlers
// are useCallback-stable, so a card only re-renders when its own conversation
// changes — not on every list-level state change.
function EmailCard({ conversation, onClick, onContextMenu, onHover, onHoverEnd, onQuickAction, onForward, isDragOverlay }) {
  const {
    attributes,
    listeners,
    setNodeRef,
    isDragging,
  } = useDraggable({
    id: conversation.id,
    data: { conversation },
    disabled: isDragOverlay,
  });

  // Track whether a drag happened so onClick doesn't fire after dragging
  const didDragRef = useRef(false);

  const handlePointerDown = useCallback((e) => {
    didDragRef.current = false;
    listeners?.onPointerDown?.(e);
  }, [listeners]);

  const handleClick = useCallback(() => {
    if (didDragRef.current) return;
    onClick?.(conversation);
  }, [onClick, conversation]);

  // When dnd-kit signals dragging, mark it
  useEffect(() => {
    if (isDragging) didDragRef.current = true;
  }, [isDragging]);

  const className = [
    isDragOverlay ? styles.ghost : styles.card,
    isDragging && !isDragOverlay ? styles.cardDragging : '',
    !conversation.read ? styles.cardUnread : '',
  ].filter(Boolean).join(' ');

  // Merge dnd-kit listeners with our handlers — dnd-kit onPointerDown must fire
  const mergedListeners = isDragOverlay ? {} : {
    ...listeners,
    onPointerDown: handlePointerDown,
  };

  return (
    <motion.div
      ref={isDragOverlay ? undefined : setNodeRef}
      className={className}
      // Exit on delete/archive/trash: fade + collapse height so the stream
      // closes the gap. Skipped for the drag ghost (it's never in the list).
      // AnimatePresence in UnifiedInboxView drives it.
      exit={isDragOverlay ? undefined : { opacity: 0, height: 0, marginTop: 0, paddingTop: 0, paddingBottom: 0 }}
      transition={{ duration: 0.22, ease: [0.16, 1, 0.3, 1] }}
      onClick={handleClick}
      onContextMenu={(e) => onContextMenu?.(conversation, e)}
      onMouseEnter={(e) => onHover?.(conversation, e)}
      onMouseLeave={() => onHoverEnd?.()}
      {...mergedListeners}
      {...(isDragOverlay ? {} : attributes)}
      role="button"
      tabIndex={0}
      aria-label={`${senderName(conversation.from_address)}: ${conversation.subject}`}
    >
      {!isDragOverlay && onQuickAction && (
        <QuickActions
          className={styles.quickActions}
          unread={!conversation.read}
          onForward={onForward ? () => onForward(conversation) : undefined}
          onMarkRead={() => onQuickAction(conversation, conversation.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ)}
          onArchive={() => onQuickAction(conversation, CONV_ACTION.ARCHIVE)}
          onTrash={() => onQuickAction(conversation, CONV_ACTION.TRASH)}
        />
      )}
      <div className={styles.topRow}>
        <div className={styles.avatarWrap}>
          <Avatar name={senderName(conversation.from_address)} email={emailOnly(conversation.from_address)} size={22} />
          {conversation.providerType && conversation.providerType !== 'inbox2' && (
            <span className={styles.providerBadge}>
              <ProviderIcon type={conversation.providerType} size={7} />
            </span>
          )}
        </div>
        <div className={styles.fromWrap}>
          <span className={styles.from}>{senderName(conversation.from_address)}</span>
          <span className={styles.email}>{emailOnly(conversation.from_address)}</span>
        </div>
      </div>

      <div className={styles.subjectLine}>
        <span className={styles.subject} dir="auto">{conversation.subject || '(no subject)'}</span>
        {conversationPreview(conversation) && (
          <>
            <span className={styles.subjectSep}> — </span>
            <span className={styles.snippet}>{conversationPreview(conversation)}</span>
          </>
        )}
      </div>

      <div className={styles.bottomRow}>
        <span className={styles.time}>{formatMailTime(conversation.updated_at)}</span>
        {conversation.has_attachment && (
          <Icon name="paperclip" size={9} className={styles.attachmentIcon} />
        )}
        {conversation.urgent && <span className={`${styles.priorityDot} ${styles.priorityDotUrgent}`} />}
        {conversation.important && <span className={`${styles.priorityDot} ${styles.priorityDotImportant}`} />}
      </div>
    </motion.div>
  );
}

export function EmailCardGhost({ conversation }) {
  return <EmailCard conversation={conversation} isDragOverlay />;
}

export default memo(EmailCard);

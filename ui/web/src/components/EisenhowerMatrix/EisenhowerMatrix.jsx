import { useRef, useCallback, useMemo } from 'react';
import { useDroppable } from '@dnd-kit/core';
import Icon from '../Icon';
import MiniCard from '../MiniCard/MiniCard';
import FlameIcon from '../AnimatedIcons/FlameIcon';
import UserPlusIcon from '../AnimatedIcons/UserPlusIcon';
import AlarmClockIcon from '../AnimatedIcons/AlarmClockIcon';
import ClockIcon from '../AnimatedIcons/ClockIcon';
import { QUADRANTS, QUADRANT_ORDER } from '../../lib/priority';
import styles from './EisenhowerMatrix.module.css';

const QUADRANT_ICONS = {
  DO_FIRST: FlameIcon,
  DELEGATE: UserPlusIcon,
  SCHEDULE: AlarmClockIcon,
  LATER: ClockIcon,
};

const QUADRANT_CLASSES = {
  DO_FIRST: styles.quadrantDoFirst,
  DELEGATE: styles.quadrantDelegate,
  SCHEDULE: styles.quadrantSchedule,
  LATER: styles.quadrantLater,
};

const EMPTY_HINTS = {
  DO_FIRST: { label: 'Priority', hint: 'Drag high-priority items here for immediate action' },
  DELEGATE: { label: 'Hand off', hint: 'Urgent items someone else can take' },
  SCHEDULE: { label: 'Plan', hint: 'Important work to schedule for focused time' },
  LATER: { label: 'Backlog', hint: 'Low-priority items to review later' },
};

function Quadrant({ quadrantKey, quadrant, conversations, onClick, onContextMenu, onHover, onHoverEnd, onQuickAction, onForward }) {
  const { setNodeRef, isOver } = useDroppable({
    id: quadrant.key,
    data: { quadrant },
  });

  const qClass = QUADRANT_CLASSES[quadrantKey] || '';
  const AnimIcon = QUADRANT_ICONS[quadrantKey];
  const headerIconRef = useRef(null);
  const emptyIconRef = useRef(null);

  const handleMouseEnter = useCallback(() => {
    headerIconRef.current?.startAnimation?.();
    emptyIconRef.current?.startAnimation?.();
  }, []);

  const handleMouseLeave = useCallback(() => {
    headerIconRef.current?.stopAnimation?.();
    emptyIconRef.current?.stopAnimation?.();
  }, []);

  return (
    <div
      ref={setNodeRef}
      className={`${styles.quadrant} ${qClass} ${isOver ? styles.quadrantOver : ''}`}
      role="presentation"
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <div className={styles.quadrantHeader}>
        <div className={styles.quadrantHeaderBar} />
        {AnimIcon && <AnimIcon ref={headerIconRef} size={14} strokeWidth={1.8} color="currentColor" className={styles.quadrantIcon} />}
        <span className={styles.quadrantLabel}>{quadrant.label}</span>
        {conversations.length > 0 && (
          <span className={styles.quadrantCount}>{conversations.length}</span>
        )}
      </div>

      <div className={styles.quadrantItems}>
        {conversations.length === 0 ? (
          <div className={styles.emptyQuadrant}>
            {AnimIcon && <AnimIcon ref={emptyIconRef} size={40} strokeWidth={1} color="currentColor" className={styles.emptyIcon} />}
            <span className={styles.emptyLabel}>{EMPTY_HINTS[quadrantKey]?.label}</span>
            <span className={styles.emptyHint}>{EMPTY_HINTS[quadrantKey]?.hint}</span>
          </div>
        ) : (
          conversations.slice(0, 20).map(conv => (
            <MiniCard key={conv.id} conv={conv} onClick={onClick} onContextMenu={onContextMenu} onHover={onHover} onHoverEnd={onHoverEnd} onQuickAction={onQuickAction} onForward={onForward} />
          ))
        )}
      </div>
    </div>
  );
}

function ActionDropZone({ id, icon, label, className }) {
  const { setNodeRef, isOver } = useDroppable({
    id,
    data: { action: id },
  });

  return (
    <div
      ref={setNodeRef}
      className={`${className} ${isOver ? styles.actionZoneOver : ''}`}
    >
      <Icon name={icon} size={14} />
      {label}
    </div>
  );
}

export default function EisenhowerMatrix({
  conversations,
  onCardClick,
  onContextMenu,
  onHover,
  onHoverEnd,
  onQuickAction,
  onForward,
  isDragging,
}) {
  const groups = useMemo(() => {
    const g = {};
    for (const key of QUADRANT_ORDER) {
      g[key] = [];
    }
    for (const c of conversations) {
      if (!c.triaged) continue;
      if (c.urgent && c.important) g.DO_FIRST.push(c);
      else if (c.urgent && !c.important) g.DELEGATE.push(c);
      else if (!c.urgent && c.important) g.SCHEDULE.push(c);
      else g.LATER.push(c);
    }
    return g;
  }, [conversations]);

  return (
    <div className={styles.wrapper}>
      <div className={styles.matrix}>
        {QUADRANT_ORDER.map(key => (
          <Quadrant
            key={key}
            quadrantKey={key}
            quadrant={QUADRANTS[key]}
            conversations={groups[key] || []}
            onClick={onCardClick}
            onContextMenu={onContextMenu}
            onHover={onHover}
            onHoverEnd={onHoverEnd}
            onQuickAction={onQuickAction}
            onForward={onForward}
          />
        ))}
      </div>

      <div className={`${styles.actionZones} ${isDragging ? styles.actionZonesVisible : ''}`}>
        <ActionDropZone
          id="action::archive"
          icon="archivebox.fill"
          label="Archive"
          className={styles.actionZoneArchive}
        />
        <ActionDropZone
          id="action::untag"
          icon="tag.slash"
          label="Untag"
          className={styles.actionZoneUntag}
        />
        <ActionDropZone
          id="action::delete"
          icon="trash.fill"
          label="Delete"
          className={styles.actionZoneDelete}
        />
      </div>
    </div>
  );
}

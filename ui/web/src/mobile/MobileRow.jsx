import { memo, useRef, useState } from 'react';
import Avatar from '../components/Avatar';
import Icon from '../components/Icon';
import { conversationItemProps } from '../components/ConversationList/itemProps';
import { displayName, emailOnly } from '../lib/emailAddress';
import { rowTime } from './rowTime';
import styles from './MobileRow.module.css';

// How far a row must travel before a release reveals its actions (px), and the
// fraction of the row width that counts as a full swipe (runs the edge action).
const SWIPE_COMMIT = 56;
const FULL_SWIPE = 0.55;
// Horizontal intent: once the finger has moved this far, decide scroll vs swipe.
const INTENT_SLOP = 8;
// Width of one revealed action button (px) — matches .action in the CSS.
const ACTION_WIDTH = 74;

/* One conversation row — the iOS ConversationRow (ui/ios/Sources/Components/
 * ConversationRow.swift) and its swipe actions (InboxListView.swift), as built
 * there: black action buttons with a whitish icon over the title.
 *   swipe left  → Trash · Archive (Archive nearest the edge, its icon in the
 *                 ring gradient); a full swipe archives
 *   swipe right → Read / Unread; a full swipe toggles it
 * Keyboard: ← and → reveal the same actions (then Tab reaches them), Esc hides. */
function MobileRow({ conv, isSent, onOpen, onArchive, onTrash, onToggleRead }) {
  const p = conversationItemProps(conv, { isSent });
  const rowRef = useRef(null);
  const drag = useRef(null);
  // A swipe ends in a pointerup the browser may still turn into a click; that
  // click must not also open the conversation.
  const swiped = useRef(false);
  const [revealed, setRevealed] = useState(null); // 'leading' | 'trailing' | null
  const who = isSent ? conv.to_address : conv.from_address;
  const trailing = [onTrash && 'trash', onArchive && 'archive'].filter(Boolean);
  const edgeAction = onArchive || onTrash; // full swipe left: Archive, else Trash
  const offsetFor = (side) => (side === 'leading' ? ACTION_WIDTH : side === 'trailing' ? -trailing.length * ACTION_WIDTH : 0);

  const setX = (x, animate) => {
    const el = rowRef.current;
    if (!el) return;
    el.dataset.animate = animate ? 'true' : 'false';
    el.style.setProperty('--swipe-x', `${x}px`);
  };
  const show = (side) => { setX(offsetFor(side), true); setRevealed(side); };
  const close = () => show(null);

  const onPointerDown = (e) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    drag.current = { x0: e.clientX, y0: e.clientY, dx: 0, mode: null, base: offsetFor(revealed), id: e.pointerId };
  };
  const onPointerMove = (e) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    const dx = e.clientX - d.x0;
    const dy = e.clientY - d.y0;
    if (!d.mode) {
      if (Math.abs(dx) < INTENT_SLOP && Math.abs(dy) < INTENT_SLOP) return;
      d.mode = Math.abs(dx) > Math.abs(dy) ? 'swipe' : 'scroll';
      if (d.mode === 'swipe') e.currentTarget.setPointerCapture(e.pointerId);
    }
    if (d.mode !== 'swipe') return;
    d.dx = dx;
    // No trailing actions in this folder → the row doesn't travel left.
    setX(Math.max(trailing.length ? -Infinity : 0, d.base + dx), false);
  };
  const onPointerUp = (e) => {
    const d = drag.current;
    drag.current = null;
    if (!d || d.mode !== 'swipe') return;
    e.preventDefault();
    // Swallow this gesture's click (dispatched right after pointerup), then
    // clear — a browser that sends no click mustn't eat the next tap.
    swiped.current = true;
    setTimeout(() => { swiped.current = false; }, 0);
    const x = d.base + d.dx;
    const width = rowRef.current?.offsetWidth || 360;
    // Full swipes only count from a closed row: dragging an open row back past
    // centre just closes it rather than firing the far side's action.
    const fromClosed = d.base === 0;
    if (fromClosed && x > width * FULL_SWIPE) { close(); onToggleRead(); }
    else if (x > SWIPE_COMMIT) show('leading');
    else if (fromClosed && x < -width * FULL_SWIPE && edgeAction) { setX(-width, true); edgeAction(); }
    else if (x < -SWIPE_COMMIT && trailing.length) show('trailing');
    else close();
  };

  const handleClick = () => {
    if (swiped.current) { swiped.current = false; return; }
    if (revealed) { close(); return; }
    onOpen(conv);
  };
  const onKeyDown = (e) => {
    if (e.key === 'Escape' && revealed) { e.preventDefault(); close(); return; }
    const toward = e.key === 'ArrowLeft' ? 'trailing' : e.key === 'ArrowRight' ? 'leading' : null;
    if (!toward) return;
    e.preventDefault();
    if (revealed) close();
    else if (toward === 'leading' || trailing.length) show(toward);
  };

  const cls = [styles.row, p.unread ? styles.unread : ''].join(' ');
  return (
    <div className={styles.wrap}>
      <button
        ref={rowRef}
        type="button"
        className={cls}
        onClick={handleClick}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={close}
        onKeyDown={onKeyDown}
        aria-label={`${p.unread ? 'Unread, ' : ''}${p.sender}: ${p.subject}`}
        aria-description="Arrow keys for actions"
      >
        <Avatar name={displayName(who) || p.sender} email={emailOnly(who)} size={48} />
        <span className={styles.text}>
          <span className={styles.line}>
            <span className={styles.sender} dir="auto">{p.sender}</span>
            <span className={styles.time}>{rowTime(isSent ? (conv.sent_at || conv.updated_at) : conv.updated_at)}</span>
          </span>
          <span className={styles.subject} dir="auto">{p.subject}</span>
          <span className={styles.line}>
            {p.hasAttachment ? <Icon name="paperclip" size={11} className={styles.clip} /> : null}
            <span className={styles.snippet} dir="auto">{p.snippet}</span>
            {p.count > 1 && <span className={styles.count}>{p.count}</span>}
            {p.priority && <span className={`${styles.tag} ${styles[`tag_${p.priority.tone}`] || ''}`}>{p.priority.badge}</span>}
            {p.folder && <span className={styles.tag}>{p.folder}</span>}
            {p.unread && <span className={styles.dot} />}
          </span>
        </span>
      </button>

      {/* Behind the row, after it in tab order. Hidden from AT until revealed. */}
      <div className={styles.under} aria-hidden={!revealed}>
        <span className={styles.side}>
          <SwipeButton icon={p.unread ? 'envelope.open' : 'envelope.badge'} label={p.unread ? 'Read' : 'Unread'}
            reachable={revealed === 'leading'} onClick={() => { close(); onToggleRead(); }} />
        </span>
        <span className={styles.side}>
          {onTrash && <SwipeButton icon="trash" label="Trash" reachable={revealed === 'trailing'} onClick={() => { close(); onTrash(); }} />}
          {onArchive && <SwipeButton icon="archivebox" label="Archive" gradient reachable={revealed === 'trailing'} onClick={() => { close(); onArchive(); }} />}
        </span>
      </div>
    </div>
  );
}

function SwipeButton({ icon, label, gradient, reachable, onClick }) {
  return (
    <button type="button" className={styles.action} tabIndex={reachable ? 0 : -1} onClick={onClick}>
      {/* The gradient glyph is the theme's --gradient-ring seen through an
          archivebox-shaped mask, so it follows the theme like the avatar rings. */}
      {gradient ? <span className={styles.ringArchive} aria-hidden="true" /> : <Icon name={icon} size={20} />}
      {label}
    </button>
  );
}

export default memo(MobileRow);

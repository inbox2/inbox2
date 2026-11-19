import { useRef, useState, useLayoutEffect, useEffect, useMemo } from 'react';
import Avatar from '../Avatar';
import Icon from '../Icon';
import ConversationStrip from '../ConversationStrip/ConversationStrip';
import AnimatedSpaceIcon from '../AnimatedIcons/AnimatedSpaceIcon';
import { squarify, inset } from '../../lib/treemap';
import { spaceColor } from '../../lib/spaceColors';
import { faceFor } from '../../lib/demoFaces';
import { spaceMetric } from '../../pages/dashboard/mockData';
import { HOLDING_PEN_SLUG, OPENNESS_PERSONAL } from '../../lib/spaceBoard';
import styles from './SpaceTreemap.module.css';

const GAP = 10; // gap between cells (matches the bottom metric-card gap)
const UNIT = { open: 'open', volume: 'total', unread: 'unread' };
const ROW = 28; // conversation row height (matches ConversationStrip .row height)
const EMPTY_ICON = 44; // animated empty-state glyph size

// A little pool of glyphs sprinkled across empty spaces so the board doesn't
// read as one repeated icon. Picked deterministically per space (stable across
// reflows), not the space's own icon.
const EMPTY_ICONS = [
  'sparkles', 'star.fill', 'bolt.fill', 'bell', 'paperplane.fill',
  'tray.fill', 'tag.fill', 'moon.fill', 'sun.max.fill', 'wand.and.stars',
];
function emptyIconFor(id) {
  const s = String(id);
  let h = 0;
  for (let i = 0; i < s.length; i += 1) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return EMPTY_ICONS[h % EMPTY_ICONS.length];
}

/* Absolutely-positioned cell; geometry + color pushed through CSS custom
 * properties via a ref (inline styles are banned project-wide). */
function Cell({ x, y, w, h, vars, className, children, ...rest }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.setProperty('--x', `${x}px`);
    el.style.setProperty('--y', `${y}px`);
    el.style.setProperty('--w', `${w}px`);
    el.style.setProperty('--h', `${h}px`);
    if (vars) for (const [k, v] of Object.entries(vars)) el.style.setProperty(k, v);
  }, [x, y, w, h, vars]);
  return <div ref={ref} className={className} {...rest}>{children}</div>;
}

/* One treemap cell: the space's count + participants, the scrolling strip of
 * every conversation in it, and — when the space is empty — an empty state
 * whose glyph animates while the cell is hovered. A wide cell puts the strip
 * beside the count, a narrow one under it; the stylesheet decides which. */
function TreemapCell({ c, metric, msgs, onSelect, onOpenMessage, onMessageContextMenu }) {
  const iconRef = useRef(null);
  const color = spaceColor(c.s.id);
  const value = spaceMetric(c.s, metric);
  const members = c.s.members.map((m) => m.name);

  // What fits is CSS's decision (see the container query in the stylesheet):
  // where the list sits and what a row drops as it narrows. JS only answers
  // "is there room at all", from the cell's height — width maths here never
  // matched the rendered layout and kept clipping rows.
  const fitsRows = Math.floor((c.h - 28) / ROW) >= 2;
  const showMsgs = fitsRows && msgs.length > 0;
  const showBig = c.h > 70;
  const showName = c.w > 120;
  const showEmpty = msgs.length === 0 && c.w >= 150 && c.h >= 120;

  const personal = c.s.openness === OPENNESS_PERSONAL;
  const pen = c.s.id === HOLDING_PEN_SLUG;
  // `unassigned` is null on the Mine board (everything there is already yours).
  const hasUnassigned = typeof c.s.unassigned === 'number';
  const showFoot = (members.length > 0 || personal || pen || c.s.unassigned > 0) && c.h > 96;
  const metricSize = Math.max(30, Math.min(46, Math.round(28 + c.h * 0.022)));

  const hover = showEmpty ? {
    onMouseEnter: () => iconRef.current?.startAnimation?.(),
    onMouseLeave: () => iconRef.current?.stopAnimation?.(),
  } : {};

  return (
    <Cell
      x={c.x}
      y={c.y}
      w={c.w}
      h={c.h}
      vars={{
        // Glass cells read dark (translucent tint over the charcoal panel), so
        // the foreground is always white regardless of the hue's lightness.
        '--q-a': color.a, '--q-b': color.b, '--q-fg': '#fff',
        '--q-glow': color.glow,
        '--metric-size': `${metricSize}px`,
      }}
      className={styles.cell}
      data-hue={color.key}
      role="button"
      tabIndex={0}
      aria-label={`${c.s.name} space`}
      onClick={() => onSelect?.(c.s)}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelect?.(c.s); } }}
      {...hover}
    >
      <div className={styles.inner}>
      <div className={styles.left}>
        <div className={styles.head}>
          <Icon name={personal ? 'lock' : c.s.openness === 'org' ? 'globe' : 'person.2'} size={14} className={styles.openIcon} />
          {showName && <span className={styles.name}>{c.s.name}</span>}
        </div>
        {showBig && (
          <div className={styles.big}>{value}<span className={styles.unit}>{UNIT[metric]}</span></div>
        )}
      </div>
      {showMsgs && (
        <ConversationStrip
          messages={msgs}
          className={styles.msgPanel}
          onOpen={onOpenMessage ? (m) => onOpenMessage(m, c.s) : undefined}
          onContextMenu={onMessageContextMenu}
        />
      )}
      {showFoot && (
        <div className={styles.foot}>
          {members.length ? (
            <div className={styles.stack}>
              {members.slice(0, 3).map((n) => (
                <span key={n} className={styles.stackItem}><Avatar name={n} src={faceFor(n)} size={24} /></span>
              ))}
              {members.length > 3 && <span className={styles.more}>+{members.length - 3}</span>}
            </div>
          ) : (
            <span className={styles.holding}>{personal ? 'Only you' : pen ? 'Holding pen' : ''}</span>
          )}
          {hasUnassigned && (
            <span className={styles.unassigned} title="Unassigned"><Icon name="tray.2.fill" size={13} /> {c.s.unassigned}</span>
          )}
        </div>
      )}
      </div>
      {showEmpty && (
        <div className={styles.empty}>
          <AnimatedSpaceIcon
            ref={iconRef}
            name={emptyIconFor(c.s.id)}
            size={EMPTY_ICON}
            className={styles.emptyIcon}
          />
          <span className={styles.emptyLabel}>All clear</span>
          <span className={styles.emptyHint}>New {c.s.name} mail lands here</span>
        </div>
      )}
    </Cell>
  );
}

export default function SpaceTreemap({ spaces, metric = 'open', onSelect, onOpenMessage, onMessageContextMenu, messagesBySpace = {} }) {
  const wrapRef = useRef(null);
  const [size, setSize] = useState({ w: 0, h: 0 });

  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return undefined;
    const ro = new ResizeObserver((entries) => {
      const r = entries[0].contentRect;
      setSize({ w: Math.floor(r.width), h: Math.floor(r.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const cells = useMemo(() => {
    if (size.w < 40 || size.h < 40) return [];
    // A strictly-proportional treemap degenerates on sparse data: when one space
    // is busy and the rest are empty (e.g. everything sitting in Triage), the busy
    // cell swallows the board and the empty spaces collapse into unreadable
    // slivers. Floor every cell to a fraction of the busiest so each space stays a
    // legible tile; when the whole board is empty (max 0) this fabricates an even
    // grid — exactly the right fallback.
    const raws = spaces.map((s) => Math.max(spaceMetric(s, metric), 0));
    const max = Math.max(0, ...raws);
    const floor = max * 0.5;
    const items = spaces.map((s, i) => ({ s, value: Math.max(raws[i], floor, 0.001) }));
    return squarify(items, 0, 0, size.w, size.h).map((r) => ({ ...inset(r, GAP / 2), s: r.s }));
  }, [spaces, metric, size]);

  return (
    <div ref={wrapRef} className={styles.canvas}>
      {cells.map((c) => (
        <TreemapCell key={c.s.id} c={c} metric={metric} msgs={messagesBySpace[c.s.id] || []} onSelect={onSelect} onOpenMessage={onOpenMessage} onMessageContextMenu={onMessageContextMenu} />
      ))}
    </div>
  );
}

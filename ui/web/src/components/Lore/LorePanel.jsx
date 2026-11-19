import { useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import usePaneMode from '../../hooks/usePaneMode';
import useLore from '../../hooks/useLore';
import useAuth from '../../hooks/useAuth';
import { PaneModeMenu, PaneStrip } from '../PaneMode/PaneMode';
import Icon from '../Icon';
import Tooltip from '../Tooltip';
import LoreItem from './LoreItem';
import LoreGroup from './LoreGroup';
import useSendTo from './useSendTo';
import { LORE_PANE_MODE } from '../../lib/storageKeys';
import { searchItems, buildToday, groupButton } from '../../lib/lore';
import { openLoreItem, entityPath, LORE_PATH } from './openItem';
import styles from './Lore.module.css';

/**
 * Today, contained: the unified inbox's right-hand Lore panel (pinned /
 * floating / hidden like the other panes). What's still open, ranked, with a
 * checkbox that archives the email; the expand button opens the full-window
 * Lore app. `dispatch` lets the inbox act on threads it already shows, so the
 * row leaves its column too (see useLore).
 */
export default function LorePanel({ dispatch, onOpen }) {
  const navigate = useNavigate();
  const { organizations } = useAuth();
  const ref = useRef(null);
  const pane = usePaneMode(LORE_PANE_MODE, ref);
  const lore = useLore({ dispatch });
  const { items, today, loading, error, complete, completeMany } = lore;
  const [query, setQuery] = useState('');
  const [closed, setClosed] = useState(() => new Set());
  // Handled-for-you groups start folded; unfold one to see the threads behind its count.
  const [unfolded, setUnfolded] = useState(() => new Set());
  const toggleHandled = (label) => setUnfolded((u) => {
    const next = new Set(u);
    if (next.has(label)) next.delete(label); else next.add(label);
    return next;
  });
  const sendTo = useSendTo();

  // Searching narrows every group in place rather than switching views.
  const shown = useMemo(() => (query ? buildToday(searchItems(items, query)) : today), [query, items, today]);
  const toggleGroup = (key) => setClosed((c) => {
    const next = new Set(c);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });
  const open = (item) => (onOpen ? onOpen(item) : openLoreItem(item, organizations));
  const toEntity = (e) => navigate(entityPath(e));
  const handledCount = shown.handled.reduce((n, g) => n + g.items.length, 0);

  const group = (key, title, tone, list) => list.length > 0 && (
    <div className={styles.group} key={key}>
      <button type="button" className={styles.groupHead} onClick={() => toggleGroup(key)} aria-expanded={!closed.has(key)}>
        <Icon name="chevron.right" size={9} className={`${styles.chevron} ${closed.has(key) ? '' : styles.chevronOpen}`} />
        <span className={`${styles.dot} ${styles[`dot_${tone}`]}`} />
        {title}
        <span className={styles.groupCount}>{list.reduce((n, g) => n + g.items.length, 0)}</span>
      </button>
      {!closed.has(key) && list.map((g) => (
        <LoreGroup key={g.uid} group={g} lore={lore} compact tone={tone} onOpen={open} onEntity={toEntity} onSendTo={sendTo.open} />
      ))}
    </div>
  );

  return (
    <aside ref={ref} className={`${styles.lore} ${styles.panel}`} aria-label="Lore — today">
      {pane.strip && <PaneStrip pane={pane} icon="checkmark.circle" label="Lore" />}
      {pane.shown && (
        <div className={styles.panelBody} data-floating={pane.floating ? 'true' : undefined}>
          <div className={styles.panelHeader}>
            <span className={styles.loreBadge}><Icon name="checkmark.circle" size={10} />Lore</span>
            <span className={styles.panelTitle}>Today</span>
            <span className={styles.count}>{loading ? '…' : `${shown.open} open`}</span>
            <span className={styles.panelTools}>
              <Tooltip content="Open Lore full window">
                <button type="button" className={styles.iconButton} onClick={() => navigate(LORE_PATH.TODAY)} aria-label="Open Lore full window">
                  <Icon name="arrow.up.left.and.arrow.down.right" size={13} />
                </button>
              </Tooltip>
              <PaneModeMenu pane={pane} label="Lore pane" />
            </span>
          </div>
          <div className={styles.panelSearch}>
            <input
              className={styles.search}
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Filter your workload…"
              aria-label="Filter Lore items"
            />
          </div>
          <div className={styles.panelScroll}>
            {error && <p className={styles.muted} role="status">Couldn't refresh everything — showing what was loaded last.</p>}
            {!loading && shown.open === 0 && handledCount === 0 && (
              <div className={styles.empty}>
                <Icon name="checkmark.circle" size={22} />
                {query ? 'Nothing matches.' : 'Nothing on your plate. New mail is sorted here as Jev triages it.'}
              </div>
            )}
            {group('first', 'Do first', 'first', shown.first)}
            {shown.sections.map((s) => group(s.bucket, s.title, s.tone, s.groups))}
            {handledCount > 0 && (
              <div className={styles.group}>
                <div className={styles.groupHead}>
                  <span className={`${styles.dot} ${styles.dot_handled}`} />
                  Handled for you — waiting for your OK
                </div>
                {shown.handled.filter((g) => g.items.length).map((g) => (
                  <div key={g.label}>
                    <div className={styles.handledRow}>
                      <button
                        type="button"
                        className={`${styles.groupHead} ${styles.handledToggle}`}
                        onClick={() => toggleHandled(g.label)}
                        aria-expanded={unfolded.has(g.label)}
                        title={unfolded.has(g.label) ? 'Hide the threads' : 'Show the threads'}
                      >
                        <Icon name="chevron.right" size={9} className={`${styles.chevron} ${unfolded.has(g.label) ? styles.chevronOpen : ''}`} />
                        <span className={styles.handledText}><b>{g.items.length}</b> {g.title}</span>
                      </button>
                      <button type="button" className={styles.button} onClick={() => completeMany(g.items, g.action)}>
                        {groupButton(g)} {g.items.length}
                      </button>
                    </div>
                    {unfolded.has(g.label) && g.items.map((item) => (
                      <LoreItem
                        key={item.uid}
                        item={item}
                        compact
                        onToggle={(it) => complete(it, g.action)}
                        onOpen={open}
                        onEntity={toEntity}
                      />
                    ))}
                  </div>
                ))}
              </div>
            )}
          </div>
          <div className={styles.panelFoot}>
            <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={() => navigate(LORE_PATH.HISTORY)}>
              <Icon name="clock.arrow.circlepath" size={12} /> History
            </button>
            <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={() => navigate(LORE_PATH.TODAY)}>
              <Icon name="note.text" size={12} /> Notes &amp; pages
            </button>
          </div>
        </div>
      )}
      {sendTo.dialog}
    </aside>
  );
}

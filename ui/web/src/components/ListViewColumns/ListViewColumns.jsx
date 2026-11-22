import { useMemo, useEffect, useRef, useCallback } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import MiniCard from '../MiniCard/MiniCard';
import { GhostColumn } from '../Ghosts/Ghosts';
import ChannelEmptyState from '../ChannelEmptyState/ChannelEmptyState';
import Button from '../Button/Button';
import { accountIconSrc } from '../../lib/providerTypes';
import { filterUnread } from '../../lib/unreadFilter';
import styles from './ListViewColumns.module.css';

export default function ListViewColumns({
  conversations,
  channelStates,
  accounts,
  selectedId,
  onSelect,
  onOpen,
  onContextMenu,
  onHover,
  onHoverEnd,
  onQuickAction,
  onForward,
  unreadOnly,
  // Row kept in the unread view even once read (see filterUnread).
  pinnedId,
  // Turns the unread filter off — offered from the "No unread" empty state.
  onShowAll,
  // Multi-select (see useColumnSelection): the id set to paint, and the click
  // handler that owns the cmd/shift gestures. It returns true when the click
  // was a selection gesture, meaning "don't open this row".
  selectedIds,
  onRowClick,
  // Non-mail column pinned before the account columns (the calendar rail).
  // Narrower than a mail lane and outside keyboard column navigation.
  asideColumn,
  // Infinite scroll: called with an account key when that column is scrolled
  // near its end. Each lane pages independently.
  onColumnEndReached,
  // Optional controls after a column's title (account → node), e.g. the MX
  // address-folder picker or the close button of an extra folder column.
  renderHeaderAction,
}) {
  const containerRef = useRef(null);

  // Fires while the user is within a screen of a column's last row. Safe to fire
  // often — the hook behind it no-ops once the column has no more pages.
  const handleColumnScroll = useCallback((accountKey, e) => {
    if (!onColumnEndReached) return;
    const el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight > el.clientHeight) return;
    onColumnEndReached(accountKey);
  }, [onColumnEndReached]);

  // Group conversations by account key
  const grouped = useMemo(() => {
    const map = {};
    for (const conv of conversations) {
      if (!map[conv.accountKey]) map[conv.accountKey] = [];
      map[conv.accountKey].push(conv);
    }
    return map;
  }, [conversations]);

  // Only show columns for enabled channels
  const enabledAccounts = useMemo(
    () => accounts.filter(a => channelStates[a.key]?.enabled),
    [accounts, channelStates]
  );

  // Per-column visible conversation lists (keyboard nav + render).
  // With the unread filter on, lanes with nothing unread drop out entirely —
  // including when that leaves no lanes at all (one "no unread" state instead).
  const columnData = useMemo(() => {
    const all = enabledAccounts.map(a => {
      const visible = filterUnread(grouped[a.key] || [], unreadOnly, pinnedId);
      return { account: a, visible };
    });
    return unreadOnly ? all.filter(c => c.visible.length > 0) : all;
  }, [enabledAccounts, grouped, unreadOnly, pinnedId]);

  // Flat column arrays for keyboard nav (only non-empty)
  const columns = useMemo(() =>
    columnData.map(c => c.visible).filter(v => v.length > 0),
  [columnData]);

  // Remember each column's last-visited row index
  const columnRowRef = useRef({});

  // Find current position: { col, row }
  const findPosition = useCallback((id) => {
    if (!id) return null;
    for (let col = 0; col < columns.length; col++) {
      const row = columns[col].findIndex(c => c.id === id);
      if (row >= 0) return { col, row };
    }
    return null;
  }, [columns]);

  // Keyboard navigation — arrows (skip when focus is in a text field)
  const handleKeyDown = useCallback((e) => {
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || e.target.isContentEditable) return;
    if (document.querySelector('[data-overlay-open]')) return;

    // Enter — open the selected conversation in its channel-specific view
    if (e.key === 'Enter') {
      if (!selectedId) return;
      const pos = findPosition(selectedId);
      if (!pos) return;
      e.preventDefault();
      onOpen?.(columns[pos.col][pos.row]);
      return;
    }

    if (!['ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    const totalItems = columns.reduce((n, col) => n + col.length, 0);
    if (totalItems === 0) return;

    e.preventDefault();
    const pos = findPosition(selectedId);

    let next;
    if (e.key === 'ArrowDown') {
      if (!pos) { next = columns[0][0]; }
      else if (pos.row < columns[pos.col].length - 1) { next = columns[pos.col][pos.row + 1]; }
      else { next = columns[pos.col][0]; }
    } else if (e.key === 'ArrowUp') {
      if (!pos) { next = columns[0][0]; }
      else if (pos.row > 0) { next = columns[pos.col][pos.row - 1]; }
      else { next = columns[pos.col][columns[pos.col].length - 1]; }
    } else if (e.key === 'ArrowRight') {
      if (!pos) { next = columns[0][0]; }
      else {
        columnRowRef.current[pos.col] = pos.row;
        const nextCol = (pos.col + 1) % columns.length;
        const remembered = columnRowRef.current[nextCol];
        const row = remembered != null
          ? Math.min(remembered, columns[nextCol].length - 1)
          : 0;
        next = columns[nextCol][row];
      }
    } else { // ArrowLeft
      if (!pos) { next = columns[0][0]; }
      else {
        columnRowRef.current[pos.col] = pos.row;
        const prevCol = (pos.col - 1 + columns.length) % columns.length;
        const remembered = columnRowRef.current[prevCol];
        const row = remembered != null
          ? Math.min(remembered, columns[prevCol].length - 1)
          : 0;
        next = columns[prevCol][row];
      }
    }

    // Update remembered row for the target column
    if (next) {
      const nextPos = findPosition(next.id);
      if (nextPos && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
        columnRowRef.current[nextPos.col] = nextPos.row;
      }
      onSelect?.(next);
    }
  }, [columns, selectedId, findPosition, onSelect, onOpen]);

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleKeyDown]);

  // Scroll selected item into view
  useEffect(() => {
    if (!selectedId || !containerRef.current) return;
    const el = containerRef.current.querySelector(`[data-conv-id="${selectedId}"]`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [selectedId]);

  return (
    <div ref={containerRef} className={styles.columnsContainer}>
      {asideColumn && (
        <div className={`${styles.column} ${styles.columnAside}`}>{asideColumn}</div>
      )}
      {/* Unread filter with nothing unread anywhere: no lane qualifies, so show
          one app-level empty state rather than resurrecting every column. */}
      {columnData.length === 0 && (
        <div className={styles.noUnread}>
          <ChannelEmptyState
            iconSrc="/logo-cube.png"
            title="No unread messages"
            message="You're all caught up across every channel."
          >
            {onShowAll && (
              <Button variant="secondary" className={styles.showAll} onClick={onShowAll}>
                Show all mail
              </Button>
            )}
          </ChannelEmptyState>
        </div>
      )}
      {columnData.map(({ account, visible }) => {
        const selectedCount = selectedIds ? visible.filter(c => selectedIds.has(c.id)).length : 0;
        return (
          <div key={account.key} className={styles.column}>
            <div className={styles.columnHeader}>
              {(grouped[account.key] || []).some(c => !c.read) && (
                <span className={styles.columnUnreadDot} aria-label="unread" />
              )}
              {/* `name` matters: without it an inbox2 lane with no custom icon
                  falls back to the generic cube while its empty state (via
                  accountIconSrc) draws the initials monogram. */}
              <ProviderIcon
                type={account.provider_type}
                iconUrl={account.icon_url}
                name={account.display_name || account.email_address}
                size={18}
              />
              <span className={styles.columnTitle}>
                {account.email_address || account.display_name}
              </span>
              {renderHeaderAction?.(account)}
              {/* The lane's count doubles as its selection readout. */}
              <span className={styles.columnCount}>
                {selectedCount > 0 ? `${selectedCount} selected` : visible.length}
              </span>
            </div>
            <div
              className={styles.columnBody}
              onScroll={(e) => handleColumnScroll(account.key, e)}
            >
              {/* Empty column → low-fidelity ghost rows under a centered
                  per-column empty state, so each lane reads as "caught up"
                  rather than a blank gutter. */}
              {visible.length === 0 && (
                <>
                  <GhostColumn />
                  <div className={styles.columnEmpty}>
                    <ChannelEmptyState
                      iconSrc={accountIconSrc(account)}
                      title="All caught up"
                      message="No open conversations"
                    />
                  </div>
                </>
              )}
              {/* AnimatePresence keeps a removed row mounted to play its exit
                  (fade + height collapse) before it leaves the DOM. The
                  per-row wrapper is the motion node so MiniCard stays shared
                  and unaware of the animation. */}
              <AnimatePresence initial={false}>
                {visible.map((conv, idx) => (
                  <motion.div
                    key={conv.id}
                    data-conv-id={conv.id}
                    className={styles.cardWrap}
                    exit={{ opacity: 0, height: 0 }}
                    transition={{ duration: 0.22, ease: [0.16, 1, 0.3, 1] }}
                  >
                    <MiniCard
                      conv={conv}
                      onClick={(c, e) => {
                        if (onRowClick?.(c, e, visible, idx)) return;
                        onSelect?.(c);
                      }}
                      onOpen={onOpen}
                      onContextMenu={onContextMenu}
                      onHover={onHover}
                      onHoverEnd={onHoverEnd}
                      onQuickAction={onQuickAction}
                      onForward={onForward}
                      active={selectedId === conv.id}
                      selected={selectedIds?.has(conv.id)}
                      hideAvatar
                    />
                  </motion.div>
                ))}
              </AnimatePresence>
            </div>
          </div>
        );
      })}
      {/* Lanes the unread filter dropped keep their share of the strip, so the
          survivors stay lane-width instead of stretching to fill it. */}
      {columnData.length > 0 && Array.from({ length: enabledAccounts.length - columnData.length }, (_, i) => (
        <div key={`gap-${i}`} className={styles.laneGap} aria-hidden="true" />
      ))}
    </div>
  );
}

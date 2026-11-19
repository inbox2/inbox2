import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../Icon';
import IconButton from '../IconButton';
import useDismiss from '../../hooks/useDismiss';
import api from '../../lib/api';
import { isTauri } from '../../lib/tauri';
import { isStandaloneDesktop } from '../../lib/setupMode';
import { displayName as senderName } from '../../lib/emailAddress';
import useNotificationStore, { getEventMeta } from '../../stores/notificationStore';
import useUpdateStore from '../../stores/updateStore';
import layout from '../../styles/layout.module.css';
import { formatClock } from '../../lib/relativeTime';
import styles from './NotificationPanel.module.css';

function dateGroup(ts) {
  const now = new Date();
  const d = new Date(ts);
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startOfYesterday = new Date(startOfToday - 86400000);
  if (d >= startOfToday) return 'Today';
  if (d >= startOfYesterday) return 'Yesterday';
  return 'Earlier';
}

function feedSummary(entry) {
  const sender = senderName(entry.from_address);
  switch (entry.eventType) {
    case 'assigned':   return `Assigned by ${sender}`;
    case 'reply':      return `${sender} replied`;
    case 'mention':    return `${sender} mentioned you`;
    case 'approval':   return `Needs your approval`;
    case 'delegated':  return `Delegated to ${sender}`;
    case 'completed':  return `Completed`;
    case 'sla_breach': return `SLA breached`;
    default:           return entry.subject || `From ${sender}`;
  }
}

// The desktop update row, in the reauth banner's clothes: the same "one click
// needed" register the message list uses for an expired sign-in.
function UpdateRow() {
  const { update, busy, progress, deferred, error, install } = useUpdateStore();
  if (!update) return null;
  let text = `Inbox2 ${update.version} is ready`;
  if (busy) text = progress == null ? 'Downloading update…' : progress >= 1 ? 'Restarting…' : `Downloading ${Math.round(progress * 100)}%`;
  else if (deferred) text = 'Installer opened. Follow the system prompt.';
  else if (error) text = `Update failed: ${error}`;
  return (
    <div className={`${layout.reauthBanner} ${styles.updateRow}`} role="status">
      <Icon name="arrow.down.circle" size={13} className={layout.reauthBannerIcon} />
      <span className={layout.reauthBannerText}>{text}</span>
      {!busy && !deferred && (
        <button type="button" className={layout.reauthBannerBtn} onClick={install}>
          {error ? 'Retry' : 'Update'}
        </button>
      )}
    </div>
  );
}

// Server notifications that point somewhere (Disk shares today: kind disk_shared,
// a url under /disk/...; an old /:orgSlug/disk/... url redirects). Unread ones show at the top and open their url.
function useLinkedNotifications(open) {
  const [items, setItems] = useState([]);
  useEffect(() => {
    if (!open || (isTauri() && isStandaloneDesktop())) return undefined;
    let live = true;
    api.getNotifications()
      .then((d) => { if (live) setItems((d.notifications || []).filter((n) => n.url && !n.read)); })
      .catch(() => {});
    return () => { live = false; };
  }, [open]);
  return [items, setItems];
}

export default function NotificationPanel({ open, onClose }) {
  const history = useNotificationStore(s => s.history);
  const clearHistory = useNotificationStore(s => s.clearHistory);
  const [linked, setLinked] = useLinkedNotifications(open);
  const navigate = useNavigate();
  const panelRef = useRef(null);
  // Escape (and a press outside the panel) closes, like every other popover.
  useDismiss(panelRef, onClose, open);

  if (!open) return null;

  const openLinked = (n) => {
    api.markNotificationsRead([n.id]).catch(() => {});
    setLinked(linked.filter((x) => x.id !== n.id));
    onClose();
    // Only in-app paths; a full URL from the server is reduced to its path.
    const url = new URL(n.url, window.location.origin);
    navigate(url.pathname + url.search);
  };

  // Group by date
  const groups = [];
  let currentGroup = null;
  for (const entry of history) {
    const group = dateGroup(entry.arrivedAt);
    if (group !== currentGroup) {
      currentGroup = group;
      groups.push({ label: group, items: [] });
    }
    groups[groups.length - 1].items.push(entry);
  }

  return (
    <div className={styles.overlay} role="presentation" onClick={onClose}>
      {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events -- only keeps panel clicks off the backdrop */}
      <div ref={panelRef} className={styles.panel} role="dialog" aria-label="Activity" onClick={e => e.stopPropagation()}>
        <div className={styles.header}>
          <span className={styles.title}>Activity</span>
          <span className={styles.headerActions}>
            {history.length > 0 && (
              <button type="button" className={styles.clearBtn} onClick={clearHistory}>Clear</button>
            )}
            <IconButton icon="xmark" size="sm" iconSize={11} onClick={onClose} aria-label="Close" title="Close (Esc)" />
          </span>
        </div>
        <div className={styles.feed}>
          <UpdateRow />
          {linked.length > 0 && (
            <div>
              <div className={styles.groupLabel}>For you</div>
              {linked.map((n) => (
                <button key={n.id} type="button" className={`${styles.feedItem} ${styles.feedLink}`} onClick={() => openLinked(n)}>
                  <span className={styles.feedRail} />
                  <span className={styles.feedIcon}><Icon name="folder" size={13} /></span>
                  <div className={styles.feedContent}>
                    <span className={styles.feedLabel}>{n.title}</span>
                    {n.body && <span className={styles.feedSummary}>{n.body}</span>}
                  </div>
                  <span className={styles.feedTime}>{formatClock(n.created_at)}</span>
                </button>
              ))}
            </div>
          )}
          {history.length === 0 && !linked.length ? (
            <div className={styles.empty}>
              <Icon name="tray" size={18} />
              <span>No recent activity</span>
            </div>
          ) : (
            groups.map(group => (
              <div key={group.label}>
                <div className={styles.groupLabel}>{group.label}</div>
                {group.items.map(entry => (
                  <div
                    key={entry._alertId}
                    className={styles.feedItem}
                    ref={(el) => { if (el) el.style.setProperty('--feed-color', `var(--notif-${entry.eventColor})`); }}
                  >
                    <span className={styles.feedRail} />
                    <span className={styles.feedIcon}>
                      <Icon name={getEventMeta(entry.eventType).icon} size={13} />
                    </span>
                    <div className={styles.feedContent}>
                      <span className={styles.feedLabel}>{entry.eventLabel}</span>
                      <span className={styles.feedSummary}>{feedSummary(entry)}</span>
                    </div>
                    <span className={styles.feedTime}>{formatClock(entry.arrivedAt)}</span>
                  </div>
                ))}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

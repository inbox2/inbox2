/**
 * TrayPage — the macOS menu bar popover (Tauri `tray` window, see
 * ui/desktop/src-tauri/src/tray.rs): the five newest unread threads with their
 * summaries, what's coming up, and the month with the same day-hover preview
 * the calendar sidebar has. Follows the selected theme — it is the same bundle,
 * so tokens.css + the stored theme id apply as they do in the main window.
 *
 * The window is wider than the card and transparent: the card sits at its right
 * edge and the day preview flies out into the gutter on the left, because a
 * webview can't draw outside its own window. Clicking the gutter closes it.
 *
 * Reads its own data (SQLite + the local-first API) each time it opens; anything
 * that needs the real app — opening a thread, the calendar — is handed to the
 * main window over the `notification-navigate` channel the alert cards use.
 */
import { useState, useEffect, useMemo, useCallback } from 'react';
import { addMonths, subMonths, startOfMonth, endOfMonth, format, differenceInMinutes } from 'date-fns';
import useAuth from '../../hooks/useAuth';
import useAccounts from '../../hooks/useAccounts';
import useChannelUnreadCounts from '../../hooks/useChannelUnreadCounts';
import useUnreadStore, { formatBadge } from '../../stores/unreadStore';
import { fetchLatestUnread } from '../../lib/trayData';
import { fetchEventsInRange } from '../../lib/localCalendar';
import { runNotificationAction } from '../../lib/notificationActions';
import { CONV_ACTION, ACTION_ICON } from '../../lib/conversationActions';
import { parseAddress } from '../../lib/emailAddress';
import { formatMailTimeCompact } from '../../lib/relativeTime';
import { applyTheme, DEFAULT_THEME_ID } from '../../lib/themes';
import { THEME } from '../../lib/storageKeys';
import { isStandaloneDesktop } from '../../lib/setupMode';
import { diskFinder, statusLine } from '../../lib/diskFinder';
import Avatar from '../../components/Avatar';
import IconButton from '../../components/IconButton';
import Button from '../../components/Button/Button';
import Icon from '../../components/Icon';
import MiniCalendar from '../../components/Calendar/MiniCalendar';
import EventListItem from '../../components/Calendar/EventListItem';
import { JoinButton } from '../../components/MeetingAlert/MeetingAlert';
import styles from './TrayPage.module.css';

const UNREAD_ROWS = 5;
const UPCOMING = 3;
const SOON_MINS = 30;
const REFRESH_MS = 60 * 1000;

const tauriEvent = () => import('@tauri-apps/api/event');
const hide = () => import('@tauri-apps/api/core')
  .then(({ invoke }) => invoke('tray_hide'))
  .catch(() => { /* not in Tauri */ });

// Hand a navigation to the main window (it raises itself), then get out of the way.
const openInApp = (payload) => {
  tauriEvent().then(({ emitTo }) => emitTo('main', 'notification-navigate', payload)).catch(() => {});
  hide();
};

export default function TrayPage() {
  const { user, organizations } = useAuth();
  const { allAccounts } = useAccounts(organizations);
  // This webview has its own unreadStore; count here too so the header is true.
  useChannelUnreadCounts(allAccounts);
  const total = useUnreadStore(s => s.total);

  const [mails, setMails] = useState(null); // null = first read still running
  const [events, setEvents] = useState([]);
  const [viewDate, setViewDate] = useState(() => new Date());
  const [opened, setOpened] = useState(0);

  // Transparent window: only the card paints.
  useEffect(() => {
    document.documentElement.style.setProperty('background', 'transparent');
    document.body.style.setProperty('background', 'transparent');
  }, []);

  // Each open: the theme may have changed in the main window, and the data has.
  useEffect(() => {
    let unlisten;
    tauriEvent().then(({ listen }) => listen('tray-opened', () => {
      applyTheme(localStorage.getItem(THEME) || DEFAULT_THEME_ID);
      setViewDate(new Date());
      setOpened(n => n + 1);
    })).then(fn => { unlisten = fn; }).catch(() => { /* not in Tauri */ });
    return () => { if (unlisten) unlisten(); };
  }, []);

  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') hide(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const accountsSig = allAccounts.map(a => a.key).join(',');
  useEffect(() => {
    let alive = true;
    const read = async () => {
      const rows = await fetchLatestUnread(allAccounts, UNREAD_ROWS);
      if (alive) setMails(rows);
    };
    read();
    const timer = setInterval(read, REFRESH_MS);
    return () => { alive = false; clearInterval(timer); };
    // allAccounts is a fresh array each render; its key signature is the real dep.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accountsSig, opened]);

  // Same window the calendar rail loads: a month either side of the one shown.
  const [from, to] = useMemo(() => [
    startOfMonth(subMonths(viewDate, 1)),
    endOfMonth(addMonths(viewDate, 1)),
  ], [viewDate]);

  useEffect(() => {
    let alive = true;
    fetchEventsInRange(from, to).then(evs => { if (alive) setEvents(evs); });
    return () => { alive = false; };
  }, [from, to, opened]);

  const eventDates = useMemo(() => events.map(e => format(e.start, 'yyyy-MM-dd')), [events]);
  const upcoming = useMemo(() => {
    const now = new Date();
    // Strictly upcoming, like the calendar rail: a meeting you're 47 minutes into isn't news.
    return events.filter(e => !e.allDay && e.start > now).sort((a, b) => a.start - b.start).slice(0, UPCOMING);
  }, [events]);

  const act = useCallback((mail, action) => {
    setMails(list => (list || []).filter(m => m.key !== mail.key));
    runNotificationAction(mail, action, null, {
      onUnread: (delta) => {
        useUnreadStore.getState().adjust(mail.accountKey, delta);
        tauriEvent().then(({ emitTo }) => emitTo('main', 'unread-adjust', { key: mail.accountKey, delta })).catch(() => {});
      },
    });
  }, []);

  const openDay = useCallback((day) => openInApp({ page: 'calendar', date: day.toISOString() }), []);
  // A meeting opens its day AND its detail popup (CalendarPage's :eventId deep link).
  const openEvent = useCallback((e) => openInApp({ page: 'calendar', date: e.start.toISOString(), eventId: e.key }), []);

  return (
    <div className={styles.window} role="presentation" onMouseDown={(e) => { if (e.target === e.currentTarget) hide(); }}>
      <section className={styles.card} aria-label="inbox2">
        <header className={styles.header}>
          <img src="/logo-mark.png" alt="" className={styles.mark} />
          <h1 className={styles.title}>Unread</h1>
          {total > 0 && <span className={styles.count}>{formatBadge(total)}</span>}
          <span className={styles.spacer} />
          <IconButton icon="macwindow" aria-label="Open inbox2" title="Open inbox2" onClick={() => openInApp({ page: 'mail' })} />
        </header>

        {/* Local channels need no inbox2 account — only a signed-out cloud setup is empty. */}
        {!user && !isStandaloneDesktop() ? (
          <div className={styles.empty}>
            <div className={styles.emptyTitle}>This Mac isn&rsquo;t signed in</div>
            <div className={styles.emptyText}>Sign in to inbox2 and your unread mail and calendar show up here.</div>
            <Button onClick={() => openInApp({ page: 'mail' })}>Open inbox2</Button>
          </div>
        ) : (
          <>
            {mails && mails.length === 0 && (
              <div className={styles.empty}>
                <span className={styles.emptyGlyph}><Icon name="checkmark" size={16} /></span>
                <div className={styles.emptyTitle}>Nothing unread</div>
                <div className={styles.emptyText}>New mail shows up here as it arrives.</div>
              </div>
            )}

            {mails && mails.length > 0 && (
              <ul className={styles.mails}>
                {mails.map((m) => {
                  const from = parseAddress(m.from_address);
                  const sender = from.name || from.email || 'Unknown sender';
                  return (
                    <li key={`${m.accountKey}:${m.key}`} className={styles.mail}>
                      <button
                        type="button"
                        className={styles.mailOpen}
                        onClick={() => openInApp({ page: 'mail', accountKey: m.accountKey, conversationId: m.key })}
                      >
                        <span className={styles.dot} />
                        <Avatar name={sender} email={from.email} size={28} />
                        <span className={styles.mailText}>
                          <span className={styles.mailTop}>
                            <span className={styles.sender}>{sender}</span>
                            <span className={styles.when}>{formatMailTimeCompact(m.updated_at)}</span>
                          </span>
                          <span className={styles.subject}>{m.subject || '(No subject)'}</span>
                          {m.summary && <span className={styles.summary}>{m.summary}</span>}
                        </span>
                      </button>
                      <span className={styles.mailActions}>
                        <IconButton size="sm" icon={ACTION_ICON[CONV_ACTION.MARK_READ]} aria-label="Mark as read" title="Mark as read" onClick={() => act(m, CONV_ACTION.MARK_READ)} />
                        <IconButton size="sm" icon={ACTION_ICON[CONV_ACTION.ARCHIVE]} aria-label="Archive" title="Archive" onClick={() => act(m, CONV_ACTION.ARCHIVE)} />
                      </span>
                    </li>
                  );
                })}
              </ul>
            )}

            {total > UNREAD_ROWS && (
              <Button variant="link" className={`${styles.link} ${styles.more}`} onClick={() => openInApp({ page: 'mail' })}>
                {total - UNREAD_ROWS} more unread &middot; Open inbox
              </Button>
            )}

            {upcoming.length > 0 && (
              <div className={styles.section}>
                <div className={styles.sectionLabel}>Coming up</div>
                {upcoming.map((e) => (
                  <div key={e.key} className={styles.event}>
                    <EventListItem
                      start={e.start}
                      title={e.title}
                      provider={e.provider}
                      account={e.account}
                      soon={differenceInMinutes(e.start, new Date()) <= SOON_MINS}
                      onClick={() => openEvent(e)}
                    />
                    {e.meeting && (
                      <JoinButton meeting={e.meeting} title={e.title} tone="theme" className={styles.join} onJoined={hide} />
                    )}
                  </div>
                ))}
              </div>
            )}

            <DiskRow opened={opened} />

            <div className={styles.section}>
              <MiniCalendar
                selectedDate={viewDate}
                onSelect={setViewDate}
                onOpenDay={openDay}
                eventDates={eventDates}
                events={events}
              />
            </div>

            <footer className={styles.footer}>
              <Button variant="link" className={styles.link} onClick={() => openInApp({ page: 'calendar' })}>Open calendar</Button>
            </footer>
          </>
        )}
      </section>
    </div>
  );
}

/* Disk in Finder's state in one line, when it is on (docs/Disk-Sync.md). */
function DiskRow({ opened }) {
  const [status, setStatus] = useState(null);
  useEffect(() => {
    if (!diskFinder.available()) return undefined;
    let alive = true;
    diskFinder.status().then((s) => { if (alive) setStatus(s); }).catch(() => {});
    return () => { alive = false; };
  }, [opened]);
  if (!status?.enabled) return null;
  const line = statusLine(status);
  return (
    <div className={styles.section}>
      <div className={styles.sectionLabel}>Disk</div>
      <button type="button" className={styles.diskRow} onClick={() => { diskFinder.open().catch(() => {}); hide(); }}>
        <span className={`${styles.diskDot} ${styles[`disk_${line.tone}`]}`} aria-hidden="true" />
        <span className={styles.diskText}>{line.text}</span>
        <span className={styles.diskOpen}>Open in Finder</span>
      </button>
    </div>
  );
}

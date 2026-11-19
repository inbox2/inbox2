import { useCallback, useState, useEffect, useMemo } from 'react';
import { differenceInMinutes } from 'date-fns';
import useCalendarStore from '../../stores/calendarStore';
import MiniCalendar from './MiniCalendar';
import Clock from './Clock';
import EventListItem from './EventListItem';
import ZoneSection from './ZoneSection';
import { detectMeetingProvider } from '../MeetingProviderIcon/meetingProvider';
import { ToolbarButton } from '../ToolbarGroup';
import AccountSwitcher, { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import Checkbox from '../Checkbox/Checkbox';
import Icon from '../Icon';
import { PROVIDER } from '../../lib/providerTypes';
import { pastelFor } from '../../lib/calendarColors';
import styles from './CalendarSidebar.module.css';

const VIEW_OPTIONS = [
  { key: 'month', label: 'Month', icon: 'calendar' },
  { key: 'week', label: 'Week', icon: 'calendar.day.timeline.left' },
  { key: 'workweek', label: 'Work week', icon: 'calendar.day.timeline.left' },
  { key: 'day', label: 'Day', icon: 'calendar.day.timeline.leading' },
  { key: 'agenda', label: 'Agenda', icon: 'list.bullet' },
];

export default function CalendarSidebar({ width, accounts, onNewEvent, onEventClick, onNewZone, onZoneClick }) {
  const view = useCalendarStore(s => s.view);
  const setView = useCalendarStore(s => s.setView);
  const currentDate = useCalendarStore(s => s.currentDate);
  const setCurrentDate = useCalendarStore(s => s.setCurrentDate);
  const calendars = useCalendarStore(s => s.calendars);
  const events = useCalendarStore(s => s.events);
  const visibleCalendarIds = useCalendarStore(s => s.visibleCalendarIds);
  const toggleCalendarVisibility = useCalendarStore(s => s.toggleCalendarVisibility);
  const activeAccountKey = useCalendarStore(s => s.activeAccountKey);
  const setActiveAccountKey = useCalendarStore(s => s.setActiveAccountKey);

  // Live clock — ticks every 60s (CSS handles colon blink), pauses when tab hidden
  const [now, setNow] = useState(new Date());
  useEffect(() => {
    let timer = setInterval(() => setNow(new Date()), 60000);
    const handleVisibility = () => {
      clearInterval(timer);
      if (!document.hidden) {
        setNow(new Date());
        timer = setInterval(() => setNow(new Date()), 60000);
      }
    };
    document.addEventListener('visibilitychange', handleVisibility);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', handleVisibility);
    };
  }, []);

  const handleDateSelect = useCallback((date) => {
    setCurrentDate(date);
  }, [setCurrentDate]);

  // Event dates for mini-calendar dots
  const eventDates = useMemo(
    () => events.map(e => e.start_at?.split('T')[0]).filter(Boolean),
    [events]
  );

  // Store rows in the shape the mini-calendar's hover preview (DayPeek) wants.
  const peekEvents = useMemo(
    () => events.map(e => ({
      key: e.id,
      title: e.title,
      start: new Date(e.start_at),
      end: new Date(e.end_at || e.start_at),
      allDay: !!e.all_day,
      color: pastelFor(e.calendar_id),
    })),
    [events]
  );

  // Group calendars by the account they belong to — the header is the specific
  // email account, with that account's individual calendars listed below it.
  // API/inbox2 calendars have no account key, so they fall back to source grouping.
  const calendarGroups = useMemo(() => {
    const SOURCE_LABELS = { inbox2: 'inbox2', google: 'Google', microsoft: 'Microsoft' };
    const acctByKey = new Map((accounts || []).map(a => [a.key, a]));
    const groups = new Map();
    for (const cal of calendars) {
      const acct = cal._accountKey ? acctByKey.get(cal._accountKey) : null;
      const groupKey = acct ? `acct:${acct.key}` : `src:${cal.source || 'inbox2'}`;
      if (!groups.has(groupKey)) {
        groups.set(groupKey, {
          key: groupKey,
          label: acct
            ? (acct.email_address || acct.display_name)
            : (SOURCE_LABELS[cal.source] || cal.source || 'inbox2'),
          providerType: acct ? acct.provider_type : (cal.source === 'google' ? PROVIDER.GMAIL : cal.source),
          iconUrl: acct?.icon_url || null,
          avatarUrl: acct?.avatar_url || null,
          calendars: [],
        });
      }
      groups.get(groupKey).calendars.push(cal);
    }
    return Array.from(groups.values());
  }, [calendars, accounts]);

  // Upcoming events (next 5 events from now)
  const upcoming = useMemo(() => {
    const nowISO = now.toISOString();
    return events
      .filter(e => e.start_at > nowISO && e.status !== 'cancelled')
      .sort((a, b) => a.start_at.localeCompare(b.start_at))
      .slice(0, 5);
  }, [events, now]);

  return (
    <div className={styles.sidebar} ref={n => n && n.style.setProperty('--cal-sidebar-w', `${width || 260}px`)}>
      {/* Account switcher — same pattern as mail */}
      <div className={styles.accountSwitcherWrap}>
        <AccountSwitcher
          accounts={accounts || []}
          activeKey={activeAccountKey}
          onSwitch={(key) => setActiveAccountKey(key)}
          onAddAccount={() => {}}
          onUnified={() => setActiveAccountKey(null)}
          isUnified={!activeAccountKey}
        />
      </div>

      <Clock />

      <ToolbarButton icon="plus.circle" variant="compose" className={styles.newEventBtn} onClick={onNewEvent}>
        New event
      </ToolbarButton>

      <div className={styles.miniCalendarWrap}>
        <MiniCalendar
          selectedDate={currentDate}
          onSelect={handleDateSelect}
          eventDates={eventDates}
          events={peekEvents}
        />
      </div>

      {/* Upcoming events — schedule awareness */}
      {upcoming.length > 0 && (
        <div className={styles.section}>
          <div className={styles.sectionTitle}>Coming up</div>
          <div className={styles.upcomingList}>
            {upcoming.map(evt => {
              const start = new Date(evt.start_at);
              const minsAway = differenceInMinutes(start, now);
              // Which channel it's on — same leading icon as the inbox rail.
              const acct = (accounts || []).find(a => a.key === evt._accountKey);
              return (
                <EventListItem key={evt.id} start={start} title={evt.title} soon={minsAway <= 30 && minsAway >= 0} provider={detectMeetingProvider(evt.location, evt.description, evt.title)} account={acct ? { providerType: acct.provider_type, avatarUrl: acct.avatar_url, email: acct.email_address } : null} onClick={onEventClick ? (rect) => onEventClick(evt, rect) : null} />
              );
            })}
          </div>
        </div>
      )}

      {/* Empty state — schedule intelligence */}
      {upcoming.length === 0 && (
        <div className={styles.emptySchedule}>
          <Icon name="checkmark.circle" size={16} />
          <span>Nothing coming up</span>
        </div>
      )}

      {/* Zones (docs/Calendar.md "Zones") — only for a signed-in account. */}
      {onNewZone && <ZoneSection onNewZone={onNewZone} onZoneClick={onZoneClick} />}

      <div className={styles.section}>
        <div className={styles.sectionTitle}>View</div>
        <div className={styles.viewList}>
          {VIEW_OPTIONS.map(opt => (
            <button
              key={opt.key}
              className={`${styles.viewItem}${view === opt.key ? ` ${styles.viewItemActive}` : ''}`}
              onClick={() => setView(opt.key)}
            >
              <span className={styles.viewItemIcon}>
                <Icon name={opt.icon} size={15} />
              </span>
              <span>{opt.label}</span>
            </button>
          ))}
        </div>
      </div>

      <div className={styles.section}>
        <div className={styles.sectionTitle}>Calendars</div>
        {calendarGroups.length === 0 && (
          <div className={styles.emptyCalendars}>
            <span>No calendars yet</span>
          </div>
        )}
        {calendarGroups.map(group => {
          const allVisible = group.calendars.every(c => visibleCalendarIds.has(c.id));
          const handleGroupToggle = () => {
            // If any visible, hide all; if none visible, show all
            group.calendars.forEach(c => {
              const isVisible = visibleCalendarIds.has(c.id);
              if (allVisible && isVisible) toggleCalendarVisibility(c.id);
              if (!allVisible && !isVisible) toggleCalendarVisibility(c.id);
            });
          };
          return (
            <div key={group.key} className={styles.sourceGroup}>
              <div className={styles.sourceHeader} role="presentation" onClick={handleGroupToggle}>
                {/* ponytail: readOnly — the row's onClick toggles; an onChange here fires too and cancels it out */}
                <Checkbox checked={allVisible} readOnly />
                <ProviderIcon type={group.providerType} iconUrl={group.iconUrl} avatarUrl={group.avatarUrl} size={16} />
                <span className={styles.sourceName}>{group.label}</span>
              </div>
              <div className={styles.calendarList}>
                {group.calendars.map(cal => (
                  <div key={cal.id} className={styles.calendarItem} role="presentation" onClick={() => toggleCalendarVisibility(cal.id)}>
                    <Checkbox checked={visibleCalendarIds.has(cal.id)} readOnly />
                    <span className={styles.calendarDot} ref={n => n && n.style.setProperty('--dot-color', cal.color)} />
                    <span className={styles.calendarName}>{cal.name}</span>
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

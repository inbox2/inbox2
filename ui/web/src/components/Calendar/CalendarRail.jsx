import { useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { useNavigate } from 'react-router'
import { addMonths, subMonths, startOfMonth, endOfMonth, format, differenceInMinutes } from 'date-fns'
import { fetchEventsInRange } from '../../lib/localCalendar'
import { CALENDAR_RAIL_MODE } from '../../lib/storageKeys'
import usePaneMode from '../../hooks/usePaneMode'
import { PaneModeMenu, PaneStrip } from '../PaneMode/PaneMode'
import useCalendarStore from '../../stores/calendarStore'
import NavGroup from '../NavGroup'
import Icon from '../Icon'
import Clock from './Clock'
import MiniCalendar from './MiniCalendar'
import EventListItem from './EventListItem'
import EventDetailPopup from './EventDetailPopup'
import ZoneSection from './ZoneSection'
import ZoneEditor from './ZoneEditor'
import styles from './CalendarRail.module.css'

// Unified inbox right rail: what time it is, the month either side of it, and
// what's coming up. One local-SQLite read feeds all three (dots, the day hover
// preview, the list) — see lib/localCalendar.

const REFRESH_MS = 60 * 1000
const UPCOMING = 5
const SOON_MINS = 30

export default function CalendarRail({ orgSlug }) {
  const navigate = useNavigate()
  // Pinned / floating / hidden, remembered across sessions. The column wrapper
  // (ListViewColumns .columnAside) narrows to the strip off [data-pane-strip].
  const railRef = useRef(null)
  const pane = usePaneMode(CALENDAR_RAIL_MODE, railRef)
  const [viewDate, setViewDate] = useState(() => new Date())
  const [events, setEvents] = useState([])
  // Clicked "Coming up" row → the same detail popup the full calendar shows
  // (read-only here — local events aren't editable and the rail isn't a CRUD surface).
  const [detail, setDetail] = useState(null)
  // Zones (docs/Calendar.md "Zones") — the store is fed app-wide by useZoneAlerts.
  const [zoneEditor, setZoneEditor] = useState(null) // { zone } | { defaults }

  // The mini-calendar shows mid-previous → mid-next month; load a whole month
  // either side so its edge weeks (and their dots) are never blank.
  const [from, to] = useMemo(() => [
    startOfMonth(subMonths(viewDate, 1)),
    endOfMonth(addMonths(viewDate, 1)),
  ], [viewDate])

  useEffect(() => {
    if (!pane.shown) return
    let alive = true
    const tick = async () => {
      const evs = await fetchEventsInRange(from, to)
      if (alive) setEvents(evs)
    }
    tick()
    const timer = setInterval(tick, REFRESH_MS)
    return () => { alive = false; clearInterval(timer) }
  }, [from, to, pane.shown])

  const eventDates = useMemo(() => events.map((e) => format(e.start, 'yyyy-MM-dd')), [events])

  const upcoming = useMemo(() => {
    const now = new Date()
    return events
      .filter((e) => e.start > now)
      .sort((a, b) => a.start - b.start)
      .slice(0, UPCOMING)
  }, [events])

  // Month paging (the chevrons) only walks the rail's own window...
  const handleSelect = useCallback((day) => setViewDate(day), [])

  // ...while clicking an actual day opens that day in the full calendar.
  const handleOpenDay = useCallback((day) => {
    useCalendarStore.getState().setCurrentDate(day)
    navigate(orgSlug ? `/${orgSlug}/calendar` : '/calendar')
  }, [navigate, orgSlug])

  return (
    <aside ref={railRef} className={styles.rail}>
      {pane.strip && <PaneStrip pane={pane} icon="calendar" label="Calendar" align="left" />}

      {pane.shown && (
      <div className={styles.body} data-floating={pane.floating ? 'true' : undefined}>
        <PaneModeMenu pane={pane} label="Calendar pane" align="left" className={styles.modeButton} />
        <Clock />

        <div className={styles.miniWrap}>
          <MiniCalendar
            selectedDate={viewDate}
            onSelect={handleSelect}
            onOpenDay={handleOpenDay}
            eventDates={eventDates}
            events={events}
            span="wide"
          />
        </div>

        <NavGroup icon="calendar.badge.clock" title="Coming up">
          {upcoming.length === 0 ? (
            <div className={styles.empty}>
              <Icon name="checkmark.circle" size={14} />
              <span>Nothing coming up</span>
            </div>
          ) : upcoming.map((e) => (
            <EventListItem
              key={e.key}
              start={e.start}
              title={e.title}
              provider={e.provider}
              account={e.account}
              soon={differenceInMinutes(e.start, new Date()) <= SOON_MINS}
              onClick={(rect) => setDetail({ event: e.detail, rect })}
            />
          ))}
        </NavGroup>
        <ZoneSection
          onNewZone={() => setZoneEditor({ defaults: null })}
          onZoneClick={(zone) => setZoneEditor({ zone })}
        />
        <div className={styles.tail} />
      </div>
      )}

      {detail && (
        <EventDetailPopup
          event={detail.event}
          anchorRect={detail.rect}
          placement="left"
          onClose={() => setDetail(null)}
        />
      )}

      {zoneEditor && (
        <ZoneEditor zone={zoneEditor.zone} defaults={zoneEditor.defaults} onClose={() => setZoneEditor(null)} />
      )}
    </aside>
  )
}

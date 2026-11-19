import { layoutDay } from '../../lib/localCalendar'
import { EVENT_TEXT } from '../../lib/calendarColors'
import styles from './DayPeek.module.css'

// One day of the calendar, drawn the way FullCalendar's timeGrid draws it: an
// hour gutter with events positioned by their real start/duration. Used as the
// mini-calendar's hover preview, so it stays read-only and compact.

const HOUR_PX = 22
const MIN_BLOCK_PX = 14

const clockLabel = (d) => d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
const hourLabel = (h) => new Date(2000, 0, 1, h).toLocaleTimeString(undefined, { hour: 'numeric' })

export default function DayPeek({ day, events }) {
  const allDay = events.filter((e) => e.allDay)
  const { spans, hours, originMin } = layoutDay(events, day)

  return (
    <div className={styles.peek}>
      <div className={styles.header}>
        {day.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })}
      </div>

      {allDay.length > 0 && (
        <div className={styles.allDay}>
          {allDay.map((e) => (
            <span key={e.key} className={styles.allDayChip}>{e.title}</span>
          ))}
        </div>
      )}

      {events.length === 0 ? (
        <div className={styles.empty}>Nothing scheduled</div>
      ) : (
        <div
          className={styles.grid}
          ref={(n) => n && n.style.setProperty('--peek-h', `${hours.length * HOUR_PX}px`)}
        >
          <div className={styles.gutter}>
            {hours.map((h) => (
              <div key={h} className={styles.hour}>{hourLabel(h)}</div>
            ))}
          </div>
          <div className={styles.track}>
            {hours.map((h) => <div key={h} className={styles.hourLine} />)}
            {spans.map((e) => (
              <div
                key={e.key}
                className={styles.event}
                ref={(n) => {
                  if (!n) return
                  n.style.setProperty('--evt-top', `${((e.from - originMin) / 60) * HOUR_PX}px`)
                  n.style.setProperty('--evt-h', `${Math.max(MIN_BLOCK_PX, ((e.to - e.from) / 60) * HOUR_PX)}px`)
                  n.style.setProperty('--evt-color', e.color || 'var(--accent-primary)')
                  n.style.setProperty('--evt-ink', EVENT_TEXT)
                  // Concurrent events share the width instead of stacking.
                  n.style.setProperty('--evt-left', `${(e.col / e.cols) * 100}%`)
                  n.style.setProperty('--evt-w', `${100 / e.cols}%`)
                }}
              >
                <span className={styles.eventTime}>{clockLabel(e.start)}</span>
                <span className={styles.eventTitle}>{e.title}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

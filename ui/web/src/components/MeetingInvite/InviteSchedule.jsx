import { useState, useEffect } from 'react'
import { isTauri } from '../../lib/tauri'
import { inviteInstant } from '../../lib/invites'
import { getDb } from '../../lib/db.js'
import { resolveAccountKey } from '../../lib/draftAttachments'
import EventListItem from '../Calendar/EventListItem'
import { detectMeetingProvider } from '../MeetingProviderIcon/meetingProvider'
import log from '../../lib/log'
import styles from './InviteSchedule.module.css'

// "Around this time" — the account's synced calendar events near the invite, so
// the user can spot conflicts before answering. Rows reuse the calendar's own
// EventListItem design; a conflict (overlaps the invite) gets the warm `soon`
// emphasis. Sourced from local SQLite (desktop/local channels for now — MX +
// mobile can follow).

const WINDOW_MS = 2 * 60 * 60 * 1000 // ±2h around the meeting

function overlaps(a, b) {
  return new Date(a.start) < new Date(b.end) && new Date(a.end) > new Date(b.start)
}

const DAY_MS = 24 * 60 * 60 * 1000

// An event starting this close to the meeting is taken to BE the meeting.
// ponytail: time only, not title — a detected meeting's title is the model's
// wording, so it rarely matches the one the event was saved under.
const SAME_TIME_MS = 15 * 60 * 1000

async function fetchLocalAdjacent(invite, message, winStart, winEnd) {
  try {
    const accountKey = await resolveAccountKey(message)
    const db = await getDb()
    if (!accountKey || !db) return []
    // start_at is stored in mixed RFC3339 forms (`+02:00` and `Z`), so a string
    // comparison on the full timestamp is wrong. Bound coarsely by the date
    // prefix (widened a day each side for offset/midnight slop) and do the
    // precise overlap in JS with Date, which understands both forms.
    const dayLo = new Date(winStart.getTime() - DAY_MS).toISOString().slice(0, 10)
    const dayHi = new Date(winEnd.getTime() + DAY_MS).toISOString().slice(0, 10)
    const rows = await db.select(
      `SELECT key, title, start_at, end_at, all_day, location, description FROM calendar_events
       WHERE account_key = ?1 AND substr(start_at, 1, 10) BETWEEN ?2 AND ?3
       ORDER BY start_at ASC LIMIT 60`,
      [accountKey, dayLo, dayHi]
    )
    return (rows || [])
      // Drop all-day events (not time-specific) and the invite's own synced copy.
      .filter((r) => !r.all_day && r.key !== invite.matched_event_key)
      .map((r) => ({ title: r.title || 'Busy', start: r.start_at, end: r.end_at || r.start_at, provider: detectMeetingProvider(r.location, r.description, r.title) }))
      .filter((e) => new Date(e.start) < winEnd && new Date(e.end) > winStart)
  } catch (e) {
    log.warn('[InviteSchedule] fetch failed', e)
    return []
  }
}

/** `onSameTime(event|null)`: called with the event that starts at the invite's time, if any. */
export default function InviteSchedule({ invite, message, onSameTime }) {
  const [events, setEvents] = useState([])

  useEffect(() => {
    let alive = true
    if (!invite?.start || !isTauri()) return undefined
    const winStart = new Date(inviteInstant(invite.start, invite.timezone).getTime() - WINDOW_MS)
    const winEnd = new Date(inviteInstant(invite.end || invite.start, invite.timezone).getTime() + WINDOW_MS)
    ;(async () => {
      const evs = await fetchLocalAdjacent(invite, message, winStart, winEnd)
      if (!alive) return
      setEvents(evs)
      const t = inviteInstant(invite.start, invite.timezone).getTime()
      onSameTime?.(evs.find((e) => Math.abs(new Date(e.start).getTime() - t) <= SAME_TIME_MS) || null)
    })()
    return () => { alive = false }
  }, [invite, message, onSameTime])

  if (events.length === 0) return null

  const inviteWindow = { start: inviteInstant(invite.start, invite.timezone).toISOString(), end: inviteInstant(invite.end || invite.start, invite.timezone).toISOString() }
  return (
    <aside className={styles.schedule}>
      <div className={styles.title}>Around this time</div>
      <div className={styles.list}>
        {events.map((e, i) => (
          <EventListItem key={i} start={e.start} title={e.title} soon={overlaps(e, inviteWindow)} provider={e.provider} />
        ))}
      </div>
    </aside>
  )
}

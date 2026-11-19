import { useState, useEffect } from 'react'
import { fetchNextMeeting } from '../../lib/localCalendar'
import NavGroup from '../NavGroup'
import Tooltip from '../Tooltip'
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher'
import EventListItem from './EventListItem'
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon'
import { openLink } from '../../lib/openLink'
import styles from './NextMeeting.module.css'

// "Next meeting" — sits in the left sidebar footer, above the sync bar, so the
// next thing on the calendar is always in view. A NavGroup so it reads as one of
// the sidebar's own sections; the row is the shared EventListItem (same design
// as the invite banner's "Around this time"). Which calendar it's on = the
// channel icon in the header, hover for the address. Local SQLite only.

const REFRESH_MS = 60 * 1000

export default function NextMeeting() {
  const [event, setEvent] = useState(null)

  useEffect(() => {
    let alive = true
    // Re-reads every minute: keeps "in 12m" honest and rolls to the next meeting.
    const tick = async () => {
      const e = await fetchNextMeeting()
      if (alive) setEvent(e)
    }
    tick()
    const timer = setInterval(tick, REFRESH_MS)
    return () => { alive = false; clearInterval(timer) }
  }, [])

  if (!event) return null

  const where = [event.email, event.calendarName].filter(Boolean).join(' · ')

  return (
    <NavGroup
      icon="calendar"
      title="Next meeting"
      action={where ? (
        <Tooltip content={where}>
          <ProviderIcon type={event.providerType} avatarUrl={event.avatarUrl} name={event.email} size={14} />
        </Tooltip>
      ) : null}
    >
      <div className={styles.body}>
        <EventListItem start={event.start} title={event.title} provider={event.meeting?.provider} soon={event.soon} />
        {/* Only inside the soon window (≤30m) — otherwise the sidebar grows a
            button that's wrong for most of the day. */}
        {event.soon && event.meeting && (
          <button className={styles.join} onClick={() => openLink(event.meeting.url)}>
            <MeetingProviderIcon provider={event.meeting.provider} size={14} />
            Join meeting
          </button>
        )}
      </div>
    </NavGroup>
  )
}

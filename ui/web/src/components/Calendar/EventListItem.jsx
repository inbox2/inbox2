import { isToday, isTomorrow, differenceInMinutes } from 'date-fns'
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon'
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher'
import Tooltip from '../Tooltip'
import styles from './EventListItem.module.css'

// The calendar "Coming Up" event row, extracted so the calendar sidebar and the
// meeting-invite banner render events with one identical design (don't invent a
// second event-item style). `soon` = the warm imminent/attention emphasis.

function formatRelativeTime(date) {
  const now = new Date()
  const mins = differenceInMinutes(date, now)
  if (mins < 1) return 'now'
  if (mins < 60) return `in ${mins}m`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `in ${hrs}h`
  return date.toLocaleDateString(undefined, { weekday: 'short' })
}

function formatUpcomingDate(date) {
  const timeStr = date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
  if (isToday(date)) return timeStr
  if (isTomorrow(date)) return `Tomorrow ${timeStr}`
  return `${date.toLocaleDateString(undefined, { weekday: 'short' })} ${timeStr}`
}

// `account` = which channel the event lives on ({providerType, avatarUrl,
// email}). Icon only — the address is a hover label, since several accounts can
// share a provider glyph.
export default function EventListItem({ start, title, soon = false, provider = null, account = null, onClick = null }) {
  const s = start instanceof Date ? start : new Date(start)
  // Clickable rows are real buttons (keyboard-reachable); static ones stay divs.
  const Tag = onClick ? 'button' : 'div'
  return (
    <Tag
      type={onClick ? 'button' : undefined}
      onClick={onClick ? (e) => onClick(e.currentTarget.getBoundingClientRect(), e) : undefined}
      className={`${styles.upcomingItem}${soon ? ` ${styles.upcomingSoon}` : ''}${onClick ? ` ${styles.upcomingClickable}` : ''}`}
    >
      <div className={styles.upcomingTime}>
        <span className={styles.upcomingRelative}>{formatRelativeTime(s)}</span>
        <span className={styles.upcomingAbsolute}>{formatUpcomingDate(s)}</span>
      </div>
      <div className={styles.upcomingTitle}>
        {account && (
          <Tooltip content={account.email}>
            <ProviderIcon type={account.providerType} avatarUrl={account.avatarUrl} size={13} />
          </Tooltip>
        )}
        {provider && <MeetingProviderIcon provider={provider} size={14} />}
        <span className={styles.upcomingTitleText}>{title}</span>
      </div>
    </Tag>
  )
}

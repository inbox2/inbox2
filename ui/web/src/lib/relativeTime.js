/**
 * Format a date as relative time (e.g. "3m ago", "2h ago", "yesterday").
 */
export default function relativeTime(date) {
  const now = Date.now()
  const d = date instanceof Date ? date : new Date(date)
  const diff = now - d.getTime()
  const sec = Math.floor(diff / 1000)

  if (sec < 60) return 'just now'
  const min = Math.floor(sec / 60)
  if (min < 60) return `${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${hr}h ago`
  const days = Math.floor(hr / 24)
  if (days === 1) return 'yesterday'
  if (days < 7) return `${days}d ago`
  if (days < 30) return `${Math.floor(days / 7)}w ago`
  if (days < 365) return `${Math.floor(days / 30)}mo ago`
  return `${Math.floor(days / 365)}y ago`
}

/**
 * Format a date as a short clock time (e.g. "9:05 AM"). Accepts a Date, a
 * date string, or a ms timestamp; returns '' for falsy input.
 */
export function formatClock(value) {
  if (!value) return ''
  const d = value instanceof Date ? value : new Date(value)
  return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
}

/**
 * Mail-card timestamp: clock time today ("9:05 AM"), weekday + clock within
 * the last week ("Mon 9:05 AM"), short date beyond that ("Jan 5").
 */
export function formatMailTime(value) {
  if (!value) return ''
  const d = value instanceof Date ? value : new Date(value)
  const diffDays = Math.floor((Date.now() - d.getTime()) / (1000 * 60 * 60 * 24))
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })

  if (diffDays === 0) return time
  if (diffDays < 7) return `${d.toLocaleDateString([], { weekday: 'short' })} ${time}`
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' })
}

/**
 * Compact variant for dense rows: clock time today ("09:05"), bare age within
 * the month ("3d", "2w"), short date beyond that ("Jan 5").
 */
export function formatMailTimeCompact(value) {
  if (!value) return ''
  const d = value instanceof Date ? value : new Date(value)
  const diffDays = Math.floor((Date.now() - d.getTime()) / (1000 * 60 * 60 * 24))

  if (diffDays === 0) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  if (diffDays < 7) return `${diffDays}d`
  if (diffDays < 30) return `${Math.floor(diffDays / 7)}w`
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' })
}

import { meetingProviderSvg } from './meetingProvider'
import styles from './MeetingProviderIcon.module.css'

// Brand mark for a detected meeting provider (Zoom/Meet/Teams…). Renders the
// shared SVG-markup source so it stays identical to the FullCalendar DOM path.
export default function MeetingProviderIcon({ provider, size = 22 }) {
  const svg = meetingProviderSvg(provider, size)
  if (!svg) return null
  return <span className={styles.wrap} dangerouslySetInnerHTML={{ __html: svg }} />
}

import { useLocation } from 'react-router'
import Spinner from '../Spinner'
import { isDiskPath } from '../../lib/disk/model'
import { isConsolePath } from '../../lib/consoleHost'
import styles from './RouteLoading.module.css'

// The pages drawn on the cream management canvas outside Disk and the console (sign-in, onboarding,
// public share links, the meeting page). On every host: these paths are the same there.
const CREAM = /^\/(login|signup|waitlist|forgot-password|reset-password|link|meet|oauth|share|onboarding)(\/|$)/

/**
 * What shows while a page's code chunk (or the session) loads: a centred spinner on the
 * page's own canvas, cream for Disk and the console, dark for mail. Without it the
 * window behind the app shows through (black on the desktop app) for that moment.
 */
export default function RouteLoading() {
  const { pathname } = useLocation()
  const light = CREAM.test(pathname) || isDiskPath(pathname) || isConsolePath(pathname)
  return (
    <div className={`${styles.page} ${light ? `${styles.light} management` : ''}`} role="status" aria-label="Loading">
      <Spinner size={22} color={light ? 'var(--m-ink-faint)' : undefined} />
    </div>
  )
}
